import AppKit
import MouseNavigateCore

/// The Keyboard Cursor tab: switching it on, rebinding its keys and tuning its speeds.
extension PreferencesWindowController {
    // MARK: - Cursor tab

    func makeCursorTab() -> NSView {
        let checkbox = NSButton(
            checkboxWithTitle: "Enable keyboard cursor control",
            target: self,
            action: #selector(enabledChanged(_:))
        )
        checkbox.state = Preferences.shared.isCursorModeEnabled ? .on : .off
        enableCheckbox = checkbox

        // Wrapped to the width of the two sections below: on one line it is wider than
        // anything else in the window, and would set the width of every tab. A wrapping
        // label still asks for its whole text in one line, at the same priority the
        // sections hug their grids, so it has to ask more weakly than anything else.
        let hint = NSTextField(
            wrappingLabelWithString: "Hold the activate key, then use the movement keys. "
                + "Shift is faster, Shift+Ctrl fastest, Option precise. "
                + "Tap it and press again to type its letter instead."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        var keyRows: [[NSView]] = []

        for binding in CursorBinding.allCases {
            let label = NSTextField(labelWithString: "\(binding.displayName):")
            label.alignment = .right

            let recorder = KeyRecorderButton(
                binding: binding,
                keyCode: Preferences.shared.keyCode(for: binding)
            )
            recorder.onRecord = { [weak self] keyCode in
                // A key already doing something else swaps: it takes this binding's old key
                // rather than being claimed twice, which would leave one of them unreachable.
                let previous = Preferences.shared.keyCode(for: binding)
                var note = ""
                if let taken = CursorBinding.allCases.first(where: {
                    $0 != binding && Preferences.shared.keyCode(for: $0) == keyCode
                }) {
                    Preferences.shared.setKeyCode(previous, for: taken)
                    self?.recorders[taken]?.update(keyCode: previous)
                    // Said, since the other key changed without being touched.
                    let name = KeyboardLayout.shared.name(for: keyCode)
                    note = "\(name) was \(taken.displayName); \(taken.displayName) and "
                        + "\(binding.displayName) have swapped keys."
                }
                Preferences.shared.setKeyCode(keyCode, for: binding)
                self?.keySwapNote?.stringValue = note
            }
            recorder.onRecordingChange = { [weak self] recording in
                // Stop the tap from eating the keystroke being recorded.
                self?.engine.isRecordingSuspended = recording
            }
            recorders[binding] = recorder

            keyRows.append([label, recorder])
        }

        // Under the grid, empty until two keys swap and emptied by the next change. It keeps
        // its line, so the window does not change height when a note appears.
        let swapNote = NSTextField(wrappingLabelWithString: " ")
        swapNote.font = .systemFont(ofSize: 11)
        swapNote.textColor = .secondaryLabelColor
        swapNote.translatesAutoresizingMaskIntoConstraints = false
        swapNote.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        swapNote.widthAnchor.constraint(equalToConstant: 220).isActive = true
        // Two lines, whether or not there is a note.
        swapNote.heightAnchor.constraint(equalToConstant: 30).isActive = true
        keySwapNote = swapNote

        var speedRows: [[NSView]] = []
        for setting in CursorSetting.allCases {
            let label = NSTextField(labelWithString: "\(setting.displayName):")
            label.alignment = .right

            let slider = makeSlider(
                value: Preferences.shared.value(for: setting),
                range: setting.range,
                width: 160,
                action: #selector(sliderChanged(_:))
            )
            slider.tag = CursorSetting.allCases.firstIndex(of: setting) ?? 0
            if setting == .retypeWindow {
                slider.toolTip = "Holding the activate key is taken by cursor mode. "
                    + "Tap it and press it again within this time to type its letter "
                    + "instead, repeating for as long as it is held."
            }
            sliders[setting] = slider

            let valueLabel = PreferencesWindowController.makeValueLabel(width: 64)
            sliderValueLabels[setting] = valueLabel
            updateValueLabel(for: setting)

            speedRows.append([label, slider, valueLabel])
        }

        // Keys and speed side by side: stacked, the two lists outgrow a laptop screen.
        let sections = NSStackView(views: [
            makeSection(title: "Keys", content: keysContent(grid: makeFormGrid(keyRows, rowSpacing: 6), note: swapNote)),
            makeSection(title: "Speed", content: makeFormGrid(speedRows, rowSpacing: 12)),
        ])
        sections.orientation = .horizontal
        sections.alignment = .top
        sections.spacing = 36

        let footer = makeRestoreDefaultsFooter(action: #selector(restoreDefaultsTapped))

        let stack = NSStackView(views: [checkbox, hint, sections, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(18, after: hint)
        stack.setCustomSpacing(16, after: sections)
        footer.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true

        return makePage(stack)
    }

    private func keysContent(grid: NSView, note: NSView) -> NSView {
        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    @objc func enabledChanged(_ sender: NSButton) {
        Preferences.shared.isCursorModeEnabled = sender.state == .on
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let settings = CursorSetting.allCases
        guard sender.tag >= 0, sender.tag < settings.count else { return }

        let setting = settings[sender.tag]
        Preferences.shared.setValue(sender.doubleValue, for: setting)
        updateValueLabel(for: setting)
    }

    func updateValueLabel(for setting: CursorSetting) {
        let value = Preferences.shared.value(for: setting)
        let formatted: String
        switch setting {
        case .retypeWindow where value == 0:
            // The one tunable with an off position; "0.00 s" would not say so.
            formatted = "Off"
        case .holdThreshold, .retypeWindow, .acceleration:
            formatted = String(format: "%.2f %@", value, setting.unit)
        case .fastMultiplier, .fasterMultiplier, .precisionMultiplier:
            formatted = String(format: "%.2f%@", value, setting.unit)
        default:
            formatted = String(format: "%.0f %@", value, setting.unit)
        }
        sliderValueLabels[setting]?.stringValue = formatted
    }

    @objc func restoreDefaultsTapped() {
        guard let window else { return }
        AlertPresenter.confirmDestructive(
            "Restore the keyboard cursor defaults?",
            "The keys and the speed settings of the keyboard cursor go back to their defaults. "
                + "Whether it is switched on, buttons, gestures and scroll settings are kept.",
            confirm: "Restore",
            on: window
        ) { [weak self] in
            Preferences.shared.restoreCursorDefaults()
            self?.refreshCursorUI()
        }
    }

    func refreshCursorUI() {
        keySwapNote?.stringValue = ""
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
