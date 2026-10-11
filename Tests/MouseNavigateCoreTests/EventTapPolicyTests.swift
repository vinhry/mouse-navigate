import XCTest
@testable import MouseNavigateCore

final class EventTapPolicyTests: XCTestCase {
    func testOnlySideButtonsWhenNothingElseIsOn() {
        XCTAssertEqual(
            EventTapPolicy.kinds(cursorMode: false, touch: false, scrollOptions: false, dragBindings: false),
            [.otherMouseDown, .otherMouseUp]
        )
    }

    func testCursorModeAddsKeys() {
        let kinds = EventTapPolicy.kinds(cursorMode: true, touch: false, scrollOptions: false, dragBindings: false)
        XCTAssertTrue(kinds.isSuperset(of: [.keyDown, .keyUp, .flagsChanged]))
        XCTAssertFalse(kinds.contains(.scrollWheel))
    }

    func testTouchTakesClicksScrollsAndDrawingButtons() {
        let kinds = EventTapPolicy.kinds(cursorMode: false, touch: true, scrollOptions: false, dragBindings: false)
        XCTAssertEqual(kinds, Set(TapEventKind.allCases).subtracting([.keyDown, .keyUp, .flagsChanged]))
    }

    func testScrollOptionsAloneTakeOnlyTheWheel() {
        XCTAssertEqual(
            EventTapPolicy.kinds(cursorMode: false, touch: false, scrollOptions: true, dragBindings: false),
            [.otherMouseDown, .otherMouseUp, .scrollWheel]
        )
    }

    func testDragBindingsTakeSideButtonDrags() {
        XCTAssertEqual(
            EventTapPolicy.kinds(cursorMode: false, touch: false, scrollOptions: false, dragBindings: true),
            [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        )
    }

    func testEverythingOn() {
        XCTAssertEqual(
            EventTapPolicy.kinds(cursorMode: true, touch: true, scrollOptions: true, dragBindings: true),
            Set(TapEventKind.allCases)
        )
    }
}

final class ScrollSessionSuppressorTests: XCTestCase {
    func testAScrollAGestureClaimsIsSwallowedToItsEnd() {
        var session = ScrollSessionSuppressor()
        XCTAssertFalse(session.shouldSuppress(phase: .began, gestureClaims: false))
        XCTAssertTrue(session.shouldSuppress(phase: .changed, gestureClaims: true))
        XCTAssertTrue(session.shouldSuppress(phase: .changed, gestureClaims: false), "the rest of it too")
        XCTAssertFalse(session.shouldSuppress(phase: .ended, gestureClaims: false), "its end reaches the app")
        XCTAssertTrue(session.shouldSuppress(phase: nil, gestureClaims: false), "and the momentum is held back")
    }

    func testTheNextScrollStartsClear() {
        var session = ScrollSessionSuppressor()
        _ = session.shouldSuppress(phase: .changed, gestureClaims: true)
        XCTAssertFalse(session.shouldSuppress(phase: .mayBegin, gestureClaims: false))
        XCTAssertFalse(session.shouldSuppress(phase: .began, gestureClaims: false))
        XCTAssertFalse(session.shouldSuppress(phase: .changed, gestureClaims: false))
    }

    func testCancelledReachesTheApp() {
        var session = ScrollSessionSuppressor()
        _ = session.shouldSuppress(phase: .changed, gestureClaims: true)
        XCTAssertFalse(session.shouldSuppress(phase: .cancelled, gestureClaims: false))
    }

    func testReset() {
        var session = ScrollSessionSuppressor()
        _ = session.shouldSuppress(phase: .changed, gestureClaims: true)
        session.reset()
        XCTAssertFalse(session.shouldSuppress(phase: .changed, gestureClaims: false))
    }

    func testPhaseValuesAreCoreGraphics() {
        XCTAssertEqual(ScrollPhase.began.rawValue, 1)
        XCTAssertEqual(ScrollPhase.mayBegin.rawValue, 128)
        XCTAssertEqual(MomentumPhase.end.rawValue, 3)
    }
}
