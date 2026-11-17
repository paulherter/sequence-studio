// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectsCatalog.swift, TemporalEffects.swift, PosterizeTime.swift, DateStamp.swift (catalog entries)

use super::util::{p, spec};
use crate::{ClipEffect, EffectColor, EffectParamSpec, EffectSpec, PictureAxis};

/// Rounded Corners, Crop, Blur, Drop Shadow, the keys and Track Mask.
pub(super) fn core() -> Vec<EffectSpec> {
    vec![
        spec(
            ClipEffect::ROUNDED_CORNERS_KIND,
            "Rounded Corners",
            vec![p(ClipEffect::RADIUS_KEY, "Radius", "px", 24.0, 0.0, 10_000.0, 1.0, 0)],
        ),
        spec(
            ClipEffect::CROP_KIND,
            "Crop",
            vec![
                p(ClipEffect::CROP_LEFT_KEY, "Left", "%", 0.0, 0.0, 100.0, 0.5, 1).axis(PictureAxis::Width),
                p(ClipEffect::CROP_TOP_KEY, "Top", "%", 0.0, 0.0, 100.0, 0.5, 1).axis(PictureAxis::Height),
                p(ClipEffect::CROP_RIGHT_KEY, "Right", "%", 0.0, 0.0, 100.0, 0.5, 1).axis(PictureAxis::Width),
                p(ClipEffect::CROP_BOTTOM_KEY, "Bottom", "%", 0.0, 0.0, 100.0, 0.5, 1).axis(PictureAxis::Height),
                p(ClipEffect::CROP_SOFTNESS_KEY, "Softness", "px", 0.0, 0.0, 1_000.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::GAUSSIAN_BLUR_KIND,
            "Blur",
            vec![
                p(ClipEffect::BLURRINESS_KEY, "Amount", "", 0.0, 0.0, 3_000.0, 0.5, 1),
                EffectParamSpec::checkbox(ClipEffect::REPEAT_EDGE_PIXELS_KEY, "Repeat Edge Pixels", false),
            ],
        ),
        // Premiere's Drop Shadow: direction 0 = up, clockwise; distance and softness in px of the clip's own frame.
        // Shadow Color is one keyframable color (v24; before: three 0...255 channels); Shadow Only is a checkbox.
        spec(
            ClipEffect::DROP_SHADOW_KIND,
            "Drop Shadow",
            vec![
                EffectParamSpec::color(ClipEffect::SHADOW_COLOR_KEY, "Shadow Color", EffectColor::BLACK),
                p(ClipEffect::SHADOW_OPACITY_KEY, "Opacity", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SHADOW_DIRECTION_KEY, "Direction", "\u{00B0}", 135.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::SHADOW_DISTANCE_KEY, "Distance", "px", 5.0, 0.0, 1_000.0, 1.0, 0),
                p(ClipEffect::SHADOW_SPREAD_KEY, "Spread", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SHADOW_SOFTNESS_KEY, "Softness", "px", 5.0, 0.0, 1_000.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::SHADOW_ONLY_KEY, "Shadow Only", false),
            ],
        ),
        // Chroma key (Ultra Key family): pick the hue to remove (green 120, blue 220), how far around it and how soft. Matte
        // generation: Keep Highlights / Keep Shadows leave bright / dark pixels of the subject alone, Black level drops weak
        // keying. Matte clean-up (shared `MatteRefine`): Shrink / Grow, Contrast, Midpoint. Spill: Spill amount and Range.
        // Color correction applies to the kept picture. Defaults leave every new control neutral; the "Green Screen" and
        // "Blue Screen" presets (`KeyingPresets`) carry the starting values.
        spec(
            ClipEffect::ULTRA_KEY_KIND,
            "Color Key",
            vec![
                p(ClipEffect::KEY_HUE_KEY, "Key Hue", "\u{00B0}", 120.0, 0.0, 360.0, 1.0, 0).hue(),
                p(ClipEffect::TOLERANCE_KEY, "Tolerance", "%", 40.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SOFTEN_KEY, "Soften", "%", 20.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_HIGHLIGHT_KEY, "Keep Highlights", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_SHADOW_KEY, "Keep Shadows", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::PEDESTAL_KEY, "Black level", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::CHOKE_KEY, "Shrink / Grow", "%", 0.0, -100.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_CONTRAST_KEY, "Matte Contrast", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_MIDPOINT_KEY, "Matte Midpoint", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SPILL_KEY, "Spill", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SPILL_RANGE_KEY, "Spill Range", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_SATURATION_KEY, "Saturation", "%", 100.0, 0.0, 200.0, 1.0, 0),
                p(ClipEffect::KEY_HUE_SHIFT_KEY, "Hue Shift", "\u{00B0}", 0.0, -180.0, 180.0, 1.0, 0),
                p(ClipEffect::KEY_LUMA_KEY, "Brightness", "%", 100.0, 0.0, 200.0, 1.0, 0),
                // Output: Composite = the keyed picture; Alpha = the matte as black / white (white kept), for tuning the key;
                // Source = the picture before keying, for comparing.
                EffectParamSpec::choice(ClipEffect::KEY_OUTPUT_KEY, "Output", &["Composite", "Alpha", "Source"], 0),
            ],
        ),
        // Luma key: removes the darks (or brights) of a picture, e.g. a title on white or black, a light flash.
        spec(
            ClipEffect::LUMA_KEY_KIND,
            "Luma Key",
            vec![
                EffectParamSpec::choice(ClipEffect::LUMA_KEY_OUT_KEY, "Key Out", &["Darks", "Brights"], 0),
                p(ClipEffect::LUMA_THRESHOLD_KEY, "Threshold", "%", 20.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::LUMA_SOFTNESS_KEY, "Softness", "%", 10.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::CHOKE_KEY, "Shrink / Grow", "%", 0.0, -100.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_CONTRAST_KEY, "Matte Contrast", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::KEY_MIDPOINT_KEY, "Matte Midpoint", "%", 50.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::choice(ClipEffect::KEY_OUTPUT_KEY, "Output", &["Composite", "Alpha", "Source"], 0),
            ],
        ),
        // Track Mask: another video track's picture limits this clip (its alpha, or its brightness). The track itself is not a
        // number: it is `ClipEffect.maskTrack`, picked on its own row. Evaluates to a Picture mask (`TrackMaskEffect.swift`).
        spec(
            ClipEffect::TRACK_MASK_KIND,
            "Track Mask",
            vec![
                EffectParamSpec::choice(ClipEffect::TRACK_MASK_MODE_KEY, "Mode", &["Alpha", "Luma"], 0),
                EffectParamSpec::checkbox(ClipEffect::TRACK_MASK_INVERT_KEY, "Invert", false),
            ],
        ),
    ]
}

/// Film / tape look. Defaults are chosen values (the design notes), tuned to be visible but tasteful at once: gate weave a
/// few px, scanlines and tracking noise visible at once. Grain (Film Grain) and glow (Glow) live in the single effects.
pub(super) fn film_look() -> Vec<EffectSpec> {
    vec![
        spec(
            ClipEffect::GATE_WEAVE_KIND,
            "Gate Weave",
            vec![
                p(ClipEffect::AMOUNT_KEY, "Amount", "px", 3.0, 0.0, 30.0, 0.1, 1),
                p(ClipEffect::SPEED_KEY, "Speed", "Hz", 2.5, 0.1, 12.0, 0.1, 1),
                p(ClipEffect::ROTATION_KEY, "Rotation", "\u{00B0}", 0.15, 0.0, 2.0, 0.01, 2),
            ],
        ),
        spec(
            ClipEffect::AGED_FILM_KIND,
            "Aged Film",
            vec![
                p(ClipEffect::DUST_KEY, "Dust", "%", 40.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SCRATCHES_KEY, "Scratches", "%", 30.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::FLICKER_KEY, "Flicker", "%", 25.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::SCANLINES_KIND,
            "Scanlines",
            vec![
                p(ClipEffect::INTENSITY_KEY, "Intensity", "%", 30.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SPACING_KEY, "Line Spacing", "px", 4.0, 2.0, 32.0, 1.0, 0),
                p(ClipEffect::THICKNESS_KEY, "Thickness", "%", 50.0, 10.0, 90.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::CHROMA_BLEED_KIND,
            "Chroma Bleed",
            vec![
                p(ClipEffect::BLEED_KEY, "Bleed", "px", 6.0, 0.0, 60.0, 0.5, 1),
                p(ClipEffect::SHIFT_KEY, "Shift", "px", 2.0, -30.0, 30.0, 0.5, 1),
            ],
        ),
        spec(
            ClipEffect::TRACKING_NOISE_KIND,
            "Tracking Noise",
            vec![
                p(ClipEffect::AMOUNT_KEY, "Amount", "%", 35.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::BAND_HEIGHT_KEY, "Band Height", "%", 12.0, 2.0, 50.0, 1.0, 0),
                p(ClipEffect::SPEED_KEY, "Speed", "Hz", 0.4, 0.0, 4.0, 0.05, 2),
            ],
        ),
    ]
}

/// Video Denoise, Deflicker, Motion Blur and Trails. Defaults chosen (the design notes "Temporal effects").
pub(super) fn temporal() -> Vec<EffectSpec> {
    vec![
        spec(
            ClipEffect::VIDEO_DENOISE_KIND,
            "Video Denoise",
            vec![
                p(ClipEffect::FRAMES_EACH_SIDE_KEY, "Frames Each Side", "", 2.0, 0.0, 5.0, 1.0, 0),
                EffectParamSpec::choice(ClipEffect::QUALITY_KEY, "Quality", &["Fast", "Best"], 0),
                EffectParamSpec::choice(
                    ClipEffect::MOTION_SEARCH_KEY,
                    "Motion Search",
                    &["Small", "Medium", "Large"],
                    1,
                ),
                p(ClipEffect::LUMA_STRENGTH_KEY, "Luma Strength", "%", 40.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::COLOR_STRENGTH_KEY, "Color Strength", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::MOTION_LIMIT_KEY, "Motion Limit", "%", 50.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::choice(
                    ClipEffect::DETAIL_SIZE_KEY,
                    "Spatial Size",
                    &["Off", "Small", "Medium", "Large"],
                    1,
                ),
                p(ClipEffect::SPATIAL_LUMA_KEY, "Spatial Luma", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::SPATIAL_COLOR_KEY, "Spatial Color", "%", 20.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::KEEP_ORIGINAL_KEY, "Keep Original", "%", 0.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::DEFLICKER_KIND,
            "Deflicker",
            vec![
                p(ClipEffect::FRAMES_EACH_SIDE_KEY, "Frames Each Side", "", 3.0, 1.0, 10.0, 1.0, 0),
                EffectParamSpec::choice(ClipEffect::ANALYSIS_KEY, "Motion Analysis", &["Fast", "Best"], 0),
                p(ClipEffect::STRENGTH_KEY, "Strength", "%", 100.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::MOTION_BLUR_KIND,
            "Motion Blur",
            vec![
                p(ClipEffect::AMOUNT_KEY, "Amount", "", 50.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::choice(
                    ClipEffect::BLUR_DIRECTION_MODE_KEY,
                    "Direction",
                    &["Both Sides", "From Previous", "Toward Next"],
                    0,
                ),
                EffectParamSpec::choice(ClipEffect::SMOOTHNESS_KEY, "Smoothness", &["Coarse", "Medium", "Fine"], 1),
            ],
        ),
        // C4 Trails: Echoes earlier frames, Spacing frames apart; each one Decay % weaker than the one before.
        spec(
            ClipEffect::TRAILS_KIND,
            "Trails",
            vec![
                p(ClipEffect::TRAIL_COUNT_KEY, "Echoes", "", 4.0, 2.0, 8.0, 1.0, 0),
                p(ClipEffect::TRAIL_SPACING_KEY, "Spacing", "frames", 2.0, 1.0, 3.0, 1.0, 0),
                p(ClipEffect::TRAIL_DECAY_KEY, "Decay", "%", 40.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::choice(ClipEffect::TRAIL_BLEND_KEY, "Blend", &["Add", "Screen", "Lighten"], 1),
            ],
        ),
    ]
}

/// Posterize Time: the held frame rate.
pub(super) fn posterize_time() -> Vec<EffectSpec> {
    // shortcut: 1...60 fps and 8 fps are copied from Swift `PosterizeTime.rateRange` / `defaultRate`; point at the
    // effects crate's constants when it exists.
    vec![spec(
        ClipEffect::POSTERIZE_TIME_KIND,
        "Posterize Time",
        vec![p(ClipEffect::POSTERIZE_RATE_KEY, "Frame Rate", "fps", 8.0, 1.0, 60.0, 1.0, 0)],
    )]
}

/// Date Stamp: format index, date and time fields, corner, size, color, blink.
pub(super) fn date_stamp() -> Vec<EffectSpec> {
    vec![spec(
        ClipEffect::DATE_STAMP_KIND,
        "Date Stamp",
        vec![
            EffectParamSpec::choice(ClipEffect::STAMP_FORMAT_KEY, "Format", &DATE_STAMP_FORMAT_TITLES, 5),
            p(ClipEffect::STAMP_YEAR_KEY, "Year", "", 1998.0, 1900.0, 2200.0, 1.0, 0),
            p(ClipEffect::STAMP_MONTH_KEY, "Month", "", 7.0, 1.0, 12.0, 1.0, 0),
            p(ClipEffect::STAMP_DAY_KEY, "Day", "", 14.0, 1.0, 31.0, 1.0, 0),
            p(ClipEffect::STAMP_HOUR_KEY, "Hour", "", 22.0, 0.0, 23.0, 1.0, 0),
            p(ClipEffect::STAMP_MINUTE_KEY, "Minute", "", 32.0, 0.0, 59.0, 1.0, 0),
            EffectParamSpec::choice(ClipEffect::STAMP_POSITION_KEY, "Position", &DATE_STAMP_POSITION_TITLES, 0),
            p(ClipEffect::STAMP_SIZE_KEY, "Size", "%", 4.5, 1.0, 20.0, 0.5, 1),
            EffectParamSpec::color(
                ClipEffect::STAMP_COLOR_KEY,
                "Color",
                EffectColor { red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0 },
            ),
            EffectParamSpec::checkbox(ClipEffect::STAMP_BLINK_KEY, "Blink", false),
        ],
    )]
}

/// Format titles of the Date Stamp (stored as the index: never reorder).
const DATE_STAMP_FORMAT_TITLES: [&str; 7] = [
    "JUL 14 1998",
    "14.07.1998",
    "07/14/1998",
    "10:32 PM",
    "22:32:05",
    "JUL 14 1998  10:32 PM",
    "14.07.1998  22:32:05",
];
/// Corner titles of the Date Stamp.
const DATE_STAMP_POSITION_TITLES: [&str; 4] = ["Bottom Right", "Bottom Left", "Top Right", "Top Left"];
