import Foundation

/// Where drawn characters can come from.
public enum CharacterSource: String, CaseIterable {
    case trackpad
    case magicMouseRightDrag
    case middleButtonDrag

    public var displayName: String {
        switch self {
        case .trackpad: return "Draw with two spread fingers on the trackpad"
        case .magicMouseRightDrag: return "Draw while holding the right mouse button"
        case .middleButtonDrag: return "Draw while holding the middle button"
        }
    }

    /// Button drags hold back the click until release, which delays context menus, so they
    /// stay off until asked for.
    public var isEnabledByDefault: Bool {
        self == .trackpad
    }
}
