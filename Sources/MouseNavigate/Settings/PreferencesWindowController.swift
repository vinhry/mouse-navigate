import AppKit
import MouseNavigateCore

/// Tabbed preferences: mouse button mapping per device profile, keyboard cursor bindings
/// plus speed tuning, touch and drawn-character gestures, and an About page. Buttons and
/// gestures can be bound for all apps or for one app at a time.
@MainActor
final class PreferencesWindowController: NSObject {
    /// Something a picker binds. Buttons are numbers alone: the profile they belong to is
    /// whichever one is active when the picker is read.
    enum BindingSlot: Hashable {
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

        var isButton: Bool {
            if case .button = self { return true }
            return false
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
    enum PickerCommand {
        static let inherit = "#inherit"
        static let shortcut = "#shortcut"
        static let launchApp = "#launchApp"
        static let openURL = "#openURL"
        static let runShortcut = "#runShortcut"
        static let addApp = "#addApp"
    }

    /// Marks the one item in a picker that shows its current custom binding.
    static let customItemTag = 1
    var window: NSWindow?
    var tabView: NSTabView?
    /// The pages and the tab view around them, kept so the window can be fitted to them
    /// again when a page grows or shrinks.
    var pages: [NSView] = []
    var tabChrome = NSSize.zero
    static let windowMargin: CGFloat = 12

    let detector: DeviceDetector
    let engine: KeyboardCursorEngine
    let touchMonitor: TouchMonitor
    let updater: Updater
    /// What Copy Diagnostics copies, from the navigator, which knows the tap and pause state.
    var diagnosticsProvider: (() -> DiagnosticsReport)?

    var automaticUpdatesCheckbox: NSButton?
    var updateStatusLabel: NSTextField?
    /// Revert Last Change on the About tab, the line under it, and what that line says once
    /// a change has been taken back, until another can be.
    var revertButton: NSButton?
    var revertStatusLabel: NSTextField?
    var revertNote: String?

    var deviceLabel: NSTextField?
    var overridePopup: NSPopUpButton?
    var bindingPopups: [BindingSlot: FocusReportingPopUpButton] = [:]
    lazy var editor = BindingEditor(engine: engine)

    /// nil edits the bindings for all apps; otherwise the app whose own bindings are shown.
    var selectedApp: String?
    var scopeControls: [(popup: NSPopUpButton, remove: NSButton, disable: NSButton)] = []
    var testerLabel: NSTextField?
    /// Which press or drag of each button the Mouse tab's pickers are showing, and with
    /// which modifier keys held.
    var buttonInput: ButtonInput = .press(.click)
    /// The Press picker's segments, presses first and then the four drags.
    static let buttonInputs: [ButtonInput] =
        ButtonPress.allCases.map { .press($0) } + DragDirection.allCases.map { .drag($0) }
    var buttonModifiers: Shortcut.Modifiers = []
    var pressPicker: NSSegmentedControl?
    var modifierPicker: NSSegmentedControl?
    /// Names the press and modifiers whose bindings the button pickers are showing.
    var slotCaption: NSTextField?
    /// Appended to a Press or With segment that has bindings behind it.
    static let boundMarker = " •"

    /// The Scroll Wheel section's controls, built and refreshed in their own file.
    /// The warning that other mouse software is running, at the top of the Mouse tab, and
    /// the workspace observers that keep it current while the window is open.
    var mouseConflictRow: NSStackView?
    var mouseConflictLabel: NSTextField?
    var workspaceObservers: [NSObjectProtocol] = []
    var scrollSection: ScrollSectionControls?
    var pointerSection: PointerSectionControls?
    var logitechGrid: NSGridView?
    var logitechSection: NSView?

    var recorders: [CursorBinding: KeyRecorderButton] = [:]
    /// The line under the cursor keys that says which two keys just swapped.
    var keySwapNote: NSTextField?
    var sliders: [CursorSetting: NSSlider] = [:]
    var sliderValueLabels: [CursorSetting: NSTextField] = [:]
    var enableCheckbox: NSButton?

    var touchEnableCheckbox: NSButton?
    var leftHandedCheckbox: NSButton?
    var ignoreTypingCheckbox: NSButton?
    var ignoreMouseMovingCheckbox: NSButton?
    var touchStatusLabel: NSTextField?
    var touchPanePicker: NSSegmentedControl?
    var gestureHUDCheckbox: NSButton?
    var touchSurfaceCheckboxes: [TouchSurface: NSButton] = [:]
    /// The Touch tab's report of the gesture that fired last.
    var lastGestureLabel: NSTextField?
    /// The warning that a macOS three-finger gesture takes one of the bound gestures.
    var touchConflictRow: NSStackView?
    var touchConflictLabel: NSTextField?
    var touchPanes: [NSView] = []
    var characterSourceCheckboxes: [CharacterSource: NSButton] = [:]
    var showDrawingCheckbox: NSButton?
    var drawSpreadSlider: NSSlider?
    var drawSpreadLabel: NSTextField?
    var letterStrictnessSlider: NSSlider?
    var letterStrictnessLabel: NSTextField?
    var strokePreview: StrokePreviewView?
    var strokePreviewName: NSTextField?
    var strokePreviewHint: NSTextField?
    /// Each character row's picker, for working out which one the pointer is over.
    var characterRows: [(gesture: CharacterGesture, row: NSView)] = []
    /// The same for each gesture list, and the label under it that says how the hovered
    /// gesture is done.
    var gestureRows: [TouchSurface: [(gesture: TouchGesture, row: NSView)]] = [:]
    var gestureHintLabels: [TouchSurface: NSTextField] = [:]
    /// The picture of the hovered gesture beside each list, and the labels around it.
    var gesturePreviews: [TouchSurface: TouchGesturePreviewView] = [:]
    var gesturePreviewNames: [TouchSurface: NSTextField] = [:]
    var gesturePreviewHints: [TouchSurface: NSTextField] = [:]

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gestureDidFire(_:)),
            name: TouchMonitor.gestureDidFireNotification,
            object: nil
        )
    }

    // MARK: - Window

    /// `tab` is the position of a tab to open on, for a caller that wants a particular one;
    /// otherwise the window opens where it was left.
    func showOrFocus(tab: Int? = nil) {
        if let window {
            if let tab { selectTab(at: tab) }
            refreshUpdatesUI()
            // "made at 3:42 PM" becomes "made on Nov 9 …" once the day has turned.
            refreshRevertUI()
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
        tabView.delegate = self
        self.tabView = tabView

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

        // After the pages are sized, which a tab change does not alter. A stored position
        // that no tab has any more opens the first.
        selectTab(at: tab ?? Preferences.shared.lastSettingsTab ?? 0)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Out of range falls back to the first tab, so a stale value is harmless.
    func selectTab(at position: Int) {
        guard let tabView else { return }
        let count = tabView.numberOfTabViewItems
        tabView.selectTabViewItem(at: (0..<count).contains(position) ? position : 0)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The content size that fits the largest page plus the tab chrome and margins.
    /// Rounded up: the frame is snapped to the pixel grid of whichever display the window
    /// lands on, and a page a fraction short of its content would have to break a
    /// constraint to fit.
    func contentSizeForPages() -> NSSize {
        let sizes = pages.map(\.fittingSize)
        let margin = PreferencesWindowController.windowMargin
        return NSSize(
            width: ceil((sizes.map(\.width).max() ?? 0) + tabChrome.width + margin * 2),
            height: ceil((sizes.map(\.height).max() ?? 0) + tabChrome.height + margin * 2)
        )
    }

    /// Fits the window to its pages again, keeping its top left corner where it is, for
    /// when a page has grown or shrunk since it was sized.
    func fitWindowToPages() {
        guard let window, let contentView = window.contentView else { return }
        let size = contentSizeForPages()
        guard size != contentView.frame.size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    @objc func windowDidBecomeKey() {
        refreshTrackpadConflictUI()
    }

    /// Every control on every tab, after the settings changed under them all at once.
    func refreshAllUI() {
        refreshDeviceUI()
        refreshScopeUI()
        refreshBindings()
        refreshScrollUI()
        refreshPointerUI()
        refreshCursorUI()
        refreshTouchUI()
        refreshUpdatesUI()
        refreshRevertUI()
    }
}

extension PreferencesWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        Preferences.shared.lastSettingsTab = tabView.indexOfTabViewItem(tabViewItem)
    }
}
