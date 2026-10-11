import CoreGraphics
import Foundation

/// The events MouseNavigate posts itself: one source, one tag, one place to post from.
///
/// Every synthetic event carries the tag in its user data so the event tap passes it
/// straight through rather than feeding it back into the state machines. Posting never
/// touches `flags`: the source stamps in whatever modifiers are down, and each caller
/// knows whether that is right (a shortcut), wrong (a cursor-mode click while Shift is
/// held for speed) or something to replay (a withheld letter).
enum SyntheticEvents {
    static let tag: Int64 = 0x4D4E_4156 // "MNAV"
    /// Made once and never changed; events are only ever created from it.
    nonisolated(unsafe) static let source = CGEventSource(stateID: .hidSystemState)

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == tag
    }

    static func mouse(
        _ type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        buttonNumber: Int? = nil,
        clickState: Int = 1
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            return nil
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if let buttonNumber {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
        }
        return event
    }

    /// Pixel units make the event continuous, as a trackpad's are, which apps scroll by
    /// the exact amount rather than by lines.
    static func scroll(verticalPixels: Int32, horizontalPixels: Int32) -> CGEvent? {
        CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: verticalPixels,
            wheel2: horizontalPixels,
            wheel3: 0
        )
    }

    static func key(_ keyCode: CGKeyCode, down: Bool) -> CGEvent? {
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
    }

    /// Marks the event as ours without posting it, for the one caller that posts through
    /// the tap proxy to keep its place in the stream.
    static func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: tag)
    }

    static func post(_ event: CGEvent) {
        stamp(event)
        event.post(tap: .cghidEventTap)
    }
}
