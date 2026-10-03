"""BLE 傳輸層：直接用 CoreBluetooth，不經過 bleak。

為什麼不用 bleak
----------------
bleak 1.1.1 在這台機器上會報「Bluetooth device is turned off」，但實測
CoreBluetooth 授權是 allowedAlways、狀態是 poweredOn。原因在
CentralManagerDelegate.init() 用 threading Event 等一秒狀態回呼，
而那個回呼要靠主執行緒服務 main dispatch queue 才送得到 ——
它在主執行緒上阻塞等一個需要主執行緒才能送達的東西，自己鎖死自己。

為什麼改用 BLE
--------------
傳統 SPP 那條路實測走不通：`/dev/cu.Android-Vlink` 在配對後一直存在，
開埠瞬間成功，但寫入不會觸發 RFCOMM 連線，`system_profiler` 全程
Not Connected。macOS 沒有提供從指令列建立 SPP 連線的介面。
BLE 的 central 角色可以完全程式化，這個限制就消失了。

執行緒模型
----------
CoreBluetooth 的回呼要靠主執行緒轉 run loop 才會送達，所以：
  主執行緒   → 一直呼叫 pump()，服務 run loop 並執行排隊的寫入
  工作執行緒 → 呼叫 send()，把請求排進佇列然後等事件
只有主執行緒碰 CoreBluetooth 物件，不會有跨執行緒問題。
"""

from __future__ import annotations

import threading
import time

import objc
from CoreBluetooth import CBCentralManager
from Foundation import NSData, NSDate, NSObject, NSRunLoop, NSUUID

# 各家 ELM327 BLE 的序列橋接服務。Vlink 是 18F0（2AF0 收、2AF1 寫），
# 常見的「OBDII」白牌是 FFF0（FFF1 收、FFF2 寫），也有用 FFE0 的。
# 特徵值不寫死，從屬性挑：能 notify/indicate 的收，能寫的寫。
SERVICES = ("18F0", "FFF0", "FFE0")

PROP_WRITE_NO_RESP = 0x04
PROP_WRITE = 0x08
PROP_NOTIFY = 0x10
PROP_INDICATE = 0x20
WRITE_WITH_RESPONSE = 0
WRITE_WITHOUT_RESPONSE = 1
MTU = 20                  # BLE 預設每包上限，指令都很短但還是切一下


class BleError(RuntimeError):
    pass


class _Delegate(NSObject):
    def initWithOwner_(self, owner):
        self = objc.super(_Delegate, self).init()
        self.owner = owner
        return self

    # ── Central ──
    def centralManagerDidUpdateState_(self, m):
        if m.state() == 5:                      # poweredOn
            self.owner._on_powered_on()

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
            self, m, p, adv, rssi):
        name = (p.name() or adv.get("kCBAdvDataLocalName") or "")
        if self.owner.name_hint.upper() in name.upper():
            m.stopScan()
            self.owner._attach(p)

    def centralManager_didConnectPeripheral_(self, m, p):
        p.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, m, p, e):
        self.owner.fail = f"連線失敗 {e}"

    def centralManager_didDisconnectPeripheral_error_(self, m, p, e):
        self.owner.connected = False

    # ── Peripheral ──
    def peripheral_didDiscoverServices_(self, p, e):
        for s in (p.services() or []):
            if str(s.UUID()).upper() in SERVICES:
                p.discoverCharacteristics_forService_(None, s)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, p, s, e):
        for c in (s.characteristics() or []):
            props = c.properties()
            if props & (PROP_NOTIFY | PROP_INDICATE) \
                    and self.owner.notify_char is None:
                self.owner.notify_char = c
                p.setNotifyValue_forCharacteristic_(True, c)
            if props & (PROP_WRITE | PROP_WRITE_NO_RESP) \
                    and self.owner.write_char is None:
                self.owner.write_char = c
                self.owner.write_type = (WRITE_WITH_RESPONSE
                                         if props & PROP_WRITE
                                         else WRITE_WITHOUT_RESPONSE)
        if self.owner.notify_char and self.owner.write_char:
            self.owner.connected = True

    def peripheral_didUpdateValueForCharacteristic_error_(self, p, c, e):
        data = c.value()
        if data:
            self.owner._on_rx(bytes(data))


class BleElm:
    """介面與 elm.Elm 相同，底層走 BLE。"""

    INIT = ["ATZ", "ATE0", "ATL0", "ATH0", "ATS0", "ATAL",
            "ATST32", "ATAT1", "ATSP6"]

    def __init__(self, target_uuid: str | None = None,
                 name_hint: str = "VLINK", verbose: bool = False):
        self.target_uuid = target_uuid
        self.name_hint = name_hint
        self.verbose = verbose

        self.active_header = "7DF"
        self.last_cmd = ""

        self.notify_char = None
        self.write_char = None
        self.write_type = WRITE_WITH_RESPONSE
        self.connected = False
        self.fail: str | None = None

        self._rx = bytearray()
        self._lock = threading.Lock()
        self._req: dict | None = None        # 同時只會有一道指令

        self._delegate = _Delegate.alloc().initWithOwner_(self)
        self._mgr = CBCentralManager.alloc().initWithDelegate_queue_(
            self._delegate, None)

    # ── 連線 ──────────────────────────────────────────────────────────
    def _on_powered_on(self):
        if self.target_uuid:
            ps = self._mgr.retrievePeripheralsWithIdentifiers_(
                [NSUUID.alloc().initWithUUIDString_(self.target_uuid)])
            if ps:
                self._attach(ps[0])
                return
        self._mgr.scanForPeripheralsWithServices_options_(None, None)

    def _attach(self, p):
        self._peripheral = p
        p.setDelegate_(self._delegate)
        self._mgr.connectPeripheral_options_(p, None)

    def connect(self, timeout: float = 20.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline and not self.connected:
            if self.fail:
                raise BleError(self.fail)
            self.pump(0.05)
        if not self.connected:
            raise BleError(f"{timeout} 秒內沒有連上 {self.name_hint}。"
                           "確認車輛電門開著、傳輸器有電，"
                           "而且沒有被手機 App 佔用。")

    # ── 主執行緒：轉 run loop 並執行排隊的寫入 ────────────────────────
    def pump(self, seconds: float = 0.05) -> None:
        with self._lock:
            req = self._req
            if req is not None and not req["written"]:
                req["written"] = True
                self._rx.clear()
                self._write((req["cmd"] + "\r").encode("ascii"))
                req["deadline"] = time.time() + req["timeout"]
            elif (req is not None and req["stream"] and not req["stopped"]
                  and time.time() >= req["stream_end"]):
                # 串流時間到：送一個 CR 讓 ELM 停止監聽並吐 '>'
                req["stopped"] = True
                self._write(b"\r")
                req["deadline"] = time.time() + req["timeout"]

        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(seconds))

        with self._lock:
            req = self._req
            if req is not None and req["written"] and (
                    not req["stream"] or req["stopped"]):
                text = self._rx.decode("ascii", "replace")
                if ">" in text or time.time() > req["deadline"]:
                    req["resp"] = text
                    self._req = None
                    req["event"].set()

    def _write(self, payload: bytes) -> None:
        for i in range(0, len(payload), MTU):
            chunk = payload[i:i + MTU]
            self._peripheral.writeValue_forCharacteristic_type_(
                NSData.dataWithBytes_length_(chunk, len(chunk)),
                self.write_char, self.write_type)

    # ── 工作執行緒：送指令並等回應 ────────────────────────────────────
    def send(self, cmd: str, timeout: float = 3.0) -> str:
        return self._submit(cmd, timeout, stream=0.0)

    def monitor(self, cmd: str, seconds: float) -> str:
        """送串流指令（ATMA 之類），收 seconds 秒後送 CR 停止。"""
        return self._submit(cmd, 3.0, stream=seconds)

    def _submit(self, cmd: str, timeout: float, stream: float) -> str:
        cmd = cmd.strip().upper().replace(" ", "")
        ev = threading.Event()
        req = {"cmd": cmd, "timeout": timeout, "event": ev,
               "written": False, "resp": "", "deadline": 0.0,
               "stream": stream > 0, "stopped": False,
               "stream_end": time.time() + stream}
        with self._lock:
            if self._req is not None:
                raise BleError("已有指令在執行中")
            self._req = req
        if not ev.wait(timeout + stream + 5.0):
            with self._lock:
                self._req = None
            raise BleError(f"{cmd} 等不到回應")

        self.last_cmd = cmd
        if cmd.startswith("ATSH"):
            self.active_header = cmd[4:]
        if self.verbose:
            print(f"  TX {cmd}  RX {req['resp']!r}", flush=True)
        return req["resp"]

    def _on_rx(self, data: bytes) -> None:
        with self._lock:
            self._rx.extend(data)

    # ── 與 Elm 對齊的其餘介面 ─────────────────────────────────────────
    def set_header(self, header: str) -> None:
        if self.active_header != header:
            self.send(f"ATSH{header}")

    def init(self) -> str:
        version = ""
        for attempt in range(3):
            raw = self.send("ATZ", timeout=6.0)
            if raw.strip():
                version = " ".join(raw.split()).replace(">", "").strip()
                break
            time.sleep(0.8)
        else:
            raise BleError("ATZ 連續三次沒有回應")
        for cmd in self.INIT[1:]:
            raw = self.send(cmd, timeout=3.0)
            if "ERROR" in raw.upper():
                raise BleError(f"初始化在 {cmd} 失敗：{raw!r}")
        return version

    def close(self) -> None:
        try:
            if getattr(self, "_peripheral", None):
                self._mgr.cancelPeripheralConnection_(self._peripheral)
        except Exception:
            pass
