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
