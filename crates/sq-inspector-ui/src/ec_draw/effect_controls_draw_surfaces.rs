// Swift: EffectControlsDrawSurfaces.swift
//! The drawn editors of Effect Controls rows (curves, EQ curve, speed graph), translated from their Mac views.

use sq_audiofx::parametric_eqresponse::ParametricEQResponse;
use sq_core_audio::audio_effects::AudioParametricEQValues;
use sq_core_model::{CurvePoint, curve_math};
use sq_core_time::Id;
use sq_draw::scroll::ScrollGesture;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, DrawTheme, InputModifiers, InspectorTokens, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::localization::SQL10n;

use super::text_in;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::eq_curve::EQCurveGeometry;

/// Which editor a surface widget hosts.
#[derive(Clone, Debug, PartialEq)]
pub enum SurfaceKind {
    /// ColorCurvesRow.
    Curves(Id),
    /// EQCurveView.
    EqCurve(Id),
}

impl SurfaceKind {
    /// A fresh editor of this kind.
    pub fn make(&self) -> Box<dyn DrawSurface> {
        match self {
            SurfaceKind::Curves(effect) => Box::new(ColorCurvesSurface::new(*effect)),
            SurfaceKind::EqCurve(effect) => Box::new(EqCurveSurface::new(*effect)),
        }
    }
}

/// A drawn editor inside a row (curves, EQ curve): draws itself and takes the pointer while pressed. Points are row
/// coordinates; `rect` is the surface's frame in the row.
pub trait DrawSurface {
    /// Draws the editor in `rect`.
    fn draw(&self, model: &EffectControlsModel, c: &mut Canvas, rect: CGRect, t: &DrawTheme);
    /// A press.
    fn mouse_down(
        &mut self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        rect: CGRect,
        click_count: i64,
        modifiers: InputModifiers,
    );
    /// A drag.
    fn mouse_dragged(&mut self, model: &mut EffectControlsModel, p: CGPoint, rect: CGRect, modifiers: InputModifiers);
    /// A release.
    fn mouse_up(&mut self, model: &mut EffectControlsModel, p: CGPoint, rect: CGRect);
    /// The pointer moved over the editor (`None`: it left).
    fn mouse_moved(&mut self, _model: &mut EffectControlsModel, _p: Option<CGPoint>, _rect: CGRect) {}
    /// The tooltip at `p`.
    fn help(&self, _p: CGPoint, _rect: CGRect) -> Option<String> {
        None
    }
    /// Wheel over the surface; true when it used it (otherwise the panel scrolls).
    fn scroll(
        &mut self,
        _model: &mut EffectControlsModel,
        _p: CGPoint,
        _rect: CGRect,
        _dy: f64,
        _gesture: Option<&ScrollGesture>,
    ) -> bool {
        false
    }
}

/// Pure point editing for one curve (x ascending, 0...1). Interior points keep a minimum gap to their neighbors; the end
/// points only move vertically.
// shortcut: a copy of the Color area's `CurveEditing` (Color/CurveEditing.swift is the color worker's file); replace it with
// theirs once `color/` is merged.
struct CurveEditing;

impl CurveEditing {
    const MIN_GAP: f32 = 0.01;
    const HIT_RADIUS: f64 = 8.0;

    fn add(pts: &[CurvePoint], x: f32, y: f32) -> (Vec<CurvePoint>, usize) {
        let mut p = pts.to_vec();
        let cx = x.clamp(0.0, 1.0);
        let cy = y.clamp(0.0, 1.0);
        let i = p.iter().position(|q| q.x > cx).unwrap_or(p.len());
        p.insert(i, CurvePoint { x: cx, y: cy });
        (p, i)
    }

    fn move_point(pts: &[CurvePoint], i: usize, x: f32, y: f32) -> Vec<CurvePoint> {
        if i >= pts.len() {
            return pts.to_vec();
        }
        let mut p = pts.to_vec();
        let cy = y.clamp(0.0, 1.0);
        if i == 0 || i == p.len() - 1 {
            p[i].y = cy;
        } else {
            let lo = p[i - 1].x + Self::MIN_GAP;
            let hi = p[i + 1].x - Self::MIN_GAP;
            p[i] = CurvePoint { x: x.max(lo).min(lo.max(hi)), y: cy };
        }
        p
    }

    fn remove(pts: &[CurvePoint], i: usize) -> Vec<CurvePoint> {
        if pts.len() <= 2 || i == 0 || i >= pts.len() - 1 {
            return pts.to_vec();
        }
        let mut p = pts.to_vec();
        p.remove(i);
        p
    }

    fn hit(pts: &[CurvePoint], x: f64, y: f64, size: CGSize) -> Option<usize> {
        let mut best: Option<(usize, f64)> = None;
        for (i, q) in pts.iter().enumerate() {
            let d = (f64::from(q.x) * size.width - x).hypot((1.0 - f64::from(q.y)) * size.height - y);
            if d <= Self::HIT_RADIUS && best.is_none_or(|b| d < b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| b.0)
    }
}

/// ColorCurvesRow (ChannelDots + CurveEditorView) on the canvas: pick a channel, click to add a point, drag to move,
/// double-click or Cmd-click to remove it, Shift locks x. One drag = one gesture on the model.
pub struct ColorCurvesSurface {
    effect: Id,
    channel: usize,
    drag_index: Option<usize>,
    hover_index: Option<usize>,
    /// The points shown: an edit shows at once (CurveEditorView.edit), the model write follows.
    shown: Option<Vec<CurvePoint>>,
}

impl ColorCurvesSurface {
    const DOT: f64 = 9.0;
    const DOT_GAP: f64 = 10.0;
    const NAMES: [&'static str; 4] = ["Master", "Red", "Green", "Blue"];

    /// An editor for the curves of `effect`.
    pub fn new(effect: Id) -> ColorCurvesSurface {
        ColorCurvesSurface { effect, channel: 0, drag_index: None, hover_index: None, shown: None }
    }

    /// The channel being edited (0 master, 1 red, 2 green, 3 blue).
    pub fn channel(&self) -> usize {
        self.channel
    }

    fn points(&self, model: &EffectControlsModel) -> Vec<CurvePoint> {
        if let Some(s) = &self.shown {
            return s.clone();
        }
        let c = model.color_curves(self.effect);
        match self.channel {
            1 => c.red,
            2 => c.green,
            3 => c.blue,
            _ => c.master,
        }
    }

    // MARK: Layout (ColorCurvesRow.layout, ChannelDots.rect, CurveEditorView.plot)

    fn dots_frame(rect: CGRect) -> CGRect {
        let dw = 4.0 * Self::DOT + 3.0 * Self::DOT_GAP + 10.0;
        CGRect::new(
            rect.min_x() + ((rect.width - dw) / 2.0).max(ControlsGrid::TOGGLE_X),
            rect.min_y(),
            dw,
            ControlsGrid::ROW_HEIGHT,
        )
    }

    fn dot_rect(i: usize, rect: CGRect) -> CGRect {
        let f = Self::dots_frame(rect);
        let total = 4.0 * Self::DOT + 3.0 * Self::DOT_GAP;
        let x0 = (f.min_x() + (f.width - total) / 2.0).round();
        CGRect::new(x0 + i as f64 * (Self::DOT + Self::DOT_GAP), f.min_y() + 6.0, Self::DOT, Self::DOT)
    }

    /// The plot inside the surface.
    pub fn plot(rect: CGRect) -> CGRect {
        let top = ControlsGrid::ROW_HEIGHT;
        let editor = CGRect::new(
            rect.min_x() + ControlsGrid::LABEL_X,
            rect.min_y() + top,
            (rect.width - ControlsGrid::LABEL_X - ControlsGrid::TRAILING).max(40.0),
            (rect.height - top - ControlsGrid::GAP).max(40.0),
        );
        editor.inset_by(6.0, 6.0)
    }

    fn to_data(p: CGPoint, r: CGRect) -> (f32, f32) {
        (((p.x - r.min_x()) / r.width.max(1.0)) as f32, (1.0 - (p.y - r.min_y()) / r.height.max(1.0)) as f32)
    }

    fn to_view(q: CurvePoint, r: CGRect) -> CGPoint {
        CGPoint::new(r.min_x() + f64::from(q.x) * r.width, r.min_y() + (1.0 - f64::from(q.y)) * r.height)
    }

    fn point_index(&self, model: &EffectControlsModel, p: CGPoint, r: CGRect) -> Option<usize> {
        CurveEditing::hit(&self.points(model), p.x - r.min_x(), p.y - r.min_y(), CGSize::new(r.width, r.height))
    }

    fn dot_at(p: CGPoint, rect: CGRect) -> Option<usize> {
        (0..4).find(|&i| Self::dot_rect(i, rect).inset_by(-Self::DOT_GAP / 2.0, -6.0).contains(p))
    }

    fn edit(&mut self, model: &mut EffectControlsModel, new: Vec<CurvePoint>) {
        self.shown = Some(new.clone());
        let mut c = model.color_curves(self.effect);
        match self.channel {
            1 => c.red = new,
            2 => c.green = new,
            3 => c.blue = new,
            _ => c.master = new,
        }
        model.set_color_curves(self.effect, c);
    }
}

impl DrawSurface for ColorCurvesSurface {
    fn draw(&self, model: &EffectControlsModel, c: &mut Canvas, rect: CGRect, t: &DrawTheme) {
        let colors = t.channel_dots();
        for (i, col) in colors.iter().enumerate() {
            let d = Self::dot_rect(i, rect);
            c.fill_ellipse(d, *col);
            if i == self.channel {
                c.stroke_ellipse(d.inset_by(-2.5, -2.5), 1.0, t.label());
            }
        }
        let r = Self::plot(rect);
        c.fill_rounded(r, radius::SMALL as f64, t.field());
        for i in 1..4 {
            let f = i as f64 / 4.0;
            c.stroke_line(
                CGPoint::new(r.min_x() + f * r.width, r.min_y()),
                CGPoint::new(r.min_x() + f * r.width, r.max_y()),
                0.5,
                t.field_edge(),
            );
            c.stroke_line(
                CGPoint::new(r.min_x(), r.min_y() + f * r.height),
                CGPoint::new(r.max_x(), r.min_y() + f * r.height),
                0.5,
                t.field_edge(),
            );
        }
        c.stroke_line(CGPoint::new(r.min_x(), r.max_y()), CGPoint::new(r.max_x(), r.min_y()), 0.5, t.field_edge());
        let pts = self.points(model);
        let spline = curve_math::Spline::new(curve_math::normalized(&pts));
        let n = 96;
        let line: Vec<CGPoint> = (0..=n)
            .map(|i| {
                let x = i as f32 / n as f32;
                Self::to_view(CurvePoint { x, y: spline.value(x) }, r)
            })
            .collect();
        let line_color = match self.channel {
            1 => t.red(),
            2 => t.green(),
            3 => t.channel_blue(),
            _ => t.label(),
        };
        c.stroke_polyline(&line, 1.5, line_color);
        for (i, q) in pts.iter().enumerate() {
            let p = Self::to_view(*q, r);
            let dot = CGRect::new(p.x - 3.5, p.y - 3.5, 7.0, 7.0);
            let fill = if Some(i) == self.drag_index {
                t.accent()
            } else if Some(i) == self.hover_index {
                t.accent_fill()
            } else {
                t.label()
            };
            c.fill_ellipse(dot, fill);
            c.stroke_ellipse(dot, 1.0, t.handle_shadow());
        }
    }

    fn mouse_down(
        &mut self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        rect: CGRect,
        click_count: i64,
        modifiers: InputModifiers,
    ) {
        if let Some(i) = Self::dot_at(p, rect) {
            self.channel = i;
            self.shown = None;
            return;
        }
        let r = Self::plot(rect);
        if !r.inset_by(-6.0, -6.0).contains(p) {
            return;
        }
        let hit = self.point_index(model, p, r);
        if click_count == 2 || (modifiers.contains(InputModifiers::COMMAND) && hit.is_some()) {
            model.begin_gesture();
            if let Some(hit) = hit {
                let pts = CurveEditing::remove(&self.points(model), hit);
                self.edit(model, pts);
            }
            model.end_gesture();
            self.shown = None;
            return;
        }
        model.begin_gesture();
        let (x, y) = Self::to_data(p, r);
        if let Some(hit) = hit {
            self.drag_index = Some(hit);
        } else {
            let (pts, index) = CurveEditing::add(&self.points(model), x, y);
            self.drag_index = Some(index);
            self.edit(model, pts);
        }
    }

    fn mouse_dragged(&mut self, model: &mut EffectControlsModel, p: CGPoint, rect: CGRect, modifiers: InputModifiers) {
        let Some(i) = self.drag_index else { return };
        let (mut x, y) = Self::to_data(p, Self::plot(rect));
        let pts = self.points(model);
        if modifiers.contains(InputModifiers::SHIFT) && i < pts.len() {
            x = pts[i].x; // Shift locks x
        }
        let moved = CurveEditing::move_point(&pts, i, x, y);
        self.edit(model, moved);
    }

    fn mouse_up(&mut self, model: &mut EffectControlsModel, p: CGPoint, rect: CGRect) {
        if self.drag_index.take().is_some() {
            model.end_gesture();
        }
        self.shown = None;
        self.hover_index = self.point_index(model, p, Self::plot(rect));
    }

    fn mouse_moved(&mut self, model: &mut EffectControlsModel, p: Option<CGPoint>, rect: CGRect) {
        self.hover_index = p.and_then(|p| self.point_index(model, p, Self::plot(rect)));
    }

    fn help(&self, p: CGPoint, rect: CGRect) -> Option<String> {
        Self::dot_at(p, rect).map(|i| SQL10n::string(Self::NAMES[i]))
    }
}

/// EQCurveView on the canvas: the combined response of the Parametric EQ with one point per band. Drag = frequency and
/// gain, Option-drag or scroll = Q, double-click resets the band; one drag or scroll = one gesture on the model.
pub struct EqCurveSurface {
    effect: Id,
    drag_filter: Option<usize>,
    drag_start: Option<(CGPoint, f64)>,
    q_drag: bool,
    scrolling: Option<(usize, f64, f64)>,
}

impl EqCurveSurface {
    const HANDLE_RADIUS: f64 = 6.0;
    const HIT_RADIUS: f64 = 12.0;
    const LABEL_BAND: f64 = 16.0;

    /// An editor for the EQ of `effect`.
    pub fn new(effect: Id) -> EqCurveSurface {
        EqCurveSurface { effect, drag_filter: None, drag_start: None, q_drag: false, scrolling: None }
    }

    /// The band being dragged.
    pub fn drag_filter(&self) -> Option<usize> {
        self.drag_filter
    }

    /// The geometry of the plot in `rect`.
    pub fn geometry(rect: CGRect) -> EQCurveGeometry {
        EQCurveGeometry::new(CGRect::new(
            rect.min_x(),
            rect.min_y(),
            rect.width,
            (rect.height - Self::LABEL_BAND).max(1.0),
        ))
    }

    /// Where band `i` sits.
    pub fn point_position(i: usize, v: &AudioParametricEQValues, g: &EQCurveGeometry) -> CGPoint {
        let b = v.band(i);
        let db = if i == 0 || i == 8 { ParametricEQResponse::total_db(v, b.hz) } else { b.gain_db };
        CGPoint::new(g.x(b.hz), g.y(db))
    }

    /// The band whose point is under `p`.
    pub fn filter_at(&self, model: &EffectControlsModel, p: CGPoint, rect: CGRect) -> Option<usize> {
        let v = model.eq_values(self.effect)?;
        let g = Self::geometry(rect);
        let mut best: Option<(usize, f64)> = None;
        for i in 0..AudioParametricEQValues::BAND_COUNT {
            if !v.band(i).on {
                continue;
            }
            let c = Self::point_position(i, &v, &g);
            let d = (c.x - p.x).hypot(c.y - p.y);
            if d <= Self::HIT_RADIUS && best.is_none_or(|b| d < b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| b.0)
    }

    /// One scroll gesture = one begin / end pair; Q accumulates from the Q at its start.
    // shortcut: the gesture ends when the pointer leaves the curve or presses (no idle timer in the portable panel);
    // upgrade with a host clock tick.
    pub fn end_scroll(&mut self, model: &mut EffectControlsModel) {
        if self.scrolling.take().is_some() {
            model.end_gesture();
        }
    }
}

impl DrawSurface for EqCurveSurface {
    fn draw(&self, model: &EffectControlsModel, c: &mut Canvas, rect: CGRect, t: &DrawTheme) {
        let g = Self::geometry(rect);
        let plot = g.plot;
        c.fill_rounded(plot, InspectorTokens::CONTROL_RADIUS, t.field());
        c.save_gstate();
        c.clip_to(plot);
        for hz in EQCurveGeometry::GRID_HZ {
            let decade = EQCurveGeometry::DECADE_HZ.contains(&hz);
            let s = t.separator();
            c.fill(
                CGRect::new(g.x(hz), plot.min_y(), 1.0, plot.height),
                if decade { s } else { s.with_alpha(s.a * InspectorTokens::DISABLED_ALPHA) },
            );
        }
        for db in EQCurveGeometry::GRID_DB {
            let l = t.label3();
            c.fill(
                CGRect::new(plot.min_x(), g.y(db), plot.width, 1.0),
                if db == 0.0 { l.with_alpha(l.a * InspectorTokens::DISABLED_ALPHA) } else { t.separator() },
            );
        }
        let Some(v) = model.eq_values(self.effect) else {
            c.restore_gstate();
            return;
        };
        let freqs = g.sample_frequencies(2.0);
        let mut dbs: Vec<f64> = Vec::new();
        ParametricEQResponse::total_db_at(&v, &freqs, &mut dbs);
        let line: Vec<CGPoint> = freqs.iter().zip(&dbs).map(|(f, d)| CGPoint::new(g.x(*f), g.y(*d))).collect();
        let zero = g.y(0.0);
        if let (Some(first), Some(last)) = (line.first(), line.last()) {
            let mut poly = vec![CGPoint::new(first.x, zero)];
            poly.extend(line.iter().copied());
            poly.push(CGPoint::new(last.x, zero));
            c.fill_polygon(&poly, t.accent_tint());
        }
        c.stroke_polyline(&line, InspectorTokens::FOCUS_LINE_WIDTH, t.accent());
        c.restore_gstate();
        let caption = type_size::CAPTION as f64;
        for (hz, text) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
            text_in(
                c,
                text,
                CGRect::new(g.x(hz) - 20.0, plot.max_y() + 1.0, 40.0, Self::LABEL_BAND - 1.0),
                caption,
                t.label3(),
                TextAlign::Center,
            );
        }
        for db in [-12.0, -6.0, 6.0, 12.0] {
            text_in(
                c,
                &format!("{db:+.0}"),
                CGRect::new(plot.min_x() + 4.0, g.y(db) - 14.0, 30.0, 13.0),
                caption,
                t.label3(),
                TextAlign::Left,
            );
        }
        let r = Self::HANDLE_RADIUS;
        for i in 0..AudioParametricEQValues::BAND_COUNT {
            let p = Self::point_position(i, &v, &g);
            let dot = CGRect::new(p.x - r, p.y - r, 2.0 * r, 2.0 * r);
            if v.band(i).on {
                c.fill_ellipse(dot, if self.drag_filter == Some(i) { t.accent() } else { t.label() });
                c.stroke_ellipse(dot, 1.0, t.divider());
            } else {
                let l = t.label3();
                c.stroke_ellipse(dot, 1.0, l.with_alpha(l.a * InspectorTokens::DISABLED_ALPHA));
            }
        }
    }

    fn mouse_down(
        &mut self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        rect: CGRect,
        click_count: i64,
        modifiers: InputModifiers,
    ) {
        self.end_scroll(model);
        let Some(i) = self.filter_at(model, p, rect) else { return };
        let Some(v) = model.eq_values(self.effect) else { return };
        if click_count == 2 {
            model.begin_gesture();
            model.reset_eq_band(self.effect, i);
            model.end_gesture();
            return;
        }
        self.drag_filter = Some(i);
        self.q_drag = modifiers.contains(InputModifiers::OPTION) && EQCurveGeometry::has_gain(i);
        self.drag_start = Some((p, v.band(i).q));
        model.begin_gesture();
    }

    fn mouse_dragged(&mut self, model: &mut EffectControlsModel, p: CGPoint, rect: CGRect, _modifiers: InputModifiers) {
        let (Some(i), Some(start)) = (self.drag_filter, self.drag_start) else { return };
        if self.q_drag {
            model.set_eq_band(self.effect, i, None, None, Some(EQCurveGeometry::q_factor(start.1, start.0.y - p.y)));
        } else {
            let g = Self::geometry(rect);
            model.set_eq_band(
                self.effect,
                i,
                Some(g.hz(p.x)),
                if EQCurveGeometry::has_gain(i) { Some(g.db(p.y)) } else { None },
                None,
            );
        }
    }

    fn mouse_up(&mut self, model: &mut EffectControlsModel, _p: CGPoint, _rect: CGRect) {
        if self.drag_filter.is_none() {
            return;
        }
        self.drag_filter = None;
        self.drag_start = None;
        self.q_drag = false;
        model.end_gesture();
    }

    fn mouse_moved(&mut self, model: &mut EffectControlsModel, p: Option<CGPoint>, _rect: CGRect) {
        if p.is_none() {
            self.end_scroll(model);
        }
    }

    fn scroll(
        &mut self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        rect: CGRect,
        dy: f64,
        gesture: Option<&ScrollGesture>,
    ) -> bool {
        let mut dy = dy;
        if let Some(g) = gesture {
            // EQCurveView.scrollWheel: the raw deltaY, a wheel line counts 4 (not the list's pixels); a pinch is no Q.
            if !g.is_scroll() {
                return false;
            }
            dy = if g.precise { g.delta_y } else { g.delta_y * 4.0 };
        }
        if self.scrolling.is_none() {
            let Some(i) = self.filter_at(model, p, rect) else { return false };
            if !EQCurveGeometry::has_gain(i) {
                return false;
            }
            let Some(v) = model.eq_values(self.effect) else { return false };
            self.scrolling = Some((i, v.band(i).q, 0.0));
            model.begin_gesture();
        }
        let Some(mut st) = self.scrolling else { return false };
        st.2 += dy;
        self.scrolling = Some(st);
        model.set_eq_band(self.effect, st.0, None, None, Some(EQCurveGeometry::q_factor(st.1, st.2)));
        true
    }
}
