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
    private var monitor: Any?
    private var isRecording = false

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
        widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        update(keyCode: keyCode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMonitor()
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
        title = "Press a key…"
        onRecordingChange?(true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // Escape leaves the binding untouched.
            if event.keyCode != UInt16(53) {
                self.onRecord?(event.keyCode)
            }
            self.finishRecording(keyCode: event.keyCode == 53 ? nil : event.keyCode)
            return nil
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
    }
}
