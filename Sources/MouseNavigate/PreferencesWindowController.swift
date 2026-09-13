import AppKit
import MouseNavigateCore

/// Two-tab preferences: mouse button mapping per device profile, and keyboard cursor
/// bindings plus speed tuning.
final class PreferencesWindowController: NSObject {
    private var panel: NSPanel?

    private let detector: DeviceDetector
    private let engine: KeyboardCursorEngine

    private var deviceLabel: NSTextField?
    private var overridePopup: NSPopUpButton?
    private var buttonPopups: [Int: NSPopUpButton] = [:]
    private var testerLabel: NSTextField?

    private var recorders: [CursorBinding: KeyRecorderButton] = [:]
    private var sliders: [CursorSetting: NSSlider] = [:]
    private var sliderValueLabels: [CursorSetting: NSTextField] = [:]
    private var enableCheckbox: NSButton?

    private var lastButtonPressed: Int?

    init(detector: DeviceDetector, engine: KeyboardCursorEngine) {
        self.detector = detector
        self.engine = engine
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidChange),
            name: DeviceDetector.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Window

    func showOrFocus() {
        if let panel {
            refreshDeviceUI()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "MouseNavigate Preferences"
        p.isReleasedWhenClosed = false
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating
        p.hidesOnDeactivate = false

        let content = p.contentView!

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        let mouseTab = NSTabViewItem(identifier: "mouse")
        mouseTab.label = "Mouse"
        mouseTab.view = makeMouseTab()
        tabView.addTabViewItem(mouseTab)

        let cursorTab = NSTabViewItem(identifier: "cursor")
        cursorTab.label = "Keyboard Cursor"
        cursorTab.view = makeCursorTab()
        tabView.addTabViewItem(cursorTab)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p

        refreshDeviceUI()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Mouse tab

    private func makeMouseTab() -> NSView {
        let view = NSView()

        let label = NSTextField(labelWithString: "Detecting…")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        deviceLabel = label

        let overrideLabel = NSTextField(labelWithString: "Profile:")
        overrideLabel.alignment = .right

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(overrideChanged(_:))
        popup.addItem(withTitle: "Automatic")
        for profile in DeviceProfile.allCases {
            popup.addItem(withTitle: profile.displayName)
        }
        overridePopup = popup

        var rows: [[NSView]] = [[overrideLabel, popup]]

        for button in Preferences.configurableButtons {
            let buttonLabel = NSTextField(labelWithString: "Button \(button):")
            buttonLabel.alignment = .right

            let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            actionPopup.tag = button
            actionPopup.target = self
            actionPopup.action = #selector(buttonActionChanged(_:))
            for action in ButtonAction.allCases {
                actionPopup.addItem(withTitle: action.displayName)
            }
            buttonPopups[button] = actionPopup

            rows.append([buttonLabel, actionPopup])
        }

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        view.addSubview(grid)

        let tester = NSTextField(labelWithString: "Press a mouse button to identify it…")
        tester.font = .systemFont(ofSize: 11)
        tester.textColor = .secondaryLabelColor
        tester.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tester)
        testerLabel = tester

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            tester.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            tester.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            tester.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        return view
    }

    // MARK: - Cursor tab

    private func makeCursorTab() -> NSView {
        let view = NSView()

        let checkbox = NSButton(
            checkboxWithTitle: "Enable keyboard cursor control",
            target: self,
            action: #selector(enabledChanged(_:))
        )
        checkbox.state = Preferences.shared.isCursorModeEnabled ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checkbox)
        enableCheckbox = checkbox

        let hint = NSTextField(
            labelWithString: "Hold the activate key, then use the movement keys. "
                + "Shift speeds up, Shift+Ctrl is fastest, Option is precise."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 400
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        var rows: [[NSView]] = []

        for binding in CursorBinding.allCases {
            let label = NSTextField(labelWithString: "\(binding.displayName):")
            label.alignment = .right

            let recorder = KeyRecorderButton(
                binding: binding,
                keyCode: Preferences.shared.keyCode(for: binding)
            )
            recorder.onRecord = { keyCode in
                Preferences.shared.setKeyCode(keyCode, for: binding)
            }
            recorder.onRecordingChange = { [weak self] recording in
                // Stop the tap from eating the keystroke being recorded.
                self?.engine.isSuspended = recording
            }
            recorders[binding] = recorder

            rows.append([label, recorder])
        }

        for setting in CursorSetting.allCases {
            let label = NSTextField(labelWithString: "\(setting.displayName):")
            label.alignment = .right

            let slider = NSSlider(
                value: Preferences.shared.value(for: setting),
                minValue: setting.range.lowerBound,
                maxValue: setting.range.upperBound,
                target: self,
                action: #selector(sliderChanged(_:))
            )
            slider.tag = CursorSetting.allCases.firstIndex(of: setting) ?? 0
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            sliders[setting] = slider

            let valueLabel = NSTextField(labelWithString: "")
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            valueLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
            sliderValueLabels[setting] = valueLabel
            updateValueLabel(for: setting)

            rows.append([label, slider, valueLabel])
        }

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        view.addSubview(grid)

        let restore = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restoreDefaultsTapped)
        )
        restore.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(restore)

        NSLayoutConstraint.activate([
            checkbox.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            checkbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            hint.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            restore.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            restore.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        return view
    }

    // MARK: - Live button tester

    /// Called from the event tap so users can discover their own mouse's numbering.
    func reportButtonPress(_ button: Int) {
        lastButtonPressed = button
        guard isVisible else { return }

        DispatchQueue.main.async { [weak self] in
            self?.testerLabel?.stringValue =
                "Last button pressed: \(button)"
        }
    }

    // MARK: - Actions

    @objc private func deviceDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDeviceUI()
        }
    }

    private func refreshDeviceUI() {
        deviceLabel?.stringValue = detector.statusDescription

        if let override = Preferences.shared.deviceOverride,
           let index = DeviceProfile.allCases.firstIndex(of: override) {
            overridePopup?.selectItem(at: index + 1)
        } else {
            overridePopup?.selectItem(at: 0)
        }

        let profile = detector.activeProfile
        for (button, popup) in buttonPopups {
            let action = Preferences.shared.action(forButton: button, profile: profile)
            let index = ButtonAction.allCases.firstIndex(of: action) ?? 0
            popup.selectItem(at: index)
        }
    }

    @objc private func overrideChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index == 0 {
            Preferences.shared.deviceOverride = nil
        } else {
            let profiles = DeviceProfile.allCases
            guard index - 1 < profiles.count else { return }
            Preferences.shared.deviceOverride = profiles[index - 1]
        }
        refreshDeviceUI()
    }

    @objc private func buttonActionChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let actions = ButtonAction.allCases
        guard index >= 0, index < actions.count else { return }
        Preferences.shared.setAction(
            actions[index],
            forButton: sender.tag,
            profile: detector.activeProfile
        )
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        Preferences.shared.isCursorModeEnabled = sender.state == .on
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let settings = CursorSetting.allCases
        guard sender.tag >= 0, sender.tag < settings.count else { return }

        let setting = settings[sender.tag]
        Preferences.shared.setValue(sender.doubleValue, for: setting)
        updateValueLabel(for: setting)
    }

    private func updateValueLabel(for setting: CursorSetting) {
        let value = Preferences.shared.value(for: setting)
        let formatted: String
        switch setting {
        case .holdThreshold, .acceleration:
            formatted = String(format: "%.2f %@", value, setting.unit)
        case .fastMultiplier, .fasterMultiplier, .precisionMultiplier:
            formatted = String(format: "%.2f%@", value, setting.unit)
        default:
            formatted = String(format: "%.0f %@", value, setting.unit)
        }
        sliderValueLabels[setting]?.stringValue = formatted
    }

    @objc private func restoreDefaultsTapped() {
        Preferences.shared.restoreCursorDefaults()

        enableCheckbox?.state = Preferences.shared.isCursorModeEnabled ? .on : .off
        for (binding, recorder) in recorders {
            recorder.update(keyCode: Preferences.shared.keyCode(for: binding))
        }
        for (setting, slider) in sliders {
            slider.doubleValue = Preferences.shared.value(for: setting)
            updateValueLabel(for: setting)
        }
    }
}
