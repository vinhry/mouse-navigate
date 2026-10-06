import AppKit
import MouseNavigateCore

/// A mode inside cursor mode that takes the keyboard for a moment: the grid and the click
/// hints. The engine hands it every key-down until it says it is done. Main thread only.
protocol CursorModal: AnyObject {
    /// Asks the engine to close the mode, for one that finishes on its own.
    var onFinish: (() -> Void)? { get set }

    func keyDown(_ keyCode: UInt16, flags: CGEventFlags) -> CursorModalResult
    /// Takes down whatever the mode shows. Called exactly once, however the mode ends.
    func close()
}

enum CursorModalResult {
    /// The mode used the key.
    case consume
    /// The mode is done, and used the key.
    case finish
    /// The mode is done, and the key belongs to cursor mode: a click key clicks where the
    /// pointer has been brought.
    case finishAndForward
}

/// Borderless windows over every display that draw above everything and never take focus
/// or clicks. Drawing happens in CoreGraphics global points, +y down, whichever display it
/// lands on. Created when shown and released when hidden, so nothing lingers between uses.
final class ScreenOverlay {
    /// Called for each display with its frame in global points; the context is already
    /// translated so global points can be drawn as they are.
    var draw: ((CGRect) -> Void)?

    private var panels: [NSPanel] = []

    func show() {
        hide()
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // Above menus and the Dock, so hints can reach what is shown there too.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.setFrame(screen.frame, display: false)

            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.globalFrame = ScreenOverlay.globalFrame(of: screen)
            view.overlay = self
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func redraw() {
        for panel in panels {
            panel.contentView?.needsDisplay = true
        }
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    /// A display's frame in CoreGraphics global points: origin at the top left of the
    /// primary display, +y down, where AppKit has it at the bottom left, +y up. The
    /// visible frame leaves out the menu bar and the Dock.
    static func globalFrame(of screen: NSScreen, visibleOnly: Bool = false) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = visibleOnly ? screen.visibleFrame : screen.frame
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Every display, left to right, which is the order the digit keys pick them in.
    static func displayFrames() -> [CGRect] {
        NSScreen.screens.map { globalFrame(of: $0) }.sorted {
            $0.minX == $1.minX ? $0.minY < $1.minY : $0.minX < $1.minX
        }
    }

    /// A label on a rounded plate, its top left at `origin` unless that would run off
    /// `bounds`.
    static func drawBadge(
        _ text: NSAttributedString,
        at origin: CGPoint,
        within bounds: CGRect,
        fill: NSColor,
        padding: CGSize = CGSize(width: 4, height: 1)
    ) {
        let size = text.size()
        var rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: ceil(size.width) + padding.width * 2,
            height: ceil(size.height) + padding.height * 2
        )
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)

        let plate = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        fill.setFill()
        plate.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        plate.lineWidth = 0.5
        plate.stroke()
        text.draw(at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height))
    }
}

private final class OverlayView: NSView {
    var globalFrame: CGRect = .zero
    weak var overlay: ScreenOverlay?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: -globalFrame.minX, y: -globalFrame.minY)
        overlay?.draw?(globalFrame)
        context.restoreGState()
    }
}
