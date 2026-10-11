import Foundation

/// Whether this login session is the one in front of someone, awake and unlocked.
///
/// While it is not, nothing a finger, button or wheel does may run. Touch frames keep
/// arriving behind the lock screen and while another user's session is in front, and a
/// gesture bound to launching an app, opening an address or pressing a shortcut would
/// otherwise act in a session nobody is looking at.
///
/// Each kind of interruption has a flag of its own, because they overlap: a Mac that locks
/// as it goes to sleep wakes up still locked, and waking must not undo the lock.
public struct SessionAvailability: Equatable {
    public enum Event: Equatable {
        case willSleep, didWake
        case sessionDidResignActive, sessionDidBecomeActive
        case screenLocked, screenUnlocked
    }

    public private(set) var isAsleep = false
    public private(set) var isSessionInactive = false
    public private(set) var isLocked = false

    public init() {}

    public var isAvailable: Bool {
        !(isAsleep || isSessionInactive || isLocked)
    }

    /// Returns true when the event changed `isAvailable`.
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        let wasAvailable = isAvailable
        switch event {
        case .willSleep: isAsleep = true
        case .didWake: isAsleep = false
        case .sessionDidResignActive: isSessionInactive = true
        case .sessionDidBecomeActive: isSessionInactive = false
        case .screenLocked: isLocked = true
        case .screenUnlocked: isLocked = false
        }
        return wasAvailable != isAvailable
    }

    /// Takes the session's state as the system reports it right now over whatever the
    /// notifications led to, so an unlock announced while nobody was listening cannot keep
    /// the app standing down for good. Whoever asks is running, so the Mac is awake.
    ///
    /// Returns true when this changed `isAvailable`.
    @discardableResult
    public mutating func reconcile(isOnConsole: Bool, isLocked: Bool) -> Bool {
        let wasAvailable = isAvailable
        isAsleep = false
        isSessionInactive = !isOnConsole
        self.isLocked = isLocked
        return wasAvailable != isAvailable
    }
}
