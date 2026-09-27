import XCTest
@testable import MouseNavigateCore

final class ScrollWheelTests: XCTestCase {
    private let notch = ScrollDelta(lines: (1, 0), fixedLines: (1, 0), points: (10, 0))

    // MARK: - Settings

    func testStandardSettingsLeaveTheWheelAlone() {
        XCTAssertFalse(ScrollSettings.standard.isActive)
        XCTAssertTrue(ScrollSettings(isReversed: true, speed: 1, isSmooth: false).isActive)
        XCTAssertTrue(ScrollSettings(isReversed: false, speed: 2, isSmooth: false).isActive)
        XCTAssertTrue(ScrollSettings(isReversed: false, speed: 1, isSmooth: true).isActive)
    }

    func testSpeedIsClamped() {
        XCTAssertEqual(ScrollSettings(isReversed: false, speed: 100, isSmooth: false).speed, 4)
        XCTAssertEqual(ScrollSettings(isReversed: false, speed: 0, isSmooth: false).speed, 0.5)
    }

    // MARK: - Transform

    func testReverseFlipsEveryForm() {
        let result = ScrollTransform.apply(
            ScrollDelta(lines: (2, -1), fixedLines: (2, -1), points: (20, -10)),
            settings: ScrollSettings(isReversed: true, speed: 1, isSmooth: false)
        )
        XCTAssertEqual(result, ScrollDelta(lines: (-2, 1), fixedLines: (-2, 1), points: (-20, 10)))
    }

    func testSpeedScalesEveryForm() {
        let result = ScrollTransform.apply(notch, settings: ScrollSettings(isReversed: false, speed: 3, isSmooth: false))
        XCTAssertEqual(result, ScrollDelta(lines: (3, 0), fixedLines: (3, 0), points: (30, 0)))
    }

    func testSlowingDownNeverTurnsANotchIntoNothing() {
        let result = ScrollTransform.apply(notch, settings: ScrollSettings(isReversed: true, speed: 0.5, isSmooth: false))
        XCTAssertEqual(result.lines.vertical, -1)
        XCTAssertEqual(result.lines.horizontal, 0)
        XCTAssertEqual(result.points.vertical, -5)
    }

    // MARK: - Smoother

    /// Runs the smoother at 120 Hz until it settles, returning each frame's vertical step.
    private func drain(_ smoother: inout ScrollSmoother, maxFrames: Int = 500) -> [Int] {
        var steps: [Int] = []
        for _ in 0..<maxFrames where !smoother.isIdle {
            steps.append(smoother.step(elapsed: 1.0 / 120).vertical)
        }
        return steps
    }

    func testANotchIsSpreadOverSeveralFramesAndAddsUpExactly() {
        var smoother = ScrollSmoother(timeConstant: 0.08)
        smoother.add(vertical: 40, horizontal: 0)
        let steps = drain(&smoother)
        XCTAssertGreaterThan(steps.count, 3)
        XCTAssertEqual(steps.reduce(0, +), 40)
        XCTAssertTrue(smoother.isIdle)
        // Fastest first, easing out.
        XCTAssertGreaterThanOrEqual(steps.first ?? 0, steps.last ?? 0)
    }

    func testFractionalDistancesAreNotLost() {
        var smoother = ScrollSmoother(timeConstant: 0.05)
        smoother.add(vertical: -7.7, horizontal: 0)
        XCTAssertEqual(drain(&smoother).reduce(0, +), -8)
    }

    func testNotchesInARowAccumulate() {
        var smoother = ScrollSmoother(timeConstant: 0.08)
        smoother.add(vertical: 30, horizontal: 0)
        let first = smoother.step(elapsed: 1.0 / 120).vertical
        smoother.add(vertical: 30, horizontal: 0)
        let rest = drain(&smoother)
        XCTAssertEqual(first + rest.reduce(0, +), 60)
    }

    func testReversingDropsTheOldDirection() {
        var smoother = ScrollSmoother(timeConstant: 0.08)
        smoother.add(vertical: 100, horizontal: 0)
        let first = smoother.step(elapsed: 1.0 / 120).vertical
        XCTAssertGreaterThan(first, 0)
        smoother.add(vertical: -20, horizontal: 0)
        let rest = drain(&smoother)
        XCTAssertTrue(rest.allSatisfy { $0 <= 0 }, "\(rest)")
    }

    func testAxesAreIndependent() {
        var smoother = ScrollSmoother(timeConstant: 0.08)
        smoother.add(vertical: 0, horizontal: 25)
        var horizontal = 0
        while !smoother.isIdle {
            let step = smoother.step(elapsed: 1.0 / 120)
            XCTAssertEqual(step.vertical, 0)
            horizontal += step.horizontal
        }
        XCTAssertEqual(horizontal, 25)
    }

    func testStopClearsEverything() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: 50, horizontal: 50)
        smoother.stop()
        XCTAssertTrue(smoother.isIdle)
        XCTAssertEqual(smoother.step(elapsed: 1).vertical, 0)
    }
}
