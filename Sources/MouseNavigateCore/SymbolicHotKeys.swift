import Foundation

/// The shortcut macOS has for one of its own features, as set under System Settings →
/// Keyboard → Keyboard Shortcuts.
public struct SymbolicHotKey: Equatable {
    public let keyCode: UInt16
    /// `CGEventFlags` raw value.
    public let flags: UInt64

    public init(keyCode: UInt16, flags: UInt64) {
        self.keyCode = keyCode
        self.flags = flags
    }
}

/// Reads the `com.apple.symbolichotkeys` preferences domain, where every one of those
/// shortcuts is kept under a number.
public enum SymbolicHotKeys {
    public static let screenshotSelection = 30
    public static let missionControl = 32
    public static let appExpose = 33
    public static let showDesktop = 36
    public static let spaceLeft = 79
    public static let spaceRight = 81

    /// What an entry has for a key when it only types a character, or has none at all.
    static let unassignedKeyCode: UInt16 = 0xFFFF

    /// The enabled shortcuts in the domain, by number. A shortcut that is switched off, or
    /// whose entry is not the shape macOS writes, is left out: sending it would do nothing,
    /// or something else.
    ///
    /// Each entry reads `{ enabled = 1; value = { parameters = (character, key code,
    /// modifier flags); type = standard; }; }`, though an entry left at its default can be
    /// just `{ enabled = 1; }`. The numbers have been seen as integers and as strings,
    /// depending on what wrote them.
    public static func parse(_ domain: [String: Any]) -> [Int: SymbolicHotKey] {
        guard let all = domain["AppleSymbolicHotKeys"] as? [String: Any] else { return [:] }
        var result: [Int: SymbolicHotKey] = [:]
        for (key, entry) in all {
            guard
                let id = Int(key),
                let entry = entry as? [String: Any],
                boolValue(entry["enabled"]) == true,
                let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Any],
                parameters.count >= 3,
                let keyCode = intValue(parameters[1]),
                let flags = intValue(parameters[2]),
                let keyCode16 = UInt16(exactly: keyCode),
                keyCode16 != unassignedKeyCode,
                flags >= 0
            else {
                continue
            }
            result[id] = SymbolicHotKey(keyCode: keyCode16, flags: UInt64(flags))
        }
        return result
    }

    private static func intValue(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return Int(string).map { $0 != 0 } }
        return nil
    }
}

/// The media keys on an Apple keyboard, which are not key codes but system-defined events:
/// subtype 8, with the key in the top half of `data1` and its state beneath it. Values are
/// `NX_KEYTYPE_*` from IOKit's `ev_keymap.h`.
public enum MediaKey: Int32, CaseIterable {
    case soundUp = 0
    case soundDown = 1
    case mute = 7
    case play = 16
    case fast = 19
    case rewind = 20

    public static let eventSubtype: Int16 = 8

    /// Down is 0xA and up is 0xB, in the second byte of both `data1` and the modifier flags.
    private static func state(isDown: Bool) -> Int32 { isDown ? 0xA : 0xB }

    public func data1(isDown: Bool) -> Int {
        Int((rawValue << 16) | (MediaKey.state(isDown: isDown) << 8))
    }

    public static func modifierFlags(isDown: Bool) -> UInt {
        UInt(state(isDown: isDown)) << 8
    }
}
