import AppKit
import MouseNavigateCore

/// Tabbed preferences: mouse button mapping per device profile, keyboard cursor bindings
/// plus speed tuning, touch and drawn-character gestures, and an About page. Buttons and
/// gestures can be bound for all apps or for one app at a time.
final class PreferencesWindowController: NSObject {
    /// Something a picker binds. Buttons are numbers alone: the profile they belong to is
    /// whichever one is active when the picker is read.
    private enum BindingSlot: Hashable {
        case button(Int)
        case touch(TouchGesture)
        case character(CharacterGesture)

        var identifier: String {
            switch self {
            case .button(let number): return "button:\(number)"
            case .touch(let gesture): return "touch:\(gesture.rawValue)"
            case .character(let gesture): return "character:\(gesture.rawValue)"
            }
        }

        init?(identifier: String) {
            let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "button":
                guard let number = Int(parts[1]) else { return nil }
                self = .button(number)
            case "touch":
                guard let gesture = TouchGesture(rawValue: parts[1]) else { return nil }
                self = .touch(gesture)
            case "character":
                guard let gesture = CharacterGesture(rawValue: parts[1]) else { return nil }
                self = .character(gesture)
            default:
                return nil
            }
        }
    }

    /// Picker items that open something rather than name a binding. The "#" can begin
    /// neither an action's raw value nor a stored binding's JSON.
    private enum PickerCommand {
        static let inherit = "#inherit"
        static let shortcut = "#shortcut"
        static let launchApp = "#launchApp"
        static let openURL = "#openURL"
        static let runShortcut = "#runShortcut"
        static let addApp = "#addApp"
    }

    /// Marks the one item in a picker that shows its current custom binding.
    private static let customItemTag = 1
    private(set) var window: NSWindow?
    /// The pages and the tab view around them, kept so the window can be fitted to them
    /// again when a page grows or shrinks.
    private var pages: [NSView] = []
    private var tabChrome = NSSize.zero
    private static let windowMargin: CGFloat = 12

    let detector: DeviceDetector
    private let engine: KeyboardCursorEngine
    private let touchMonitor: TouchMonitor
    private let updater: Updater

    private var automaticUpdatesCheckbox: NSButton?
    private var updateStatusLabel: NSTextField?

    private var deviceLabel: NSTextField?
    private var overridePopup: NSPopUpButton?
    private var bindingPopups: [BindingSlot: NSPopUpButton] = [:]
    private lazy var editor = BindingEditor(engine: engine)

    /// nil edits the bindings for all apps; otherwise the app whose own bindings are shown.
    private(set) var selectedApp: String?
    private var scopeControls: [(popup: NSPopUpButton, remove: NSButton, disable: NSButton)] = []
    private var testerLabel: NSTextField?
    /// Which press or drag of each button the Mouse tab's pickers are showing, and with
    /// which modifier keys held.
    private var buttonInput: ButtonInput = .press(.click)
    /// The Press picker's segments, presses first and then the four drags.
    private static let buttonInputs: [ButtonInput] =
        ButtonPress.allCases.map { .press($0) } + DragDirection.allCases.map { .drag($0) }
    private var buttonModifiers: Shortcut.Modifiers = []
    private var pressPicker: NSSegmentedControl?
    private var modifierPicker: NSSegmentedControl?
    /// Names the press and modifiers whose bindings the button pickers are showing.
    private var slotCaption: NSTextField?
    /// Appended to a Press or With segment that has bindings behind it.
    private static let boundMarker = " •"

    /// The Scroll Wheel section's controls, built and refreshed in their own file.
    var scrollSection: ScrollSectionControls?

    private var recorders: [CursorBinding: KeyRecorderButton] = [:]
    private var sliders: [CursorSetting: NSSlider] = [:]
    private var sliderValueLabels: [CursorSetting: NSTextField] = [:]
    private var enableCheckbox: NSButton?

    private var touchEnableCheckbox: NSButton?
    private var leftHandedCheckbox: NSButton?
    private var touchStatusLabel: NSTextField?
    /// The warning that a macOS three-finger gesture takes one of the bound gestures.
    private var touchConflictRow: NSStackView?
    private var touchConflictLabel: NSTextField?
    private var touchPanes: [NSView] = []
    private var characterSourceCheckboxes: [CharacterSource: NSButton] = [:]
    private var showDrawingCheckbox: NSButton?
    private var drawSpreadSlider: NSSlider?
    private var drawSpreadLabel: NSTextField?
    private var strokePreview: StrokePreviewView?
    private var strokePreviewName: NSTextField?
    private var strokePreviewHint: NSTextField?
    /// Each character row's picker, for working out which one the pointer is over.
    private var characterRows: [(gesture: CharacterGesture, row: NSView)] = []
    /// The same for each gesture list, and the label under it that says how the hovered
    /// gesture is done.
    private var gestureRows: [TouchSurface: [(gesture: TouchGesture, row: NSView)]] = [:]
    private var gestureHintLabels: [TouchSurface: NSTextField] = [:]
    /// The picture of the hovered gesture beside each list, and the labels around it.
    private var gesturePreviews: [TouchSurface: TouchGesturePreviewView] = [:]
    private var gesturePreviewNames: [TouchSurface: NSTextField] = [:]
    private var gesturePreviewHints: [TouchSurface: NSTextField] = [:]

    init(detector: DeviceDetector, engine: KeyboardCursorEngine, touchMonitor: TouchMonitor, updater: Updater) {
        self.detector = detector
        self.engine = engine
        self.touchMonitor = touchMonitor
        self.updater = updater
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updaterDidChange),
            name: Updater.didChangeNotification,
            object: nil
        )

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
            refreshUpdatesUI()
            refreshScopeUI()
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
        w.title = "MouseNavigate Settings"
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

        let margin = PreferencesWindowController.windowMargin
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])

        // A tab view takes no size from its pages, so size the window to the larger page
        // plus the tab chrome. A fixed size clipped the cursor tab's lower rows.
        pages = [mousePage, cursorPage, touchPage, aboutPage]
        let probe = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        tabView.frame = probe
        tabChrome = NSSize(
            width: probe.width - tabView.contentRect.width,
            height: probe.height - tabView.contentRect.height
        )
        w.setContentSize(contentSizeForPages())
        window = w

        // Coming back from System Settings, the trackpad warning is read again.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: w
        )

        // Before the window shows: a refresh can make a page taller, and the window with it.
        refreshScopeUI()
        refreshDeviceUI()
        refreshTouchUI()

        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The content size that fits the largest page plus the tab chrome and margins.
    /// Rounded up: the frame is snapped to the pixel grid of whichever display the window
    /// lands on, and a page a fraction short of its content would have to break a
    /// constraint to fit.
    private func contentSizeForPages() -> NSSize {
        let sizes = pages.map(\.fittingSize)
        let margin = PreferencesWindowController.windowMargin
        return NSSize(
            width: ceil((sizes.map(\.width).max() ?? 0) + tabChrome.width + margin * 2),
            height: ceil((sizes.map(\.height).max() ?? 0) + tabChrome.height + margin * 2)
        )
    }

    /// Fits the window to its pages again, keeping its top left corner where it is, for
    /// when a page has grown or shrunk since it was sized.
    private func fitWindowToPages() {
        guard let window, let contentView = window.contentView else { return }
        let size = contentSizeForPages()
        guard size != contentView.frame.size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    @objc private func windowDidBecomeKey() {
        refreshTrackpadConflictUI()
    }

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

        let pressLabel = NSTextField(labelWithString: "Press:")
        pressLabel.alignment = .right
        let pressPicker = NSSegmentedControl(
            labels: PreferencesWindowController.buttonInputs.map { input in
                switch input {
                case .press(let press): return press.displayName
                case .drag(let direction): return direction.displayName
                }
            },
            trackingMode: .selectOne,
            target: self,
            action: #selector(buttonPressChanged(_:))
        )
        pressPicker.selectedSegment = 0
        pressPicker.toolTip = "Which press of each button the pickers below show. A dot marks one with "
            + "bindings. A button with a hold, double-click or drag binding waits to see which "
            + "it was before acting, so bind those only where you want them. A drag is the "
            + "button held while the mouse moves that way."
        self.pressPicker = pressPicker

        let withLabel = NSTextField(labelWithString: "With:")
        withLabel.alignment = .right
        let modifierPicker = NSSegmentedControl(
            labels: PreferencesWindowController.modifierSegments.map(\.label),
            trackingMode: .selectAny,
            target: self,
            action: #selector(buttonModifiersChanged(_:))
        )
        modifierPicker.toolTip = "Bind a button pressed with these keys held. A dot marks a key with "
            + "bindings for this press. Until a combination has a binding of its own, holding "
            + "the keys does what the button does on its own."
        self.modifierPicker = modifierPicker
        for picker in [pressPicker, modifierPicker] {
            PreferencesWindowController.reserveMarkerRoom(in: picker)
        }

        // Says what the pickers below are for, so they read as the bindings of one press
        // rather than as settings of their own.
        let caption = NSTextField(labelWithString: "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        slotCaption = caption

        var rows: [[NSView]] = [
            [overrideLabel, popup], [pressLabel, pressPicker], [withLabel, modifierPicker],
            [NSTextField(labelWithString: ""), caption],
        ]

        for button in Preferences.configurableButtons {
            let buttonLabel = NSTextField(labelWithString: "Button \(button):")
            buttonLabel.alignment = .right

            let actionPopup = makeBindingPopup(for: .button(button))

            rows.append([buttonLabel, actionPopup])
        }

        let grid = makeFormGrid(rows, rowSpacing: 8)
        // Every picker takes the width of the widest, so the column reads as one edge.
        grid.column(at: 1).xPlacement = .fill
        // Keep the profile, press and modifier pickers visually apart from the per-button rows.
        grid.row(at: 2).bottomPadding = 10
        grid.row(at: 3).bottomPadding = 2
        grid.cell(for: pressPicker)?.xPlacement = .leading
        grid.cell(for: modifierPicker)?.xPlacement = .leading

        let tester = NSTextField(labelWithString: "Press a mouse button to identify it…")
        tester.font = .systemFont(ofSize: 11)
        tester.textColor = .secondaryLabelColor
        testerLabel = tester

        let restore = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restoreMouseDefaultsTapped)
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, restore])
        footer.orientation = .horizontal

        let scroll = makeScrollSection()
        let stack = NSStackView(views: [label, makeScopeRow(), grid, tester, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(22, after: tester)
        stack.setCustomSpacing(16, after: scroll)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return makePage(stack)
    }

    /// Fixes each segment at the width its label needs with the marker on, so marking one
    /// later never moves the others.
    private static func reserveMarkerRoom(in picker: NSSegmentedControl) {
        let font = picker.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        for segment in 0..<picker.segmentCount {
            let label = (picker.label(forSegment: segment) ?? "") + boundMarker
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            picker.setWidth(ceil(width) + 14, forSegment: segment)
        }
    }

    /// Marks the presses and modifier keys that have bindings for the profile in the
    /// current scope, and names the ones on show.
    private func updateBindingMarkers() {
        guard let pressPicker, let modifierPicker else { return }
        let bound = Preferences.shared.boundButtonCombinations(profile: detector.activeProfile, app: selectedApp)

        func name(of input: ButtonInput) -> String {
            switch input {
            case .press(let press): return press.displayName
            case .drag(let direction): return direction.displayName
            }
        }
        for (index, input) in PreferencesWindowController.buttonInputs.enumerated() {
            let marked = bound.contains(ButtonCombination(input: input, modifiers: buttonModifiers))
            pressPicker.setLabel(name(of: input) + (marked ? Self.boundMarker : ""), forSegment: index)
        }
        for (index, segment) in PreferencesWindowController.modifierSegments.enumerated() {
            let marked = bound.contains { $0.input == buttonInput && $0.modifiers.contains(segment.modifier) }
            modifierPicker.setLabel(segment.label + (marked ? Self.boundMarker : ""), forSegment: index)
        }

        let shown = name(of: buttonInput)
        slotCaption?.stringValue = buttonModifiers.isEmpty
            ? "Showing the \(shown) bindings"
            : "Showing the \(shown) bindings with \(buttonModifiers.symbols) held"
    }

    /// In one app's scope this hands its buttons and wheel back to the settings for all
    /// apps; otherwise it resets the mouse in use.
    @objc private func restoreMouseDefaultsTapped() {
        guard let window else { return }
        let profile = detector.activeProfile
        let alert = NSAlert()
        if let selectedApp, let app = Preferences.shared.appOverrides[selectedApp] {
            alert.messageText = "Restore the mouse defaults for \(app.name)?"
            alert.informativeText = "\(app.name) gives up its own button bindings and scroll settings and "
                + "goes back to the ones for all apps. Its gestures are kept."
        } else {
            alert.messageText = "Restore the mouse defaults for the \(profile.displayName)?"
            alert.informativeText = "Every button binding of the \(profile.displayName), for every press "
                + "and modifier combination, goes back to its default, and so do the scroll settings "
                + "for all mice and for this mouse. Other mice, apps' own settings, gestures and the "
                + "keyboard cursor are kept."
        }
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let selectedApp = self.selectedApp {
                Preferences.shared.clearAppBindings(app: selectedApp) { key in
                    [
                        SettingsKey.buttonPrefix, SettingsKey.buttonHoldPrefix,
                        SettingsKey.buttonDoublePrefix, SettingsKey.buttonDragPrefix,
                    ].contains(where: key.hasPrefix)
                }
                Preferences.shared.setAppScrollOverride(.none, app: selectedApp)
            } else {
                Preferences.shared.restoreMouseDefaults(profile: profile)
            }
            self.refreshDeviceUI()
        }
    }

    /// ⌃⌥⇧⌘ in menu order, one segment each.
    private static let modifierSegments: [(label: String, modifier: Shortcut.Modifiers)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command),
    ]

    @objc private func buttonModifiersChanged(_ sender: NSSegmentedControl) {
        var modifiers: Shortcut.Modifiers = []
        for (index, segment) in PreferencesWindowController.modifierSegments.enumerated()
        where sender.isSelected(forSegment: index) {
            modifiers.insert(segment.modifier)
        }
        buttonModifiers = modifiers
        refreshBindings { slot in
            if case .button = slot { return true }
            return false
        }
    }

    @objc private func buttonPressChanged(_ sender: NSSegmentedControl) {
        guard PreferencesWindowController.buttonInputs.indices.contains(sender.selectedSegment) else { return }
        buttonInput = PreferencesWindowController.buttonInputs[sender.selectedSegment]
        refreshBindings { slot in
            if case .button = slot { return true }
            return false
        }
    }

    // MARK: - Layout helpers

    /// Wraps a tab's content with margins. Trailing and bottom are inequalities so the
    /// page can be handed more room than it needs, which also lets `fittingSize` report
    /// the size it actually needs.
    private func makePage(_ content: NSView) -> NSView {
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

    /// Every action the slot can take, grouped by category, then the custom kinds. Items
    /// carry a binding's storage value or a `PickerCommand`, so selection never depends on
    /// item positions, which separators would throw off.
    private func makeBindingPopup(for slot: BindingSlot) -> FocusReportingPopUpButton {
        let popup = FocusReportingPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(bindingChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(slot.identifier)
        // A long custom binding is cut short rather than widening the window.
        popup.cell?.lineBreakMode = .byTruncatingTail

        // Headings and the unavailable item stay disabled only if the popup does not
        // enable everything itself.
        popup.autoenablesItems = false

        // Shown only while one app's bindings are being edited.
        popup.addItem(withTitle: "Same as All Apps")
        popup.lastItem?.representedObject = PickerCommand.inherit
        popup.menu?.addItem(.separator())

        // Off first, where it can be found, then every action under its group's heading.
        popup.addItem(withTitle: ButtonAction.disabled.displayName)
        popup.lastItem?.representedObject = ButtonAction.disabled.rawValue

        let trigger = self.trigger(for: slot)
        var previousCategory: ButtonAction.Category?
        for action in ButtonAction.allCases where action != .disabled && trigger.allows(.builtin(action)) {
            if previousCategory != action.category {
                popup.menu?.addItem(.separator())
                if let heading = action.category.displayName {
                    popup.menu?.addItem(PreferencesWindowController.makeHeading(heading))
                }
                previousCategory = action.category
            }

            popup.addItem(withTitle: action.displayName)
            popup.lastItem?.representedObject = action.rawValue
        }

        popup.menu?.addItem(.separator())
        popup.menu?.addItem(PreferencesWindowController.makeHeading("Custom"))
        for (title, command) in [
            ("Keyboard Shortcut…", PickerCommand.shortcut),
            ("Launch App…", PickerCommand.launchApp),
            ("Open URL…", PickerCommand.openURL),
            ("Run Shortcut…", PickerCommand.runShortcut),
        ] {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = command
        }

        // Fixed at the width the built-in actions need, so a picker never grows past its
        // column when it later shows a custom binding.
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let width = popup.widthAnchor.constraint(equalToConstant: popup.intrinsicContentSize.width)
        width.priority = .init(700)
        width.isActive = true

        bindingPopups[slot] = popup
        return popup
    }

    /// A group's title in a picker: a section header where macOS draws one, a greyed item
    /// before that.
    private static func makeHeading(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A custom binding in full, where the picker may have cut it short.
    private static func fullDescription(of binding: ActionBinding) -> String {
        if case .openURL(let url) = binding { return "Open \(url.absoluteString)" }
        return binding.displayName
    }

    private func trigger(for slot: BindingSlot) -> BindingTrigger {
        switch slot {
        case .button(let number): return .button(number, detector.activeProfile, input: buttonInput, modifiers: buttonModifiers)
        case .touch(let gesture): return .touch(gesture)
        case .character(let gesture): return .character(gesture)
        }
    }

    /// Shows the slot's binding in the current scope. A custom binding gets an item of its
    /// own at the head of the custom group, replacing whichever one was there.
    private func refreshBinding(_ slot: BindingSlot) {
        guard let popup = bindingPopups[slot], let menu = popup.menu else { return }
        let trigger = self.trigger(for: slot)
        let preferences = Preferences.shared

        if let item = menu.items.first(where: { $0.tag == Self.customItemTag }) {
            menu.removeItem(item)
        }

        let inherit = popup.item(at: 0)
        let inheritSeparator = popup.item(at: 1)
        inherit?.isHidden = selectedApp == nil
        inheritSeparator?.isHidden = selectedApp == nil
        popup.isEnabled = !preferences.isAppDisabled(selectedApp)
        // Only a custom binding gets a tooltip, with its full description; a gesture's how-to
        // is shown in the open and would only be covered by one.
        popup.toolTip = nil

        let binding: ActionBinding
        if let selectedApp {
            let global = preferences.globalBinding(for: trigger)
            inherit?.title = "Same as All Apps (\(global.displayName))"
            guard let own = preferences.appBinding(for: trigger, app: selectedApp) else {
                popup.selectItem(at: 0)
                return
            }
            binding = own
        } else {
            binding = preferences.globalBinding(for: trigger)
        }

        if binding.builtinAction == nil {
            let index = popup.indexOfItem(withRepresentedObject: PickerCommand.shortcut)
            let item = NSMenuItem(title: binding.displayName, action: nil, keyEquivalent: "")
            item.representedObject = binding.storageValue
            item.tag = Self.customItemTag
            menu.insertItem(item, at: max(index, 0))
            popup.select(item)
            popup.toolTip = Self.fullDescription(of: binding)
            return
        }

        let index = popup.indexOfItem(withRepresentedObject: binding.storageValue)
        if index >= 0 {
            popup.selectItem(at: index)
            return
        }

        // Stored, but not on this picker: an action this trigger does not offer, or one a
        // later version added. Shown as itself rather than as whatever was selected before.
        let unavailable = NSMenuItem(title: "\(binding.displayName) (not available here)", action: nil, keyEquivalent: "")
        unavailable.representedObject = binding.storageValue
        unavailable.tag = Self.customItemTag
        unavailable.isEnabled = false
        let shortcutIndex = popup.indexOfItem(withRepresentedObject: PickerCommand.shortcut)
        menu.insertItem(unavailable, at: max(shortcutIndex, 0))
        popup.select(unavailable)
    }

    private func refreshBindings(where include: (BindingSlot) -> Bool = { _ in true }) {
        for slot in bindingPopups.keys where include(slot) {
            refreshBinding(slot)
        }
        updateBindingMarkers()
    }

    @objc private func bindingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let slot = BindingSlot(identifier: raw),
              let value = sender.selectedItem?.representedObject as? String
        else {
            return
        }
        let trigger = self.trigger(for: slot)
        let current = currentBinding(for: trigger)

        switch value {
        case PickerCommand.inherit:
            store(nil, for: slot)
        case PickerCommand.shortcut:
            guard let window else { return }
            var existing: Shortcut?
            if case .shortcut(let shortcut) = current { existing = shortcut }
            editor.editShortcut(current: existing, in: window) { [weak self] shortcut in
                self?.store(shortcut.map(ActionBinding.shortcut), for: slot, cancelled: shortcut == nil)
            }
        case PickerCommand.launchApp:
            guard let window else { return }
            editor.chooseApp(message: "Choose the app to open", in: window) { [weak self] app in
                self?.store(app.map { .launchApp(bundleID: $0.bundleID, name: $0.name) }, for: slot, cancelled: app == nil)
            }
        case PickerCommand.openURL:
            guard let window else { return }
            var existing: URL?
            if case .openURL(let url) = current { existing = url }
            editor.editURL(current: existing, in: window) { [weak self] url in
                self?.store(url.map(ActionBinding.openURL), for: slot, cancelled: url == nil)
            }
        case PickerCommand.runShortcut:
            guard let window else { return }
            var existing: String?
            if case .runShortcut(let name) = current { existing = name }
            editor.editShortcutName(current: existing, in: window) { [weak self] name in
                self?.store(name.map { .runShortcut(name: $0) }, for: slot, cancelled: name == nil)
            }
        default:
            store(ActionBinding(storageValue: value), for: slot)
        }
    }

    /// The binding the picker shows now, for pre-filling an editor.
    private func currentBinding(for trigger: BindingTrigger) -> ActionBinding? {
        if let selectedApp {
            return Preferences.shared.appBinding(for: trigger, app: selectedApp)
        }
        return Preferences.shared.globalBinding(for: trigger)
    }

    /// nil in an app's scope hands the slot back to the binding for all apps. A cancelled
    /// editor stores nothing and puts the picker back as it was.
    private func store(_ binding: ActionBinding?, for slot: BindingSlot, cancelled: Bool = false) {
        defer {
            refreshBinding(slot)
            if case .button = slot { updateBindingMarkers() }
            // Binding or freeing a gesture macOS also uses changes what there is to warn of.
            if case .touch = slot { refreshTrackpadConflictUI() }
        }
        guard !cancelled else { return }

        let trigger = self.trigger(for: slot)
        if let selectedApp {
            Preferences.shared.setAppBinding(binding, for: trigger, app: selectedApp)
        } else if let binding {
            Preferences.shared.setGlobalBinding(binding, for: trigger)
        }
    }

    // MARK: - App scope

    /// "Applies to" with the apps that have bindings of their own. Built once per tab that
    /// binds anything; every copy shows the same scope.
    private func makeScopeRow() -> NSView {
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

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
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

    @objc private func removeAppTapped() {
        guard let window, let selectedApp,
              let app = Preferences.shared.appOverrides[selectedApp]
        else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Remove \(app.name)?"
        alert.informativeText = "Its own bindings and scroll settings are deleted, MouseNavigate is "
            + "turned back on in it, and it goes back to the settings for all apps."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Preferences.shared.removeApp(bundleID: selectedApp)
            self?.selectedApp = nil
            self?.refreshScopeUI()
        }
    }

    @objc private func appDisabledChanged(_ sender: NSButton) {
        guard let selectedApp else { return }
        Preferences.shared.setApp(selectedApp, disabled: sender.state == .on)
        refreshScopeUI()
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

    // MARK: - Cursor tab

    private func makeCursorTab() -> NSView {
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
        toggles.setHuggingPriority(.required, for: .horizontal)

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

        let restore = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restoreTouchDefaultsTapped)
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, restore])
        footer.orientation = .horizontal

        let scopeRow = makeScopeRow()
        let stack = NSStackView(views: [toggles, hint, status, conflictRow, scopeRow, panePicker, paneContainer, footer])
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

    private func makeGesturePane(for surface: TouchSurface) -> NSView {
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

    /// Shows the gesture the pointer is over: the surface from above, resting fingers in
    /// grey and the ones that act in red.
    private func makeGesturePreviewColumn(for surface: TouchSurface) -> NSView {
        let preview = TouchGesturePreviewView()
        preview.surfaceType = surface
        preview.isMirrored = Preferences.shared.isLeftHanded
        gesturePreviews[surface] = preview

        let column = makePreviewColumn(
            placeholder: "Hover a gesture",
            legend: "Grey rests, red moves",
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
    private func makePreviewColumn(
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
    private func hoveredGesture(at point: NSPoint?, in view: NSView, on surface: TouchSurface) {
        guard let point, let rows = gestureRows[surface] else { return }

        let hit = rows.first { _, row in
            let frame = view.convert(row.bounds, from: row).insetBy(dx: 0, dy: -3)
            return point.y >= frame.minY && point.y <= frame.maxY
        }
        guard let hit else { return }
        show(hit.gesture, on: surface)
    }

    private func show(_ gesture: TouchGesture, on surface: TouchSurface) {
        gesturePreviews[surface]?.gesture = gesture
        gesturePreviewNames[surface]?.stringValue = gesture.displayName
        gesturePreviewHints[surface]?.isHidden = false
        gestureHintLabels[surface]?.stringValue = gesture.hint
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

            let popup = makeBindingPopup(for: .character(gesture))
            popup.onFocus = { [weak self] in
                self?.show(gesture)
            }
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
        row.setHuggingPriority(.required, for: .horizontal)
        PreferencesWindowController.titleControls(in: [caption, slider])
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
    private func hoveredCharacter(at point: NSPoint?, in view: NSView) {
        guard let point else { return }

        let hit = characterRows.first { _, row in
            let frame = view.convert(row.bounds, from: row).insetBy(dx: 0, dy: -3)
            return point.y >= frame.minY && point.y <= frame.maxY
        }
        guard let hit else { return }
        show(hit.gesture)
    }

    private func show(_ gesture: CharacterGesture) {
        strokePreview?.gesture = gesture
        strokePreviewName?.stringValue = gesture.displayName
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

    func refreshTouchUI() {
        let preferences = Preferences.shared
        touchEnableCheckbox?.state = preferences.isTouchEnabled ? .on : .off
        leftHandedCheckbox?.state = preferences.isLeftHanded ? .on : .off
        for preview in gesturePreviews.values {
            preview.isMirrored = preferences.isLeftHanded
        }

        refreshBindings { slot in
            if case .button = slot { return false }
            return true
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
        refreshTrackpadConflictUI()
    }

    /// Warns of the macOS three-finger gestures that take a trackpad gesture bound in the
    /// current scope. The settings are read every time: System Settings changes them
    /// under the window, and the user comes back expecting the warning to follow.
    private func refreshTrackpadConflictUI() {
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

    @objc private func openTrackpadSettingsTapped() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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
        for preview in gesturePreviews.values {
            preview.isMirrored = sender.state == .on
        }
    }

    @objc private func touchPaneChanged(_ sender: NSSegmentedControl) {
        for (index, pane) in touchPanes.enumerated() {
            pane.isHidden = index != sender.selectedSegment
        }
        // Nothing should animate on a pane nobody is looking at.
        gesturePreviews[.trackpad]?.isAnimating = sender.selectedSegment == 0
        gesturePreviews[.magicMouse]?.isAnimating = sender.selectedSegment == 1
        strokePreview?.isAnimating = sender.selectedSegment == 2
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

    /// In one app's scope this hands its gestures back to the ones for all apps rather than
    /// resetting those.
    @objc private func restoreTouchDefaultsTapped() {
        if let selectedApp {
            Preferences.shared.clearAppBindings(app: selectedApp) {
                $0.hasPrefix(SettingsKey.touchPrefix) || $0.hasPrefix(SettingsKey.characterPrefix)
            }
        } else {
            Preferences.shared.restoreTouchDefaults()
        }
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

    private func makeUpdatesSection() -> NSView {
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

    @objc private func updaterDidChange() {
        refreshUpdatesUI()
    }

    @objc private func automaticUpdatesChanged(_ sender: NSButton) {
        Preferences.shared.automaticUpdates = sender.state == .on
        if sender.state == .on, UpdateSchedule.isDue(lastCheck: Preferences.shared.lastUpdateCheck, now: Date()) {
            updater.check(userInitiated: false)
        }
    }

    @objc private func checkForUpdatesTapped() {
        updater.check(userInitiated: true)
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

    func refreshDeviceUI() {
        deviceLabel?.stringValue = detector.statusDescription
        refreshScrollUI()

        if let override = Preferences.shared.deviceOverride,
           let index = DeviceProfile.allCases.firstIndex(of: override) {
            overridePopup?.selectItem(at: index + 1)
        } else {
            overridePopup?.selectItem(at: 0)
        }

        refreshBindings { slot in
            if case .button = slot { return true }
            return false
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

    /// Every control on every tab, after the settings changed under them all at once.
    func refreshAllUI() {
        refreshDeviceUI()
        refreshScopeUI()
        refreshBindings()
        refreshScrollUI()
        refreshCursorUI()
        refreshTouchUI()
        refreshUpdatesUI()
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
