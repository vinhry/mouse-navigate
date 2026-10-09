import XCTest
@testable import MouseNavigateCore

/// Scripts fingers over time, feeding a frame to the recognizer at every step as a real
/// surface would.
private final class TouchDriver {
    var recognizer: TouchGestureRecognizer
    var time = 0.0
    var fingers: [Int: Vector2] = [:]
    var isButtonDown = false
    private(set) var events: [TouchEvent] = []
    private(set) var suppressedScroll = false

    init(_ surface: TouchSurface, leftHanded: Bool = false) {
        recognizer = TouchGestureRecognizer(surface: surface)
        recognizer.isLeftHanded = leftHanded
    }

    var gestures: [TouchGesture] {
        events.compactMap { event in
            if case .gesture(let gesture) = event { return gesture }
            return nil
        }
    }

    var progressPaths: [[Vector2]] {
        events.compactMap { event in
            if case .strokeProgress(let points) = event { return points }
            return nil
        }
    }

    var wasCancelled: Bool {
        events.contains { $0 == .strokeCancelled }
    }

    var strokes: [[Vector2]] {
        events.compactMap { event in
            if case .stroke(let points) = event { return points }
            return nil
        }
    }

    func frame() {
        let contacts = fingers.map { TouchContact(id: $0.key, position: $0.value) }
        events += recognizer.process(TouchFrame(
            timestamp: time,
            contacts: contacts,
            isPrimaryButtonDown: isButtonDown,
            aspectRatio: 1.6
        ))
        suppressedScroll = suppressedScroll || recognizer.shouldSuppressScroll
    }

    func down(_ id: Int, _ x: Double, _ y: Double = 0.5) {
        fingers[id] = Vector2(x: x, y: y)
        frame()
    }

    func up(_ ids: Int...) {
        for id in ids {
            fingers[id] = nil
        }
        frame()
        // A Magic Mouse lift is only believed once the lift grace has passed.
        if recognizer.surface == .magicMouse {
            wait(0.1)
        }
    }

    /// Takes a finger off the surface for a moment, as a Magic Mouse keeps doing to a
    /// lightly resting one, and brings it back where it is now, under the same or a new id.
    func flicker(_ id: Int, frames: Int = 1, newID: Int? = nil) {
        guard let position = fingers[id] else { return }
        fingers[id] = nil
        wait(0.01 * Double(frames))
        fingers[newID ?? id] = position
        frame()
    }

    func wait(_ seconds: Double) {
        let steps = Int((seconds / 0.01).rounded())
        for _ in 0..<steps {
            time += 0.01
            frame()
        }
    }

    func slide(_ ids: [Int], by delta: Vector2, over seconds: Double = 0.2) {
        let steps = max(Int((seconds / 0.01).rounded()), 1)
        for _ in 0..<steps {
            time += 0.01
            for id in ids {
                guard let position = fingers[id] else { continue }
                fingers[id] = Vector2(
                    x: position.x + delta.x / Double(steps),
                    y: position.y + delta.y / Double(steps)
                )
            }
            frame()
        }
    }

    func tap(_ id: Int, _ x: Double, _ y: Double = 0.5) {
        down(id, x, y)
        wait(0.06)
        up(id)
    }
}

final class TrackpadGestureTests: XCTestCase {
    func testOneFixRightTap() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3)
        pad.wait(0.2)
        pad.tap(2, 0.5)
        pad.wait(0.1)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixRightTap])
    }

    func testOneFixLeftTap() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.6)
        pad.wait(0.2)
        pad.tap(2, 0.4)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixLeftTap])
    }

    func testRepeatedTapsWhileRestingRepeat() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3)
        pad.wait(0.2)
        pad.tap(2, 0.5)
        pad.wait(0.1)
        pad.tap(3, 0.5)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixRightTap, .trackpadOneFixRightTap])
    }

    func testLeftHandedMirrorsSideTaps() {
        let pad = TouchDriver(.trackpad, leftHanded: true)
        pad.down(1, 0.6)
        pad.wait(0.2)
        pad.tap(2, 0.4)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixRightTap])
    }

    func testSlowRestAndLiftIsNotATap() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3)
        pad.wait(0.2)
        pad.down(2, 0.5)
        pad.wait(0.5)
        pad.up(2)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [])
    }

    func testThreeFingerTap() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3)
        pad.down(2, 0.45)
        pad.down(3, 0.6)
        pad.wait(0.1)
        pad.up(1, 2, 3)
        XCTAssertEqual(pad.gestures, [.trackpadThreeFingerTap])
    }

    func testOneFixTwoTap() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3)
        pad.wait(0.2)
        pad.down(2, 0.45)
        pad.down(3, 0.6)
        pad.wait(0.08)
        pad.up(2, 3)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixTwoTap])
    }

    func testTwoFixIndexDoubleTap() {
        let pad = TouchDriver(.trackpad)
        pad.down(2, 0.5)
        pad.down(3, 0.65)
        pad.wait(0.2)
        pad.tap(1, 0.3)
        pad.wait(0.1)
        pad.tap(4, 0.3)
        pad.up(2, 3)
        XCTAssertEqual(pad.gestures, [.trackpadTwoFixIndexDoubleTap])
    }

    func testTwoFixSingleIndexTapDoesNothing() {
        let pad = TouchDriver(.trackpad)
        pad.down(2, 0.5)
        pad.down(3, 0.65)
        pad.wait(0.2)
        pad.tap(1, 0.3)
        pad.wait(0.5)
        pad.up(2, 3)
        XCTAssertEqual(pad.gestures, [])
    }

    func testOneFixTwoSlideDown() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3, 0.4)
        pad.wait(0.2)
        pad.down(2, 0.45, 0.3)
        pad.down(3, 0.6, 0.3)
        pad.slide([2, 3], by: Vector2(x: 0, y: 0.25))
        pad.up(2, 3)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixTwoSlideDown])
        XCTAssertTrue(pad.suppressedScroll)
    }

    func testOneFixTwoSlideUp() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3, 0.4)
        pad.wait(0.2)
        pad.down(2, 0.45, 0.6)
        pad.down(3, 0.6, 0.6)
        pad.slide([2, 3], by: Vector2(x: 0, y: -0.25))
        pad.up(1, 2, 3)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixTwoSlideUp])
    }

    func testClickTwoSlideDown() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3, 0.6)
        pad.isButtonDown = true
        pad.wait(0.2)
        pad.down(2, 0.45, 0.3)
        pad.down(3, 0.6, 0.3)
        pad.slide([2, 3], by: Vector2(x: 0, y: 0.25))
        pad.isButtonDown = false
        pad.up(1, 2, 3)
        XCTAssertEqual(pad.gestures, [.trackpadClickTwoSlideDown])
    }

    func testOneFixOneSlideDownDrivesAWindowDrag() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3, 0.5)
        pad.wait(0.2)
        pad.down(2, 0.45, 0.3)
        pad.slide([2], by: Vector2(x: 0, y: 0.2))
        pad.up(2)
        pad.slide([1], by: Vector2(x: 0.2, y: 0))
        pad.tap(3, 0.6)
        pad.up(1)
        XCTAssertEqual(pad.events, [.gesture(.trackpadOneFixOneSlideDown), .dragToggleMode, .dragEnded])
    }

    func testIndexToPinkyTaps() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.2)
        pad.wait(0.05)
        pad.down(2, 0.4)
        pad.wait(0.05)
        pad.down(3, 0.6)
        pad.wait(0.05)
        pad.down(4, 0.8)
        pad.wait(0.1)
        pad.up(1, 2, 3, 4)
        XCTAssertEqual(pad.gestures, [.trackpadIndexToPinky])
    }

    func testPinkyToIndexTaps() {
        let pad = TouchDriver(.trackpad)
        pad.down(4, 0.8)
        pad.wait(0.05)
        pad.down(3, 0.6)
        pad.wait(0.05)
        pad.down(2, 0.4)
        pad.wait(0.05)
        pad.down(1, 0.2)
        pad.wait(0.1)
        pad.up(4, 3)
        pad.wait(0.02)
        pad.up(2, 1)
        XCTAssertEqual(pad.gestures, [.trackpadPinkyToIndex])
    }

    func testTwoFingerScrollDoesNothing() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.45)
        pad.down(2, 0.55)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.3))
        pad.up(1, 2)
        XCTAssertEqual(pad.events, [])
        XCTAssertFalse(pad.suppressedScroll)
    }

    func testSpreadFingersDrawAStroke() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.5), over: 0.3)
        pad.up(1)
        pad.up(2)

        XCTAssertTrue(pad.suppressedScroll)
        XCTAssertEqual(pad.gestures, [])
        XCTAssertEqual(pad.strokes.count, 1)
        let stroke = pad.strokes.first ?? []
        XCTAssertEqual(stroke.first?.y ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(stroke.last?.y ?? 0, 0.7, accuracy: 0.001)
        // Midpoint x is 0.45, scaled by the 1.6 aspect ratio.
        XCTAssertEqual(stroke.first?.x ?? 0, 0.72, accuracy: 0.001)
    }

    func testLeftHandedStrokeIsNotMirrored() {
        let pad = TouchDriver(.trackpad, leftHanded: true)
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0.2, y: 0), over: 0.3)
        pad.up(1, 2)
        let stroke = pad.strokes.first ?? []
        XCTAssertGreaterThan((stroke.last?.x ?? 0) - (stroke.first?.x ?? 0), 0)
    }

    func testDrawingReportsProgressBeforeTheFinishedStroke() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.5), over: 0.3)
        pad.up(1, 2)

        XCTAssertGreaterThan(pad.progressPaths.count, 5)
        guard let last = pad.progressPaths.last, let stroke = pad.strokes.first else {
            return XCTFail("expected progress and a finished stroke")
        }
        // Progress grows point by point and the finished stroke carries on from it.
        XCTAssertEqual(Array(stroke.prefix(last.count)), last)
        XCTAssertLessThan(pad.progressPaths[0].count, last.count)

        let strokeIndex = pad.events.firstIndex { if case .stroke = $0 { return true } else { return false } }
        let progressIndex = pad.events.firstIndex { if case .strokeProgress = $0 { return true } else { return false } }
        XCTAssertLessThan(progressIndex ?? 0, strokeIndex ?? 0)
        XCTAssertFalse(pad.wasCancelled)
    }

    func testShortDrawingIsCancelled() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.1))
        pad.up(1, 2)
        XCTAssertTrue(pad.wasCancelled)
        XCTAssertEqual(pad.strokes.count, 0)
    }

    func testThirdFingerCancelsTheDrawing() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.3), over: 0.2)
        pad.down(3, 0.45, 0.8)
        pad.up(1, 2, 3)
        XCTAssertTrue(pad.wasCancelled)
        XCTAssertEqual(pad.strokes.count, 0)
    }

    func testLeftHandedStrokesStayOnTheSurface() {
        let pad = TouchDriver(.trackpad, leftHanded: true)
        pad.down(1, 0.15, 0.2)
        pad.down(2, 0.75, 0.25)
        pad.slide([1, 2], by: Vector2(x: 0.15, y: 0.4), over: 0.3)
        pad.up(1, 2)

        let aspectRatio = 1.6
        let drawn = pad.progressPaths.flatMap { $0 } + pad.strokes.flatMap { $0 }
        XCTAssertFalse(drawn.isEmpty)
        for point in drawn {
            XCTAssertTrue((0...aspectRatio).contains(point.x), "x \(point.x) is off the surface")
            XCTAssertTrue((0...1).contains(point.y), "y \(point.y) is off the surface")
        }
    }

    func testFingerSpacingDecidesWhatCountsAsDrawing() {
        func draw(spread: Double, fingersApart: Double) -> Int {
            let pad = TouchDriver(.trackpad)
            pad.recognizer.tuning.drawSpread = spread
            pad.down(1, 0.45 - fingersApart / 2, 0.2)
            pad.down(2, 0.45 + fingersApart / 2, 0.2)
            pad.slide([1, 2], by: Vector2(x: 0, y: 0.5), over: 0.3)
            pad.up(1, 2)
            return pad.strokes.count
        }

        // Fingers a fifth of the pad apart: drawing only when asked for that closely.
        XCTAssertEqual(draw(spread: 0.3, fingersApart: 0.2), 0)
        XCTAssertEqual(draw(spread: 0.15, fingersApart: 0.2), 1)
        // A wide setting still leaves a wide reach drawing.
        XCTAssertEqual(draw(spread: 0.5, fingersApart: 0.55), 1)
    }

    func testDrawSpreadSettingStaysInRange() {
        XCTAssertEqual(TouchTuning.clampDrawSpread(5), TouchTuning.drawSpreadRange.upperBound)
        XCTAssertEqual(TouchTuning.clampDrawSpread(0), TouchTuning.drawSpreadRange.lowerBound)
        XCTAssertTrue(TouchTuning.drawSpreadRange.contains(TouchTuning().drawSpread))
    }

    func testLongDrawingStopsGrowing() {
        let pad = TouchDriver(.trackpad)
        pad.recognizer.tuning.maxStrokePoints = 40
        pad.down(1, 0.15, 0.2)
        pad.down(2, 0.75, 0.2)
        // Far more frames than the cap allows.
        for _ in 0..<6 {
            pad.slide([1, 2], by: Vector2(x: 0, y: 0.1), over: 0.3)
            pad.slide([1, 2], by: Vector2(x: 0, y: -0.1), over: 0.3)
        }
        pad.up(1, 2)

        for path in pad.progressPaths + pad.strokes {
            XCTAssertLessThanOrEqual(path.count, 40, "a stroke kept growing past the cap")
        }
        // Capped, but still a drawing rather than nothing.
        XCTAssertEqual(pad.strokes.count, 1)
    }

    func testDrawingCanBeTurnedOff() {
        let pad = TouchDriver(.trackpad)
        pad.recognizer.isDrawingEnabled = false
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.5), over: 0.3)
        pad.up(1, 2)
        XCTAssertEqual(pad.events, [])
        XCTAssertFalse(pad.suppressedScroll)
    }

    func testShortDrawingIsIgnored() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.2, 0.2)
        pad.down(2, 0.7, 0.2)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.1))
        pad.up(1, 2)
        XCTAssertEqual(pad.strokes.count, 0)
    }
}

final class MagicMouseGestureTests: XCTestCase {
    func testMiddleFixIndexNearTap() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.2)
        mouse.tap(1, 0.42, 0.42)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap])
    }

    func testMiddleFixIndexFarTap() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.9, 0.2)
        mouse.wait(0.2)
        mouse.tap(1, 0.1, 0.22)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexFarTap])
    }

    func testTapAtTheNaturalSpreadIsNear() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.91, 0.21)
        mouse.wait(0.3)
        mouse.tap(1, 0.42, 0.24)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap])
    }

    func testMiddleFixIndexSlideLeft() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.2)
        mouse.down(1, 0.4, 0.4)
        mouse.slide([1], by: Vector2(x: -0.2, y: 0))
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexSlideLeft])
        XCTAssertTrue(mouse.suppressedScroll)
    }

    func testIndexFixMiddleSlideRight() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.4, 0.4)
        mouse.wait(0.2)
        mouse.down(2, 0.6, 0.4)
        mouse.slide([2], by: Vector2(x: 0.2, y: 0))
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [.mouseIndexFixMiddleSlideRight])
    }

    func testTwoFixIndexSlideRight() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.55, 0.4)
        mouse.down(3, 0.75, 0.4)
        mouse.wait(0.2)
        mouse.down(1, 0.25, 0.4)
        mouse.slide([1], by: Vector2(x: 0.15, y: 0))
        mouse.up(1, 2, 3)
        XCTAssertEqual(mouse.gestures, [.mouseTwoFixIndexSlideRight])
    }

    func testThreeFingerSwipeUp() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.3, 0.6)
        mouse.down(2, 0.5, 0.6)
        mouse.down(3, 0.7, 0.6)
        mouse.slide([1, 2, 3], by: Vector2(x: 0, y: -0.25))
        mouse.up(1, 2, 3)
        XCTAssertEqual(mouse.gestures, [.mouseThreeFingerSwipeUp])
    }

    func testThreeFingerSwipeDown() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.3, 0.3)
        mouse.down(2, 0.5, 0.3)
        mouse.down(3, 0.7, 0.3)
        mouse.slide([1, 2, 3], by: Vector2(x: 0, y: 0.25))
        mouse.up(1, 2, 3)
        XCTAssertEqual(mouse.gestures, [.mouseThreeFingerSwipeDown])
    }

    func testCornerHoldDrivesAWindowDrag() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.2, 0.65)
        mouse.down(2, 0.7, 0.25)
        mouse.wait(0.5)
        mouse.up(1)
        mouse.wait(0.2)
        mouse.up(2)
        XCTAssertEqual(mouse.events, [.gesture(.mouseCornerHold), .dragToggleMode, .dragEnded])
    }

    func testRestingFingersSideBySideDoNothing() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.4, 0.4)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(1)
        mouse.up(1, 2)
        XCTAssertEqual(mouse.events, [])
    }

    // MARK: Holding the mouse

    func testSlideStartsFromFingersAlreadyResting() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.4, 0.4)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(1)
        mouse.slide([1], by: Vector2(x: -0.2, y: 0))
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexSlideLeft])
        XCTAssertTrue(mouse.suppressedScroll)

        // Coming to rest re-arms it: no need to lift anything between slides.
        mouse.wait(0.5)
        mouse.slide([1], by: Vector2(x: 0.2, y: 0))
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexSlideLeft, .mouseMiddleFixIndexSlideRight])
    }

    func testOneSlideFiresOnce() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.4, 0.4)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.5)
        mouse.slide([1], by: Vector2(x: -0.3, y: 0), over: 0.6)
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexSlideLeft])
    }

    func testRestingFingerThatDriftedStillAnchorsATap() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        // Two seconds of use, the finger creeping as the mouse is moved about.
        for _ in 0..<20 {
            mouse.wait(0.1)
            mouse.fingers[2]!.x += 0.008
        }
        mouse.tap(1, 0.52, 0.42)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap])
    }

    func testRestingFingerThatDriftedStillAnchorsASlide() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        for _ in 0..<20 {
            mouse.wait(0.1)
            mouse.fingers[2]!.y += 0.008
        }
        mouse.down(1, 0.4, 0.4)
        mouse.slide([1], by: Vector2(x: -0.2, y: 0))
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexSlideLeft])
    }

    func testClickBesideARestingFingerIsNotATap() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.2)
        mouse.down(1, 0.42, 0.42)
        mouse.wait(0.03)
        mouse.isButtonDown = true
        mouse.wait(0.06)
        mouse.isButtonDown = false
        mouse.wait(0.02)
        mouse.up(1)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [])
    }

    func testScrollingBesideARestingFingerIsLeftAlone() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.4, 0.3)
        mouse.down(2, 0.6, 0.3)
        mouse.wait(0.5)
        mouse.slide([1], by: Vector2(x: 0, y: 0.3))
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [])
        XCTAssertFalse(mouse.suppressedScroll)
    }

    func testPalmOnTheBackOfTheMouseIsNotAFinger() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(9, 0.5, 0.9)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.2)
        mouse.tap(1, 0.42, 0.42)
        mouse.up(2, 9)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap])

        let index = TouchContact(id: 1, position: Vector2(x: 0.4, y: 0.6))
        let middle = TouchContact(id: 2, position: Vector2(x: 0.6, y: 0.45))
        let palm = TouchContact(id: 9, position: Vector2(x: 0.5, y: 0.92), size: 3)
        XCTAssertTrue(TouchGestureRecognizer.isMiddleClickPose([palm, middle, index]))
    }

    // MARK: Contacts the mouse keeps losing

    func testFlickeringRestingFingerIsNotTapping() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(1, 0.25, 0.25)
        mouse.down(2, 0.75, 0.2)
        mouse.wait(0.5)
        for round in 0..<10 {
            mouse.flicker(1, frames: 2, newID: round % 2 == 0 ? nil : 100 + round)
            mouse.wait(0.05)
        }
        mouse.up(1, 2)
        XCTAssertEqual(mouse.gestures, [])
    }

    func testSlideSurvivesFlicker() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        mouse.down(1, 0.4, 0.4)
        mouse.wait(0.5)
        var id = 1
        var x = 0.4
        for step in 0..<20 {
            x -= 0.012
            mouse.fingers[id] = Vector2(x: x, y: 0.4)
            mouse.wait(0.01)
            if step % 4 == 3 {
                // Dropped for a frame, back under a new id a little further along.
                mouse.fingers[id] = nil
                mouse.wait(0.01)
                id += 10
                x -= 0.012
                mouse.fingers[id] = Vector2(x: x, y: 0.4)
                mouse.frame()
            }
        }
        mouse.up(id)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexSlideLeft])
    }

    func testQuickRepeatedTapsStaySeparate() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.85, 0.2)
        mouse.wait(0.3)
        for _ in 0..<3 {
            mouse.down(1, 0.5, 0.22)
            mouse.wait(0.05)
            mouse.fingers[1] = nil
            mouse.wait(0.07)
        }
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, Array(repeating: .mouseMiddleFixIndexNearTap, count: 3))
    }

    func testBouncingTapIsOneTap() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.91, 0.21)
        mouse.wait(0.3)
        for _ in 0..<3 {
            mouse.down(1, 0.3, 0.22)
            mouse.wait(0.02)
            mouse.fingers[1] = nil
            mouse.wait(0.02)
        }
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexFarTap])
    }

    func testMovedRestingFingerStillAnchorsOnTheMouse() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.88, 0.2)
        mouse.wait(0.2)
        mouse.slide([2], by: Vector2(x: -0.04, y: 0), over: 0.05)
        mouse.tap(1, 0.45, 0.22)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap])
    }

    func testTapsSurviveTheRestingFingerRocking() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.88, 0.2)
        mouse.wait(0.3)
        for round in 0..<3 {
            // Each tap rocks the mouse, and the resting finger shifts a hair with it.
            mouse.fingers[2]!.x = round % 2 == 0 ? 0.85 : 0.89
            mouse.down(1, 0.5, 0.22)
            mouse.wait(0.06)
            mouse.fingers[1] = nil
            mouse.wait(0.1)
        }
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, Array(repeating: .mouseMiddleFixIndexNearTap, count: 3))
    }

    func testAbsenceLongerThanTheGraceIsALift() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.3)
        mouse.tap(1, 0.42, 0.42)
        mouse.wait(0.2)
        mouse.tap(1, 0.42, 0.42)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap, .mouseMiddleFixIndexNearTap])
    }

    func testTapCountsWhenTheRestingFingerLiftsStraightAfter() {
        let mouse = TouchDriver(.magicMouse)
        mouse.down(2, 0.6, 0.4)
        mouse.wait(0.3)
        mouse.down(1, 0.42, 0.42)
        mouse.wait(0.06)
        mouse.fingers[1] = nil
        mouse.wait(0.02)
        mouse.up(2)
        XCTAssertEqual(mouse.gestures, [.mouseMiddleFixIndexNearTap])
    }

    func testFingersAreOnlyFilteredWhenOthersAreDown() {
        let alone = [TouchContact(id: 1, position: Vector2(x: 0.5, y: 0.9))]
        XCTAssertEqual(TouchGestureRecognizer.fingers(among: alone, on: .magicMouse), alone)

        let edge = TouchContact(id: 3, position: Vector2(x: 1, y: 0.4), size: 0.1)
        let finger = TouchContact(id: 1, position: Vector2(x: 0.5, y: 0.4), size: 1)
        XCTAssertEqual(TouchGestureRecognizer.fingers(among: [edge, finger], on: .magicMouse), [finger])
        XCTAssertEqual(TouchGestureRecognizer.fingers(among: [edge, finger], on: .trackpad), [edge, finger])
    }

    func testMiddleClickPose() {
        let index = TouchContact(id: 1, position: Vector2(x: 0.4, y: 0.6))
        let middle = TouchContact(id: 2, position: Vector2(x: 0.6, y: 0.45))
        XCTAssertTrue(TouchGestureRecognizer.isMiddleClickPose([middle, index]))

        let level = TouchContact(id: 1, position: Vector2(x: 0.4, y: 0.47))
        XCTAssertFalse(TouchGestureRecognizer.isMiddleClickPose([middle, level]))
        XCTAssertFalse(TouchGestureRecognizer.isMiddleClickPose([index]))
    }

    func testMiddleClickPoseLeftHanded() {
        let middle = TouchContact(id: 2, position: Vector2(x: 0.4, y: 0.45))
        let index = TouchContact(id: 1, position: Vector2(x: 0.6, y: 0.6))
        XCTAssertTrue(TouchGestureRecognizer.isMiddleClickPose([middle, index], isLeftHanded: true))
        XCTAssertFalse(TouchGestureRecognizer.isMiddleClickPose([middle, index]))
    }
}

final class TouchGestureTests: XCTestCase {
    func testEveryGestureHasASurfaceAndDefault() {
        XCTAssertEqual(
            TouchGesture.gestures(for: .trackpad).count + TouchGesture.gestures(for: .magicMouse).count,
            TouchGesture.allCases.count
        )
        for gesture in TouchGesture.allCases {
            XCTAssertTrue(gesture.allows(gesture.defaultAction), "\(gesture) default must be allowed")
        }
    }

    func testMoveResizeOnlyForLastingGestures() {
        XCTAssertTrue(TouchGesture.mouseCornerHold.allows(.moveResizeWindow))
        XCTAssertFalse(TouchGesture.trackpadThreeFingerTap.allows(.moveResizeWindow))
    }
}

final class TrackpadFalsePositiveTests: XCTestCase {
    func testStaggeredTwoFingerTapLiftingTogetherIsNothing() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.4, 0.4)
        pad.wait(0.15)
        pad.down(2, 0.55, 0.4)
        pad.wait(0.06)
        pad.up(1, 2)
        XCTAssertEqual(pad.events, [])
    }

    func testFingerThatHasMovedIsNotAnAnchor() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.4, 0.4)
        pad.wait(0.1)
        pad.slide([1], by: Vector2(x: 0, y: 0.05), over: 0.05)
        pad.tap(2, 0.55, 0.42)
        pad.up(1)
        XCTAssertEqual(pad.events, [])
    }

    func testQuickAlternatingTapsBothFire() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.4, 0.4)
        pad.wait(0.2)
        pad.tap(2, 0.55, 0.4)
        pad.wait(0.02)
        pad.tap(3, 0.25, 0.4)
        pad.up(1)
        XCTAssertEqual(pad.gestures, [.trackpadOneFixRightTap, .trackpadOneFixLeftTap])
    }

    func testFastIndexDoubleTapFires() {
        let pad = TouchDriver(.trackpad)
        pad.down(2, 0.5, 0.4)
        pad.down(3, 0.6, 0.4)
        pad.wait(0.2)
        pad.tap(1, 0.35, 0.42)
        pad.wait(0.03)
        pad.tap(1, 0.35, 0.42)
        pad.up(2, 3)
        XCTAssertEqual(pad.gestures, [.trackpadTwoFixIndexDoubleTap])
    }

    func testRestingThumbDoesNotTurnScrollIntoGesture() {
        let pad = TouchDriver(.trackpad)
        pad.down(9, 0.3, 0.95)
        pad.wait(0.3)
        pad.down(1, 0.45, 0.3)
        pad.down(2, 0.55, 0.3)
        pad.slide([1, 2], by: Vector2(x: 0, y: 0.3))
        pad.up(1, 2)
        pad.up(9)
        XCTAssertEqual(pad.events, [])
        XCTAssertFalse(pad.suppressedScroll)
    }

    func testRestingThumbDoesNotTurnTapIntoTabSwitch() {
        let pad = TouchDriver(.trackpad)
        pad.down(9, 0.3, 0.95)
        pad.wait(0.3)
        pad.tap(1, 0.5, 0.4)
        pad.up(9)
        XCTAssertEqual(pad.events, [])
    }

    func testTapFarAboveRestingFingerIsIgnored() {
        let pad = TouchDriver(.trackpad)
        pad.down(1, 0.3, 0.8)
        pad.wait(0.2)
        pad.tap(2, 0.5, 0.2)
        pad.up(1)
        XCTAssertEqual(pad.events, [])
    }
}
