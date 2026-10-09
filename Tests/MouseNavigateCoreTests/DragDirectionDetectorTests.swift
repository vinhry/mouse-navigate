import XCTest
@testable import MouseNavigateCore

final class DragDirectionDetectorTests: XCTestCase {
    func testNothingInsideTheDeadZone() {
        var detector = DragDirectionDetector(threshold: 30)
        XCTAssertNil(detector.moved(by: Vector2(x: 10, y: 0)))
        XCTAssertNil(detector.moved(by: Vector2(x: 10, y: -5)))
        XCTAssertNil(detector.moved(by: Vector2(x: 9, y: 0)))
    }

    func testTheDominantAxisDecides() {
        var up = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(up.moved(by: Vector2(x: 5, y: -30)), .up)
        var down = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(down.moved(by: Vector2(x: -12, y: 31)), .down)
        var left = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(left.moved(by: Vector2(x: -40, y: 20)), .left)
        var right = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(right.moved(by: Vector2(x: 30, y: 0)), .right)
    }

    func testMovementAccumulatesAcrossEvents() {
        var detector = DragDirectionDetector(threshold: 30)
        for _ in 0..<5 {
            XCTAssertNil(detector.moved(by: Vector2(x: 0, y: 5)))
        }
        XCTAssertEqual(detector.moved(by: Vector2(x: 0, y: 5)), .down)
    }

    func testADiagonalGoesWithTheLargerAxisAndTiesGoVertical() {
        var detector = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(detector.moved(by: Vector2(x: 30, y: -30)), .up)
        var wider = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(wider.moved(by: Vector2(x: 31, y: -30)), .right)
    }

    func testFiresOncePerPress() {
        var detector = DragDirectionDetector(threshold: 30)
        XCTAssertEqual(detector.moved(by: Vector2(x: 0, y: -40)), .up)
        XCTAssertNil(detector.moved(by: Vector2(x: 0, y: -40)))
        XCTAssertNil(detector.moved(by: Vector2(x: 80, y: 0)))
        detector.reset()
        XCTAssertEqual(detector.moved(by: Vector2(x: 80, y: 0)), .right)
    }

    func testDoublingBackIsForgiven() {
        var detector = DragDirectionDetector(threshold: 30)
        XCTAssertNil(detector.moved(by: Vector2(x: 20, y: 0)))
        XCTAssertNil(detector.moved(by: Vector2(x: -25, y: 0)))
        XCTAssertNil(detector.moved(by: Vector2(x: 0, y: 20)))
        XCTAssertEqual(detector.moved(by: Vector2(x: 0, y: 15)), .down)
    }
}
