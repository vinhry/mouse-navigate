import AppKit
import MouseNavigateCore
import QuartzCore

/// Shows how one touch gesture is done: the trackpad or mouse seen from above, the fingers
/// that rest on it in grey and the ones that tap, click or slide in red, over and over.
final class TouchGesturePreviewView: NSView {
    private static let padding: CGFloat = 6
    private static let fingerRadius: CGFloat = 6
    private static let ringGap: CGFloat = 4
    private static let trailAlpha: Float = 0.35
    /// Width over height. A trackpad is a wide slab, a Magic Mouse a tall pebble.
    private static let trackpadAspect: CGFloat = 1.5
    private static let mouseAspect: CGFloat = 0.62

    private static let passDuration = 2.4
    private static let tapDown = 0.16
    private static let tapPeriod = 0.32
    private static let slideDuration = 0.7
    private static let animationKey = "pass"

    /// Everything drawn, so the whole picture can move as a pushed mouse does.
    private let content = CALayer()
    private let surface = CAShapeLayer()
    private var fingers: [PlacedFinger] = []

    private struct PlacedFinger {
        let cue: FingerCue
        let dot: CAShapeLayer
        /// Where an acting finger lands, shown all along, so the picture is never short of
        /// a finger while that one is up.
        let ghost: CAShapeLayer?
        let ring: CAShapeLayer?
        let trail: CAShapeLayer?
        let start: CGPoint
        let end: CGPoint

        var layers: [CAShapeLayer] { [ghost, trail, dot, ring].compactMap { $0 } }
    }

    var gesture: TouchGesture? {
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

    /// Left-handed: the picture is flipped, index finger on the right.
    var isMirrored = false {
        didSet {
            guard isMirrored != oldValue else { return }
            rebuild()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(content)
        surface.lineWidth = 1.5
        content.addSublayer(surface)
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in allShapeLayers {
            layer.contentsScale = scale
        }
    }

    private var allShapeLayers: [CAShapeLayer] {
        [surface] + fingers.flatMap(\.layers)
    }

    /// Layer colours are resolved once, so they are re-resolved when the appearance changes.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.strokeColor = NSColor.tertiaryLabelColor.cgColor
            surface.fillColor = NSColor.quaternaryLabelColor.cgColor
            for finger in fingers {
                let color = finger.cue.isActive ? DrawingOverlay.textColor : NSColor.secondaryLabelColor
                finger.dot.fillColor = color.cgColor
                finger.ghost?.strokeColor = color.cgColor
                finger.ring?.strokeColor = color.cgColor
                finger.trail?.strokeColor = color.cgColor
            }
        }
    }

    // MARK: - Building the picture

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for layer in fingers.flatMap(\.layers) {
            layer.removeFromSuperlayer()
        }
        fingers = []
        content.frame = bounds
        content.transform = CATransform3DIdentity

        guard let gesture, bounds.width > 0, bounds.height > 0 else {
            surface.path = nil
            return
        }

        let frame = surfaceFrame(for: gesture.surface)
        let cornerRadius = gesture.surface == .magicMouse ? frame.width * 0.45 : 10
        surface.path = CGPath(roundedRect: frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        let radius = TouchGesturePreviewView.fingerRadius
        let dotPath = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        let ringRadius = radius + TouchGesturePreviewView.ringGap
        let ringPath = CGPath(
            ellipseIn: CGRect(x: -ringRadius, y: -ringRadius, width: ringRadius * 2, height: ringRadius * 2),
            transform: nil
        )

        // Ghosts and trails go in first, so every finger sits on top of all of them.
        var placed: [PlacedFinger] = []
        for cue in gesture.choreography.fingers {
            let start = place(cue.at, in: frame)
            var end = start

            var ghost: CAShapeLayer?
            if cue.isActive, cue.motion != .hold {
                let layer = CAShapeLayer()
                layer.path = dotPath
                layer.fillColor = nil
                layer.lineWidth = 1.5
                layer.opacity = 0.45
                layer.position = start
                content.addSublayer(layer)
                ghost = layer
            }

            var trail: CAShapeLayer?
            if case .slide(let to) = cue.motion {
                end = place(to, in: frame)
                let path = CGMutablePath()
                path.move(to: start)
                path.addLine(to: end)
                let layer = CAShapeLayer()
                layer.path = path
                layer.fillColor = nil
                layer.lineWidth = radius * 2
                layer.lineCap = .round
                layer.opacity = TouchGesturePreviewView.trailAlpha
                content.addSublayer(layer)
                trail = layer
            }

            let dot = CAShapeLayer()
            dot.path = dotPath
            dot.position = end

            var ring: CAShapeLayer?
            if cue.motion == .hold || cue.motion == .click {
                let layer = CAShapeLayer()
                layer.path = ringPath
                layer.fillColor = nil
                layer.lineWidth = 2
                layer.position = end
                // A held finger keeps its ring; a click's ring only shows as it spreads.
                layer.opacity = cue.motion == .hold ? 1 : 0
                ring = layer
            }
            placed.append(PlacedFinger(
                cue: cue, dot: dot, ghost: ghost, ring: ring, trail: trail, start: start, end: end
            ))
        }
        for finger in placed {
            content.addSublayer(finger.dot)
            if let ring = finger.ring {
                content.addSublayer(ring)
            }
        }
        fingers = placed

        applyColors()
        viewDidChangeBackingProperties()
        updateAnimation()
    }

    /// The device, as large as fits with its proportions kept, in the middle of the view.
    private func surfaceFrame(for surface: TouchSurface) -> CGRect {
        let aspect = surface == .magicMouse
            ? TouchGesturePreviewView.mouseAspect
            : TouchGesturePreviewView.trackpadAspect
        let available = bounds.insetBy(dx: TouchGesturePreviewView.padding, dy: TouchGesturePreviewView.padding)
        var size = CGSize(width: available.width, height: available.width / aspect)
        if size.height > available.height {
            size = CGSize(width: available.height * aspect, height: available.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// A unit-box position onto the device. Cues count y downwards and assume the right
    /// hand; the view counts y up and may be showing the left.
    private func place(_ point: Vector2, in frame: CGRect) -> CGPoint {
        let x = isMirrored ? 1 - point.x : point.x
        return CGPoint(
            x: frame.minX + CGFloat(x) * frame.width,
            y: frame.maxY - CGFloat(point.y) * frame.height
        )
    }

    // MARK: - Animation

    private func updateAnimation() {
        for layer in [content] + (allShapeLayers as [CALayer]) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(TouchGesturePreviewView.animationKey) {
                layer.removeAnimation(forKey: key)
            }
        }
        // With Reduce Motion on, the picture at the end of the pass says the same thing: the
        // fingers that act, in red, and each slide's trail, drawn to its end.
        guard isAnimating, window != nil, let gesture, !fingers.isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }

        for finger in fingers {
            for (keyPath, animation) in animations(for: finger) {
                add(animation, to: finger.dot, keyPath: keyPath)
            }
            if let ring = finger.ring, finger.cue.motion == .click {
                for (keyPath, animation) in ringAnimations(for: finger.cue) {
                    add(animation, to: ring, keyPath: keyPath)
                }
            }
            if let trail = finger.trail {
                for (keyPath, animation) in trailAnimations(for: finger.cue) {
                    add(animation, to: trail, keyPath: keyPath)
                }
            }
        }

        if gesture.choreography.movesDevice {
            // Pushed away and to the right, then brought back for the next pass.
            let x = Timeline()
            x.add(0, 0).add(0.5, 0).add(1.3, 14).add(1.8, 14).add(Timeline.duration - 0.1, 0).add(Timeline.duration, 0)
            let y = Timeline()
            y.add(0, 0).add(0.5, 0).add(1.3, 9).add(1.8, 9).add(Timeline.duration - 0.1, 0).add(Timeline.duration, 0)
            add(x.animation(eased: true), to: content, keyPath: "transform.translation.x")
            add(y.animation(eased: true), to: content, keyPath: "transform.translation.y")
        }
    }

    private func add(_ animation: CAKeyframeAnimation, to layer: CALayer, keyPath: String) {
        animation.keyPath = keyPath
        layer.add(animation, forKey: "\(TouchGesturePreviewView.animationKey).\(keyPath)")
    }

    private func animations(for finger: PlacedFinger) -> [(String, CAKeyframeAnimation)] {
        let total = Timeline.duration
        let delay = finger.cue.delay
        switch finger.cue.motion {
        case .rest, .hold:
            return []

        case .press:
            // Down at its turn, then everyone lifts together near the end.
            let opacity = Timeline()
            opacity.add(0, 0).add(delay, 0).add(delay, 1).add(total - 0.2, 1).add(total - 0.2, 0).add(total, 0)
            let scale = Timeline()
            scale.add(0, 1).add(delay, 1.3).add(delay + 0.12, 1).add(total, 1)
            return [("opacity", opacity.animation()), ("transform.scale", scale.animation(eased: true))]

        case .tap, .click:
            var count = 1
            if case .tap(let taps) = finger.cue.motion {
                count = taps
            }
            let opacity = Timeline()
            let scale = Timeline()
            opacity.add(0, 0)
            scale.add(0, 1)
            for index in 0..<count {
                let down = delay + Double(index) * TouchGesturePreviewView.tapPeriod
                let up = down + TouchGesturePreviewView.tapDown
                opacity.add(down, 0).add(down, 1).add(up, 1).add(up, 0)
                scale.add(down, 1.3).add(up, 1)
            }
            opacity.add(total, 0)
            scale.add(total, 1)
            return [("opacity", opacity.animation()), ("transform.scale", scale.animation(eased: true))]

        case .slide:
            // Lands a moment before it moves, holds at the end, then fades for the next pass.
            let opacity = Timeline()
            opacity.add(0, 0).add(delay - 0.3, 0).add(delay - 0.2, 1).add(total - 0.25, 1).add(total - 0.1, 0).add(total, 0)
            let moved = delay + TouchGesturePreviewView.slideDuration
            let position = Timeline()
            position.add(0, finger.start).add(delay, finger.start).add(moved, finger.end)
                .add(total - 0.1, finger.end).add(total, finger.start)
            return [("opacity", opacity.animation()), ("position", position.animation(eased: true))]
        }
    }

    /// A click's ring spreads out from the finger and fades as it goes.
    private func ringAnimations(for cue: FingerCue) -> [(String, CAKeyframeAnimation)] {
        let total = Timeline.duration
        let opacity = Timeline()
        opacity.add(0, 0).add(cue.delay, 0).add(cue.delay, 1).add(cue.delay + 0.45, 0).add(total, 0)
        let scale = Timeline()
        scale.add(0, 1).add(cue.delay, 1).add(cue.delay + 0.45, 1.8).add(total, 1)
        return [("opacity", opacity.animation()), ("transform.scale", scale.animation(eased: true))]
    }

    /// The trail draws itself under the finger as it moves, and goes with it at the end.
    private func trailAnimations(for cue: FingerCue) -> [(String, CAKeyframeAnimation)] {
        let total = Timeline.duration
        let alpha = Double(TouchGesturePreviewView.trailAlpha)
        let moved = cue.delay + TouchGesturePreviewView.slideDuration
        let opacity = Timeline()
        opacity.add(0, 0).add(cue.delay, 0).add(cue.delay, alpha).add(total - 0.25, alpha).add(total - 0.1, 0).add(total, 0)
        let strokeEnd = Timeline()
        strokeEnd.add(0, 0).add(cue.delay, 0).add(moved, 1).add(total - 0.1, 1).add(total - 0.1, 0).add(total, 0)
        return [("opacity", opacity.animation()), ("strokeEnd", strokeEnd.animation(eased: true))]
    }

    /// Keyframes along one pass. Two values at one instant make a step; Core Animation
    /// wants its key times to climb, so the second is nudged along by a hair.
    private final class Timeline {
        static let duration = TouchGesturePreviewView.passDuration
        private var times: [Double] = []
        private var values: [Any] = []

        @discardableResult
        func add(_ time: Double, _ value: Double) -> Timeline {
            append(time, value)
        }

        @discardableResult
        func add(_ time: Double, _ point: CGPoint) -> Timeline {
            append(time, NSValue(point: point))
        }

        private func append(_ time: Double, _ value: Any) -> Timeline {
            var clamped = min(max(time, 0), Timeline.duration)
            if let last = times.last, clamped <= last {
                clamped = min(last + 0.001, Timeline.duration)
            }
            times.append(clamped)
            values.append(value)
            return self
        }

        func animation(eased: Bool = false) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation()
            animation.values = values
            animation.keyTimes = times.map { NSNumber(value: $0 / Timeline.duration) }
            animation.duration = Timeline.duration
            animation.repeatCount = .infinity
            if eased {
                animation.timingFunctions = Array(
                    repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                    count: max(values.count - 1, 0)
                )
            }
            return animation
        }
    }
}
