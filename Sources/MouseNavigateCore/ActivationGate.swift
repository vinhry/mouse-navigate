import Foundation

/// Decides whether a key event belongs to cursor mode or to whoever is typing.
///
/// The activation key is an ordinary letter, so it can never simply be swallowed. This
/// gate withholds it just long enough to tell the two cases apart: if the key is still
/// down when the hold threshold expires, cursor mode engages; anything else — an early
/// release, another key arriving mid-roll, a modifier joining in — replays the withheld
/// letter and stands down.
///
/// Holding the key is therefore spoken for, which would otherwise leave it as the one
/// letter on the keyboard that cannot autorepeat. Pressing it again just after it was
/// typed is the way back in: that press is handed straight over, so the system repeats
/// the letter exactly as it would for any other key.
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
        /// Pressed again moments after being typed, so it is deliberately being typed:
        /// passed through and left to the system to autorepeat.
        case typing
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

    /// What engaging from a mouse button did.
    public enum ExternalToggle: Equatable {
        /// Cursor mode was on and is now off.
        case ended
        /// Cursor mode is now latched on.
        case engaged
        /// Latched on, once the caller has replayed the activation letter that was being
        /// withheld: it had been pressed moments before, so it was typed after all.
        case engagedAfterReplay
    }

    public private(set) var phase: Phase = .idle

    /// When the activation letter was last handed to whoever is typing.
    private var lastTypedAt: TimeInterval?
    /// The activation key is down and the app saw it go down, so it gets the release too.
    private var passesActivationRelease = false

    public init() {}

    public var isEngaged: Bool {
        phase == .engaged || phase == .locked
    }

    // MARK: - Input

    /// - Parameters:
    ///   - time: A monotonic clock reading for this event.
    ///   - retypeWindow: How soon after the letter was typed a fresh press means the user
    ///     wants to type it again rather than engage. Zero switches that off.
    public mutating func keyDown(
        keyCode: UInt16,
        activationKey: UInt16,
        hasModifier: Bool,
        isRepeat: Bool,
        at time: TimeInterval,
        retypeWindow: TimeInterval
    ) -> Outcome {
        switch phase {
        case .idle:
            guard keyCode == activationKey, !isRepeat else { return .pass }
            // A modifier means this is a shortcut such as ⌘A, or a capital letter.
            // Leaving those alone is what keeps existing shortcuts working.
            guard !hasModifier else { return .pass }
            // Pressed again right after it was typed: the letter is wanted, held down.
            // Withholding it now is what would stop it repeating, so hand it over.
            if isRetype(at: time, within: retypeWindow) {
                phase = .typing
                return .pass
            }
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

        case .typing:
            // The autorepeats of the letter, and anything typed alongside it.
            return .pass

        case .engaged, .locked:
            return .handleEngaged
        }
    }

    public mutating func keyUp(
        keyCode: UInt16,
        activationKey: UInt16,
        at time: TimeInterval
    ) -> Outcome {
        switch phase {
        case .idle:
            return .pass

        case .pending:
            guard keyCode == activationKey else { return .pass }
            // Released before the threshold: it was a plain keystroke after all.
            phase = .idle
            lastTypedAt = time
            return .replayThenConsume

        case .aborted:
            if keyCode == activationKey {
                phase = .idle
                lastTypedAt = time
            }
            return .pass

        case .typing:
            guard keyCode == activationKey else { return .pass }
            phase = .idle
            lastTypedAt = time
            return .pass

        case .engaged:
            guard keyCode == activationKey else { return .handleEngaged }
            // No letter was typed, and holding the key again straight away is how people
            // re-engage, so leaving the retype window unarmed is the point.
            phase = .idle
            return .exitEngaged

        case .locked:
            // The activation key is no longer what holds the mode open.
            guard keyCode == activationKey else { return .handleEngaged }
            if passesActivationRelease {
                // The press reached the app, so withholding the release would leave the
                // key stuck down there.
                passesActivationRelease = false
                return .pass
            }
            return .consume
        }
    }

    /// A modifier joined a hold in progress, so this is a shortcut rather than cursor mode.
    public mutating func modifierJoined() -> Outcome {
        guard phase == .pending else { return .pass }
        phase = .aborted
        return .replayThenPass
    }

    private func isRetype(at time: TimeInterval, within window: TimeInterval) -> Bool {
        guard window > 0, let lastTypedAt else { return false }
        return time >= lastTypedAt && time - lastTypedAt <= window
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

    /// Engage from something other than the activation key, such as a mouse button, or end
    /// the mode if it is on. Whatever the activation key was in the middle of is settled
    /// first, so the app is never left with half a keystroke.
    public mutating func toggleExternally() -> ExternalToggle {
        if isEngaged {
            phase = .idle
            passesActivationRelease = false
            return .ended
        }

        let previous = phase
        phase = .locked
        switch previous {
        case .pending:
            return .engagedAfterReplay
        case .typing, .aborted:
            // The app has the press already, so it gets the release as well.
            passesActivationRelease = true
            return .engaged
        case .idle, .engaged, .locked:
            return .engaged
        }
    }

    /// Unconditional teardown for pause, sleep, tap loss and quit.
    public mutating func reset() {
        phase = .idle
        passesActivationRelease = false
        // A window left armed across a teardown would spray the letter on the next hold.
        lastTypedAt = nil
    }
}
