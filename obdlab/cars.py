"""車型設定：每台車的模組位址、回應位址、點名方式與廣播封包假設。

為什麼要分車型
--------------
Hyundai 的模組回應位址一律是請求 +8（770→778、7C6→7CE），ELM327 會自動
過濾、自動送流量控制，所以先前完全不用管。Nissan 不是：BCM 745→765、
儀表 743→763，差 0x20，有些甚至不規則（TCU 746→783）。不明確設定的話：

1. ELM 只收請求 +8 的位址，回應會被濾掉，看起來像模組不存在
2. 多幀回應的流量控制會送到 回應 −8（765−8=75D），模組等不到就中斷，
   長回應只剩第一幀

所以每個模組都要記下回應位址，切換時明確設 ATCRA 與 ATFCSH。

資料也分開存（data/ 是 NX4，data/k13/ 是 K13），兩台車的快照不能混比。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

DATA_ROOT = Path(__file__).parent / "data"


@dataclass
class Broadcast:
    """一個廣播封包的假設解讀，來源是其他同代 Nissan，K13 要實車驗證。"""
    desc: str
    decode: object = None         # fn(bytes) -> str，None 表示只看原始值


@dataclass
class Car:
    key: str
    name: str
    data_dir: Path
    # (請求位址, 回應位址或 None=請求+8, 說明)
    modules: list = field(default_factory=list)
    liveness: list = field(default_factory=list)
    known_families: dict = field(default_factory=dict)
    broadcasts: dict = field(default_factory=dict)

    def response_id(self, header: str) -> str:
        """模組的回應位址。普查結果優先，其次是設定，最後假設 +8。"""
        from store import load_census
        census = load_census(self)
        if header in census:
            return census[header]
        for req, resp, _ in self.modules:
            if req == header and resp:
                return resp
        return f"{int(header, 16) + 8:03X}"

    def note(self, header: str) -> str:
        for req, _, note in self.modules:
            if req == header:
                return note
        return ""


# ── Hyundai Tucson NX4（原本的設定，行為不變）──────────────────────────

NX4 = Car(
    key="nx4",
    name="Hyundai Tucson NX4",
    data_dir=DATA_ROOT,
    modules=[
        ("7A5", None, "智慧鑰匙 SMK 候選 —— 實車兩次點名都沒回應，應該不在這個位址"),
        ("770", None, "車身 IGMP（車門、門鎖、大燈、倒車）"),
        ("7C6", None, "儀表 CLU（里程、油量、保養）"),
        ("7E0", None, "引擎 ECM"),
        ("7E1", None, "變速箱 TCU（零件號 95441-3D210）"),
        ("7E2", None, "活著，只有識別區"),
        ("7E3", None, "油電相關（字串自報 GNXDH22GAMS0）"),
        ("7E4", None, "電池管理 BMS（220102/220103 各 32 byte 電芯資料）"),
        ("7A0", None, "胎壓 TPMS"),
        ("7D0", None, "前方雷達 FCA（22FD10 字串自報 LogicRadar / FCA）"),
        ("7D2", None, "活著但找不到資料家族"),
        ("7D4", None, "未知，2201 家族有資料"),
        ("7B1", None, "未知，22C0 家族有資料"),
        ("7B3", None, "空調（2201xx 是溫度與風門）"),
        ("7C4", None, "未知，2201 與 22FD 家族有資料"),
        ("7D1", None, "ABS（OBD.csv 有列，點名沒回應）"),
        ("7D6", None, ""), ("7E5", None, ""), ("7A1", None, ""), ("780", None, ""),
    ],
    liveness=["22F190", "22F180"],
    # 由 OBD.csv 的 78 條 Mode 22 反推，這幾顆不用花時間做家族探索
    known_families={"770": "BC", "7C6": "B0", "7E0": "E0"},
)


# ── Nissan March K13 ──────────────────────────────────────────────────


def _u24(b: bytes, i: int) -> int:
    return (b[i] << 16) | (b[i + 1] << 8) | b[i + 2]


def _rpm(b: bytes) -> str:
    raw = (b[0] << 8) | b[1]
    # Qashqai 文件：15-bit、0.25 rpm；Juke 設定檔：÷7。兩個都印，對儀表選一個
    return f"A–B={raw}  ÷4={raw / 4:.0f} rpm  ÷7={raw / 7:.0f} rpm"


def _speed(b: bytes) -> str:
    return f"E–F={((b[4] << 8) | b[5]) / 100:.2f} km/h"


def _wheels(b: bytes) -> str:
    return (f"A–B={((b[0] << 8) | b[1]) * 0.005:.1f}  "
            f"C–D={((b[2] << 8) | b[3]) * 0.005:.1f} km/h  " + _speed(b))


K13 = Car(
    key="k13",
    name="Nissan March K13",
    data_dir=DATA_ROOT / "k13",
    # 位址來自 Leaf 的模組表與 Qashqai 文件，K13 實際有哪些要點名確認。
    # 回應位址不規則的（TCU、VSP）照 Leaf 表填，跑 census 會用實測覆蓋。
    modules=[
        ("7E0", "7E8", "引擎 ECM（HR12DE/HR15DE）"),
        ("7E1", "7E9", "變速箱 CVT/AT"),
        ("745", "765", "BCM（含胎壓 AIR PRESSURE MONITOR）"),
        ("743", "763", "儀表 M&A（里程、油量）"),
        ("740", "760", "ABS"),
        ("742", "762", "EPS 電動輔助轉向"),
        ("744", "764", "空調 HVAC"),
        ("74D", "76D", "IPDM E/R"),
        ("752", "772", "安全氣囊"),
        ("747", "767", "影音 Multi AV"),
        ("746", "783", "TCU（Leaf 表，K13 可能沒有）"),
        ("73F", "761", "VSP（Leaf 表，K13 可能沒有）"),
    ],
    # 這一代 Nissan 多半講 KWP：2180 是 ECU 識別（零件號），
    # 22F190 是 UDS 的 VIN，3E01 是 TesterPresent。任何回應（含負回應）都算活著
    liveness=["2180", "22F190", "3E01"],
    known_families={},
    broadcasts={
        "180": Broadcast("轉速", _rpm),
        "280": Broadcast("車速（儀表）", _speed),
        "284": Broadcast("前輪輪速與車速（ABS）", _wheels),
        "285": Broadcast("後輪輪速（ABS）",
                         lambda b: f"A–B={((b[0] << 8) | b[1]) * 0.005:.1f}  "
                                   f"C–D={((b[2] << 8) | b[3]) * 0.005:.1f} km/h"),
        "551": Broadcast("水溫", lambda b: f"A−40={b[0] - 40} °C"),
        "5C5": Broadcast("里程 B–D；byte A 在 Juke 是油量、在 Qashqai 是狀態位元",
                         lambda b: f"B–D={_u24(b, 1)} km  A={b[0]} (0x{b[0]:02X})"),
        "2DE": Broadcast("剩餘可跑里程（Qashqai）",
                         lambda b: f"G–H={((b[6] << 8) | b[7]) / 10:.1f} km"
                         if len(b) >= 8 else ""),
        "54C": Broadcast("剩餘可跑里程（Juke）"),
        "385": Broadcast("四輪胎壓（Leaf）；K13 儀表不顯示數值，可能沒有廣播",
                         lambda b: "C–F=" + " ".join(
                             f"{x * 0.25:.2f}" for x in b[2:6]) + " psi"
                         if len(b) >= 6 else ""),
        "60D": Broadcast("車門與 IGN 狀態"),
        "6F6": Broadcast("電瓶電壓（Juke）"),
    },
)

CARS = {c.key: c for c in (NX4, K13)}
DEFAULT = "nx4"

_current = CARS[DEFAULT]


def current() -> Car:
    return _current


def use(key: str) -> Car:
    global _current
    if key not in CARS:
        raise SystemExit(f"不認識的車型 {key}，可用：{', '.join(CARS)}")
    _current = CARS[key]
    _current.data_dir.mkdir(parents=True, exist_ok=True)
    return _current
