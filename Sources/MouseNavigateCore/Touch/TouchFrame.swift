import Foundation

public enum TouchSurface: String, CaseIterable {
    case trackpad
    case magicMouse

    public var displayName: String {
        switch self {
        case .trackpad: return "Trackpad"
        case .magicMouse: return "Magic Mouse"
        }
    }
}

/// One finger on a multitouch surface.
public struct TouchContact: Equatable {
    public var id: Int
    /// Normalized to 0...1 on both axes, with +y towards the user: 0 is the far edge of a
    /// trackpad or the front of a Magic Mouse, 1 the edge nearest the user.
    public var position: Vector2
    public var size: Double
    /// MultitouchSupport's finger state: 1 and 2 are coming into range and hovering, 3 and
    /// 4 making and holding touch, 5 breaking it, 6 and 7 lingering and leaving.
    public var state: Int

    public static let touchingStates: ClosedRange<Int> = 3...4

    public var isTouching: Bool { TouchContact.touchingStates.contains(state) }

    public init(id: Int, position: Vector2, size: Double = 0, state: Int = 4) {
        self.id = id
        self.position = position
        self.size = size
        self.state = state
    }
}

/// Everything a surface reported at one instant.
public struct TouchFrame: Equatable {
    public var timestamp: Double
    public var contacts: [TouchContact]
    /// Whether the physical button is held, which turns some trackpad slides into their
    /// "click" variants.
    public var isPrimaryButtonDown: Bool
    /// Physical width over height, so drawn strokes keep their shape.
    public var aspectRatio: Double

    public init(
        timestamp: Double,
        contacts: [TouchContact],
        isPrimaryButtonDown: Bool = false,
        aspectRatio: Double = 1
    ) {
        self.timestamp = timestamp
        self.contacts = contacts
        self.isPrimaryButtonDown = isPrimaryButtonDown
        self.aspectRatio = aspectRatio
    }

    /// Flips left and right, so gestures defined for the right hand work for the left.
    public func mirrored() -> TouchFrame {
        var copy = self
        copy.contacts = contacts.map { contact in
            var flipped = contact
            flipped.position.x = 1 - contact.position.x
            return flipped
        }
        return copy
    }
}

/// Thresholds for gesture recognition, in seconds and normalized surface units.
public struct TouchTuning: Equatable {
    /// A finger counts as resting once it has been down this long without drifting.
    public var fixDuration = 0.12
    public var fixTolerance = 0.03
    /// How far a resting finger may have strayed since it came to rest and still anchor a
    /// gesture. Tapping on a Magic Mouse rocks it, and the resting finger with it.
    public var restTolerance = 0.06
    /// A finger that stays within `fixTolerance` for this long has come to rest where it
    /// is: its movement is measured from there on. Fingers resting on a Magic Mouse drift
    /// as the mouse moves, and without this they would stop counting as resting.
    public var settleDuration = 0.3
    public var tapMaxDuration = 0.22
    public var tapTolerance = 0.03
    /// Fingers landing within this window count as landing together.
    public var simultaneousWindow = 0.1
    public var slideDistance = 0.12
    /// The main axis of a slide must be this many times the other.
    public var dominantAxisRatio = 2.0
    public var doubleTapWindow = 0.35
    public var sequenceMinGap = 0.02
    public var sequenceMaxSpan = 0.8
    public var releaseTogetherWindow = 0.15
    /// On a Magic Mouse, an index tap closer than this to the resting middle finger is "near".
    /// Index and middle rest about half the mouse's width apart, and a tap made there is
    /// near; far means reaching out towards the edge.
    public var nearTapDistance = 0.6
    /// A Magic Mouse loses a finger for a frame or two at a time: a lightly resting or
    /// sliding one drops out, and a light tap bounces between touching and hovering. A
    /// contact that vanishes is kept for this long, and one that comes back within
    /// `mouseReviveDistance` of it carries on as the same finger; only a longer absence is
    /// a lift. Mouse taps are reported this much later.
    public var mouseLiftGrace = 0.05
    public var mouseReviveDistance = 0.12
    /// Taps closer together than this are one tap still bouncing; no hand taps that fast.
    public var tapRefractory = 0.1
    public var swipeDistance = 0.15
    public var cornerHoldDuration = 0.4
    public var cornerSpread = 0.35
    /// Fingers resting nearer the user's edge of a trackpad than this are taken for a
    /// resting thumb, which must not turn ordinary taps and scrolls into gestures.
    public var thumbZone = 0.85
    /// Fingers working beside a resting finger stay roughly level with it.
    public var neighbourMaxOffset = 0.3
    /// On a Magic Mouse, a contact nearer the user than this while other fingers are down
    /// is the palm resting on the back of the mouse, not a finger.
    public var mousePalmZone = 0.7
    /// A Magic Mouse contact hugging the left or right edge and smaller than this is the
    /// side of the hand, not a finger.
    public var mouseEdgeContactSize = 0.375
    /// Two fingers at least this far apart draw instead of scrolling, as a fraction of the
    /// surface's width.
    public var drawSpread = 0.3

    public var drawStartDistance = 0.03
    /// Shortest stroke worth recognizing, in surface heights.
    public var minStrokeLength = 0.25
    /// A ceiling on the points kept for one drawing; beyond it the path is thinned by half,
    /// keeping its shape. The recognizer resamples to 64, so detail beyond this is never
    /// missed, and a finger left moving cannot allocate forever.
    public var maxStrokePoints = 600
    /// How much nearer the rear the index must be than the middle finger for a Magic Mouse
    /// click to become a middle click.
    public var middleClickOffset = 0.08

    public init() {}

    /// How far apart the drawing fingers may be asked to be: from touching neighbours to
    /// index and pinky spread across the pad.
    public static let drawSpreadRange: ClosedRange<Double> = 0.12...0.6

    public static func clampDrawSpread(_ value: Double) -> Double {
        min(max(value, drawSpreadRange.lowerBound), drawSpreadRange.upperBound)
    }
}

/// What a recognizer reports back.
public enum TouchEvent: Equatable {
    case gesture(TouchGesture)
    /// Switch a running move/resize between moving and resizing.
    case dragToggleMode
    case dragEnded
    /// A finished drawing, in surface units with +y down, ready for `StrokeRecognizer`.
    case stroke([Vector2])
    /// The drawing so far, in the same units, for showing it on screen as it happens.
    case strokeProgress([Vector2])
    /// A drawing that came to nothing: interrupted, or too short to recognise.
    case strokeCancelled
}

// MARK: - Contact tracking

/// A contact's history over one touch.
public struct TrackedContact: Equatable {
    public let id: Int
    public let downTime: Double
    /// Where the finger landed, or where it last came to rest (see `TouchTuning.settleDuration`).
    public internal(set) var start: Vector2
    /// When `start` was last set.
    public internal(set) var restTime: Double
    /// Where the finger was when it last moved more than the tolerance, and when: the
    /// stillness that makes a new rest position is measured from here.
    var settleAnchor: Vector2
    var settleTime: Double
    public var position: Vector2
    /// Furthest the finger has strayed from `start`.
    public var maxDisplacement: Double
    public var upTime: Double?

    public var displacement: Vector2 {
        Vector2(x: position.x - start.x, y: position.y - start.y)
    }

    /// Down long enough, and not strayed further than `tolerance` from where it rests. A
    /// trackpad finger must be quite still; a Magic Mouse one is allowed `restTolerance`,
    /// since tapping rocks the mouse.
    public func isFixed(at time: Double, tuning: TouchTuning, tolerance: Double? = nil) -> Bool {
        upTime == nil && time - downTime >= tuning.fixDuration
            && maxDisplacement <= (tolerance ?? tuning.fixTolerance)
    }

    public func isTap(tuning: TouchTuning) -> Bool {
        guard let upTime else { return false }
        return upTime - downTime <= tuning.tapMaxDuration && maxDisplacement <= tuning.tapTolerance
    }
}

/// The state of a surface after one frame, with what changed.
public struct ContactSnapshot {
    public let time: Double
    /// Fingers still down, left to right.
    public let active: [TrackedContact]
    public let landed: [TrackedContact]
    public let lifted: [TrackedContact]
    public let isPrimaryButtonDown: Bool
    public let aspectRatio: Double

    /// The last finger just lifted.
    public var sessionEnded: Bool { active.isEmpty && !lifted.isEmpty }

    public func active(_ id: Int) -> TrackedContact? {
        active.first { $0.id == id }
    }
}

/// Turns raw frames into landings, lifts and per-finger histories.
///
/// With a lift grace, a contact that drops out of a frame is not lifted at once: it stays
/// active where it was, and a contact reported again within the grace, under the same id or
/// a new one close by, carries on as the same finger. Only one that stays away for the whole
/// grace is lifted, as of the moment it vanished.
public struct ContactTracker {
    private var contacts: [Int: TrackedContact] = [:]
    /// Contacts that have dropped out and may yet come back, with the time they vanished.
    private var missing: [Int: (contact: TrackedContact, since: Double)] = [:]
    /// Raw ids standing in for a contact that came back under a new id.
    private var aliases: [Int: Int] = [:]

    public init() {}

    public mutating func update(
        _ frame: TouchFrame,
        tuning: TouchTuning = TouchTuning(),
        liftGrace: Double = 0
    ) -> ContactSnapshot {
        let time = frame.timestamp
        var landed: [TrackedContact] = []
        var seen = Set<Int>()

        for contact in frame.contacts {
            let id = aliases[contact.id] ?? contact.id
            seen.insert(id)
            if var tracked = contacts[id] ?? revive(id, near: contact.position, rawID: contact.id, tuning: tuning) {
                seen.insert(tracked.id)
                tracked.position = contact.position
                let offset = tracked.displacement
                tracked.maxDisplacement = max(tracked.maxDisplacement, offset.magnitude)
                // A finger that has stayed put has come to rest here, wherever here is.
                // Measuring from here on lets slow drift pass, while a deliberate movement,
                // which covers far more than the tolerance within the window, keeps
                // restarting the window and is never rebased mid-way.
                let shift = Vector2(
                    x: contact.position.x - tracked.settleAnchor.x,
                    y: contact.position.y - tracked.settleAnchor.y
                )
                if shift.magnitude > tuning.fixTolerance {
                    tracked.settleAnchor = contact.position
                    tracked.settleTime = time
                } else if time - tracked.settleTime >= tuning.settleDuration {
                    tracked.start = contact.position
                    tracked.restTime = time
                    tracked.maxDisplacement = 0
                    tracked.settleAnchor = contact.position
                    tracked.settleTime = time
                }
                contacts[tracked.id] = tracked
            } else {
                let tracked = TrackedContact(
                    id: contact.id,
                    downTime: time,
                    start: contact.position,
                    restTime: time,
                    settleAnchor: contact.position,
                    settleTime: time,
                    position: contact.position,
                    maxDisplacement: 0,
                    upTime: nil
                )
                contacts[contact.id] = tracked
                landed.append(tracked)
            }
        }

        var lifted: [TrackedContact] = []
        for (id, tracked) in contacts where !seen.contains(id) {
            contacts.removeValue(forKey: id)
            if liftGrace > 0 {
                missing[id] = (tracked, time)
            } else {
                var gone = tracked
                gone.upTime = time
                lifted.append(gone)
            }
        }
        for (id, entry) in missing where time - entry.since >= liftGrace {
            var gone = entry.contact
            gone.upTime = entry.since
            lifted.append(gone)
            missing.removeValue(forKey: id)
            aliases = aliases.filter { $0.value != id }
        }

        let active = Array(contacts.values) + missing.values.map(\.contact)
        return ContactSnapshot(
            time: time,
            active: active.sorted { $0.position.x < $1.position.x },
            landed: landed,
            lifted: lifted.sorted { $0.position.x < $1.position.x },
            isPrimaryButtonDown: frame.isPrimaryButtonDown,
            aspectRatio: frame.aspectRatio
        )
    }

    /// A missing contact that a reported one continues: the same id, or a new id close to
    /// where a finger was last seen. Taken out of the missing set.
    private mutating func revive(_ id: Int, near position: Vector2, rawID: Int, tuning: TouchTuning) -> TrackedContact? {
        if let entry = missing.removeValue(forKey: id) {
            return entry.contact
        }
        guard aliases[rawID] == nil else { return nil }
        let nearest = missing.min { lhs, rhs in
            distance(lhs.value.contact.position, position) < distance(rhs.value.contact.position, position)
        }
        guard let nearest, distance(nearest.value.contact.position, position) <= tuning.mouseReviveDistance else {
            return nil
        }
        missing.removeValue(forKey: nearest.key)
        aliases[rawID] = nearest.key
        return nearest.value.contact
    }

    private func distance(_ a: Vector2, _ b: Vector2) -> Double {
        Vector2(x: a.x - b.x, y: a.y - b.y).magnitude
    }

    public mutating func reset() {
        contacts.removeAll()
        missing.removeAll()
        aliases.removeAll()
    }
}
