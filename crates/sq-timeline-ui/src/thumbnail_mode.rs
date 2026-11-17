// Swift: ThumbnailMode.swift
//! What the thumbnails of a video clip on the timeline show and where the tiles sit.

use sq_core_model::Clip;
use sq_core_time::Time;
use sq_library::library_folder_store::SettingsStore;
use std::ops::RangeInclusive;

/// What the thumbnails of a video clip on the timeline show: the first frame in a column at the head (the default),
/// the first and the last frame, or a strip of frames along the whole clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ThumbnailMode {
    /// The first frame.
    Head,
    /// The first and the last frame.
    HeadAndTail,
    /// A strip along the whole clip.
    Continuous,
}

impl ThumbnailMode {
    /// All cases.
    pub const ALL: [ThumbnailMode; 3] = [ThumbnailMode::Head, ThumbnailMode::HeadAndTail, ThumbnailMode::Continuous];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            ThumbnailMode::Head => "head",
            ThumbnailMode::HeadAndTail => "headAndTail",
            ThumbnailMode::Continuous => "continuous",
        }
    }

    /// From the Swift raw value.
    pub fn from_raw(s: &str) -> Option<ThumbnailMode> {
        Self::ALL.into_iter().find(|m| m.raw_value() == s)
    }

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            ThumbnailMode::Head => "Head",
            ThumbnailMode::HeadAndTail => "Head and Tail",
            ThumbnailMode::Continuous => "Continuous",
        }
    }
}

/// The choice is a user preference of the app (settings `sq.timeline.thumbnailMode`), not part of a project.
pub struct ThumbnailPrefs;

impl ThumbnailPrefs {
    /// Settings key.
    pub const MODE_KEY: &'static str = "sq.timeline.thumbnailMode";

    /// The stored mode (default head).
    pub fn mode(store: &dyn SettingsStore) -> ThumbnailMode {
        store
            .data(Self::MODE_KEY)
            .and_then(|d| String::from_utf8(d).ok())
            .and_then(|s| ThumbnailMode::from_raw(&s))
            .unwrap_or(ThumbnailMode::Head)
    }

    /// Stores the mode. Swift also posts `didChange`; the caller redraws.
    pub fn set_mode(store: &mut dyn SettingsStore, mode: ThumbnailMode) {
        store.set_data(Self::MODE_KEY, mode.raw_value().as_bytes().to_vec());
    }
}

/// Which frame a tile shows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ThumbnailAnchor {
    /// The clip's first frame.
    Head,
    /// The clip's last frame.
    Tail,
    /// The frame at this share (0...1) of the clip's length.
    Fraction(f64),
}

/// One picture of a clip's thumbnails, in clip-local points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ThumbnailTile {
    /// Distance of the tile's left edge from the clip's left edge.
    pub offset: f64,
    /// Width.
    pub width: f64,
    /// The frame it shows.
    pub anchor: ThumbnailAnchor,
    /// Drawn under the name strip instead of beside it (the strip modes keep the name readable).
    pub below_name_strip: bool,
}

/// Thumbnail tiles.
pub struct ThumbnailLayout;

impl ThumbnailLayout {
    /// Most tiles a clip gets in one draw (a safety cap far above what a screen shows).
    const MAX_TILES: i64 = 400;

    /// The tiles of a clip `clip_width` points wide.
    /// - `column`: the head column's width (`ClipBodyMetrics::thumbnail_column` result, 0 = the clip shows no thumbnails).
    /// - `visible`: the part of the clip on screen in clip-local points; tiles outside it are not made.
    pub fn tiles(
        mode: ThumbnailMode,
        clip_width: f64,
        column: f64,
        visible: &RangeInclusive<f64>,
    ) -> Vec<ThumbnailTile> {
        if !(column > 0.0 && clip_width > 0.0) {
            return Vec::new();
        }
        let head = ThumbnailTile { offset: 0.0, width: column, anchor: ThumbnailAnchor::Head, below_name_strip: true };
        match mode {
            ThumbnailMode::Head => vec![head],
            ThumbnailMode::HeadAndTail => {
                // A clip too short for two columns and a name keeps only the head.
                if clip_width < column * 2.0 + 24.0 {
                    return vec![head];
                }
                vec![
                    head,
                    ThumbnailTile {
                        offset: clip_width - column,
                        width: column,
                        anchor: ThumbnailAnchor::Tail,
                        below_name_strip: true,
                    },
                ]
            }
            ThumbnailMode::Continuous => {
                let w = column * 2.0;
                let first = ((visible.start().max(0.0) / w).floor() as i64).max(0);
                let last = (visible.end().min(clip_width) / w).floor() as i64;
                if last < first {
                    return Vec::new();
                }
                let mut out = Vec::new();
                for i in first..=last.min(first + Self::MAX_TILES) {
                    let x = i as f64 * w;
                    if x >= clip_width {
                        break;
                    }
                    let tile = w.min(clip_width - x);
                    // The first tile shows the first frame, the last one the last frame; the rest the frame under their center.
                    let anchor = if i == 0 {
                        ThumbnailAnchor::Head
                    } else if x + w >= clip_width {
                        ThumbnailAnchor::Tail
                    } else {
                        ThumbnailAnchor::Fraction((x + tile / 2.0) / clip_width)
                    };
                    out.push(ThumbnailTile { offset: x, width: tile, anchor, below_name_strip: true });
                }
                out
            }
        }
    }

    /// Media time a tile asks for. Interior frames snap to a quarter second so zooming reuses cached pictures; the first
    /// and last frame are exact.
    pub fn media_time(anchor: ThumbnailAnchor, c: &Clip, fd: Time) -> Time {
        let last_frame = c.timeline().start.max(c.timeline().end() - fd);
        match anchor {
            ThumbnailAnchor::Head => c.source_time(c.timeline().start, fd),
            ThumbnailAnchor::Tail => c.source_time(last_frame, fd),
            ThumbnailAnchor::Fraction(f) => {
                let local = Time::scaled_int(c.timeline().duration, (f.clamp(0.0, 1.0) * 1000.0).round() as i64, 1000);
                let at = (c.timeline().start + local).snapped(fd).max(c.timeline().start).min(last_frame);
                c.source_time(at, fd).snapped(Time::new(1, 4))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_library::library_folder_store::MemorySettings;

    #[test]
    fn head_and_tail_need_room_for_both_columns() {
        let all = 0.0..=1000.0;
        assert_eq!(ThumbnailLayout::tiles(ThumbnailMode::Head, 200.0, 25.0, &all).len(), 1);
        assert_eq!(ThumbnailLayout::tiles(ThumbnailMode::HeadAndTail, 200.0, 25.0, &all).len(), 2);
        assert_eq!(ThumbnailLayout::tiles(ThumbnailMode::HeadAndTail, 60.0, 25.0, &all).len(), 1);
        assert!(ThumbnailLayout::tiles(ThumbnailMode::Head, 200.0, 0.0, &all).is_empty());
    }

    #[test]
    fn continuous_strip_runs_head_to_tail_and_skips_what_is_off_screen() {
        let tiles = ThumbnailLayout::tiles(ThumbnailMode::Continuous, 230.0, 25.0, &(0.0..=230.0));
        assert_eq!(tiles.first().map(|t| t.anchor), Some(ThumbnailAnchor::Head));
        assert_eq!(tiles.last().map(|t| t.anchor), Some(ThumbnailAnchor::Tail));
        assert!(tiles.iter().all(|t| t.below_name_strip));
        let seen = ThumbnailLayout::tiles(ThumbnailMode::Continuous, 5000.0, 25.0, &(1000.0..=1100.0));
        assert!(seen.iter().all(|t| t.offset + t.width >= 950.0 && t.offset <= 1100.0));
    }

    #[test]
    fn interior_frames_snap_to_a_quarter_second() {
        let c = mk(0, 240, sq_core_model::TrackKind::Video, None);
        let t = ThumbnailLayout::media_time(ThumbnailAnchor::Fraction(0.5), &c, FD);
        assert_eq!(t.snapped(Time::new(1, 4)), t);
        assert_eq!(ThumbnailLayout::media_time(ThumbnailAnchor::Head, &c, FD), c.source.start);
    }

    #[test]
    fn mode_preference_round_trips() {
        let mut s = MemorySettings::default();
        assert_eq!(ThumbnailPrefs::mode(&s), ThumbnailMode::Head);
        ThumbnailPrefs::set_mode(&mut s, ThumbnailMode::Continuous);
        assert_eq!(ThumbnailPrefs::mode(&s), ThumbnailMode::Continuous);
    }
}
