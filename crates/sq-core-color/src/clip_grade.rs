// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGradeEffect.swift (`extension Clip`), ColorKeyframing.swift (`extension Clip`), ColorGradeLinks.swift
//        (range grades), ColorGradeFade.swift (`setColorRangeFades`), ColorGraph.swift (`extension Clip`)
//! The clip's color as the Color inspector edits it: the footage interpretation plus every Color effect, the Pro grade
//! accessors, keyframing of one slider or wheel, range grades with soft edges, and the grade the renderer uses.
//!
//! New effects and keyframes take their ids from an `IdSource` (Swift draws random UUIDs).

use crate::color_effect::ClipColorExt;
use crate::color_grade_effect::{ClipEffectColorExt, ColorEffectScaleExt, ColorGradeFields, ColorScalarField};
use crate::color_graph::{ActiveGrade, ColorGraphExt};
use crate::color_match::color_match_solver::ColorMatchResult;
use sq_core_model::{
    Clip, ClipColor, ClipEffect, ClipFootageColor, ColorEffect, ColorGraph, ColorMatchReference, LUTRef, TrackKind,
};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, Time, TimeRange};

/// Kind of the Adjustment Layer generator (Swift `GeneratorRef.adjustment`).
const ADJUSTMENT_KIND: &str = "adjustment";

/// Kind of the Color Graph effect (stored string: never rename).
pub const COLOR_GRAPH_KIND: &str = "colorGraph";

/// The Color Graph effect (kind `colorGraph`) holding `graph`.
pub fn color_graph_effect(id: Id, graph: ColorGraph) -> ClipEffect {
    let mut e = ClipEffect::new(id, COLOR_GRAPH_KIND);
    e.color_graph = Some(graph);
    e
}

/// Removes an effect from the clip and its per-variant parameter overrides (Swift: `Clip.removeEffect`).
///
/// The one implementation: the grade edits in this crate remove effects too and the effects crate sits above this one,
/// so `ClipEffectsEditingExt::remove_effect` there forwards to this function.
pub fn remove_effect(clip: &mut Clip, id: Id) -> bool {
    let Some(i) = clip.effects.iter().position(|e| e.id == id) else { return false };
    clip.effects.remove(i);
    if let Some(v) = clip.variant_store.as_mut() {
        for o in v.items.values_mut() {
            o.effect_parameters.remove(&id);
        }
    }
    true
}

/// A copy of the effect with a new id (Swift: `ClipEffect.copy()`).
fn copy_with_id(e: &ClipEffect, id: Id) -> ClipEffect {
    let mut c = e.clone();
    c.id = id;
    c
}

/// The grade with the footage interpretation of `f` and these effects (Swift `ClipColor(footage:effects:)`).
fn clip_color_of(f: &ClipFootageColor, effects: Vec<ColorEffect>) -> ClipColor {
    let mut c = ClipColor::new(f.source, f.use_embedded_lut, effects);
    c.log_mode = f.log_mode;
    c.target_space = f.target_space;
    c.hdr_conform = f.hdr_conform;
    c
}

/// A neutral first Color effect with an automatic Input LUT.
pub(crate) fn neutral_base_grade(ids: &mut dyn IdSource) -> ClipEffect {
    ClipEffect::color_grade(ids.next_id(), &ColorEffect::new(1, Some(LUTRef::Automatic)), ids)
}

/// The Color inspector's view of a clip and the edits behind it.
pub trait ClipGradeExt {
    /// Indices of the Color effects in `effects`, in list order.
    fn color_effect_indices(&self) -> Vec<usize>;
    /// The clip's color: the footage interpretation plus every Color effect (static values; ids 1, 2, ... in list
    /// order). No Color effect = the neutral default.
    fn color(&self) -> ClipColor;
    /// The color shown at clip-local `t` (keyframed values evaluated there).
    fn color_at_local(&self, t: Time) -> ClipColor;
    /// Sets the color by inspector id: ids that exist update their effect, new ids append Color effects (behind the
    /// last one, or in front of the list), missing ids remove theirs. A neutral default grade on a clip without Color
    /// effects adds none. With `t` keyed values get a key at `t`.
    fn set_color(&mut self, c: &ClipColor, t: Option<Time>, ids: &mut dyn IdSource);
    /// Writes an inspector edit: `base` is the grade the inspector showed, `c` the grade after the edit. Only what
    /// changed between the two is written (keyed values get a key at `t`). False (and nothing changes) when the edit
    /// touches a keyed value and `t` is `None`.
    fn set_color_edited_from(
        &mut self,
        c: &ClipColor,
        base: &ClipColor,
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool;
    /// Clip-local time an inspector edit at `playhead` keys at: on the clip's frames (the last one at most), `None`
    /// when the playhead is not over the clip.
    fn color_edit_time(&self, playhead: Time, frame_duration: Time) -> Option<Time>;
    /// The renderer runs the color chain on media, stills and Adjustment Layers (on the picture below them): nested
    /// sequences, other generators (text, shapes, solids) and audio take no Color effect.
    fn accepts_color(&self) -> bool;
    /// True when a copy of `e` may be pasted onto this clip: a known effect, audio effects onto audio clips and the others onto
    /// video clips, Color only on clips that take it, generator-owned effects only on their generator.
    // Swift: ColorGradeEffect.swift:555
    fn can_accept_pasted_effect(&self, e: &ClipEffect) -> bool;
    /// The Color effects as stored (keys, the effect switch and all), in order.
    fn color_grade_effects(&self) -> Vec<ClipEffect>;
    /// Replaces every Color effect with copies of `fx` (new ids, keys and switches kept), first in the list. The
    /// footage interpretation stays. Empty = no grade (Reset). Ignored on clips that take no color.
    fn replace_color_grade(&mut self, fx: &[ClipEffect], ids: &mut dyn IdSource);
    /// Paste Grade "Add on top": copies of `fx` go behind the clip's own Color effects, which stay untouched. Without
    /// a grade this is `replace_color_grade`. Ignored on clips that take no color.
    fn add_color_grade_on_top(&mut self, fx: &[ClipEffect], ids: &mut dyn IdSource);
    /// Adds a pasted effect (new id). A Color effect goes behind the clip's Color effects (color stays first) and
    /// only on a clip that takes color; other effects are appended. Returns false when refused.
    fn insert_pasted_effect(&mut self, e: &ClipEffect, ids: &mut dyn IdSource) -> bool;
    /// The color the renderer uses at clip-local `t`: switched-off Color effects are skipped; when the first one is
    /// off, a neutral first effect with the same conversion stands in (its Input LUT and Basic Correction switch), so
    /// the footage converts exactly as before and later effects stay display-referred.
    /// `has_live_mask_input` is the masks rule for a Color effect that runs as a masked pass instead.
    fn render_color(&self, t: Time, has_live_mask_input: &dyn Fn(&ClipEffect) -> bool) -> ClipColor;
    /// v26 and older stored the grade inside `color`: its effects become Color effects in front of the list (unless
    /// the clip already has some, or the grade is the neutral default).
    ///
    /// The Clip decode calls this for a `color` key of a file older than v27.
    fn adopt_legacy_grade(&mut self, old: &ClipColor, ids: &mut dyn IdSource);

    /// The grade is keyed: any of these parameters of Color effect `n` (1-based) has keys.
    fn is_color_animated(&self, n: usize, keys: &[&str]) -> bool;
    /// Key times of these parameters of Color effect `n`, sorted and distinct.
    fn color_key_times(&self, n: usize, keys: &[&str]) -> Vec<Time>;
    /// There is a key at `t` on any of these parameters.
    fn has_color_key(&self, n: usize, keys: &[&str], t: Time) -> bool;
    /// Starts or stops animating one slider or wheel group (all its parameters together). Starting needs `t`; stopping
    /// keeps the value shown at `t`.
    fn set_color_animated(
        &mut self,
        on: bool,
        n: usize,
        keys: &[&str],
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool;
    /// Adds a key at `t` for all these parameters, or removes it when one is there.
    fn toggle_color_key(&mut self, n: usize, keys: &[&str], t: Time, ids: &mut dyn IdSource) -> bool;

    /// Range grades: every Color effect without a range.
    fn base_grade_effects(&self) -> Vec<ClipEffect>;
    /// `r` cut to the clip, `None` when it misses the clip.
    fn clamped_color_range(&self, r: TimeRange) -> Option<TimeRange>;
    /// Adds a range grade (a Color effect that grades only `range`, clip-local) behind the last Color effect.
    fn add_range_grade(&mut self, range: TimeRange, ids: &mut dyn IdSource) -> Option<Id>;
    /// Moves, sets or clears (`None`) the range of a Color effect. The first Color effect never keeps a range.
    fn set_color_range(&mut self, id: Id, range: Option<TimeRange>) -> bool;
    /// A range grade may not be the first Color effect: puts a neutral base grade in front. True when it did.
    fn ensure_base_under_range_grades(&mut self, ids: &mut dyn IdSource) -> bool;
    /// This Color effect grades at `t`: it is on, and a later effect with a range only inside its range.
    fn color_effect_renders(&self, e: &ClipEffect, position: usize, t: Time) -> bool;
    /// Sets (or clears with `None`) the fade-in / fade-out lengths of range grade `id`; each is clamped to the range
    /// length. Refused for effects without a range.
    fn set_color_range_fades(&mut self, id: Id, fade_in: Option<Time>, fade_out: Option<Time>) -> bool;

    /// Writes a Match result: the first Color effect gets the wheels (switched on), the Exposure when the result has
    /// one, and the reference. A clip without Color effect gets one. False on clips that take no color.
    fn apply_color_match(
        &mut self,
        result: &ColorMatchResult,
        reference: &ColorMatchReference,
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool;

    /// The Pro grade of the clip (the Color Graph effect).
    fn color_graph(&self) -> Option<ColorGraph>;
    /// Sets (`Some`), replaces or removes (`None`) the Color Graph effect. A new one goes behind the Color effects.
    fn set_color_graph(&mut self, g: Option<ColorGraph>, ids: &mut dyn IdSource);
    /// Applies a copied Pro grade; without one the Pro grade switches off.
    fn apply_copied_graph(&mut self, g: Option<ColorGraph>, ids: &mut dyn IdSource);
    /// Which grade renders.
    fn active_grade(&self) -> ActiveGrade;
    /// Switches between the Simple and the Pro grade.
    fn set_active_grade(&mut self, m: ActiveGrade, ids: &mut dyn IdSource);
    /// The graph the renderer uses: the active one; only its conversion while the effect is switched off.
    fn render_graph(&self) -> Option<ColorGraph>;
}

impl ClipGradeExt for Clip {
    fn color_effect_indices(&self) -> Vec<usize> {
        (0..self.effects.len()).filter(|&i| self.effects[i].is_color()).collect()
    }

    fn color(&self) -> ClipColor {
        color_at(self, None)
    }

    fn color_at_local(&self, t: Time) -> ClipColor {
        color_at(self, Some(t))
    }

    fn set_color(&mut self, c: &ClipColor, t: Option<Time>, ids: &mut dyn IdSource) {
        self.footage_color = ClipFootageColor::from(c);
        let existing = self.color_effect_indices();
        if existing.is_empty() && c.effects() == ClipColor::default_effects().as_slice() {
            return;
        }
        let effect_ids: Vec<Id> = existing.iter().map(|&i| self.effects[i].id).collect();
        // Update or remove the existing ones (by inspector id = position + 1).
        for (n, fx_id) in effect_ids.iter().enumerate() {
            if let Some(e) = c.effect(n as i64 + 1) {
                if let Some(i) = self.effects.iter().position(|x| x.id == *fx_id) {
                    self.effects[i].set_color_effect(e, t, ids);
                }
            } else {
                remove_effect(self, *fx_id);
            }
        }
        // Append new ones behind the last Color effect (or in front of the list).
        let added: Vec<&ColorEffect> = c.effects().iter().filter(|e| e.id > effect_ids.len() as i64).collect();
        if added.is_empty() || !self.accepts_color() {
            return;
        }
        let first = self.color_effect_indices().last().map_or(0, |i| i + 1);
        for (n, e) in added.into_iter().enumerate() {
            let id = ids.next_id();
            self.effects.insert(first + n, ClipEffect::color_grade(id, e, ids));
        }
    }

    fn set_color_edited_from(
        &mut self,
        c: &ClipColor,
        base: &ClipColor,
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool {
        let mut out = self.clone();
        if ClipFootageColor::from(c) != ClipFootageColor::from(base) {
            out.footage_color = ClipFootageColor::from(c);
        }
        let effect_ids: Vec<Id> = out.color_effect_indices().iter().map(|&i| out.effects[i].id).collect();
        for (n, fx_id) in effect_ids.iter().enumerate() {
            let Some(i) = out.effects.iter().position(|x| x.id == *fx_id) else { continue };
            let inspector_id = n as i64 + 1;
            match (c.effect(inspector_id), base.effect(inspector_id)) {
                (Some(e), Some(b)) => {
                    if !out.effects[i].apply_color_edit(b, e, t, ids) {
                        return false;
                    }
                }
                (Some(e), None) => out.effects[i].set_color_effect(e, t, ids),
                (None, Some(_)) => {
                    remove_effect(&mut out, *fx_id);
                }
                (None, None) => {}
            }
        }
        // Without Color effects the clip shows the neutral default as effect 1: an edit creates every shown effect.
        let added: Vec<&ColorEffect> = if effect_ids.is_empty() {
            if c.effects() == ClipColor::default_effects().as_slice() {
                Vec::new()
            } else {
                c.effects().iter().collect()
            }
        } else {
            c.effects().iter().filter(|e| e.id > effect_ids.len() as i64 && base.effect(e.id).is_none()).collect()
        };
        if !added.is_empty() && out.accepts_color() {
            let first = out.color_effect_indices().last().map_or(0, |i| i + 1);
            for (n, e) in added.into_iter().enumerate() {
                let id = ids.next_id();
                out.effects.insert(first + n, ClipEffect::color_grade(id, e, ids));
            }
        }
        *self = out;
        true
    }

    fn color_edit_time(&self, playhead: Time, frame_duration: Time) -> Option<Time> {
        if !(playhead >= self.start && playhead < self.start + self.duration()) {
            return None;
        }
        let last = (self.duration() - frame_duration).max(Time::ZERO);
        Some((playhead - self.start).max(Time::ZERO).min(last))
    }

    fn accepts_color(&self) -> bool {
        self.kind == TrackKind::Video
            && !self.is_nested()
            && (!self.is_generator() || self.generator.as_ref().is_some_and(|g| g.kind == ADJUSTMENT_KIND))
    }

    fn can_accept_pasted_effect(&self, e: &ClipEffect) -> bool {
        if sq_core_model::EffectCatalog::spec_for(&e.kind).is_none() {
            return false;
        }
        if e.is_audio() || self.kind == TrackKind::Audio {
            return e.is_audio() && self.kind == TrackKind::Audio;
        }
        if e.is_color() {
            return self.accepts_color();
        }
        if let Some(owner) = sq_core_model::EffectCatalog::owning_generator(&e.kind) {
            return self.generator.as_ref().is_some_and(|g| g.kind == owner);
        }
        true
    }

    fn color_grade_effects(&self) -> Vec<ClipEffect> {
        self.color_effect_indices().into_iter().map(|i| self.effects[i].clone()).collect()
    }

    fn replace_color_grade(&mut self, fx: &[ClipEffect], ids: &mut dyn IdSource) {
        if !self.accepts_color() {
            return;
        }
        for i in self.color_effect_indices().into_iter().rev() {
            let id = self.effects[i].id;
            remove_effect(self, id);
        }
        // Range grades are cut to this clip (dropped when they miss it); the first Color effect never keeps a range.
        let mut colors: Vec<ClipEffect> = Vec::new();
        for e in fx.iter().filter(|e| e.is_color()) {
            let mut c = copy_with_id(e, ids.next_id());
            if let Some(r) = c.color_range {
                let Some(x) = self.clamped_color_range(r) else { continue };
                if colors.is_empty() {
                    colors.push(neutral_base_grade(ids));
                }
                c.color_range = Some(x);
            }
            let primary = colors.is_empty();
            colors.push(c.adapting_luts(self.media, primary));
        }
        self.effects.splice(0..0, colors);
    }

    fn add_color_grade_on_top(&mut self, fx: &[ClipEffect], ids: &mut dyn IdSource) {
        if !self.accepts_color() {
            return;
        }
        let Some(&last) = self.color_effect_indices().last() else {
            self.replace_color_grade(fx, ids);
            return;
        };
        let mut add: Vec<ClipEffect> = Vec::new();
        for e in fx.iter().filter(|e| e.is_color()) {
            let mut c = copy_with_id(e, ids.next_id());
            if let Some(r) = c.color_range {
                let Some(x) = self.clamped_color_range(r) else { continue };
                c.color_range = Some(x);
            }
            add.push(c.adapting_luts(self.media, false));
        }
        self.effects.splice(last + 1..last + 1, add);
    }

    fn insert_pasted_effect(&mut self, e: &ClipEffect, ids: &mut dyn IdSource) -> bool {
        if !e.is_color() {
            self.effects.push(copy_with_id(e, ids.next_id()));
            return true;
        }
        if !self.accepts_color() {
            return false;
        }
        let mut at = self.color_effect_indices().last().map_or(0, |i| i + 1);
        let mut c = copy_with_id(e, ids.next_id());
        if let Some(r) = c.color_range {
            let Some(x) = self.clamped_color_range(r) else { return false };
            c.color_range = Some(x);
            if at == 0 {
                let base = neutral_base_grade(ids);
                self.effects.insert(0, base);
                at = 1;
            }
        }
        self.effects.insert(at, c.adapting_luts(self.media, at == 0));
        true
    }

    fn render_color(&self, t: Time, has_live_mask_input: &dyn Fn(&ClipEffect) -> bool) -> ClipColor {
        if let Some(g) = self.render_graph() {
            // Pro is active: the Color effects stay dimmed; the graph's In LUT is the conversion.
            let mut c = ClipColor::new(
                self.footage_color.source,
                self.footage_color.use_embedded_lut,
                vec![ColorEffect::new(1, g.input_lut.clone())],
            );
            c.graph = Some(g);
            return c;
        }
        let all = self.color_effect_indices();
        if all.is_empty() {
            return ClipColor::new(self.footage_color.source, self.footage_color.use_embedded_lut, Vec::new());
        }
        let mut fx: Vec<ColorEffect> = Vec::new();
        for (n, &i) in all.iter().enumerate() {
            // A masked Color effect is a grade pass in the effect chain, not part of the clip's grade.
            if n > 0 && has_live_mask_input(&self.effects[i]) {
                continue;
            }
            if self.color_effect_renders(&self.effects[i], n, t) {
                let mut ce = self.effects[i].color_effect(Some(t), n as i64 + 1);
                if n > 0 {
                    let w = self.effects[i].range_strength(t);
                    if w < 1.0 {
                        ce = ce.scaled(w as f32);
                    }
                }
                fx.push(ce);
            } else if n == 0 {
                let off = self.effects[i].color_effect(Some(t), 1);
                let mut stand = ColorEffect::new(1, off.input_lut.clone());
                stand.set_enabled(
                    sq_core_model::ColorSectionKind::BasicCorrection,
                    off.is_enabled(sq_core_model::ColorSectionKind::BasicCorrection),
                );
                fx.push(stand);
            }
        }
        clip_color_of(&self.footage_color, fx)
    }

    fn adopt_legacy_grade(&mut self, old: &ClipColor, ids: &mut dyn IdSource) {
        self.footage_color = ClipFootageColor::from(old);
        if old.effects() == ClipColor::default_effects().as_slice()
            || !self.color_effect_indices().is_empty()
            || !self.accepts_color()
        {
            return;
        }
        let grades: Vec<ClipEffect> = old
            .effects()
            .iter()
            .map(|e| {
                let id = ids.next_id();
                ClipEffect::color_grade(id, e, ids)
            })
            .collect();
        self.effects.splice(0..0, grades);
    }

    fn is_color_animated(&self, n: usize, keys: &[&str]) -> bool {
        let Some(i) = color_effect_index(self, n) else { return false };
        keys.iter().any(|k| self.effects[i].parameters.get(*k).is_some_and(|p| p.is_animated()))
    }

    fn color_key_times(&self, n: usize, keys: &[&str]) -> Vec<Time> {
        let Some(i) = color_effect_index(self, n) else { return Vec::new() };
        let mut times: Vec<Time> = keys
            .iter()
            .flat_map(|k| {
                self.effects[i].parameters.get(*k).map(|p| p.track.keys.iter().map(|k| k.time).collect::<Vec<_>>())
            })
            .flatten()
            .collect();
        times.sort();
        times.dedup();
        times
    }

    fn has_color_key(&self, n: usize, keys: &[&str], t: Time) -> bool {
        self.color_key_times(n, keys).contains(&t)
    }

    fn set_color_animated(
        &mut self,
        on: bool,
        n: usize,
        keys: &[&str],
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool {
        if on == self.is_color_animated(n, keys) || (on && t.is_none()) {
            return false;
        }
        edit_color_effect(self, n, ids, |fx, ids| {
            let before = fx.clone();
            for k in keys {
                let mut p = fx
                    .parameters
                    .get(*k)
                    .cloned()
                    .unwrap_or_else(|| sq_core_model::AnimatedProperty::new(default_value(k)));
                let shown = t
                    .and_then(|t| before.color_shown_value(k, t))
                    .unwrap_or_else(|| t.map_or(p.value, |t| p.value_at_local(t)));
                if let (true, Some(t)) = (on, t) {
                    p.track.insert(Keyframe::new(ids.next_id(), t, shown));
                } else {
                    p.value = shown;
                    p.track = KeyframeTrack::default();
                }
                fx.parameters.insert((*k).to_string(), p);
            }
            true
        })
    }

    fn toggle_color_key(&mut self, n: usize, keys: &[&str], t: Time, ids: &mut dyn IdSource) -> bool {
        let removing = self.has_color_key(n, keys, t);
        edit_color_effect(self, n, ids, |fx, ids| {
            let before = fx.clone();
            for k in keys {
                let mut p = fx
                    .parameters
                    .get(*k)
                    .cloned()
                    .unwrap_or_else(|| sq_core_model::AnimatedProperty::new(default_value(k)));
                let shown = before.color_shown_value(k, t).unwrap_or_else(|| p.value_at_local(t));
                if removing {
                    let Some(key) = p.track.keys.iter().find(|x| x.time == t) else { continue };
                    let id = key.id;
                    p.track.remove(id);
                    if p.track.is_empty() {
                        p.value = shown;
                    }
                } else {
                    p.track.insert(Keyframe::new(ids.next_id(), t, shown));
                }
                fx.parameters.insert((*k).to_string(), p);
            }
            true
        })
    }

    fn base_grade_effects(&self) -> Vec<ClipEffect> {
        self.effects.iter().filter(|e| e.is_color() && e.color_range.is_none()).cloned().collect()
    }

    fn clamped_color_range(&self, r: TimeRange) -> Option<TimeRange> {
        if self.duration() <= Time::ZERO {
            return None;
        }
        let x = r.intersection(&TimeRange::new(Time::ZERO, self.duration()))?;
        if x.duration > Time::ZERO { Some(x) } else { None }
    }

    fn add_range_grade(&mut self, range: TimeRange, ids: &mut dyn IdSource) -> Option<Id> {
        if !self.accepts_color() {
            return None;
        }
        let r = self.clamped_color_range(range)?;
        if self.color_effect_indices().is_empty() {
            let base = neutral_base_grade(ids);
            self.effects.insert(0, base);
        }
        let id = ids.next_id();
        let mut fx =
            ClipEffect::color_grade(id, &ColorEffect::new(self.color_effect_indices().len() as i64 + 1, None), ids);
        fx.color_range = Some(r);
        let at = self.color_effect_indices().last().map_or(0, |i| i + 1);
        self.effects.insert(at, fx);
        Some(id)
    }

    fn set_color_range(&mut self, id: Id, range: Option<TimeRange>) -> bool {
        let colour = self.color_effect_indices();
        let Some(n) = colour.iter().position(|&i| self.effects[i].id == id) else { return false };
        if n == 0 {
            return false;
        }
        match range {
            Some(range) => {
                let Some(r) = self.clamped_color_range(range) else { return false };
                self.effects[colour[n]].color_range = Some(r);
            }
            None => self.effects[colour[n]].color_range = None,
        }
        true
    }

    fn ensure_base_under_range_grades(&mut self, ids: &mut dyn IdSource) -> bool {
        let Some(&first) = self.color_effect_indices().first() else { return false };
        if self.effects[first].color_range.is_none() {
            return false;
        }
        let base = neutral_base_grade(ids);
        self.effects.insert(first, base);
        true
    }

    fn color_effect_renders(&self, e: &ClipEffect, position: usize, t: Time) -> bool {
        if !e.enabled {
            return false;
        }
        match (&e.color_range, position) {
            (Some(r), n) if n > 0 => r.contains(t),
            _ => true,
        }
    }

    fn set_color_range_fades(&mut self, id: Id, fade_in: Option<Time>, fade_out: Option<Time>) -> bool {
        let Some(i) = self.effects.iter().position(|e| e.id == id && e.is_color()) else { return false };
        let Some(r) = self.effects[i].color_range else { return false };
        let clean = |t: Option<Time>| t.filter(|t| *t > Time::ZERO).map(|t| t.min(r.duration));
        self.effects[i].color_fade_in = clean(fade_in);
        self.effects[i].color_fade_out = clean(fade_out);
        true
    }

    fn apply_color_match(
        &mut self,
        result: &ColorMatchResult,
        reference: &ColorMatchReference,
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool {
        if !self.accepts_color() {
            return false;
        }
        if self.color_effect_indices().is_empty() {
            let id = ids.next_id();
            self.effects.insert(0, ClipEffect::color_grade(id, &ClipColor::default_effects()[0], ids));
        }
        let Some(&i) = self.color_effect_indices().first() else { return false };
        let mut e = self.effects[i].color_effect(t, 1);
        e.wheels = result.wheels.clone();
        e.set_enabled(sq_core_model::ColorSectionKind::Wheels, true);
        if let Some(ev) = result.exposure {
            e.basic.exposure = ev;
        }
        self.effects[i].set_color_effect(&e, t, ids);
        let mut d = self.effects[i].color_data();
        d.match_reference = Some(reference.clone());
        self.effects[i].grade = Some(d);
        true
    }

    fn color_graph(&self) -> Option<ColorGraph> {
        let i = self.effects.iter().position(|e| e.kind == COLOR_GRAPH_KIND)?;
        // A stored graph effect without data stands for a fresh graph (its first Step id is drawn on first use).
        Some(
            self.effects[i]
                .color_graph
                .clone()
                .unwrap_or_else(|| ColorGraph::new(Vec::new(), Some(LUTRef::Automatic), None, Id::NIL)),
        )
    }

    fn set_color_graph(&mut self, g: Option<ColorGraph>, ids: &mut dyn IdSource) {
        let index = self.effects.iter().position(|e| e.kind == COLOR_GRAPH_KIND);
        match (index, g) {
            (Some(i), Some(g)) => self.effects[i].color_graph = Some(g),
            (Some(i), None) => {
                self.effects.remove(i);
            }
            (None, Some(g)) => {
                if !self.accepts_color() {
                    return;
                }
                let at = self.color_effect_indices().last().map_or(0, |i| i + 1);
                self.effects.insert(at, color_graph_effect(ids.next_id(), g));
            }
            (None, None) => {}
        }
    }

    fn apply_copied_graph(&mut self, g: Option<ColorGraph>, ids: &mut dyn IdSource) {
        if let Some(g) = g {
            self.set_color_graph(Some(g), ids);
            return;
        }
        let Some(mut cur) = self.color_graph() else { return };
        if !cur.is_active {
            return;
        }
        cur.is_active = false;
        self.set_color_graph(Some(cur), ids);
    }

    fn active_grade(&self) -> ActiveGrade {
        if self.color_graph().is_some_and(|g| g.is_active) { ActiveGrade::Pro } else { ActiveGrade::Simple }
    }

    fn set_active_grade(&mut self, m: ActiveGrade, ids: &mut dyn IdSource) {
        let mut g = self.color_graph().or_else(|| {
            (m == ActiveGrade::Pro).then(|| ColorGraph::new(Vec::new(), Some(LUTRef::Automatic), None, ids.next_id()))
        });
        if let Some(g) = g.as_mut() {
            g.is_active = m == ActiveGrade::Pro;
        }
        if g.is_some() {
            self.set_color_graph(g, ids);
        }
    }

    fn render_graph(&self) -> Option<ColorGraph> {
        let e = self.effects.iter().find(|e| e.kind == COLOR_GRAPH_KIND)?;
        let g = e.color_graph.as_ref().filter(|g| g.is_active)?;
        // The conversion-only graph's Step is never rendered, so it needs no real id.
        Some(if e.enabled { g.clone() } else { g.conversion_only(Id::NIL) })
    }
}

fn color_at(c: &Clip, t: Option<Time>) -> ClipColor {
    let fx = c
        .color_effect_indices()
        .into_iter()
        .enumerate()
        .map(|(n, i)| c.effects[i].color_effect(t, n as i64 + 1))
        .collect();
    clip_color_of(&c.footage_color, fx)
}

/// The list index of Color effect `n` (1-based).
fn color_effect_index(c: &Clip, n: usize) -> Option<usize> {
    let all = c.color_effect_indices();
    if n >= 1 && n <= all.len() { Some(all[n - 1]) } else { None }
}

fn default_value(key: &str) -> f64 {
    ColorGradeFields::scalars().iter().find(|f| f.key == key).map_or(0.0, |f| ColorScalarField::spec(f).default_value)
}

/// Runs `body` on Color effect `n`; the first effect is created on a clip that takes color and has none. The clip
/// changes only when `body` returns true.
fn edit_color_effect(
    c: &mut Clip,
    n: usize,
    ids: &mut dyn IdSource,
    body: impl FnOnce(&mut ClipEffect, &mut dyn IdSource) -> bool,
) -> bool {
    let mut out = c.clone();
    if n == 1 && out.color_effect_indices().is_empty() {
        if !out.accepts_color() {
            return false;
        }
        let id = ids.next_id();
        out.effects.insert(0, ClipEffect::color_grade(id, &ColorEffect::new(1, Some(LUTRef::Automatic)), ids));
    }
    let Some(i) = color_effect_index(&out, n) else { return false };
    if !body(&mut out.effects[i], ids) {
        return false;
    }
    *c = out;
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color_effect::ColorEffectExt;
    use sq_core_model::{
        BasicToneModel, COLOR_BASIC_MODEL_KEY, COLOR_KIND, ColorSectionKind, ColorSpaceID, CurvePoint, GeneratorRef,
        WheelValue,
    };
    use sq_core_time::{SequentialIds, Time};

    const EXPOSURE: &[&str] = &["exposure"];
    const MIDTONES: &[&str] = &["wheelMidtonesHue", "wheelMidtonesAmount", "wheelMidtonesLuma"];

    fn picture(ids: &mut SequentialIds) -> Clip {
        let mut c = Clip::new(
            ids.next_id(),
            "v",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(4, 1)),
            Time::ZERO,
        );
        c.media_duration = Some(Time::new(10, 1));
        c
    }

    /// A grade that touches many fields of two Color effects (LUT refs of every kind, curves, toggles).
    fn rich_grade(media: Id) -> ClipColor {
        let mut c = ClipColor::new(Some(ColorSpaceID::SLog3SGamut3Cine), false, Vec::new());
        c.edit_effects(|fx| {
            let e = &mut fx[0];
            e.basic.temperature = 12.5;
            e.basic.tint = -3.0;
            e.basic.exposure = 1.25;
            e.basic.contrast = 20.0;
            e.basic.highlights = -40.0;
            e.basic.shadows = 15.0;
            e.basic.whites = 5.0;
            e.basic.blacks = -7.0;
            e.basic.saturation = 130.0;
            e.basic.vibrance = 9.0;
            e.input_lut = Some(LUTRef::Embedded { media });
            e.creative.look = Some(LUTRef::File { path: "/luts/look.cube".into() });
            e.creative.intensity = 60.0;
            e.creative.faded_film = 11.0;
            e.creative.vibrance = -4.0;
            e.creative.saturation = 90.0;
            e.creative.shadow_tint = WheelValue { hue: 200.0, amount: 0.3 };
            e.creative.highlight_tint = WheelValue { hue: 35.5, amount: 0.125 };
            e.creative.tint_balance = -20.0;
            e.curves.master =
                vec![CurvePoint { x: 0.0, y: 0.05 }, CurvePoint { x: 0.5, y: 0.6 }, CurvePoint { x: 1.0, y: 1.0 }];
            e.curves.red = vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 1.0, y: 0.9 }];
            e.hue_curves.hue_vs_sat =
                vec![CurvePoint { x: 0.0, y: 0.5 }, CurvePoint { x: 0.3, y: 0.8 }, CurvePoint { x: 1.0, y: 0.5 }];
            e.wheels.shadows = WheelValue { hue: 10.0, amount: 0.2 };
            e.wheels.midtones = WheelValue { hue: 120.0, amount: 0.4 };
            e.wheels.highlights = WheelValue { hue: 240.0, amount: 0.6 };
            e.wheels.shadows_luma = -10.0;
            e.wheels.midtones_luma = 5.0;
            e.wheels.highlights_luma = 8.0;
            e.wheels.saturation = 110.0;
            e.vignette.amount = -1.5;
            e.vignette.midpoint = 40.0;
            e.vignette.roundness = 10.0;
            e.vignette.feather = 70.0;
            e.set_enabled(ColorSectionKind::Vignette, false);
        });
        c.add_effect();
        c.edit_effects(|fx| {
            fx[1].input_lut = Some(LUTRef::File { path: "/luts/second.cube".into() });
            fx[1].input_lut_intensity = 35.0;
            fx[1].basic.exposure = -0.5;
            fx[1].set_enabled(ColorSectionKind::Creative, false);
        });
        c
    }

    fn graded(exposure: f32, ids: &mut SequentialIds) -> Clip {
        let mut c = picture(ids);
        let mut color = ClipColor::default();
        color.edit_effects(|fx| fx[0].basic.exposure = exposure);
        c.set_color(&color, None, ids);
        c
    }

    #[test]
    fn every_field_of_a_colour_effect_survives_the_effect_form() {
        let mut ids = SequentialIds::default();
        let g = rich_grade(ids.next_id());
        for (i, e) in g.effects().iter().enumerate() {
            let id = ids.next_id();
            let fx = ClipEffect::color_grade(id, e, &mut ids);
            assert_eq!(fx.kind, COLOR_KIND);
            assert_eq!(&fx.color_effect(None, i as i64 + 1), e);
            assert_eq!(&fx.color_effect(Some(Time::new(1, 1)), i as i64 + 1), e);
        }
    }

    #[test]
    fn a_clip_without_a_grade_has_no_colour_effect() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        assert_eq!(c.color(), ClipColor::default());
        c.set_color(&ClipColor::default(), None, &mut ids);
        assert!(c.effects.is_empty(), "the neutral grade is not stored as an effect");
        let mut hlg = c.color();
        hlg.source = Some(ColorSpaceID::HlgBT2020);
        c.set_color(&hlg, None, &mut ids);
        assert!(c.effects.is_empty() && c.color().source == Some(ColorSpaceID::HlgBT2020));
    }

    #[test]
    fn setting_the_colour_writes_colour_effects() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        c.effects.push(ClipEffect::new(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND));
        let g = rich_grade(c.media);
        c.set_color(&g, None, &mut ids);
        assert_eq!(c.color(), g);
        let kinds: Vec<&str> = c.effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [COLOR_KIND, COLOR_KIND, "gaussianBlur"], "color effects go in front of the other effects");
        // Removing the second effect through the view removes its ClipEffect, the first keeps its id.
        let first = c.effects[0].id;
        let mut less = c.color();
        less.remove_effect(2);
        c.set_color(&less, None, &mut ids);
        let colour_ids: Vec<Id> = c.effects.iter().filter(|e| e.is_color()).map(|e| e.id).collect();
        assert_eq!(colour_ids, [first]);
        // Adding one appends behind the existing color effect.
        let mut more = c.color();
        more.add_effect();
        c.set_color(&more, None, &mut ids);
        let kinds: Vec<&str> = c.effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [COLOR_KIND, COLOR_KIND, "gaussianBlur"]);
        assert!(c.color().effects().len() == 2 && c.color().effects()[1].input_lut.is_none());
    }

    #[test]
    fn an_edit_at_a_keyed_parameter_sets_a_key_and_leaves_the_others() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        let mut fx = ClipEffect::color_grade(ids.next_id(), &ColorEffect::new(1, Some(LUTRef::Automatic)), &mut ids);
        let mut p = sq_core_model::AnimatedProperty::new(0.0);
        p.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, 0.0));
        p.track.insert(Keyframe::new(ids.next_id(), Time::new(2, 1), 2.0));
        fx.parameters.insert("exposure".into(), p);
        c.effects.push(fx);
        let t = Time::new(1, 1);
        assert_eq!(c.color_at_local(t).effects()[0].basic.exposure, 1.0);
        let mut g = c.color_at_local(t);
        g.edit_effects(|fx| {
            fx[0].basic.exposure = 1.5;
            fx[0].basic.contrast = 30.0;
        });
        c.set_color(&g, Some(t), &mut ids);
        let times: Vec<Time> = c.effects[0].parameters["exposure"].track.keys.iter().map(|k| k.time).collect();
        assert_eq!(times, [Time::ZERO, t, Time::new(2, 1)]);
        assert!(!c.effects[0].parameters["contrast"].is_animated());
        assert_eq!(c.color_at_local(t).effects()[0].basic.contrast, 30.0);
        assert_eq!(c.color_at_local(Time::new(2, 1)).effects()[0].basic.exposure, 2.0);
    }

    #[test]
    fn a_switched_off_first_effect_keeps_the_conversion() {
        for lut in [None, Some(LUTRef::File { path: "/c.cube".into() }), Some(LUTRef::Automatic)] {
            let mut ids = SequentialIds::default();
            let mut c = picture(&mut ids);
            let mut g = ClipColor::new(Some(ColorSpaceID::SLog3SGamut3Cine), true, Vec::new());
            g.edit_effects(|fx| {
                fx[0].input_lut = lut.clone();
                fx[0].basic.exposure = 2.0;
            });
            c.set_color(&g, None, &mut ids);
            c.effects[0].enabled = false;
            let shown = c.render_color(Time::ZERO, &|_| false);
            assert_eq!(shown.effects().len(), 1);
            assert_eq!(shown.effects()[0].input_lut, lut);
            assert!(shown.effects()[0].basic.is_neutral());
        }
    }

    #[test]
    fn an_edit_writes_only_the_edited_parameter_and_refuses_a_keyed_edit_without_time() {
        let mut ids = SequentialIds::default();
        let mut c = graded(0.0, &mut ids);
        assert!(c.set_color_animated(true, 1, EXPOSURE, Some(Time::ZERO), &mut ids));
        let base = c.color_at_local(Time::new(1, 1));
        let mut keyed = base.clone();
        keyed.edit_effects(|fx| fx[0].basic.exposure = 4.0);
        let before = c.clone();
        assert!(!c.set_color_edited_from(&keyed, &base, None, &mut ids), "a keyed edit needs a time");
        assert_eq!(c, before, "refused: nothing changes");
        let mut plain = base.clone();
        plain.edit_effects(|fx| fx[0].basic.contrast = 10.0);
        assert!(c.set_color_edited_from(&plain, &base, None, &mut ids), "an unkeyed value needs no time");
        assert_eq!(c.effects[0].parameters["contrast"].value, 10.0);
        assert_eq!(c.effects[0].parameters["exposure"].track.keys.len(), 1, "no stale key");
    }

    #[test]
    fn an_edit_on_an_ungraded_clip_creates_every_shown_effect() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        let base = c.color();
        let mut edited = base.clone();
        edited.add_effect();
        edited.edit_effects(|fx| fx[1].wheels.saturation = 120.0);
        assert!(c.set_color_edited_from(&edited, &base, Some(Time::ZERO), &mut ids));
        assert!(c.color().effects().len() == 2 && c.color().effects()[1].wheels.saturation == 120.0);
        assert_eq!(c.color().effects()[0], ClipColor::default_effects()[0]);
        let mut neutral = picture(&mut ids);
        let same = neutral.color();
        assert!(neutral.set_color_edited_from(&same, &same, Some(Time::ZERO), &mut ids) && neutral.effects.is_empty());
    }

    #[test]
    fn edit_time_stays_on_the_clips_frames() {
        let mut ids = SequentialIds::default();
        let c = graded(1.0, &mut ids);
        let fd = Time::new(1, 25);
        assert_eq!(c.color_edit_time(Time::new(4, 1), fd), None);
        assert_eq!(c.color_edit_time(Time::new(-1, 1), fd), None);
        assert_eq!(c.color_edit_time(Time::new(1, 1), fd), Some(Time::new(1, 1)));
        assert_eq!(c.color_edit_time(Time::new(4, 1) - Time::new(1, 100), fd), Some(Time::new(4, 1) - fd));
    }

    #[test]
    fn colour_is_refused_on_nested_and_generator_clips() {
        let mut ids = SequentialIds::default();
        let mut nested = picture(&mut ids);
        nested.sequence = Some(ids.next_id());
        let mut solid = picture(&mut ids);
        solid.generator = Some(GeneratorRef { kind: "solid".into(), payload: vec![1, 2, 3], payload_version: 1 });
        let mut adjustment = picture(&mut ids);
        adjustment.generator =
            Some(GeneratorRef { kind: ADJUSTMENT_KIND.into(), payload: Vec::new(), payload_version: 1 });
        assert!(!nested.accepts_color() && !solid.accepts_color());
        assert!(adjustment.accepts_color() && picture(&mut ids).accepts_color());
    }

    #[test]
    fn keyframing_one_slider_and_one_wheel() {
        let mut ids = SequentialIds::default();
        // Animate adds one key at the time with the shown value.
        let mut c = graded(1.5, &mut ids);
        assert!(!c.is_color_animated(1, EXPOSURE) && c.color_key_times(1, EXPOSURE).is_empty());
        let t = Time::new(1, 1);
        assert!(c.set_color_animated(true, 1, EXPOSURE, Some(t), &mut ids));
        assert_eq!(c.color_key_times(1, EXPOSURE), [t]);
        assert_eq!(c.color_at_local(Time::new(3, 1)).effects()[0].basic.exposure, 1.5);
        // Without a playhead it is refused.
        let mut d = graded(1.5, &mut ids);
        let before = d.clone();
        assert!(!d.set_color_animated(true, 1, EXPOSURE, None, &mut ids) && d == before);
        // Toggle key adds then removes; removing the last key leaves the shown value static.
        let mut e = graded(1.5, &mut ids);
        assert!(e.set_color_animated(true, 1, EXPOSURE, Some(Time::ZERO), &mut ids));
        let t2 = Time::new(2, 1);
        assert!(!e.has_color_key(1, EXPOSURE, t2));
        assert!(e.toggle_color_key(1, EXPOSURE, t2, &mut ids) && e.has_color_key(1, EXPOSURE, t2));
        assert_eq!(e.color_key_times(1, EXPOSURE), [Time::ZERO, t2]);
        assert!(e.toggle_color_key(1, EXPOSURE, t2, &mut ids));
        assert_eq!(e.color_key_times(1, EXPOSURE), [Time::ZERO]);
        assert!(e.toggle_color_key(1, EXPOSURE, Time::ZERO, &mut ids));
        assert!(!e.is_color_animated(1, EXPOSURE));
        assert_eq!(e.color().effects()[0].basic.exposure, 1.5);
        // A wheel group keys all its parameters; other parameters stay static.
        let mut w = graded(1.5, &mut ids);
        assert!(w.set_color_animated(true, 1, MIDTONES, Some(t), &mut ids));
        let fx = &w.color_grade_effects()[0];
        for k in MIDTONES {
            let times: Vec<Time> = fx.parameters[*k].track.keys.iter().map(|k| k.time).collect();
            assert_eq!(times, [t]);
        }
        assert!(!fx.parameters["exposure"].is_animated() && !fx.parameters["wheelShadowsHue"].is_animated());
        // A clip without a Color effect gets one on animate; a missing second effect is refused.
        let mut bare = picture(&mut ids);
        assert!(bare.set_color_animated(true, 1, EXPOSURE, Some(Time::ZERO), &mut ids));
        assert_eq!(bare.color_grade_effects().len(), 1);
        assert_eq!(bare.color().effects()[0].input_lut, Some(LUTRef::Automatic));
        assert!(!bare.set_color_animated(true, 2, EXPOSURE, Some(Time::ZERO), &mut ids));
        assert!(!bare.toggle_color_key(2, EXPOSURE, Time::ZERO, &mut ids));
    }

    #[test]
    fn replacing_the_grade_carries_keys_and_the_effect_switch() {
        let mut ids = SequentialIds::default();
        let mut src = graded(1.0, &mut ids);
        assert!(src.set_color_animated(true, 1, EXPOSURE, Some(Time::ZERO), &mut ids));
        src.effects[0].enabled = false;
        let mut dst = picture(&mut ids);
        dst.replace_color_grade(&src.color_grade_effects(), &mut ids);
        let got = dst.color_grade_effects();
        assert_eq!(got.len(), 1);
        assert!(!got[0].enabled && got[0].parameters["exposure"].is_animated());
        assert_ne!(got[0].id, src.effects[0].id, "a copy has a new id");
        // Empty = Reset.
        dst.replace_color_grade(&[], &mut ids);
        assert!(dst.color_grade_effects().is_empty());
    }

    #[test]
    fn replacing_the_grade_drops_the_other_medias_embedded_lut() {
        let mut ids = SequentialIds::default();
        let mut src = picture(&mut ids);
        let g = rich_grade(src.media);
        src.set_color(&g, None, &mut ids);
        let mut dst = picture(&mut ids);
        dst.replace_color_grade(&src.color_grade_effects(), &mut ids);
        assert_eq!(
            dst.color().effects()[0].input_lut,
            Some(LUTRef::Automatic),
            "the first effect falls back to automatic"
        );
        let mut same = picture(&mut ids);
        same.media = src.media;
        same.replace_color_grade(&src.color_grade_effects(), &mut ids);
        assert_eq!(same.color().effects()[0].input_lut, Some(LUTRef::Embedded { media: src.media }));
    }

    #[test]
    fn a_pasted_colour_effect_goes_behind_the_colour_block_and_only_on_colour_clips() {
        let mut ids = SequentialIds::default();
        let mut c = graded(1.0, &mut ids);
        c.effects.push(ClipEffect::new(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND));
        let pasted = ClipEffect::color_grade(ids.next_id(), &ColorEffect::new(2, None), &mut ids);
        assert!(c.insert_pasted_effect(&pasted, &mut ids));
        let kinds: Vec<&str> = c.effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [COLOR_KIND, COLOR_KIND, "gaussianBlur"]);
        let mut solid = picture(&mut ids);
        solid.generator = Some(GeneratorRef { kind: "solid".into(), payload: vec![0, 0, 0], payload_version: 1 });
        assert!(!solid.insert_pasted_effect(&pasted, &mut ids));
        assert!(solid.insert_pasted_effect(&ClipEffect::new(ids.next_id(), "gaussianBlur"), &mut ids));
    }

    #[test]
    fn range_grades_sit_behind_a_base_and_fade_at_their_edges() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        let range = TimeRange::new(Time::new(1, 1), Time::new(2, 1));
        let id = c.add_range_grade(range, &mut ids).expect("added");
        assert_eq!(c.color_effect_indices().len(), 2, "a neutral base grade comes first");
        assert!(c.effects[0].color_range.is_none() && c.effects[1].color_range == Some(range));
        assert!(c.set_color_range_fades(id, Some(Time::new(1, 2)), Some(Time::new(10, 1))));
        assert_eq!(c.effects[1].color_fade_out, Some(Time::new(2, 1)), "clamped to the range length");
        let fx = &c.effects[1];
        assert_eq!(fx.range_strength(Time::new(1, 2)), 0.0, "outside the range");
        assert_eq!(fx.range_strength(Time::new(5, 4)), 0.5, "halfway through the fade-in");
        assert_eq!(fx.range_strength(Time::new(2, 1)), 0.5, "halfway through the fade-out of 2 s");
        assert!(!c.color_effect_renders(&c.effects[1], 1, Time::new(1, 2)));
        assert!(c.color_effect_renders(&c.effects[1], 1, Time::new(3, 2)));
        assert!(!c.set_color_range(c.effects[0].id, Some(range)), "the first effect never keeps a range");
        assert!(c.set_color_range(id, None) && c.effects[1].color_range.is_none());
    }

    #[test]
    fn the_pro_grade_accessors_follow_the_active_grade() {
        let mut ids = SequentialIds::default();
        let mut c = graded(1.0, &mut ids);
        assert_eq!(c.active_grade(), ActiveGrade::Simple);
        assert!(c.color_graph().is_none());
        c.set_active_grade(ActiveGrade::Pro, &mut ids);
        assert_eq!(c.active_grade(), ActiveGrade::Pro);
        let kinds: Vec<&str> = c.effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [COLOR_KIND, COLOR_GRAPH_KIND], "the graph goes behind the Color effects");
        assert!(c.render_graph().is_some());
        c.effects[1].enabled = false;
        assert!(c.render_graph().is_some_and(|g| g.steps().len() == 1), "switched off: conversion only");
        c.apply_copied_graph(None, &mut ids);
        assert_eq!(c.active_grade(), ActiveGrade::Simple);
        assert!(c.render_graph().is_none());
        c.set_color_graph(None, &mut ids);
        assert!(c.color_graph().is_none());
    }

    #[test]
    fn the_legacy_grade_is_adopted_unless_neutral_or_the_clip_has_one() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        let mut old = ClipColor::new(Some(ColorSpaceID::HlgBT2020), false, Vec::new());
        old.edit_effects(|fx| fx[0].basic.contrast = 25.0);
        c.adopt_legacy_grade(&old, &mut ids);
        assert_eq!(c.footage_color.source, Some(ColorSpaceID::HlgBT2020));
        assert_eq!(c.color().effects()[0].basic.contrast, 25.0);
        let mut neutral = picture(&mut ids);
        neutral.adopt_legacy_grade(&ClipColor::new(Some(ColorSpaceID::Rec709), true, Vec::new()), &mut ids);
        assert!(neutral.effects.is_empty(), "the neutral default grade adds no effect");
        let mut has = graded(1.0, &mut ids);
        has.adopt_legacy_grade(&old, &mut ids);
        assert_eq!(has.color_grade_effects().len(), 1, "an existing grade wins");
    }

    #[test]
    fn a_new_colour_effect_carries_the_lumetri_maths_flag() {
        let mut ids = SequentialIds::default();
        let fx = ClipEffect::color_grade(ids.next_id(), &ColorEffect::new(1, Some(LUTRef::Automatic)), &mut ids);
        assert_eq!(fx.parameters[COLOR_BASIC_MODEL_KEY].value, 1.0);
        assert_eq!(fx.color_effect(None, 1).basic.model, BasicToneModel::Lumetri);
        // An edit on a legacy effect stays legacy; a reset can upgrade.
        let mut e = ColorEffect::new(1, Some(LUTRef::Automatic));
        e.basic.model = BasicToneModel::Legacy;
        e.basic.shadows = 20.0;
        let mut fx = ClipEffect::color_grade(ids.next_id(), &e, &mut ids);
        let base = fx.color_effect(None, 1);
        let mut edited = base.clone();
        edited.basic.shadows = 35.0;
        assert!(fx.apply_color_edit(&base, &edited, None, &mut ids));
        assert_eq!(fx.color_effect(None, 1).basic, edited.basic);
        assert_eq!(fx.color_effect(None, 1).basic.model, BasicToneModel::Legacy);
        let mut reset = edited.clone();
        reset.basic = sq_core_model::BasicCorrection::default();
        assert!(fx.apply_color_edit(&edited, &reset, None, &mut ids));
        assert_eq!(fx.color_effect(None, 1).basic.model, BasicToneModel::Lumetri);
        assert!(
            !ColorGradeFields::params().iter().any(|p| p.key == COLOR_BASIC_MODEL_KEY),
            "hidden from Effect Controls"
        );
    }

    #[test]
    fn the_effect_spec_lists_unique_keys_with_the_section_toggles() {
        let spec = ColorGradeFields::spec();
        let mut keys: Vec<&str> = spec.params.iter().map(|p| p.key.as_str()).collect();
        let n = keys.len();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), n, "keys are unique");
        let exposure = spec.params.iter().find(|p| p.key == "exposure").expect("exposure");
        assert_eq!(exposure.range, -5.0..=5.0);
        let creative = spec.params.iter().find(|p| p.key == "creativeOn").expect("creative switch");
        assert_eq!(creative.title, "Creative");
        assert_eq!(crate::ColorEffectGroups::group_key("exposure").as_deref(), Some("basicCorrectionOn"));
        assert_eq!(crate::ColorEffectGroups::group_key("vignetteFeather").as_deref(), Some("vignetteOn"));
        assert!(ColorEffectExt::is_neutral(&ColorEffect::new(1, None), ColorSectionKind::Vignette));
    }
}
