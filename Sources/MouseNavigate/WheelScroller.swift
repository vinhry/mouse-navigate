import CoreGraphics
import Foundation
import MouseNavigateCore

/// Reverses, speeds up and smooths a mouse wheel. Only line-based wheel events come here;
/// trackpads and the Magic Mouse scroll continuously and are left to macOS.
final class WheelScroller {
    private var smoother = ScrollSmoother()
    private var timer: DispatchSourceTimer?
    private var lastFrame: TimeInterval = 0

    private static let frameInterval: TimeInterval = 1.0 / 120

    /// Returns true when the event is swallowed, which it is only while smoothing: the
    /// movement is then sent again, spread over the frames that follow.
    func handle(_ event: CGEvent, settings: ScrollSettings) -> Bool {
        let delta = ScrollTransform.apply(Self.read(event), settings: settings)

        guard settings.isSmooth else {
            Self.write(delta, to: event)
            return false
        }

        smoother.add(vertical: delta.points.vertical, horizontal: delta.points.horizontal)
        startTimerIfNeeded()
        return true
    }

    func stop() {
        timer?.cancel()
        timer = nil
        smoother.stop()
    }

    // MARK: - Event fields

    private static func read(_ event: CGEvent) -> ScrollDelta {
        ScrollDelta(
            lines: (
                Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            ),
            fixedLines: (
                event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            ),
            points: (
                Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            )
        )
    }

    /// Whole lines first: setting them makes CoreGraphics recompute the other two forms,
    /// which are then overwritten with the values meant for them.
    private static func write(_ delta: ScrollDelta, to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(delta.lines.vertical))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(delta.lines.horizontal))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta.fixedLines.vertical)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: delta.fixedLines.horizontal)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta.points.vertical.rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(delta.points.horizontal.rounded()))
    }

    // MARK: - Smoothing

    private func startTimerIfNeeded() {
        guard timer == nil else { return }

        lastFrame = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: WheelScroller.frameInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.frame()
        }
        timer.resume()
        self.timer = timer
    }

    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let step = smoother.step(elapsed: now - lastFrame)
        lastFrame = now

        if step.vertical != 0 || step.horizontal != 0 {
            postPixels(vertical: step.vertical, horizontal: step.horizontal)
        }
        if smoother.isIdle {
            timer?.cancel()
            timer = nil
        }
    }

    /// Pixel units make the event continuous, as a trackpad's are, which apps scroll by the
    /// exact amount rather than by lines.
    private func postPixels(vertical: Int, horizontal: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: vertical),
            wheel2: Int32(clamping: horizontal),
            wheel3: 0
        ) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        event.post(tap: .cghidEventTap)
    }
}
