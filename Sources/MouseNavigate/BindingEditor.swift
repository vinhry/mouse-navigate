import AppKit
import MouseNavigateCore
import UniformTypeIdentifiers

/// The sheets behind the pickers' "…" items: record a shortcut, choose an app, type a URL
/// or name a Shortcuts shortcut. Each hands back nil when cancelled.
@MainActor
final class BindingEditor: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    private let engine: KeyboardCursorEngine

    /// The sheet's OK button, enabled only while its field holds something usable.
    private weak var confirmButton: NSButton?
    private var isAcceptable: ((String) -> Bool)?

    init(engine: KeyboardCursorEngine) {
        self.engine = engine
    }

    // MARK: - Keyboard shortcut

    func editShortcut(current: Shortcut?, in window: NSWindow, completion: @escaping (Shortcut?) -> Void) {
        let alert = makeAlert(
            title: "Keyboard Shortcut",
            message: "Press the keys. The shortcut is sent to the frontmost app. Click the button to record again."
        )

        let recorder = ShortcutRecorderButton(shortcut: current)
        recorder.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        recorder.onRecordingChange = { [weak self] recording in
            // Stop the tap from eating the keystroke being recorded. The recording flag,
            // not the pause flag: finishing here must not resume a paused app.
            self?.engine.isRecordingSuspended = recording
        }
        alert.accessoryView = recorder

        let ok = alert.buttons[0]
        ok.isEnabled = current != nil
        recorder.onChange = { [weak ok] shortcut in
            ok?.isEnabled = shortcut != nil
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            recorder.cancel()
            self?.engine.isRecordingSuspended = false
            completion(response == .alertFirstButtonReturn ? recorder.shortcut : nil)
        }
        // Straight into recording: that is the only thing this sheet is for.
        recorder.performClick(nil)
    }

    // MARK: - App

    /// `message` says what the app is for: the same panel picks an app to launch and an app
    /// to give its own bindings.
    func chooseApp(message: String, in window: NSWindow, completion: @escaping ((bundleID: String, name: String)?) -> Void) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.beginSheetModal(for: window) { response in
            guard response == .OK,
                  let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier
            else {
                completion(nil)
                return
            }
            completion((bundleID, url.deletingPathExtension().lastPathComponent))
        }
    }

    // MARK: - URL

    func editURL(current: URL?, in window: NSWindow, completion: @escaping (URL?) -> Void) {
        let alert = makeAlert(title: "Open URL", message: "A web address, or any link an app on this Mac can open.")

        let field = NSTextField(string: current?.absoluteString ?? "")
        field.placeholderString = "https://"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        watch(field, confirm: alert.buttons[0]) { ActionBinding.validURL($0) != nil }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, let url = ActionBinding.validURL(field.stringValue) else {
                completion(nil)
                return
            }
            // Asked once: keeping a link that was already bound asks nothing.
            guard case .other(let scheme) = ActionBinding.linkKind(of: url), url != current else {
                completion(url)
                return
            }
            // The sheet has to be gone before another can be shown.
            DispatchQueue.main.async {
                Self.confirmUnusualLink(url, scheme: scheme, in: window, completion: completion)
            }
        }
        alert.window.makeFirstResponder(field)
    }

    /// A web page or an email is what people expect a link to open. Any other scheme goes to
    /// whichever app claims it, so it is said once, here, while the link is being chosen,
    /// rather than each time the input is used: `raycast:` and `things:` links are what
    /// some people bind on purpose.
    private static func confirmUnusualLink(_ url: URL, scheme: String, in window: NSWindow, completion: @escaping (URL?) -> Void) {
        let message: String
        if url.isFileURL {
            message = "This opens \(url.path) each time the input is used, the way double-clicking it "
                + "in the Finder would: a document opens in its app, and an app or a script runs."
        } else {
            message = "This opens \(url.absoluteString) with whatever app handles “\(scheme):” links, "
                + "each time the input is used. That app decides what the link does, which can be more "
                + "than showing a page. Use it only if you know what this link does."
        }
        AlertPresenter.sheet(
            "Open a “\(scheme):” link?",
            message,
            buttons: ["Use This Link", "Cancel"],
            on: window
        ) { response in
            completion(response == .alertFirstButtonReturn ? url : nil)
        }
    }

    // MARK: - Shortcuts app

    func editShortcutName(current: String?, in window: NSWindow, completion: @escaping (String?) -> Void) {
        let alert = makeAlert(title: "Run Shortcut", message: "The name of a shortcut in the Shortcuts app.")

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        combo.stringValue = current ?? ""
        combo.placeholderString = "Loading shortcuts…"
        combo.completes = true
        alert.accessoryView = combo
        watch(combo, confirm: alert.buttons[0]) { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Listed in the background: `shortcuts list` takes a noticeable moment.
        DispatchQueue.global(qos: .userInitiated).async {
            let names = Self.shortcutNames()
            DispatchQueue.main.async {
                combo.addItems(withObjectValues: names)
                combo.placeholderString = names.isEmpty ? "Shortcut name" : "Choose or type a name"
            }
        }

        alert.beginSheetModal(for: window) { response in
            let name = combo.stringValue.trimmingCharacters(in: .whitespaces)
            completion(response == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
        alert.window.makeFirstResponder(combo)
    }

    private nonisolated static func shortcutNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    // MARK: - Helpers

    private func makeAlert(title: String, message: String) -> NSAlert {
        AlertPresenter.make(title, message, buttons: ["OK", "Cancel"])
    }

    private func watch(_ field: NSTextField, confirm: NSButton, acceptable: @escaping (String) -> Bool) {
        confirmButton = confirm
        isAcceptable = acceptable
        field.delegate = self
        confirm.isEnabled = acceptable(field.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        confirmButton?.isEnabled = isAcceptable?(field.stringValue) ?? true
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // Picking from the list counts even before the field's text catches up.
        confirmButton?.isEnabled = true
    }
}
