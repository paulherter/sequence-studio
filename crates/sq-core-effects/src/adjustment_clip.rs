// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AdjustmentClip.swift (`LayerRequest.isAdjustment` waits on the evaluation port; the file-version gates
//        `containsAdjustmentClips`, `containsExtendedBlendModes`, `containsFullBlendModes` live in sq-core-file)
//! Adjustment Layer: a generator clip without a picture of its own. Its effects (Crop, Blur, Ultra Key, filters, masks),
//! Motion, Opacity and blend mode apply to everything composited below it on lower tracks of the same sequence, for as long
//! as it lasts. The renderer composites the layers below into one image, runs the clip's effects on it and draws that over
//! the unadjusted image with the clip's opacity and blend mode.

use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{Clip, EditError, GeneratorRef, Project};
use sq_core_time::{Id, IdSource, Time};

/// Kind of the Adjustment Layer generator (Swift `GeneratorRef.adjustment`).
pub const ADJUSTMENT_KIND: &str = "adjustment";

/// The Adjustment Layer generator (Swift `GeneratorRef.adjustmentLayer`).
pub fn adjustment_layer() -> GeneratorRef {
    GeneratorRef { kind: ADJUSTMENT_KIND.to_string(), payload: Vec::new(), payload_version: 1 }
}

/// Swift `Clip.isAdjustment`.
pub trait ClipAdjustmentExt {
    /// The clip is an Adjustment Layer.
    fn is_adjustment(&self) -> bool;
}

impl ClipAdjustmentExt for Clip {
    fn is_adjustment(&self) -> bool {
        self.generator.as_ref().is_some_and(|g| g.kind == ADJUSTMENT_KIND)
    }
}

/// Swift `extension Project` in AdjustmentClip.swift.
pub trait ProjectAdjustmentExt {
    /// Places an Adjustment Layer on a video track (overwrite, like any generator drop). Errors like `add_generator_clip`.
    fn add_adjustment_clip(
        &mut self,
        timeline: Id,
        start: Time,
        track: Id,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
}

impl ProjectAdjustmentExt for Project {
    fn add_adjustment_clip(
        &mut self,
        timeline: Id,
        start: Time,
        track: Id,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        self.add_generator_clip(
            adjustment_layer(),
            Some("Adjustment Layer"),
            GeneratorPlacement { timeline, track, start, duration },
            ids,
        )
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

    fn project(ids: &mut SequentialIds) -> (Project, Id, Id, Id) {
        let tracks: Vec<Track> =
            [TrackKind::Video, TrackKind::Video, TrackKind::Audio].map(|k| Track::new(ids.next_id(), k)).to_vec();
        let (v1, v2) = (tracks[0].id, tracks[1].id);
        let t = Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), tracks);
        let tl = t.id;
        (Project::new(ids.next_id(), "P", Vec::new(), vec![t]), tl, v1, v2)
    }

    fn find(p: &Project, tl: Id, id: Id) -> Clip {
        p.timeline(tl).unwrap().tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id).unwrap().clone()
    }

    #[test]
    fn add_places_an_adjustment_layer_without_media() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, _, v2) = project(&mut ids);
        let id = p.add_adjustment_clip(tl, s(1), v2, s(4), &mut ids).unwrap();
        let c = find(&p, tl, id);
        assert!(c.is_adjustment() && c.is_generator() && c.kind == TrackKind::Video);
        assert_eq!(c.generator.as_ref().map(|g| g.kind.as_str()), Some(ADJUSTMENT_KIND));
        assert_eq!(c.name, "Adjustment Layer");
        assert_eq!(c.timeline(), TimeRange::new(s(1), s(4)));
        assert_eq!(c.media_duration, None);
    }

    #[test]
    fn refuses_audio_tracks_and_empty_lengths() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, v1, _) = project(&mut ids);
        let audio = p.timeline(tl).unwrap().tracks[2].id;
        assert_eq!(p.add_adjustment_clip(tl, s(0), audio, s(1), &mut ids), Err(EditError::WrongTrackKind));
        assert_eq!(p.add_adjustment_clip(tl, s(0), v1, Time::new(1, 60), &mut ids), Err(EditError::EmptyClip));
    }
}
