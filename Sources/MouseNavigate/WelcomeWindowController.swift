import AppKit
import MouseNavigateCore

/// What a new install shows first: the permissions MouseNavigate needs from macOS, each
/// with its state kept current while the window is open, and the two choices worth making
/// before anything else. It takes the place of the Accessibility prompt and the update
/// question that used to arrive one after the other on their own.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let updater: Updater
    /// Opens the Settings window, for the button here.
    var onOpenSettings: (() -> Void)?

    private var window: NSWindow?
    /// Runs while the window is open: permissions are granted in System Settings, and
    /// macOS says nothing when they are.
    private var refreshTimer: MainTimer?
    private var accessibilityRow: PermissionRow?
    private var inputMonitoringRow: PermissionRow?
    private var loginCheckbox: NSButton?
    private var updatesCheckbox: NSButton?

    /// The window's content, inside its margins; everything is laid out to it.
    private static let contentWidth: CGFloat = 480
    /// The intro beside the icon.
    private static let textWidth: CGFloat = contentWidth - 56 - 16

    init(updater: Updater) {
        self.updater = updater
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let isNew = window == nil
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        refreshTimer = MainTimer(after: 1, repeating: 1) { [weak self] in
            self?.refresh()
        }
        if isNew {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to MouseNavigate"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView()
        icon.image = AppInfo.icon()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])

        let title = NSTextField(labelWithString: "Welcome to MouseNavigate")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let intro = Self.wrappingLabel(
            "MouseNavigate lives in the menu bar. To see your mouse buttons, wheel and keys it needs "
                + "one permission from macOS. Everything else can be set up later in Settings.",
            size: 13
        )
        let heading = NSStackView(views: [title, intro])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 6
        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16

        let accessibility = PermissionRow(
            title: "Accessibility",
            detail: "Lets MouseNavigate see side buttons, the wheel and the keyboard cursor's keys, "
                + "and move windows. Nothing works without it.",
            target: self,
            action: #selector(grantAccessibilityTapped)
        )
        accessibilityRow = accessibility
        let inputMonitoring = PermissionRow(
            title: "Input Monitoring (optional)",
            detail: "Only needed if the keyboard cursor's keys do nothing once Accessibility is on.",
            target: self,
            action: #selector(inputMonitoringTapped)
        )
        inputMonitoringRow = inputMonitoring

        let login = NSButton(checkboxWithTitle: "Open MouseNavigate at login", target: self, action: #selector(loginChanged(_:)))
        loginCheckbox = login
        let updates = NSButton(
            checkboxWithTitle: "Check for updates automatically",
            target: nil,
            action: nil
        )
        updates.state = (Preferences.shared.automaticUpdates ?? true) ? .on : .off
        updates.toolTip = "Once a day, from GitHub. A new version is downloaded and checked in the "
            + "background, and installed only when you choose Install and Relaunch from the menu."
        // A copy that could never install an update has nothing to ask.
        updates.isHidden = !updater.canSelfUpdate
        updatesCheckbox = updates
        let choices = NSStackView(views: [login, updates])
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 8

        let settings = NSButton(title: "Open Settings…", target: self, action: #selector(openSettingsTapped))
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, settings, done])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [header, accessibility.view, inputMonitoring.view, choices, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(24, after: choices)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A fixed width, so the wrapping text knows its room rather than the window guessing.
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 48).isActive = true
        for row in [accessibility.view, inputMonitoring.view, buttons] {
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    private static func wrappingLabel(_ text: String, size: CGFloat, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        if secondary {
            label.textColor = .secondaryLabelColor
        }
        label.preferredMaxLayoutWidth = textWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return label
    }

    // MARK: - State

    private func refresh() {
        let trusted = Permissions.isAccessibilityGranted
        accessibilityRow?.show(granted: trusted, buttonTitle: "Grant Access…")

        switch Permissions.inputMonitoring {
        case .granted:
            inputMonitoringRow?.show(granted: true, buttonTitle: nil)
        case .denied:
            inputMonitoringRow?.show(granted: false, buttonTitle: "Open Settings…")
        case .notAsked:
            inputMonitoringRow?.show(granted: false, buttonTitle: "Allow…", isOptional: true)
        }

        loginCheckbox?.state = LoginItem.isEnabled || LoginItem.needsApproval ? .on : .off
        loginCheckbox?.title = LoginItem.needsApproval
            ? "Open MouseNavigate at login (approve it in System Settings)"
            : "Open MouseNavigate at login"
    }

    // MARK: - Actions

    @objc private func grantAccessibilityTapped() {
        // macOS's own prompt, which also puts MouseNavigate on the list in System Settings
        // and offers to open it there.
        Permissions.requestAccessibility()
    }

    @objc private func inputMonitoringTapped() {
        if Permissions.inputMonitoring == .notAsked {
            Permissions.requestInputMonitoring()
        } else {
            SystemSettingsPane.inputMonitoring.open()
        }
    }

    @objc private func loginChanged(_ sender: NSButton) {
        LoginItem.set(sender.state == .on)
        refresh()
    }

    @objc private func openSettingsTapped() {
        window?.close()
        onOpenSettings?()
    }

    @objc private func doneTapped() {
        window?.close()
    }

    /// However the window closes, what it asked is answered.
    func windowWillClose(_ notification: Notification) {
        refreshTimer = nil
        if let updatesCheckbox, !updatesCheckbox.isHidden {
            Preferences.shared.automaticUpdates = updatesCheckbox.state == .on
        }
        Preferences.shared.hasCompletedOnboarding = true
    }
}

/// One permission: what it is for, whether it is granted, and a way to grant it.
@MainActor
private final class PermissionRow {
    let view: NSStackView
    private let status: NSTextField
    private let symbol: NSImageView
    private let button: NSButton

    init(title: String, detail: String, target: AnyObject, action: Selector) {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 300
        explanation.translatesAutoresizingMaskIntoConstraints = false
        explanation.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let text = NSStackView(views: [name, explanation])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        symbol = NSImageView()
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        button = NSButton(title: "", target: target, action: action)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        view = NSStackView(views: [text, spacer, symbol, status, button])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 6
        view.setCustomSpacing(12, after: status)
        button.setAccessibilityLabel(title)
    }

    func show(granted: Bool, buttonTitle: String?, isOptional: Bool = false) {
        let name = granted ? "checkmark.circle.fill" : (isOptional ? "circle" : "exclamationmark.triangle.fill")
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbol.contentTintColor = granted ? .systemGreen : (isOptional ? .tertiaryLabelColor : .systemOrange)
        status.stringValue = granted ? "Allowed" : (isOptional ? "Not needed yet" : "Not allowed yet")
        button.isHidden = granted || buttonTitle == nil
        if let buttonTitle {
            button.title = buttonTitle
        }
    }
}
