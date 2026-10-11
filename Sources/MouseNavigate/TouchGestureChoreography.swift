import Foundation
import MouseNavigateCore

/// One finger in a gesture's preview: where it goes down and what it does there. Positions
/// are in a unit box over the surface, y downwards and the right hand assumed, like the
/// character templates; the preview mirrors them for the left hand.
struct FingerCue {
    enum Motion: Equatable {
        /// Down for the whole pass, out of the action's way.
        case rest
        /// Down and held, shown with a ring: a click held, or a corner pinned.
        case hold
        /// Goes down at `delay` and stays until the pass ends.
        case press
        /// Goes down and straight up again, `count` times.
        case tap(count: Int)
        /// A tap with a ring that spreads out, for a click.
        case click
        /// Lands, then moves to `to`, leaving a trail.
        case slide(to: Vector2)
    }

    var at: Vector2
    var motion: Motion
    /// Seconds into the pass before the finger acts. Rest and hold take no notice.
    var delay = 0.6

    /// Whether the finger is one that does something, so it is drawn in the accent colour.
    var isActive: Bool { motion != .rest }
}

/// The fingers that make a gesture, and whether the whole device moves with them.
struct GestureChoreography {
    var fingers: [FingerCue]
    /// A mouse that is pushed about, with the fingers pinned to it.
    var movesDevice = false
}

extension TouchGesture {
    /// How the gesture looks from above. Every gesture has one, so a new case cannot
    /// compile without a picture.
    var choreography: GestureChoreography {
        switch self {
        // MARK: Trackpad. Fingers lie across the middle, index on the left.
        case .trackpadOneFixLeftTap:
            return .init(fingers: [rest(0.58, 0.5), tap(0.36, 0.5)])
        case .trackpadOneFixRightTap:
            return .init(fingers: [rest(0.40, 0.5), tap(0.62, 0.5)])
        case .trackpadThreeFingerTap:
            return .init(fingers: [tap(0.35, 0.5), tap(0.50, 0.45), tap(0.65, 0.5)])
        case .trackpadOneFixTwoTap:
            return .init(fingers: [rest(0.35, 0.5), tap(0.52, 0.45), tap(0.66, 0.5)])
        case .trackpadOneFixTwoSlideDown:
            return .init(fingers: [
                rest(0.35, 0.5),
                slide(0.52, 0.30, to: 0.52, 0.70),
                slide(0.66, 0.33, to: 0.66, 0.73),
            ])
        case .trackpadOneFixTwoSlideUp:
            return .init(fingers: [
                rest(0.35, 0.5),
                slide(0.52, 0.70, to: 0.52, 0.30),
                slide(0.66, 0.73, to: 0.66, 0.33),
            ])
        case .trackpadClickTwoSlideDown:
            return .init(fingers: [
                FingerCue(at: Vector2(x: 0.35, y: 0.5), motion: .hold),
                slide(0.52, 0.30, to: 0.52, 0.70, delay: 0.8),
                slide(0.66, 0.33, to: 0.66, 0.73, delay: 0.8),
            ])
        case .trackpadTwoFixIndexDoubleTap:
            return .init(fingers: [rest(0.52, 0.45), rest(0.66, 0.5), tap(0.35, 0.5, count: 2)])
        case .trackpadIndexToPinky:
            return .init(fingers: [
                press(0.30, 0.50, delay: 0.3),
                press(0.44, 0.43, delay: 0.55),
                press(0.58, 0.45, delay: 0.8),
                press(0.72, 0.54, delay: 1.05),
            ])
        case .trackpadPinkyToIndex:
            return .init(fingers: [
                press(0.72, 0.54, delay: 0.3),
                press(0.58, 0.45, delay: 0.55),
                press(0.44, 0.43, delay: 0.8),
                press(0.30, 0.50, delay: 1.05),
            ])
        case .trackpadOneFixOneSlideDown:
            return .init(fingers: [rest(0.35, 0.5), slide(0.52, 0.30, to: 0.52, 0.70)])

        // MARK: Magic Mouse. The top is the front; fingers sit near it, index on the left.
        case .mouseMiddleFixIndexNearTap:
            return .init(fingers: [rest(0.64, 0.35), tap(0.42, 0.35)])
        case .mouseMiddleFixIndexFarTap:
            return .init(fingers: [rest(0.66, 0.35), tap(0.28, 0.44)])
        case .mouseMiddleFixIndexSlideLeft:
            return .init(fingers: [rest(0.66, 0.35), slide(0.46, 0.35, to: 0.22, 0.35)])
        case .mouseMiddleFixIndexSlideRight:
            return .init(fingers: [rest(0.74, 0.35), slide(0.28, 0.35, to: 0.52, 0.35)])
        case .mouseIndexFixMiddleSlideLeft:
            return .init(fingers: [rest(0.28, 0.35), slide(0.72, 0.35, to: 0.48, 0.35)])
        case .mouseIndexFixMiddleSlideRight:
            return .init(fingers: [rest(0.30, 0.35), slide(0.52, 0.35, to: 0.76, 0.35)])
        case .mouseTwoFixIndexSlideLeft:
            return .init(fingers: [rest(0.62, 0.33), rest(0.78, 0.40), slide(0.42, 0.35, to: 0.20, 0.35)])
        case .mouseTwoFixIndexSlideRight:
            return .init(fingers: [rest(0.68, 0.33), rest(0.82, 0.40), slide(0.26, 0.35, to: 0.50, 0.35)])
        case .mouseThreeFingerSwipeUp:
            return .init(fingers: [
                slide(0.34, 0.58, to: 0.34, 0.24),
                slide(0.50, 0.55, to: 0.50, 0.21),
                slide(0.66, 0.58, to: 0.66, 0.24),
            ])
        case .mouseThreeFingerSwipeDown:
            return .init(fingers: [
                slide(0.34, 0.24, to: 0.34, 0.58),
                slide(0.50, 0.21, to: 0.50, 0.55),
                slide(0.66, 0.24, to: 0.66, 0.58),
            ])
        case .mouseMiddleClick:
            return .init(fingers: [rest(0.64, 0.35), FingerCue(at: Vector2(x: 0.40, y: 0.52), motion: .click)])
        case .mouseCornerHold:
            return .init(
                fingers: [
                    FingerCue(at: Vector2(x: 0.30, y: 0.22), motion: .hold),
                    FingerCue(at: Vector2(x: 0.70, y: 0.78), motion: .hold),
                ],
                movesDevice: true
            )
        }
    }
}

// Short forms for the table above.
private func rest(_ x: Double, _ y: Double) -> FingerCue {
    FingerCue(at: Vector2(x: x, y: y), motion: .rest)
}

private func tap(_ x: Double, _ y: Double, count: Int = 1, delay: Double = 0.6) -> FingerCue {
    FingerCue(at: Vector2(x: x, y: y), motion: .tap(count: count), delay: delay)
}

private func press(_ x: Double, _ y: Double, delay: Double) -> FingerCue {
    FingerCue(at: Vector2(x: x, y: y), motion: .press, delay: delay)
}

private func slide(
    _ x: Double, _ y: Double, to toX: Double, _ toY: Double, delay: Double = 0.6
) -> FingerCue {
    FingerCue(at: Vector2(x: x, y: y), motion: .slide(to: Vector2(x: toX, y: toY)), delay: delay)
}
