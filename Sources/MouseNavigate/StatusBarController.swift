import AppKit
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem
import MouseNavigateCore
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var permissionSeparator: NSMenuItem?
    private var inputMonitoringMenuItem: NSMenuItem?
    private var deviceMenuItem: NSMenuItem?
    private var offInAppMenuItem: NSMenuItem?
    private var installUpdateMenuItem: NSMenuItem?
    private var installUpdateSeparator: NSMenuItem?

    private let detector: DeviceDetector

    /// Assigned once startup has built it. The icon goes up before this exists, because
    /// nothing that can stall is allowed to run ahead of the menu bar item.
    var preferencesController: PreferencesWindowController?
    /// Assigned with the preferences, for the same reason.
    var updater: Updater?

    var onQuit: (() -> Void)?
    var onPauseToggle: ((Bool) -> Void)?

    private(set) var isPaused = false {
        didSet {
            updateIcon()
            pauseMenuItem?.title = isPaused ? "Resume" : "Pause"
        }
    }

    /// Cursor mode captures keystrokes, so the icon has to make that obvious.
    var isCursorModeActive = false {
        didSet { updateIcon() }
    }

    /// Nothing works until Accessibility is granted, so the icon has to say so.
    var isAwaitingPermission = false {
        didSet { updateIcon() }
    }

    /// The name of the app in front when MouseNavigate is turned off in it, or nil. Shown
    /// like a pause, because to the user that is what it is.
    var disabledInApp: String? {
        didSet {
            guard disabledInApp != oldValue else { return }
            updateIcon()
            offInAppMenuItem?.isHidden = disabledInApp == nil
            offInAppMenuItem?.title = disabledInApp.map { "Off in \($0)" } ?? ""
        }
    }

    init(detector: DeviceDetector) {
        self.detector = detector
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self

        addDisabledItem("MouseNavigate \(AppInfo.version)", to: menu)

        let device = NSMenuItem(title: "Detecting device…", action: nil, keyEquivalent: "")
        device.isEnabled = false
        menu.addItem(device)
        deviceMenuItem = device

        let offInApp = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        offInApp.isEnabled = false
        offInApp.isHidden = true
        menu.addItem(offInApp)
        offInAppMenuItem = offInApp

        menu.addItem(.separator())

        // Shown only once an update has been downloaded and verified.
        let installItem = NSMenuItem(title: "Install Update and Relaunch", action: #selector(installUpdateTapped), keyEquivalent: "")
        installItem.target = self
        installItem.isHidden = true
        menu.addItem(installItem)
        installUpdateMenuItem = installItem

        let installSeparator = NSMenuItem.separator()
        installSeparator.isHidden = true
        menu.addItem(installSeparator)
        installUpdateSeparator = installSeparator

        // Accessibility permission warning — shown only when not trusted
        let permItem = NSMenuItem(
            title: "Grant Accessibility Permission…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permItem.target = self
        permItem.image = Self.warningImage
        permItem.isHidden = true
        menu.addItem(permItem)
        permissionMenuItem = permItem

        // Keyboard taps also need Input Monitoring on some configurations.
        let inputItem = NSMenuItem(
            title: "Grant Input Monitoring…",
            action: #selector(openInputMonitoringSettings),
            keyEquivalent: ""
        )
        inputItem.target = self
        inputItem.image = Self.warningImage
        inputItem.isHidden = true
        menu.addItem(inputItem)
        inputMonitoringMenuItem = inputItem

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

        let updatesItem = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdatesTapped), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        // Settings. The shortcuts match the main menu, which is what makes them work while
        // the Settings window is in front.
        let prefsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(preferencesTapped), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit MouseNavigate", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionWarning()
        updateLaunchAtLoginState()
        detector.refresh()
        deviceMenuItem?.title = detector.statusDescription

        let ready = updater?.readyVersion
        installUpdateMenuItem?.isHidden = ready == nil
        installUpdateSeparator?.isHidden = ready == nil
        if let ready {
            installUpdateMenuItem?.title = "Install MouseNavigate \(ready) and Relaunch"
        }
    }

    // MARK: - Icon

    private static let warningImage: NSImage? = {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
        image?.isTemplate = true
        return image
    }()

    private func updateIcon() {
        let name: String
        let state: String
        if isAwaitingPermission {
            name = "exclamationmark.triangle"
            state = "Needs Accessibility permission"
        } else if isCursorModeActive {
            name = "cursorarrow.motionlines"
            state = "Cursor mode"
        } else if isPaused {
            name = "computermouse"
            state = "Paused"
        } else if let disabledInApp {
            name = "computermouse"
            state = "Off in \(disabledInApp)"
        } else {
            name = "computermouse.fill"
            state = "Running"
        }

        // The description is what VoiceOver reads for the item, so it carries the state the
        // glyph only hints at.
        let description = "MouseNavigate, \(state.lowercased())"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        // A nil image leaves an invisible but clickable square, which reads to anyone
        // looking at their menu bar as "the app did not start". Say something instead.
        statusItem?.button?.title = image == nil ? "MN" : ""
        statusItem?.button?.setAccessibilityLabel(description)
        statusItem?.button?.toolTip = "MouseNavigate – \(state)"
        statusItem?.isVisible = true
    }

    // MARK: - Pause

    @objc private func pauseToggleTapped() {
        isPaused.toggle()
        onPauseToggle?(isPaused)
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLoginMenuItem?.state = status == .enabled ? .on : .off
        // Registered, but macOS is holding it until the user allows it in System Settings;
        // registering again would change nothing, so say what will.
        launchAtLoginMenuItem?.title = status == .requiresApproval
            ? "Launch at Login (needs approval in System Settings)"
            : "Launch at Login"
    }

    @objc private func launchAtLoginTapped() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            // Typically an unsigned or unbundled build, which macOS will not start at login.
            Log.launch.error("Launch at Login could not be changed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Launch at Login couldn't be changed"
            alert.informativeText = error.localizedDescription
                + "\n\nmacOS starts only a signed copy that runs from an app bundle at login, "
                + "so a build run from source or from the Terminal cannot be registered."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateLaunchAtLoginState()
    }

    // MARK: - Permissions

    private func updatePermissionWarning() {
        let trusted = AXIsProcessTrusted()
        permissionMenuItem?.isHidden = trusted

        let inputMonitoringDenied = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
        inputMonitoringMenuItem?.isHidden = !inputMonitoringDenied

        permissionSeparator?.isHidden = trusted && !inputMonitoringDenied
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Updates

    @objc private func installUpdateTapped() {
        updater?.installAndRelaunch()
    }

    @objc private func checkForUpdatesTapped() {
        updater?.check(userInitiated: true)
    }

    // MARK: - Settings

    @objc func preferencesTapped() {
        preferencesController?.showOrFocus()
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
