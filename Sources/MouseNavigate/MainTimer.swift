import Foundation

/// A timer whose handler runs on the main queue, beside the event tap, and which stops when
/// cancelled or let go of.
final class MainTimer {
    private let source: DispatchSourceTimer

    /// Fires once after `delay`, and then every `interval` when one is given.
    init(
        after delay: TimeInterval,
        repeating interval: DispatchTimeInterval? = nil,
        leeway: DispatchTimeInterval = .nanoseconds(0),
        handler: @escaping () -> Void
    ) {
        source = DispatchSource.makeTimerSource(queue: .main)
        if let interval {
            source.schedule(deadline: .now() + delay, repeating: interval, leeway: leeway)
        } else {
            source.schedule(deadline: .now() + delay, leeway: leeway)
        }
        source.setEventHandler(handler: handler)
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
