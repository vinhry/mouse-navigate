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
    private var isPaused = false
    private var installedEventMask: CGEventMask = 0
    /// Set when a Magic Mouse click became a gesture, so its release is swallowed too.
    private var isSwallowingLeftMouseUp = false

    /// NSApplication holds its delegate weakly, so it lives here.
    private lazy var appDelegate = AppDelegate(navigator: self)

    private let detector = DeviceDetector()
    private let cursorEngine = KeyboardCursorEngine()
    private let strokeCapture = StrokeCapture()
    private lazy var performer = ActionPerformer(cursorEngine: cursorEngine, windowManager: WindowManager())
    private lazy var touchMonitor = TouchMonitor(performer: performer)

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
            self.isPaused = paused
            self.cursorEngine.isSuspended = paused
            self.touchMonitor.isPaused = paused
            self.releaseHeldMouseInput()
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

        app.run()

        releaseSingleInstanceLock()
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
        touchMonitor.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: Preferences.didChangeNotification,
            object: nil
        )

        let preferences = PreferencesWindowController(
            detector: detector,
            engine: cursorEngine,
            touchMonitor: touchMonitor
        )
        preferencesController = preferences
        statusBarController?.preferencesController = preferences

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

    private func releaseSingleInstanceLock() {
        if lockFileDescriptor >= 0 {
            _ = flock(lockFileDescriptor, LOCK_UN)
            _ = close(lockFileDescriptor)
            lockFileDescriptor = -1
        }
    }

    /// The running copy is a registered application, so it can simply be brought forward;
    /// it answers reopen by showing its preferences. This is only reachable from a second
    /// command-line launch, since Finder never starts a second process for a running app.
    private func activateRunningInstance() {
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

    /// Clicks and scrolls only pass through the tap while touch gestures need them, so with
    /// gestures off the pointer never waits on this process.
    private var desiredEventMask: CGEventMask {
        var types: [CGEventType] = [.otherMouseDown, .keyDown, .keyUp, .flagsChanged]
        if Preferences.shared.isTouchEnabled {
            types += [
                .scrollWheel, .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .otherMouseDragged, .otherMouseUp,
            ]
        }
        return types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
    }

    @objc private func preferencesDidChange() {
        guard let eventTap, desiredEventMask != installedEventMask else { return }

        releaseHeldMouseInput()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
        _ = installEventTap()
    }

    /// Lets go of anything held back mid-gesture, so no click is ever lost.
    private func releaseHeldMouseInput() {
        strokeCapture.cancel()
        isSwallowingLeftMouseUp = false
    }

    /// Quitting here would leave a first-time user with no icon and no explanation, so stay
    /// in the menu bar showing the permission warning. macOS posts nothing when the grant
    /// arrives, so poll for it and install the tap the moment it does.
    private func waitForAccessibilityPermission() {
        statusBarController?.isAwaitingPermission = true

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

        guard !isPaused else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return handleKeyboard(type: type, event: event, proxy: proxy)
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            preferencesController?.reportButtonPress(button)
            if button == 2, isCharacterSourceActive(.middleButtonDrag),
               strokeCapture.handleDown(.middle, at: event.location) {
                return nil
            }
            let action = Preferences.shared.action(forButton: button, profile: detector.activeProfile)
            return performAction(action, event: event)
        case .otherMouseDragged:
            return strokeCapture.handleDragged(.middle, at: event.location) ? nil : Unmanaged.passUnretained(event)
        case .otherMouseUp:
            return strokeCapture.handleUp(.middle, at: event.location) ? nil : Unmanaged.passUnretained(event)
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
            return isContinuous && touchMonitor.shouldSuppressScroll ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// A Magic Mouse click with the fingers in the middle-click pose runs that gesture's
    /// action instead of clicking.
    private func handleLeftMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Preferences.shared.isTouchEnabled, touchMonitor.isMagicMouseMiddleClickPose else {
            return Unmanaged.passUnretained(event)
        }
        let action = Preferences.shared.touchAction(for: .mouseMiddleClick)
        guard action != .disabled, performer.perform(action) else {
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

    private func performAction(_ action: ButtonAction, event: CGEvent) -> Unmanaged<CGEvent>? {
        performer.perform(action) ? nil : Unmanaged.passUnretained(event)
    }
}
