//! Accuracy of drawn-mask tracking against known ground truth (docs/rust/GAPS-B.md, "Tracking a path mask"). Synthetic clips: a
//! textured object that moves and scales over a textured background, with sensor noise and motion blur; one has an occluder
//! crossing the object. The tracked center and scale are compared with the truth per frame. `cargo test -p sq-analysis
//! mask_track_accuracy -- --nocapture` prints the table. A real clip is measured by the ignored test (`SQ_MASK_TRACK_CLIP`).

use crate::mask_point_tracker::{Gray, track_region};
use sq_core_masks::mask_motion::{MaskMotion, MaskTrackMode};
use sq_core_time::Vec2;

const W: usize = 480;
const H: usize = 270;
const FRAMES: usize = 40;
const SUBFRAMES: usize = 3;
const HALF: f64 = 40.0;

/// Deterministic hash noise, -0.5...0.5.
fn hash(x: i64, y: i64, seed: u64) -> f32 {
    let mut h = (x as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (y as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F) ^ seed;
    h ^= h >> 29;
    h = h.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    h ^= h >> 32;
    (h & 0xFFFF) as f32 / 65535.0 - 0.5
}

/// Smooth value noise at one scale (bilinear over a hashed lattice).
fn value_noise(x: f64, y: f64, cell: f64, seed: u64) -> f32 {
    let (fx, fy) = (x / cell, y / cell);
    let (ix, iy) = (fx.floor(), fy.floor());
    let (tx, ty) = ((fx - ix) as f32, (fy - iy) as f32);
    let (ix, iy) = (ix as i64, iy as i64);
    let a = hash(ix, iy, seed) * (1.0 - tx) + hash(ix + 1, iy, seed) * tx;
    let b = hash(ix, iy + 1, seed) * (1.0 - tx) + hash(ix + 1, iy + 1, seed) * tx;
    a * (1.0 - ty) + b * ty
}

fn texture(x: f64, y: f64, seed: u64) -> f32 {
    0.5 + 0.9 * value_noise(x, y, 14.0, seed)
        + 0.5 * value_noise(x, y, 5.0, seed + 1)
        + 0.25 * value_noise(x, y, 2.5, seed + 2)
}

/// Where the object is at (fractional) frame `t`: center in px and scale against frame 0.
fn truth(kind: Kind, t: f64) -> (Vec2, f64) {
    let u = t / (FRAMES as f64 - 1.0);
    let center = Vec2::new(150.0 + 170.0 * u, 120.0 + 25.0 * (u * std::f64::consts::TAU).sin());
    let scale = match kind {
        Kind::Move => 1.0,
        Kind::Grow => 1.0 + 0.5 * u,
        Kind::Shrink => 1.0 - 0.35 * u,
        Kind::Occluded => 1.0 + 0.2 * u,
    };
    (center, scale)
}

#[derive(Clone, Copy, Debug)]
enum Kind {
    Move,
    Grow,
    Shrink,
    Occluded,
}

fn render(kind: Kind, frame: usize) -> Gray {
    let mut px = vec![0.0f32; W * H];
    for (i, v) in px.iter_mut().enumerate() {
        let (x, y) = ((i % W) as f64, (i / W) as f64);
        let mut sum = 0.0;
        for s in 0..SUBFRAMES {
            // Motion blur: the shutter covers 70 % of the frame interval.
            let t = frame as f64 + (s as f64 / (SUBFRAMES as f64 - 1.0) - 0.5) * 0.7;
            let (c, k) = truth(kind, t);
            let (u, w) = ((x - c.x) / k, (y - c.y) / k);
            let mut value = if u.abs() < HALF && w.abs() < HALF {
                texture(u + 1000.0, w + 1000.0, 7)
            } else {
                0.8 * texture(x, y, 99) * 0.7 + 0.15
            };
            if matches!(kind, Kind::Occluded) && (16..=26).contains(&frame) {
                // A bar crossing the right third of the object, in front of it.
                let bar_x = c.x + HALF * k * 0.2;
                if x > bar_x && x < bar_x + HALF * k * 0.9 && (y - c.y).abs() < HALF * k * 1.3 {
                    value = 0.25 + 0.2 * texture(x, y, 5);
                }
            }
            sum += value;
        }
        let noise = hash(i as i64, frame as i64, 4242) * 0.05 + hash(i as i64, frame as i64, 77) * 0.03;
        *v = (sum / SUBFRAMES as f32 + noise).clamp(0.0, 1.0);
    }
    Gray { w: W, h: H, px }
}

/// The drawn outline on frame 0, in frame fractions (a little inside the object, as a hand-drawn mask is).
fn outline() -> Vec<Vec2> {
    let (c, _) = truth(Kind::Move, 0.0);
    let r = HALF * 0.9;
    [(-r, -r), (r, -r), (r, r), (-r, r)]
        .iter()
        .map(|(dx, dy)| Vec2::new((c.x + dx) / W as f64, (c.y + dy) / H as f64))
        .collect()
}

/// Mean and max center error (px), mean and max scale error (share), and the number of tracked frames.
pub struct Accuracy {
    /// Mean center error in px.
    pub mean_px: f64,
    /// Max center error in px.
    pub max_px: f64,
    /// Max scale error, share of the true scale.
    pub max_scale: f64,
    /// Frames tracked (not lost).
    pub tracked: usize,
    /// Frames of the clip.
    pub frames: usize,
}

/// Error of `motions` against `truths` (center px, scale), the outline's own center being the object center.
pub fn score(motions: &[Option<MaskMotion>], truths: &[(Vec2, f64)], check_scale: bool) -> Accuracy {
    let (w, h) = (W as f64, H as f64);
    let (c0, s0) = truths[0];
    let (mut sum, mut max, mut max_scale, mut n) = (0.0f64, 0.0f64, 0.0f64, 0usize);
    for (m, (c, s)) in motions.iter().zip(truths) {
        let Some(m) = m else { continue };
        let p = m.apply(Vec2::new(c0.x / w, c0.y / h));
        let e = ((p.x * w - c.x).powi(2) + (p.y * h - c.y).powi(2)).sqrt();
        sum += e;
        max = max.max(e);
        n += 1;
        if check_scale {
            let px = m.in_pixels(w, h).m;
            let est = (px[0] * px[4] - px[1] * px[3]).abs().sqrt();
            max_scale = max_scale.max((est - s / s0).abs() / (s / s0));
        }
    }
    Accuracy { mean_px: sum / n.max(1) as f64, max_px: max, max_scale, tracked: n, frames: motions.len() }
}

fn measure(kind: Kind, mode: MaskTrackMode) -> Accuracy {
    let truths: Vec<(Vec2, f64)> = (0..FRAMES).map(|i| truth(kind, i as f64)).collect();
    let mut f = |i: usize| Some(render(kind, i));
    let motions = track_region(&outline(), mode, &mut f, FRAMES, &mut |_| false);
    score(&motions, &truths, !matches!(mode, MaskTrackMode::Position))
}

fn row(name: &str, a: &Accuracy) -> String {
    format!(
        "{name:<22} mean {:5.2} px  max {:5.2} px  scale max {:4.1} %  tracked {}/{}",
        a.mean_px,
        a.max_px,
        a.max_scale * 100.0,
        a.tracked,
        a.frames
    )
}

#[test]
fn the_synthetic_clips_meet_the_accuracy_targets() {
    let cases = [
        ("move / Position", Kind::Move, MaskTrackMode::Position),
        ("move / Scale", Kind::Move, MaskTrackMode::Scale),
        ("grow / Scale", Kind::Grow, MaskTrackMode::Scale),
        ("shrink / Scale", Kind::Shrink, MaskTrackMode::Scale),
        ("occluded / Scale", Kind::Occluded, MaskTrackMode::Scale),
    ];
    let mut failures = Vec::new();
    for (name, kind, mode) in cases {
        let a = measure(kind, mode);
        sq_os::outln!("{}", row(name, &a));
        let scale_ok = matches!(mode, MaskTrackMode::Position) || a.max_scale <= 0.03;
        if a.tracked != a.frames || a.mean_px > 2.0 || a.max_px > 6.0 || !scale_ok {
            failures.push(row(name, &a));
        }
    }
    assert!(failures.is_empty(), "targets missed (mean <= 2 px, max <= 6 px, scale <= 3 %):\n{}", failures.join("\n"));
}

/// A real clip: the object is outlined as a box given by `SQ_MASK_TRACK_BOX` ("x0,y0,x1,y1" fractions on frame 0); the clip is read
/// as gray frames through the ffmpeg command line. No ground truth exists, so this prints the track and checks it stays found;
/// look at the numbers or overlay them.
#[test]
#[ignore = "needs SQ_MASK_TRACK_CLIP (a video file) and ffmpeg"]
fn a_real_clip_is_tracked_through() {
    let clip = std::env::var("SQ_MASK_TRACK_CLIP").expect("SQ_MASK_TRACK_CLIP");
    let b: Vec<f64> = std::env::var("SQ_MASK_TRACK_BOX")
        .unwrap_or_else(|_| "0.35,0.3,0.65,0.7".into())
        .split(',')
        .map(|s| s.trim().parse().expect("number"))
        .collect();
    let out = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "error",
            "-i",
            &clip,
            "-vf",
            &format!("scale={W}:{H}"),
            "-frames:v",
            "120",
            "-pix_fmt",
            "gray",
            "-f",
            "rawvideo",
            "-",
        ])
        .output()
        .expect("ffmpeg");
    let frames: Vec<Gray> = out
        .stdout
        .as_chunks::<{ W * H }>()
        .0
        .iter()
        .map(|c| Gray { w: W, h: H, px: c.iter().map(|&v| v as f32 / 255.0).collect() })
        .collect();
    assert!(frames.len() > 10, "clip too short");
    let region = vec![Vec2::new(b[0], b[1]), Vec2::new(b[2], b[1]), Vec2::new(b[2], b[3]), Vec2::new(b[0], b[3])];
    let mut f = |i: usize| frames.get(i).cloned();
    let motions = track_region(&region, MaskTrackMode::Scale, &mut f, frames.len(), &mut |_| false);
    let tracked = motions.iter().filter(|m| m.is_some()).count();
    for (i, m) in motions.iter().enumerate().step_by(10) {
        if let Some(m) = m {
            let c = m.apply(Vec2::new((b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0));
            sq_os::outln!("frame {i}: center {:.1}, {:.1} px", c.x * W as f64, c.y * H as f64);
        }
    }
    sq_os::outln!("tracked {tracked}/{}", frames.len());
    assert!(tracked * 10 >= frames.len() * 8, "lost the object early");
}
