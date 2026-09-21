"""ELM327 連線層：Mac 直接走藍牙序列埠對話，不經過手機。

為什麼繞過 App
--------------
先前每一輪是「改 Dart、建 APK、上車測、匯出日誌、貼回來分析」，一輪要
好幾小時。而回顧起來大多數時間不是在找車上的訊號，是在找工具本身的錯
（字串搜尋誤讀 MAP、點名只認正回應、實驗沒有對照組）。這一層讓迴路縮到
幾秒，代價是 Mac 要待在車上。
"""

from __future__ import annotations

import glob
import re
import time

import serial


class ElmError(RuntimeError):
    pass


def candidate_ports() -> list[str]:
    """列出可能的序列埠。

    macOS 把藍牙 SPP 掛成 /dev/cu.<裝置名>。內建那兩個要排除：
    Bluetooth-Incoming-Port 是給別人連進來的，debug-console 是系統的。
    """
    skip = ("Bluetooth-Incoming-Port", "debug-console", "wlan-debug")
    return [p for p in sorted(glob.glob("/dev/cu.*"))
            if not any(s in p for s in skip)]


class Elm:
    """一條 ELM327 連線。指令是序列的，回應以 '>' 提示符結尾。"""

    # 與 App 相同的初始化序列，行為才對得起來。
    # ATAL 很關鍵：沒有它長回應會被截斷。
    # ATSP6 直接鎖 ISO 15765-4 CAN 11-bit 500K，省掉自動偵測的時間。
    INIT = ["ATZ", "ATE0", "ATL0", "ATH0", "ATS0", "ATAL",
            "ATST32", "ATAT1", "ATSP6"]

    def __init__(self, port: str, baud: int = 38400, timeout: float = 5.0,
                 verbose: bool = False):
        self.port = port
        self.verbose = verbose
        self.ser = serial.Serial(port, baud, timeout=timeout)
        self.active_header = "7DF"
        self.last_cmd = ""

        # 藍牙 RFCOMM 剛建立時還不穩，馬上送指令常常整包掉。
        # 實測第一次連線正常、第二次整個沒回應就是這個原因。
        # 先等一下、清乾淨緩衝區，再送一個裸 CR 讓 ELM 回到指令狀態。
        time.sleep(0.5)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()
        try:
            self.ser.write(b"\r")
            self.ser.flush()
            time.sleep(0.2)
            self.ser.reset_input_buffer()
        except Exception:
            pass

    # ── 低階 ────────────────────────────────────────────────────────────
    def close(self) -> None:
        try:
            self.ser.close()
        except Exception:
            pass

    def _read_until_prompt(self, timeout: float) -> str:
        """讀到 '>' 為止。ELM327 每次回應結束都會吐這個提示符。"""
        deadline = time.time() + timeout
        buf = bytearray()
        while time.time() < deadline:
            chunk = self.ser.read(256)
            if chunk:
                buf.extend(chunk)
                if b">" in chunk:
                    break
            else:
                # 已經收到東西又停了一小段，視為結束（有些相容晶片不吐提示符）
                if buf:
                    break
        return buf.decode("ascii", errors="replace")

    def send(self, cmd: str, timeout: float = 3.0) -> str:
        """送一道指令，回傳原始文字回應。"""
        cmd = cmd.strip().upper().replace(" ", "")
        self.ser.reset_input_buffer()
        self.ser.write((cmd + "\r").encode("ascii"))
        self.ser.flush()
        raw = self._read_until_prompt(timeout)
        self.last_cmd = cmd
        if cmd.startswith("ATSH"):
            self.active_header = cmd[4:]
        if self.verbose:
            print(f"  TX {cmd}  RX {raw!r}")
        return raw

    # ── 初始化 ──────────────────────────────────────────────────────────
    def init(self) -> str:
        """跑初始化序列，回傳 ATZ 報出來的版本字串。

        ATZ 重試三次：藍牙連線剛起來時第一道指令常常沒有回應，
        但第二道就正常了。直接放棄會讓整個工具看起來時好時壞。
        """
        version = ""
        for attempt in range(3):
            raw = self.send("ATZ", timeout=6.0)
            if raw.strip():
                version = " ".join(raw.split()).replace(">", "").strip()
                break
            if self.verbose:
                print(f"  ATZ 第 {attempt + 1} 次沒回應，重試")
            time.sleep(0.8)
        else:
            raise ElmError("ATZ 連續三次沒有回應。傳輸器可能睡著了，"
                           "或被手機 App 佔用。")
        time.sleep(0.3)

        for cmd in self.INIT[1:]:      # ATZ 已經單獨處理過
            raw = self.send(cmd, timeout=3.0)
            if "ERROR" in raw.upper():
                raise ElmError(f"初始化在 {cmd} 失敗：{raw!r}")
        return version

    def set_header(self, header: str) -> None:
        if self.active_header != header:
            self.send(f"ATSH{header}")


# ── 回應整理 ────────────────────────────────────────────────────────────

_LINE_PREFIX = re.compile(r"^[0-9A-F]:")


def clean_response(raw: str) -> str:
    """把 ELM327 的文字回應整理成連續的十六進位字串。

    ATAL 開著時，長回應會長這樣：
        014
        0:62BC03FDEE
        1:206 30A6404
        2:00AAAAAAAA
    第一行是總長度，後面是編號的資料行。App 那邊用一條全域正規式把
    「十六進位字元加冒號」通殺，剛好沒出事但不夠嚴謹。這裡逐行處理：
    去掉行首編號、丟掉單獨的長度行，其餘才拼起來。
    """
    out = []
    for line in raw.replace("\r", "\n").split("\n"):
        line = line.strip().replace(" ", "").replace(">", "").upper()
        if not line:
            continue
        if _LINE_PREFIX.match(line):
            out.append(line[2:])
            continue
        # 單獨一行的長度標示（1~3 位十六進位）不是資料
        if len(line) <= 3 and re.fullmatch(r"[0-9A-F]+", line):
            continue
        if re.fullmatch(r"[0-9A-F]+", line):
            out.append(line)
    return "".join(out)


AT_KEYWORDS = ("NODATA", "UNABLETOCONNECT", "BUSERROR", "CANERROR",
               "DATAERROR", "ERROR", "SEARCHING", "STOPPED", "BUFFERFULL",
               "OK")


def is_at_noise(raw: str) -> bool:
    compact = raw.upper().replace(" ", "").replace("\r", "").replace("\n", "")
    return any(k in compact for k in AT_KEYWORDS)
