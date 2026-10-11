import AppKit
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem

/// The two macOS permissions MouseNavigate works with, and where to grant them.
@MainActor
enum Permissions {
    enum State {
        case granted
        case denied
        case notAsked
    }

    /// Accessibility: the event tap, synthetic input and moving other apps' windows.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show its Accessibility prompt, which also puts the app on the list in
    /// System Settings with its switch off. Returns whether access is already granted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // The value of kAXTrustedCheckOptionPrompt, which Swift imports as a mutable
        // global that strict concurrency checking will not let be read.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as NSDictionary)
    }

    /// Asks macOS to show its Input Monitoring prompt, which also lists the app in System
    /// Settings.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Input Monitoring, which some setups also want before the tap sees keystrokes.
    static var inputMonitoring: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notAsked
        }
    }
}

/// The panes of System Settings where the permissions are switched on.
enum SystemSettingsPane: String {
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    @MainActor
    func open() {
        if let url = URL(string: rawValue) {
            NSWorkspace.shared.open(url)
        }
    }
}
