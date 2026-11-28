from __future__ import annotations

import os
import shutil
import subprocess
from typing import Callable, Dict, Iterable, List, Optional

from .config import Entry, Frame
from .log import LOG
from .paths import Paths
from .x11_windows import WindowFrame, X11WindowManager

try:
    from gi.repository import GLib
except Exception:
    GLib = None


_STRIP_ENV_KEYS = (
    "WEZTERM_UNIX_SOCKET",
    "WEZTERM_PANE",
    "TMUX",
    "TMUX_PANE",
)


def build_wezterm_command(
    wezterm_bin: str,
    attach_script: str,
    entry: Entry,
    frame: Optional[Frame] = None,
) -> List[str]:
    argv = [
        wezterm_bin,
        "--config",
        'exit_behavior="Close"',
        "--config",
        'window_close_confirmation="NeverPrompt"',
        "start",
        "--always-new-process",
        "--class",
        entry.window_class,
    ]
    if frame is not None and frame.is_usable:
        argv.extend(["--position", f"{int(round(frame.x))},{int(round(frame.y))}"])
    argv.extend(["--", attach_script, entry.id])
    return argv


def build_plain_ssh_command(wezterm_bin: str, entry: Entry) -> List[str]:
    return [
        wezterm_bin,
        "--config",
        'exit_behavior="Close"',
        "--config",
        'window_close_confirmation="NeverPrompt"',
        "start",
        "--always-new-process",
        "--",
        *entry.plain_ssh_argv,
    ]


class TerminalController:
    """Drives per-entry WezTerm windows and X11 window management."""

    def __init__(
        self,
        paths: Paths,
        window_manager: Optional[X11WindowManager] = None,
    ) -> None:
        self.paths = paths
        self.wm = window_manager if window_manager is not None else X11WindowManager()

    def _wezterm_bin(self) -> Optional[str]:
        return shutil.which("wezterm") or (
            "/usr/bin/wezterm" if os.path.exists("/usr/bin/wezterm") else None
        )

    def _spawn_env(self, window_class: Optional[str] = None) -> Dict[str, str]:
        env = dict(os.environ)
        for key in _STRIP_ENV_KEYS:
            env.pop(key, None)
        env["TMUX_MANAGER_DIR"] = str(self.paths.support_dir)
        if window_class:
            env["TMUX_MANAGER_WINDOW_CLASS"] = window_class
        else:
            env.pop("TMUX_MANAGER_WINDOW_CLASS", None)
        return env

    def create_window(
        self,
        entry: Entry,
        frame: Optional[Frame],
        on_done: Callable[[Optional[str]], None],
    ) -> None:
        wezterm = self._wezterm_bin()
        if not wezterm:
            on_done("wezterm executable was not found in PATH.")
            return
        argv = build_wezterm_command(
            wezterm_bin=wezterm,
            attach_script=str(self.paths.attach_script_path),
            entry=entry,
            frame=frame,
        )
        try:
            subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=self._spawn_env(entry.window_class),
                start_new_session=True,
            )
        except OSError as exc:
            msg = f"Could not launch WezTerm: {exc}"
            LOG.write(f"create window failed: {msg}")
            on_done(msg)
            return

        LOG.write(f"created window for {entry.address} class={entry.window_class}")
        if frame is not None and frame.is_usable and self.wm.available and GLib is not None:
            self._schedule_geometry_apply(entry.window_class, frame, attempts=30)
        on_done(None)

    def _schedule_geometry_apply(
        self, window_class: str, frame: Frame, attempts: int
    ) -> None:
        if attempts <= 0 or GLib is None:
            return

        def tick() -> bool:
            if self.wm.apply_geometry(window_class, frame):
                LOG.write(
                    f"applied saved frame {frame.x:.0f},{frame.y:.0f} "
                    f"{frame.w:.0f}x{frame.h:.0f} to {window_class}"
                )
                return False
            self._schedule_geometry_apply(window_class, frame, attempts - 1)
            return False

        GLib.timeout_add(100, tick)

    def open_shell_window(
        self, entry: Entry, on_done: Callable[[Optional[str]], None]
    ) -> None:
        wezterm = self._wezterm_bin()
        if not wezterm:
            on_done("wezterm executable was not found in PATH.")
            return
        argv = build_plain_ssh_command(wezterm, entry)
        try:
            subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=self._spawn_env(None),
                start_new_session=True,
            )
            LOG.write(f"opened plain ssh window for {entry.address}")
            on_done(None)
        except OSError as exc:
            msg = f"Could not open a plain ssh window: {exc}"
            LOG.write(f"plain ssh failed: {msg}")
            on_done(msg)

    def activate(
        self, window_class: str, on_done: Callable[[bool], None]
    ) -> None:
        found = self.wm.activate(window_class)
        on_done(found)

    def close_window(self, window_class: str) -> None:
        if window_class:
            self.wm.close(window_class)

    def frames(self, window_classes: Iterable[str]) -> Dict[str, WindowFrame]:
        return self.wm.frames(window_classes)

    def monitor_workareas(self):
        return self.wm.monitor_workareas()
