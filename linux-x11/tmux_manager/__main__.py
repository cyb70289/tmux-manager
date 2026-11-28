from __future__ import annotations

import argparse
import json
import signal
import sys
from typing import Any, Dict, List, Optional

from .config import Entry
from .ipc import ControlServer, send_ipc_command
from .log import LOG
from .paths import Paths


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="tmux-manager",
        description="Floating X11 bar for remote tmux sessions in WezTerm.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable verbose logging and the local IPC debug hook.",
    )
    parser.add_argument(
        "--send",
        metavar="JSON",
        help="Send a JSON command to the running instance (requires --debug on the app) and exit.",
    )
    return parser.parse_args(argv)


def _handle_debug_command(
    msg: Dict[str, Any], model, bar
) -> Dict[str, Any]:
    action = str(msg.get("action", ""))
    if action == "raise":
        bar.raise_bar()
        return {"ok": True}
    LOG.write(f"debug action {action} {msg}")
    if action == "status":
        return {
            "ok": True,
            "entries": [e.to_dict() for e in model.config.sorted_entries],
            "active": sorted(model.states.keys()),
            "busy": sorted(model.busy),
            "error": model.error_message,
            "bar_position": list(bar.get_position()),
            "bar_size": list(bar.get_size()),
        }
    if action == "quit":
        bar.shutdown()
        from gi.repository import Gtk

        Gtk.main_quit()
        return {"ok": True}
    if action == "sizebar":
        bar.apply_debug_frame(
            float(msg["x"]), float(msg["y"]), float(msg["w"]), float(msg["h"])
        )
        return {"ok": True}
    if action == "add" and isinstance(msg.get("entry"), dict):
        entry = Entry.from_dict(msg["entry"])
        ok = model.add(entry)
        return {"ok": ok, "id": entry.id}
    if action == "editor":
        bar.add_entry()
        return {"ok": True}
    if action == "closeeditor":
        from .entry_editor import EntryEditor

        EntryEditor.close_active()
        return {"ok": True}
    if action == "reload":
        model.reload_from_disk()
        return {"ok": True}
    if action == "capture":
        model.capture_frames()
        return {"ok": True}

    entry_id = msg.get("entry")
    entry = model.config.entry(str(entry_id)) if entry_id else None
    if entry is None:
        return {"ok": False, "error": f"unknown action or entry: {action}"}
    if action == "open":
        model.open(entry)
    elif action == "plain_ssh":
        model.open_plain_ssh(entry)
    elif action == "reconnect":
        model.reconnect(entry)
    elif action == "close":
        model.close_console(entry)
    elif action == "remove":
        model.remove(entry, kill_remote_session=bool(msg.get("kill", False)))
    elif action == "update" and isinstance(msg.get("entry"), dict):
        patch = Entry.from_dict(msg["entry"])
        patch.id = entry.id
        return {"ok": model.update(patch)}
    else:
        return {"ok": False, "error": f"unsupported action: {action}"}
    return {"ok": True}


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)
    paths = Paths.default()

    if args.send:
        try:
            payload = json.loads(args.send)
        except ValueError as exc:
            print(f"Invalid JSON for --send: {exc}", file=sys.stderr)
            return 2
        reply = send_ipc_command(paths.socket_path, payload, timeout=5.0)
        if reply is None:
            print("TmuxManager is not running.", file=sys.stderr)
            return 1
        print(json.dumps(reply))
        return 0 if reply.get("ok") else 1

    # Single-instance check: raise existing bar if already running.
    if send_ipc_command(paths.socket_path, {"action": "raise"}, timeout=2.0) is not None:
        return 0

    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import GLib, Gtk

    from .app_model import AppModel
    from .bar_ui import BarWindow

    debug_enabled = args.debug or paths.debug_flag_path.exists()
    model = AppModel(paths=paths)
    bar = BarWindow(model=model, debug_enabled=debug_enabled)

    server = ControlServer(
        socket_path=paths.socket_path,
        debug_enabled=debug_enabled,
        on_command=lambda msg: _handle_debug_command(msg, model, bar),
    )
    if not server.start():
        send_ipc_command(paths.socket_path, {"action": "raise"}, timeout=0.5)
        return 0

    def _handle_signal(*_args) -> bool:
        bar.shutdown()
        Gtk.main_quit()
        return False

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, _handle_signal)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, _handle_signal)

    try:
        bar.start()
        Gtk.main()
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
