/// The Mac twin of the Windows key route (SQWinApp `Window.swift`): virtual key codes (`kVK_*`, key positions) to the
/// portable keys, so shortcuts follow the US cap of a key on every layout as they do on Windows. Pure data: the AppKit host
/// (App `SharedUIView`) passes `NSEvent.keyCode`, the raw modifier flags and what the input method committed.
public enum MacKeys {
    /// The key at a Mac key position; nil for keys the portable UI does not handle (modifiers, F13+, the ISO section key).
    public static func key(code: UInt16) -> InputKey? {
        switch code {
        case 49: InputKey.space
        case 123: InputKey.left
        case 124: InputKey.right
        case 125: InputKey.down
        case 126: InputKey.up
        case 115: InputKey.home
        case 119: InputKey.end
        case 117: InputKey.delete          // forward delete
        case 51: InputKey.backspace        // the "delete" cap
        case 53: InputKey.escape
        case 36, 76: InputKey.enter        // return, keypad enter
        case 116: InputKey.pageUp
        case 121: InputKey.pageDown
        case 48: InputKey.character("\t")
        case 24, 69: InputKey.plus         // "=" cap (Windows VK_OEM_PLUS), keypad +
        case 27, 78: InputKey.minus
        case 42: InputKey.character("\\")
        case 43: InputKey.character(",")
        case 47: InputKey.character(".")
        case 33: InputKey.character("[")
        case 30: InputKey.character("]")
        case 41: InputKey.character(";")
        case 39: InputKey.character("'")
        case 44: InputKey.character("/")
        case 50: InputKey.character("`")
        default:
            functionKeys[code].map { InputKey.function($0) } ?? (letters[code] ?? digits[code]).map { InputKey.character($0) }
        }
    }

    private static let functionKeys: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9,
                                                      109: 10, 103: 11, 111: 12]
    private static let letters: [UInt16: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]
    private static let digits: [UInt16: Character] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",   // keypad
    ]

    /// `NSEvent.ModifierFlags` raw bits: Command is the shortcut modifier (Ctrl on Windows); Control only makes a click
    /// secondary (`secondaryClick`), it is no shortcut modifier of the portable key map.
    public static func modifiers(flags: UInt) -> InputModifiers {
        var m: InputModifiers = []
        if flags & (1 << 17) != 0 { m.insert(.shift) }
        if flags & (1 << 19) != 0 { m.insert(.option) }
        if flags & (1 << 20) != 0 { m.insert(.command) }
        return m
    }

    /// Control-click is the Mac's right click.
    public static func secondaryClick(flags: UInt) -> Bool { flags & (1 << 18) != 0 }

    /// What one key press sends, the Mac counterpart of `ShellTextInput` (Windows WM_KEYDOWN + WM_CHAR):
    /// - Command combinations: the key map's key only (the input method is not asked).
    /// - While an input method composes (marked text before or after the key: IME, a dead key such as Option-E): only
    ///   the text it commits, as plain characters.
    /// - Committed text with a non-ASCII character (ä, ö, ß on a German layout, é after a dead key): that text, replacing
    ///   the key map's guess for the same key (the German ö cap sits where the US ";" is).
    /// - Otherwise the key map's key with its modifiers (ASCII typing, shortcuts, arrows); a key it does not know types
    ///   the committed text.
    /// shortcut: text that only Option produces and that is ASCII (@ is Option-L on a German layout) arrives as the key
    /// map's key with Option, as AltGr text does on Windows; upgrade when the focused field tells the host it edits text.
    public static func events(key: InputKey?, modifiers: InputModifiers, committed: String, composing: Bool) -> [InputEvent] {
        if modifiers.contains(.command) { return key.map { [.keyDown($0, modifiers: modifiers)] } ?? [] }
        // Control characters and AppKit's function-key code points (U+F700...U+F8FF) are keys, not text.
        let typed = committed.filter { c in
            !c.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value) }
        }
        let text: [InputEvent] = typed.map { .keyDown(.character($0), modifiers: []) }
        if composing { return text }
        if typed.unicodeScalars.contains(where: { !$0.isASCII }) { return text }
        if let key { return [.keyDown(key, modifiers: modifiers)] }
        return text
    }
}
