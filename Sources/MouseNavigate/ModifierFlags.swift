import CoreGraphics
import MouseNavigateCore

extension Shortcut.Modifiers {
    /// The four modifier keys out of an event's flags; Caps Lock, Fn and the rest are
    /// left out.
    init(_ flags: CGEventFlags) {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        self = modifiers
    }
}

extension CGEventFlags {
    init(_ modifiers: Shortcut.Modifiers) {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        self = flags
    }
}
