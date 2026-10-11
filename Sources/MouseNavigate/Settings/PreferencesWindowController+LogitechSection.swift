import AppKit
import MouseNavigateCore

/// The Logitech controls of the mouse in use, bound like the side buttons above, with the
/// same press and modifier pickers. Shown only for a model that has them.
extension PreferencesWindowController {
    func makeLogitechSection() -> NSView {
        var rows: [[NSView]] = []
        for control in LogitechControl.allCases {
            let label = NSTextField(labelWithString: "\(control.displayName):")
            label.alignment = .right
            let popup = makeBindingPopup(for: .button(control.button))
            switch control {
            case .modeShift:
                popup.toolTip = "Once bound, it no longer switches the wheel between ratchet and free spin."
            case .hapticPanel:
                popup.toolTip = "The panel above the thumb on an MX Master 4."
            case .gestureButton:
                popup.toolTip = "The button under the thumb."
            }
            rows.append([label, popup])
        }
        let grid = makeFormGrid(rows, rowSpacing: 8)
        grid.column(at: 1).xPlacement = .fill
        logitechGrid = grid

        let note = NSTextField(wrappingLabelWithString: "Taken from the mouse over Bluetooth while it has a binding.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 260

        let content = NSStackView(views: [grid, note])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        let section = makeSection(title: "Logitech Buttons", content: content)
        logitechSection = section
        refreshLogitechRows()
        return section
    }

    /// Only the controls the model in use has.
    func refreshLogitechRows() {
        let available = LogitechControl.controls(for: detector.activeProfile)
        for (index, control) in LogitechControl.allCases.enumerated() {
            logitechGrid?.row(at: index).isHidden = !available.contains(control)
        }
        logitechSection?.isHidden = available.isEmpty
    }
}
