import AppKit
import CoreGraphics
import MouseNavigateCore

/// Follows sleep, the lock screen and fast user switching, and says when this session stops
/// or starts being the one in front of someone. See `SessionAvailability` for why it matters.
///
/// Main thread only.
@MainActor
final class SessionMonitor {
    private var state = SessionAvailability()
    /// Runs while the session is unavailable, asking the window server how things stand,
    /// so a missed unlock costs a few seconds rather than everything until the next one.
    private var recheckTimer: MainTimer?

    var isAvailable: Bool { state.isAvailable }

    /// Called on the main thread whenever `isAvailable` changes.
    var onChange: ((Bool) -> Void)?
    /// Called when the displays go to sleep. The session stays available, since touching
    /// the mouse wakes them, but anything held is let go: nobody can see it.
    var onDisplaysSleep: (() -> Void)?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, Selector)] = [
            (NSWorkspace.willSleepNotification, #selector(willSleep)),
            (NSWorkspace.didWakeNotification, #selector(didWake)),
            (NSWorkspace.sessionDidResignActiveNotification, #selector(sessionDidResignActive)),
            (NSWorkspace.sessionDidBecomeActiveNotification, #selector(sessionDidBecomeActive)),
            (NSWorkspace.screensDidSleepNotification, #selector(screensDidSleep)),
        ]
        for (name, selector) in workspaceEvents {
            workspace.addObserver(self, selector: selector, name: name, object: nil)
        }

        // The lock screen announces itself to anyone listening. AppKit holds distributed
        // notifications back while an app is inactive, which a menu bar app nearly always
        // is, so these are asked for at once.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(screenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        distributed.addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        reconcile()
    }

    @objc private func willSleep() { apply(.willSleep) }
    @objc private func sessionDidResignActive() { apply(.sessionDidResignActive) }
    @objc private func sessionDidBecomeActive() { apply(.sessionDidBecomeActive) }
    @objc private func screenLocked() { apply(.screenLocked) }
    @objc private func screenUnlocked() { apply(.screenUnlocked) }

    @objc private func didWake() {
        apply(.didWake)
        // A lock that came as the Mac went to sleep may have been announced to nobody.
        reconcile()
    }

    @objc private func screensDidSleep() {
        Log.session.info("Displays asleep; letting go of anything held.")
        onDisplaysSleep?()
    }

    private func apply(_ event: SessionAvailability.Event) {
        guard state.apply(event) else { return }
        changed(because: "\(event)")
    }

    /// Takes the window server's word for whether this session is on the console and
    /// whether its screen is locked.
    private func reconcile() {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let isOnConsole = info["kCGSSessionOnConsoleKey"] as? Bool ?? true
        let isLocked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard state.reconcile(isOnConsole: isOnConsole, isLocked: isLocked) else { return }
        changed(because: "the session state reported by the window server")
    }

    private func changed(because reason: String) {
        let available = state.isAvailable
        if available {
            Log.session.info("Session in front again (\(reason, privacy: .public)); resuming.")
            recheckTimer = nil
        } else {
            Log.session.info("Session out of reach (\(reason, privacy: .public)); standing down.")
            if recheckTimer == nil {
                recheckTimer = MainTimer(after: 5, repeating: 5) { [weak self] in
                    self?.reconcile()
                }
            }
        }
        onChange?(available)
    }
}
