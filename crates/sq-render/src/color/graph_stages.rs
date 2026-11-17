// Swift: ColorGraphStages.swift
//! Pro grade (Color Graph) blocks. A Step lowers to: [step begin] primaries, curves, hue curves, LUT [step end]. The begin
//! / end pair only exists when the Step is limited by a qualifier or a window: begin keeps the Step's input (`n0`), end
//! mixes the Step's result back over it by the matte (qualifier on the input x window on the pixel position).

use sq_core_color::ColorQualifierExt;
use sq_core_model::{ColorQualifier, KeyMixMode, LayerMixMode, StepPrimaries, StepWindow, StepWindowShape};

use super::gamut::Gamut;
use super::stages::PreparedHslSecondary;
use super::tone_math::smooth;
use super::transfer::bt709_inverse_oetf as inv_oetf;
use super::transfer::bt709_oetf as oetf;
use super::vec::{Mat3, Vec3};

/// Step primaries on the display signal: lift, gain, offset, power (gamma) per channel, contrast about a pivot, then
/// saturation about the Rec.709 luma. Lift 0, contrast 1 = the ASC CDL.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedPrimaries {
    pub(crate) lift: Vec3,
    pub(crate) gamma: Vec3,
    pub(crate) gain: Vec3,
    pub(crate) offset: Vec3,
    pub(crate) contrast: f32,
    pub(crate) pivot: f32,
    pub(crate) saturation: f32,
    pub(crate) has_gamma: bool,
    pub(crate) has_contrast: bool,
    pub(crate) has_saturation: bool,
}

const PRIMARIES_LUMA: Vec3 = Vec3::new(0.2126, 0.7152, 0.0722);

impl PreparedPrimaries {
    /// Prepares the block.
    pub fn new(p: &StepPrimaries) -> PreparedPrimaries {
        let gamma = Vec3::new(p.gamma.r, p.gamma.g, p.gamma.b);
        PreparedPrimaries {
            lift: Vec3::new(p.lift.r, p.lift.g, p.lift.b),
            gamma,
            gain: Vec3::new(p.gain.r, p.gain.g, p.gain.b),
            offset: Vec3::new(p.offset.r, p.offset.g, p.offset.b),
            contrast: p.contrast,
            pivot: p.pivot,
            saturation: p.saturation,
            has_gamma: gamma != Vec3::ONE,
            has_contrast: p.contrast != 1.0,
            has_saturation: p.saturation != 1.0,
        }
    }

    /// Bit 0 gamma, bit 1 contrast, bit 2 saturation (GPU section flags).
    pub fn flags(&self) -> u32 {
        u32::from(self.has_gamma) | (u32::from(self.has_contrast) << 1) | (u32::from(self.has_saturation) << 2)
    }

    /// Applies the block.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let mut t = if pre { c.map(oetf) } else { c };
        t = t + self.lift * (Vec3::ONE - t);
        t = t * self.gain + self.offset;
        if self.has_gamma {
            for i in 0..3 {
                if t[i] > 0.0 && self.gamma[i] != 1.0 {
                    t[i] = t[i].powf(self.gamma[i]);
                }
            }
        }
        if self.has_contrast {
            t = (t - Vec3::splat(self.pivot)) * self.contrast + Vec3::splat(self.pivot);
        }
        if self.has_saturation {
            let y = PRIMARIES_LUMA.dot(t);
            t = Vec3::splat(y) + (t - Vec3::splat(y)) * self.saturation;
        }
        if pre { t.map(inv_oetf) } else { t }
    }
}

/// A Step window: an ellipse, a rectangle or a straight edge in picture space (uv 0...1, y down), rotated clockwise about
/// its center, with a soft edge. Width is a fraction of the picture width, height of its height.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedWindow {
    pub(crate) center: [f32; 2],
    pub(crate) half: [f32; 2],
    pub(crate) cos_r: f32,
    pub(crate) sin_r: f32,
    pub(crate) soft: f32,
    /// 0 ellipse, 1 rectangle, 2 linear.
    pub(crate) shape: f32,
    pub(crate) invert: bool,
}

impl PreparedWindow {
    /// Prepares the window.
    pub fn new(w: &StepWindow) -> PreparedWindow {
        let r = w.rotation * std::f32::consts::PI / 180.0;
        PreparedWindow {
            center: [w.center_x, w.center_y],
            half: [w.width.max(0.0) / 2.0, w.height.max(0.0) / 2.0],
            cos_r: r.cos(),
            sin_r: r.sin(),
            soft: w.softness.clamp(1e-3, 1.0),
            shape: match w.shape {
                StepWindowShape::Ellipse => 0.0,
                StepWindowShape::Rectangle => 1.0,
                StepWindowShape::Linear => 2.0,
            },
            invert: w.invert,
        }
    }

    /// Columns of the GPU section matrix: (cx, cy, half x), (half y, cos, sin), (soft, shape, invert).
    pub fn matrix(&self) -> Mat3 {
        Mat3::from_cols(
            Vec3::new(self.center[0], self.center[1], self.half[0]),
            Vec3::new(self.half[1], self.cos_r, self.sin_r),
            Vec3::new(self.soft, self.shape, if self.invert { 1.0 } else { 0.0 }),
        )
    }

    /// The window matte at a pixel (`aspect` = width / height).
    pub fn mask(&self, uv: [f32; 2], aspect: f32) -> f32 {
        let px = (uv[0] - self.center[0]) * aspect;
        let py = uv[1] - self.center[1];
        let qx = px * self.cos_r + py * self.sin_r;
        let qy = -px * self.sin_r + py * self.cos_r;
        let hx = (self.half[0] * aspect).max(1e-5);
        let hy = self.half[1].max(1e-5);
        let m = if self.shape < 0.5 {
            let (ex, ey) = (qx / hx, qy / hy);
            1.0 - smooth(1.0 - self.soft, 1.0, (ex * ex + ey * ey).sqrt())
        } else if self.shape < 1.5 {
            1.0 - smooth(1.0 - self.soft, 1.0, (qx.abs() / hx).max(qy.abs() / hy))
        } else {
            let e = (self.soft * hy).max(1e-4);
            1.0 - smooth(-e, e, qy)
        };
        if self.invert { 1.0 - m } else { m }
    }
}

/// One key wire arriving at a Step or a mixer box: the donor Step's key output (its qualifier and window), optionally
/// inverted ("outside"). `mode` combines it with the wires before it; `None` = the first wire, it sets the matte.
/// Same as Swift (ColorGraphStages.swift:92): the donor's qualifier is evaluated on the receiving Step's input, not on the donor's own input (the geometric
/// window is exact); upgrade when a Step's input can be kept per donor.
#[derive(Clone, Debug, PartialEq)]
pub struct KeyTerm {
    /// The donor's qualifier.
    pub qualifier: Option<ColorQualifier>,
    /// The donor's window.
    pub window: Option<StepWindow>,
    /// Read inverted.
    pub outside: bool,
    /// How it combines with the wires before it.
    pub mode: Option<KeyMixMode>,
}

/// A [`KeyTerm`] on the display signal.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedKeyTerm {
    pub(crate) qualifier: Option<PreparedHslSecondary>,
    pub(crate) window: Option<PreparedWindow>,
    pub(crate) outside: bool,
    /// 0 sets the matte (first wire), 1 add, 2 multiply, 3 subtract, 4 max.
    pub(crate) mode: u32,
}

impl PreparedKeyTerm {
    /// Prepares the term.
    pub fn new(k: &KeyTerm) -> PreparedKeyTerm {
        PreparedKeyTerm {
            qualifier: k.qualifier.as_ref().map(|q| PreparedHslSecondary::new(&q.as_color_range(), Gamut::rec709())),
            window: k.window.as_ref().map(PreparedWindow::new),
            outside: k.outside,
            mode: match k.mode {
                None => 0,
                Some(KeyMixMode::Add) => 1,
                Some(KeyMixMode::Multiply) => 2,
                Some(KeyMixMode::Subtract) => 3,
                Some(KeyMixMode::Max) => 4,
            },
        }
    }

    /// Bit 0 qualifier, bit 1 window, bit 2 outside, bits 5...7 mode (GPU section flags).
    pub fn flags(&self) -> u32 {
        u32::from(self.qualifier.is_some())
            | (u32::from(self.window.is_some()) << 1)
            | (u32::from(self.outside) << 2)
            | (self.mode << 5)
    }

    /// `km`: the matte so far; `input`: the receiving Step's input (`n0`).
    pub fn apply(&self, km: f32, input: Vec3, uv: [f32; 2], aspect: f32, pre: bool) -> f32 {
        let mut m = 1.0;
        if let Some(q) = &self.qualifier {
            m = q.mask(if pre { input.map(oetf) } else { input });
        }
        if let Some(w) = &self.window {
            m *= w.mask(uv, aspect);
        }
        if self.outside {
            m = 1.0 - m;
        }
        match self.mode {
            1 => (km + m).min(1.0),
            2 => km * m,
            3 => (km - m).max(0.0),
            4 => km.max(m),
            _ => m,
        }
    }
}

/// The end of a limited Step: how much of the Step's result each pixel keeps.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedStepMatte {
    pub(crate) qualifier: Option<PreparedHslSecondary>,
    pub(crate) window: Option<PreparedWindow>,
    /// 0...1, scales the matte.
    pub(crate) mix: f32,
    /// Key terms came before this end: the matte is also scaled by the key register.
    pub keyed: bool,
    /// Layer mix of a layer branch.
    pub(crate) blend: LayerMixMode,
}

impl PreparedStepMatte {
    /// Prepares the matte (`mix` clamped to 0...1).
    pub fn new(
        qualifier: Option<&ColorQualifier>,
        window: Option<&StepWindow>,
        mix: f32,
        keyed: bool,
        blend: LayerMixMode,
    ) -> PreparedStepMatte {
        PreparedStepMatte {
            mix: mix.clamp(0.0, 1.0),
            qualifier: qualifier.map(|q| PreparedHslSecondary::new(&q.as_color_range(), Gamut::rec709())),
            window: window.map(PreparedWindow::new),
            keyed,
            blend,
        }
    }

    /// The Layer mix as the shader index.
    pub fn blend_index(&self) -> u32 {
        match self.blend {
            LayerMixMode::Normal => 0,
            LayerMixMode::Add => 1,
            LayerMixMode::Subtract => 2,
            LayerMixMode::Multiply => 3,
            LayerMixMode::Screen => 4,
            LayerMixMode::Lighten => 5,
            LayerMixMode::Darken => 6,
        }
    }

    /// Bit 0 qualifier, bit 1 window, bit 2 mix below 1, bit 4 keyed, bits 5...7 Layer mix (bit 3 is the layer branch,
    /// set by the GPU encoder).
    pub fn flags(&self) -> u32 {
        u32::from(self.qualifier.is_some())
            | (u32::from(self.window.is_some()) << 1)
            | (u32::from(self.mix < 1.0) << 2)
            | (u32::from(self.keyed) << 4)
            | (self.blend_index() << 5)
    }

    /// `input`: the Step's input (`n0`), `c`: its result, both in the same domain. `key`: the key register (1 = none).
    pub fn apply(&self, c: Vec3, input: Vec3, uv: [f32; 2], aspect: f32, pre: bool, key: f32) -> Vec3 {
        input + (c - input) * (self.matte(input, uv, aspect, pre) * key)
    }

    /// The key (qualifier on the input, window) times the mix.
    pub fn matte(&self, input: Vec3, uv: [f32; 2], aspect: f32, pre: bool) -> f32 {
        let mut m = 1.0;
        if let Some(q) = &self.qualifier {
            m = q.mask(if pre { input.map(oetf) } else { input });
        }
        if let Some(w) = &self.window {
            m *= w.mask(uv, aspect);
        }
        if self.mix < 1.0 {
            m *= self.mix;
        }
        m
    }

    /// A layer's result `c` composited over `acc` (what is below it), before the key sets the strength.
    pub fn composite(&self, c: Vec3, acc: Vec3) -> Vec3 {
        match self.blend {
            LayerMixMode::Normal => c,
            LayerMixMode::Add => acc + c,
            LayerMixMode::Subtract => acc - c,
            LayerMixMode::Multiply => acc * c,
            LayerMixMode::Screen => Vec3::ONE - (Vec3::ONE - acc) * (Vec3::ONE - c),
            LayerMixMode::Lighten => acc.max(c),
            LayerMixMode::Darken => acc.min(c),
        }
    }
}
