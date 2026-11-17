// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Reframe.swift
//! Auto-Reframe planning: subject detections per sampled frame -> smoothed Position keys (and a cover Scale) that keep the
//! subject inside the target frame. Pure value logic; the Vision part sits behind `SubjectDetecting`.
use crate::analysis_turn::{CancelToken, Cancelled};
use sq_core_model::{AnimatedProperty, Clip};
use sq_core_time::{IdSource, Keyframe, KeyframeTrack, Time, Vec2};
use std::fmt;

/// Rectangle in normalized coordinates of the upright picture: 0...1, origin top-left, y down.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NormalizedRect {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl NormalizedRect {
    /// The middle.
    pub fn center(&self) -> Vec2 {
        Vec2::new(self.x + self.width / 2.0, self.y + self.height / 2.0)
    }

    /// Area, never negative.
    pub fn area(&self) -> f64 {
        self.width.max(0.0) * self.height.max(0.0)
    }
}

/// What kind of subject a box holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SubjectKind {
    /// Strongest signal: the camera keeps faces in frame first.
    Face,
    /// Human body (person detector).
    Body,
    /// Attention-based saliency (whatever the eye goes to), used when no person is found.
    Saliency,
}

impl SubjectKind {
    /// The raw string value.
    pub fn raw_value(self) -> &'static str {
        match self {
            SubjectKind::Face => "face",
            SubjectKind::Body => "body",
            SubjectKind::Saliency => "saliency",
        }
    }

    /// The case with this raw value.
    pub fn from_raw(raw: &str) -> Option<SubjectKind> {
        [SubjectKind::Face, SubjectKind::Body, SubjectKind::Saliency].into_iter().find(|k| k.raw_value() == raw)
    }
}

/// One detected subject.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubjectBox {
    /// What it is.
    pub kind: SubjectKind,
    /// Where it is.
    pub rect: NormalizedRect,
    /// 0...1.
    pub confidence: f64,
}

/// Detections of one sampled frame. `time` is clip-local (0 = the clip's first timeline frame), like keyframe times.
#[derive(Clone, Debug, PartialEq)]
pub struct FrameDetections {
    /// Clip-local time.
    pub time: Time,
    /// The subjects found.
    pub boxes: Vec<SubjectBox>,
}

/// Tuning of the planner.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReframeOptions {
    /// Seconds between analyzed frames (rounded to whole sequence frames, at least one).
    pub sample_interval: f64,
    /// Length of the moving average over the camera path, in seconds.
    pub smoothing_window: f64,
    /// The camera does not move while the subject stays within this fraction of the frame size of the current framing.
    pub dead_zone: f64,
    /// Keys are dropped while the linear path between the kept ones stays within this many sequence pixels.
    pub tolerance: f64,
    /// Detections below this confidence are ignored.
    pub min_confidence: f64,
    /// Extra zoom on top of the cover scale (1 = just fill the frame; values below 1 are clamped to 1).
    pub zoom: f64,
}

impl Default for ReframeOptions {
    fn default() -> Self {
        ReframeOptions {
            sample_interval: 0.2,
            smoothing_window: 1.0,
            dead_zone: 0.05,
            tolerance: 2.0,
            min_confidence: 0.3,
            zoom: 1.0,
        }
    }
}

// MARK: - Crop window

/// Where the picture sits in the frame. Compositor semantics (SQRender): position = offset of the anchor from the canvas
/// center in sequence px (y down), scale = sequence px per source px, anchor = offset from the picture center in source px.
/// Rotation is not considered (reframing a rotated clip keeps its rotation but frames as if it were 0).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReframeGeometry {
    /// Upright picture width (rotation applied), source px.
    pub picture_width: i64,
    /// Upright picture height, source px.
    pub picture_height: i64,
    /// Target frame (sequence) width.
    pub frame_width: i64,
    /// Target frame height.
    pub frame_height: i64,
    /// The anchor.
    pub anchor: Vec2,
    /// Extra zoom.
    pub zoom: f64,
}

impl ReframeGeometry {
    /// A geometry with the anchor at the picture center and no extra zoom.
    pub fn new(picture_width: i64, picture_height: i64, frame_width: i64, frame_height: i64) -> ReframeGeometry {
        ReframeGeometry { picture_width, picture_height, frame_width, frame_height, anchor: Vec2::ZERO, zoom: 1.0 }
    }

    /// Smallest scale at which the picture covers the frame on both axes, times `zoom` (>= 1).
    pub fn scale(&self) -> f64 {
        if self.picture_width <= 0 || self.picture_height <= 0 {
            return 1.0;
        }
        let cover = (self.frame_width as f64 / self.picture_width as f64)
            .max(self.frame_height as f64 / self.picture_height as f64);
        cover * (if self.zoom.is_finite() { self.zoom } else { 1.0 }).max(1.0)
    }

    /// The picture already fills the frame with nothing to spare (same shape, no extra zoom): the crop window cannot move.
    pub fn is_already_framed(&self) -> bool {
        let m = self.max_offset();
        m.x < 0.5 && m.y < 0.5
    }

    /// Largest |position| per axis at which the picture still covers the frame, for an anchor at the picture center.
    pub fn max_offset(&self) -> Vec2 {
        let s = self.scale();
        Vec2::new(
            ((self.picture_width as f64 * s - self.frame_width as f64) / 2.0).max(0.0),
            ((self.picture_height as f64 * s - self.frame_height as f64) / 2.0).max(0.0),
        )
    }

    /// Position range on one axis: the picture edges at `position + s * (±half - anchor)` must stay outside the frame.
    fn range(&self, max: f64, anchor: f64) -> (f64, f64) {
        let a = anchor * self.scale();
        (a - max, a + max)
    }

    /// Clamped position that puts the normalized picture point `p` in the frame center (as close as covering allows).
    pub fn position_centering(&self, p: Vec2) -> Vec2 {
        let s = self.scale();
        let src = Vec2::new((p.x - 0.5) * self.picture_width as f64, (p.y - 0.5) * self.picture_height as f64);
        self.clamp(Vec2::new(-s * (src.x - self.anchor.x), -s * (src.y - self.anchor.y)))
    }

    /// `v` limited to the positions at which the picture still covers the frame.
    pub fn clamp(&self, v: Vec2) -> Vec2 {
        let m = self.max_offset();
        let (xl, xh) = self.range(m.x, self.anchor.x);
        let (yl, yh) = self.range(m.y, self.anchor.y);
        Vec2::new(v.x.max(xl).min(xh), v.y.max(yl).min(yh))
    }
}

// MARK: - Focus point

/// The focus point of one frame.
pub struct ReframeFocus;

impl ReframeFocus {
    /// A body box is framed on its upper part (head and shoulders), this far down from its top.
    pub const BODY_HEAD_FRACTION: f64 = 0.25;

    /// Normalized point the camera should center for one frame: faces first, then bodies, then saliency; within the winning
    /// kind the area x confidence weighted center. `None` when nothing reaches `min_confidence`.
    pub fn focus(boxes: &[SubjectBox], min_confidence: f64) -> Option<Vec2> {
        let usable: Vec<&SubjectBox> =
            boxes.iter().filter(|b| b.confidence >= min_confidence && b.rect.area() > 0.0).collect();
        for kind in [SubjectKind::Face, SubjectKind::Body, SubjectKind::Saliency] {
            let group: Vec<&&SubjectBox> = usable.iter().filter(|b| b.kind == kind).collect();
            if group.is_empty() {
                continue;
            }
            let mut sum = Vec2::ZERO;
            let mut total = 0.0;
            for b in group {
                let w = b.rect.area() * b.confidence;
                sum = sum + Self::point(b) * w;
                total += w;
            }
            if total > 0.0 {
                return Some(sum * (1.0 / total));
            }
        }
        None
    }

    fn point(b: &SubjectBox) -> Vec2 {
        match b.kind {
            SubjectKind::Body => {
                Vec2::new(b.rect.x + b.rect.width / 2.0, b.rect.y + b.rect.height * Self::BODY_HEAD_FRACTION)
            }
            SubjectKind::Face | SubjectKind::Saliency => b.rect.center(),
        }
    }
}

// MARK: - Smoothing

/// The camera path filters.
pub struct ReframeSmoothing;

impl ReframeSmoothing {
    /// Missing points hold the last known one; leading gaps take the first known. `None` when no point is known.
    pub fn fill_gaps(pts: &[Option<Vec2>]) -> Option<Vec<Vec2>> {
        let first = pts.iter().find_map(|p| *p)?;
        let mut last = first;
        Some(
            pts.iter()
                .map(|p| {
                    if let Some(p) = p {
                        last = *p;
                    }
                    last
                })
                .collect(),
        )
    }

    /// Lazy camera: starts on the first point and moves only as far as needed to keep each point within `radius`.
    pub fn dead_zone(pts: &[Vec2], radius: Vec2) -> Vec<Vec2> {
        let Some(&first) = pts.first() else { return Vec::new() };
        fn follow(cam: f64, p: f64, r: f64) -> f64 {
            if p > cam + r {
                p - r
            } else if p < cam - r {
                p + r
            } else {
                cam
            }
        }
        let mut c = first;
        pts.iter()
            .map(|p| {
                c = Vec2::new(follow(c.x, p.x, radius.x), follow(c.y, p.y, radius.y));
                c
            })
            .collect()
    }

    /// Centered moving average of `2 * radius + 1` points; the window shrinks symmetrically at the ends, so the first and
    /// last points are kept as they are and a straight path stays straight.
    pub fn moving_average(pts: &[Vec2], radius: usize) -> Vec<Vec2> {
        if radius == 0 || pts.len() <= 2 {
            return pts.to_vec();
        }
        (0..pts.len())
            .map(|i| {
                let r = radius.min(i).min(pts.len() - 1 - i);
                if r == 0 {
                    return pts[i];
                }
                let mut s = Vec2::ZERO;
                for p in &pts[i - r..=i + r] {
                    s = s + *p;
                }
                s * (1.0 / (2 * r + 1) as f64)
            })
            .collect()
    }

    /// Ramer-Douglas-Peucker in time: indices of the points to keep so that linear interpolation between the kept points
    /// (by time) stays within `tolerance` of every dropped point. Always keeps the first and the last.
    pub fn simplify(times: &[f64], points: &[Vec2], tolerance: f64) -> Vec<usize> {
        let n = times.len().min(points.len());
        if n <= 2 {
            return (0..n).collect();
        }
        let mut keep = vec![false; n];
        keep[0] = true;
        keep[n - 1] = true;
        let mut stack = vec![(0, n - 1)];
        while let Some((a, b)) = stack.pop() {
            if b <= a + 1 {
                continue;
            }
            let mut worst = -1.0;
            let mut at = a;
            let span = times[b] - times[a];
            for k in a + 1..b {
                let f = if span > 0.0 { (times[k] - times[a]) / span } else { 0.0 };
                let lerp = points[a] + (points[b] - points[a]) * f;
                let d = (points[k] - lerp).length();
                if d > worst {
                    worst = d;
                    at = k;
                }
            }
            if worst > tolerance {
                keep[at] = true;
                stack.push((a, at));
                stack.push((at, b));
            }
        }
        (0..n).filter(|&i| keep[i]).collect()
    }
}

// MARK: - Planner

/// Result for one clip: what to write into Motion.
#[derive(Clone, Debug, PartialEq)]
pub struct ReframePlan {
    /// Uniform Scale (static).
    pub scale: f64,
    /// Position: static value, or keys at sample times (clip-local, linear).
    pub position: AnimatedProperty<Vec2>,
    /// Frames analyzed.
    pub samples: usize,
    /// Frames with a usable subject.
    pub detected_samples: usize,
}

/// Plans the camera path.
pub struct ReframePlanner;

impl ReframePlanner {
    /// `None` when no frame has a usable subject (the clip is then left alone). Key ids come from `ids`.
    pub fn plan(
        detections: &[FrameDetections],
        geometry: &ReframeGeometry,
        options: &ReframeOptions,
        ids: &mut dyn IdSource,
    ) -> Option<ReframePlan> {
        let mut sorted: Vec<&FrameDetections> = detections.iter().collect();
        sorted.sort_by_key(|d| d.time);
        let focus: Vec<Option<Vec2>> =
            sorted.iter().map(|d| ReframeFocus::focus(&d.boxes, options.min_confidence)).collect();
        let filled = ReframeSmoothing::fill_gaps(&focus)?;
        let targets: Vec<Vec2> = filled.iter().map(|p| geometry.position_centering(*p)).collect();
        let lazy = ReframeSmoothing::dead_zone(
            &targets,
            Vec2::new(
                options.dead_zone * geometry.frame_width as f64,
                options.dead_zone * geometry.frame_height as f64,
            ),
        );
        let seconds: Vec<f64> = sorted.iter().map(|d| d.time.value() as f64 / d.time.timescale() as f64).collect();
        let step = if seconds.len() > 1 {
            (seconds[seconds.len() - 1] - seconds[0]) / (seconds.len() - 1) as f64
        } else {
            0.0
        };
        let radius = if step > 0.0 { (options.smoothing_window / step / 2.0).round().max(0.0) as usize } else { 0 };
        let path: Vec<Vec2> =
            ReframeSmoothing::moving_average(&lazy, radius).into_iter().map(|p| geometry.clamp(p)).collect();
        let kept = ReframeSmoothing::simplify(&seconds, &path, options.tolerance);
        let detected = focus.iter().filter(|f| f.is_some()).count();
        let s = geometry.scale();
        if let (Some(&a), Some(&b)) = (kept.first(), kept.last())
            && kept.len() <= 2
            && (path[a] - path[b]).length() <= options.tolerance
        {
            return Some(ReframePlan {
                scale: s,
                position: AnimatedProperty::new(path[a]),
                samples: sorted.len(),
                detected_samples: detected,
            });
        }
        let keys: Vec<Keyframe<Vec2>> =
            kept.iter().map(|&i| Keyframe::new(ids.next_id(), sorted[i].time, path[i])).collect();
        let position = AnimatedProperty { value: path[*kept.first()?], track: KeyframeTrack::with_keys(keys) };
        Some(ReframePlan { scale: s, position, samples: sorted.len(), detected_samples: detected })
    }
}

// MARK: - Sampling

/// One analyzed frame: clip-local time (key time) and the source (media) time shown there.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReframeSample {
    /// Clip-local time.
    pub local: Time,
    /// Source time shown there.
    pub source: Time,
}

/// Which frames are analyzed.
pub struct ReframeSampling;

impl ReframeSampling {
    /// Every `interval` seconds (whole frames, at least one) from the clip's first frame, plus its last frame; source times
    /// through the clip's speed, reverse and time remapping.
    pub fn samples(clip: &Clip, fd: Time, interval: f64) -> Vec<ReframeSample> {
        let frames = clip.duration().frame_index(fd);
        if frames <= 0 {
            return Vec::new();
        }
        let fps = fd.timescale() as f64 / fd.value() as f64;
        let step = ((interval * fps).round() as i64).max(1);
        let mut locals: Vec<Time> = (0..frames).step_by(step as usize).map(|i| fd * i).collect();
        let last_frame = fd * (frames - 1);
        if locals.last() != Some(&last_frame) {
            locals.push(last_frame);
        }
        locals
            .into_iter()
            .map(|local| ReframeSample { local, source: clip.source_time(clip.start + local, fd) })
            .collect()
    }
}

// MARK: - Detection

/// Finds subjects in the frame shown at a source time. `VisionSubjectDetector` is the real one on the Mac; tests script their
/// own.
pub trait SubjectDetecting: Sync {
    /// What the detector can fail with.
    type Error;
    /// The subjects in the frame at `source_time`.
    fn subjects(&self, source_time: Time) -> Result<Vec<SubjectBox>, Self::Error>;
}

/// Why `ReframeAnalyzer::detect` stopped.
#[derive(Clone, Debug, PartialEq)]
pub enum DetectError<E> {
    /// The task was canceled (checked before each frame).
    Cancelled,
    /// The detector failed.
    Detector(E),
}

impl<E> From<Cancelled> for DetectError<E> {
    fn from(_: Cancelled) -> Self {
        DetectError::Cancelled
    }
}

impl<E: fmt::Display> fmt::Display for DetectError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DetectError::Cancelled => f.write_str("canceled"),
            DetectError::Detector(e) => e.fmt(f),
        }
    }
}

impl<E: fmt::Debug + fmt::Display> std::error::Error for DetectError<E> {}

/// Runs a detector over the samples.
pub struct ReframeAnalyzer;

impl ReframeAnalyzer {
    /// Runs `detector` on every sample in order. `progress` gets 0...1 after each frame. Fails with `Cancelled` when the
    /// token is canceled (checked before each frame).
    pub fn detect<D: SubjectDetecting>(
        samples: &[ReframeSample],
        detector: &D,
        progress: Option<&dyn Fn(f64)>,
        cancel: &CancelToken,
    ) -> Result<Vec<FrameDetections>, DetectError<D::Error>> {
        let mut out = Vec::with_capacity(samples.len());
        for (i, s) in samples.iter().enumerate() {
            cancel.check()?;
            let boxes = detector.subjects(s.source).map_err(DetectError::Detector)?;
            out.push(FrameDetections { time: s.local, boxes });
            if let Some(p) = progress {
                p((i + 1) as f64 / samples.len() as f64);
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{ClipSpeed, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};
    use std::sync::Mutex;

    fn near(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() <= eps
    }

    fn near_v(a: Vec2, b: Vec2, eps: f64) -> bool {
        near(a.x, b.x, eps) && near(a.y, b.y, eps)
    }

    fn face(cx: f64, cy: f64, size: f64, confidence: f64) -> SubjectBox {
        SubjectBox {
            kind: SubjectKind::Face,
            rect: NormalizedRect { x: cx - size / 2.0, y: cy - size / 2.0, width: size, height: size },
            confidence,
        }
    }

    fn rect_box(kind: SubjectKind, x: f64, y: f64, w: f64, h: f64, confidence: f64) -> SubjectBox {
        SubjectBox { kind, rect: NormalizedRect { x, y, width: w, height: h }, confidence }
    }

    /// 16:9 landscape picture into a 9:16 portrait frame.
    fn landscape_to_portrait() -> ReframeGeometry {
        ReframeGeometry::new(1920, 1080, 1080, 1920)
    }

    // MARK: geometry

    #[test]
    fn same_picture_shape_is_already_framed() {
        assert!(ReframeGeometry::new(3840, 2160, 1920, 1080).is_already_framed());
        let zoomed = ReframeGeometry { zoom: 1.5, ..ReframeGeometry::new(3840, 2160, 1920, 1080) };
        assert!(!zoomed.is_already_framed());
        assert!(!landscape_to_portrait().is_already_framed());
    }

    #[test]
    fn cover_scale_fills_the_frame_on_both_axes() {
        assert!(near(landscape_to_portrait().scale(), 1920.0 / 1080.0, 1e-6));
        let same = ReframeGeometry::new(3840, 2160, 1920, 1080);
        assert!(near(same.scale(), 0.5, 1e-6));
        assert!(near(ReframeGeometry { zoom: 1.5, ..same }.scale(), 0.75, 1e-6));
        // A zoom below 1 would show bars: clamped to 1.
        assert!(near(ReframeGeometry { zoom: 0.5, ..same }.scale(), 0.5, 1e-6));
    }

    #[test]
    fn centered_subject_needs_no_offset() {
        assert!(near_v(landscape_to_portrait().position_centering(Vec2::new(0.5, 0.5)), Vec2::ZERO, 1e-6));
    }

    #[test]
    fn off_center_subject_moves_the_picture_the_other_way() {
        let s = 1920.0 / 1080.0;
        // Subject a quarter of the width right of center: 480 source px, so the picture moves 480 * s left.
        assert!(near_v(
            landscape_to_portrait().position_centering(Vec2::new(0.75, 0.5)),
            Vec2::new(-480.0 * s, 0.0),
            1e-6
        ));
        assert!(near_v(
            landscape_to_portrait().position_centering(Vec2::new(0.25, 0.5)),
            Vec2::new(480.0 * s, 0.0),
            1e-6
        ));
    }

    #[test]
    fn position_is_clamped_so_the_picture_always_covers_the_frame() {
        let s = 1920.0 / 1080.0;
        let limit = (1920.0 * s - 1080.0) / 2.0;
        let g = landscape_to_portrait();
        assert!(near_v(g.max_offset(), Vec2::new(limit, 0.0), 1e-6));
        assert!(near_v(g.position_centering(Vec2::new(1.0, 0.0)), Vec2::new(-limit, 0.0), 1e-6));
        assert!(near_v(g.position_centering(Vec2::new(0.0, 1.0)), Vec2::new(limit, 0.0), 1e-6));
    }

    #[test]
    fn anchor_is_taken_into_account() {
        let mut g = landscape_to_portrait();
        g.anchor = Vec2::new(100.0, 0.0);
        let s = g.scale();
        // Point p lands at center + position + s * (p - anchor).
        assert!(near_v(g.position_centering(Vec2::new(0.75, 0.5)), Vec2::new(-(480.0 - 100.0) * s, 0.0), 1e-6));
        assert!(near_v(g.position_centering(Vec2::new(0.5, 0.5)), Vec2::new(100.0 * s, 0.0), 1e-6));
    }

    #[test]
    fn zoom_opens_the_vertical_axis() {
        let g = ReframeGeometry { zoom: 2.0, ..landscape_to_portrait() };
        assert!(g.max_offset().y > 0.0);
        assert!(g.position_centering(Vec2::new(0.5, 0.25)).y > 0.0);
    }

    // MARK: focus

    #[test]
    fn faces_win_over_bodies_and_saliency() {
        let boxes = [
            rect_box(SubjectKind::Saliency, 0.0, 0.0, 0.2, 0.2, 1.0),
            rect_box(SubjectKind::Body, 0.7, 0.2, 0.2, 0.6, 1.0),
            face(0.3, 0.4, 0.1, 0.9),
        ];
        let f = ReframeFocus::focus(&boxes, 0.3).expect("focus");
        assert!(near_v(f, Vec2::new(0.3, 0.4), 1e-6));
    }

    #[test]
    fn several_faces_give_their_weighted_center() {
        // Same size and confidence: plain midpoint.
        let f = ReframeFocus::focus(&[face(0.2, 0.5, 0.1, 0.9), face(0.6, 0.3, 0.1, 0.9)], 0.3).expect("focus");
        assert!(near_v(f, Vec2::new(0.4, 0.4), 1e-6));
        // Larger face pulls harder (area weight 4:1).
        let f = ReframeFocus::focus(&[face(0.2, 0.5, 0.2, 0.9), face(0.7, 0.5, 0.1, 0.9)], 0.3).expect("focus");
        assert!(near_v(f, Vec2::new(0.3, 0.5), 1e-6));
    }

    #[test]
    fn body_focuses_on_the_upper_part() {
        let b = rect_box(SubjectKind::Body, 0.4, 0.2, 0.2, 0.6, 0.8);
        let f = ReframeFocus::focus(&[b], 0.3).expect("focus");
        assert!(near_v(f, Vec2::new(0.5, 0.2 + 0.6 * ReframeFocus::BODY_HEAD_FRACTION), 1e-6));
    }

    #[test]
    fn saliency_uses_the_box_center() {
        let b = rect_box(SubjectKind::Saliency, 0.6, 0.2, 0.2, 0.4, 1.0);
        assert!(near_v(ReframeFocus::focus(&[b], 0.3).expect("focus"), Vec2::new(0.7, 0.4), 1e-6));
    }

    #[test]
    fn weak_detections_are_ignored() {
        assert!(ReframeFocus::focus(&[face(0.2, 0.2, 0.1, 0.1)], 0.3).is_none());
        assert!(ReframeFocus::focus(&[], 0.3).is_none());
        // A weak face does not hide a confident body.
        let b = rect_box(SubjectKind::Body, 0.4, 0.2, 0.2, 0.6, 0.9);
        assert_eq!(ReframeFocus::focus(&[face(0.1, 0.1, 0.1, 0.1), b], 0.3).expect("focus").x, 0.5);
    }

    // MARK: smoothing

    #[test]
    fn gaps_hold_the_last_known_point_and_the_start_takes_the_first() {
        let (a, b) = (Vec2::new(1.0, 1.0), Vec2::new(5.0, 5.0));
        assert_eq!(
            ReframeSmoothing::fill_gaps(&[None, Some(a), None, None, Some(b), None]),
            Some(vec![a, a, a, a, b, b])
        );
        assert_eq!(ReframeSmoothing::fill_gaps(&[None, None]), None);
        assert_eq!(ReframeSmoothing::fill_gaps(&[]), None);
    }

    #[test]
    fn dead_zone_swallows_jitter() {
        let pts = [
            Vec2::new(0.0, 0.0),
            Vec2::new(3.0, -2.0),
            Vec2::new(-4.0, 1.0),
            Vec2::new(2.0, 3.0),
            Vec2::new(-1.0, -4.0),
        ];
        let out = ReframeSmoothing::dead_zone(&pts, Vec2::new(5.0, 5.0));
        assert!(out.iter().all(|p| *p == Vec2::new(0.0, 0.0)));
    }

    #[test]
    fn dead_zone_follows_a_large_move_lazily() {
        let out = ReframeSmoothing::dead_zone(
            &[Vec2::new(0.0, 0.0), Vec2::new(20.0, 0.0), Vec2::new(20.0, 0.0)],
            Vec2::new(5.0, 5.0),
        );
        // The camera moves just enough to keep the target on the edge of the zone.
        assert_eq!(out, [Vec2::new(0.0, 0.0), Vec2::new(15.0, 0.0), Vec2::new(15.0, 0.0)]);
    }

    #[test]
    fn moving_average_keeps_constants_and_softens_a_step() {
        let flat = vec![Vec2::new(7.0, -3.0); 9];
        assert_eq!(ReframeSmoothing::moving_average(&flat, 2), flat);
        let step: Vec<Vec2> = (0..10).map(|i| Vec2::new(if i < 5 { 0.0 } else { 10.0 }, 0.0)).collect();
        let out = ReframeSmoothing::moving_average(&step, 2);
        assert!(out[0] == Vec2::new(0.0, 0.0) && out[out.len() - 1] == Vec2::new(10.0, 0.0));
        for i in 1..out.len() {
            assert!(out[i].x >= out[i - 1].x);
        }
        assert!(out[4].x > 0.0 && out[4].x < 10.0);
        assert_eq!(ReframeSmoothing::moving_average(&step, 0), step);
    }

    #[test]
    fn simplify_drops_points_on_a_straight_line() {
        let times: Vec<f64> = (0..10).map(f64::from).collect();
        let line: Vec<Vec2> = times.iter().map(|t| Vec2::new(t * 3.0, -t)).collect();
        assert_eq!(ReframeSmoothing::simplify(&times, &line, 0.5), [0, 9]);
    }

    #[test]
    fn simplify_keeps_a_corner() {
        let times: Vec<f64> = (0..9).map(f64::from).collect();
        let v: Vec<Vec2> =
            times.iter().map(|t| Vec2::new(if *t <= 4.0 { t * 10.0 } else { (8.0 - t) * 10.0 }, 0.0)).collect();
        assert_eq!(ReframeSmoothing::simplify(&times, &v, 0.5), [0, 4, 8]);
        assert_eq!(ReframeSmoothing::simplify(&[0.0], &[Vec2::new(1.0, 1.0)], 1.0), [0]);
        assert_eq!(ReframeSmoothing::simplify(&[], &[], 1.0), Vec::<usize>::new());
    }

    #[test]
    fn simplify_honours_the_tolerance() {
        let times: Vec<f64> = (0..5).map(f64::from).collect();
        let bump =
            [Vec2::new(0.0, 0.0), Vec2::new(1.0, 0.0), Vec2::new(2.0, 1.0), Vec2::new(3.0, 0.0), Vec2::new(4.0, 0.0)];
        assert_eq!(ReframeSmoothing::simplify(&times, &bump, 2.0), [0, 4]);
        assert!(ReframeSmoothing::simplify(&times, &bump, 0.5).contains(&2));
    }

    // MARK: sampling

    const FD: Time = Time::new(1, 30);

    fn clip(ids: &mut SequentialIds, source: TimeRange, start: Time) -> Clip {
        Clip::new(ids.next_id(), "a", ids.next_id(), TrackKind::Video, source, start)
    }

    #[test]
    fn samples_every_few_frames_and_the_last_frame() {
        let c = clip(&mut SequentialIds::default(), TimeRange::new(Time::new(10, 1), Time::new(2, 1)), Time::new(5, 1));
        let s = ReframeSampling::samples(&c, FD, 0.2);
        assert_eq!(s[0], ReframeSample { local: Time::ZERO, source: Time::new(10, 1) });
        assert!(s[1].local == Time::new(6, 30) && s[1].source == Time::new(10, 1) + Time::new(6, 30));
        assert_eq!(s[s.len() - 1].local, Time::new(59, 30));
        assert_eq!(s.len(), 11); // 0, 6, ..., 54 and 59
        assert!(s.windows(2).all(|w| w[0].local < w[1].local));
    }

    #[test]
    fn short_clip_still_gets_a_sample() {
        let c = clip(&mut SequentialIds::default(), TimeRange::new(Time::ZERO, Time::new(1, 30)), Time::ZERO);
        assert_eq!(ReframeSampling::samples(&c, FD, 0.2), [ReframeSample { local: Time::ZERO, source: Time::ZERO }]);
    }

    #[test]
    fn interval_below_one_frame_samples_every_frame() {
        let c = clip(&mut SequentialIds::default(), TimeRange::new(Time::ZERO, Time::new(5, 30)), Time::ZERO);
        assert_eq!(ReframeSampling::samples(&c, FD, 0.001).len(), 5);
    }

    #[test]
    fn follows_the_clip_speed() {
        let mut c = clip(&mut SequentialIds::default(), TimeRange::new(Time::ZERO, Time::new(4, 1)), Time::ZERO);
        c.speed = ClipSpeed::new(2, 1);
        let s = ReframeSampling::samples(&c, FD, 0.2);
        assert!(s[1].local == Time::new(6, 30) && s[1].source == Time::new(12, 30));
    }

    // MARK: planner

    fn detections(points: &[Option<Vec2>]) -> Vec<FrameDetections> {
        let step = Time::new(6, 30);
        points
            .iter()
            .enumerate()
            .map(|(i, p)| FrameDetections {
                time: step * i as i64,
                boxes: p.map(|p| vec![face(p.x, p.y, 0.1, 0.9)]).unwrap_or_default(),
            })
            .collect()
    }

    fn plan(points: &[Option<Vec2>]) -> Option<ReframePlan> {
        ReframePlanner::plan(
            &detections(points),
            &landscape_to_portrait(),
            &ReframeOptions::default(),
            &mut SequentialIds::default(),
        )
    }

    #[test]
    fn nothing_detected_gives_no_plan() {
        assert!(plan(&[None, None, None]).is_none());
        assert!(plan(&[]).is_none());
    }

    #[test]
    fn still_subject_gives_a_static_position() {
        let p = plan(&vec![Some(Vec2::new(0.7, 0.5)); 20]).expect("plan");
        assert!(!p.position.is_animated());
        assert!(near_v(p.position.value, landscape_to_portrait().position_centering(Vec2::new(0.7, 0.5)), 1e-6));
        assert!(near(p.scale, landscape_to_portrait().scale(), 1e-6));
        assert!(p.detected_samples == 20 && p.samples == 20);
    }

    #[test]
    fn jitter_inside_the_dead_zone_does_not_animate() {
        let jitter: Vec<Option<Vec2>> =
            (0..30).map(|i| Some(Vec2::new(0.6 + if i % 2 == 0 { 0.004 } else { -0.004 }, 0.5))).collect();
        assert!(!plan(&jitter).expect("plan").position.is_animated());
    }

    #[test]
    fn moving_subject_is_followed_with_few_smooth_keys() {
        // Subject walks from 30 % to 70 % of the width over 40 samples (8 s).
        let walk: Vec<Vec2> = (0..40).map(|i| Vec2::new(0.3 + 0.4 * f64::from(i) / 39.0, 0.5)).collect();
        let p = plan(&walk.iter().map(|v| Some(*v)).collect::<Vec<_>>()).expect("plan");
        let keys = &p.position.track.keys;
        let g = landscape_to_portrait();
        assert!(p.position.is_animated());
        assert!(keys.len() >= 2 && keys.len() < 20);
        assert!(keys[0].time == Time::ZERO && keys[keys.len() - 1].time == Time::new(6, 30) * 39);
        // The picture moves left as the subject walks right; never leaves the clamp.
        assert!(keys[0].value.x > keys[keys.len() - 1].value.x);
        for k in keys {
            assert!(k.value.x.abs() <= g.max_offset().x + 1e-9 && k.value.y == 0.0);
        }
        for w in keys.windows(2) {
            assert!(w[1].value.x <= w[0].value.x + 1e-9);
        }
        // The camera keeps the subject in frame: at the end it is within the dead zone of the target.
        let target = g.position_centering(walk[walk.len() - 1]);
        assert!((keys[keys.len() - 1].value.x - target.x).abs() <= ReframeOptions::default().dead_zone * 1080.0 + 1.0);
    }

    #[test]
    fn missing_detections_hold_the_camera() {
        let mut pts = vec![Some(Vec2::new(0.7, 0.5))];
        pts.extend(vec![None; 10]);
        let p = plan(&pts).expect("plan");
        assert!(!p.position.is_animated());
        assert!(p.detected_samples == 1 && p.samples == 11);
    }

    #[test]
    fn keys_are_sorted_on_sample_times() {
        let walk: Vec<Option<Vec2>> = (0..20).map(|i| Some(Vec2::new(if i < 10 { 0.2 } else { 0.8 }, 0.5))).collect();
        let p = plan(&walk).expect("plan");
        let times: Vec<Time> = detections(&walk).iter().map(|d| d.time).collect();
        for k in &p.position.track.keys {
            assert!(times.contains(&k.time));
        }
        assert_eq!(p.position.value, p.position.track.keys[0].value);
    }

    // MARK: analyzer

    /// Scripted detector: boxes per source time.
    struct FakeDetector {
        calls: Mutex<Vec<Time>>,
        script: fn(Time) -> Vec<SubjectBox>,
    }

    impl SubjectDetecting for FakeDetector {
        type Error = String;
        fn subjects(&self, t: Time) -> Result<Vec<SubjectBox>, String> {
            self.calls.lock().unwrap_or_else(|e| e.into_inner()).push(t);
            Ok((self.script)(t))
        }
    }

    #[test]
    fn detects_every_sample_in_order_and_reports_progress() {
        let samples: Vec<ReframeSample> =
            (0..5).map(|i| ReframeSample { local: Time::new(i, 10), source: Time::new(i + 100, 10) }).collect();
        let fake = FakeDetector {
            calls: Mutex::new(Vec::new()),
            script: |t| if t == Time::new(102, 10) { Vec::new() } else { vec![face(0.5, 0.5, 0.1, 0.9)] },
        };
        let progress = Mutex::new(Vec::<f64>::new());
        let report = |p: f64| progress.lock().unwrap_or_else(|e| e.into_inner()).push(p);
        let out = ReframeAnalyzer::detect(&samples, &fake, Some(&report), &CancelToken::new()).expect("detect");
        assert_eq!(out.iter().map(|d| d.time).collect::<Vec<_>>(), samples.iter().map(|s| s.local).collect::<Vec<_>>());
        assert!(out[2].boxes.is_empty() && out[0].boxes.len() == 1);
        assert_eq!(
            *fake.calls.lock().unwrap_or_else(|e| e.into_inner()),
            samples.iter().map(|s| s.source).collect::<Vec<_>>()
        );
        assert_eq!(progress.lock().unwrap_or_else(|e| e.into_inner()).last(), Some(&1.0));
    }

    #[test]
    fn cancellation_stops() {
        let samples: Vec<ReframeSample> =
            (0..50).map(|i| ReframeSample { local: Time::new(i, 10), source: Time::new(i, 10) }).collect();
        let fake = FakeDetector { calls: Mutex::new(Vec::new()), script: |_| Vec::new() };
        let token = CancelToken::new();
        token.cancel();
        assert_eq!(ReframeAnalyzer::detect(&samples, &fake, None, &token), Err(DetectError::Cancelled));
        assert!(fake.calls.lock().unwrap_or_else(|e| e.into_inner()).is_empty());
    }

    #[test]
    fn a_detector_error_stops_with_it() {
        struct Failing;
        impl SubjectDetecting for Failing {
            type Error = String;
            fn subjects(&self, _t: Time) -> Result<Vec<SubjectBox>, String> {
                Err("no frame".to_string())
            }
        }
        let samples = [ReframeSample { local: Time::ZERO, source: Time::ZERO }];
        let r = ReframeAnalyzer::detect(&samples, &Failing, None, &CancelToken::new());
        assert_eq!(r, Err(DetectError::Detector("no frame".to_string())));
    }
}
