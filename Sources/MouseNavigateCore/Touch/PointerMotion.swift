import Foundation

/// Whether the pointer has been moving lately, from samples of where it was.
///
/// A finger touching a Magic Mouse while the mouse is pushed about is gripping it, not
/// tapping, so the touch side asks this before believing a tap. Positions are in points
/// on the whole desktop, so a jump from one display to another is just a long distance.
public struct PointerMotion {
    /// How far back the pointer's travel is added up, in seconds.
    public var window = 0.15
    /// Travel over the window, in points, above which the pointer counts as moving. A tap
    /// rocks a Magic Mouse a little; that must stay below it.
    public var threshold = 12.0
    /// A ceiling on the samples kept: frames arrive about a hundred a second, so this is
    /// more than a window holds, and a clock that stops cannot grow the list.
    static let maxSamples = 64

    private var samples: [(time: Double, position: Vector2)] = []

    public init() {}

    /// Notes where the pointer is at `time`, and says whether it has been moving over the
    /// window that ends there.
    @discardableResult
    public mutating func record(time: Double, position: Vector2) -> Bool {
        samples.append((time, position))
        if samples.count > PointerMotion.maxSamples {
            samples.removeFirst(samples.count - PointerMotion.maxSamples)
        }
        // Older samples can never matter again, as time only moves forward.
        let cutoff = time - window
        if let firstInWindow = samples.firstIndex(where: { $0.time >= cutoff }), firstInWindow > 0 {
            samples.removeFirst(firstInWindow)
        }
        return travel > threshold
    }

    /// How far the pointer went over the window ending at the latest sample, in points.
    /// Out and back counts both ways.
    public var travel: Double {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            total + Vector2(x: pair.1.position.x - pair.0.position.x, y: pair.1.position.y - pair.0.position.y).magnitude
        }
    }

    public var isMoving: Bool { travel > threshold }

    public mutating func reset() {
        samples.removeAll()
    }

    var sampleCount: Int { samples.count }
}

