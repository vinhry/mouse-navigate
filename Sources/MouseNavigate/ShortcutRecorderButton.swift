import AppKit
import MouseNavigateCore

/// A button that captures the next key combination, modifiers included.
///
/// While armed it asks the caller to stand the keyboard cursor down, otherwise the global
/// tap could withhold the very keystroke being recorded.
final class ShortcutRecorderButton: NSButton {
    private var monitor: Any?
    private var isRecording = false

    private(set) var shortcut: Shortcut? {
        didSet { onChange?(shortcut) }
    }

    var onChange: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)

        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 220).isActive = true
        showShortcut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMonitor()
    }

    /// Stops listening without changing anything, for when the dialog closes mid-recording.
    func cancel() {
        guard isRecording else { return }
        finishRecording()
    }

    @objc private func toggleRecording() {
        guard !isRecording else {
            finishRecording()
            return
        }

        isRecording = true
        title = "Type the shortcut…"
        onRecordingChange?(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            let modifiers = Self.modifiers(from: event.modifierFlags)
            if event.type == .flagsChanged {
                // Shows the modifiers as they go down, so it is clear the keys are arriving.
                self.title = modifiers.isEmpty ? "Type the shortcut…" : modifiers.symbols + "…"
                return nil
            }

            // A bare Escape backs out; with a modifier it is a shortcut like any other.
            if event.keyCode == KeyCode.escape, modifiers.isEmpty {
                self.finishRecording()
                return nil
            }
            self.finishRecording()
            self.shortcut = Shortcut(event.keyCode, modifiers)
            self.showShortcut()
            return nil
        }
    }

    private func finishRecording() {
        removeMonitor()
        isRecording = false
        onRecordingChange?(false)
        showShortcut()
    }

    private func showShortcut() {
        title = shortcut?.displayString ?? "Record Shortcut"
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }
}
