import AppKit
import MouseNavigateCore

/// Runs the configurable mouse buttons through a `ButtonPressTracker`, supplying what it
/// cannot have: the bindings, the actions, the timers and the replayed clicks. Main thread
/// only, as the event tap is.
final class ButtonPressController {
    private let performer: ActionPerformer
    /// The binding for a press, resolved for the active profile and frontmost app.
    private let binding: (Int, ButtonPress) -> ActionBinding

    private var tracker = ButtonPressTracker()
    private var timers: [Int: DispatchWorkItem] = [:]

    init(performer: ActionPerformer, binding: @escaping (Int, ButtonPress) -> ActionBinding) {
        self.performer = performer
        self.binding = binding
    }

    /// Returns true when the event is swallowed.
    func buttonDown(_ button: Int, at location: CGPoint) -> Bool {
        let capabilities = ButtonPressTracker.Capabilities(
            hasHold: binding(button, .hold) != .disabled,
            hasDoubleClick: binding(button, .doubleClick) != .disabled
        )
        let decision = tracker.buttonDown(
            button,
            capabilities: capabilities,
            location: Vector2(x: Double(location.x), y: Double(location.y))
        ) { press in
            performer.perform(binding(button, press))
        }
        return apply(decision, to: button)
    }

    /// Returns true when the event is swallowed. Safe to call while paused: a release
    /// whose press was swallowed is swallowed too, and nothing else happens.
    func buttonUp(_ button: Int) -> Bool {
        let decision = tracker.buttonUp(button) { press in
            performer.perform(binding(button, press))
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
        if let replay = decision.replay {
            replayClicks(replay.clicks, of: button, at: replay.location)
        }
        return decision.consume
    }

    private func timerFired(for button: Int, generation: Int) {
        timers[button] = nil
        let decision = tracker.timerFired(button, generation: generation) { press in
            performer.perform(binding(button, press))
        }
        _ = apply(decision, to: button)
    }

    /// The button's own clicks, where the press began: the tracker held the real one back,
    /// so nothing else will deliver it.
    private func replayClicks(_ count: Int, of button: Int, at location: Vector2) {
        let point = CGPoint(x: location.x, y: location.y)
        for clickNumber in 1...max(count, 1) {
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                guard let event = CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .center
                ) else {
                    return
                }
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
                event.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
