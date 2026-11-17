//! Match Color to Clip and Color Matte clips.

use std::collections::BTreeSet;

use sq_core_color::color_match_solver;
use sq_core_color::{
    ClipEffectColorExt as _, ClipGradeExt as _, ColorEffectExt, ColorMatchClipExt as _, ColorMatchPair,
    ColorMatchStatsExt as _, ColorMatchTimelineExt as _, ColorMatteClipExt, ColorMatteColor, ColorMatteGeneratorExt,
    ColorSpaceIdExt as _,
};
use sq_core_edit::generators::GeneratorsExt;
use sq_core_edit::timeline_replace::TimelineReplaceExt as _;
use sq_core_edit::timeline_solo_views::TimelineSoloExt;
use sq_core_graphics::format_variants_view::ProjectVariantsExt;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{
    Clip, ClipColor, ColorMatchReference, ColorMatchStats, ColorSectionKind, ColorSpaceID, EditError, Timeline,
    TrackKind,
};
use sq_core_time::{Id, Time, TimeRange};

use crate::es05_captions_titles::generator_track;

use crate::EditorSession;
use crate::es01_session_core::TimecodeFormat;

/// What the Match Color to Clip command can do right now.
// Swift: EditorSession+ColorMatchToClip.swift:8
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ColorMatchToClipPlan {
    Ready(ColorMatchPair),
    Blocked(String),
}

/// The result of measuring and applying a match.
// Swift: EditorSession+ColorMatchToClip.swift:13
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorMatchToClipOutcome {
    Applied,
    AlreadyMatches,
    Unreadable,
}

impl EditorSession {
    // Swift: EditorSession+ColorMatchToClip.swift:22
    pub const COLOR_MATCH_NO_TARGET: &'static str = "Select a video clip to match its color.";
    // Swift: EditorSession+ColorMatchToClip.swift:23
    pub const COLOR_MATCH_NO_REFERENCE: &'static str =
        "Nothing to match to: put a clip on another track under the playhead, or a clip before this one on its track.";

    /// The clip the command grades: of the selected video clips (else the clips under the playhead) the one under the
    /// playhead on the highest track, else the last one.
    // Swift: EditorSession+ColorMatchToClip.swift:27
    fn color_match_target(&self) -> Option<Clip> {
        let locked: BTreeSet<Id> = self
            .active_timeline()
            .map(|t| t.tracks.iter().filter(|tr| tr.is_locked).flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect())
            .unwrap_or_default();
        let all: Vec<Clip> = self
            .command_clips(Some(TrackKind::Video))
            .into_iter()
            .filter(|c| c.is_color_match_picture() && c.accepts_color() && !locked.contains(&c.id))
            .collect();
        all.iter().rev().find(|c| c.timeline().contains(self.playhead)).or(all.last()).cloned()
    }

    /// Menu enabling: there is a clip to grade (the command reports any other problem).
    // Swift: EditorSession+ColorMatchToClip.swift:35
    pub fn has_color_match_target(&self) -> bool {
        self.color_match_target().is_some()
    }
    /// What the command would do now, or why it cannot.
    // Swift: EditorSession+ColorMatchToClip.swift:38
    pub fn color_match_to_clip_plan(&self) -> ColorMatchToClipPlan {
        let (Some(t), Some(target)) = (self.active_timeline(), self.color_match_target()) else {
            return ColorMatchToClipPlan::Blocked(Self::COLOR_MATCH_NO_TARGET.to_string());
        };
        let source = self.color_source(&target);
        if source != ColorSpaceID::Rec709 {
            return ColorMatchToClipPlan::Blocked(format!(
                "Match works on Rec. 709 footage. This clip is interpreted as {}; grade it by hand.",
                source.display_name()
            ));
        }
        if let Some(first) = target.color_grade_effects().first() {
            let e = first.color_effect(None, 1);
            if e.is_enabled(ColorSectionKind::Vignette) && !ColorEffectExt::is_neutral(&e, ColorSectionKind::Vignette) {
                return ColorMatchToClipPlan::Blocked(
                    "Match would measure the Vignette too. Reset or switch off Vignette first.".to_string(),
                );
            }
        }
        match t.color_match_pair(target.id, self.playhead) {
            Some(pair) => ColorMatchToClipPlan::Ready(pair),
            None => ColorMatchToClipPlan::Blocked(Self::COLOR_MATCH_NO_REFERENCE.to_string()),
        }
    }
    // Swift: EditorSession+ColorMatchToClip.swift:53
    pub fn color_match_solo_timeline(&self, id: Id) -> Option<Timeline> {
        let tid = self.active_timeline_id?;
        let view = self.project().variant_view(tid, self.active_variant_id())?;
        let c = view.timeline.tracks.iter().find_map(|tr| tr.clip(id))?;
        Some(view.timeline.soloing_video_clip(id, self.project().picture_size(c)))
    }
    // Swift: EditorSession+ColorMatchToClip.swift:60
    pub fn show_color_match_solo(&mut self, id: Id, at: Time) -> bool {
        let Some(tid) = self.active_timeline_id else { return false };
        let Some(view) = self.project().variant_view(tid, self.active_variant_id()) else { return false };
        let Some(solo) = self.color_match_solo_timeline(id) else { return false };
        self.engine.set_timeline(&solo, &view.sequences);
        self.engine.seek(at);
        true
    }
    // Swift: EditorSession+ColorMatchToClip.swift:69
    pub fn end_color_match_solo(&mut self) {
        self.push_timeline(true);
        let at = self.color_source_view.as_ref().map_or(self.playhead, |v| v.position);
        self.engine.seek(at);
    }
    // Swift: EditorSession+ColorMatchToClip.swift:75
    pub fn apply_color_match_to_clip(
        &mut self,
        pair: &ColorMatchPair,
        reference: &[[f32; 3]],
        target: &[[f32; 3]],
    ) -> ColorMatchToClipOutcome {
        let Some(tl) = self.active_timeline() else { return ColorMatchToClipOutcome::Unreadable };
        let Some(clip) = tl.tracks.iter().find_map(|tr| tr.clip(pair.target)).cloned() else {
            return ColorMatchToClipOutcome::Unreadable;
        };
        let to_v3 = |px: &[[f32; 3]]| color_match_solver::picture_samples(px);
        let Some(ref_stats) = ColorMatchStats::measure(&to_v3(reference)) else {
            return ColorMatchToClipOutcome::Unreadable;
        };
        let samples = to_v3(target);
        if samples.len() < 16 {
            return ColorMatchToClipOutcome::Unreadable;
        }
        let fd = tl.frame_duration();
        let local = (pair.target_time - clip.start).max(Time::ZERO).min((clip.duration() - fd).max(Time::ZERO));
        let effect = clip
            .color_grade_effects()
            .first()
            .map_or_else(|| ClipColor::default_effects().remove(0), |e| e.color_effect(Some(local), 1));
        let Some(result) = color_match_solver::solve_clip(&samples, &effect, &ref_stats) else {
            return ColorMatchToClipOutcome::AlreadyMatches;
        };
        let ref_name =
            tl.tracks.iter().find_map(|tr| tr.clip(pair.reference)).map_or("Clip".to_string(), |c| c.name.clone());
        let tc = TimecodeFormat::new(fd, true).string_for_time(pair.reference_time, fd);
        let reference_info = ColorMatchReference {
            clip: Some(pair.reference),
            time: pair.reference_time,
            label: format!("{ref_name} {tc}"),
            stats: ref_stats,
        };
        let ok = self.attempt_ids("Match Color to Clip", |t, ids| {
            let mut c = clip.clone();
            if !c.apply_color_match(&result, &reference_info, Some(local), ids) {
                return Err(EditError::EmptyClip);
            }
            t.replace_clip(c)
        });
        if ok { ColorMatchToClipOutcome::Applied } else { ColorMatchToClipOutcome::AlreadyMatches }
    }

    /// Places a Color Matte at `time` (default: playhead) on `track`, else on the topmost free video track.
    // Swift: EditorSession+ColorMatte.swift:8
    pub fn add_color_matte(
        &mut self,
        color: ColorMatteColor,
        name: &str,
        time: Option<Time>,
        track: Option<Id>,
        duration: Time,
    ) -> Option<Id> {
        let (Some(t), Some(tl)) = (self.active_timeline(), self.active_timeline_id) else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let fd = t.frame_duration();
        let start = time.unwrap_or(self.playhead).snapped(fd);
        let duration = duration.snapped(fd).max(fd);
        let Some(chosen) = generator_track(t, TimeRange::new(start, duration), track, true) else {
            self.set_error("There is no video track for the color matte.");
            return None;
        };
        let name = if name.is_empty() { "Color Matte" } else { name };
        let mut made = None;
        let lease = self.lend_ids();
        let ids = &mut lease.source();
        let result = self.try_perform("Add Color Matte", None, |p| {
            let at = GeneratorPlacement { timeline: tl, track: chosen, start, duration };
            made = Some(p.add_generator_clip(
                sq_core_model::GeneratorRef::color_matte(color),
                Some(name),
                at,
                &mut *ids,
            )?);
            Ok::<(), EditError>(())
        });
        self.return_ids(lease);
        if let Err(e) = result {
            self.set_error(e.to_string());
            return None;
        }
        if let Some(id) = made {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        made
    }
    /// Sets a Color Matte's color; calls of one gesture merge into one undo step.
    // Swift: EditorSession+ColorMatte.swift:28
    pub fn set_color_matte(&mut self, id: Id, color: ColorMatteColor, continues_gesture: bool) {
        let key = self.gesture_key("matte", id, continues_gesture);
        if self.clip_in_active(id).and_then(|c| c.matte_color()) == Some(color) {
            return;
        }
        let result = self.try_perform("Edit Color Matte", Some(&key), |p| {
            let is_matte = p
                .timelines
                .iter()
                .any(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.id == id && c.is_color_matte())));
            if !is_matte {
                return Err(EditError::ClipNotFound);
            }
            p.update_generator(id, color.bytes().to_vec(), None)
        });
        if let Err(e) = result {
            self.set_error(e.to_string());
        }
    }
}
