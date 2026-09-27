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
        // Not a suite: the app's own bundle identifier is not a valid suite name, so
        // `UserDefaults(suiteName:)` returned nil here and logged "does not make sense and
        // will not work" on every terminal run. The fallback was already what ran, and it
        // reads the same ~/Library/Preferences/com.vinhry.MouseNavigate.plist.
        store = .standard
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

            let newKey = BindingTrigger.button(button, .mxMaster4).storageKey
            if store.string(forKey: newKey) == nil {
                store.set(raw, forKey: newKey)
            }
            store.removeObject(forKey: legacyKey)
        }

        store.set(currentConfigVersion, forKey: "configVersion")
    }

    // MARK: - Device profile

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

    // MARK: - Bindings

    /// What `trigger` runs with `bundleID` in front: that app's own binding, then the one
    /// for all apps.
    func binding(for trigger: BindingTrigger, app bundleID: String?) -> ActionBinding {
        BindingResolver.resolve(
            trigger,
            frontmost: bundleID,
            overrides: appOverrides,
            global: globalBinding(for:)
        )
    }

    /// The binding for all apps, or the trigger's default when none is stored or the
    /// stored one cannot be read.
    func globalBinding(for trigger: BindingTrigger) -> ActionBinding {
        guard let raw = store.string(forKey: trigger.storageKey),
              let binding = ActionBinding(storageValue: raw),
              trigger.allows(binding)
        else {
            return trigger.defaultBinding
        }
        return binding
    }

    func setGlobalBinding(_ binding: ActionBinding, for trigger: BindingTrigger) {
        store.set(binding.storageValue, forKey: trigger.storageKey)
        notifyChange()
    }

    // MARK: - Per-app bindings

    private static let appOverridesKey = "appOverrides"

    /// Keyed by bundle identifier.
    var appOverrides: [String: AppOverride] {
        AppOverride.decodeAll(store.dictionary(forKey: Preferences.appOverridesKey))
    }

    private func saveAppOverrides(_ overrides: [String: AppOverride]) {
        store.set(AppOverride.encodeAll(overrides), forKey: Preferences.appOverridesKey)
        notifyChange()
    }

    /// Apps with bindings of their own, by name.
    var overriddenApps: [AppOverride] {
        appOverrides.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func addApp(bundleID: String, name: String) {
        var overrides = appOverrides
        guard overrides[bundleID] == nil else { return }
        overrides[bundleID] = AppOverride(bundleID: bundleID, name: name)
        saveAppOverrides(overrides)
    }

    func removeApp(bundleID: String) {
        var overrides = appOverrides
        overrides[bundleID] = nil
        saveAppOverrides(overrides)
    }

    func isAppDisabled(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appOverrides[bundleID]?.isDisabled ?? false
    }

    func setApp(_ bundleID: String, disabled: Bool) {
        var overrides = appOverrides
        guard overrides[bundleID] != nil else { return }
        overrides[bundleID]?.isDisabled = disabled
        saveAppOverrides(overrides)
    }

    /// nil means the app follows the binding for all apps.
    func appBinding(for trigger: BindingTrigger, app bundleID: String) -> ActionBinding? {
        appOverrides[bundleID]?.binding(for: trigger)
    }

    /// Hands every trigger whose key passes `matching` back to the binding for all apps.
    func clearAppBindings(app bundleID: String, matching: (String) -> Bool) {
        var overrides = appOverrides
        guard let bindings = overrides[bundleID]?.bindings else { return }
        overrides[bundleID]?.bindings = bindings.filter { !matching($0.key) }
        saveAppOverrides(overrides)
    }

    func setAppBinding(_ binding: ActionBinding?, for trigger: BindingTrigger, app bundleID: String) {
        var overrides = appOverrides
        guard overrides[bundleID] != nil else { return }
        overrides[bundleID]?.bindings[trigger.storageKey] = binding?.storageValue
        saveAppOverrides(overrides)
    }

    // MARK: - Scroll wheel

    var scrollSettings: ScrollSettings {
        get {
            ScrollSettings(
                isReversed: store.bool(forKey: "scroll.reversed"),
                speed: store.object(forKey: "scroll.speed") as? Double ?? 1,
                isSmooth: store.bool(forKey: "scroll.smooth")
            )
        }
        set {
            store.set(newValue.isReversed, forKey: "scroll.reversed")
            store.set(newValue.speed, forKey: "scroll.speed")
            store.set(newValue.isSmooth, forKey: "scroll.smooth")
            notifyChange()
        }
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

    // MARK: - Character gestures

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
            store.removeObject(forKey: BindingTrigger.touch(gesture).storageKey)
        }
        for gesture in CharacterGesture.allCases {
            store.removeObject(forKey: BindingTrigger.character(gesture).storageKey)
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
