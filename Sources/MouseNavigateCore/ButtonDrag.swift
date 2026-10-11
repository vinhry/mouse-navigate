import Foundation

/// The way the mouse was moved while a side button was held.
public enum DragDirection: String, CaseIterable, Sendable {
    case up
    case down
    case left
    case right

    public var displayName: String {
        switch self {
        case .up: return "Drag ↑"
        case .down: return "Drag ↓"
        case .left: return "Drag ←"
        case .right: return "Drag →"
        }
    }
}

/// Everything one mouse button can be asked to do: pressed one of the ways, or held and
/// moved one of the directions.
public enum ButtonInput: Hashable, Sendable {
    case press(ButtonPress)
    case drag(DragDirection)

    public var displayName: String {
        switch self {
        case .press(let press): return press.displayName
        case .drag(let direction): return direction.displayName
        }
    }
}

/// Watches the pointer while a side button is held and says which way it was dragged,
/// once per press. The pointer is not held still: it moves the few dozen points the
/// threshold asks for, which is what the threshold is for.
public struct DragDirectionDetector: Equatable {
    public static let defaultThreshold = 30.0

    /// How far, in points along the dominant axis, the pointer has to travel.
    public let threshold: Double
    private var travel = Vector2.zero
    private var hasFired = false

    public init(threshold: Double = DragDirectionDetector.defaultThreshold) {
        self.threshold = threshold
    }

    /// Adds one dragged event's movement, in screen points with y growing downwards. The
    /// direction once the dominant axis passes the threshold, and nil after that.
    public mutating func moved(by delta: Vector2) -> DragDirection? {
        guard !hasFired else { return nil }
        travel = Vector2(x: travel.x + delta.x, y: travel.y + delta.y)
        let horizontal = abs(travel.x)
        let vertical = abs(travel.y)
        guard max(horizontal, vertical) >= threshold else { return nil }
        hasFired = true
        if vertical >= horizontal {
            return travel.y < 0 ? .up : .down
        }
        return travel.x < 0 ? .left : .right
    }

    public mutating func reset() {
        travel = .zero
        hasFired = false
    }
}
