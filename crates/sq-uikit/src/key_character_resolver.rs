// Swift: KeyCharacterResolver.swift (currentLayout: Mac Text Input Sources, Windows ToUnicodeEx and the Linux layout name come through `sq_os::keyboard`)
//! The physical key identities the shortcut map uses, and the translation of a typed character to such a key.

use crate::key_binding::Key;
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

/// Where the keyboard has a key code: the physical (ANSI position) identity the shortcut map uses, shared by the
/// app's key event adapter and the shortcut import.
pub struct PhysicalKeys;

impl PhysicalKeys {
    /// Key code to key.
    pub fn codes() -> &'static HashMap<u16, Key> {
        static CODES: OnceLock<HashMap<u16, Key>> = OnceLock::new();
        CODES.get_or_init(|| {
            let mut m: HashMap<u16, Key> = HashMap::new();
            let letters: [(u16, char); 48] = [
                (0, 'a'),
                (11, 'b'),
                (8, 'c'),
                (2, 'd'),
                (14, 'e'),
                (3, 'f'),
                (5, 'g'),
                (4, 'h'),
                (34, 'i'),
                (38, 'j'),
                (40, 'k'),
                (37, 'l'),
                (46, 'm'),
                (45, 'n'),
                (31, 'o'),
                (35, 'p'),
                (12, 'q'),
                (15, 'r'),
                (1, 's'),
                (17, 't'),
                (32, 'u'),
                (9, 'v'),
                (13, 'w'),
                (7, 'x'),
                (16, 'y'),
                (6, 'z'),
                (29, '0'),
                (18, '1'),
                (19, '2'),
                (20, '3'),
                (21, '4'),
                (23, '5'),
                (22, '6'),
                (26, '7'),
                (28, '8'),
                (25, '9'),
                (24, '='),
                (27, '-'),
                (30, ']'),
                (33, '['),
                (39, '\''),
                (41, ';'),
                (42, '\\'),
                (43, ','),
                (44, '/'),
                (47, '.'),
                (50, '`'),
                (10, '<'), // the extra key left of Z/Y on ISO and JIS keyboards (German "<>|"); has no ANSI counterpart
            ];
            for (code, c) in letters {
                m.insert(code, Key::Char(c));
            }
            m.insert(49, Key::Space);
            m.insert(123, Key::Left);
            m.insert(124, Key::Right);
            m.insert(125, Key::Down);
            m.insert(126, Key::Up);
            m.insert(115, Key::Home);
            m.insert(119, Key::End);
            m.insert(116, Key::PageUp);
            m.insert(121, Key::PageDown);
            m.insert(51, Key::Delete);
            m.insert(117, Key::ForwardDelete);
            m.insert(36, Key::ReturnKey);
            m.insert(76, Key::ReturnKey);
            m.insert(122, Key::Function(1));
            m.insert(120, Key::Function(2));
            m.insert(99, Key::Function(3));
            m.insert(118, Key::Function(4));
            m.insert(96, Key::Function(5));
            m.insert(97, Key::Function(6));
            m.insert(98, Key::Function(7));
            m.insert(100, Key::Function(8));
            m.insert(101, Key::Function(9));
            m.insert(109, Key::Function(10));
            m.insert(103, Key::Function(11));
            m.insert(111, Key::Function(12));
            m
        })
    }
}

/// The key a typed character sits on, and whether Shift has to be held to type it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyCharacterResolution {
    pub key: Key,
    pub needs_shift: bool,
}

type ResolveFn = dyn Fn(char) -> Option<KeyCharacterResolution> + Send + Sync;

/// Turns the character another program stored for a shortcut ("ß", "+", "ö") into the physical key our map binds.
/// A Final Cut command set names keys by the character on the keycap, so on a German keyboard Trim Start is "ß" while
/// our map (and the key event adapter) knows key positions: the character has to go through the keyboard layout.
#[derive(Clone)]
pub struct KeyCharacterResolver {
    resolve: Arc<ResolveFn>,
}

impl KeyCharacterResolver {
    pub fn new(resolve: impl Fn(char) -> Option<KeyCharacterResolution> + Send + Sync + 'static) -> Self {
        KeyCharacterResolver { resolve: Arc::new(resolve) }
    }

    /// The key `c` sits on, if the layout can type it.
    pub fn resolve(&self, c: char) -> Option<KeyCharacterResolution> {
        (self.resolve)(c)
    }

    /// A table of characters, lower-case letters first.
    pub fn table(t: HashMap<char, KeyCharacterResolution>) -> KeyCharacterResolver {
        KeyCharacterResolver::new(move |c| {
            t.get(&c).copied().or_else(|| {
                let mut lower = c.to_lowercase();
                match (lower.next(), lower.next()) {
                    (Some(l), None) => t.get(&l).copied(),
                    _ => None,
                }
            })
        })
    }

    /// US keyboard: letters, digits and the unshifted symbols are themselves, shifted symbols sit on their key plus Shift.
    pub fn us() -> KeyCharacterResolver {
        static US: OnceLock<KeyCharacterResolver> = OnceLock::new();
        US.get_or_init(|| {
            let mut t: HashMap<char, KeyCharacterResolution> = HashMap::new();
            for key in PhysicalKeys::codes().values() {
                if let Key::Char(c) = key
                    && *c != '<'
                {
                    t.insert(*c, KeyCharacterResolution { key: *key, needs_shift: false });
                }
            }
            let shifted: [(char, char); 21] = [
                ('!', '1'),
                ('@', '2'),
                ('#', '3'),
                ('$', '4'),
                ('%', '5'),
                ('^', '6'),
                ('&', '7'),
                ('*', '8'),
                ('(', '9'),
                (')', '0'),
                ('_', '-'),
                ('+', '='),
                ('{', '['),
                ('}', ']'),
                ('|', '\\'),
                (':', ';'),
                ('"', '\''),
                ('<', ','),
                ('>', '.'),
                ('?', '/'),
                ('~', '`'),
            ];
            for (c, base) in shifted {
                t.insert(c, KeyCharacterResolution { key: Key::Char(base), needs_shift: true });
            }
            KeyCharacterResolver::table(t)
        })
        .clone()
    }

    /// The layout the computer is typing with now (German, French, Dvorak ...); characters it cannot type fall back to `us`.
    // Swift: KeyCharacterResolver.swift currentLayout
    pub fn current_layout() -> KeyCharacterResolver {
        match sq_os::keyboard::active() {
            Some(k) => Self::from_probes(&k.probes),
            None => Self::us(),
        }
    }

    /// A layout from what each key types: plain first so a character on two keys keeps the plain one, lower-case, no
    /// blanks or control characters; what the layout cannot type is looked up on the US layout.
    pub fn from_probes(probes: &[sq_os::keyboard::KeyProbe]) -> KeyCharacterResolver {
        if probes.is_empty() {
            return Self::us();
        }
        let mut t: HashMap<char, KeyCharacterResolution> = HashMap::new();
        for shift in [false, true] {
            for p in probes {
                let typed = if shift { p.shifted } else { p.plain };
                let Some(typed) = typed else { continue };
                if typed.is_whitespace() || (typed as u32) < 0x20 {
                    continue;
                }
                let mut lower = typed.to_lowercase();
                let c = match (lower.next(), lower.next()) {
                    (Some(l), None) => l,
                    _ => typed,
                };
                t.entry(c).or_insert(KeyCharacterResolution { key: Key::Char(p.position), needs_shift: shift });
            }
        }
        let own = Self::table(t);
        let us = Self::us();
        KeyCharacterResolver::new(move |c| own.resolve(c).or_else(|| us.resolve(c)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn us_layout_maps_letters_digits_and_shifted_symbols() {
        let us = KeyCharacterResolver::us();
        assert_eq!(us.resolve('a'), Some(KeyCharacterResolution { key: Key::Char('a'), needs_shift: false }));
        assert_eq!(us.resolve('A'), Some(KeyCharacterResolution { key: Key::Char('a'), needs_shift: false }));
        assert_eq!(us.resolve('+'), Some(KeyCharacterResolution { key: Key::Char('='), needs_shift: true }));
        assert_eq!(us.resolve('<'), Some(KeyCharacterResolution { key: Key::Char(','), needs_shift: true }));
        assert_eq!(us.resolve('ß'), None);
    }

    #[test]
    fn physical_key_codes_cover_the_special_keys() {
        let codes = PhysicalKeys::codes();
        assert_eq!(codes.get(&49), Some(&Key::Space));
        assert_eq!(codes.get(&76), Some(&Key::ReturnKey));
        assert_eq!(codes.get(&111), Some(&Key::Function(12)));
        assert_eq!(codes.get(&10), Some(&Key::Char('<')));
        assert_eq!(codes.len(), 48 + 1 + 4 + 4 + 2 + 2 + 12);
    }

    #[test]
    fn a_german_layout_finds_y_on_the_z_key_and_slash_on_shift_7() {
        let de = KeyCharacterResolver::from_probes(&sq_os::keyboard::ActiveKeyboard::from_id("de").probes);
        assert_eq!(de.resolve('y'), Some(KeyCharacterResolution { key: Key::Char('z'), needs_shift: false }));
        assert_eq!(de.resolve('/'), Some(KeyCharacterResolution { key: Key::Char('7'), needs_shift: true }));
        assert_eq!(de.resolve('ß'), Some(KeyCharacterResolution { key: Key::Char('-'), needs_shift: false }));
        // Not on the German keys: the US layout answers.
        assert_eq!(de.resolve('['), KeyCharacterResolver::us().resolve('['));
    }

    #[test]
    fn no_probes_means_the_us_layout() {
        assert_eq!(KeyCharacterResolver::from_probes(&[]).resolve('+'), KeyCharacterResolver::us().resolve('+'));
    }
}
