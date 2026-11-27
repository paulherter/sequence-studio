// Swift: CaptionSegmenter.swift
//! Splits a transcript into captions.

use crate::caption_preset::CaptionPreset;
use crate::transcript::{Transcript, has_letter_or_number};
use sq_core_model::{CaptionPosition, CaptionWord, KaraokeStyle};
use sq_core_time::text::graphemes;
use sq_core_time::{Id, Time, TimeRange, word_segmentation};
use std::ops::Range;

/// One caption: its lines, time and the words it was made from.
#[derive(Clone, Debug, PartialEq)]
pub struct Caption {
    /// The text lines.
    pub lines: Vec<String>,
    /// On screen from start to end.
    pub range: TimeRange,
    /// Id of the first word.
    pub first_word_id: Id,
    /// Id of the last word.
    pub last_word_id: Id,
    /// Indices into `Transcript::words`.
    pub word_indices: Range<usize>,
    /// Style reference.
    pub style_ref: String,
    /// Animation reference.
    pub animation_ref: String,
    /// The spoken words with their times (same time base as `range`): the karaoke highlight follows them.
    pub words: Vec<CaptionWord>,
    /// Karaoke word highlight of the caption's track (burn-in only); `None` = off.
    pub karaoke: Option<KaraokeStyle>,
    /// The caption's own position (`None`: the project's).
    pub position: Option<CaptionPosition>,
}

impl Caption {
    /// A caption without words, karaoke and position (Swift's defaults); the ids and indices name the transcript words.
    pub fn new(
        lines: Vec<String>,
        range: TimeRange,
        first_word_id: Id,
        last_word_id: Id,
        word_indices: Range<usize>,
        style_ref: &str,
        animation_ref: &str,
    ) -> Caption {
        Caption {
            lines,
            range,
            first_word_id,
            last_word_id,
            word_indices,
            style_ref: style_ref.to_string(),
            animation_ref: animation_ref.to_string(),
            words: Vec::new(),
            karaoke: None,
            position: None,
        }
    }
}

/// Longest a caption stays up past the end of its last spoken word because a punctuation mark is timed later.
const MAX_HOLD: Time = Time::new(2, 5);

/// A caption being built in the one-word-per-caption mode.
#[derive(Clone)]
struct Unit {
    text: String,
    words: Vec<CaptionWord>,
    start: Time,
    end: Time,
    lo: usize,
    hi: usize,
    first_id: Id,
    last_id: Id,
}

fn char_count(text: &str) -> usize {
    graphemes(text).count()
}

/// Splits a transcript into captions.
pub struct CaptionSegmenter;

impl CaptionSegmenter {
    /// Splits a transcript into captions. Every word lands in exactly one caption; captions never overlap
    /// and their range is exactly the first word's start to the last word's end (start clamped to the
    /// previous caption's end when word times overlap).
    /// Breaks: line/char limit, max duration, pause, sentence end once the caption is about half a line full
    /// and at least `min_duration` long. A word longer than a line gets a line of its own.
    pub fn segment(transcript: &Transcript, preset: &CaptionPreset) -> Vec<Caption> {
        if preset.max_words_per_caption == Some(1) {
            return Self::segment_single_words(transcript, preset);
        }
        let words = &transcript.words;
        let mut captions: Vec<Caption> = Vec::new();
        let mut start_index = 0usize;
        let mut last_end: Option<Time> = None;

        let mut close = |up_to: usize, start_index: &mut usize, last_end: &mut Option<Time>| {
            let slice = &words[*start_index..up_to];
            let (Some(first), Some(last)) = (slice.first(), slice.last()) else { return };
            let mut s = first.range.start;
            if let Some(le) = *last_end
                && s < le
            {
                s = le;
            }
            let mut e = last.range.end().max(s);
            if !has_letter_or_number(&last.text)
                && let Some(spoken) = slice.iter().rev().find(|w| has_letter_or_number(&w.text))
            {
                e = e.min(spoken.range.end() + MAX_HOLD).max(spoken.range.end()).max(s);
            }
            let texts: Vec<&str> = slice.iter().map(|w| w.text.as_str()).collect();
            let mut caption = Caption::new(
                Self::wrap(&texts, preset.max_chars_per_line),
                TimeRange::from_end(s, e),
                first.id,
                last.id,
                *start_index..up_to,
                &preset.style_ref,
                &preset.animation_ref,
            );
            caption.words = slice
                .iter()
                .map(|w| CaptionWord { text: w.text.clone(), range: w.range, confidence: w.confidence })
                .collect();
            captions.push(caption);
            *last_end = Some(e);
            *start_index = up_to;
        };

        for i in 0..words.len() {
            if i > start_index {
                let current = &words[start_index..i];
                let word = &words[i];
                let prev = &words[i - 1];
                let mut texts: Vec<&str> = current.iter().map(|w| w.text.as_str()).collect();
                let paused = word.range.start - prev.range.end() >= preset.pause_break;
                let too_long = word.range.end() - current[0].range.start > preset.max_duration;
                let full = preset.max_words_per_caption.is_some_and(|n| current.len() as i64 >= n);
                let split = paused || too_long || full || {
                    texts.push(&word.text);
                    if Self::wrap(&texts, preset.max_chars_per_line).len() as i64 > preset.max_lines {
                        true
                    } else {
                        texts.pop();
                        Self::ends_sentence(&prev.text)
                            && (char_count(&texts.join(" ")) as i64) * 2 >= preset.max_chars_per_line
                            && prev.range.end() - current[0].range.start >= preset.min_duration
                    }
                };
                if split {
                    close(i, &mut start_index, &mut last_end);
                }
            }
        }
        close(words.len(), &mut start_index, &mut last_end);
        captions
    }

    /// One word per caption. Ignores `max_duration`, `pause_break` and `gap`; callers must run `apply_timing` afterwards
    /// (it keeps the minimum). Words are never split: a word longer than `max_chars_per_line` is a caption of its own,
    /// and a word without letters or digits (a dash, a lone punctuation mark) joins the caption before it.
    /// A caption shorter than `min_duration` grows into the silence after it, else takes time
    /// from a long enough next caption, else merges with a neighbor (only if the text still fits),
    /// else pushes the next caption's start back by the missing time (see the cascade below).
    fn segment_single_words(transcript: &Transcript, preset: &CaptionPreset) -> Vec<Caption> {
        let mut units: Vec<Unit> = Vec::new();
        let mut last_end: Option<Time> = None;
        for (i, word) in transcript.words.iter().enumerate() {
            let mut s = word.range.start;
            if let Some(le) = last_end
                && s < le
            {
                s = le;
            }
            let e = word.range.end().max(s);
            let r = TimeRange::from_end(s, e);
            let unit = Unit {
                text: word.text.clone(),
                words: vec![CaptionWord { text: word.text.clone(), range: r, confidence: word.confidence }],
                start: s,
                end: e,
                lo: i,
                hi: i + 1,
                first_id: word.id,
                last_id: word.id,
            };
            match units.last() {
                Some(last) if !has_letter_or_number(&word.text) => {
                    let mut m = Self::merged(last, &unit);
                    // A mark the recognizer times after a long pause must not hold the caption through the pause.
                    m.end = m.end.min(last.end + MAX_HOLD).max(last.end);
                    let n = units.len();
                    units[n - 1] = m;
                }
                _ => units.push(unit),
            }
            last_end = Some(e);
        }

        let mut i = 0;
        while i < units.len() {
            let need = preset.min_duration - (units[i].end - units[i].start);
            if need <= Time::ZERO {
                i += 1;
                continue;
            }
            if i + 1 < units.len() {
                let room = units[i + 1].start - units[i].end;
                if room > Time::ZERO {
                    units[i].end += room.min(need);
                }
            } else {
                units[i].end += need; // last caption: trailing time is free
                i += 1;
                continue;
            }
            let still = preset.min_duration - (units[i].end - units[i].start);
            if still <= Time::ZERO {
                i += 1;
                continue;
            }
            // Borrow time from the neighbors' surplus above the minimum (next first, then previous).
            let from_next = if i + 1 < units.len() {
                Time::ZERO.max(still.min(units[i + 1].end - units[i + 1].start - preset.min_duration))
            } else {
                Time::ZERO
            };
            let from_prev = if i > 0 {
                Time::ZERO.max((still - from_next).min(units[i - 1].end - units[i - 1].start - preset.min_duration))
            } else {
                Time::ZERO
            };
            if from_next + from_prev >= still {
                if from_next > Time::ZERO {
                    units[i].end += from_next;
                    units[i + 1].start = units[i].end;
                }
                if from_prev > Time::ZERO {
                    units[i].start -= from_prev;
                    units[i - 1].end = units[i].start;
                }
                i += 1;
                continue;
            }
            if i + 1 < units.len()
                && char_count(&Self::joined_text(&units[i], &units[i + 1])) as i64 <= preset.max_chars_per_line
            {
                units[i] = Self::merged(&units[i], &units[i + 1]);
                units.remove(i + 1);
                continue;
            }
            if i > 0 && char_count(&Self::joined_text(&units[i - 1], &units[i])) as i64 <= preset.max_chars_per_line {
                units[i - 1] = Self::merged(&units[i - 1], &units[i]);
                units.remove(i);
                i -= 1;
                continue;
            }
            // Unavoidable case (no surplus anywhere, text cannot merge): keep the minimum by pushing the next
            // caption's start back; it is then too short itself and grows in turn, so a dense run of tiny
            // captions is delayed, never dropped, and the last one extends into trailing time.
            units[i].end += still;
            if units[i + 1].start < units[i].end {
                units[i + 1].start = units[i].end;
                if units[i + 1].end < units[i + 1].start {
                    units[i + 1].end = units[i + 1].start;
                }
            }
            i += 1;
        }

        units
            .into_iter()
            .map(|u| {
                let mut c = Caption::new(
                    vec![u.text],
                    TimeRange::from_end(u.start, u.end),
                    u.first_id,
                    u.last_id,
                    u.lo..u.hi,
                    &preset.style_ref,
                    &preset.animation_ref,
                );
                c.words = u.words;
                c
            })
            .collect()
    }

    /// Different words join with one space.
    fn joined_text(a: &Unit, b: &Unit) -> String {
        format!("{} {}", a.text, b.text)
    }

    fn merged(a: &Unit, b: &Unit) -> Unit {
        let mut words = a.words.clone();
        words.extend(b.words.iter().cloned());
        Unit {
            text: Self::joined_text(a, b),
            words,
            start: a.start,
            end: a.end.max(b.end),
            lo: a.lo,
            hi: b.hi,
            first_id: a.first_id,
            last_id: b.last_id,
        }
    }

    /// Applies the preset's minimum duration and gap: a caption shorter than `min_duration` is extended into the silence
    /// after it (never over the next caption and its gap), then a caption that ends closer than `gap` to the next one
    /// is shortened (never to nothing). The start of a caption never moves. Input must be sorted and non-overlapping.
    pub fn apply_timing(captions: &[Caption], preset: &CaptionPreset) -> Vec<Caption> {
        let mut out = captions.to_vec();
        for i in 0..out.len() {
            let s = out[i].range.start;
            let mut e = out[i].range.end();
            let limit = out.get(i + 1).map(|n| n.range.start - preset.gap);
            if e - s < preset.min_duration {
                let mut wanted = s + preset.min_duration;
                if let Some(limit) = limit {
                    wanted = wanted.min(limit);
                }
                e = e.max(wanted);
            }
            if let Some(next_caption) = out.get(i + 1) {
                let next = next_caption.range.start;
                if next - e < preset.gap && next - preset.gap > s {
                    e = next - preset.gap;
                }
            }
            out[i].range = TimeRange::from_end(s, e);
        }
        out
    }

    fn ends_sentence(text: &str) -> bool {
        const SKIPPED: [&str; 7] = ["\"", "'", "\u{201D}", "\u{201C}", "\u{BB}", "\u{AB}", ")"];
        let chars: Vec<&str> = graphemes(text).collect();
        let Some(c) = chars.iter().rev().find(|g| !SKIPPED.contains(g) && **g != "]") else { return false };
        matches!(*c, "." | "!" | "?" | "\u{2026}")
    }

    /// Greedy line wrap of whole words (never split); an over-long word occupies its own line, and a word without letters or
    /// digits (a dash) stays at the end of the line before it instead of starting a line.
    ///
    /// The lines are balanced: the narrowest width that keeps the greedy line count sets the breaks, so a caption of two
    /// lines is two similar lines (the greedy fill leaves a short word like "of" that a narrower render wraps alone).
    pub(crate) fn wrap(words: &[&str], max_chars: i64) -> Vec<String> {
        let greedy = Self::wrap_greedy(words, max_chars);
        if greedy.len() < 2 {
            return greedy;
        }
        let longest = words.iter().map(|w| char_count(w) as i64).max().unwrap_or(0).min(max_chars);
        (longest..max_chars)
            .map(|w| Self::wrap_greedy(words, w))
            .find(|lines| lines.len() == greedy.len())
            .unwrap_or(greedy)
    }

    fn wrap_greedy(words: &[&str], max_chars: i64) -> Vec<String> {
        let mut lines: Vec<String> = Vec::new();
        for word in words {
            let punctuation = !has_letter_or_number(word);
            match lines.last_mut() {
                Some(last) if punctuation || (char_count(last) + 1 + char_count(word)) as i64 <= max_chars => {
                    if word_segmentation::is_tight(last, word) {
                        last.push_str(word);
                    } else {
                        last.push(' ');
                        last.push_str(word);
                    }
                }
                _ => lines.push((*word).to_string()),
            }
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_preset::CaptionPresetOptions;
    use crate::transcript::TranscriptWord;
    use crate::transcript::test_support::*;
    use std::collections::BTreeSet;

    fn preset(chars: i64, lines: i64, max_dur: i64, min_dur: i64, pause: i64) -> CaptionPreset {
        CaptionPreset {
            max_chars_per_line: chars,
            max_lines: lines,
            max_duration: t(max_dur),
            min_duration: t(min_dur),
            pause_break: t(pause),
            style_ref: "style.a".into(),
            animation_ref: "anim.b".into(),
            gap: Time::ZERO,
            max_words_per_caption: None,
            emphasis: Default::default(),
        }
    }

    fn p(chars: i64) -> CaptionPreset {
        preset(chars, 2, 6000, 0, 800)
    }

    /// n words of the given text, 300 ms long, 100 ms apart.
    fn run(texts: &[&str]) -> Transcript {
        let mut out = Vec::new();
        let mut cur = 0;
        for x in texts {
            out.push(w(x, cur, cur + 300));
            cur += 300 + 100;
        }
        transcript(out)
    }

    fn lines_of(caps: &[Caption]) -> Vec<Vec<String>> {
        caps.iter().map(|c| c.lines.clone()).collect()
    }

    fn strs(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn empty_transcript_gives_no_captions() {
        assert!(CaptionSegmenter::segment(&transcript(vec![]), &p(20)).is_empty());
    }

    #[test]
    fn short_text_is_one_caption_with_refs() {
        let tr = run(&["Hallo", "Welt"]);
        let caps = CaptionSegmenter::segment(&tr, &p(20));
        assert_eq!(caps.len(), 1);
        assert_eq!(caps[0].lines, ["Hallo Welt"]);
        assert_eq!(caps[0].range, TimeRange::from_end(t(0), t(700)));
        assert!(caps[0].first_word_id == tr.words[0].id && caps[0].last_word_id == tr.words[1].id);
        assert_eq!(caps[0].word_indices, 0..2);
        assert!(caps[0].style_ref == "style.a" && caps[0].animation_ref == "anim.b");
    }

    #[test]
    fn wraps_lines_at_char_limit() {
        let caps = CaptionSegmenter::segment(&run(&["aaaaaaaa", "bbbbbbbb", "cccccccc"]), &p(17));
        assert_eq!(caps.len(), 1);
        assert_eq!(caps[0].lines, ["aaaaaaaa bbbbbbbb", "cccccccc"]);
    }

    /// At a 40 character limit the greedy fill put "of" at the end of line one; a render a little narrower wrapped it
    /// alone onto a third line. Balanced, both lines are short enough and none ends on a stranded short word.
    #[test]
    fn two_lines_are_balanced_not_filled_to_the_limit() {
        let text = "Hello and welcome to this short test of the caption feature.";
        let words: Vec<&str> = text.split(' ').collect();
        let lines = CaptionSegmenter::wrap(&words, 40);
        assert_eq!(lines, ["Hello and welcome to this short", "test of the caption feature."]);
        assert_eq!(CaptionSegmenter::wrap(&["one", "two"], 40), ["one two"], "one line stays one line");
        let lines = CaptionSegmenter::wrap(&["aaaa", "bbbb", "cccc"], 9);
        assert_eq!(lines.len(), 2, "never more lines than the greedy wrap");
    }

    #[test]
    fn line_never_exceeds_limit_except_single_long_word() {
        let words = vec!["wort"; 30];
        for c in CaptionSegmenter::segment(&run(&words), &p(12)) {
            assert!(c.lines.len() <= 2);
            assert!(c.lines.iter().all(|l| l.chars().count() <= 12));
        }
    }

    #[test]
    fn breaks_when_max_lines_exceeded() {
        let caps = CaptionSegmenter::segment(&run(&["aaaa", "bbbb", "cccc"]), &p(4));
        assert_eq!(caps.len(), 2);
        assert_eq!(caps[0].lines, ["aaaa", "bbbb"]);
        assert_eq!(caps[1].lines, ["cccc"]);
        assert_eq!(caps[1].word_indices, 2..3);
    }

    #[test]
    fn single_line_mode() {
        let caps = CaptionSegmenter::segment(&run(&["aaaa", "bbbb", "cccc"]), &preset(9, 1, 6000, 0, 800));
        assert_eq!(lines_of(&caps), [strs(&["aaaa bbbb"]), strs(&["cccc"])]);
    }

    #[test]
    fn breaks_on_max_duration() {
        let caps = CaptionSegmenter::segment(&run(&["a", "b", "c", "d"]), &preset(50, 2, 1000, 0, 800));
        // words at 0-300, 400-700, 800-1100, 1200-1500 -> third would end at 1100 > 1000
        assert!(caps.len() == 3 || caps.len() == 2);
        for c in &caps {
            assert!(c.range.duration <= t(1000) || c.word_indices.len() == 1);
        }
        assert_eq!(caps[0].word_indices, 0..2);
    }

    #[test]
    fn breaks_on_pause() {
        let tr = transcript(vec![w("eins", 0, 300), w("zwei", 400, 700), w("drei", 2000, 2300)]);
        let caps = CaptionSegmenter::segment(&tr, &p(20));
        assert_eq!(lines_of(&caps), [strs(&["eins zwei"]), strs(&["drei"])]);
    }

    #[test]
    fn breaks_at_sentence_end_when_reasonably_full() {
        let tr = run(&["Das", "ist", "ein", "Satz.", "Und", "noch", "einer."]);
        let caps = CaptionSegmenter::segment(&tr, &p(20));
        assert_eq!(caps.len(), 2);
        assert_eq!(caps[0].lines, ["Das ist ein Satz."]);
        assert_eq!(caps[1].lines, ["Und noch einer."]);
    }

    #[test]
    fn does_not_break_at_sentence_end_when_mostly_empty() {
        let caps = CaptionSegmenter::segment(&run(&["Ja.", "Nein."]), &p(40));
        assert_eq!(caps.len(), 1);
    }

    #[test]
    fn no_overlaps_and_all_words_covered_once() {
        let words: Vec<String> = (0..60).map(|i| format!("Wort{i}")).collect();
        let refs: Vec<&str> = words.iter().map(String::as_str).collect();
        let caps = CaptionSegmenter::segment(&run(&refs), &p(15));
        let mut next = 0;
        for (i, c) in caps.iter().enumerate() {
            assert_eq!(c.word_indices.start, next);
            next = c.word_indices.end;
            if i > 0 {
                assert!(caps[i - 1].range.end() <= c.range.start);
            }
        }
        assert_eq!(next, 60);
    }

    #[test]
    fn overlapping_word_times_are_clamped_so_captions_do_not_overlap() {
        let tr = transcript(vec![w("a", 0, 1000), w("b", 500, 1500)]);
        let caps = CaptionSegmenter::segment(&tr, &preset(1, 1, 6000, 0, 800));
        assert_eq!(caps.len(), 2);
        assert!(caps[0].range.end() <= caps[1].range.start);
        assert!(!caps[1].range.is_empty());
    }

    #[test]
    fn single_very_long_word_gets_own_line() {
        let long = "x".repeat(50);
        let caps = CaptionSegmenter::segment(&run(&["kurz", &long, "kurz"]), &p(10));
        assert!(caps.iter().flat_map(|c| c.lines.iter()).any(|l| *l == long));
        assert!(caps.iter().all(|c| c.lines.len() <= 2));
        assert_eq!(caps.iter().map(|c| c.word_indices.len()).sum::<usize>(), 3);
    }

    #[test]
    fn single_long_word_alone_is_one_caption() {
        let long = "x".repeat(50);
        let caps = CaptionSegmenter::segment(&run(&[&long]), &p(10));
        assert_eq!(caps.len(), 1);
        assert_eq!(caps[0].lines, [long]);
    }

    #[test]
    fn min_duration_suppresses_soft_sentence_break() {
        let tr = run(&["Ja.", "Nein.", "Gut."]);
        let caps = CaptionSegmenter::segment(&tr, &preset(6, 1, 6000, 5000, 800));
        // limits still force breaks; sentence rule alone must not split short captions
        let roomy = CaptionSegmenter::segment(&tr, &preset(40, 2, 6000, 5000, 800));
        assert_eq!(roomy.len(), 1);
        assert!(!caps.is_empty());
    }

    // -- timing

    fn tp(min_ms: i64, gap_ms: i64) -> CaptionPreset {
        let mut q = preset(20, 2, 6000, min_ms, 800);
        q.gap = t(gap_ms);
        q.style_ref = "s".into();
        q.animation_ref = "a".into();
        q
    }

    fn cap(a: i64, b: i64) -> Caption {
        Caption::new(strs(&["x"]), TimeRange::from_end(t(a), t(b)), Id::fixed(1), Id::fixed(2), 0..1, "s", "a")
    }

    fn ranges(c: &[Caption]) -> Vec<[i64; 2]> {
        let ms = |x: Time| x.value() * 1000 / x.timescale();
        c.iter().map(|c| [ms(c.range.start), ms(c.range.end())]).collect()
    }

    #[test]
    fn short_caption_is_extended_into_the_silence_after_it() {
        let r = CaptionSegmenter::apply_timing(&[cap(0, 300), cap(3000, 3200)], &tp(1000, 0));
        assert_eq!(ranges(&r), [[0, 1000], [3000, 4000]]);
    }

    #[test]
    fn extension_stops_at_the_next_caption_minus_gap() {
        let r = CaptionSegmenter::apply_timing(&[cap(0, 300), cap(700, 900)], &tp(1000, 100));
        assert_eq!(ranges(&r)[0], [0, 600]); // wanted 1000, next starts at 700, 100 ms gap
        assert_eq!(ranges(&r)[1], [700, 1700]);
    }

    #[test]
    fn gap_shortens_an_end_that_touches_the_next() {
        let r = CaptionSegmenter::apply_timing(&[cap(0, 1000), cap(1000, 2000)], &tp(0, 100));
        assert_eq!(ranges(&r), [[0, 900], [1000, 2000]]);
    }

    #[test]
    fn gap_never_empties_a_caption() {
        let r = CaptionSegmenter::apply_timing(&[cap(0, 50), cap(60, 2000)], &tp(0, 100));
        assert_eq!(ranges(&r)[0], [0, 50]); // would become empty: left alone
    }

    #[test]
    fn nothing_changes_without_min_duration_and_gap() {
        let c = [cap(0, 300), cap(300, 600)];
        assert_eq!(CaptionSegmenter::apply_timing(&c, &tp(0, 0)), c);
    }

    /// The acceptance case: 0.3 s caption, then 2 s of silence.
    #[test]
    fn a_short_caption_before_a_pause_is_extended() {
        let r = CaptionSegmenter::apply_timing(&[cap(0, 300), cap(2300, 3000)], &tp(1000, 0));
        assert_eq!(r[0].range, TimeRange::from_end(t(0), t(1000)));
        assert!(r[0].range.end() <= r[1].range.start);
    }

    #[test]
    fn the_one_line_preset_yields_one_line() {
        let words: Vec<TranscriptWord> = (0..14).map(|i| w(&format!("word{i}"), i * 300, i * 300 + 250)).collect();
        let tr = transcript(words);
        let one = CaptionPresetOptions { lines: Some(1), ..Default::default() };
        let caps = CaptionSegmenter::segment(&tr, &CaptionPreset::standard().with(&one));
        assert!(!caps.is_empty() && caps.iter().all(|c| c.lines.len() == 1));
        assert!(CaptionSegmenter::segment(&tr, &CaptionPreset::short_video()).iter().all(|c| c.lines.len() == 1));
    }

    #[test]
    fn segments_carry_their_word_timings() {
        let caps =
            CaptionSegmenter::segment(&transcript(vec![w("a", 0, 200), w("b", 300, 500)]), &CaptionPreset::standard());
        assert_eq!(caps.len(), 1);
        assert_eq!(caps[0].words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        assert_eq!(caps[0].words[1].range, TimeRange::from_end(t(300), t(500)));
    }

    /// Pseudo-random sorted, non-overlapping captions: after the timing pass nothing overlaps, the order and every start
    /// are unchanged, and a caption reaches the minimum whenever the silence after it allows.
    #[test]
    fn timing_never_overlaps_and_keeps_order() {
        let mut seed = 0x2545_F491_4F6C_DD1Du64;
        let mut next = |lo: i64, hi: i64| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            lo + (seed % (hi - lo + 1) as u64) as i64
        };
        for _ in 0..500 {
            let mut caps = Vec::new();
            let mut cursor = 0;
            for _ in 0..next(1, 8) {
                cursor += next(0, 2500);
                let len = next(20, 1500);
                caps.push(cap(cursor, cursor + len));
                cursor += len;
            }
            let (min_ms, gap_ms) = (next(0, 2000), next(0, 300));
            let pr = tp(min_ms, gap_ms);
            let out = CaptionSegmenter::apply_timing(&caps, &pr);
            assert_eq!(out.len(), caps.len());
            for i in 0..out.len() {
                assert_eq!(out[i].range.start, caps[i].range.start);
                assert!(!out[i].range.is_empty());
                if i + 1 < out.len() {
                    assert!(out[i].range.end() <= out[i + 1].range.start);
                }
                let room =
                    if i + 1 < out.len() { out[i + 1].range.start - pr.gap - out[i].range.start } else { t(min_ms) };
                if room >= t(min_ms) {
                    assert!(out[i].range.duration >= t(min_ms) || out[i].range.duration >= caps[i].range.duration);
                }
            }
        }
    }

    // -- short-video mode

    /// A speech of ~108 words/min, mixed lengths, tiny words, German compounds, pauses.
    fn long_transcript() -> Transcript {
        let vocab = [
            "Ich",
            "habe",
            "heute",
            "ein",
            "neues",
            "Video",
            "geschnitten",
            "und",
            "es",
            "ist",
            "a",
            "Geschwindigkeitsbegrenzung",
            "Bildschirmaufnahme",
            "so",
            "schnell",
            "wie",
            "nie",
            "Zusammenarbeit",
            "ja,",
            "Wahnsinn!",
            "Kaffeemaschinenreiniger",
            "du",
            "ok",
        ];
        let mut words = Vec::new();
        let mut ms = 0i64;
        for i in 0..108i64 {
            let text = vocab[((i * 7 + i / 5) as usize) % vocab.len()];
            // Short words are spoken fast (0.11 to 0.17 s) and often run straight into the next one.
            let n = text.chars().count() as i64;
            let dur = if n <= 3 { 110 + (i % 4) * 20 } else { 400 + n * 12 };
            words.push(w(text, ms, ms + dur));
            ms += dur
                + if i % 9 == 8 {
                    700
                } else if i % 3 == 0 {
                    0
                } else {
                    60
                };
        }
        transcript(words)
    }

    fn covered(caps: &[Caption]) -> BTreeSet<usize> {
        caps.iter().flat_map(|c| c.word_indices.clone()).collect()
    }

    fn timed(tr: &Transcript, pr: &CaptionPreset) -> Vec<Caption> {
        CaptionSegmenter::apply_timing(&CaptionSegmenter::segment(tr, pr), pr)
    }

    #[test]
    fn long_transcript_meets_acceptance() {
        let tr = long_transcript();
        let pr = CaptionPreset::short_video();
        let caps = timed(&tr, &pr);
        assert!(!caps.is_empty());
        for c in &caps {
            assert!(c.range.end() - c.range.start >= t(200), "caption {:?} too short", c.lines);
            // words are never split; only a single word may be longer than a line
            assert!(
                c.lines.iter().all(|l| l.chars().count() <= 11 || !l.contains(' ')),
                "caption {:?} too long",
                c.lines
            );
        }
        for (a, b) in caps.iter().zip(caps.iter().skip(1)) {
            assert!(a.range.end() <= b.range.start);
        }
        assert_eq!(covered(&caps), (0..tr.words.len()).collect::<BTreeSet<_>>());
        let joined = caps.iter().map(|c| c.lines.join(" ")).collect::<Vec<_>>().join(" ");
        assert_eq!(joined, tr.text());
    }

    #[test]
    fn one_word_per_caption_when_timing_allows() {
        let tr = transcript(vec![w("Hallo", 0, 500), w("Welt", 600, 1100), w("heute", 1200, 1700)]);
        let caps = CaptionSegmenter::segment(&tr, &CaptionPreset::short_video());
        assert_eq!(lines_of(&caps), [strs(&["Hallo"]), strs(&["Welt"]), strs(&["heute"])]);
    }

    #[test]
    fn long_word_stays_whole() {
        let tr = transcript(vec![w("Geschwindigkeitsbegrenzung", 0, 2600)]);
        let caps = CaptionSegmenter::segment(&tr, &CaptionPreset::short_video());
        assert_eq!(lines_of(&caps), [strs(&["Geschwindigkeitsbegrenzung"])]);
        assert_eq!(caps[0].range, TimeRange::from_end(t(0), t(2600)));
    }

    #[test]
    fn no_caption_ever_carries_a_piece_of_a_word() {
        let tr = long_transcript();
        let words: BTreeSet<&str> = tr.words.iter().map(|w| w.text.as_str()).collect();
        for pr in [CaptionPreset::short_video(), CaptionPreset::standard()] {
            for c in timed(&tr, &pr) {
                for l in &c.lines {
                    for piece in l.split(' ').filter(|p| !p.is_empty()) {
                        assert!(words.contains(piece), "{piece}");
                    }
                }
            }
        }
    }

    #[test]
    fn dash_joins_the_previous_word_instead_of_standing_alone() {
        let tr = transcript(vec![
            w("ausprobieren", 0, 600),
            w("\u{2013}", 600, 650),
            w("das", 700, 900),
            w("Rennen", 950, 1400),
        ]);
        let caps = CaptionSegmenter::segment(&tr, &CaptionPreset::short_video());
        assert_eq!(lines_of(&caps), [strs(&["ausprobieren \u{2013}"]), strs(&["das"]), strs(&["Rennen"])]);
        assert_eq!(caps[0].words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["ausprobieren", "\u{2013}"]);
    }

    #[test]
    fn too_short_word_between_tight_neighbours_is_not_left_under_minimum() {
        let tr = transcript(vec![w("Hallo", 0, 500), w("a", 500, 600), w("Welt", 600, 1100)]);
        let caps = timed(&tr, &CaptionPreset::short_video());
        assert!(caps.iter().all(|c| c.range.end() - c.range.start >= t(200)));
        assert_eq!(covered(&caps), BTreeSet::from([0, 1, 2]));
    }

    fn all_valid(caps: &[Caption], words: usize) -> bool {
        covered(caps) == (0..words).collect::<BTreeSet<_>>()
            && caps.iter().all(|c| {
                c.range.end() - c.range.start >= t(200)
                    && c.lines.iter().all(|l| l.chars().count() <= 11 || !l.contains(' '))
            })
            && caps.iter().zip(caps.iter().skip(1)).all(|(a, b)| a.range.end() <= b.range.start)
    }

    #[test]
    fn last_short_word_extends_into_trailing_time() {
        let tr = transcript(vec![w("Hallo", 0, 500), w("ja", 600, 650)]);
        let caps = CaptionSegmenter::segment(&tr, &CaptionPreset::short_video());
        assert!(all_valid(&caps, 2));
        assert_eq!(caps.last().map(|c| c.range.start), Some(t(600)));
    }

    #[test]
    fn two_tiny_neighbours_that_cannot_merge_keep_the_minimum() {
        let tr = transcript(vec![w("Hello", 0, 50), w("wonderful", 50, 100)]);
        let caps = CaptionSegmenter::segment(&tr, &CaptionPreset::short_video());
        assert_eq!(caps.len(), 2);
        assert!(all_valid(&caps, 2));
        let cascade =
            transcript(vec![w("Hello", 0, 50), w("wonderful", 50, 100), w("amazing", 100, 150), w("stuff", 150, 200)]);
        assert!(all_valid(&CaptionSegmenter::segment(&cascade, &CaptionPreset::short_video()), 4));
    }
}

#[cfg(test)]
mod words_tests {
    use super::*;
    use crate::transcript::test_support::*;

    #[test]
    fn a_word_cap_above_one_groups_that_many_words() {
        let tr =
            transcript(vec![w("a", 0, 200), w("b", 250, 450), w("c", 500, 700), w("d", 750, 950), w("e", 1000, 1200)]);
        let mut pr = CaptionPreset::short_video();
        pr.max_words_per_caption = Some(2);
        pr.max_chars_per_line = 40;
        let lines: Vec<Vec<String>> = CaptionSegmenter::segment(&tr, &pr).into_iter().map(|c| c.lines).collect();
        assert_eq!(lines, vec![vec!["a b".to_string()], vec!["c d".to_string()], vec!["e".to_string()]]);
    }
}

#[cfg(test)]
mod hang_tests {
    use super::*;
    use crate::transcript::test_support::*;

    fn ends(pr: &CaptionPreset) -> Vec<(Time, Time)> {
        let tr = transcript(vec![
            w("Das", 4000, 4900),
            w("27", 5000, 6140),
            w(".", 8600, 8670),
            w("ist", 8700, 8900),
            w("gut", 8950, 9300),
        ]);
        CaptionSegmenter::apply_timing(&CaptionSegmenter::segment(&tr, pr), pr)
            .iter()
            .map(|c| (c.range.start, c.range.end()))
            .collect()
    }

    /// "27" (5.00-6.14 s) with a mark timed at 8.6-8.67 s: the caption ends 0.4 s after the word, not at 8.67 s.
    #[test]
    fn a_late_punctuation_mark_does_not_hold_a_caption_through_a_pause() {
        for pr in [CaptionPreset::short_video(), CaptionPreset::standard()] {
            for (s, e) in ends(&pr) {
                if s == t(5000) || s == t(4000) {
                    assert!(e <= t(6540), "caption {s:?} holds until {e:?}");
                }
            }
        }
    }
}
