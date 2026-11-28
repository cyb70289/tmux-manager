from __future__ import annotations

import os
import signal
import threading
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

from .config import (
    BarOrigin,
    Config,
    Entry,
    Frame,
    shell_quote,
    validate_entry,
    validation_message,
)
from .config_store import ConfigStore
from .frame_clamp import clamp_frame
from .log import LOG, install_wrapper
from .paths import Paths
from .shell import run_command
from .state_store import StateStore, WrapperState
from .terminal_controller import TerminalController

try:
    from gi.repository import GLib
except Exception:
    GLib = None


class _GLibScheduler:
    def call_later(self, delay_ms: int, fn: Callable[[], None]) -> int:
        if GLib is None:
            return 0

        def _cb() -> bool:
            fn()
            return False

        return int(GLib.timeout_add(max(1, delay_ms), _cb))

    def call_every(self, interval_ms: int, fn: Callable[[], None]) -> int:
        if GLib is None:
            return 0

        def _cb() -> bool:
            fn()
            return True

        return int(GLib.timeout_add(max(100, interval_ms), _cb))

    def cancel(self, handle: Optional[int]) -> None:
        if handle and GLib is not None:
            try:
                GLib.source_remove(handle)
            except Exception:
                pass

    def call_main(self, fn: Callable[[], None]) -> None:
        if GLib is None:
            fn()
            return

        def _cb() -> bool:
            fn()
            return False

        GLib.idle_add(_cb)


class AppModel:
    """Owns config, wrapper states, frames, timers, and entry operations."""

    def __init__(
        self,
        paths: Optional[Paths] = None,
        controller: Optional[TerminalController] = None,
        attach_source: Optional[Path] = None,
        scheduler=None,
    ) -> None:
        self.paths = paths or Paths.default()
        self.config_store = ConfigStore(self.paths)
        self.state_store = StateStore(self.paths)
        self.controller = controller or TerminalController(self.paths)
        self.attach_source = attach_source or (
            Path(__file__).resolve().parent.parent / "resources" / "attach.sh"
        )
        self._sched = scheduler or _GLibScheduler()

        self.config: Config = Config()
        self.states: Dict[str, WrapperState] = {}
        self.busy: Set[str] = set()
        self.reconnecting: Set[str] = set()
        self.error_message: Optional[str] = None
        self.notes: List[str] = []

        self._frames: Dict[str, Frame] = {}
        self._frame_save_handle: Optional[int] = None
        self._origin_save_handle: Optional[int] = None
        self._state_timer_handle: Optional[int] = None
        self._frame_timer_handle: Optional[int] = None
        self._error_generation = 0
        self._suppress_config_reload = 0
        self._last_config_stamp: Optional[Tuple[int, int, int]] = None

        self.on_change: Optional[Callable[[], None]] = None

        res = self.config_store.load()
        if res.status == "loaded" and res.config is not None:
            self.config = res.config
            self.notes = list(res.notes or [])
        elif res.status == "empty":
            self.config = Config()
        else:
            self.config = Config()
            self.error_message = res.error

    # MARK: - Lifecycle

    def start(self) -> None:
        LOG.configure(self.paths)
        try:
            self.paths.prepare_directories()
        except OSError as exc:
            self.show_error(f"Cannot create {self.paths.support_dir}: {exc}")

        if self.attach_source.exists():
            try:
                changed = install_wrapper(self.attach_source, self.paths)
                LOG.write(
                    f"attach.sh installed (changed={changed}) at {self.paths.attach_script_path}"
                )
            except OSError as exc:
                self.show_error(f"Cannot install attach.sh: {exc}")
        else:
            LOG.write(f"attach.sh missing at {self.attach_source}")

        self._persist_env_files()
        self._last_config_stamp = self.config_store.stat_stamp()
        self.refresh_states()
        self._start_state_timer()
        self._start_frame_timer()
        if self.notes:
            self.show_error("  ".join(self.notes))
            self.notes = []
        self._notify()

    def shutdown(self) -> None:
        self._sched.cancel(self._state_timer_handle)
        self._sched.cancel(self._frame_timer_handle)
        self._sched.cancel(self._frame_save_handle)
        self._sched.cancel(self._origin_save_handle)
        self._state_timer_handle = None
        self._frame_timer_handle = None
        self.capture_frames()
        self._store_frames_now()

    def _notify(self) -> None:
        if self.on_change is not None:
            self.on_change()

    # MARK: - Queries

    def is_active(self, entry: Entry) -> bool:
        return entry.id in self.states

    def is_busy(self, entry: Entry) -> bool:
        return entry.id in self.busy

    def is_reconnecting(self, entry: Entry) -> bool:
        return entry.id in self.reconnecting

    def live_state(self, entry: Entry) -> Optional[WrapperState]:
        return self.states.get(entry.id)

    # MARK: - Operations

    def open(self, entry: Entry) -> None:
        current = self.config.entry(entry.id) or entry
        if current.id in self.busy:
            return
        state = self.states.get(current.id)
        if state is not None:
            window_class = state.window_class or current.window_class
            self.busy.add(current.id)
            self._notify()

            def _after_activate(found: bool) -> None:
                if found:
                    self.busy.discard(current.id)
                    LOG.write(f"activated existing window for {current.address}")
                    self.capture_frames()
                    self._flush_frames()
                    self._notify()
                else:
                    LOG.write(
                        f"window for {current.address} is gone; opening a new one"
                    )
                    self.states.pop(current.id, None)
                    self.busy.discard(current.id)
                    self._create_window(current)

            self.controller.activate(window_class, _after_activate)
            return

        self._create_window(current)

    def open_plain_ssh(self, entry: Entry) -> None:
        current = self.config.entry(entry.id) or entry

        def _after_open(error: Optional[str]) -> None:
            if error:
                self.show_error(error)

        self.controller.open_shell_window(current, _after_open)

    def _create_window(self, entry: Entry) -> None:
        if entry.id in self.busy:
            return
        self.busy.add(entry.id)
        self._notify()
        frame = self._clamped_restore_frame(entry)

        def _after_create(error: Optional[str]) -> None:
            if error:
                self.busy.discard(entry.id)
                self.show_error(error)
                self._notify()
                return
            self._wait_for_state(entry.id, attempts=60)

        self.controller.create_window(entry, frame, _after_create)

    def _wait_for_state(self, entry_id: str, attempts: int) -> None:
        if attempts <= 0:
            self.busy.discard(entry_id)
            self.show_error(
                f"The console window opened but never reported back. Check {self.paths.log_path}."
            )
            return
        if entry_id in self.states:
            self.busy.discard(entry_id)
            self._notify()
            return
        if self.config.entry(entry_id) is None:
            self.busy.discard(entry_id)
            return

        def _poll() -> None:
            self.refresh_states()
            if entry_id in self.states:
                self.busy.discard(entry_id)
                self._notify()
            else:
                self._wait_for_state(entry_id, attempts - 1)

        self._sched.call_later(100, _poll)

    def reconnect(self, entry: Entry) -> None:
        current = self.config.entry(entry.id) or entry
        state = self.states.get(current.id)
        if current.id in self.busy or state is None:
            return
        self.busy.add(current.id)
        self.reconnecting.add(current.id)
        self._notify()

        def _send_signal() -> None:
            if current.id not in self.reconnecting:
                return
            self.capture_frames()
            self._flush_frames()
            try:
                os.kill(state.wrapper_pid, signal.SIGUSR1)
            except OSError:
                self._finish_reconnect(current.id)
                self.show_error(
                    f"Could not signal the console process for {current.display_name}."
                )
                return
            LOG.write(
                f"sent reconnect to {current.address} (pid {state.wrapper_pid})"
            )
            self._sched.call_later(
                300, lambda: self._wait_for_reconnect(current, state, attempts=30)
            )

        self._sched.call_later(50, _send_signal)

    def _wait_for_reconnect(
        self, entry: Entry, previous: WrapperState, attempts: int
    ) -> None:
        if entry.id not in self.reconnecting:
            return
        self.refresh_states()
        state = self.states.get(entry.id)
        if state is None:
            self._finish_reconnect(entry.id)
            return
        if state.wrapper_pid != previous.wrapper_pid or (
            state.ssh_pid is not None and state.ssh_pid != previous.ssh_pid
        ):
            self._finish_reconnect(entry.id)
            return
        if attempts <= 0:
            self._finish_reconnect(entry.id)
            LOG.write(
                f"reconnect wait ended without a new ssh pid for {entry.address}"
            )
            return
        self._sched.call_later(
            100, lambda: self._wait_for_reconnect(entry, previous, attempts - 1)
        )

    def _finish_reconnect(self, entry_id: str) -> None:
        self.reconnecting.discard(entry_id)
        self.busy.discard(entry_id)
        self._notify()

    def add(self, entry: Entry) -> bool:
        msg = validation_message(validate_entry(entry, self.config.entries))
        if msg:
            self.show_error(msg)
            return False
        self.config.entries.append(entry)
        self.save()
        self._notify()
        return True

    def update(self, entry: Entry) -> bool:
        idx = next(
            (i for i, item in enumerate(self.config.entries) if item.id == entry.id),
            None,
        )
        if idx is None:
            return False
        entry.frame = self.config.entries[idx].frame
        msg = validation_message(validate_entry(entry, self.config.entries))
        if msg:
            self.show_error(msg)
            return False
        self.config.entries[idx] = entry
        self.save()
        self._notify()
        return True

    def remove(self, entry: Entry, kill_remote_session: bool) -> None:
        state = self.states.pop(entry.id, None)
        if state is not None:
            try:
                os.kill(state.wrapper_pid, signal.SIGTERM)
            except OSError:
                pass
            self.controller.close_window(state.window_class or entry.window_class)
            try:
                self.paths.state_path(entry.id).unlink()
            except OSError:
                pass
        self.config.entries = [e for e in self.config.entries if e.id != entry.id]
        self._frames.pop(entry.id, None)
        self.reconnecting.discard(entry.id)
        self.busy.discard(entry.id)
        self.save()
        self._notify()
        if kill_remote_session:
            self._kill_remote(entry)

    def close_console(self, entry: Entry) -> None:
        state = self.states.get(entry.id)
        if state is None or entry.id in self.busy:
            return
        self.capture_frames()
        self._store_frames_now()
        try:
            os.kill(state.wrapper_pid, signal.SIGTERM)
        except OSError:
            pass
        self.controller.close_window(state.window_class or entry.window_class)
        self.states.pop(entry.id, None)
        try:
            self.paths.state_path(entry.id).unlink()
        except OSError:
            pass
        LOG.write(f"closed console for {entry.address}")
        self._notify()

    def _kill_remote(self, entry: Entry) -> None:
        def _worker() -> None:
            remote_cmd = (
                f"{shell_quote(entry.effective_tmux_path)} "
                f"kill-session -t {shell_quote(entry.session)}"
            )
            argv = [
                "/usr/bin/ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                *entry.ssh_options,
                entry.host,
                remote_cmd,
            ]
            result = run_command(argv, timeout=30.0)
            if result.status == 0:
                LOG.write(f"killed remote session {entry.address}")
            else:
                text = result.combined or f"ssh exited {result.status}"
                LOG.write(f"could not kill remote session {entry.address}: {text}")

        threading.Thread(target=_worker, daemon=True).start()

    # MARK: - Frames

    def _clamped_restore_frame(self, entry: Entry) -> Optional[Frame]:
        saved = entry.frame
        if saved is None or not saved.is_usable:
            return None
        screens = self.controller.monitor_workareas()
        return clamp_frame(saved, screens)

    def _start_frame_timer(self) -> None:
        self._sched.cancel(self._frame_timer_handle)
        interval_ms = int(max(1.0, self.config.ui.frame_capture_interval_seconds) * 1000)
        self._frame_timer_handle = self._sched.call_every(interval_ms, self._tick_frames)

    def _tick_frames(self) -> None:
        self.capture_frames()
        self._flush_frames()

    def capture_frames(self) -> None:
        if not self.states:
            return
        class_to_entry: Dict[str, str] = {}
        for entry_id, state in self.states.items():
            entry = self.config.entry(entry_id)
            window_class = state.window_class or (entry.window_class if entry else None)
            if window_class:
                class_to_entry[window_class] = entry_id
        if not class_to_entry:
            return
        for window_class, wframe in self.controller.frames(class_to_entry.keys()).items():
            entry_id = class_to_entry.get(window_class)
            if not entry_id or wframe.minimized or not wframe.frame.is_usable:
                continue
            if self._frames.get(entry_id) != wframe.frame:
                self._frames[entry_id] = wframe.frame

    def _flush_frames(self) -> None:
        changed = False
        for entry_id, frame in self._frames.items():
            entry = self.config.entry(entry_id)
            if entry is not None and entry.frame != frame:
                entry.frame = frame
                changed = True
        if not changed:
            return
        self._sched.cancel(self._frame_save_handle)
        self._frame_save_handle = self._sched.call_later(2000, self.save)
        self._notify()

    def _store_frames_now(self) -> None:
        had_pending = self._frame_save_handle is not None
        self._sched.cancel(self._frame_save_handle)
        self._frame_save_handle = None
        changed = False
        for entry_id, frame in self._frames.items():
            entry = self.config.entry(entry_id)
            if entry is not None and entry.frame != frame:
                entry.frame = frame
                changed = True
        if changed or had_pending:
            self.save()

    # MARK: - State & config polling

    def _start_state_timer(self) -> None:
        self._sched.cancel(self._state_timer_handle)
        self._state_timer_handle = self._sched.call_every(1000, self._tick_state)

    def _tick_state(self) -> None:
        before = dict(self.states)
        self.refresh_states()
        if before != self.states:
            self._notify()
        stamp = self.config_store.stat_stamp()
        if stamp != self._last_config_stamp:
            self._last_config_stamp = stamp
            self.reload_from_disk()

    def refresh_states(self) -> None:
        live = self.state_store.live_states()
        self.states = {
            eid: st for eid, st in live.items() if self.config.entry(eid) is not None
        }
        self._frames = {
            eid: fr
            for eid, fr in self._frames.items()
            if eid in self.states or self.config.entry(eid) is not None
        }

    def _persist_env_files(self) -> None:
        try:
            self.config_store.write_env_files(self.config)
            self.config_store.cleanup_orphans(self.config)
        except OSError as exc:
            self.show_error(f"Cannot write entry files: {exc}")

    def save(self) -> None:
        self._suppress_config_reload += 1
        try:
            self.config_store.save(self.config)
            self._last_config_stamp = self.config_store.stat_stamp()
        except OSError as exc:
            self.show_error(f"Cannot save config.json: {exc}")

        def _unsuppress() -> None:
            self._suppress_config_reload = max(0, self._suppress_config_reload - 1)

        self._sched.call_later(600, _unsuppress)

    def reload_from_disk(self) -> None:
        if self._suppress_config_reload > 0:
            return
        res = self.config_store.load()
        if res.status == "loaded" and res.config is not None:
            if res.config == self.config:
                return
            LOG.write("config.json changed on disk; reloading")
            self.config = res.config
            self._persist_env_files()
            self.refresh_states()
            self._start_frame_timer()
            self._notify()
        elif res.status == "empty":
            if not self.config.entries:
                return
            self.config = Config()
            self._persist_env_files()
            self.refresh_states()
            self._notify()
        elif res.error:
            self.show_error(res.error)

    # MARK: - Bar origin & errors

    @property
    def bar_origin(self) -> Optional[BarOrigin]:
        return self.config.ui.bar_origin

    def set_bar_origin(self, origin: BarOrigin) -> None:
        if self.config.ui.bar_origin == origin:
            return
        self.config.ui.bar_origin = origin
        self._sched.cancel(self._origin_save_handle)
        self._origin_save_handle = self._sched.call_later(1500, self.save)

    def show_error(self, message: str) -> None:
        self.error_message = message
        self._error_generation += 1
        gen = self._error_generation
        LOG.write(f"error: {message}")
        self._notify()

        def _expire() -> None:
            if self._error_generation == gen:
                self.error_message = None
                self._notify()

        self._sched.call_later(8000, _expire)

    def dismiss_error(self) -> None:
        self.error_message = None
        self._error_generation += 1
        self._notify()
