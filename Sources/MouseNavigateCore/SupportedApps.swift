import Foundation

/// Apps where Back/Forward map onto the ⌘[ / ⌘] shortcut pair.
public enum SupportedApps {
    public static let bundleIDs: Set<String> = [
        // Apple
        "com.apple.Safari",
        "com.apple.finder",
        // Google
        "com.google.Chrome",
        "com.google.Chrome.canary",
        // Mozilla
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        // Arc
        "company.thebrowser.Browser",
        // Brave
        "com.brave.Browser",
        "com.brave.Browser.beta",
        // Microsoft
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        // Opera
        "com.operasoftware.Opera",
        // Vivaldi
        "com.vivaldi.Vivaldi",
        // Orion
        "com.kagi.kagimacOS",
    ]

    public static func isSupported(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
