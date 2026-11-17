// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleEffects.swift (catalog entries)

use super::util::{p, spec};
use crate::{ClipEffect, EffectColor, EffectParamSpec, EffectSpec};
use sq_core_time::Vec2;

const INVERT_CHANNELS: [&str; 5] = ["RGB", "Red", "Green", "Blue", "Alpha"];
const WAVE_TYPES: [&str; 4] = ["Sine", "Square", "Triangle", "Sawtooth"];
const WAVE_PINNINGS: [&str; 4] = ["None", "All Edges", "Horizontal Edges", "Vertical Edges"];
const GRADIENT_TYPES: [&str; 2] = ["Linear", "Radial"];
const STROBE_OPERATORS: [&str; 5] = ["Copy", "Add", "Multiply", "Screen", "Difference"];
const OUTLINE_POSITIONS: [&str; 3] = ["Outside", "Inside", "Center"];
const HALFTONE_MODES: [&str; 2] = ["Black & White", "Color"];

/// FB-T2 style effects: Premiere's names, defaults and ranges where Premiere has the effect, and visible start values for
/// the short-form looks it only has inside Lumetri or not at all.
pub(super) fn specs() -> Vec<EffectSpec> {
    let deg = "\u{00B0}";
    vec![
        // Lumetri's Vignette as its own effect: Amount in stops (negative darkens the edges, positive lightens them),
        // Midpoint = where the falloff sits, Roundness 0 = the frame's ellipse (+ circle, - rounded rectangle), Feather = width.
        spec(
            ClipEffect::VIGNETTE_KIND,
            "Vignette",
            vec![
                p(ClipEffect::VIGNETTE_AMOUNT_KEY, "Amount", "", -1.5, -5.0, 5.0, 0.1, 1),
                p(ClipEffect::VIGNETTE_MIDPOINT_KEY, "Midpoint", "", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::VIGNETTE_ROUNDNESS_KEY, "Roundness", "", 0.0, -100.0, 100.0, 1.0, 0),
                p(ClipEffect::VIGNETTE_FEATHER_KEY, "Feather", "", 50.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        // Film Grain: soft, resolution-independent grain (Size in px of the clip), a new pattern each frame; Response
        // keeps it out of the deepest shadows and brightest highlights like film does.
        spec(
            ClipEffect::GRAIN_KIND,
            "Film Grain",
            vec![
                p(ClipEffect::GRAIN_AMOUNT_KEY, "Amount", "%", 30.0, 0.0, 100.0, 0.5, 1),
                p(ClipEffect::GRAIN_SIZE_KEY, "Size", "px", 1.5, 0.5, 20.0, 0.1, 1),
                p(ClipEffect::GRAIN_SOFTNESS_KEY, "Softness", "%", 40.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::GRAIN_COLOR_KEY, "Color", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::GRAIN_RESPONSE_KEY, "Highlight/Shadow Protect", "%", 60.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::GRAIN_ANIMATE_KEY, "Animate", true),
            ],
        ),
        // RGB Split (chromatic aberration): red one way, blue the other. Radial = lens-like, growing towards the corners.
        spec(
            ClipEffect::RGB_SPLIT_KIND,
            "RGB Split",
            vec![
                p(ClipEffect::RGB_SPLIT_AMOUNT_KEY, "Amount", "px", 8.0, 0.0, 1_000.0, 0.5, 1),
                p(ClipEffect::RGB_SPLIT_ANGLE_KEY, "Angle", deg, 90.0, -3_600.0, 3_600.0, 1.0, 0),
                EffectParamSpec::choice(ClipEffect::RGB_SPLIT_MODE_KEY, "Mode", &["Linear", "Radial"], 0),
                p(ClipEffect::RGB_SPLIT_BLEND_KEY, "Blend With Original", "%", 0.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        // Premiere's Radial Blur: Spin smears Amount degrees around Center, Zoom along the line to it (Amount % of the
        // distance). Antialiasing High takes twice the taps.
        spec(
            ClipEffect::RADIAL_BLUR_KIND,
            "Radial Blur",
            vec![
                p(ClipEffect::RADIAL_AMOUNT_KEY, "Amount", "", 10.0, 0.0, 100.0, 0.5, 1),
                EffectParamSpec::point(ClipEffect::RADIAL_CENTER_KEY, "Center", Vec2::ZERO, "px"),
                EffectParamSpec::choice(ClipEffect::RADIAL_TYPE_KEY, "Type", &["Spin", "Zoom"], 0),
                EffectParamSpec::choice(
                    ClipEffect::RADIAL_QUALITY_KEY,
                    "Antialiasing (Best Quality)",
                    &["Low", "High"],
                    0,
                ),
            ],
        ),
        spec(ClipEffect::HORIZONTAL_FLIP_KIND, "Horizontal Flip", vec![]),
        spec(ClipEffect::VERTICAL_FLIP_KIND, "Vertical Flip", vec![]),
        spec(
            ClipEffect::INVERT_KIND,
            "Invert",
            vec![
                EffectParamSpec::choice(ClipEffect::INVERT_CHANNEL_KEY, "Channel", &INVERT_CHANNELS, 0),
                p(ClipEffect::INVERT_BLEND_KEY, "Blend With Original", "%", 0.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::POSTERIZE_KIND,
            "Posterize",
            vec![p(ClipEffect::POSTERIZE_LEVEL_KEY, "Level", "", 7.0, 2.0, 255.0, 1.0, 0)],
        ),
        // Premiere's Tint: the picture's luminance mapped from Map Black To to Map White To (duotone), Amount to Tint mixed in.
        spec(
            ClipEffect::TINT_KIND,
            "Duotone",
            vec![
                EffectParamSpec::color(ClipEffect::TINT_BLACK_KEY, "Map Black To", EffectColor::BLACK),
                EffectParamSpec::color(ClipEffect::TINT_WHITE_KEY, "Map White To", EffectColor::WHITE),
                p(ClipEffect::TINT_AMOUNT_KEY, "Amount to Duotone", "%", 100.0, 0.0, 100.0, 0.5, 1),
            ],
        ),
        spec(ClipEffect::BLACK_AND_WHITE_KIND, "Black & White", vec![]),
        spec(
            ClipEffect::BRIGHTNESS_CONTRAST_KIND,
            "Brightness & Contrast",
            vec![
                p(ClipEffect::BRIGHTNESS_KEY, "Brightness", "", 0.0, -100.0, 100.0, 0.5, 1),
                p(ClipEffect::CONTRAST_KEY, "Contrast", "", 0.0, -100.0, 100.0, 0.5, 1),
            ],
        ),
        // Premiere's Twirl: strongest at Twirl Center, none at Twirl Radius (% of the longer side; 50 reaches the edges).
        spec(
            ClipEffect::TWIRL_KIND,
            "Twirl",
            vec![
                p(ClipEffect::TWIRL_ANGLE_KEY, "Angle", deg, 0.0, -36_000.0, 36_000.0, 1.0, 0),
                p(ClipEffect::TWIRL_RADIUS_KEY, "Twirl Radius", "", 50.0, 0.0, 100.0, 0.5, 1),
                EffectParamSpec::point(ClipEffect::TWIRL_CENTER_KEY, "Twirl Center", Vec2::ZERO, "px"),
            ],
        ),
        // Corner Warp: the four corners move by their offsets (px) and the picture is stretched to the new quadrilateral
        // in perspective; outside it is transparent. All offsets zero = the picture as it is (the drop-in default).
        spec(
            ClipEffect::CORNER_PIN_KIND,
            "Corner Warp",
            vec![
                EffectParamSpec::point(ClipEffect::CORNER_PIN_TOP_LEFT_KEY, "Top Left", Vec2::ZERO, "px"),
                EffectParamSpec::point(ClipEffect::CORNER_PIN_TOP_RIGHT_KEY, "Top Right", Vec2::ZERO, "px"),
                EffectParamSpec::point(ClipEffect::CORNER_PIN_BOTTOM_RIGHT_KEY, "Bottom Right", Vec2::ZERO, "px"),
                EffectParamSpec::point(ClipEffect::CORNER_PIN_BOTTOM_LEFT_KEY, "Bottom Left", Vec2::ZERO, "px"),
            ],
        ),
        // Premiere's Wave Warp: waves travel along Direction (90 = right), the picture moves across it by Wave Height px;
        // Wave Width is the wavelength, Wave Speed cycles per second, Phase where the cycle starts. Pinning holds edges still.
        spec(
            ClipEffect::WAVE_WARP_KIND,
            "Wave Warp",
            vec![
                EffectParamSpec::choice(ClipEffect::WAVE_TYPE_KEY, "Wave Type", &WAVE_TYPES, 0),
                p(ClipEffect::WAVE_HEIGHT_KEY, "Wave Height", "px", 10.0, -1_000.0, 1_000.0, 1.0, 0),
                p(ClipEffect::WAVE_WIDTH_KEY, "Wave Width", "px", 40.0, 1.0, 10_000.0, 1.0, 0),
                p(ClipEffect::WAVE_DIRECTION_KEY, "Direction", deg, 90.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::WAVE_SPEED_KEY, "Wave Speed", "", 1.0, -100.0, 100.0, 0.1, 1),
                EffectParamSpec::choice(ClipEffect::WAVE_PINNING_KEY, "Pinning", &WAVE_PINNINGS, 0),
                p(ClipEffect::WAVE_PHASE_KEY, "Phase", deg, 0.0, -36_000.0, 36_000.0, 1.0, 0),
            ],
        ),
        // Spherize: a lens bulge of Radius px around Center; Strength (extra) below 0 pinches.
        spec(
            ClipEffect::SPHERIZE_KIND,
            "Spherize",
            vec![
                p(ClipEffect::SPHERIZE_RADIUS_KEY, "Radius", "px", 0.0, 0.0, 10_000.0, 1.0, 0),
                EffectParamSpec::point(ClipEffect::SPHERIZE_CENTER_KEY, "Center of Sphere", Vec2::ZERO, "px"),
                p(ClipEffect::SPHERIZE_STRENGTH_KEY, "Strength", "%", 100.0, -100.0, 100.0, 1.0, 0),
            ],
        ),
        // Premiere's Strobe Light: flashes Strobe Duration seconds every Strobe Period; Random Strobe Probability makes
        // only some periods flash (always the same ones).
        spec(
            ClipEffect::STROBE_KIND,
            "Strobe Light",
            vec![
                EffectParamSpec::color(ClipEffect::STROBE_COLOR_KEY, "Strobe Color", EffectColor::WHITE),
                p(ClipEffect::STROBE_BLEND_KEY, "Blend With Original", "%", 0.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::STROBE_DURATION_KEY, "Strobe Duration", "s", 0.05, 0.0, 60.0, 0.01, 2),
                p(ClipEffect::STROBE_PERIOD_KEY, "Strobe Period", "s", 0.1, 0.01, 60.0, 0.01, 2),
                p(ClipEffect::STROBE_RANDOM_KEY, "Random Strobe Probability", "%", 0.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::choice(
                    ClipEffect::STROBE_MODE_KEY,
                    "Strobe",
                    &["Operates on Color Only", "Makes Layer Transparent"],
                    0,
                ),
                EffectParamSpec::choice(ClipEffect::STROBE_OPERATOR_KEY, "Strobe Operator", &STROBE_OPERATORS, 0),
            ],
        ),
        spec(
            ClipEffect::ALPHA_ADJUST_KIND,
            "Transparency",
            vec![
                p(ClipEffect::ALPHA_OPACITY_KEY, "Opacity", "%", 100.0, 0.0, 100.0, 0.5, 1),
                EffectParamSpec::checkbox(ClipEffect::ALPHA_IGNORE_KEY, "Ignore Alpha", false),
                EffectParamSpec::checkbox(ClipEffect::ALPHA_INVERT_KEY, "Invert Alpha", false),
                EffectParamSpec::checkbox(ClipEffect::ALPHA_MASK_ONLY_KEY, "Mask Only", false),
            ],
        ),
        // Premiere's Lens Distortion: Curvature below 0 bulges the picture like a fisheye, above 0 pinches it (pincushion);
        // decentering moves the lens center (% of half the frame). Fill Alpha leaves uncovered corners transparent.
        spec(
            ClipEffect::LENS_DISTORTION_KIND,
            "Lens Distortion",
            vec![
                p(ClipEffect::LENS_CURVATURE_KEY, "Curvature", "", 0.0, -100.0, 100.0, 1.0, 0),
                p(ClipEffect::LENS_V_DECENTER_KEY, "Vertical Decentering", "", 0.0, -100.0, 100.0, 1.0, 0),
                p(ClipEffect::LENS_H_DECENTER_KEY, "Horizontal Decentering", "", 0.0, -100.0, 100.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::LENS_FILL_ALPHA_KEY, "Fill Alpha", true),
                EffectParamSpec::color(ClipEffect::LENS_FILL_COLOR_KEY, "Fill Color", EffectColor::WHITE),
                EffectParamSpec::checkbox(ClipEffect::LENS_AUTO_SCALE_KEY, "Auto Scale", false), // F7.15: zoom about the lens center until no empty edge shows
            ],
        ),
        // Gradient: a linear or radial ramp from Start Color at Start Point to End Color at End Point, mixed over the picture
        // by Opacity (100 = the ramp replaces the colors; the picture's own alpha is kept). Points are px from the frame center.
        spec(
            ClipEffect::GRADIENT_KIND,
            "Gradient",
            vec![
                EffectParamSpec::choice(ClipEffect::GRADIENT_TYPE_KEY, "Type", &GRADIENT_TYPES, 0),
                EffectParamSpec::color(ClipEffect::GRADIENT_COLOR1_KEY, "Start Color", EffectColor::BLACK),
                EffectParamSpec::color(ClipEffect::GRADIENT_COLOR2_KEY, "End Color", EffectColor::WHITE),
                EffectParamSpec::point(ClipEffect::GRADIENT_START_KEY, "Start Point", Vec2::new(0.0, -400.0), "px"),
                EffectParamSpec::point(ClipEffect::GRADIENT_END_KEY, "End Point", Vec2::new(0.0, 400.0), "px"),
                p(ClipEffect::GRADIENT_BLEND_KEY, "Opacity", "%", 100.0, 0.0, 100.0, 0.5, 1),
            ],
        ),
        // Light Leak: a warm, soft light washing in from one side (screen blend), drifting with Speed; Seed picks the path.
        spec(
            ClipEffect::LIGHT_LEAK_KIND,
            "Light Leak",
            vec![
                EffectParamSpec::color(
                    ClipEffect::LEAK_COLOR1_KEY,
                    "Color 1",
                    EffectColor { red: 1.0, green: 0.55, blue: 0.15, alpha: 1.0 },
                ),
                EffectParamSpec::color(
                    ClipEffect::LEAK_COLOR2_KEY,
                    "Color 2",
                    EffectColor { red: 1.0, green: 0.25, blue: 0.45, alpha: 1.0 },
                ),
                p(ClipEffect::LEAK_INTENSITY_KEY, "Intensity", "%", 70.0, 0.0, 200.0, 1.0, 0),
                p(ClipEffect::LEAK_ANGLE_KEY, "From", deg, 300.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::LEAK_SIZE_KEY, "Size", "%", 60.0, 1.0, 300.0, 1.0, 0),
                p(ClipEffect::LEAK_SPEED_KEY, "Speed", "", 1.0, 0.0, 20.0, 0.1, 1),
                p(ClipEffect::LEAK_SEED_KEY, "Seed", "", 1.0, 0.0, 10_000.0, 1.0, 0),
            ],
        ),
        // Halftone: a rotated dot screen. Dots grow with the shadows (Black & White: ink on paper) or with the highlights
        // (Color: the picture's own colors as dots on black). Size = dot pitch in px, Softness = edge width.
        spec(
            ClipEffect::HALFTONE_KIND,
            "Halftone",
            vec![
                p(ClipEffect::HALFTONE_SIZE_KEY, "Dot Size", "px", 12.0, 2.0, 200.0, 0.5, 1),
                p(ClipEffect::HALFTONE_ANGLE_KEY, "Angle", deg, 45.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::HALFTONE_SOFTNESS_KEY, "Softness", "%", 20.0, 0.0, 100.0, 1.0, 0),
                EffectParamSpec::choice(ClipEffect::HALFTONE_MODE_KEY, "Mode", &HALFTONE_MODES, 0),
                p(ClipEffect::HALFTONE_BLEND_KEY, "Amount", "%", 100.0, 0.0, 100.0, 0.5, 1),
            ],
        ),
        // Tile: the whole picture repeated Columns x Rows times (fractions allowed, so it can zoom smoothly); Offset scrolls
        // it by a share of one tile; Mirror Edges flips every second tile so the seams match.
        spec(
            ClipEffect::TILE_KIND,
            "Tile",
            vec![
                p(ClipEffect::TILE_COLUMNS_KEY, "Columns", "", 2.0, 1.0, 20.0, 0.1, 1),
                p(ClipEffect::TILE_ROWS_KEY, "Rows", "", 2.0, 1.0, 20.0, 0.1, 1),
                p(ClipEffect::TILE_OFFSET_X_KEY, "Offset X", "%", 0.0, -1_000.0, 1_000.0, 0.5, 1),
                p(ClipEffect::TILE_OFFSET_Y_KEY, "Offset Y", "%", 0.0, -1_000.0, 1_000.0, 0.5, 1),
                EffectParamSpec::checkbox(ClipEffect::TILE_MIRROR_KEY, "Mirror Edges", false),
            ],
        ),
        // Kaleidoscope: one wedge of the picture mirrored around Center into Segments slices; Angle turns which wedge is
        // read, Zoom scales it.
        spec(
            ClipEffect::KALEIDOSCOPE_KIND,
            "Kaleidoscope",
            vec![
                EffectParamSpec::point(ClipEffect::KALEIDO_CENTER_KEY, "Center", Vec2::ZERO, "px"),
                p(ClipEffect::KALEIDO_SEGMENTS_KEY, "Segments", "", 6.0, 2.0, 32.0, 1.0, 0),
                p(ClipEffect::KALEIDO_ANGLE_KEY, "Angle", deg, 0.0, -36_000.0, 36_000.0, 1.0, 0),
                p(ClipEffect::KALEIDO_ZOOM_KEY, "Zoom", "%", 100.0, 10.0, 400.0, 0.5, 1),
            ],
        ),
        // Edge Feather: the picture's own edges fade to transparent over Feather px (a soft frame, no mask needed).
        spec(
            ClipEffect::EDGE_FEATHER_KIND,
            "Edge Feather",
            vec![p(ClipEffect::EDGE_FEATHER_AMOUNT_KEY, "Feather", "px", 40.0, 0.0, 2_000.0, 0.5, 1)],
        ),
        // Glitch Displace: horizontal bands of Block Height px slide sideways by up to Amount px (Density = share of bands),
        // red and blue split Chroma Split px; the pattern changes Rate times a second (0 holds it), Seed picks another one.
        spec(
            ClipEffect::GLITCH_KIND,
            "Glitch Displace",
            vec![
                p(ClipEffect::GLITCH_AMOUNT_KEY, "Amount", "px", 30.0, 0.0, 2_000.0, 0.5, 1),
                p(ClipEffect::GLITCH_BLOCK_KEY, "Block Height", "px", 24.0, 1.0, 500.0, 0.5, 1),
                p(ClipEffect::GLITCH_SPLIT_KEY, "Chroma Split", "px", 6.0, 0.0, 200.0, 0.5, 1),
                p(ClipEffect::GLITCH_DENSITY_KEY, "Density", "%", 40.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::GLITCH_RATE_KEY, "Rate", "", 8.0, 0.0, 60.0, 0.5, 1),
                p(ClipEffect::GLITCH_SEED_KEY, "Seed", "", 1.0, 0.0, 10_000.0, 1.0, 0),
            ],
        ),
        // C5 Outline: a stroke around the picture's alpha edge (cutouts, stickers, keyed footage; on a full frame it frames
        // the picture). Text and shapes keep their own stroke in the Graphics panel.
        spec(
            ClipEffect::OUTLINE_KIND,
            "Outline",
            vec![
                p(ClipEffect::OUTLINE_WIDTH_KEY, "Width", "px", 12.0, 0.0, 500.0, 0.5, 1),
                EffectParamSpec::color(ClipEffect::OUTLINE_COLOR_KEY, "Color", EffectColor::WHITE),
                p(ClipEffect::OUTLINE_SOFTNESS_KEY, "Softness", "px", 0.0, 0.0, 200.0, 0.5, 1),
                EffectParamSpec::choice(ClipEffect::OUTLINE_POSITION_KEY, "Position", &OUTLINE_POSITIONS, 0),
            ],
        ),
        // C5 Long Shadow: the silhouette dragged along Angle (0 = up, clockwise) for Length px, fading out by Fade.
        spec(
            ClipEffect::LONG_SHADOW_KIND,
            "Long Shadow",
            vec![
                p(ClipEffect::LONG_SHADOW_ANGLE_KEY, "Angle", deg, 135.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::LONG_SHADOW_LENGTH_KEY, "Length", "px", 200.0, 0.0, 4_000.0, 0.5, 1),
                EffectParamSpec::color(ClipEffect::LONG_SHADOW_COLOR_KEY, "Color", EffectColor::BLACK),
                p(ClipEffect::LONG_SHADOW_FADE_KEY, "Fade", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::LONG_SHADOW_OPACITY_KEY, "Opacity", "%", 80.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
    ]
}
