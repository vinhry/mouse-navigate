import AppKit
import MouseNavigateCore
import UniformTypeIdentifiers

/// Export and import of every setting as a JSON file, from the About tab.
extension PreferencesWindowController {
    func makeTransferSection() -> NSView {
        let export = NSButton(title: "Export Settings…", target: self, action: #selector(exportSettingsTapped))
        export.bezelStyle = .rounded
        export.toolTip = "Writes every setting to a JSON file you can read, edit and keep."

        let importButton = NSButton(title: "Import Settings…", target: self, action: #selector(importSettingsTapped))
        importButton.bezelStyle = .rounded
        importButton.toolTip = "Replaces every setting with the ones in a file, after checking it."

        let diagnostics = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnosticsTapped(_:)))
        diagnostics.bezelStyle = .rounded
        diagnostics.toolTip = "Copies what MouseNavigate can see and which permissions it has, to paste into a "
            + "bug report. Nothing about your apps, shortcuts or files is included."

        let row = NSStackView(views: [export, importButton, diagnostics])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    @objc func copyDiagnosticsTapped(_ sender: NSButton) {
        guard let report = diagnosticsProvider?() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.text, forType: .string)

        // Nothing else on screen changes, so say it worked, in words and to VoiceOver.
        let title = "Copy Diagnostics"
        sender.title = "Copied"
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Diagnostics copied", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak sender] in
            sender?.title = title
        }
    }

    @objc func exportSettingsTapped() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MouseNavigate Settings.json"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Preferences.shared.exportSettings(appVersion: AppInfo.version)
                try data.write(to: url, options: .atomic)
            } catch {
                self?.showTransferError("Couldn't export settings", error.localizedDescription)
            }
        }
    }

    @objc func importSettingsTapped() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.confirmImport(from: url)
        }
    }

    /// The file is read and checked before the question is asked, so a file that cannot be
    /// imported is refused without a replace being agreed to first.
    private func confirmImport(from url: URL) {
        guard let window else { return }
        let result: SettingsSnapshot.ReadResult
        do {
            result = try Preferences.shared.readSettings(try Data(contentsOf: url))
        } catch let error as SettingsSnapshot.ReadError {
            showTransferError("Couldn't import settings", PreferencesWindowController.describe(error))
            return
        } catch {
            showTransferError("Couldn't import settings", error.localizedDescription)
            return
        }

        AlertPresenter.sheet(
            "Replace your settings with the ones in “\(url.lastPathComponent)”?",
            "Every button, gesture, keyboard cursor and scroll setting on this Mac "
                + "will be replaced. There is no undo, so export first to keep a copy.",
            buttons: ["Replace", "Cancel"],
            on: window
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // The sheet has to be gone before another can be shown.
            DispatchQueue.main.async {
                self?.importSettings(result)
            }
        }
    }

    private func importSettings(_ result: SettingsSnapshot.ReadResult) {
        Preferences.shared.applySettings(result)
        refreshAllUI()

        guard let window else { return }
        let message = result.ignoredKeys.isEmpty
            ? "Every setting now comes from the file."
            : "Settings this version of MouseNavigate does not know were left out:\n"
                + result.ignoredKeys.joined(separator: "\n")
        AlertPresenter.sheet("Settings imported", message, on: window)
    }

    private func showTransferError(_ title: String, _ message: String) {
        guard let window else { return }
        AlertPresenter.sheet(title, message, style: .warning, on: window)
    }

    private static func describe(_ error: SettingsSnapshot.ReadError) -> String {
        switch error {
        case .notASettingsFile:
            return "This is not a MouseNavigate settings file."
        case .unsupportedSchema(let version):
            return "This file is laid out in a way this version cannot read (schema \(version))."
        case .newerConfigVersion:
            return "This file was written by a newer MouseNavigate. Update first, then import it."
        case .wrongType(let key, let expected):
            return "The setting “\(key)” should be \(describe(expected)). Nothing was changed."
        }
    }

    private static func describe(_ type: SettingsKey.ValueType) -> String {
        switch type {
        case .bool: return "true or false"
        case .int: return "a whole number"
        case .double: return "a number"
        case .string: return "text"
        case .dictionary: return "a set of entries"
        case .date: return "a date"
        }
    }
}
