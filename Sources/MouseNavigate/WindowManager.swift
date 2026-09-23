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
    private var dragTimer: DispatchSourceTimer?

    /// Frames saved before "Maximize Window" so a second use restores them.
    private var framesBeforeZoom: [(window: AXUIElement, frame: Rect)] = []

    var isDragging: Bool { drag != nil }

    // MARK: - Actions

    func minimize() {
        guard let window = focusedWindow() else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    func zoom() {
        guard let window = focusedWindow(), let frame = frame(of: window) else { return }
        let screens = visibleScreenRects()
        guard let index = WindowLayout.screenIndex(for: frame, in: screens) else { return }

        let target = screens[index]
        if frame.approximatelyEquals(target),
           let saved = framesBeforeZoom.lastIndex(where: { CFEqual($0.window, window) }) {
            setFrame(framesBeforeZoom.remove(at: saved).frame, of: window)
            return
        }

        framesBeforeZoom.removeAll { CFEqual($0.window, window) }
        framesBeforeZoom.append((window, frame))
        if framesBeforeZoom.count > 20 {
            framesBeforeZoom.removeFirst()
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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.updateDrag() }
        timer.resume()
        dragTimer = timer
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
        dragTimer?.cancel()
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
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return copyElement(element, kAXFocusedWindowAttribute)
    }

    private func windowUnderCursor() -> AXUIElement? {
        let point = cursorLocation()
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard result == .success, var element = hit else { return nil }

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
        return (value as! AXUIElement)
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
        setPosition(frame, of: window)
        setSize(frame, of: window)
        setPosition(frame, of: window)
    }

    private func setPosition(_ frame: Rect, of window: AXUIElement) {
        var point = CGPoint(x: frame.minX, y: frame.minY)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ frame: Rect, of window: AXUIElement) {
        var size = CGSize(width: frame.width, height: frame.height)
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private func cursorLocation() -> Vector2 {
        let point = CGEvent(source: nil)?.location ?? .zero
        return Vector2(x: Double(point.x), y: Double(point.y))
    }

    /// Visible frames (menu bar and Dock excluded) in CoreGraphics coordinates.
    private func visibleScreenRects() -> [Rect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }

        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            // AppKit's origin is the bottom-left of the primary display with +y up.
            return Rect(
                x: Double(visible.minX),
                y: Double(primaryHeight - visible.maxY),
                width: Double(visible.width),
                height: Double(visible.height)
            )
        }
    }
}
