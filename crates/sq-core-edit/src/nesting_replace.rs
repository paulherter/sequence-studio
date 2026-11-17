//! Replace edit with a sequence.
// Swift: Nesting+Replace.swift

use sq_core_model::{Clip, ClipFootageColor, EditError, Project};
use sq_core_time::{Id, IdSource, Time};

use crate::nesting_place::NestingPlaceExt;

/// Swift `Project.replaceWithSequence(of:with:in:)`.
pub trait NestingReplaceExt {
    /// Replace edit with a sequence (Option-drop of a sequence onto a clip): the clip plays `sequence` as a nested clip
    /// instead, keeping position, timeline length, track, link, speed, effects and keys. The linked partner of the other
    /// kind follows when the sequence has that stream. The sequence plays from its start for the clip's source length.
    /// Errors: `NestingCycle` (the sequence is or contains the host), `InsufficientMedia` (the sequence is shorter than
    /// the played range), `WrongTrackKind` (an audio clip and a sequence without audio), `SpeedUnsupported` (stills,
    /// held frames, speed-remapped clips, generators), `TrackLocked`, `ClipNotFound`. Nothing changes on a refusal.
    fn replace_with_sequence(
        &mut self,
        clip_id: Id,
        sequence: Id,
        host: Id,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
}

fn swap(c: &Clip, p: &Clip) -> Clip {
    let mut n = c.clone();
    n.media = p.media;
    n.sequence = p.sequence;
    n.name = p.name.clone();
    n.media_duration = p.media_duration;
    n.angle = p.angle.clone();
    n.source.start = Time::ZERO;
    n.footage_color = ClipFootageColor::default();
    n.markers = None;
    n
}

impl NestingReplaceExt for Project {
    fn replace_with_sequence(
        &mut self,
        clip_id: Id,
        sequence: Id,
        host: Id,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let hi = self.timelines.iter().position(|t| t.id == host).ok_or(EditError::TimelineNotFound)?;
        let seq_duration = self.timeline(sequence).ok_or(EditError::TimelineNotFound)?.duration();
        if self.would_create_cycle(sequence, host) {
            return Err(EditError::NestingCycle);
        }
        let tl = self.timelines[hi].clone();
        let ti = tl.tracks.iter().position(|t| t.clip(clip_id).is_some()).ok_or(EditError::ClipNotFound)?;
        let old = tl.tracks[ti].clip(clip_id).ok_or(EditError::ClipNotFound)?.clone();
        if tl.tracks[ti].is_locked {
            return Err(EditError::TrackLocked);
        }
        if old.is_generator() || old.is_still || old.hold_frame.is_some() || old.speed_keys.is_some() {
            return Err(EditError::SpeedUnsupported);
        }
        let make = self.sequence_clips(sequence, Time::ZERO, ids).ok_or(EditError::EmptyClip)?;
        let len = match self.nested_length(sequence, tl.frame_duration()) {
            Some(len) if seq_duration > Time::ZERO => len,
            _ => return Err(EditError::EmptyClip),
        };
        let proto = make.iter().find(|c| c.kind == old.kind).ok_or(EditError::WrongTrackKind)?;
        if old.source.duration > len {
            return Err(EditError::InsufficientMedia);
        }
        let mut work = tl;
        work.tracks[ti].replace(swap(&old, proto));
        if let Some(link) = old.link {
            for pi in 0..work.tracks.len() {
                if pi == ti {
                    continue;
                }
                let Some(p) =
                    work.tracks[pi].clips().iter().find(|c| c.link == Some(link) && c.kind != old.kind).cloned()
                else {
                    continue;
                };
                let Some(pp) = make.iter().find(|c| c.kind == p.kind) else { continue };
                if work.tracks[pi].is_locked {
                    return Err(EditError::TrackLocked);
                }
                if p.source.duration > len {
                    return Err(EditError::InsufficientMedia);
                }
                work.tracks[pi].replace(swap(&p, pp));
            }
        }
        self.edit(host, |t| {
            *t = work;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(ids: &mut SequentialIds, start: i64, dur: i64, kind: TrackKind, link: Option<Id>) -> Clip {
        let mut c = Clip::new(ids.next_id(), "c", ids.next_id(), kind, TimeRange::new(Time::ZERO, s(dur)), s(start));
        c.link = link;
        c
    }
    fn track(ids: &mut SequentialIds, clips: Vec<Clip>, kind: TrackKind) -> Track {
        let mut t = Track::new(ids.next_id(), kind);
        for c in clips {
            t.overwrite(c, ids).unwrap();
        }
        t
    }
    fn seq(ids: &mut SequentialIds, name: &str, secs: i64, audio: bool) -> Timeline {
        let video = clip(ids, 0, secs, TrackKind::Video, None);
        let mut tracks = vec![track(ids, vec![video], TrackKind::Video)];
        if audio {
            let sound = clip(ids, 0, secs, TrackKind::Audio, None);
            tracks.push(track(ids, vec![sound], TrackKind::Audio));
        }
        Timeline::new(ids.next_id(), name, SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    #[test]
    fn clip_and_partner_play_sequence_keeping_position_and_length() {
        let mut ids = SequentialIds::default();
        let l = ids.next_id();
        let v = clip(&mut ids, 2, 4, TrackKind::Video, Some(l));
        let a = clip(&mut ids, 2, 4, TrackKind::Audio, Some(l));
        let tracks = vec![
            track(&mut ids, vec![v.clone()], TrackKind::Video),
            track(&mut ids, vec![a.clone()], TrackKind::Audio),
        ];
        let host = Timeline::new(ids.next_id(), "A", SequenceFormat::new(Time::new(1, 30)), tracks);
        let b = seq(&mut ids, "B", 6, true);
        let (host_id, b_id) = (host.id, b.id);
        let mut p = Project::new(ids.next_id(), "P", vec![], vec![host, b]);
        p.replace_with_sequence(v.id, b_id, host_id, &mut ids).unwrap();
        let t = p.timeline(host_id).unwrap();
        let (nv, na) = (&t.tracks[0].clips()[0], &t.tracks[1].clips()[0]);
        assert!(nv.id == v.id && nv.start == s(2) && nv.source.duration == s(4) && nv.sequence == Some(b_id));
        assert!(na.id == a.id && na.sequence == Some(b_id) && na.link == Some(l));
    }

    #[test]
    fn too_short_sequence_and_cycle_refuse_without_change() {
        let mut ids = SequentialIds::default();
        let v = clip(&mut ids, 0, 4, TrackKind::Video, None);
        let tracks = vec![track(&mut ids, vec![v.clone()], TrackKind::Video)];
        let host = Timeline::new(ids.next_id(), "A", SequenceFormat::new(Time::new(1, 30)), tracks);
        let b = seq(&mut ids, "B", 2, false);
        let (host_id, b_id) = (host.id, b.id);
        let mut p = Project::new(ids.next_id(), "P", vec![], vec![host, b]);
        let before = p.clone();
        assert_eq!(p.replace_with_sequence(v.id, b_id, host_id, &mut ids), Err(EditError::InsufficientMedia));
        assert_eq!(p.replace_with_sequence(v.id, host_id, host_id, &mut ids), Err(EditError::NestingCycle));
        assert_eq!(p, before);
    }
}
