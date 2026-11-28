from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence, Tuple

from .config import Frame


@dataclass(frozen=True)
class ScreenRect:
    """Rectangle in X11 screen coordinates (origin top-left, y grows downward)."""

    x: float
    y: float
    w: float
    h: float

    @property
    def area(self) -> float:
        return max(0.0, self.w) * max(0.0, self.h)

    @property
    def right(self) -> float:
        return self.x + self.w

    @property
    def bottom(self) -> float:
        return self.y + self.h

    def intersection_area(self, other: ScreenRect) -> float:
        x0 = max(self.x, other.x)
        y0 = max(self.y, other.y)
        x1 = min(self.right, other.right)
        y1 = min(self.bottom, other.bottom)
        return max(0.0, x1 - x0) * max(0.0, y1 - y0)

    def contains(self, point: Tuple[float, float]) -> bool:
        px, py = point
        return self.x <= px <= self.right and self.y <= py <= self.bottom


MINIMUM_VISIBLE_FRACTION = 0.25


def _distance(rect: ScreenRect, screen: ScreenRect) -> float:
    dx = max(screen.x - rect.right, rect.x - screen.right)
    dy = max(screen.y - rect.bottom, rect.y - screen.bottom)
    return max(0.0, dx) + max(0.0, dy)


def clamp_frame(frame: Frame, screens: Sequence[ScreenRect]) -> Frame:
    """Keep a frame on-screen; frames <25% visible move onto the nearest monitor."""
    if not frame.is_usable or not screens:
        return frame
    rect = ScreenRect(frame.x, frame.y, frame.w, frame.h)
    total = rect.area
    if total <= 0:
        return frame

    visible = sum(rect.intersection_area(s) for s in screens)
    if visible / total >= MINIMUM_VISIBLE_FRACTION:
        return frame

    def score(s: ScreenRect) -> float:
        inter = rect.intersection_area(s)
        return inter if inter > 0 else -_distance(rect, s)

    target = max(screens, key=score)
    w = max(200.0, min(rect.w, target.w))
    h = max(150.0, min(rect.h, target.h))
    x = min(max(rect.x, target.x), target.right - w)
    y = min(max(rect.y, target.y), target.bottom - h)
    x = max(x, target.x)
    y = max(y, target.y)
    return Frame(x=x, y=y, w=w, h=h)


@dataclass(frozen=True)
class BarAnchor:
    """Pinned top-right corner of the floating bar in X11 top-left coordinates."""

    right: float
    top: float

    @classmethod
    def from_rect(cls, rect: ScreenRect) -> BarAnchor:
        return cls(right=rect.x + rect.w, top=rect.y)


def place_bar(
    width: float,
    height: float,
    anchor: BarAnchor,
    visible: ScreenRect,
) -> ScreenRect:
    """Keep the right edge fixed so content growth extends leftwards."""
    x = anchor.right - width
    if x < visible.x:
        x = visible.x
    return ScreenRect(x=x, y=anchor.top, w=width, h=height)
