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
    private var window: NSWindow?

    private let detector: DeviceDetector
    private let engine: KeyboardCursorEngine
    private let touchMonitor: TouchMonitor

    private var deviceLabel: NSTextField?
    private var overridePopup: NSPopUpButton?
    private var bindingPopups: [BindingSlot: NSPopUpButton] = [:]
    private lazy var editor = BindingEditor(engine: engine)

    /// nil edits the bindings for all apps; otherwise the app whose own bindings are shown.
    private var selectedApp: String?
    private var scopeControls: [(popup: NSPopUpButton, remove: NSButton, disable: NSButton)] = []
    private var testerLabel: NSTextField?

    private var recorders: [CursorBinding: KeyRecorderButton] = [:]
    private var sliders: [CursorSetting: NSSlider] = [:]
    private var sliderValueLabels: [CursorSetting: NSTextField] = [:]
    private var enableCheckbox: NSButton?

    private var touchEnableCheckbox: NSButton?
    private var leftHandedCheckbox: NSButton?
    private var touchStatusLabel: NSTextField?
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

        refreshScopeUI()
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

            let actionPopup = makeBindingPopup(for: .button(button))

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

        let stack = NSStackView(views: [label, makeScopeRow(), grid, tester])
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

    /// Every action the slot can take, grouped by category, then the custom kinds. Items
    /// carry a binding's storage value or a `PickerCommand`, so selection never depends on
    /// item positions, which separators would throw off.
    private func makeBindingPopup(for slot: BindingSlot) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(bindingChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(slot.identifier)
        // A long custom binding is cut short rather than widening the window.
        popup.cell?.lineBreakMode = .byTruncatingTail

        // Shown only while one app's bindings are being edited.
        popup.addItem(withTitle: "Same as All Apps")
        popup.lastItem?.representedObject = PickerCommand.inherit
        popup.menu?.addItem(.separator())

        let trigger = self.trigger(for: slot)
        var previousCategory: ButtonAction.Category?
        for action in ButtonAction.allCases where trigger.allows(.builtin(action)) {
            if let previousCategory, previousCategory != action.category {
                popup.menu?.addItem(.separator())
            }
            previousCategory = action.category

            popup.addItem(withTitle: action.displayName)
            popup.lastItem?.representedObject = action.rawValue
        }

        popup.menu?.addItem(.separator())
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

    private func trigger(for slot: BindingSlot) -> BindingTrigger {
        switch slot {
        case .button(let number): return .button(number, detector.activeProfile)
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
            return
        }

        let index = popup.indexOfItem(withRepresentedObject: binding.storageValue)
        if index >= 0 {
            popup.selectItem(at: index)
        }
    }

    private func refreshBindings(where include: (BindingSlot) -> Bool = { _ in true }) {
        for slot in bindingPopups.keys where include(slot) {
            refreshBinding(slot)
        }
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
            editor.chooseApp(in: window) { [weak self] app in
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
        defer { refreshBinding(slot) }
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

    private func refreshScopeUI() {
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
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        guard value == PickerCommand.addApp else {
            selectedApp = value.isEmpty ? nil : value
            refreshScopeUI()
            return
        }

        guard let window else { return }
        editor.chooseApp(in: window) { [weak self] app in
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
        alert.informativeText = "Its own bindings are deleted, and it goes back to the ones for all apps."
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

        let scopeRow = makeScopeRow()
        let stack = NSStackView(views: [toggles, hint, status, scopeRow, panePicker, paneContainer, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: status)
        stack.setCustomSpacing(14, after: scopeRow)
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

            let popup = makeBindingPopup(for: .touch(gesture))
            popup.toolTip = gesture.hint
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

            let popup = makeBindingPopup(for: .character(gesture))
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
                $0.hasPrefix("touch.") || $0.hasPrefix("character.")
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
