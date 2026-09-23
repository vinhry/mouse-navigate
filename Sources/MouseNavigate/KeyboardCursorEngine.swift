import AppKit
import CoreGraphics
import MouseNavigateCore

/// Drives the pointer from the keyboard.
///
/// The activation key is an ordinary letter, so the hard part is never stealing it from
/// someone who is just typing. That is handled by hold-duration gating: the key is
/// withheld briefly, and unless it is *still* down when the threshold expires, it is
/// replayed as a normal keystroke.
final class KeyboardCursorEngine {
    /// What the event tap should do with the event that was just handled.
    enum Disposition {
        case pass
        case consume
    }

    private let preferences = Preferences.shared
    private let output = CursorOutput()

    private var gate = ActivationGate()
    private var heldDirections: Set<CursorBinding> = []
    private var isScrollModifierHeld = false
    private var tier: SpeedTier = []

    private var motionTimer: DispatchSourceTimer?
    private var holdTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

    private var motionStart: TimeInterval = 0
    private var accumulator = SubPixelAccumulator()
    private var scrollAccumulator = SubPixelAccumulator()
    private var lastPosition = Vector2.zero
    private var speedProfile = CursorSpeedProfile()
    private var screens: [Rect] = []

    private let keyEventSource = CGEventSource(stateID: .hidSystemState)
    /// Modifier flags (Caps Lock, in practice) on the activation key-down being withheld.
    private var withheldFlags: CGEventFlags = []

    /// Suspends the engine entirely — used while a key recorder in preferences is armed,
    /// and while the app is paused from the status menu.
    var isSuspended = false {
        didSet {
            if isSuspended { forceExit() }
        }
    }

    /// Reports whether cursor mode is engaged, for the status bar icon.
    var onModeChange: ((Bool) -> Void)?

    var isEngaged: Bool { gate.isEngaged }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemInterruption),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemInterruption),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        // Rebinding a key or disabling the feature mid-hold would otherwise leave the
        // gate waiting on a key that no longer means anything.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemInterruption),
            name: Preferences.didChangeNotification,
            object: nil
        )
    }

    @objc private func handleSystemInterruption() {
        forceExit()
    }

    // MARK: - Key routing

    /// `proxy` is the tap the event is passing through; replayed keystrokes are inserted
    /// there so they stay in order with the event being handled.
    func handleKeyDown(
        keyCode: UInt16,
        flags: CGEventFlags,
        isRepeat: Bool,
        proxy: CGEventTapProxy
    ) -> Disposition {
        guard isEnabled else { return .pass }

        let outcome = gate.keyDown(
            keyCode: keyCode,
            activationKey: activationKey,
            hasModifier: hasAnyModifier(flags),
            isRepeat: isRepeat,
            at: ProcessInfo.processInfo.systemUptime,
            retypeWindow: retypeWindow
        )

        switch outcome {
        case .handleEngaged:
            return handleKeyDownEngaged(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        case .armHold:
            withheldFlags = flags
            return apply(outcome, proxy: proxy)
        default:
            return apply(outcome, proxy: proxy)
        }
    }

    func handleKeyUp(keyCode: UInt16, proxy: CGEventTapProxy) -> Disposition {
        guard isEnabled else { return .pass }

        let outcome = gate.keyUp(
            keyCode: keyCode,
            activationKey: activationKey,
            at: ProcessInfo.processInfo.systemUptime
        )

        switch outcome {
        case .handleEngaged:
            return handleKeyUpEngaged(keyCode: keyCode)
        case .exitEngaged:
            tearDownCursorMode()
            return .consume
        default:
            return apply(outcome, proxy: proxy)
        }
    }

    func handleFlagsChanged(flags: CGEventFlags, proxy: CGEventTapProxy) {
        guard isEnabled else { return }

        // A modifier joining a pending hold means a shortcut, not cursor mode.
        if flags.contains(.maskCommand) || flags.contains(.maskAlternate)
            || flags.contains(.maskControl) {
            _ = apply(gate.modifierJoined(), proxy: proxy)
        }

        updateTier(from: flags)
    }

    /// Carry out the side effects the gate asked for.
    private func apply(_ outcome: ActivationGate.Outcome, proxy: CGEventTapProxy) -> Disposition {
        switch outcome {
        case .pass:
            return .pass
        case .consume:
            return .consume
        case .armHold:
            startHoldTimer()
            return .consume
        case .replayThenPass:
            cancelHoldTimer()
            replayActivationKey(proxy: proxy)
            return .pass
        case .replayThenConsume:
            cancelHoldTimer()
            replayActivationKey(proxy: proxy)
            return .consume
        case .exitEngaged:
            tearDownCursorMode()
            return .consume
        case .handleEngaged:
            return .pass
        }
    }

    // MARK: - Hold timer

    private func startHoldTimer() {
        cancelHoldTimer()

        let threshold = preferences.value(for: .holdThreshold)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + threshold)
        timer.setEventHandler { [weak self] in
            self?.enterCursorMode()
        }
        timer.resume()
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func replayActivationKey(proxy: CGEventTapProxy) {
        postKeyEvent(keyCode: activationKey, down: true, proxy: proxy)
        postKeyEvent(keyCode: activationKey, down: false, proxy: proxy)
    }

    private func postKeyEvent(keyCode: UInt16, down: Bool, proxy: CGEventTapProxy) {
        guard let event = CGEvent(
            keyboardEventSource: keyEventSource,
            virtualKey: CGKeyCode(keyCode),
            keyDown: down
        ) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        // Replay the letter as it was typed. Left to the source, the event takes whatever
        // modifiers are down *now*, so rolling "a" into Shift+B produced "A".
        event.flags = withheldFlags
        // Posting at the HID tap would re-enter the stream upstream of the key that
        // triggered the replay, which is then delivered first: typing "abc" fast came out
        // as "bac". An event posted through the proxy enters the system before the event
        // the tap callback returns, so the withheld letter keeps its place.
        event.tapPostEvent(proxy)
    }

    // MARK: - Engaged

    private func handleKeyDownEngaged(
        keyCode: UInt16,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Disposition {
        updateTier(from: flags)

        if keyCode == activationKey {
            // Autorepeat while held; the timer drives movement, not the repeat rate.
            return .consume
        }

        guard let binding = binding(for: keyCode) else {
            // Unmapped keys still reach the frontmost app, so ⌘Tab and ⌘W keep working.
            return .pass
        }

        guard !isRepeat else { return .consume }

        switch binding {
        case .exit:
            gate.reset()
            tearDownCursorMode()
        case .lock:
            toggleLock()
        case .leftClick:
            output.pressButton(.left)
        case .rightClick:
            output.pressButton(.right)
        case .middleClick:
            output.pressButton(.middle)
        case .scrollModifier:
            isScrollModifierHeld = true
            restartMotionRamp()
        case .moveUp, .moveDown, .moveLeft, .moveRight:
            if heldDirections.insert(binding).inserted {
                restartMotionRamp()
                startMotionTimer()
            }
        case .activate:
            break
        }

        return .consume
    }

    private func handleKeyUpEngaged(keyCode: UInt16) -> Disposition {
        guard let binding = binding(for: keyCode) else { return .pass }

        switch binding {
        case .leftClick:
            output.releaseButton(.left)
        case .rightClick:
            output.releaseButton(.right)
        case .middleClick:
            output.releaseButton(.middle)
        case .scrollModifier:
            isScrollModifierHeld = false
            restartMotionRamp()
        case .moveUp, .moveDown, .moveLeft, .moveRight:
            heldDirections.remove(binding)
            if heldDirections.isEmpty {
                stopMotionTimer()
            } else {
                restartMotionRamp()
            }
        case .activate, .exit, .lock:
            break
        }

        return .consume
    }

    private func enterCursorMode() {
        cancelHoldTimer()
        guard gate.holdElapsed() else { return }

        speedProfile = preferences.speedProfile()
        screens = output.screenRects()
        lastPosition = output.location
        startWatchdog()
        onModeChange?(true)
    }

    private func toggleLock() {
        if gate.toggleLock() {
            tearDownCursorMode()
        }
    }

    /// Release everything cursor mode was holding. The gate's phase is assumed to have
    /// been settled already by whoever called this.
    private func tearDownCursorMode() {
        cancelHoldTimer()
        stopMotionTimer()
        stopWatchdog()
        output.releaseAllButtons()

        heldDirections.removeAll()
        isScrollModifierHeld = false
        accumulator.reset()
        scrollAccumulator.reset()

        onModeChange?(false)
    }

    /// Unconditional teardown for pause, sleep, tap loss and quit.
    func forceExit() {
        let wasEngaged = gate.isEngaged
        gate.reset()
        cancelHoldTimer()
        stopMotionTimer()
        stopWatchdog()
        output.releaseAllButtons()

        heldDirections.removeAll()
        isScrollModifierHeld = false
        accumulator.reset()
        scrollAccumulator.reset()

        if wasEngaged {
            onModeChange?(false)
        }
    }

    // MARK: - Motion

    private func restartMotionRamp() {
        motionStart = ProcessInfo.processInfo.systemUptime
        accumulator.reset()
        scrollAccumulator.reset()
    }

    private func startMotionTimer() {
        guard motionTimer == nil else { return }

        speedProfile = preferences.speedProfile()
        screens = output.screenRects()
        lastPosition = output.location

        lastTick = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        motionTimer = timer
    }

    private func stopMotionTimer() {
        motionTimer?.cancel()
        motionTimer = nil
        lastTick = 0
    }

    private var lastTick: TimeInterval = 0

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastTick == 0 ? 1.0 / 120.0 : min(now - lastTick, 0.1)
        lastTick = now

        let direction = CursorMotion.direction(
            up: heldDirections.contains(.moveUp),
            down: heldDirections.contains(.moveDown),
            left: heldDirections.contains(.moveLeft),
            right: heldDirections.contains(.moveRight)
        )
        guard !direction.isZero else { return }

        let held = now - motionStart

        if isScrollModifierHeld {
            let eased = CursorMotion.easedRamp(
                heldDuration: held,
                acceleration: speedProfile.acceleration
            )
            let multiplier = tier.multiplier(using: speedProfile)
            // Scroll runs on the same ramp, scaled to a per-tick pixel budget.
            let perTick = speedProfile.scrollSpeed * (0.35 + 0.65 * eased) * multiplier
            let delta = Vector2(x: direction.x * perTick, y: direction.y * perTick)
            let step = scrollAccumulator.take(delta)
            // Positive wheel1 scrolls the content up, which is the opposite sign to the
            // downward-positive cursor axis.
            output.scroll(deltaX: -step.dx, deltaY: -step.dy)
            return
        }

        let speed = CursorMotion.speed(heldDuration: held, tier: tier, profile: speedProfile)
        let delta = Vector2(x: direction.x * speed * dt, y: direction.y * speed * dt)
        let step = accumulator.take(delta)
        guard step.dx != 0 || step.dy != 0 else { return }

        let current = output.location
        let target = Vector2(x: current.x + Double(step.dx), y: current.y + Double(step.dy))
        let clamped = CursorMotion.clamp(point: target, previous: lastPosition, screens: screens)
        lastPosition = clamped
        output.move(to: clamped)
    }

    // MARK: - Watchdog

    /// A key-up can be lost if another process grabs the event stream mid-hold, which
    /// would otherwise leave cursor mode stuck on. Re-check the real key state instead
    /// of trusting that we saw every event.
    private func startWatchdog() {
        stopWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Only the held phase depends on the key still being down; a latched
            // mode is meant to outlive it.
            guard self.gate.phase == .engaged else { return }

            // Read the hardware state: the tap consumes the activation key, so the
            // session state never sees it go down and would always report it released.
            let stillDown = CGEventSource.keyState(
                .hidSystemState,
                key: CGKeyCode(self.activationKey)
            )
            if !stillDown {
                self.gate.reset()
                self.tearDownCursorMode()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - Helpers

    private var isEnabled: Bool {
        !isSuspended && preferences.isCursorModeEnabled
    }

    private var activationKey: UInt16 {
        preferences.keyCode(for: .activate)
    }

    /// How soon after the activation letter was typed a fresh press means the user wants
    /// it again, held down, rather than cursor mode.
    private var retypeWindow: TimeInterval {
        preferences.value(for: .retypeWindow)
    }

    private func binding(for keyCode: UInt16) -> CursorBinding? {
        for binding in CursorBinding.allCases where preferences.keyCode(for: binding) == keyCode {
            return binding
        }
        return nil
    }

    private func hasAnyModifier(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskShift)
            || flags.contains(.maskSecondaryFn)
    }

    private func updateTier(from flags: CGEventFlags) {
        var next: SpeedTier = []
        if flags.contains(.maskShift) { next.insert(.shift) }
        if flags.contains(.maskControl) { next.insert(.control) }
        if flags.contains(.maskAlternate) { next.insert(.option) }
        tier = next
    }

    /// Engages cursor mode from a mouse button rather than the keyboard.
    func toggleFromMouseButton() {
        guard preferences.isCursorModeEnabled, !isSuspended else { return }

        if gate.toggleExternally() {
            tearDownCursorMode()
            return
        }

        cancelHoldTimer()
        speedProfile = preferences.speedProfile()
        screens = output.screenRects()
        lastPosition = output.location
        onModeChange?(true)
    }
}
