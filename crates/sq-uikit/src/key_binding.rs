//! Port of `SQUIKit/Sources/SQUIKit/KeyBinding.swift`.

use std::ops::{BitOr, BitOrAssign};

/// Physical-ish key identity. Letters are lowercase; digits and symbols name the key cap without Shift
/// (Shift+1 is `Key::Char('1')` + `SHIFT`). The AppKit adapter maps key codes to this, not characters.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    Char(char),
    Space,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Delete,
    /// Return / keypad Enter and the key under Help ("Forward Delete"). Plain Return and Forward Delete bind to nothing by default.
    ReturnKey,
    ForwardDelete,
    Function(i64),
}

/// The modifier keys of a binding (Swift `OptionSet`; same raw values).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyModifiers(pub i64);

impl KeyModifiers {
    pub const COMMAND: KeyModifiers = KeyModifiers(1);
    pub const SHIFT: KeyModifiers = KeyModifiers(2);
    pub const OPTION: KeyModifiers = KeyModifiers(4);
    pub const CONTROL: KeyModifiers = KeyModifiers(8);

    /// No modifier (`[]`).
    pub const EMPTY: KeyModifiers = KeyModifiers(0);

    /// True when every modifier of `other` is set.
    pub fn contains(self, other: KeyModifiers) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

impl BitOr for KeyModifiers {
    type Output = KeyModifiers;
    fn bitor(self, rhs: KeyModifiers) -> KeyModifiers {
        KeyModifiers(self.0 | rhs.0)
    }
}

impl BitOrAssign for KeyModifiers {
    fn bitor_assign(&mut self, rhs: KeyModifiers) {
        self.0 |= rhs.0;
    }
}

/// A key plus its modifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KeyBinding {
    pub key: Key,
    pub modifiers: KeyModifiers,
}

impl KeyBinding {
    pub fn new(key: Key, modifiers: KeyModifiers) -> KeyBinding {
        KeyBinding { key, modifiers }
    }
}

/// Key press or release.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyPhase {
    Down,
    Up,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KeyEvent {
    pub key: Key,
    pub modifiers: KeyModifiers,
    pub phase: KeyPhase,
    pub is_repeat: bool,
}

impl KeyEvent {
    /// A key-down event that is not a repeat.
    pub fn new(key: Key, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent { key, modifiers, phase: KeyPhase::Down, is_repeat: false }
    }

    pub fn binding(&self) -> KeyBinding {
        KeyBinding::new(self.key, self.modifiers)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_combine_like_an_option_set() {
        let m = KeyModifiers::COMMAND | KeyModifiers::SHIFT;
        assert!(m.contains(KeyModifiers::COMMAND) && m.contains(KeyModifiers::SHIFT));
        assert!(!m.contains(KeyModifiers::OPTION));
        assert_eq!(m.0, 3);
        assert!(KeyModifiers::EMPTY.is_empty());
    }

    #[test]
    fn event_binding_drops_phase_and_repeat() {
        let e = KeyEvent { key: Key::Left, modifiers: KeyModifiers::SHIFT, phase: KeyPhase::Up, is_repeat: true };
        assert_eq!(e.binding(), KeyBinding::new(Key::Left, KeyModifiers::SHIFT));
    }
}
