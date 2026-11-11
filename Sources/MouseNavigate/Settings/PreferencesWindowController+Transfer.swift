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
        let result: SettingsSnapshot.ReadResult
        do {
            result = try Preferences.shared.readSettings(try SettingsSnapshot.loadFile(at: url))
        } catch let error as SettingsSnapshot.ReadError {
            showTransferError("Couldn't import settings", PreferencesWindowController.describe(error))
            return
        } catch {
            showTransferError("Couldn't import settings", error.localizedDescription)
            return
        }

        let actions = result.snapshot.customActions
        if actions.isEmpty {
            confirmReplace(with: result, fileName: url.lastPathComponent)
        } else {
            confirmCustomActions(actions, in: result, fileName: url.lastPathComponent)
        }
    }

    private static let replaceWarning = "Every button, gesture, keyboard cursor and scroll setting on this Mac "
        + "will be replaced. There is no undo, so export first to keep a copy."

    private func confirmReplace(with result: SettingsSnapshot.ReadResult, fileName: String) {
        guard let window else { return }
        let alert = AlertPresenter.make(
            "Replace your settings with the ones in “\(fileName)”?",
            Self.replaceWarning,
            buttons: ["Replace", "Cancel"]
        )
        // Marked as destructive, Replace no longer answers Return, so a stray Return cannot
        // throw the settings away. Cancel keeps Escape; making it the Return button instead
        // would take Escape from it.
        let replace = alert.buttons[0]
        replace.hasDestructiveAction = true
        replace.keyEquivalent = ""

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // The sheet has to be gone before another can be shown.
            DispatchQueue.main.async {
                self?.importSettings(result, leftOutActions: 0)
            }
        }
    }

    /// Listed in the sheet before the rest are only counted: enough to see what a file is
    /// up to, few enough that the list is read rather than scrolled past.
    private static let listedActionLimit = 50

    /// A file that would make inputs press keys, open apps or links, or run shortcuts says
    /// so, one by one, before anything is replaced. Leaving them out is the default, since
    /// a shared file has no business deciding what a click does without being looked at.
    private func confirmCustomActions(
        _ actions: [SettingsSnapshot.CustomAction],
        in result: SettingsSnapshot.ReadResult,
        fileName: String
    ) {
        guard let window else { return }
        let inputs = actions.count == 1 ? "The input below" : "The \(actions.count) inputs below"
        let alert = AlertPresenter.make(
            "“\(fileName)” includes custom actions",
            "\(inputs) would press keys, open an app or a link, or run a shortcut. Import them "
                + "only if you know what each one does and trust where the file came from.\n\n"
                + "Import Without Custom Actions takes everything else and leaves those inputs at their "
                + "defaults. Either way, every button, gesture, keyboard cursor and scroll setting on this "
                + "Mac is replaced, with no undo.",
            style: .warning,
            buttons: ["Import Without Custom Actions", "Import Everything", "Cancel"]
        )
        alert.accessoryView = Self.customActionList(actions)

        alert.beginSheetModal(for: window) { [weak self] response in
            let chosen: SettingsSnapshot.ReadResult
            switch response {
            case .alertFirstButtonReturn: chosen = result.withoutCustomActions()
            case .alertSecondButtonReturn: chosen = result
            default: return
            }
            let leftOut = response == .alertFirstButtonReturn ? actions.count : 0
            DispatchQueue.main.async {
                self?.importSettings(chosen, leftOutActions: leftOut)
            }
        }
    }

    /// One line per action, in a box that fits a short list and scrolls a long one.
    private static func customActionList(_ actions: [SettingsSnapshot.CustomAction]) -> NSView {
        var lines = actions.prefix(listedActionLimit).map { "• " + $0.summary }
        if actions.count > listedActionLimit {
            lines.append("and \(actions.count - listedActionLimit) more")
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        // Selectable, so a URL or bundle ID can be copied to look it up.
        text.isSelectable = true
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = lines.joined(separator: "\n")
        text.setAccessibilityLabel("Custom actions in the file")
        scroll.documentView = text

        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            let fitted = layout.usedRect(for: container).height + text.textContainerInset.height * 2 + 4
            scroll.frame.size.height = min(max(fitted, 32), 200)
        }
        return scroll
    }

    private func importSettings(_ result: SettingsSnapshot.ReadResult, leftOutActions: Int) {
        Preferences.shared.applySettings(result)
        refreshAllUI()

        guard let window else { return }
        var notes: [String] = []
        if leftOutActions == 1 {
            notes.append("The file's custom action was left out, so that input is at its default.")
        } else if leftOutActions > 1 {
            notes.append("The file's \(leftOutActions) custom actions were left out, so those inputs are at their defaults.")
        }
        if !result.ignoredKeys.isEmpty {
            notes.append(
                "Settings this version of MouseNavigate does not know, or that each Mac keeps for itself, "
                    + "were left out:\n" + result.ignoredKeys.joined(separator: "\n")
            )
        }
        let message = notes.isEmpty ? "Every setting now comes from the file." : notes.joined(separator: "\n\n")
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
        case .fileTooLarge(let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "This file is larger than any MouseNavigate settings file (\(size) at most). Nothing was changed."
        case .tooManyKeys(let limit):
            return "This file holds more settings than MouseNavigate has "
                + "(\(limit.formatted()) at most). Nothing was changed."
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
