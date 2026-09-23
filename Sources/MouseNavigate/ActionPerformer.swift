import AppKit
import ApplicationServices
import Darwin
import Foundation
import MouseNavigateCore
import notify

/// Carries out a `ButtonAction`, whichever input asked for it. Main thread only.
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

    /// Returns false when the action did not apply, so a caller holding the original event
    /// can let it through untouched.
    @discardableResult
    func perform(_ action: ButtonAction) -> Bool {
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
            windowManager.minimize()
            return true
        case .zoom:
            windowManager.zoom()
            return true
        case .maximizeLeft:
            windowManager.maximize(.left)
            return true
        case .maximizeRight:
            windowManager.maximize(.right)
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
        case .disabled:
            return false
        case .nextTab, .previousTab, .newTab, .closeTab, .reopenClosedTab, .refresh,
             .copy, .paste, .newDocument, .open, .save, .quit:
            guard let shortcut = action.shortcut else { return false }
            send(shortcut)
            return true
        }
    }

    private var isSupportedFrontmostApp: Bool {
        SupportedApps.isSupported(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func launchApplication(at url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Keyboard shortcuts

    private func send(_ shortcut: Shortcut) {
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        sendShortcut(keyCode: CGKeyCode(shortcut.keyCode), flags: flags)
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
