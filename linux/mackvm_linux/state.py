"""Persistent configuration and timestamped logging for MacKVM Linux."""

from __future__ import annotations

import json
import math
import os
import re
import socket
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from . import VERSION


def config_dir() -> Path:
    custom = os.environ.get("MACKVM_LINUX_HOME", "").strip()
    if custom:
        return Path(custom).expanduser()
    return Path("~/.config/mackvm").expanduser()


def log_path() -> Path:
    custom = os.environ.get("MACKVM_LINUX_LOG", "").strip()
    if custom:
        return Path(custom).expanduser()
    if custom_home := os.environ.get("MACKVM_LINUX_HOME", "").strip():
        return Path(custom_home).expanduser() / "mackvm.log"
    return Path("~/.local/state/mackvm/mackvm.log").expanduser()


_log_lock = threading.Lock()
_log_role = "未配对"


def set_log_role(role: str) -> None:
    global _log_role
    _log_role = role


def log(msg: str) -> None:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    line = f"{now} [{_log_role}] {msg}\n"
    with _log_lock:
        try:
            sys.stderr.write(line)
            sys.stderr.flush()
        except Exception:
            pass
        try:
            lp = log_path()
            lp.parent.mkdir(parents=True, exist_ok=True)
            with open(lp, "a", encoding="utf-8") as f:
                f.write(line)
        except Exception:
            pass


def current_computer_name() -> str:
    try:
        name = socket.gethostname().split(".")[0].strip()
        if name:
            return name
    except Exception:
        pass
    return "Ubuntu"


DEFAULT_RIPPLE: dict[str, Any] = {
    "enabled": True,
    "leaveSize": 70.0,
    "leaveDuration": 0.4,
    "leaveInterval": 0.1,
    "leaveTotal": 1.0,
    "arriveSize": 140.0,
    "arriveDuration": 0.5,
    "spawnInterval": 0.1,
    "minDuration": 1.0,
    "idleStop": 0.5,
    "maxDuration": 5.0,
    "leaveColors": ["#FFFFFF", "#000000"],
    "arriveColors": ["#000000", "#FFFFFF"],
}

_RIPPLE_SPECS: dict[str, tuple[float, float, float]] = {
    "leaveSize": (20.0, 300.0, 10.0),
    "leaveDuration": (0.1, 3.0, 0.1),
    "leaveInterval": (0.05, 1.0, 0.05),
    "leaveTotal": (0.0, 5.0, 0.1),
    "arriveSize": (20.0, 400.0, 10.0),
    "arriveDuration": (0.1, 3.0, 0.1),
    "spawnInterval": (0.05, 1.0, 0.05),
    "minDuration": (0.0, 10.0, 0.5),
    "idleStop": (0.1, 5.0, 0.1),
    "maxDuration": (0.5, 20.0, 0.5),
}

_HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


def _clean_colors(raw: Any, fallback: list[str]) -> list[str]:
    if not isinstance(raw, list):
        return list(fallback)
    out = [str(c).upper() for c in raw if isinstance(c, str) and _HEX_RE.match(c.strip())]
    out = [c.strip().upper() if isinstance(c, str) else c for c in out]
    out = out[:5]
    return out if out else list(fallback)


def sanitize_ripple(raw: dict[str, Any] | None) -> dict[str, Any]:
    out = dict(DEFAULT_RIPPLE)
    if isinstance(raw, dict):
        out["enabled"] = bool(raw.get("enabled", True))
        for k, (lo, hi, step) in _RIPPLE_SPECS.items():
            v = raw.get(k, DEFAULT_RIPPLE[k])
            try:
                v = float(v)
            except (TypeError, ValueError):
                v = float(DEFAULT_RIPPLE[k])
            if not math.isfinite(v):
                v = float(DEFAULT_RIPPLE[k])
            v = round(round(v / step) * step, 3)
            out[k] = min(max(v, lo), hi)
        if out["maxDuration"] < out["minDuration"]:
            out["maxDuration"] = out["minDuration"]
        out["leaveColors"] = _clean_colors(raw.get("leaveColors"), DEFAULT_RIPPLE["leaveColors"])
        out["arriveColors"] = _clean_colors(raw.get("arriveColors"), DEFAULT_RIPPLE["arriveColors"])
    return out


@dataclass
class PersistedState:
    device_id: str
    pairing: dict[str, Any] | None = None
    shared: dict[str, Any] | None = None
    swap_cmd_ctrl: bool = True
    peer_screens: dict[str, list[dict[str, Any]]] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "deviceID": self.device_id,
            "swapCmdCtrl": self.swap_cmd_ctrl,
            "version": VERSION,
        }
        if self.pairing is not None:
            d["pairing"] = self.pairing
        if self.shared is not None:
            d["shared"] = self.shared
        if self.peer_screens:
            d["peerScreens"] = self.peer_screens
        return d

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "PersistedState":
        dev_id = str(data.get("deviceID") or "").strip() or str(uuid.uuid4())
        pairing = data.get("pairing") if isinstance(data.get("pairing"), dict) else None
        shared = data.get("shared") if isinstance(data.get("shared"), dict) else None
        if pairing is None or shared is None:
            pairing = None
            shared = None
        swap = bool(data.get("swapCmdCtrl", True))
        ps = data.get("peerScreens") if isinstance(data.get("peerScreens"), dict) else {}
        return cls(device_id=dev_id, pairing=pairing, shared=shared, swap_cmd_ctrl=swap, peer_screens=ps)


class Store:
    def __init__(self, directory: Path | None = None) -> None:
        self.dir = directory or config_dir()
        self.file = self.dir / "state.json"

    def load(self) -> PersistedState:
        if self.file.exists():
            try:
                raw = json.loads(self.file.read_text(encoding="utf-8"))
                if isinstance(raw, dict):
                    return PersistedState.from_json(raw)
            except Exception as exc:
                bad = self.dir / f"state.broken-{int(time.time())}.json"
                try:
                    self.file.rename(bad)
                except Exception:
                    pass
                log(f"警告：{self.file} 解析失败（{exc}），已备份为 {bad.name}，按未配对处理")
        st = PersistedState(device_id=str(uuid.uuid4()))
        log(f"第一次运行：生成本机设备 ID {st.device_id}")
        self.save(st)
        return st

    def save(self, st: PersistedState) -> None:
        try:
            self.dir.mkdir(parents=True, exist_ok=True)
            os.chmod(self.dir, 0o700)
            payload = json.dumps(st.to_json(), ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
            tmp = self.dir / f".state.{os.getpid()}.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                view = memoryview(payload)
                written = 0
                while written < len(payload):
                    n = os.write(fd, view[written:])
                    if n <= 0:
                        raise OSError("short write")
                    written += n
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(tmp, self.file)
        except Exception as exc:
            log(f"错误：保存 {self.file} 失败：{exc}")
