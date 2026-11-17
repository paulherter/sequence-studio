use super::*;
#[cfg(target_os = "macos")]
use sq_analysis::registration_math::SplitMix;

fn near(a: f64, b: f64, tol: f64) -> bool {
    (a - b).abs() <= tol
}

#[test]
fn a_translation_warp_becomes_the_content_motion() {
    // Vision maps current -> previous with y up: content that moved 5 right and 3 down has tx = -5, ty = +3.
    let warp = VisionWarp::Translation { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: -5.0, ty: 3.0 };
    let m = motion_from_warp(&warp, 256, 192).expect("motion");
    assert!(near(m.dx, 5.0, 1e-6) && near(m.dy, 3.0, 1e-6), "{m:?}");
    assert!(near(m.rotation, 0.0, 1e-6) && near(m.scale, 1.0, 1e-9));
}

#[test]
fn an_identity_homography_is_no_motion_and_a_warp_to_infinity_is_none() {
    let id = VisionWarp::Homography { columns: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]] };
    let m = motion_from_warp(&id, 100, 100).expect("motion");
    assert!(near(m.dx, 0.0, 1e-9) && near(m.dy, 0.0, 1e-9) && near(m.scale, 1.0, 1e-9));
    let flat = VisionWarp::Homography { columns: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 0.0]] };
    assert!(motion_from_warp(&flat, 100, 100).is_none());
}

/// Smooth value noise: textured enough for a registration, deterministic.
#[cfg(target_os = "macos")]
fn texture(w: usize, h: usize) -> Vec<u8> {
    let mut rng = SplitMix::new(7);
    let cell = 8;
    let (gw, gh) = (w / cell + 2, h / cell + 2);
    let grid: Vec<f64> = (0..gw * gh).map(|_| (rng.next_u64() >> 11) as f64 / (1u64 << 53) as f64).collect();
    (0..w * h)
        .map(|i| {
            let (x, y) = ((i % w) as f64 / cell as f64, (i / w) as f64 / cell as f64);
            let (x0, y0) = (x.floor() as usize, y.floor() as usize);
            let (fx, fy) = (x - x0 as f64, y - y0 as f64);
            let g = |gx: usize, gy: usize| grid[gy * gw + gx];
            let top = g(x0, y0) * (1.0 - fx) + g(x0 + 1, y0) * fx;
            let bottom = g(x0, y0 + 1) * (1.0 - fx) + g(x0 + 1, y0 + 1) * fx;
            ((top * (1.0 - fy) + bottom * fy) * 255.0) as u8
        })
        .collect()
}

/// A `w` x `h` window of the `big` texture (row length `bw`) starting at (`x0`, `y0`): a window moved by (-dx, -dy)
/// shows the content moved by (dx, dy), with real texture at the edges (no clamped strips).
#[cfg(target_os = "macos")]
fn window(big: &[u8], bw: usize, x0: i64, y0: i64, w: usize, h: usize) -> Vec<u8> {
    (0..w * h).map(|i| big[(y0 as usize + i / w) * bw + x0 as usize + i % w]).collect()
}

#[cfg(target_os = "macos")]
const MARGIN: i64 = 20;

/// The previous and the current window of a content shift of (dx, dy).
#[cfg(target_os = "macos")]
fn pair(w: usize, h: usize, dx: i64, dy: i64) -> (Vec<u8>, Vec<u8>) {
    let (bw, bh) = (w + 2 * MARGIN as usize, h + 2 * MARGIN as usize);
    let big = texture(bw, bh);
    (window(&big, bw, MARGIN, MARGIN, w, h), window(&big, bw, MARGIN - dx, MARGIN - dy, w, h))
}

#[cfg(target_os = "macos")]
#[test]
fn vision_recovers_a_known_translation_within_half_a_pixel() {
    let (w, h) = (256usize, 192usize);
    for (dx, dy) in [(5i64, 3i64), (-7, 2), (0, -4)] {
        let (previous, current) = pair(w, h, dx, dy);
        let (p, c) =
            (Gray8 { width: w, height: h, pixels: &previous }, Gray8 { width: w, height: h, pixels: &current });
        let warp = register_with(p, c, false).expect("Vision finds a translation");
        let m = motion_from_warp(&warp, w, h).expect("motion");
        assert!(near(m.dx, dx as f64, 0.5) && near(m.dy, dy as f64, 0.5), "shift ({dx}, {dy}) came back as {m:?}");
    }
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[test]
fn the_combined_registration_finds_a_plausible_motion_within_a_pixel_and_a_half() {
    // Vision's homography is coarse on this synthetic texture (measured: off by up to 0.8 px, and it does not follow
    // shifts beyond about 4 px); the translational request above is the exact one.
    let (w, h) = (256usize, 192usize);
    for (dx, dy) in [(3i64, 2i64), (-3, 1), (0, -2)] {
        let (previous, current) = pair(w, h, dx, dy);
        let (p, c) =
            (Gray8 { width: w, height: h, pixels: &previous }, Gray8 { width: w, height: h, pixels: &current });
        let m = registered_motion(p, c).expect("a motion");
        assert!(near(m.dx, dx as f64, 1.5) && near(m.dy, dy as f64, 1.5), "({dx}, {dy}) -> {m:?}");
    }
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[test]
fn vision_homography_recovers_a_known_translation_within_half_a_pixel() {
    let (w, h) = (256usize, 192usize);
    let (previous, current) = pair(w, h, 3, -2);
    let (p, c) = (Gray8 { width: w, height: h, pixels: &previous }, Gray8 { width: w, height: h, pixels: &current });
    let warp = register_with(p, c, true).expect("Vision finds a homography");
    let m = motion_from_warp(&warp, w, h).expect("motion");
    assert!(near(m.dx, 3.0, 0.5) && near(m.dy, -2.0, 0.5), "{m:?}");
    assert!(near(m.scale, 1.0, 0.01) && near(m.rotation, 0.0, 0.5), "{m:?}");
}

#[cfg(not(target_os = "macos"))]
#[test]
fn off_the_mac_vision_finds_nothing() {
    let px = vec![0u8; 16];
    let g = Gray8 { width: 4, height: 4, pixels: &px };
    assert!(registered_motion(g, g).is_none());
}
