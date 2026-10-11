import CoreGraphics
import Foundation
import MouseNavigateCore

/// Reverses, speeds up and smooths a mouse wheel, with momentum if asked. Only line-based
/// wheel events come here; trackpads and the Magic Mouse scroll continuously and are left
/// to macOS.
@MainActor
final class WheelScroller {
    private var scroller = MomentumScroller(hasMomentum: false)
    private var timer: MainTimer?
    /// Modifiers a wheel option has used up, to keep off the frames posted while smoothing:
    /// the source would otherwise stamp the held ⇧ back on, and AppKit swap the axes again.
    private var consumedFlags: CGEventFlags = []

    private static let frameInterval: TimeInterval = 1.0 / 120

    /// Returns true when the event is swallowed, which it is only while smoothing: the
    /// movement is then sent again, spread over the frames that follow.
    func handle(_ event: CGEvent, settings: ScrollSettings) -> Bool {
        let modified = ScrollTransform.apply(Self.read(event), settings: settings, modifiers: Shortcut.Modifiers(event.flags))
        let delta = modified.delta
        consumedFlags = CGEventFlags(modified.consumedModifiers)
        event.flags.remove(consumedFlags)

        guard settings.isSmooth else {
            Self.write(delta, to: event)
            return false
        }

        // Momentum switched on or off, or a scope with the other setting in front, takes
        // effect from the next scroll rather than half way through this one.
        if scroller.hasMomentum != settings.hasMomentum, scroller.isIdle {
            scroller = MomentumScroller(hasMomentum: settings.hasMomentum)
        }
        scroller.add(
            vertical: delta.points.vertical,
            horizontal: delta.points.horizontal,
            at: ProcessInfo.processInfo.systemUptime
        )
        startTimerIfNeeded()
        return true
    }

    /// Stops at once, closing a gesture or coast that apps have been told has begun.
    func stop() {
        timer = nil
        if let closing = scroller.cancel() {
            post(closing)
        }
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
        timer = MainTimer(after: 0, repeating: WheelScroller.frameInterval, leeway: .milliseconds(1)) { [weak self] in
            self?.frame()
        }
    }

    private func frame() {
        if let next = scroller.frame(at: ProcessInfo.processInfo.systemUptime) {
            post(next)
        }
        if scroller.isIdle {
            timer = nil
        }
    }

    private func post(_ frame: MomentumScroller.Frame) {
        guard let event = SyntheticEvents.scroll(
            verticalPixels: Int32(clamping: frame.vertical),
            horizontalPixels: Int32(clamping: frame.horizontal),
            phase: frame.phase,
            momentum: frame.momentum
        ) else {
            return
        }
        event.flags.remove(consumedFlags)
        SyntheticEvents.post(event)
    }
}
