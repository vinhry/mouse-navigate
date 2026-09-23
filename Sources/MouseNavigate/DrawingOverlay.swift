import AppKit
import MouseNavigateCore
import QuartzCore

/// Draws the stroke being made, so a character gesture can be seen as it happens, and
/// flashes what it turned out to be.
///
/// There is no card or panel behind it. The ink is jitouch's: translucent dark red, thick,
/// with round ends and nothing underneath it. The window never takes focus or clicks. Main
/// thread only.
final class DrawingOverlay {
    /// Where a stroke's points live.
    enum Space: Equatable {
        /// Surface units: x in `0...aspectRatio`, y in `0...1` pointing down. Drawn centred
        /// on the screen under the pointer, in the surface's own proportions.
        case surface(aspectRatio: Double)
        /// CoreGraphics global points, drawn where they were made.
        case screen
    }

    /// jitouch's trail colour, shared with anything else that shows a stroke.
    static let inkColor = NSColor(srgbRed: 0.7, green: 0, blue: 0, alpha: 0.6)
    /// A lighter take on it, for text and for small previews.
    static let textColor = NSColor(srgbRed: 0.87, green: 0.18, blue: 0.18, alpha: 1)

    /// Width of the surface drawing; its height follows the surface's proportions.
    private static let surfaceWidth: CGFloat = 260
    /// How close the drawing may come to the edge of the screen.
    private static let screenMargin: CGFloat = 8
    /// The window the result is shown in, centred on the screen. Big enough for the largest
    /// letter over the longest action name.
    private static let resultSize = CGSize(width: 520, height: 200)
    private static let holdDuration = 0.5
    private static let fadeDuration = 0.25

    private var panel: NSPanel?
    private var canvas: OverlayCanvas?
    private var pendingFade: DispatchWorkItem?
    /// Where the current stroke is being drawn, in screen-local points. Taken once when the
    /// stroke starts, so a pointer that moves cannot drag the ink along with it.
    private var strokeAnchor: CGPoint?
    private var canvasScale: CGFloat = 0

    var isEnabled = true {
        didSet {
            if !isEnabled { hide() }
        }
    }

    /// Updates the ink to the stroke drawn so far.
    func show(_ points: [Vector2], in space: Space) {
        guard isEnabled, !points.isEmpty, let screen = activeScreen else { return }

        pendingFade?.cancel()
        pendingFade = nil

        if strokeAnchor == nil {
            strokeAnchor = anchor(on: screen, for: space)
        }
        // The window is only as big as the drawing needs, so nothing has to composite a
        // screen-sized surface for a stroke the size of a postage stamp.
        let panel = panel(on: screen, frame: inkFrame(on: screen, for: space))
        canvas?.showPath(points.map { convert($0, in: space, screen: screen) })
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Replaces the ink with what the stroke was recognised as, then fades everything out.
    func finish(character: CharacterGesture?, action: ButtonAction?) {
        guard isEnabled, let canvas, let screen = activeScreen, panel?.isVisible == true else { return }

        // The ink is done with, so the window moves to the middle for the result.
        let size = DrawingOverlay.resultSize
        _ = panel(on: screen, frame: NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))

        if let character {
            canvas.showResult(title: character.displayName, subtitle: action?.displayName)
        } else {
            canvas.showResult(title: "no match", subtitle: nil)
        }
        strokeAnchor = nil
        fadeOut(after: DrawingOverlay.holdDuration)
    }

    /// The stroke came to nothing, so take the ink away.
    func cancel() {
        guard panel?.isVisible == true else { return }
        fadeOut(after: 0)
    }

    /// Stops immediately, without a fade.
    func hide() {
        pendingFade?.cancel()
        pendingFade = nil
        strokeAnchor = nil
        canvas?.clear()
        panel?.orderOut(nil)
    }

    // MARK: - Window

    private var activeScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func panel(on screen: NSScreen, frame: NSRect) -> NSPanel {
        let panel = panel ?? makePanel()
        // Called for every frame of a stroke, so only touch the window when something has
        // actually changed.
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        let scale = panel.backingScaleFactor
        if scale != canvasScale {
            canvasScale = scale
            canvas?.updateScale(scale)
        }
        return panel
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DrawingOverlay.surfaceWidth, height: 160),
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
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let canvas = OverlayCanvas(frame: panel.contentLayoutRect)
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas

        self.panel = panel
        self.canvas = canvas
        return panel
    }

    /// Where the ink is drawn: a box at the pointer for a surface drawing, or the whole
    /// screen for a pointer drag, which can wander anywhere.
    private func inkFrame(on screen: NSScreen, for space: Space) -> NSRect {
        switch space {
        case .surface(let aspectRatio):
            let size = surfaceSize(aspectRatio: aspectRatio)
            let origin = strokeAnchor ?? .zero
            return NSRect(
                x: screen.frame.minX + origin.x,
                y: screen.frame.minY + origin.y,
                width: size.width,
                height: size.height
            )
        case .screen:
            return screen.frame
        }
    }

    /// The bottom-left of the box a surface drawing fills, kept on the screen.
    private func anchor(on screen: NSScreen, for space: Space) -> CGPoint {
        guard case .surface(let aspectRatio) = space else { return .zero }

        let size = surfaceSize(aspectRatio: aspectRatio)
        // The pointer is where the eye already is, so the drawing goes around it.
        let pointer = NSEvent.mouseLocation
        let origin = CGPoint(
            x: pointer.x - screen.frame.minX - size.width / 2,
            y: pointer.y - screen.frame.minY - size.height / 2
        )

        let margin = DrawingOverlay.screenMargin
        return CGPoint(
            x: min(max(origin.x, margin), max(screen.frame.width - size.width - margin, margin)),
            y: min(max(origin.y, margin), max(screen.frame.height - size.height - margin, margin))
        )
    }

    private func surfaceSize(aspectRatio: Double) -> CGSize {
        let width = DrawingOverlay.surfaceWidth
        return CGSize(width: width, height: width / max(aspectRatio, 0.2))
    }

    /// Stroke point to a point inside the panel, which covers the whole screen.
    private func convert(_ point: Vector2, in space: Space, screen: NSScreen) -> CGPoint {
        switch space {
        case .surface(let aspectRatio):
            // The window is the drawing box, so points map straight into it. Keeping the
            // surface's proportions means a wide trackpad is never squashed.
            let size = surfaceSize(aspectRatio: aspectRatio)
            return CGPoint(
                x: point.x / max(aspectRatio, 0.2) * size.width,
                // Surface y points down, AppKit's points up.
                y: (1 - point.y) * size.height
            )
        case .screen:
            // CoreGraphics measures from the top of the primary display, AppKit from the
            // bottom of it, the same flip `WindowManager` does for window frames.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            return CGPoint(
                x: point.x - screen.frame.minX,
                y: (primaryHeight - point.y) - screen.frame.minY
            )
        }
    }

    private func fadeOut(after delay: TimeInterval) {
        pendingFade?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DrawingOverlay.fadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // A new stroke may have started during the fade.
                guard panel.alphaValue == 0 else { return }
                self?.hide()
            })
        }
        pendingFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// The ink and the result labels, as layers so a stroke can grow without redrawing.
private final class OverlayCanvas: NSView {
    /// A little thicker than jitouch's 12 points.
    private static let inkWidth: CGFloat = 14

    private let ink = CAShapeLayer()
    private let title = CATextLayer()
    private let subtitle = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        ink.fillColor = nil
        ink.lineWidth = OverlayCanvas.inkWidth
        ink.lineCap = .round
        ink.lineJoin = .round
        ink.strokeColor = DrawingOverlay.inkColor.cgColor
        layer?.addSublayer(ink)

        for label in [title, subtitle] {
            label.alignmentMode = .center
            label.isHidden = true
            layer?.addSublayer(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    func updateScale(_ scale: CGFloat) {
        for layer in [ink, title, subtitle] {
            layer.contentsScale = scale
        }
    }

    func showPath(_ points: [CGPoint]) {
        guard let first = points.first else { return }

        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        withoutAnimation {
            ink.path = path
            ink.isHidden = false
            title.isHidden = true
            subtitle.isHidden = true
        }
    }

    func showResult(title text: String, subtitle detail: String?) {
        // Always in the middle, wherever on the surface or the screen the stroke was made.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // A single letter can be large; "Down ↓ (I)" and the like need to fit.
        let titleSize: CGFloat = text.count <= 2 ? 76 : 40
        let titleHeight = titleSize * 1.3
        let subtitleHeight: CGFloat = detail == nil ? 0 : 30
        let top = centre.y + (titleHeight + subtitleHeight) / 2

        withoutAnimation {
            ink.isHidden = true

            // Kept inside the window, so tall text cannot run off a short one.
            let width = min(bounds.width, 420)
            let x = min(max(centre.x - width / 2, 0), max(bounds.width - width, 0))
            let titleY = min(max(top - titleHeight, subtitleHeight), bounds.height - titleHeight)

            title.string = attributed(text, size: titleSize, weight: .bold, alpha: 1)
            title.frame = CGRect(x: x, y: titleY, width: width, height: titleHeight)
            title.isHidden = false

            subtitle.string = detail.map { attributed($0, size: 20, weight: .bold, alpha: 1) }
            subtitle.frame = CGRect(
                x: x,
                y: titleY - subtitleHeight,
                width: width,
                height: subtitleHeight
            )
            subtitle.isHidden = detail == nil
        }
    }

    func clear() {
        withoutAnimation {
            ink.path = nil
            title.isHidden = true
            subtitle.isHidden = true
        }
    }

    /// A lighter shade of the ink, with nothing drawn around or behind the glyphs: their
    /// size and weight are what make them readable.
    private func attributed(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        alpha: CGFloat
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: OverlayCanvas.roundedFont(size: size, weight: weight),
            .foregroundColor: DrawingOverlay.textColor.withAlphaComponent(alpha),
        ])
    }

    /// SF Rounded, whose softer letterforms suit a scribbled letter better than the default
    /// face. Falls back to the plain system font if the design is ever unavailable.
    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    /// Layer changes animate by default, which would leave the ink lagging the fingers.
    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
