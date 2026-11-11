import Foundation

/// Whether MouseNavigate is paused from the menu bar, and until when.
///
/// The end is a wall-clock date rather than a countdown: a timer does not run while the Mac
/// sleeps, so an hour set before closing the lid would otherwise outlast the night. Whoever
/// owns this feeds it `tick` from a timer and again on waking, and it ends the pause once
/// the date has passed.
public struct PauseState: Equatable {
    public enum Status: Equatable {
        case running
        case pausedIndefinitely
        case paused(until: Date)
    }

    public enum Event: Equatable {
        case pause
        case pauseFor(TimeInterval, now: Date)
        case resume
        case tick(now: Date)
    }

    public private(set) var status: Status = .running

    public init() {}

    public var isPaused: Bool { status != .running }

    /// When a timed pause ends, or nil when running or paused with no end.
    public var resumeDate: Date? {
        if case .paused(let date) = status { return date }
        return nil
    }

    /// Applies the event, and says whether the status changed.
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        let before = status
        switch event {
        case .pause:
            // Pausing by hand during a timed pause means "until I say", not "until then".
            status = .pausedIndefinitely
        case .pauseFor(let seconds, let now):
            status = .paused(until: now.addingTimeInterval(seconds))
        case .resume:
            status = .running
        case .tick(let now):
            if case .paused(let date) = status, now >= date {
                status = .running
            }
        }
        return status != before
    }
}
