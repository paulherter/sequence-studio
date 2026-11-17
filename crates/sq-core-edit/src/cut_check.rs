// Swift: CutCheck.swift
//! Pure cut-quality analysis of a sequence: jump cuts with unchanged framing, gaps, captions in the platform UI zone,
//! audio joins without a fade, plus shot-length statistics.

use crate::timeline_markers::TimelineMarkersExt;
use sq_core_model::{CaptionItem, Clip, FadeKeys, Marker, MarkerColor, Timeline, Track, TrackKind};
use sq_core_time::{IdSource, Time, TimeRange};
use std::collections::BTreeSet;

/// Platforms with a UI overlay safe zone (mirrors the export presets).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CutCheckPlatform {
    /// TikTok.
    Tiktok,
    /// Instagram Reels.
    Reels,
    /// YouTube Shorts.
    Shorts,
}

impl CutCheckPlatform {
    /// Every platform.
    pub const ALL: [CutCheckPlatform; 3] = [Self::Tiktok, Self::Reels, Self::Shorts];

    /// Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Tiktok => "tiktok",
            Self::Reels => "reels",
            Self::Shorts => "shorts",
        }
    }

    /// Display name.
    pub fn title(self) -> &'static str {
        match self {
            Self::Tiktok => "TikTok",
            Self::Reels => "Reels",
            Self::Shorts => "Shorts",
        }
    }
}

/// Rectangle in frame-relative units: origin top-left, all values 0...1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NormRect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl NormRect {
    /// True when `o` lies inside this rectangle, give or take 0.001.
    pub fn contains(&self, o: &NormRect) -> bool {
        self.contains_within(o, 0.001)
    }

    /// True when `o` lies inside this rectangle, give or take `e`.
    pub fn contains_within(&self, o: &NormRect, e: f64) -> bool {
        o.x >= self.x - e
            && o.y >= self.y - e
            && o.x + o.width <= self.x + self.width + e
            && o.y + o.height <= self.y + self.height + e
    }
}

/// Insets (fractions of the frame) that platform UI (username, buttons, progress bar) covers on a 9:16 video.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SafeZone {
    /// Top inset.
    pub top: f64,
    /// Bottom inset.
    pub bottom: f64,
    /// Left inset.
    pub left: f64,
    /// Right inset.
    pub right: f64,
}

impl SafeZone {
    /// The clear rectangle inside the insets.
    pub fn rect(&self) -> NormRect {
        NormRect {
            x: self.left,
            y: self.top,
            width: 1.0 - self.left - self.right,
            height: 1.0 - self.top - self.bottom,
        }
    }

    /// The zone as a frame fraction for a frame of `frame_aspect` (width / height). A frame wider than 9:16 shows the
    /// platform's 9:16 picture as a centered window, so the zone is mapped into that window.
    pub fn rect_for(p: CutCheckPlatform, frame_aspect: f64) -> NormRect {
        let z = Self::zone(p).rect();
        let vertical = 9.0 / 16.0;
        if frame_aspect <= vertical + 1e-6 {
            return z;
        }
        let win = vertical / frame_aspect;
        NormRect { x: (1.0 - win) / 2.0 + z.x * win, y: z.y, width: z.width * win, height: z.height }
    }

    /// Approximate published creator guidance (1080 x 1920): TikTok ~ top 210 / bottom 340 / right 120 px, Reels and
    /// Shorts similar.
    pub fn zone(p: CutCheckPlatform) -> SafeZone {
        match p {
            CutCheckPlatform::Tiktok => SafeZone { top: 0.11, bottom: 0.18, left: 0.06, right: 0.12 },
            CutCheckPlatform::Reels => SafeZone { top: 0.13, bottom: 0.20, left: 0.05, right: 0.10 },
            CutCheckPlatform::Shorts => SafeZone { top: 0.10, bottom: 0.20, left: 0.05, right: 0.14 },
        }
    }
}

/// What a finding is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CutFindingKind {
    /// Same source, same framing across a cut.
    JumpCut,
    /// Empty stretch on the video tracks.
    Gap,
    /// A caption leaves the platform safe zone.
    CaptionOutsideSafeZone,
    /// Audio join without a fade.
    AudioPop,
}

impl CutFindingKind {
    /// Every kind.
    pub const ALL: [CutFindingKind; 4] = [Self::JumpCut, Self::Gap, Self::CaptionOutsideSafeZone, Self::AudioPop];

    /// Swift raw value (also the sort key of equal times).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::JumpCut => "jumpCut",
            Self::Gap => "gap",
            Self::CaptionOutsideSafeZone => "captionOutsideSafeZone",
            Self::AudioPop => "audioPop",
        }
    }

    /// Reads a raw value.
    pub fn from_raw(raw: &str) -> Option<CutFindingKind> {
        Self::ALL.into_iter().find(|k| k.raw_value() == raw)
    }

    /// Display name.
    pub fn title(self) -> &'static str {
        match self {
            Self::JumpCut => "Jump cut",
            Self::Gap => "Gap",
            Self::CaptionOutsideSafeZone => "Caption outside safe zone",
            Self::AudioPop => "Audio pop",
        }
    }

    fn marker_color(self) -> MarkerColor {
        match self {
            Self::JumpCut => MarkerColor::Orange,
            Self::Gap => MarkerColor::Red,
            Self::CaptionOutsideSafeZone => MarkerColor::Purple,
            Self::AudioPop => MarkerColor::Yellow,
        }
    }
}

/// One thing the check found.
#[derive(Clone, Debug, PartialEq)]
pub struct CutFinding {
    /// What was found.
    pub kind: CutFindingKind,
    /// Where.
    pub time: Time,
    /// Zero for point findings.
    pub duration: Time,
    /// Text for the marker comment.
    pub message: String,
}

/// One bar of the shot-length histogram.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShotBucket {
    /// Range label.
    pub label: String,
    /// Shots in the range.
    pub count: usize,
}

/// Shot-length statistics of a sequence.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EditStats {
    /// Number of shots.
    pub shot_count: usize,
    /// Number of cuts inside covered ranges.
    pub cuts: usize,
    /// Covered seconds.
    pub total_seconds: f64,
    /// Mean shot length.
    pub average_shot_seconds: f64,
    /// Shortest shot.
    pub shortest_shot_seconds: f64,
    /// Longest shot.
    pub longest_shot_seconds: f64,
    /// Cuts per covered minute.
    pub cuts_per_minute: f64,
    /// Shots per length bucket.
    pub histogram: Vec<ShotBucket>,
}

/// A caption's on-screen box (frame-relative); `None` = unknown, the caption is skipped.
pub type CaptionBounds = dyn Fn(&CaptionItem) -> Option<NormRect>;

/// Cut-quality analysis (`enum CutCheck`).
pub enum CutCheck {}

fn sec(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

impl CutCheck {
    /// Comment prefix of the markers a run leaves.
    pub const TAG_PREFIX: &'static str = "[cutcheck:";

    /// `caption_bounds` returns a caption's on-screen box (frame-relative); `None` = unknown, the caption is skipped.
    /// `platform` `None` skips the safe-zone check.
    pub fn analyze(
        tl: &Timeline,
        platform: Option<CutCheckPlatform>,
        frame_aspect: f64,
        caption_bounds: Option<&CaptionBounds>,
    ) -> Vec<CutFinding> {
        let mut out = Vec::new();
        let fd = tl.frame_duration();
        for track in &tl.tracks {
            let clips: Vec<&Clip> = track.clips().iter().filter(|c| c.is_enabled).collect();
            for w in clips.windows(2) {
                let (a, b) = (w[0], w[1]);
                // touching
                if !(b.start - a.timeline().end() < fd && a.timeline().end() - b.start < fd) {
                    continue;
                }
                if track.kind == TrackKind::Video && Self::is_jump_cut(a, b, fd) {
                    out.push(CutFinding {
                        kind: CutFindingKind::JumpCut,
                        time: b.start,
                        duration: Time::ZERO,
                        message: "Same source, same framing: cut looks like a jump.".to_string(),
                    });
                }
                if track.kind == TrackKind::Audio && Self::is_pop(a, b, fd, track) {
                    out.push(CutFinding {
                        kind: CutFindingKind::AudioPop,
                        time: b.start,
                        duration: Time::ZERO,
                        message: "No fade at this audio join: it may click.".to_string(),
                    });
                }
            }
        }
        out.extend(Self::gaps(tl));
        if let (Some(p), Some(bounds)) = (platform, caption_bounds) {
            let zone = SafeZone::rect_for(p, frame_aspect);
            for ct in &tl.caption_tracks {
                for item in ct.items() {
                    let Some(r) = bounds(item).filter(|r| !zone.contains(r)) else { continue };
                    let _ = r;
                    out.push(CutFinding {
                        kind: CutFindingKind::CaptionOutsideSafeZone,
                        time: item.range.start,
                        duration: item.range.duration,
                        message: format!("Caption leaves the {} safe zone.", p.raw_value()),
                    });
                }
            }
        }
        out.sort_by(|a, b| a.time.cmp(&b.time).then_with(|| a.kind.raw_value().cmp(b.kind.raw_value())));
        out
    }

    /// The second clip continues the first one's source (within a frame): a rejoined edit, not a jump.
    fn contiguous_source(a: &Clip, b: &Clip, fd: Time) -> bool {
        if a.is_retimed() || b.is_retimed() {
            return false;
        }
        let d = b.source.start - a.source.end();
        d < fd && Time::ZERO - fd < d
    }

    fn is_jump_cut(a: &Clip, b: &Clip, fd: Time) -> bool {
        if a.is_generator()
            || b.is_generator()
            || a.is_nested()
            || b.is_nested()
            || a.is_still
            || b.is_still
            || a.media != b.media
        {
            return false;
        }
        if Self::contiguous_source(a, b, fd) {
            return false;
        }
        let (ta, tb) = (a.transform(a.timeline().end() - fd), b.transform(b.start));
        (ta.position.x - tb.position.x).abs() < 0.02
            && (ta.position.y - tb.position.y).abs() < 0.02
            && (ta.scale.x - tb.scale.x).abs() < 0.03
            && (ta.scale.y - tb.scale.y).abs() < 0.03
            && (ta.rotation - tb.rotation).abs() < 1.0
    }

    fn is_pop(a: &Clip, b: &Clip, fd: Time, track: &Track) -> bool {
        if a.media == b.media && Self::contiguous_source(a, b, fd) {
            return false;
        }
        let tail = FadeKeys::tail_length(&a.animation.volume, a.duration(), &a.audio_fades).unwrap_or(Time::ZERO);
        let head = FadeKeys::head_length(&b.animation.volume, &b.audio_fades).unwrap_or(Time::ZERO);
        if tail >= fd || head >= fd {
            return false;
        }
        if track.transitions.iter().any(|t| t.outgoing == Some(a.id) && t.incoming == Some(b.id)) {
            return false;
        }
        // Silent on one side: nothing to click.
        a.volume(a.timeline().end() - fd) > 0.001 && b.volume(b.start) > 0.001
    }

    /// Union of enabled video clips; holes inside it are gaps.
    fn gaps(tl: &Timeline) -> Vec<CutFinding> {
        Self::coverage(tl)
            .windows(2)
            .map(|w| CutFinding {
                kind: CutFindingKind::Gap,
                time: w[0].end(),
                duration: w[1].start - w[0].end(),
                message: "Empty stretch on the video tracks.".to_string(),
            })
            .collect()
    }

    /// Merged (touching ranges joined) covered ranges of the video tracks.
    pub(crate) fn coverage(tl: &Timeline) -> Vec<TimeRange> {
        let mut rs: Vec<TimeRange> = tl
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| t.clips())
            .filter(|c| c.is_enabled)
            .map(|c| c.timeline())
            .filter(|r| !r.is_empty())
            .collect();
        rs.sort_by_key(|r| r.start);
        let mut merged: Vec<TimeRange> = Vec::new();
        for r in rs {
            match merged.last_mut() {
                Some(l) if r.start <= l.end() => *l = TimeRange::from_end(l.start, l.end().max(r.end())),
                _ => merged.push(r),
            }
        }
        merged
    }

    /// Shot-length statistics of the enabled video clips.
    pub fn stats(tl: &Timeline) -> EditStats {
        let clips: Vec<&Clip> = tl
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| t.clips())
            .filter(|c| c.is_enabled && !c.timeline().is_empty())
            .collect();
        let cov = Self::coverage(tl);
        if clips.is_empty() {
            return EditStats { histogram: Self::histogram(&[]), ..EditStats::default() };
        }
        let mut bounds = BTreeSet::new();
        for c in &clips {
            bounds.insert(c.start);
            bounds.insert(c.timeline().end());
        }
        let sorted: Vec<Time> = bounds.into_iter().collect();
        let mut shots = Vec::new();
        let mut cuts = 0;
        for w in sorted.windows(2) {
            if cov.iter().any(|r| r.start <= w[0] && w[1] <= r.end()) {
                shots.push(w[1] - w[0]);
            }
        }
        for t in &sorted {
            if cov.iter().any(|r| r.start < *t && *t < r.end()) {
                cuts += 1;
            }
        }
        let secs: Vec<f64> = shots.iter().map(|t| sec(*t)).collect();
        let total = cov.iter().fold(0.0, |acc, r| acc + sec(r.duration));
        EditStats {
            shot_count: shots.len(),
            cuts,
            total_seconds: total,
            average_shot_seconds: if secs.is_empty() { 0.0 } else { secs.iter().sum::<f64>() / secs.len() as f64 },
            shortest_shot_seconds: secs.iter().copied().reduce(f64::min).unwrap_or(0.0),
            longest_shot_seconds: secs.iter().copied().reduce(f64::max).unwrap_or(0.0),
            cuts_per_minute: if total > 0.0 { cuts as f64 / (total / 60.0) } else { 0.0 },
            histogram: Self::histogram(&secs),
        }
    }

    fn histogram(secs: &[f64]) -> Vec<ShotBucket> {
        let edges: [(&str, f64); 5] = [
            ("< 0.5 s", 0.5),
            ("0.5\u{2013}1", 1.0),
            ("1\u{2013}2", 2.0),
            ("2\u{2013}4", 4.0),
            ("> 4 s", f64::INFINITY),
        ];
        let mut counts = [0usize; 5];
        for s in secs {
            counts[edges.iter().position(|e| *s < e.1).unwrap_or(edges.len() - 1)] += 1;
        }
        edges.iter().zip(counts).map(|(e, count)| ShotBucket { label: e.0.to_string(), count }).collect()
    }

    /// The finding kind a marker carries, `None` for markers the user made.
    pub fn kind_of(m: &Marker) -> Option<CutFindingKind> {
        let rest = m.comment.strip_prefix(Self::TAG_PREFIX)?;
        let end = rest.find(']')?;
        CutFindingKind::from_raw(&rest[..end])
    }
}

/// `extension Timeline` of CutCheck.swift.
pub trait CutCheckTimelineExt {
    /// Replaces the markers of the last Check Cuts run with `findings` (user markers stay). The kind is in the comment
    /// tag, the color and name follow the kind, gaps and captions span their range.
    fn apply_cut_check(&mut self, findings: &[CutFinding], ids: &mut dyn IdSource);
}

impl CutCheckTimelineExt for Timeline {
    fn apply_cut_check(&mut self, findings: &[CutFinding], ids: &mut dyn IdSource) {
        self.markers.retain(|m| CutCheck::kind_of(m).is_none());
        let fd = self.frame_duration();
        for f in findings {
            let id = self.add_marker(f.time, f.kind.title(), ids);
            self.update_marker(id, |m| {
                m.color = f.kind.marker_color();
                m.comment = format!("{}{}] {}", CutCheck::TAG_PREFIX, f.kind.raw_value(), f.message);
                m.duration = f.duration.snapped(fd);
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sq_core_model::{CaptionTrack, SequenceFormat};
    use sq_core_time::{Id, SequentialIds};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn clip(m: u128, kind: TrackKind, src: i64, len: i64, at: i64) -> Clip {
        Clip::new(
            Id::from_u128(1000 + (src * 100 + at) as u128 + (m * 100_000)),
            "c",
            Id::from_u128(m),
            kind,
            TimeRange::new(s(src), s(len)),
            s(at),
        )
    }
    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }
    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(fd()), tracks)
    }
    fn video(clips: Vec<Clip>) -> Timeline {
        tl(vec![track(1, TrackKind::Video, clips)])
    }
    fn kinds(t: &Timeline, k: CutFindingKind) -> Vec<CutFinding> {
        CutCheck::analyze(t, None, 9.0 / 16.0, None).into_iter().filter(|f| f.kind == k).collect()
    }

    #[test]
    fn jump_cut_same_media_same_framing() {
        let t = video(vec![clip(7, TrackKind::Video, 0, 3, 0), clip(7, TrackKind::Video, 10, 3, 3)]);
        let f = kinds(&t, CutFindingKind::JumpCut);
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].time, s(3));
    }

    #[test]
    fn no_jump_cut_when_source_continuous_or_framing_differs() {
        let cont = video(vec![clip(7, TrackKind::Video, 0, 3, 0), clip(7, TrackKind::Video, 3, 3, 3)]);
        assert!(kinds(&cont, CutFindingKind::JumpCut).is_empty());
        let mut b = clip(7, TrackKind::Video, 10, 3, 3);
        b.animation.scale = sq_core_model::AnimatedProperty::new(sq_core_time::Vec2 { x: 1.3, y: 1.3 });
        let punch = video(vec![clip(7, TrackKind::Video, 0, 3, 0), b]);
        assert!(kinds(&punch, CutFindingKind::JumpCut).is_empty());
        let other = video(vec![clip(7, TrackKind::Video, 0, 3, 0), clip(8, TrackKind::Video, 0, 3, 3)]);
        assert!(kinds(&other, CutFindingKind::JumpCut).is_empty());
    }

    #[test]
    fn gaps_between_video_clips() {
        let t = video(vec![clip(7, TrackKind::Video, 0, 2, 0), clip(8, TrackKind::Video, 0, 2, 5)]);
        let g = kinds(&t, CutFindingKind::Gap);
        assert_eq!(g.len(), 1);
        assert!(g[0].time == s(2) && g[0].duration == s(3));
    }

    #[test]
    fn gap_covered_by_other_track_is_no_gap() {
        let a =
            track(1, TrackKind::Video, vec![clip(7, TrackKind::Video, 0, 2, 0), clip(8, TrackKind::Video, 0, 2, 5)]);
        let b = track(2, TrackKind::Video, vec![clip(9, TrackKind::Video, 0, 6, 0)]);
        assert!(kinds(&tl(vec![a, b]), CutFindingKind::Gap).is_empty());
    }

    #[test]
    fn audio_pop_without_fade() {
        let t = tl(vec![track(
            1,
            TrackKind::Audio,
            vec![clip(7, TrackKind::Audio, 0, 2, 0), clip(7, TrackKind::Audio, 9, 2, 2)],
        )]);
        assert_eq!(kinds(&t, CutFindingKind::AudioPop).len(), 1);
    }

    #[test]
    fn audio_fade_or_continuous_source_is_no_pop() {
        let mut a = clip(7, TrackKind::Audio, 0, 2, 0);
        a.animation.volume = FadeKeys::setting_tail(
            &a.animation.volume,
            &mut a.audio_fades,
            Time::new(1, 10),
            s(2),
            fd(),
            0.0,
            &mut SequentialIds::default(),
        );
        let faded = tl(vec![track(1, TrackKind::Audio, vec![a, clip(7, TrackKind::Audio, 9, 2, 2)])]);
        assert!(kinds(&faded, CutFindingKind::AudioPop).is_empty());
        let cont = tl(vec![track(
            1,
            TrackKind::Audio,
            vec![clip(7, TrackKind::Audio, 0, 2, 0), clip(7, TrackKind::Audio, 2, 2, 2)],
        )]);
        assert!(kinds(&cont, CutFindingKind::AudioPop).is_empty());
    }

    fn captioned() -> Timeline {
        let ct: CaptionTrack = serde_json::from_value(json!({"id": "00000000-0000-0000-0000-000000000001", "items": [
            {"id": "00000000-0000-0000-0000-000000000002", "lines": ["hi"],
             "range": {"start": {"value": 1, "timescale": 1}, "duration": {"value": 2, "timescale": 1}}}]}))
        .unwrap();
        let mut t = tl(vec![]);
        t.caption_tracks.push(ct);
        t
    }

    #[test]
    fn caption_outside_safe_zone() {
        let t = captioned();
        let low = NormRect { x: 0.2, y: 0.9, width: 0.6, height: 0.06 };
        let mid = NormRect { x: 0.2, y: 0.5, width: 0.6, height: 0.06 };
        let at = |r: NormRect, p: Option<CutCheckPlatform>, aspect: f64| {
            CutCheck::analyze(&t, p, aspect, Some(&move |_: &CaptionItem| Some(r)))
        };
        let bad = at(low, Some(CutCheckPlatform::Tiktok), 9.0 / 16.0);
        assert_eq!(bad.iter().filter(|f| f.kind == CutFindingKind::CaptionOutsideSafeZone).count(), 1);
        assert!(at(mid, Some(CutCheckPlatform::Tiktok), 9.0 / 16.0).is_empty());
        assert!(at(low, None, 9.0 / 16.0).is_empty());
    }

    #[test]
    fn safe_zone_maps_to_the_centered_9x16_window_of_a_landscape_frame() {
        let vertical = SafeZone::zone(CutCheckPlatform::Tiktok).rect();
        assert_eq!(SafeZone::rect_for(CutCheckPlatform::Tiktok, 9.0 / 16.0), vertical);
        let wide = SafeZone::rect_for(CutCheckPlatform::Tiktok, 16.0 / 9.0);
        let win = (9.0 / 16.0) / (16.0 / 9.0);
        assert!((wide.width - vertical.width * win).abs() < 1e-9);
        assert!((wide.x - ((1.0 - win) / 2.0 + vertical.x * win)).abs() < 1e-9);
        assert!(wide.y == vertical.y && wide.height == vertical.height);
        let t = captioned();
        let mid = NormRect { x: 0.4, y: 0.5, width: 0.2, height: 0.06 };
        let left = NormRect { x: 0.02, y: 0.5, width: 0.2, height: 0.06 };
        let run = |r: NormRect| {
            CutCheck::analyze(&t, Some(CutCheckPlatform::Reels), 16.0 / 9.0, Some(&move |_: &CaptionItem| Some(r)))
        };
        assert!(run(mid).is_empty());
        assert_eq!(run(left).len(), 1);
    }

    #[test]
    fn safe_zones_defined_for_each_platform() {
        for p in CutCheckPlatform::ALL {
            let z = SafeZone::zone(p);
            assert!(z.top > 0.0 && z.bottom > 0.0 && z.left > 0.0 && z.right > 0.0);
            assert!(z.rect().width > 0.0 && z.rect().height > 0.0);
        }
    }

    #[test]
    fn stats_histogram_and_cut_rate() {
        let t = video(vec![
            clip(7, TrackKind::Video, 0, 1, 0),
            clip(7, TrackKind::Video, 0, 4, 1),
            clip(7, TrackKind::Video, 0, 15, 5),
        ]);
        let st = CutCheck::stats(&t);
        assert_eq!(st.shot_count, 3);
        assert_eq!(st.cuts, 2);
        assert!((st.cuts_per_minute - 6.0).abs() < 0.001);
        assert!((st.average_shot_seconds - 20.0 / 3.0).abs() < 0.001);
        assert!(st.longest_shot_seconds == 15.0 && st.shortest_shot_seconds == 1.0);
        assert_eq!(st.histogram.iter().map(|b| b.count).sum::<usize>(), 3);
        assert_eq!(st.histogram.iter().find(|b| b.label == "> 4 s").map(|b| b.count), Some(2));
    }

    #[test]
    fn stats_empty_timeline() {
        let st = CutCheck::stats(&tl(vec![]));
        assert!(st.shot_count == 0 && st.cuts_per_minute == 0.0);
    }

    #[test]
    fn markers_replace_previous_run_only() {
        let mut ids = SequentialIds::default();
        let mut t = video(vec![clip(7, TrackKind::Video, 0, 2, 0), clip(8, TrackKind::Video, 0, 2, 5)]);
        t.add_marker(s(1), "mine", &mut ids);
        let found = CutCheck::analyze(&t, None, 9.0 / 16.0, None);
        t.apply_cut_check(&found, &mut ids);
        assert_eq!(t.markers.len(), 2);
        let found = CutCheck::analyze(&t, None, 9.0 / 16.0, None);
        t.apply_cut_check(&found, &mut ids);
        assert_eq!(t.markers.len(), 2);
        assert!(t.markers.iter().any(|m| m.name == "mine"));
        let m = t.markers.iter().find(|m| CutCheck::kind_of(m) == Some(CutFindingKind::Gap));
        assert_eq!(m.map(|m| m.duration), Some(s(3)));
    }
}
