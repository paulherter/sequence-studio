// Swift: TranscriptEditing.swift (word ids for new words come from an `IdSource`; strings compare by bytes, not by
// Unicode canonical equivalence, see NOTES.md)
//! Applies a text-only edit to a transcript.

use crate::transcript::{Transcript, TranscriptWord};
use sq_core_time::text::graphemes;
use sq_core_time::{IdSource, Time, TimeRange};

/// Constants and helpers of the text edit.
pub struct TranscriptEditing;

impl TranscriptEditing {
    /// Duration given to each inserted word when there is no gap to fill
    /// (inserted at the start or end of a transcript, or into an empty one): 1/3 s per word.
    pub const FALLBACK_WORD_DURATION: Time = Time::new(1, 3);

    /// Minimum time per inserted word in a gap between unchanged neighbors. A smaller gap
    /// (including zero) is widened by sharing time with the neighbors.
    pub const MIN_INSERTED_WORD_DURATION: Time = Time::new(1, 100);

    /// Comparison key: lowercased, surrounding punctuation stripped. Falls back to the raw token if nothing is left.
    fn normalise(token: &str) -> String {
        let lower = token.to_lowercase();
        let trimmed = lower.trim_matches(|c: char| !is_alphanumeric(c));
        if trimmed.is_empty() { lower.clone() } else { trimmed.to_string() }
    }

    fn tokenise(text: &str) -> Vec<String> {
        text.split(char::is_whitespace).filter(|s| !s.is_empty()).map(str::to_string).collect()
    }
}

/// `CharacterSet.alphanumerics`: letters, marks and numbers.
fn is_alphanumeric(c: char) -> bool {
    c.is_alphanumeric()
        || matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// Character count of Swift `String.count`, at least one (the weight of a word).
fn weight(text: &str) -> i64 {
    (graphemes(text).count() as i64).max(1)
}

/// `Time(span.duration.value * cum, span.duration.timescale * total)`: `cum / total` of the span.
fn fraction_of(span: &TimeRange, cum: i64, total: i64) -> Time {
    Time::new(span.duration.value() * cum, span.duration.timescale() * total)
}

/// The state of one `applying_text` run.
struct Edit<'a> {
    words: &'a [TranscriptWord],
    tokens: Vec<String>,
    result: Vec<TranscriptWord>,
    /// Index of the next old word and of the next new token.
    oi: usize,
    ni: usize,
    pending_next_start: Option<Time>,
}

impl Edit<'_> {
    fn flush_run(&mut self, old_end: usize, new_end: usize, ids: &mut dyn IdSource) {
        let old_run = &self.words[self.oi..old_end];
        let new_run: Vec<String> = self.tokens[self.ni..new_end].to_vec();
        if new_run.is_empty() {
            return;
        }
        if old_run.is_empty()
            && old_end < self.words.len()
            && let Some(prev) = self.result.last()
        {
            let next = &self.words[old_end];
            let gap = next.range.start - prev.range.end();
            let needed = Self::min_inserted(new_run.len());
            let span = TimeRange::from_end(prev.range.start, next.range.end());
            if gap < needed && span.duration > Time::ZERO {
                let mut weights = vec![weight(&prev.text)];
                weights.extend(new_run.iter().map(|t| weight(t)));
                weights.push(weight(&next.text));
                let total: i64 = weights.iter().sum();
                let mut bounds = vec![span.start];
                let mut cum = 0i64;
                for wgt in &weights[..weights.len() - 1] {
                    cum += wgt;
                    bounds.push(span.start + fraction_of(&span, cum, total));
                }
                bounds.push(span.end());
                if let Some(last) = self.result.last_mut() {
                    last.range = TimeRange::from_end(bounds[0], bounds[1]);
                }
                for (k, token) in new_run.iter().enumerate() {
                    let mut word =
                        TranscriptWord::new(ids.next_id(), token, TimeRange::from_end(bounds[k + 1], bounds[k + 2]));
                    word.is_edited = true;
                    self.result.push(word);
                }
                self.pending_next_start = Some(bounds[new_run.len() + 1]);
                return;
            }
        }
        let (span, equal) = self.span_for_run(old_run, old_end, new_run.len());
        let spread = Self::spread(&new_run, &span, equal, ids);
        self.result.extend(spread);
    }

    fn min_inserted(count: usize) -> Time {
        TranscriptEditing::MIN_INSERTED_WORD_DURATION * count as i64
    }

    /// Span for a run; the flag is true when the span came from the fallback duration (1/3 s per word).
    fn span_for_run(&self, old_run: &[TranscriptWord], old_end: usize, count: usize) -> (TimeRange, bool) {
        if let (Some(first), Some(last)) = (old_run.first(), old_run.last()) {
            return (TimeRange::from_end(first.range.start, last.range.end().max(first.range.start)), false);
        }
        // Pure insertion: gap between unchanged neighbors.
        let prev_end = self.result.last().map(|p| p.range.end());
        let next = self.words.get(old_end).map(|w| w.range.start);
        let fallback = TranscriptEditing::FALLBACK_WORD_DURATION * count as i64;
        match (prev_end, next) {
            (Some(p), Some(n)) => (TimeRange::from_end(p, n.max(p)), false),
            (Some(p), None) => (TimeRange::new(p, fallback), true),
            (None, Some(n)) => {
                let s = Time::ZERO.max(n - fallback);
                (TimeRange::from_end(s, n.max(s)), true)
            }
            (None, None) => (TimeRange::new(Time::ZERO, fallback), true),
        }
    }

    /// Splits `span` into contiguous slots proportional to character count. A 1:1 run keeps the slot exactly.
    fn spread(tokens: &[String], span: &TimeRange, equal_weights: bool, ids: &mut dyn IdSource) -> Vec<TranscriptWord> {
        let weights: Vec<i64> = tokens.iter().map(|t| if equal_weights { 1 } else { weight(t) }).collect();
        let total: i64 = weights.iter().sum();
        let mut out = Vec::new();
        let mut cum = 0i64;
        let mut cursor = span.start;
        for (i, token) in tokens.iter().enumerate() {
            cum += weights[i];
            let end = if i == tokens.len() - 1 { span.end() } else { span.start + fraction_of(span, cum, total) };
            let mut word = TranscriptWord::new(ids.next_id(), token, TimeRange::from_end(cursor, end.max(cursor)));
            word.is_edited = true;
            out.push(word);
            cursor = end.max(cursor);
        }
        out
    }
}

/// Index pairs of a longest common subsequence, ascending.
fn lcs_pairs(a: &[String], b: &[String]) -> Vec<(usize, usize)> {
    let (n, m) = (a.len(), b.len());
    if n == 0 || m == 0 {
        return Vec::new();
    }
    let mut dp = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if a[i] == b[j] { dp[i + 1][j + 1] + 1 } else { dp[i + 1][j].max(dp[i][j + 1]) };
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut out = Vec::new();
    while i < n && j < m {
        if a[i] == b[j] {
            out.push((i, j));
            i += 1;
            j += 1;
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    out
}

impl Transcript {
    /// Applies a text-only edit. Unchanged words keep their exact timing; replaced words take the old
    /// words' span; inserted words split the gap between their unchanged neighbors proportionally to
    /// character count; deleted words vanish. Never touches media.
    ///
    /// Edge cases: when the gap between the neighbors is zero or smaller than
    /// `TranscriptEditing::MIN_INSERTED_WORD_DURATION` per inserted word, the neighbors' time is shared with
    /// the inserted words proportionally by character count (neighbors keep their outer start/end);
    /// inserts at the start/end use `TranscriptEditing::FALLBACK_WORD_DURATION` per word
    /// (at the start the run ends at the first word's start, clamped at zero).
    pub fn applying_text(&self, new_text: &str, ids: &mut dyn IdSource) -> Transcript {
        let tokens = TranscriptEditing::tokenise(new_text);
        let old_keys: Vec<String> = self.words.iter().map(|w| TranscriptEditing::normalise(&w.text)).collect();
        let new_keys: Vec<String> = tokens.iter().map(|t| TranscriptEditing::normalise(t)).collect();
        let mut pairs = lcs_pairs(&old_keys, &new_keys);
        pairs.push((self.words.len(), tokens.len()));

        let mut edit = Edit { words: &self.words, tokens, result: Vec::new(), oi: 0, ni: 0, pending_next_start: None };
        for (o, n) in pairs {
            edit.flush_run(o, n, ids);
            if o < self.words.len() && n < edit.tokens.len() {
                let mut kept = self.words[o].clone();
                if kept.text != edit.tokens[n] {
                    kept.text = edit.tokens[n].clone();
                    kept.is_edited = true;
                    kept.confidence = None;
                }
                if let Some(s) = edit.pending_next_start.take() {
                    kept.range = TimeRange::from_end(s, kept.range.end());
                }
                edit.result.push(kept);
            }
            edit.oi = o + 1;
            edit.ni = n + 1;
        }
        Transcript { language: self.language.clone(), words: edit.result }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_support::*;
    use sq_core_time::SequentialIds;

    fn base() -> Transcript {
        transcript(vec![w("Hallo,", 0, 500), w("liebe", 600, 1000), w("Welt.", 1200, 2000)])
    }

    fn apply(tr: &Transcript, text: &str) -> Transcript {
        tr.applying_text(text, &mut SequentialIds::default())
    }

    fn texts(tr: &Transcript) -> Vec<&str> {
        tr.words.iter().map(|w| w.text.as_str()).collect()
    }

    #[test]
    fn unchanged_text_changes_nothing() {
        let b = base();
        let r = apply(&b, "Hallo, liebe Welt.");
        assert_eq!(r, b);
        assert!(r.words.iter().all(|w| !w.is_edited));
    }

    #[test]
    fn punctuation_and_case_are_ignored_for_diff_but_text_is_verbatim() {
        let b = base();
        let r = apply(&b, "hallo liebe Welt!");
        assert_eq!(
            r.words.iter().map(|w| w.range).collect::<Vec<_>>(),
            b.words.iter().map(|w| w.range).collect::<Vec<_>>()
        );
        assert_eq!(r.words.iter().map(|w| w.id).collect::<Vec<_>>(), b.words.iter().map(|w| w.id).collect::<Vec<_>>());
        assert_eq!(r.text(), "hallo liebe Welt!");
        assert!(r.words[0].is_edited && r.words[2].is_edited);
        assert!(!r.words[1].is_edited);
    }

    #[test]
    fn replaced_word_takes_old_slot() {
        let b = base();
        let r = apply(&b, "Hallo, liebe Leute.");
        assert_eq!(r.words.len(), 3);
        assert_eq!(r.words[2].text, "Leute.");
        assert_eq!(r.words[2].range, b.words[2].range);
        assert!(r.words[2].is_edited);
        assert_eq!(r.words[0].range, b.words[0].range);
        assert_eq!(r.words[1].range, b.words[1].range);
    }

    #[test]
    fn deleted_words_vanish() {
        let b = base();
        let r = apply(&b, "Hallo, Welt.");
        assert_eq!(texts(&r), ["Hallo,", "Welt."]);
        assert_eq!(r.words[0].range, b.words[0].range);
        assert_eq!(r.words[1].range, b.words[2].range);
    }

    #[test]
    fn inserted_words_split_gap_proportionally_to_char_count() {
        // gap between "Hallo," (end 500) and "liebe" (start 600) = 100 ms; "ab" = 2 chars, "cdef" = 4 chars
        let b = base();
        let r = apply(&b, "Hallo, ab cdef liebe Welt.");
        assert_eq!(texts(&r), ["Hallo,", "ab", "cdef", "liebe", "Welt."]);
        let (ab, cd) = (r.words[1].range, r.words[2].range);
        assert_eq!(ab.start, t(500));
        assert_eq!(ab.duration, Time::new(100 * 2, 6 * 1000));
        assert_eq!(ab.end(), cd.start);
        assert_eq!(cd.end(), t(600));
        assert!(r.words[1].is_edited && r.words[2].is_edited);
        assert_eq!(r.words[0].range, b.words[0].range);
        assert_eq!(r.words[3].range, b.words[1].range);
    }

    #[test]
    fn inserted_words_strictly_increasing_and_non_overlapping() {
        let r = apply(&base(), "Hallo, a bb ccc dddd eeeee liebe Welt.");
        for (a, b) in r.words.iter().zip(r.words.iter().skip(1)) {
            assert!(a.range.start < b.range.start);
            assert!(a.range.end() <= b.range.start);
        }
    }

    #[test]
    fn insert_at_end_uses_fallback_duration_per_word() {
        let r = apply(&base(), "Hallo, liebe Welt. Und mehr");
        let (und, mehr) = (r.words[3].range, r.words[4].range);
        assert_eq!(und.start, t(2000));
        assert_eq!(und.duration, TranscriptEditing::FALLBACK_WORD_DURATION);
        assert_eq!(mehr.start, und.end());
        assert_eq!(mehr.duration, TranscriptEditing::FALLBACK_WORD_DURATION);
        assert_eq!(TranscriptEditing::FALLBACK_WORD_DURATION, Time::new(1, 3));
    }

    #[test]
    fn insert_at_start_ends_at_first_word_start() {
        let tr = transcript(vec![w("liebe", 2000, 2500)]);
        let r = apply(&tr, "Hallo liebe");
        assert_eq!(r.words[0].text, "Hallo");
        assert_eq!(r.words[0].range.end(), t(2000));
        assert_eq!(r.words[0].range.duration, TranscriptEditing::FALLBACK_WORD_DURATION);
        assert_eq!(r.words[1].range, tr.words[0].range);
    }

    #[test]
    fn insert_at_start_never_goes_negative() {
        let tr = transcript(vec![w("liebe", 100, 500)]);
        let r = apply(&tr, "Hallo liebe");
        assert_eq!(r.words[0].range.start, Time::ZERO);
        assert_eq!(r.words[0].range.end(), t(100));
    }

    #[test]
    fn replacing_more_words_spreads_over_old_span() {
        let b = base();
        let r = apply(&b, "Hallo, liebe große weite Welt.");
        // "Welt." unchanged
        assert_eq!(r.words.last().map(|w| w.range), Some(b.words[2].range));
        assert_eq!(r.words.len(), 5);
        for (a, b) in r.words.iter().zip(r.words.iter().skip(1)) {
            assert!(a.range.end() <= b.range.start);
        }
    }

    #[test]
    fn empty_transcript_gets_sequential_fallback_words() {
        let r = apply(&transcript(vec![]), "eins zwei");
        assert_eq!(r.words.len(), 2);
        assert_eq!(r.words[0].range.start, Time::ZERO);
        assert_eq!(r.words[1].range.start, r.words[0].range.end());
    }

    #[test]
    fn deleting_everything_gives_empty_transcript() {
        assert!(apply(&base(), "  ").words.is_empty());
    }

    #[test]
    fn language_is_preserved() {
        assert_eq!(apply(&base(), "x").language, "de-DE");
    }

    fn expect_contiguous_positive(r: &Transcript) {
        for x in &r.words {
            assert!(x.range.duration > Time::ZERO);
        }
        for (a, b) in r.words.iter().zip(r.words.iter().skip(1)) {
            assert_eq!(a.range.end(), b.range.start);
        }
    }

    #[test]
    fn zero_gap_insertion_shares_time_with_neighbours_by_char_count() {
        // "abcd" 0..400, "efgh" 400..800, zero gap. Insert "xx" (2 chars): total 10 chars over 0..800.
        let b = transcript(vec![w("abcd", 0, 400), w("efgh", 400, 800)]);
        let r = apply(&b, "abcd xx efgh");
        assert_eq!(texts(&r), ["abcd", "xx", "efgh"]);
        assert_eq!(r.words[0].range.start, t(0));
        assert_eq!(r.words[2].range.end(), t(800));
        expect_contiguous_positive(&r);
        assert!(r.words[1].is_edited);
        assert_eq!(r.words[1].range.duration, Time::new(800 * 2, 1000 * 10));
        assert_eq!(r.words[0].range.end(), Time::new(800 * 4, 1000 * 10));
    }

    #[test]
    fn zero_gap_multiple_inserted_words() {
        let b = transcript(vec![w("aa", 100, 300), w("bb", 300, 500)]);
        let r = apply(&b, "aa c dd eee bb");
        assert_eq!(r.words.len(), 5);
        assert_eq!(r.words[0].range.start, t(100));
        assert_eq!(r.words[4].range.end(), t(500));
        expect_contiguous_positive(&r);
    }

    #[test]
    fn tiny_gap_is_treated_like_zero_gap() {
        let b = transcript(vec![w("abcd", 0, 400), w("efgh", 401, 800)]);
        let r = apply(&b, "abcd xx yy efgh");
        assert_eq!(r.words[0].range.start, t(0));
        assert_eq!(r.words[3].range.end(), t(800));
        expect_contiguous_positive(&r);
        for x in &r.words {
            assert!(x.range.duration >= Time::new(1, 100));
        }
    }

    #[test]
    fn zero_gap_insertion_leaves_other_words_untouched() {
        let b = transcript(vec![w("one", 0, 300), w("abcd", 300, 600), w("efgh", 600, 900), w("two", 900, 1200)]);
        let r = apply(&b, "one abcd xx efgh two");
        assert_eq!(r.words[0].range, b.words[0].range);
        assert_eq!(r.words[4].range, b.words[3].range);
        assert_eq!(r.words[0].id, b.words[0].id);
        assert_eq!(r.words[1].id, b.words[1].id);
        assert_eq!(r.words[3].id, b.words[2].id);
    }

    #[test]
    fn non_zero_roomy_gap_does_not_touch_neighbours() {
        let b = base();
        let r = apply(&b, "Hallo, ab liebe Welt.");
        assert_eq!(r.words[0].range, b.words[0].range);
        assert_eq!(r.words[2].range, b.words[1].range);
    }
}
