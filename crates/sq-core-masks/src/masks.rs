// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Masks.swift (logic only; the saved types are in sq-core-model)
//! Masks on a clip's picture, like Premiere's Opacity masks. They cut the finished picture of the clip (after all
//! effects), before its Motion places it: the mask moves with the clip. Stored in `Clip.masks`.

use crate::anonymize::MagicSelectionAnonymizeExt;
use crate::magic_mask::MagicSelectionExt;
use crate::subject_mask::{MaskSourceExt, SubjectMatte};
use sq_core_model::{
    AnimatedProperty, Clip, ClipMask, ColorRangeKey, MaskMode, MaskPath, MaskSource, MaskVertex, MatteChannel,
};
use sq_core_time::{Id, IdSource, Keyframe, Time, Vec2};
use std::collections::BTreeMap;

/// Line pieces per curved segment when flattened (`MaskPathExt::polygon`).
pub const CURVE_SUBDIVISIONS: usize = 16;
/// Most polygon points one mask hands to the renderer.
pub const MAX_POLYGON_POINTS: usize = 1024;

/// Logic Swift keeps on `MaskPath`.
pub trait MaskPathExt: Sized {
    /// Corners clockwise from the top left.
    fn rectangle(a: Vec2, b: Vec2) -> MaskPath;
    /// Four-point bezier ellipse (top, right, bottom, left), tangents at the circle constant.
    fn ellipse(center: Vec2, radius: Vec2) -> MaskPath;
    /// The path as a closed polygon (frame fractions): straight segments give one point, curved ones
    /// `CURVE_SUBDIVISIONS`.
    fn polygon(&self) -> Vec<Vec2>;
    /// Moves a vertex; its tangents go along.
    fn move_vertex(&mut self, i: usize, to: Vec2);
    /// Moves every vertex by `d` (frame fractions).
    fn translated(&self, d: Vec2) -> MaskPath;
    /// The vertex within `radius` px of `p` (frame px, `frame` = frame size in px), the nearest one; `None` when none.
    fn vertex_index_near(&self, p: Vec2, frame: Vec2, radius: f64) -> Option<usize>;
}

impl MaskPathExt for MaskPath {
    fn rectangle(a: Vec2, b: Vec2) -> MaskPath {
        let lo = Vec2::new(a.x.min(b.x), a.y.min(b.y));
        let hi = Vec2::new(a.x.max(b.x), a.y.max(b.y));
        MaskPath {
            vertices: vec![
                MaskVertex::corner(lo),
                MaskVertex::corner(Vec2::new(hi.x, lo.y)),
                MaskVertex::corner(hi),
                MaskVertex::corner(Vec2::new(lo.x, hi.y)),
            ],
        }
    }

    fn ellipse(c: Vec2, r: Vec2) -> MaskPath {
        let k = 0.5522847498307936;
        let (kx, ky) = (r.x * k, r.y * k);
        let v = |point: Vec2, in_tangent: Vec2, out_tangent: Vec2| MaskVertex { point, in_tangent, out_tangent };
        MaskPath {
            vertices: vec![
                v(Vec2::new(c.x, c.y - r.y), Vec2::new(-kx, 0.0), Vec2::new(kx, 0.0)),
                v(Vec2::new(c.x + r.x, c.y), Vec2::new(0.0, -ky), Vec2::new(0.0, ky)),
                v(Vec2::new(c.x, c.y + r.y), Vec2::new(kx, 0.0), Vec2::new(-kx, 0.0)),
                v(Vec2::new(c.x - r.x, c.y), Vec2::new(0.0, ky), Vec2::new(0.0, -ky)),
            ],
        }
    }

    fn polygon(&self) -> Vec<Vec2> {
        let vertices = &self.vertices;
        let n = vertices.len();
        if n == 0 {
            return Vec::new();
        }
        let mut out: Vec<Vec2> = Vec::with_capacity(n * 4);
        for i in 0..n {
            let (a, b) = (&vertices[i], &vertices[(i + 1) % n]);
            out.push(a.point);
            if a.out_tangent == Vec2::ZERO && b.in_tangent == Vec2::ZERO {
                continue;
            }
            let p0 = a.point;
            let p1 = a.point + a.out_tangent;
            let p2 = b.point + b.in_tangent;
            let p3 = b.point;
            for s in 1..CURVE_SUBDIVISIONS {
                let t = s as f64 / CURVE_SUBDIVISIONS as f64;
                let u = 1.0 - t;
                let w0: f64 = u * u * u;
                let w1: f64 = 3.0 * u * u * t;
                let w2: f64 = 3.0 * u * t * t;
                let w3: f64 = t * t * t;
                let x: f64 = p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3;
                let y: f64 = p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3;
                out.push(Vec2::new(x, y));
            }
        }
        if out.len() > MAX_POLYGON_POINTS {
            let step = out.len() as f64 / MAX_POLYGON_POINTS as f64;
            out = (0..MAX_POLYGON_POINTS).map(|i| out[(i as f64 * step) as usize]).collect();
        }
        out
    }

    fn move_vertex(&mut self, i: usize, to: Vec2) {
        if let Some(v) = self.vertices.get_mut(i) {
            v.point = to;
        }
    }

    fn translated(&self, d: Vec2) -> MaskPath {
        MaskPath {
            vertices: self
                .vertices
                .iter()
                .map(|v| {
                    let mut v = *v;
                    v.point = v.point + d;
                    v
                })
                .collect(),
        }
    }

    fn vertex_index_near(&self, p: Vec2, frame: Vec2, radius: f64) -> Option<usize> {
        let mut best: Option<(usize, f64)> = None;
        for (i, v) in self.vertices.iter().enumerate() {
            let q = Vec2::new(v.point.x * frame.x, v.point.y * frame.y);
            let d = (q - p).length();
            if d <= radius && d < best.map_or(f64::INFINITY, |b| b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| b.0)
    }
}

/// Logic Swift keeps on `ColorRangeKey`.
pub trait ColorRangeKeyExt {
    /// The mask value 0...1 of one display-encoded pixel: distance to the picked color against tolerance and softness.
    fn value(&self, red: f64, green: f64, blue: f64) -> f64;
}

impl ColorRangeKeyExt for ColorRangeKey {
    fn value(&self, r: f64, g: f64, b: f64) -> f64 {
        let (dr, dg, db) = (r - self.red, g - self.green, b - self.blue);
        let d = (dr * dr + dg * dg + db * db).sqrt() / 3.0_f64.sqrt();
        if self.softness <= 1e-6 {
            return if d <= self.tolerance { 1.0 } else { 0.0 };
        }
        let x = ((d - self.tolerance) / self.softness).clamp(0.0, 1.0);
        1.0 - x * x * (3.0 - 2.0 * x)
    }
}

/// One mask at one instant, what the renderer draws. `polygon` in frame fractions; `feather` / `expansion` in px of the
/// clip's own frame; `opacity` 0...1.
#[derive(Clone, Debug, PartialEq)]
pub struct MaskShape {
    /// The flattened path.
    pub polygon: Vec<Vec2>,
    /// Soft edge width in px.
    pub feather: f64,
    /// Grow (positive) or shrink, px.
    pub expansion: f64,
    /// 0...1.
    pub opacity: f64,
    /// The coverage is turned around.
    pub inverted: bool,
    /// How it combines with the masks above.
    pub mode: MaskMode,
    /// `Subject`: the coverage is the layer's subject matte (`SubjectMatte`), the polygon is ignored.
    pub source: MaskSource,
    /// `Magic`: the key of its matte in `RenderLayer.mattes` (the mask's id).
    pub matte_key: Option<Id>,
    /// `Magic`: where the tracked mattes it draws are cached (`MagicSelection::matte_key`); set by the clip.
    pub matte_cache_key: Option<String>,
    /// `Magic`, Anonymize Face / Skin: where the followed whole person is cached (what covers when the narrowed matte of
    /// a frame is missing).
    pub matte_base_key: Option<String>,
    /// `Magic`, made by Anonymize: a frame without a matte is covered by estimate, never left open.
    pub matte_must_cover: bool,
    /// `Picture`: the track whose layers (`LayerRequest.matteFor` == this id, same `groups`) make the matte; `None` =
    /// covers nothing.
    pub picture_track: Option<Id>,
    /// `Picture`: what of that picture is read.
    pub picture_channel: MatteChannel,
    /// `ColorRange`: the key; the coverage is `ColorRangeKeyExt::value` of the picture's own pixel.
    pub color_range: ColorRangeKey,
}

impl MaskShape {
    /// A shape with Swift's defaults: no edge, full opacity, Add, from the path.
    pub fn new(polygon: Vec<Vec2>) -> MaskShape {
        MaskShape {
            polygon,
            feather: 0.0,
            expansion: 0.0,
            opacity: 1.0,
            inverted: false,
            mode: MaskMode::Add,
            source: MaskSource::Path,
            matte_key: None,
            matte_cache_key: None,
            matte_base_key: None,
            matte_must_cover: false,
            picture_track: None,
            picture_channel: MatteChannel::Shape,
            color_range: ColorRangeKey::DEFAULT,
        }
    }
}

/// Reads the Picture matte value at clip px `p` for a mask (see `CoverageInputs::picture`).
pub type PictureSampler<'a> = &'a dyn Fn(&MaskShape, Vec2) -> Option<f64>;
/// Reads the display-encoded color at clip px `p` (see `CoverageInputs::color`).
pub type ColorSampler<'a> = &'a dyn Fn(Vec2) -> Option<(f64, f64, f64)>;

/// Inputs of `MaskCoverage::coverage` besides the shapes; the default has no mattes and no picture.
#[derive(Default)]
pub struct CoverageInputs<'a> {
    /// The subject matte of a `Subject` mask.
    pub matte: Option<&'a SubjectMatte>,
    /// The mattes of `Magic` masks by their `matte_key`.
    pub mattes: Option<&'a BTreeMap<Id, SubjectMatte>>,
    /// C6 Picture masks: the matte value (already through `picture_channel`) at clip px `p`; `None` = no matte there:
    /// covers nothing.
    pub picture: Option<PictureSampler<'a>>,
    /// Color range masks: the picture's display-encoded straight color `(r, g, b)` at clip px `p`; `None` = no picture
    /// there: covers nothing.
    pub color: Option<ColorSampler<'a>>,
}

/// CPU reference of the mask maths in the compositor's fragment shader (`maskCoverage`). Same steps, in `f64`.
pub struct MaskCoverage;

impl MaskCoverage {
    /// The Opacity masks a layer draws with: a Magic mask without a usable matte on this frame (not tracked here, picked
    /// on another frame, or a blank matte) is left out, so it never cuts the whole picture to black. Effect inputs keep
    /// it (there "no matte" only means the effect applies nowhere).
    pub fn opacity_masks(masks: &[MaskShape], mattes: &BTreeMap<Id, SubjectMatte>) -> Vec<MaskShape> {
        if !masks.iter().any(|m| m.source == MaskSource::Magic) {
            return masks.to_vec();
        }
        masks
            .iter()
            .filter(|m| {
                if m.source != MaskSource::Magic {
                    return true;
                }
                let Some(x) = m.matte_key.and_then(|k| mattes.get(&k)) else { return false };
                !x.is_blank()
            })
            .cloned()
            .collect()
    }

    /// Signed distance (px, negative inside, even-odd rule) of `p` to the polygon `poly` (already in px).
    pub fn signed_distance(p: Vec2, poly: &[Vec2]) -> f64 {
        if poly.len() < 2 {
            return f64::INFINITY;
        }
        let mut d2 = f64::INFINITY;
        let mut inside = false;
        let mut j = poly.len() - 1;
        for i in 0..poly.len() {
            let (a, b) = (poly[j], poly[i]);
            let e = b - a;
            let w = p - a;
            let ee = e.x * e.x + e.y * e.y;
            let t = if ee > 0.0 { ((w.x * e.x + w.y * e.y) / ee).clamp(0.0, 1.0) } else { 0.0 };
            let q = w - e * t;
            d2 = d2.min(q.x * q.x + q.y * q.y);
            if (b.y > p.y) != (a.y > p.y) && p.x < (a.x - b.x) * (p.y - b.y) / (a.y - b.y) + b.x {
                inside = !inside;
            }
            j = i;
        }
        let d = d2.sqrt();
        if inside { -d } else { d }
    }

    /// One mask's own value 0...1 at signed distance `d0` (px): expansion, feather (smoothstep across the edge) or a
    /// one-pixel edge ramp when the feather is narrower than `pixel` (frame px per output px), then invert and opacity.
    pub fn value(d0: f64, m: &MaskShape, pixel: f64) -> f64 {
        let d = d0 - m.expansion;
        let mut c: f64;
        if m.feather > pixel {
            let h = m.feather / 2.0;
            let x = ((d + h) / (2.0 * h)).clamp(0.0, 1.0);
            c = 1.0 - x * x * (3.0 - 2.0 * x);
        } else {
            c = (0.5 - d / pixel.max(1e-9)).clamp(0.0, 1.0);
        }
        if m.inverted {
            c = 1.0 - c;
        }
        c * m.opacity
    }

    /// The running coverage starts at 1 (whole frame) when the first mask is of this mode, else at 0.
    pub fn starts_from_full_frame(mode: MaskMode) -> bool {
        mode == MaskMode::Subtract || mode == MaskMode::Intersect
    }

    /// Combines one mask into the running coverage.
    pub fn combine(acc: f64, v: f64, mode: MaskMode) -> f64 {
        match mode {
            MaskMode::Add => (acc + v).min(1.0),
            MaskMode::Subtract => (acc - v).max(0.0),
            MaskMode::Intersect => acc * v,
            MaskMode::Difference => (acc - v).abs(),
        }
    }

    /// Coverage at `p` (px of the clip's frame, origin top left) of `masks` on a frame of `frame` px. The running value
    /// starts at 0, or at 1 (the whole frame) when the first mask subtracts or intersects, as in After Effects: a first
    /// Intersect shows its own area. A first Difference starts from 0, so it shows its own area like Add. No masks = 1
    /// (nothing cut). A subject mask reads `inputs.matte` (no matte = no person anywhere, so the clip never flashes in
    /// full). Magic masks read `inputs.mattes[matte_key]` the same way. Picture and Color range masks read
    /// `inputs.picture` / `inputs.color`.
    pub fn coverage(p: Vec2, masks: &[MaskShape], frame: Vec2, pixel: f64, inputs: &CoverageInputs) -> f64 {
        let Some(first) = masks.first() else { return 1.0 };
        let mut acc: f64 = if Self::starts_from_full_frame(first.mode) { 1.0 } else { 0.0 };
        for m in masks {
            let v: f64 = if m.source == MaskSource::Picture {
                let sample =
                    if m.picture_track.is_none() { 0.0 } else { inputs.picture.and_then(|f| f(m, p)).unwrap_or(0.0) };
                Self::subject_value(sample, m)
            } else if m.source == MaskSource::ColorRange {
                let sample = inputs.color.and_then(|f| f(p)).map_or(0.0, |(r, g, b)| m.color_range.value(r, g, b));
                Self::subject_value(sample, m)
            } else if m.source.uses_matte() {
                let mt = if m.source == MaskSource::Magic {
                    m.matte_key.and_then(|k| inputs.mattes.and_then(|all| all.get(&k)))
                } else {
                    inputs.matte
                };
                Self::subject_value(mt.map_or(0.0, |x| Self::subject_sample(x, p.x / frame.x, p.y / frame.y)), m)
            } else {
                let poly: Vec<Vec2> = m.polygon.iter().map(|q| Vec2::new(q.x * frame.x, q.y * frame.y)).collect();
                Self::value(Self::signed_distance(p, &poly), m, pixel)
            };
            acc = Self::combine(acc, v, m.mode);
        }
        acc
    }

    /// The matte at frame fractions `(u, v)`: bilinear inside the clip's frame, 0 outside it (a blur-padded layer reaches
    /// past the frame; a person cut by the frame edge does not continue there).
    pub fn subject_sample(matte: &SubjectMatte, u: f64, v: f64) -> f64 {
        if !((0.0..=1.0).contains(&u) && (0.0..=1.0).contains(&v)) {
            return 0.0;
        }
        matte.sample(u, v)
    }

    /// A subject mask's own value from the matte sample: invert, then opacity.
    pub fn subject_value(sample: f64, m: &MaskShape) -> f64 {
        let mut c = sample.clamp(0.0, 1.0);
        if m.inverted {
            c = 1.0 - c;
        }
        c * m.opacity
    }
}

/// Logic Swift keeps on `ClipMask`.
pub trait ClipMaskExt {
    fn shape_at_local(&self, t: Time) -> MaskShape;
    /// Times of the mask's keys.
    fn key_times(&self) -> Vec<Time>;
    /// Key times through `f` (a retime).
    #[doc(hidden)]
    fn remapped(&self, f: &dyn Fn(Time) -> Time) -> ClipMask;
    /// Key times moved by `d`.
    #[doc(hidden)]
    fn shifted(&self, d: Time) -> ClipMask;
    /// Every value frozen at clip-local `t`.
    #[doc(hidden)]
    fn frozen(&self, t: Time) -> ClipMask;
}

impl ClipMaskExt for ClipMask {
    fn shape_at_local(&self, t: Time) -> MaskShape {
        let source = self.source();
        let picture = source == MaskSource::Picture;
        let mut s = MaskShape::new(if source == MaskSource::Magic || picture {
            Vec::new()
        } else {
            self.path.value_at_local(t).polygon()
        });
        s.feather = if picture { 0.0 } else { self.feather.value_at_local(t).max(0.0) };
        s.expansion = if picture { 0.0 } else { self.expansion.value_at_local(t) };
        s.opacity = (self.opacity.value_at_local(t) / 100.0).clamp(0.0, 1.0);
        s.inverted = self.inverted;
        s.mode = self.mode;
        s.source = source;
        s.matte_key = if source == MaskSource::Magic { Some(self.id) } else { None };
        if picture {
            s.picture_track = self.picture_track;
            s.picture_channel = self.picture_channel();
        }
        if source == MaskSource::ColorRange {
            s.color_range = self.color_range();
            s.feather = 0.0;
            s.expansion = 0.0;
        }
        s
    }

    fn key_times(&self) -> Vec<Time> {
        let mut out: Vec<Time> = self.path.track.keys.iter().map(|k| k.time).collect();
        out.extend(self.feather.track.keys.iter().map(|k| k.time));
        out.extend(self.opacity.track.keys.iter().map(|k| k.time));
        out.extend(self.expansion.track.keys.iter().map(|k| k.time));
        out
    }

    fn remapped(&self, f: &dyn Fn(Time) -> Time) -> ClipMask {
        let mut m = self.clone();
        m.path = self.path.remapped(f);
        m.feather = self.feather.remapped(f);
        m.opacity = self.opacity.remapped(f);
        m.expansion = self.expansion.remapped(f);
        m
    }

    fn shifted(&self, d: Time) -> ClipMask {
        let mut m = self.clone();
        m.path = self.path.shifted(d);
        m.feather = self.feather.shifted(d);
        m.opacity = self.opacity.shifted(d);
        m.expansion = self.expansion.shifted(d);
        m
    }

    fn frozen(&self, t: Time) -> ClipMask {
        let mut m = self.clone();
        m.path = AnimatedProperty::new(self.path.value_at_local(t));
        m.feather = AnimatedProperty::new(self.feather.value_at_local(t));
        m.opacity = AnimatedProperty::new(self.opacity.value_at_local(t));
        m.expansion = AnimatedProperty::new(self.expansion.value_at_local(t));
        m
    }
}

/// Logic Swift keeps on `Clip` in `Masks.swift`.
pub trait ClipMasksExt {
    /// Masks on the picture, top first.
    fn masks(&self) -> &[ClipMask];
    /// Replaces the masks; an empty list stores nothing.
    fn set_masks(&mut self, masks: Vec<ClipMask>);
    /// Enabled masks at clip-local `t`; none while the Opacity section is switched off.
    fn mask_shapes_at_local(&self, t: Time) -> Vec<MaskShape>;
    /// One mask's shape at `t`, a Magic mask with its matte cache key (needs the clip's media).
    #[doc(hidden)]
    fn mask_shape(&self, m: &ClipMask, t: Time) -> MaskShape;
    /// Key times of every mask through `f` (a retime).
    #[doc(hidden)]
    fn remap_mask_keys(&mut self, f: &dyn Fn(Time) -> Time);
    /// Every mask frozen at clip-local `t`.
    #[doc(hidden)]
    fn freeze_masks(&mut self, t: Time);
    /// The mask with `id`.
    fn mask(&self, id: Id) -> Option<&ClipMask>;
    /// Edits the mask `id` in place; its id cannot change.
    fn update_mask(&mut self, id: Id, body: impl FnOnce(&mut ClipMask));
    /// Name for a new mask: "Mask (n)" with the next free number.
    fn next_mask_name(&self) -> String;
    /// Writes the path at clip-local `t`: a key there when the path is animated, else the static value.
    fn set_mask_path(&mut self, id: Id, path: MaskPath, t: Time, ids: &mut dyn IdSource);
    /// Key button of an animated mask path: removes the key at `t`, or adds one with the shape shown there. Removing the
    /// last key keeps that shape as the static value. Does nothing while the path is not animated.
    fn toggle_mask_path_key(&mut self, id: Id, t: Time, ids: &mut dyn IdSource);
    /// Stopwatch of the mask path: on adds a key with the current shape at `t`; off keeps the shape at `t` as the static
    /// value.
    fn set_mask_path_animated(&mut self, id: Id, on: bool, t: Time, ids: &mut dyn IdSource);
}

impl ClipMasksExt for Clip {
    fn masks(&self) -> &[ClipMask] {
        self.mask_store.as_deref().unwrap_or(&[])
    }

    fn set_masks(&mut self, masks: Vec<ClipMask>) {
        self.mask_store = if masks.is_empty() { None } else { Some(masks) };
    }

    fn mask_shapes_at_local(&self, t: Time) -> Vec<MaskShape> {
        let Some(m) = &self.mask_store else { return Vec::new() };
        if !self.opacity_enabled {
            return Vec::new();
        }
        m.iter()
            .filter(|m| m.enabled && m.used_by_opacity())
            .map(|m| self.mask_shape(m, t))
            .filter(|s| s.polygon.len() >= 2 || s.source.uses_matte())
            .collect()
    }

    fn mask_shape(&self, m: &ClipMask, t: Time) -> MaskShape {
        let mut s = m.shape_at_local(t);
        if m.source() == MaskSource::Magic {
            let sel = m.magic.clone().unwrap_or_default();
            s.matte_cache_key = Some(sel.matte_key(self.media));
            if sel.part_key(self.media).is_some() {
                s.matte_base_key = Some(sel.cache_key(self.media));
            }
            s.matte_must_cover = sel.must_cover(); // a pick that lost its points too: then the whole frame
        }
        s
    }

    fn remap_mask_keys(&mut self, f: &dyn Fn(Time) -> Time) {
        if let Some(m) = &self.mask_store {
            self.mask_store = Some(m.iter().map(|m| m.remapped(f)).collect());
        }
    }

    fn freeze_masks(&mut self, t: Time) {
        if let Some(m) = &self.mask_store {
            self.mask_store = Some(m.iter().map(|m| m.frozen(t)).collect());
        }
    }

    fn mask(&self, id: Id) -> Option<&ClipMask> {
        self.masks().iter().find(|m| m.id == id)
    }

    fn update_mask(&mut self, id: Id, body: impl FnOnce(&mut ClipMask)) {
        let Some(list) = &mut self.mask_store else { return };
        let Some(m) = list.iter_mut().find(|m| m.id == id) else { return };
        let keep = m.id;
        body(m);
        m.id = keep;
    }

    fn next_mask_name(&self) -> String {
        let masks = self.masks();
        let mut n = masks.len() + 1;
        while masks.iter().any(|m| m.name == format!("Mask ({n})")) {
            n += 1;
        }
        format!("Mask ({n})")
    }

    fn set_mask_path(&mut self, id: Id, path: MaskPath, t: Time, ids: &mut dyn IdSource) {
        self.update_mask(id, |m| {
            if m.path.is_animated() {
                if let Some(k) = m.path.track.keys.iter().find(|k| k.time == t) {
                    let kid = k.id;
                    m.path.track.set(kid, path);
                } else {
                    m.path.track.insert(Keyframe::new(ids.next_id(), t, path));
                }
            } else {
                m.path.value = path;
            }
        });
    }

    fn toggle_mask_path_key(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) {
        self.update_mask(id, |m| {
            if !m.path.is_animated() {
                return;
            }
            if let Some(k) = m.path.track.keys.iter().find(|k| k.time == t) {
                let kid = k.id;
                let shown = m.path.value_at_local(t);
                m.path.track.remove(kid);
                if m.path.track.is_empty() {
                    m.path.value = shown;
                }
            } else {
                m.path.track.insert(Keyframe::new(ids.next_id(), t, m.path.value_at_local(t)));
            }
        });
    }

    fn set_mask_path_animated(&mut self, id: Id, on: bool, t: Time, ids: &mut dyn IdSource) {
        self.update_mask(id, |m| {
            let v = m.path.value_at_local(t);
            if on {
                if m.path.is_animated() {
                    return;
                }
                m.path.track.insert(Keyframe::new(ids.next_id(), t, v));
            } else {
                m.path = AnimatedProperty::new(v);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::{keys, test_clip, test_mask};
    use sq_core_time::{KeyframeValue, SequentialIds};

    fn rect(a: (f64, f64), b: (f64, f64)) -> MaskPath {
        MaskPath::rectangle(Vec2::new(a.0, a.1), Vec2::new(b.0, b.1))
    }
    fn ellipse(c: (f64, f64), r: (f64, f64)) -> MaskPath {
        MaskPath::ellipse(Vec2::new(c.0, c.1), Vec2::new(r.0, r.1))
    }
    fn t(n: i64) -> Time {
        Time::new(n, 1)
    }

    #[test]
    fn rectangle_flattens_to_its_four_corners() {
        let p = rect((0.25, 0.25), (0.75, 0.5));
        assert_eq!(p.vertices.len(), 4);
        let want = [Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.25), Vec2::new(0.75, 0.5), Vec2::new(0.25, 0.5)];
        assert_eq!(p.polygon(), want);
    }

    #[test]
    fn ellipse_flattens_close_to_the_true_ellipse() {
        let p = ellipse((0.5, 0.5), (0.2, 0.1));
        assert_eq!(p.vertices.len(), 4);
        let poly = p.polygon();
        assert_eq!(poly.len(), 4 * CURVE_SUBDIVISIONS);
        for v in poly {
            let e = ((v.x - 0.5) / 0.2) * ((v.x - 0.5) / 0.2) + ((v.y - 0.5) / 0.1) * ((v.y - 0.5) / 0.1);
            assert!((e - 1.0).abs() < 0.003); // a 4-point bezier circle is within 0.03 % of the radius
        }
    }

    #[test]
    fn polygon_of_an_empty_path_is_empty() {
        assert!(MaskPath { vertices: vec![] }.polygon().is_empty());
    }

    #[test]
    fn path_keys_interpolate_vertex_by_vertex() {
        let mut m = test_mask(rect((0.0, 0.0), (0.5, 0.5)));
        m.path.track = keys(&[(Time::ZERO, rect((0.0, 0.0), (0.5, 0.5))), (t(2), rect((0.5, 0.5), (1.0, 1.0)))]);
        let mid = m.path.value_at_local(t(1));
        let want = [Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.25), Vec2::new(0.75, 0.75), Vec2::new(0.25, 0.75)];
        let got: Vec<Vec2> = mid.vertices.iter().map(|v| v.point).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn paths_with_different_vertex_counts_hold_until_the_next_key() {
        let a = rect((0.0, 0.0), (0.5, 0.5));
        let mut three = ellipse((0.5, 0.5), (0.1, 0.1));
        three.vertices.pop();
        assert_eq!(MaskPath::lerp(&a, &three, 0.5), a);
        assert_eq!(MaskPath::lerp(&a, &three, 1.0), three);
    }

    #[test]
    fn feather_opacity_and_expansion_are_keyframable() {
        let mut m = test_mask(rect((0.0, 0.0), (1.0, 1.0)));
        m.feather.track = keys(&[(Time::ZERO, 0.0), (t(2), 40.0)]);
        m.opacity.track = keys(&[(Time::ZERO, 100.0), (t(2), 0.0)]);
        m.expansion.track = keys(&[(Time::ZERO, -10.0), (t(2), 10.0)]);
        let s = m.shape_at_local(t(1));
        assert_eq!(s.feather, 20.0);
        assert_eq!(s.opacity, 0.5);
        assert_eq!(s.expansion, 0.0);
    }

    #[test]
    fn evaluated_values_are_clamped() {
        let mut m = test_mask(rect((0.0, 0.0), (1.0, 1.0)));
        m.feather = AnimatedProperty::new(-5.0);
        m.opacity = AnimatedProperty::new(140.0);
        let s = m.shape_at_local(Time::ZERO);
        assert_eq!(s.feather, 0.0);
        assert_eq!(s.opacity, 1.0);
    }

    fn shape(p: &MaskPath, feather: f64, expansion: f64, opacity: f64, inverted: bool, mode: MaskMode) -> MaskShape {
        let mut s = MaskShape::new(p.polygon());
        s.feather = feather;
        s.expansion = expansion;
        s.opacity = opacity;
        s.inverted = inverted;
        s.mode = mode;
        s
    }
    fn plain(p: &MaskPath) -> MaskShape {
        shape(p, 0.0, 0.0, 1.0, false, MaskMode::Add)
    }
    fn in_mode(p: &MaskPath, mode: MaskMode) -> MaskShape {
        shape(p, 0.0, 0.0, 1.0, false, mode)
    }
    fn cov(masks: &[MaskShape], x: f64, y: f64) -> f64 {
        MaskCoverage::coverage(Vec2::new(x, y), masks, Vec2::new(100.0, 100.0), 1.0, &CoverageInputs::default())
    }

    #[test]
    fn hard_edge_coverage_is_one_inside_zero_outside_half_on_the_edge() {
        let m = [plain(&rect((0.2, 0.2), (0.8, 0.8)))];
        assert_eq!(cov(&m, 50.0, 50.0), 1.0);
        assert_eq!(cov(&m, 5.0, 5.0), 0.0);
        assert!((cov(&m, 20.0, 50.0) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn feather_ramps_across_the_edge_centred_on_it() {
        let m = [shape(&rect((0.2, 0.2), (0.8, 0.8)), 20.0, 0.0, 1.0, false, MaskMode::Add)];
        assert!((cov(&m, 20.0, 50.0) - 0.5).abs() < 1e-9);
        assert_eq!(cov(&m, 31.0, 50.0), 1.0);
        assert_eq!(cov(&m, 9.0, 50.0), 0.0);
        let (a, b) = (cov(&m, 25.0, 50.0), cov(&m, 15.0, 50.0));
        assert!(a > 0.5 && a < 1.0 && b > 0.0 && b < 0.5);
        assert!((a + b - 1.0).abs() < 1e-9);
    }

    #[test]
    fn expansion_grows_and_shrinks_the_shape() {
        let r = rect((0.2, 0.2), (0.8, 0.8));
        let grown = shape(&r, 0.0, 10.0, 1.0, false, MaskMode::Add);
        let shrunk = shape(&r, 0.0, -10.0, 1.0, false, MaskMode::Add);
        assert_eq!(cov(&[grown], 12.0, 50.0), 1.0);
        assert_eq!(cov(&[shrunk], 28.0, 50.0), 0.0);
    }

    #[test]
    fn invert_and_opacity() {
        let r = rect((0.2, 0.2), (0.8, 0.8));
        let inv = shape(&r, 0.0, 0.0, 1.0, true, MaskMode::Add);
        let quarter = shape(&r, 0.0, 0.0, 0.25, false, MaskMode::Add);
        assert_eq!(cov(std::slice::from_ref(&inv), 50.0, 50.0), 0.0);
        assert_eq!(cov(&[inv], 5.0, 5.0), 1.0);
        assert_eq!(cov(&[quarter], 50.0, 50.0), 0.25);
    }

    #[test]
    fn modes_combine_in_order() {
        let big = rect((0.1, 0.1), (0.9, 0.9));
        let small = rect((0.4, 0.4), (0.6, 0.6));
        let left = rect((0.0, 0.0), (0.5, 1.0));
        let (s_big, s_small, s_left) = (plain(&big), plain(&small), plain(&left));
        let sub_small = in_mode(&small, MaskMode::Subtract);
        let inter_left = in_mode(&left, MaskMode::Intersect);
        let diff_left = in_mode(&left, MaskMode::Difference);
        assert_eq!(cov(&[s_small, s_left], 25.0, 50.0), 1.0);
        assert_eq!(cov(&[s_big.clone(), sub_small.clone()], 50.0, 50.0), 0.0);
        assert_eq!(cov(&[s_big.clone(), sub_small.clone()], 20.0, 50.0), 1.0);
        assert_eq!(cov(&[s_big.clone(), inter_left.clone()], 75.0, 50.0), 0.0);
        assert_eq!(cov(&[s_big.clone(), inter_left], 25.0, 50.0), 1.0);
        assert_eq!(cov(&[s_big.clone(), diff_left.clone()], 25.0, 50.0), 0.0);
        assert_eq!(cov(&[s_big, diff_left], 75.0, 50.0), 1.0);
        // A first Subtract mask starts from the whole frame (Premiere).
        assert_eq!(cov(std::slice::from_ref(&sub_small), 20.0, 50.0), 1.0);
        assert_eq!(cov(&[sub_small], 50.0, 50.0), 0.0);
    }

    #[test]
    fn first_intersect_starts_from_the_full_frame_and_first_difference_acts_like_add() {
        let small = rect((0.4, 0.4), (0.6, 0.6));
        let inter = in_mode(&small, MaskMode::Intersect);
        let diff = in_mode(&small, MaskMode::Difference);
        assert_eq!(cov(&[inter], 50.0, 50.0), 1.0);
        assert_eq!(cov(&[in_mode(&small, MaskMode::Intersect)], 20.0, 50.0), 0.0);
        assert_eq!(cov(std::slice::from_ref(&diff), 50.0, 50.0), 1.0);
        assert_eq!(cov(&[diff], 20.0, 50.0), 0.0);
        let half = shape(&small, 0.0, 0.0, 0.5, false, MaskMode::Intersect);
        assert_eq!(cov(&[half], 50.0, 50.0), 0.5);
    }

    #[test]
    fn animated_path_with_an_empty_static_value_still_renders() {
        let mut ids = SequentialIds::default();
        let mut m = test_mask(MaskPath { vertices: vec![] });
        m.path.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, rect((0.2, 0.2), (0.8, 0.8))));
        let mut c = test_clip();
        c.set_masks(vec![m]);
        assert_eq!(c.mask_shapes_at_local(t(1)).len(), 1);
        // And the other way round: a path that has fewer than two points at t is skipped.
        let mut e = test_mask(rect((0.2, 0.2), (0.8, 0.8)));
        e.path.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, MaskPath { vertices: vec![] }));
        let mut c = test_clip();
        c.set_masks(vec![e]);
        assert!(c.mask_shapes_at_local(t(1)).is_empty());
    }

    #[test]
    fn coverage_works_in_frame_pixels_for_non_square_frames() {
        let m = [plain(&ellipse((0.5, 0.5), (0.5, 0.5)))];
        let wide = Vec2::new(200.0, 100.0);
        let c = |x, y| MaskCoverage::coverage(Vec2::new(x, y), &m, wide, 1.0, &CoverageInputs::default());
        assert_eq!(c(190.0, 50.0), 1.0);
        assert_eq!(c(100.0, 3.0), 1.0);
        assert_eq!(c(195.0, 5.0), 0.0);
    }

    #[test]
    fn set_path_at_writes_a_key_only_when_animated() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        c.set_masks(vec![test_mask(rect((0.0, 0.0), (0.5, 0.5)))]);
        let id = c.masks()[0].id;
        let moved = rect((0.1, 0.1), (0.6, 0.6));
        c.set_mask_path(id, moved.clone(), t(1), &mut ids);
        assert_eq!(c.masks()[0].path.value, moved);
        assert!(!c.masks()[0].path.is_animated());
        c.set_mask_path_animated(id, true, t(1), &mut ids);
        let times = |c: &Clip| c.masks()[0].path.track.keys.iter().map(|k| k.time).collect::<Vec<_>>();
        assert_eq!(times(&c), vec![t(1)]);
        let again = rect((0.2, 0.2), (0.7, 0.7));
        c.set_mask_path(id, again.clone(), t(3), &mut ids);
        assert_eq!(times(&c), vec![t(1), t(3)]);
        assert_eq!(c.masks()[0].path.value_at_local(t(3)), again);
        c.set_mask_path_animated(id, false, t(3), &mut ids);
        assert!(!c.masks()[0].path.is_animated());
        assert_eq!(c.masks()[0].path.value, again);
    }

    #[test]
    fn toggle_mask_path_key_adds_then_removes_a_key_at_the_time() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        c.set_masks(vec![test_mask(rect((0.0, 0.0), (0.5, 0.5)))]);
        let id = c.masks()[0].id;
        let times = |c: &Clip| c.masks()[0].path.track.keys.iter().map(|k| k.time).collect::<Vec<_>>();
        c.toggle_mask_path_key(id, t(1), &mut ids); // not animated: nothing to toggle
        assert!(!c.masks()[0].path.is_animated());
        c.set_mask_path_animated(id, true, t(1), &mut ids);
        c.set_mask_path(id, rect((0.2, 0.2), (0.7, 0.7)), t(3), &mut ids);
        let shown_at_2 = c.masks()[0].path.value_at_local(t(2));
        c.toggle_mask_path_key(id, t(2), &mut ids); // adds a key with the shape shown there
        assert_eq!(times(&c), vec![t(1), t(2), t(3)]);
        assert_eq!(c.masks()[0].path.value_at_local(t(2)), shown_at_2);
        c.toggle_mask_path_key(id, t(2), &mut ids); // removes it again
        assert_eq!(times(&c), vec![t(1), t(3)]);
        c.toggle_mask_path_key(id, t(1), &mut ids);
        c.toggle_mask_path_key(id, t(3), &mut ids); // last key: the shape there stays as the static value
        assert!(!c.masks()[0].path.is_animated());
        assert_eq!(c.masks()[0].path.value, rect((0.2, 0.2), (0.7, 0.7)));
    }

    #[test]
    fn moving_a_vertex_moves_its_tangents_with_it() {
        let mut p = ellipse((0.5, 0.5), (0.2, 0.2));
        let before = p.vertices[1];
        let target = Vec2::new(before.point.x + 0.1, before.point.y);
        p.move_vertex(1, target);
        let after = p.vertices[1];
        assert_eq!(after.point, target);
        assert_eq!(after.in_tangent, before.in_tangent);
        assert_eq!(after.out_tangent, before.out_tangent);
    }

    #[test]
    fn nearest_vertex_hit_test_in_frame_pixels() {
        let p = rect((0.2, 0.2), (0.8, 0.8));
        let frame = Vec2::new(100.0, 100.0);
        assert_eq!(p.vertex_index_near(Vec2::new(21.0, 19.0), frame, 4.0), Some(0));
        assert_eq!(p.vertex_index_near(Vec2::new(50.0, 50.0), frame, 4.0), None);
    }

    #[test]
    fn subject_mask_reaches_the_renderer_without_polygon() {
        let mut ids = SequentialIds::default();
        let mut c = test_clip();
        let mut m = ClipMask::make_subject(ids.next_id(), "Subject");
        m.path.value = MaskPath { vertices: vec![] };
        c.set_masks(vec![m]);
        let shapes = c.mask_shapes_at_local(Time::ZERO);
        assert_eq!(shapes.len(), 1);
        assert_eq!(shapes[0].source, MaskSource::Subject);
    }

    #[test]
    fn subject_coverage_samples_the_matte() {
        let matte = SubjectMatte::new(2, 1, vec![0.0, 1.0]);
        let mut s = MaskShape::new(vec![]);
        s.source = MaskSource::Subject;
        let frame = Vec2::new(20.0, 10.0);
        let inputs = CoverageInputs { matte: Some(&matte), ..CoverageInputs::default() };
        let c = |m: &MaskShape, x: f64| {
            MaskCoverage::coverage(Vec2::new(x, 5.0), std::slice::from_ref(m), frame, 1.0, &inputs)
        };
        assert!(c(&s, 5.0).abs() < 1e-9);
        assert!((c(&s, 10.0) - 0.5).abs() < 1e-9);
        assert!((c(&s, 19.0) - 1.0).abs() < 1e-9);
        let mut inv = s.clone();
        inv.inverted = true;
        inv.opacity = 0.5;
        assert!((c(&inv, 5.0) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn subject_without_matte_shows_no_person() {
        let mut s = MaskShape::new(vec![]);
        s.source = MaskSource::Subject;
        let none = CoverageInputs::default();
        let at = |m: &[MaskShape]| MaskCoverage::coverage(Vec2::new(3.0, 3.0), m, Vec2::new(10.0, 10.0), 1.0, &none);
        assert_eq!(at(std::slice::from_ref(&s)), 0.0);
        let mut inv = s.clone();
        inv.inverted = true;
        inv.opacity = 0.5;
        assert_eq!(at(&[inv]), 0.5);
        let rect =
            MaskShape::new(vec![Vec2::new(0.0, 0.0), Vec2::new(1.0, 0.0), Vec2::new(1.0, 1.0), Vec2::new(0.0, 1.0)]);
        let mut sub = s;
        sub.mode = MaskMode::Subtract;
        assert_eq!(at(&[rect, sub]), 1.0);
    }

    #[test]
    fn matte_outside_the_frame_is_empty() {
        let matte = SubjectMatte::new(2, 2, vec![1.0; 4]);
        let mut s = MaskShape::new(vec![]);
        s.source = MaskSource::Subject;
        let frame = Vec2::new(20.0, 10.0);
        let inputs = CoverageInputs { matte: Some(&matte), ..CoverageInputs::default() };
        let c = |m: &MaskShape, x: f64, y: f64| {
            MaskCoverage::coverage(Vec2::new(x, y), std::slice::from_ref(m), frame, 1.0, &inputs)
        };
        assert_eq!(c(&s, 19.5, 5.0), 1.0);
        for (x, y) in [(-0.5, 5.0), (20.5, 5.0), (10.0, -0.5), (10.0, 10.5)] {
            assert_eq!(c(&s, x, y), 0.0, "{x},{y}");
        }
        let mut inv = s;
        inv.inverted = true;
        assert_eq!(c(&inv, -3.0, 5.0), 1.0);
    }

    #[test]
    fn untracked_or_blank_magic_masks_do_not_cut_the_picture() {
        let (a, b, c) = (Id::from_u128(1), Id::from_u128(2), Id::from_u128(3));
        let magic = |k| {
            let mut m = MaskShape::new(vec![]);
            m.source = MaskSource::Magic;
            m.matte_key = Some(k);
            m
        };
        let (magic_a, magic_b, magic_c) = (magic(a), magic(b), magic(c));
        let rect =
            MaskShape::new(vec![Vec2::new(0.0, 0.0), Vec2::new(0.5, 0.0), Vec2::new(0.5, 1.0), Vec2::new(0.0, 1.0)]);
        let mut subject = MaskShape::new(vec![]);
        subject.source = MaskSource::Subject;
        let half = |left: bool| {
            let mut v = vec![0.0_f32; 16];
            for y in 0..4 {
                for x in 0..4 {
                    v[y * 4 + x] = if left && x < 2 { 1.0 } else { 0.0 };
                }
            }
            SubjectMatte::new(4, 4, v)
        };
        let mut mattes = BTreeMap::new();
        mattes.insert(a, half(true));
        mattes.insert(b, half(false));
        let kept = MaskCoverage::opacity_masks(
            &[magic_a.clone(), magic_b.clone(), magic_c.clone(), rect.clone(), subject.clone()],
            &mattes,
        );
        assert_eq!(kept, vec![magic_a.clone(), rect, subject]);
        let frame = Vec2::new(100.0, 100.0);
        let inputs = CoverageInputs { mattes: Some(&mattes), ..CoverageInputs::default() };
        let at = |m: &[MaskShape], x: f64| MaskCoverage::coverage(Vec2::new(x, 50.0), m, frame, 1.0, &inputs);
        let alone = MaskCoverage::opacity_masks(&[magic_c], &mattes);
        assert_eq!(at(&alone, 75.0), 1.0);
        let blank = MaskCoverage::opacity_masks(&[magic_b], &mattes);
        assert_eq!(at(&blank, 75.0), 1.0);
        let tracked = MaskCoverage::opacity_masks(&[magic_a], &mattes);
        assert_eq!(at(&tracked, 75.0), 0.0);
        assert_eq!(at(&tracked, 25.0), 1.0);
    }

    #[test]
    fn color_range_and_picture_masks_read_their_callbacks() {
        let mut m = MaskShape::new(vec![]);
        m.source = MaskSource::ColorRange;
        m.color_range = ColorRangeKey::new(0.0, 1.0, 0.0, 0.1, 0.0);
        let green = |_: Vec2| Some((0.0, 1.0, 0.0));
        let red = |_: Vec2| Some((1.0, 0.0, 0.0));
        let frame = Vec2::new(10.0, 10.0);
        let with = |f: &dyn Fn(Vec2) -> Option<(f64, f64, f64)>| {
            let inputs = CoverageInputs { color: Some(f), ..CoverageInputs::default() };
            MaskCoverage::coverage(Vec2::new(5.0, 5.0), std::slice::from_ref(&m), frame, 1.0, &inputs)
        };
        assert_eq!(with(&green), 1.0);
        assert_eq!(with(&red), 0.0);
        let mut p = MaskShape::new(vec![]);
        p.source = MaskSource::Picture;
        p.picture_track = Some(Id::from_u128(9));
        let pic = |_: &MaskShape, _: Vec2| Some(0.75);
        let inputs = CoverageInputs { picture: Some(&pic), ..CoverageInputs::default() };
        assert_eq!(MaskCoverage::coverage(Vec2::new(5.0, 5.0), std::slice::from_ref(&p), frame, 1.0, &inputs), 0.75);
    }
}
