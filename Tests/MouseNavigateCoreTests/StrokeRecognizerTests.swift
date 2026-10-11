import XCTest
@testable import MouseNavigateCore

final class StrokeRecognizerTests: XCTestCase {
    private let recognizer = StrokeRecognizer()

    /// Densely sampled, as a finger would report it.
    private func trace(_ points: [Vector2], scale: Double = 1, offset: Vector2 = .zero) -> [Vector2] {
        StrokeRecognizer.resample(points, count: 90).map {
            Vector2(x: $0.x * scale + offset.x, y: $0.y * scale + offset.y)
        }
    }

    func testEveryTemplateRecognizesAsItself() {
        for template in CharacterTemplates.all {
            XCTAssertEqual(
                recognizer.recognize(trace(template.points)),
                template.gesture,
                "template for \(template.gesture) matched \(String(describing: recognizer.bestMatch(trace(template.points))))"
            )
        }
    }

    func testScaledAndOffsetTemplatesStillMatch() {
        for template in CharacterTemplates.all {
            let drawn = trace(template.points, scale: 0.4, offset: Vector2(x: 0.7, y: 0.2))
            XCTAssertEqual(recognizer.recognize(drawn), template.gesture, "\(template.gesture)")
        }
    }

    func testJitteredTemplatesStillMatch() {
        var generator = SeededGenerator(seed: 42)
        for template in CharacterTemplates.all {
            let drawn = trace(template.points).map {
                Vector2(
                    x: $0.x + Double.random(in: -0.02...0.02, using: &generator),
                    y: $0.y + Double.random(in: -0.02...0.02, using: &generator)
                )
            }
            XCTAssertEqual(recognizer.recognize(drawn), template.gesture, "\(template.gesture)")
        }
    }

    func testSlightlySlantedLetterStillMatches() {
        let template = CharacterTemplates.all.first { $0.gesture == .n }!
        let slanted = StrokeRecognizer.rotate(trace(template.points), by: 10 * .pi / 180)
        XCTAssertEqual(recognizer.recognize(slanted), .n)
    }

    func testStraightStrokesAreDirections() {
        let cases: [(Vector2, CharacterGesture)] = [
            (Vector2(x: 0, y: -1), .up),
            (Vector2(x: 0, y: 1), .down),
            (Vector2(x: -1, y: 0), .left),
            (Vector2(x: 1, y: 0), .right),
            (Vector2(x: -1, y: -1), .upLeft),
            (Vector2(x: 1, y: -1), .upRight),
            (Vector2(x: -1, y: 1), .downLeft),
            (Vector2(x: 1, y: 1), .downRight),
        ]
        for (vector, expected) in cases {
            let stroke = trace([Vector2(x: 0.5, y: 0.5), Vector2(x: 0.5 + vector.x * 0.3, y: 0.5 + vector.y * 0.3)])
            XCTAssertEqual(recognizer.recognize(stroke), expected, "\(vector)")
        }
    }

    func testWobblyVerticalLineIsStillDown() {
        let stroke = trace([
            Vector2(x: 0.5, y: 0), Vector2(x: 0.53, y: 0.3), Vector2(x: 0.48, y: 0.6), Vector2(x: 0.51, y: 1),
        ])
        XCTAssertEqual(recognizer.recognize(stroke), .down)
    }

    func testLIsNotMistakenForADirection() {
        let stroke = trace([Vector2(x: 0, y: 0), Vector2(x: 0, y: 1), Vector2(x: 0.8, y: 1)])
        XCTAssertEqual(recognizer.recognize(stroke), .l)
    }

    func testScribbleIsRejected() {
        var generator = SeededGenerator(seed: 7)
        let scribble = (0..<30).map { _ in
            Vector2(x: Double.random(in: 0...1, using: &generator), y: Double.random(in: 0...1, using: &generator))
        }
        XCTAssertNil(recognizer.recognize(trace(scribble)))
    }

    func testAcceptsAgreesWithRecognize() {
        let letter = trace(CharacterTemplates.all.first { $0.gesture == .n }!.points)
        let line = trace([Vector2(x: 0, y: 0), Vector2(x: 0, y: 1)])
        var generator = SeededGenerator(seed: 7)
        let scribble = (0..<40).map { _ in
            Vector2(x: Double.random(in: 0...1, using: &generator), y: Double.random(in: 0...1, using: &generator))
        }
        for stroke in [letter, line, scribble] {
            let viaMatch = recognizer.bestMatch(stroke).flatMap { recognizer.accepts($0) ? $0.gesture : nil }
            XCTAssertEqual(viaMatch, recognizer.recognize(stroke))
        }
        XCTAssertNotNil(recognizer.recognize(letter))
        XCTAssertNil(recognizer.recognize(scribble))
    }

    func testDegenerateStrokesAreIgnored() {
        XCTAssertNil(recognizer.recognize([]))
        XCTAssertNil(recognizer.recognize([Vector2(x: 0.5, y: 0.5)]))
        XCTAssertNil(recognizer.recognize([Vector2(x: 0.5, y: 0.5), Vector2(x: 0.5, y: 0.5)]))
    }

    func testDefaultsFollowJitouch() {
        XCTAssertEqual(CharacterGesture.t.defaultAction, .newTab)
        XCTAssertEqual(CharacterGesture.up.defaultAction, .copy)
        XCTAssertEqual(CharacterGesture.down.defaultAction, .paste)
        XCTAssertEqual(CharacterGesture.left.defaultAction, .maximizeLeft)
        XCTAssertEqual(CharacterGesture.z.defaultAction, .disabled)
    }

    func testEveryGestureHasAPreviewStroke() {
        for gesture in CharacterGesture.allCases {
            let preview = CharacterTemplates.preview(for: gesture)
            XCTAssertGreaterThanOrEqual(preview.count, 2, "\(gesture) has no preview")
            XCTAssertGreaterThan(StrokeRecognizer.pathLength(preview), 0, "\(gesture) preview has no length")
        }
    }

    func testPreviewStrokesAreRecognisedAsThemselves() {
        // What the preview shows must be what the recogniser accepts, letters and arrows alike.
        for gesture in CharacterGesture.allCases {
            XCTAssertEqual(
                recognizer.recognize(trace(CharacterTemplates.preview(for: gesture))),
                gesture,
                "\(gesture) preview is not recognised as itself"
            )
        }
    }

    func testEveryLetterHasATemplate() {
        let covered = Set(CharacterTemplates.all.map(\.gesture))
        for gesture in CharacterGesture.allCases where !gesture.isDirection {
            XCTAssertTrue(covered.contains(gesture), "\(gesture) has no template")
        }
    }
}

/// Deterministic randomness so jitter tests never flake.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class StrokeRecognizerCompoundStrokeTests: XCTestCase {
    private let recognizer = StrokeRecognizer()

    private func trace(_ points: [(Double, Double)]) -> [Vector2] {
        StrokeRecognizer.resample(points.map { Vector2(x: $0.0, y: $0.1) }, count: 90)
    }

    func testCornerWithAShortSecondLegIsStillACorner() {
        // A fifth of the first leg is a corner; a twelfth is a hand that wobbled at the end.
        XCTAssertEqual(recognizer.recognize(trace([(1, 1), (0, 1), (0, 0.8)])), .leftThenUp)
        XCTAssertEqual(recognizer.recognize(trace([(0, 1), (1, 1), (1, 0.8)])), .rightThenUp)
        XCTAssertEqual(recognizer.recognize(trace([(1, 1), (1, 0), (0.8, 0)])), .upThenLeft)
        XCTAssertEqual(recognizer.recognize(trace([(0, 1), (0, 0), (0.2, 0)])), .upThenRight)
        XCTAssertEqual(recognizer.recognize(trace([(1, 1), (0, 1), (0, 0.92)])), .left)
        XCTAssertEqual(recognizer.recognize(trace([(0, 1), (0, 0), (0.08, 0)])), .up)
    }

    func testBackAndForthWithAShortReturnIsStillTheStroke() {
        // A return of two fifths, and one drawn straight back over the outward leg.
        XCTAssertEqual(recognizer.recognize(trace([(1, 0.5), (0, 0.5), (0.4, 0.52)])), .leftThenRight)
        XCTAssertEqual(recognizer.recognize(trace([(0, 0.5), (1, 0.5), (0.6, 0.52)])), .rightThenLeft)
        XCTAssertEqual(recognizer.recognize(trace([(0.5, 1), (0.5, 0), (0.52, 0.4)])), .upThenDown)
        XCTAssertEqual(recognizer.recognize(trace([(0.5, 0), (0.5, 1), (0.52, 0.6)])), .downThenUp)
        XCTAssertEqual(recognizer.recognize(trace([(1, 0.5), (0, 0.5), (1, 0.5)])), .leftThenRight)
        XCTAssertEqual(recognizer.recognize(trace([(0.5, 0), (0.5, 1), (0.5, 0)])), .downThenUp)
        // A return of a twenty-fifth is the pen lifting, not a stroke back.
        XCTAssertEqual(recognizer.recognize(trace([(1, 0.5), (0, 0.5), (0.04, 0.5)])), .left)
        XCTAssertEqual(recognizer.recognize(trace([(0.5, 0), (0.5, 1), (0.5, 0.96)])), .down)
    }

    func testStrokesBeatTheNearestLetterByAMargin() {
        // Every stroke must win clearly over the letters it most resembles, or a loose hand
        // would flip between the two. Up then Right starts the way P, R, B and D do.
        let letters = StrokeRecognizer(templates: CharacterTemplates.letters)
        for gesture in CharacterGesture.strokes {
            let drawn = StrokeRecognizer.resample(CharacterTemplates.preview(for: gesture), count: 90)
            let best = recognizer.bestMatch(drawn)!
            let nearestLetter = letters.bestMatch(drawn)!
            XCTAssertEqual(best.gesture, gesture)
            XCTAssertGreaterThanOrEqual(
                best.score - nearestLetter.score, 0.1,
                "\(gesture) scores \(best.score) against \(nearestLetter.gesture) at \(nearestLetter.score)"
            )
        }
    }

    func testLettersAreNotTakenByTheStrokes() {
        // The letters whose shapes come closest to the strokes keep matching as themselves.
        let strokesOnly = StrokeRecognizer(templates: CharacterTemplates.strokes)
        for gesture in [CharacterGesture.p, .r, .b, .d, .l, .f, .t, .j, .n, .u, .v, .w] {
            for template in CharacterTemplates.letters where template.gesture == gesture {
                let drawn = StrokeRecognizer.resample(template.points, count: 90)
                XCTAssertEqual(recognizer.recognize(drawn), gesture)
                let asStroke = strokesOnly.bestMatch(drawn)!
                let asLetter = recognizer.bestMatch(drawn)!
                XCTAssertGreaterThanOrEqual(
                    asLetter.score - asStroke.score, 0.1,
                    "\(gesture) scores \(asLetter.score) against \(asStroke.gesture) at \(asStroke.score)"
                )
            }
        }
    }

    func testStrokesDefaultToDisabledAndHaveTemplates() {
        let covered = Set(CharacterTemplates.all.map(\.gesture))
        for gesture in CharacterGesture.strokes {
            XCTAssertEqual(gesture.defaultAction, .disabled)
            XCTAssertFalse(gesture.isDirection)
            XCTAssertTrue(covered.contains(gesture), "\(gesture) has no template")
            XCTAssertTrue(gesture.displayName.contains("then"), gesture.displayName)
        }
        XCTAssertEqual(Set(CharacterGesture.allCases).count, CharacterGesture.allCases.count)
    }
}
