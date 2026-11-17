//! Shortcut keys on the keyboard layout in use (Windows and Linux): the one rule that matches a key press to a binding and
//! that finds the key a label shows. The Mac keeps its own path (the system menu bar and key codes).
//!
//! A binding's key is a character of the US map (`/`, `` ` ``, `[`), with Shift as a modifier. A real press stands for the
//! first of these chords that the key map binds (else the first of them):
//! 1. the character the layout prints on the key: a letter, a digit or one of [`MAPPED_PUNCTUATION`], Shift as held
//!    (German `-` and `+` keys zoom, French `a` is the key marked A);
//! 2. a mapped punctuation character the layout types with Shift on that key, Shift used up by typing it (German Shift+7
//!    is `/`, so Ctrl+Shift+7 is Ctrl+/);
//! 3. the key's US position, Shift as held, for a key whose own character is no letter or digit (German `ü`, `#`, `^`: the
//!    position carries the shortcut, so Duplicate Ctrl+Shift+/ is Ctrl+Shift+`-` there).
//!
//! A label is found by trying the presses of the layout through the same rule ([`typing`]), so a shown key is a key that
//! works; a binding no press reaches shows no key.

use sq_os::keyboard::ActiveKeyboard;

/// The punctuation the key map binds, which every layout we care about has somewhere (so the typed character is kept: `-`
/// and `+` zoom on a German keyboard, where `-` is not at the US position).
pub const MAPPED_PUNCTUATION: &str = "=-[];',./\\`+<";

/// How a key map reads a typed character: lower case, and the `+` cap is the `=` key (`ShellKeys::key`).
pub fn map_char(c: char) -> char {
    match lower(c) {
        '+' => '=',
        c => c,
    }
}

fn lower(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

/// The chords one key press can stand for, best first, as (character the layout types, Shift stays a modifier).
/// `plain` and `shifted` are what the layout types on the key without and with Shift, `position` the key's US position.
pub fn chords(plain: Option<char>, shifted: Option<char>, position: Option<char>, shift: bool) -> Vec<(char, bool)> {
    let mut out: Vec<(char, bool)> = Vec::new();
    let mut push = |chord: (char, bool)| {
        if !out.contains(&chord) {
            out.push(chord);
        }
    };
    let own = plain.filter(|c| c.is_ascii_alphanumeric() || MAPPED_PUNCTUATION.contains(*c));
    if let Some(c) = own {
        push((lower(c), shift));
    }
    if let Some(c) = shifted.filter(|c| shift && MAPPED_PUNCTUATION.contains(*c)) {
        push((c, false));
    }
    // A letter or digit key is the key marked so: its position never stands in for it.
    if let Some(p) = position.filter(|_| !plain.is_some_and(|c| c.is_ascii_alphanumeric())) {
        push((p, shift));
    }
    out
}

/// The chord of `chords` that `binds`, else the first one.
pub fn choose(chords: &[(char, bool)], binds: &dyn Fn(char, bool) -> bool) -> Option<(char, bool)> {
    chords.iter().copied().find(|&(c, s)| binds(c, s)).or_else(|| chords.first().copied())
}

/// The key to press and whether Shift goes with it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Typing {
    /// The key, by its US position.
    pub position: char,
    pub shift: bool,
}

/// What a key types on `layout`: (US position, plain, shifted). No layout, or one the system could not describe, is the US
/// keyboard, where every key types its own character.
fn rows(layout: Option<&ActiveKeyboard>, key: char) -> Vec<(char, Option<char>, Option<char>)> {
    match layout.filter(|l| !l.probes.is_empty()) {
        Some(l) => {
            let mut out: Vec<_> = l
                .probes
                .iter()
                .filter(|p| {
                    let is = |c: Option<char>| c.is_some_and(|c| map_char(c) == key);
                    p.position == key || is(p.plain) || is(p.shifted)
                })
                .map(|p| (p.position, p.plain, p.shifted))
                .collect();
            // The built-in tables list the keys that differ from the US keyboard: the rest type their US character.
            if !l.probes.iter().any(|p| p.position == key) {
                out.push((key, Some(key), None));
            }
            out
        }
        None => vec![(key, Some(key), None)],
    }
}

/// The press that runs the binding `key` + `shift` on `layout`, as `binds` (does the key map bind this character with this
/// Shift and the binding's other modifiers) judges: the press without an extra Shift first, then the earliest chord.
pub fn typing(
    layout: Option<&ActiveKeyboard>,
    key: char,
    shift: bool,
    binds: &dyn Fn(char, bool) -> bool,
) -> Option<Typing> {
    let mut best: Option<((u8, usize), Typing)> = None;
    for (position, plain, shifted) in rows(layout, key) {
        for held in [false, true] {
            let cs = chords(plain, shifted, Some(position), held);
            let Some(picked) = choose(&cs, binds) else { continue };
            if map_char(picked.0) != key || picked.1 != shift {
                continue;
            }
            let rank = (u8::from(held), cs.iter().position(|c| *c == picked).unwrap_or(0));
            if best.is_none_or(|(r, _)| rank < r) {
                best = Some((rank, Typing { position, shift: held }));
            }
        }
    }
    best.map(|(_, t)| t)
}

/// What the key at a US `position` shows on its cap on `layout` (without Shift): its character, or the dead key's mark
/// (German `^` and `´`, French `^`); the US character when the layout is unknown.
pub fn cap(layout: Option<&ActiveKeyboard>, position: char) -> char {
    let Some(l) = layout.filter(|l| !l.probes.is_empty()) else { return position };
    let plain = l.probes.iter().find(|p| p.position == position).and_then(|p| p.plain);
    plain.or_else(|| dead_cap(&l.layout_id, position)).unwrap_or(position)
}

/// The mark a dead key shows (the system answers `None` for it: it types nothing by itself).
fn dead_cap(layout_id: &str, position: char) -> Option<char> {
    match (layout_id, position) {
        ("de", '`') => Some('^'),
        ("de", '=') => Some('´'),
        ("fr", '[') => Some('^'),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn is(c: char) -> Option<char> {
        Some(c)
    }

    #[test]
    fn a_letter_key_is_never_its_position() {
        // French AZERTY: the key at the US Q position is marked A.
        assert_eq!(chords(is('a'), is('A'), is('q'), false), vec![('a', false)]);
        assert_eq!(chords(is('a'), is('A'), is('q'), true), vec![('a', true)]);
    }

    #[test]
    fn german_shift_7_is_a_slash_with_shift_used_up() {
        assert_eq!(chords(is('7'), is('/'), is('7'), true), vec![('7', true), ('/', false)]);
        assert_eq!(chords(is('7'), is('/'), is('7'), false), vec![('7', false)]);
    }

    #[test]
    fn a_key_with_no_mapped_character_falls_back_to_its_position() {
        assert_eq!(chords(is('ü'), is('Ü'), is('['), false), vec![('[', false)]);
        assert_eq!(chords(None, is('°'), is('`'), false), vec![('`', false)]);
        assert_eq!(chords(None, None, None, false), vec![]);
    }

    #[test]
    fn the_chord_a_map_binds_wins_else_the_first() {
        let cs = vec![('-', true), ('/', true)];
        assert_eq!(choose(&cs, &|c, _| c == '/'), Some(('/', true)));
        assert_eq!(choose(&cs, &|_, _| false), Some(('-', true)));
        assert_eq!(choose(&[], &|_, _| true), None);
    }

    #[test]
    fn the_german_caps_show_the_dead_marks_and_umlauts() {
        let de = ActiveKeyboard::from_id("de");
        assert_eq!(cap(Some(&de), '`'), '^');
        assert_eq!(cap(Some(&de), '['), 'ü');
        assert_eq!(cap(Some(&de), '/'), '-');
        assert_eq!(cap(None, '/'), '/');
    }
}
