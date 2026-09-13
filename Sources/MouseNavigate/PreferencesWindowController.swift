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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
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

        let mousePage = makeMouseTab()
        let mouseTab = NSTabViewItem(identifier: "mouse")
        mouseTab.label = "Mouse"
        mouseTab.view = mousePage
        tabView.addTabViewItem(mouseTab)

        let cursorPage = makeCursorTab()
        let cursorTab = NSTabViewItem(identifier: "cursor")
        cursorTab.label = "Keyboard Cursor"
        cursorTab.view = cursorPage
        tabView.addTabViewItem(cursorTab)

        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])

        // A tab view takes no size from its pages, so size the window to the larger page
        // plus the tab chrome. A fixed size clipped the cursor tab's lower rows.
        let pages = [mousePage.fittingSize, cursorPage.fittingSize]
        let probe = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        tabView.frame = probe
        let chromeWidth = probe.width - tabView.contentRect.width
        let chromeHeight = probe.height - tabView.contentRect.height
        p.setContentSize(NSSize(
            width: (pages.map(\.width).max() ?? 0) + chromeWidth + margin * 2,
            height: (pages.map(\.height).max() ?? 0) + chromeHeight + margin * 2
        ))

        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p

        refreshDeviceUI()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Mouse tab

    private func makeMouseTab() -> NSView {
        let label = NSTextField(labelWithString: "Detecting…")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
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
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
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

        let grid = makeFormGrid(rows, rowSpacing: 8)
        // Every picker takes the width of the widest, so the column reads as one edge.
        grid.column(at: 1).xPlacement = .fill
        // Keep the profile picker visually apart from the per-button rows.
        grid.row(at: 0).bottomPadding = 8

        let tester = NSTextField(labelWithString: "Press a mouse button to identify it…")
        tester.font = .systemFont(ofSize: 11)
        tester.textColor = .secondaryLabelColor
        testerLabel = tester

        let stack = NSStackView(views: [label, grid, tester])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: grid)

        return makePage(stack)
    }

    // MARK: - Layout helpers

    /// Wraps a tab's content with margins. Trailing and bottom are inequalities so the
    /// page can be handed more room than it needs, which also lets `fittingSize` report
    /// the size it actually needs.
    private func makePage(_ content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            content.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -16),
        ])

        return page
    }

    /// Right-aligned labels in the first column, controls vertically centred on them.
    private func makeFormGrid(_ rows: [[NSView]], rowSpacing: CGFloat) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        // Pin the natural height. Beside a taller section the grid would otherwise stretch
        // and pour the spare height into arbitrary rows, and its internal spacing
        // constraints are too weak for content hugging to hold it without squashing rows.
        let naturalHeight = grid.heightAnchor.constraint(equalToConstant: grid.fittingSize.height)
        naturalHeight.priority = .init(999)
        naturalHeight.isActive = true
        return grid
    }

    private func makeSection(title: String, content: NSView) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        return section
    }

    // MARK: - Cursor tab

    private func makeCursorTab() -> NSView {
        let checkbox = NSButton(
            checkboxWithTitle: "Enable keyboard cursor control",
            target: self,
            action: #selector(enabledChanged(_:))
        )
        checkbox.state = Preferences.shared.isCursorModeEnabled ? .on : .off
        enableCheckbox = checkbox

        let hint = NSTextField(
            labelWithString: "Hold the activate key, then use the movement keys. "
                + "Shift is faster, Shift+Ctrl fastest, Option precise."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        var keyRows: [[NSView]] = []

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

            keyRows.append([label, recorder])
        }

        var speedRows: [[NSView]] = []
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
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
            sliders[setting] = slider

            let valueLabel = NSTextField(labelWithString: "")
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            valueLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
            sliderValueLabels[setting] = valueLabel
            updateValueLabel(for: setting)

            speedRows.append([label, slider, valueLabel])
        }

        // Keys and speed side by side: stacked, the two lists outgrow a laptop screen.
        let sections = NSStackView(views: [
            makeSection(title: "Keys", content: makeFormGrid(keyRows, rowSpacing: 6)),
            makeSection(title: "Speed", content: makeFormGrid(speedRows, rowSpacing: 12)),
        ])
        sections.orientation = .horizontal
        sections.alignment = .top
        sections.spacing = 36

        let restore = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restoreDefaultsTapped)
        )

        // Pushes Restore Defaults to the trailing edge of the row.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, restore])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [checkbox, hint, sections, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(18, after: hint)
        stack.setCustomSpacing(16, after: sections)
        footer.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true

        return makePage(stack)
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
