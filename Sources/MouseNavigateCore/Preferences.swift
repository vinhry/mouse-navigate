import Foundation

/// UserDefaults-backed settings shared by the daemon and the preferences window.
///
/// Main thread only: the event tap, the preferences window and the touch monitor's
/// gesture handling all run there, and the cache below is not locked.
@MainActor
public final class Preferences {
    public static let shared = Preferences(store: .standard)

    public nonisolated static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.preferencesDidChange")
    /// `userInfo` key carrying the `SettingsArea` that changed.
    public nonisolated static let areaUserInfoKey = "area"

    /// Buttons the preferences window offers. CGEvent numbers 0-2 are the primary,
    /// secondary and middle buttons, which are left alone.
    public nonisolated static let configurableButtons = Array(3...9)

    private let store: UserDefaults
    nonisolated let currentConfigVersion = 3

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

    /// Brings an older layout up to date, one version at a time, so a store from any
    /// version arrives at the same place.
    ///
    /// - v1 stored a single global mapping under "button<n>". Those values came from the
    ///   MX Master 4, so they seed that profile and the old keys are cleared.
    /// - v2 had one reverse switch and one speed for the wheel; v3 reverses each axis on
    ///   its own and has a speed for each, so the switch becomes "both" and the speed both.
    func migrateIfNeeded() {
        let version = store.integer(forKey: SettingsKey.configVersion)
        guard version < currentConfigVersion else { return }

        if version < 2 {
            for button in Preferences.configurableButtons {
                let legacyKey = SettingsKey.legacyButton(button)
                guard let raw = store.string(forKey: legacyKey) else { continue }

                let newKey = BindingTrigger.button(button, .mxMaster4).storageKey
                if store.string(forKey: newKey) == nil {
                    store.set(raw, forKey: newKey)
                }
                store.removeObject(forKey: legacyKey)
            }
        }

        if version < 3 {
            if store.bool(forKey: SettingsKey.legacyScrollReversed) {
                store.set(ScrollReverse.both.rawValue, forKey: SettingsKey.scroll(.reverse))
            }
            if let speed = store.object(forKey: SettingsKey.legacyScrollSpeed) as? Double {
                store.set(speed, forKey: SettingsKey.scroll(.verticalSpeed))
                store.set(speed, forKey: SettingsKey.scroll(.horizontalSpeed))
            }
            store.removeObject(forKey: SettingsKey.legacyScrollReversed)
            store.removeObject(forKey: SettingsKey.legacyScrollSpeed)
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

    /// What a button press made with `modifiers` held runs: the combination's own
    /// binding, or, while that is unset or Disabled, the plain button's. Holding a
    /// modifier never takes away what a button does on its own until the combination is
    /// bound, so nothing changes for anyone who has not bound one.
    public func buttonBinding(
        _ button: Int,
        profile: DeviceProfile,
        input: ButtonInput,
        modifiers: Shortcut.Modifiers,
        app bundleID: String?
    ) -> ActionBinding {
        if !modifiers.isEmpty {
            let combination = binding(for: .button(button, profile, input: input, modifiers: modifiers), app: bundleID)
            if combination != .disabled {
                return combination
            }
        }
        return binding(for: .button(button, profile, input: input), app: bundleID)
    }

    private var cachedHasAnyDragBinding: Bool?

    /// Whether any button, for any mouse in any app, is bound to a drag, which is what
    /// decides whether side-button drags pass through the app at all. Cached like
    /// `isAnyScrollSettingActive`, for the same reason.
    public var hasAnyDragBinding: Bool {
        if let cachedHasAnyDragBinding {
            return cachedHasAnyDragBinding
        }
        func isBound(_ key: String, _ value: String) -> Bool {
            key.hasPrefix(SettingsKey.buttonDragPrefix) && value != ButtonAction.disabled.rawValue
        }
        let global = SettingsKey.userSettingKeys(in: store).contains { key in
            isBound(key, store.string(forKey: key) ?? "")
        }
        let apps = appOverrides.values.contains { override in
            override.bindings.contains { isBound($0.key, $0.value) }
        }
        cachedHasAnyDragBinding = global || apps
        return global || apps
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

    /// Every press, drag and modifier combination of the profile's buttons that has a
    /// binding other than its default: the bindings for all apps, or an app's own. Plain
    /// clicks are left out, since every one of them has a binding. For the settings window
    /// to mark the pickers behind which bindings are hiding.
    public func boundButtonCombinations(profile: DeviceProfile, app bundleID: String?) -> Set<ButtonCombination> {
        let inputs: [ButtonInput] = ButtonPress.allCases.map { .press($0) } + DragDirection.allCases.map { .drag($0) }
        var combinations: Set<ButtonCombination> = []
        for input in inputs {
            for raw in 0..<(1 << 4) {
                let modifiers = Shortcut.Modifiers(rawValue: raw)
                if input == .press(.click), modifiers.isEmpty { continue }
                let combination = ButtonCombination(input: input, modifiers: modifiers)
                for number in Preferences.configurableButtons {
                    let trigger = BindingTrigger.button(number, profile, input: input, modifiers: modifiers)
                    let bound: Bool
                    if let bundleID {
                        bound = appBinding(for: trigger, app: bundleID) != nil
                    } else {
                        bound = globalBinding(for: trigger) != trigger.defaultBinding
                    }
                    if bound {
                        combinations.insert(combination)
                        break
                    }
                }
            }
        }
        return combinations
    }

    /// Every button binding of the profile, for every press and modifier combination, and
    /// the scroll settings for all mice and for the profile, back to their defaults. Other
    /// profiles, apps' own settings, gestures and cursor keys are untouched.
    public func restoreMouseDefaults(profile: DeviceProfile) {
        let prefixes = [
            SettingsKey.buttonPrefix, SettingsKey.buttonHoldPrefix,
            SettingsKey.buttonDoublePrefix, SettingsKey.buttonDragPrefix,
        ].map { $0 + profile.rawValue + "." }
        for key in SettingsKey.userSettingKeys(in: store) where prefixes.contains(where: key.hasPrefix) {
            store.removeObject(forKey: key)
        }
        notifyChange(.bindings)
        setScrollOverride(.none, for: profile)
        scrollSettings = .standard
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

    /// The wheel for all mice and all apps.
    public var scrollSettings: ScrollSettings {
        get { readScrollOverride(profile: nil).applied(to: .standard) }
        set {
            writeScrollOverride(ScrollOverride(settings: newValue), profile: nil)
            notifyChange(.scroll)
        }
    }

    /// What one mouse model changes about the wheel; `.none` when it follows all mice.
    public func scrollOverride(for profile: DeviceProfile) -> ScrollOverride {
        readScrollOverride(profile: profile)
    }

    public func setScrollOverride(_ override: ScrollOverride, for profile: DeviceProfile) {
        writeScrollOverride(override, profile: profile)
        notifyChange(.scroll)
    }

    /// What one app changes about the wheel; `.none` when it follows the mouse.
    public func appScrollOverride(_ bundleID: String) -> ScrollOverride {
        appOverrides[bundleID]?.scroll ?? .none
    }

    public func setAppScrollOverride(_ override: ScrollOverride, app bundleID: String) {
        var overrides = appOverrides
        guard overrides[bundleID] != nil else { return }
        overrides[bundleID]?.scroll = override
        saveAppOverrides(overrides)
    }

    /// The wheel with `profile` in use and `bundleID` in front: the app's own settings,
    /// then the mouse model's, then the ones for all.
    public func resolvedScrollSettings(profile: DeviceProfile, app bundleID: String?) -> ScrollSettings {
        ScrollResolver.resolve(
            global: scrollSettings,
            profile: scrollOverride(for: profile),
            app: bundleID.flatMap { appOverrides[$0]?.scroll }
        )
    }

    private var cachedAnyScrollSettingActive: Bool?

    /// Whether any mouse in any app has the wheel reshaped, which is what decides whether
    /// wheel events pass through the app at all. Cached: it is asked whenever the event
    /// tap's mask is reconsidered, and the answer only changes with the settings.
    public var isAnyScrollSettingActive: Bool {
        if let cachedAnyScrollSettingActive {
            return cachedAnyScrollSettingActive
        }
        let active = scrollSettings.isActive
            || DeviceProfile.allCases.contains { !scrollOverride(for: $0).isEmpty }
            || appOverrides.values.contains { !$0.scroll.isEmpty }
        cachedAnyScrollSettingActive = active
        return active
    }

    private func readScrollOverride(profile: DeviceProfile?) -> ScrollOverride {
        var override = ScrollOverride()
        for field in ScrollField.allCases {
            override.set(field, to: store.object(forKey: SettingsKey.scroll(field, profile: profile)))
        }
        return override
    }

    private func writeScrollOverride(_ override: ScrollOverride, profile: DeviceProfile?) {
        for field in ScrollField.allCases {
            let key = SettingsKey.scroll(field, profile: profile)
            if let value = override.value(of: field) {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
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

    // MARK: - Export and import

    /// Every setting as a JSON file, for keeping or carrying to another Mac.
    public func exportSettings(appVersion: String?) throws -> Data {
        try SettingsSnapshot.capture(from: store, configVersion: currentConfigVersion, appVersion: appVersion).jsonData()
    }

    /// Replaces every setting with the file's, after checking the whole file. Nothing is
    /// written if any of it is refused.
    @discardableResult
    public func importSettings(_ data: Data) throws -> SettingsSnapshot.ReadResult {
        let result = try readSettings(data)
        applySettings(result)
        return result
    }

    /// Checks a file without writing anything, so a user can be asked to replace their
    /// settings only once the file is known to be good.
    public func readSettings(_ data: Data) throws -> SettingsSnapshot.ReadResult {
        try SettingsSnapshot.read(data, currentConfigVersion: currentConfigVersion)
    }

    /// Writes what `readSettings` read.
    public func applySettings(_ result: SettingsSnapshot.ReadResult) {
        result.snapshot.apply(to: store)
        migrateIfNeeded()
        notifyChange(.all)
    }

    private func notifyChange(_ area: SettingsArea) {
        cachedAppOverrides = nil
        cachedAnyScrollSettingActive = nil
        cachedHasAnyDragBinding = nil
        NotificationCenter.default.post(
            name: Preferences.didChangeNotification,
            object: nil,
            userInfo: [Preferences.areaUserInfoKey: area]
        )
    }
}

/// One way of pressing a button together with the modifier keys held for it.
public struct ButtonCombination: Hashable {
    public var input: ButtonInput
    public var modifiers: Shortcut.Modifiers

    public init(input: ButtonInput, modifiers: Shortcut.Modifiers) {
        self.input = input
        self.modifiers = modifiers
    }
}

/// Which part of the settings a change touched, so an observer can tell a change it has
/// to act on from one it can ignore. Cursor mode, for one, stands down when its own keys
/// change and keeps going when a scroll slider moves.
public enum SettingsArea: String, Sendable {
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
