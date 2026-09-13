import XCTest
@testable import MouseNavigateCore

final class CursorMotionTests: XCTestCase {
    private let profile = CursorSpeedProfile()

    // MARK: - Direction

    func testDirectionUsesCoreGraphicsOrientation() {
        // +y points down the screen in CoreGraphics coordinates.
        XCTAssertEqual(CursorMotion.direction(up: true, down: false, left: false, right: false),
                       Vector2(x: 0, y: -1))
        XCTAssertEqual(CursorMotion.direction(up: false, down: true, left: false, right: false),
                       Vector2(x: 0, y: 1))
    }

    func testOpposingKeysCancel() {
        XCTAssertEqual(CursorMotion.direction(up: true, down: true, left: true, right: true), .zero)
    }

    func testDiagonalIsNormalised() {
        let diagonal = CursorMotion.direction(up: true, down: false, left: false, right: true)
        // Without normalisation a diagonal would travel √2 times faster than an axis.
        XCTAssertEqual(diagonal.magnitude, 1.0, accuracy: 1e-9)
        XCTAssertEqual(diagonal.x, 0.70710678, accuracy: 1e-6)
        XCTAssertEqual(diagonal.y, -0.70710678, accuracy: 1e-6)
    }

    // MARK: - Ramp

    func testRampStartsAtZeroAndSaturates() {
        XCTAssertEqual(CursorMotion.easedRamp(heldDuration: 0, acceleration: 0.45), 0, accuracy: 1e-9)
        XCTAssertEqual(CursorMotion.easedRamp(heldDuration: 0.45, acceleration: 0.45), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorMotion.easedRamp(heldDuration: 10, acceleration: 0.45), 1, accuracy: 1e-9)
    }

    func testRampIsMonotonic() {
        var previous = -1.0
        for step in 0...20 {
            let value = CursorMotion.easedRamp(heldDuration: Double(step) * 0.03, acceleration: 0.45)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testZeroAccelerationSkipsTheRamp() {
        XCTAssertEqual(CursorMotion.easedRamp(heldDuration: 0, acceleration: 0), 1)
    }

    // MARK: - Speed

    func testSpeedStartsAtBaseAndReachesMax() {
        XCTAssertEqual(CursorMotion.speed(heldDuration: 0, tier: [], profile: profile),
                       profile.baseSpeed, accuracy: 1e-6)
        XCTAssertEqual(CursorMotion.speed(heldDuration: 5, tier: [], profile: profile),
                       profile.maxSpeed, accuracy: 1e-6)
    }

    func testSpeedTiersAreOrdered() {
        let normal = CursorMotion.speed(heldDuration: 5, tier: [], profile: profile)
        let fast = CursorMotion.speed(heldDuration: 5, tier: [.shift], profile: profile)
        let fastest = CursorMotion.speed(heldDuration: 5, tier: [.shift, .control], profile: profile)

        XCTAssertLessThan(normal, fast)
        XCTAssertLessThan(fast, fastest)
    }

    func testControlAloneDoesNotChangeSpeed() {
        // Ctrl is only a speed modifier in combination with Shift.
        XCTAssertEqual(
            CursorMotion.speed(heldDuration: 5, tier: [.control], profile: profile),
            CursorMotion.speed(heldDuration: 5, tier: [], profile: profile),
            accuracy: 1e-6
        )
    }

    func testOptionOverridesTheFasterTiers() {
        let precise = CursorMotion.speed(heldDuration: 5, tier: [.option, .shift, .control], profile: profile)
        let normal = CursorMotion.speed(heldDuration: 5, tier: [], profile: profile)
        XCTAssertLessThan(precise, normal)
    }

    // MARK: - Clamping

    private let primary = Rect(minX: 0, minY: 0, maxX: 1439, maxY: 899)

    func testPointInsideIsUnchanged() {
        let point = Vector2(x: 100, y: 100)
        XCTAssertEqual(CursorMotion.clamp(point: point, previous: .zero, screens: [primary]), point)
    }

    func testHorizontalMovementSurvivesVerticalOverrun() {
        // Sliding along the bottom edge must keep the x travel rather than freezing.
        let result = CursorMotion.clamp(
            point: Vector2(x: 500, y: 950),
            previous: Vector2(x: 400, y: 899),
            screens: [primary]
        )
        XCTAssertEqual(result, Vector2(x: 500, y: 899))
    }

    func testVerticalMovementSurvivesHorizontalOverrun() {
        let result = CursorMotion.clamp(
            point: Vector2(x: 1500, y: 400),
            previous: Vector2(x: 1439, y: 300),
            screens: [primary]
        )
        XCTAssertEqual(result, Vector2(x: 1439, y: 400))
    }

    func testCornerOverrunPinsToTheNearestDisplay() {
        let result = CursorMotion.clamp(
            point: Vector2(x: 5000, y: 5000),
            previous: Vector2(x: 5000, y: 5000),
            screens: [primary]
        )
        XCTAssertEqual(result, Vector2(x: 1439, y: 899))
    }

    func testMovingIntoASecondDisplayIsAllowed() {
        let secondary = Rect(minX: 1440, minY: 0, maxX: 3279, maxY: 1079)
        let point = Vector2(x: 2000, y: 500)
        XCTAssertEqual(
            CursorMotion.clamp(point: point, previous: Vector2(x: 1439, y: 500), screens: [primary, secondary]),
            point
        )
    }

    func testGapBetweenMisalignedDisplaysDoesNotTrapTheCursor() {
        // The secondary display is taller, so y=1000 exists on it but not on the primary.
        let secondary = Rect(minX: 1440, minY: 0, maxX: 3279, maxY: 1079)
        let result = CursorMotion.clamp(
            point: Vector2(x: 1400, y: 1000),
            previous: Vector2(x: 1500, y: 1000),
            screens: [primary, secondary]
        )
        XCTAssertEqual(result, Vector2(x: 1500, y: 1000))
    }

    func testNoScreensLeavesThePointAlone() {
        let point = Vector2(x: 42, y: 42)
        XCTAssertEqual(CursorMotion.clamp(point: point, previous: .zero, screens: []), point)
    }

    // MARK: - Sub-pixel accumulation

    func testSlowMovementStillAdvances() {
        var accumulator = SubPixelAccumulator()
        var total = 0

        // A third of a pixel per tick must not round away to nothing.
        for _ in 0..<9 {
            total += accumulator.take(Vector2(x: 1.0 / 3.0, y: 0)).dx
        }
        XCTAssertEqual(total, 3)
    }

    func testAccumulatorHandlesNegativeTravel() {
        var accumulator = SubPixelAccumulator()
        var total = 0
        for _ in 0..<4 {
            total += accumulator.take(Vector2(x: -0.5, y: 0)).dx
        }
        XCTAssertEqual(total, -2)
    }

    func testResetDropsThePendingRemainder() {
        var accumulator = SubPixelAccumulator()
        _ = accumulator.take(Vector2(x: 0.9, y: 0.9))
        accumulator.reset()
        XCTAssertEqual(accumulator.take(Vector2(x: 0.5, y: 0.5)).dx, 0)
    }
}
