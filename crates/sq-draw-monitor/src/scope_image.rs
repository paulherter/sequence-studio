// Swift: SQDrawKit/Monitor/ScopesDrawing.swift (`ScopeImage`)
//! The picture of one scope from its counts: the CPU form of the Mac's `ScopeRenderer` fragment shader (count / max,
//! bilinear clamp sampling, compressive map, 4-tap cross glow, phosphor tints, additive histogram curves on 12/255 gray).
//! It lives here because it reads `ScopeCounts` / `ScopeLayout` of `sq-render`, which `sq-draw` must not depend on.

use sq_draw::RgbaImage;
use sq_draw::monitor::scope_graticule::ScopeKind;
use sq_render::passes::scope_binning::{ScopeCounts, ScopeLayout};

/// Renders scope pictures.
pub enum ScopeImage {}

const BACKGROUND: f32 = 12.0 / 255.0;

/// A count / max plane (the Mac's r32Float scope texture).
struct Plane {
    w: usize,
    h: usize,
    v: Vec<f32>,
}

impl Plane {
    fn new(counts: &[u32], w: usize, h: usize, max: u32) -> Plane {
        let inv = if max > 0 { 1.0 / max as f32 } else { 0.0 };
        Plane { w, h, v: counts.iter().map(|c| *c as f32 * inv).collect() }
    }

    fn at(&self, x: i64, y: i64) -> f32 {
        let yy = y.clamp(0, self.h as i64 - 1) as usize;
        let xx = x.clamp(0, self.w as i64 - 1) as usize;
        self.v.get(yy * self.w + xx).copied().unwrap_or(0.0)
    }

    fn sample(&self, u: f32, t: f32) -> f32 {
        let fx = u * self.w as f32 - 0.5;
        let fy = t * self.h as f32 - 0.5;
        let x0 = fx.floor() as i64;
        let y0 = fy.floor() as i64;
        let ax = fx - x0 as f32;
        let ay = fy - y0 as f32;
        let top = self.at(x0, y0) * (1.0 - ax) + self.at(x0 + 1, y0) * ax;
        let bottom = self.at(x0, y0 + 1) * (1.0 - ax) + self.at(x0 + 1, y0 + 1) * ax;
        top * (1.0 - ay) + bottom * ay
    }
}

fn saturate(x: f32) -> f32 {
    x.clamp(0.0, 1.0)
}

/// count/max (0...1) -> display intensity: compressive so sparse traces stay visible.
fn map(v: f32, gain: f32) -> f32 {
    saturate(v.max(0.0).powf(0.45) * 1.6 * gain)
}

/// Vectorscope: log over five decades with a visible floor for any occupied bin.
fn map_vector(v: f32, gain: f32) -> f32 {
    if v <= 0.0 { 0.0 } else { saturate((0.34 + 0.66 * saturate(1.0 + v.log10() / 5.0)) * gain) }
}

fn glow(p: &Plane, u: f32, t: f32, gain: f32, sx: f32, sy: f32, vector: bool) -> f32 {
    let f = |v: f32| if vector { map_vector(v, gain) } else { map(v, gain) };
    let tx = sx / p.w as f32;
    let ty = sy / p.h as f32;
    let g = f(p.sample(u + tx, t)) + f(p.sample(u - tx, t)) + f(p.sample(u, t + ty)) + f(p.sample(u, t - ty));
    saturate(f(p.sample(u, t)) + 0.18 * g)
}

impl ScopeImage {
    /// The top slice of a waveform or parade plot (as a fraction of its height) that is 100 % and above: drawn red.
    pub const OVER_100: f32 = 0.015;

    /// The scope `kind` drawn `width` x `height` pixels (opaque RGBA).
    pub fn render(kind: ScopeKind, c: &ScopeCounts, width: usize, height: usize, gain: f32) -> RgbaImage {
        let l = c.layout;
        let plane = match kind {
            ScopeKind::Waveform => {
                Plane::new(&c.waveform_luma, l.waveform_width, l.waveform_levels, c.max_waveform_luma)
            }
            ScopeKind::Parade => {
                Plane::new(&c.waveform_parade, 3 * l.waveform_width, l.waveform_levels, c.max_waveform_parade)
            }
            ScopeKind::Vectorscope => {
                Plane::new(&c.vectorscope, l.vectorscope_size, l.vectorscope_size, c.max_vectorscope)
            }
            ScopeKind::Histogram => Plane::new(&c.histogram, ScopeLayout::HISTOGRAM_BINS, 4, c.max_histogram),
        };
        let mut px = vec![255u8; width * height * 4];
        let bg = BACKGROUND;
        for y in 0..height {
            let t = (y as f32 + 0.5) / height as f32;
            for x in 0..width {
                let u = (x as f32 + 0.5) / width as f32;
                let col: (f32, f32, f32) = match kind {
                    ScopeKind::Waveform => {
                        let i = glow(&plane, u, t, gain, 1.5, 1.5, false);
                        if t < Self::OVER_100 {
                            // Clipped: at or above 100 % the trace turns red.
                            (bg + i, bg + i * 0.22, bg + i * 0.20)
                        } else {
                            (bg + i * 0.62, bg + i, bg + i * 0.72)
                        }
                    }
                    ScopeKind::Parade => {
                        let panel = (u * 3.0).floor().min(2.0);
                        let i = glow(&plane, u, t, gain, 1.0, 1.5, false);
                        let tint: (f32, f32, f32) = if t < Self::OVER_100 {
                            (1.0, 0.22, 0.20)
                        } else if panel < 0.5 {
                            (1.0, 0.30, 0.26)
                        } else if panel < 1.5 {
                            (0.30, 1.0, 0.42)
                        } else {
                            (0.30, 0.52, 1.0)
                        };
                        (bg + i * tint.0, bg + i * tint.1, bg + i * tint.2)
                    }
                    ScopeKind::Vectorscope => {
                        let i = glow(&plane, u, t, gain, 1.5, 1.5, true);
                        (bg + i * 0.70, bg + i, bg + i * 0.80)
                    }
                    ScopeKind::Histogram => {
                        let h = 1.0 - t;
                        let mut add = (0.0f32, 0.0f32, 0.0f32);
                        let tints: [(f32, f32, f32); 4] =
                            [(0.85, 0.12, 0.10), (0.10, 0.75, 0.22), (0.12, 0.30, 0.95), (0.22, 0.22, 0.22)];
                        for (r, tint) in tints.iter().enumerate() {
                            if h <= plane.sample(u, (r as f32 + 0.5) / 4.0).sqrt() {
                                add = (add.0 + tint.0, add.1 + tint.1, add.2 + tint.2);
                            }
                        }
                        (bg + add.0 * gain, bg + add.1 * gain, bg + add.2 * gain)
                    }
                };
                let i = (y * width + x) * 4;
                px[i] = (saturate(col.0) * 255.0 + 0.5) as u8;
                px[i + 1] = (saturate(col.1) * 255.0 + 0.5) as u8;
                px[i + 2] = (saturate(col.2) * 255.0 + 0.5) as u8;
            }
        }
        RgbaImage { width, height, pixels: px }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::monitor::scope_graticule::ScopeGraticule;
    use sq_render::passes::scope_binning::cbcr;

    #[test]
    fn a_brighter_intensity_lifts_the_waveform_trace() {
        let mut c = ScopeCounts::new(ScopeLayout::default());
        // A faint trace over the whole luma waveform (a tenth of the max).
        c.waveform_luma = vec![20; c.waveform_luma.len()];
        c.max_waveform_luma = 200;
        let a = ScopeImage::render(ScopeKind::Waveform, &c, 64, 32, 1.0);
        let b = ScopeImage::render(ScopeKind::Waveform, &c, 64, 32, 2.0);
        let sum = |i: &RgbaImage| i.pixels.iter().map(|v| u64::from(*v)).sum::<u64>();
        assert!(sum(&b) > sum(&a));
    }

    #[test]
    fn a_waveform_trace_over_100_percent_is_red() {
        let mut c = ScopeCounts::new(ScopeLayout::default());
        c.waveform_luma = vec![200; c.waveform_luma.len()];
        c.max_waveform_luma = 200;
        let img = ScopeImage::render(ScopeKind::Waveform, &c, 64, 200, 1.0);
        let px = |y: usize| {
            let i = (y * 64 + 32) * 4;
            (img.pixels[i], img.pixels[i + 1])
        };
        let (r, g) = px(0);
        assert!(r > g + 40, "top row is red: {r} {g}");
        let (r, g) = px(100);
        assert!(g > r, "middle stays green-white: {r} {g}");
    }

    #[test]
    fn empty_counts_draw_the_dark_background_and_a_zero_size_draws_nothing() {
        let c = ScopeCounts::new(ScopeLayout::default());
        let img = ScopeImage::render(ScopeKind::Histogram, &c, 4, 4, 1.0);
        assert_eq!(img.pixels[0..4], [12, 12, 12, 255]);
        assert!(ScopeImage::render(ScopeKind::Parade, &c, 0, 5, 1.0).pixels.is_empty());
    }

    /// The graticule test that sq-draw could not run: the targets sit where the binning puts the same colors.
    #[test]
    fn vectorscope_targets_match_the_binning() {
        let t = ScopeGraticule::vectorscope_targets(0.75);
        assert_eq!(t.iter().map(|x| x.name).collect::<Vec<_>>(), ["R", "Mg", "B", "Cy", "G", "Yl"]);
        for target in &t {
            let c = cbcr([target.rgb[0] as f32, target.rgb[1] as f32, target.rgb[2] as f32]);
            assert!((target.center[0] - (f64::from(c[0]) + 0.5)).abs() < 1e-6);
            assert!((target.center[1] - (0.5 - f64::from(c[1]))).abs() < 1e-6);
        }
    }

    /// The GPU drawing (`Scopes.scopeDraw`) equals the CPU one: every scope kind of a fixed frame within a few 8-bit steps.
    #[test]
    fn gpu_drawn_scopes_match_the_cpu_pictures() {
        use sq_render::gpu_effects::scope_passes::{ScopeDrawKind, ScopePasses};
        use sq_render::passes::scope_binning::compute_rgba;
        let Ok(gpu) = sq_gpu::gpu::Gpu::new() else {
            sq_os::errln!("skipping: no GPU adapter");
            return;
        };
        let passes = ScopePasses::new(&gpu);
        let (w, h) = (96usize, 54usize);
        let mut rgba = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let (r, g, b) = ((x * 255 / w) as u8, (y * 255 / h) as u8, ((x * y) % 256) as u8);
                rgba.extend_from_slice(&[r, g, b, 255]);
            }
        }
        // Clipped whites too, so the red top slice is covered.
        for px in rgba.as_chunks_mut::<4>().0.iter_mut().take(w) {
            px[..3].copy_from_slice(&[255, 255, 255]);
        }
        let c = compute_rgba(&rgba, w, h, ScopeLayout::default(), 1);
        let kinds = [
            (ScopeKind::Waveform, ScopeDrawKind::Waveform),
            (ScopeKind::Parade, ScopeDrawKind::Parade),
            (ScopeKind::Vectorscope, ScopeDrawKind::Vectorscope),
            (ScopeKind::Histogram, ScopeDrawKind::Histogram),
        ];
        for (k, gk) in kinds {
            let cpu = ScopeImage::render(k, &c, 200, 120, 1.3);
            let gpu_px = passes.draw_image(&c, gk, 200, 120, 1.3).unwrap_or_else(|e| panic!("{k:?}: {e}"));
            assert_eq!(gpu_px.len(), cpu.pixels.len());
            let worst = cpu.pixels.iter().zip(&gpu_px).map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
            let off = cpu.pixels.iter().zip(&gpu_px).filter(|(a, b)| a.abs_diff(**b) > 3).count();
            sq_os::errln!("{k:?}: worst {worst}, {off} of {} values differ by more than 3", gpu_px.len());
            // The vectorscope map jumps at an empty bin (0 -> 0.34 floor), so a bilinear weight that rounds differently
            // on the GPU flips single pixels at the edge of a trace; everything else stays within 3 steps.
            let allowed = if k == ScopeKind::Vectorscope { gpu_px.len() / 200 } else { 0 };
            assert!(off <= allowed, "{k:?}: worst channel difference {worst}, {off} values off");
        }
    }
}
