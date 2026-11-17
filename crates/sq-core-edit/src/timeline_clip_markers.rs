//! Port of `Timeline+ClipMarkers.swift`: editing clip markers from the timeline (`clip_markers` holds the visibility rule).
//! Markers are stored in the clip's source time; these helpers take sequence time (what the user points at) and convert
//! with `Clip::source_time`, so a marker keeps its source frame through trims and splits.

use crate::clip_markers::ClipMarkersExt as _;
use crate::timeline_replace::TimelineReplaceExt as _;
use sq_core_model::{Marker, MarkerColor, Timeline, floored_to_frame};
use sq_core_time::{Id, IdSource, Time};

/// `extension Timeline` of `Timeline+ClipMarkers.swift`.
pub trait TimelineClipMarkersExt {
    /// Adds a marker to clip `clip` at sequence time `time` (snapped to the sequence frame grid). `None` when the clip does
    /// not show markers there: the time is outside the clip, or the clip plays a hold frame or an applied title template.
    fn add_clip_marker(
        &mut self,
        clip: Id,
        time: Time,
        name: &str,
        color: MarkerColor,
        ids: &mut dyn IdSource,
    ) -> Option<Id>;

    /// Moves a clip marker to sequence time `time` (clamped into the clip, on the frame grid). False when unknown or when
    /// the clip would not show the marker there.
    fn move_clip_marker(&mut self, id: Id, clip: Id, time: Time) -> bool;

    /// Changes name, color, comment or length of a clip marker (not its position, see `move_clip_marker`). False when unknown.
    fn update_clip_marker(&mut self, id: Id, clip: Id, body: impl FnOnce(&mut Marker)) -> bool;

    /// Removes a clip marker; the list goes back to `None` when it was the last one.
    fn remove_clip_marker(&mut self, id: Id, clip: Id) -> bool;

    /// Sequence times of every clip marker shown on the timeline, for snapping (Snap to markers).
    fn clip_marker_times(&self) -> Vec<Time>;
}

impl TimelineClipMarkersExt for Timeline {
    fn add_clip_marker(
        &mut self,
        clip: Id,
        time: Time,
        name: &str,
        color: MarkerColor,
        ids: &mut dyn IdSource,
    ) -> Option<Id> {
        let fd = self.frame_duration();
        let mut c = self.find(clip)?.clip;
        let t = floored_to_frame(time, fd);
        if !c.timeline().contains(t) {
            return None;
        }
        let m = Marker {
            id: ids.next_id(),
            time: c.source_time(t, fd),
            name: name.to_string(),
            color,
            comment: String::new(),
            duration: Time::ZERO,
        };
        let id = m.id;
        c.markers.get_or_insert_with(Vec::new).push(m);
        if !c.visible_markers(fd).iter().any(|v| v.id == id) {
            return None;
        }
        self.replace_clip(c).ok().map(|_| id)
    }

    fn move_clip_marker(&mut self, id: Id, clip: Id, time: Time) -> bool {
        let fd = self.frame_duration();
        let Some(mut c) = self.find(clip).map(|m| m.clip) else { return false };
        let Some(i) = c.markers.as_ref().and_then(|all| all.iter().position(|m| m.id == id)) else { return false };
        if c.duration() <= Time::ZERO {
            return false;
        }
        let last = c.start.max(floored_to_frame(c.timeline().end() - fd, fd));
        let t = floored_to_frame(time, fd).max(c.start).min(last);
        let source = c.source_time(t, fd);
        if let Some(all) = &mut c.markers {
            all[i].time = source;
        }
        c.visible_markers(fd).iter().any(|v| v.id == id) && self.replace_clip(c).is_ok()
    }

    fn update_clip_marker(&mut self, id: Id, clip: Id, body: impl FnOnce(&mut Marker)) -> bool {
        let Some(mut c) = self.find(clip).map(|m| m.clip) else { return false };
        let Some(m) = c.markers.as_mut().and_then(|all| all.iter_mut().find(|m| m.id == id)) else { return false };
        let time = m.time;
        body(m);
        m.time = time; // the position has its own call (`move_clip_marker`)
        self.replace_clip(c).is_ok()
    }

    fn remove_clip_marker(&mut self, id: Id, clip: Id) -> bool {
        let Some(mut c) = self.find(clip).map(|m| m.clip) else { return false };
        let Some(all) = c.markers.as_mut().filter(|all| all.iter().any(|m| m.id == id)) else { return false };
        all.retain(|m| m.id != id);
        if all.is_empty() {
            c.markers = None;
        }
        self.replace_clip(c).is_ok()
    }

    fn clip_marker_times(&self) -> Vec<Time> {
        let fd = self.frame_duration();
        self.tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| c.markers.as_ref().is_some_and(|m| !m.is_empty()))
            .flat_map(|c| c.visible_markers(fd).into_iter().map(move |m| c.start + m.time))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::Video;
    use sq_core_time::SequentialIds;

    fn one_clip() -> (Timeline, Id) {
        let c = clip(2, 4, 10, Video, None, Some(100));
        let id = c.id;
        (timeline(vec![track(Video, vec![c])]), id)
    }

    #[test]
    fn a_marker_is_stored_in_source_time_and_removed_with_the_list() {
        let (mut tl, c) = one_clip();
        let mut ids = SequentialIds::default();
        let m = tl.add_clip_marker(c, s(3), "a", MarkerColor::default(), &mut ids);
        let m = m.expect("added");
        assert_eq!(tl.tracks[0].clips()[0].markers.as_ref().map(|v| v[0].time), Some(s(11)));
        assert_eq!(tl.clip_marker_times(), [s(3)]);
        assert!(tl.add_clip_marker(c, s(9), "out", MarkerColor::default(), &mut ids).is_none());
        assert!(tl.remove_clip_marker(m, c));
        assert!(tl.tracks[0].clips()[0].markers.is_none());
        assert!(!tl.remove_clip_marker(m, c));
    }

    #[test]
    fn move_clamps_into_the_clip_and_update_keeps_the_position() {
        let (mut tl, c) = one_clip();
        let mut ids = SequentialIds::default();
        let m = tl.add_clip_marker(c, s(3), "a", MarkerColor::default(), &mut ids).expect("added");
        assert!(tl.move_clip_marker(m, c, s(100)));
        let last = tl.tracks[0].clips()[0].markers.as_ref().map(|v| v[0].time);
        assert_eq!(last, Some(s(10) + s(4) - tl.frame_duration()));
        assert!(tl.update_clip_marker(m, c, |mk| {
            mk.name = "b".into();
            mk.time = s(0);
        }));
        let after = &tl.tracks[0].clips()[0].markers.as_ref().map(|v| (v[0].name.clone(), v[0].time));
        assert_eq!(after.as_ref().map(|x| x.0.as_str()), Some("b"));
        assert_eq!(after.as_ref().map(|x| x.1), last);
        assert!(!tl.move_clip_marker(Id::from_u128(9), c, s(3)));
    }
}
