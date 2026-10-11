import AppKit
import MouseNavigateCore

/// Runs the configurable mouse buttons through a `ButtonPressTracker`, supplying what it
/// cannot have: the bindings, the actions, the timers and the replayed clicks. Main thread
/// only, as the event tap is.
@MainActor
final class ButtonPressController {
    private let performer: ActionPerformer
    /// The binding for a press or drag with the given modifiers held, resolved for the
    /// active profile and frontmost app.
    private let binding: (Int, ButtonInput, Shortcut.Modifiers) -> ActionBinding

    private var tracker = ButtonPressTracker()
    private var timers: [Int: DispatchWorkItem] = [:]
    /// The modifiers held when each button went down. A hold or double-click is decided
    /// later, by a timer or a release, and means what the press meant.
    private var pressModifiers: [Int: Shortcut.Modifiers] = [:]

    init(performer: ActionPerformer, binding: @escaping (Int, ButtonInput, Shortcut.Modifiers) -> ActionBinding) {
        self.performer = performer
        self.binding = binding
    }

    /// Returns true when the event is swallowed.
    func buttonDown(_ button: Int, modifiers: Shortcut.Modifiers, at location: CGPoint) -> Bool {
        pressModifiers[button] = modifiers
        let capabilities = ButtonPressTracker.Capabilities(
            hasHold: binding(button, .press(.hold), modifiers) != .disabled,
            hasDoubleClick: binding(button, .press(.doubleClick), modifiers) != .disabled,
            hasDrag: DragDirection.allCases.contains { binding(button, .drag($0), modifiers) != .disabled }
        )
        let decision = tracker.buttonDown(
            button,
            capabilities: capabilities,
            location: Vector2(x: Double(location.x), y: Double(location.y))
        ) { input in
            performer.perform(binding(button, input, modifiers))
        }
        return apply(decision, to: button)
    }

    /// Returns true when the event is swallowed.
    func buttonDragged(_ button: Int, by delta: Vector2) -> Bool {
        let modifiers = pressModifiers[button] ?? []
        let decision = tracker.buttonDragged(button, by: delta) { input in
            performer.perform(binding(button, input, modifiers))
        }
        return apply(decision, to: button)
    }

    /// Returns true when the event is swallowed. Safe to call while paused: a release
    /// whose press was swallowed is swallowed too, and nothing else happens.
    func buttonUp(_ button: Int) -> Bool {
        let modifiers = pressModifiers[button] ?? []
        let decision = tracker.buttonUp(button) { input in
            performer.perform(binding(button, input, modifiers))
        }
        return apply(decision, to: button)
    }

    /// Forgets every press in progress, for pausing and switching apps.
    func reset() {
        tracker.reset()
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll()
    }

    private func apply(_ decision: ButtonPressTracker.Decision, to button: Int) -> Bool {
        if decision.cancelTimer || decision.armTimer != nil {
            timers.removeValue(forKey: button)?.cancel()
        }
        if let delay = decision.armTimer, let generation = tracker.timerGeneration(for: button) {
            let timer = DispatchWorkItem { [weak self] in
                self?.timerFired(for: button, generation: generation)
            }
            timers[button] = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
        }
        // A Logitech control taken over HID++ has no click of its own to hand back.
        if let replay = decision.replay, !LogitechControl.isVirtual(button: button) {
            replayClicks(replay.clicks, of: button, at: replay.location)
        }
        return decision.consume
    }

    private func timerFired(for button: Int, generation: Int) {
        timers[button] = nil
        let modifiers = pressModifiers[button] ?? []
        let decision = tracker.timerFired(button, generation: generation) { input in
            performer.perform(binding(button, input, modifiers))
        }
        _ = apply(decision, to: button)
    }

    /// The button's own clicks, where the press began: the tracker held the real one back,
    /// so nothing else will deliver it.
    private func replayClicks(_ count: Int, of button: Int, at location: Vector2) {
        let point = CGPoint(x: location.x, y: location.y)
        for clickNumber in 1...max(count, 1) {
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                guard let event = SyntheticEvents.mouse(
                    type, at: point, button: .center, buttonNumber: button, clickState: clickNumber
                ) else {
                    return
                }
                SyntheticEvents.post(event)
            }
        }
    }
}
