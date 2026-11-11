import Foundation
@testable import MouseNavigateCore

/// One stroke to recognise, and what it ought to be. Negatives have no answer: they should
/// be rejected, or at most read as a straight-line direction.
struct LabelledStroke {
    enum Group: String, CaseIterable {
        case letter
        case direction
        /// The four corners that are not letters and the four out-and-back strokes.
        case stroke
        case negative
    }

    let truth: CharacterGesture?
    let group: Group
    /// The reference shape's form, the distortion strength, or the negative's kind.
    let form: String
    let kind: ReferenceShape.Kind
    let strength: Double
    let points: [Vector2]
}

/// A recognizer under evaluation: how it finds its best match, and whether it would act on
/// that match at a given slider setting.
struct EvaluatedRecognizer {
    let name: String
    let match: ([Vector2]) -> StrokeRecognizer.Match?
    let accepts: (StrokeRecognizer.Match, Double) -> Bool

    static let current: EvaluatedRecognizer = {
        let recognizer = StrokeRecognizer()
        return EvaluatedRecognizer(
            name: "current",
            match: { recognizer.bestMatch($0) },
            accepts: { match, setting in
                var copy = recognizer
                copy.minimumScore = setting
                return copy.accepts(match)
            }
        )
    }()

    static let legacy: EvaluatedRecognizer = {
        let recognizer = LegacyStrokeRecognizer()
        return EvaluatedRecognizer(
            name: "0.8.1",
            match: { recognizer.bestMatch($0) },
            accepts: { match, setting in match.score >= setting }
        )
    }()
}

enum StrokeEvaluation {
    /// The slider's two ends and its default.
    static let loose = 0.6
    static let balanced = StrokeRecognizer.defaultMinimumScore
    static let strict = 0.95
    static let settings = [loose, 0.7, balanced, 0.875, strict]

    /// Strengths of the hand model: clean, mild, moderate, rough.
    static let strengths = [0.0, 0.33, 0.67, 1.0]

    // MARK: Building the sets

    /// Every reference shape at every strength, `perCell` times each, forwards and, where
    /// that is still the letter, backwards.
    static func genuineStrokes(perCell: Int, seed: UInt64) -> [LabelledStroke] {
        var rng = SplitMix64(seed: seed)
        var strokes: [LabelledStroke] = []
        for shape in ReferenceShapes.all {
            let group: LabelledStroke.Group = shape.gesture.isDirection ? .direction
                : CharacterGesture.strokes.contains(shape.gesture) ? .stroke : .letter
            for reversed in shape.isReversible ? [false, true] : [false] {
                for strength in strengths {
                    for _ in 0..<perCell {
                        var source = shape
                        if shape.gesture.isDirection {
                            // Anywhere within 15° of the sector's centre, 7.5° from its edge.
                            let angle = rng.uniform(-15, 15) * .pi / 180
                            let centre = Vector2(x: 0.5, y: 0.5)
                            source = ReferenceShape(gesture: shape.gesture, name: shape.name, kind: shape.kind,
                                                    points: shape.points.map { centre + ($0 - centre).rotated(by: angle) })
                        }
                        let model = HandModel(strength: strength, reversed: reversed, twoFingers: rng.chance(0.7))
                        strokes.append(LabelledStroke(
                            truth: shape.gesture, group: group,
                            form: reversed ? "\(shape.name), reversed" : shape.name,
                            kind: reversed ? .natural : shape.kind,
                            strength: strength,
                            points: model.apply(source, using: &rng)
                        ))
                    }
                }
            }
        }
        return strokes
    }

    static func negativeStrokes(perKind: Int, seed: UInt64) -> [LabelledStroke] {
        var rng = SplitMix64(seed: seed)
        var strokes: [LabelledStroke] = []
        for kind in Negative.allCases {
            for _ in 0..<perKind {
                let path = kind.path(using: &rng)
                let model = HandModel(strength: 0.5, twoFingers: rng.chance(0.7))
                var points = model.sampleInTime(EvalGeometry.resample(path, count: 240), using: &rng)
                points = model.addSensorNoise(points, using: &rng)
                strokes.append(LabelledStroke(truth: nil, group: .negative, form: kind.rawValue, kind: .natural,
                                              strength: 0.5, points: EvalGeometry.fit(points, size: 0.4, origin: .zero)))
            }
        }
        return strokes
    }

    /// Movements that are not letters: scribbles, and the shapes ordinary hand movements
    /// make. Some resemble letters in passing; that is the point.
    enum Negative: String, CaseIterable {
        case randomWalk = "random walk"
        case randomPoints = "random points joined"
        case loops = "row of loops"
        case zigzag = "zigzag of 5 to 8 legs"
        case nearLine = "nearly straight drag with a wobble"
        case arc = "shallow arc"
        case circleAndAHalf = "circle and a half"
        case shortHook = "diagonal line with a curl"

        func path(using rng: inout SplitMix64) -> [Vector2] {
            switch self {
            case .randomWalk:
                var heading = rng.uniform(0, 2 * .pi)
                var turn = 0.0
                var point = Vector2.zero
                var points = [point]
                for _ in 0..<rng.integer(60, 160) {
                    turn = min(max(turn + rng.gaussian() * 0.08, -0.35), 0.35)
                    heading += turn
                    point = point + Vector2(x: cos(heading), y: sin(heading))
                    points.append(point)
                }
                return points
            case .randomPoints:
                let points = (0..<rng.integer(6, 14)).map { _ in Vector2(x: rng.unit(), y: rng.unit()) }
                return HandModel(strength: 1).roundCorners(EvalGeometry.resample(points, count: 200), radius: 0.04)
            case .loops:
                let count = Double(rng.integer(2, 4))
                let angle = rng.uniform(0, 2 * .pi)
                let direction = rng.sign()
                return (0...240).map { step in
                    let t = Double(step) / 240
                    let theta = direction * 2 * .pi * count * t
                    let p = Vector2(x: 1.2 * count * t + 0.5 * sin(theta), y: -0.5 * cos(theta))
                    return p.rotated(by: angle)
                }
            case .zigzag:
                var heading = rng.uniform(0, 2 * .pi)
                var point = Vector2.zero
                var points = [point]
                var side = rng.sign()
                for _ in 0..<rng.integer(5, 8) {
                    point = point + Vector2(x: cos(heading), y: sin(heading)) * rng.uniform(0.5, 1)
                    points.append(point)
                    heading += side * rng.uniform(120, 170) * .pi / 180
                    side = -side
                }
                return points
            case .nearLine:
                let angle = rng.uniform(0, 2 * .pi)
                let bow = rng.uniform(-0.08, 0.08)
                let wobble = rng.uniform(0.01, 0.04)
                let phase = rng.uniform(0, 2 * .pi)
                return (0...100).map { step in
                    let t = Double(step) / 100
                    let p = Vector2(x: t, y: bow * sin(.pi * t) + wobble * sin(6 * .pi * t + phase))
                    return p.rotated(by: angle)
                }
            case .arc:
                let sweep = rng.uniform(70, 130) * rng.sign()
                let start = rng.uniform(0, 360)
                return PenPath.arc(0, 0, rx: 1, ry: 1, from: start, to: start + sweep).points
            case .circleAndAHalf:
                let sweep = rng.uniform(480, 600) * rng.sign()
                let start = rng.uniform(0, 360)
                let drift = rng.uniform(-0.15, 0.15)
                return (0...240).map { step in
                    let t = Double(step) / 240
                    let radians = (start + sweep * t) * .pi / 180
                    let radius = 1 + drift * t
                    return Vector2(x: radius * cos(radians) + 0.3 * drift * t, y: radius * sin(radians))
                }
            case .shortHook:
                // Diagonal, so that it is not a rounded L, J, T or F, which are letters.
                let angle = (45 + 90 * Double(rng.integer(0, 3)) + rng.uniform(-15, 15)) * .pi / 180
                let radius = rng.uniform(0.08, 0.15)
                let side = rng.sign()
                let direction = Vector2(x: cos(angle), y: sin(angle))
                let end = direction
                let normal = Vector2(x: -direction.y, y: direction.x) * side
                let centre = end + normal * radius
                let sweep = rng.uniform(180, 240)
                var points = [Vector2.zero, end]
                for step in 1...16 {
                    let turned = (normal * -radius).rotated(by: side * sweep * Double(step) / 16 * .pi / 180)
                    points.append(centre + turned)
                }
                return points
            }
        }
    }

    // MARK: Running

    struct Outcome {
        let stroke: LabelledStroke
        let match: StrokeRecognizer.Match?
    }

    struct Run {
        let recognizer: EvaluatedRecognizer
        let outcomes: [Outcome]
        /// Mean seconds per recognition.
        let secondsPerStroke: Double

        func accepted(_ outcome: Outcome, at setting: Double) -> CharacterGesture? {
            guard let match = outcome.match, recognizer.accepts(match, setting) else { return nil }
            return match.gesture
        }

        func group(_ group: LabelledStroke.Group, minStrength: Double = 0.01) -> [Outcome] {
            outcomes.filter { $0.stroke.group == group && $0.stroke.strength >= minStrength }
        }

        /// Share recognised correctly.
        func accuracy(_ set: [Outcome], at setting: Double) -> Double {
            share(set) { accepted($0, at: setting) == $0.stroke.truth }
        }

        /// Share of genuine strokes rejected outright.
        func rejectRate(_ set: [Outcome], at setting: Double) -> Double {
            share(set) { accepted($0, at: setting) == nil }
        }

        /// Share of negatives taken for a letter or a two-legged stroke. Read as a straight
        /// line, a movement is at least what it looked like.
        func falseAcceptRate(at setting: Double, kind: Negative? = nil) -> Double {
            share(group(.negative, minStrength: 0).filter { kind == nil || $0.stroke.form == kind!.rawValue }) {
                accepted($0, at: setting).map { !$0.isDirection } ?? false
            }
        }

        private func share(_ set: [Outcome], _ predicate: (Outcome) -> Bool) -> Double {
            set.isEmpty ? 0 : Double(set.filter(predicate).count) / Double(set.count)
        }

        /// The commonest wrong answers among accepted genuine strokes.
        func confusions(_ set: [Outcome], at setting: Double, limit: Int) -> [(String, Int)] {
            var counts: [String: Int] = [:]
            for outcome in set {
                guard let truth = outcome.stroke.truth, let got = accepted(outcome, at: setting), got != truth else { continue }
                counts["\(truth.displayName) → \(got.displayName)", default: 0] += 1
            }
            return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(limit).map { ($0.key, $0.value) }
        }
    }

    static func run(_ recognizer: EvaluatedRecognizer, on strokes: [LabelledStroke]) -> Run {
        let start = DispatchTime.now().uptimeNanoseconds
        let outcomes = strokes.map { Outcome(stroke: $0, match: recognizer.match($0.points)) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return Run(recognizer: recognizer, outcomes: outcomes, secondsPerStroke: elapsed / Double(max(strokes.count, 1)))
    }

    // MARK: Reporting

    static func percent(_ value: Double) -> String {
        String(format: "%5.1f%%", value * 100)
    }

    /// A plain-text table of the numbers the report asks for.
    static func report(_ runs: [Run]) -> String {
        var lines: [String] = []
        for run in runs {
            lines.append("== \(run.recognizer.name): \(String(format: "%.3f", run.secondsPerStroke * 1000)) ms per stroke")
            let letters = run.group(.letter)
            let taught = letters.filter { $0.stroke.kind == .taught }
            let natural = letters.filter { $0.stroke.kind == .natural }
            lines.append("setting  letters  taught natural  reject | lines  strokes | false accept")
            for setting in settings {
                lines.append(String(
                    format: "%.3f   %@  %@  %@  %@ | %@ %@ | %@",
                    setting,
                    percent(run.accuracy(letters, at: setting)),
                    percent(run.accuracy(taught, at: setting)),
                    percent(run.accuracy(natural, at: setting)),
                    percent(run.rejectRate(letters, at: setting)),
                    percent(run.accuracy(run.group(.direction), at: setting)),
                    percent(run.accuracy(run.group(.stroke), at: setting)),
                    percent(run.falseAcceptRate(at: setting))
                ))
            }
            lines.append("by strength at the default (letters / lines / strokes):")
            for strength in strengths {
                func at(_ group: LabelledStroke.Group) -> [Outcome] {
                    run.outcomes.filter { $0.stroke.group == group && $0.stroke.strength == strength }
                }
                lines.append(String(format: "  %.2f  %@ %@ %@", strength,
                                    percent(run.accuracy(at(.letter), at: balanced)),
                                    percent(run.accuracy(at(.direction), at: balanced)),
                                    percent(run.accuracy(at(.stroke), at: balanced))))
            }
            lines.append("false accepts at the default, by kind:")
            for kind in Negative.allCases {
                lines.append("  \(percent(run.falseAcceptRate(at: balanced, kind: kind)))  \(kind.rawValue)")
            }
            lines.append("per letter at the default (accuracy, reject, top confusion):")
            for gesture in CharacterGesture.allCases where !gesture.isDirection && !CharacterGesture.strokes.contains(gesture) {
                let set = letters.filter { $0.stroke.truth == gesture }
                let confusion = run.confusions(set, at: balanced, limit: 1).first.map { "\($0.0) ×\($0.1)" } ?? ""
                lines.append("  \(gesture.displayName.padding(toLength: 3, withPad: " ", startingAt: 0)) "
                             + "\(percent(run.accuracy(set, at: balanced))) \(percent(run.rejectRate(set, at: balanced)))  \(confusion)")
            }
            lines.append("worst forms at the default:")
            let forms = Dictionary(grouping: letters + run.group(.stroke)) { "\($0.stroke.truth!.displayName): \($0.stroke.form)" }
            for (form, set) in forms.sorted(by: { run.accuracy($0.value, at: balanced) < run.accuracy($1.value, at: balanced) }).prefix(12) {
                lines.append("  \(percent(run.accuracy(set, at: balanced)))  \(form)")
            }
            lines.append("commonest confusions at the default:")
            for (pair, count) in run.confusions(letters + run.group(.stroke) + run.group(.direction), at: balanced, limit: 12) {
                lines.append("  \(count)  \(pair)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
