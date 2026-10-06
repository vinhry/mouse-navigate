import AppKit

/// The app keystrokes are going to, which is the one per-app bindings follow.
///
/// Cached from activation notifications rather than asked for on every event: the event tap
/// runs for every click and keystroke, and has no business making a round trip for an
/// answer that only changes when the user switches apps.
final class FrontmostApp {
    static let shared = FrontmostApp()

    private(set) var bundleID: String?
    private(set) var processIdentifier: pid_t?

    /// Called on the main thread whenever a different app comes to the front.
    var onChange: ((String?) -> Void)?

    private init() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        bundleID = frontmost?.bundleIdentifier
        processIdentifier = frontmost?.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let identifier = app?.bundleIdentifier
        processIdentifier = app?.processIdentifier
        guard identifier != bundleID else { return }
        bundleID = identifier
        onChange?(identifier)
    }
}
