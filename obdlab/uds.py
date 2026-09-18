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
"""

from __future__ import annotations

from dataclasses import dataclass

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
}


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
        if c.startswith("22"):
            return "62" + c[2:]
        if c.startswith("01"):
            return "41" + c[2:]
        if c.startswith("21"):
            return "61" + c[2:]
        return ""

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


def request(e: Elm, header: str, cmd: str, timeout: float = 2.0) -> Resp:
    """對某個模組送一道查詢。Header 只在需要時切換，省一道指令。"""
    e.set_header(header)
    raw = e.send(cmd, timeout=timeout)
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
