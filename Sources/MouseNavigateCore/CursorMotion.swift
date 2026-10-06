import Foundation

public struct Vector2 : Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vector2(x: 0, y: 0)

    public var isZero: Bool { x == 0 && y == 0 }

    public var magnitude: Double { (x * x + y * y).squareRoot() }

    /// Scale to unit length so holding two keys does not move √2 faster than one.
    public var normalized: Vector2 {
        let length = magnitude
        guard length > 0 else { return .zero }
        return Vector2(x: x / length, y: y / length)
    }
}

public struct Rect: Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}

public enum CursorMotion {
    /// Direction implied by the held movement keys, in CoreGraphics coordinates where
    /// +y points down the screen.
    public static func direction(up: Bool, down: Bool, left: Bool, right: Bool) -> Vector2 {
        var vector = Vector2.zero
        if up { vector.y -= 1 }
        if down { vector.y += 1 }
        if left { vector.x -= 1 }
        if right { vector.x += 1 }
        return vector.normalized
    }

    /// Smoothstep easing, so the cursor eases into its top speed instead of snapping
    /// there. Returns 0 at rest and 1 once fully ramped.
    public static func easedRamp(heldDuration: Double, acceleration: Double) -> Double {
        guard acceleration > 0 else { return 1 }
        let ramp = min(max(heldDuration / acceleration, 0), 1)
        return ramp * ramp * (3 - 2 * ramp)
    }

    /// Points per second for the current hold duration and modifier tier.
    public static func speed(
        heldDuration: Double,
        tier: SpeedTier,
        profile: CursorSpeedProfile
    ) -> Double {
        let eased = easedRamp(heldDuration: heldDuration, acceleration: profile.acceleration)
        let ramped = profile.baseSpeed + (profile.maxSpeed - profile.baseSpeed) * eased
        return ramped * tier.multiplier(using: profile)
    }

    /// Confine a point to the union of the display rects. Each axis falls back to its
    /// previous value independently, so sliding along the edge of one display does not
    /// snag on the gap next to another.
    ///
    /// Display rects are half-open: a display 1440 points wide holds x from 0 up to, but
    /// not including, 1440, so the pointer's fractional positions on a Retina display can
    /// reach its last column and step across to a display that starts at 1440.
    public static func clamp(
        point: Vector2,
        previous: Vector2,
        screens: [Rect]
    ) -> Vector2 {
        guard !screens.isEmpty else { return point }

        if screens.contains(where: { holds($0, point) }) {
            return point
        }

        // Try giving up one axis at a time before falling back entirely.
        let horizontalOnly = Vector2(x: point.x, y: previous.y)
        if screens.contains(where: { holds($0, horizontalOnly) }) {
            return horizontalOnly
        }

        let verticalOnly = Vector2(x: previous.x, y: point.y)
        if screens.contains(where: { holds($0, verticalOnly) }) {
            return verticalOnly
        }

        // Both axes left the desktop: pin to the edge of the display the pointer was on,
        // or of the closest one when it was nowhere.
        guard let home = screens.first(where: { holds($0, previous) }) ?? screens.min(by: {
            squaredDistance(from: point, to: $0) < squaredDistance(from: point, to: $1)
        }) else {
            return previous
        }

        return Vector2(
            x: min(max(point.x, home.minX), home.maxX - 1),
            y: min(max(point.y, home.minY), home.maxY - 1)
        )
    }

    private static func holds(_ rect: Rect, _ point: Vector2) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }

    private static func squaredDistance(from point: Vector2, to rect: Rect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// Carries the sub-pixel remainder between ticks so slow movement still advances
/// smoothly instead of rounding away to nothing.
public struct SubPixelAccumulator {
    private var remainder = Vector2.zero

    public init() {}

    public mutating func take(_ delta: Vector2) -> (dx: Int, dy: Int) {
        remainder.x += delta.x
        remainder.y += delta.y

        let dx = remainder.x.rounded(.towardZero)
        let dy = remainder.y.rounded(.towardZero)
        remainder.x -= dx
        remainder.y -= dy

        return (Int(dx), Int(dy))
    }

    public mutating func reset() {
        remainder = .zero
    }
}
