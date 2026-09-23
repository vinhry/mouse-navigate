import Foundation

/// Recognizes gestures on one multitouch surface from a stream of frames.
///
/// Each gesture family has its own detector watching the same contacts. The first detector
/// to report something owns the touch session, and the others stay quiet until every
/// finger has lifted, so one movement never triggers two actions.
public struct TouchGestureRecognizer {
    public let surface: TouchSurface
    public var tuning: TouchTuning
    public var isLeftHanded = false
    /// With drawing off, two spread fingers are left to scroll as usual.
    public var isDrawingEnabled = true

    public private(set) var shouldSuppressScroll = false

    private var tracker = ContactTracker()
    private var detectors: [any GestureDetector]
    private var owner: Int?

    public init(surface: TouchSurface, tuning: TouchTuning = TouchTuning()) {
        self.surface = surface
        self.tuning = tuning
        switch surface {
        case .trackpad:
            detectors = [
                FixedTapDetector(surface: .trackpad),
                FixedSlideDetector(surface: .trackpad),
                ThreeFingerTapDetector(),
                SequentialTapDetector(),
                DrawingDetector(),
            ]
        case .magicMouse:
            detectors = [
                FixedTapDetector(surface: .magicMouse),
                FixedSlideDetector(surface: .magicMouse),
                ThreeFingerSwipeDetector(),
                CornerHoldDetector(),
            ]
        }
    }

    public mutating func process(_ frame: TouchFrame) -> [TouchEvent] {
        let snapshot = tracker.update(isLeftHanded ? frame.mirrored() : frame)

        var events: [TouchEvent] = []
        for index in detectors.indices {
            if !isDrawingEnabled && detectors[index] is DrawingDetector {
                continue
            }
            let blocked = owner != nil && owner != index
            let produced = detectors[index].update(snapshot, tuning: tuning, blocked: blocked)
            guard !produced.isEmpty, !blocked else { continue }
            owner = index
            events += produced
        }

        shouldSuppressScroll = detectors.indices.contains { index in
            (owner == nil || owner == index) && detectors[index].suppressesScroll
                && (isDrawingEnabled || !(detectors[index] is DrawingDetector))
        }

        if snapshot.active.isEmpty {
            owner = nil
        }

        guard isLeftHanded else { return events }
        // Letters must not come out mirrored just because the fingers were. Mirroring back
        // across the surface, rather than negating, keeps the points inside it for drawing.
        func unmirror(_ points: [Vector2]) -> [Vector2] {
            points.map { Vector2(x: frame.aspectRatio - $0.x, y: $0.y) }
        }
        return events.map { event in
            switch event {
            case .stroke(let points): return .stroke(unmirror(points))
            case .strokeProgress(let points): return .strokeProgress(unmirror(points))
            default: return event
            }
        }
    }

    public mutating func reset() {
        tracker.reset()
        for index in detectors.indices {
            detectors[index].reset()
        }
        owner = nil
        shouldSuppressScroll = false
    }

    /// A Magic Mouse click made with the index finger held nearer the back than the resting
    /// middle finger, which jitouch users know as "open link in new tab".
    public static func isMiddleClickPose(
        _ contacts: [TouchContact],
        tuning: TouchTuning = TouchTuning(),
        isLeftHanded: Bool = false
    ) -> Bool {
        guard contacts.count == 2 else { return false }
        let sorted = contacts.sorted { $0.position.x < $1.position.x }
        let index = isLeftHanded ? sorted[1] : sorted[0]
        let middle = isLeftHanded ? sorted[0] : sorted[1]
        return index.position.y - middle.position.y >= tuning.middleClickOffset
    }
}

// MARK: - Detectors

protocol GestureDetector {
    /// `blocked` means another detector owns the session: keep state current, start nothing.
    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent]
    var suppressesScroll: Bool { get }
    mutating func reset()
}

private func mean(_ vectors: [Vector2]) -> Vector2 {
    guard !vectors.isEmpty else { return .zero }
    let sum = vectors.reduce(Vector2.zero) { Vector2(x: $0.x + $1.x, y: $0.y + $1.y) }
    return Vector2(x: sum.x / Double(vectors.count), y: sum.y / Double(vectors.count))
}

/// Fingers that land beside one or two resting fingers. Resting fingers are chosen when the
/// first new finger lands, and must still be down when the new ones have lifted.
private func restingFingers(
    whenLanding snapshot: ContactSnapshot,
    surface: TouchSurface,
    tuning: TouchTuning
) -> [TrackedContact]? {
    let landed = Set(snapshot.landed.map(\.id))
    let others = snapshot.active.filter { !landed.contains($0.id) }
    guard (1...2).contains(others.count),
          others.allSatisfy({ $0.isFixed(at: snapshot.time, tuning: tuning) })
    else {
        return nil
    }
    if surface == .trackpad {
        guard others.allSatisfy({ $0.position.y <= tuning.thumbZone }),
              snapshot.landed.allSatisfy({ contact in
                  others.contains { abs($0.position.y - contact.start.y) <= tuning.neighbourMaxOffset }
              })
        else {
            return nil
        }
    }
    return others
}

/// Taps made while one or two fingers rest: tab switching, two-finger taps and the index
/// double-tap.
struct FixedTapDetector: GestureDetector {
    let surface: TouchSurface

    private var anchors: [TrackedContact] = []
    private var burst: [Int: TrackedContact] = [:]
    private var lastTwoFixTap: Double?

    var suppressesScroll: Bool { false }

    init(surface: TouchSurface) {
        self.surface = surface
    }

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        if snapshot.active.isEmpty {
            reset()
            return []
        }

        if !snapshot.landed.isEmpty {
            if burst.isEmpty {
                anchors = restingFingers(whenLanding: snapshot, surface: surface, tuning: tuning) ?? []
            }
            // Only fingers joining resting ones form a burst; a first finger never does.
            if !burst.isEmpty || !anchors.isEmpty {
                for contact in snapshot.landed {
                    burst[contact.id] = contact
                }
            }
        }
        guard !burst.isEmpty else { return [] }

        for contact in snapshot.active + snapshot.lifted where burst[contact.id] != nil {
            burst[contact.id] = contact
        }

        // A resting finger that lifts or wanders cancels the burst.
        let currentAnchors = anchors.compactMap { snapshot.active($0.id) }
        if currentAnchors.count != anchors.count
            || currentAnchors.contains(where: { $0.maxDisplacement > tuning.fixTolerance * 2 }) {
            anchors = []
        }

        guard !burst.keys.contains(where: { snapshot.active($0) != nil }) else { return [] }

        let taps = burst.values.sorted { $0.start.x < $1.start.x }
        burst.removeAll()
        guard !blocked, !currentAnchors.isEmpty, anchors.count == currentAnchors.count,
              taps.allSatisfy({ $0.isTap(tuning: tuning) })
        else {
            return []
        }
        return classify(taps: taps, anchors: currentAnchors, time: snapshot.time, tuning: tuning)
    }

    private mutating func classify(
        taps: [TrackedContact],
        anchors: [TrackedContact],
        time: Double,
        tuning: TouchTuning
    ) -> [TouchEvent] {
        switch (surface, anchors.count, taps.count) {
        case (.trackpad, 1, 1):
            let gesture: TouchGesture = taps[0].start.x > anchors[0].position.x
                ? .trackpadOneFixRightTap
                : .trackpadOneFixLeftTap
            return [.gesture(gesture)]

        case (.trackpad, 1, 2):
            guard abs(taps[0].downTime - taps[1].downTime) <= tuning.simultaneousWindow else { return [] }
            return [.gesture(.trackpadOneFixTwoTap)]

        case (.trackpad, 2, 1):
            guard taps[0].start.x < anchors[0].position.x else { return [] }
            if let last = lastTwoFixTap, time - last <= tuning.doubleTapWindow {
                lastTwoFixTap = nil
                return [.gesture(.trackpadTwoFixIndexDoubleTap)]
            }
            lastTwoFixTap = time
            return []

        case (.magicMouse, 1, 1):
            // The index taps to the left of the resting middle finger.
            let tap = taps[0]
            let middle = anchors[0]
            guard tap.start.x < middle.position.x else { return [] }
            let distance = Vector2(x: middle.position.x - tap.start.x, y: middle.position.y - tap.start.y).magnitude
            return [.gesture(distance < tuning.nearTapDistance ? .mouseMiddleFixIndexNearTap : .mouseMiddleFixIndexFarTap)]

        default:
            return []
        }
    }

    mutating func reset() {
        anchors = []
        burst.removeAll()
        lastTwoFixTap = nil
    }
}

/// Fingers sliding beside resting ones: closing and reopening tabs, quitting, spaces, and
/// starting a trackpad window move.
struct FixedSlideDetector: GestureDetector {
    let surface: TouchSurface

    private var anchors: [TrackedContact] = []
    private var sliders: Set<Int> = []
    private var fired = false
    /// The resting index finger that ends a trackpad window move when it lifts.
    private var dragAnchor: Int?

    private(set) var suppressesScroll = false

    init(surface: TouchSurface) {
        self.surface = surface
    }

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        if snapshot.active.isEmpty {
            let wasDragging = dragAnchor != nil
            reset()
            return wasDragging ? [.dragEnded] : []
        }

        if let anchor = dragAnchor {
            guard snapshot.active(anchor) != nil else {
                dragAnchor = nil
                return [.dragEnded]
            }
            // Tapping another finger switches between moving and resizing.
            return snapshot.lifted
                .filter { $0.id != anchor && $0.isTap(tuning: tuning) }
                .map { _ in .dragToggleMode }
        }

        if !snapshot.landed.isEmpty {
            if sliders.isEmpty {
                anchors = restingFingers(whenLanding: snapshot, surface: surface, tuning: tuning) ?? []
            }
            if !anchors.isEmpty {
                sliders.formUnion(snapshot.landed.map(\.id))
            }
        }

        guard !fired, !anchors.isEmpty, !sliders.isEmpty else { return [] }

        let currentAnchors = anchors.compactMap { snapshot.active($0.id) }
        let moving = sliders.compactMap { snapshot.active($0) }
        guard currentAnchors.count == anchors.count,
              moving.count == sliders.count,
              !currentAnchors.contains(where: { $0.maxDisplacement > tuning.fixTolerance * 2 })
        else {
            cancel()
            return []
        }

        suppressesScroll = !blocked && moving.contains { $0.maxDisplacement > tuning.fixTolerance }
        guard !blocked, let gesture = classify(moving: moving, anchors: currentAnchors, snapshot: snapshot, tuning: tuning) else {
            return []
        }

        fired = true
        if gesture == .trackpadOneFixOneSlideDown {
            dragAnchor = currentAnchors[0].id
        }
        return [.gesture(gesture)]
    }

    private func classify(
        moving: [TrackedContact],
        anchors: [TrackedContact],
        snapshot: ContactSnapshot,
        tuning: TouchTuning
    ) -> TouchGesture? {
        let travel = mean(moving.map(\.displacement))
        let vertical = abs(travel.y) >= tuning.slideDistance && abs(travel.y) >= abs(travel.x) * tuning.dominantAxisRatio
        let horizontal = abs(travel.x) >= tuning.slideDistance && abs(travel.x) >= abs(travel.y) * tuning.dominantAxisRatio
        let leftmostAnchor = anchors.map(\.position.x).min() ?? 0
        let rightmostAnchor = anchors.map(\.position.x).max() ?? 0

        switch surface {
        case .trackpad:
            guard anchors.count == 1, vertical,
                  moving.allSatisfy({ $0.start.x > rightmostAnchor }),
                  moving.allSatisfy({ ($0.displacement.y > 0) == (travel.y > 0) })
            else {
                return nil
            }
            switch (moving.count, travel.y > 0) {
            case (2, true):
                return snapshot.isPrimaryButtonDown ? .trackpadClickTwoSlideDown : .trackpadOneFixTwoSlideDown
            case (2, false):
                return .trackpadOneFixTwoSlideUp
            case (1, true):
                return .trackpadOneFixOneSlideDown
            default:
                return nil
            }

        case .magicMouse:
            guard moving.count == 1, horizontal else { return nil }
            let slider = moving[0]
            let left = travel.x < 0
            switch anchors.count {
            case 1 where slider.start.x < leftmostAnchor:
                return left ? .mouseMiddleFixIndexSlideLeft : .mouseMiddleFixIndexSlideRight
            case 1:
                return left ? .mouseIndexFixMiddleSlideLeft : .mouseIndexFixMiddleSlideRight
            case 2 where slider.start.x < leftmostAnchor:
                return left ? .mouseTwoFixIndexSlideLeft : .mouseTwoFixIndexSlideRight
            default:
                return nil
            }
        }
    }

    /// Gives up on the current fingers; the next finger to land is judged afresh.
    private mutating func cancel() {
        anchors = []
        sliders = []
        suppressesScroll = false
    }

    mutating func reset() {
        anchors = []
        sliders = []
        fired = false
        dragAnchor = nil
        suppressesScroll = false
    }
}

/// Three fingers landing and lifting together.
struct ThreeFingerTapDetector: GestureDetector {
    private var session: [Int: TrackedContact] = [:]

    var suppressesScroll: Bool { false }

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        for contact in snapshot.landed + snapshot.active + snapshot.lifted {
            session[contact.id] = contact
        }
        guard snapshot.active.isEmpty else { return [] }

        let contacts = Array(session.values)
        reset()
        guard !blocked, contacts.count == 3,
              contacts.allSatisfy({ $0.isTap(tuning: tuning) }),
              let firstDown = contacts.map(\.downTime).min(),
              let lastDown = contacts.map(\.downTime).max(),
              lastDown - firstDown <= tuning.simultaneousWindow
        else {
            return []
        }
        return [.gesture(.trackpadThreeFingerTap)]
    }

    mutating func reset() {
        session.removeAll()
    }
}

/// Four fingers rolled down one at a time across the pad, then lifted together.
struct SequentialTapDetector: GestureDetector {
    private var session: [Int: TrackedContact] = [:]

    var suppressesScroll: Bool { false }

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        for contact in snapshot.landed + snapshot.active + snapshot.lifted {
            session[contact.id] = contact
        }
        guard snapshot.active.isEmpty else { return [] }

        let contacts = session.values.sorted { $0.downTime < $1.downTime }
        reset()
        guard !blocked, contacts.count == 4,
              contacts.allSatisfy({ $0.maxDisplacement <= tuning.tapTolerance * 2 }),
              let firstUp = contacts.compactMap(\.upTime).min(),
              let lastUp = contacts.compactMap(\.upTime).max(),
              lastUp - firstUp <= tuning.releaseTogetherWindow,
              firstUp >= contacts[3].downTime,
              contacts[3].downTime - contacts[0].downTime <= tuning.sequenceMaxSpan
        else {
            return []
        }

        let gaps = zip(contacts, contacts.dropFirst())
        guard gaps.allSatisfy({ $1.downTime - $0.downTime >= tuning.sequenceMinGap }) else { return [] }

        if gaps.allSatisfy({ $1.start.x > $0.start.x }) {
            return [.gesture(.trackpadIndexToPinky)]
        }
        if gaps.allSatisfy({ $1.start.x < $0.start.x }) {
            return [.gesture(.trackpadPinkyToIndex)]
        }
        return []
    }

    mutating func reset() {
        session.removeAll()
    }
}

/// Two widely spread fingers moving together draw a character. The stroke follows their
/// midpoint and ends when either finger lifts.
struct DrawingDetector: GestureDetector {
    private var pair: (Int, Int)?
    private var path: [Vector2] = []
    private var isDrawing = false
    private var isDone = false

    var suppressesScroll: Bool { isDrawing }

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        defer {
            if snapshot.active.isEmpty { reset() }
        }
        guard !isDone else { return [] }

        guard let (firstID, secondID) = pair else {
            startIfSpread(snapshot, tuning: tuning, blocked: blocked)
            return []
        }

        let all = snapshot.active + snapshot.lifted
        guard let first = all.first(where: { $0.id == firstID }),
              let second = all.first(where: { $0.id == secondID }),
              snapshot.active.count <= 2
        else {
            isDone = true
            return stopDrawing()
        }

        if path.count >= tuning.maxStrokePoints {
            // Thin the path rather than stop recording: a long drawing keeps its whole
            // shape, at lower resolution, and its memory stays bounded.
            path = stride(from: 0, to: path.count, by: 2).map { path[$0] }
        }
        path.append(midpoint(first, second, aspectRatio: snapshot.aspectRatio))

        if first.upTime != nil || second.upTime != nil {
            isDone = true
            let wasDrawing = isDrawing
            isDrawing = false
            guard wasDrawing, !blocked else { return [] }
            guard length(of: path) >= tuning.minStrokeLength else { return [.strokeCancelled] }
            return [.stroke(path)]
        }

        if !isDrawing, !blocked {
            let a = first.displacement
            let b = second.displacement
            let together = a.x * b.x + a.y * b.y > 0
            isDrawing = together
                && a.magnitude >= tuning.drawStartDistance
                && b.magnitude >= tuning.drawStartDistance
        }
        // Reporting the whole path each frame keeps whatever draws it stateless.
        return isDrawing ? [.strokeProgress(path)] : []
    }

    /// Gives up on a drawing that was already showing on screen.
    private mutating func stopDrawing() -> [TouchEvent] {
        let wasDrawing = isDrawing
        isDrawing = false
        return wasDrawing ? [.strokeCancelled] : []
    }

    private mutating func startIfSpread(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) {
        guard !blocked, snapshot.active.count == 2 else { return }
        let first = snapshot.active[0]
        let second = snapshot.active[1]
        guard abs(first.downTime - second.downTime) <= tuning.simultaneousWindow,
              abs(first.start.x - second.start.x) >= tuning.drawSpread
        else {
            return
        }
        pair = (first.id, second.id)
        let start = Vector2(
            x: (first.start.x + second.start.x) / 2 * snapshot.aspectRatio,
            y: (first.start.y + second.start.y) / 2
        )
        path = [start]
    }

    private func midpoint(_ a: TrackedContact, _ b: TrackedContact, aspectRatio: Double) -> Vector2 {
        Vector2(x: (a.position.x + b.position.x) / 2 * aspectRatio, y: (a.position.y + b.position.y) / 2)
    }

    private func length(of points: [Vector2]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + Vector2(x: pair.1.x - pair.0.x, y: pair.1.y - pair.0.y).magnitude
        }
    }

    mutating func reset() {
        pair = nil
        path = []
        isDrawing = false
        isDone = false
    }
}

/// Three fingers swiping together along the length of a Magic Mouse.
struct ThreeFingerSwipeDetector: GestureDetector {
    private var fired = false
    private(set) var suppressesScroll = false

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        guard !snapshot.active.isEmpty else {
            reset()
            return []
        }
        guard snapshot.active.count == 3, !blocked else {
            suppressesScroll = false
            return []
        }

        let contacts = snapshot.active
        suppressesScroll = contacts.contains { $0.maxDisplacement > tuning.fixTolerance }
        guard !fired else { return [] }

        let travel = mean(contacts.map(\.displacement))
        guard contacts.allSatisfy({ abs($0.displacement.y) >= tuning.swipeDistance }),
              contacts.allSatisfy({ ($0.displacement.y > 0) == (travel.y > 0) }),
              abs(travel.y) >= abs(travel.x) * tuning.dominantAxisRatio
        else {
            return []
        }

        fired = true
        return [.gesture(travel.y < 0 ? .mouseThreeFingerSwipeUp : .mouseThreeFingerSwipeDown)]
    }

    mutating func reset() {
        fired = false
        suppressesScroll = false
    }
}

/// Index and middle fingers held on opposite corners of a Magic Mouse start a window move.
/// Lifting one finger switches to resizing; lifting both ends it.
struct CornerHoldDetector: GestureDetector {
    private var isDragging = false
    private var hasToggled = false

    var suppressesScroll: Bool { false }

    mutating func update(_ snapshot: ContactSnapshot, tuning: TouchTuning, blocked: Bool) -> [TouchEvent] {
        if snapshot.active.isEmpty {
            let wasDragging = isDragging
            reset()
            return wasDragging ? [.dragEnded] : []
        }

        if isDragging {
            guard snapshot.active.count < 2, !hasToggled else { return [] }
            hasToggled = true
            return [.dragToggleMode]
        }

        guard !blocked, snapshot.active.count == 2 else { return [] }
        let first = snapshot.active[0]
        let second = snapshot.active[1]
        let held = [first, second].allSatisfy {
            snapshot.time - $0.downTime >= tuning.cornerHoldDuration && $0.maxDisplacement <= tuning.fixTolerance
        }
        guard held,
              abs(first.position.x - second.position.x) >= tuning.cornerSpread,
              abs(first.position.y - second.position.y) >= tuning.cornerSpread
        else {
            return []
        }

        isDragging = true
        return [.gesture(.mouseCornerHold)]
    }

    mutating func reset() {
        isDragging = false
        hasToggled = false
    }
}
