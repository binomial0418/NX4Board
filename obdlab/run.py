#!/usr/bin/env python3
"""obdlab 指令列入口。

    python3 run.py ports                    列出候選序列埠
    python3 run.py probe                    連線並跑初始化，印 ELM 版本
    python3 run.py raw 22BC08 --header 770  送一道原始查詢
    python3 run.py modules                  模組點名
    python3 run.py families 7D0             對某個位址做家族探索
    python3 run.py sweep 7D0 E0             掃一個家族
    python3 run.py discover                 完整探索（點名 + 家族 + 掃描）
    python3 run.py snap 鑰匙在車內           拍一張快照
    python3 run.py diff                     比對已存的快照
    python3 run.py watch 770|22BC08 ...     即時監看，只印變動
    python3 run.py pids                     標準 PID 支援表

共用選項：--port 指定序列埠，--verbose 印出每一道收發。
"""

from __future__ import annotations

import argparse
import sys
import time

import discover
import snapshot
import store
from elm import Elm, candidate_ports
from uds import PID_LEN, byte_label, request, walk_mode01


def connect(args) -> Elm:
    port = args.port
    if not port:
        ports = candidate_ports()
        if not ports:
            sys.exit("找不到序列埠。先在系統設定把 OBD 傳輸器配對成藍牙裝置，"
                     "配對後 /dev/cu.<名稱> 才會出現。")
        if len(ports) > 1:
            print("多個候選序列埠，用 --port 指定其中一個：")
            for p in ports:
                print("  ", p)
            sys.exit(1)
        port = ports[0]
    print(f"連線 {port} …")
    e = Elm(port, verbose=args.verbose)
    print("ELM 版本：", e.init())
    return e


# ── 子指令 ──────────────────────────────────────────────────────────────

def cmd_ports(args):
    ports = candidate_ports()
    print("\n".join(ports) if ports else
          "(沒有候選序列埠。先配對藍牙 OBD 傳輸器)")


def cmd_probe(args):
    e = connect(args)
    r = request(e, "7DF", "0100")
    print("0100 →", r.describe())
    e.close()


def cmd_raw(args):
    e = connect(args)
    r = request(e, args.header, args.cmd, timeout=args.timeout)
    print(f"{args.header}/{args.cmd}")
    print("  原始 ：", r.raw.strip())
    print("  整理 ：", r.hex)
    print("  判讀 ：", r.describe())
    e.close()


def cmd_modules(args):
    e = connect(args)
    print("── 模組點名（正回應與負回應都算存在）──")
    alive = discover.roll_call(e)
    store.save_modules(alive)
    print(f"活著的位址 {len(alive)} 個，已存 {store.MODULES}")
    e.close()


def cmd_families(args):
    e = connect(args)
    fams = discover.find_families(e, args.header)
    print(f"{args.header} 找到家族：{', '.join(fams) or '(無)'}")
    e.close()


def cmd_sweep(args):
    e = connect(args)
    found = discover.sweep_family(e, args.header, args.family.upper())
    dids = store.load_dids()
    for cmd, payload in found.items():
        dids[f"{args.header}|{cmd}"] = payload
    store.save_dids(dids)
    print(f"{args.header}/{args.family} 有回應 {len(found)} 個，"
          f"已知 DID 累計 {len(dids)} 個")
    e.close()


def cmd_discover(args):
    e = connect(args)
    print("── 第一步：模組點名 ──")
    alive = discover.roll_call(e)
    store.save_modules(alive)

    dids = store.load_dids()
    print(f"\n── 第二步：取得各模組的 DID（已知 {len(dids)} 個）──")
    for header in alive:
        have = any(k.startswith(f"{header}|") for k in dids)
        known = discover.KNOWN_FAMILIES.get(header)
        if have and known:
            print(f"  {header} 的 22{known} 先前已掃完，跳過")
            continue
        fams = [known] if known else discover.find_families(e, header)
        for fam in fams:
            if fam == "F1":      # 識別區，掃了也沒有狀態訊號
                continue
            found = discover.sweep_family(e, header, fam)
            for cmd, payload in found.items():
                dids[f"{header}|{cmd}"] = payload
            store.save_dids(dids)
    print(f"\n探索結束，已知 DID 共 {len(dids)} 個，存在 {store.DIDS}")
    e.close()


def cmd_snap(args):
    dids = sorted(store.load_dids())
    if not dids:
        sys.exit("還沒有已知 DID，先跑 discover")
    e = connect(args)
    if args.delay:
        print(f"{args.delay} 秒後開始拍攝「{args.label}」，現在去做動作 …")
        for left in range(args.delay, 0, -10):
            time.sleep(min(10, left))
            if left > 10:
                print(f"  還有 {left - 10} 秒")
    print(f"── 拍攝「{args.label}」（{len(dids)} 個 DID，每個讀兩次）──")
    a, b = snapshot.capture(e, dids, args.label)
    path = store.save_snapshot(args.label, a, b)
    print("已存", path)
    e.close()


def cmd_diff(args):
    snaps = store.load_snapshots()
    if not snaps:
        sys.exit("沒有快照")
    snapshot.diff(snaps)


def cmd_watch(args):
    e = connect(args)
    keys = args.dids
    last: dict[str, str] = {}
    print(f"── 監看 {len(keys)} 個 DID，只印變動。Ctrl-C 結束 ──")
    try:
        while True:
            for key in keys:
                header, cmd = key.split("|", 1)
                r = request(e, header, cmd, timeout=1.5)
                p = r.payload
                if p is None:
                    continue
                prev = last.get(key)
                if prev is None:
                    last[key] = p
                    print(f"[{time.strftime('%H:%M:%S')}] {key} 首筆 {p}")
                elif p != prev:
                    diffs = [
                        f"{byte_label(i)}:{prev[i*2:i*2+2]}->{p[i*2:i*2+2]}"
                        for i in range(min(len(prev), len(p)) // 2)
                        if prev[i*2:i*2+2] != p[i*2:i*2+2]]
                    print(f"[{time.strftime('%H:%M:%S')}] ★ {key} "
                          f"{' '.join(diffs)}")
                    last[key] = p
    except KeyboardInterrupt:
        print("\n結束")
    finally:
        e.close()


def cmd_pids(args):
    e = connect(args)
    supported: list[int] = []
    for base in range(0x00, 0xC0, 0x20):
        pid = f"{base:02X}"
        r = request(e, "7DF", f"01{pid}", timeout=2.0)
        hexs = r.hex
        # 廣播查詢會有多顆模組各自回自己的支援表，要全部聯集
        maps, i = [], hexs.find(f"41{pid}")
        while i != -1 and i + 12 <= len(hexs):
            maps.append(int(hexs[i + 4:i + 12], 16))
            i = hexs.find(f"41{pid}", i + 4)
        if not maps:
            print(f"01{pid} 無回應，後面的區間不查了")
            break
        bits = 0
        for m in maps:
            bits |= m
        n = 0
        for k in range(32):
            if bits & (1 << (31 - k)):
                supported.append(base + k + 1)
                n += 1
        print(f"01{pid} → {len(maps)} 顆模組回應，聯集支援 {n} 個")
        if not bits & 1:
            break
    print("支援：", " ".join(f"{p:02X}" for p in supported))
    for p in supported:
        if f"{p:02X}" in PID_LEN:
            print(f"  01{p:02X} 已知長度 {PID_LEN[f'{p:02X}']} byte")
    # App 實際在查的，對一次
    for p, note in ((0x0B, "MAP，算增壓用"), (0x0D, "車速"),
                    (0x33, "大氣壓，算增壓基準"), (0x70, "專用增壓壓力")):
        if p not in supported:
            print(f"  ✗ 01{p:02X} 不支援（{note}）")
    r = request(e, "7DF", "010B0C0D", timeout=2.0)
    print("010B0C0D 原始回應 →", r.hex)
    print("  逐段走訪 →", walk_mode01(r.hex, ["0B", "0C", "0D"]))
    e.close()


def main():
    ap = argparse.ArgumentParser(description="obdlab：Mac 直連 OBD 訊號分析")
    ap.add_argument("--port")
    ap.add_argument("--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ports").set_defaults(fn=cmd_ports)
    sub.add_parser("probe").set_defaults(fn=cmd_probe)
    sub.add_parser("modules").set_defaults(fn=cmd_modules)
    sub.add_parser("discover").set_defaults(fn=cmd_discover)
    sub.add_parser("diff").set_defaults(fn=cmd_diff)
    sub.add_parser("pids").set_defaults(fn=cmd_pids)

    p = sub.add_parser("raw"); p.set_defaults(fn=cmd_raw)
    p.add_argument("cmd"); p.add_argument("--header", default="7DF")
    p.add_argument("--timeout", type=float, default=2.0)

    p = sub.add_parser("families"); p.set_defaults(fn=cmd_families)
    p.add_argument("header")

    p = sub.add_parser("sweep"); p.set_defaults(fn=cmd_sweep)
    p.add_argument("header"); p.add_argument("family")

    p = sub.add_parser("snap"); p.set_defaults(fn=cmd_snap)
    p.add_argument("label"); p.add_argument("--delay", type=int, default=0)

    p = sub.add_parser("watch"); p.set_defaults(fn=cmd_watch)
    p.add_argument("dids", nargs="+")

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
