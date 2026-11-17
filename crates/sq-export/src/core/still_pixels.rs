// Swift: FrameStillPixels.swift

use super::frame_output::FrameStillFormat;

/// The pixels of one image-sequence still: the export frame is rgba half floats, premultiplied, linear Rec.709 light;
/// each format gets the same code values on both platforms.
/// - PNG, JPEG: 8-bit BT.709 OETF, opaque. PNG (with alpha): 8-bit straight alpha (un-premultiplied in linear light).
/// - TIFF (16-bit): the same at 16 bits. EXR: the half floats unchanged (premultiplied, linear).
pub struct FrameStillPixels;

/// RGBA rows, tightly packed, top down. `bits_per_channel` 8 (u8), 16 (u16, little-endian) or, for EXR, 16 as IEEE half
/// floats (`is_float`). Channels are always four; `has_alpha` false = alpha is opaque (skip it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StillImage {
    /// Pixel bytes.
    pub bytes: Vec<u8>,
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// 8 or 16.
    pub bits_per_channel: usize,
    /// IEEE half floats instead of integers (EXR).
    pub is_float: bool,
    /// Whether alpha is meaningful.
    pub has_alpha: bool,
}

impl StillImage {
    /// Bytes of one row.
    pub fn bytes_per_row(&self) -> usize {
        self.width * 4 * self.bits_per_channel / 8
    }
}

impl FrameStillPixels {
    /// BT.709 OETF of a linear value (clamped to 0...1).
    // The constants are the standard's; they round to the same f32 as Swift's literals.
    #[allow(clippy::excessive_precision)]
    pub fn oetf(x: f32) -> f32 {
        let v = x.clamp(0.0, 1.0);
        if v < 0.018053968510807 { 4.5 * v } else { 1.09929682680944 * v.powf(0.45) - 0.09929682680944 }
    }

    /// IEEE binary16 bits to f32.
    pub fn float(half_bits: u16) -> f32 {
        let sign = u32::from(half_bits & 0x8000) << 16;
        let exp = i32::from((half_bits >> 10) & 0x1F);
        let mant = u32::from(half_bits & 0x3FF);
        if exp == 0 {
            if mant == 0 {
                return f32::from_bits(sign);
            }
            let v = mant as f32 / 1024.0 / 16384.0; // subnormal: mant * 2^-24
            return if sign != 0 { -v } else { v };
        }
        if exp == 31 {
            return f32::from_bits(sign | 0x7F80_0000 | (mant << 13));
        }
        f32::from_bits(sign | ((exp - 15 + 127) as u32) << 23 | (mant << 13))
    }

    /// `src`: `height` rows of `width` rgba halves (little-endian), `bytes_per_row` apart.
    pub fn image(
        half_rgba: &[u8],
        width: usize,
        height: usize,
        bytes_per_row: usize,
        format: FrameStillFormat,
    ) -> Option<StillImage> {
        let (w, h) = (width, height);
        if w == 0 || h == 0 || bytes_per_row < w * 8 || half_rgba.len() < (h - 1) * bytes_per_row + w * 8 {
            return None;
        }
        let half = |y: usize, i: usize| {
            let o = y * bytes_per_row + i * 2;
            u16::from_le_bytes([half_rgba[o], half_rgba[o + 1]])
        };
        if format == FrameStillFormat::Exr {
            let mut out = vec![0u8; w * h * 8];
            for y in 0..h {
                out[y * w * 8..(y + 1) * w * 8]
                    .copy_from_slice(&half_rgba[y * bytes_per_row..y * bytes_per_row + w * 8]);
            }
            return Some(StillImage {
                bytes: out,
                width: w,
                height: h,
                bits_per_channel: 16,
                is_float: true,
                has_alpha: true,
            });
        }
        let alpha = format.keeps_alpha();
        let sixteen = matches!(format, FrameStillFormat::Tiff16 | FrameStillFormat::Tiff16Alpha);
        let scale: f32 = if sixteen { 65535.0 } else { 255.0 };
        let mut out = vec![0u8; w * h * if sixteen { 8 } else { 4 }];
        for y in 0..h {
            for x in 0..w {
                let (mut r, mut g, mut b) =
                    (Self::float(half(y, x * 4)), Self::float(half(y, x * 4 + 1)), Self::float(half(y, x * 4 + 2)));
                let mut a: f32 = 1.0;
                if alpha {
                    // Straight (not premultiplied) alpha: un-premultiply in linear light, then apply the curve.
                    a = Self::float(half(y, x * 4 + 3)).clamp(0.0, 1.0);
                    if a > 0.0 {
                        r /= a;
                        g /= a;
                        b /= a;
                    } else {
                        (r, g, b) = (0.0, 0.0, 0.0);
                    }
                }
                let p = (y * w + x) * 4;
                for (k, c) in [Self::oetf(r), Self::oetf(g), Self::oetf(b), a].into_iter().enumerate() {
                    let v = (c * scale).round();
                    if sixteen {
                        out[(p + k) * 2..(p + k) * 2 + 2].copy_from_slice(&(v as u16).to_le_bytes());
                    } else {
                        out[p + k] = v as u8;
                    }
                }
            }
        }
        Some(StillImage {
            bytes: out,
            width: w,
            height: h,
            bits_per_channel: if sixteen { 16 } else { 8 },
            is_float: false,
            has_alpha: alpha,
        })
    }
}
