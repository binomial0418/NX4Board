"""模組點名、家族探索、DID 掃描。"""

from __future__ import annotations

from elm import Elm
from uds import Resp, request

# 點名清單。括號裡是實車確認的身分，靠 22FD10 之類的字串自報或資料形態推斷。
MODULE_HEADERS = [
    ("7A5", "智慧鑰匙 SMK 候選 —— 實車兩次點名都沒回應，應該不在這個位址"),
    ("770", "車身 IGMP（車門、門鎖、大燈、倒車）"),
    ("7C6", "儀表 CLU（里程、油量、保養）"),
    ("7E0", "引擎 ECM"),
    ("7E1", "變速箱 TCU（零件號 95441-3D210）"),
    ("7E2", "活著，只有識別區"),
    ("7E3", "油電相關（字串自報 GNXDH22GAMS0）"),
    ("7E4", "電池管理 BMS（220102/220103 各 32 byte 電芯資料）"),
    ("7A0", "胎壓 TPMS"),
    ("7D0", "前方雷達 FCA（22FD10 字串自報 LogicRadar / FCA）"),
    ("7D2", "活著但找不到資料家族"),
    ("7D4", "未知，2201 家族有資料"),
    ("7B1", "未知，22C0 家族有資料"),
    ("7B3", "空調（2201xx 是溫度與風門）"),
    ("7C4", "未知，2201 與 22FD 家族有資料"),
    ("7D1", "ABS（OBD.csv 有列，點名沒回應）"),
    ("7D6", ""), ("7E5", ""), ("7A1", ""), ("780", ""),
]

# 已知模組使用的 DID 家族，由 OBD.csv 的 78 條 Mode 22 反推。
# 這幾顆不用花時間做家族探索。
KNOWN_FAMILIES = {"770": "BC", "7C6": "B0", "7E0": "E0"}

# 點名用的識別區 DID。任何講 UDS 的模組幾乎都會對其中一個有反應，
# 正回應或負回應都算存在。
LIVENESS = ["22F190", "22F180"]


def roll_call(e: Elm, log=print) -> dict[str, str]:
    """對每個位址送識別區查詢。回傳 {header: 判定依據}，只含活著的。"""
    alive: dict[str, str] = {}
    for header, note in MODULE_HEADERS:
        verdict = ""
        for did in LIVENESS:
            r = request(e, header, did, timeout=1.5)
            if r.alive:
                verdict = f"{did} {r.describe()}"
                break
        if verdict:
            alive[header] = verdict
            log(f"  [活] {header}  {verdict}" + (f"   ({note})" if note else ""))
        else:
            log(f"  [--] {header}  沒回應")
        e.set_header("7DF")
    return alive


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


def sweep_family(e: Elm, header: str, fam: str, log=print) -> dict[str, str]:
    """把一個家族的 00~FF 全問一遍，回傳 {CMD: payload}。"""
    out: dict[str, str] = {}
    for lo in range(0x100):
        cmd = f"22{fam}{lo:02X}"
        r = request(e, header, cmd, timeout=1.2)
        if r.payload is not None:
            out[cmd] = r.payload
            log(f"  [DID] {header}/{cmd}  {r.payload[:60]}"
                + ("…" if len(r.payload) > 60 else ""))
        if (lo + 1) % 64 == 0:
            log(f"  {header}/{fam} 進度 {lo + 1}/256，累計 {len(out)} 個")
    return out
