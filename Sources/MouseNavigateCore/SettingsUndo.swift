import Foundation

/// A change that throws many settings away at once, named so it can be offered back.
public enum SettingsChange: Equatable, Sendable {
    /// The tabs with a Restore Defaults button, by the names they have in the window.
    public enum Tab: String, Sendable {
        case mouse = "Mouse"
        case cursor = "Keyboard Cursor"
        case touch = "Touch"
    }

    /// Settings replaced by a file's, with or without its custom actions.
    case importFile(name: String)
    /// Restore Defaults on a tab; `app` is the name of the app it was done for, nil for
    /// All Apps.
    case restoreDefaults(Tab, app: String?)
    /// Remove App, with the app's name.
    case removeApp(name: String)

    /// What the change was, written to follow "Undo" or "before": "the import of
    /// “file.json”", "Restore Defaults on the Touch tab", "removing the settings for Safari".
    /// Names come from a file or an app's bundle, so they are made safe to show.
    public var label: String {
        switch self {
        case .importFile(let name):
            return "the import of “\(SettingsSnapshot.displayable(name))”"
        case .restoreDefaults(let tab, let app):
            let base = "Restore Defaults on the \(tab.rawValue) tab"
            return app.map { "\(base) for \(SettingsSnapshot.displayable($0))" } ?? base
        case .removeApp(let name):
            return "removing the settings for \(SettingsSnapshot.displayable(name))"
        }
    }
}

/// The settings as they were just before a `SettingsChange`, kept in memory so the change
/// can be taken back. Never written to disk: it is a way out of a mistake made just now,
/// not a backup, and it goes when MouseNavigate quits.
public struct SettingsUndoPoint: Equatable {
    public var change: SettingsChange
    public var date: Date
    /// Everything `capture` takes; the keys it leaves out are ones no change above touches.
    public var snapshot: SettingsSnapshot

    public init(change: SettingsChange, date: Date, snapshot: SettingsSnapshot) {
        self.change = change
        self.date = date
        self.snapshot = snapshot
    }
}
