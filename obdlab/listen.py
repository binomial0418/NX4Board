"""被動監聽廣播封包（ATMA）。

為什麼 K13 要這個
-----------------
NX4 的 OBD 接頭後面有閘道器，只轉發診斷請求，聽不到車身廣播。
同代 Nissan 沒有閘道器：OBD 接頭就在主 CAN 上，轉速、車速、水溫、里程
各模組本來就在定期廣播（Qashqai、Juke、Leaf 三份資料都這樣接）。
聽就好，不必問。

ELM327 走藍牙聽整條匯流排一定 BUFFER FULL（500 kbps 上每秒上千幀），
所以一次只聽一個 ID（ATCRA），每個聽幾秒、輪流來。不帶 ID 的
「普查模式」會刻意不過濾聽一下，只為了列出匯流排上有哪些 ID。
"""

from __future__ import annotations

import time

import cars
import store
from elm import Elm
from uds import select_module

_HEX = set("0123456789ABCDEF")


def parse_frames(raw: str) -> list[tuple[str, bytes]]:
    """把 ATH1 + ATS0 + ATCAF0 的監聽輸出拆成 (ID, 資料)。

    每行長這樣：5C5 後面接最多 8 個位元組，例如 "5C50012D6870000000"。
    BUFFER FULL、STOPPED、殘缺的行都丟掉。
    """
    out = []
    for line in raw.replace("\r", "\n").split("\n"):
        line = line.strip().replace(" ", "").replace(">", "").upper()
        if len(line) < 5 or not set(line) <= _HEX:
            continue
        body = line[3:]
        if len(body) % 2:
            continue
        out.append((line[:3], bytes.fromhex(body)))
    return out


def _enter(e: Elm) -> None:
    select_module(e, "7DF")
    e.send("ATH1")       # 要看到 ID
    e.send("ATCAF0")     # 原始 8 位元組，不要 ELM 當 ISO-TP 解讀


def _leave(e: Elm) -> None:
    e.send("ATCRA")
    e.send("ATCAF1")
    e.send("ATH0")
    e.rx_filter = "AUTO"


def listen_id(e: Elm, cid: str, seconds: float) -> list[tuple[float, bytes]]:
    """只聽一個 ID，回傳 [(相對秒數, 資料)]。時間是平均攤開的近似值。"""
    e.send(f"ATCRA{cid}")
    e.rx_filter = cid
    t0 = time.time()
    raw = e.monitor("ATMA", seconds)
    frames = [d for i, d in parse_frames(raw) if i == cid]
    span = time.time() - t0
    n = max(1, len(frames))
    return [(round(span * k / n, 2), d) for k, d in enumerate(frames)]


def survey(e: Elm, seconds: float, log=print) -> dict[str, int]:
    """不過濾聽一下，列出匯流排上出現過哪些 ID 與次數。"""
    _enter(e)
    try:
        e.send("ATCRA")
        raw = e.monitor("ATMA", seconds)
    finally:
        _leave(e)
    if "BUFFERFULL" in raw.replace(" ", "").upper():
        log("  （ELM 緩衝區滿了，這是預期的；列出的 ID 仍然有效，但次數偏低）")
    counts: dict[str, int] = {}
    for cid, _ in parse_frames(raw):
        counts[cid] = counts.get(cid, 0) + 1
    return dict(sorted(counts.items()))


def summarize(cid: str, frames: list[tuple[float, bytes]], log=print) -> dict:
    """印出一個 ID 的摘要：幾幀、哪些位元組在變、假設解讀。"""
    car = cars.current()
    bc = car.broadcasts.get(cid)
    title = f"{cid}" + (f"（{bc.desc}）" if bc else "")
    if not frames:
        log(f"  {title}：沒聽到")
        return {"frames": 0}
    datas = [d for _, d in frames]
    width = max(len(d) for d in datas)
    moving = []
    for i in range(width):
        vals = {d[i] for d in datas if len(d) > i}
        if len(vals) > 1:
            moving.append(f"{chr(0x41 + i)}({len(vals)})")
    first, last = datas[0], datas[-1]
    log(f"  {title}：{len(frames)} 幀，首 {first.hex().upper()}  "
        f"末 {last.hex().upper()}")
    log(f"     會變的 byte：{' '.join(moving) or '（都沒變）'}")
    if bc and bc.decode:
        try:
            log(f"     假設解讀（末幀）：{bc.decode(last)}")
        except Exception as exc:
            log(f"     假設解讀失敗：{exc}")
    return {"frames": len(frames), "moving": moving,
            "first": first.hex().upper(), "last": last.hex().upper()}


def run(e: Elm, ids: list[str], seconds: float, label: str,
        log=print) -> dict:
    """依序聽每個 ID，印摘要並存檔。"""
    record: dict = {"label": label, "car": cars.current().key,
                    "seconds": seconds, "ids": {}}
    _enter(e)
    try:
        for cid in ids:
            cid = cid.upper()
            frames = listen_id(e, cid, seconds)
            record["ids"][cid] = {
                "summary": summarize(cid, frames, log),
                "frames": [[t, d.hex().upper()] for t, d in frames],
            }
    finally:
        _leave(e)
    path = store.save_listen(label, record)
    log(f"已存 {path}")
    return record
