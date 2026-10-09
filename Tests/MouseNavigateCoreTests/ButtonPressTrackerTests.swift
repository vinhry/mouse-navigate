import XCTest
@testable import MouseNavigateCore

/// A press and its release always travel together, and a press nobody handled is never lost.
final class ButtonPressTrackerTests: XCTestCase {
    private let clickOnly = ButtonPressTracker.Capabilities(hasHold: false, hasDoubleClick: false)
    private let holdOnly = ButtonPressTracker.Capabilities(hasHold: true, hasDoubleClick: false)
    private let doubleOnly = ButtonPressTracker.Capabilities(hasHold: false, hasDoubleClick: true)
    private let dragOnly = ButtonPressTracker.Capabilities(hasHold: false, hasDoubleClick: false, hasDrag: true)
    private let holdAndDrag = ButtonPressTracker.Capabilities(hasHold: true, hasDoubleClick: false, hasDrag: true)
    private let origin = Vector2(x: 300, y: 200)

    private var tracker = ButtonPressTracker(holdDelay: 0.35, doubleClickWindow: 0.3)
    private var performed: [ButtonInput] = []

    override func setUp() {
        super.setUp()
        tracker = ButtonPressTracker(holdDelay: 0.35, doubleClickWindow: 0.3)
        performed = []
    }

    private func handled(_ input: ButtonInput) -> Bool {
        performed.append(input)
        return true
    }

    private func unhandled(_ input: ButtonInput) -> Bool {
        performed.append(input)
        return false
    }

    private func fire(_ button: Int, perform: (ButtonInput) -> Bool) -> ButtonPressTracker.Decision {
        tracker.timerFired(button, generation: tracker.timerGeneration(for: button) ?? 0, perform: perform)
    }

    // MARK: - Drag

    func testADragFiresOnceThePointerHasGoneFarEnough() {
        XCTAssertEqual(tracker.buttonDown(5, capabilities: dragOnly, location: origin, perform: handled), .consume)
        XCTAssertEqual(tracker.buttonDragged(5, by: Vector2(x: 0, y: -10), perform: handled), .consume)
        XCTAssertEqual(performed, [])
        XCTAssertEqual(
            tracker.buttonDragged(5, by: Vector2(x: 0, y: -25), perform: handled),
            .init(consume: true, cancelTimer: true)
        )
        XCTAssertEqual(performed, [.drag(.up)])
        XCTAssertEqual(tracker.buttonDragged(5, by: Vector2(x: 0, y: -25), perform: handled), .consume)
        XCTAssertEqual(performed, [.drag(.up)], "once per press")
        XCTAssertEqual(tracker.buttonUp(5, perform: handled), .consume)
        XCTAssertEqual(performed, [.drag(.up)])
        XCTAssertEqual(tracker.phase(of: 5), .idle)
    }

    func testADragBeforeTheHoldTimerLeavesTheTimerStale() {
        let decision = tracker.buttonDown(5, capabilities: holdAndDrag, location: origin, perform: handled)
        XCTAssertEqual(decision.armTimer, 0.35)
        let holdTimer = tracker.timerGeneration(for: 5)!
        let drag = tracker.buttonDragged(5, by: Vector2(x: 40, y: 0), perform: handled)
        XCTAssertTrue(drag.cancelTimer)
        XCTAssertEqual(performed, [.drag(.right)])
        XCTAssertEqual(tracker.timerFired(5, generation: holdTimer, perform: handled), .consume)
        XCTAssertEqual(performed, [.drag(.right)])
    }

    func testOnceTheHoldHasFiredDragsAreSwallowedButIgnored() {
        _ = tracker.buttonDown(5, capabilities: holdAndDrag, location: origin, perform: handled)
        _ = fire(5, perform: handled)
        XCTAssertEqual(performed, [.press(.hold)])
        XCTAssertEqual(tracker.buttonDragged(5, by: Vector2(x: 0, y: 60), perform: handled), .consume)
        XCTAssertEqual(performed, [.press(.hold)])
    }

    func testAClickOnlyButtonPassesItsDrags() {
        _ = tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: unhandled)
        XCTAssertEqual(tracker.buttonDragged(3, by: Vector2(x: 0, y: 60), perform: handled), .pass)
        XCTAssertEqual(performed, [.press(.click)])
    }

    func testAHoldOnlyButtonPassesItsDragsToo() {
        _ = tracker.buttonDown(4, capabilities: holdOnly, location: origin, perform: handled)
        XCTAssertEqual(tracker.buttonDragged(4, by: Vector2(x: 0, y: 60), perform: handled), .pass)
        XCTAssertEqual(performed, [])
    }

    func testADragNobodyHandledIsNotReplayed() {
        _ = tracker.buttonDown(5, capabilities: dragOnly, location: origin, perform: unhandled)
        let decision = tracker.buttonDragged(5, by: Vector2(x: -40, y: 0), perform: unhandled)
        XCTAssertEqual(performed, [.drag(.left)])
        XCTAssertNil(decision.replay)
        XCTAssertEqual(tracker.buttonUp(5, perform: unhandled), .consume)
    }

    func testAQuickClickOnADragButtonIsReplayedOnReleaseWhenUnhandled() {
        _ = tracker.buttonDown(5, capabilities: dragOnly, location: origin, perform: unhandled)
        let release = tracker.buttonUp(5, perform: unhandled)
        XCTAssertEqual(performed, [.press(.click)])
        XCTAssertEqual(release.replay, .init(clicks: 1, location: origin))
    }

    func testAResetMidDragStillSwallowsTheRelease() {
        _ = tracker.buttonDown(5, capabilities: dragOnly, location: origin, perform: handled)
        _ = tracker.buttonDragged(5, by: Vector2(x: 0, y: 40), perform: handled)
        tracker.reset()
        XCTAssertEqual(tracker.buttonDragged(5, by: Vector2(x: 0, y: 40), perform: handled), .pass)
        XCTAssertEqual(tracker.buttonUp(5, perform: handled), .consume)
        XCTAssertEqual(performed, [.drag(.down)])
    }

    // MARK: - Click only

    func testAHandledClickActsOnThePressAndSwallowsTheRelease() {
        XCTAssertEqual(tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: handled), .consume)
        XCTAssertEqual(performed, [.press(.click)])
        XCTAssertEqual(tracker.buttonUp(3, perform: handled), .consume)
        XCTAssertEqual(performed, [.press(.click)])
    }

    func testAnUnhandledClickPassesBothPressAndRelease() {
        XCTAssertEqual(tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: unhandled), .pass)
        XCTAssertEqual(tracker.buttonUp(3, perform: unhandled), .pass)
    }

    // MARK: - Releases after a reset

    func testAResetMidPressStillSwallowsTheRelease() {
        _ = tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: handled)
        tracker.reset()
        XCTAssertEqual(tracker.buttonUp(3, perform: handled), .consume)
        XCTAssertEqual(tracker.buttonUp(3, perform: handled), .pass)
    }

    func testAResetDuringAHoldStillSwallowsTheRelease() {
        _ = tracker.buttonDown(4, capabilities: holdOnly, location: origin, perform: handled)
        _ = fire(4, perform: handled)
        XCTAssertEqual(performed, [.press(.hold)])
        tracker.reset()
        XCTAssertEqual(tracker.phase(of: 4), .idle)
        XCTAssertEqual(tracker.buttonUp(4, perform: handled), .consume)
    }

    func testAStaleSwallowDoesNotEatTheNextPressesRelease() {
        _ = tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: handled)
        tracker.reset()
        // The release was lost. The next press is unhandled, so the app gets both halves.
        XCTAssertEqual(tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: unhandled), .pass)
        XCTAssertEqual(tracker.buttonUp(3, perform: unhandled), .pass)
    }

    // MARK: - Replays

    func testAnUnhandledGatedClickIsReplayedWhereItBegan() {
        XCTAssertEqual(
            tracker.buttonDown(5, capabilities: holdOnly, location: origin, perform: unhandled),
            .init(consume: true, armTimer: 0.35)
        )
        let moved = Vector2(x: 900, y: 900)
        _ = moved
        XCTAssertEqual(
            tracker.buttonUp(5, perform: unhandled),
            .init(consume: true, cancelTimer: true, replay: .init(clicks: 1, location: origin))
        )
        XCTAssertEqual(performed, [.press(.click)])
    }

    func testAnUnhandledHoldIsReplayedAsAClick() {
        _ = tracker.buttonDown(5, capabilities: holdOnly, location: origin, perform: unhandled)
        XCTAssertEqual(
            fire(5, perform: unhandled),
            .init(consume: true, replay: .init(clicks: 1, location: origin))
        )
        XCTAssertEqual(performed, [.press(.hold)])
        XCTAssertEqual(tracker.buttonUp(5, perform: unhandled), .consume)
    }

    func testAnUnhandledDoubleClickIsReplayedAsTwoClicks() {
        _ = tracker.buttonDown(5, capabilities: doubleOnly, location: origin, perform: unhandled)
        _ = tracker.buttonUp(5, perform: unhandled)
        XCTAssertEqual(
            tracker.buttonDown(5, capabilities: doubleOnly, location: Vector2(x: 301, y: 201), perform: unhandled),
            .init(consume: true, cancelTimer: true, replay: .init(clicks: 2, location: Vector2(x: 301, y: 201)))
        )
        XCTAssertEqual(performed, [.press(.doubleClick)])
        XCTAssertEqual(tracker.buttonUp(5, perform: unhandled), .consume)
    }

    func testAHandledPressReplaysNothing() {
        _ = tracker.buttonDown(5, capabilities: doubleOnly, location: origin, perform: handled)
        XCTAssertEqual(tracker.buttonUp(5, perform: handled), .init(consume: true, armTimer: 0.3))
        XCTAssertEqual(fire(5, perform: handled), .consume)
        XCTAssertEqual(performed, [.press(.click)])
    }

    // MARK: - Timers

    func testTimerGenerationFollowsTheGate() {
        XCTAssertNil(tracker.timerGeneration(for: 6))
        _ = tracker.buttonDown(6, capabilities: holdOnly, location: origin, perform: handled)
        let generation = tracker.timerGeneration(for: 6)
        XCTAssertNotNil(generation)
        _ = tracker.buttonUp(6, perform: handled)
        // The hold timer is stale once the button came up.
        XCTAssertEqual(tracker.timerFired(6, generation: generation ?? -1, perform: handled), .consume)
        XCTAssertEqual(performed, [.press(.click)])
    }
}
