import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import notify

private let supportedBundleIDs: Set<String> = [
    "com.apple.Safari",
    "com.apple.finder"
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

final class MouseNavigator {
    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    private static let lockFilePath = "/tmp/com.vinhry.MouseNavigate.lock"
    private static let quitRequestNotification = "com.vinhry.MouseNavigate.quitRequest"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lockFileDescriptor: CInt = -1

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
        defer { teardownSingleInstanceResources() }

        setbuf(stdout, nil)
        setbuf(stderr, nil)
        requestAccessibilityPermission()
        installEventTap()
        print("mouse-navigate daemon is running. Listening for side buttons.")
        CFRunLoopRun()
    }

    private func tryAcquireSingleInstanceLock() -> Bool {
        lockFileDescriptor = open(MouseNavigator.lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
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
        let executablePath = CommandLine.arguments[0]
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: executablePath)
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
        CFRunLoopStop(CFRunLoopGetMain())
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
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true
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

        guard type == .otherMouseDown else {
            return Unmanaged.passUnretained(event)
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        switch button {
        case 3:
            guard isSupportedFrontmostApp else {
                return Unmanaged.passUnretained(event)
            }
            sendShortcut(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand)
            return nil
        case 4:
            guard isSupportedFrontmostApp else {
                return Unmanaged.passUnretained(event)
            }
            sendShortcut(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand)
            return nil
        case 5:
            triggerSystemAppExpose()
            return nil
        case 6:
            triggerSystemMissionControl()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private var isSupportedFrontmostApp: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return supportedBundleIDs.contains(bundleID)
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
