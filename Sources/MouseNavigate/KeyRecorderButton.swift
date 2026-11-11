import AppKit
import MouseNavigateCore

/// A button that captures the next keystroke and reports its virtual key code.
///
/// While armed it asks the engine to stand down, otherwise the global tap would swallow
/// the very keystroke being recorded. Only one recorder is ever armed, and none stays
/// armed once its window has gone: an app that lives in the menu bar gets no keystroke
/// to end the recording with once the window is closed.
final class KeyRecorderButton: NSButton {
    /// The one recorder armed at the moment, if any.
    private static weak var active: KeyRecorderButton?

    private let binding: CursorBinding
    /// Only used on the main thread, apart from being let go of in deinit.
    nonisolated(unsafe) private var monitor: Any?
    private var isRecording = false
    /// Clicks elsewhere in the window, which end the recording like a click on the button.
    nonisolated(unsafe) private var clickMonitor: Any?

    /// Escape is a key like any other here: it is the default Exit key, so taking it as
    /// "cancel" would leave no way to bind it again. Clicking cancels instead.
    private static let prompt = "Press a key, click to cancel"

    var onRecord: ((UInt16) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    init(binding: CursorBinding, keyCode: UInt16) {
        self.binding = binding
        super.init(frame: .zero)

        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for the prompt, so the keys list does not shift while recording.
        title = KeyRecorderButton.prompt
        let promptWidth = ceil(intrinsicContentSize.width)
        widthAnchor.constraint(greaterThanOrEqualToConstant: max(96, promptWidth)).isActive = true
        update(keyCode: keyCode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    func update(keyCode: UInt16) {
        guard !isRecording else { return }
        title = KeyboardLayout.shared.name(for: keyCode)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, isRecording {
            cancelRecording()
        }
    }

    @objc private func startRecording() {
        guard !isRecording else {
            cancelRecording()
            return
        }
        // A second recorder armed alongside the first would never hear the keystroke the
        // first one takes.
        KeyRecorderButton.active?.cancelRecording()
        KeyRecorderButton.active = self

        isRecording = true
        title = KeyRecorderButton.prompt
        onRecordingChange?(true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            self.onRecord?(event.keyCode)
            self.finishRecording(keyCode: event.keyCode)
            return nil
        }
        // A click anywhere but on this button backs out, and still does what it was for.
        // A click on the button is left to its own action, which cancels.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let onButton = event.window === self.window
                && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !onButton {
                self.cancelRecording()
            }
            return event
        }
    }

    @objc private func windowResignedKey() {
        // Keystrokes now go elsewhere, so none will arrive to end the recording.
        cancelRecording()
    }

    private func cancelRecording() {
        finishRecording(keyCode: nil)
    }

    private func finishRecording(keyCode: UInt16?) {
        guard isRecording else { return }
        removeMonitor()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        isRecording = false
        if KeyRecorderButton.active === self {
            KeyRecorderButton.active = nil
        }
        onRecordingChange?(false)

        title = KeyboardLayout.shared.name(for: keyCode ?? Preferences.shared.keyCode(for: binding))
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }
}
