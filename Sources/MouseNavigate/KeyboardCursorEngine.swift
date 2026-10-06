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
    /// Every key whose press was swallowed and is still down. Their repeats and releases
    /// are swallowed too, however cursor mode ends in between: the frontmost app never saw
    /// the press, so it must not see the rest.
    private var heldKeys = HeldKeySwallower()
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

    /// The grid or the click hints, while one has the keyboard.
    private var modal: CursorModal?
    /// The activation key came up while a modal was open. Its release is held over until
    /// the modal closes, so letting go of it mid-pick does not snatch the grid away.
    private var activationReleasedDuringModal = false
    /// Cursor mode was switched on only to show a modal, from a mouse button, and goes off
    /// again with it.
    private var exitsWithModal = false

    private let keyEventSource = CGEventSource(stateID: .hidSystemState)
    /// Modifier flags (Caps Lock, in practice) on the activation key-down being withheld.
    private var withheldFlags: CGEventFlags = []

    // Settings, read once per change rather than on every keystroke.
    private var bindingsByKey: [UInt16: CursorBinding] = [:]
    private var activationKey = CursorBinding.activate.defaultKeyCode
    private var isCursorModeEnabled = true
    private var holdThreshold = CursorSetting.holdThreshold.defaultValue
    private var retypeWindow = CursorSetting.retypeWindow.defaultValue

    /// Suspends the engine entirely while the app is paused from the status menu.
    var isSuspended = false {
        didSet {
            if isSuspended { forceExit() }
        }
    }

    /// Suspends the engine while a key recorder in preferences is armed, so the global tap
    /// does not swallow the very keystroke being recorded. Kept apart from pausing: the
    /// recorder finishing must not resume a paused app.
    var isRecordingSuspended = false {
        didSet {
            if isRecordingSuspended { forceExit() }
        }
    }

    /// Reports whether cursor mode is engaged, for the status bar icon.
    var onModeChange: ((Bool) -> Void)?

    var isEngaged: Bool { gate.isEngaged }

    init() {
        reloadSettings()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspace.addObserver(self, selector: #selector(handleSystemInterruption), name: name, object: nil)
        }
        // Locking the screen is announced to nobody in particular, by the lock screen itself.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemInterruption),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        // Rebinding a key or disabling the feature mid-hold would otherwise leave the
        // gate waiting on a key that no longer means anything.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: Preferences.didChangeNotification,
            object: nil
        )
    }

    @objc private func handleSystemInterruption() {
        forceExit()
    }

    @objc private func preferencesDidChange() {
        reloadSettings()
        forceExit()
    }

    private func reloadSettings() {
        var bindings: [UInt16: CursorBinding] = [:]
        // The first binding in declaration order keeps a key two of them claim.
        for binding in CursorBinding.allCases {
            let keyCode = preferences.keyCode(for: binding)
            if bindings[keyCode] == nil {
                bindings[keyCode] = binding
            }
        }
        bindingsByKey = bindings
        activationKey = preferences.keyCode(for: .activate)
        isCursorModeEnabled = preferences.isCursorModeEnabled
        holdThreshold = preferences.value(for: .holdThreshold)
        retypeWindow = preferences.value(for: .retypeWindow)
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
        // A key whose press was swallowed keeps repeating until it is let go, whatever
        // cursor mode is doing by now. Those repeats are nobody's.
        if heldKeys.keyDown(keyCode, isRepeat: isRepeat) {
            return .consume
        }
        guard isEnabled else { return .pass }

        if modal != nil, gate.isEngaged {
            return handleKeyDownModal(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }

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
        // Whether the press was swallowed decides whether the release is: an app is never
        // handed one half of a keystroke.
        let wasHeld = heldKeys.keyUp(keyCode)
        guard isEnabled else { return wasHeld ? .consume : .pass }

        if modal != nil, gate.isEngaged {
            if keyCode == activationKey, gate.phase == .engaged {
                activationReleasedDuringModal = true
                return .consume
            }
            if wasHeld {
                return .consume
            }
        }

        let outcome = gate.keyUp(
            keyCode: keyCode,
            activationKey: activationKey,
            at: ProcessInfo.processInfo.systemUptime
        )

        switch outcome {
        case .handleEngaged:
            handleKeyUpEngaged(keyCode: keyCode)
            return wasHeld ? .consume : .pass
        case .exitEngaged:
            tearDownCursorMode()
            return .consume
        default:
            let disposition = apply(outcome, proxy: proxy)
            return wasHeld ? .consume : disposition
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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + holdThreshold)
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

    /// Hands the withheld activation letter to the frontmost app after all. With no tap
    /// callback in progress there is no proxy, and the key goes in at the top of the stream.
    private func replayActivationKey(proxy: CGEventTapProxy?) {
        postKeyEvent(keyCode: activationKey, down: true, proxy: proxy)
        postKeyEvent(keyCode: activationKey, down: false, proxy: proxy)
    }

    private func postKeyEvent(keyCode: UInt16, down: Bool, proxy: CGEventTapProxy?) {
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
        if let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: .cghidEventTap)
        }
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

        // ⌘ means a shortcut for the frontmost app, never a cursor action: ⌘S saves and
        // ⌘L reaches the address bar, in locked mode as much as anywhere.
        if flags.contains(.maskCommand) {
            return .pass
        }

        guard let binding = bindingsByKey[keyCode] else {
            // Unmapped keys still reach the frontmost app, so ⌘Tab and ⌘W keep working.
            return .pass
        }

        guard !isRepeat else { return .consume }

        // Swallowed here, so its repeats and release are swallowed too.
        heldKeys.hold(keyCode)

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
        case .grid:
            openGrid()
        case .hints:
            openHints()
        case .activate:
            break
        }

        return .consume
    }

    /// Side effects of a release while engaged. Whether the event itself is swallowed is
    /// decided by whether its press was.
    private func handleKeyUpEngaged(keyCode: UInt16) {
        guard let binding = bindingsByKey[keyCode] else { return }

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
        case .activate, .exit, .lock, .grid, .hints:
            break
        }
    }

    // MARK: - Modals

    private func handleKeyDownModal(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> Disposition {
        // The activation key autorepeating while it is still held.
        if keyCode == activationKey {
            return .consume
        }
        // ⌘-shortcuts reach the frontmost app; the modal gives way to them. Nothing else
        // runs: closing the modal may end cursor mode with it, and a cursor action started
        // then would have no mode to end it.
        if flags.contains(.maskCommand) {
            closeModal()
            return .pass
        }
        guard !isRepeat, let modal else { return .consume }

        switch modal.keyDown(keyCode, flags: flags) {
        case .consume:
            heldKeys.hold(keyCode)
            return .consume
        case .finish:
            heldKeys.hold(keyCode)
            closeModal()
            return .consume
        case .finishAndForward:
            // The key does its job before cursor mode might end with the modal, so a click
            // key still clicks where a grid opened from a mouse button led.
            dismissModal()
            let disposition = handleKeyDownEngaged(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            // A key that opened another modal hands it what was held over, rather than
            // settling now and taking the new modal straight down again.
            if self.modal == nil {
                settleAfterModal()
            }
            return disposition
        }
    }

    private func openGrid() {
        let exitKey = preferences.keyCode(for: .exit)
        let gridKey = preferences.keyCode(for: .grid)
        present(GridMode(pointer: output.location, exitKey: exitKey, gridKey: gridKey) { [weak self] point in
            _ = self?.jump(to: point)
        })
    }

    private func openHints() {
        let hints = HintMode(
            excluding: [activationKey],
            exitKey: preferences.keyCode(for: .exit),
            hintsKey: preferences.keyCode(for: .hints)
        ) { [weak self] point, click in
            guard let self else { return }
            let target = Vector2(x: Double(point.x), y: Double(point.y))
            // The click lands where the pointer actually went, which may be clamped.
            let landed = self.jump(to: target)
            switch click {
            case .left: self.output.click(.left, at: landed)
            case .right: self.output.click(.right, at: landed)
            case .none: break
            }
        }
        present(hints)
    }

    private func present(_ newModal: CursorModal) {
        dismissModal()
        // Movement stops while the keys belong to the modal.
        heldDirections.removeAll()
        isScrollModifierHeld = false
        stopMotionTimer()

        newModal.onFinish = { [weak self, weak newModal] in
            guard let self, let newModal, self.modal === newModal else { return }
            self.closeModal()
        }
        modal = newModal
    }

    @discardableResult
    private func jump(to point: Vector2) -> Vector2 {
        let clamped = CursorMotion.clamp(point: point, previous: output.location, screens: output.screenRects())
        lastPosition = clamped
        output.move(to: clamped)
        return clamped
    }

    /// Ends the modal and settles what was held over while it was open.
    private func closeModal() {
        dismissModal()
        settleAfterModal()
    }

    private func settleAfterModal() {
        if exitsWithModal {
            exitsWithModal = false
            activationReleasedDuringModal = false
            gate.reset()
            tearDownCursorMode()
            return
        }
        if activationReleasedDuringModal {
            activationReleasedDuringModal = false
            let stillDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(activationKey))
            if gate.phase == .engaged, !stillDown {
                gate.reset()
                tearDownCursorMode()
            }
        }
    }

    /// Takes the modal down without deciding anything about cursor mode itself.
    private func dismissModal() {
        modal?.close()
        modal = nil
    }

    /// For the Click Hints and Grid Jump actions on a mouse button or gesture: switches
    /// cursor mode on for as long as the modal is up, if it was not on already.
    func showFromMouseButton(hints: Bool) {
        guard isCursorModeEnabled, !isSuspended, !isRecordingSuspended else { return }

        if !gate.isEngaged {
            engageExternally()
            exitsWithModal = true
        }
        if hints {
            openHints()
        } else {
            openGrid()
        }
    }

    /// Engages cursor mode from a mouse button rather than the keyboard, or ends it.
    func toggleFromMouseButton() {
        guard isCursorModeEnabled, !isSuspended, !isRecordingSuspended else { return }

        if gate.isEngaged {
            _ = gate.toggleExternally()
            tearDownCursorMode()
            return
        }
        engageExternally()
    }

    private func engageExternally() {
        if gate.toggleExternally() == .engagedAfterReplay {
            // The activation letter was pressed moments before, so it was typed after all.
            replayActivationKey(proxy: nil)
        }
        beginCursorMode()
    }

    private func enterCursorMode() {
        cancelHoldTimer()
        guard gate.holdElapsed() else { return }

        // Withheld all along, and still down: its repeats and release are ours to swallow.
        heldKeys.hold(activationKey)
        beginCursorMode()
        startWatchdog()
    }

    private func beginCursorMode() {
        cancelHoldTimer()
        speedProfile = preferences.speedProfile()
        screens = output.screenRects()
        lastPosition = output.location
        onModeChange?(true)
    }

    private func toggleLock() {
        if gate.toggleLock() {
            tearDownCursorMode()
        }
    }

    /// Release everything cursor mode was holding. The gate's phase is assumed to have
    /// been settled already by whoever called this. Keys still physically down stay
    /// remembered: their repeats and releases are swallowed whenever they come.
    private func tearDownCursorMode(reporting: Bool = true) {
        dismissModal()
        activationReleasedDuringModal = false
        exitsWithModal = false
        cancelHoldTimer()
        stopMotionTimer()
        stopWatchdog()
        output.releaseAllButtons()

        heldDirections.removeAll()
        isScrollModifierHeld = false
        accumulator.reset()
        scrollAccumulator.reset()

        if reporting {
            onModeChange?(false)
        }
    }

    /// Unconditional teardown for pause, sleep, tap loss and quit.
    func forceExit() {
        let wasEngaged = gate.isEngaged
        if gate.phase == .pending {
            // The letter was being withheld; dropping it would lose a keystroke.
            replayActivationKey(proxy: nil)
        }
        gate.reset()
        tearDownCursorMode(reporting: wasEngaged)
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

    /// The tick interval the scroll budget is written for.
    private static let nominalTick: TimeInterval = 0.008

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
            // Scroll runs on the same ramp, scaled to a per-tick pixel budget. Scaled by
            // the real tick length too, so a busy main thread slows nothing down.
            let perTick = speedProfile.scrollSpeed * (0.35 + 0.65 * eased) * multiplier
                * (dt / KeyboardCursorEngine.nominalTick)
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
        output.move(to: clamped, delta: (clamped.x - current.x, clamped.y - current.y))
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
            // A modal holds the activation key's release over until it closes.
            guard self.gate.phase == .engaged, self.modal == nil else { return }

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
        !isSuspended && !isRecordingSuspended && isCursorModeEnabled
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
}
