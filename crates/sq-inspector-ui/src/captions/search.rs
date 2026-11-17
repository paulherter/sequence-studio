// Swift: CaptionSearch.swift
//! Search in the transcript and in the caption list (type the term, the instances are marked, the arrows move between them).

use std::ops::Range;

use sq_core_audio::caption_handover::TimelineCaptionsExt;
use sq_core_model::Timeline;
use sq_core_time::text_search;
use sq_core_time::{Id, Time};

/// Pure functions; the views only draw and select.
pub enum TranscriptSearch {}

impl TranscriptSearch {
    /// UTF-16 ranges of every non-overlapping occurrence of `find` in `text`, in order. Case-insensitive searches also
    /// ignore diacritics.
    pub fn matches(text: &str, find: &str, case_sensitive: bool) -> Vec<Range<usize>> {
        text_search::matches(text, find, case_sensitive, case_sensitive)
    }

    /// Index of the match after (or before) `location`, wrapping at the ends. A match that starts at `location` counts
    /// as the current one, so repeated "next" moves on and "previous" goes back. `None` without matches.
    pub fn step(matches: &[Range<usize>], location: usize, forward: bool) -> Option<usize> {
        if matches.is_empty() {
            return None;
        }
        if forward {
            return Some(matches.iter().position(|m| m.start > location).unwrap_or(0));
        }
        Some(matches.iter().rposition(|m| m.start < location).unwrap_or(matches.len() - 1))
    }
}

/// The caption of the next or previous match relative to the time `t` (a caption starting exactly at `t` is the
/// current one), wrapping around. `None` without matches.
pub fn caption_match(timeline: &Timeline, find: &str, case_sensitive: bool, t: Time, forward: bool) -> Option<Id> {
    let ids = timeline.caption_matches(find, case_sensitive);
    if ids.is_empty() {
        return None;
    }
    let items: Vec<_> = timeline.caption_tracks.iter().flat_map(|c| c.items()).collect();
    let start = |id: Id| items.iter().find(|i| i.id == id).map_or(Time::ZERO, |i| i.range.start);
    if forward {
        return Some(ids.iter().copied().find(|id| start(*id) > t).unwrap_or(ids[0]));
    }
    Some(ids.iter().copied().rev().find(|id| start(*id) < t).unwrap_or(ids[ids.len() - 1]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_audio::timeline_caption_edits::TimelineCaptionEditsExt;
    use sq_core_model::{CaptionItem, SequenceFormat};
    use sq_core_time::{SequentialIds, TimeRange};

    fn item(text: &str, a: i64) -> CaptionItem {
        CaptionItem {
            id: Id::fixed(a as u64 + 100),
            lines: vec![text.to_string()],
            range: TimeRange::from_end(Time::new(a, 1), Time::new(a + 1, 1)),
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        }
    }

    #[test]
    fn transcript_matches_are_found_in_order_and_ignore_case_by_default() {
        let m = TranscriptSearch::matches("The cat sat. the CAT ran.", "cat", false);
        assert_eq!(m, [4..7, 17..20]);
        assert_eq!(TranscriptSearch::matches("The cat sat. the CAT ran.", "cat", true).len(), 1);
        assert!(TranscriptSearch::matches("abc", "", false).is_empty());
    }

    #[test]
    fn next_and_previous_walk_the_matches_and_wrap() {
        let m = [4..7, 17..20, 30..33];
        assert_eq!(TranscriptSearch::step(&m, 0, true), Some(0));
        assert_eq!(TranscriptSearch::step(&m, 4, true), Some(1));
        assert_eq!(TranscriptSearch::step(&m, 30, true), Some(0));
        assert_eq!(TranscriptSearch::step(&m, 17, false), Some(0));
        assert_eq!(TranscriptSearch::step(&m, 4, false), Some(2));
        assert_eq!(TranscriptSearch::step(&[], 0, true), None);
    }

    fn timeline(items: Vec<CaptionItem>) -> Timeline {
        let mut t = Timeline::new(Id::fixed(1), "t", SequenceFormat::new(Time::new(1, 30)), Vec::new());
        t.replace_captions(items, None, &mut SequentialIds::default()).unwrap_or_else(|e| panic!("{e:?}"));
        t
    }

    #[test]
    fn caption_matches_step_through_time_both_ways() {
        let t = timeline(vec![item("hello", 0), item("the cat", 2), item("nothing", 4), item("a cat again", 6)]);
        let ids: Vec<Id> = t.caption_tracks[0].items().iter().map(|i| i.id).collect();
        let at = |s: i64, forward| caption_match(&t, "cat", false, Time::new(s, 1), forward);
        assert_eq!(at(0, true), Some(ids[1]));
        assert_eq!(at(2, true), Some(ids[3]));
        assert_eq!(at(6, true), Some(ids[1]));
        assert_eq!(at(6, false), Some(ids[1]));
        assert_eq!(at(2, false), Some(ids[3]));
        assert_eq!(caption_match(&t, "dog", false, Time::ZERO, true), None);
    }
}
