import Foundation

/// Every key MouseNavigate writes to its UserDefaults domain, in one place.
///
/// Settings are flat keys. Most are fixed; bindings and cursor keys form families that
/// share a prefix. Knowing every key and its type is what lets the settings be exported,
/// imported with their values checked, and reset without a list to keep by hand.
public enum SettingsKey {
    /// The property-list type a key holds. Numbers are told apart by the registry, not
    /// by the value: a `1` in a file means a bool for a bool key and a double for a
    /// double key.
    public enum ValueType: Equatable, Sendable {
        case bool, int, double, string, dictionary, date
    }

    // MARK: - Fixed keys

    public static let configVersion = "configVersion"
    public static let deviceOverride = "deviceOverride"
    public static let appOverrides = "appOverrides"
    /// Written by versions before 3, which had one reverse switch and one speed.
    public static let legacyScrollReversed = "scroll.reversed"
    public static let legacyScrollSpeed = "scroll.speed"
    public static let cursorModeEnabled = "cursorModeEnabled"
    public static let touchEnabled = "touchEnabled"
    public static let touchLeftHanded = "touchLeftHanded"
    public static let touchShowsDrawing = "touchShowsDrawing"
    public static let touchDrawSpread = "touchDrawSpread"
    public static let automaticUpdates = "update.automatic"
    /// When the updater last asked GitHub. Bookkeeping, not a setting: never exported.
    public static let lastUpdateCheck = "update.lastCheck"
    /// The Welcome window has been seen through, or was never needed. Bookkeeping too.
    public static let onboardingCompleted = "onboarding.completed"

    /// Keys this Mac keeps for itself: never exported, and kept when settings are imported,
    /// since another Mac's answer means nothing here.
    public static let bookkeeping: Set<String> = [lastUpdateCheck, onboardingCompleted]

    /// "scroll.<field>" for all mice, "scroll.<profile>.<field>" for one mouse model.
    public static func scroll(_ field: ScrollField, profile: DeviceProfile? = nil) -> String {
        if let profile {
            return "scroll.\(profile.rawValue).\(field.rawValue)"
        }
        return "scroll.\(field.rawValue)"
    }

    /// "pointer.<field>" for all mice, "pointer.<profile>.<field>" for one mouse model.
    public static func pointer(_ field: PointerField, profile: DeviceProfile? = nil) -> String {
        if let profile {
            return "pointer.\(profile.rawValue).\(field.rawValue)"
        }
        return "pointer.\(field.rawValue)"
    }

    public static let fixed: [String: ValueType] = {
        var keys: [String: ValueType] = [
            configVersion: .int,
            deviceOverride: .string,
            appOverrides: .dictionary,
            cursorModeEnabled: .bool,
            touchEnabled: .bool,
            touchLeftHanded: .bool,
            touchShowsDrawing: .bool,
            touchDrawSpread: .double,
            automaticUpdates: .bool,
            lastUpdateCheck: .date,
            onboardingCompleted: .bool,
        ]
        for field in ScrollField.allCases {
            keys[scroll(field)] = field.valueType
            for profile in DeviceProfile.allCases {
                keys[scroll(field, profile: profile)] = field.valueType
            }
        }
        for field in PointerField.allCases {
            keys[pointer(field)] = field.valueType
            for profile in DeviceProfile.allCases {
                keys[pointer(field, profile: profile)] = field.valueType
            }
        }
        return keys
    }()

    // MARK: - Families

    /// A set of keys that share a prefix and a type.
    public struct Family: Equatable, Sendable {
        public let prefix: String
        public let type: ValueType

        public func contains(_ key: String) -> Bool {
            key.count > prefix.count && key.hasPrefix(prefix)
        }
    }

    public static let buttonPrefix = "button."
    public static let buttonHoldPrefix = "buttonHold."
    public static let buttonDoublePrefix = "buttonDouble."
    public static let buttonDragPrefix = "buttonDrag."
    public static let touchPrefix = "touch."
    public static let characterPrefix = "character."
    public static let cursorKeyPrefix = "key."
    public static let cursorSettingPrefix = "cursor."
    public static let characterSourcePrefix = "characterSource."

    public static let families: [Family] = [
        Family(prefix: buttonPrefix, type: .string),
        Family(prefix: buttonHoldPrefix, type: .string),
        Family(prefix: buttonDoublePrefix, type: .string),
        Family(prefix: buttonDragPrefix, type: .string),
        Family(prefix: touchPrefix, type: .string),
        Family(prefix: characterPrefix, type: .string),
        Family(prefix: cursorKeyPrefix, type: .int),
        Family(prefix: cursorSettingPrefix, type: .double),
        Family(prefix: characterSourcePrefix, type: .bool),
    ]

    public static func cursorKey(_ binding: CursorBinding) -> String {
        cursorKeyPrefix + binding.rawValue
    }

    public static func cursorSetting(_ setting: CursorSetting) -> String {
        cursorSettingPrefix + setting.rawValue
    }

    public static func characterSource(_ source: CharacterSource) -> String {
        characterSourcePrefix + source.rawValue
    }

    // MARK: - Legacy

    /// Keys an older version wrote. A file holding them can still be imported, since the
    /// migration that follows knows what to do with them; they are never exported.
    public static let legacy: [String: ValueType] = {
        var keys: [String: ValueType] = [legacyScrollReversed: .bool, legacyScrollSpeed: .double]
        for number in 3...9 {
            keys[legacyButton(number)] = .string
        }
        return keys
    }()

    /// Version 1 stored one global mapping under "button<n>".
    public static func legacyButton(_ number: Int) -> String {
        "button\(number)"
    }

    // MARK: - Lookup

    public static func type(of key: String) -> ValueType? {
        if let type = fixed[key] { return type }
        if let family = families.first(where: { $0.contains(key) }) { return family.type }
        return legacy[key]
    }

    /// Whether `key` is one of ours at all, current or legacy.
    public static func isSetting(_ key: String) -> Bool {
        type(of: key) != nil
    }

    public static func isExportable(_ key: String) -> Bool {
        guard legacy[key] == nil, !bookkeeping.contains(key) else { return false }
        return fixed[key] != nil || families.contains { $0.contains(key) }
    }

    /// The keys MouseNavigate wrote to `store`, and nothing the global domain or another
    /// app put there.
    public static func userSettingKeys(in store: UserDefaults) -> [String] {
        store.dictionaryRepresentation().keys.filter(isSetting).sorted()
    }
}
