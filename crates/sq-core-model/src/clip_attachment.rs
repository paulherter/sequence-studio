// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ClipAttachment.swift
//
// Fast Cut model (docs/research/FCP-MAGNETIC-TIMELINE.md section 5.3): a sequence is either Normal (classic tracks) or
// magnetic ("Fast Cut" in the UI). In Fast Cut the first video track (V1) is the main track; a clip on any other track is an
// attached clip that stores which main-track clip it belongs to (`ClipAttachment::host`) and where (`point`, from the
// attached clip's own start). Positions stay the only truth for where a clip is: an attachment is checked against the
// positions (`is_attachment_valid`) and re-derived when it no longer fits. Normal mode ignores attachments but keeps them.

use crate::{Clip, EditError, Project, Timeline, Track, TrackKind};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Time};
use std::collections::{BTreeMap, BTreeSet};

/// Ties a clip on a non-main track to a main-track clip (Fast Cut).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ClipAttachment {
    /// The main-track (V1) clip this clip follows.
    pub host: Id,
    /// The attach point, as timeline time from the attached clip's own start; negative for a linked member that
    /// starts after the shared attach time.
    pub point: Time,
}

/// Edit mode of a sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TimelineEditMode {
    /// Classic tracks: every edit verb as it has always been.
    Normal,
    /// Fast Cut: V1 is magnetic, clips on other tracks are attached to V1 clips.
    Magnetic,
}

impl ClipAttachment {
    /// An attachment to `host` at `point` (timeline time from the attached clip's own start).
    pub fn new(host: Id, point: Time) -> ClipAttachment {
        ClipAttachment { host, point }
    }
}

impl Timeline {
    /// The sequence's edit rules (v67). Default `Normal`, which stores nothing.
    pub fn edit_mode(&self) -> TimelineEditMode {
        self.edit_mode_store.unwrap_or(TimelineEditMode::Normal)
    }

    /// Stores the edit rules (`Normal` as absent) without deriving attachments; `set_edit_mode` is the Fast Cut switch.
    pub fn set_edit_mode_stored(&mut self, mode: TimelineEditMode) {
        self.edit_mode_store = (mode != TimelineEditMode::Normal).then_some(mode);
    }

    /// The main track of Fast Cut: the first video track (V1), empty or not. `None` when the sequence has no video track.
    pub fn main_track_id(&self) -> Option<Id> {
        self.main_track_index().map(|i| self.tracks[i].id)
    }

    /// Index of `main_track_id` in `tracks`.
    pub fn main_track_index(&self) -> Option<usize> {
        self.tracks.iter().position(|t| t.kind == crate::TrackKind::Video)
    }

    /// True when the clip can carry an attachment: it is not on the main track and not linked to a main-track clip (camera
    /// audio linked to a V1 clip is part of the main track through its link). False for an unknown id.
    pub fn is_attachable(&self, id: Id) -> bool {
        let Some(m) = self.find(id) else { return false };
        let Some(mi) = self.main_track_index() else { return false };
        if m.track == mi {
            return false;
        }
        !m.clip.link.is_some_and(|l| self.tracks[mi].clips().iter().any(|c| c.link == Some(l)))
    }

    /// The main-track clip an attach time `t` belongs to: the clip under `t`, in a hole the clip before it, before the
    /// first clip the first clip. `None` when the main track is empty or missing.
    pub fn attach_host(&self, t: Time) -> Option<Id> {
        let main = self.tracks[self.main_track_index()?].clips();
        main.iter().rev().find(|c| c.start <= t).or(main.first()).map(|c| c.id)
    }

    /// True when `id`'s attachment fits the positions: the clip is attachable, its host is on the main track, the attach
    /// time (`start + point`) lies on the host or in the hole right after it (for the first main-track clip also in the
    /// leading hole before it), the attach time lies within the clip (within its linked group's span for a group), and
    /// every attachable member of its linked group stores the same host and attach time. False without an attachment.
    pub fn is_attachment_valid(&self, id: Id) -> bool {
        let Some(c) = self.find(id).map(|m| m.clip) else { return false };
        let (Some(a), true, Some(mi)) = (&c.attachment, self.is_attachable(id), self.main_track_index()) else {
            return false;
        };
        let main = self.tracks[mi].clips();
        let Some(hi) = main.iter().position(|m| m.id == a.host) else { return false };
        let t = c.start + a.point;
        if hi > 0 && t < main[hi].start {
            return false;
        }
        if hi + 1 < main.len() && t >= main[hi + 1].start {
            return false;
        }
        let group = self.attach_group(&c);
        let lo = group.iter().map(|m| m.start).min();
        let end = group.iter().map(|m| m.timeline().end()).max();
        let (Some(lo), Some(end)) = (lo, end) else { return false };
        if t < lo || t > end {
            return false;
        }
        group.iter().all(|m| m.attachment.as_ref().is_some_and(|x| x.host == a.host && m.start + x.point == t))
    }

    /// The attachable clips that attach as one with `c`: its linked partners off the main track, `c` included.
    fn attach_group<'a>(&'a self, c: &'a Clip) -> Vec<&'a Clip> {
        let (Some(l), Some(mi)) = (c.link, self.main_track_index()) else { return vec![c] };
        let off_main = self.tracks.iter().enumerate().filter(|(i, _)| *i != mi).flat_map(|(_, t)| t.clips());
        off_main.filter(|m| m.link == Some(l)).collect()
    }

    /// True when any clip carries an attachment.
    pub fn has_attachments(&self) -> bool {
        self.tracks.iter().any(|t| t.clips().iter().any(|c| c.attachment.is_some()))
    }

    /// Makes every attachment fit the positions; moves no clip. Valid attachments stay as they are. A clip on the main
    /// track or linked to a main-track clip loses its attachment. Every other clip (a linked group as one) whose
    /// attachment is missing or invalid gets one derived from where it is: the attach time is the stored one when it
    /// still lies within the clip (group), else the clip's (group's earliest) start, and the host is `attach_host`.
    /// With an empty or missing main track every attachment is dropped. Fast Cut edits call this first.
    pub fn derive_attachments(&mut self) {
        let Some(mi) = self.main_track_index() else {
            for t in &mut self.tracks {
                t.map_clips_keeping_timing(|c| Clip { attachment: None, ..c.clone() });
            }
            return;
        };
        let main_links: BTreeSet<Id> = self.tracks[mi].clips().iter().filter_map(|c| c.link).collect();
        let mut decided: BTreeMap<Id, Option<ClipAttachment>> = BTreeMap::new();
        // Groups in timeline order, keyed by link (or the clip itself).
        let mut groups: BTreeMap<Id, Vec<Clip>> = BTreeMap::new();
        let mut order: Vec<Id> = Vec::new();
        let off_main = || self.tracks.iter().enumerate().filter(|(i, _)| *i != mi).flat_map(|(_, t)| t.clips());
        for c in off_main() {
            if c.link.is_some_and(|l| main_links.contains(&l)) {
                decided.insert(c.id, None);
                continue;
            }
            let key = c.link.unwrap_or(c.id);
            if !groups.contains_key(&key) {
                order.push(key);
            }
            groups.entry(key).or_default().push(c.clone());
        }
        // `is_attachment_valid` per member, with the lookups indexed once (it searches every track per call).
        let main = self.tracks[mi].clips();
        let mut main_index: BTreeMap<Id, usize> = BTreeMap::new();
        for (k, c) in main.iter().enumerate() {
            main_index.entry(c.id).or_insert(k);
        }
        let mut linked: BTreeMap<Id, Vec<&Clip>> = BTreeMap::new();
        for c in off_main() {
            if let Some(l) = c.link {
                linked.entry(l).or_default().push(c);
            }
        }
        let is_valid = |c: &Clip| -> bool {
            let Some(a) = &c.attachment else { return false };
            let Some(&hi) = main_index.get(&a.host) else { return false };
            let t = c.start + a.point;
            if hi > 0 && t < main[hi].start {
                return false;
            }
            if hi + 1 < main.len() && t >= main[hi + 1].start {
                return false;
            }
            let single = [c];
            let group: &[&Clip] = c.link.and_then(|l| linked.get(&l)).map_or(&single[..], |g| &g[..]);
            let lo = group.iter().map(|m| m.start).min();
            let end = group.iter().map(|m| m.timeline().end()).max();
            let (Some(lo), Some(end)) = (lo, end) else { return false };
            t >= lo
                && t <= end
                && group
                    .iter()
                    .all(|m| m.attachment.as_ref().is_some_and(|x| x.host == a.host && m.start + x.point == t))
        };
        for key in order {
            let mut members = groups.remove(&key).unwrap_or_default();
            members.sort_by_key(|m| m.start);
            if members.iter().all(&is_valid) {
                for m in &members {
                    decided.insert(m.id, m.attachment.clone());
                }
                continue;
            }
            let (Some(lo), Some(end)) =
                (members.iter().map(|m| m.start).min(), members.iter().map(|m| m.timeline().end()).max())
            else {
                continue;
            };
            let stored = members
                .iter()
                .filter_map(|m| m.attachment.as_ref().map(|a| m.start + a.point))
                .find(|t| *t >= lo && *t <= end);
            let t = stored.unwrap_or(lo);
            let host = self.attach_host(t);
            for m in &members {
                decided.insert(m.id, host.map(|h| ClipAttachment { host: h, point: t - m.start }));
            }
        }
        for (i, track) in self.tracks.iter_mut().enumerate() {
            track.map_clips_keeping_timing(|c| Clip {
                attachment: if i == mi { None } else { decided.get(&c.id).cloned().flatten() },
                ..c.clone()
            });
        }
    }

    /// Switches the edit rules; moves no clip. Entering Fast Cut derives the attachments from where the clips are
    /// (`derive_attachments`); leaving it keeps them (Normal ignores them).
    pub fn set_edit_mode(&mut self, mode: TimelineEditMode) {
        self.set_edit_mode_stored(mode);
        if mode == TimelineEditMode::Magnetic {
            self.derive_attachments();
        }
    }

    /// Rewrites attachment hosts through `map` (old clip id to new) after clips got new ids. A host missing from the map
    /// drops the attachment (re-derived at the next Fast Cut edit) unless `keep_unmapped`. `only`: limit to these clips
    /// (`None` = every clip).
    #[doc(hidden)]
    pub fn remap_attachments(&mut self, map: &BTreeMap<Id, Id>, only: Option<&BTreeSet<Id>>, keep_unmapped: bool) {
        for t in self.tracks.iter_mut().filter(|t| t.clips().iter().any(|c| c.attachment.is_some())) {
            t.map_clips_keeping_timing(|c| {
                let Some(a) = &c.attachment else { return c.clone() };
                if only.is_some_and(|o| !o.contains(&c.id)) || (keep_unmapped && !map.contains_key(&a.host)) {
                    return c.clone();
                }
                let mut c = c.clone();
                c.remap_attachment(map);
                c
            });
        }
    }

    /// Drops every attachment whose host is not a clip of this sequence (clips moved into a new sequence).
    #[doc(hidden)]
    pub fn drop_attachments_to_missing_hosts(&mut self) {
        let ids: BTreeMap<Id, Id> = self.tracks.iter().flat_map(|t| t.clips()).map(|c| (c.id, c.id)).collect();
        self.remap_attachments(&ids, None, false);
    }
}

impl Clip {
    /// `attachment` with its host rewritten through `map`; `None` when the host is not in it.
    #[doc(hidden)]
    pub fn remap_attachment(&mut self, map: &BTreeMap<Id, Id>) {
        self.attachment =
            self.attachment.take().and_then(|a| map.get(&a.host).map(|h| ClipAttachment { host: *h, point: a.point }));
    }
}

impl Project {
    /// Switches one sequence's edit rules (`Timeline::set_edit_mode`); moves no clip.
    pub fn set_edit_mode(&mut self, mode: TimelineEditMode, timeline: Id) -> Result<(), EditError> {
        let t = self.timelines.iter_mut().find(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        t.set_edit_mode(mode);
        Ok(())
    }
}

/// Fast Cut invariant: a clip on the main track (first video track) carries no attachment. Edits that place clips (move,
/// insert, overwrite, paste, lane moves) end with this, so a clip moved or copied onto V1 drops its attachment.
pub fn clear_main_track_attachments(tracks: &mut [Track]) {
    let Some(mi) = tracks.iter().position(|t| t.kind == TrackKind::Video) else { return };
    if tracks[mi].clips().iter().any(|c| c.attachment.is_some()) {
        tracks[mi].map_clips_keeping_timing(|c| Clip { attachment: None, ..c.clone() });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn attachment_round_trips() {
        assert_round_trip::<ClipAttachment>(json!({
            "host": "00000000-0000-0000-0000-000000000009", "point": {"value": -1, "timescale": 10}}));
    }

    #[test]
    fn edit_mode_uses_the_raw_names() {
        assert_round_trip::<TimelineEditMode>(json!("magnetic"));
    }

    use crate::nesting::test_util::*;

    // V1: c1 2-5 | c2 5-8 | hole 8-10 | c3 10-13
    // V2: lead 0-1 (leading hole), t1 6-7 (on c2), t2 9-9.5 (hole after c2), tail 14-15 (after the last clip)
    // V3: broll 3.5-4.5, linked with music on A2 3-6 (group attach time 3 -> c1)
    // A1: c1Sound 2-5, linked with c1 (camera audio: part of the main track)
    const C1: u32 = 1;
    const C2: u32 = 2;
    const C3: u32 = 3;
    const C1_SOUND: u32 = 4;
    const LEAD: u32 = 5;
    const T1: u32 = 6;
    const T2: u32 = 7;
    const TAIL: u32 = 8;
    const BROLL: u32 = 9;
    const MUSIC: u32 = 10;

    /// The fixture timeline; `attachments` are `(clip, host, point in tenths of a second)`.
    fn fixture(attachments: &[(u32, u32, i64)]) -> Timeline {
        let clip = |n: u32, kind: &str, start: i64, len: i64, link: Option<u32>| {
            let mut c = json!({"id": id(n), "name": "x", "media": id(300), "kind": kind,
                "source": {"start": time(0, 10), "duration": time(len, 10)}, "start": time(start, 10),
                "mediaDuration": time(1000, 10)});
            if let Some(l) = link {
                c["link"] = json!(id(l));
            }
            if let Some((_, host, point)) = attachments.iter().find(|a| a.0 == n) {
                c["attachment"] = json!({"host": id(*host), "point": time(*point, 10)});
            }
            c
        };
        let tracks = vec![
            track_json(
                21,
                "video",
                vec![
                    clip(C1, "video", 20, 30, Some(201)),
                    clip(C2, "video", 50, 30, None),
                    clip(C3, "video", 100, 30, None),
                ],
            ),
            track_json(
                22,
                "video",
                vec![
                    clip(LEAD, "video", 0, 10, None),
                    clip(T1, "video", 60, 10, None),
                    clip(T2, "video", 90, 5, None),
                    clip(TAIL, "video", 140, 10, None),
                ],
            ),
            track_json(23, "video", vec![clip(BROLL, "video", 35, 10, Some(202))]),
            track_json(24, "audio", vec![clip(C1_SOUND, "audio", 20, 30, Some(201))]),
            track_json(25, "audio", vec![clip(MUSIC, "audio", 30, 30, Some(202))]),
        ];
        let mut p = project_json(vec![], vec![timeline_json(1, tracks)]);
        p.timelines.remove(0)
    }

    fn valid(attachments: &[(u32, u32, i64)], clip: u32) -> bool {
        fixture(attachments).is_attachment_valid(id(clip))
    }

    #[test]
    fn edit_mode_defaults_to_normal_and_stores_only_magnetic() {
        let mut t = fixture(&[]);
        assert_eq!(t.edit_mode(), TimelineEditMode::Normal);
        t.set_edit_mode_stored(TimelineEditMode::Magnetic);
        assert_eq!(t.edit_mode_store, Some(TimelineEditMode::Magnetic));
        t.set_edit_mode_stored(TimelineEditMode::Normal);
        assert_eq!(t.edit_mode_store, None);
    }

    #[test]
    fn main_track_is_the_first_video_track_even_when_empty() {
        let mut t = fixture(&[]);
        assert_eq!((t.main_track_id(), t.main_track_index()), (Some(id(21)), Some(0)));
        t.tracks.remove(0);
        assert_eq!(t.main_track_id(), Some(id(22)));
        t.tracks.retain(|x| x.kind == crate::TrackKind::Audio);
        assert_eq!(t.main_track_id(), None);
    }

    #[test]
    fn attachable_excludes_main_track_and_camera_audio() {
        let t = fixture(&[]);
        assert!(!t.is_attachable(id(C1)));
        assert!(!t.is_attachable(id(C1_SOUND)));
        assert!(t.is_attachable(id(T1)));
        assert!(t.is_attachable(id(MUSIC)));
        assert!(!t.is_attachable(id(999)));
    }

    #[test]
    fn attach_host_rule() {
        let t = fixture(&[]);
        let host = |tenths| t.attach_host(Time::new(tenths, 10));
        assert_eq!(host(0), Some(id(C1)), "leading hole: the first clip");
        assert_eq!(host(20), Some(id(C1)));
        assert_eq!(host(50), Some(id(C2)), "a cut belongs to the clip that starts there");
        assert_eq!(host(90), Some(id(C2)), "hole: the clip before it");
        assert_eq!(host(200), Some(id(C3)), "after the last clip");
        let mut empty = fixture(&[]);
        empty.tracks[0] =
            serde_json::from_value(track_json(21, "video", vec![])).unwrap_or_else(|_| empty.tracks[0].clone());
        assert_eq!(empty.attach_host(Time::new(3, 1)), None);
    }

    #[test]
    fn validity_follows_the_positions() {
        assert!(!valid(&[], T1), "none stored");
        assert!(valid(&[(T1, C2, 0)], T1), "on the host");
        assert!(!valid(&[(T1, C1, 0)], T1), "on another clip");
        assert!(valid(&[(T2, C2, 0)], T2), "the hole after the host");
        assert!(!valid(&[(T2, C3, 0)], T2), "the hole before the host");
        assert!(valid(&[(LEAD, C1, 0)], LEAD), "leading hole: first clip");
        assert!(valid(&[(TAIL, C3, 0)], TAIL), "after the last clip");
        assert!(!valid(&[(T1, 999, 0)], T1), "host gone");
        assert!(!valid(&[(T1, T2, 0)], T1), "host not on the main track");
        assert!(!valid(&[(T1, C2, 20)], T1), "point past the clip's end");
        assert!(valid(&[(T1, C2, 10)], T1), "point at the clip's end");
        assert!(!valid(&[(T1, C2, -5)], T1), "point before the clip");
        assert!(!valid(&[(C1_SOUND, C1, 0)], C1_SOUND), "camera audio never attaches");
    }

    #[test]
    fn a_linked_group_must_agree() {
        // music starts at 3.0, broll at 3.5: attach time 3.0 -> c1.
        assert!(valid(&[(MUSIC, C1, 0), (BROLL, C1, -5)], MUSIC));
        assert!(valid(&[(MUSIC, C1, 0), (BROLL, C1, -5)], BROLL));
        assert!(!valid(&[(MUSIC, C1, 0), (BROLL, C1, 0)], MUSIC), "3.5 disagrees");
        assert!(!valid(&[(MUSIC, C1, 0), (BROLL, C1, 0)], BROLL));
        assert!(!valid(&[(MUSIC, C1, 0)], MUSIC), "a member without attachment");
        assert!(fixture(&[(MUSIC, C1, 0)]).has_attachments() && !fixture(&[]).has_attachments());
    }

    fn att(t: &Timeline, clip: u32) -> Option<ClipAttachment> {
        t.find(id(clip)).and_then(|m| m.clip.attachment)
    }

    fn to(host: u32, tenths: i64) -> Option<ClipAttachment> {
        Some(ClipAttachment::new(id(host), Time::new(tenths, 10)))
    }

    fn set(t: &mut Timeline, clip: u32, a: Option<ClipAttachment>) {
        if let Some(m) = t.find(id(clip)) {
            t.tracks[m.track].map_clips_keeping_timing(|c| Clip {
                attachment: if c.id == id(clip) { a.clone() } else { c.attachment.clone() },
                ..c.clone()
            });
        }
    }

    fn positions(t: &Timeline) -> Vec<Vec<(Id, sq_core_time::TimeRange)>> {
        t.tracks.iter().map(|tr| tr.clips().iter().map(|c| (c.id, c.timeline())).collect()).collect()
    }

    #[test]
    fn derive_from_positions() {
        let mut t = fixture(&[]);
        let before = positions(&t);
        t.derive_attachments();
        assert_eq!(positions(&t), before);
        assert_eq!(att(&t, LEAD), to(C1, 0));
        assert_eq!(att(&t, T1), to(C2, 0));
        assert_eq!(att(&t, T2), to(C2, 0));
        assert_eq!(att(&t, TAIL), to(C3, 0));
        assert_eq!(att(&t, MUSIC), to(C1, 0));
        assert_eq!(att(&t, BROLL), to(C1, -5));
        assert!(att(&t, C1).is_none() && att(&t, C2).is_none() && att(&t, C1_SOUND).is_none());
        for c in [LEAD, T1, T2, TAIL, MUSIC, BROLL] {
            assert!(t.is_attachment_valid(id(c)));
        }
    }

    #[test]
    fn derive_keeps_valid_and_rederives_invalid_keeping_the_point() {
        let mut t = fixture(&[]);
        set(&mut t, T1, to(C2, 5)); // valid, not point 0
        set(&mut t, T2, to(C1, 2)); // wrong host (Swift uses 0.25 s; tenths here)
        set(&mut t, LEAD, to(777, 50)); // gone host, point outside the clip
        set(&mut t, C2, to(C1, 0)); // main-track clip
        set(&mut t, C1_SOUND, to(C1, 0)); // camera audio
        t.derive_attachments();
        assert_eq!(att(&t, T1), to(C2, 5));
        assert_eq!(att(&t, T2), to(C2, 2));
        assert_eq!(att(&t, LEAD), to(C1, 0));
        assert!(att(&t, C2).is_none());
        assert!(att(&t, C1_SOUND).is_none());
    }

    #[test]
    fn derive_keeps_a_groups_stored_attach_time() {
        let mut t = fixture(&[]);
        set(&mut t, BROLL, to(777, 5)); // attach time 4, inside the group span
        t.derive_attachments();
        assert_eq!(att(&t, BROLL), to(C1, 5));
        assert_eq!(att(&t, MUSIC), to(C1, 10));
    }

    #[test]
    fn derive_after_a_move_rehosts() {
        let mut t = fixture(&[]);
        t.derive_attachments();
        // Normal-mode move of t1 over c3: the stored attachment stays (invalid) until the next derive.
        t.tracks[1].map_clips_keeping_timing(|c| Clip {
            start: if c.id == id(T1) { Time::new(11, 1) } else { c.start },
            ..c.clone()
        });
        assert_eq!(att(&t, T1).map(|a| a.host), Some(id(C2)));
        assert!(!t.is_attachment_valid(id(T1)));
        t.derive_attachments();
        assert_eq!(att(&t, T1), to(C3, 0));
    }

    #[test]
    fn derive_with_an_empty_main_track_drops_everything() {
        let mut t = fixture(&[]);
        t.derive_attachments();
        t.tracks[0] = Track::new(id(21), crate::TrackKind::Video);
        t.derive_attachments();
        assert!(t.tracks.iter().flat_map(|tr| tr.clips()).all(|c| c.attachment.is_none()));
    }

    #[test]
    fn switching_modes_moves_no_clip_and_leaving_keeps_attachments() {
        let f = fixture(&[]);
        let mut p = project_json(vec![], vec![]);
        p.timelines.push(f.clone());
        assert!(p.set_edit_mode(TimelineEditMode::Magnetic, f.id).is_ok());
        let on = p.timelines[0].clone();
        assert_eq!(on.edit_mode(), TimelineEditMode::Magnetic);
        assert_eq!(positions(&on), positions(&f));
        assert!(on.has_attachments());
        assert!(p.set_edit_mode(TimelineEditMode::Normal, f.id).is_ok());
        let off = &p.timelines[0];
        assert_eq!(off.edit_mode(), TimelineEditMode::Normal);
        let all = |t: &Timeline| {
            t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.attachment.clone())).collect::<Vec<_>>()
        };
        assert_eq!(all(off), all(&on));
        assert_eq!(p.set_edit_mode(TimelineEditMode::Magnetic, id(404)), Err(EditError::TimelineNotFound));
    }

    #[test]
    fn remapping_rewrites_hosts_drops_unmapped_ones_and_clearing_the_main_track_works() {
        let mut t = fixture(&[]);
        t.derive_attachments();
        let map = BTreeMap::from([(id(C2), id(50))]);
        let mut only = t.clone();
        only.remap_attachments(&map, None, true);
        assert_eq!(att(&only, T1), to(50, 0));
        assert_eq!(att(&only, LEAD), to(C1, 0), "unmapped host kept");
        t.remap_attachments(&map, None, false);
        assert_eq!(att(&t, LEAD), None, "unmapped host dropped");
        t.drop_attachments_to_missing_hosts();
        assert_eq!(att(&t, T1), None, "host 50 is not a clip of this sequence");
        set(&mut t, C2, to(C1, 0));
        clear_main_track_attachments(&mut t.tracks);
        assert!(att(&t, C2).is_none());
    }
}
