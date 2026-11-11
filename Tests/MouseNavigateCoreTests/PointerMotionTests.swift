import XCTest
@testable import MouseNavigateCore

final class PointerMotionTests: XCTestCase {
    private func point(_ x: Double, _ y: Double = 0) -> Vector2 {
        Vector2(x: x, y: y)
    }

    func testStillPointerIsNotMoving() {
        var motion = PointerMotion()
        for step in 0..<50 {
            XCTAssertFalse(motion.record(time: Double(step) * 0.01, position: point(500, 300)))
        }
    }

    func testRockingFromATapIsNotMoving() {
        var motion = PointerMotion()
        // A few points either way, as a tap rocks the mouse.
        let rock = [0.0, 2, 4, 3, 1, 0, 2, 3]
        for (step, offset) in rock.enumerated() {
            XCTAssertFalse(motion.record(time: Double(step) * 0.01, position: point(500 + offset)))
        }
    }

    func testSlowDriftUnderTheThresholdIsNotMoving() {
        var motion = PointerMotion()
        // 40 points a second is 6 over a window.
        for step in 0..<100 {
            XCTAssertFalse(motion.record(time: Double(step) * 0.01, position: point(Double(step) * 0.4)))
        }
    }

    func testFastMoveIsMoving() {
        var motion = PointerMotion()
        var moving = false
        for step in 0..<10 {
            moving = motion.record(time: Double(step) * 0.01, position: point(Double(step) * 5))
        }
        XCTAssertTrue(moving)
        XCTAssertGreaterThan(motion.travel, motion.threshold)
    }

    func testOldSamplesExpire() {
        var motion = PointerMotion()
        for step in 0..<10 {
            motion.record(time: Double(step) * 0.01, position: point(Double(step) * 5))
        }
        XCTAssertTrue(motion.isMoving)
        // The pointer stops; once the window has passed the move no longer counts.
        XCTAssertFalse(motion.record(time: 0.5, position: point(45)))
        XCTAssertFalse(motion.record(time: 0.51, position: point(45)))
        XCTAssertEqual(motion.travel, 0)
    }

    func testJumpAcrossDisplaysIsMoving() {
        var motion = PointerMotion()
        motion.record(time: 0, position: point(1400, 300))
        XCTAssertTrue(motion.record(time: 0.01, position: point(3000, -200)))
    }

    func testOutAndBackCountsBothWays() {
        var motion = PointerMotion()
        motion.record(time: 0, position: point(0))
        motion.record(time: 0.02, position: point(10))
        XCTAssertTrue(motion.record(time: 0.04, position: point(0)))
    }

    func testMemoryIsBounded() {
        var motion = PointerMotion()
        // A clock that never moves keeps every sample inside the window.
        for step in 0..<1000 {
            motion.record(time: 1, position: point(Double(step % 2)))
        }
        XCTAssertLessThanOrEqual(motion.sampleCount, PointerMotion.maxSamples)
    }

    func testResetForgetsTheMove() {
        var motion = PointerMotion()
        motion.record(time: 0, position: point(0))
        motion.record(time: 0.01, position: point(100))
        motion.reset()
        XCTAssertFalse(motion.isMoving)
    }
}

final class TypingActivityTests: XCTestCase {
    func testRealKeyWithNoOwnKeyIsTyping() {
        let typing = TypingActivity()
        XCTAssertTrue(typing.isTyping(now: 100, secondsSinceKey: 0.2, lastOwnKey: nil))
        XCTAssertTrue(typing.isTyping(now: 100, secondsSinceKey: 0.5, lastOwnKey: nil))
    }

    func testKeyOlderThanTheWindowIsNotTyping() {
        let typing = TypingActivity()
        XCTAssertFalse(typing.isTyping(now: 100, secondsSinceKey: 0.6, lastOwnKey: nil))
        XCTAssertFalse(typing.isTyping(now: 100, secondsSinceKey: 600, lastOwnKey: 99))
    }

    func testOwnKeyIsNotTyping() {
        let typing = TypingActivity()
        // Posted 0.2 s ago; the system reports it then, or up to 0.4 s earlier than that.
        XCTAssertFalse(typing.isTyping(now: 100, secondsSinceKey: 0.2, lastOwnKey: 99.8))
        XCTAssertFalse(typing.isTyping(now: 100, secondsSinceKey: 0.45, lastOwnKey: 99.8))
    }

    func testRealKeyAfterOwnKeyIsTyping() {
        let typing = TypingActivity()
        // The app pressed a key at 99.6, and a real one went down at 99.95.
        XCTAssertTrue(typing.isTyping(now: 100, secondsSinceKey: 0.05, lastOwnKey: 99.6))
    }

    func testRealKeyJustAfterOwnKeyIsTheBlindSpot() {
        let typing = TypingActivity()
        // Within the slack after the app's own key, a real one cannot be told from it.
        XCTAssertFalse(typing.isTyping(now: 100, secondsSinceKey: 0.15, lastOwnKey: 99.8))
    }

    func testOwnKeyTooLongAgoNoLongerHidesTyping() {
        let typing = TypingActivity()
        // Own key at 98; a real key reported at 99.8 is far from it.
        XCTAssertTrue(typing.isTyping(now: 100, secondsSinceKey: 0.2, lastOwnKey: 98))
    }
}

final class OwnKeystrokesTests: XCTestCase {
    func testRemembersTheLastKeyDown() {
        let keys = OwnKeystrokes()
        XCTAssertNil(keys.last)
        keys.note(at: 5)
        keys.note(at: 7)
        XCTAssertEqual(keys.last, 7)
    }
}
