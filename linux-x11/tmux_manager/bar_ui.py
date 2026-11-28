from __future__ import annotations

from typing import Callable, Dict, Optional, Tuple

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

from .app_model import AppModel
from .config import BarOrigin, Entry
from .entry_editor import EntryEditor
from .frame_clamp import BarAnchor, ScreenRect, place_bar
from .log import LOG

_LABEL_CHAR_LIMIT = 10
_BAR_HEIGHT = 44

_CSS = b"""
window.tm-bar-window {
    background-color: transparent;
}
.tm-bar-surface {
    background-color: rgba(32, 36, 44, 0.94);
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.14);
    padding: 7px 11px;
}
.tm-pill {
    border-radius: 13px;
    min-height: 26px;
    padding: 0 11px;
    border: 1px solid rgba(255, 255, 255, 0.22);
    background-color: rgba(255, 255, 255, 0.09);
    color: #f0f4f8;
}
.tm-pill:hover, .tm-pill.hovered {
    background-color: rgba(255, 255, 255, 0.18);
}
.tm-pill.active {
    background-color: rgba(52, 199, 89, 0.28);
    border-color: rgba(52, 199, 89, 0.85);
}
.tm-pill.active:hover, .tm-pill.active.hovered {
    background-color: rgba(39, 149, 67, 0.72);
}
.tm-pill-label {
    font-weight: 700;
    font-size: 13px;
    color: #f0f4f8;
}
button.tm-reconnect-btn {
    padding: 0 2px;
    min-width: 18px;
    min-height: 18px;
    border: none;
    background: transparent;
    box-shadow: none;
    color: #f0f4f8;
    font-size: 13px;
}
button.tm-reconnect-btn:hover {
    background: transparent;
}
button.tm-plus-btn {
    padding: 0;
    min-width: 26px;
    min-height: 26px;
    border-radius: 13px;
    border: none;
    background: transparent;
    box-shadow: none;
    color: #e6edf3;
    font-size: 16px;
    font-weight: 700;
}
button.tm-plus-btn:hover {
    background-color: rgba(255, 255, 255, 0.14);
}
.tm-error-label {
    color: #ff6b6b;
    font-size: 11px;
    font-weight: 600;
    padding: 0 4px;
}
"""


def _tooltip_for(entry: Entry) -> str:
    if entry.display_name == entry.address:
        return entry.address
    return f"{entry.display_name} — {entry.address}"


def _shorten(message: str, limit: int = 58) -> str:
    if len(message) <= limit:
        return message
    return message[: limit - 1] + "…"


class EntryPill(Gtk.EventBox):
    """One capsule in the bar: gray when closed, green when open."""

    def __init__(
        self,
        entry: Entry,
        on_open: Callable[[Entry], None],
        on_reconnect: Callable[[Entry], None],
        on_close: Callable[[Entry], None],
        on_plain_ssh: Callable[[Entry], None],
        on_edit: Callable[[Entry], None],
        on_remove: Callable[[Entry], None],
    ) -> None:
        super().__init__()
        self.entry = entry
        self.is_active = False
        self.is_busy = False
        self.is_reconnecting = False
        self._on_open = on_open
        self._on_reconnect = on_reconnect
        self._on_close = on_close
        self._on_plain_ssh = on_plain_ssh
        self._on_edit = on_edit
        self._on_remove = on_remove

        self.set_visible_window(False)
        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.ENTER_NOTIFY_MASK
            | Gdk.EventMask.LEAVE_NOTIFY_MASK
        )
        self.connect("button-press-event", self._on_button_press)
        self.connect("enter-notify-event", self._on_enter)
        self.connect("leave-notify-event", self._on_leave)
        self.connect("realize", self._on_realize)

        self._box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self._box.get_style_context().add_class("tm-pill")
        self._box.set_valign(Gtk.Align.CENTER)

        self._label = Gtk.Label(label="")
        self._label.get_style_context().add_class("tm-pill-label")
        self._label.set_valign(Gtk.Align.CENTER)
        self._box.pack_start(self._label, False, False, 0)

        self._spinner = Gtk.Spinner()
        self._spinner.set_size_request(14, 14)
        self._spinner.set_valign(Gtk.Align.CENTER)
        self._spinner.set_no_show_all(True)
        self._box.pack_start(self._spinner, False, False, 0)

        self._reconnect_btn = Gtk.Button.new_with_label("⟳")
        self._reconnect_btn.set_relief(Gtk.ReliefStyle.NONE)
        self._reconnect_btn.set_can_focus(False)
        self._reconnect_btn.get_style_context().add_class("tm-reconnect-btn")
        self._reconnect_btn.set_tooltip_text(
            "Force reconnect (ssh is restarted, the window stays)"
        )
        self._reconnect_btn.set_no_show_all(True)
        self._reconnect_btn.connect("clicked", self._on_reconnect_clicked)
        self._reconnect_btn.connect("button-press-event", self._on_reconnect_press)
        self._box.pack_start(self._reconnect_btn, False, False, 0)

        self.add(self._box)
        self.update(entry, False, False, False)

    def _on_realize(self, *_args) -> None:
        win = self.get_window()
        if win is not None:
            cursor = Gdk.Cursor.new_from_name(win.get_display(), "pointer")
            if cursor is not None:
                win.set_cursor(cursor)

    def update(
        self, entry: Entry, is_active: bool, is_busy: bool, is_reconnecting: bool
    ) -> None:
        self.entry = entry
        self.is_active = is_active
        self.is_busy = is_busy
        self.is_reconnecting = is_reconnecting

        self._label.set_text(entry.display_name[:_LABEL_CHAR_LIMIT])
        self.set_tooltip_text(_tooltip_for(entry))

        ctx = self._box.get_style_context()
        if is_active:
            ctx.add_class("active")
        else:
            ctx.remove_class("active")

        shows_reconnect_spinner = is_active and is_reconnecting
        if is_active and not shows_reconnect_spinner:
            self._reconnect_btn.show()
            self._reconnect_btn.set_sensitive(not is_busy)
        else:
            self._reconnect_btn.hide()

        if is_busy:
            self._spinner.show()
            self._spinner.start()
        else:
            self._spinner.stop()
            self._spinner.hide()

    def _on_enter(self, *_args) -> bool:
        self._box.get_style_context().add_class("hovered")
        return False

    def _on_leave(self, *_args) -> bool:
        self._box.get_style_context().remove_class("hovered")
        return False

    def _on_reconnect_clicked(self, *_args) -> None:
        if not self.is_busy:
            self._on_reconnect(self.entry)

    def _on_reconnect_press(self, _widget, event) -> bool:
        if event.button == 3:
            self._popup_menu(event)
            return True
        return False

    def _on_button_press(self, _widget, event) -> bool:
        if event.button == 1 and event.type == Gdk.EventType.BUTTON_PRESS:
            if not self.is_busy:
                self._on_open(self.entry)
            return True
        if event.button == 3:
            self._popup_menu(event)
            return True
        return False

    def _popup_menu(self, event) -> None:
        menu = Gtk.Menu()

        close_item = Gtk.MenuItem.new_with_label("Close")
        close_item.set_sensitive(self.is_active and not self.is_busy)
        close_item.connect("activate", lambda *_: self._on_close(self.entry))
        menu.append(close_item)

        menu.append(Gtk.SeparatorMenuItem())

        plain_item = Gtk.MenuItem.new_with_label("Plain SSH")
        plain_item.connect("activate", lambda *_: self._on_plain_ssh(self.entry))
        menu.append(plain_item)

        menu.append(Gtk.SeparatorMenuItem())

        edit_item = Gtk.MenuItem.new_with_label("Edit…")
        edit_item.connect("activate", lambda *_: self._on_edit(self.entry))
        menu.append(edit_item)

        remove_item = Gtk.MenuItem.new_with_label("Remove…")
        remove_item.connect("activate", lambda *_: self._on_remove(self.entry))
        menu.append(remove_item)

        menu.show_all()
        menu.popup_at_pointer(event)


class BarWindow(Gtk.Window):
    """Floating, borderless, draggable, right-edge-pinned bar."""

    def __init__(self, model: AppModel, debug_enabled: bool = False) -> None:
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.model = model
        self.debug_enabled = debug_enabled
        self._pills: Dict[str, EntryPill] = {}
        self._anchor: Optional[BarAnchor] = None
        self._applying_frame = False
        self._ready = False
        self._last_seen_origin: Optional[Tuple[int, int]] = None
        self._origin_timer: Optional[int] = None

        self._install_css()
        self._configure_window()
        self._build_layout()

        self.model.on_change = self._on_model_changed

    @staticmethod
    def _install_css() -> None:
        provider = Gtk.CssProvider()
        provider.load_from_data(_CSS)
        screen = Gdk.Screen.get_default()
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(
                screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def _configure_window(self) -> None:
        self.set_title("TmuxManager")
        self.set_role("tmux-manager-bar")
        self.get_style_context().add_class("tm-bar-window")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.stick()
        self.set_app_paintable(True)

        screen = self.get_screen()
        visual = screen.get_rgba_visual() if screen is not None else None
        if visual is not None and screen.is_composited():
            self.set_visual(visual)

        self.connect("configure-event", self._on_configure)
        self.connect("key-press-event", self._on_key_press)
        self.connect("delete-event", self._on_delete)

    def _build_layout(self) -> None:
        self._drag_box = Gtk.EventBox()
        self._drag_box.set_visible_window(True)
        self._drag_box.get_style_context().add_class("tm-bar-surface")
        self._drag_box.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self._drag_box.connect("button-press-event", self._on_bar_press)

        self._scroll = Gtk.ScrolledWindow()
        self._scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        self._scroll.set_shadow_type(Gtk.ShadowType.NONE)
        self._scroll.set_propagate_natural_width(True)
        self._scroll.set_propagate_natural_height(True)

        self._row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self._row.set_valign(Gtk.Align.CENTER)

        self._error_box = Gtk.EventBox()
        self._error_box.set_visible_window(False)
        self._error_box.set_no_show_all(True)
        self._error_box.connect("button-press-event", self._on_error_click)
        self._error_label = Gtk.Label(label="")
        self._error_label.get_style_context().add_class("tm-error-label")
        self._error_box.add(self._error_label)

        self._plus_btn = Gtk.Button.new_with_label("+")
        self._plus_btn.set_relief(Gtk.ReliefStyle.NONE)
        self._plus_btn.set_can_focus(False)
        self._plus_btn.get_style_context().add_class("tm-plus-btn")
        self._plus_btn.set_tooltip_text("Add host:session")
        self._plus_btn.connect("clicked", lambda *_: self.add_entry())

        self._scroll.add(self._row)
        self._drag_box.add(self._scroll)
        self.add(self._drag_box)

    def start(self) -> None:
        self.model.start()
        self._rebuild_row()
        self.show_all()
        self._refresh_geometry(initial=True)
        self._ready = True
        self._last_seen_origin = self.get_position()
        self._origin_timer = GLib.timeout_add_seconds(1, self._sample_origin)

    def shutdown(self) -> None:
        if self._origin_timer is not None:
            try:
                GLib.source_remove(self._origin_timer)
            except Exception:
                pass
            self._origin_timer = None
        EntryEditor.close_active()
        self.model.shutdown()

    def raise_bar(self) -> None:
        self.show()
        self.present()

    def add_entry(self) -> None:
        self.raise_bar()
        EntryEditor.present(entry=None, model=self.model, near=self)

    def _edit_entry(self, entry: Entry) -> None:
        EntryEditor.present(entry=entry, model=self.model, near=self)

    def _remove_entry(self, entry: Entry) -> None:
        dialog = Gtk.MessageDialog(
            transient_for=None,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.NONE,
            text=f"Remove {entry.display_name}?",
        )
        dialog.set_keep_above(True)
        secondary = (
            "The console window for this entry will be closed. "
            "The tmux session itself is only killed if you tick the box below."
            if self.model.is_active(entry)
            else "This only removes the entry from the bar."
        )
        dialog.format_secondary_text(secondary)

        kill_check = Gtk.CheckButton.new_with_label(
            f"Also kill the remote tmux session ({entry.session})"
        )
        kill_check.set_active(True)
        area = dialog.get_message_area()
        area.pack_end(kill_check, False, False, 6)
        kill_check.show()

        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        remove_btn = dialog.add_button("Remove", Gtk.ResponseType.OK)
        remove_btn.get_style_context().add_class("destructive-action")
        dialog.set_default_response(Gtk.ResponseType.OK)

        response = dialog.run()
        kill_remote = kill_check.get_active()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            self.model.remove(entry, kill_remote_session=kill_remote)

    # MARK: - Row updates & geometry

    def _on_model_changed(self) -> None:
        if not self._ready:
            return
        self._rebuild_row()
        self._refresh_geometry(initial=False)

    def _rebuild_row(self) -> None:
        for child in list(self._row.get_children()):
            self._row.remove(child)

        if self.model.error_message:
            self._error_label.set_text(_shorten(self.model.error_message))
            self._error_box.set_tooltip_text(
                f"{self.model.error_message} (click to dismiss)"
            )
            self._error_label.show()
            self._error_box.show()
            self._row.pack_start(self._error_box, False, False, 0)
        else:
            self._error_box.hide()

        live_ids = set()
        for entry in self.model.config.sorted_entries:
            pill = self._pills.get(entry.id)
            if pill is None:
                pill = EntryPill(
                    entry=entry,
                    on_open=self.model.open,
                    on_reconnect=self.model.reconnect,
                    on_close=self.model.close_console,
                    on_plain_ssh=self.model.open_plain_ssh,
                    on_edit=self._edit_entry,
                    on_remove=self._remove_entry,
                )
                self._pills[entry.id] = pill
            pill.update(
                entry=entry,
                is_active=self.model.is_active(entry),
                is_busy=self.model.is_busy(entry),
                is_reconnecting=self.model.is_reconnecting(entry),
            )
            pill.show_all()
            # Re-apply visibility of conditional widgets (spinner/reconnect)
            pill.update(
                entry=entry,
                is_active=self.model.is_active(entry),
                is_busy=self.model.is_busy(entry),
                is_reconnecting=self.model.is_reconnecting(entry),
            )
            live_ids.add(entry.id)
            self._row.pack_start(pill, False, False, 0)

        for eid in list(self._pills.keys()):
            if eid not in live_ids:
                self._pills.pop(eid, None)

        self._plus_btn.show()
        self._row.pack_start(self._plus_btn, False, False, 0)

    def _current_monitor_rect(self) -> Tuple[ScreenRect, list[ScreenRect]]:
        all_rects = self.model.controller.monitor_workareas()
        display = Gdk.Display.get_default()
        visible: Optional[ScreenRect] = None
        if display is not None and self.get_window() is not None:
            mon = display.get_monitor_at_window(self.get_window())
            if mon is not None:
                wa = mon.get_workarea()
                if wa.width > 0 and wa.height > 0:
                    visible = ScreenRect(
                        float(wa.x), float(wa.y), float(wa.width), float(wa.height)
                    )
        if visible is None:
            visible = all_rects[0] if all_rects else ScreenRect(0.0, 0.0, 1280.0, 800.0)
        if not all_rects:
            all_rects = [visible]
        return visible, all_rects

    def _refresh_geometry(self, initial: bool) -> None:
        visible, all_rects = self._current_monitor_rect()
        max_width = max(200.0, visible.w - 40.0)

        _, row_nat = self._row.get_preferred_size()
        content_w = float(max(120, row_nat.width + 24))
        width = min(content_w, max_width)
        height = float(max(_BAR_HEIGHT, row_nat.height + 16))

        self._scroll.set_size_request(int(max(96, width - 22)), int(height - 14))

        if initial:
            origin = self.model.bar_origin
            if origin is not None:
                x, y = origin.x, origin.y
            else:
                x = visible.right - width - 20.0
                y = visible.y + 20.0
            self._anchor = BarAnchor.from_rect(ScreenRect(x, y, width, height))

        if self._anchor is not None:
            placed = place_bar(width, height, self._anchor, visible)
            x, y = placed.x, placed.y
        else:
            cur_x, cur_y = self.get_position()
            x, y = float(cur_x), float(cur_y)

        x, y = self._clamp_origin(x, y, width, height, visible, all_rects)
        self._apply_frame(int(round(x)), int(round(y)), int(round(width)), int(round(height)))
        if self.debug_enabled:
            LOG.write(
                f"bar set=({x:.0f},{y:.0f},{width:.0f},{height:.0f}) "
                f"anchor={self._anchor}"
            )

    @staticmethod
    def _clamp_origin(
        x: float,
        y: float,
        w: float,
        h: float,
        visible: ScreenRect,
        all_rects: list[ScreenRect],
    ) -> Tuple[float, float]:
        bar = ScreenRect(x, y, w, h)
        reachable = any(r.intersection_area(bar) > 400.0 for r in all_rects)
        if not reachable:
            x = visible.right - w - 20.0
            y = visible.y + 20.0
        min_x = min(r.x for r in all_rects)
        max_x = max(r.right for r in all_rects)
        min_y = min(r.y for r in all_rects)
        max_y = max(r.bottom for r in all_rects)
        x = min(max(x, min_x), max(min_x, max_x - w))
        y = min(max(y, min_y), max(min_y, max_y - h))
        return x, y

    def _apply_frame(self, x: int, y: int, w: int, h: int) -> None:
        self._applying_frame = True
        try:
            self._drag_box.set_size_request(w, h)
            self.set_size_request(w, h)
            self.resize(w, h)
            self.move(x, y)
            self._last_seen_origin = (x, y)
        finally:
            GLib.idle_add(self._clear_applying_frame)

    def _clear_applying_frame(self) -> bool:
        self._applying_frame = False
        self._last_seen_origin = self.get_position()
        return False

    def apply_debug_frame(self, x: float, y: float, w: float, h: float) -> None:
        self._apply_frame(int(round(x)), int(round(y)), int(round(w)), int(round(h)))
        self._anchor = BarAnchor.from_rect(ScreenRect(x, y, w, h))

    # MARK: - Events

    def _on_bar_press(self, _widget, event) -> bool:
        if event.button == 1 and event.type == Gdk.EventType.BUTTON_PRESS:
            self.begin_move_drag(
                event.button, int(event.x_root), int(event.y_root), event.time
            )
            return True
        return False

    def _on_error_click(self, _widget, event) -> bool:
        if event.button == 1:
            self.model.dismiss_error()
            return True
        return False

    def _on_configure(self, *_args) -> bool:
        self._sample_origin()
        return False

    def _sample_origin(self) -> bool:
        if not self._ready or self._applying_frame:
            return True
        origin = self.get_position()
        if origin == self._last_seen_origin:
            return True
        self._last_seen_origin = origin
        w, _ = self.get_size()
        self._anchor = BarAnchor(right=float(origin[0] + w), top=float(origin[1]))
        if self.debug_enabled:
            LOG.write(f"bar moved to {origin} anchor={self._anchor}")
        self.model.set_bar_origin(BarOrigin(x=float(origin[0]), y=float(origin[1])))
        return True

    def _on_key_press(self, _widget, event) -> bool:
        ctrl = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        if ctrl and event.keyval in (Gdk.KEY_q, Gdk.KEY_Q):
            self.shutdown()
            Gtk.main_quit()
            return True
        if ctrl and event.keyval in (Gdk.KEY_n, Gdk.KEY_N):
            self.add_entry()
            return True
        return False

    def _on_delete(self, *_args) -> bool:
        self.shutdown()
        Gtk.main_quit()
        return False
