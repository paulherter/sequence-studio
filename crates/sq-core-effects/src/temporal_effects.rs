// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TemporalEffects.swift
//! Temporal effects: Video Denoise and Deflicker read the clip's neighboring decoded source frames; Motion Blur smears
//! the clip's own motion (Motion, transform stages, keys) over a shutter window. Kinds, keys and catalog rows live in
//! `sq-core-model`; this module evaluates them.
//!
//! Frame history seam (one rule for playback, scrub and export): a layer whose `ClipEffects::temporal` is set asks for
//! the source frames `TemporalWindow::neighbours` names (sample indices either side of the shown frame, inside the clip's
//! source range, nearest first). Playback takes them from its byte-capped frame cache, export keeps them in a
//! `FrameHistory` bounded to the window. The renderer works with whatever subset arrived.

use crate::effect_transform_stage::{EffectTransformStage, MotionBlurSamples};
use sq_core_model::ClipEffect;
use sq_core_time::{Id, Time};
use std::collections::BTreeMap;
use std::ops::RangeInclusive;

/// How exact the temporal work must be. Export and a settled (paused) frame are `Exact`; playing and scrubbing are `Fast`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TemporalQuality {
    /// Full window and quality.
    Exact,
    /// Reduced window for playback and scrubbing.
    Fast,
}

/// Video Denoise: temporal average of the neighboring frames (motion-rejected), then a spatial edge-keeping smooth.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TemporalDenoise {
    /// Source frames used on each side of the shown one, 0...5.
    pub frames_each_side: i64,
    /// false = Fast (single-pixel difference), true = Best (patch difference, motion search).
    pub best: bool,
    /// Motion search radius step: 0 = small (none), 1 = medium, 2 = large. Only with `best`.
    pub motion_search: i64,
    /// Temporal strength 0...1 for luma.
    pub luma: f64,
    /// Temporal strength 0...1 for color.
    pub color: f64,
    /// 0...1: differences above the limit count as motion and are left alone (higher = more tolerant).
    pub motion_limit: f64,
    /// Spatial pass size: 0 = off, 1 small, 2 medium, 3 large.
    pub detail_size: i64,
    /// Spatial strength 0...1 for luma.
    pub spatial_luma: f64,
    /// Spatial strength 0...1 for color.
    pub spatial_color: f64,
    /// 0...1 share of the original frame mixed back in (keeps texture).
    pub keep_original: f64,
}

impl TemporalDenoise {
    /// A denoise with the Swift defaults for everything but the window.
    pub fn new(frames_each_side: i64) -> TemporalDenoise {
        TemporalDenoise {
            frames_each_side,
            best: false,
            motion_search: 1,
            luma: 0.4,
            color: 0.5,
            motion_limit: 0.5,
            detail_size: 0,
            spatial_luma: 0.0,
            spatial_color: 0.0,
            keep_original: 0.0,
        }
    }

    /// The temporal part does something.
    pub fn is_temporal(&self) -> bool {
        self.frames_each_side > 0 && (self.luma > 0.0 || self.color > 0.0)
    }

    /// The spatial part does something.
    pub fn is_spatial(&self) -> bool {
        self.detail_size > 0 && (self.spatial_luma > 0.0 || self.spatial_color > 0.0)
    }
}

/// Deflicker: each frame's brightness is scaled to the average brightness of the window around it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TemporalDeflicker {
    /// Frames averaged on each side of the shown one, 1...10.
    pub frames_each_side: i64,
    /// false = Fast (one gain for the whole frame), true = Best (a gain per region, regions that change too much
    /// between frames, i.e. motion, are not corrected).
    pub local: bool,
    /// 0...1 how much of the correction is applied.
    pub strength: f64,
}

impl TemporalDeflicker {
    /// A whole-frame deflicker at full strength unless told otherwise.
    pub fn new(frames_each_side: i64, local: bool, strength: f64) -> TemporalDeflicker {
        TemporalDeflicker { frames_each_side, local, strength }
    }
}

/// How an echo of Trails meets the picture: Add (sums, brightens), Screen (brightens softly), Lighten (the brighter wins).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrailBlend {
    /// Sums.
    Add = 0,
    /// Brightens softly.
    Screen = 1,
    /// The brighter one wins.
    Lighten = 2,
}

impl TrailBlend {
    /// Every case in raw order.
    pub const ALL: [TrailBlend; 3] = [TrailBlend::Add, TrailBlend::Screen, TrailBlend::Lighten];

    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<TrailBlend> {
        usize::try_from(raw).ok().and_then(|i| Self::ALL.get(i).copied())
    }
}

/// Trails (C4): `count` earlier source frames, `spacing` frames apart, laid over the shown one; echo k (1 = nearest) has
/// weight (1 - decay)^k. Runs after Denoise / Deflicker on the same decoded frames, before the color pipeline.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TemporalTrails {
    /// Echoes, 2...8.
    pub count: i64,
    /// Frames between two echoes, 1...3.
    pub spacing: i64,
    /// 0...1: share each echo loses against the one before it.
    pub decay: f64,
    /// How an echo meets the picture.
    pub blend: TrailBlend,
    /// The clip plays its source backwards here (reverse, or a reversed speed segment): the frames already seen lie ahead
    /// in source order, so the echoes are read from there. Set by `ClipEffectsEvaluation::effects`.
    pub backward: bool,
}

impl TemporalTrails {
    /// Echo counts a Trails effect accepts.
    pub const COUNT_RANGE: RangeInclusive<i64> = 2..=8;
    /// Echo spacings (frames) a Trails effect accepts.
    pub const SPACING_RANGE: RangeInclusive<i64> = 1..=3;
    /// The furthest frame back a trail reads (8 echoes x 3 frames): bounds the history export keeps.
    pub const MAX_REACH: i64 = 8 * 3;

    /// Clamps every value to its range.
    pub fn new(count: i64, spacing: i64, decay: f64, blend: TrailBlend) -> TemporalTrails {
        TemporalTrails {
            count: count.clamp(*Self::COUNT_RANGE.start(), *Self::COUNT_RANGE.end()),
            spacing: spacing.clamp(*Self::SPACING_RANGE.start(), *Self::SPACING_RANGE.end()),
            decay: if decay.is_nan() { 0.0 } else { decay.clamp(0.0, 1.0) },
            blend,
            backward: false,
        }
    }

    /// Frames back of each echo, nearest first.
    pub fn offsets(&self) -> Vec<i64> {
        (1..=self.count).map(|k| k * self.spacing).collect()
    }

    /// Weight of each echo, nearest first.
    pub fn weights(&self) -> Vec<f64> {
        let mut w = 1.0;
        (1..=self.count)
            .map(|_| {
                w *= 1.0 - self.decay;
                w
            })
            .collect()
    }

    /// Furthest frame back.
    pub fn reach(&self) -> i64 {
        self.count * self.spacing
    }
}

/// Evaluated Video Denoise + Deflicker + Trails of one layer at one instant (sibling of `FilmLook` inside
/// `ClipEffects`). The renderer runs it on the decoded source frame before the color pipeline and every other effect.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TemporalFilter {
    /// Video Denoise.
    pub denoise: Option<TemporalDenoise>,
    /// Deflicker.
    pub deflicker: Option<TemporalDeflicker>,
    /// Trails.
    pub trails: Option<TemporalTrails>,
}

impl TemporalFilter {
    /// Denoise frames each side while playing or scrubbing.
    pub const FAST_DENOISE_FRAMES: i64 = 1;
    /// Deflicker frames each side while playing or scrubbing.
    pub const FAST_DEFLICKER_FRAMES: i64 = 2;

    /// Nothing to do.
    pub fn is_identity(&self) -> bool {
        self.denoise.is_none() && self.deflicker.is_none() && self.trails.is_none()
    }

    /// Source frames Denoise / Deflicker need on each side of the shown one.
    pub fn radius(&self) -> i64 {
        let d = self.denoise.map_or(0, |d| if d.is_temporal() { d.frames_each_side } else { 0 });
        d.max(self.deflicker.map_or(0, |d| d.frames_each_side))
    }

    /// Source frames needed before the shown one (Trails look back, or ahead when `backward`).
    pub fn reach_back(&self) -> i64 {
        self.radius().max(self.trails.map_or(0, |t| if t.backward { 0 } else { t.reach() }))
    }

    /// Source frames needed after the shown one.
    pub fn reach_ahead(&self) -> i64 {
        self.radius().max(self.trails.map_or(0, |t| if t.backward { t.reach() } else { 0 }))
    }

    /// Fast mode (playback, scrub): denoise at most 1 frame each side, Fast quality, no motion search; deflicker at most 2
    /// frames each side, whole-frame gain. The spatial pass and the strengths stay (they cost little and keep the look).
    /// Trails stay as they are: they are the look, and cost one texture read per echo.
    pub fn degraded(&self, q: TemporalQuality) -> TemporalFilter {
        if q != TemporalQuality::Fast {
            return *self;
        }
        let mut f = *self;
        if let Some(mut d) = f.denoise {
            d.frames_each_side = d.frames_each_side.min(Self::FAST_DENOISE_FRAMES);
            d.best = false;
            d.motion_search = 0;
            f.denoise = Some(d);
        }
        if let Some(mut d) = f.deflicker {
            d.frames_each_side = d.frames_each_side.min(Self::FAST_DEFLICKER_FRAMES);
            d.local = false;
            f.deflicker = Some(d);
        }
        f
    }
}

/// Sample indices on each side of a shown frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Neighbours {
    /// Indices before the center, nearest first.
    pub before: Vec<i64>,
    /// Indices after the center, nearest first.
    pub after: Vec<i64>,
}

/// Which source frames a temporal filter reads around the shown one.
pub enum TemporalWindow {}

impl TemporalWindow {
    /// Sample indices on each side of `center`, nearest first, at most `radius` each, limited to `lower...upper` (the
    /// clip's first and last source frame, so a neighbor never comes from material cut away, which may be another shot).
    pub fn neighbours(center: i64, radius: i64, lower: i64, upper: i64) -> Neighbours {
        Self::neighbours_split(center, radius, radius, lower, upper)
    }

    /// As above with separate reaches (`TemporalFilter::reach_back` / `reach_ahead`).
    pub fn neighbours_split(center: i64, b: i64, a: i64, lower: i64, upper: i64) -> Neighbours {
        if center < lower || center > upper {
            return Neighbours::default();
        }
        let before = if b > 0 { (1..=b).map(|k| center - k).filter(|&i| i >= lower).collect() } else { Vec::new() };
        let after = if a > 0 { (1..=a).map(|k| center + k).filter(|&i| i <= upper).collect() } else { Vec::new() };
        Neighbours { before, after }
    }

    /// All indices of the window, oldest first (what a history must hold for `center`).
    pub fn span(center: i64, radius: i64, lower: i64, upper: i64) -> RangeInclusive<i64> {
        Self::span_split(center, radius, radius, lower, upper)
    }

    /// As above with separate reaches.
    pub fn span_split(center: i64, b: i64, a: i64, lower: i64, upper: i64) -> RangeInclusive<i64> {
        let n = Self::neighbours_split(center, b, a, lower, upper);
        n.before.last().copied().unwrap_or(center)..=n.after.last().copied().unwrap_or(center)
    }
}

/// Bounded store of decoded frames for temporal effects (export). Keyed by media and sample index; `keep` drops
/// everything outside the windows still needed, so it never holds more than the sum of the windows (at most 2 x 10 + 1
/// frames per window).
#[derive(Clone, Debug)]
pub struct FrameHistory<Frame> {
    frames: BTreeMap<(Id, i64), Frame>,
}

impl<Frame> Default for FrameHistory<Frame> {
    fn default() -> Self {
        FrameHistory { frames: BTreeMap::new() }
    }
}

impl<Frame> FrameHistory<Frame> {
    /// An empty history.
    pub fn new() -> FrameHistory<Frame> {
        FrameHistory::default()
    }

    /// Frames held.
    pub fn count(&self) -> usize {
        self.frames.len()
    }

    /// The frame of `media` at sample `index`.
    pub fn get(&self, media: Id, index: i64) -> Option<&Frame> {
        self.frames.get(&(media, index))
    }

    /// Stores (or, with `None`, drops) the frame of `media` at sample `index`.
    pub fn set(&mut self, media: Id, index: i64, frame: Option<Frame>) {
        match frame {
            Some(f) => {
                self.frames.insert((media, index), f);
            }
            None => {
                self.frames.remove(&(media, index));
            }
        }
    }

    /// Keeps only frames inside one of `windows` (per media); everything else is released.
    pub fn keep(&mut self, windows: &BTreeMap<Id, Vec<RangeInclusive<i64>>>) {
        self.frames.retain(|(media, index), _| windows.get(media).is_some_and(|w| w.iter().any(|r| r.contains(index))));
    }
}

/// Which side of the frame a Motion Blur shutter reaches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ShutterSide {
    /// Centered on the frame.
    Both = 0,
    /// From the previous frame to this one.
    FromPrevious = 1,
    /// From this frame toward the next.
    TowardNext = 2,
}

impl ShutterSide {
    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<ShutterSide> {
        match raw {
            0 => Some(ShutterSide::Both),
            1 => Some(ShutterSide::FromPrevious),
            2 => Some(ShutterSide::TowardNext),
            _ => None,
        }
    }
}

/// Motion Blur effect settings (the shutter window of the clip's own motion).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MotionBlurShutter {
    /// Shutter angle in degrees, 0...360 (Amount 100 = 360).
    pub angle: f64,
    /// Which side of the frame the shutter reaches.
    pub side: ShutterSide,
    /// Sample count factor: 0 coarse (half), 1 medium, 2 fine (double).
    pub smoothness: i64,
}

impl MotionBlurShutter {
    /// A centered shutter of medium smoothness.
    pub fn new(angle: f64) -> MotionBlurShutter {
        MotionBlurShutter { angle, side: ShutterSide::Both, smoothness: 1 }
    }

    /// Sub-frame samples: the shutter's own count scaled by the smoothness, 2...32.
    pub fn sample_count(&self) -> i64 {
        let n = EffectTransformStage::sample_count(self.angle);
        if n <= 0 {
            return 0;
        }
        match self.smoothness {
            0 => 2.max((n + 1) / 2),
            2 => 32.min(n * 2),
            _ => n,
        }
    }

    /// The shutter of an enabled Motion Blur effect at clip-local `t` (nil = none or amount 0); the last one wins.
    pub(crate) fn of(effects: &[ClipEffect], t: Time) -> Option<MotionBlurShutter> {
        let e = effects.iter().rev().find(|e| e.enabled && e.kind == ClipEffect::MOTION_BLUR_KIND)?;
        let amount = e.scalar(ClipEffect::AMOUNT_KEY, t);
        if amount <= 0.0 {
            return None;
        }
        Some(MotionBlurShutter {
            angle: amount.min(100.0) * 3.6,
            side: ShutterSide::from_raw(e.choice(ClipEffect::BLUR_DIRECTION_MODE_KEY, t)).unwrap_or(ShutterSide::Both),
            smoothness: e.choice(ClipEffect::SMOOTHNESS_KEY, t),
        })
    }
}

impl MotionBlurSamples {
    /// Samples kept while playing (`thinned`).
    pub const PLAYBACK_MAX_SAMPLES: usize = 8;

    /// At most `max_count` samples, spread evenly over the same window (first and last kept). Playback uses this while
    /// playing; paused frames and export keep every sample.
    pub fn thinned(&self, max_count: usize) -> MotionBlurSamples {
        let n = self.transforms.len();
        if max_count < 2 || n <= max_count {
            return self.clone();
        }
        let picks: Vec<usize> = (0..max_count)
            .map(|k| match k {
                0 => 0,
                k if k == max_count - 1 => n - 1,
                k => (k * (n - 1) + (max_count - 1) / 2) / (max_count - 1),
            })
            .collect();
        MotionBlurSamples {
            format: self.format.clone(),
            transforms: picks.iter().map(|&i| self.transforms[i]).collect(),
            local_times: picks.iter().filter_map(|&i| self.local_times.get(i).copied()).collect(),
        }
    }
}

/// Evaluation of the temporal effect kinds (Swift `extension ClipEffect`).
pub trait TemporalEffectEval {
    /// This effect's part of the temporal filter at clip-local `t` (Video Denoise / Deflicker / Trails), untouched when it
    /// does nothing.
    fn apply_temporal(&self, f: &mut TemporalFilter, t: Time);
}

impl TemporalEffectEval for ClipEffect {
    fn apply_temporal(&self, f: &mut TemporalFilter, t: Time) {
        // Scalars are sanitized (finite, inside the catalog range), so the rounding cannot overflow.
        let v = |key: &str| self.scalar(key, t);
        let int = |key: &str| v(key).round() as i64;
        match self.kind.as_str() {
            ClipEffect::VIDEO_DENOISE_KIND => {
                let d = TemporalDenoise {
                    frames_each_side: int(ClipEffect::FRAMES_EACH_SIDE_KEY),
                    best: self.choice(ClipEffect::QUALITY_KEY, t) == 1,
                    motion_search: self.choice(ClipEffect::MOTION_SEARCH_KEY, t),
                    luma: v(ClipEffect::LUMA_STRENGTH_KEY) / 100.0,
                    color: v(ClipEffect::COLOR_STRENGTH_KEY) / 100.0,
                    motion_limit: v(ClipEffect::MOTION_LIMIT_KEY) / 100.0,
                    detail_size: self.choice(ClipEffect::DETAIL_SIZE_KEY, t),
                    spatial_luma: v(ClipEffect::SPATIAL_LUMA_KEY) / 100.0,
                    spatial_color: v(ClipEffect::SPATIAL_COLOR_KEY) / 100.0,
                    keep_original: v(ClipEffect::KEEP_ORIGINAL_KEY) / 100.0,
                };
                f.denoise = if (d.is_temporal() || d.is_spatial()) && d.keep_original < 1.0 { Some(d) } else { None };
            }
            ClipEffect::DEFLICKER_KIND => {
                let s = v(ClipEffect::STRENGTH_KEY) / 100.0;
                f.deflicker = if s > 0.0 {
                    Some(TemporalDeflicker::new(
                        int(ClipEffect::FRAMES_EACH_SIDE_KEY),
                        self.choice(ClipEffect::ANALYSIS_KEY, t) == 1,
                        s,
                    ))
                } else {
                    None
                };
            }
            ClipEffect::TRAILS_KIND => {
                let blend = int(ClipEffect::TRAIL_BLEND_KEY).clamp(0, TrailBlend::ALL.len() as i64 - 1);
                let tr = TemporalTrails::new(
                    int(ClipEffect::TRAIL_COUNT_KEY),
                    int(ClipEffect::TRAIL_SPACING_KEY),
                    v(ClipEffect::TRAIL_DECAY_KEY) / 100.0,
                    TrailBlend::from_raw(blend).unwrap_or(TrailBlend::Screen),
                );
                f.trails = if tr.decay < 1.0 { Some(tr) } else { None };
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fast_mode_clamps_the_window_and_quality() {
        let f = TemporalFilter {
            denoise: Some(TemporalDenoise { best: true, motion_search: 2, ..TemporalDenoise::new(5) }),
            deflicker: Some(TemporalDeflicker::new(8, true, 1.0)),
            trails: None,
        };
        let fast = f.degraded(TemporalQuality::Fast);
        let d = fast.denoise.map(|d| (d.frames_each_side, d.best, d.motion_search));
        assert_eq!(d, Some((1, false, 0)));
        let k = fast.deflicker.map(|d| (d.frames_each_side, d.local));
        assert_eq!(k, Some((2, false)));
        assert_eq!(fast.radius(), 2);
        assert_eq!(f.degraded(TemporalQuality::Exact), f);
    }

    #[test]
    fn window_stays_inside_the_clips_source_frames() {
        let n = TemporalWindow::neighbours(10, 3, 8, 30);
        assert_eq!(n.before, vec![9, 8]);
        assert_eq!(n.after, vec![11, 12, 13]);
        assert_eq!(TemporalWindow::neighbours(10, 0, 0, 30), Neighbours::default());
        assert_eq!(TemporalWindow::span(30, 2, 0, 30), 28..=30);
    }

    #[test]
    fn history_keeps_only_the_needed_windows() {
        let a = Id::from_u128(1);
        let b = Id::from_u128(2);
        let mut h = FrameHistory::<i64>::new();
        for i in 0..20 {
            h.set(a, i, Some(i));
            h.set(b, i, Some(i));
        }
        let mut windows = BTreeMap::new();
        windows.insert(a, vec![TemporalWindow::span(10, 2, 0, 99)]);
        h.keep(&windows);
        assert_eq!(h.count(), 5);
        assert_eq!(h.get(a, 8), Some(&8));
        assert_eq!(h.get(a, 12), Some(&12));
        assert_eq!(h.get(a, 7), None);
        assert_eq!(h.get(b, 10), None);
    }

    #[test]
    fn trails_clamp_and_weigh_their_echoes() {
        let t = TemporalTrails::new(20, 0, 2.0, TrailBlend::Add);
        assert_eq!((t.count, t.spacing, t.decay), (8, 1, 1.0));
        let t = TemporalTrails::new(3, 2, 0.5, TrailBlend::Screen);
        assert_eq!(t.offsets(), vec![2, 4, 6]);
        assert_eq!(t.weights(), vec![0.5, 0.25, 0.125]);
        assert_eq!(t.reach(), 6);
    }
}
