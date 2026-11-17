//! The keyboard layout the user types with now. Each system has its own way to ask (Mac: Text Input Sources, Windows:
//! `GetKeyboardLayout` and `ToUnicodeEx`, Linux: the desktop's layout setting), so the backends register one provider here
//! and the shared code reads the answer as plain values.
// Swift: KeyCharacterResolver.swift currentLayout (Mac only there), KeyboardLayout.swift:127 (style of the system)

use std::sync::{Arc, OnceLock};

/// What one physical key types. `position` is the character the key has on a US (ANSI) keyboard, `<` for the ISO key left
/// of Z; it names the key the way the shortcut map does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyProbe {
    pub position: char,
    pub plain: Option<char>,
    pub shifted: Option<char>,
}

/// The active layout: a short id (`"us"`, `"de"`, `"fr"`: the language of the layout) and, when the system can say, what
/// every key types.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveKeyboard {
    pub layout_id: String,
    pub probes: Vec<KeyProbe>,
}

impl ActiveKeyboard {
    /// A layout known by id only (Linux): the keys come from the built-in tables, when there is one.
    pub fn from_id(id: &str) -> ActiveKeyboard {
        let layout_id = normalize_layout_id(id);
        let probes = builtin_probes(&layout_id).unwrap_or_default();
        ActiveKeyboard { layout_id, probes }
    }

    /// German, Austrian and Swiss layouts draw the ISO German picture.
    pub fn is_german(&self) -> bool {
        self.layout_id == "de"
    }
}

type Provider = fn() -> Option<Arc<ActiveKeyboard>>;
static PROVIDER: OnceLock<Provider> = OnceLock::new();

/// Registered once at start by the app, with the backend of the running system. The answer is shared and cached by the
/// backend: shortcut labels ask for it on every frame.
pub fn set_provider(p: Provider) {
    let _ = PROVIDER.set(p);
}

/// The active layout, `None` when no backend is registered or the system does not say.
pub fn active() -> Option<Arc<ActiveKeyboard>> {
    PROVIDER.get().and_then(|p| p())
}

/// Short layout id from any system's name for a layout: `com.apple.keylayout.German`, `de-CH`, `de(nodeadkeys)`, `0407`,
/// `us:intl`, `French`. German variants (Austrian, Swiss German) are `de`; unknown names keep their lower-case head.
pub fn normalize_layout_id(raw: &str) -> String {
    let s = raw.trim().to_lowercase();
    let s = s.strip_prefix("com.apple.keylayout.").unwrap_or(&s);
    let head = s.split(['(', ':', '+', '.', ' ']).next().unwrap_or("");
    match head {
        "german" | "austrian" | "swissgerman" | "de-de" | "de-at" | "de-ch" | "de_de" | "de_at" | "de_ch" | "at"
        | "ch" | "0407" | "0c07" | "0807" => "de".to_string(),
        "french" | "fr-fr" | "fr_fr" | "0c0c" | "040c" => "fr".to_string(),
        "u.s." | "us" | "abc" | "en-us" | "en_us" | "0409" => "us".to_string(),
        "british" | "gb" | "uk" | "en-gb" | "en_gb" | "0809" => "gb".to_string(),
        other => other.split(['-', '_']).next().unwrap_or(other).to_string(),
    }
}

fn pair(position: char, plain: char, shifted: char) -> KeyProbe {
    KeyProbe { position, plain: Some(plain), shifted: Some(shifted) }
}

fn letter(position: char, c: char) -> KeyProbe {
    KeyProbe { position, plain: Some(c), shifted: c.to_uppercase().next() }
}

/// The keys of the layouts that need no system lookup (Linux only knows the layout's name).
pub fn builtin_probes(id: &str) -> Option<Vec<KeyProbe>> {
    let (swaps, rest): (&[(char, char)], Vec<KeyProbe>) = match id {
        "de" => (
            &[('y', 'z'), ('z', 'y')],
            vec![
                pair('1', '1', '!'),
                pair('2', '2', '"'),
                pair('3', '3', '§'),
                pair('4', '4', '$'),
                pair('5', '5', '%'),
                pair('6', '6', '&'),
                pair('7', '7', '/'),
                pair('8', '8', '('),
                pair('9', '9', ')'),
                pair('0', '0', '='),
                pair('-', 'ß', '?'),
                KeyProbe { position: '=', plain: None, shifted: None },
                letter('[', 'ü'),
                pair(']', '+', '*'),
                letter(';', 'ö'),
                letter('\'', 'ä'),
                pair('\\', '#', '\''),
                pair(',', ',', ';'),
                pair('.', '.', ':'),
                pair('/', '-', '_'),
                KeyProbe { position: '`', plain: None, shifted: Some('°') },
                pair('<', '<', '>'),
            ],
        ),
        "fr" => (
            &[('q', 'a'), ('w', 'z'), ('a', 'q'), ('z', 'w')],
            vec![
                pair('1', '&', '1'),
                pair('2', 'é', '2'),
                pair('3', '"', '3'),
                pair('4', '\'', '4'),
                pair('5', '(', '5'),
                pair('6', '-', '6'),
                pair('7', 'è', '7'),
                pair('8', '_', '8'),
                pair('9', 'ç', '9'),
                pair('0', 'à', '0'),
                pair('-', ')', '°'),
                pair('=', '=', '+'),
                KeyProbe { position: '[', plain: None, shifted: None },
                pair(']', '$', '£'),
                pair('m', ',', '?'),
                pair(';', 'm', 'M'),
                pair(',', ';', '.'),
                pair('.', ':', '/'),
                pair('/', '!', '§'),
                pair('\'', 'ù', '%'),
                pair('\\', '*', 'µ'),
                pair('`', '²', '²'),
                pair('<', '<', '>'),
            ],
        ),
        // The UK keyboard: `"` and `@` trade places, `#` sits at the US backslash position and `\` on the ISO key.
        "gb" => (
            &[],
            vec![
                pair('2', '2', '"'),
                pair('3', '3', '£'),
                pair('\'', '\'', '@'),
                pair('\\', '#', '~'),
                pair('<', '\\', '|'),
                pair('`', '`', '¬'),
            ],
        ),
        _ => return None,
    };
    let mut out: Vec<KeyProbe> = Vec::new();
    for p in 'a'..='z' {
        let c = swaps.iter().find(|(from, _)| *from == p).map_or(p, |(_, to)| *to);
        out.push(letter(p, c));
    }
    for k in rest {
        // The French letter row has `m` on the `;` key and `,` on the `m` key: those rows replace the letter default.
        if let Some(i) = out.iter().position(|o| o.position == k.position) {
            out[i] = k;
        } else {
            out.push(k);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_names_of_every_system_become_one_id() {
        assert_eq!(normalize_layout_id("com.apple.keylayout.German"), "de");
        assert_eq!(normalize_layout_id("com.apple.keylayout.SwissGerman"), "de");
        assert_eq!(normalize_layout_id("com.apple.keylayout.ABC"), "us");
        assert_eq!(normalize_layout_id("de(nodeadkeys)"), "de");
        assert_eq!(normalize_layout_id("us:intl"), "us");
        assert_eq!(normalize_layout_id("0407"), "de");
        assert_eq!(normalize_layout_id("fr"), "fr");
        assert_eq!(normalize_layout_id("ru"), "ru");
        assert!(ActiveKeyboard::from_id("de").is_german());
        assert!(!ActiveKeyboard::from_id("fr").is_german());
    }

    #[test]
    fn the_german_table_swaps_y_and_z_and_puts_umlauts_on_the_symbol_keys() {
        let k = ActiveKeyboard::from_id("de");
        let at = |p: char| k.probes.iter().find(|x| x.position == p).cloned();
        assert_eq!(at('y').and_then(|x| x.plain), Some('z'));
        assert_eq!(at('z').and_then(|x| x.plain), Some('y'));
        assert_eq!(at('[').and_then(|x| x.plain), Some('ü'));
        assert_eq!(at('7').and_then(|x| x.shifted), Some('/'));
        assert_eq!(at('<').and_then(|x| x.shifted), Some('>'));
    }

    #[test]
    fn the_french_table_moves_the_letters_and_types_symbols_on_the_digit_row() {
        let k = ActiveKeyboard::from_id("fr");
        let at = |p: char| k.probes.iter().find(|x| x.position == p).cloned();
        assert_eq!(at('q').and_then(|x| x.plain), Some('a'));
        assert_eq!(at(';').and_then(|x| x.plain), Some('m'));
        assert_eq!(at('m').and_then(|x| x.plain), Some(','));
        assert_eq!(at('1').and_then(|x| x.plain), Some('&'));
        assert_eq!(at('1').and_then(|x| x.shifted), Some('1'));
    }

    #[test]
    fn unknown_layouts_have_no_table() {
        assert!(ActiveKeyboard::from_id("ru").probes.is_empty());
    }
}
