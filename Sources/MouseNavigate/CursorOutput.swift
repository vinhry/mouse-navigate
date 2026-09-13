import AppKit
import CoreGraphics
import MouseNavigateCore

/// Posts the synthetic pointer events that drive cursor mode.
final class CursorOutput {
    /// Stamped into `eventSourceUserData` on everything we post so the tap can tell our
    /// own events apart from real input and pass them straight through.
    static let syntheticTag: Int64 = 0x4D4E_4156 // "MNAV"

    enum MouseButton {
        case left
        case right
        case middle

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }

        var downType: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        }

        var upType: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        }

        var draggedType: CGEventType {
            switch self {
            case .left: return .leftMouseDragged
            case .right: return .rightMouseDragged
            case .middle: return .otherMouseDragged
            }
        }
    }

    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldButtons: [MouseButton: Int] = [:]
    private var lastClick: (button: MouseButton, time: TimeInterval, location: CGPoint)?

    // MARK: - Position

    var location: Vector2 {
        let point = CGEvent(source: nil)?.location ?? .zero
        return Vector2(x: Double(point.x), y: Double(point.y))
    }

    /// Display rects in CoreGraphics coordinates (origin top-left, +y downwards).
    func screenRects() -> [Rect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }

        return NSScreen.screens.map { screen in
            let frame = screen.frame
            // AppKit's origin is the bottom-left of the primary display with +y up.
            let top = primaryHeight - frame.maxY
            return Rect(
                minX: Double(frame.minX),
                minY: Double(top),
                maxX: Double(frame.maxX) - 1,
                maxY: Double(top + frame.height) - 1
            )
        }
    }

    // MARK: - Movement

    func move(to position: Vector2) {
        let point = CGPoint(x: position.x, y: position.y)

        // While a button is held the system expects drag events, not plain moves —
        // otherwise drag-and-drop never starts.
        let type = heldButtons.keys.first.map { $0.draggedType } ?? .mouseMoved
        let button = heldButtons.keys.first?.cgButton ?? .left

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            return
        }

        post(event)
    }

    // MARK: - Buttons

    func pressButton(_ button: MouseButton) {
        guard heldButtons[button] == nil else { return }

        let point = CGPoint(x: location.x, y: location.y)
        let clickCount = clickCount(for: button, at: point)
        heldButtons[button] = clickCount

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: button.downType,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    func releaseButton(_ button: MouseButton) {
        guard let clickCount = heldButtons.removeValue(forKey: button) else { return }

        let point = CGPoint(x: location.x, y: location.y)
        lastClick = (button, ProcessInfo.processInfo.systemUptime, point)

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: button.upType,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    /// Release everything still held. Called on every exit path so a synthetic button
    /// can never be left stuck down.
    func releaseAllButtons() {
        for button in Array(heldButtons.keys) {
            releaseButton(button)
        }
    }

    var hasHeldButton: Bool { !heldButtons.isEmpty }

    /// Promote a rapid second press at the same spot to a double-click, matching what
    /// a real mouse would report.
    private func clickCount(for button: MouseButton, at point: CGPoint) -> Int {
        guard let lastClick,
              lastClick.button == button,
              ProcessInfo.processInfo.systemUptime - lastClick.time < 0.3,
              abs(lastClick.location.x - point.x) < 5,
              abs(lastClick.location.y - point.y) < 5
        else {
            return 1
        }
        return 2
    }

    // MARK: - Scrolling

    func scroll(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            return
        }
        post(event)
    }

    // MARK: - Posting

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        event.post(tap: .cghidEventTap)
    }
}
