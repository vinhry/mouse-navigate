import XCTest
@testable import MouseNavigateCore

/// Measures drawn-letter recognition on synthetic hand-drawn strokes and, where available,
/// real handwriting, and holds the recognizer to the quality it has reached.
///
/// Set `MOUSENAVIGATE_STROKE_REPORT=1` to print the full comparison with the 0.8.1
/// recognizer on a larger set, and `MOUSENAVIGATE_UJI_PATH` to the UJI Pen Characters file to
/// include all of its one-stroke letters.
///
/// The 0.8.1 recognizer, on the full report's synthetic set (distorted strokes only) at
/// Loose / Balanced / Strict: letters 56% / 44% / 3% correct (taught forms 84% / 66% / 6%),
/// half of all letters rejected at Balanced; straight lines 13% at every setting; corner and
/// out-and-back strokes 99% / 97% / 12%; 79% / 21% / 0% of non-letters accepted as a letter
/// or stroke. On the UJI held-out writers, letters in the forms the app teaches: 44% / 31% / 1%.
final class StrokeEvaluationTests: XCTestCase {
    private static let environment = ProcessInfo.processInfo.environment

    private static let genuine = StrokeEvaluation.genuineStrokes(perCell: 1, seed: 1)
    private static let negatives = StrokeEvaluation.negativeStrokes(perKind: 20, seed: 2)

    private static let synthetic = StrokeEvaluation.run(.current, on: genuine + negatives)
    private static let real: StrokeEvaluation.Run? = (try? UJIPenCharacters.fixture())
        .map { StrokeEvaluation.run(.current, on: UJIPenCharacters.labelled($0)) }

    private typealias E = StrokeEvaluation

    func testTheStrokesAreTheSameEveryRun() {
        let a = StrokeEvaluation.genuineStrokes(perCell: 1, seed: 5)
        let b = StrokeEvaluation.genuineStrokes(perCell: 1, seed: 5)
        XCTAssertEqual(a.count, b.count)
        XCTAssertTrue(zip(a, b).allSatisfy { $0.points == $1.points })
        let c = StrokeEvaluation.negativeStrokes(perKind: 3, seed: 5)
        let d = StrokeEvaluation.negativeStrokes(perKind: 3, seed: 5)
        XCTAssertTrue(zip(c, d).allSatisfy { $0.points == $1.points })
    }

    /// The test strokes come from shapes written for the evaluation, not from the
    /// recognizer's own templates.
    func testReferenceShapesAreNotTheTemplates() {
        let templates = CharacterTemplates.all.map { EvalGeometry.resample($0.points, count: 32) }
        for shape in ReferenceShapes.letters {
            let points = EvalGeometry.resample(shape.points, count: 32)
            XCTAssertFalse(templates.contains { zip($0, points).allSatisfy { ($0.0 - $0.1).magnitude < 1e-3 } },
                           "\(shape.gesture) \(shape.name) is a template")
        }
    }

    func testGestureCoverage() {
        let covered = Set(ReferenceShapes.all.map(\.gesture))
        for gesture in CharacterGesture.allCases {
            XCTAssertTrue(covered.contains(gesture), "\(gesture) has no reference shape")
        }
        XCTAssertGreaterThan(Self.real?.outcomes.count ?? 0, 250, "the real handwriting sample is missing")
    }

    func testQualityAtTheDefault() {
        let run = Self.synthetic
        let letters = run.group(.letter)
        let taught = letters.filter { $0.stroke.kind == .taught }
        printIfAsked(run)
        XCTAssertGreaterThanOrEqual(run.accuracy(letters, at: E.balanced), 0.40)
        XCTAssertGreaterThanOrEqual(run.accuracy(taught, at: E.balanced), 0.60)
        XCTAssertGreaterThanOrEqual(run.accuracy(run.group(.stroke), at: E.balanced), 0.95)
        XCTAssertGreaterThanOrEqual(run.accuracy(run.group(.direction), at: E.balanced), 0.0)
        XCTAssertLessThanOrEqual(run.falseAcceptRate(at: E.balanced), 0.25)
    }

    func testQualityOnRealHandwriting() throws {
        let run = try XCTUnwrap(Self.real)
        let letters = run.group(.letter)
        let taught = letters.filter { $0.stroke.kind == .taught }
        printIfAsked(run)
        XCTAssertGreaterThanOrEqual(run.accuracy(taught, at: E.balanced), 0.25)
    }

    /// Moving the slider towards Strict never accepts more, of anything.
    func testTheSliderIsMonotonic() {
        let run = Self.synthetic
        let letters = run.group(.letter)
        for (looser, stricter) in zip(E.settings, E.settings.dropFirst()) {
            XCTAssertLessThanOrEqual(run.rejectRate(letters, at: looser), run.rejectRate(letters, at: stricter))
            XCTAssertGreaterThanOrEqual(run.falseAcceptRate(at: looser), run.falseAcceptRate(at: stricter))
        }
        XCTAssertGreaterThan(run.accuracy(letters, at: E.loose), run.accuracy(letters, at: E.strict))
    }

    private func printIfAsked(_ run: StrokeEvaluation.Run) {
        if Self.environment["MOUSENAVIGATE_STROKE_REPORT"] == "1" { print(E.report([run])) }
    }

    func testFullReport() throws {
        try XCTSkipUnless(Self.environment["MOUSENAVIGATE_STROKE_REPORT"] == "1", "set MOUSENAVIGATE_STROKE_REPORT=1")
        let strokes = StrokeEvaluation.genuineStrokes(perCell: 10, seed: 11)
            + StrokeEvaluation.negativeStrokes(perKind: 150, seed: 12)
        var text = "Synthetic: \(strokes.count) strokes\n"
        text += StrokeEvaluation.report([
            StrokeEvaluation.run(.legacy, on: strokes),
            StrokeEvaluation.run(.current, on: strokes),
        ])
        if let path = UJIPenCharacters.environmentPath {
            let samples = try UJIPenCharacters.load(path: path)
            for (name, writers) in [("trn", false), ("tst", true)] {
                let real = UJIPenCharacters.labelled(samples.filter { $0.isTestWriter == writers })
                text += "\n\nUJI \(name) writers: \(real.count) one-stroke letters\n"
                text += StrokeEvaluation.report([
                    StrokeEvaluation.run(.legacy, on: real),
                    StrokeEvaluation.run(.current, on: real),
                ])
            }
        }
        print(text)
        if let out = Self.environment["MOUSENAVIGATE_STROKE_REPORT_FILE"] {
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
