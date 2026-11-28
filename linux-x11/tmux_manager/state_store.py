from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

from .paths import Paths


@dataclass
class WrapperState:
    entry_id: str
    wrapper_pid: int
    ssh_pid: Optional[int] = None
    window_class: Optional[str] = None
    wezterm_pane_id: Optional[str] = None
    tty: Optional[str] = None
    started_at: Optional[float] = None

    @classmethod
    def from_dict(cls, data: dict) -> WrapperState:
        return cls(
            entry_id=str(data["entry_id"]),
            wrapper_pid=int(data["wrapper_pid"]),
            ssh_pid=int(data["ssh_pid"]) if data.get("ssh_pid") is not None else None,
            window_class=data.get("window_class"),
            wezterm_pane_id=(
                str(data["wezterm_pane_id"])
                if data.get("wezterm_pane_id") is not None
                else None
            ),
            tty=data.get("tty"),
            started_at=(
                float(data["started_at"])
                if data.get("started_at") is not None
                else None
            ),
        )


def process_is_zombie(pid: int) -> bool:
    try:
        stat_text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
        rparen = stat_text.rfind(")")
        if rparen == -1:
            return False
        fields = stat_text[rparen + 2 :].split()
        return bool(fields) and fields[0] == "Z"
    except OSError:
        return True


def process_cmdline(pid: int) -> Optional[List[str]]:
    """Return argv of pid from /proc/<pid>/cmdline, or None if not alive."""
    if pid <= 0 or process_is_zombie(pid):
        return None
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return None
    if not raw:
        return None
    parts = [p.decode("utf-8", errors="replace") for p in raw.split(b"\x00") if p]
    return parts or None


class StateStore:
    def __init__(self, paths: Paths) -> None:
        self.paths = paths

    def live_states(self) -> Dict[str, WrapperState]:
        out: Dict[str, WrapperState] = {}
        if not self.paths.state_dir.exists():
            return out
        raw_script = str(self.paths.attach_script_path)
        resolved_script = str(self.paths.attach_script_path.resolve())
        for path in self.paths.state_dir.iterdir():
            if not path.is_file() or path.suffix != ".json" or path.name.startswith("."):
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                state = WrapperState.from_dict(data)
            except Exception:
                self._unlink_quiet(path)
                continue
            if not self._belongs_to_wrapper(state, raw_script, resolved_script):
                self._unlink_quiet(path)
                continue
            out[state.entry_id] = state
        return out

    @staticmethod
    def _belongs_to_wrapper(
        state: WrapperState, raw_script: str, resolved_script: str
    ) -> bool:
        argv = process_cmdline(state.wrapper_pid)
        if not argv:
            return False
        matches_script = any(arg in (raw_script, resolved_script) for arg in argv)
        matches_entry = state.entry_id in argv
        return matches_script and matches_entry

    @staticmethod
    def _unlink_quiet(path: Path) -> None:
        try:
            os.unlink(path)
        except OSError:
            pass
