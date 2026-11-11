import Foundation
@testable import MouseNavigateCore

// Shared pieces of the drawn-letter evaluation: a seeded random source and the plain
// geometry the harness needs. The geometry is written here rather than borrowed from
// `StrokeRecognizer`, so that changing the recognizer can never quietly change the strokes
// it is measured on.

/// SplitMix64 (Steele, Lea and Flood, 2014): tiny, fast and the same on every machine, so
/// every evaluation run draws exactly the same strokes.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1). Written out rather than `Double.random(in:using:)`, whose way of
    /// turning bits into a number is not promised to stay the same between Swift releases.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    mutating func integer(_ low: Int, _ high: Int) -> Int {
        low + Int(next() % UInt64(high - low + 1))
    }

    mutating func sign() -> Double {
        chance(0.5) ? 1 : -1
    }

    /// Standard normal, by Box and Muller.
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

extension Vector2 {
    static func + (a: Vector2, b: Vector2) -> Vector2 { Vector2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vector2, b: Vector2) -> Vector2 { Vector2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vector2, k: Double) -> Vector2 { Vector2(x: a.x * k, y: a.y * k) }

    func rotated(by radians: Double) -> Vector2 {
        Vector2(x: x * cos(radians) - y * sin(radians), y: x * sin(radians) + y * cos(radians))
    }
}

enum EvalGeometry {
    static func length(_ points: [Vector2]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).magnitude }
    }

    /// Evenly spaced points along a polyline, `count` of them, ends included.
    static func resample(_ points: [Vector2], count: Int) -> [Vector2] {
        guard points.count >= 2, count >= 2 else { return points }
        var cumulative = [0.0]
        for (a, b) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + (b - a).magnitude)
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else { return Array(repeating: points[0], count: count) }
        return position(along: points, cumulative: cumulative, at: (0..<count).map {
            total * Double($0) / Double(count - 1)
        })
    }

    /// Points at the given distances along a polyline, which must be in increasing order.
    static func position(along points: [Vector2], cumulative: [Double], at distances: [Double]) -> [Vector2] {
        var result: [Vector2] = []
        result.reserveCapacity(distances.count)
        var segment = 0
        for distance in distances {
            while segment < points.count - 2, cumulative[segment + 1] < distance {
                segment += 1
            }
            let span = cumulative[segment + 1] - cumulative[segment]
            let t = span > 0 ? min(max((distance - cumulative[segment]) / span, 0), 1) : 0
            result.append(points[segment] + (points[segment + 1] - points[segment]) * t)
        }
        return result
    }

    static func bounds(_ points: [Vector2]) -> (min: Vector2, max: Vector2) {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return (Vector2(x: xs.min() ?? 0, y: ys.min() ?? 0), Vector2(x: xs.max() ?? 0, y: ys.max() ?? 0))
    }

    /// The larger side of the bounding box.
    static func size(_ points: [Vector2]) -> Double {
        let box = bounds(points)
        return max(box.max.x - box.min.x, box.max.y - box.min.y)
    }

    /// Fits a stroke so its larger side is `size` and its box starts at `origin`.
    static func fit(_ points: [Vector2], size: Double, origin: Vector2) -> [Vector2] {
        let box = bounds(points)
        let scale = size / max(box.max.x - box.min.x, box.max.y - box.min.y, 1e-9)
        return points.map { origin + ($0 - box.min) * scale }
    }
}

/// A pen path written as moves, lines, curves and arcs in a unit box with +y down, the
/// way a person would describe how to draw a letter.
struct PenPath {
    private(set) var points: [Vector2]

    init(_ x: Double, _ y: Double) {
        points = [Vector2(x: x, y: y)]
    }

    private var current: Vector2 { points[points.count - 1] }

    func line(_ x: Double, _ y: Double) -> PenPath {
        var copy = self
        copy.points.append(Vector2(x: x, y: y))
        return copy
    }

    /// A quadratic Bézier from where the pen is, pulled towards (cx, cy), ending at (x, y).
    func curve(_ cx: Double, _ cy: Double, _ x: Double, _ y: Double, steps: Int = 12) -> PenPath {
        var copy = self
        let p0 = current
        let c = Vector2(x: cx, y: cy)
        let p1 = Vector2(x: x, y: y)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let a = p0 * ((1 - t) * (1 - t))
            let b = c * (2 * (1 - t) * t)
            copy.points.append(a + b + p1 * (t * t))
        }
        return copy
    }

    /// An elliptical arc round (cx, cy). Degrees, 0 pointing right and increasing clockwise
    /// on screen, since +y is down. The pen first moves to the arc's start if it is not there.
    func arc(_ cx: Double, _ cy: Double, rx: Double, ry: Double, from start: Double, to end: Double) -> PenPath {
        var copy = self
        let steps = max(8, Int(abs(end - start) / 10))
        for step in 0...steps {
            let degrees = start + (end - start) * Double(step) / Double(steps)
            let radians = degrees * .pi / 180
            let point = Vector2(x: cx + rx * cos(radians), y: cy + ry * sin(radians))
            if step == 0, (point - copy.current).magnitude < 1e-6 { continue }
            copy.points.append(point)
        }
        return copy
    }
}
