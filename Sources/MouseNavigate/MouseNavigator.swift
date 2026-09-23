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
    private static let quitRequestNotification = "com.vinhry.MouseNavigate.quitRequest"

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

    func runLauncher() {
        if tryAcquireSingleInstanceLock() {
            releaseSingleInstanceLock()
            launchDaemon()
            return
        }

        if promptQuitRunningInstance() {
            requestExistingInstanceQuit()
        }
    }

    func runDaemon() {
        guard tryAcquireSingleInstanceLock() else {
            return
        }

        registerQuitRequestObserver()

        setbuf(stdout, nil)
        setbuf(stderr, nil)
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

        let controller = StatusBarController(detector: detector, preferencesController: preferences)
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

        if !tapInstalled {
            waitForAccessibilityPermission()
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        print("mouse-navigate daemon is running. Listening for side buttons and keyboard cursor keys.")
        NSApplication.shared.run()

        // Reached only when NSApp.stop() is used instead of terminate
        teardownSingleInstanceResources()
    }

    private func tryAcquireSingleInstanceLock() -> Bool {
        // O_NOFOLLOW prevents a symlink attack where an adversary replaces the lock
        // file with a symlink to a sensitive path before this process creates it.
        lockFileDescriptor = open(MouseNavigator.lockFilePath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0 else {
            return false
        }
        return flock(lockFileDescriptor, LOCK_EX | LOCK_NB) == 0
    }

    private func releaseSingleInstanceLock() {
        if lockFileDescriptor >= 0 {
            _ = flock(lockFileDescriptor, LOCK_UN)
            _ = close(lockFileDescriptor)
            lockFileDescriptor = -1
        }
    }

    private func launchDaemon() {
        // Use Bundle.main.executableURL rather than CommandLine.arguments[0].
        // argv[0] is caller-controlled and could be spoofed or contain a crafted path.
        guard let executableURL = Bundle.main.executableURL else {
            fputs("Failed to determine executable path.\n", stderr)
            return
        }
        let daemon = Process()
        daemon.executableURL = executableURL
        daemon.arguments = ["--daemon"]
        daemon.standardInput = nil
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice

        do {
            try daemon.run()
        } catch {
            fputs("Failed to launch daemon: \(error)\n", stderr)
        }
    }

    private func promptQuitRunningInstance() -> Bool {
        let dialog = SecondaryLaunchDialogController(icon: AppInfo.icon())
        return dialog.run()
    }

    private func requestExistingInstanceQuit() {
        let name = CFNotificationName(MouseNavigator.quitRequestNotification as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    private func registerQuitRequestObserver() {
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            { _, observer, name, _, _ in
                guard let observer, let name else {
                    return
                }

                let receivedName = name.rawValue as String
                guard receivedName == MouseNavigator.quitRequestNotification else {
                    return
                }

                let navigator = Unmanaged<MouseNavigator>.fromOpaque(observer).takeUnretainedValue()
                navigator.handleQuitRequest()
            },
            MouseNavigator.quitRequestNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handleQuitRequest() {
        print("Received quit request. Exiting running daemon.")
        cursorEngine.forceExit()
        NSApp.terminate(nil)
    }

    private func teardownSingleInstanceResources() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            CFNotificationName(MouseNavigator.quitRequestNotification as CFString),
            nil
        )
        releaseSingleInstanceLock()
    }

    private func requestAccessibilityPermission() {
        // takeUnretainedValue() is correct here: kAXTrustedCheckOptionPrompt is a
        // global constant. takeRetainedValue() would decrement its retain count on
        // each call, eventually leading to a dangling reference.
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true
        ]
        if !AXIsProcessTrustedWithOptions(options) {
            print("Accessibility permission is required. Grant access in System Settings > Privacy & Security > Accessibility.")
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
            fputs("Failed to create event tap. Check Accessibility/Input Monitoring permissions.\n", stderr)
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            fputs("Failed to create run loop source.\n", stderr)
            exit(1)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        installedEventMask = mask
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
            print("Accessibility permission granted. Listening for side buttons and keyboard cursor keys.")
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
