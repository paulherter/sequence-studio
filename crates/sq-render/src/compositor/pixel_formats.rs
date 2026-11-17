// Swift: PixelFormats+Portable.swift
//! The portable part of `PixelFormats`: matrix tags, the Y'CbCr to R'G'B' matrix and the range parameters the layer draw
//! reads.

/// Y'CbCr matrix coefficients.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatrixCoefficients {
    Bt601,
    Bt709,
    Bt2020,
}

/// Accepts AVFoundation names (`ITU_R_709_2`, `ITU_R_601_4`, `SMPTE_C`, `ITU_R_2020`), ffprobe names (`bt709`, `smpte170m`,
/// `bt470bg`, `bt2020nc`) and ISO numbers. Untagged or unknown = 709.
pub fn matrix(tag: Option<&str>) -> MatrixCoefficients {
    let Some(t) = tag.map(str::to_lowercase).filter(|t| !t.is_empty()) else { return MatrixCoefficients::Bt709 };
    if t.contains("2020") || t == "9" || t == "10" {
        return MatrixCoefficients::Bt2020;
    }
    if t.contains("601") || t.contains("470") || t.contains("170") || t.contains("smpte_c") || t == "5" || t == "6" {
        return MatrixCoefficients::Bt601;
    }
    MatrixCoefficients::Bt709
}

/// Y'CbCr (Y in 0...1, Cb/Cr centered on 0) to R'G'B', as columns for `M * (Y, Cb, Cr)`.
pub fn ycbcr_to_rgb(m: MatrixCoefficients) -> [[f32; 3]; 3] {
    let (kr, kb): (f32, f32) = match m {
        MatrixCoefficients::Bt601 => (0.299, 0.114),
        MatrixCoefficients::Bt709 => (0.2126, 0.0722),
        MatrixCoefficients::Bt2020 => (0.2627, 0.0593),
    };
    let kg = 1.0 - kr - kb;
    [
        [1.0, 1.0, 1.0],
        [0.0, -2.0 * kb * (1.0 - kb) / kg, 2.0 * (1.0 - kb)],
        [2.0 * (1.0 - kr), -2.0 * kr * (1.0 - kr) / kg, 0.0],
    ]
}

/// Sampled unorm planes of `bit_depth` (10 bit: MSB-aligned in 16) in full or video range.
pub fn range_params(bit_depth: u32, full_range: bool) -> [f32; 4] {
    let s = (1u32 << (bit_depth - 8)) as f32;
    let max_code = ((1u32 << bit_depth) - 1) as f32;
    // Sampled unorm to integer code: 8-bit = v*255, 10-bit MSB-aligned in 16 bit = v*65535/64, 16-bit = v*65535.
    let k: f32 = match bit_depth {
        8 => 255.0,
        16 => 65535.0,
        _ => 65535.0 / 64.0,
    };
    if full_range {
        [k / max_code, 0.0, k / max_code, -(128.0 * s) / max_code]
    } else {
        [k / (219.0 * s), -(16.0 * s) / (219.0 * s), k / (224.0 * s), -(128.0 * s) / (224.0 * s)]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_map_to_matrices() {
        assert_eq!(matrix(None), MatrixCoefficients::Bt709);
        assert_eq!(matrix(Some("ITU_R_2020")), MatrixCoefficients::Bt2020);
        assert_eq!(matrix(Some("smpte170m")), MatrixCoefficients::Bt601);
        assert_eq!(matrix(Some("6")), MatrixCoefficients::Bt601);
        assert_eq!(matrix(Some("bt709")), MatrixCoefficients::Bt709);
    }

    #[test]
    fn range_params_of_the_common_depths() {
        assert_eq!(range_params(8, true), [1.0, 0.0, 1.0, -128.0 / 255.0]);
        let v = range_params(8, false);
        assert!((v[0] - 255.0 / 219.0).abs() < 1e-6 && (v[1] + 16.0 / 219.0).abs() < 1e-6);
        let t = range_params(10, true);
        assert!((t[0] - 65535.0 / 64.0 / 1023.0).abs() < 1e-6);
    }

    #[test]
    fn white_ycbcr_is_white() {
        let m = ycbcr_to_rgb(MatrixCoefficients::Bt709);
        assert_eq!([m[0][0], m[0][1], m[0][2]], [1.0, 1.0, 1.0]);
    }
}
