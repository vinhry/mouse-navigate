import AppKit

/// Exists for reopen, and for being a registered application at all.
///
/// The app runs as a single process that LaunchServices knows about, so a second
/// double-click never starts anything: macOS activates this copy and asks here what to do.
/// Showing preferences is the useful answer — someone clicking a menu bar app a second
/// time is usually looking for its settings, or checking it is alive.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var navigator: MouseNavigator?

    init(navigator: MouseNavigator) {
        self.navigator = navigator
        super.init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.launch.info("Reopened; showing preferences.")
        navigator?.showPreferences()
        return true
    }
}
