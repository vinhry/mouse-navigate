import Foundation

/// UserDefaults-backed settings shared by the daemon and the preferences window.
///
/// Main thread only: the event tap, the preferences window and the touch monitor's
/// gesture handling all run there, and the cache below is not locked.
public final class Preferences {
    public static let shared = Preferences(store: .standard)

    public static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.preferencesDidChange")
    /// `userInfo` key carrying the `SettingsArea` that changed.
    public static let areaUserInfoKey = "area"

    /// Buttons the preferences window offers. CGEvent numbers 0-2 are the primary,
    /// secondary and middle buttons, which are left alone.
    public static let configurableButtons = Array(3...9)

    private let store: UserDefaults
    let currentConfigVersion = 2

    /// The app uses `.standard`, not a suite: its own bundle identifier is not a valid
    /// suite name, so `UserDefaults(suiteName:)` returned nil and logged "does not make
    /// sense and will not work" on every terminal run. The fallback was already what ran,
    /// and it reads the same ~/Library/Preferences/com.vinhry.MouseNavigate.plist. Tests
    /// pass a suite of their own.
    public init(store: UserDefaults) {
        self.store = store
        migrateIfNeeded()
    }

    // MARK: - Migration

    /// v1 stored a single global mapping under "button<n>". Those values came from the
    /// MX Master 4, so they seed that profile and the old keys are cleared.
    func migrateIfNeeded() {
        guard store.integer(forKey: SettingsKey.configVersion) < currentConfigVersion else { return }

        for button in Preferences.configurableButtons {
            let legacyKey = SettingsKey.legacyButton(button)
            guard let raw = store.string(forKey: legacyKey) else { continue }

            let newKey = BindingTrigger.button(button, .mxMaster4).storageKey
            if store.string(forKey: newKey) == nil {
                store.set(raw, forKey: newKey)
            }
            store.removeObject(forKey: legacyKey)
        }

        store.set(currentConfigVersion, forKey: SettingsKey.configVersion)
    }

    // MARK: - Device profile

    /// nil means "auto" — follow whatever the detector reports.
    public var deviceOverride: DeviceProfile? {
        get {
            guard let raw = store.string(forKey: SettingsKey.deviceOverride) else { return nil }
            return DeviceProfile(rawValue: raw)
        }
        set {
            if let newValue {
                store.set(newValue.rawValue, forKey: SettingsKey.deviceOverride)
            } else {
                store.removeObject(forKey: SettingsKey.deviceOverride)
            }
            notifyChange(.device)
        }
    }

    // MARK: - Bindings

    /// What `trigger` runs with `bundleID` in front: that app's own binding, then the one
    /// for all apps.
    public func binding(for trigger: BindingTrigger, app bundleID: String?) -> ActionBinding {
        BindingResolver.resolve(
            trigger,
            frontmost: bundleID,
            overrides: appOverrides,
            global: globalBinding(for:)
        )
    }

    /// The binding for all apps, or the trigger's default when none is stored or the
    /// stored one cannot be read.
    public func globalBinding(for trigger: BindingTrigger) -> ActionBinding {
        guard let raw = store.string(forKey: trigger.storageKey),
              let binding = ActionBinding(storageValue: raw),
              trigger.allows(binding)
        else {
            return trigger.defaultBinding
        }
        return binding
    }

    public func setGlobalBinding(_ binding: ActionBinding, for trigger: BindingTrigger) {
        store.set(binding.storageValue, forKey: trigger.storageKey)
        notifyChange(.bindings)
    }

    // MARK: - Per-app bindings

    /// Decoded once per change rather than on every press: a single button press asks
    /// for its hold, double-click and click bindings in turn.
    private var cachedAppOverrides: [String: AppOverride]?

    /// Keyed by bundle identifier.
    public var appOverrides: [String: AppOverride] {
        if let cachedAppOverrides {
            return cachedAppOverrides
        }
        let overrides = AppOverride.decodeAll(store.dictionary(forKey: SettingsKey.appOverrides))
        cachedAppOverrides = overrides
        return overrides
    }

    private func saveAppOverrides(_ overrides: [String: AppOverride]) {
        store.set(AppOverride.encodeAll(overrides), forKey: SettingsKey.appOverrides)
        notifyChange(.apps)
    }

    /// Apps with bindings of their own, by name.
    public var overriddenApps: [AppOverride] {
        appOverrides.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func addApp(bundleID: String, name: String) {
        var overrides = appOverrides
        guard overrides[bundleID] == nil else { return }
        overrides[bundleID] = AppOverride(bundleID: bundleID, name: name)
        saveAppOverrides(overrides)
    }

    public func removeApp(bundleID: String) {
        var overrides = appOverrides
        overrides[bundleID] = nil
        saveAppOverrides(overrides)
    }

    public func isAppDisabled(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appOverrides[bundleID]?.isDisabled ?? false
    }

    public func setApp(_ bundleID: String, disabled: Bool) {
        var overrides = appOverrides
        guard overrides[bundleID] != nil else { return }
        overrides[bundleID]?.isDisabled = disabled
        saveAppOverrides(overrides)
    }

    /// nil means the app follows the binding for all apps.
    public func appBinding(for trigger: BindingTrigger, app bundleID: String) -> ActionBinding? {
        appOverrides[bundleID]?.binding(for: trigger)
    }

    /// Hands every trigger whose key passes `matching` back to the binding for all apps.
    public func clearAppBindings(app bundleID: String, matching: (String) -> Bool) {
        var overrides = appOverrides
        guard let bindings = overrides[bundleID]?.bindings else { return }
        overrides[bundleID]?.bindings = bindings.filter { !matching($0.key) }
        saveAppOverrides(overrides)
    }

    public func setAppBinding(_ binding: ActionBinding?, for trigger: BindingTrigger, app bundleID: String) {
        var overrides = appOverrides
        guard overrides[bundleID] != nil else { return }
        overrides[bundleID]?.bindings[trigger.storageKey] = binding?.storageValue
        saveAppOverrides(overrides)
    }

    // MARK: - Scroll wheel

    public var scrollSettings: ScrollSettings {
        get {
            ScrollSettings(
                isReversed: store.bool(forKey: SettingsKey.scrollReversed),
                speed: store.object(forKey: SettingsKey.scrollSpeed) as? Double ?? 1,
                isSmooth: store.bool(forKey: SettingsKey.scrollSmooth)
            )
        }
        set {
            store.set(newValue.isReversed, forKey: SettingsKey.scrollReversed)
            store.set(newValue.speed, forKey: SettingsKey.scrollSpeed)
            store.set(newValue.isSmooth, forKey: SettingsKey.scrollSmooth)
            notifyChange(.scroll)
        }
    }

    // MARK: - Updates

    /// nil until the user has been asked, which happens once.
    public var automaticUpdates: Bool? {
        get { store.object(forKey: SettingsKey.automaticUpdates) as? Bool }
        set {
            store.set(newValue, forKey: SettingsKey.automaticUpdates)
            notifyChange(.updates)
        }
    }

    /// Not a setting, so it changes without telling anyone.
    public var lastUpdateCheck: Date? {
        get { store.object(forKey: SettingsKey.lastUpdateCheck) as? Date }
        set { store.set(newValue, forKey: SettingsKey.lastUpdateCheck) }
    }

    // MARK: - Keyboard cursor

    public var isCursorModeEnabled: Bool {
        get { store.object(forKey: SettingsKey.cursorModeEnabled) as? Bool ?? true }
        set {
            store.set(newValue, forKey: SettingsKey.cursorModeEnabled)
            notifyChange(.cursor)
        }
    }

    public func keyCode(for binding: CursorBinding) -> UInt16 {
        guard let stored = store.object(forKey: SettingsKey.cursorKey(binding)) as? Int,
              let keyCode = UInt16(exactly: stored)
        else {
            return binding.defaultKeyCode
        }
        return keyCode
    }

    public func setKeyCode(_ keyCode: UInt16, for binding: CursorBinding) {
        store.set(Int(keyCode), forKey: SettingsKey.cursorKey(binding))
        notifyChange(.cursor)
    }

    public func value(for setting: CursorSetting) -> Double {
        guard let stored = store.object(forKey: SettingsKey.cursorSetting(setting)) as? Double else {
            return setting.defaultValue
        }
        return setting.clamp(stored)
    }

    public func setValue(_ value: Double, for setting: CursorSetting) {
        store.set(setting.clamp(value), forKey: SettingsKey.cursorSetting(setting))
        notifyChange(.cursor)
    }

    public func speedProfile() -> CursorSpeedProfile {
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
    public func restoreCursorDefaults() {
        for binding in CursorBinding.allCases {
            store.removeObject(forKey: SettingsKey.cursorKey(binding))
        }
        for setting in CursorSetting.allCases {
            store.removeObject(forKey: SettingsKey.cursorSetting(setting))
        }
        store.removeObject(forKey: SettingsKey.cursorModeEnabled)
        notifyChange(.cursor)
    }

    // MARK: - Touch gestures

    /// Off until the user opts in: the gestures run alongside macOS's own and can overlap.
    public var isTouchEnabled: Bool {
        get { store.object(forKey: SettingsKey.touchEnabled) as? Bool ?? false }
        set {
            store.set(newValue, forKey: SettingsKey.touchEnabled)
            notifyChange(.touch)
        }
    }

    public var isLeftHanded: Bool {
        get { store.bool(forKey: SettingsKey.touchLeftHanded) }
        set {
            store.set(newValue, forKey: SettingsKey.touchLeftHanded)
            notifyChange(.touch)
        }
    }

    // MARK: - Character gestures

    /// Whether the stroke is drawn on screen as it is made.
    public var showsDrawingOverlay: Bool {
        get { store.object(forKey: SettingsKey.touchShowsDrawing) as? Bool ?? true }
        set {
            store.set(newValue, forKey: SettingsKey.touchShowsDrawing)
            notifyChange(.touch)
        }
    }

    /// How far apart the two fingers must be to draw rather than scroll, as a fraction of
    /// the trackpad's width.
    public var characterDrawSpread: Double {
        get {
            let stored = store.object(forKey: SettingsKey.touchDrawSpread) as? Double ?? TouchTuning().drawSpread
            return TouchTuning.clampDrawSpread(stored)
        }
        set {
            store.set(TouchTuning.clampDrawSpread(newValue), forKey: SettingsKey.touchDrawSpread)
            notifyChange(.touch)
        }
    }

    public func isCharacterSourceEnabled(_ source: CharacterSource) -> Bool {
        store.object(forKey: SettingsKey.characterSource(source)) as? Bool ?? source.isEnabledByDefault
    }

    public func setCharacterSource(_ source: CharacterSource, enabled: Bool) {
        store.set(enabled, forKey: SettingsKey.characterSource(source))
        notifyChange(.touch)
    }

    /// Reset every gesture binding and touch option; mouse buttons and cursor keys are untouched.
    public func restoreTouchDefaults() {
        for gesture in TouchGesture.allCases {
            store.removeObject(forKey: BindingTrigger.touch(gesture).storageKey)
        }
        for gesture in CharacterGesture.allCases {
            store.removeObject(forKey: BindingTrigger.character(gesture).storageKey)
        }
        for source in CharacterSource.allCases {
            store.removeObject(forKey: SettingsKey.characterSource(source))
        }
        store.removeObject(forKey: SettingsKey.touchLeftHanded)
        store.removeObject(forKey: SettingsKey.touchShowsDrawing)
        store.removeObject(forKey: SettingsKey.touchDrawSpread)
        notifyChange(.touch)
    }

    private func notifyChange(_ area: SettingsArea) {
        cachedAppOverrides = nil
        NotificationCenter.default.post(
            name: Preferences.didChangeNotification,
            object: nil,
            userInfo: [Preferences.areaUserInfoKey: area]
        )
    }
}

/// Which part of the settings a change touched, so an observer can tell a change it has
/// to act on from one it can ignore. Cursor mode, for one, stands down when its own keys
/// change and keeps going when a scroll slider moves.
public enum SettingsArea: String {
    case bindings
    case device
    case apps
    case scroll
    case cursor
    case touch
    case updates
    /// Everything at once, as after importing settings.
    case all
}

public extension Notification {
    /// The area a `Preferences.didChangeNotification` reports; `.all` when it says nothing.
    var settingsArea: SettingsArea {
        userInfo?[Preferences.areaUserInfoKey] as? SettingsArea ?? .all
    }
}
