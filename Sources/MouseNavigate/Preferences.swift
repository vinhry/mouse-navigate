import Foundation
import MouseNavigateCore

/// UserDefaults-backed settings shared by the daemon and the preferences window.
final class Preferences {
    static let shared = Preferences()

    static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.preferencesDidChange")

    /// Buttons the preferences window offers. CGEvent numbers 0-2 are the primary,
    /// secondary and middle buttons, which are left alone.
    static let configurableButtons = Array(3...9)

    private let store: UserDefaults
    private let currentConfigVersion = 2

    private init() {
        store = UserDefaults(suiteName: "com.vinhry.MouseNavigate") ?? .standard
        migrateIfNeeded()
    }

    // MARK: - Migration

    /// v1 stored a single global mapping under "button<n>". Those values came from the
    /// MX Master 4, so they seed that profile and the old keys are cleared.
    private func migrateIfNeeded() {
        guard store.integer(forKey: "configVersion") < currentConfigVersion else { return }

        for button in Preferences.configurableButtons {
            let legacyKey = "button\(button)"
            guard let raw = store.string(forKey: legacyKey) else { continue }

            let newKey = buttonKey(profile: .mxMaster4, button: button)
            if store.string(forKey: newKey) == nil {
                store.set(raw, forKey: newKey)
            }
            store.removeObject(forKey: legacyKey)
        }

        store.set(currentConfigVersion, forKey: "configVersion")
    }

    // MARK: - Device profile

    private func buttonKey(profile: DeviceProfile, button: Int) -> String {
        "button.\(profile.rawValue).\(button)"
    }

    /// nil means "auto" — follow whatever the detector reports.
    var deviceOverride: DeviceProfile? {
        get {
            guard let raw = store.string(forKey: "deviceOverride") else { return nil }
            return DeviceProfile(rawValue: raw)
        }
        set {
            if let newValue {
                store.set(newValue.rawValue, forKey: "deviceOverride")
            } else {
                store.removeObject(forKey: "deviceOverride")
            }
            notifyChange()
        }
    }

    // MARK: - Button mapping

    func action(forButton button: Int, profile: DeviceProfile) -> ButtonAction {
        guard let raw = store.string(forKey: buttonKey(profile: profile, button: button)),
              let action = ButtonAction(rawValue: raw)
        else {
            return profile.defaultActions[button] ?? .disabled
        }
        return action
    }

    func setAction(_ action: ButtonAction, forButton button: Int, profile: DeviceProfile) {
        store.set(action.rawValue, forKey: buttonKey(profile: profile, button: button))
        notifyChange()
    }

    // MARK: - Keyboard cursor

    var isCursorModeEnabled: Bool {
        get { store.object(forKey: "cursorModeEnabled") as? Bool ?? true }
        set {
            store.set(newValue, forKey: "cursorModeEnabled")
            notifyChange()
        }
    }

    func keyCode(for binding: CursorBinding) -> UInt16 {
        guard let stored = store.object(forKey: "key.\(binding.rawValue)") as? Int,
              let keyCode = UInt16(exactly: stored)
        else {
            return binding.defaultKeyCode
        }
        return keyCode
    }

    func setKeyCode(_ keyCode: UInt16, for binding: CursorBinding) {
        store.set(Int(keyCode), forKey: "key.\(binding.rawValue)")
        notifyChange()
    }

    func value(for setting: CursorSetting) -> Double {
        guard let stored = store.object(forKey: "cursor.\(setting.rawValue)") as? Double else {
            return setting.defaultValue
        }
        return setting.clamp(stored)
    }

    func setValue(_ value: Double, for setting: CursorSetting) {
        store.set(setting.clamp(value), forKey: "cursor.\(setting.rawValue)")
        notifyChange()
    }

    func speedProfile() -> CursorSpeedProfile {
        CursorSpeedProfile(
            baseSpeed: value(for: .baseSpeed),
            maxSpeed: value(for: .maxSpeed),
            acceleration: value(for: .acceleration),
            fastMultiplier: value(for: .fastMultiplier),
            fasterMultiplier: value(for: .fasterMultiplier),
            precisionMultiplier: value(for: .precisionMultiplier),
            scrollSpeed: value(for: .scrollSpeed)
        )
    }

    /// Reset only the cursor-mode keys and tunables; button mappings are untouched.
    func restoreCursorDefaults() {
        for binding in CursorBinding.allCases {
            store.removeObject(forKey: "key.\(binding.rawValue)")
        }
        for setting in CursorSetting.allCases {
            store.removeObject(forKey: "cursor.\(setting.rawValue)")
        }
        store.removeObject(forKey: "cursorModeEnabled")
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
    }
}
