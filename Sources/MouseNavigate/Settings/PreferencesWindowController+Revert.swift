import AppKit
import MouseNavigateCore

/// Taking back the last import, Restore Defaults or Remove App. `Preferences` keeps the
/// settings from before it in memory; this offers them back from the import's success
/// sheet and from Revert Last Change on the About tab, which stays until MouseNavigate
/// quits, so the chance is not lost with the sheet or for changes that show none.
extension PreferencesWindowController {
    /// Said in every confirmation for a change that can be taken back, which is the only
    /// reason it is not final.
    static let undoNotice = "You can take this back with Revert Last Change on the About tab "
        + "until you quit MouseNavigate."

    /// Runs a change the user has just agreed to, keeping what it replaces. Returns the
    /// new undo point, or nil if the change kept none because it changed nothing, so a
    /// caller never offers to take back a change with an older one's settings.
    @discardableResult
    func recordingUndo(_ change: SettingsChange, _ body: () -> Void) -> SettingsUndoPoint? {
        let previous = Preferences.shared.undoPoint
        Preferences.shared.recordingUndo(change, body)
        let current = Preferences.shared.undoPoint
        guard let current, current != previous else { return nil }
        revertNote = nil
        refreshRevertUI()
        return current
    }

    func makeRevertButton() -> NSButton {
        let button = NSButton(title: "Revert Last Change…", target: self, action: #selector(revertLastChangeTapped))
        button.bezelStyle = .rounded
        revertButton = button
        return button
    }

    /// The line under the About tab's buttons that says what Revert Last Change would undo,
    /// or that it just did. Empty rather than hidden, so the page keeps its height.
    func makeRevertStatusLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        revertStatusLabel = label
        return label
    }

    func refreshRevertUI() {
        let point = Preferences.shared.undoPoint
        revertButton?.isEnabled = point != nil
        let summary = point.map { "Undo \($0.change.label), made \(Self.when($0.date))" }
        revertButton?.toolTip = summary
            ?? "Puts back your settings from before the last import, Restore Defaults or Remove App. "
            + "There is nothing to put back now."
        let status = summary ?? revertNote ?? ""
        revertStatusLabel?.stringValue = status
        revertStatusLabel?.toolTip = status.isEmpty ? nil : status
    }

    @objc func revertLastChangeTapped() {
        guard let window, let point = Preferences.shared.undoPoint else { return }
        let label = point.change.label
        AlertPresenter.confirmDestructive(
            "Revert to your settings from before \(label)?",
            "Settings go back to how they were before \(label) \(Self.when(point.date)); "
                + "anything you changed since then is lost.",
            confirm: "Revert",
            on: window
        ) { [weak self] in
            // Nothing else can make a change while the sheet is up; this only makes sure the
            // settings put back are the ones the question named.
            guard Preferences.shared.undoPoint == point else { return }
            self?.revertLastChange()
        }
    }

    /// Puts the undo point back and every control with it, the way an import does: the
    /// settings go through the same migration and the same change to everything, so the
    /// touch monitor, the event tap and Logitech diversion follow them too.
    @discardableResult
    func revertLastChange() -> SettingsUndoPoint? {
        guard let point = Preferences.shared.undoPoint else { return nil }
        Preferences.shared.revertLastChange()
        let note = "Settings are back to how they were before \(point.change.label)."
        revertNote = note
        refreshAllUI()
        // The button greys out and the line under it changes; say it to VoiceOver too.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: note, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        return point
    }

    /// "at 3:42 PM" today, "on Nov 9, 2026 at 3:42 PM" before: the app can run for days.
    static func when(_ date: Date) -> String {
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        guard !Calendar.current.isDateInToday(date) else { return "at \(time)" }
        let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        return "on \(day) at \(time)"
    }
}
