import AppKit
import MouseNavigateCore

/// The Mouse tab: the device in use, the press and modifier pickers, a picker per button
/// and the live button tester. The scroll section is in its own file.
extension PreferencesWindowController {
    // MARK: - Mouse tab

    func makeMouseTab() -> NSView {
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

        let pressLabel = NSTextField(labelWithString: "Press:")
        pressLabel.alignment = .right
        let pressPicker = NSSegmentedControl(
            labels: PreferencesWindowController.buttonInputs.map(\.displayName),
            trackingMode: .selectOne,
            target: self,
            action: #selector(buttonPressChanged(_:))
        )
        pressPicker.selectedSegment = 0
        pressPicker.toolTip = "Which press of each button the pickers below show. A dot marks one with "
            + "bindings. A button with a hold, double-click or drag binding waits to see which "
            + "it was before acting, so bind those only where you want them. A drag is the "
            + "button held while the mouse moves that way."
        self.pressPicker = pressPicker

        let withLabel = NSTextField(labelWithString: "With:")
        withLabel.alignment = .right
        let modifierPicker = NSSegmentedControl(
            labels: PreferencesWindowController.modifierSegments.map(\.label),
            trackingMode: .selectAny,
            target: self,
            action: #selector(buttonModifiersChanged(_:))
        )
        modifierPicker.toolTip = "Bind a button pressed with these keys held. A dot marks a key with "
            + "bindings for this press. Until a combination has a binding of its own, holding "
            + "the keys does what the button does on its own."
        self.modifierPicker = modifierPicker
        for picker in [pressPicker, modifierPicker] {
            PreferencesWindowController.reserveMarkerRoom(in: picker)
        }

        // Says what the pickers below are for, so they read as the bindings of one press
        // rather than as settings of their own.
        let caption = NSTextField(labelWithString: "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        slotCaption = caption

        var rows: [[NSView]] = [
            [overrideLabel, popup], [pressLabel, pressPicker], [withLabel, modifierPicker],
            [NSTextField(labelWithString: ""), caption],
        ]

        for button in Preferences.configurableButtons {
            let buttonLabel = NSTextField(labelWithString: "Button \(button):")
            buttonLabel.alignment = .right

            let actionPopup = makeBindingPopup(for: .button(button))

            rows.append([buttonLabel, actionPopup])
        }

        let grid = makeFormGrid(rows, rowSpacing: 8)
        // Every picker takes the width of the widest, so the column reads as one edge.
        grid.column(at: 1).xPlacement = .fill
        // Keep the profile, press and modifier pickers visually apart from the per-button rows.
        grid.row(at: 2).bottomPadding = 10
        grid.row(at: 3).bottomPadding = 2
        grid.cell(for: pressPicker)?.xPlacement = .leading
        grid.cell(for: modifierPicker)?.xPlacement = .leading

        let tester = NSTextField(labelWithString: "Press a mouse button to identify it…")
        tester.font = .systemFont(ofSize: 11)
        tester.textColor = .secondaryLabelColor
        testerLabel = tester

        let restore = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restoreMouseDefaultsTapped)
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, restore])
        footer.orientation = .horizontal

        let scroll = makeScrollSection()
        let stack = NSStackView(views: [label, makeScopeRow(), grid, tester, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(22, after: tester)
        stack.setCustomSpacing(16, after: scroll)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return makePage(stack)
    }

    /// Fixes each segment at the width its label needs with the marker on, so marking one
    /// later never moves the others.
    static func reserveMarkerRoom(in picker: NSSegmentedControl) {
        let font = picker.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        for segment in 0..<picker.segmentCount {
            let label = (picker.label(forSegment: segment) ?? "") + boundMarker
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            picker.setWidth(ceil(width) + 14, forSegment: segment)
        }
    }

    /// Marks the presses and modifier keys that have bindings for the profile in the
    /// current scope, and names the ones on show.
    func updateBindingMarkers() {
        guard let pressPicker, let modifierPicker else { return }
        let bound = Preferences.shared.boundButtonCombinations(profile: detector.activeProfile, app: selectedApp)
        for (index, input) in PreferencesWindowController.buttonInputs.enumerated() {
            let marked = bound.contains(ButtonCombination(input: input, modifiers: buttonModifiers))
            pressPicker.setLabel(input.displayName + (marked ? Self.boundMarker : ""), forSegment: index)
        }
        for (index, segment) in PreferencesWindowController.modifierSegments.enumerated() {
            let marked = bound.contains { $0.input == buttonInput && $0.modifiers.contains(segment.modifier) }
            modifierPicker.setLabel(segment.label + (marked ? Self.boundMarker : ""), forSegment: index)
        }

        let shown = buttonInput.displayName
        slotCaption?.stringValue = buttonModifiers.isEmpty
            ? "Showing the \(shown) bindings"
            : "Showing the \(shown) bindings with \(buttonModifiers.symbols) held"
    }

    /// In one app's scope this hands its buttons and wheel back to the settings for all
    /// apps; otherwise it resets the mouse in use.
    @objc func restoreMouseDefaultsTapped() {
        guard let window else { return }
        let profile = detector.activeProfile
        let title: String
        let message: String
        if let selectedApp, let app = Preferences.shared.appOverrides[selectedApp] {
            title = "Restore the mouse defaults for \(app.name)?"
            message = "\(app.name) gives up its own button bindings and scroll settings and "
                + "goes back to the ones for all apps. Its gestures are kept."
        } else {
            title = "Restore the mouse defaults for the \(profile.displayName)?"
            message = "Every button binding of the \(profile.displayName), for every press "
                + "and modifier combination, goes back to its default, and so do the scroll settings "
                + "for all mice and for this mouse. Other mice, apps' own settings, gestures and the "
                + "keyboard cursor are kept."
        }
        AlertPresenter.sheet(title, message, buttons: ["Restore", "Cancel"], on: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let selectedApp = self.selectedApp {
                Preferences.shared.clearAppBindings(app: selectedApp) { key in
                    [
                        SettingsKey.buttonPrefix, SettingsKey.buttonHoldPrefix,
                        SettingsKey.buttonDoublePrefix, SettingsKey.buttonDragPrefix,
                    ].contains(where: key.hasPrefix)
                }
                Preferences.shared.setAppScrollOverride(.none, app: selectedApp)
            } else {
                Preferences.shared.restoreMouseDefaults(profile: profile)
            }
            self.refreshDeviceUI()
        }
    }

    /// ⌃⌥⇧⌘ in menu order, one segment each.
    static let modifierSegments: [(label: String, modifier: Shortcut.Modifiers)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command),
    ]

    @objc func buttonModifiersChanged(_ sender: NSSegmentedControl) {
        var modifiers: Shortcut.Modifiers = []
        for (index, segment) in PreferencesWindowController.modifierSegments.enumerated()
        where sender.isSelected(forSegment: index) {
            modifiers.insert(segment.modifier)
        }
        buttonModifiers = modifiers
        refreshBindings(where: \.isButton)
    }

    @objc func buttonPressChanged(_ sender: NSSegmentedControl) {
        guard PreferencesWindowController.buttonInputs.indices.contains(sender.selectedSegment) else { return }
        buttonInput = PreferencesWindowController.buttonInputs[sender.selectedSegment]
        refreshBindings(where: \.isButton)
    }

    // MARK: - Live button tester

    /// Called from the event tap so users can discover their own mouse's numbering.
    func reportButtonPress(_ button: Int) {
        guard isVisible else { return }

        DispatchQueue.main.async { [weak self] in
            self?.testerLabel?.stringValue =
                "Last button pressed: \(button)"
        }
    }

    @objc func deviceDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDeviceUI()
        }
    }

    func refreshDeviceUI() {
        deviceLabel?.stringValue = detector.statusDescription
        refreshScrollUI()

        if let override = Preferences.shared.deviceOverride,
           let index = DeviceProfile.allCases.firstIndex(of: override) {
            overridePopup?.selectItem(at: index + 1)
        } else {
            overridePopup?.selectItem(at: 0)
        }

        refreshBindings(where: \.isButton)
    }

    @objc func overrideChanged(_ sender: NSPopUpButton) {
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
}
