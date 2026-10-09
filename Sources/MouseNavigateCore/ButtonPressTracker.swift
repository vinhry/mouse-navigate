import Foundation

/// Runs the configurable mouse buttons: a click straight away when that is all a button is
/// bound to, or through a `ButtonPressGate` when it also has a hold, double-click or drag.
///
/// Whatever the bindings decide, a press and its release are kept together: an app is never
/// handed a release for a press it did not see, and a press no binding handled is replayed
/// where it happened rather than dropped. The tracker keeps no clock and posts nothing
/// itself; it says what to run, what to replay and which timers to arm.
public struct ButtonPressTracker {
    public typealias Capabilities = ButtonPressGate.Capabilities

    /// Clicks to send on the button's behalf, because no binding handled its press.
    public struct Replay: Equatable {
        public var clicks: Int
        /// Where the press began, which is where the app would have received it.
        public var location: Vector2

        public init(clicks: Int, location: Vector2) {
            self.clicks = clicks
            self.location = location
        }
    }

    public struct Decision: Equatable {
        /// Swallow the event rather than deliver it.
        public var consume: Bool
        /// Arm the button's timer for this long, replacing any running one.
        public var armTimer: TimeInterval?
        /// Stop the button's timer without starting another.
        public var cancelTimer: Bool
        public var replay: Replay?

        public init(consume: Bool, armTimer: TimeInterval? = nil, cancelTimer: Bool = false, replay: Replay? = nil) {
            self.consume = consume
            self.armTimer = armTimer
            self.cancelTimer = cancelTimer
            self.replay = replay
        }

        public static let pass = Decision(consume: false)
        public static let consume = Decision(consume: true)
    }

    private var gates: [Int: ButtonPressGate] = [:]
    /// Buttons whose press was swallowed, so their release must be too. Survives a reset:
    /// the button is still down whatever else has been forgotten.
    private var swallowRelease: Set<Int> = []
    private var pressLocations: [Int: Vector2] = [:]
    /// One per button held back that can be dragged.
    private var dragDetectors: [Int: DragDirectionDetector] = [:]
    private let holdDelay: TimeInterval
    private let doubleClickWindow: TimeInterval
    private let dragThreshold: Double

    public init(
        holdDelay: TimeInterval = ButtonPressGate.defaultHoldDelay,
        doubleClickWindow: TimeInterval = ButtonPressGate.defaultDoubleClickWindow,
        dragThreshold: Double = DragDirectionDetector.defaultThreshold
    ) {
        self.holdDelay = holdDelay
        self.doubleClickWindow = doubleClickWindow
        self.dragThreshold = dragThreshold
    }

    public func phase(of button: Int) -> ButtonPressGate.Phase {
        gates[button]?.phase ?? .idle
    }

    /// The generation a timer armed for `button` must carry to count when it fires.
    public func timerGeneration(for button: Int) -> Int? {
        gates[button]?.timerGeneration
    }

    /// `perform` runs a press or drag and reports whether a binding handled it.
    public mutating func buttonDown(
        _ button: Int,
        capabilities: Capabilities,
        location: Vector2,
        perform: (ButtonInput) -> Bool
    ) -> Decision {
        // A release missed earlier must not swallow this press's own release.
        swallowRelease.remove(button)
        pressLocations[button] = location

        var gate = gates[button] ?? ButtonPressGate(holdDelay: holdDelay, doubleClickWindow: doubleClickWindow)

        // A gesture already under way finishes in the gate, whatever the bindings say now.
        guard capabilities.needsGate || gate.phase != .idle else {
            let handled = perform(.press(.click))
            if handled {
                swallowRelease.insert(button)
            }
            return Decision(consume: handled)
        }

        let wasIdle = gate.phase == .idle
        let response = gate.buttonDown(capabilities: capabilities)
        gates[button] = gate
        if response.consume {
            swallowRelease.insert(button)
        }
        if wasIdle, capabilities.hasDrag {
            dragDetectors[button] = DragDirectionDetector(threshold: dragThreshold)
        }
        return apply(response, to: button, perform: perform)
    }

    /// The pointer moved with `button` down. Taken only while a press that can be dragged
    /// is being held back; a button bound to a click alone passes its drags through, as
    /// it passed its press.
    public mutating func buttonDragged(_ button: Int, by delta: Vector2, perform: (ButtonInput) -> Bool) -> Decision {
        guard var detector = dragDetectors[button], var gate = gates[button], gate.phase != .idle else {
            return .pass
        }
        guard let direction = detector.moved(by: delta) else {
            dragDetectors[button] = detector
            return .consume
        }
        dragDetectors[button] = detector
        let response = gate.dragFired(direction)
        gates[button] = gate
        return apply(response, to: button, perform: perform)
    }

    public mutating func buttonUp(_ button: Int, perform: (ButtonInput) -> Bool) -> Decision {
        guard var gate = gates[button], gate.phase != .idle else {
            return swallowRelease.remove(button) != nil ? .consume : .pass
        }
        let response = gate.buttonUp()
        gates[button] = gate
        if gate.phase == .idle {
            swallowRelease.remove(button)
        }
        return apply(response, to: button, perform: perform)
    }

    public mutating func timerFired(_ button: Int, generation: Int, perform: (ButtonInput) -> Bool) -> Decision {
        guard var gate = gates[button] else { return .consume }
        let response = gate.timerFired(generation: generation)
        gates[button] = gate
        return apply(response, to: button, perform: perform)
    }

    /// Forgets every gesture in progress, for pausing and switching apps. Which buttons are
    /// still down is remembered, so their releases go nowhere.
    public mutating func reset() {
        for button in gates.keys {
            gates[button]?.reset()
        }
        dragDetectors.removeAll()
    }

    private mutating func apply(
        _ response: ButtonPressGate.Response,
        to button: Int,
        perform: (ButtonInput) -> Bool
    ) -> Decision {
        var decision = Decision(consume: response.consume, armTimer: response.armTimer, cancelTimer: response.cancelTimer)
        if let input = response.fire, !perform(input), case .press(let press) = input {
            // The gate held the real press back, so nothing else will deliver it. A
            // double-click that went nowhere is still two clicks to the app. A drag that
            // went nowhere is not replayed: a click was not what the user meant.
            decision.replay = Replay(
                clicks: press == .doubleClick ? 2 : 1,
                location: pressLocations[button] ?? .zero
            )
        }
        if gates[button]?.phase == .idle {
            pressLocations[button] = nil
            dragDetectors[button] = nil
        }
        return decision
    }
}
