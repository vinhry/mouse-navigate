import XCTest
@testable import MouseNavigateCore

final class OnboardingPolicyTests: XCTestCase {
    func testAFreshInstallIsWelcomed() {
        XCTAssertEqual(OnboardingPolicy.decide(isBundled: true, hasCompleted: false, isTrusted: false, hasChosenUpdates: false), .show)
    }

    func testOnceDoneItIsNotShownAgain() {
        XCTAssertEqual(OnboardingPolicy.decide(isBundled: true, hasCompleted: true, isTrusted: false, hasChosenUpdates: false), .skip)
    }

    func testSomeoneAlreadySetUpIsNotWelcomed() {
        XCTAssertEqual(OnboardingPolicy.decide(isBundled: true, hasCompleted: false, isTrusted: true, hasChosenUpdates: false), .recordAsDone)
        XCTAssertEqual(OnboardingPolicy.decide(isBundled: true, hasCompleted: false, isTrusted: false, hasChosenUpdates: true), .recordAsDone)
    }

    func testACopyRunFromSourceNeverIs() {
        XCTAssertEqual(OnboardingPolicy.decide(isBundled: false, hasCompleted: false, isTrusted: false, hasChosenUpdates: false), .skip)
    }
}
