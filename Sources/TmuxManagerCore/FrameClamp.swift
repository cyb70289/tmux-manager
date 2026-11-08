import Foundation

/// A rectangle in Cocoa screen coordinates (origin bottom-left of the primary display).
public struct ScreenRect: Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var area: Double { max(0, w) * max(0, h) }

    public func intersectionArea(_ other: ScreenRect) -> Double {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(x + w, other.x + other.w), y1 = min(y + h, other.y + other.h)
        return max(0, x1 - x0) * max(0, y1 - y0)
    }

    public func contains(_ point: (Double, Double)) -> Bool {
        point.0 >= x && point.0 <= x + w && point.1 >= y && point.1 <= y + h
    }
}

public enum FrameClamp {
    /// Minimum fraction of the window that must be visible for the frame to be kept as-is.
    public static let minimumVisibleFraction = 0.25

    /// Converts an AppleScript-space frame into Cocoa screen coordinates.
    public static func cocoaRect(from frame: Frame, primaryHeight: Double) -> ScreenRect {
        ScreenRect(x: frame.x, y: primaryHeight - (frame.y + frame.h), w: frame.w, h: frame.h)
    }

    /// Converts a Cocoa rect back into AppleScript-space frame.
    public static func appleScriptFrame(fromCocoa rect: ScreenRect, primaryHeight: Double) -> Frame {
        Frame(x: rect.x, y: primaryHeight - (rect.y + rect.h), w: rect.w, h: rect.h)
    }

    /// Returns a frame that is guaranteed to be reachable on one of `screens`.
    /// `screens` are Cocoa-space visible frames.
    public static func clamp(_ frame: Frame,
                             screens: [ScreenRect],
                             primaryHeight: Double) -> Frame {
        guard frame.isUsable, !screens.isEmpty else { return frame }
        let rect = cocoaRect(from: frame, primaryHeight: primaryHeight)
        let total = rect.area
        guard total > 0 else { return frame }

        let visible = screens.map { rect.intersectionArea($0) }.reduce(0, +)
        if visible / total >= minimumVisibleFraction { return frame }

        // Prefer the screen the window mostly sits on, else the nearest one.
        let target = screens.max { a, b in
            let ta = rect.intersectionArea(a) > 0 ? rect.intersectionArea(a) : -distance(rect, a)
            let tb = rect.intersectionArea(b) > 0 ? rect.intersectionArea(b) : -distance(rect, b)
            return ta < tb
        } ?? screens[0]

        var w = min(rect.w, target.w)
        var h = min(rect.h, target.h)
        w = max(w, 200)
        h = max(h, 150)
        var x = min(max(rect.x, target.x), target.x + target.w - w)
        var y = min(max(rect.y, target.y), target.y + target.h - h)
        x = max(x, target.x)
        y = max(y, target.y)
        return appleScriptFrame(fromCocoa: ScreenRect(x: x, y: y, w: w, h: h), primaryHeight: primaryHeight)
    }

    private static func distance(_ rect: ScreenRect, _ screen: ScreenRect) -> Double {
        let dx = max(screen.x - (rect.x + rect.w), rect.x - (screen.x + screen.w))
        let dy = max(screen.y - (rect.y + rect.h), rect.y - (screen.y + screen.h))
        return max(0, dx) + max(0, dy)
    }
}
