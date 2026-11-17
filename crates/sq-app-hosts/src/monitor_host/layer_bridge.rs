// Swift: SQAppShell/Monitors/GraphicsLayerAdapter.swift and MonitorHost.syncGraphicLayers
//! The Graphics editor as the Program monitor's layer overlay sees it, so a click on a text or shape inside the selected
//! Graphic picks that item (box, handles, move) instead of the whole clip, and a click on empty canvas is the clip's.
//!
//! The overlay lives in the card and only gets the session, but the editor is owned by the Graphics host. So the host
//! refreshes this bridge every frame (what the overlay reads: outlines, selection, a copy of the shown document for hit
//! tests) and the overlay's edits wait in a queue that the root applies with the editor right after the input event.

use super::MonitorHost;
use super::create_tool::STROKE_WIDTH;
use sq_core_graphics::graphics_editing::{
    GraphicsDocumentEditingExt, GraphicsLayerGeometryExt, GraphicsRect, GraphicsTextMeasure,
};
use sq_core_model::{Clip, EffectColor, GraphicsDocument, GraphicsLayer, SequenceFormat};
use sq_core_time::{Id, Time, Vec2};
use sq_draw_monitor::graphics_layer_overlay::{
    GraphicsLayerGuides, GraphicsLayerOutline, GraphicsLayerSnapshot, GraphicsLayerSource, ResizeRequest,
};
use sq_draw_monitor::transform_overlay::TransformOverlay;
use sq_editor_session::{EditorSession, SnapResult};
use sq_inspector_ui::graphics::canvas_mapping::GraphicsCanvasMapping;
use sq_inspector_ui::graphics::editor::GraphicsEditor;
use sq_inspector_ui::graphics::monitor_logic::{GraphicsMoveSnapper, GraphicsSnap};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

/// Smoothing tolerance of a stroke drawn on the monitor (canvas px; Swift `GraphicsEditor.strokeTolerance`).
const STROKE_TOLERANCE: f64 = 2.0;

/// One edit the overlay asked for, in the order it asked.
enum Edit {
    Select(BTreeSet<Id>),
    BeginGesture,
    BeginMove(Vec2, f64),
    MoveTo(Vec2, bool),
    Resize(ResizeRequest),
    AddPath(Vec<Vec2>),
}

/// The Graphic as drawn at the playhead, kept for the hit tests between two frames.
struct Shown {
    doc: GraphicsDocument,
    map: GraphicsCanvasMapping,
    local: Time,
    duration: Time,
    format: Option<SequenceFormat>,
}

impl Shown {
    /// Runs `f` with the document, the clip-local time and the text measure the render and the hit test share.
    fn at<R>(&self, f: impl FnOnce(&GraphicsDocument, Time, Option<GraphicsTextMeasure>) -> R) -> R {
        let measure = GraphicsEditor::text_measure_for(self.duration, self.format.clone());
        f(&self.doc, self.local, Some(&measure))
    }

    fn outline(&self, l: &GraphicsLayer, selection: &BTreeSet<Id>) -> Option<GraphicsLayerOutline> {
        let corners = self.at(|_, t, m| l.corners(t, m))?;
        (corners.len() == 4).then(|| GraphicsLayerOutline {
            id: l.id,
            corners: corners.into_iter().map(|c| self.map.sequence_offset_from_canvas(c)).collect(),
            is_selected: selection.contains(&l.id),
        })
    }
}

/// What the overlay reads and the edits it queued; shared by the host and the overlay's [`LayerAdapter`].
#[derive(Default)]
pub(super) struct LayerBridge {
    snapshot: GraphicsLayerSnapshot,
    shown: Option<Shown>,
    queue: Vec<Edit>,
    snapper: Option<GraphicsMoveSnapper>,
    /// The snap lines of the last applied drag step (the overlay draws them one step late).
    guides: GraphicsLayerGuides,
}

impl LayerBridge {
    /// Reads the editor again: outlines of the layers drawn at the playhead, the handled layer and the selection.
    fn refresh(&mut self, session: &EditorSession, g: &GraphicsEditor) {
        self.shown = None;
        self.snapshot = GraphicsLayerSnapshot { is_drawing: g.is_drawing(), ..GraphicsLayerSnapshot::default() };
        let (Some(doc), Some(map)) = (g.shown_document(session), g.mapping(session)) else { return };
        let shown = Shown {
            doc,
            map,
            local: g.local_time(session),
            duration: g.clip(session).map_or(Time::new(5, 1), Clip::duration),
            format: session.active_timeline().map(|t| t.format.clone()),
        };
        let selection = g.selected_layers(session).clone();
        let t = shown.local;
        let outlines = shown
            .doc
            .layers
            .iter()
            .filter(|l| l.is_visible && l.is_shown(t))
            .filter_map(|l| shown.outline(l, &selection))
            .collect();
        // The single selected unlocked layer drawn at the playhead gets the handles.
        let handled = selection
            .iter()
            .next()
            .filter(|_| selection.len() == 1)
            .and_then(|id| shown.doc.layer(*id))
            .filter(|l| !l.is_locked && l.is_shown(t))
            .and_then(|l| shown.outline(l, &selection));
        self.snapshot = GraphicsLayerSnapshot { outlines, handled, selection, is_drawing: g.is_drawing() };
        self.shown = Some(shown);
    }

    fn clear(&mut self) {
        self.shown = None;
        self.snapshot = GraphicsLayerSnapshot::default();
    }

    /// Runs the queued edits on the editor, then reads it again.
    fn apply(&mut self, session: &mut EditorSession, g: &mut GraphicsEditor) {
        let edits = std::mem::take(&mut self.queue);
        if edits.is_empty() {
            return;
        }
        for edit in edits {
            let Some(map) = g.mapping(session) else { continue };
            match edit {
                Edit::Select(ids) => g.select(session, ids),
                Edit::BeginGesture => g.begin_gesture(session),
                Edit::BeginMove(p, view_scale) => self.snapper = Self::snapper(session, g, &map, p, view_scale),
                Edit::MoveTo(p, snapping) => {
                    let Some(snapper) = self.snapper.as_mut() else { continue };
                    let (delta, snap) = snapper.step(map.canvas_point_from_sequence(p), snapping);
                    g.translate_selected(session, delta);
                    self.guides = Self::guides(&snap, &map);
                }
                Edit::Resize(req) => self.guides = Self::resize(session, g, &map, &req),
                Edit::AddPath(points) => {
                    let canvas: Vec<Vec2> = points.iter().map(|p| map.canvas_point_from_sequence(*p)).collect();
                    g.add_path(session, &canvas, false, EffectColor::WHITE, STROKE_WIDTH, STROKE_TOLERANCE);
                }
            }
        }
        self.refresh(session, g);
    }

    /// A move drag starts: the selection's box and the snap lines of the canvas (Swift `beginMove`).
    fn snapper(
        session: &EditorSession,
        g: &GraphicsEditor,
        map: &GraphicsCanvasMapping,
        p: Vec2,
        view_scale: f64,
    ) -> Option<GraphicsMoveSnapper> {
        let q = map.canvas_point_from_sequence(p);
        let shown = g.shown_document(session)?;
        let (t, measure) = (g.local_time(session), g.text_measure(session));
        let boxed = g
            .selected_layers(session)
            .iter()
            .filter_map(|id| shown.bounds_of(*id, t, Some(&measure)))
            .reduce(|a, b| a.union(&b))
            .unwrap_or(GraphicsRect { min_x: q.x, min_y: q.y, max_x: q.x, max_y: q.y });
        let threshold = GraphicsSnap::threshold(TransformOverlay::SNAP_DISTANCE, view_scale, map);
        Some(GraphicsMoveSnapper::new(boxed, q, GraphicsSnap::targets(g.canvas(session), map, &[]), threshold))
    }

    /// A corner drag step: Shift keeps the aspect, which moves the edge away from the snapped point, so no snapping then.
    fn resize(
        session: &mut EditorSession,
        g: &mut GraphicsEditor,
        map: &GraphicsCanvasMapping,
        req: &ResizeRequest,
    ) -> GraphicsLayerGuides {
        let mut target = map.canvas_point_from_sequence(req.to);
        let mut snap = SnapResult::none();
        if req.snapping
            && !req.keep_aspect
            && let Some(targets) = GraphicsSnap::targets(g.canvas(session), map, &[])
        {
            let threshold = GraphicsSnap::threshold(TransformOverlay::SNAP_DISTANCE, req.view_scale, map);
            (target, snap) = GraphicsSnap::snap_point(target, &targets, threshold);
        }
        g.resize(session, req.id, req.corner, target, req.keep_aspect);
        Self::guides(&snap, map)
    }

    /// Snap lines in the graphic's canvas, back in sequence px.
    fn guides(snap: &SnapResult, map: &GraphicsCanvasMapping) -> GraphicsLayerGuides {
        GraphicsLayerGuides {
            vertical: snap
                .vertical_lines
                .iter()
                .map(|x| map.sequence_offset_from_canvas(Vec2::new(*x, 0.0)).x)
                .collect(),
            horizontal: snap
                .horizontal_lines
                .iter()
                .map(|y| map.sequence_offset_from_canvas(Vec2::new(0.0, *y)).y)
                .collect(),
        }
    }
}

/// The overlay's side of the bridge: reads answer from the last refresh, edits queue up.
pub(super) struct LayerAdapter(pub(super) Rc<RefCell<LayerBridge>>);

impl GraphicsLayerSource for LayerAdapter {
    fn snapshot(&self, _s: &EditorSession) -> GraphicsLayerSnapshot {
        self.0.borrow().snapshot.clone()
    }

    fn layer_at(&self, _s: &EditorSession, p: Vec2) -> Option<Id> {
        let bridge = self.0.borrow();
        let shown = bridge.shown.as_ref()?;
        let q = shown.map.canvas_point_from_sequence(p);
        shown.at(|d, t, m| d.hit_test(q, t, m))
    }

    fn layer_below(&self, _s: &EditorSession, current: Option<Id>, p: Vec2) -> Option<Id> {
        let bridge = self.0.borrow();
        let shown = bridge.shown.as_ref()?;
        let q = shown.map.canvas_point_from_sequence(p);
        shown.at(|d, t, m| d.hit_below(current, q, t, m))
    }

    fn layers_in_rect(&self, _s: &EditorSession, a: Vec2, b: Vec2) -> BTreeSet<Id> {
        let bridge = self.0.borrow();
        let Some(shown) = bridge.shown.as_ref() else { return BTreeSet::new() };
        let (ca, cb) = (shown.map.canvas_point_from_sequence(a), shown.map.canvas_point_from_sequence(b));
        let rect =
            GraphicsRect { min_x: ca.x.min(cb.x), min_y: ca.y.min(cb.y), max_x: ca.x.max(cb.x), max_y: ca.y.max(cb.y) };
        shown.at(|d, t, m| d.layers_touching(&rect, t, m))
    }

    fn select(&mut self, _s: &mut EditorSession, ids: BTreeSet<Id>) {
        let mut bridge = self.0.borrow_mut();
        // The next press in the same frame already sees the new selection (Shift toggles against it).
        bridge.snapshot.selection.clone_from(&ids);
        bridge.queue.push(Edit::Select(ids));
    }

    fn begin_gesture(&mut self, _s: &mut EditorSession) {
        self.0.borrow_mut().queue.push(Edit::BeginGesture);
    }

    fn begin_move(&mut self, _s: &mut EditorSession, p: Vec2, view_scale: f64) {
        self.0.borrow_mut().queue.push(Edit::BeginMove(p, view_scale));
    }

    fn move_to(&mut self, _s: &mut EditorSession, p: Vec2, snapping: bool) -> GraphicsLayerGuides {
        let mut bridge = self.0.borrow_mut();
        bridge.queue.push(Edit::MoveTo(p, snapping));
        bridge.guides.clone()
    }

    fn resize(&mut self, _s: &mut EditorSession, req: &ResizeRequest) -> GraphicsLayerGuides {
        let mut bridge = self.0.borrow_mut();
        bridge.queue.push(Edit::Resize(*req));
        bridge.guides.clone()
    }

    fn add_path(&mut self, _s: &mut EditorSession, points: &[Vec2]) {
        self.0.borrow_mut().queue.push(Edit::AddPath(points.to_vec()));
    }
}

impl MonitorHost {
    /// Hands the card's layer overlay its source; called once when the host is made.
    pub(super) fn wire_layer_overlay(
        panel: &mut sq_draw_monitor::monitor_panel::MonitorPanel,
    ) -> Rc<RefCell<LayerBridge>> {
        let bridge = Rc::new(RefCell::new(LayerBridge::default()));
        panel.layer_overlay.source = Some(Box::new(LayerAdapter(Rc::clone(&bridge))));
        bridge
    }

    /// Per frame, before the card syncs: the layer boxes show while a Graphic under the playhead is selected and nothing
    /// plays; a drag in progress keeps them (Swift `syncGraphicLayers`).
    pub fn sync_layers(&mut self, session: &EditorSession, editor: Option<&GraphicsEditor>) {
        match editor {
            Some(g) => self.layers.borrow_mut().refresh(session, g),
            None => self.layers.borrow_mut().clear(),
        }
        let overlay = &mut self.panel.layer_overlay;
        if overlay.is_dragging() {
            return;
        }
        let active = editor.is_some_and(|g| g.clip(session).is_some_and(|c| c.timeline().contains(session.playhead())));
        overlay.is_shown = !session.is_playing() && active && session.color_solo_clip().is_none();
    }

    /// Runs the layer edits the card queued during the last input event (the root calls it after every event).
    pub fn apply_layer_edits(&mut self, session: &mut EditorSession, editor: Option<&mut GraphicsEditor>) {
        if let Some(g) = editor {
            self.layers.borrow_mut().apply(session, g);
        }
    }
}
