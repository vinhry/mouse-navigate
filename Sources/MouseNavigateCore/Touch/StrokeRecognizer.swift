import Foundation

/// A drawn letter, straight-line direction or two-segment stroke that can be bound to an
/// action.
public enum CharacterGesture: String, CaseIterable, Sendable {
    case a, b, c, d, e, f, g, h, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case up, down, left, right, upLeft, upRight, downLeft, downRight
    /// Two straight legs at a right angle. The other four corners are letters already:
    /// down then right is L, right then down is T, left then down is F, down then left is J.
    case leftThenUp, rightThenUp, upThenLeft, upThenRight
    /// Out and straight back.
    case leftThenRight, rightThenLeft, upThenDown, downThenUp

    public var displayName: String {
        switch self {
        case .up: return "Up ↑"
        case .down: return "Down ↓ (I)"
        case .left: return "Left ←"
        case .right: return "Right →"
        case .upLeft: return "Up-Left ↖"
        case .upRight: return "Up-Right ↗"
        case .downLeft: return "Down-Left ↙"
        case .downRight: return "Down-Right ↘"
        case .leftThenUp: return "Left then Up ←↑"
        case .rightThenUp: return "Right then Up →↑"
        case .upThenLeft: return "Up then Left ↑←"
        case .upThenRight: return "Up then Right ↑→"
        case .leftThenRight: return "Left then Right ←→"
        case .rightThenLeft: return "Right then Left →←"
        case .upThenDown: return "Up then Down ↑↓"
        case .downThenUp: return "Down then Up ↓↑"
        default: return rawValue.uppercased()
        }
    }

    public var isDirection: Bool {
        CharacterGesture.directions.contains(self)
    }

    public static let directions: [CharacterGesture] = [
        .up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight,
    ]

    /// The two-segment strokes, which have templates like the letters.
    public static let strokes: [CharacterGesture] = [
        .leftThenUp, .rightThenUp, .upThenLeft, .upThenRight,
        .leftThenRight, .rightThenLeft, .upThenDown, .downThenUp,
    ]

    public var defaultAction: ButtonAction {
        switch self {
        case .b: return .launchBrowser
        case .f: return .launchFinder
        case .n: return .newDocument
        case .o: return .open
        case .s: return .save
        case .t: return .newTab
        case .down: return .paste
        case .up: return .copy
        case .left: return .maximizeLeft
        case .right: return .maximizeRight
        default: return .disabled
        }
    }
}

/// Recognizes a drawn stroke.
///
/// The stroke is first tidied: the points a pause piles up are dropped, the jitter of two
/// fingers' midpoint is smoothed away, and a short hook at either end (the fingers rolling as
/// they land, or flicking as they lift) is cut off. A stroke that is then nearly straight is
/// read as one of eight directions. Anything else is compared with the templates after the
/// $1 unistroke recognizer (Wobbrock, Wilson and Li, 2007), minus its rotation invariance,
/// since orientation is what tells many letters apart, and with an elastic comparison in
/// place of $1's point-by-point one, so that a letter with one part drawn longer than the
/// template does not fall out of step with it from there on.
public struct StrokeRecognizer {
    public struct Match: Equatable {
        public let gesture: CharacterGesture
        /// 1 is a perfect match; see `minimumScoreRange`.
        public let score: Double
        /// The closest other gesture, and its score, for diagnostics. Nil for a straight line.
        public let runnerUp: CharacterGesture?
        public let runnerUpScore: Double?

        public init(gesture: CharacterGesture, score: Double, runnerUp: CharacterGesture? = nil, runnerUpScore: Double? = nil) {
            self.gesture = gesture
            self.score = score
            self.runnerUp = runnerUp
            self.runnerUpScore = runnerUpScore
        }
    }

    /// The matching's working limits. Each is a judgement checked against the evaluation in
    /// the tests (StrokeEvaluation), which is where to measure any change.
    struct Tuning {
        /// Points closer than this to the last one kept, as a share of the stroke's size, are
        /// dropped: a pause piles up points that would otherwise count as drawing.
        var dwellRadius = 0.015
        /// Passes of a light [1 4 6 4 1] smoothing over the resampled stroke.
        var smoothingPasses = 2
        /// The longest end, as a share of the stroke's length, that may be cut off as a hook.
        /// The short legs of corner strokes are longer: a fifth of the first leg is a sixth of
        /// the stroke.
        var hookLimit = 0.1
        /// How sharply a hook must turn away from the rest of the stroke.
        var hookAngle = 75 * Double.pi / 180
        /// Cutting a hook off costs this much score per share of the stroke cut, so that a
        /// letter whose tail is part of it (Q's) is still preferred whole.
        var hookPenalty = 0.25
        /// Hooks are looked for at all.
        var trimsHooks = true
        /// Points compared per stroke.
        var sampleCount = 32
        /// How far the elastic comparison may run ahead or behind, in samples.
        var band = 4
        /// Weight of the agreement in direction of travel, beside position.
        var directionWeight = 1.0
        /// How much of a stroke's height-to-width difference from the template is forgiven:
        /// 0 keeps proportions exactly, 1 would stretch every stroke to a square. Half lets a
        /// letter drawn twice as tall as the template look only √2 as tall.
        var aspectSoftening = 0.5
        /// The largest slant tried either way, beyond the upright, and how many evenly spaced
        /// slants are tried on each side up to it. The elastic comparison forgives a little
        /// slant of its own.
        var slant = 8 * Double.pi / 180
        var slantSteps = 1
        /// The raw score that the default strictness stands for. See `minimumScoreRange`.
        var defaultRawScore = 0.22
        /// Gestures compared with uniform scaling whatever `aspectSoftening` says: a corner
        /// or out-and-back stroke is defined by its legs' lengths and its thinness.
        var keepsProportions: Set<CharacterGesture> = Set(CharacterGesture.strokes)
    }

    /// Endpoint distance over path length at which a stroke counts as a straight line,
    /// measured once the stroke is tidied and any hooks are cut off.
    public var straightness = 0.9
    /// Below this a letter match is rejected as a scribble.
    public var minimumScore = StrokeRecognizer.defaultMinimumScore
    let tuning: Tuning

    public static let defaultMinimumScore = 0.8

    /// How loose or strict the user may make the match. A score is one minus the warped
    /// distance from the closest template as a share of half the drawing box's diagonal,
    /// stretched so that the default falls where the evaluation in the tests
    /// (StrokeEvaluationTests) found the best balance. Measured there at 0.6, 0.8 and 0.95,
    /// on synthetic strokes roughened the ways hands roughen them: 95%, 94% and 15% of
    /// letters read correctly; 100%, 99% and 28% of corner and out-and-back strokes; and 71%,
    /// 12% and 0% of non-letters taken for something, at 0.8 nearly all of them shallow arcs
    /// and loops gone round one and a half times, with scribbles about 1%. On real one-stroke
    /// handwriting by writers the matching was not tuned on (UJI Pen Characters), 73%, 64%
    /// and 1% of letters. The 0.8.1 matcher read 56%, 44% and 3% of the same synthetic letters
    /// and 35%, 25% and 1% of the real ones, while taking 79%, 21% and 0% of the non-letters.
    /// Past either end the slider would only make letters unusable.
    public static let minimumScoreRange: ClosedRange<Double> = 0.6...0.95

    public static func clampMinimumScore(_ value: Double) -> Double {
        min(max(value, minimumScoreRange.lowerBound), minimumScoreRange.upperBound)
    }

    /// A word for a setting of `minimumScore`, for the slider's value.
    public static func strictnessName(for score: Double) -> String {
        switch clampMinimumScore(score) {
        case ..<0.72: return "Loose"
        case ..<0.88: return "Balanced"
        default: return "Strict"
        }
    }

    private static let workingCount = 64
    private static let halfDiagonal = 0.5 * 2.0.squareRoot()

    private let templates: [(gesture: CharacterGesture, shape: Shape, keepsProportions: Bool)]

    public init(templates: [CharacterTemplate] = CharacterTemplates.all) {
        self.init(templates: templates, tuning: Tuning())
    }

    init(templates: [CharacterTemplate] = CharacterTemplates.all, tuning: Tuning) {
        self.tuning = tuning
        self.templates = templates.map { template in
            let tidy = StrokeRecognizer.tidy(template.points, tuning: tuning)
            let keeps = tuning.keepsProportions.contains(template.gesture)
            return (template.gesture, StrokeRecognizer.shape(tidy, tuning: tuning, softening: keeps ? 0 : tuning.aspectSoftening), keeps)
        }
    }

    public func recognize(_ points: [Vector2]) -> CharacterGesture? {
        guard let match = bestMatch(points), accepts(match) else { return nil }
        return match.gesture
    }

    /// Whether a match is close enough to be the letter, rather than a scribble that
    /// happened to be nearest it. Lets a caller that already has the match avoid a second
    /// search.
    public func accepts(_ match: Match) -> Bool {
        match.score >= minimumScore
    }

    /// The closest gesture whatever its score, with the closest other one.
    public func bestMatch(_ points: [Vector2]) -> Match? {
        guard let prepared = prepare(points) else { return nil }
        switch prepared {
        case .line(let gesture):
            return Match(gesture: gesture, score: 1)
        case .curve(let versions):
            // Only the two leaders matter here, so a comparison that can no longer reach
            // either is given up part-way.
            var best: (gesture: CharacterGesture, score: Double)?
            var second: (gesture: CharacterGesture, score: Double)?
            search(versions) { gesture in
                // The worst score worth finishing for: beating this gesture's own lead, or
                // taking second place.
                gesture == best?.gesture ? best!.score : second?.score ?? -.infinity
            } record: { gesture, score in
                if gesture == best?.gesture {
                    if score > best!.score { best!.score = score }
                } else if score > best?.score ?? -.infinity {
                    second = best
                    best = (gesture, score)
                } else if gesture == second?.gesture {
                    if score > second!.score { second!.score = score }
                } else if score > second?.score ?? -.infinity {
                    second = (gesture, score)
                }
            }
            return best.map { Match(gesture: $0.gesture, score: $0.score, runnerUp: second?.gesture, runnerUpScore: second?.score) }
        }
    }

    /// Every gesture's best score, best first, for diagnostics. A straight stroke gives its
    /// direction alone.
    public func matches(_ points: [Vector2]) -> [Match] {
        guard let prepared = prepare(points) else { return [] }
        switch prepared {
        case .line(let gesture):
            return [Match(gesture: gesture, score: 1)]
        case .curve(let versions):
            var best: [CharacterGesture: Double] = [:]
            search(versions) { best[$0] ?? -.infinity } record: { gesture, score in
                best[gesture] = max(best[gesture] ?? -.infinity, score)
            }
            return best.map { Match(gesture: $0.key, score: $0.value) }
                .sorted { $0.score > $1.score || ($0.score == $1.score && $0.gesture.rawValue < $1.gesture.rawValue) }
        }
    }

    /// One version of the stroke, scaled both ways.
    private struct Version {
        var shape: Shape
        /// Scaled uniformly, for the templates whose proportions are their meaning.
        var proportional: Shape
        var cut: Double
    }

    private enum Prepared {
        case line(CharacterGesture)
        /// The stroke as drawn and, if it has hooks, without them, with the share cut off.
        case curve([Version])
    }

    private func prepare(_ points: [Vector2]) -> Prepared? {
        let length = StrokeRecognizer.pathLength(points)
        guard points.count >= 2, length > 0 else { return nil }

        let tidy = StrokeRecognizer.tidy(points, tuning: tuning)
        let versions = StrokeRecognizer.hookless(tidy, tuning: tuning)
        // Straightness is judged without the hooks and the jitter, which would otherwise
        // make a line drawn with two fingers look curved.
        let gate = versions[versions.count - 1].points
        let span = Vector2(x: gate[gate.count - 1].x - gate[0].x, y: gate[gate.count - 1].y - gate[0].y)
        let gateLength = StrokeRecognizer.pathLength(gate)
        if gateLength > 0, span.magnitude / gateLength >= straightness {
            return .line(StrokeRecognizer.direction(of: span))
        }
        return .curve(versions.map {
            Version(shape: StrokeRecognizer.shape($0.points, tuning: tuning, softening: tuning.aspectSoftening),
                    proportional: StrokeRecognizer.shape($0.points, tuning: tuning, softening: 0), cut: $0.cut)
        })
    }

    /// Compares every version of the stroke, at each slant, with every template. `floor`
    /// gives the score below which a comparison may be abandoned; `record` receives each
    /// score that was not.
    private func search(
        _ versions: [Version],
        floor: (CharacterGesture) -> Double,
        record: (CharacterGesture, Double) -> Void
    ) {
        let steps = tuning.slantSteps
        // Upright first: it usually matches best, which lets later comparisons stop sooner.
        var angles = [0.0]
        for step in stride(from: 1, through: steps, by: 1) {
            let angle = tuning.slant * Double(step) / Double(steps)
            angles += [angle, -angle]
        }
        var rows = DistanceRows(count: tuning.sampleCount)
        for version in versions.reversed() {
            let penalty = version.cut * tuning.hookPenalty
            // Templates that are close point for point are usually closest after warping
            // too; trying them first sets a high bar early, so the rest are abandoned sooner.
            let order = templates.indices.map { index -> (index: Int, distance: Double) in
                let template = templates[index]
                let own = template.keepsProportions ? version.proportional : version.shape
                return (index, StrokeRecognizer.inStepDistance(own, template.shape))
            }.sorted { $0.distance < $1.distance }
            for angle in angles {
                let soft = angle == 0 ? version.shape : version.shape.rotated(by: angle)
                let plain = angle == 0 ? version.proportional : version.proportional.rotated(by: angle)
                for (index, _) in order {
                    let template = templates[index]
                    let candidate = template.keepsProportions ? plain : soft
                    // The distance at which this comparison could no longer change the result.
                    let needed = rawScore(fromCalibrated: floor(template.gesture)) + penalty
                    let limit = (1 - needed) * StrokeRecognizer.halfDiagonal
                    guard let distance = StrokeRecognizer.warpedDistance(
                        candidate, template.shape, band: tuning.band, directionWeight: tuning.directionWeight,
                        limit: limit, rows: &rows
                    ) else { continue }
                    record(template.gesture, calibrated(1 - distance / StrokeRecognizer.halfDiagonal - penalty))
                }
            }
        }
    }

    /// The raw score is one minus the warped distance as a share of half the drawing box's
    /// diagonal, less any cost of cutting hooks. It is stretched linearly so that a perfect
    /// match is still 1 and `defaultRawScore` lands on the default strictness.
    private var scoreStretch: Double {
        (1 - StrokeRecognizer.defaultMinimumScore) / (1 - tuning.defaultRawScore)
    }

    func calibrated(_ raw: Double) -> Double {
        1 - (1 - raw) * scoreStretch
    }

    func rawScore(fromCalibrated score: Double) -> Double {
        guard score.isFinite else { return -.infinity }
        return 1 - (1 - score) / scoreStretch
    }

    // MARK: - Directions

    /// Eight 45° sectors centred on the compass directions, with +y down.
    static func direction(of vector: Vector2) -> CharacterGesture {
        let degrees = atan2(vector.y, vector.x) * 180 / .pi
        let sector = Int(((degrees + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        let order: [CharacterGesture] = [.right, .downRight, .down, .downLeft, .left, .upLeft, .up, .upRight]
        return order[sector % 8]
    }

    // MARK: - Tidying

    /// Drops the points a pause piles up, evens the spacing and smooths the jitter.
    static func tidy(_ points: [Vector2], tuning: Tuning) -> [Vector2] {
        let size = boxSize(points)
        let radius = tuning.dwellRadius * size
        var kept = [points[0]]
        for point in points.dropFirst() {
            let last = kept[kept.count - 1]
            if Vector2(x: point.x - last.x, y: point.y - last.y).magnitude >= radius {
                kept.append(point)
            }
        }
        if kept.count == 1 || kept[kept.count - 1] != points[points.count - 1] {
            if kept.count > 1 { kept.removeLast() }
            kept.append(points[points.count - 1])
        }
        guard pathLength(kept) > 0 else { return kept }
        var even = resample(kept, count: workingCount)
        guard tuning.smoothingPasses > 0 else { return even }
        for _ in 0..<tuning.smoothingPasses {
            even = smooth(even)
        }
        return resample(even, count: workingCount)
    }

    /// A [1 4 6 4 1] average, narrowing towards the ends so they stay where they are.
    static func smooth(_ points: [Vector2]) -> [Vector2] {
        let n = points.count
        guard n > 4 else { return points }
        var result = points
        for i in 1..<(n - 1) {
            if i == 1 || i == n - 2 {
                let a = points[i - 1], b = points[i], c = points[i + 1]
                result[i] = Vector2(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4)
            } else {
                let a = points[i - 2], b = points[i - 1], c = points[i], d = points[i + 1], e = points[i + 2]
                result[i] = Vector2(
                    x: (a.x + 4 * b.x + 6 * c.x + 4 * d.x + e.x) / 16,
                    y: (a.y + 4 * b.y + 6 * c.y + 4 * d.y + e.y) / 16
                )
            }
        }
        return result
    }

    /// The stroke as drawn and, where an end turns sharply within `hookLimit` of the stroke's
    /// length, without that end, each with the share of the length cut. Trying each end on
    /// its own as well was measured to make no difference.
    static func hookless(_ points: [Vector2], tuning: Tuning) -> [(points: [Vector2], cut: Double)] {
        let total = pathLength(points)
        guard tuning.trimsHooks, total > 0, points.count >= 8 else { return [(points, 0)] }
        let start = hookEnd(points, total: total, tuning: tuning) ?? 0
        let end = hookEnd(Array(points.reversed()), total: total, tuning: tuning).map { points.count - 1 - $0 }
            ?? points.count - 1
        guard start > 0 || end < points.count - 1, end - start >= 8 else { return [(points, 0)] }
        let kept = Array(points[start...end])
        return [(points, 0), (resample(kept, count: workingCount), 1 - pathLength(kept) / total)]
    }

    /// The index where a hook at the start of `points` ends, if there is one: the point
    /// within the limit at which the stroke turns most sharply from the way it came.
    private static func hookEnd(_ path: [Vector2], total: Double, tuning: Tuning) -> Int? {
        var travelled = [0.0]
        for i in 1..<path.count {
            travelled.append(travelled[i - 1] + distance(path[i], path[i - 1]))
        }
        let limit = tuning.hookLimit * total
        var best: (index: Int, turn: Double)?
        var i = 1
        while i < path.count - 2, travelled[i] <= limit {
            // The way the rest of the stroke goes from here, over as long again as the limit.
            var j = i + 1
            while j < path.count - 1, travelled[j] - travelled[i] < limit { j += 1 }
            let incoming = Vector2(x: path[i].x - path[0].x, y: path[i].y - path[0].y)
            let outgoing = Vector2(x: path[j].x - path[i].x, y: path[j].y - path[i].y)
            let turn = angle(between: incoming, and: outgoing)
            if turn >= tuning.hookAngle, turn > best?.turn ?? 0 {
                best = (i, turn)
            }
            i += 1
        }
        return best?.index
    }

    private static func angle(between a: Vector2, and b: Vector2) -> Double {
        let magnitudes = a.magnitude * b.magnitude
        guard magnitudes > 0 else { return 0 }
        return acos(min(max((a.x * b.x + a.y * b.y) / magnitudes, -1), 1))
    }

    // MARK: - Comparing

    /// A stroke ready to compare: evenly spaced points, centred and scaled, with the
    /// direction of travel at each, stored as x, y, dx, dy for each point in turn.
    struct Shape {
        var values: [Double]
        var count: Int { values.count / 4 }

        func rotated(by radians: Double) -> Shape {
            let c = cos(radians), s = sin(radians)
            var copy = self
            for i in 0..<count {
                let k = 4 * i
                copy.values[k] = values[k] * c - values[k + 1] * s
                copy.values[k + 1] = values[k] * s + values[k + 1] * c
                copy.values[k + 2] = values[k + 2] * c - values[k + 3] * s
                copy.values[k + 3] = values[k + 2] * s + values[k + 3] * c
            }
            return copy
        }

        var points: [Vector2] {
            (0..<count).map { Vector2(x: values[4 * $0], y: values[4 * $0 + 1]) }
        }
    }

    static func shape(_ points: [Vector2], tuning: Tuning, softening: Double) -> Shape {
        let even = resample(points, count: tuning.sampleCount)
        let xs = even.map(\.x)
        let ys = even.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        let big = max(width, height)
        var sx = 1.0, sy = 1.0
        if big > 0 {
            // Uniform scaling keeps a tall narrow letter tall and narrow. Some of a
            // difference in proportions is forgiven, scaling each side by its length to the
            // power -aspectSoftening, though not for a stroke much thinner than it is long:
            // that is what an out-and-back stroke is.
            let ratio = min(width, height) / big
            let soften = softening * min(max((ratio - 0.15) / 0.25, 0), 1)
            let w = pow(max(width, 1e-9), 1 - soften)
            let h = pow(max(height, 1e-9), 1 - soften)
            let k = 1 / max(w, h)
            sx = width > 0 ? k * w / width : 1 / big
            sy = height > 0 ? k * h / height : 1 / big
        }
        let n = xs.count
        let cx = xs.reduce(0, +) / Double(n)
        let cy = ys.reduce(0, +) / Double(n)
        var values = [Double](repeating: 0, count: 4 * n)
        for i in 0..<n {
            values[4 * i] = (xs[i] - cx) * sx
            values[4 * i + 1] = (ys[i] - cy) * sy
        }
        for i in 0..<n {
            let a = max(i - 1, 0), b = min(i + 1, n - 1)
            let vx = values[4 * b] - values[4 * a], vy = values[4 * b + 1] - values[4 * a + 1]
            let m = (vx * vx + vy * vy).squareRoot()
            if m > 0 {
                values[4 * i + 2] = vx / m
                values[4 * i + 3] = vy / m
            }
        }
        return Shape(values: values)
    }

    /// The mean distance between points taken in step, positions only: a cheap first guess.
    static func inStepDistance(_ a: Shape, _ b: Shape) -> Double {
        var total = 0.0
        a.values.withUnsafeBufferPointer { pa in
            b.values.withUnsafeBufferPointer { pb in
                for k in stride(from: 0, to: min(pa.count, pb.count), by: 4) {
                    let ex = pa[k] - pb[k], ey = pa[k + 1] - pb[k + 1]
                    total += (ex * ex + ey * ey).squareRoot()
                }
            }
        }
        return total / Double(max(a.count, 1))
    }

    /// Two rows of the warping table, kept between comparisons to save allocating them.
    struct DistanceRows {
        var storage: [Double]

        init(count: Int) {
            storage = Array(repeating: .infinity, count: 2 * count)
        }
    }

    /// Dynamic time warping within a band: each point is matched to one on the template
    /// no more than `band` samples ahead or behind, in order, choosing the matching with the
    /// least total distance between points, plus `directionWeight` times the difference in
    /// their directions of travel. Divided by the point count, it is never more than the
    /// in-step distance, and equals it when the stroke keeps pace with the template. Nil
    /// once every way forward already costs more than `limit`.
    static func warpedDistance(
        _ a: Shape, _ b: Shape, band: Int, directionWeight: Double,
        limit: Double = .infinity, rows: inout DistanceRows
    ) -> Double? {
        let n = a.count
        precondition(b.count == n && rows.storage.count >= 2 * n)
        let total = limit * Double(n)
        // Raw pointers: this loop is most of the recognizer's time, and in a debug build
        // checked subscripts would make it many times slower.
        return a.values.withUnsafeBufferPointer { bufferA in
            b.values.withUnsafeBufferPointer { bufferB in
                rows.storage.withUnsafeMutableBufferPointer { storage -> Double? in
                    let pa = bufferA.baseAddress!, pb = bufferB.baseAddress!
                    var previous = storage.baseAddress!
                    var current = previous + n
                    for j in 0..<(2 * n) { previous[j] = .infinity }
                    for i in 0..<n {
                        let ax = pa[4 * i], ay = pa[4 * i + 1], adx = pa[4 * i + 2], ady = pa[4 * i + 3]
                        let low = max(0, i - band), high = min(n - 1, i + band)
                        // Bands only move right, so a cell above the band was never written
                        // and is still infinite; the one to the left of it is an older row's.
                        var left = Double.infinity
                        var rowBest = Double.infinity
                        var q = pb + 4 * low
                        var j = low
                        while j <= high {
                            // Written out rather than with min(), which a debug build calls.
                            var before = previous[j] < left ? previous[j] : left
                            if j > 0, previous[j - 1] < before { before = previous[j - 1] }
                            if i == 0 && j == 0 { before = 0 }
                            let ex = ax - q[0], ey = ay - q[1]
                            let fx = adx - q[2], fy = ady - q[3]
                            let value = before + (ex * ex + ey * ey).squareRoot()
                                + directionWeight * (fx * fx + fy * fy).squareRoot()
                            current[j] = value
                            left = value
                            if value < rowBest { rowBest = value }
                            q += 4
                            j += 1
                        }
                        if rowBest > total { return nil }
                        swap(&previous, &current)
                    }
                    let result = previous[n - 1] / Double(n)
                    return result <= limit ? result : nil
                }
            }
        }
    }

    /// The same without a limit, allocating its own rows.
    static func warpedDistance(_ a: Shape, _ b: Shape, band: Int, directionWeight: Double) -> Double {
        var rows = DistanceRows(count: a.count)
        return warpedDistance(a, b, band: band, directionWeight: directionWeight, rows: &rows) ?? .infinity
    }

    // MARK: - Geometry

    static func resample(_ points: [Vector2], count: Int) -> [Vector2] {
        let interval = pathLength(points) / Double(count - 1)
        guard interval > 0, var previous = points.first else {
            return Array(repeating: points.first ?? .zero, count: count)
        }

        var result = [previous]
        result.reserveCapacity(count)
        var carried = 0.0
        var index = 1
        while index < points.count {
            let current = points[index]
            let segment = distance(current, previous)
            if carried + segment >= interval, segment > 0 {
                let t = (interval - carried) / segment
                let point = Vector2(
                    x: previous.x + t * (current.x - previous.x),
                    y: previous.y + t * (current.y - previous.y)
                )
                result.append(point)
                previous = point
                carried = 0
            } else {
                carried += segment
                previous = current
                index += 1
            }
        }
        // Floating-point error can leave the last point off the end.
        while result.count < count {
            result.append(points[points.count - 1])
        }
        return Array(result.prefix(count))
    }

    static func rotate(_ points: [Vector2], by radians: Double) -> [Vector2] {
        let cosine = cos(radians)
        let sine = sin(radians)
        return points.map { Vector2(x: $0.x * cosine - $0.y * sine, y: $0.x * sine + $0.y * cosine) }
    }

    static func pathLength(_ points: [Vector2]) -> Double {
        var total = 0.0
        for i in points.indices.dropFirst() {
            total += distance(points[i], points[i - 1])
        }
        return total
    }

    private static func boxSize(_ points: [Vector2]) -> Double {
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return max(maxX - minX, maxY - minY)
    }

    @inline(__always)
    private static func distance(_ a: Vector2, _ b: Vector2) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
