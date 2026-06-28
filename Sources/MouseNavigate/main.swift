import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import ServiceManagement
import notify

private let supportedBundleIDs: Set<String> = [
    // Apple
    "com.apple.Safari",
    "com.apple.finder",
    // Google
    "com.google.Chrome",
    "com.google.Chrome.canary",
    // Mozilla
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    // Arc
    "company.thebrowser.Browser",
    // Brave
    "com.brave.Browser",
    "com.brave.Browser.beta",
    // Microsoft
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    // Opera
    "com.operasoftware.Opera",
    // Vivaldi
    "com.vivaldi.Vivaldi",
    // Orion
    "com.kagi.kagimacOS",
]

private final class SecondaryLaunchDialogController: NSObject {
    private let panel: NSPanel

    init(icon: NSImage?) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "MouseNavigate"
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24)
        ])

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72)
        ])
        stack.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "MouseNavigate is already running")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Click Quit to stop the current instance.")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        stack.addArrangedSubview(subtitleLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        let okButton = NSButton(title: "OK", target: self, action: #selector(okTapped))
        okButton.keyEquivalent = "\r"

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitTapped))

        buttonRow.addArrangedSubview(okButton)
        buttonRow.addArrangedSubview(quitButton)
        stack.addArrangedSubview(buttonRow)
    }

    func run() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = app.runModal(for: panel)
        panel.orderOut(nil)

        return response == .OK
    }

    @objc private func okTapped() {
        NSApp.stopModal(withCode: .cancel)
    }

    @objc private func quitTapped() {
        NSApp.stopModal(withCode: .OK)
    }
}

private enum ButtonAction: String, CaseIterable {
    case back = "back"
    case forward = "forward"
    case appExpose = "appExpose"
    case missionControl = "missionControl"
    case disabled = "disabled"

    var displayName: String {
        switch self {
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        case .appExpose: return "App Exposé"
        case .missionControl: return "Mission Control"
        case .disabled: return "Disabled"
        }
    }
}

private final class ButtonConfig {
    static let shared = ButtonConfig()

    private static let defaultActions: [Int: ButtonAction] = [
        3: .back,
        4: .forward,
        5: .appExpose,
        6: .missionControl,
    ]

    private let store: UserDefaults

    private init() {
        store = UserDefaults(suiteName: "com.vinhry.MouseNavigate") ?? .standard
    }

    func action(forButton button: Int) -> ButtonAction {
        guard let raw = store.string(forKey: "button\(button)"),
              let action = ButtonAction(rawValue: raw)
        else {
            return Self.defaultActions[button] ?? .disabled
        }
        return action
    }

    func setAction(_ action: ButtonAction, forButton button: Int) {
        store.set(action.rawValue, forKey: "button\(button)")
    }
}

private final class PreferencesWindowController: NSObject {
    private var panel: NSPanel?

    func showOrFocus() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Button Mapping"
        p.isReleasedWhenClosed = false
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating

        let content = p.contentView!

        var rows: [[NSView]] = []
        for button in 3...6 {
            let label = NSTextField(labelWithString: "Button \(button):")
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.tag = button
            popup.target = self
            popup.action = #selector(popupChanged(_:))
            popup.translatesAutoresizingMaskIntoConstraints = false
            for action in ButtonAction.allCases {
                popup.addItem(withTitle: action.displayName)
            }
            let currentIndex = ButtonAction.allCases.firstIndex(
                of: ButtonConfig.shared.action(forButton: button)
            ) ?? 0
            popup.selectItem(at: currentIndex)

            rows.append([label, popup])
        }

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        content.addSubview(grid)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(closeButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        let button = sender.tag
        let idx = sender.indexOfSelectedItem
        let actions = ButtonAction.allCases
        guard idx >= 0, idx < actions.count else { return }
        ButtonConfig.shared.setAction(actions[idx], forButton: button)
    }

    @objc private func closeTapped() {
        panel?.orderOut(nil)
    }
}

private final class StatusBarController: NSObject, NSMenuDelegate {
    private static let appVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var permissionSeparator: NSMenuItem?

    private let preferencesController = PreferencesWindowController()

    var onQuit: (() -> Void)?
    var onPauseToggle: ((Bool) -> Void)?

    private(set) var isPaused = false {
        didSet {
            updateIcon()
            pauseMenuItem?.title = isPaused ? "Resume" : "Pause"
        }
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self

        addDisabledItem("MouseNavigate", to: menu)
        addDisabledItem("v\(Self.appVersion)", to: menu)
        menu.addItem(.separator())

        // Accessibility permission warning — shown only when not trusted
        let permItem = NSMenuItem(
            title: "⚠ Grant Accessibility Permission…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permItem.target = self
        permItem.isHidden = true
        menu.addItem(permItem)
        permissionMenuItem = permItem

        let permSep = NSMenuItem.separator()
        permSep.isHidden = true
        menu.addItem(permSep)
        permissionSeparator = permSep

        // Pause / Resume
        let pauseItem = NSMenuItem(title: "Pause", action: #selector(pauseToggleTapped), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem

        menu.addItem(.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(launchAtLoginTapped), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        launchAtLoginMenuItem = loginItem

        menu.addItem(.separator())

        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences\u{2026}", action: #selector(preferencesTapped), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit MouseNavigate", action: #selector(quitTapped), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionWarning()
        updateLaunchAtLoginState()
    }

    // MARK: - Icon

    private func updateIcon() {
        let name = isPaused ? "computermouse" : "computermouse.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = isPaused ? "MouseNavigate – Paused" : "MouseNavigate – Running"
    }

    // MARK: - Pause

    @objc private func pauseToggleTapped() {
        isPaused.toggle()
        onPauseToggle?(isPaused)
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLoginState() {
        launchAtLoginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func launchAtLoginTapped() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Silently ignore — typically fails when not running from a signed app bundle
        }
        updateLaunchAtLoginState()
    }

    // MARK: - Accessibility

    private func updatePermissionWarning() {
        let trusted = AXIsProcessTrusted()
        permissionMenuItem?.isHidden = trusted
        permissionSeparator?.isHidden = trusted
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Preferences

    @objc private func preferencesTapped() {
        preferencesController.showOrFocus()
    }

    // MARK: - Quit

    @objc private func quitTapped() {
        onQuit?()
    }

    // MARK: - Helpers

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}

final class MouseNavigator {
    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    private static let lockFilePath = "/tmp/com.vinhry.MouseNavigate.lock"
    private static let quitRequestNotification = "com.vinhry.MouseNavigate.quitRequest"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lockFileDescriptor: CInt = -1
    private var statusBarController: StatusBarController?
    private var isPaused = false

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
        installEventTap()

        let controller = StatusBarController()
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onPauseToggle = { [weak self] paused in self?.isPaused = paused }
        controller.setup()
        statusBarController = controller

        NSApplication.shared.setActivationPolicy(.accessory)
        print("mouse-navigate daemon is running. Listening for side buttons.")
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

    private func installEventTap() {
        let mask = CGEventMask(1) << CGEventType.otherMouseDown.rawValue

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
            exit(1)
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            fputs("Failed to create run loop source.\n", stderr)
            exit(1)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard !isPaused, type == .otherMouseDown else {
            return Unmanaged.passUnretained(event)
        }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        return performAction(ButtonConfig.shared.action(forButton: button), event: event)
    }

    private var isSupportedFrontmostApp: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return supportedBundleIDs.contains(bundleID)
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

let navigator = MouseNavigator()
let isAppBundleLaunch = Bundle.main.bundleURL.pathExtension == "app"
let forceDaemon = CommandLine.arguments.contains("--daemon")

if forceDaemon || !isAppBundleLaunch {
    navigator.runDaemon()
} else {
    navigator.runLauncher()
}
