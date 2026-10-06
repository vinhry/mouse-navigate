import Foundation

/// Keys whose press cursor mode swallowed and which are still physically down.
///
/// The system goes on autorepeating a key the tap consumed, and sends its release in the
/// end. If cursor mode has ended by then, none of that may reach the frontmost app: a press
/// it never saw cannot be followed by repeats or a release, or letting go of the activation
/// key a beat after a movement key would type that letter.
public struct HeldKeySwallower: Equatable {
    private var held: Set<UInt16> = []

    public init() {}

    public var isEmpty: Bool { held.isEmpty }

    public func contains(_ keyCode: UInt16) -> Bool {
        held.contains(keyCode)
    }

    /// Records that the press of `keyCode` was swallowed while the key stays down.
    public mutating func hold(_ keyCode: UInt16) {
        held.insert(keyCode)
    }

    /// Whether a key-down is to be swallowed. A repeat of a held key is. A fresh press of a
    /// held key means its release was missed, so the key is forgotten and the press is the
    /// caller's to handle as it sees fit.
    public mutating func keyDown(_ keyCode: UInt16, isRepeat: Bool) -> Bool {
        guard held.contains(keyCode) else { return false }
        if isRepeat { return true }
        held.remove(keyCode)
        return false
    }

    /// Whether a key-up is to be swallowed, which it is once for every held key.
    public mutating func keyUp(_ keyCode: UInt16) -> Bool {
        held.remove(keyCode) != nil
    }

    /// Lets a key go without swallowing anything, for a release handed on elsewhere.
    public mutating func forget(_ keyCode: UInt16) {
        held.remove(keyCode)
    }
}
