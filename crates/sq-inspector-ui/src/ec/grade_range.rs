// Swift: EffectControlsModel+GradeRange.swift
//! COLOR-GRADE-LINKS follow-up: range of a range grade (a Color effect with `color_range`) edited in Effect Controls.

use sq_core_model::ClipEffect;
use sq_core_time::{Id, Time, TimeRange};

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::prelude::*;

/// Fade-in / fade-out lengths of a range grade.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GradeFades {
    pub fade_in: Time,
    pub fade_out: Time,
}

impl EffectControlsModel {
    /// Steps of the Color Graph effect `effect` (the Pro grade row's "N Steps").
    pub fn color_graph_step_count(&self, effect: Id) -> usize {
        self.clip
            .as_ref()
            .and_then(|c| c.effects.iter().find(|e| e.id == effect && e.kind == ClipEffect::COLOR_GRAPH_KIND))
            .and_then(|e| e.color_graph.as_ref())
            .map_or(0, |g| g.steps().len())
    }

    /// The clip-local range of Color effect `effect`, nil for a whole-clip grade.
    pub fn grade_range(&self, effect: Id) -> Option<TimeRange> {
        self.clip.as_ref()?.effects.iter().find(|e| e.id == effect && e.is_color())?.color_range
    }

    /// Color effects of the shown clip that grade only a range (they get a Range row under their header).
    pub fn grade_range_effects(&self) -> Vec<Id> {
        self.clip
            .as_ref()
            .map(|c| c.effects.iter().filter(|e| e.is_range_grade()).map(|e| e.id).collect())
            .unwrap_or_default()
    }

    /// Moves the start and/or end (clip-local, cut to the clip). Refused when the result is empty or reversed.
    pub fn set_grade_range(&mut self, effect: Id, start: Option<Time>, end: Option<Time>) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(r) = c.effects.iter().find(|e| e.id == effect).and_then(|e| e.color_range) else { return };
        let s = start.unwrap_or(r.start).max(Time::ZERO);
        let e = end.unwrap_or(r.end()).min(c.duration());
        if s >= e {
            return;
        }
        let new = TimeRange::from_end(s, e);
        if new == r || !c.set_color_range(effect, Some(new)) {
            return;
        }
        self.commit(c, "Set Grade Range", None);
    }

    /// Drops the range: the effect grades the whole clip again.
    pub fn set_grade_whole_clip(&mut self, effect: Id) {
        let Some(mut c) = self.working_clip() else { return };
        if !c.set_color_range(effect, None) {
            return;
        }
        self.commit(c, "Grade Whole Clip", None);
    }

    /// Fade-in / fade-out lengths of a range grade (soft edges); zero = hard edge.
    pub fn grade_fades(&self, effect: Id) -> GradeFades {
        let fx = self.clip.as_ref().and_then(|c| c.effects.iter().find(|e| e.id == effect && e.is_color()));
        GradeFades {
            fade_in: fx.and_then(|e| e.color_fade_in).unwrap_or(Time::ZERO),
            fade_out: fx.and_then(|e| e.color_fade_out).unwrap_or(Time::ZERO),
        }
    }

    /// Sets one or both fade lengths (clamped to the range). One undo step.
    pub fn set_grade_fades(&mut self, effect: Id, fade_in: Option<Time>, fade_out: Option<Time>) {
        let Some(mut c) = self.working_clip() else { return };
        let cur = self.grade_fades(effect);
        if !c.set_color_range_fades(
            effect,
            Some(fade_in.unwrap_or(cur.fade_in)),
            Some(fade_out.unwrap_or(cur.fade_out)),
        ) {
            return;
        }
        let new = c.effects.iter().find(|e| e.id == effect);
        let old = self.clip.as_ref().and_then(|c| c.effects.iter().find(|e| e.id == effect));
        if new.map(|e| (e.color_fade_in, e.color_fade_out)) == old.map(|e| (e.color_fade_in, e.color_fade_out)) {
            return;
        }
        self.commit(c, "Set Grade Fade", None);
    }
}
