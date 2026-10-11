import XCTest
@testable import MouseNavigateCore

final class ZoomHistoryTests: XCTestCase {
    private let screen = Rect(minX: 0, minY: 25, maxX: 1440, maxY: 900)
    private let small = Rect(minX: 100, minY: 100, maxX: 700, maxY: 600)

    private func history(capacity: Int = 20) -> ZoomHistory<Int> {
        ZoomHistory(capacity: capacity) { $0 == $1 }
    }

    func testFillsThenRestores() {
        var zoom = history()
        XCTAssertEqual(zoom.zoom(1, from: small, screens: [screen]), screen)
        XCTAssertEqual(zoom.zoom(1, from: screen, screens: [screen]), small)
        XCTAssertEqual(zoom.count, 0, "restoring forgets the frame")
    }

    func testAWindowFilledByOtherMeansIsFilledAgainNotRestored() {
        var zoom = history()
        XCTAssertEqual(zoom.zoom(1, from: screen, screens: [screen]), screen)
        XCTAssertEqual(zoom.count, 1)
    }

    func testEachWindowHasItsOwnFrame() {
        var zoom = history()
        let other = Rect(minX: 300, minY: 300, maxX: 500, maxY: 500)
        _ = zoom.zoom(1, from: small, screens: [screen])
        _ = zoom.zoom(2, from: other, screens: [screen])
        XCTAssertEqual(zoom.zoom(1, from: screen, screens: [screen]), small)
        XCTAssertEqual(zoom.zoom(2, from: screen, screens: [screen]), other)
    }

    func testAFrameOnAScreenThatIsGoneIsNotRestored() {
        var zoom = history()
        let second = Rect(minX: 1440, minY: 0, maxX: 3360, maxY: 1080)
        let onSecond = Rect(minX: 1600, minY: 100, maxX: 2200, maxY: 700)
        _ = zoom.zoom(1, from: onSecond, screens: [screen, second])
        // The second display was unplugged and the window moved to the first, filled.
        XCTAssertEqual(zoom.zoom(1, from: screen, screens: [screen]), screen)
    }

    func testOnlyTheLastWindowsAreRemembered() {
        var zoom = history(capacity: 2)
        for window in 1...3 {
            _ = zoom.zoom(window, from: small, screens: [screen])
        }
        XCTAssertEqual(zoom.count, 2)
        XCTAssertEqual(zoom.zoom(1, from: screen, screens: [screen]), screen, "forgotten, so filled again")
        XCTAssertEqual(zoom.zoom(3, from: screen, screens: [screen]), small)
    }

    func testAWindowOffEveryScreenFillsTheNearest() {
        var zoom = history()
        let offscreen = Rect(minX: 5000, minY: 5000, maxX: 5100, maxY: 5100)
        XCTAssertEqual(zoom.zoom(1, from: offscreen, screens: [screen]), screen)
        XCTAssertNil(zoom.zoom(2, from: small, screens: []), "no screens at all")
    }
}
