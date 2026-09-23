import Foundation

/// A multitouch gesture that can be bound to an action. Finger names assume the right hand;
/// the left-handed preference mirrors them.
public enum TouchGesture: String, CaseIterable {
    // Trackpad
    case trackpadOneFixLeftTap
    case trackpadOneFixRightTap
    case trackpadThreeFingerTap
    case trackpadOneFixTwoTap
    case trackpadOneFixTwoSlideDown
    case trackpadOneFixTwoSlideUp
    case trackpadClickTwoSlideDown
    case trackpadTwoFixIndexDoubleTap
    case trackpadIndexToPinky
    case trackpadPinkyToIndex
    case trackpadOneFixOneSlideDown

    // Magic Mouse
    case mouseMiddleFixIndexNearTap
    case mouseMiddleFixIndexFarTap
    case mouseMiddleFixIndexSlideLeft
    case mouseMiddleFixIndexSlideRight
    case mouseIndexFixMiddleSlideLeft
    case mouseIndexFixMiddleSlideRight
    case mouseTwoFixIndexSlideLeft
    case mouseTwoFixIndexSlideRight
    case mouseThreeFingerSwipeUp
    case mouseThreeFingerSwipeDown
    case mouseMiddleClick
    case mouseCornerHold

    public var surface: TouchSurface {
        rawValue.hasPrefix("trackpad") ? .trackpad : .magicMouse
    }

    public static func gestures(for surface: TouchSurface) -> [TouchGesture] {
        allCases.filter { $0.surface == surface }
    }

    /// Gestures that keep going after they are recognised, so they can drive a window drag.
    public var supportsMoveResize: Bool {
        self == .trackpadOneFixOneSlideDown || self == .mouseCornerHold
    }

    public var displayName: String {
        switch self {
        case .trackpadOneFixLeftTap: return "One-Fix Left-Tap"
        case .trackpadOneFixRightTap: return "One-Fix Right-Tap"
        case .trackpadThreeFingerTap: return "Three-Finger Tap"
        case .trackpadOneFixTwoTap: return "One-Fix Two-Tap"
        case .trackpadOneFixTwoSlideDown: return "One-Fix Two-Slide Down"
        case .trackpadOneFixTwoSlideUp: return "One-Fix Two-Slide Up"
        case .trackpadClickTwoSlideDown: return "Click Two-Slide Down"
        case .trackpadTwoFixIndexDoubleTap: return "Two-Fix Index Double-Tap"
        case .trackpadIndexToPinky: return "Index-to-Pinky Taps"
        case .trackpadPinkyToIndex: return "Pinky-to-Index Taps"
        case .trackpadOneFixOneSlideDown: return "One-Fix One-Slide Down"
        case .mouseMiddleFixIndexNearTap: return "Middle-Fix Index Near-Tap"
        case .mouseMiddleFixIndexFarTap: return "Middle-Fix Index Far-Tap"
        case .mouseMiddleFixIndexSlideLeft: return "Middle-Fix Index Slide Left"
        case .mouseMiddleFixIndexSlideRight: return "Middle-Fix Index Slide Right"
        case .mouseIndexFixMiddleSlideLeft: return "Index-Fix Middle Slide Left"
        case .mouseIndexFixMiddleSlideRight: return "Index-Fix Middle Slide Right"
        case .mouseTwoFixIndexSlideLeft: return "Two-Fix Index Slide Left"
        case .mouseTwoFixIndexSlideRight: return "Two-Fix Index Slide Right"
        case .mouseThreeFingerSwipeUp: return "Three-Finger Swipe Up"
        case .mouseThreeFingerSwipeDown: return "Three-Finger Swipe Down"
        case .mouseMiddleClick: return "Middle Click"
        case .mouseCornerHold: return "Corner Hold"
        }
    }

    /// How to perform the gesture, shown as a tooltip.
    public var hint: String {
        switch self {
        case .trackpadOneFixLeftTap:
            return "Rest one finger, then tap with another finger to its left."
        case .trackpadOneFixRightTap:
            return "Rest one finger, then tap with another finger to its right."
        case .trackpadThreeFingerTap:
            return "Tap quickly with three fingers."
        case .trackpadOneFixTwoTap:
            return "Rest one finger, then tap with two other fingers together."
        case .trackpadOneFixTwoSlideDown:
            return "Rest your index finger, then slide your middle and ring fingers down."
        case .trackpadOneFixTwoSlideUp:
            return "Rest your index finger, then slide your middle and ring fingers up."
        case .trackpadClickTwoSlideDown:
            return "Click and hold with your index finger, then slide your middle and ring fingers down."
        case .trackpadTwoFixIndexDoubleTap:
            return "Rest your middle and ring fingers, then double-tap with your index finger."
        case .trackpadIndexToPinky:
            return "Tap index, middle, ring and pinky one after another, then lift them together."
        case .trackpadPinkyToIndex:
            return "Tap pinky, ring, middle and index one after another, then lift them together."
        case .trackpadOneFixOneSlideDown:
            return "Rest your index finger and slide your middle finger down. Move the window with your index finger, tap with the middle finger to switch to resizing, lift to finish."
        case .mouseMiddleFixIndexNearTap:
            return "Rest your middle finger, then tap with your index finger close beside it."
        case .mouseMiddleFixIndexFarTap:
            return "Rest your middle finger, then tap with your index finger further away."
        case .mouseMiddleFixIndexSlideLeft:
            return "Rest your middle finger, then slide your index finger left."
        case .mouseMiddleFixIndexSlideRight:
            return "Rest your middle finger, then slide your index finger right."
        case .mouseIndexFixMiddleSlideLeft:
            return "Rest your index finger, then slide your middle finger left."
        case .mouseIndexFixMiddleSlideRight:
            return "Rest your index finger, then slide your middle finger right."
        case .mouseTwoFixIndexSlideLeft:
            return "Rest your middle and ring fingers, then slide your index finger left."
        case .mouseTwoFixIndexSlideRight:
            return "Rest your middle and ring fingers, then slide your index finger right."
        case .mouseThreeFingerSwipeUp:
            return "Swipe up with index, middle and ring fingers."
        case .mouseThreeFingerSwipeDown:
            return "Swipe down with index, middle and ring fingers."
        case .mouseMiddleClick:
            return "Rest your middle finger and click with your index finger held a little nearer the back of the mouse."
        case .mouseCornerHold:
            return "Hold index and middle fingers on opposite corners, then move the mouse. Lift one finger to switch to resizing."
        }
    }

    public var defaultAction: ButtonAction {
        switch self {
        case .trackpadOneFixLeftTap: return .previousTab
        case .trackpadOneFixRightTap: return .nextTab
        case .trackpadThreeFingerTap: return .openLinkInNewTab
        case .trackpadOneFixTwoTap: return .openLinkInNewTab
        case .trackpadOneFixTwoSlideDown: return .closeTab
        case .trackpadOneFixTwoSlideUp: return .reopenClosedTab
        case .trackpadClickTwoSlideDown: return .quit
        case .trackpadTwoFixIndexDoubleTap: return .refresh
        case .trackpadIndexToPinky: return .minimize
        case .trackpadPinkyToIndex: return .zoom
        case .trackpadOneFixOneSlideDown: return .moveResizeWindow
        case .mouseMiddleFixIndexNearTap: return .nextTab
        case .mouseMiddleFixIndexFarTap: return .previousTab
        case .mouseMiddleFixIndexSlideLeft: return .closeTab
        case .mouseMiddleFixIndexSlideRight: return .refresh
        case .mouseIndexFixMiddleSlideLeft: return .minimize
        case .mouseIndexFixMiddleSlideRight: return .zoom
        case .mouseTwoFixIndexSlideLeft: return .spaceLeft
        case .mouseTwoFixIndexSlideRight: return .spaceRight
        case .mouseThreeFingerSwipeUp: return .showDesktop
        case .mouseThreeFingerSwipeDown: return .missionControl
        case .mouseMiddleClick: return .openLinkInNewTab
        case .mouseCornerHold: return .moveResizeWindow
        }
    }

    /// Actions a gesture may be bound to. Move/resize needs a gesture that lasts.
    public func allows(_ action: ButtonAction) -> Bool {
        action != .moveResizeWindow || supportsMoveResize
    }
}
