import XCTest
@testable import MouseNavigateCore

final class WindowLayoutTests: XCTestCase {
    // A 1440-wide laptop display with a 1920-wide external display to its right.
    private let laptop = Rect(x: 0, y: 25, width: 1440, height: 875)
    private let external = Rect(x: 1440, y: 0, width: 1920, height: 1055)

    func testScreenIndexPicksLargestOverlap() {
        let window = Rect(x: 1300, y: 100, width: 600, height: 400)
        XCTAssertEqual(WindowLayout.screenIndex(for: window, in: [laptop, external]), 1)
    }

    func testScreenIndexFallsBackToNearestForOffscreenWindow() {
        let window = Rect(x: -3000, y: 100, width: 200, height: 200)
        XCTAssertEqual(WindowLayout.screenIndex(for: window, in: [laptop, external]), 0)
    }

    func testScreenIndexIsNilWithoutScreens() {
        XCTAssertNil(WindowLayout.screenIndex(for: Rect(x: 0, y: 0, width: 10, height: 10), in: []))
    }

    func testHalvesSplitTheVisibleFrame() {
        XCTAssertEqual(WindowLayout.half(.left, of: laptop), Rect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(WindowLayout.half(.right, of: laptop), Rect(x: 720, y: 25, width: 720, height: 875))
    }

    func testHalfTargetOnCurrentScreen() {
        let window = Rect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            WindowLayout.halfTarget(.right, window: window, screens: [laptop, external]),
            WindowLayout.half(.right, of: laptop)
        )
    }

    func testRepeatingHalfTargetMovesToNeighbourDisplay() {
        let window = WindowLayout.half(.right, of: laptop)
        XCTAssertEqual(
            WindowLayout.halfTarget(.right, window: window, screens: [laptop, external]),
            WindowLayout.half(.left, of: external)
        )
    }

    func testRepeatingHalfTargetStaysWithoutNeighbour() {
        let window = WindowLayout.half(.left, of: laptop)
        XCTAssertEqual(
            WindowLayout.halfTarget(.left, window: window, screens: [laptop, external]),
            WindowLayout.half(.left, of: laptop)
        )
    }

    func testNearlyMatchingFrameCountsAsAlreadyThere() {
        var window = WindowLayout.half(.left, of: external)
        window.maxY -= 6
        XCTAssertEqual(
            WindowLayout.halfTarget(.left, window: window, screens: [laptop, external]),
            WindowLayout.half(.right, of: laptop)
        )
    }

    func testADisplayBelowIsNotANeighbourSideways() {
        // A laptop centred a little left of a wide external display above it.
        let above = Rect(x: 0, y: 0, width: 2560, height: 1415)
        let below = Rect(x: 400, y: 1415, width: 1440, height: 875)
        XCTAssertNil(WindowLayout.neighbourIndex(of: 0, toward: .left, in: [above, below]))
        XCTAssertNil(WindowLayout.neighbourIndex(of: 0, toward: .right, in: [above, below]))
        XCTAssertEqual(
            WindowLayout.halfTarget(.left, window: WindowLayout.half(.left, of: above), screens: [above, below]),
            WindowLayout.half(.left, of: above)
        )
    }

    func testALevelNeighbourWinsOverADiagonalOne() {
        let origin = Rect(x: 2000, y: 0, width: 1920, height: 1080)
        let diagonal = Rect(x: 0, y: 1500, width: 1440, height: 900)
        let level = Rect(x: 560, y: 100, width: 1440, height: 900)
        XCTAssertEqual(WindowLayout.neighbourIndex(of: 0, toward: .left, in: [origin, diagonal, level]), 2)
        // With nothing level, a display placed diagonally still counts as beside.
        XCTAssertEqual(WindowLayout.neighbourIndex(of: 0, toward: .left, in: [origin, diagonal]), 1)
    }

    func testResizeRespectsMinimumSize() {
        let frame = Rect(x: 10, y: 10, width: 300, height: 200)
        let resized = WindowLayout.resized(frame, by: Vector2(x: -1000, y: -1000))
        XCTAssertEqual(resized.width, WindowLayout.minimumSize.width)
        XCTAssertEqual(resized.height, WindowLayout.minimumSize.height)
        XCTAssertEqual(resized.minX, 10)
    }

    func testMoveKeepsSize() {
        let frame = Rect(x: 10, y: 10, width: 300, height: 200)
        XCTAssertEqual(
            WindowLayout.moved(frame, by: Vector2(x: 5, y: -5)),
            Rect(x: 15, y: 5, width: 300, height: 200)
        )
    }
}
