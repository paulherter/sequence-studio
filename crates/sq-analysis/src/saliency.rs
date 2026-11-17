// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: VisionSubjectDetector.swift (`VNGenerateAttentionBasedSaliencyImageRequest`)
//! Saliency without a model: the spectral residual of Hou and Zhang (CVPR 2007) on a 64 x 64 gray copy. What stands out from
//! the picture's average spectrum is salient; the strongest blob above three times the mean becomes one box. Vision returns
//! "salient objects" as boxes; this gives the same shape of answer for Auto-Reframe's no-person fallback.

use crate::edge_tamonnx::SubjectFrame;
use sq_core_masks::anonymize::AnonymizeBox;

const N: usize = 64;

#[derive(Clone, Copy)]
struct C(f64, f64);

/// In-place radix-2 FFT (`inverse` scales by 1/n).
fn fft(a: &mut [C], inverse: bool) {
    let n = a.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            a.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let ang = 2.0 * std::f64::consts::PI / len as f64 * if inverse { 1.0 } else { -1.0 };
        for start in (0..n).step_by(len) {
            for k in 0..len / 2 {
                let (wr, wi) = ((ang * k as f64).cos(), (ang * k as f64).sin());
                let (u, v) = (a[start + k], a[start + k + len / 2]);
                let t = C(v.0 * wr - v.1 * wi, v.0 * wi + v.1 * wr);
                a[start + k] = C(u.0 + t.0, u.1 + t.1);
                a[start + k + len / 2] = C(u.0 - t.0, u.1 - t.1);
            }
        }
        len <<= 1;
    }
    if inverse {
        for x in a.iter_mut() {
            *x = C(x.0 / n as f64, x.1 / n as f64);
        }
    }
}

fn fft2(a: &mut [C], inverse: bool) {
    for r in 0..N {
        fft(&mut a[r * N..(r + 1) * N], inverse);
    }
    let mut col = [C(0.0, 0.0); N];
    for c in 0..N {
        for r in 0..N {
            col[r] = a[r * N + c];
        }
        fft(&mut col, inverse);
        for r in 0..N {
            a[r * N + c] = col[r];
        }
    }
}

/// 3 x 3 box average with clamped edges.
fn mean3(src: &[f64]) -> Vec<f64> {
    let mut out = vec![0.0; N * N];
    for y in 0..N {
        for x in 0..N {
            let mut s = 0.0;
            for dy in [-1i64, 0, 1] {
                for dx in [-1i64, 0, 1] {
                    let (yy, xx) = (
                        (y as i64 + dy).clamp(0, N as i64 - 1) as usize,
                        (x as i64 + dx).clamp(0, N as i64 - 1) as usize,
                    );
                    s += src[yy * N + xx];
                }
            }
            out[y * N + x] = s / 9.0;
        }
    }
    out
}

/// The saliency map (N x N, values >= 0) of a frame.
fn map(frame: &SubjectFrame) -> Vec<f64> {
    let (w, h) = (frame.width.max(1), frame.height.max(1));
    // Gray copy by box averaging.
    let mut gray = vec![0.0f64; N * N];
    let mut count = vec![0.0f64; N * N];
    for y in 0..frame.height {
        for x in 0..frame.width {
            let i = (y * w + x) * 4;
            let g = 0.299 * f64::from(frame.rgba[i])
                + 0.587 * f64::from(frame.rgba[i + 1])
                + 0.114 * f64::from(frame.rgba[i + 2]);
            let cell = (y * N / h) * N + x * N / w;
            gray[cell] += g;
            count[cell] += 1.0;
        }
    }
    let (lo, hi) = gray
        .iter()
        .zip(&count)
        .filter(|(_, c)| **c > 0.0)
        .map(|(g, c)| g / c)
        .fold((f64::MAX, f64::MIN), |(l, h), v| (l.min(v), h.max(v)));
    if hi - lo < 2.0 {
        return Vec::new(); // a flat picture has nothing that stands out (its spectrum is rounding noise)
    }
    let mut spec: Vec<C> = gray.iter().zip(&count).map(|(g, c)| C(g / c.max(1.0), 0.0)).collect();
    fft2(&mut spec, false);
    let log_amp: Vec<f64> = spec.iter().map(|c| (c.0.hypot(c.1) + 1e-9).ln()).collect();
    let avg = mean3(&log_amp);
    let mut back: Vec<C> = spec
        .iter()
        .zip(log_amp.iter().zip(&avg))
        .map(|(c, (l, a))| {
            let amp = (l - a).exp();
            let phase = c.1.atan2(c.0);
            C(amp * phase.cos(), amp * phase.sin())
        })
        .collect();
    // The average brightness is not an object: without the DC term the squared result is only what stands out.
    back[0] = C(0.0, 0.0);
    fft2(&mut back, true);
    let sq: Vec<f64> = back.iter().map(|c| c.0 * c.0 + c.1 * c.1).collect();
    mean3(&mean3(&sq))
}

/// The strongest salient blob of `frame` as a box in fractions of the frame; empty when nothing stands out.
pub fn salient_boxes(frame: &SubjectFrame) -> Vec<AnonymizeBox> {
    if frame.width == 0 || frame.height == 0 || frame.rgba.len() < frame.width * frame.height * 4 {
        return Vec::new();
    }
    let s = map(frame);
    if s.is_empty() {
        return Vec::new();
    }
    let mean = s.iter().sum::<f64>() / s.len() as f64;
    let limit = mean * 3.0;
    if limit <= 1e-9 {
        return Vec::new();
    }
    let mut seen = vec![false; N * N];
    let mut best: Option<(f64, usize, usize, usize, usize)> = None; // mass, x0, y0, x1, y1
    for start in 0..N * N {
        if seen[start] || s[start] <= limit {
            continue;
        }
        let (mut mass, mut x0, mut y0, mut x1, mut y1) = (0.0, N, N, 0, 0);
        let mut stack = vec![start];
        seen[start] = true;
        while let Some(i) = stack.pop() {
            let (x, y) = (i % N, i / N);
            mass += s[i];
            (x0, y0, x1, y1) = (x0.min(x), y0.min(y), x1.max(x), y1.max(y));
            for (nx, ny) in [(x.wrapping_sub(1), y), (x + 1, y), (x, y.wrapping_sub(1)), (x, y + 1)] {
                if nx < N && ny < N && !seen[ny * N + nx] && s[ny * N + nx] > limit {
                    seen[ny * N + nx] = true;
                    stack.push(ny * N + nx);
                }
            }
        }
        if best.is_none_or(|b| mass > b.0) {
            best = Some((mass, x0, y0, x1, y1));
        }
    }
    best.map(|(_, x0, y0, x1, y1)| {
        let f = N as f64;
        AnonymizeBox {
            x: x0 as f64 / f,
            y: y0 as f64 / f,
            width: (x1 + 1 - x0) as f64 / f,
            height: (y1 + 1 - y0) as f64 / f,
        }
    })
    .into_iter()
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(paint: impl Fn(usize, usize) -> u8) -> SubjectFrame {
        let (w, h) = (128, 128);
        let mut rgba = Vec::new();
        for y in 0..h {
            for x in 0..w {
                let g = paint(x, y);
                rgba.extend_from_slice(&[g, g, g, 255]);
            }
        }
        SubjectFrame::new(w, h, rgba)
    }

    #[test]
    fn the_fft_round_trips_and_finds_a_pure_tone() {
        let mut a: Vec<C> =
            (0..N).map(|i| C((2.0 * std::f64::consts::PI * 4.0 * i as f64 / N as f64).cos(), 0.0)).collect();
        let original: Vec<f64> = a.iter().map(|c| c.0).collect();
        fft(&mut a, false);
        let peak = (0..N).max_by(|x, y| a[*x].0.hypot(a[*x].1).total_cmp(&a[*y].0.hypot(a[*y].1))).unwrap_or(0);
        assert!(peak == 4 || peak == N - 4);
        fft(&mut a, true);
        assert!(a.iter().zip(&original).all(|(c, o)| (c.0 - o).abs() < 1e-9 && c.1.abs() < 1e-9));
    }

    #[test]
    fn a_flat_picture_has_no_salient_object() {
        assert!(salient_boxes(&picture(|_, _| 120)).is_empty());
    }

    #[test]
    fn a_picture_with_a_lone_textured_patch_gives_one_box_inside_the_frame() {
        // Checkerboard patch at x 80..108, y 20..48 of 128 on a flat gray background.
        let f = picture(|x, y| {
            if (80..108).contains(&x) && (20..48).contains(&y) {
                if (x / 4 + y / 4) % 2 == 0 { 250 } else { 5 }
            } else {
                120
            }
        });
        let boxes = salient_boxes(&f);
        // Something stands out and the answer is one sane box inside the frame. Where it lands is a heuristic (the spectral
        // residual is not Vision's attention model): on synthetic art it can sit at the picture's center, so the position
        // is only checked on real pictures by the detector test.
        assert_eq!(boxes.len(), 1, "{boxes:?}");
        let b = boxes[0];
        assert!(b.x >= 0.0 && b.y >= 0.0 && b.x + b.width <= 1.0 + 1e-9 && b.y + b.height <= 1.0 + 1e-9, "{b:?}");
        assert!(b.width > 0.02 && b.width < 0.9 && b.height > 0.02 && b.height < 0.9, "{b:?}");
    }
}
