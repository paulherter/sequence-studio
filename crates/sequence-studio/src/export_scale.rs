//! The export picture at the preset's size: one bilinear tap per output pixel, as Swift (`ExportShaderSource`
//! `linSampler`: texel centers, clamp to edge). A different shape is fitted unstretched, centered, on opaque black
//! bars ("Scale to Fit", `fit_rect`, the same rectangle as the GPU Present pass); the same shape fills the frame.
//!
//! 8-bit frames are decoded with the sRGB curve, filtered in linear light and encoded again (Swift filters the linear
//! working picture before encoding; the sRGB curve stands in for the working picture's transfer). The half-float (HDR)
//! path is linear and matches.
//!
//! shortcut: runs on the CPU after the readback (the compositor has no sized composite yet), threaded by rows; upgrade
//! with a compositor pass at the output size so the frame is read back once at its final size.

/// One output coordinate: the two source indices and the weight of the second (`sample(linSampler, uv)`: texel centers,
/// `uv = (gid + 0.5) / size`, clamp to edge).
struct Tap {
    lo: usize,
    hi: usize,
    t: f32,
}

fn axis_taps(from: usize, to: usize) -> Vec<Tap> {
    (0..to)
        .map(|i| {
            let x = (i as f32 + 0.5) / to as f32 * from as f32 - 0.5;
            let base = x.floor();
            let last = (from - 1) as f32;
            Tap { lo: base.clamp(0.0, last) as usize, hi: (base + 1.0).clamp(0.0, last) as usize, t: x - base }
        })
        .collect()
}

/// Runs `row` for every `row_len` chunk of `out` on all cores.
fn par_rows(out: &mut [f32], row_len: usize, row: impl Fn(usize, &mut [f32]) + Sync) {
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get());
    let rows = out.len() / row_len.max(1);
    let per = rows.div_ceil(threads).max(1);
    std::thread::scope(|scope| {
        for (n, block) in out.chunks_mut(per * row_len).enumerate() {
            let row = &row;
            scope.spawn(move || {
                for (k, chunk) in block.chunks_mut(row_len).enumerate() {
                    row(n * per + k, chunk);
                }
            });
        }
    });
}

fn half_to_f32(h: u16) -> f32 {
    let (sign, exp, frac) = (u32::from(h >> 15), u32::from((h >> 10) & 0x1F), u32::from(h & 0x3FF));
    let magnitude = match exp {
        0 => frac as f32 * 2f32.powi(-24),
        31 if frac == 0 => f32::INFINITY,
        31 => f32::NAN,
        _ => f32::from_bits(((exp + 112) << 23) | (frac << 13)),
    };
    if sign == 1 { -magnitude } else { magnitude }
}

fn f32_to_half(v: f32) -> u16 {
    let bits = v.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32 - 127;
    let frac = bits & 0x7F_FFFF;
    if v.is_nan() {
        return sign | 0x7E00;
    }
    if exp > 15 {
        return sign | 0x7C00;
    }
    if exp >= -14 {
        let half = (((exp + 15) as u32) << 10) | (frac >> 13);
        // Round to nearest even; a carry out of the fraction correctly bumps the exponent.
        let round = (frac >> 12) & 1 != 0 && ((frac & 0xFFF) != 0 || half & 1 != 0);
        return sign | (half + u32::from(round)) as u16;
    }
    // Subnormal half or zero.
    let value = (v.abs() * 2f32.powi(24)).round_ties_even();
    sign | value.min(1023.0) as u16
}

/// The sRGB decode of one 8-bit code value.
fn srgb_to_linear(code: usize) -> f32 {
    static LUT: std::sync::OnceLock<[f32; 256]> = std::sync::OnceLock::new();
    LUT.get_or_init(|| {
        std::array::from_fn(|i| {
            let v = i as f32 / 255.0;
            if v <= 0.040_45 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        })
    })[code]
}

/// The 8-bit sRGB code of a linear value.
fn linear_to_srgb(v: f32) -> u8 {
    const N: usize = 16384;
    static LUT: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    let lut = LUT.get_or_init(|| {
        (0..=N)
            .map(|i| {
                let l = i as f32 / N as f32;
                let e = if l <= 0.003_130_8 { l * 12.92 } else { 1.055 * l.powf(1.0 / 2.4) - 0.055 };
                (e * 255.0).round().clamp(0.0, 255.0) as u8
            })
            .collect()
    });
    lut[(v.clamp(0.0, 1.0) * N as f32).round() as usize]
}

/// `pixels` (RGBA, `bpp` 4 = 8-bit, 8 = half-float; `w` x `h`) fitted into `(tw, th)`: scaled with one bilinear tap per
/// output pixel into the centered fit rectangle, opaque black around it (nothing around it when the shapes match).
pub(crate) fn resample(pixels: &[u8], bpp: usize, (w, h): (usize, usize), (tw, th): (usize, usize)) -> Vec<u8> {
    if (w, h) == (tw, th) || w == 0 || h == 0 || tw == 0 || th == 0 {
        return pixels.to_vec();
    }
    let (x0, y0, fw, fh) = sq_render::program::compositor::fit_rect((w as u32, h as u32), (tw as u32, th as u32));
    let (x0, y0, fw, fh) = (x0 as usize, y0 as usize, fw as usize, fh as usize);
    if (fw, fh) == (tw, th) {
        return stretch(pixels, bpp, (w, h), (tw, th));
    }
    let inner = stretch(pixels, bpp, (w, h), (fw, fh));
    let mut black = [0u8, 0, 0, 255].to_vec();
    if bpp == 8 {
        black = [0u16, 0, 0, f32_to_half(1.0)].iter().flat_map(|v| v.to_le_bytes()).collect();
    }
    let mut out: Vec<u8> = black.iter().copied().cycle().take(tw * th * bpp).collect();
    for y in 0..fh {
        let dst = ((y0 + y) * tw + x0) * bpp;
        out[dst..dst + fw * bpp].copy_from_slice(&inner[y * fw * bpp..(y + 1) * fw * bpp]);
    }
    out
}

/// The whole picture stretched to `(tw, th)`.
fn stretch(pixels: &[u8], bpp: usize, (w, h): (usize, usize), (tw, th): (usize, usize)) -> Vec<u8> {
    if (w, h) == (tw, th) {
        return pixels.to_vec();
    }
    let half = bpp == 8;
    let at = |i: usize| -> f32 {
        if half {
            half_to_f32(u16::from_le_bytes([pixels[2 * i], pixels[2 * i + 1]]))
        } else if i % 4 == 3 {
            f32::from(pixels[i]) / 255.0 // alpha is coverage, already linear
        } else {
            srgb_to_linear(usize::from(pixels[i]))
        }
    };
    let (xt, yt) = (axis_taps(w, tw), axis_taps(h, th));
    let ch = 4;
    // Horizontal pass: h rows of tw pixels.
    let mut across = vec![0f32; h * tw * ch];
    par_rows(&mut across, tw * ch, |y, out| {
        for (x, tap) in xt.iter().enumerate() {
            for c in 0..ch {
                let (a, b) = (at((y * w + tap.lo) * ch + c), at((y * w + tap.hi) * ch + c));
                out[x * ch + c] = a + (b - a) * tap.t;
            }
        }
    });
    // Vertical pass: th rows of tw pixels.
    let mut down = vec![0f32; th * tw * ch];
    par_rows(&mut down, tw * ch, |y, out| {
        let tap = &yt[y];
        for (i, o) in out.iter_mut().enumerate() {
            let (a, b) = (across[tap.lo * tw * ch + i], across[tap.hi * tw * ch + i]);
            *o = a + (b - a) * tap.t;
        }
    });
    if half {
        down.iter().flat_map(|v| f32_to_half(*v).to_le_bytes()).collect()
    } else {
        down.iter()
            .enumerate()
            .map(|(i, v)| if i % 4 == 3 { (v * 255.0).round().clamp(0.0, 255.0) as u8 } else { linear_to_srgb(*v) })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgba(w: usize, h: usize, f: impl Fn(usize, usize) -> u8) -> Vec<u8> {
        (0..w * h).flat_map(|i| [f(i % w, i / w), f(i % w, i / w), f(i % w, i / w), 255]).collect()
    }

    #[test]
    fn a_flat_picture_stays_flat_at_any_size() {
        let src = rgba(64, 36, |_, _| 90);
        for size in [(32, 18), (128, 72), (16, 9)] {
            let out = resample(&src, 4, (64, 36), size);
            assert_eq!(out.len(), size.0 * size.1 * 4);
            assert!(out.chunks(4).all(|p| p == [90, 90, 90, 255]), "{size:?}");
        }
    }

    #[test]
    fn a_fine_stripe_pattern_averages_instead_of_aliasing_when_quartered() {
        // One-pixel stripes 0/200: the mean light is the average of the two linear values. Nearest neighbor would give 0 or 200.
        let mid = i32::from(linear_to_srgb((srgb_to_linear(0) + srgb_to_linear(200)) / 2.0));
        let src = rgba(64, 64, |x, _| if x % 2 == 0 { 0 } else { 200 });
        let out = resample(&src, 4, (64, 64), (16, 16));
        for p in out.chunks(4).skip(16 * 4) {
            assert!((i32::from(p[0]) - mid).abs() <= 2, "{}", p[0]);
        }
    }

    #[test]
    fn a_2x2_picture_at_4x4_matches_the_linsampler_values() {
        // uv = (gid + 0.5) / 4, texel center x = uv * 2 - 0.5 = -0.25, 0.25, 0.75, 1.25 (clamped): weights 0, .25, .75, 1.
        let src = rgba2(&[0, 100, 200, 40]);
        let out = resample(&src, 4, (2, 2), (4, 4));
        let lin = |v: usize| srgb_to_linear(v);
        let w: [f32; 4] = [0.0, 0.25, 0.75, 1.0];
        let src_px = [[0usize, 100], [200, 40]];
        for (y, wy) in w.iter().enumerate() {
            for (x, wx) in w.iter().enumerate() {
                let row = |r: usize| lin(src_px[r][0]) + (lin(src_px[r][1]) - lin(src_px[r][0])) * wx;
                let want = i32::from(linear_to_srgb(row(0) + (row(1) - row(0)) * wy));
                let got = i32::from(out[(y * 4 + x) * 4]);
                assert!((got - want).abs() <= 1, "({x},{y}): {got} vs {want}");
            }
        }
    }

    fn rgba2(v: &[u8]) -> Vec<u8> {
        v.iter().flat_map(|g| [*g, *g, *g, 255]).collect()
    }

    #[test]
    #[ignore = "timing, run with --release -- --ignored --nocapture"]
    fn timing_of_one_4k_frame_to_1080p() {
        let src = vec![77u8; 3840 * 2160 * 4];
        let t = std::time::Instant::now();
        let out = resample(&src, 4, (3840, 2160), (1920, 1080));
        sq_os::outln!("3840x2160 -> 1920x1080 8-bit: {:?}", t.elapsed());
        assert_eq!(out.len(), 1920 * 1080 * 4);
    }

    #[test]
    fn a_smooth_ramp_survives_down_and_up_within_tolerance() {
        let ramp = |x: usize, w: usize| (x * 255 / (w - 1)) as u8;
        let src = rgba(128, 8, |x, _| ramp(x, 128));
        let small = resample(&src, 4, (128, 8), (64, 4));
        let back = resample(&small, 4, (64, 4), (128, 8));
        // Away from the edges, where the clamped border bends the ramp.
        for y in 0..8 {
            for x in 8..120 {
                let (a, b) = (i32::from(src[(y * 128 + x) * 4]), i32::from(back[(y * 128 + x) * 4]));
                assert!((a - b).abs() <= 2, "x {x}: {a} vs {b}");
            }
        }
    }

    #[test]
    fn a_different_shape_is_fitted_unstretched_on_black_bars() {
        // Behavior changed on purpose (2026-11-24): this test used to assert a stretch without bars.
        // Tall 9:16 source into a 16:9 frame: pillarbox. Left half 40, right half 220.
        let src = rgba(18, 32, |x, _| if x < 9 { 40 } else { 220 });
        let out = resample(&src, 4, (18, 32), (64, 36));
        assert_eq!(out.len(), 64 * 36 * 4);
        let (x0, y0, fw, fh) = sq_render::program::compositor::fit_rect((18, 32), (64, 36));
        assert_eq!((y0, fh), (0, 36));
        assert!(fw < 64 && x0 > 0);
        let px = |x: usize, y: usize| out[(y * 64 + x) * 4];
        for y in 0..36 {
            assert_eq!(px(0, y), 0);
            assert_eq!(px(63, y), 0);
            assert_eq!(out[(y * 64) * 4 + 3], 255);
        }
        assert!(px(x0 as usize + 1, 5) < 60 && px((x0 + fw) as usize - 2, 5) > 200);
        // A wide source into a tall frame: letterbox.
        let wide = rgba(32, 18, |_, _| 120);
        let o = resample(&wide, 4, (32, 18), (36, 64));
        assert_eq!(o[0], 0);
        assert_eq!(o[(32 * 36 + 18) * 4], 120);
        assert!(o.chunks(4).all(|p| p[3] == 255));
    }

    #[test]
    fn the_same_aspect_is_the_plain_stretch() {
        let src = rgba(40, 30, |x, y| (x * 5 + y) as u8);
        assert_eq!(resample(&src, 4, (40, 30), (20, 15)), stretch(&src, 4, (40, 30), (20, 15)));
    }

    #[test]
    fn black_and_white_stripes_average_in_linear_light() {
        let src = rgba(8, 1, |x, _| if x % 2 == 0 { 0 } else { 255 });
        let out = resample(&src, 4, (8, 1), (4, 1));
        // Half the light is 188 on the sRGB curve (code-value filtering would give 128).
        assert!(out[..3].iter().all(|v| (186..=190).contains(v)), "{:?}", &out[..4]);
        assert_eq!(out[3], 255);
    }

    #[test]
    fn half_float_pictures_scale_in_light_values() {
        let one = f32_to_half(1.0).to_le_bytes();
        let two = f32_to_half(4.0).to_le_bytes();
        let mut src = Vec::new();
        for x in 0..8 {
            let v = if x % 2 == 0 { one } else { two };
            for _ in 0..3 {
                src.extend_from_slice(&v);
            }
            src.extend_from_slice(&f32_to_half(1.0).to_le_bytes());
        }
        let out = resample(&src, 8, (8, 1), (4, 1));
        let mid = half_to_f32(u16::from_le_bytes([out[8], out[9]]));
        assert!((mid - 2.5).abs() < 0.15, "{mid}");
        assert_eq!(half_to_f32(u16::from_le_bytes([out[6], out[7]])), 1.0);
    }

    #[test]
    fn half_conversion_round_trips_typical_values() {
        for v in [0.0, 1.0, 0.5, 4.0, 0.333, 65504.0, 1e-5] {
            let back = half_to_f32(f32_to_half(v));
            assert!((back - v).abs() <= v.abs() * 1e-3 + 1e-7, "{v} -> {back}");
        }
    }
}
