import XCTest
@testable import MouseNavigateCore

final class ButtonPressGateTests: XCTestCase {
    private let holdOnly = ButtonPressGate.Capabilities(hasHold: true, hasDoubleClick: false)
    private let doubleOnly = ButtonPressGate.Capabilities(hasHold: false, hasDoubleClick: true)
    private let both = ButtonPressGate.Capabilities(hasHold: true, hasDoubleClick: true)

    private var gate = ButtonPressGate(holdDelay: 0.35, doubleClickWindow: 0.3)

    override func setUp() {
        super.setUp()
        gate = ButtonPressGate(holdDelay: 0.35, doubleClickWindow: 0.3)
    }

    private func fire() -> ButtonPressGate.Response {
        gate.timerFired(generation: gate.timerGeneration)
    }

    // MARK: - Hold

    func testQuickPressWithHoldIsAClickOnRelease() {
        XCTAssertEqual(gate.buttonDown(capabilities: holdOnly), .init(consume: true, armTimer: 0.35))
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, fire: .click, cancelTimer: true))
        XCTAssertEqual(gate.phase, .idle)
    }

    func testHoldFiresWhileStillDownAndSwallowsTheRelease() {
        _ = gate.buttonDown(capabilities: holdOnly)
        XCTAssertEqual(fire(), .init(consume: true, fire: .hold))
        XCTAssertEqual(gate.phase, .held)
        XCTAssertEqual(gate.buttonUp(), .consume)
        XCTAssertEqual(gate.phase, .idle)
    }

    // MARK: - Double-click

    func testSinglePressWaitsOutTheWindowThenClicks() {
        XCTAssertEqual(gate.buttonDown(capabilities: doubleOnly), .consume)
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, armTimer: 0.3))
        XCTAssertEqual(gate.phase, .awaitingSecondPress)
        XCTAssertEqual(fire(), .init(consume: true, fire: .click))
        XCTAssertEqual(gate.phase, .idle)
    }

    func testSecondPressInsideTheWindowIsADoubleClick() {
        _ = gate.buttonDown(capabilities: doubleOnly)
        _ = gate.buttonUp()
        XCTAssertEqual(gate.buttonDown(capabilities: doubleOnly), .init(consume: true, fire: .doubleClick, cancelTimer: true))
        XCTAssertEqual(gate.buttonUp(), .consume)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testTheWindowTimerAfterADoubleClickDoesNothing() {
        _ = gate.buttonDown(capabilities: doubleOnly)
        _ = gate.buttonUp()
        let windowTimer = gate.timerGeneration
        _ = gate.buttonDown(capabilities: doubleOnly)
        XCTAssertEqual(gate.timerFired(generation: windowTimer), .consume)
        XCTAssertEqual(gate.phase, .secondPress)
    }

    // MARK: - Both

    func testHoldWinsOverDoubleClickWhenHeld() {
        _ = gate.buttonDown(capabilities: both)
        XCTAssertEqual(fire(), .init(consume: true, fire: .hold))
        XCTAssertEqual(gate.buttonUp(), .consume)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testQuickPressWithBothStillWaitsForASecondPress() {
        _ = gate.buttonDown(capabilities: both)
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, armTimer: 0.3))
        XCTAssertEqual(fire(), .init(consume: true, fire: .click))
    }

    func testAStaleHoldTimerCannotFireAfterRelease() {
        _ = gate.buttonDown(capabilities: both)
        let holdTimer = gate.timerGeneration
        _ = gate.buttonUp()
        XCTAssertEqual(gate.timerFired(generation: holdTimer), .consume)
        XCTAssertEqual(gate.phase, .awaitingSecondPress)
    }

    // MARK: - Edges

    func testReleaseWithNothingPendingPassesThrough() {
        XCTAssertEqual(gate.buttonUp(), .pass)
    }

    func testCapabilitiesAreFixedForTheWholeGesture() {
        _ = gate.buttonDown(capabilities: doubleOnly)
        _ = gate.buttonUp()
        // The bindings changing mid-gesture must not strand it.
        XCTAssertEqual(
            gate.buttonDown(capabilities: .init(hasHold: false, hasDoubleClick: false)),
            .init(consume: true, fire: .doubleClick, cancelTimer: true)
        )
    }

    func testResetDropsAPendingClickAndOutdatesItsTimer() {
        _ = gate.buttonDown(capabilities: doubleOnly)
        _ = gate.buttonUp()
        let windowTimer = gate.timerGeneration
        gate.reset()
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertEqual(gate.timerFired(generation: windowTimer), .consume)
        XCTAssertEqual(gate.buttonUp(), .pass)
    }

    // MARK: - Triggers

    func testEachPressHasItsOwnKeyAndClickKeepsTheOldOne() {
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4).storageKey, "button.mxMaster4.5")
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4, .hold).storageKey, "buttonHold.mxMaster4.5")
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4, .doubleClick).storageKey, "buttonDouble.mxMaster4.5")
    }

    func testHoldAndDoubleClickStartUnbound() {
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4, .hold).defaultBinding, .disabled)
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4, .doubleClick).defaultBinding, .disabled)
    }
}
