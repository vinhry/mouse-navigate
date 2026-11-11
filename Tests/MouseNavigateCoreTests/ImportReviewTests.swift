import XCTest
@testable import MouseNavigateCore

@MainActor
final class ImportReviewTests: XCTestCase {
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

    /// A file as someone might share it: ordinary settings, with custom actions for all
    /// apps and others tucked into two apps' bindings, one of them under an older key.
    private let crafted = #"""
    {"format": "MouseNavigate settings", "schemaVersion": 1, "configVersion": 3,
     "settings": {
       "touchEnabled": true,
       "button.mxMaster4.5": "newTab",
       "button.mxMaster4.3": "{\"type\":\"openURL\",\"url\":\"file:\\/\\/\\/Users\\/someone\\/Downloads\\/x.command\"}",
       "buttonHold.generic.4+cmd": "{\"keyCode\":12,\"modifiers\":[\"command\"],\"type\":\"shortcut\"}",
       "touch.trackpadThreeFingerTap": "{\"bundleID\":\"com.example.evil\",\"name\":\"Safari\",\"type\":\"launchApp\"}",
       "button7": "{\"name\":\"Wipe\",\"type\":\"runShortcut\"}",
       "appOverrides": {
         "com.apple.Safari": {"name": "Safari", "disabled": false,
           "bindings": {"character.t": "newTab",
                        "character.b": "{\"type\":\"openURL\",\"url\":\"smb:\\/\\/host\\/share\"}"},
           "scroll": {"smooth": true}},
         "com.example.game": {"name": "Game", "disabled": true,
           "bindings": {"buttonDrag.mxMaster3.32.up": "{\"name\":\"Do it\",\"type\":\"runShortcut\"}"}},
         "com.example.plain": {"name": "Plain", "bindings": {"character.c": "copy"}}
       }
     }}
    """#

    private func read() throws -> SettingsSnapshot.ReadResult {
        try SettingsSnapshot.read(Data(crafted.utf8), currentConfigVersion: 3)
    }

    // MARK: - Listing

    func testEveryCustomActionIsListedGloballyAndPerApp() throws {
        let actions = try read().snapshot.customActions
        XCTAssertEqual(actions.map(\.summary), [
            "Logitech MX Master 4: Button 3 Click → Open file:///Users/someone/Downloads/x.command",
            "button7 → Run Shortcut “Wipe”",
            "Generic Mouse: ⌘ Button 4 Hold → Shortcut ⌘Q",
            "Trackpad: Three-Finger Tap → Launch Safari (com.example.evil)",
            "Drawing: B in com.apple.Safari → Open smb://host/share",
            "Logitech MX Master 3: Gesture button Drag ↑ in com.example.game → Run Shortcut “Do it”",
        ])
        XCTAssertEqual(actions.map(\.bundleID), [nil, nil, nil, nil, "com.apple.Safari", "com.example.game"])
        XCTAssertEqual(actions[2].binding, .shortcut(Shortcut(KeyCode.q, [.command])))
    }

    func testAFileOfBuiltInActionsListsNothing() throws {
        let store = makeStore()
        let preferences = Preferences(store: store)
        preferences.setGlobalBinding(.builtin(.newTab), for: .button(5, .mxMaster4))
        preferences.addApp(bundleID: "com.example.app", name: "Example")
        preferences.setAppBinding(.builtin(.copy), for: .character(.c), app: "com.example.app")
        let result = try preferences.readSettings(try preferences.exportSettings(appVersion: nil))
        XCTAssertEqual(result.snapshot.customActions, [])
    }

    func testTextFromTheFileCannotBreakTheList() {
        let action = SettingsSnapshot.CustomAction(
            key: "button.mxMaster4.3",
            bundleID: "com.example\n\u{202E}ppa",
            binding: .runShortcut(name: "One\nTwo\u{2028}Three")
        )
        XCTAssertEqual(action.summary, "Logitech MX Master 4: Button 3 Click in com.example ppa → Run Shortcut “One Two Three”")
    }

    // MARK: - Leaving them out

    func testWithoutCustomActionsRemovesExactlyThose() throws {
        let result = try read()
        let stripped = result.withoutCustomActions()
        XCTAssertEqual(stripped.snapshot.customActions, [])
        XCTAssertEqual(stripped.ignoredKeys, result.ignoredKeys)

        var expected = result.snapshot.values
        for key in ["button.mxMaster4.3", "buttonHold.generic.4+cmd", "touch.trackpadThreeFingerTap", "button7"] {
            XCTAssertNotNil(expected.removeValue(forKey: key), key)
        }
        expected[SettingsKey.appOverrides] = .dictionary([
            "com.apple.Safari": .dictionary([
                "name": .string("Safari"), "disabled": .bool(false),
                "bindings": .dictionary(["character.t": .string("newTab")]),
                "scroll": .dictionary(["smooth": .bool(true)]),
            ]),
            "com.example.game": .dictionary([
                "name": .string("Game"), "disabled": .bool(true), "bindings": .dictionary([:]),
            ]),
            "com.example.plain": .dictionary([
                "name": .string("Plain"), "bindings": .dictionary(["character.c": .string("copy")]),
            ]),
        ])
        XCTAssertEqual(stripped.snapshot.values, expected)
        XCTAssertEqual(stripped.snapshot.configVersion, result.snapshot.configVersion)
    }

    func testImportingWithoutThemLeavesThoseInputsAtTheirDefaults() throws {
        let preferences = Preferences(store: makeStore())
        preferences.setGlobalBinding(.shortcut(Shortcut(KeyCode.k, [.command])), for: .button(3, .mxMaster4))

        preferences.applySettings(try read().withoutCustomActions())

        XCTAssertEqual(preferences.globalBinding(for: .button(3, .mxMaster4)), .builtin(.back), "the default, not what was there")
        XCTAssertEqual(preferences.globalBinding(for: .button(4, .generic, .hold, [.command])), .disabled)
        XCTAssertEqual(preferences.globalBinding(for: .touch(.trackpadThreeFingerTap)), BindingTrigger.touch(.trackpadThreeFingerTap).defaultBinding)
        XCTAssertNil(preferences.appBinding(for: .character(.b), app: "com.apple.Safari"), "follows all apps again")
        XCTAssertEqual(preferences.appBinding(for: .character(.t), app: "com.apple.Safari"), .builtin(.newTab))
        XCTAssertTrue(preferences.isAppDisabled("com.example.game"), "the rest of the entry is kept")
        XCTAssertEqual(preferences.globalBinding(for: .button(5, .mxMaster4)), .builtin(.newTab))
        XCTAssertTrue(preferences.isTouchEnabled)
    }

    func testImportingEverythingKeepsThem() throws {
        let preferences = Preferences(store: makeStore())
        preferences.applySettings(try read())
        XCTAssertEqual(preferences.globalBinding(for: .button(4, .generic, .hold, [.command])), .shortcut(Shortcut(KeyCode.q, [.command])))
        XCTAssertEqual(preferences.appBinding(for: .character(.b), app: "com.apple.Safari"), .openURL(URL(string: "smb://host/share")!))
    }
}
