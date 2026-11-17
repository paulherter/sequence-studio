//! Placing whole sequences into another sequence: the nested clip's length.
// Swift: Nesting+Place.swift

use crate::timeline_add_track::AddTrackExt as _;
use crate::timeline_drop_targets::TimelineDropTargetsExt as _;
use crate::timeline_magnetic_ops::{MagneticOpsExt as _, Placement};
use sq_core_model::{EditError, Project, ThreePointMode, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Where and how `place_sequences` / `place_sequence_clips` put sequences (the arguments Swift passes one by one).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SequencePlacement {
    /// The sequence they go into.
    pub host: Id,
    /// Where the first one starts.
    pub time: Time,
    /// The video track the first lane lands on; `None` = drop rule / own lanes.
    pub video_track: Option<Id>,
    /// Create a track of this kind first (audio: only the audio clips go in).
    pub new_track: Option<TrackKind>,
    /// Insert or overwrite.
    pub mode: ThreePointMode,
}

/// Swift `Project.nestedLength(of:hostFrameDuration:)` and `placeSequences`.
pub trait NestingPlaceExt {
    /// Length of `sequence` as a nested clip in a host with `frame_duration`: whole host frames (nearest, at least one),
    /// never longer than the sequence itself (a 30 fps sequence of 10 s plays 10 s in a 25 fps host).
    fn nested_length(&self, sequence: Id, host_frame_duration: Time) -> Option<Time>;

    /// Places `sequences` one after another at `time` in `host` (a video clip and, when the sequence has audio, a linked
    /// audio clip each). Drop rule for tracks like media (`drop_targets`): V2 to A2, missing audio tracks are created;
    /// `new_track` creates a track of that kind first (audio ghost: audio only). One edit: a refusal changes nothing.
    /// `NestingCycle` when a sequence is the host or contains it (transitively), `TimelineNotFound` for an unknown host,
    /// `EmptyClip` for an unknown or empty sequence. Returns the end of the last placed clip.
    fn place_sequences(
        &mut self,
        sequences: &[Id],
        at: &SequencePlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
}

impl NestingPlaceExt for Project {
    fn nested_length(&self, sequence: Id, fd: Time) -> Option<Time> {
        let t = self.timeline(sequence).filter(|t| t.duration() > Time::ZERO)?;
        let duration = t.duration();
        let mut d = duration.snapped(fd);
        if d > duration {
            d = fd * 1.max(duration.frame_index(fd));
        }
        Some(if d > Time::ZERO { d } else { fd })
    }

    fn place_sequences(
        &mut self,
        sequences: &[Id],
        at: &SequencePlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let SequencePlacement { host, time, video_track, new_track, mode } = *at;
        if self.timeline(host).is_none() {
            return Err(EditError::TimelineNotFound);
        }
        if sequences.is_empty() {
            return Err(EditError::EmptyClip);
        }
        for id in sequences {
            if self.timeline(*id).is_none() {
                return Err(EditError::EmptyClip);
            }
            if self.would_create_cycle(*id, host) {
                return Err(EditError::NestingCycle);
            }
        }
        let mut end = time;
        let snapshot = self.clone();
        self.edit(host, |tl| {
            let fd = tl.frame_duration();
            let mut at = time.snapped(fd);
            let mut pointer = video_track;
            let mut audio_only = false;
            if let Some(kind) = new_track {
                pointer = Some(tl.add_track(kind, ids));
                audio_only = kind == TrackKind::Audio;
            }
            for id in sequences {
                let mut clips = snapshot.sequence_clips(*id, Time::ZERO, ids).ok_or(EditError::EmptyClip)?;
                let len = snapshot.nested_length(*id, fd).ok_or(EditError::EmptyClip)?;
                if audio_only {
                    clips.retain(|c| c.kind == TrackKind::Audio);
                }
                if clips.is_empty() {
                    return Err(EditError::EmptyClip);
                }
                let has_video = clips.iter().any(|c| c.kind == TrackKind::Video);
                let has_audio = clips.iter().any(|c| c.kind == TrackKind::Audio);
                let mut targets: Vec<Id> = Vec::new();
                let d = tl.drop_targets(pointer, has_video, has_audio);
                targets.extend(d.video);
                match (d.audio, d.new_audio_ordinal) {
                    (Some(a), _) => targets.push(a),
                    (None, Some(n)) => targets.push(tl.ensure_audio_track(n, ids)),
                    (None, None) => {}
                }
                let mut placements: Vec<Placement> = Vec::new();
                for mut c in clips {
                    c.source = TimeRange::new(Time::ZERO, len);
                    let tid = targets
                        .iter()
                        .copied()
                        .find(|t| tl.track(*t).is_some_and(|x| x.kind == c.kind))
                        .ok_or(EditError::ClipNotFound)?;
                    placements.push((c, tid));
                }
                // Fast Cut: onto the main track or attached off it, like any source edit (`fast_cut_source_edit`).
                if tl.is_fast_cut() {
                    tl.fast_cut_source_edit(&placements, at, mode, false, ids)?;
                } else if mode == ThreePointMode::Insert {
                    tl.insert(&placements, at, ids)?;
                } else {
                    tl.overwrite(&placements, at, ids)?;
                }
                at = (at + len).snapped(fd);
            }
            end = at;
            Ok(())
        })?;
        Ok(end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn project_with(duration: Time) -> (Project, Id) {
        let mut ids = SequentialIds::default();
        let mut v = Track::new(Id::from_u128(1), TrackKind::Video);
        let src = TimeRange::new(Time::ZERO, duration);
        v.overwrite(Clip::new(Id::from_u128(2), "c", Id::from_u128(3), TrackKind::Video, src, Time::ZERO), &mut ids)
            .unwrap();
        let t = Timeline::new(Id::from_u128(4), "S", SequenceFormat::new(Time::new(1, 30)), vec![v]);
        (Project::new(Id::from_u128(5), "P", vec![], vec![t]), Id::from_u128(4))
    }

    #[test]
    fn a_nested_clip_never_outlasts_its_sequence_and_is_whole_host_frames() {
        let (p, seq) = project_with(Time::new(10, 1));
        assert_eq!(p.nested_length(seq, Time::new(1, 25)), Some(Time::new(10, 1)));
        // 1/30 s long in a 25 fps host: rounds up to 2/25 > 1/30, so it drops to the frame count that fits (at least one).
        let (q, one) = project_with(Time::new(1, 30));
        assert_eq!(q.nested_length(one, Time::new(1, 25)), Some(Time::new(1, 25)));
        assert_eq!(p.nested_length(Id::from_u128(99), Time::new(1, 25)), None);
    }
}
