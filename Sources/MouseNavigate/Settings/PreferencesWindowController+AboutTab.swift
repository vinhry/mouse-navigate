import AppKit
import MouseNavigateCore

/// The About tab: who made it, the license, and updates. Export and import are in their
/// own file.
extension PreferencesWindowController {
    // MARK: - About tab

    func makeAboutTab() -> NSView {
        let iconView = NSImageView()
        iconView.image = AppInfo.icon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
        ])

        let name = NSTextField(labelWithString: AppInfo.name)
        name.font = .systemFont(ofSize: 20, weight: .semibold)

        let versionText = AppInfo.build.map { "Version \(AppInfo.version) (\($0))" }
            ?? "Version \(AppInfo.version)"
        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true

        let tagline = NSTextField(wrappingLabelWithString: AppInfo.tagline)
        tagline.alignment = .center
        tagline.translatesAutoresizingMaskIntoConstraints = false
        tagline.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        let developer = NSTextField(labelWithString: "Developed by \(AppInfo.developer)")

        let links = NSStackView(views: [
            makeLinkButton(title: "GitHub", url: AppInfo.repositoryURL),
            makeLinkButton(title: "Report an Issue", url: AppInfo.issuesURL),
        ])
        links.orientation = .horizontal
        links.spacing = 12

        let legal = NSTextField(labelWithString: "Released under the \(AppInfo.license). \(AppInfo.copyright).")
        legal.font = .systemFont(ofSize: 11)
        legal.textColor = .secondaryLabelColor

        let updates = makeUpdatesSection()
        let stack = NSStackView(views: [iconView, name, version, tagline, developer, links, legal, updates, makeTransferSection()])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(14, after: version)
        stack.setCustomSpacing(14, after: tagline)
        stack.setCustomSpacing(12, after: developer)
        stack.setCustomSpacing(18, after: links)
        stack.setCustomSpacing(28, after: legal)
        stack.setCustomSpacing(18, after: updates)

        return makePage(stack)
    }

    func makeUpdatesSection() -> NSView {
        let automatic = NSButton(
            checkboxWithTitle: "Check for updates automatically",
            target: self,
            action: #selector(automaticUpdatesChanged(_:))
        )
        // A copy that could never install an update has nothing to check for.
        automatic.isEnabled = updater.canSelfUpdate
        automatic.toolTip = updater.canSelfUpdate
            ? "Once a day, from GitHub. Updates are downloaded and checked in the "
                + "background, and installed only when you choose to."
            : "Only a release signed with a Developer ID, installed from GitHub, updates itself."
        automaticUpdatesCheckbox = automatic

        let checkNow = NSButton(title: "Check Now", target: self, action: #selector(checkForUpdatesTapped))
        checkNow.bezelStyle = .rounded

        let row = NSStackView(views: [automatic, checkNow])
        row.orientation = .horizontal
        row.spacing = 16

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        updateStatusLabel = status

        let section = NSStackView(views: [row, status])
        section.orientation = .vertical
        section.alignment = .centerX
        section.spacing = 6
        refreshUpdatesUI()
        return section
    }

    func refreshUpdatesUI() {
        automaticUpdatesCheckbox?.state = Preferences.shared.automaticUpdates == true ? .on : .off

        let text: String
        switch updater.state {
        case .checking:
            text = "Checking for updates…"
        case .downloading(let version):
            text = "Downloading version \(version)…"
        case .ready(let staged):
            text = "Version \(staged.version) is ready — Install and Relaunch is in the menu bar menu."
        case .installing(let version):
            text = "Installing version \(version)…"
        case .failed(let message):
            text = message
        case .upToDate, .idle:
            if !updater.canSelfUpdate {
                // The checkbox above is greyed out; say why where it can be read.
                text = "Only a release signed with a Developer ID, installed from GitHub, updates itself."
            } else if let last = Preferences.shared.lastUpdateCheck {
                let formatter = RelativeDateTimeFormatter()
                text = "Up to date. Last checked \(formatter.localizedString(for: last, relativeTo: Date()))."
            } else {
                text = "Not checked yet."
            }
        }
        updateStatusLabel?.stringValue = text
        updateStatusLabel?.toolTip = text
    }

    @objc func updaterDidChange() {
        refreshUpdatesUI()
    }

    @objc func automaticUpdatesChanged(_ sender: NSButton) {
        Preferences.shared.automaticUpdates = sender.state == .on
        if sender.state == .on, UpdateSchedule.isDue(lastCheck: Preferences.shared.lastUpdateCheck, now: Date()) {
            updater.check(userInitiated: false)
        }
    }

    @objc func checkForUpdatesTapped() {
        updater.check(userInitiated: true)
    }

    func makeLinkButton(title: String, url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        button.toolTip = url.absoluteString
        return button
    }

    @objc func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}
