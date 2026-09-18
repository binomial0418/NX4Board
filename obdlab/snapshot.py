"""快照拍攝與比對 —— 這份專案的分析核心。

為什麼用快照而不是即時監看
--------------------------
ELM327 走藍牙序列埠，實測一次請求約 200 毫秒。監看 16 個目標跑完一輪要
145 秒，切檔只停留幾秒根本取樣不到。改成「把狀態固定住，慢慢把全部 DID
拍一遍」，取樣速度就不再是問題。檔位 R 與 D 都是這樣定出來的。

比對的四道過濾，每一道都是實車踩過的坑
--------------------------------------
1. 長度不一致 → 略過。多幀組裝結果不同時比 byte 會全錯位。
2. 連讀兩次就自己變 → 雜訊。引擎的溫度、點火角、滾動計數器屬於這類。
   沒有這道時，15 個候選裡 14 個是引擎自己在飄。
3. 同標籤跨快照不穩定 → 雜訊。抓的是變化比連讀間隔更慢的漂移。
   所以每個狀態要拍兩張，只拍一張時這道完全沒作用（實測 247 個候選）。
4. 識別區 DID 變了 → 不是候選，是警訊。那裡是零件號與版本字串，
   永遠不變，變了代表讀取本身有問題，整份比對要打折扣。
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from elm import Elm
from uds import byte_label, is_static_did, popcount, request


def capture(e: Elm, dids: list[str], label: str, log=print,
            reads: int = 2) -> tuple[dict[str, str], dict[str, str]]:
    """把 dids 全部讀一遍，每個讀兩次。

    dids 的格式是 "HEADER|CMD"。回傳兩份 payload 表，第二份用來建雜訊遮罩。
    """
    a: dict[str, str] = {}
    b: dict[str, str] = {}
    t0 = time.time()
    for i, key in enumerate(dids, 1):
        header, cmd = key.split("|", 1)
        r1 = request(e, header, cmd, timeout=1.5)
        r2 = request(e, header, cmd, timeout=1.5)
        if r1.payload is not None:
            a[key] = r1.payload
            if r2.payload is not None:
                b[key] = r2.payload
        if i % 40 == 0:
            log(f"  「{label}」進度 {i}/{len(dids)}"
                f"（{time.time() - t0:.0f} 秒）")
    log(f"  「{label}」完成，取得 {len(a)}/{len(dids)} 個，"
        f"耗時 {time.time() - t0:.0f} 秒")
    return a, b


@dataclass
class Candidate:
    key: str
    index: int
    bits: int
    per_state: dict[str, str]

    def line(self) -> str:
        detail = "  ".join(f"{k}={v}" for k, v in self.per_state.items())
        return (f"{self.key.replace('|', '/')} byte {byte_label(self.index)}"
                f"  差{self.bits}位元  {detail}")


def diff(snaps: list[dict], log=print) -> list[Candidate]:
    """比對多張快照，找出隨狀態改變而且同狀態下穩定的位元組。"""
    if len(snaps) < 2:
        log("至少要兩張快照")
        return []

    by_state: dict[str, list[dict]] = {}
    for s in snaps:
        by_state.setdefault(s["label"], []).append(s)
    if len(by_state) < 2:
        log(f"只有「{next(iter(by_state))}」一種狀態，需要至少兩種")
        return []

    states = list(by_state)
    log(f"══ 比對 {' / '.join(f'{k}×{len(v)}' for k, v in by_state.items())} ══")
    if all(len(v) == 1 for v in by_state.values()):
        log("⚠ 每種狀態都只有一張快照，濾不掉會自己慢慢飄的 byte。"
            "同狀態拍兩張可大幅減少誤判。")

    common = set(snaps[0]["a"])
    for s in snaps:
        common &= set(s["a"])

    skipped_len = 0
    self_drift = 0
    unstable = 0
    static_changed: list[str] = []
    cands: list[Candidate] = []

    for key in sorted(common):
        lens = {len(s["a"][key]) for s in snaps}
        if len(lens) != 1:
            skipped_len += 1
            continue

        _, cmd = key.split("|", 1)
        if is_static_did(cmd):
            if len({s["a"][key] for s in snaps}) > 1:
                static_changed.append(key.replace("|", "/"))
            continue

        for i in range(lens.pop() // 2):
            sl = slice(i * 2, i * 2 + 2)

            # 過濾二：連讀兩次就不一樣
            noisy = False
            for s in snaps:
                bb = s.get("b", {}).get(key)
                if bb and len(bb) == len(s["a"][key]) \
                        and s["a"][key][sl] != bb[sl]:
                    noisy = True
                    break
            if noisy:
                self_drift += 1
                continue

            # 過濾三：同狀態跨快照不穩定
            per_state: dict[str, str] = {}
            stable = True
            for st in states:
                vals = {s["a"][key][sl] for s in by_state[st]}
                if len(vals) != 1:
                    stable = False
                    break
                per_state[st] = vals.pop()
            if not stable:
                unstable += 1
                continue
            if len(set(per_state.values())) < 2:
                continue

            xor = 0
            vs = [int(v, 16) for v in per_state.values()]
            for x in range(len(vs)):
                for y in range(x + 1, len(vs)):
                    xor |= vs[x] ^ vs[y]
            cands.append(Candidate(key, i, popcount(xor), dict(per_state)))

    if static_changed:
        log(f"⚠ 有 {len(static_changed)} 個識別區 DID 內容不一樣，但那裡是"
            f"零件號與版本字串、理論上永遠不變。")
        log(f"⚠ 代表多幀回應組裝錯位，這份比對可信度要打折扣。"
            f"受影響：{', '.join(static_changed[:6])}")

    log(f"比對 {len(common)} 個 DID：略過長度不一致 {skipped_len} 個、"
        f"連讀就自己飄 {self_drift} 個 byte、同狀態不穩定 {unstable} 個 byte")

    # 旗標通常只翻一個位元，量值會翻好幾個。單一位元排前面省掉大量人工篩選。
    cands.sort(key=lambda c: (-len(set(c.per_state.values())), c.bits, c.key))
    log(f"找到 {len(cands)} 個隨狀態變動的 byte，最像旗標的排前面：")
    for c in cands[:40]:
        log("  ★ " + c.line())
    if len(cands) > 40:
        log(f"  其餘 {len(cands) - 40} 個未列出")
    return cands
