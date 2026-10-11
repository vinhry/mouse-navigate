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
                if let taken = CursorBinding.allCases.first(where: {
                    $0 != binding && Preferences.shared.keyCode(for: $0) == keyCode
                }) {
                    Preferences.shared.setKeyCode(previous, for: taken)
                    self?.recorders[taken]?.update(keyCode: previous)
                }
                Preferences.shared.setKeyCode(keyCode, for: binding)
            }
            recorder.onRecordingChange = { [weak self] recording in
                // Stop the tap from eating the keystroke being recorded.
                self?.engine.isRecordingSuspended = recording
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
            if setting == .retypeWindow {
                slider.toolTip = "Holding the activate key is taken by cursor mode. "
                    + "Tap it and press it again within this time to type its letter "
                    + "instead, repeating for as long as it is held."
            }
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
        hint.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true

        return makePage(stack)
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
        Preferences.shared.restoreCursorDefaults()
        refreshCursorUI()
    }

    func refreshCursorUI() {
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
