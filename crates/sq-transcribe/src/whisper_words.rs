// Swift: WhisperWords.swift
//! Words out of whisper tokens (portable, so the grouping is tested without an engine).

use crate::transcript::{TranscriptWord, trim_blanks_and_newlines};
use sq_core_time::{IdSource, Time, TimeRange};

/// One token as whisper.cpp reports it: raw UTF-8 bytes (a character can be split across tokens), position in
/// centiseconds and the token probability.
#[derive(Clone, Debug, PartialEq)]
pub struct WhisperToken {
    /// The token's bytes.
    pub bytes: Vec<u8>,
    /// Control tokens ([_BEG_], <|endoftext|>, timestamps): never part of the text.
    pub is_special: bool,
    /// Start in centiseconds.
    pub start_cs: i64,
    /// End in centiseconds.
    pub end_cs: i64,
    /// Probability, 0...1.
    pub probability: f32,
}

/// A word being collected.
struct Open {
    bytes: Vec<u8>,
    start: i64,
    end: i64,
    p: f32,
}

/// Words out of whisper tokens. A token that starts with a space starts a word; a token without one (punctuation, the rest of
/// a word) belongs to the word before it. The word's time runs from its first to its last token, its confidence is its lowest
/// token probability. Times never go backwards: start is at least the previous start, end at least its own start.
pub fn words(tokens: &[WhisperToken], ids: &mut dyn IdSource) -> Vec<TranscriptWord> {
    let mut out: Vec<TranscriptWord> = Vec::new();
    let mut cur: Option<Open> = None;
    let mut last_start = 0i64;
    let mut flush = |cur: &mut Option<Open>, out: &mut Vec<TranscriptWord>, ids: &mut dyn IdSource| {
        let Some(c) = cur.take() else { return };
        let decoded = String::from_utf8_lossy(&c.bytes);
        let text = trim_blanks_and_newlines(&decoded);
        if text.is_empty() {
            return;
        }
        let start = c.start.max(last_start);
        let end = c.end.max(start);
        last_start = start;
        let mut word =
            TranscriptWord::new(ids.next_id(), text, TimeRange::from_end(Time::new(start, 100), Time::new(end, 100)));
        word.confidence = Some(c.p.clamp(0.0, 1.0));
        out.push(word);
    };
    for t in tokens.iter().filter(|t| !t.is_special) {
        let starts_word = t.bytes.first().is_some_and(|b| matches!(b, 0x20 | 0x0A | 0x09));
        if starts_word || cur.is_none() {
            flush(&mut cur, &mut out, ids);
            cur = Some(Open { bytes: Vec::new(), start: t.start_cs, end: t.end_cs, p: t.probability });
        }
        let Some(c) = cur.as_mut() else { continue };
        c.bytes.extend_from_slice(&t.bytes);
        c.end = c.end.max(t.end_cs);
        c.p = c.p.min(t.probability);
    }
    flush(&mut cur, &mut out, ids);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn tok(s: &str, t0: i64, t1: i64, p: f32, special: bool) -> WhisperToken {
        WhisperToken { bytes: s.as_bytes().to_vec(), is_special: special, start_cs: t0, end_cs: t1, probability: p }
    }

    fn words_of(tokens: &[WhisperToken]) -> Vec<TranscriptWord> {
        words(tokens, &mut SequentialIds::default())
    }

    fn texts(w: &[TranscriptWord]) -> Vec<&str> {
        w.iter().map(|w| w.text.as_str()).collect()
    }

    #[test]
    fn leading_space_starts_a_word_and_punctuation_attaches_to_the_word_before() {
        let w = words_of(&[
            tok(" Hallo", 10, 40, 0.9, false),
            tok(",", 40, 45, 0.9, false),
            tok(" Welt", 50, 90, 0.9, false),
            tok("!", 90, 95, 0.9, false),
        ]);
        assert_eq!(texts(&w), ["Hallo,", "Welt!"]);
        assert_eq!(w[0].range, TimeRange::from_end(Time::new(10, 100), Time::new(45, 100)));
        assert_eq!(w[1].range, TimeRange::from_end(Time::new(50, 100), Time::new(95, 100)));
    }

    #[test]
    fn special_tokens_are_dropped_and_the_lowest_probability_becomes_the_confidence() {
        let w = words_of(&[
            tok("[_BEG_]", 0, 0, 0.9, true),
            tok(" Na", 0, 20, 0.8, false),
            tok("ja", 20, 40, 0.4, false),
            tok("<|endoftext|>", 40, 40, 0.9, true),
        ]);
        assert_eq!(texts(&w), ["Naja"]);
        assert_eq!(w[0].confidence, Some(0.4));
    }

    #[test]
    fn a_character_split_across_tokens_is_joined_before_decoding() {
        let bytes = " Grüße".as_bytes().to_vec(); // ü is two bytes: the second token starts mid-character
        let cut = bytes.iter().position(|&b| b == 0xC3).unwrap() + 1;
        let a =
            WhisperToken { bytes: bytes[..cut].to_vec(), is_special: false, start_cs: 0, end_cs: 10, probability: 0.9 };
        let b = WhisperToken {
            bytes: bytes[cut..].to_vec(),
            is_special: false,
            start_cs: 10,
            end_cs: 30,
            probability: 0.9,
        };
        assert_eq!(texts(&words_of(&[a, b])), ["Grüße"]);
    }

    #[test]
    fn times_never_go_backwards_and_a_word_ends_not_before_it_starts() {
        let w = words_of(&[tok(" a", 50, 40, 0.9, false), tok(" b", 30, 35, 0.9, false)]);
        assert!(w[0].range.end() >= w[0].range.start);
        assert!(w[1].range.start >= w[0].range.start);
        assert!(w[1].range.end() >= w[1].range.start);
    }

    #[test]
    fn whitespace_only_tokens_make_no_word() {
        assert!(words_of(&[tok(" ", 0, 5, 0.9, false), tok("\n", 5, 9, 0.9, false)]).is_empty());
    }
}
