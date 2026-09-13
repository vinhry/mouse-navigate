import AppKit
import MouseNavigateCore

/// A button that captures the next keystroke and reports its virtual key code.
///
/// While armed it asks the engine to stand down, otherwise the global tap would swallow
/// the very keystroke being recorded.
final class KeyRecorderButton: NSButton {
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
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
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
        title = KeyCodeNames.name(for: keyCode)
    }

    @objc private func startRecording() {
        guard !isRecording else {
            cancelRecording()
            return
        }

        isRecording = true
        title = "Press a key…"
        onRecordingChange?(true)

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

    private func cancelRecording() {
        finishRecording(keyCode: nil)
    }

    private func finishRecording(keyCode: UInt16?) {
        removeMonitor()
        isRecording = false
        onRecordingChange?(false)

        if let keyCode {
            title = KeyCodeNames.name(for: keyCode)
        } else {
            title = KeyCodeNames.name(for: Preferences.shared.keyCode(for: binding))
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
