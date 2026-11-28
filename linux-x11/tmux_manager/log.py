from __future__ import annotations

import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .paths import Paths


class Logger:
    def __init__(self, rotate_at: int = 1_000_000) -> None:
        self._lock = threading.Lock()
        self._path: Optional[Path] = None
        self._rotate_at = rotate_at

    def configure(self, paths: Paths) -> None:
        with self._lock:
            self._path = paths.log_path

    def write(self, message: str) -> None:
        with self._lock:
            path = self._path
            if path is None:
                return
            stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            line = f"{stamp} {message}\n".encode("utf-8", errors="replace")
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                if path.exists() and path.stat().st_size > self._rotate_at:
                    backup = path.with_name(f"{path.name}.1")
                    try:
                        os.replace(path, backup)
                    except OSError:
                        pass
                with open(path, "ab") as fh:
                    fh.write(line)
            except OSError:
                pass


LOG = Logger()


def install_wrapper(source: Path, paths: Paths) -> bool:
    """Install or update attach.sh inside the support directory."""
    paths.prepare_directories()
    destination = paths.attach_script_path
    new_data = source.read_bytes()
    old_data = destination.read_bytes() if destination.exists() else None
    changed = old_data != new_data
    if changed:
        tmp = destination.with_name(".attach.sh.tmp")
        tmp.write_bytes(new_data)
        os.chmod(tmp, 0o755)
        os.replace(tmp, destination)
    else:
        os.chmod(destination, 0o755)
    return changed
