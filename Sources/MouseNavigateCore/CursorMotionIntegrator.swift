import Foundation

/// Keyboard-driven motion from one tick to the next: which movement keys are held, how
/// long the speed has been ramping up, and the fractions of a point carried between ticks.
///
/// Knows nothing of screens or events, and keeps no clock: every call is given the time.
/// The engine calls `tick` on a timer while `isMoving`, keeps the pointer on the screens,
/// and posts what each tick says.
public struct CursorMotionIntegrator: Equatable {
    public enum Step: Equatable {
        case none
        /// Points to move the pointer by, with +y down the screen.
        case move(dx: Int, dy: Int)
        /// Pixels to scroll by, as the wheel counts them: positive scrolls the content up
        /// or left, the opposite of the pointer's axes.
        case scroll(dx: Int, dy: Int)
    }

    /// The tick interval the scroll speed is written for.
    public static let nominalTick: TimeInterval = 0.008
    /// The step assumed for the first tick, which has no earlier one to measure from.
    static let firstTick: TimeInterval = 1.0 / 120.0
    /// The longest step one tick may take, so a main thread that stalled for a moment
    /// does not fling the pointer across the screen when it comes back.
    static let longestTick: TimeInterval = 0.1

    private static let movementKeys: Set<CursorBinding> = [.moveUp, .moveDown, .moveLeft, .moveRight]

    public private(set) var heldDirections: Set<CursorBinding> = []
    public private(set) var isScrolling = false
    private var rampStart: TimeInterval = 0
    private var lastTick: TimeInterval?
    private var moveRemainder = SubPixelAccumulator()
    private var scrollRemainder = SubPixelAccumulator()

    public init() {}

    /// Whether any movement key is held, which is when ticks are wanted.
    public var isMoving: Bool { !heldDirections.isEmpty }

    /// A movement key went down. Returns true when it was not held already: the ramp
    /// starts again from rest, and with no key held before, so does the tick clock.
    @discardableResult
    public mutating func press(_ key: CursorBinding, at now: TimeInterval) -> Bool {
        guard CursorMotionIntegrator.movementKeys.contains(key) else { return false }
        let wasIdle = heldDirections.isEmpty
        guard heldDirections.insert(key).inserted else { return false }
        if wasIdle {
            lastTick = nil
        }
        restartRamp(at: now)
        return true
    }

    /// A movement key came up. The ramp starts again for the keys still held; with none
    /// left, motion stops.
    public mutating func release(_ key: CursorBinding, at now: TimeInterval) {
        guard heldDirections.remove(key) != nil else { return }
        if heldDirections.isEmpty {
            lastTick = nil
        } else {
            restartRamp(at: now)
        }
    }

    /// The scroll modifier went down or up. The ramp starts again either way, so speed
    /// built up moving never carries over into scrolling, or back.
    public mutating func setScrolling(_ scrolling: Bool, at now: TimeInterval) {
        isScrolling = scrolling
        restartRamp(at: now)
    }

    /// Forgets everything, for when cursor mode ends.
    public mutating func reset() {
        self = CursorMotionIntegrator()
    }

    public mutating func tick(at now: TimeInterval, tier: SpeedTier, profile: CursorSpeedProfile) -> Step {
        let elapsed = lastTick.map { min(now - $0, CursorMotionIntegrator.longestTick) }
            ?? CursorMotionIntegrator.firstTick
        lastTick = now

        let direction = CursorMotion.direction(
            up: heldDirections.contains(.moveUp),
            down: heldDirections.contains(.moveDown),
            left: heldDirections.contains(.moveLeft),
            right: heldDirections.contains(.moveRight)
        )
        guard !direction.isZero else { return .none }

        let held = now - rampStart

        if isScrolling {
            let eased = CursorMotion.easedRamp(heldDuration: held, acceleration: profile.acceleration)
            // Scrolling runs on the same ramp, scaled to a per-tick pixel budget, and by
            // the real tick length too, so a busy main thread slows nothing down.
            let perTick = profile.scrollSpeed * (0.35 + 0.65 * eased) * tier.multiplier(using: profile)
                * (elapsed / CursorMotionIntegrator.nominalTick)
            let step = scrollRemainder.take(Vector2(x: direction.x * perTick, y: direction.y * perTick))
            guard step.dx != 0 || step.dy != 0 else { return .none }
            return .scroll(dx: -step.dx, dy: -step.dy)
        }

        let speed = CursorMotion.speed(heldDuration: held, tier: tier, profile: profile)
        let step = moveRemainder.take(Vector2(x: direction.x * speed * elapsed, y: direction.y * speed * elapsed))
        guard step.dx != 0 || step.dy != 0 else { return .none }
        return .move(dx: step.dx, dy: step.dy)
    }

    private mutating func restartRamp(at now: TimeInterval) {
        rampStart = now
        moveRemainder.reset()
        scrollRemainder.reset()
    }
}
