import Foundation

/// Smooth scrolling for a mouse wheel, optionally with momentum, the way a trackpad scrolls.
///
/// Each notch's distance is spread over the frames that follow by a `ScrollSmoother`. With
/// momentum on, the scroll is also a gesture, as a trackpad's is: it begins with its first
/// movement, changes with every frame and ends a moment after the last notch. A flick — a
/// quick run of notches — then coasts on from the speed it had, slowing as a page does
/// after the fingers lift, so apps rubber-band at the ends and coast as they would under a
/// trackpad. A notch during the coast ends it and begins a new gesture. Without momentum
/// the frames carry no phases at all, which is how smooth scrolling has always been.
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
        /// The drive's easing: after this long about 63% of a notch has been scrolled.
        public var driveTimeConstant: TimeInterval = 0.08
        /// How long after the last notch the gesture ends.
        public var endDelay: TimeInterval = 0.08
        /// The notches of the last this-long count towards a flick.
        public var flickWindow: TimeInterval = 0.15
        /// Points a second the wheel must be turned at to coast afterwards.
        public var flickSpeed = 800.0
        /// How quickly a coast slows: after this long it has 37% of its speed left.
        public var coastTimeConstant: TimeInterval = 0.35
        /// Points a second below which a coast stops.
        public var stopSpeed = 15.0
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
    private var drive: ScrollSmoother
    private var lastNotch: TimeInterval = 0
    private var recentNotches: [(time: TimeInterval, distance: Double)] = []
    private var lastFrame: TimeInterval?
    private var velocity = (vertical: 0.0, horizontal: 0.0)
    private var carry = (vertical: 0.0, horizontal: 0.0)
    /// A coast cut short by a new notch: its end goes out before the new gesture begins.
    private var owesCoastEnd = false

    /// The frame length assumed for a scroll's first frame, with none before it to measure.
    static let firstFrame: TimeInterval = 1.0 / 120

    public init(hasMomentum: Bool, tuning: Tuning = Tuning()) {
        self.hasMomentum = hasMomentum
        self.tuning = tuning
        drive = ScrollSmoother(timeConstant: tuning.driveTimeConstant)
    }

    /// Nothing left to send; the frame clock can stop.
    public var isIdle: Bool {
        if case .idle = stage { return !owesCoastEnd }
        return false
    }

    /// A notch's distance in points, after any reversing and speeding up.
    public mutating func add(vertical: Double, horizontal: Double, at now: TimeInterval) {
        guard vertical != 0 || horizontal != 0 else { return }
        if case .coast(let begun) = stage {
            owesCoastEnd = begun
            stage = .idle
        }
        if case .idle = stage {
            stage = .gesture(began: false)
            recentNotches.removeAll()
            carry = (0, 0)
        }
        drive.add(vertical: vertical, horizontal: horizontal)
        lastNotch = now
        recentNotches.append((now, (vertical * vertical + horizontal * horizontal).squareRoot()))
        recentNotches.removeAll { now - $0.time > tuning.flickWindow }
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
            if hasMomentum, began, now - lastNotch >= tuning.endDelay, let ended = endGestureIfDue() {
                return ended
            }
            let step = drive.step(elapsed: elapsed)
            if !hasMomentum, drive.isIdle {
                stage = .idle
                lastFrame = nil
            }
            guard step.vertical != 0 || step.horizontal != 0 else { return nil }
            guard hasMomentum else {
                return Frame(vertical: step.vertical, horizontal: step.horizontal, phase: nil, momentum: .none)
            }
            stage = .gesture(began: true)
            return Frame(vertical: step.vertical, horizontal: step.horizontal, phase: began ? .changed : .began, momentum: .none)

        case .coast(let begun):
            let decay = exp(-elapsed / tuning.coastTimeConstant)
            // The distance an exponentially slowing coast covers in `elapsed`, so a frame
            // rate never changes how far it goes.
            let reach = tuning.coastTimeConstant * (1 - decay)
            carry.vertical += velocity.vertical * reach
            carry.horizontal += velocity.horizontal * reach
            velocity.vertical *= decay
            velocity.horizontal *= decay
            let step = (vertical: Int(carry.vertical.rounded(.towardZero)), horizontal: Int(carry.horizontal.rounded(.towardZero)))
            carry.vertical -= Double(step.vertical)
            carry.horizontal -= Double(step.horizontal)

            if begun, speed(of: velocity) < tuning.stopSpeed {
                stage = .idle
                lastFrame = nil
                return Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end)
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
        defer {
            stage = .idle
            drive.stop()
            recentNotches.removeAll()
            lastFrame = nil
            carry = (0, 0)
            owesCoastEnd = false
        }
        if owesCoastEnd {
            return Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end)
        }
        switch stage {
        case .gesture(began: true) where hasMomentum:
            return Frame(vertical: 0, horizontal: 0, phase: .cancelled, momentum: .none)
        case .coast(begun: true):
            return Frame(vertical: 0, horizontal: 0, phase: nil, momentum: .end)
        default:
            return nil
        }
    }

    /// A flick ends as soon as the notches stop, handing what the drive had left to the
    /// coast at the speed it was going, so nothing is lost and nothing jumps. Anything
    /// slower ends only once the drive has scrolled the whole distance.
    private mutating func endGestureIfDue() -> Frame? {
        let notchSpeed = recentNotches.reduce(0) { $0 + $1.distance } / tuning.flickWindow
        let isFlick = notchSpeed >= tuning.flickSpeed
        guard isFlick || drive.isIdle else { return nil }

        let remaining = drive.remainingDistance
        drive.stop()
        velocity = (remaining.vertical / tuning.driveTimeConstant, remaining.horizontal / tuning.driveTimeConstant)
        if isFlick, speed(of: velocity) >= tuning.stopSpeed {
            stage = .coast(begun: false)
            carry = (0, 0)
        } else {
            stage = .idle
            lastFrame = nil
        }
        return Frame(vertical: 0, horizontal: 0, phase: .ended, momentum: .none)
    }

    private func speed(of velocity: (vertical: Double, horizontal: Double)) -> Double {
        (velocity.vertical * velocity.vertical + velocity.horizontal * velocity.horizontal).squareRoot()
    }
}
