// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRMapper.swift (effects). Premiere video components -> clip effects.

use super::{ClipContext, Mapping};
use crate::prdocument::{PRComponent, PRItem, PRParamValue};
use crate::primport_report::Status;
use sq_core_model::{AnimatedProperty, ClipEffect, EffectColor};
use sq_core_time::Vec2;

fn sv(comp: &PRComponent, id: i64) -> Option<&str> {
    comp.param(id).and_then(|p| p.static_value.as_deref())
}

fn animated(comp: &PRComponent, id: i64) -> bool {
    comp.param(id).is_some_and(PRParamValue::is_animated)
}

fn rgb(c: &EffectColor) -> EffectColor {
    EffectColor { red: c.red, green: c.green, blue: c.blue, alpha: 1.0 }
}

impl Mapping<'_> {
    pub(crate) fn effects(
        &mut self,
        item: &PRItem,
        ctx: &ClipContext,
        frame: Vec2,
        text_offset: Vec2,
    ) -> Vec<ClipEffect> {
        use Status::{Approximated, Dropped, Mapped};
        let mut out: Vec<ClipEffect> = Vec::new();
        for comp in item.components.iter().filter(|c| !c.is_audio) {
            let name = comp.match_name.as_str();
            match name {
                "AE.ADBE Motion" => {
                    // Motion's crop (params 8-11, %) as a Crop effect.
                    let ids = [8, 9, 10, 11];
                    let keys = [
                        ClipEffect::CROP_LEFT_KEY,
                        ClipEffect::CROP_TOP_KEY,
                        ClipEffect::CROP_RIGHT_KEY,
                        ClipEffect::CROP_BOTTOM_KEY,
                    ];
                    if !ids
                        .iter()
                        .any(|&i| PRParamValue::double(sv(comp, i)).unwrap_or(0.0) != 0.0 || animated(comp, i))
                    {
                        continue;
                    }
                    let mut e = self.make_effect(ClipEffect::CROP_KIND);
                    for (id, key) in ids.iter().zip(keys) {
                        e.parameters
                            .insert(key.to_string(), self.anim(ctx, comp.param(*id), 0.0, PRParamValue::double, |v| v));
                    }
                    out.push(e);
                    self.report.note("Motion crop", Mapped, "");
                }
                "AE.ADBE Opacity" | "AE.ADBE Text" | "AE.ADBE MPEG.SourceSettings" | "AE.ADBE Graphic Group" => {
                    continue;
                }
                "AE.ADBE Shape" if item.is_adjustment_layer || self.map_shapes => continue, // layer of an adjustment graphic: not drawn; its area is judged in adjustment_clip
                "AE.ADBE Geometry2" => {
                    let e = self.transform_stage(comp, ctx, frame, text_offset);
                    out.push(e);
                }
                "AE.ADBE Gaussian Blur 2" | "AE.ADBE Gaussian Blur" => {
                    let mut e = self.make_effect(ClipEffect::GAUSSIAN_BLUR_KIND);
                    // Blurriness 1:1: SQ's Gaussian Blur uses Premiere's units (ClipEffect.gaussianSigmaPerBlurriness).
                    e.parameters.insert(
                        ClipEffect::BLURRINESS_KEY.to_string(),
                        self.anim(ctx, comp.param(1), 0.0, PRParamValue::double, |v| v),
                    );
                    // Repeat Edge Pixels (param 3): the edge stays opaque instead of fading into black.
                    if PRParamValue::bool(sv(comp, 3)) == Some(true) {
                        e.parameters.insert(ClipEffect::REPEAT_EDGE_PIXELS_KEY.to_string(), AnimatedProperty::new(1.0));
                    }
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.ADBE Drop Shadow" => {
                    let mut e = self.make_effect(ClipEffect::DROP_SHADOW_KIND);
                    if let Some(col) = PRParamValue::color(sv(comp, 1)) {
                        e.colors.insert(ClipEffect::SHADOW_COLOR_KEY.to_string(), AnimatedProperty::new(rgb(&col)));
                    }
                    let mut p = |m: &mut Self, key: &str, id: i64, fallback: f64, f: fn(f64) -> f64| {
                        e.parameters
                            .insert(key.to_string(), m.anim(ctx, comp.param(id), fallback, PRParamValue::double, f));
                    };
                    p(self, ClipEffect::SHADOW_OPACITY_KEY, 2, 50.0, |v| v / 255.0 * 100.0);
                    p(self, ClipEffect::SHADOW_DIRECTION_KEY, 3, 135.0, |v| v);
                    p(self, ClipEffect::SHADOW_DISTANCE_KEY, 4, 5.0, |v| v);
                    p(self, ClipEffect::SHADOW_SOFTNESS_KEY, 5, 5.0, |v| v);
                    if PRParamValue::bool(sv(comp, 6)) == Some(true) {
                        e.parameters.insert(ClipEffect::SHADOW_ONLY_KEY.to_string(), AnimatedProperty::new(1.0));
                    }
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.ADBE Lumetri" => {
                    if let Some(e) = self.lumetri(comp) {
                        out.push(e);
                    }
                    if let Some(e) = self.lumetri_sharpen(comp) {
                        out.push(e);
                    }
                }
                "AE.ADBE Mosaic" => {
                    let mut e = self.make_effect(ClipEffect::MOSAIC_KIND);
                    e.parameters.insert(
                        ClipEffect::MOSAIC_COLUMNS_KEY.to_string(),
                        self.anim(ctx, comp.param(1), 10.0, PRParamValue::double, |v| v),
                    );
                    e.parameters.insert(
                        ClipEffect::MOSAIC_ROWS_KEY.to_string(),
                        self.anim(ctx, comp.param(2), 10.0, PRParamValue::double, |v| v),
                    );
                    if PRParamValue::bool(sv(comp, 3)) == Some(true) {
                        e.parameters.insert(ClipEffect::MOSAIC_SHARP_KEY.to_string(), AnimatedProperty::new(1.0));
                    }
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.ADBE Tint" => {
                    let mut e = self.make_effect(ClipEffect::TINT_KIND);
                    if let Some(c) = PRParamValue::color(sv(comp, 1)) {
                        e.colors.insert(ClipEffect::TINT_BLACK_KEY.to_string(), AnimatedProperty::new(rgb(&c)));
                    }
                    if let Some(c) = PRParamValue::color(sv(comp, 2)) {
                        e.colors.insert(ClipEffect::TINT_WHITE_KEY.to_string(), AnimatedProperty::new(rgb(&c)));
                    }
                    e.parameters.insert(
                        ClipEffect::TINT_AMOUNT_KEY.to_string(),
                        self.anim(ctx, comp.param(3), 100.0, PRParamValue::double, |v| v),
                    );
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.ADBE Horizontal Flip" => {
                    let e = self.make_effect(ClipEffect::HORIZONTAL_FLIP_KIND);
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.ADBE_Noise_FX" => {
                    // Premiere's grain effect (Intensity 3, Saturation 8, Master 10): the closest SQ effect is Noise.
                    let mut e = self.make_effect(ClipEffect::NOISE_KIND);
                    let master = PRParamValue::double(sv(comp, 10)).unwrap_or(100.0) / 100.0;
                    e.parameters.insert(
                        ClipEffect::NOISE_AMOUNT_KEY.to_string(),
                        self.anim(ctx, comp.param(3), 50.0, PRParamValue::double, |v| (v * master).min(100.0)),
                    );
                    let sat = PRParamValue::double(sv(comp, 8)).unwrap_or(50.0);
                    e.parameters.insert(
                        ClipEffect::NOISE_COLOR_KEY.to_string(),
                        AnimatedProperty::new(if sat > 0.0 { 1.0 } else { 0.0 }),
                    );
                    out.push(e);
                    self.report.note(name, Approximated, "film grain drawn as Noise (Intensity x Master); shadow/midtone/highlight split and blend mode dropped");
                }
                "AE.ADBE Motion Blur" | "AE.ADBE Directional Blur" => {
                    // Directional Blur (legacy match name "Motion Blur"): direction 0 = vertical smear, length px.
                    let mut e = self.make_effect(ClipEffect::DIRECTIONAL_BLUR_KIND);
                    e.parameters.insert(
                        ClipEffect::BLUR_DIRECTION_KEY.to_string(),
                        self.anim(ctx, comp.param(1), 0.0, PRParamValue::double, |v| v),
                    );
                    e.parameters.insert(
                        ClipEffect::BLUR_LENGTH_KEY.to_string(),
                        self.anim(ctx, comp.param(2), 0.0, PRParamValue::double, |v| v),
                    );
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.ADBE Alpha Adjust"
                    if PRParamValue::double(sv(comp, 1)).unwrap_or(100.0) == 100.0
                        && !animated(comp, 1)
                        && PRParamValue::bool(sv(comp, 3)) != Some(true)
                        && PRParamValue::bool(sv(comp, 4)) != Some(true) =>
                {
                    self.report.note(name, Mapped, "neutral (100 %, no invert / mask only): no effect needed");
                }
                "AE.ADBE Mirror"
                    if out.iter().any(|e| {
                        e.kind == ClipEffect::TRANSFORM_KIND
                            && e.parameters.get(ClipEffect::STAGE_SCALE_KEY).map(|p| p.value) != Some(100.0)
                    }) =>
                {
                    // Measured on the "seamless slide" preset (Transform 200 % + Mirror + Transform 50 %): Premiere's
                    // reflection line then lies outside the picture (it works in the enlarged layer's coordinates). SQ's
                    // stage space differs, so the line would cut through the frame: dropped (fidelity 18.1 dB with it,
                    // 24.0 dB without).
                    self.report.note(
                        name,
                        Dropped,
                        "after a scaled Transform (reflection line in Premiere's enlarged layer)",
                    );
                }
                "AE.ADBE Mirror" => {
                    let mut e = self.make_effect(ClipEffect::MIRROR_KIND);
                    e.points.insert(
                        ClipEffect::MIRROR_CENTER_KEY.to_string(),
                        self.anim(ctx, comp.param(1), Vec2::ZERO, PRParamValue::point, |p| {
                            Vec2::new((p.x - 0.5) * frame.x - text_offset.x, (p.y - 0.5) * frame.y - text_offset.y)
                        }),
                    );
                    e.parameters.insert(
                        ClipEffect::MIRROR_ANGLE_KEY.to_string(),
                        self.anim(ctx, comp.param(2), 0.0, PRParamValue::double, |v| v),
                    );
                    out.push(e);
                    self.report.note(name, Mapped, "");
                }
                "AE.Impact_Crop_FX" => {
                    let fx = self.rounded_crop(comp, ctx, frame);
                    out.extend(fx);
                }
                "AE.ADBE Ultra Key" => {
                    if let Some(e) = self.ultra_key(comp, ctx) {
                        out.push(e);
                    }
                }
                "AE.ADBE Ramp" => {
                    // Ramp (ids checked on the maintainer's instance): Start 1, Start Color 2, End 3, End Color 4, Shape 5
                    // (0 linear, 1 radial), Scatter 6, Blend With Original 7. Points are 0...1 of the frame; SQ's are px from
                    // its center.
                    let mut e = self.make_effect(ClipEffect::GRADIENT_KIND);
                    let point = |m: &mut Self, id: i64, fallback: Vec2| {
                        m.anim(ctx, comp.param(id), fallback, PRParamValue::point, |p| {
                            Vec2::new((p.x - 0.5) * frame.x - text_offset.x, (p.y - 0.5) * frame.y - text_offset.y)
                        })
                    };
                    e.points.insert(
                        ClipEffect::GRADIENT_START_KEY.to_string(),
                        point(self, 1, Vec2::new(0.0, -frame.y / 2.0)),
                    );
                    e.points.insert(
                        ClipEffect::GRADIENT_END_KEY.to_string(),
                        point(self, 3, Vec2::new(0.0, frame.y / 2.0)),
                    );
                    for (id, key) in [(2, ClipEffect::GRADIENT_COLOR1_KEY), (4, ClipEffect::GRADIENT_COLOR2_KEY)] {
                        // Colors keep their keys; alpha is dropped like before (the ramp covers the frame).
                        if PRParamValue::color(sv(comp, id)).is_none() && !animated(comp, id) {
                            continue;
                        }
                        e.colors.insert(
                            key.to_string(),
                            self.anim(ctx, comp.param(id), EffectColor::BLACK, PRParamValue::color, |c| rgb(&c)),
                        );
                    }
                    e.parameters.insert(
                        ClipEffect::GRADIENT_TYPE_KEY.to_string(),
                        AnimatedProperty::new(if PRParamValue::double(sv(comp, 5)) == Some(1.0) { 1.0 } else { 0.0 }),
                    );
                    e.parameters.insert(
                        ClipEffect::GRADIENT_BLEND_KEY.to_string(),
                        self.anim(ctx, comp.param(7), 100.0, PRParamValue::double, |v| 100.0 - v),
                    );
                    out.push(e);
                    let lost = if PRParamValue::double(sv(comp, 6)).unwrap_or(0.0) != 0.0 {
                        "Ramp Scatter dropped"
                    } else {
                        ""
                    };
                    self.report.note(name, if lost.is_empty() { Mapped } else { Approximated }, lost);
                }
                _ => self.report.note(name, Dropped, &comp.display_name),
            }
        }
        out
    }

    /// Ultra Key as SQ's Color Key. Param ids checked 2026-10-06 on the maintainer's four instances (German UI, all with
    /// Premiere's defaults except the key color): Output 1 (0 Composite, 1 Alpha Channel, 2 Color Channel), Setting 2, Key
    /// Color 3, Matte Generation 5-9 (Transparency, Highlight, Shadow, Tolerance, Pedestal), Matte Cleanup 12-15 (Choke,
    /// Soften, Contrast, Mid Point), Spill Suppression 18-21 (Desaturate, Range, Spill, Luma), Color Correction 24-26
    /// (Saturation, Hue, Luminance); 4, 11, 17, 23 are the group headers. The key hue and the controls with the same
    /// meaning in SQ are copied (Premiere's Spill 20 is SQ's Spill; Desaturate 18 and spill Luma 21 have no SQ control and
    /// are not carried). Premiere's matte generation is a different formulation (the design notes, Keying family), so
    /// Tolerance, Soften, Keep Highlights and Keep Shadows start from SQ's Green Screen preset: approximated, to be tuned
    /// by eye.
    fn ultra_key(&mut self, comp: &PRComponent, ctx: &ClipContext) -> Option<ClipEffect> {
        let Some(hue) = PRParamValue::color(sv(comp, 3)).and_then(|c| hue(&c)) else {
            self.report.note(&comp.match_name, Status::Dropped, "no key color picked (black or gray keys nothing)");
            return None;
        };
        let mut e = self.make_effect(ClipEffect::ULTRA_KEY_KIND);
        e.parameters.insert(ClipEffect::KEY_HUE_KEY.to_string(), AnimatedProperty::new(hue));
        for (key, value) in [
            (ClipEffect::TOLERANCE_KEY, 45.0),
            (ClipEffect::SOFTEN_KEY, 20.0),
            (ClipEffect::KEY_HIGHLIGHT_KEY, 10.0),
            (ClipEffect::KEY_SHADOW_KEY, 20.0),
        ] {
            e.parameters.insert(key.to_string(), AnimatedProperty::new(value));
        }
        for (id, key, fallback) in [
            (9, ClipEffect::PEDESTAL_KEY, 10.0),
            (12, ClipEffect::CHOKE_KEY, 0.0),
            (14, ClipEffect::KEY_CONTRAST_KEY, 0.0),
            (15, ClipEffect::KEY_MIDPOINT_KEY, 50.0),
            (20, ClipEffect::SPILL_KEY, 50.0),
            (19, ClipEffect::SPILL_RANGE_KEY, 50.0),
            (24, ClipEffect::KEY_SATURATION_KEY, 100.0),
            (25, ClipEffect::KEY_HUE_SHIFT_KEY, 0.0),
            (26, ClipEffect::KEY_LUMA_KEY, 100.0),
        ] {
            e.parameters.insert(key.to_string(), self.anim(ctx, comp.param(id), fallback, PRParamValue::double, |v| v));
        }
        // Alpha Channel shows the matte; Color Channel (the color before the matte applies) is closest to SQ's Source.
        let output = crate::prcontainer::safe_int(PRParamValue::double(sv(comp, 1))).unwrap_or(0);
        e.parameters.insert(
            ClipEffect::KEY_OUTPUT_KEY.to_string(),
            AnimatedProperty::new(if (0..=2).contains(&output) { output as f64 } else { 0.0 }),
        );
        let keyed = if animated(comp, 3) { "; key colour keys dropped" } else { "" };
        self.report.note(
            &comp.match_name,
            Status::Approximated,
            &format!("key hue, matte clean-up, Spill, Range and color correction copied; Transparency, Highlight, Shadow, Tolerance and matte Soften use SQ's Green Screen starting values; spill Desaturate and Luma have no SQ control{keyed}"),
        );
        Some(e)
    }

    fn transform_stage(&mut self, comp: &PRComponent, ctx: &ClipContext, frame: Vec2, text_offset: Vec2) -> ClipEffect {
        let mut e = self.make_effect(ClipEffect::TRANSFORM_KIND);
        let axis = |m: &mut Self, id: i64, x: bool| {
            m.anim(ctx, comp.param(id), 0.0, PRParamValue::point, |p| {
                if x { (p.x - 0.5) * frame.x - text_offset.x } else { (p.y - 0.5) * frame.y - text_offset.y }
            })
        };
        // Premiere maps q -> R s (q - A) + P; an SQ stage maps p -> R s (p - a) + a + position in the clip's own frame (the
        // text raster sits at `text_offset`): a = A - text_offset, position = P - A.
        let ax = axis(self, 1, true);
        let ay = axis(self, 1, false);
        e.parameters.insert(ClipEffect::STAGE_ANCHOR_X_KEY.to_string(), ax);
        e.parameters.insert(ClipEffect::STAGE_ANCHOR_Y_KEY.to_string(), ay);
        let anchor = PRParamValue::point(sv(comp, 1)).unwrap_or(Vec2::new(0.5, 0.5));
        if animated(comp, 1) {
            self.report.note("Transform anchor keys", Status::Approximated, "position uses the static anchor");
        }
        let px = self.anim(ctx, comp.param(2), 0.0, PRParamValue::point, |p| (p.x - anchor.x) * frame.x);
        let py = self.anim(ctx, comp.param(2), 0.0, PRParamValue::point, |p| (p.y - anchor.y) * frame.y);
        e.parameters.insert(ClipEffect::STAGE_POSITION_X_KEY.to_string(), px);
        e.parameters.insert(ClipEffect::STAGE_POSITION_Y_KEY.to_string(), py);
        e.parameters.insert(
            ClipEffect::STAGE_SCALE_KEY.to_string(),
            self.anim(ctx, comp.param(3), 100.0, PRParamValue::double, |v| v),
        );
        e.parameters.insert(
            ClipEffect::STAGE_ROTATION_KEY.to_string(),
            self.anim(ctx, comp.param(7), 0.0, PRParamValue::double, |v| v),
        );
        e.parameters.insert(
            ClipEffect::STAGE_OPACITY_KEY.to_string(),
            self.anim(ctx, comp.param(8), 100.0, PRParamValue::double, |v| v),
        );
        if PRParamValue::bool(sv(comp, 9)) == Some(false) {
            e.parameters.insert(
                ClipEffect::STAGE_SHUTTER_ANGLE_KEY.to_string(),
                self.anim(ctx, comp.param(10), 0.0, PRParamValue::double, |v| v),
            );
        }
        let mut approx: Vec<&str> = Vec::new();
        if PRParamValue::bool(sv(comp, 11)) == Some(false)
            && PRParamValue::double(sv(comp, 4)).unwrap_or(100.0) != PRParamValue::double(sv(comp, 3)).unwrap_or(100.0)
        {
            approx.push("non-uniform scale (height used)");
        }
        if PRParamValue::double(sv(comp, 5)).unwrap_or(0.0) != 0.0 || animated(comp, 5) {
            approx.push("skew");
        }
        self.report.note(
            "AE.ADBE Geometry2",
            if approx.is_empty() { Status::Mapped } else { Status::Approximated },
            &approx.join(", "),
        );
        e
    }

    /// Impact Rounded Crop: crop % per side + roundness (as a share of half the short side).
    fn rounded_crop(&mut self, comp: &PRComponent, ctx: &ClipContext, frame: Vec2) -> Vec<ClipEffect> {
        let mut out = Vec::new();
        let sides = [
            (8182, ClipEffect::CROP_LEFT_KEY),
            (8184, ClipEffect::CROP_TOP_KEY),
            (8183, ClipEffect::CROP_RIGHT_KEY),
            (8185, ClipEffect::CROP_BOTTOM_KEY),
        ];
        if sides.iter().any(|(id, _)| PRParamValue::double(sv(comp, *id)).unwrap_or(0.0) != 0.0 || animated(comp, *id))
        {
            let mut e = self.make_effect(ClipEffect::CROP_KIND);
            for (id, key) in sides {
                e.parameters.insert(key.to_string(), self.anim(ctx, comp.param(id), 0.0, PRParamValue::double, |v| v));
            }
            out.push(e);
        }
        let round = PRParamValue::double(sv(comp, 8187)).unwrap_or(0.0);
        if round > 0.0 {
            out.push(ClipEffect::rounded_corners(self.ids.next_id(), round / 100.0 * frame.x.min(frame.y) / 2.0));
        }
        self.report.note(
            "AE.Impact_Crop_FX",
            Status::Approximated,
            "Crop + Rounded Corners; roundness scale and feather estimated",
        );
        out
    }
}

/// Hue in degrees (0...360) of a color; `None` for black, white and grays.
pub(super) fn hue(c: &EffectColor) -> Option<f64> {
    let hi = c.red.max(c.green).max(c.blue);
    let d = hi - c.red.min(c.green).min(c.blue);
    if d <= 0.02 {
        return None;
    }
    let h = if hi == c.red {
        (c.green - c.blue) / d
    } else if hi == c.green {
        2.0 + (c.blue - c.red) / d
    } else {
        4.0 + (c.red - c.green) / d
    };
    Some((h * 60.0 + 360.0) % 360.0)
}
