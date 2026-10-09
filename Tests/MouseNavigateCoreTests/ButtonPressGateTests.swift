import XCTest
@testable import MouseNavigateCore

final class ButtonPressGateTests: XCTestCase {
    private let holdOnly = ButtonPressGate.Capabilities(hasHold: true, hasDoubleClick: false)
    private let doubleOnly = ButtonPressGate.Capabilities(hasHold: false, hasDoubleClick: true)
    private let both = ButtonPressGate.Capabilities(hasHold: true, hasDoubleClick: true)
    private let dragOnly = ButtonPressGate.Capabilities(hasHold: false, hasDoubleClick: false, hasDrag: true)
    private let holdAndDrag = ButtonPressGate.Capabilities(hasHold: true, hasDoubleClick: false, hasDrag: true)

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
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, fire: .press(.click), cancelTimer: true))
        XCTAssertEqual(gate.phase, .idle)
    }

    func testHoldFiresWhileStillDownAndSwallowsTheRelease() {
        _ = gate.buttonDown(capabilities: holdOnly)
        XCTAssertEqual(fire(), .init(consume: true, fire: .press(.hold)))
        XCTAssertEqual(gate.phase, .held)
        XCTAssertEqual(gate.buttonUp(), .consume)
        XCTAssertEqual(gate.phase, .idle)
    }

    // MARK: - Drag

    func testADragFiresWhileHeldBackAndSwallowsTheRelease() {
        XCTAssertEqual(gate.buttonDown(capabilities: dragOnly), .consume)
        XCTAssertEqual(gate.dragFired(.up), .init(consume: true, fire: .drag(.up), cancelTimer: true))
        XCTAssertEqual(gate.phase, .dragged)
        XCTAssertEqual(gate.buttonUp(), .consume)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testAQuickPressOnADragButtonIsAClickOnRelease() {
        _ = gate.buttonDown(capabilities: dragOnly)
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, fire: .press(.click), cancelTimer: true))
    }

    func testADragBeforeTheHoldTimerOutdatesIt() {
        _ = gate.buttonDown(capabilities: holdAndDrag)
        let holdTimer = gate.timerGeneration
        XCTAssertEqual(gate.dragFired(.left), .init(consume: true, fire: .drag(.left), cancelTimer: true))
        XCTAssertEqual(gate.timerFired(generation: holdTimer), .consume)
        XCTAssertEqual(gate.phase, .dragged)
    }

    func testAfterTheHoldHasFiredADragMeansNothing() {
        _ = gate.buttonDown(capabilities: holdAndDrag)
        XCTAssertEqual(fire(), .init(consume: true, fire: .press(.hold)))
        XCTAssertEqual(gate.dragFired(.down), .consume)
        XCTAssertEqual(gate.phase, .held)
    }

    func testADragOnTheSecondPressOfADoubleClickMeansNothing() {
        let capabilities = ButtonPressGate.Capabilities(hasHold: false, hasDoubleClick: true, hasDrag: true)
        _ = gate.buttonDown(capabilities: capabilities)
        _ = gate.buttonUp()
        _ = gate.buttonDown(capabilities: capabilities)
        XCTAssertEqual(gate.phase, .secondPress)
        XCTAssertEqual(gate.dragFired(.right), .consume)
        XCTAssertEqual(gate.phase, .secondPress)
    }

    func testADragWithoutTheCapabilityMeansNothing() {
        _ = gate.buttonDown(capabilities: holdOnly)
        XCTAssertEqual(gate.dragFired(.up), .consume)
        XCTAssertEqual(gate.phase, .pressed)
    }

    func testResetForgetsADrag() {
        _ = gate.buttonDown(capabilities: dragOnly)
        _ = gate.dragFired(.up)
        gate.reset()
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertEqual(gate.buttonUp(), .pass)
    }

    // MARK: - Double-click

    func testSinglePressWaitsOutTheWindowThenClicks() {
        XCTAssertEqual(gate.buttonDown(capabilities: doubleOnly), .consume)
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, armTimer: 0.3))
        XCTAssertEqual(gate.phase, .awaitingSecondPress)
        XCTAssertEqual(fire(), .init(consume: true, fire: .press(.click)))
        XCTAssertEqual(gate.phase, .idle)
    }

    func testSecondPressInsideTheWindowIsADoubleClick() {
        _ = gate.buttonDown(capabilities: doubleOnly)
        _ = gate.buttonUp()
        XCTAssertEqual(gate.buttonDown(capabilities: doubleOnly), .init(consume: true, fire: .press(.doubleClick), cancelTimer: true))
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
        XCTAssertEqual(fire(), .init(consume: true, fire: .press(.hold)))
        XCTAssertEqual(gate.buttonUp(), .consume)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testQuickPressWithBothStillWaitsForASecondPress() {
        _ = gate.buttonDown(capabilities: both)
        XCTAssertEqual(gate.buttonUp(), .init(consume: true, armTimer: 0.3))
        XCTAssertEqual(fire(), .init(consume: true, fire: .press(.click)))
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
            .init(consume: true, fire: .press(.doubleClick), cancelTimer: true)
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
