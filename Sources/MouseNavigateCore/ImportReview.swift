import Foundation

/// What a settings file would make inputs do beyond the built-in actions, so it can be
/// shown before the file is imported.
///
/// A custom action presses keys, opens an app or a link, or runs a shortcut, and a file
/// from someone else can tie one to a button the user presses all day, or hide it in one
/// app's bindings. Built-in actions are left out: they are what the pickers offer anyway.
extension SettingsSnapshot {
    public struct CustomAction: Equatable {
        /// The settings key: a global one, or one inside the app's bindings.
        public var key: String
        /// The app the binding applies in, nil for all apps.
        public var bundleID: String?
        public var binding: ActionBinding

        /// Where it is bound, as the preferences window names it, or the bare key for one
        /// that names no trigger, such as a key from an older version.
        public var trigger: String {
            SettingsSnapshot.displayable(BindingTrigger(storageKey: key)?.displayName ?? key)
        }

        /// What it does, with the whole URL and the app's bundle ID.
        public var action: String {
            SettingsSnapshot.displayable(binding.fullDescription)
        }

        /// One line of the list: "Trackpad: Three-Finger Tap in com.example.app → Shortcut ⌘Q".
        public var summary: String {
            let place = bundleID.map { "\(trigger) in \(SettingsSnapshot.displayable($0))" } ?? trigger
            return "\(place) → \(action)"
        }
    }

    /// Every custom action in the snapshot: the ones for all apps first, then each app's,
    /// by bundle ID, each group in key order so the list reads the same every time.
    public var customActions: [CustomAction] {
        var global: [CustomAction] = []
        for (key, value) in values where key != SettingsKey.appOverrides {
            if let binding = SettingsSnapshot.customBinding(value) {
                global.append(CustomAction(key: key, bundleID: nil, binding: binding))
            }
        }

        var perApp: [CustomAction] = []
        for (bundleID, bindings) in appBindings {
            for (key, value) in bindings {
                if let binding = SettingsSnapshot.customBinding(value) {
                    perApp.append(CustomAction(key: key, bundleID: bundleID, binding: binding))
                }
            }
        }

        return global.sorted { $0.key < $1.key }
            + perApp.sorted { ($0.bundleID ?? "", $0.key) < ($1.bundleID ?? "", $1.key) }
    }

    /// The snapshot with every custom action taken out and everything else as it was. The
    /// keys are simply left out: `apply` removes whatever the snapshot lacks, so a global
    /// trigger goes back to its default, and an app's trigger goes back to following the
    /// binding for all apps (itself default if it was custom too).
    public func withoutCustomActions() -> SettingsSnapshot {
        var copy = self
        copy.values = values.filter { $0.key == SettingsKey.appOverrides || SettingsSnapshot.customBinding($0.value) == nil }

        if case .dictionary(let apps) = values[SettingsKey.appOverrides] {
            copy.values[SettingsKey.appOverrides] = .dictionary(apps.mapValues { entry in
                guard case .dictionary(var fields) = entry,
                      case .dictionary(let bindings) = fields["bindings"]
                else {
                    return entry
                }
                fields["bindings"] = .dictionary(bindings.filter { SettingsSnapshot.customBinding($0.value) == nil })
                return .dictionary(fields)
            })
        }
        return copy
    }

    /// Each app's bindings, as `AppOverride` would read them.
    private var appBindings: [(bundleID: String, bindings: [String: SettingsValue])] {
        guard case .dictionary(let apps) = values[SettingsKey.appOverrides] else { return [] }
        return apps.compactMap { bundleID, entry in
            guard case .dictionary(let fields) = entry, case .dictionary(let bindings) = fields["bindings"] else {
                return nil
            }
            return (bundleID, bindings)
        }
    }

    /// A value that reads back, the same way the event tap reads it, as something other
    /// than a built-in action. Any string key counts, not only the binding families: a
    /// custom action anywhere is shown, and one where nothing reads it is harmless to drop.
    private static func customBinding(_ value: SettingsValue) -> ActionBinding? {
        guard case .string(let raw) = value, let binding = ActionBinding(storageValue: raw), binding.isCustom else {
            return nil
        }
        return binding
    }

    /// Text from the file made safe to show in a list: a line break or a right-to-left
    /// override could otherwise make one entry look like another, or like nothing.
    static func displayable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            default:
                if !bidiControls.contains(scalar.value) {
                    scalars.append(scalar)
                }
            }
        }
        return String(scalars)
    }

    private static let bidiControls = Set<UInt32>([0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))
}

extension SettingsSnapshot.ReadResult {
    /// The same file without its custom actions, which are named nowhere afterwards: the
    /// caller already listed them when it asked.
    public func withoutCustomActions() -> SettingsSnapshot.ReadResult {
        SettingsSnapshot.ReadResult(snapshot: snapshot.withoutCustomActions(), ignoredKeys: ignoredKeys)
    }
}
