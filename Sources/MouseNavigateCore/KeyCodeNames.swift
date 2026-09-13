import Foundation

/// ANSI virtual key codes used as defaults. Mirrors Carbon's `kVK_*` constants so the
/// core library stays free of framework imports.
public enum KeyCode {
    public static let a: UInt16 = 0
    public static let s: UInt16 = 1
    public static let d: UInt16 = 2
    public static let f: UInt16 = 3
    public static let i: UInt16 = 34
    public static let j: UInt16 = 38
    public static let k: UInt16 = 40
    public static let l: UInt16 = 37
    public static let semicolon: UInt16 = 41
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
}

public enum KeyCodeNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
        47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        76: "Enter", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear",
        75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 114: "Help", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
