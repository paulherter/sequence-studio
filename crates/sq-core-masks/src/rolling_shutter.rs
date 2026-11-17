// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RollingShutter.swift (`ClipEffect.rollingShutterFilter` returns an effects-crate `ImageFilter` and waits there,
// see NOTES.md)
//! Rolling shutter correction without gyro data: an option of the Standard Stabilizer.
//!
//! A rolling sensor reads its rows one after the other: the row at scan position v (-0.5 = first row read ... +0.5 = last,
//! 0 = the picture center) is exposed `readout * v` later than the center row. While the picture moves with velocity `vel`
//! (px/s) that row is displaced by `vel * readout * v`: a pan leans verticals, a tilt stretches or squeezes the picture.
//!   shown(p) = ideal(p) + shear * v(p),   shear = vel * readout   (px across the whole scan extent)
//! A constant velocity shears every frame alike, so two frames show no difference; only a change of velocity does: between
//! frame i-1 and i the measured shift grows along the scan axis by slope_i = readout * (vel_i - vel_i-1). The analysis
//! stores shift and slope per frame pair; the readout time is the least-squares fit of slope against the velocity change
//! over the whole shot, and each frame's shear follows from it. The effect stores the shear per clip frame (fraction of the
//! scan extent, decimated keys like the stage keys).

use crate::stabilizer::{FramePick, StabilizationAnalysis, pick_frame};
use sq_core_time::{Time, Vec2};
use std::collections::BTreeSet;

/// What the analysis measured between two analyzed frames, source px.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RollingShutterSample {
    /// Picture shift previous -> current at the picture center (x).
    pub shift_x: f64,
    /// Picture shift previous -> current at the picture center (y).
    pub shift_y: f64,
    /// Extra shift of the last scan row against the first one (rotation and zoom taken out), x.
    pub slope_x: f64,
    /// Extra shift of the last scan row against the first one, y.
    pub slope_y: f64,
}

/// The readout time of a shot, seconds from the first to the last row along the positive scan axis of the upright picture
/// (negative: the sensor reads the other way round, as in footage stored upside down).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReadoutEstimate {
    /// Seconds.
    pub readout: f64,
    /// False: the shot did not let it be measured (`readout` is then the typical value).
    pub measured: bool,
    /// Observations the fit used.
    pub observations: usize,
    /// Standard error of the fit, seconds.
    pub error: f64,
}

/// Rolling shutter estimation.
pub struct RollingShutter;

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale().max(1) as f64
}

impl RollingShutter {
    /// Readout assumed when a shot cannot be measured: 16 ms (phones and mirrorless cameras read 4K in 8-30 ms), at most
    /// 60 % of the source's frame interval (60 fps: 10 ms, 120 fps: 5 ms).
    pub const TYPICAL_READOUT: f64 = 0.016;
    /// A fit counts as measured from this many observations ...
    pub const MIN_OBSERVATIONS: usize = 12;
    /// ... and below this standard error (seconds).
    pub const MAX_ERROR: f64 = 0.004;
    /// ... and only when the velocity changes by at least this much from frame to frame (RMS, source px/s).
    pub const MIN_VELOCITY_CHANGE: f64 = 5.0;

    /// Picture velocity (source px/s) over each frame pair: `[i]` is frame i-1 -> i; `None` where it was not measured, at
    /// index 0 and across a cut.
    pub(crate) fn pair_velocities(a: &StabilizationAnalysis) -> Vec<Option<Vec2>> {
        let n = a.frame_times.len().min(a.rolling.len());
        let mut out = vec![None; n];
        let cuts: BTreeSet<usize> = a.cuts.iter().copied().collect();
        for (i, slot) in out.iter_mut().enumerate().skip(1) {
            if cuts.contains(&i) {
                continue;
            }
            let Some(s) = a.rolling[i] else { continue };
            let dt = seconds(a.frame_times[i] - a.frame_times[i - 1]);
            if !(dt > 0.0 && s.shift_x.is_finite() && s.shift_y.is_finite()) {
                continue;
            }
            *slot = Some(Vec2::new(s.shift_x / dt, s.shift_y / dt));
        }
        out
    }

    /// Median interval between analyzed frames, seconds (0 when there are fewer than two).
    pub(crate) fn frame_interval(a: &StabilizationAnalysis) -> f64 {
        let mut d: Vec<f64> = a.frame_times.windows(2).map(|w| seconds(w[1] - w[0])).filter(|x| *x > 0.0).collect();
        d.sort_by(f64::total_cmp);
        if d.is_empty() { 0.0 } else { d[d.len() / 2] }
    }

    /// The longest a sensor can take to read one frame: the source's own frame interval. The analyzed frames are coarser
    /// on a high frame rate (the analyzer skips frames closer than 24 ms), so their interval only stands in when the
    /// source's is not known; 1/24 s when there is neither.
    pub(crate) fn readout_cap(a: &StabilizationAnalysis) -> f64 {
        let analyzed = Self::frame_interval(a);
        if a.source_frame_interval > 0.0 {
            return if analyzed > 0.0 { a.source_frame_interval.min(analyzed) } else { a.source_frame_interval };
        }
        if analyzed > 0.0 { analyzed } else { 1.0 / 24.0 }
    }

    /// The shot's readout time: least squares of the measured slopes against the velocity changes, both axes pooled,
    /// observations far off the fit dropped once. Falls back to `TYPICAL_READOUT` (signed by the scan direction) when the
    /// camera's speed never changes enough to tell.
    pub fn estimate(a: &StabilizationAnalysis) -> ReadoutEstimate {
        let vel = Self::pair_velocities(a);
        let n = vel.len();
        let mut obs: Vec<(f64, f64)> = Vec::new(); // (slope, velocity change)
        let mut i = 2;
        while i + 1 < n {
            if let (Some(before), Some(_), Some(after), Some(s)) = (vel[i - 1], vel[i], vel[i + 1], a.rolling[i])
                && s.slope_x.is_finite()
                && s.slope_y.is_finite()
            {
                // vel at frame i minus vel at frame i-1, each the mean of the two pairs around it.
                obs.push((s.slope_x, (after.x - before.x) / 2.0));
                obs.push((s.slope_y, (after.y - before.y) / 2.0));
            }
            i += 1;
        }
        let fit = |o: &[(f64, f64)]| -> Option<(f64, f64)> {
            let den = o.iter().fold(0.0, |s, v| s + v.1 * v.1);
            if !(o.len() >= 2 && den > 0.0) {
                return None;
            }
            let t = o.iter().fold(0.0, |s, v| s + v.0 * v.1) / den;
            let rss = o.iter().fold(0.0, |s, v| s + (v.0 - t * v.1) * (v.0 - t * v.1));
            Some((t, (rss / (o.len() - 1) as f64 / den).sqrt()))
        };
        let mut result = fit(&obs);
        if let Some(first) = result
            && obs.len() >= Self::MIN_OBSERVATIONS
        {
            let res: Vec<f64> = obs.iter().map(|o| (o.0 - first.0 * o.1).abs()).collect();
            let mut sorted = res.clone();
            sorted.sort_by(f64::total_cmp);
            let limit = 3.0 * sorted[sorted.len() / 2] + 1e-9;
            let kept: Vec<(f64, f64)> = obs.iter().zip(&res).filter(|(_, r)| **r <= limit).map(|(o, _)| *o).collect();
            if kept.len() >= Self::MIN_OBSERVATIONS
                && let Some(again) = fit(&kept)
            {
                result = Some(again);
                obs = kept;
            }
        }
        let cap = Self::readout_cap(a);
        // A camera whose speed never changes shows no slope at all, whatever its sensor: that is not a measurement.
        let change =
            if obs.is_empty() { 0.0 } else { (obs.iter().fold(0.0, |s, o| s + o.1 * o.1) / obs.len() as f64).sqrt() };
        if let Some(r) = result
            && obs.len() >= Self::MIN_OBSERVATIONS
            && change >= Self::MIN_VELOCITY_CHANGE
            && r.0.is_finite()
            && r.1.is_finite()
            && r.1 <= Self::MAX_ERROR
        {
            return ReadoutEstimate {
                readout: r.0.max(-cap).min(cap),
                measured: true,
                observations: obs.len(),
                error: r.1,
            };
        }
        // Scan direction of the upright picture: 1 and 2 read against the axis.
        let sign = if a.rolling_scan == 1 || a.rolling_scan == 2 { -1.0 } else { 1.0 };
        ReadoutEstimate {
            readout: sign * Self::TYPICAL_READOUT.min(0.6 * cap),
            measured: false,
            observations: obs.len(),
            error: result.map_or(f64::INFINITY, |r| r.1),
        }
    }

    /// The shear of every analyzed frame as a fraction of the scan extent (picture height, or width when the sensor rows
    /// stand upright): `readout` times the frame's velocity, the mean of the two pairs around it inside a shot.
    pub fn shears(a: &StabilizationAnalysis, readout: f64) -> Vec<Vec2> {
        let vel = Self::pair_velocities(a);
        let n = a.frame_times.len();
        let extent = if a.rolling_scans_along_x() { a.picture_width as f64 } else { a.picture_height as f64 };
        if !(extent > 0.0 && readout.is_finite()) {
            return vec![Vec2::ZERO; n];
        }
        (0..n)
            .map(|i| {
                let into = vel.get(i).copied().flatten(); // pair i-1 -> i
                let out = vel.get(i + 1).copied().flatten(); // pair i -> i+1 (None across a cut)
                let v = match (into, out) {
                    (Some(p), Some(q)) => Vec2::new((p.x + q.x) / 2.0, (p.y + q.y) / 2.0),
                    (Some(p), None) => p,
                    (None, Some(q)) => q,
                    (None, None) => Vec2::ZERO,
                };
                Vec2::new(v.x * readout / extent, v.y * readout / extent)
            })
            .collect()
    }

    /// The shear at source time `t`: linear between analyzed frames, held before the first, after the last and up to a cut.
    pub fn shear(shears: &[Vec2], a: &StabilizationAnalysis, t: Time) -> Vec2 {
        let n = shears.len().min(a.frame_times.len());
        match pick_frame(&a.frame_times, n, &a.cuts, t) {
            FramePick::Empty => Vec2::ZERO,
            FramePick::Held(i) => shears[i],
            FramePick::Between(i, f) => shears[i] + (shears[i + 1] - shears[i]) * f,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stabilizer::{CameraMotion, StabilizerOptions};

    fn fd30() -> Time {
        Time::new(1, 30)
    }

    struct Rig {
        frames: usize,
        readout: f64,
        pan: f64,
        sway: f64,
        bob: f64,
        noise: f64,
        scan: i64,
        cuts: Vec<usize>,
        every: Time,
        source_interval: f64,
    }

    fn rig(readout: f64) -> Rig {
        Rig {
            frames: 120,
            readout,
            pan: 300.0,
            sway: 40.0,
            bob: 15.0,
            noise: 0.0,
            scan: 0,
            cuts: vec![],
            every: fd30(),
            source_interval: 0.0,
        }
    }

    /// A hand-held pan: x(t) = pan * t + sway * sin(2 pi f t), y(t) = bob * sin(2 pi g t); slopes as a sensor with `readout`
    /// would give them, plus `noise` px on every slope.
    fn analysis(r: &Rig) -> StabilizationAnalysis {
        let dt = r.every.value() as f64 / r.every.timescale() as f64;
        let tau = 2.0 * std::f64::consts::PI;
        let pos = |t: f64| Vec2::new(r.pan * t + r.sway * (tau * 1.3 * t).sin(), r.bob * (tau * 2.1 * t).sin());
        let vel = |t: f64| {
            Vec2::new(r.pan + r.sway * tau * 1.3 * (tau * 1.3 * t).cos(), r.bob * tau * 2.1 * (tau * 2.1 * t).cos())
        };
        let mut seed: u64 = 7;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as f64 / (1u64 << 31) as f64 * 2.0 - 1.0
        };
        let mut rolling = vec![None];
        for i in 1..r.frames {
            let (t0, t1) = ((i - 1) as f64 * dt, i as f64 * dt);
            let d = pos(t1) - pos(t0);
            let dv = vel(t1) - vel(t0);
            rolling.push(Some(RollingShutterSample {
                shift_x: d.x,
                shift_y: d.y,
                slope_x: r.readout * dv.x + r.noise * rnd(),
                slope_y: r.readout * dv.y + r.noise * rnd(),
            }));
        }
        let mut a = StabilizationAnalysis::new(
            1920,
            1080,
            (0..r.frames).map(|i| r.every * i as i64).collect(),
            vec![CameraMotion::IDENTITY; r.frames],
        )
        .with_rolling_scan(r.scan)
        .with_source_frame_interval(r.source_interval);
        a.cuts = r.cuts.clone();
        a.rolling = rolling;
        a
    }

    #[test]
    fn the_readout_time_comes_out_of_the_slopes() {
        for readout in [0.008, 0.02, -0.02, 0.03] {
            let e = RollingShutter::estimate(&analysis(&Rig { noise: 0.3, ..rig(readout) }));
            assert!(e.measured);
            assert!((e.readout - readout).abs() < 0.002, "readout {readout}: {} +- {}", e.readout, e.error);
        }
        let global = RollingShutter::estimate(&analysis(&Rig { noise: 0.3, ..rig(0.0) }));
        assert!(global.measured && global.readout.abs() < 0.002);
    }

    #[test]
    fn a_steady_pan_cannot_be_measured_and_takes_the_typical_readout() {
        let steady = |scan, noise| Rig { sway: 0.0, bob: 0.0, scan, noise, ..rig(0.02) };
        let e = RollingShutter::estimate(&analysis(&steady(0, 0.3)));
        assert!(!e.measured);
        assert_eq!(e.readout, RollingShutter::TYPICAL_READOUT);
        assert_eq!(RollingShutter::estimate(&analysis(&steady(2, 0.0))).readout, -RollingShutter::TYPICAL_READOUT);
        assert_eq!(RollingShutter::estimate(&analysis(&steady(1, 0.0))).readout, -RollingShutter::TYPICAL_READOUT);
        assert_eq!(RollingShutter::estimate(&analysis(&steady(3, 0.0))).readout, RollingShutter::TYPICAL_READOUT);
        let none = StabilizationAnalysis::new(1920, 1080, vec![Time::ZERO, fd30()], vec![CameraMotion::IDENTITY; 2]);
        assert!(!RollingShutter::estimate(&none).measured);
        let wild = RollingShutter::estimate(&analysis(&rig(0.2)));
        assert!(wild.measured && (wild.readout - 1.0 / 30.0).abs() < 1e-9);
    }

    /// The analyzer skips frames closer than 24 ms: a 60 fps source is analyzed every second frame, a 120 fps one every
    /// third. A sensor still cannot read longer than one source frame lasts, so the cap and the fallback follow the
    /// source's interval, not the analyzed one.
    #[test]
    fn the_cap_follows_the_source_frame_rate_not_the_analyzed_one() {
        for (fps, every, fallback) in [(60.0, Time::new(2, 60), 0.010), (120.0, Time::new(3, 120), 0.005)] {
            let base = Rig { every, source_interval: 1.0 / fps, ..rig(0.02) };
            let steady = RollingShutter::estimate(&analysis(&Rig {
                sway: 0.0,
                bob: 0.0,
                noise: 0.3,
                every,
                source_interval: 1.0 / fps,
                ..rig(0.02)
            }));
            assert!(!steady.measured);
            assert!((steady.readout - fallback).abs() < 1e-12, "{fps} fps: fallback {}", steady.readout);
            let against = RollingShutter::estimate(&analysis(&Rig {
                sway: 0.0,
                bob: 0.0,
                scan: 2,
                every,
                source_interval: 1.0 / fps,
                ..rig(0.02)
            }));
            assert!((against.readout + fallback).abs() < 1e-12);
            for sign in [1.0, -1.0] {
                let wild =
                    RollingShutter::estimate(&analysis(&Rig { every, source_interval: 1.0 / fps, ..rig(sign * 0.03) }));
                assert!(
                    wild.measured && (wild.readout - sign / fps).abs() < 1e-12,
                    "{fps} fps: measured {}",
                    wild.readout
                );
            }
            let fine = RollingShutter::estimate(&analysis(&Rig {
                noise: 0.05,
                every,
                source_interval: 1.0 / fps,
                ..rig(0.004)
            }));
            assert!(fine.measured && (fine.readout - 0.004).abs() < 0.001, "{fps} fps: {}", fine.readout);
            assert_eq!(RollingShutter::readout_cap(&analysis(&base)), 1.0 / fps);
        }
        assert_eq!(RollingShutter::readout_cap(&analysis(&Rig { every: Time::new(2, 60), ..rig(0.02) })), 1.0 / 30.0);
    }

    /// Rolling Shutter Strength scales the stored shear when the frame is drawn: changing it needs no new plan.
    #[test]
    fn strength_alone_needs_no_new_plan() {
        let mut a = StabilizerOptions { rolling_shutter: true, ..StabilizerOptions::default() };
        let mut b = a;
        b.rolling_shutter_strength = 40.0;
        assert!(a != b && a.same_plan_as(&b));
        b.rolling_shutter = false;
        assert!(!a.same_plan_as(&b));
        b.rolling_shutter = true;
        b.smoothness = 1.0;
        a.rolling_shutter = true;
        assert!(!a.same_plan_as(&b));
    }

    #[test]
    fn the_shear_is_readout_times_velocity() {
        // 300 px/s at 20 ms readout: verticals lean 6 px over the 1080 rows.
        let a = analysis(&Rig { sway: 0.0, bob: 0.0, ..rig(0.02) });
        let s = RollingShutter::shears(&a, 0.02);
        assert_eq!(s.len(), 120);
        for v in &s {
            assert!((v.x * 1080.0 - 6.0).abs() < 1e-6 && v.y.abs() < 1e-9);
        }
        // Rows upright: the same shift counts against the width.
        let turned = RollingShutter::shears(&analysis(&Rig { sway: 0.0, bob: 0.0, scan: 3, ..rig(0.02) }), 0.02);
        assert!((turned[10].x * 1920.0 - 6.0).abs() < 1e-6);
        // Between two analyzed frames the shear is interpolated; outside it is held; a cut is not crossed.
        let swaying = analysis(&Rig { cuts: vec![50], ..rig(0.02) });
        let sh = RollingShutter::shears(&swaying, 0.02);
        let mid = RollingShutter::shear(&sh, &swaying, Time::new(21, 60));
        assert!((mid.x - (sh[10].x + sh[11].x) / 2.0).abs() < 1e-12);
        assert_eq!(RollingShutter::shear(&sh, &swaying, Time::new(-1, 1)), sh[0]);
        assert_eq!(RollingShutter::shear(&sh, &swaying, Time::new(100, 1)), sh[119]);
        assert_eq!(RollingShutter::shear(&sh, &swaying, Time::new(99, 60)), sh[49]);
        // Frame 49 ends its shot: only the pair into it counts (the pair across the cut is another picture).
        let pair = swaying.rolling[49].unwrap_or(RollingShutterSample {
            shift_x: 0.0,
            shift_y: 0.0,
            slope_x: 0.0,
            slope_y: 0.0,
        });
        assert!((sh[49].x - pair.shift_x * 30.0 * 0.02 / 1080.0).abs() < 1e-12);
    }
}
