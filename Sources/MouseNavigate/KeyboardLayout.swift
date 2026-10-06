import Carbon
import Foundation
import MouseNavigateCore

/// What the keys mean on the keyboard layout in use.
///
/// Key codes name positions, not letters: 13 is W on a US keyboard and Z on a French one.
/// A built-in shortcut means a letter, because apps match ⌘-shortcuts by the character
/// typed, so the letter is looked up on the current layout each time it is sent. Recorded
/// shortcuts and the cursor keys stay positions, which is what was pressed; only their
/// labels come from here, so they read as the keys they are.
final class KeyboardLayout {
    static let shared = KeyboardLayout()

    /// The main block of the keyboard: letters, digits and punctuation, whose meaning
    /// moves between layouts. Everything above is the keypad and the named keys, which the
    /// fixed table describes better.
    private static let printingKeyCodes: ClosedRange<UInt16> = 0...50

    private var codesByCharacter: [Character: UInt16] = [:]
    private var namesByCode: [UInt16: String] = [:]

    private init() {
        rebuild()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(layoutChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    /// The key that types `character` on the current layout, or `fallback` where none does.
    func keyCode(for character: Character, fallback: UInt16) -> UInt16 {
        codesByCharacter[character] ?? codesByCharacter[Character(character.lowercased())] ?? fallback
    }

    /// The key code a built-in shortcut should be sent with.
    func keyCode(for shortcut: Shortcut) -> UInt16 {
        shortcut.character.map { keyCode(for: $0, fallback: shortcut.keyCode) } ?? shortcut.keyCode
    }

    func name(for keyCode: UInt16) -> String {
        namesByCode[keyCode] ?? KeyCodeNames.name(for: keyCode)
    }

    /// As menus write it: ⌃⌥⇧⌘ in that order, then the key as this layout labels it.
    func displayString(for shortcut: Shortcut) -> String {
        shortcut.modifiers.symbols + name(for: shortcut.keyCode)
    }

    @objc private func layoutChanged() {
        rebuild()
    }

    private func rebuild() {
        var codes: [Character: UInt16] = [:]
        var names: [UInt16: String] = [:]
        defer {
            codesByCharacter = codes
            namesByCode = names
        }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in KeyboardLayout.printingKeyCodes {
                var deadKeyState: UInt32 = 0
                var units = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units
                )
                guard status == noErr, length > 0 else { continue }
                let typed = String(utf16CodeUnits: units, count: length)
                guard typed.count == 1, let character = typed.first,
                      !character.isWhitespace, !character.isNewline,
                      character.unicodeScalars.allSatisfy({ $0.value >= 32 })
                else {
                    continue
                }
                if codes[character] == nil {
                    codes[character] = code
                }
                names[code] = typed.uppercased()
            }
        }
    }
}
