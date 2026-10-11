import XCTest
@testable import MouseNavigateCore

final class SymbolicHotKeysTests: XCTestCase {
    private func entry(enabled: Any = true, parameters: [Any]) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]
    }

    func testReadsEnabledShortcuts() {
        let domain: [String: Any] = ["AppleSymbolicHotKeys": [
            "79": entry(parameters: [65535, 123, 8_650_752]),
            "32": entry(parameters: [65535, 126, 262_144]),
        ]]
        let parsed = SymbolicHotKeys.parse(domain)
        XCTAssertEqual(parsed[SymbolicHotKeys.spaceLeft], SymbolicHotKey(keyCode: 123, flags: 8_650_752))
        XCTAssertEqual(parsed[SymbolicHotKeys.missionControl], SymbolicHotKey(keyCode: 126, flags: 262_144))
    }

    func testLeavesOutDisabledShortcuts() {
        let domain: [String: Any] = ["AppleSymbolicHotKeys": [
            "30": entry(enabled: false, parameters: [52, 21, 1_179_648]),
            "36": entry(enabled: 0, parameters: [65535, 103, 8_388_608]),
        ]]
        XCTAssertTrue(SymbolicHotKeys.parse(domain).isEmpty)
    }

    func testReadsNumbersWrittenAsStrings() {
        let domain: [String: Any] = ["AppleSymbolicHotKeys": [
            "81": entry(enabled: "1", parameters: ["65535", "124", "8650752"]),
        ]]
        XCTAssertEqual(
            SymbolicHotKeys.parse(domain)[SymbolicHotKeys.spaceRight],
            SymbolicHotKey(keyCode: 124, flags: 8_650_752)
        )
    }

    func testSkipsMalformedEntries() {
        let domain: [String: Any] = ["AppleSymbolicHotKeys": [
            "30": entry(parameters: [52, 21]),
            "32": ["enabled": true],
            "33": entry(parameters: [65535, "x", 0]),
            "36": entry(parameters: [65535, 70_000, 0]),
            "79": entry(parameters: [65535, 123, -1]),
            "60": entry(parameters: [32, 65535, 262_144]),
            "64": ["enabled": true],
            "abc": entry(parameters: [65535, 1, 0]),
            "81": "not a dictionary",
        ]]
        XCTAssertTrue(SymbolicHotKeys.parse(domain).isEmpty)
    }

    func testEmptyOrForeignDomain() {
        XCTAssertTrue(SymbolicHotKeys.parse([:]).isEmpty)
        XCTAssertTrue(SymbolicHotKeys.parse(["AppleSymbolicHotKeys": [1, 2]]).isEmpty)
    }

    func testMediaKeyEncoding() {
        XCTAssertEqual(MediaKey.play.data1(isDown: true), 0x10_0A00)
        XCTAssertEqual(MediaKey.play.data1(isDown: false), 0x10_0B00)
        XCTAssertEqual(MediaKey.soundUp.data1(isDown: true), 0x0A00)
        XCTAssertEqual(MediaKey.modifierFlags(isDown: true), 0xA00)
        XCTAssertEqual(MediaKey.modifierFlags(isDown: false), 0xB00)
    }
}
