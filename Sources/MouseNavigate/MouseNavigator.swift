import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import MouseNavigateCore
import notify

final class MouseNavigator {
    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    private static let lockFilePath = "/tmp/com.vinhry.MouseNavigate.lock"
    private static let quitRequestNotification = "com.vinhry.MouseNavigate.quitRequest"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: DispatchSourceTimer?
    private var lockFileDescriptor: CInt = -1
    private var statusBarController: StatusBarController?
    private var preferencesController: PreferencesWindowController?
    private var isPaused = false

    private let detector = DeviceDetector()
    private let cursorEngine = KeyboardCursorEngine()

    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private let hiServicesHandle = dlopen(MouseNavigator.hiServicesPath, RTLD_NOW)
    private lazy var coreDockSendNotification: CoreDockSendNotificationFn? = {
        guard
            let hiServicesHandle,
            let symbol = dlsym(hiServicesHandle, "CoreDockSendNotification")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    deinit {
        if let handle = hiServicesHandle {
            dlclose(handle)
        }
    }

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

        let preferences = PreferencesWindowController(detector: detector, engine: cursorEngine)
        preferencesController = preferences

        let controller = StatusBarController(detector: detector, preferencesController: preferences)
        controller.onQuit = { [weak self] in
            // Never leave a synthetic mouse button held down after quitting.
            self?.cursorEngine.forceExit()
            NSApp.terminate(nil)
        }
        controller.onPauseToggle = { [weak self] paused in
            self?.isPaused = paused
            self?.cursorEngine.isSuspended = paused
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
        let dialog = SecondaryLaunchDialogController(icon: loadMouseNavigateIcon())
        return dialog.run()
    }

    private func loadMouseNavigateIcon() -> NSImage? {
        if let image = NSImage(named: "AppIcon") {
            return image
        }

        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }

        let fallbackPath =
            FileManager.default.currentDirectoryPath + "/Assets/mouse-navigation-icon.png"
        if let image = NSImage(contentsOfFile: fallbackPath) {
            return image
        }

        return NSApp.applicationIconImage
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
        var mask = CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        mask |= CGEventMask(1) << CGEventType.keyUp.rawValue
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let navigator = Unmanaged<MouseNavigator>.fromOpaque(userInfo).takeUnretainedValue()
            return navigator.handle(type: type, event: event)
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
        return true
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            // The tap went deaf, so a key-up may have been missed entirely.
            cursorEngine.forceExit()
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
            return handleKeyboard(type: type, event: event)
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            preferencesController?.reportButtonPress(button)
            let action = Preferences.shared.action(forButton: button, profile: detector.activeProfile)
            return performAction(action, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyboard(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        let disposition: KeyboardCursorEngine.Disposition
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            disposition = cursorEngine.handleKeyDown(
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat
            )
        case .keyUp:
            disposition = cursorEngine.handleKeyUp(keyCode: keyCode)
        default:
            // Modifiers are observed for the speed tiers but always passed along, so
            // other apps keep seeing an accurate modifier state.
            cursorEngine.handleFlagsChanged(flags: event.flags)
            disposition = .pass
        }

        return disposition == .consume ? nil : Unmanaged.passUnretained(event)
    }

    private var isSupportedFrontmostApp: Bool {
        SupportedApps.isSupported(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func performAction(_ action: ButtonAction, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch action {
        case .back:
            guard isSupportedFrontmostApp else { return Unmanaged.passUnretained(event) }
            sendShortcut(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand)
            return nil
        case .forward:
            guard isSupportedFrontmostApp else { return Unmanaged.passUnretained(event) }
            sendShortcut(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand)
            return nil
        case .appExpose:
            triggerSystemAppExpose()
            return nil
        case .missionControl:
            triggerSystemMissionControl()
            return nil
        case .toggleCursorMode:
            cursorEngine.toggleFromMouseButton()
            return nil
        case .disabled:
            return Unmanaged.passUnretained(event)
        }
    }

    private func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        // Tagged so the keyboard path recognises these as ours and ignores them.
        keyDown.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func triggerSystemAppExpose() {
        if sendCoreDockNotification("com.apple.expose.front.awake") {
            return
        }
        if sendConfiguredMissionControlHotKey(id: 33) {
            return
        }
        postDockNotification("com.apple.expose.front.awake")
    }

    private func triggerSystemMissionControl() {
        if sendCoreDockNotification("com.apple.expose.awake") {
            return
        }
        if sendConfiguredMissionControlHotKey(id: 32) {
            return
        }
        postDockNotification("com.apple.expose.awake")
        postDockNotification("com.apple.workspaces.awake")
    }

    private func sendConfiguredMissionControlHotKey(id: Int) -> Bool {
        guard
            let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
            let allHotKeys = domain["AppleSymbolicHotKeys"] as? [String: Any],
            let hotKey = allHotKeys[String(id)] as? [String: Any],
            (hotKey["enabled"] as? Bool) == true,
            let value = hotKey["value"] as? [String: Any],
            let parameters = value["parameters"] as? [Any],
            parameters.count >= 3,
            let keyCodeInt = intValue(from: parameters[1]),
            let flagsInt = intValue(from: parameters[2])
        else {
            return false
        }

        sendShortcut(
            keyCode: CGKeyCode(keyCodeInt),
            flags: CGEventFlags(rawValue: UInt64(flagsInt))
        )
        return true
    }

    private func intValue(from value: Any) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }

    private func sendCoreDockNotification(_ name: String) -> Bool {
        guard let coreDockSendNotification else {
            return false
        }
        coreDockSendNotification(name as CFString, nil)
        return true
    }

    private func postDockNotification(_ name: String) {
        let notification = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            notification,
            nil,
            nil,
            true
        )
        _ = name.withCString { cName in
            notify_post(cName)
        }
    }
}
