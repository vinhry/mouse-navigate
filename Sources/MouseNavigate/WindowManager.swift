import AppKit
import ApplicationServices
import MouseNavigateCore

/// Moves, resizes, minimizes and tiles other apps' windows through the Accessibility API,
/// which the app already holds permission for. Main thread only.
final class WindowManager {
    enum DragMode {
        case move
        case resize
    }

    private struct DragSession {
        let window: AXUIElement
        var mode: DragMode
        var anchorCursor: Vector2
        var anchorFrame: Rect
    }

    private var drag: DragSession?
    private var dragTimer: MainTimer?

    /// Frames saved before "Maximize Window" so a second use restores them.
    private var zoomHistory = ZoomHistory<AXUIElement> { CFEqual($0, $1) }

    /// How long one Accessibility request may wait on the other app. The actions run inside
    /// the event tap's callback, and a hung app must not take every keystroke on the Mac
    /// down with it for the several seconds the system would otherwise allow.
    private static let messagingTimeout: Float = 0.25

    // MARK: - Actions

    func minimize() {
        guard let window = focusedWindow() else { return }
        report(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue), "Minimizing the window")
    }

    func zoom() {
        guard let window = focusedWindow(), let frame = frame(of: window),
              let target = zoomHistory.zoom(window, from: frame, screens: visibleScreenRects())
        else {
            return
        }
        setFrame(target, of: window)
    }

    func maximize(_ side: WindowLayout.Side) {
        guard let window = focusedWindow(), let frame = frame(of: window),
              let target = WindowLayout.halfTarget(side, window: frame, screens: visibleScreenRects())
        else {
            return
        }
        setFrame(target, of: window)
    }

    // MARK: - Move / resize

    /// Starts dragging the window under the pointer. From then on it follows the pointer,
    /// whichever device is moving it, until `endDrag()`.
    func beginDrag(mode: DragMode = .move) {
        endDrag()
        guard let window = windowUnderCursor() ?? focusedWindow(), let frame = frame(of: window) else {
            return
        }

        drag = DragSession(window: window, mode: mode, anchorCursor: cursorLocation(), anchorFrame: frame)

        dragTimer = MainTimer(after: 0, repeating: 0.016) { [weak self] in
            self?.updateDrag()
        }
    }

    /// Switches between moving and resizing, re-anchoring so the window does not jump.
    func toggleDragMode() {
        guard var session = drag, let frame = frame(of: session.window) else { return }
        session.mode = session.mode == .move ? .resize : .move
        session.anchorCursor = cursorLocation()
        session.anchorFrame = frame
        drag = session
    }

    func endDrag() {
        dragTimer = nil
        drag = nil
    }

    private func updateDrag() {
        guard let session = drag else { return }

        let cursor = cursorLocation()
        let delta = Vector2(x: cursor.x - session.anchorCursor.x, y: cursor.y - session.anchorCursor.y)
        switch session.mode {
        case .move:
            setPosition(WindowLayout.moved(session.anchorFrame, by: delta), of: session.window)
        case .resize:
            setSize(WindowLayout.resized(session.anchorFrame, by: delta), of: session.window)
        }
    }

    // MARK: - Accessibility helpers

    private func focusedWindow() -> AXUIElement? {
        guard let pid = FrontmostApp.shared.processIdentifier else { return nil }
        let app = bounded(AXUIElementCreateApplication(pid))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            report(error == .success ? .noValue : error, "Finding the focused window")
            return nil
        }
        return bounded(value as! AXUIElement)
    }

    /// A window action that did nothing says why in the log: an app that is busy (a
    /// timeout), one that keeps no windows Accessibility can reach, or one that refuses to
    /// be moved. The drag, which sets the frame every frame, does not report.
    private func report(_ error: AXError, _ attempt: String) {
        guard error != .success else { return }
        let app = FrontmostApp.shared.bundleID ?? "the app in front"
        Log.actions.notice("\(attempt, privacy: .public) in \(app, privacy: .public) failed: AXError \(error.rawValue).")
    }

    /// The element with the request timeout applied. Every element the actions touch goes
    /// through here: the timeout is per element, not per app.
    private func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, WindowManager.messagingTimeout)
        return element
    }

    private func windowUnderCursor() -> AXUIElement? {
        let point = cursorLocation()
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            bounded(AXUIElementCreateSystemWide()),
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard result == .success, var element = hit.map(bounded) else { return nil }

        if let window = copyElement(element, kAXWindowAttribute) {
            return window
        }
        // Not every element exposes its window, so climb the hierarchy instead.
        for _ in 0..<32 {
            if role(of: element) == kAXWindowRole {
                return element
            }
            guard let parent = copyElement(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        return nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return bounded(value as! AXUIElement)
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func frame(of window: AXUIElement) -> Rect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return Rect(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }

    private func setFrame(_ frame: Rect, of window: AXUIElement) {
        // Position, size, then position again: a window being grown near a screen edge can be
        // pushed back by the system before its new size lands.
        let results = [
            setPosition(frame, of: window),
            setSize(frame, of: window),
            setPosition(frame, of: window),
        ]
        if let failure = results.first(where: { $0 != .success }) {
            report(failure, "Moving or resizing the window")
        }
    }

    @discardableResult
    private func setPosition(_ frame: Rect, of window: AXUIElement) -> AXError {
        var point = CGPoint(x: frame.minX, y: frame.minY)
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    private func setSize(_ frame: Rect, of window: AXUIElement) -> AXError {
        var size = CGSize(width: frame.width, height: frame.height)
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private func cursorLocation() -> Vector2 {
        let point = CGEvent(source: nil)?.location ?? .zero
        return Vector2(x: Double(point.x), y: Double(point.y))
    }

    /// Visible frames (menu bar and Dock excluded) in CoreGraphics coordinates.
    private func visibleScreenRects() -> [Rect] {
        NSScreen.screens.map { Rect(ScreenOverlay.globalFrame(of: $0, visibleOnly: true)) }
    }
}
