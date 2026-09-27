import AppKit
import MouseNavigateCore

/// Runs the configurable mouse buttons: a click straight away when that is all a button is
/// bound to, or through a `ButtonPressGate` when it also has a hold or double-click. Main
/// thread only, as the event tap is.
final class ButtonPressController {
    private let performer: ActionPerformer
    /// The binding for a press, resolved for the active profile and frontmost app.
    private let binding: (Int, ButtonPress) -> ActionBinding

    private var gates: [Int: ButtonPressGate] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    /// Buttons whose press ran an action, so their release is swallowed too rather than
    /// reaching an app that never saw the press.
    private var consumedPresses: Set<Int> = []

    init(performer: ActionPerformer, binding: @escaping (Int, ButtonPress) -> ActionBinding) {
        self.performer = performer
        self.binding = binding
    }

    /// Returns true when the event is swallowed.
    func buttonDown(_ button: Int) -> Bool {
        let capabilities = ButtonPressGate.Capabilities(
            hasHold: binding(button, .hold) != .disabled,
            hasDoubleClick: binding(button, .doubleClick) != .disabled
        )
        var gate = gates[button] ?? ButtonPressGate()

        // A gesture already under way finishes in the gate, whatever the bindings say now.
        guard capabilities.needsGate || gate.phase != .idle else {
            let handled = performer.perform(binding(button, .click))
            if handled {
                consumedPresses.insert(button)
            }
            return handled
        }

        let response = gate.buttonDown(capabilities: capabilities)
        gates[button] = gate
        return apply(response, to: button)
    }

    /// Returns true when the event is swallowed.
    func buttonUp(_ button: Int) -> Bool {
        if var gate = gates[button], gate.phase != .idle {
            let response = gate.buttonUp()
            gates[button] = gate
            return apply(response, to: button)
        }
        return consumedPresses.remove(button) != nil
    }

    /// Forgets every press in progress, for pausing and switching apps.
    func reset() {
        for button in gates.keys {
            gates[button]?.reset()
        }
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll()
        consumedPresses.removeAll()
    }

    private func apply(_ response: ButtonPressGate.Response, to button: Int) -> Bool {
        if response.cancelTimer || response.armTimer != nil {
            timers.removeValue(forKey: button)?.cancel()
        }
        if let delay = response.armTimer, let generation = gates[button]?.timerGeneration {
            let timer = DispatchWorkItem { [weak self] in
                self?.timerFired(for: button, generation: generation)
            }
            timers[button] = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
        }
        if let press = response.fire {
            run(press, on: button)
        }
        return response.consume
    }

    private func timerFired(for button: Int, generation: Int) {
        timers[button] = nil
        guard var gate = gates[button] else { return }
        let response = gate.timerFired(generation: generation)
        gates[button] = gate
        _ = apply(response, to: button)
    }

    /// A click the binding does not handle, such as Back outside a browser, is handed on as
    /// the button's own click: the gate held the real one back, so nothing else will.
    private func run(_ press: ButtonPress, on button: Int) {
        if !performer.perform(binding(button, press)), press == .click {
            replayClick(button)
        }
    }

    private func replayClick(_ button: Int) {
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: .center
            ) else {
                return
            }
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
