import XCTest
@testable import MouseNavigateCore

/// The activation key is a normal letter, so these tests exist to prove cursor mode
/// never steals it from someone who is just typing.
final class ActivationGateTests: XCTestCase {
    private let activate = KeyCode.a
    private let s = KeyCode.s
    private let l = KeyCode.l

    private var gate = ActivationGate()

    override func setUp() {
        super.setUp()
        gate = ActivationGate()
    }

    private func down(_ keyCode: UInt16, modifier: Bool = false, isRepeat: Bool = false)
        -> ActivationGate.Outcome {
        gate.keyDown(
            keyCode: keyCode,
            activationKey: activate,
            hasModifier: modifier,
            isRepeat: isRepeat
        )
    }

    private func up(_ keyCode: UInt16) -> ActivationGate.Outcome {
        gate.keyUp(keyCode: keyCode, activationKey: activate)
    }

    // MARK: - Typing must survive

    func testTappingTheActivationKeyTypesTheLetter() {
        XCTAssertEqual(down(activate), .armHold)
        // Released before the threshold, so the withheld letter is handed back.
        XCTAssertEqual(up(activate), .replayThenConsume)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testFastRollAbortsAndTypesBothLetters() {
        // "as" typed quickly must never fire a click.
        XCTAssertEqual(down(activate), .armHold)
        XCTAssertEqual(down(s), .replayThenPass)
        XCTAssertFalse(gate.isEngaged)

        // The interrupting key is still down, so the activation key-up just settles state.
        XCTAssertEqual(up(activate), .pass)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testKeysAfterAnAbortKeepFlowingThrough() {
        _ = down(activate)
        _ = down(s)
        // Still mid-word: everything else must pass untouched.
        XCTAssertEqual(down(l), .pass)
        XCTAssertEqual(up(s), .pass)
    }

    func testRepeatedRollsNeverEngage() {
        for _ in 0..<5 {
            XCTAssertEqual(down(activate), .armHold)
            XCTAssertEqual(down(s), .replayThenPass)
            XCTAssertEqual(up(s), .pass)
            XCTAssertEqual(up(activate), .pass)
            XCTAssertFalse(gate.isEngaged)
        }
    }

    func testCommandShortcutPassesStraightThrough() {
        // ⌘A must still select all.
        XCTAssertEqual(down(activate, modifier: true), .pass)
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertEqual(up(activate), .pass)
    }

    func testShiftedActivationKeyTypesACapital() {
        XCTAssertEqual(down(activate, modifier: true), .pass)
        XCTAssertFalse(gate.isEngaged)
    }

    func testModifierJoiningAPendingHoldAborts() {
        XCTAssertEqual(down(activate), .armHold)
        // The user reached for ⌘ after pressing A; that is a shortcut, not cursor mode.
        XCTAssertEqual(gate.modifierJoined(), .replayThenPass)
        XCTAssertEqual(gate.phase, .aborted)
        XCTAssertFalse(gate.isEngaged)
    }

    func testModifierJoinedIsInertOutsideThePendingWindow() {
        XCTAssertEqual(gate.modifierJoined(), .pass)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testAutorepeatWhilePendingDoesNotLeakTheLetter() {
        XCTAssertEqual(down(activate), .armHold)
        // A repeat must stay swallowed, or holding the key would spray the letter.
        XCTAssertEqual(down(activate, isRepeat: true), .consume)
        XCTAssertEqual(gate.phase, .pending)
    }

    func testAutorepeatFromIdleIsIgnored() {
        XCTAssertEqual(down(activate, isRepeat: true), .pass)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testOtherKeysAreUntouchedWhileIdle() {
        XCTAssertEqual(down(s), .pass)
        XCTAssertEqual(up(s), .pass)
        XCTAssertEqual(gate.phase, .idle)
    }

    // MARK: - Engaging

    func testHoldingPastTheThresholdEngages() {
        XCTAssertEqual(down(activate), .armHold)
        XCTAssertTrue(gate.holdElapsed())
        XCTAssertTrue(gate.isEngaged)
        XCTAssertEqual(gate.phase, .engaged)
    }

    func testHoldElapsingAfterAnAbortDoesNotEngage() {
        // The timer can still fire after the roll already stood the gate down.
        _ = down(activate)
        _ = down(s)
        XCTAssertFalse(gate.holdElapsed())
        XCTAssertFalse(gate.isEngaged)
    }

    func testHoldElapsingFromIdleDoesNothing() {
        XCTAssertFalse(gate.holdElapsed())
        XCTAssertEqual(gate.phase, .idle)
    }

    func testEngagedKeysAreHandedToTheCaller() {
        _ = down(activate)
        _ = gate.holdElapsed()
        XCTAssertEqual(down(l), .handleEngaged)
        XCTAssertEqual(up(l), .handleEngaged)
    }

    func testReleasingTheActivationKeyExits() {
        _ = down(activate)
        _ = gate.holdElapsed()
        XCTAssertEqual(up(activate), .exitEngaged)
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.isEngaged)
    }

    func testTypingWorksAgainImmediatelyAfterExiting() {
        _ = down(activate)
        _ = gate.holdElapsed()
        _ = up(activate)

        XCTAssertEqual(down(s), .pass)
        XCTAssertEqual(down(activate), .armHold)
    }

    // MARK: - Lock

    func testLockSurvivesReleasingTheActivationKey() {
        _ = down(activate)
        _ = gate.holdElapsed()

        XCTAssertFalse(gate.toggleLock())
        XCTAssertEqual(gate.phase, .locked)

        // Releasing the key no longer ends the mode, and must not type the letter.
        XCTAssertEqual(up(activate), .consume)
        XCTAssertTrue(gate.isEngaged)
    }

    func testUnlockingEndsTheMode() {
        _ = down(activate)
        _ = gate.holdElapsed()
        _ = gate.toggleLock()

        XCTAssertTrue(gate.toggleLock())
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.isEngaged)
    }

    func testLockIsInertWhenNotEngaged() {
        XCTAssertFalse(gate.toggleLock())
        XCTAssertEqual(gate.phase, .idle)
    }

    // MARK: - External toggle and teardown

    func testMouseButtonTogglesTheModeOnAndOff() {
        XCTAssertFalse(gate.toggleExternally())
        XCTAssertEqual(gate.phase, .locked)

        XCTAssertTrue(gate.toggleExternally())
        XCTAssertEqual(gate.phase, .idle)
    }

    func testResetFromEveryPhaseReturnsToIdle() {
        _ = down(activate)
        gate.reset()
        XCTAssertEqual(gate.phase, .idle)

        _ = down(activate)
        _ = gate.holdElapsed()
        gate.reset()
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.isEngaged)
    }

    func testTypingIsUnaffectedAfterAForcedReset() {
        // Mirrors a lost key-up: the tap went deaf and the caller tore everything down.
        _ = down(activate)
        _ = gate.holdElapsed()
        gate.reset()

        XCTAssertEqual(down(s), .pass)
        XCTAssertEqual(down(activate), .armHold)
        XCTAssertEqual(up(activate), .replayThenConsume)
    }
}
