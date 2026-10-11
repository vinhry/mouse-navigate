import Foundation

/// What **Copy Diagnostics** puts on the clipboard, to be pasted into a bug report.
///
/// Enough to tell why MouseNavigate is not doing its job on someone else's Mac — which
/// permissions it has, what it sees attached, what is switched on — and nothing about what
/// that person does with it. Every field is a state, a count, a version or a device model:
/// there is nowhere to put an app, a web address, a shortcut or a path.
public struct DiagnosticsReport: Equatable {
    public enum Permission: String, Equatable {
        case granted
        case denied
        case notAsked = "not asked yet"
    }

    public enum Location: String, Equatable {
        case applications = "/Applications"
        case userApplications = "~/Applications"
        case translocated = "a read-only copy macOS made (run from Downloads)"
        case elsewhere = "another folder"
        case notABundle = "not an app bundle (run from source)"

        public static func of(bundlePath: String, homeDirectory: String) -> Location {
            guard bundlePath.hasSuffix(".app") else { return .notABundle }
            if bundlePath.contains("/AppTranslocation/") { return .translocated }
            if bundlePath.hasPrefix("/Applications/") { return .applications }
            if bundlePath.hasPrefix(homeDirectory + "/Applications/") { return .userApplications }
            return .elsewhere
        }
    }

    /// Why MouseNavigate is standing aside, if it is.
    public enum StandDown: String, CaseIterable, Equatable {
        case paused = "paused from the menu"
        case offInFrontApp = "turned off in the app in front"
        case sessionAway = "asleep, locked or another user in front"
    }

    public struct Device: Equatable {
        public var model: String?
        public var vendorID: Int
        public var productID: Int
        /// The profile it resolves to, or why it has none.
        public var resolution: String

        public init(model: String?, vendorID: Int, productID: Int, resolution: String) {
            self.model = model
            self.vendorID = vendorID
            self.productID = productID
            self.resolution = resolution
        }
    }

    public enum Touch: Equatable {
        case unavailable
        case off
        case paused
        case listening(surfaces: [String])
    }

    public struct Settings: Equatable {
        public var keyboardCursor = false
        public var touch = false
        public var leftHanded = false
        public var drawingSources = 0
        public var scrollOptions = false
        public var smoothScrolling = false
        /// Presses other than a plain click, for any button, bound to something of their own.
        public var boundButtonCombinations = 0
        public var appsWithOwnSettings = 0
        public var appsTurnedOff = 0
        public var automaticUpdates: Bool?

        public init() {}
    }

    public var version = ""
    public var build = ""
    public var macOS = ""
    public var architecture = ""
    public var isTranslated = false
    public var location = Location.elsewhere
    public var accessibility = Permission.notAsked
    public var inputMonitoring = Permission.notAsked
    public var isEventTapLive = false
    public var standingDown: [StandDown] = []
    public var activeProfile = ""
    public var isProfileSetManually = false
    public var devices: [Device] = []
    public var touch = Touch.unavailable
    public var settings = Settings()
    public var updates = ""
    public var otherMouseSoftware: [String] = []

    public init() {}

    public var text: String {
        var lines = [
            "MouseNavigate \(version) (build \(build))",
            "macOS \(macOS), \(architecture)\(isTranslated ? " under Rosetta" : "")",
            "Running from: \(location.rawValue)",
            "Accessibility: \(accessibility.rawValue)",
            "Input Monitoring: \(inputMonitoring.rawValue)",
            "Event tap: \(isEventTapLive ? "listening" : "not listening")",
            "Standing down: "
                + (standingDown.isEmpty ? "no" : standingDown.map(\.rawValue).joined(separator: "; ")),
            "Profile: \(activeProfile)\(isProfileSetManually ? " (set manually)" : "")",
            "Pointing devices:",
        ]
        if devices.isEmpty {
            lines.append("  none")
        }
        for device in devices {
            let ids = String(format: "%04X:%04X", device.vendorID, device.productID)
            lines.append("  - \(device.model ?? "(unnamed)") [\(ids)] -> \(device.resolution)")
        }

        switch touch {
        case .unavailable: lines.append("Touch: unavailable (MultitouchSupport did not load)")
        case .off: lines.append("Touch: off")
        case .paused: lines.append("Touch: on, standing down")
        case .listening(let surfaces):
            lines.append("Touch: listening to " + (surfaces.isEmpty ? "no surfaces" : surfaces.joined(separator: ", ")))
        }

        let s = settings
        let automatic: String
        switch s.automaticUpdates {
        case true?: automatic = "on"
        case false?: automatic = "off"
        case nil: automatic = "not chosen yet"
        }
        lines += [
            "Settings:",
            "  Keyboard cursor: \(onOff(s.keyboardCursor))",
            "  Touch gestures: \(onOff(s.touch)), left-handed \(onOff(s.leftHanded)), "
                + "\(s.drawingSources) drawing source(s)",
            "  Scroll options: \(onOff(s.scrollOptions)), smooth scrolling \(onOff(s.smoothScrolling))",
            "  Holds, double-clicks, drags and modifier presses bound for this mouse: "
                + "\(s.boundButtonCombinations)",
            "  Apps with their own settings: \(s.appsWithOwnSettings), turned off in: \(s.appsTurnedOff)",
            "  Automatic updates: \(automatic)",
            "Updates: \(updates)",
            "Other mouse software running: "
                + (otherMouseSoftware.isEmpty ? "none seen" : otherMouseSoftware.joined(separator: ", ")),
        ]
        return lines.joined(separator: "\n")
    }

    private func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }
}

/// Other apps that take over mouse buttons, the wheel or gestures, which can fight
/// MouseNavigate for the same input. Known by the start of their bundle identifiers.
public enum KnownMouseSoftware {
    static let prefixes: [(prefix: String, name: String)] = [
        ("com.logi.", "Logitech Options+"),
        ("com.logitech.", "Logitech Options"),
        ("com.nuebling.mac-mouse-fix", "Mac Mouse Fix"),
        ("com.lujjjh.LinearMouse", "LinearMouse"),
        ("com.hegenberg.BetterTouchTool", "BetterTouchTool"),
        ("jp.plentycom.", "SteerMouse"),
        ("org.pqrs.Karabiner", "Karabiner-Elements"),
        ("com.pilotmoon.scroll-reverser", "Scroll Reverser"),
    ]

    /// The names of those running, once each, in a stable order.
    public static func names(runningBundleIDs: [String]) -> [String] {
        let found = Set(runningBundleIDs.compactMap { bundleID in
            prefixes.first { bundleID.hasPrefix($0.prefix) }?.name
        })
        return found.sorted()
    }
}
