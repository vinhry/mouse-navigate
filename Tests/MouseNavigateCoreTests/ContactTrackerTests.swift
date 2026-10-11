import XCTest
@testable import MouseNavigateCore

final class ContactTrackerTests: XCTestCase {
    private func frame(_ time: Double, _ contacts: [(id: Int, x: Double, y: Double)]) -> TouchFrame {
        TouchFrame(timestamp: time, contacts: contacts.map { TouchContact(id: $0.id, position: Vector2(x: $0.x, y: $0.y)) })
    }

    func testLandingAndLifting() {
        var tracker = ContactTracker()
        let down = tracker.update(frame(0, [(1, 0.5, 0.5)]))
        XCTAssertEqual(down.landed.map(\.id), [1])
        XCTAssertEqual(down.active.map(\.id), [1])
        XCTAssertFalse(down.sessionEnded)

        let up = tracker.update(frame(0.1, []))
        XCTAssertEqual(up.lifted.map(\.id), [1])
        XCTAssertEqual(up.lifted.first?.upTime, 0.1)
        XCTAssertTrue(up.sessionEnded)
    }

    func testActiveFingersAreLeftToRight() {
        var tracker = ContactTracker()
        let snapshot = tracker.update(frame(0, [(1, 0.8, 0.5), (2, 0.2, 0.5), (3, 0.5, 0.5)]))
        XCTAssertEqual(snapshot.active.map(\.id), [2, 3, 1])
    }

    func testMovementIsMeasuredFromWhereTheFingerLanded() {
        var tracker = ContactTracker()
        _ = tracker.update(frame(0, [(1, 0.5, 0.5)]))
        _ = tracker.update(frame(0.05, [(1, 0.6, 0.5)]))
        let back = tracker.update(frame(0.1, [(1, 0.55, 0.5)]))
        let finger = try! XCTUnwrap(back.active(1))
        XCTAssertEqual(finger.displacement.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(finger.maxDisplacement, 0.1, accuracy: 1e-9, "the furthest it strayed")
    }

    func testAFingerThatComesToRestIsMeasuredFromThere() {
        var tracker = ContactTracker()
        let tuning = TouchTuning()
        _ = tracker.update(frame(0, [(1, 0.5, 0.5)]), tuning: tuning)
        _ = tracker.update(frame(0.1, [(1, 0.6, 0.5)]), tuning: tuning)
        let rested = tracker.update(frame(0.1 + tuning.settleDuration, [(1, 0.6, 0.5)]), tuning: tuning)
        let finger = try! XCTUnwrap(rested.active(1))
        XCTAssertEqual(finger.start, Vector2(x: 0.6, y: 0.5))
        XCTAssertEqual(finger.maxDisplacement, 0)
        XCTAssertEqual(finger.restTime, 0.1 + tuning.settleDuration)
    }

    func testAFingerBackWithinTheGraceCarriesOn() {
        var tracker = ContactTracker()
        _ = tracker.update(frame(0, [(1, 0.5, 0.5)]), liftGrace: 0.05)
        let gone = tracker.update(frame(0.02, []), liftGrace: 0.05)
        XCTAssertTrue(gone.lifted.isEmpty)
        XCTAssertEqual(gone.active.map(\.id), [1], "still down where it was")

        // Back under a new id close by: the same finger, not a new landing.
        let back = tracker.update(frame(0.04, [(7, 0.52, 0.5)]), liftGrace: 0.05)
        XCTAssertTrue(back.landed.isEmpty)
        XCTAssertEqual(back.active.map(\.id), [1])
        let later = tracker.update(frame(0.06, [(7, 0.53, 0.5)]), liftGrace: 0.05)
        XCTAssertEqual(later.active.map(\.id), [1], "the new id keeps standing in")
    }

    func testANewFingerFarAwayIsANewLanding() {
        var tracker = ContactTracker()
        _ = tracker.update(frame(0, [(1, 0.1, 0.5)]), liftGrace: 0.05)
        _ = tracker.update(frame(0.02, []), liftGrace: 0.05)
        let other = tracker.update(frame(0.03, [(7, 0.9, 0.5)]), liftGrace: 0.05)
        XCTAssertEqual(other.landed.map(\.id), [7])
    }

    func testAFingerGoneForTheWholeGraceLiftsWhenItVanished() {
        var tracker = ContactTracker()
        _ = tracker.update(frame(0, [(1, 0.5, 0.5)]), liftGrace: 0.05)
        _ = tracker.update(frame(0.02, []), liftGrace: 0.05)
        let lifted = tracker.update(frame(0.08, []), liftGrace: 0.05)
        XCTAssertEqual(lifted.lifted.map(\.id), [1])
        XCTAssertEqual(lifted.lifted.first?.upTime, 0.02)
    }

    func testResetForgetsEveryFinger() {
        var tracker = ContactTracker()
        _ = tracker.update(frame(0, [(1, 0.5, 0.5)]))
        tracker.reset()
        XCTAssertEqual(tracker.update(frame(0.1, [(1, 0.5, 0.5)])).landed.map(\.id), [1])
    }

    func testFixedAndTap() {
        let tuning = TouchTuning()
        var tracker = ContactTracker()
        _ = tracker.update(frame(0, [(1, 0.5, 0.5)]))
        let held = try! XCTUnwrap(tracker.update(frame(tuning.fixDuration, [(1, 0.5, 0.5)])).active(1))
        XCTAssertTrue(held.isFixed(at: tuning.fixDuration, tuning: tuning))
        XCTAssertFalse(held.isFixed(at: tuning.fixDuration / 2, tuning: tuning))

        var tapper = ContactTracker()
        _ = tapper.update(frame(0, [(2, 0.5, 0.5)]))
        let tap = try! XCTUnwrap(tapper.update(frame(0.1, [])).lifted.first)
        XCTAssertTrue(tap.isTap(tuning: tuning))
        XCTAssertFalse(held.isTap(tuning: tuning), "not lifted yet")
    }

    func testMirroringFlipsLeftAndRight() {
        let mirrored = frame(0, [(1, 0.2, 0.3)]).mirrored()
        XCTAssertEqual(mirrored.contacts.first?.position.x ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(mirrored.contacts.first?.position.y, 0.3)
    }
}
