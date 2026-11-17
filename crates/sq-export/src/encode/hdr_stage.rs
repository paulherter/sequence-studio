//! HDR output stage (Swift: `HDRDelivery.encode`, `ExportShaderSource` with `SQ_HDR`): a picture conformed to Rec.2020
//! HLG or PQ as 10-bit P010. Linear Rec.709 light (1.0 = reference white, 203 nit) -> Rec.2020 primaries -> HLG or PQ
//! signal -> Y'CbCr with the Rec.2020 matrix, limited range. Two inputs: `to_p010_f16`, the engine's half-float working
//! composite (highlights above SDR white survive; docs/rust/HDR-PLAN.md), and `to_p010`, an 8-bit Rec.709 picture
//! (a source that only has an SDR frame; 8-bit code values -> linear first).

use crate::core::HdrTransfer;
use sq_render::color::gamut::Gamut;
use sq_render::color::transfer::{bt709_inverse_oetf, hlg_encode, pq_encode};
use sq_render::color::vec::{Mat3, Vec3};

/// The signal (R', G', B' in 0...1) of one linear Rec.709 pixel; mirrors `HDRDelivery.encode`.
pub(super) fn encode_linear(transfer: HdrTransfer, lin: Vec3, to2020: &Mat3) -> Vec3 {
    let c = to2020.mul_vec(lin);
    let c = Vec3::new(c.x.max(0.0), c.y.max(0.0), c.z.max(0.0));
    let s = match transfer {
        HdrTransfer::Pq => Vec3::new(pq_encode(c.x), pq_encode(c.y), pq_encode(c.z)),
        HdrTransfer::Hlg => hlg_encode(c),
    };
    Vec3::new(s.x.clamp(0.0, 1.0), s.y.clamp(0.0, 1.0), s.z.clamp(0.0, 1.0))
}

/// Y'CbCr (Rec.2020 matrix, 10-bit limited range) of a signal: `(Y, Cb, Cr)` as code values.
pub(super) fn ycbcr10(s: Vec3) -> (f32, f32, f32) {
    let y = 0.2627 * s.x + 0.6780 * s.y + 0.0593 * s.z;
    let cb = (s.z - y) / 1.8814;
    let cr = (s.x - y) / 1.4746;
    (64.0 + 876.0 * y, 512.0 + 896.0 * cb, 512.0 + 896.0 * cr)
}

/// `rgba` (4 bytes per pixel, `bgr` = BGRA order, `stride` bytes per row) as tightly packed P010: the Y plane, then
/// interleaved CbCr at half size (box average); 10-bit values in the high bits of 16-bit little-endian words.
pub(super) fn to_p010(rgba: &[u8], stride: usize, bgr: bool, w: usize, h: usize, transfer: HdrTransfer) -> Vec<u8> {
    let lut: Vec<f32> = (0..256).map(|v| bt709_inverse_oetf(v as f32 / 255.0)).collect();
    let (ri, bi) = if bgr { (2, 0) } else { (0, 2) };
    pack_p010(w, h, transfer, |row, x| {
        let px = &rgba[row * stride + x * 4..][..4];
        Vec3::new(lut[px[ri] as usize], lut[px[1] as usize], lut[px[bi] as usize])
    })
}

/// IEEE half float to f32 (NaN and infinity become 0, so a stray value cannot poison a row).
fn half_to_f32(h: u16) -> f32 {
    let (sign, exp, man) = (u32::from(h >> 15), u32::from((h >> 10) & 0x1F), u32::from(h & 0x3FF));
    let v = match exp {
        0 => man as f32 * (1.0 / 16_777_216.0), // subnormal: man * 2^-24
        31 => 0.0,
        _ => f32::from_bits(((exp + 112) << 23) | (man << 13)),
    };
    if sign == 1 { -v } else { v }
}

/// `rgba16f` (RGBA half floats, premultiplied linear Rec.709, 1.0 = reference white; `stride` bytes per row) as tightly
/// packed P010. Same layout and levels as `to_p010`; nothing is clamped before the transfer function.
pub(super) fn to_p010_f16(rgba16f: &[u8], stride: usize, w: usize, h: usize, transfer: HdrTransfer) -> Vec<u8> {
    pack_p010(w, h, transfer, |row, x| {
        let px = &rgba16f[row * stride + x * 8..][..8];
        let c = |i: usize| half_to_f32(u16::from_le_bytes([px[i * 2], px[i * 2 + 1]]));
        Vec3::new(c(0), c(1), c(2))
    })
}

/// The P010 bytes of a `w` x `h` picture whose linear Rec.709 pixel `(row, x)` is `linear`.
fn pack_p010(w: usize, h: usize, transfer: HdrTransfer, linear: impl Fn(usize, usize) -> Vec3 + Sync) -> Vec<u8> {
    let to2020 = Gamut::rec709().matrix(Gamut::bt2020());
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let mut y_plane = vec![0u16; w * h];
    let mut cb_cr = vec![0u16; cw * ch * 2];
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(8);
    // Each worker takes whole pairs of rows: its luma rows and its chroma row never overlap another worker's.
    let pairs_per = ch.div_ceil(threads).max(1);
    std::thread::scope(|scope| {
        let mut y_rest = y_plane.as_mut_slice();
        let mut c_rest = cb_cr.as_mut_slice();
        let mut first = 0usize;
        while first < ch {
            let pairs = pairs_per.min(ch - first);
            let rows = (pairs * 2).min(h - first * 2);
            let (y_chunk, y_tail) = y_rest.split_at_mut(rows * w);
            let (c_chunk, c_tail) = c_rest.split_at_mut(pairs * cw * 2);
            (y_rest, c_rest) = (y_tail, c_tail);
            let (linear, to2020) = (&linear, &to2020);
            scope.spawn(move || {
                for p in 0..pairs {
                    let mut chroma = vec![(0.0f32, 0.0f32); cw];
                    for dy in 0..2 {
                        let row = p * 2 + dy;
                        if row >= rows {
                            break;
                        }
                        for x in 0..w {
                            let lin = linear(first * 2 + row, x);
                            let (y, cb, cr) = ycbcr10(encode_linear(transfer, lin, to2020));
                            y_chunk[row * w + x] = (y.round().clamp(64.0, 940.0) as u16) << 6;
                            let slot = &mut chroma[x / 2];
                            slot.0 += cb;
                            slot.1 += cr;
                        }
                    }
                    for (x, (cb, cr)) in chroma.iter().enumerate() {
                        let n = (((w - x * 2).min(2)) * (rows - p * 2).min(2)) as f32;
                        c_chunk[(p * cw + x) * 2] = ((cb / n).round().clamp(64.0, 960.0) as u16) << 6;
                        c_chunk[(p * cw + x) * 2 + 1] = ((cr / n).round().clamp(64.0, 960.0) as u16) << 6;
                    }
                }
            });
            first += pairs;
        }
    });
    y_plane.iter().chain(cb_cr.iter()).flat_map(|v| v.to_le_bytes()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gray_p010(v: u8, transfer: HdrTransfer) -> Vec<u16> {
        let px: Vec<u8> = (0..4 * 3 * 3).map(|i| if i % 4 == 3 { 255 } else { v }).collect();
        let out = to_p010(&px, 12, false, 3, 3, transfer);
        out.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    }

    #[test]
    fn white_lands_on_the_reference_signal_levels() {
        // Odd size 3x3: 9 luma words, then 2x2 chroma pairs (8 words).
        let pq = gray_p010(255, HdrTransfer::Pq);
        assert_eq!(pq.len(), 9 + 8);
        // PQ of 203 nit = 0.5807 -> code 64 + 876 * 0.5807 = 573; chroma neutral.
        assert_eq!(pq[0] >> 6, 573);
        assert!(pq[9..].iter().all(|c| c >> 6 == 512));
        // HLG reference white is signal 0.75 -> 64 + 876 * 0.75 = 721.
        let hlg = gray_p010(255, HdrTransfer::Hlg);
        assert_eq!(hlg[0] >> 6, 721);
        assert!(hlg[9..].iter().all(|c| c >> 6 == 512));
    }

    fn half(v: f32) -> u16 {
        // Enough for the test values: normal numbers with a 10-bit mantissa, rounded down.
        if v == 0.0 {
            return 0;
        }
        let b = v.to_bits();
        let sign = if v < 0.0 { 0x8000 } else { 0 };
        sign | ((((b >> 23) & 0xFF) as i32 - 112) as u16) << 10 | ((b >> 13) & 0x3FF) as u16
    }

    fn gray_f16_p010(v: f32, transfer: HdrTransfer) -> Vec<u16> {
        let px: Vec<u8> =
            (0..9).flat_map(|_| [half(v), half(v), half(v), half(1.0)]).flat_map(u16::to_le_bytes).collect();
        to_p010_f16(&px, 24, 3, 3, transfer).chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    }

    #[test]
    fn half_floats_decode_exactly() {
        for v in [0.0f32, 1.0, 0.5, 4.0, 4.93, 0.000061035156, -2.0] {
            let h = half(v);
            let back = half_to_f32(h);
            assert!((back - v).abs() <= v.abs() * 1.0e-3, "{v} -> {back}");
        }
        assert_eq!(half_to_f32(0x7C00), 0.0); // infinity
        assert!((half_to_f32(1) - 5.9604645e-8).abs() < 1e-12); // smallest subnormal
    }

    #[test]
    fn float_white_matches_the_8_bit_path_and_highlights_go_above_it() {
        let pq = gray_f16_p010(1.0, HdrTransfer::Pq);
        assert_eq!(pq[0] >> 6, 573);
        assert!(pq[9..].iter().all(|c| c >> 6 == 512));
        assert_eq!(gray_f16_p010(1.0, HdrTransfer::Hlg)[0] >> 6, 721);
        // 4x reference white (812 nit): far above SDR white in PQ, and above 75 % in HLG.
        assert!(gray_f16_p010(4.0, HdrTransfer::Pq)[0] >> 6 > 700);
        assert!(gray_f16_p010(4.0, HdrTransfer::Hlg)[0] >> 6 > 721);
        // Negative light (a wide-gamut overshoot) floors at black.
        assert_eq!(gray_f16_p010(-1.0, HdrTransfer::Pq)[0] >> 6, 64);
    }

    /// The SDR path (8-bit pictures) is the same picture as the float path fed the decoded 8-bit values: the 8-bit
    /// export keeps its output, the new float input only adds range.
    #[test]
    fn the_8_bit_and_the_float_input_agree_on_sdr_pictures() {
        let (w, h) = (6usize, 4usize);
        let px8: Vec<u8> = (0..w * h * 4).map(|i| if i % 4 == 3 { 255 } else { ((i * 37) % 256) as u8 }).collect();
        let lut: Vec<f32> = (0..256).map(|v| bt709_inverse_oetf(v as f32 / 255.0)).collect();
        let f16: Vec<u8> = px8
            .chunks(4)
            .flat_map(|p| [lut[p[0] as usize], lut[p[1] as usize], lut[p[2] as usize], 1.0])
            .flat_map(|v| half(v).to_le_bytes())
            .collect();
        for t in HdrTransfer::ALL {
            let a = to_p010(&px8, w * 4, false, w, h, t);
            let b = to_p010_f16(&f16, w * 8, w, h, t);
            assert_eq!(a.len(), b.len());
            let words =
                |v: &[u8]| v.chunks(2).map(|c| i32::from(u16::from_le_bytes([c[0], c[1]]) >> 6)).collect::<Vec<_>>();
            // Half floats keep 11 bits: dark values land within a few codes of the exact path.
            let worst = words(&a).iter().zip(words(&b)).map(|(x, y)| (x - y).abs()).max().unwrap_or(0);
            assert!(worst <= 3, "{t:?}: worst difference {worst} codes");
        }
    }

    #[test]
    fn black_is_the_limited_range_floor_and_the_low_bits_are_clear() {
        for t in HdrTransfer::ALL {
            let o = gray_p010(0, t);
            assert_eq!(o[0] >> 6, 64);
            assert!(o.iter().all(|c| c & 0x3F == 0));
        }
    }

    #[test]
    fn red_has_the_rec2020_chroma() {
        let px = [255u8, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255];
        let o = to_p010(&px, 8, false, 2, 2, HdrTransfer::Pq);
        let w: Vec<u16> = o.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]]) >> 6).collect();
        // Rec.709 red is inside Rec.2020: Cr is high, Cb below neutral.
        assert!(w[5] > 560, "Cr {}", w[5]);
        assert!(w[4] < 512, "Cb {}", w[4]);
    }
}
