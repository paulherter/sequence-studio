// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectTransformStage.swift, DynamicZoom.swift, Stabilizer.swift, Grouping.swift, ShapeGenerator.swift, ColorGraph.swift, ColorGradeEffect.swift (catalog entries)

use super::util::{p, spec};
use crate::{ClipEffect, ColorEffect, EffectColor, EffectParamPair, EffectParamSpec, EffectSpec};
use sq_core_time::Vec2;

/// Motion's row order (Position, Scale, Rotation, Anchor, Opacity, Shutter); X/Y members are paired in the UI.
fn stage_params(shutter: bool) -> Vec<EffectParamSpec> {
    let mut params = vec![
        p(ClipEffect::STAGE_POSITION_X_KEY, "Position X", "px", 0.0, -100_000.0, 100_000.0, 1.0, 1),
        p(ClipEffect::STAGE_POSITION_Y_KEY, "Position Y", "px", 0.0, -100_000.0, 100_000.0, 1.0, 1),
        p(ClipEffect::STAGE_SCALE_KEY, "Scale", "%", 100.0, 0.0, 10_000.0, 0.5, 1),
        // P5: stored only while Scale is unlinked (absent = Height follows Scale); never created by default.
        p(ClipEffect::STAGE_SCALE_Y_KEY, "Scale Height", "%", 100.0, 0.0, 10_000.0, 0.5, 1),
        p(ClipEffect::STAGE_ROTATION_KEY, "Rotation", "\u{00B0}", 0.0, -36_000.0, 36_000.0, 1.0, 1),
        p(ClipEffect::STAGE_ANCHOR_X_KEY, "Anchor X", "px", 0.0, -100_000.0, 100_000.0, 1.0, 1),
        p(ClipEffect::STAGE_ANCHOR_Y_KEY, "Anchor Y", "px", 0.0, -100_000.0, 100_000.0, 1.0, 1),
        p(ClipEffect::STAGE_OPACITY_KEY, "Opacity", "%", 100.0, 0.0, 100.0, 1.0, 1),
    ];
    if shutter {
        params.push(p(ClipEffect::STAGE_SHUTTER_ANGLE_KEY, "Shutter Angle", "\u{00B0}", 0.0, 0.0, 360.0, 1.0, 0));
    }
    params
}

fn stage_spec(kind: &str, title: &str, shutter: bool) -> EffectSpec {
    EffectSpec { pairs: EffectParamPair::stage_pairs(), ..spec(kind, title, stage_params(shutter)) }
}

/// Transform, offered in the Effects panel.
pub(super) fn transform() -> EffectSpec {
    stage_spec(ClipEffect::TRANSFORM_KIND, "Transform", true)
}

/// Auto Reframe, written by Auto Reframe only.
pub(super) fn reframe() -> EffectSpec {
    stage_spec(ClipEffect::REFRAME_KIND, "Auto Reframe", false)
}

/// Dynamic Zoom, written by Dynamic Zoom only.
pub(super) fn dynamic_zoom() -> EffectSpec {
    stage_spec(ClipEffect::DYNAMIC_ZOOM_KIND, "Dynamic Zoom", false)
}

/// The Stabilizer effect. The Position / Rotation / Scale keys the analysis writes are not listed: they are dense generated
/// data (the stage reads them by key).
pub(super) fn stabilize() -> EffectSpec {
    spec(
        ClipEffect::STABILIZE_KIND,
        "Stabilizer",
        vec![
            EffectParamSpec::choice(ClipEffect::STABILIZE_METHOD_KEY, "Method", &["Standard", "Gyroflow"], 0),
            // Standard
            EffectParamSpec::choice(
                ClipEffect::STABILIZE_MODE_KEY,
                "Result",
                &["Smooth Motion", "No Motion", "Auto"],
                0,
            ),
            p(ClipEffect::STABILIZE_STRENGTH_KEY, "Strength", "%", 100.0, 0.0, 100.0, 1.0, 0),
            p(ClipEffect::STABILIZE_SMOOTHNESS_KEY, "Smoothness", "s", 0.5, 0.05, 10.0, 0.05, 2),
            p(ClipEffect::STABILIZE_MAX_CROP_KEY, "Crop Limit", "%", 8.0, 0.0, 50.0, 1.0, 0),
            EffectParamSpec::choice(
                ClipEffect::STABILIZE_EDGE_FILL_KEY,
                "Edge Fill",
                &["Zoom", "Mirror Edge", "Blur Edge"],
                0,
            ),
            EffectParamSpec::checkbox(ClipEffect::ROLLING_SHUTTER_KEY, "Rolling Shutter", false),
            p(ClipEffect::ROLLING_SHUTTER_STRENGTH_KEY, "Rolling Shutter Strength", "%", 100.0, 0.0, 200.0, 1.0, 0),
            // Gyroflow (GyroflowOptions)
            p(ClipEffect::GYRO_SMOOTHNESS_KEY, "Smoothness", "%", 50.0, 1.0, 100.0, 1.0, 0),
            p(ClipEffect::GYRO_ZOOM_LIMIT_KEY, "Zoom Limit", "%", 130.0, 100.0, 300.0, 1.0, 0),
            p(ClipEffect::GYRO_FIELD_OF_VIEW_KEY, "Field of View", "%", 100.0, 10.0, 300.0, 1.0, 0),
            p(ClipEffect::GYRO_LENS_CORRECTION_KEY, "Lens Correction", "%", 100.0, 0.0, 100.0, 1.0, 0),
            EffectParamSpec::checkbox(ClipEffect::GYRO_ROLLING_SHUTTER_KEY, "Rolling Shutter", true),
            p(ClipEffect::GYRO_HORIZON_LOCK_KEY, "Horizon Lock", "%", 0.0, 0.0, 100.0, 1.0, 0),
            p(ClipEffect::GYRO_SYNC_OFFSET_KEY, "Sync Offset", "ms", 0.0, -5000.0, 5000.0, 1.0, 1),
        ],
    )
}

/// Effects that belong to a generator clip and are created with it, never offered in the Effects panel.
pub(super) fn generators() -> Vec<EffectSpec> {
    vec![
        // Size in sequence px of the clip's own frame; a line is Width long and Outline Width thick (its fill is unused).
        // Titles say Outline (VOCABULARY.md), the stored keys stay "shapeStroke…". The outline is centered on the outline. Corner Radius only rounds rectangles (clamped to half the shorter side).
        spec(
            ClipEffect::SHAPE_EFFECT_KIND,
            "Shape",
            vec![
                p(ClipEffect::SHAPE_WIDTH_KEY, "Width", "px", 400.0, 0.0, 16_000.0, 1.0, 0),
                p(ClipEffect::SHAPE_HEIGHT_KEY, "Height", "px", 300.0, 0.0, 16_000.0, 1.0, 0),
                p(ClipEffect::SHAPE_CORNER_RADIUS_KEY, "Corner Radius", "px", 0.0, 0.0, 8_000.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::SHAPE_FILL_KEY, "Fill", true),
                EffectParamSpec::color(ClipEffect::SHAPE_FILL_COLOR_KEY, "Fill Color", EffectColor::WHITE),
                EffectParamSpec::checkbox(ClipEffect::SHAPE_GRADIENT_KEY, "Gradient", false),
                EffectParamSpec::color(ClipEffect::SHAPE_GRADIENT_COLOR_KEY, "Gradient End Color", EffectColor::BLACK),
                p(ClipEffect::SHAPE_GRADIENT_ANGLE_KEY, "Gradient Angle", "°", 90.0, 0.0, 360.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::SHAPE_STROKE_KEY, "Outline", false),
                EffectParamSpec::color(ClipEffect::SHAPE_STROKE_COLOR_KEY, "Outline Color", EffectColor::BLACK),
                p(ClipEffect::SHAPE_STROKE_WIDTH_KEY, "Outline Width", "px", 8.0, 0.0, 2_000.0, 0.5, 1),
            ],
        ),
    ]
}

/// The Group Transform an ungrouped Group leaves on its clips; not offered in the Effects panel.
pub(super) fn group_transform() -> EffectSpec {
    let scale = EffectParamSpec {
        kind: crate::EffectParamKind::Point(Vec2::new(1.0, 1.0)),
        display_scale: 100.0,
        ..p(ClipEffect::GROUP_SCALE_KEY, "Scale", "%", 0.0, 0.0, 100.0, 0.01, 1)
    };
    spec(
        ClipEffect::GROUP_TRANSFORM_KIND,
        "Group Transform",
        vec![
            EffectParamSpec::point(ClipEffect::GROUP_POSITION_KEY, "Position", Vec2::ZERO, "px"),
            scale,
            p(ClipEffect::GROUP_ROTATION_KEY, "Rotation", "\u{00B0}", 0.0, -36_000.0, 36_000.0, 1.0, 1),
            EffectParamSpec::point(ClipEffect::GROUP_ANCHOR_KEY, "Anchor", Vec2::ZERO, "px"),
            p(ClipEffect::GROUP_OPACITY_KEY, "Opacity", "%", 1.0, 0.0, 1.0, 0.01, 1).display_scale(100.0),
        ],
    )
}

/// The Color Graph entry: no sliders, the graph is edited in the Color panel.
pub(super) fn color_graph() -> EffectSpec {
    spec(ClipEffect::COLOR_GRAPH_KIND, "Color Graph", Vec::new())
}

/// One number of a Color effect: key, title, unit, range, decimals and where the `ColorEffect` holds it.
type ColorField = (&'static str, &'static str, &'static str, f64, f64, i64, fn(&ColorEffect) -> f32);

const DEGREE: &str = "\u{00B0}";
const BASIC: [ColorField; 11] = [
    (ClipEffect::COLOR_TEMPERATURE_KEY, "Temperature", "", -100.0, 100.0, 1, |e| e.basic.temperature),
    (ClipEffect::COLOR_TINT_KEY, "Tint", "", -100.0, 100.0, 1, |e| e.basic.tint),
    (ClipEffect::COLOR_SATURATION_KEY, "Saturation", "", 0.0, 200.0, 1, |e| e.basic.saturation),
    (ClipEffect::COLOR_EXPOSURE_KEY, "Exposure", "", -5.0, 5.0, 2, |e| e.basic.exposure),
    (ClipEffect::COLOR_CONTRAST_KEY, "Contrast", "", -100.0, 100.0, 1, |e| e.basic.contrast),
    (ClipEffect::COLOR_HIGHLIGHTS_KEY, "Highlights", "", -100.0, 100.0, 1, |e| e.basic.highlights),
    (ClipEffect::COLOR_SHADOWS_KEY, "Shadows", "", -100.0, 100.0, 1, |e| e.basic.shadows),
    (ClipEffect::COLOR_WHITES_KEY, "Whites", "", -100.0, 100.0, 1, |e| e.basic.whites),
    (ClipEffect::COLOR_BLACKS_KEY, "Blacks", "", -100.0, 100.0, 1, |e| e.basic.blacks),
    (ClipEffect::COLOR_VIBRANCE_KEY, "Vibrance", "", -100.0, 100.0, 1, |e| e.basic.vibrance),
    (ClipEffect::COLOR_INPUT_LUT_INTENSITY_KEY, "Source LUT Intensity", "", 0.0, 100.0, 1, |e| e.input_lut_intensity),
];
const CREATIVE: [ColorField; 9] = [
    (ClipEffect::COLOR_LOOK_INTENSITY_KEY, "Look Intensity", "", 0.0, 100.0, 1, |e| e.creative.intensity),
    (ClipEffect::COLOR_FADED_FILM_KEY, "Fade", "", 0.0, 100.0, 1, |e| e.creative.faded_film),
    (ClipEffect::COLOR_CREATIVE_VIBRANCE_KEY, "Look Vibrance", "", -100.0, 100.0, 1, |e| e.creative.vibrance),
    (ClipEffect::COLOR_CREATIVE_SATURATION_KEY, "Look Saturation", "", 0.0, 200.0, 1, |e| e.creative.saturation),
    (ClipEffect::COLOR_SHADOW_TINT_HUE_KEY, "Shadow Tint Hue", DEGREE, 0.0, 360.0, 1, |e| e.creative.shadow_tint.hue),
    (ClipEffect::COLOR_SHADOW_TINT_AMOUNT_KEY, "Shadow Tint Amount", "", 0.0, 1.0, 2, |e| {
        e.creative.shadow_tint.amount
    }),
    (ClipEffect::COLOR_HIGHLIGHT_TINT_HUE_KEY, "Highlight Tint Hue", DEGREE, 0.0, 360.0, 1, |e| {
        e.creative.highlight_tint.hue
    }),
    (ClipEffect::COLOR_HIGHLIGHT_TINT_AMOUNT_KEY, "Highlight Tint Amount", "", 0.0, 1.0, 2, |e| {
        e.creative.highlight_tint.amount
    }),
    (ClipEffect::COLOR_TINT_BALANCE_KEY, "Tint Balance", "", -100.0, 100.0, 1, |e| e.creative.tint_balance),
];
const WHEELS: [ColorField; 10] = [
    (ClipEffect::COLOR_WHEEL_SHADOWS_HUE_KEY, "Shadows Hue", DEGREE, 0.0, 360.0, 1, |e| e.wheels.shadows.hue),
    (ClipEffect::COLOR_WHEEL_SHADOWS_AMOUNT_KEY, "Shadows Amount", "", 0.0, 1.0, 2, |e| e.wheels.shadows.amount),
    (ClipEffect::COLOR_WHEEL_SHADOWS_LUMA_KEY, "Shadows Luma", "", -100.0, 100.0, 1, |e| e.wheels.shadows_luma),
    (ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY, "Midtones Hue", DEGREE, 0.0, 360.0, 1, |e| e.wheels.midtones.hue),
    (ClipEffect::COLOR_WHEEL_MIDTONES_AMOUNT_KEY, "Midtones Amount", "", 0.0, 1.0, 2, |e| e.wheels.midtones.amount),
    (ClipEffect::COLOR_WHEEL_MIDTONES_LUMA_KEY, "Midtones Luma", "", -100.0, 100.0, 1, |e| e.wheels.midtones_luma),
    (ClipEffect::COLOR_WHEEL_HIGHLIGHTS_HUE_KEY, "Highlights Hue", DEGREE, 0.0, 360.0, 1, |e| e.wheels.highlights.hue),
    (ClipEffect::COLOR_WHEEL_HIGHLIGHTS_AMOUNT_KEY, "Highlights Amount", "", 0.0, 1.0, 2, |e| {
        e.wheels.highlights.amount
    }),
    (ClipEffect::COLOR_WHEEL_HIGHLIGHTS_LUMA_KEY, "Highlights Luma", "", -100.0, 100.0, 1, |e| {
        e.wheels.highlights_luma
    }),
    (ClipEffect::COLOR_WHEEL_SATURATION_KEY, "Wheels Saturation", "", 0.0, 200.0, 1, |e| e.wheels.saturation),
];
const VIGNETTE: [ColorField; 4] = [
    (ClipEffect::COLOR_VIGNETTE_AMOUNT_KEY, "Vignette Amount", "", -5.0, 5.0, 2, |e| e.vignette.amount),
    (ClipEffect::COLOR_VIGNETTE_MIDPOINT_KEY, "Vignette Midpoint", "", 0.0, 100.0, 1, |e| e.vignette.midpoint),
    (ClipEffect::COLOR_VIGNETTE_ROUNDNESS_KEY, "Vignette Roundness", "", -100.0, 100.0, 1, |e| e.vignette.roundness),
    (ClipEffect::COLOR_VIGNETTE_FEATHER_KEY, "Vignette Feather", "", 0.0, 100.0, 1, |e| e.vignette.feather),
];

/// The Color effect: each section's switch, then its numbers (Lumetri order).
pub(super) fn color() -> EffectSpec {
    let defaults = ColorEffect::new(1, None);
    let rows = |fields: &[ColorField]| -> Vec<EffectParamSpec> {
        fields
            .iter()
            .map(|&(key, title, unit, lo, hi, decimals, get)| {
                let step = if decimals >= 2 { 0.01 } else { 0.1 };
                let row = p(key, title, unit, f64::from(get(&defaults)), lo, hi, step, decimals);
                if unit == DEGREE { row.hue() } else { row }
            })
            .collect()
    };
    let toggle = |key: &str, title: &str| EffectParamSpec::checkbox(key, title, true);
    let mut params = vec![toggle(ClipEffect::COLOR_BASIC_ON_KEY, "Basic")];
    params.extend(rows(&BASIC));
    params.push(toggle(ClipEffect::COLOR_CREATIVE_ON_KEY, "Creative"));
    params.extend(rows(&CREATIVE));
    params.push(toggle(ClipEffect::COLOR_CURVES_ON_KEY, "Curves"));
    params.push(toggle(ClipEffect::COLOR_WHEELS_ON_KEY, "Wheels & Match"));
    params.extend(rows(&WHEELS));
    params.push(toggle(ClipEffect::COLOR_VIGNETTE_ON_KEY, "Vignette"));
    params.extend(rows(&VIGNETTE));
    spec(ClipEffect::COLOR_KIND, "Color", params)
}
