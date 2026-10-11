import AppKit
import MouseNavigateCore

/// The controls of the Pointer section, kept together like the scroll section's.
@MainActor
final class PointerSectionControls {
    var profilePopup: NSPopUpButton!
    var ownSettings: NSButton!
    var speedSlider: NSSlider!
    var speedLabel: NSTextField!
    var accelerationPopup: NSPopUpButton!
    var accelerationSlider: NSSlider!
    var accelerationLabel: NSTextField!
    var accelerationRow: NSView!

    /// The mouse model being edited; nil is all mice.
    var profile: DeviceProfile?

    var settingControls: [NSControl] {
        [speedSlider, accelerationPopup, accelerationSlider]
    }

    var settings: PointerSettings {
        PointerSettings(
            speed: speedSlider.doubleValue,
            accelerationMode: PointerAccelerationMode.allCases[max(accelerationPopup.indexOfSelectedItem, 0)],
            acceleration: accelerationSlider.doubleValue
        )
    }

    func show(_ settings: PointerSettings) {
        speedSlider.doubleValue = settings.speed
        speedLabel.stringValue = String(format: "%.2f×", settings.speed)
        accelerationPopup.selectItem(at: PointerAccelerationMode.allCases.firstIndex(of: settings.accelerationMode) ?? 0)
        accelerationSlider.doubleValue = settings.acceleration
        accelerationLabel.stringValue = String(format: "%.2f", settings.acceleration)
        // The curve's own slider only means something once a curve of its own is chosen.
        accelerationRow.isHidden = settings.accelerationMode != .custom
    }
}

/// The Pointer section of the Mouse tab: how far and how fast a mouse moves the pointer,
/// for all mice or one mouse model. It is the same in every app, so it ignores "Applies to".
extension PreferencesWindowController {
    func makePointerSection() -> NSView {
        let controls = PointerSectionControls()

        let forLabel = NSTextField(labelWithString: "For:")
        let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePopup.target = self
        profilePopup.action = #selector(pointerProfileChanged(_:))
        profilePopup.toolTip = "Settings for one mouse model apply whenever that mouse is the one in use."
        controls.profilePopup = profilePopup
        let scopeRow = NSStackView(views: [forLabel, profilePopup])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8
        PreferencesWindowController.titleControls(in: [forLabel, profilePopup])

        let own = NSButton(checkboxWithTitle: "Use its own pointer settings", target: self, action: #selector(pointerOwnSettingsChanged(_:)))
        own.toolTip = "Untick to follow the settings for all mice."
        controls.ownSettings = own

        let speedTitle = NSTextField(labelWithString: "Speed:")
        let speedSlider = makeSlider(
            value: 1,
            range: PointerSettings.speedRange,
            width: 140,
            action: #selector(pointerSettingChanged(_:))
        )
        speedSlider.toolTip = "How far the pointer goes for the same movement of the mouse. 1× leaves it "
            + "as it comes; Tracking speed in System Settings still applies on top."
        controls.speedSlider = speedSlider
        let speedLabel = PreferencesWindowController.makeValueLabel(width: 44)
        controls.speedLabel = speedLabel
        let speedRow = NSStackView(views: [speedTitle, speedSlider, speedLabel])
        speedRow.orientation = .horizontal
        speedRow.spacing = 8
        PreferencesWindowController.titleControls(in: [speedTitle, speedSlider])

        let accelerationTitle = NSTextField(labelWithString: "Acceleration:")
        let accelerationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        accelerationPopup.target = self
        accelerationPopup.action = #selector(pointerSettingChanged(_:))
        accelerationPopup.addItems(withTitles: PointerAccelerationMode.allCases.map(\.displayName))
        accelerationPopup.toolTip = "How much faster the pointer goes the faster the mouse moves. Off moves "
            + "it in proportion, as games and drawing want."
        controls.accelerationPopup = accelerationPopup
        let accelerationModeRow = NSStackView(views: [accelerationTitle, accelerationPopup])
        accelerationModeRow.orientation = .horizontal
        accelerationModeRow.spacing = 8
        PreferencesWindowController.titleControls(in: [accelerationTitle, accelerationPopup])

        let curveTitle = NSTextField(labelWithString: "Curve:")
        let accelerationSlider = makeSlider(
            value: 1,
            range: PointerSettings.accelerationRange,
            width: 140,
            action: #selector(pointerSettingChanged(_:))
        )
        accelerationSlider.toolTip = "On System Settings' own scale, from none to the most."
        controls.accelerationSlider = accelerationSlider
        let accelerationLabel = PreferencesWindowController.makeValueLabel(width: 44)
        controls.accelerationLabel = accelerationLabel
        let curveRow = NSStackView(views: [curveTitle, accelerationSlider, accelerationLabel])
        curveRow.orientation = .horizontal
        curveRow.spacing = 8
        PreferencesWindowController.titleControls(in: [curveTitle, accelerationSlider])
        controls.accelerationRow = curveRow

        let note = NSTextField(labelWithString: "The same in every app. Trackpads are never changed.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let content = NSStackView(views: [scopeRow, own, speedRow, accelerationModeRow, curveRow, note])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(12, after: own)

        pointerSection = controls
        refreshPointerUI()
        return makeSection(title: "Pointer", content: content)
    }

    func refreshPointerUI() {
        guard let controls = pointerSection else { return }
        let preferences = Preferences.shared

        let popup = controls.profilePopup!
        popup.removeAllItems()
        popup.addItem(withTitle: "All mice")
        for profile in DeviceProfile.allCases {
            let inUse = profile == detector.activeProfile ? " (in use)" : ""
            popup.addItem(withTitle: profile.displayName + inUse)
        }

        let shown: PointerSettings
        let hasOwn: Bool
        if let profile = controls.profile, let index = DeviceProfile.allCases.firstIndex(of: profile) {
            popup.selectItem(at: index + 1)
            let override = preferences.pointerOverride(for: profile)
            hasOwn = !override.isEmpty
            shown = override.applied(to: preferences.pointerSettings)
            controls.ownSettings.isHidden = false
            controls.ownSettings.title = "Use its own pointer settings for \(profile.displayName)"
        } else {
            popup.selectItem(at: 0)
            hasOwn = true
            shown = preferences.pointerSettings
            controls.ownSettings.isHidden = true
        }

        controls.show(shown)
        controls.ownSettings.state = hasOwn ? .on : .off
        for control in controls.settingControls {
            control.isEnabled = hasOwn
        }
    }

    @objc private func pointerProfileChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        pointerSection?.profile = index > 0 ? DeviceProfile.allCases[index - 1] : nil
        refreshPointerUI()
    }

    @objc private func pointerOwnSettingsChanged(_ sender: NSButton) {
        guard let controls = pointerSection, let profile = controls.profile else { return }
        // Starting from what the mouse was getting anyway, so ticking the box changes
        // nothing until a control is moved.
        let override = sender.state == .on ? PointerOverride(settings: controls.settings) : .none
        Preferences.shared.setPointerOverride(override, for: profile)
        refreshPointerUI()
    }

    @objc private func pointerSettingChanged(_ sender: NSControl) {
        guard let controls = pointerSection else { return }
        let settings = controls.settings
        if let profile = controls.profile {
            Preferences.shared.setPointerOverride(PointerOverride(settings: settings), for: profile)
        } else {
            Preferences.shared.pointerSettings = settings
        }
        refreshPointerUI()
    }
}
