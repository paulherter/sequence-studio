// Swift: Gamut.swift
//! RGB gamuts from xy primaries and a white point; matrices are built in f64 and exposed as f32. Bradford adaptation
//! and the Planckian white point used by the white balance.

use std::sync::LazyLock;

use super::vec::{Mat3, Mat3d, Vec3};

/// RGB gamut defined by xy primaries and white point.
#[derive(Clone, Debug, PartialEq)]
pub struct Gamut {
    /// Red primary xy.
    pub red: [f64; 2],
    /// Green primary xy.
    pub green: [f64; 2],
    /// Blue primary xy.
    pub blue: [f64; 2],
    /// White point xy.
    pub white: [f64; 2],
    /// Linear RGB to XYZ in f64.
    pub rgb_to_xyz_double: Mat3d,
    /// Linear RGB to XYZ.
    pub rgb_to_xyz: Mat3,
    /// XYZ to linear RGB.
    pub xyz_to_rgb: Mat3,
    /// Y row of `rgb_to_xyz`.
    pub luma_row: Vec3,
}

impl Gamut {
    /// Gamut from primaries and white point.
    pub fn new(red: [f64; 2], green: [f64; 2], blue: [f64; 2], white: [f64; 2]) -> Gamut {
        let p = Mat3d { cols: [WhitePoint::xyz(red), WhitePoint::xyz(green), WhitePoint::xyz(blue)] };
        let s = p.inverse().mul_vec(WhitePoint::xyz(white));
        let m = p.mul_mat(&Mat3d::diagonal(s));
        Gamut {
            red,
            green,
            blue,
            white,
            rgb_to_xyz_double: m,
            rgb_to_xyz: m.to_f32(),
            xyz_to_rgb: m.inverse().to_f32(),
            luma_row: Vec3::new(m.cols[0][1] as f32, m.cols[1][1] as f32, m.cols[2][1] as f32),
        }
    }

    /// Linear RGB(self) to linear RGB(target), Bradford-adapted when the white points differ.
    pub fn matrix(&self, target: &Gamut) -> Mat3 {
        let mut m = target.rgb_to_xyz_double.inverse();
        if self.white != target.white {
            m = m.mul_mat(&WhitePoint::bradford(WhitePoint::xyz(self.white), WhitePoint::xyz(target.white)));
        }
        m.mul_mat(&self.rgb_to_xyz_double).to_f32()
    }
}

const D65: [f64; 2] = [0.3127, 0.3290];

macro_rules! gamuts {
    ($($(#[$doc:meta])* $name:ident: [$r:expr, $g:expr, $b:expr, $w:expr];)*) => {
        impl Gamut {
            $(
                $(#[$doc])*
                pub fn $name() -> &'static Gamut {
                    static G: LazyLock<Gamut> = LazyLock::new(|| Gamut::new($r, $g, $b, $w));
                    &G
                }
            )*
        }
    };
}

gamuts! {
    /// Rec.709 / sRGB primaries, D65.
    rec709: [[0.64, 0.33], [0.30, 0.60], [0.15, 0.06], D65];
    /// Rec.2020.
    bt2020: [[0.708, 0.292], [0.170, 0.797], [0.131, 0.046], D65];
    /// Sony S-Gamut3.Cine.
    s_gamut3_cine: [[0.766, 0.275], [0.225, 0.800], [0.089, -0.087], D65];
    /// Panasonic V-Gamut.
    v_gamut: [[0.730, 0.280], [0.165, 0.840], [0.100, -0.030], D65];
    /// DJI D-Gamut.
    d_gamut: [[0.71, 0.31], [0.21, 0.88], [0.09, -0.08], D65];
    /// Canon Cinema Gamut.
    cinema_gamut: [[0.740, 0.270], [0.170, 1.140], [0.080, -0.100], D65];
    /// "SQ Wide": the published DaVinci Wide Gamut primaries (D65); available, not the default working space.
    sq_wide: [[0.8000, 0.3130], [0.1682, 0.9877], [0.0790, -0.1155], D65];
    /// Display P3 with the D65 white.
    display_p3: [[0.680, 0.320], [0.265, 0.690], [0.150, 0.060], D65];
    /// ARRI Wide Gamut 3 (LogC3).
    arri_wide_gamut3: [[0.6840, 0.3130], [0.2210, 0.8480], [0.0861, -0.1020], D65];
    /// ARRI Wide Gamut 4 (LogC4).
    arri_wide_gamut4: [[0.7347, 0.2653], [0.1424, 0.8576], [0.0991, -0.0308], D65];
    /// REDWideGamutRGB.
    red_wide_gamut_rgb: [[0.780308, 0.304253], [0.121595, 1.493994], [0.095612, -0.084589], D65];
    /// Blackmagic Wide Gamut (Gen 5).
    blackmagic_wide_gamut: [[0.7177215, 0.3171181], [0.2280410, 0.8615690], [0.1005841, -0.0820452], [0.3127170, 0.3290312]];
    /// Fujifilm F-Gamut C.
    f_gamut_c: [[0.7347, 0.2653], [0.0263, 0.9737], [0.1173, -0.0224], D65];
    /// ACES AP1 (ACEScct), ACES white (Bradford-adapted to D65 by `matrix`).
    aces_ap1: [[0.713, 0.293], [0.165, 0.830], [0.128, 0.044], [0.32168, 0.33767]];
}

/// White point helpers.
pub struct WhitePoint;

impl WhitePoint {
    /// xy (Y = 1) to XYZ.
    pub fn xyz(xy: [f64; 2]) -> [f64; 3] {
        [xy[0] / xy[1], 1.0, (1.0 - xy[0] - xy[1]) / xy[1]]
    }

    /// XYZ to XYZ adaptation matrix (Bradford) from source white to destination white.
    pub fn bradford(src: [f64; 3], dst: [f64; 3]) -> Mat3d {
        let m = Mat3d::from_rows([[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]);
        let cs = m.mul_vec(src);
        let cd = m.mul_vec(dst);
        m.inverse().mul_mat(&Mat3d::diagonal([cd[0] / cs[0], cd[1] / cs[1], cd[2] / cs[2]])).mul_mat(&m)
    }

    /// CIE 1960 uv of the Planckian locus (Krystek 1985), T in kelvin.
    fn planck_uv(t: f64) -> [f64; 2] {
        let t2 = t * t;
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t2) / (1.0 + 8.42420235e-4 * t + 7.08145163e-7 * t2);
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t2) / (1.0 - 2.89741816e-5 * t + 1.61456053e-7 * t2);
        [u, v]
    }

    /// Chromaticity for correlated color temperature and Duv (positive = above the locus = greenish).
    pub fn xy(cct: f64, duv: f64) -> [f64; 2] {
        let mut uv = Self::planck_uv(cct);
        if duv != 0.0 {
            let a = Self::planck_uv(cct - 10.0);
            let b = Self::planck_uv(cct + 10.0);
            let d = [b[0] - a[0], b[1] - a[1]];
            let mut n = [-d[1], d[0]];
            let len = (n[0] * n[0] + n[1] * n[1]).sqrt();
            n = [n[0] / len, n[1] / len];
            if n[1] < 0.0 {
                n = [-n[0], -n[1]];
            }
            uv = [uv[0] + duv * n[0], uv[1] + duv * n[1]];
        }
        let k = 2.0 * uv[0] - 8.0 * uv[1] + 4.0;
        [3.0 * uv[0] / k, 2.0 * uv[1] / k]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rec709_to_itself_is_identity() {
        let m = Gamut::rec709().matrix(Gamut::rec709());
        for c in 0..3 {
            for r in 0..3 {
                let want = if c == r { 1.0 } else { 0.0 };
                assert!((m.cols[c][r] - want).abs() < 1e-6);
            }
        }
    }

    #[test]
    fn white_maps_to_white_across_gamuts() {
        for g in [Gamut::bt2020(), Gamut::s_gamut3_cine(), Gamut::aces_ap1(), Gamut::arri_wide_gamut4()] {
            let w = g.matrix(Gamut::rec709()).mul_vec(Vec3::ONE);
            assert!((w.x - 1.0).abs() < 1e-4 && (w.y - 1.0).abs() < 1e-4 && (w.z - 1.0).abs() < 1e-4, "{w:?}");
        }
    }

    #[test]
    fn rec709_luma_row_is_the_standard_weights() {
        let l = Gamut::rec709().luma_row;
        assert!((l.x - 0.2126).abs() < 1e-4 && (l.y - 0.7152).abs() < 1e-4 && (l.z - 0.0722).abs() < 1e-4);
    }
}
