// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectsEvaluation.swift, EffectsCatalog.swift (`imageFilter`), RollingShutter.swift (`rollingShutterFilter`),
// TrackMaskEffect.swift (`trackMaskShape`), AnonymizeOrder.swift (`movesPixels`)
//! Evaluated clip effects at one instant (siblings of `ClipTransform`, already clamped). The effect list is walked in
//! order and cut into segments at every active blur, so [Blur, Ultra Key] keys the blurred picture and [Ultra Key, Blur]
//! blurs the keyed one. Without any effect there are no segments.

use crate::effect_transform_stage::ClipEffectStage;
use crate::style_effects::ClipEffectStyleExt;
use crate::temporal_effects::{TemporalEffectEval, TemporalFilter};
use sq_core_color::{
    ActiveGrade, Aged, ChromaBleed, ClipEffectColorExt, ClipGradeExt, ColorEffectScaleExt, FilmLook, GateWeave, Grain,
    Scanlines, Tracking,
};
use sq_core_masks::{
    AnonymizeOrderExt, ClipEffectStabilizeExt, ClipMasksExt, IN_PLACE_KINDS, MaskInputsExt, MaskShape, Stabilizer,
    StabilizerEdgeFill, StabilizerMethod, stabilize_perspective_keys,
};
use sq_core_model::{Affine2, Clip, ClipEffect, ColorEffect, MaskMode, MaskSource, MatteChannel, StageTransform};
use sq_core_time::{Id, Time, Vec2};
use std::f64::consts::PI;

/// Crop insets as fractions (0...1) of the clip's own frame.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CropInsets {
    /// Left inset.
    pub left: f64,
    /// Top inset.
    pub top: f64,
    /// Right inset.
    pub right: f64,
    /// Bottom inset.
    pub bottom: f64,
}

impl CropInsets {
    /// No crop.
    pub const NONE: CropInsets = CropInsets { left: 0.0, top: 0.0, right: 0.0, bottom: 0.0 };

    /// Nothing is cropped.
    pub fn is_identity(&self) -> bool {
        self.left == 0.0 && self.top == 0.0 && self.right == 0.0 && self.bottom == 0.0
    }

    /// Nothing is left of the picture.
    pub fn is_empty(&self) -> bool {
        self.left + self.right >= 1.0 || self.top + self.bottom >= 1.0
    }

    /// The larger inset per edge: two crops in a row keep what both keep.
    pub fn merged(&self, o: &CropInsets) -> CropInsets {
        CropInsets {
            left: self.left.max(o.left),
            top: self.top.max(o.top),
            right: self.right.max(o.right),
            bottom: self.bottom.max(o.bottom),
        }
    }
}

/// Crop and Rounded Corners as one coverage mask on the layer rectangle. The order of the two matters:
/// - `round_first` false (Crop, then Rounded Corners): the radius rounds the corners of the cropped rectangle;
/// - `round_first` true (Rounded Corners, then Crop): the frame is rounded first, the crop then cuts straight edges into it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct EffectMasks {
    /// The crop.
    pub crop: CropInsets,
    /// Canvas pixels of the clip's own frame, >= 0.
    pub corner_radius: f64,
    /// Rounded Corners before Crop.
    pub round_first: bool,
    /// Crop Softness: width of the soft edge inside the mask, canvas pixels of the clip's own frame (like
    /// `corner_radius`); 0 = the one pixel anti-aliased edge.
    pub feather: f64,
}

impl EffectMasks {
    /// No mask.
    pub const NONE: EffectMasks =
        EffectMasks { crop: CropInsets::NONE, corner_radius: 0.0, round_first: false, feather: 0.0 };

    /// Nothing to do.
    pub fn is_identity(&self) -> bool {
        self.crop.is_identity() && self.corner_radius == 0.0 && self.feather == 0.0
    }

    /// Adds Rounded Corners after what is already here, or `None` when one mask cannot express the pair (Crop, Rounded
    /// Corners, Crop again): the caller then starts a new pass.
    pub(crate) fn adding_radius(&self, r: f64) -> Option<EffectMasks> {
        let mut m = *self;
        if self.corner_radius == 0.0 {
            m.corner_radius = r;
            m.round_first = false;
            return Some(m);
        }
        // A radius exists: with no crop, or in the order Crop then Rounded Corners, the larger radius stands for both.
        if self.crop.is_identity() || !self.round_first {
            m.corner_radius = self.corner_radius.max(r);
            return Some(m);
        }
        None // Rounded Corners, Crop, Rounded Corners: not one mask
    }

    /// Adds a Crop after what is already here (see `adding_radius`). Two Crops in one mask keep the softer edge.
    pub(crate) fn adding_crop(&self, c: &CropInsets, f: f64) -> Option<EffectMasks> {
        let mut m = *self;
        m.feather = self.feather.max(f);
        if self.corner_radius == 0.0 {
            m.crop = self.crop.merged(c);
            return Some(m);
        }
        if self.crop.is_identity() {
            m.crop = *c;
            m.round_first = true;
            return Some(m);
        }
        if self.round_first {
            m.crop = self.crop.merged(c);
            return Some(m);
        }
        None
    }
}

/// Chroma key or luma key mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChromaKeyMode {
    /// Ultra Key.
    Chroma = 0,
    /// Luma key.
    Luma = 1,
}

/// What a keyed layer shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChromaKeyOutput {
    /// The keyed picture.
    Composite = 0,
    /// The matte as black / white.
    Alpha = 1,
    /// The picture before keying.
    Source = 2,
}

impl ChromaKeyOutput {
    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<ChromaKeyOutput> {
        match raw {
            0 => Some(ChromaKeyOutput::Composite),
            1 => Some(ChromaKeyOutput::Alpha),
            2 => Some(ChromaKeyOutput::Source),
            _ => None,
        }
    }
}

/// One key at one instant, in the units the renderer uses (degrees of hue). A chroma key (Ultra Key) or a luma key; both
/// share the matte clean-up (shrink / grow, contrast, midpoint) and the output view.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChromaKey {
    /// Chroma or luma.
    pub mode: ChromaKeyMode,
    /// Hue to remove, 0...360.
    pub hue: f64,
    /// Pixels within this many degrees of `hue` are keyed out completely.
    pub half_width: f64,
    /// Width in degrees of the soft edge beyond `half_width` (at least 1).
    pub soft: f64,
    /// Share (0...1) of the colored spill near the key hue that is desaturated.
    pub spill: f64,
    /// -1...1: shrinks (positive) or grows (negative) the kept picture.
    pub choke: f64,
    /// Matte values below this (0...1) are treated as not keyed at all.
    pub pedestal: f64,
    /// The output view.
    pub output: ChromaKeyOutput,
    /// 0...1 matte contrast.
    pub contrast: f64,
    /// 0...1 matte midpoint.
    pub midpoint: f64,
    /// 0...1: how much of bright pixels are kept regardless of the key.
    pub keep_highlights: f64,
    /// 0...1: how much of dark pixels are kept regardless of the key.
    pub keep_shadows: f64,
    /// 0...1: how far around the key hue spill is desaturated (0.5 = the original zone).
    pub spill_range: f64,
    /// Saturation factor of the kept picture (1 = unchanged).
    pub saturation: f64,
    /// Hue shift in degrees of the kept picture.
    pub hue_shift: f64,
    /// Luma factor of the kept picture (1 = unchanged).
    pub luma: f64,
    /// Luma key: encoded luma (0...1) where keying ends or starts.
    pub luma_threshold: f64,
    /// Luma key: the width of the ramp beyond the threshold (0...1).
    pub luma_softness: f64,
    /// Luma key: which side is removed.
    pub luma_keys_brights: bool,
}

impl ChromaKey {
    /// Most keys the renderer applies in one pass.
    pub const MAX_PER_LAYER: usize = 2;

    /// A chroma key with the Swift defaults for everything the arguments do not name.
    pub fn new(hue: f64, half_width: f64, soft: f64, spill: f64, choke: f64, pedestal: f64) -> ChromaKey {
        ChromaKey {
            mode: ChromaKeyMode::Chroma,
            hue,
            half_width,
            soft,
            spill,
            choke,
            pedestal,
            output: ChromaKeyOutput::Composite,
            contrast: 0.0,
            midpoint: 0.5,
            keep_highlights: 0.0,
            keep_shadows: 0.0,
            spill_range: 0.5,
            saturation: 1.0,
            hue_shift: 0.0,
            luma: 1.0,
            luma_threshold: 0.0,
            luma_softness: 0.0,
            luma_keys_brights: false,
        }
    }

    /// A luma key: removes pixels darker (or brighter) than `threshold`, with a ramp of `softness`.
    pub fn luma_key(threshold: f64, softness: f64, brights: bool) -> ChromaKey {
        ChromaKey {
            mode: ChromaKeyMode::Luma,
            luma_threshold: threshold,
            luma_softness: softness,
            luma_keys_brights: brights,
            ..ChromaKey::new(0.0, 0.0, 1.0, 0.0, 0.0, 0.0)
        }
    }

    /// Output "Alpha": show the matte (white = kept, black = keyed) instead of the keyed picture.
    pub fn matte_output(&self) -> bool {
        self.output == ChromaKeyOutput::Alpha
    }

    /// Sets or clears the Alpha output.
    pub fn set_matte_output(&mut self, on: bool) {
        self.output = if on { ChromaKeyOutput::Alpha } else { ChromaKeyOutput::Composite };
    }

    /// True when the color correction changes anything.
    pub fn corrects_color(&self) -> bool {
        self.saturation != 1.0 || self.hue_shift != 0.0 || self.luma != 1.0
    }
}

/// One Drop Shadow at one instant, in px of the clip's own frame (y down).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DropShadow {
    /// Display-encoded (BT.709 OETF) 0...1 channels as picked in the color well; the renderer linearises them.
    pub color: [f64; 3],
    /// 0...1.
    pub opacity: f64,
    /// Offset in px.
    pub dx: f64,
    /// Offset in px, y down.
    pub dy: f64,
    /// Gaussian sigma in px (0.2 x Softness, see `ClipEffect::SHADOW_SIGMA_PER_SOFTNESS`).
    pub sigma: f64,
    /// 0...1: how far the blurred edge is pushed outwards (Photoshop's Spread / choke).
    pub spread: f64,
    /// Draw only the shadow, not the picture.
    pub shadow_only: bool,
}

impl DropShadow {
    /// The offset length.
    pub fn distance(&self) -> f64 {
        (self.dx * self.dx + self.dy * self.dy).sqrt()
    }

    /// How far (px) the shadow can reach beyond the picture: offset plus three sigma.
    pub fn margin(&self) -> f64 {
        self.distance() + 3.0 * self.sigma * (1.0 + self.spread)
    }
}

/// Where an Outline sits against the picture's edge (stored as the effect's choice index).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OutlinePosition {
    /// Under the picture, around it.
    Outside = 0,
    /// Over the picture, within it.
    Inside = 1,
    /// Over the picture, half each side.
    Centre = 2,
}

impl OutlinePosition {
    /// Every case in raw order.
    pub const ALL: [OutlinePosition; 3] = [OutlinePosition::Outside, OutlinePosition::Inside, OutlinePosition::Centre];

    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<OutlinePosition> {
        usize::try_from(raw).ok().and_then(|i| Self::ALL.get(i).copied())
    }
}

/// A whole-picture effect at one instant (W3.1), in px of the clip's own frame (y down). Like a blur or a shadow it ends
/// its segment: the renderer runs it on the image the segment's masks and keys made.
#[derive(Clone, Debug, PartialEq)]
pub enum ImageFilter {
    /// p + amount * (p - mean of its 3 x 3 neighborhood); amount 1 = Sharpen Amount 100.
    Sharpen {
        /// Strength.
        amount: f64,
    },
    /// p + amount * (p - Gaussian(sigma px)) where the largest channel difference exceeds `threshold` (0...1, working
    /// linear); the blur repeats the picture's edge pixels. Amount 1 = Unsharp Mask Amount 100.
    UnsharpMask {
        /// Blur sigma in px.
        sigma: f64,
        /// Strength.
        amount: f64,
        /// Difference threshold.
        threshold: f64,
    },
    /// Box smear along (dx, dy), the whole length, centered on each pixel.
    DirectionalBlur {
        /// Smear x.
        dx: f64,
        /// Smear y.
        dy: f64,
    },
    /// Reflection line through `center` (offset from the frame center, px, y down); `angle` degrees, 0 = left onto
    /// right, 90 = top onto bottom (the side the normal (cos, sin) points to shows the other side).
    Mirror {
        /// A point on the line.
        center: Vec2,
        /// Line angle in degrees.
        angle: f64,
    },
    /// `amount` 0...1; `seed` changes per instant so the grain moves.
    Noise {
        /// Strength.
        amount: f64,
        /// Colored noise.
        color: bool,
        /// Clip the result.
        clip: bool,
        /// Noise pattern id.
        seed: u32,
    },
    /// `threshold` 0...1 luma; `sigma` px; `color` display-encoded tint, `None` = the picture's own colors.
    Glow {
        /// Luma threshold.
        threshold: f64,
        /// Blur sigma in px.
        sigma: f64,
        /// Strength.
        intensity: f64,
        /// Tint.
        color: Option<[f64; 3]>,
    },
    /// Blocks over the frame, average color each (or the block's center pixel when `sharp`).
    Mosaic {
        /// Blocks across.
        columns: i64,
        /// Blocks down.
        rows: i64,
        /// Center pixel instead of the average.
        sharp: bool,
    },
    /// Lumetri-style vignette: `amount` stops (-5...5), `midpoint` 0...1, `roundness` -1...1, `feather` 0...1.
    Vignette {
        /// Stops.
        amount: f64,
        /// Midpoint.
        midpoint: f64,
        /// Roundness.
        roundness: f64,
        /// Feather.
        feather: f64,
    },
    /// Red moved by (dx, dy), blue by -(dx, dy); `radial`: the length grows from 0 at the center to |d| at the corners
    /// and points away from the center. `mix` = Blend With Original 0...1.
    RgbSplit {
        /// Shift x.
        dx: f64,
        /// Shift y.
        dy: f64,
        /// Radial instead of constant.
        radial: bool,
        /// Blend With Original.
        mix: f64,
    },
    /// Spin: `amount` degrees around `center`; zoom: `amount` % of the distance to it.
    RadialBlur {
        /// Center.
        center: Vec2,
        /// Degrees or percent.
        amount: f64,
        /// Zoom instead of spin.
        zoom: bool,
        /// High quality.
        high: bool,
    },
    /// Flip.
    Flip {
        /// Mirror left to right.
        horizontal: bool,
        /// Mirror top to bottom.
        vertical: bool,
    },
    /// `channel`: 0 RGB, 1 red, 2 green, 3 blue, 4 alpha. `blend` = Blend With Original 0...1.
    Invert {
        /// Channel choice.
        channel: i64,
        /// Blend With Original.
        blend: f64,
    },
    /// Posterize.
    Posterize {
        /// Levels per channel.
        levels: i64,
    },
    /// Luma mapped from `black` to `white` (display-encoded), mixed in by `amount` 0...1.
    Tint {
        /// Color for black.
        black: [f64; 3],
        /// Color for white.
        white: [f64; 3],
        /// Mix.
        amount: f64,
    },
    /// Both -1...1.
    BrightnessContrast {
        /// Brightness.
        brightness: f64,
        /// Contrast.
        contrast: f64,
    },
    /// `angle` degrees at the center; `radius` = share of the frame's longer side.
    Twirl {
        /// Center.
        center: Vec2,
        /// Degrees.
        angle: f64,
        /// Radius.
        radius: f64,
    },
    /// Each corner of the picture moved by its offset (px from the corner, y down); the picture is stretched to that
    /// quadrilateral in perspective, transparent outside it.
    CornerPin {
        /// Offset of the top left corner.
        top_left: Vec2,
        /// Offset of the top right corner.
        top_right: Vec2,
        /// Offset of the bottom right corner.
        bottom_right: Vec2,
        /// Offset of the bottom left corner.
        bottom_left: Vec2,
    },
    /// `type_` 0 sine, 1 square, 2 triangle, 3 sawtooth; `height`/`width` px; `direction` degrees (0 up, clockwise);
    /// `phase` 0..<1 cycles; `pinning` 0 none, 1 all edges, 2 horizontal edges, 3 vertical edges.
    WaveWarp {
        /// Wave type.
        wave_type: i64,
        /// Height in px.
        height: f64,
        /// Width in px.
        width: f64,
        /// Direction in degrees.
        direction: f64,
        /// Phase in cycles.
        phase: f64,
        /// Pinning choice.
        pinning: i64,
    },
    /// `radius` px; `strength` -1...1 (negative pinches).
    Spherize {
        /// Center.
        center: Vec2,
        /// Radius in px.
        radius: f64,
        /// Strength.
        strength: f64,
    },
    /// A flash: `color` display-encoded, `op` 0 copy, 1 add, 2 multiply, 3 screen, 4 difference; `transparent` hides the
    /// picture instead. `blend` = Blend With Original 0...1.
    Strobe {
        /// Flash color.
        color: [f64; 3],
        /// Blend With Original.
        blend: f64,
        /// Operator choice.
        op: i64,
        /// Hide the picture instead.
        transparent: bool,
    },
    /// `opacity` 0...1 multiplies alpha after Ignore / Invert; Mask Only draws the alpha as white.
    AlphaAdjust {
        /// Opacity.
        opacity: f64,
        /// Ignore the alpha.
        ignore: bool,
        /// Invert the alpha.
        invert: bool,
        /// Draw the alpha as white.
        mask_only: bool,
    },
    /// `curvature` -1...1 (negative bulges); `decenter` share of half the frame; outside the picture: transparent
    /// (`fill_alpha`) or `fill` (display-encoded). `exact_model` false = the look of effects saved before F7.15.
    LensDistortion {
        /// Curvature.
        curvature: f64,
        /// Decenter.
        decenter: Vec2,
        /// Transparent outside.
        fill_alpha: bool,
        /// Fill color outside.
        fill: [f64; 3],
        /// Scale to hide the border.
        auto_scale: bool,
        /// The exact lens model.
        exact_model: bool,
    },
    /// Linear or radial ramp from `color1` at `start` to `color2` at `end` (display-encoded colors; points are offsets
    /// from the frame center, px, y down), mixed over the picture by `blend` 0...1; alpha kept.
    Gradient {
        /// Start color.
        color1: [f64; 3],
        /// End color.
        color2: [f64; 3],
        /// Start point.
        start: Vec2,
        /// End point.
        end: Vec2,
        /// Radial instead of linear.
        radial: bool,
        /// Mix.
        blend: f64,
    },
    /// A rotated dot screen: `size` px pitch, `angle` degrees, `softness` 0...1 edge width; `color` = bright dots in the
    /// picture's colors on black instead of ink on white. `blend` = Amount 0...1.
    Halftone {
        /// Pitch in px.
        size: f64,
        /// Degrees.
        angle: f64,
        /// Edge width.
        softness: f64,
        /// Colored dots.
        color: bool,
        /// Amount.
        blend: f64,
    },
    /// The picture repeated `columns` x `rows` times, scrolled by `offset` (share of a tile); `mirror` flips alternate
    /// tiles.
    Tile {
        /// Columns.
        columns: f64,
        /// Rows.
        rows: f64,
        /// Scroll.
        offset: Vec2,
        /// Flip alternate tiles.
        mirror: bool,
    },
    /// A wedge mirrored into `segments` slices around `center` (px from the frame center); `angle` degrees; `zoom` 1 = as is.
    Kaleidoscope {
        /// Center.
        center: Vec2,
        /// Slices.
        segments: i64,
        /// Degrees.
        angle: f64,
        /// Zoom.
        zoom: f64,
    },
    /// The picture's alpha fading to 0 over `amount` px (clip px) inward from the frame edges (smoothstep).
    EdgeFeather {
        /// Width in px.
        amount: f64,
    },
    /// Digital glitch: horizontal bands `block` px high; a share `density` 0...1 of them (chosen by `seed`) slides sideways
    /// by up to +-`amount` px; red and blue are pulled `split` px apart horizontally.
    Glitch {
        /// Slide in px.
        amount: f64,
        /// Band height in px.
        block: f64,
        /// Channel split in px.
        split: f64,
        /// Share of bands.
        density: f64,
        /// Band choice seed.
        seed: i64,
    },
    /// A light leak.
    LightLeak {
        /// Start color.
        color1: [f64; 3],
        /// End color.
        color2: [f64; 3],
        /// Strength.
        intensity: f64,
        /// Center.
        center: Vec2,
        /// Size.
        size: f64,
        /// Radians.
        angle: f64,
    },
    /// A Transform effect with a mask input, drawn on the picture: the output point p (px from the frame center, y down)
    /// reads the picture at (a p.x + b p.y + tx, c p.x + d p.y + ty), times `opacity` (the stage's inverse map).
    StageWarp {
        /// Matrix a.
        a: f64,
        /// Matrix b.
        b: f64,
        /// Matrix c.
        c: f64,
        /// Matrix d.
        d: f64,
        /// Translation x.
        tx: f64,
        /// Translation y.
        ty: f64,
        /// Opacity.
        opacity: f64,
    },
    /// The Stabilizer's correction as a picture warp (same inverse map as `StageWarp`, no opacity) whose reads past the
    /// picture's edge are filled: `Mirror` folds them back over the edge, `Blur` also blurs them wide (Edge Fill).
    StageFill {
        /// Matrix a.
        a: f64,
        /// Matrix b.
        b: f64,
        /// Matrix c.
        c: f64,
        /// Matrix d.
        d: f64,
        /// Translation x.
        tx: f64,
        /// Translation y.
        ty: f64,
        /// What fills the border.
        fill: StabilizerEdgeFill,
    },
    /// Rolling shutter correction: rows shifted back by `shear` (fraction of the scan extent) times their scan position.
    RollingShutter {
        /// Shear.
        shear: Vec2,
        /// Scan along x.
        along_x: bool,
    },
    /// The Stabilizer's one warp pass when it also carries the residual perspective: the Rolling Shutter shear (zero when
    /// the option is off) and the correction homography `perspective` (8 terms, picture px about the frame center): the
    /// output point p reads the picture at the rolling shutter source of (I + perspective)^-1 p.
    StabilizeWarp {
        /// Shear.
        shear: Vec2,
        /// Scan along x.
        along_x: bool,
        /// The 8 homography terms.
        perspective: Vec<f64>,
    },
    /// C5 Outline: a stroke `width` px (clip px) along the picture's alpha edge (alpha 0.5), in `color` (display-encoded),
    /// its edge ramped over `softness` px.
    Outline {
        /// Stroke width in px.
        width: f64,
        /// Stroke color.
        color: [f64; 3],
        /// Edge ramp in px.
        softness: f64,
        /// Where the stroke sits.
        position: OutlinePosition,
    },
    /// C5 Long Shadow: the picture's silhouette dragged `length` px along `angle` (degrees, 0 = up, clockwise), under the
    /// picture, in `color` at `opacity`; its alpha falls linearly by `fade` (0...1) over the length.
    LongShadow {
        /// Degrees.
        angle: f64,
        /// Length in px.
        length: f64,
        /// Shadow color.
        color: [f64; 3],
        /// Fade over the length.
        fade: f64,
        /// Opacity.
        opacity: f64,
    },
}

impl ImageFilter {
    /// Unit direction (y down) a Long Shadow runs for `degrees` (the RGB Split convention: 0 = up, clockwise).
    pub fn long_shadow_direction(degrees: f64) -> Vec2 {
        let a = degrees * PI / 180.0;
        Vec2::new(a.sin(), -a.cos())
    }

    /// The picture warp of a transform stage; `None` for the identity. A stage scaled to 0 shows nothing (opacity 0).
    pub fn stage(s: &StageTransform) -> Option<ImageFilter> {
        if s.is_identity() {
            return None;
        }
        let f = Affine2::from(s);
        let det = f.a * f.d - f.b * f.c;
        let opacity = s.opacity.clamp(0.0, 1.0);
        if !(det.abs() > 1e-12 && s.scale > 0.0 && s.scale_y() > 0.0) {
            return Some(ImageFilter::StageWarp { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0, opacity: 0.0 });
        }
        let a = f.d / det;
        let b = -f.b / det;
        let c = -f.c / det;
        let d = f.a / det;
        Some(ImageFilter::StageWarp { a, b, c, d, tx: -(a * f.t.x + b * f.t.y), ty: -(c * f.t.x + d * f.t.y), opacity })
    }

    /// The Stabilizer's correction `s` as a filling picture warp; `None` for the identity or `Zoom` (that one moves the
    /// clip).
    pub fn stage_fill(s: &StageTransform, fill: StabilizerEdgeFill) -> Option<ImageFilter> {
        if fill == StabilizerEdgeFill::Zoom {
            return None;
        }
        let Some(ImageFilter::StageWarp { a, b, c, d, tx, ty, .. }) = Self::stage(s) else { return None };
        if !(s.scale > 0.0 && s.scale_y() > 0.0) {
            return None;
        }
        Some(ImageFilter::StageFill { a, b, c, d, tx, ty, fill })
    }

    /// How far (px) the result can reach beyond the picture.
    pub fn margin(&self) -> f64 {
        match self {
            ImageFilter::DirectionalBlur { dx, dy } => (dx * dx + dy * dy).sqrt() / 2.0,
            ImageFilter::Glow { sigma, .. } => 3.0 * sigma,
            ImageFilter::RgbSplit { dx, dy, .. } => (dx * dx + dy * dy).sqrt(),
            ImageFilter::WaveWarp { height, .. } => height.abs(),
            ImageFilter::Outline { width, softness, position, .. } => match position {
                OutlinePosition::Outside => width + softness + 1.0,
                OutlinePosition::Centre => width / 2.0 + softness + 1.0,
                OutlinePosition::Inside => 1.0,
            },
            ImageFilter::LongShadow { length, .. } => length + 1.0,
            _ => 0.0,
        }
    }

    /// `margin` per axis (x, y), applied on both sides of that axis so the picture stays centered. Long Shadow only grows
    /// along the axes its angle runs on (a sideways shadow adds no rows); every other filter uses `margin` on both.
    pub fn axis_margin(&self) -> Vec2 {
        if let ImageFilter::LongShadow { angle, length, .. } = self {
            let d = Self::long_shadow_direction(*angle);
            return Vec2::new(d.x.abs() * length + 1.0, d.y.abs() * length + 1.0);
        }
        let m = self.margin();
        Vec2::new(m, m)
    }
}

/// What happens to the picture between two blurs: masks and keys. They commute with each other (both only change alpha or
/// per-pixel color), so they share one pass; a blur is a neighborhood operation and ends the segment.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EffectSegment {
    /// Crop and Rounded Corners.
    pub masks: EffectMasks,
    /// Keys, at most `ChromaKey::MAX_PER_LAYER` per pass.
    pub keys: Vec<ChromaKey>,
    /// Gaussian sigma in px applied after this segment's masks and keys; 0 = none. A segment with 0 that is not the last
    /// one is an extra pass (the effects before and after it could not be merged).
    pub blur_after: f64,
    /// `blur_after` repeats the edge pixels outside the picture and is cut to the picture (Repeat Edge Pixels): the edge
    /// stays opaque and the image does not grow. Off: zero outside, the blur spreads past the picture.
    pub blur_repeats_edges: bool,
    /// Drop Shadow cast by this segment's picture (after masks and keys). Never set together with `blur_after`.
    pub shadow: Option<DropShadow>,
    /// Whole-picture effect run on this segment's picture (after masks and keys). Never set together with `blur_after` or
    /// `shadow`.
    pub filter: Option<ImageFilter>,
    /// Unified masks: the input masks of the effect that made `blur_after` / `filter` (top first). Not empty: the
    /// renderer mixes the blurred or filtered picture over the picture before it by their coverage, so the effect shows
    /// only there. Empty = everywhere. A segment with `keys`, a `scope` and nothing else: the scope limits the keys.
    pub scope: Vec<MaskShape>,
    /// A Color effect with a mask input, run on this segment's picture (after masks and keys) as its own grade
    /// (display-referred, like a later Color effect); `scope` limits it. Never set together with `blur_after`, `shadow`
    /// or `filter`.
    pub grade: Option<ColorEffect>,
}

impl EffectSegment {
    pub(crate) fn is_plain(&self) -> bool {
        self.masks.is_identity()
            && self.keys.is_empty()
            && self.shadow.is_none()
            && self.filter.is_none()
            && self.grade.is_none()
    }

    /// The scope limits this segment's keys (a masked key is a pass of its own).
    pub fn scopes_keys(&self) -> bool {
        !self.scope.is_empty()
            && !self.keys.is_empty()
            && self.blur_after == 0.0
            && self.shadow.is_none()
            && self.filter.is_none()
            && self.grade.is_none()
    }
}

/// Evaluated clip effects at one instant (siblings of `ClipTransform`, already clamped).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClipEffects {
    /// The passes, cut at every active blur.
    pub segments: Vec<EffectSegment>,
    /// Film Grain, Gate Weave, Scanlines, Chroma Bleed, Tracking Noise: one pass after all segments.
    pub look: FilmLook,
    /// W6.7 clip masks (Opacity masks), top first: cut the finished picture of all segments, in the clip's own frame.
    pub masks: Vec<MaskShape>,
    /// Video Denoise / Deflicker / Trails: run on the decoded source frame (with its neighbors) before everything else.
    /// Not part of `is_identity` (the frame is replaced before the effect chain).
    pub temporal: Option<TemporalFilter>,
    /// Motion's Anti-flicker Filter at this instant, 0...1: a vertical-only softening of the clip's picture before its
    /// effects. 0 = untouched (no pass runs).
    pub anti_flicker: f64,
}

impl ClipEffects {
    /// No effects.
    pub fn none() -> ClipEffects {
        ClipEffects::default()
    }

    /// Segments, clip masks and film look.
    pub fn new(segments: Vec<EffectSegment>, masks: Vec<MaskShape>, look: FilmLook) -> ClipEffects {
        ClipEffects { segments, masks, look, ..ClipEffects::default() }
    }

    /// Simple form: masks before a blur, the blur, masks after it (what most clips have).
    pub fn simple(pre: EffectMasks, blur: f64, post: EffectMasks, keys: Vec<ChromaKey>) -> ClipEffects {
        let segments = if blur > 0.0 {
            vec![
                EffectSegment { masks: pre, keys, blur_after: blur, ..EffectSegment::default() },
                EffectSegment { masks: post, ..EffectSegment::default() },
            ]
        } else if !pre.is_identity() || !keys.is_empty() {
            vec![EffectSegment { masks: pre, keys, ..EffectSegment::default() }]
        } else {
            Vec::new()
        };
        ClipEffects { segments, ..ClipEffects::default() }
    }

    /// Only Rounded Corners.
    pub fn with_corner_radius(corner_radius: f64) -> ClipEffects {
        Self::simple(EffectMasks { corner_radius, ..EffectMasks::NONE }, 0.0, EffectMasks::NONE, Vec::new())
    }

    /// Masks of the first pass (the whole stack when there is no blur).
    pub fn pre(&self) -> EffectMasks {
        self.segments.first().map_or(EffectMasks::NONE, |s| s.masks)
    }

    /// Sets the masks of the first pass.
    pub fn set_pre(&mut self, m: EffectMasks) {
        if self.segments.is_empty() {
            self.segments = vec![EffectSegment::default()];
        }
        self.segments[0].masks = m;
    }

    /// Masks of the last pass when a blur comes before it.
    pub fn post(&self) -> EffectMasks {
        if self.segments.len() > 1 { self.segments[self.segments.len() - 1].masks } else { EffectMasks::NONE }
    }

    /// Sets the masks of the last pass.
    pub fn set_post(&mut self, m: EffectMasks) {
        if self.segments.len() < 2 {
            let first = self.segments.first().cloned().unwrap_or_default();
            self.segments = vec![first, EffectSegment::default()];
        }
        let last = self.segments.len() - 1;
        self.segments[last].masks = m;
    }

    /// All blurs together (Gaussians add in quadrature).
    pub fn blur(&self) -> f64 {
        self.segments.iter().map(|s| s.blur_after * s.blur_after).fold(0.0, |a, b| a + b).sqrt()
    }

    /// Sets the blur on the first pass.
    pub fn set_blur(&mut self, v: f64) {
        if v.is_nan() || v <= 0.0 {
            self.segments = self
                .segments
                .iter()
                .map(|s| EffectSegment { blur_after: 0.0, ..s.clone() })
                .filter(|s| !s.is_plain())
                .collect();
            return;
        }
        if self.segments.is_empty() {
            self.segments = vec![EffectSegment::default(), EffectSegment::default()];
        }
        if self.segments.len() < 2 {
            self.segments.push(EffectSegment::default());
        }
        self.segments[0].blur_after = v;
    }

    /// Every key of every pass.
    pub fn keys(&self) -> Vec<ChromaKey> {
        self.segments.iter().flat_map(|s| s.keys.iter().copied()).collect()
    }

    /// Sets the keys of the first pass.
    pub fn set_keys(&mut self, keys: Vec<ChromaKey>) {
        if self.segments.is_empty() {
            self.segments = vec![EffectSegment::default()];
        }
        self.segments[0].keys = keys;
    }

    /// Rounded Corners radius of the first pass.
    pub fn corner_radius(&self) -> f64 {
        self.pre().corner_radius
    }

    /// Nothing to do: the renderer takes the plain path and runs none of the effect maths.
    pub fn is_identity(&self) -> bool {
        self.masks.is_empty()
            && self.segments.iter().all(|s| s.is_plain() && s.blur_after == 0.0)
            && self.segments.len() <= 1
            && self.look.is_identity()
            && self.anti_flicker == 0.0
    }

    /// A crop took away the whole picture: the layer draws nothing.
    pub fn is_empty(&self) -> bool {
        self.segments.iter().any(|s| s.masks.crop.is_empty())
    }
}

/// One Magic mask a layer evaluates (`ClipEffects::magic_mattes`).
#[derive(Clone, Debug, PartialEq)]
pub struct MagicMatteUse {
    /// The mask's matte key.
    pub mask: Id,
    /// The cache key of the matte it draws.
    pub cache_key: String,
    /// Edge softness in clip frame px.
    pub feather: f64,
    /// Edge expansion in clip frame px.
    pub expansion: f64,
    /// Masks made by Anonymize: the base key of the matte.
    pub base_key: Option<String>,
    /// Masks made by Anonymize: the matte must cover.
    pub must_cover: bool,
}

impl ClipEffects {
    /// Magic masks evaluated anywhere in the clip (Opacity or an effect's input): the renderer needs their mattes keyed by
    /// mask id.
    pub fn magic_matte_keys(&self) -> Vec<Id> {
        self.magic_mattes().into_iter().map(|m| m.mask).collect()
    }

    /// Each Magic mask once: its id, the cache key of the matte it draws and its edge (Feather / Expansion, clip frame px).
    pub fn magic_mattes(&self) -> Vec<MagicMatteUse> {
        let mut out: Vec<MagicMatteUse> = Vec::new();
        let scoped = self.segments.iter().flat_map(|s| s.scope.iter());
        for m in self.masks.iter().chain(scoped).filter(|m| m.source == MaskSource::Magic) {
            if let Some(k) = m.matte_key
                && !out.iter().any(|u| u.mask == k)
            {
                out.push(MagicMatteUse {
                    mask: k,
                    cache_key: m.matte_cache_key.clone().unwrap_or_default(),
                    feather: m.feather,
                    expansion: m.expansion,
                    base_key: m.matte_base_key.clone(),
                    must_cover: m.matte_must_cover,
                });
            }
        }
        out
    }

    /// An enabled subject mask is evaluated: the renderer has to segment the decoded frame.
    pub fn needs_subject_matte(&self) -> bool {
        self.masks.iter().any(|m| m.source == MaskSource::Subject)
            || self.segments.iter().any(|s| s.scope.iter().any(|m| m.source == MaskSource::Subject))
    }
}

/// Filters and mask shapes an effect makes at one instant (Swift `extension ClipEffect`).
pub trait ClipEffectFilters {
    /// The W3.1 filter this effect makes at clip-local `t`, or `None` when it is not such an effect or does nothing.
    fn image_filter(&self, t: Time) -> Option<ImageFilter>;

    /// The row shift a Standard Stabilizer with Rolling Shutter on applies at clip-local `t`; `None` when the option is
    /// off, nothing was measured or the picture stands still (no pass is planned then).
    fn rolling_shutter_filter(&self, t: Time) -> Option<ImageFilter>;

    /// The Picture mask this effect stands for at clip-local `t`; `None` while off, without a track, or not a Track Mask.
    fn track_mask_shape(&self, t: Time) -> Option<MaskShape>;
}

impl ClipEffectFilters for ClipEffect {
    fn image_filter(&self, t: Time) -> Option<ImageFilter> {
        let v = |key: &str| self.scalar(key, t);
        // Scalars are sanitized (finite, inside the catalog range), so the rounding cannot overflow.
        let int = |key: &str| v(key).round() as i64;
        match self.kind.as_str() {
            ClipEffect::SHARPEN_KIND => {
                let a = v(ClipEffect::SHARPEN_AMOUNT_KEY) / 100.0;
                (a > 0.0).then_some(ImageFilter::Sharpen { amount: a })
            }
            ClipEffect::UNSHARP_MASK_KIND => {
                let a = v(ClipEffect::UNSHARP_AMOUNT_KEY) / 100.0;
                let r = v(ClipEffect::UNSHARP_RADIUS_KEY);
                (a > 0.0 && r > 0.0).then(|| ImageFilter::UnsharpMask {
                    sigma: r / 2.0,
                    amount: a,
                    threshold: v(ClipEffect::UNSHARP_THRESHOLD_KEY) / 100.0,
                })
            }
            ClipEffect::DIRECTIONAL_BLUR_KIND => {
                let len = v(ClipEffect::BLUR_LENGTH_KEY);
                let a = v(ClipEffect::BLUR_DIRECTION_KEY) * PI / 180.0;
                (len > 0.0).then(|| ImageFilter::DirectionalBlur { dx: len * a.sin(), dy: -len * a.cos() })
            }
            ClipEffect::MIRROR_KIND => Some(ImageFilter::Mirror {
                center: self.point(ClipEffect::MIRROR_CENTER_KEY, t),
                angle: v(ClipEffect::MIRROR_ANGLE_KEY),
            }),
            ClipEffect::NOISE_KIND => {
                let a = v(ClipEffect::NOISE_AMOUNT_KEY) / 100.0;
                if a <= 0.0 {
                    return None;
                }
                Some(ImageFilter::Noise {
                    amount: a,
                    color: self.flag(ClipEffect::NOISE_COLOR_KEY, t),
                    clip: self.flag(ClipEffect::NOISE_CLIP_KEY, t),
                    seed: ClipEffect::noise_seed(t),
                })
            }
            ClipEffect::GLOW_KIND => {
                let i = v(ClipEffect::GLOW_INTENSITY_KEY);
                let th = v(ClipEffect::GLOW_THRESHOLD_KEY) / 100.0;
                if !(i > 0.0 && th < 1.0) {
                    return None;
                }
                let tint = if self.choice(ClipEffect::GLOW_COLORS_KEY, t) == 1 {
                    Some(self.color(ClipEffect::GLOW_COLOR_KEY, t).rgb())
                } else {
                    None
                };
                Some(ImageFilter::Glow {
                    threshold: th,
                    sigma: v(ClipEffect::GLOW_RADIUS_KEY) / 2.0,
                    intensity: i,
                    color: tint,
                })
            }
            ClipEffect::MOSAIC_KIND => Some(ImageFilter::Mosaic {
                columns: int(ClipEffect::MOSAIC_COLUMNS_KEY).max(1),
                rows: int(ClipEffect::MOSAIC_ROWS_KEY).max(1),
                sharp: self.flag(ClipEffect::MOSAIC_SHARP_KEY, t),
            }),
            _ => self.style_filter(t),
        }
    }

    fn rolling_shutter_filter(&self, t: Time) -> Option<ImageFilter> {
        if self.kind != ClipEffect::STABILIZE_KIND || self.stabilize_method() != StabilizerMethod::Standard {
            return None;
        }
        let along_x = self.parameters.get(ClipEffect::ROLLING_SCAN_AXIS_KEY).map_or(0.0, |p| p.value) >= 0.5;
        let mut shear: Option<Vec2> = None;
        if self.flag(ClipEffect::ROLLING_SHUTTER_KEY, t)
            && let (Some(x), Some(y)) = (
                self.parameters.get(ClipEffect::ROLLING_SHEAR_X_KEY),
                self.parameters.get(ClipEffect::ROLLING_SHEAR_Y_KEY),
            )
        {
            let k = self.scalar(ClipEffect::ROLLING_SHUTTER_STRENGTH_KEY, t).clamp(0.0, 200.0) / 100.0;
            let s = Vec2::new(x.value_at_local(t) * k, y.value_at_local(t) * k);
            if s.x.is_finite() && s.y.is_finite() && (s.x.abs() > 2e-5 || s.y.abs() > 2e-5) {
                shear = Some(s);
            }
        }
        // The residual perspective rides in the same warp pass (one resampling for both).
        let keys = stabilize_perspective_keys();
        let mut h: Vec<f64> = Vec::new();
        if keys.iter().any(|k| self.parameters.contains_key(k)) {
            h = keys.iter().map(|k| self.parameters.get(k).map_or(0.0, |p| p.value_at_local(t))).collect();
            if !h.iter().all(|x| x.is_finite()) || h.iter().all(|x| x.abs() <= Stabilizer::PERSPECTIVE_FLOOR) {
                h = Vec::new();
            }
        }
        if h.is_empty() {
            return shear.map(|s| ImageFilter::RollingShutter { shear: s, along_x });
        }
        Some(ImageFilter::StabilizeWarp { shear: shear.unwrap_or(Vec2::ZERO), along_x, perspective: h })
    }

    fn track_mask_shape(&self, t: Time) -> Option<MaskShape> {
        if !self.is_track_mask() || !self.enabled {
            return None;
        }
        let track = self.mask_track?;
        let mut s = MaskShape::new(Vec::new());
        s.inverted = self.scalar(ClipEffect::TRACK_MASK_INVERT_KEY, t) >= 0.5;
        s.mode = MaskMode::Intersect;
        s.source = MaskSource::Picture;
        s.picture_track = Some(track);
        s.picture_channel = if self.scalar(ClipEffect::TRACK_MASK_MODE_KEY, t) >= 0.5 {
            MatteChannel::Brightness
        } else {
            MatteChannel::Shape
        };
        Some(s)
    }
}

/// Effect evaluation of a clip (Swift `extension Clip`).
pub trait ClipEffectsEval {
    /// Effects at timeline time `t`, in list order.
    fn effects_at(&self, t: Time) -> ClipEffects;

    /// `e` changes where things are in the picture the next effect reads, at clip-local `t`. Transform, Auto Reframe and
    /// the Standard Stabilizer's motion are stages after every pixel effect and do not count.
    fn moves_pixels(&self, e: &ClipEffect, t: Time) -> bool;
}

impl ClipEffectsEval for Clip {
    fn effects_at(&self, t: Time) -> ClipEffects {
        let mut out = effects_without_anti_flicker(self, t);
        let strength =
            if self.motion_enabled { self.animation.anti_flicker_strength_at_local(t - self.start) } else { 0.0 };
        if strength > 0.0 {
            out.anti_flicker = strength;
        }
        out
    }

    fn moves_pixels(&self, e: &ClipEffect, t: Time) -> bool {
        match e.kind.as_str() {
            ClipEffect::TRANSFORM_KIND => self.has_live_mask_input(e), // then a picture warp inside its masks
            ClipEffect::STABILIZE_KIND => e.rolling_shutter_filter(t).is_some() || e.stabilize_fills_edges(),
            kind => !IN_PLACE_KINDS.contains(&kind) && !e.is_audio() && e.image_filter(t).is_some(),
        }
    }
}

/// The current segment is complete: start a new one (after a blur, or as an extra pass when a merge is impossible).
fn split(segs: &mut Vec<EffectSegment>, blur: f64, repeat_edges: bool) {
    let n = segs.len() - 1;
    segs[n].blur_after = blur;
    segs[n].blur_repeats_edges = blur > 0.0 && repeat_edges;
    segs.push(EffectSegment::default());
}

/// A masked key is a pass of its own: what came before is finished first, the keyed image ends the pass.
fn append_key(segs: &mut Vec<EffectSegment>, k: ChromaKey, scope: Vec<MaskShape>) {
    if !scope.is_empty() {
        if !segs[segs.len() - 1].is_plain() {
            split(segs, 0.0, false);
        }
        let n = segs.len() - 1;
        segs[n].keys = vec![k];
        segs[n].scope = scope;
        split(segs, 0.0, false);
        return;
    }
    let n = segs.len() - 1;
    if segs[n].keys.len() >= ChromaKey::MAX_PER_LAYER || segs[n].scopes_keys() {
        split(segs, 0.0, false);
    }
    let n = segs.len() - 1;
    segs[n].keys.push(k);
}

fn effects_without_anti_flicker(c: &Clip, t: Time) -> ClipEffects {
    let local = t - c.start;
    if c.effects.is_empty() {
        // the common case: only the clip masks (same result as below)
        let masks = c.mask_shapes_at_local(local);
        return if masks.is_empty() {
            ClipEffects::none()
        } else {
            ClipEffects::new(Vec::new(), masks, FilmLook::default())
        };
    }
    let value = |e: &ClipEffect, key: &str| e.scalar(key, local);
    let mut segs = vec![EffectSegment::default()];
    let mut look = FilmLook::default();
    let mut temporal: Option<TemporalFilter> = None;
    let seed = FilmLook::seed_at_local(local);
    let local_seconds = local.value() as f64 / local.timescale().max(1) as f64;
    let color_order: Vec<_> = c.color_effect_indices().into_iter().map(|i| c.effects[i].id).collect();
    let pro_grade = c.active_grade() == ActiveGrade::Pro;
    // Anonymize: a cover whose matte no longer fits the picture it reads (an effect in front of it moved pixels) or whose
    // mask is switched off covers the whole frame.
    let guards_covers = c.has_cover_mask();
    let mut moved = false;
    for e in c.effects.iter().filter(|e| e.enabled) {
        let mut scope = c.input_mask_shapes(e, local);
        if guards_covers {
            if c.is_cover(e) && (moved || c.cover_input_is_off(e)) {
                scope = Vec::new();
            }
            if !moved && c.moves_pixels(e, local) {
                moved = true;
            }
        }
        let last = segs.len() - 1;
        match e.kind.as_str() {
            ClipEffect::COLOR_KIND => {
                // Unmasked Color effects are the clip's grade (`renderColor`); a masked one is a grade pass here.
                if pro_grade || !c.has_live_mask_input(e) {
                    continue;
                }
                let Some(n) = color_order.iter().position(|id| *id == e.id) else { continue };
                if !c.color_effect_renders(e, n, local) {
                    continue;
                }
                let mut ce = e.color_effect(Some(local), n as i64 + 1);
                let w = e.range_strength(local);
                if w < 1.0 {
                    ce = ce.scaled(w as f32);
                }
                segs[last].grade = Some(ce);
                segs[last].scope = scope;
                segs.push(EffectSegment::default());
            }
            ClipEffect::COLOR_GRAPH_KIND => continue, // the Pro grade is the clip's grade (`renderColor`)
            ClipEffect::TRANSFORM_KIND if c.has_live_mask_input(e) => {
                // A masked Transform moves the picture inside its masks instead of moving the clip.
                let Some(f) = ImageFilter::stage(&e.stage_transform(local, Some(c.duration()), Vec2::ZERO)) else {
                    continue;
                };
                segs[last].filter = Some(f);
                segs[last].scope = scope;
                segs.push(EffectSegment::default());
            }
            ClipEffect::GAUSSIAN_BLUR_KIND => {
                let b = ClipEffect::gaussian_sigma(value(e, ClipEffect::BLURRINESS_KEY));
                if b <= 0.0 {
                    continue; // blur 0 is identity: it does not even cut the list
                }
                let edges = e.flag(ClipEffect::REPEAT_EDGE_PIXELS_KEY, local);
                let n = segs.len();
                if scope.is_empty()
                    && n > 1
                    && segs[n - 1].is_plain()
                    && segs[n - 2].shadow.is_none()
                    && segs[n - 2].filter.is_none()
                    && segs[n - 2].scope.is_empty()
                    && segs[n - 2].blur_repeats_edges == edges
                {
                    // two blurs in a row, same edge mode: one Gaussian
                    let prev = segs[n - 2].blur_after;
                    segs[n - 2].blur_after = (prev * prev + b * b).sqrt();
                } else {
                    segs[last].scope = scope;
                    split(&mut segs, b, edges);
                }
            }
            ClipEffect::ROUNDED_CORNERS_KIND => {
                let r = value(e, ClipEffect::RADIUS_KEY);
                if r <= 0.0 {
                    continue;
                }
                if let Some(m) = segs[last].masks.adding_radius(r) {
                    segs[last].masks = m;
                } else {
                    split(&mut segs, 0.0, false);
                    let n = segs.len() - 1;
                    segs[n].masks = EffectMasks::NONE.adding_radius(r).unwrap_or_default();
                }
            }
            ClipEffect::CROP_KIND => {
                let cr = CropInsets {
                    left: value(e, ClipEffect::CROP_LEFT_KEY) / 100.0,
                    top: value(e, ClipEffect::CROP_TOP_KEY) / 100.0,
                    right: value(e, ClipEffect::CROP_RIGHT_KEY) / 100.0,
                    bottom: value(e, ClipEffect::CROP_BOTTOM_KEY) / 100.0,
                };
                let f = value(e, ClipEffect::CROP_SOFTNESS_KEY).max(0.0);
                if cr.is_identity() && (f.is_nan() || f <= 0.0) {
                    continue; // softness alone softens the frame edge
                }
                if let Some(m) = segs[last].masks.adding_crop(&cr, f) {
                    segs[last].masks = m;
                } else {
                    split(&mut segs, 0.0, false);
                    let n = segs.len() - 1;
                    segs[n].masks = EffectMasks::NONE.adding_crop(&cr, f).unwrap_or_default();
                }
            }
            ClipEffect::ULTRA_KEY_KIND => {
                let tolerance = value(e, ClipEffect::TOLERANCE_KEY);
                if tolerance <= 0.0 {
                    continue; // tolerance 0 keys nothing: identity
                }
                let mut k = ChromaKey::new(
                    value(e, ClipEffect::KEY_HUE_KEY),
                    tolerance * 0.9,
                    1.0 + value(e, ClipEffect::SOFTEN_KEY) * 0.6,
                    value(e, ClipEffect::SPILL_KEY) / 100.0,
                    value(e, ClipEffect::CHOKE_KEY) / 100.0,
                    value(e, ClipEffect::PEDESTAL_KEY) / 100.0,
                );
                k.output = ChromaKeyOutput::from_raw(value(e, ClipEffect::KEY_OUTPUT_KEY).round() as i64)
                    .unwrap_or(ChromaKeyOutput::Composite);
                k.contrast = value(e, ClipEffect::KEY_CONTRAST_KEY) / 100.0;
                k.midpoint = value(e, ClipEffect::KEY_MIDPOINT_KEY) / 100.0;
                k.keep_highlights = value(e, ClipEffect::KEY_HIGHLIGHT_KEY) / 100.0;
                k.keep_shadows = value(e, ClipEffect::KEY_SHADOW_KEY) / 100.0;
                k.spill_range = value(e, ClipEffect::SPILL_RANGE_KEY) / 100.0;
                k.saturation = value(e, ClipEffect::KEY_SATURATION_KEY) / 100.0;
                k.hue_shift = value(e, ClipEffect::KEY_HUE_SHIFT_KEY);
                k.luma = value(e, ClipEffect::KEY_LUMA_KEY) / 100.0;
                append_key(&mut segs, k, scope);
            }
            ClipEffect::LUMA_KEY_KIND => {
                let thr = value(e, ClipEffect::LUMA_THRESHOLD_KEY) / 100.0;
                let soft = value(e, ClipEffect::LUMA_SOFTNESS_KEY) / 100.0;
                let brights = value(e, ClipEffect::LUMA_KEY_OUT_KEY) >= 0.5;
                let mut k = ChromaKey::luma_key(thr, soft, brights);
                k.choke = value(e, ClipEffect::CHOKE_KEY) / 100.0;
                k.contrast = value(e, ClipEffect::KEY_CONTRAST_KEY) / 100.0;
                k.midpoint = value(e, ClipEffect::KEY_MIDPOINT_KEY) / 100.0;
                k.output = ChromaKeyOutput::from_raw(value(e, ClipEffect::KEY_OUTPUT_KEY).round() as i64)
                    .unwrap_or(ChromaKeyOutput::Composite);
                append_key(&mut segs, k, scope);
            }
            // Film / tape look: when a kind is applied twice the later instance wins (one pass, one set of values).
            ClipEffect::GRAIN_KIND => {
                let amount = value(e, ClipEffect::GRAIN_AMOUNT_KEY) / 100.0;
                look.grain = if amount > 0.0 {
                    Some(Grain {
                        amount,
                        size: value(e, ClipEffect::GRAIN_SIZE_KEY),
                        softness: value(e, ClipEffect::GRAIN_SOFTNESS_KEY) / 100.0,
                        luma_weight: value(e, ClipEffect::GRAIN_RESPONSE_KEY) / 100.0,
                        color: value(e, ClipEffect::GRAIN_COLOR_KEY) / 100.0,
                        seed: if value(e, ClipEffect::GRAIN_ANIMATE_KEY) >= 0.5 { seed } else { 0 },
                    })
                } else {
                    None
                };
            }
            ClipEffect::AGED_FILM_KIND => {
                let d = value(e, ClipEffect::DUST_KEY) / 100.0;
                let s = value(e, ClipEffect::SCRATCHES_KEY) / 100.0;
                let f = value(e, ClipEffect::FLICKER_KEY) / 100.0;
                look.aged = if d > 0.0 || s > 0.0 || f > 0.0 {
                    Some(Aged { dust: d, scratches: s, flicker: f, seed })
                } else {
                    None
                };
            }
            ClipEffect::GATE_WEAVE_KIND => {
                let amount = value(e, ClipEffect::AMOUNT_KEY);
                let rot = value(e, ClipEffect::ROTATION_KEY);
                look.weave = if amount > 0.0 || rot > 0.0 {
                    Some(GateWeave::evaluate(amount, value(e, ClipEffect::SPEED_KEY), rot, local_seconds))
                } else {
                    None
                };
            }
            ClipEffect::SCANLINES_KIND => {
                let i = value(e, ClipEffect::INTENSITY_KEY) / 100.0;
                look.scanlines = if i > 0.0 {
                    Some(Scanlines {
                        intensity: i,
                        spacing: value(e, ClipEffect::SPACING_KEY),
                        thickness: value(e, ClipEffect::THICKNESS_KEY) / 100.0,
                    })
                } else {
                    None
                };
            }
            ClipEffect::CHROMA_BLEED_KIND => {
                let b = value(e, ClipEffect::BLEED_KEY);
                let s = value(e, ClipEffect::SHIFT_KEY);
                look.chroma_bleed = if b > 0.0 || s != 0.0 { Some(ChromaBleed { bleed: b, shift: s }) } else { None };
            }
            ClipEffect::TRACKING_NOISE_KIND => {
                let a = value(e, ClipEffect::AMOUNT_KEY) / 100.0;
                let phase = (local_seconds * value(e, ClipEffect::SPEED_KEY)) % 1.0;
                look.tracking = if a > 0.0 {
                    Some(Tracking {
                        amount: a,
                        band_height: value(e, ClipEffect::BAND_HEIGHT_KEY) / 100.0,
                        phase,
                        seed,
                    })
                } else {
                    None
                };
            }
            ClipEffect::VIDEO_DENOISE_KIND | ClipEffect::DEFLICKER_KIND | ClipEffect::TRAILS_KIND => {
                let mut f = temporal.unwrap_or_default();
                e.apply_temporal(&mut f, local);
                temporal = if f.is_identity() { None } else { Some(f) };
            }
            // a time remap / an extra text layer (see `Timeline::video_layers`)
            ClipEffect::POSTERIZE_TIME_KIND | ClipEffect::DATE_STAMP_KIND => continue,
            // blurs the motion (`Clip::motion_blur`), not the picture
            ClipEffect::MOTION_BLUR_KIND => continue,
            ClipEffect::DROP_SHADOW_KIND => {
                let opacity = value(e, ClipEffect::SHADOW_OPACITY_KEY) / 100.0;
                let only = e.flag(ClipEffect::SHADOW_ONLY_KEY, local);
                if !(opacity > 0.0 || only) {
                    continue; // invisible shadow, picture kept: identity
                }
                let a = value(e, ClipEffect::SHADOW_DIRECTION_KEY) * PI / 180.0;
                let d = value(e, ClipEffect::SHADOW_DISTANCE_KEY);
                let sh = DropShadow {
                    color: e.color(ClipEffect::SHADOW_COLOR_KEY, local).rgb(),
                    opacity,
                    dx: d * a.sin(),
                    dy: -d * a.cos(),
                    sigma: value(e, ClipEffect::SHADOW_SOFTNESS_KEY).max(0.0) * ClipEffect::SHADOW_SIGMA_PER_SOFTNESS,
                    spread: value(e, ClipEffect::SHADOW_SPREAD_KEY) / 100.0,
                    shadow_only: only,
                };
                segs[last].shadow = Some(sh);
                segs.push(EffectSegment::default());
            }
            ClipEffect::STABILIZE_KIND => {
                // The correction itself moves the clip, unless Edge Fill warps the picture instead (after the rolling
                // shutter pass).
                if let Some(f) = e.rolling_shutter_filter(local) {
                    let n = segs.len() - 1;
                    segs[n].filter = Some(f);
                    segs.push(EffectSegment::default());
                }
                if e.stabilize_fills_edges() {
                    let st = e.stage_transform(local, Some(c.duration()), Vec2::ZERO);
                    if let Some(f) = ImageFilter::stage_fill(&st, e.stabilize_edge_fill()) {
                        let n = segs.len() - 1;
                        segs[n].filter = Some(f);
                        segs.push(EffectSegment::default());
                    }
                }
            }
            _ => {
                let Some(f) = e.image_filter(local) else { continue };
                segs[last].filter = Some(f);
                segs[last].scope = scope;
                segs.push(EffectSegment::default());
            }
        }
    }
    let mut masks = c.mask_shapes_at_local(local);
    masks.extend(c.effects.iter().filter_map(|e| e.track_mask_shape(local)));
    // A lone plain segment is no effect at all; a trailing plain segment after a blur stays (the blurred image is drawn).
    let mut out = if segs.len() == 1 && segs[0].is_plain() {
        if masks.is_empty() && look.is_identity() {
            ClipEffects::none()
        } else {
            ClipEffects::new(Vec::new(), masks, look)
        }
    } else {
        ClipEffects::new(segs, masks, look)
    };
    if let Some(tf) = temporal.as_mut()
        && let Some(tr) = tf.trails.as_mut()
    {
        tr.backward = c.plays_backward(local);
    }
    out.temporal = temporal;
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect_transform_stage::test_support::*;
    use sq_core_model::AnimatedProperty;
    use sq_core_time::{Id, IdSource};

    fn fx(c: &Clip, t: Time) -> ClipEffects {
        c.effects_at(t)
    }

    fn with(kind: &str, values: &[(&str, f64)]) -> ClipEffect {
        stage(values, kind)
    }

    // Swift EffectOrderTests.blursSeparatedByAnEffectStayTwoBlursAndAdjacentOnesMerge.
    #[test]
    fn blurs_separated_by_an_effect_stay_two_blurs_and_adjacent_ones_merge() {
        let blur = |v: f64| with(ClipEffect::GAUSSIAN_BLUR_KIND, &[(ClipEffect::BLURRINESS_KEY, v)]);
        let crop = || with(ClipEffect::CROP_KIND, &[(ClipEffect::CROP_LEFT_KEY, 10.0)]);
        let sep = fx(&clip(vec![blur(3.0), crop(), blur(4.0)]), s(1));
        let got: Vec<f64> = sep.segments.iter().map(|g| g.blur_after).collect();
        let want: Vec<f64> = [3.0, 4.0, 0.0].iter().map(|b| ClipEffect::gaussian_sigma(*b)).collect();
        assert_eq!(got, want);
        let adj = fx(&clip(vec![blur(3.0), blur(4.0)]), s(1));
        assert!(adj.segments.len() == 2 && adj.segments[1].blur_after == 0.0);
        assert!((adj.segments[0].blur_after - ClipEffect::gaussian_sigma(5.0)).abs() < 1e-12);
    }

    #[test]
    fn crop_softness_reaches_the_mask() {
        let c = clip(vec![with(
            ClipEffect::CROP_KIND,
            &[(ClipEffect::CROP_LEFT_KEY, 10.0), (ClipEffect::CROP_SOFTNESS_KEY, 12.0)],
        )]);
        let e = fx(&c, s(1));
        assert!(e.pre().feather == 12.0 && (e.pre().crop.left - 0.1).abs() < 1e-12);
        assert!(!e.pre().is_identity());
    }

    #[test]
    fn softness_without_a_crop_softens_the_frame_edge() {
        let c = clip(vec![with(ClipEffect::CROP_KIND, &[(ClipEffect::CROP_SOFTNESS_KEY, 8.0)])]);
        let e = fx(&c, s(1));
        assert!(e.pre().feather == 8.0 && e.pre().crop.is_identity() && !e.pre().is_identity());
        // nothing set: identity, no pass
        assert!(fx(&clip(vec![with(ClipEffect::CROP_KIND, &[])]), s(1)).segments.is_empty());
    }

    #[test]
    fn two_crops_keep_the_softer_edge() {
        let a = with(ClipEffect::CROP_KIND, &[(ClipEffect::CROP_LEFT_KEY, 10.0), (ClipEffect::CROP_SOFTNESS_KEY, 4.0)]);
        let b = with(ClipEffect::CROP_KIND, &[(ClipEffect::CROP_TOP_KEY, 20.0), (ClipEffect::CROP_SOFTNESS_KEY, 9.0)]);
        let e = fx(&clip(vec![a, b]), s(1));
        assert!(e.segments.len() == 1 && e.pre().feather == 9.0);
    }

    #[test]
    fn stored_crop_without_softness_reads_zero() {
        let mut e = with(ClipEffect::CROP_KIND, &[(ClipEffect::CROP_LEFT_KEY, 10.0)]);
        e.parameters.remove(ClipEffect::CROP_SOFTNESS_KEY);
        assert_eq!(fx(&clip(vec![e]), s(1)).pre().feather, 0.0);
    }

    #[test]
    fn denoise_and_deflicker_evaluate_into_one_temporal_filter() {
        let n = with(
            ClipEffect::VIDEO_DENOISE_KIND,
            &[(ClipEffect::FRAMES_EACH_SIDE_KEY, 4.0), (ClipEffect::QUALITY_KEY, 1.0)],
        );
        let d = with(
            ClipEffect::DEFLICKER_KIND,
            &[
                (ClipEffect::FRAMES_EACH_SIDE_KEY, 6.0),
                (ClipEffect::ANALYSIS_KEY, 1.0),
                (ClipEffect::STRENGTH_KEY, 50.0),
            ],
        );
        let out = fx(&clip(vec![n, d]), s(1));
        let t = out.temporal.expect("temporal filter");
        assert!(t.denoise.is_some_and(|d| d.frames_each_side == 4 && d.best));
        assert_eq!(t.deflicker, Some(crate::temporal_effects::TemporalDeflicker::new(6, true, 0.5)));
        assert_eq!(t.radius(), 6);
        // The temporal filter runs before the chain: it is not an effect segment, so the plain path stays plain.
        assert!(out.segments.is_empty() && out.is_identity());
    }

    #[test]
    fn disabled_or_zero_effects_give_no_filter() {
        let c = clip(vec![with(ClipEffect::DEFLICKER_KIND, &[(ClipEffect::STRENGTH_KEY, 0.0)])]);
        assert!(fx(&c, s(1)).temporal.is_none());
        let mut e = with(ClipEffect::VIDEO_DENOISE_KIND, &[]);
        e.enabled = false;
        assert!(fx(&clip(vec![e]), s(1)).temporal.is_none());
        // Keep Original 100 % is the original frame.
        let c = clip(vec![with(ClipEffect::VIDEO_DENOISE_KIND, &[(ClipEffect::KEEP_ORIGINAL_KEY, 100.0)])]);
        assert!(fx(&c, s(1)).temporal.is_none());
    }

    #[test]
    fn spatial_only_denoise_needs_no_neighbours() {
        let c = clip(vec![with(
            ClipEffect::VIDEO_DENOISE_KIND,
            &[(ClipEffect::FRAMES_EACH_SIDE_KEY, 0.0), (ClipEffect::SPATIAL_LUMA_KEY, 30.0)],
        )]);
        let t = fx(&c, s(1)).temporal.expect("temporal filter");
        assert!(t.radius() == 0 && t.denoise.is_some_and(|d| d.is_spatial()));
    }

    fn moving_position() -> AnimatedProperty<Vec2> {
        let mut ids = sq_core_time::SequentialIds::default();
        let keys = sq_core_time::KeyframeTrack::with_keys(vec![
            sq_core_time::Keyframe::new(ids.next_id(), Time::ZERO, Vec2::ZERO),
            sq_core_time::Keyframe::new(ids.next_id(), s(1), Vec2::new(100.0, 0.0)),
        ]);
        AnimatedProperty { value: Vec2::ZERO, track: keys }
    }

    #[test]
    fn motion_blur_effect_blurs_keyed_motion_and_a_still_clip_costs_nothing() {
        use crate::effect_transform_stage::ClipStageEval;
        let blur = |amount: f64| with(ClipEffect::MOTION_BLUR_KIND, &[(ClipEffect::AMOUNT_KEY, amount)]);
        let mut c = clip(vec![blur(100.0)]);
        c.animation.position = moving_position();
        let mb = c.motion_blur(Time::new(1, 2), fd(), &canvas(), 1.0).expect("samples");
        assert_eq!(mb.transforms.len(), 16);
        // Amount 100 = a 360 degree shutter: one full frame (4 px at 100 px/s, 25 fps), centered.
        assert!(close(mb.transforms[0].position.x, 48.0, 1e-6) && close(mb.transforms[15].position.x, 52.0, 1e-6));
        let still = clip(vec![blur(100.0)]);
        assert!(still.motion_blur(Time::new(1, 2), fd(), &canvas(), 1.0).is_none());
        assert_eq!(fx(&still, Time::new(1, 2)), ClipEffects::none());
    }

    #[test]
    fn effect_masks_merge_and_split_like_one_coverage_mask() {
        let crop = CropInsets { left: 0.1, ..CropInsets::NONE };
        let m = EffectMasks::NONE.adding_radius(8.0).and_then(|m| m.adding_crop(&crop, 0.0)).expect("one mask");
        assert!(m.round_first && m.corner_radius == 8.0);
        // Rounded Corners, Crop, Rounded Corners is not one mask.
        assert!(m.adding_radius(4.0).is_none());
        assert!(CropInsets { left: 0.5, right: 0.5, ..CropInsets::NONE }.is_empty());
    }

    #[test]
    fn stage_warp_inverts_the_stage_map() {
        let st = StageTransform { position: Vec2::new(10.0, 0.0), scale: 2.0, ..StageTransform::IDENTITY };
        let Some(ImageFilter::StageWarp { a, d, tx, opacity, .. }) = ImageFilter::stage(&st) else { panic!("warp") };
        assert!(close(a, 0.5, 1e-12) && close(d, 0.5, 1e-12) && close(tx, -5.0, 1e-12) && opacity == 1.0);
        assert!(ImageFilter::stage(&StageTransform::IDENTITY).is_none());
        let zero = StageTransform { scale: 0.0, ..StageTransform::IDENTITY };
        assert!(matches!(ImageFilter::stage(&zero), Some(ImageFilter::StageWarp { opacity, .. }) if opacity == 0.0));
        assert!(ImageFilter::stage_fill(&st, StabilizerEdgeFill::Zoom).is_none());
        assert!(matches!(
            ImageFilter::stage_fill(&st, StabilizerEdgeFill::Mirror),
            Some(ImageFilter::StageFill { .. })
        ));
    }

    #[test]
    fn long_shadow_only_grows_along_its_axes() {
        let f = ImageFilter::LongShadow { angle: 90.0, length: 20.0, color: [0.0; 3], fade: 0.0, opacity: 1.0 };
        let m = f.axis_margin();
        assert!(close(m.x, 21.0, 1e-9) && close(m.y, 1.0, 1e-9));
        assert_eq!(ImageFilter::Mosaic { columns: 2, rows: 2, sharp: false }.margin(), 0.0);
    }

    #[test]
    fn simple_form_round_trips_through_the_views() {
        let mut e = ClipEffects::simple(
            EffectMasks { corner_radius: 4.0, ..EffectMasks::NONE },
            3.0,
            EffectMasks::NONE,
            Vec::new(),
        );
        assert_eq!(e.segments.len(), 2);
        assert!(close(e.blur(), 3.0, 1e-12) && e.corner_radius() == 4.0);
        e.set_blur(0.0);
        assert_eq!(e.segments.len(), 1);
        assert!(ClipEffects::none().is_identity() && !ClipEffects::with_corner_radius(4.0).is_identity());
        let _ = Id::NIL;
    }
}
