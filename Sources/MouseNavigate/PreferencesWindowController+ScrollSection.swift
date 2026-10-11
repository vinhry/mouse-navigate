import AppKit
import MouseNavigateCore

/// The controls of the Scroll Wheel section, kept together so the section can be built
/// and refreshed away from the rest of the window.
final class ScrollSectionControls {
    var forLabel: NSTextField!
    var profilePopup: NSPopUpButton!
    var ownSettings: NSButton!
    var reversePopup: NSPopUpButton!
    var verticalSlider: NSSlider!
    var verticalLabel: NSTextField!
    var horizontalSlider: NSSlider!
    var horizontalLabel: NSTextField!
    var smooth: NSButton!
    var shift: NSButton!
    var option: NSButton!
    var command: NSButton!

    /// The mouse model being edited; nil is all mice. Only meaningful with no app chosen.
    var profile: DeviceProfile?

    var settingControls: [NSControl] {
        [reversePopup, verticalSlider, horizontalSlider, smooth, shift, option, command]
    }

    /// What the controls show, as settings.
    var settings: ScrollSettings {
        ScrollSettings(
            reverse: ScrollReverse.allCases[max(reversePopup.indexOfSelectedItem, 0)],
            verticalSpeed: verticalSlider.doubleValue,
            horizontalSpeed: horizontalSlider.doubleValue,
            isSmooth: smooth.state == .on,
            shiftSwapsAxes: shift.state == .on,
            optionIsPrecise: option.state == .on,
            commandIsFast: command.state == .on
        )
    }

    func show(_ settings: ScrollSettings) {
        reversePopup.selectItem(at: ScrollReverse.allCases.firstIndex(of: settings.reverse) ?? 0)
        verticalSlider.doubleValue = settings.verticalSpeed
        verticalLabel.stringValue = String(format: "%.1f×", settings.verticalSpeed)
        horizontalSlider.doubleValue = settings.horizontalSpeed
        horizontalLabel.stringValue = String(format: "%.1f×", settings.horizontalSpeed)
        smooth.state = settings.isSmooth ? .on : .off
        shift.state = settings.shiftSwapsAxes ? .on : .off
        option.state = settings.optionIsPrecise ? .on : .off
        command.state = settings.commandIsFast ? .on : .off
    }
}

/// The Scroll Wheel section of the Mouse tab. It follows the "Applies to" app scope the
/// pickers follow, and adds a scope of its own for the mouse model: an app's settings win
/// over the mouse's, which win over the ones for all.
extension PreferencesWindowController {
    /// Which settings the section is editing.
    private enum ScrollScope {
        case all
        case profile(DeviceProfile)
        case app(String)
    }

    private var scrollScope: ScrollScope {
        if let selectedApp { return .app(selectedApp) }
        if let profile = scrollSection?.profile { return .profile(profile) }
        return .all
    }

    func makeScrollSection() -> NSView {
        let controls = ScrollSectionControls()

        let forLabel = NSTextField(labelWithString: "For:")
        controls.forLabel = forLabel
        let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePopup.target = self
        profilePopup.action = #selector(scrollProfileChanged(_:))
        profilePopup.toolTip = "Settings for one mouse model apply whenever that mouse is the one in use."
        controls.profilePopup = profilePopup

        let own = NSButton(
            checkboxWithTitle: "Use its own scroll settings",
            target: self,
            action: #selector(scrollOwnSettingsChanged(_:))
        )
        own.toolTip = "Untick to follow the settings beneath: the mouse's for an app, all mice for a mouse."
        controls.ownSettings = own

        let scopeRow = NSStackView(views: [forLabel, profilePopup, own])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8
        scopeRow.detachesHiddenViews = false

        let reverseLabel = NSTextField(labelWithString: "Reverse:")
        let reversePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        reversePopup.target = self
        reversePopup.action = #selector(scrollSettingChanged(_:))
        for reverse in ScrollReverse.allCases {
            reversePopup.addItem(withTitle: reverse.displayName)
        }
        reversePopup.toolTip = "Only the mouse wheel changes, so a trackpad can keep natural scrolling. "
            + "Horizontal covers a thumb wheel."
        controls.reversePopup = reversePopup
        let reverseRow = NSStackView(views: [reverseLabel, reversePopup])
        reverseRow.orientation = .horizontal
        reverseRow.spacing = 8

        let (verticalRow, verticalSlider, verticalLabel) = makeSpeedRow(title: "Vertical speed:")
        controls.verticalSlider = verticalSlider
        controls.verticalLabel = verticalLabel
        let (horizontalRow, horizontalSlider, horizontalLabel) = makeSpeedRow(title: "Horizontal speed:")
        controls.horizontalSlider = horizontalSlider
        controls.horizontalLabel = horizontalLabel

        let smooth = NSButton(
            checkboxWithTitle: "Smooth scrolling (experimental)",
            target: self,
            action: #selector(scrollSettingChanged(_:))
        )
        smooth.toolTip = "Spreads each notch of the wheel over a few frames instead of jumping."
        controls.smooth = smooth

        let shift = NSButton(checkboxWithTitle: "⇧ scrolls sideways", target: self, action: #selector(scrollSettingChanged(_:)))
        shift.toolTip = "Hold Shift and the wheel scrolls horizontally. Shift is used up, so apps "
            + "that scroll sideways on Shift themselves do not do it twice."
        controls.shift = shift

        let option = NSButton(checkboxWithTitle: "⌥ scrolls precisely", target: self, action: #selector(scrollSettingChanged(_:)))
        option.toolTip = "Hold Option and each notch moves a quarter as far."
        controls.option = option

        let command = NSButton(checkboxWithTitle: "⌘ scrolls fast", target: self, action: #selector(scrollSettingChanged(_:)))
        command.toolTip = "Hold Command and each notch moves three times as far. Command is used "
            + "up, so a browser does not zoom as well."
        controls.command = command

        let modifiers = NSStackView(views: [shift, option, command])
        modifiers.orientation = .horizontal
        modifiers.spacing = 14

        let content = NSStackView(views: [scopeRow, reverseRow, verticalRow, horizontalRow, smooth, modifiers])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(12, after: scopeRow)

        scrollSection = controls
        refreshScrollUI()
        return makeSection(title: "Scroll Wheel", content: content)
    }

    private func makeSpeedRow(title: String) -> (NSView, NSSlider, NSTextField) {
        let label = NSTextField(labelWithString: title)
        let slider = NSSlider(
            value: 1,
            minValue: ScrollSettings.speedRange.lowerBound,
            maxValue: ScrollSettings.speedRange.upperBound,
            target: self,
            action: #selector(scrollSettingChanged(_:))
        )
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.spacing = 8
        return (row, slider, value)
    }

    // MARK: - Refresh

    func refreshScrollUI() {
        guard let controls = scrollSection else { return }
        let preferences = Preferences.shared

        // The mouse popup names the model in use, which can change while the window is up.
        let popup = controls.profilePopup!
        popup.removeAllItems()
        popup.addItem(withTitle: "All mice")
        for profile in DeviceProfile.allCases {
            let inUse = profile == detector.activeProfile ? " (in use)" : ""
            popup.addItem(withTitle: profile.displayName + inUse)
        }
        if let profile = controls.profile, let index = DeviceProfile.allCases.firstIndex(of: profile) {
            popup.selectItem(at: index + 1)
        } else {
            popup.selectItem(at: 0)
        }

        let shown: ScrollSettings
        let hasOwn: Bool
        var enabled = true
        // The checkbox names the scope it gives settings to, since nothing else in the
        // section says whether an app or a mouse is being edited.
        var ownTitle = "Use its own scroll settings"
        switch scrollScope {
        case .all:
            shown = preferences.scrollSettings
            hasOwn = true
            controls.forLabel.isHidden = false
            popup.isHidden = false
            controls.ownSettings.isHidden = true
        case .profile(let profile):
            let override = preferences.scrollOverride(for: profile)
            hasOwn = !override.isEmpty
            shown = ScrollResolver.resolve(global: preferences.scrollSettings, profile: override, app: nil)
            controls.forLabel.isHidden = false
            popup.isHidden = false
            controls.ownSettings.isHidden = false
            ownTitle += " for \(profile.displayName)"
        case .app(let bundleID):
            let override = preferences.appScrollOverride(bundleID)
            hasOwn = !override.isEmpty
            shown = preferences.resolvedScrollSettings(profile: detector.activeProfile, app: bundleID)
            // The mouse picker has no say in an app's settings, so the label goes with it.
            controls.forLabel.isHidden = true
            popup.isHidden = true
            controls.ownSettings.isHidden = false
            enabled = !preferences.isAppDisabled(bundleID)
            if let app = preferences.appOverrides[bundleID] {
                ownTitle += " for \(app.name)"
            }
        }
        controls.ownSettings.title = ownTitle

        controls.show(shown)
        controls.ownSettings.state = hasOwn ? .on : .off
        controls.ownSettings.isEnabled = enabled
        for control in controls.settingControls {
            control.isEnabled = enabled && hasOwn
        }
    }

    // MARK: - Actions

    @objc private func scrollProfileChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        scrollSection?.profile = index > 0 ? DeviceProfile.allCases[index - 1] : nil
        refreshScrollUI()
    }

    @objc private func scrollOwnSettingsChanged(_ sender: NSButton) {
        guard let controls = scrollSection else { return }
        // Starting its own settings from what the scope was getting anyway, so ticking the
        // box changes nothing until a control is moved.
        let override = sender.state == .on ? ScrollOverride(settings: controls.settings) : .none
        write(override)
        refreshScrollUI()
    }

    @objc private func scrollSettingChanged(_ sender: NSControl) {
        guard let controls = scrollSection else { return }
        let settings = controls.settings
        switch scrollScope {
        case .all:
            Preferences.shared.scrollSettings = settings
        case .profile, .app:
            write(ScrollOverride(settings: settings))
        }
        refreshScrollUI()
    }

    private func write(_ override: ScrollOverride) {
        switch scrollScope {
        case .all:
            Preferences.shared.scrollSettings = override.applied(to: .standard)
        case .profile(let profile):
            Preferences.shared.setScrollOverride(override, for: profile)
        case .app(let bundleID):
            Preferences.shared.setAppScrollOverride(override, app: bundleID)
        }
    }
}
