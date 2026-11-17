// Swift: EffectControlsModel+ColorMatch.swift
//! FB-B3 Color Match (Premiere Lumetri "Match"): a reference frame's statistics are stored with the Color effect;
//! Match solves the Color Wheels that bring the clip's frame to them. The host samples the Program frame
//! (`EffectControlsEvent::ColorMatch`).

use sq_core_color::color_match_solver;
use sq_core_model::{ColorMatchReference, ColorSpaceID};
use sq_core_time::Id;
use sq_uikit::localization::SQL10n;

use crate::ec::effect_controls_model::core::{EffectControlsEvent, EffectControlsModel};
use crate::ec::prelude::*;

/// What the host does with the Match row's buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorMatchRequest {
    SetReference,
    Match,
}

impl ColorMatchRequest {
    /// The capture key of the button's frame (Swift `sampleLinear(key:)`).
    pub fn key(self) -> &'static str {
        match self {
            ColorMatchRequest::SetReference => "color.match.reference",
            ColorMatchRequest::Match => "color.match",
        }
    }
}

impl EffectControlsModel {
    /// The stored reference of a Color effect.
    pub fn color_match_reference(&self, effect: Id) -> Option<ColorMatchReference> {
        self.clip.as_ref()?.effects.iter().find(|e| e.id == effect)?.color_data().match_reference
    }

    /// The Color effect as edited at the playhead (keyframed wheels evaluated there).
    fn color_match_effect(&self, effect: Id) -> Option<sq_core_model::ColorEffect> {
        let c = self.clip.as_ref()?;
        let e = c.effects.iter().find(|e| e.id == effect)?;
        if !e.is_color() {
            return None;
        }
        Some(e.color_effect(c.color_edit_time(self.playhead, self.frame_duration), 1))
    }

    /// Why Match cannot run (nil = it can). `source` defaults to the clip's own interpretation (else Rec. 709).
    pub fn color_match_block(
        &self,
        effect: Id,
        source: Option<ColorSpaceID>,
        color_source_of: Option<&dyn Fn(&sq_core_model::Clip) -> ColorSpaceID>,
    ) -> Option<String> {
        let Some(e) = self.color_match_effect(effect) else { return Some(SQL10n::string("No Color effect.")) };
        let c = self.clip.as_ref();
        if c.is_none_or(|c| c.color_edit_time(self.playhead, self.frame_duration).is_none()) {
            return Some(SQL10n::string("Park the playhead on this clip to match it."));
        }
        let src = source
            .or_else(|| {
                c.map(|c| {
                    color_source_of.map_or_else(|| c.footage_color.source.unwrap_or(ColorSpaceID::Rec709), |f| f(c))
                })
            })
            .unwrap_or(ColorSpaceID::Rec709);
        color_match_solver::block_reason(&e, src, self.color_match_reference(effect).as_ref())
            .map(|m| SQL10n::localized(&m))
    }

    /// Stores (or with nil removes) the reference of a Color effect. One undo step.
    pub fn set_color_match_reference(&mut self, effect: Id, reference: Option<ColorMatchReference>) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == effect) else { return };
        if !c.effects[i].is_color() {
            return;
        }
        let mut g = c.effects[i].color_data();
        if g.match_reference == reference {
            return;
        }
        let clearing = reference.is_none();
        g.match_reference = reference;
        c.effects[i].grade = Some(g);
        self.commit(c, if clearing { "Clear Match Reference" } else { "Set Match Reference" }, None);
    }

    /// The clip's frame as shown (display-encoded samples) is matched to the reference: Color Wheels and Wheels Saturation
    /// are set (keyed at the playhead when they are keyframed). One undo step. False when blocked or nothing changes.
    pub fn apply_color_match(&mut self, effect: Id, display: &[[f32; 3]], source: Option<ColorSpaceID>) -> bool {
        if self.color_match_block(effect, source, None).is_some() {
            return false;
        }
        let (Some(reference), Some(e)) = (self.color_match_reference(effect), self.color_match_effect(effect)) else {
            return false;
        };
        let Some(w) = color_match_solver::solve(display, &e.wheels, &reference.stats) else { return false };
        let Some(mut c) = self.working_clip() else { return false };
        let Some(i) = c.effects.iter().position(|x| x.id == effect) else { return false };
        let t = c.color_edit_time(self.playhead, self.frame_duration);
        let mut ne = c.effects[i].color_effect(t, 1);
        ne.wheels = w;
        c.effects[i].set_color_effect(&ne, t, &mut *self.ids);
        self.commit(c, "Match Color", None);
        true
    }

    /// The Match row's buttons: the host samples the Program frame and calls back into the model.
    pub fn request_color_match(&mut self, effect: Id, request: ColorMatchRequest) {
        self.events.push(EffectControlsEvent::ColorMatch { effect, request });
    }
}
