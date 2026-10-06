import AppKit
import MouseNavigateCore
import Security

/// Keeps the app current from GitHub Releases.
///
/// Once a day it asks GitHub for the latest release. A newer one is downloaded, unpacked
/// and verified in the background, then offered in the menu as Install and Relaunch; it is
/// never installed unasked, because relaunching drops cursor mode and anything held down
/// in the middle of whatever the user is doing. Main thread only, except where noted.
final class Updater {
    static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.updaterDidChange")

    struct StagedUpdate {
        var version: SemanticVersion
        /// The verified app, unpacked in the caches folder.
        var app: URL
        var releasePage: URL
    }

    enum State {
        case idle
        case checking
        case downloading(SemanticVersion)
        case ready(StagedUpdate)
        case upToDate
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            NotificationCenter.default.post(name: Updater.didChangeNotification, object: self)
        }
    }

    /// Quits the app the way the menu does, so nothing synthetic is left held down.
    var onQuit: (() -> Void)?

    private let work = DispatchQueue(label: "com.vinhry.MouseNavigate.update", qos: .utility)
    /// Nothing about an update is worth keeping on disk: the answer changes, and the
    /// download is unpacked and verified straight away.
    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer?
    private var hasAskedThisLaunch = false
    /// nil when this copy cannot check an update's signature, and so never installs one.
    private let requirement = UpdateVerifier.ownRequirement()

    private static let firstTick: TimeInterval = 20
    private static let tickInterval: TimeInterval = 60 * 60

    static var stagingDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.vinhry.MouseNavigate/Update", isDirectory: true)
    }

    // MARK: - Schedule

    /// Hourly ticks, each deciding whether a daily check is due. Cheap enough to leave
    /// running, and it copes with sleep and clock changes where a 24-hour timer would not.
    ///
    /// A run-loop timer, not a dispatch source: the tick may put up an alert, and a modal
    /// alert run from inside a main-queue block stops every other main-queue block, the
    /// engine's hold and motion timers among them, for as long as it is up.
    func start() {
        work.async {
            try? FileManager.default.removeItem(at: Updater.stagingDirectory)
        }

        let timer = Timer(timeInterval: Updater.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.fireDate = Date(timeIntervalSinceNow: Updater.firstTick)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        switch Preferences.shared.automaticUpdates {
        case nil:
            askOnce()
        case true?:
            if UpdateSchedule.isDue(lastCheck: Preferences.shared.lastUpdateCheck, now: Date()) {
                check(userInitiated: false)
            }
        case false?:
            break
        }
    }

    /// Whether this copy can ever install an update: it needs a Developer ID identity of
    /// its own to hold a download to, and a release version to compare against.
    var canSelfUpdate: Bool {
        requirement != nil && SemanticVersion(AppInfo.version)?.preRelease == nil
    }

    /// Asked after Accessibility is granted, so it never stacks on the permission prompt a
    /// new install already shows. A copy that could never install an update is not asked.
    private func askOnce() {
        guard !hasAskedThisLaunch, canSelfUpdate, AXIsProcessTrusted() else { return }
        hasAskedThisLaunch = true

        let alert = NSAlert()
        alert.messageText = "Keep MouseNavigate up to date?"
        alert.informativeText = "MouseNavigate can check GitHub once a day for a new version and download it "
            + "in the background. Nothing is installed until you choose Install and Relaunch from the menu, "
            + "and only a version signed and notarized for MouseNavigate is ever installed.\n\n"
            + "You can change this in Preferences → About."
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")

        present(alert) { [weak self] response in
            let automatic = response == .alertFirstButtonReturn
            Preferences.shared.automaticUpdates = automatic
            if automatic {
                self?.check(userInitiated: false)
            }
        }
    }

    /// Shows a modal alert from run-loop context, whatever context the caller is in.
    ///
    /// `NSAlert.runModal()` spins a nested run loop. Entered from a block on the main
    /// dispatch queue, that loop serves no other main-queue block until the alert closes,
    /// so the keyboard cursor's hold timer never fires, side buttons with a hold binding
    /// swallow their presses and gesture actions queue up. Entered from the run loop
    /// itself, it serves everything as usual.
    private func present(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        RunLoop.main.perform(inModes: [.common]) {
            NSApp.activate(ignoringOtherApps: true)
            handle(alert.runModal())
        }
    }

    // MARK: - Checking

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// A check the user asked for reports every outcome; a scheduled one stays quiet.
    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        if case .ready(let staged) = state {
            if userInitiated { offerInstall(staged) }
            return
        }
        // A development build, run unbundled, has no release to be updated to.
        guard let current = SemanticVersion(AppInfo.version), current.preRelease == nil else {
            if userInitiated {
                showAlert("Not a release build", "This copy runs from source, so it does not update itself.")
            }
            return
        }

        state = .checking
        var request = URLRequest(url: AppInfo.latestReleaseURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MouseNavigate/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<UpdateCandidate?, UpdateError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if status == 404 {
                // No release published yet.
                result = .success(nil)
            } else if status == 403 || status == 429 {
                result = .failure(.network("GitHub is limiting requests from this network. Try again later."))
            } else if status != 200 {
                result = .failure(.network("GitHub answered with status \(status)."))
            } else if let data, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
                result = .success(UpdateCandidate.select(from: release, current: current))
            } else {
                result = .failure(.network("GitHub's answer could not be read."))
            }

            DispatchQueue.main.async {
                self.finishCheck(result, userInitiated: userInitiated)
            }
        }.resume()
    }

    private enum UpdateError: Error {
        case network(String)
    }

    private func finishCheck(_ result: Result<UpdateCandidate?, UpdateError>, userInitiated: Bool) {
        switch result {
        case .failure(.network(let message)):
            Log.update.notice("Update check failed: \(message, privacy: .public)")
            state = .failed(message)
            if userInitiated { showAlert("Couldn't check for updates", message) }
        case .success(nil):
            Preferences.shared.lastUpdateCheck = Date()
            Log.update.info("Up to date at \(AppInfo.version, privacy: .public).")
            state = .upToDate
            if userInitiated {
                showAlert("MouseNavigate is up to date", "Version \(AppInfo.version) is the newest release.")
            }
        case .success(let candidate?):
            Preferences.shared.lastUpdateCheck = Date()
            download(candidate, userInitiated: userInitiated)
        }
    }

    // MARK: - Downloading

    private func download(_ candidate: UpdateCandidate, userInitiated: Bool) {
        guard let requirement else {
            let message = UpdateVerifier.Failure.unsignedSelf.localizedDescription
            state = .failed(message)
            if userInitiated { showAlert("Version \(candidate.version) is available", message) }
            return
        }

        Log.update.info("Downloading \(candidate.version.description, privacy: .public).")
        state = .downloading(candidate.version)

        var request = URLRequest(url: candidate.download, timeoutInterval: 120)
        request.setValue("MouseNavigate/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        session.downloadTask(with: request) { location, response, error in
            // The downloaded file is deleted when this returns, so it is claimed here.
            let result: Result<StagedUpdate, Error>
            do {
                if let error { throw error }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw StageError("The download failed.")
                }
                result = .success(try Updater.stage(location, candidate: candidate, requirement: requirement))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.finishDownload(result, userInitiated: userInitiated)
            }
        }.resume()
    }

    private struct StageError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Unpacks and verifies a downloaded release. Runs on URLSession's queue.
    private static func stage(
        _ archive: URL,
        candidate: UpdateCandidate,
        requirement: SecRequirement
    ) throws -> StagedUpdate {
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == candidate.size else {
            throw StageError("The download is \(size) bytes; the release lists \(candidate.size).")
        }

        let fileManager = FileManager.default
        let folder = stagingDirectory.appendingPathComponent(candidate.version.description, isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // ditto, not unzip: it keeps the code signature and the stapled ticket intact.
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])

        let app = folder.appendingPathComponent("MouseNavigate.app", isDirectory: true)
        guard fileManager.fileExists(atPath: app.path) else {
            throw StageError("The download does not contain MouseNavigate.app.")
        }
        try UpdateVerifier.verify(app: app, expectedVersion: candidate.version, requirement: requirement)

        return StagedUpdate(version: candidate.version, app: app, releasePage: candidate.releasePage)
    }

    private func finishDownload(_ result: Result<StagedUpdate, Error>, userInitiated: Bool) {
        switch result {
        case .success(let staged):
            Log.update.info("Version \(staged.version.description, privacy: .public) is verified and ready.")
            state = .ready(staged)
            if userInitiated { offerInstall(staged) }
        case .failure(let error):
            let message = error.localizedDescription
            Log.update.error("Update rejected: \(message, privacy: .public)")
            state = .failed(message)
            if userInitiated { showAlert("The update couldn't be prepared", message) }
        }
    }

    // MARK: - Installing

    var readyVersion: SemanticVersion? {
        if case .ready(let staged) = state { return staged.version }
        return nil
    }

    private func offerInstall(_ staged: StagedUpdate) {
        let alert = NSAlert()
        alert.messageText = "MouseNavigate \(staged.version) is ready"
        alert.informativeText = "It has been downloaded and checked. Install it now? MouseNavigate "
            + "quits and reopens, which takes a moment."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")

        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.installAndRelaunch()
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(staged.releasePage)
            default:
                break
            }
        }
    }

    func installAndRelaunch() {
        guard case .ready(let staged) = state else { return }

        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        let writable = FileManager.default.isWritableFile(atPath: folder.path)
            && FileManager.default.isWritableFile(atPath: target.path)
        if let problem = InstallLocationProblem.check(bundlePath: target.path, isWritable: writable) {
            handOver(staged, because: problem)
            return
        }

        do {
            try replace(target, with: staged)
        } catch {
            Log.update.error("Install failed: \(error.localizedDescription, privacy: .public)")
            showAlert("The update couldn't be installed", error.localizedDescription)
            NSWorkspace.shared.activateFileViewerSelecting([staged.app])
            return
        }

        Log.update.info("Installed \(staged.version.description, privacy: .public); relaunching.")
        relaunch(target)
    }

    /// The new app is copied next to the old one first, so the swap itself is a rename on
    /// one volume: whatever happens, the folder holds one whole app or the other.
    private func replace(_ target: URL, with staged: StagedUpdate) throws {
        let fileManager = FileManager.default
        let scratch = target.deletingLastPathComponent()
            .appendingPathComponent(".MouseNavigate-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: scratch) }

        let copy = scratch.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        try Updater.run("/usr/bin/ditto", [staged.app.path, copy.path])

        // The copy is what goes live, so it is what gets checked, not the staged original.
        if let requirement {
            var code: SecStaticCode?
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            guard SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
            else {
                throw StageError("The copied update failed its signature check.")
            }
        }

        _ = try fileManager.replaceItemAt(target, withItemAt: copy)
    }

    /// A small shell waits for this process to exit, then opens the new app. Opening it
    /// sooner would meet the single-instance lock this process still holds.
    private func relaunch(_ app: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path,
        ]
        do {
            try helper.run()
        } catch {
            showAlert("Installed, but couldn't relaunch", "Open MouseNavigate again to finish updating.")
        }
        onQuit?()
    }

    /// Where the app cannot replace itself, the verified app is shown in Finder with what
    /// to do next.
    private func handOver(_ staged: StagedUpdate, because problem: InstallLocationProblem) {
        let reason: String
        switch problem {
        case .translocated:
            reason = "MouseNavigate is running from Downloads, where macOS runs a read-only copy. "
                + "Move the new version into your Applications folder and open it from there."
        case .notWritable:
            reason = "This account can't change the folder MouseNavigate is in. Replace it with the "
                + "new version in Finder, which may ask for an administrator password."
        case .notABundle:
            reason = "MouseNavigate isn't running from an app bundle, so there is nothing to replace."
        }
        showAlert("Install MouseNavigate \(staged.version) by hand", reason)
        NSWorkspace.shared.activateFileViewerSelecting([staged.app])
    }

    // MARK: - Helpers

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        present(alert)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StageError("\((tool as NSString).lastPathComponent) failed with status \(process.terminationStatus).")
        }
    }
}
