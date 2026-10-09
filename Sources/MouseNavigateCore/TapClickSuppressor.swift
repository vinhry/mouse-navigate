import Foundation

/// Holds back the click macOS makes out of a trackpad tap that was already a gesture.
///
/// With Tap to click on, a tap that MouseNavigate recognised as a gesture also reaches the
/// app as a click, which usually lands after the gesture's action. Terminal and Finder tabs
/// are windows, so a click aimed at the old tab brings it straight back after a One-Fix tap
/// has switched away from it. The next click, if it comes soon, is that one and is held
/// back, release and all. A click that already came a moment ago was that one instead, and
/// nothing is armed, so a real click after the tap is never lost.
///
/// Keeps no clock: every call is given the time.
public struct TapClickSuppressor: Equatable {
    /// How long after a tap gesture its click may still arrive.
    public let window: TimeInterval
    /// How recently a click must have come to be taken for the tap's own click that
    /// arrived first.
    public let lead: TimeInterval

    private var deadline: TimeInterval = 0
    private var lastClick: TimeInterval = -.infinity

    public init(window: TimeInterval = 0.3, lead: TimeInterval = 0.15) {
        self.window = window
        self.lead = lead
    }

    /// A trackpad tap has just become a gesture with an action.
    public mutating func tapBecameGesture(at now: TimeInterval) {
        guard now - lastClick > lead else { return }
        deadline = now + window
    }

    /// A real left click has arrived. True when it is the tap's own click and must be
    /// swallowed, together with its release.
    public mutating func leftMouseDown(at now: TimeInterval) -> Bool {
        lastClick = now
        guard now < deadline else { return false }
        deadline = 0
        return true
    }

    /// Forgets an armed window, for pausing and switching apps.
    public mutating func reset() {
        deadline = 0
    }
}
