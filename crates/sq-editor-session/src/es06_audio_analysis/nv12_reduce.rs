// Swift: NV12Reduce.swift
//! The playback quality's picture reduction for engines that get full-size NV12 bytes from their decoder: a box filter
//! over 2 x 2 (1/2) or 4 x 4 (1/4) luma samples and the matching chroma pairs.
//! shortcut: the decoder still decodes at full size (only upload, cache and sampling shrink); upgrade by letting FFmpeg
//! scale (sws / hardware scaler) when decode time limits Windows playback.

use sq_media::video_decoding::DecodeScale;

/// A reduced NV12 picture.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Nv12Picture {
    pub bytes: Vec<u8>,
    pub width: usize,
    pub height: usize,
}

/// Namespace of the NV12 reduction (Swift `NV12Reduce`).
// Swift: NV12Reduce.swift:11
pub enum Nv12Reduce {}

impl Nv12Reduce {
    /// The divisor of a decode scale (1, 2, 4).
    // Swift: NV12Reduce.swift:12
    pub fn divisor(s: DecodeScale) -> usize {
        s.divisor() as usize
    }

    /// `bytes` (width x height luma, then interleaved CbCr at half size, stride = width) reduced by `d`; `None` when the
    /// divisor is 1, the size does not divide evenly into whole chroma pairs, or the bytes are short.
    // Swift: NV12Reduce.swift:18
    pub fn reduce(bytes: &[u8], w: usize, h: usize, d: usize) -> Option<Nv12Picture> {
        if d <= 1 || !w.is_multiple_of(2 * d) || !h.is_multiple_of(2 * d) || bytes.len() < w * h * 3 / 2 {
            return None;
        }
        let (ow, oh) = (w / d, h / d);
        let mut out = vec![0u8; ow * oh * 3 / 2];
        let area = d * d;
        let half = area / 2;
        for y in 0..oh {
            for x in 0..ow {
                let mut sum = 0usize;
                for dy in 0..d {
                    let row = (y * d + dy) * w + x * d;
                    sum += bytes[row..row + d].iter().map(|b| usize::from(*b)).sum::<usize>();
                }
                out[y * ow + x] = ((sum + half) / area) as u8;
            }
        }
        // Chroma: (w / 2) x (h / 2) Cb Cr pairs, each averaged over d x d pairs.
        let (cw, ocw, och) = (w / 2, ow / 2, oh / 2);
        let (c_base, o_base) = (w * h, ow * oh);
        for y in 0..och {
            for x in 0..ocw {
                let (mut cb, mut cr) = (0usize, 0usize);
                for dy in 0..d {
                    let row = c_base + (y * d + dy) * cw * 2 + x * d * 2;
                    for dx in 0..d {
                        cb += usize::from(bytes[row + dx * 2]);
                        cr += usize::from(bytes[row + dx * 2 + 1]);
                    }
                }
                let o = o_base + (y * ocw + x) * 2;
                out[o] = ((cb + half) / area) as u8;
                out[o + 1] = ((cr + half) / area) as u8;
            }
        }
        Some(Nv12Picture { bytes: out, width: ow, height: oh })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn divisors() {
        assert_eq!(Nv12Reduce::divisor(DecodeScale::Full), 1);
        assert_eq!(Nv12Reduce::divisor(DecodeScale::Half), 2);
        assert_eq!(Nv12Reduce::divisor(DecodeScale::Quarter), 4);
    }

    #[test]
    fn refuses_what_it_cannot_reduce() {
        assert!(Nv12Reduce::reduce(&[0; 24], 4, 4, 1).is_none());
        assert!(Nv12Reduce::reduce(&[0; 24], 4, 4, 4).is_none()); // 4 is not a multiple of 2 * 4
        assert!(Nv12Reduce::reduce(&[0; 10], 4, 4, 2).is_none()); // short
    }

    #[test]
    fn averages_luma_and_chroma() {
        // 4 x 4: luma rows of 10 10 20 20 ... , chroma Cb 100 Cr 50 everywhere.
        let mut b = Vec::new();
        for _ in 0..4 {
            b.extend_from_slice(&[10, 10, 20, 20]);
        }
        for _ in 0..4 {
            b.extend_from_slice(&[100, 50]);
        }
        let r = Nv12Reduce::reduce(&b, 4, 4, 2).expect("reducible");
        assert_eq!((r.width, r.height), (2, 2));
        assert_eq!(r.bytes, vec![10, 20, 10, 20, 100, 50]);
    }
}
