//! Port of `Timeline+FastCutStorylines.swift`: Final Cut differences that need no stored item. Everything here is
//! derived from positions and attachments, so the project file stays as it is.
//!
//! - Gap item: a hole on V1 is the host of the clips attached inside it (`main_gaps`, `is_gap_attached`). The edit
//!   engine keeps such clips when the clip before the hole is deleted (they follow the hole), Delete on the gap
//!   deletes them.
//! - Storyline: a run of two or more touching attached clips on one non-main track (`storylines`). Create, ripple
//!   delete and rearrange work inside the run and never touch the main track.
//! - Position move: overwrite without rippling, leaves a hole behind (`position_move`).

use crate::timeline_edits::TimelineEditsExt as _;
use crate::timeline_magnetic::{MagneticExt, MagneticScope, MagneticStay};
use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{Clip, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// A hole on the main track with the clips attached to it (see `main_gaps`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MainGap {
    /// The hole.
    pub range: TimeRange,
    /// The main clip right before the hole; `None` for a hole at the head of the main track.
    pub before: Option<Id>,
    /// The main clip right after the hole.
    pub after: Id,
    /// Clips whose attach time lies in the hole, earliest first.
    pub attached: Vec<Id>,
}

/// A connected storyline: touching attached clips on one lane (see `storylines`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Storyline {
    /// The lane.
    pub track: Id,
    /// The clips, earliest first.
    pub clips: Vec<Id>,
    /// From the first clip's start to the last clip's end.
    pub range: TimeRange,
}

/// `extension Timeline` of `Timeline+FastCutStorylines.swift`.
pub trait FastCutStorylinesExt {
    /// Every hole of the main track (leading hole included, space after the last clip is not one) with the clips attached
    /// in it. Empty in Normal mode.
    fn main_gaps(&self) -> Vec<MainGap>;
    /// True when the clip's attach time lies in a hole of the main track (it hangs on the gap, not on a clip).
    fn is_gap_attached(&self, id: Id) -> bool;
    /// The connected storylines: two or more touching clips on one non-main track, linked partners of main clips left out.
    /// Empty in Normal mode.
    fn storylines(&self) -> Vec<Storyline>;
    /// The storyline `id` belongs to; `None` for a lone clip, a main clip or a clip that does not exist.
    fn storyline_containing(&self, id: Id) -> Option<Storyline>;
    /// Create Storyline (Cmd+G): two or more attached clips of one kind go onto the lane of the earliest one, on their own
    /// frames (a hole between them stays a hole: positions are the truth). Fails with `ClipNotFound` for fewer than two
    /// attachable clips, `WrongTrackKind` for mixed kinds or outside Fast Cut, `TrackLocked`, `Collision` when
    /// something else already sits there.
    fn create_storyline(&mut self, ids: &BTreeSet<Id>, id_source: &mut dyn IdSource) -> Result<(), EditError>;
    /// Ripple delete inside a storyline (the connected clips after it close up; the main track and everything outside
    /// the run stay). The clip's linked group leaves with it. Fails with `ClipNotFound` when `id` is in no storyline.
    fn storyline_ripple_delete(&mut self, id: Id, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Rearrange inside a storyline: the clip goes to the storyline edit nearest to `t`, the others close up around it.
    fn storyline_rearrange(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Position move (FCP's Position tool): the clip (with its linked partners) lands at `t` overwriting what is there and
    /// leaves a hole behind; nothing ripples, attached clips stay on their frames. The main track never gets a hole after
    /// its last clip: `t` is clamped to the end of the others. Normal: the plain overwrite move.
    fn position_move(&mut self, id: Id, t: Time, track: Option<Id>, ids: &mut dyn IdSource) -> Result<(), EditError>;
}

fn flush(run: &mut Vec<&Clip>, track: Id, out: &mut Vec<Storyline>) {
    if let (true, Some(first), Some(last)) = (run.len() >= 2, run.first(), run.last()) {
        out.push(Storyline {
            track,
            clips: run.iter().map(|c| c.id).collect(),
            range: TimeRange::from_end(first.start, last.timeline().end()),
        });
    }
    run.clear();
}

/// Moves clips by a delta (and optionally to another track index) without covering anything: they are lifted out,
/// `removing` is dropped, and each is put back, failing with `Collision` when a clip that stayed is in the way and
/// `TrackLocked` for a locked lane. `with_partners`: linked partners of a moved clip shift by the same delta on their own
/// tracks. Transitions leaning on lifted clips come back where both sides are still adjacent.
fn relocate(
    tl: &mut Timeline,
    moves: &[(Id, Time, Option<usize>)],
    removing: &BTreeSet<Id>,
    with_partners: bool,
    ids: &mut dyn IdSource,
) -> Result<(), EditError> {
    let mut items: Vec<(Clip, usize)> = Vec::new();
    let mut seen = BTreeSet::new();
    for &(id, delta, track) in moves {
        let found = tl.find(id).ok_or(EditError::ClipNotFound)?;
        let mut group = vec![found];
        if with_partners && let Ok(g) = tl.linked_group(id) {
            group = g;
        }
        for g in group {
            if !seen.insert(g.clip.id) || removing.contains(&g.clip.id) {
                continue;
            }
            let mut c = g.clip.clone();
            c.start += delta;
            if c.start < Time::ZERO {
                return Err(EditError::Collision);
            }
            let mut ti = g.track;
            if g.clip.id == id
                && let Some(to) = track
            {
                if tl.tracks[to].kind != c.kind {
                    return Err(EditError::WrongTrackKind);
                }
                ti = to;
            }
            if tl.tracks[g.track].is_locked || tl.tracks[ti].is_locked {
                return Err(EditError::TrackLocked);
            }
            items.push((c, ti));
        }
    }
    for id in removing {
        if tl.find(*id).is_some_and(|f| tl.tracks[f.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
    }
    let mut work = tl.clone();
    let lifted: BTreeSet<Id> = seen.union(removing).copied().collect();
    let stashed = work.lift_out(&lifted);
    for (clip, track) in items {
        let r = clip.timeline();
        if work.tracks[track].clips().iter().any(|c| c.timeline().overlaps(&r)) {
            return Err(EditError::Collision);
        }
        work.tracks[track].overwrite(clip, ids)?;
    }
    work.restore_magnetic(&stashed);
    if !work.tracks.iter().all(|t| t.is_consistent()) {
        return Err(EditError::Collision);
    }
    *tl = work;
    Ok(())
}

impl FastCutStorylinesExt for Timeline {
    fn main_gaps(&self) -> Vec<MainGap> {
        let Some(mi) = self.main_track_index().filter(|_| self.is_fast_cut()) else { return Vec::new() };
        let mut d = self.clone();
        d.derive_attachments();
        let main = d.tracks[mi].clips();
        let attached: Vec<(Id, Time)> = d
            .tracks
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != mi)
            .flat_map(|(_, t)| t.clips())
            .filter_map(|c| c.attachment.as_ref().map(|a| (c.id, c.start + a.point)))
            .collect();
        let mut out = Vec::new();
        for (k, next) in main.iter().enumerate() {
            let from = if k == 0 { Time::ZERO } else { main[k - 1].timeline().end() };
            if next.start <= from {
                continue;
            }
            let r = TimeRange::from_end(from, next.start);
            let mut inside: Vec<&(Id, Time)> = attached.iter().filter(|a| r.contains(a.1)).collect();
            inside.sort_by_key(|a| a.1);
            out.push(MainGap {
                range: r,
                before: (k > 0).then(|| main[k - 1].id),
                after: next.id,
                attached: inside.iter().map(|a| a.0).collect(),
            });
        }
        out
    }

    fn is_gap_attached(&self, id: Id) -> bool {
        self.main_gaps().iter().any(|g| g.attached.contains(&id))
    }

    fn storylines(&self) -> Vec<Storyline> {
        let Some(mi) = self.main_track_index().filter(|_| self.is_fast_cut()) else { return Vec::new() };
        let mut out = Vec::new();
        for (_, t) in self.tracks.iter().enumerate().filter(|(i, _)| *i != mi) {
            let mut clips: Vec<&Clip> = t.clips().iter().filter(|c| self.is_attachable(c.id)).collect();
            clips.sort_by_key(|c| c.start);
            let mut run: Vec<&Clip> = Vec::new();
            for c in clips {
                if run.last().is_some_and(|last| last.timeline().end() != c.start) {
                    flush(&mut run, t.id, &mut out);
                }
                run.push(c);
            }
            flush(&mut run, t.id, &mut out);
        }
        out.sort_by_key(|s| s.range.start);
        out
    }

    fn storyline_containing(&self, id: Id) -> Option<Storyline> {
        self.storylines().into_iter().find(|s| s.clips.contains(&id))
    }

    fn create_storyline(&mut self, ids: &BTreeSet<Id>, id_source: &mut dyn IdSource) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            return Err(EditError::WrongTrackKind);
        }
        let members: Vec<_> = ids.iter().filter_map(|i| self.find(*i)).collect();
        if members.len() < 2 || !members.iter().all(|m| self.is_attachable(m.clip.id)) {
            return Err(EditError::ClipNotFound);
        }
        if members.iter().any(|m| m.clip.kind != members[0].clip.kind) {
            return Err(EditError::WrongTrackKind);
        }
        let home = members.iter().min_by_key(|m| m.clip.start).map(|m| m.track).ok_or(EditError::ClipNotFound)?;
        let mut work = self.clone();
        let moves: Vec<_> = members.iter().map(|m| (m.clip.id, Time::ZERO, Some(home))).collect();
        relocate(&mut work, &moves, &BTreeSet::new(), false, id_source)?;
        work.derive_attachments();
        *self = work;
        Ok(())
    }

    fn storyline_ripple_delete(&mut self, id: Id, ids: &mut dyn IdSource) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            return Err(EditError::WrongTrackKind);
        }
        let (Some(line), Some(c)) = (self.storyline_containing(id), self.find(id).map(|m| m.clip)) else {
            return Err(EditError::ClipNotFound);
        };
        let later = line.clips.iter().skip_while(|x| **x != id).skip(1);
        let mut work = self.clone();
        let gone: BTreeSet<Id> = match self.linked_group(id) {
            Ok(g) => g.iter().map(|m| m.clip.id).collect(),
            Err(_) => [id].into(),
        };
        let moves: Vec<_> = later.map(|l| (*l, -c.timeline().duration, None)).collect();
        relocate(&mut work, &moves, &gone, true, ids)?;
        work.derive_attachments();
        *self = work;
        Ok(())
    }

    fn storyline_rearrange(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            return Err(EditError::WrongTrackKind);
        }
        let (Some(line), Some(c)) = (self.storyline_containing(id), self.find(id).map(|m| m.clip)) else {
            return Err(EditError::ClipNotFound);
        };
        let others: Vec<Clip> =
            line.clips.iter().filter(|x| **x != id).filter_map(|x| self.find(*x).map(|m| m.clip)).collect();
        // Edit positions of the run without the moved clip, laid back to back from the run start.
        let mut edges = vec![line.range.start];
        for o in &others {
            edges.push(edges[edges.len() - 1] + o.timeline().duration);
        }
        let slot =
            (0..edges.len()).min_by_key(|&i| (if edges[i] < t { t - edges[i] } else { edges[i] - t }, i)).unwrap_or(0);
        let mut order = others;
        order.insert(slot, c);
        let mut cursor = line.range.start;
        let mut moves = Vec::new();
        for o in &order {
            if o.start != cursor {
                moves.push((o.id, cursor - o.start, None));
            }
            cursor += o.timeline().duration;
        }
        if moves.is_empty() {
            return Ok(());
        }
        let mut work = self.clone();
        relocate(&mut work, &moves, &BTreeSet::new(), true, ids)?;
        work.derive_attachments();
        *self = work;
        Ok(())
    }

    fn position_move(&mut self, id: Id, t: Time, track: Option<Id>, ids: &mut dyn IdSource) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            self.move_clip(id, t, track, &BTreeMap::new(), None, ids)?;
            return Ok(());
        }
        let mi = self.main_track_index().filter(|_| self.find(id).is_some()).ok_or(EditError::ClipNotFound)?;
        let mut at = t.max(Time::ZERO);
        if self.is_main_material(id) && track.is_none_or(|tr| tr == self.tracks[mi].id) {
            let end = self.tracks[mi].clips().iter().filter(|c| c.id != id).map(|c| c.timeline().end()).max();
            at = at.min(end.unwrap_or(Time::ZERO));
        }
        let mut work = self.clone();
        let scope = MagneticScope { involving: [id].into(), stay: MagneticStay::All, ..MagneticScope::default() };
        work.magnetic_edit(scope, ids, |tl, ids| tl.move_clip(id, at, track, &BTreeMap::new(), None, ids))?;
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_magnetic::{MagneticOrphans, MagneticScope};
    use crate::timeline_magnetic_ops::fixture::{clip, d, fd, s};
    use sq_core_model::{ClipAttachment, SequenceFormat, TimelineEditMode, Track, TrackKind};
    use sq_core_time::SequentialIds;

    struct Fx {
        tl: Timeline,
        ids: SequentialIds,
    }

    /// One video clip at `start` for `len` seconds (30 fps fixtures), optionally attached to `(host, point)`.
    fn vclip(ids: &mut SequentialIds, start: f64, len: f64, attach: Option<(Id, f64)>) -> Clip {
        let media = ids.next_id();
        let mut c = clip(ids, TrackKind::Video, start, len, None, media);
        c.attachment = attach.map(|(h, p)| ClipAttachment::new(h, s(p)));
        c
    }

    fn fast_cut(ids: &mut SequentialIds, lanes: Vec<Vec<Clip>>) -> Timeline {
        let tracks = lanes
            .into_iter()
            .map(|clips| {
                let mut t = Track::new(ids.next_id(), TrackKind::Video);
                t.set_clips(clips);
                t
            })
            .collect();
        let mut tl = Timeline::new(ids.next_id(), "S", SequenceFormat::new(fd()), tracks);
        tl.set_edit_mode_stored(TimelineEditMode::Magnetic);
        tl
    }

    fn start(tl: &Timeline, id: Id) -> Option<f64> {
        tl.find(id).map(|m| d(m.clip.start))
    }

    /// V1: c1 0-4 | hole 4-6 | c2 6-10;  V2: inGap 4.5-5.5 (attach time in the hole), inside 1-2 (on c1).
    struct Gap {
        fx: Fx,
        c1: Id,
        c2: Id,
        in_gap: Id,
        inside: Id,
    }

    fn gap() -> Gap {
        let mut ids = SequentialIds::default();
        let c1 = vclip(&mut ids, 0.0, 4.0, None);
        let c2 = vclip(&mut ids, 6.0, 4.0, None);
        let inside = vclip(&mut ids, 1.0, 1.0, Some((c1.id, 0.0)));
        let in_gap = vclip(&mut ids, 4.5, 1.0, Some((c1.id, 0.0)));
        let g = (c1.id, c2.id, in_gap.id, inside.id);
        let tl = fast_cut(&mut ids, vec![vec![c1, c2], vec![inside, in_gap]]);
        Gap { fx: Fx { tl, ids }, c1: g.0, c2: g.1, in_gap: g.2, inside: g.3 }
    }

    #[test]
    fn main_gaps_list_the_hole_with_its_attached_clips() {
        let g = gap();
        let tl = &g.fx.tl;
        let gaps = tl.main_gaps();
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].range, TimeRange::from_end(s(4.0), s(6.0)));
        assert_eq!(gaps[0].before, Some(g.c1));
        assert_eq!(gaps[0].after, g.c2);
        assert_eq!(gaps[0].attached, vec![g.in_gap]);
        assert!(tl.is_gap_attached(g.in_gap));
        assert!(!tl.is_gap_attached(g.inside));
    }

    #[test]
    fn normal_sequence_has_no_gap_items() {
        let mut g = gap();
        g.fx.tl.set_edit_mode_stored(TimelineEditMode::Normal);
        assert!(g.fx.tl.main_gaps().is_empty());
        assert!(g.fx.tl.storylines().is_empty());
    }

    #[test]
    fn deleting_the_clip_before_a_gap_keeps_the_clips_attached_to_the_gap() {
        let mut g = gap();
        let hosts: BTreeSet<Id> = [g.c1].into();
        let scope = MagneticScope { orphans: MagneticOrphans::Delete, ..Default::default() };
        g.fx.tl.magnetic_edit(scope, &mut g.fx.ids, |tl, _| tl.ripple_delete_main(&hosts)).unwrap();
        let tl = &g.fx.tl;
        assert!(tl.find(g.inside).is_none()); // attached to the clip itself: goes with it
        let kept = start(tl, g.in_gap).unwrap(); // attached to the gap: stays in it
        let c2 = start(tl, g.c2).unwrap();
        assert_eq!(c2 - kept, 1.5); // same distance before c2 as before
        assert!(tl.is_attachment_valid(g.in_gap));
        assert_eq!(tl.main_gaps().first().map(|x| x.attached.clone()), Some(vec![g.in_gap]));
    }

    /// V1: c1 0-4, c2 4-8, c3 8-12.  V2: s1 5-6, s2 6-8, s3 8-9 (one run), s4 10-11 (apart).  V3: u 6.5-7.5 (lone).
    struct Lines {
        fx: Fx,
        c1: Id,
        s: [Id; 4],
        u: Id,
    }

    fn lines() -> Lines {
        let mut ids = SequentialIds::default();
        let v1: Vec<Clip> =
            [(0.0, 4.0), (4.0, 4.0), (8.0, 4.0)].iter().map(|&(a, l)| vclip(&mut ids, a, l, None)).collect();
        let v2: Vec<Clip> = [(5.0, 1.0), (6.0, 2.0), (8.0, 1.0), (10.0, 1.0)]
            .iter()
            .map(|&(a, l)| vclip(&mut ids, a, l, None))
            .collect();
        let u = vclip(&mut ids, 6.5, 1.0, None);
        let (c1, sid, uid) = (v1[0].id, [v2[0].id, v2[1].id, v2[2].id, v2[3].id], u.id);
        let mut tl = fast_cut(&mut ids, vec![v1, v2, vec![u]]);
        tl.derive_attachments();
        Lines { fx: Fx { tl, ids }, c1, s: sid, u: uid }
    }

    #[test]
    fn a_run_of_touching_attached_clips_is_a_storyline() {
        let l = lines();
        let found = l.fx.tl.storylines();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].clips, vec![l.s[0], l.s[1], l.s[2]]);
        assert_eq!(found[0].range, TimeRange::from_end(s(5.0), s(9.0)));
        assert_eq!(l.fx.tl.storyline_containing(l.s[1]).map(|x| x.clips.len()), Some(3));
        assert!(l.fx.tl.storyline_containing(l.s[3]).is_none());
        assert!(l.fx.tl.storyline_containing(l.c1).is_none());
    }

    #[test]
    fn ripple_delete_closes_the_storyline_only() {
        let mut l = lines();
        l.fx.tl.storyline_ripple_delete(l.s[1], &mut l.fx.ids).unwrap();
        let tl = &l.fx.tl;
        assert!(tl.find(l.s[1]).is_none());
        assert_eq!(start(tl, l.s[0]), Some(5.0));
        assert_eq!(start(tl, l.s[2]), Some(6.0));
        assert_eq!(start(tl, l.s[3]), Some(10.0)); // apart from the run: not moved
        assert_eq!(start(tl, tl.tracks[0].clips()[1].id), Some(4.0)); // main track untouched
        assert!(tl.is_attachment_valid(l.s[2]));
    }

    #[test]
    fn rearrange_reorders_inside_the_storyline() {
        let mut l = lines();
        l.fx.tl.storyline_rearrange(l.s[2], s(5.0), &mut l.fx.ids).unwrap();
        let tl = &l.fx.tl;
        assert_eq!(start(tl, l.s[2]), Some(5.0));
        assert_eq!(start(tl, l.s[0]), Some(6.0));
        assert_eq!(start(tl, l.s[1]), Some(7.0));
        assert!(tl.tracks.iter().all(Track::is_consistent));
        assert_eq!(tl.storyline_containing(l.s[0]).map(|x| x.range), Some(TimeRange::from_end(s(5.0), s(9.0))));
    }

    #[test]
    fn create_gathers_touching_clips_on_one_lane() {
        let mut l = lines();
        let pick: BTreeSet<Id> = [l.s[3], l.u].into();
        l.fx.tl.create_storyline(&pick, &mut l.fx.ids).unwrap();
        let tl = &l.fx.tl;
        assert_eq!(tl.find(l.s[3]).map(|m| m.track), tl.find(l.u).map(|m| m.track));
        assert!(tl.tracks.iter().all(Track::is_consistent));
    }

    #[test]
    fn create_touching_pair_is_one_storyline() {
        let mut l = lines();
        let u = vclip(&mut l.fx.ids, 9.0, 1.0, None); // u 9-10 touches s3 and s4
        let uid = u.id;
        let mut lane = Track::new(l.fx.ids.next_id(), TrackKind::Video);
        lane.set_clips(vec![u]);
        l.fx.tl.tracks[2] = lane;
        l.fx.tl.derive_attachments();
        l.fx.tl.create_storyline(&[uid, l.s[0]].into(), &mut l.fx.ids).unwrap();
        assert_eq!(l.fx.tl.find(uid).map(|m| m.track), l.fx.tl.find(l.s[0]).map(|m| m.track));
        assert!(l.fx.tl.storyline_containing(uid).is_some());
    }

    #[test]
    fn create_needs_two_attached_clips_and_fast_cut() {
        let mut l = lines();
        assert_eq!(l.fx.tl.create_storyline(&[l.s[0]].into(), &mut l.fx.ids), Err(EditError::ClipNotFound));
        assert_eq!(l.fx.tl.create_storyline(&[l.s[0], l.c1].into(), &mut l.fx.ids), Err(EditError::ClipNotFound));
        l.fx.tl.set_edit_mode_stored(TimelineEditMode::Normal);
        assert_eq!(l.fx.tl.storyline_ripple_delete(l.s[1], &mut l.fx.ids), Err(EditError::WrongTrackKind));
        assert!(l.fx.tl.storylines().is_empty());
    }

    #[test]
    fn position_move_leaves_a_hole_behind_and_clamps_to_the_end_of_the_others() {
        let mut ids = SequentialIds::default();
        let a = vclip(&mut ids, 0.0, 4.0, None);
        let b = vclip(&mut ids, 4.0, 4.0, None);
        let c = vclip(&mut ids, 8.0, 4.0, None);
        let (b_id, c_id) = (b.id, c.id);
        let mut tl = fast_cut(&mut ids, vec![vec![a, b, c]]);
        tl.position_move(b_id, Time::new(20, 1), None, &mut ids).unwrap();
        // b is clamped to the end of the other main clips (12 s): no hole after the last clip.
        assert_eq!(start(&tl, b_id), Some(12.0));
        assert_eq!(start(&tl, c_id), Some(8.0));
    }
}
