import XCTest
@testable import MouseNavigateCore

final class MomentumScrollerTests: XCTestCase {
    /// Notches at the given times, frames every `frame` seconds until the scroller is idle.
    private func run(
        _ scroller: inout MomentumScroller,
        notches: [(time: Double, vertical: Double)],
        frame: Double = 1.0 / 120,
        limit: Double = 10
    ) -> [MomentumScroller.Frame] {
        var frames: [MomentumScroller.Frame] = []
        var pending = notches.sorted { $0.time < $1.time }
        var now = 0.0
        while now < limit {
            while let next = pending.first, next.time <= now {
                scroller.add(vertical: next.vertical, horizontal: 0, at: next.time)
                pending.removeFirst()
            }
            if let out = scroller.frame(at: now) {
                frames.append(out)
            }
            if pending.isEmpty, scroller.isIdle { break }
            now += frame
        }
        return frames
    }

    private func distance(_ frames: [MomentumScroller.Frame]) -> Int {
        frames.reduce(0) { $0 + $1.vertical }
    }

    private func flick(_ count: Int = 10, every gap: Double = 0.02, by step: Double = 40) -> [(time: Double, vertical: Double)] {
        (0..<count).map { (Double($0) * gap, step) }
    }

    // MARK: - Without momentum

    func testPlainSmoothingCarriesNoPhasesAndLosesNothing() {
        var scroller = MomentumScroller(hasMomentum: false)
        let frames = run(&scroller, notches: [(0, 100), (0.05, 30)])
        XCTAssertEqual(distance(frames), 130)
        XCTAssertTrue(frames.allSatisfy { $0.phase == nil && $0.momentum == .none })
        XCTAssertTrue(scroller.isIdle)
    }

    func testAFlickDoesNotCoastWithoutMomentum() {
        var scroller = MomentumScroller(hasMomentum: false)
        let frames = run(&scroller, notches: flick())
        XCTAssertEqual(distance(frames), 400)
    }

    // MARK: - With momentum

    func testASingleNotchIsAGestureThatEndsWithoutCoasting() {
        var scroller = MomentumScroller(hasMomentum: true)
        let frames = run(&scroller, notches: [(0, 40)])
        XCTAssertEqual(frames.first?.phase, .began)
        XCTAssertEqual(frames.last?.phase, .ended)
        XCTAssertEqual(frames.dropFirst().dropLast().map(\.phase), Array(repeating: .changed, count: frames.count - 2))
        XCTAssertFalse(frames.contains { $0.momentum != .none }, "a single notch never coasts")
        XCTAssertEqual(distance(frames), 40)
    }

    func testAFlickEndsThenCoastsFurther() {
        var scroller = MomentumScroller(hasMomentum: true)
        let frames = run(&scroller, notches: flick())
        let ended = try! XCTUnwrap(frames.firstIndex { $0.phase == .ended })
        XCTAssertEqual(frames.filter { $0.phase == .ended }.count, 1)
        XCTAssertEqual(frames[ended + 1].momentum, .begin)
        XCTAssertEqual(frames.last?.momentum, .end)
        XCTAssertTrue(frames[(ended + 2)..<(frames.count - 1)].allSatisfy { $0.momentum == .continue })
        XCTAssertTrue(frames[..<ended].allSatisfy { $0.momentum == .none })
        XCTAssertGreaterThan(distance(frames), 400, "the coast goes beyond the notches")
    }

    func testTheCoastSlowsDown() {
        var scroller = MomentumScroller(hasMomentum: true)
        let frames = run(&scroller, notches: flick())
        let coast = frames.filter { $0.momentum == .continue }.map(\.vertical)
        XCTAssertGreaterThan(coast.count, 5)
        XCTAssertGreaterThan(coast.prefix(3).reduce(0, +), coast.suffix(3).reduce(0, +))
    }

    func testFrameRateDoesNotChangeTheDistance() {
        var at60 = MomentumScroller(hasMomentum: true)
        var at120 = MomentumScroller(hasMomentum: true)
        let slow = distance(run(&at60, notches: flick(), frame: 1.0 / 60))
        let fast = distance(run(&at120, notches: flick(), frame: 1.0 / 120))
        XCTAssertEqual(Double(slow), Double(fast), accuracy: 0.03 * Double(fast))
    }

    func testANotchDuringTheCoastEndsItAndBeginsAgain() {
        var scroller = MomentumScroller(hasMomentum: true)
        var notches = flick()
        notches.append((0.5, 40))
        let frames = run(&scroller, notches: notches)
        let interrupted = try! XCTUnwrap(frames.firstIndex { $0.momentum == .end })
        XCTAssertEqual(frames[interrupted + 1].phase, .began, "a new gesture after the coast's end")
        XCTAssertEqual(frames.last?.phase, .ended, "and the single notch does not coast")
    }

    func testTurningTheOtherWayDropsWhatWasLeft() {
        var scroller = MomentumScroller(hasMomentum: false)
        let frames = run(&scroller, notches: [(0, 100), (0.01, -20)])
        XCTAssertLessThan(distance(frames), 100 - 20)
        XCTAssertLessThan(frames.last?.vertical ?? 0, 0)
    }

    func testCancelClosesWhateverIsOpen() {
        var idle = MomentumScroller(hasMomentum: true)
        XCTAssertNil(idle.cancel())

        var gesture = MomentumScroller(hasMomentum: true)
        gesture.add(vertical: 40, horizontal: 0, at: 0)
        XCTAssertEqual(gesture.frame(at: 0)?.phase, .began)
        XCTAssertEqual(gesture.cancel()?.phase, .cancelled)
        XCTAssertTrue(gesture.isIdle)

        var coasting = MomentumScroller(hasMomentum: true)
        let frames = run(&coasting, notches: flick(), limit: 0.4)
        XCTAssertTrue(frames.contains { $0.momentum == .begin })
        XCTAssertEqual(coasting.cancel()?.momentum, .end)
        XCTAssertTrue(coasting.isIdle)
    }

    func testNotYetBegunNeedsNoClosing() {
        var scroller = MomentumScroller(hasMomentum: true)
        scroller.add(vertical: 40, horizontal: 0, at: 0)
        XCTAssertNil(scroller.cancel())
    }
}
