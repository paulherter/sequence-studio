// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: StabilizerTests, StabilizerQuadraticTests (with StabilizerL1Tests), StabilizerPerspectiveTests and
// StabilizerEdgeFillTests, the parts that need no effect rendering.
//! Stabilizer plan tests on synthetic hand-held analyses.

use crate::stabilization_cuts::StabilizationCuts;
use crate::stabilizer::*;
use crate::stabilizer_perspective::PerspectiveResidual;
use crate::test_util::Lcg;
use sq_core_model::Affine2;
use sq_core_model::StageTransform;
use sq_core_time::{SequentialIds, Time, Vec2};

fn fd30() -> Time {
    Time::new(1, 30)
}

fn times(n: usize) -> Vec<Time> {
    (0..n).map(|i| fd30() * i as i64).collect()
}

/// The map of a stage: p -> R s (p - anchor) + anchor + position.
fn stage_affine(s: &StageTransform) -> Affine2 {
    let mut m = Affine2::rot_scale(s.rotation, s.scale, s.scale_y());
    m.t = s.anchor + s.position - m.linear(s.anchor);
    m
}

fn analysis_from_poses(poses: &[CameraPose], width: i64, height: i64) -> StabilizationAnalysis {
    let mut motions = vec![CameraMotion::IDENTITY];
    for k in 1..poses.len() {
        motions.push(CameraMotion::from_poses(&poses[k - 1], &poses[k]));
    }
    StabilizationAnalysis::new(width, height, times(poses.len()), motions)
}

/// A hand-held clip: per-frame camera poses = optional slow pan + jitter (px, degrees), as inter-frame motions.
fn analysis(n: usize, pan: f64, jitter: f64, rot_jitter: f64, scale_jitter: f64, seed: u64) -> StabilizationAnalysis {
    let mut r = Lcg(seed);
    let poses: Vec<CameraPose> = (0..n)
        .map(|k| {
            let x = pan * k as f64 + jitter * r.symmetric();
            let y = jitter * r.symmetric();
            CameraPose::new(Vec2::new(x, y), rot_jitter * r.symmetric(), scale_jitter * r.symmetric())
        })
        .collect();
    analysis_from_poses(&poses, 1920, 1080)
}

fn standard(pan: f64, jitter: f64, rot: f64) -> StabilizationAnalysis {
    analysis(300, pan, jitter, rot, 0.0, 7)
}

/// Where a world point sits in each frame after the stage (what the viewer sees, before Motion).
fn rendered(a: &StabilizationAnalysis, plan: &StabilizationPlan) -> Vec<Vec2> {
    let w = Vec2::new(100.0, -50.0);
    let path = Stabilizer::path(&a.motions);
    (0..path.len()).map(|k| stage_affine(&plan.corrections[k]).apply(path[k].apply(w))).collect()
}

fn raw(a: &StabilizationAnalysis) -> Vec<Vec2> {
    let w = Vec2::new(100.0, -50.0);
    Stabilizer::path(&a.motions).iter().map(|p| p.apply(w)).collect()
}

fn plan_of(a: &StabilizationAnalysis, o: &StabilizerOptions) -> StabilizationPlan {
    Stabilizer::plan(a, o).unwrap_or_else(|| panic!("no plan"))
}

#[test]
fn motions_compose_into_the_path() {
    let p0 = CameraPose::new(Vec2::new(3.0, -2.0), 1.5, 0.01);
    let p1 = CameraPose::new(Vec2::new(-4.0, 7.0), -0.5, -0.02);
    let m = CameraMotion::from_poses(&p0, &p1);
    let path = Stabilizer::path(&[CameraMotion::from_poses(&CameraPose::IDENTITY, &p0), m]);
    let w = Vec2::new(250.0, -120.0);
    assert!((path[1].apply(w) - p1.apply(w)).length() < 1e-9);
    assert!((path[0].apply(w) - p0.apply(w)).length() < 1e-9);
}

#[test]
fn gaussian_keeps_straight_lines_and_ends() {
    let line: Vec<f64> = (0..50).map(|i| 3.0 + 2.0 * f64::from(i)).collect();
    let s = Stabilizer::gaussian_smooth(&line, 6.0);
    for (a, b) in line.iter().zip(&s) {
        assert!((a - b).abs() < 1e-9);
    }
}

#[test]
fn smooth_mode_removes_jitter_with_less_than_ten_percent_crop() {
    let a = standard(2.0, 6.0, 0.3);
    let plan = plan_of(&a, &StabilizerOptions::default());
    let (before, after) = (Stabilizer::jitter(&raw(&a)), Stabilizer::jitter(&rendered(&a, &plan)));
    assert!(after < before * 0.2, "jitter {before} -> {after}");
    assert!(plan.crop() < 0.10, "crop {}", plan.crop());
    assert!(plan.crop() > 0.0);
    assert!(plan.fully_covered);
    // The pan survives: the rendered picture still moves ~2 px per frame on average.
    let r = rendered(&a, &plan);
    let drift = (r[r.len() - 1] - r[0]).x / (r.len() - 1) as f64;
    assert!((drift - 2.0 * plan.zoom).abs() < 0.3, "drift {drift}");
}

#[test]
fn smooth_mode_keeps_crop_under_the_limit_for_strong_shake() {
    let a = standard(0.0, 60.0, 2.0);
    let o = StabilizerOptions { max_crop: 0.08, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    assert!(plan.crop() <= 0.08 + 1e-6, "crop {}", plan.crop());
    assert!(plan.fully_covered);
    assert!(Stabilizer::jitter(&rendered(&a, &plan)) < Stabilizer::jitter(&raw(&a)) * 0.6);
}

#[test]
fn every_frame_stays_covered() {
    let a = analysis(300, 1.0, 15.0, 1.0, 0.01, 7);
    let plan = plan_of(&a, &StabilizerOptions::default());
    let (hw, hh) = (a.picture_width as f64 / 2.0, a.picture_height as f64 / 2.0);
    for c in &plan.corrections {
        let m = stage_affine(c);
        let det = m.a * m.d - m.b * m.c;
        for q in [Vec2::new(-hw, -hh), Vec2::new(hw, -hh), Vec2::new(hw, hh), Vec2::new(-hw, hh)] {
            let d = q - m.t;
            let src = Vec2::new((m.d * d.x - m.b * d.y) / det, (-m.c * d.x + m.a * d.y) / det);
            assert!(src.x.abs() <= hw + 1e-6 && src.y.abs() <= hh + 1e-6);
        }
    }
}

#[test]
fn locked_mode_holds_the_shot_still() {
    let a = standard(0.0, 8.0, 0.4);
    let o = StabilizerOptions { mode: StabilizerMode::Locked, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    let r = rendered(&a, &plan);
    let max_dev = r.iter().map(|p| (*p - r[0]).length()).fold(0.0, f64::max);
    assert!(max_dev < 1e-6, "locked moved {max_dev} px");
    assert!(plan.fully_covered);
    assert!(plan.crop() < 0.10);
}

#[test]
fn locked_mode_caps_the_zoom_on_a_pan() {
    let a = standard(10.0, 2.0, 0.3); // 3000 px of pan: cannot be held
    let o = StabilizerOptions { mode: StabilizerMode::Locked, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    assert!(plan.fully_covered); // the lock gives way locally instead of leaving the frame edge short
    assert!(plan.crop() <= o.max_locked_crop + 1e-9);
}

#[test]
fn still_shot_needs_no_correction() {
    let a = standard(0.0, 0.0, 0.0);
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.zoom, 1.0);
    assert!(
        plan.corrections
            .iter()
            .all(|c| c.is_identity() || (c.position.length() < 1e-9 && (c.scale - 1.0).abs() < 1e-9))
    );
}

#[test]
fn too_few_frames_has_no_plan() {
    assert!(Stabilizer::plan(&analysis(1, 0.0, 6.0, 0.3, 0.0, 7), &StabilizerOptions::default()).is_none());
}

#[test]
fn nearest_frame_index() {
    let a = analysis(10, 0.0, 6.0, 0.3, 0.0, 7);
    assert_eq!(a.index_nearest(Time::new(-1, 1)), 0);
    assert_eq!(a.index_nearest(fd30() * 3), 3);
    assert_eq!(a.index_nearest(Time::new(7, 60)), 4); // 3.5 frames rounds up
    assert_eq!(a.index_nearest(Time::new(100, 1)), 9);
}

#[test]
fn scene_cuts_are_smoothed_separately() {
    let mut a = analysis(200, 0.0, 0.0, 0.0, 0.0, 7);
    a.motions[100] = CameraMotion::new(400.0, 0.0, 0.0, 1.0);
    let blind = plan_of(&a, &StabilizerOptions::default());
    a.cuts = vec![100];
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert!(plan.fully_covered && plan.zoom == 1.0);
    assert!(plan.corrections.iter().all(|c| *c == StageTransform::IDENTITY));
    assert!(blind.fully_covered); // the bilateral smoothing follows a jump instead of averaging across it
    let locked = StabilizerOptions { mode: StabilizerMode::Locked, ..StabilizerOptions::default() };
    let l = plan_of(&a, &locked);
    assert!(l.fully_covered && l.zoom == 1.0);
}

#[test]
fn each_segment_of_a_cut_shot_is_steadied_on_its_own() {
    let mut a = analysis(200, 0.0, 6.0, 0.2, 0.0, 7);
    a.motions[100] = CameraMotion::IDENTITY;
    a.cuts = vec![100];
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.corrections.len(), 200);
    let mut seg_a = a.clone();
    seg_a.motions = a.motions[0..100].to_vec();
    seg_a.frame_times = a.frame_times[0..100].to_vec();
    let mut seg_b = a.clone();
    seg_b.motions = a.motions[100..200].to_vec();
    seg_b.motions[0] = CameraMotion::IDENTITY;
    seg_b.frame_times = a.frame_times[100..200].to_vec();
    let r = rendered(&a, &plan);
    let path_b = Stabilizer::path(&seg_b.motions);
    let rendered_b: Vec<Vec2> = (0..100)
        .map(|k| stage_affine(&plan.corrections[100 + k]).apply(path_b[k].apply(Vec2::new(100.0, -50.0))))
        .collect();
    assert!(Stabilizer::jitter(&r[0..100]) < Stabilizer::jitter(&raw(&seg_a)) * 0.5);
    assert!(Stabilizer::jitter(&rendered_b) < Stabilizer::jitter(&raw(&seg_b)) * 0.5);
}

#[test]
fn decimation_keeps_every_value_within_tolerance() {
    let times: Vec<f64> = (0..200).map(f64::from).collect();
    let vals: Vec<f64> = times.iter().map(|t| (t / 9.0).sin() * 5.0 + t * 0.1).collect();
    let kept = Stabilizer::decimate(&times, &vals, 0.05);
    assert!(kept[0] == 0 && kept[kept.len() - 1] == 199);
    assert!(kept.len() < 100);
    for i in 0..times.len() {
        let j = kept.iter().rposition(|k| *k <= i).unwrap_or(0);
        let (a, b) = (kept[j], kept[(j + 1).min(kept.len() - 1)]);
        let f = if b > a { (times[i] - times[a]) / (times[b] - times[a]) } else { 0.0 };
        assert!((vals[a] + (vals[b] - vals[a]) * f - vals[i]).abs() <= 0.05 + 1e-12);
    }
    assert_eq!(Stabilizer::decimate(&[0.0, 1.0, 2.0, 3.0], &[1.0; 4], 0.05), vec![0, 3]);
}

#[test]
fn a_track_collapses_to_a_constant_only_within_tolerance() {
    let mut ids = SequentialIds::default();
    let wobble = Stabilizer::decimated_property(&[0.0, 0.15, 0.1], fd30(), 0.1, &mut ids);
    assert!(wobble.track.keys.len() >= 2);
    for (i, v) in [0.0, 0.15, 0.1].iter().enumerate() {
        assert!((wobble.value_at_local(fd30() * i as i64) - v).abs() <= 0.1 + 1e-12);
    }
    let flat = Stabilizer::decimated_property(&[0.02, -0.05, 0.08, 0.01], fd30(), 0.1, &mut ids);
    assert!(flat.track.is_empty() && flat.value == 0.02);
}

// Quadratic path smoothing (StabilizerQuadraticTests).

fn shaky(n: usize, pan: f64, jitter: f64, rot: f64, seed: u64) -> StabilizationAnalysis {
    let mut r = Lcg(seed);
    let poses: Vec<CameraPose> = (0..n)
        .map(|k| {
            let x = pan * k as f64 + jitter * r.symmetric();
            let y = jitter * r.symmetric();
            CameraPose::new(Vec2::new(x, y), rot * r.symmetric(), 0.0)
        })
        .collect();
    analysis_from_poses(&poses, 1920, 1080)
}

fn steadied(a: &StabilizationAnalysis, plan: &StabilizationPlan) -> (f64, f64) {
    let path = Stabilizer::path(&a.motions);
    let w = Vec2::new(100.0, -50.0);
    let before: Vec<Vec2> = path.iter().map(|p| p.apply(w)).collect();
    let after: Vec<Vec2> =
        (0..path.len()).map(|i| stage_affine(&plan.corrections[i]).apply(path[i].apply(w))).collect();
    (Stabilizer::jitter(&before), Stabilizer::jitter(&after))
}

#[test]
fn banded_solve_matches_the_normal_equations() {
    let p = [0.0, 3.0, -1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0];
    let lambda = [2.0, 0.5, 3.0, 1.0, 4.0, 0.2, 7.0];
    let s = Stabilizer::solve_second_difference(&p, &lambda, None);
    // (I + D^T L D) s - p must vanish.
    for i in 0..p.len() {
        let mut v = s[i];
        for r in i.saturating_sub(2)..=i.min(p.len() - 3) {
            let c: f64 = if i == r + 1 { -2.0 } else { 1.0 };
            let ds = s[r] - 2.0 * s[r + 1] + s[r + 2];
            v += c * lambda[r] * ds;
        }
        assert!((v - p[i]).abs() < 1e-9);
    }
}

#[test]
fn a_straight_line_stays_and_jitter_goes() {
    let line: Vec<f64> = (0..100).map(|i| f64::from(i) * 3.0 + 7.0).collect();
    let l = Stabilizer::base_lambda(10.0);
    let s = Stabilizer::solve_second_difference(&line, &vec![l; 98], None);
    for i in 0..line.len() {
        assert!((s[i] - line[i]).abs() < 1e-6);
    }
}

#[test]
fn residual_shake_is_below_thirty_percent() {
    for pan in [0.0, 1.5] {
        let a = shaky(240, pan, 8.0, 0.4, 5);
        let plan = plan_of(&a, &StabilizerOptions::default());
        let r = steadied(&a, &plan);
        assert!(r.1 < r.0 * 0.3, "pan {pan}: {} vs {}", r.1, r.0);
    }
}

#[test]
fn tripod_holds_and_auto_picks_it_for_a_still_shot() {
    let a = shaky(240, 0.0, 6.0, 0.2, 5);
    let mut o = StabilizerOptions { mode: StabilizerMode::Locked, ..StabilizerOptions::default() };
    let tripod = plan_of(&a, &o);
    let t = steadied(&a, &tripod);
    assert!(t.1 < t.0 * 0.05);
    o.mode = StabilizerMode::Auto;
    let auto = plan_of(&a, &o);
    assert_eq!(auto.corrections, tripod.corrections);
    let pan = shaky(240, 1.5, 8.0, 0.4, 5);
    let pan_auto = plan_of(&pan, &o);
    let s = StabilizerOptions { mode: StabilizerMode::Smooth, ..StabilizerOptions::default() };
    assert_eq!(pan_auto.corrections, plan_of(&pan, &s).corrections);
}

#[test]
fn strength_blends_toward_no_correction() {
    let a = shaky(240, 0.0, 8.0, 0.4, 5);
    let mut o = StabilizerOptions::default();
    let full = steadied(&a, &plan_of(&a, &o));
    o.strength = 0.5;
    let half = steadied(&a, &plan_of(&a, &o));
    o.strength = 0.0;
    let none = steadied(&a, &plan_of(&a, &o));
    assert!(full.1 < half.1 && half.1 < none.1);
    assert!((none.1 - none.0).abs() < none.0 * 0.05);
}

#[test]
fn parameters_replan_from_the_same_analysis() {
    // The plan is a pure function of the stored analysis: Strength / Smoothness / Crop Limit never need a new analysis.
    let a = shaky(240, 0.0, 8.0, 0.4, 5);
    let copy = a.clone();
    let mut o = StabilizerOptions::default();
    Stabilizer::plan(&a, &o);
    o.strength = 0.4;
    o.smoothness = 1.2;
    o.max_crop = 0.15;
    Stabilizer::plan(&a, &o);
    assert_eq!(a, copy);
    const _: () = assert!(StabilizationAnalysis::CURRENT_VERSION >= 6);
}

#[test]
fn crop_limit_holds_where_smoothing_would_over_cut() {
    let a = shaky(300, 0.5, 40.0, 2.0, 5);
    let o = StabilizerOptions { max_crop: 0.08, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    assert!(plan.zoom <= 1.0 / (1.0 - o.max_crop) + 1e-6);
}

#[test]
fn l1_path_needs_less_zoom_than_the_quadratic_path_at_no_more_jitter() {
    let mut r = Lcg(11);
    // Hand-held walk: slow sway of 150 px plus 35 px of shake.
    let real: Vec<CameraPose> = (0..300)
        .map(|k| {
            let t = f64::from(k);
            let x = 150.0 * (t / 25.0).sin() + 35.0 * r.symmetric();
            let y = 100.0 * (t / 31.0).sin() + 35.0 * r.symmetric();
            CameraPose::new(Vec2::new(x, y), 3.0 * (t / 40.0).sin() + 1.0 * r.symmetric(), 0.0)
        })
        .collect();
    let (hw, hh, cap) = (960.0, 540.0, 1.06); // a tight crop limit: the quadratic path has to give way and gets jittery
    let correction = |w: &CameraPose, k: usize| w.after(&real[k].inverse());
    let zoom = |p: &[CameraPose]| -> Option<f64> {
        let mut z = 1.0_f64;
        for (k, pose) in p.iter().enumerate() {
            z = z.max(Stabilizer::required_zoom(&correction(pose, k), hw, hh, cap)?);
        }
        Some(z)
    };
    let quad = Stabilizer::adaptive_quadratic_path(&real, 10.0, 40, &|p, k| {
        Stabilizer::required_zoom(&correction(p, k), hw, hh, cap).is_some()
    });
    let l1 = Stabilizer::l1_crop_path(&real, &quad, hw, hh, &|p, k| {
        Stabilizer::required_zoom(&correction(p, k), hw, hh, cap)
    });
    let d = (hw * hw + hh * hh).sqrt();
    let (zq, zl) = (zoom(&quad).unwrap_or(9.0), zoom(&l1).unwrap_or(9.0));
    let (jq, jl) = (Stabilizer::path_jitter(&quad, d), Stabilizer::path_jitter(&l1, d));
    assert!(zl < zq - 0.005, "{zl} vs {zq}");
    assert!(jl <= jq * 1.0001);
}

#[test]
fn locked_pose_is_crop_aware() {
    let real: Vec<CameraPose> = (0..120)
        .map(|k| CameraPose::new(Vec2::new(f64::from(k) * 0.8, 0.0), if k < 100 { 0.0 } else { 6.0 }, 0.0))
        .collect();
    let (hw, hh, cap) = (960.0, 540.0, 3.0);
    let z = |p: &CameraPose, k: usize| Stabilizer::required_zoom(&p.after(&real[k].inverse()), hw, hh, cap);
    let mid = CameraPose::new(Vec2::new(47.6, 0.0), 0.3, 0.0);
    let best = Stabilizer::lock_pose(&real, mid, 48.0, &z);
    let worst = |p: &CameraPose| (0..real.len()).map(|i| z(p, i).unwrap_or(9.0)).fold(0.0, f64::max);
    assert!(worst(&best) <= worst(&mid));
}

#[test]
fn smoothing_helpers_keep_poses_and_blend() {
    let poses: Vec<CameraPose> =
        (0..20).map(|k| CameraPose::new(Vec2::new(f64::from(k) * 2.0, 0.0), 0.0, 0.0)).collect();
    let s = Stabilizer::smooth(&poses, 3.0);
    assert!((s[10].translation.x - 20.0).abs() < 1e-9);
    let soft = Stabilizer::bilateral_smooth(&poses, 3.0, 100.0, 500.0);
    let blended = Stabilizer::blended(&poses, &soft, &[0.0; 20]);
    assert_eq!(blended, poses);
}

// Residual perspective (StabilizerPerspectiveTests).

fn tilting(n: usize, wobble: f64, seed: u64) -> (StabilizationAnalysis, Vec<PerspectiveResidual>) {
    let mut r = Lcg(seed);
    let mut real: Vec<[f64; 8]> = Vec::new();
    for k in 0..n {
        let mut v = [0.0_f64; 8];
        v[6] = wobble * r.symmetric() + 2e-6 * k as f64;
        v[7] = wobble * r.symmetric();
        v[0] = wobble * 0.5 * r.symmetric();
        real.push(v);
    }
    let mut pairs = vec![PerspectiveResidual::ZERO];
    for k in 1..n {
        let mut d = [0.0; 8];
        for c in 0..8 {
            d[c] = real[k][c] - real[k - 1][c];
        }
        pairs.push(PerspectiveResidual { values: d });
    }
    let mut a = StabilizationAnalysis::new(1920, 1080, times(n), vec![CameraMotion::IDENTITY; n]);
    a.perspective = pairs;
    (a, real.iter().map(|v| PerspectiveResidual { values: *v }).collect())
}

/// Shake of a point set after the plan's correction: jitter of where the corner points land over the frames.
fn persp_shake(real: &[PerspectiveResidual], plan: Option<&StabilizationPlan>) -> f64 {
    let corners =
        [Vec2::new(960.0, 540.0), Vec2::new(-960.0, 540.0), Vec2::new(960.0, -540.0), Vec2::new(-960.0, -540.0)];
    let mut total = 0.0;
    for c in corners {
        let landed: Vec<Vec2> = (0..real.len())
            .map(|k| {
                let mut p = real[k].map(c);
                if let Some(plan) = plan
                    && k < plan.perspective.len()
                {
                    p = plan.perspective[k].map(p);
                }
                p
            })
            .collect();
        total += Stabilizer::jitter(&landed);
    }
    total
}

#[test]
fn a_poor_inlier_pair_its_check_agrees_with_adds_no_perspective() {
    // The check agrees with the similarity (both still), which trusts the motion, not the pair's homography.
    let (mut a, _) = tilting(240, 4e-5, 9);
    a.confidence = vec![1.0; a.motions.len()];
    a.confidence[100] = 0.3;
    a.checks = a.motions.iter().map(|m| Some(*m)).collect();
    assert!(a.confidence_at(100) == 1.0 && a.stored_confidence(100) == 0.3);
    a.perspective[100] = PerspectiveResidual::new(&[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 3e-4, -3e-4]);
    let mut without = a.clone();
    without.perspective[100] = PerspectiveResidual::ZERO;
    let plan = plan_of(&a, &StabilizerOptions::default());
    let clean = plan_of(&without, &StabilizerOptions::default());
    assert!(!plan.perspective.is_empty());
    assert_eq!(plan.perspective, clean.perspective);
    a.confidence[100] = 1.0; // trusted: the pair does count
    assert_ne!(plan_of(&a, &StabilizerOptions::default()).perspective, clean.perspective);
}

#[test]
fn analysis_version_is_bumped() {
    const _: () = assert!(StabilizationAnalysis::CURRENT_VERSION >= 8);
}

#[test]
fn residual_perspective_shake_falls_below_a_third_and_strength_scales_it() {
    let (a, real) = tilting(240, 4e-5, 9);
    let mut o = StabilizerOptions { strength: 1.0, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    assert_eq!(plan.perspective.len(), a.frame_times.len());
    let (before, after) = (persp_shake(&real, None), persp_shake(&real, Some(&plan)));
    assert!(before > 1.0);
    assert!(after < before * 0.33, "before {before} after {after}");
    o.strength = 0.5;
    let half = plan_of(&a, &o);
    let mid = persp_shake(&real, Some(&half));
    assert!(mid > after && mid < before);
    o.strength = 0.0;
    assert!(plan_of(&a, &o).perspective.is_empty());
}

#[test]
fn zero_perspective_leaves_the_plan_untouched() {
    let (with_p, _) = tilting(60, 0.0, 9);
    let mut a = with_p;
    a.perspective = vec![];
    let mut zeros = a.clone();
    zeros.perspective = vec![PerspectiveResidual::ZERO; a.frame_times.len()];
    let o = StabilizerOptions::default();
    let (p1, p2) = (plan_of(&a, &o), plan_of(&zeros, &o));
    assert!(p1.corrections == p2.corrections && p2.perspective.is_empty());
    let t = Time::new(1, 3);
    assert_eq!(Stabilizer::perspective_correction(&p2, &zeros, t), PerspectiveResidual::ZERO);
}

#[test]
fn perspective_correction_is_interpolated_between_frames() {
    let (a, _) = tilting(90, 4e-5, 9);
    let plan = plan_of(&a, &StabilizerOptions { strength: 1.0, ..StabilizerOptions::default() });
    let mid = Stabilizer::perspective_correction(&plan, &a, Time::new(21, 60));
    let want = plan.perspective[10].lerp(&plan.perspective[11], 0.5);
    for i in 0..8 {
        assert!((mid.values[i] - want.values[i]).abs() < 1e-15);
    }
    let tol = Stabilizer::perspective_tolerances(1920, 1080);
    assert!(tol[6] < tol[0] && tol[2] == 0.1);
}

// Edge fill (StabilizerEdgeFillTests).

#[test]
fn uncovered_area_of_a_simple_shift() {
    // Picture shifted 96 px right of 1920x1080 output: 96 / 1920 = 5% of the output is open.
    let u = Stabilizer::uncovered_fraction(&CameraPose::new(Vec2::new(96.0, 0.0), 0.0, 0.0), 1.0, 960.0, 540.0);
    assert!((u - 0.05).abs() < 1e-9);
    assert!(Stabilizer::uncovered_fraction(&CameraPose::IDENTITY, 1.0, 960.0, 540.0) < 1e-12);
    assert!(
        Stabilizer::uncovered_fraction(&CameraPose::new(Vec2::new(96.0, 40.0), 2.0, 0.0), 1.5, 960.0, 540.0) < 1e-12
    );
    let all = Stabilizer::uncovered_fraction(&CameraPose::new(Vec2::new(5000.0, 0.0), 0.0, 0.0), 1.0, 960.0, 540.0);
    assert!((all - 1.0).abs() < 1e-9);
}

fn edge_shaky() -> StabilizationAnalysis {
    let mut r = Lcg(11);
    let poses: Vec<CameraPose> = (0..300)
        .map(|_| CameraPose::new(Vec2::new(45.0 * r.symmetric(), 30.0 * r.symmetric()), 1.2 * r.symmetric(), 0.0))
        .collect();
    analysis_from_poses(&poses, 1920, 1080)
}

#[test]
fn zoom_fill_plan_is_fully_covered() {
    let plan = plan_of(&edge_shaky(), &StabilizerOptions::default());
    assert_eq!(plan.uncovered.len(), plan.corrections.len());
    assert!(plan.uncovered.iter().copied().fold(0.0, f64::max) < 1e-6);
}

#[test]
fn fill_lowers_the_zoom_within_the_tolerance() {
    for fill in [StabilizerEdgeFill::Mirror, StabilizerEdgeFill::Blur] {
        let a = edge_shaky();
        let zoom_plan = plan_of(&a, &StabilizerOptions::default());
        let plan = plan_of(&a, &StabilizerOptions { edge_fill: fill, ..StabilizerOptions::default() });
        assert!(zoom_plan.zoom > 1.02);
        assert!(plan.zoom < zoom_plan.zoom && plan.zoom >= 1.0);
        let worst = plan.uncovered.iter().copied().fold(0.0, f64::max);
        assert!(worst <= Stabilizer::EDGE_FILL_TOLERANCE + 1e-6);
        assert!(worst > 0.0);
        assert_eq!(plan.models, zoom_plan.models);
    }
}

#[test]
fn a_still_shot_keeps_zoom_one_with_a_fill() {
    let o = StabilizerOptions { edge_fill: StabilizerEdgeFill::Mirror, ..StabilizerOptions::default() };
    let a = StabilizationAnalysis::new(1920, 1080, times(30), vec![CameraMotion::IDENTITY; 30]);
    assert_eq!(plan_of(&a, &o).zoom, 1.0);
}

#[test]
fn options_keep_the_plan_when_only_the_edge_fill_row_is_absent() {
    let a = StabilizerOptions::default();
    let b = StabilizerOptions { edge_fill: StabilizerEdgeFill::Mirror, ..StabilizerOptions::default() };
    assert!(a != b && !a.same_plan_as(&b));
}

#[test]
fn cut_detection_flags_a_histogram_jump_but_not_a_busy_scene() {
    let n = 60;
    let motions = vec![CameraMotion::IDENTITY; n];
    let mut hist = vec![0.02; n];
    hist[30] = 0.8;
    let cuts = StabilizationCuts::detect(&motions, &hist, &[], &[], &[]);
    assert_eq!(cuts, vec![30]);
    let busy = vec![0.5; n];
    assert!(StabilizationCuts::detect(&motions, &busy, &[], &[], &[]).is_empty());
    let mut m2 = motions.clone();
    m2[20] = CameraMotion::new(0.0, 0.0, 12.0, 1.0);
    assert_eq!(StabilizationCuts::detect(&m2, &[], &[], &[], &[]), vec![20]);
    // The independent check measures a steady camera there: Vision's error, no cut.
    let mut checks = vec![Some(CameraMotion::IDENTITY); n];
    checks[20] = Some(CameraMotion::IDENTITY);
    assert!(StabilizationCuts::detect(&m2, &[], &[], &checks, &[]).is_empty());
}

// Low confidence, checks and the guard (StabilizerConfidenceTests), cuts and the rebuild (StabilizerRebuildTests).

use std::ops::Range;

/// True hand-held motions (jitter px / degrees) for `n` frames.
fn true_motions(n: usize, jitter: f64, rot: f64, seed: u64) -> Vec<CameraMotion> {
    let mut r = Lcg(seed);
    let poses: Vec<CameraPose> = (0..n)
        .map(|_| {
            let (x, y) = (jitter * r.symmetric(), jitter * r.symmetric());
            CameraPose::new(Vec2::new(x, y), rot * r.symmetric(), 0.0)
        })
        .collect();
    let mut out = vec![CameraMotion::IDENTITY];
    out.extend((1..n).map(|k| CameraMotion::from_poses(&poses[k - 1], &poses[k])));
    out
}

fn analysis_of(motions: &[CameraMotion]) -> StabilizationAnalysis {
    StabilizationAnalysis::new(1920, 1080, times(motions.len()), motions.to_vec())
}

/// What the viewer sees: a world point through the TRUE camera path and the plan's correction.
fn seen(truth: &[CameraMotion], plan: &StabilizationPlan, range: Range<usize>) -> Vec<Vec2> {
    let path = Stabilizer::path(truth);
    range.map(|k| stage_affine(&plan.corrections[k]).apply(path[k].apply(Vec2::new(100.0, -50.0)))).collect()
}

fn unstabilised(truth: &[CameraMotion], range: Range<usize>) -> Vec<Vec2> {
    let path = Stabilizer::path(truth);
    range.map(|k| path[k].apply(Vec2::new(100.0, -50.0))).collect()
}

/// Measured = truth + noise of `noise` px on `range` (what a registration fitted to a blank wall delivers).
fn noisy(truth: &[CameraMotion], range: Range<usize>, noise: f64) -> Vec<CameraMotion> {
    let mut r = Lcg(5);
    let mut m = truth.to_vec();
    for k in range {
        m[k].dx += noise * r.symmetric();
        m[k].dy += noise * r.symmetric();
        m[k].rotation += r.symmetric();
    }
    m
}

fn tm(n: usize) -> Vec<CameraMotion> {
    true_motions(n, 6.0, 0.2, 11)
}

#[test]
fn low_confidence_stretch_does_not_add_shake() {
    let truth = tm(300);
    let bad = 100..160;
    let mut a = analysis_of(&noisy(&truth, bad.clone(), 25.0));
    // Without a confidence measure the noise is "corrected" into the picture.
    let blind = plan_of(&a, &StabilizerOptions::default());
    assert!(
        Stabilizer::jitter(&seen(&truth, &blind, bad.clone()))
            > Stabilizer::jitter(&unstabilised(&truth, bad.clone())) * 1.5
    );
    // Flagged: the stretch falls back to the neighboring path, no worse than untouched.
    a.confidence = (0..truth.len()).map(|i| if bad.contains(&i) { 0.0 } else { 1.0 }).collect();
    let plan = plan_of(&a, &StabilizerOptions::default());
    let ratio = Stabilizer::jitter(&seen(&truth, &plan, bad.clone())) / Stabilizer::jitter(&unstabilised(&truth, bad));
    assert!(ratio <= 1.05, "r {ratio}");
    // The trusted parts are still steadied.
    let good = 10..90;
    assert!(
        Stabilizer::jitter(&seen(&truth, &plan, good.clone())) < Stabilizer::jitter(&unstabilised(&truth, good)) * 0.5
    );
    assert_eq!(plan.uncorrected_frames, 0);
}

#[test]
fn mostly_untrusted_shot_is_left_alone() {
    let truth = tm(200);
    let mut a = analysis_of(&noisy(&truth, 0..200, 10.0));
    a.confidence = (0..truth.len()).map(|i| if i % 10 < 3 { 1.0 } else { 0.0 }).collect(); // 30 % trusted (a blank wall)
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.zoom, 1.0);
    assert!(plan.corrections.iter().all(|c| *c == StageTransform::IDENTITY));
    assert_eq!(plan.uncorrected_frames, 200);
    // The same noisy shot with checks that see the true motion: the guard confirms it would get shakier.
    a.checks = truth.iter().map(|m| Some(*m)).collect();
    assert_eq!(plan_of(&a, &StabilizerOptions::default()).uncorrected_frames, 200);
}

#[test]
fn mostly_untrusted_shot_is_corrected_when_the_check_confirms_it_gets_steadier() {
    // Vision is right, the check could vouch for few pairs (moving subject) but measures less shake after.
    let truth = tm(200);
    let mut a = analysis_of(&truth);
    a.confidence = (0..truth.len()).map(|i| if i % 10 < 3 { 1.0 } else { 0.0 }).collect();
    a.checks = (0..truth.len()).map(|i| if i % 2 == 0 { Some(truth[i]) } else { None }).collect();
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.uncorrected_frames, 0);
    let all = 10..190;
    assert!(
        Stabilizer::jitter(&seen(&truth, &plan, all.clone())) < Stabilizer::jitter(&unstabilised(&truth, all)) * 0.5
    );
}

#[test]
fn guard_falls_back_when_the_independent_check_measures_more_shake() {
    let truth = true_motions(240, 2.0, 0.2, 11);
    // Undetected noise (confidence high everywhere), but the independent check sees the true motion.
    let mut a = analysis_of(&noisy(&truth, 0..240, 12.0));
    a.checks = truth.iter().map(|m| Some(*m)).collect();
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert!(plan.corrections.iter().all(|c| *c == StageTransform::IDENTITY));
    assert_eq!(plan.zoom, 1.0);
    assert_eq!(plan.uncorrected_frames, 240);
    // A good measurement with the same check keeps its correction.
    let mut good = analysis_of(&true_motions(240, 6.0, 0.2, 11));
    good.checks = good.motions.iter().map(|m| Some(*m)).collect();
    let kept = plan_of(&good, &StabilizerOptions::default());
    assert!(kept.zoom > 1.0 && kept.uncorrected_frames == 0);
}

#[test]
fn guard_decides_per_segment() {
    let truth = true_motions(240, 6.0, 0.2, 11);
    let mut measured = noisy(&truth, 120..240, 30.0);
    measured[120] = CameraMotion::IDENTITY;
    let mut a = analysis_of(&measured);
    a.cuts = vec![120];
    let mut checks: Vec<Option<CameraMotion>> = truth.iter().map(|m| Some(*m)).collect();
    checks[120] = None;
    a.checks = checks;
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.uncorrected_frames, 120);
    let first = 10..110;
    assert!(
        Stabilizer::jitter(&seen(&truth, &plan, first.clone()))
            < Stabilizer::jitter(&unstabilised(&truth, first)) * 0.5
    );
    // The skipped segment only carries the shared zoom: no shift, no turn.
    let z = plan.zoom;
    assert!(plan.corrections[120..240].iter().all(|c| c.position.length() < 1e-9 && (c.scale - z).abs() < 1e-9));
}

#[test]
fn noisy_zoom_and_turn_are_left_out_when_the_check_says_they_add_shake() {
    // A small iPhone-like shake that only moves (no turn, no zoom), measured with zoom / turn noise: the full similarity
    // correction adds shake, the translation-only one removes it.
    let truth = true_motions(300, 3.0, 0.0, 11);
    let mut r = Lcg(21);
    let mut measured = truth.clone();
    for m in measured.iter_mut().skip(1) {
        m.rotation += 0.25 * r.symmetric();
        m.scale *= (0.006 * r.symmetric()).exp();
    }
    let mut a = analysis_of(&measured);
    a.checks = truth.iter().map(|m| Some(*m)).collect();
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.uncorrected_frames, 0);
    assert_eq!(plan.models, vec![StabilizationModel::Translation]);
    let all = 10..290;
    assert!(
        Stabilizer::jitter(&seen(&truth, &plan, all.clone())) < Stabilizer::jitter(&unstabilised(&truth, all)) * 0.6
    );
    assert!(plan.corrections.iter().all(|c| c.rotation.abs() < 1e-9 && (c.scale - plan.zoom).abs() < 1e-9));
}

#[test]
fn frames_between_analysed_frames_get_the_interpolated_correction() {
    // 60 fps footage analyzed at 30 fps: every other source frame lies between two analyzed frames.
    let fd60 = Time::new(1, 60);
    let mut a = analysis_of(&tm(60));
    a.frame_times = (0..60).map(|i| fd60 * (2 * i) as i64).collect();
    let plan = plan_of(&a, &StabilizerOptions::default());
    let (c10, c11) = (plan.corrections[10], plan.corrections[11]);
    let mid = Stabilizer::correction(&plan, &a, fd60 * 21);
    assert!((mid.position - (c10.position + c11.position) * 0.5).length() < 1e-9);
    assert!((mid.rotation - (c10.rotation + c11.rotation) / 2.0).abs() < 1e-9);
    assert!((mid.scale - (c10.scale * c11.scale).sqrt()).abs() < 1e-9);
    assert_eq!(Stabilizer::correction(&plan, &a, fd60 * 20), c10);
    // Before the first / after the last analyzed frame: held.
    assert_eq!(Stabilizer::correction(&plan, &a, fd60 * 200), plan.corrections[59]);
}

#[test]
fn a_cut_between_analysed_frames_is_not_blended() {
    let fd60 = Time::new(1, 60);
    let mut a = analysis_of(&tm(60));
    a.frame_times = (0..60).map(|i| fd60 * (2 * i) as i64).collect();
    a.cuts = vec![30];
    let plan = plan_of(&a, &StabilizerOptions::default());
    // Source frame 59 lies between analyzed 29 (old shot) and 30 (new shot): it keeps the old shot's correction.
    assert_eq!(Stabilizer::correction(&plan, &a, fd60 * 59), plan.corrections[29]);
}

#[test]
fn a_real_turn_keeps_the_full_model() {
    let truth = true_motions(300, 4.0, 0.6, 11);
    let mut a = analysis_of(&truth);
    a.checks = truth.iter().map(|m| Some(*m)).collect();
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert_eq!(plan.models, vec![StabilizationModel::Similarity]);
    assert!(plan.corrections.iter().any(|c| c.rotation.abs() > 0.1));
}

#[test]
fn without_checks_the_full_model_is_used_and_missing_checks_never_block() {
    let plan = plan_of(&analysis_of(&tm(200)), &StabilizerOptions::default());
    assert_eq!(plan.models, vec![StabilizationModel::Similarity]);
    let mut a = analysis_of(&tm(200));
    a.checks = vec![None; 200];
    let plan = plan_of(&a, &StabilizerOptions::default());
    assert!(plan.zoom > 1.0 && plan.uncorrected_frames == 0);
}

fn calm(n: usize) -> Vec<CameraMotion> {
    true_motions(n, 2.0, 0.1, 11)
}

#[test]
fn a_histogram_jump_is_a_cut() {
    let mut h: Vec<f64> = (0..120).map(|i| 0.02 + 0.01 * f64::from(i % 3)).collect();
    h[60] = 0.45;
    assert_eq!(StabilizationCuts::detect(&calm(120), &h, &vec![3.0; 120], &[], &[]), vec![60]);
}

#[test]
fn a_residual_spike_is_a_cut_even_with_similar_colours() {
    let mut r: Vec<f64> = (0..120).map(|i| 2.5 + 0.5 * f64::from(i % 4)).collect();
    r[45] = 24.0;
    assert_eq!(StabilizationCuts::detect(&calm(120), &vec![0.03; 120], &r, &[], &[]), vec![45]);
}

#[test]
fn a_wrong_match_with_a_zoom_jump_is_a_cut() {
    let mut m = calm(120);
    m[80] = CameraMotion::new(30.0, -10.0, 8.0, 0.84); // Vision "matched" across a cut
    assert_eq!(StabilizationCuts::detect(&m, &vec![0.03; 120], &vec![3.0; 120], &[], &[]), vec![80]);
}

#[test]
fn a_fast_pan_or_busy_scene_is_not_a_cut() {
    let mut r = Lcg(3);
    let h: Vec<f64> = (0..150).map(|_| 0.25 + 0.05 * r.symmetric()).collect();
    let res: Vec<f64> = (0..150).map(|_| 18.0 + 3.0 * r.symmetric()).collect();
    let m: Vec<CameraMotion> = (0..150)
        .map(|_| {
            let (dx, dy, rot, sc) =
                (40.0 + 5.0 * r.symmetric(), 2.0 * r.symmetric(), 0.5 * r.symmetric(), 1.0 + 0.01 * r.symmetric());
            CameraMotion::new(dx, dy, rot, sc)
        })
        .collect();
    assert!(StabilizationCuts::detect(&m, &h, &res, &[], &[]).is_empty());
}

#[test]
fn a_light_change_both_registrations_agree_on_is_no_cut() {
    let (mut h, mut r) = (vec![0.01; 120], vec![1.6; 120]);
    h[60] = 0.2;
    r[60] = 10.6;
    let mut conf = vec![1.0; 120];
    assert!(StabilizationCuts::detect(&calm(120), &h, &r, &[], &conf).is_empty());
    conf[60] = 0.1; // they disagree there: a cut
    assert_eq!(StabilizationCuts::detect(&calm(120), &h, &r, &[], &conf), vec![60]);
}

#[test]
fn a_vision_zoom_jump_the_check_does_not_see_is_no_cut() {
    let m0 = calm(120);
    let mut m = m0.clone();
    for item in m.iter_mut().take(42).skip(36) {
        *item = CameraMotion::new(-20.0, 60.0, -2.5, 0.86);
    }
    let (flat, res) = (vec![0.02; 120], vec![2.5; 120]);
    let mut checks: Vec<Option<CameraMotion>> = m0.iter().map(|x| Some(*x)).collect();
    assert!(StabilizationCuts::detect(&m, &flat, &res, &checks, &[]).is_empty());
    // The check sees the jump too (or cannot measure): a cut.
    checks[38] = Some(CameraMotion::new(0.0, 0.0, 0.0, 0.85));
    checks[40] = None;
    assert_eq!(StabilizationCuts::detect(&m, &flat, &res, &checks, &[]), vec![38, 40]);
}

#[test]
fn every_cut_names_its_reason() {
    let mut m = calm(120);
    m[80] = CameraMotion::new(0.0, 0.0, 0.0, 0.84);
    let mut h = vec![0.03; 120];
    h[30] = 0.45;
    let mut r = vec![3.0; 120];
    r[55] = 24.0;
    let found = StabilizationCuts::detect_with_reasons(&m, &h, &r, &[], &[]);
    assert_eq!(found.iter().map(|c| c.0).collect::<Vec<_>>(), vec![30, 55, 80]);
    use crate::stabilization_cuts::CutReason;
    assert_eq!(
        found.iter().map(|c| c.1).collect::<Vec<_>>(),
        vec![CutReason::Histogram, CutReason::Residual, CutReason::Motion]
    );
}

#[test]
fn missing_scores_only_use_the_motion_and_the_local_reference_survives_tiny_inputs() {
    let mut m = calm(50);
    m[20] = CameraMotion::new(0.0, 0.0, 0.0, 1.18);
    assert_eq!(StabilizationCuts::detect(&m, &[], &[], &[], &[]), vec![20]);
    assert_eq!(StabilizationCuts::local_reference(&[], 0), 0.0);
    assert_eq!(StabilizationCuts::local_reference(&[1.0], 0), 0.0);
    assert_eq!(StabilizationCuts::local_reference(&[1.0, 2.0], 1), 0.0);
    assert_eq!(StabilizationCuts::local_reference(&[1.0, 2.0], 0), 0.0);
}

#[test]
fn bilateral_smooth_follows_a_step_but_flattens_jitter() {
    let mut poses = vec![CameraPose::IDENTITY; 120];
    for p in poses.iter_mut().skip(60) {
        *p = CameraPose::new(Vec2::new(400.0, 0.0), 0.0, 0.0);
    }
    let s = Stabilizer::bilateral_smooth(&poses, 8.0, 50.0, 1000.0);
    assert!(s[59].translation.x.abs() < 1.0); // the step is not smeared backwards
    assert!((s[60].translation.x - 400.0).abs() < 1.0);
    let g = Stabilizer::smooth(&poses, 8.0);
    assert!(g[59].translation.x.abs() > 20.0); // a plain Gaussian smears it
}

#[test]
fn rebuild_smooth_residual_drops_and_crop_stays_bounded() {
    let a = shaky(240, 1.5, 8.0, 0.4, 11);
    let o = StabilizerOptions { mode: StabilizerMode::Smooth, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    let r = steadied(&a, &plan);
    assert!(r.1 < r.0 * 0.4);
    assert!(plan.zoom <= 1.0 / (1.0 - o.max_crop) + 1e-6);
}

#[test]
fn camera_lock_holds_the_shot_and_gives_way_on_a_pan() {
    let a = shaky(240, 0.0, 6.0, 0.2, 11);
    let o = StabilizerOptions { mode: StabilizerMode::Locked, ..StabilizerOptions::default() };
    let plan = plan_of(&a, &o);
    let after = rendered(&a, &plan);
    let range = |f: fn(&Vec2) -> f64| {
        let v: Vec<f64> = after.iter().map(f).collect();
        v.iter().copied().fold(f64::NEG_INFINITY, f64::max) - v.iter().copied().fold(f64::INFINITY, f64::min)
    };
    assert!(range(|p| p.x) < 3.0 && range(|p| p.y) < 3.0);
    assert!(plan.zoom <= 1.0 / (1.0 - o.max_locked_crop) + 1e-6);
    let pan = shaky(240, 4.0, 2.0, 0.0, 11);
    let p = plan_of(&pan, &o);
    assert!(p.fully_covered && p.zoom <= 1.0 / (1.0 - o.max_locked_crop) + 1e-6);
}

#[test]
fn a_jump_the_smoothing_cannot_follow_still_needs_the_cut_flag() {
    let mut a = shaky(200, 0.0, 0.0, 0.0, 11);
    a.motions[100] = CameraMotion::new(40.0, 0.0, 0.0, 1.0);
    let o = StabilizerOptions { mode: StabilizerMode::Smooth, ..StabilizerOptions::default() };
    let blind = plan_of(&a, &o);
    a.cuts = vec![100];
    let cut = plan_of(&a, &o);
    assert!(blind.corrections.iter().any(|c| *c != StageTransform::IDENTITY));
    assert!(cut.corrections.iter().all(|c| *c == StageTransform::IDENTITY));
}
