import AppKit

/// Identity details shown in the status menu and the About tab.
enum AppInfo {
    static let name = "MouseNavigate"
    static let tagline = "Global mouse side-button navigation, touch gestures and keyboard cursor control for macOS."
    static let developer = "Vinh Ry"
    static let copyright = "© 2026 Vinh Ry"
    static let license = "MIT License"

    static let repositoryURL = URL(string: "https://github.com/vinhry/mouse-navigate")!
    static let issuesURL = URL(string: "https://github.com/vinhry/mouse-navigate/issues/new/choose")!

    static let version: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1"

    static let build: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    static func icon() -> NSImage? {
        if let image = NSImage(named: "AppIcon") {
            return image
        }

        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }

        let fallbackPath =
            FileManager.default.currentDirectoryPath + "/Assets/mouse-navigation-icon.png"
        if let image = NSImage(contentsOfFile: fallbackPath) {
            return image
        }

        return NSApp.applicationIconImage
    }
}
