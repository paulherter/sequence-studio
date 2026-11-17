// Swift: GraphEditorDraw.swift
//! The Graph Editor on the shared toolkit: `GraphEditorView` and its toolbar translated (curves, hit test and the
//! gesture stay in `GraphEditorGeometry` / `GraphEditorGesture`; every edit goes through `EffectControlsModel`). Fills
//! the keyframe area while on: the speed curves of the selected rows in one plot, keys as small squares, handles of
//! selected keys, the hover readout, and the bottom toolbar (Fit | Snap | Steady, Smooth, Smooth In, Smooth Out | Hold,
//! Hold Ahead). Coordinates: points, y down, (0, 0) = the area's top-left.

use sq_core_model::keyframes_editing::SummaryMember;
use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
use sq_core_time::ease_names::ease_name;
use sq_draw::draw_list::Color;
use sq_draw::scroll::ScrollGesture;
use sq_draw::theme::type_size;
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, InspectorTokens, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;

use super::{draw_marquee, text_at, text_in};
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::ec::inspector_text_formats::ControlsNumberText;
use crate::ec::key_tools::GraphHandleReadout;
use crate::keyframes::graph_editor_geometry::{
    GraphEditorAction, GraphEditorCurve, GraphEditorGeometry, GraphEditorGesture, GraphEditorGestureKind,
    GraphEditorHit,
};
use crate::keyframes::graph_editor_shortcuts::GraphEditorShortcut;
use crate::keyframes::keyframe_zoom_input::{KeyframeScroll, KeyframeZoomInput};

struct CurveCache {
    revision: u64,
    properties: Vec<EffectProperty>,
    samples: usize,
    curves: Vec<GraphEditorCurve>,
}

/// The Graph Editor.
pub struct GraphEditorDraw {
    /// Size of the area in points.
    pub size: CGSize,
    gesture: Option<GraphEditorGesture>,
    marquee: Option<CGRect>,
    escape_cancelled: bool,
    hover_point: Option<CGPoint>,
    toolbar_hover: Option<usize>,
    cache: Option<CurveCache>,
}

impl Default for GraphEditorDraw {
    fn default() -> Self {
        Self::new()
    }
}

/// Fit, Snap, then the six eases; a gap before the groups at 1, 2, 5 and 6 (the Mac layout).
pub const EASE_CHOICES: [(KeyInterpolationChoice, &str); 6] = [
    (KeyInterpolationChoice::Linear, ease_name::STEADY),
    (KeyInterpolationChoice::EasyEase, ease_name::SMOOTH),
    (KeyInterpolationChoice::EaseIn, ease_name::SMOOTH_IN),
    (KeyInterpolationChoice::EaseOut, ease_name::SMOOTH_OUT),
    (KeyInterpolationChoice::Hold, ease_name::HOLD),
    (KeyInterpolationChoice::HoldAhead, ease_name::HOLD_AHEAD),
];
const GROUP_STARTS: [usize; 4] = [1, 2, 5, 6];
const TOOLBAR_SLOT: f64 = 26.0;

impl GraphEditorDraw {
    /// An editor without a size.
    pub fn new() -> GraphEditorDraw {
        GraphEditorDraw {
            size: CGSize::default(),
            gesture: None,
            marquee: None,
            escape_cancelled: false,
            hover_point: None,
            toolbar_hover: None,
            cache: None,
        }
    }

    /// The marquee rectangle while one is dragged.
    pub fn marquee(&self) -> Option<CGRect> {
        self.marquee
    }

    // MARK: Curves

    /// Sampled again only when the clip, the drawn properties or the zoom's sample count change (as the Mac cache).
    pub fn curves(&mut self, model: &EffectControlsModel) -> Vec<GraphEditorCurve> {
        let n = model.graph_sample_count(model.lane_geometry(self.size.width).points_per_second());
        let props = model.graph_editor_properties();
        if let Some(c) = &self.cache
            && c.revision == model.clip_revision()
            && c.properties == props
            && c.samples == n
        {
            return c.curves.clone();
        }
        let v = model.graph_editor_curves(n);
        self.cache =
            Some(CurveCache { revision: model.clip_revision(), properties: props, samples: n, curves: v.clone() });
        v
    }

    /// Live geometry; while a drag runs the axis only grows.
    pub fn geometry(&mut self, model: &EffectControlsModel) -> GraphEditorGeometry {
        let curves = self.curves(model);
        let g = GraphEditorGeometry::new(model.lane_geometry(self.size.width), self.size.height, curves);
        match &self.gesture {
            Some(gs) => g.growing(&gs.geometry),
            None => g,
        }
    }

    // MARK: Drawing

    /// Draws the editor.
    pub fn draw(&mut self, model: &EffectControlsModel, c: &mut Canvas, t: &DrawTheme) {
        let g = self.geometry(model);
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        let sel = model.selection();
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.lane());
        for s in g.time_ticks(90.0) {
            c.fill(
                CGRect::new(g.lane.x_seconds(s).round(), g.plot_top(), 1.0, g.plot_bottom() - g.plot_top()),
                t.separator(),
            );
        }
        let fs = type_size::CAPTION as f64;
        for v in g.speed_ticks() {
            let y = g.y(v).round();
            c.fill(CGRect::new(0.0, y, self.size.width, 1.0), t.separator());
            let label = format!("{}\u{00D7}", ControlsNumberText::format(v, if v.round() == v { 0 } else { 1 }));
            text_at(c, &label, CGPoint::new(4.0, y + 1.0), fs, t.label3());
        }
        if model.playhead_in_clip() {
            let x = model.lane_geometry(self.size.width).x(model.local_playhead()).round();
            c.fill(
                CGRect::new(x - 1.0, 0.0, 2.0, (self.size.height - GraphEditorGeometry::BOTTOM_INSET).max(0.0)),
                t.playhead(),
            );
        }
        c.fill(CGRect::new(0.0, g.plot_bottom().round(), self.size.width, 1.0), t.label3());
        let palette = t.graph_curve();
        for cv in &g.curves {
            let color = palette[cv.color_index % palette.len()];
            for line in g.polylines(cv) {
                c.stroke_polyline(&line, 1.5, color);
            }
        }
        for cv in &g.curves {
            for h in &cv.curve.handles {
                if !sel.contains(&SummaryMember::new(cv.property.clone(), h.key_id)) {
                    continue;
                }
                let Some(k) = cv.curve.keys.iter().find(|k| k.id == h.key_id) else { continue };
                let Some(hp) = g.handle_point(cv, h) else { continue };
                c.stroke_line(g.key_point(cv, k), hp, 1.0, t.yellow());
                c.fill_ellipse(CGRect::new(hp.x - 3.0, hp.y - 3.0, 6.0, 6.0), t.yellow());
            }
        }
        // Plain keys: lane-colored square with a white outline; selected keys: solid white.
        for cv in &g.curves {
            for k in &cv.curve.keys {
                let kp = g.key_point(cv, k);
                let r = CGRect::new(kp.x - 3.5, kp.y - 3.5, 7.0, 7.0);
                if sel.contains(&SummaryMember::new(cv.property.clone(), k.id)) {
                    c.fill(r, Color::WHITE);
                } else {
                    c.fill(r, Color::WHITE);
                    c.fill(r.inset_by(1.0, 1.0), t.lane());
                }
            }
        }
        if g.curves.is_empty() {
            let text = SQL10n::string(if model.graph_show_all {
                "No animated properties"
            } else {
                "Select properties on the left to show their speed"
            });
            text_in(
                c,
                &text,
                CGRect::new(0.0, (g.plot_top() + g.plot_bottom()) / 2.0 - 8.0, self.size.width, 16.0),
                type_size::BODY as f64,
                t.label3(),
                TextAlign::Center,
            );
        }
        if let Some(m) = self.marquee {
            draw_marquee(c, m, t);
        }
        if let Some((at, text)) = self.readout(model, &g) {
            self.draw_readout(c, t, at, &text);
        }
        self.draw_toolbar(model, c, t);
        c.restore_gstate();
    }

    /// The handle readout while dragging or hovering a handle, else the speed of the hovered curve.
    pub fn readout(&self, model: &EffectControlsModel, g: &GraphEditorGeometry) -> Option<(CGPoint, String)> {
        if let Some(gs) = &self.gesture
            && gs.moved()
            && let GraphEditorGestureKind::Handle(m, side) = &gs.kind
            && let Some(c) = g.curve(&m.property)
            && let Some(h) = c.curve.handles.iter().find(|h| h.key_id == m.key_id && h.side == *side)
            && let Some(hp) = g.handle_point(c, h)
        {
            return Some((hp, GraphHandleReadout::text(&c.title, h.speed.abs(), h.influence, &c.unit)));
        }
        let p = self.hover_point?;
        if self.gesture.is_some() || p.y >= self.size.height - GraphEditorGeometry::TOOLBAR_HEIGHT {
            return None;
        }
        if let GraphEditorHit::Handle(m, side) = g.hit_test(p, model.selection())
            && let Some(c) = g.curve(&m.property)
            && let Some(h) = c.curve.handles.iter().find(|h| h.key_id == m.key_id && h.side == side)
        {
            return Some((p, GraphHandleReadout::text(&c.title, h.speed * c.scale, h.influence, &c.unit)));
        }
        if let Some(hit) = g.hover(p)
            && let Some(c) = g.curve(&hit.property)
        {
            let name = model.clip().map_or("Clip".to_string(), |c| c.name.clone());
            return Some((
                p,
                format!("{name} \u{00B7} {}\n{} {}/s", c.title, ControlsNumberText::format(hit.speed, 2), c.unit),
            ));
        }
        None
    }

    fn draw_readout(&self, c: &mut Canvas, t: &DrawTheme, p: CGPoint, text: &str) {
        let fs = type_size::CAPTION as f64;
        let lines: Vec<&str> = text.split('\n').filter(|l| !l.is_empty()).collect();
        let w = lines.iter().map(|l| c.size_of(l, fs, 0).width).fold(0.0, f64::max);
        let lh = 14.0;
        let n = lines.len() as f64;
        let mut r = CGRect::new(p.x + 10.0, p.y - n * lh - 14.0, w + 10.0, n * lh + 6.0);
        if r.max_x() > self.size.width {
            r.x = p.x - r.width - 10.0;
        }
        if r.min_y() < 0.0 {
            r.y = p.y + 12.0;
        }
        let radius = InspectorTokens::CONTROL_RADIUS;
        c.fill_rounded(r, radius, t.overlay());
        c.stroke_rounded(r, radius, 0.5, t.ink_fill(0.14));
        for (i, l) in lines.iter().enumerate() {
            text_in(
                c,
                l,
                CGRect::new(r.min_x() + 5.0, r.min_y() + 3.0 + i as f64 * lh, w + 2.0, lh),
                fs,
                t.label(),
                TextAlign::Left,
            );
        }
    }

    // MARK: Toolbar (GraphEditorToolbar)

    /// Frames of the eight toolbar buttons, centered in the bottom strip.
    pub fn toolbar_frames(&self) -> Vec<CGRect> {
        let h = GraphEditorGeometry::TOOLBAR_HEIGHT;
        let gap = 12.0;
        let n = 2 + EASE_CHOICES.len();
        let total = n as f64 * TOOLBAR_SLOT + GROUP_STARTS.len() as f64 * gap;
        let mut x = ((self.size.width - total) / 2.0).max(4.0);
        (0..n)
            .map(|i| {
                if GROUP_STARTS.contains(&i) {
                    x += gap;
                }
                let r = CGRect::new(x, self.size.height - h + 2.0, TOOLBAR_SLOT, h - 4.0);
                x += TOOLBAR_SLOT;
                r
            })
            .collect()
    }

    fn toolbar_enabled(&self, model: &EffectControlsModel, i: usize) -> bool {
        if i < 2 {
            return true;
        }
        let has_keys = !model.selection().is_empty();
        if i == 1 + EASE_CHOICES.len() { has_keys && model.selection_takes_hold_ahead() } else { has_keys }
    }

    /// The tooltip of toolbar button `i`.
    pub fn toolbar_title(i: usize) -> &'static str {
        match i {
            0 => "Fit",
            1 => "Snap",
            _ => EASE_CHOICES[i - 2].1,
        }
    }

    fn run_toolbar(&self, model: &mut EffectControlsModel, i: usize) {
        if !self.toolbar_enabled(model, i) {
            return;
        }
        match i {
            0 => model.fit_graph_default(),
            1 => model.graph_snap = !model.graph_snap,
            _ => model.apply_graph_ease(EASE_CHOICES[i - 2].0),
        }
    }

    fn draw_toolbar(&self, model: &EffectControlsModel, c: &mut Canvas, t: &DrawTheme) {
        let h = GraphEditorGeometry::TOOLBAR_HEIGHT;
        c.fill(CGRect::new(0.0, self.size.height - h, self.size.width, h), t.panel());
        c.fill(CGRect::new(0.0, self.size.height - h, self.size.width, 1.0), t.separator());
        for (i, f) in self.toolbar_frames().iter().enumerate() {
            let on = self.toolbar_enabled(model, i);
            if self.toolbar_hover == Some(i) && on {
                c.fill_rounded(*f, InspectorTokens::CONTROL_RADIUS, t.fill_hover());
            }
            let mut tint = if i == 1 && model.graph_snap {
                t.accent()
            } else if self.toolbar_hover == Some(i) {
                t.label()
            } else {
                t.label2()
            };
            if !on {
                tint = tint.with_alpha(InspectorTokens::DISABLED_ALPHA);
            }
            let at = CGPoint::new((f.mid_x() - 7.0).round(), (f.mid_y() - 7.0).round());
            match i {
                0 => c.draw_icon(SQIcon::MoveHorizontal, at, 14.0, tint, None),
                1 => c.draw_icon(SQIcon::Snap, at, 14.0, tint, None),
                _ => Self::ease_glyph(
                    c,
                    EASE_CHOICES[i - 2].0,
                    CGRect::new(f.mid_x() - 8.0, f.mid_y() - 6.0, 16.0, 12.0),
                    tint,
                ),
            }
        }
    }

    /// The small curve glyph of an ease button (value over time: step, line, S-curves), y down.
    pub fn ease_glyph(c: &mut Canvas, choice: KeyInterpolationChoice, r: CGRect, color: Color) {
        let a = CGPoint::new(r.min_x() + 1.5, r.max_y() - 1.5);
        let b = CGPoint::new(r.max_x() - 1.5, r.min_y() + 1.5);
        let w = b.x - a.x;
        let bezier = |c1: CGPoint, c2: CGPoint| -> Vec<CGPoint> {
            (0..=16)
                .map(|i| {
                    let s = i as f64 / 16.0;
                    let u = 1.0 - s;
                    CGPoint::new(
                        u * u * u * a.x + 3.0 * u * u * s * c1.x + 3.0 * u * s * s * c2.x + s * s * s * b.x,
                        u * u * u * a.y + 3.0 * u * u * s * c1.y + 3.0 * u * s * s * c2.y + s * s * s * b.y,
                    )
                })
                .collect()
        };
        let line = match choice {
            KeyInterpolationChoice::Hold => vec![a, CGPoint::new(b.x - 2.0, a.y), CGPoint::new(b.x - 2.0, b.y), b],
            KeyInterpolationChoice::HoldAhead => vec![a, CGPoint::new(a.x + 2.0, a.y), CGPoint::new(a.x + 2.0, b.y), b],
            KeyInterpolationChoice::Linear => vec![a, b],
            KeyInterpolationChoice::EasyEase => {
                bezier(CGPoint::new(a.x + w * 0.6, a.y), CGPoint::new(b.x - w * 0.6, b.y))
            }
            KeyInterpolationChoice::EaseIn => {
                bezier(CGPoint::new(a.x + w * 0.3, a.y - 3.0), CGPoint::new(b.x - w * 0.6, b.y))
            }
            _ => bezier(CGPoint::new(a.x + w * 0.6, a.y), CGPoint::new(b.x - w * 0.3, b.y + 3.0)),
        };
        c.stroke_polyline(&line, 1.3, color);
        for q in [a, b] {
            c.fill(CGRect::new(q.x - 1.5, q.y - 1.5, 3.0, 3.0), color);
        }
    }

    // MARK: Input

    fn toolbar_index(&self, p: CGPoint) -> Option<usize> {
        self.toolbar_frames().iter().position(|f| f.contains(p))
    }

    /// The tooltip at `p`.
    pub fn help(&self, p: CGPoint) -> Option<&'static str> {
        self.toolbar_index(p).map(Self::toolbar_title)
    }

    /// The pointer moved over the editor (`None`: it left).
    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover_point = p;
        self.toolbar_hover = p.and_then(|p| self.toolbar_index(p));
    }

    /// Press at `p`.
    pub fn mouse_down(&mut self, model: &mut EffectControlsModel, p: CGPoint, modifiers: InputModifiers) {
        self.escape_cancelled = false;
        if p.y >= self.size.height - GraphEditorGeometry::TOOLBAR_HEIGHT {
            if let Some(i) = self.toolbar_index(p) {
                self.run_toolbar(model, i);
            }
            return;
        }
        let g = GraphEditorGesture::new(
            p,
            modifiers.contains(InputModifiers::SHIFT),
            self.geometry(model),
            model.selection().clone(),
        );
        let sel = g.selection().clone();
        self.gesture = Some(g);
        if &sel != model.selection() {
            model.select(&sel.into_iter().collect::<Vec<_>>(), false);
        }
    }

    /// Drag to `p`.
    /// A drag is one undo step however many events it has (`begin_gesture` .. `end_gesture`, test
    /// `a_graph_drag_is_one_undo_step`); only Swift's one-commit-per-frame `LiveDragCoalescer` is not ported (speed only).
    pub fn mouse_dragged(&mut self, model: &mut EffectControlsModel, p: CGPoint, modifiers: InputModifiers) {
        if self.escape_cancelled {
            return;
        }
        let Some(g) = self.gesture.as_mut() else { return };
        let was_moved = g.moved();
        let action = g.drag(p, modifiers.contains(InputModifiers::SHIFT));
        let moved = g.moved();
        let kind = g.kind.clone();
        let pps = g.geometry.lane.points_per_second();
        if moved && !was_moved && matches!(kind, GraphEditorGestureKind::Keys | GraphEditorGestureKind::Handle(..)) {
            model.begin_gesture();
        }
        match action {
            GraphEditorAction::MoveKeys { seconds } => {
                let tol = if modifiers.contains(InputModifiers::COMMAND) { None } else { Some(6.0 / pps.max(1e-9)) }; // Ctrl: no snapping
                model.move_graph_selection(seconds, tol);
            }
            GraphEditorAction::SetHandle(h, side) => model.set_graph_handle(h, side),
            GraphEditorAction::Select { members, marquee } => {
                self.marquee = marquee.map(|r| CGRect::new(r.x, r.y, r.width, r.height));
                if &members != model.selection() {
                    model.select(&members.into_iter().collect::<Vec<_>>(), false);
                }
            }
            GraphEditorAction::Nothing => {}
        }
    }

    /// Release at `p`.
    pub fn mouse_up(&mut self, model: &mut EffectControlsModel, p: CGPoint) {
        let g = self.gesture.take();
        self.marquee = None;
        self.mouse_moved(Some(p));
        if self.escape_cancelled {
            self.escape_cancelled = false;
            return;
        }
        let Some(g) = g else { return };
        if g.moved() {
            match g.kind {
                GraphEditorGestureKind::Keys => model.end_graph_key_move(),
                GraphEditorGestureKind::Handle(..) => model.end_gesture(),
                _ => {}
            }
        } else {
            let s = g.end_selection();
            if &s != model.selection() {
                model.select(&s.into_iter().collect::<Vec<_>>(), false);
            }
        }
    }

    /// True while a gesture runs.
    pub fn is_dragging(&self) -> bool {
        self.gesture.is_some()
    }

    /// Escape drops a marquee or undoes a running drag; F / Shift-F / Ctrl-A / F9 run the editor's commands; + / - / \
    /// zoom; Delete removes the selected keys.
    pub fn key(&mut self, model: &mut EffectControlsModel, k: InputKey, modifiers: InputModifiers) -> bool {
        if k == InputKey::Escape
            && let Some(g) = self.gesture.take()
        {
            if matches!(g.kind, GraphEditorGestureKind::Marquee { .. }) {
                if &g.base_selection != model.selection() {
                    model.select(&g.base_selection.iter().cloned().collect::<Vec<_>>(), false);
                }
            } else if g.moved() {
                match g.kind {
                    GraphEditorGestureKind::Keys => {
                        let _ = model.move_selection(sq_core_time::Time::ZERO, false);
                        model.end_graph_key_move();
                    }
                    GraphEditorGestureKind::Handle(..) => model.cancel_gesture(),
                    _ => {}
                }
            }
            self.marquee = None;
            self.escape_cancelled = true;
            return true;
        }
        if let Some(sc) = GraphEditorShortcut::resolve(k, modifiers) {
            model.perform(sc);
            return true;
        }
        if KeyframeZoomInput::key(k, modifiers, model) {
            return true;
        }
        if k == InputKey::Delete || k == InputKey::Backspace {
            model.delete_selection_or_effect();
            return true;
        }
        false
    }

    /// Wheel: Option / Ctrl zooms around the pointer, horizontal pans.
    pub fn scroll(
        &self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        dx: f64,
        dy: f64,
        modifiers: InputModifiers,
        published: Option<&ScrollGesture>,
    ) -> bool {
        let lane = model.lane_geometry(self.size.width);
        match KeyframeZoomInput::classify(dx, dy, modifiers, published) {
            KeyframeScroll::Zoom { factor } => {
                model.zoom(factor, Some(lane.seconds(p.x)));
                true
            }
            KeyframeScroll::Pan { points } => {
                model.pan_viewport(-points / lane.points_per_second().max(1e-6));
                true
            }
            KeyframeScroll::None => false,
        }
    }

    /// Right click: selects the key under the pointer. Returns whether the menu is for a key (the lanes' key menu follows).
    pub fn context_menu(&mut self, model: &mut EffectControlsModel, p: CGPoint) -> bool {
        let hit = self.geometry(model).hit_test(p, model.selection());
        let mut on_key = false;
        if let GraphEditorHit::Key(m) = &hit {
            on_key = true;
            if !model.selection().contains(m) {
                model.select(std::slice::from_ref(m), false);
            }
        }
        if matches!(hit, GraphEditorHit::Handle(..)) {
            on_key = true;
        }
        on_key
    }
}
