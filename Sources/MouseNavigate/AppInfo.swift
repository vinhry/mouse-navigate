import AppKit

/// Identity details shown in the status menu and the About tab.
enum AppInfo {
    static let name = "MouseNavigate"
    static let tagline = "Global mouse side-button navigation, touch gestures and keyboard cursor control for macOS."
    static let developer = "Vinhry"
    static let copyright = "© 2026 Vinhry"
    static let license = "MIT License"

    static let repositoryURL = URL(string: "https://github.com/vinhry/mouse-navigate")!
    static let issuesURL = URL(string: "https://github.com/vinhry/mouse-navigate/issues/new/choose")!
    /// GitHub's answer for the newest published release, which drafts and pre-releases
    /// never are.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/vinhry/mouse-navigate/releases/latest")!

    /// From the bundle the build script wrote, which is the one place the version lives.
    /// Unbundled, as under `swift run`, this is a development build and says so, so it is
    /// never mistaken for a release to be updated from.
    static let version: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"

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
