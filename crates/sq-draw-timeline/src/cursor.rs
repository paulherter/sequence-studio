// Swift: TimelinePanel+Cursor.swift
//! The Mac `TimelineView.resetCursorRects` and its drag-time `NSCursor.set` calls as one query: which pointer shape
//! shows at a point (tool cursors from `TimelineCursorMap`, transition edges, track resize edges), and during a gesture
//! the shape it began with. The panel puts it into `Hover` for every mouse event it handles.
//! It also offers the track header buttons' tips (the Mac `TrackHeaderView.setTooltip` names).

use crate::band_gestures::BandKind;
use crate::geom::RectExt as _;
use crate::item_lanes::{ItemLaneBarMode, ItemLaneHit};
use crate::panel::{Gesture, TimelinePanel};
use sq_core_audio::caption_handover::TimelineCaptionsExt as _;
use sq_core_effects::transition::TrackTransitions as _;
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{InputEvent, InputModifiers, UiCx};
use sq_editor_session::TimelineTool;
use sq_timeline_ui::{
    CaptionWordLayout, TimelineCursorKind, TimelineCursorMap, TimelineGeometry, TrackSizing, TransitionLayerLayout,
    TransitionLayout,
};
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl TimelinePanel {
    /// The shape at host pixels `x, y`; `None` outside the panel (the host's arrow).
    pub fn cursor_at(&self, x: f32, y: f32, modifiers: InputModifiers) -> Option<DrawCursor> {
        if let Some(g) = &self.gesture {
            return self.drag_cursor(g);
        }
        if !self.frame.contains(x, y) {
            return None;
        }
        self.cursor_at_point(self.point(x, y), modifiers)
    }

    /// The shape at a panel point while no gesture runs (the Mac cursor rects, last added wins: row edges, transitions,
    /// then the tool's regions).
    pub(crate) fn cursor_at_point(&self, p: CGPoint, mods: InputModifiers) -> Option<DrawCursor> {
        if self.interaction.is_idle() && TrackSizing::zone(p, &self.rows(), self.size.width).is_some() {
            return Some(DrawCursor::ResizeUpDown);
        }
        let tool = self.tool_state().timeline_tool();
        if tool == TimelineTool::Selection
            && let Some(ItemLaneHit::Bar { mode, .. }) = self.item_lane_hit(p)
        {
            return match mode {
                ItemLaneBarMode::Head => Some(DrawCursor::TrimIn),
                ItemLaneBarMode::Tail => Some(DrawCursor::TrimOut),
                ItemLaneBarMode::Move => None,
            };
        }
        let content = CGRect::new(
            TimelineGeometry::CONTENT_ORIGIN_X,
            TimelineGeometry::RULER_HEIGHT,
            (self.size.width - TimelineGeometry::CONTENT_ORIGIN_X).max(0.0),
            (self.track_area_height() - TimelineGeometry::RULER_HEIGHT).max(0.0),
        );
        if !content.has(p) {
            return None;
        }
        if tool == TimelineTool::Selection
            && let Some(t) = self.transition_cursor(p)
        {
            return Some(t);
        }
        if self.caption_word_edge(p) {
            return Some(DrawCursor::ResizeLeftRight);
        }
        let regions = TimelineCursorMap::regions(
            &self.timeline,
            &self.geometry,
            tool,
            &content,
            mods.contains(InputModifiers::COMMAND),
            mods.contains(InputModifiers::OPTION),
        );
        regions.iter().rev().find(|r| r.rect.has(p)).map(|r| Self::draw_cursor(r.kind))
    }

    /// The pointer is on the inner edge grab of a caption word (the Mac `addCaptionWordCursorRects`; Selection tool,
    /// word level).
    fn caption_word_edge(&self, p: CGPoint) -> bool {
        if self.tool_state().timeline_tool() != TimelineTool::Selection
            || self.geometry.points_per_second < CaptionWordLayout::WORD_LEVEL_POINTS_PER_SECOND
        {
            return false;
        }
        let Some(row) = self.geometry.caption_rows(&self.timeline).into_iter().find(|r| p.y >= r.y && p.y < r.max_y())
        else {
            return false;
        };
        let Some(track) = self.timeline.caption_track(row.track).filter(|t| !t.is_locked) else { return false };
        let grab = CaptionWordLayout::EDGE_GRAB;
        for item in track.items().iter().filter(|i| CaptionWordLayout::shows_words(i, &self.geometry)) {
            let (x0, x1) = (self.geometry.x(item.range.start), self.geometry.x(item.range.end()));
            if !(p.x >= x0 && p.x < x1) {
                continue;
            }
            let handle = TimelineGeometry::trim_handle_width(x1 - x0);
            for w in item.effective_words() {
                let (a, b) = (self.geometry.x(w.range.start), self.geometry.x(w.range.end()));
                if b - a < CaptionWordLayout::MIN_WIDTH_FOR_EDGES {
                    continue;
                }
                for x in [a, b - grab] {
                    if x >= x0 + handle && x + grab <= x1 - handle && p.x >= x && p.x < x + grab {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// Transition boxes: resize on the ends, a hand over the body; transition layers: resize on the ends and the cut.
    fn transition_cursor(&self, p: CGPoint) -> Option<DrawCursor> {
        let fd = self.timeline.format.frame_duration;
        for row in self.rows() {
            if !(p.y >= row.y && p.y < row.max_y()) {
                continue;
            }
            let Some(track) = self.timeline.tracks.iter().find(|t| t.id == row.track) else { continue };
            for r in track.resolved_transitions(fd) {
                let b = TransitionLayout::rect(&r, &row, &self.geometry);
                if !b.has(p) {
                    continue;
                }
                let e = TransitionLayout::edge_width(b.width);
                return Some(if p.x < b.min_x() + e || p.x >= b.max_x() - e {
                    DrawCursor::ResizeLeftRight
                } else {
                    DrawCursor::OpenHand
                });
            }
        }
        TransitionLayerLayout::hit_test(p, &self.timeline, &self.geometry).map(|_| DrawCursor::ResizeLeftRight)
    }

    /// The shape a running gesture keeps (the Mac drags set theirs at the press and leave it until the release).
    pub(crate) fn drag_cursor(&self, g: &Gesture) -> Option<DrawCursor> {
        match g {
            Gesture::Resize { .. } => Some(DrawCursor::ResizeUpDown),
            Gesture::Keystone(_) | Gesture::Attach { .. } | Gesture::TransitionLayer(_) | Gesture::Speed(_) => {
                Some(DrawCursor::ResizeLeftRight)
            }
            // a fade handle drag sets the left-right shape (beginFadeDrag), the lines up-down
            Gesture::Band(d) => Some(if matches!(d.kind, BandKind::Fade { .. }) {
                DrawCursor::ResizeLeftRight
            } else {
                DrawCursor::ResizeUpDown
            }),
            Gesture::Patch { dragging, .. } => dragging.then_some(DrawCursor::ClosedHand),
            Gesture::Transition { .. } => Some(if self.press_cursor == Some(DrawCursor::OpenHand) {
                DrawCursor::ClosedHand
            } else {
                DrawCursor::ResizeLeftRight
            }),
            Gesture::Clips => {
                if self.interaction.move_hint().is_some_and(|h| h.contains("opy")) {
                    return Some(DrawCursor::DragCopy);
                }
                if self.tool_state().timeline_tool() == TimelineTool::Hand {
                    return Some(DrawCursor::ClosedHand);
                }
                self.press_cursor
            }
            _ => self.press_cursor,
        }
    }

    pub(crate) fn draw_cursor(k: TimelineCursorKind) -> DrawCursor {
        match k {
            TimelineCursorKind::TrimIn => DrawCursor::TrimIn,
            TimelineCursorKind::TrimOut => DrawCursor::TrimOut,
            TimelineCursorKind::RippleIn => DrawCursor::RippleIn,
            TimelineCursorKind::RippleOut => DrawCursor::RippleOut,
            TimelineCursorKind::RateIn => DrawCursor::RateIn,
            TimelineCursorKind::RateOut => DrawCursor::RateOut,
            TimelineCursorKind::Roll => DrawCursor::Roll,
            TimelineCursorKind::Slip => DrawCursor::Slip,
            TimelineCursorKind::Slide => DrawCursor::Slide,
            TimelineCursorKind::Razor => DrawCursor::Razor,
            TimelineCursorKind::Hand => DrawCursor::OpenHand,
            TimelineCursorKind::Zoom => DrawCursor::ZoomIn,
            TimelineCursorKind::TrackSelect => DrawCursor::TrackSelect,
            TimelineCursorKind::Copy => DrawCursor::DragCopy,
        }
    }

    /// After a mouse event: the shape into the hover state (inside the panel or while its gesture runs), and on a move
    /// the tip of the header button under the pointer (offered by the header owner).
    pub(crate) fn publish_hover(&self, e: &InputEvent, ui: &mut UiCx) {
        let live = self.live_mods();
        match *e {
            InputEvent::MouseMoved { x, y } => {
                ui.hover.request(self.cursor_at(x, y, live));
                if self.frame.contains(x, y) {
                    ui.hover.offer_tip(self.header_tip_at(self.point(x, y)));
                }
            }
            InputEvent::MouseDown { x, y, .. }
            | InputEvent::MouseDragged { x, y, .. }
            | InputEvent::MouseUp { x, y } => {
                ui.hover.request(self.cursor_at(x, y, live));
            }
            InputEvent::KeyDown { .. } | InputEvent::Scroll { .. } => {} // keys: `key` publishes
        }
    }

    /// After a key: a tool key or a held modifier changes the shape under a resting pointer.
    pub(crate) fn publish_key_hover(&self, ui: &mut UiCx) {
        let Some(p) = self.hover_point else { return };
        if self.gesture.is_some() {
            return;
        }
        ui.hover.replace(self.cursor_at_point(p, self.live_mods()));
    }

    /// The modifiers held right now, or none when the host reports none.
    pub(crate) fn live_mods(&self) -> InputModifiers {
        self.live_modifiers.as_ref().map_or(InputModifiers::NONE, |f| f())
    }
}
