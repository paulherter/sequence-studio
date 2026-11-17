// SPDX-License-Identifier: GPL-3.0-or-later
//! The one definition of a "word" for captions, karaoke, text animators, text layout, burn-in and transcription
//! tokens, ported from `WordSegmentation`, so a word index means the same thing everywhere.
//!
//! Whitespace separates words. Every CJK character (ideographs, kana, fullwidth forms: [`is_cjk`]) is a word of its
//! own. A closing mark stays with the word before it, an opening mark joins the word after it. Latin text is exactly
//! whitespace splitting. Indices count Swift `Character`s (grapheme clusters).

use crate::text::graphemes;
use std::ops::Range;

/// A Character whose first scalar is CJK (ideographs, kana, fullwidth forms).
pub fn is_cjk(c: &str) -> bool {
    let Some(v) = c.chars().next().map(u32::from) else { return false };
    matches!(v, 0x2E80..=0x2FDF | 0x3000..=0x30FF | 0x3190..=0x31FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF
        | 0xF900..=0xFAFF | 0xFF00..=0xFFEF | 0x20000..=0x2FA1F)
}

/// May not start a line (closing marks, small kana, prolonged sound mark, iteration marks, ASCII `)]}!?,.:;%`).
const CLOSING: &str =
    "、。，．・：；！？）〕］｝〉》」』】〙〗〟'”ゝゞヽヾーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ々〻)]}!?,.:;%";
/// May not end a line (opening marks).
const OPENING: &str = "（〔［｛〈《「『【〘〖〝‘“([{";

/// Whether the Character is exactly one scalar of `set`.
fn in_set(c: &str, set: &str) -> bool {
    let mut it = c.chars();
    matches!((it.next(), it.next()), (Some(x), None) if set.contains(x))
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Latin,
    Cjk,
    Open,
}

/// Character-index spans of the words of `chars`.
pub fn spans(chars: &[&str]) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    let mut kind = Kind::Latin;
    let mut close = |start: &mut Option<usize>, n: usize| {
        if let Some(s) = start.take() {
            out.push(s..n);
        }
    };
    for (n, ch) in chars.iter().enumerate() {
        if ch.chars().next().is_some_and(char::is_whitespace) {
            close(&mut start, n);
        } else if in_set(ch, CLOSING) {
            if start.is_none() {
                start = Some(n);
                kind = Kind::Latin;
            }
        } else if in_set(ch, OPENING) {
            if start.is_some() && kind == Kind::Cjk {
                close(&mut start, n);
            }
            if start.is_none() {
                start = Some(n);
                kind = Kind::Open;
            }
        } else if is_cjk(ch) {
            if start.is_some() && kind != Kind::Open {
                close(&mut start, n);
            }
            start.get_or_insert(n);
            kind = Kind::Cjk;
        } else {
            if start.is_some() && kind == Kind::Cjk {
                close(&mut start, n);
            }
            start.get_or_insert(n);
            kind = Kind::Latin;
        }
    }
    close(&mut start, chars.len());
    out
}

/// Spans of the words of `text`.
pub fn spans_of(text: &str) -> Vec<Range<usize>> {
    spans(&graphemes(text).collect::<Vec<_>>())
}

/// The words of `text`.
pub fn words(text: &str) -> Vec<String> {
    let chars: Vec<&str> = graphemes(text).collect();
    spans(&chars).into_iter().map(|r| chars[r].concat()).collect()
}

/// Number of words in `text`.
pub fn word_count(text: &str) -> usize {
    spans_of(text).len()
}

/// True when a space does not belong between `a` and `b` (a CJK character on either side of the seam).
pub fn is_tight(a: &str, b: &str) -> bool {
    match (graphemes(a).last(), graphemes(b).next()) {
        (Some(x), Some(y)) => is_cjk(x) || is_cjk(y),
        _ => false,
    }
}

/// The words as one line: a space between words, none beside a CJK character.
pub fn join<S: AsRef<str>>(words: &[S]) -> String {
    let mut out = String::new();
    for w in words {
        let w = w.as_ref();
        if !out.is_empty() && !is_tight(&out, w) {
            out.push(' ');
        }
        out.push_str(w);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<String> {
        words(s)
    }

    #[test]
    fn latin_is_unchanged() {
        assert_eq!(w("  Hallo,   (Welt)  E-Mail! "), ["Hallo,", "(Welt)", "E-Mail!"]);
        assert_eq!(w("a - b"), ["a", "-", "b"]);
        assert!(w("").is_empty());
    }

    #[test]
    fn cjk_splits_per_character() {
        assert_eq!(w("你好世界"), ["你", "好", "世", "界"]);
        assert_eq!(w("こんにちは"), ["こ", "ん", "に", "ち", "は"]);
    }

    #[test]
    fn mixed_latin_and_cjk() {
        assert_eq!(w("Hello世界 ok"), ["Hello", "世", "界", "ok"]);
        assert_eq!(w("用iPhone拍"), ["用", "iPhone", "拍"]);
    }

    #[test]
    fn punctuation_attaches() {
        assert_eq!(w("你好。世界"), ["你", "好。", "世", "界"]);
        assert_eq!(w("他说「好」吗"), ["他", "说", "「好」", "吗"]);
        assert_eq!(w("(漢字)"), ["(漢", "字)"]);
        assert_eq!(w("。"), ["。"]);
    }

    #[test]
    fn spans_are_character_ranges() {
        assert_eq!(spans_of("ab 你好"), [0..2, 3..4, 4..5]);
        assert_eq!(word_count("e\u{301}le\u{301}ve cafe\u{301}"), 2);
    }

    #[test]
    fn join_keeps_cjk_tight() {
        assert_eq!(join(&["你", "好", "world", "ok", "世"]), "你好world ok世");
        assert_eq!(join(&["a", "b"]), "a b");
        assert_eq!(join::<&str>(&[]), "");
        assert!(is_tight("日本", "語") && !is_tight("hello", "world") && !is_tight("", "x"));
    }
}
