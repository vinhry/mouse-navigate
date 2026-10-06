import Foundation

extension Rect {
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }

    public func intersectionArea(with other: Rect) -> Double {
        let width = min(maxX, other.maxX) - max(minX, other.minX)
        let height = min(maxY, other.maxY) - max(minY, other.minY)
        return width > 0 && height > 0 ? width * height : 0
    }

    /// Windows rarely land on an exact frame: apps round to their own minimum sizes and
    /// the title bar can snap by a few points.
    public func approximatelyEquals(_ other: Rect, tolerance: Double = 12) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }
}

/// Window placement maths for the window actions. All rects use CoreGraphics global
/// coordinates (origin top-left of the primary display, +y down), which is what the
/// Accessibility API reports.
public enum WindowLayout {
    public enum Side {
        case left, right
    }

    public static let minimumSize = (width: 120.0, height: 80.0)

    /// The display a window mostly sits on.
    public static func screenIndex(for window: Rect, in screens: [Rect]) -> Int? {
        guard !screens.isEmpty else { return nil }

        let areas = screens.map { $0.intersectionArea(with: window) }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
            return best
        }
        // Entirely off-screen: fall back to whichever display is nearest its centre.
        return screens.indices.min(by: {
            distanceSquared(screens[$0], window) < distanceSquared(screens[$1], window)
        })
    }

    public static func half(_ side: Side, of screen: Rect) -> Rect {
        let width = (screen.width / 2).rounded(.down)
        switch side {
        case .left:
            return Rect(x: screen.minX, y: screen.minY, width: width, height: screen.height)
        case .right:
            return Rect(x: screen.maxX - width, y: screen.minY, width: width, height: screen.height)
        }
    }

    /// Where "Maximize Left/Right" should put a window. Repeating the action on a window that
    /// already fills that half carries it on to the neighbouring display, entering from the
    /// opposite edge, so a window can be walked across monitors.
    public static func halfTarget(_ side: Side, window: Rect, screens: [Rect]) -> Rect? {
        guard let index = screenIndex(for: window, in: screens) else { return nil }

        let screen = screens[index]
        let target = half(side, of: screen)
        guard window.approximatelyEquals(target),
              let neighbour = neighbourIndex(of: index, toward: side, in: screens)
        else {
            return target
        }
        return half(side == .left ? .right : .left, of: screens[neighbour])
    }

    /// The nearest display lying wholly to that side. A display stacked above or below,
    /// however its centre happens to sit, is not where a window walked sideways should go.
    /// Among several, one level with the origin wins over one placed diagonally.
    public static func neighbourIndex(of index: Int, toward side: Side, in screens: [Rect]) -> Int? {
        let origin = screens[index]
        let tolerance = 1.0
        let candidates = screens.indices.filter { candidate in
            guard candidate != index else { return false }
            switch side {
            case .left: return screens[candidate].maxX <= origin.minX + tolerance
            case .right: return screens[candidate].minX >= origin.maxX - tolerance
            }
        }
        let level = candidates.filter { candidate in
            min(screens[candidate].maxY, origin.maxY) - max(screens[candidate].minY, origin.minY) > 0
        }
        return (level.isEmpty ? candidates : level).min(by: {
            abs(screens[$0].midX - origin.midX) < abs(screens[$1].midX - origin.midX)
        })
    }

    public static func moved(_ frame: Rect, by delta: Vector2) -> Rect {
        Rect(x: frame.minX + delta.x, y: frame.minY + delta.y, width: frame.width, height: frame.height)
    }

    /// Resizing drags the bottom-right corner, never below a usable minimum.
    public static func resized(_ frame: Rect, by delta: Vector2) -> Rect {
        Rect(
            x: frame.minX,
            y: frame.minY,
            width: max(frame.width + delta.x, minimumSize.width),
            height: max(frame.height + delta.y, minimumSize.height)
        )
    }

    private static func distanceSquared(_ a: Rect, _ b: Rect) -> Double {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy
    }
}
