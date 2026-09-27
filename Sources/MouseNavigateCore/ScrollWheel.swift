import Foundation

/// How a mouse wheel's scrolling is reshaped. Trackpads and the Magic Mouse scroll
/// continuously and are never touched.
public struct ScrollSettings: Equatable {
    public var isReversed: Bool
    public var speed: Double
    public var isSmooth: Bool

    public static let speedRange: ClosedRange<Double> = 0.5...4
    public static let standard = ScrollSettings(isReversed: false, speed: 1, isSmooth: false)

    public init(isReversed: Bool, speed: Double, isSmooth: Bool) {
        self.isReversed = isReversed
        self.speed = ScrollSettings.clampSpeed(speed)
        self.isSmooth = isSmooth
    }

    /// Whether wheel events need to pass through the app at all.
    public var isActive: Bool {
        self != .standard
    }

    public static func clampSpeed(_ speed: Double) -> Double {
        min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }
}

/// One wheel event's movement on both axes, in the three forms a scroll event carries it.
/// Axis 1 is vertical and axis 2 horizontal, as CoreGraphics numbers them.
public struct ScrollDelta: Equatable {
    public var lines: (vertical: Int, horizontal: Int)
    public var fixedLines: (vertical: Double, horizontal: Double)
    public var points: (vertical: Double, horizontal: Double)

    public init(
        lines: (vertical: Int, horizontal: Int),
        fixedLines: (vertical: Double, horizontal: Double),
        points: (vertical: Double, horizontal: Double)
    ) {
        self.lines = lines
        self.fixedLines = fixedLines
        self.points = points
    }

    public static func == (lhs: ScrollDelta, rhs: ScrollDelta) -> Bool {
        lhs.lines == rhs.lines && lhs.fixedLines == rhs.fixedLines && lhs.points == rhs.points
    }
}

public enum ScrollTransform {
    /// Reverses and scales every form of the delta alike, so an app gets the same answer
    /// whichever one it reads.
    public static func apply(_ delta: ScrollDelta, settings: ScrollSettings) -> ScrollDelta {
        let factor = settings.speed * (settings.isReversed ? -1 : 1)
        return ScrollDelta(
            lines: (scaleLines(delta.lines.vertical, by: factor), scaleLines(delta.lines.horizontal, by: factor)),
            fixedLines: (delta.fixedLines.vertical * factor, delta.fixedLines.horizontal * factor),
            points: (delta.points.vertical * factor, delta.points.horizontal * factor)
        )
    }

    /// Whole lines, rounded, but never to zero: slowing the wheel down must not make a
    /// notch do nothing.
    static func scaleLines(_ lines: Int, by factor: Double) -> Int {
        guard lines != 0 else { return 0 }
        let scaled = (Double(lines) * factor).rounded()
        if scaled == 0 {
            return factor * Double(lines) > 0 ? 1 : -1
        }
        return Int(scaled)
    }
}

/// Spreads each wheel notch over a few frames instead of jumping the whole way at once.
///
/// Every notch adds its distance to what is still to travel; each frame covers a share of
/// that, so a quick run of notches speeds up and a pause lets it settle. Turning the wheel
/// the other way drops whatever was left in the old direction.
public struct ScrollSmoother {
    /// How quickly the remaining distance is used up: after this long about 63% of it has
    /// been scrolled.
    public var timeConstant: TimeInterval

    private var remaining = (vertical: 0.0, horizontal: 0.0)
    /// Fractions of a point not yet sent, so rounding never loses distance.
    private var carry = (vertical: 0.0, horizontal: 0.0)

    public init(timeConstant: TimeInterval = 0.08) {
        self.timeConstant = timeConstant
    }

    public var isIdle: Bool {
        remaining.vertical == 0 && remaining.horizontal == 0
    }

    public mutating func add(vertical: Double, horizontal: Double) {
        remaining.vertical = Self.combine(remaining.vertical, vertical)
        remaining.horizontal = Self.combine(remaining.horizontal, horizontal)
    }

    /// Whole points to scroll this frame.
    public mutating func step(elapsed: TimeInterval) -> (vertical: Int, horizontal: Int) {
        let share = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1
        let vertical = advance(&remaining.vertical, carry: &carry.vertical, share: share)
        let horizontal = advance(&remaining.horizontal, carry: &carry.horizontal, share: share)
        return (vertical, horizontal)
    }

    public mutating func stop() {
        remaining = (0, 0)
        carry = (0, 0)
    }

    private static func combine(_ current: Double, _ added: Double) -> Double {
        if added == 0 { return current }
        if current == 0 || (current > 0) == (added > 0) { return current + added }
        return added
    }

    private func advance(_ remaining: inout Double, carry: inout Double, share: Double) -> Int {
        guard remaining != 0 else { return 0 }

        // The last sliver goes in one step rather than trailing off for ever.
        var move = remaining * share
        if abs(remaining - move) < 0.5 {
            move = remaining
        }
        remaining -= move
        if remaining == 0 {
            // Whatever is left over is sent now, so the total always adds up.
            move += carry
            carry = 0
            return Int(move.rounded())
        }
        carry += move
        let whole = carry.rounded(.towardZero)
        carry -= whole
        return Int(whole)
    }
}
