//! The ITU-R BT.709 display profile embedded in exported stills, generated here from the standard's numbers (BT.709
//! primaries, D65 white, the BT.709 transfer curve) as an ICC v4 matrix/TRC profile. No third-party profile is shipped.
//! The colorants are adapted from D65 to the ICC D50 connection space with the Bradford matrix, as the ICC spec asks.

use std::sync::OnceLock;

/// BT.709 primaries (x, y) of red, green, blue.
const PRIMARIES: [(f64, f64); 3] = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)];
/// D65 white point (x, y).
const D65: (f64, f64) = (0.3127, 0.3290);
/// The ICC profile connection space white (D50), ICC.1 section 7.2.16.
const D50_XYZ: [f64; 3] = [0.9642, 1.0, 0.8249];
/// Bradford cone response matrix.
const BRADFORD: [[f64; 3]; 3] = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]];

fn xyz_of(x: f64, y: f64) -> [f64; 3] {
    [x / y, 1.0, (1.0 - x - y) / y]
}

fn mul_vec(m: &[[f64; 3]; 3], v: [f64; 3]) -> [f64; 3] {
    std::array::from_fn(|i| m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2])
}

fn mul_mat(a: &[[f64; 3]; 3], b: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    std::array::from_fn(|i| std::array::from_fn(|j| (0..3).map(|k| a[i][k] * b[k][j]).sum()))
}

fn inverse(m: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let c = |r: usize, s: usize| {
        let (r1, r2, s1, s2) = ((r + 1) % 3, (r + 2) % 3, (s + 1) % 3, (s + 2) % 3);
        m[r1][s1] * m[r2][s2] - m[r1][s2] * m[r2][s1]
    };
    let det = m[0][0] * c(0, 0) + m[0][1] * c(0, 1) + m[0][2] * c(0, 2);
    std::array::from_fn(|i| std::array::from_fn(|j| c(j, i) / det))
}

/// The red, green and blue colorants in D50 XYZ (the columns of the RGB to XYZ matrix).
pub fn colorants_d50() -> [[f64; 3]; 3] {
    let cols: Vec<[f64; 3]> = PRIMARIES.iter().map(|&(x, y)| xyz_of(x, y)).collect();
    let m: [[f64; 3]; 3] = std::array::from_fn(|i| std::array::from_fn(|j| cols[j][i]));
    let s = mul_vec(&inverse(&m), xyz_of(D65.0, D65.1));
    let scaled: [[f64; 3]; 3] = std::array::from_fn(|i| std::array::from_fn(|j| m[i][j] * s[j]));
    // Bradford: D65 -> D50.
    let (src, dst) = (mul_vec(&BRADFORD, xyz_of(D65.0, D65.1)), mul_vec(&BRADFORD, D50_XYZ));
    let scale: [[f64; 3]; 3] =
        std::array::from_fn(|i| std::array::from_fn(|j| if i == j { dst[i] / src[i] } else { 0.0 }));
    let adapt = mul_mat(&inverse(&BRADFORD), &mul_mat(&scale, &BRADFORD));
    let adapted = mul_mat(&adapt, &scaled);
    // Return per colorant: [X, Y, Z].
    std::array::from_fn(|c| std::array::from_fn(|i| adapted[i][c]))
}

fn s15(v: f64) -> [u8; 4] {
    ((v * 65536.0).round() as i32).to_be_bytes()
}

fn xyz_tag(v: [f64; 3]) -> Vec<u8> {
    let mut t = b"XYZ \0\0\0\0".to_vec();
    v.iter().for_each(|x| t.extend(s15(*x)));
    t
}

fn text_tag(s: &str) -> Vec<u8> {
    let mut t = b"mluc\0\0\0\0\0\0\0\x01\0\0\0\x0cenUS".to_vec();
    t.extend(((s.len() * 2) as u32).to_be_bytes());
    t.extend(28u32.to_be_bytes());
    s.encode_utf16().for_each(|u| t.extend(u.to_be_bytes()));
    t
}

/// The BT.709 curve decoded to linear light as an ICC parametric curve type 3:
/// Y = (a X + b)^g for X >= d, c X below (g 1/0.45, a 1/1.099, b 0.099/1.099, c 1/4.5, d 0.081).
fn trc_tag() -> Vec<u8> {
    let mut t = b"para\0\0\0\0\0\x03\0\0".to_vec();
    [1.0 / 0.45, 1.0 / 1.099, 0.099 / 1.099, 1.0 / 4.5, 0.081].iter().for_each(|v| t.extend(s15(*v)));
    t
}

fn pad4(mut v: Vec<u8>) -> Vec<u8> {
    while !v.len().is_multiple_of(4) {
        v.push(0);
    }
    v
}

/// Builds the profile bytes.
pub fn build() -> Vec<u8> {
    let c = colorants_d50();
    let chad = {
        // The Bradford D65 -> D50 adaptation matrix the colorants went through.
        let (src, dst) = (mul_vec(&BRADFORD, xyz_of(D65.0, D65.1)), mul_vec(&BRADFORD, D50_XYZ));
        let scale: [[f64; 3]; 3] =
            std::array::from_fn(|i| std::array::from_fn(|j| if i == j { dst[i] / src[i] } else { 0.0 }));
        let m = mul_mat(&inverse(&BRADFORD), &mul_mat(&scale, &BRADFORD));
        let mut t = b"sf32\0\0\0\0".to_vec();
        m.iter().flatten().for_each(|v| t.extend(s15(*v)));
        t
    };
    let trc = trc_tag();
    // (signature, data); the three curves share one data block, as Apple-style profiles do.
    let mut blocks: Vec<Vec<u8>> = vec![
        pad4(text_tag("Rec. 709 (Sequence Studio)")),
        pad4(text_tag("No copyright, generated from the BT.709 numbers")),
        xyz_tag(D50_XYZ),
        xyz_tag(c[0]),
        xyz_tag(c[1]),
        xyz_tag(c[2]),
        pad4(trc),
        chad,
    ];
    let sigs: [(&[u8; 4], usize); 10] = [
        (b"desc", 0),
        (b"cprt", 1),
        (b"wtpt", 2),
        (b"rXYZ", 3),
        (b"gXYZ", 4),
        (b"bXYZ", 5),
        (b"rTRC", 6),
        (b"chad", 7),
        (b"bTRC", 6),
        (b"gTRC", 6),
    ];
    let table_len = 4 + sigs.len() * 12;
    let mut offsets = Vec::new();
    let mut at = 128 + table_len;
    for b in &mut blocks {
        offsets.push(at);
        at += b.len();
    }
    let total = at;
    let mut out = Vec::with_capacity(total);
    out.extend((total as u32).to_be_bytes());
    out.extend([0u8; 4]); // no preferred CMM
    out.extend([4, 0, 0, 0]); // version 4.0
    out.extend(b"mntrRGB XYZ ");
    out.extend([0x07, 0xe6, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0]); // 2022-01-01 00:00:00
    out.extend(b"acsp");
    out.extend([0u8; 24]); // platform, flags, manufacturer, model, attributes: none; intent: perceptual
    out.extend(s15(D50_XYZ[0]));
    out.extend(s15(D50_XYZ[1]));
    out.extend(s15(D50_XYZ[2]));
    out.resize(128, 0);
    out.extend((sigs.len() as u32).to_be_bytes());
    for (sig, block) in sigs {
        out.extend(sig);
        out.extend((offsets[block] as u32).to_be_bytes());
        out.extend((blocks[block].len() as u32).to_be_bytes());
    }
    blocks.iter().for_each(|b| out.extend(b));
    out
}

/// The profile, built once.
pub fn itu_709() -> &'static [u8] {
    static PROFILE: OnceLock<Vec<u8>> = OnceLock::new();
    PROFILE.get_or_init(build)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn be32(b: &[u8], at: usize) -> u32 {
        u32::from_be_bytes(b[at..at + 4].try_into().expect("4 bytes"))
    }

    fn tag(p: &[u8], sig: &[u8; 4]) -> (usize, usize) {
        (0..be32(p, 128) as usize)
            .map(|i| 132 + i * 12)
            .find(|&e| &p[e..e + 4] == sig)
            .map(|e| (be32(p, e + 4) as usize, be32(p, e + 8) as usize))
            .expect("tag")
    }

    fn xyz(p: &[u8], sig: &[u8; 4]) -> [f64; 3] {
        let (o, _) = tag(p, sig);
        std::array::from_fn(|i| be32(p, o + 8 + 4 * i) as i32 as f64 / 65536.0)
    }

    #[test]
    fn header_is_a_v4_rgb_display_profile_with_a_true_size() {
        let p = itu_709();
        assert_eq!(be32(p, 0) as usize, p.len());
        assert_eq!(p.len() % 4, 0);
        assert_eq!(&p[8..12], &[4, 0, 0, 0]);
        assert_eq!(&p[12..20], b"mntrRGB ");
        assert_eq!(&p[36..40], b"acsp");
        assert!(!p.windows(5).any(|w| w == b"Apple" || w == b"appl"));
    }

    /// The values the macOS ITU-R BT.709 profile held (read before it was removed from the repo), within 2e-4.
    #[test]
    fn colorimetry_matches_the_values_of_the_old_apple_profile() {
        let p = itu_709();
        let near = |got: [f64; 3], want: [f64; 3]| {
            for i in 0..3 {
                assert!((got[i] - want[i]).abs() < 2e-4, "{got:?} vs {want:?}");
            }
        };
        near(xyz(p, b"wtpt"), [0.964_187_6, 1.0, 0.824_89]);
        near(xyz(p, b"rXYZ"), [0.436_065_7, 0.222_488_4, 0.013_916]);
        near(xyz(p, b"gXYZ"), [0.385_147_1, 0.716_873_1, 0.097_076_4]);
        near(xyz(p, b"bXYZ"), [0.143_066_4, 0.060_607_9, 0.714_096_0]);
        // The three curves are the BT.709 curve: g 2.2222, a 0.9099, b 0.0901, c 0.2222, d 0.0810 (type 3).
        let (o, _) = tag(p, b"rTRC");
        assert_eq!(&p[o..o + 4], b"para");
        assert_eq!(&p[o + 8..o + 10], &[0, 3]);
        let params: Vec<f64> = (0..5).map(|i| be32(p, o + 12 + 4 * i) as i32 as f64 / 65536.0).collect();
        for (got, want) in params.iter().zip([2.222_229, 0.909_912, 0.090_088, 0.222_229, 0.080_994]) {
            assert!((got - want).abs() < 2e-5, "{params:?}");
        }
        assert_eq!(tag(p, b"gTRC"), tag(p, b"rTRC"));
        assert_eq!(tag(p, b"bTRC"), tag(p, b"rTRC"));
    }

    #[test]
    fn white_is_the_sum_of_the_colorants() {
        let c = colorants_d50();
        for i in 0..3 {
            let sum = c[0][i] + c[1][i] + c[2][i];
            assert!((sum - D50_XYZ[i]).abs() < 1e-9, "{sum}");
        }
    }
}
