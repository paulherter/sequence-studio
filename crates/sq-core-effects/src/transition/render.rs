// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Transition.swift (TransitionMix, TransitionSide, TransitionRender)

//! The pure per-frame maths of transitions, shared by playback and export: how two pictures mix on one frame.

use super::{TransitionDirectionExt, TransitionKindExt};
use crate::transition_custom_curve::TransitionEasing;
use sq_core_model::{TransitionDirection, TransitionKind};
use sq_core_time::{EasingCurve, Vec2};
use std::f64::consts::{FRAC_PI_2, PI};

/// Weights of the outgoing and incoming picture and of the solid dip layer between them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionMix {
    /// Weight of the outgoing picture.
    pub outgoing: f64,
    /// Weight of the incoming picture.
    pub incoming: f64,
    /// Weight of the dip color.
    pub dip: f64,
}

impl TransitionMix {
    /// Through Color without a pick: a warm red, so the kind is visibly not Through Black.
    pub const DEFAULT_DIP_COLOUR: [u8; 3] = [230, 60, 50];
    /// Flash: the color peak is `(1 - |2w - 1|)^exponent` (a dip is exponent 1).
    const FLASH_EXPONENT: f64 = 2.5;

    /// Weight of the incoming picture on frame `frame_index` of `frames`: strictly inside 0...1, so a one-frame transition
    /// shows the 50 % blend and the first frame is already slightly mixed.
    pub fn video_weight(frame_index: i64, frames: i64) -> f64 {
        (frame_index + 1) as f64 / (frames + 1) as f64
    }

    /// Two-sided video mix at incoming weight `w`. Cross dissolve: `(1-w)*A + w*B`. Dips: A fades to the dip color over the
    /// first half, B fades in from it over the second.
    pub fn video(kind: TransitionKind, w: f64) -> TransitionMix {
        match kind {
            TransitionKind::DipToBlack | TransitionKind::DipToWhite | TransitionKind::DipToColour => {
                let o = (1.0 - 2.0 * w).max(0.0);
                let i = (2.0 * w - 1.0).max(0.0);
                TransitionMix { outgoing: o, incoming: i, dip: 1.0 - o - i }
            }
            TransitionKind::Flash => {
                // Hard cut at the middle; the color comes in fast and leaves fast (a peak, not a ramp).
                let k = (1.0 - (2.0 * w - 1.0).abs()).max(0.0).powf(Self::FLASH_EXPONENT);
                TransitionMix {
                    outgoing: if w < 0.5 { 1.0 - k } else { 0.0 },
                    incoming: if w < 0.5 { 0.0 } else { 1.0 - k },
                    dip: k,
                }
            }
            _ => TransitionMix { outgoing: 1.0 - w, incoming: w, dip: 0.0 },
        }
    }

    /// Dip color as display-encoded RGB bytes; `custom` counts only with three bytes.
    pub fn dip_color(kind: TransitionKind, custom: Option<&[u8]>) -> [u8; 3] {
        match kind {
            TransitionKind::DipToWhite | TransitionKind::Flash => [255, 255, 255],
            TransitionKind::DipToColour => {
                custom.and_then(|c| <[u8; 3]>::try_from(c).ok()).unwrap_or(Self::DEFAULT_DIP_COLOUR)
            }
            _ => [0, 0, 0],
        }
    }

    /// Audio gains `(outgoing, incoming)` at progress 0...1. Constant Power: equal power (cos/sin). Constant Gain: linear.
    pub fn audio_gains(kind: TransitionKind, progress: f64) -> (f64, f64) {
        let p = progress.clamp(0.0, 1.0);
        match kind {
            TransitionKind::ConstantGain => (1.0 - p, p),
            TransitionKind::ExponentialFade => ((1.0 - p) * (1.0 - p), p * p),
            _ => ((p * FRAC_PI_2).cos(), (p * FRAC_PI_2).sin()),
        }
    }
}

/// How one side of a motion transition is drawn at one instant. Offsets and blur are fractions of the frame (x of the
/// width, y of the height, y down); scale is about the frame center.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionSide {
    /// Offset.
    pub offset: Vec2,
    /// Scale.
    pub scale: f64,
    /// Opacity.
    pub opacity: f64,
    /// Directional motion blur: the full smear vector (centered on the picture's position).
    pub blur: Vec2,
    /// Radial (zoom) blur: relative scale spread of the smear, centered.
    pub zoom_blur: f64,
    /// Rotation about the frame center in radians (clockwise on screen).
    pub rotation: f64,
    /// Outside the picture it repeats mirrored instead of being transparent.
    pub mirror_edges: bool,
}

impl Default for TransitionSide {
    fn default() -> Self {
        TransitionSide {
            offset: Vec2::ZERO,
            scale: 1.0,
            opacity: 1.0,
            blur: Vec2::ZERO,
            zoom_blur: 0.0,
            rotation: 0.0,
            mirror_edges: false,
        }
    }
}

/// How the two side images combine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Compose {
    /// Premultiplied sum: the two pictures tile the frame (push).
    Sum = 0,
    /// Incoming over outgoing.
    IncomingOver = 1,
    /// Outgoing over incoming.
    OutgoingOver = 2,
    /// Soft-edged mask between the two.
    Wipe = 3,
    /// RGB split + slice displacement on one picture, hard cut at `Glitch::mix` 0.5.
    Glitch = 4,
    /// Ellipse mask (`iris`).
    Iris = 5,
    /// Dissolve plus a screen-blended gradient (`light_leak`).
    LightLeak = 6,
    /// Dissolve of two pictures each smeared by a disc blur.
    BlurDissolve = 7,
    /// Channel-change noise: hard cut at mix 0.5.
    StaticNoise = 8,
    /// Dissolve plus a drifting screen-blended glow noise.
    LightNoise = 9,
    /// Reveal of B by a distance field (`shape_wipe`).
    Shape = 10,
    /// Dissolve under blocks that grow to the middle and shrink again.
    Mosaic = 11,
    /// Flip 3D.
    Flip3D = 12,
    /// Burn.
    Burn = 13,
    /// Flare.
    Flare = 14,
    /// Warp.
    Warp = 15,
    /// Shake.
    Shake = 16,
}

/// The moving edge of a wipe.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Wipe {
    /// Direction the edge travels (unit vector, y down).
    pub direction: Vec2,
    /// Edge position along `direction`, 0 = the side it starts from, 1 = the far side; B shows behind it.
    pub front: f64,
    /// Half width of the soft band, frame fractions.
    pub softness: f64,
}

impl Wipe {
    /// A wipe.
    pub fn new(direction: Vec2, front: f64, softness: f64) -> Wipe {
        Wipe { direction, front, softness }
    }
}

/// Glitch state: purely a function of the frame, so playback and export agree.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Glitch {
    /// Incoming weight 0...1; the picture switches from A to B at 0.5.
    pub mix: f64,
    /// 0...1, a bell over the span (peaks at the cut).
    pub intensity: f64,
    /// Per-frame hash seed.
    pub seed: u32,
}

impl Glitch {
    /// Horizontal bands (full frame height split in this many slices).
    pub const BANDS: i64 = 24;
    /// Largest slice displacement, frame fractions of the width.
    pub const MAX_SHIFT: f64 = 0.12;
    /// Largest RGB channel offset, frame fractions of the width.
    pub const MAX_SPLIT: f64 = 0.025;

    fn hash(band: u32, seed: u32) -> u32 {
        let mut h = band.wrapping_mul(0x9E37_79B1) ^ seed.wrapping_mul(0x85EB_CA6B);
        h ^= h >> 15;
        h = h.wrapping_mul(0x2C1B_3C6D);
        h ^= h >> 12;
        h = h.wrapping_mul(0x297A_2D39);
        h ^= h >> 15;
        h
    }

    /// Horizontal displacement of one band (frame fractions, signed); 0 for most bands at low intensity.
    pub fn slice_shift(band: i64, seed: u32, intensity: f64) -> f64 {
        let h = Self::hash(band as u32, seed);
        let gate = f64::from(h & 0xFF) / 255.0;
        if gate >= 0.45 * intensity {
            return 0.0;
        }
        (f64::from((h >> 8) & 0xFFFF) / 65535.0 * 2.0 - 1.0) * Self::MAX_SHIFT * intensity
    }

    /// RGB channel offset at `intensity`.
    pub fn rgb_split(intensity: f64) -> f64 {
        Self::MAX_SPLIT * intensity.clamp(0.0, 1.0)
    }
}

/// `smoothstep(a, b, x)`.
pub fn smoothstep(a: f64, b: f64, x: f64) -> f64 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Iris mask. The shader mirrors this.
pub mod iris {
    use super::smoothstep;

    /// 0 at the center, 1 at the corners; the iso-lines are ellipses with the frame's aspect.
    pub fn radius(u: f64, v: f64) -> f64 {
        let (x, y) = ((u - 0.5) * 2.0, (v - 0.5) * 2.0);
        (x * x + y * y).sqrt() / 2f64.sqrt()
    }

    /// How much of the incoming picture shows (1 inside the ellipse, 0 outside, smooth over +-softness).
    pub fn mask(u: f64, v: f64, front: f64, softness: f64) -> f64 {
        1.0 - smoothstep(front - softness, front + softness, radius(u, v))
    }
}

/// Spring and Fall move curves (frame fractions of travel).
pub mod spring_fall {
    use std::f64::consts::PI;

    /// Tilt of the falling picture at the end of the fall, radians.
    pub const TILT: f64 = 0.25;

    /// 0 -> 1 with a small overshoot (about 9 % near 45 %) that settles exactly on 1.
    pub fn spring(t: f64) -> f64 {
        let t = t.clamp(0.0, 1.0);
        1.0 - (1.0 - t) * (-4.0 * t).exp() * (2.2 * PI * t).cos()
    }

    /// Gravity: distance grows with the square of the time, A is gone (past the edge) at the end.
    pub fn fall(t: f64) -> f64 {
        let t = t.clamp(0.0, 1.0);
        1.1 * t * t
    }
}

/// Flip 3D geometry.
pub mod flip_3d {
    /// Camera distance in half-heights.
    pub const CAMERA: f64 = 3.0;

    /// The card at screen point (`x`, `y`) in -1...1 (y down) turned by `angle` about the vertical center line, camera 3
    /// half-heights away. Returns the card point (-1...1) that lands there, `None` where the card is not.
    pub fn card_point(sx: f64, sy: f64, angle: f64) -> Option<(f64, f64)> {
        let d = CAMERA;
        let den = d * angle.cos() + sx * angle.sin();
        if den <= 0.05 {
            return None;
        }
        let x = sx * d / den;
        let y = sy * (d - x * angle.sin()) / d;
        (x.abs() <= 1.0 && y.abs() <= 1.0).then_some((x, y))
    }
}

/// Shape reveals: every shape is a distance field `d(u, v)` over the frame (0...1, y down); B shows where `d` is below the
/// front. The shape id travels in `Wipe::direction.x`.
pub mod shape_wipe {
    use super::smoothstep;
    use std::f64::consts::PI;

    /// The shapes, in shader id order.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Shape {
        /// Clock.
        Clock = 0,
        /// Box.
        Box,
        /// Diamond.
        Diamond,
        /// Cross.
        Cross,
        /// Doors opening sideways.
        DoorsAcross,
        /// Doors opening up and down.
        DoorsDown,
        /// Blinds.
        Blinds,
        /// Radial.
        Radial,
        /// Wedge.
        Wedge,
        /// Pinwheel.
        Pinwheel,
        /// Checker.
        Checker,
        /// Zig-zag blocks.
        ZigZag,
        /// Inset.
        Inset,
        /// Random blocks.
        Random,
        /// Slice.
        Slice,
    }

    /// Number of slats of Blinds.
    pub const BLIND_COUNT: i64 = 8;
    /// Cells of Checker (columns, rows).
    pub const CHECKER_CELLS: (i64, i64) = (8, 6);
    /// Cells of Zig-Zag Blocks (columns, rows).
    pub const ZIG_ZAG_CELLS: (i64, i64) = (8, 8);
    /// Cells of Random Blocks (columns, rows).
    pub const RANDOM_CELLS: (i64, i64) = (12, 8);
    /// Strips of Slice.
    pub const SLICE_COUNT: i64 = 10;

    /// Order of a Random Blocks cell, 0..<1. Integer hash; the shader repeats it bit for bit.
    pub fn cell_order(cx: i64, cy: i64) -> f64 {
        let mut h = (cx as u32).wrapping_mul(73_856_093) ^ (cy as u32).wrapping_mul(19_349_663);
        h = (h ^ (h >> 13)).wrapping_mul(1_274_126_177);
        h ^= h >> 16;
        f64::from(h & 0xFFFF) / 65536.0
    }

    fn fract(x: f64) -> f64 {
        x - x.floor()
    }

    /// Distance of point (`u`, `v`) in the shape's field.
    pub fn distance(s: Shape, u: f64, v: f64) -> f64 {
        let (x, y) = ((u - 0.5) * 2.0, (v - 0.5) * 2.0);
        match s {
            Shape::Clock => {
                // Clockwise from 12 o'clock.
                let a = x.atan2(-y) / (2.0 * PI);
                if a < 0.0 { a + 1.0 } else { a }
            }
            Shape::Box => x.abs().max(y.abs()),
            Shape::Diamond => (x.abs() + y.abs()) / 2.0,
            Shape::Cross => x.abs().min(y.abs()),
            Shape::DoorsAcross => x.abs(),
            Shape::DoorsDown => y.abs(),
            Shape::Blinds => fract(v * BLIND_COUNT as f64),
            Shape::Radial => u.atan2(v) / (PI / 2.0),
            Shape::Wedge => x.abs().atan2(-y) / PI,
            Shape::Pinwheel => {
                let a = x.atan2(-y) / (2.0 * PI);
                fract((if a < 0.0 { a + 1.0 } else { a }) * 4.0)
            }
            Shape::Checker => {
                let (c, r) = (CHECKER_CELLS.0 as f64, CHECKER_CELLS.1 as f64);
                let f = fract(u * c);
                if ((u * c).floor() as i64 + (v * r).floor() as i64) % 2 == 0 { f } else { 1.0 - f }
            }
            Shape::ZigZag => {
                let (c, r) = (ZIG_ZAG_CELLS.0 as f64, ZIG_ZAG_CELLS.1 as f64);
                let row = (v * r).floor().min(r - 1.0);
                let col = (u * c).floor().min(c - 1.0);
                let along = (col + 0.5) / c;
                (row + if (row as i64) % 2 == 0 { along } else { 1.0 - along }) / r
            }
            Shape::Slice => {
                let row = (v * SLICE_COUNT as f64).floor();
                if (row as i64) % 2 == 0 { u } else { 1.0 - u }
            }
            Shape::Inset => u.max(v),
            Shape::Random => {
                let (c, r) = (RANDOM_CELLS.0 as f64, RANDOM_CELLS.1 as f64);
                cell_order((u * c).floor().min(c - 1.0) as i64, (v * r).floor().min(r - 1.0) as i64)
            }
        }
    }

    /// How much of B shows (1 where `distance` is below the front, smooth over +-softness).
    pub fn mask(s: Shape, u: f64, v: f64, front: f64, softness: f64) -> f64 {
        1.0 - smoothstep(front - softness, front + softness, distance(s, u, v))
    }
}

/// Light Leak: the gradient color at a point and the dissolve behind it.
pub mod light_leak {
    use super::smoothstep;
    use sq_core_time::Vec2;

    /// Incoming weight of the underlying dissolve (B takes over while the leak peaks).
    pub fn mix_weight(progress: f64) -> f64 {
        smoothstep(0.35, 0.65, progress)
    }

    /// Strength of the leak over the span, 0 at both ends and 1 in the middle.
    pub fn bell(progress: f64) -> f64 {
        (progress.clamp(0.0, 1.0) * std::f64::consts::PI).sin().max(0.0)
    }

    /// Leak color (linear, added with screen blend) at `u, v` (0...1, y down): a soft band traveling along `d`; `softness`
    /// widens it.
    pub fn leak(u: f64, v: f64, p: f64, d: Vec2, softness: f64) -> (f64, f64, f64) {
        let x = (u - 0.5) * d.x + (v - 0.5) * d.y + 0.5; // along the travel
        let y = -(u - 0.5) * d.y + (v - 0.5) * d.x + 0.5; // across it
        let centre = -0.3 + 1.6 * p;
        let width = 0.15 + 1.5 * softness;
        let k = (x - centre) / width;
        let f = (-k * k).exp();
        let b = bell(p);
        let t = y.clamp(0.0, 1.0);
        // Orange at one edge, pink at the other.
        let (wr, wg, wb) = (1.0, 0.55 - 0.35 * t, 0.15 + 0.3 * t);
        let a = f * b * 1.2;
        let core = f * f * f * b;
        ((wr * a + 0.4 * core).min(1.0), (wg * a + 0.3 * core).min(1.0), (wb * a + 0.2 * core).min(1.0))
    }

    /// Screen blend of `leak` over a premultiplied picture (the leak counts as much as the picture's alpha).
    pub fn screen(base: (f64, f64, f64), alpha: f64, l: (f64, f64, f64)) -> (f64, f64, f64) {
        (
            base.0 + l.0 * alpha * (1.0 - base.0),
            base.1 + l.1 * alpha * (1.0 - base.1),
            base.2 + l.2 * alpha * (1.0 - base.2),
        )
    }
}

/// Blur Dissolve: the blur radius peaks (as a bell) in the middle of the span.
pub mod blur_dissolve {
    /// Largest radius, fraction of the frame height.
    pub const MAX_RADIUS: f64 = 0.02;

    /// Radius at `progress`.
    pub fn radius(progress: f64) -> f64 {
        MAX_RADIUS * (progress.clamp(0.0, 1.0) * std::f64::consts::PI).sin().max(0.0)
    }
}

/// A colored band centered on the transition's moving edge. The color is working-space linear.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Border {
    /// Full width, frame fraction along the travel direction.
    pub width: f64,
    /// Red, linear.
    pub r: f64,
    /// Green, linear.
    pub g: f64,
    /// Blue, linear.
    pub b: f64,
}

impl Border {
    /// `None` unless `width` > 0. `color`: display-encoded RGB bytes (`None` or not three bytes = white), linearized with the
    /// BT.709 inverse OETF.
    pub fn new(width: Option<f64>, color: Option<&[u8]>) -> Option<Border> {
        let w = width.filter(|w| w.is_finite() && *w > 0.0)?;
        let lin = |v: u8| {
            let x = f64::from(v) / 255.0;
            if x < 0.081 { x / 4.5 } else { ((x + 0.099) / 1.099).powf(1.0 / 0.45) }
        };
        let c = color.and_then(|c| <[u8; 3]>::try_from(c).ok()).unwrap_or([255, 255, 255]);
        Some(Border {
            width: w.min(<TransitionKind as TransitionKindExt>::MAX_BORDER_WIDTH),
            r: lin(c[0]),
            g: lin(c[1]),
            b: lin(c[2]),
        })
    }

    /// How much of the band covers a point at `x` (0...1 along the travel direction) when the edge is at `front`; `aa` = half
    /// a pixel along the direction, so the band edge is smooth; the band fades while `front` is within half a width of the
    /// frame edge.
    pub fn coverage(x: f64, front: f64, width: f64, aa: f64) -> f64 {
        let d = (x - front).abs();
        let h = width / 2.0;
        let a = aa.max(1e-6);
        // The band fades in over its own half width as the edge enters or leaves the frame: no solid strip on the first and
        // last frame.
        let enter = smoothstep(0.0, h, front) * smoothstep(0.0, h, 1.0 - front);
        (1.0 - smoothstep(h - a, h + a, d)) * enter
    }
}

/// What `TransitionRender::evaluate` needs besides the frame: the transition's effective style and which sides exist.
#[derive(Clone, Debug)]
pub struct RenderStyle<'a> {
    /// Kind.
    pub kind: TransitionKind,
    /// Render direction (already reversed when the transition is).
    pub direction: TransitionDirection,
    /// Soft edge.
    pub softness: f64,
    /// Motion blur shutter in frames.
    pub motion_blur: f64,
    /// Progress curve.
    pub easing: &'a EasingCurve,
    /// A tail transition (an outgoing clip, nothing after it) has no incoming picture: Slide and Zoom Pop play mirrored.
    pub has_incoming: bool,
    /// A head transition has no outgoing picture.
    pub has_outgoing: bool,
    /// Zoom In / Out amount (scale, 1.1 = 110 %).
    pub zoom_amount: f64,
    /// Zoom In / Out with a stored Amount: the settling zoom.
    pub zoom_settles: bool,
    /// Border along the moving edge.
    pub border: Option<Border>,
}

impl<'a> RenderStyle<'a> {
    /// A style for a cut (both sides), the default zoom amount and no border.
    pub fn new(
        kind: TransitionKind,
        direction: TransitionDirection,
        softness: f64,
        motion_blur: f64,
        easing: &'a EasingCurve,
    ) -> Self {
        RenderStyle {
            kind,
            direction,
            softness,
            motion_blur,
            easing,
            has_incoming: true,
            has_outgoing: true,
            zoom_amount: TransitionRender::ZOOM_AMOUNT,
            zoom_settles: false,
            border: None,
        }
    }
}

/// One frame of a motion transition: both sides (each composited alone into a transparent frame first) and how they combine.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionRender {
    /// The outgoing picture.
    pub outgoing: TransitionSide,
    /// The incoming picture.
    pub incoming: TransitionSide,
    /// How the two combine.
    pub compose: Compose,
    /// The moving edge.
    pub wipe: Wipe,
    /// Glitch state.
    pub glitch: Glitch,
    /// Border drawn over the moving edge (`wipe` locates it); `None` = none.
    pub border: Option<Border>,
}

impl Default for TransitionRender {
    fn default() -> Self {
        TransitionRender {
            outgoing: TransitionSide::default(),
            incoming: TransitionSide::default(),
            compose: Compose::Sum,
            wipe: Wipe::new(Vec2::ZERO, 0.0, 0.0),
            glitch: Glitch::default(),
            border: None,
        }
    }
}

impl TransitionRender {
    /// Spin: the largest rotation of either picture, radians (90 degrees).
    pub const SPIN_ANGLE: f64 = FRAC_PI_2;
    /// Cross Zoom: A grows to 1 + this, B settles from 1 + this.
    pub const CROSS_ZOOM_AMOUNT: f64 = 0.4;
    /// Cross Zoom radial smear: `CROSS_ZOOM_BLUR * bell * motionBlur`.
    pub const CROSS_ZOOM_BLUR: f64 = 0.35;
    /// Spin smear.
    pub const SPIN_BLUR: f64 = 0.12;
    /// Strobe Cut: A and B alternate over this many equal parts (even = A, odd = B), so it ends on B.
    pub const STROBE_PARTS: i64 = 6;
    /// Zoom Pop's 110 % -> 100 %.
    const POP_SCALE: f64 = 0.1;
    /// Zoom Pop's fading radial smear.
    const POP_BLUR: f64 = 0.04;
    /// Zoom In / Out: both layers scale between 100 % and this.
    pub const ZOOM_AMOUNT: f64 = 1.1;
    /// Zoom In / Out: A's opacity fade over B at the transition point, in frames.
    pub const ZOOM_FADE_FRAMES: f64 = 3.0;
    /// Zoom In / Out speed curve exponent.
    const ZOOM_CURVE: f64 = 3.0;

    /// Scale at which a picture rotated by `angle` still covers a frame up to 16:9.
    pub fn cover_scale(angle: f64) -> f64 {
        angle.abs().cos() + angle.abs().sin() * 16.0 / 9.0
    }

    /// B's progress in a settling Zoom In: starts at full speed, passes its rest by 6 % of the way at half time and comes back
    /// with no speed left: `1 - (1 - u)^3 (1 - 3u)`.
    fn zoom_settle(u: f64) -> f64 {
        let u = u.clamp(0.0, 1.0);
        1.0 - (1.0 - u).powi(3) * (1.0 - 3.0 * u)
    }

    /// Zoom In / Out: B sits under A; A fades out over `ZOOM_FADE_FRAMES` centered on the middle of the span. A plays its move
    /// from the span start to the end of that fade, B from the start of the fade to the span end, both 100 -> amount %
    /// (Zoom Out: amount -> 100 %). Single-sided ones play their side's move over the whole span and fade in (head) / out
    /// (tail). The radial blur is each layer's relative scale change during the shutter. Positions are in frames
    /// (`frame_index + 1` of `frames + 1`).
    ///
    /// `zoom_settles` (a transition with a stored Amount): the move ends at rest on both span edges.
    fn zoom_layers(s: &RenderStyle<'_>, i: i64, n: i64) -> TransitionRender {
        let zoom_in = s.kind == TransitionKind::ZoomIn;
        let settles = s.zoom_settles;
        let total = (n + 1) as f64;
        let pos = (i + 1) as f64;
        let fade = Self::ZOOM_FADE_FRAMES.min(total / 2.0).max(1.0);
        let mid = total / 2.0;
        let a_end = if s.has_incoming { mid + fade / 2.0 } else { total };
        let b_start = if s.has_outgoing { mid - fade / 2.0 } else { 0.0 };
        let k = Self::ZOOM_CURVE;
        let delta = s.zoom_amount.max(1.0) - 1.0;
        let scale = |p: f64| if zoom_in { 1.0 + delta * p } else { 1.0 + delta * (1.0 - p) };
        let big = s.zoom_amount.max(1.0);
        let small = 1.0 / big;
        let a_scale = |x: f64| {
            let p = (x / a_end).clamp(0.0, 1.0).powf(k);
            if settles { 1.0 + ((if zoom_in { big } else { small }) - 1.0) * p } else { scale(p) }
        };
        let b_scale = |x: f64| {
            let u = ((x - b_start) / (total - b_start)).clamp(0.0, 1.0);
            if !settles {
                return scale(1.0 - (1.0 - u).powf(k));
            }
            // Zoom In lands from below and may swing past 100 % (never shows an edge); Zoom Out lands from above without.
            let from = if zoom_in { small } else { big };
            from + (1.0 - from) * if zoom_in { Self::zoom_settle(u) } else { 1.0 - (1.0 - u).powi(4) }
        };
        let h = s.motion_blur.max(0.0) / 2.0;
        let blur = |f: &dyn Fn(f64) -> f64| (f(pos + h) - f(pos - h)).abs() / f(pos);
        let mut a_opacity = 0.0;
        let mut b_opacity = 0.0;
        if s.has_outgoing {
            a_opacity = ((a_end - pos) / fade).clamp(0.0, 1.0);
        }
        if s.has_incoming {
            b_opacity = if s.has_outgoing { if pos > b_start { 1.0 } else { 0.0 } } else { (pos / fade).min(1.0) };
        }
        TransitionRender {
            outgoing: TransitionSide {
                scale: a_scale(pos),
                opacity: a_opacity,
                zoom_blur: blur(&a_scale),
                mirror_edges: settles && !zoom_in,
                ..TransitionSide::default()
            },
            incoming: TransitionSide {
                scale: b_scale(pos),
                opacity: b_opacity,
                zoom_blur: blur(&b_scale),
                mirror_edges: settles && zoom_in,
                ..TransitionSide::default()
            },
            compose: Compose::OutgoingOver,
            ..TransitionRender::default()
        }
    }

    /// The state on frame `i` of `n`. Progress is `TransitionMix::video_weight` through the easing. Motion blur is physical:
    /// the distance travelled during `motion_blur` frames of shutter at the current (eased) speed.
    pub fn evaluate(s: &RenderStyle<'_>, i: i64, n: i64) -> TransitionRender {
        use TransitionKind as K;
        let easing = s.easing;
        let raw = TransitionMix::video_weight(i, n);
        let dt = 1.0 / (n + 1) as f64;
        let e = easing.progress(raw);
        // A curve may run outside 0...1 (overshoot): the moves follow it, the opacities of Spin / Cross Zoom do not.
        let w = e.clamp(0.0, 1.0);
        // Progress covered by one frame of shutter around this instant.
        let blur_gain = s.motion_blur.max(0.0);
        let de = (easing.progress(raw + dt / 2.0) - easing.progress(raw - dt / 2.0)) * blur_gain;
        let v = s.direction.vector();
        let along = |k: f64| Vec2::new(v.x * k, v.y * k);
        let sign = if v.x + v.y > 0.0 { 1.0 } else { -1.0 };
        let soft = s.softness.clamp(0.0, 0.5);
        let side = TransitionSide::default;
        let mut r = TransitionRender::default();
        match s.kind {
            K::Push | K::Whip => {
                let blur = along(de);
                r.outgoing = TransitionSide { offset: along(e), blur, ..side() };
                r.incoming = TransitionSide { offset: along(e - 1.0), blur, ..side() };
                r.compose = Compose::Sum;
                if let (K::Push, Some(b)) = (s.kind, s.border) {
                    r.border = Some(b);
                    r.wipe = Wipe::new(v, e, 0.0);
                }
            }
            K::Slide if !s.has_incoming => {
                // The slide-in played backwards in time but still traveling along `direction`: A leaves, accelerating.
                let eo = 1.0 - easing.progress(1.0 - raw);
                r.outgoing = TransitionSide { offset: along(eo), blur: along(de), ..side() };
                r.compose = Compose::Sum;
                if let Some(b) = s.border {
                    r.border = Some(b);
                    r.wipe = Wipe::new(v, eo, 0.0);
                }
            }
            K::Slide => {
                r.incoming = TransitionSide { offset: along(e - 1.0), blur: along(de), ..side() };
                r.compose = Compose::IncomingOver;
                if let Some(b) = s.border {
                    r.border = Some(b);
                    r.wipe = Wipe::new(v, e, 0.0);
                }
            }
            K::ZoomIn | K::ZoomOut => return Self::zoom_layers(s, i, n),
            K::ZoomPop if !s.has_incoming => {
                // The pop-in reversed in time: A grows towards 110 %, the smear builds and it fades out at the end.
                let back = 1.0 - raw;
                let sa = 1.0 + Self::POP_SCALE * (1.0 - easing.progress(back));
                let pop = Self::POP_BLUR * (1.0 - back / 0.3).max(0.0);
                r.outgoing = TransitionSide {
                    scale: sa,
                    opacity: (back / 0.15).min(1.0),
                    zoom_blur: pop + Self::POP_SCALE * de / sa,
                    ..side()
                };
                r.compose = Compose::OutgoingOver;
            }
            K::ZoomPop => {
                let sb = 1.0 + Self::POP_SCALE * (1.0 - e);
                let pop = Self::POP_BLUR * (1.0 - raw / 0.3).max(0.0);
                r.incoming = TransitionSide {
                    scale: sb,
                    opacity: (raw / 0.15).min(1.0),
                    zoom_blur: pop + Self::POP_SCALE * de / sb,
                    ..side()
                };
                r.compose = Compose::IncomingOver;
            }
            K::SoftWipe => {
                r.wipe = Wipe::new(v, e * (1.0 + 2.0 * soft) - soft, soft);
                r.compose = Compose::Wipe;
                r.border = s.border;
            }
            K::Iris => {
                r.wipe = Wipe::new(v, e * (1.0 + 2.0 * soft) - soft, soft);
                r.compose = Compose::Iris;
            }
            K::LightLeak => {
                r.wipe = Wipe::new(v, e, soft);
                r.compose = Compose::LightLeak;
            }
            K::BlurDissolve => {
                r.wipe = Wipe::new(v, e, blur_dissolve::radius(raw));
                r.compose = Compose::BlurDissolve;
            }
            K::Spin => {
                let (ta, tb) = (sign * Self::SPIN_ANGLE * e, sign * Self::SPIN_ANGLE * (e - 1.0));
                let bell = (raw * PI).sin() * Self::SPIN_BLUR * blur_gain;
                r.outgoing = TransitionSide {
                    scale: Self::cover_scale(ta),
                    opacity: 1.0 - w,
                    zoom_blur: bell,
                    rotation: ta,
                    ..side()
                };
                r.incoming = TransitionSide {
                    scale: Self::cover_scale(tb),
                    opacity: w,
                    zoom_blur: bell,
                    rotation: tb,
                    ..side()
                };
                r.compose = Compose::Sum;
            }
            K::CrossZoom => {
                let blur = (raw * PI).sin() * Self::CROSS_ZOOM_BLUR * blur_gain;
                r.outgoing = TransitionSide {
                    scale: 1.0 + Self::CROSS_ZOOM_AMOUNT * e,
                    opacity: 1.0 - w,
                    zoom_blur: blur,
                    ..side()
                };
                r.incoming = TransitionSide {
                    scale: 1.0 + Self::CROSS_ZOOM_AMOUNT * (1.0 - e),
                    opacity: w,
                    zoom_blur: blur,
                    ..side()
                };
                r.compose = Compose::Sum;
            }
            K::StrobeCut => {
                let part = (Self::STROBE_PARTS - 1).min((raw * Self::STROBE_PARTS as f64) as i64);
                let show_b = part % 2 == 1;
                r.outgoing = TransitionSide { opacity: if show_b { 0.0 } else { 1.0 }, ..side() };
                r.incoming = TransitionSide { opacity: if show_b { 1.0 } else { 0.0 }, ..side() };
                r.compose = Compose::Sum;
            }
            K::StaticNoise => {
                r.glitch = Glitch {
                    mix: raw,
                    intensity: (0.2 + 0.8 * (raw * PI).sin()).min(1.0),
                    seed: (i as u32).wrapping_mul(2_654_435_761).wrapping_add(777),
                };
                r.compose = Compose::StaticNoise;
            }
            K::LightNoise => {
                r.wipe = Wipe::new(v, e, 0.0);
                r.compose = Compose::LightNoise;
            }
            K::MosaicDissolve => {
                r.wipe = Wipe::new(v, e, 0.0);
                r.compose = Compose::Mosaic;
            }
            K::Flip3D | K::Burn | K::Flare | K::Warp | K::Shake => {
                r.wipe = Wipe::new(v, w, 0.0);
                r.compose = match s.kind {
                    K::Flip3D => Compose::Flip3D,
                    K::Burn => Compose::Burn,
                    K::Flare => Compose::Flare,
                    K::Warp => Compose::Warp,
                    _ => Compose::Shake,
                };
            }
            K::Spring if !s.has_incoming => {
                // Nothing to settle: A just slides out along the direction.
                r.outgoing = TransitionSide { offset: along(e), blur: along(de), ..side() };
                r.compose = Compose::Sum;
            }
            K::Spring => {
                // B slides in along `direction` and settles with a small overshoot; A stays under it.
                let sp = spring_fall::spring(e);
                let ds = (spring_fall::spring(easing.progress(raw + dt / 2.0))
                    - spring_fall::spring(easing.progress(raw - dt / 2.0)))
                    * blur_gain;
                r.incoming = TransitionSide { offset: along(sp - 1.0), blur: along(ds), ..side() };
                r.compose = Compose::IncomingOver;
            }
            K::Fall => {
                // A drops out along `direction`, accelerating and tilting; B waits under it.
                let f = spring_fall::fall(e);
                let df = (spring_fall::fall(easing.progress(raw + dt / 2.0))
                    - spring_fall::fall(easing.progress(raw - dt / 2.0)))
                    * blur_gain;
                r.outgoing = TransitionSide {
                    offset: along(f),
                    blur: along(df),
                    rotation: sign * spring_fall::TILT * f,
                    ..side()
                };
                r.compose = Compose::OutgoingOver;
            }
            K::AdditiveDissolve => {
                // Both pictures at full strength over the middle, so the sum brightens (clipped by the display).
                r.outgoing = TransitionSide { opacity: (2.0 * (1.0 - w)).min(1.0), ..side() };
                r.incoming = TransitionSide { opacity: (2.0 * w).min(1.0), ..side() };
                r.compose = Compose::Sum;
            }
            K::ClockWipe
            | K::BoxIris
            | K::DiamondIris
            | K::CrossIris
            | K::BarnDoors
            | K::VenetianBlinds
            | K::RadialWipe
            | K::WedgeWipe
            | K::Pinwheel
            | K::CheckerWipe
            | K::ZigZagBlocks
            | K::InsetWipe
            | K::RandomBlocks
            | K::SliceWipe => {
                use shape_wipe::Shape;
                let shape = match s.kind {
                    K::ClockWipe => Shape::Clock,
                    K::BoxIris => Shape::Box,
                    K::DiamondIris => Shape::Diamond,
                    K::CrossIris => Shape::Cross,
                    K::BarnDoors => {
                        if matches!(s.direction, TransitionDirection::Left | TransitionDirection::Right) {
                            Shape::DoorsAcross
                        } else {
                            Shape::DoorsDown
                        }
                    }
                    K::RadialWipe => Shape::Radial,
                    K::WedgeWipe => Shape::Wedge,
                    K::Pinwheel => Shape::Pinwheel,
                    K::CheckerWipe => Shape::Checker,
                    K::ZigZagBlocks => Shape::ZigZag,
                    K::InsetWipe => Shape::Inset,
                    K::RandomBlocks => Shape::Random,
                    K::SliceWipe => Shape::Slice,
                    _ => Shape::Blinds,
                };
                r.wipe = Wipe::new(Vec2::new(f64::from(shape as i32), 0.0), e * (1.0 + 2.0 * soft) - soft, soft);
                r.compose = Compose::Shape;
            }
            K::Glitch => {
                r.glitch = Glitch {
                    mix: raw,
                    intensity: (raw * PI).sin(),
                    seed: (i as u32).wrapping_mul(2_654_435_761).wrapping_add(12345),
                };
                r.compose = Compose::Glitch;
            }
            _ => {}
        }
        r
    }
}
