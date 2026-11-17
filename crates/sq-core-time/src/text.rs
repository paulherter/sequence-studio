// SPDX-License-Identifier: GPL-3.0-or-later
//! Locale-independent stand-ins for the Foundation string calls the core uses: Finder-style sorting
//! (`localizedStandardCompare`), case-insensitive search (`localizedCaseInsensitiveContains`) and Character counts.
//! Checked against `oracle/sq-core-time/golden/text-tables.tsv` (Apple ICU, en_US); see the crate README for the
//! rows that still differ.

use std::cmp::Ordering;
use unicode_segmentation::UnicodeSegmentation;

/// Swift `Character`s of `s` (extended grapheme clusters).
pub fn graphemes(s: &str) -> impl Iterator<Item = &str> {
    s.graphemes(true)
}

/// Swift `a.localizedCaseInsensitiveContains(b)`: whole Characters only (a skin-tone emoji does not contain the
/// plain one); false for an empty needle.
pub fn ci_contains(haystack: &str, needle: &str) -> bool {
    let (h, n) = (decompose_latin1(&haystack.to_lowercase()), decompose_latin1(&needle.to_lowercase()));
    let (h, n): (Vec<&str>, Vec<&str>) = (graphemes(&h).collect(), graphemes(&n).collect());
    !n.is_empty() && h.windows(n.len()).any(|w| w == n.as_slice())
}

/// Splits the accented lowercase Latin-1 letters into base letter plus combining mark (canonical decomposition), so
/// "e\u{301}" and "\u{e9}" match like in Swift.
// shortcut: Latin-1 only, no full NFD table; add one when names in other scripts must match across forms.
pub(crate) fn decompose_latin1(s: &str) -> String {
    // Mark of U+00E0..=U+00FF as an offset from U+0300 ('.' = none); the base letter comes from `fold`.
    const MARKS: &[u8; 32] = b"01238:.W01280128.301238..01281.8";
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let code = u32::from(c);
        let mark = (0xE0..=0xFF).contains(&code).then(|| MARKS[(code - 0xE0) as usize]).filter(|&m| m != b'.');
        match mark {
            Some(m) => {
                out.push_str(&fold(c).0);
                out.push(char::from_u32(0x300 + u32::from(m - b'0')).unwrap_or(c));
            }
            None => out.push(c),
        }
    }
    out
}

/// Swift `a.localizedStandardCompare(b)` (Finder order): digit runs compare by value, letters by base letter, then
/// accents, then case (lowercase first); fully equal only for identical strings.
pub fn standard_compare(a: &str, b: &str) -> Ordering {
    let (ka, kb) = (sort_key(a), sort_key(b));
    ka.primary
        .cmp(&kb.primary)
        .then_with(|| ka.secondary.cmp(&kb.secondary))
        .then_with(|| ka.tertiary.cmp(&kb.tertiary))
        .then_with(|| a.cmp(b))
}

/// Collation weights in three levels, like ICU's.
struct SortKey {
    primary: Vec<u64>,
    secondary: Vec<u32>,
    tertiary: Vec<u8>,
}

/// Primary groups in ICU root order: spaces and punctuation, symbols, digits, Latin letters, every other script.
const PUNCT: u64 = 1 << 40;
const DIGIT: u64 = 2 << 40;
const LETTER: u64 = 3 << 40;
const OTHER: u64 = 4 << 40;

/// ICU root order of the ASCII spaces, punctuation and symbols.
const PUNCT_ORDER: &str = "\t\n\u{b}\u{c}\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$";

fn sort_key(s: &str) -> SortKey {
    let mut k = SortKey { primary: Vec::new(), secondary: Vec::new(), tertiary: Vec::new() };
    // Fullwidth forms weigh like ASCII (width-insensitive), differing only at the last level.
    let chars: Vec<(char, bool)> = s
        .chars()
        .map(|c| match u32::from(c) {
            v @ 0xFF01..=0xFF5E => (char::from_u32(v - 0xFEE0).unwrap_or(c), true),
            _ => (c, false),
        })
        .collect();
    let mut i = 0;
    while i < chars.len() {
        let (c, wide) = chars[i];
        if digit_value(c).is_some() {
            // A digit run weighs by its value: length without leading zeros, then the digits; more leading zeros and
            // non-ASCII digits sort later at the second level.
            let start = i;
            while i < chars.len() && digit_value(chars[i].0).is_some() {
                i += 1;
            }
            let run: Vec<u8> = chars[start..i].iter().filter_map(|&(d, _)| digit_value(d)).collect();
            let zeros = run.iter().take_while(|&&d| d == 0).count();
            let digits = &run[zeros..];
            k.primary.push(DIGIT | digits.len() as u64);
            k.primary.extend(digits.iter().map(|&d| DIGIT | u64::from(d)));
            k.secondary.push(zeros as u32);
            k.secondary.extend(chars[start..i].iter().map(|&(d, _)| if d.is_ascii_digit() { 0 } else { u32::from(d) }));
            k.tertiary.extend(chars[start..i].iter().map(|&(_, w)| u8::from(w)));
            continue;
        }
        i += 1;
        let upper = c.is_uppercase() || u32::from(c) == 0x1C5;
        for l in c.to_lowercase() {
            let (bases, accent) = fold(l);
            for base in bases.chars() {
                k.primary.push(weight(base));
            }
            k.secondary.push(accent);
        }
        k.tertiary.push(u8::from(upper) | u8::from(wide) << 1);
    }
    k
}

/// Decimal value of ASCII, Arabic-Indic, superscript and fullwidth digits.
fn digit_value(c: char) -> Option<u8> {
    let v = match u32::from(c) {
        v @ 0x30..=0x39 => v - 0x30,
        v @ 0x660..=0x669 => v - 0x660,
        0xB9 => 1,
        0xB2 => 2,
        0xB3 => 3,
        _ => return None,
    };
    u8::try_from(v).ok()
}

fn weight(c: char) -> u64 {
    if let Some(p) = PUNCT_ORDER.find(c) {
        return PUNCT | p as u64;
    }
    if c.is_ascii_lowercase() {
        return LETTER | u64::from(c);
    }
    if c.is_whitespace() || (c.is_ascii() && !c.is_alphanumeric()) {
        return PUNCT | 0xFF | u64::from(c) << 8;
    }
    OTHER | u64::from(c)
}

/// Lowercase letter to its base letters and an accent weight (0 = none). Covers Latin-1 and Latin Extended-A plus
/// the ligatures seen in file names; other characters stay themselves.
fn fold(c: char) -> (String, u32) {
    // Base letters of U+00E0..=U+00FF and U+0100..=U+017F, one char per code point ('.' = keep the char).
    const LATIN1: &str = "aaaaaa.ceeeeiiii.nooooo.ouuuuy.y";
    const EXT_A: &str = "aaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiii..jjkkkllllllllllnnnnnnn..oooooo..rrrrrrssssssssttttttuuuuuuuuuuuuwwyyyzzzzzzs";
    let code = u32::from(c);
    let table = match code {
        0xE0..=0xFF => LATIN1.chars().nth((code - 0xE0) as usize),
        0x100..=0x17F => EXT_A.chars().nth((code - 0x100) as usize),
        _ => None,
    };
    match (c, table) {
        ('ß', _) => ("ss".into(), 1),
        ('æ', _) => ("ae".into(), 1),
        ('œ', _) => ("oe".into(), 1),
        ('\u{FB01}', _) => ("fi".into(), 1),
        ('\u{FB02}', _) => ("fl".into(), 1),
        ('\u{1C4}'..='\u{1C6}', _) => ("dz".into(), 0x17E),
        ('\u{1C7}'..='\u{1C9}', _) => ("lj".into(), 1),
        ('\u{1CA}'..='\u{1CC}', _) => ("nj".into(), 1),
        (_, Some(b)) if b != '.' => (b.to_string(), code),
        _ => (c.to_string(), 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_compare_by_value_and_case_is_last() {
        assert_eq!(standard_compare("file 9", "file 10"), Ordering::Less);
        assert_eq!(standard_compare("a", "A"), Ordering::Less);
        assert_eq!(standard_compare("Äpfel", "b"), Ordering::Less);
        assert_eq!(standard_compare("x", "x"), Ordering::Equal);
    }

    #[test]
    fn contains_ignores_case_and_counts_characters() {
        assert!(ci_contains("Hello World", "WORLD"));
        assert!(!ci_contains("abc", ""));
        assert_eq!(graphemes("e\u{301}\r\n").count(), 2);
    }
}
