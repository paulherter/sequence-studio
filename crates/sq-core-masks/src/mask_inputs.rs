// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MaskInputs.swift (`ClipEffects.magicMattes` waits on the effects crate, see NOTES.md)
//! Unified masks: every mask (Magic, Pen, Ellipse, Rectangle) is an item of the clip (`Clip.masks`). It cuts the clip's
//! picture (Opacity) while `used_by_opacity`, and limits any picture effect that lists it in `ClipEffect.mask_input`.
//! One mask can feed several effects.

use crate::anonymize_order::AnonymizeOrderExt;
use crate::masks::{ClipMasksExt, MaskPathExt, MaskShape};
use crate::subject_mask::MaskSourceExt;
use sq_core_model::{Clip, ClipEffect, ClipMask, MagicPoint, MaskPath, MaskShapeKind, MaskSource, MaskVertex, Project};
use sq_core_time::{Id, IdSource, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// Kinds whose result the renderer can mix back over the picture they read, by the coverage of their input masks: blur
/// and the picture filters, the keys, Transform (then a picture warp instead of a clip transform) and Color (then a
/// grade pass in the effect chain). The clip decides for Color (`takes_mask_input`: not its first one).
// shortcut: the kind strings are copied because the effects catalog constants live in the effects crate; switch to its
// constants when that crate exists.
pub const MASK_INPUT_KINDS: [&str; 38] = [
    "gaussianBlur",
    "sharpen",
    "unsharpMask",
    "directionalBlur",
    "mirror",
    "noise",
    "glow",
    "mosaic",
    "vignette",
    "filmGrain",
    "rgbSplit",
    "radialBlur",
    "horizontalFlip",
    "verticalFlip",
    "invert",
    "posterize",
    "tint",
    "blackAndWhite",
    "brightnessContrast",
    "twirl",
    "cornerPin",
    "waveWarp",
    "spherize",
    "strobeLight",
    "lensDistortion",
    "lightLeak",
    "gradient",
    "halftone",
    "tile",
    "kaleidoscope",
    "edgeFeather",
    "glitchDisplace",
    "alphaOutline",
    "longShadow",
    "ultraKey",
    "lumaKey",
    "transform",
    "color",
];

/// A Color effect (Swift `ClipEffect.isColor`).
pub(crate) fn is_color(e: &ClipEffect) -> bool {
    e.kind == sq_core_model::COLOR_KIND
}

/// Logic Swift keeps on `ClipEffect` in `MaskInputs.swift`.
pub trait ClipEffectMaskExt {
    /// Whether the kind can take a mask input at all.
    fn accepts_mask_input(&self) -> bool;
}

impl ClipEffectMaskExt for ClipEffect {
    fn accepts_mask_input(&self) -> bool {
        MASK_INPUT_KINDS.contains(&self.kind.as_str())
    }
}

/// Logic Swift keeps on `Clip` in `MaskInputs.swift`.
pub trait MaskInputsExt {
    /// Whether `e` can take a mask input on this clip. The first Color effect converts the footage (the base grade every
    /// later effect builds on), so it stays whole; a masked grade is a second Color effect.
    fn takes_mask_input(&self, e: &ClipEffect) -> bool;
    /// `e` takes a mask input here and at least one of its input masks exists and is on: the renderer then runs it as a
    /// masked pass (Color: out of the clip's grade; Transform: out of the clip's transform).
    #[doc(hidden)]
    fn has_live_mask_input(&self, e: &ClipEffect) -> bool;
    /// The shapes of `e`'s input masks at clip-local `t` (enabled ones that still exist, in the clip's list order).
    #[doc(hidden)]
    fn input_mask_shapes(&self, e: &ClipEffect, t: Time) -> Vec<MaskShape>;
    /// Effects of this clip that take mask `id` as input.
    fn effects_using_mask(&self, id: Id) -> Vec<Id>;
    /// Adds or removes mask `id` as an input of effect `effect_id` (no duplicates; only on kinds that take one).
    fn set_mask_input(&mut self, id: Id, on: bool, effect_id: Id);
    /// Whether mask `id` cuts the clip's picture (Opacity).
    fn set_mask_used_by_opacity(&mut self, id: Id, on: bool);
    /// Deletes a mask and drops it from every effect's input.
    fn remove_mask(&mut self, id: Id);
    /// Magic mode click at frame fraction `p` on the source frame at `source_time`. Adds the point to mask `id`: on the
    /// pick's own frame it adds / removes objects, on any other frame it corrects the tracked matte from there on
    /// (`MagicFollower`); `id` `None` makes a new Magic mask. A subtract (Option) click needs a pick to subtract from.
    /// Returns the mask, `None` when nothing changed.
    fn magic_click(
        &mut self,
        id: Option<Id>,
        p: Vec2,
        subtract: bool,
        source_time: Time,
        ids: &mut dyn IdSource,
    ) -> Option<Id>;
    /// Pen mode click: appends a corner point to path mask `id` (at clip-local `t`, a key there when animated), or starts
    /// a new path mask with this first point. Returns the mask.
    fn pen_click(&mut self, id: Option<Id>, p: Vec2, t: Time, ids: &mut dyn IdSource) -> Id;
    /// Ellipse / Rectangle mode click: the default shape centered on `p`.
    fn add_shape_mask_at(&mut self, kind: MaskShapeKind, p: Vec2, ids: &mut dyn IdSource) -> Id;
    /// Ellipse / Rectangle drawn by dragging: the path as `MaskShapeDrag` made it.
    fn add_shape_mask_path(&mut self, kind: MaskShapeKind, path: MaskPath, ids: &mut dyn IdSource) -> Id;
    /// Anything only v54 can hold: a Magic mask, a mask that does not cut Opacity, or an effect with a mask input.
    #[doc(hidden)]
    fn holds_mask_inputs(&self) -> bool;
    /// Masks as Paste Attributes copies them, with the old -> new id map (for the pasted effects' inputs).
    #[doc(hidden)]
    fn pasted_masks_with_map(&self, ids: &mut dyn IdSource) -> (Vec<ClipMask>, BTreeMap<Id, Id>);
}

impl MaskInputsExt for Clip {
    fn takes_mask_input(&self, e: &ClipEffect) -> bool {
        if !e.accepts_mask_input() {
            return false;
        }
        if !is_color(e) {
            return true;
        }
        self.effects.iter().find(|x| is_color(x)).map(|x| x.id) != Some(e.id)
    }

    fn has_live_mask_input(&self, e: &ClipEffect) -> bool {
        if e.mask_input.is_empty() || !self.takes_mask_input(e) {
            return false;
        }
        self.masks().iter().any(|m| m.enabled && e.mask_input.contains(&m.id))
    }

    fn input_mask_shapes(&self, e: &ClipEffect, t: Time) -> Vec<MaskShape> {
        if e.mask_input.is_empty() || !self.takes_mask_input(e) {
            return Vec::new();
        }
        let ids: BTreeSet<Id> = e.mask_input.iter().copied().collect();
        self.masks()
            .iter()
            .filter(|m| m.enabled && ids.contains(&m.id))
            .map(|m| self.mask_shape(m, t))
            .filter(|s| s.polygon.len() >= 2 || s.source.uses_matte())
            .collect()
    }

    fn effects_using_mask(&self, id: Id) -> Vec<Id> {
        self.effects.iter().filter(|e| e.mask_input.contains(&id)).map(|e| e.id).collect()
    }

    fn set_mask_input(&mut self, id: Id, on: bool, effect_id: Id) {
        if self.mask(id).is_none() {
            return;
        }
        let Some(i) = self.effects.iter().position(|e| e.id == effect_id) else { return };
        if !self.takes_mask_input(&self.effects[i]) {
            return;
        }
        self.effects[i].mask_input.retain(|m| *m != id);
        if on {
            self.effects[i].mask_input.push(id);
        }
        self.pin_covers(); // an effect limited to an Anonymize mask is a cover
    }

    fn set_mask_used_by_opacity(&mut self, id: Id, on: bool) {
        self.update_mask(id, |m| m.set_used_by_opacity(on));
    }

    fn remove_mask(&mut self, id: Id) {
        if let Some(list) = &mut self.mask_store {
            list.retain(|m| m.id != id);
            if list.is_empty() {
                self.mask_store = None;
            }
        }
        for e in &mut self.effects {
            e.mask_input.retain(|m| *m != id);
        }
    }

    fn magic_click(
        &mut self,
        id: Option<Id>,
        p: Vec2,
        subtract: bool,
        source_time: Time,
        ids: &mut dyn IdSource,
    ) -> Option<Id> {
        let point = MagicPoint { position: p, subtract, source_time };
        if let Some(id) = id
            && let Some(m) = self.mask(id).filter(|m| m.source() == MaskSource::Magic)
        {
            let mut sel = m.magic.clone().unwrap_or_default();
            if subtract && sel.points.is_empty() {
                return None;
            }
            sel.points.push(point);
            self.update_mask(id, |m| m.magic = Some(sel));
            return Some(id);
        }
        if subtract {
            return None;
        }
        let m = ClipMask::make_magic(ids.next_id(), &self.next_mask_name(), vec![point]);
        let new_id = m.id;
        let mut list = self.masks().to_vec();
        list.push(m);
        self.set_masks(list);
        Some(new_id)
    }

    fn pen_click(&mut self, id: Option<Id>, p: Vec2, t: Time, ids: &mut dyn IdSource) -> Id {
        if let Some(id) = id
            && let Some(m) = self.mask(id).filter(|m| m.source() == MaskSource::Path)
        {
            let mut path = m.path.value_at_local(t);
            path.vertices.push(MaskVertex::corner(p));
            self.set_mask_path(id, path, t, ids);
            return id;
        }
        let mut m = ClipMask::new(
            ids.next_id(),
            &self.next_mask_name(),
            MaskShapeKind::Bezier,
            MaskPath { vertices: vec![MaskVertex::corner(p)] },
        );
        m.feather.value = ClipMask::DEFAULT_FEATHER;
        let new_id = m.id;
        let mut list = self.masks().to_vec();
        list.push(m);
        self.set_masks(list);
        new_id
    }

    fn add_shape_mask_at(&mut self, kind: MaskShapeKind, p: Vec2, ids: &mut dyn IdSource) -> Id {
        let mut m = ClipMask::make(ids.next_id(), kind, &self.next_mask_name());
        m.path.value = m.path.value.translated(p - Vec2::new(0.5, 0.5));
        let new_id = m.id;
        let mut list = self.masks().to_vec();
        list.push(m);
        self.set_masks(list);
        new_id
    }

    fn add_shape_mask_path(&mut self, kind: MaskShapeKind, path: MaskPath, ids: &mut dyn IdSource) -> Id {
        let mut m = ClipMask::new(ids.next_id(), &self.next_mask_name(), kind, path);
        m.feather.value = ClipMask::DEFAULT_FEATHER;
        let new_id = m.id;
        let mut list = self.masks().to_vec();
        list.push(m);
        self.set_masks(list);
        new_id
    }

    fn holds_mask_inputs(&self) -> bool {
        self.masks().iter().any(|m| m.source() == MaskSource::Magic || !m.used_by_opacity())
            || self.effects.iter().any(|e| !e.mask_input.is_empty())
    }

    fn pasted_masks_with_map(&self, ids: &mut dyn IdSource) -> (Vec<ClipMask>, BTreeMap<Id, Id>) {
        let mut map = BTreeMap::new();
        let out = self
            .masks()
            .iter()
            .map(|m| {
                let mut c = m.clone();
                c.id = ids.next_id();
                map.insert(m.id, c.id);
                c
            })
            .collect();
        (out, map)
    }
}

/// A Rectangle / Ellipse being drawn with the Mask tool: a rubber band from the press (`start`, frame fraction) to the
/// pointer. Shift = square / circle (equal sides in frame px), Option = `start` is the center.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskShapeDrag {
    /// The shape drawn.
    pub kind: MaskShapeKind,
    /// The press point, frame fractions.
    pub start: Vec2,
}

impl MaskShapeDrag {
    /// Pointer travel (view pt) below which a press counts as a click (the default shape there instead).
    pub const CLICK_DISTANCE: f64 = 3.0;

    /// A press that travelled less than `CLICK_DISTANCE` is a click.
    pub fn is_click(view_distance: f64) -> bool {
        view_distance < Self::CLICK_DISTANCE
    }

    /// The shape for the pointer at `p`. `frame` = the clip's frame size in px (for Shift's equal sides).
    pub fn path(&self, p: Vec2, square: bool, from_center: bool, frame: Vec2) -> MaskPath {
        let mut d = p - self.start;
        if square && frame.x > 0.0 && frame.y > 0.0 {
            let side = (d.x.abs() * frame.x).max(d.y.abs() * frame.y);
            d = Vec2::new(
                (if d.x < 0.0 { -side } else { side }) / frame.x,
                (if d.y < 0.0 { -side } else { side }) / frame.y,
            );
        }
        let a = if from_center { self.start - d } else { self.start };
        let b = self.start + d;
        match self.kind {
            MaskShapeKind::Ellipse => {
                let r = Vec2::new((b.x - a.x).abs() / 2.0, (b.y - a.y).abs() / 2.0);
                MaskPath::ellipse(Vec2::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0), r)
            }
            MaskShapeKind::Rectangle | MaskShapeKind::Bezier => MaskPath::rectangle(a, b),
        }
    }
}

/// Logic Swift keeps on `Project` in `MaskInputs.swift`.
pub trait ProjectMaskInputsExt {
    /// ProjectFile v54 gate.
    fn contains_mask_inputs(&self) -> bool;
}

impl ProjectMaskInputsExt for Project {
    fn contains_mask_inputs(&self) -> bool {
        self.timelines.iter().any(|t| t.tracks.iter().any(|t| t.clips().iter().any(|c| c.holds_mask_inputs())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::masks::ClipMaskExt;
    use crate::test_util::test_clip;
    use sq_core_time::IdSource;
    use sq_core_time::SequentialIds;

    fn fx(n: u128, kind: &str) -> ClipEffect {
        ClipEffect::new(Id::from_u128(0xE00 + n), kind)
    }

    #[test]
    fn keys_transform_and_later_colour_effects_take_a_mask() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        c.effects = vec![
            fx(1, "color"),
            fx(2, "color"),
            fx(3, "ultraKey"),
            fx(4, "lumaKey"),
            fx(5, "transform"),
            fx(6, "crop"),
        ];
        let takes: Vec<bool> = c.effects.iter().map(|e| c.takes_mask_input(e)).collect();
        // The first Color effect converts the footage (the clip's base grade): it stays whole.
        assert_eq!(takes, vec![false, true, true, true, true, false]);
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Ellipse, "M");
        m.set_used_by_opacity(false);
        let mid = m.id;
        c.set_masks(vec![m]);
        let (first, second) = (c.effects[0].id, c.effects[1].id);
        c.set_mask_input(mid, true, first);
        assert!(c.effects[0].mask_input.is_empty());
        c.set_mask_input(mid, true, second);
        assert_eq!(c.effects[1].mask_input, vec![mid]);
    }

    #[test]
    fn picture_effects_take_a_mask_input() {
        assert!(fx(1, "mosaic").accepts_mask_input());
        assert!(fx(1, "gaussianBlur").accepts_mask_input());
        assert!(!fx(1, "crop").accepts_mask_input());
        assert!(fx(1, "ultraKey").accepts_mask_input());
    }

    #[test]
    fn removing_a_mask_drops_it_from_effect_inputs() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let m = ClipMask::make(ids.next_id(), MaskShapeKind::Ellipse, "M");
        let mid = m.id;
        c.set_masks(vec![m]);
        let mut e = fx(1, "mosaic");
        e.mask_input = vec![mid];
        c.effects = vec![e];
        c.remove_mask(mid);
        assert!(c.masks().is_empty());
        assert!(c.effects[0].mask_input.is_empty());
    }

    #[test]
    fn assigning_masks_to_effects_and_opacity() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let m = ClipMask::make(ids.next_id(), MaskShapeKind::Ellipse, "M");
        let mid = m.id;
        c.set_masks(vec![m]);
        let e = fx(1, "mosaic");
        let eid = e.id;
        c.effects = vec![e];
        c.set_mask_input(mid, true, eid);
        assert_eq!(c.effects[0].mask_input, vec![mid]);
        c.set_mask_input(mid, true, eid);
        assert_eq!(c.effects[0].mask_input, vec![mid]); // no duplicates
        c.set_mask_used_by_opacity(mid, false);
        assert_eq!(c.mask(mid).map(|m| m.used_by_opacity()), Some(false));
        assert_eq!(c.effects_using_mask(mid), vec![eid]);
        assert!(c.has_live_mask_input(&c.effects[0]));
        c.set_mask_input(mid, false, eid);
        assert!(c.effects[0].mask_input.is_empty());
    }

    #[test]
    fn mask_on_an_effect_leaves_opacity_and_scopes_the_effect() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Ellipse, "M");
        m.set_used_by_opacity(false);
        let mid = m.id;
        c.set_masks(vec![m]);
        let mut e = fx(1, "mosaic");
        e.mask_input = vec![mid];
        assert!(c.mask_shapes_at_local(Time::new(1, 1)).is_empty()); // Opacity does not cut the picture
        let scope = c.input_mask_shapes(&e, Time::new(1, 1));
        assert_eq!(scope.len(), 1);
        assert!(!scope[0].polygon.is_empty());
    }

    #[test]
    fn missing_or_disabled_input_masks_leave_the_effect_whole() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Ellipse, "M");
        m.enabled = false;
        let mid = m.id;
        c.set_masks(vec![m]);
        let mut e = fx(1, "mosaic");
        e.mask_input = vec![mid, Id::from_u128(999)];
        assert!(c.input_mask_shapes(&e, Time::ZERO).is_empty());
        assert!(!c.has_live_mask_input(&e));
    }

    #[test]
    fn clicks_make_and_extend_masks() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        // A subtract click needs a pick to subtract from.
        assert_eq!(c.magic_click(None, Vec2::new(0.5, 0.5), true, Time::ZERO, &mut ids), None);
        let a = c.magic_click(None, Vec2::new(0.5, 0.5), false, Time::ZERO, &mut ids);
        let a = a.unwrap_or(Id::NIL);
        assert_eq!(c.mask(a).map(|m| m.name.as_str()), Some("Mask (1)"));
        assert_eq!(c.magic_click(Some(a), Vec2::new(0.2, 0.2), true, Time::ZERO, &mut ids), Some(a));
        assert_eq!(c.mask(a).and_then(|m| m.magic.as_ref()).map(|s| s.points.len()), Some(2));
        let pen = c.pen_click(None, Vec2::new(0.1, 0.1), Time::ZERO, &mut ids);
        assert_eq!(c.pen_click(Some(pen), Vec2::new(0.9, 0.1), Time::ZERO, &mut ids), pen);
        assert_eq!(c.mask(pen).map(|m| m.path.value.vertices.len()), Some(2));
        let shape = c.add_shape_mask_at(MaskShapeKind::Rectangle, Vec2::new(0.6, 0.5), &mut ids);
        let p = c.mask(shape).map(|m| m.path.value.vertices[0].point).unwrap_or(Vec2::ZERO);
        assert!((p.x - 0.35).abs() < 1e-12 && (p.y - 0.25).abs() < 1e-12);
        assert!(c.holds_mask_inputs()); // a Magic mask
        let (copies, map) = c.pasted_masks_with_map(&mut ids);
        assert_eq!(copies.len(), c.masks().len());
        assert!(copies.iter().all(|m| map.values().any(|v| *v == m.id)));
    }

    #[test]
    fn shape_drag_makes_squares_and_centered_shapes() {
        let drag = MaskShapeDrag { kind: MaskShapeKind::Rectangle, start: Vec2::new(0.5, 0.5) };
        let frame = Vec2::new(200.0, 100.0);
        let p = drag.path(Vec2::new(0.6, 0.55), true, false, frame);
        // Equal sides in px: 20 px wide -> 0.1 of width; 10 px tall -> square uses the larger (20 px) = 0.2 of height.
        let (a, b) = (p.vertices[0].point, p.vertices[2].point);
        assert!(((b.x - a.x) * 200.0 - (b.y - a.y) * 100.0).abs() < 1e-9);
        let centered = drag.path(Vec2::new(0.6, 0.6), false, true, frame);
        assert!((centered.vertices[0].point.x - 0.4).abs() < 1e-12);
        assert!(MaskShapeDrag::is_click(2.0) && !MaskShapeDrag::is_click(3.0));
    }

    fn bounds(p: &MaskPath) -> (Vec2, Vec2) {
        let poly = p.polygon();
        let f = |g: fn(&Vec2) -> f64, pick: fn(f64, f64) -> f64, init: f64| poly.iter().map(g).fold(init, pick);
        (
            Vec2::new(f(|v| v.x, f64::min, f64::INFINITY), f(|v| v.y, f64::min, f64::INFINITY)),
            Vec2::new(f(|v| v.x, f64::max, f64::NEG_INFINITY), f(|v| v.y, f64::max, f64::NEG_INFINITY)),
        )
    }

    fn close(a: Vec2, b: Vec2, eps: f64) -> bool {
        (a.x - b.x).abs() < eps && (a.y - b.y).abs() < eps
    }

    const FRAME: Vec2 = Vec2::new(1920.0, 1080.0);

    #[test]
    fn rectangle_spans_from_press_to_pointer_in_any_direction() {
        let d = MaskShapeDrag { kind: MaskShapeKind::Rectangle, start: Vec2::new(0.6, 0.7) };
        let p = d.path(Vec2::new(0.2, 0.3), false, false, FRAME);
        assert_eq!(p.vertices.len(), 4);
        let b = bounds(&p);
        assert!(close(b.0, Vec2::new(0.2, 0.3), 1e-6) && close(b.1, Vec2::new(0.6, 0.7), 1e-6));
    }

    #[test]
    fn ellipse_fits_the_dragged_box() {
        let d = MaskShapeDrag { kind: MaskShapeKind::Ellipse, start: Vec2::new(0.1, 0.2) };
        let p = d.path(Vec2::new(0.5, 0.6), false, false, FRAME);
        assert_eq!(p.vertices.len(), 4);
        let b = bounds(&p);
        assert!(close(b.0, Vec2::new(0.1, 0.2), 1e-3) && close(b.1, Vec2::new(0.5, 0.6), 1e-3));
    }

    #[test]
    fn shift_makes_a_square_in_frame_pixels_and_option_draws_from_the_centre() {
        let d = MaskShapeDrag { kind: MaskShapeKind::Rectangle, start: Vec2::new(0.5, 0.5) };
        let b = bounds(&d.path(Vec2::new(0.7, 0.6), true, false, FRAME));
        let (w, h) = ((b.1.x - b.0.x) * FRAME.x, (b.1.y - b.0.y) * FRAME.y);
        assert!((w - h).abs() < 1e-6 && (w - 0.2 * 1920.0).abs() < 1e-6);
        assert!(close(b.0, Vec2::new(0.5, 0.5), 1e-6));
        let q = bounds(&d.path(Vec2::new(0.45, 0.2), true, false, FRAME));
        assert!((q.1.x - 0.5).abs() < 1e-9 && (q.1.y - 0.5).abs() < 1e-9);
        assert!(((q.1.x - q.0.x) * FRAME.x - (q.1.y - q.0.y) * FRAME.y).abs() < 1e-6);
        let e = MaskShapeDrag { kind: MaskShapeKind::Ellipse, start: Vec2::new(0.5, 0.5) };
        let c = bounds(&e.path(Vec2::new(0.6, 0.7), false, true, FRAME));
        assert!(close(c.0, Vec2::new(0.4, 0.3), 1e-3) && close(c.1, Vec2::new(0.6, 0.7), 1e-3));
        let s = bounds(&e.path(Vec2::new(0.6, 0.55), true, true, FRAME));
        assert!(((s.1.x - s.0.x) * FRAME.x - (s.1.y - s.0.y) * FRAME.y).abs() < 0.5);
        assert!(((s.0.x + s.1.x) / 2.0 - 0.5).abs() < 1e-3 && ((s.0.y + s.1.y) / 2.0 - 0.5).abs() < 1e-3);
    }

    #[test]
    fn add_drawn_mask_stores_the_path_once() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let path = MaskShapeDrag { kind: MaskShapeKind::Rectangle, start: Vec2::new(0.1, 0.1) }.path(
            Vec2::new(0.3, 0.4),
            false,
            false,
            FRAME,
        );
        let a = c.add_shape_mask_path(MaskShapeKind::Rectangle, path.clone(), &mut ids);
        let b = c.add_shape_mask_path(MaskShapeKind::Ellipse, path.clone(), &mut ids);
        assert!(c.masks().len() == 2 && a != b);
        let m = c.mask(a).cloned();
        assert!(m.as_ref().is_some_and(|m| m.kind == MaskShapeKind::Rectangle
            && m.path.value == path
            && m.name == "Mask (1)"
            && m.feather.value == ClipMask::DEFAULT_FEATHER));
        assert_eq!(c.mask(b).map(|m| m.name.as_str()), Some("Mask (2)"));
    }

    #[test]
    fn magic_click_on_another_frame_adds_a_correction_and_changes_the_cache_key() {
        use crate::magic_mask::MagicSelectionExt;
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let id = c.magic_click(None, Vec2::new(0.3, 0.4), false, Time::new(3, 1), &mut ids).unwrap_or(Id::NIL);
        let key = |c: &Clip| c.mask(id).and_then(|m| m.magic.as_ref()).map(|s| s.cache_key(c.media));
        let before = key(&c);
        c.magic_click(Some(id), Vec2::new(0.5, 0.5), false, Time::new(4, 1), &mut ids);
        c.magic_click(Some(id), Vec2::new(0.6, 0.5), true, Time::new(4, 1), &mut ids);
        let pts = c.mask(id).and_then(|m| m.magic.as_ref()).map(|s| s.points.clone()).unwrap_or_default();
        assert_eq!(
            pts.iter().map(|p| p.source_time).collect::<Vec<_>>(),
            vec![Time::new(3, 1), Time::new(4, 1), Time::new(4, 1)]
        );
        assert_eq!(pts.iter().map(|p| p.subtract).collect::<Vec<_>>(), vec![false, false, true]);
        assert_eq!(c.mask(id).and_then(|m| m.magic.as_ref()).and_then(|s| s.anchor_time()), Some(Time::new(3, 1)));
        assert_ne!(key(&c), before);
    }

    #[test]
    fn pen_clicks_build_a_path_and_a_shape_is_placed_around_the_click() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let id = c.pen_click(None, Vec2::new(0.2, 0.2), Time::ZERO, &mut ids);
        c.pen_click(Some(id), Vec2::new(0.8, 0.2), Time::ZERO, &mut ids);
        c.pen_click(Some(id), Vec2::new(0.5, 0.8), Time::ZERO, &mut ids);
        let v =
            c.mask(id).map(|m| m.path.value.vertices.iter().map(|v| v.point).collect::<Vec<_>>()).unwrap_or_default();
        assert_eq!(v, vec![Vec2::new(0.2, 0.2), Vec2::new(0.8, 0.2), Vec2::new(0.5, 0.8)]);
        assert!(c.mask(id).is_some_and(|m| m.kind == MaskShapeKind::Bezier && m.source() == MaskSource::Path));
        let s = c.add_shape_mask_at(MaskShapeKind::Ellipse, Vec2::new(0.25, 0.75), &mut ids);
        let poly = c.mask(s).map(|m| m.path.value.polygon()).unwrap_or_default();
        let cx = poly.iter().map(|p| p.x).sum::<f64>() / poly.len() as f64;
        let cy = poly.iter().map(|p| p.y).sum::<f64>() / poly.len() as f64;
        assert!((cx - 0.25).abs() < 0.01 && (cy - 0.75).abs() < 0.01);
    }

    #[test]
    fn color_range_value_and_coverage() {
        use crate::masks::{ColorRangeKeyExt, CoverageInputs, MaskCoverage};
        use sq_core_model::ColorRangeKey;
        let k = ColorRangeKey::new(0.5, 0.5, 0.5, 0.2, 0.2);
        assert_eq!(k.value(0.5, 0.5, 0.5), 1.0);
        assert_eq!(k.value(0.7, 0.7, 0.7), 1.0); // distance 0.2 = tolerance exactly: still fully covered
        assert!((k.value(0.8, 0.8, 0.8) - 0.5).abs() < 1e-9); // distance 0.3 = tolerance + softness / 2
        assert_eq!(k.value(0.95, 0.95, 0.95), 0.0);
        let hard = ColorRangeKey::new(0.0, 1.0, 0.0, 0.1, 0.0);
        assert!(hard.value(0.0, 1.0, 0.0) == 1.0 && hard.value(0.0, 0.0, 0.0) == 0.0);
        let mut ids = SequentialIds::default();
        let m = ClipMask::make_color_range(ids.next_id(), "Color Range", ColorRangeKey::new(0.0, 1.0, 0.0, 0.2, 0.0));
        let shapes = [m.shape_at_local(Time::ZERO)];
        let color = |p: Vec2| Some(if p.x < 50.0 { (0.0, 1.0, 0.0) } else { (1.0, 0.0, 0.0) });
        let inputs = CoverageInputs { color: Some(&color), ..CoverageInputs::default() };
        let cov = |x: f64, i: &CoverageInputs| {
            MaskCoverage::coverage(Vec2::new(x, 50.0), &shapes, Vec2::new(100.0, 100.0), 1.0, i)
        };
        assert_eq!(cov(10.0, &inputs), 1.0);
        assert_eq!(cov(90.0, &inputs), 0.0);
        assert_eq!(cov(10.0, &CoverageInputs::default()), 0.0); // no picture -> covers nothing
        assert!(!MaskSource::ColorRange.uses_matte());
    }
}
