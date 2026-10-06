import XCTest
@testable import MouseNavigateCore

final class ActionBindingTests: XCTestCase {
    func testBuiltinStoresAsBareRawValue() {
        // Settings written before bindings existed must keep reading back unchanged.
        XCTAssertEqual(ActionBinding.builtin(.missionControl).storageValue, "missionControl")
        XCTAssertEqual(ActionBinding(storageValue: "back"), .builtin(.back))
    }

    func testEveryBuiltinRoundTrips() {
        for action in ButtonAction.allCases {
            let binding = ActionBinding.builtin(action)
            XCTAssertEqual(ActionBinding(storageValue: binding.storageValue), binding)
        }
    }

    func testCustomBindingsRoundTrip() {
        let bindings: [ActionBinding] = [
            .shortcut(Shortcut(KeyCode.k, [.command, .shift])),
            .shortcut(Shortcut(KeyCode.space, [])),
            .shortcut(Shortcut(KeyCode.t, [.control, .option, .shift, .command])),
            .launchApp(bundleID: "com.figma.Desktop", name: "Figma"),
            .openURL(URL(string: "https://github.com/vinhry/mouse-navigate")!),
            .runShortcut(name: "Toggle “Focus”"),
        ]
        for binding in bindings {
            XCTAssertEqual(ActionBinding(storageValue: binding.storageValue), binding, "\(binding)")
        }
    }

    func testShortcutStoresReadableModifierNames() {
        let value = ActionBinding.shortcut(Shortcut(KeyCode.k, [.command, .shift])).storageValue
        XCTAssertTrue(value.contains("\"command\""), value)
        XCTAssertTrue(value.contains("\"shift\""), value)
    }

    func testUnreadableValuesAreRejected() {
        for value in [
            "",
            "notAnAction",
            "{",
            #"{"type":"teleport"}"#,
            #"{"type":"shortcut"}"#,
            #"{"type":"shortcut","keyCode":40,"modifiers":["hyper"]}"#,
            #"{"type":"launchApp","bundleID":""}"#,
            #"{"type":"openURL","url":"not a url"}"#,
            #"{"type":"runShortcut"}"#,
        ] {
            XCTAssertNil(ActionBinding(storageValue: value), value)
        }
    }

    func testShortcutDisplayOrderMatchesMenus() {
        let shortcut = Shortcut(KeyCode.k, [.command, .shift, .option, .control])
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘K")
    }

    func testValidURL() {
        XCTAssertEqual(ActionBinding.validURL("https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(ActionBinding.validURL("  example.com ")?.absoluteString, "https://example.com")
        XCTAssertEqual(ActionBinding.validURL("mailto:me@example.com")?.scheme, "mailto")
        XCTAssertNil(ActionBinding.validURL(""))
        XCTAssertNil(ActionBinding.validURL("not a url"))
        XCTAssertNil(ActionBinding.validURL("nothing"))
    }

    func testTriggerKeysMatchExistingSettings() {
        XCTAssertEqual(BindingTrigger.button(3, .mxMaster4).storageKey, "button.mxMaster4.3")
        XCTAssertEqual(BindingTrigger.touch(.trackpadThreeFingerTap).storageKey, "touch.trackpadThreeFingerTap")
        XCTAssertEqual(BindingTrigger.character(.t).storageKey, "character.t")
    }

    func testMoveResizeOnlyWhereItCanBeDriven() {
        let moveResize = ActionBinding.builtin(.moveResizeWindow)
        XCTAssertFalse(BindingTrigger.button(5, .generic).allows(moveResize))
        XCTAssertFalse(BindingTrigger.character(.m).allows(moveResize))
        XCTAssertFalse(BindingTrigger.touch(.trackpadThreeFingerTap).allows(moveResize))
        XCTAssertTrue(BindingTrigger.touch(.mouseCornerHold).allows(moveResize))

        let custom = ActionBinding.shortcut(Shortcut(KeyCode.k, [.command]))
        XCTAssertTrue(BindingTrigger.button(5, .generic).allows(custom))
    }

    func testDefaultsComeFromProfileAndGestures() {
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4).defaultBinding, .builtin(.appExpose))
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster3).defaultBinding, .disabled)
        XCTAssertEqual(BindingTrigger.character(.t).defaultBinding, .builtin(.newTab))
    }
}

final class BindingResolverTests: XCTestCase {
    private let trigger = BindingTrigger.button(5, .mxMaster4)
    private let global: (BindingTrigger) -> ActionBinding = { _ in .builtin(.missionControl) }

    func testFallsBackToGlobalWithNoApp() {
        XCTAssertEqual(
            BindingResolver.resolve(trigger, frontmost: nil, overrides: [:], global: global),
            .builtin(.missionControl)
        )
    }

    func testAppBindingWins() {
        let figma = AppOverride(
            bundleID: "com.figma.Desktop",
            name: "Figma",
            bindings: [trigger.storageKey: ActionBinding.shortcut(Shortcut(KeyCode.k, [.command])).storageValue]
        )
        XCTAssertEqual(
            BindingResolver.resolve(trigger, frontmost: "com.figma.Desktop", overrides: [figma.bundleID: figma], global: global),
            .shortcut(Shortcut(KeyCode.k, [.command]))
        )
    }

    func testOtherAppsAndUnboundTriggersFallThrough() {
        let figma = AppOverride(
            bundleID: "com.figma.Desktop",
            name: "Figma",
            bindings: ["button.mxMaster4.6": "showDesktop"]
        )
        let overrides = [figma.bundleID: figma]
        XCTAssertEqual(
            BindingResolver.resolve(trigger, frontmost: "com.apple.Safari", overrides: overrides, global: global),
            .builtin(.missionControl)
        )
        XCTAssertEqual(
            BindingResolver.resolve(trigger, frontmost: "com.figma.Desktop", overrides: overrides, global: global),
            .builtin(.missionControl)
        )
    }

    func testBadOrDisallowedAppBindingFallsThrough() {
        let app = AppOverride(
            bundleID: "x",
            name: "X",
            bindings: [
                trigger.storageKey: "garbage",
                "button.mxMaster4.6": "moveResizeWindow",
            ]
        )
        XCTAssertEqual(
            BindingResolver.resolve(trigger, frontmost: "x", overrides: ["x": app], global: global),
            .builtin(.missionControl)
        )
        XCTAssertEqual(
            BindingResolver.resolve(.button(6, .mxMaster4), frontmost: "x", overrides: ["x": app], global: global),
            .builtin(.missionControl)
        )
    }

    func testDisabledAppGetsNothing() {
        let game = AppOverride(bundleID: "game", name: "Game", isDisabled: true, bindings: [trigger.storageKey: "back"])
        XCTAssertEqual(
            BindingResolver.resolve(trigger, frontmost: "game", overrides: ["game": game], global: global),
            .disabled
        )
    }

    func testPropertyListRoundTrip() {
        let entry = AppOverride(bundleID: "com.figma.Desktop", name: "Figma", isDisabled: true, bindings: ["character.t": "newTab"])
        let decoded = AppOverride.decodeAll(AppOverride.encodeAll([entry.bundleID: entry]))
        XCTAssertEqual(decoded, [entry.bundleID: entry])
    }

    func testMalformedEntriesAreDropped() {
        let decoded = AppOverride.decodeAll([
            "good": ["name": "Good"],
            "bad": "not a dictionary",
            "": ["name": "Empty ID"],
        ] as [String: Any])
        XCTAssertEqual(Array(decoded.keys), ["good"])
        XCTAssertEqual(AppOverride.decodeAll(nil), [:])
    }

    func testBuiltInShortcutsNameTheirLetter() {
        // Sent by letter on the layout in use; the key code is only the US position.
        XCTAssertEqual(ButtonAction.closeTab.shortcut, Shortcut(KeyCode.w, [.command], character: "w"))
        XCTAssertEqual(ButtonAction.back.shortcut?.character, "[")
        // Tab is the same key everywhere, so it has no letter to look up.
        XCTAssertNil(ButtonAction.nextTab.shortcut?.character)
        for action in ButtonAction.allCases {
            guard let shortcut = action.shortcut, let character = shortcut.character else { continue }
            XCTAssertEqual(KeyCodeNames.name(for: shortcut.keyCode).lowercased(), String(character), "\(action)")
        }
    }

    func testOneUnreadableBindingValueDoesNotDropTheOthers() {
        let decoded = AppOverride.decodeAll([
            "com.figma.Desktop": [
                "name": "Figma",
                "bindings": ["character.t": "newTab", "button.generic.3": 42] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertEqual(decoded["com.figma.Desktop"]?.bindings, ["character.t": "newTab"])
    }
}
