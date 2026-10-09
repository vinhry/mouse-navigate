import XCTest
@testable import MouseNavigateCore

final class PreferencesTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MouseNavigateTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private func makePreferences() -> Preferences {
        Preferences(store: store)
    }

    /// Only the keys this suite wrote, without the global domain's noise.
    private var storedKeys: Set<String> {
        Set(store.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? [])
    }

    // MARK: - Migration

    func testFreshStoreIsOnlyStamped() {
        let preferences = makePreferences()
        XCTAssertEqual(store.integer(forKey: "configVersion"), preferences.currentConfigVersion)
        XCTAssertEqual(storedKeys, ["configVersion"])
    }

    func testVersionOneButtonsSeedTheMXMaster4Profile() {
        store.set("back", forKey: "button3")
        store.set("missionControl", forKey: "button6")

        let preferences = makePreferences()

        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster4)), .builtin(.back))
        XCTAssertEqual(preferences.globalBinding(for: .button(6, .mxMaster4)), .builtin(.missionControl))
        XCTAssertNil(store.object(forKey: "button3"))
        XCTAssertNil(store.object(forKey: "button6"))
        XCTAssertEqual(store.integer(forKey: "configVersion"), preferences.currentConfigVersion)
    }

    func testMigrationNeverOverwritesAProfileBinding() {
        store.set("back", forKey: "button3")
        store.set("forward", forKey: BindingTrigger.button(3, .mxMaster4).storageKey)

        let preferences = makePreferences()

        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster4)), .builtin(.forward))
        XCTAssertNil(store.object(forKey: "button3"))
    }

    func testVersionTwoScrollSettingsBecomePerAxis() {
        store.set(2, forKey: SettingsKey.configVersion)
        store.set(true, forKey: SettingsKey.legacyScrollReversed)
        store.set(2.0, forKey: SettingsKey.legacyScrollSpeed)
        store.set(true, forKey: SettingsKey.scroll(.smooth))

        let preferences = makePreferences()

        XCTAssertEqual(
            preferences.scrollSettings,
            ScrollSettings(reverse: .both, verticalSpeed: 2, horizontalSpeed: 2, isSmooth: true)
        )
        XCTAssertNil(store.object(forKey: SettingsKey.legacyScrollReversed))
        XCTAssertNil(store.object(forKey: SettingsKey.legacyScrollSpeed))
        XCTAssertEqual(store.integer(forKey: SettingsKey.configVersion), 3)
    }

    func testAVersionTwoStoreThatNeverReversedStaysThatWay() {
        store.set(2, forKey: SettingsKey.configVersion)
        store.set(false, forKey: SettingsKey.legacyScrollReversed)
        let preferences = makePreferences()
        XCTAssertEqual(preferences.scrollSettings.reverse, .off)
        XCTAssertNil(store.object(forKey: SettingsKey.scroll(.reverse)))
    }

    func testAVersionOneStoreRunsEveryStage() {
        store.set("newTab", forKey: "button5")
        store.set(true, forKey: SettingsKey.legacyScrollReversed)

        let preferences = makePreferences()

        XCTAssertEqual(preferences.globalBinding(for: .button(5, .mxMaster4)), .builtin(.newTab))
        XCTAssertEqual(preferences.scrollSettings.reverse, .both)
        XCTAssertEqual(store.integer(forKey: SettingsKey.configVersion), 3)
    }

    func testACurrentStoreIsLeftAlone() {
        store.set(3, forKey: SettingsKey.configVersion)
        store.set(true, forKey: SettingsKey.legacyScrollReversed)
        _ = makePreferences()
        XCTAssertEqual(store.bool(forKey: SettingsKey.legacyScrollReversed), true, "nothing to migrate at version 3")
    }

    func testMigrationIsIdempotent() {
        store.set("back", forKey: "button3")
        let preferences = makePreferences()
        let after = store.persistentDomain(forName: suiteName) as NSDictionary?

        preferences.migrateIfNeeded()

        XCTAssertEqual(store.persistentDomain(forName: suiteName) as NSDictionary?, after)
    }

    // MARK: - Restore defaults

    func testRestoreCursorDefaultsRemovesOnlyCursorKeys() {
        let preferences = makePreferences()
        preferences.setKeyCode(40, for: .activate)
        preferences.setValue(0.9, for: .holdThreshold)
        preferences.isCursorModeEnabled = false
        preferences.setGlobalBinding(.builtin(.newTab), for: .button(4, .generic))
        preferences.isLeftHanded = true

        preferences.restoreCursorDefaults()

        XCTAssertEqual(preferences.keyCode(for: .activate), CursorBinding.activate.defaultKeyCode)
        XCTAssertEqual(preferences.value(for: .holdThreshold), CursorSetting.holdThreshold.defaultValue)
        XCTAssertTrue(preferences.isCursorModeEnabled)
        XCTAssertEqual(preferences.globalBinding(for: .button(4, .generic)), .builtin(.newTab))
        XCTAssertTrue(preferences.isLeftHanded)
        XCTAssertFalse(storedKeys.contains { $0.hasPrefix("key.") || $0.hasPrefix("cursor.") })
    }

    func testRestoreTouchDefaultsRemovesOnlyTouchKeys() {
        let preferences = makePreferences()
        preferences.setGlobalBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap))
        preferences.setGlobalBinding(.builtin(.paste), for: .character(.t))
        preferences.setCharacterSource(.middleButtonDrag, enabled: true)
        preferences.isLeftHanded = true
        preferences.showsDrawingOverlay = false
        preferences.characterDrawSpread = 0.5
        preferences.isTouchEnabled = true
        preferences.setKeyCode(40, for: .activate)

        preferences.restoreTouchDefaults()

        XCTAssertEqual(preferences.globalBinding(for: .touch(.trackpadThreeFingerTap)), BindingTrigger.touch(.trackpadThreeFingerTap).defaultBinding)
        XCTAssertEqual(preferences.globalBinding(for: .character(.t)), BindingTrigger.character(.t).defaultBinding)
        XCTAssertFalse(preferences.isCharacterSourceEnabled(.middleButtonDrag))
        XCTAssertFalse(preferences.isLeftHanded)
        XCTAssertTrue(preferences.showsDrawingOverlay)
        XCTAssertEqual(preferences.characterDrawSpread, TouchTuning().drawSpread)
        // Whether gestures are on at all is not a default to restore.
        XCTAssertTrue(preferences.isTouchEnabled)
        XCTAssertEqual(preferences.keyCode(for: .activate), 40)
    }

    // MARK: - Bindings

    func testUnreadableStoredBindingFallsBackToDefault() {
        store.set("{not json", forKey: BindingTrigger.button(3, .mxMaster4).storageKey)
        let preferences = makePreferences()
        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster4)), .builtin(.back))
    }

    func testBindingAProfileDoesNotTouchAnother() {
        let preferences = makePreferences()
        preferences.setGlobalBinding(.builtin(.copy), for: .button(3, .mxMaster3))
        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster3)), .builtin(.copy))
        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster4)), .builtin(.back))
    }

    // MARK: - Scroll scopes

    func testScrollSettingsResolveAppThenMouseThenAll() {
        let preferences = makePreferences()
        preferences.scrollSettings = ScrollSettings(verticalSpeed: 2)
        preferences.setScrollOverride(ScrollOverride(reverse: .both), for: .mxMaster4)
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppScrollOverride(ScrollOverride(reverse: .vertical, isSmooth: true), app: "com.example.app")

        XCTAssertEqual(
            preferences.resolvedScrollSettings(profile: .mxMaster4, app: "com.example.app"),
            ScrollSettings(reverse: .vertical, verticalSpeed: 2, isSmooth: true)
        )
        XCTAssertEqual(
            preferences.resolvedScrollSettings(profile: .mxMaster4, app: nil),
            ScrollSettings(reverse: .both, verticalSpeed: 2)
        )
        XCTAssertEqual(
            preferences.resolvedScrollSettings(profile: .generic, app: "com.other"),
            ScrollSettings(verticalSpeed: 2)
        )
        XCTAssertEqual(preferences.scrollOverride(for: .mxMaster4), ScrollOverride(reverse: .both))
        XCTAssertEqual(preferences.scrollOverride(for: .generic), .none)
        XCTAssertEqual(preferences.appScrollOverride("com.example.app"), ScrollOverride(reverse: .vertical, isSmooth: true))
        XCTAssertEqual(preferences.appScrollOverride("com.other"), .none)
    }

    func testClearingAScopeHandsItBack() {
        let preferences = makePreferences()
        preferences.setScrollOverride(ScrollOverride(settings: ScrollSettings(reverse: .both)), for: .generic)
        preferences.setScrollOverride(.none, for: .generic)
        XCTAssertEqual(preferences.scrollOverride(for: .generic), .none)
        XCTAssertFalse(storedKeys.contains { $0.hasPrefix("scroll.generic.") })
    }

    func testAnyScrollSettingActiveFollowsEveryScope() {
        let preferences = makePreferences()
        XCTAssertFalse(preferences.isAnyScrollSettingActive)

        preferences.setScrollOverride(ScrollOverride(isSmooth: true), for: .mxMaster3)
        XCTAssertTrue(preferences.isAnyScrollSettingActive, "the cache is dropped on change")
        preferences.setScrollOverride(.none, for: .mxMaster3)
        XCTAssertFalse(preferences.isAnyScrollSettingActive)

        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppScrollOverride(ScrollOverride(reverse: .both), app: "com.example.app")
        XCTAssertTrue(preferences.isAnyScrollSettingActive)
        preferences.removeApp(bundleID: "com.example.app")
        XCTAssertFalse(preferences.isAnyScrollSettingActive)

        preferences.scrollSettings = ScrollSettings(verticalSpeed: 2)
        XCTAssertTrue(preferences.isAnyScrollSettingActive)
    }

    func testAppScrollOverrideSurvivesTheOverridesPlist() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppScrollOverride(ScrollOverride(commandIsFast: true), app: "com.example.app")
        preferences.setAppBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap), app: "com.example.app")
        XCTAssertEqual(preferences.appScrollOverride("com.example.app"), ScrollOverride(commandIsFast: true))
        XCTAssertEqual(preferences.appBinding(for: .touch(.trackpadThreeFingerTap), app: "com.example.app"), .builtin(.copy))
    }

    // MARK: - Drags

    func testDragBindingsResolveLikePresses() {
        let preferences = makePreferences()
        XCTAssertFalse(preferences.hasAnyDragBinding)
        preferences.setGlobalBinding(.builtin(.missionControl), for: .buttonDrag(5, .mxMaster4, .up))
        XCTAssertTrue(preferences.hasAnyDragBinding)
        XCTAssertEqual(
            preferences.buttonBinding(5, profile: .mxMaster4, input: .drag(.up), modifiers: [], app: nil),
            .builtin(.missionControl)
        )
        XCTAssertEqual(
            preferences.buttonBinding(5, profile: .mxMaster4, input: .drag(.up), modifiers: [.shift], app: nil),
            .builtin(.missionControl),
            "an unbound combination falls back to the plain drag"
        )
        XCTAssertEqual(
            preferences.buttonBinding(5, profile: .mxMaster4, input: .drag(.down), modifiers: [], app: nil),
            .disabled
        )
        preferences.setGlobalBinding(.disabled, for: .buttonDrag(5, .mxMaster4, .up))
        XCTAssertFalse(preferences.hasAnyDragBinding, "a drag set back to Disabled is not a binding")
    }

    func testAnAppsDragBindingCountsToo() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppBinding(.builtin(.copy), for: .buttonDrag(4, .generic, .left), app: "com.example.app")
        XCTAssertTrue(preferences.hasAnyDragBinding)
        XCTAssertEqual(
            preferences.buttonBinding(4, profile: .generic, input: .drag(.left), modifiers: [], app: "com.example.app"),
            .builtin(.copy)
        )
        preferences.removeApp(bundleID: "com.example.app")
        XCTAssertFalse(preferences.hasAnyDragBinding)
    }

    // MARK: - Modifier combinations

    func testAnUnboundCombinationFallsBackToThePlainButton() {
        let preferences = makePreferences()
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.shift], app: nil),
            .builtin(.back)
        )
    }

    func testABoundCombinationWins() {
        let preferences = makePreferences()
        preferences.setGlobalBinding(.builtin(.newTab), for: .button(3, .mxMaster4, .click, [.shift]))
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.shift], app: nil),
            .builtin(.newTab)
        )
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [], app: nil),
            .builtin(.back)
        )
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.shift, .command], app: nil),
            .builtin(.back),
            "a different combination is not the bound one"
        )
    }

    func testACombinationSetToDisabledFallsBackToThePlainButton() {
        let preferences = makePreferences()
        preferences.setGlobalBinding(.disabled, for: .button(3, .mxMaster4, .click, [.shift]))
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.shift], app: nil),
            .builtin(.back)
        )
    }

    func testAnAppsCombinationBeatsThePlainBindingForAllApps() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppBinding(.builtin(.copy), for: .button(3, .mxMaster4, .click, [.command]), app: "com.example.app")

        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.command], app: "com.example.app"),
            .builtin(.copy)
        )
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.command], app: "com.other"),
            .builtin(.back)
        )
        preferences.setApp("com.example.app", disabled: true)
        XCTAssertEqual(
            preferences.buttonBinding(3, profile: .mxMaster4, input: .press(.click), modifiers: [.command], app: "com.example.app"),
            .disabled
        )
    }

    // MARK: - Per-app bindings

    func testAppBindingWinsAndInheritsOtherwise() {
        let preferences = makePreferences()
        let trigger = BindingTrigger.button(3, .mxMaster4)
        preferences.addApp(bundleID: "com.example.app", name: "Example")

        XCTAssertEqual(preferences.binding(for: trigger, app: "com.example.app"), .builtin(.back))
        XCTAssertNil(preferences.appBinding(for: trigger, app: "com.example.app"))

        preferences.setAppBinding(.builtin(.newTab), for: trigger, app: "com.example.app")

        XCTAssertEqual(preferences.binding(for: trigger, app: "com.example.app"), .builtin(.newTab))
        XCTAssertEqual(preferences.binding(for: trigger, app: "com.other.app"), .builtin(.back))
        XCTAssertEqual(preferences.binding(for: trigger, app: nil), .builtin(.back))
    }

    func testDisabledAppGetsNothing() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.game", name: "Game")
        preferences.setApp("com.example.game", disabled: true)

        XCTAssertTrue(preferences.isAppDisabled("com.example.game"))
        XCTAssertFalse(preferences.isAppDisabled(nil))
        XCTAssertEqual(preferences.binding(for: .button(3, .mxMaster4), app: "com.example.game"), .disabled)
    }

    func testAddingAnAppTwiceKeepsItsBindings() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap), app: "com.example.app")

        preferences.addApp(bundleID: "com.example.app", name: "Renamed")

        XCTAssertEqual(preferences.appBinding(for: .touch(.trackpadThreeFingerTap), app: "com.example.app"), .builtin(.copy))
        XCTAssertEqual(preferences.overriddenApps.map(\.name), ["Example"])
    }

    func testRemoveAppAndClearBindings() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap), app: "com.example.app")
        preferences.setAppBinding(.builtin(.paste), for: .button(3, .mxMaster4), app: "com.example.app")

        preferences.clearAppBindings(app: "com.example.app") { $0.hasPrefix("touch.") }
        XCTAssertNil(preferences.appBinding(for: .touch(.trackpadThreeFingerTap), app: "com.example.app"))
        XCTAssertEqual(preferences.appBinding(for: .button(3, .mxMaster4), app: "com.example.app"), .builtin(.paste))

        preferences.removeApp(bundleID: "com.example.app")
        XCTAssertTrue(preferences.overriddenApps.isEmpty)
        XCTAssertEqual(preferences.binding(for: .button(3, .mxMaster4), app: "com.example.app"), .builtin(.back))
    }

    func testSettingABindingOnAnUnknownAppIsIgnored() {
        let preferences = makePreferences()
        preferences.setAppBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap), app: "com.example.unknown")
        preferences.setApp("com.example.unknown", disabled: true)
        XCTAssertTrue(preferences.overriddenApps.isEmpty)
        XCTAssertFalse(preferences.isAppDisabled("com.example.unknown"))
    }

    func testOverridesAreReadFreshAfterEveryChange() {
        let preferences = makePreferences()
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        _ = preferences.appOverrides  // fills the cache
        preferences.setApp("com.example.app", disabled: true)
        XCTAssertTrue(preferences.appOverrides["com.example.app"]?.isDisabled ?? false)
        preferences.removeApp(bundleID: "com.example.app")
        XCTAssertTrue(preferences.appOverrides.isEmpty)
    }

    // MARK: - Notifications

    func testChangeNotificationNamesItsArea() {
        let preferences = makePreferences()
        var areas: [SettingsArea] = []
        let observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChangeNotification, object: nil, queue: nil
        ) { areas.append($0.settingsArea) }
        defer { NotificationCenter.default.removeObserver(observer) }

        preferences.scrollSettings = ScrollSettings(reverse: .both, verticalSpeed: 1, horizontalSpeed: 1, isSmooth: false)
        preferences.setKeyCode(40, for: .activate)
        preferences.isTouchEnabled = true
        preferences.setGlobalBinding(.builtin(.copy), for: .button(3, .generic))
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.deviceOverride = .generic
        preferences.automaticUpdates = true
        preferences.lastUpdateCheck = Date()

        XCTAssertEqual(areas, [.scroll, .cursor, .touch, .bindings, .apps, .device, .updates])
    }

    func testNotificationWithoutAreaMeansEverything() {
        let notification = Notification(name: Preferences.didChangeNotification)
        XCTAssertEqual(notification.settingsArea, .all)
    }
}
