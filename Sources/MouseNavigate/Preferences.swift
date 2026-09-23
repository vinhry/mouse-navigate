import Foundation
import MouseNavigateCore

/// Where drawn characters can come from.
enum CharacterSource: String, CaseIterable {
    case trackpad
    case magicMouseRightDrag
    case middleButtonDrag

    var displayName: String {
        switch self {
        case .trackpad: return "Draw with two spread fingers on the trackpad"
        case .magicMouseRightDrag: return "Draw while holding the right button (Magic Mouse)"
        case .middleButtonDrag: return "Draw while holding the middle button"
        }
    }

    /// Button drags hold back the click until release, which delays context menus, so they
    /// stay off until asked for.
    var isEnabledByDefault: Bool {
        self == .trackpad
    }
}

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

    // MARK: - Touch gestures

    /// Off until the user opts in: the gestures run alongside macOS's own and can overlap.
    var isTouchEnabled: Bool {
        get { store.object(forKey: "touchEnabled") as? Bool ?? false }
        set {
            store.set(newValue, forKey: "touchEnabled")
            notifyChange()
        }
    }

    var isLeftHanded: Bool {
        get { store.bool(forKey: "touchLeftHanded") }
        set {
            store.set(newValue, forKey: "touchLeftHanded")
            notifyChange()
        }
    }

    func touchAction(for gesture: TouchGesture) -> ButtonAction {
        guard let raw = store.string(forKey: "touch.\(gesture.rawValue)"),
              let action = ButtonAction(rawValue: raw),
              gesture.allows(action)
        else {
            return gesture.defaultAction
        }
        return action
    }

    func setTouchAction(_ action: ButtonAction, for gesture: TouchGesture) {
        store.set(action.rawValue, forKey: "touch.\(gesture.rawValue)")
        notifyChange()
    }

    // MARK: - Character gestures

    func characterAction(for gesture: CharacterGesture) -> ButtonAction {
        guard let raw = store.string(forKey: "character.\(gesture.rawValue)"),
              let action = ButtonAction(rawValue: raw),
              action != .moveResizeWindow
        else {
            return gesture.defaultAction
        }
        return action
    }

    func setCharacterAction(_ action: ButtonAction, for gesture: CharacterGesture) {
        store.set(action.rawValue, forKey: "character.\(gesture.rawValue)")
        notifyChange()
    }

    /// Whether the stroke is drawn on screen as it is made.
    var showsDrawingOverlay: Bool {
        get { store.object(forKey: "touchShowsDrawing") as? Bool ?? true }
        set {
            store.set(newValue, forKey: "touchShowsDrawing")
            notifyChange()
        }
    }

    /// How far apart the two fingers must be to draw rather than scroll, as a fraction of
    /// the trackpad's width.
    var characterDrawSpread: Double {
        get {
            let stored = store.object(forKey: "touchDrawSpread") as? Double ?? TouchTuning().drawSpread
            return TouchTuning.clampDrawSpread(stored)
        }
        set {
            store.set(TouchTuning.clampDrawSpread(newValue), forKey: "touchDrawSpread")
            notifyChange()
        }
    }

    func isCharacterSourceEnabled(_ source: CharacterSource) -> Bool {
        store.object(forKey: "characterSource.\(source.rawValue)") as? Bool ?? source.isEnabledByDefault
    }

    func setCharacterSource(_ source: CharacterSource, enabled: Bool) {
        store.set(enabled, forKey: "characterSource.\(source.rawValue)")
        notifyChange()
    }

    /// Reset every gesture binding and touch option; mouse buttons and cursor keys are untouched.
    func restoreTouchDefaults() {
        for gesture in TouchGesture.allCases {
            store.removeObject(forKey: "touch.\(gesture.rawValue)")
        }
        for gesture in CharacterGesture.allCases {
            store.removeObject(forKey: "character.\(gesture.rawValue)")
        }
        for source in CharacterSource.allCases {
            store.removeObject(forKey: "characterSource.\(source.rawValue)")
        }
        store.removeObject(forKey: "touchLeftHanded")
        store.removeObject(forKey: "touchShowsDrawing")
        store.removeObject(forKey: "touchDrawSpread")
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
    }
}
