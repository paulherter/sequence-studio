// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Deinterlacer.swift (the CPU reference; the picture buffers and the Metal kernel are platform code)
//! Turns a woven interlaced picture (both fields in one frame) into a progressive one, one output frame per source frame.
//!
//! Comb-adaptive, one frame at a time (no neighbor frames: a frame looks the same whatever was decoded before it, so scrub,
//! playback and export agree). The field that comes first in time is kept as stored. A sample of the other field stays as
//! stored (weave, full vertical detail) unless it combs: it lies beyond both vertical neighbors in the same direction and its
//! own field's next line does too, which is what motion between the two fields looks like and what a still picture (a
//! one-line rule, a gradient, an edge) does not. Combing samples are rebuilt from the kept field along the local edge
//! direction. Each plane (luma, chroma) is treated in its own rows (interlaced 4:2:0 stores chroma per field).
//!
//! The first and the last row of a plane have one vertical neighbor only, which cannot tell a comb from a still edge line:
//! they always stay as stored.
//!
//! This is the definition of the pass; a GPU kernel must match it. Callers hand it the planes of a decoded frame (bi-planar
//! Y'CbCr 8 bit or 10-in-16 bit, or one packed four-channel plane); RGB is not deinterlaced.

use sq_core_model::FieldOrder;

/// Comb size (normalized code values) where interpolation starts.
const LOW: f32 = 5.0 / 255.0;
/// Comb size where interpolation is complete.
const HIGH: f32 = 13.0 / 255.0;
/// A diagonal must beat the vertical by this much: equal candidates resolve the same way on CPU and GPU.
const DIRECTION_BIAS: f32 = 1.5 / 1024.0;

/// A sample type of a plane: 8 bit or 16 bit.
pub trait PlaneSample: Copy {
    /// Largest code value.
    const MAX: f32;
    /// The code value as a number.
    fn to_f32(self) -> f32;
    /// The nearest code value of an already clamped number.
    fn from_f32(v: f32) -> Self;
}

impl PlaneSample for u8 {
    const MAX: f32 = 255.0;
    fn to_f32(self) -> f32 {
        f32::from(self)
    }
    fn from_f32(v: f32) -> Self {
        v as u8
    }
}

impl PlaneSample for u16 {
    const MAX: f32 = 65535.0;
    fn to_f32(self) -> f32 {
        f32::from(self)
    }
    fn from_f32(v: f32) -> Self {
        v as u16
    }
}

/// The shape of one plane: `channels` interleaved samples per pixel (1 luma, 2 chroma, 4 packed), `stride` in samples.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlaneShape {
    /// Pixels per row.
    pub width: usize,
    /// Rows.
    pub height: usize,
    /// Interleaved samples per pixel.
    pub channels: usize,
    /// Samples from one row to the next (at least `width * channels`).
    pub stride: usize,
}

/// Field a frame keeps: the top field is the even rows.
fn keep_parity(order: FieldOrder) -> usize {
    if order == FieldOrder::TopFirst { 0 } else { 1 }
}

/// The progressive plane of `src` (same shape, same stride). Rows of the kept field and the edge rows are copied.
pub fn deinterlace_plane<T: PlaneSample>(src: &[T], shape: PlaneShape, order: FieldOrder) -> Vec<T> {
    let PlaneShape { width: w, height: h, channels: n, stride } = shape;
    let mut dst = src.to_vec();
    let keep = keep_parity(order);
    let scale = T::MAX;
    let row = |y: usize| &src[y * stride..y * stride + w * n];
    let f = |p: &[T], i: usize| p[i].to_f32() / scale;
    let diff = |a: &[T], i: usize, b: &[T], j: usize| -> f32 {
        (0..n).map(|ch| (f(a, i * n + ch) - f(b, j * n + ch)).abs()).sum()
    };
    let mut comb = vec![0f32; w];
    for y in 0..h {
        // An edge row has one neighbor: it stays as stored (a still edge line is not a comb).
        if (y & 1) == keep || y == 0 || y == h - 1 || w < 1 {
            continue;
        }
        let (c, a, b) = (row(y), row(y - 1), row(y + 1));
        let cu = if y >= 2 { row(y - 2) } else { c };
        let cd = if y + 2 < h { row(y + 2) } else { c };
        for (x, slot) in comb.iter_mut().enumerate() {
            let mut m = 0f32;
            for ch in 0..n {
                let i = x * n + ch;
                let (fc, fa, fb) = (f(c, i), f(a, i), f(b, i));
                let (d1, d2) = (fc - fa, fc - fb);
                if d1 * d2 > 0.0 {
                    let s: f32 = if d1 > 0.0 { 1.0 } else { -1.0 };
                    let beyond = (s * (f(cu, i) - fa)).max(s * (f(cd, i) - fb)).max(0.0);
                    m = m.max(d1.abs().min(d2.abs()).min(beyond));
                }
            }
            *slot = m;
        }
        let out = &mut dst[y * stride..y * stride + w * n];
        for x in 0..w {
            let (xm, xp, xm2, xp2) = (x.saturating_sub(1), (x + 1).min(w - 1), x.saturating_sub(2), (x + 2).min(w - 1));
            let m = comb[xm].max(comb[x].max(comb[xp]));
            let weight = ((m - LOW) / (HIGH - LOW)).clamp(0.0, 1.0);
            if weight <= 0.0 {
                continue;
            }
            let mut best = diff(a, xm, b, xm) + diff(a, x, b, x) + diff(a, xp, b, xp);
            let (mut ia, mut ib) = (x, x);
            let d = diff(a, xm2, b, x) + diff(a, xm, b, xp) + diff(a, x, b, xp2);
            if d + DIRECTION_BIAS < best {
                best = d;
                (ia, ib) = (xm, xp);
            }
            let d = diff(a, x, b, xm2) + diff(a, xp, b, xm) + diff(a, xp2, b, x);
            if d + DIRECTION_BIAS < best {
                (ia, ib) = (xp, xm);
            }
            for ch in 0..n {
                let (fa, fb, fc) = (f(a, x * n + ch), f(b, x * n + ch), f(c, x * n + ch));
                let r = ((f(a, ia * n + ch) + f(b, ib * n + ch)) * 0.5).clamp(fa.min(fb), fa.max(fb));
                let v = fc + (r - fc) * weight;
                out[x * n + ch] = T::from_f32((v * scale + 0.5).clamp(0.0, scale));
            }
        }
    }
    dst
}

/// The progressive picture of a downloaded 4:2:0 bi-planar frame (NV12 / P010: the Y plane, then the interleaved CbCr plane
/// of half the rows, one `bytes_per_row` for both), in the same layout. `wide`: 16-bit words (P010) instead of bytes.
/// `None` when `bytes` is too short for the picture.
pub fn deinterlace_biplanar_420(
    bytes: &[u8],
    width: usize,
    height: usize,
    bytes_per_row: usize,
    wide: bool,
    order: FieldOrder,
) -> Option<Vec<u8>> {
    let chroma_rows = height.div_ceil(2);
    let luma_len = bytes_per_row.checked_mul(height)?;
    if bytes.len() < luma_len + bytes_per_row.checked_mul(chroma_rows)? {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len());
    for (plane, rows, channels, w) in [(0, height, 1, width), (1, chroma_rows, 2, width.div_ceil(2))] {
        let start = if plane == 0 { 0 } else { luma_len };
        let src = &bytes[start..start + bytes_per_row * rows];
        if wide {
            let words: Vec<u16> = src.as_chunks::<2>().0.iter().map(|b| u16::from_le_bytes([b[0], b[1]])).collect();
            let shape = PlaneShape { width: w, height: rows, channels, stride: bytes_per_row / 2 };
            out.extend(deinterlace_plane(&words, shape, order).iter().flat_map(|v| v.to_le_bytes()));
        } else {
            let shape = PlaneShape { width: w, height: rows, channels, stride: bytes_per_row };
            out.extend(deinterlace_plane(src, shape, order));
        }
    }
    out.extend_from_slice(&bytes[out.len()..]);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 192;
    const H: usize = 96;
    const SHIFT: usize = 12;

    /// Luma of the scene with the box at `box_x` (Swift `Scene.luma`): gradient, bars, a one-line rule, a bright box.
    fn luma(x: usize, y: usize, box_x: usize, edge_lines: bool) -> u8 {
        if edge_lines && (y == 0 || y == H - 1) {
            return 230;
        }
        if (24..60).contains(&y) && (box_x..box_x + 40).contains(&x) {
            return 220;
        }
        if y == 80 {
            return 200;
        }
        if x >= 150 {
            return if (x / 3).is_multiple_of(2) { 60 } else { 150 };
        }
        (40 + (x + 2 * y) / 4) as u8
    }

    /// Both fields woven: the first-in-time field shows the box at 40, the later one `SHIFT` further.
    fn frame(order: FieldOrder, moving: bool, edge_lines: bool) -> Vec<u8> {
        let first_parity = keep_parity(order);
        let mut v = Vec::with_capacity(W * H);
        for y in 0..H {
            let later = (y & 1) != first_parity;
            let bx = if moving && later { 40 + SHIFT } else { 40 };
            v.extend((0..W).map(|x| luma(x, y, bx, edge_lines)));
        }
        v
    }

    fn shape() -> PlaneShape {
        PlaneShape { width: W, height: H, channels: 1, stride: W }
    }

    #[test]
    fn a_still_picture_is_woven_unchanged() {
        for order in [FieldOrder::TopFirst, FieldOrder::BottomFirst] {
            let src = frame(order, false, false);
            assert_eq!(deinterlace_plane(&src, shape(), order), src);
        }
    }

    #[test]
    fn the_earlier_field_is_kept_as_stored() {
        for order in [FieldOrder::TopFirst, FieldOrder::BottomFirst] {
            let src = frame(order, true, false);
            let out = deinterlace_plane(&src, shape(), order);
            for y in (keep_parity(order)..H).step_by(2) {
                assert_eq!(src[y * W..(y + 1) * W], out[y * W..(y + 1) * W]);
            }
        }
    }

    #[test]
    fn moving_areas_lose_the_comb_in_both_field_orders() {
        for order in [FieldOrder::TopFirst, FieldOrder::BottomFirst] {
            let src = frame(order, true, false);
            let truth: Vec<u8> = (0..H).flat_map(|y| (0..W).map(move |x| luma(x, y, 40, false))).collect();
            let combed = src.iter().zip(&truth).map(|(a, b)| a.abs_diff(*b)).max().unwrap();
            assert!(combed > 100);
            let out = deinterlace_plane(&src, shape(), order);
            let far = out.iter().zip(&truth).filter(|(a, b)| a.abs_diff(**b) > 3).count();
            assert!(far <= 2 * SHIFT, "{order:?}: {far} samples off");
        }
    }

    #[test]
    fn the_field_order_decides_which_field_survives() {
        let src = frame(FieldOrder::TopFirst, true, false);
        let wrong = deinterlace_plane(&src, shape(), FieldOrder::BottomFirst);
        // Column 85 holds the box at the later time only.
        assert!((30..54).all(|y| wrong[y * W + 85] == 220));
        let right = deinterlace_plane(&src, shape(), FieldOrder::TopFirst);
        assert!((30..54).all(|y| right[y * W + 85] < 120));
    }

    #[test]
    fn edge_rows_are_left_alone() {
        for order in [FieldOrder::TopFirst, FieldOrder::BottomFirst] {
            let src = frame(order, true, true);
            let out = deinterlace_plane(&src, shape(), order);
            assert_eq!(src[..W], out[..W]);
            assert_eq!(src[(H - 1) * W..], out[(H - 1) * W..]);
        }
    }

    #[test]
    fn wide_and_packed_planes_work_and_a_stride_is_respected() {
        // 16 bit, two channels, padded rows: the same moving scene scaled up must lose its comb the same way.
        let src8 = frame(FieldOrder::TopFirst, true, false);
        let stride = W * 2 + 6;
        let mut src = vec![0u16; stride * H];
        for y in 0..H {
            for x in 0..W {
                let v = u16::from(src8[y * W + x]) * 257;
                src[y * stride + x * 2] = v;
                src[y * stride + x * 2 + 1] = 32768;
            }
        }
        let shape = PlaneShape { width: W, height: H, channels: 2, stride };
        let out = deinterlace_plane(&src, shape, FieldOrder::TopFirst);
        let narrow = deinterlace_plane(&src8, self::shape(), FieldOrder::TopFirst);
        for y in 0..H {
            for x in 0..W {
                assert!(out[y * stride + x * 2].abs_diff(u16::from(narrow[y * W + x]) * 257) <= 300);
                assert_eq!(out[y * stride + x * 2 + 1], 32768);
            }
            // The padding is copied as it was.
            assert_eq!(out[y * stride + W * 2..(y + 1) * stride], src[y * stride + W * 2..(y + 1) * stride]);
        }
    }

    #[test]
    fn a_downloaded_nv12_frame_is_deinterlaced_plane_by_plane() {
        let luma = frame(FieldOrder::TopFirst, true, false);
        let mut nv12 = luma.clone();
        nv12.extend(std::iter::repeat_n(128u8, W * H / 2));
        let out = deinterlace_biplanar_420(&nv12, W, H, W, false, FieldOrder::TopFirst).unwrap();
        assert_eq!(out.len(), nv12.len());
        assert_eq!(out[..W * H], deinterlace_plane(&luma, shape(), FieldOrder::TopFirst)[..]);
        assert_eq!(out[W * H..], nv12[W * H..]); // flat chroma does not comb
        assert!(deinterlace_biplanar_420(&nv12[..100], W, H, W, false, FieldOrder::TopFirst).is_none());
    }
}
