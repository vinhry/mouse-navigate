import Foundation
import MouseNavigateCore

// Release aid: whether the updater would unpack a zip, decided by the same check it runs,
// so the release workflow never publishes an archive every installed copy would refuse.
// Handled before anything of the app exists, so it takes no lock and asks for nothing.
// Exits 0 if it would, 1 if it would not, and 2 if the zip cannot be read at all.
if let flag = CommandLine.arguments.firstIndex(of: "--check-update-archive") {
    func fail(_ message: String, _ status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
    guard flag + 1 < CommandLine.arguments.count else {
        fail("--check-update-archive needs the path of a zip.", 2)
    }
    let path = CommandLine.arguments[flag + 1]
    let archive: Data
    do {
        archive = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    } catch {
        fail("Can't read \(path): \(error.localizedDescription)", 2)
    }
    do {
        let entries = try UpdateArchive.check(archive)
        let megabytes = Double(entries.reduce(0) { $0 + $1.size }) / 1_048_576
        print("OK: \(entries.count) entries, \(String(format: "%.1f", megabytes)) MB unpacked")
        exit(0)
    } catch {
        // Word for word what the updater would show.
        fail(error.localizedDescription, 1)
    }
}

// The process starts on the main thread, where everything the app does belongs.
MainActor.assumeIsolated {
    let navigator = MouseNavigator()
    navigator.isTouchDebugEnabled = CommandLine.arguments.contains("--touch-debug")

    if CommandLine.arguments.contains("--list-devices") {
        // Support aid: shows what the detector sees without needing any permissions.
        navigator.printDetectedDevices()
    } else {
        // One process, however it was started. Earlier versions spawned a detached copy of
        // themselves with "--daemon" and let this one exit; the flag is still accepted and
        // ignored, so a login item registered by such a version keeps working.
        navigator.run()
    }
}
