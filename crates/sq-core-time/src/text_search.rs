// SPDX-License-Identifier: GPL-3.0-or-later
//! Find-in-text for the transcript and caption panels (`TextSearch.matches`): case and diacritic insensitive
//! ("o-ton" finds "O-Ton", "cafe" finds "Café"). The text is one string, so a search term with spaces matches across
//! word boundaries. The `Timeline` marker extension lives in `sq-core-edit`.

use crate::text::{decompose_latin1, graphemes};
use std::ops::Range;

/// UTF-16 ranges (in `text`, like `NSRange`) of every non-overlapping occurrence of `find`, in order. A hit starts and
/// ends on a Character boundary of `text` (a skin-tone modifier may follow unless diacritic sensitive).
// Accents are stripped for Latin-1 only and case folding adds only the sharp s to lowercasing (see DECISIONS).
pub fn matches(text: &str, find: &str, case_sensitive: bool, diacritic_sensitive: bool) -> Vec<Range<usize>> {
    let needle: Vec<char> = find.chars().flat_map(|c| fold(c, case_sensitive, diacritic_sensitive)).collect();
    if needle.is_empty() {
        return Vec::new();
    }
    // Folded characters of the text, each with the index of its source Character and the UTF-16 end of its source
    // scalar; Characters with their UTF-16 span.
    let mut stream: Vec<(char, usize, usize)> = Vec::new();
    let mut spans: Vec<Range<usize>> = Vec::new();
    let mut at = 0;
    for g in graphemes(text) {
        let len = g.encode_utf16().count();
        spans.push(at..at + len);
        at += len;
        let mut char_end = at - len;
        for c in g.chars() {
            char_end += c.len_utf16();
            stream.extend(fold(c, case_sensitive, diacritic_sensitive).map(|f| (f, spans.len() - 1, char_end)));
        }
    }
    let boundary = |p: usize| p == 0 || p >= stream.len() || stream[p].1 != stream[p - 1].1;
    // Foundation finds the base emoji inside the same emoji with a skin tone (a diacritic-insensitive search treats the
    // modifier like an accent), so a modifier also ends a hit then.
    let ends_before =
        |p: usize| boundary(p) || (!diacritic_sensitive && ('\u{1F3FB}'..='\u{1F3FF}').contains(&stream[p].0));
    let mut out = Vec::new();
    let mut p = 0;
    while p + needle.len() <= stream.len() {
        let end = p + needle.len();
        let hit = boundary(p) && ends_before(end) && stream[p..end].iter().map(|s| s.0).eq(needle.iter().copied());
        if hit {
            let last = stream[end - 1];
            out.push(spans[stream[p].1].start..if boundary(end) { spans[last.1].end } else { last.2 });
            p = end;
        } else {
            p += 1;
        }
    }
    out
}

/// One character as the characters compared: case folded unless sensitive, canonically decomposed, accents dropped
/// unless sensitive.
fn fold(c: char, case_sensitive: bool, diacritic_sensitive: bool) -> impl Iterator<Item = char> {
    let cased: Vec<char> = if case_sensitive {
        vec![c]
    } else if c == 'ß' {
        vec!['s', 's']
    } else {
        c.to_lowercase().collect()
    };
    cased.into_iter().flat_map(move |l| {
        // `decompose_latin1` knows lowercase letters; an uppercase one is lowered, split and raised again.
        let lower = l.to_lowercase().next().unwrap_or(l);
        let mut parts = decompose_latin1(&lower.to_string()).chars().collect::<Vec<_>>();
        if let (true, Some(first)) = (lower != l, parts.first_mut()) {
            *first = first.to_uppercase().next().unwrap_or(*first);
        }
        parts.into_iter().filter(move |&p| diacritic_sensitive || !('\u{300}'..='\u{36f}').contains(&p))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find(text: &str, f: &str) -> Vec<Range<usize>> {
        matches(text, f, false, false)
    }

    #[test]
    fn case_and_diacritic_insensitive() {
        assert_eq!(find("Der O-Ton, dann o-ton und Café", "O-TON"), [4..9, 16..21]);
        assert_eq!(find("Un café noir", "CAFE").len(), 1);
        assert_eq!(find("Un cafe noir", "café").len(), 1);
        assert!(matches("Café", "cafe", false, true).is_empty());
        assert!(find("abc", "").is_empty());
    }

    #[test]
    fn matches_across_word_boundaries() {
        assert_eq!(find("so the big story is the big story", "big story").len(), 2);
    }

    #[test]
    fn ranges_count_utf16_units_and_whole_characters() {
        // The emoji takes two UTF-16 units; the base emoji is found inside the skin-tone one.
        assert_eq!(find("\u{1F44D} x", "x"), vec![3..4]);
        assert_eq!(find("\u{1F44D}\u{1F3FD}", "\u{1F44D}"), vec![0..2]);
        assert!(find("e\u{301}", "e\u{301}x").is_empty());
        assert!(matches("e\u{301}", "e", false, true).is_empty());
        assert!(matches("\u{1F44D}\u{1F3FD}", "\u{1F44D}", false, true).is_empty());
        assert_eq!(matches("Straße STRASSE strasse", "ss", false, false), [4..5, 11..13, 19..21]);
        assert_eq!(matches("Straße STRASSE strasse", "ss", true, false), vec![19..21]);
    }
}
