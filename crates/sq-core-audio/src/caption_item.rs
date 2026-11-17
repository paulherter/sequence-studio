// Swift: Captions+Karaoke.swift, CaptionHandover.swift (`isBlank`)
//! Words, tokens and karaoke keys of one caption. A word's range inside a `CaptionItem` is relative to the item's start, so
//! moving, rippling and tail-trimming a caption keep its words right without touching them (a head trim shifts them by the
//! trimmed amount).

use sq_core_model::{CaptionItem, CaptionWord, KaraokeStyle};
use sq_core_time::{Time, TimeRange, text::graphemes, word_segmentation};

/// Words below this confidence are marked in the caption editor so mistakes are found fast.
pub const UNSURE_BELOW: f32 = 0.5;

/// `extension CaptionWord`.
pub trait CaptionWordExt {
    /// True when the recognizer reported a confidence under `UNSURE_BELOW`.
    fn is_unsure(&self) -> bool;
    /// The one rule for every surface (timeline, transcript panel): `None` (hand-typed or none reported) is never unsure.
    fn is_unsure_confidence(confidence: Option<f32>) -> bool;
}

impl CaptionWordExt for CaptionWord {
    fn is_unsure(&self) -> bool {
        Self::is_unsure_confidence(self.confidence)
    }

    fn is_unsure_confidence(confidence: Option<f32>) -> bool {
        confidence.is_some_and(|c| c < UNSURE_BELOW)
    }
}

/// Swift `KaraokeStyle.init`: components are clamped to 0...1.
pub trait KaraokeStyleExt: Sized {
    /// The yellow default of the TikTok look.
    fn default_style() -> Self;
    /// A style with every component clamped to 0...1.
    fn clamped(red: f64, green: f64, blue: f64, keep_spoken: bool) -> Self;
}

impl KaraokeStyleExt for KaraokeStyle {
    fn default_style() -> Self {
        Self::clamped(1.0, 0.86, 0.1, false)
    }

    fn clamped(red: f64, green: f64, blue: f64, keep_spoken: bool) -> Self {
        let c = |v: f64| v.clamp(0.0, 1.0);
        KaraokeStyle { red: c(red), green: c(green), blue: c(blue), keep_spoken }
    }
}

/// A color key of the karaoke highlight: from `time` on, word `active_word` is lit (`None`: none).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KaraokeKey {
    /// From this time on.
    pub time: Time,
    /// The lit word.
    pub active_word: Option<usize>,
}

/// Characters (Swift `Character`s) of a text.
pub(crate) fn char_count(s: &str) -> i64 {
    graphemes(s).count() as i64
}

/// `extension CaptionItem` of Captions+Karaoke.swift.
pub trait CaptionItemExt {
    /// Lines joined with newlines.
    fn text(&self) -> String;
    /// The words of the text, across all lines.
    fn tokens(&self) -> Vec<String>;
    /// True when the stored word timings still match the text (editing a word keeps them, adding or removing one does not).
    fn has_word_timings(&self) -> bool;
    /// Moves the stored word origin when the start of the caption moves by `delta` without the speech moving (head trim).
    fn shift_word_origin(&mut self, delta: Time);
    /// One timed word per word of the text (absolute timeline time, clamped into the caption): the stored timings while
    /// they match, else the range spread over the words by their length (so captions typed by hand highlight too).
    fn effective_words(&self) -> Vec<CaptionWord>;
    /// Per-word color keys: each word lights up when it starts and stays lit until the next one starts (a pause keeps the
    /// spoken word on); the last key switches everything off at the end of the last word.
    fn karaoke_keys(&self) -> Vec<KaraokeKey>;
    /// The lit word at timeline time `t` (`None` before the first word, after the last one and outside the caption).
    fn active_word(&self, t: Time) -> Option<usize>;
    /// No visible text: such a caption is never drawn and never takes part in a hand-over.
    fn is_blank(&self) -> bool;
}

impl CaptionItemExt for CaptionItem {
    fn text(&self) -> String {
        self.lines.join("\n")
    }

    fn tokens(&self) -> Vec<String> {
        self.lines.iter().flat_map(|l| word_segmentation::words(l)).collect()
    }

    fn has_word_timings(&self) -> bool {
        !self.words.is_empty() && self.words.len() == self.tokens().len()
    }

    fn shift_word_origin(&mut self, delta: Time) {
        if self.words.is_empty() || delta == Time::ZERO {
            return;
        }
        for w in self.words.iter_mut() {
            w.range = TimeRange::from_end(w.range.start - delta, w.range.end() - delta);
        }
    }

    fn effective_words(&self) -> Vec<CaptionWord> {
        let toks = self.tokens();
        if toks.is_empty() {
            return Vec::new();
        }
        let range = self.range;
        if self.has_word_timings() {
            let clamp = |t: Time| t.max(range.start).min(range.end());
            return toks
                .iter()
                .zip(&self.words)
                .map(|(tok, w)| {
                    let a = clamp(range.start + w.range.start);
                    let b = clamp(range.start + w.range.end()).max(a);
                    CaptionWord {
                        text: tok.clone(),
                        range: TimeRange::from_end(a, b),
                        confidence: if &w.text == tok { w.confidence } else { None },
                    }
                })
                .collect();
        }
        let total: i64 = toks.iter().map(|t| char_count(t).max(1)).sum();
        let d = range.duration;
        let mut cum = 0_i64;
        toks.iter()
            .map(|tok| {
                let a = cum;
                cum += char_count(tok).max(1);
                // Huge timescales round (see Time::reducing): clamp so a word never ends before it starts.
                let at = |n: i64| {
                    if n == total {
                        range.end()
                    } else {
                        (range.start + Time::scaled_int(d, n, total)).max(range.start).min(range.end())
                    }
                };
                let s = at(a);
                CaptionWord { text: tok.clone(), range: TimeRange::from_end(s, at(cum).max(s)), confidence: None }
            })
            .collect()
    }

    fn karaoke_keys(&self) -> Vec<KaraokeKey> {
        let w = self.effective_words();
        let Some(last_word) = w.last() else { return Vec::new() };
        let mut keys = Vec::new();
        let mut last: Option<Time> = None;
        for (i, word) in w.iter().enumerate() {
            let t = word.range.start.max(last.unwrap_or(word.range.start));
            keys.push(KaraokeKey { time: t, active_word: Some(i) });
            last = Some(t);
        }
        keys.push(KaraokeKey { time: last_word.range.end().max(last.unwrap_or(Time::ZERO)), active_word: None });
        keys
    }

    fn active_word(&self, t: Time) -> Option<usize> {
        if !self.range.contains(t) {
            return None;
        }
        let mut result = None;
        for k in self.karaoke_keys() {
            if k.time <= t {
                result = k.active_word;
            } else {
                break;
            }
        }
        result
    }

    fn is_blank(&self) -> bool {
        // Foundation's whitespacesAndNewlines set, as `sq_prproj_reader::fastxml::is_ws` documents it.
        self.text().chars().all(is_whitespace_or_newline)
    }
}

/// Foundation's `CharacterSet.whitespacesAndNewlines`, the same table as `sq_prproj_reader::fastxml::is_ws`.
// shortcut: a copy of that private table; move one shared helper into `sq_core_time::text` (PORTING.md section 5).
fn is_whitespace_or_newline(c: char) -> bool {
    matches!(c as u32,
        0x09..=0x0D | 0x20 | 0x85 | 0xA0 | 0x1680 | 0x2000..=0x200B | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::audio_role::tests::fresh_id;

    pub(crate) fn t(ms: i64) -> Time {
        Time::new(ms, 1000)
    }
    pub(crate) fn range(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(t(a), t(b))
    }
    pub(crate) fn word(s: &str, a: i64, b: i64) -> CaptionWord {
        CaptionWord { text: s.to_string(), range: range(a, b), confidence: None }
    }
    /// A caption with the Swift initializer's defaults.
    pub(crate) fn item(lines: &[&str], r: TimeRange) -> CaptionItem {
        CaptionItem {
            id: fresh_id(),
            lines: lines.iter().map(|l| l.to_string()).collect(),
            range: r,
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        }
    }

    #[test]
    fn effective_words_spread_by_length_without_timings() {
        let c = item(&["ab cdef"], range(0, 3000));
        let w = c.effective_words();
        assert_eq!(w.iter().map(|x| x.text.as_str()).collect::<Vec<_>>(), vec!["ab", "cdef"]);
        assert_eq!(w[0].range, range(0, 1000));
        assert_eq!(w[1].range, range(1000, 3000));
        assert!(!c.has_word_timings());
    }

    #[test]
    fn stored_timings_are_clamped_into_the_caption_and_keep_confidence_of_unchanged_words() {
        let mut c = item(&["one two"], range(1000, 2000));
        c.words = vec![
            CaptionWord { confidence: Some(0.3), ..word("one", 0, 500) },
            CaptionWord { confidence: Some(0.9), ..word("old", 500, 5000) },
        ];
        assert!(c.has_word_timings());
        let w = c.effective_words();
        assert_eq!((w[0].range, w[0].confidence), (range(1000, 1500), Some(0.3)));
        assert_eq!((w[1].range, w[1].confidence), (range(1500, 2000), None)); // text differs, tail clamped
        assert!(CaptionWord::is_unsure_confidence(Some(0.3)) && !CaptionWord::is_unsure_confidence(None));
    }

    #[test]
    fn karaoke_keys_light_each_word_and_switch_off_at_the_end() {
        let mut c = item(&["a b"], range(0, 2000));
        c.words = vec![word("a", 0, 500), word("b", 800, 1200)];
        let k = c.karaoke_keys();
        assert_eq!(
            k,
            vec![
                KaraokeKey { time: t(0), active_word: Some(0) },
                KaraokeKey { time: t(800), active_word: Some(1) },
                KaraokeKey { time: t(1200), active_word: None }
            ]
        );
        assert_eq!(c.active_word(t(600)), Some(0)); // a pause keeps the spoken word on
        assert_eq!(c.active_word(t(1300)), None);
        assert_eq!(c.active_word(t(2000)), None); // outside the caption
    }

    #[test]
    fn shift_word_origin_moves_the_stored_words_back() {
        let mut c = item(&["a"], range(0, 1000));
        c.words = vec![word("a", 100, 400)];
        c.shift_word_origin(t(100));
        assert_eq!(c.words[0].range, range(0, 300));
    }

    #[test]
    fn blank_captions_have_no_visible_text() {
        assert!(item(&[" ", "\t"], range(0, 1)).is_blank());
        assert!(!item(&["x"], range(0, 1)).is_blank());
    }

    #[test]
    fn karaoke_style_components_are_clamped() {
        let k = KaraokeStyle::clamped(2.0, -1.0, 0.5, true);
        assert_eq!((k.red, k.green, k.blue, k.keep_spoken), (1.0, 0.0, 0.5, true));
    }
}
