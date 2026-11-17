// Swift: PlayheadLogic.swift
//! Timeline scroll policy during playback and the Shift snap of the playhead drag.

use crate::timeline_feel::PlaybackFollow;
use crate::timeline_geometry::TimelineGeometry;
use sq_core_edit::snapping::{SnapPoint, SnappingTimelineExt, snap};
use sq_core_edit::timeline_beat_snap::{BeatSnapLevel, TimelineBeatSnapExt};
use sq_core_model::Timeline;
use sq_core_time::Time;
use std::collections::BTreeSet;

/// Timeline scroll policy during playback (page-wise follow, manual scroll wins).
/// The playhead pages the view when it reaches an edge; once the user scrolls or zooms while playing, the view stays
/// where they put it until playback is started again.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TimelineFollow {
    manual_scroll_wins: bool,
}

impl TimelineFollow {
    /// A fresh policy.
    pub fn new() -> TimelineFollow {
        TimelineFollow::default()
    }

    /// True once the user scrolled while playing.
    pub fn manual_scroll_wins(&self) -> bool {
        self.manual_scroll_wins
    }

    /// Play was pressed. A playhead that is off screen at that moment means the user is looking elsewhere on purpose.
    pub fn playback_started(&mut self, playhead_visible: bool) {
        self.manual_scroll_wins = !playhead_visible;
    }

    /// The viewport changed by the user (wheel, drag, zoom). Only a change during playback overrides the follow.
    pub fn user_scrolled(&mut self, while_playing: bool) {
        if while_playing {
            self.manual_scroll_wins = true;
        }
    }

    /// New `scroll_x` when the view must page, `None` when it stays. `view_left`/`view_right` bound the content area in
    /// view coordinates; the playhead lands `margin` points from the left edge after a page.
    pub fn page_scroll(
        &self,
        playhead_x: f64,
        scroll_x: f64,
        view_left: f64,
        view_right: f64,
        margin: f64,
    ) -> Option<f64> {
        if self.manual_scroll_wins {
            return None;
        }
        if !(playhead_x > view_right - 12.0 || playhead_x < view_left) {
            return None;
        }
        Some(scroll_x + (playhead_x - view_left) - margin)
    }

    /// The default page margin.
    pub const PAGE_MARGIN: f64 = 24.0;

    /// Continuous follow (Final Cut): the playhead runs to the center of the content area, then the content scrolls
    /// under it. A playhead left of the view (loop back) is brought to the center too. Never scrolls before time 0.
    pub fn continuous_scroll(&self, playhead_x: f64, scroll_x: f64, view_left: f64, view_right: f64) -> Option<f64> {
        if self.manual_scroll_wins {
            return None;
        }
        let centre = (view_left + view_right) / 2.0;
        if !(playhead_x > centre || playhead_x < view_left) {
            return None;
        }
        let target = (scroll_x + playhead_x - centre).max(0.0);
        if target == scroll_x { None } else { Some(target) }
    }

    /// The scroll for `mode` (`None`: stay).
    pub fn scroll(
        &self,
        mode: PlaybackFollow,
        playhead_x: f64,
        scroll_x: f64,
        view_left: f64,
        view_right: f64,
    ) -> Option<f64> {
        match mode {
            PlaybackFollow::Page => self.page_scroll(playhead_x, scroll_x, view_left, view_right, Self::PAGE_MARGIN),
            PlaybackFollow::Continuous => self.continuous_scroll(playhead_x, scroll_x, view_left, view_right),
        }
    }
}

/// Shift while dragging the playhead: it sticks to clip edges, markers and time 0 (Premiere).
pub struct PlayheadSnap;

impl PlayheadSnap {
    /// Snap distance in points.
    pub const THRESHOLD_POINTS: f64 = 10.0;

    /// The snapped time and the point it snapped to.
    pub fn resolve(
        t: Time,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        beat_level: BeatSnapLevel,
    ) -> (Time, Option<SnapPoint>) {
        let markers = timeline.marker_snap_times(beat_level, 4);
        let points = timeline.snap_points(&BTreeSet::new(), None, &markers, false);
        snap(t, &points, geometry.snap_threshold(Self::THRESHOLD_POINTS), Some(geometry.frame_duration))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_edit::snapping::SnapKind;
    use sq_core_model::{Clip, Marker, SequenceFormat, Track, TrackKind};
    use sq_core_time::{Id, TimeRange};

    const FD: Time = Time::new(1, 24);

    fn frames(n: i64) -> Time {
        FD * n
    }

    // View content spans x 160...1000, 24 pt margin.
    fn page(f: &TimelineFollow, playhead_x: f64, scroll_x: f64) -> Option<f64> {
        f.page_scroll(playhead_x, scroll_x, 160.0, 1000.0, TimelineFollow::PAGE_MARGIN)
    }

    #[test]
    fn inside_the_view_does_not_scroll() {
        assert_eq!(page(&TimelineFollow::new(), 500.0, 0.0), None);
    }

    #[test]
    fn leaving_the_right_edge_jumps_a_page() {
        // Playhead at x 995 (within 12 pt of the edge): the playhead moves to 24 pt from the left edge.
        assert_eq!(page(&TimelineFollow::new(), 995.0, 100.0), Some(911.0));
    }

    #[test]
    fn leaving_the_left_edge_jumps_a_page() {
        assert_eq!(page(&TimelineFollow::new(), 100.0, 400.0), Some(316.0));
    }

    #[test]
    fn manual_scroll_wins_while_playing_until_playback_restarts() {
        let mut f = TimelineFollow::new();
        f.playback_started(true);
        f.user_scrolled(true);
        assert_eq!(page(&f, 2000.0, 0.0), None); // the user looks elsewhere: no forced follow
        f.playback_started(true);
        assert!(page(&f, 2000.0, 0.0).is_some()); // restart: following again
    }

    #[test]
    fn scrolling_while_paused_does_not_disable_follow() {
        let mut f = TimelineFollow::new();
        f.user_scrolled(false);
        f.playback_started(true);
        assert!(page(&f, 2000.0, 0.0).is_some());
    }

    #[test]
    fn starting_playback_with_the_playhead_off_screen_does_not_yank_the_view() {
        let mut f = TimelineFollow::new();
        f.playback_started(false);
        assert_eq!(page(&f, 2000.0, 0.0), None);
    }

    #[test]
    fn continuous_keeps_playhead_at_centre_once_passed() {
        let f = TimelineFollow::new();
        // Content area 100...1100, center 600.
        assert_eq!(f.continuous_scroll(400.0, 0.0, 100.0, 1100.0), None);
        assert_eq!(f.continuous_scroll(610.0, 50.0, 100.0, 1100.0), Some(60.0));
        // Off screen to the left (loop back to the start): bring it to the center, never before time 0.
        assert_eq!(f.continuous_scroll(50.0, 2000.0, 100.0, 1100.0), Some(1450.0));
        assert_eq!(f.continuous_scroll(50.0, 20.0, 100.0, 1100.0), Some(0.0));
    }

    #[test]
    fn continuous_respects_manual_scroll() {
        let mut f = TimelineFollow::new();
        f.user_scrolled(true);
        assert_eq!(f.continuous_scroll(900.0, 0.0, 100.0, 1100.0), None);
    }

    #[test]
    fn follow_dispatches_on_mode() {
        let f = TimelineFollow::new();
        assert_eq!(f.scroll(PlaybackFollow::Page, 700.0, 0.0, 100.0, 1100.0), None);
        assert_eq!(f.scroll(PlaybackFollow::Continuous, 700.0, 0.0, 100.0, 1100.0), Some(100.0));
    }

    fn timeline() -> Timeline {
        let clip = |n: u128, start: i64| {
            Clip::new(
                Id::from_u128(n),
                "c",
                Id::from_u128(900 + n),
                TrackKind::Video,
                TimeRange::new(Time::ZERO, frames(20)),
                frames(start),
            )
        };
        let mut track = Track::new(Id::from_u128(10), TrackKind::Video);
        track.set_clips(vec![clip(1, 10), clip(2, 50)]);
        let mut t = Timeline::new(Id::from_u128(11), "t", SequenceFormat::new(FD), vec![track]);
        t.markers = vec![Marker {
            id: Id::from_u128(12),
            time: frames(100),
            name: String::new(),
            color: Default::default(),
            comment: String::new(),
            duration: Time::ZERO,
        }];
        t
    }

    fn geo() -> TimelineGeometry {
        TimelineGeometry::new(FD, 96.0) // 4 pt per frame
    }

    fn resolve(f: i64) -> (Time, Option<SnapPoint>) {
        PlayheadSnap::resolve(frames(f), &timeline(), &geo(), BeatSnapLevel::EveryBeat)
    }

    #[test]
    fn snaps_to_clip_edges_within_ten_points() {
        let r = resolve(31); // 1 frame = 4 pt from a's end (30)
        assert_eq!(r.0, frames(30));
        assert_eq!(r.1.map(|p| p.kind), Some(SnapKind::ClipEdge));
        assert_eq!(resolve(48).0, frames(50));
    }

    #[test]
    fn snaps_to_markers() {
        let r = resolve(101);
        assert_eq!(r.0, frames(100));
        assert_eq!(r.1.map(|p| p.kind), Some(SnapKind::Marker));
    }

    #[test]
    fn far_from_everything_keeps_the_frame() {
        let r = resolve(40);
        assert_eq!(r.0, frames(40));
        assert_eq!(r.1, None);
    }

    #[test]
    fn zero_is_a_target() {
        assert_eq!(resolve(1).0, Time::ZERO);
    }
}
