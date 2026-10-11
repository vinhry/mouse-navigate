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
    private var permissionTimer: MainTimer?
    /// Runs while the tap is installed; see `checkTapHealth`.
    private var tapHealthTimer: MainTimer?
    private var lockFileDescriptor: CInt = -1
    private var statusBarController: StatusBarController?
    private var preferencesController: PreferencesWindowController?
    /// Paused from the menu bar.
    private var isUserPaused = false
    /// The frontmost app has MouseNavigate turned off in its per-app settings.
    private var isFrontmostDisabled = false
    /// Asleep, locked, or another user's session in front.
    private let session = SessionMonitor()
    private var isPaused: Bool { isUserPaused || isFrontmostDisabled || !session.isAvailable }
    private var installedEventMask: CGEventMask = 0
    /// Set when a Magic Mouse click became a gesture, so its release is swallowed too.
    private var isSwallowingLeftMouseUp = false
    /// Holds back the click Tap to click makes out of a trackpad tap that was a gesture.
    private var tapClicks = TapClickSuppressor()
    /// Holds back the rest of a scroll a touch gesture has taken.
    private var scrollSession = ScrollSessionSuppressor()
    /// The wheel settings for the mouse in use and the app in front, worked out when
    /// either changes rather than on every notch.
    private var resolvedScroll = ScrollSettings.standard

    /// NSApplication holds its delegate weakly, so it lives here.
    private lazy var appDelegate = AppDelegate(navigator: self)

    private let detector = DeviceDetector()
    private let cursorEngine = KeyboardCursorEngine()
    private let strokeCapture = StrokeCapture()
    private lazy var performer = ActionPerformer(cursorEngine: cursorEngine, windowManager: WindowManager())
    private lazy var touchMonitor = TouchMonitor(performer: performer)
    private lazy var buttons = ButtonPressController(performer: performer) { [unowned self] button, input, modifiers in
        Preferences.shared.buttonBinding(
            button,
            profile: self.detector.activeProfile,
            input: input,
            modifiers: modifiers,
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
        installMainMenu()

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

        // Before touch starts, so a Mac that launches us behind the lock screen never
        // listens to a finger until it is unlocked.
        session.onChange = { [weak self] _ in
            self?.applyPauseState()
        }
        session.onDisplaysSleep = { [weak self] in
            self?.cursorEngine.forceExit()
            self?.releaseHeldMouseInput()
        }
        session.start()

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
            self?.refreshScrollCache()
        }
        updateFrontmostDisabled()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidChange),
            name: DeviceDetector.didChangeNotification,
            object: nil
        )
        refreshScrollCache()

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
        preferences.diagnosticsProvider = { [unowned self] in
            self.collectDiagnostics()
        }
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

    private func collectDiagnostics() -> DiagnosticsReport {
        var standingDown: [DiagnosticsReport.StandDown] = []
        if isUserPaused { standingDown.append(.paused) }
        if isFrontmostDisabled { standingDown.append(.offInFrontApp) }
        if !session.isAvailable { standingDown.append(.sessionAway) }
        return DiagnosticsCollector.collect(.init(
            detector: detector,
            touchMonitor: touchMonitor,
            updater: updater,
            isEventTapLive: eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            standingDown: standingDown
        ))
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
        tapHealthTimer = MainTimer(after: 10, repeating: 10) { [weak self] in
            self?.checkTapHealth()
        }
        Log.permissions.info("Event tap installed.")
        return true
    }

    private func tearDownEventTap() {
        tapHealthTimer = nil
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
    }

    /// macOS tells a running app nothing when its Accessibility permission is taken away:
    /// the tap just stops hearing anything, and the menu bar went on saying Running while
    /// no button, key or gesture did a thing. Nor is a tap that was switched off always
    /// announced. Both are looked for every few seconds.
    private func checkTapHealth() {
        guard let eventTap else { return }
        if !AXIsProcessTrusted() {
            accessibilityWasRevoked()
        } else if !CGEvent.tapIsEnabled(tap: eventTap) {
            Log.tap.notice("Event tap found switched off; re-enabling it and letting go of everything held.")
            CGEvent.tapEnable(tap: eventTap, enable: true)
            releaseAfterMissedEvents()
        }
    }

    /// Stops listening and shows the permission warning, then waits for the grant exactly
    /// as at startup.
    private func accessibilityWasRevoked() {
        Log.permissions.notice("Accessibility was taken away; waiting for it to be granted again.")
        releaseAfterMissedEvents()
        tearDownEventTap()
        waitForAccessibilityPermission()
    }

    /// The tap went deaf for a while, or is going away, so a key-up or mouse-up may never
    /// arrive: everything held is let go of.
    private func releaseAfterMissedEvents() {
        cursorEngine.forceExit()
        releaseHeldMouseInput()
        isSwallowingLeftMouseUp = false
    }

    /// See `EventTapPolicy`.
    private var desiredEventMask: CGEventMask {
        let preferences = Preferences.shared
        let kinds = EventTapPolicy.kinds(
            cursorMode: preferences.isCursorModeEnabled,
            touch: preferences.isTouchEnabled,
            scrollOptions: preferences.isAnyScrollSettingActive,
            dragBindings: preferences.hasAnyDragBinding
        )
        return kinds.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << MouseNavigator.eventType(for: $1).rawValue }
    }

    private static func eventType(for kind: TapEventKind) -> CGEventType {
        switch kind {
        case .otherMouseDown: return .otherMouseDown
        case .otherMouseUp: return .otherMouseUp
        case .otherMouseDragged: return .otherMouseDragged
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        case .scrollWheel: return .scrollWheel
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseDragged: return .rightMouseDragged
        case .rightMouseUp: return .rightMouseUp
        }
    }

    /// Pausing, an app with MouseNavigate turned off, and a session that is asleep, locked or
    /// switched out all stand everything down the same way: whatever is held is let go, so
    /// switching apps mid-hold never strands a key or click, a press held across sleep never
    /// fires its hold on waking, and no gesture runs behind the lock screen.
    private func applyPauseState() {
        cursorEngine.isSuspended = isPaused
        touchMonitor.isPaused = isPaused
        releaseHeldMouseInput()
    }

    private func updateFrontmostDisabled() {
        let bundleID = FrontmostApp.shared.bundleID
        let disabled = Preferences.shared.isAppDisabled(bundleID)
        // The menu bar says which app it is standing aside for, so a Mac where nothing
        // works never looks like a Mac where MouseNavigate has stopped.
        statusBarController?.disabledInApp = disabled
            ? bundleID.flatMap { Preferences.shared.appOverrides[$0]?.name } ?? bundleID
            : nil
        guard disabled != isFrontmostDisabled else { return }
        isFrontmostDisabled = disabled
        applyPauseState()
    }

    /// An accessory app shows no menu bar, but the key equivalents of its main menu still
    /// work while one of its windows is in front. Without one, ⌘C, ⌘V and ⌘A do nothing in
    /// the Settings window's text fields and ⌘W does not close it.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MouseNavigate", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // First responder actions: whichever text field has focus handles them.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsFromMenu() {
        showPreferences()
    }

    @objc private func quitFromMenu() {
        statusBarController?.onQuit?()
    }

    @objc private func deviceDidChange() {
        refreshScrollCache()
    }

    private func refreshScrollCache() {
        resolvedScroll = Preferences.shared.resolvedScrollSettings(
            profile: detector.activeProfile,
            app: FrontmostApp.shared.bundleID
        )
    }

    @objc private func preferencesDidChange() {
        updateFrontmostDisabled()
        refreshScrollCache()
        guard eventTap != nil, desiredEventMask != installedEventMask else { return }

        // The new tap would never see the key-up a hold is waiting on, nor a left
        // release once touch gestures are off.
        cursorEngine.forceExit()
        releaseHeldMouseInput()
        if !Preferences.shared.isTouchEnabled {
            isSwallowingLeftMouseUp = false
        }
        tearDownEventTap()
        if !installEventTap() {
            // Accessibility was taken away since the tap was first made. Say so, and keep
            // trying, exactly as at startup.
            waitForAccessibilityPermission()
        }
    }

    /// Lets go of anything held back mid-gesture, so no click is ever lost. A left press
    /// that was swallowed stays swallowed: its release must be too, whatever else is
    /// forgotten, just as the side buttons' are.
    private func releaseHeldMouseInput() {
        strokeCapture.cancel()
        scrollSession.reset()
        tapClicks.reset()
        buttons.reset()
        wheel.stop()
    }

    /// Quitting here would leave a first-time user with no icon and no explanation, so stay
    /// in the menu bar showing the permission warning. macOS posts nothing when the grant
    /// arrives, so poll for it and install the tap the moment it does.
    private func waitForAccessibilityPermission() {
        statusBarController?.isAwaitingPermission = true
        guard permissionTimer == nil else { return }

        permissionTimer = MainTimer(after: 1, repeating: 1) { [weak self] in
            guard let self, AXIsProcessTrusted(), self.installEventTap() else { return }

            self.permissionTimer = nil
            self.statusBarController?.isAwaitingPermission = false
            Log.permissions.info("Accessibility granted; now listening.")
        }
    }

    private func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let cause = type == .tapDisabledByTimeout ? "a timeout" : "user input"
            Log.tap.notice(
                "Event tap disabled by \(cause, privacy: .public); re-enabling and letting go of everything held."
            )
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            releaseAfterMissedEvents()
            if !AXIsProcessTrusted() {
                // Not from inside the tap's own callback.
                DispatchQueue.main.async { [weak self] in
                    guard self?.eventTap != nil else { return }
                    self?.accessibilityWasRevoked()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Our own synthetic events must never re-enter the state machine.
        if SyntheticEvents.isSynthetic(event) {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseUp, isPaused {
            // Pausing forgets every press in progress, but not that a press was swallowed:
            // its release is swallowed too, so the app never gets half a click.
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return buttons.buttonUp(button) ? nil : Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, isPaused, isSwallowingLeftMouseUp {
            isSwallowingLeftMouseUp = false
            return nil
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
            let modifiers = Shortcut.Modifiers(event.flags)
            return buttons.buttonDown(button, modifiers: modifiers, at: event.location) ? nil : Unmanaged.passUnretained(event)
        case .otherMouseDragged:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if button == 2 {
                // Only the middle button draws.
                return strokeCapture.handleDragged(.middle, at: event.location) ? nil : Unmanaged.passUnretained(event)
            }
            guard Preferences.configurableButtons.contains(button) else {
                return Unmanaged.passUnretained(event)
            }
            let delta = Vector2(
                x: event.getDoubleValueField(.mouseEventDeltaX),
                y: event.getDoubleValueField(.mouseEventDeltaY)
            )
            return buttons.buttonDragged(button, by: delta) ? nil : Unmanaged.passUnretained(event)
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
            guard resolvedScroll.isActive else { return Unmanaged.passUnretained(event) }
            return wheel.handle(event, settings: resolvedScroll) ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// See `ScrollSessionSuppressor`.
    private func shouldSuppressContinuousScroll(_ event: CGEvent) -> Bool {
        let phase = ScrollPhase(rawValue: Int(event.getIntegerValueField(.scrollWheelEventScrollPhase)))
        return scrollSession.shouldSuppress(phase: phase, gestureClaims: touchMonitor.shouldSuppressScroll)
    }

    /// A trackpad tap has just become a gesture; see `TapClickSuppressor` for why the
    /// click macOS makes of it is held back.
    private func trackpadTapBecameGesture() {
        tapClicks.tapBecameGesture(at: ProcessInfo.processInfo.systemUptime)
    }

    /// A Magic Mouse click with the fingers in the middle-click pose runs that gesture's
    /// action instead of clicking. A click that Tap to click made out of a trackpad tap
    /// which has just been a gesture is held back, release and all: the tap was spoken for.
    private func handleLeftMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Preferences.shared.isTouchEnabled else {
            return Unmanaged.passUnretained(event)
        }
        if tapClicks.leftMouseDown(at: ProcessInfo.processInfo.systemUptime) {
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
