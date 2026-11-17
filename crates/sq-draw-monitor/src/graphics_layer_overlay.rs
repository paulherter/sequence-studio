// Swift: GraphicsLayerOverlay.swift
//! The layers of the selected graphics clip on the Program monitor (the Mac `GraphicsOverlayView` translated): every
//! layer's outline, the selected layers' boxes, corner handles on the single selected one. A click picks the single
//! layer (Shift toggles, Command goes through to the one below), a drag moves the selection, a corner handle resizes
//! (Shift keeps the aspect), the Draw tool records a stroke. A text in a graphic is thus picked, boxed and moved alone,
//! never as the whole clip. Clicks beside the layers fall through to the clip's own transform overlay.
//!
//! The Swift `weak var source` is [`GraphicsLayerSource`], owned by the overlay; since no object stores the session,
//! every source method receives it. Drawing reads the [`GraphicsLayerSnapshot`] the panel refreshes in `sync` and after
//! each input call.

use crate::cg::RectExt;
use sq_core_graphics::graphics_editing::GraphicsCorner;
use sq_core_time::{Id, Vec2};
use sq_draw::canvas::Canvas;
use sq_draw::theme::DrawTheme;
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Color, InputModifiers};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::collections::BTreeSet;

/// One layer of the selected graphic as the monitor draws it: its four corners in sequence px from the canvas center
/// (order of `GraphicsCorner`), already through the layer's Motion and the graphic's own.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphicsLayerOutline {
    /// The layer.
    pub id: Id,
    /// The four corners.
    pub corners: Vec<Vec2>,
    /// The layer is selected.
    pub is_selected: bool,
}

/// Snap lines of a running layer drag, in sequence px from the canvas center.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GraphicsLayerGuides {
    /// x of the vertical lines.
    pub vertical: Vec<f64>,
    /// y of the horizontal lines.
    pub horizontal: Vec<f64>,
}

/// What the overlay reads of the Graphics editor between two input calls.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GraphicsLayerSnapshot {
    /// Layers drawn at the playhead (visible, inside their range), bottom first.
    pub outlines: Vec<GraphicsLayerOutline>,
    /// The single selected unlocked layer that has corner handles; `None`: no handles.
    pub handled: Option<GraphicsLayerOutline>,
    /// The selected layers.
    pub selection: BTreeSet<Id>,
    /// The Draw tool is armed: a drag records a freeform stroke.
    pub is_drawing: bool,
}

/// One step of a corner drag.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResizeRequest {
    /// The layer.
    pub id: Id,
    /// The corner held.
    pub corner: GraphicsCorner,
    /// Where the pointer is (sequence px).
    pub to: Vec2,
    /// Snap to the guides (Shift and Option switch it off).
    pub snapping: bool,
    /// Shift: keep the aspect.
    pub keep_aspect: bool,
    /// View points per sequence px.
    pub view_scale: f64,
}

/// What the Program monitor's layer overlay needs from the Graphics editor (the shell adapts `GraphicsEditor`; the
/// overlay itself knows only sequence px). Every point is sequence px from the canvas center, y down.
pub trait GraphicsLayerSource {
    /// The state the overlay draws and hit-tests with.
    fn snapshot(&self, s: &EditorSession) -> GraphicsLayerSnapshot;
    /// The layer under `p`.
    fn layer_at(&self, s: &EditorSession, p: Vec2) -> Option<Id>;
    /// Command-click: the layer under `p` below `current` (deep select).
    fn layer_below(&self, s: &EditorSession, current: Option<Id>, p: Vec2) -> Option<Id>;
    /// Layers touched by the marquee spanned by two sequence points.
    fn layers_in_rect(&self, s: &EditorSession, a: Vec2, b: Vec2) -> BTreeSet<Id>;
    /// Selects `ids`.
    fn select(&mut self, s: &mut EditorSession, ids: BTreeSet<Id>);
    /// Opens one undo gesture.
    fn begin_gesture(&mut self, s: &mut EditorSession);
    /// A move drag starts at `p`; `view_scale` is view points per sequence px (the snap distance in view points).
    fn begin_move(&mut self, s: &mut EditorSession, p: Vec2, view_scale: f64);
    /// The move drag reached `p`.
    fn move_to(&mut self, s: &mut EditorSession, p: Vec2, snapping: bool) -> GraphicsLayerGuides;
    /// A corner drag reached `req.to`.
    fn resize(&mut self, s: &mut EditorSession, req: &ResizeRequest) -> GraphicsLayerGuides;
    /// The Draw tool recorded a stroke.
    fn add_path(&mut self, s: &mut EditorSession, points: &[Vec2]);
}

#[derive(Clone, Debug)]
enum Drag {
    Move,
    Resize(Id, GraphicsCorner),
    Draw(Vec<Vec2>),
    /// Empty canvas: a click clears the layers, a drag draws a marquee (start and current point).
    Marquee(Vec2, Vec2, BTreeSet<Id>),
}

/// The layer overlay of the Program monitor.
#[derive(Default)]
pub struct GraphicsLayerOverlay {
    /// The Graphics editor's adapter; `None` hides the overlay's content.
    pub source: Option<Box<dyn GraphicsLayerSource>>,
    /// What the source showed at the last refresh.
    pub snapshot: GraphicsLayerSnapshot,
    /// A graphic is selected under the playhead and the monitor is not playing.
    pub is_shown: bool,
    sequence_size: Option<CGSize>,
    drag: Option<Drag>,
    guides: GraphicsLayerGuides,
    canvas_rect: CGRect,
    press_modifiers: InputModifiers,
}

impl GraphicsLayerOverlay {
    const HANDLE_SIZE: f64 = 8.0;

    /// A hidden overlay.
    pub fn new() -> GraphicsLayerOverlay {
        GraphicsLayerOverlay::default()
    }

    /// The sequence size in px.
    pub fn sequence_size(&self) -> CGSize {
        self.sequence_size.unwrap_or(CGSize::new(1920.0, 1080.0))
    }

    /// Sets the sequence size in px.
    pub fn set_sequence_size(&mut self, s: CGSize) {
        self.sequence_size = Some(s);
    }

    /// Reads the source again (after the session changed or an input call edited it).
    pub fn refresh(&mut self, s: &EditorSession) {
        if let Some(src) = &self.source {
            self.snapshot = src.snapshot(s);
        }
    }

    /// A gesture runs.
    pub fn is_dragging(&self) -> bool {
        self.drag.is_some()
    }

    // MARK: Mapping

    fn k(&self, r: CGRect) -> f64 {
        let w = self.sequence_size().width;
        if w > 0.0 { r.width / w } else { 1.0 }
    }

    pub(crate) fn sequence(&self, p: CGPoint, r: CGRect) -> Vec2 {
        let s = self.k(r).max(1e-9);
        Vec2::new((p.x - r.mid_x()) / s, (p.y - r.mid_y()) / s)
    }

    pub(crate) fn view(&self, q: Vec2, r: CGRect) -> CGPoint {
        let s = self.k(r);
        CGPoint::new(r.mid_x() + q.x * s, r.mid_y() + q.y * s)
    }

    fn handle_at(&self, p: CGPoint, r: CGRect) -> Option<(Id, GraphicsCorner)> {
        let h = self.snapshot.handled.as_ref().filter(|h| h.corners.len() == 4)?;
        for (i, c) in GraphicsCorner::ALL.into_iter().enumerate() {
            let v = self.view(h.corners[i], r);
            if (v.x - p.x).hypot(v.y - p.y) <= Self::HANDLE_SIZE {
                return Some((h.id, c));
            }
        }
        None
    }

    fn layer_at(&self, s: &EditorSession, p: CGPoint, r: CGRect) -> Option<Id> {
        self.source.as_ref().and_then(|src| src.layer_at(s, self.sequence(p, r)))
    }

    // MARK: Hit test

    /// True when a press at `p` is the layers' (else it falls through to the clip's transform box).
    pub fn hits(&self, s: &EditorSession, p: CGPoint, r: CGRect, modifiers: InputModifiers) -> bool {
        if !self.is_shown || r.is_empty_rect() || self.source.is_none() {
            return false;
        }
        if self.snapshot.is_drawing {
            return r.contains(p);
        }
        if self.handle_at(p, r).is_some() || self.layer_at(s, p, r).is_some() {
            return true;
        }
        // Empty canvas belongs to the layers while some are selected (click clears, drag is a marquee), or with Option.
        (!self.snapshot.selection.is_empty() || modifiers.contains(InputModifiers::OPTION)) && r.contains(p)
    }

    /// The pointer over the selected layer: the move cursor (nothing elsewhere; the monitor's own stays).
    pub fn hover_cursor(&self, p: CGPoint, r: CGRect) -> Option<DrawCursor> {
        if !self.is_shown || r.is_empty_rect() || self.source.is_none() {
            return None;
        }
        if self.snapshot.is_drawing {
            return if r.contains(p) { Some(DrawCursor::Crosshair) } else { None };
        }
        let h = self.snapshot.handled.as_ref().filter(|h| h.corners.len() == 4)?;
        let v: Vec<CGPoint> = h.corners.iter().map(|c| self.view(*c, r)).collect();
        let x0 = v.iter().map(|p| p.x).fold(f64::INFINITY, f64::min);
        let x1 = v.iter().map(|p| p.x).fold(f64::NEG_INFINITY, f64::max);
        let y0 = v.iter().map(|p| p.y).fold(f64::INFINITY, f64::min);
        let y1 = v.iter().map(|p| p.y).fold(f64::NEG_INFINITY, f64::max);
        CGRect::new(x0, y0, x1 - x0, y1 - y0).contains(p).then_some(DrawCursor::Move)
    }

    // MARK: Input

    /// A left press; true when the overlay took it.
    pub fn mouse_down(&mut self, s: &mut EditorSession, p: CGPoint, modifiers: InputModifiers, r: CGRect) -> bool {
        if !self.hits(s, p, r, modifiers) {
            return false;
        }
        self.canvas_rect = r;
        self.press_modifiers = modifiers;
        let q = self.sequence(p, r);
        let took = self.press(s, p, q, modifiers, r);
        self.refresh(s);
        took
    }

    fn press(&mut self, s: &mut EditorSession, p: CGPoint, q: Vec2, modifiers: InputModifiers, r: CGRect) -> bool {
        if self.snapshot.is_drawing {
            self.drag = Some(Drag::Draw(vec![q]));
            return true;
        }
        let k = self.k(r);
        if let Some((id, corner)) = self.handle_at(p, r) {
            if let Some(src) = self.source.as_mut() {
                src.begin_gesture(s);
            }
            self.drag = Some(Drag::Resize(id, corner));
            return true;
        }
        let Some(id) = self.layer_at(s, p, r) else {
            let keep = if modifiers.contains(InputModifiers::SHIFT) {
                self.snapshot.selection.clone()
            } else {
                BTreeSet::new()
            };
            self.drag = Some(Drag::Marquee(q, q, keep));
            return true;
        };
        let Some(src) = self.source.as_mut() else { return false };
        // Command-click selects through to the layer underneath (deep select); Shift toggles.
        if modifiers.contains(InputModifiers::COMMAND) && !modifiers.contains(InputModifiers::SHIFT) {
            let current =
                if self.snapshot.selection.len() == 1 { self.snapshot.selection.iter().next().copied() } else { None };
            if let Some(deeper) = src.layer_below(s, current, q) {
                src.select(s, BTreeSet::from([deeper]));
            }
            return true;
        }
        if modifiers.contains(InputModifiers::SHIFT) {
            let mut sel = self.snapshot.selection.clone();
            if !sel.remove(&id) {
                sel.insert(id);
            }
            src.select(s, sel);
            return true;
        }
        if !self.snapshot.selection.contains(&id) {
            src.select(s, BTreeSet::from([id]));
        }
        src.begin_gesture(s);
        src.begin_move(s, q, k);
        self.drag = Some(Drag::Move);
        true
    }

    /// The pointer moved with the button down; `now` are the modifiers held now (`None`: those at the press).
    pub fn mouse_dragged(&mut self, s: &mut EditorSession, p: CGPoint, now: Option<InputModifiers>) {
        let modifiers = now.unwrap_or(self.press_modifiers);
        let Some(d) = self.drag.clone() else { return };
        if self.source.is_none() {
            return;
        }
        let r = self.canvas_rect;
        let q = self.sequence(p, r);
        // Shift or Option switches snapping off
        let plain = !modifiers.contains(InputModifiers::SHIFT) && !modifiers.contains(InputModifiers::OPTION);
        let k = self.k(r);
        let Some(src) = self.source.as_mut() else { return };
        match d {
            Drag::Move => self.guides = src.move_to(s, q, plain),
            Drag::Resize(id, corner) => {
                let req = ResizeRequest {
                    id,
                    corner,
                    to: q,
                    snapping: plain,
                    keep_aspect: modifiers.contains(InputModifiers::SHIFT),
                    view_scale: k,
                };
                self.guides = src.resize(s, &req);
            }
            Drag::Marquee(a, _, keep) => {
                let hit = src.layers_in_rect(s, a, q);
                let mut sel = keep.clone();
                sel.extend(hit);
                src.select(s, sel);
                self.drag = Some(Drag::Marquee(a, q, keep));
            }
            Drag::Draw(mut pts) => {
                if let Some(l) = pts.last()
                    && (l.x - q.x).hypot(l.y - q.y) < 2.0
                {
                    return;
                }
                pts.push(q);
                self.drag = Some(Drag::Draw(pts));
            }
        }
        self.refresh(s);
    }

    /// The button went up.
    pub fn mouse_up(&mut self, s: &mut EditorSession) {
        match self.drag.take() {
            Some(Drag::Draw(pts)) => {
                if let Some(src) = self.source.as_mut() {
                    src.add_path(s, &pts);
                }
            }
            // A click on empty canvas (no movement) clears the layers and keeps the clip: back to clip level.
            Some(Drag::Marquee(a, b, keep)) if a == b && keep.is_empty() => {
                if let Some(src) = self.source.as_mut() {
                    src.select(s, BTreeSet::new());
                }
            }
            _ => {}
        }
        self.guides = GraphicsLayerGuides::default();
        self.refresh(s);
    }

    // MARK: Drawing

    /// Draws the layers over the canvas.
    pub fn draw(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        if !self.is_shown || r.is_empty_rect() || self.source.is_none() {
            return;
        }
        let stroke = t.on_picture_stroke();
        for o in self.snapshot.outlines.iter().filter(|o| o.corners.len() == 4) {
            let v: Vec<CGPoint> = o.corners.iter().map(|q| self.view(*q, r)).collect();
            if o.is_selected {
                c.stroke_polygon(&v, 1.5, t.accent());
            } else {
                Self::dashed(c, &v, 3.0, 3.0, stroke.with_alpha(0.25));
            }
        }
        if let Some(h) = self.snapshot.handled.as_ref().filter(|h| h.corners.len() == 4) {
            let s = Self::HANDLE_SIZE;
            for corner in &h.corners {
                let v = self.view(*corner, r);
                let rect = CGRect::new(v.x - s / 2.0, v.y - s / 2.0, s, s);
                c.fill(rect, stroke);
                c.stroke_polygon(&rect.corner_points(), 1.0, t.accent());
            }
        }
        for x in &self.guides.vertical {
            let a = self.view(Vec2::new(*x, 0.0), r);
            c.stroke_line(CGPoint::new(a.x, r.min_y()), CGPoint::new(a.x, r.max_y()), 1.0, t.accent());
        }
        for y in &self.guides.horizontal {
            let a = self.view(Vec2::new(0.0, *y), r);
            c.stroke_line(CGPoint::new(r.min_x(), a.y), CGPoint::new(r.max_x(), a.y), 1.0, t.accent());
        }
        match &self.drag {
            Some(Drag::Marquee(a, b, _)) => {
                let va = self.view(*a, r);
                let vb = self.view(*b, r);
                let rect = CGRect::new(va.x.min(vb.x), va.y.min(vb.y), (va.x - vb.x).abs(), (va.y - vb.y).abs());
                c.fill(rect, t.accent().with_alpha(0.15));
                c.stroke_polygon(&rect.corner_points(), 1.0, t.accent());
            }
            Some(Drag::Draw(pts)) if pts.len() >= 2 => {
                let v: Vec<CGPoint> = pts.iter().map(|q| self.view(*q, r)).collect();
                for i in 1..v.len() {
                    c.stroke_line(v[i - 1], v[i], 2.0, stroke);
                }
            }
            _ => {}
        }
    }

    fn dashed(c: &mut Canvas, poly: &[CGPoint], dash: f64, gap: f64, color: Color) {
        for i in 0..poly.len() {
            let a = poly[i];
            let b = poly[(i + 1) % poly.len()];
            let len = (b.x - a.x).hypot(b.y - a.y);
            if len <= 0.0 {
                continue;
            }
            let ux = (b.x - a.x) / len;
            let uy = (b.y - a.y) / len;
            let mut s = 0.0;
            while s < len {
                let e = (s + dash).min(len);
                c.stroke_line(
                    CGPoint::new(a.x + ux * s, a.y + uy * s),
                    CGPoint::new(a.x + ux * e, a.y + uy * e),
                    1.0,
                    color,
                );
                s = e + gap;
            }
        }
    }
}
