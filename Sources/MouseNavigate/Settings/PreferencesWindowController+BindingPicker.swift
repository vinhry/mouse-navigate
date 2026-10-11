import AppKit
import MouseNavigateCore

/// The action pickers the Mouse and Touch tabs share: building a picker for a slot, showing
/// what a slot is bound to, and storing what is chosen, custom bindings included.
extension PreferencesWindowController {
    /// Every action the slot can take, grouped by category, then the custom kinds. Items
    /// carry a binding's storage value or a `PickerCommand`, so selection never depends on
    /// item positions, which separators would throw off.
    func makeBindingPopup(for slot: BindingSlot) -> FocusReportingPopUpButton {
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
    static func makeHeading(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A custom binding in full, where the picker may have cut it short.
    static func fullDescription(of binding: ActionBinding) -> String {
        if case .openURL(let url) = binding { return "Open \(url.absoluteString)" }
        return binding.displayName
    }

    func trigger(for slot: BindingSlot) -> BindingTrigger {
        switch slot {
        case .button(let number): return .button(number, detector.activeProfile, input: buttonInput, modifiers: buttonModifiers)
        case .touch(let gesture): return .touch(gesture)
        case .character(let gesture): return .character(gesture)
        }
    }

    /// Shows the slot's binding in the current scope. A custom binding gets an item of its
    /// own at the head of the custom group, replacing whichever one was there.
    func refreshBinding(_ slot: BindingSlot) {
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

    func refreshBindings(where include: (BindingSlot) -> Bool = { _ in true }) {
        for slot in bindingPopups.keys where include(slot) {
            refreshBinding(slot)
        }
        updateBindingMarkers()
    }

    @objc func bindingChanged(_ sender: NSPopUpButton) {
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
    func currentBinding(for trigger: BindingTrigger) -> ActionBinding? {
        if let selectedApp {
            return Preferences.shared.appBinding(for: trigger, app: selectedApp)
        }
        return Preferences.shared.globalBinding(for: trigger)
    }

    /// nil in an app's scope hands the slot back to the binding for all apps. A cancelled
    /// editor stores nothing and puts the picker back as it was.
    func store(_ binding: ActionBinding?, for slot: BindingSlot, cancelled: Bool = false) {
        defer {
            refreshBinding(slot)
            if slot.isButton { updateBindingMarkers() }
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
}
