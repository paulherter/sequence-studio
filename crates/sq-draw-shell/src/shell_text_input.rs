// Swift: ShellTextInput.swift
//! Typed text on Windows beyond the key map: an IME's committed text (Japanese, Chinese, Korean), letters of the active
//! keyboard layout that the US key map does not know (ä, ö, ß, é) and dead-key compositions (^ then e = ê) arrive as
//! WM_CHAR after `TranslateMessage`. ASCII stays with WM_KEYDOWN (the key map, shortcuts, modifiers); this bridge turns
//! the non-ASCII WM_CHAR units into character keys and drops the key map's guess for the same keystroke (the German
//! ö key is VK_OEM_3, which the key map types as a backquote).
//! While an IME composes, WM_KEYDOWN carries VK_PROCESSKEY (no key-map entry), so nothing is typed twice.
//! The Rust app's window gets input methods through winit `Ime` events instead (composition drawn at the caret, candidate
//! window at the caret: `sequence-studio/src/main.rs` `ime_event` / `follow_caret`); this bridge is the Swift port.

use sq_draw::InputKey;

/// What to do with a typed unit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextOutput {
    /// Nothing.
    None,
    /// Type the character.
    Type(char),
    /// Drop the key map's character of this keystroke, then type the character.
    Replace(char),
    /// Drop the key map's character of this keystroke (a dead key: its accent comes with the next letter).
    Drop,
}

/// The WM_KEYDOWN / WM_CHAR bridge state.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ShellTextInput {
    key_typed: bool,
    lead: Option<u16>,
}

impl ShellTextInput {
    /// A bridge with nothing pending.
    pub fn new() -> ShellTextInput {
        ShellTextInput::default()
    }

    /// WM_KEYDOWN: what the key map made of the key (`None`: nothing, as for VK_PROCESSKEY while an IME composes).
    pub fn key_down(&mut self, k: Option<InputKey>) {
        self.key_typed = matches!(k, Some(InputKey::Character(_)));
        self.lead = None;
    }

    /// WM_DEADCHAR: an accent key waiting for its letter.
    pub fn dead_char(&mut self) -> TextOutput {
        let out = if self.key_typed { TextOutput::Drop } else { TextOutput::None };
        self.key_typed = false;
        out
    }

    /// WM_CHAR with one UTF-16 unit (characters outside the BMP come as two).
    pub fn char(&mut self, unit: u16) -> TextOutput {
        let scalar = if (0xD800..0xDC00).contains(&unit) {
            self.lead = Some(unit);
            return TextOutput::None;
        } else if (0xDC00..0xE000).contains(&unit) {
            let Some(l) = self.lead else { return TextOutput::None };
            char::from_u32(((u32::from(l) - 0xD800) << 10) + (u32::from(unit) - 0xDC00) + 0x10000)
        } else {
            char::from_u32(u32::from(unit))
        };
        self.lead = None;
        let typed = self.key_typed;
        self.key_typed = false;
        // ASCII and control units: the key map has them
        let Some(c) = scalar.filter(|c| u32::from(*c) >= 0x80) else { return TextOutput::None };
        if typed { TextOutput::Replace(c) } else { TextOutput::Type(c) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_stays_with_the_key_map() {
        let mut t = ShellTextInput::new();
        t.key_down(Some(InputKey::Character('a')));
        assert_eq!(t.char(u16::from(b'a')), TextOutput::None);
        t.key_down(Some(InputKey::Character('a'))); // Ctrl+A: a control unit
        assert_eq!(t.char(1), TextOutput::None);
    }

    #[test]
    fn layout_letter_replaces_the_key_map_guess() {
        let mut t = ShellTextInput::new();
        t.key_down(Some(InputKey::Character('`'))); // German ö key = VK_OEM_3
        assert_eq!(t.char(0x00F6), TextOutput::Replace('ö'));
        t.key_down(None); // AltGr letters without a key-map entry
        assert_eq!(t.char(0x00DF), TextOutput::Type('ß'));
    }

    #[test]
    fn dead_key_drops_the_accent_guess_and_the_letter_is_replaced() {
        let mut t = ShellTextInput::new();
        t.key_down(Some(InputKey::Character('\\'))); // German ^ dead key
        assert_eq!(t.dead_char(), TextOutput::Drop);
        t.key_down(Some(InputKey::Character('e')));
        assert_eq!(t.char(0x00EA), TextOutput::Replace('ê'));
    }

    #[test]
    fn ime_result_is_typed_and_surrogate_pairs_join() {
        let mut t = ShellTextInput::new();
        t.key_down(None); // VK_PROCESSKEY while composing
        assert_eq!(t.char(0x65E5), TextOutput::Type('日'));
        assert_eq!(t.char(0x672C), TextOutput::Type('本'));
        assert_eq!(t.char(0xD83D), TextOutput::None);
        assert_eq!(t.char(0xDE00), TextOutput::Type('😀'));
        assert_eq!(t.char(0xDE00), TextOutput::None); // a lone trail unit is dropped
    }
}
