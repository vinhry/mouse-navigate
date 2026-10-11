import XCTest
@testable import MouseNavigateCore

final class CursorMotionIntegratorTests: XCTestCase {
    /// No ramp: 600 points a second from the first tick.
    private let steady = CursorSpeedProfile(
        baseSpeed: 600, maxSpeed: 600, acceleration: 0,
        fastMultiplier: 2, fasterMultiplier: 4, precisionMultiplier: 0.25, scrollSpeed: 10
    )

    func testFirstTickAssumesAFrameAndLaterOnesMeasure() {
        var motion = CursorMotionIntegrator()
        XCTAssertTrue(motion.press(.moveRight, at: 0))
        XCTAssertEqual(motion.tick(at: 0, tier: [], profile: steady), .move(dx: 5, dy: 0))
        // 1/16 s at 600 points a second is 37.5 points.
        XCTAssertEqual(motion.tick(at: 0.0625, tier: [], profile: steady), .move(dx: 37, dy: 0))
    }

    func testAStalledTickIsCapped() {
        var motion = CursorMotionIntegrator()
        motion.press(.moveLeft, at: 0)
        _ = motion.tick(at: 0, tier: [], profile: steady)
        XCTAssertEqual(motion.tick(at: 5, tier: [], profile: steady), .move(dx: -60, dy: 0))
    }

    func testDiagonalsAreNoFasterAndCarryTheirFractions() {
        var motion = CursorMotionIntegrator()
        motion.press(.moveRight, at: 0)
        motion.press(.moveDown, at: 0)
        // 5 points along the diagonal is 3.54 on each axis.
        XCTAssertEqual(motion.tick(at: 0, tier: [], profile: steady), .move(dx: 3, dy: 3))
        XCTAssertEqual(motion.tick(at: 1.0 / 120, tier: [], profile: steady), .move(dx: 4, dy: 4))
    }

    func testTiers() {
        var motion = CursorMotionIntegrator()
        motion.press(.moveUp, at: 0)
        XCTAssertEqual(motion.tick(at: 0, tier: .shift, profile: steady), .move(dx: 0, dy: -10))
        XCTAssertEqual(motion.tick(at: 1.0 / 120, tier: [.shift, .control], profile: steady), .move(dx: 0, dy: -20))
        // A quarter speed moves 1.25 a tick: the quarter is carried.
        XCTAssertEqual(motion.tick(at: 2.0 / 120, tier: .option, profile: steady), .move(dx: 0, dy: -1))
        XCTAssertEqual(motion.tick(at: 3.0 / 120, tier: .option, profile: steady), .move(dx: 0, dy: -1))
    }

    func testScrollingIsNegatedForTheWheel() {
        var motion = CursorMotionIntegrator()
        motion.setScrolling(true, at: 0)
        motion.press(.moveDown, at: 0)
        // 10 pixels a nominal tick, and the first tick is a little longer than one.
        XCTAssertEqual(motion.tick(at: 0, tier: [], profile: steady), .scroll(dx: 0, dy: -10))
        // Letting go of the modifier moves again; the tick clock runs on regardless.
        motion.setScrolling(false, at: 0.01)
        XCTAssertEqual(motion.tick(at: 0.01, tier: [], profile: steady), .move(dx: 0, dy: 6))
    }

    func testNothingHeldIsNothing() {
        var motion = CursorMotionIntegrator()
        XCTAssertFalse(motion.isMoving)
        XCTAssertEqual(motion.tick(at: 0, tier: [], profile: steady), .none)
        XCTAssertFalse(motion.press(.leftClick, at: 0), "not a movement key")
        XCTAssertFalse(motion.isMoving)
    }

    func testHeldKeysAndTheClock() {
        var motion = CursorMotionIntegrator()
        XCTAssertTrue(motion.press(.moveRight, at: 0))
        XCTAssertFalse(motion.press(.moveRight, at: 0.1), "already held")
        _ = motion.tick(at: 0, tier: [], profile: steady)
        motion.release(.moveRight, at: 0.2)
        XCTAssertFalse(motion.isMoving)
        // Pressed again much later, the first tick is one frame again, not the gap.
        motion.press(.moveRight, at: 30)
        XCTAssertEqual(motion.tick(at: 30, tier: [], profile: steady), .move(dx: 5, dy: 0))
    }

    func testTheRampStartsAgainWhenTheKeysChange() {
        let ramped = CursorSpeedProfile(baseSpeed: 120, maxSpeed: 1200, acceleration: 1)
        var motion = CursorMotionIntegrator()
        motion.press(.moveRight, at: 0)
        // Half way up the ramp: 660 points a second, 5.5 a frame.
        XCTAssertEqual(motion.tick(at: 0.5, tier: [], profile: ramped), .move(dx: 5, dy: 0))
        motion.press(.moveUp, at: 0.5)
        motion.release(.moveUp, at: 0.5)
        // Back at the bottom: about 120 points a second, 1 a frame.
        XCTAssertEqual(motion.tick(at: 0.5 + 1.0 / 120, tier: [], profile: ramped), .move(dx: 1, dy: 0))
    }

    func testResetForgetsEverything() {
        var motion = CursorMotionIntegrator()
        motion.press(.moveRight, at: 0)
        motion.setScrolling(true, at: 0)
        motion.reset()
        XCTAssertEqual(motion, CursorMotionIntegrator())
    }
}
