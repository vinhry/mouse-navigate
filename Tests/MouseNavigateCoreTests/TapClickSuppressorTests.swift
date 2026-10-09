import XCTest
@testable import MouseNavigateCore

final class TapClickSuppressorTests: XCTestCase {
    func testClickSoonAfterGestureIsSwallowedOnce() {
        var suppressor = TapClickSuppressor()
        suppressor.tapBecameGesture(at: 10)
        XCTAssertTrue(suppressor.leftMouseDown(at: 10.1))
        XCTAssertFalse(suppressor.leftMouseDown(at: 10.15), "only the tap's own click is held back")
    }

    func testClickAfterTheWindowPasses() {
        var suppressor = TapClickSuppressor()
        suppressor.tapBecameGesture(at: 10)
        XCTAssertFalse(suppressor.leftMouseDown(at: 10.3))
        XCTAssertFalse(suppressor.leftMouseDown(at: 11))
    }

    func testClickWithoutGesturePasses() {
        var suppressor = TapClickSuppressor()
        XCTAssertFalse(suppressor.leftMouseDown(at: 1))
    }

    func testClickThatCameJustBeforeTheGestureWasTheTapsOwn() {
        var suppressor = TapClickSuppressor()
        XCTAssertFalse(suppressor.leftMouseDown(at: 10))
        suppressor.tapBecameGesture(at: 10.1)
        XCTAssertFalse(suppressor.leftMouseDown(at: 10.2), "the tap's click already came; this is a real one")
    }

    func testClickLongEnoughBeforeTheGestureDoesNotDisarmIt() {
        var suppressor = TapClickSuppressor()
        XCTAssertFalse(suppressor.leftMouseDown(at: 10))
        suppressor.tapBecameGesture(at: 10.2)
        XCTAssertTrue(suppressor.leftMouseDown(at: 10.3))
    }

    func testResetClearsAnArmedWindow() {
        var suppressor = TapClickSuppressor()
        suppressor.tapBecameGesture(at: 10)
        suppressor.reset()
        XCTAssertFalse(suppressor.leftMouseDown(at: 10.1))
    }

    func testCustomTimings() {
        var suppressor = TapClickSuppressor(window: 1, lead: 0.5)
        suppressor.tapBecameGesture(at: 10)
        XCTAssertTrue(suppressor.leftMouseDown(at: 10.9))
        XCTAssertFalse(suppressor.leftMouseDown(at: 12))
        suppressor.tapBecameGesture(at: 12.4)
        XCTAssertFalse(suppressor.leftMouseDown(at: 12.5), "a click 0.4 s before is within the lead")
    }
}
