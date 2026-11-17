// Swift: ProposedCuts.swift, SilenceRemoval.swift (the Timeline half)
//! Proposed cuts: range markers a scan leaves for the editor to review before anything is removed.

use crate::timeline_batch_ripple::TimelineBatchRippleExt as _;
use crate::timeline_markers::{new_marker, sort_markers};
use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use crate::timeline_replace::TimelineReplaceExt as _;
use crate::timeline_three_point::TimelineThreePointExt as _;
use sq_core_audio::SilenceRemoval;
use sq_core_model::{EditError, Marker, MarkerColor, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeSet;

/// What a proposed cut was found by. Silence and filler are ranges that get removed; `Scene` is a point (empty range)
/// where accepting razors the clips instead of deleting anything.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProposedCutKind {
    /// A pause.
    Silence,
    /// A filler word.
    Filler,
    /// A scene change.
    Scene,
}

impl ProposedCutKind {
    /// Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Silence => "silence",
            Self::Filler => "filler",
            Self::Scene => "scene",
        }
    }

    fn from_raw(raw: &str) -> Option<Self> {
        [Self::Silence, Self::Filler, Self::Scene].into_iter().find(|k| k.raw_value() == raw)
    }
}

/// Typed marker without a file-format change: a range marker whose comment carries this tag (`tag:kind`).
pub const PROPOSED_CUT_TAG: &str = "sq.proposedCut";

/// `extension Marker` of ProposedCuts.swift.
pub trait MarkerProposedCutExt {
    /// The kind a proposed-cut marker carries, `None` for other markers (an unknown kind reads as silence).
    fn proposed_cut_kind(&self) -> Option<ProposedCutKind>;
    /// True for a proposed-cut marker.
    fn is_proposed_cut(&self) -> bool;
}

impl MarkerProposedCutExt for Marker {
    fn proposed_cut_kind(&self) -> Option<ProposedCutKind> {
        let rest = self.comment.strip_prefix(PROPOSED_CUT_TAG)?;
        // Swift drops one separator character after the tag.
        let raw: String = rest.chars().skip(1).collect();
        Some(ProposedCutKind::from_raw(&raw).unwrap_or(ProposedCutKind::Silence))
    }

    fn is_proposed_cut(&self) -> bool {
        self.proposed_cut_kind().is_some()
    }
}

/// One pending proposal.
#[derive(Clone, Debug, PartialEq)]
pub struct ProposedCut {
    /// The marker's id.
    pub id: Id,
    /// The range to remove (empty for scenes).
    pub range: TimeRange,
    /// What found it.
    pub kind: ProposedCutKind,
}

fn sec(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

impl ProposedCut {
    /// "0:12.4   1.4 s": start in minutes:seconds and the length of the pause (the review list's row).
    pub fn row_title(&self) -> String {
        let start = sec(self.range.start).max(0.0);
        let m = start.trunc() as i64 / 60;
        let s = start - (m * 60) as f64;
        if self.kind == ProposedCutKind::Scene {
            return format!("{m}:{s:04.1}   scene change");
        }
        format!("{m}:{s:04.1}   {:.1} s", sec(self.range.duration))
    }

    /// "3 of 5 checked, 4.2 s will be removed." under the review list.
    pub fn review_summary(count: usize, checked: usize, removed: Time) -> String {
        if count == 0 {
            return "No proposed cuts.".to_string();
        }
        format!("{checked} of {count} checked, {:.1} s will be removed.", sec(removed))
    }
}

/// `extension Timeline` of ProposedCuts.swift.
pub trait TimelineProposedCutsExt {
    /// The pending "proposed cut" markers, in time order.
    fn proposed_cuts(&self) -> Vec<ProposedCut>;
    /// Total length of the pending proposals.
    fn proposed_cut_total(&self) -> Time;
    /// Replaces earlier proposals of `kind` by range markers for `cuts` (red, named "Cut: silence").
    fn propose_cuts(&mut self, cuts: &[TimeRange], kind: ProposedCutKind, ids: &mut dyn IdSource);
    /// Replaces earlier scene proposals by point markers at `times` (sorted, duplicates dropped, negative ones ignored).
    fn propose_scene_cuts(&mut self, times: &[Time], ids: &mut dyn IdSource);
    /// Drops one proposal marker.
    fn reject_proposed_cut(&mut self, id: Id);
    /// Drops every proposal marker.
    fn reject_all_proposed_cuts(&mut self);

    /// Ripple-deletes the proposals in `chosen` (`None` = all) as `remove_silences` does (all or nothing), drops their
    /// markers and moves every other marker with the closed gaps. Returns the time removed. Scene proposals razor instead:
    /// every clip under the point on the tracks of `scene_clips` (default `clips`) and of their linked partners is cut in
    /// two; nothing is removed and nothing moves.
    fn accept_proposed_cuts(
        &mut self,
        chosen: Option<&BTreeSet<Id>>,
        clips: &BTreeSet<Id>,
        scene_clips: Option<&BTreeSet<Id>>,
        join_fade: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;

    /// "Remove Silences": ripple-deletes every cut through the whole sequence, one edit, all or nothing. Cut are the tracks
    /// of `clips` and of their linked partners (a locked one refuses the edit), plus every sync-locked unlocked track: what
    /// lies inside a cut there (music, B-roll) is cut too, so everything after a cut moves by exactly its length and stays
    /// in sync. A clip a cut splits or moves takes the tracks of its linked partners along too (a locked one refuses the
    /// edit). Tracks without sync lock and locked tracks are not touched. Cuts may be unsorted or overlap; parts after the
    /// end of all affected content are ignored. Returns the total time removed.
    fn remove_silences(
        &mut self,
        cuts: &[TimeRange],
        clips: &BTreeSet<Id>,
        join_fade: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
}

impl TimelineProposedCutsExt for Timeline {
    fn proposed_cuts(&self) -> Vec<ProposedCut> {
        self.markers
            .iter()
            .filter_map(|m| {
                m.proposed_cut_kind().map(|kind| ProposedCut {
                    id: m.id,
                    range: TimeRange::new(m.time, m.duration),
                    kind,
                })
            })
            .collect()
    }

    fn proposed_cut_total(&self) -> Time {
        self.proposed_cuts().iter().fold(Time::ZERO, |acc, p| acc + p.range.duration)
    }

    fn propose_cuts(&mut self, cuts: &[TimeRange], kind: ProposedCutKind, ids: &mut dyn IdSource) {
        self.markers.retain(|m| m.proposed_cut_kind() != Some(kind));
        for c in SilenceRemoval::normalized(cuts) {
            let mut m = new_marker(ids.next_id(), c.start, &format!("Cut: {}", kind.raw_value()));
            m.color = MarkerColor::Red;
            m.comment = format!("{PROPOSED_CUT_TAG}:{}", kind.raw_value());
            m.duration = c.duration;
            self.markers.push(m);
        }
        sort_markers(&mut self.markers);
    }

    fn propose_scene_cuts(&mut self, times: &[Time], ids: &mut dyn IdSource) {
        self.markers.retain(|m| m.proposed_cut_kind() != Some(ProposedCutKind::Scene));
        let mut last: Option<Time> = None;
        let mut sorted = times.to_vec();
        sorted.sort();
        for t in sorted {
            if t > Time::ZERO && Some(t) != last {
                last = Some(t);
                let mut m = new_marker(ids.next_id(), t, "Cut: scene");
                m.color = MarkerColor::Red;
                m.comment = format!("{PROPOSED_CUT_TAG}:scene");
                self.markers.push(m);
            }
        }
        sort_markers(&mut self.markers);
    }

    fn reject_proposed_cut(&mut self, id: Id) {
        self.markers.retain(|m| !(m.id == id && m.is_proposed_cut()));
    }

    fn reject_all_proposed_cuts(&mut self) {
        self.markers.retain(|m| !m.is_proposed_cut());
    }

    fn accept_proposed_cuts(
        &mut self,
        chosen: Option<&BTreeSet<Id>>,
        clips: &BTreeSet<Id>,
        scene_clips: Option<&BTreeSet<Id>>,
        join_fade: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let chosen: Vec<ProposedCut> =
            self.proposed_cuts().into_iter().filter(|p| chosen.is_none_or(|c| c.contains(&p.id))).collect();
        if chosen.is_empty() {
            return Ok(Time::ZERO);
        }
        let mut work = self.clone();
        let scenes: Vec<&ProposedCut> = chosen.iter().filter(|p| p.kind == ProposedCutKind::Scene).collect();
        if !scenes.is_empty() {
            let sel = scene_clips.unwrap_or(clips);
            let links: BTreeSet<Id> = self
                .tracks
                .iter()
                .flat_map(|t| t.clips())
                .filter(|c| sel.contains(&c.id))
                .filter_map(|c| c.link)
                .collect();
            let tracks: Vec<Id> = work
                .tracks
                .iter()
                .filter(|t| {
                    !t.is_locked
                        && t.clips().iter().any(|c| sel.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)))
                })
                .map(|t| t.id)
                .collect();
            if !tracks.is_empty() {
                for sc in &scenes {
                    work.add_edit(sc.range.start, Some(&tracks), ids)?;
                }
            }
        }
        let removals: Vec<TimeRange> =
            chosen.iter().filter(|p| p.kind != ProposedCutKind::Scene).map(|p| p.range).collect();
        let removed =
            if removals.is_empty() { Time::ZERO } else { work.remove_silences(&removals, clips, join_fade, ids)? };
        let gone: BTreeSet<Id> = chosen.iter().map(|p| p.id).collect();
        work.markers.retain(|m| !gone.contains(&m.id));
        *self = work; // extract already moved the remaining markers (close_caption_span)
        Ok(removed)
    }

    fn remove_silences(
        &mut self,
        cuts: &[TimeRange],
        clips: &BTreeSet<Id>,
        join_fade: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let links: BTreeSet<Id> = self
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| clips.contains(&c.id))
            .filter_map(|c| c.link)
            .collect();
        let mut cut_tracks: BTreeSet<Id> = BTreeSet::new();
        for t in &self.tracks {
            let owns = t.clips().iter().any(|c| clips.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)));
            if owns || t.follows_ripple() {
                cut_tracks.insert(t.id);
            }
        }
        let normalized = SilenceRemoval::normalized(cuts);
        // Every clip on a cut track that a cut splits or moves (it ends after the first cut starts) takes its linked
        // partners along, even on tracks without sync lock, until no new track joins. A locked one refuses the edit.
        if let Some(first) = normalized.first().map(|c| c.start) {
            let mut grew = true;
            while grew {
                let moved: BTreeSet<Id> = self
                    .tracks
                    .iter()
                    .filter(|t| cut_tracks.contains(&t.id))
                    .flat_map(|t| t.clips())
                    .filter(|c| c.timeline().end() > first)
                    .filter_map(|c| c.link)
                    .collect();
                grew = false;
                for t in &self.tracks {
                    if !cut_tracks.contains(&t.id)
                        && t.clips().iter().any(|c| c.link.is_some_and(|l| moved.contains(&l)))
                    {
                        if t.is_locked {
                            return Err(EditError::TrackLocked);
                        }
                        cut_tracks.insert(t.id);
                        grew = true;
                    }
                }
            }
        }
        let end =
            self.tracks.iter().filter(|t| cut_tracks.contains(&t.id)).map(|t| t.end()).max().unwrap_or(Time::ZERO);
        let clamped: Vec<TimeRange> = normalized
            .iter()
            .filter_map(|c| {
                let b = c.end().min(end);
                (b > c.start).then(|| TimeRange::new(c.start, b - c.start))
            })
            .collect();
        if clamped.is_empty() {
            return Ok(Time::ZERO);
        }
        // Every sync-locked unlocked track is among the cut tracks, so the cuts close in one sweep and always completely.
        let order: Vec<Id> = self.tracks.iter().map(|t| t.id).filter(|id| cut_tracks.contains(id)).collect();
        let targets = self.target_indices(&order)?;
        let removed = self.extract_all(&clamped, &targets, ids)?;
        if join_fade > Time::ZERO {
            self.soften_joins(&clamped, &cut_tracks, join_fade, ids);
        }
        Ok(removed)
    }
}

/// A short fade out and fade in on both sides of every join the cuts left on the audio tracks `tracks` (a hard cut in the
/// middle of a signal clicks; the padding next to the pause is quiet, so the fade is not heard). A fade a clip already has
/// at that edge is kept when it is longer. `cuts` are sorted, non-overlapping, in time before the edit.
trait SoftenJoins {
    fn soften_joins(&mut self, cuts: &[TimeRange], tracks: &BTreeSet<Id>, length: Time, ids: &mut dyn IdSource);
}

impl SoftenJoins for Timeline {
    fn soften_joins(&mut self, cuts: &[TimeRange], tracks: &BTreeSet<Id>, length: Time, ids: &mut dyn IdSource) {
        let mut joins: Vec<Time> = Vec::new();
        let mut removed_before = Time::ZERO;
        for c in cuts {
            joins.push(c.start - removed_before);
            removed_before += c.duration;
        }
        let fd = self.frame_duration();
        let audio: Vec<Id> =
            self.tracks.iter().filter(|t| tracks.contains(&t.id) && t.kind == TrackKind::Audio).map(|t| t.id).collect();
        for id in audio {
            for t in &joins {
                // Fresh each time: an earlier join may have changed a clip.
                let Some(track) = self.track(id) else { continue };
                let a = track.clips().iter().find(|c| c.timeline().end() == *t && !c.is_generator()).cloned();
                let b = track.clips().iter().find(|c| c.start == *t && !c.is_generator()).cloned();
                let (Some(mut out), Some(mut inn)) = (a, b) else { continue };
                out.set_audio_fade_out(length.max(out.audio_fade_out()), fd, ids);
                inn.set_audio_fade_in(length.max(inn.audio_fade_in()), fd, ids);
                let _ = self.replace_clip(out);
                let _ = self.replace_clip(inn);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_markers::TimelineMarkersExt;
    use sq_core_model::SequenceFormat;
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn r(a: i64, d: i64) -> TimeRange {
        TimeRange::new(s(a), s(d))
    }
    fn timeline() -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![])
    }
    fn ranges(t: &Timeline) -> Vec<TimeRange> {
        t.proposed_cuts().iter().map(|p| p.range).collect()
    }

    #[test]
    fn propose_adds_typed_range_markers_and_replaces_old_ones() {
        let mut ids = SequentialIds::default();
        let mut t = timeline();
        let user = t.add_marker(s(1), "mine", &mut ids);
        t.propose_cuts(&[r(2, 1), r(6, 2)], ProposedCutKind::Silence, &mut ids);
        let p = t.proposed_cuts();
        assert_eq!(p.iter().map(|x| x.range).collect::<Vec<_>>(), vec![r(2, 1), r(6, 2)]);
        assert!(p.iter().all(|x| x.kind == ProposedCutKind::Silence));
        assert!(t.markers.iter().find(|m| m.id == p[0].id).is_some_and(|m| m.is_proposed_cut()));
        t.propose_cuts(&[r(9, 1)], ProposedCutKind::Silence, &mut ids); // a new scan replaces the earlier proposals only
        assert_eq!(ranges(&t), vec![r(9, 1)]);
        assert!(t.markers.iter().any(|m| m.id == user && !m.is_proposed_cut()));
    }

    #[test]
    fn reject_removes_one_marker_only() {
        let mut ids = SequentialIds::default();
        let mut t = timeline();
        t.propose_cuts(&[r(2, 1), r(6, 2)], ProposedCutKind::Silence, &mut ids);
        let first = t.proposed_cuts()[0].id;
        t.reject_proposed_cut(first);
        assert_eq!(ranges(&t), vec![r(6, 2)]);
        t.reject_all_proposed_cuts();
        assert!(t.proposed_cuts().is_empty() && t.markers.is_empty());
    }

    #[test]
    fn scene_proposals_are_points_sorted_deduplicated_and_positive() {
        let mut ids = SequentialIds::default();
        let mut t = timeline();
        t.propose_scene_cuts(&[s(5), s(-1), s(3), s(5), s(0)], &mut ids);
        let p = t.proposed_cuts();
        assert_eq!(p.iter().map(|x| x.range.start).collect::<Vec<_>>(), vec![s(3), s(5)]);
        assert!(p.iter().all(|x| x.kind == ProposedCutKind::Scene && x.range.is_empty()));
    }

    #[test]
    fn total_is_the_sum_of_proposals() {
        let mut t = timeline();
        t.propose_cuts(&[r(2, 1), r(6, 2)], ProposedCutKind::Silence, &mut SequentialIds::default());
        assert_eq!(t.proposed_cut_total(), s(3));
    }

    #[test]
    fn unknown_kind_reads_as_silence() {
        let mut m = new_marker(Id::from_u128(1), s(1), "x");
        m.comment = format!("{PROPOSED_CUT_TAG}:weird");
        assert_eq!(m.proposed_cut_kind(), Some(ProposedCutKind::Silence));
        m.comment = "other".to_string();
        assert!(!m.is_proposed_cut());
    }

    #[test]
    fn review_rows_and_summary_text() {
        let cut = ProposedCut {
            id: Id::from_u128(1),
            range: TimeRange::new(Time::new(72, 5), Time::new(7, 5)),
            kind: ProposedCutKind::Silence,
        };
        assert_eq!(cut.row_title(), "0:14.4   1.4 s");
        let scene = ProposedCut {
            id: Id::from_u128(2),
            range: TimeRange::new(s(75), Time::ZERO),
            kind: ProposedCutKind::Scene,
        };
        assert_eq!(scene.row_title(), "1:15.0   scene change");
        assert_eq!(ProposedCut::review_summary(0, 0, Time::ZERO), "No proposed cuts.");
        assert_eq!(ProposedCut::review_summary(5, 3, Time::new(21, 5)), "3 of 5 checked, 4.2 s will be removed.");
    }

    fn av_timeline() -> (Timeline, Id) {
        use sq_core_model::{
            Clip, Track,
            TrackKind::{Audio, Video},
        };
        let (m, l) = (Id::from_u128(1), Id::from_u128(2));
        let mk = |id: u128, kind| {
            let mut c = Clip::new(Id::from_u128(id), "c", m, kind, TimeRange::new(Time::ZERO, s(20)), Time::ZERO);
            c.link = Some(l);
            c
        };
        let (v, a) = (mk(10, Video), mk(11, Audio));
        let (mut vt, mut at) = (Track::new(Id::from_u128(20), Video), Track::new(Id::from_u128(21), Audio));
        vt.set_clips(vec![v]);
        at.set_clips(vec![a.clone()]);
        (Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![vt, at]), a.id)
    }

    #[test]
    fn accept_all_ripples_and_leaves_no_proposals() {
        let mut ids = SequentialIds::default();
        let (mut t, a) = av_timeline();
        t.propose_cuts(&[r(2, 1), r(6, 2)], ProposedCutKind::Silence, &mut ids);
        assert_eq!(t.accept_proposed_cuts(None, &[a].into(), None, Time::ZERO, &mut ids), Ok(s(3)));
        assert_eq!(t.tracks.iter().map(|x| x.end()).collect::<Vec<_>>(), [s(17), s(17)]);
        assert!(t.proposed_cuts().is_empty());
    }

    #[test]
    fn accept_one_keeps_the_others_at_shifted_positions() {
        let mut ids = SequentialIds::default();
        let (mut t, a) = av_timeline();
        t.propose_cuts(&[r(2, 1), r(6, 2), r(12, 2)], ProposedCutKind::Silence, &mut ids);
        let ps = t.proposed_cuts();
        let user = t.add_marker(s(10), "mine", &mut ids);
        let chosen = [ps[1].id].into(); // the 6-8 s cut
        assert_eq!(t.accept_proposed_cuts(Some(&chosen), &[a].into(), None, Time::ZERO, &mut ids), Ok(s(2)));
        assert_eq!(ranges(&t), vec![r(2, 1), r(10, 2)]); // the later one moved earlier by 2 s
        assert_eq!(t.markers.iter().find(|m| m.id == user).map(|m| m.time), Some(s(8))); // ordinary markers ripple too
        assert_eq!(t.tracks.iter().map(|x| x.end()).collect::<Vec<_>>(), [s(18), s(18)]);
    }

    #[test]
    fn accept_with_a_locked_track_fails_and_changes_nothing() {
        let mut ids = SequentialIds::default();
        let (mut t, a) = av_timeline();
        t.tracks[1].is_locked = true;
        t.propose_cuts(&[r(2, 1)], ProposedCutKind::Silence, &mut ids);
        let before = t.clone();
        assert!(t.accept_proposed_cuts(None, &[a].into(), None, Time::ZERO, &mut ids).is_err());
        assert_eq!(t, before);
    }
}
