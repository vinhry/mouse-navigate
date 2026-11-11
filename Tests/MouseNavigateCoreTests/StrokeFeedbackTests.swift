import XCTest
@testable import MouseNavigateCore

final class StrokeFeedbackTests: XCTestCase {
    private func lines(_ match: StrokeRecognizer.Match?, bound: String? = nil, minimum: Double = 0.8) -> StrokeFeedback {
        StrokeFeedback.lines(for: match, minimumScore: minimum, actionName: bound)
    }

    func testARecognisedBoundLetterShowsItsAction() {
        let result = lines(.init(gesture: .t, score: 0.9, runnerUp: .f, runnerUpScore: 0.85), bound: "New Tab (⌘T)")
        XCTAssertEqual(result, StrokeFeedback(title: "T", subtitle: "New Tab (⌘T)"))
    }

    func testARecognisedLetterWithNothingBoundSaysSo() {
        let result = lines(.init(gesture: .b, score: 0.9))
        XCTAssertEqual(result, StrokeFeedback(title: "B", subtitle: "No action"))
    }

    func testANearMissNamesTheClosestLetter() {
        let result = lines(.init(gesture: .b, score: 0.74, runnerUp: .d, runnerUpScore: 0.6))
        XCTAssertEqual(result, StrokeFeedback(title: "no match", subtitle: "Closest: B"))
    }

    func testATieNamesBoth() {
        let result = lines(.init(gesture: .b, score: 0.76, runnerUp: .d, runnerUpScore: 0.74))
        XCTAssertEqual(result.subtitle, "Closest: B or D")
    }

    func testARunnerUpTooFarBackOrTooPoorIsLeftOut() {
        XCTAssertEqual(lines(.init(gesture: .b, score: 0.76, runnerUp: .d, runnerUpScore: 0.6)).subtitle, "Closest: B")
        // Close to the best, but itself nowhere near the threshold.
        XCTAssertEqual(lines(.init(gesture: .b, score: 0.68, runnerUp: .d, runnerUpScore: 0.66)).subtitle, "Closest: B or D")
        XCTAssertEqual(lines(.init(gesture: .b, score: 0.66, runnerUp: .d, runnerUpScore: 0.64)).subtitle, "Closest: B")
    }

    func testAScribbleIsNotToldItWasNearlyAnything() {
        let result = lines(.init(gesture: .q, score: 0.4, runnerUp: .o, runnerUpScore: 0.39))
        XCTAssertEqual(result, StrokeFeedback(title: "no match", subtitle: nil))
    }

    func testNothingToCompareShowsAPlainMiss() {
        XCTAssertEqual(lines(nil), StrokeFeedback(title: "no match", subtitle: nil))
    }

    func testTheReachFollowsTheStrictnessSetting() {
        let match = StrokeRecognizer.Match(gesture: .b, score: 0.7)
        XCTAssertEqual(lines(match, minimum: 0.8).subtitle, "Closest: B")
        XCTAssertNil(lines(match, minimum: 0.95).subtitle)
    }

    func testAcceptanceAgreesWithTheRecogniser() {
        let recogniser = StrokeRecognizer()
        for score in [0.5, 0.79, 0.8, 0.81] {
            let match = StrokeRecognizer.Match(gesture: .c, score: score)
            let shownAsLetter = lines(match, bound: "X").title == "C"
            XCTAssertEqual(shownAsLetter, recogniser.accepts(match), "\(score)")
        }
    }

    func testDebugLineGivesRunnerUpAndNeededScore() {
        let match = StrokeRecognizer.Match(gesture: .b, score: 0.84, runnerUp: .d, runnerUpScore: 0.79)
        XCTAssertEqual(StrokeFeedback.debugDescription(of: match, minimumScore: 0.8), "B (score 0.84), then D (0.79), needs 0.80")
        XCTAssertEqual(StrokeFeedback.debugDescription(of: .init(gesture: .left, score: 1), minimumScore: 0.8), "Left ← (score 1.00), needs 0.80")
        XCTAssertEqual(StrokeFeedback.debugDescription(of: nil, minimumScore: 0.8), "nothing")
    }

    // MARK: - Drawing help

    func testEveryGestureHasHelp() {
        for gesture in CharacterGesture.allCases {
            XCTAssertFalse(CharacterDrawingHelp.text(for: gesture).isEmpty, "\(gesture)")
        }
    }

    func testHelpSaysWhichAlternativesExist() {
        for gesture in CharacterGesture.allCases {
            let kinds = Set(CharacterTemplates.all.filter { $0.gesture == gesture }.compactMap(\.alternativeKind))
            let help = CharacterDrawingHelp.text(for: gesture)
            if kinds.contains(.reversed) { XCTAssertTrue(help.contains("backwards"), "\(gesture)") }
            if kinds.contains(.anyStart) { XCTAssertTrue(help.contains("any point"), "\(gesture)") }
            if kinds.contains(.stemFirst) { XCTAssertTrue(help.contains("stem"), "\(gesture)") }
            if kinds.contains(.lowerCase) { XCTAssertTrue(help.contains("lower-case"), "\(gesture)") }
            if kinds.isEmpty { XCTAssertFalse(help.contains("also accepted"), "\(gesture)") }
        }
        XCTAssertTrue(CharacterDrawingHelp.text(for: .o).contains("any point"))
        XCTAssertTrue(CharacterDrawingHelp.text(for: .c).contains("backwards"))
    }
}
