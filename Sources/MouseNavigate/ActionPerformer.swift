import AppKit
import ApplicationServices
import Darwin
import Foundation
import MouseNavigateCore
import notify

/// Carries out a `ButtonAction`, whichever input asked for it. Main thread only.
///
/// Most calls arrive from inside the event tap's callback, where every keystroke and click
/// on the Mac waits. Anything that can take its time, such as launching an app or asking
/// another app to move its window, is decided here and done on the next turn of the run
/// loop, once the event has been answered.
@MainActor
final class ActionPerformer {
    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

    private let cursorEngine: KeyboardCursorEngine
    let windowManager: WindowManager
    private let pointer = CursorOutput()
    private let systemShortcuts = SymbolicHotKeyCache()

    // The handle is never closed: HIServices stays mapped for the life of the process,
    // which costs nothing and cannot pull the code out from under a call in flight.
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private let hiServicesHandle = dlopen(ActionPerformer.hiServicesPath, RTLD_NOW)
    private lazy var coreDockSendNotification: CoreDockSendNotificationFn? = {
        guard
            let hiServicesHandle,
            let symbol = dlsym(hiServicesHandle, "CoreDockSendNotification")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    init(cursorEngine: KeyboardCursorEngine, windowManager: WindowManager) {
        self.cursorEngine = cursorEngine
        self.windowManager = windowManager
    }

    /// Returns false when the binding did not apply, so a caller holding the original event
    /// can let it through untouched.
    @discardableResult
    func perform(_ binding: ActionBinding) -> Bool {
        switch binding {
        case .builtin(let action):
            return perform(action)
        case .shortcut(let shortcut):
            send(shortcut)
            return true
        case .launchApp(let bundleID, _):
            // Finding the app asks Launch Services, which can take its time, so a missing
            // app is only found out about later; the press is spoken for either way.
            later { self.launchApplication(bundleID: bundleID) }
            return true
        case .openURL(let url):
            later {
                if !NSWorkspace.shared.open(url) {
                    Log.actions.notice("Nothing opened \(url.absoluteString, privacy: .public).")
                }
            }
            return true
        case .runShortcut(let name):
            later { self.runShortcut(named: name) }
            return true
        }
    }

    /// Runs `work` once the event being handled has been answered.
    private func later(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            work()
        }
    }

    private func perform(_ action: ButtonAction) -> Bool {
        switch action {
        case .back, .forward:
            guard isSupportedFrontmostApp, let shortcut = action.shortcut else { return false }
            send(shortcut)
            return true
        case .openLinkInNewTab:
            pointer.pressButton(.middle)
            pointer.releaseButton(.middle)
            return true
        case .minimize:
            later { self.windowManager.minimize() }
            return true
        case .zoom:
            later { self.windowManager.zoom() }
            return true
        case .maximizeLeft:
            later { self.windowManager.maximize(.left) }
            return true
        case .maximizeRight:
            later { self.windowManager.maximize(.right) }
            return true
        case .moveResizeWindow:
            // Driven continuously by the touch monitor, never as a one-shot.
            return false
        case .appExpose:
            triggerSystemAppExpose()
            return true
        case .missionControl:
            triggerSystemMissionControl()
            return true
        case .showDesktop:
            triggerShowDesktop()
            return true
        case .spaceLeft:
            if !sendConfiguredSymbolicHotKey(id: SymbolicHotKeys.spaceLeft) {
                sendShortcut(keyCode: CGKeyCode(KeyCode.leftArrow), flags: [.maskControl, .maskSecondaryFn])
            }
            return true
        case .spaceRight:
            if !sendConfiguredSymbolicHotKey(id: SymbolicHotKeys.spaceRight) {
                sendShortcut(keyCode: CGKeyCode(KeyCode.rightArrow), flags: [.maskControl, .maskSecondaryFn])
            }
            return true
        case .screenshot:
            if !sendConfiguredSymbolicHotKey(id: SymbolicHotKeys.screenshotSelection) {
                sendShortcut(keyCode: CGKeyCode(KeyCode.four), flags: [.maskCommand, .maskShift])
            }
            return true
        case .playPause:
            sendMediaKey(.play)
            return true
        case .nextTrack:
            sendMediaKey(.fast)
            return true
        case .previousTrack:
            sendMediaKey(.rewind)
            return true
        case .volumeUp:
            sendMediaKey(.soundUp)
            return true
        case .volumeDown:
            sendMediaKey(.soundDown)
            return true
        case .mute:
            sendMediaKey(.mute)
            return true
        case .launchFinder:
            later { self.launchApplication(bundleID: "com.apple.finder") }
            return true
        case .launchBrowser:
            later {
                let probe = URL(string: "https://example.com")!
                guard let browser = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
                    Log.actions.notice("No default web browser found; nothing launched.")
                    return
                }
                self.launchApplication(at: browser)
            }
            return true
        case .toggleCursorMode:
            cursorEngine.toggleFromMouseButton()
            return true
        case .showHints:
            cursorEngine.showFromMouseButton(hints: true)
            return true
        case .showGrid:
            cursorEngine.showFromMouseButton(hints: false)
            return true
        case .disabled:
            return false
        case .nextTab, .previousTab, .newTab, .closeTab, .reopenClosedTab, .refresh,
             .copy, .paste, .newDocument, .open, .save, .quit, .lockScreen:
            guard let shortcut = action.shortcut else { return false }
            send(shortcut)
            return true
        }
    }

    /// The same answer the per-app bindings were resolved against, so the two never
    /// disagree in the moment after an app switch.
    private var isSupportedFrontmostApp: Bool {
        SupportedApps.isSupported(bundleID: FrontmostApp.shared.bundleID)
    }

    private func launchApplication(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Log.actions.notice("No app found for \(bundleID, privacy: .public); nothing launched.")
            return
        }
        launchApplication(at: url)
    }

    private func launchApplication(at url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Runs a Shortcuts.app shortcut through the `shortcuts` tool, which needs no
    /// automation permission and never brings the Shortcuts app forward. Not waited on:
    /// a shortcut can take as long as it likes.
    private func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            Log.actions.notice(
                "Shortcut \(name, privacy: .public) exited with status \(process.terminationStatus)."
            )
        }
        do {
            try process.run()
        } catch {
            Log.actions.error("Could not run shortcut \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Keyboard shortcuts

    private func send(_ shortcut: Shortcut) {
        // A built-in shortcut names a letter; the key that types it depends on the layout.
        sendShortcut(keyCode: CGKeyCode(KeyboardLayout.shared.keyCode(for: shortcut)), flags: CGEventFlags(shortcut.modifiers))
    }

    private func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = SyntheticEvents.key(keyCode, down: true),
              let keyUp = SyntheticEvents.key(keyCode, down: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        SyntheticEvents.post(keyDown)
        SyntheticEvents.post(keyUp)
    }

    /// Sent as the keyboard's own media keys are, so they reach whichever player macOS
    /// routes those keys to.
    private func sendMediaKey(_ key: MediaKey) {
        for isDown in [true, false] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: MediaKey.modifierFlags(isDown: isDown)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: MediaKey.eventSubtype,
                data1: key.data1(isDown: isDown),
                data2: -1
            ), let cgEvent = event.cgEvent else {
                return
            }
            SyntheticEvents.post(cgEvent)
        }
    }

    // MARK: - System features

    private func triggerSystemAppExpose() {
        if sendCoreDockNotification("com.apple.expose.front.awake") {
            return
        }
        if sendConfiguredSymbolicHotKey(id: SymbolicHotKeys.appExpose) {
            return
        }
        postDockNotification("com.apple.expose.front.awake")
    }

    private func triggerSystemMissionControl() {
        if sendCoreDockNotification("com.apple.expose.awake") {
            return
        }
        if sendConfiguredSymbolicHotKey(id: SymbolicHotKeys.missionControl) {
            return
        }
        postDockNotification("com.apple.expose.awake")
        postDockNotification("com.apple.workspaces.awake")
    }

    private func triggerShowDesktop() {
        if sendCoreDockNotification("com.apple.showdesktop.awake") {
            return
        }
        if sendConfiguredSymbolicHotKey(id: SymbolicHotKeys.showDesktop) {
            return
        }
        postDockNotification("com.apple.showdesktop.awake")
    }

    /// Sends the shortcut set for a macOS feature under System Settings → Keyboard, if it is
    /// on. Read from the cache, then reread in the background, so a shortcut changed there
    /// is the one sent from the next use.
    private func sendConfiguredSymbolicHotKey(id: Int) -> Bool {
        defer { systemShortcuts.reload() }
        guard let hotKey = systemShortcuts.hotKeys[id] else { return false }
        sendShortcut(keyCode: CGKeyCode(hotKey.keyCode), flags: CGEventFlags(rawValue: hotKey.flags))
        return true
    }

    private func sendCoreDockNotification(_ name: String) -> Bool {
        guard let coreDockSendNotification else {
            return false
        }
        coreDockSendNotification(name as CFString, nil)
        return true
    }

    private func postDockNotification(_ name: String) {
        let notification = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            notification,
            nil,
            nil,
            true
        )
        _ = name.withCString { cName in
            notify_post(cName)
        }
    }
}
