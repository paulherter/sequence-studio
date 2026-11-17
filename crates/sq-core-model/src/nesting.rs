// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Nesting.swift

use crate::{BinItem, BinItemRef, Clip, EditError, Project, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

impl Timeline {
    /// The inside of a Group, not an ordinary sequence (Swift `isGroup`, Grouping.swift).
    pub fn is_group(&self) -> bool {
        self.group.is_some()
    }
}

/// Nested sequences: a clip whose `sequence` is set plays another timeline of the project.
impl Project {
    /// The sequences a user can pick (Export, opening, Project panel): everything but the inside of Groups, which only the
    /// group clip that plays one reaches (Ungroup, or a double click into it).
    pub fn pickable_timelines(&self) -> impl Iterator<Item = &Timeline> {
        self.timelines.iter().filter(|t| !t.is_group())
    }

    /// The Group a clip plays, if it plays one.
    pub fn group_sequence_of(&self, clip: &Clip) -> Option<&Timeline> {
        clip.sequence.and_then(|id| self.timeline(id)).filter(|t| t.is_group())
    }

    /// The timeline with `id`.
    pub fn timeline(&self, id: Id) -> Option<&Timeline> {
        self.timelines.iter().find(|t| t.id == id)
    }

    /// Sequences nested directly in `id` (one level).
    pub fn nested_sequences(&self, id: Id) -> BTreeSet<Id> {
        let Some(t) = self.timeline(id) else { return BTreeSet::new() };
        t.tracks.iter().flat_map(|tr| tr.clips()).filter_map(|c| c.sequence).collect()
    }

    /// Every sequence reachable from `id` through nesting (not including `id` unless it is on a cycle).
    pub fn reachable_sequences(&self, id: Id) -> BTreeSet<Id> {
        let mut seen = BTreeSet::new();
        let mut stack: Vec<Id> = self.nested_sequences(id).into_iter().collect();
        while let Some(n) = stack.pop() {
            if seen.insert(n) {
                stack.extend(self.nested_sequences(n));
            }
        }
        seen
    }

    /// True if `host` may not contain `sequence`: it is the same sequence or contains `host` somewhere inside.
    pub fn would_create_cycle(&self, sequence: Id, host: Id) -> bool {
        sequence == host || self.reachable_sequences(sequence).contains(&host)
    }

    /// True if no sequence contains itself, directly or indirectly.
    pub fn is_nesting_acyclic(&self) -> bool {
        self.timelines.iter().all(|t| !self.reachable_sequences(t.id).contains(&t.id))
    }

    /// Runs any timeline edit on a copy and commits it only if the result is valid: returns the edit's own error, or
    /// `NestingCycle` when a nested clip would make `id` contain itself. Use this for every edit that can place clips
    /// (insert, overwrite, paste, move between tracks).
    pub fn edit<F>(&mut self, id: Id, body: F) -> Result<(), EditError>
    where
        F: FnOnce(&mut Timeline) -> Result<(), EditError>,
    {
        let i = self.timelines.iter().position(|t| t.id == id).ok_or(EditError::TimelineNotFound)?;
        let mut work = self.clone();
        // A nested clip's media is the inner sequence as it is now, not as it was when nested.
        for ti in 0..work.timelines[i].tracks.len() {
            let clips = work.timelines[i].tracks[ti].clips().to_vec();
            for mut c in clips {
                let Some(d) = c.sequence.and_then(|inner| work.timeline(inner)).map(Timeline::duration) else {
                    continue;
                };
                if c.media_duration == Some(d) {
                    continue;
                }
                c.media_duration = Some(d);
                work.timelines[i].tracks[ti].replace(c);
            }
        }
        body(&mut work.timelines[i])?;
        work.timelines[i].prune_transitions();
        if work.reachable_sequences(id).contains(&id) {
            return Err(EditError::NestingCycle);
        }
        *self = work;
        Ok(())
    }

    /// Clips for placing `sequence` into another timeline at `start`: a video clip and, if the sequence has audio tracks
    /// with clips, a linked audio clip. Plays the whole sequence (0 ... duration). `None` for an unknown or empty
    /// sequence. Place them with `edit` so cycles are refused.
    pub fn sequence_clips(&self, sequence: Id, start: Time, ids: &mut dyn IdSource) -> Option<Vec<Clip>> {
        let t = self.timeline(sequence).filter(|t| t.duration() > Time::ZERO)?;
        let range = TimeRange::new(Time::ZERO, t.duration());
        let has_audio = t.tracks.iter().any(|x| x.kind == TrackKind::Audio && !x.clips().is_empty());
        let link = has_audio.then(|| ids.next_id());
        let mut make = |kind: TrackKind| {
            let mut c = Clip::new(ids.next_id(), &t.name, sequence, kind, range, start);
            c.link = link;
            c.media_duration = Some(t.duration());
            c.sequence = Some(sequence);
            c.angle = t.angles.as_ref().map(|a| a.first_choice(kind)); // an Angles sequence is placed as an Angles clip
            c
        };
        let video = make(TrackKind::Video);
        Some(if has_audio { vec![video, make(TrackKind::Audio)] } else { vec![video] })
    }

    // MARK: Nest

    /// Combine: replaces the selected clips (and their linked partners) with one nested-sequence clip.
    /// - The new sequence has the outer timeline's format, one track per involved track (same kind, name and flags, in the
    ///   same order) and the clips shifted so the earliest starts at 0.
    /// - The outer timeline gets a nested video clip on the lowest involved video track and, if audio was nested, a linked
    ///   nested audio clip on the lowest involved audio track, both covering earliest start ... latest end.
    /// - The sequence is filed in the bin of the outer sequence (root if it has none) and named "Combined NN" unless
    ///   `name` is given.
    ///
    /// Errors: `TrackLocked` if a clip is on a locked track, `Collision` if another (unselected) clip on a target track lies
    /// inside the nested span, `ClipNotFound`, `TimelineNotFound` or `EmptyClip` otherwise. Returns the new sequence's id.
    pub fn nest(
        &mut self,
        clips: &[Id],
        timeline_id: Id,
        name: Option<&str>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let ti = self.timelines.iter().position(|t| t.id == timeline_id).ok_or(EditError::TimelineNotFound)?;
        if clips.is_empty() {
            return Err(EditError::EmptyClip);
        }
        let mut tl = self.timelines[ti].clone();
        let mut selected = BTreeSet::new();
        for id in clips {
            selected.extend(tl.linked_group(*id)?.iter().map(|m| m.clip.id));
        }

        let involved: Vec<usize> =
            (0..tl.tracks.len()).filter(|i| tl.tracks[*i].clips().iter().any(|c| selected.contains(&c.id))).collect();
        if involved.iter().any(|i| tl.tracks[*i].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let picked: Vec<&Clip> =
            involved.iter().flat_map(|i| tl.tracks[*i].clips().iter().filter(|c| selected.contains(&c.id))).collect();
        let (Some(s), Some(e)) =
            (picked.iter().map(|c| c.start).min(), picked.iter().map(|c| c.timeline().end()).max())
        else {
            return Err(EditError::ClipNotFound);
        };
        let span = TimeRange::from_end(s, e);

        // Inner sequence.
        let mut inner: Vec<Track> = Vec::new();
        let mut track_ids: BTreeMap<Id, Id> = BTreeMap::new();
        for i in &involved {
            let t = &tl.tracks[*i];
            let moved: Vec<Clip> = t
                .clips()
                .iter()
                .filter(|c| selected.contains(&c.id))
                .map(|c| Clip { start: c.start - s, ..c.clone() })
                .collect();
            // Transitions between nested clips (and fades on them) go inside; one that joins a nested clip to a clip left
            // outside has no counterpart there and is dropped (below).
            let carried = t
                .transitions
                .iter()
                .filter(|tr| {
                    tr.outgoing.is_none_or(|o| selected.contains(&o))
                        && tr.incoming.is_none_or(|n| selected.contains(&n))
                })
                .cloned()
                .collect();
            let mut nt = Track::new(ids.next_id(), t.kind);
            nt.set_clips(moved);
            nt.sync_lock = t.sync_lock;
            nt.name = t.name.clone();
            nt.is_visible = t.is_visible;
            nt.is_muted = t.is_muted;
            nt.is_solo = t.is_solo;
            nt.height = t.height;
            nt.transitions = carried;
            track_ids.insert(t.id, nt.id);
            inner.push(nt);
        }
        let seq_id = ids.next_id();
        let seq_name = name.map_or_else(|| self.next_nested_name(), str::to_string);
        let mut seq = Timeline::new(seq_id, &seq_name, tl.format.clone(), inner);
        // The inner sequence gets the outer variants (same ids), so the nested clips keep their overrides and the variant
        // picture stays the same (evaluation renders the inner sequence in the variant of the same id).
        seq.variants = tl.variants.clone();
        // Picture masks follow their matte track inside; one whose track stays outside reads nothing.
        seq.remap_picture_masks(&track_ids);
        // Fast Cut attachments inside keep a host nested along; one whose host stays outside is dropped.
        seq.drop_attachments_to_missing_hosts();

        // Outer timeline: remove the clips, place the nested clip(s).
        for i in &involved {
            for id in &selected {
                tl.tracks[*i].remove(*id);
            }
        }
        let video_target = involved.iter().copied().find(|i| tl.tracks[*i].kind == TrackKind::Video);
        let audio_target = involved.iter().copied().find(|i| tl.tracks[*i].kind == TrackKind::Audio);
        let link = (video_target.is_some() && audio_target.is_some()).then(|| ids.next_id());
        let mut nested_video = None;
        for (target, kind) in [(video_target, TrackKind::Video), (audio_target, TrackKind::Audio)] {
            let Some(target) = target else { continue };
            if tl.tracks[target].clips().iter().any(|c| c.timeline().overlaps(&span)) {
                return Err(EditError::Collision);
            }
            let mut c = Clip::new(ids.next_id(), &seq_name, seq_id, kind, TimeRange::new(Time::ZERO, span.duration), s);
            c.link = link;
            c.media_duration = Some(span.duration);
            c.sequence = Some(seq_id);
            let nested_id = c.id;
            tl.tracks[target].overwrite(c, ids)?;
            if kind == TrackKind::Video {
                nested_video = Some(nested_id);
            }
        }
        // Outside clips attached to a nested clip now belong to the nested clip (the rest keep their hosts).
        if let Some(nv) = nested_video {
            let map: BTreeMap<Id, Id> = selected.iter().map(|id| (*id, nv)).collect();
            tl.remap_attachments(&map, None, true);
        }

        // Transitions naming a removed clip would dangle; only those go (others, even inactive ones, stay).
        for i in &involved {
            tl.tracks[*i].transitions.retain(|tr| {
                !(tr.outgoing.is_some_and(|o| selected.contains(&o))
                    || tr.incoming.is_some_and(|n| selected.contains(&n)))
            });
        }
        self.timelines[ti] = tl;
        self.timelines.push(seq);
        let bin = self.root_bin.parent_of(BinItemRef::Sequence(timeline_id)).unwrap_or(self.root_bin.id);
        if let Some(b) = self.root_bin.bin_mut(bin) {
            b.children.push(BinItem::Sequence(seq_id));
        }
        Ok(seq_id)
    }

    fn next_nested_name(&self) -> String {
        let names: BTreeSet<&str> = self.timelines.iter().map(|t| t.name.as_str()).collect();
        let mut n = 1;
        while names.contains(format!("Combined {n:02}").as_str()) {
            n += 1;
        }
        format!("Combined {n:02}")
    }
}

#[cfg(test)]
pub(crate) mod test_util {
    use crate::Project;
    use serde_json::json;
    use sq_core_time::{Id, IdSource};

    /// Hands out `id(n)`, `id(n + 1)`, ... so new ids never meet the fixed ids of a test.
    pub(crate) struct TestIds(pub(crate) u32);

    impl IdSource for TestIds {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            id(self.0)
        }
    }

    /// The id `00000000-0000-0000-0000-<n>`.
    pub(crate) fn id(n: u32) -> Id {
        Id::parse(&format!("00000000-0000-0000-0000-{n:012}")).unwrap_or(Id::NIL)
    }

    pub(crate) fn time(v: i64, scale: i64) -> serde_json::Value {
        json!({"value": v, "timescale": scale})
    }

    /// A clip of media `media` (a nested clip when `sequence` is set), one second long, starting at `start` seconds.
    pub(crate) fn clip_json(n: u32, media: u32, kind: &str, start: i64, sequence: Option<u32>) -> serde_json::Value {
        let mut c = json!({"id": id(n), "name": "c", "media": id(media), "kind": kind,
            "source": {"start": time(0, 1), "duration": time(1, 1)}, "start": time(start, 1)});
        if let Some(s) = sequence {
            c["sequence"] = json!(id(s));
        }
        c
    }

    pub(crate) fn timeline_json(n: u32, tracks: Vec<serde_json::Value>) -> serde_json::Value {
        json!({"id": id(n), "name": format!("T{n}"),
               "format": {"width": 1920, "height": 1080, "frameDuration": time(1, 30), "audioSampleRate": 48000},
               "tracks": tracks})
    }

    pub(crate) fn track_json(n: u32, kind: &str, clips: Vec<serde_json::Value>) -> serde_json::Value {
        json!({"id": id(n), "kind": kind, "clips": clips})
    }

    pub(crate) fn project_json(media: Vec<serde_json::Value>, timelines: Vec<serde_json::Value>) -> Project {
        serde_json::from_value(json!({"id": id(999), "name": "P", "media": media, "timelines": timelines}))
            .unwrap_or_else(|e| panic!("test project: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::test_util::*;
    use super::*;

    /// Timelines 1.. each nesting the listed sequences.
    fn project(nesting: &[(u32, &[u32])]) -> Project {
        let timelines = nesting
            .iter()
            .map(|(n, inner)| {
                let clips = inner
                    .iter()
                    .enumerate()
                    .map(|(k, s)| clip_json(n * 10 + k as u32, *s, "video", k as i64, Some(*s)))
                    .collect();
                timeline_json(*n, vec![track_json(50 + n, "video", clips)])
            })
            .collect();
        project_json(vec![], timelines)
    }

    fn ids(ns: &[u32]) -> BTreeSet<Id> {
        ns.iter().map(|n| id(*n)).collect()
    }

    #[test]
    fn the_inside_of_a_group_is_not_pickable() {
        let mut p = project(&[(1, &[2]), (2, &[])]);
        assert_eq!(p.pickable_timelines().count(), 2);
        p.timelines[1].group = Some(crate::TimelineGroup { source_tracks: BTreeMap::new() });
        assert!(p.timelines[1].is_group() && !p.timelines[0].is_group());
        assert_eq!(p.pickable_timelines().map(|t| t.id).collect::<Vec<_>>(), [id(1)]);
        let c = p.timelines[0].tracks[0].clips()[0].clone();
        assert_eq!(p.group_sequence_of(&c).map(|t| t.id), Some(id(2)));
    }

    fn sec(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// A clip with a unique id `n`, source from `src` for `dur` seconds, at `start`.
    fn clip(n: u32, start: i64, dur: i64, src: i64, kind: TrackKind, link: Option<u32>) -> Clip {
        let mut c = Clip::new(id(n), "c", id(5000 + n), kind, TimeRange::new(sec(src), sec(dur)), sec(start));
        c.link = link.map(id);
        c
    }

    fn track(n: u32, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(id(n), kind);
        t.set_clips(clips);
        t
    }

    fn timeline(n: u32, name: &str, tracks: Vec<Track>) -> Timeline {
        Timeline::new(id(n), name, crate::SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    fn proj(timelines: Vec<Timeline>) -> Project {
        let mut p = project_json(vec![], vec![]);
        p.timelines = timelines.into();
        p.normalize_bins();
        p
    }

    fn nested(n: u32, sequence: u32, start: i64, dur: i64) -> Clip {
        let mut c = clip(n, start, dur, 0, TrackKind::Video, None);
        c.media = id(sequence);
        c.sequence = Some(id(sequence));
        c
    }

    #[test]
    fn nest_replaces_clips_with_one_nested_clip() {
        let (v1, a1) = (clip(1, 2, 3, 10, TrackKind::Video, Some(90)), clip(2, 2, 3, 10, TrackKind::Audio, Some(90)));
        let (v2, untouched) = (clip(3, 5, 2, 0, TrackKind::Video, None), clip(4, 20, 2, 0, TrackKind::Video, None));
        let outer = timeline(
            100,
            "Main",
            vec![
                track(11, TrackKind::Video, vec![v1.clone(), v2.clone(), untouched.clone()]),
                track(12, TrackKind::Audio, vec![a1]),
            ],
        );
        let mut p = proj(vec![outer.clone()]);
        let seq_id = p.nest(&[v1.id, v2.id], outer.id, None, &mut TestIds(700)).unwrap_or(Id::NIL);

        let seq = p.timeline(seq_id).cloned().unwrap_or_else(|| outer.clone());
        assert_eq!(seq.name, "Combined 01");
        assert_eq!(seq.format, outer.format);
        assert_eq!(seq.tracks.iter().map(|t| t.kind).collect::<Vec<_>>(), [TrackKind::Video, TrackKind::Audio]);
        let starts = |t: &Track| t.clips().iter().map(|c| c.start).collect::<Vec<_>>();
        assert_eq!(starts(&seq.tracks[0]), [sec(0), sec(3)]);
        assert_eq!(seq.tracks[0].clips()[0].source, v1.source);
        assert_eq!(starts(&seq.tracks[1]), [sec(0)]);
        assert_eq!(seq.tracks[1].clips()[0].link, Some(id(90)));
        let o = p.timeline(outer.id).cloned().unwrap_or_else(|| outer.clone());
        let on = |t: &Track| t.clips().iter().find(|c| c.sequence == Some(seq_id)).cloned();
        let (nv, na) = (on(&o.tracks[0]).unwrap_or_else(|| v1.clone()), on(&o.tracks[1]).unwrap_or_else(|| v1.clone()));
        assert_eq!(nv.timeline(), TimeRange::from_end(sec(2), sec(7)));
        assert_eq!(na.timeline(), nv.timeline());
        assert!(nv.link.is_some() && nv.link == na.link);
        assert_eq!((nv.source, nv.media), (TimeRange::new(sec(0), sec(5)), seq_id));
        assert!(o.tracks[0].clips().iter().any(|c| c.id == untouched.id));
        assert_eq!(o.tracks[0].clips().len(), 2);
        assert_eq!(
            p.root_bin.parent_of(BinItemRef::Sequence(seq_id)),
            p.root_bin.parent_of(BinItemRef::Sequence(outer.id))
        );
    }

    #[test]
    fn nest_goes_on_the_lowest_track() {
        let (a, b) = (clip(1, 0, 2, 0, TrackKind::Video, None), clip(2, 0, 2, 0, TrackKind::Video, None));
        let outer = timeline(
            100,
            "Main",
            vec![
                track(11, TrackKind::Video, vec![]),
                track(12, TrackKind::Video, vec![a.clone()]),
                track(13, TrackKind::Video, vec![b.clone()]),
            ],
        );
        let mut p = proj(vec![outer.clone()]);
        let new = p.nest(&[a.id, b.id], outer.id, None, &mut TestIds(700)).unwrap_or(Id::NIL);
        let o = p.timeline(outer.id).cloned().unwrap_or_else(|| outer.clone());
        assert_eq!(o.tracks[1].clips().first().and_then(|c| c.sequence), Some(new));
        assert!(o.tracks[2].clips().is_empty());
        assert_eq!(p.timeline(new).map(|t| t.tracks.len()), Some(2));
    }

    #[test]
    fn nest_names_are_unique_and_the_bin_is_kept() {
        let (a, b) = (clip(1, 0, 2, 0, TrackKind::Video, None), clip(2, 3, 2, 0, TrackKind::Video, None));
        let outer = timeline(100, "Main", vec![track(11, TrackKind::Video, vec![a.clone(), b.clone()])]);
        let mut p = proj(vec![outer.clone()]);
        let ids = &mut TestIds(700);
        let bin = p.new_bin("Seqs", None, ids).unwrap_or(Id::NIL);
        assert!(p.move_items(&[BinItemRef::Sequence(outer.id)], bin, None));
        let first = p.nest(&[a.id], outer.id, None, ids).unwrap_or(Id::NIL);
        let second = p.nest(&[b.id], outer.id, None, ids).unwrap_or(Id::NIL);
        assert_eq!(p.timeline(first).map(|t| t.name.as_str()), Some("Combined 01"));
        assert_eq!(p.timeline(second).map(|t| t.name.as_str()), Some("Combined 02"));
        assert_eq!(p.root_bin.parent_of(BinItemRef::Sequence(second)), Some(bin));
        let named = p.nest(&[clip_id_of(&p, outer.id)], outer.id, Some("Mine"), ids).unwrap_or(Id::NIL);
        assert_eq!(p.timeline(named).map(|t| t.name.as_str()), Some("Mine"));
    }

    fn clip_id_of(p: &Project, timeline: Id) -> Id {
        p.timeline(timeline).and_then(|t| t.tracks[0].clips().first().map(|c| c.id)).unwrap_or(Id::NIL)
    }

    #[test]
    fn nest_errors_change_nothing() {
        let (a, blocker, b) = (
            clip(1, 0, 2, 0, TrackKind::Video, None),
            clip(2, 3, 1, 0, TrackKind::Video, None),
            clip(3, 6, 2, 0, TrackKind::Video, None),
        );
        let mut locked = track(12, TrackKind::Video, vec![clip(4, 0, 1, 0, TrackKind::Video, None)]);
        locked.is_locked = true;
        let outer =
            timeline(100, "Main", vec![track(11, TrackKind::Video, vec![a.clone(), blocker, b.clone()]), locked]);
        let mut p = proj(vec![outer.clone()]);
        let ids = &mut TestIds(700);
        assert_eq!(p.nest(&[a.id], id(404), None, ids), Err(EditError::TimelineNotFound));
        assert_eq!(p.nest(&[], outer.id, None, ids), Err(EditError::EmptyClip));
        assert_eq!(p.nest(&[id(404)], outer.id, None, ids), Err(EditError::ClipNotFound));
        assert_eq!(p.nest(&[id(4)], outer.id, None, ids), Err(EditError::TrackLocked));
        // `blocker` sits between a and b on the target track.
        assert_eq!(p.nest(&[a.id, b.id], outer.id, None, ids), Err(EditError::Collision));
        assert_eq!(p.timelines.len(), 1);
        assert_eq!(p.timeline(outer.id), Some(&outer));
    }

    #[test]
    fn nest_rehosts_outer_attachments_and_drops_inner_hosts_left_outside() {
        let (host, riding, other) = (
            clip(1, 0, 4, 0, TrackKind::Video, None),
            clip(2, 1, 1, 0, TrackKind::Video, None),
            clip(3, 2, 1, 0, TrackKind::Video, None),
        );
        let outer = timeline(
            100,
            "Main",
            vec![
                track(11, TrackKind::Video, vec![host.clone()]),
                track(12, TrackKind::Video, vec![riding.clone(), other.clone()]),
            ],
        );
        let mut p = proj(vec![outer.clone()]);
        p.timelines[0].derive_attachments();
        // Nest the host with `riding`; `other` (attached to the host) stays outside and moves to the nested clip.
        let seq_id = p.nest(&[host.id, riding.id], outer.id, None, &mut TestIds(700)).unwrap_or(Id::NIL);
        let o = &p.timelines[0];
        let nested = o.tracks[0].clips().iter().find(|c| c.sequence == Some(seq_id)).map(|c| c.id).unwrap_or(Id::NIL);
        assert_eq!(o.find(other.id).and_then(|m| m.clip.attachment).map(|a| a.host), Some(nested));
        assert!(o.is_attachment_valid(other.id));
        let inner = p.timeline(seq_id).cloned().unwrap_or_else(|| outer.clone());
        assert_eq!(
            inner.find(riding.id).and_then(|m| m.clip.attachment).map(|a| a.host),
            Some(host.id),
            "host nested along"
        );
        // A clip nested without its host loses the attachment.
        let mut q = proj(vec![outer.clone()]);
        q.timelines[0].derive_attachments();
        let seq2 = q.nest(&[riding.id], outer.id, None, &mut TestIds(700)).unwrap_or(Id::NIL);
        assert_eq!(q.timeline(seq2).and_then(|t| t.find(riding.id)).map(|m| m.clip.attachment), Some(None));
    }

    #[test]
    fn edit_commits_only_cycle_free_results() {
        let (a, b) = (
            timeline(1, "A", vec![track(11, TrackKind::Video, vec![clip(1, 0, 4, 0, TrackKind::Video, None)])]),
            timeline(2, "B", vec![track(12, TrackKind::Video, vec![clip(2, 0, 4, 0, TrackKind::Video, None)])]),
        );
        let mut p = proj(vec![a.clone(), b.clone()]);
        let in_b = p
            .sequence_clips(b.id, Time::ZERO, &mut TestIds(700))
            .and_then(|c| c.into_iter().next())
            .unwrap_or_else(|| clip(9, 0, 1, 0, TrackKind::Video, None));
        // A contains B: fine. The clip overwrites A's own clip.
        assert_eq!(p.edit(a.id, |t| t.tracks[0].overwrite(in_b, &mut TestIds(800))), Ok(()));
        assert_eq!(p.nested_sequences(a.id), ids(&[2]));
        // B containing A would close the loop.
        let in_a = p
            .sequence_clips(a.id, Time::ZERO, &mut TestIds(700))
            .and_then(|c| c.into_iter().next())
            .unwrap_or_else(|| clip(9, 0, 1, 0, TrackKind::Video, None));
        assert!(p.would_create_cycle(a.id, b.id));
        let before = p.clone();
        assert_eq!(p.edit(b.id, |t| t.tracks[0].overwrite(in_a, &mut TestIds(800))), Err(EditError::NestingCycle));
        assert_eq!(p, before);
        // Directly into itself.
        let own = nested(50, 1, 10, 1);
        assert_eq!(p.edit(a.id, |t| t.tracks[0].overwrite(own, &mut TestIds(800))), Err(EditError::NestingCycle));
        assert!(p.is_nesting_acyclic());
        assert_eq!(p.edit(id(404), |_| Ok(())), Err(EditError::TimelineNotFound));
    }

    #[test]
    fn edit_finds_a_three_level_cycle_and_refreshes_nested_media_lengths() {
        let mk = |n: u32, name: &str| {
            timeline(n, name, vec![track(10 + n, TrackKind::Video, vec![clip(n, 0, 4, 0, TrackKind::Video, None)])])
        };
        let mut p = proj(vec![mk(1, "A"), mk(2, "B"), mk(3, "C")]);
        let put = |n: u32, inner: u32| nested(60 + n, inner, 10, 2);
        assert_eq!(p.edit(id(1), |t| t.tracks[0].overwrite(put(1, 2), &mut TestIds(800))), Ok(()));
        assert_eq!(p.edit(id(2), |t| t.tracks[0].overwrite(put(2, 3), &mut TestIds(800))), Ok(()));
        assert_eq!(p.reachable_sequences(id(1)), ids(&[2, 3]));
        assert!(p.would_create_cycle(id(1), id(3)));
        assert!(!p.would_create_cycle(id(3), id(1)));
        assert_eq!(
            p.edit(id(3), |t| t.tracks[0].overwrite(put(3, 1), &mut TestIds(800))),
            Err(EditError::NestingCycle)
        );
        // A later edit of A refreshes the nested clip's media length to B's current duration.
        assert_eq!(p.edit(id(1), |_| Ok(())), Ok(()));
        let refreshed = p.timeline(id(1)).and_then(|t| t.tracks[0].clip(id(61)).and_then(|c| c.media_duration));
        assert_eq!(refreshed, p.timeline(id(2)).map(Timeline::duration));
    }

    #[test]
    fn sequence_clips_build_video_and_linked_audio() {
        let inner = timeline(
            2,
            "Inner",
            vec![
                track(11, TrackKind::Video, vec![clip(1, 0, 10, 100, TrackKind::Video, None)]),
                track(12, TrackKind::Audio, vec![clip(2, 0, 10, 50, TrackKind::Audio, None)]),
            ],
        );
        let p = proj(vec![inner.clone()]);
        let cs = p.sequence_clips(inner.id, sec(7), &mut TestIds(700)).unwrap_or_default();
        assert_eq!(cs.iter().map(|c| c.kind).collect::<Vec<_>>(), [TrackKind::Video, TrackKind::Audio]);
        assert!(cs[0].link.is_some() && cs[0].link == cs[1].link);
        assert_eq!(
            (cs[0].source, cs[0].start, cs[0].media_duration),
            (TimeRange::new(Time::ZERO, sec(10)), sec(7), Some(sec(10)))
        );
        assert_eq!(p.sequence_clips(id(404), Time::ZERO, &mut TestIds(700)), None);
        let silent = proj(vec![timeline(
            3,
            "V",
            vec![track(13, TrackKind::Video, vec![clip(3, 0, 2, 0, TrackKind::Video, None)])],
        )]);
        assert_eq!(silent.sequence_clips(id(3), Time::ZERO, &mut TestIds(700)).map(|c| c.len()), Some(1));
        assert_eq!(proj(vec![timeline(4, "E", vec![])]).sequence_clips(id(4), Time::ZERO, &mut TestIds(700)), None);
    }

    #[test]
    fn reachable_follows_nesting_and_stops_on_cycles() {
        let p = project(&[(1, &[2]), (2, &[3]), (3, &[])]);
        assert_eq!(p.nested_sequences(id(1)), ids(&[2]));
        assert_eq!(p.reachable_sequences(id(1)), ids(&[2, 3]));
        assert!(p.is_nesting_acyclic());
        let cyclic = project(&[(1, &[2]), (2, &[1])]);
        assert_eq!(cyclic.reachable_sequences(id(1)), ids(&[1, 2]));
        assert!(!cyclic.is_nesting_acyclic());
    }

    #[test]
    fn would_create_cycle_refuses_self_and_containers() {
        let p = project(&[(1, &[2]), (2, &[])]);
        assert!(p.would_create_cycle(id(1), id(1)));
        assert!(p.would_create_cycle(id(1), id(2)), "1 contains 2, so 1 cannot go into 2");
        assert!(!p.would_create_cycle(id(2), id(1)));
        assert!(p.nested_sequences(id(77)).is_empty());
    }
}
