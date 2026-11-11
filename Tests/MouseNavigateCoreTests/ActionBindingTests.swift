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

    func testModifierCombinationsGetKeysOfTheirOwn() {
        XCTAssertEqual(BindingTrigger.button(3, .mxMaster4, .click, []).storageKey, "button.mxMaster4.3")
        XCTAssertEqual(BindingTrigger.button(3, .mxMaster4, .click, [.shift]).storageKey, "button.mxMaster4.3+shift")
        XCTAssertEqual(
            BindingTrigger.button(3, .mxMaster4, .click, [.command, .shift]).storageKey,
            "button.mxMaster4.3+shift+cmd"
        )
        XCTAssertEqual(
            BindingTrigger.button(5, .generic, .hold, [.control, .option, .shift, .command]).storageKey,
            "buttonHold.generic.5+ctrl+opt+shift+cmd"
        )
        XCTAssertEqual(BindingTrigger.button(4, .mxMaster3, .doubleClick, [.option]).storageKey, "buttonDouble.mxMaster3.4+opt")
    }

    func testModifierSuffixRoundTrips() {
        let sets: [Shortcut.Modifiers] = [[], [.shift], [.command], [.control, .option], [.control, .option, .shift, .command]]
        for modifiers in sets {
            XCTAssertEqual(Shortcut.Modifiers(storageSuffix: modifiers.storageSuffix), modifiers)
        }
        XCTAssertNil(Shortcut.Modifiers(storageSuffix: "shift"))
        XCTAssertNil(Shortcut.Modifiers(storageSuffix: "+hyper"))
        XCTAssertNil(Shortcut.Modifiers(storageSuffix: "+shift+shift"))
        XCTAssertNil(Shortcut.Modifiers(storageSuffix: "+"))
    }

    func testDragTriggersHaveKeysOfTheirOwn() {
        XCTAssertEqual(BindingTrigger.buttonDrag(5, .mxMaster4, .up).storageKey, "buttonDrag.mxMaster4.5.up")
        XCTAssertEqual(
            BindingTrigger.buttonDrag(5, .generic, .left, [.command]).storageKey,
            "buttonDrag.generic.5.left+cmd"
        )
        XCTAssertEqual(BindingTrigger.buttonDrag(5, .mxMaster4, .down).defaultBinding, .disabled)
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4, input: .drag(.right)), .buttonDrag(5, .mxMaster4, .right))
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4, input: .press(.hold), modifiers: [.shift]), .button(5, .mxMaster4, .hold, [.shift]))
        XCTAssertFalse(BindingTrigger.buttonDrag(5, .mxMaster4, .up).allows(.builtin(.moveResizeWindow)))
        XCTAssertTrue(BindingTrigger.buttonDrag(5, .mxMaster4, .up).allows(.builtin(.missionControl)))
    }

    func testACombinationStartsUnbound() {
        XCTAssertEqual(BindingTrigger.button(3, .mxMaster4, .click, [.shift]).defaultBinding, .disabled)
        XCTAssertEqual(BindingTrigger.button(3, .mxMaster4).defaultBinding, .builtin(.back))
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

    // MARK: - Reading a key back

    func testEveryTriggerReadsBackFromItsKey() {
        var triggers: [BindingTrigger] = TouchGesture.allCases.map { .touch($0) } + CharacterGesture.allCases.map { .character($0) }
        let modifierSets: [Shortcut.Modifiers] = [[], [.shift], [.control, .option, .shift, .command]]
        for profile in DeviceProfile.allCases {
            for button in Preferences.bindableButtons(for: profile) {
                for modifiers in modifierSets {
                    for press in ButtonPress.allCases {
                        triggers.append(.button(button, profile, press, modifiers))
                    }
                    for direction in DragDirection.allCases {
                        triggers.append(.buttonDrag(button, profile, direction, modifiers))
                    }
                }
            }
        }
        for trigger in triggers {
            XCTAssertEqual(BindingTrigger(storageKey: trigger.storageKey), trigger, trigger.storageKey)
        }
    }

    func testKeysNothingWritesNameNoTrigger() {
        for key in [
            "", "button.", "button.mxMaster4", "button.mxMaster9.3", "button.mxMaster4.x", "button.mxMaster4.03",
            "button.mxMaster4.3+hyper", "button.mxMaster4.3+cmd+shift", "buttonDrag.mxMaster4.3", "buttonDrag.mxMaster4.3.sideways",
            "button.mxMaster4.3.up", "touch.nothing", "character.i", "button3", "scroll.smooth",
        ] {
            XCTAssertNil(BindingTrigger(storageKey: key), key)
        }
    }

    func testTriggersAreNamedAsTheWindowNamesThem() {
        XCTAssertEqual(BindingTrigger.button(5, .mxMaster4).displayName, "Logitech MX Master 4: Button 5 Click")
        XCTAssertEqual(
            BindingTrigger.button(3, .generic, .hold, [.shift, .command]).displayName,
            "Generic Mouse: ⇧⌘ Button 3 Hold"
        )
        XCTAssertEqual(
            BindingTrigger.buttonDrag(LogitechControl.gestureButton.button, .mxMaster3, .up).displayName,
            "Logitech MX Master 3: Gesture button Drag ↑"
        )
        XCTAssertEqual(BindingTrigger.touch(.trackpadThreeFingerTap).displayName, "Trackpad: Three-Finger Tap")
        XCTAssertEqual(BindingTrigger.character(.b).displayName, "Drawing: B")
    }

    func testFullDescriptionLeavesNothingOut() {
        let url = URL(string: "file:///Users/someone/Downloads/x.command")!
        XCTAssertEqual(ActionBinding.openURL(url).displayName, "Open file:///Users/someone/Downloads/x.command", "no host to show")
        XCTAssertEqual(
            ActionBinding.openURL(URL(string: "https://example.com/a/b?c=d")!).fullDescription,
            "Open https://example.com/a/b?c=d"
        )
        XCTAssertEqual(
            ActionBinding.launchApp(bundleID: "com.example.evil", name: "Safari").fullDescription,
            "Launch Safari (com.example.evil)"
        )
        XCTAssertEqual(ActionBinding.launchApp(bundleID: "com.example.app", name: "com.example.app").fullDescription, "Launch com.example.app")
        XCTAssertEqual(ActionBinding.shortcut(Shortcut(KeyCode.q, [.command])).fullDescription, "Shortcut ⌘Q")
        XCTAssertEqual(ActionBinding.runShortcut(name: "Wipe").fullDescription, "Run Shortcut “Wipe”")
        XCTAssertFalse(ActionBinding.builtin(.back).isCustom)
        XCTAssertTrue(ActionBinding.runShortcut(name: "Wipe").isCustom)
    }

    // MARK: - Link kinds

    func testWebAndMailLinksAreOrdinary() {
        for text in ["https://example.com", "http://example.com", "HTTPS://EXAMPLE.COM", "HtTp://example.com",
                     "mailto:me@example.com", "MAILTO:me@example.com", "example.com"] {
            XCTAssertEqual(ActionBinding.linkKind(of: text), .ordinary, text)
        }
    }

    func testOtherSchemesAreNamedLowercased() {
        XCTAssertEqual(ActionBinding.linkKind(of: "file:///Users/someone/x.command"), .other(scheme: "file"))
        XCTAssertEqual(ActionBinding.linkKind(of: "FILE:///tmp/x"), .other(scheme: "file"))
        XCTAssertEqual(ActionBinding.linkKind(of: "javascript:alert(1)"), .other(scheme: "javascript"))
        XCTAssertEqual(ActionBinding.linkKind(of: "smb://host/share"), .other(scheme: "smb"))
        XCTAssertEqual(ActionBinding.linkKind(of: "shortcuts://run-shortcut?name=x"), .other(scheme: "shortcuts"))
        XCTAssertEqual(ActionBinding.linkKind(of: "raycast://extensions/x"), .other(scheme: "raycast"))
        XCTAssertEqual(ActionBinding.linkKind(of: URL(string: "x-apple.systempreferences:com.apple.preference")!), .other(scheme: "x-apple.systempreferences"))
    }

    func testEmptyAndInvalidLinksAreInvalid() {
        for text in ["", "   ", "not a url", "nothing"] {
            XCTAssertEqual(ActionBinding.linkKind(of: text), .invalid, text)
        }
        XCTAssertEqual(ActionBinding.linkKind(of: URL(string: "relative/path")!), .invalid)
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
