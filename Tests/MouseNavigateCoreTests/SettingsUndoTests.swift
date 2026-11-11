import XCTest
@testable import MouseNavigateCore

@MainActor
final class SettingsUndoTests: XCTestCase {
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

    /// Everything this suite holds, bookkeeping and all, without the global domain's keys.
    private var domain: NSDictionary {
        (store.persistentDomain(forName: suiteName) ?? [:]) as NSDictionary
    }

    private let app = "com.example.app"
    private let game = "com.example.game"

    /// A store with something set in every place a destructive change reaches, and in the
    /// places none of them may: bookkeeping, update consent and a key that is not ours.
    private func populated() -> Preferences {
        let preferences = Preferences(store: store)
        // Buttons on two mice, with presses, a drag and modifier combinations.
        preferences.setGlobalBinding(.builtin(.newTab), for: .button(5, .mxMaster4))
        preferences.setGlobalBinding(.shortcut(Shortcut(0x00, [.command, .shift])), for: .button(6, .mxMaster4, .hold))
        preferences.setGlobalBinding(.builtin(.paste), for: .buttonDrag(3, .mxMaster4, .down, [.command]))
        preferences.setGlobalBinding(.builtin(.copy), for: .button(3, .mxMaster3))
        // Gestures and letters.
        preferences.setGlobalBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap))
        preferences.setGlobalBinding(.openURL(URL(string: "https://example.com")!), for: .character(.b))
        // The keyboard cursor.
        preferences.setKeyCode(40, for: .activate)
        preferences.setValue(0.75, for: .holdThreshold)
        preferences.setValue(3, for: .fastMultiplier)
        preferences.isCursorModeEnabled = false
        // Scroll and pointer, for all mice and for one.
        preferences.scrollSettings = ScrollSettings(reverse: .both, verticalSpeed: 2, horizontalSpeed: 2, isSmooth: true)
        preferences.setScrollOverride(ScrollOverride(horizontalSpeed: 0.5, isSmooth: false), for: .mxMaster4)
        preferences.pointerSettings = PointerSettings(accelerationMode: .custom, acceleration: 2)
        preferences.setPointerOverride(PointerOverride(accelerationMode: .off), for: .mxMaster4)
        // Touch options.
        preferences.isTouchEnabled = true
        preferences.isLeftHanded = true
        preferences.ignoresTouchWhileTyping = false
        preferences.letterStrictness = 0.8
        preferences.characterDrawSpread = 0.3
        preferences.showsGestureHUD = true
        preferences.setCharacterSource(.middleButtonDrag, enabled: true)
        preferences.setTouchSurface(.magicMouse, enabled: false)
        preferences.deviceOverride = .mxMaster4
        // Two apps with settings of their own.
        preferences.addApp(bundleID: app, name: "Example")
        preferences.setAppBinding(.builtin(.copy), for: .touch(.trackpadThreeFingerTap), app: app)
        preferences.setAppBinding(.builtin(.copy), for: .character(.c), app: app)
        preferences.setAppBinding(.builtin(.paste), for: .button(3, .mxMaster4), app: app)
        preferences.setAppBinding(.builtin(.paste), for: .button(4, .mxMaster4, .doubleClick, [.option]), app: app)
        preferences.setAppScrollOverride(ScrollOverride(reverse: .vertical, verticalSpeed: 3), app: app)
        preferences.addApp(bundleID: game, name: "Game")
        preferences.setApp(game, disabled: true)
        // Keys no change may touch.
        preferences.automaticUpdates = true
        preferences.lastUpdateCheck = Date(timeIntervalSince1970: 1_000_000)
        preferences.hasCompletedOnboarding = true
        preferences.lastSettingsTab = 2
        preferences.lastSettingsTouchPane = 1
        store.set("someone else's", forKey: "NSNotOurs")
        return preferences
    }

    private func importFile(_ settings: String) -> Data {
        Data("""
        {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 3, "settings": \(settings)}
        """.utf8)
    }

    // MARK: - Round trip

    /// Every change the window can take back, each from the same full store, comes back to
    /// that store exactly: every key, bookkeeping included, with nothing left out of the
    /// comparison.
    func testEveryDestructiveChangeIsTakenBackExactly() throws {
        let fileWithCustomAction = importFile("""
        {"touchEnabled": false, "button.generic.3": "copy",
         "button.generic.4": "{\\"kind\\":\\"openURL\\",\\"url\\":\\"https://example.org\\"}"}
        """)

        let changes: [(String, SettingsChange, (Preferences) throws -> Void)] = [
            ("import", .importFile(name: "a.json"), { try $0.importSettings(fileWithCustomAction) }),
            ("import without custom actions", .importFile(name: "a.json"), {
                $0.applySettings(try $0.readSettings(fileWithCustomAction).withoutCustomActions())
            }),
            ("mouse defaults", .restoreDefaults(.mouse, app: nil), { $0.restoreMouseDefaults(profile: .mxMaster4) }),
            ("mouse defaults for an app", .restoreDefaults(.mouse, app: "Example"), { preferences in
                preferences.clearAppBindings(app: self.app) { key in
                    [
                        SettingsKey.buttonPrefix, SettingsKey.buttonHoldPrefix,
                        SettingsKey.buttonDoublePrefix, SettingsKey.buttonDragPrefix,
                    ].contains(where: key.hasPrefix)
                }
                preferences.setAppScrollOverride(.none, app: self.app)
            }),
            ("cursor defaults", .restoreDefaults(.cursor, app: nil), { $0.restoreCursorDefaults() }),
            ("touch defaults", .restoreDefaults(.touch, app: nil), { $0.restoreTouchDefaults() }),
            ("touch defaults for an app", .restoreDefaults(.touch, app: "Example"), {
                $0.clearAppBindings(app: self.app) {
                    $0.hasPrefix(SettingsKey.touchPrefix) || $0.hasPrefix(SettingsKey.characterPrefix)
                }
            }),
            ("remove app", .removeApp(name: "Example"), { $0.removeApp(bundleID: self.app) }),
        ]

        for (name, change, run) in changes {
            store.removePersistentDomain(forName: suiteName)
            let preferences = populated()
            let original = domain

            try preferences.recordingUndo(change) { try run(preferences) }
            XCTAssertNotEqual(domain, original, "\(name) changed something")
            XCTAssertEqual(preferences.undoPoint?.change, change, name)

            let reverted = preferences.revertLastChange()
            XCTAssertEqual(reverted?.change, change, name)
            XCTAssertEqual(domain, original, "\(name) taken back exactly")
            XCTAssertNil(preferences.undoPoint, "\(name): an undo point is used once")
        }
    }

    func testTheRevertedSettingsAreReadFresh() {
        let preferences = populated()
        _ = preferences.appOverrides  // fills the cache
        preferences.recordingUndo(.removeApp(name: "Example")) { preferences.removeApp(bundleID: app) }
        XCTAssertNil(preferences.appOverrides[app])

        preferences.revertLastChange()
        XCTAssertEqual(preferences.appBinding(for: .button(3, .mxMaster4), app: app), .builtin(.paste))
        XCTAssertTrue(preferences.isAnyScrollSettingActive)
    }

    func testRevertingPostsWhatAnImportPosts() {
        let preferences = populated()
        preferences.recordingUndo(.restoreDefaults(.touch, app: nil)) { preferences.restoreTouchDefaults() }

        var areas: [SettingsArea] = []
        let observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChangeNotification, object: nil, queue: nil
        ) { areas.append($0.settingsArea) }
        defer { NotificationCenter.default.removeObserver(observer) }

        preferences.revertLastChange()
        XCTAssertEqual(areas, [.all])
    }

    // MARK: - Which change is kept

    func testANewerChangeReplacesTheUndoPoint() throws {
        let preferences = populated()
        try preferences.recordingUndo(.importFile(name: "a.json")) {
            try preferences.importSettings(importFile(#"{"key.activate": 41}"#))
        }
        let afterImport = domain
        preferences.recordingUndo(.restoreDefaults(.cursor, app: nil)) { preferences.restoreCursorDefaults() }

        XCTAssertEqual(preferences.undoPoint?.change, .restoreDefaults(.cursor, app: nil))
        preferences.revertLastChange()
        XCTAssertEqual(domain, afterImport, "only the newer change is taken back")
        XCTAssertNil(preferences.revertLastChange(), "and there is nothing further back")
    }

    func testAChangeThatChangedNothingKeepsTheEarlierUndoPoint() {
        let preferences = populated()
        preferences.recordingUndo(.restoreDefaults(.touch, app: nil)) { preferences.restoreTouchDefaults() }
        preferences.recordingUndo(.restoreDefaults(.touch, app: nil), at: Date.distantFuture) {
            preferences.restoreTouchDefaults()
        }
        XCTAssertNotEqual(preferences.undoPoint?.date, Date.distantFuture, "the first one is still there")
        XCTAssertFalse(preferences.isLeftHanded)

        preferences.revertLastChange()
        XCTAssertTrue(preferences.isLeftHanded)
    }

    func testAChangeThatFailsLeavesNoUndoPoint() {
        struct Refused: Error {}
        let preferences = populated()
        XCTAssertThrowsError(try preferences.recordingUndo(.importFile(name: "bad.json")) {
            try preferences.importSettings(Data("not json".utf8))
        })
        XCTAssertNil(preferences.undoPoint)

        // A change that wrote something before it failed is not offered back either: the
        // window never sees it as made.
        XCTAssertThrowsError(try preferences.recordingUndo(.removeApp(name: "Example")) {
            preferences.removeApp(bundleID: app)
            throw Refused()
        })
        XCTAssertNil(preferences.undoPoint)
    }

    func testNothingToRevertChangesNothing() {
        let preferences = populated()
        let original = domain
        XCTAssertNil(preferences.revertLastChange())
        XCTAssertEqual(domain, original)
    }

    // MARK: - Keys each Mac keeps

    /// Neither the import nor its reverting touches what each Mac keeps for itself, so an
    /// answer given in between stands.
    func testRevertingAnImportKeepsWhatThisMacAnsweredSince() throws {
        let preferences = populated()
        try preferences.recordingUndo(.importFile(name: "a.json")) {
            try preferences.importSettings(importFile("{}"))
        }
        XCTAssertEqual(preferences.automaticUpdates, true, "the import left it alone")
        preferences.automaticUpdates = false
        preferences.lastSettingsTab = 3

        preferences.revertLastChange()
        XCTAssertEqual(preferences.automaticUpdates, false)
        XCTAssertEqual(preferences.lastSettingsTab, 3)
        XCTAssertTrue(preferences.isLeftHanded, "the rest is back")
    }

    // MARK: - Labels

    func testEachChangeIsNamedToFollowUndo() {
        XCTAssertEqual(SettingsChange.importFile(name: "file.json").label, "the import of “file.json”")
        XCTAssertEqual(SettingsChange.restoreDefaults(.touch, app: nil).label, "Restore Defaults on the Touch tab")
        XCTAssertEqual(
            SettingsChange.restoreDefaults(.cursor, app: nil).label,
            "Restore Defaults on the Keyboard Cursor tab"
        )
        XCTAssertEqual(
            SettingsChange.restoreDefaults(.mouse, app: "Safari").label,
            "Restore Defaults on the Mouse tab for Safari"
        )
        XCTAssertEqual(SettingsChange.removeApp(name: "Safari").label, "removing the settings for Safari")
    }

    func testNamesFromOutsideAreMadeSafeToShow() {
        XCTAssertEqual(
            SettingsChange.importFile(name: "a\u{202E}nosj.b\nc.json").label,
            "the import of “anosj.b c.json”"
        )
    }
}
