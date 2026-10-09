import AppKit
import ApplicationServices
import Darwin
import Foundation
import MouseNavigateCore

final class MouseNavigator {
    /// In the per-user temporary directory rather than /tmp: anyone with an account on the
    /// machine can create and hold a path in /tmp, and doing so would keep the daemon from
    /// ever starting.
    private static let lockFilePath =
        NSTemporaryDirectory() + "com.vinhry.MouseNavigate.lock"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: DispatchSourceTimer?
    private var lockFileDescriptor: CInt = -1
    private var statusBarController: StatusBarController?
    private var preferencesController: PreferencesWindowController?
    /// Paused from the menu bar.
    private var isUserPaused = false
    /// The frontmost app has MouseNavigate turned off in its per-app settings.
    private var isFrontmostDisabled = false
    private var isPaused: Bool { isUserPaused || isFrontmostDisabled }
    private var installedEventMask: CGEventMask = 0
    /// Set when a Magic Mouse click became a gesture, so its release is swallowed too.
    private var isSwallowingLeftMouseUp = false
    /// Until when the next left click is Tap to click's rendering of a trackpad tap that was
    /// a gesture, and when the last left click arrived, both in system uptime.
    private var tapClickDeadline: TimeInterval = 0
    private var lastLeftClickTime: TimeInterval = 0
    /// How long after a tap gesture its click may still arrive, and how recently a click
    /// must have come to be taken for the tap's own click that arrived first.
    private static let tapClickWindow: TimeInterval = 0.3
    private static let tapClickLead: TimeInterval = 0.15
    /// Set once a touch gesture has taken a scroll, until the next scroll begins.
    private var isSuppressingScrollSession = false

    /// NSApplication holds its delegate weakly, so it lives here.
    private lazy var appDelegate = AppDelegate(navigator: self)

    private let detector = DeviceDetector()
    private let cursorEngine = KeyboardCursorEngine()
    private let strokeCapture = StrokeCapture()
    private lazy var performer = ActionPerformer(cursorEngine: cursorEngine, windowManager: WindowManager())
    private lazy var touchMonitor = TouchMonitor(performer: performer)
    private lazy var buttons = ButtonPressController(performer: performer) { [unowned self] button, press in
        Preferences.shared.binding(
            for: .button(button, self.detector.activeProfile, press),
            app: FrontmostApp.shared.bundleID
        )
    }
    private let wheel = WheelScroller()
    private let updater = Updater()

    /// Prints touch surfaces, contacts and recognized gestures. Set by `--touch-debug`.
    var isTouchDebugEnabled = false

    /// Prints every attached pointing device and the profile it resolves to.
    func printDetectedDevices() {
        detector.refresh()
        print("Detected: \(detector.statusDescription)")
        print("Active profile: \(detector.activeProfile.displayName)")
        for line in detector.deviceSummaries() {
            print("  - \(line)")
        }
    }

    /// Become an application, put the icon up, and only then start anything that can stall
    /// or ask for permission.
    ///
    /// The order is the whole point. Earlier versions spawned a detached copy of
    /// themselves and let the process LaunchServices started exit, which left the survivor
    /// unregistered: macOS attributed its permission prompts to a process that no longer
    /// existed, so on a Mac with no existing grant no dialog ever appeared. The icon was
    /// also created after the permission check, the event tap, IOKit enumeration and two
    /// dlopens of private frameworks — so anything slow or stuck among those left a
    /// running process with no icon, no permission and no way to quit it.
    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate

        Log.launch.info(
            """
            MouseNavigate \(AppInfo.version, privacy: .public) starting from \
            \(Bundle.main.bundleURL.path, privacy: .public)
            """
        )

        guard claimSingleInstance() else {
            Log.launch.info("Another copy is already running; bringing it forward instead.")
            activateRunningInstance()
            return
        }

        let controller = StatusBarController(detector: detector)
        controller.onQuit = { [weak self] in
            // Never leave a synthetic mouse button held down after quitting.
            self?.cursorEngine.forceExit()
            NSApp.terminate(nil)
        }
        controller.onPauseToggle = { [weak self] paused in
            guard let self else { return }
            self.isUserPaused = paused
            self.applyPauseState()
        }
        controller.setup()
        statusBarController = controller

        cursorEngine.onModeChange = { [weak controller] active in
            controller?.isCursorModeActive = active
        }
        Log.launch.info("Menu bar item created.")

        // Left to the first turn of the run loop, which is spinning by then: whatever
        // these calls do — wait on a TCC round trip, dlopen a private framework, walk
        // IOKit — the icon is already on screen and its menu already works.
        DispatchQueue.main.async { [weak self] in
            self?.startServices()
        }

        // Never returns: quitting ends the process from inside the run loop, and the lock
        // goes with it.
        app.run()
    }

    /// The last thing before the process ends, by whatever route.
    func prepareForTermination() {
        cursorEngine.forceExit()
        releaseHeldMouseInput()
    }

    /// Everything that needs permission, hardware or a private framework. None of it is
    /// allowed to run before the icon exists.
    private func startServices() {
        requestAccessibilityPermission()
        let tapInstalled = installEventTap()

        detector.start()

        strokeCapture.onStroke = { [weak self] points in
            self?.touchMonitor.handleStroke(points, in: .screen)
        }
        strokeCapture.onProgress = { [weak self] points in
            self?.touchMonitor.handleStrokeProgress(points, in: .screen)
        }
        strokeCapture.onCancelled = { [weak self] in
            self?.touchMonitor.cancelStroke()
        }
        touchMonitor.isDebugLogging = isTouchDebugEnabled
        touchMonitor.trackpadTapGestureHandler = { [weak self] in
            self?.trackpadTapBecameGesture()
        }
        touchMonitor.start()

        FrontmostApp.shared.onChange = { [weak self] _ in
            self?.updateFrontmostDisabled()
        }
        updateFrontmostDisabled()

        // A press held across sleep would otherwise fire its hold on waking, and a click
        // waiting on its double-click window would run long after it was made.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: Preferences.didChangeNotification,
            object: nil
        )

        let preferences = PreferencesWindowController(
            detector: detector,
            engine: cursorEngine,
            touchMonitor: touchMonitor,
            updater: updater
        )
        preferencesController = preferences
        statusBarController?.preferencesController = preferences
        statusBarController?.updater = updater

        updater.onQuit = { [weak self] in
            self?.statusBarController?.onQuit?()
        }
        updater.start()

        if !tapInstalled {
            waitForAccessibilityPermission()
        }

        Log.launch.info(
            "Services started; device: \(self.detector.statusDescription, privacy: .public)."
        )
    }

    /// What a second launch does, by way of the app delegate, and the Preferences menu
    /// item with it.
    func showPreferences() {
        guard let preferencesController else {
            // Only reachable in the moment between the icon appearing and the first turn
            // of the run loop.
            Log.launch.notice("Preferences asked for before startup finished; ignoring.")
            return
        }
        preferencesController.showOrFocus()
    }

    /// Only a lock another process is holding means "already running".
    ///
    /// This used to give the same answer when `open()` itself failed — a symlinked or
    /// foreign-owned lock file, a purged temporary directory, no free descriptors — and
    /// the caller then exited in silence. Refusing to start because a lock file could not
    /// be created is far worse than starting without the lock.
    private func claimSingleInstance() -> Bool {
        // O_NOFOLLOW prevents a symlink attack where an adversary replaces the lock
        // file with a symlink to a sensitive path before this process creates it.
        lockFileDescriptor = open(MouseNavigator.lockFilePath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            Log.launch.error(
                """
                Could not open \(MouseNavigator.lockFilePath, privacy: .public): \
                \(reason, privacy: .public). Starting without single-instance protection.
                """
            )
            return true
        }

        guard flock(lockFileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(lockFileDescriptor)
            lockFileDescriptor = -1
            return false
        }
        return true
    }

    /// The running copy answers reopen by showing its preferences, and reopen is what
    /// Launch Services sends a running app when it is asked to open it again. Activating
    /// it would only bring forward an app with no windows, which is to say nothing. This
    /// is only reachable from a second command-line launch, since Finder never starts a
    /// second process for a running app.
    private func activateRunningInstance() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let opened = DispatchSemaphore(value: 0)
            var succeeded = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                succeeded = app != nil
                opened.signal()
            }
            // The process is about to exit; give Launch Services a moment to deliver.
            if opened.wait(timeout: .now() + 3) == .success, succeeded {
                return
            }
        }

        // Unbundled, or Launch Services declined: bringing it forward is all that is left.
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        where app.processIdentifier != mine {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }
            return
        }
    }

    private func requestAccessibilityPermission() {
        // takeUnretainedValue() is correct here: kAXTrustedCheckOptionPrompt is a
        // global constant. takeRetainedValue() would decrement its retain count on
        // each call, eventually leading to a dangling reference.
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true
        ]
        if AXIsProcessTrustedWithOptions(options) {
            Log.permissions.info("Accessibility already granted.")
        } else {
            Log.permissions.notice(
                """
                Accessibility not granted; the system was asked to prompt. Grant it in \
                System Settings > Privacy & Security > Accessibility.
                """
            )
        }
    }

    /// Returns false when the tap cannot be created, which is the normal state until
    /// Accessibility permission has been granted.
    private func installEventTap() -> Bool {
        let mask = desiredEventMask

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let navigator = Unmanaged<MouseNavigator>.fromOpaque(userInfo).takeUnretainedValue()
            return navigator.handle(type: type, event: event, proxy: proxy)
        }

        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfRef
        )

        guard let eventTap else {
            Log.permissions.notice(
                "Event tap refused; waiting on Accessibility and Input Monitoring."
            )
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            // Quitting here would leave someone with a process and no explanation, which
            // is the failure this whole startup path was rewritten to avoid. Fall back to
            // the same waiting behaviour a refused tap already uses.
            Log.launch.error("Could not create the run loop source for the event tap.")
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        installedEventMask = mask
        Log.permissions.info("Event tap installed.")
        return true
    }

    /// Clicks, keystrokes and scrolls only pass through the tap while something needs them,
    /// so with the keyboard cursor, gestures and scroll options off neither the pointer nor
    /// the keyboard ever waits on this process. Side-button releases are rare enough to take
    /// always: a hold or double-click needs them.
    private var desiredEventMask: CGEventMask {
        var types: [CGEventType] = [.otherMouseDown, .otherMouseUp]
        if Preferences.shared.isCursorModeEnabled {
            types += [.keyDown, .keyUp, .flagsChanged]
        }
        if Preferences.shared.isTouchEnabled {
            types += [
                .scrollWheel, .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .otherMouseDragged,
            ]
        } else if Preferences.shared.scrollSettings.isActive {
            types.append(.scrollWheel)
        }
        return types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
    }

    /// Pausing and an app with MouseNavigate turned off stand everything down the same way:
    /// whatever is held is let go, so switching apps mid-hold never strands a key or click.
    private func applyPauseState() {
        cursorEngine.isSuspended = isPaused
        touchMonitor.isPaused = isPaused
        releaseHeldMouseInput()
    }

    private func updateFrontmostDisabled() {
        let disabled = Preferences.shared.isAppDisabled(FrontmostApp.shared.bundleID)
        guard disabled != isFrontmostDisabled else { return }
        isFrontmostDisabled = disabled
        applyPauseState()
    }

    @objc private func handleWillSleep() {
        releaseHeldMouseInput()
    }

    @objc private func preferencesDidChange() {
        updateFrontmostDisabled()
        guard let eventTap, desiredEventMask != installedEventMask else { return }

        releaseHeldMouseInput()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
        if !installEventTap() {
            // Accessibility was taken away since the tap was first made. Say so, and keep
            // trying, exactly as at startup.
            waitForAccessibilityPermission()
        }
    }

    /// Lets go of anything held back mid-gesture, so no click is ever lost.
    private func releaseHeldMouseInput() {
        strokeCapture.cancel()
        isSwallowingLeftMouseUp = false
        isSuppressingScrollSession = false
        tapClickDeadline = 0
        buttons.reset()
        wheel.stop()
    }

    /// Quitting here would leave a first-time user with no icon and no explanation, so stay
    /// in the menu bar showing the permission warning. macOS posts nothing when the grant
    /// arrives, so poll for it and install the tap the moment it does.
    private func waitForAccessibilityPermission() {
        statusBarController?.isAwaitingPermission = true
        guard permissionTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, AXIsProcessTrusted(), self.installEventTap() else { return }

            self.permissionTimer?.cancel()
            self.permissionTimer = nil
            self.statusBarController?.isAwaitingPermission = false
            Log.permissions.info("Accessibility granted; now listening.")
        }
        timer.resume()
        permissionTimer = timer
    }

    private func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            // The tap went deaf, so a key-up may have been missed entirely.
            cursorEngine.forceExit()
            releaseHeldMouseInput()
            return Unmanaged.passUnretained(event)
        }

        // Our own synthetic events must never re-enter the state machine.
        if event.getIntegerValueField(.eventSourceUserData) == CursorOutput.syntheticTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseUp, isPaused {
            // Pausing forgets every press in progress, but not that a press was swallowed:
            // its release is swallowed too, so the app never gets half a click.
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return buttons.buttonUp(button) ? nil : Unmanaged.passUnretained(event)
        }

        guard !isPaused else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return handleKeyboard(type: type, event: event, proxy: proxy)
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            preferencesController?.reportButtonPress(button)
            if button == 2 {
                if isCharacterSourceActive(.middleButtonDrag), strokeCapture.handleDown(.middle, at: event.location) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            guard Preferences.configurableButtons.contains(button) else {
                return Unmanaged.passUnretained(event)
            }
            return buttons.buttonDown(button, at: event.location) ? nil : Unmanaged.passUnretained(event)
        case .otherMouseDragged:
            // Only the middle button draws; a side button dragged mid-stroke is its own affair.
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
                return Unmanaged.passUnretained(event)
            }
            return strokeCapture.handleDragged(.middle, at: event.location) ? nil : Unmanaged.passUnretained(event)
        case .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if button == 2 {
                return strokeCapture.handleUp(.middle, at: event.location) ? nil : Unmanaged.passUnretained(event)
            }
            return buttons.buttonUp(button) ? nil : Unmanaged.passUnretained(event)
        case .rightMouseDown:
            if isCharacterSourceActive(.magicMouseRightDrag), strokeCapture.handleDown(.right, at: event.location) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .rightMouseDragged:
            return strokeCapture.handleDragged(.right, at: event.location) ? nil : Unmanaged.passUnretained(event)
        case .rightMouseUp:
            return strokeCapture.handleUp(.right, at: event.location) ? nil : Unmanaged.passUnretained(event)
        case .leftMouseDown:
            return handleLeftMouseDown(event)
        case .leftMouseUp:
            guard isSwallowingLeftMouseUp else { return Unmanaged.passUnretained(event) }
            isSwallowingLeftMouseUp = false
            return nil
        case .scrollWheel:
            // Only trackpad and Magic Mouse scrolls are continuous; a wheel is never held back.
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            if isContinuous {
                return shouldSuppressContinuousScroll(event) ? nil : Unmanaged.passUnretained(event)
            }
            let settings = Preferences.shared.scrollSettings
            guard settings.isActive else { return Unmanaged.passUnretained(event) }
            return wheel.handle(event, settings: settings) ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Once a touch gesture has claimed a scroll, the rest of that scroll is its too: the
    /// moves that follow and the momentum after the fingers lift, which would otherwise
    /// fling the page the moment the drawn letter was done. The gesture's end still
    /// reaches the app, so a scroll it had begun is finished rather than left hanging.
    private func shouldSuppressContinuousScroll(_ event: CGEvent) -> Bool {
        let phase = CGScrollPhase(rawValue: UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase)))
        if phase == .began || phase == .mayBegin {
            isSuppressingScrollSession = false
        }
        if touchMonitor.shouldSuppressScroll {
            isSuppressingScrollSession = true
        }
        guard isSuppressingScrollSession else { return false }
        return !(phase == .ended || phase == .cancelled)
    }

    /// A trackpad tap has just become a gesture. With Tap to click on, macOS makes a click
    /// out of the same tap, which usually lands after the gesture's action. Terminal and
    /// Finder tabs are windows, so a click aimed at the old tab brings it straight back
    /// after a One-Fix tap has switched away from it. The next click, if it comes soon, is
    /// that one and is held back. A click that already came a moment ago was that one
    /// instead, and nothing is armed, so a real click after the tap is never lost.
    private func trackpadTapBecameGesture() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLeftClickTime > MouseNavigator.tapClickLead else { return }
        tapClickDeadline = now + MouseNavigator.tapClickWindow
    }

    /// A Magic Mouse click with the fingers in the middle-click pose runs that gesture's
    /// action instead of clicking. A click that Tap to click made out of a trackpad tap
    /// which has just been a gesture is held back, release and all: the tap was spoken for.
    private func handleLeftMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Preferences.shared.isTouchEnabled else {
            return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastLeftClickTime = now
        if now < tapClickDeadline {
            tapClickDeadline = 0
            isSwallowingLeftMouseUp = true
            return nil
        }
        guard touchMonitor.isMagicMouseMiddleClickPose else {
            return Unmanaged.passUnretained(event)
        }
        let binding = Preferences.shared.binding(for: .touch(.mouseMiddleClick), app: FrontmostApp.shared.bundleID)
        guard binding != .disabled, performer.perform(binding) else {
            return Unmanaged.passUnretained(event)
        }
        isSwallowingLeftMouseUp = true
        return nil
    }

    private func isCharacterSourceActive(_ source: CharacterSource) -> Bool {
        Preferences.shared.isTouchEnabled && Preferences.shared.isCharacterSourceEnabled(source)
    }

    private func handleKeyboard(
        type: CGEventType,
        event: CGEvent,
        proxy: CGEventTapProxy
    ) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        let disposition: KeyboardCursorEngine.Disposition
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            disposition = cursorEngine.handleKeyDown(
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat,
                proxy: proxy
            )
        case .keyUp:
            disposition = cursorEngine.handleKeyUp(keyCode: keyCode, proxy: proxy)
        default:
            // Modifiers are observed for the speed tiers but always passed along, so
            // other apps keep seeing an accurate modifier state.
            cursorEngine.handleFlagsChanged(flags: event.flags, proxy: proxy)
            disposition = .pass
        }

        return disposition == .consume ? nil : Unmanaged.passUnretained(event)
    }
}
