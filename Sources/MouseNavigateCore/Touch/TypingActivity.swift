import Foundation

/// When MouseNavigate last pressed a key itself, stamped where the key is posted. Safe from
/// any thread, with a lock of its own so posting never waits on anything else.
public final class OwnKeystrokes: @unchecked Sendable {
    public static let shared = OwnKeystrokes()

    private let lock = NSLock()
    private var lastKeyDown: Double?

    public init() {}

    /// Notes a key-down posted at `time`, in seconds of system uptime.
    public func note(at time: Double) {
        lock.lock()
        lastKeyDown = time
        lock.unlock()
    }

    public var last: Double? {
        lock.lock()
        defer { lock.unlock() }
        return lastKeyDown
    }
}

/// Whether a key was pressed on the keyboard lately, told apart from the keys MouseNavigate
/// presses itself when a gesture fires or a button is bound to a shortcut.
///
/// The system reports how long ago the last key went down, but counts the app's own
/// synthetic keystrokes too (measured: a key posted to the HID tap restarts the hardware
/// counter). So the app stamps each key it posts, and the reported key is taken as its own
/// if it lies near that stamp.
///
/// Measured, too: the counter takes about 0.1 s to notice a posted key, and the key time it
/// then reports lies before the post, by 0.05 to 0.4 s in five runs. So the match looks well
/// before the stamp and only a little after it.
///
/// Blind spot: a real key pressed within `ownKeyAfter` of the app's own, or whose reported
/// time falls that far before it, reads as the app's own, and typing is missed for that
/// press. Whether real keys are reported as early as synthetic ones is not known.
public struct TypingActivity {
    /// A key press this recent is typing, in seconds. Palms and thumbs rest on the
    /// trackpad for a moment after the last key.
    public var window = 0.5
    /// How far before the app's stamp a reported key time may fall and still be its own.
    public var ownKeyBefore = 0.5
    /// How far after the stamp. The key cannot be reported later than it was posted; this
    /// is slack for the two clocks.
    public var ownKeyAfter = 0.1

    public init() {}

    /// `secondsSinceKey` is how long ago the last key went down, as the system reports it;
    /// `lastOwnKey` is when the app last posted one. All on the system uptime clock.
    public func isTyping(now: Double, secondsSinceKey: Double, lastOwnKey: Double?) -> Bool {
        guard secondsSinceKey >= 0, secondsSinceKey <= window else { return false }
        if let lastOwnKey {
            let keyTime = now - secondsSinceKey
            if keyTime >= lastOwnKey - ownKeyBefore, keyTime <= lastOwnKey + ownKeyAfter { return false }
        }
        return true
    }
}
