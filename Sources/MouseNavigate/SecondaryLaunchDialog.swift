import AppKit

final class SecondaryLaunchDialogController: NSObject {
    private let panel: NSPanel

    init(icon: NSImage?) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "MouseNavigate"
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24)
        ])

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72)
        ])
        stack.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "MouseNavigate is already running")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Click Quit to stop the current instance.")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        stack.addArrangedSubview(subtitleLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12

        let okButton = NSButton(title: "OK", target: self, action: #selector(okTapped))
        okButton.keyEquivalent = "\r"

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitTapped))

        buttonRow.addArrangedSubview(okButton)
        buttonRow.addArrangedSubview(quitButton)
        stack.addArrangedSubview(buttonRow)
    }

    func run() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = app.runModal(for: panel)
        panel.orderOut(nil)

        return response == .OK
    }

    @objc private func okTapped() {
        NSApp.stopModal(withCode: .cancel)
    }

    @objc private func quitTapped() {
        NSApp.stopModal(withCode: .OK)
    }
}
