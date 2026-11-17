// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: VisibleSourceRegion.swift
//! Playback perf: which part of a layer's source texture lands on the canvas, and at what size the color stage and the
//! effect passes of a layer run (docs/PLAYBACK-PERF.md). Pure geometry on the layer transform.
//! Not here until their types exist (NOTES-effects.md): `isPointwise` (needs the color pipeline) and
//! `averagesBeforeGrading` (needs the source color space).

use super::simd::Float2;
use sq_core_model::ClipTransform;

/// A pixel rectangle of a source texture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceRegion {
    /// Left.
    pub x: i64,
    /// Top.
    pub y: i64,
    /// Width.
    pub width: i64,
    /// Height.
    pub height: i64,
}

/// A layer on the canvas: where its source texture lands.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SourceGeometry {
    /// The canvas size.
    pub canvas: Float2,
    /// The layer's evaluated transform.
    pub transform: ClipTransform,
    /// The layer's own size (before the transform).
    pub size: Float2,
    /// The source texture size `(width, height)`.
    pub texture: (i64, i64),
    /// Quarter turns of the stored texture (0...3).
    pub quarter: u32,
}

/// Where a frame layer's convert + color passes run: an intermediate of `width` x `height` (the source size, or half of it)
/// and the region of it to process (`None`: nothing of the layer is on the canvas).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ColorWork {
    /// Intermediate width.
    pub width: i64,
    /// Intermediate height.
    pub height: i64,
    /// The region to process.
    pub region: Option<SourceRegion>,
}

/// Above this many canvas px per texel the display-size grade saves too little to be worth the resample.
pub const DISPLAY_GRADE_MAX_SHOWN: f64 = 0.9;

/// The part of a layer's source texture that lands on the canvas. Inverts the composite vertex mapping
/// `canvas/2 + position + R((local - anchor) * scale)`, `uv = local / size + 0.5`, then the quarter turn of the fragment
/// shader. `canvas_pad`: canvas px added around the canvas first (edge antialiasing grows the quad by 1 screen px); `pad`:
/// texture px added around the result (the bilinear footprint). `None` when nothing of the layer is on the canvas.
pub fn visible_source_region(g: &SourceGeometry, pad: i64, canvas_pad: f32) -> Option<SourceRegion> {
    let t = &g.transform;
    let sx = t.scale.x.max(0.0) as f32;
    let sy = t.scale.y.max(0.0) as f32;
    let (tex_w, tex_h) = g.texture;
    if !(sx > 1e-6 && sy > 1e-6 && g.size.x > 0.0 && g.size.y > 0.0 && tex_w > 0 && tex_h > 0) {
        return None;
    }
    // shortcut: a tilted layer keeps its whole texture (the perspective inverse is not folded in here); upgrade when a
    // large tilted clip needs the region trim.
    if t.is_tilted() {
        return Some(SourceRegion { x: 0, y: 0, width: tex_w, height: tex_h });
    }
    let r = t.rotation * std::f64::consts::PI / 180.0;
    let c = r.cos() as f32;
    let s = r.sin() as f32;
    let pos = Float2::new(t.position.x as f32, t.position.y as f32);
    let anchor = Float2::new(t.anchor.x as f32, t.anchor.y as f32);
    let canvas = g.canvas;
    let mut lo = Float2::splat(f32::INFINITY);
    let mut hi = Float2::splat(f32::NEG_INFINITY);
    let corners = [
        Float2::new(-canvas_pad, -canvas_pad),
        Float2::new(canvas.x + canvas_pad, -canvas_pad),
        Float2::new(-canvas_pad, canvas.y + canvas_pad),
        Float2::new(canvas.x + canvas_pad, canvas.y + canvas_pad),
    ];
    for corner in corners {
        let q = corner - canvas * 0.5 - pos;
        let p = Float2::new(c * q.x + s * q.y, -s * q.x + c * q.y); // R^-1
        let mut uv = (p / Float2::new(sx, sy) + anchor) / g.size + 0.5;
        uv = match g.quarter {
            // upright uv -> stored texture uv
            1 => Float2::new(uv.y, 1.0 - uv.x),
            2 => Float2::new(1.0 - uv.x, 1.0 - uv.y),
            3 => Float2::new(1.0 - uv.y, uv.x),
            _ => uv,
        };
        lo = lo.min(uv);
        hi = hi.max(uv);
    }
    let tw = tex_w as f32;
    let th = tex_h as f32;
    // Snap away float noise (cos 90 degrees is not 0) before rounding outwards.
    let eps = 1e-3f32;
    let x0 = (lo.x * tw + eps).floor() as i64 - pad;
    let y0 = (lo.y * th + eps).floor() as i64 - pad;
    let x1 = (hi.x * tw - eps).ceil() as i64 + pad;
    let y1 = (hi.y * th - eps).ceil() as i64 + pad;
    let (cx0, cy0, cx1, cy1) = (x0.max(0), y0.max(0), x1.min(tex_w), y1.min(tex_h));
    if cx1 > cx0 && cy1 > cy0 {
        Some(SourceRegion { x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0 })
    } else {
        None
    }
}

/// The one half-size test of `color_work` and `effect_work_factor` (f64, on the transform's own values, so the color stage
/// and the effect chain flip at the same frame of a keyframed scale): at most one canvas px per 2 x 2 texels.
/// `texels_per_native_pixel` < 1 for a reduced proxy (its texel already covers several layer px).
pub fn shown_at_half_or_less(t: &ClipTransform, texels_per_native_pixel: f64) -> bool {
    if t.is_tilted() {
        return false; // the near edge of a tilted layer is shown larger than its scale
    }
    let shown = t.scale.x.max(t.scale.y);
    shown > 0.0 && shown * 2.0 <= texels_per_native_pixel
}

/// Playback perf: half resolution when the canvas shows at most one pixel per 2 x 2 source texels (a 4K clip at 50 % or
/// less): the 2 x 2 box the draw would average anyway is averaged first, then graded. Only the visible region when the layer
/// is drawn in one pass (a blur, shadow or filter pass reads beyond it). Also half resolution under a strong blur at any
/// scale (`strong_blur`). `halves` false: the source curve does not allow the 2 x 2 average before grading.
pub fn color_work(
    g: &SourceGeometry,
    texels_per_native_pixel: f32,
    one_pass: bool,
    strong_blur: bool,
    halves: bool,
) -> ColorWork {
    let tpn = f64::from(texels_per_native_pixel);
    let fine = shown_at_half_or_less(&g.transform, tpn) || (strong_blur && tpn >= 1.0);
    let (tw, th) = g.texture;
    let half = halves && fine && tw >= 64 && th >= 64;
    let (w, h) = if half { ((tw + 1) / 2, (th + 1) / 2) } else { (tw, th) };
    if !one_pass {
        return ColorWork { width: w, height: h, region: Some(SourceRegion { x: 0, y: 0, width: w, height: h }) };
    }
    let reduced = SourceGeometry { texture: (w, h), ..*g };
    ColorWork { width: w, height: h, region: visible_source_region(&reduced, 2, 2.0) }
}

/// Playback perf: the size the effect passes (blur, shadow, filters) of a layer run at, as 1/factor of the layer. 2 when the
/// layer is shown at half size or less on both axes; 1 otherwise. Depends only on the transform, so export renders the same.
pub fn effect_work_factor(t: &ClipTransform, size: Float2) -> i64 {
    if shown_at_half_or_less(t, 1.0) && size.x.min(size.y) >= 128.0 { 2 } else { 1 }
}

/// Preview (`gradesAtDisplaySize`): where a pointwise layer's convert + grade run when it is graded at the size it is shown:
/// the texture scaled by the canvas px per texel (rounded up), only its visible region. `None` when the layer is shown at
/// (nearly) its texture size or larger: the normal path runs.
pub fn display_color_work(g: &SourceGeometry, texels_per_native_pixel: f32, halves: bool) -> Option<ColorWork> {
    if !halves {
        return None;
    }
    let tpn = f64::from(texels_per_native_pixel);
    if tpn <= 0.0 {
        return None;
    }
    let shown = g.transform.scale.x.max(g.transform.scale.y) / tpn;
    if !(shown > 0.0 && shown <= DISPLAY_GRADE_MAX_SHOWN) {
        return None;
    }
    let w = ((g.texture.0 as f64 * shown).ceil() as i64).max(1);
    let h = ((g.texture.1 as f64 * shown).ceil() as i64).max(1);
    let reduced = SourceGeometry { texture: (w, h), ..*g };
    Some(ColorWork { width: w, height: h, region: visible_source_region(&reduced, 2, 2.0) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Vec2;

    fn geometry(
        canvas: (i64, i64),
        t: ClipTransform,
        size: (i64, i64),
        texture: (i64, i64),
        quarter: u32,
    ) -> SourceGeometry {
        SourceGeometry {
            canvas: Float2::new(canvas.0 as f32, canvas.1 as f32),
            transform: t,
            size: Float2::new(size.0 as f32, size.1 as f32),
            texture,
            quarter,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn region(
        canvas: (i64, i64),
        position: Vec2,
        scale: f64,
        rotation: f64,
        size: (i64, i64),
        texture: (i64, i64),
        quarter: u32,
        pad: i64,
    ) -> Option<SourceRegion> {
        let mut t = ClipTransform::IDENTITY;
        t.position = position;
        t.scale = Vec2::new(scale, scale);
        t.rotation = rotation;
        visible_source_region(&geometry(canvas, t, size, texture, quarter), pad, 0.0)
    }

    fn r(x: i64, y: i64, width: i64, height: i64) -> Option<SourceRegion> {
        Some(SourceRegion { x, y, width, height })
    }

    #[test]
    fn wide_source_in_tall_canvas_keeps_only_the_middle() {
        // 3840x2160 at 100 % in a 1080x1920 canvas: the middle 1080 columns, all rows that fit (1920 of 2160).
        assert_eq!(
            region((1080, 1920), Vec2::ZERO, 1.0, 0.0, (3840, 2160), (3840, 2160), 0, 0),
            r(1380, 120, 1080, 1920)
        );
    }

    #[test]
    fn pad_is_clamped_to_the_texture() {
        assert_eq!(
            region((1080, 1920), Vec2::ZERO, 1.0, 0.0, (3840, 2160), (3840, 2160), 0, 4),
            r(1376, 116, 1088, 1928)
        );
        assert_eq!(region((1920, 1080), Vec2::ZERO, 1.0, 0.0, (1920, 1080), (1920, 1080), 0, 4), r(0, 0, 1920, 1080));
    }

    #[test]
    fn position_scale_and_rotation_move_the_region() {
        let moved = region((1080, 1920), Vec2::new(100.0, 0.0), 2.0, 0.0, (3840, 2160), (3840, 2160), 0, 0);
        assert_eq!(moved, r(1920 - 270 - 50, 1080 - 480, 540, 960));
        let turned = region((1080, 1920), Vec2::ZERO, 1.0, 90.0, (3840, 2160), (3840, 2160), 0, 0);
        assert_eq!(turned, r(960, 540, 1920, 1080));
    }

    #[test]
    fn off_canvas_layer_has_no_region() {
        assert_eq!(region((100, 100), Vec2::new(5000.0, 0.0), 1.0, 0.0, (200, 200), (200, 200), 0, 0), None);
        assert_eq!(region((100, 100), Vec2::ZERO, 0.0, 0.0, (200, 200), (200, 200), 0, 0), None);
    }

    #[test]
    fn quarter_turned_source_maps_back_to_the_stored_texture() {
        // Stored 2160x3840 portrait texture shown upright as 3840x2160 (quarter 1): upright uv (u, v) reads texture (v, 1 - u).
        let got = region((1080, 1920), Vec2::ZERO, 1.0, 0.0, (3840, 2160), (2160, 3840), 1, 0);
        assert_eq!(got, r(120, 3840 - 2460, 1920, 1080));
    }

    #[test]
    fn a_tilted_layer_keeps_the_whole_texture() {
        let mut t = ClipTransform::IDENTITY;
        t.tilt_x = 10.0;
        assert_eq!(
            visible_source_region(&geometry((100, 100), t, (200, 200), (200, 100), 0), 0, 0.0),
            r(0, 0, 200, 100)
        );
    }

    fn work(scale: f64, texture: (i64, i64), tpn: f32, quarter: u32, one_pass: bool, size: (i64, i64)) -> ColorWork {
        let mut t = ClipTransform::IDENTITY;
        t.scale = Vec2::new(scale, scale);
        color_work(&geometry((1080, 1920), t, size, texture, quarter), tpn, one_pass, false, true)
    }

    #[test]
    fn half_resolution_only_when_shown_at_half_size_or_less() {
        // 4K at 50 % in a vertical canvas: half-size intermediate, visible middle of it (2 canvas px + 2 texels of pad).
        let a = work(0.5, (3840, 2160), 1.0, 0, true, (3840, 2160));
        assert_eq!((a.width, a.height), (1920, 1080));
        assert_eq!(a.region, r(960 - 540 - 4, 0, 1080 + 8, 1080));
        let b = work(0.6, (3840, 2160), 1.0, 0, true, (3840, 2160));
        assert_eq!((b.width, b.height), (3840, 2160));
        // A half-size proxy of a 4K clip at 50 %: one texel per canvas pixel already, no further halving.
        let c = work(0.5, (1920, 1080), 0.5, 0, true, (3840, 2160));
        assert_eq!((c.width, c.height), (1920, 1080));
        // A blur pass reads the whole picture: full region, still half resolution.
        let d = work(0.25, (3840, 2160), 1.0, 0, false, (3840, 2160));
        assert_eq!(d, ColorWork { width: 1920, height: 1080, region: r(0, 0, 1920, 1080) });
        // Vertical phone clip (stored 3840x2160, turned) at 50 %: the whole picture shows, at half resolution.
        let e = work(0.5, (3840, 2160), 1.0, 1, true, (2160, 3840));
        assert_eq!(e, ColorWork { width: 1920, height: 1080, region: r(0, 0, 1920, 1080) });
    }

    #[test]
    fn effect_work_factor_follows_the_half_size_rule() {
        let mut t = ClipTransform::IDENTITY;
        t.scale = Vec2::new(0.5, 0.5);
        assert_eq!(effect_work_factor(&t, Float2::new(1920.0, 1080.0)), 2);
        assert_eq!(effect_work_factor(&t, Float2::new(100.0, 1080.0)), 1);
        t.scale = Vec2::new(0.6, 0.6);
        assert_eq!(effect_work_factor(&t, Float2::new(1920.0, 1080.0)), 1);
        t.scale = Vec2::new(0.25, 0.25);
        t.tilt_y = 5.0;
        assert_eq!(effect_work_factor(&t, Float2::new(1920.0, 1080.0)), 1);
    }

    #[test]
    fn display_grade_applies_below_the_threshold_only() {
        let mut t = ClipTransform::IDENTITY;
        t.scale = Vec2::new(0.5, 0.5);
        let g = geometry((1920, 1080), t, (3840, 2160), (3840, 2160), 0);
        let w = display_color_work(&g, 1.0, true).map(|w| (w.width, w.height));
        assert_eq!(w, Some((1920, 1080)));
        assert_eq!(display_color_work(&g, 1.0, false), None);
        t.scale = Vec2::new(0.95, 0.95);
        assert_eq!(display_color_work(&SourceGeometry { transform: t, ..g }, 1.0, true), None);
    }
}
