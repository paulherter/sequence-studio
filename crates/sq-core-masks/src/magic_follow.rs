// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagicFollow.swift
//! Magic mask tracking (pure part): one segmented frame (`InstanceFrame`) and the per-frame rule of Track
//! (`MagicFollower`). The segmentation itself (Vision) runs in SQAnalysis; tests drive this with synthetic frames.

use crate::magic_correction;
use crate::magic_mask::{InstanceLabels, MagicPick};
use crate::subject_mask::SubjectMatte;
use sq_core_model::MagicPoint;
use sq_core_time::Vec2;
use std::collections::BTreeSet;

/// The picture of a segmented frame at the labels' size: RGB 0...1, interleaved, row 0 at the top. Corrections (add /
/// remove points) grow and cut along its color edges.
#[derive(Clone, Debug, PartialEq)]
pub struct MagicGuide {
    width: usize,
    height: usize,
    /// The interleaved RGB values.
    pub rgb: Vec<f32>,
}

impl MagicGuide {
    /// A guide of `width` x `height`; `rgb.len()` must be `width * height * 3` (Swift traps otherwise).
    pub fn new(width: usize, height: usize, rgb: Vec<f32>) -> MagicGuide {
        assert!(width > 0 && height > 0 && rgb.len() == width * height * 3, "MagicGuide size mismatch");
        MagicGuide { width, height, rgb }
    }

    /// Width in px.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Height in px.
    pub fn height(&self) -> usize {
        self.height
    }
}

/// Soft matte of a set of labels at the labels' size.
pub type SoftMatte = Box<dyn Fn(&BTreeSet<u8>) -> SubjectMatte + Send + Sync>;

/// One segmented frame: object labels plus the soft matte of any set of objects, and (when the segmenter gives it) the
/// picture for corrections.
pub struct InstanceFrame {
    /// The object labels.
    pub labels: InstanceLabels,
    /// The picture for corrections.
    pub guide: Option<MagicGuide>,
    /// Soft matte of the given labels at the labels' size; default: the hard labels.
    pub soft: SoftMatte,
}

impl InstanceFrame {
    /// A frame whose soft matte is the hard matte of the labels.
    pub fn new(labels: InstanceLabels, guide: Option<MagicGuide>) -> InstanceFrame {
        let for_soft = labels.clone();
        InstanceFrame { labels, guide, soft: Box::new(move |s| for_soft.matte_of(s)) }
    }
}

/// The per-frame rule of Track: the first frame picks by the clicks made on it (or continues a stored matte), every later
/// frame keeps the objects that continue the last matte (`MagicPick::follow`); add / remove points made on a frame
/// correct it there (`magic_correction`) and the correction is carried on. A frame's matte comes from that frame alone:
/// nothing of the frame before is blended in (a blend in tracking order trails every motion, and the other way when
/// tracked backward). Pure apart from the segmenter's output, so tests drive it with synthetic frames.
pub struct MagicFollower {
    previous: Option<SubjectMatte>,
    last_confidence: f64,
    correction: magic_correction::State,
    index: usize,
    starts_on_lost_frame: bool,
}

impl MagicFollower {
    /// A point belongs to the frame at `pts` (seconds) when its source time is within this of it.
    pub const POINT_TOLERANCE: f64 = 1e-3;

    /// `start`: a matte to continue from (stored for the start frame), else `None` to pick by `points`.
    /// A start matte stored empty (the subject was not found on that frame) is no matte to continue: only points made
    /// on that frame pick there.
    pub fn new(start: Option<SubjectMatte>) -> MagicFollower {
        let lost = start.as_ref().is_some_and(|s| s.is_blank());
        MagicFollower {
            previous: if lost { None } else { start },
            last_confidence: 1.0,
            correction: magic_correction::State::default(),
            index: 0,
            starts_on_lost_frame: lost,
        }
    }

    /// The last matte found.
    pub fn previous(&self) -> Option<&SubjectMatte> {
        self.previous.as_ref()
    }

    /// Agreement of the last step with the matte before it (0...1).
    pub fn last_confidence(&self) -> f64 {
        self.last_confidence
    }

    /// Whether a point stored at `point` (source seconds) was made on the frame at `pts` that is shown for `span`
    /// seconds: at the frame's own time (older projects stored the decoded frame's time) or anywhere before the next
    /// frame (a click stores the clip's source time at the playhead, which lies inside the frame). `span` 0 = unknown:
    /// the frame's own time only.
    pub fn belongs(point: f64, pts: f64, span: f64) -> bool {
        let d = point - pts;
        d >= -Self::POINT_TOLERANCE && d < span.max(2.0 * Self::POINT_TOLERANCE) - Self::POINT_TOLERANCE
    }

    /// The matte of the next frame in tracking order, `None` when the subject is not found on it. The follower then stays
    /// as it was: the next frame is compared with the last matte that was found, so a subject hidden for some frames is
    /// picked up again where it was last seen. `points`: all points of the pick; the first frame without a start matte
    /// uses the pick's own frame's points, every frame applies the points made on it (`pts`: the frame's source time in
    /// seconds, `None` = none; `span`: seconds to the next frame).
    pub fn step(
        &mut self,
        f: &InstanceFrame,
        points: &[MagicPoint],
        pts: Option<f64>,
        span: f64,
    ) -> Option<SubjectMatte> {
        let mut selected: BTreeSet<u8>;
        let mut here: Vec<MagicPoint> = Vec::new();
        if let Some(pts) = pts {
            here = points
                .iter()
                .filter(|p| {
                    Self::belongs(p.source_time.value() as f64 / p.source_time.timescale().max(1) as f64, pts, span)
                })
                .copied()
                .collect();
        }
        let mut cuts: Vec<Vec2> = Vec::new();
        if let Some(prev) = &self.previous {
            let r = MagicPick::follow(prev, &f.labels)?;
            selected = r.selected.clone();
            for p in &here {
                let x = f.labels.label_at(p.position);
                if x == 0 {
                    continue;
                }
                if !p.subtract {
                    selected.insert(x);
                } else if MagicPick::share(x, prev, &f.labels) >= MagicPick::PROTECTED_SHARE {
                    cuts.push(p.position);
                } else {
                    selected.remove(&x);
                }
            }
            if self.index == 0 {
                // Continuing a stored (maybe corrected) matte: its correction is carried on.
                self.correction = magic_correction::state(&(f.soft)(&r.selected), prev, f.guide.as_ref());
            }
        } else {
            // The pick's points were made on another frame: they say nothing about where the subject is here.
            if self.starts_on_lost_frame && here.is_empty() {
                return None;
            }
            let anchor = points.first().map(|p| p.source_time);
            let first: Vec<MagicPoint> = if here.is_empty() {
                points.iter().filter(|p| Some(p.source_time) == anchor).copied().collect()
            } else {
                here.clone()
            };
            let s = MagicPick::selection(&first, &f.labels);
            selected = s.selected;
            cuts = s.cuts;
            here = first;
        }
        if selected.is_empty() {
            return None;
        }
        let raw = (f.soft)(&selected);
        if raw.is_blank() {
            return None; // an empty matte is a lost subject, never a black frame
        }
        let add: Vec<Vec2> = here.iter().filter(|p| !p.subtract).map(|p| p.position).collect();
        // A frame that turns out lost leaves the carried correction as it was.
        let mut carried = self.correction.clone();
        let corrected = magic_correction::apply(&raw, f.guide.as_ref(), &add, &cuts, &mut carried);
        if corrected.is_blank() {
            return None;
        }
        match &self.previous {
            Some(prev) if self.index > 0 => {
                let c = Self::overlap(&corrected, prev);
                if c < MagicPick::MIN_CONFIDENCE {
                    return None;
                }
                self.last_confidence = c;
            }
            _ => self.last_confidence = 1.0,
        }
        self.correction = carried;
        self.index += 1;
        self.previous = Some(corrected.clone());
        Some(corrected)
    }

    /// Soft IoU of two mattes (`b` resampled to `a`'s size).
    pub fn overlap(a: &SubjectMatte, b: &SubjectMatte) -> f64 {
        let resampled;
        let bb = if a.width() == b.width() && a.height() == b.height() {
            b
        } else {
            resampled = b.resampled(a.width(), a.height());
            &resampled
        };
        let (mut mn, mut mx) = (0.0_f64, 0.0_f64);
        for i in 0..a.values.len() {
            let (x, y) = (f64::from(a.values[i]), f64::from(bb.values[i]));
            mn += x.min(y);
            mx += x.max(y);
        }
        if mx > 0.0 { mn / mx } else { 0.0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::{SwingShot, matte_scores};
    use sq_core_time::Time;

    fn face() -> Vec2 {
        Vec2::new(96.0 / 192.0, 30.0 / 108.0)
    }
    fn lamp_point() -> Vec2 {
        Vec2::new(137.0 / 192.0, 60.0 / 108.0)
    }
    fn hat_point() -> Vec2 {
        Vec2::new(96.0 / 192.0, 12.0 / 108.0)
    }
    fn pt(p: Vec2, f: i64, subtract: bool) -> MagicPoint {
        MagicPoint { position: p, subtract, source_time: Time::new(f, 24) }
    }

    /// Tracks frames 0..<48 and returns per-frame (soft IoU, leak) against `truth`.
    fn track(
        mut shot: SwingShot,
        points: &[MagicPoint],
        truth: fn(i64) -> SubjectMatte,
        start: Option<SubjectMatte>,
    ) -> Vec<(f64, f64)> {
        let mut follower = MagicFollower::new(start);
        let mut out = Vec::new();
        for f in 0..48 {
            let fr = shot.frame(f); // every frame drawn, so the wobble matches across runs
            let Some(m) = follower.step(&fr, points, Some(f as f64 / 24.0), 0.0) else {
                panic!("lost at {f}");
            };
            let s = matte_scores(&m, &truth(f));
            out.push((s.0, s.2));
        }
        out
    }

    fn mean(x: &[(f64, f64)], leak: bool) -> f64 {
        if x.is_empty() { 0.0 } else { x.iter().map(|v| if leak { v.1 } else { v.0 }).sum::<f64>() / x.len() as f64 }
    }

    #[test]
    fn remove_point_cuts_a_merged_lamp_for_the_whole_track() {
        let mut shot = SwingShot::new();
        shot.merge_lamp = true;
        let mut shot2 = SwingShot::new();
        shot2.merge_lamp = true;
        let without = track(shot, &[pt(face(), 0, false)], SwingShot::truth, None);
        let with = track(shot2, &[pt(face(), 0, false), pt(lamp_point(), 0, true)], SwingShot::truth, None);
        assert_eq!(with.len(), 48);
        assert!(mean(&without, true) > 0.4);
        assert!(mean(&with, true) < 0.05, "leak {}", mean(&with, true));
        assert!(mean(&with, false) > 0.9, "soft IoU {}", mean(&with, false));
        assert!(with.iter().map(|v| v.1).fold(0.0, f64::max) < 0.1);
    }

    #[test]
    fn add_point_grows_a_missed_hat_and_keeps_it_on_the_moving_head() {
        let mut a = SwingShot::new();
        a.hat = true;
        let mut b = SwingShot::new();
        b.hat = true;
        let without = track(a, &[pt(face(), 0, false)], SwingShot::truth_with_hat, None);
        let with = track(b, &[pt(face(), 0, false), pt(hat_point(), 0, false)], SwingShot::truth_with_hat, None);
        assert_eq!(with.len(), 48);
        assert!(mean(&with, false) > mean(&without, false) + 0.03);
        assert!(mean(&with, false) > 0.9, "soft IoU {}", mean(&with, false));
        assert!(mean(&with, true) < 0.05);
    }

    #[test]
    fn a_correction_acts_from_the_frame_it_was_made_on() {
        let mut shot = SwingShot::new();
        shot.merge_lamp = true;
        let r = track(shot, &[pt(face(), 0, false), pt(lamp_point(), 10, true)], SwingShot::truth, None);
        assert_eq!(r.len(), 48);
        assert!(r[0..10].iter().all(|v| v.1 > 0.4));
        assert!(mean(&r[12..], true) < 0.05);
    }

    #[test]
    fn a_point_inside_a_frames_span_belongs_to_that_frame() {
        let fd = 1.0 / 24.0;
        assert!(MagicFollower::belongs(10.0 * fd, 10.0 * fd, 0.0));
        assert!(MagicFollower::belongs(10.0 * fd + 0.0000005, 10.0 * fd, 0.0));
        assert!(!MagicFollower::belongs(10.0 * fd + 0.03, 10.0 * fd, 0.0));
        assert!(MagicFollower::belongs(10.0 * fd + 0.03, 10.0 * fd, fd));
        assert!(!MagicFollower::belongs(11.0 * fd, 10.0 * fd, fd));
        assert!(MagicFollower::belongs(11.0 * fd, 11.0 * fd, fd));
        assert!(!MagicFollower::belongs(10.0 * fd - 0.01, 10.0 * fd, fd));
    }

    #[test]
    fn a_correction_stored_inside_a_frame_acts_from_that_frame() {
        let mut shot = SwingShot::new();
        shot.merge_lamp = true;
        // Made with the playhead of a 30 fps sequence at 13/30 s: inside the 24 fps frame 10.
        let points = [
            pt(face(), 0, false),
            MagicPoint { position: lamp_point(), subtract: true, source_time: Time::new(13, 30) },
        ];
        let mut follower = MagicFollower::new(None);
        let mut leaks = Vec::new();
        for f in 0..48 {
            let m = follower.step(&shot.frame(f), &points, Some(f as f64 / 24.0), 1.0 / 24.0);
            let Some(m) = m else { panic!("lost at {f}") };
            leaks.push(matte_scores(&m, &SwingShot::truth(f)).2);
        }
        assert!(leaks[0..10].iter().all(|v| *v > 0.4));
        assert!((leaks[12..].iter().sum::<f64>() / (leaks.len() - 12) as f64) < 0.05);
    }

    #[test]
    fn track_continuing_a_corrected_frame_keeps_the_correction() {
        let mut shot = SwingShot::new();
        shot.merge_lamp = true;
        let points = [pt(face(), 0, false), pt(lamp_point(), 0, true)];
        let mut follower = MagicFollower::new(None);
        for f in 0..=20 {
            follower.step(&shot.frame(f), &points, Some(f as f64 / 24.0), 0.0);
        }
        let stored = follower.previous().cloned();
        assert!(stored.is_some());
        let mut g = SwingShot::new();
        g.merge_lamp = true;
        let mut cont = MagicFollower::new(stored);
        let (mut leak, mut n) = (0.0, 0.0);
        for f in 0..48 {
            let fr = g.frame(f);
            if f < 20 {
                continue;
            }
            let Some(m) = cont.step(&fr, &points, Some(f as f64 / 24.0), 0.0) else { panic!("lost at {f}") };
            leak += matte_scores(&m, &SwingShot::truth(f)).2;
            n += 1.0;
        }
        assert!(leak / n < 0.05, "leak {}", leak / n);
    }

    #[test]
    fn remove_on_the_subject_cuts_while_remove_on_another_object_drops_it() {
        let mut l = vec![0_u8; 32];
        for y in 1..=2 {
            for x in 0..4 {
                l[y * 8 + x] = 1;
            }
            for x in 4..8 {
                l[y * 8 + x] = 2;
            }
        }
        let labels = InstanceLabels::new(8, 4, l);
        let t = Time::ZERO;
        let p = |x: f64, subtract: bool| MagicPoint { position: Vec2::new(x, 0.5), subtract, source_time: t };
        let cut_subject = MagicPick::selection(&[p(0.1, false), p(0.3, true)], &labels);
        assert!(cut_subject.selected == BTreeSet::from([1]) && cut_subject.cuts.len() == 1);
        let drop_other = MagicPick::selection(&[p(0.1, false), p(0.9, false), p(0.8, true)], &labels);
        assert!(drop_other.selected == BTreeSet::from([1]) && drop_other.cuts.is_empty());
    }

    #[test]
    fn no_guide_means_instance_level_only() {
        let m = SubjectMatte::new(4, 4, vec![1.0; 16]);
        let mut st = magic_correction::State::default();
        let out = magic_correction::apply(&m, None, &[], &[Vec2::new(0.5, 0.5)], &mut st);
        assert_eq!(out, m);
    }

    #[test]
    fn swinging_head_is_followed_without_trail_or_leak() {
        let mut shot = SwingShot::new();
        let mut follower = MagicFollower::new(None);
        let click = [MagicPoint { position: face(), subtract: false, source_time: Time::ZERO }];
        let (mut soft, mut hard, mut worst, mut leak, mut n) = (0.0, 0.0, 1.0_f64, 0.0, 0.0);
        for f in 0..48 {
            let Some(m) = follower.step(&shot.frame(f), &click, None, 0.0) else { panic!("lost at {f}") };
            if f == 0 {
                continue;
            }
            let s = matte_scores(&m, &SwingShot::truth(f));
            soft += s.0;
            hard += s.1;
            worst = worst.min(s.0);
            leak += s.2;
            n += 1.0;
        }
        // Without any blend of the frame before (2026-10-09 in Swift): soft 0.979, worst 0.972, hard 0.980, leak 0.011.
        assert!(soft / n > 0.97, "soft IoU {}", soft / n);
        assert!(worst > 0.96, "worst soft IoU {worst}");
        assert!(hard / n > 0.97, "hard IoU {}", hard / n);
        assert!(leak / n < 0.02, "leak {}", leak / n);
    }

    #[test]
    fn raw_segmentation_reference() {
        let mut shot = SwingShot::new();
        let mut soft = 0.0;
        for f in 0..48 {
            let fr = shot.frame(f);
            let id = fr.labels.label_at(Vec2::new(96.0 / 192.0, 60.0 / 108.0));
            if f > 0 {
                soft += matte_scores(&fr.labels.matte_of(&BTreeSet::from([id])), &SwingShot::truth(f)).0;
            }
        }
        assert!(soft / 47.0 > 0.9);
    }

    /// A frame's matte is that frame's own: the same picture gives the same matte whatever was tracked before it, so
    /// nothing trails a motion and forward and backward tracking agree.
    #[test]
    fn a_frame_matte_does_not_depend_on_the_frames_before() {
        let click = [MagicPoint { position: face(), subtract: false, source_time: Time::ZERO }];
        let mut shot = SwingShot::new();
        let frames: Vec<InstanceFrame> = (0..12).map(|f| shot.frame(f)).collect();
        let mut forward = MagicFollower::new(None);
        let mut up = Vec::new();
        for f in &frames {
            let Some(m) = forward.step(f, &click, None, 0.0) else { panic!("lost") };
            up.push(m);
        }
        let mut backward = MagicFollower::new(Some(up[11].clone()));
        for i in (0..12).rev() {
            let Some(m) = backward.step(&frames[i], &click, None, 0.0) else { panic!("lost at {i}") };
            assert!(m == up[i], "frame {i} differs by direction");
        }
    }
}
