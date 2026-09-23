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

    private func down(
        _ keyCode: UInt16,
        modifier: Bool = false,
        isRepeat: Bool = false,
        at time: TimeInterval = 0,
        window: TimeInterval = 0.4
    ) -> ActivationGate.Outcome {
        gate.keyDown(
            keyCode: keyCode,
            activationKey: activate,
            hasModifier: modifier,
            isRepeat: isRepeat,
            at: time,
            retypeWindow: window
        )
    }

    private func up(_ keyCode: UInt16, at time: TimeInterval = 0) -> ActivationGate.Outcome {
        gate.keyUp(keyCode: keyCode, activationKey: activate, at: time)
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
        for index in 0..<5 {
            let time = Double(index)
            XCTAssertEqual(down(activate, at: time), .armHold)
            XCTAssertEqual(down(s, at: time), .replayThenPass)
            XCTAssertEqual(up(s, at: time), .pass)
            XCTAssertEqual(up(activate, at: time), .pass)
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

    // MARK: - Typing the letter repeatedly

    func testDoubleTapThenHoldTypesTheLetterRepeatedly() {
        XCTAssertEqual(down(activate, at: 0), .armHold)
        XCTAssertEqual(up(activate, at: 0.08), .replayThenConsume)

        // Pressed again inside the window, so the key is handed over and the system
        // autorepeats it instead of cursor mode taking the hold.
        XCTAssertEqual(down(activate, at: 0.2), .pass)
        XCTAssertEqual(gate.phase, .typing)
        XCTAssertEqual(down(activate, isRepeat: true, at: 0.7), .pass)
        XCTAssertEqual(down(activate, isRepeat: true, at: 0.75), .pass)
        XCTAssertFalse(gate.isEngaged)

        XCTAssertEqual(up(activate, at: 2), .pass)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testTypeThroughNeverEngages() {
        _ = down(activate, at: 0)
        _ = up(activate, at: 0.08)
        _ = down(activate, at: 0.2)

        // No hold timer is armed for it, and a stale one must not engage either.
        XCTAssertFalse(gate.holdElapsed())
        XCTAssertEqual(gate.phase, .typing)
        XCTAssertFalse(gate.isEngaged)
    }

    func testTypeThroughChainsSoTheKeyCanBeHeldAgain() {
        _ = down(activate, at: 0)
        _ = up(activate, at: 0.08)
        _ = down(activate, at: 0.2)

        XCTAssertEqual(up(activate, at: 0.9), .pass)
        // Letting go after a spray still counts as having typed the letter.
        XCTAssertEqual(down(activate, at: 1.0), .pass)
        XCTAssertEqual(gate.phase, .typing)
    }

    func testPressingAgainAfterTheWindowStillEngages() {
        _ = down(activate, at: 0)
        _ = up(activate, at: 0.08)

        XCTAssertEqual(down(activate, at: 1.0), .armHold)
        XCTAssertTrue(gate.holdElapsed())
        XCTAssertTrue(gate.isEngaged)
    }

    func testOtherKeysKeepFlowingDuringTypeThrough() {
        _ = down(activate, at: 0)
        _ = up(activate, at: 0.08)
        _ = down(activate, at: 0.2)

        XCTAssertEqual(down(s, at: 0.3), .pass)
        XCTAssertEqual(up(s, at: 0.4), .pass)
        // Reaching for a shortcut mid-spray must not disturb it either.
        XCTAssertEqual(gate.modifierJoined(), .pass)
        XCTAssertEqual(gate.phase, .typing)
    }

    func testARollAlsoArmsTypeThrough() {
        // "as" typed fast still put an "a" on screen, so holding A next means more a's.
        _ = down(activate, at: 0)
        _ = down(s, at: 0.05)
        _ = up(s, at: 0.1)
        XCTAssertEqual(up(activate, at: 0.12), .pass)

        XCTAssertEqual(down(activate, at: 0.3), .pass)
        XCTAssertEqual(gate.phase, .typing)
    }

    func testLeavingCursorModeDoesNotArmTypeThrough() {
        _ = down(activate, at: 0)
        _ = gate.holdElapsed()
        XCTAssertEqual(up(activate, at: 1.0), .exitEngaged)

        // No letter was typed, and holding again straight away is how people re-engage.
        XCTAssertEqual(down(activate, at: 1.05), .armHold)
    }

    func testZeroWindowSwitchesTypeThroughOff() {
        XCTAssertEqual(down(activate, at: 0, window: 0), .armHold)
        XCTAssertEqual(up(activate, at: 0.08), .replayThenConsume)

        XCTAssertEqual(down(activate, at: 0.2, window: 0), .armHold)
        XCTAssertEqual(gate.phase, .pending)
    }

    func testResetClearsTheTypeThroughWindow() {
        _ = down(activate, at: 0)
        _ = up(activate, at: 0.08)
        // A sleep or a lost tap between the two presses must not leave the window armed.
        gate.reset()

        XCTAssertEqual(down(activate, at: 0.2), .armHold)
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
