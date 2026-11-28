from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Paths:
    support_dir: Path

    @classmethod
    def default(cls) -> Paths:
        override = os.environ.get("TMUX_MANAGER_DIR", "").strip()
        if override:
            return cls(Path(override).expanduser())
        xdg_data = os.environ.get("XDG_DATA_HOME", "").strip()
        base = Path(xdg_data).expanduser() if xdg_data else Path.home() / ".local" / "share"
        return cls(base / "tmux-manager")

    @property
    def config_path(self) -> Path:
        return self.support_dir / "config.json"

    @property
    def env_dir(self) -> Path:
        return self.support_dir / "env"

    @property
    def state_dir(self) -> Path:
        return self.support_dir / "state"

    @property
    def attach_script_path(self) -> Path:
        return self.support_dir / "attach.sh"

    @property
    def log_path(self) -> Path:
        return self.support_dir / "log.txt"

    @property
    def debug_flag_path(self) -> Path:
        return self.support_dir / "debug"

    @property
    def socket_path(self) -> Path:
        return self.support_dir / "control.sock"

    def env_path(self, entry_id: str) -> Path:
        return self.env_dir / f"{entry_id}.sh"

    def state_path(self, entry_id: str) -> Path:
        return self.state_dir / f"{entry_id}.json"

    def prepare_directories(self) -> None:
        self.support_dir.mkdir(parents=True, exist_ok=True)
        self.env_dir.mkdir(parents=True, exist_ok=True)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.support_dir, 0o700)
        except OSError:
            pass
