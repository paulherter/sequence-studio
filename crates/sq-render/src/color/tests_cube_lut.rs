//! Ports of CubeLUTTests, CubeLUT3DLTests and LUTInterpolationAndOutputTests (LUT parts).

use super::cube_lut::{CubeKind, CubeLut, CubeLutError as E, LutInterpolation};
use super::testing::{Lcg, dist, identity_cube_3d};
use super::vec::Vec3;

fn parse(t: &str) -> CubeLut {
    CubeLut::parse(t).expect("parses")
}

fn err(t: &str) -> Option<E> {
    CubeLut::parse(t).err()
}

#[test]
fn identity_3d_sizes() {
    for n in [2usize, 17, 33] {
        let lut = parse(&identity_cube_3d(n, ""));
        let mut rng = Lcg(n as u64);
        for _ in 0..500 {
            let p = rng.rgb();
            assert!(dist(lut.lookup(p), p) < 1e-5);
        }
    }
}

#[test]
fn identity_1d_and_per_channel_linear() {
    let lut = parse("LUT_1D_SIZE 5\n0 0 0\n0.25 0.25 0.25\n0.5 0.5 0.5\n0.75 0.75 0.75\n1 1 1\n");
    let mut rng = Lcg(7);
    for _ in 0..200 {
        let p = rng.rgb();
        assert!(dist(lut.lookup(p), p) < 1e-6);
    }
    let lut = parse("LUT_1D_SIZE 3\n0 0 1\n1 0.5 0\n0 1 1\n");
    let o = lut.lookup(Vec3::new(0.25, 0.5, 0.75));
    assert!((o.x - 0.5).abs() < 1e-6 && (o.y - 0.5).abs() < 1e-6 && (o.z - 0.5).abs() < 1e-6);
}

#[test]
fn hand_computed_tetrahedral() {
    // N = 2, lattice value = (r*g, g*b, b*r). Point (0.5, 0.25, 0.75): b >= r >= g.
    let mut text = String::from("LUT_3D_SIZE 2\n");
    for b in 0..2 {
        for g in 0..2 {
            for r in 0..2 {
                text += &format!("{} {} {}\n", r * g, g * b, b * r);
            }
        }
    }
    let o = parse(&text).lookup(Vec3::new(0.5, 0.25, 0.75));
    assert!(dist(o, Vec3::new(0.25, 0.25, 0.5)) < 1e-6);
}

#[test]
fn exact_at_lattice_points() {
    let mut rng = Lcg(99);
    let n = 4;
    let mut text = format!("LUT_3D_SIZE {n}\n");
    let mut table = Vec::new();
    for _ in 0..n * n * n {
        let v = rng.rgb();
        table.push(v);
        text += &format!("{} {} {}\n", v.x, v.y, v.z);
    }
    let lut = parse(&text);
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                let p = Vec3::new(r as f32, g as f32, b as f32) / (n - 1) as f32;
                assert!(dist(lut.lookup(p), table[r + n * g + n * n * b]) < 1e-6);
            }
        }
    }
}

#[test]
fn domain_clamp_scaling_and_headers() {
    let lut = parse(&identity_cube_3d(2, "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n"));
    assert!(dist(lut.lookup(Vec3::ONE), Vec3::splat(0.5)) < 1e-6);
    assert!(dist(lut.lookup(Vec3::new(5.0, -3.0, 2.0)), Vec3::new(1.0, 0.0, 1.0)) < 1e-6);
    let lut = parse(&format!("DOMAIN_MAX 0.4 0.4 0.4\nDOMAIN_MIN -1 -1 -1\n{}", identity_cube_3d(2, "")));
    assert!(lut.domain_min == Vec3::splat(-1.0) && lut.domain_max == Vec3::splat(0.4));
    let lut = parse(&format!(
        "\u{FEFF}LUT_3D_INPUT_RANGE -0.5 2\nLUT_IN_VIDEO_RANGE\nLUT_OUT_VIDEO_RANGE\n{}",
        identity_cube_3d(2, "")
    ));
    assert!(lut.domain_min == Vec3::splat(-0.5) && lut.domain_max == Vec3::splat(2.0));
    assert!(lut.in_video_range && lut.out_video_range);
    let l1 = parse("LUT_1D_INPUT_RANGE 0 4\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n");
    assert!(l1.domain_max == Vec3::splat(4.0) && !l1.in_video_range && !l1.out_video_range);
    assert!(err("LUT_3D_INPUT_RANGE 1\nLUT_3D_SIZE 2\n").is_some());
}

#[test]
fn comments_title_blank_lines_crlf() {
    let mut text = String::from("# hi\r\n\r\nTITLE \"My LUT\"\r\n  # indented comment\r\nLUT_3D_SIZE 2\r\n");
    for i in 0..8 {
        text += &format!("{} {} {}\r\n", i & 1, (i >> 1) & 1, (i >> 2) & 1);
    }
    let lut = parse(&text);
    assert_eq!((lut.title.as_str(), lut.size, lut.kind), ("My LUT", 2, CubeKind::Lut3D));
}

#[test]
fn trailing_comments_are_stripped() {
    let id = identity_cube_3d(2, "");
    let mut lines: Vec<String> = id.lines().skip(2).map(String::from).collect();
    lines[0] += " # note";
    let text = format!("TITLE \"a # b\" # trailing\nLUT_3D_SIZE 2 # c\n{}", lines.join("\n"));
    let lut = parse(&text);
    assert!(lut.size == 2 && lut.table.len() == 8 && lut.title == "a # b");
    let l1 = parse("LUT_1D_SIZE 2\n0.1 0.2 0.3 # note\n1 1 1#x\n");
    assert!(l1.table[0] == Vec3::new(0.1, 0.2, 0.3) && l1.table[1] == Vec3::ONE);
}

#[test]
fn errors() {
    assert_eq!(err("0 0 0\n"), Some(E::MissingSize));
    assert_eq!(err("LUT_3D_SIZE 1\n"), Some(E::SizeOutOfRange { line: 1, size: 1 }));
    assert_eq!(err("\nLUT_3D_SIZE 257\n"), Some(E::SizeOutOfRange { line: 2, size: 257 }));
    assert_eq!(err("LUT_3D_SIZE 2\n0 0 0\n"), Some(E::WrongEntryCount { expected: 8, found: 1 }));
    assert_eq!(err("LUT_1D_SIZE 2\n0 0 0\nx 1 1\n"), Some(E::BadNumber { line: 3, token: "x".into() }));
    assert_eq!(err("LUT_1D_SIZE 2\n0 0\n1 1 1\n"), Some(E::MalformedLine { line: 2 }));
    assert_eq!(err("LUT_1D_SIZE 2\nFOO 1\n"), Some(E::UnknownKeyword { line: 2, keyword: "FOO".into() }));
    assert_eq!(err("LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n"), Some(E::ConflictingSizes { line: 2 }));
    assert_eq!(err("LUT_3D_SIZE abc\n"), Some(E::BadNumber { line: 1, token: "abc".into() }));
    assert_eq!(err("LUT_3D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n"), Some(E::InvalidDomain { line: 3 }));
    assert_eq!(err("LUT_3D_SIZE 2\nDOMAIN_MAX 0 0 0\nDOMAIN_MIN 1 1 1\n"), Some(E::InvalidDomain { line: 3 }));
}

#[test]
fn video_range_is_applied() {
    let id = identity_cube_3d(17, "");
    let make = |flags: &str| parse(&format!("{flags}{id}"));
    let both = make("LUT_IN_VIDEO_RANGE\nLUT_OUT_VIDEO_RANGE\n");
    for p in [Vec3::ZERO, Vec3::ONE, Vec3::new(0.3, 0.6, 0.9), Vec3::new(0.5, 0.25, 0.75)] {
        assert!(dist(both.lookup(p), p) < 1e-5);
    }
    let in_only = make("LUT_IN_VIDEO_RANGE\n");
    assert!(dist(in_only.lookup(Vec3::ZERO), Vec3::splat(64.0 / 1023.0)) < 1e-6);
    assert!(dist(in_only.lookup(Vec3::ONE), Vec3::splat(940.0 / 1023.0)) < 1e-6);
    let out_only = make("LUT_OUT_VIDEO_RANGE\n");
    assert!(dist(out_only.lookup(Vec3::splat(64.0 / 1023.0)), Vec3::ZERO) < 1e-6);
    assert!(dist(out_only.lookup(Vec3::splat(940.0 / 1023.0)), Vec3::ONE) < 1e-5);
}

const TINY_3DL: &str =
    "0 1023\n0 0 0\n0 0 1023\n0 1023 0\n0 1023 1023\n1023 0 0\n1023 0 1023\n1023 1023 0\n1023 1023 1023\n";

#[test]
fn threedl_mesh_line_and_red_fastest() {
    let lut = parse(TINY_3DL);
    assert!(lut.kind == CubeKind::Lut3D && lut.size == 2 && lut.table.len() == 8);
    for r in 0..2 {
        for g in 0..2 {
            for b in 0..2 {
                assert_eq!(lut.table[r + 2 * (g + 2 * b)], Vec3::new(r as f32, g as f32, b as f32));
            }
        }
    }
    assert_eq!(lut.lookup(Vec3::new(1.0, 0.0, 0.0)), Vec3::new(1.0, 0.0, 0.0));
}

#[test]
fn threedl_twelve_bit_errors_fractions_and_size_three() {
    let mut t = String::new();
    for r in 0..2 {
        for g in 0..2 {
            for b in 0..2 {
                t += &format!("{} {} {}\n", r * 4095, g * 4095, b * 4095);
            }
        }
    }
    let lut = CubeLut::parse_3dl(&format!("# 12 bit, no mesh line\n{t}")).expect("parses");
    assert!(lut.size == 2 && lut.table[1] == Vec3::new(1.0, 0.0, 0.0));
    assert!(CubeLut::parse_3dl("0 1023\n0 0 0\n1023 1023 1023\n").is_err());
    assert_eq!(err("0 0 0\n"), Some(E::MissingSize));
    let mut t = String::new();
    for r in 0..2 {
        for g in 0..2 {
            for b in 0..2 {
                t += &format!("{:?} {:?} {:?}\n", r as f32 * 1.02, g as f32 * 0.5, b as f32);
            }
        }
    }
    assert!((CubeLut::parse_3dl(&t).expect("parses").table[1].x - 1.02).abs() < 1e-5);
    let mut t = String::new();
    for r in 0..3 {
        for g in 0..3 {
            for b in 0..3 {
                t += &format!("{} {} {}\n", r * 511, g * 511, b * 511);
            }
        }
    }
    let with_mesh = CubeLut::parse_3dl(&format!("0 511 1022\n{t}")).expect("parses");
    assert!(with_mesh.size == 3 && with_mesh.table.len() == 27);
    assert!((with_mesh.table[1].x - 511.0 / 1023.0).abs() < 1e-5);
    let no_mesh = CubeLut::parse_3dl(&t).expect("parses");
    assert!(no_mesh.size == 3 && no_mesh.table == with_mesh.table);
}

fn non_linear_cube() -> CubeLut {
    let mut s = String::from("LUT_3D_SIZE 2\n");
    for b in 0..2 {
        for g in 0..2 {
            for r in 0..2 {
                let (fr, fg, fb) = (r as f32, g as f32, b as f32);
                s += &format!("{} {} {}\n", fr * fg, fg * fb, fr.max(fb));
            }
        }
    }
    parse(&s)
}

#[test]
fn interpolation_modes() {
    let tet = non_linear_cube();
    assert_eq!(tet.interpolation, LutInterpolation::Tetrahedral);
    let tri = tet.with_interpolation(LutInterpolation::Trilinear);
    let p = Vec3::new(0.3, 0.6, 0.8);
    let out = tri.lookup(p);
    assert!((out.x - 0.3 * 0.6).abs() < 1e-6 && (out.y - 0.6 * 0.8).abs() < 1e-6);
    for c in [Vec3::ZERO, Vec3::new(1.0, 0.0, 1.0), Vec3::ONE, Vec3::new(0.0, 1.0, 0.0)] {
        assert!(dist(tet.lookup(c), tri.lookup(c)) < 1e-6);
    }
    assert!(dist(tet.lookup(p), tri.lookup(p)) > 1e-3);
    let id = parse(&identity_cube_3d(17, "")).with_interpolation(LutInterpolation::Trilinear);
    let mut rng = Lcg(7);
    for _ in 0..200 {
        let p = rng.rgb();
        assert!(dist(id.lookup(p), p) < 1e-5);
    }
}

#[test]
fn vlt_files() {
    let n = 5;
    let mut s = String::from("# panasonic vlt file version 1\n# source vlt file\nLUT_3D_SIZE 5\n\n");
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                let q = |v: usize| (v as f64 / 4.0 * 4095.0).round() as i64;
                s += &format!("{} {} {}\n", q(r), q(g), q(b));
            }
        }
    }
    let lut = parse(&s);
    assert!(lut.kind == CubeKind::Lut3D && lut.size == 5);
    let mut rng = Lcg(3);
    for _ in 0..100 {
        let p = rng.rgb();
        assert!(dist(lut.lookup(p), p) < 5e-4);
    }
    let text = "# panasonic vlt file version 1\nLUT_3D_SIZE 2\n0 0 0\n4095 0 0\n0 4095 0\n4095 4095 0\n0 0 4095\n4095 0 4095\n0 4095 4095\n4095 4095 4095\n";
    let lut = CubeLut::parse_vlt(text).expect("parses");
    assert_eq!(
        (lut.table[1], lut.table[2], lut.table[4]),
        (Vec3::new(1.0, 0.0, 0.0), Vec3::new(0.0, 1.0, 0.0), Vec3::new(0.0, 0.0, 1.0))
    );
    assert!(CubeLut::parse_vlt("# panasonic vlt file version 1\nLUT_3D_SIZE 2\n0 0 0\n").is_err());
    assert!(CubeLut::parse_vlt("# panasonic vlt file version 1\n0 0 0\n").is_err());
}
