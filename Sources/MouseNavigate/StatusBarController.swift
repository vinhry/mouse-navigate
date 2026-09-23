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

    private let detector: DeviceDetector
    let preferencesController: PreferencesWindowController

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

    init(detector: DeviceDetector, preferencesController: PreferencesWindowController) {
        self.detector = detector
        self.preferencesController = preferencesController
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self

        addDisabledItem("MouseNavigate - v\(AppInfo.version)", to: menu)

        let device = NSMenuItem(title: "Detecting device…", action: nil, keyEquivalent: "")
        device.isEnabled = false
        menu.addItem(device)
        deviceMenuItem = device

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

        // Keyboard taps also need Input Monitoring on some configurations.
        let inputItem = NSMenuItem(
            title: "⚠ Grant Input Monitoring…",
            action: #selector(openInputMonitoringSettings),
            keyEquivalent: ""
        )
        inputItem.target = self
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
        detector.refresh()
        deviceMenuItem?.title = detector.statusDescription
    }

    // MARK: - Icon

    private func updateIcon() {
        let name: String
        if isAwaitingPermission {
            name = "exclamationmark.triangle"
        } else if isCursorModeActive {
            name = "cursorarrow.motionlines"
        } else if isPaused {
            name = "computermouse"
        } else {
            name = "computermouse.fill"
        }

        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem?.button?.image = image

        if isAwaitingPermission {
            statusItem?.button?.toolTip = "MouseNavigate – Needs Accessibility permission"
        } else if isCursorModeActive {
            statusItem?.button?.toolTip = "MouseNavigate – Cursor mode"
        } else {
            statusItem?.button?.toolTip = isPaused
                ? "MouseNavigate – Paused"
                : "MouseNavigate – Running"
        }
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
