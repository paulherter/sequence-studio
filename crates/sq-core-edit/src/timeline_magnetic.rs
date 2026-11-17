//! Port of `Timeline+Magnetic.swift`: the Fast Cut engine. Fast Cut is the stored mode (`edit_mode() == Magnetic`) and
//! decides who follows whom by the stored attachments, not by sync lock. `magnetic_edit` is the one engine every Fast
//! Cut verb runs through.

use crate::timeline_add_track::AddTrackExt;
use sq_core_model::{Clip, EditError, Timeline, TimelineEditMode, Transition, clear_main_track_attachments};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// What happens to attached clips whose host left the main track and has no surviving piece.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum MagneticOrphans {
    /// Deleted with their host (Delete on a main-track clip, FCP).
    Delete,
    /// Stay on their timeline frame and re-attach to the clip now under it.
    Stay,
    /// Move like the next surviving main-track clip, never before the end of the one before.
    #[default]
    Follow,
}

/// Which attached clips stay on their timeline frame during an edit instead of following their host.
#[derive(Clone, Debug, PartialEq, Default)]
pub enum MagneticStay {
    /// Every attached clip follows its host.
    #[default]
    None,
    /// Every attached clip stays (overwrite, roll, slip, lift: nothing moves along the main track).
    All,
    /// The clips attached to these hosts stay (the "keep attached" override: hold ` while deleting or dragging).
    Hosts(BTreeSet<Id>),
    /// The clips whose attach time lies in this range stay (Delete on a spacer with the override).
    Range(TimeRange),
}

impl MagneticStay {
    fn contains(&self, host: Id, time: Time) -> bool {
        match self {
            MagneticStay::None => false,
            MagneticStay::All => true,
            MagneticStay::Hosts(s) => s.contains(&host),
            MagneticStay::Range(r) => r.contains(time),
        }
    }
}

/// The optional arguments of `magnetic_edit` (Swift default arguments: `involving: []`, `local: false`, `stay: .none`,
/// `orphans: .follow`).
#[derive(Clone, Debug, Default)]
pub struct MagneticScope {
    /// Clips the edit works on directly; they (and their linked partners) are not lifted out.
    pub involving: BTreeSet<Id>,
    /// The edit works on the involved clips' own tracks only (trim, roll, slip, slide, nudge of attached clips): every
    /// clip on those tracks stays in the edit as a plain clip, so the involved clips see their neighbors.
    pub local: bool,
    /// Which attached groups keep their timeline frame.
    pub stay: MagneticStay,
    /// What happens to groups whose host is gone.
    pub orphans: MagneticOrphans,
}

/// `extension Timeline` of `Timeline+Magnetic.swift`.
pub trait MagneticExt {
    /// Puts the transitions of attached clips back after placement. A fade (one side) follows its clip to whatever track it
    /// landed on. A transition between two clips is kept only when both stayed adjacent on one track (the same cut);
    /// when they landed on different tracks or apart, it is dropped deliberately: there is no cut to dissolve over.
    fn restore_magnetic(&mut self, stashed: &[Transition]);

    /// Runs `edit` with the Fast Cut rules: the attached clips (not in `scope.involving`, not on locked tracks) are
    /// taken out, the edit runs on the main track and the clips it works on (sync lock is on for every unlocked track
    /// meanwhile, so camera audio of later main clips ripples with them; the flags are kept), then every attached group
    /// goes back relative to its host: to the same content frame of the host (a head trim keeps the picture in sync),
    /// clamped to the host; in the hole after it, the same distance after its end; into the piece of the host that now
    /// holds the frame when the edit cut it. `stay` groups keep their timeline frame; a group whose host is gone follows
    /// `orphans`. Groups go back without covering anything: their own track when free, else the nearest free track of
    /// their kind (never the main track, a new track when none is free). Clips the edit made off the main track (pasted,
    /// cut halves) yield to the groups that were there. Then every attachment is re-derived from the positions (host =
    /// main clip under the attach time). Normal mode or no main track: `edit` alone. Returns the error of `edit`;
    /// nothing changes then. A linked group with a member on a locked track keeps its place whole (its unlocked
    /// members do not ripple), so its J/L offset survives.
    ///
    /// `edit` gets the id source too, so a verb needs only one borrow of it.
    fn magnetic_edit<T>(
        &mut self,
        scope: MagneticScope,
        ids: &mut dyn IdSource,
        edit: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<T, EditError>,
    ) -> Result<T, EditError>;

    /// Removes `ids` from their tracks and returns their transitions (those leaning only on them), for `restore_magnetic`.
    fn lift_out(&mut self, ids: &BTreeSet<Id>) -> Vec<Transition>;

    /// Places a clip without covering anything: on `preferring` when free, else the nearest free unlocked track of its
    /// kind (never the main track), else a new track. For the Fast Cut verbs that move clips off the main track.
    fn place_attached(&mut self, c: Clip, preferring: Id, ids: &mut dyn IdSource) -> Result<(), EditError>;
}

/// Timeline time the clip's head moved into its content (positive = head trimmed shorter). Zero for speed ramps.
fn magnetic_head_shift(old: &Clip, new: &Clip) -> Time {
    if old.speed_keys.is_some() || new.speed_keys.is_some() || old.speed != new.speed || old.reversed != new.reversed {
        return Time::ZERO;
    }
    let d = if old.reversed { old.source.end() - new.source.end() } else { new.source.start - old.source.start };
    if old.speed.is_normal() { d } else { old.speed.unscale(d) }
}

/// `magnetic_head_shift`, zero when the content changed (replace: other media or sequence).
fn content_shift(old: &Clip, new: &Clip) -> Time {
    if old.media != new.media || old.sequence != new.sequence {
        return Time::ZERO;
    }
    magnetic_head_shift(old, new)
}

/// Puts an attached clip back without covering anything: its own track when free, else the nearest free unlocked track
/// of its kind (not the main track; above first), else a new track. Its transitions are put back by `restore_magnetic`.
fn place_magnetic(
    tl: &mut Timeline,
    c: Clip,
    track_id: Id,
    spine: Id,
    ids: &mut dyn IdSource,
) -> Result<(), EditError> {
    let range = c.timeline();
    let free = |tl: &Timeline, i: usize| {
        let t = &tl.tracks[i];
        t.kind == c.kind && !t.is_locked && t.id != spine && !t.clips().iter().any(|x| x.timeline().overlaps(&range))
    };
    let home = tl.tracks.iter().position(|t| t.id == track_id);
    let target = match home {
        Some(h) if free(tl, h) => Some(h),
        _ => {
            let origin = home.unwrap_or(tl.tracks.len());
            // Nearest first; on a tie the track further up (larger index).
            (0..tl.tracks.len()).filter(|&i| free(tl, i)).min_by_key(|&i| (i.abs_diff(origin), std::cmp::Reverse(i)))
        }
    };
    let target = match target {
        Some(t) => t,
        None => {
            tl.add_track(c.kind, ids);
            tl.tracks.len() - 1
        }
    };
    tl.tracks[target].overwrite(c, ids)
}

struct AttachedGroup {
    members: Vec<(Id, Clip)>,
    start: Time,
    /// Attach time.
    time: Time,
    host: Clip,
    host_index: usize,
}

impl AttachedGroup {
    fn offset(&self) -> Time {
        self.time - self.host.start
    }
}

impl MagneticExt for Timeline {
    fn restore_magnetic(&mut self, stashed: &[Transition]) {
        let mut touched = BTreeSet::new();
        for t in stashed {
            let Some(first) = t.outgoing.or(t.incoming) else { continue };
            let Some(ti) = self.tracks.iter().position(|tr| tr.clip(first).is_some()) else { continue };
            if let (Some(o), Some(i)) = (t.outgoing, t.incoming) {
                let (Some(co), Some(ci)) = (self.tracks[ti].clip(o), self.tracks[ti].clip(i)) else { continue };
                if co.timeline().end() != ci.start {
                    continue;
                }
            }
            self.tracks[ti].transitions.push(t.clone());
            touched.insert(ti);
        }
        let fd = self.format.frame_duration;
        for ti in touched {
            self.tracks[ti].prune_transitions(fd);
        }
    }

    fn magnetic_edit<T>(
        &mut self,
        scope: MagneticScope,
        ids: &mut dyn IdSource,
        edit: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<T, EditError>,
    ) -> Result<T, EditError> {
        let MagneticScope { involving, local, stay, orphans } = scope;
        let Some(mi) = self.main_track_index().filter(|_| self.edit_mode() == TimelineEditMode::Magnetic) else {
            return edit(self, ids);
        };
        let mut base = self.clone();
        base.derive_attachments();
        let main_id = base.tracks[mi].id;
        let main_clips: Vec<Clip> = base.tracks[mi].clips().to_vec();
        let old_main_ids: BTreeSet<Id> = main_clips.iter().map(|c| c.id).collect();
        let base_ids: BTreeSet<Id> = base.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
        let mut involved = involving.clone();
        let involved_links: BTreeSet<Id> =
            involving.iter().filter_map(|i| base.find(*i).and_then(|m| m.clip.link)).collect();
        for t in &base.tracks {
            for c in t.clips().iter().filter(|c| c.link.is_some_and(|l| involved_links.contains(&l))) {
                involved.insert(c.id);
            }
        }

        // Tracks a local edit works on: their clips are not lifted out.
        let local_tracks: BTreeSet<usize> = if local {
            (0..base.tracks.len())
                .filter(|&i| i != mi && base.tracks[i].clips().iter().any(|c| involved.contains(&c.id)))
                .collect()
        } else {
            BTreeSet::new()
        };
        let main_links: BTreeSet<Id> = main_clips.iter().filter_map(|c| c.link).collect();

        // Attached groups (by link), whole or not at all.
        let mut by_key: BTreeMap<Id, Vec<(Id, Clip)>> = BTreeMap::new();
        let mut order: Vec<Id> = Vec::new();
        let mut refused = BTreeSet::new();
        let mut locked_keys = BTreeSet::new();
        let mut worked_keys = BTreeSet::new();
        // Linked clips off the main track, unlocked. Swift keeps a Dictionary here; the BTreeMap only orders ties of `pinned`.
        let mut linked_off: BTreeMap<Id, Vec<(Id, Clip)>> = BTreeMap::new();
        for (i, t) in base.tracks.iter().enumerate().filter(|(i, _)| *i != mi) {
            for c in t.clips() {
                let key = c.link.unwrap_or(c.id);
                let worked = involved.contains(&c.id) || local_tracks.contains(&i);
                if t.is_locked {
                    locked_keys.insert(key);
                }
                if worked {
                    worked_keys.insert(key);
                }
                if let Some(l) = c.link
                    && !t.is_locked
                    && !main_links.contains(&l)
                {
                    linked_off.entry(l).or_default().push((t.id, c.clone()));
                }
                if c.attachment.is_none() {
                    continue;
                }
                if t.is_locked || worked {
                    refused.insert(key);
                    continue;
                }
                if !by_key.contains_key(&key) {
                    order.push(key);
                }
                by_key.entry(key).or_default().push((t.id, c.clone()));
            }
        }
        // A linked group with a member on a locked track stays whole where it is: its unlocked members are set aside
        // during the edit (so they do not ripple away from the locked ones) and go back on their frame.
        let mut pinned: Vec<(Id, Clip)> = linked_off
            .into_iter()
            .filter(|(k, _)| locked_keys.contains(k) && !worked_keys.contains(k))
            .flat_map(|(_, v)| v)
            .collect();
        pinned.sort_by_key(|p| p.1.start);
        let mut groups: Vec<AttachedGroup> = Vec::new();
        for key in order.iter().filter(|k| !refused.contains(k)) {
            let Some(members) = by_key.remove(key) else { continue };
            let Some(a) = members.first().and_then(|m| m.1.attachment.clone()) else { continue };
            let Some(hi) = main_clips.iter().position(|c| c.id == a.host) else { continue };
            let Some(start) = members.iter().map(|m| m.1.start).min() else { continue };
            let time = members[0].1.start + a.point;
            groups.push(AttachedGroup { members, start, time, host: main_clips[hi].clone(), host_index: hi });
        }

        let mut work = base.clone();
        let lifted: BTreeSet<Id> =
            groups.iter().flat_map(|g| g.members.iter().map(|m| m.1.id)).chain(pinned.iter().map(|p| p.1.id)).collect();
        let mut stashed = work.lift_out(&lifted);
        let sync_locks: BTreeMap<Id, bool> = work.tracks.iter().map(|t| (t.id, t.sync_lock)).collect();
        for t in &mut work.tracks {
            t.sync_lock = true;
        }
        let result = edit(&mut work, ids)?;
        for t in &mut work.tracks {
            t.sync_lock = sync_locks.get(&t.id).copied().unwrap_or(t.sync_lock);
        }

        // Clips the edit made off the main track: they yield to the groups that were there.
        let wmi = work.tracks.iter().position(|t| t.id == main_id).ok_or(EditError::TrackLocked)?;
        let mut newcomers: Vec<(Id, Clip)> = Vec::new();
        for t in work.tracks.iter().enumerate().filter(|(i, _)| *i != wmi).map(|(_, t)| t) {
            for c in t.clips() {
                if !base_ids.contains(&c.id) && work.is_attachable(c.id) {
                    newcomers.push((t.id, c.clone()));
                }
            }
        }
        let newcomer_ids: BTreeSet<Id> = newcomers.iter().map(|n| n.1.id).collect();
        stashed.extend(work.lift_out(&newcomer_ids));

        let new_main: Vec<Clip> = work.tracks[wmi].clips().to_vec();
        let now = |id: Id| new_main.iter().find(|c| c.id == id);
        let frame = self.frame_duration();
        let sources_before: BTreeMap<Id, TimeRange> = main_clips.iter().map(|c| (c.id, c.source)).collect();

        // The timeline time the source frame `offset` into `old` now plays at: a new piece of it (cut by the edit), else a
        // surviving clip whose source grew over it (joined). Constant-speed, forward clips only.
        let content_piece = |old: &Clip, offset: Time| -> Option<Time> {
            if old.speed_keys.is_some() || old.reversed || offset < Time::ZERO {
                return None;
            }
            let point = old.source.start + if old.speed.is_normal() { offset } else { old.speed.scale(offset) };
            let fresh = new_main.iter().filter(|c| !old_main_ids.contains(&c.id));
            let grown = new_main.iter().filter(|c| sources_before.get(&c.id).is_some_and(|s| *s != c.source));
            for p in fresh.chain(grown) {
                if p.media == old.media
                    && p.kind == old.kind
                    && p.sequence == old.sequence
                    && p.speed_keys.is_none()
                    && !p.reversed
                    && p.speed == old.speed
                    && p.source.start <= point
                    && point < p.source.end()
                {
                    let d = point - p.source.start;
                    return Some(p.start + if p.speed.is_normal() { d } else { p.speed.unscale(d) });
                }
            }
            None
        };

        let new_time = |g: &AttachedGroup| -> Option<Time> {
            if stay.contains(g.host.id, g.time) {
                return Some(g.time);
            }
            let old = &g.host;
            let offset = g.offset();
            if let Some(new) = now(old.id) {
                if offset < Time::ZERO {
                    return Some(new.start + offset); // leading hole
                }
                if offset >= old.duration() {
                    return Some(new.timeline().end() + (offset - old.duration())); // hole after it
                }
                let p = new.start + offset - content_shift(old, new);
                if (p >= new.timeline().end() || p < new.start)
                    && let Some(piece) = content_piece(old, offset)
                {
                    return Some(piece);
                }
                return Some(p.max(new.start).min((new.timeline().end() - frame).max(new.start)));
            }
            if let Some(piece) = content_piece(old, offset) {
                return Some(piece);
            }
            // A clip attached to the hole before or after its host hangs on the gap, not on the host: it survives the
            // host's deletion and moves like the clips after it (`main_gaps`).
            let on_gap = offset < Time::ZERO || offset >= old.duration();
            match orphans {
                MagneticOrphans::Delete if !on_gap => None,
                MagneticOrphans::Stay => Some(g.time),
                MagneticOrphans::Delete | MagneticOrphans::Follow => {
                    let later = main_clips[g.host_index + 1..].iter().find(|c| now(c.id).is_some());
                    let earlier = main_clips[..g.host_index].iter().rev().find(|c| now(c.id).is_some());
                    let mut delta = Time::ZERO;
                    if let Some((l, n)) = later.and_then(|l| now(l.id).map(|n| (l, n))) {
                        delta = n.start - l.start;
                    } else if let Some((e, n)) = earlier.and_then(|e| now(e.id).map(|n| (e, n))) {
                        delta = n.timeline().end() - e.timeline().end();
                    }
                    let mut p = g.time + delta;
                    if let Some(n) = earlier.and_then(|e| now(e.id)) {
                        p = p.max(n.timeline().end());
                    }
                    Some(p)
                }
            }
        };

        let mut placed = work.clone();
        // What does not move goes back first, so it keeps its track; then the moved groups, earliest first.
        let mut moves: Vec<(&AttachedGroup, Time)> = Vec::new();
        for g in &groups {
            let Some(t) = new_time(g) else { continue };
            let mut d = t - g.time;
            if g.start + d < Time::ZERO {
                d = Time::ZERO - g.start;
            }
            moves.push((g, d));
        }
        for (track, clip) in &pinned {
            place_magnetic(&mut placed, clip.clone(), *track, main_id, ids)?;
        }
        let (still, moving): (Vec<_>, Vec<_>) = moves.into_iter().partition(|m| m.1 == Time::ZERO);
        let mut ordered = still;
        ordered.sort_by_key(|m| m.0.start);
        let mut moving = moving;
        moving.sort_by_key(|m| m.0.start);
        ordered.extend(moving);
        for (g, d) in ordered {
            for (track, clip) in &g.members {
                let mut c = clip.clone();
                c.start += d;
                place_magnetic(&mut placed, c, *track, main_id, ids)?;
            }
        }
        newcomers.sort_by_key(|n| n.1.start);
        for (track, clip) in newcomers {
            place_magnetic(&mut placed, clip, track, main_id, ids)?;
        }
        placed.restore_magnetic(&stashed);
        clear_main_track_attachments(&mut placed.tracks);
        placed.derive_attachments();
        if !placed.tracks.iter().all(|t| t.is_consistent()) {
            return Err(EditError::Collision);
        }
        *self = placed;
        Ok(result)
    }

    fn lift_out(&mut self, ids: &BTreeSet<Id>) -> Vec<Transition> {
        if ids.is_empty() {
            return Vec::new();
        }
        let mut stashed = Vec::new();
        for t in &mut self.tracks {
            for c in t.clips().to_vec().iter().filter(|c| ids.contains(&c.id)) {
                t.remove(c.id);
            }
            let mine: Vec<Transition> = t
                .transitions
                .iter()
                .filter(|tr| {
                    let sides = [tr.outgoing, tr.incoming];
                    sides.iter().flatten().all(|s| ids.contains(s)) && (tr.outgoing.is_some() || tr.incoming.is_some())
                })
                .cloned()
                .collect();
            if !mine.is_empty() {
                t.transitions.retain(|tr| !mine.iter().any(|m| m.id == tr.id));
                stashed.extend(mine);
            }
        }
        stashed
    }

    fn place_attached(&mut self, c: Clip, preferring: Id, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let main = self.main_track_id().ok_or(EditError::WrongTrackKind)?;
        place_magnetic(self, c, preferring, main, ids)
    }
}

/// Builders shared by the tests of the Fast Cut modules.
#[cfg(test)]
pub(crate) mod test_support {
    use sq_core_model::{
        Clip, SequenceFormat, Timeline, TimelineEditMode, Track, TrackKind, Transition, TransitionAlignment,
        TransitionKind,
    };
    use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};

    /// Frames of 1/10 s keep the arithmetic readable.
    pub fn fd() -> Time {
        Time::new(1, 10)
    }

    pub fn secs(n: i64) -> Time {
        Time::new(n, 1)
    }

    pub fn clip(ids: &mut SequentialIds, kind: TrackKind, start: i64, len: i64) -> Clip {
        let media = ids.next_id();
        Clip::new(ids.next_id(), "c", media, kind, TimeRange::new(Time::ZERO, secs(len)), secs(start))
    }

    /// V1 (main), V2, A1, A2 in Fast Cut.
    pub fn fast_cut(ids: &mut SequentialIds) -> Timeline {
        let tracks = vec![
            Track::new(ids.next_id(), TrackKind::Video),
            Track::new(ids.next_id(), TrackKind::Video),
            Track::new(ids.next_id(), TrackKind::Audio),
            Track::new(ids.next_id(), TrackKind::Audio),
        ];
        let mut tl = Timeline::new(ids.next_id(), "T", SequenceFormat::new(fd()), tracks);
        tl.set_edit_mode_stored(TimelineEditMode::Magnetic);
        tl
    }

    /// A one-second cross dissolve between two clips (either side may be missing: a fade).
    pub fn dissolve(id: Id, outgoing: Option<Id>, incoming: Option<Id>) -> Transition {
        Transition {
            id,
            kind: TransitionKind::CrossDissolve,
            duration: Time::new(1, 1),
            alignment: TransitionAlignment::Center,
            custom_before: Time::ZERO,
            outgoing,
            incoming,
            easing: None,
            direction: None,
            reversed: None,
            softness: None,
            motion_blur: None,
            stinger: None,
            params: None,
            color: None,
            border_width: None,
            border_color: None,
        }
    }

    pub fn put(tl: &mut Timeline, track: usize, c: Clip, ids: &mut SequentialIds) -> Id {
        let id = c.id;
        tl.tracks[track].overwrite(c, ids).unwrap();
        id
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::SequentialIds;

    /// Main track A (0..4) B (4..8) with an attached clip on V2 at 5..6.
    fn setup(ids: &mut SequentialIds) -> (Timeline, Id, Id, Id) {
        let mut tl = fast_cut(ids);
        let a = put(&mut tl, 0, clip(ids, TrackKind::Video, 0, 4), ids);
        let b = put(&mut tl, 0, clip(ids, TrackKind::Video, 4, 4), ids);
        let over = put(&mut tl, 1, clip(ids, TrackKind::Video, 5, 1), ids);
        (tl, a, b, over)
    }

    #[test]
    fn attached_clip_follows_its_host_when_the_main_track_ripples() {
        let mut ids = SequentialIds::default();
        let (mut tl, a, b, over) = setup(&mut ids);
        tl.magnetic_edit(MagneticScope::default(), &mut ids, |tl, _| {
            tl.tracks[0].remove(a);
            tl.tracks[0].shift(secs(4), secs(-4), &BTreeSet::new());
            Ok(())
        })
        .unwrap();
        assert_eq!(tl.find(b).unwrap().clip.start, secs(0));
        assert_eq!(tl.find(over).unwrap().clip.start, secs(1));
        assert_eq!(tl.find(over).unwrap().clip.attachment.unwrap().host, b);
    }

    #[test]
    fn stay_all_keeps_the_attached_clip_on_its_frame() {
        let mut ids = SequentialIds::default();
        let (mut tl, a, _b, over) = setup(&mut ids);
        let scope = MagneticScope { stay: MagneticStay::All, ..Default::default() };
        tl.magnetic_edit(scope, &mut ids, |tl, _| {
            tl.tracks[0].remove(a);
            tl.tracks[0].shift(secs(4), secs(-4), &BTreeSet::new());
            Ok(())
        })
        .unwrap();
        assert_eq!(tl.find(over).unwrap().clip.start, secs(5));
    }

    #[test]
    fn orphan_of_a_deleted_host_is_deleted_or_follows() {
        let mut ids = SequentialIds::default();
        let (tl, _a, b, over) = setup(&mut ids);
        let run = |orphans| {
            let mut tl = tl.clone();
            let scope = MagneticScope { orphans, ..Default::default() };
            tl.magnetic_edit(scope, &mut SequentialIds::default(), |tl, _| {
                tl.tracks[0].remove(b);
                Ok(())
            })
            .unwrap();
            tl
        };
        assert!(run(MagneticOrphans::Delete).find(over).is_none());
        // The host was the last clip: nothing after it, the orphan keeps its frame (delta 0, not before the earlier end).
        assert_eq!(run(MagneticOrphans::Follow).find(over).unwrap().clip.start, secs(5));
    }

    #[test]
    fn an_error_of_the_edit_changes_nothing_and_normal_mode_runs_the_edit_alone() {
        let mut ids = SequentialIds::default();
        let (mut tl, a, _b, _over) = setup(&mut ids);
        let before = tl.clone();
        let r: Result<(), _> = tl.magnetic_edit(MagneticScope::default(), &mut ids, |tl, _| {
            tl.tracks[0].remove(a);
            Err(EditError::Collision)
        });
        assert_eq!(r, Err(EditError::Collision));
        assert_eq!(tl, before);
        tl.set_edit_mode_stored(TimelineEditMode::Normal);
        tl.magnetic_edit(MagneticScope::default(), &mut ids, |tl, _| {
            tl.tracks[0].remove(a);
            Ok(())
        })
        .unwrap();
        assert!(tl.find(a).is_none());
    }

    #[test]
    fn lifted_clip_that_would_collide_moves_to_a_free_track() {
        let mut ids = SequentialIds::default();
        let (mut tl, _a, _b, over) = setup(&mut ids);
        // A newcomer-free case: another attached clip is dropped on the attached one's frame by the edit.
        let blocker = clip(&mut ids, TrackKind::Video, 5, 1);
        tl.magnetic_edit(MagneticScope::default(), &mut ids, |tl, ids| tl.tracks[1].overwrite(blocker, ids)).unwrap();
        // The blocker was made by the edit off the main track and yields: the original stays on V2.
        let m = tl.find(over).unwrap();
        assert_eq!(m.track, 1);
        assert_eq!(tl.tracks.iter().map(|t| t.clips().len()).sum::<usize>(), 4);
    }

    #[test]
    fn lift_out_returns_the_transitions_that_lean_only_on_lifted_clips() {
        let mut ids = SequentialIds::default();
        let (mut tl, a, b, _over) = setup(&mut ids);
        let tr = dissolve(ids.next_id(), Some(a), Some(b));
        tl.tracks[0].transitions.push(tr.clone());
        let only_a: BTreeSet<Id> = [a].into();
        assert!(tl.lift_out(&only_a).is_empty());
        let both: BTreeSet<Id> = [a, b].into();
        assert_eq!(tl.lift_out(&both), vec![tr.clone()]);
        assert!(tl.tracks[0].transitions.is_empty() && tl.tracks[0].clips().is_empty());
    }
}
