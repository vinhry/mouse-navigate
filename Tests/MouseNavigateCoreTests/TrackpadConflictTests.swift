import XCTest
@testable import MouseNavigateCore

final class TrackpadConflictTests: XCTestCase {
    private let bound: (TouchGesture) -> Bool = { _ in true }

    func testVerticalSwipeOnThreeFingersTakesTheSlides() {
        let settings = MacOSTrackpadSettings(values: [.threeFingerVerticalSwipe: 2])
        let conflicts = settings.conflicts(isBound: bound)
        XCTAssertEqual(conflicts.map(\.gesture), [.threeFingerVerticalSwipe])
        XCTAssertEqual(
            conflicts.first?.taken,
            [.trackpadOneFixTwoSlideDown, .trackpadOneFixTwoSlideUp, .trackpadClickTwoSlideDown]
        )
    }

    func testUnsetKeysUseTheSystemDefaults() {
        // Never written: the swipes start on three fingers; drag and tap start off.
        XCTAssertEqual(MacOSTrackpadSettings().activeGestures, [.threeFingerVerticalSwipe])
    }

    func testSwipeMovedToFourFingersIsNoConflict() {
        let settings = MacOSTrackpadSettings(values: [.threeFingerVerticalSwipe: 0])
        XCTAssertTrue(settings.conflicts(isBound: bound).isEmpty)
    }

    func testTapAndDragTakeTheirGestures() {
        let settings = MacOSTrackpadSettings(values: [
            .threeFingerVerticalSwipe: 0, .threeFingerDrag: 1, .threeFingerTap: 2,
        ])
        let conflicts = settings.conflicts(isBound: bound)
        XCTAssertEqual(conflicts.map(\.gesture), [.threeFingerDrag, .threeFingerTap])
        XCTAssertEqual(conflicts[0].taken, [.trackpadOneFixTwoSlideDown, .trackpadOneFixTwoSlideUp, .trackpadClickTwoSlideDown])
        XCTAssertEqual(conflicts[1].taken, [.trackpadThreeFingerTap, .trackpadOneFixTwoTap])
        XCTAssertTrue(MacOSTrackpadSettings(values: [.threeFingerDrag: 0, .threeFingerTap: 0]).conflicts(isBound: bound)
            .allSatisfy { $0.gesture == .threeFingerVerticalSwipe })
    }

    func testOnlyBoundGesturesCount() {
        let settings = MacOSTrackpadSettings(values: [.threeFingerVerticalSwipe: 2])
        XCTAssertTrue(settings.conflicts(isBound: { _ in false }).isEmpty)
        let conflicts = settings.conflicts(isBound: { $0 == .trackpadOneFixTwoSlideUp })
        XCTAssertEqual(conflicts.first?.taken, [.trackpadOneFixTwoSlideUp])
    }

    func testEveryCollidingGestureIsATrackpadGesture() {
        for gesture in MacOSTrackpadGesture.allCases {
            XCTAssertFalse(gesture.collidingGestures.isEmpty)
            XCTAssertFalse(gesture.defaultsKey.isEmpty)
            for colliding in gesture.collidingGestures {
                XCTAssertEqual(colliding.surface, .trackpad, "\(colliding)")
            }
        }
    }

    func testMessageNamesTheSettingAndTheGestures() {
        XCTAssertNil(TrackpadConflictMessage.text(for: []))
        let text = TrackpadConflictMessage.text(for: [
            TrackpadConflict(gesture: .threeFingerVerticalSwipe, taken: [.trackpadOneFixTwoSlideDown, .trackpadOneFixTwoSlideUp]),
        ])
        XCTAssertEqual(
            text,
            "Mission Control and App Exposé are on a three-finger swipe in macOS, which takes "
                + "One-Fix Two-Slide Down and One-Fix Two-Slide Up. "
                + "Set them to four fingers in System Settings → Trackpad → More Gestures."
        )
        XCTAssertEqual(TrackpadConflictMessage.list(["A"]), "A")
        XCTAssertEqual(TrackpadConflictMessage.list(["A", "B", "C"]), "A, B and C")
    }
}
