import XCTest
@testable import MouseNavigateCore

/// A press and its release always travel together, and a press nobody handled is never lost.
final class ButtonPressTrackerTests: XCTestCase {
    private let clickOnly = ButtonPressTracker.Capabilities(hasHold: false, hasDoubleClick: false)
    private let holdOnly = ButtonPressTracker.Capabilities(hasHold: true, hasDoubleClick: false)
    private let doubleOnly = ButtonPressTracker.Capabilities(hasHold: false, hasDoubleClick: true)
    private let origin = Vector2(x: 300, y: 200)

    private var tracker = ButtonPressTracker(holdDelay: 0.35, doubleClickWindow: 0.3)
    private var performed: [ButtonPress] = []

    override func setUp() {
        super.setUp()
        tracker = ButtonPressTracker(holdDelay: 0.35, doubleClickWindow: 0.3)
        performed = []
    }

    private func handled(_ press: ButtonPress) -> Bool {
        performed.append(press)
        return true
    }

    private func unhandled(_ press: ButtonPress) -> Bool {
        performed.append(press)
        return false
    }

    private func fire(_ button: Int, perform: (ButtonPress) -> Bool) -> ButtonPressTracker.Decision {
        tracker.timerFired(button, generation: tracker.timerGeneration(for: button) ?? 0, perform: perform)
    }

    // MARK: - Click only

    func testAHandledClickActsOnThePressAndSwallowsTheRelease() {
        XCTAssertEqual(tracker.buttonDown(3, capabilities: clickOnly, location: origin, perform: handled), .consume)
        XCTAssertEqual(performed, [.click])
        XCTAssertEqual(tracker.buttonUp(3, perform: handled), .consume)
        XCTAssertEqual(performed, [.click])
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
        XCTAssertEqual(performed, [.hold])
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
        XCTAssertEqual(performed, [.click])
    }

    func testAnUnhandledHoldIsReplayedAsAClick() {
        _ = tracker.buttonDown(5, capabilities: holdOnly, location: origin, perform: unhandled)
        XCTAssertEqual(
            fire(5, perform: unhandled),
            .init(consume: true, replay: .init(clicks: 1, location: origin))
        )
        XCTAssertEqual(performed, [.hold])
        XCTAssertEqual(tracker.buttonUp(5, perform: unhandled), .consume)
    }

    func testAnUnhandledDoubleClickIsReplayedAsTwoClicks() {
        _ = tracker.buttonDown(5, capabilities: doubleOnly, location: origin, perform: unhandled)
        _ = tracker.buttonUp(5, perform: unhandled)
        XCTAssertEqual(
            tracker.buttonDown(5, capabilities: doubleOnly, location: Vector2(x: 301, y: 201), perform: unhandled),
            .init(consume: true, cancelTimer: true, replay: .init(clicks: 2, location: Vector2(x: 301, y: 201)))
        )
        XCTAssertEqual(performed, [.doubleClick])
        XCTAssertEqual(tracker.buttonUp(5, perform: unhandled), .consume)
    }

    func testAHandledPressReplaysNothing() {
        _ = tracker.buttonDown(5, capabilities: doubleOnly, location: origin, perform: handled)
        XCTAssertEqual(tracker.buttonUp(5, perform: handled), .init(consume: true, armTimer: 0.3))
        XCTAssertEqual(fire(5, perform: handled), .consume)
        XCTAssertEqual(performed, [.click])
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
        XCTAssertEqual(performed, [.click])
    }
}
