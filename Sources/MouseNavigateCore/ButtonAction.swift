import Foundation

public enum ButtonAction: String, CaseIterable {
    case back = "back"
    case forward = "forward"
    case appExpose = "appExpose"
    case missionControl = "missionControl"
    case toggleCursorMode = "toggleCursorMode"
    case disabled = "disabled"

    public var displayName: String {
        switch self {
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        case .appExpose: return "App Exposé"
        case .missionControl: return "Mission Control"
        case .toggleCursorMode: return "Toggle Keyboard Cursor"
        case .disabled: return "Disabled"
        }
    }
}
