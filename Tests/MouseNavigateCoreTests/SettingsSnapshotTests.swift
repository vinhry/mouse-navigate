import XCTest
@testable import MouseNavigateCore

@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites = []
        super.tearDown()
    }

    private func makeStore() -> UserDefaults {
        let suite = "MouseNavigateTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func populated() -> (Preferences, UserDefaults) {
        let store = makeStore()
        let preferences = Preferences(store: store)
        preferences.setGlobalBinding(.builtin(.newTab), for: .button(5, .mxMaster4))
        preferences.setGlobalBinding(.shortcut(Shortcut(0x00, [.command, .shift])), for: .button(6, .mxMaster4, .hold))
        preferences.setGlobalBinding(.openURL(URL(string: "https://example.com")!), for: .character(.b))
        preferences.setKeyCode(40, for: .activate)
        preferences.setValue(0.75, for: .holdThreshold)
        preferences.isCursorModeEnabled = false
        preferences.scrollSettings = ScrollSettings(reverse: .both, verticalSpeed: 2, horizontalSpeed: 2, isSmooth: true)
        preferences.isTouchEnabled = true
        preferences.isLeftHanded = true
        preferences.setCharacterSource(.middleButtonDrag, enabled: true)
        preferences.deviceOverride = .generic
        preferences.automaticUpdates = true
        preferences.lastUpdateCheck = Date()
        preferences.hasCompletedOnboarding = true
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setApp("com.example.app", disabled: false)
        preferences.setAppBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap), app: "com.example.app")
        preferences.addApp(bundleID: "com.example.game", name: "Game")
        preferences.setApp("com.example.game", disabled: true)
        preferences.setAppScrollOverride(ScrollOverride(reverse: .vertical), app: "com.example.game")
        preferences.setScrollOverride(ScrollOverride(horizontalSpeed: 0.5, isSmooth: false), for: .generic)
        return (preferences, store)
    }

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - Round trip

    func testExportThenImportReproducesEverySetting() throws {
        let (source, sourceStore) = populated()
        let data = try source.exportSettings(appVersion: "0.5.0")

        let targetStore = makeStore()
        let target = Preferences(store: targetStore)
        let result = try target.importSettings(data)

        XCTAssertTrue(result.ignoredKeys.isEmpty)
        var expected = sourceStore.persistentDomain(forName: suites[0]) ?? [:]
        var actual = targetStore.persistentDomain(forName: suites[1]) ?? [:]
        for key in SettingsSnapshot.keptOnThisMac {
            expected[key] = nil
            actual[key] = nil
        }
        XCTAssertEqual(expected as NSDictionary, actual as NSDictionary)

        XCTAssertEqual(target.globalBinding(for: .button(6, .mxMaster4, .hold)), .shortcut(Shortcut(0x00, [.command, .shift])))
        XCTAssertEqual(target.binding(for: .touch(.trackpadThreeFingerTap), app: "com.example.app"), .builtin(.copy))
        XCTAssertTrue(target.isAppDisabled("com.example.game"))
        XCTAssertEqual(target.keyCode(for: .activate), 40)
        XCTAssertEqual(target.scrollSettings, ScrollSettings(reverse: .both, verticalSpeed: 2, horizontalSpeed: 2, isSmooth: true))
        XCTAssertEqual(target.appScrollOverride("com.example.game"), ScrollOverride(reverse: .vertical))
        XCTAssertEqual(target.scrollOverride(for: .generic), ScrollOverride(horizontalSpeed: 0.5, isSmooth: false))
    }

    func testExportLeavesTheUpdateStampOut() throws {
        let (source, _) = populated()
        let data = try source.exportSettings(appVersion: nil)
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let settings = envelope["settings"] as! [String: Any]
        XCTAssertNil(settings[SettingsKey.lastUpdateCheck])
        XCTAssertNil(settings[SettingsKey.configVersion])
        XCTAssertNil(settings[SettingsKey.automaticUpdates], "each Mac answers for its own updates")
        XCTAssertEqual(envelope["format"] as? String, SettingsSnapshot.format)
        XCTAssertEqual(envelope["configVersion"] as? Int, source.currentConfigVersion)
        XCTAssertNil(envelope["appVersion"])
    }

    func testExportIsPrettyPrintedWithSortedKeys() throws {
        let (source, _) = populated()
        let text = String(decoding: try source.exportSettings(appVersion: "0.5.0"), as: UTF8.self)
        XCTAssertTrue(text.contains("\n"))
        let aIndex = text.range(of: "\"appVersion\"")!.lowerBound
        let fIndex = text.range(of: "\"format\"")!.lowerBound
        let sIndex = text.range(of: "\"settings\"")!.lowerBound
        XCTAssertLessThan(aIndex, fIndex)
        XCTAssertLessThan(fIndex, sIndex)
        // Bindings are stored as they are, so a built-in one reads as its name.
        XCTAssertTrue(text.contains("\"button.mxMaster4.5\" : \"newTab\""))
    }

    func testImportReplacesSettingsTheFileLacks() throws {
        let store = makeStore()
        let preferences = Preferences(store: store)
        preferences.setGlobalBinding(.builtin(.copy), for: .button(3, .generic))
        preferences.isLeftHanded = true
        let stamp = Date(timeIntervalSince1970: 1000)
        preferences.lastUpdateCheck = stamp

        try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"touchEnabled": true}}
        """))

        XCTAssertEqual(preferences.globalBinding(for: .button(3, .generic)), .builtin(.back))
        XCTAssertFalse(preferences.isLeftHanded)
        XCTAssertTrue(preferences.isTouchEnabled)
        XCTAssertEqual(preferences.lastUpdateCheck, stamp, "bookkeeping survives an import")
    }

    func testWhereSettingsWasLeftIsNeitherExportedNorImportedNorCleared() throws {
        let store = makeStore()
        let preferences = Preferences(store: store)
        preferences.lastSettingsTab = 2
        preferences.lastSettingsTouchPane = 1
        preferences.isLeftHanded = true

        let exported = try preferences.exportSettings(appVersion: "0.9.0")
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(text.contains(SettingsKey.settingsLastTab))
        XCTAssertFalse(text.contains(SettingsKey.settingsLastTouchPane))

        // A file that carries them anyway is not believed.
        let result = try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"touchEnabled": true, "ui.settingsTab": 3, "ui.settingsTouchPane": 0}}
        """))
        XCTAssertEqual(result.ignoredKeys, [SettingsKey.settingsLastTab, SettingsKey.settingsLastTouchPane].sorted())
        XCTAssertEqual(preferences.lastSettingsTab, 2)
        XCTAssertEqual(preferences.lastSettingsTouchPane, 1)
        XCTAssertFalse(preferences.isLeftHanded, "the rest was replaced")

        // And applying a file without them clears nothing of theirs.
        try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2, "settings": {}}
        """))
        XCTAssertEqual(preferences.lastSettingsTab, 2)
        XCTAssertEqual(preferences.lastSettingsTouchPane, 1)
    }

    func testImportPostsOneChangeForEverything() throws {
        let preferences = Preferences(store: makeStore())
        var areas: [SettingsArea] = []
        let observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChangeNotification, object: nil, queue: nil
        ) { areas.append($0.settingsArea) }
        defer { NotificationCenter.default.removeObserver(observer) }

        try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2, "settings": {}}
        """))
        XCTAssertEqual(areas, [.all])
    }

    // MARK: - Validation

    func testUnknownKeysAreIgnoredAndNamed() throws {
        let preferences = Preferences(store: makeStore())
        let result = try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"touchEnabled": true, "somethingNew": 3, "update.lastCheck": "yesterday", "configVersion": 9}}
        """))
        XCTAssertEqual(result.ignoredKeys, ["configVersion", "somethingNew", "update.lastCheck"])
        XCTAssertTrue(preferences.isTouchEnabled)
        XCTAssertNil(preferences.lastUpdateCheck)
    }

    func testWrongTypeRefusesTheWholeFile() {
        let store = makeStore()
        let preferences = Preferences(store: store)
        preferences.isLeftHanded = true

        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"touchEnabled": true, "scroll.smooth": "yes"}}
        """))) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .wrongType(key: "scroll.smooth", expected: .bool))
        }
        XCTAssertTrue(preferences.isLeftHanded, "nothing was written")
        XCTAssertFalse(preferences.isTouchEnabled)
    }

    func testNumbersAreToldApartByTheRegistry() throws {
        let preferences = Preferences(store: makeStore())
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2, "settings": {"scroll.smooth": 1}}
        """))) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .wrongType(key: "scroll.smooth", expected: .bool))
        }
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2, "settings": {"key.activate": true}}
        """)))
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2, "settings": {"key.activate": 1.5}}
        """)))

        try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"scroll.speed": 2, "key.activate": 40.0, "scroll.reversed": true}}
        """))
        // A version-2 file: its one speed and reverse switch are migrated on import.
        XCTAssertEqual(preferences.scrollSettings.verticalSpeed, 2)
        XCTAssertEqual(preferences.keyCode(for: .activate), 40)
        XCTAssertEqual(preferences.scrollSettings.reverse, .both)
    }

    func testMalformedAppOverridesAreRefused() {
        let preferences = Preferences(store: makeStore())
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"appOverrides": {"com.example.app": "not a dictionary"}}}
        """))) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .wrongType(key: "appOverrides", expected: .dictionary))
        }
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"appOverrides": {"com.example.app": {"name": "X", "bindings": [1, 2]}}}}
        """)))
    }

    func testNotASettingsFile() {
        let preferences = Preferences(store: makeStore())
        for text in ["", "null", "[]", "{\"settings\": {}}", "{\"format\": \"other\", \"settings\": {}}", "{\"format\": \"MouseNavigate settings\"}"] {
            XCTAssertThrowsError(try preferences.importSettings(json(text)), text) { error in
                XCTAssertEqual(error as? SettingsSnapshot.ReadError, .notASettingsFile, text)
            }
        }
    }

    func testUnsupportedSchemaAndNewerConfigAreRefused() {
        let preferences = Preferences(store: makeStore())
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 2, "configVersion": 2, "settings": {}}
        """))) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .unsupportedSchema(2))
        }
        XCTAssertThrowsError(try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 99, "settings": {}}
        """))) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .newerConfigVersion(99))
        }
    }

    // MARK: - Older files

    func testAnOlderFileIsImportedAndMigrated() throws {
        let store = makeStore()
        let preferences = Preferences(store: store)
        let result = try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 1,
         "settings": {"button3": "newTab", "touchEnabled": true}}
        """))
        XCTAssertTrue(result.ignoredKeys.isEmpty)
        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster4)), .builtin(.newTab))
        XCTAssertNil(store.object(forKey: "button3"))
        XCTAssertEqual(store.integer(forKey: SettingsKey.configVersion), preferences.currentConfigVersion)
    }

    func testAVersionTwoFileBringsItsWheelSettingsAlong() throws {
        let preferences = Preferences(store: makeStore())
        try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 2,
         "settings": {"scroll.reversed": true, "scroll.speed": 3, "scroll.smooth": true}}
        """))
        XCTAssertEqual(
            preferences.scrollSettings,
            ScrollSettings(reverse: .both, verticalSpeed: 3, horizontalSpeed: 3, isSmooth: true)
        )
    }

    // MARK: - Values

    func testDictionaryValuesKeepTheirKinds() {
        let value = SettingsValue(any: ["a": true, "b": 2, "c": 2.5, "d": "x", "e": ["f": false]] as [String: Any])
        XCTAssertEqual(value, .dictionary([
            "a": .bool(true), "b": .int(2), "c": .double(2.5), "d": .string("x"), "e": .dictionary(["f": .bool(false)]),
        ]))
        XCTAssertNil(SettingsValue(any: [1, 2]))
        XCTAssertNil(SettingsValue(any: Date()))
        XCTAssertNil(SettingsValue(any: Date(), as: .date))
    }

    func testImportKeepsThisMacsBookkeeping() throws {
        let (source, _) = populated()
        let data = try source.exportSettings(appVersion: "0.8.0")

        let targetStore = makeStore()
        let target = Preferences(store: targetStore)
        target.hasCompletedOnboarding = true
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        target.lastUpdateCheck = checked
        _ = try target.importSettings(data)

        XCTAssertTrue(target.hasCompletedOnboarding, "the Welcome window does not come back")
        XCTAssertEqual(target.lastUpdateCheck, checked)
    }

    // MARK: - What a file may not set

    func testAFileCannotSetBookkeepingOrUpdateConsent() throws {
        let store = makeStore()
        let preferences = Preferences(store: store)
        preferences.automaticUpdates = false

        let result = try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 3,
         "settings": {"touchEnabled": true, "update.automatic": true, "onboarding.completed": true}}
        """))

        XCTAssertEqual(result.ignoredKeys, ["onboarding.completed", "update.automatic"], "named like configVersion")
        XCTAssertEqual(preferences.automaticUpdates, false, "this Mac's answer stands")
        XCTAssertFalse(preferences.hasCompletedOnboarding)
        XCTAssertTrue(preferences.isTouchEnabled)
    }

    func testAnImportWithoutTheUpdateKeyKeepsThisMacsAnswer() throws {
        let preferences = Preferences(store: makeStore())
        preferences.automaticUpdates = true
        try preferences.importSettings(json("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 3, "settings": {}}
        """))
        XCTAssertEqual(preferences.automaticUpdates, true, "not asked again after an import")
    }

    // MARK: - Size

    func testTooManyKeysAreRefused() {
        var settings: [String: Any] = [:]
        for index in 0...SettingsSnapshot.maximumKeyCount {
            settings["unknown.\(index)"] = true
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "format": SettingsSnapshot.format, "schemaVersion": 1, "configVersion": 3, "settings": settings,
        ] as [String: Any])
        XCTAssertLessThan(data.count, SettingsSnapshot.maximumFileSize, "refused for its keys, not its size")

        let preferences = Preferences(store: makeStore())
        XCTAssertThrowsError(try preferences.importSettings(data)) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .tooManyKeys(limit: SettingsSnapshot.maximumKeyCount))
        }
    }

    func testKeysInsideAppOverridesCount() {
        var bindings: [String: Any] = [:]
        for index in 0..<SettingsSnapshot.maximumKeyCount {
            bindings["touch.\(index)"] = "back"
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "format": SettingsSnapshot.format, "schemaVersion": 1, "configVersion": 3,
            "settings": ["appOverrides": ["com.example.app": ["name": "X", "bindings": bindings]]],
        ] as [String: Any])

        XCTAssertThrowsError(try SettingsSnapshot.read(data, currentConfigVersion: 3)) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .tooManyKeys(limit: SettingsSnapshot.maximumKeyCount))
        }
    }

    func testARealExportIsWellInsideTheLimits() throws {
        let (source, _) = populated()
        for profile in DeviceProfile.allCases {
            for button in Preferences.bindableButtons(for: profile) {
                for raw in 0..<16 {
                    let modifiers = Shortcut.Modifiers(rawValue: raw)
                    for press in ButtonPress.allCases {
                        source.setGlobalBinding(.runShortcut(name: "A shortcut with a longish name"), for: .button(button, profile, press, modifiers))
                    }
                    for direction in DragDirection.allCases {
                        source.setGlobalBinding(.openURL(URL(string: "https://example.com/some/path")!), for: .buttonDrag(button, profile, direction, modifiers))
                    }
                }
            }
        }
        let data = try source.exportSettings(appVersion: "0.8.0")
        XCTAssertLessThan(data.count, SettingsSnapshot.maximumFileSize / 2)
        XCTAssertNoThrow(try SettingsSnapshot.read(data, currentConfigVersion: source.currentConfigVersion))
    }

    func testAnOversizeFileIsRefused() throws {
        let oversize = Data(repeating: 0x20, count: SettingsSnapshot.maximumFileSize + 1)
        XCTAssertThrowsError(try SettingsSnapshot.read(oversize, currentConfigVersion: 3)) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .fileTooLarge(limit: SettingsSnapshot.maximumFileSize))
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MouseNavigateTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try oversize.write(to: url)
        XCTAssertThrowsError(try SettingsSnapshot.loadFile(at: url)) { error in
            XCTAssertEqual(error as? SettingsSnapshot.ReadError, .fileTooLarge(limit: SettingsSnapshot.maximumFileSize))
        }

        let exact = Data(repeating: 0x20, count: SettingsSnapshot.maximumFileSize)
        try exact.write(to: url)
        XCTAssertEqual(try SettingsSnapshot.loadFile(at: url).count, SettingsSnapshot.maximumFileSize)
    }
}
