import AppKit
import MouseNavigateCore

/// Building blocks every tab is laid out with.
extension PreferencesWindowController {
    // MARK: - Layout helpers

    /// Wraps a tab's content with margins. Trailing and bottom are inequalities so the
    /// page can be handed more room than it needs, which also lets `fittingSize` report
    /// the size it actually needs.
    func makePage(_ content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)

        // The bottom margin yields rather than being required: a page a point short of its
        // content then overflows the margin by that point, where a required constraint
        // AppKit had to drop would take the layout with it.
        let bottom = content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -16)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            content.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 20),
            bottom,
        ])

        return page
    }

    /// Right-aligned labels in the first column, controls vertically centred on them.
    func makeFormGrid(_ rows: [[NSView]], rowSpacing: CGFloat) -> NSGridView {
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
        for row in rows {
            PreferencesWindowController.titleControls(in: row)
        }
        return grid
    }

    /// Hands the row's leading label to accessibility as the title of each control beside
    /// it. A grid does not do this itself, so VoiceOver would read a picker as "pop up
    /// button, Back" with no button number, and a slider as nothing but its value.
    static func titleControls(in row: [NSView]) {
        guard let label = row.first as? NSTextField, !label.isEditable, !label.stringValue.isEmpty else { return }
        for control in row.dropFirst() where control is NSControl && !(control is NSTextField) {
            control.setAccessibilityTitleUIElement(label)
        }
    }

    /// A slider of a fixed width, for a row with its label before it and its value after.
    func makeSlider(value: Double, range: ClosedRange<Double>, width: CGFloat, action: Selector) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: self,
            action: action
        )
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        return slider
    }

    /// The value beside a slider: small, grey, in monospaced digits and a fixed width, so the
    /// row keeps still as the value changes.
    static func makeValueLabel(width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// Restore Defaults at the trailing edge of a row, which the tab makes as wide as its
    /// content.
    func makeRestoreDefaultsFooter(action: Selector) -> NSStackView {
        let restore = NSButton(title: "Restore Defaults", target: self, action: action)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, restore])
        footer.orientation = .horizontal
        return footer
    }

    func makeSection(title: String, content: NSView) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        return section
    }
}

/// A picker that says when it takes keyboard focus, so what hovering shows can be shown
/// for the row that was tabbed to.
final class FocusReportingPopUpButton: NSPopUpButton {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }
}

/// Lays out subviews from the top, as a scroll view's document should.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Reports where the pointer is inside a scrolling list, so the row under it can be shown.
final class HoverTrackingView: FlippedView {
    var onHover: ((NSPoint?, NSView) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil), self)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil, self)
    }
}
