import AppKit
import MouseNavigateCore

/// Tabbed preferences: mouse button mapping per device profile, keyboard cursor bindings
/// plus speed tuning, touch and drawn-character gestures, and an About page.
final class PreferencesWindowController: NSObject {
    private var window: NSWindow?

    private let detector: DeviceDetector
    private let engine: KeyboardCursorEngine
    private let touchMonitor: TouchMonitor

    private var deviceLabel: NSTextField?
    private var overridePopup: NSPopUpButton?
    private var buttonPopups: [Int: NSPopUpButton] = [:]
    private var testerLabel: NSTextField?

    private var recorders: [CursorBinding: KeyRecorderButton] = [:]
    private var sliders: [CursorSetting: NSSlider] = [:]
    private var sliderValueLabels: [CursorSetting: NSTextField] = [:]
    private var enableCheckbox: NSButton?

    private var touchEnableCheckbox: NSButton?
    private var leftHandedCheckbox: NSButton?
    private var touchStatusLabel: NSTextField?
    private var touchPanes: [NSView] = []
    private var touchPopups: [TouchGesture: NSPopUpButton] = [:]
    private var characterPopups: [CharacterGesture: NSPopUpButton] = [:]
    private var characterSourceCheckboxes: [CharacterSource: NSButton] = [:]
    private var showDrawingCheckbox: NSButton?
    private var drawSpreadSlider: NSSlider?
    private var drawSpreadLabel: NSTextField?
    private var strokePreview: StrokePreviewView?
    private var strokePreviewName: NSTextField?
    private var strokePreviewHint: NSTextField?
    /// Each character row's picker, for working out which one the pointer is over.
    private var characterRows: [(gesture: CharacterGesture, row: NSView)] = []

    private var lastButtonPressed: Int?

    init(detector: DeviceDetector, engine: KeyboardCursorEngine, touchMonitor: TouchMonitor) {
        self.detector = detector
        self.engine = engine
        self.touchMonitor = touchMonitor
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidChange),
            name: DeviceDetector.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(touchDidChange),
            name: TouchMonitor.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Window

    func showOrFocus() {
        if let window {
            refreshDeviceUI()
            refreshTouchUI()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // A standard titled window, not a utility panel: panels get a shrunken title bar,
        // close button and title font that look out of place next to other apps. Not being
        // resizable, it shows the zoom button disabled, as system settings windows do.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "MouseNavigate Preferences"
        // Kept and reused rather than rebuilt: measuring showed a fresh window costs about
        // 10 MB that AppKit's own caches never give back, while reopening this one is free.
        w.isReleasedWhenClosed = false
        w.isRestorable = false

        let content = w.contentView!

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        let mousePage = makeMouseTab()
        let mouseTab = NSTabViewItem(identifier: "mouse")
        mouseTab.label = "Mouse"
        mouseTab.view = mousePage
        tabView.addTabViewItem(mouseTab)

        let cursorPage = makeCursorTab()
        let cursorTab = NSTabViewItem(identifier: "cursor")
        cursorTab.label = "Keyboard Cursor"
        cursorTab.view = cursorPage
        tabView.addTabViewItem(cursorTab)

        let touchPage = makeTouchTab()
        let touchTab = NSTabViewItem(identifier: "touch")
        touchTab.label = "Touch"
        touchTab.view = touchPage
        tabView.addTabViewItem(touchTab)

        let aboutPage = makeAboutTab()
        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "About"
        aboutTab.view = aboutPage
        tabView.addTabViewItem(aboutTab)

        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])

        // A tab view takes no size from its pages, so size the window to the larger page
        // plus the tab chrome. A fixed size clipped the cursor tab's lower rows.
        let pages = [mousePage, cursorPage, touchPage, aboutPage].map(\.fittingSize)
        let probe = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        tabView.frame = probe
        let chromeWidth = probe.width - tabView.contentRect.width
        let chromeHeight = probe.height - tabView.contentRect.height
        w.setContentSize(NSSize(
            width: (pages.map(\.width).max() ?? 0) + chromeWidth + margin * 2,
            height: (pages.map(\.height).max() ?? 0) + chromeHeight + margin * 2
        ))

        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w

        refreshDeviceUI()
        refreshTouchUI()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Mouse tab

    private func makeMouseTab() -> NSView {
        let label = NSTextField(labelWithString: "Detecting…")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        deviceLabel = label

        let overrideLabel = NSTextField(labelWithString: "Profile:")
        overrideLabel.alignment = .right

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(overrideChanged(_:))
        popup.addItem(withTitle: "Automatic")
        for profile in DeviceProfile.allCases {
            popup.addItem(withTitle: profile.displayName)
        }
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        overridePopup = popup

        var rows: [[NSView]] = [[overrideLabel, popup]]

        for button in Preferences.configurableButtons {
            let buttonLabel = NSTextField(labelWithString: "Button \(button):")
            buttonLabel.alignment = .right

            let actionPopup = makeActionPopup(
                action: #selector(buttonActionChanged(_:)),
                include: { $0.isAvailableForButtons }
            )
            actionPopup.tag = button
            buttonPopups[button] = actionPopup

            rows.append([buttonLabel, actionPopup])
        }

        let grid = makeFormGrid(rows, rowSpacing: 8)
        // Every picker takes the width of the widest, so the column reads as one edge.
        grid.column(at: 1).xPlacement = .fill
        // Keep the profile picker visually apart from the per-button rows.
        grid.row(at: 0).bottomPadding = 8

        let tester = NSTextField(labelWithString: "Press a mouse button to identify it…")
        tester.font = .systemFont(ofSize: 11)
        tester.textColor = .secondaryLabelColor
        testerLabel = tester

        let stack = NSStackView(views: [label, grid, tester])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: grid)

        return makePage(stack)
    }

    // MARK: - Layout helpers

    /// Wraps a tab's content with margins. Trailing and bottom are inequalities so the
    /// page can be handed more room than it needs, which also lets `fittingSize` report
    /// the size it actually needs.
    private func makePage(_ content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            content.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -16),
        ])

        return page
    }

    /// Right-aligned labels in the first column, controls vertically centred on them.
    private func makeFormGrid(_ rows: [[NSView]], rowSpacing: CGFloat) -> NSGridView {
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
        return grid
    }

    /// Every assignable action, grouped by category. Items carry the action's raw value, so
    /// selection never depends on item positions, which separators would throw off.
    private func makeActionPopup(
        action selector: Selector,
        include: (ButtonAction) -> Bool = { _ in true }
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = selector

        var previousCategory: ButtonAction.Category?
        for action in ButtonAction.allCases where include(action) {
            if let previousCategory, previousCategory != action.category {
                popup.menu?.addItem(.separator())
            }
            previousCategory = action.category

            popup.addItem(withTitle: action.displayName)
            popup.lastItem?.representedObject = action.rawValue
        }
        return popup
    }

    private func select(_ action: ButtonAction, in popup: NSPopUpButton) {
        let index = popup.indexOfItem(withRepresentedObject: action.rawValue)
        if index >= 0 {
            popup.selectItem(at: index)
        }
    }

    private func selectedAction(of popup: NSPopUpButton) -> ButtonAction? {
        (popup.selectedItem?.representedObject as? String).flatMap(ButtonAction.init(rawValue:))
    }

    private func makeSection(title: String, content: NSView) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        return section
    }

    // MARK: - Cursor tab

    private func makeCursorTab() -> NSView {
        let checkbox = NSButton(
            checkboxWithTitle: "Enable keyboard cursor control",
            target: self,
            action: #selector(enabledChanged(_:))
        )
        checkbox.state = Preferences.shared.isCursorModeEnabled ? .on : .off
        enableCheckbox = checkbox

        let hint = NSTextField(
            labelWithString: "Hold the activate key, then use the movement keys. "
                + "Shift is faster, Shift+Ctrl fastest, Option precise. "
                + "Tap it and press again to type its letter instead."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        var keyRows: [[NSView]] = []

        for binding in CursorBinding.allCases {
            let label = NSTextField(labelWithString: "\(binding.displayName):")
            label.alignment = .right

            let recorder = KeyRecorderButton(
                binding: binding,
                keyCode: Preferences.shared.keyCode(for: binding)
            )
            recorder.onRecord = { keyCode in
                Preferences.shared.setKeyCode(keyCode, for: binding)
            }
            recorder.onRecordingChange = { [weak self] recording in
                // Stop the tap from eating the keystroke being recorded.
                self?.engine.isSuspended = recording
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

        return makePage(stack)
    }

    // MARK: - Touch tab

    private func makeTouchTab() -> NSView {
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

        let hint = NSTextField(wrappingLabelWithString:
            "Gestures work alongside the ones built into macOS. Turn off any that overlap in "
                + "System Settings → Trackpad, such as Look Up with a three-finger tap. "
                + "Hover over a gesture's name to see how to do it."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 580).isActive = true

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        touchStatusLabel = status

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

        // Panes overlap in one container that is as large as the largest, so switching
        // never resizes the window.
        let paneContainer = NSView()
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
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

        let restore = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restoreTouchDefaultsTapped)
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, restore])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [toggles, hint, status, panePicker, paneContainer, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: status)
        stack.setCustomSpacing(12, after: panePicker)
        stack.setCustomSpacing(12, after: paneContainer)
        footer.widthAnchor.constraint(equalTo: hint.widthAnchor).isActive = true
        paneContainer.widthAnchor.constraint(equalTo: hint.widthAnchor).isActive = true

        return makePage(stack)
    }

    private func makeGesturePane(for surface: TouchSurface) -> NSView {
        let rows: [[NSView]] = TouchGesture.gestures(for: surface).map { gesture in
            let label = NSTextField(labelWithString: "\(gesture.displayName):")
            label.alignment = .right
            label.toolTip = gesture.hint

            let popup = makeActionPopup(
                action: #selector(touchActionChanged(_:)),
                include: { gesture.allows($0) }
            )
            popup.identifier = NSUserInterfaceItemIdentifier(gesture.rawValue)
            popup.toolTip = gesture.hint
            touchPopups[gesture] = popup
            return [label, popup]
        }

        let grid = makeFormGrid(rows, rowSpacing: 6)
        grid.column(at: 1).xPlacement = .fill
        return makeScrollingPane(grid, height: 322)
    }

    private func makeCharacterPane() -> NSView {
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
            sources.append(checkbox)

            // The spacing only governs the trackpad, so it sits under that source.
            if source == .trackpad {
                sources.append(makeDrawSpreadRow())
            }
        }

        let rows: [[NSView]] = CharacterGesture.allCases.map { gesture in
            let label = NSTextField(labelWithString: "\(gesture.displayName):")
            label.alignment = .right

            let popup = makeActionPopup(
                action: #selector(characterActionChanged(_:)),
                include: { $0 != .moveResizeWindow }
            )
            popup.identifier = NSUserInterfaceItemIdentifier(gesture.rawValue)
            characterPopups[gesture] = popup
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

    /// How far apart the two drawing fingers must be. Wide enough that ordinary two-finger
    /// scrolling is never mistaken for drawing, narrow enough to be comfortable.
    private func makeDrawSpreadRow() -> NSView {
        let caption = NSTextField(labelWithString: "Finger spacing:")

        let slider = NSSlider(
            value: Preferences.shared.characterDrawSpread,
            minValue: TouchTuning.drawSpreadRange.lowerBound,
            maxValue: TouchTuning.drawSpreadRange.upperBound,
            target: self,
            action: #selector(drawSpreadChanged(_:))
        )
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.toolTip = "Index and middle fingers sit close together; index and ring are further apart."
        drawSpreadSlider = slider

        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 110).isActive = true
        drawSpreadLabel = value

        let row = NSStackView(views: [caption, slider, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        // Indented under the checkbox it belongs to.
        row.edgeInsets = NSEdgeInsets(top: 2, left: 18, bottom: 2, right: 0)
        return row
    }

    private func updateDrawSpreadLabel() {
        let spread = Preferences.shared.characterDrawSpread
        if let width = touchMonitor.trackpadWidthMillimetres {
            drawSpreadLabel?.stringValue = String(format: "%.0f mm apart", spread * width)
        } else {
            drawSpreadLabel?.stringValue = String(format: "%.0f%% of the pad", spread * 100)
        }
    }

    /// Shows the stroke for whichever character the pointer is over.
    private func makeStrokePreviewColumn() -> NSView {
        let name = NSTextField(labelWithString: "Hover a character")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        strokePreviewName = name

        let preview = StrokePreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 150),
            preview.heightAnchor.constraint(equalToConstant: 130),
        ])
        strokePreview = preview

        let hint = NSTextField(labelWithString: "Start at the dot")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.isHidden = true
        strokePreviewHint = hint

        let column = NSStackView(views: [name, preview, hint])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        return column
    }

    /// `point` is in `view`, or nil when the pointer has left the list. The last character
    /// stays on show, so the pointer can move over to the preview.
    private func hoveredCharacter(at point: NSPoint?, in view: NSView) {
        guard let point else { return }

        let hit = characterRows.first { _, row in
            let frame = view.convert(row.bounds, from: row).insetBy(dx: 0, dy: -3)
            return point.y >= frame.minY && point.y <= frame.maxY
        }
        guard let hit else { return }

        strokePreview?.gesture = hit.gesture
        strokePreviewName?.stringValue = hit.gesture.displayName
        strokePreviewHint?.isHidden = false
    }

    /// A fixed-height scroll view showing the top of `content` first.
    private func makeScrollingPane(
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

    private func refreshTouchUI() {
        let preferences = Preferences.shared
        touchEnableCheckbox?.state = preferences.isTouchEnabled ? .on : .off
        leftHandedCheckbox?.state = preferences.isLeftHanded ? .on : .off

        for (gesture, popup) in touchPopups {
            select(preferences.touchAction(for: gesture), in: popup)
        }
        for (gesture, popup) in characterPopups {
            select(preferences.characterAction(for: gesture), in: popup)
        }
        for (source, checkbox) in characterSourceCheckboxes {
            checkbox.state = preferences.isCharacterSourceEnabled(source) ? .on : .off
        }
        showDrawingCheckbox?.state = preferences.showsDrawingOverlay ? .on : .off

        drawSpreadSlider?.doubleValue = preferences.characterDrawSpread
        drawSpreadSlider?.isEnabled = preferences.isCharacterSourceEnabled(.trackpad)
        updateDrawSpreadLabel()

        touchStatusLabel?.stringValue = touchStatusText
        touchStatusLabel?.textColor = touchMonitor.isRunning ? .labelColor : .secondaryLabelColor
    }

    private var touchStatusText: String {
        guard touchMonitor.isAvailable else {
            return "Touch gestures are unavailable on this version of macOS."
        }
        guard Preferences.shared.isTouchEnabled else {
            return "Gestures are off."
        }
        guard touchMonitor.isRunning else {
            return "Gestures are paused from the menu bar."
        }
        let surfaces = touchMonitor.surfaces
        guard !surfaces.isEmpty else {
            return "No trackpad or Magic Mouse found."
        }
        let names = surfaces.map { "\($0.name) (\($0.surface.displayName))" }
        return "Listening on " + names.joined(separator: ", ")
    }

    @objc private func touchDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshTouchUI()
        }
    }

    @objc private func touchEnabledChanged(_ sender: NSButton) {
        Preferences.shared.isTouchEnabled = sender.state == .on
        refreshTouchUI()
    }

    @objc private func leftHandedChanged(_ sender: NSButton) {
        Preferences.shared.isLeftHanded = sender.state == .on
    }

    @objc private func touchPaneChanged(_ sender: NSSegmentedControl) {
        for (index, pane) in touchPanes.enumerated() {
            pane.isHidden = index != sender.selectedSegment
        }
        // Nothing should animate on a pane nobody is looking at.
        strokePreview?.isAnimating = touchPanes.last?.isHidden == false
    }

    @objc private func touchActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let gesture = TouchGesture(rawValue: raw),
              let action = selectedAction(of: sender)
        else {
            return
        }
        Preferences.shared.setTouchAction(action, for: gesture)
    }

    @objc private func characterActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let gesture = CharacterGesture(rawValue: raw),
              let action = selectedAction(of: sender)
        else {
            return
        }
        Preferences.shared.setCharacterAction(action, for: gesture)
    }

    @objc private func showDrawingChanged(_ sender: NSButton) {
        Preferences.shared.showsDrawingOverlay = sender.state == .on
    }

    @objc private func drawSpreadChanged(_ sender: NSSlider) {
        Preferences.shared.characterDrawSpread = sender.doubleValue
        updateDrawSpreadLabel()
    }

    @objc private func characterSourceChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let source = CharacterSource(rawValue: raw) else { return }
        Preferences.shared.setCharacterSource(source, enabled: sender.state == .on)
        if source == .trackpad {
            drawSpreadSlider?.isEnabled = sender.state == .on
        }
    }

    @objc private func restoreTouchDefaultsTapped() {
        Preferences.shared.restoreTouchDefaults()
        refreshTouchUI()
    }

    // MARK: - About tab

    private func makeAboutTab() -> NSView {
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

        let stack = NSStackView(views: [iconView, name, version, tagline, developer, links, legal])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(14, after: version)
        stack.setCustomSpacing(14, after: tagline)
        stack.setCustomSpacing(12, after: developer)
        stack.setCustomSpacing(18, after: links)

        return makePage(stack)
    }

    private func makeLinkButton(title: String, url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        button.toolTip = url.absoluteString
        return button
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Live button tester

    /// Called from the event tap so users can discover their own mouse's numbering.
    func reportButtonPress(_ button: Int) {
        lastButtonPressed = button
        guard isVisible else { return }

        DispatchQueue.main.async { [weak self] in
            self?.testerLabel?.stringValue =
                "Last button pressed: \(button)"
        }
    }

    // MARK: - Actions

    @objc private func deviceDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDeviceUI()
        }
    }

    private func refreshDeviceUI() {
        deviceLabel?.stringValue = detector.statusDescription

        if let override = Preferences.shared.deviceOverride,
           let index = DeviceProfile.allCases.firstIndex(of: override) {
            overridePopup?.selectItem(at: index + 1)
        } else {
            overridePopup?.selectItem(at: 0)
        }

        let profile = detector.activeProfile
        for (button, popup) in buttonPopups {
            select(Preferences.shared.action(forButton: button, profile: profile), in: popup)
        }
    }

    @objc private func overrideChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index == 0 {
            Preferences.shared.deviceOverride = nil
        } else {
            let profiles = DeviceProfile.allCases
            guard index - 1 < profiles.count else { return }
            Preferences.shared.deviceOverride = profiles[index - 1]
        }
        refreshDeviceUI()
    }

    @objc private func buttonActionChanged(_ sender: NSPopUpButton) {
        guard let action = selectedAction(of: sender) else { return }
        Preferences.shared.setAction(action, forButton: sender.tag, profile: detector.activeProfile)
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        Preferences.shared.isCursorModeEnabled = sender.state == .on
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let settings = CursorSetting.allCases
        guard sender.tag >= 0, sender.tag < settings.count else { return }

        let setting = settings[sender.tag]
        Preferences.shared.setValue(sender.doubleValue, for: setting)
        updateValueLabel(for: setting)
    }

    private func updateValueLabel(for setting: CursorSetting) {
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

    @objc private func restoreDefaultsTapped() {
        Preferences.shared.restoreCursorDefaults()

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

/// Lays out subviews from the top, as a scroll view's document should.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Reports where the pointer is inside a scrolling list, so the row under it can be shown.
private final class HoverTrackingView: FlippedView {
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
