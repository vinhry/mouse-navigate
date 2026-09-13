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
