// Swift: TimelinePanel+ItemLanes.swift
//! Item lanes, translated from TimelineView+ItemLanes and +ItemLaneMove: a Graphic clip has a disclosure arrow at its
//! head (a text or shape clip too: pressing it makes the clip a Graphic through the host, then opens the lanes). Opened,
//! one lane per item appears under the clip's row (top item first); the bar in a lane is the part of the clip the item
//! shows in (`GraphicsLayer.range`), moved and trimmed inside the clip. A lane name drags its layer: within the Graphic
//! it reorders, onto another Graphic it moves there, onto a free stretch of a video track it becomes a new Graphic
//! (Option copies). Which clips are open is view state. One clip per track can be open.

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_edit::snapping::{SnapKind, SnapPoint, SnappingTimelineExt as _, snap, snap_move};
use sq_core_edit::timeline_replace::TimelineReplaceExt as _;
use sq_core_graphics::graphics_editing::GraphicsDocumentEditingExt as _;
use sq_core_graphics::graphics_make_graphic::{ClipMakeGraphicExt as _, TimelineMakeGraphicExt as _};
use sq_core_graphics::graphics_move_out::{GraphicsLayerDestination, GraphicsMoveOutExt as _};
use sq_core_model::{Clip, ClipEdge, GraphicsContent, GraphicsLayer, ShapeKind, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::{Canvas, InputModifiers};
use sq_editor_session::TimelineTool;
use sq_timeline_ui::{TimelineGeometry, TrackRow};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{metrics, radius, spacing, type_size};
use sq_uikit::sqicon::SQIcon;
use std::collections::BTreeSet;

/// Measures of the item lanes (the Mac `ItemLanes`, in points).
pub(crate) struct ItemLaneMetrics;

impl ItemLaneMetrics {
    pub(crate) const LANE_HEIGHT: f64 = metrics::TRACK_OTHER as f64;
    pub(crate) const BAR_INSET: f64 = spacing::XXS as f64;
    pub(crate) const STUB_WIDTH: f64 = 4.0;
    pub(crate) const CHEVRON_SIZE: f64 = 12.0;
    pub(crate) const DRAG_SLOP: f64 = 3.0;
    pub(crate) const OPENER_WIDTH: f64 = 34.0;

    pub(crate) fn is_available(clip: &Clip) -> bool {
        !clip.graphics().is_none_or(|g| g.layers.is_empty())
    }

    pub(crate) fn space(items: usize) -> f64 {
        items as f64 * Self::LANE_HEIGHT
    }

    /// Graphic, text and shape clips are flat (no thumbnail column), so the arrow sits right of the head trim handle.
    pub(crate) fn chevron_offset() -> f64 {
        TimelineGeometry::MAX_TRIM_HANDLE_WIDTH + 2.0
    }

    pub(crate) fn opener_width(clip_width: f64) -> f64 {
        if clip_width >= 90.0 { Self::OPENER_WIDTH } else { Self::CHEVRON_SIZE }
    }

    /// How far the clip name moves right for the arrow in front of it.
    pub(crate) fn chevron_reserve(clip_width: f64) -> f64 {
        if clip_width >= 40.0 { Self::chevron_offset() + Self::opener_width(clip_width) - 2.0 } else { 0.0 }
    }

    pub(crate) fn chevron_rect(rect: CGRect, visible: CGRect) -> Option<CGRect> {
        if rect.width < 40.0 {
            return None;
        }
        let left = rect.min_x().max(visible.min_x()) + Self::chevron_offset();
        let w = Self::opener_width(rect.width);
        let r = if w > Self::CHEVRON_SIZE {
            CGRect::new(left, rect.min_y(), w, rect.height)
        } else {
            CGRect::new(left, rect.min_y() + 4.0, w, Self::CHEVRON_SIZE)
        };
        (r.max_x() + 2.0 <= rect.max_x().min(visible.max_x()) - TimelineGeometry::MAX_TRIM_HANDLE_WIDTH).then_some(r)
    }

    pub(crate) fn lane_y(row: &TrackRow, index: usize) -> f64 {
        row.max_y() + index as f64 * Self::LANE_HEIGHT
    }

    pub(crate) fn bar_rect(x0: f64, x1: f64, lane_y: f64) -> CGRect {
        CGRect::new(
            x0,
            lane_y + Self::BAR_INSET,
            (x1 - x0).max(Self::STUB_WIDTH),
            Self::LANE_HEIGHT - 2.0 * Self::BAR_INSET - 1.0,
        )
    }
}

/// What a bar press may become.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ItemLaneBarMode {
    Move,
    Head,
    Tail,
}

/// A press on a bar that may become a move or a trim.
#[derive(Clone, Debug)]
pub(crate) struct ItemLaneBarDrag {
    pub original: Clip,
    pub item: Id,
    pub mode: ItemLaneBarMode,
    pub start_x: f64,
    /// Timeline time under the press: the drag is measured in time, so it stays right while the timeline scrolls.
    pub start_time: Time,
    pub start_range: TimeRange,
    pub last: Clip,
    pub moved: bool,
    pub points: Vec<SnapPoint>,
}

/// Where a dragged layer would land.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ItemLaneDropTarget {
    /// Inside its own Graphic: `gap` counts lanes from the top (0 = above the top lane).
    Reorder {
        gap: usize,
    },
    /// Another Graphic: `gap` as above, `None` = on top.
    Graphic(Id, Option<usize>),
    NewGraphic(Id),
}

/// A press on a lane name that may become a move.
#[derive(Clone, Debug)]
pub(crate) struct ItemLaneNameDrag {
    pub clip: Clip,
    /// Bottom first, as in the document.
    pub ids: Vec<Id>,
    pub name: String,
    pub start_y: f64,
    pub pointer: CGPoint,
    pub moved: bool,
    pub copy: bool,
    pub target: Option<ItemLaneDropTarget>,
    /// Where the target shows (an insertion line, or the dashed outline of the new Graphic).
    pub indicator: Option<CGRect>,
}

/// What lies under the pointer.
#[derive(Clone, Debug)]
pub(crate) enum ItemLaneHit {
    Chevron(Id),
    Bar {
        clip: Box<Clip>,
        item: Id,
        mode: ItemLaneBarMode,
    },
    Header {
        clip: Box<Clip>,
        item: Id,
    },
    /// Lane space with nothing to grab: the press is swallowed.
    Space,
}

/// View state of the item lanes (the Mac `ItemLaneState` without the prepared CoreText headers).
#[derive(Clone, Debug, Default)]
pub(crate) struct ItemLaneState {
    pub open: BTreeSet<Id>,
    /// Text or shape clips the host was asked to make Graphics: they open when the timeline shows them as Graphics.
    pub pending_open: BTreeSet<Id>,
    pub selected_clip: Option<Id>,
    pub selected_items: BTreeSet<Id>,
    pub drag: Option<ItemLaneBarDrag>,
    pub name_drag: Option<ItemLaneNameDrag>,
    /// The bar drag sent a change whose undo step is still open.
    pub step_open: bool,
    /// Cmd+C in a lane: the shown range of the copied item (Cmd+V gives it to the selected items).
    pub copied_range: Option<TimeRange>,
}

/// `LayerListLogic.symbol` (the list logic is not in `sq-timeline-ui` yet).
fn layer_symbol(l: &GraphicsLayer) -> SQIcon {
    match &l.content {
        GraphicsContent::Shape { kind: ShapeKind::Rectangle } => SQIcon::ShapeRectangle,
        GraphicsContent::Shape { kind: ShapeKind::Ellipse } => SQIcon::ShapeEllipse,
        GraphicsContent::Shape { kind: ShapeKind::Line } => SQIcon::ShapeLine,
        GraphicsContent::Shape { kind: ShapeKind::Arrow } => SQIcon::ArrowUpRight,
        GraphicsContent::Path { .. } => SQIcon::Draw,
        GraphicsContent::Text { .. } => SQIcon::Text,
    }
}

impl TimelinePanel {
    // MARK: State

    /// The Graphic clips whose item lanes are open.
    pub fn open_item_lanes(&self) -> &BTreeSet<Id> {
        &self.item_lanes.open
    }

    /// The arrow is offered: a Graphic, or a text or shape clip that can become one.
    pub(crate) fn item_lanes_offered(&self, c: &Clip) -> bool {
        ItemLaneMetrics::is_available(c) || (c.is_text_or_shape() && self.timeline.make_graphic_blocker(c).is_none())
    }

    /// Opens or closes the item lanes of a clip. Opening closes another open clip on the same track; a text or shape clip
    /// is first made a Graphic by the host (`MakeGraphic`) and opens once the timeline shows it as one.
    pub fn toggle_item_lanes(&mut self, id: Id) -> Vec<TimelineAction> {
        if self.item_lanes.open.contains(&id) {
            self.item_lanes.open.remove(&id);
        } else {
            let Some(track) = self.timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == id)) else {
                return Vec::new();
            };
            let Some(clip) = track.clips().iter().find(|c| c.id == id) else { return Vec::new() };
            if !ItemLaneMetrics::is_available(clip) {
                if !self.item_lanes_offered(clip) || track.is_locked {
                    return Vec::new();
                }
                self.item_lanes.pending_open.insert(id);
                return vec![TimelineAction::MakeGraphic(id)];
            }
            let others: Vec<Id> =
                track.clips().iter().filter(|c| self.item_lanes.open.contains(&c.id)).map(|c| c.id).collect();
            for c in others {
                self.item_lanes.open.remove(&c);
            }
            self.item_lanes.open.insert(id);
        }
        self.sync_item_lanes();
        self.clamp_scroll();
        Vec::new()
    }

    /// The items selected in the monitor and in Controls (the host calls this when that selection changes).
    pub fn set_item_selection(&mut self, clip: Option<Id>, items: BTreeSet<Id>) {
        self.item_lanes.selected_items = if clip.is_none() { BTreeSet::new() } else { items };
        self.item_lanes.selected_clip = clip;
    }

    /// The clip and items selected in the lanes.
    pub fn item_selection(&self) -> (Option<Id>, &BTreeSet<Id>) {
        (self.item_lanes.selected_clip, &self.item_lanes.selected_items)
    }

    pub(crate) fn open_item_lane_clip<'a>(&self, track: &'a Track) -> Option<&'a Clip> {
        if self.item_lanes.open.is_empty() {
            return None;
        }
        track.clips().iter().find(|c| self.item_lanes.open.contains(&c.id))
    }

    /// After a timeline change: converted clips open, clips that are gone or have no lanes close, the lane space follows.
    pub(crate) fn sync_item_lanes(&mut self) {
        if !self.item_lanes.pending_open.is_empty() {
            let pending = std::mem::take(&mut self.item_lanes.pending_open);
            let mut opened: Vec<(Vec<Id>, Id)> = Vec::new();
            for t in &self.timeline.tracks {
                let Some(c) = t.clips().iter().find(|c| pending.contains(&c.id) && ItemLaneMetrics::is_available(c))
                else {
                    continue;
                };
                let open: Vec<Id> =
                    t.clips().iter().filter(|o| self.item_lanes.open.contains(&o.id)).map(|o| o.id).collect();
                opened.push((open, c.id));
            }
            for (close, id) in opened {
                for o in close {
                    self.item_lanes.open.remove(&o);
                }
                self.item_lanes.open.insert(id);
            }
        }
        let mut kept = BTreeSet::new();
        let mut space = std::collections::BTreeMap::new();
        if !self.item_lanes.open.is_empty() {
            for t in &self.timeline.tracks {
                let Some(c) =
                    t.clips().iter().find(|c| self.item_lanes.open.contains(&c.id) && ItemLaneMetrics::is_available(c))
                else {
                    continue;
                };
                kept.insert(c.id);
                space.insert(t.id, ItemLaneMetrics::space(c.graphics().map_or(0, |g| g.layers.len())));
            }
        }
        self.item_lanes.open = kept;
        if self.geometry.lane_space != space {
            self.geometry.lane_space = space;
        }
        self.interaction.geometry = self.geometry.clone();
    }

    // MARK: Layout

    pub(crate) fn item_lane_content(&self) -> CGRect {
        CGRect::new(
            TimelineGeometry::CONTENT_ORIGIN_X,
            0.0,
            (self.size.width - TimelineGeometry::CONTENT_ORIGIN_X).max(0.0),
            self.size.height,
        )
    }

    fn item_lane_chevron_rect(&self, c: &Clip, y: f64, height: f64) -> Option<CGRect> {
        let (x0, x1) = (self.geometry.x(c.timeline().start), self.geometry.x(c.timeline().end()));
        ItemLaneMetrics::chevron_rect(CGRect::new(x0, y, x1 - x0, height), self.item_lane_content())
    }

    pub(crate) fn item_lane_hit(&self, p: CGPoint) -> Option<ItemLaneHit> {
        if !(p.y >= TimelineGeometry::RULER_HEIGHT && p.x >= TimelineGeometry::TOOL_COLUMN_WIDTH) {
            return None;
        }
        for row in self.rows() {
            if !(p.y >= row.y && p.y < row.bottom()) {
                continue;
            }
            let track = self.timeline.track(row.track)?;
            if p.y < row.max_y() {
                if p.x < TimelineGeometry::CONTENT_ORIGIN_X {
                    return None;
                }
                let c = track.clips().iter().find(|c| {
                    self.geometry.x(c.timeline().start) <= p.x && p.x < self.geometry.x(c.timeline().end())
                })?;
                if !self.item_lanes_offered(c) || self.tool_state().timeline_tool() != TimelineTool::Selection {
                    return None;
                }
                let r = self.item_lane_chevron_rect(c, row.y, row.height);
                return if r.is_some_and(|r| r.inset(-2.0, -2.0).has(p)) {
                    Some(ItemLaneHit::Chevron(c.id))
                } else {
                    None
                };
            }
            let Some(c) = self.open_item_lane_clip(track) else { return Some(ItemLaneHit::Space) };
            let Some(doc) = c.graphics().filter(|d| !d.layers.is_empty()) else { return Some(ItemLaneHit::Space) };
            let index = (((p.y - row.max_y()) / ItemLaneMetrics::LANE_HEIGHT) as usize).min(doc.layers.len() - 1);
            let layer = &doc.layers[doc.layers.len() - 1 - index];
            if p.x < TimelineGeometry::CONTENT_ORIGIN_X {
                return Some(ItemLaneHit::Header { clip: Box::new(c.clone()), item: layer.id });
            }
            let r = doc.shown_range(layer, c.timeline().duration);
            let bar = ItemLaneMetrics::bar_rect(
                self.geometry.x(c.timeline().start + r.start),
                self.geometry.x(c.timeline().start + r.end()),
                ItemLaneMetrics::lane_y(&row, index),
            );
            if !(p.x >= bar.min_x() && p.x < bar.max_x()) {
                return Some(ItemLaneHit::Space);
            }
            let handle = TimelineGeometry::trim_handle_width(bar.width);
            let mode = if p.x < bar.min_x() + handle {
                ItemLaneBarMode::Head
            } else if p.x >= bar.max_x() - handle {
                ItemLaneBarMode::Tail
            } else {
                ItemLaneBarMode::Move
            };
            return Some(ItemLaneHit::Bar { clip: Box::new(c.clone()), item: layer.id, mode });
        }
        None
    }

    // MARK: Mouse

    /// A press on a disclosure arrow, a lane name, a bar or lane space; `None` when the press is not the lanes'.
    pub(crate) fn item_lane_down(&mut self, p: CGPoint, mods: InputModifiers) -> Option<Vec<TimelineAction>> {
        let hit = self.item_lane_hit(p)?;
        self.gesture = Some(Gesture::ItemLane);
        match hit {
            ItemLaneHit::Space => Some(Vec::new()),
            ItemLaneHit::Chevron(id) => Some(self.toggle_item_lanes(id)),
            ItemLaneHit::Header { clip, item } => {
                let out = self.select_item_lane(clip.id, item, mods);
                if !mods.contains(InputModifiers::SHIFT) && !mods.contains(InputModifiers::COMMAND) {
                    self.begin_item_lane_move(&clip, item, p);
                }
                Some(out)
            }
            ItemLaneHit::Bar { clip, item, mode } => {
                let out = self.select_item_lane(clip.id, item, mods);
                // A locked item (or track) is selected only, like in the monitor.
                let unlocked_track = self
                    .timeline
                    .tracks
                    .iter()
                    .find(|t| t.clips().iter().any(|c| c.id == clip.id))
                    .is_some_and(|t| !t.is_locked);
                let Some(doc) = clip.graphics() else { return Some(out) };
                let Some(layer) = doc.layer(item) else { return Some(out) };
                if self.tool_state().timeline_tool() != TimelineTool::Selection || layer.is_locked || !unlocked_track {
                    return Some(out);
                }
                let base = clip.timeline().start;
                let mut points: Vec<SnapPoint> = self
                    .timeline
                    .snap_points(&BTreeSet::new(), Some(self.playhead), &self.interaction.markers, false)
                    .into_iter()
                    .filter(|s| s.time >= base && s.time <= clip.timeline().end())
                    .collect();
                for l in doc.layers.iter().filter(|l| l.id != item) {
                    let Some(r) = l.range else { continue };
                    points.push(SnapPoint::new(base + r.start, SnapKind::ClipEdge));
                    points.push(SnapPoint::new(base + r.end(), SnapKind::ClipEdge));
                }
                points.sort_by_key(|s| s.time);
                let start_range = doc.shown_range(layer, clip.timeline().duration);
                self.item_lanes.drag = Some(ItemLaneBarDrag {
                    original: (*clip).clone(),
                    item,
                    mode,
                    start_x: p.x,
                    start_time: self.geometry.unsnapped_time(p.x),
                    start_range,
                    last: (*clip).clone(),
                    moved: false,
                    points,
                });
                Some(out)
            }
        }
    }

    fn select_item_lane(&mut self, clip: Id, item: Id, mods: InputModifiers) -> Vec<TimelineAction> {
        let mut items: BTreeSet<Id> = BTreeSet::from([item]);
        if (mods.contains(InputModifiers::SHIFT) || mods.contains(InputModifiers::COMMAND))
            && self.item_lanes.selected_clip == Some(clip)
        {
            items = self.item_lanes.selected_items.symmetric_difference(&items).copied().collect();
        }
        self.set_item_selection(Some(clip), items.clone());
        vec![TimelineAction::SelectItems { clip, items }]
    }

    pub(crate) fn item_lane_dragged(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        if self.item_lanes.name_drag.is_some() {
            self.item_lane_move_dragged(p);
            return Vec::new();
        }
        let Some(mut d) = self.item_lanes.drag.clone() else { return Vec::new() };
        if !d.moved {
            if (p.x - d.start_x).abs() < ItemLaneMetrics::DRAG_SLOP {
                return Vec::new();
            }
            d.moved = true;
        }
        self.last_drag = Some(p);
        let Some(mut doc) = d.original.graphics().cloned() else { return Vec::new() };
        let fd = self.timeline.format.frame_duration;
        let base = d.original.timeline().start;
        let length = d.original.timeline().duration;
        let dt = self.geometry.unsnapped_time(p.x) - d.start_time;
        let points: &[SnapPoint] = if self.snapping() { &d.points } else { &[] };
        let threshold = self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS);
        let mut hit: Option<SnapPoint>;
        match d.mode {
            ItemLaneBarMode::Move => {
                let start = base + d.start_range.start + dt;
                let s = snap_move(start, d.start_range.duration, points, threshold, Some(fd));
                hit = s.1;
                doc.move_item_range(d.item, start + s.0 - base, length);
            }
            ItemLaneBarMode::Head | ItemLaneBarMode::Tail => {
                let head = d.mode == ItemLaneBarMode::Head;
                let s = snap(
                    base + if head { d.start_range.start } else { d.start_range.end() } + dt,
                    points,
                    threshold,
                    Some(fd),
                );
                hit = s.1;
                doc.trim_item_range(d.item, if head { ClipEdge::Head } else { ClipEdge::Tail }, s.0 - base, length, fd);
            }
        }
        // The line shows only where the bar really ended up (the clip's ends clamp it).
        if let (Some(h), Some(l)) = (hit, doc.layer(d.item)) {
            let r = doc.shown_range(l, length);
            if base + r.start != h.time && base + r.end() != h.time {
                hit = None;
            }
        }
        self.scrub_snap_time = hit.map(|h| h.time);
        let mut c = d.last.clone();
        c.set_graphics(Some(doc));
        self.item_lanes.drag = Some(d.clone());
        if c == d.last {
            return Vec::new();
        }
        let base = Box::new(std::mem::replace(&mut d.last, c.clone()));
        self.item_lanes.drag = Some(d);
        self.preview_item_lane_clip(&c);
        let continues = self.item_lanes.step_open;
        self.item_lanes.step_open = true;
        vec![TimelineAction::ReplaceClip { clip: Box::new(c), base, undo_name: "Item Range".to_string(), continues }]
    }

    pub(crate) fn item_lane_up(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        let out = if self.item_lanes.name_drag.is_some() {
            self.item_lane_move_up(p)
        } else if let Some(d) = self.item_lanes.drag.clone() {
            let mut out = if d.moved { self.item_lane_dragged(p) } else { Vec::new() };
            if self.item_lanes.step_open {
                out.push(TimelineAction::EndGesture);
                self.item_lanes.step_open = false;
            }
            out
        } else {
            Vec::new()
        };
        self.item_lanes.drag = None;
        self.item_lanes.name_drag = None;
        self.scrub_snap_time = None;
        out
    }

    /// Esc during a bar drag: the clip goes back to what it was before the drag (its open step closes with it).
    pub(crate) fn cancel_item_lane_drag(&mut self) -> Vec<TimelineAction> {
        let d = self.item_lanes.drag.take();
        let step_open = self.item_lanes.step_open;
        self.item_lanes.name_drag = None;
        self.item_lanes.step_open = false;
        match d {
            Some(d) if step_open => vec![
                TimelineAction::ReplaceClip {
                    clip: Box::new(d.original),
                    base: Box::new(d.last),
                    undo_name: "Item Range".to_string(),
                    continues: true,
                },
                TimelineAction::EndGesture,
            ],
            _ => Vec::new(),
        }
    }

    /// Shows the edited clip at once; the session gets the same edit through the action.
    fn preview_item_lane_clip(&mut self, c: &Clip) {
        let mut t = self.timeline.clone();
        if t.replace_clip(c.clone()).is_err() {
            return;
        }
        self.timeline = t;
    }

    // MARK: Keys (Cmd+D duplicate, Cmd+C copy range, Cmd+V paste range)

    /// The three keys for the items selected in an open lane; `None` when none applies (the shell gets the key).
    pub(crate) fn item_lane_key(&mut self, ch: char, mods: InputModifiers) -> Option<Vec<TimelineAction>> {
        if !(mods == InputModifiers::COMMAND && matches!(ch, 'd' | 'c' | 'v') && self.gesture.is_none()) {
            return None;
        }
        let id = self.item_lanes.selected_clip?;
        if self.item_lanes.selected_items.is_empty()
            || !self.item_lanes.open.contains(&id)
            || self.tool_state().timeline_tool() != TimelineTool::Selection
        {
            return None;
        }
        let track = self.timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == id))?;
        if track.is_locked {
            return None;
        }
        let clip = track.clips().iter().find(|c| c.id == id)?.clone();
        let mut doc = clip.graphics()?.clone();
        let ids = self.item_lanes.selected_items.clone();
        let order: Vec<Id> = doc.layers.iter().map(|l| l.id).filter(|i| ids.contains(i)).collect();
        if order.is_empty() {
            return None;
        }
        let mut out: Vec<TimelineAction> = Vec::new();
        match ch {
            'c' => {
                let first = doc.layer(order[0])?;
                self.item_lanes.copied_range = Some(doc.shown_range(first, clip.timeline().duration));
                return Some(Vec::new());
            }
            'v' => {
                let r = self.item_lanes.copied_range?;
                doc.set_range(Some(r), &ids, clip.timeline().duration);
            }
            _ => {
                let mut mint = self.fresh_ids();
                let copies = doc.duplicate(&order, &mut mint);
                if copies.is_empty() {
                    return None;
                }
                let set: BTreeSet<Id> = copies.iter().copied().collect();
                self.set_item_selection(Some(id), set.clone());
                out.push(TimelineAction::SelectItems { clip: id, items: set });
            }
        }
        let mut edited = clip.clone();
        edited.set_graphics(Some(doc));
        if edited == clip {
            return Some(out);
        }
        self.preview_item_lane_clip(&edited);
        let mut all = vec![
            TimelineAction::ReplaceClip {
                clip: Box::new(edited),
                base: Box::new(clip),
                undo_name: "Item Range".to_string(),
                continues: false,
            },
            TimelineAction::EndGesture,
        ];
        all.extend(out);
        Some(all)
    }

    // MARK: Lane name drag (TimelineView+ItemLaneMove)

    fn begin_item_lane_move(&mut self, clip: &Clip, item: Id, p: CGPoint) {
        let Some(doc) = clip.graphics() else { return };
        let Some(layer) = doc.layer(item) else { return };
        let unlocked_track = self
            .timeline
            .tracks
            .iter()
            .find(|t| t.clips().iter().any(|c| c.id == clip.id))
            .is_some_and(|t| !t.is_locked);
        if self.tool_state().timeline_tool() != TimelineTool::Selection || layer.is_locked || !unlocked_track {
            return;
        }
        let ids: Vec<Id> =
            if self.item_lanes.selected_clip == Some(clip.id) && self.item_lanes.selected_items.contains(&item) {
                doc.layers.iter().map(|l| l.id).filter(|i| self.item_lanes.selected_items.contains(i)).collect()
            } else {
                vec![item]
            };
        self.item_lanes.name_drag = Some(ItemLaneNameDrag {
            clip: clip.clone(),
            ids,
            name: layer.name.clone(),
            start_y: p.y,
            pointer: p,
            moved: false,
            copy: false,
            target: None,
            indicator: None,
        });
    }

    fn item_lane_move_dragged(&mut self, p: CGPoint) {
        let Some(mut m) = self.item_lanes.name_drag.clone() else { return };
        if !m.moved {
            if (p.y - m.start_y).abs() < ItemLaneMetrics::DRAG_SLOP {
                return;
            }
            m.moved = true;
        }
        m.pointer = p;
        m.copy = self.drag_modifiers().contains(InputModifiers::OPTION);
        let hit = self.item_lane_drop_target(p, &m);
        m.target = hit.map(|h| h.0);
        m.indicator = hit.map(|h| h.1);
        self.item_lanes.name_drag = Some(m);
    }

    fn item_lane_move_up(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        if self.item_lanes.name_drag.as_ref().is_none_or(|m| !m.moved) {
            return Vec::new();
        }
        self.item_lane_move_dragged(p);
        let Some(m) = self.item_lanes.name_drag.clone() else { return Vec::new() };
        let Some(target) = m.target else { return Vec::new() };
        match target {
            ItemLaneDropTarget::Reorder { gap } => {
                let Some(doc) = m.clip.graphics().filter(|_| !m.copy) else { return Vec::new() };
                let moving: BTreeSet<Id> = m.ids.iter().copied().collect();
                let above = doc.layers.iter().rev().take(gap).filter(|l| !moving.contains(&l.id)).count();
                let rest = doc.layers.len() - moving.len();
                vec![TimelineAction::ReorderItems { clip: m.clip.id, ids: m.ids, to_index: rest - above }]
            }
            ItemLaneDropTarget::Graphic(id, gap) => {
                let count = self
                    .timeline
                    .tracks
                    .iter()
                    .flat_map(|t| t.clips().iter())
                    .find(|c| c.id == id)
                    .and_then(|c| c.graphics())
                    .map_or(0, |g| g.layers.len());
                let index = gap.map(|g| i64::try_from(count.saturating_sub(g)).unwrap_or(0));
                vec![TimelineAction::MoveItemsOut {
                    clip: m.clip.id,
                    ids: m.ids,
                    to: GraphicsLayerDestination::Graphic { clip: id, index },
                    copy: m.copy,
                }]
            }
            ItemLaneDropTarget::NewGraphic(track) => vec![TimelineAction::MoveItemsOut {
                clip: m.clip.id,
                ids: m.ids,
                to: GraphicsLayerDestination::NewGraphic { track },
                copy: m.copy,
            }],
        }
    }

    /// The drop under the pointer, `None` when the layers cannot land there (nothing is highlighted then).
    pub(crate) fn item_lane_drop_target(
        &self,
        p: CGPoint,
        m: &ItemLaneNameDrag,
    ) -> Option<(ItemLaneDropTarget, CGRect)> {
        if !(p.x >= TimelineGeometry::TOOL_COLUMN_WIDTH && p.y >= TimelineGeometry::RULER_HEIGHT) {
            return None;
        }
        let doc = m.clip.graphics()?;
        let spans: Vec<TimeRange> = doc
            .extracted_copies(&m.ids, m.clip.timeline().start, m.clip.timeline().duration)
            .iter()
            .map(|e| e.span)
            .collect();
        let from = spans.iter().map(|s| s.start).min()?;
        let to = spans.iter().map(|s| s.end()).max()?;
        let union = TimeRange::from_end(from, to.max(from + self.timeline.format.frame_duration));
        for row in self.rows() {
            if !(p.y >= row.y && p.y < row.bottom()) {
                continue;
            }
            let track = self.timeline.track(row.track)?;
            if row.kind != TrackKind::Video || track.is_locked {
                return None;
            }
            if p.y >= row.max_y() {
                let c = self.open_item_lane_clip(track)?;
                let d = c.graphics()?;
                let gap = (((p.y - row.max_y()) / ItemLaneMetrics::LANE_HEIGHT).round().max(0.0) as usize)
                    .min(d.layers.len());
                let line = CGRect::new(
                    TimelineGeometry::TOOL_COLUMN_WIDTH,
                    row.max_y() + gap as f64 * ItemLaneMetrics::LANE_HEIGHT - 1.0,
                    (self.geometry.x(c.timeline().end()) - TimelineGeometry::TOOL_COLUMN_WIDTH).max(0.0),
                    2.0,
                );
                if c.id == m.clip.id {
                    return if m.copy { None } else { Some((ItemLaneDropTarget::Reorder { gap }, line)) };
                }
                if !spans.iter().all(|s| s.overlaps(&c.timeline())) {
                    return None;
                }
                return Some((ItemLaneDropTarget::Graphic(c.id, Some(gap)), line));
            }
            if let Some(c) = track
                .clips()
                .iter()
                .find(|c| self.geometry.x(c.timeline().start) <= p.x && p.x < self.geometry.x(c.timeline().end()))
            {
                if !(c.is_graphics() && c.id != m.clip.id && spans.iter().all(|s| s.overlaps(&c.timeline()))) {
                    return None;
                }
                return Some((
                    ItemLaneDropTarget::Graphic(c.id, None),
                    CGRect::new(
                        self.geometry.x(c.timeline().start),
                        row.y,
                        self.geometry.width(c.timeline().duration),
                        row.height - 1.0,
                    ),
                ));
            }
            if track.clips().iter().any(|c| c.timeline().overlaps(&union)) {
                return None;
            }
            return Some((
                ItemLaneDropTarget::NewGraphic(track.id),
                CGRect::new(
                    self.geometry.x(union.start),
                    row.y,
                    self.geometry.width(union.duration).max(2.0),
                    row.height - 1.0,
                ),
            ));
        }
        None
    }

    // MARK: Drawing

    /// The disclosure arrow (with the layer count on a wide clip) at a clip's head.
    pub(crate) fn draw_item_lane_chevron(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect) {
        if !self.item_lanes_offered(c) {
            return;
        }
        let Some(r) = ItemLaneMetrics::chevron_rect(rect, visible) else { return };
        let open = self.item_lanes.open.contains(&c.id);
        let box_ = if r.width > ItemLaneMetrics::CHEVRON_SIZE {
            CGRect::new(r.min_x(), r.min_y() + 4.0, ItemLaneMetrics::CHEVRON_SIZE, ItemLaneMetrics::CHEVRON_SIZE)
        } else {
            r
        };
        cv.draw_icon(
            if open { SQIcon::ChevronDown } else { SQIcon::ChevronRight },
            CGPoint { x: box_.mid_x() - 4.5, y: box_.mid_y() - 4.5 },
            9.0,
            self.theme.label(),
            None,
        );
        if r.width <= ItemLaneMetrics::CHEVRON_SIZE {
            return;
        }
        cv.draw_text(
            &format!("{}", c.graphics().map_or(0, |g| g.layers.len())),
            CGPoint { x: box_.max_x() + 2.0, y: box_.min_y() - 1.0 },
            f64::from(type_size::CAPTION),
            self.theme.label(),
            f64::INFINITY,
            0,
        );
    }

    /// Lanes and bars of the open clips, inside the content clip.
    pub(crate) fn draw_item_lanes(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        if self.item_lanes.open.is_empty() {
            return;
        }
        let lane_h = ItemLaneMetrics::LANE_HEIGHT;
        for row in rows.iter().filter(|r| r.lane_space > 0.0 && r.max_y() < clip.max_y() && r.bottom() > clip.min_y()) {
            let Some(track) = self.timeline.track(row.track) else { continue };
            let Some(c) = self.open_item_lane_clip(track) else { continue };
            let Some(doc) = c.graphics() else { continue };
            let start = c.timeline().start;
            let length = c.timeline().duration;
            let x0 = self.geometry.x(start).max(clip.min_x());
            let x1 = self.geometry.x(c.timeline().end()).min(clip.max_x());
            if x1 <= x0 {
                continue;
            }
            let selected_clip = self.item_lanes.selected_clip == Some(c.id);
            for (index, layer) in doc.layers.iter().rev().enumerate() {
                let y = row.max_y() + index as f64 * lane_h;
                if !(y < clip.max_y() && y + lane_h > clip.min_y()) {
                    continue;
                }
                cv.fill(CGRect::new(x0, y, x1 - x0, lane_h), self.theme.lane());
                cv.fill(CGRect::new(x0, y + lane_h - 1.0, x1 - x0, 1.0), self.theme.track_row_line());
                let r = layer.range.unwrap_or_else(|| TimeRange::new(Time::ZERO, length));
                let bar =
                    ItemLaneMetrics::bar_rect(self.geometry.x(start + r.start), self.geometry.x(start + r.end()), y);
                let shown = CGRect::new(
                    bar.min_x().max(clip.min_x() - 8.0),
                    bar.min_y(),
                    bar.max_x().min(clip.max_x() + 8.0) - bar.min_x().max(clip.min_x() - 8.0),
                    bar.height,
                );
                if shown.width <= 0.0 {
                    continue;
                }
                let selected = selected_clip && self.item_lanes.selected_items.contains(&layer.id);
                let radius = f64::from(radius::SMALL);
                cv.fill_rounded(
                    shown,
                    radius,
                    if selected { self.theme.accent() } else { self.theme.accent().with_alpha(0.45) },
                );
                if selected {
                    cv.stroke_rounded(shown.inset(0.5, 0.5), radius, 1.0, self.theme.yellow());
                }
            }
        }
    }

    /// Icon and name of every lane in the header column.
    pub(crate) fn draw_item_lane_headers(&self, cv: &mut Canvas, rows: &[TrackRow]) {
        if self.item_lanes.open.is_empty() {
            return;
        }
        let x = TimelineGeometry::TOOL_COLUMN_WIDTH;
        let w = TimelineGeometry::HEADER_WIDTH;
        let lane_h = ItemLaneMetrics::LANE_HEIGHT;
        let bottom = self.zoom_bar_rect().min_y();
        let sm = f64::from(spacing::SM);
        for row in rows.iter().filter(|r| r.lane_space > 0.0) {
            let Some(track) = self.timeline.track(row.track) else { continue };
            let Some(c) = self.open_item_lane_clip(track) else { continue };
            let Some(doc) = c.graphics() else { continue };
            for (index, l) in doc.layers.iter().rev().enumerate() {
                let r = CGRect::new(x, row.max_y() + index as f64 * lane_h, w, lane_h);
                if !(r.min_y() >= TimelineGeometry::RULER_HEIGHT && r.max_y() <= bottom) {
                    continue;
                }
                let sel = self.item_lanes.selected_clip == Some(c.id) && self.item_lanes.selected_items.contains(&l.id);
                cv.fill(r, self.theme.lane());
                if sel {
                    cv.fill(r, self.theme.selection());
                }
                cv.fill(CGRect::new(x, r.max_y() - 1.0, w, 1.0), self.theme.track_header_line());
                let color = if sel { self.theme.label() } else { self.theme.label2() };
                let icon_box = CGRect::new(x + sm, r.min_y(), ItemLaneMetrics::CHEVRON_SIZE, lane_h - 1.0);
                cv.draw_icon(
                    layer_symbol(l),
                    CGPoint { x: icon_box.mid_x() - 5.0, y: icon_box.mid_y() - 5.0 },
                    10.0,
                    color,
                    None,
                );
                let text_x = icon_box.max_x() + f64::from(spacing::XS);
                cv.draw_text_in(
                    &l.name,
                    CGRect::new(text_x, r.min_y(), (r.max_x() - sm - text_x).max(0.0), lane_h - 1.0),
                    f64::from(type_size::BODY),
                    color,
                    sq_draw::TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
    }

    /// The lane name drag's ghost: the target (insertion line or dashed clip) and the name chip under the pointer.
    pub(crate) fn draw_item_lane_move_ghost(&self, cv: &mut Canvas) {
        let Some(m) = self.item_lanes.name_drag.as_ref().filter(|m| m.moved) else { return };
        let radius = f64::from(radius::SMALL);
        let ghost_alpha = 0.55_f32; // `Theme.OnPicture.clipGhostAlpha`
        if let Some(r) = m.indicator {
            if r.height <= 2.0 {
                cv.fill(r, self.theme.accent());
            } else {
                cv.fill_rounded(
                    r,
                    radius,
                    self.theme.clip(sq_core_model::LabelColor::VIDEO_DEFAULT).with_alpha(ghost_alpha),
                );
                cv.stroke_dashed_rounded(r.inset(0.5, 0.5), radius, 1.0, 4.0, 3.0, self.theme.accent());
            }
        }
        let lane_h = ItemLaneMetrics::LANE_HEIGHT;
        let chip = CGRect::new(
            m.pointer.x - TimelineGeometry::HEADER_WIDTH / 2.0,
            m.pointer.y - lane_h / 2.0,
            TimelineGeometry::HEADER_WIDTH,
            lane_h,
        );
        cv.fill_rounded(
            chip,
            radius,
            self.theme.accent().with_alpha(if m.target.is_none() { ghost_alpha / 2.0 } else { ghost_alpha }),
        );
        let label = if m.ids.len() > 1 { format!("{} +{}", m.name, m.ids.len() - 1) } else { m.name.clone() };
        cv.draw_text_in(
            &label,
            chip,
            f64::from(type_size::BODY),
            self.theme.label(),
            sq_draw::TextAlign::Left,
            f64::from(spacing::SM),
            0,
        );
    }
}
