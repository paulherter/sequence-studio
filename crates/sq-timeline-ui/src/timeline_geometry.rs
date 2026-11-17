// Swift: TimelineGeometry.swift
//! Timeline view geometry. Model time is rational (`Time`); `f64` only appears at the view edge.

use crate::portable_theme::metrics;
use crate::track_sizing::{TrackHeightMode, TrackSizing};
use sq_core_audio::caption_handover::TimelineCaptionsExt;
use sq_core_model::{Timeline, Track, TrackKind};
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::Point;
use std::collections::BTreeMap;

/// Where in a clip the pointer is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ClipZone {
    /// The middle.
    Body,
    /// The start edge (trim).
    Head,
    /// The end edge (trim).
    Tail,
}

/// What a point of the timeline view hits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TimelineHit {
    /// The ruler.
    Ruler,
    /// The tool column.
    ToolColumn,
    /// A track header.
    Header(Id),
    /// A clip.
    Clip(Id, ClipZone),
    /// A caption item on a caption track (same zones as clips: edges trim).
    Caption(Id, ClipZone),
    /// Empty space on a caption track.
    CaptionGap(Id, Time),
    /// A caption track header.
    CaptionHeader(Id),
    /// Empty space on a track; `Time` is the frame-snapped time under the pointer (never negative).
    Gap(Id, Time),
    /// Below the last track row.
    None,
}

/// One laid-out track row. `y` is in view coordinates (y down, origin top-left, after scroll).
#[derive(Clone, Debug, PartialEq)]
pub struct TrackRow {
    /// The track.
    pub track: Id,
    /// Its kind.
    pub kind: TrackKind,
    /// "V1", "A2", ...
    pub label: String,
    /// Top.
    pub y: f64,
    /// Height.
    pub height: f64,
    /// Space under the row that belongs to it (item lanes of an opened Graphic); the next row starts below it.
    pub lane_space: f64,
}

impl TrackRow {
    /// Bottom of the row itself.
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// Bottom of the row including its lane space.
    pub fn bottom(&self) -> f64 {
        self.y + self.height + self.lane_space
    }
}

/// One laid-out caption track row (above the video rows).
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionRow {
    /// The caption track.
    pub track: Id,
    /// "C1", "C2", ...
    pub label: String,
    /// Top.
    pub y: f64,
    /// Height.
    pub height: f64,
}

impl CaptionRow {
    /// Bottom.
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
}

/// A ghost track: empty space under the last row where a drop creates a new track of `kind`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GhostRow {
    /// Kind of the track a drop creates.
    pub kind: TrackKind,
    /// Top.
    pub y: f64,
    /// Height.
    pub height: f64,
}

impl GhostRow {
    /// Bottom.
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// "V+" / "A+"
    pub fn label(&self) -> &'static str {
        if self.kind == TrackKind::Video { "V+" } else { "A+" }
    }
}

fn int64(x: f64) -> i64 {
    debug_assert!(x.is_finite());
    x as i64
}

type Entry<'a> = (&'a Track, String, usize); // track, label, indexInKind

/// View coordinates: origin top-left, y down. Columns: tool column `0..<38`, track headers `38..<162`, content from 162.
/// Time 0 sits at `CONTENT_ORIGIN_X - scroll_x`. Rows: ruler, then video tracks top to bottom V(n)...V1, then audio A1...A(n)
/// (video/audio order inside `Timeline.tracks` is bottom-up per kind).
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineGeometry {
    /// One frame.
    pub frame_duration: Time,
    /// Zoom: points per second of sequence time.
    pub points_per_second: f64,
    /// Horizontal scroll.
    pub scroll_x: f64,
    /// Vertical scroll.
    pub scroll_y: f64,
    /// User row heights. `Track.height` (a 48 pt model hint) is deliberately ignored.
    pub height_overrides: BTreeMap<Id, f64>,
    /// Height of the track area's viewport (the whole view). When set and taller than the rows, the spare height is
    /// shared out over the tracks (see `stretched_heights`) so the panel has no dead space. 0 disables stretching.
    pub viewport_height: f64,
    /// Preset for tracks without an override; only `Auto` stretches.
    pub height_mode: TrackHeightMode,
    /// Fit All Tracks: every track shares the panel height (`TrackSizing::fit_heights`); overrides and the preset are ignored
    /// until it is turned off (the view then freezes the drawn heights as overrides).
    pub fit_all_tracks: bool,
    /// Keeps `GHOST_ROW_HEIGHT` x 2 free under the last track, so the ghost tracks (drop to add a track) are always in view.
    pub reserves_ghost_space: bool,
    /// Space under a track's row for the item lanes of an opened Graphic (view state; rows below move down by it).
    pub lane_space: BTreeMap<Id, f64>,
    /// Where the V/A split sits, as a fraction of the track area under the ruler and caption rows (0.5 = the exact middle).
    /// The video tracks stack upward from it, the audio tracks downward; the heights are not touched by moving it.
    /// Only applies with a viewport, both kinds present and Fit All Tracks off.
    pub split_fraction: f64,
}

impl TimelineGeometry {
    /// Ruler height.
    pub const RULER_HEIGHT: f64 = sq_uikit::redesign_tokens::size::RULER as f64;
    /// Tool column width.
    pub const TOOL_COLUMN_WIDTH: f64 = metrics::TOOL_COLUMN;
    /// Header column width.
    pub const HEADER_WIDTH: f64 = metrics::TRACK_HEADER;
    /// Where the content starts.
    pub const CONTENT_ORIGIN_X: f64 = Self::TOOL_COLUMN_WIDTH + Self::HEADER_WIDTH;
    /// Caption row height.
    pub const CAPTION_ROW_HEIGHT: f64 = 26.0;
    /// Ghost row height.
    pub const GHOST_ROW_HEIGHT: f64 = 24.0;
    /// Widest trim handle.
    pub const MAX_TRIM_HANDLE_WIDTH: f64 = 6.0;
    /// Default snap distance in points.
    pub const DEFAULT_SNAP_THRESHOLD_POINTS: f64 = 8.0;
    /// Resolution of un-snapped times and thresholds (1 microsecond).
    pub const TICK_SCALE: i64 = 1_000_000;

    /// Geometry at `points_per_second` (positive, finite).
    pub fn new(frame_duration: Time, points_per_second: f64) -> TimelineGeometry {
        assert!(points_per_second > 0.0 && points_per_second.is_finite());
        TimelineGeometry {
            frame_duration,
            points_per_second,
            scroll_x: 0.0,
            scroll_y: 0.0,
            height_overrides: BTreeMap::new(),
            viewport_height: 0.0,
            height_mode: TrackHeightMode::Auto,
            fit_all_tracks: false,
            reserves_ghost_space: false,
            lane_space: BTreeMap::new(),
            split_fraction: TrackSizing::DEFAULT_SPLIT_FRACTION,
        }
    }

    /// Geometry at `points_per_frame`.
    pub fn with_points_per_frame(frame_duration: Time, points_per_frame: f64) -> TimelineGeometry {
        Self::new(
            frame_duration,
            points_per_frame / (frame_duration.value() as f64 / frame_duration.timescale() as f64),
        )
    }

    // MARK: Time <-> x

    fn seconds(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    /// Width of a duration in points.
    pub fn width(&self, duration: Time) -> f64 {
        Self::seconds(duration) * self.points_per_second
    }

    /// View x of a time.
    pub fn x(&self, time: Time) -> f64 {
        Self::CONTENT_ORIGIN_X - self.scroll_x + self.width(time)
    }

    /// Time under view x, snapped to the nearest frame.
    pub fn time(&self, x: f64) -> Time {
        let frames = ((x - Self::CONTENT_ORIGIN_X + self.scroll_x)
            / self.points_per_second
            / Self::seconds(self.frame_duration))
        .round();
        self.frame_duration * int64(frames)
    }

    /// Time under view x, not snapped (rounded to 1 microsecond).
    pub fn unsnapped_time(&self, x: f64) -> Time {
        let s = (x - Self::CONTENT_ORIGIN_X + self.scroll_x) / self.points_per_second;
        Time::new(int64((s * Self::TICK_SCALE as f64).round()), Self::TICK_SCALE)
    }

    /// A pixel distance as a duration, for snapping. At least one tick.
    pub fn snap_threshold(&self, points: f64) -> Time {
        let ticks = int64((points / self.points_per_second * Self::TICK_SCALE as f64).round());
        Time::new(ticks.max(1), Self::TICK_SCALE)
    }

    // MARK: Rows

    /// Default row height, uniform per kind: video 32, audio 26.
    pub fn default_height(kind: TrackKind, _index_in_kind: usize) -> f64 {
        if kind == TrackKind::Video { metrics::TRACK_V1 } else { metrics::TRACK_A1 }
    }

    /// Largest height stretching may give a row, uniform per kind: video 120, audio 90.
    pub fn max_stretch_height(kind: TrackKind, _index_in_kind: usize) -> f64 {
        if kind == TrackKind::Video { 120.0 } else { 90.0 }
    }

    /// Spreads `extra` points over rows with water-filling: every row grows in proportion to its weight until it
    /// reaches its cap; what a capped row cannot take goes to the others. Rows with `cap == base` stay fixed.
    /// The result never exceeds a cap and sums to `base + min(extra, total headroom)`.
    pub fn stretched_heights(base: &[f64], caps: &[f64], weights: &[f64], extra: f64) -> Vec<f64> {
        let mut h = base.to_vec();
        let mut left = extra.max(0.0);
        let mut open: Vec<usize> = (0..h.len()).filter(|&i| caps[i] > h[i] + 0.001 && weights[i] > 0.0).collect();
        while left > 0.001 && !open.is_empty() {
            let total = open.iter().fold(0.0, |a, &i| a + weights[i]);
            let mut used = 0.0;
            for &i in &open {
                let add = (left * weights[i] / total).min(caps[i] - h[i]);
                h[i] += add;
                used += add;
            }
            left -= used;
            open.retain(|&i| caps[i] > h[i] + 0.001);
            if used < 0.0001 {
                break;
            }
        }
        h
    }

    /// Caption rows, directly under the ruler (above V tracks), in model order (first track on top).
    pub fn caption_rows(&self, timeline: &Timeline) -> Vec<CaptionRow> {
        let mut y = Self::RULER_HEIGHT - self.scroll_y;
        timeline
            .caption_tracks
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let row = CaptionRow { track: t.id, label: format!("C{}", i + 1), y, height: Self::CAPTION_ROW_HEIGHT };
                y += Self::CAPTION_ROW_HEIGHT;
                row
            })
            .collect()
    }

    /// Total height of all caption rows.
    pub fn caption_height(&self, timeline: &Timeline) -> f64 {
        timeline.caption_tracks.len() as f64 * Self::CAPTION_ROW_HEIGHT
    }

    /// Fills `heights[idx]` with the stretched heights of those rows (see `rows`).
    fn stretch(
        &self,
        heights: &mut [f64],
        idx: &[usize],
        room: f64,
        stretches: bool,
        base: &[f64],
        entries: &[Entry<'_>],
    ) {
        if !stretches || idx.is_empty() {
            return;
        }
        let b: Vec<f64> = idx.iter().map(|&i| base[i]).collect();
        let extra = room - b.iter().fold(0.0, |a, &x| a + x);
        if extra <= 0.0 {
            return;
        }
        let caps: Vec<f64> = idx
            .iter()
            .map(|&i| {
                if self.height_overrides.contains_key(&entries[i].0.id) {
                    base[i]
                } else {
                    Self::max_stretch_height(entries[i].0.kind, entries[i].2)
                }
            })
            .collect();
        let w: Vec<f64> = idx.iter().map(|&i| if entries[i].0.kind == TrackKind::Video { 3.0 } else { 2.0 }).collect();
        let out = Self::stretched_heights(&b, &caps, &w, extra);
        for (k, &i) in idx.iter().enumerate() {
            heights[i] = out[k];
        }
    }

    /// Media track rows; they start below the caption rows.
    pub fn rows(&self, timeline: &Timeline) -> Vec<TrackRow> {
        let mut v = 0;
        let mut a = 0;
        let mut video: Vec<Entry<'_>> = Vec::new();
        let mut audio: Vec<Entry<'_>> = Vec::new();
        for t in timeline.tracks.iter() {
            match t.kind {
                TrackKind::Video => {
                    video.push((t, format!("V{}", v + 1), v));
                    v += 1;
                }
                TrackKind::Audio => {
                    audio.push((t, format!("A{}", a + 1), a));
                    a += 1;
                }
            }
        }
        let nv = video.len();
        let audio_empty = audio.is_empty();
        let mut entries: Vec<Entry<'_>> = video.into_iter().rev().collect();
        entries.extend(audio);
        let base: Vec<f64> = entries
            .iter()
            .map(|(t, _, idx)| {
                self.height_overrides
                    .get(&t.id)
                    .copied()
                    .or_else(|| self.height_mode.height(t.kind))
                    .unwrap_or_else(|| Self::default_height(t.kind, *idx))
            })
            .collect();
        let mut heights = base.clone();
        let lanes = if self.lane_space.is_empty() {
            0.0
        } else {
            entries.iter().fold(0.0, |acc, e| acc + self.lane_space.get(&e.0.id).copied().unwrap_or(0.0))
        };
        if self.fit_all_tracks && self.viewport_height > 0.0 {
            let avail = self.viewport_height
                - Self::RULER_HEIGHT
                - self.caption_height(timeline)
                - if self.reserves_ghost_space { 2.0 * Self::GHOST_ROW_HEIGHT } else { 0.0 }
                - lanes;
            let weights: Vec<f64> =
                entries.iter().map(|e| if e.0.kind == TrackKind::Video { 3.0 } else { 2.0 }).collect();
            heights = TrackSizing::fit_heights(&weights, avail);
        }
        let ghost_reserve = if self.reserves_ghost_space { 2.0 * Self::GHOST_ROW_HEIGHT } else { 0.0 };
        let top = Self::RULER_HEIGHT + self.caption_height(timeline);
        let stretches = self.height_mode == TrackHeightMode::Auto || !self.height_overrides.is_empty();
        let splits = !self.fit_all_tracks && self.viewport_height > 0.0 && nv > 0 && !audio_empty;
        let mut video_lead = 0.0; // gap above the first video row: the video tracks sit on the split
        if splits {
            let lane = |i: usize| self.lane_space.get(&entries[i].0.id).copied().unwrap_or(0.0);
            let avail = (self.viewport_height - top - ghost_reserve).max(0.0);
            let offset = TrackSizing::split_offset(self.split_fraction, avail);
            let v_idx: Vec<usize> = (0..nv).collect();
            let a_idx: Vec<usize> = (nv..entries.len()).collect();
            let v_lanes = v_idx.iter().fold(0.0, |acc, &i| acc + lane(i));
            let a_lanes = a_idx.iter().fold(0.0, |acc, &i| acc + lane(i));
            self.stretch(&mut heights, &v_idx, offset, stretches, &base, &entries);
            // Item lanes (view state) hang under their row and push what is below down; they never move the rows above.
            let v_sum = v_idx.iter().fold(0.0, |acc, &i| acc + heights[i]);
            self.stretch(
                &mut heights,
                &a_idx,
                avail - offset.max(v_sum) - v_lanes - a_lanes,
                stretches,
                &base,
                &entries,
            );
            video_lead = (offset - v_sum).max(0.0); // video taller than its half pushes the audio side down
        } else {
            let spare = self.viewport_height
                - Self::RULER_HEIGHT
                - self.caption_height(timeline)
                - base.iter().fold(0.0, |acc, &x| acc + x)
                - ghost_reserve
                - lanes;
            if !self.fit_all_tracks && self.viewport_height > 0.0 && spare > 0.0 && stretches {
                let caps: Vec<f64> = entries
                    .iter()
                    .enumerate()
                    .map(|(i, e)| {
                        if self.height_overrides.contains_key(&e.0.id) {
                            base[i]
                        } else {
                            Self::max_stretch_height(e.0.kind, e.2)
                        }
                    })
                    .collect();
                let weights: Vec<f64> =
                    entries.iter().map(|e| if e.0.kind == TrackKind::Video { 3.0 } else { 2.0 }).collect();
                heights = Self::stretched_heights(&base, &caps, &weights, spare);
            }
        }
        let mut y = top - self.scroll_y + video_lead;
        entries
            .iter()
            .enumerate()
            .map(|(i, (t, label, _))| {
                let space =
                    if self.lane_space.is_empty() { 0.0 } else { self.lane_space.get(&t.id).copied().unwrap_or(0.0) };
                let row = TrackRow {
                    track: t.id,
                    kind: t.kind,
                    label: label.clone(),
                    y,
                    height: heights[i],
                    lane_space: space,
                };
                y += heights[i] + space;
                row
            })
            .collect()
    }

    /// Height of the area the V/A split moves in: the viewport under the ruler and caption rows, less the ghost rows.
    pub fn split_available(&self, timeline: &Timeline) -> f64 {
        (self.viewport_height
            - Self::RULER_HEIGHT
            - self.caption_height(timeline)
            - if self.reserves_ghost_space { 2.0 * Self::GHOST_ROW_HEIGHT } else { 0.0 })
        .max(0.0)
    }

    /// Two ghost rows directly under the last track: a new top video track (V n+1), then a new audio track (A n+1).
    pub fn ghost_rows(&self, timeline: &Timeline) -> [GhostRow; 2] {
        let top = self
            .rows(timeline)
            .last()
            .map(|r| r.bottom())
            .unwrap_or(Self::RULER_HEIGHT - self.scroll_y + self.caption_height(timeline));
        [
            GhostRow { kind: TrackKind::Video, y: top, height: Self::GHOST_ROW_HEIGHT },
            GhostRow { kind: TrackKind::Audio, y: top + Self::GHOST_ROW_HEIGHT, height: Self::GHOST_ROW_HEIGHT },
        ]
    }

    /// The kind of track a drop at `point` (view coordinates) would create, when the point is over a ghost row.
    pub fn ghost_kind(&self, point: Point, timeline: &Timeline) -> Option<TrackKind> {
        if !(point.x >= Self::TOOL_COLUMN_WIDTH && point.y >= Self::RULER_HEIGHT) {
            return None;
        }
        self.ghost_rows(timeline).iter().find(|g| point.y >= g.y && point.y < g.max_y()).map(|g| g.kind)
    }

    /// Total content height (ruler plus all rows, ignoring scroll).
    pub fn content_height(&self, timeline: &Timeline) -> f64 {
        self.rows(timeline)
            .last()
            .map(|r| r.max_y() + r.lane_space + self.scroll_y)
            .unwrap_or(Self::RULER_HEIGHT + self.caption_height(timeline))
            + if self.reserves_ghost_space { 2.0 * Self::GHOST_ROW_HEIGHT } else { 0.0 }
    }

    // MARK: Trim handles

    /// Trim handle width for a clip of the given width: 6 pt, shrinking to a third of the clip on narrow clips so the
    /// body (at least the middle third) stays clickable. Zero-width clips have no handles.
    pub fn trim_handle_width(clip_width: f64) -> f64 {
        0.0_f64.max(Self::MAX_TRIM_HANDLE_WIDTH.min(clip_width / 3.0))
    }

    fn zone(point_x: f64, x0: f64, x1: f64) -> ClipZone {
        let h = Self::trim_handle_width(x1 - x0);
        if point_x < x0 + h {
            ClipZone::Head
        } else if point_x >= x1 - h {
            ClipZone::Tail
        } else {
            ClipZone::Body
        }
    }

    // MARK: Hit test

    /// `point` is in view coordinates. Clip edges are half-open: the start pixel belongs to the clip, the end pixel to the next.
    pub fn hit_test(&self, point: Point, timeline: &Timeline) -> TimelineHit {
        if point.y < Self::RULER_HEIGHT {
            return if point.x < Self::TOOL_COLUMN_WIDTH { TimelineHit::ToolColumn } else { TimelineHit::Ruler };
        }
        if point.x < Self::TOOL_COLUMN_WIDTH {
            return TimelineHit::ToolColumn;
        }
        if let Some(crow) = self.caption_rows(timeline).iter().find(|r| point.y >= r.y && point.y < r.max_y())
            && let Some(ctrack) = timeline.caption_track(crow.track)
        {
            if point.x < Self::CONTENT_ORIGIN_X {
                return TimelineHit::CaptionHeader(ctrack.id);
            }
            for item in ctrack.items() {
                let x0 = self.x(item.range.start);
                let x1 = self.x(item.range.end());
                if !(point.x >= x0 && point.x < x1) {
                    continue;
                }
                return TimelineHit::Caption(item.id, Self::zone(point.x, x0, x1));
            }
            return TimelineHit::CaptionGap(ctrack.id, self.time(point.x).max(Time::ZERO));
        }
        let rows = self.rows(timeline);
        let Some(row) = rows.iter().find(|r| point.y >= r.y && point.y < r.max_y()) else { return TimelineHit::None };
        let Some(track) = timeline.track(row.track) else { return TimelineHit::None };
        if point.x < Self::CONTENT_ORIGIN_X {
            return TimelineHit::Header(track.id);
        }
        for clip in track.clips() {
            let x0 = self.x(clip.timeline().start);
            let x1 = self.x(clip.timeline().end());
            if !(point.x >= x0 && point.x < x1) {
                continue;
            }
            return TimelineHit::Clip(clip.id, Self::zone(point.x, x0, x1));
        }
        TimelineHit::Gap(track.id, self.time(point.x).max(Time::ZERO))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::Clip;
    use sq_core_time::TimeRange;

    const FD: Time = Time::new(1, 24);

    fn clip(n: u128, start_frame: i64, frames: i64) -> Clip {
        Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(1000 + n),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, FD * frames),
            FD * start_frame,
        )
    }

    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }

    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", sq_core_model::SequenceFormat::new(FD), tracks)
    }

    // v1 = 100, v2 = 101, a1 = 102, a2 = 103
    fn make_timeline() -> Timeline {
        tl(vec![
            track(100, TrackKind::Video, vec![clip(1, 0, 48), clip(2, 72, 2), clip(3, 100, 3)]),
            track(101, TrackKind::Video, vec![]),
            track(102, TrackKind::Audio, vec![]),
            track(103, TrackKind::Audio, vec![]),
        ])
    }

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn pt(x: f64, y: f64) -> Point {
        Point::new(x, y)
    }

    fn g100() -> TimelineGeometry {
        TimelineGeometry::new(FD, 100.0)
    }

    #[test]
    fn round_trip_one_frame_200pt() {
        let g = TimelineGeometry::with_points_per_frame(FD, 200.0);
        assert!((g.width(FD) - 200.0).abs() < 1e-9);
        for n in [0_i64, 1, 2, 23, 24, 1000, 86_400] {
            let t = FD * n;
            assert_eq!(g.time(g.x(t)), t);
            assert_eq!(g.time(g.x(t) + 99.0), t); // just under half a frame
            assert_eq!(g.time(g.x(t) + 101.0), t + FD);
        }
    }

    #[test]
    fn round_trip_one_hour_300pt() {
        let g = TimelineGeometry::new(FD, 300.0 / 3600.0);
        let hour = Time::seconds(3600);
        assert!((g.width(hour) - 300.0).abs() < 1e-9);
        assert_eq!(g.time(g.x(hour)), hour);
        for n in [0_i64, 1, 24, 86_399, 86_400] {
            assert_eq!(g.time(g.x(FD * n)), FD * n);
        }
        // A point 300 pt right of the origin is one hour, snapped to a frame.
        assert_eq!(g.time(TimelineGeometry::CONTENT_ORIGIN_X + 300.0), hour);
    }

    #[test]
    fn ntsc_frame_duration() {
        let ntsc = Time::new(1001, 30000);
        let g = TimelineGeometry::with_points_per_frame(ntsc, 50.0);
        for n in [0_i64, 1, 29, 107_892] {
            assert_eq!(g.time(g.x(ntsc * n)), ntsc * n);
        }
    }

    #[test]
    fn scroll_shifts_x() {
        let mut g = g100();
        assert_eq!(g.x(Time::ZERO), TimelineGeometry::CONTENT_ORIGIN_X);
        g.scroll_x = 50.0;
        assert_eq!(g.x(Time::ZERO), TimelineGeometry::CONTENT_ORIGIN_X - 50.0);
        assert_eq!(g.time(g.x(Time::seconds(2))), Time::seconds(2));
    }

    #[test]
    fn unsnapped_time() {
        assert_eq!(g100().unsnapped_time(TimelineGeometry::CONTENT_ORIGIN_X + 50.0), Time::new(1, 2));
    }

    #[test]
    fn snap_threshold_conversion() {
        let d = TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS;
        let g = g100();
        assert_eq!(g.snap_threshold(d), Time::new(2, 25)); // 8 pt = 0.08 s
        assert_eq!(g.snap_threshold(10.0), Time::new(1, 10));
        let far = TimelineGeometry::new(FD, 300.0 / 3600.0);
        assert_eq!(far.snap_threshold(d), Time::new(96, 1)); // 8 pt = 96 s
        let near = TimelineGeometry::with_points_per_frame(FD, 200.0);
        assert!(near.snap_threshold(d) < FD);
        assert!(near.snap_threshold(d) > Time::ZERO);
    }

    #[test]
    fn default_row_heights_and_layout() {
        let t = make_timeline();
        let g = g100();
        let rows = g.rows(&t);
        assert_eq!(rows.iter().map(|r| r.track).collect::<Vec<_>>(), [id(101), id(100), id(102), id(103)]);
        assert_eq!(rows.iter().map(|r| r.label.as_str()).collect::<Vec<_>>(), ["V2", "V1", "A1", "A2"]);
        assert_eq!(rows.iter().map(|r| r.height).collect::<Vec<_>>(), [40.0, 40.0, 32.0, 32.0]); // Track.height (48) is ignored
        assert_eq!(rows[0].y, TimelineGeometry::RULER_HEIGHT);
        assert_eq!(rows[1].y, rows[0].max_y());
        assert_eq!(g.content_height(&t), TimelineGeometry::RULER_HEIGHT + 144.0);
    }

    #[test]
    fn height_override() {
        let t = make_timeline();
        let mut g = g100();
        g.height_overrides.insert(id(100), 60.0);
        assert_eq!(g.rows(&t).iter().find(|r| r.track == id(100)).map(|r| r.height), Some(60.0));
    }

    #[test]
    fn columns_and_ruler() {
        let t = make_timeline();
        let g = g100();
        const { assert!(TimelineGeometry::TOOL_COLUMN_WIDTH == 0.0 && TimelineGeometry::HEADER_WIDTH == 190.0) };
        assert_eq!(g.hit_test(pt(300.0, 5.0), &t), TimelineHit::Ruler);
        assert_eq!(TimelineGeometry::CONTENT_ORIGIN_X, 190.0);
        let rows = g.rows(&t);
        assert_eq!(g.hit_test(pt(0.0, rows[0].y + 1.0), &t), TimelineHit::Header(id(101)));
        assert_eq!(g.hit_test(pt(123.0, rows[1].y + 1.0), &t), TimelineHit::Header(id(100)));
        assert_eq!(g.hit_test(pt(300.0, rows[3].max_y() + 5.0), &t), TimelineHit::None);
    }

    /// A cut has a full trim zone on each side: the first clip's tail left of it, the second clip's head right of it.
    #[test]
    fn both_sides_of_a_cut_have_a_full_trim_zone() {
        let t = tl(vec![track(100, TrackKind::Video, vec![clip(1, 0, 48), clip(2, 48, 48)])]);
        let g = g100();
        let (a, b) = (t.tracks[0].clips()[0].id, t.tracks[0].clips()[1].id);
        let y = g.rows(&t).first().map(|r| r.y).unwrap_or(0.0) + 5.0;
        let cut = g.x(FD * 48);
        let hit = |x: f64| g.hit_test(pt(x, y), &t);
        let w = TimelineGeometry::MAX_TRIM_HANDLE_WIDTH;
        assert_eq!(hit(cut - w), TimelineHit::Clip(a, ClipZone::Tail));
        assert_eq!(hit(cut - 0.1), TimelineHit::Clip(a, ClipZone::Tail));
        assert_eq!(hit(cut), TimelineHit::Clip(b, ClipZone::Head));
        assert_eq!(hit(cut + w - 0.1), TimelineHit::Clip(b, ClipZone::Head));
        assert_eq!(hit(cut - w - 0.1), TimelineHit::Clip(a, ClipZone::Body));
        assert_eq!(hit(cut + w), TimelineHit::Clip(b, ClipZone::Body));
    }

    #[test]
    fn clip_zones_at_edges() {
        let t = make_timeline();
        let g = g100();
        let y = g.rows(&t).iter().find(|r| r.track == id(100)).map(|r| r.y).unwrap_or(0.0) + 5.0;
        let c = &t.tracks[0].clips()[0]; // frames 0..48 = 2 s = 200 pt
        let x0 = g.x(c.timeline().start);
        let x1 = g.x(c.timeline().end());
        let hit = |x: f64| g.hit_test(pt(x, y), &t);
        assert_eq!(hit(x0), TimelineHit::Clip(c.id, ClipZone::Head));
        assert_eq!(hit(x0 + 5.9), TimelineHit::Clip(c.id, ClipZone::Head));
        assert_eq!(hit(x0 + 6.0), TimelineHit::Clip(c.id, ClipZone::Body));
        assert_eq!(hit(x1 - 6.1), TimelineHit::Clip(c.id, ClipZone::Body));
        assert_eq!(hit(x1 - 6.0), TimelineHit::Clip(c.id, ClipZone::Tail));
        assert_eq!(hit(x1 - 0.1), TimelineHit::Clip(c.id, ClipZone::Tail));
        assert_eq!(hit(x1), TimelineHit::Gap(id(100), c.timeline().end())); // end is exclusive
    }

    #[test]
    fn narrow_clip_keeps_body() {
        let t = make_timeline();
        let g = g100();
        let y = g.rows(&t).iter().find(|r| r.track == id(100)).map(|r| r.y).unwrap_or(0.0) + 5.0;
        let c = &t.tracks[0].clips()[1]; // 2 frames = 8.33 pt wide
        let x0 = g.x(c.timeline().start);
        let w = g.width(c.timeline().duration);
        let h = TimelineGeometry::trim_handle_width(w);
        assert!((h - w / 3.0).abs() < 1e-9);
        assert_eq!(g.hit_test(pt(x0 + w / 2.0, y), &t), TimelineHit::Clip(c.id, ClipZone::Body));
        assert_eq!(g.hit_test(pt(x0 + 0.5, y), &t), TimelineHit::Clip(c.id, ClipZone::Head));
        assert_eq!(g.hit_test(pt(x0 + w - 0.5, y), &t), TimelineHit::Clip(c.id, ClipZone::Tail));
        assert_eq!(TimelineGeometry::trim_handle_width(100.0), 6.0);
        assert_eq!(TimelineGeometry::trim_handle_width(18.0), 6.0);
        assert_eq!(TimelineGeometry::trim_handle_width(12.0), 4.0);
        assert_eq!(TimelineGeometry::trim_handle_width(0.0), 0.0);
    }

    #[test]
    fn gap_time_is_snapped_and_clamped() {
        let t = make_timeline();
        let g = g100();
        let y = g.rows(&t)[0].y + 5.0;
        // 100 pt right of origin = 1 s = frame 24
        assert_eq!(
            g.hit_test(pt(TimelineGeometry::CONTENT_ORIGIN_X + 100.0, y), &t),
            TimelineHit::Gap(id(101), FD * 24)
        );
        let mut scrolled = g;
        scrolled.scroll_x = -40.0; // rubber-band: time < 0 clamps to zero
        assert_eq!(
            scrolled.hit_test(pt(TimelineGeometry::CONTENT_ORIGIN_X + 10.0, y), &t),
            TimelineHit::Gap(id(101), Time::ZERO)
        );
    }

    // --- TrackStretchTests

    fn stretch_timeline(video: u128, audio: u128) -> Timeline {
        let mut tracks = Vec::new();
        for i in 0..video {
            tracks.push(track(200 + i, TrackKind::Video, vec![]));
        }
        for i in 0..audio {
            tracks.push(track(300 + i, TrackKind::Audio, vec![]));
        }
        tl(tracks)
    }

    #[test]
    fn water_filling_respects_caps_and_sum() {
        let h = TimelineGeometry::stretched_heights(&[32.0, 26.0], &[200.0, 120.0], &[3.0, 2.0], 100.0);
        assert!((h.iter().sum::<f64>() - 158.0).abs() < 0.01);
        assert!(h.iter().zip([140.0, 100.0]).all(|(a, b)| *a <= b + 0.001));
        // Not enough room: only the headroom is used.
        let full = TimelineGeometry::stretched_heights(&[32.0, 26.0], &[200.0, 120.0], &[3.0, 2.0], 1000.0);
        assert_eq!(full, vec![200.0, 120.0]);
    }

    #[test]
    fn no_viewport_height_means_no_stretch() {
        let g = TimelineGeometry::new(FD, 40.0);
        assert_eq!(g.rows(&stretch_timeline(1, 1)).iter().map(|r| r.height).collect::<Vec<_>>(), [40.0, 32.0]);
    }

    #[test]
    fn rows_fill_default_panel_height() {
        let mut g = TimelineGeometry::new(FD, 40.0);
        let t = stretch_timeline(2, 2);
        for panel in [260.0, 300.0, 360.0] {
            g.viewport_height = panel;
            let rows = g.rows(&t);
            assert!((rows[rows.len() - 1].max_y() - panel).abs() < 0.5); // no dead space below the last row
            assert!(rows.iter().all(|r| r.height >= 20.0));
        }
        g.viewport_height = 1000.0; // huge panel: capped, the rest is empty
        let rows = g.rows(&t);
        assert!(rows[rows.len() - 1].max_y() < 1000.0);
    }

    #[test]
    fn all_tracks_grow_evenly_per_kind() {
        let mut g = TimelineGeometry::new(FD, 40.0);
        let t = stretch_timeline(4, 4);
        let small: Vec<f64> = g.rows(&t).iter().map(|r| r.height).collect();
        assert_eq!(small, [40.0, 40.0, 40.0, 40.0, 32.0, 32.0, 32.0, 32.0]);
        g.viewport_height = 420.0;
        let rows = g.rows(&t);
        assert!((rows[rows.len() - 1].max_y() - 420.0).abs() < 0.5);
        let kinds = |k: TrackKind| {
            rows.iter()
                .filter(|r| r.kind == k)
                .map(|r| r.height.round() as i64)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
        };
        assert_eq!(kinds(TrackKind::Video), 1);
        assert_eq!(kinds(TrackKind::Audio), 1);
        assert!(rows.iter().all(|r| r.height > if r.kind == TrackKind::Video { 32.0 } else { 26.0 }));
    }

    #[test]
    fn small_panel_keeps_defaults_and_scrolls() {
        let mut g = TimelineGeometry::new(FD, 40.0);
        g.viewport_height = 60.0;
        assert_eq!(g.rows(&stretch_timeline(1, 1)).iter().map(|r| r.height).collect::<Vec<_>>(), [40.0, 32.0]);
    }

    #[test]
    fn user_heights_stay_fixed() {
        let mut g = TimelineGeometry::new(FD, 40.0);
        let t = stretch_timeline(1, 1);
        g.height_overrides.insert(t.tracks[0].id, 50.0);
        g.viewport_height = 300.0;
        let rows = g.rows(&t);
        assert_eq!(rows[0].height, 50.0);
        assert!(rows[1].height > 26.0);
    }

    #[test]
    fn hit_test_uses_stretched_rows() {
        let mut g = TimelineGeometry::new(FD, 40.0);
        g.viewport_height = 300.0;
        let t = stretch_timeline(1, 1);
        let rows = g.rows(&t);
        match g.hit_test(pt(400.0, rows[1].max_y() - 2.0), &t) {
            TimelineHit::Gap(tid, _) => assert_eq!(tid, t.tracks[1].id),
            other => panic!("not a gap: {other:?}"),
        }
    }

    // --- TrackHeightModeTests

    #[test]
    fn small_is_thin_and_does_not_stretch() {
        let mut g = TimelineGeometry::new(Time::new(1, 25), 50.0);
        g.viewport_height = 900.0;
        g.height_mode = TrackHeightMode::Small;
        assert!(g.rows(&stretch_timeline(1, 1)).iter().all(|r| r.height == 24.0));
    }

    #[test]
    fn large_is_taller_and_auto_stretches() {
        let mut g = TimelineGeometry::new(Time::new(1, 25), 50.0);
        g.viewport_height = 900.0;
        g.height_mode = TrackHeightMode::Large;
        let t = stretch_timeline(1, 1);
        assert_eq!(g.rows(&t).iter().map(|r| r.height).collect::<Vec<_>>(), [72.0, 56.0]);
        g.height_mode = TrackHeightMode::Auto;
        assert!(g.rows(&t).iter().map(|r| r.height).sum::<f64>() > 128.0);
    }
}
