import AppKit
import MouseNavigateCore

/// The Touch tab: trackpad and Magic Mouse gestures, drawn characters, and their previews.
extension PreferencesWindowController {
    // MARK: - Touch tab

    func makeTouchTab() -> NSView {
        let enable = NSButton(
            checkboxWithTitle: "Enable touch gestures",
            target: self,
            action: #selector(touchEnabledChanged(_:))
        )
        touchEnableCheckbox = enable

        let leftHanded = NSButton(
            checkboxWithTitle: "Left-handed",
            target: self,
            action: #selector(leftHandedChanged(_:))
        )
        leftHandedCheckbox = leftHanded

        let toggles = NSStackView(views: [enable, leftHanded])
        toggles.orientation = .horizontal
        toggles.spacing = 24
        toggles.setHuggingPriority(.required, for: .horizontal)

        let ignoreTyping = NSButton(
            checkboxWithTitle: "Ignore touches while typing",
            target: self,
            action: #selector(ignoreTypingChanged(_:))
        )
        ignoreTyping.toolTip = "Fingers and palms that land on the trackpad while you type, and for half a second after, are not gestures."
        ignoreTypingCheckbox = ignoreTyping

        let ignoreMouseMoving = NSButton(
            checkboxWithTitle: "Ignore taps while the mouse is moving",
            target: self,
            action: #selector(ignoreMouseMovingChanged(_:))
        )
        ignoreMouseMoving.toolTip = "A finger that touches a Magic Mouse while you are moving it is gripping it, not tapping."
        ignoreMouseMovingCheckbox = ignoreMouseMoving

        // A row of its own: the two together are wider than the hint's 580 points would
        // leave room for beside "Enable" and "Left-handed".
        let guards = NSStackView(views: [ignoreTyping, ignoreMouseMoving])
        guards.orientation = .horizontal
        guards.spacing = 24
        guards.setHuggingPriority(.required, for: .horizontal)

        let hint = NSTextField(wrappingLabelWithString:
            "Gestures work alongside the ones built into macOS. Turn off any that overlap in "
                + "System Settings → Trackpad, such as Look Up with a three-finger tap. "
                + "Hover over a gesture's name to see how to do it. "
                + "In gesture names, “Fix” means a finger that stays resting on the surface."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 580).isActive = true

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        touchStatusLabel = status

        // Shown while a macOS three-finger gesture takes one of the bound gestures. Hidden,
        // it leaves the layout, and the window is fitted to the page again either way.
        let warningIcon = NSImageView()
        warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
        warningIcon.setContentHuggingPriority(.required, for: .horizontal)
        let conflictLabel = NSTextField(wrappingLabelWithString: "")
        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false
        // As wide as the hint above less the icon, so lines wrap where it does.
        let conflictTextWidth: CGFloat = 580 - 24
        conflictLabel.preferredMaxLayoutWidth = conflictTextWidth
        conflictLabel.widthAnchor.constraint(equalToConstant: conflictTextWidth).isActive = true
        let openSettings = NSButton(
            title: "Open Trackpad Settings…",
            target: self,
            action: #selector(openTrackpadSettingsTapped)
        )
        openSettings.bezelStyle = .rounded
        openSettings.controlSize = .small
        openSettings.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let conflictColumn = NSStackView(views: [conflictLabel, openSettings])
        conflictColumn.orientation = .vertical
        conflictColumn.alignment = .leading
        conflictColumn.spacing = 6
        let conflictRow = NSStackView(views: [warningIcon, conflictColumn])
        conflictRow.orientation = .horizontal
        conflictRow.alignment = .top
        conflictRow.spacing = 8
        conflictRow.isHidden = true
        touchConflictRow = conflictRow
        touchConflictLabel = conflictLabel

        let panePicker = NSSegmentedControl(
            labels: ["Trackpad", "Magic Mouse", "Characters"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(touchPaneChanged(_:))
        )
        panePicker.selectedSegment = 0

        let panes = [
            makeGesturePane(for: .trackpad),
            makeGesturePane(for: .magicMouse),
            makeCharacterPane(),
        ]
        touchPanes = panes
        // Only the pane on show animates, and only the first is on show to begin with.
        gesturePreviews[.magicMouse]?.isAnimating = false
        strokePreview?.isAnimating = false

        // Panes overlap in one container that is as large as the largest, so switching
        // never resizes the window. The container is pinned to that size: left with only
        // the panes' lower bounds its size was ambiguous, and the engine chose a different
        // solution after the window crossed to another display, which put the list and
        // the footer up over the header.
        let paneContainer = NSView()
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        let paneSizes = panes.map(\.fittingSize)
        for (index, pane) in panes.enumerated() {
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = index != 0
            paneContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
                pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
                pane.trailingAnchor.constraint(lessThanOrEqualTo: paneContainer.trailingAnchor),
                pane.bottomAnchor.constraint(lessThanOrEqualTo: paneContainer.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            paneContainer.widthAnchor.constraint(
                equalToConstant: ceil(max(hint.fittingSize.width, paneSizes.map(\.width).max() ?? 0))
            ),
            paneContainer.heightAnchor.constraint(equalToConstant: ceil(paneSizes.map(\.height).max() ?? 0)),
        ])

        let footer = makeRestoreDefaultsFooter(action: #selector(restoreTouchDefaultsTapped))

        let scopeRow = makeScopeRow()
        let stack = NSStackView(views: [toggles, guards, hint, status, conflictRow, scopeRow, panePicker, paneContainer, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: status)
        stack.setCustomSpacing(14, after: conflictRow)
        stack.setCustomSpacing(14, after: scopeRow)
        stack.setCustomSpacing(12, after: panePicker)
        stack.setCustomSpacing(12, after: paneContainer)
        // The footer follows the container, which is as wide as the text or the widest pane.
        footer.widthAnchor.constraint(equalTo: paneContainer.widthAnchor).isActive = true

        return makePage(stack)
    }

    func makeGesturePane(for surface: TouchSurface) -> NSView {
        var tracked: [(gesture: TouchGesture, row: NSView)] = []
        let rows: [[NSView]] = TouchGesture.gestures(for: surface).map { gesture in
            let label = NSTextField(labelWithString: "\(gesture.displayName):")
            label.alignment = .right

            let popup = makeBindingPopup(for: .touch(gesture))
            // Keyboard focus shows the gesture as hovering does, and VoiceOver gets the
            // how-to as the picker's help, since neither can hover.
            popup.onFocus = { [weak self] in
                self?.show(gesture, on: surface)
            }
            popup.setAccessibilityHelp(gesture.hint)
            tracked.append((gesture, popup))
            return [label, popup]
        }
        gestureRows[surface] = tracked

        let grid = makeFormGrid(rows, rowSpacing: 6)
        grid.column(at: 1).xPlacement = .fill

        let hoverView = HoverTrackingView()
        hoverView.onHover = { [weak self] point, view in
            self?.hoveredGesture(at: point, in: view, on: surface)
        }
        let list = makeScrollingPane(grid, height: 286, document: hoverView)

        let listAndPreview = NSStackView(views: [list, makeGesturePreviewColumn(for: surface)])
        listAndPreview.orientation = .horizontal
        listAndPreview.alignment = .top
        listAndPreview.spacing = 16
        // Both views in it have fixed widths; nothing below may stretch it past them. A
        // stack hugs its views at a priority of its own, 250 unless raised, which a label
        // asking for its text in one line would beat.
        listAndPreview.setHuggingPriority(.required, for: .horizontal)

        // The how-to in words, under the picture of it. Fixed height, so the window keeps
        // its size whatever the hint's length, and no resistance to wrapping: a wrapping
        // label asks for the width of its whole text in one line, and would be given it.
        let hint = NSTextField(wrappingLabelWithString: "Hover over a gesture to see how it is done.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.heightAnchor.constraint(equalToConstant: 44).isActive = true
        gestureHintLabels[surface] = hint

        let pane = NSStackView(views: [listAndPreview, hint])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 8
        // Only once both are in the pane: a constraint between views with no common
        // ancestor throws, which would abandon the whole window half-built.
        hint.widthAnchor.constraint(equalTo: listAndPreview.widthAnchor).isActive = true
        return pane
    }

    /// Shows the gesture the pointer is over: the surface from above, resting fingers as
    /// grey hollow circles and the ones that act as filled red dots.
    func makeGesturePreviewColumn(for surface: TouchSurface) -> NSView {
        let preview = TouchGesturePreviewView()
        preview.surfaceType = surface
        preview.isMirrored = Preferences.shared.isLeftHanded
        gesturePreviews[surface] = preview

        let column = makePreviewColumn(
            placeholder: "Hover a gesture",
            legend: "Hollow rests, filled acts",
            preview: preview,
            names: TouchGesture.gestures(for: surface).map(\.displayName)
        )
        gesturePreviewNames[surface] = column.name
        gesturePreviewHints[surface] = column.legend
        return column.view
    }

    /// A name over a preview over a legend. The column is as wide as the longest name it
    /// may show, so it never moves as the pointer goes from a short name to a long one,
    /// and nothing beside it is stretched by one.
    func makePreviewColumn(
        placeholder: String,
        legend: String,
        preview: NSView,
        names: [String]
    ) -> (view: NSView, name: NSTextField, legend: NSTextField) {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let name = NSTextField(labelWithString: placeholder)
        name.font = font
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 150),
            preview.heightAnchor.constraint(equalToConstant: 130),
        ])

        let legendLabel = NSTextField(labelWithString: legend)
        legendLabel.font = .systemFont(ofSize: 11)
        legendLabel.textColor = .secondaryLabelColor
        legendLabel.alignment = .center
        legendLabel.isHidden = true

        let column = NSStackView(views: [name, preview, legendLabel])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        // As tall as its content, not as the list beside it: the stack holding both would
        // otherwise leave the column's height open to the engine.
        column.setHuggingPriority(.required, for: .vertical)

        // Measured as a label, since a label draws its text with a little room either side
        // that its intrinsic size leaves out; a column that is too narrow truncates it.
        let widest = (names + [placeholder, legend])
            .map { text -> CGFloat in
                let sample = NSTextField(labelWithString: text)
                sample.font = font
                return sample.fittingSize.width
            }
            .max() ?? 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: max(150, ceil(widest))).isActive = true
        return (column, name, legendLabel)
    }

    /// Shows how the gesture under the pointer is done. The last one stays on show when the
    /// pointer leaves, so it can be read at leisure.
    func hoveredGesture(at point: NSPoint?, in view: NSView, on surface: TouchSurface) {
        guard let point, let rows = gestureRows[surface] else { return }

        let hit = rows.first { _, row in
            let frame = view.convert(row.bounds, from: row).insetBy(dx: 0, dy: -3)
            return point.y >= frame.minY && point.y <= frame.maxY
        }
        guard let hit else { return }
        show(hit.gesture, on: surface)
    }

    func show(_ gesture: TouchGesture, on surface: TouchSurface) {
        gesturePreviews[surface]?.gesture = gesture
        gesturePreviewNames[surface]?.stringValue = gesture.displayName
        gesturePreviewHints[surface]?.isHidden = false
        gestureHintLabels[surface]?.stringValue = gesture.hint
    }

    func makeCharacterPane() -> NSView {
        let showDrawing = NSButton(
            checkboxWithTitle: "Show the drawing on screen",
            target: self,
            action: #selector(showDrawingChanged(_:))
        )
        showDrawingCheckbox = showDrawing

        var sources: [NSView] = []
        for source in CharacterSource.allCases {
            let checkbox = NSButton(
                checkboxWithTitle: source.displayName,
                target: self,
                action: #selector(characterSourceChanged(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(source.rawValue)
            characterSourceCheckboxes[source] = checkbox
            // What it costs is said where it is chosen: both button sources hold the press
            // back, which is the price of telling a drawing from a click.
            switch source {
            case .trackpad:
                break
            case .magicMouseRightDrag:
                checkbox.toolTip = "A right-button drag of more than about 40 points is taken as a drawing, "
                    + "so it cannot select or drag. The press is held back until you release, so a "
                    + "context menu opens on release instead of on press."
            case .middleButtonDrag:
                checkbox.toolTip = "A middle-button drag of more than about 40 points is taken as a drawing, "
                    + "so it cannot scroll or drag. The press is held back until you release, so a "
                    + "middle click is delayed until then."
            }
            sources.append(checkbox)

            // The spacing only governs the trackpad, so it sits under that source.
            if source == .trackpad {
                sources.append(makeDrawSpreadRow())
            }
        }

        let rows: [[NSView]] = CharacterGesture.allCases.map { gesture in
            let label = NSTextField(labelWithString: "\(gesture.displayName):")
            label.alignment = .right

            let popup = makeBindingPopup(for: .character(gesture))
            popup.onFocus = { [weak self] in
                self?.show(gesture)
            }
            popup.setAccessibilityHelp(Self.accessibilityHelp(for: gesture))
            characterRows.append((gesture, popup))
            return [label, popup]
        }
        let grid = makeFormGrid(rows, rowSpacing: 6)
        grid.column(at: 1).xPlacement = .fill

        let hoverView = HoverTrackingView()
        // The view hands itself back rather than being captured, which would tie the
        // closure it owns to the view that owns the closure.
        hoverView.onHover = { [weak self] point, view in
            self?.hoveredCharacter(at: point, in: view)
        }
        let list = makeScrollingPane(grid, height: 228, document: hoverView)

        let listAndPreview = NSStackView(views: [list, makeStrokePreviewColumn()])
        listAndPreview.orientation = .horizontal
        listAndPreview.alignment = .top
        listAndPreview.spacing = 16
        listAndPreview.setHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [showDrawing] + sources + [listAndPreview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: showDrawing)
        if let last = sources.last {
            stack.setCustomSpacing(10, after: last)
        }
        return stack
    }

    /// The how-to for VoiceOver, which cannot hover over the preview.
    static func accessibilityHelp(for gesture: CharacterGesture) -> String {
        let what: String
        if gesture.isDirection {
            what = "Draw a straight line \(gesture.displayName)"
        } else if CharacterGesture.strokes.contains(gesture) {
            what = "Draw \(gesture.displayName) as one stroke with a corner"
        } else {
            what = "Draw the letter \(gesture.displayName)"
        }
        return what + " with two fingers spread apart on the trackpad, or with the right or middle "
            + "button held, starting at the dot shown in the preview. Which of these work depends on "
            + "the drawing sources chosen above."
    }

    /// How far apart the two drawing fingers must be. Wide enough that ordinary two-finger
    /// scrolling is never mistaken for drawing, narrow enough to be comfortable.
    func makeDrawSpreadRow() -> NSView {
        let caption = NSTextField(labelWithString: "Finger spacing:")

        let slider = makeSlider(
            value: Preferences.shared.characterDrawSpread,
            range: TouchTuning.drawSpreadRange,
            width: 160,
            action: #selector(drawSpreadChanged(_:))
        )
        slider.toolTip = "Index and middle fingers sit close together; index and ring are further apart."
        drawSpreadSlider = slider

        let value = PreferencesWindowController.makeValueLabel(width: 110)
        drawSpreadLabel = value

        let row = NSStackView(views: [caption, slider, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setHuggingPriority(.required, for: .horizontal)
        PreferencesWindowController.titleControls(in: [caption, slider])
        // Indented under the checkbox it belongs to.
        row.edgeInsets = NSEdgeInsets(top: 2, left: 18, bottom: 2, right: 0)
        return row
    }

    func updateDrawSpreadLabel() {
        let spread = Preferences.shared.characterDrawSpread
        if let width = touchMonitor.trackpadWidthMillimetres {
            drawSpreadLabel?.stringValue = String(format: "%.0f mm apart", spread * width)
        } else {
            drawSpreadLabel?.stringValue = String(format: "%.0f%% of the pad", spread * 100)
        }
    }

    /// Shows the stroke for whichever character the pointer is over.
    func makeStrokePreviewColumn() -> NSView {
        let preview = StrokePreviewView()
        strokePreview = preview

        let column = makePreviewColumn(
            placeholder: "Hover a character",
            legend: "Start at the dot",
            preview: preview,
            names: CharacterGesture.allCases.map(\.displayName)
        )
        strokePreviewName = column.name
        strokePreviewHint = column.legend
        return column.view
    }

    /// `point` is in `view`, or nil when the pointer has left the list. The last character
    /// stays on show, so the pointer can move over to the preview.
    func hoveredCharacter(at point: NSPoint?, in view: NSView) {
        guard let point else { return }

        let hit = characterRows.first { _, row in
            let frame = view.convert(row.bounds, from: row).insetBy(dx: 0, dy: -3)
            return point.y >= frame.minY && point.y <= frame.maxY
        }
        guard let hit else { return }
        show(hit.gesture)
    }

    func show(_ gesture: CharacterGesture) {
        strokePreview?.gesture = gesture
        strokePreviewName?.stringValue = gesture.displayName
        strokePreviewHint?.isHidden = false
    }

    /// A fixed-height scroll view showing the top of `content` first.
    func makeScrollingPane(
        _ content: NSView,
        height: CGFloat,
        document: FlippedView = FlippedView()
    ) -> NSView {
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
        ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document

        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: height),
            scroll.widthAnchor.constraint(equalToConstant: content.fittingSize.width + 8 + scrollerWidth),
        ])
        return scroll
    }

    func refreshTouchUI() {
        let preferences = Preferences.shared
        touchEnableCheckbox?.state = preferences.isTouchEnabled ? .on : .off
        leftHandedCheckbox?.state = preferences.isLeftHanded ? .on : .off
        ignoreTypingCheckbox?.state = preferences.ignoresTouchWhileTyping ? .on : .off
        ignoreMouseMovingCheckbox?.state = preferences.ignoresTapsWhileMouseMoves ? .on : .off
        for preview in gesturePreviews.values {
            preview.isMirrored = preferences.isLeftHanded
        }

        refreshBindings { !$0.isButton }
        for (source, checkbox) in characterSourceCheckboxes {
            checkbox.state = preferences.isCharacterSourceEnabled(source) ? .on : .off
        }
        showDrawingCheckbox?.state = preferences.showsDrawingOverlay ? .on : .off

        drawSpreadSlider?.doubleValue = preferences.characterDrawSpread
        drawSpreadSlider?.isEnabled = preferences.isCharacterSourceEnabled(.trackpad)
        updateDrawSpreadLabel()

        touchStatusLabel?.stringValue = touchStatusText
        touchStatusLabel?.textColor = touchMonitor.isRunning ? .labelColor : .secondaryLabelColor
        refreshTrackpadConflictUI()
    }

    /// Warns of the macOS three-finger gestures that take a trackpad gesture bound in the
    /// current scope. The settings are read every time: System Settings changes them
    /// under the window, and the user comes back expecting the warning to follow.
    func refreshTrackpadConflictUI() {
        guard let row = touchConflictRow, let label = touchConflictLabel else { return }
        var text: String?
        // Nothing to warn of where no gesture fires: touch off, no trackpad, or an app in
        // whose scope MouseNavigate is turned off.
        if Preferences.shared.isTouchEnabled, !Preferences.shared.isAppDisabled(selectedApp),
           touchMonitor.surfaces.contains(where: { $0.surface == .trackpad }) {
            let conflicts = MacOSTrackpadSettings.current().conflicts { gesture in
                let trigger = BindingTrigger.touch(gesture)
                let binding = self.selectedApp.flatMap { Preferences.shared.appBinding(for: trigger, app: $0) }
                    ?? Preferences.shared.globalBinding(for: trigger)
                return binding.builtinAction != .disabled
            }
            text = TrackpadConflictMessage.text(for: conflicts)
        }
        let changed = row.isHidden != (text == nil) || label.stringValue != (text ?? "")
        row.isHidden = text == nil
        label.stringValue = text ?? ""
        if changed {
            fitWindowToPages()
        }
    }

    @objc func openTrackpadSettingsTapped() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    var touchStatusText: String {
        guard touchMonitor.isAvailable else {
            return "Touch gestures are unavailable on this version of macOS."
        }
        guard Preferences.shared.isTouchEnabled else {
            return "Gestures are off."
        }
        guard touchMonitor.isRunning else {
            return "Gestures are paused."
        }
        let surfaces = touchMonitor.surfaces
        guard !surfaces.isEmpty else {
            return "No trackpad or Magic Mouse found."
        }
        let names = surfaces.map { "\($0.name) (\($0.surface.displayName))" }
        return "Listening on " + names.joined(separator: ", ")
    }

    @objc func touchDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshTouchUI()
        }
    }

    @objc func touchEnabledChanged(_ sender: NSButton) {
        Preferences.shared.isTouchEnabled = sender.state == .on
        refreshTouchUI()
    }

    @objc func leftHandedChanged(_ sender: NSButton) {
        Preferences.shared.isLeftHanded = sender.state == .on
        for preview in gesturePreviews.values {
            preview.isMirrored = sender.state == .on
        }
    }

    @objc func ignoreTypingChanged(_ sender: NSButton) {
        Preferences.shared.ignoresTouchWhileTyping = sender.state == .on
    }

    @objc func ignoreMouseMovingChanged(_ sender: NSButton) {
        Preferences.shared.ignoresTapsWhileMouseMoves = sender.state == .on
    }

    @objc func touchPaneChanged(_ sender: NSSegmentedControl) {
        for (index, pane) in touchPanes.enumerated() {
            pane.isHidden = index != sender.selectedSegment
        }
        // Nothing should animate on a pane nobody is looking at.
        gesturePreviews[.trackpad]?.isAnimating = sender.selectedSegment == 0
        gesturePreviews[.magicMouse]?.isAnimating = sender.selectedSegment == 1
        strokePreview?.isAnimating = sender.selectedSegment == 2
    }

    @objc func showDrawingChanged(_ sender: NSButton) {
        Preferences.shared.showsDrawingOverlay = sender.state == .on
    }

    @objc func drawSpreadChanged(_ sender: NSSlider) {
        Preferences.shared.characterDrawSpread = sender.doubleValue
        updateDrawSpreadLabel()
    }

    @objc func characterSourceChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let source = CharacterSource(rawValue: raw) else { return }
        Preferences.shared.setCharacterSource(source, enabled: sender.state == .on)
        if source == .trackpad {
            drawSpreadSlider?.isEnabled = sender.state == .on
        }
    }

    /// In one app's scope this hands its gestures back to the ones for all apps rather than
    /// resetting those.
    @objc func restoreTouchDefaultsTapped() {
        guard let window else { return }
        let title: String
        let message: String
        if let selectedApp, let app = Preferences.shared.appOverrides[selectedApp] {
            title = "Restore the gestures for \(app.name)?"
            message = "\(app.name) gives up its own gesture and character bindings and goes back to "
                + "following the ones for All Apps. Those, and everything else, are kept."
        } else {
            title = "Restore the touch defaults?"
            message = "Every gesture and character binding for All Apps goes back to its default, and so do "
                + "the touch options on this tab: left-handed, the drawing sources, finger spacing, showing "
                + "the drawing, and ignoring touches. Whether touch gestures are switched on, apps' own "
                + "gestures, mouse buttons and the keyboard cursor are kept."
        }
        AlertPresenter.confirmDestructive(title, message, confirm: "Restore", on: window) { [weak self] in
            guard let self else { return }
            if let selectedApp = self.selectedApp {
                Preferences.shared.clearAppBindings(app: selectedApp) {
                    $0.hasPrefix(SettingsKey.touchPrefix) || $0.hasPrefix(SettingsKey.characterPrefix)
                }
            } else {
                Preferences.shared.restoreTouchDefaults()
            }
            self.refreshTouchUI()
        }
    }
}
