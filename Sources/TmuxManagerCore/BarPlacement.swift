import Foundation

/// The bar's pinned corner: right and top edge, in Cocoa screen coordinates.
/// Content changes keep this corner fixed, so the bar grows and shrinks leftwards.
public struct BarAnchor: Equatable {
    public var right: Double
    public var top: Double

    public init(right: Double, top: Double) {
        self.right = right
        self.top = top
    }

    /// Anchor of an existing frame: its top-right corner.
    public init(topRightOf rect: ScreenRect) {
        self.init(right: rect.x + rect.w, top: rect.y + rect.h)
    }
}

public enum BarPlacement {
    /// Frame for a bar of `width` x `height` pinned at `anchor`.
    ///
    /// The right edge never moves because of a width change: a growing bar extends
    /// to the left. If that would push the left edge off `visible`, the bar is
    /// placed at `visible.x` instead, so it stays fully on screen.
    public static func frame(width: Double,
                             height: Double,
                             anchor: BarAnchor,
                             visible: ScreenRect) -> ScreenRect {
        var x = anchor.right - width
        if x < visible.x { x = visible.x }
        return ScreenRect(x: x, y: anchor.top - height, w: width, h: height)
    }
}
