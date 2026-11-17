// Swift: Transcript.swift
//! The transcript model: words with rational time. Also the small text helpers the other modules share.

use serde::{Deserialize, Serialize};
use sq_core_audio::caption_item::{CaptionWordExt, UNSURE_BELOW};
use sq_core_model::CaptionWord;
use sq_core_time::{Id, TimeRange};

/// One recognized or edited word with its position on the source timeline (rational time).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptWord {
    /// Identity.
    pub id: Id,
    /// The word.
    pub text: String,
    /// Where it is spoken.
    pub range: TimeRange,
    /// True once the text was changed by hand after recognition.
    pub is_edited: bool,
    /// The recognizer's own confidence, 0...1 (`None`: the engine reported none, or the word was typed by hand).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f32>,
}

impl TranscriptWord {
    /// A word that was not edited and has no confidence.
    pub fn new(id: Id, text: &str, range: TimeRange) -> TranscriptWord {
        TranscriptWord { id, text: text.to_string(), range, is_edited: false, confidence: None }
    }

    /// Same rule as the timeline word boxes (`UNSURE_BELOW`); an edited word has no confidence.
    pub fn is_unsure(&self) -> bool {
        CaptionWord::is_unsure_confidence(self.confidence)
    }
}

/// Words of one language.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Transcript {
    /// BCP-47 identifier, e.g. "de-DE".
    pub language: String,
    /// The words in time order.
    pub words: Vec<TranscriptWord>,
}

impl Transcript {
    /// A transcript of `words`.
    pub fn new(language: &str, words: Vec<TranscriptWord>) -> Transcript {
        Transcript { language: language.to_string(), words }
    }

    /// Words joined by single spaces.
    pub fn text(&self) -> String {
        self.words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ")
    }
}

/// `CharacterSet.whitespaces` (tab and the space separators).
fn is_blank(c: char) -> bool {
    matches!(c as u32, 0x09 | 0x20 | 0xA0 | 0x1680 | 0x2000..=0x200B | 0x202F | 0x205F | 0x3000)
}

/// `CharacterSet.whitespacesAndNewlines` (Zs, Zl, Zp, U+0009-U+000D, U+0085), same table as the project XML reader.
fn is_blank_or_newline(c: char) -> bool {
    is_blank(c) || matches!(c as u32, 0x0A..=0x0D | 0x85 | 0x2028 | 0x2029)
}

/// Swift `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_blanks(s: &str) -> &str {
    s.trim_matches(is_blank)
}

/// Swift `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub(crate) fn trim_blanks_and_newlines(s: &str) -> &str {
    s.trim_matches(is_blank_or_newline)
}

/// Swift `Character.isLetter || Character.isNumber` for a character (grapheme cluster): decided by its first scalar.
pub(crate) fn is_letter_or_number(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(|c| c.is_alphabetic() || c.is_numeric())
}

/// Swift `text.contains(where: { $0.isLetter || $0.isNumber })`.
pub(crate) fn has_letter_or_number(text: &str) -> bool {
    sq_core_time::text::graphemes(text).any(is_letter_or_number)
}

const _: () = assert!(UNSURE_BELOW == 0.5);

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use sq_core_time::Time;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// Milliseconds as `Time`.
    pub fn t(ms: i64) -> Time {
        Time::new(ms, 1000)
    }

    /// A word with a fresh id.
    pub fn w(text: &str, start_ms: i64, end_ms: i64) -> TranscriptWord {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = Id::fixed(NEXT.fetch_add(1, Ordering::Relaxed));
        TranscriptWord::new(id, text, TimeRange::from_end(t(start_ms), t(end_ms)))
    }

    /// A German transcript of `words`.
    pub fn transcript(words: Vec<TranscriptWord>) -> Transcript {
        Transcript::new("de-DE", words)
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use sq_core_time::Time;

    #[test]
    fn text_joins_words_with_spaces() {
        let tr = transcript(vec![w("Hallo,", 0, 500), w("Welt", 600, 900)]);
        assert_eq!(tr.text(), "Hallo, Welt");
        assert_eq!(transcript(vec![]).text(), "");
    }

    #[test]
    fn codable_round_trip_keeps_rational_time() {
        let mut word = w("Test", 0, 1);
        word.range = TimeRange::from_end(Time::new(1, 3), Time::new(5, 6));
        word.is_edited = true;
        let tr = Transcript::new("de-DE", vec![word]);
        let back: Transcript = serde_json::from_str(&serde_json::to_string(&tr).unwrap()).unwrap();
        assert_eq!(back, tr);
        assert_eq!(back.words[0].range.start, Time::new(1, 3));
    }

    #[test]
    fn words_are_not_edited_by_default_and_have_unique_ids() {
        let (a, b) = (w("a", 0, 1), w("a", 0, 1));
        assert!(!a.is_edited);
        assert_ne!(a.id, b.id);
    }

    #[test]
    fn unsure_follows_the_caption_word_rule() {
        let mut a = w("a", 0, 1);
        assert!(!a.is_unsure());
        a.confidence = Some(0.3);
        assert!(a.is_unsure());
        a.confidence = Some(0.9);
        assert!(!a.is_unsure());
    }

    #[test]
    fn blank_sets_match_foundation() {
        assert_eq!(trim_blanks(" \t x\n"), "x\n");
        assert_eq!(trim_blanks_and_newlines(" \t x\n\u{2028}"), "x");
        assert!(has_letter_or_number("a-") && !has_letter_or_number("\u{2013}"));
    }
}
