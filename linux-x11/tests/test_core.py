from __future__ import annotations

import json
import os
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from tmux_manager.app_model import AppModel
from tmux_manager.config import (
    BarOrigin,
    Config,
    Entry,
    Frame,
    UIConfig,
    validate_entry,
    window_class_for_entry,
)
from tmux_manager.config_store import ConfigStore
from tmux_manager.frame_clamp import BarAnchor, ScreenRect, clamp_frame, place_bar
from tmux_manager.log import install_wrapper
from tmux_manager.paths import Paths
from tmux_manager.state_store import StateStore
from tmux_manager.terminal_controller import (
    build_plain_ssh_command,
    build_wezterm_command,
)
from tmux_manager.x11_windows import WindowFrame


class _FakeScheduler:
    def call_later(self, delay_ms, fn):
        return 0

    def call_every(self, interval_ms, fn):
        return 0

    def cancel(self, handle):
        pass

    def call_main(self, fn):
        fn()


class _FakeController:
    def __init__(self) -> None:
        self.created = []
        self.plain_opened = []
        self.activated = []
        self.closed = []
        self.activate_result = True
        self.window_frames = {}
        self.workareas = [ScreenRect(0, 0, 1920, 1080)]

    def create_window(self, entry, frame, on_done):
        self.created.append((entry.id, frame))
        on_done(None)

    def open_shell_window(self, entry, on_done):
        self.plain_opened.append(entry.id)
        on_done(None)

    def activate(self, window_class, on_done):
        self.activated.append(window_class)
        on_done(self.activate_result)

    def close_window(self, window_class):
        self.closed.append(window_class)

    def frames(self, window_classes):
        return {
            wc: self.window_frames[wc]
            for wc in window_classes
            if wc in self.window_frames
        }

    def monitor_workareas(self):
        return list(self.workareas)


class CoreTests(unittest.TestCase):
    def test_macos_config_roundtrip_and_sorting(self) -> None:
        raw = {
            "version": 1,
            "ui": {
                "bar_origin": {"x": 1380, "y": 40},
                "frame_capture_interval_seconds": 30,
            },
            "entries": [
                {
                    "id": "e2",
                    "name": None,
                    "host": "cyb@devbox",
                    "session": "main",
                    "tmux_path": None,
                    "ssh_options": ["-p", "2222"],
                    "detach_other_clients": True,
                    "frame": {"x": 400, "y": 300, "w": 800, "h": 600},
                },
                {
                    "id": "e1",
                    "name": "Alpha",
                    "host": "box1",
                    "session": "work",
                },
            ],
        }
        cfg = Config.from_dict(raw)
        self.assertEqual([e.id for e in cfg.sorted_entries], ["e1", "e2"])
        self.assertEqual(cfg.entry("e2").display_name, "devbox:main")
        self.assertEqual(cfg.entry("e2").frame, Frame(400, 300, 800, 600))
        self.assertEqual(
            cfg.entry("e2").plain_ssh_argv,
            ["/usr/bin/ssh", "-p", "2222", "cyb@devbox"],
        )

        with tempfile.TemporaryDirectory() as tmp:
            store = ConfigStore(Paths(Path(tmp)))
            store.save(cfg)
            loaded = store.load()
            self.assertEqual(loaded.status, "loaded")
            self.assertEqual(loaded.config, cfg)
            env_text = (Path(tmp) / "env" / "e2.sh").read_text(encoding="utf-8")
            self.assertIn("HOST='cyb@devbox'", env_text)
            self.assertIn("EXTRA_SSH_OPTS=( '-p' '2222' )", env_text)
            self.assertIn("DETACH_OTHER_CLIENTS=1", env_text)

    def test_entry_validation(self) -> None:
        existing = Entry(id="a", host="devbox", session="main")
        dup = Entry(id="b", host="DEVBOX", session="main")
        bad = Entry(id="c", host="bad host", session="bad;session", tmux_path="/a b/tmux")
        self.assertTrue(validate_entry(dup, [existing, dup]))
        problems = {p.field for p in validate_entry(bad, [bad])}
        self.assertEqual(problems, {"host", "session", "tmux_path"})

    def test_frame_clamp_and_right_pinned_bar(self) -> None:
        screens = [ScreenRect(0, 0, 1920, 1080)]
        visible = clamp_frame(Frame(100, 100, 800, 600), screens)
        self.assertEqual(visible, Frame(100, 100, 800, 600))

        offscreen = clamp_frame(Frame(5000, 2000, 800, 600), screens)
        self.assertGreaterEqual(offscreen.x, 0)
        self.assertLessEqual(offscreen.x + offscreen.w, 1920)
        self.assertLessEqual(offscreen.y + offscreen.h, 1080)

        anchor = BarAnchor(right=1900, top=20)
        placed = place_bar(width=400, height=44, anchor=anchor, visible=screens[0])
        self.assertEqual(placed, ScreenRect(1500, 20, 400, 44))
        clamped_left = place_bar(
            width=500, height=44, anchor=BarAnchor(right=300, top=20), visible=screens[0]
        )
        self.assertEqual(clamped_left.x, 0)

    def test_wezterm_command_builders(self) -> None:
        entry = Entry(id="abc-123", host="u@h", session="dev", ssh_options=["-A"])
        cmd = build_wezterm_command(
            "/usr/bin/wezterm", "/tmp/attach.sh", entry, Frame(10, 20, 800, 600)
        )
        self.assertIn("--always-new-process", cmd)
        self.assertIn(window_class_for_entry("abc-123"), cmd)
        self.assertIn("--position", cmd)
        self.assertIn("10,20", cmd)
        self.assertEqual(cmd[-3:], ["--", "/tmp/attach.sh", "abc-123"])

        plain = build_plain_ssh_command("/usr/bin/wezterm", entry)
        self.assertEqual(plain[-4:], ["--", "/usr/bin/ssh", "-A", "u@h"])

    def test_attach_wrapper_lifecycle_and_state_store(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = Paths(Path(tmp))
            paths.prepare_directories()
            attach_src = Path(__file__).resolve().parent.parent / "resources" / "attach.sh"
            install_wrapper(attach_src, paths)

            entry = Entry(id="test-entry-1", host="dummyhost", session="work", detach_other_clients=True)
            ConfigStore(paths).save(Config(entries=[entry]))

            # Fake ssh that records invocations and waits until signaled.
            invocations = Path(tmp) / "ssh_calls.log"
            fake_ssh = Path(tmp) / "fake_ssh.sh"
            fake_ssh.write_text(
                "#!/bin/bash\n"
                f"printf '%s\\n' \"$*\" >> {invocations}\n"
                "sleep 30\n",
                encoding="utf-8",
            )
            os.chmod(fake_ssh, stat.S_IRWXU)

            env = dict(os.environ)
            env["TMUX_MANAGER_DIR"] = str(paths.support_dir)
            env["TMUX_MANAGER_WINDOW_CLASS"] = entry.window_class
            env["TMUX_MANAGER_SSH_BIN"] = str(fake_ssh)

            proc = subprocess.Popen(
                [str(paths.attach_script_path), entry.id],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
            try:
                store = StateStore(paths)
                state = None
                for _ in range(40):
                    live = store.live_states()
                    if entry.id in live and live[entry.id].ssh_pid:
                        state = live[entry.id]
                        break
                    time.sleep(0.05)
                self.assertIsNotNone(state)
                assert state is not None
                self.assertEqual(state.wrapper_pid, proc.pid)
                self.assertEqual(state.window_class, entry.window_class)
                first_ssh_pid = state.ssh_pid

                # SIGUSR1 reconnects in place and starts a replacement ssh pid.
                os.kill(proc.pid, signal.SIGUSR1)
                new_ssh_pid = None
                for _ in range(40):
                    live = store.live_states()
                    cur = live.get(entry.id)
                    if cur and cur.ssh_pid and cur.ssh_pid != first_ssh_pid:
                        new_ssh_pid = cur.ssh_pid
                        break
                    time.sleep(0.05)
                self.assertIsNotNone(new_ssh_pid)
                self.assertGreaterEqual(
                    len(invocations.read_text(encoding="utf-8").splitlines()), 2
                )
            finally:
                proc.terminate()
                proc.wait(timeout=5)

            # State file is removed on clean termination.
            self.assertEqual(StateStore(paths).live_states(), {})

    def test_app_model_open_activate_close_and_frame_save(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = Paths(Path(tmp))
            controller = _FakeController()
            model = AppModel(paths=paths, controller=controller, scheduler=_FakeScheduler())
            model.start()

            entry = Entry(id="e-open", host="host1", session="s1")
            self.assertTrue(model.add(entry))

            # First open creates a new window.
            model.open(entry)
            self.assertEqual(len(controller.created), 1)
            model.busy.clear()

            # Simulate an open wrapper + window geometry, then Close captures frame immediately.
            from tmux_manager.state_store import WrapperState

            model.states[entry.id] = WrapperState(
                entry_id=entry.id,
                wrapper_pid=999999,
                window_class=entry.window_class,
            )
            controller.window_frames[entry.window_class] = WindowFrame(
                window_class=entry.window_class,
                frame=Frame(120, 80, 900, 650),
                minimized=False,
            )
            model.open(entry)
            self.assertEqual(controller.activated, [entry.window_class])

            model.close_console(entry)
            self.assertEqual(controller.closed, [entry.window_class])
            self.assertNotIn(entry.id, model.states)
            saved = ConfigStore(paths).load().config
            self.assertEqual(saved.entry(entry.id).frame, Frame(120, 80, 900, 650))


if __name__ == "__main__":
    unittest.main()
