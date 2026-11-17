// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Stabilizer.swift (`Stabilizer.effect`, the `ClipEffect` parameter helpers and `stabilizeSpec` wait on the
// effects crate, see NOTES.md; no serde coding of the analysis cache)
//! Stabilizer (pure maths). Picture analysis (SQAnalysis, Vision) measures how each frame's content moved against the
//! previous one (`CameraMotion`). Here those motions become the camera path (`CameraPose` per frame: where a point of the
//! first frame sits in frame k), the path is smoothed (Smooth) or replaced by one fixed pose (Locked), and each frame gets
//! the correction that moves its content from the real path onto the wanted one, scaled up just enough that the picture
//! still covers its own frame (auto scale; Smooth keeps that crop under `max_crop` by giving up correction where needed).
//! The corrections are written as keys of a `stabilize` effect, a transform stage: the compositor applies it to the
//! clip's own frame before Motion.
//!
//! Units: px of the upright source picture, offset from the picture center, y down; degrees clockwise on screen (the
//! rotation convention of `StageTransform`).

use crate::rolling_shutter::RollingShutterSample;
use crate::stabilizer_perspective::PerspectiveResidual;
use sq_core_model::{Affine2, AnimatedProperty, ClipEffect, StageTransform};
use sq_core_time::{IdSource, Keyframe, KeyframeTrack, Time, Vec2};
use std::collections::BTreeSet;
use std::ops::Range;

/// A stage with the given position, scale and rotation; the rest at their defaults.
fn stage(position: Vec2, scale: f64, rotation: f64) -> StageTransform {
    StageTransform { position, scale, rotation, ..StageTransform::IDENTITY }
}

/// A similarity pose: p -> e^logScale R(rotation) p + translation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraPose {
    /// Translation.
    pub translation: Vec2,
    /// Degrees, clockwise on screen.
    pub rotation: f64,
    /// Natural log of the scale.
    pub log_scale: f64,
}

impl CameraPose {
    /// No change.
    pub const IDENTITY: CameraPose = CameraPose { translation: Vec2::ZERO, rotation: 0.0, log_scale: 0.0 };

    /// A pose.
    pub fn new(translation: Vec2, rotation: f64, log_scale: f64) -> CameraPose {
        CameraPose { translation, rotation, log_scale }
    }

    /// The scale.
    pub fn scale(&self) -> f64 {
        self.log_scale.exp()
    }

    fn linear(&self) -> Affine2 {
        Affine2::rot_scale(self.rotation, self.scale(), self.scale())
    }

    /// The pose applied to `p`.
    pub fn apply(&self, p: Vec2) -> Vec2 {
        self.linear().linear(p) + self.translation
    }

    /// self after `o`: p -> self(o(p)). Rotations add (no wrapping), so a path stays continuous.
    pub fn after(&self, o: &CameraPose) -> CameraPose {
        CameraPose {
            translation: self.apply(o.translation),
            rotation: self.rotation + o.rotation,
            log_scale: self.log_scale + o.log_scale,
        }
    }

    /// The pose undone.
    pub fn inverse(&self) -> CameraPose {
        let inv = CameraPose { translation: Vec2::ZERO, rotation: -self.rotation, log_scale: -self.log_scale };
        CameraPose {
            translation: inv.apply(self.translation) * -1.0,
            rotation: -self.rotation,
            log_scale: -self.log_scale,
        }
    }

    /// Blend of two poses, `f` = 0 is `a`.
    pub fn lerp(a: &CameraPose, b: &CameraPose, f: f64) -> CameraPose {
        CameraPose {
            translation: a.translation + (b.translation - a.translation) * f,
            rotation: a.rotation + (b.rotation - a.rotation) * f,
            log_scale: a.log_scale + (b.log_scale - a.log_scale) * f,
        }
    }
}

/// How the content moved from one analyzed frame to the next: p_k = scale R(rotation) p_{k-1} + (dx, dy).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraMotion {
    /// Horizontal shift.
    pub dx: f64,
    /// Vertical shift.
    pub dy: f64,
    /// Degrees, clockwise on screen.
    pub rotation: f64,
    /// Scale factor.
    pub scale: f64,
}

impl CameraMotion {
    /// No motion.
    pub const IDENTITY: CameraMotion = CameraMotion { dx: 0.0, dy: 0.0, rotation: 0.0, scale: 1.0 };

    /// A motion.
    pub fn new(dx: f64, dy: f64, rotation: f64, scale: f64) -> CameraMotion {
        CameraMotion { dx, dy, rotation, scale }
    }

    /// The motion that takes content at pose `a` to pose `b` (b after a^-1).
    pub fn from_poses(a: &CameraPose, b: &CameraPose) -> CameraMotion {
        let m = b.after(&a.inverse());
        CameraMotion { dx: m.translation.x, dy: m.translation.y, rotation: m.rotation, scale: m.scale() }
    }

    /// The motion as a pose.
    pub fn pose(&self) -> CameraPose {
        CameraPose {
            translation: Vec2::new(self.dx, self.dy),
            rotation: if self.rotation.is_finite() { self.rotation } else { 0.0 },
            log_scale: if self.scale.is_finite() && self.scale > 0.0 { self.scale.ln() } else { 0.0 },
        }
    }
}

/// The result of analyzing one source range (cached per media file and range by SQAnalysis).
#[derive(Clone, Debug, PartialEq)]
pub struct StabilizationAnalysis {
    /// Bumped when the analysis changes so cached results are measured again.
    pub version: i64,
    /// Upright source picture width, px.
    pub picture_width: i64,
    /// Upright source picture height, px.
    pub picture_height: i64,
    /// Source time of every analyzed frame, ascending.
    pub frame_times: Vec<Time>,
    /// `motions[i]`: frame i-1 to frame i (`motions[0]` is the identity).
    pub motions: Vec<CameraMotion>,
    /// Frame indices where the picture could not be matched to the previous frame (a scene cut, a black frame): the
    /// camera path restarts there, so smoothing never runs across it (`motions[i]` of a cut is ignored). Ascending, > 0.
    pub cuts: Vec<usize>,
    /// How far `motions[i]` can be trusted, 0...1. Empty = all trusted. Below `Stabilizer::MIN_CONFIDENCE` the plan
    /// replaces the motion by its trusted neighbors (no correction of noise).
    pub confidence: Vec<f64>,
    /// `checks[i]`: frame i-1 to frame i measured by a second, independent registration, `None` where it could not
    /// measure. The plan's guard compares the shake before and after the correction with these. Empty = no guard.
    pub checks: Vec<Option<CameraMotion>>,
    /// `rolling[i]`: shift and scan-axis slope of frame i-1 to frame i for the rolling shutter option, `None` where it
    /// could not be measured. Empty = an analysis from before the option.
    pub rolling: Vec<Option<RollingShutterSample>>,
    /// How the sensor's rows lie in the upright picture, as the quarter turns the stored picture was rotated by (0...3).
    pub rolling_scan: i64,
    /// Seconds between two frames of the source as the analyzer received them (60 fps: 1/60), 0 = not known.
    pub source_frame_interval: f64,
    /// `perspective[i]`: what the homography of frame i-1 to frame i holds beyond `motions[i]` (the similarity), in
    /// picture px. Empty = no pair had any.
    pub perspective: Vec<PerspectiveResidual>,
}

impl StabilizationAnalysis {
    /// Bumped when the analysis changes so cached results are measured again.
    /// 3: per-frame confidence, independent check motions, cut detection beyond "no match".
    /// 4: cuts only where the two registrations do not agree.
    /// 5: camera motion and check in picture pixels on both axes for non-square pixels (anamorphic).
    /// 6: motions from tracked features at 720 px, every frame; confidence from the inlier ratio.
    /// 7: per-pair planar homography by RANSAC reduced to the camera similarity.
    /// 8: the residual perspective of each pair's homography is kept next to the camera similarity.
    pub const CURRENT_VERSION: i64 = 8;

    /// An analysis with the Swift initializer's defaults for the optional parts.
    pub fn new(picture_width: i64, picture_height: i64, frame_times: Vec<Time>, motions: Vec<CameraMotion>) -> Self {
        StabilizationAnalysis {
            version: Self::CURRENT_VERSION,
            picture_width,
            picture_height,
            frame_times,
            motions,
            cuts: Vec::new(),
            confidence: Vec::new(),
            checks: Vec::new(),
            rolling: Vec::new(),
            rolling_scan: 0,
            source_frame_interval: 0.0,
            perspective: Vec::new(),
        }
    }

    /// Sets the scan turns (reduced into 0...3) like the Swift initializer.
    pub fn with_rolling_scan(mut self, scan: i64) -> Self {
        self.rolling_scan = scan.rem_euclid(4);
        self
    }

    /// Sets the source frame interval; a value that is not a positive finite number is 0 (not known).
    pub fn with_source_frame_interval(mut self, seconds: f64) -> Self {
        self.source_frame_interval = if seconds.is_finite() && seconds > 0.0 { seconds } else { 0.0 };
        self
    }

    /// The sensor rows stand upright in the picture: the scan axis is x.
    pub fn rolling_scans_along_x(&self) -> bool {
        self.rolling_scan % 2 != 0
    }

    /// Confidence of `motions[i]` (1 when not measured): the stored one, raised to how well the independent check agrees
    /// with the motion (`check_agreement`). Two independent registrations that agree are not noise, whatever the inlier
    /// ratio says.
    pub fn confidence_at(&self, i: usize) -> f64 {
        let stored = self.stored_confidence(i);
        if stored >= 1.0 { stored } else { stored.max(self.check_agreement(i)) }
    }

    /// The feature confidence of `motions[i]` as measured (1 when not measured), without the check's vote.
    pub fn stored_confidence(&self, i: usize) -> f64 {
        self.confidence.get(i).copied().unwrap_or(1.0)
    }

    /// 0...1: how well `checks[i]` agrees with `motions[i]` (0 without a check). RMS difference of the two at the four
    /// half-way-to-the-corner points, px per 512 px of the long side: 1 within `Stabilizer::FULL_AGREEMENT`, 0 from
    /// `Stabilizer::FULL_DISAGREEMENT`.
    pub fn check_agreement(&self, i: usize) -> f64 {
        if i >= self.checks.len() || i >= self.motions.len() {
            return 0.0;
        }
        let Some(c) = self.checks[i] else { return 0.0 };
        let (w, h) = (self.picture_width as f64, self.picture_height as f64);
        if !(w > 0.0 && h > 0.0) {
            return 0.0;
        }
        let (a, b) = (self.motions[i].pose(), c.pose());
        let mut s = 0.0_f64;
        for q in [
            Vec2::new(-w / 4.0, -h / 4.0),
            Vec2::new(w / 4.0, -h / 4.0),
            Vec2::new(w / 4.0, h / 4.0),
            Vec2::new(-w / 4.0, h / 4.0),
        ] {
            let d = a.apply(q) - b.apply(q);
            s += d.x * d.x + d.y * d.y;
        }
        let d = (s / 4.0).sqrt() * 512.0 / w.max(h);
        if !d.is_finite() {
            return 0.0;
        }
        ((Stabilizer::FULL_DISAGREEMENT - d) / (Stabilizer::FULL_DISAGREEMENT - Stabilizer::FULL_AGREEMENT))
            .clamp(0.0, 1.0)
    }

    /// The analyzed frame nearest to source time `t` (ties to the later one); 0 when there are none.
    pub fn index_nearest(&self, t: Time) -> usize {
        if self.frame_times.is_empty() {
            return 0;
        }
        let (mut lo, mut hi) = (0, self.frame_times.len()); // first index with frameTimes[i] >= t
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.frame_times[mid] < t {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if lo == 0 {
            return 0;
        }
        if lo == self.frame_times.len() {
            return self.frame_times.len() - 1;
        }
        let before = t - self.frame_times[lo - 1];
        let after = self.frame_times[lo] - t;
        if after <= before { lo } else { lo - 1 }
    }

    /// Seconds from the first to the last analyzed frame.
    pub(crate) fn seconds(&self) -> f64 {
        let (Some(a), Some(b)) = (self.frame_times.first(), self.frame_times.last()) else { return 0.0 };
        let d = *b - *a;
        d.value() as f64 / d.timescale() as f64
    }
}

/// What the Stabilizer does with the shot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StabilizerMode {
    /// Keeps the camera's intended movement, removes the shake.
    Smooth = 0,
    /// Holds the first framing still, as on a tripod.
    Locked = 1,
    /// Holds the framing when the shot is a still one (shake only, no intended movement), else keeps the movement.
    Auto = 2,
}

impl StabilizerMode {
    /// The stored index.
    pub fn from_raw(i: i64) -> Option<StabilizerMode> {
        match i {
            0 => Some(StabilizerMode::Smooth),
            1 => Some(StabilizerMode::Locked),
            2 => Some(StabilizerMode::Auto),
            _ => None,
        }
    }
}

/// What fills the border the Crop Limit leaves uncovered (stored as the index of the Edge Fill choice; never reorder).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StabilizerEdgeFill {
    /// The planned zoom hides the border (up to the Crop Limit): the clip transform, as before the option existed.
    Zoom = 0,
    /// The picture is mirrored back over its own edge.
    Mirror = 1,
    /// The mirrored picture, blurred wide where it reaches past the edge.
    Blur = 2,
}

impl StabilizerEdgeFill {
    /// Display name.
    pub fn title(self) -> &'static str {
        match self {
            StabilizerEdgeFill::Zoom => "Zoom",
            StabilizerEdgeFill::Mirror => "Mirror Edge",
            StabilizerEdgeFill::Blur => "Blur Edge",
        }
    }

    /// The stored index.
    pub fn from_raw(i: i64) -> Option<StabilizerEdgeFill> {
        match i {
            0 => Some(StabilizerEdgeFill::Zoom),
            1 => Some(StabilizerEdgeFill::Mirror),
            2 => Some(StabilizerEdgeFill::Blur),
            _ => None,
        }
    }
}

/// The settings of one plan.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StabilizerOptions {
    /// Which engine. The plan below is the Standard one; a Gyroflow Stabilizer is never planned here.
    pub method: crate::stabilize_effect::StabilizerMethod,
    /// Result.
    pub mode: StabilizerMode,
    /// Smooth: how long a wobble is still removed (Gaussian sigma), seconds.
    pub smoothness: f64,
    /// How much of the correction is applied, 0...1 (1 = all; the correction pose is blended with no correction).
    pub strength: f64,
    /// Smooth: most of each picture side the auto scale may cut away (0.08 = scale at most 1 / 0.92).
    pub max_crop: f64,
    /// What fills the border the crop limit leaves open. Mirror and Blur lower the plan's zoom, so it is part of the plan.
    pub edge_fill: StabilizerEdgeFill,
    /// Locked: the same cap; a shot that would need more shows its edges on the frames that do.
    pub max_locked_crop: f64,
    /// The guard keeps a segment's correction only below this checked shake ratio (after / before). Not stored on the
    /// effect; infinity turns the guard off (diagnostics).
    pub guard_limit: f64,
    /// Straighten the lean a rolling sensor adds while the camera moves.
    pub rolling_shutter: bool,
    /// How much of the measured shear is taken out, % (100 = the measured readout time).
    pub rolling_shutter_strength: f64,
}

impl Default for StabilizerOptions {
    fn default() -> Self {
        StabilizerOptions {
            method: crate::stabilize_effect::StabilizerMethod::Standard,
            mode: StabilizerMode::Smooth,
            smoothness: 0.5,
            strength: 1.0,
            max_crop: 0.08,
            edge_fill: StabilizerEdgeFill::Zoom,
            max_locked_crop: 0.3,
            guard_limit: Stabilizer::GUARD_RATIO,
            rolling_shutter: false,
            rolling_shutter_strength: 100.0,
        }
    }
}

impl StabilizerOptions {
    /// The settings stored on a Stabilizer effect (defaults for missing values).
    pub fn from_effect(e: &ClipEffect) -> StabilizerOptions {
        use crate::stabilize_effect::ClipEffectStabilizeExt;
        let mut o = StabilizerOptions { method: e.stabilize_method(), ..StabilizerOptions::default() };
        let v = |k: &str| e.parameters.get(k).map(|p| p.value);
        if let Some(m) = v(Stabilizer::MODE_KEY) {
            o.mode = StabilizerMode::from_raw(m.round() as i64).unwrap_or(StabilizerMode::Smooth);
        }
        if let Some(s) = v(Stabilizer::SMOOTHNESS_KEY).filter(|s| s.is_finite() && *s > 0.0) {
            o.smoothness = s;
        }
        if let Some(t) = v(Stabilizer::STRENGTH_KEY).filter(|t| t.is_finite()) {
            o.strength = t.clamp(0.0, 100.0) / 100.0;
        }
        if let Some(c) = v(Stabilizer::MAX_CROP_KEY).filter(|c| c.is_finite()) {
            o.max_crop = c.clamp(0.0, 50.0) / 100.0;
        }
        o.edge_fill = e.stabilize_edge_fill();
        if let Some(r) = v(Stabilizer::ROLLING_SHUTTER_KEY) {
            o.rolling_shutter = r >= 0.5;
        }
        if let Some(s) = v(Stabilizer::ROLLING_SHUTTER_STRENGTH_KEY).filter(|s| s.is_finite()) {
            o.rolling_shutter_strength = s.clamp(0.0, 200.0);
        }
        o
    }

    /// True when a clip planned with `other` needs no new plan for these options: they differ at most in what the
    /// renderer applies by itself (Rolling Shutter Strength scales the stored shear).
    pub fn same_plan_as(&self, other: &StabilizerOptions) -> bool {
        let mut a = *self;
        let mut b = *other;
        a.rolling_shutter_strength = 100.0;
        b.rolling_shutter_strength = 100.0;
        a == b
    }
}

/// Which parts of the measured camera motion a segment's correction follows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StabilizationModel {
    /// Move, turn and zoom.
    Similarity,
    /// Move and turn (the measured zoom is left out).
    Rigid,
    /// Move only.
    Translation,
}

impl StabilizationModel {
    pub(crate) fn reduce(self, m: &CameraMotion) -> CameraMotion {
        match self {
            StabilizationModel::Similarity => *m,
            StabilizationModel::Rigid => CameraMotion::new(m.dx, m.dy, m.rotation, 1.0),
            StabilizationModel::Translation => CameraMotion::new(m.dx, m.dy, 0.0, 1.0),
        }
    }
}

/// The correction for every analyzed frame.
#[derive(Clone, Debug, PartialEq)]
pub struct StabilizationPlan {
    /// Stage per analyzed frame (auto scale included), anchor at the picture center.
    pub corrections: Vec<StageTransform>,
    /// The auto scale (>= 1).
    pub zoom: f64,
    /// Every frame covers its picture at `zoom` (false only for Locked shots that move too far).
    pub fully_covered: bool,
    /// Frames left without correction (only the shared zoom) because their segment was mostly untrusted or the guard
    /// measured more shake after the correction than before. All frames = the shot is not stabilized (warn).
    pub uncorrected_frames: usize,
    /// Per segment: checked shake after / before the correction (the guard's measure; -1 = too few checks).
    pub checked_shake_ratios: Vec<f64>,
    /// Per segment: which parts of the measured motion were corrected (chosen with the checks).
    pub models: Vec<StabilizationModel>,
    /// Per analyzed frame: the residual perspective correction (smoothed, Strength applied). Empty = none.
    pub perspective: Vec<PerspectiveResidual>,
    /// Per analyzed frame: share of the output pixels whose source falls outside the picture at `zoom` (0 = covered).
    /// Perspective residuals are not counted (similarity only, as Swift Stabilizer.swift:305).
    pub uncovered: Vec<f64>,
}

impl StabilizationPlan {
    /// Share of each picture side cut away by the auto scale.
    pub fn crop(&self) -> f64 {
        1.0 - 1.0 / self.zoom
    }
}

/// The Stabilizer maths.
pub struct Stabilizer;

/// Binary search for the first index with `ts[i] > t` and the blend factor towards the next analyzed frame, like
/// `Stabilizer.correction`. `Held(i)`: use frame i as it is.
pub(crate) enum FramePick {
    Empty,
    Held(usize),
    Between(usize, f64),
}

pub(crate) fn pick_frame(ts: &[Time], n: usize, cuts: &[usize], t: Time) -> FramePick {
    if n == 0 {
        return FramePick::Empty;
    }
    let (mut lo, mut hi) = (0, n); // first index with ts[i] > t
    while lo < hi {
        let mid = (lo + hi) / 2;
        if ts[mid] <= t {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo == 0 {
        return FramePick::Held(0);
    }
    let i = lo - 1;
    if i == n - 1 || ts[i] == t || cuts.contains(&(i + 1)) {
        return FramePick::Held(i);
    }
    let span = ts[i + 1] - ts[i];
    let into = t - ts[i];
    let f = into.value() as f64 / into.timescale() as f64 / (span.value() as f64 / span.timescale() as f64);
    if !(f.is_finite() && f > 0.0) {
        return FramePick::Held(i);
    }
    FramePick::Between(i, f)
}

impl Stabilizer {
    /// Stored parameter key (never rename).
    pub const STRENGTH_KEY: &'static str = "stabilizeStrength";
    /// Stored parameter key.
    pub const EDGE_FILL_KEY: &'static str = "edgeFill";
    /// Stored parameter key.
    pub const MODE_KEY: &'static str = "stabilizeMode";
    /// Stored parameter key.
    pub const SMOOTHNESS_KEY: &'static str = "smoothness";
    /// Stored parameter key.
    pub const MAX_CROP_KEY: &'static str = "maxCrop";
    /// The source range (seconds) the analysis measured, to notice a clip trimmed beyond it.
    pub const FROM_KEY: &'static str = "analysedFrom";
    /// See `FROM_KEY`.
    pub const TO_KEY: &'static str = "analysedTo";
    /// Stored parameter key of the rolling shutter option.
    pub const ROLLING_SHUTTER_KEY: &'static str = "rollingShutter";
    /// Stored parameter key.
    pub const ROLLING_SHUTTER_STRENGTH_KEY: &'static str = "rollingShutterStrength";

    /// Most of a frame Mirror / Blur Edge may have to invent (share of output pixels); the zoom is lowered to this.
    pub const EDGE_FILL_TOLERANCE: f64 = 0.01;
    /// Auto holds a shot whose path stays within this share of the half picture around its middle.
    pub(crate) const STILL_LIMIT: f64 = 0.12;
    /// A simpler model replaces the fuller one only when its checked shake ratio is below this share of the fuller one's
    /// (near ties keep the full correction: the check's own noise pulls ratios together).
    pub const SIMPLER_MODEL_GAIN: f64 = 0.9;
    /// Motions below this confidence are not used as measured (`trusted_motions`).
    pub const MIN_CONFIDENCE: f64 = 0.5;
    /// Motion and check agree within this (px per 512 px of the long side): full confidence.
    pub const FULL_AGREEMENT: f64 = 0.5;
    /// From here no agreement; so trusted (`MIN_CONFIDENCE`) up to 1 px per 512.
    pub const FULL_DISAGREEMENT: f64 = 1.5;
    /// A segment with fewer trusted motions than this share is corrected only when the guard measures less shake after;
    /// without a verdict it is left uncorrected.
    pub const MIN_CONFIDENT_SHARE: f64 = 0.5;
    /// The guard keeps a correction only when the checked shake after is below this share of before. Above 1 because the
    /// check's own noise pulls every ratio towards 1 (a ratio near 1 means "cannot tell").
    pub const GUARD_RATIO: f64 = 1.25;
    /// Fewer checked pairs in a segment than this: no verdict, the correction stays.
    pub const GUARD_MIN_PAIRS: usize = 10;
    /// Trusted motions averaged on each side of an untrusted stretch (the camera's steady movement there).
    pub(crate) const FALLBACK_NEIGHBOURS: usize = 10;
    /// Largest error of the stored keys against the full per-frame correction: source px.
    pub const POSITION_TOLERANCE: f64 = 0.1;
    /// Largest error of the stored keys: degrees.
    pub const ROTATION_TOLERANCE: f64 = 0.01;
    /// Largest error of the stored keys: scale (1 = 100 %).
    pub const SCALE_TOLERANCE: f64 = 0.0005;

    /// Absolute poses: path[k] = motions[k] after ... after motions[0].
    pub fn path(motions: &[CameraMotion]) -> Vec<CameraPose> {
        let mut out = Vec::with_capacity(motions.len());
        let mut p = CameraPose::IDENTITY;
        for m in motions {
            p = m.pose().after(&p);
            out.push(p);
        }
        out
    }

    /// Gaussian smoothing with odd reflection at the ends: the first and last values stay, a straight line stays straight.
    pub fn gaussian_smooth(xs: &[f64], sigma: f64) -> Vec<f64> {
        let n = xs.len();
        if !(n > 2 && sigma.is_finite() && sigma > 0.0) {
            return xs.to_vec();
        }
        let r = ((3.0 * sigma).ceil() as usize).min(n - 1);
        if r == 0 {
            return xs.to_vec();
        }
        let w: Vec<f64> = (0..=r).map(|k| (-((k * k) as f64) / (2.0 * sigma * sigma)).exp()).collect();
        let total = w[0] + 2.0 * w[1..].iter().fold(0.0, |a, b| a + b);
        let at = |i: i64| -> f64 {
            if i < 0 {
                return 2.0 * xs[0] - xs[((-i) as usize).min(n - 1)];
            }
            if i >= n as i64 {
                return 2.0 * xs[n - 1] - xs[((2 * (n as i64 - 1) - i).max(0)) as usize];
            }
            xs[i as usize]
        };
        (0..n)
            .map(|i| {
                let mut s = w[0] * xs[i];
                for (k, wk) in w.iter().enumerate().skip(1) {
                    s += wk * (at(i as i64 - k as i64) + at(i as i64 + k as i64));
                }
                s / total
            })
            .collect()
    }

    #[doc(hidden)]
    pub fn smooth(poses: &[CameraPose], sigma: f64) -> Vec<CameraPose> {
        let tx = Self::gaussian_smooth(&poses.iter().map(|p| p.translation.x).collect::<Vec<_>>(), sigma);
        let ty = Self::gaussian_smooth(&poses.iter().map(|p| p.translation.y).collect::<Vec<_>>(), sigma);
        let r = Self::gaussian_smooth(&poses.iter().map(|p| p.rotation).collect::<Vec<_>>(), sigma);
        let s = Self::gaussian_smooth(&poses.iter().map(|p| p.log_scale).collect::<Vec<_>>(), sigma);
        (0..poses.len()).map(|i| CameraPose::new(Vec2::new(tx[i], ty[i]), r[i], s[i])).collect()
    }

    /// RMS of the second differences: frame-to-frame shake of a point's track (a steady pan scores 0).
    pub fn jitter(pts: &[Vec2]) -> f64 {
        if pts.len() <= 2 {
            return 0.0;
        }
        let mut s = 0.0_f64;
        for i in 1..pts.len() - 1 {
            let d = pts[i + 1] - pts[i] * 2.0 + pts[i - 1];
            s += d.x * d.x + d.y * d.y;
        }
        (s / (pts.len() - 2) as f64).sqrt()
    }

    /// Smallest zoom z (1...cap) at which `z` after correction `c` still covers the picture (half sizes hw, hh) at every
    /// output corner; `None` when even `cap` does not.
    pub(crate) fn required_zoom(c: &CameraPose, hw: f64, hh: f64, cap: f64) -> Option<f64> {
        let inv = c.inverse();
        let covers = |z: f64| -> bool {
            for q in [Vec2::new(-hw, -hh), Vec2::new(hw, -hh), Vec2::new(hw, hh), Vec2::new(-hw, hh)] {
                let s = inv.apply(q * (1.0 / z));
                if s.x.abs() > hw * (1.0 + 1e-12) || s.y.abs() > hh * (1.0 + 1e-12) {
                    return false;
                }
            }
            true
        };
        if covers(1.0) {
            return Some(1.0);
        }
        if !covers(cap) {
            return None;
        }
        let (mut lo, mut hi) = (1.0_f64, cap);
        for _ in 0..50 {
            let mid = (lo + hi) / 2.0;
            if covers(mid) {
                hi = mid;
            } else {
                lo = mid;
            }
        }
        Some(hi)
    }

    /// Share of the output (half sizes hw, hh) whose source lies outside the picture when correction `c` is followed by
    /// `zoom`: the picture's quad `zoom * c(corner)` is clipped to the output rectangle (Sutherland-Hodgman).
    pub(crate) fn uncovered_fraction(c: &CameraPose, zoom: f64, hw: f64, hh: f64) -> f64 {
        let mut poly: Vec<Vec2> = [Vec2::new(-hw, -hh), Vec2::new(hw, -hh), Vec2::new(hw, hh), Vec2::new(-hw, hh)]
            .iter()
            .map(|q| c.apply(*q) * zoom)
            .collect();
        // Each clip edge: keep points with sign * coordinate <= bound.
        for (axis_x, sign, bound) in [(true, 1.0, hw), (true, -1.0, hw), (false, 1.0, hh), (false, -1.0, hh)] {
            let d = |p: Vec2| sign * (if axis_x { p.x } else { p.y }) - bound;
            let mut out: Vec<Vec2> = Vec::new();
            for i in 0..poly.len() {
                let (a, b) = (poly[i], poly[(i + 1) % poly.len()]);
                let (da, db) = (d(a), d(b));
                if da <= 0.0 {
                    out.push(a);
                }
                if (da < 0.0 && db > 0.0) || (da > 0.0 && db < 0.0) {
                    out.push(a + (b - a) * (da / (da - db)));
                }
            }
            poly = out;
            if poly.is_empty() {
                return 1.0;
            }
        }
        let mut area = 0.0_f64;
        for i in 0..poly.len() {
            let (a, b) = (poly[i], poly[(i + 1) % poly.len()]);
            area += a.x * b.y - b.x * a.y;
        }
        (1.0 - area.abs() / 2.0 / (4.0 * hw * hh)).clamp(0.0, 1.0)
    }

    /// The plan for `analysis`; `None` with fewer than two frames or no picture size.
    pub fn plan(analysis: &StabilizationAnalysis, options: &StabilizerOptions) -> Option<StabilizationPlan> {
        let n = analysis.motions.len().min(analysis.frame_times.len());
        if !(n >= 2 && analysis.picture_width > 0 && analysis.picture_height > 0) {
            return None;
        }
        // Scene cuts split the shot: each segment is its own camera path (starting at the identity pose) and is smoothed
        // or locked on its own, so nothing is averaged across a cut.
        let mut bounds = vec![0_usize];
        bounds.extend(analysis.cuts.iter().copied().filter(|c| *c > 0 && *c < n).collect::<BTreeSet<_>>());
        bounds.push(n);
        let segments: Vec<Range<usize>> = (0..bounds.len() - 1).map(|i| bounds[i]..bounds[i + 1]).collect();
        // Low-confidence motions are replaced by their trusted neighbors (`trusted_motions`). A segment that is mostly
        // untrusted keeps the measured motions as they are and is corrected only when the guard measures it gets steadier.
        let measured = Self::trusted_motions(analysis, &segments);
        let doubtful: Vec<bool> = segments
            .iter()
            .map(|r| {
                (r.clone().skip(1).filter(|k| analysis.confidence_at(*k) >= Self::MIN_CONFIDENCE).count() as f64)
                    < Self::MIN_CONFIDENT_SHARE * (r.len().saturating_sub(1).max(1)) as f64
            })
            .collect();
        let mut skip = vec![false; segments.len()];
        let hw = analysis.picture_width as f64 / 2.0;
        let hh = analysis.picture_height as f64 / 2.0;
        let mode = if options.mode == StabilizerMode::Auto {
            if Self::is_still(&measured, &segments, hw, hh) { StabilizerMode::Locked } else { StabilizerMode::Smooth }
        } else {
            options.mode
        };
        let strength = options.strength.clamp(0.0, 1.0);
        let crop = if mode == StabilizerMode::Locked { options.max_locked_crop } else { options.max_crop };
        let limit = 1.0 / (1.0 - crop.clamp(0.0, 0.9));
        // The keys only follow the exact correction within the tolerances (`effect`), which can move the picture edge up
        // to `slack` px inwards at a corner; the zoom gets that much extra, kept inside the crop limit.
        let diagonal = (hw * hw + hh * hh).sqrt();
        let slack = Self::POSITION_TOLERANCE * 2.0_f64.sqrt()
            + diagonal * (Self::SCALE_TOLERANCE + limit * Self::ROTATION_TOLERANCE * std::f64::consts::PI / 180.0);
        let margin = 1.0 + slack / hw.min(hh);
        let cap = limit / margin;
        let seconds = analysis.seconds();
        let fps = if seconds > 0.0 { (n - 1) as f64 / seconds } else { 30.0 };
        let sigma = options.smoothness.max(0.0) * fps;
        // Bilateral motion width: path differences beyond ~15% of the long half-side count as an intended move.
        let motion_sigma = hw.max(hh) * 0.15;
        // Corrections (no zoom) for one segment's motions `ms` (`ms[0]` ignored).
        let corrections = |ms: &[CameraMotion]| -> Vec<CameraPose> {
            let mut ms = ms.to_vec();
            ms[0] = CameraMotion::IDENTITY;
            let real = Self::path(&ms);
            let m = ms.len();
            let correction = |wanted: &CameraPose, k: usize| -> CameraPose { wanted.after(&real[k].inverse()) };
            match mode {
                StabilizerMode::Locked | StabilizerMode::Auto => {
                    // Camera Lock: one pose for the segment (middle of the translation range = smallest largest
                    // correction, mean turn/scale). A frame that cannot hold it within the crop limit falls back to the
                    // smoothed path, and where even that does not fit, to the real path.
                    let xs: Vec<f64> = real.iter().map(|p| p.translation.x).collect();
                    let ys: Vec<f64> = real.iter().map(|p| p.translation.y).collect();
                    let (min, max) = (f64::min, f64::max);
                    let mid = CameraPose::new(
                        Vec2::new(
                            (xs.iter().copied().fold(f64::INFINITY, min)
                                + xs.iter().copied().fold(f64::NEG_INFINITY, max))
                                / 2.0,
                            (ys.iter().copied().fold(f64::INFINITY, min)
                                + ys.iter().copied().fold(f64::NEG_INFINITY, max))
                                / 2.0,
                        ),
                        real.iter().fold(0.0, |a, p| a + p.rotation) / m as f64,
                        real.iter().fold(0.0, |a, p| a + p.log_scale) / m as f64,
                    );
                    // Crop-aware: the pose is then searched for the smallest zoom the whole segment needs to hold it.
                    let fixed = Self::lock_pose(&real, mid, hw * 0.05, &|p, k| {
                        Self::required_zoom(&correction(p, k), hw, hh, cap)
                    });
                    let soft = Self::bilateral_smooth(&real, sigma, motion_sigma, diagonal);
                    let fits = |p: &CameraPose, k: usize| Self::required_zoom(&correction(p, k), hw, hh, cap).is_some();
                    let give_way = |from: &CameraPose, to: &CameraPose, k: usize| -> CameraPose {
                        if fits(from, k) {
                            return *from;
                        }
                        let (mut lo, mut hi) = (0.0_f64, 1.0_f64);
                        for _ in 0..30 {
                            let mid = (lo + hi) / 2.0;
                            if fits(&CameraPose::lerp(from, to, mid), k) {
                                hi = mid;
                            } else {
                                lo = mid;
                            }
                        }
                        CameraPose::lerp(from, to, hi)
                    };
                    (0..real.len())
                        .map(|k| {
                            let w = if fits(&fixed, k) {
                                fixed
                            } else {
                                give_way(&fixed, if fits(&soft[k], k) { &soft[k] } else { &real[k] }, k)
                            };
                            correction(
                                &CameraPose::lerp(&real[k], if fits(&w, k) { &w } else { &real[k] }, strength),
                                k,
                            )
                        })
                        .collect()
                }
                StabilizerMode::Smooth => {
                    let quad = Self::adaptive_quadratic_path(&real, sigma, 40, &|p, k| {
                        Self::required_zoom(&correction(p, k), hw, hh, cap).is_some()
                    });
                    // L1 crop path: the straightest path in the crop tube of the least zoom that is no more jittery
                    // than `quad`.
                    let w = Self::l1_crop_path(&real, &quad, hw, hh, &|p, k| {
                        Self::required_zoom(&correction(p, k), hw, hh, cap)
                    });
                    (0..real.len()).map(|i| correction(&CameraPose::lerp(&real[i], &w[i], strength), i)).collect()
                }
            }
        };

        // Per segment: the full similarity correction, and (when the checks can judge it) the same without the measured
        // zoom, and without zoom and turn. The check, independent of Vision's noise, picks the model that leaves the
        // least shake.
        let mut raw: Vec<CameraPose> = Vec::with_capacity(n);
        let mut models: Vec<StabilizationModel> = Vec::new();
        let mut ratios: Vec<f64> = Vec::new();
        for (i, seg) in segments.iter().enumerate() {
            let mut ms: Vec<CameraMotion> =
                if doubtful[i] { analysis.motions[seg.clone()].to_vec() } else { measured[seg.clone()].to_vec() };
            let first = corrections(&ms);
            let first_ratio = Self::checked_shake_ratio(&first, &analysis.checks, seg, hw, hh);
            let mut best: (StabilizationModel, Vec<CameraPose>, Option<f64>) =
                (StabilizationModel::Similarity, first, first_ratio);
            // Untrusted frames in a trusted segment: their own motion is dropped for the neighbors' mean, so their part of
            // the shake stays in. The motions as measured are tried too and kept when the checks see clearly less shake.
            if !doubtful[i]
                && let Some(fallback) = best.2.filter(|f| *f > 0.0)
                && analysis.motions[seg.clone()] != ms[..]
            {
                let as_measured = analysis.motions[seg.clone()].to_vec();
                let c = corrections(&as_measured);
                if let Some(r) = Self::checked_shake_ratio(&c, &analysis.checks, seg, hw, hh)
                    && r < fallback * Self::SIMPLER_MODEL_GAIN
                {
                    ms = as_measured;
                    best = (StabilizationModel::Similarity, c, Some(r));
                }
            }
            if best.2.is_some_and(|full| full > 0.0) {
                for model in [StabilizationModel::Rigid, StabilizationModel::Translation] {
                    let reduced: Vec<CameraMotion> = ms.iter().map(|m| model.reduce(m)).collect();
                    let c = corrections(&reduced);
                    if let Some(r) = Self::checked_shake_ratio(&c, &analysis.checks, seg, hw, hh)
                        && best.2.is_some_and(|b| r < b * Self::SIMPLER_MODEL_GAIN)
                    {
                        best = (model, c, Some(r));
                    }
                }
            }
            raw.extend(best.1.iter().copied());
            models.push(best.0);
            let r = best.2;
            ratios.push(r.unwrap_or(-1.0));
            if doubtful[i] {
                if !r.is_some_and(|r| r < options.guard_limit.min(1.0)) {
                    skip[i] = true;
                }
            } else if let Some(r) = r
                && !matches!(r.partial_cmp(&options.guard_limit), Some(std::cmp::Ordering::Less))
            {
                skip[i] = true;
            }
        }
        let mut uncorrected = 0;
        for (i, seg) in segments.iter().enumerate() {
            if skip[i] {
                for k in seg.clone() {
                    raw[k] = CameraPose::IDENTITY;
                }
                uncorrected += seg.len();
            }
        }
        let (mut zoom, mut covered) = (1.0_f64, true);
        for c in &raw {
            if let Some(z) = Self::required_zoom(c, hw, hh, cap) {
                zoom = zoom.max(z);
            } else {
                zoom = cap;
                covered = false;
            }
        }
        // Mirror / Blur Edge fill what the zoom would hide: the zoom drops to the least at which no frame leaves more than
        // `EDGE_FILL_TOLERANCE` of its pixels open (never below 1, never above the covering zoom).
        if options.edge_fill != StabilizerEdgeFill::Zoom && zoom > 1.0 {
            let worst = |z: f64| -> f64 {
                raw.iter()
                    .map(|c| Self::uncovered_fraction(c, z, hw, hh))
                    .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))))
                    .unwrap_or(0.0)
            };
            if worst(1.0) > Self::EDGE_FILL_TOLERANCE {
                let (mut lo, mut hi) = (1.0_f64, zoom);
                for _ in 0..40 {
                    let mid = (lo + hi) / 2.0;
                    if worst(mid) <= Self::EDGE_FILL_TOLERANCE {
                        hi = mid;
                    } else {
                        lo = mid;
                    }
                }
                zoom = hi;
            } else {
                zoom = 1.0;
            }
        }
        if zoom > 1.0 {
            zoom *= margin; // zoom 1 = no correction anywhere: nothing for the keys to miss
        }
        let stages: Vec<StageTransform> = raw
            .iter()
            .map(|c| {
                let z = CameraPose::new(Vec2::ZERO, 0.0, zoom.ln()).after(c);
                let identity = z.translation.x.abs() < 1e-9
                    && z.translation.y.abs() < 1e-9
                    && z.rotation.abs() < 1e-9
                    && z.log_scale.abs() < 1e-12;
                if identity { StageTransform::IDENTITY } else { stage(z.translation, z.scale(), z.rotation) }
            })
            .collect();
        let uncovered: Vec<f64> = raw.iter().map(|c| Self::uncovered_fraction(c, zoom, hw, hh)).collect();
        let perspective = Self::perspective_corrections(
            analysis,
            n,
            &segments,
            &skip,
            mode == StabilizerMode::Locked,
            sigma,
            strength,
        );
        Some(StabilizationPlan {
            corrections: stages,
            zoom,
            fully_covered: covered,
            uncorrected_frames: uncorrected,
            checked_shake_ratios: ratios,
            models,
            perspective,
            uncovered,
        })
    }

    /// True when every segment's camera stays within a small part of the picture around its middle pose: a still shot with
    /// shake only, which Auto holds like a tripod. A pan, a walk or a drift moves the path beyond it.
    pub(crate) fn is_still(motions: &[CameraMotion], segments: &[Range<usize>], hw: f64, hh: f64) -> bool {
        let reach = (hw * hw + hh * hh).sqrt();
        for seg in segments.iter().filter(|s| s.len() > 1) {
            let mut ms = motions[seg.clone()].to_vec();
            ms[0] = CameraMotion::IDENTITY;
            let real = Self::path(&ms);
            let xs: Vec<f64> = real.iter().map(|p| p.translation.x).collect();
            let ys: Vec<f64> = real.iter().map(|p| p.translation.y).collect();
            let (min, max) = (f64::min, f64::max);
            let mid = CameraPose::new(
                Vec2::new(
                    (xs.iter().copied().fold(f64::INFINITY, min) + xs.iter().copied().fold(f64::NEG_INFINITY, max))
                        / 2.0,
                    (ys.iter().copied().fold(f64::INFINITY, min) + ys.iter().copied().fold(f64::NEG_INFINITY, max))
                        / 2.0,
                ),
                real.iter().fold(0.0, |a, p| a + p.rotation) / real.len() as f64,
                real.iter().fold(0.0, |a, p| a + p.log_scale) / real.len() as f64,
            );
            if real.iter().any(|p| Self::path_distance(p, &mid, reach * 0.5) > Self::STILL_LIMIT * hw.min(hh)) {
                return false;
            }
        }
        true
    }

    /// The measured motions with every low-confidence one replaced by the camera's steady movement around it: the mean of
    /// up to `FALLBACK_NEIGHBOURS` trusted motions before and after the stretch, blended across it (one side only at a
    /// segment end; identity when the segment has none). Single neighbors would carry their own shake into the stretch as
    /// a fake pan.
    pub(crate) fn trusted_motions(a: &StabilizationAnalysis, segments: &[Range<usize>]) -> Vec<CameraMotion> {
        let take = segments.last().map_or(0, |s| s.end).min(a.motions.len());
        let mut out: Vec<CameraMotion> = a.motions[..take].to_vec();
        if a.confidence.is_empty() {
            return out;
        }
        let mean = |ks: &[usize]| -> Option<CameraMotion> {
            if ks.is_empty() {
                return None;
            }
            let mut m = CameraMotion::new(0.0, 0.0, 0.0, 0.0);
            for k in ks {
                let x = a.motions[*k];
                m.dx += x.dx;
                m.dy += x.dy;
                m.rotation += x.rotation;
                m.scale += x.scale.ln();
            }
            let c = ks.len() as f64;
            Some(CameraMotion::new(m.dx / c, m.dy / c, m.rotation / c, (m.scale / c).exp()))
        };
        for seg in segments {
            let trusted: Vec<usize> = seg
                .clone()
                .skip(1)
                .filter(|k| a.confidence_at(*k) >= Self::MIN_CONFIDENCE && a.motions[*k].scale > 0.0)
                .collect();
            if trusted.len() >= seg.len().saturating_sub(1) {
                continue;
            }
            let mut k = seg.start + 1;
            while k < seg.end {
                if a.confidence_at(k) >= Self::MIN_CONFIDENCE {
                    k += 1;
                    continue;
                }
                let mut end = k;
                while end < seg.end && a.confidence_at(end) < Self::MIN_CONFIDENCE {
                    end += 1; // stretch k..<end
                }
                let split = trusted.iter().position(|t| *t > k).unwrap_or(trusted.len());
                let left = mean(&trusted[split.saturating_sub(Self::FALLBACK_NEIGHBOURS)..split]);
                let right = mean(&trusted[split..(split + Self::FALLBACK_NEIGHBOURS).min(trusted.len())]);
                for (j, slot) in out.iter_mut().enumerate().take(end).skip(k) {
                    *slot = match (left, right) {
                        (Some(l), Some(r)) => {
                            let t = (j - k + 1) as f64 / (end - k + 1) as f64;
                            CameraMotion::new(
                                l.dx + (r.dx - l.dx) * t,
                                l.dy + (r.dy - l.dy) * t,
                                l.rotation + (r.rotation - l.rotation) * t,
                                (l.scale.ln() + (r.scale.ln() - l.scale.ln()) * t).exp(),
                            )
                        }
                        (Some(l), None) => l,
                        (None, Some(r)) => r,
                        (None, None) => CameraMotion::IDENTITY,
                    };
                }
                k = end;
            }
        }
        out
    }

    /// Variance of the frame-to-frame motion of four points (half way to the corners), summed: the residual shake measure.
    pub(crate) fn shake(ms: &[CameraPose], hw: f64, hh: f64) -> f64 {
        if ms.len() <= 1 {
            return 0.0;
        }
        let mut total = 0.0_f64;
        for q in [
            Vec2::new(-hw / 2.0, -hh / 2.0),
            Vec2::new(hw / 2.0, -hh / 2.0),
            Vec2::new(hw / 2.0, hh / 2.0),
            Vec2::new(-hw / 2.0, hh / 2.0),
        ] {
            let d: Vec<Vec2> = ms.iter().map(|p| p.apply(q) - q).collect();
            let mut mean = Vec2::ZERO;
            for v in &d {
                mean = mean + *v;
            }
            mean = mean * (1.0 / d.len() as f64);
            let mut s = 0.0_f64;
            for v in &d {
                let e = *v - mean;
                s += e.x * e.x + e.y * e.y;
            }
            total += s / (d.len() - 1) as f64;
        }
        total
    }

    /// The guard's measure for one segment: shake after the segment's corrections `raw` (no zoom; `raw[0]` is frame
    /// `seg.start`) / before, as the checks see it; `None` when there are too few checks to tell.
    pub(crate) fn checked_shake_ratio(
        raw: &[CameraPose],
        checks: &[Option<CameraMotion>],
        seg: &Range<usize>,
        hw: f64,
        hh: f64,
    ) -> Option<f64> {
        let (mut before, mut after): (Vec<CameraPose>, Vec<CameraPose>) = (Vec::new(), Vec::new());
        let o = seg.start;
        for k in seg.clone().skip(1).filter(|k| *k < checks.len()) {
            let Some(t) = checks[k] else { continue };
            let tp = t.pose();
            before.push(tp);
            // What the viewer sees from frame k-1 to k: C_k after T_k after C_{k-1}^-1.
            after.push(raw[k - o].after(&tp).after(&raw[k - 1 - o].inverse()));
        }
        if before.len() < Self::GUARD_MIN_PAIRS {
            return None;
        }
        let (b, a) = (Self::shake(&before, hw, hh), Self::shake(&after, hw, hh));
        Some(if b > 0.0 {
            a / b
        } else if a > 0.0 {
            f64::INFINITY
        } else {
            1.0
        })
    }

    /// The correction at source time `t`: the analyzed frame's own, linear between two analyzed frames (high frame rates
    /// are analyzed at about 30 fps), held before the first / after the last and across a cut (the earlier shot's).
    pub fn correction(plan: &StabilizationPlan, analysis: &StabilizationAnalysis, t: Time) -> StageTransform {
        let cs = &plan.corrections;
        let n = cs.len().min(analysis.frame_times.len());
        match pick_frame(&analysis.frame_times, n, &analysis.cuts, t) {
            FramePick::Empty => StageTransform::IDENTITY,
            FramePick::Held(i) => cs[i],
            FramePick::Between(i, f) => {
                let (a, b) = (cs[i], cs[i + 1]);
                stage(
                    a.position + (b.position - a.position) * f,
                    (a.scale.ln() + (b.scale.ln() - a.scale.ln()) * f).exp(),
                    a.rotation + (b.rotation - a.rotation) * f,
                )
            }
        }
    }

    /// One value per frame (`fd` apart from 0) as linear keys within `tolerance` of every value; a constant (no keys)
    /// when every value is within `tolerance` of the first.
    pub fn decimated_property(
        v: &[f64],
        frame_duration: Time,
        tolerance: f64,
        ids: &mut dyn IdSource,
    ) -> AnimatedProperty<f64> {
        let Some(first) = v.first().copied() else { return AnimatedProperty::new(0.0) };
        // Constant only when the constant itself is within tolerance everywhere (RDP's two end keys alone can still hide
        // up to twice the tolerance between them).
        if !v.iter().any(|x| (x - first).abs() > tolerance) {
            return AnimatedProperty::new(first);
        }
        let times: Vec<f64> = (0..v.len()).map(|i| i as f64).collect();
        let kept = Self::decimate(&times, v, tolerance);
        let mut p = AnimatedProperty::new(first);
        p.track = KeyframeTrack::with_keys(
            kept.iter().map(|&i| Keyframe::new(ids.next_id(), frame_duration * i as i64, v[i])).collect(),
        );
        p
    }

    /// Ramer-Douglas-Peucker on one value track: indices to keep (always the first and the last) so that linear
    /// interpolation between kept samples stays within `tolerance` of every dropped one.
    pub fn decimate(times: &[f64], values: &[f64], tolerance: f64) -> Vec<usize> {
        let n = times.len().min(values.len());
        if n <= 2 {
            return (0..n).collect();
        }
        let mut keep = vec![false; n];
        keep[0] = true;
        keep[n - 1] = true;
        let mut stack = vec![(0_usize, n - 1)];
        while let Some((a, b)) = stack.pop() {
            if b <= a + 1 {
                continue;
            }
            let span = times[b] - times[a];
            let va = values[a];
            let dv = values[b] - values[a];
            let (mut worst, mut at) = (-1.0_f64, None);
            for k in a + 1..b {
                let f = if span > 0.0 { (times[k] - times[a]) / span } else { 0.0 };
                let d = (va + dv * f - values[k]).abs();
                if d > worst {
                    worst = d;
                    at = Some(k);
                }
            }
            if let (true, Some(at)) = (worst > tolerance, at) {
                keep[at] = true;
                stack.push((a, at));
                stack.push((at, b));
            }
        }
        (0..n).filter(|i| keep[*i]).collect()
    }
}
