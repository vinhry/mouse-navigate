import CoreGraphics
import Foundation
import MouseNavigateCore

/// Draws characters with the pointer while a mouse button is held.
///
/// The button press is held back until release. A drag long enough to be a drawing is
/// recognized and never reaches the app; anything shorter is replayed as the ordinary click
/// it was, at the spot it began.
@MainActor
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
    /// The ink is redrawn at most this often, about once a display frame, however fast the
    /// mouse reports.
    private static let progressInterval = 0.008

    private struct Capture {
        let button: Button
        let start: CGPoint
        var path: [Vector2]
        var length: Double
    }

    private var capture: Capture?
    /// A redraw of the ink is already on its way.
    private var isProgressPending = false

    var onStroke: (([Vector2]) -> Void)?
    /// The drag so far, for drawing it on screen.
    var onProgress: (([Vector2]) -> Void)?
    /// The drag turned out to be a click, so nothing was drawn after all.
    var onCancelled: (() -> Void)?

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
        scheduleProgress()
        return true
    }

    /// Drags arrive from the event tap, where every click and keystroke waits, and a gaming
    /// mouse sends a thousand of them a second. Drawing is left until the event has been
    /// answered, and the drags that come in the meantime are drawn together.
    private func scheduleProgress() {
        guard !isProgressPending else { return }
        isProgressPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + StrokeCapture.progressInterval) { [weak self] in
            guard let self else { return }
            self.isProgressPending = false
            // Released or cancelled meanwhile: the result or the cancel has the ink now.
            guard let current = self.capture else { return }
            self.onProgress?(current.path)
        }
    }

    func handleUp(_ button: Button, at location: CGPoint) -> Bool {
        guard let current = capture, current.button == button else { return false }
        capture = nil

        if current.length >= StrokeCapture.minimumLength {
            let path = current.path + [vector(location)]
            // Recognised and acted on once the release has been answered. The ink is brought
            // up to date first: a stroke quicker than one redraw has no window yet to show
            // its result in.
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(path)
                self?.onStroke?(path)
            }
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
        guard let event = SyntheticEvents.mouse(
            type, at: location, button: button.cgButton, buttonNumber: button == .middle ? 2 : nil
        ) else {
            return
        }
        SyntheticEvents.post(event)
    }

    private func vector(_ point: CGPoint) -> Vector2 {
        Vector2(x: Double(point.x), y: Double(point.y))
    }
}
