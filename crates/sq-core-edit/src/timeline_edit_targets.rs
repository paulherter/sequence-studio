// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+EditTargets.swift (the edit target rule and clamp reporting)
//
// One track-targeting rule for the playhead commands Cmd+K (add edit), Up/Down (edit navigation) and X (mark clip):
//   1. the tracks holding a selected clip, if any selected clip is in this sequence;
//   2. else the targeted tracks, if any track is targeted;
//   3. else all tracks.
// Locked tracks stay in the scope: reading commands (Up/Down, X) use them; Cmd+K skips them and fails with
// `TrackLocked` only when every track in the scope is locked. Q/W are not covered (they trim all unlocked tracks).
//
// Ripple clamps never limit silently: the `*_outcome` variants return `Clamped(reason)` when clips on another track kept
// the edit short of what was asked. `RippleClamp` itself lives in sq-core-model.

use sq_core_model::{ClipEdge, EditError, RippleClamp, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeSet;

use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use crate::timeline_three_point::TimelineThreePointExt as _;

/// Why an edit did less than asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ClampReason {
    /// Clips on this track left too little room; the edit ran `shortfall` shorter than asked.
    ClipOnTrack {
        /// The limiting track.
        track: Id,
        /// How much less the edit did.
        shortfall: Time,
    },
}

/// Result of an edit that can be limited.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditOutcome {
    /// Done as asked.
    Applied,
    /// Done, but less than asked.
    Clamped(ClampReason),
}

impl EditOutcome {
    /// The reason when the edit was limited.
    pub fn clamp_reason(&self) -> Option<ClampReason> {
        match self {
            EditOutcome::Clamped(r) => Some(*r),
            EditOutcome::Applied => None,
        }
    }
}

/// Which tier of the rule picked the tracks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditTargetsSource {
    /// The tracks of the selected clips.
    Selection,
    /// The targeted tracks.
    Targeted,
    /// All tracks.
    All,
}

/// Which tracks a playhead command acts on, and which tier of the rule picked them.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EditTargets {
    /// The tier.
    pub source: EditTargetsSource,
    /// In timeline order; locked tracks included.
    pub tracks: Vec<Id>,
}

/// The edit target rule and the clamp-reporting edit variants.
pub trait TimelineEditTargetsExt {
    /// The edit target rule: tracks of the selected clips, else the targeted tracks, else all tracks.
    fn edit_targets(&self, selection: &BTreeSet<Id>) -> EditTargets;

    /// Cmd+K: cuts at `t` on the tracks the rule picks, skipping locked ones. Fails with `TrackLocked` when every track in
    /// the scope is locked. Returns the ids of the new right halves.
    fn add_edit_for_selection(
        &mut self,
        t: Time,
        selection: &BTreeSet<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;

    /// Up/Down: sorted, unique clip starts and ends on the tracks the rule picks.
    fn edit_points(&self, selection: &BTreeSet<Id>) -> Vec<Time>;

    /// X: In/Out around the clips under `t` on the tracks the rule picks; `None` when none is under `t`.
    fn mark_clip_range_for_selection(&self, t: Time, selection: &BTreeSet<Id>) -> Option<TimeRange>;

    /// "V3" / "A2": the track's number among the tracks of its kind, counted from 1.
    fn track_label(&self, id: Id) -> Option<String>;

    /// Status-line text for a clamp, without the verb: "limited by clip on V3".
    fn describe(&self, reason: &ClampReason) -> String;

    /// Q/W (`ripple_trim_to_playhead`) with the clamp reported.
    fn ripple_trim_to_playhead_outcome(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
    ) -> Result<(Time, EditOutcome), EditError>;

    /// Ripple delete with the clamp reported (the gap closed less than the deleted span).
    fn ripple_delete_outcome(&mut self, ids: &[Id]) -> Result<(Time, EditOutcome), EditError>;

    /// Extract (In/Out) with the clamp reported (the gap closed less than the range).
    fn extract_outcome(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(Time, EditOutcome), EditError>;
}

fn outcome(tl: &Timeline, clamp: Option<RippleClamp>) -> EditOutcome {
    match clamp {
        Some(c) if c.shortfall > Time::ZERO => {
            EditOutcome::Clamped(ClampReason::ClipOnTrack { track: tl.tracks[c.track].id, shortfall: c.shortfall })
        }
        _ => EditOutcome::Applied,
    }
}

impl TimelineEditTargetsExt for Timeline {
    fn edit_targets(&self, selection: &BTreeSet<Id>) -> EditTargets {
        let selected: Vec<Id> = self
            .tracks
            .iter()
            .filter(|tr| tr.clips().iter().any(|c| selection.contains(&c.id)))
            .map(|t| t.id)
            .collect();
        if !selected.is_empty() {
            return EditTargets { source: EditTargetsSource::Selection, tracks: selected };
        }
        let targeted: Vec<Id> = self.tracks.iter().filter(|t| t.is_targeted).map(|t| t.id).collect();
        if !targeted.is_empty() {
            return EditTargets { source: EditTargetsSource::Targeted, tracks: targeted };
        }
        EditTargets { source: EditTargetsSource::All, tracks: self.tracks.iter().map(|t| t.id).collect() }
    }

    fn add_edit_for_selection(
        &mut self,
        t: Time,
        selection: &BTreeSet<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let scope = self.edit_targets(selection).tracks;
        let open: Vec<Id> = scope.iter().copied().filter(|id| self.track(*id).is_some_and(|t| !t.is_locked)).collect();
        if open.is_empty() && !scope.is_empty() {
            return Err(EditError::TrackLocked);
        }
        self.add_edit(t, Some(&open), ids)
    }

    fn edit_points(&self, selection: &BTreeSet<Id>) -> Vec<Time> {
        let scope: BTreeSet<Id> = self.edit_targets(selection).tracks.into_iter().collect();
        let mut set: BTreeSet<Time> = BTreeSet::new();
        for tr in self.tracks.iter().filter(|tr| scope.contains(&tr.id)) {
            for c in tr.clips() {
                set.insert(c.start);
                set.insert(c.timeline().end());
            }
        }
        set.into_iter().collect()
    }

    fn mark_clip_range_for_selection(&self, t: Time, selection: &BTreeSet<Id>) -> Option<TimeRange> {
        self.mark_clip_range(t, Some(&self.edit_targets(selection).tracks))
    }

    fn track_label(&self, id: Id) -> Option<String> {
        let i = self.tracks.iter().position(|t| t.id == id)?;
        let kind = self.tracks[i].kind;
        let n = self.tracks[..=i].iter().filter(|t| t.kind == kind).count();
        Some(format!("{}{}", if kind == TrackKind::Video { "V" } else { "A" }, n))
    }

    fn describe(&self, reason: &ClampReason) -> String {
        match reason {
            ClampReason::ClipOnTrack { track, .. } => {
                format!(
                    "limited by clip on {}",
                    self.track_label(*track).unwrap_or_else(|| "another track".to_string())
                )
            }
        }
    }

    fn ripple_trim_to_playhead_outcome(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
    ) -> Result<(Time, EditOutcome), EditError> {
        let (moved, limited_by, shortfall) = self.ripple_trim_to_playhead_detailed(edge, t, tracks)?;
        match limited_by {
            Some(track) if shortfall > Time::ZERO => {
                Ok((moved, EditOutcome::Clamped(ClampReason::ClipOnTrack { track, shortfall })))
            }
            _ => Ok((moved, EditOutcome::Applied)),
        }
    }

    fn ripple_delete_outcome(&mut self, ids: &[Id]) -> Result<(Time, EditOutcome), EditError> {
        let mut work = self.clone();
        let (closed, clamp) = work.ripple_delete_detailed(ids)?;
        let o = outcome(&work, clamp);
        *self = work;
        Ok((closed, o))
    }

    fn extract_outcome(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(Time, EditOutcome), EditError> {
        let mut work = self.clone();
        let (closed, clamp) = work.extract_detailed(range, tracks, ids)?;
        let o = outcome(&work, clamp);
        *self = work;
        Ok((closed, o))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::Clip;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    #[test]
    fn the_rule_picks_selection_then_targeted_then_all() {
        let (x, y) = (v(0, 4), a(0, 4));
        let mut tl = timeline(vec![track(Video, vec![x.clone()]), track(Audio, vec![y.clone()])]);
        let (t0, t1) = (tl.tracks[0].id, tl.tracks[1].id);
        let e = tl.edit_targets(&BTreeSet::new());
        assert_eq!((e.source, e.tracks), (EditTargetsSource::All, vec![t0, t1]));
        tl.tracks[1].is_targeted = true;
        let e = tl.edit_targets(&BTreeSet::new());
        assert_eq!((e.source, e.tracks), (EditTargetsSource::Targeted, vec![t1]));
        let e = tl.edit_targets(&BTreeSet::from([x.id]));
        assert_eq!((e.source, e.tracks), (EditTargetsSource::Selection, vec![t0]));
    }

    #[test]
    fn add_edit_skips_locked_tracks_and_fails_only_when_all_are_locked() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 10)]), locked(track(Audio, vec![a(0, 10)]))]);
        let mut ids = SequentialIds::default();
        assert_eq!(tl.add_edit_for_selection(s(4), &BTreeSet::new(), &mut ids).map(|v| v.len()), Ok(1));
        assert_eq!(spans(&tl.tracks[0]), [[0, 4], [4, 10]]);
        assert_eq!(spans(&tl.tracks[1]), [[0, 10]]);
        tl.tracks[0].is_locked = true;
        assert_eq!(tl.add_edit_for_selection(s(6), &BTreeSet::new(), &mut ids), Err(EditError::TrackLocked));
    }

    #[test]
    fn edit_points_labels_and_mark_clip() {
        let tl = timeline(vec![
            track(Video, vec![v(0, 4), v(6, 2)]),
            track(Video, vec![v(2, 8)]),
            track(Audio, vec![a(0, 1)]),
        ]);
        assert_eq!(tl.edit_points(&BTreeSet::new()), [s(0), s(1), s(2), s(4), s(6), s(8), s(10)]);
        assert_eq!(tl.track_label(tl.tracks[1].id).as_deref(), Some("V2"));
        assert_eq!(tl.track_label(tl.tracks[2].id).as_deref(), Some("A1"));
        assert_eq!(tl.mark_clip_range_for_selection(s(3), &BTreeSet::new()), Some(r(0, 10)));
        let reason = ClampReason::ClipOnTrack { track: tl.tracks[1].id, shortfall: s(1) };
        assert_eq!(tl.describe(&reason), "limited by clip on V2");
        assert_eq!(EditOutcome::Clamped(reason).clamp_reason(), Some(reason));
    }

    #[test]
    fn extract_outcome_reports_the_clamp() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 10)]), track(Video, vec![v(0, 4), v(8, 2)])]);
        let t0 = tl.tracks[0].id;
        let (closed, outcome) =
            tl.extract_outcome(r(1, 6), &[t0], &mut SequentialIds::default()).unwrap_or_default_outcome();
        assert_eq!(closed, s(4));
        assert_eq!(outcome, EditOutcome::Clamped(ClampReason::ClipOnTrack { track: tl.tracks[1].id, shortfall: s(1) }));
        assert_eq!(
            tl.describe(
                &outcome.clamp_reason().unwrap_or(ClampReason::ClipOnTrack { track: Id::NIL, shortfall: s(0) })
            ),
            "limited by clip on V2"
        );
    }

    // RippleClampOutcomeTests (EditTargetRulesTests.swift)

    fn vclip(start: i64, dur: i64, media: i64) -> Clip {
        clip(start, dur, 0, Video, None, Some(media))
    }

    #[test]
    fn q_unclamped_is_applied() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 4), v(4, 2)])]);
        assert_eq!(tl.ripple_trim_to_playhead_outcome(ClipEdge::Head, s(1), None), Ok((s(1), EditOutcome::Applied)));
    }

    #[test]
    fn q_clamped_by_other_track_reports_the_reason() {
        let mut tl = timeline(vec![track(Video, vec![vclip(0, 10, 20)]), track(Video, vec![v(0, 3), v(4, 2)])]);
        let t0 = tl.tracks[0].id;
        let (moved, outcome) = tl.ripple_trim_to_playhead_outcome(ClipEdge::Head, s(3), Some(&[t0])).unwrap();
        assert_eq!(moved, s(1));
        let reason = ClampReason::ClipOnTrack { track: tl.tracks[1].id, shortfall: s(2) };
        assert_eq!(outcome, EditOutcome::Clamped(reason));
        assert_eq!(tl.describe(&reason), "limited by clip on V2");
    }

    #[test]
    fn w_clamped_by_other_track_reports_the_reason() {
        let mut tl = timeline(vec![track(Video, vec![vclip(0, 4, 10), v(4, 2)]), track(Video, vec![v(0, 3), v(4, 1)])]);
        let t0 = tl.tracks[0].id;
        let (moved, outcome) = tl.ripple_trim_to_playhead_outcome(ClipEdge::Tail, s(1), Some(&[t0])).unwrap();
        assert_eq!(moved, s(-1));
        assert_eq!(outcome, EditOutcome::Clamped(ClampReason::ClipOnTrack { track: tl.tracks[1].id, shortfall: s(2) }));
    }

    #[test]
    fn ripple_delete_unclamped_is_applied() {
        let first = v(0, 2);
        let mut tl = timeline(vec![track(Video, vec![first.clone(), v(2, 2)]), track(Video, vec![v(5, 1)])]);
        assert_eq!(tl.ripple_delete_outcome(&[first.id]), Ok((s(2), EditOutcome::Applied)));
    }

    #[test]
    fn ripple_delete_clamped_by_other_track_reports_the_reason() {
        // V2 [0,1) and [2,3): its later clip can move only 1 s left, so the 2 s gap closes by 1 s.
        let first = v(0, 2);
        let mut tl = timeline(vec![track(Video, vec![first.clone(), v(2, 2)]), track(Video, vec![v(0, 1), v(2, 1)])]);
        let (closed, outcome) = tl.ripple_delete_outcome(&[first.id]).unwrap();
        assert_eq!(closed, s(1));
        let reason = ClampReason::ClipOnTrack { track: tl.tracks[1].id, shortfall: s(1) };
        assert_eq!(outcome, EditOutcome::Clamped(reason));
        assert_eq!(tl.describe(&reason), "limited by clip on V2");
        assert!(tl.tracks.iter().all(|t| t.is_consistent()));
    }

    #[test]
    fn extract_unclamped_is_applied() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 8)])]);
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.extract_outcome(r(2, 4), &[t0], &mut SequentialIds::default()), Ok((s(2), EditOutcome::Applied)));
    }

    #[test]
    fn extract_clamped_by_other_track_reports_the_reason() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 8)]), track(Video, vec![v(0, 3), v(4, 2)])]);
        let t0 = tl.tracks[0].id;
        let (closed, outcome) = tl.extract_outcome(r(2, 4), &[t0], &mut SequentialIds::default()).unwrap();
        assert_eq!(closed, s(1));
        assert_eq!(outcome, EditOutcome::Clamped(ClampReason::ClipOnTrack { track: tl.tracks[1].id, shortfall: s(1) }));
    }

    #[test]
    fn a_clamped_outcome_exposes_its_reason_and_applied_does_not() {
        let reason = ClampReason::ClipOnTrack { track: Id::NIL, shortfall: s(1) };
        assert_eq!(EditOutcome::Applied.clamp_reason(), None);
        assert_eq!(EditOutcome::Clamped(reason).clamp_reason(), Some(reason));
    }

    #[test]
    fn q_w_trim_every_unlocked_track_whatever_is_targeted() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 4)]), track(Video, vec![v(0, 4)])]);
        tl.tracks[0].is_targeted = true;
        tl.ripple_trim_to_playhead(ClipEdge::Tail, s(2), None).unwrap();
        let ends: Vec<Time> = tl.tracks.iter().map(|t| t.clips()[0].timeline().end()).collect();
        assert_eq!(ends, [s(2), s(2)]);
    }

    trait OrDefault {
        fn unwrap_or_default_outcome(self) -> (Time, EditOutcome);
    }

    impl OrDefault for Result<(Time, EditOutcome), EditError> {
        fn unwrap_or_default_outcome(self) -> (Time, EditOutcome) {
            self.unwrap_or((Time::ZERO, EditOutcome::Applied))
        }
    }
}
