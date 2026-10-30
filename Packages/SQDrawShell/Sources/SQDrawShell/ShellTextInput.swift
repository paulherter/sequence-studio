import SQDrawKit

/// Typed text on Windows beyond the key map: an IME's committed text (Japanese, Chinese, Korean), letters of the active
/// keyboard layout that the US key map does not know (ä, ö, ß, é) and dead-key compositions (^ then e = ê) arrive as
/// WM_CHAR after `TranslateMessage`. ASCII stays with WM_KEYDOWN (the key map, shortcuts, modifiers); this bridge turns
/// the non-ASCII WM_CHAR units into `.character` keys and drops the key map's guess for the same keystroke (the German
/// ö key is VK_OEM_3, which the key map types as a backquote).
/// While an IME composes, WM_KEYDOWN carries VK_PROCESSKEY (no key-map entry), so nothing is typed twice.
/// shortcut: the composition string is not drawn inline and the candidate window sits at the IME's default place (no
/// ImmSetCompositionWindow / TSF); upgrade with a caret-rect seam from the focused field.
public struct ShellTextInput: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        case none
        /// Type the character.
        case type(Character)
        /// Drop the key map's character of this keystroke, then type the character.
        case replace(Character)
        /// Drop the key map's character of this keystroke (a dead key: its accent comes with the next letter).
        case drop
    }

    private var keyTyped = false
    private var lead: UInt16?

    public init() {}

    /// WM_KEYDOWN: what the key map made of the key (nil: nothing, as for VK_PROCESSKEY while an IME composes).
    public mutating func keyDown(_ k: InputKey?) {
        if case .character? = k { keyTyped = true } else { keyTyped = false }
        lead = nil
    }

    /// WM_DEADCHAR: an accent key waiting for its letter.
    public mutating func deadChar() -> Output {
        defer { keyTyped = false }
        return keyTyped ? .drop : .none
    }

    /// WM_CHAR with one UTF-16 unit (characters outside the BMP come as two).
    public mutating func char(_ unit: UInt16) -> Output {
        if UTF16.isLeadSurrogate(unit) { lead = unit; return .none }
        let scalar: Unicode.Scalar?
        if UTF16.isTrailSurrogate(unit) {
            guard let l = lead else { return .none }
            scalar = Unicode.Scalar((UInt32(l) - 0xD800) << 10 + (UInt32(unit) - 0xDC00) + 0x10000)
        } else {
            scalar = Unicode.Scalar(unit)
        }
        lead = nil
        let typed = keyTyped
        keyTyped = false
        guard let scalar, scalar.value >= 0x80 else { return .none }     // ASCII and control units: the key map has them
        let c = Character(scalar)
        return typed ? .replace(c) : .type(c)
    }
}
