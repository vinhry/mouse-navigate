import XCTest
@testable import MouseNavigateCore

final class DiagnosticsReportTests: XCTestCase {
    private func sample() -> DiagnosticsReport {
        var report = DiagnosticsReport()
        report.version = "0.7.1"
        report.build = "230"
        report.macOS = "Version 26.1 (Build 25B78)"
        report.architecture = "arm64"
        report.location = .applications
        report.accessibility = .granted
        report.inputMonitoring = .denied
        report.isEventTapLive = true
        report.standingDown = [.offInFrontApp]
        report.activeProfile = "Logitech MX Master 4"
        report.devices = [
            .init(model: "MX Master 4", vendorID: 0x046D, productID: 0xB042, resolution: "Logitech MX Master 4"),
            .init(model: nil, vendorID: 0, productID: 0, resolution: "ignored"),
        ]
        report.touch = .listening(surfaces: ["Trackpad"])
        report.settings.keyboardCursor = true
        report.settings.boundButtonCombinations = 6
        report.settings.appsWithOwnSettings = 2
        report.settings.pointer = PointerSettings(accelerationMode: .off)
        report.settings.automaticUpdates = true
        report.updates = "up to date"
        report.otherMouseSoftware = ["Logitech Options+"]
        return report
    }

    func testReadsAsALineEach() {
        let text = sample().text
        XCTAssertTrue(text.hasPrefix("MouseNavigate 0.7.1 (build 230)\n"))
        XCTAssertTrue(text.contains("Input Monitoring: denied"))
        XCTAssertTrue(text.contains("Standing down: turned off in the app in front"))
        XCTAssertTrue(text.contains("  - MX Master 4 [046D:B042] -> Logitech MX Master 4"))
        XCTAssertTrue(text.contains("  - (unnamed) [0000:0000] -> ignored"))
        XCTAssertTrue(text.contains("Touch: listening to Trackpad"))
        XCTAssertTrue(text.contains("  Holds, double-clicks, drags and modifier presses bound for this mouse: 6"))
        XCTAssertTrue(text.contains("Other mouse software running: Logitech Options+"))
        XCTAssertTrue(text.contains("  Pointer: acceleration off"))
    }

    func testCarriesNothingPersonal() {
        let text = sample().text
        for leak in ["com.", "http", "/Users/", "@"] {
            XCTAssertFalse(text.contains(leak), "\(leak) in the report")
        }
    }

    func testEmptyStatesSaySo() {
        var report = DiagnosticsReport()
        report.touch = .unavailable
        let text = report.text
        XCTAssertTrue(text.contains("Standing down: no"))
        XCTAssertTrue(text.contains("Pointing devices:\n  none"))
        XCTAssertTrue(text.contains("Touch: unavailable"))
        XCTAssertTrue(text.contains("Automatic updates: not chosen yet"))
        XCTAssertTrue(text.contains("Other mouse software running: none seen"))
    }

    func testLocation() {
        let home = "/Users/someone"
        XCTAssertEqual(DiagnosticsReport.Location.of(bundlePath: "/Applications/MouseNavigate.app", homeDirectory: home), .applications)
        XCTAssertEqual(DiagnosticsReport.Location.of(bundlePath: "/Users/someone/Applications/MouseNavigate.app", homeDirectory: home), .userApplications)
        XCTAssertEqual(
            DiagnosticsReport.Location.of(bundlePath: "/private/var/folders/x/AppTranslocation/1/d/MouseNavigate.app", homeDirectory: home),
            .translocated
        )
        XCTAssertEqual(DiagnosticsReport.Location.of(bundlePath: "/Users/someone/Desktop/MouseNavigate.app", homeDirectory: home), .elsewhere)
        XCTAssertEqual(DiagnosticsReport.Location.of(bundlePath: "/Users/someone/src/.build/debug", homeDirectory: home), .notABundle)
    }

    func testKnownMouseSoftware() {
        let names = KnownMouseSoftware.names(runningBundleIDs: [
            "com.apple.finder",
            "com.logi.optionsplus",
            "com.logi.optionsplus.updater",
            "com.nuebling.mac-mouse-fix.helper",
            "com.hegenberg.BetterTouchTool",
        ])
        XCTAssertEqual(names, ["BetterTouchTool", "Logitech Options+", "Mac Mouse Fix"])
        XCTAssertEqual(KnownMouseSoftware.names(runningBundleIDs: ["com.apple.Safari"]), [])
    }
}
