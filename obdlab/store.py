"""把掃描結果與快照存成 JSON，實驗中斷了也不用重來。

每台車一個資料夾（見 cars.py）：NX4 沿用 data/，K13 是 data/k13/。
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import cars


def _dir() -> Path:
    d = cars.current().data_dir
    d.mkdir(parents=True, exist_ok=True)
    return d


def dids_path() -> Path:        # 已知 DID：{"HEADER|CMD": 最後一次的 payload}
    return _dir() / "dids.json"


def modules_path() -> Path:     # 點名結果
    return _dir() / "modules.json"


def census_path() -> Path:      # 位址普查：{請求位址: 回應位址}
    return _dir() / "census.json"


def snaps_dir() -> Path:        # 每張快照一個檔
    return _dir() / "snapshots"


def listens_dir() -> Path:      # 被動監聽的錄音
    return _dir() / "listen"


def _load(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text("utf-8"))


def _save(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=1), "utf-8")


def load_dids() -> dict[str, str]:
    return _load(dids_path(), {})


def save_dids(d: dict[str, str]) -> None:
    _save(dids_path(), d)


def load_modules() -> dict[str, str]:
    return _load(modules_path(), {})


def save_modules(m: dict[str, str]) -> None:
    _save(modules_path(), m)


def load_census(car=None) -> dict[str, str]:
    d = (car or cars.current()).data_dir / "census.json"
    return _load(d, {})


def save_census(c: dict[str, str]) -> None:
    _save(census_path(), c)


def _stamp_name(label: str) -> str:
    stamp = time.strftime("%Y%m%d_%H%M%S")
    safe = "".join(ch for ch in label if ch.isalnum() or ch in "_-") or "snap"
    return f"{stamp}_{safe}.json"


def snapshot_files() -> list[Path]:
    snaps_dir().mkdir(parents=True, exist_ok=True)
    return sorted(snaps_dir().glob("*.json"))


def save_snapshot(label: str, a: dict[str, str], b: dict[str, str]) -> Path:
    path = snaps_dir() / _stamp_name(label)
    _save(path, {"label": label, "taken_at": path.stem[:15], "a": a, "b": b})
    return path


def load_snapshots() -> list[dict]:
    return [_load(p, {}) for p in snapshot_files()]


def save_listen(label: str, obj: dict) -> Path:
    path = listens_dir() / _stamp_name(label)
    _save(path, obj)
    return path
