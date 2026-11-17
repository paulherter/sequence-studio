// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MatteRefine.swift (plain path, `#else` branch of `canImport(Accelerate)`)
//! Shared matte clean-up (Swift `MatteRefine`): per-pixel `tone` (shrink / grow curve, contrast around a midpoint) and the
//! spatial `refine` (erode / dilate, box feather, then tone) on a coverage grid, 1 = kept. The two spatial filters are a
//! min / max filter and a box blur, separable, edges clamped (the plain-Swift path of Swift's `#else` branch).

/// Matte clean-up settings. `MatteRefine::default()` is the identity.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MatteRefine {
    /// -1...1: positive shrinks the kept picture, negative grows it.
    pub shrink: f64,
    /// 0...1: steepens the edge ramp around `midpoint`.
    pub contrast: f64,
    /// 0...1: the coverage the contrast pivots on.
    pub midpoint: f64,
    /// Spatial feather radius in matte px (box blur), `refine` only.
    pub feather: f64,
    /// Spatial shrink (+) / grow (-) in matte px, `refine` only.
    pub shrink_px: f64,
}

impl Default for MatteRefine {
    fn default() -> Self {
        MatteRefine { shrink: 0.0, contrast: 0.0, midpoint: 0.5, feather: 0.0, shrink_px: 0.0 }
    }
}

impl MatteRefine {
    /// Contrast slope at `contrast` 1 is 1 + 9 = 10x.
    pub const CONTRAST_GAIN: f64 = 9.0;
    /// How much of the 0...1 range one full unit of `shrink` covers.
    pub const SHRINK_REACH: f64 = 0.9;

    /// True when `tone` leaves every value alone.
    pub fn is_tone_identity(&self) -> bool {
        self.shrink == 0.0 && self.contrast == 0.0
    }

    /// True when `refine` leaves a matte alone.
    pub fn is_spatial_identity(&self) -> bool {
        self.shrink_px == 0.0 && self.feather == 0.0
    }

    /// Per-pixel refinement of coverage `c` (0...1).
    pub fn tone(&self, c: f64) -> f64 {
        let mut m = c.clamp(0.0, 1.0);
        if self.shrink > 0.0 {
            let s = Self::SHRINK_REACH * self.shrink.min(1.0);
            m = ((m - s) / (1.0 - s).max(1e-4)).clamp(0.0, 1.0);
        } else if self.shrink < 0.0 {
            let g = Self::SHRINK_REACH * (-self.shrink).min(1.0);
            m = (m / (1.0 - g).max(1e-4)).min(1.0);
        }
        if self.contrast > 0.0 {
            m = ((m - self.midpoint) * (1.0 + Self::CONTRAST_GAIN * self.contrast.min(1.0)) + self.midpoint)
                .clamp(0.0, 1.0);
        }
        m
    }

    /// Refines a `width` x `height` coverage grid (row major): erode / dilate by `shrink_px` (whole px), box feather of
    /// radius `feather`, then `tone`. Edges clamp.
    pub fn refine(&self, matte: &[f32], width: usize, height: usize) -> Vec<f32> {
        assert_eq!(matte.len(), width * height, "matte size");
        let mut m = matte.to_vec();
        let r = self.shrink_px.abs().round() as usize;
        if r > 0 {
            m = morph(&m, width, height, r, self.shrink_px > 0.0);
        }
        let f = self.feather.round() as usize;
        if f > 0 {
            m = box_blur(&m, width, height, f);
        }
        if !self.is_tone_identity() {
            for v in &mut m {
                *v = self.tone(f64::from(*v)) as f32;
            }
        }
        m
    }
}

/// Min (erode) or max (dilate) filter with a `(2r+1)` square kernel, edges clamped.
pub fn morph(src: &[f32], width: usize, height: usize, radius: usize, erode: bool) -> Vec<f32> {
    let h = pass(src, width, height, radius, true, None, &|a, b| if erode { a.min(b) } else { a.max(b) });
    pass(&h, width, height, radius, false, None, &|a, b| if erode { a.min(b) } else { a.max(b) })
}

/// Separable box blur, `(2r+1)` wide, edges clamped.
pub fn box_blur(src: &[f32], width: usize, height: usize, radius: usize) -> Vec<f32> {
    let w = 1.0 / (2 * radius + 1) as f32;
    let blur = |a: &[f32], horizontal: bool| {
        let mut out = pass(a, width, height, radius, horizontal, Some(0.0), &|a, b| a + b);
        for v in &mut out {
            *v *= w;
        }
        out
    };
    let h = blur(src, true);
    blur(&h, false)
}

fn pass(
    src: &[f32],
    w: usize,
    h: usize,
    r: usize,
    horizontal: bool,
    initial: Option<f32>,
    combine: &dyn Fn(f32, f32) -> f32,
) -> Vec<f32> {
    let mut out = vec![0.0_f32; w * h];
    let (lines, len) = if horizontal { (h, w) } else { (w, h) };
    for l in 0..lines {
        for i in 0..len {
            let mut acc = initial;
            for o in -(r as i64)..=(r as i64) {
                let j = (i as i64 + o).clamp(0, len as i64 - 1) as usize;
                let v = if horizontal { src[l * w + j] } else { src[j * w + l] };
                acc = Some(acc.map_or(v, |a| combine(a, v)));
            }
            let dst = if horizontal { l * w + i } else { i * w + l };
            out[dst] = acc.unwrap_or(0.0);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dilate_then_erode_a_single_pixel() {
        let mut m = vec![0.0_f32; 25];
        m[12] = 1.0;
        let d = morph(&m, 5, 5, 1, false);
        assert_eq!(d.iter().filter(|v| **v == 1.0).count(), 9);
        assert_eq!(morph(&d, 5, 5, 1, true), m);
    }

    #[test]
    fn tone_shrink_grow_and_contrast_follow_swift() {
        let shrink = MatteRefine { shrink: 1.0, ..Default::default() };
        assert_eq!(shrink.tone(0.9), 0.0);
        assert!((shrink.tone(0.95) - 0.5).abs() < 1e-9);
        let grow = MatteRefine { shrink: -1.0, ..Default::default() };
        assert!((grow.tone(0.09) - 0.9).abs() < 1e-9);
        assert_eq!(grow.tone(0.2), 1.0);
        let contrast = MatteRefine { contrast: 1.0, ..Default::default() };
        assert!((contrast.tone(0.55) - 1.0).abs() < 1e-9);
        assert_eq!(contrast.tone(0.5), 0.5);
        assert_eq!(MatteRefine::default().tone(0.3), 0.3);
        assert!(MatteRefine::default().is_tone_identity() && MatteRefine::default().is_spatial_identity());
    }

    #[test]
    fn refine_runs_erode_then_feather_then_tone() {
        let mut m = vec![0.0_f32; 25];
        m[12] = 1.0;
        let grown = MatteRefine { shrink_px: -1.0, ..Default::default() }.refine(&m, 5, 5);
        assert_eq!(grown.iter().filter(|v| **v == 1.0).count(), 9);
        let toned = MatteRefine { shrink_px: -1.0, feather: 1.0, shrink: 1.0, ..Default::default() }.refine(&m, 5, 5);
        // The feathered edge (1/3 and below) is cut by the full shrink; the centre keeps 1.0 * 1/... after the blur.
        assert!(toned.iter().all(|v| (0.0..=1.0).contains(v)));
        assert_eq!(MatteRefine::default().refine(&m, 5, 5), m);
    }

    #[test]
    fn box_blur_keeps_a_constant_matte() {
        let m = vec![0.5_f32; 16];
        for v in box_blur(&m, 4, 4, 1) {
            assert!((v - 0.5).abs() < 1e-6);
        }
    }
}
