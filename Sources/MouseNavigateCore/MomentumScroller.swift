import Foundation

/// Smooth scrolling for a mouse wheel, optionally with momentum, the way a trackpad scrolls.
///
/// Without momentum, each notch's distance is spread over the frames that follow by a
/// `ScrollSmoother`, and the frames carry no phases, which is how smooth scrolling has
/// always been.
///
/// With momentum, the page has a speed, and each notch gives it a push. How freely it then
/// slides depends on how fast the wheel is being turned: a slow turn settles each notch in
/// a moment and moves exactly its own distance, so reading line by line stays precise; a
/// fast spin lets the page run on, as a flick on a trackpad does, and the faster the spin
/// the further. It is one motion throughout, so letting go of a spin never makes the page
/// lurch or brake and then creep. The scroll is a gesture with a trackpad's phases — began,
/// changed, ended a moment after the last notch — and a spin that still has speed then
/// coasts, through momentum begin, continue and end, braking firmly at the very end rather
/// than crawling the last few points. A notch during the coast ends it and begins a new
/// gesture, and turning the other way stops the page first.
///
/// Keeps no clock: every call is given the time.
public struct MomentumScroller: Sendable {
    public struct Frame: Equatable, Sendable {
        public var vertical: Int
        public var horizontal: Int
        /// Where the gesture is; nil during the coast and without momentum.
        public var phase: ScrollPhase?
        public var momentum: MomentumPhase

        public init(vertical: Int, horizontal: Int, phase: ScrollPhase?, momentum: MomentumPhase) {
            self.vertical = vertical
            self.horizontal = horizontal
            self.phase = phase
            self.momentum = momentum
        }
    }

    public struct Tuning: Equatable, Sendable {
        /// Without momentum, each notch's easing: after this long about 63% of it is scrolled.
        public var smoothTimeConstant: TimeInterval = 0.08
        /// With momentum and a slow turn, how quickly a notch settles.
        public var preciseTimeConstant: TimeInterval = 0.05
        /// With momentum and a fast spin, how freely the page slides: after this long it
        /// keeps 37% of its speed, before braking.
        public var glideTimeConstant: TimeInterval = 0.3
        /// Turning speeds, in points a second, from all precise to all glide.
        public var slowSpeed = 400.0
        public var fastSpeed = 1600.0
        /// The notches of the last this-long make the turning speed.
        public var inputWindow: TimeInterval = 0.15
        /// How long after the last notch the gesture ends.
        public var endDelay: TimeInterval = 0.06
        /// Braking added during a coast, in points a second each second, so it comes to a
        /// clean stop instead of creeping a point at a time.
        public var braking = 600.0
        /// Points a second below which the page stops.
        public var stopSpeed = 10.0
        /// The longest a frame may count for, so a stalled timer does not fling the page.
        public var longestFrame: TimeInterval = 0.05

        public init() {}
    }

    private enum Stage: Sendable {
        case idle
        case gesture(began: Bool)
        case coast(begun: Bool)
    }

    public let hasMomentum: Bool
    public let tuning: Tuning
    private var stage = Stage.idle
    /// Without momentum.
    private var smoother: ScrollSmoother
    /// With momentum: the page's speed in points a second, and how freely it slides.
    private var velocity = (vertical: 0.0, horizontal: 0.0)
    private var timeConstant: TimeInterval
    private var carry = (vertical: 0.0, horizontal: 0.0)
    private var lastNotch: TimeInterval = 0
    private var recentNotches: [(time: TimeInterval, distance: Double)] = []
    private var lastFrame: TimeInterval?
    /// A coast cut short by a new notch: its end goes out before the new gesture begins.
    private var owesCoastEnd = false

    /// The frame length assumed for a scroll's first frame, with none before it to measure.
    static let firstFrame: TimeInterval = 1.0 / 120

    public init(hasMomentum: Bool, tuning: Tuning = Tuning()) {
        self.hasMomentum = hasMomentum
        self.tuning = tuning
        smoother = ScrollSmoother(timeConstant: tuning.smoothTimeConstant)
        timeConstant = tuning.preciseTimeConstant
    }

    /// Nothing left to send; the frame clock can stop.
    public var isIdle: Bool {
        if case .idle = stage { return !owesCoastEnd }
        return false
    }

    /// A notch's distance in points, after any reversing and speeding up.
    public mutating func add(vertical: Double, horizontal: Double, at now: TimeInterval) {
        guard vertical != 0 || horizontal != 0 else { return }
        guard hasMomentum else {
            smoother.add(vertical: vertical, horizontal: horizontal)
            if case .idle = stage { stage = .gesture(began: false) }
            return
        }

        if case .coast(let begun) = stage {
            // The page keeps its speed; only the phases start again.
            owesCoastEnd = begun
            stage = .gesture(began: false)
        }
        if case .idle = stage {
            stage = .gesture(began: false)
            velocity = (0, 0)
            carry = (0, 0)
            recentNotches.removeAll()
        }
        lastNotch = now
        recentNotches.append((now, (vertical * vertical + horizontal * horizontal).squareRoot()))
        recentNotches.removeAll { now - $0.time > tuning.inputWindow }
        timeConstant = slideTimeConstant(forTurningSpeed: recentNotches.reduce(0) { $0 + $1.distance } / tuning.inputWindow)

        push(&velocity.vertical, carry: &carry.vertical, by: vertical)
        push(&velocity.horizontal, carry: &carry.horizontal, by: horizontal)
    }

    /// What to send this frame, if anything.
    public mutating func frame(at now: TimeInterval) -> Frame? {
        let elapsed = lastFrame.map { min(max(now - $0, 0), tuning.longestFrame) } ?? Self.firstFrame
        lastFrame = now

        if owesCoastEnd {
            owesCoastEnd = false
            return Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end)
        }

        switch stage {
        case .idle:
            lastFrame = nil
            return nil

        case .gesture(let began):
            guard hasMomentum else { return smoothFrame(elapsed: elapsed) }

            let notchesStopped = now - lastNotch >= tuning.endDelay
            if began, notchesStopped, isStill {
                becomeIdle()
                return Frame(vertical: 0, horizontal: 0, phase: .ended, momentum: .none)
            }
            if began, notchesStopped, timeConstant > tuning.preciseTimeConstant {
                // A spin that has stopped and still has speed glides on.
                stage = .coast(begun: false)
                return Frame(vertical: 0, horizontal: 0, phase: .ended, momentum: .none)
            }
            let step = advance(elapsed: elapsed, braking: false)
            if !began, isStill, step.vertical == 0, step.horizontal == 0 {
                // Too small a notch to move a whole point.
                becomeIdle()
                return nil
            }
            guard step.vertical != 0 || step.horizontal != 0 else { return nil }
            stage = .gesture(began: true)
            return Frame(vertical: step.vertical, horizontal: step.horizontal, phase: began ? .changed : .began, momentum: .none)

        case .coast(let begun):
            let step = advance(elapsed: elapsed, braking: true)
            if isStill {
                becomeIdle()
                return begun ? Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end) : nil
            }
            stage = .coast(begun: true)
            if !begun {
                return Frame(vertical: step.vertical, horizontal: step.horizontal, phase: nil, momentum: .begin)
            }
            guard step.vertical != 0 || step.horizontal != 0 else { return nil }
            return Frame(vertical: step.vertical, horizontal: step.horizontal, phase: nil, momentum: .continue)
        }
    }

    /// Ends whatever is under way, for pausing, sleep and the event tap going deaf: the
    /// frame that closes it, when one has begun.
    public mutating func cancel() -> Frame? {
        let closing: Frame?
        if owesCoastEnd {
            closing = Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end)
        } else {
            switch stage {
            case .gesture(began: true) where hasMomentum:
                closing = Frame(vertical: 0, horizontal: 0, phase: .cancelled, momentum: .none)
            case .coast(begun: true):
                closing = Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end)
            default:
                closing = nil
            }
        }
        smoother.stop()
        owesCoastEnd = false
        becomeIdle()
        return closing
    }

    // MARK: - Motion

    private var isStill: Bool {
        velocity.vertical == 0 && velocity.horizontal == 0
    }

    /// From precise to gliding, eased so no turning speed is a step.
    private func slideTimeConstant(forTurningSpeed speed: Double) -> TimeInterval {
        let range = max(tuning.fastSpeed - tuning.slowSpeed, 1)
        let t = min(max((speed - tuning.slowSpeed) / range, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return tuning.preciseTimeConstant + (tuning.glideTimeConstant - tuning.preciseTimeConstant) * eased
    }

    /// The push that, left to slow down at the current rate, covers exactly `distance`.
    /// Turning the other way stops what was going first.
    private func push(_ speed: inout Double, carry: inout Double, by distance: Double) {
        guard distance != 0 else { return }
        if speed != 0, (speed > 0) != (distance > 0) {
            speed = 0
            carry = 0
        }
        speed += distance / timeConstant
    }

    /// Moves the page on by `elapsed`, in whole points. The slowing is integrated exactly,
    /// so the frame rate changes nothing. A gesture that comes to rest sends the last of its
    /// distance, so a notch moves exactly its own way; a coast just stops.
    private mutating func advance(elapsed: TimeInterval, braking: Bool) -> (vertical: Int, horizontal: Int) {
        let decay = exp(-elapsed / timeConstant)
        let reach = timeConstant * (1 - decay)
        var moved = (vertical: velocity.vertical * reach, horizontal: velocity.horizontal * reach)
        velocity.vertical *= decay
        velocity.horizontal *= decay

        if braking {
            let speed = magnitude(velocity)
            if speed > 0 {
                let lost = min(tuning.braking * elapsed, speed)
                // Braking evenly over the frame costs half its loss times the frame's length.
                let shortfall = lost * elapsed / 2
                moved.vertical -= shortened(moved.vertical, by: shortfall * abs(velocity.vertical) / speed)
                moved.horizontal -= shortened(moved.horizontal, by: shortfall * abs(velocity.horizontal) / speed)
                let scale = (speed - lost) / speed
                velocity.vertical *= scale
                velocity.horizontal *= scale
            }
        }

        let stopping = magnitude(velocity) < tuning.stopSpeed
        if stopping {
            if !braking {
                moved.vertical += velocity.vertical * timeConstant
                moved.horizontal += velocity.horizontal * timeConstant
            }
            velocity = (0, 0)
        }

        carry.vertical += moved.vertical
        carry.horizontal += moved.horizontal
        let step: (vertical: Int, horizontal: Int)
        if stopping, !braking {
            step = (Int(carry.vertical.rounded()), Int(carry.horizontal.rounded()))
            carry = (0, 0)
        } else {
            step = (Int(carry.vertical.rounded(.towardZero)), Int(carry.horizontal.rounded(.towardZero)))
            carry.vertical -= Double(step.vertical)
            carry.horizontal -= Double(step.horizontal)
        }
        return step
    }

    /// How much of `amount` to take off `distance`, without turning it round.
    private func shortened(_ distance: Double, by amount: Double) -> Double {
        let taken = min(amount, abs(distance))
        return distance < 0 ? -taken : taken
    }

    private func magnitude(_ vector: (vertical: Double, horizontal: Double)) -> Double {
        (vector.vertical * vector.vertical + vector.horizontal * vector.horizontal).squareRoot()
    }

    private mutating func becomeIdle() {
        stage = .idle
        velocity = (0, 0)
        carry = (0, 0)
        recentNotches.removeAll()
        lastFrame = nil
    }

    // MARK: - Without momentum

    private mutating func smoothFrame(elapsed: TimeInterval) -> Frame? {
        let step = smoother.step(elapsed: elapsed)
        if smoother.isIdle {
            stage = .idle
            lastFrame = nil
        }
        guard step.vertical != 0 || step.horizontal != 0 else { return nil }
        return Frame(vertical: step.vertical, horizontal: step.horizontal, phase: nil, momentum: .none)
    }
}
