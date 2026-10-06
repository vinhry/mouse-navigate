import XCTest
@testable import MouseNavigateCore

/// A key whose press cursor mode swallowed must stay swallowed until it is released,
/// however cursor mode itself ends in between.
final class HeldKeySwallowerTests: XCTestCase {
    private var keys = HeldKeySwallower()

    override func setUp() {
        super.setUp()
        keys = HeldKeySwallower()
    }

    func testUnknownKeysAreLeftAlone() {
        XCTAssertFalse(keys.keyDown(KeyCode.l, isRepeat: false))
        XCTAssertFalse(keys.keyDown(KeyCode.l, isRepeat: true))
        XCTAssertFalse(keys.keyUp(KeyCode.l))
    }

    func testRepeatsAndReleaseOfAHeldKeyAreSwallowed() {
        keys.hold(KeyCode.a)
        XCTAssertTrue(keys.keyDown(KeyCode.a, isRepeat: true))
        XCTAssertTrue(keys.keyDown(KeyCode.a, isRepeat: true))
        XCTAssertTrue(keys.keyUp(KeyCode.a))
        // Released: the next press is an ordinary one.
        XCTAssertFalse(keys.keyDown(KeyCode.a, isRepeat: false))
        XCTAssertFalse(keys.keyUp(KeyCode.a))
        XCTAssertTrue(keys.isEmpty)
    }

    func testAFreshPressOfAHeldKeyMeansTheReleaseWasMissed() {
        keys.hold(KeyCode.s)
        XCTAssertFalse(keys.keyDown(KeyCode.s, isRepeat: false))
        XCTAssertFalse(keys.contains(KeyCode.s))
        XCTAssertFalse(keys.keyUp(KeyCode.s))
    }

    func testKeysAreIndependent() {
        keys.hold(KeyCode.a)
        keys.hold(KeyCode.l)
        XCTAssertTrue(keys.keyUp(KeyCode.a))
        XCTAssertTrue(keys.keyDown(KeyCode.l, isRepeat: true))
        XCTAssertTrue(keys.keyUp(KeyCode.l))
        XCTAssertTrue(keys.isEmpty)
    }

    func testForgetDropsAKeyWithoutSwallowingItsRelease() {
        keys.hold(KeyCode.a)
        keys.forget(KeyCode.a)
        XCTAssertFalse(keys.keyUp(KeyCode.a))
    }
}
