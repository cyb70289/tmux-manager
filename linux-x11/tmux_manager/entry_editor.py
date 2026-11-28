from __future__ import annotations

import threading
from typing import Optional

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

from .app_model import AppModel
from .config import Entry, is_valid_host, validate_entry, validation_message
from .shell import probe_ssh


class EntryEditor:
    """Floating add/edit window placed near the bar without moving the bar."""

    _active: Optional[EntryEditor] = None

    def __init__(self, model: AppModel, entry: Optional[Entry]) -> None:
        self.model = model
        self.original = entry
        self.window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.window.set_title(
            "Add Host:Session" if entry is None else f"Edit {entry.display_name}"
        )
        self.window.set_default_size(520, -1)
        self.window.set_resizable(False)
        self.window.set_keep_above(True)
        self.window.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        self.window.set_border_width(16)
        self.window.connect("destroy", self._on_destroy)
        self.window.connect("key-press-event", self._on_key_press)

        self.name_entry = self._make_entry("host:session")
        self.host_entry = self._make_entry("azure-japan or user@10.0.0.5")
        self.session_entry = self._make_entry("main")
        self.tmux_path_entry = self._make_entry("tmux")

        self.ssh_options_view = Gtk.TextView()
        self.ssh_options_view.set_monospace(True)
        self.ssh_options_view.set_wrap_mode(Gtk.WrapMode.NONE)
        self.ssh_options_view.set_left_margin(4)
        self.ssh_options_view.set_right_margin(4)
        self.ssh_options_view.set_top_margin(3)
        self.ssh_options_view.set_bottom_margin(3)

        opts_scroll = Gtk.ScrolledWindow()
        opts_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        opts_scroll.set_shadow_type(Gtk.ShadowType.IN)
        opts_scroll.set_size_request(340, 66)
        opts_scroll.add(self.ssh_options_view)

        self.detach_check = Gtk.CheckButton.new_with_label(
            "Detach other clients on reconnect (-D)"
        )

        grid = Gtk.Grid(row_spacing=8, column_spacing=12)
        rows = [
            ("Name", self.name_entry),
            ("SSH host", self.host_entry),
            ("tmux session", self.session_entry),
            ("tmux path", self.tmux_path_entry),
            ("Extra ssh options", opts_scroll),
            ("", self.detach_check),
        ]
        for row_idx, (text, widget) in enumerate(rows):
            if text:
                lbl = Gtk.Label(label=text)
                lbl.set_xalign(1.0)
                lbl.set_valign(
                    Gtk.Align.START if widget is opts_scroll else Gtk.Align.CENTER
                )
                grid.attach(lbl, 0, row_idx, 1, 1)
            widget.set_hexpand(True)
            grid.attach(widget, 1, row_idx, 1, 1)

        hint_text = (
            "Leave Name empty to show host:session. "
            "Host may be an ~/.ssh/config alias or user@host."
        )
        if entry is not None and model.is_active(entry):
            hint_text += (
                " This console is open: host/session changes apply after a reconnect."
            )
        hint_label = Gtk.Label(label=hint_text)
        hint_label.set_xalign(0.0)
        hint_label.set_line_wrap(True)
        hint_label.set_max_width_chars(64)
        hint_label.get_style_context().add_class("dim-label")

        self.status_label = Gtk.Label(label="")
        self.status_label.set_xalign(0.0)
        self.status_label.set_line_wrap(True)
        self.status_label.set_max_width_chars(64)

        self.test_btn = Gtk.Button.new_with_label("Test")
        self.test_btn.connect("clicked", self._on_test)
        cancel_btn = Gtk.Button.new_with_label("Cancel")
        cancel_btn.connect("clicked", lambda *_: self.window.destroy())
        self.save_btn = Gtk.Button.new_with_label("Save")
        self.save_btn.get_style_context().add_class("suggested-action")
        self.save_btn.set_can_default(True)
        self.save_btn.connect("clicked", self._on_save)

        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        btn_row.pack_start(self.test_btn, False, False, 0)
        btn_row.pack_end(self.save_btn, False, False, 0)
        btn_row.pack_end(cancel_btn, False, False, 0)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.pack_start(grid, False, False, 0)
        outer.pack_start(hint_label, False, False, 0)
        outer.pack_start(self.status_label, False, False, 0)
        outer.pack_start(btn_row, False, False, 0)
        self.window.add(outer)
        self.window.set_default(self.save_btn)

        self._fill(entry)

    @classmethod
    def present(
        cls, entry: Optional[Entry], model: AppModel, near: Optional[Gtk.Window]
    ) -> EntryEditor:
        cls.close_active()
        editor = cls(model, entry)
        cls._active = editor
        editor.window.show_all()
        editor._place_near(near)
        editor.window.present()
        editor.host_entry.grab_focus()
        return editor

    @classmethod
    def close_active(cls) -> None:
        if cls._active is not None:
            cls._active.window.destroy()
            cls._active = None

    def _make_entry(self, placeholder: str) -> Gtk.Entry:
        field = Gtk.Entry()
        field.set_placeholder_text(placeholder)
        field.set_width_chars(36)
        field.set_activates_default(True)
        return field

    def _fill(self, entry: Optional[Entry]) -> None:
        if entry is None:
            self.detach_check.set_active(True)
            return
        self.name_entry.set_text(entry.name or "")
        self.host_entry.set_text(entry.host)
        self.session_entry.set_text(entry.session)
        self.tmux_path_entry.set_text(entry.tmux_path or "")
        buf = self.ssh_options_view.get_buffer()
        buf.set_text("\n".join(entry.ssh_options))
        self.detach_check.set_active(entry.detach_other_clients)

    def _place_near(self, bar: Optional[Gtk.Window]) -> None:
        display = Gdk.Display.get_default()
        if display is None:
            return
        _, nat = self.window.get_preferred_size()
        win_w = max(nat.width, 520)
        win_h = max(nat.height, 340)

        monitor = None
        bar_x = bar_y = bar_w = bar_h = 0
        if bar is not None and bar.get_window() is not None:
            bar_x, bar_y = bar.get_position()
            bar_w, bar_h = bar.get_size()
            monitor = display.get_monitor_at_window(bar.get_window())
        if monitor is None:
            monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return
        wa = monitor.get_workarea()
        if bar is not None and bar_w > 0:
            x = bar_x + bar_w - win_w
            y = bar_y + bar_h + 8
        else:
            x = wa.x + (wa.width - win_w) // 2
            y = wa.y + (wa.height - win_h) // 2
        x = max(wa.x, min(x, wa.x + max(0, wa.width - win_w)))
        y = max(wa.y, min(y, wa.y + max(0, wa.height - win_h)))
        self.window.move(int(x), int(y))

    def _draft(self) -> Entry:
        buf = self.ssh_options_view.get_buffer()
        raw_opts = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True)
        options = [line.strip() for line in raw_opts.splitlines() if line.strip()]
        name = self.name_entry.get_text().strip() or None
        host = self.host_entry.get_text().strip()
        session = self.session_entry.get_text().strip()
        tmux_path = self.tmux_path_entry.get_text().strip() or None
        detach = self.detach_check.get_active()
        if self.original is not None:
            return Entry(
                id=self.original.id,
                name=name,
                host=host,
                session=session,
                tmux_path=tmux_path,
                ssh_options=options,
                detach_other_clients=detach,
                frame=self.original.frame,
            )
        return Entry(
            name=name,
            host=host,
            session=session,
            tmux_path=tmux_path,
            ssh_options=options,
            detach_other_clients=detach,
        )

    def _set_status(self, text: str, color: Optional[str] = None) -> None:
        if color:
            escaped = GLib.markup_escape_text(text)
            self.status_label.set_markup(
                f'<span foreground="{color}">{escaped}</span>'
            )
        else:
            self.status_label.set_text(text)

    def _on_test(self, *_) -> None:
        entry = self._draft()
        if not is_valid_host(entry.host):
            self._set_status("Enter an SSH host first.", "#e5534b")
            return
        self.test_btn.set_sensitive(False)
        self._set_status(f"Testing {entry.host}…", None)

        def _worker() -> None:
            result = probe_ssh(entry.host, entry.ssh_options)

            def _apply() -> bool:
                if not self.window.get_visible():
                    return False
                self.test_btn.set_sensitive(True)
                color_map = {
                    "ok": "#3fb950",
                    "tmux_missing": "#d29922",
                    "unverified": "#d29922",
                    "failed": "#e5534b",
                }
                self._set_status(result.summary, color_map.get(result.kind))
                return False

            GLib.idle_add(_apply)

        threading.Thread(target=_worker, daemon=True).start()

    def _on_save(self, *_) -> None:
        entry = self._draft()
        others = [e for e in self.model.config.entries if e.id != entry.id]
        msg = validation_message(validate_entry(entry, others + [entry]))
        if msg:
            self._set_status(msg, "#e5534b")
            return
        if self.original is None:
            if not self.model.add(entry, then_probe=True):
                return
        else:
            if not self.model.update(entry):
                return
        self.window.destroy()

    def _on_key_press(self, _widget, event) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self.window.destroy()
            return True
        return False

    def _on_destroy(self, *_) -> None:
        if EntryEditor._active is self:
            EntryEditor._active = None
