// Swift: CaptionSearchModel.swift
//! Find and replace over the caption tracks of a timeline (the popup on the caption track). Pure: the popup draws it,
//! the timeline view commits what `replacing_current` / `replacing_all` return as one undo step each.

use sq_core_audio::caption_words::CaptionTextMatch;
use sq_core_audio::timeline_caption_edits::TimelineCaptionEditsExt;
use sq_core_edit::captions_words::TimelineCaptionWordsExt;
use sq_core_model::Timeline;
use sq_core_time::text::graphemes;
use sq_core_time::{Id, Time};

/// The find and replace state.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionSearchModel {
    /// The text to find.
    pub find: String,
    /// The replacement.
    pub replacement: String,
    /// Match case.
    pub case_sensitive: bool,
    /// Limits the search to one caption track (`None`: every track).
    pub track: Option<Id>,
    matches: Vec<CaptionTextMatch>,
    current: Option<usize>,
}

impl CaptionSearchModel {
    /// A model for `track` (`None`: every track).
    pub fn new(track: Option<Id>) -> CaptionSearchModel {
        CaptionSearchModel {
            find: String::new(),
            replacement: String::new(),
            case_sensitive: false,
            track,
            matches: Vec::new(),
            current: None,
        }
    }

    /// Matches in time order.
    pub fn matches(&self) -> &[CaptionTextMatch] {
        &self.matches
    }

    /// Index of the current match in `matches()`.
    pub fn current(&self) -> Option<usize> {
        self.current
    }

    /// The current match.
    pub fn current_match(&self) -> Option<&CaptionTextMatch> {
        self.current.and_then(|i| self.matches.get(i))
    }

    /// "3 of 12", "No matches", or nothing while the find text is empty.
    pub fn count_label(&self) -> String {
        if self.find.is_empty() {
            return String::new();
        }
        if self.matches.is_empty() {
            return "No matches".to_string();
        }
        format!("{} of {}", self.current.unwrap_or(0) + 1, self.matches.len())
    }

    /// There is a current match and replacing would change something.
    pub fn can_replace(&self) -> bool {
        self.current_match().is_some() && self.find != self.replacement
    }

    /// Searches `timeline` again. The current match stays the same occurrence when it still exists; otherwise it becomes
    /// the first match at or after `time` (the playhead), wrapping to the first one.
    pub fn refresh(&mut self, timeline: &Timeline, time: Time) {
        let old = self.current_match().cloned();
        self.matches = timeline.caption_text_matches(&self.find, self.case_sensitive, self.track);
        if self.matches.is_empty() {
            self.current = None;
            return;
        }
        if let Some(old) = old
            && let Some(i) = self.matches.iter().position(|m| *m == old)
        {
            self.current = Some(i);
            return;
        }
        self.current = Some(self.matches.iter().position(|m| m.time >= time).unwrap_or(0));
    }

    /// Next or previous match, wrapping at the ends.
    pub fn step(&mut self, forward: bool) {
        if self.matches.is_empty() {
            self.current = None;
            return;
        }
        let n = self.matches.len() as i64;
        let i = self.current.map_or(if forward { -1 } else { 0 }, |c| c as i64);
        self.current = Some((((i + if forward { 1 } else { -1 }) % n + n) % n) as usize);
    }

    /// The timeline with the current match replaced, `None` when there is nothing to replace or the track is locked.
    /// The model then points at the match that followed it.
    pub fn replacing_current(&mut self, timeline: &Timeline) -> Option<Timeline> {
        if !self.can_replace() {
            return None;
        }
        let m = self.current_match()?.clone();
        let i = self.current?;
        let mut out = timeline.clone();
        out.replace_caption_match(&m, &self.replacement).ok()?;
        if out == *timeline {
            return None;
        }
        self.matches = out.caption_text_matches(&self.find, self.case_sensitive, self.track);
        // The replacement may contain the find text again: step over it instead of matching it forever.
        let resume = m.range.start + graphemes(&self.replacement).count();
        let after = self.matches.iter().position(|n| {
            if n.caption == m.caption {
                return n.line > m.line || (n.line == m.line && n.range.start >= resume);
            }
            n.time > m.time
        });
        self.current =
            if self.matches.is_empty() { None } else { Some(after.unwrap_or_else(|| i.min(self.matches.len() - 1))) };
        Some(out)
    }

    /// The timeline with every match replaced and how many there were, `None` when nothing changes.
    pub fn replacing_all(&mut self, timeline: &Timeline) -> Option<(Timeline, usize)> {
        if self.find.is_empty() || self.find == self.replacement || self.matches.is_empty() {
            return None;
        }
        let mut out = timeline.clone();
        let n = out.replace_caption_text(&self.find, &self.replacement, self.case_sensitive, self.track).ok()?;
        if n == 0 {
            return None;
        }
        self.refresh(&out, Time::ZERO);
        Some((out, n))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::{CaptionItem, SequenceFormat};
    use sq_core_time::TimeRange;

    fn tl(texts: &[&str]) -> Timeline {
        let mut track: sq_core_model::CaptionTrack =
            serde_json::from_value(serde_json::json!({"id": uid().to_string()})).unwrap();
        track.with_items(|v| {
            for (k, t) in texts.iter().enumerate() {
                v.push(CaptionItem {
                    id: uid(),
                    lines: vec![t.to_string()],
                    range: TimeRange::new(Time::new(k as i64, 1), Time::new(1, 1)),
                    style_ref: String::new(),
                    animation_ref: String::new(),
                    style_overridden: false,
                    words: vec![],
                    position: None,
                });
            }
        });
        let mut t = Timeline::new(uid(), "t", SequenceFormat::new(Time::new(1, 30)), vec![]);
        t.caption_tracks = vec![track];
        t
    }

    #[test]
    fn count_label_and_stepping_wrap() {
        let t = tl(&["red car", "blue car", "red bus"]);
        let mut m = CaptionSearchModel::new(None);
        assert_eq!(m.count_label(), "");
        m.find = "car".to_string();
        m.refresh(&t, Time::ZERO);
        assert_eq!(m.count_label(), "1 of 2");
        m.step(true);
        m.step(true);
        assert_eq!(m.current(), Some(0));
        m.step(false);
        assert_eq!(m.current(), Some(1));
        m.find = "zzz".to_string();
        m.refresh(&t, Time::ZERO);
        assert_eq!(m.count_label(), "No matches");
    }

    #[test]
    fn replace_current_moves_on_and_replace_all_counts() {
        let t = tl(&["red car", "blue car"]);
        let mut m = CaptionSearchModel::new(None);
        m.find = "car".to_string();
        m.replacement = "bike".to_string();
        m.refresh(&t, Time::ZERO);
        let one = m.replacing_current(&t).unwrap();
        assert_eq!(one.caption_tracks[0].items()[0].lines[0], "red bike");
        assert_eq!(m.matches().len(), 1);
        let (all, n) = m.replacing_all(&t).unwrap();
        assert_eq!(n, 2);
        assert_eq!(all.caption_tracks[0].items()[1].lines[0], "blue bike");
        let mut same = CaptionSearchModel::new(None);
        same.find = "car".to_string();
        same.replacement = "car".to_string();
        same.refresh(&t, Time::ZERO);
        assert!(same.replacing_current(&t).is_none() && same.replacing_all(&t).is_none());
    }
}
