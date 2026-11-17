//! Generator clips (text layers): clips without media, see `Clip.generator`.
// Swift: Generators.swift (`addGeneratorClip` is `Project::add_generator_clip` in sq-core-model)

use sq_core_model::{EditError, Project};
use sq_core_time::Id;

/// Swift `Project.updateGenerator`.
pub trait GeneratorsExt {
    /// Replaces a generator clip's payload (text edit). Position, length and animation stay. A single mutation,
    /// so callers get one undo step. Errors `ClipNotFound` for an unknown clip or one that is not a generator,
    /// `TrackLocked` on a locked track.
    fn update_generator(
        &mut self,
        clip_id: Id,
        payload: Vec<u8>,
        payload_version: Option<i64>,
    ) -> Result<(), EditError>;
}

impl GeneratorsExt for Project {
    fn update_generator(
        &mut self,
        clip_id: Id,
        payload: Vec<u8>,
        payload_version: Option<i64>,
    ) -> Result<(), EditError> {
        for tl in &mut self.timelines {
            for track in &mut tl.tracks {
                let Some(mut c) = track.clips().iter().find(|c| c.id == clip_id).cloned() else { continue };
                let Some(mut g) = c.generator.take() else { return Err(EditError::ClipNotFound) };
                if track.is_locked {
                    return Err(EditError::TrackLocked);
                }
                g.payload = payload;
                if let Some(v) = payload_version {
                    g.payload_version = v;
                }
                c.generator = Some(g);
                track.replace(c);
                return Ok(());
            }
        }
        Err(EditError::ClipNotFound)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::project_media_ops::GeneratorPlacement;
    use sq_core_model::{Clip, GeneratorRef, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn project(ids: &mut SequentialIds) -> (Project, Id, Id) {
        use sq_core_time::IdSource;
        let v = Track::new(ids.next_id(), TrackKind::Video);
        let (vid, tid) = (v.id, ids.next_id());
        let t = Timeline::new(tid, "T", SequenceFormat::new(Time::new(1, 30)), vec![v]);
        (Project::new(ids.next_id(), "P", vec![], vec![t]), tid, vid)
    }
    fn text(payload: &[u8]) -> GeneratorRef {
        GeneratorRef { kind: "text".into(), payload: payload.to_vec(), payload_version: 1 }
    }

    #[test]
    fn update_replaces_the_payload_and_keeps_everything_else() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, v) = project(&mut ids);
        let at = GeneratorPlacement { timeline: tl, track: v, start: s(2), duration: s(3) };
        let id = p.add_generator_clip(text(b"old"), None, at, &mut ids).unwrap();
        let before = p.timeline(tl).unwrap().find(id).unwrap().clip;
        p.update_generator(id, b"new".to_vec(), Some(2)).unwrap();
        let mut after = p.timeline(tl).unwrap().find(id).unwrap().clip;
        assert_eq!(
            after.generator,
            Some(GeneratorRef { kind: "text".into(), payload: b"new".to_vec(), payload_version: 2 })
        );
        after.generator = before.generator.clone();
        assert_eq!(after, before);
        assert_eq!(p.update_generator(Id::from_u128(9999), b"x".to_vec(), None), Err(EditError::ClipNotFound));
    }

    #[test]
    fn update_refuses_a_media_clip_and_a_locked_track() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, v) = project(&mut ids);
        let m = Clip::new(
            Id::from_u128(77),
            "m",
            Id::from_u128(78),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(2)),
            Time::ZERO,
        );
        p.timelines[0].tracks[0].overwrite(m.clone(), &mut ids).unwrap();
        assert_eq!(p.update_generator(m.id, b"x".to_vec(), None), Err(EditError::ClipNotFound));
        let at = GeneratorPlacement { timeline: tl, track: v, start: s(5), duration: s(2) };
        let g = p.add_generator_clip(text(b"a"), None, at, &mut ids).unwrap();
        p.timelines[0].tracks[0].is_locked = true;
        assert_eq!(p.update_generator(g, b"b".to_vec(), None), Err(EditError::TrackLocked));
    }
}
