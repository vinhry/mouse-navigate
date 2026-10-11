import AppKit
import MouseNavigateCore

/// "Applies to": the app whose own bindings and scroll settings the tabs show, if any.
extension PreferencesWindowController {
    // MARK: - App scope

    /// "Applies to" with the apps that have bindings of their own. Built once per tab that
    /// binds anything; every copy shows the same scope.
    func makeScopeRow() -> NSView {
        let label = NSTextField(labelWithString: "Applies to:")

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(scopeChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        popup.cell?.lineBreakMode = .byTruncatingTail

        let remove = NSButton(title: "Remove App", target: self, action: #selector(removeAppTapped))
        remove.bezelStyle = .rounded

        let disable = NSButton(
            checkboxWithTitle: "Turn off MouseNavigate in this app",
            target: self,
            action: #selector(appDisabledChanged(_:))
        )
        disable.toolTip = "Buttons, gestures and the keyboard cursor all stand aside while this app is in front."

        let row = NSStackView(views: [label, popup, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        PreferencesWindowController.titleControls(in: [label, popup])

        let stack = NSStackView(views: [row, disable])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // Hidden views keep their room, so choosing an app never changes the page's height.
        stack.detachesHiddenViews = false
        row.detachesHiddenViews = false

        scopeControls.append((popup, remove, disable))
        return stack
    }

    func refreshScopeUI() {
        let apps = Preferences.shared.overriddenApps
        if let selectedApp, !apps.contains(where: { $0.bundleID == selectedApp }) {
            self.selectedApp = nil
        }

        for control in scopeControls {
            let popup = control.popup
            popup.removeAllItems()
            popup.addItem(withTitle: "All Apps")
            popup.lastItem?.representedObject = ""
            if !apps.isEmpty {
                popup.menu?.addItem(.separator())
                for app in apps {
                    popup.addItem(withTitle: app.name)
                    popup.lastItem?.representedObject = app.bundleID
                    popup.lastItem?.toolTip = app.bundleID
                }
            }
            popup.menu?.addItem(.separator())
            popup.addItem(withTitle: "Add App…")
            popup.lastItem?.representedObject = PickerCommand.addApp

            popup.selectItem(at: max(popup.indexOfItem(withRepresentedObject: selectedApp ?? ""), 0))

            control.remove.isHidden = selectedApp == nil
            control.disable.isHidden = selectedApp == nil
            control.disable.state = Preferences.shared.isAppDisabled(selectedApp) ? .on : .off
        }
        refreshBindings()
        refreshScrollUI()
        // The scope decides which bindings the warning speaks of, and whether any fire.
        refreshTrackpadConflictUI()
    }

    @objc func scopeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        guard value == PickerCommand.addApp else {
            selectedApp = value.isEmpty ? nil : value
            refreshScopeUI()
            return
        }

        guard let window else { return }
        editor.chooseApp(message: "Choose an app to give settings of its own", in: window) { [weak self] app in
            guard let self else { return }
            if let app {
                Preferences.shared.addApp(bundleID: app.bundleID, name: app.name)
                self.selectedApp = app.bundleID
            }
            self.refreshScopeUI()
        }
    }

    @objc func removeAppTapped() {
        guard let window, let selectedApp,
              let app = Preferences.shared.appOverrides[selectedApp]
        else {
            return
        }

        AlertPresenter.sheet(
            "Remove \(app.name)?",
            "Its own bindings and scroll settings are deleted, MouseNavigate is "
                + "turned back on in it, and it goes back to the settings for all apps.",
            buttons: ["Remove", "Cancel"],
            on: window
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Preferences.shared.removeApp(bundleID: selectedApp)
            self?.selectedApp = nil
            self?.refreshScopeUI()
        }
    }

    @objc func appDisabledChanged(_ sender: NSButton) {
        guard let selectedApp else { return }
        Preferences.shared.setApp(selectedApp, disabled: sender.state == .on)
        refreshScopeUI()
    }
}
