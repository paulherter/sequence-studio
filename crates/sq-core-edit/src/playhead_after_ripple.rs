// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PlayheadAfterRipple.swift
//
// The playhead keeps the picture it was on when a ripple closes material before it. A closed span is the stretch of the
// timeline that disappears: everything at or after its end moves left by its duration.

use sq_core_model::{Marker, Timeline};
use sq_core_time::{IdSource, Time, TimeRange};

/// Playhead position after ripples.
pub trait PlayheadAfterRippleExt {
    /// Where a playhead belongs after ripples closed `spans` (in the order the edits ran, each span in the coordinates the
    /// one before left behind). Same point rule as `shift_markers`: at or after a span it moves left by the span, inside it
    /// lands on the edit point where the span began, before it stays.
    fn playhead_after_ripple(playhead: Time, spans: &[TimeRange]) -> Time;

    /// Runs `edit` and returns where a playhead at `playhead` belongs afterwards. Every ripple reports the span it closes to
    /// the sequence markers (`close_caption_span`), so a probe marker at the playhead rides along with the edit and is taken
    /// out again: the result follows `playhead_after_ripple` for whatever the edit closed, on whichever path. Only closing
    /// moves the playhead: an edit that pushes material later leaves it where it was. A refused edit returns its error and
    /// changes nothing.
    fn following_ripple<E>(
        &mut self,
        playhead: Time,
        ids: &mut dyn IdSource,
        edit: impl FnOnce(&mut Timeline) -> Result<(), E>,
    ) -> Result<Time, E>;
}

impl PlayheadAfterRippleExt for Timeline {
    fn playhead_after_ripple(playhead: Time, spans: &[TimeRange]) -> Time {
        spans.iter().fold(playhead, |p, span| {
            if span.is_empty() || p < span.start {
                p
            } else if p >= span.end() {
                p - span.duration
            } else {
                span.start
            }
        })
    }

    fn following_ripple<E>(
        &mut self,
        playhead: Time,
        ids: &mut dyn IdSource,
        edit: impl FnOnce(&mut Timeline) -> Result<(), E>,
    ) -> Result<Time, E> {
        let mut work = self.clone();
        let probe = Marker {
            id: ids.next_id(),
            time: playhead,
            name: String::new(),
            color: Default::default(),
            comment: String::new(),
            duration: Time::ZERO,
        };
        let at = work.markers.iter().position(|m| m.time > playhead).unwrap_or(work.markers.len());
        let probe_id = probe.id;
        work.markers.insert(at, probe);
        edit(&mut work)?;
        let landed = work.markers.iter().find(|m| m.id == probe_id).map_or(playhead, |m| m.time);
        work.markers.retain(|m| m.id != probe_id);
        *self = work;
        Ok(landed.min(playhead))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use crate::timeline_range_edits::TimelineRangeEditsExt as _;
    use sq_core_model::TrackKind::Video;
    use sq_core_time::SequentialIds;

    #[test]
    fn the_rule_moves_left_by_closed_spans() {
        let spans = [r(2, 4)];
        assert_eq!(Timeline::playhead_after_ripple(s(10), &spans), s(8));
        assert_eq!(Timeline::playhead_after_ripple(s(3), &spans), s(2)); // inside: where the span began
        assert_eq!(Timeline::playhead_after_ripple(s(1), &spans), s(1));
        assert_eq!(Timeline::playhead_after_ripple(s(4), &spans), s(2));
        // each span is in the coordinates the one before left behind
        assert_eq!(Timeline::playhead_after_ripple(s(10), &[r(2, 4), r(6, 8)]), s(6));
    }

    #[test]
    fn an_extract_reports_its_span_through_the_probe_marker() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 10)])]);
        let t0 = tl.tracks[0].id;
        let mut ids = SequentialIds::default();
        let landed = tl
            .following_ripple(s(8), &mut ids, |t| t.extract(r(2, 4), &[t0], &mut SequentialIds::default()).map(|_| ()));
        assert_eq!(landed, Ok(s(6)));
        assert!(tl.markers.is_empty());
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [2, 8]]);
    }

    #[test]
    fn material_pushed_later_leaves_the_playhead_and_a_refused_edit_changes_nothing() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 10)])]);
        let before = tl.clone();
        let t0 = tl.tracks[0].id;
        let landed = tl.following_ripple(s(8), &mut SequentialIds::default(), |t| {
            t.lift(r(2, 4), &[t0], &mut SequentialIds::default())
        });
        assert_eq!(landed, Ok(s(8)));
        let mut locked_tl = before.clone();
        locked_tl.tracks[0].is_locked = true;
        let t0 = locked_tl.tracks[0].id;
        let refused = locked_tl.following_ripple(s(8), &mut SequentialIds::default(), |t| {
            t.extract(r(2, 4), &[t0], &mut SequentialIds::default()).map(|_| ())
        });
        assert!(refused.is_err());
        assert_eq!(spans(&locked_tl.tracks[0]), [[0, 10]]);
    }
}
