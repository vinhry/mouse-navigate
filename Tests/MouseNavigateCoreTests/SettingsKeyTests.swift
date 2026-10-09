import XCTest
@testable import MouseNavigateCore

final class SettingsKeyTests: XCTestCase {
    /// Every key the app can write, built the way the app builds it.
    private var everyCurrentKey: [String] {
        var keys = Array(SettingsKey.fixed.keys)
        for profile in DeviceProfile.allCases {
            for button in Preferences.configurableButtons {
                for press in ButtonPress.allCases {
                    keys.append(BindingTrigger.button(button, profile, press).storageKey)
                }
            }
        }
        keys += TouchGesture.allCases.map { BindingTrigger.touch($0).storageKey }
        keys += CharacterGesture.allCases.map { BindingTrigger.character($0).storageKey }
        keys += CursorBinding.allCases.map(SettingsKey.cursorKey)
        keys += CursorSetting.allCases.map(SettingsKey.cursorSetting)
        keys += CharacterSource.allCases.map(SettingsKey.characterSource)
        for field in ScrollField.allCases {
            keys.append(SettingsKey.scroll(field))
            keys += DeviceProfile.allCases.map { SettingsKey.scroll(field, profile: $0) }
        }
        return keys
    }

    func testEveryCurrentKeyHasAType() {
        for key in everyCurrentKey {
            XCTAssertNotNil(SettingsKey.type(of: key), key)
        }
    }

    func testBindingKeysAreStrings() {
        XCTAssertEqual(SettingsKey.type(of: BindingTrigger.button(3, .mxMaster4).storageKey), .string)
        XCTAssertEqual(SettingsKey.type(of: BindingTrigger.button(3, .mxMaster4, .hold).storageKey), .string)
        XCTAssertEqual(SettingsKey.type(of: BindingTrigger.button(3, .mxMaster4, .doubleClick).storageKey), .string)
        XCTAssertEqual(SettingsKey.type(of: BindingTrigger.touch(.trackpadThreeFingerTap).storageKey), .string)
        XCTAssertEqual(SettingsKey.type(of: BindingTrigger.character(.t).storageKey), .string)
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.cursorKey(.activate)), .int)
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.cursorSetting(.baseSpeed)), .double)
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.characterSource(.trackpad)), .bool)
    }

    func testNoKeyBelongsToTwoFamilies() {
        for key in everyCurrentKey {
            let families = SettingsKey.families.filter { $0.contains(key) }
            XCTAssertLessThanOrEqual(families.count, 1, key)
            if !families.isEmpty {
                XCTAssertNil(SettingsKey.fixed[key], "\(key) is both fixed and in a family")
            }
        }
    }

    func testAPrefixAloneIsNotAKey() {
        for family in SettingsKey.families {
            XCTAssertNil(SettingsKey.type(of: family.prefix), family.prefix)
        }
    }

    func testEveryCurrentKeyButTheUpdateStampIsExportable() {
        for key in everyCurrentKey where key != SettingsKey.lastUpdateCheck {
            XCTAssertTrue(SettingsKey.isExportable(key), key)
        }
        XCTAssertFalse(SettingsKey.isExportable(SettingsKey.lastUpdateCheck))
    }

    func testLegacyKeysAreKnownButNotExported() {
        for button in Preferences.configurableButtons {
            let key = SettingsKey.legacyButton(button)
            XCTAssertEqual(SettingsKey.type(of: key), .string)
            XCTAssertTrue(SettingsKey.isSetting(key))
            XCTAssertFalse(SettingsKey.isExportable(key))
        }
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.legacyScrollReversed), .bool)
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.legacyScrollSpeed), .double)
        XCTAssertFalse(SettingsKey.isExportable(SettingsKey.legacyScrollSpeed))
    }

    func testScrollKeysAreTypedByField() {
        XCTAssertEqual(SettingsKey.scroll(.reverse), "scroll.reverse")
        XCTAssertEqual(SettingsKey.scroll(.smooth, profile: .mxMaster4), "scroll.mxMaster4.smooth")
        XCTAssertEqual(SettingsKey.type(of: "scroll.reverse"), .string)
        XCTAssertEqual(SettingsKey.type(of: "scroll.generic.verticalSpeed"), .double)
        XCTAssertEqual(SettingsKey.type(of: "scroll.mxMaster3.commandFast"), .bool)
        XCTAssertNil(SettingsKey.type(of: "scroll.mxMaster3.unknown"))
    }

    func testForeignKeysAreNotSettings() {
        for key in ["AppleLanguages", "NSNavLastRootDirectory", "buttonless", "scroll", "", "key"] {
            XCTAssertNil(SettingsKey.type(of: key), key)
            XCTAssertFalse(SettingsKey.isExportable(key), key)
        }
    }

    func testUserSettingKeysLeaveTheGlobalDomainOut() {
        let suite = "MouseNavigateTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: SettingsKey.touchEnabled)
        store.set("back", forKey: BindingTrigger.button(3, .generic).storageKey)
        store.set("x", forKey: "SomethingElse")

        XCTAssertEqual(
            SettingsKey.userSettingKeys(in: store),
            [BindingTrigger.button(3, .generic).storageKey, SettingsKey.touchEnabled]
        )
    }
}
