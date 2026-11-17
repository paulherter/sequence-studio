// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RollingShutterMeasure.swift
//! The per-row motion of a frame pair for the Stabilizer's Rolling Shutter option (sq-core-masks rolling_shutter).
//!
//! The registration of the Stabilizer check gives one similarity (shift, rotation, zoom) for the whole picture. A rolling
//! sensor adds a part no similarity holds: while the camera's speed changes, the shift grows along the scan axis. It is
//! measured as a dense flow on a grid: every cell (about 24 px) refines its own shift from the global fit, and an affine
//! field dx = a0 + a1 x + a2 y, dy = b0 + b1 x + b2 y goes through the cells that agree (a moving subject drops out).
//! Of its four linear terms a rotation and a zoom use two (a2 = -b1, a1 = b2); what is left is the slope:
//!   rows scanned along y:  slope = ((a2 + b1) * height, (b2 - a1) * height)
//!   rows scanned along x:  slope = ((a1 - b2) * width,  (b1 + a2) * width)
//! That split only holds where a pixel is square. The analysis frame has the stored pixels (anamorphic: wider than tall when
//! shown), so the field is taken to the displayed source picture first (X = fx x, Y = fy y):
//!   a1, b2 stay, a2 -> a2 fx / fy, b1 -> b1 fy / fx, shifts and extents by their own factor.
use crate::stabilization_check::{GrayFrame, PhotometricRegistration};
use sq_core_masks::rolling_shutter::RollingShutterSample;
use sq_core_masks::stabilizer::CameraMotion;
use sq_core_time::Vec2;

/// The rolling shutter measurement of a frame pair.
pub struct RollingShutterMeasure;

impl RollingShutterMeasure {
    /// Cell size of the flow grid in analysis pixels ...
    pub const CELL_SIZE: usize = 24;
    /// ... and the fewest agreeing cells for a sample.
    pub const MIN_CELLS: usize = 12;

    /// Shift and slope of `current` against `previous` (same size), started at the registered `motion` (analysis pixels).
    /// The result is in source pixels: `factor_x/y` = picture width / analysis width and picture height / analysis height
    /// (both 1: analysis pixels). `None` when too few textured cells agree.
    pub fn sample(
        previous: &GrayFrame,
        current: &GrayFrame,
        motion: &CameraMotion,
        along_x: bool,
        factor_x: f64,
        factor_y: f64,
    ) -> Option<RollingShutterSample> {
        if previous.width != current.width || previous.height != current.height {
            return None;
        }
        let (w, h) = (current.width, current.height);
        let r = motion.rotation * std::f64::consts::PI / 180.0;
        let a = motion.scale * r.cos() - 1.0;
        let b = motion.scale * r.sin();
        let (tx, ty) = (motion.dx, motion.dy);
        let cols = 4.max(w / Self::CELL_SIZE);
        let rows = 4.max(h / Self::CELL_SIZE);
        let cx = (w - 1) as f64 / 2.0;
        let cy = (h - 1) as f64 / 2.0;
        let mut at: Vec<Vec2> = Vec::with_capacity(cols * rows);
        let mut flow: Vec<Vec2> = Vec::with_capacity(cols * rows);
        for row in 0..rows {
            for col in 0..cols {
                let (x0, x1, y0, y1) = (col * w / cols, (col + 1) * w / cols, row * h / rows, (row + 1) * h / rows);
                let (mut ctx, mut cty, mut ok) = (tx, ty, false);
                for _ in 0..8 {
                    let Some((d, fit)) = PhotometricRegistration::step(
                        previous,
                        current,
                        ctx,
                        cty,
                        a,
                        b,
                        1,
                        Some((x0, x1, y0, y1)),
                        true,
                    ) else {
                        break;
                    };
                    if !(fit.texture >= PhotometricRegistration::MIN_TEXTURE && fit.valid > 0.5) {
                        break;
                    }
                    ctx += d.0;
                    cty += d.1;
                    if d.0.abs() < 0.005 && d.1.abs() < 0.005 {
                        ok = true;
                        break;
                    }
                }
                if !(ok && (ctx - tx).abs() < w as f64 / 16.0 && (cty - ty).abs() < h as f64 / 16.0) {
                    continue;
                }
                let p = Vec2::new(((x0 + x1) as f64 - 1.0) / 2.0 - cx, ((y0 + y1) as f64 - 1.0) / 2.0 - cy);
                at.push(p);
                flow.push(Vec2::new(a * p.x - b * p.y + ctx, b * p.x + a * p.y + cty));
            }
        }
        if at.len() < Self::MIN_CELLS {
            return None;
        }
        let mut keep: Vec<usize> = (0..at.len()).collect();
        let mut fx = [0.0_f64; 3];
        let mut fy = [0.0_f64; 3];
        for _ in 0..3 {
            if keep.len() < Self::MIN_CELLS {
                return None;
            }
            let pts: Vec<Vec2> = keep.iter().map(|&i| at[i]).collect();
            let xs: Vec<f64> = keep.iter().map(|&i| flow[i].x).collect();
            let ys: Vec<f64> = keep.iter().map(|&i| flow[i].y).collect();
            fx = Self::plane(&pts, &xs)?;
            fy = Self::plane(&pts, &ys)?;
            let res: Vec<f64> = (0..at.len())
                .map(|i| {
                    let ex = fx[0] + fx[1] * at[i].x + fx[2] * at[i].y - flow[i].x;
                    let ey = fy[0] + fy[1] * at[i].x + fy[2] * at[i].y - flow[i].y;
                    (ex * ex + ey * ey).sqrt()
                })
                .collect();
            let mut kept_res: Vec<f64> = keep.iter().map(|&i| res[i]).collect();
            kept_res.sort_by(f64::total_cmp);
            let limit = 0.25_f64.max(2.5 * kept_res[keep.len() / 2]);
            let next: Vec<usize> = (0..at.len()).filter(|&i| res[i] <= limit).collect();
            if next == keep {
                break;
            }
            keep = next;
        }
        if keep.len() < Self::MIN_CELLS {
            return None;
        }
        if !(factor_x > 0.0 && factor_y > 0.0 && factor_x.is_finite() && factor_y.is_finite()) {
            return None;
        }
        let a1 = fx[1];
        let a2 = fx[2] * factor_x / factor_y;
        let b1 = fy[1] * factor_y / factor_x;
        let b2 = fy[2];
        let width = w as f64 * factor_x;
        let height = h as f64 * factor_y;
        let slope = if along_x {
            Vec2::new((a1 - b2) * width, (b1 + a2) * width)
        } else {
            Vec2::new((a2 + b1) * height, (b2 - a1) * height)
        };
        let shift = Vec2::new(fx[0] * factor_x, fy[0] * factor_y);
        if !(slope.x.is_finite() && slope.y.is_finite() && shift.x.is_finite() && shift.y.is_finite()) {
            return None;
        }
        Some(RollingShutterSample { shift_x: shift.x, shift_y: shift.y, slope_x: slope.x, slope_y: slope.y })
    }

    /// Least-squares plane v = c0 + c1 x + c2 y through the points; `None` when they lie on a line.
    pub fn plane(p: &[Vec2], v: &[f64]) -> Option<[f64; 3]> {
        let (mut sx, mut sy, mut sxx, mut sxy, mut syy, mut sv, mut sxv, mut syv) =
            (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        for (q, value) in p.iter().zip(v) {
            sx += q.x;
            sy += q.y;
            sxx += q.x * q.x;
            sxy += q.x * q.y;
            syy += q.y * q.y;
            sv += value;
            sxv += q.x * value;
            syv += q.y * value;
        }
        let n = p.len() as f64;
        // Cramer on [[n sx sy] [sx sxx sxy] [sy sxy syy]].
        let det = n * (sxx * syy - sxy * sxy) - sx * (sx * syy - sxy * sy) + sy * (sx * sxy - sxx * sy);
        if det.abs() <= 1e-9 * (n * sxx * syy).max(1e-300) {
            return None;
        }
        let c0 = (sv * (sxx * syy - sxy * sxy) - sx * (sxv * syy - sxy * syv) + sy * (sxv * sxy - sxx * syv)) / det;
        let c1 = (n * (sxv * syy - sxy * syv) - sv * (sx * syy - sxy * sy) + sy * (sx * syv - sxv * sy)) / det;
        let c2 = (n * (sxx * syv - sxv * sxy) - sx * (sx * syv - sxv * sy) + sv * (sx * sxy - sxx * sy)) / det;
        Some([c0, c1, c2])
    }

    /// The sample in source pixels (`factor` = picture width / analysis width).
    pub fn scaled(s: &RollingShutterSample, factor: f64) -> RollingShutterSample {
        RollingShutterSample {
            shift_x: s.shift_x * factor,
            shift_y: s.shift_y * factor,
            slope_x: s.slope_x * factor,
            slope_y: s.slope_y * factor,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::rolling_shutter::RollingShutter;
    use sq_core_masks::stabilizer::StabilizationAnalysis;
    use sq_core_time::Time;
    use std::f64::consts::PI;

    // Rolling shutter without gyro data, measured on synthesized frames: a textured scene filmed hand-held by a sensor that
    // reads its rows one after the other (every row sees the scene where the camera was when that row was read). The readout
    // time must come back out of the frames, a global shutter must measure as none, and the shear that is left after the
    // correction is reported in source pixels.

    /// A scene with detail at several sizes, gray levels around 128.
    fn scene(x: f64, y: f64) -> f64 {
        128.0
            + 34.0 * (x / 5.3 + y / 9.1).sin()
            + 28.0 * (x / 11.7 - y / 6.3).cos()
            + 22.0 * (x / 3.1).sin() * (y / 4.3).cos()
            + 18.0 * ((x + 2.0 * y) / 17.9).sin()
            + 14.0 * ((3.0 * x - y) / 23.3).cos()
    }

    /// Where the scene stands in the picture at time `t` (analysis px): a pan with sway, and a bob.
    #[derive(Clone, Copy)]
    struct Camera {
        pan: f64,
        sway: f64,
        bob: f64,
    }

    impl Camera {
        const STANDARD: Camera = Camera { pan: 40.0, sway: 6.0, bob: 2.5 };

        fn shift(&self, t: f64) -> Vec2 {
            Vec2::new(
                self.pan * t + self.sway * (2.0 * PI * 1.3 * t).sin(),
                self.bob * (2.0 * PI * 2.1 * t + 0.4).sin(),
            )
        }

        fn velocity_x(&self, t: f64) -> f64 {
            self.pan + self.sway * 2.0 * PI * 1.3 * (2.0 * PI * 1.3 * t).cos()
        }
    }

    /// Frame `i` at 30 fps as a sensor with `readout` seconds from the first to the last row (scan position along y, or along
    /// x when `along_x`) records it, with one gray level of sensor noise.
    fn frame(i: u64, readout: f64, camera: &Camera, along_x: bool) -> GrayFrame {
        let (w, h) = (256_usize, 144_usize);
        let mut seed = i.wrapping_mul(7919).wrapping_add(13);
        let mut rnd = || {
            seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            (seed >> 33) as f64 / (1_u64 << 31) as f64 * 2.0 - 1.0
        };
        let mut px = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let v = if along_x {
                    (x as f64 + 0.5 - w as f64 / 2.0) / w as f64
                } else {
                    (y as f64 + 0.5 - h as f64 / 2.0) / h as f64
                };
                let c = camera.shift(i as f64 / 30.0 + readout * v);
                px[y * w + x] = (scene(x as f64 - c.x, y as f64 - c.y) + rnd()) as f32;
            }
        }
        GrayFrame::new(w, h, px)
    }

    /// The analysis the Stabilizer pass would store for the frames (source picture 1920 x 1080 over 256 x 144).
    fn analyze(n: u64, readout: f64, camera: &Camera, scan: i64) -> StabilizationAnalysis {
        let factor = 1920.0 / 256.0;
        let along_x = scan % 2 != 0;
        let mut rolling: Vec<Option<RollingShutterSample>> = vec![None];
        let mut previous = frame(0, readout, camera, along_x);
        for i in 1..n {
            let current = frame(i, readout, camera, along_x);
            let check = PhotometricRegistration::register(&previous, &current, 4);
            rolling.push(check.and_then(|c| {
                if !c.converged {
                    return None;
                }
                RollingShutterMeasure::sample(&previous, &current, &c.motion, along_x, 1.0, 1.0)
                    .map(|s| RollingShutterMeasure::scaled(&s, factor))
            }));
            previous = current;
        }
        let times = (0..n as i64).map(|i| Time::new(i, 30)).collect();
        let mut a = StabilizationAnalysis::new(1920, 1080, times, vec![CameraMotion::IDENTITY; n as usize]);
        a.rolling = rolling;
        a.rolling_scan = scan;
        a
    }

    #[test]
    fn a_plane_goes_through_its_points() {
        let p = [
            Vec2::new(-3.0, -2.0),
            Vec2::new(4.0, -2.0),
            Vec2::new(-3.0, 5.0),
            Vec2::new(4.0, 5.0),
            Vec2::new(0.0, 1.0),
        ];
        let v: Vec<f64> = p.iter().map(|q| 2.0 - 0.5 * q.x + 0.25 * q.y).collect();
        let c = RollingShutterMeasure::plane(&p, &v).expect("plane");
        assert!((c[0] - 2.0).abs() < 1e-9 && (c[1] + 0.5).abs() < 1e-9 && (c[2] - 0.25).abs() < 1e-9);
        assert!(
            RollingShutterMeasure::plane(&[Vec2::ZERO, Vec2::new(1.0, 1.0), Vec2::new(2.0, 2.0)], &[1.0, 2.0, 3.0])
                .is_none()
        );
    }

    #[test]
    fn a_pair_gives_shift_and_slope() {
        // Speeding up from 30 to 120 px/s between two frames at 20 ms readout: the last row runs ahead of the first one by
        // 0.02 * 90 = 1.8 px, on top of the shift.
        let shot = |t: f64, v: f64| {
            let mut px = vec![0.0_f32; 256 * 144];
            for y in 0..144 {
                for x in 0..256 {
                    let row = (y as f64 + 0.5 - 72.0) / 144.0;
                    px[y * 256 + x] = scene(x as f64 - (t + v * 0.02 * row), y as f64) as f32;
                }
            }
            GrayFrame::new(256, 144, px)
        };
        let (a, b) = (shot(0.0, 30.0), shot(2.5, 120.0));
        let check = PhotometricRegistration::register(&a, &b, 4).expect("register");
        let s = RollingShutterMeasure::sample(&a, &b, &check.motion, false, 1.0, 1.0).expect("sample");
        assert!((s.shift_x - 2.5).abs() < 0.1 && s.shift_y.abs() < 0.1, "shift {}, {}", s.shift_x, s.shift_y);
        assert!((s.slope_x - 1.8).abs() < 0.3 && s.slope_y.abs() < 0.3, "slope {}, {}", s.slope_x, s.slope_y);
    }

    /// Non-square pixels (anamorphic, pixel aspect 1.33): the analysis frame has the stored pixels, the picture is the
    /// displayed one (1920 x 1080 over 192 x 144: 10 across, 7.5 down). A camera that shifts and rolls about its axis is a
    /// similarity in the displayed picture only; the sample must report the shift per axis in source pixels and no slope (one
    /// factor for both axes gave shiftY 1.33 times too large and read the roll as a shear).
    #[test]
    fn non_square_pixels_are_measured_in_the_displayed_picture() {
        let (w, h, fx, fy, roll) = (192_usize, 144_usize, 10.0, 7.5, 0.012);
        let shot = |dx: f64, dy: f64, angle: f64| {
            let mut px = vec![0.0_f32; w * h];
            for y in 0..h {
                for x in 0..w {
                    // Displayed position of the texel about the center, rolled back, in stored pixels again.
                    let xx = (x as f64 - (w - 1) as f64 / 2.0) * fx;
                    let yy = (y as f64 - (h - 1) as f64 / 2.0) * fy;
                    let sx = (xx + angle * yy) / fx + (w - 1) as f64 / 2.0 - dx;
                    let sy = (yy - angle * xx) / fy + (h - 1) as f64 / 2.0 - dy;
                    px[y * w + x] = scene(sx, sy) as f32;
                }
            }
            GrayFrame::new(w, h, px)
        };
        let (a, b) = (shot(0.0, 0.0, 0.0), shot(2.0, 1.5, roll));
        let check = PhotometricRegistration::register(&a, &b, 4).expect("register");
        let s = RollingShutterMeasure::sample(&a, &b, &check.motion, false, fx, fy).expect("sample");
        assert!(
            (s.shift_x - 20.0).abs() < 1.0 && (s.shift_y - 11.25).abs() < 1.0,
            "shift {}, {}",
            s.shift_x,
            s.shift_y
        );
        assert!(s.slope_x.abs() < 2.5 && s.slope_y.abs() < 2.5, "slope {}, {}", s.slope_x, s.slope_y);
        // One factor for both axes, as before: the roll comes out as a shear of about 10 px.
        let one = RollingShutterMeasure::sample(&a, &b, &check.motion, false, 1.0, 1.0).expect("sample");
        assert!(RollingShutterMeasure::scaled(&one, fx).slope_x.abs() > 6.0);
        // Square pixels: both factors equal is the old scaling.
        let square = RollingShutterMeasure::sample(&a, &b, &check.motion, false, 7.5, 7.5).expect("sample");
        let scaled = RollingShutterMeasure::scaled(&one, 7.5);
        assert!((square.shift_x - scaled.shift_x).abs() < 1e-9 && (square.shift_y - scaled.shift_y).abs() < 1e-9);
        assert!((square.slope_x - scaled.slope_x).abs() < 1e-9 && (square.slope_y - scaled.slope_y).abs() < 1e-9);
    }

    #[test]
    fn the_readout_time_comes_back_out_of_the_frames() {
        for readout in [0.02, 0.01, -0.02, 0.0] {
            let camera = Camera::STANDARD;
            let a = analyze(90, readout, &camera, 0);
            let e = RollingShutter::estimate(&a);
            // What is left after the correction: the worst lean in source px over the picture height.
            let factor = 1920.0 / 256.0;
            let shears = RollingShutter::shears(&a, e.readout);
            let (mut left, mut was) = (0.0_f64, 0.0_f64);
            for (i, shear) in shears.iter().enumerate().take(88).skip(2) {
                let truth = camera.velocity_x(i as f64 / 30.0) * factor * readout;
                left = left.max((shear.x * 1080.0 - truth).abs());
                was = was.max(truth.abs());
            }
            assert!(e.measured, "readout {readout}: {e:?}");
            assert!(
                (e.readout - readout).abs() < 0.004_f64.max(readout.abs() * 0.25),
                "readout {readout}: {}",
                e.readout
            );
            if readout != 0.0 {
                assert!(left < was / 2.0, "readout {readout}: {left} of {was} px left");
            }
        }
    }

    #[test]
    fn sensor_rows_standing_upright_are_measured_along_x() {
        let a = analyze(90, 0.02, &Camera::STANDARD, 3);
        let e = RollingShutter::estimate(&a);
        assert!(e.measured && (e.readout - 0.02).abs() < 0.006, "{e:?}");
    }

    #[test]
    fn a_steady_pan_takes_the_typical_readout() {
        let a = analyze(40, 0.02, &Camera { pan: 40.0, sway: 0.0, bob: 0.0 }, 0);
        let e = RollingShutter::estimate(&a);
        assert!(!e.measured && e.readout == RollingShutter::TYPICAL_READOUT, "{e:?}");
        // The shear still follows the pan: 300 px/s * 16 ms.
        let s = RollingShutter::shears(&a, e.readout);
        assert!((s[20].x * 1080.0 - 4.8).abs() < 0.3);
    }
}
