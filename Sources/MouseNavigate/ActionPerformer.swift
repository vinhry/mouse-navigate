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
final class ActionPerformer {
    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

    /// Symbolic hot key IDs from `com.apple.symbolichotkeys`.
    private enum SymbolicHotKey {
        static let missionControl = 32
        static let appExpose = 33
        static let showDesktop = 36
        static let spaceLeft = 79
        static let spaceRight = 81
        static let screenshotSelection = 30
    }

    /// `NX_KEYTYPE_*` from IOKit's `ev_keymap.h`: what the media keys on an Apple keyboard
    /// send, so they reach whichever player macOS routes those keys to.
    private enum MediaKey {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
        static let mute: Int32 = 7
        static let play: Int32 = 16
        static let fast: Int32 = 19
        static let rewind: Int32 = 20
    }

    private let cursorEngine: KeyboardCursorEngine
    let windowManager: WindowManager
    private let pointer = CursorOutput()

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
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.actions.notice("No app found for \(bundleID, privacy: .public); nothing launched.")
                return false
            }
            later { self.launchApplication(at: url) }
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
    private func later(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
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
            if !sendConfiguredSymbolicHotKey(id: SymbolicHotKey.spaceLeft) {
                sendShortcut(keyCode: CGKeyCode(KeyCode.leftArrow), flags: [.maskControl, .maskSecondaryFn])
            }
            return true
        case .spaceRight:
            if !sendConfiguredSymbolicHotKey(id: SymbolicHotKey.spaceRight) {
                sendShortcut(keyCode: CGKeyCode(KeyCode.rightArrow), flags: [.maskControl, .maskSecondaryFn])
            }
            return true
        case .screenshot:
            if !sendConfiguredSymbolicHotKey(id: SymbolicHotKey.screenshotSelection) {
                sendShortcut(keyCode: CGKeyCode(KeyCode.four), flags: [.maskCommand, .maskShift])
            }
            return true
        case .playPause:
            sendMediaKey(MediaKey.play)
            return true
        case .nextTrack:
            sendMediaKey(MediaKey.fast)
            return true
        case .previousTrack:
            sendMediaKey(MediaKey.rewind)
            return true
        case .volumeUp:
            sendMediaKey(MediaKey.soundUp)
            return true
        case .volumeDown:
            sendMediaKey(MediaKey.soundDown)
            return true
        case .mute:
            sendMediaKey(MediaKey.mute)
            return true
        case .launchFinder:
            launchApplication(at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
            return true
        case .launchBrowser:
            let probe = URL(string: "https://example.com")!
            launchApplication(at: NSWorkspace.shared.urlForApplication(toOpen: probe))
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

    private func launchApplication(at url: URL?) {
        guard let url else { return }
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
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        // A built-in shortcut names a letter; the key that types it depends on the layout.
        sendShortcut(keyCode: CGKeyCode(KeyboardLayout.shared.keyCode(for: shortcut)), flags: flags)
    }

    private func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        // Tagged so the keyboard path recognises these as ours and ignores them.
        keyDown.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Media keys are not key codes but system-defined events: subtype 8, with the key in
    /// the top half of `data1` and the down (0xA) or up (0xB) state beneath it.
    private func sendMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | (state << 8)),
                data2: -1
            ), let cgEvent = event.cgEvent else {
                return
            }
            cgEvent.setIntegerValueField(.eventSourceUserData, value: CursorOutput.syntheticTag)
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System features

    private func triggerSystemAppExpose() {
        if sendCoreDockNotification("com.apple.expose.front.awake") {
            return
        }
        if sendConfiguredSymbolicHotKey(id: SymbolicHotKey.appExpose) {
            return
        }
        postDockNotification("com.apple.expose.front.awake")
    }

    private func triggerSystemMissionControl() {
        if sendCoreDockNotification("com.apple.expose.awake") {
            return
        }
        if sendConfiguredSymbolicHotKey(id: SymbolicHotKey.missionControl) {
            return
        }
        postDockNotification("com.apple.expose.awake")
        postDockNotification("com.apple.workspaces.awake")
    }

    private func triggerShowDesktop() {
        if sendCoreDockNotification("com.apple.showdesktop.awake") {
            return
        }
        if sendConfiguredSymbolicHotKey(id: SymbolicHotKey.showDesktop) {
            return
        }
        postDockNotification("com.apple.showdesktop.awake")
    }

    private func sendConfiguredSymbolicHotKey(id: Int) -> Bool {
        guard
            let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
            let allHotKeys = domain["AppleSymbolicHotKeys"] as? [String: Any],
            let hotKey = allHotKeys[String(id)] as? [String: Any],
            (hotKey["enabled"] as? Bool) == true,
            let value = hotKey["value"] as? [String: Any],
            let parameters = value["parameters"] as? [Any],
            parameters.count >= 3,
            let keyCodeInt = intValue(from: parameters[1]),
            let flagsInt = intValue(from: parameters[2])
        else {
            return false
        }

        sendShortcut(
            keyCode: CGKeyCode(keyCodeInt),
            flags: CGEventFlags(rawValue: UInt64(flagsInt))
        )
        return true
    }

    private func intValue(from value: Any) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
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
