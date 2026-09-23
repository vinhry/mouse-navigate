import Foundation

/// Something the app can do in response to input. Shared by mouse buttons, touch gestures
/// and drawn characters, despite the name, which is kept because raw values are persisted.
public enum ButtonAction: String, CaseIterable {
    case back = "back"
    case forward = "forward"
    case nextTab = "nextTab"
    case previousTab = "previousTab"
    case newTab = "newTab"
    case closeTab = "closeTab"
    case reopenClosedTab = "reopenClosedTab"
    case refresh = "refresh"
    case openLinkInNewTab = "openLinkInNewTab"

    case copy = "copy"
    case paste = "paste"
    case newDocument = "newDocument"
    case open = "open"
    case save = "save"
    case quit = "quit"

    case minimize = "minimize"
    case zoom = "zoom"
    case maximizeLeft = "maximizeLeft"
    case maximizeRight = "maximizeRight"
    case moveResizeWindow = "moveResizeWindow"

    case appExpose = "appExpose"
    case missionControl = "missionControl"
    case showDesktop = "showDesktop"
    case spaceLeft = "spaceLeft"
    case spaceRight = "spaceRight"

    case launchFinder = "launchFinder"
    case launchBrowser = "launchBrowser"

    case toggleCursorMode = "toggleCursorMode"
    case disabled = "disabled"

    public enum Category: CaseIterable {
        case browsing, editing, window, system, launch, app, none
    }

    public var category: Category {
        switch self {
        case .back, .forward, .nextTab, .previousTab, .newTab, .closeTab, .reopenClosedTab,
             .refresh, .openLinkInNewTab:
            return .browsing
        case .copy, .paste, .newDocument, .open, .save, .quit:
            return .editing
        case .minimize, .zoom, .maximizeLeft, .maximizeRight, .moveResizeWindow:
            return .window
        case .appExpose, .missionControl, .showDesktop, .spaceLeft, .spaceRight:
            return .system
        case .launchFinder, .launchBrowser:
            return .launch
        case .toggleCursorMode:
            return .app
        case .disabled:
            return .none
        }
    }

    public var displayName: String {
        switch self {
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        case .nextTab: return "Next Tab (⌃⇥)"
        case .previousTab: return "Previous Tab (⌃⇧⇥)"
        case .newTab: return "New Tab (⌘T)"
        case .closeTab: return "Close Tab / Window (⌘W)"
        case .reopenClosedTab: return "Reopen Closed Tab (⌘⇧T)"
        case .refresh: return "Refresh (⌘R)"
        case .openLinkInNewTab: return "Open Link in New Tab (Middle Click)"
        case .copy: return "Copy (⌘C)"
        case .paste: return "Paste (⌘V)"
        case .newDocument: return "New (⌘N)"
        case .open: return "Open (⌘O)"
        case .save: return "Save (⌘S)"
        case .quit: return "Quit App (⌘Q)"
        case .minimize: return "Minimize Window"
        case .zoom: return "Maximize Window"
        case .maximizeLeft: return "Maximize Left"
        case .maximizeRight: return "Maximize Right"
        case .moveResizeWindow: return "Move / Resize Window"
        case .appExpose: return "App Exposé"
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show Desktop"
        case .spaceLeft: return "Move Left a Space"
        case .spaceRight: return "Move Right a Space"
        case .launchFinder: return "Launch Finder"
        case .launchBrowser: return "Launch Default Browser"
        case .toggleCursorMode: return "Toggle Keyboard Cursor"
        case .disabled: return "Disabled"
        }
    }

    /// Move/resize follows the fingers for as long as they stay down, which a single button
    /// press cannot express.
    public var isAvailableForButtons: Bool {
        self != .moveResizeWindow
    }

    /// The key combination for actions that are nothing more than a shortcut.
    public var shortcut: Shortcut? {
        switch self {
        case .back: return Shortcut(KeyCode.leftBracket, [.command])
        case .forward: return Shortcut(KeyCode.rightBracket, [.command])
        case .nextTab: return Shortcut(KeyCode.tab, [.control])
        case .previousTab: return Shortcut(KeyCode.tab, [.control, .shift])
        case .newTab: return Shortcut(KeyCode.t, [.command])
        case .closeTab: return Shortcut(KeyCode.w, [.command])
        case .reopenClosedTab: return Shortcut(KeyCode.t, [.command, .shift])
        case .refresh: return Shortcut(KeyCode.r, [.command])
        case .copy: return Shortcut(KeyCode.c, [.command])
        case .paste: return Shortcut(KeyCode.v, [.command])
        case .newDocument: return Shortcut(KeyCode.n, [.command])
        case .open: return Shortcut(KeyCode.o, [.command])
        case .save: return Shortcut(KeyCode.s, [.command])
        case .quit: return Shortcut(KeyCode.q, [.command])
        default: return nil
        }
    }
}

/// A key plus modifiers, kept free of CoreGraphics so the core library stays testable.
public struct Shortcut: Equatable {
    public struct Modifiers: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let option = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(_ keyCode: UInt16, _ modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
