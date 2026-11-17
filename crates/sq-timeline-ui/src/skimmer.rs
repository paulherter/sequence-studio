// Swift: Skimmer.swift
//! Fast Cut skimmer (Final Cut's skimmer, our name: hover playhead): a second, yellow line follows the pointer over the
//! tracks (never in the ruler, no head) and shows that frame in the Program monitor while the main playhead stays put.
//! Pure rules; the draw layer draws it and reports it to the host.

use crate::portable_theme::playhead_skin;
use crate::timeline_geometry::TimelineGeometry;
use sq_core_time::Time;
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// Namespace of the skimmer rules.
pub struct Skimmer;

/// Why the skimmer is not shown right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SkimmerContext {
    /// The sequence is a Fast Cut one.
    pub is_fast_cut: bool,
    /// A drag (clip, edge, scrub, marker, zoom box ...) is in flight.
    pub is_dragging: bool,
    /// Playback runs.
    pub is_playing: bool,
    /// The razor tool shows its own hover guide.
    pub is_razor: bool,
}

impl SkimmerContext {
    fn allows_skimming(&self) -> bool {
        self.is_fast_cut && !self.is_dragging && !self.is_playing && !self.is_razor
    }
}

impl Skimmer {
    /// Line thickness: the same 2 pt as every playhead line, so it reads as a playhead, in its own color.
    pub const WIDTH: f64 = playhead_skin::LINE_WIDTH;

    /// The pointer is over the track lanes: right of the headers, below the ruler, above the zoom bar.
    pub fn is_over_tracks(p: Point, view_height: f64, zoom_bar_height: f64) -> bool {
        p.x >= TimelineGeometry::CONTENT_ORIGIN_X
            && p.y >= TimelineGeometry::RULER_HEIGHT
            && p.y < view_height - zoom_bar_height
    }

    /// Sequence time the skimmer shows for a pointer (frame-snapped, same mapping as a ruler scrub without Shift);
    /// `None` when it is hidden: not Fast Cut, a gesture or playback running, the razor tool, or the pointer off the tracks.
    pub fn time(
        pointer: Option<Point>,
        context: SkimmerContext,
        view_height: f64,
        zoom_bar_height: f64,
        geometry: &TimelineGeometry,
    ) -> Option<Time> {
        let p = pointer?;
        if !context.allows_skimming() || !Self::is_over_tracks(p, view_height, zoom_bar_height) {
            return None;
        }
        Some(geometry.time(p.x))
    }

    /// The line over the tracks (the ruler has none).
    pub fn line_rect(x: f64, view_height: f64, zoom_bar_height: f64) -> Rect {
        playhead_skin::line_frame(
            x,
            TimelineGeometry::RULER_HEIGHT,
            (view_height - zoom_bar_height - TimelineGeometry::RULER_HEIGHT).max(0.0),
        )
    }
}
