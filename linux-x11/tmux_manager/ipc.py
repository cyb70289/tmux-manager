from __future__ import annotations

import json
import os
import socket
import threading
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from .log import LOG

try:
    from gi.repository import GLib
except Exception:
    GLib = None


def send_ipc_command(socket_path: Path, payload: Dict[str, Any], timeout: float = 1.5) -> Optional[Dict[str, Any]]:
    """Send a JSON command to a running instance; returns None if none is listening."""
    if not socket_path.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path))
            sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            sock.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                chunks.append(data)
            if not chunks:
                return {"ok": True}
            return json.loads(b"".join(chunks).decode("utf-8", errors="replace"))
    except OSError:
        return None
    except ValueError:
        return {"ok": True}


class ControlServer:
    """Single-instance Unix domain socket (raises existing bar; handles --debug actions)."""

    def __init__(
        self,
        socket_path: Path,
        debug_enabled: bool,
        on_command: Callable[[Dict[str, Any]], Dict[str, Any]],
    ) -> None:
        self.socket_path = socket_path
        self.debug_enabled = debug_enabled
        self._on_command = on_command
        self._sock: Optional[socket.socket] = None
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> bool:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists():
            # Probe whether an existing instance owns the socket.
            if send_ipc_command(self.socket_path, {"action": "ping"}, timeout=0.5) is not None:
                return False
            try:
                self.socket_path.unlink()
            except OSError:
                pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(self.socket_path))
        os.chmod(self.socket_path, 0o600)
        sock.listen(8)
        sock.settimeout(0.5)
        self._sock = sock
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        if self.debug_enabled:
            LOG.write(f"debug control socket listening at {self.socket_path}")
        return True

    def stop(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        try:
            self.socket_path.unlink()
        except OSError:
            pass

    def _serve(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()

    def _handle_conn(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(2.0)
            try:
                raw = b""
                while b"\n" not in raw and len(raw) < 65536:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    raw += chunk
                msg = json.loads(raw.decode("utf-8"))
                if not isinstance(msg, dict):
                    raise ValueError("command must be a JSON object")
            except Exception as exc:
                self._reply(conn, {"ok": False, "error": str(exc)})
                return

            action = str(msg.get("action", ""))
            if action == "ping":
                self._reply(conn, {"ok": True})
                return
            if action != "raise" and not self.debug_enabled:
                self._reply(conn, {"ok": False, "error": "debug mode is disabled"})
                return
            if action == "raise":
                if GLib is not None:
                    GLib.idle_add(lambda: (self._on_command(msg), False)[1])
                else:
                    self._on_command(msg)
                self._reply(conn, {"ok": True})
                return

            done = threading.Event()
            response: Dict[str, Any] = {"ok": True}

            def _run_on_main() -> bool:
                nonlocal response
                try:
                    response = self._on_command(msg)
                except Exception as exc:
                    response = {"ok": False, "error": str(exc)}
                finally:
                    done.set()
                return False

            if GLib is not None:
                GLib.idle_add(_run_on_main)
                done.wait(timeout=5.0)
            else:
                _run_on_main()
            self._reply(conn, response)

    @staticmethod
    def _reply(conn: socket.socket, payload: Dict[str, Any]) -> None:
        try:
            conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        except OSError:
            pass
