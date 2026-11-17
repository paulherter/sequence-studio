// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Captions.swift, Captions+Karaoke.swift (saved types, moved down; editing, word timing and queries: later tasks)

use crate::CaptionPosition;
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{Id, Time, TimeRange, word_segmentation};

/// One spoken word of a caption. Inside a `CaptionItem` the range is relative to the item's start.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CaptionWord {
    /// The word.
    pub text: String,
    /// Where it is spoken.
    pub range: TimeRange,
    /// How sure the recognizer was, 0...1; `None` = unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f32>,
}

/// The karaoke word highlight: the word being spoken is drawn in the highlight color (plain sRGB).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KaraokeStyle {
    /// Red.
    pub red: f64,
    /// Green.
    pub green: f64,
    /// Blue.
    pub blue: f64,
    /// Words already spoken stay in the highlight color.
    pub keep_spoken: bool,
}

/// One caption on a caption track. Older files lack the override flag and the word timings.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionItem {
    /// Identity.
    pub id: Id,
    /// Display lines.
    pub lines: Vec<String>,
    /// Timeline position (half-open).
    pub range: TimeRange,
    /// The style this caption is drawn with.
    #[serde(default)]
    pub style_ref: String,
    /// The animation preset.
    #[serde(default)]
    pub animation_ref: String,
    /// The caption got its own style: a change of the track style leaves it alone.
    #[serde(default)]
    pub style_overridden: bool,
    /// Word timings relative to the item start; empty = spread over the range.
    #[serde(default)]
    pub words: Vec<CaptionWord>,
    /// Own position; `None` follows the project's kit position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<CaptionPosition>,
}

fn yes() -> bool {
    true
}

/// Items sorted by start, as the Swift initializer keeps them.
fn sorted_items<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<CaptionItem>, D::Error> {
    let mut items = Vec::<CaptionItem>::deserialize(d)?;
    items.sort_by_key(|i| i.range.start);
    Ok(items)
}

/// A caption track: sorted items. Sits above the video tracks; sync-locked like a clip track.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionTrack {
    /// Identity.
    pub id: Id,
    /// Shown name.
    #[serde(default)]
    pub name: String,
    /// Locked tracks refuse edits.
    #[serde(default)]
    pub is_locked: bool,
    /// Shifts together with ripple edits made on other tracks (unless locked).
    #[serde(default = "yes")]
    pub sync_lock: bool,
    /// Hidden tracks produce no captions.
    #[serde(default = "yes")]
    pub is_visible: bool,
    /// Style of the track.
    #[serde(default)]
    pub style_ref: String,
    /// Animation preset of the track.
    #[serde(default)]
    pub animation_ref: String,
    /// Karaoke word highlight; `None` = off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub karaoke: Option<KaraokeStyle>,
    /// The Look the track was last given.
    #[serde(rename = "lookID", default, skip_serializing_if = "Option::is_none")]
    pub look_id: Option<String>,
    /// Sorted by start; read with `items()`.
    #[serde(default, deserialize_with = "sorted_items")]
    items: Vec<CaptionItem>,
}

impl CaptionItem {
    /// The words of the text, across all lines.
    pub fn tokens(&self) -> Vec<String> {
        self.lines.iter().flat_map(|l| word_segmentation::words(l)).collect()
    }

    /// True when the stored word timings still match the text (editing a word keeps them, adding or removing one does not).
    pub fn has_word_timings(&self) -> bool {
        !self.words.is_empty() && self.words.len() == self.tokens().len()
    }

    /// One timed word per word of the text (absolute timeline time, clamped into the caption): the stored timings while
    /// they match, else the range spread over the words by their length (so captions typed by hand highlight too).
    pub fn effective_words(&self) -> Vec<CaptionWord> {
        let toks = self.tokens();
        if toks.is_empty() {
            return Vec::new();
        }
        let range = self.range;
        if self.has_word_timings() {
            let clamp = |t: Time| t.max(range.start).min(range.end());
            return toks
                .into_iter()
                .zip(&self.words)
                .map(|(tok, w)| {
                    let a = clamp(range.start + w.range.start);
                    let b = clamp(range.start + w.range.end()).max(a);
                    let confidence = if w.text == tok { w.confidence } else { None };
                    CaptionWord { text: tok, range: TimeRange::from_end(a, b), confidence }
                })
                .collect();
        }
        let len = |t: &str| t.chars().count().max(1) as i64;
        let total: i64 = toks.iter().map(|t| len(t)).sum();
        let d = range.duration;
        // Huge timescales round (see `Time::reducing`): clamp so a word never ends before it starts.
        let at = |n: i64| {
            if n == total {
                range.end()
            } else {
                (range.start + Time::scaled_int(d, n, total)).max(range.start).min(range.end())
            }
        };
        let mut cum = 0;
        toks.into_iter()
            .map(|tok| {
                let a = cum;
                cum += len(&tok);
                let s = at(a);
                CaptionWord { text: tok, range: TimeRange::from_end(s, at(cum).max(s)), confidence: None }
            })
            .collect()
    }

    /// After a ripple: the word times of `old` pass through the same time map as the material, and are stored relative to
    /// the (already set) new range. Items without usable timings are left alone.
    fn map_words(&mut self, old: &CaptionItem, f: impl Fn(Time) -> Time) {
        if !old.has_word_timings() {
            return;
        }
        let moved: Vec<CaptionWord> = old
            .effective_words()
            .into_iter()
            .map(|w| CaptionWord { range: TimeRange::from_end(f(w.range.start), f(w.range.end())), ..w })
            .collect();
        self.words = CaptionTrack::relative_words(&moved, self.range);
    }
}

impl CaptionTrack {
    /// Items sorted by start.
    pub fn items(&self) -> &[CaptionItem] {
        &self.items
    }

    /// Hands the items to the word operations (`sq-core-audio` `CaptionItemsExt`). The body must keep them sorted and
    /// non-overlapping.
    #[doc(hidden)]
    pub fn with_items<R>(&mut self, body: impl FnOnce(&mut Vec<CaptionItem>) -> R) -> R {
        body(&mut self.items)
    }

    /// Takes part in ripple edits made on other tracks.
    pub fn follows_ripple(&self) -> bool {
        self.sync_lock && !self.is_locked
    }

    /// Absolute words made relative to `range.start`, clamped into the range.
    fn relative_words(words: &[CaptionWord], range: TimeRange) -> Vec<CaptionWord> {
        words
            .iter()
            .map(|w| {
                let a = w.range.start.max(range.start).min(range.end());
                let b = w.range.end().max(a).min(range.end());
                CaptionWord {
                    text: w.text.clone(),
                    range: TimeRange::from_end(a - range.start, b - range.start),
                    confidence: w.confidence,
                }
            })
            .collect()
    }

    /// Ripple-closes `span`: later items move left; items inside collapse to its start, and an item that collapses to
    /// nothing is dropped.
    #[doc(hidden)]
    pub fn close_span(&mut self, span: TimeRange) {
        if span.is_empty() {
            return;
        }
        let f = |t: Time| {
            if t <= span.start {
                t
            } else if t >= span.end() {
                t - span.duration
            } else {
                span.start
            }
        };
        self.remap(f);
    }

    /// `close_span` for a ripple that closes its span as a side effect (Fast Cut keeps V1 gapless whatever is on the
    /// captions): a caption the span covers completely is not cut out but pulled in to the span start with its duration,
    /// so no edit deletes one. Where that makes captions overlap, the earlier one yields to a later one that starts after
    /// it, and one that starts with the one before it stacks behind it (the rule of the tidy pass); nothing vanishes.
    #[doc(hidden)]
    pub fn close_span_keeping(&mut self, span: TimeRange) {
        if span.is_empty() {
            return;
        }
        let f = |t: Time| {
            if t <= span.start {
                t
            } else if t >= span.end() {
                t - span.duration
            } else {
                span.start
            }
        };
        let retimed = |item: &CaptionItem, range: TimeRange| {
            let mut c = item.clone();
            c.range = range;
            c.map_words(item, |t| t - item.range.start + range.start);
            c
        };
        let mut items: Vec<CaptionItem> = self
            .items
            .iter()
            .map(|item| {
                let covered = item.range.start >= span.start && item.range.end() <= span.end();
                if covered {
                    return retimed(item, TimeRange::new(span.start, item.range.duration));
                }
                let mut c = item.clone();
                c.range = TimeRange::from_end(f(item.range.start), f(item.range.end()));
                c.map_words(item, f);
                c
            })
            .collect();
        for i in 1..items.len() {
            let (prev, cur) = (items[i - 1].range, items[i].range);
            if cur.start >= prev.end() {
                continue;
            }
            if cur.start > prev.start {
                items[i - 1] = retimed(&items[i - 1], TimeRange::from_end(prev.start, cur.start));
            } else {
                items[i] = retimed(&items[i], TimeRange::new(prev.end(), cur.duration));
            }
        }
        self.items = items;
    }

    /// `close_span` for many spans at once: `f` is their composed point map (`RippleMap::map` of the batch ripple).
    #[doc(hidden)]
    pub fn close_spans(&mut self, f: &dyn Fn(Time) -> Time) {
        self.remap(f);
    }

    /// Ripple-opens a gap of `length` at `pivot`: items starting at or after it move right with their words. An item
    /// that starts before the pivot stays exactly as it is (start, length and words): an insert never stretches or splits
    /// a caption. The Swift app stretched it over the gap (a 1.5 s caption became 5.5 s); decided 2026-11-16 that edits
    /// never distort captions.
    #[doc(hidden)]
    pub fn open_gap(&mut self, pivot: Time, length: Time) {
        if length <= Time::ZERO {
            return;
        }
        let g = |t: Time| if t >= pivot { t + length } else { t };
        self.items = self
            .items
            .iter()
            .map(|item| {
                let mut c = item.clone();
                if item.range.start >= pivot {
                    c.range = TimeRange::new(item.range.start + length, item.range.duration);
                    c.map_words(item, g);
                }
                c
            })
            .collect();
    }

    fn remap(&mut self, f: impl Fn(Time) -> Time) {
        self.items = self
            .items
            .iter()
            .filter_map(|item| {
                let mut c = item.clone();
                let r = TimeRange::from_end(f(item.range.start), f(item.range.end()));
                if r.is_empty() {
                    return None;
                }
                c.range = r;
                c.map_words(item, &f);
                Some(c)
            })
            .collect();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    fn item(id: u8, start: i64) -> serde_json::Value {
        json!({"id": format!("00000000-0000-0000-0000-0000000000{id:02}"), "lines": ["x"],
               "range": {"start": {"value": start, "timescale": 1}, "duration": {"value": 1, "timescale": 1}},
               "styleRef": "", "animationRef": "", "styleOverridden": false, "words": []})
    }

    #[test]
    fn caption_track_round_trips_and_defaults_missing_keys() {
        let full = json!({"id": "00000000-0000-0000-0000-000000000001", "name": "EN", "isLocked": false,
            "syncLock": true, "isVisible": true, "styleRef": "s", "animationRef": "a", "items": [item(2, 0)],
            "karaoke": {"red": 1.0, "green": 0.5, "blue": 0.0, "keepSpoken": true}, "lookID": "look-1"});
        assert_round_trip::<CaptionTrack>(full);
        let t: CaptionTrack = serde_json::from_value(json!({"id": "00000000-0000-0000-0000-000000000001"})).unwrap();
        assert!(t.sync_lock && t.is_visible && !t.is_locked && t.items().is_empty() && t.name.is_empty());
    }

    #[test]
    fn items_are_sorted_by_start_on_read() {
        let t: CaptionTrack = serde_json::from_value(json!({"id": "00000000-0000-0000-0000-000000000001",
            "items": [item(3, 5), item(2, 1)]}))
        .unwrap();
        let starts: Vec<i64> = t.items().iter().map(|i| i.range.start.value()).collect();
        assert_eq!(starts, vec![1, 5]);
    }

    #[test]
    fn old_item_without_flags_words_and_position_reads_with_defaults() {
        let i: CaptionItem = serde_json::from_value(json!({"id": "00000000-0000-0000-0000-000000000002",
            "lines": ["a", "b"], "range": item(2, 0)["range"]}))
        .unwrap();
        assert_eq!((i.style_ref.as_str(), i.style_overridden, i.words.len(), i.position), ("", false, 0, None));
    }

    #[test]
    fn word_confidence_is_written_only_when_known() {
        let range = json!({"start": {"value": 0, "timescale": 1}, "duration": {"value": 1, "timescale": 1}});
        assert_round_trip::<CaptionWord>(json!({"text": "hi", "range": range}));
        assert_round_trip::<CaptionWord>(json!({"text": "hi", "range": range, "confidence": 0.5}));
    }

    fn track(spans: &[(i64, i64)]) -> CaptionTrack {
        let items: Vec<_> = spans
            .iter()
            .enumerate()
            .map(|(n, (a, b))| {
                let mut i = item(n as u8 + 1, *a);
                i["range"]["duration"]["value"] = json!(b - a);
                i
            })
            .collect();
        serde_json::from_value(json!({"id": "00000000-0000-0000-0000-0000000000ff", "items": items})).unwrap()
    }

    fn spans(t: &CaptionTrack) -> Vec<(i64, i64)> {
        t.items().iter().map(|i| (i.range.start.value(), i.range.end().value())).collect()
    }

    fn secs(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(Time::new(a, 1), Time::new(b, 1))
    }

    #[test]
    fn closing_keeping_pulls_a_covered_caption_to_the_span_start_with_its_duration() {
        let mut t = track(&[(0, 2), (6, 8), (12, 14)]);
        t.close_span_keeping(secs(5, 10)); // a 5 s span: (6, 8) lies inside, (12, 14) rides
        assert_eq!(spans(&t), vec![(0, 2), (5, 7), (7, 9)]);
        let mut cut = track(&[(0, 2), (6, 8), (12, 14)]);
        cut.close_span(secs(5, 10));
        assert_eq!(spans(&cut), vec![(0, 2), (7, 9)], "the deliberate delete still cuts it out");
    }

    #[test]
    fn closing_keeping_stacks_captions_that_start_together_and_shortens_the_earlier_one() {
        let mut t = track(&[(5, 7), (6, 8), (9, 10)]); // all inside the span 5..10: pulled to 5, then stacked in order
        t.close_span_keeping(secs(5, 10));
        assert_eq!(spans(&t), vec![(5, 7), (7, 9), (9, 10)]);
        let mut u = track(&[(6, 9), (11, 13)]); // pulled to (5, 8); the rider moves to (6, 8): the earlier one yields
        u.close_span_keeping(secs(5, 10));
        assert_eq!(spans(&u), vec![(5, 6), (6, 8)]);
    }

    #[test]
    fn closing_keeping_moves_the_words_with_a_pulled_in_caption() {
        let mut t = track(&[(6, 8)]);
        t.with_items(|v| {
            let w = |text: &str, a: i64, b: i64| CaptionWord { text: text.into(), range: secs(a, b), confidence: None };
            v[0].words = vec![w("a", 0, 1), w("b", 1, 2)]; // relative to the caption start
        });
        t.close_span_keeping(secs(5, 10));
        let i = &t.items()[0];
        assert_eq!(
            (i.range, i.words.iter().map(|w| w.range).collect::<Vec<_>>()),
            (secs(5, 7), vec![secs(0, 1), secs(1, 2)])
        );
    }

    #[test]
    fn open_gap_moves_later_captions_and_keeps_the_one_under_the_pivot_whole() {
        let mut t: CaptionTrack = serde_json::from_value(json!({"id": "00000000-0000-0000-0000-000000000001",
            "items": [
                {"id": "00000000-0000-0000-0000-000000000011", "lines": ["a b"],
                 "range": {"start": {"value": 1, "timescale": 1}, "duration": {"value": 3, "timescale": 1}},
                 "words": [{"text": "a", "range": {"start": {"value": 1, "timescale": 1}, "duration": {"value": 1, "timescale": 1}}},
                           {"text": "b", "range": {"start": {"value": 3, "timescale": 1}, "duration": {"value": 1, "timescale": 1}}}]},
                item(12, 4), item(13, 8)]}))
        .unwrap();
        let before = t.items()[0].clone();
        t.open_gap(Time::new(2, 1), Time::new(5, 1));
        let r: Vec<(i64, i64)> = t.items().iter().map(|i| (i.range.start.value(), i.range.duration.value())).collect();
        assert_eq!(r, vec![(1, 3), (9, 1), (13, 1)], "under the pivot: untouched; after it: moved, same length");
        assert_eq!(t.items()[0], before, "words of the caption under the pivot stay too");
        t.open_gap(Time::new(9, 1), Time::new(1, 1));
        assert_eq!(t.items()[1].range.start.value(), 10, "a caption starting exactly at the pivot moves");
        t.open_gap(Time::new(0, 1), Time::ZERO);
        assert_eq!(t.items()[1].range.start.value(), 10, "no gap, no change");
    }
}
