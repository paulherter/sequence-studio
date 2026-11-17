// Swift: Draw/ColorGradeDraw+ProTabs.swift
//! The Pro page's Curves, Qualifier, Window, LUT and Effects tabs (the Mac `ColorStepDetailView` and the LUT rows of
//! `ColorGraphPage`). The sliders and curves are the Simple page's own drawing; the range bars and chips are drawn here.

use super::color_grade_draw::{
    ColorGradeDraw, ColorGradeHost, Control, Curve, DrawMenuCommand, Mac, Row, RowStyle, Slider,
};
use super::color_graph_menus::LUTTarget;
use super::color_inspector_model::{ColorInspectorModel, HueCurveKind};
use super::color_inspector_model_graph::StepParam;
use super::color_inspector_model_graph_detail::{StepWindowParam, StepWindowShapeExt};
use super::color_range_model::ColorRangeParam;
use super::geom::offset_by;
use super::step_range_logic::{RangeBarMath, StepRangeKind};
use sq_core_model::{ColorStep, RGBCurves, StepWindowShape};
use sq_core_time::Id;
use sq_draw::inspector::{CheckState, InspectorDraw, InspectorTokens};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{metrics, radius, spacing, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputModifiers, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

fn tr(s: &str) -> String {
    SQL10n::string(s)
}

const SHAPES: [StepWindowShape; 3] = [StepWindowShape::Ellipse, StepWindowShape::Rectangle, StepWindowShape::Linear];

impl ColorGradeDraw {
    pub const RANGE_ROW_HEIGHT: f64 = 34.0;
    pub const RANGE_TRACK_HEIGHT: f64 = 14.0;
    pub const RGB_CURVE_HEIGHT: f64 = 150.0;
    pub const HUE_CURVE_HEIGHT: f64 = 90.0;
    pub const GROUP_HEIGHT: f64 = 24.0;
    pub const CHANNEL_TITLES: [&'static str; 4] = ["Luma", "Red", "Green", "Blue"];

    pub(crate) fn pro_other_tab_rows(
        &self,
        _model: &ColorInspectorModel,
        id: Id,
        step: Option<&ColorStep>,
        add: &mut dyn FnMut(Row),
    ) {
        let w = self.size.width;
        let inset = Mac::INSET;
        let cap = f64::from(metrics::CAPSULE);
        let fh = Self::FORM_ROW_HEIGHT;
        let sm = f64::from(spacing::SM);
        let none = step.is_none();
        let body = f64::from(type_size::BODY);
        let mid = |h: f64, ch: f64| ((h - ch) / 2.0).round();
        let curve_box = |h: f64| CGRect::new(inset, 6.0, (w - 2.0 * inset).max(0.0), h);
        match self.pro_tab {
            1 => {
                add(Row::plain(
                    None,
                    6.0 + Self::RGB_CURVE_HEIGHT + sm,
                    vec![(Control::Curve(Curve::StepRgb(id)), curve_box(Self::RGB_CURVE_HEIGHT))],
                )
                .dimmed(none));
                let mut x = inset;
                let mut chips: Vec<(Control, CGRect)> = Vec::new();
                for (i, t) in Self::CHANNEL_TITLES.iter().enumerate() {
                    let cw = self.text_width(t, body, false) + 20.0;
                    chips.push((Control::CurveChip(i), CGRect::new(x, mid(fh, cap), cw, cap)));
                    x += cw + 2.0;
                }
                let rw = self.button_width("Reset");
                chips.push((Control::CurveReset, CGRect::new(w - inset - rw, mid(fh, cap), rw, cap)));
                add(Row::plain(None, fh, chips).dimmed(none));
                add(Row::new(Some("Hue Saturation Curves"), RowStyle::GroupHead, Self::GROUP_HEIGHT, Vec::new())
                    .dimmed(none));
                add(Row::plain(
                    Some("Curve"),
                    Mac::POPUP_ROW,
                    vec![(
                        Control::StepHueKind,
                        CGRect::new(
                            Mac::CONTROL_X,
                            mid(Mac::POPUP_ROW, cap),
                            (w - inset - Mac::CONTROL_X).max(0.0),
                            cap,
                        ),
                    )],
                )
                .dimmed(none));
                add(Row::plain(
                    None,
                    6.0 + Self::HUE_CURVE_HEIGHT + sm,
                    vec![(Control::Curve(Curve::StepHue(id)), curve_box(Self::HUE_CURVE_HEIGHT))],
                )
                .dimmed(none));
            }
            2 => {
                let has_q = step.is_some_and(|s| s.qualifier.is_some());
                let cb = 14.0;
                let check = |k: Control, title: &str, x: f64| -> (Control, CGRect) {
                    let cw = cb + 6.0 + self.text_width(title, body, false);
                    (k, CGRect::new(x, mid(fh, cb), cw, cb))
                };
                let q = check(Control::QualOn, "Limit to a color range", inset);
                add(Row::plain(None, fh, vec![q]).dimmed(none));
                let pw = self.button_width("Pick color");
                let mt = check(Control::Matte, "Show matte", inset + pw + sm);
                let iv = check(Control::QualInvert, "Invert", mt.1.max_x() + sm);
                add(Row::plain(
                    None,
                    fh,
                    vec![(Control::PickColor, CGRect::new(inset, mid(fh, cap), pw, cap)), mt, iv],
                )
                .dimmed(none));
                let right = w - inset - 56.0;
                for kind in StepRangeKind::ALL {
                    let h = Self::RANGE_ROW_HEIGHT;
                    add(Row::plain(
                        Some(kind.title()),
                        h,
                        vec![(
                            Control::RangeBar(kind),
                            CGRect::new(
                                Mac::CONTROL_X,
                                mid(h, Self::RANGE_TRACK_HEIGHT),
                                (right - Mac::CONTROL_X).max(1.0),
                                Self::RANGE_TRACK_HEIGHT,
                            ),
                        )],
                    )
                    .dimmed(!has_q));
                }
                add(Row::plain(
                    Some(ColorRangeParam::Softness.title()),
                    Mac::ROW,
                    vec![(Control::Slider(Slider::StepQual(id, ColorRangeParam::Softness)), self.slider_box(Mac::ROW))],
                )
                .dimmed(!has_q));
            }
            3 => {
                let has_w = step.is_some_and(|s| s.window.is_some());
                let mut x = inset;
                let mut chips: Vec<(Control, CGRect)> = Vec::new();
                for (i, s) in SHAPES.iter().enumerate() {
                    let cw = self.text_width(s.chip_title(), body, false) + 20.0;
                    chips.push((Control::ShapeChip(i), CGRect::new(x, mid(fh, cap), cw, cap)));
                    x += cw + 2.0;
                }
                add(Row::plain(None, fh, chips).dimmed(none));
                let tw = Mac::ICON;
                let title = step
                    .and_then(|s| s.window.as_ref())
                    .map_or("No window".to_string(), |win| format!("Window \u{00B7} {}", win.shape.chip_title()));
                let mut title_row = Row::new(
                    Some(&title),
                    RowStyle::Title,
                    fh,
                    vec![(Control::WindowRemove, CGRect::new(w - inset - tw, mid(fh, cap), tw, cap))],
                )
                .dimmed(none);
                title_row.open = has_w;
                add(title_row);
                for p in StepWindowParam::ALL {
                    let label = if p == StepWindowParam::Softness { "Feather" } else { p.title() };
                    add(Row::plain(
                        Some(label),
                        Mac::ROW,
                        vec![(Control::Slider(Slider::Window(id, p)), self.slider_box(Mac::ROW))],
                    )
                    .dimmed(!has_w));
                }
                let cw = 14.0 + 6.0 + self.text_width("Invert", body, false);
                let iv = CGRect::new(Mac::INSET, ((fh - 14.0) / 2.0).round(), cw, 14.0);
                add(Row::plain(None, fh, vec![(Control::WindowInvert, iv)]).dimmed(!has_w));
                self.note("Windows use the same shapes as masks on the timeline.", add);
            }
            4 => {
                let ib = self.button_width("Import\u{2026}");
                add(Row::plain(
                    None,
                    fh,
                    vec![
                        (Control::LutPill, CGRect::new(inset, mid(fh, cap), (w - 2.0 * inset - ib - sm).max(0.0), cap)),
                        (Control::LutImport, CGRect::new(w - inset - ib, mid(fh, cap), ib, cap)),
                    ],
                )
                .dimmed(none));
                add(Row::plain(
                    Some(StepParam::LutIntensity.title()),
                    Mac::ROW,
                    vec![(Control::Slider(Slider::Step(id, StepParam::LutIntensity)), self.slider_box(Mac::ROW))],
                )
                .dimmed(step.is_none_or(|s| s.lut.is_none())));
                self.note("Supports .cube and .3dl. Imported files are kept with the project.", add);
            }
            _ => {
                add(Row::plain(
                    None,
                    fh,
                    vec![(Control::AddEffect, CGRect::new(inset, mid(fh, cap), (w - 2.0 * inset).max(0.0), cap))],
                ));
                self.note(
                    "No effects on this Step. Effects run after the Step\u{2019}s color work, in the order listed.",
                    add,
                );
            }
        }
    }

    fn note(&self, text: &str, add: &mut dyn FnMut(Row)) {
        let lines = self.wrap_lines(text, (self.size.width - 2.0 * Mac::INSET).max(0.0), f64::from(type_size::CAPTION));
        let mut r = Row::new(None, RowStyle::Footnote, lines.len() as f64 * Self::FOOTNOTE_LINE + 16.0, Vec::new());
        r.lines = lines;
        add(r);
    }

    // MARK: Drawing

    #[allow(clippy::too_many_arguments)]
    fn draw_check(&self, c: &mut Canvas, t: &DrawTheme, f: CGRect, title: &str, on: bool, k: Control, enabled: bool) {
        let boxed = CGRect::new(f.min_x(), f.mid_y() - 7.0, 14.0, 14.0);
        InspectorDraw::checkbox(
            c,
            if on { CheckState::On } else { CheckState::Off },
            boxed,
            self.hover == Some(k),
            self.pressed == Some(k),
            enabled,
            false,
            t,
        );
        c.draw_text_in(
            &tr(title),
            CGRect::new(boxed.max_x() + 6.0, f.min_y() - 4.0, f.width, f.height + 8.0),
            f64::from(type_size::BODY),
            t.label().with_alpha(if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA }),
            TextAlign::Left,
            0.0,
            0,
        );
    }

    fn draw_chip(c: &mut Canvas, t: &DrawTheme, f: CGRect, title: &str, on: bool, hover: bool, enabled: bool) {
        let a: f32 = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        c.stone_chip(f, on, false, Touch { hovering: hover, disabled: !enabled, ..Touch::default() }, t);
        c.draw_text_in(
            &tr(title),
            f,
            f64::from(type_size::BODY),
            (if on { t.label() } else { t.label2() }).with_alpha(a),
            TextAlign::Center,
            0.0,
            0,
        );
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn draw_pro_tab_control(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        m: &ColorInspectorModel,
        k: Control,
        f: CGRect,
        enabled: bool,
    ) -> bool {
        let hov = self.hover == Some(k);
        let prs = self.pressed == Some(k);
        let step = m.selected_step().and_then(|s| m.step(s));
        let h = f64::MAX;
        match k {
            Control::CurveChip(i) => {
                let id = step.map_or(Self::NO_STEP, |s| s.id);
                Self::draw_chip(c, t, f, Self::CHANNEL_TITLES[i], self.channel(Curve::StepRgb(id)) == i, hov, enabled);
            }
            Control::CurveReset => InspectorDraw::button(c, &tr("Reset"), f, hov, prs, enabled, false, h, t),
            Control::StepHueKind => {
                InspectorDraw::popup(c, &tr(self.step_hue_kind.title()), f, hov, false, enabled, false, h, None, t);
            }
            Control::QualOn => self.draw_check(
                c,
                t,
                f,
                "Limit to a color range",
                step.is_some_and(|s| s.qualifier.is_some()),
                k,
                step.is_some(),
            ),
            Control::PickColor => InspectorDraw::button(c, &tr("Pick color"), f, false, false, false, false, h, t),
            Control::Matte => self.draw_check(
                c,
                t,
                f,
                "Show matte",
                m.shows_matte(),
                k,
                step.is_some_and(|s| s.qualifier.is_some() || s.window.is_some()),
            ),
            Control::QualInvert => self.draw_check(
                c,
                t,
                f,
                "Invert",
                step.and_then(|s| s.qualifier.as_ref()).is_some_and(|q| q.invert),
                k,
                step.is_some_and(|s| s.qualifier.is_some()),
            ),
            Control::WindowInvert => self.draw_check(
                c,
                t,
                f,
                "Invert",
                step.and_then(|s| s.window.as_ref()).is_some_and(|w| w.invert),
                k,
                step.is_some_and(|s| s.window.is_some()),
            ),
            Control::RangeBar(kind) => self.draw_range(c, t, m, kind, f, enabled),
            Control::ShapeChip(i) => {
                let sel = step.and_then(|s| s.window.as_ref()).and_then(|w| SHAPES.iter().position(|s| *s == w.shape));
                Self::draw_chip(c, t, f, SHAPES[i].chip_title(), sel == Some(i), hov, step.is_some());
            }
            Control::WindowRemove => {
                let live = step.is_some_and(|s| s.window.is_some());
                if live && hov {
                    c.stone_button(f, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
                }
                c.draw_icon(
                    SQIcon::Trash,
                    CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0),
                    12.0,
                    if live { t.label2() } else { t.label3().with_alpha(0.5) },
                    None,
                );
            }
            Control::LutPill => {
                let name =
                    step.and_then(|s| m.step_lut_choice(s.id)).map_or("Choose LUT\u{2026}".to_string(), |c| c.name);
                InspectorDraw::button(c, &name, f, hov, prs, step.is_some(), false, h, t);
            }
            Control::LutImport => {
                InspectorDraw::button(c, &tr("Import\u{2026}"), f, hov, prs, step.is_some(), false, h, t)
            }
            Control::AddEffect => InspectorDraw::popup(c, &tr("Add effect"), f, false, false, false, false, h, None, t),
            _ => return false,
        }
        true
    }

    /// The range bar (ColorRangeRow.draw): the gradient track, the selection frame and the two edge handles; the value at
    /// the right.
    fn draw_range(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        m: &ColorInspectorModel,
        kind: StepRangeKind,
        f: CGRect,
        enabled: bool,
    ) {
        let (lo, hi) = self.range_bounds(Some(m), kind);
        let math = RangeBarMath { maximum: kind.maximum(), min_x: f.min_x(), width: f.width };
        let r = f64::from(radius::SMALL);
        c.save_gstate();
        c.clip_to(f);
        let n = 24;
        let dim: f32 = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        for i in 0..n {
            let u = f64::from(i) / f64::from(n - 1);
            let col = match kind {
                StepRangeKind::Hue => {
                    let v = Self::hsb(u, 0.5, 0.62);
                    Color::new(v.0, v.1, v.2, 1.0)
                }
                StepRangeKind::Saturation => {
                    let v = Self::hsb(0.08, 0.8 * u, 0.45 + 0.25 * u);
                    Color::new(v.0, v.1, v.2, 1.0)
                }
                StepRangeKind::Luma => {
                    let v = 0.08 + 0.87 * u as f32;
                    Color::new(v, v, v, 1.0)
                }
            };
            c.fill(
                CGRect::new(
                    f.min_x() + f.width * f64::from(i) / f64::from(n),
                    f.min_y(),
                    f.width / f64::from(n) + 0.5,
                    f.height,
                ),
                col.with_alpha(dim),
            );
        }
        c.restore_gstate();
        let sel = CGRect::new(math.x(lo), f.min_y() - 3.0, (math.x(hi) - math.x(lo)).max(0.0), f.height + 6.0);
        c.stroke_rounded(sel, r, 1.5, t.label().with_alpha(dim));
        for edge in [sel.min_x(), sel.max_x()] {
            c.fill_rounded(CGRect::new(edge - 2.0, f.min_y() - 4.0, 4.0, f.height + 8.0), r, t.label().with_alpha(dim));
        }
        c.draw_text_in(
            &RangeBarMath::text(lo, hi),
            CGRect::new(self.size.width - Mac::INSET - 58.0, f.min_y() - 10.0, 56.0, f.height + 20.0),
            f64::from(type_size::CAPTION),
            t.label().with_alpha(if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA }),
            TextAlign::Right,
            0.0,
            0,
        );
    }

    pub(crate) fn range_bounds(&self, m: Option<&ColorInspectorModel>, kind: StepRangeKind) -> (f64, f64) {
        let Some(m) = m else { return (0.0, kind.maximum()) };
        let Some(id) = m.selected_step() else { return (0.0, kind.maximum()) };
        let (a, b) = kind.pair();
        let (lo, hi) = kind.bounds(f64::from(m.step_qualifier_value(id, a)), f64::from(m.step_qualifier_value(id, b)));
        let l = lo.clamp(0.0, kind.maximum());
        (l, hi.clamp(l, kind.maximum()))
    }

    // MARK: Pointer

    pub(crate) fn pro_tab_mouse_down(
        &mut self,
        host: &mut ColorGradeHost,
        k: Control,
        q: CGPoint,
        _modifiers: InputModifiers,
    ) {
        let Some(id) = host.model().and_then(|m| m.selected_step()) else {
            self.pressed = None;
            return;
        };
        let steps_shown = host.controller.steps_shown();
        match k {
            Control::CurveChip(i) => {
                self.channels.insert(Curve::StepRgb(id), i);
                self.pressed = None;
            }
            Control::StepHueKind => {
                let items: Vec<SQMenuItem> = HueCurveKind::ALL
                    .iter()
                    .map(|kind| {
                        let mut i = self
                            .row(kind.title(), DrawMenuCommand::SetStepHueKind(*kind))
                            .with_help(kind.explanation());
                        i.is_checked = self.step_hue_kind == *kind;
                        i
                    })
                    .collect();
                self.menu_below(host, items, k);
                self.pressed = None;
            }
            Control::ShapeChip(i) => {
                if let Some(shape) = SHAPES.get(i).copied() {
                    if let Some(m) = host.model_mut() {
                        if m.step(id).is_some_and(|s| s.window.is_none()) {
                            m.set_step_window_enabled(id, true);
                        }
                        m.set_step_window_shape(id, shape);
                    }
                    host.pump();
                }
                self.pressed = None;
            }
            Control::LutPill => {
                let menus = super::color_graph_menus::ColorGraphMenus::new(self.graph_sink.clone());
                let mut menus = menus;
                menus.can_choose_lut_file = true;
                let items = host.model().map(|m| menus.lut_items(m, LUTTarget::Step)).unwrap_or_default();
                self.menu_below(host, items, k);
                self.pressed = None;
            }
            Control::RangeBar(kind) => {
                let has_q = host.model().and_then(|m| m.step(id)).is_some_and(|s| s.qualifier.is_some());
                let frame = host.model().and_then(|m| Self::frame_in(&self.rows(m, steps_shown), k));
                let (true, Some(f)) = (has_q, frame) else {
                    self.pressed = None;
                    return;
                };
                let math = RangeBarMath { maximum: kind.maximum(), min_x: f.min_x(), width: f.width };
                let (lo, hi) = self.range_bounds(host.model(), kind);
                self.range_drag = Some((kind, math.grab(q.x, lo, hi)));
                if let Some(m) = host.model_mut() {
                    m.emit_gesture_began();
                }
                host.pump();
                self.pro_range_dragged(host, q);
            }
            _ => {}
        }
    }

    fn menu_below(&mut self, host: &ColorGradeHost, items: Vec<SQMenuItem>, k: Control) {
        if items.is_empty() {
            return;
        }
        let steps_shown = host.controller.steps_shown();
        let Some(f) = host.model().and_then(|m| Self::frame_in(&self.rows(m, steps_shown), k)) else { return };
        self.menus
            .push(super::color_grade_draw::GradeMenuRequest { items, anchor: offset_by(&f, 0.0, -self.scroll_y) });
    }

    pub(crate) fn pro_range_dragged(&mut self, host: &mut ColorGradeHost, q: CGPoint) -> bool {
        let Some((kind, grab)) = self.range_drag else { return false };
        let Some(id) = host.model().and_then(|m| m.selected_step()) else { return false };
        let steps_shown = host.controller.steps_shown();
        let Some(f) = host.model().and_then(|m| Self::frame_in(&self.rows(m, steps_shown), Control::RangeBar(kind)))
        else {
            return false;
        };
        let math = RangeBarMath { maximum: kind.maximum(), min_x: f.min_x(), width: f.width };
        let (lo, hi) = self.range_bounds(host.model(), kind);
        let r = math.apply(grab, q.x, lo, hi);
        if let Some(m) = host.model_mut() {
            for (p, v) in kind.params(r.0, r.1) {
                m.set_step_qualifier(id, p, v);
            }
        }
        host.pump();
        true
    }

    pub(crate) fn pro_range_up(&mut self, host: &mut ColorGradeHost) -> bool {
        if self.range_drag.take().is_none() {
            return false;
        }
        if let Some(m) = host.model_mut() {
            m.emit_gesture_ended();
        }
        host.pump();
        true
    }

    pub(crate) fn pro_tab_clicked(&mut self, host: &mut ColorGradeHost, k: Control) {
        let Some(id) = host.model().and_then(|m| m.selected_step()) else { return };
        let Some(m) = host.model_mut() else { return };
        let step = m.step(id).cloned();
        match k {
            Control::CurveReset => {
                let mut c = m.step_curves(id);
                let flat = RGBCurves::default();
                match self.channel(Curve::StepRgb(id)) {
                    1 => c.red = flat.red,
                    2 => c.green = flat.green,
                    3 => c.blue = flat.blue,
                    _ => c.master = flat.master,
                }
                m.set_step_curves(id, c);
            }
            Control::QualOn => m.set_step_qualifier_enabled(id, step.as_ref().is_some_and(|s| s.qualifier.is_none())),
            Control::Matte => {
                if step.as_ref().is_some_and(|s| s.qualifier.is_some() || s.window.is_some()) {
                    let on = !m.shows_matte();
                    m.set_shows_matte(on);
                }
            }
            Control::QualInvert => {
                if let Some(q) = step.as_ref().and_then(|s| s.qualifier.as_ref()) {
                    m.set_step_qualifier_invert(id, !q.invert);
                }
            }
            Control::WindowInvert => {
                if let Some(w) = step.as_ref().and_then(|s| s.window.as_ref()) {
                    m.set_step_window_invert(id, !w.invert);
                }
            }
            Control::WindowRemove => m.set_step_window_enabled(id, false),
            Control::LutImport => {
                self.file_requests.push(super::color_grade_draw::GradeFileRequest::LutFiles {
                    multiple: false,
                    then: super::color_grade_draw::LutFilesFor::StepLut(id),
                });
            }
            _ => {}
        }
        host.pump();
    }
}
