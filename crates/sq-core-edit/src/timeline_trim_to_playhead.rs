//! Port of `Timeline+TrimToPlayhead.swift`: Q / W with a mode.

use crate::timeline_edits::TimelineEditsExt as _;
use crate::timeline_three_point::TimelineThreePointExt as _;
use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

/// How Q / W land an edge on the playhead.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PlayheadTrimMode {
    /// Q / W: ripple, later clips close the gap.
    Ripple,
    /// Shift+Q / Shift+W: the cut between two clips moves to the playhead, the sequence length stays.
    Roll,
    /// Opt+Q / Opt+W: plain trim, the gap stays.
    Plain,
}

/// `extension Timeline` of `Timeline+TrimToPlayhead.swift`.
pub trait TimelineTrimToPlayheadExt {
    /// Q (`Head`) / W (`Tail`) with a mode. The clip under `t` on each given track (`None` = all unlocked tracks) gets
    /// that edge moved to `t`. `Ripple` is `ripple_trim_to_playhead`. `Roll` also moves the touching neighbor's edge
    /// (tracks without a touching neighbor are skipped; `Collision` when none could roll). `Plain` leaves a gap. Atomic;
    /// linked partners follow. Returns the edge movement of the first trimmed clip (negative = shortened).
    fn trim_to_playhead(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
        mode: PlayheadTrimMode,
    ) -> Result<Time, EditError>;
}

impl TimelineTrimToPlayheadExt for Timeline {
    fn trim_to_playhead(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
        mode: PlayheadTrimMode,
    ) -> Result<Time, EditError> {
        if mode == PlayheadTrimMode::Ripple {
            return self.ripple_trim_to_playhead(edge, t, tracks);
        }
        let mut targets: Vec<usize> = Vec::new();
        if let Some(tracks) = tracks {
            for id in tracks {
                let i = self.tracks.iter().position(|x| x.id == *id).ok_or(EditError::ClipNotFound)?;
                if self.tracks[i].is_locked {
                    return Err(EditError::TrackLocked);
                }
                if !targets.contains(&i) {
                    targets.push(i);
                }
            }
        } else {
            targets = (0..self.tracks.len()).filter(|i| !self.tracks[*i].is_locked).collect();
        }
        let picks: Vec<Id> = targets
            .iter()
            .filter_map(|i| {
                self.tracks[*i].clips().iter().find(|c| match edge {
                    ClipEdge::Head => c.timeline().contains(t),
                    ClipEdge::Tail => c.start < t && t <= c.timeline().end(),
                })
            })
            .map(|c| c.id)
            .collect();
        if picks.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        let mut work = self.clone();
        let mut first: Option<Time> = None;
        let mut done: BTreeSet<Id> = BTreeSet::new();
        let mut skipped = false;
        for id in picks {
            if done.contains(&id) {
                continue;
            }
            let Some(m) = work.find(id) else { continue };
            let group: Vec<Id> = work.linked_group(id)?.iter().map(|g| g.clip.id).collect();
            if mode == PlayheadTrimMode::Plain {
                done.extend(group.iter().copied());
            }
            let delta = if edge == ClipEdge::Head { t - m.clip.start } else { t - m.clip.timeline().end() };
            let moved = if mode == PlayheadTrimMode::Plain {
                work.trim(id, edge, delta)?
            } else {
                // Rolling needs a touching neighbor and a real move; tracks without one are skipped.
                let clips = work.tracks[m.track].clips();
                let left = clips.iter().find(|c| c.timeline().end() == m.clip.start).map(|c| c.id);
                let right = clips.iter().find(|c| c.start == m.clip.timeline().end()).map(|c| c.id);
                let roll_id = if edge == ClipEdge::Tail { right.map(|_| id) } else { left };
                let Some(roll_id) = roll_id.filter(|_| delta != Time::ZERO) else {
                    skipped = true;
                    continue;
                };
                work.roll(roll_id, delta)?
            };
            done.extend(group); // a skipped partner (no touching neighbor) must not block its group
            first.get_or_insert(moved);
        }
        if mode == PlayheadTrimMode::Roll && first.is_none() {
            return Err(if skipped { EditError::Collision } else { EditError::ClipNotFound });
        }
        *self = work;
        Ok(first.unwrap_or(Time::ZERO))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::Video;

    fn ab() -> (Timeline, Id, Id) {
        let (a, b) = (clip(0, 10, 0, Video, None, Some(1000)), clip(10, 10, 10, Video, None, Some(1000)));
        let ids = (a.id, b.id);
        (timeline(vec![track(Video, vec![a, b])]), ids.0, ids.1)
    }

    #[test]
    fn plain_w_ripples_later_clips_back() {
        let (mut tl, _, _) = ab();
        assert!(tl.trim_to_playhead(ClipEdge::Tail, s(7), None, PlayheadTrimMode::Ripple).is_ok());
        assert_eq!(spans(&tl.tracks[0]), [[0, 7], [7, 17]]);
    }

    #[test]
    fn shift_w_rolls_the_cut() {
        let (mut tl, a, b) = ab();
        assert_eq!(tl.trim_to_playhead(ClipEdge::Tail, s(7), None, PlayheadTrimMode::Roll), Ok(s(-3)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 7], [7, 20]]);
        assert_eq!(tl.duration(), s(20));
        // B's head now shows 3 s earlier source.
        assert_eq!(tl.tracks[0].clip(b).map(|c| c.source.start), Some(s(7)));
        assert_eq!(tl.tracks[0].clip(a).map(|c| c.source.duration), Some(s(7)));
    }

    #[test]
    fn opt_w_leaves_a_gap() {
        let (mut tl, _, _) = ab();
        assert!(tl.trim_to_playhead(ClipEdge::Tail, s(7), None, PlayheadTrimMode::Plain).is_ok());
        assert_eq!(spans(&tl.tracks[0]), [[0, 7], [10, 20]]);
    }

    #[test]
    fn shift_q_rolls_the_cut_later() {
        let (mut tl, _, _) = ab();
        assert!(tl.trim_to_playhead(ClipEdge::Head, s(13), None, PlayheadTrimMode::Roll).is_ok());
        assert_eq!(spans(&tl.tracks[0]), [[0, 13], [13, 20]]);
    }

    #[test]
    fn opt_q_leaves_a_gap_before_the_clip() {
        let (mut tl, _, _) = ab();
        assert!(tl.trim_to_playhead(ClipEdge::Head, s(13), None, PlayheadTrimMode::Plain).is_ok());
        assert_eq!(spans(&tl.tracks[0]), [[0, 10], [13, 20]]);
    }

    #[test]
    fn roll_without_a_neighbour_is_refused() {
        let mut tl = timeline(vec![track(Video, vec![clip(0, 10, 0, Video, None, Some(1000))])]);
        let before = tl.clone();
        assert_eq!(tl.trim_to_playhead(ClipEdge::Tail, s(7), None, PlayheadTrimMode::Roll), Err(EditError::Collision));
        assert_eq!(tl, before);
    }

    #[test]
    fn a_locked_track_refuses_every_mode() {
        for mode in [PlayheadTrimMode::Ripple, PlayheadTrimMode::Roll, PlayheadTrimMode::Plain] {
            let mut tl = timeline(vec![locked(track(Video, vec![v(0, 10), v(10, 10)]))]);
            let id = tl.tracks[0].id;
            assert_eq!(tl.trim_to_playhead(ClipEdge::Tail, s(7), Some(&[id]), mode), Err(EditError::TrackLocked));
        }
    }
}
