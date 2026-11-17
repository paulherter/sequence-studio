// Swift: TrackSizing.swift
//! Track height editing (Premiere behavior): resizing one track or a whole kind, the V/A split, minimize / expand,
//! and the stepped height commands. Pure functions over the rows as drawn. Every result is a FULL set of height
//! overrides (all tracks), so a resize freezes the layout and the other rows do not re-stretch under the pointer;
//! `expanded_all` (no overrides) hands the space back to the automatic fit.

use crate::portable_theme::metrics;
use crate::timeline_geometry::{TimelineGeometry, TrackRow};
use sq_core_model::TrackKind;
use sq_core_time::Id;
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::keyframe_graph_geometry::Point;
use std::collections::BTreeMap;

/// Default row height preset for tracks without a user override. `Auto` stretches the rows to fill the panel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrackHeightMode {
    /// 24 pt.
    Small,
    /// The default heights.
    Medium,
    /// 72 / 56 pt.
    Large,
    /// Stretch to fill the panel.
    Auto,
}

impl TrackHeightMode {
    /// All cases.
    pub const ALL: [TrackHeightMode; 4] =
        [TrackHeightMode::Small, TrackHeightMode::Medium, TrackHeightMode::Large, TrackHeightMode::Auto];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            TrackHeightMode::Small => "small",
            TrackHeightMode::Medium => "medium",
            TrackHeightMode::Large => "large",
            TrackHeightMode::Auto => "auto",
        }
    }

    /// From the Swift raw value.
    pub fn from_raw(s: &str) -> Option<TrackHeightMode> {
        Self::ALL.into_iter().find(|m| m.raw_value() == s)
    }

    /// Row height by kind; `None` for `Auto` (the stretch decides).
    pub fn height(self, kind: TrackKind) -> Option<f64> {
        match self {
            TrackHeightMode::Small => Some(24.0),
            TrackHeightMode::Medium => {
                Some(if kind == TrackKind::Video { metrics::TRACK_V1 } else { metrics::TRACK_A1 })
            }
            TrackHeightMode::Large => Some(if kind == TrackKind::Video { 72.0 } else { 56.0 }),
            TrackHeightMode::Auto => None,
        }
    }
}

/// Zone under the pointer for track resizing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackSizingZone {
    /// Bottom edge of this track's header: drag to resize the track (Shift = every track of its kind).
    TrackEdge(Id),
    /// The boundary between the lowest video track and the first audio track, across the whole width.
    Split,
}

/// Namespace of the track sizing functions.
pub struct TrackSizing;

impl TrackSizing {
    /// A minimized track: color and name only.
    pub const MINIMIZED_HEIGHT: f64 = 18.0;
    /// Tallest row.
    pub const MAX_HEIGHT: f64 = 240.0;
    /// One step of the height commands.
    pub const STEP: f64 = 8.0;
    /// Grab distance around a row boundary.
    pub const GRAB: f64 = 3.0;
    /// Default V/A split: the exact middle of the track area.
    pub const DEFAULT_SPLIT_FRACTION: f64 = 0.5;
    /// Least height either side of the split keeps (one minimized row).
    pub const MIN_SPLIT_SIDE: f64 = Self::MINIMIZED_HEIGHT;

    /// `h` clamped to the allowed row heights.
    pub fn clamp(h: f64) -> f64 {
        h.clamp(Self::MINIMIZED_HEIGHT, Self::MAX_HEIGHT)
    }

    /// The heights as drawn, as overrides.
    pub fn frozen(rows: &[TrackRow]) -> BTreeMap<Id, f64> {
        rows.iter().map(|r| (r.track, r.height)).collect()
    }

    /// Edge drag: `id` gets `height`; with `whole_kind` every track of that kind does.
    pub fn resized(rows: &[TrackRow], id: Id, height: f64, whole_kind: bool) -> BTreeMap<Id, f64> {
        let mut out = Self::frozen(rows);
        let Some(row) = rows.iter().find(|r| r.track == id) else { return out };
        let h = Self::clamp(height);
        for r in rows {
            if r.track == id || (whole_kind && r.kind == row.kind) {
                out.insert(r.track, h);
            }
        }
        out
    }

    /// Offset of the split from the top of the track area, for a fraction of `available`; clamped so each side keeps
    /// `MIN_SPLIT_SIDE` (or half the area when it is tighter than that).
    pub fn split_offset(fraction: f64, available: f64) -> f64 {
        let usable = available > 0.0;
        if !usable {
            return 0.0;
        }
        let margin = Self::MIN_SPLIT_SIDE.min(available / 2.0);
        (fraction * available).max(margin).min(available - margin)
    }

    /// The fraction after dragging the split `dy` points (down = positive) from `start_fraction`. Track heights are not
    /// part of it: the split only moves.
    pub fn split_fraction(start_fraction: f64, dy: f64, available: f64) -> f64 {
        let usable = available > 0.0;
        if !usable {
            return Self::DEFAULT_SPLIT_FRACTION;
        }
        let moved = Self::split_offset(start_fraction, available) + dy;
        Self::split_offset(moved / available, available) / available
    }

    /// `direction` +1 / -1 changes the height of the tracks of `kind` (`None` = all tracks) by one step.
    pub fn stepped(rows: &[TrackRow], kind: Option<TrackKind>, direction: i64) -> BTreeMap<Id, f64> {
        let mut out = Self::frozen(rows);
        for r in rows {
            if kind.is_none() || Some(r.kind) == kind {
                out.insert(r.track, Self::clamp(r.height + Self::STEP * direction as f64));
            }
        }
        out
    }

    /// Fit All Tracks: splits `available` points over tracks in proportion to `weights`, each clamped to
    /// `MINIMIZED_HEIGHT...MAX_HEIGHT` (water-filling: what a clamped track cannot take goes to the others). When even the
    /// minimum does not fit, every track gets the minimum and the timeline scrolls.
    pub fn fit_heights(weights: &[f64], available: f64) -> Vec<f64> {
        if weights.is_empty() {
            return Vec::new();
        }
        let mut h: Vec<Option<f64>> = vec![None; weights.len()];
        let mut left = available.max(0.0);
        let mut open: Vec<usize> = (0..weights.len()).collect();
        while !open.is_empty() {
            let total = open.iter().fold(0.0, |a, &i| a + weights[i].max(0.0001));
            let mut clamped_any = false;
            for &i in &open {
                let share = left * weights[i].max(0.0001) / total;
                if share < Self::MINIMIZED_HEIGHT {
                    h[i] = Some(Self::MINIMIZED_HEIGHT);
                    left -= Self::MINIMIZED_HEIGHT;
                    clamped_any = true;
                } else if share > Self::MAX_HEIGHT {
                    h[i] = Some(Self::MAX_HEIGHT);
                    left -= Self::MAX_HEIGHT;
                    clamped_any = true;
                }
                if clamped_any {
                    break; // one clamp changes the shares: restart with the rest
                }
            }
            if !clamped_any {
                for &i in &open {
                    h[i] = Some(left * weights[i].max(0.0001) / total);
                }
                break;
            }
            open.retain(|&i| h[i].is_none());
            left = left.max(0.0);
        }
        h.into_iter().map(|x| x.unwrap_or(Self::MINIMIZED_HEIGHT)).collect()
    }

    /// Double-click on a track header: a track below the Large preset grows to Large, a larger one returns to Medium.
    /// `whole_kind` (Shift) does the same for every track of that kind, by the clicked track's current height.
    pub fn toggled(rows: &[TrackRow], id: Id, whole_kind: bool) -> BTreeMap<Id, f64> {
        let mut out = Self::frozen(rows);
        let Some(row) = rows.iter().find(|r| r.track == id) else { return out };
        let large = TrackHeightMode::Large.height(row.kind).unwrap_or(row.height);
        let target = if row.height < large - 0.5 {
            large
        } else {
            TrackHeightMode::Medium.height(row.kind).unwrap_or(row.height)
        };
        for r in rows {
            if r.track == id || (whole_kind && r.kind == row.kind) {
                out.insert(r.track, Self::clamp(target));
            }
        }
        out
    }

    /// Every track minimized.
    pub fn minimized_all(rows: &[TrackRow]) -> BTreeMap<Id, f64> {
        rows.iter().map(|r| (r.track, Self::MINIMIZED_HEIGHT)).collect()
    }

    /// No overrides: default heights, stretched to fill the panel.
    pub fn expanded_all() -> BTreeMap<Id, f64> {
        BTreeMap::new()
    }

    // MARK: Hit zones

    /// Zone under `p` (view coordinates). The V/A boundary is the split over the full width; every other row
    /// boundary resizes the track above it, in the header column only.
    pub fn zone(p: Point, rows: &[TrackRow], view_width: f64) -> Option<TrackSizingZone> {
        if !(p.x >= TimelineGeometry::TOOL_COLUMN_WIDTH && p.x < view_width && p.y > TimelineGeometry::RULER_HEIGHT) {
            return None;
        }
        let in_header = p.x < TimelineGeometry::CONTENT_ORIGIN_X;
        for (i, r) in rows.iter().enumerate() {
            if (p.y - r.max_y()).abs() <= Self::GRAB {
                if i + 1 < rows.len() && r.kind == TrackKind::Video && rows[i + 1].kind == TrackKind::Audio {
                    return Some(TrackSizingZone::Split);
                }
                if in_header {
                    return Some(TrackSizingZone::TrackEdge(r.track));
                }
            }
        }
        None
    }
}

/// Track heights per sequence, kept in the settings store (the project file has no view-state slot, and heights are not
/// undoable edits). Key: `sq.trackHeights.<sequence id>`, value: JSON `{trackID: points}`.
pub struct TrackHeightStore<'a> {
    defaults: &'a mut dyn SettingsStore,
}

impl<'a> TrackHeightStore<'a> {
    /// A store over `defaults`.
    pub fn new(defaults: &'a mut dyn SettingsStore) -> TrackHeightStore<'a> {
        TrackHeightStore { defaults }
    }

    /// Settings key of the heights of a sequence.
    pub fn key(sequence: Id) -> String {
        format!("sq.trackHeights.{sequence}")
    }

    /// The stored heights of a sequence (clamped; broken entries dropped).
    pub fn load(&self, sequence: Id) -> BTreeMap<Id, f64> {
        let Some(data) = self.defaults.data(&Self::key(sequence)) else { return BTreeMap::new() };
        let Ok(raw) = serde_json::from_slice::<BTreeMap<String, f64>>(&data) else { return BTreeMap::new() };
        let mut out = BTreeMap::new();
        for (k, v) in raw {
            if let Some(id) = Id::parse(&k)
                && v.is_finite()
            {
                out.insert(id, TrackSizing::clamp(v));
            }
        }
        out
    }

    /// Settings key of the split of a sequence.
    pub fn split_key(sequence: Id) -> String {
        format!("sq.trackSplit.{sequence}")
    }

    /// The V/A split fraction of a sequence; the default (middle) when none is stored.
    pub fn load_split(&self, sequence: Id) -> f64 {
        let stored = self
            .defaults
            .data(&Self::split_key(sequence))
            .and_then(|d| serde_json::from_slice::<f64>(&d).ok())
            .filter(|v| v.is_finite());
        match stored {
            Some(v) => v.clamp(0.0, 1.0),
            None => TrackSizing::DEFAULT_SPLIT_FRACTION,
        }
    }

    /// Stores the split; the default is stored as nothing.
    pub fn save_split(&mut self, fraction: f64, sequence: Id) {
        if (fraction - TrackSizing::DEFAULT_SPLIT_FRACTION).abs() < 0.0005 {
            self.defaults.remove(&Self::split_key(sequence));
            return;
        }
        if let Ok(data) = serde_json::to_vec(&fraction) {
            self.defaults.set_data(&Self::split_key(sequence), data);
        }
    }

    /// Stores the heights of a sequence; none stores nothing.
    pub fn save(&mut self, heights: &BTreeMap<Id, f64>, sequence: Id) {
        if heights.is_empty() {
            self.defaults.remove(&Self::key(sequence));
            return;
        }
        let raw: BTreeMap<String, f64> = heights.iter().map(|(k, v)| (k.to_string(), *v)).collect();
        if let Ok(data) = serde_json::to_vec(&raw) {
            self.defaults.set_data(&Self::key(sequence), data);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(heights: &[(TrackKind, f64)]) -> Vec<TrackRow> {
        let mut y = 0.0;
        heights
            .iter()
            .enumerate()
            .map(|(i, h)| {
                let r = TrackRow {
                    track: Id::from_u128(i as u128 + 1),
                    kind: h.0,
                    label: i.to_string(),
                    y,
                    height: h.1,
                    lane_space: 0.0,
                };
                y += h.1;
                r
            })
            .collect()
    }

    #[test]
    fn smaller_track_grows_to_large_and_large_goes_back_to_medium() {
        let r = rows(&[(TrackKind::Video, 40.0), (TrackKind::Audio, 28.0)]);
        let grown = TrackSizing::toggled(&r, r[0].track, false);
        assert_eq!(grown[&r[0].track], TrackHeightMode::Large.height(TrackKind::Video).unwrap());
        assert_eq!(grown[&r[1].track], 28.0); // other rows stay as drawn
        let big = rows(&[(TrackKind::Video, 72.0), (TrackKind::Audio, 28.0)]);
        let back = TrackSizing::toggled(&big, big[0].track, false);
        assert_eq!(back[&big[0].track], TrackHeightMode::Medium.height(TrackKind::Video).unwrap());
    }

    #[test]
    fn minimized_track_grows_to_large() {
        let r = rows(&[(TrackKind::Audio, TrackSizing::MINIMIZED_HEIGHT)]);
        assert_eq!(
            TrackSizing::toggled(&r, r[0].track, false)[&r[0].track],
            TrackHeightMode::Large.height(TrackKind::Audio).unwrap()
        );
    }

    #[test]
    fn shift_applies_to_every_track_of_the_kind_only() {
        let r = rows(&[(TrackKind::Video, 40.0), (TrackKind::Video, 50.0), (TrackKind::Audio, 28.0)]);
        let out = TrackSizing::toggled(&r, r[0].track, true);
        assert!(out[&r[0].track] == 72.0 && out[&r[1].track] == 72.0 && out[&r[2].track] == 28.0);
    }

    #[test]
    fn unknown_track_changes_nothing() {
        let r = rows(&[(TrackKind::Video, 40.0)]);
        assert_eq!(TrackSizing::toggled(&r, Id::from_u128(99), false), TrackSizing::frozen(&r));
    }

    #[test]
    fn split_offset_keeps_each_side() {
        assert_eq!(TrackSizing::split_offset(0.5, 200.0), 100.0);
        assert_eq!(TrackSizing::split_offset(0.0, 200.0), 18.0);
        assert_eq!(TrackSizing::split_offset(1.0, 200.0), 182.0);
        assert_eq!(TrackSizing::split_offset(0.5, 0.0), 0.0);
    }

    #[test]
    fn height_store_round_trips() {
        let mut settings = sq_library::library_folder_store::MemorySettings::default();
        let seq = Id::from_u128(7);
        let t = Id::from_u128(8);
        let mut store = TrackHeightStore::new(&mut settings);
        store.save(&BTreeMap::from([(t, 500.0)]), seq);
        assert_eq!(store.load(seq), BTreeMap::from([(t, TrackSizing::MAX_HEIGHT)]));
        store.save_split(0.5, seq);
        assert_eq!(store.load_split(seq), 0.5);
        store.save_split(0.25, seq);
        assert_eq!(store.load_split(seq), 0.25);
    }
}
