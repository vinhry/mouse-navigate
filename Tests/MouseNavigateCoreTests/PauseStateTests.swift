import XCTest
@testable import MouseNavigateCore

final class PauseStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testStartsRunning() {
        let state = PauseState()
        XCTAssertEqual(state.status, .running)
        XCTAssertFalse(state.isPaused)
        XCTAssertNil(state.resumeDate)
    }

    func testPauseAndResume() {
        var state = PauseState()
        XCTAssertTrue(state.apply(.pause))
        XCTAssertEqual(state.status, .pausedIndefinitely)
        XCTAssertTrue(state.isPaused)
        XCTAssertNil(state.resumeDate)
        XCTAssertFalse(state.apply(.pause), "nothing changed")
        XCTAssertTrue(state.apply(.resume))
        XCTAssertFalse(state.isPaused)
    }

    func testTimedPauseEndsOnTick() {
        var state = PauseState()
        state.apply(.pauseFor(3600, now: t0))
        XCTAssertEqual(state.resumeDate, t0.addingTimeInterval(3600))
        XCTAssertFalse(state.apply(.tick(now: t0.addingTimeInterval(3599))))
        XCTAssertTrue(state.isPaused)
        XCTAssertTrue(state.apply(.tick(now: t0.addingTimeInterval(3600))))
        XCTAssertEqual(state.status, .running)
    }

    func testTickLongAfterTheEndResumes() {
        // The Mac slept through the hour.
        var state = PauseState()
        state.apply(.pauseFor(3600, now: t0))
        XCTAssertTrue(state.apply(.tick(now: t0.addingTimeInterval(8 * 3600))))
        XCTAssertFalse(state.isPaused)
    }

    func testManualPauseDuringTimedPauseIsIndefinite() {
        var state = PauseState()
        state.apply(.pauseFor(3600, now: t0))
        XCTAssertTrue(state.apply(.pause))
        XCTAssertEqual(state.status, .pausedIndefinitely)
        XCTAssertFalse(state.apply(.tick(now: t0.addingTimeInterval(7200))))
        XCTAssertTrue(state.isPaused)
    }

    func testResumeEarlyClearsTheEnd() {
        var state = PauseState()
        state.apply(.pauseFor(3600, now: t0))
        XCTAssertTrue(state.apply(.resume))
        XCTAssertNil(state.resumeDate)
        XCTAssertFalse(state.apply(.tick(now: t0.addingTimeInterval(10))))
    }

    func testTickWhileRunningOrIndefiniteChangesNothing() {
        var state = PauseState()
        XCTAssertFalse(state.apply(.tick(now: t0)))
        state.apply(.pause)
        XCTAssertFalse(state.apply(.tick(now: t0.addingTimeInterval(1e9))))
    }
}
