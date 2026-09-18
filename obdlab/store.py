"""把掃描結果與快照存成 JSON，實驗中斷了也不用重來。"""

from __future__ import annotations

import json
import time
from pathlib import Path

DATA = Path(__file__).parent / "data"
DATA.mkdir(exist_ok=True)

DIDS = DATA / "dids.json"          # 已知 DID：{"HEADER|CMD": 最後一次的 payload}
MODULES = DATA / "modules.json"    # 點名結果
SNAPS = DATA / "snapshots"         # 每張快照一個檔


def _load(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text("utf-8"))


def _save(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=1), "utf-8")


def load_dids() -> dict[str, str]:
    return _load(DIDS, {})


def save_dids(d: dict[str, str]) -> None:
    _save(DIDS, d)


def load_modules() -> dict[str, str]:
    return _load(MODULES, {})


def save_modules(m: dict[str, str]) -> None:
    _save(MODULES, m)


def snapshot_files() -> list[Path]:
    SNAPS.mkdir(parents=True, exist_ok=True)
    return sorted(SNAPS.glob("*.json"))


def save_snapshot(label: str, a: dict[str, str], b: dict[str, str]) -> Path:
    SNAPS.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    safe = "".join(c for c in label if c.isalnum() or c in "_-") or "snap"
    path = SNAPS / f"{stamp}_{safe}.json"
    _save(path, {"label": label, "taken_at": stamp, "a": a, "b": b})
    return path


def load_snapshots() -> list[dict]:
    return [_load(p, {}) for p in snapshot_files()]
