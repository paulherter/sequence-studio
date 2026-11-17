//! What identifies "the same camera" without a camera ID in the file, and Grade From Previous Clip / From Camera.
// Swift: CameraSignature.swift

use sq_core_color::{ClipGradeExt, remove_effect};
use sq_core_model::{ColorSpaceID, EditError, MediaInfo, Timeline};
use sq_core_time::{Id, IdSource, Time};

/// What identifies "the same camera" without a camera ID in the file: color space, frame size, frame rate, codec and
/// embedded look name.
// A heuristic, as in Swift: two cameras of one model and one setting are one signature (which is what "grade all from
// this camera" wants).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct CameraSignature {
    pub color_space: Option<ColorSpaceID>,
    pub width: i64,
    pub height: i64,
    pub frame_duration: Time,
    pub codec: String,
    pub embedded_lut_name: Option<String>,
}

impl CameraSignature {
    /// None for stills, audio-only media and media not probed yet.
    pub fn new(info: Option<&MediaInfo>) -> Option<CameraSignature> {
        let info = info.filter(|i| !i.is_still)?;
        let v = info.video.as_ref()?;
        Some(CameraSignature {
            color_space: info.detected_color_space,
            width: v.width,
            height: v.height,
            frame_duration: v.nominal_frame_duration,
            codec: v.codec.clone(),
            embedded_lut_name: info.embedded_lut_name.clone(),
        })
    }
}

/// Swift `Timeline.gradeFromPreviousClip` and `gradeAllFromCamera`.
pub trait CameraSignatureTimelineExt {
    /// Grade From Previous Clip: the Color effects and footage interpretation of the clip `back` places before `id` on
    /// its track (1 = the previous clip, 2 = the clip before that) replace the clip's own. Errors when there is none.
    fn grade_from_previous_clip(&mut self, id: Id, back: usize, ids: &mut dyn IdSource) -> Result<(), EditError>;

    /// Copies the Color effects (and the footage interpretation) of clip `source_id` onto every other video clip of this
    /// timeline whose media has the same camera signature (`signature(media)`). Returns how many clips changed. The
    /// target's own Color effects are replaced; its other effects stay. Errors when nothing matched.
    fn grade_all_from_camera(
        &mut self,
        source_id: Id,
        signature: impl Fn(Id) -> Option<CameraSignature>,
        ids: &mut dyn IdSource,
    ) -> Result<usize, EditError>;
}

/// Replaces the Color effects of `c` by copies of `fx` (new ids) at the front of its effect list.
fn replace_grade(c: &mut sq_core_model::Clip, fx: &[sq_core_model::ClipEffect], ids: &mut dyn IdSource) {
    for id in c.color_grade_effects().iter().map(|e| e.id) {
        remove_effect(c, id);
    }
    for (at, e) in fx.iter().enumerate() {
        let mut copy = e.clone();
        copy.id = ids.next_id();
        c.effects.insert(at.min(c.effects.len()), copy);
    }
}

impl CameraSignatureTimelineExt for Timeline {
    fn grade_from_previous_clip(&mut self, id: Id, back: usize, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let ti = self.tracks.iter().position(|t| t.clip(id).is_some()).ok_or(EditError::ClipNotFound)?;
        if self.tracks[ti].is_locked {
            return Err(EditError::TrackLocked);
        }
        let mut ordered = self.tracks[ti].clips().to_vec();
        ordered.sort_by_key(|c| c.start);
        let i = ordered.iter().position(|c| c.id == id).filter(|i| *i >= back).ok_or(EditError::EmptyClip)?;
        let src = ordered[i - back].clone();
        let mut c = ordered[i].clone();
        if !c.accepts_color() || !src.accepts_color() {
            return Err(EditError::EmptyClip);
        }
        replace_grade(&mut c, &src.color_grade_effects(), ids);
        c.footage_color = src.footage_color.clone();
        self.tracks[ti].replace(c);
        Ok(())
    }

    fn grade_all_from_camera(
        &mut self,
        source_id: Id,
        signature: impl Fn(Id) -> Option<CameraSignature>,
        ids: &mut dyn IdSource,
    ) -> Result<usize, EditError> {
        let src = self
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .find(|c| c.id == source_id)
            .cloned()
            .ok_or(EditError::EmptyClip)?;
        let sig = signature(src.media).ok_or(EditError::EmptyClip)?;
        let fx = src.color_grade_effects();
        let mut changed = 0;
        for ti in 0..self.tracks.len() {
            if self.tracks[ti].is_locked {
                continue;
            }
            let clips = self.tracks[ti].clips().to_vec();
            for mut c in clips {
                if c.id == source_id || !c.accepts_color() || signature(c.media).as_ref() != Some(&sig) {
                    continue;
                }
                replace_grade(&mut c, &fx, ids);
                c.footage_color = src.footage_color.clone();
                self.tracks[ti].replace(c);
                changed += 1;
            }
        }
        if changed == 0 {
            return Err(EditError::EmptyClip);
        }
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{COLOR_KIND, Clip, ClipEffect, SequenceFormat, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};
    use std::collections::HashMap;

    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn f(n: i64) -> Time {
        fd() * n
    }
    fn clip(ids: &mut SequentialIds, media: Id, start: i64) -> Clip {
        let mut c = Clip::new(ids.next_id(), "c", media, TrackKind::Video, TimeRange::new(Time::ZERO, f(30)), f(start));
        c.media_duration = Some(f(300));
        c
    }
    fn info(width: i64, space: Option<&str>) -> MediaInfo {
        let mut j = serde_json::json!({
            "duration": {"value": 300, "timescale": 30},
            "video": {"width": width, "height": 1080, "codec": "hvc1", "bitDepth": 10, "chroma": "420",
                      "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false},
        });
        if let Some(s) = space {
            j["detectedColorSpace"] = s.into();
        }
        serde_json::from_value(j).unwrap()
    }
    fn timeline(ids: &mut SequentialIds, clips: &[Clip]) -> Timeline {
        let mut track = Track::new(ids.next_id(), TrackKind::Video);
        for c in clips {
            track.overwrite(c.clone(), ids).unwrap();
        }
        Timeline::new(ids.next_id(), "T", SequenceFormat::new(fd()), vec![track])
    }
    fn with_grade(tl: &mut Timeline, ids: &mut SequentialIds, clip_index: usize) -> Id {
        let mut c = tl.tracks[0].clips()[clip_index].clone();
        let id = ids.next_id();
        c.effects.insert(0, ClipEffect::new(id, COLOR_KIND));
        tl.tracks[0].replace(c);
        id
    }

    #[test]
    fn grades_only_clips_of_the_same_camera() {
        let mut ids = SequentialIds::default();
        let (cam_a, cam_a2, cam_b) = (ids.next_id(), ids.next_id(), ids.next_id());
        let infos = HashMap::from([
            (cam_a, info(1920, Some("rec709"))),
            (cam_a2, info(1920, Some("rec709"))),
            (cam_b, info(3840, Some("rec709"))),
        ]);
        let clips = [clip(&mut ids, cam_a, 0), clip(&mut ids, cam_a2, 30), clip(&mut ids, cam_b, 60)];
        let mut tl = timeline(&mut ids, &clips);
        let graded = with_grade(&mut tl, &mut ids, 0);
        let n = tl.grade_all_from_camera(clips[0].id, |m| CameraSignature::new(infos.get(&m)), &mut ids).unwrap();
        assert_eq!(n, 1);
        let cs = tl.tracks[0].clips();
        assert_eq!(cs[1].color_grade_effects().len(), 1);
        assert_ne!(cs[1].color_grade_effects()[0].id, graded);
        assert!(cs[2].color_grade_effects().is_empty());
    }

    #[test]
    fn grade_from_previous_clip_copies_grade() {
        let mut ids = SequentialIds::default();
        let clips = [
            clip(&mut ids, Id::from_u128(1), 0),
            clip(&mut ids, Id::from_u128(2), 30),
            clip(&mut ids, Id::from_u128(3), 60),
        ];
        let mut tl = timeline(&mut ids, &clips);
        with_grade(&mut tl, &mut ids, 0);
        tl.grade_from_previous_clip(clips[2].id, 2, &mut ids).unwrap();
        assert_eq!(tl.tracks[0].clips()[2].color_grade_effects().len(), 1);
        assert!(tl.tracks[0].clips()[1].color_grade_effects().is_empty());
        assert_eq!(tl.grade_from_previous_clip(clips[0].id, 1, &mut ids), Err(EditError::EmptyClip));
    }

    #[test]
    fn errors_when_nothing_matches() {
        let mut ids = SequentialIds::default();
        let src = clip(&mut ids, Id::from_u128(9), 0);
        let mut tl = timeline(&mut ids, std::slice::from_ref(&src));
        let same = CameraSignature::new(Some(&info(1920, None)));
        assert_eq!(tl.grade_all_from_camera(src.id, |_| same.clone(), &mut ids), Err(EditError::EmptyClip));
    }
}
