import XCTest
@testable import MouseNavigateCore

final class ScrollWheelTests: XCTestCase {
    private let notch = ScrollDelta(lines: (1, 0), fixedLines: (1, 0), points: (10, 0))

    // MARK: - Settings

    func testStandardSettingsLeaveTheWheelAlone() {
        XCTAssertFalse(ScrollSettings.standard.isActive)
        XCTAssertTrue(ScrollSettings(reverse: .both, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false).isActive)
        XCTAssertTrue(ScrollSettings(reverse: .off, verticalSpeed: 2, horizontalSpeed: 2, isSmooth: false).isActive)
        XCTAssertTrue(ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: true).isActive)
    }

    func testSpeedIsClamped() {
        let fast = ScrollSettings(verticalSpeed: 100, horizontalSpeed: 100)
        XCTAssertEqual(fast.verticalSpeed, 4)
        XCTAssertEqual(fast.horizontalSpeed, 4)
        let slow = ScrollSettings(verticalSpeed: 0, horizontalSpeed: 0)
        XCTAssertEqual(slow.verticalSpeed, 0.5)
        XCTAssertEqual(slow.horizontalSpeed, 0.5)
    }

    // MARK: - Per axis

    func testEachAxisReversesOnItsOwn() {
        let delta = ScrollDelta(lines: (2, -1), fixedLines: (2, -1), points: (20, -10))
        XCTAssertEqual(
            ScrollTransform.apply(delta, settings: ScrollSettings(reverse: .vertical)),
            ScrollDelta(lines: (-2, -1), fixedLines: (-2, -1), points: (-20, -10))
        )
        XCTAssertEqual(
            ScrollTransform.apply(delta, settings: ScrollSettings(reverse: .horizontal)),
            ScrollDelta(lines: (2, 1), fixedLines: (2, 1), points: (20, 10))
        )
        XCTAssertTrue(ScrollReverse.both.reversesVertical && ScrollReverse.both.reversesHorizontal)
        XCTAssertFalse(ScrollReverse.off.reversesVertical || ScrollReverse.off.reversesHorizontal)
    }

    func testEachAxisHasItsOwnSpeed() {
        let delta = ScrollDelta(lines: (1, 1), fixedLines: (1, 1), points: (10, 10))
        let result = ScrollTransform.apply(delta, settings: ScrollSettings(verticalSpeed: 3, horizontalSpeed: 0.5))
        XCTAssertEqual(result, ScrollDelta(lines: (3, 1), fixedLines: (3, 0.5), points: (30, 5)))
    }

    func testReverseComesBeforeTheSwap() {
        // The wheel was turned vertically; that axis is the reversed one, whichever way
        // Shift then sends it.
        let settings = ScrollSettings(reverse: .vertical, verticalSpeed: 2, shiftSwapsAxes: true)
        let result = ScrollTransform.apply(notch, settings: settings, modifiers: [.shift])
        XCTAssertEqual(result.delta, ScrollDelta(lines: (0, -2), fixedLines: (0, -2), points: (0, -20)))
    }

    // MARK: - Overrides

    func testAnOverrideChangesOnlyWhatItSets() {
        let base = ScrollSettings(reverse: .both, verticalSpeed: 2, horizontalSpeed: 3, isSmooth: true)
        let override = ScrollOverride(reverse: .vertical, horizontalSpeed: 1)
        XCTAssertEqual(
            override.applied(to: base),
            ScrollSettings(reverse: .vertical, verticalSpeed: 2, horizontalSpeed: 1, isSmooth: true)
        )
        XCTAssertEqual(ScrollOverride.none.applied(to: base), base)
        XCTAssertTrue(ScrollOverride.none.isEmpty)
        XCTAssertFalse(override.isEmpty)
        XCTAssertEqual(ScrollOverride(settings: base).applied(to: .standard), base)
    }

    func testOverridePropertyListRoundTripsAndTolerates() {
        let override = ScrollOverride(reverse: .horizontal, verticalSpeed: 2, commandIsFast: true)
        let list = override.propertyList
        XCTAssertEqual(Set(list.keys), ["reverse", "verticalSpeed", "commandFast"])
        XCTAssertEqual(ScrollOverride(propertyList: list), override)

        XCTAssertEqual(ScrollOverride(propertyList: nil), .none)
        XCTAssertEqual(ScrollOverride(propertyList: "junk"), .none)
        XCTAssertEqual(
            ScrollOverride(propertyList: ["reverse": "sideways", "smooth": "yes", "verticalSpeed": 9, "optionPrecise": true] as [String: Any]),
            ScrollOverride(verticalSpeed: 4, optionIsPrecise: true),
            "unreadable fields are unset, a speed is clamped"
        )
    }

    func testResolverLetsTheAppWinThenTheMouse() {
        let global = ScrollSettings(verticalSpeed: 2)
        let mouse = ScrollOverride(reverse: .both, isSmooth: true)
        let app = ScrollOverride(reverse: .off)
        XCTAssertEqual(
            ScrollResolver.resolve(global: global, profile: mouse, app: app),
            ScrollSettings(reverse: .off, verticalSpeed: 2, isSmooth: true)
        )
        XCTAssertEqual(
            ScrollResolver.resolve(global: global, profile: mouse, app: nil),
            ScrollSettings(reverse: .both, verticalSpeed: 2, isSmooth: true)
        )
        XCTAssertEqual(ScrollResolver.resolve(global: global, profile: nil, app: nil), global)
    }

    // MARK: - Transform

    func testReverseFlipsEveryForm() {
        let result = ScrollTransform.apply(
            ScrollDelta(lines: (2, -1), fixedLines: (2, -1), points: (20, -10)),
            settings: ScrollSettings(reverse: .both, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false)
        )
        XCTAssertEqual(result, ScrollDelta(lines: (-2, 1), fixedLines: (-2, 1), points: (-20, 10)))
    }

    func testSpeedScalesEveryForm() {
        let result = ScrollTransform.apply(notch, settings: ScrollSettings(reverse: .off, verticalSpeed: 3, horizontalSpeed: 3, isSmooth: false))
        XCTAssertEqual(result, ScrollDelta(lines: (3, 0), fixedLines: (3, 0), points: (30, 0)))
    }

    func testSlowingDownNeverTurnsANotchIntoNothing() {
        let result = ScrollTransform.apply(notch, settings: ScrollSettings(reverse: .both, verticalSpeed: 0.5, horizontalSpeed: 0.5, isSmooth: false))
        XCTAssertEqual(result.lines.vertical, -1)
        XCTAssertEqual(result.lines.horizontal, 0)
        XCTAssertEqual(result.points.vertical, -5)
    }

    // MARK: - Modifiers

    private let twoAxes = ScrollDelta(lines: (2, -1), fixedLines: (2, -1), points: (20, -10))

    func testShiftSwapsEveryFormWhenAsked() {
        let settings = ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, shiftSwapsAxes: true)
        let result = ScrollTransform.apply(twoAxes, settings: settings, modifiers: [.shift])
        XCTAssertEqual(result.delta, ScrollDelta(lines: (-1, 2), fixedLines: (-1, 2), points: (-10, 20)))
        XCTAssertEqual(result.consumedModifiers, [.shift])
    }

    func testOptionScrollsPrecisely() {
        let settings = ScrollSettings(reverse: .off, verticalSpeed: 2, horizontalSpeed: 2, isSmooth: false, optionIsPrecise: true)
        let result = ScrollTransform.apply(twoAxes, settings: settings, modifiers: [.option])
        XCTAssertEqual(result.delta, ScrollDelta(lines: (1, -1), fixedLines: (1, -0.5), points: (10, -5)))
        XCTAssertEqual(result.consumedModifiers, [.option])
    }

    func testCommandScrollsFast() {
        let settings = ScrollSettings(reverse: .both, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, commandIsFast: true)
        let result = ScrollTransform.apply(notch, settings: settings, modifiers: [.command])
        XCTAssertEqual(result.delta, ScrollDelta(lines: (-3, 0), fixedLines: (-3, 0), points: (-30, 0)))
        XCTAssertEqual(result.consumedModifiers, [.command])
    }

    func testOptionWinsOverCommand() {
        let settings = ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, optionIsPrecise: true, commandIsFast: true)
        let result = ScrollTransform.apply(notch, settings: settings, modifiers: [.option, .command])
        XCTAssertEqual(result.delta.points.vertical, 2.5)
        XCTAssertEqual(result.consumedModifiers, [.option], "⌘ stays on the event for the app")
    }

    func testSwapComesAfterScaling() {
        let settings = ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, shiftSwapsAxes: true, commandIsFast: true)
        let result = ScrollTransform.apply(notch, settings: settings, modifiers: [.shift, .command])
        XCTAssertEqual(result.delta, ScrollDelta(lines: (0, 3), fixedLines: (0, 3), points: (0, 30)))
        XCTAssertEqual(result.consumedModifiers, [.shift, .command])
    }

    func testModifiersAreIgnoredWhileTheirOptionsAreOff() {
        let result = ScrollTransform.apply(twoAxes, settings: .standard, modifiers: [.shift, .option, .command])
        XCTAssertEqual(result.delta, twoAxes)
        XCTAssertTrue(result.consumedModifiers.isEmpty)
    }

    func testNoModifiersMeansNoChange() {
        let settings = ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, shiftSwapsAxes: true, optionIsPrecise: true, commandIsFast: true)
        XCTAssertEqual(ScrollTransform.apply(twoAxes, settings: settings, modifiers: []).delta, twoAxes)
        XCTAssertEqual(ScrollTransform.apply(twoAxes, settings: settings), twoAxes)
    }

    func testAWheelOptionAloneMakesTheSettingsActive() {
        XCTAssertTrue(ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, shiftSwapsAxes: true).isActive)
        XCTAssertTrue(ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, optionIsPrecise: true).isActive)
        XCTAssertTrue(ScrollSettings(reverse: .off, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false, commandIsFast: true).isActive)
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
