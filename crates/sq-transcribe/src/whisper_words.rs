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
    words_in_voice(tokens, None, ids)
}

/// Like `words`; with the voiced frames of the recording (`whisper_align::voiced_frames_chunked`) a word also ends where its
/// voice ends instead of running across a pause to the next word.
pub fn words_in_voice(tokens: &[WhisperToken], voiced: Option<&[bool]>, ids: &mut dyn IdSource) -> Vec<TranscriptWord> {
    let mut raw: Vec<Raw> = Vec::new();
    let mut cur: Option<Open> = None;
    let mut last_start = 0i64;
    let mut flush = |cur: &mut Option<Open>, raw: &mut Vec<Raw>| {
        let Some(c) = cur.take() else { return };
        let decoded = String::from_utf8_lossy(&c.bytes);
        let text = trim_blanks_and_newlines(&decoded);
        if text.is_empty() {
            return;
        }
        let start = c.start.max(last_start);
        let mut end = c.end.max(start);
        if let Some(v) = voiced {
            end = crate::whisper_align::word_end_in_voice(start, end, v);
        }
        last_start = start;
        raw.push(Raw { text: text.to_string(), start, end, p: c.p });
    };
    for t in tokens.iter().filter(|t| !t.is_special) {
        let starts_word = t.bytes.first().is_some_and(|b| matches!(b, 0x20 | 0x0A | 0x09));
        if starts_word || cur.is_none() {
            flush(&mut cur, &mut raw);
            cur = Some(Open { bytes: Vec::new(), start: t.start_cs, end: t.end_cs, p: t.probability });
        }
        let Some(c) = cur.as_mut() else { continue };
        c.bytes.extend_from_slice(&t.bytes);
        c.end = c.end.max(t.end_cs);
        c.p = c.p.min(t.probability);
    }
    flush(&mut cur, &mut raw);
    spread_collapsed(&mut raw);
    ensure_min_length(&mut raw);
    raw.into_iter()
        .map(|r| {
            let mut word = TranscriptWord::new(
                ids.next_id(),
                &r.text,
                TimeRange::from_end(Time::new(r.start, 100), Time::new(r.end, 100)),
            );
            word.confidence = Some(r.p.clamp(0.0, 1.0));
            word
        })
        .collect()
}

/// A word before it becomes a `TranscriptWord` (times in centiseconds).
struct Raw {
    text: String,
    start: i64,
    end: i64,
    p: f32,
}

/// Centiseconds of speech assumed per character when a run of words has no time of its own (about 12 characters a second).
const CS_PER_CHAR: i64 = 8;

/// Words without a duration come from a degenerate segment (the model closed a timestamp pair where it opened it, or the
/// alignment found no frames). A run of them (same time) gets the time up to the next word with a different time, shared out by text length and
/// capped at the usual speaking speed, so word-by-word captions keep every word. Words with a duration stay as they are.
fn spread_collapsed(words: &mut [Raw]) {
    let mut i = 0;
    while i < words.len() {
        if words[i].end > words[i].start {
            i += 1;
            continue;
        }
        let mut j = i;
        // One run = the collapsed words that share one time; a later collapsed time starts its own run.
        while j < words.len() && words[j].end <= words[j].start && words[j].start == words[i].start {
            j += 1;
        }
        let chars: Vec<i64> = words[i..j].iter().map(|w| w.text.chars().count().max(1) as i64).collect();
        let total: i64 = chars.iter().sum();
        let from = words[i].start;
        let estimate = total * CS_PER_CHAR;
        let room = words.get(j).map_or(estimate, |next| (next.start - from).max(0));
        let span = estimate.min(room);
        let mut at = 0i64;
        let mut edge = from;
        for (w, c) in words[i..j].iter_mut().zip(&chars) {
            at += c;
            let next_edge = from + span * at / total;
            w.start = edge;
            w.end = next_edge;
            edge = next_edge;
        }
        i = j;
    }
}

/// Shortest a word may be (centiseconds), so a word-by-word caption never skips one.
pub const MIN_WORD_CS: i64 = 8;

/// Final guarantee: every word lasts at least `MIN_WORD_CS`. A word that is too short grows to that length; the words after it
/// move on only as far as needed, so nothing overlaps and the order stays. (The spread of collapsed runs has no room when the
/// next word starts at the same time, and a word at the very end has no next word at all.)
fn ensure_min_length(words: &mut [Raw]) {
    for i in 0..words.len() {
        if words[i].end - words[i].start >= MIN_WORD_CS {
            continue;
        }
        let end = words[i].start + MIN_WORD_CS;
        words[i].end = end;
        if let Some(next) = words.get_mut(i + 1)
            && next.start < end
        {
            next.start = end;
            next.end = next.end.max(end);
        }
    }
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
    fn a_run_of_words_without_a_duration_shares_the_time_up_to_the_next_word() {
        // Two degenerate segments (start == end), as the model closed <|27.00|> where it opened it.
        let w = words_of(&[
            tok(" a", 100, 150, 0.9, false),
            tok(" Öffne", 270, 270, 0.9, false),
            tok(" die", 270, 270, 0.9, false),
            tok(" Einstellung", 270, 270, 0.9, false),
            tok(" Hier", 320, 320, 0.9, false),
            tok(" kannst", 320, 320, 0.9, false),
            tok(" du", 390, 400, 0.9, false),
        ]);
        let cs = |t: Time| t.value() * 100 / t.timescale();
        assert!(w.iter().all(|w| w.range.end() > w.range.start), "{w:?}");
        assert!(w.windows(2).all(|p| p[0].range.end() <= p[1].range.start));
        assert_eq!(cs(w[0].range.start), 100);
        assert_eq!(cs(w[1].range.start), 270);
        assert!(cs(w[3].range.end()) <= 320, "the run stops at the next timed word");
        assert_eq!(cs(w[4].range.start), 320);
        assert!(cs(w[5].range.end()) <= 390);
    }

    #[test]
    fn a_collapsed_tail_gets_a_speaking_time_not_the_whole_rest() {
        let w = words_of(&[tok(" Hallo", 500, 500, 0.9, false), tok(" Welt", 500, 500, 0.9, false)]);
        assert!(w.iter().all(|w| w.range.end() > w.range.start));
        assert!(w[1].range.end() <= Time::new(500 + 9 * 8, 100));
    }

    fn voiced_between(n_frames: usize, runs: &[(usize, usize)]) -> Vec<bool> {
        (0..n_frames).map(|f| runs.iter().any(|(a, b)| (*a..*b).contains(&f))).collect()
    }

    #[test]
    fn a_word_ends_where_its_voice_ends_not_across_the_pause() {
        // "endlich" is voiced 0.0-0.6 s, silent until 10.0 s, the next word is voiced from 10.0 s; the token runs to 10.0 s.
        let voiced = voiced_between(1100, &[(0, 30), (500, 520)]);
        let tokens = [tok(" endlich", 0, 1000, 0.9, false), tok(" los", 1000, 1040, 0.9, false)];
        let w = words_in_voice(&tokens, Some(&voiced), &mut SequentialIds::default());
        let cs = |t: Time| t.value() * 100 / t.timescale();
        assert_eq!(cs(w[0].range.start), 0);
        assert!(cs(w[0].range.end()) <= 60 + 2 * 2, "{:?}", w[0].range);
        assert_eq!(cs(w[1].range.start), 1000);
        // Without audio the end stays as the tokens say.
        assert_eq!(cs(words_of(&tokens)[0].range.end()), 1000);
    }

    #[test]
    fn a_short_pause_inside_a_word_is_bridged() {
        let voiced = voiced_between(100, &[(0, 10), (15, 30)]); // 0.1 s gap
        let tokens = [tok(" Wort", 0, 200, 0.9, false)];
        let w = words_in_voice(&tokens, Some(&voiced), &mut SequentialIds::default());
        assert!(w[0].range.end() >= Time::new(60, 100), "{:?}", w[0].range);
    }

    #[test]
    fn no_word_is_shorter_than_the_minimum_even_at_the_end_or_before_a_word_with_the_same_start() {
        let w = words_of(&[
            tok(" Es", 6868, 6868, 0.9, false),
            tok(" ist", 6868, 6900, 0.9, false),
            tok(" vorher", 19476, 19476, 0.9, false),
        ]);
        let cs = |t: Time| t.value() * 100 / t.timescale();
        assert!(w.iter().all(|w| cs(w.range.end()) - cs(w.range.start) >= MIN_WORD_CS), "{w:?}");
        assert!(w.windows(2).all(|p| p[0].range.end() <= p[1].range.start));
    }

    #[test]
    fn whitespace_only_tokens_make_no_word() {
        assert!(words_of(&[tok(" ", 0, 5, 0.9, false), tok("\n", 5, 9, 0.9, false)]).is_empty());
    }
}
