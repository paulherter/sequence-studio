// Swift: Compositor+Uniforms.swift
//! The layer draw's uniform blocks and placement maths (`CompositeU`, `ConvertU`, `PreBlurU`, `TransitionU` of
//! `shaders-src`), shared by every draw the compositor records. The blocks serialize with [`Block`] in the byte layout of
//! their Slang twins (sizes and offsets are tested).

use sq_core_effects::transition::{Compose, TransitionRender, TransitionSide};
use sq_core_masks::perspective_tilt as tilt;
use sq_core_model::{ClipTransform, SequenceFormat};
use sq_core_time::Vec2;

use super::block::Block;
use super::layer::PlaceholderKind;

/// Bytes of `CompositeU`.
pub const UNIFORMS_BYTES: usize = 368;

/// `CompositeU`: one layer draw.
#[derive(Clone, Debug, PartialEq)]
pub struct Uniforms {
    /// Y'CbCr to R'G'B' (columns).
    pub m: [[f32; 3]; 3],
    pub solid: [f32; 4],
    pub range: [f32; 4],
    pub canvas: [f32; 2],
    pub size: [f32; 2],
    pub position: [f32; 2],
    pub anchor: [f32; 2],
    pub scale: [f32; 2],
    pub rot_cos: f32,
    pub rot_sin: f32,
    pub opacity: f32,
    pub mode: u32,
    pub linearize: u32,
    pub corner_radius: f32,
    /// Clockwise quarter turns of a source picture (0...3): the layer quad is upright, the texture lookup turns.
    pub quarter: u32,
    /// Blend mode id for the blending pipeline (0 = normal; see `blend_modes::shader_id`).
    pub blend: u32,
    /// Size of the rectangle Crop and Rounded Corners work on (the layer's own picture); zero = `size`.
    pub mask_size: [f32; 2],
    /// Crop insets as fractions of `mask_size`: left, top, right, bottom.
    pub crop: [f32; 4],
    /// Ultra Keys: hue, half width, soft edge, spill; `key_count` of them are used.
    pub key0: [f32; 4],
    pub key1: [f32; 4],
    /// Matte shaping per key: shrink / grow, pedestal, output, mode.
    pub matte0: [f32; 4],
    pub matte1: [f32; 4],
    /// Matte contrast / midpoint / keep highlights / keep shadows.
    pub shape0: [f32; 4],
    pub shape1: [f32; 4],
    /// Color correction per key (saturation, hue shift in radians, brightness, spill range).
    pub cc0: [f32; 4],
    pub cc1: [f32; 4],
    pub key_count: u32,
    /// 1 = Rounded Corners came before Crop.
    pub round_first: u32,
    /// Texture alpha of modes 1 and 4: 0 = legacy, 1 = straight, 2 = premultiplied.
    pub alpha_mode: u32,
    /// Clip masks in the draw's mask buffer; 0 = none.
    pub mask_count: u32,
    /// Crop Softness in layer px; 0 = hard.
    pub crop_feather: f32,
    /// A partial buffer drawn as the whole picture (mode 3): where `tex0` lies in it (x, y) and the whole picture's
    /// size (z, w); z = 0: `tex0` is the whole picture.
    pub part: [f32; 4],
    /// Perspective tilt: x / y turn in radians about the anchor and the camera distance in px (0 = flat).
    pub tilt: [f32; 3],
}

impl Default for Uniforms {
    fn default() -> Uniforms {
        Uniforms {
            m: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            solid: [0.0, 0.0, 0.0, 1.0],
            range: [1.0, 0.0, 1.0, 0.0],
            canvas: [1.0, 1.0],
            size: [1.0, 1.0],
            position: [0.0, 0.0],
            anchor: [0.0, 0.0],
            scale: [1.0, 1.0],
            rot_cos: 1.0,
            rot_sin: 0.0,
            opacity: 1.0,
            mode: 0,
            linearize: 1,
            corner_radius: 0.0,
            quarter: 0,
            blend: 0,
            mask_size: [0.0, 0.0],
            crop: [0.0; 4],
            key0: [0.0; 4],
            key1: [0.0; 4],
            matte0: [0.0; 4],
            matte1: [0.0; 4],
            shape0: [0.0, 0.5, 0.0, 0.0],
            shape1: [0.0, 0.5, 0.0, 0.0],
            cc0: [1.0, 0.0, 1.0, 0.5],
            cc1: [1.0, 0.0, 1.0, 0.5],
            key_count: 0,
            round_first: 0,
            alpha_mode: 0,
            mask_count: 0,
            crop_feather: 0.0,
            part: [0.0; 4],
            tilt: [0.0; 3],
        }
    }
}

impl Uniforms {
    /// The 368 bytes of `CompositeU`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut b = Block::new();
        b.mat3(self.m).vec4(self.solid).vec4(self.range);
        b.vec2(self.canvas).vec2(self.size).vec2(self.position).vec2(self.anchor).vec2(self.scale);
        b.f32(self.rot_cos).f32(self.rot_sin).f32(self.opacity);
        b.u32(self.mode).u32(self.linearize).f32(self.corner_radius).u32(self.quarter).u32(self.blend);
        b.vec2(self.mask_size).vec4(self.crop);
        b.vec4(self.key0).vec4(self.key1).vec4(self.matte0).vec4(self.matte1);
        b.vec4(self.shape0).vec4(self.shape1).vec4(self.cc0).vec4(self.cc1);
        b.u32(self.key_count).u32(self.round_first).u32(self.alpha_mode).u32(self.mask_count).f32(self.crop_feather);
        b.vec4(self.part).vec3(self.tilt);
        b.finish(16)
    }

    /// Fills the placement fields (`CompositeU`: canvas, size, transform, opacity, corner radius and tilt).
    ///
    /// Display space: with a non-square pixel shape the canvas is the picture as shown; its edges still map to the whole
    /// target in the vertex stage, which squeezes it into the stored pixels. Square: unchanged.
    pub fn layer_geometry(&mut self, t: &ClipTransform, canvas: &SequenceFormat, size: [f32; 2], corner_radius: f64) {
        self.corner_radius = corner_radius.max(0.0) as f32;
        self.canvas = [canvas.display_width() as f32, canvas.height as f32];
        self.size = size;
        self.position = [t.position.x as f32, t.position.y as f32];
        self.anchor = [t.anchor.x as f32, t.anchor.y as f32];
        self.scale = [t.scale.x.max(0.0) as f32, t.scale.y.max(0.0) as f32];
        let r = t.rotation * std::f64::consts::PI / 180.0;
        self.rot_cos = r.cos() as f32;
        self.rot_sin = r.sin() as f32;
        self.opacity = t.opacity.clamp(0.0, 1.0) as f32;
        // Picture masks and effect mask scopes read `screenFromLocal`, which carries this tilt.
        if t.is_tilted() {
            let focal = f64::from(self.tilt_focal());
            let deg = std::f64::consts::PI / 180.0;
            self.tilt = [(tilt::clamped(t.tilt_x) * deg) as f32, (tilt::clamped(t.tilt_y) * deg) as f32, focal as f32];
        }
    }

    /// Camera distance (px) of a tilted draw, from the draw's own `size` (after any blur or shadow padding), anchor, scale
    /// and canvas, so the depth never reaches the camera plane (`focal(layer_radius + 2)`, as the overlay does).
    pub fn tilt_focal(&self) -> f32 {
        let v = |a: [f32; 2]| Vec2::new(f64::from(a[0]), f64::from(a[1]));
        let r = tilt::layer_radius(v(self.size), v(self.anchor), v(self.scale));
        tilt::focal(r + 2.0, v(self.canvas)) as f32
    }
}

/// `ConvertU`: where the dispatch starts and the source curve of the half-size average (`u32::MAX`: plain average).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConvertUniforms {
    pub origin: [u32; 2],
    pub transfer: u32,
}

impl ConvertUniforms {
    /// The 16 bytes of `ConvertU`.
    pub fn to_bytes(self) -> Vec<u8> {
        let mut b = Block::new();
        b.u32(self.origin[0]).u32(self.origin[1]).u32(self.transfer).u32(0);
        b.finish(8)
    }
}

/// `PreBlurU` (16 bytes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreBlurUniforms {
    pub canvas: [f32; 2],
    pub pad: f32,
    pub slot: u32,
}

impl PreBlurUniforms {
    pub fn to_bytes(self) -> Vec<u8> {
        let mut b = Block::new();
        b.vec2(self.canvas).f32(self.pad).u32(self.slot);
        b.finish(8)
    }
}

/// `TransitionSideU` (40 bytes; `TransitionU` 120).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionSideUniforms {
    pub offset: [f32; 2],
    pub blur: [f32; 2],
    pub scale: f32,
    pub opacity: f32,
    pub zoom_blur: f32,
    pub taps: f32,
    /// Rotation (radians) about the frame center, in pixel space.
    pub rotation: f32,
    /// 1 = mirrored repeat outside the picture (a settling Zoom In / Out side below 100 %), 0 = transparent.
    pub mirror: f32,
}

impl TransitionSideUniforms {
    pub fn new(s: &TransitionSide) -> TransitionSideUniforms {
        TransitionSideUniforms {
            offset: [s.offset.x as f32, s.offset.y as f32],
            blur: [s.blur.x as f32, s.blur.y as f32],
            scale: s.scale.max(1e-4) as f32,
            opacity: s.opacity.clamp(0.0, 1.0) as f32,
            zoom_blur: s.zoom_blur as f32,
            taps: 0.0,
            rotation: s.rotation as f32,
            mirror: if s.mirror_edges { 1.0 } else { 0.0 },
        }
    }

    /// The 40 bytes of `TransitionSideU`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut b = Block::new();
        self.write(&mut b);
        b.finish(8)
    }

    fn write(&self, b: &mut Block) {
        b.vec2(self.offset).vec2(self.blur);
        b.f32(self.scale).f32(self.opacity).f32(self.zoom_blur).f32(self.taps).f32(self.rotation).f32(self.mirror);
    }

    /// A directional smear longer than one pass covers smoothly (64 taps at 1.5 px) is split in two: a pre-pass that
    /// places the side on the canvas with a box smear of one comb spacing (returned; `None` when not needed), and `taps`
    /// comb taps here on that already placed picture. Box * comb = the full box, samples never more than ~1.5 px apart.
    /// The returned `pad` is how far (canvas fraction, every side) the pre-pass canvas reaches past the frame; this side
    /// then samples it at scale `1 + 2 pad`.
    pub fn split_long_blur(&mut self, canvas: [f32; 2]) -> Option<(TransitionSideUniforms, f32)> {
        if self.opacity <= 0.0 || self.zoom_blur != 0.0 {
            return None;
        }
        let d = [self.blur[0] * canvas[0], self.blur[1] * canvas[1]]; // canvas px: the smear is `blur` on screen
        let len = (d[0] * d[0] + d[1] * d[1]).sqrt();
        if len <= 96.0 {
            return None;
        }
        let m = (len / 96.0).ceil().min(256.0);
        let mut pre = *self;
        pre.blur = [self.blur[0] / m, self.blur[1] / m];
        pre.opacity = 1.0;
        pre.taps = 0.0;
        let pad = (d[0].abs() / canvas[0]).max(d[1].abs() / canvas[1]) / 2.0 + 2.0 / canvas[0].min(canvas[1]);
        let pad = pad.min(1.0);
        self.offset = [0.0, 0.0];
        self.scale = 1.0 + 2.0 * pad;
        self.mirror = 0.0; // the pre-pass already filled its canvas
        let keep = 1.0 - 1.0 / m;
        self.blur = [self.blur[0] * keep, self.blur[1] * keep];
        self.taps = m;
        Some((pre, pad))
    }
}

/// `TransitionU` (120 bytes): both sides and how they combine.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionUniforms {
    pub a: TransitionSideUniforms,
    pub b: TransitionSideUniforms,
    pub wipe_dir: [f32; 2],
    pub wipe_front: f32,
    pub wipe_soft: f32,
    pub compose: u32,
    /// Border band (0 = off), working-linear color.
    pub border_width: f32,
    pub border_rgb: [f32; 3],
}

impl TransitionUniforms {
    pub fn new(r: &TransitionRender) -> TransitionUniforms {
        let glitchy = matches!(r.compose, Compose::Glitch | Compose::StaticNoise);
        let mut u = TransitionUniforms {
            a: TransitionSideUniforms::new(&r.outgoing),
            b: TransitionSideUniforms::new(&r.incoming),
            wipe_dir: [r.wipe.direction.x as f32, r.wipe.direction.y as f32],
            wipe_front: r.wipe.front as f32,
            wipe_soft: r.wipe.softness.max(0.0) as f32,
            compose: r.compose as u32,
            border_width: 0.0,
            border_rgb: [0.0; 3],
        };
        if let Some(b) = r.border.filter(|_| !glitchy) {
            u.border_width = b.width as f32;
            u.border_rgb = [b.r as f32, b.g as f32, b.b as f32];
        }
        if glitchy {
            // Glitch reuses the wipe fields: dir.x = seed bits, front = mix, soft = intensity.
            u.wipe_dir = [f32::from_bits(r.glitch.seed), 0.0];
            u.wipe_front = r.glitch.mix as f32;
            u.wipe_soft = r.glitch.intensity as f32;
        }
        u
    }

    /// The 120 bytes of `TransitionU`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut b = Block::new();
        self.a.write(&mut b);
        self.b.write(&mut b);
        b.vec2(self.wipe_dir).f32(self.wipe_front).f32(self.wipe_soft).u32(self.compose);
        b.f32(self.border_width).f32(self.border_rgb[0]).f32(self.border_rgb[1]).f32(self.border_rgb[2]);
        b.finish(8)
    }
}

/// Size of a long blur's pre-pass texture: `(pad, width, height)` for a `width` x `height` transition canvas grown by
/// `pad` on every side. The pad is rounded up to 1/16 of the canvas, so an animated blur draws into a few recurring sizes
/// the pool reuses instead of a new texture every frame. Larger than `max_side` (frames wider than 16384 / 3 at pad 1),
/// both sides shrink together: both passes address that canvas in normalized coordinates and the picture on it is already
/// smeared over a comb spacing of at least ~48 canvas px, so drawing it at up to 3x fewer pixels shows nothing.
pub fn long_blur_target(width: i64, height: i64, pad: f32, max_side: i64) -> (f32, i64, i64) {
    let q = ((pad.max(0.0) * 16.0).ceil() / 16.0).min(1.0);
    let bw = (width as f32 * (1.0 + 2.0 * q)).ceil();
    let bh = (height as f32 * (1.0 + 2.0 * q)).ceil();
    let s = (max_side as f32 / bw.max(bh)).min(1.0);
    if s >= 1.0 {
        return (q, bw as i64, bh as i64);
    }
    let fit = |v: f32| ((v * s).round() as i64).clamp(1, max_side);
    (q, fit(bw), fit(bh))
}

/// Inverse BT.709 OETF: display-encoded to working-linear.
pub fn lin(e: f32) -> f32 {
    if e < 0.081_242_86 { e / 4.5 } else { ((e + 0.099_296_83) / 1.099_296_8).powf(1.0 / 0.45) }
}

/// Placeholder display colors (sRGB-ish, then linearized): offline = dark red, damaged = amber, loading = gray.
pub fn placeholder_linear(k: PlaceholderKind) -> [f32; 4] {
    let d = match k {
        PlaceholderKind::Offline => [0.45, 0.10, 0.10],
        PlaceholderKind::Damaged => [0.45, 0.33, 0.05],
        PlaceholderKind::Loading => [0.20, 0.20, 0.20],
    };
    [lin(d[0]), lin(d[1]), lin(d[2]), 1.0]
}

/// Corner radii are given in px of the layer fitted into the canvas (what they meant before Scale became relative to
/// source pixels); the layer is now drawn at its own size, so the radius is converted: native / fitted.
pub fn radius_factor(w: i64, h: i64, canvas: &SequenceFormat) -> f64 {
    let fit = fit_size(w, h, canvas.display_width(), canvas.height);
    if fit[0] > 0.0 { f64::from(w as f32 / fit[0]) } else { 1.0 }
}

/// Aspect-fit size of `w x h` into the canvas `cw x ch`.
pub fn fit_size(w: i64, h: i64, cw: i64, ch: i64) -> [f32; 2] {
    let s = (cw as f32 / w as f32).min(ch as f32 / h as f32);
    [w as f32 * s, h as f32 * s]
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn format(w: i64, h: i64) -> SequenceFormat {
        SequenceFormat {
            width: w,
            height: h,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        }
    }

    #[test]
    fn uniform_blocks_match_the_slang_sizes() {
        // Swift CompositorUniformLayoutTests.
        assert_eq!(Uniforms::default().to_bytes().len(), 368, "CompositeU");
        assert_eq!(TransitionUniforms::new(&TransitionRender::default()).to_bytes().len(), 120, "TransitionU");
        let mut b = Block::new();
        TransitionSideUniforms::new(&TransitionSide::default()).write(&mut b);
        assert_eq!(b.len(), 40, "TransitionSideU");
        assert_eq!(ConvertUniforms { origin: [0, 0], transfer: 0 }.to_bytes().len(), 16);
        assert_eq!(PreBlurUniforms { canvas: [1.0, 1.0], pad: 0.0, slot: 0 }.to_bytes().len(), 16);
    }

    #[test]
    fn fields_land_at_the_slang_offsets() {
        let u = Uniforms {
            blend: 0x1111,
            alpha_mode: 0x2222,
            key_count: 0x3333,
            tilt: [1.0, 2.0, 3.0],
            ..Uniforms::default()
        };
        let bytes = u.to_bytes();
        let word = |off: usize| u32::from_le_bytes([bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3]]);
        assert_eq!(word(148), 0x1111, "blend");
        assert_eq!(word(312), 0x2222, "alphaMode");
        assert_eq!(word(304), 0x3333, "keyCount");
        assert_eq!(f32::from_bits(word(352)), 1.0, "tilt.x");
        assert_eq!(f32::from_bits(word(360)), 3.0, "tilt.z");
        assert_eq!(f32::from_bits(word(48 + 12)), 1.0, "solid.w after the 48-byte matrix");
    }

    #[test]
    fn geometry_places_the_layer() {
        let mut u = Uniforms::default();
        let mut t = ClipTransform::IDENTITY;
        t.position = Vec2::new(10.0, -4.0);
        t.rotation = 90.0;
        t.opacity = 1.5;
        t.scale = Vec2::new(-1.0, 2.0);
        u.layer_geometry(&t, &format(192, 128), [64.0, 48.0], -3.0);
        assert_eq!((u.canvas, u.size, u.position), ([192.0, 128.0], [64.0, 48.0], [10.0, -4.0]));
        assert_eq!((u.scale, u.opacity, u.corner_radius), ([0.0, 2.0], 1.0, 0.0));
        assert!(u.rot_cos.abs() < 1e-6 && (u.rot_sin - 1.0).abs() < 1e-6);
        assert_eq!(u.tilt, [0.0; 3]);
        t.tilt_x = 25.0;
        u.layer_geometry(&t, &format(192, 128), [64.0, 48.0], 0.0);
        assert!(u.tilt[0] > 0.4 && u.tilt[2] > 0.0);
    }

    #[test]
    fn long_blur_target_rounds_the_pad_and_shrinks_oversize() {
        assert_eq!(long_blur_target(1920, 1080, 0.0, 16384), (0.0, 1920, 1080));
        let (q, w, h) = long_blur_target(1920, 1080, 0.3, 16384);
        assert_eq!(q, 0.3125);
        assert_eq!((w, h), (3120, 1755));
        let (q, w, h) = long_blur_target(8000, 4000, 1.0, 16384);
        assert_eq!(q, 1.0);
        assert!(w <= 16384 && h <= 16384 && w > h);
    }

    #[test]
    fn a_long_smear_splits_in_a_pre_pass_and_comb_taps() {
        let mut side =
            TransitionSideUniforms::new(&TransitionSide { blur: Vec2::new(-1.5, 0.0), ..TransitionSide::default() });
        let (pre, pad) = side.split_long_blur([1920.0, 1080.0]).expect("split");
        assert_eq!(side.taps, 30.0); // 2880 px / 96
        assert_eq!(pre.taps, 0.0);
        assert!((pre.blur[0] + 0.05).abs() < 1e-6);
        assert!(pad > 0.7 && pad <= 1.0);
        assert!((side.scale - (1.0 + 2.0 * pad)).abs() < 1e-6);
        let mut short =
            TransitionSideUniforms::new(&TransitionSide { blur: Vec2::new(0.01, 0.0), ..TransitionSide::default() });
        assert!(short.split_long_blur([1920.0, 1080.0]).is_none());
    }

    #[test]
    fn placeholders_are_linearized() {
        assert_eq!(lin(0.0), 0.0);
        assert!((lin(1.0) - 1.0).abs() < 1e-5);
        assert!((placeholder_linear(PlaceholderKind::Loading)[0] - lin(0.2)).abs() < 1e-7);
        assert_eq!(radius_factor(192, 128, &format(192, 128)), 1.0);
        assert_eq!(fit_size(64, 48, 192, 128), [170.66667, 128.0]);
    }
}
