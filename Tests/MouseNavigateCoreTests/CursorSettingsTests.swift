import XCTest
@testable import MouseNavigateCore

final class CursorSettingsTests: XCTestCase {
    func testDefaultsMatchTheRequestedLayout() {
        XCTAssertEqual(CursorBinding.activate.defaultKeyCode, KeyCode.a)
        XCTAssertEqual(CursorBinding.leftClick.defaultKeyCode, KeyCode.s)
        XCTAssertEqual(CursorBinding.rightClick.defaultKeyCode, KeyCode.d)
        XCTAssertEqual(CursorBinding.moveUp.defaultKeyCode, KeyCode.i)
        XCTAssertEqual(CursorBinding.moveDown.defaultKeyCode, KeyCode.k)
        XCTAssertEqual(CursorBinding.moveLeft.defaultKeyCode, KeyCode.j)
        XCTAssertEqual(CursorBinding.moveRight.defaultKeyCode, KeyCode.l)
    }

    func testDefaultBindingsAreUnique() {
        let codes = CursorBinding.allCases.map(\.defaultKeyCode)
        XCTAssertEqual(Set(codes).count, codes.count, "two actions share a default key")
    }

    func testEveryDefaultValueSitsInsideItsRange() {
        for setting in CursorSetting.allCases {
            XCTAssertTrue(
                setting.range.contains(setting.defaultValue),
                "\(setting.rawValue) default is outside its slider range"
            )
        }
    }

    func testClampPinsToTheRange() {
        XCTAssertEqual(CursorSetting.holdThreshold.clamp(-5), CursorSetting.holdThreshold.range.lowerBound)
        XCTAssertEqual(CursorSetting.holdThreshold.clamp(99), CursorSetting.holdThreshold.range.upperBound)
        XCTAssertEqual(CursorSetting.holdThreshold.clamp(0.3), 0.3)
    }

    func testKeyCodeNamesCoverTheDefaults() {
        XCTAssertEqual(KeyCodeNames.name(for: KeyCode.a), "A")
        XCTAssertEqual(KeyCodeNames.name(for: KeyCode.semicolon), ";")
        XCTAssertEqual(KeyCodeNames.name(for: KeyCode.space), "Space")
        XCTAssertEqual(KeyCodeNames.name(for: KeyCode.escape), "Esc")
    }

    func testUnknownKeyCodeFallsBackToItsNumber() {
        XCTAssertEqual(KeyCodeNames.name(for: 250), "Key 250")
    }
}

final class SpeedTierTests: XCTestCase {
    private let profile = CursorSpeedProfile(fastMultiplier: 2, fasterMultiplier: 4, precisionMultiplier: 0.25)

    func testTiers() {
        XCTAssertEqual(SpeedTier().multiplier(using: profile), 1)
        XCTAssertEqual(SpeedTier.shift.multiplier(using: profile), 2)
        XCTAssertEqual(SpeedTier([.shift, .control]).multiplier(using: profile), 4)
        XCTAssertEqual(SpeedTier.control.multiplier(using: profile), 1, "Control alone is no tier")
    }

    func testOptionAlwaysWins() {
        XCTAssertEqual(SpeedTier([.option, .shift, .control]).multiplier(using: profile), 0.25)
        XCTAssertEqual(SpeedTier([.option, .shift]).multiplier(using: profile), 0.25)
    }

    func testTheDefaultProfileComesFromTheSettings() {
        let defaults = CursorSpeedProfile()
        XCTAssertEqual(defaults.baseSpeed, CursorSetting.baseSpeed.defaultValue)
        XCTAssertEqual(defaults.maxSpeed, CursorSetting.maxSpeed.defaultValue)
        XCTAssertEqual(defaults.scrollSpeed, CursorSetting.scrollSpeed.defaultValue)
        XCTAssertLessThan(defaults.baseSpeed, defaults.maxSpeed)
    }
}
