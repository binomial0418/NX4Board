"""UDS 請求與回應判讀。

這裡刻意把幾個實車踩過的坑寫成規則，不要再犯：

1. 負回應（7F <sid> <nrc>）代表模組存在但不支援這個 DID，是最有力的存在
   證明。第一版點名只認正回應，結果把 770 判成不存在 —— 而它整份日誌都在
   正常回答 22BC03 到 22BC10。
2. 不要用字串搜尋定位 PID。App 曾經寫成 indexOf('0B') 去找 MAP，等於在整串
   十六進位字元裡找那兩個字。704~767 rpm 的高位元組正好是 0x0B，回應變成
   410C0B54，就把轉速的低位元組當成 MAP 讀走。要照 PID 的固定長度逐段走。
3. 識別區（22F1xx）裝的是零件號與版本字串，永遠不變。它一旦在兩次取樣間
   不一樣，就是多幀組裝錯位，整份資料的可信度要打折扣。當成金絲雀用。
4. 回應位址不一定是請求 +8（Nissan BCM 745→765）。切模組時要一起設
   接收過濾（ATCRA）與流量控制（ATFCSH），見 select_module()。
"""

from __future__ import annotations

from dataclasses import dataclass

import time

import cars
from elm import Elm, clean_response

# 標準 Mode 01 PID 的資料長度，用來逐段走訪合併查詢的回應
PID_LEN = {
    "04": 1, "05": 1, "0B": 1, "0C": 2, "0D": 1, "0F": 1, "10": 2, "11": 1,
    "1F": 2, "21": 2, "2F": 1, "31": 2, "33": 1, "42": 2, "43": 2, "46": 1,
    "5B": 1, "5C": 1, "5E": 2, "61": 1, "62": 1, "63": 2, "67": 3, "6B": 5,
    "70": 10, "74": 5, "87": 5, "9A": 6,
}

NRC = {
    "11": "服務不支援", "12": "子功能不支援", "13": "長度錯誤",
    "22": "條件不符", "31": "要求超出範圍", "33": "安全存取被拒",
    "7E": "此會談不支援", "7F": "此會談不支援服務",
    "78": "處理中，稍後回應", "80": "目前會談不支援（KWP）",
}

# 正回應的服務碼 = 請求 + 0x40。這幾個會用到。
_POSITIVE = {"22": "62", "21": "61", "01": "41", "09": "49",
             "10": "50", "3E": "7E"}


@dataclass
class Resp:
    header: str
    cmd: str
    raw: str
    hex: str

    @property
    def payload(self) -> str | None:
        """正回應的資料段。22xxxx 的簽章是 62xxxx，01xx 的是 41xx。"""
        sig = self.signature
        if not sig:
            return None
        i = self.hex.find(sig)
        return None if i == -1 else self.hex[i + len(sig):]

    @property
    def signature(self) -> str:
        c = self.cmd
        pos = _POSITIVE.get(c[:2])
        return pos + c[2:] if pos else ""

    @property
    def negative(self) -> tuple[str, str] | None:
        """回傳 (服務碼, 原因碼)，沒有負回應則 None。"""
        i = self.hex.find("7F")
        if i == -1 or len(self.hex) < i + 6:
            return None
        return self.hex[i + 2:i + 4], self.hex[i + 4:i + 6]

    @property
    def alive(self) -> bool:
        """模組有沒有回話。正回應或負回應都算。"""
        return self.payload is not None or self.negative is not None

    def describe(self) -> str:
        if self.payload is not None:
            return f"正回應 {self.payload}"
        neg = self.negative
        if neg:
            sid, nrc = neg
            return f"負回應 7F{sid}{nrc}（{NRC.get(nrc, '原因碼未知')}）"
        return f"無回應 {self.raw.strip()!r}"


def select_module(e: Elm, header: str) -> None:
    """切到某個模組：Header、接收過濾、流量控制一起設，只在需要時送指令。

    回應位址是請求 +8 時交給 ELM 自動處理（Hyundai 一路都是這樣）。
    不是的話：
      ATCRA <回應>    只收那個位址，不然回應會被濾掉
      ATFCSH <請求>   多幀回應的流量控制送回請求位址；預設會送到 回應−8，
                      Nissan 的 765−8=75D 沒有人收，長回應只剩第一幀
      ATFCSD300000 + ATFCSM1  啟用上面那組自訂流量控制
    7DF 是廣播查詢，一律回到自動。
    """
    e.set_header(header)
    want = "AUTO"
    if header != "7DF":
        resp = cars.current().response_id(header)
        if int(resp, 16) != int(header, 16) + 8:
            want = resp
    have = getattr(e, "rx_filter", "AUTO")
    if want == have:
        return
    if want == "AUTO":
        e.send("ATCRA")            # 不帶參數 = 清除接收過濾
        e.send("ATFCSM0")
    else:
        e.send(f"ATCRA{want}")
        e.send(f"ATFCSH{header}")
        e.send("ATFCSD300000")
        e.send("ATFCSM1")
    e.rx_filter = want


# 診斷會談。Nissan 這一代講 KWP，BCM／儀表的資料多半要先進 10 C0
# （CONSULT 用的會談）才讀得到。會談閒置幾秒就自動回預設，所以每次
# 對某模組送查詢前，若距上次送出超過 SESSION_STALE 秒就重新進入。
# 進入會談不是寫入，模組逾時後自己會回到預設會談。
SESSION_STALE = 2.0
_session: dict[str, object] = {"sub": None, "last": {}}


def use_session(sub: str | None) -> None:
    """設定要用的會談子功能（例如 "C0"），None 表示不進會談。"""
    _session["sub"] = sub.upper() if sub else None
    _session["last"] = {}


def _ensure_session(e: Elm, header: str) -> None:
    sub = _session["sub"]
    if not sub or header == "7DF":
        return
    last: dict = _session["last"]  # type: ignore[assignment]
    if time.time() - last.get(header, 0.0) < SESSION_STALE:
        return
    raw = e.send(f"10{sub}", timeout=1.5)
    hexs = clean_response(raw)
    if f"50{sub}" not in hexs and getattr(e, "verbose", False):
        print(f"  {header} 進入會談 10{sub} 失敗：{raw.strip()!r}")


def request(e: Elm, header: str, cmd: str, timeout: float = 2.0) -> Resp:
    """對某個模組送一道查詢。位址相關的設定只在需要時切換，省指令。"""
    select_module(e, header)
    _ensure_session(e, header)
    raw = e.send(cmd, timeout=timeout)
    if _session["sub"] and header != "7DF":
        _session["last"][header] = time.time()  # type: ignore[index]
    return Resp(header, cmd.upper(), raw, clean_response(raw))


def walk_mode01(hex_str: str, pids: list[str]) -> dict[str, str]:
    """照 PID 長度逐段走訪 41 回應，回傳 {pid: 資料十六進位}。

    ECU 只會回它支援的 PID，而且順序跟請求一致。遇到不認識的就停手，
    不要往下猜 —— 那正是當初把轉速讀成 MAP 的原因。
    """
    i = hex_str.find("41")
    if i == -1:
        return {}
    out: dict[str, str] = {}
    p = i + 2
    while p + 2 <= len(hex_str):
        pid = hex_str[p:p + 2]
        n = PID_LEN.get(pid)
        if n is None or pid not in pids:
            break
        if p + 2 + n * 2 > len(hex_str):
            break
        out[pid] = hex_str[p + 2:p + 2 + n * 2]
        p += 2 + n * 2
    return out


def is_static_did(cmd: str) -> bool:
    """識別區 DID：零件號、軟體版本、序號，理論上永不改變。"""
    return cmd.upper().startswith("22F1")


def byte_label(index: int) -> str:
    """OBD.csv 的位元組標號：A..Z, AA..AZ, BA..BZ（試算表欄位那種進位）。

    22E004 的電瓶 SOC 在 CSV 裡寫成 AD，對應 index 29。第一版寫成
    「AA 之後接 AA+1」，印出 AC+2 這種 CSV 裡不存在的標號，對照公式會錯位。
    """
    n = index + 1
    out = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        out = chr(0x41 + r) + out
    return out


def popcount(x: int) -> int:
    return bin(x).count("1")
