from __future__ import annotations

import os
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from tmux_manager.app_model import AppModel
from tmux_manager.config import Config, Entry, Frame
from tmux_manager.config_store import ConfigStore
from tmux_manager.frame_clamp import BarAnchor, ScreenRect, clamp_frame, place_bar
from tmux_manager.log import install_wrapper
from tmux_manager.paths import Paths
from tmux_manager.state_store import StateStore, WrapperState
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
        self.activated = []
        self.closed = []
        self.window_frames = {}
        self.workareas = [ScreenRect(0, 0, 1920, 1080)]

    def create_window(self, entry, frame, on_done):
        self.created.append((entry.id, frame))
        on_done(None)

    def open_shell_window(self, entry, on_done):
        on_done(None)

    def activate(self, window_class, on_done):
        self.activated.append(window_class)
        on_done(True)

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
    def test_config_roundtrip_and_env_generation(self) -> None:
        cfg = Config.from_dict(
            {
                "version": 1,
                "ui": {"bar_origin": {"x": 1380, "y": 40}},
                "entries": [
                    {
                        "id": "e2",
                        "host": "cyb@devbox",
                        "session": "main",
                        "ssh_options": ["-p", "2222"],
                        "detach_other_clients": True,
                        "frame": {"x": 400, "y": 300, "w": 800, "h": 600},
                    },
                    {"id": "e1", "name": "Alpha", "host": "box1", "session": "work"},
                ],
            }
        )
        self.assertEqual([e.id for e in cfg.sorted_entries], ["e1", "e2"])

        with tempfile.TemporaryDirectory() as tmp:
            store = ConfigStore(Paths(Path(tmp)))
            store.save(cfg)
            self.assertEqual(store.load().config, cfg)
            env_text = (Path(tmp) / "env" / "e2.sh").read_text(encoding="utf-8")
            self.assertIn("HOST='cyb@devbox'", env_text)
            self.assertIn("DETACH_OTHER_CLIENTS=1", env_text)

    def test_frame_clamp_and_bar_placement(self) -> None:
        screens = [ScreenRect(0, 0, 1920, 1080)]
        self.assertEqual(clamp_frame(Frame(100, 100, 800, 600), screens), Frame(100, 100, 800, 600))

        clamped = clamp_frame(Frame(5000, 2000, 800, 600), screens)
        self.assertLessEqual(clamped.x + clamped.w, 1920)
        self.assertLessEqual(clamped.y + clamped.h, 1080)

        placed = place_bar(400, 44, BarAnchor(right=1900, top=20), screens[0])
        self.assertEqual(placed, ScreenRect(1500, 20, 400, 44))
        self.assertEqual(place_bar(500, 44, BarAnchor(right=300, top=20), screens[0]).x, 0)

    def test_attach_wrapper_lifecycle_and_reconnect(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = Paths(Path(tmp))
            paths.prepare_directories()
            install_wrapper(
                Path(__file__).resolve().parent.parent / "resources" / "attach.sh",
                paths,
            )

            entry = Entry(id="e-wrap", host="dummyhost", session="work", detach_other_clients=True)
            ConfigStore(paths).save(Config(entries=[entry]))

            fake_ssh = Path(tmp) / "fake_ssh.sh"
            fake_ssh.write_text("#!/bin/bash\nsleep 30\n", encoding="utf-8")
            os.chmod(fake_ssh, stat.S_IRWXU)

            env = dict(
                os.environ,
                TMUX_MANAGER_DIR=str(paths.support_dir),
                TMUX_MANAGER_WINDOW_CLASS=entry.window_class,
                TMUX_MANAGER_SSH_BIN=str(fake_ssh),
            )
            proc = subprocess.Popen(
                [str(paths.attach_script_path), entry.id],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
            try:
                store = StateStore(paths)
                first_ssh_pid = None
                for _ in range(40):
                    cur = store.live_states().get(entry.id)
                    if cur and cur.ssh_pid:
                        first_ssh_pid = cur.ssh_pid
                        break
                    time.sleep(0.05)
                self.assertIsNotNone(first_ssh_pid)

                os.kill(proc.pid, signal.SIGUSR1)
                new_ssh_pid = None
                for _ in range(40):
                    cur = store.live_states().get(entry.id)
                    if cur and cur.ssh_pid and cur.ssh_pid != first_ssh_pid:
                        new_ssh_pid = cur.ssh_pid
                        break
                    time.sleep(0.05)
                self.assertIsNotNone(new_ssh_pid)
            finally:
                proc.terminate()
                proc.wait(timeout=5)

            self.assertEqual(StateStore(paths).live_states(), {})

    def test_app_model_open_activate_close_and_frame_save(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = Paths(Path(tmp))
            controller = _FakeController()
            model = AppModel(paths=paths, controller=controller, scheduler=_FakeScheduler())
            model.start()

            entry = Entry(id="e-open", host="host1", session="s1")
            self.assertTrue(model.add(entry))

            model.open(entry)
            self.assertEqual(len(controller.created), 1)
            model.busy.clear()

            model.states[entry.id] = WrapperState(
                entry_id=entry.id, wrapper_pid=999999, window_class=entry.window_class
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
            self.assertEqual(
                ConfigStore(paths).load().config.entry(entry.id).frame,
                Frame(120, 80, 900, 650),
            )


if __name__ == "__main__":
    unittest.main()
