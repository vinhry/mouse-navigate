import Foundation

/// Tells a click from a hold from a double-click from a drag on one mouse button.
///
/// Only a button with a hold, double-click or drag binding goes through here. Telling
/// those apart means holding the press back until it is clear which it was, and a button
/// bound only to a click should never pay that delay, so its caller acts on the press
/// straight away.
///
/// The gate keeps no clock. It asks for a timer and is told when that timer fires; each
/// timer carries a generation, so one that fires after it was replaced does nothing.
public struct ButtonPressGate {
    public struct Capabilities: Equatable {
        public var hasHold: Bool
        public var hasDoubleClick: Bool
        public var hasDrag: Bool

        public init(hasHold: Bool, hasDoubleClick: Bool, hasDrag: Bool = false) {
            self.hasHold = hasHold
            self.hasDoubleClick = hasDoubleClick
            self.hasDrag = hasDrag
        }

        public var needsGate: Bool { hasHold || hasDoubleClick || hasDrag }
    }

    public enum Phase: Equatable {
        case idle
        /// Down and held back, waiting for either the release or the hold timer.
        case pressed
        /// Released once; a second press within the window makes it a double-click.
        case awaitingSecondPress
        /// Hold has fired; the release is swallowed.
        case held
        /// Double-click has fired on the second press; its release is swallowed.
        case secondPress
        /// A drag has fired; the release is swallowed.
        case dragged
    }

    /// What the caller does with the event, and what it runs.
    public struct Response: Equatable {
        /// Swallow the event rather than deliver it.
        public var consume: Bool
        /// The press or drag that has now been decided, to be run.
        public var fire: ButtonInput?
        /// Arm the timer for this long, replacing any running one.
        public var armTimer: TimeInterval?
        /// Stop the running timer without starting another.
        public var cancelTimer: Bool

        public init(consume: Bool, fire: ButtonInput? = nil, armTimer: TimeInterval? = nil, cancelTimer: Bool = false) {
            self.consume = consume
            self.fire = fire
            self.armTimer = armTimer
            self.cancelTimer = cancelTimer
        }

        public static let pass = Response(consume: false)
        public static let consume = Response(consume: true)
    }

    public private(set) var phase: Phase = .idle
    /// Identifies the timer most recently asked for.
    public private(set) var timerGeneration = 0

    private var capabilities = Capabilities(hasHold: false, hasDoubleClick: false)
    private let holdDelay: TimeInterval
    private let doubleClickWindow: TimeInterval

    public static let defaultHoldDelay: TimeInterval = 0.35
    public static let defaultDoubleClickWindow: TimeInterval = 0.3

    public init(
        holdDelay: TimeInterval = ButtonPressGate.defaultHoldDelay,
        doubleClickWindow: TimeInterval = ButtonPressGate.defaultDoubleClickWindow
    ) {
        self.holdDelay = holdDelay
        self.doubleClickWindow = doubleClickWindow
    }

    // MARK: - Input

    /// `capabilities` is read on the first press only: what the button can do is settled
    /// for the whole gesture, even if the bindings change halfway through it.
    public mutating func buttonDown(capabilities: Capabilities) -> Response {
        switch phase {
        case .idle:
            self.capabilities = capabilities
            phase = .pressed
            return capabilities.hasHold ? arm(holdDelay) : .consume
        case .awaitingSecondPress:
            phase = .secondPress
            return Response(consume: true, fire: .press(.doubleClick), cancelTimer: true)
        case .pressed, .held, .secondPress, .dragged:
            // A down without its up in between: nothing sensible to add, so keep quiet.
            return .consume
        }
    }

    /// The pointer has gone far enough while the button is held back. Only a press still
    /// waiting can become a drag: once the hold has fired, or on the second press of a
    /// double-click, the movement means nothing. The hold timer is outdated so that it
    /// cannot fire on top.
    public mutating func dragFired(_ direction: DragDirection) -> Response {
        guard phase == .pressed, capabilities.hasDrag else { return .consume }
        phase = .dragged
        timerGeneration += 1
        return Response(consume: true, fire: .drag(direction), cancelTimer: true)
    }

    public mutating func buttonUp() -> Response {
        switch phase {
        case .idle:
            return .pass
        case .pressed:
            if capabilities.hasDoubleClick {
                phase = .awaitingSecondPress
                return arm(doubleClickWindow)
            }
            phase = .idle
            return Response(consume: true, fire: .press(.click), cancelTimer: true)
        case .held, .secondPress, .dragged:
            phase = .idle
            return .consume
        case .awaitingSecondPress:
            return .consume
        }
    }

    public mutating func timerFired(generation: Int) -> Response {
        guard generation == timerGeneration else { return .consume }

        switch phase {
        case .pressed where capabilities.hasHold:
            phase = .held
            return Response(consume: true, fire: .press(.hold))
        case .awaitingSecondPress:
            phase = .idle
            return Response(consume: true, fire: .press(.click))
        default:
            return .consume
        }
    }

    /// Forgets the gesture in progress, for pausing or switching apps mid-press. A click
    /// still waiting on a possible second press is dropped rather than run late.
    public mutating func reset() {
        phase = .idle
        timerGeneration += 1
    }

    private mutating func arm(_ delay: TimeInterval) -> Response {
        timerGeneration += 1
        return Response(consume: true, armTimer: delay)
    }
}
