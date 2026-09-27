import Foundation

/// Bindings that apply only while one app is frontmost, on top of the ones for all apps.
public struct AppOverride: Equatable {
    public var bundleID: String
    /// Only a label for the preferences window.
    public var name: String
    /// MouseNavigate stands aside entirely in this app: buttons, gestures and the keyboard
    /// cursor, which matters in games, virtual machines and remote desktops.
    public var isDisabled: Bool
    /// Trigger storage key to binding storage value, in the same form as the global
    /// settings, so an entry never needs a format of its own.
    public var bindings: [String: String]

    public init(bundleID: String, name: String, isDisabled: Bool = false, bindings: [String: String] = [:]) {
        self.bundleID = bundleID
        self.name = name
        self.isDisabled = isDisabled
        self.bindings = bindings
    }

    /// Unreadable values are treated as absent, so a bad entry falls through to the global
    /// binding rather than disabling the trigger.
    public func binding(for trigger: BindingTrigger) -> ActionBinding? {
        guard let raw = bindings[trigger.storageKey],
              let binding = ActionBinding(storageValue: raw),
              trigger.allows(binding)
        else {
            return nil
        }
        return binding
    }

    // MARK: - Property list

    public var propertyList: [String: Any] {
        ["name": name, "disabled": isDisabled, "bindings": bindings]
    }

    public init?(bundleID: String, propertyList: Any) {
        guard !bundleID.isEmpty, let dictionary = propertyList as? [String: Any] else { return nil }
        self.bundleID = bundleID
        name = dictionary["name"] as? String ?? bundleID
        isDisabled = dictionary["disabled"] as? Bool ?? false
        bindings = dictionary["bindings"] as? [String: String] ?? [:]
    }

    /// Every entry that reads cleanly; the rest are dropped rather than failing the lot.
    public static func decodeAll(_ propertyList: Any?) -> [String: AppOverride] {
        guard let dictionary = propertyList as? [String: Any] else { return [:] }
        var result: [String: AppOverride] = [:]
        for (bundleID, value) in dictionary {
            if let entry = AppOverride(bundleID: bundleID, propertyList: value) {
                result[bundleID] = entry
            }
        }
        return result
    }

    public static func encodeAll(_ overrides: [String: AppOverride]) -> [String: Any] {
        overrides.mapValues(\.propertyList)
    }
}

/// Decides which binding a trigger runs with a given app in front.
public enum BindingResolver {
    /// The frontmost app's own binding first, then the one for all apps. An app with
    /// MouseNavigate turned off gets nothing at all.
    public static func resolve(
        _ trigger: BindingTrigger,
        frontmost bundleID: String?,
        overrides: [String: AppOverride],
        global: (BindingTrigger) -> ActionBinding
    ) -> ActionBinding {
        if let bundleID, let entry = overrides[bundleID] {
            if entry.isDisabled {
                return .disabled
            }
            if let binding = entry.binding(for: trigger) {
                return binding
            }
        }
        return global(trigger)
    }
}
