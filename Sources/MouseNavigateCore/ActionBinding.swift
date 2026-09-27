import Foundation

/// What a button, gesture or drawn character is bound to: one of the built-in actions, or
/// one the user configured with a value of its own.
public enum ActionBinding: Equatable {
    case builtin(ButtonAction)
    case shortcut(Shortcut)
    /// `name` is only a label, kept so the binding reads well without looking the app up.
    case launchApp(bundleID: String, name: String)
    case openURL(URL)
    case runShortcut(name: String)

    public static let disabled = ActionBinding.builtin(.disabled)

    public var builtinAction: ButtonAction? {
        if case .builtin(let action) = self { return action }
        return nil
    }

    public var displayName: String {
        switch self {
        case .builtin(let action): return action.displayName
        case .shortcut(let shortcut): return "Shortcut \(shortcut.displayString)"
        case .launchApp(_, let name): return "Launch \(name)"
        case .openURL(let url): return "Open \(url.host ?? url.absoluteString)"
        case .runShortcut(let name): return "Run Shortcut “\(name)”"
        }
    }

    // MARK: - Storage

    /// Built-in actions store as their bare raw value, exactly as every version before
    /// bindings did, so existing settings read back unchanged. Everything else stores as
    /// a small JSON object, which can never collide with a raw value.
    public var storageValue: String {
        if case .builtin(let action) = self {
            return action.rawValue
        }

        let stored: Stored
        switch self {
        case .builtin:
            preconditionFailure("handled above")
        case .shortcut(let shortcut):
            stored = Stored(
                type: .shortcut,
                keyCode: shortcut.keyCode,
                modifiers: Stored.modifierNames(shortcut.modifiers)
            )
        case .launchApp(let bundleID, let name):
            stored = Stored(type: .launchApp, bundleID: bundleID, name: name)
        case .openURL(let url):
            stored = Stored(type: .openURL, url: url.absoluteString)
        case .runShortcut(let name):
            stored = Stored(type: .runShortcut, name: name)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stored), let json = String(data: data, encoding: .utf8) else {
            return ButtonAction.disabled.rawValue
        }
        return json
    }

    /// nil for anything unreadable, so the caller falls back to its default rather than
    /// running something half-decoded.
    public init?(storageValue: String) {
        if let action = ButtonAction(rawValue: storageValue) {
            self = .builtin(action)
            return
        }

        guard
            let data = storageValue.data(using: .utf8),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            return nil
        }

        switch stored.type {
        case .shortcut:
            guard let keyCode = stored.keyCode,
                  let modifiers = Stored.modifiers(named: stored.modifiers ?? [])
            else {
                return nil
            }
            self = .shortcut(Shortcut(keyCode, modifiers))
        case .launchApp:
            guard let bundleID = stored.bundleID, !bundleID.isEmpty else { return nil }
            self = .launchApp(bundleID: bundleID, name: stored.name ?? bundleID)
        case .openURL:
            guard let raw = stored.url, let url = ActionBinding.validURL(raw) else { return nil }
            self = .openURL(url)
        case .runShortcut:
            guard let name = stored.name, !name.isEmpty else { return nil }
            self = .runShortcut(name: name)
        }
    }

    /// A URL worth opening: it has to name a scheme, or `NSWorkspace` has nothing to hand
    /// it to. Bare hosts such as "example.com" are taken as web addresses.
    public static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty,
           trimmed.contains(":") {
            return url
        }
        guard !trimmed.contains(" "), trimmed.contains(".") else { return nil }
        return URL(string: "https://" + trimmed)
    }

    private struct Stored: Codable {
        enum Kind: String, Codable {
            case shortcut, launchApp, openURL, runShortcut
        }

        var type: Kind
        var keyCode: UInt16?
        var modifiers: [String]?
        var bundleID: String?
        var name: String?
        var url: String?

        private static let modifierTable: [(String, Shortcut.Modifiers)] = [
            ("control", .control), ("option", .option), ("shift", .shift), ("command", .command),
        ]

        /// Names rather than a bit mask, so an exported settings file can be read.
        static func modifierNames(_ modifiers: Shortcut.Modifiers) -> [String] {
            modifierTable.filter { modifiers.contains($0.1) }.map(\.0)
        }

        static func modifiers(named names: [String]) -> Shortcut.Modifiers? {
            var modifiers: Shortcut.Modifiers = []
            for name in names {
                guard let entry = modifierTable.first(where: { $0.0 == name }) else { return nil }
                modifiers.insert(entry.1)
            }
            return modifiers
        }
    }
}

/// The ways one mouse button can be pressed, each with a binding of its own.
public enum ButtonPress: String, CaseIterable {
    case click
    case hold
    case doubleClick

    public var displayName: String {
        switch self {
        case .click: return "Click"
        case .hold: return "Hold"
        case .doubleClick: return "Double-click"
        }
    }
}

/// Something that can be bound: a mouse button press on one device profile, a touch
/// gesture or a drawn character.
public enum BindingTrigger: Hashable {
    case button(Int, DeviceProfile, ButtonPress = .click)
    case touch(TouchGesture)
    case character(CharacterGesture)

    /// The settings key. A plain click keeps the key it had before bindings existed.
    public var storageKey: String {
        switch self {
        case .button(let number, let profile, .click): return "button.\(profile.rawValue).\(number)"
        case .button(let number, let profile, .hold): return "buttonHold.\(profile.rawValue).\(number)"
        case .button(let number, let profile, .doubleClick): return "buttonDouble.\(profile.rawValue).\(number)"
        case .touch(let gesture): return "touch.\(gesture.rawValue)"
        case .character(let gesture): return "character.\(gesture.rawValue)"
        }
    }

    public var defaultBinding: ActionBinding {
        switch self {
        case .button(let number, let profile, .click): return .builtin(profile.defaultActions[number] ?? .disabled)
        case .button: return .disabled
        case .touch(let gesture): return .builtin(gesture.defaultAction)
        case .character(let gesture): return .builtin(gesture.defaultAction)
        }
    }

    /// Move / resize follows fingers that stay down, which only some gestures can offer.
    /// Every user-configured binding is a one-shot and fits anywhere.
    public func allows(_ binding: ActionBinding) -> Bool {
        guard let action = binding.builtinAction else { return true }
        switch self {
        case .button: return action.isAvailableForButtons
        case .touch(let gesture): return gesture.allows(action)
        case .character: return action != .moveResizeWindow
        }
    }
}
