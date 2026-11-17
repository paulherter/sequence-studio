// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGraph.swift, ColorGraph+Simple.swift, ColorGraph+LayerList.swift
//! Pro grade logic (Color Graph effect, v78): Step maths and edits, the layer list and "Send to Pro". The saved types
//! live in `sq-core-model`; the wiring (links, compile, refusals) is in [`crate::color_graph_wiring`].
//!
//! Swift's `steps` has a `didSet` (an empty list gets one Step, the first Step is serial) that runs after every single
//! mutation; every mutation here goes through [`edit`], which applies the same rules each time.

use crate::color_effect::{CreativeLookExt, HSLSecondaryExt};
use crate::color_graph_wiring::{detach, sanitize_wiring, set_image_links};
use sq_core_model::{
    ClipColor, ColorEffect, ColorGraph, ColorQualifier, ColorSectionKind, ColorStep, ColorTriple, GraphLink, GraphPort,
    HSLSecondary, LUTRef, LayerMixMode, StepKind, StepPosition, StepPrimaries, WheelValue,
};
use sq_core_time::{Id, IdSource};

/// Which grade renders: the Simple one (fixed Color effects) or the Pro one (the graph).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ActiveGrade {
    /// The clip's Color effects.
    Simple,
    /// The Color Graph effect.
    Pro,
}

/// Applies one mutation to the Steps with the `didSet` rules of Swift's `ColorGraph.steps`.
///
/// An emptied list gets a Step with `Id::NIL`: no edit in this crate empties the list (removing the last Step resets
/// it instead).
pub(crate) fn edit(g: &mut ColorGraph, f: impl FnOnce(&mut Vec<ColorStep>)) {
    g.edit_steps(Id::NIL, f);
}

/// Ranges and maths of the Step primaries.
pub trait StepPrimariesExt {
    /// Lift range.
    const LIFT_RANGE: (f32, f32);
    /// Gamma range.
    const GAMMA_RANGE: (f32, f32);
    /// Gain range.
    const GAIN_RANGE: (f32, f32);
    /// Offset range.
    const OFFSET_RANGE: (f32, f32);
    /// Contrast range.
    const CONTRAST_RANGE: (f32, f32);
    /// Pivot range.
    const PIVOT_RANGE: (f32, f32);
    /// Saturation range.
    const SATURATION_RANGE: (f32, f32);
    /// The primaries applied to one display-referred color.
    fn apply(&self, c: [f32; 3]) -> [f32; 3];
    /// Every value in its range.
    fn clamped(&self) -> StepPrimaries;
}

impl StepPrimariesExt for StepPrimaries {
    const LIFT_RANGE: (f32, f32) = (-1.0, 1.0);
    const GAMMA_RANGE: (f32, f32) = (0.1, 4.0);
    const GAIN_RANGE: (f32, f32) = (0.0, 4.0);
    const OFFSET_RANGE: (f32, f32) = (-1.0, 1.0);
    const CONTRAST_RANGE: (f32, f32) = (0.0, 2.0);
    const PIVOT_RANGE: (f32, f32) = (0.0, 1.0);
    const SATURATION_RANGE: (f32, f32) = (0.0, 4.0);

    fn apply(&self, c: [f32; 3]) -> [f32; 3] {
        let ch = |v: f32, l: f32, ga: f32, gn: f32, o: f32| -> f32 {
            let mut t = v + l * (1.0 - v);
            t = t * gn + o;
            if t > 0.0 && ga != 1.0 {
                t = t.powf(ga);
            }
            (t - self.pivot) * self.contrast + self.pivot
        };
        let r = ch(c[0], self.lift.r, self.gamma.r, self.gain.r, self.offset.r);
        let g = ch(c[1], self.lift.g, self.gamma.g, self.gain.g, self.offset.g);
        let b = ch(c[2], self.lift.b, self.gamma.b, self.gain.b, self.offset.b);
        if self.saturation == 1.0 {
            return [r, g, b];
        }
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        [y + self.saturation * (r - y), y + self.saturation * (g - y), y + self.saturation * (b - y)]
    }

    fn clamped(&self) -> StepPrimaries {
        fn c(v: f32, r: (f32, f32)) -> f32 {
            v.max(r.0).min(r.1)
        }
        fn t(v: ColorTriple, r: (f32, f32)) -> ColorTriple {
            ColorTriple { r: c(v.r, r), g: c(v.g, r), b: c(v.b, r) }
        }
        let mut p = self.clone();
        p.lift = t(self.lift, Self::LIFT_RANGE);
        p.gamma = t(self.gamma, Self::GAMMA_RANGE);
        p.gain = t(self.gain, Self::GAIN_RANGE);
        p.offset = t(self.offset, Self::OFFSET_RANGE);
        p.contrast = c(self.contrast, Self::CONTRAST_RANGE);
        p.pivot = c(self.pivot, Self::PIVOT_RANGE);
        p.saturation = c(self.saturation, Self::SATURATION_RANGE);
        p
    }
}

/// The qualifier as a Color Range.
pub trait ColorQualifierExt {
    /// The qualifier's range as a clamped Color Range with no correction.
    fn as_color_range(&self) -> HSLSecondary;
}

impl ColorQualifierExt for ColorQualifier {
    fn as_color_range(&self) -> HSLSecondary {
        HSLSecondary {
            hue_center: self.hue_center,
            hue_width: self.hue_width,
            sat_min: self.sat_min,
            sat_max: self.sat_max,
            lum_min: self.lum_min,
            lum_max: self.lum_max,
            softness: self.softness,
            invert: self.invert,
            ..HSLSecondary::default()
        }
        .clamped()
    }
}

/// One Step's checks, reset and the "Send to Pro" conversion.
pub trait ColorStepExt: Sized {
    /// The Step does nothing to the picture.
    fn is_neutral(&self) -> bool;
    /// Back to a neutral Step; the switch, kind, positions and key mix stay.
    fn reset(&mut self);
    /// The Step uses v80 fields (Layer mix, key output or key mix).
    fn uses_v80_fields(&self) -> bool;
    /// The Step uses v79 fields (kind, mix or canvas positions).
    fn uses_v79_fields(&self) -> bool;
    /// The Simple grade's values as a Step. The Simple sliders are not primaries, so the result is the closest
    /// Lift / Gamma / Gain / Offset equivalent, not a pixel-exact match; curves, hue curves and the look LUT carry
    /// over unchanged.
    fn from_simple(e: &ColorEffect, id: Id, label: &str, is_first: bool) -> Self;
}

/// The puck of a wheel as an RGB offset that sums to zero (hue wheel at amount 1 = full color).
fn wheel_offset(w: &WheelValue) -> [f32; 3] {
    if w.amount <= 0.0 || w.amount.is_nan() {
        return [0.0; 3];
    }
    let mut h = w.hue / 360.0;
    h -= h.floor();
    let ch = |o: f32| -> f32 {
        let mut x = h + o;
        x -= x.floor();
        ((x * 6.0 - 3.0).abs() - 1.0).clamp(0.0, 1.0)
    };
    let c = [ch(0.0), ch(2.0 / 3.0), ch(1.0 / 3.0)];
    let mean = (c[0] + c[1] + c[2]) / 3.0;
    let a = w.amount.min(1.0);
    c.map(|x| a * (x - mean))
}

fn mul(t: &mut ColorTriple, r: f32, g: f32, b: f32) {
    t.r *= r;
    t.g *= g;
    t.b *= b;
}

fn add(t: &mut ColorTriple, v: [f32; 3]) {
    t.r += v[0];
    t.g += v[1];
    t.b += v[2];
}

impl ColorStepExt for ColorStep {
    fn is_neutral(&self) -> bool {
        self.primaries.is_neutral()
            && self.curves.is_neutral()
            && self.hue_curves.is_neutral()
            && (self.lut.is_none() || self.lut_intensity <= 0.0)
    }

    fn reset(&mut self) {
        let mut fresh = ColorStep::new(self.id, &self.label);
        fresh.enabled = self.enabled;
        fresh.kind = self.kind;
        fresh.position = self.position;
        fresh.mixer_position = self.mixer_position;
        fresh.key_mix = self.key_mix;
        *self = fresh;
    }

    fn uses_v80_fields(&self) -> bool {
        self.layer_mix != LayerMixMode::Normal
            || self.key_outside
            || self.key_mix != sq_core_model::KeyMixMode::Multiply
    }

    fn uses_v79_fields(&self) -> bool {
        self.kind != StepKind::Serial || self.mix != 100.0 || self.position.is_some() || self.mixer_position.is_some()
    }

    fn from_simple(e: &ColorEffect, id: Id, label: &str, is_first: bool) -> ColorStep {
        let mut step = ColorStep::new(id, label);
        let mut p = StepPrimaries::default();
        let mut saturation: f32 = 1.0;

        if e.is_enabled(ColorSectionKind::BasicCorrection) {
            let b = &e.basic;
            let k = b.exposure.exp2();
            mul(&mut p.gain, k, k, k);
            let t = b.temperature / 100.0 * 0.2;
            let ti = b.tint / 100.0 * 0.2;
            mul(&mut p.gain, 1.0 + t, 1.0 - ti, 1.0 - t);
            let hi = 1.0 + b.highlights / 100.0 * 0.15 + b.whites / 100.0 * 0.2;
            mul(&mut p.gain, hi, hi, hi);
            let s = b.shadows / 100.0 * 0.15;
            add(&mut p.lift, [s, s, s]);
            p.contrast = 1.0 + b.contrast / 100.0;
            saturation *= b.saturation / 100.0;
            if !is_first
                && let Some(l) = &e.input_lut
                && *l != LUTRef::Automatic
                && e.input_lut_intensity > 0.0
            {
                step.lut = Some(l.clone());
                step.lut_intensity = e.input_lut_intensity;
            }
        }
        if e.is_enabled(ColorSectionKind::Creative) {
            saturation *= e.creative.saturation / 100.0;
            if e.creative.has_look() {
                step.lut = e.creative.look.clone();
                step.lut_intensity = e.creative.intensity;
            }
        }
        if e.is_enabled(ColorSectionKind::Curves) {
            step.curves = e.curves.clone();
            step.hue_curves = e.hue_curves.clone();
        }
        if e.is_enabled(ColorSectionKind::Wheels) {
            let w = &e.wheels;
            let luma = w.shadows_luma / 100.0 * 0.2;
            add(&mut p.lift, wheel_offset(&w.shadows).map(|x| x * 0.25 + luma));
            let m = wheel_offset(&w.midtones);
            mul(&mut p.gamma, (-m[0]).exp2(), (-m[1]).exp2(), (-m[2]).exp2());
            let mg = (-w.midtones_luma / 100.0).exp2();
            mul(&mut p.gamma, mg, mg, mg);
            let h = wheel_offset(&w.highlights).map(|x| x * 0.5);
            let hl = 1.0 + w.highlights_luma / 100.0 * 0.5;
            mul(&mut p.gain, hl + h[0], hl + h[1], hl + h[2]);
            saturation *= w.saturation / 100.0;
        }
        p.saturation = saturation;
        step.primaries = p.clamped();
        step
    }
}

/// How a Step in the layer list combines with the picture below it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StepBlend {
    /// A serial Step: one more column.
    Series,
    /// A parallel Step in the column above.
    Parallel,
    /// A Layer Step with this mix mode.
    Layer(LayerMixMode),
}

impl StepBlend {
    /// Every blend in menu order: series, parallel, then the layer modes.
    pub fn all() -> Vec<StepBlend> {
        let mut v = vec![StepBlend::Series, StepBlend::Parallel];
        v.extend(
            [
                LayerMixMode::Normal,
                LayerMixMode::Add,
                LayerMixMode::Subtract,
                LayerMixMode::Multiply,
                LayerMixMode::Screen,
                LayerMixMode::Lighten,
                LayerMixMode::Darken,
            ]
            .map(StepBlend::Layer),
        );
        v
    }
}

/// Step edits, columns and the layer list of a [`ColorGraph`].
pub trait ColorGraphExt: Sized {
    /// Every enabled Step is neutral and there is no Out LUT: the graph changes nothing.
    fn is_neutral(&self) -> bool;
    /// The Step with this id.
    fn step(&self, id: Id) -> Option<&ColorStep>;
    /// Adds a Step behind `after` (or at the end) and returns its id. `kind` is ignored with custom wiring: a new Step
    /// is wired in series.
    fn add_step(&mut self, after: Option<Id>, kind: StepKind, ids: &mut dyn IdSource) -> Id;
    /// Removes a Step; the last Step is reset instead.
    fn remove_step(&mut self, id: Id);
    /// The Steps grouped into columns: every serial Step starts one, parallel and layer Steps join the column.
    fn columns(&self) -> Vec<Vec<ColorStep>>;
    /// Number of serial Steps (= columns).
    fn serial_count(&self) -> usize;
    /// Sets a Step's kind; the wiring is the kinds again.
    fn set_kind(&mut self, id: Id, kind: StepKind);
    /// Renames a Step (a blank name is ignored).
    fn rename(&mut self, id: Id, name: &str);
    /// Moves a Step to a position in the Step order.
    fn move_step(&mut self, id: Id, index: i64);
    /// Moves a Step into the gap between columns (0 = first); it becomes a serial Step.
    fn move_to_gap(&mut self, id: Id, gap: i64);
    /// Sets a Step's canvas position.
    fn set_position(&mut self, id: Id, p: Option<StepPosition>);
    /// Sets the position of the mixer box behind the stack headed by `head`.
    fn set_mixer_position(&mut self, head: Id, p: Option<StepPosition>);
    /// The Step ids of the stack headed by `head` (empty when `head` is not a column's first Step).
    fn stack(&self, head: Id) -> Vec<Id>;
    /// Dissolves a stack's mixer: the followers become serial Steps again. False when `head` has no stack.
    fn dissolve_mixer(&mut self, head: Id) -> bool;
    /// Makes `id` follow `source` (a lone Step, or the head of a stack = its mixer; `None` = first). False when refused.
    fn follow(&mut self, id: Id, after: Option<Id>) -> bool;
    /// Joins `id` to the stack headed by `head` (`Layer` makes it a Layer Step, anything else a parallel one).
    fn join(&mut self, id: Id, stack_of: Id, kind: StepKind) -> bool;
    /// Forgets all canvas positions.
    fn tidy_up(&mut self);
    /// Switches a Step on or off.
    fn set_step_enabled(&mut self, id: Id, on: bool);
    /// Edits one Step; its id cannot change.
    fn update(&mut self, id: Id, f: impl FnOnce(&mut ColorStep));
    /// The graph without Steps: only the conversion (used while the effect is switched off).
    fn conversion_only(&self, first_id: Id) -> ColorGraph;
    /// The graph uses v80 fields (custom wiring, key wires, Layer mix or key settings).
    fn uses_v80_fields(&self) -> bool;
    /// Runs the wiring cleanup a decode needs (Swift runs it in `init(from:)`).
    fn sanitize_wiring(&mut self);
    /// "Send to Pro": the Simple grade as a graph (active). A neutral Simple grade gets one neutral Step.
    fn from_simple(color: &ClipColor, ids: &mut dyn IdSource) -> ColorGraph;

    /// The Steps for the layer list: topmost row = last Step.
    fn list_steps(&self) -> Vec<ColorStep>;
    /// The layer list can be edited (no custom wiring).
    fn allows_list_edit(&self) -> bool;
    /// How a Step combines with the picture below it.
    fn blend(&self, id: Id) -> Option<StepBlend>;
    /// Sets a Step's blend. Refused (false) with custom wiring, for an unknown Step and for the first Step.
    fn set_blend(&mut self, id: Id, blend: StepBlend) -> bool;
    /// Moves a Step to a list row (row 0 = top = the last Step).
    fn move_step_to_list_row(&mut self, id: Id, row: i64);
}

fn index_of(g: &ColorGraph, id: Id) -> Option<usize> {
    g.steps().iter().position(|s| s.id == id)
}

/// Moves the Step out of its place; a serial head that leaves hands its column to the first follower.
fn take_step(g: &mut ColorGraph, i: usize) -> ColorStep {
    let s = g.steps()[i].clone();
    edit(g, |steps| {
        steps.remove(i);
    });
    if s.kind == StepKind::Serial && i < g.steps().len() && g.steps()[i].kind != StepKind::Serial {
        edit(g, |steps| steps[i].kind = StepKind::Serial);
    }
    s
}

impl ColorGraphExt for ColorGraph {
    fn is_neutral(&self) -> bool {
        self.steps().iter().all(|s| !s.enabled || ColorStepExt::is_neutral(s))
            && (self.output_lut.is_none() || self.output_lut_intensity <= 0.0)
    }

    fn step(&self, id: Id) -> Option<&ColorStep> {
        self.steps().iter().find(|s| s.id == id)
    }

    fn add_step(&mut self, after: Option<Id>, kind: StepKind, ids: &mut dyn IdSource) -> Id {
        let n = self
            .steps()
            .iter()
            .filter_map(|s| s.label.strip_prefix("Step ").and_then(|t| t.parse::<i64>().ok()))
            .max()
            .unwrap_or(0)
            + 1;
        let mut s = ColorStep::new(ids.next_id(), &format!("Step {n}"));
        s.kind = if self.links.is_none() { kind } else { StepKind::Serial };
        let new_id = s.id;
        if let Some(mut l) = self.links.clone() {
            // Behind the box that ends `after`'s column (the mixer of a stack's last Step), on every wire that left it.
            let cols = self.columns();
            let col = cols.iter().find(|c| after.is_some_and(|a| c.iter().any(|x| x.id == a)));
            let anchor = match after {
                Some(i) => match col {
                    Some(col) if col.len() > 1 && col.last().map(|x| x.id) == Some(i) => GraphPort::Mixer(col[0].id),
                    _ => GraphPort::Step(i),
                },
                None => l.iter().find(|x| x.to == GraphPort::Sink).map_or(GraphPort::Source, |x| x.from),
            };
            let at = col
                .and_then(|c| self.steps().iter().position(|x| Some(x.id) == c.last().map(|y| y.id)))
                .map_or(self.steps().len(), |i| i + 1);
            edit(self, |steps| steps.insert(at, s));
            let outs: Vec<GraphPort> = l.iter().filter(|x| x.from == anchor).map(|x| x.to).collect();
            l.retain(|x| x.from != anchor);
            l.push(GraphLink { from: anchor, to: GraphPort::Step(new_id) });
            for o in outs {
                l.push(GraphLink { from: GraphPort::Step(new_id), to: o });
            }
            set_image_links(self, l);
            return new_id;
        }
        match after.and_then(|id| index_of(self, id)) {
            Some(i) => edit(self, |steps| steps.insert(i + 1, s)),
            None => edit(self, |steps| steps.push(s)),
        }
        new_id
    }

    fn remove_step(&mut self, id: Id) {
        let Some(i) = index_of(self, id) else { return };
        if self.steps().len() == 1 {
            edit(self, |steps| steps[0].reset());
            return;
        }
        // Custom wiring closes up around the Step (its input goes to what it fed).
        let healed = self.links.clone().map(|l| detach(self, id, &l));
        let was_serial = self.steps()[i].kind == StepKind::Serial;
        edit(self, |steps| {
            steps.remove(i);
        });
        // A removed head hands its column to the first follower instead of joining the column before.
        if was_serial && i < self.steps().len() && self.steps()[i].kind != StepKind::Serial {
            edit(self, |steps| steps[i].kind = StepKind::Serial);
        }
        if let Some(h) = healed {
            set_image_links(self, h);
        }
        sanitize_wiring(self);
    }

    fn columns(&self) -> Vec<Vec<ColorStep>> {
        let mut out: Vec<Vec<ColorStep>> = Vec::new();
        for s in self.steps() {
            match out.last_mut() {
                Some(last) if s.kind != StepKind::Serial => last.push(s.clone()),
                _ => out.push(vec![s.clone()]),
            }
        }
        out
    }

    fn serial_count(&self) -> usize {
        self.steps().iter().filter(|s| s.kind == StepKind::Serial).count()
    }

    fn set_kind(&mut self, id: Id, kind: StepKind) {
        self.links = None; // the kinds are the wiring again
        self.update(id, |s| s.kind = kind);
        sanitize_wiring(self);
    }

    fn rename(&mut self, id: Id, name: &str) {
        // Foundation's whitespace set; the same limits as `sq_core_time::text`'s trim helper once that exists.
        let n = name.trim();
        if n.is_empty() {
            return;
        }
        self.update(id, |s| s.label = n.to_string());
    }

    fn move_step(&mut self, id: Id, index: i64) {
        if self.steps().len() <= 1 {
            return;
        }
        let Some(i) = index_of(self, id) else { return };
        self.links = None;
        let s = take_step(self, i);
        let at = usize::try_from(index.max(0)).unwrap_or(0).min(self.steps().len());
        edit(self, |steps| steps.insert(at, s));
        sanitize_wiring(self);
    }

    fn move_to_gap(&mut self, id: Id, gap: i64) {
        if self.steps().len() <= 1 {
            return;
        }
        let Some(i) = index_of(self, id) else { return };
        self.links = None;
        let mut s = take_step(self, i);
        s.kind = StepKind::Serial;
        let cols = self.columns();
        let g = usize::try_from(gap.max(0)).unwrap_or(0).min(cols.len());
        let at: usize = cols.iter().take(g).map(Vec::len).sum();
        edit(self, |steps| steps.insert(at, s));
        sanitize_wiring(self);
    }

    fn set_position(&mut self, id: Id, p: Option<StepPosition>) {
        self.update(id, |s| s.position = p);
    }

    fn set_mixer_position(&mut self, head: Id, p: Option<StepPosition>) {
        self.update(head, |s| s.mixer_position = p);
    }

    fn stack(&self, head: Id) -> Vec<Id> {
        self.columns()
            .into_iter()
            .find(|c| c.first().map(|s| s.id) == Some(head))
            .map(|c| c.iter().map(|s| s.id).collect())
            .unwrap_or_default()
    }

    fn dissolve_mixer(&mut self, head: Id) -> bool {
        let ids = self.stack(head);
        if ids.len() <= 1 {
            return false;
        }
        self.links = None;
        for id in ids.into_iter().skip(1) {
            self.update(id, |s| s.kind = StepKind::Serial);
        }
        self.update(head, |s| s.mixer_position = None);
        sanitize_wiring(self);
        true
    }

    fn follow(&mut self, id: Id, after: Option<Id>) -> bool {
        if self.steps().len() <= 1 || self.step(id).is_none() {
            return false;
        }
        self.links = None;
        let done = follow_inner(self, id, after);
        sanitize_wiring(self);
        done
    }

    fn join(&mut self, id: Id, stack_of: Id, kind: StepKind) -> bool {
        let members = self.stack(stack_of);
        if members.len() <= 1 || members.contains(&id) {
            return false;
        }
        let Some(i) = index_of(self, id) else { return false };
        self.links = None;
        let mut s = take_step(self, i);
        s.kind = if kind == StepKind::Layer { StepKind::Layer } else { StepKind::Parallel };
        let after = members[members.len() - 1];
        let done = match index_of(self, after) {
            Some(at) => {
                edit(self, |steps| steps.insert(at + 1, s));
                true
            }
            None => {
                edit(self, |steps| steps.push(s));
                false
            }
        };
        sanitize_wiring(self);
        done
    }

    fn tidy_up(&mut self) {
        edit(self, |steps| {
            for s in steps.iter_mut() {
                s.position = None;
                s.mixer_position = None;
            }
        });
    }

    fn set_step_enabled(&mut self, id: Id, on: bool) {
        self.update(id, |s| s.enabled = on);
    }

    fn update(&mut self, id: Id, f: impl FnOnce(&mut ColorStep)) {
        let Some(i) = index_of(self, id) else { return };
        edit(self, |steps| {
            let keep = steps[i].id;
            f(&mut steps[i]);
            steps[i].id = keep;
        });
    }

    fn conversion_only(&self, first_id: Id) -> ColorGraph {
        let mut g = ColorGraph::new(Vec::new(), self.input_lut.clone(), None, first_id);
        g.is_active = self.is_active;
        g
    }

    fn uses_v80_fields(&self) -> bool {
        self.links.is_some() || !self.key_links.is_empty() || self.steps().iter().any(ColorStepExt::uses_v80_fields)
    }

    fn sanitize_wiring(&mut self) {
        sanitize_wiring(self);
    }

    fn from_simple(color: &ClipColor, ids: &mut dyn IdSource) -> ColorGraph {
        let mut steps: Vec<ColorStep> = Vec::new();
        for (i, e) in color.effects().iter().enumerate() {
            let s = ColorStep::from_simple(e, ids.next_id(), &format!("Step {}", steps.len() + 1), i == 0);
            if !ColorStepExt::is_neutral(&s) {
                steps.push(s);
            }
        }
        let first = color.effects().first();
        let input = if first.is_none_or(|f| f.is_enabled(ColorSectionKind::BasicCorrection)) {
            first.and_then(|f| f.input_lut.clone())
        } else {
            None
        };
        let first_id = if steps.is_empty() { ids.next_id() } else { Id::NIL };
        let mut g = ColorGraph::new(steps, input, None, first_id);
        g.is_active = true;
        g
    }

    fn list_steps(&self) -> Vec<ColorStep> {
        self.steps().iter().rev().cloned().collect()
    }

    fn allows_list_edit(&self) -> bool {
        self.links.is_none()
    }

    fn blend(&self, id: Id) -> Option<StepBlend> {
        let s = self.step(id)?;
        Some(match s.kind {
            StepKind::Serial => StepBlend::Series,
            StepKind::Parallel => StepBlend::Parallel,
            StepKind::Layer => StepBlend::Layer(s.layer_mix),
        })
    }

    fn set_blend(&mut self, id: Id, blend: StepBlend) -> bool {
        let Some(i) = index_of(self, id) else { return false };
        if !self.allows_list_edit() || i == 0 {
            return false;
        }
        let (kind, mode) = match blend {
            StepBlend::Series => (StepKind::Serial, LayerMixMode::Normal),
            StepBlend::Parallel => (StepKind::Parallel, LayerMixMode::Normal),
            StepBlend::Layer(m) => (StepKind::Layer, m),
        };
        self.set_kind(id, kind);
        self.update(id, |s| s.layer_mix = mode);
        true
    }

    fn move_step_to_list_row(&mut self, id: Id, row: i64) {
        let last = i64::try_from(self.steps().len()).unwrap_or(i64::MAX) - 1;
        self.move_step(id, last - row.max(0).min(last));
    }
}

/// The body of `follow` after `links = nil` (Swift runs `sanitizeWiring` in a `defer`).
fn follow_inner(g: &mut ColorGraph, id: Id, source: Option<Id>) -> bool {
    let mut gap: i64 = 0;
    if let Some(source) = source {
        let cols = g.columns();
        let Some(col) = cols.iter().position(|c| c.iter().any(|s| s.id == source)) else { return false };
        if source == id {
            return false;
        }
        let members = &cols[col];
        // Only a column's end (its lone Step, or its mixer, named by the head) can feed a Step.
        if !(members.len() == 1 || members[0].id == source) {
            return false;
        }
        if members.iter().any(|s| s.id == id) {
            return false;
        }
        let rest: Vec<Vec<&ColorStep>> = cols
            .iter()
            .map(|c| c.iter().filter(|s| s.id != id).collect::<Vec<_>>())
            .filter(|c| !c.is_empty())
            .collect();
        let Some(at) = rest.iter().position(|c| c.iter().any(|s| s.id == source)) else { return false };
        gap = i64::try_from(at).unwrap_or(0) + 1;
    }
    g.move_to_gap(id, gap);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color_effect::ClipColorExt;
    use sq_core_model::CurvePoint;
    use sq_core_time::SequentialIds;

    fn new_graph(ids: &mut SequentialIds) -> ColorGraph {
        ColorGraph::new(Vec::new(), Some(LUTRef::Automatic), None, ids.next_id())
    }

    /// A graph of Steps S1, S2, ... with these kinds.
    fn graph(kinds: &[StepKind], ids: &mut SequentialIds) -> ColorGraph {
        let steps = kinds
            .iter()
            .enumerate()
            .map(|(i, k)| {
                let mut s = ColorStep::new(ids.next_id(), &format!("S{}", i + 1));
                s.kind = *k;
                s
            })
            .collect();
        ColorGraph::new(steps, Some(LUTRef::Automatic), None, ids.next_id())
    }

    fn order(g: &ColorGraph) -> Vec<Id> {
        g.steps().iter().map(|s| s.id).collect()
    }

    fn kinds(g: &ColorGraph) -> Vec<StepKind> {
        g.steps().iter().map(|s| s.kind).collect()
    }

    fn columns(g: &ColorGraph) -> Vec<Vec<Id>> {
        g.columns().iter().map(|c| c.iter().map(|s| s.id).collect()).collect()
    }

    use StepKind::{Layer, Parallel, Serial};

    #[test]
    fn new_graph_has_one_neutral_step_and_automatic_in_lut() {
        let g = new_graph(&mut SequentialIds::default());
        assert!(g.steps().len() == 1 && ColorStepExt::is_neutral(&g.steps()[0]));
        assert_eq!(g.input_lut, Some(LUTRef::Automatic));
        assert!(g.output_lut.is_none() && g.is_neutral());
    }

    #[test]
    fn add_remove_move_and_enable_steps() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        let b = g.add_step(Some(a), Serial, &mut ids);
        let c = g.add_step(Some(a), Serial, &mut ids); // lands between a and b
        assert_eq!(order(&g), [a, c, b]);
        let labels: Vec<&str> = g.steps().iter().map(|s| s.label.as_str()).collect();
        assert_eq!(labels, ["Step 1", "Step 3", "Step 2"]);
        g.move_step(b, 0);
        assert_eq!(order(&g), [b, a, c]);
        g.move_step(b, 99); // clamped to the end
        assert_eq!(order(&g), [a, c, b]);
        g.set_step_enabled(c, false);
        assert_eq!(g.step(c).map(|s| s.enabled), Some(false));
        g.remove_step(c);
        assert_eq!(order(&g), [a, b]);
        g.remove_step(a);
        g.remove_step(b);
        assert_eq!(g.steps().len(), 1, "the last Step stays (reset instead)");
        assert!(ColorStepExt::is_neutral(&g.steps()[0]));
        let appended = g.add_step(None, Serial, &mut ids);
        assert_eq!(g.steps().last().map(|s| s.id), Some(appended));
    }

    #[test]
    fn primaries_match_cdl_when_lift_is_zero() {
        let p = StepPrimaries {
            gain: ColorTriple { r: 1.2, g: 1.0, b: 0.8 },
            offset: ColorTriple { r: 0.01, g: 0.0, b: -0.02 },
            gamma: ColorTriple { r: 0.9, g: 1.0, b: 1.1 },
            saturation: 0.8,
            ..StepPrimaries::default()
        };
        let out = p.apply([0.4, 0.5, 0.6]);
        let sop = |v: f32, s: f32, o: f32, pw: f32| {
            let t = v * s + o;
            if t > 0.0 { t.powf(pw) } else { t }
        };
        let (r, g, b) = (sop(0.4, 1.2, 0.01, 0.9), sop(0.5, 1.0, 0.0, 1.0), sop(0.6, 0.8, -0.02, 1.1));
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        assert!((out[0] - (y + 0.8 * (r - y))).abs() < 1e-5);
        assert!((out[1] - (y + 0.8 * (g - y))).abs() < 1e-5);
        assert!((out[2] - (y + 0.8 * (b - y))).abs() < 1e-5);
        assert!(StepPrimaries::default().is_neutral());
        assert_eq!(StepPrimaries::default().apply([0.4, 0.5, 0.6]), [0.4, 0.5, 0.6]);
    }

    #[test]
    fn new_steps_are_serial_at_mix_100_and_the_first_step_stays_serial() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let id = g.add_step(None, Serial, &mut ids);
        assert!(g.step(id).is_some_and(|s| s.kind == Serial && s.mix == 100.0));
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        let p = g.add_step(Some(a), Parallel, &mut ids);
        let l = g.add_step(Some(p), Layer, &mut ids);
        assert_eq!(kinds(&g), [Serial, Parallel, Layer]);
        g.move_step(p, 0);
        assert_eq!(g.steps()[0].kind, Serial, "the first Step is always serial");
        assert_eq!(g.step(l).map(|s| s.kind), Some(Layer));
    }

    #[test]
    fn moving_a_head_away_hands_its_column_to_the_first_follower() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        let b = g.add_step(Some(a), Parallel, &mut ids);
        let c = g.add_step(Some(b), Serial, &mut ids);
        g.move_step(a, 2);
        assert_eq!(order(&g), [b, c, a]);
        assert_eq!(kinds(&g), [Serial, Serial, Serial]);
    }

    #[test]
    fn dropping_a_step_on_a_wire_makes_it_a_serial_step_in_that_gap() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        let b = g.add_step(Some(a), Parallel, &mut ids);
        let c = g.add_step(Some(b), Serial, &mut ids);
        let d = g.add_step(Some(c), Serial, &mut ids);
        g.move_to_gap(b, 2); // columns without b: [a] [c] [d] -> between c and d
        assert_eq!(order(&g), [a, c, b, d]);
        assert_eq!(kinds(&g), [Serial, Serial, Serial, Serial]);
        g.move_to_gap(a, 0);
        assert_eq!(order(&g), [a, c, b, d]);
        g.move_to_gap(d, 0);
        assert_eq!(g.steps().first().map(|s| s.id), Some(d));
    }

    #[test]
    fn columns_group_a_head_with_its_followers() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        let b = g.add_step(Some(a), Parallel, &mut ids);
        let c = g.add_step(Some(b), Layer, &mut ids);
        let d = g.add_step(Some(c), Serial, &mut ids);
        let e = g.add_step(Some(d), Parallel, &mut ids);
        assert_eq!(columns(&g), [vec![a, b, c], vec![d, e]]);
        assert_eq!(g.serial_count(), 2);
    }

    #[test]
    fn removing_a_head_promotes_its_first_follower() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        let b = g.add_step(Some(a), Serial, &mut ids);
        let c = g.add_step(Some(b), Parallel, &mut ids);
        g.remove_step(b);
        assert_eq!(order(&g), [a, c]);
        assert_eq!(g.steps()[1].kind, Serial);
        g.remove_step(a);
        assert_eq!(order(&g), [c]);
    }

    #[test]
    fn kind_change_and_reset_keeps_kind() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let b = g.add_step(None, Serial, &mut ids);
        g.set_kind(b, Layer);
        assert_eq!(g.step(b).map(|s| s.kind), Some(Layer));
        let first = g.steps()[0].id;
        g.set_kind(first, Parallel);
        assert_eq!(g.steps()[0].kind, Serial, "the first Step cannot leave the series");
        g.update(b, |s| s.mix = 40.0);
        g.update(b, |s| s.reset());
        assert!(g.step(b).is_some_and(|s| s.kind == Layer && s.mix == 100.0));
    }

    #[test]
    fn rename_trims_and_ignores_empty_names() {
        let mut ids = SequentialIds::default();
        let mut g = new_graph(&mut ids);
        let a = g.steps()[0].id;
        g.rename(a, "  Skin  ");
        assert_eq!(g.steps()[0].label, "Skin");
        g.rename(a, "   ");
        assert_eq!(g.steps()[0].label, "Skin");
    }

    #[test]
    fn mix_alone_is_not_a_change() {
        let mut s = ColorStep::new(Id::NIL, "A");
        s.mix = 30.0;
        assert!(ColorStepExt::is_neutral(&s));
    }

    #[test]
    fn deleting_a_mixer_turns_its_inputs_into_serial_steps() {
        let mut ids = SequentialIds::default();
        let mut g = graph(&[Serial, Parallel, Layer, Serial], &mut ids);
        let head = g.steps()[0].id;
        g.set_mixer_position(head, Some(StepPosition { x: 1.0, y: 2.0 }));
        assert_eq!(g.stack(head).len(), 3);
        assert!(g.dissolve_mixer(head));
        assert_eq!(kinds(&g), [Serial, Serial, Serial, Serial]);
        let labels: Vec<&str> = g.steps().iter().map(|s| s.label.as_str()).collect();
        assert_eq!(labels, ["S1", "S2", "S3", "S4"], "the order stays");
        assert!(g.steps()[0].mixer_position.is_none());
        assert!(!g.dissolve_mixer(head), "a lone Step has no mixer");
    }

    #[test]
    fn a_wire_from_a_steps_output_makes_the_target_follow_it() {
        let mut ids = SequentialIds::default();
        let mut g = graph(&[Serial, Serial, Serial], &mut ids);
        let (a, b, c) = (g.steps()[0].id, g.steps()[1].id, g.steps()[2].id);
        assert!(g.follow(c, Some(a)));
        assert_eq!(order(&g), [a, c, b]);
        assert!(g.follow(c, None), "from the source: the front");
        assert_eq!(order(&g), [c, a, b]);
        assert!(!g.follow(c, Some(c)), "a loop snaps back");
        assert!(!g.follow(ids.next_id(), Some(a)));
    }

    #[test]
    fn a_wire_from_a_stack_branch_does_not_map_but_from_its_mixer_does() {
        let mut ids = SequentialIds::default();
        let mut g = graph(&[Serial, Parallel, Serial], &mut ids);
        let (a, p, c) = (g.steps()[0].id, g.steps()[1].id, g.steps()[2].id);
        let before = g.clone();
        assert!(!g.follow(c, Some(p)));
        assert_eq!(g, before);
        assert!(g.follow(c, Some(a)), "the head names the stack's mixer");
        assert_eq!(order(&g), [a, p, c]);
        assert!(!g.follow(p, Some(a)), "a stack member cannot follow its own mixer");
    }

    #[test]
    fn a_wire_into_a_mixer_adds_a_parallel_input() {
        let mut ids = SequentialIds::default();
        let mut g = graph(&[Serial, Parallel, Serial, Serial], &mut ids);
        let (a, c, d) = (g.steps()[0].id, g.steps()[2].id, g.steps()[3].id);
        assert!(g.join(d, a, Parallel));
        assert_eq!(kinds(&g), [Serial, Parallel, Parallel, Serial]);
        assert!(g.steps()[2].id == d && g.steps()[3].id == c);
        assert_eq!(g.stack(a).len(), 3);
        assert!(!g.join(d, a, Parallel), "already an input");
        assert!(!g.join(c, c, Parallel), "a lone Step has no mixer");
    }

    #[test]
    fn neutral_simple_gives_one_neutral_active_step() {
        let g = ColorGraph::from_simple(&ClipColor::default(), &mut SequentialIds::default());
        assert!(g.is_active && g.steps().len() == 1 && ColorStepExt::is_neutral(&g.steps()[0]));
        assert_eq!(g.input_lut, Some(LUTRef::Automatic));
    }

    #[test]
    fn basic_values_land_in_step_one() {
        let mut c = ClipColor::default();
        c.edit_effects(|fx| {
            fx[0].basic.exposure = 1.0;
            fx[0].basic.contrast = 50.0;
            fx[0].basic.saturation = 120.0;
            fx[0].curves.master =
                vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 0.5, y: 0.6 }, CurvePoint { x: 1.0, y: 1.0 }];
        });
        let g = ColorGraph::from_simple(&c, &mut SequentialIds::default());
        let p = &g.steps()[0].primaries;
        assert_eq!(g.steps().len(), 1);
        assert!((p.gain.r - 2.0).abs() < 1e-5 && (p.gain.g - 2.0).abs() < 1e-5);
        assert!((p.contrast - 1.5).abs() < 1e-5 && (p.saturation - 1.2).abs() < 1e-5);
        assert_eq!(g.steps()[0].curves, c.effects()[0].curves);
    }

    #[test]
    fn disabled_sections_and_second_effect_are_respected() {
        let mut c = ClipColor::default();
        c.edit_effects(|fx| {
            fx[0].basic.contrast = 40.0;
            fx[0].set_enabled(ColorSectionKind::BasicCorrection, false);
        });
        c.add_effect();
        c.edit_effects(|fx| fx[1].wheels.saturation = 50.0);
        let g = ColorGraph::from_simple(&c, &mut SequentialIds::default());
        assert_eq!(g.steps().len(), 1, "the disabled Basic section leaves effect 1 neutral");
        assert!((g.steps()[0].primaries.saturation - 0.5).abs() < 1e-5);
    }

    #[test]
    fn values_stay_in_slider_ranges() {
        let mut c = ClipColor::default();
        c.edit_effects(|fx| {
            fx[0].basic.exposure = 5.0;
            fx[0].basic.saturation = 200.0;
            fx[0].wheels.saturation = 200.0;
        });
        let g = ColorGraph::from_simple(&c, &mut SequentialIds::default());
        let p = &g.steps()[0].primaries;
        assert_eq!(p.gain.r, StepPrimaries::GAIN_RANGE.1);
        assert_eq!(p.saturation, StepPrimaries::SATURATION_RANGE.1);
    }

    #[test]
    fn layer_list_blends_and_rows() {
        let mut ids = SequentialIds::default();
        let mut g = graph(&[Serial, Serial, Serial], &mut ids);
        let (a, b, c) = (g.steps()[0].id, g.steps()[1].id, g.steps()[2].id);
        let rows: Vec<Id> = g.list_steps().iter().map(|s| s.id).collect();
        assert_eq!(rows, [c, b, a], "the topmost row is the last Step");
        assert!(!g.set_blend(a, StepBlend::Parallel), "the first Step stays in series");
        assert!(g.set_blend(b, StepBlend::Layer(LayerMixMode::Screen)));
        assert_eq!(g.blend(b), Some(StepBlend::Layer(LayerMixMode::Screen)));
        assert!(g.set_blend(b, StepBlend::Series) && g.blend(b) == Some(StepBlend::Series));
        g.move_step_to_list_row(c, 2);
        assert_eq!(g.steps()[0].id, c, "the bottom row is the first Step");
        assert_eq!(StepBlend::all().len(), 9);
    }
}
