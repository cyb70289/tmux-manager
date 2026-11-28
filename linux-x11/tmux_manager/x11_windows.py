from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional

from .config import Frame
from .frame_clamp import ScreenRect
from .log import LOG


@dataclass(frozen=True)
class WindowFrame:
    window_class: str
    frame: Frame
    minimized: bool


class X11WindowManager:
    """EWMH/X11 window inspection and control via libwnck3 + Gdk (lazy-loaded)."""

    def __init__(self) -> None:
        self._initialized = False
        self._wnck = None
        self._gdk = None
        self._gtk = None
        self._wnck_screen = None

    def _ensure_loaded(self) -> None:
        if self._initialized:
            return
        self._initialized = True
        try:
            import gi

            gi.require_version("Gtk", "3.0")
            gi.require_version("Gdk", "3.0")
            from gi.repository import Gdk, Gtk

            self._gdk = Gdk
            self._gtk = Gtk
            try:
                gi.require_version("Wnck", "3.0")
                from gi.repository import Wnck

                self._wnck = Wnck
                screen = Wnck.Screen.get_default()
                if screen is not None:
                    screen.force_update()
                    self._wnck_screen = screen
            except Exception as exc:
                LOG.write(f"wnck unavailable: {exc}")
        except Exception as exc:
            LOG.write(f"gtk/gdk unavailable: {exc}")

    @property
    def available(self) -> bool:
        self._ensure_loaded()
        return self._wnck_screen is not None

    def _timestamp(self) -> int:
        if self._gtk is not None:
            ts = int(self._gtk.get_current_event_time())
            if ts > 0:
                return ts
        return int(time.monotonic() * 1000) & 0xFFFFFFFF

    def _refresh(self):
        self._ensure_loaded()
        if self._wnck_screen is None:
            return None
        try:
            self._wnck_screen.force_update()
        except Exception:
            pass
        return self._wnck_screen

    def _find_window(self, window_class: str):
        screen = self._refresh()
        if screen is None or not window_class:
            return None
        target = window_class.casefold()
        for win in screen.get_windows():
            inst = (win.get_class_instance_name() or "").casefold()
            grp = (win.get_class_group_name() or "").casefold()
            if inst == target or grp == target:
                return win
        return None

    def has_window(self, window_class: str) -> bool:
        return self._find_window(window_class) is not None

    def activate(self, window_class: str) -> bool:
        win = self._find_window(window_class)
        if win is None:
            return False
        ts = self._timestamp()
        try:
            workspace = win.get_workspace()
            screen = self._wnck_screen
            if workspace is not None and screen is not None:
                active_ws = screen.get_active_workspace()
                if active_ws is None or active_ws != workspace:
                    workspace.activate(ts)
            if win.is_minimized():
                win.unminimize(ts)
            win.activate(ts)
            return True
        except Exception as exc:
            LOG.write(f"x11 activate failed for {window_class}: {exc}")
            return False

    def close(self, window_class: str) -> bool:
        win = self._find_window(window_class)
        if win is None:
            return False
        try:
            win.close(self._timestamp())
            return True
        except Exception as exc:
            LOG.write(f"x11 close failed for {window_class}: {exc}")
            return False

    def apply_geometry(self, window_class: str, frame: Frame) -> bool:
        win = self._find_window(window_class)
        if win is None or not frame.is_usable or self._wnck is None:
            return False
        try:
            if win.is_maximized():
                win.unmaximize()
            mask = (
                self._wnck.WindowMoveResizeMask.X
                | self._wnck.WindowMoveResizeMask.Y
                | self._wnck.WindowMoveResizeMask.WIDTH
                | self._wnck.WindowMoveResizeMask.HEIGHT
            )
            win.set_geometry(
                self._wnck.WindowGravity.STATIC,
                mask,
                int(round(frame.x)),
                int(round(frame.y)),
                int(round(frame.w)),
                int(round(frame.h)),
            )
            return True
        except Exception as exc:
            LOG.write(f"x11 set_geometry failed for {window_class}: {exc}")
            return False

    def frames(self, wanted_classes: Iterable[str]) -> Dict[str, WindowFrame]:
        screen = self._refresh()
        if screen is None:
            return {}
        lookup = {c.casefold(): c for c in wanted_classes if c}
        if not lookup:
            return {}
        out: Dict[str, WindowFrame] = {}
        for win in screen.get_windows():
            inst = (win.get_class_instance_name() or "").casefold()
            grp = (win.get_class_group_name() or "").casefold()
            canonical = lookup.get(inst) or lookup.get(grp)
            if not canonical:
                continue
            try:
                x, y, w, h = win.get_geometry()
                out[canonical] = WindowFrame(
                    window_class=canonical,
                    frame=Frame(x=float(x), y=float(y), w=float(w), h=float(h)),
                    minimized=bool(win.is_minimized()),
                )
            except Exception:
                continue
        return out

    def monitor_workareas(self) -> List[ScreenRect]:
        try:
            import gi

            gi.require_version("Gdk", "3.0")
            from gi.repository import Gdk
        except Exception:
            return []
        display = Gdk.Display.get_default()
        if display is None:
            return []
        rects: List[ScreenRect] = []
        for idx in range(display.get_n_monitors()):
            mon = display.get_monitor(idx)
            if mon is None:
                continue
            wa = mon.get_workarea()
            if wa.width > 0 and wa.height > 0:
                rects.append(
                    ScreenRect(
                        x=float(wa.x),
                        y=float(wa.y),
                        w=float(wa.width),
                        h=float(wa.height),
                    )
                )
        return rects
