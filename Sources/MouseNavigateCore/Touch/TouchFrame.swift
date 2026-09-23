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

    public init(id: Int, position: Vector2, size: Double = 0) {
        self.id = id
        self.position = position
        self.size = size
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
    public var nearTapDistance = 0.3
    public var swipeDistance = 0.15
    public var cornerHoldDuration = 0.4
    public var cornerSpread = 0.35
    /// Fingers resting nearer the user's edge of a trackpad than this are taken for a
    /// resting thumb, which must not turn ordinary taps and scrolls into gestures.
    public var thumbZone = 0.85
    /// Fingers working beside a resting finger stay roughly level with it.
    public var neighbourMaxOffset = 0.3
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
    public let start: Vector2
    public var position: Vector2
    /// Furthest the finger has strayed from where it landed.
    public var maxDisplacement: Double
    public var upTime: Double?

    public var displacement: Vector2 {
        Vector2(x: position.x - start.x, y: position.y - start.y)
    }

    public func isFixed(at time: Double, tuning: TouchTuning) -> Bool {
        upTime == nil && time - downTime >= tuning.fixDuration && maxDisplacement <= tuning.fixTolerance
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
public struct ContactTracker {
    private var contacts: [Int: TrackedContact] = [:]

    public init() {}

    public mutating func update(_ frame: TouchFrame) -> ContactSnapshot {
        let time = frame.timestamp
        var landed: [TrackedContact] = []
        var seen = Set<Int>()

        for contact in frame.contacts {
            seen.insert(contact.id)
            if var tracked = contacts[contact.id] {
                tracked.position = contact.position
                let offset = tracked.displacement
                tracked.maxDisplacement = max(tracked.maxDisplacement, offset.magnitude)
                contacts[contact.id] = tracked
            } else {
                let tracked = TrackedContact(
                    id: contact.id,
                    downTime: time,
                    start: contact.position,
                    position: contact.position,
                    maxDisplacement: 0,
                    upTime: nil
                )
                contacts[contact.id] = tracked
                landed.append(tracked)
            }
        }

        var lifted: [TrackedContact] = []
        for (id, var tracked) in contacts where !seen.contains(id) {
            tracked.upTime = time
            lifted.append(tracked)
            contacts.removeValue(forKey: id)
        }

        return ContactSnapshot(
            time: time,
            active: contacts.values.sorted { $0.position.x < $1.position.x },
            landed: landed,
            lifted: lifted.sorted { $0.position.x < $1.position.x },
            isPrimaryButtonDown: frame.isPrimaryButtonDown,
            aspectRatio: frame.aspectRatio
        )
    }

    public mutating func reset() {
        contacts.removeAll()
    }
}
