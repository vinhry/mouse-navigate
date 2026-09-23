import CoreGraphics
import Foundation
import MouseNavigateCore

/// Draws characters with the pointer while a mouse button is held.
///
/// The button press is held back until release. A drag long enough to be a drawing is
/// recognized and never reaches the app; anything shorter is replayed as the ordinary click
/// it was, at the spot it began.
final class StrokeCapture {
    enum Button {
        case right
        case middle

        var cgButton: CGMouseButton {
            switch self {
            case .right: return .right
            case .middle: return .center
            }
        }

        var downType: CGEventType {
            self == .right ? .rightMouseDown : .otherMouseDown
        }

        var upType: CGEventType {
            self == .right ? .rightMouseUp : .otherMouseUp
        }
    }

    /// Pointer travel, in points, that separates a drawing from a click.
    private static let minimumLength = 40.0
    /// A ceiling on the points kept for one drag; beyond it the path is thinned.
    private static let maximumPoints = 600

    private struct Capture {
        let button: Button
        let start: CGPoint
        var path: [Vector2]
        var length: Double
    }

    private var capture: Capture?

    var onStroke: (([Vector2]) -> Void)?
    /// The drag so far, for drawing it on screen.
    var onProgress: (([Vector2]) -> Void)?
    /// The drag turned out to be a click, so nothing was drawn after all.
    var onCancelled: (() -> Void)?

    var isCapturing: Bool { capture != nil }

    /// Returns true when the event was taken and must not reach the app.
    func handleDown(_ button: Button, at location: CGPoint) -> Bool {
        guard capture == nil else { return false }
        capture = Capture(button: button, start: location, path: [vector(location)], length: 0)
        return true
    }

    func handleDragged(_ button: Button, at location: CGPoint) -> Bool {
        guard var current = capture, current.button == button else { return false }

        let point = vector(location)
        if let last = current.path.last {
            current.length += Vector2(x: point.x - last.x, y: point.y - last.y).magnitude
        }
        if current.path.count >= StrokeCapture.maximumPoints {
            // Thinned rather than cut short, so a long drag keeps its shape.
            current.path = stride(from: 0, to: current.path.count, by: 2).map { current.path[$0] }
        }
        current.path.append(point)
        capture = current
        onProgress?(current.path)
        return true
    }

    func handleUp(_ button: Button, at location: CGPoint) -> Bool {
        guard let current = capture, current.button == button else { return false }
        capture = nil

        if current.length >= StrokeCapture.minimumLength {
            onStroke?(current.path + [vector(location)])
        } else {
            onCancelled?()
            replayClick(current.button, at: current.start)
        }
        return true
    }

    /// Hands a held-back press to the app, so pausing mid-drag never swallows a click.
    func cancel() {
        guard let current = capture else { return }
        capture = nil
        onCancelled?()
        post(current.button.downType, button: current.button, at: current.start)
    }

    private func replayClick(_ button: Button, at location: CGPoint) {
        post(button.downType, button: button, at: location)
        post(button.upType, button: button, at: location)
    }

    private func post(_ type: CGEventType, button: Button, at location: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button.cgButton
        ) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        if button == .middle {
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        event.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        event.post(tap: .cghidEventTap)
    }

    private func vector(_ point: CGPoint) -> Vector2 {
        Vector2(x: Double(point.x), y: Double(point.y))
    }
}
