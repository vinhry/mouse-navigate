import XCTest
@testable import MouseNavigateCore

final class SupportedAppsTests: XCTestCase {
    func testBrowsersAndFinderAreSupported() {
        for bundleID in ["com.apple.Safari", "com.apple.finder", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser"] {
            XCTAssertTrue(SupportedApps.isSupported(bundleID: bundleID), bundleID)
        }
    }

    func testOtherAppsAndNoAppAreNot() {
        XCTAssertFalse(SupportedApps.isSupported(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(SupportedApps.isSupported(bundleID: "com.apple.safari"), "bundle identifiers are matched exactly")
        XCTAssertFalse(SupportedApps.isSupported(bundleID: nil))
    }
}

final class KeyCodeNamesTests: XCTestCase {
    func testDigitsAndArrowsHaveNames() {
        XCTAssertEqual(KeyCode.digits.map(KeyCodeNames.name(for:)), ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertEqual(KeyCodeNames.name(for: KeyCode.leftArrow), "←")
        XCTAssertEqual(KeyCodeNames.name(for: KeyCode.rightArrow), "→")
    }

    func testEveryNamedKeyCodeHasItsLetter() {
        let letters: [(UInt16, String)] = [
            (KeyCode.a, "A"), (KeyCode.s, "S"), (KeyCode.d, "D"), (KeyCode.f, "F"), (KeyCode.g, "G"),
            (KeyCode.h, "H"), (KeyCode.i, "I"), (KeyCode.j, "J"), (KeyCode.k, "K"), (KeyCode.l, "L"),
            (KeyCode.u, "U"), (KeyCode.m, "M"), (KeyCode.comma, ","), (KeyCode.period, "."),
            (KeyCode.semicolon, ";"), (KeyCode.space, "Space"), (KeyCode.escape, "Esc"),
            (KeyCode.returnKey, "Return"), (KeyCode.delete, "Delete"), (KeyCode.tab, "Tab"),
        ]
        for (code, name) in letters {
            XCTAssertEqual(KeyCodeNames.name(for: code), name)
        }
    }
}
