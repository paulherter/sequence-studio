// Swift: CaptionTidy.swift, CaptionTranslation.swift
//! Fast-captions timing pass and translated caption items. Pure logic, no UI.

use crate::caption_item::char_count;
use crate::caption_words::relative_words;
use sq_core_model::{CaptionItem, CaptionWord};
use sq_core_time::{IdSource, Time, TimeRange, word_segmentation};

/// Limits of the one-click "Tidy Captions" pass.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionTidyOptions {
    /// Most words in one caption.
    pub max_words: usize,
    /// Longest a caption stays on screen before it is split.
    pub max_duration: Time,
    /// A shorter caption grows into the silence after it (never over the next caption).
    pub min_duration: Time,
    /// A silence shorter than this between two captions is closed (the earlier caption stays until the next starts).
    pub bridge_gaps_under: Time,
    /// Silence kept between two captions that were bridged or touch (zero: none).
    pub gap: Time,
}

impl CaptionTidyOptions {
    /// Swift `init`: `max_words` is at least 1.
    pub fn new(max_words: usize, max_duration: Time, min_duration: Time, bridge_gaps_under: Time, gap: Time) -> Self {
        CaptionTidyOptions { max_words: max_words.max(1), max_duration, min_duration, bridge_gaps_under, gap }
    }

    /// Short punchy chunks: 3 words, 1.5 s at most, 1/3 s at least.
    pub fn tik_tok() -> Self {
        Self::new(3, Time::new(3, 2), Time::new(1, 3), Time::new(1, 4), Time::ZERO)
    }
}

struct Work {
    item: CaptionItem,
    range: TimeRange,
    words: Vec<CaptionWord>, // absolute timeline time
}

/// Namespace of the tidy pass.
pub enum CaptionTidy {}

impl CaptionTidy {
    /// Tidies the captions of one track. Empty captions are dropped; the first chunk of a caption keeps its id, style,
    /// animation and position. The result is sorted, frame-aligned, non-empty and never overlaps.
    pub fn tidy(items: &[CaptionItem], o: &CaptionTidyOptions, fd: Time, ids: &mut dyn IdSource) -> Vec<CaptionItem> {
        let mut work: Vec<Work> = Vec::new();
        let mut sorted = items.to_vec();
        sorted.sort_by_key(|i| i.range.start);
        for item in &sorted {
            work.extend(chunks(item, o, ids));
        }
        if work.is_empty() {
            return Vec::new();
        }
        // 1. Overlaps (input sorted by start): the earlier caption yields; a caption that starts with the one before it is pushed.
        for i in 0..work.len() - 1 {
            let next = work[i + 1].range;
            if next.start >= work[i].range.end() {
                continue;
            }
            if next.start > work[i].range.start {
                work[i].range = TimeRange::from_end(work[i].range.start, next.start);
            } else {
                let s = work[i].range.end();
                work[i + 1].range = TimeRange::from_end(s, next.end().max(s + fd));
            }
        }
        // 2. Minimum duration: grow into the silence, never over the next caption.
        for i in 0..work.len() {
            if work[i].range.duration >= o.min_duration {
                continue;
            }
            let mut e = work[i].range.start + o.min_duration;
            if i + 1 < work.len() {
                e = e.min(work[i + 1].range.start - o.gap);
            }
            if e > work[i].range.end() {
                work[i].range = TimeRange::from_end(work[i].range.start, e);
            }
        }
        // 3. Close small gaps; keep `gap` where captions touch.
        for i in 0..work.len() - 1 {
            let (r, next) = (work[i].range, work[i + 1].range.start);
            if !(next - r.end() < o.bridge_gaps_under || next - r.end() < o.gap) {
                continue;
            }
            let target = next - o.gap;
            if target > r.start && target != r.end() {
                work[i].range = TimeRange::from_end(r.start, target);
            }
        }
        // 4. Frame grid, then one forward sweep so rounding can never create an overlap or an empty caption.
        let mut prev_end = Time::ZERO;
        for w in work.iter_mut() {
            let r = w.range;
            let s = r.start.snapped(fd).max(prev_end);
            let e = r.end().snapped(fd).max(s + fd);
            w.range = TimeRange::from_end(s, e);
            prev_end = e;
        }
        work.into_iter()
            .map(|w| {
                let mut item = w.item;
                item.range = w.range;
                item.words = relative_words(&w.words, &w.range);
                item
            })
            .collect()
    }
}

fn chunks(item: &CaptionItem, o: &CaptionTidyOptions, ids: &mut dyn IdSource) -> Vec<Work> {
    let words = item.effective_words();
    if words.is_empty() {
        return Vec::new();
    }
    let mut groups: Vec<Vec<CaptionWord>> = vec![Vec::new()];
    for w in words {
        let current = groups.last().map(|g| g.as_slice()).unwrap_or(&[]);
        if let (Some(first), Some(last)) = (current.first(), current.last()) {
            let count = current.len();
            if count >= o.max_words
                || w.range.end() - first.range.start > o.max_duration
                || ends_sentence(&last.text)
                || (count >= 2 && ends_clause(&last.text))
            {
                groups.push(Vec::new());
            }
        }
        if let Some(g) = groups.last_mut() {
            g.push(w);
        }
    }
    groups
        .into_iter()
        .enumerate()
        .map(|(i, g)| {
            let mut c = item.clone();
            if i > 0 {
                c.id = ids.next_id();
            }
            let texts: Vec<&str> = g.iter().map(|w| w.text.as_str()).collect();
            c.lines = vec![word_segmentation::join(&texts)];
            let s = g[0].range.start;
            let e = g[g.len() - 1].range.end().max(s);
            Work { item: c, range: TimeRange::from_end(s, e), words: g }
        })
        .collect()
}

const CLOSERS: &str = "\"'\u{201D}\u{201C}\u{BB}\u{AB})]";

fn last_visible(text: &str) -> Option<char> {
    text.chars().rev().find(|c| !CLOSERS.contains(*c))
}

fn ends_sentence(text: &str) -> bool {
    matches!(last_visible(text), Some('.' | '!' | '?' | '\u{2026}'))
}

fn ends_clause(text: &str) -> bool {
    matches!(last_visible(text), Some(',' | ';' | ':'))
}

/// Turns translated texts back into captions: the translated track has the same timings and look as the source.
pub enum CaptionTranslation {}

impl CaptionTranslation {
    /// New caption items with the same ranges, style, animation and position as `source`, one per source caption,
    /// carrying `texts[i]` as their text. A text that is longer than `max_chars_per_line` is broken into at most two
    /// balanced lines. Word timings are not carried over (the words differ): the karaoke highlight spreads over the new
    /// words by length. Captions whose translated text is empty keep the source text. `None` when the counts differ.
    pub fn translated_items(
        source: &[CaptionItem],
        texts: &[String],
        max_chars_per_line: usize,
        ids: &mut dyn IdSource,
    ) -> Option<Vec<CaptionItem>> {
        if source.len() != texts.len() {
            return None;
        }
        Some(
            source
                .iter()
                .zip(texts)
                .map(|(item, text)| {
                    let mut c = item.clone();
                    c.id = ids.next_id();
                    let words = word_segmentation::words(text);
                    c.lines = if words.is_empty() {
                        item.lines.clone()
                    } else {
                        Self::balanced_lines(&words, max_chars_per_line)
                    };
                    c.words = Vec::new();
                    c
                })
                .collect(),
        )
    }

    /// One line when it fits, else two lines broken at the word boundary closest to the middle.
    pub(crate) fn balanced_lines(words: &[String], max_chars: usize) -> Vec<String> {
        let whole = word_segmentation::join(words);
        if char_count(&whole) as usize <= max_chars || words.len() <= 1 {
            return vec![whole];
        }
        let (mut best, mut best_diff) = (1, i64::MAX);
        for k in 1..words.len() {
            let a = char_count(&word_segmentation::join(&words[..k]));
            let b = char_count(&word_segmentation::join(&words[k..]));
            if (a - b).abs() < best_diff {
                best = k;
                best_diff = (a - b).abs();
            }
        }
        vec![word_segmentation::join(&words[..best]), word_segmentation::join(&words[best..])]
    }

    /// Track name for a translation: "Captions 1 (de)".
    pub fn track_name(source: &str, language: &str) -> String {
        let base = if source.is_empty() { "Captions" } else { source };
        format!("{base} ({language})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_item::CaptionItemExt;
    use crate::caption_item::tests::{item, range, t};
    use sq_core_model::CaptionPosition;
    use sq_core_time::SequentialIds;

    const MS: Time = Time::new(1, 1000);

    /// A caption with one word per `step` ms, timed (word times relative to the start, like the segmenter writes them).
    fn spoken(text: &str, start: i64, step: i64, style: &str) -> CaptionItem {
        let toks: Vec<&str> = text.split(' ').collect();
        let words: Vec<CaptionWord> = toks
            .iter()
            .enumerate()
            .map(|(i, w)| CaptionWord {
                text: w.to_string(),
                range: range(i as i64 * step, i as i64 * step + step - 50),
                confidence: None,
            })
            .collect();
        let end = start + toks.len() as i64 * step - 50;
        let mut c = item(&[text], range(start, end));
        c.style_ref = style.to_string();
        c.animation_ref = "a".to_string();
        c.words = words;
        c
    }
    fn texts(items: &[CaptionItem]) -> Vec<String> {
        items.iter().map(|i| i.text()).collect()
    }
    fn opts(words: usize, max_ms: i64, min_ms: i64, bridge_ms: i64, gap_ms: i64) -> CaptionTidyOptions {
        CaptionTidyOptions::new(words, t(max_ms), t(min_ms), t(bridge_ms), t(gap_ms))
    }
    fn plain() -> CaptionTidyOptions {
        opts(3, 10_000, 0, 0, 0)
    }
    fn tidy(items: &[CaptionItem], o: &CaptionTidyOptions, fd: Time) -> Vec<CaptionItem> {
        CaptionTidy::tidy(items, o, fd, &mut SequentialIds::default())
    }

    #[test]
    fn long_caption_splits_into_short_chunks() {
        let r = tidy(&[spoken("one two three four five six seven eight", 0, 300, "s")], &plain(), MS);
        assert_eq!(texts(&r), vec!["one two three", "four five six", "seven eight"]);
    }

    #[test]
    fn chunk_range_and_word_timings_follow_the_speech() {
        let r = tidy(&[spoken("one two three four", 1000, 300, "s")], &opts(2, 10_000, 0, 0, 0), MS);
        assert_eq!(r.len(), 2);
        assert_eq!(r[1].range, range(1600, 2150)); // "three" starts at 1600, "four" ends at 2150
        assert!(r[1].has_word_timings());
        assert_eq!(r[1].effective_words().iter().map(|w| w.range.start).collect::<Vec<_>>(), vec![t(1600), t(1900)]);
    }

    #[test]
    fn sentence_end_and_max_duration_break_the_chunk() {
        let r = tidy(&[spoken("Hi there. How are you", 0, 300, "s")], &plain(), MS);
        assert_eq!(texts(&r), vec!["Hi there.", "How are you"]);
        let r = tidy(&[spoken("a b c d", 0, 600, "s")], &opts(4, 1_300, 0, 0, 0), MS);
        assert_eq!(texts(&r), vec!["a b", "c d"]);
    }

    #[test]
    fn style_and_animation_are_kept_and_the_first_chunk_keeps_the_id() {
        let it = spoken("one two three four", 0, 300, "bold");
        let r = tidy(std::slice::from_ref(&it), &opts(2, 10_000, 0, 0, 0), MS);
        assert!(r.iter().all(|c| c.style_ref == "bold" && c.animation_ref == "a"));
        assert_eq!(r[0].id, it.id);
        assert_ne!(r[1].id, it.id);
    }

    #[test]
    fn overlaps_are_removed() {
        let (a, b) = (item(&["first"], range(0, 1500)), item(&["second"], range(1000, 2000)));
        let r = tidy(&[b, a], &plain(), MS);
        assert_eq!(r.iter().map(|c| c.range).collect::<Vec<_>>(), vec![range(0, 1000), range(1000, 2000)]);
    }

    #[test]
    fn small_gaps_are_bridged_large_ones_stay() {
        let items = [item(&["a"], range(0, 500)), item(&["b"], range(600, 1000)), item(&["c"], range(3000, 3500))];
        let r = tidy(&items, &opts(3, 10_000, 0, 250, 0), MS);
        assert_eq!(
            r.iter().map(|c| c.range).collect::<Vec<_>>(),
            vec![range(0, 600), range(600, 1000), range(3000, 3500)]
        );
    }

    #[test]
    fn gap_is_kept_between_bridged_captions() {
        let items = [item(&["a"], range(0, 500)), item(&["b"], range(600, 1000))];
        let r = tidy(&items, &opts(3, 10_000, 0, 250, 40), MS);
        assert_eq!(r[0].range, range(0, 560));
    }

    #[test]
    fn short_caption_grows_into_the_silence_but_not_over_the_next() {
        let items = [item(&["a"], range(0, 200)), item(&["b"], range(700, 800)), item(&["c"], range(5000, 5100))];
        let r = tidy(&items, &opts(3, 10_000, 500, 0, 0), MS);
        assert_eq!(
            r.iter().map(|c| c.range).collect::<Vec<_>>(),
            vec![range(0, 500), range(700, 1200), range(5000, 5500)]
        );
    }

    #[test]
    fn untimed_captions_split_too_and_empty_ones_are_dropped() {
        let it = item(&["alpha beta gamma delta"], range(0, 4000));
        let r = tidy(&[it], &opts(2, 10_000, 0, 0, 0), MS);
        assert_eq!(texts(&r), vec!["alpha beta", "gamma delta"]);
        assert!(r[0].range.end() <= r[1].range.start);
        let r = tidy(&[item(&[" "], range(0, 500)), item(&["x"], range(600, 900))], &plain(), MS);
        assert_eq!(texts(&r), vec!["x"]);
    }

    #[test]
    fn result_is_frame_aligned_sorted_and_never_overlaps_and_tidying_twice_changes_nothing() {
        let fd = Time::new(1001, 30000);
        let items = [spoken("one two three four five six", 130, 300, "s"), spoken("next one here", 2300, 300, "s")];
        let r = tidy(&items, &CaptionTidyOptions::tik_tok(), fd);
        for c in &r {
            assert!(c.range.start == c.range.start.snapped(fd) && c.range.end() == c.range.end().snapped(fd));
            assert!(!c.range.is_empty());
        }
        for w in r.windows(2) {
            assert!(w[0].range.end() <= w[1].range.start);
        }
        let fd = Time::new(1, 30);
        let once =
            tidy(&[spoken("one two three four five six seven", 0, 300, "s")], &CaptionTidyOptions::tik_tok(), fd);
        assert_eq!(tidy(&once, &CaptionTidyOptions::tik_tok(), fd), once);
    }

    fn translated_source(text: &str, a: i64, b: i64) -> CaptionItem {
        let mut c = item(&[text], range(a, b));
        c.style_ref = "bold".to_string();
        c.animation_ref = "pop".to_string();
        c.style_overridden = true;
        c.words = vec![CaptionWord { text: "x".to_string(), range: range(0, 100), confidence: None }];
        c.position = serde_json::from_str::<CaptionPosition>(r#"{"vertical":"top"}"#).ok();
        assert!(c.position.is_some());
        c
    }
    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn translation_keeps_timings_and_look_and_changes_text() {
        let src = [translated_source("Hello world", 0, 1000), translated_source("Bye", 1500, 2000)];
        let out = CaptionTranslation::translated_items(
            &src,
            &s(&["Hallo Welt", "Tsch\u{FC}ss"]),
            32,
            &mut SequentialIds::default(),
        );
        let Some(out) = out else { panic!("translation refused") };
        assert_eq!(texts(&out), vec!["Hallo Welt", "Tsch\u{FC}ss"]);
        assert_eq!(out.iter().map(|c| c.range).collect::<Vec<_>>(), src.iter().map(|c| c.range).collect::<Vec<_>>());
        assert!(
            out.iter()
                .all(|c| c.style_ref == "bold" && c.animation_ref == "pop" && c.style_overridden && c.words.is_empty())
        );
        assert_eq!(
            out.iter().map(|c| c.position).collect::<Vec<_>>(),
            src.iter().map(|c| c.position).collect::<Vec<_>>()
        );
        assert!(out.iter().all(|c| src.iter().all(|o| o.id != c.id)));
    }

    #[test]
    fn translation_count_mismatch_empty_text_and_long_text() {
        let mut ids = SequentialIds::default();
        assert!(CaptionTranslation::translated_items(&[translated_source("a", 0, 1)], &[], 32, &mut ids).is_none());
        let out = CaptionTranslation::translated_items(&[translated_source("keep", 0, 500)], &s(&["  "]), 32, &mut ids);
        assert_eq!(out.map(|o| o[0].text()), Some("keep".to_string()));
        let out = CaptionTranslation::translated_items(
            &[translated_source("x", 0, 500)],
            &s(&["Das ist ein ziemlich langer Untertitel mit vielen W\u{F6}rtern"]),
            30,
            &mut ids,
        );
        assert_eq!(
            out.map(|o| o[0].lines.clone()),
            Some(s(&["Das ist ein ziemlich langer", "Untertitel mit vielen W\u{F6}rtern"]))
        );
    }

    #[test]
    fn track_name_carries_the_language() {
        assert_eq!(CaptionTranslation::track_name("Captions 1", "de"), "Captions 1 (de)");
        assert_eq!(CaptionTranslation::track_name("", "fr"), "Captions (fr)");
    }
}
