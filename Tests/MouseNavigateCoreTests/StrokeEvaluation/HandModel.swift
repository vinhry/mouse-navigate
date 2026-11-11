import Foundation
@testable import MouseNavigateCore

/// Turns a clean reference shape into the kind of point list a drawing produces, by
/// applying the ways a hand departs from the ideal, together, at a chosen strength.
///
/// This is a model, with numbers chosen by judgement rather than measured from people: it
/// says what kinds of untidiness a recognizer should survive, not how often each occurs.
/// Strength 0 is the clean shape, merely sampled; 1 is a rough, hurried drawing that a
/// person would still call the letter.
struct HandModel {
    var strength: Double
    /// Draw the shape backwards, for shapes where that is still the same letter.
    var reversed = false
    /// Drawn with two fingers on a trackpad, whose midpoint is the pen, rather than with a
    /// mouse.
    var twoFingers = true

    // At full strength:
    /// Per-point sensor noise, standard deviation as a share of the drawing's size.
    static let jitter = 0.012
    /// A slow wander of the whole line, amplitude as a share of the size.
    static let wobble = 0.035
    /// Horizontal shear per unit height: 0.3 is a slant of about 17°.
    static let shear = 0.3
    /// Height over width multiplied or divided by up to this.
    static let aspect = 1.5
    /// Turn of the whole drawing.
    static let rotation = 20 * Double.pi / 180
    /// How unevenly the parts of a stroke are drawn: local length multiplied by up to
    /// e^0.5 ≈ 1.65 in one place and divided by as much in another.
    static let proportion = 0.5
    /// Radius, as a share of the size, over which corners are rounded off.
    static let rounding = 0.07
    /// Hooks at either end, as a share of the path's length.
    static let hook = 0.1

    func apply(_ shape: ReferenceShape, using rng: inout SplitMix64) -> [Vector2] {
        let s = strength
        var path = EvalGeometry.resample(shape.points, count: 200)
        if reversed { path.reverse() }

        if shape.isClosed, s > 0, rng.chance(0.6) {
            // Start somewhere else round the loop: any clock position.
            path = startElsewhere(path, fraction: rng.unit())
        }
        if s > 0 {
            path = roundCorners(path, radius: Self.rounding * s * rng.unit())
            path = warpProportions(path, amount: Self.proportion * s * rng.uniform(0.3, 1), using: &rng)
        }
        if s > 0, shape.gesture.isDirection == false || rng.chance(0.5) {
            path = addHooks(path, using: &rng)
        }
        if shape.gesture.isDirection {
            // A line's slant is chosen by the caller within its sector; turning it here
            // could carry it into the next one.
        } else if s > 0 {
            path = affine(path, using: &rng)
        }
        if s > 0 {
            path = addWobble(path, amplitude: Self.wobble * s * rng.uniform(0.3, 1), using: &rng)
        }
        var points = sampleInTime(path, using: &rng)
        if s > 0, rng.chance(0.4 + 0.4 * s) {
            points = addDwell(points, using: &rng)
        }
        points = addSensorNoise(points, using: &rng)

        // Somewhere on a trackpad-sized surface; the recognizer should not care where.
        let size = rng.uniform(0.25, 0.7)
        return EvalGeometry.fit(points, size: size, origin: Vector2(x: rng.uniform(0, 0.5), y: rng.uniform(0, 0.3)))
    }

    // MARK: Pieces

    /// Restarts a closed loop part-way round.
    func startElsewhere(_ path: [Vector2], fraction: Double) -> [Vector2] {
        let loop = Array(path.dropLast())
        let offset = Int(fraction * Double(loop.count)) % max(loop.count, 1)
        let turned = Array(loop[offset...] + loop[..<offset])
        return turned + [turned[0]]
    }

    /// Averages each point with its neighbours within `radius` along the path, which rounds
    /// corners off and leaves straight runs alone.
    func roundCorners(_ path: [Vector2], radius: Double) -> [Vector2] {
        let spacing = EvalGeometry.length(path) / Double(path.count - 1)
        let window = Int(radius * EvalGeometry.size(path) / max(spacing, 1e-9))
        guard window >= 1 else { return path }
        return path.indices.map { i in
            // Ends stay put, or rounding would shorten the stroke.
            let reach = min(window, i, path.count - 1 - i)
            guard reach > 0 else { return path[i] }
            var sum = Vector2.zero
            for j in (i - reach)...(i + reach) { sum = sum + path[j] }
            return sum * (1 / Double(2 * reach + 1))
        }
    }

    /// Lengthens some parts of the stroke and shortens others, keeping every part's
    /// direction: a letter whose first leg runs long and whose bowl comes out small.
    func warpProportions(_ path: [Vector2], amount: Double, using rng: inout SplitMix64) -> [Vector2] {
        let phase1 = rng.uniform(0, 2 * .pi)
        let phase2 = rng.uniform(0, 2 * .pi)
        let mix = rng.unit()
        var result = [path[0]]
        for i in 1..<path.count {
            let t = Double(i) / Double(path.count - 1)
            let wave = (1 - mix) * cos(2 * .pi * t + phase1) + mix * cos(4 * .pi * t + phase2)
            let step = (path[i] - path[i - 1]) * exp(amount * wave)
            result.append(result[result.count - 1] + step)
        }
        return result
    }

    /// The landing roll and the flick on lifting: a short stroke at either end, turned
    /// sharply away from the way the line goes there.
    func addHooks(_ path: [Vector2], using rng: inout SplitMix64) -> [Vector2] {
        let s = strength
        let length = EvalGeometry.length(path)
        var result = path
        if rng.chance(0.3 + 0.4 * s) {
            let size = length * Self.hook * s * rng.uniform(0.2, 1)
            let direction = (path[min(5, path.count - 1)] - path[0]).normalized
            // The pen lands a little ahead of or beside the start and comes back to it, so
            // the stroke turns by 100° to 170° when it sets off properly.
            let away = direction.rotated(by: rng.sign() * rng.uniform(10, 80) * .pi / 180)
            let start = path[0] + away * size
            result = hook(from: start, to: path[0]) + result.dropFirst()
        }
        if rng.chance(0.3 + 0.4 * s) {
            let size = length * Self.hook * s * rng.uniform(0.2, 1)
            let last = path.count - 1
            let direction = (path[last] - path[max(0, last - 5)]).normalized
            let away = direction.rotated(by: rng.sign() * rng.uniform(60, 150) * .pi / 180)
            result += hook(from: path[last], to: path[last] + away * size).dropFirst()
        }
        return result
    }

    private func hook(from a: Vector2, to b: Vector2) -> [Vector2] {
        (0...6).map { a + (b - a) * (Double($0) / 6) }
    }

    /// Slant, stretch and turn.
    func affine(_ path: [Vector2], using rng: inout SplitMix64) -> [Vector2] {
        let s = strength
        let shear = Self.shear * s * rng.uniform(-1, 1)
        let stretch = pow(Self.aspect, s * rng.uniform(-1, 1))
        let angle = Self.rotation * s * rng.uniform(-1, 1)
        let centre = Vector2(x: 0.5, y: 0.5)
        return path.map { point in
            var p = point - centre
            p = Vector2(x: p.x + shear * p.y, y: p.y)
            p = Vector2(x: p.x / stretch.squareRoot(), y: p.y * stretch.squareRoot())
            return centre + p.rotated(by: angle)
        }
    }

    /// A slow wander, a cycle or two along the stroke, as an arm drifts.
    func addWobble(_ path: [Vector2], amplitude: Double, using rng: inout SplitMix64) -> [Vector2] {
        let size = EvalGeometry.size(path)
        let cycles = rng.uniform(0.5, 2.5)
        let phaseX = rng.uniform(0, 2 * .pi)
        let phaseY = rng.uniform(0, 2 * .pi)
        return path.enumerated().map { index, point in
            let t = Double(index) / Double(path.count - 1)
            return point + Vector2(
                x: amplitude * size * sin(2 * .pi * cycles * t + phaseX),
                y: amplitude * size * sin(2 * .pi * cycles * t + phaseY)
            )
        }
    }

    /// Reports the pen at even time steps while its speed varies: slow parts come out
    /// dense, quick parts sparse. A trackpad reports about 90 times a second and a letter
    /// takes from half a second to two.
    func sampleInTime(_ path: [Vector2], using rng: inout SplitMix64) -> [Vector2] {
        let s = strength
        let count = rng.integer(40, 220)
        let unevenness = 0.9 * s
        let phase = rng.uniform(0, 2 * .pi)
        let cycles = rng.uniform(1, 3)
        // Arc length covered by time t, from a speed that rises and falls.
        var cumulative = [0.0]
        for (a, b) in zip(path, path.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + (b - a).magnitude)
        }
        let total = cumulative[cumulative.count - 1]
        var distances: [Double] = []
        var travelled = 0.0
        var speeds: [Double] = []
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            speeds.append(exp(unevenness * sin(2 * .pi * cycles * t + phase)))
        }
        let speedTotal = speeds.dropLast().reduce(0, +)
        for i in 0..<count {
            distances.append(min(travelled, total))
            travelled += total * speeds[i] / speedTotal
        }
        distances[count - 1] = total
        return EvalGeometry.position(along: path, cumulative: cumulative, at: distances)
    }

    /// The pen stops for a moment: at the start, at the end, or part-way, as at a corner.
    func addDwell(_ points: [Vector2], using rng: inout SplitMix64) -> [Vector2] {
        let size = EvalGeometry.size(points)
        let at: Int
        switch rng.integer(0, 2) {
        case 0: at = 0
        case 1: at = points.count - 1
        default: at = rng.integer(1, points.count - 2)
        }
        let cluster = (0..<rng.integer(5, 30)).map { _ in
            points[at] + Vector2(x: rng.gaussian(), y: rng.gaussian()) * (0.003 * size)
        }
        return Array(points[...at]) + cluster + Array(points[(at + 1)...])
    }

    /// Sensor noise. Two fingers each carry their own, and the midpoint averages them; one
    /// finger also trails the other slightly, which a hand cannot quite avoid.
    func addSensorNoise(_ points: [Vector2], using rng: inout SplitMix64) -> [Vector2] {
        let size = EvalGeometry.size(points)
        let sigma = Self.jitter * strength * size
        guard twoFingers else {
            return points.map { $0 + Vector2(x: rng.gaussian(), y: rng.gaussian()) * (sigma * 0.5) }
        }
        let lag = strength > 0 ? rng.integer(0, 3) : 0
        return points.indices.map { i in
            let a = points[i] + Vector2(x: rng.gaussian(), y: rng.gaussian()) * sigma
            let b = points[max(0, i - lag)] + Vector2(x: rng.gaussian(), y: rng.gaussian()) * sigma
            return (a + b) * 0.5
        }
    }
}
