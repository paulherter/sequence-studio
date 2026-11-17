// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Angles.swift (`AngleInput`, `Project.makeAnglesSequence`, `Project.makeAnglesClip`, `AnglesOffsets`)

use crate::angles_edits::angle_groups;
use sq_core_model::{
    AnglesSetup, BinItem, BinItemRef, Clip, EditError, Project, SequenceFormat, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};

/// One angle for `make_angles_sequence`.
#[derive(Clone, Debug)]
pub struct AngleInput {
    /// Track name of the angle (empty: "Angle n").
    pub name: String,
    /// The angle's clips (usually one video clip and its linked audio clip). Their starts are kept relative to each other.
    pub clips: Vec<Clip>,
    /// Where the angle's earliest clip starts on the common clock (any origin, may be negative): the angles are shifted
    /// so the earliest starts at 0.
    pub offset: Time,
}

impl AngleInput {
    /// An angle starting at offset 0.
    pub fn new(name: &str, clips: Vec<Clip>) -> AngleInput {
        AngleInput { name: name.to_string(), clips, offset: Time::ZERO }
    }
}

/// Builds Angles sequences and clips in a project.
pub trait AnglesProjectExt {
    /// Builds an Angles sequence: one video and one audio track per angle (audio tracks only when an angle has sound),
    /// each angle shifted by its offset so the earliest starts at 0 (on the frame grid of `format`). Filed in `bin`
    /// (root when `None`) and named "Angles NN" unless `name` is given. `setup.audio_angle` falls back to the first angle with
    /// sound. `EmptyClip` without clips, `Collision` if an angle's own clips overlap.
    fn make_angles_sequence(
        &mut self,
        name: Option<&str>,
        format: &SequenceFormat,
        angles: &[AngleInput],
        setup: &AnglesSetup,
        bin: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;

    /// Create Angles Clip from timeline clips: every selected clip with its linked partners becomes one angle (ordered by
    /// track from the bottom, then by start) and the Angles clip takes their place: at the earliest start, on the lowest
    /// involved video and audio track.
    /// `offsets`: where each angle starts on the common clock, keyed by any of its clips; `None` = the positions the clips
    /// have in the timeline. An angle without an entry starts at 0.
    /// `TrackLocked`, `Collision` (an unselected clip lies where the Angles clip goes), `EmptyClip` (fewer than two
    /// angles) or `ClipNotFound`. Returns the new sequence.
    fn make_angles_clip(
        &mut self,
        from: &[Id],
        in_timeline: Id,
        name: Option<&str>,
        offsets: Option<&BTreeMap<Id, Time>>,
        setup: &AnglesSetup,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
}

fn next_angles_name(p: &Project) -> String {
    let names: BTreeSet<&str> = p.timelines.iter().map(|t| t.name.as_str()).collect();
    let mut n = 1;
    while names.contains(format!("Angles {n:02}").as_str()) {
        n += 1;
    }
    format!("Angles {n:02}")
}

impl AnglesProjectExt for Project {
    fn make_angles_sequence(
        &mut self,
        name: Option<&str>,
        format: &SequenceFormat,
        angles: &[AngleInput],
        setup: &AnglesSetup,
        bin: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let used: Vec<&AngleInput> = angles.iter().filter(|a| !a.clips.is_empty()).collect();
        let Some(earliest) = used.iter().map(|a| a.offset).min() else { return Err(EditError::EmptyClip) };
        let fd = format.frame_duration;
        let has_audio = used.iter().any(|a| a.clips.iter().any(|c| c.kind == TrackKind::Audio));
        let mut video: Vec<Track> = Vec::new();
        let mut audio: Vec<Track> = Vec::new();
        for (i, angle) in used.iter().enumerate() {
            let name = if angle.name.is_empty() { format!("Angle {}", i + 1) } else { angle.name.clone() };
            let mut v = Track::new(ids.next_id(), TrackKind::Video);
            v.name = name.clone();
            v.is_targeted = i == 0;
            let mut a = Track::new(ids.next_id(), TrackKind::Audio);
            a.name = name;
            a.is_targeted = i == 0;
            let base = angle.clips.iter().map(|c| c.start).min().unwrap_or(Time::ZERO);
            let shift = (angle.offset - earliest).snapped(fd);
            for c in &angle.clips {
                let mut c = c.clone();
                c.start = shift + (c.start - base);
                c.attachment = None;
                let track = if c.kind == TrackKind::Video { &mut v } else { &mut a };
                if track.clips().iter().any(|x| x.timeline().overlaps(&c.timeline())) {
                    return Err(EditError::Collision);
                }
                track.overwrite(c, ids)?;
            }
            video.push(v);
            if has_audio {
                audio.push(a);
            }
        }
        let with_sound: Vec<i64> =
            audio.iter().enumerate().filter(|(_, t)| !t.clips().is_empty()).map(|(i, _)| i as i64).collect();
        let sound = if with_sound.contains(&setup.audio_angle) {
            setup.audio_angle
        } else {
            with_sound.first().copied().unwrap_or(0)
        };
        let id = ids.next_id();
        let mut seq = Timeline::new(
            id,
            &name.map_or_else(|| next_angles_name(self), str::to_string),
            format.clone(),
            video.into_iter().chain(audio).collect(),
        );
        seq.angles = Some(AnglesSetup { audio_angle: sound, audio_follows_video: setup.audio_follows_video });
        if seq.duration() <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        self.timelines.push(seq);
        let target = bin.unwrap_or(self.root_bin.id);
        match self.root_bin.bin_mut(target) {
            Some(b) => b.children.push(BinItem::Sequence(id)),
            None => self.root_bin.children.push(BinItem::Sequence(id)),
        }
        Ok(id)
    }

    fn make_angles_clip(
        &mut self,
        from: &[Id],
        in_timeline: Id,
        name: Option<&str>,
        offsets: Option<&BTreeMap<Id, Time>>,
        setup: &AnglesSetup,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let ti = self.timelines.iter().position(|t| t.id == in_timeline).ok_or(EditError::TimelineNotFound)?;
        let mut tl = self.timelines[ti].clone();
        let groups = angle_groups(&tl, from)?;
        let selected: BTreeSet<Id> = groups.iter().flatten().map(|m| m.clip.id).collect();
        if groups.len() < 2 {
            return Err(EditError::EmptyClip);
        }
        if groups.iter().any(|g| g.iter().any(|m| tl.tracks[m.track].is_locked)) {
            return Err(EditError::TrackLocked);
        }
        let inputs: Vec<AngleInput> = groups
            .iter()
            .map(|g| {
                let start = g.iter().map(|m| m.clip.start).min().unwrap_or(Time::ZERO);
                let offset =
                    offsets.map_or(start, |o| g.iter().find_map(|m| o.get(&m.clip.id).copied()).unwrap_or(Time::ZERO));
                let lead = g.iter().find(|m| m.clip.kind == TrackKind::Video).map_or(&g[0], |m| m);
                AngleInput { name: lead.clip.name.clone(), clips: g.iter().map(|m| m.clip.clone()).collect(), offset }
            })
            .collect();
        let mut work = self.clone();
        let bin = self.root_bin.parent_of(BinItemRef::Sequence(in_timeline));
        let seq_id = work.make_angles_sequence(name, &tl.format, &inputs, setup, bin, ids)?;
        let Some(s) = groups.iter().flatten().map(|m| m.clip.start).min() else { return Err(EditError::EmptyClip) };
        let Some(made) = work.sequence_clips(seq_id, s, ids) else { return Err(EditError::EmptyClip) };
        let involved: BTreeSet<usize> = groups.iter().flatten().map(|m| m.track).collect();
        for &i in &involved {
            for id in &selected {
                tl.tracks[i].remove(*id);
            }
            tl.tracks[i].transitions.retain(|tr| {
                !(tr.outgoing.is_some_and(|o| selected.contains(&o))
                    || tr.incoming.is_some_and(|n| selected.contains(&n)))
            });
        }
        let mut placed_video: Option<Id> = None;
        for c in made {
            let Some(target) = involved.iter().copied().find(|&i| tl.tracks[i].kind == c.kind) else { continue };
            if tl.tracks[target].clips().iter().any(|x| x.timeline().overlaps(&c.timeline())) {
                return Err(EditError::Collision);
            }
            let (kind, cid) = (c.kind, c.id);
            tl.tracks[target].overwrite(c, ids)?;
            if kind == TrackKind::Video {
                placed_video = Some(cid);
            }
        }
        if let Some(pv) = placed_video {
            let map: BTreeMap<Id, Id> = selected.iter().map(|id| (*id, pv)).collect();
            tl.remap_attachments(&map, None, true);
        }
        work.timelines[ti] = tl;
        *self = work;
        Ok(seq_id)
    }
}

/// Where the angles of a new Angles clip start, for every sync mode.
pub struct AnglesOffsets;

impl AnglesOffsets {
    /// The start of each angle on the common clock (`AngleInput::offset`). Each entry is `(origin, in_point)`. `origin`:
    /// where the angle's file time 0 lies on that clock (start timecode, the shift the sound match found), `None` when
    /// nothing places the file. `in_point`: the source time of the angle's first frame.
    /// An origin places the file's time 0, so that angle starts at origin + In point. An angle without an origin starts
    /// with the earliest placed angle: its In point is at 0 of the Angles sequence. No origin at all: every In point is at 0.
    pub fn starts(angles: &[(Option<Time>, Time)]) -> Vec<Time> {
        let placed: Vec<Option<Time>> = angles.iter().map(|(origin, in_point)| origin.map(|o| o + *in_point)).collect();
        let earliest = placed.iter().flatten().min().copied().unwrap_or(Time::ZERO);
        placed.into_iter().map(|p| p.unwrap_or(earliest)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::angles_edits::AnglesEditsExt as _;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::AngleChoice;
    use sq_core_time::{SequentialIds, TimeRange};

    fn format() -> SequenceFormat {
        SequenceFormat::new(Time::new(1, 25))
    }

    fn setup(audio_angle: i64, audio_follows_video: bool) -> AnglesSetup {
        AnglesSetup { audio_angle, audio_follows_video }
    }

    fn project(timelines: Vec<Timeline>) -> Project {
        Project::new(link(), "P", Vec::new(), timelines)
    }

    /// One camera: a video clip and its linked sound over `dur` seconds of media `media`.
    fn camera(media: Id, dur: i64, src: i64, audio: bool) -> Vec<Clip> {
        let l = audio.then(link);
        let make = |k: TrackKind| {
            let mut c = clip(0, dur, src, k, l, Some(src + dur));
            c.media = media;
            c
        };
        if audio { vec![make(TrackKind::Video), make(TrackKind::Audio)] } else { vec![make(TrackKind::Video)] }
    }

    fn three_angles(p: &mut Project, audio_angle: i64, follows: bool) -> (Id, [Id; 3]) {
        let m = [link(), link(), link()];
        let angles: Vec<AngleInput> = m
            .iter()
            .enumerate()
            .map(|(i, id)| AngleInput::new(&format!("Cam {}", i + 1), camera(*id, 10, 0, true)))
            .collect();
        let setup = AnglesSetup { audio_angle, audio_follows_video: follows };
        let seq = p.make_angles_sequence(None, &format(), &angles, &setup, None, &mut FreshIds);
        (seq.unwrap_or(Id::NIL), m)
    }

    #[test]
    fn sequence_has_one_video_and_one_audio_track_per_angle() {
        let mut p = project(vec![]);
        let (id, _) = three_angles(&mut p, 0, false);
        let seq = p.timeline(id).cloned().unwrap_or_else(|| timeline(vec![]));
        assert_eq!(seq.name, "Angles 01");
        let kinds: Vec<TrackKind> = seq.tracks.iter().map(|t| t.kind).collect();
        assert_eq!(kinds, [TrackKind::Video; 3].into_iter().chain([TrackKind::Audio; 3]).collect::<Vec<_>>());
        assert_eq!(seq.angles, Some(AnglesSetup { audio_angle: 0, audio_follows_video: false }));
        assert_eq!(seq.angle_count(), 3);
        assert_eq!(seq.angle_names(), ["Cam 1", "Cam 2", "Cam 3"]);
        assert_eq!(p.root_bin.parent_of(BinItemRef::Sequence(id)), Some(p.root_bin.id));
    }

    #[test]
    fn offsets_shift_the_angles_so_the_earliest_starts_at_zero() {
        let mut p = project(vec![]);
        let mut a = AngleInput::new("A", camera(link(), 10, 0, true));
        a.offset = s(5);
        let mut b = AngleInput::new("B", camera(link(), 10, 0, false));
        b.offset = Time::new(-51, 50); // off the frame grid
        let id = p.make_angles_sequence(Some("Talk"), &format(), &[a, b], &setup(1, false), None, &mut FreshIds);
        let seq = id.ok().and_then(|id| p.timeline(id).cloned()).unwrap_or_else(|| timeline(vec![]));
        assert_eq!(seq.name, "Talk");
        assert_eq!(seq.tracks[1].clips().iter().map(|c| c.start).collect::<Vec<_>>(), [Time::ZERO]);
        // 5 s + 1.02 s = 6.02 s, on the 25 fps grid: frame 150.5 snaps to a whole frame.
        let start = seq.tracks[0].clips()[0].start;
        assert_eq!(start, (s(5) + Time::new(51, 50)).snapped(Time::new(1, 25)));
        assert_eq!(seq.tracks[2].clips().iter().map(|c| c.start).collect::<Vec<_>>(), [start]); // the sound moved along
        assert!(seq.tracks[3].clips().is_empty()); // angle B has no sound, its track stays (index = angle)
        assert_eq!(seq.angles.map(|a| a.audio_angle), Some(0)); // angle 2 has no sound: first angle with sound
    }

    #[test]
    fn an_empty_list_is_refused() {
        let mut p = project(vec![]);
        let r = p.make_angles_sequence(None, &format(), &[], &setup(0, false), None, &mut FreshIds);
        assert_eq!(r, Err(EditError::EmptyClip));
    }

    #[test]
    fn a_new_angles_clip_starts_on_the_chosen_audio_angle() {
        let mut p = project(vec![]);
        let (seq, _) = three_angles(&mut p, 2, false);
        let clips = p.sequence_clips(seq, s(4), &mut FreshIds).unwrap_or_default();
        let angles: Vec<Option<AngleChoice>> = clips.iter().map(|c| c.angle.clone()).collect();
        assert_eq!(
            angles,
            [
                Some(AngleChoice { index: 0, follows_video: false }),
                Some(AngleChoice { index: 2, follows_video: false })
            ]
        );
        let mut q = project(vec![]);
        let (seq, _) = three_angles(&mut q, 2, true);
        let c2 = q.sequence_clips(seq, Time::ZERO, &mut FreshIds).unwrap_or_default();
        assert_eq!(c2[1].angle, Some(AngleChoice { index: 0, follows_video: true }));
    }

    #[test]
    fn an_origin_places_the_files_time_zero_and_no_origin_places_the_in_point_at_zero() {
        // No origin at all (In Points): every angle starts together whatever its In point.
        assert_eq!(AnglesOffsets::starts(&[(None, s(10)), (None, Time::ZERO)]), [Time::ZERO, Time::ZERO]);
        // Origins: file time 0 is placed, so the angle starts at origin + In.
        assert_eq!(AnglesOffsets::starts(&[(Some(s(100)), s(10)), (Some(s(103)), Time::ZERO)]), [s(110), s(103)]);
        // An angle nothing places starts with the earliest placed one: at 0 of the Angles sequence.
        assert_eq!(
            AnglesOffsets::starts(&[(Some(s(100)), s(10)), (None, s(4)), (Some(s(103)), Time::ZERO)]),
            [s(110), s(103), s(103)]
        );
        let starts = AnglesOffsets::starts(&[(None, s(10)), (None, Time::ZERO)]);
        let (mut a, mut b) =
            (AngleInput::new("A", camera(link(), 5, 10, true)), AngleInput::new("B", camera(link(), 5, 0, true)));
        (a.offset, b.offset) = (starts[0], starts[1]);
        let mut p = project(vec![]);
        let id = p.make_angles_sequence(None, &format(), &[a, b], &setup(0, false), None, &mut FreshIds);
        let seq = id.ok().and_then(|id| p.timeline(id).cloned()).unwrap_or_else(|| timeline(vec![]));
        let firsts: Vec<Option<Time>> = seq
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .map(|t| t.clips().first().map(|c| c.start))
            .collect();
        assert_eq!(firsts, [Some(Time::ZERO), Some(Time::ZERO)]);
        assert_eq!(seq.tracks[0].clips()[0].source.start, s(10));
    }

    #[test]
    fn timeline_clips_become_one_angles_clip() {
        let m = [link(), link()];
        let (mut a, mut b) = (camera(m[0], 10, 0, true), camera(m[1], 8, 0, true));
        a.iter_mut().for_each(|c| c.start = s(2));
        b.iter_mut().for_each(|c| c.start = s(4));
        let other = v(30, 2);
        let tl = timeline(vec![
            track(TrackKind::Video, vec![a[0].clone(), other]),
            track(TrackKind::Video, vec![b[0].clone()]),
            track(TrackKind::Audio, vec![a[1].clone()]),
            track(TrackKind::Audio, vec![b[1].clone()]),
        ]);
        let tid = tl.id;
        let mut p = project(vec![tl]);
        let id = p
            .make_angles_clip(&[b[0].id, a[0].id], tid, None, None, &setup(0, false), &mut FreshIds)
            .unwrap_or(Id::NIL);
        let seq = p.timeline(id).cloned().unwrap_or_else(|| timeline(vec![]));
        // Timeline positions are the sync: A at 0, B two seconds later; angles ordered by track from the bottom.
        let kinds: Vec<TrackKind> = seq.tracks.iter().map(|t| t.kind).collect();
        assert_eq!(kinds, [TrackKind::Video, TrackKind::Video, TrackKind::Audio, TrackKind::Audio]);
        assert_eq!(seq.tracks[0].clips().iter().map(|c| (c.media, c.start)).collect::<Vec<_>>(), [(m[0], Time::ZERO)]);
        assert_eq!(seq.tracks[1].clips().iter().map(|c| (c.media, c.start)).collect::<Vec<_>>(), [(m[1], s(2))]);
        let out = p.timeline(tid).cloned().unwrap_or_else(|| timeline(vec![]));
        assert!(
            out.tracks[0].clips().len() == 2 && out.tracks[1].clips().is_empty() && out.tracks[3].clips().is_empty()
        );
        let (vc, au) = (&out.tracks[0].clips()[0], &out.tracks[2].clips()[0]);
        assert_eq!(vc.sequence, Some(id));
        assert_eq!(vc.angle, Some(AngleChoice { index: 0, follows_video: false }));
        assert_eq!(vc.timeline(), TimeRange::from_end(s(2), s(12)));
        assert_eq!(au.angle, Some(AngleChoice { index: 0, follows_video: false }));
        assert!(au.link == vc.link && vc.link.is_some());
    }

    #[test]
    fn timeline_clips_with_offsets_and_a_collision() {
        let m = [link(), link()];
        let a = camera(m[0], 10, 0, false).remove(0);
        let mut b = camera(m[1], 10, 0, false).remove(0);
        b.start = s(20);
        let mut blocker = camera(link(), 2, 0, false).remove(0);
        blocker.start = s(11);
        let tl = timeline(vec![track(TrackKind::Video, vec![a.clone(), blocker.clone(), b.clone()])]);
        let tid = tl.id;
        let mut p = project(vec![tl.clone()]);
        let mut ids = SequentialIds::default();
        // Synced, B starts 3 s after A: the Angles clip is 13 s long and would run into the clip at 11 s.
        let o = BTreeMap::from([(a.id, Time::ZERO), (b.id, s(3))]);
        assert_eq!(
            p.make_angles_clip(&[a.id, b.id], tid, None, Some(&o), &setup(0, false), &mut ids),
            Err(EditError::Collision)
        );
        assert!(p.timelines.len() == 1 && p.timelines[0] == tl);
        let o = BTreeMap::from([(a.id, Time::ZERO), (b.id, s(1))]);
        let id = p.make_angles_clip(&[a.id, b.id], tid, None, Some(&o), &setup(0, false), &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.timeline(id).map(Timeline::duration), Some(s(11)));
        assert_eq!(
            p.make_angles_clip(&[blocker.id], tid, None, None, &setup(0, false), &mut ids),
            Err(EditError::EmptyClip)
        );
    }
}
