import XCTest
@testable import MouseNavigateCore

/// The ways the recognizer forgives how people actually draw, one at a time.
final class StrokeRecognizerForgivenessTests: XCTestCase {
    private let recognizer = StrokeRecognizer()
    private let tuning = StrokeRecognizer.Tuning()

    /// Densely sampled, as a finger would report it.
    private func trace(_ points: [(Double, Double)], count: Int = 90) -> [Vector2] {
        StrokeRecognizer.resample(points.map { Vector2(x: $0.0, y: $0.1) }, count: count)
    }

    private func ellipse(from start: Double, to end: Double, steps: Int = 60) -> [Vector2] {
        (0...steps).map { step in
            let radians = (start + (end - start) * Double(step) / Double(steps)) * .pi / 180
            return Vector2(x: 0.5 + 0.42 * cos(radians), y: 0.5 + 0.5 * sin(radians))
        }
    }

    private func cuts(_ stroke: [Vector2]) -> [Double] {
        StrokeRecognizer.hookless(StrokeRecognizer.tidy(stroke, tuning: tuning), tuning: tuning).map(\.cut)
    }

    // MARK: Hooks

    func testHooksAtBothEndsAreCutOff() {
        // A landing tick and a lift flick, each about a twentieth of the stroke, turned back sharply.
        let stroke = trace([(0.55, 0.05), (0.5, 0), (0.5, 1), (0.45, 0.96)])
        let cut = cuts(stroke)
        XCTAssertEqual(cut.count, 2)
        XCTAssertGreaterThan(cut[1], 0.05)
        XCTAssertLessThan(cut[1], 0.2)
        XCTAssertEqual(recognizer.recognize(stroke), .down)
    }

    func testAHookedLetterIsStillTheLetter() {
        let n = trace([(0.06, 0.94), (0, 1), (0, 0), (1, 1), (1, 0), (0.94, 0.05)])
        XCTAssertEqual(recognizer.recognize(n), .n)
        let z = trace([(0.05, 0.08), (0, 0), (1, 0), (0, 1), (1, 1), (1.04, 0.94)])
        XCTAssertEqual(recognizer.recognize(z), .z)
    }

    /// L, T, F and J and the corner strokes have short legs on purpose; a quarter of the
    /// other leg is a fifth of the stroke, twice the longest hook.
    func testShortLegsAreNotHooks() {
        let cases: [([(Double, Double)], CharacterGesture)] = [
            ([(0, 0), (0, 1), (0.25, 1)], .l),
            ([(0, 0), (1, 0), (1, 0.25)], .t),
            ([(1, 0), (0, 0), (0, 0.25)], .f),
            ([(1, 0), (1, 1), (0.75, 1)], .j),
            ([(1, 1), (0, 1), (0, 0.75)], .leftThenUp),
            ([(0, 1), (0, 0), (0.25, 0)], .upThenRight),
        ]
        for (points, expected) in cases {
            let stroke = trace(points)
            XCTAssertEqual(cuts(stroke), [0], "\(expected) lost a leg")
            XCTAssertEqual(recognizer.recognize(stroke), expected)
        }
    }

    func testQKeepsItsTail() {
        let q = CharacterTemplates.letters.first { $0.gesture == .q }!
        XCTAssertEqual(recognizer.recognize(trace(q.points.map { ($0.x, $0.y) })), .q)
    }

    // MARK: Pauses and jitter

    func testAPauseDoesNotCount() {
        var stroke = trace([(0, 1), (0, 0), (1, 1), (1, 0)])
        var generator = SeededGenerator(seed: 3)
        // A hundred and fifty reports at the first corner, wandering a fraction of a percent.
        let corner = stroke[30]
        let pause = (0..<150).map { _ in
            Vector2(x: corner.x + Double.random(in: -0.003...0.003, using: &generator),
                    y: corner.y + Double.random(in: -0.003...0.003, using: &generator))
        }
        stroke.insert(contentsOf: pause, at: 30)
        XCTAssertEqual(recognizer.recognize(stroke), .n)
    }

    /// Two fingers' midpoint shakes. Measured on the raw points, the shake alone made a
    /// line look curved.
    func testAShakyLineIsStillALine() {
        var generator = SeededGenerator(seed: 9)
        let line = trace([(0.2, 0.1), (0.8, 0.9)], count: 150).map {
            Vector2(x: $0.x + Double.random(in: -0.012...0.012, using: &generator),
                    y: $0.y + Double.random(in: -0.012...0.012, using: &generator))
        }
        XCTAssertGreaterThan(StrokeRecognizer.pathLength(line) * 0.9, 1.0, "the shake alone should fail the old straightness test")
        XCTAssertEqual(recognizer.recognize(line), .downRight)
    }

    func testABowedLineIsALineButAHalfCircleIsNot() {
        let bowed = (0...40).map { step -> Vector2 in
            let t = Double(step) / 40
            return Vector2(x: t, y: 0.1 * sin(.pi * t))
        }
        XCTAssertEqual(recognizer.recognize(bowed), .right)
        let half = ellipse(from: 180, to: 360)
        XCTAssertFalse(recognizer.bestMatch(half)!.gesture.isDirection)
    }

    // MARK: Other ways of drawing a letter

    func testOFromAnyStartEitherWay() {
        for start in stride(from: 0.0, to: 360, by: 45) {
            XCTAssertEqual(recognizer.recognize(ellipse(from: start, to: start - 360)), .o, "anticlockwise from \(start)°")
            XCTAssertEqual(recognizer.recognize(ellipse(from: start, to: start + 360)), .o, "clockwise from \(start)°")
        }
    }

    func testLettersDrawnBackwards() {
        // C and S begun at the bottom, U and V begun on the right.
        XCTAssertEqual(recognizer.recognize(ellipse(from: 45, to: 315)), .c)
        let s = [(0.1, 0.9), (0.4, 1), (0.85, 0.9), (0.9, 0.7), (0.5, 0.5), (0.1, 0.3), (0.15, 0.08), (0.5, 0), (0.9, 0.1)]
        XCTAssertEqual(recognizer.recognize(trace(s)), .s)
        XCTAssertEqual(recognizer.recognize(trace([(1, 0), (1, 0.7), (0.8, 1), (0.2, 1), (0, 0.7), (0, 0)])), .u)
        XCTAssertEqual(recognizer.recognize(trace([(1, 0), (0.5, 1), (0, 0)])), .v)
    }

    func testStemsDrawnDownFirst() {
        // Down the stem, back up beside it, then the rest of the letter.
        let cases: [([(Double, Double)], CharacterGesture)] = [
            ([(0, 0), (0, 1), (0.04, 0), (0.65, 0), (0.95, 0.25), (0.6, 0.5), (0.04, 0.5)], .p),
            ([(0, 0), (0, 1), (0.04, 0), (0.65, 0), (0.95, 0.25), (0.6, 0.5), (0.04, 0.5), (1, 1)], .r),
            ([(0, 0), (0, 1), (0.04, 0), (0.6, 0.05), (1, 0.5), (0.6, 0.95), (0.04, 1)], .d),
            ([(0, 0), (0, 1), (0.04, 0), (1, 1), (1, 0)], .n),
            ([(0, 0), (0, 1), (0.04, 0), (0.5, 0.7), (1, 0), (1, 1)], .m),
        ]
        for (points, expected) in cases {
            XCTAssertEqual(recognizer.recognize(trace(points)), expected, "\(expected)")
        }
    }

    func testCommonLowerCaseForms() {
        // n and m as arches, e as a loop, d with its bowl first.
        let n = [(0, 0.1), (0, 1), (0, 0.35), (0.3, 0.02), (0.7, 0.02), (1, 0.35), (1, 1)]
        XCTAssertEqual(recognizer.recognize(trace(n)), .n)
        let m = [(0, 0.2), (0, 1), (0, 0.45), (0.2, 0.2), (0.4, 0.3), (0.5, 0.5), (0.5, 1), (0.5, 0.45),
                 (0.7, 0.2), (0.9, 0.3), (1, 0.5), (1, 1)]
        XCTAssertEqual(recognizer.recognize(trace(m)), .m)
        let e = [(0.1, 0.55), (0.9, 0.5)] + ellipse(from: -5, to: -320).map { ($0.x, $0.y) }
        XCTAssertEqual(recognizer.recognize(trace(e)), .e)
    }

    // MARK: Search and scores

    /// `bestMatch` gives up on comparisons that cannot change its answer; it must give the
    /// same answer as the full ranking.
    func testTheShortCutAgreesWithTheFullRanking() {
        let strokes = StrokeEvaluation.genuineStrokes(perCell: 1, seed: 17, strengths: [0.67]).prefix(40).map(\.points)
            + StrokeEvaluation.negativeStrokes(perKind: 3, seed: 18).map(\.points)
        for stroke in strokes {
            let ranked = recognizer.matches(stroke)
            let best = recognizer.bestMatch(stroke)!
            XCTAssertEqual(best.gesture, ranked[0].gesture)
            XCTAssertEqual(best.score, ranked[0].score, accuracy: 1e-9)
            XCTAssertEqual(best.runnerUp, ranked.count > 1 ? ranked[1].gesture : nil)
            if let runnerUp = best.runnerUp {
                XCTAssertNotEqual(runnerUp, best.gesture)
                XCTAssertEqual(best.runnerUpScore!, ranked[1].score, accuracy: 1e-9)
            }
        }
    }

    /// The score's stretch keeps a perfect match at 1, puts the measured default where the
    /// slider's default is, and never changes the order of two scores.
    func testCalibrationIsAnchoredAndMonotonic() {
        XCTAssertEqual(recognizer.calibrated(1), 1, accuracy: 1e-12)
        XCTAssertEqual(recognizer.calibrated(tuning.defaultRawScore), StrokeRecognizer.defaultMinimumScore, accuracy: 1e-12)
        var previous = -Double.infinity
        for raw in stride(from: -1.0, through: 1.0, by: 0.05) {
            let score = recognizer.calibrated(raw)
            XCTAssertGreaterThan(score, previous)
            XCTAssertEqual(recognizer.rawScore(fromCalibrated: score), raw, accuracy: 1e-9)
            previous = score
        }
    }

    /// Recognition runs on the main thread as a stroke ends. A release build takes well
    /// under a millisecond; this bound is loose enough for a debug build on a busy machine.
    func testALongStrokeIsQuick() {
        var rng = SplitMix64(seed: 4)
        let shape = ReferenceShapes.letters.first { $0.gesture == .m }!
        let base = HandModel(strength: 0.7).apply(shape, using: &rng)
        let stroke = EvalGeometry.resample(base, count: 600)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = recognizer.bestMatch(stroke) }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / 10
        print(String(format: "a 600-point stroke takes %.3f ms", milliseconds))
        XCTAssertLessThan(milliseconds, 40, "a 600-point stroke took \(milliseconds) ms")
    }
}
