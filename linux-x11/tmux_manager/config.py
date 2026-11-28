from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


_SESSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_CLASS_SAFE_RE = re.compile(r"[^A-Za-z0-9_-]")


def shell_quote(value: str) -> str:
    """POSIX single-quoted string safe for bash/sh."""
    return "'" + value.replace("'", "'\\''") + "'"


def is_valid_session(session: str) -> bool:
    return bool(session) and bool(_SESSION_RE.match(session))


def is_valid_host(host: str) -> bool:
    trimmed = host.strip()
    return bool(trimmed) and not any(ch.isspace() for ch in trimmed)


def bare_host(host: str) -> str:
    if "@" not in host:
        return host
    return host.rsplit("@", 1)[1]


def window_class_for_entry(entry_id: str) -> str:
    token = _CLASS_SAFE_RE.sub("", entry_id) or "entry"
    return f"tmux-manager-{token}"


@dataclass
class Frame:
    """Window frame in top-left screen coordinates (x, y, width, height)."""

    x: float
    y: float
    w: float
    h: float

    @property
    def is_usable(self) -> bool:
        return self.w >= 100 and self.h >= 100

    def to_dict(self) -> Dict[str, float]:
        return {"x": self.x, "y": self.y, "w": self.w, "h": self.h}

    @classmethod
    def from_dict(cls, data: Any) -> Optional[Frame]:
        if not isinstance(data, dict):
            return None
        try:
            return cls(
                x=float(data["x"]),
                y=float(data["y"]),
                w=float(data["w"]),
                h=float(data["h"]),
            )
        except (KeyError, TypeError, ValueError):
            return None


@dataclass
class BarOrigin:
    x: float
    y: float

    def to_dict(self) -> Dict[str, float]:
        return {"x": self.x, "y": self.y}

    @classmethod
    def from_dict(cls, data: Any) -> Optional[BarOrigin]:
        if not isinstance(data, dict):
            return None
        try:
            return cls(x=float(data["x"]), y=float(data["y"]))
        except (KeyError, TypeError, ValueError):
            return None


@dataclass
class UIConfig:
    bar_origin: Optional[BarOrigin] = None
    frame_capture_interval_seconds: float = 30.0

    def to_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {
            "frame_capture_interval_seconds": self.frame_capture_interval_seconds,
        }
        if self.bar_origin is not None:
            out["bar_origin"] = self.bar_origin.to_dict()
        return out

    @classmethod
    def from_dict(cls, data: Any) -> UIConfig:
        if not isinstance(data, dict):
            return cls()
        origin = BarOrigin.from_dict(data.get("bar_origin"))
        raw_interval = data.get("frame_capture_interval_seconds", 30.0)
        try:
            interval = float(raw_interval)
        except (TypeError, ValueError):
            interval = 30.0
        interval = min(max(interval, 1.0), 3600.0)
        return cls(bar_origin=origin, frame_capture_interval_seconds=interval)


@dataclass
class Entry:
    host: str
    session: str
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    name: Optional[str] = None
    tmux_path: Optional[str] = None
    ssh_options: List[str] = field(default_factory=list)
    detach_other_clients: bool = False
    frame: Optional[Frame] = None

    @property
    def display_name(self) -> str:
        if self.name and self.name.strip():
            return self.name
        return self.default_display_name

    @property
    def default_display_name(self) -> str:
        return f"{bare_host(self.host)}:{self.session}"

    @property
    def address(self) -> str:
        return f"{self.host}:{self.session}"

    @property
    def effective_tmux_path(self) -> str:
        return self.tmux_path if self.tmux_path else "tmux"

    @property
    def window_class(self) -> str:
        return window_class_for_entry(self.id)

    @property
    def plain_ssh_argv(self) -> List[str]:
        return ["/usr/bin/ssh", *self.ssh_options, self.host]

    def to_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {
            "detach_other_clients": self.detach_other_clients,
            "host": self.host,
            "id": self.id,
            "session": self.session,
            "ssh_options": list(self.ssh_options),
        }
        if self.name is not None:
            out["name"] = self.name
        if self.tmux_path is not None:
            out["tmux_path"] = self.tmux_path
        if self.frame is not None:
            out["frame"] = self.frame.to_dict()
        return out

    @classmethod
    def from_dict(cls, data: Any) -> Entry:
        if not isinstance(data, dict):
            raise ValueError("entry must be a JSON object")
        if "host" not in data or not isinstance(data["host"], str):
            raise ValueError("entry is missing string field 'host'")
        if "session" not in data or not isinstance(data["session"], str):
            raise ValueError("entry is missing string field 'session'")
        raw_id = data.get("id")
        entry_id = raw_id if isinstance(raw_id, str) and raw_id else str(uuid.uuid4())
        name = data.get("name")
        if name is not None and not isinstance(name, str):
            raise ValueError("entry 'name' must be a string or null")
        tmux_path = data.get("tmux_path")
        if tmux_path is not None and not isinstance(tmux_path, str):
            raise ValueError("entry 'tmux_path' must be a string or null")
        raw_opts = data.get("ssh_options", [])
        if not isinstance(raw_opts, list) or not all(isinstance(x, str) for x in raw_opts):
            raise ValueError("entry 'ssh_options' must be a list of strings")
        detach = bool(data.get("detach_other_clients", False))
        frame = Frame.from_dict(data.get("frame"))
        return cls(
            id=entry_id,
            name=name,
            host=data["host"],
            session=data["session"],
            tmux_path=tmux_path,
            ssh_options=list(raw_opts),
            detach_other_clients=detach,
            frame=frame,
        )


@dataclass
class Config:
    version: int = 1
    ui: UIConfig = field(default_factory=UIConfig)
    entries: List[Entry] = field(default_factory=list)

    def entry(self, entry_id: str) -> Optional[Entry]:
        for item in self.entries:
            if item.id == entry_id:
                return item
        return None

    @property
    def sorted_entries(self) -> List[Entry]:
        return sorted(
            self.entries,
            key=lambda e: (e.display_name.casefold(), e.address.casefold()),
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "entries": [e.to_dict() for e in self.entries],
            "ui": self.ui.to_dict(),
            "version": self.version,
        }

    @classmethod
    def from_dict(cls, data: Any) -> Config:
        if not isinstance(data, dict):
            raise ValueError("config root must be a JSON object")
        version = int(data.get("version", 1))
        ui = UIConfig.from_dict(data.get("ui"))
        raw_entries = data.get("entries", [])
        if not isinstance(raw_entries, list):
            raise ValueError("'entries' must be a list")
        entries = [Entry.from_dict(item) for item in raw_entries]
        return cls(version=version, ui=ui, entries=entries)


@dataclass(frozen=True)
class EntryProblem:
    field: str
    message: str


def validate_entry(entry: Entry, all_entries: List[Entry]) -> List[EntryProblem]:
    problems: List[EntryProblem] = []
    if not is_valid_host(entry.host):
        problems.append(
            EntryProblem("host", "SSH host is empty or contains whitespace.")
        )
    if not is_valid_session(entry.session):
        problems.append(
            EntryProblem(
                "session",
                "Session name may only contain letters, digits, _ . and -",
            )
        )
    if entry.tmux_path and any(ch.isspace() for ch in entry.tmux_path):
        problems.append(
            EntryProblem("tmux_path", "Remote tmux path must not contain whitespace.")
        )
    for opt in entry.ssh_options:
        if "\n" in opt or "\r" in opt:
            problems.append(
                EntryProblem("ssh_options", "SSH options must be one per line.")
            )
            break
    clash = any(
        other.id != entry.id
        and other.host.casefold() == entry.host.casefold()
        and other.session == entry.session
        for other in all_entries
    )
    if clash:
        problems.append(
            EntryProblem("session", f"{entry.address} is already configured.")
        )
    return problems


def validation_message(problems: List[EntryProblem]) -> Optional[str]:
    if not problems:
        return None
    return " ".join(p.message for p in problems)
