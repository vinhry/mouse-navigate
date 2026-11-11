import Foundation

/// What a button, gesture or drawn character is bound to: one of the built-in actions, or
/// one the user configured with a value of its own.
public enum ActionBinding: Equatable, Sendable {
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

    /// Anything but a built-in action: a keystroke, an app, a link or a shortcut, each of
    /// which can do whatever the value it carries says.
    public var isCustom: Bool {
        builtinAction == nil
    }

    /// What the binding does with nothing left out, for the user to check before taking a
    /// binding from a file: the whole URL rather than its host, and the app's bundle ID,
    /// since the name beside it is only a label the file supplies.
    public var fullDescription: String {
        switch self {
        case .openURL(let url): return "Open \(url.absoluteString)"
        case .launchApp(let bundleID, let name) where name != bundleID: return "Launch \(name) (\(bundleID))"
        default: return displayName
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

    /// Whether a link goes where people expect links to go.
    public enum LinkKind: Equatable, Sendable {
        /// A web page or a new email, opened in the browser or mail app.
        case ordinary
        /// Handed to whichever app claims the scheme, which can be anything: `file:` opens
        /// or runs a file, `smb:` mounts a share, `shortcuts:` runs a shortcut. Lowercased.
        case other(scheme: String)
        /// Not a URL `validURL` accepts.
        case invalid
    }

    public static let ordinarySchemes: Set<String> = ["http", "https", "mailto"]

    /// Read the way `validURL` reads the text, so a bare host counts as the web address it
    /// becomes. Schemes are case-insensitive, so "HTTPS:" is ordinary.
    public static func linkKind(of text: String) -> LinkKind {
        guard let url = validURL(text) else { return .invalid }
        return linkKind(of: url)
    }

    public static func linkKind(of url: URL) -> LinkKind {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .invalid }
        return ordinarySchemes.contains(scheme) ? .ordinary : .other(scheme: scheme)
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
public enum ButtonPress: String, CaseIterable, Sendable {
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

/// Something that can be bound: a mouse button press on one device profile, with or
/// without modifier keys held, a touch gesture or a drawn character.
public enum BindingTrigger: Hashable {
    case button(Int, DeviceProfile, ButtonPress = .click, Shortcut.Modifiers = [])
    /// A side button held while the mouse is moved that way.
    case buttonDrag(Int, DeviceProfile, DragDirection, Shortcut.Modifiers = [])
    case touch(TouchGesture)
    case character(CharacterGesture)

    /// The trigger for whatever a button was asked to do.
    public static func button(_ number: Int, _ profile: DeviceProfile, input: ButtonInput, modifiers: Shortcut.Modifiers = []) -> BindingTrigger {
        switch input {
        case .press(let press): return .button(number, profile, press, modifiers)
        case .drag(let direction): return .buttonDrag(number, profile, direction, modifiers)
        }
    }

    /// The settings key. A plain click keeps the key it had before bindings existed;
    /// modifiers add a suffix, "button.mxMaster4.3+shift+cmd" for ⇧⌘ and button 3.
    public var storageKey: String {
        switch self {
        case .button(let number, let profile, let press, let modifiers):
            let prefix: String
            switch press {
            case .click: prefix = SettingsKey.buttonPrefix
            case .hold: prefix = SettingsKey.buttonHoldPrefix
            case .doubleClick: prefix = SettingsKey.buttonDoublePrefix
            }
            return "\(prefix)\(profile.rawValue).\(number)\(modifiers.storageSuffix)"
        case .buttonDrag(let number, let profile, let direction, let modifiers):
            return "\(SettingsKey.buttonDragPrefix)\(profile.rawValue).\(number).\(direction.rawValue)\(modifiers.storageSuffix)"
        case .touch(let gesture): return SettingsKey.touchPrefix + gesture.rawValue
        case .character(let gesture): return SettingsKey.characterPrefix + gesture.rawValue
        }
    }

    /// The trigger a settings key belongs to, so a key read from a file can be named. Only
    /// a key written exactly as `storageKey` writes it counts: anything else is a key
    /// nothing looks up.
    public init?(storageKey key: String) {
        let trigger: BindingTrigger?
        if let rest = key.dropPrefix(SettingsKey.touchPrefix) {
            trigger = TouchGesture(rawValue: rest).map { .touch($0) }
        } else if let rest = key.dropPrefix(SettingsKey.characterPrefix) {
            trigger = CharacterGesture(rawValue: rest).map { .character($0) }
        } else if let rest = key.dropPrefix(SettingsKey.buttonDragPrefix) {
            trigger = BindingTrigger.parseButton(rest, hasDirection: true, press: .click)
        } else if let rest = key.dropPrefix(SettingsKey.buttonHoldPrefix) {
            trigger = BindingTrigger.parseButton(rest, hasDirection: false, press: .hold)
        } else if let rest = key.dropPrefix(SettingsKey.buttonDoublePrefix) {
            trigger = BindingTrigger.parseButton(rest, hasDirection: false, press: .doubleClick)
        } else if let rest = key.dropPrefix(SettingsKey.buttonPrefix) {
            trigger = BindingTrigger.parseButton(rest, hasDirection: false, press: .click)
        } else {
            trigger = nil
        }
        guard let trigger, trigger.storageKey == key else { return nil }
        self = trigger
    }

    /// "<profile>.<number>[.<direction>][+modifiers]".
    private static func parseButton(_ text: String, hasDirection: Bool, press: ButtonPress) -> BindingTrigger? {
        let modifierStart = text.firstIndex(of: "+") ?? text.endIndex
        guard let modifiers = Shortcut.Modifiers(storageSuffix: String(text[modifierStart...])) else { return nil }
        let parts = text[..<modifierStart].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == (hasDirection ? 3 : 2),
              let profile = DeviceProfile(rawValue: String(parts[0])),
              let number = Int(parts[1]), number >= 0
        else {
            return nil
        }
        if hasDirection {
            guard let direction = DragDirection(rawValue: String(parts[2])) else { return nil }
            return .buttonDrag(number, profile, direction, modifiers)
        }
        return .button(number, profile, press, modifiers)
    }

    /// The trigger as the preferences window names it, with the mouse model or surface
    /// first: "Logitech MX Master 4: ⇧⌘ Button 5 Hold", "Trackpad: Three-Finger Tap".
    public var displayName: String {
        switch self {
        case .button(let number, let profile, let press, let modifiers):
            return BindingTrigger.buttonName(number, profile, input: .press(press), modifiers: modifiers)
        case .buttonDrag(let number, let profile, let direction, let modifiers):
            return BindingTrigger.buttonName(number, profile, input: .drag(direction), modifiers: modifiers)
        case .touch(let gesture):
            return "\(gesture.surface.displayName): \(gesture.displayName)"
        case .character(let gesture):
            return "Drawing: \(gesture.displayName)"
        }
    }

    private static func buttonName(_ number: Int, _ profile: DeviceProfile, input: ButtonInput, modifiers: Shortcut.Modifiers) -> String {
        let button = LogitechControl(button: number)?.displayName ?? "Button \(number)"
        let held = modifiers.isEmpty ? "" : modifiers.symbols + " "
        return "\(profile.displayName): \(held)\(button) \(input.displayName)"
    }

    /// A combination with modifiers starts unbound: the plain button's binding stands in
    /// for it until it is given one of its own.
    public var defaultBinding: ActionBinding {
        switch self {
        case .button(let number, let profile, .click, let modifiers) where modifiers.isEmpty:
            return .builtin(profile.defaultActions[number] ?? .disabled)
        case .button, .buttonDrag: return .disabled
        case .touch(let gesture): return .builtin(gesture.defaultAction)
        case .character(let gesture): return .builtin(gesture.defaultAction)
        }
    }

    /// Move / resize follows fingers that stay down, which only some gestures can offer.
    /// Every user-configured binding is a one-shot and fits anywhere.
    public func allows(_ binding: ActionBinding) -> Bool {
        guard let action = binding.builtinAction else { return true }
        switch self {
        case .button, .buttonDrag: return action.isAvailableForButtons
        case .touch(let gesture): return gesture.allows(action)
        case .character: return action != .moveResizeWindow
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
