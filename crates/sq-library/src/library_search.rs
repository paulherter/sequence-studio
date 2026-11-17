// Swift: LibrarySearch.swift
//! Name filter and sort of library entries, plus the text folding the preset lists share.

use crate::watched_folder::LibraryEntry;
use std::cmp::Ordering;

/// What the entries are sorted by.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LibrarySortKey {
    /// File name, digits by value.
    Name,
    /// Modification date.
    Date,
    /// Size in bytes.
    Size,
}

/// Base letter of an accented Latin-1 letter (already lower case).
fn strip_accent(c: char) -> char {
    match c {
        'à'..='å' => 'a',
        'ç' => 'c',
        'è'..='ë' => 'e',
        'ì'..='ï' => 'i',
        'ñ' => 'n',
        'ò'..='ö' | 'ø' => 'o',
        'ù'..='ü' => 'u',
        'ý' | 'ÿ' => 'y',
        _ => c,
    }
}

/// Swift `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)`.
// shortcut: accents are dropped for Latin-1 letters and combining marks only; upgrade with a full decomposition table.
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        // Full-width ASCII (U+FF01...U+FF5E) is the plain character.
        let c =
            if ('\u{ff01}'..='\u{ff5e}').contains(&c) { char::from_u32(u32::from(c) - 0xfee0).unwrap_or(c) } else { c };
        if ('\u{300}'..='\u{36f}').contains(&c) {
            continue;
        }
        if c == 'ß' {
            out.push_str("ss");
            continue;
        }
        for l in c.to_lowercase() {
            out.push(strip_accent(l));
        }
    }
    out
}

/// Swift `compare(_, options: .numeric)`: digit runs compare by value, everything else by character.
pub fn numeric_compare(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let run = |it: &mut std::iter::Peekable<std::str::Chars<'_>>| {
                    let mut digits = String::new();
                    while let Some(d) = it.next_if(char::is_ascii_digit) {
                        digits.push(d);
                    }
                    digits.trim_start_matches('0').to_string()
                };
                let (da, db) = (run(&mut a), run(&mut b));
                let order = da.len().cmp(&db.len()).then_with(|| da.cmp(&db));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                if x != y {
                    return x.cmp(&y);
                }
                a.next();
                b.next();
            }
        }
    }
}

/// Filters by name tokens (all tokens must occur in the file name), then sorts.
pub fn filter(entries: &[LibraryEntry], query: &str, sort: LibrarySortKey, ascending: bool) -> Vec<LibraryEntry> {
    let folded = fold(query);
    let tokens: Vec<&str> = folded.split_whitespace().collect();
    let mut matched: Vec<LibraryEntry> = entries
        .iter()
        .filter(|entry| {
            let name = fold(entry.name());
            tokens.iter().all(|t| name.contains(t))
        })
        .cloned()
        .collect();
    matched.sort_by(|a, b| {
        let order = compare(a, b, sort);
        if order == Ordering::Equal {
            return a.relative_path.cmp(&b.relative_path);
        }
        if ascending { order } else { order.reverse() }
    });
    matched
}

fn compare(a: &LibraryEntry, b: &LibraryEntry, key: LibrarySortKey) -> Ordering {
    match key {
        LibrarySortKey::Name => numeric_compare(&fold(a.name()), &fold(b.name())),
        LibrarySortKey::Date => a.modified.partial_cmp(&b.modified).unwrap_or(Ordering::Equal),
        LibrarySortKey::Size => a.size.cmp(&b.size),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library_item_kind::LibraryItemKind;
    use sq_core_time::{Id, Timestamp};

    fn e(path: &str, kind: LibraryItemKind, size: i64, modified: f64) -> LibraryEntry {
        LibraryEntry {
            folder_id: Id::fixed(1),
            relative_path: path.into(),
            kind,
            size,
            modified: Timestamp::from_reference_seconds(modified),
        }
    }

    #[test]
    fn fold_ignores_case_accents_and_width() {
        assert_eq!(fold("Café ÉCLAIR"), "cafe eclair");
        assert_eq!(fold("ＡＢＣ"), "abc");
        assert_eq!(fold("Straße"), "strasse");
    }

    #[test]
    fn numeric_order_compares_digit_runs_by_value() {
        assert_eq!(numeric_compare("take 2", "take 10"), Ordering::Less);
        assert_eq!(numeric_compare("a01", "a1"), Ordering::Equal);
        assert_eq!(numeric_compare("b", "a9"), Ordering::Greater);
    }

    #[test]
    fn tokens_must_all_match_the_name() {
        use LibraryItemKind::*;
        let list = [e("x/Big Boom.wav", Audio, 1, 0.0), e("big.mov", Video, 2, 0.0), e("boom.wav", Audio, 3, 0.0)];
        let by = |q: &str| {
            filter(&list, q, LibrarySortKey::Name, true).iter().map(|x| x.relative_path.clone()).collect::<Vec<_>>()
        };
        assert_eq!(by("big boom"), ["x/Big Boom.wav"]);
        assert_eq!(by("").len(), 3);
        assert_eq!(by("BOOM"), ["x/Big Boom.wav", "boom.wav"]);
    }

    #[test]
    fn sorts_by_key_with_path_as_tie_break() {
        use LibraryItemKind::Audio;
        let list = [e("b10.wav", Audio, 5, 3.0), e("b2.wav", Audio, 5, 1.0), e("a.wav", Audio, 9, 2.0)];
        let names = |k, asc| filter(&list, "", k, asc).iter().map(|x| x.relative_path.clone()).collect::<Vec<_>>();
        assert_eq!(names(LibrarySortKey::Name, true), ["a.wav", "b2.wav", "b10.wav"]);
        assert_eq!(names(LibrarySortKey::Date, false), ["b10.wav", "a.wav", "b2.wav"]);
        assert_eq!(names(LibrarySortKey::Size, true), ["b10.wav", "b2.wav", "a.wav"]);
    }
}
