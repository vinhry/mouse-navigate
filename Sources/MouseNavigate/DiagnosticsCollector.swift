import AppKit
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem
import MouseNavigateCore

/// Fills in a `DiagnosticsReport` from the running app. Main thread only.
@MainActor
enum DiagnosticsCollector {
    /// What only the navigator knows.
    struct Context {
        var detector: DeviceDetector
        var touchMonitor: TouchMonitor
        var updater: Updater
        var isEventTapLive: Bool
        var standingDown: [DiagnosticsReport.StandDown]
    }

    static func collect(_ context: Context) -> DiagnosticsReport {
        let preferences = Preferences.shared
        var report = DiagnosticsReport()

        report.version = AppInfo.version
        report.build = AppInfo.build ?? "none"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        report.macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        report.architecture = "arm64"
        #else
        report.architecture = "x86_64"
        #endif
        report.isTranslated = isTranslated
        report.location = .of(bundlePath: Bundle.main.bundlePath, homeDirectory: NSHomeDirectory())

        report.accessibility = AXIsProcessTrusted() ? .granted : .denied
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: report.inputMonitoring = .granted
        case kIOHIDAccessTypeDenied: report.inputMonitoring = .denied
        default: report.inputMonitoring = .notAsked
        }
        report.isEventTapLive = context.isEventTapLive
        report.standingDown = context.standingDown

        let detector = context.detector
        report.activeProfile = detector.activeProfile.displayName
        report.isProfileSetManually = preferences.deviceOverride != nil
        report.devices = detector.describedDevices()

        let touch = context.touchMonitor
        if !touch.isAvailable {
            report.touch = .unavailable
        } else if !preferences.isTouchEnabled {
            report.touch = .off
        } else if touch.isRunning {
            report.touch = .listening(surfaces: touch.surfaces.map { "\($0.surface.displayName) (\($0.name))" })
        } else {
            report.touch = .paused
        }

        var settings = DiagnosticsReport.Settings()
        settings.keyboardCursor = preferences.isCursorModeEnabled
        settings.touch = preferences.isTouchEnabled
        settings.leftHanded = preferences.isLeftHanded
        settings.drawingSources = CharacterSource.allCases.filter(preferences.isCharacterSourceEnabled).count
        settings.scrollOptions = preferences.isAnyScrollSettingActive
        settings.smoothScrolling = preferences.scrollSettings.isSmooth
        settings.boundButtonCombinations = preferences
            .boundButtonCombinations(profile: detector.activeProfile, app: nil).count
        settings.appsWithOwnSettings = preferences.appOverrides.count
        settings.appsTurnedOff = preferences.appOverrides.values.filter(\.isDisabled).count
        settings.automaticUpdates = preferences.automaticUpdates
        report.settings = settings

        report.updates = describe(context.updater)
        report.otherMouseSoftware = KnownMouseSoftware.names(
            runningBundleIDs: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        return report
    }

    /// Whether this Intel build is running on Apple silicon through Rosetta.
    private static var isTranslated: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    private static func describe(_ updater: Updater) -> String {
        var text: String
        switch updater.state {
        case .idle: text = "not checked since launch"
        case .checking: text = "checking"
        case .downloading(let version): text = "downloading \(version)"
        case .ready(let staged): text = "\(staged.version) ready to install"
        case .installing(let version): text = "installing \(version)"
        case .upToDate: text = "up to date"
        case .failed(let message): text = "last attempt failed: \(message)"
        }
        if !updater.canSelfUpdate {
            text += "; this copy cannot update itself"
        }
        if let last = Preferences.shared.lastUpdateCheck {
            let day = ISO8601DateFormatter.string(from: last, timeZone: .current, formatOptions: [.withFullDate])
            text += "; last checked \(day)"
        }
        return text
    }
}
