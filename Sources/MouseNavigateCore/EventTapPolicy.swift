import Foundation

/// The kinds of event the event tap is asked for. Named here rather than as CoreGraphics
/// types so the choice can be tested; the app maps each to its `CGEventType`.
public enum TapEventKind: CaseIterable, Hashable {
    case otherMouseDown, otherMouseUp, otherMouseDragged
    case keyDown, keyUp, flagsChanged
    case scrollWheel
    case leftMouseDown, leftMouseUp
    case rightMouseDown, rightMouseDragged, rightMouseUp
}

/// Clicks, keystrokes and scrolls only pass through the tap while something needs them, so
/// with the keyboard cursor, gestures and scroll options off neither the pointer nor the
/// keyboard ever waits on this process.
public enum EventTapPolicy {
    public static func kinds(
        cursorMode: Bool,
        touch: Bool,
        scrollOptions: Bool,
        dragBindings: Bool
    ) -> Set<TapEventKind> {
        // Side-button releases are rare enough to take always: a hold or double-click needs them.
        var kinds: Set<TapEventKind> = [.otherMouseDown, .otherMouseUp]
        if cursorMode {
            kinds.formUnion([.keyDown, .keyUp, .flagsChanged])
        }
        if touch {
            // Gestures hold back the scrolls and clicks they take over, and the right and
            // middle buttons draw.
            kinds.formUnion([
                .scrollWheel, .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .otherMouseDragged,
            ])
        } else if scrollOptions {
            kinds.insert(.scrollWheel)
        }
        // Side-button drags are only worth the trip while a button is bound to one.
        if dragBindings {
            kinds.insert(.otherMouseDragged)
        }
        return kinds
    }
}

/// `kCGScrollWheelEventScrollPhase`: where a continuous scroll is, from fingers landing to
/// lifting. Raw values are CoreGraphics's.
public enum ScrollPhase: Int, Equatable, Sendable {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

/// `kCGScrollWheelEventMomentumPhase`: the coast after the fingers lift. Raw values are
/// CoreGraphics's.
public enum MomentumPhase: Int, Equatable, Sendable {
    case none = 0
    case begin = 1
    case `continue` = 2
    case end = 3
}

/// Once a touch gesture has claimed a scroll, the rest of that scroll is its too: the moves
/// that follow and the momentum after the fingers lift, which would otherwise fling the page
/// the moment the drawn letter was done. The gesture's end still reaches the app, so a
/// scroll it had begun is finished rather than left hanging.
public struct ScrollSessionSuppressor: Equatable {
    private var isSuppressing = false

    public init() {}

    /// A continuous scroll in `phase` (nil during momentum), with `gestureClaims` saying
    /// whether a gesture is using the fingers now. True when the event is to be swallowed.
    public mutating func shouldSuppress(phase: ScrollPhase?, gestureClaims: Bool) -> Bool {
        if phase == .began || phase == .mayBegin {
            isSuppressing = false
        }
        if gestureClaims {
            isSuppressing = true
        }
        guard isSuppressing else { return false }
        return !(phase == .ended || phase == .cancelled)
    }

    public mutating func reset() {
        isSuppressing = false
    }
}
