import Foundation

/// A macOS trackpad gesture made with the same three fingers as some of MouseNavigate's.
/// The app only listens to the touches, so when one of these is on, macOS acts on the
/// fingers as well: a two-finger slide beside a resting finger opens Mission Control, say,
/// at the same time as it closes a tab.
public enum MacOSTrackpadGesture: CaseIterable, Hashable {
    /// Mission Control and App Exposé on a three-finger swipe up and down.
    case threeFingerVerticalSwipe
    /// Three-finger drag, under Accessibility → Pointer Control.
    case threeFingerDrag
    /// Look up & data detectors on a three-finger tap.
    case threeFingerTap

    /// The key System Settings writes, in `com.apple.AppleMultitouchTrackpad` for the
    /// built-in trackpad and in the Bluetooth trackpad domain for an external one.
    public var defaultsKey: String {
        switch self {
        case .threeFingerVerticalSwipe: return "TrackpadThreeFingerVertSwipeGesture"
        case .threeFingerDrag: return "TrackpadThreeFingerDrag"
        case .threeFingerTap: return "TrackpadThreeFingerTapGesture"
        }
    }

    /// What macOS does when the key has never been written: the swipes start on three
    /// fingers, three-finger drag is off, and Look Up starts on Force Click.
    public var isOnByDefault: Bool {
        self == .threeFingerVerticalSwipe
    }

    /// The gesture as a sentence subject, the way System Settings names it.
    public var settingDescription: String {
        switch self {
        case .threeFingerVerticalSwipe:
            return "Mission Control and App Exposé are on a three-finger swipe in macOS"
        case .threeFingerDrag:
            return "Three-finger drag is on in macOS"
        case .threeFingerTap:
            return "Look up & data detectors is on a three-finger tap in macOS"
        }
    }

    /// Where to turn it off or move it to four fingers.
    public var remedy: String {
        switch self {
        case .threeFingerVerticalSwipe:
            return "Set them to four fingers in System Settings → Trackpad → More Gestures."
        case .threeFingerDrag:
            return "Turn it off in System Settings → Accessibility → Pointer Control → Trackpad Options."
        case .threeFingerTap:
            return "Set it to Force Click or off in System Settings → Trackpad."
        }
    }

    /// The MouseNavigate gestures macOS acts on at the same time. A horizontal three-finger
    /// swipe is left out: no trackpad gesture here slides three fingers sideways.
    public var collidingGestures: [TouchGesture] {
        switch self {
        case .threeFingerVerticalSwipe, .threeFingerDrag:
            return [.trackpadOneFixTwoSlideDown, .trackpadOneFixTwoSlideUp, .trackpadClickTwoSlideDown]
        case .threeFingerTap:
            return [.trackpadThreeFingerTap, .trackpadOneFixTwoTap]
        }
    }
}

/// The macOS trackpad settings that matter, as read from the system's own preferences.
/// A missing value means the key has never been written, so macOS's default applies.
public struct MacOSTrackpadSettings: Equatable {
    public var values: [MacOSTrackpadGesture: Int]

    public init(values: [MacOSTrackpadGesture: Int] = [:]) {
        self.values = values
    }

    /// The gestures macOS has on. A value of 0 is off; anything else is on, since the
    /// swipe and tap keys store the finger count and the drag key stores a flag.
    public var activeGestures: [MacOSTrackpadGesture] {
        MacOSTrackpadGesture.allCases.filter { gesture in
            if let value = values[gesture] {
                return value != 0
            }
            return gesture.isOnByDefault
        }
    }

    /// The active gestures that take a MouseNavigate gesture bound to something, with the
    /// gestures they take. One bound to Disabled is not worth a warning.
    public func conflicts(isBound: (TouchGesture) -> Bool) -> [TrackpadConflict] {
        activeGestures.compactMap { gesture in
            let taken = gesture.collidingGestures.filter(isBound)
            return taken.isEmpty ? nil : TrackpadConflict(gesture: gesture, taken: taken)
        }
    }
}

/// One macOS gesture and the bound MouseNavigate gestures it takes.
public struct TrackpadConflict: Equatable {
    public let gesture: MacOSTrackpadGesture
    public let taken: [TouchGesture]

    public init(gesture: MacOSTrackpadGesture, taken: [TouchGesture]) {
        self.gesture = gesture
        self.taken = taken
    }
}

public enum TrackpadConflictMessage {
    /// One sentence per conflict naming the setting and the gestures it takes, then where
    /// to change it; nil when there is nothing to say.
    public static func text(for conflicts: [TrackpadConflict]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        return conflicts.map { conflict in
            "\(conflict.gesture.settingDescription), which takes "
                + "\(list(conflict.taken.map(\.displayName))). \(conflict.gesture.remedy)"
        }.joined(separator: " ")
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
