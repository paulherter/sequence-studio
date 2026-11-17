// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SourceMarks.swift (saved type, moved down; split-in and range logic, Project edits: task M-4)

use crate::Project;
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Time, TimeRange};

/// Source-monitor In/Out for one media item. Each side is optional.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceMarks {
    /// In point.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mark_in: Option<Time>,
    /// Out point.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mark_out: Option<Time>,
    /// Where the sound starts when it differs from `mark_in` (Mark Audio In); `None` follows `mark_in`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_in: Option<Time>,
    /// Where the picture starts when it differs from `mark_in` (Mark Video In); `None` follows `mark_in`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_in: Option<Time>,
}

impl SourceMarks {
    /// No mark set.
    pub fn is_empty(&self) -> bool {
        self.mark_in.is_none() && self.mark_out.is_none() && self.audio_in.is_none() && self.video_in.is_none()
    }

    /// The picture and sound start points of a split edit as `(video, audio, out)`, `None` unless they differ (and both
    /// lie before `mark_out` when set).
    pub fn split_ins(&self, total: Time) -> Option<(Time, Time, Time)> {
        if self.audio_in.is_none() && self.video_in.is_none() {
            return None;
        }
        let base = self.mark_in.unwrap_or(Time::ZERO);
        let (v, a, o) = (self.video_in.unwrap_or(base), self.audio_in.unwrap_or(base), self.mark_out.unwrap_or(total));
        (v != a && o > v && o > a).then_some((v, a, o))
    }

    /// In/Out as a range when both are set and Out is after In.
    pub fn range(&self) -> Option<TimeRange> {
        let (i, o) = (self.mark_in?, self.mark_out?);
        (o > i).then(|| TimeRange::from_end(i, o))
    }
}

impl Project {
    /// The In/Out marks of a media item (none set when it has no entry).
    pub fn source_marks_for(&self, media: Id) -> SourceMarks {
        self.source_marks.get(&media).cloned().unwrap_or_default()
    }

    /// Sets In. An existing Out at or before the new In is cleared (Premiere behavior).
    pub fn set_source_in(&mut self, t: Time, media: Id) {
        let mut m = self.source_marks_for(media);
        m.mark_in = Some(t);
        m.audio_in = None;
        m.video_in = None;
        if m.mark_out.is_some_and(|o| o <= t) {
            m.mark_out = None;
        }
        self.source_marks.insert(media, m);
    }

    /// Sets Out. An existing In at or after the new Out is cleared.
    pub fn set_source_out(&mut self, t: Time, media: Id) {
        let mut m = self.source_marks_for(media);
        m.mark_out = Some(t);
        if m.mark_in.is_some_and(|i| i >= t) {
            m.mark_in = None;
        }
        self.source_marks.insert(media, m);
    }

    /// Mark Audio In: the sound starts at `t` while the picture keeps In.
    pub fn set_source_audio_in(&mut self, t: Time, media: Id) {
        let mut m = self.source_marks_for(media);
        m.audio_in = Some(t);
        self.source_marks.insert(media, m);
    }

    /// Mark Video In: the picture starts at `t` while the sound keeps In.
    pub fn set_source_video_in(&mut self, t: Time, media: Id) {
        let mut m = self.source_marks_for(media);
        m.video_in = Some(t);
        self.source_marks.insert(media, m);
    }

    /// Clears In and the split In points.
    pub fn clear_source_in(&mut self, media: Id) {
        self.update_marks(media, |m| {
            m.mark_in = None;
            m.audio_in = None;
            m.video_in = None;
        });
    }

    /// Clears Out.
    pub fn clear_source_out(&mut self, media: Id) {
        self.update_marks(media, |m| m.mark_out = None);
    }

    /// Clears every mark of the item.
    pub fn clear_source_marks(&mut self, media: Id) {
        self.source_marks.remove(&media);
    }

    fn update_marks(&mut self, media: Id, body: impl FnOnce(&mut SourceMarks)) {
        let Some(m) = self.source_marks.get_mut(&media) else { return };
        body(m);
        if m.is_empty() {
            self.source_marks.remove(&media);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn round_trips_with_missing_sides() {
        assert_round_trip::<SourceMarks>(json!({}));
        assert_round_trip::<SourceMarks>(json!({
            "markIn": {"value": 1, "timescale": 1}, "audioIn": {"value": 2, "timescale": 1}}));
    }

    #[test]
    fn is_empty_needs_all_four_unset() {
        assert!(SourceMarks::default().is_empty());
        let m = SourceMarks { video_in: Some(Time::ZERO), ..SourceMarks::default() };
        assert!(!m.is_empty());
    }

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    #[test]
    fn set_and_clear() {
        let m = crate::nesting::test_util::id(1);
        let mut p = Project::new(crate::nesting::test_util::id(9), "P", vec![], vec![]);
        p.set_source_in(s(2), m);
        p.set_source_out(s(5), m);
        assert_eq!(p.source_marks_for(m).range(), Some(TimeRange::from_end(s(2), s(5))));
        p.clear_source_in(m);
        assert_eq!(p.source_marks_for(m), SourceMarks { mark_out: Some(s(5)), ..SourceMarks::default() });
        assert_eq!(p.source_marks_for(m).range(), None);
        p.clear_source_out(m);
        assert!(!p.source_marks.contains_key(&m));
    }

    #[test]
    fn crossing_marks_clear_the_other_side() {
        let m = crate::nesting::test_util::id(1);
        let mut p = Project::new(crate::nesting::test_util::id(9), "P", vec![], vec![]);
        p.set_source_in(s(2), m);
        p.set_source_out(s(5), m);
        p.set_source_in(s(6), m);
        assert_eq!(p.source_marks_for(m), SourceMarks { mark_in: Some(s(6)), ..SourceMarks::default() });
        p.set_source_out(s(3), m);
        assert_eq!(p.source_marks_for(m), SourceMarks { mark_out: Some(s(3)), ..SourceMarks::default() });
    }

    #[test]
    fn clear_all_and_a_plain_in_clears_the_split_points() {
        let m = crate::nesting::test_util::id(1);
        let mut p = Project::new(crate::nesting::test_util::id(9), "P", vec![], vec![]);
        p.set_source_in(Time::new(1001, 30000), m);
        p.set_source_audio_in(s(3), m);
        p.set_source_video_in(s(4), m);
        p.set_source_in(s(1), m);
        assert_eq!(p.source_marks_for(m), SourceMarks { mark_in: Some(s(1)), ..SourceMarks::default() });
        p.clear_source_marks(m);
        assert!(p.source_marks.is_empty());
    }

    #[test]
    fn split_ins_need_different_points_before_out() {
        let marks = |i, o, a, v| SourceMarks { mark_in: i, mark_out: o, audio_in: a, video_in: v };
        assert_eq!(marks(Some(s(1)), None, None, None).split_ins(s(10)), None);
        assert_eq!(marks(Some(s(1)), None, Some(s(3)), None).split_ins(s(10)), Some((s(1), s(3), s(10))));
        assert_eq!(marks(None, Some(s(5)), Some(s(2)), Some(s(1))).split_ins(s(10)), Some((s(1), s(2), s(5))));
        assert_eq!(marks(Some(s(1)), None, Some(s(1)), Some(s(1))).split_ins(s(10)), None, "equal points");
        assert_eq!(marks(Some(s(1)), Some(s(3)), Some(s(4)), None).split_ins(s(10)), None, "audio after out");
    }
}
