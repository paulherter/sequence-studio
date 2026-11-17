// Swift: CaptionWordLayout.swift
//! Level of detail and geometry of the words on the caption track.

use crate::timeline_geometry::{CaptionRow, ClipZone, TimelineGeometry};
use sq_core_audio::caption_handover::TimelineCaptionsExt;
use sq_core_model::{CaptionItem, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// One word of a caption on the caption track (index into `CaptionItem::tokens`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CaptionWordRef {
    /// The caption item.
    pub caption: Id,
    /// Word index.
    pub index: usize,
}

impl CaptionWordRef {
    /// A reference to word `index` of `caption`.
    pub fn new(caption: Id, index: usize) -> CaptionWordRef {
        CaptionWordRef { caption, index }
    }
}

/// What a point on the caption track hits at word level: the word and whether it is one of its edges (retime) or its body.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CaptionWordHit {
    /// The word.
    pub word: CaptionWordRef,
    /// Edge or body.
    pub zone: ClipZone,
}

/// Level of detail and geometry of the words on the caption track. Pure: the same zoom and caption always give the
/// same answer, so nothing flickers while scrolling or playing (only a zoom step can switch a caption between its two
/// pictures, and each caption switches exactly once on the way).
pub struct CaptionWordLayout;

impl CaptionWordLayout {
    /// Zoom from which a caption track shows words at all (points per second). Below it every caption is one block.
    pub const WORD_LEVEL_POINTS_PER_SECOND: f64 = 60.0;
    /// A caption shows its words only when they are this wide on average; a fast speaker stays a block a little longer.
    pub const MIN_AVERAGE_WORD_WIDTH: f64 = 18.0;
    /// Width of the grab zone at a word edge.
    pub const EDGE_GRAB: f64 = 4.0;
    /// The narrowest word that still has edges to grab.
    pub const MIN_WIDTH_FOR_EDGES: f64 = 14.0;
    /// Space between a word box and the caption's body, top and bottom.
    pub const BOX_INSET_Y: f64 = 3.0;
    /// Space between two touching word boxes (half on each side).
    pub const BOX_GAP: f64 = 1.0;
    /// A caption narrower than this is drawn as a plain sliver (no outline, no text).
    pub const SLIVER_WIDTH: f64 = 3.0;

    /// True when `item` is drawn as word boxes at this zoom.
    pub fn shows_words(item: &CaptionItem, geometry: &TimelineGeometry) -> bool {
        if geometry.points_per_second < Self::WORD_LEVEL_POINTS_PER_SECOND {
            return false;
        }
        let n = Self::word_count(item);
        if n == 0 {
            return false;
        }
        let width = geometry.x(item.range.end()) - geometry.x(item.range.start);
        width / n as f64 >= Self::MIN_AVERAGE_WORD_WIDTH
    }

    /// Zoom (points per second) at which `item` shows its words.
    pub fn zoom_for_words(item: &CaptionItem) -> f64 {
        let n = Self::word_count(item);
        let d = item.range.duration;
        if n == 0 || d <= Time::ZERO {
            return Self::WORD_LEVEL_POINTS_PER_SECOND;
        }
        let seconds = d.value() as f64 / d.timescale() as f64;
        Self::WORD_LEVEL_POINTS_PER_SECOND.max((Self::MIN_AVERAGE_WORD_WIDTH + 2.0) * n as f64 / seconds)
    }

    /// Number of words without building them (the stored timings match the text in the common case).
    fn word_count(item: &CaptionItem) -> usize {
        if item.has_word_timings() { item.words.len() } else { item.tokens().len() }
    }

    /// The box of the word with the absolute range `range` in `row`.
    pub fn box_of(range: &TimeRange, geometry: &TimelineGeometry, row: &CaptionRow) -> Rect {
        let x0 = geometry.x(range.start);
        let x1 = geometry.x(range.end());
        Rect::new(
            x0 + Self::BOX_GAP / 2.0,
            row.y + 1.0 + Self::BOX_INSET_Y,
            (x1 - x0 - Self::BOX_GAP).max(1.0),
            row.height - 2.0 - 2.0 * Self::BOX_INSET_Y,
        )
    }

    /// Word boxes of `item` in `row`, in word order.
    pub fn boxes(item: &CaptionItem, geometry: &TimelineGeometry, row: &CaptionRow) -> Vec<Rect> {
        item.effective_words().iter().map(|w| Self::box_of(&w.range, geometry, row)).collect()
    }

    /// Row and item of a caption.
    pub fn locate<'a>(
        id: Id,
        timeline: &'a Timeline,
        geometry: &TimelineGeometry,
    ) -> Option<(CaptionRow, &'a CaptionItem)> {
        for row in geometry.caption_rows(timeline) {
            let item = timeline.caption_track(row.track).and_then(|t| t.items().iter().find(|i| i.id == id));
            if let Some(item) = item {
                return Some((row, item));
            }
        }
        None
    }

    /// The box of one word (view coordinates), `None` when the word does not exist.
    pub fn box_of_word(r: &CaptionWordRef, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<Rect> {
        let (row, item) = Self::locate(r.caption, timeline, geometry)?;
        let words = item.effective_words();
        let w = words.get(r.index)?;
        Some(Self::box_of(&w.range, geometry, &row))
    }

    /// The word of caption `id` at `p`, `None` when the caption is drawn as a block. A point in a pause between two words
    /// belongs to the nearer one (body). Word edges are grab zones only on words wide enough to keep a body.
    pub fn hit(p: Point, id: Id, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<CaptionWordHit> {
        let (_, item) = Self::locate(id, timeline, geometry)?;
        if !Self::shows_words(item, geometry) {
            return None;
        }
        let words = item.effective_words();
        let mut best: Option<(usize, f64)> = None;
        for (i, w) in words.iter().enumerate() {
            let x0 = geometry.x(w.range.start);
            let x1 = geometry.x(w.range.end());
            if p.x >= x0 && p.x < x1 {
                let mut zone = ClipZone::Body;
                if x1 - x0 >= Self::MIN_WIDTH_FOR_EDGES {
                    if p.x < x0 + Self::EDGE_GRAB {
                        zone = ClipZone::Head;
                    } else if p.x >= x1 - Self::EDGE_GRAB {
                        zone = ClipZone::Tail;
                    }
                }
                return Some(CaptionWordHit { word: CaptionWordRef::new(id, i), zone });
            }
            let d = if p.x < x0 { x0 - p.x } else { p.x - x1 };
            if best.is_none_or(|b| d < b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| CaptionWordHit { word: CaptionWordRef::new(id, b.0), zone: ClipZone::Body })
    }

    /// Index of the first item that ends after `t` (items are in time order and never overlap): where drawing starts.
    pub fn first_index(t: Time, items: &[CaptionItem]) -> usize {
        let mut lo = 0;
        let mut hi = items.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if items[mid].range.end() > t {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        lo
    }
}
