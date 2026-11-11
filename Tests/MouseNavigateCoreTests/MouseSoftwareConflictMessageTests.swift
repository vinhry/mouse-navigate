import XCTest
@testable import MouseNavigateCore

final class MouseSoftwareConflictMessageTests: XCTestCase {
    func testNothingRunningSaysNothing() {
        XCTAssertNil(MouseSoftwareConflictMessage.text(for: []))
    }

    func testOneName() {
        let text = MouseSoftwareConflictMessage.text(for: ["LinearMouse"])
        XCTAssertEqual(
            text,
            "LinearMouse is also running. It can change what the same buttons do, so a button may "
                + "act twice or not at all. Quit it, or turn off its button actions for this mouse."
        )
    }

    func testSeveralNamesUseThePlural() {
        let text = MouseSoftwareConflictMessage.text(for: ["A", "B", "C"]) ?? ""
        XCTAssertTrue(text.hasPrefix("A, B and C are also running. They can"))
        XCTAssertTrue(text.contains("Quit them, or turn off their button actions"))
    }

    func testDetectionFeedsTheMessage() {
        let names = KnownMouseSoftware.names(runningBundleIDs: [
            "com.apple.finder", "com.lujjjh.LinearMouse", "org.pqrs.Karabiner-Elements.Settings",
        ])
        XCTAssertEqual(names, ["Karabiner-Elements", "LinearMouse"])
        XCTAssertNotNil(MouseSoftwareConflictMessage.text(for: names))
    }
}
