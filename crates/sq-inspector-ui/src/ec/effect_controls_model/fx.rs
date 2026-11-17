// Swift: EffectControlsFX.swift, EffectControlsModel+SpeedKeys.swift
//! Effect instances in Effect Controls: fx toggle for the fixed sections, reorder, duplicate, cut / clear, blend mode, and
//! the Speed section (clip retime through the session, one undo step each). Speed edits take the session as a
//! parameter (the Swift model held it weakly).

use sq_core_edit::timeline_speed::SpeedChange;
use sq_core_effects::effects_editing::ClipEffectsEditingExt;
use sq_core_model::{BlendMode, ClipEffect, ClipSpeed, TimeInterpolation, TrackKind};
use sq_core_time::Time;
use sq_editor_session::{EditorSession, EffectSection};
use sq_uikit::keyframe_control_state::KeyframeControlState;

use super::core::EffectControlsModel;
use super::property::{EffectProperty, StopwatchOutcome};

impl EffectControlsModel {
    // MARK: fx toggle of Motion and Opacity

    /// Motion, Opacity and every applied effect have an fx toggle; Volume does not (audio has its own side).
    pub fn has_fx_toggle(&self, s: &EffectSection) -> bool {
        *s != EffectSection::Volume && *s != EffectSection::Speed
    }

    // MARK: Reorder and duplicate

    /// Position of an effect section among the applied effects (0 = first = evaluated first); nil for fixed sections.
    pub fn effect_index(&self, s: &EffectSection) -> Option<usize> {
        let id = s.effect_id()?;
        self.clip.as_ref()?.effects.iter().position(|e| e.id == id)
    }

    /// Moves an applied effect to list position `index` (clamped). The list order is the evaluation order, so the picture
    /// changes accordingly. Returns false when nothing moved.
    pub fn move_effect(&mut self, s: &EffectSection, to_index: i64) -> bool {
        let (Some(id), Some(mut c)) = (s.effect_id(), self.clip.clone()) else { return false };
        if !c.move_effect(id, to_index) {
            return false;
        }
        self.commit(c, "Reorder Effects", None);
        true
    }

    /// A second instance with the same values right behind the original.
    pub fn duplicate_effect(&mut self, s: &EffectSection) -> bool {
        let (Some(id), Some(mut c)) = (s.effect_id(), self.clip.clone()) else { return false };
        if c.duplicate_effect(id, &mut *self.ids).is_none() {
            return false;
        }
        self.commit(c, "Duplicate Effect", None);
        true
    }

    /// Where a header dragged to `y` (content coordinates) lands among the effect headers, given each header's vertical
    /// midpoint in list order. Pure: the view feeds it the row geometry.
    pub fn drop_index(y: f64, midpoints: &[f64], dragging: usize) -> usize {
        let mut target = 0usize;
        for (i, m) in midpoints.iter().enumerate() {
            if i != dragging && y > *m {
                target += 1;
            }
        }
        target.min(midpoints.len().saturating_sub(1))
    }

    // MARK: Cut and Clear (effect header menu)

    /// Cut: copy the effect, then remove it.
    pub fn cut_effect(&mut self, s: &EffectSection) -> bool {
        if !(self.can_remove_effect(s) && self.copy_effect(s)) {
            return false;
        }
        self.last_copy_was_keys = false;
        self.remove_effect(s)
    }

    /// The effect copy button of a header menu: Paste then pastes the effect, not keys.
    pub fn mark_effect_copied(&mut self) {
        self.last_copy_was_keys = false;
    }

    // MARK: Blend mode

    pub fn blend_mode(&self) -> BlendMode {
        self.clip.as_ref().map_or(BlendMode::Normal, |c| c.blend_mode)
    }

    pub fn set_blend_mode(&mut self, m: BlendMode) {
        let Some(mut c) = self.clip.clone() else { return };
        if c.kind != TrackKind::Video || !(c.blend_mode != m || self.is_blend_mode_mixed()) {
            return;
        }
        c.blend_mode = m;
        // Multi-select: every selected picture clip gets the mode, one undo step.
        let others = if self.is_multi() {
            let base = self.peer_gesture_base.clone().unwrap_or_else(|| self.peers.clone());
            Some(
                base.into_iter()
                    .map(|mut o| {
                        if o.kind == TrackKind::Video {
                            o.blend_mode = m;
                        }
                        o
                    })
                    .collect(),
            )
        } else {
            None
        };
        self.commit(c, "Change Blend Mode", others);
    }

    // MARK: Speed section (clip retime through the session, one undo step each)

    /// Constant speed of the shown clip in percent (100 = normal).
    pub fn speed_percent(&self) -> f64 {
        let Some(c) = &self.clip else { return 100.0 };
        // Animated speed: the field shows the speed at the playhead (like every keyframed row).
        if let Some(k) = &c.speed_keys
            && self.speed_is_animated()
        {
            let last = (k.duration() - self.frame_duration).max(Time::ZERO);
            return k.speed_value(self.local_playhead().max(Time::ZERO).min(last)) * 100.0;
        }
        c.speed.num() as f64 / c.speed.den() as f64 * 100.0
    }

    pub fn is_reversed(&self) -> bool {
        self.clip.as_ref().is_some_and(|c| c.reversed)
    }

    pub fn keeps_pitch(&self) -> bool {
        self.clip.as_ref().is_none_or(|c| c.keeps_pitch)
    }

    pub fn set_speed_percent(&mut self, session: &mut EditorSession, percent: f64) {
        let Some(c) = self.clip.clone() else { return };
        if !(percent.is_finite() && percent > 0.0) {
            return;
        }
        // Animated speed: the value is set at the playhead (a key appears there), neighbors ramp with their ease. The
        // playhead is clamped into the clip, so a typed value never falls through to the constant-speed path (which would
        // rescale the whole track). With several clips selected only the shown clip takes the value.
        if self.speed_is_animated() {
            let at = self.local_playhead().max(Time::ZERO).min((c.duration() - self.frame_duration).max(Time::ZERO));
            session.set_speed_key_value(c.id, at, ClipSpeed::from_percent(percent));
            return;
        }
        session.apply_speed(SpeedChange { speed: Some(ClipSpeed::from_percent(percent)), ..SpeedChange::default() });
    }

    pub fn begin_speed_gesture(&self, session: &mut EditorSession) {
        session.begin_speed_gesture();
    }

    pub fn end_speed_gesture(&self, session: &mut EditorSession) {
        session.end_speed_gesture();
    }

    pub fn set_reversed_clip(&self, session: &mut EditorSession, on: bool) {
        session.set_reversed(on);
    }

    /// How the frames between two source frames are filled (the Speed dialog's choice; one undo step).
    pub fn time_interpolation(&self) -> TimeInterpolation {
        self.clip.as_ref().map_or(TimeInterpolation::FrameSampling, |c| c.time_interpolation)
    }

    pub fn set_time_interpolation(&self, session: &mut EditorSession, t: TimeInterpolation) {
        session.apply_speed(SpeedChange { time_interpolation: Some(t), ..SpeedChange::default() });
    }

    pub fn set_keeps_pitch_clip(&self, session: &mut EditorSession, on: bool) {
        session.apply_speed(SpeedChange { keeps_pitch: Some(on), ..SpeedChange::default() });
    }

    pub fn reset_speed_with(&self, session: &mut EditorSession) {
        session.apply_speed(SpeedChange {
            speed: Some(ClipSpeed::NORMAL),
            reversed: Some(false),
            keeps_pitch: Some(true),
            time_interpolation: Some(TimeInterpolation::FrameSampling),
            ..SpeedChange::default()
        });
    }

    /// Reset of the Speed section needs the session; `reset_section` on `Speed` asks the owner through this event.
    pub(crate) fn reset_speed(&mut self) {
        self.events.push(super::core::EffectControlsEvent::ResetSpeed);
    }

    // MARK: Speed keys

    /// Clip-local times of the speed keys (interior boundaries of the speed track), ascending.
    pub fn speed_key_times(&self) -> Vec<Time> {
        let Some(k) = self.clip.as_ref().and_then(|c| c.speed_keys.as_ref()) else { return Vec::new() };
        let b = k.boundaries();
        if b.len() > 2 { b[1..b.len() - 1].to_vec() } else { Vec::new() }
    }

    /// Only video clips carry speed keys (the band is video only); audio and stills show the plain Speed field.
    pub fn speed_keys_available(&self) -> bool {
        self.clip.as_ref().is_some_and(|c| c.kind == TrackKind::Video) && self.has_session
    }

    pub fn speed_is_animated(&self) -> bool {
        !self.speed_key_times().is_empty()
    }

    pub fn speed_key_boundary(&self, local: Time) -> Option<usize> {
        let t = local.snapped(self.frame_duration);
        self.speed_key_times().iter().position(|x| *x == t).map(|i| i + 1)
    }

    pub fn previous_speed_key_time(&self) -> Option<Time> {
        let l = self.local_playhead();
        let t = self.speed_key_times().into_iter().rfind(|t| *t < l)?;
        Some(t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start))
    }

    pub fn next_speed_key_time(&self) -> Option<Time> {
        let l = self.local_playhead();
        let t = self.speed_key_times().into_iter().find(|t| *t > l)?;
        Some(t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start))
    }

    pub fn speed_key_control_state(&self) -> KeyframeControlState {
        KeyframeControlState::resolve(
            self.speed_is_animated(),
            self.speed_key_boundary(self.local_playhead()).is_some(),
            self.previous_speed_key_time().is_some(),
            self.next_speed_key_time().is_some(),
            self.playhead_in_clip(),
        )
    }

    pub fn go_to_previous_speed_key(&mut self) {
        if let Some(t) = self.previous_speed_key_time() {
            self.reveal_playhead(t);
            self.seek(t);
        }
    }

    pub fn go_to_next_speed_key(&mut self) {
        if let Some(t) = self.next_speed_key_time() {
            self.reveal_playhead(t);
            self.seek(t);
        }
    }

    /// The diamond: a key at the playhead is removed, otherwise one is added (speed stays as it is). One undo step.
    pub fn toggle_speed_key_at_playhead(&mut self, session: &mut EditorSession) -> bool {
        if !(self.speed_keys_available() && self.playhead_in_clip()) {
            return false;
        }
        let Some(id) = self.clip_id() else { return false };
        if let Some(b) = self.speed_key_boundary(self.local_playhead()) {
            return session.remove_speed_key(id, b);
        }
        session.add_speed_key(id, self.local_playhead())
    }

    /// The left switch of the Speed row. On -> off (keys exist) asks first, then removes the ramp through the menu command's
    /// path (Clip > Remove Speed Ramp, one undo step). Off -> on adds the first key at the playhead like every other row.
    pub fn toggle_speed_animation(&mut self, session: &mut EditorSession, confirm_removal: bool) -> StopwatchOutcome {
        if !self.speed_keys_available() {
            return StopwatchOutcome::Unavailable;
        }
        if self.speed_is_animated() {
            if !confirm_removal {
                return StopwatchOutcome::NeedsConfirmation;
            }
            return if session.remove_time_remapping() {
                StopwatchOutcome::Removed
            } else {
                StopwatchOutcome::Unavailable
            };
        }
        if self.toggle_speed_key_at_playhead(session) { StopwatchOutcome::Added } else { StopwatchOutcome::Unavailable }
    }

    /// True when the speed track has a transition between two different key values (something to ease).
    pub fn speed_has_transition(&self) -> bool {
        self.clip.as_ref().and_then(|c| c.speed_keys.as_ref()).is_some_and(|k| k.segments.iter().any(|s| s.is_ramp()))
    }

    // MARK: Color Key eyedropper (portable half)

    /// The Key Hue row of a Color Key effect.
    pub fn is_key_hue(p: &EffectProperty) -> bool {
        let EffectProperty::Fx { kind, key, .. } = p else { return false };
        kind == ClipEffect::ULTRA_KEY_KIND && key == ClipEffect::KEY_HUE_KEY
    }

    pub(crate) const KEY_PICK_GRAY_NOTICE: &'static str =
        "That spot is gray or black: pick a spot of the screen color.";

    /// Sets Key Hue to the hue of a linear-light sample (one undo step); a gray or black spot only shows the notice.
    pub fn apply_key_color(&mut self, p: &EffectProperty, linear: [f32; 3]) {
        if !Self::is_key_hue(p) {
            return;
        }
        let Some(hue) = sq_core_color::key_color_pick::hue_from_linear(linear) else {
            self.notice(Self::KEY_PICK_GRAY_NOTICE);
            return;
        };
        self.set_value(p, super::property::EffectComponent::All, hue);
    }

    /// An sRGB-encoded sample (a screen pick) as linear light, for `apply_key_color`.
    pub fn linear_from_srgb(r: f64, g: f64, b: f64) -> [f32; 3] {
        let lin = |v: f64| -> f32 {
            let c = v.clamp(0.0, 1.0);
            (if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }) as f32
        };
        [lin(r), lin(g), lin(b)]
    }
}
