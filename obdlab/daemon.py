"""常駐連線。開一次埠、一直握著，所有指令走 Unix socket 進來。

為什麼需要
----------
實測 macOS **無法從指令列建立** 這顆傳輸器的 RFCOMM 連線：`/dev/cu.` 節點
在配對後就一直存在，開埠瞬間成功（0.00 秒），但寫入不會觸發連線，
`system_profiler` 全程顯示 Not Connected。只有在系統設定裡手動按連線
那條鏈路才會起來，而且閒置就掉。

所以「每道指令重開一次連線」的架構在這台機器上不可用。改成一個常駐行程
握著那條連線，並定期送 ATI 當心跳避免閒置斷線。
"""

from __future__ import annotations

import os
import socket
import sys
import threading
import time
from pathlib import Path

from elm import Elm, candidate_ports

SOCK = Path(__file__).parent / "data" / "obdlab.sock"
KEEPALIVE_SEC = 20.0


class Daemon:
    def __init__(self, port: str, verbose: bool = False):
        self.elm = Elm(port, verbose=verbose)
        self.lock = threading.Lock()
        self.last_activity = time.time()
        self.running = True

    def keepalive(self) -> None:
        """閒置時定期戳一下，免得藍牙鏈路被回收。斷了就只能請人重連。"""
        while self.running:
            time.sleep(2.0)
            if time.time() - self.last_activity < KEEPALIVE_SEC:
                continue
            with self.lock:
                try:
                    r = self.elm.send("ATI", timeout=3.0)
                    self.last_activity = time.time()
                    if not r.strip():
                        print("[心跳] 沒有回應，鏈路可能已斷", flush=True)
                except Exception as exc:
                    print(f"[心跳] 失敗 {exc}", flush=True)

    def handle(self, conn: socket.socket) -> None:
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
        line = data.decode("utf-8").strip()

        if line == "__PING__":
            conn.sendall(b"PONG\n")
            return
        if line == "__QUIT__":
            self.running = False
            conn.sendall(b"BYE\n")
            return

        # 格式：<逾時秒數> <指令>
        try:
            tmo_s, cmd = line.split(" ", 1)
            tmo = float(tmo_s)
        except ValueError:
            tmo, cmd = 3.0, line

        with self.lock:
            self.last_activity = time.time()
            try:
                raw = self.elm.send(cmd, timeout=tmo)
            except Exception as exc:
                raw = f"__ERROR__ {exc}"
        # 回應可能含換行，用長度前綴避免切錯
        payload = raw.encode("utf-8", "replace")
        conn.sendall(f"{len(payload)}\n".encode() + payload)

    def serve(self) -> None:
        if SOCK.exists():
            SOCK.unlink()
        SOCK.parent.mkdir(parents=True, exist_ok=True)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(SOCK))
        srv.listen(8)
        srv.settimeout(1.0)
        threading.Thread(target=self.keepalive, daemon=True).start()
        print(f"常駐連線就緒，socket {SOCK}", flush=True)
        try:
            while self.running:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                with conn:
                    try:
                        self.handle(conn)
                    except Exception as exc:
                        print(f"[處理失敗] {exc}", flush=True)
        finally:
            srv.close()
            SOCK.unlink(missing_ok=True)
            self.elm.close()
            print("常駐連線結束", flush=True)


class Client:
    """跟 Elm 同樣的介面，但指令是丟給常駐行程執行。"""

    def __init__(self):
        self.active_header = "7DF"
        self.last_cmd = ""
        self.verbose = False

    @staticmethod
    def available() -> bool:
        if not SOCK.exists():
            return False
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2.0)
            s.connect(str(SOCK))
            s.sendall(b"__PING__\n")
            ok = s.recv(16).startswith(b"PONG")
            s.close()
            return ok
        except Exception:
            return False

    def send(self, cmd: str, timeout: float = 3.0) -> str:
        cmd = cmd.strip().upper().replace(" ", "")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout + 10.0)
        s.connect(str(SOCK))
        s.sendall(f"{timeout} {cmd}\n".encode())

        head = b""
        while not head.endswith(b"\n"):
            head += s.recv(1)
        n = int(head)
        buf = b""
        while len(buf) < n:
            buf += s.recv(n - len(buf))
        s.close()

        self.last_cmd = cmd
        if cmd.startswith("ATSH"):
            self.active_header = cmd[4:]
        return buf.decode("utf-8", "replace")

    def set_header(self, header: str) -> None:
        if self.active_header != header:
            self.send(f"ATSH{header}")

    def init(self) -> str:
        return self.send("ATI", timeout=3.0).strip()

    def close(self) -> None:
        pass


def main() -> None:
    port = sys.argv[1] if len(sys.argv) > 1 else None
    if not port:
        ports = candidate_ports()
        if not ports:
            sys.exit("找不到序列埠")
        port = ports[0]
    print(f"連線 {port} …", flush=True)
    d = Daemon(port, verbose=os.environ.get("OBDLAB_VERBOSE") == "1")
    print("ELM 版本：", d.elm.init(), flush=True)
    d.serve()


if __name__ == "__main__":
    main()
