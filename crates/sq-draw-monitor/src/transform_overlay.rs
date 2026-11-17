// Swift: TransformOverlay.swift
//! The Program monitor's transform overlay on the canvas: layer quad, scale and rotate handles, anchor ring, smart and
//! spacing guides, Crop edge handles, the motion path of the position keys, effect point handles. Masks are in
//! `transform_overlay_masks`.
//!
//! All math is the shared `TransformOverlayGeometry` / `MotionPathGeometry` / `CropHandleGeometry`; this type only
//! routes presses and draws. One gesture = began, changed..., ended (the host makes it one undo step); Esc cancels it.
//! Coordinates: window points (the monitor panel converts from pixels); `canvas_rect` is where the sequence is shown.
//! The Swift `on*` hooks are [`OverlayEvent`]s in `events`; `modifiers_now` (a hook that returned a value) is a field the
//! owner fills before each pointer call.

use crate::cg::RectExt;
use crate::mask_handle_edit::MaskHandleEdit;
use crate::point_param_handles::{PointHandle, PointHandleGeometry, PointHandleSnap};
use sq_core_effects::effects_evaluation::CropInsets;
use sq_core_model::{ClipTransform, MaskPath, MaskShapeKind};
use sq_core_time::keyframes_model::KeyframeTrack;
use sq_core_time::{Id, Vec2};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::crop_handle_geometry::{CropEdge, CropHandleGeometry};
use sq_draw::monitor::mask_overlay_geometry::MaskOverlay;
use sq_draw::monitor::spacing_guides::{Gap, SpacingGuides};
use sq_draw::monitor::transform_overlay_geometry::{
    Handle, Hit, MotionHit, MotionPathGeometry, ScaleModifiers, TransformOverlayGeometry,
};
use sq_draw::theme::DrawTheme;
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Color, InputModifiers};
use sq_editor_session::es01_session_core::MaskToolMode;
use sq_editor_session::es02_timeline_ops::{LayerBounds, SafeArea, SnapGuides, SnapResult, SnapTargets};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// One step of a gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// The press.
    Began,
    /// A drag step.
    Changed,
    /// The release.
    Ended,
}

/// Edit of a position key from the motion path. `tangents` is set for handle drags.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PathEdit {
    /// The key.
    pub key: Id,
    /// The new position.
    pub position: Option<Vec2>,
    /// The new (in, out) tangents.
    pub tangents: Option<(Vec2, Vec2)>,
}

/// What the Swift overlay's `on*` hooks reported, in call order.
#[derive(Clone, Debug, PartialEq)]
pub enum OverlayEvent {
    /// `onTransform`: began with the start transform, changed / ended with the new one (display space).
    Transform(Phase, ClipTransform),
    /// `onPathEdit`.
    PathEdit(Phase, PathEdit),
    /// `onCrop`: the edge and its inset (fraction of the frame).
    Crop(Phase, CropEdge, f64),
    /// `onPointHandle`: the handle id and its offset (sequence px from the canvas center).
    PointHandle(Phase, String, Vec2),
    /// `onDragCanceled`: Esc during a drag, the host puts the clip back as it was at the press.
    DragCanceled,
    /// `onMaskVertex`: a vertex drag (frame fraction of the vertex).
    MaskVertex(Phase, Id, usize, Vec2),
    /// `onMaskEdit`: pen handles of a mask; a click sends began + ended.
    MaskEdit(Phase, MaskHandleEdit),
    /// `onMaskToolClick`: a Mask tool click on the layer (frame fraction, modifier keys at the press).
    MaskToolClick(Vec2, InputModifiers),
    /// Magic mode, a drag from one corner to the other on the layer (frame fractions, modifier keys at the press): a box prompt.
    MaskToolBox(Vec2, Vec2, InputModifiers),
    /// `onMaskToolHover`: Magic mode, the pointer moved over the layer (frame fraction), or left it.
    MaskToolHover(Option<Vec2>),
    /// `onMaskShapeDrawn`: Ellipse / Rectangle dragged out with the Mask tool, sent once on release.
    MaskShapeDrawn(MaskShapeKind, MaskPath),
    /// `onMaskSelect`: a press picked this mask; the host selects it in Effect Controls.
    MaskSelect(Id),
}

/// The running drag.
#[derive(Clone, Debug)]
pub(crate) enum Drag {
    Body {
        start: CGPoint,
        geo: TransformOverlayGeometry,
    },
    Scale {
        handle: Handle,
        start: CGPoint,
        geo: TransformOverlayGeometry,
    },
    Rotate {
        start: CGPoint,
        geo: TransformOverlayGeometry,
        last: f64,
    },
    Anchor {
        start: CGPoint,
        geo: TransformOverlayGeometry,
    },
    Key(Id),
    Tangent {
        id: Id,
        side: MotionHit,
        current: (Vec2, Vec2),
    },
    Crop(CropEdge),
    Point {
        handle: PointHandle,
        grab: CGPoint,
    },
    MaskVertex(Id, usize),
    MaskTangent {
        id: Id,
        vertex: usize,
        out: bool,
        last: Vec2,
        independent: bool,
    },
    MaskMove {
        id: Id,
        start: Vec2,
        base: MaskPath,
        last: Vec2,
    },
    MaskPen {
        id: Id,
        segment: usize,
        t: f64,
        base: MaskPath,
        last: Vec2,
        independent: bool,
    },
    /// Mask tool press (Pen / shapes): nothing is placed until release; shapes rubber-band while dragging.
    MaskTool {
        mode: MaskToolMode,
        start: Vec2,
        start_view: CGPoint,
        modifiers: InputModifiers,
        moved: bool,
    },
}

impl Drag {
    /// A drag that rewrites a mask path live (Esc puts the masks back as they were at the press).
    pub(crate) fn is_mask_edit(&self) -> bool {
        matches!(self, Drag::MaskVertex(..) | Drag::MaskTangent { .. } | Drag::MaskMove { .. } | Drag::MaskPen { .. })
    }
}

/// The transform overlay of the Program monitor.
pub struct TransformOverlay {
    /// What the hooks reported since the owner last took them.
    pub events: Vec<OverlayEvent>,
    /// Modifier keys held now (drags carry none); `None` = the keys held at the press. The owner sets it per event.
    pub modifiers_now: Option<InputModifiers>,
    /// Shown and grabbable (a picture clip is selected under the playhead, not playing).
    pub is_shown: bool,
    /// The sequence size in px.
    pub sequence_size: CGSize,
    /// Upright native size of the picture in sequence px (scale 1 = this size).
    pub media_pixel_size: Option<CGSize>,
    /// The target's display transform at the playhead; ignored for drawing while a gesture runs.
    pub transform: ClipTransform,
    /// The position keys.
    pub position_track: KeyframeTrack<Vec2>,
    /// The selected position key.
    pub selected_key: Option<Id>,
    /// Corner handles keep the aspect.
    pub uniform_scale: bool,
    /// Smart guide targets for moves; `None` = none.
    pub snap_targets: Option<SnapTargets>,
    /// Bounds of the other layers (spacing guides).
    pub neighbor_bounds: Vec<CGRect>,
    /// Dashed action / title safe frames while Safe Margins is on (drawn with the layer).
    pub safe_areas: Vec<SafeArea>,
    /// Crop effect selected in Effect Controls: edge handles instead of scale and rotate handles.
    pub crop_insets: Option<CropInsets>,
    /// Point parameters of the selected clip's effects (the host maps them through the clip's transform).
    pub point_handles: Vec<PointHandle>,
    /// The selected clip's masks at the playhead (frame fractions); the active one shows its tangent handles.
    pub masks: Vec<MaskOverlay>,
    /// Mask tool mode (`None` = Selection tool): the transform box rests, the masks' handles still edit, every other press
    /// on the layer is a tool press (Pen point, Ellipse / Rectangle click or drag).
    pub mask_tool: Option<MaskToolMode>,
    /// Mask Tint: the image slot holding the Magic mattes' coverage, drawn yellow over the layer under the mask outlines.
    pub mask_tint_slot: Option<usize>,
    /// Magic mode: the Add | Remove switch (top left of the picture). true = Remove; Option at the click flips it.
    pub magic_subtract: bool,
    pub(crate) magic_hover_point: Option<Vec2>,
    pub(crate) drag: Option<Drag>,
    pub(crate) masks_at_press: Option<Vec<MaskOverlay>>,
    /// The Ellipse / Rectangle being dragged out.
    pub(crate) draw_preview: Option<MaskPath>,
    press_modifiers: InputModifiers,
    /// The hover cursor at the press: a handle drag keeps it.
    held_cursor: Option<DrawCursor>,
    pub(crate) canvas_rect: CGRect,
    live_transform: Option<ClipTransform>,
    live_crop: Option<CropInsets>,
    live_points: Vec<(String, Vec2)>,
    active_guides: SnapResult,
    active_gaps: Vec<Gap>,
}

impl Default for TransformOverlay {
    fn default() -> Self {
        Self::new()
    }
}

impl TransformOverlay {
    /// Smart-guide and handle snap distance in view points.
    pub const SNAP_DISTANCE: f64 = 6.0;

    /// A hidden overlay.
    pub fn new() -> TransformOverlay {
        TransformOverlay {
            events: Vec::new(),
            modifiers_now: None,
            is_shown: false,
            sequence_size: CGSize::new(1920.0, 1080.0),
            media_pixel_size: None,
            transform: ClipTransform::IDENTITY,
            position_track: KeyframeTrack::default(),
            selected_key: None,
            uniform_scale: true,
            snap_targets: None,
            neighbor_bounds: Vec::new(),
            safe_areas: Vec::new(),
            crop_insets: None,
            point_handles: Vec::new(),
            masks: Vec::new(),
            mask_tool: None,
            mask_tint_slot: None,
            magic_subtract: false,
            magic_hover_point: None,
            drag: None,
            masks_at_press: None,
            draw_preview: None,
            press_modifiers: InputModifiers::NONE,
            held_cursor: None,
            canvas_rect: CGRect::default(),
            live_transform: None,
            live_crop: None,
            live_points: Vec::new(),
            active_guides: SnapResult::none(),
            active_gaps: Vec::new(),
        }
    }

    /// Takes the hook calls since the last take.
    pub fn take_events(&mut self) -> Vec<OverlayEvent> {
        std::mem::take(&mut self.events)
    }

    /// A gesture runs.
    pub fn is_dragging(&self) -> bool {
        self.drag.is_some()
    }

    /// Swift's `didSet` on `drag`: a mask edit remembers the masks as they were at the press.
    pub(crate) fn set_drag(&mut self, d: Option<Drag>) {
        if self.drag.is_none() && d.as_ref().is_some_and(Drag::is_mask_edit) {
            self.masks_at_press = Some(self.masks.clone());
        }
        self.drag = d;
    }

    // MARK: Geometry

    pub(crate) fn geometry(&self, r: CGRect) -> TransformOverlayGeometry {
        let aspect =
            self.media_pixel_size.map_or(16.0 / 9.0, |s| if s.height > 0.0 { s.width / s.height } else { 16.0 / 9.0 });
        TransformOverlayGeometry::new(
            self.sequence_size,
            r,
            aspect,
            self.live_transform.unwrap_or(self.transform),
            self.media_pixel_size,
        )
    }

    fn point_geometry(&self, r: CGRect) -> PointHandleGeometry {
        PointHandleGeometry::new(self.sequence_size, r)
    }

    fn live_point(&self, id: &str) -> Option<Vec2> {
        self.live_points.iter().find(|(k, _)| k == id).map(|(_, v)| *v)
    }

    /// The handles where they are shown now (a running drag shows its live offset).
    pub fn displayed_points(&self) -> Vec<PointHandle> {
        self.point_handles
            .iter()
            .map(|h| PointHandle { id: h.id.clone(), offset: self.live_point(&h.id).unwrap_or(h.offset) })
            .collect()
    }

    fn point_hit(&self, p: CGPoint, r: CGRect) -> Option<PointHandle> {
        let shown = self.displayed_points();
        let id = self.point_geometry(r).hit_test(p, &shown, PointHandleGeometry::HIT_RADIUS)?;
        shown.into_iter().find(|h| h.id == id)
    }

    fn path_geometry(&self, r: CGRect) -> Option<MotionPathGeometry> {
        if self.position_track.is_empty() {
            None
        } else {
            Some(MotionPathGeometry::new(&self.position_track, self.sequence_size, r, 32))
        }
    }

    fn crop_edge(&self, p: CGPoint, g: &TransformOverlayGeometry) -> Option<CropEdge> {
        let i = self.live_crop.or(self.crop_insets)?;
        CropHandleGeometry::new(&g.quad()).hit(p, &i)
    }

    /// The box hit under `p`; in crop mode only the picture moves (no scale or rotate handles).
    fn transform_hit(&self, p: CGPoint, g: &TransformOverlayGeometry) -> Option<Hit> {
        let hit = g.hit_test(p, true);
        if self.crop_insets.is_none() {
            return hit;
        }
        match hit? {
            Hit::Handle(_) => Some(Hit::Body),
            Hit::Rotate(_) => None,
            other => Some(other),
        }
    }

    /// True when a press at `p` lands on the overlay (else it falls through to the monitor below).
    pub fn hits(&self, p: CGPoint, r: CGRect) -> bool {
        if !self.is_shown || r.is_empty_rect() {
            return false;
        }
        if let Some(mode) = self.mask_tool {
            if mode == MaskToolMode::Magic && self.magic_switch_hit(p, r).is_some() {
                return true;
            }
            if mode != MaskToolMode::Magic && self.mask_hit(p, r).is_some() {
                return true;
            }
            return self.mask_frame_point(p, r).is_some();
        }
        if self.point_hit(p, r).is_some() {
            return true;
        }
        let g = self.geometry(r);
        if self.crop_edge(p, &g).is_some() {
            return true;
        }
        if self.mask_hit(p, r).is_some() {
            return true;
        }
        if self.path_geometry(r).and_then(|path| path.hit_test(p, self.selected_key)).is_some() {
            return true;
        }
        self.transform_hit(p, &g).is_some()
    }

    // MARK: Hover cursor

    /// The pointer shape over the overlay at `p`, `None` when it is not on a handle (the monitor's own cursor stays).
    /// Like the Mac `TransformOverlayView.updateCursor`: rotate arrows toward the corner, a resize arrow along the
    /// handle, the four-way move over the body, the crosshair on the anchor.
    pub fn hover_cursor(&self, p: CGPoint, r: CGRect) -> Option<DrawCursor> {
        if !self.is_shown || r.is_empty_rect() {
            return None;
        }
        if self.mask_tool == Some(MaskToolMode::Magic) && self.magic_switch_hit(p, r).is_some() {
            return None;
        }
        if let Some(mode) = self.mask_tool {
            // Mask tool: the whole overlay is a crosshair, the active mask's inside moves it (Pen / shapes).
            if mode != MaskToolMode::Magic
                && matches!(self.mask_hit(p, r), Some(crate::transform_overlay_masks::MaskHit::Inside(_)))
            {
                return Some(DrawCursor::Move);
            }
            return self.mask_frame_point(p, r).map(|_| DrawCursor::Crosshair);
        }
        if self.point_hit(p, r).is_some() {
            return Some(DrawCursor::Crosshair);
        }
        let g = self.geometry(r);
        if let Some(e) = self.crop_edge(p, &g) {
            return Some(if e.is_vertical() { DrawCursor::ResizeLeftRight } else { DrawCursor::ResizeUpDown });
        }
        if let Some(h) = self.mask_hit(p, r) {
            return Some(if matches!(h, crate::transform_overlay_masks::MaskHit::Inside(_)) {
                DrawCursor::Move
            } else {
                DrawCursor::Crosshair
            });
        }
        match self.transform_hit(p, &g)? {
            Hit::Anchor => Some(DrawCursor::Crosshair),
            Hit::Rotate(h) => Some(DrawCursor::rotate(g.view_angle_of(h))),
            Hit::Body => Some(DrawCursor::Move),
            Hit::Handle(h) => Some(DrawCursor::resize(g.view_angle_of(h))),
        }
    }

    /// The pointer shape while a drag runs: the closed hand for a picture or mask move, the hover shape kept for
    /// handles, `None` for motion path keys.
    pub fn drag_cursor(&self) -> Option<DrawCursor> {
        match self.drag {
            None | Some(Drag::Key(_)) | Some(Drag::Tangent { .. }) => None,
            Some(Drag::Body { .. }) | Some(Drag::MaskMove { .. }) => Some(DrawCursor::ClosedHand),
            _ => self.held_cursor,
        }
    }

    // MARK: Input

    /// A left press; true when the overlay took it.
    pub fn mouse_down(&mut self, p: CGPoint, modifiers: InputModifiers, r: CGRect) -> bool {
        if !self.hits(p, r) {
            return false;
        }
        self.canvas_rect = r;
        self.press_modifiers = modifiers;
        self.held_cursor = self.hover_cursor(p, r);
        if self.mask_tool == Some(MaskToolMode::Magic)
            && let Some(remove) = self.magic_switch_hit(p, r)
        {
            self.magic_subtract = remove;
            return true;
        }
        if self.mask_tool.is_some() {
            return self.mask_tool_down(p, modifiers);
        }
        // Point-parameter handles sit on top of everything else.
        if let Some(h) = self.point_hit(p, r) {
            self.events.push(OverlayEvent::PointHandle(Phase::Began, h.id.clone(), h.offset));
            self.set_drag(Some(Drag::Point { handle: h, grab: p }));
            return true;
        }
        let g = self.geometry(r);
        if let Some(edge) = self.crop_edge(p, &g)
            && let Some(i) = self.crop_insets
        {
            self.set_drag(Some(Drag::Crop(edge)));
            self.live_crop = Some(i);
            self.events.push(OverlayEvent::Crop(Phase::Began, edge, edge.value(&i)));
            return true;
        }
        if self.mask_handles_down(p, modifiers) {
            return true;
        }
        if let Some(path) = self.path_geometry(r)
            && let Some(hit) = path.hit_test(p, self.selected_key)
        {
            match hit {
                MotionHit::Key(id) => {
                    self.set_drag(Some(Drag::Key(id)));
                    self.events.push(OverlayEvent::PathEdit(
                        Phase::Began,
                        PathEdit { key: id, position: Some(path.key_value(p)), tangents: None },
                    ));
                }
                MotionHit::InTangent(id) | MotionHit::OutTangent(id) => {
                    let k = self.position_track.key(id);
                    let current = (k.map_or(Vec2::ZERO, |k| k.in_tangent), k.map_or(Vec2::ZERO, |k| k.out_tangent));
                    self.set_drag(Some(Drag::Tangent { id, side: hit, current }));
                    self.events.push(OverlayEvent::PathEdit(
                        Phase::Began,
                        PathEdit { key: id, position: None, tangents: Some(current) },
                    ));
                }
            }
            return true;
        }
        let Some(mut hit) = self.transform_hit(p, &g) else { return false };
        // Alt-drag on the picture moves the anchor point, not the picture.
        if hit == Hit::Body && modifiers.contains(InputModifiers::OPTION) {
            hit = Hit::Anchor;
        }
        let drag = match hit {
            Hit::Body => Drag::Body { start: p, geo: g.clone() },
            Hit::Handle(h) => Drag::Scale { handle: h, start: p, geo: g.clone() },
            Hit::Rotate(_) => Drag::Rotate { start: p, geo: g.clone(), last: g.transform.rotation },
            Hit::Anchor => Drag::Anchor { start: p, geo: g.clone() },
        };
        self.set_drag(Some(drag));
        self.live_transform = Some(g.transform);
        self.events.push(OverlayEvent::Transform(Phase::Began, g.transform));
        true
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint) {
        let Some(d) = self.drag.clone() else { return };
        let mods = self.modifiers_now.unwrap_or(self.press_modifiers);
        let shift = mods.contains(InputModifiers::SHIFT);
        let option = mods.contains(InputModifiers::OPTION);
        match d {
            Drag::Body { start, geo } => {
                let t = self.snapped(geo.moved(start, p, shift), &geo, mods.contains(InputModifiers::COMMAND), shift);
                self.emit(t);
            }
            Drag::Scale { handle, start, geo } => {
                let m = ScaleModifiers { shift, option, uniform_scale: self.uniform_scale };
                self.emit(geo.scaled(handle, start, p, m));
            }
            Drag::Rotate { start, geo, last } => {
                let t = geo.rotated(start, p, shift, Some(last));
                self.set_drag(Some(Drag::Rotate { start, geo, last: t.rotation }));
                self.emit(t);
            }
            Drag::Anchor { start, geo } => self.emit(geo.anchor_moved(start, p)),
            Drag::Crop(edge) => {
                let Some(base) = self.live_crop else { return };
                let v = CropHandleGeometry::new(&self.geometry(self.canvas_rect).quad()).inset(edge, p, &base);
                self.live_crop = Some(edge.setting(v, &base));
                self.events.push(OverlayEvent::Crop(Phase::Changed, edge, v));
            }
            Drag::Key(id) => {
                let Some(path) = self.path_geometry(self.canvas_rect) else { return };
                self.events.push(OverlayEvent::PathEdit(
                    Phase::Changed,
                    PathEdit { key: id, position: Some(path.key_value(p)), tangents: None },
                ));
            }
            Drag::Tangent { id, side, current } => {
                let Some(path) = self.path_geometry(self.canvas_rect) else { return };
                let t = path.tangents(id, side, p, option, current);
                self.set_drag(Some(Drag::Tangent { id, side, current: t }));
                self.events.push(OverlayEvent::PathEdit(
                    Phase::Changed,
                    PathEdit { key: id, position: None, tangents: Some(t) },
                ));
            }
            Drag::Point { handle, grab } => {
                let snap = self
                    .snap_targets
                    .clone()
                    .map(|targets| PointHandleSnap { targets, view_threshold: Self::SNAP_DISTANCE });
                let use_snap = if mods.contains(InputModifiers::COMMAND) { None } else { snap.as_ref() };
                let r = self.point_geometry(self.canvas_rect).dragged(&handle, grab, p, shift, use_snap);
                self.active_guides = r.guides;
                self.set_live_point(&handle.id, r.offset);
                self.events.push(OverlayEvent::PointHandle(Phase::Changed, handle.id, r.offset));
            }
            Drag::MaskVertex(..)
            | Drag::MaskTangent { .. }
            | Drag::MaskPen { .. }
            | Drag::MaskMove { .. }
            | Drag::MaskTool { .. } => self.mask_dragged(&d, p, shift, option),
        }
    }

    fn set_live_point(&mut self, id: &str, o: Vec2) {
        match self.live_points.iter_mut().find(|(k, _)| k == id) {
            Some(e) => e.1 = o,
            None => self.live_points.push((id.to_string(), o)),
        }
    }

    /// The button went up.
    pub fn mouse_up(&mut self, p: CGPoint) {
        let Some(d) = self.drag.take() else { return };
        match d {
            Drag::Crop(edge) => {
                let g = self.geometry(self.canvas_rect);
                let current = self.live_crop.or(self.crop_insets).unwrap_or(CropInsets::NONE);
                let v = CropHandleGeometry::new(&g.quad()).inset(edge, p, &current);
                self.events.push(OverlayEvent::Crop(Phase::Ended, edge, v));
                self.live_crop = None;
            }
            Drag::Key(id) => {
                let position = self.path_geometry(self.canvas_rect).map(|g| g.key_value(p));
                self.events.push(OverlayEvent::PathEdit(Phase::Ended, PathEdit { key: id, position, tangents: None }));
            }
            Drag::Tangent { id, current, .. } => {
                self.events.push(OverlayEvent::PathEdit(
                    Phase::Ended,
                    PathEdit { key: id, position: None, tangents: Some(current) },
                ));
            }
            Drag::Point { handle, .. } => {
                let o = self.live_point(&handle.id).unwrap_or(handle.offset);
                self.events.push(OverlayEvent::PointHandle(Phase::Ended, handle.id.clone(), o));
                self.live_points.retain(|(k, _)| *k != handle.id);
                self.active_guides = SnapResult::none();
                self.active_gaps = Vec::new();
            }
            Drag::MaskVertex(..)
            | Drag::MaskTangent { .. }
            | Drag::MaskPen { .. }
            | Drag::MaskMove { .. }
            | Drag::MaskTool { .. } => self.mask_up(&d, p),
            _ => {
                if let Some(t) = self.live_transform {
                    self.events.push(OverlayEvent::Transform(Phase::Ended, t));
                }
                self.live_transform = None;
                self.active_guides = SnapResult::none();
                self.active_gaps = Vec::new();
            }
        }
    }

    /// Esc: drops the running drag; true when there was one (the key is consumed).
    pub fn cancel_drag(&mut self) -> bool {
        let Some(d) = self.drag.take() else { return false };
        if d.is_mask_edit()
            && let Some(saved) = self.masks_at_press.clone()
        {
            self.masks = saved;
        }
        self.masks_at_press = None;
        self.draw_preview = None;
        if matches!(d, Drag::MaskTool { .. }) {
            return true; // nothing was applied yet: no host revert
        }
        self.live_transform = None;
        self.live_crop = None;
        self.live_points = Vec::new();
        self.active_guides = SnapResult::none();
        self.active_gaps = Vec::new();
        self.events.push(OverlayEvent::DragCanceled);
        true
    }

    /// Smart guides: the moved layer's edges and center snap to the canvas and the other layers.
    fn snapped(
        &mut self,
        t: ClipTransform,
        g: &TransformOverlayGeometry,
        disabled: bool,
        lock_axis: bool,
    ) -> ClipTransform {
        let Some(targets) = self.snap_targets.as_ref().filter(|_| !disabled && g.view_scale() > 0.0) else {
            self.active_guides = SnapResult::none();
            self.active_gaps = Vec::new();
            return t;
        };
        let size = g.fitted_size();
        let box_ = LayerBounds::rect(size, &t);
        let r = SnapGuides::snap_box(box_, targets, Self::SNAP_DISTANCE / g.view_scale()).locking(
            lock_axis && t.position.x == g.transform.position.x,
            lock_axis && t.position.y == g.transform.position.y,
        );
        self.active_guides = r.clone();
        let mut out = t;
        out.position = Vec2::new(t.position.x + r.dx, t.position.y + r.dy);
        self.active_gaps = Vec::new();
        if !lock_axis && !self.neighbor_bounds.is_empty() {
            let moved = LayerBounds::rect(size, &out);
            let s = SpacingGuides::snap(moved, &self.neighbor_bounds, Self::SNAP_DISTANCE / g.view_scale());
            let use_x = r.vertical_lines.is_empty() && s.dx != 0.0;
            let use_y = r.horizontal_lines.is_empty() && s.dy != 0.0;
            if use_x {
                out.position.x += s.dx;
            }
            if use_y {
                out.position.y += s.dy;
            }
            self.active_gaps = s.gaps.into_iter().filter(|g| if g.vertical { use_y } else { use_x }).collect();
        }
        out
    }

    fn emit(&mut self, t: ClipTransform) {
        self.live_transform = Some(t);
        self.events.push(OverlayEvent::Transform(Phase::Changed, t));
    }

    // MARK: Drawing

    /// Draws the overlay over the canvas.
    pub fn draw(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        if !self.is_shown || r.is_empty_rect() {
            return;
        }
        self.draw_body(c, r, t);
        self.draw_point_handles(c, r, t);
    }

    fn draw_body(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        let stroke = t.on_picture_stroke();
        let shadow = t.on_picture_shadow();
        let yellow = t.yellow();
        let g = self.geometry(r);
        for a in &self.safe_areas {
            let s = a.rect(self.sequence_size);
            let tl = g.view_point_from_offset(Vec2::new(s.min_x(), s.min_y()));
            let br = g.view_point_from_offset(Vec2::new(s.max_x(), s.max_y()));
            let rect = CGRect::new(tl.x, tl.y, br.x - tl.x, br.y - tl.y);
            crate::monitor_panel_overlays::dashed_rect(c, rect, 4.0, 3.0, stroke.with_alpha(0.7));
        }
        if let Some(path) = self.path_geometry(r) {
            self.draw_motion_path(c, &path, t);
        }
        if self.drag.is_some() {
            self.draw_guides(c, &g, r, t);
        }
        if self.mask_tool.is_some() {
            // Mask tool: masks and the shape being drawn, no box
            self.draw_mask_tint(c, r, t);
            self.draw_masks(c, r, t);
            self.draw_shape_preview(c, r, t);
            if self.mask_tool == Some(MaskToolMode::Magic) {
                self.draw_magic_switch(c, r, t);
            }
            return;
        }
        self.draw_masks(c, r, t);

        let q = g.quad();
        c.stroke_polygon(&q, 3.0, shadow);
        c.stroke_polygon(&q, 1.0, stroke);
        if let Some(i) = self.live_crop.or(self.crop_insets) {
            let cg = CropHandleGeometry::new(&q);
            let kept = cg.corners(&i);
            if !i.is_identity() {
                c.stroke_polygon(&kept, 3.0, shadow);
                c.stroke_polygon(&kept, 1.0, yellow);
            }
            for e in CropEdge::ALL {
                let p = cg.handle_point(e, &i);
                let (w, h) = if e.is_vertical() { (5.0, 11.0) } else { (11.0, 5.0) };
                let rect = CGRect::new(p.x - w / 2.0, p.y - h / 2.0, w, h);
                c.fill(rect, yellow);
                c.stroke_polygon(&rect.corner_points(), 1.0, shadow);
            }
            return;
        }
        // White 1 pt frame, white 8 pt squares with a shadow edge, a white ring at the anchor (blue is only the panel focus,
        // Export and the dock preview: HAUPTFENSTER 4).
        for h in Handle::ALL {
            let p = g.view_point_of(h);
            let rect = CGRect::new(p.x - 4.0, p.y - 4.0, 8.0, 8.0);
            c.fill(rect, stroke);
            c.stroke_polygon(&rect.corner_points(), 1.0, shadow);
        }
        let a = g.anchor_view_point();
        c.stroke_ellipse(CGRect::new(a.x - 5.0, a.y - 5.0, 10.0, 10.0), 1.2, stroke);
    }

    /// White dots with a dark edge over a soft dark ring.
    fn draw_point_handles(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        let geo = self.point_geometry(r);
        for h in self.displayed_points() {
            let p = geo.view_point_from_offset(h.offset);
            let ring = CGRect::new(p.x - 5.0, p.y - 5.0, 10.0, 10.0);
            c.stroke_ellipse(ring, 3.0, t.on_picture_shadow());
            c.fill_ellipse(ring, t.on_picture_stroke());
            c.stroke_ellipse(ring, 1.5, t.on_picture_shadow());
        }
    }

    fn draw_guides(&self, c: &mut Canvas, g: &TransformOverlayGeometry, r: CGRect, t: &DrawTheme) {
        let color: Color = t.guide_snap();
        let k = g.view_scale();
        for gap in &self.active_gaps {
            let a = gap.from * k;
            let b = gap.to * k;
            let x = gap.cross * k;
            if gap.vertical {
                c.stroke_line(
                    CGPoint::new(r.mid_x() + x, r.mid_y() + a),
                    CGPoint::new(r.mid_x() + x, r.mid_y() + b),
                    2.0,
                    color,
                );
            } else {
                c.stroke_line(
                    CGPoint::new(r.mid_x() + a, r.mid_y() + x),
                    CGPoint::new(r.mid_x() + b, r.mid_y() + x),
                    2.0,
                    color,
                );
            }
        }
        for x in &self.active_guides.vertical_lines {
            let vx = r.mid_x() + x * k;
            c.stroke_line(CGPoint::new(vx, r.min_y()), CGPoint::new(vx, r.max_y()), 1.0, color);
        }
        for y in &self.active_guides.horizontal_lines {
            let vy = r.mid_y() + y * k;
            c.stroke_line(CGPoint::new(r.min_x(), vy), CGPoint::new(r.max_x(), vy), 1.0, color);
        }
    }

    fn draw_motion_path(&self, c: &mut Canvas, path: &MotionPathGeometry, t: &DrawTheme) {
        let shadow = t.on_picture_shadow();
        for seg in path.segments.iter().filter(|s| s.len() > 1) {
            c.stroke_polyline(seg, 3.0, shadow);
            c.stroke_polyline(seg, 1.0, t.yellow());
        }
        for k in &path.keys {
            let show_in = Some(k.id) == self.selected_key || k.has_in_tangent;
            let show_out = Some(k.id) == self.selected_key || k.has_out_tangent;
            for (show, h) in [(show_in, k.in_handle), (show_out, k.out_handle)] {
                if show && h != k.point {
                    c.stroke_line(k.point, h, 1.0, t.label2());
                    let dot = CGRect::new(h.x - 3.5, h.y - 3.5, 7.0, 7.0);
                    c.fill_ellipse(dot, t.yellow());
                    c.stroke_ellipse(dot, 1.0, shadow);
                }
            }
            let r = 4.5;
            let diamond = [
                CGPoint::new(k.point.x, k.point.y - r),
                CGPoint::new(k.point.x + r, k.point.y),
                CGPoint::new(k.point.x, k.point.y + r),
                CGPoint::new(k.point.x - r, k.point.y),
            ];
            c.fill_polygon(&diamond, if Some(k.id) == self.selected_key { t.on_picture_stroke() } else { t.yellow() });
            c.stroke_polygon(&diamond, 1.0, shadow);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_editor_session::es02_timeline_ops::SnapGuides;

    /// A full-frame 1920x1080 picture shown at 960x540 (view scale 0.5).
    fn rect() -> CGRect {
        CGRect::new(100.0, 50.0, 960.0, 540.0)
    }

    fn shown() -> TransformOverlay {
        let mut o = TransformOverlay::new();
        o.is_shown = true;
        o.media_pixel_size = Some(CGSize::new(1920.0, 1080.0));
        o
    }

    #[test]
    fn point_handle_drag_reports_offsets_and_wins_over_the_box() {
        let r = rect();
        let mut o = shown();
        o.point_handles = vec![PointHandle { id: "fx|center".into(), offset: Vec2::new(100.0, 50.0) }];
        let at = CGPoint::new(r.mid_x() + 50.0, r.mid_y() + 25.0); // the handle in view points
        assert!(o.mouse_down(at, InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(at.x + 10.0, at.y + 5.0));
        assert_eq!(o.displayed_points()[0].offset, Vec2::new(120.0, 60.0));
        o.mouse_up(CGPoint::new(at.x + 10.0, at.y + 5.0));
        let events = o.take_events();
        let phases: Vec<Phase> = events
            .iter()
            .filter_map(|e| if let OverlayEvent::PointHandle(p, ..) = e { Some(*p) } else { None })
            .collect();
        assert_eq!(phases, [Phase::Began, Phase::Changed, Phase::Ended]);
        assert!(events.iter().all(|e| matches!(e, OverlayEvent::PointHandle(_, id, _) if id == "fx|center")));
        assert!(matches!(events.last(), Some(OverlayEvent::PointHandle(_, _, v)) if *v == Vec2::new(120.0, 60.0)));
        // the host writes the value back
        assert_eq!(o.displayed_points()[0].offset, Vec2::new(100.0, 50.0));
    }

    #[test]
    fn esc_cancels_a_point_drag() {
        let r = rect();
        let mut o = TransformOverlay::new();
        o.is_shown = true;
        o.point_handles = vec![PointHandle { id: "a".into(), offset: Vec2::ZERO }];
        assert!(o.mouse_down(CGPoint::new(r.mid_x(), r.mid_y()), InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(r.mid_x() + 40.0, r.mid_y()));
        assert!(o.cancel_drag());
        let canceled = o.take_events().iter().filter(|e| **e == OverlayEvent::DragCanceled).count();
        assert_eq!(canceled, 1);
        assert_eq!(o.displayed_points()[0].offset, Vec2::ZERO);
    }

    #[test]
    fn a_body_drag_sends_began_changed_ended_with_the_moved_transform() {
        let r = rect();
        let mut o = shown();
        let start = CGPoint::new(r.mid_x() + 100.0, r.mid_y() + 60.0);
        assert!(o.mouse_down(start, InputModifiers::NONE, r));
        assert!(o.is_dragging());
        o.mouse_dragged(CGPoint::new(start.x + 20.0, start.y));
        o.mouse_up(CGPoint::new(start.x + 20.0, start.y));
        let t: Vec<(Phase, f64)> = o
            .take_events()
            .iter()
            .filter_map(|e| if let OverlayEvent::Transform(p, t) = e { Some((*p, t.position.x)) } else { None })
            .collect();
        assert_eq!(t.iter().map(|x| x.0).collect::<Vec<_>>(), [Phase::Began, Phase::Changed, Phase::Ended]);
        assert!((t[1].1 - 40.0).abs() < 1e-9);
        assert!(!o.is_dragging());
    }

    #[test]
    fn a_hidden_overlay_takes_nothing() {
        let o = TransformOverlay::new();
        assert!(!o.hits(CGPoint::new(500.0, 300.0), rect()));
        assert_eq!(o.hover_cursor(CGPoint::new(500.0, 300.0), rect()), None);
    }

    use sq_core_time::keyframes_model::Keyframe;
    use sq_core_time::{IdSource, SequentialIds, Time};

    fn phases(o: &mut TransformOverlay) -> Vec<(Phase, ClipTransform)> {
        o.take_events()
            .into_iter()
            .filter_map(|e| if let OverlayEvent::Transform(p, t) = e { Some((p, t)) } else { None })
            .collect()
    }

    #[test]
    fn body_drag_moves_the_position_in_sequence_pixels() {
        let r = rect();
        let mut o = shown();
        let start = CGPoint::new(r.mid_x() + 100.0, r.mid_y() + 50.0);
        assert!(o.mouse_down(start, InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(start.x + 20.0, start.y + 10.0));
        o.mouse_up(CGPoint::new(start.x + 20.0, start.y + 10.0));
        let ev = phases(&mut o);
        assert_eq!(ev.iter().map(|e| e.0).collect::<Vec<_>>(), [Phase::Began, Phase::Changed, Phase::Ended]);
        assert_eq!(ev.last().map(|e| e.1.position), Some(Vec2::new(40.0, 20.0)));
        assert!(!o.is_dragging());
    }

    #[test]
    fn shift_locks_the_move_to_the_dominant_axis() {
        let r = rect();
        let mut o = shown();
        o.modifiers_now = Some(InputModifiers::SHIFT);
        let start = CGPoint::new(r.mid_x() + 100.0, r.mid_y() + 50.0);
        o.mouse_down(start, InputModifiers::NONE, r);
        o.mouse_dragged(CGPoint::new(start.x + 30.0, start.y + 5.0));
        assert_eq!(phases(&mut o).last().map(|e| e.1.position), Some(Vec2::new(60.0, 0.0)));
    }

    #[test]
    fn move_snaps_to_the_canvas_center() {
        let r = rect();
        let mut o = shown();
        o.snap_targets = Some(SnapGuides::targets(CGSize::new(1920.0, 1080.0), &[], &[], None));
        let start = CGPoint::new(r.mid_x() + 100.0, r.mid_y() + 50.0);
        o.mouse_down(start, InputModifiers::NONE, r);
        o.mouse_dragged(CGPoint::new(start.x + 2.0, start.y)); // 4 px in sequence space: within 6 view px
        assert_eq!(phases(&mut o).last().map(|e| e.1.position), Some(Vec2::new(0.0, 0.0)));
        let mut c = Canvas::with_size(1200.0, 700.0, None, 1.0);
        o.draw(&mut c, r, &DrawTheme::default()); // guides drawn while dragging, no crash
    }

    #[test]
    fn corner_handle_scales_uniformly_about_the_anchor() {
        let r = rect();
        let mut o = shown();
        let corner = CGPoint::new(r.max_x(), r.max_y());
        assert!(o.mouse_down(corner, InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(corner.x + 48.0, corner.y + 27.0));
        o.mouse_up(CGPoint::new(corner.x + 48.0, corner.y + 27.0));
        let t = phases(&mut o).last().map(|e| e.1).unwrap_or(ClipTransform::IDENTITY);
        assert!((t.scale.x - 1.1).abs() < 1e-6 && (t.scale.y - 1.1).abs() < 1e-6);
        assert_eq!(t.position, Vec2::ZERO);
    }

    #[test]
    fn hover_cursors_match_the_mac_overlay() {
        let r = rect();
        let o = shown();
        let at = |x: f64, y: f64| o.hover_cursor(CGPoint::new(x, y), r);
        assert_eq!(at(r.max_x(), r.max_y()), Some(DrawCursor::OverlayResize(30)));
        assert_eq!(at(r.min_x(), r.min_y()), Some(DrawCursor::OverlayResize(30)));
        assert_eq!(at(r.max_x(), r.min_y()), Some(DrawCursor::OverlayResize(150)));
        assert_eq!(at(r.max_x(), r.mid_y()), Some(DrawCursor::OverlayResize(0)));
        assert_eq!(at(r.mid_x(), r.min_y()), Some(DrawCursor::OverlayResize(90)));
        assert_eq!(at(r.max_x() + 10.0, r.min_y() - 10.0), Some(DrawCursor::OverlayRotate(330)));
        assert_eq!(at(r.min_x() - 10.0, r.max_y() + 10.0), Some(DrawCursor::OverlayRotate(150)));
        assert_eq!(at(r.mid_x() + 40.0, r.mid_y() + 30.0), Some(DrawCursor::Move));
    }

    #[test]
    fn drag_cursor_keeps_what_is_held() {
        let r = rect();
        let mut o = shown();
        assert_eq!(o.drag_cursor(), None);
        let corner = CGPoint::new(r.max_x(), r.max_y());
        o.mouse_down(corner, InputModifiers::NONE, r);
        assert_eq!(o.drag_cursor(), Some(DrawCursor::OverlayResize(30)));
        o.mouse_up(corner);
        o.mouse_down(CGPoint::new(r.max_x() + 10.0, r.min_y() - 10.0), InputModifiers::NONE, r);
        assert_eq!(o.drag_cursor(), Some(DrawCursor::OverlayRotate(330)));
        o.mouse_up(corner);
        o.mouse_down(CGPoint::new(r.mid_x() + 40.0, r.mid_y() + 30.0), InputModifiers::NONE, r);
        assert_eq!(o.drag_cursor(), Some(DrawCursor::ClosedHand));
        o.mouse_up(corner);
        assert_eq!(o.drag_cursor(), None);
    }

    #[test]
    fn outside_a_corner_rotates() {
        let r = rect();
        let mut o = shown();
        assert!(o.mouse_down(CGPoint::new(r.max_x() + 10.0, r.min_y() - 10.0), InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(r.max_x() + 10.0, r.min_y() + 30.0));
        let t = phases(&mut o).last().map(|e| e.1).unwrap_or(ClipTransform::IDENTITY);
        assert!(t.rotation > 0.0);
        assert!(t.position == Vec2::ZERO && t.scale == Vec2::new(1.0, 1.0));
    }

    #[test]
    fn alt_drag_on_the_picture_moves_the_anchor_only() {
        let r = rect();
        let mut o = shown();
        let start = CGPoint::new(r.mid_x() + 100.0, r.mid_y() + 50.0);
        o.mouse_down(start, InputModifiers::OPTION, r);
        o.mouse_dragged(CGPoint::new(start.x + 10.0, start.y));
        let t = phases(&mut o).last().map(|e| e.1).unwrap_or(ClipTransform::IDENTITY);
        assert!(t.anchor == Vec2::new(20.0, 0.0) && t.position == Vec2::new(20.0, 0.0));
    }

    #[test]
    fn escape_cancels_the_drag() {
        let r = rect();
        let mut o = shown();
        o.mouse_down(CGPoint::new(r.mid_x() + 100.0, r.mid_y()), InputModifiers::NONE, r);
        o.mouse_dragged(CGPoint::new(r.mid_x() + 150.0, r.mid_y()));
        assert!(o.cancel_drag());
        o.mouse_up(CGPoint::new(r.mid_x() + 150.0, r.mid_y()));
        let ev = o.take_events();
        assert_eq!(ev.iter().filter(|e| **e == OverlayEvent::DragCanceled).count(), 1);
        // no ended after the cancel
        assert!(!ev.iter().any(|e| matches!(e, OverlayEvent::Transform(Phase::Ended, _))));
        assert!(!o.cancel_drag());
    }

    #[test]
    fn presses_beside_the_layer_fall_through() {
        let r = rect();
        let mut o = shown();
        o.transform.scale = Vec2::new(0.5, 0.5);
        assert!(!o.mouse_down(CGPoint::new(r.min_x() + 20.0, r.mid_y()), InputModifiers::NONE, r));
        o.is_shown = false;
        assert!(!o.mouse_down(CGPoint::new(r.mid_x() + 50.0, r.mid_y()), InputModifiers::NONE, r));
        assert!(o.take_events().is_empty());
    }

    #[test]
    fn crop_mode_drags_an_edge_and_has_no_scale_handles() {
        let r = rect();
        let mut o = shown();
        o.crop_insets = Some(CropInsets::NONE);
        let left = CGPoint::new(r.min_x(), r.mid_y());
        assert!(o.mouse_down(left, InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(r.min_x() + 96.0, r.mid_y()));
        o.mouse_up(CGPoint::new(r.min_x() + 96.0, r.mid_y()));
        let crops: Vec<(Phase, CropEdge, f64)> = o
            .take_events()
            .into_iter()
            .filter_map(|e| if let OverlayEvent::Crop(p, ed, v) = e { Some((p, ed, v)) } else { None })
            .collect();
        assert_eq!(crops.iter().map(|c| c.0).collect::<Vec<_>>(), [Phase::Began, Phase::Changed, Phase::Ended]);
        assert_eq!(crops.last().map(|c| c.1), Some(CropEdge::Left));
        assert!((crops.last().map_or(0.0, |c| c.2) - 0.1).abs() < 1e-6);
        // A corner is no scale handle in crop mode: the press moves the picture.
        o.mouse_down(CGPoint::new(r.max_x() - 1.0, r.max_y() - 1.0), InputModifiers::NONE, r);
        o.mouse_dragged(CGPoint::new(r.max_x() + 9.0, r.max_y() - 1.0));
        let t = phases(&mut o).last().map(|e| e.1).unwrap_or(ClipTransform::IDENTITY);
        assert_eq!(t.scale, Vec2::new(1.0, 1.0));
        assert_eq!(t.position, Vec2::new(20.0, 0.0));
    }

    #[test]
    fn motion_path_key_drag_edits_that_key() {
        let r = rect();
        let mut o = shown();
        let mut ids = SequentialIds::default();
        let first = Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(-400.0, 0.0));
        let first_id = first.id;
        let mut track = KeyframeTrack::default();
        track.insert(first);
        track.insert(Keyframe::new(ids.next_id(), Time::new(1, 1), Vec2::new(400.0, 0.0)));
        o.position_track = track;
        let p = CGPoint::new(r.mid_x() - 200.0, r.mid_y());
        assert!(o.mouse_down(p, InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(p.x, p.y + 50.0));
        o.mouse_up(CGPoint::new(p.x, p.y + 50.0));
        let paths: Vec<(Phase, PathEdit)> = o
            .take_events()
            .into_iter()
            .filter_map(|e| if let OverlayEvent::PathEdit(p, e) = e { Some((p, e)) } else { None })
            .collect();
        assert_eq!(paths.iter().map(|x| x.0).collect::<Vec<_>>(), [Phase::Began, Phase::Changed, Phase::Ended]);
        assert_eq!(paths.last().map(|x| x.1.key), Some(first_id));
        assert_eq!(paths.last().and_then(|x| x.1.position), Some(Vec2::new(-400.0, 100.0)));
    }
}
