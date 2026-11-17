// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+ThreePoint.swift (overwrite and three-point edit)

use crate::clip_attachment::clear_main_track_attachments;
use crate::{Clip, ClipSpeed, EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// How a three-point edit meets what is already on the track.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThreePointMode {
    /// Ripple like `Timeline::insert` (sync lock honored).
    Insert,
    /// Replace what is covered.
    Overwrite,
}

/// What a three-point edit places: a source range of a media item and how the new clips are made.
#[derive(Clone, Debug)]
pub struct SourcePlacement {
    /// The part of the media to place.
    pub source: TimeRange,
    /// The media item.
    pub media: Id,
    /// Name of the new clips.
    pub name: String,
    /// Length of the media, when known.
    pub media_duration: Option<Time>,
    /// The media is a still image.
    pub is_still: bool,
    /// The Scale property of new video clips (Scale is relative to source pixels); 1 = untouched.
    pub initial_scale: f64,
    /// Speed of the new clips (ignored for stills).
    pub speed: ClipSpeed,
}

impl SourcePlacement {
    /// A plain placement: no media length known, not a still, scale 1, normal speed.
    pub fn new(source: TimeRange, media: Id, name: &str) -> SourcePlacement {
        SourcePlacement {
            source,
            media,
            name: name.to_string(),
            media_duration: None,
            is_still: false,
            initial_scale: 1.0,
            speed: ClipSpeed::NORMAL,
        }
    }
}

impl Timeline {
    /// Overwrite edit, mirror of `insert`: placements keep their start offsets relative to the earliest one, which lands at
    /// `t`; whatever they cover is cut or removed, nothing shifts. A time before 0 returns `Collision`; nothing changes then.
    pub fn overwrite(&mut self, placements: &[(Clip, Id)], t: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let first = placements.iter().map(|p| p.0.start).min().ok_or(EditError::EmptyClip)?;
        if t < Time::ZERO {
            return Err(EditError::Collision);
        }
        let mut work = self.tracks.clone();
        let mut relinks = BTreeMap::new();
        for (clip, track) in placements {
            let i = work.iter().position(|x| x.id == *track).ok_or(EditError::ClipNotFound)?;
            if work[i].is_locked {
                return Err(EditError::TrackLocked);
            }
            if clip.kind != work[i].kind {
                return Err(EditError::WrongTrackKind);
            }
            let mut c = clip.clone();
            c.start = t + (clip.start - first);
            work[i].overwrite_relinking(c, &mut relinks, ids)?;
        }
        if !work.iter().all(|x| x.is_consistent()) {
            return Err(EditError::Collision);
        }
        clear_main_track_attachments(&mut work);
        self.tracks = work;
        Ok(())
    }

    /// Places `src` on the target tracks at `t`. One clip per target track (kind follows the track). When targets include
    /// video and audio tracks, all new clips share one fresh link; a single kind gives unlinked clips. `Insert` ripples like
    /// `insert` (sync lock honored), `Overwrite` replaces what is covered. The source range must be non-empty, start at or
    /// after 0 and end within `media_duration` when given, otherwise `EmptyClip`. No targets: `ClipNotFound`.
    ///
    /// Normal-mode path only: Swift sends a Fast Cut sequence to `fastCutSourceEdit` from here, but that lives in
    /// sq-core-edit (which depends on this crate). The session dispatches (`es02_timeline_ops/source_edit.rs`), so every
    /// user edit takes the Fast Cut path; the one caller here is a new Normal sequence (`Project::sequence_from_media`).
    pub fn three_point_edit(
        &mut self,
        src: &SourcePlacement,
        targets: &[Id],
        t: Time,
        mode: ThreePointMode,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let SourcePlacement { source, media, name, media_duration, is_still, initial_scale, speed } = src;
        let (source, media, media_duration, is_still, initial_scale) =
            (*source, *media, *media_duration, *is_still, *initial_scale);
        if source.is_empty() || source.start < Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        if media_duration.is_some_and(|md| source.end() > md) {
            return Err(EditError::EmptyClip);
        }
        if targets.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        let mut kinds = BTreeSet::new();
        for id in targets {
            let tr = self.track(*id).ok_or(EditError::ClipNotFound)?;
            kinds.insert(tr.kind == TrackKind::Video);
        }
        let link = (kinds.len() > 1).then(|| ids.next_id());
        let mut placements = Vec::new();
        for id in targets {
            let kind = self.track(*id).ok_or(EditError::ClipNotFound)?.kind;
            let mut clip = Clip::new(ids.next_id(), name, media, kind, source, Time::ZERO);
            clip.link = link;
            clip.media_duration = media_duration;
            clip.is_still = is_still;
            if !is_still && !speed.is_normal() {
                clip.speed = *speed;
            }
            if kind == TrackKind::Video && (initial_scale - 1.0).abs() > 1e-12 {
                clip.animation.scale = crate::AnimatedProperty::new(Vec2::new(initial_scale, initial_scale));
            }
            placements.push((clip, *id));
        }
        match mode {
            ThreePointMode::Insert => self.insert(&placements, t, ids),
            ThreePointMode::Overwrite => self.overwrite(&placements, t, ids),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::TestIds;
    use crate::{SequenceFormat, Track};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }

    fn clip(n: u128, kind: TrackKind, start: i64, dur: i64) -> Clip {
        Clip::new(Id::from_u128(n), "c", Id::from_u128(70), kind, TimeRange::new(s(0), s(dur)), s(start))
    }

    fn place(
        tl: &mut Timeline,
        targets: &[Id],
        at: i64,
        mode: ThreePointMode,
        md: Option<Time>,
    ) -> Result<(), EditError> {
        let mut src = SourcePlacement::new(TimeRange::new(s(10), s(4)), Id::from_u128(71), "m");
        src.media_duration = md;
        tl.three_point_edit(&src, targets, s(at), mode, &mut TestIds(900))
    }

    #[test]
    fn video_and_audio_targets_get_one_shared_link() {
        let mut tl = timeline(vec![track(1, TrackKind::Video, vec![]), track(2, TrackKind::Audio, vec![])]);
        let targets = [Id::from_u128(1), Id::from_u128(2)];
        assert_eq!(place(&mut tl, &targets, 2, ThreePointMode::Insert, None), Ok(()));
        let (v, a) = (tl.tracks[0].clips()[0].clone(), tl.tracks[1].clips()[0].clone());
        assert!(v.link.is_some() && v.link == a.link);
        assert_eq!((v.start, v.source, a.kind), (s(2), TimeRange::new(s(10), s(4)), TrackKind::Audio));
        let mut single = timeline(vec![track(1, TrackKind::Video, vec![])]);
        assert_eq!(place(&mut single, &targets[..1], 0, ThreePointMode::Overwrite, None), Ok(()));
        assert_eq!(single.tracks[0].clips()[0].link, None);
    }

    #[test]
    fn insert_pushes_and_overwrite_replaces() {
        let base = || timeline(vec![track(1, TrackKind::Video, vec![clip(5, TrackKind::Video, 0, 10)])]);
        let targets = [Id::from_u128(1)];
        let mut ins = base();
        assert_eq!(place(&mut ins, &targets, 2, ThreePointMode::Insert, None), Ok(()));
        let spans = |t: &Timeline| t.tracks[0].clips().iter().map(|c| (c.start, c.duration())).collect::<Vec<_>>();
        assert_eq!(spans(&ins), [(s(0), s(2)), (s(2), s(4)), (s(6), s(8))]);
        let mut over = base();
        assert_eq!(place(&mut over, &targets, 2, ThreePointMode::Overwrite, None), Ok(()));
        assert_eq!(spans(&over), [(s(0), s(2)), (s(2), s(4)), (s(6), s(4))]);
    }

    #[test]
    fn bad_sources_and_targets_are_refused() {
        let mut tl = timeline(vec![track(1, TrackKind::Video, vec![])]);
        let targets = [Id::from_u128(1)];
        let ids = &mut TestIds(900);
        let go = |tl: &mut Timeline, src: TimeRange, targets: &[Id], ids: &mut TestIds| {
            let mut p = SourcePlacement::new(src, Id::from_u128(71), "m");
            p.media_duration = Some(s(12));
            tl.three_point_edit(&p, targets, s(0), ThreePointMode::Insert, ids)
        };
        assert_eq!(go(&mut tl, TimeRange::new(s(1), Time::ZERO), &targets, ids), Err(EditError::EmptyClip));
        assert_eq!(
            go(&mut tl, TimeRange::new(s(10), s(4)), &targets, ids),
            Err(EditError::EmptyClip),
            "past the media end"
        );
        assert_eq!(go(&mut tl, TimeRange::new(s(1), s(4)), &[], ids), Err(EditError::ClipNotFound));
        assert_eq!(go(&mut tl, TimeRange::new(s(1), s(4)), &[Id::from_u128(99)], ids), Err(EditError::ClipNotFound));
        assert!(tl.tracks[0].clips().is_empty());
    }

    #[test]
    fn speed_and_initial_scale_apply_to_the_new_clips() {
        let mut tl = timeline(vec![track(1, TrackKind::Video, vec![]), track(2, TrackKind::Audio, vec![])]);
        let targets = [Id::from_u128(1), Id::from_u128(2)];
        let mut src = SourcePlacement::new(TimeRange::new(s(0), s(4)), Id::from_u128(71), "m");
        src.initial_scale = 0.5;
        src.speed = ClipSpeed::from_percent(200.0);
        let r = tl.three_point_edit(&src, &targets, s(0), ThreePointMode::Overwrite, &mut TestIds(900));
        assert_eq!(r, Ok(()));
        let v = &tl.tracks[0].clips()[0];
        assert_eq!(v.animation.scale.value, Vec2::new(0.5, 0.5));
        assert_eq!(tl.tracks[1].clips()[0].animation.scale.value, Vec2::new(1.0, 1.0), "audio keeps the default scale");
        assert!(!v.speed.is_normal());
    }

    #[test]
    fn overwrite_keeps_placement_offsets_and_refuses_bad_input() {
        let mut tl = timeline(vec![track(1, TrackKind::Video, vec![]), track(2, TrackKind::Audio, vec![])]);
        let (video, audio) = (Id::from_u128(1), Id::from_u128(2));
        let ids = &mut TestIds(900);
        assert_eq!(tl.overwrite(&[], s(0), ids), Err(EditError::EmptyClip));
        assert_eq!(tl.overwrite(&[(clip(5, TrackKind::Video, 1, 2), video)], s(-1), ids), Err(EditError::Collision));
        assert_eq!(
            tl.overwrite(&[(clip(5, TrackKind::Audio, 1, 2), video)], s(0), ids),
            Err(EditError::WrongTrackKind)
        );
        assert_eq!(
            tl.overwrite(
                &[(clip(5, TrackKind::Video, 4, 2), video), (clip(6, TrackKind::Audio, 2, 6), audio)],
                s(10),
                ids
            ),
            Ok(())
        );
        assert_eq!(tl.tracks[0].clips()[0].start, s(12));
        assert_eq!(tl.tracks[1].clips()[0].start, s(10));
    }
}
