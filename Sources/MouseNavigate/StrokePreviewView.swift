import AppKit
import MouseNavigateCore
import QuartzCore

/// Shows how one character is drawn: its stroke, traced from start to finish over and over,
/// with a dot where the stroke begins.
final class StrokePreviewView: NSView {
    private static let padding: CGFloat = 16
    private static let lineWidth: CGFloat = 7
    private static let dotRadius: CGFloat = 7
    private static let passDuration = 1.4
    private static let animationKey = "trace"

    private let stroke = CAShapeLayer()
    private let dot = CAShapeLayer()

    var gesture: CharacterGesture? {
        didSet {
            guard gesture != oldValue else { return }
            rebuild()
        }
    }

    /// Off while the pane is hidden, so nothing animates out of sight.
    var isAnimating = true {
        didSet {
            guard isAnimating != oldValue else { return }
            updateAnimation()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stroke.fillColor = nil
        stroke.lineWidth = StrokePreviewView.lineWidth
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.strokeColor = DrawingOverlay.textColor.cgColor
        layer?.addSublayer(stroke)

        // A ring rather than a blob: a filled dot in the same red would disappear into the
        // stroke it sits on.
        dot.lineWidth = 3
        layer?.addSublayer(dot)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Layer colours are resolved once, so they are re-resolved when the appearance changes.
    private func applyColors() {
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            stroke.strokeColor = DrawingOverlay.textColor.cgColor
            dot.strokeColor = DrawingOverlay.textColor.cgColor
            dot.fillColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        stroke.contentsScale = scale
        dot.contentsScale = scale
    }

    private func rebuild() {
        let points = gesture.map { CharacterTemplates.preview(for: $0) } ?? []
        guard points.count >= 2, bounds.width > 0, bounds.height > 0 else {
            stroke.path = nil
            dot.path = nil
            return
        }

        let placed = fit(points)
        let path = CGMutablePath()
        path.move(to: placed[0])
        for point in placed.dropFirst() {
            path.addLine(to: point)
        }

        let radius = StrokePreviewView.dotRadius
        stroke.path = path
        dot.path = CGPath(
            ellipseIn: CGRect(
                x: placed[0].x - radius,
                y: placed[0].y - radius,
                width: radius * 2,
                height: radius * 2
            ),
            transform: nil
        )
        updateAnimation()
    }

    /// Scales the stroke to fill the view without distorting it. Templates are drawn in a
    /// unit box but a few stray outside it, so the actual extent is what gets fitted.
    private func fit(_ points: [Vector2]) -> [CGPoint] {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let width = (xs.max() ?? 1) - minX
        let height = (ys.max() ?? 1) - minY

        let inset = StrokePreviewView.padding + StrokePreviewView.lineWidth / 2
        let available = CGSize(width: bounds.width - inset * 2, height: bounds.height - inset * 2)
        let scale = min(
            width > 0 ? available.width / width : .greatestFiniteMagnitude,
            height > 0 ? available.height / height : .greatestFiniteMagnitude
        )
        let drawn = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(
            x: (bounds.width - drawn.width) / 2,
            y: (bounds.height - drawn.height) / 2
        )

        return points.map { point in
            CGPoint(
                x: origin.x + (point.x - minX) * scale,
                // Templates count y downwards; the view counts it up.
                y: origin.y + drawn.height - (point.y - minY) * scale
            )
        }
    }

    private func updateAnimation() {
        stroke.removeAnimation(forKey: StrokePreviewView.animationKey)
        guard isAnimating, window != nil, stroke.path != nil else {
            stroke.strokeEnd = 1
            return
        }

        // One pass, then a pause holding the finished shape, over and over.
        let trace = CAKeyframeAnimation(keyPath: "strokeEnd")
        trace.values = [0, 1, 1]
        trace.keyTimes = [0, 0.75, 1]
        trace.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]
        trace.duration = StrokePreviewView.passDuration
        trace.repeatCount = .infinity
        stroke.add(trace, forKey: StrokePreviewView.animationKey)
    }
}
