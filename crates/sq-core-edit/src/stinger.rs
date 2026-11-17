//! N6b Stinger transition, project side: picking a Library clip.
// Swift: Stinger.swift (`containsStinger`, the v38 gate, is `stinger` in sq-core-file's gates)

use sq_core_effects::transition::{TimelineTransitions, TransitionChange};
use sq_core_model::{EditError, Project, TransitionStinger};
use sq_core_time::{Id, Time};

/// Swift `Project.setStinger(transition:media:cutFraction:in:)`.
pub trait StingerExt {
    /// Makes cut transition `id` a Stinger playing media `media`: the transition takes the clip's length (whole frames)
    /// and its picture is scaled to fit the sequence frame. Errors `ClipNotFound` for unknown media or transition,
    /// `WrongTrackKind` for media without a picture, `TimelineNotFound`, `TrackLocked`, `NotACut`.
    fn set_stinger(&mut self, transition: Id, media: Id, cut_fraction: f64, timeline: Id) -> Result<(), EditError>;
}

impl StingerExt for Project {
    fn set_stinger(&mut self, transition: Id, media: Id, cut_fraction: f64, timeline: Id) -> Result<(), EditError> {
        let m = self.media(media).ok_or(EditError::ClipNotFound)?.clone();
        if m.info.as_ref().is_some_and(|i| i.video.is_none()) {
            return Err(EditError::WrongTrackKind);
        }
        self.edit(timeline, |t| {
            let fd = t.format.frame_duration;
            let scale = m
                .info
                .as_ref()
                .and_then(|i| i.video.as_ref())
                .map(|v| t.format.fit_scale(v.display_width(), v.display_height()));
            t.set_stinger(transition, Some(TransitionStinger { media, cut_fraction, scale }))?;
            if let Some(d) = m.info.as_ref().map(|i| i.duration).or(m.duration).filter(|d| *d > Time::ZERO) {
                let change =
                    TransitionChange { duration: Some(fd * 1.max(d.frame_index(fd))), ..TransitionChange::default() };
                t.set_transition(transition, &change)?;
            }
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaInfo, MediaRef, SequenceFormat, Timeline};

    fn project(video: bool) -> (Project, Id, Id) {
        let mut j = serde_json::json!({"duration": {"value": 30, "timescale": 30}});
        if video {
            j["video"] = serde_json::json!({"width": 3840, "height": 2160, "codec": "ap4h", "bitDepth": 12, "chroma": "4:4:4",
                "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false});
        }
        let info: MediaInfo = serde_json::from_value(j).unwrap();
        let mut m = MediaRef::new(Id::from_u128(5), "Stinger", "/s.mov", MediaFingerprint::new(1));
        m.info = Some(info);
        let t = Timeline::new(Id::from_u128(6), "T", SequenceFormat::new(Time::new(1, 30)), vec![]);
        (Project::new(Id::from_u128(7), "P", vec![m], vec![t]), Id::from_u128(5), Id::from_u128(6))
    }

    #[test]
    fn unknown_or_picture_less_media_is_refused_before_anything_changes() {
        let (mut p, _, t) = project(true);
        assert_eq!(p.set_stinger(Id::from_u128(1), Id::from_u128(404), 0.5, t), Err(EditError::ClipNotFound));
        let (mut audio, m, t) = project(false);
        let before = audio.clone();
        assert_eq!(audio.set_stinger(Id::from_u128(1), m, 0.5, t), Err(EditError::WrongTrackKind));
        assert_eq!(audio, before);
        // A picture clip reaches the sequence edit, which knows no such transition.
        assert!(p.set_stinger(Id::from_u128(1), Id::from_u128(5), 0.5, t).is_err());
    }
}
