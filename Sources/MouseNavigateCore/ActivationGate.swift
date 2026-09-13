import Foundation

/// Decides whether a key event belongs to cursor mode or to whoever is typing.
///
/// The activation key is an ordinary letter, so it can never simply be swallowed. This
/// gate withholds it just long enough to tell the two cases apart: if the key is still
/// down when the hold threshold expires, cursor mode engages; anything else — an early
/// release, another key arriving mid-roll, a modifier joining in — replays the withheld
/// letter and stands down.
///
/// Kept free of AppKit so the behaviour that protects normal typing can be tested.
public struct ActivationGate {
    public enum Phase: Equatable {
        /// Not engaged; every key passes through.
        case idle
        /// Activation key is down and withheld, threshold not yet reached.
        case pending
        /// Stood down and already replayed the letter; waiting for the key to come up.
        case aborted
        /// Cursor mode, held open by the activation key.
        case engaged
        /// Cursor mode, latched until explicitly exited.
        case locked
    }

    public enum Outcome: Equatable {
        /// Deliver the event untouched.
        case pass
        /// Swallow the event.
        case consume
        /// Swallow the event and start the hold timer.
        case armHold
        /// Emit the withheld activation key, then deliver this event.
        case replayThenPass
        /// Emit the withheld activation key and swallow this event.
        case replayThenConsume
        /// Cursor mode is on; the caller decides using its own key bindings.
        case handleEngaged
        /// Leave cursor mode and swallow the event.
        case exitEngaged
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public var isEngaged: Bool {
        phase == .engaged || phase == .locked
    }

    // MARK: - Input

    public mutating func keyDown(
        keyCode: UInt16,
        activationKey: UInt16,
        hasModifier: Bool,
        isRepeat: Bool
    ) -> Outcome {
        switch phase {
        case .idle:
            guard keyCode == activationKey, !isRepeat else { return .pass }
            // A modifier means this is a shortcut such as ⌘A, or a capital letter.
            // Leaving those alone is what keeps existing shortcuts working.
            guard !hasModifier else { return .pass }
            phase = .pending
            return .armHold

        case .pending:
            if keyCode == activationKey {
                // Autorepeat of the key we are already withholding.
                return .consume
            }
            // A second key during the hold window means someone is typing a roll
            // like "as" or "ad". Give the letter back and get out of the way.
            phase = .aborted
            return .replayThenPass

        case .aborted:
            return .pass

        case .engaged, .locked:
            return .handleEngaged
        }
    }

    public mutating func keyUp(keyCode: UInt16, activationKey: UInt16) -> Outcome {
        switch phase {
        case .idle:
            return .pass

        case .pending:
            guard keyCode == activationKey else { return .pass }
            // Released before the threshold: it was a plain keystroke after all.
            phase = .idle
            return .replayThenConsume

        case .aborted:
            if keyCode == activationKey {
                phase = .idle
            }
            return .pass

        case .engaged:
            guard keyCode == activationKey else { return .handleEngaged }
            phase = .idle
            return .exitEngaged

        case .locked:
            // The activation key is no longer what holds the mode open.
            guard keyCode == activationKey else { return .handleEngaged }
            return .consume
        }
    }

    /// A modifier joined a hold in progress, so this is a shortcut rather than cursor mode.
    public mutating func modifierJoined() -> Outcome {
        guard phase == .pending else { return .pass }
        phase = .aborted
        return .replayThenPass
    }

    // MARK: - Transitions driven by the caller

    /// The hold threshold expired. Returns true when cursor mode actually engaged.
    public mutating func holdElapsed() -> Bool {
        guard phase == .pending else { return false }
        phase = .engaged
        return true
    }

    /// Latch cursor mode so it survives releasing the activation key.
    /// Returns true when the mode should now end instead.
    public mutating func toggleLock() -> Bool {
        switch phase {
        case .engaged:
            phase = .locked
            return false
        case .locked:
            phase = .idle
            return true
        default:
            return false
        }
    }

    /// Engage from something other than the activation key, such as a mouse button.
    /// Returns true when the mode should end instead.
    public mutating func toggleExternally() -> Bool {
        if isEngaged {
            phase = .idle
            return true
        }
        phase = .locked
        return false
    }

    /// Unconditional teardown for pause, sleep, tap loss and quit.
    public mutating func reset() {
        phase = .idle
    }
}
