import XCTest
@testable import MouseNavigateCore

final class SessionAvailabilityTests: XCTestCase {
    func testAvailableAtStart() {
        XCTAssertTrue(SessionAvailability().isAvailable)
    }

    func testLockAndUnlock() {
        var session = SessionAvailability()
        XCTAssertTrue(session.apply(.screenLocked))
        XCTAssertFalse(session.isAvailable)
        XCTAssertTrue(session.apply(.screenUnlocked))
        XCTAssertTrue(session.isAvailable)
    }

    func testWakingStillLockedStaysUnavailable() {
        var session = SessionAvailability()
        session.apply(.screenLocked)
        XCTAssertFalse(session.apply(.willSleep), "already unavailable")
        XCTAssertFalse(session.apply(.didWake), "the lock outlasts the sleep")
        XCTAssertFalse(session.isAvailable)
        XCTAssertTrue(session.apply(.screenUnlocked))
        XCTAssertTrue(session.isAvailable)
    }

    func testAnotherUserInFront() {
        var session = SessionAvailability()
        XCTAssertTrue(session.apply(.sessionDidResignActive))
        XCTAssertFalse(session.isAvailable)
        XCTAssertTrue(session.apply(.sessionDidBecomeActive))
        XCTAssertTrue(session.isAvailable)
    }

    func testRepeatedEventsReportNoChange() {
        var session = SessionAvailability()
        XCTAssertTrue(session.apply(.screenLocked))
        XCTAssertFalse(session.apply(.screenLocked))
        XCTAssertFalse(session.apply(.didWake))
    }

    func testUnlockWithoutLockChangesNothing() {
        var session = SessionAvailability()
        XCTAssertFalse(session.apply(.screenUnlocked))
        XCTAssertFalse(session.apply(.sessionDidBecomeActive))
        XCTAssertTrue(session.isAvailable)
    }

    func testReconcileClearsAMissedUnlockAndWake() {
        var session = SessionAvailability()
        session.apply(.screenLocked)
        session.apply(.willSleep)
        XCTAssertTrue(session.reconcile(isOnConsole: true, isLocked: false))
        XCTAssertTrue(session.isAvailable)
        XCTAssertFalse(session.isAsleep)
    }

    func testReconcileKeepsARealLock() {
        var session = SessionAvailability()
        session.apply(.screenLocked)
        XCTAssertFalse(session.reconcile(isOnConsole: true, isLocked: true))
        XCTAssertFalse(session.isAvailable)
    }

    func testReconcileNoticesASwitchedOutSession() {
        var session = SessionAvailability()
        XCTAssertTrue(session.reconcile(isOnConsole: false, isLocked: false))
        XCTAssertTrue(session.isSessionInactive)
        XCTAssertFalse(session.isAvailable)
    }
}
