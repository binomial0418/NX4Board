"""模組點名、位址普查、家族探索、DID 掃描。"""

from __future__ import annotations

import cars
from elm import Elm
from uds import request, select_module


def roll_call(e: Elm, log=print) -> dict[str, str]:
    """對每個位址送識別區查詢。回傳 {header: 判定依據}，只含活著的。"""
    car = cars.current()
    alive: dict[str, str] = {}
    for header, _, note in car.modules:
        verdict = ""
        for did in car.liveness:
            r = request(e, header, did, timeout=1.5)
            if r.alive:
                verdict = f"{did} {r.describe()}"
                break
        if verdict:
            alive[header] = verdict
            log(f"  [活] {header}→{car.response_id(header)}  {verdict}"
                + (f"   ({note})" if note else ""))
        else:
            log(f"  [--] {header}  沒回應")
    select_module(e, "7DF")
    return alive


def census(e: Elm, lo: int = 0x700, hi: int = 0x7FF, probe: str = "3E01",
           log=print) -> dict[str, list[str]]:
    """700~7FF 每個請求位址各送一道 probe，看是哪個位址回話。

    Nissan 的回應位址不規則（745→765、746→783），只靠設定表會漏，
    所以接收過濾放寬成整個 7xx（ATCF700 + ATCM700）並打開 ATH1，
    從回應行首的位址看出是誰回的。

    probe 預設 3E01（TesterPresent）：講 KWP 的會回 7E01，講 UDS 的會回
    7F3E12（子功能不支援）—— 兩種都證明有人在。它不改變任何狀態。

    回傳 {請求位址: [回應位址, ...]}，只含有回應的。
    """
    found: dict[str, list[str]] = {}
    select_module(e, "7DF")
    e.send("ATH1")
    e.send("ATCF700")
    e.send("ATCM700")
    e.rx_filter = "CENSUS"
    seen_count: dict[str, int] = {}
    try:
        for n, req in enumerate(range(lo, hi + 1), 1):
            header = f"{req:03X}"
            if header == "7DF":
                continue
            e.set_header(header)
            raw = e.send(probe, timeout=0.6)
            ids = []
            for line in raw.replace("\r", "\n").split("\n"):
                line = line.strip().replace(" ", "").upper()
                if len(line) >= 5 and all(c in "0123456789ABCDEF"
                                          for c in line):
                    rid = line[:3]
                    if rid not in ids and rid != header:
                        ids.append(rid)
            for rid in ids:
                seen_count[rid] = seen_count.get(rid, 0) + 1
            if ids:
                found[header] = ids
                log(f"  [回] {header} → {', '.join(ids)}")
            if n % 64 == 0:
                log(f"  進度 {header}，{len(found)} 個位址有回應")
    finally:
        e.send("ATH0")
        e.send("ATCRA")            # 清掉 CF/CM 過濾，回到自動
        e.rx_filter = "AUTO"
        e.set_header("7DF")

    # 對很多請求都「回應」的位址是自己在定期發送，不是在回話
    total = max(1, len(found))
    noisy = {rid for rid, c in seen_count.items() if c > 3 and c / total > 0.3}
    if noisy:
        log(f"  略過定期發送的位址（不是回應）：{', '.join(sorted(noisy))}")
        found = {k: [r for r in v if r not in noisy] for k, v in found.items()}
        found = {k: v for k, v in found.items() if v}
    return found


def find_families(e: Elm, header: str, log=print,
                  indices: tuple[str, ...] = ("00", "01")) -> list[str]:
    """對 256 個家族各試幾個索引，找出有回應的家族。

    已知限制：只試 indices 裡那幾個索引。如果某個家族的成員從 05 才開始，
    整族會被漏掉。前雷達只找到 5 個一到兩位元組的小值，很可能就是這個原因。
    位址空間總共 65536 個，這個做法只涵蓋 512 個。
    """
    found = []
    for hi in range(0x100):
        fam = f"{hi:02X}"
        for lo in indices:
            r = request(e, header, f"22{fam}{lo}", timeout=1.2)
            if r.payload is not None:
                found.append(fam)
                log(f"  [家族] {header} 22{fam} 有回應")
                break
        if (hi + 1) % 64 == 0:
            log(f"  {header} 進度 {hi + 1}/256，找到 {len(found)} 族")
    return found


def sweep(e: Elm, header: str, prefix: str, log=print,
          negatives: dict | None = None) -> dict[str, str]:
    """把 prefix 後面接 00~FF 全問一遍，回傳 {CMD: payload}。

    prefix "22E0" 掃 22E000~22E0FF（UDS 的一個家族）；
    prefix "21" 掃 2100~21FF（KWP 的 local identifier，Nissan 這一代用的）。
    negatives 有給的話，順便記下每種負回應原因碼出現幾次 ——
    全部都是「會談不支援」代表要加 --session，而不是真的沒有資料。
    """
    out: dict[str, str] = {}
    for lo in range(0x100):
        cmd = f"{prefix}{lo:02X}"
        r = request(e, header, cmd, timeout=1.2)
        if r.payload is not None:
            out[cmd] = r.payload
            log(f"  [DID] {header}/{cmd}  {r.payload[:60]}"
                + ("…" if len(r.payload) > 60 else ""))
        elif negatives is not None and r.negative:
            nrc = r.negative[1]
            negatives[nrc] = negatives.get(nrc, 0) + 1
        if (lo + 1) % 64 == 0:
            log(f"  {header}/{prefix} 進度 {lo + 1}/256，累計 {len(out)} 個")
    return out


def sweep_family(e: Elm, header: str, fam: str, log=print) -> dict[str, str]:
    """把一個 22 家族的 00~FF 全問一遍（相容舊呼叫）。"""
    return sweep(e, header, f"22{fam}", log=log)
