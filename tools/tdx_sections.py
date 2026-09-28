#!/usr/bin/env python3
"""從 TDX 下載國道與省道的「路段」靜態資料，打包成 App 用的 assets/tdx_sections.json.gz。

用法:
    TDX_CLIENT_ID=... TDX_CLIENT_SECRET=... python3 tools/tdx_sections.py
    python3 tools/tdx_sections.py --roadrader-config ../../web/RoadRader/refactor_v2/config.py

路段（Section）是 TDX 發布即時路況的單位，每段有方向、起訖里程與折線幾何。
App 用折線比對目前所在路段，再依里程列出前方路段，按段向 Live API 查車速。
這取代了 RoadRader 以 VD 點位推里程的做法：VD 的 LocationMile 半數是空的，
而從 LinkID 拆出的數字不是里程（台61 58 支 VD 只有 3 支誤差在 1 km 內）。

來源（皆為 v2 Road/Traffic）:
    Section/Freeway, SectionShape/Freeway      國道 456 段
    Section/Highway, SectionShape/Highway      省道 6831 段（含台61～88 快速公路）
    VD/Highway                                 LinkID → VDID 對照

台66～88 等東西向快速公路在 Live/Highway 沒有路段車速，每段另外記錄對應的 VD，
App 端改查 VD 補上。對應有兩個來源，取聯集：
    1. 路段 LinkIDs 與 VD DetectionLinks 相同。但台72/74/76/78 這樣對到的是新編號
       VD（VD-T74-…），2026-09 實測幾乎全部 Status=1、車速 -99，形同離線
    2. 幾何：同路名的 VD 位在路段折線 30 m 內（投影不落在端點外），且偵測鏈路的
       Bearing 與折線方位相差 67.5° 內。舊編號 VD（VD-21-0740-…）仍正常回報，
       台74 有車速的路段因此從 5/33 增加到 31/33。台61 上與路段車速比對，同向鏈路
       差距中位數 3.5 km/h、對向 7.0，方向配對有效

輸出格式（gzip JSON）:
    {"version": 1, "updated": "...", "sections": [
        {"i": SectionID, "s": "F" 國道 / "P" 省道, "r": 路線編號（對應 OSM ref，如 "1"、"61"、"3甲"）,
         "n": 顯示用路名, "d": 方向（N/NE/…）, "a": 起點里程 km, "b": 終點里程 km,
         "l": 速限（國道才有，其餘 0）, "v": {VDID: [LinkID, ...]}（僅省道，可能為空）,
         "p": 折線，[lon, lat] 以 1e-5 度為單位的整數，第一點為絕對值、其後為差值}
    ]}

折線點序即行車方向（實測 95% 路段頭尾方位與 RoadDirection 相差 60° 內，其餘為彎道），
雙向路段相距中位數僅 11 m，所以 App 必須以航向比對方向，不能只看距離。
"""

import argparse
import gzip
import importlib.util
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request

AUTH_URL = 'https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token'
BASE_URL = 'https://tdx.transportdata.tw/api/basic/v2/Road/Traffic'

# Douglas-Peucker 容差。TDX 折線與 OSM 同編號道路中位數距離 2.2 m，簡化不能比這粗太多。
SIMPLIFY_M = 3.0

# VD 幾何配對：到路段折線的距離上限，與偵測方向和折線方位的容許差（8 方位的半格再加一半）
VD_RADIUS_M = 30.0
VD_BEARING_TOL = 67.5
COMPASS = {'N': 0, 'NE': 45, 'E': 90, 'SE': 135, 'S': 180, 'SW': 225, 'W': 270, 'NW': 315}

OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'tdx_sections.json.gz')


def load_credentials(args):
    if args.roadrader_config:
        spec = importlib.util.spec_from_file_location('rr_config', args.roadrader_config)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.CLIENT_ID, mod.CLIENT_SECRET
    cid = os.environ.get('TDX_CLIENT_ID')
    secret = os.environ.get('TDX_CLIENT_SECRET')
    if not cid or not secret:
        sys.exit('需要 TDX_CLIENT_ID / TDX_CLIENT_SECRET 環境變數或 --roadrader-config')
    return cid, secret


def get_token(cid, secret):
    data = urllib.parse.urlencode({
        'grant_type': 'client_credentials',
        'client_id': cid,
        'client_secret': secret,
    }).encode()
    req = urllib.request.Request(
        AUTH_URL, data=data, headers={'content-type': 'application/x-www-form-urlencoded'})
    return json.load(urllib.request.urlopen(req, timeout=30))['access_token']


def fetch(token, path, key):
    url = f'{BASE_URL}/{path}?$format=JSON'
    req = urllib.request.Request(
        url, headers={'authorization': f'Bearer {token}', 'Accept-Encoding': 'gzip'})
    resp = urllib.request.urlopen(req, timeout=120)
    body = resp.read()
    if resp.headers.get('Content-Encoding') == 'gzip':
        body = gzip.decompress(body)
    items = json.loads(body)[key]
    print(f'  {path}: {len(items)}')
    time.sleep(0.5)  # TDX 會員有每秒次數限制
    return items


def parse_km(text):
    m = re.match(r'\s*(\d+)K\+(\d+)', text or '')
    if not m:
        return None
    return int(m.group(1)) + int(m.group(2)) / 1000.0


def road_key(road_name):
    """TDX 路名 → (系統, OSM ref)。國道對應 OSM motorway，其餘是省道。

    國道1號汐止五股高架道路在 OSM 上同樣是 ref=1 的 motorway，併入國1。
    Section/Freeway 裡的「臺76線」是高公局代管的省道，歸省道。
    """
    m = re.match(r'國道(\d+)號', road_name)
    if m:
        return 'F', m.group(1)
    m = re.match(r'國道(\d+甲)', road_name)
    if m:
        return 'F', m.group(1)
    m = re.match(r'[台臺](\d+[甲乙丙丁戊己庚]?)線', road_name)
    if m:
        return 'P', m.group(1)
    return None


def parse_linestring(wkt):
    return [(float(x), float(y)) for x, y in re.findall(r'([-\d.]+) ([-\d.]+)', wkt)]


def simplify(points, tol_m):
    if len(points) < 3:
        return points
    lat0 = math.radians(points[0][1])
    kx = 111320.0 * math.cos(lat0)
    ky = 110574.0
    xy = [(p[0] * kx, p[1] * ky) for p in points]

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        s, e = stack.pop()
        ax, ay = xy[s]
        bx, by = xy[e]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        best, idx = 0.0, -1
        for i in range(s + 1, e):
            px, py = xy[i]
            if length == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                d = abs(dy * (px - ax) - dx * (py - ay)) / length
            if d > best:
                best, idx = d, i
        if best > tol_m:
            keep[idx] = True
            stack.append((s, idx))
            stack.append((idx, e))
    return [p for p, k in zip(points, keep) if k]


def project(points, lon, lat):
    """點到折線的投影：(距離 m, 線段方位, 是否落在端點外)"""
    kx = 111320.0 * math.cos(math.radians(lat))
    ky = 110574.0
    best = None
    last = len(points) - 2
    for i in range(len(points) - 1):
        ax, ay = (points[i][0] - lon) * kx, (points[i][1] - lat) * ky
        bx, by = (points[i + 1][0] - lon) * kx, (points[i + 1][1] - lat) * ky
        dx, dy = bx - ax, by - ay
        length_sq = dx * dx + dy * dy
        t = 0.0 if length_sq == 0 else max(0.0, min(1.0, (-ax * dx - ay * dy) / length_sq))
        d = math.hypot(ax + t * dx, ay + t * dy)
        if best is None or d < best[0]:
            outside = (i == 0 and t == 0.0) or (i == last and t == 1.0)
            best = (d, (math.degrees(math.atan2(dx, dy)) + 360) % 360, outside)
    return best


def angle_diff(a, b):
    d = abs(a - b) % 360
    return 360 - d if d > 180 else d


def geo_vd_links(points, road_vds):
    """位在折線旁且偵測方向相符的 VD 鏈路：{VDID: [LinkID, ...]}"""
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    pad = 0.001
    out = {}
    for vd in road_vds:
        lon, lat = vd['PositionLon'], vd['PositionLat']
        if not (min(lons) - pad <= lon <= max(lons) + pad and min(lats) - pad <= lat <= max(lats) + pad):
            continue
        dist, bearing, outside = project(points, lon, lat)
        if dist > VD_RADIUS_M or outside:
            continue
        for link in vd.get('DetectionLinks', []):
            d = link.get('Bearing') or link.get('RoadDirection')
            if d in COMPASS and angle_diff(COMPASS[d], bearing) <= VD_BEARING_TOL:
                out.setdefault(vd['VDID'], []).append(link['LinkID'])
    return out


def encode_points(points):
    out = []
    px = py = 0
    for lon, lat in points:
        x, y = round(lon * 1e5), round(lat * 1e5)
        out += [x - px, y - py]
        px, py = x, y
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--roadrader-config', help='讀取 RoadRader 的 config.py 取得 TDX 憑證')
    ap.add_argument('--out', default=OUT)
    args = ap.parse_args()

    token = get_token(*load_credentials(args))
    print('下載 TDX 路段資料')
    sources = [
        ('F', fetch(token, 'Section/Freeway', 'Sections'),
         fetch(token, 'SectionShape/Freeway', 'SectionShapes')),
        ('P', fetch(token, 'Section/Highway', 'Sections'),
         fetch(token, 'SectionShape/Highway', 'SectionShapes')),
    ]
    vds = fetch(token, 'VD/Highway', 'VDs')

    link_to_vd = {}
    vds_by_road = {}
    for vd in vds:
        for link in vd.get('DetectionLinks', []):
            link_to_vd[link['LinkID']] = vd['VDID']
        if 'PositionLon' in vd and 'PositionLat' in vd:
            vds_by_road.setdefault(vd.get('RoadName', '').replace('臺', '台'), []).append(vd)

    sections = []
    skipped = {'路名': 0, '里程': 0, '折線': 0}
    points_before = points_after = 0
    for api, secs, shapes in sources:
        shape_of = {s['SectionID']: s['Geometry'] for s in shapes}
        for sec in secs:
            key = road_key(sec.get('RoadName', ''))
            if key is None:
                skipped['路名'] += 1
                continue
            a = parse_km(sec.get('SectionMile', {}).get('StartKM'))
            b = parse_km(sec.get('SectionMile', {}).get('EndKM'))
            if a is None or b is None or a == b:
                skipped['里程'] += 1
                continue
            pts = parse_linestring(shape_of.get(sec['SectionID'], ''))
            if len(pts) < 2:
                skipped['折線'] += 1
                continue

            simple = simplify(pts, SIMPLIFY_M)
            points_before += len(pts)
            points_after += len(simple)

            vd_links = {}
            if api == 'P':
                for link in sec.get('LinkIDs', []):
                    vdid = link_to_vd.get(link['LinkID'])
                    if vdid:
                        vd_links.setdefault(vdid, []).append(link['LinkID'])
                road_name = sec['RoadName'].replace('臺', '台')
                for vdid, links in geo_vd_links(pts, vds_by_road.get(road_name, [])).items():
                    merged = vd_links.setdefault(vdid, [])
                    merged += [l for l in links if l not in merged]

            sections.append({
                'i': sec['SectionID'],
                # 查即時路況要用的 API：國道路段 → Live/Freeway，省道 → Live/Highway。
                # 臺76 雖歸省道 ref，資料卻在國道 API 底下。
                'q': api,
                's': key[0],
                'r': key[1],
                'n': sec['RoadName'].replace('臺', '台'),
                'd': sec.get('RoadDirection', ''),
                'a': round(a, 3),
                'b': round(b, 3),
                'l': int(sec.get('SpeedLimit') or 0),
                'v': vd_links,
                'p': encode_points(simple),
            })

    payload = {
        'version': 1,
        'updated': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'sections': sections,
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
    with gzip.open(args.out, 'wb', compresslevel=9) as fh:
        fh.write(raw)

    by_system = {'F': 0, 'P': 0}
    for s in sections:
        by_system[s['s']] += 1
    with_vd = sum(1 for s in sections if s['v'])
    print(f'輸出 {len(sections)} 段（國道 {by_system["F"]}、省道 {by_system["P"]}，'
          f'{with_vd} 段有 VD 對照）')
    print(f'  略過 {skipped}')
    print(f'  折線點 {points_before} → {points_after}')
    print(f'  {args.out}: {os.path.getsize(args.out) / 1024:.0f} KB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
