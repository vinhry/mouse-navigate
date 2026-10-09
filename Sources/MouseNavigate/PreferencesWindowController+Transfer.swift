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

        let row = NSStackView(views: [export, importButton])
        row.orientation = .horizontal
        row.spacing = 12
        return row
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

    private func confirmImport(from url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Replace your settings with the ones in “\(url.lastPathComponent)”?"
        alert.informativeText = "Every button, gesture, keyboard cursor and scroll setting on this Mac "
            + "will be replaced. There is no undo, so export first to keep a copy."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // The sheet has to be gone before another can be shown.
            DispatchQueue.main.async {
                self?.importSettings(from: url)
            }
        }
    }

    private func importSettings(from url: URL) {
        let result: SettingsSnapshot.ReadResult
        do {
            result = try Preferences.shared.importSettings(try Data(contentsOf: url))
        } catch let error as SettingsSnapshot.ReadError {
            showTransferError("Couldn't import settings", PreferencesWindowController.describe(error))
            return
        } catch {
            showTransferError("Couldn't import settings", error.localizedDescription)
            return
        }
        refreshAllUI()

        guard !result.ignoredKeys.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Settings imported"
        alert.informativeText = "Settings this version of MouseNavigate does not know were left out: "
            + result.ignoredKeys.joined(separator: ", ") + "."
        alert.beginSheetModal(for: window)
    }

    private func showTransferError(_ title: String, _ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
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
