// Swift: Draw/ColorStepsDraw.swift
//! The Steps panel (the Pro grade's Color Graph) on the shared toolkit. The start page (Start empty / Start from Simple
//! grade), the dotted well with In, LUT slots, Steps, mixers and wires, and the footer (hint, Tidy up, Fit, count). A click
//! selects (Command adds, Shift toggles), a double-click renames, the eye bypasses, a drag moves the Step (onto a wire
//! inserts it, Shift-drag takes it off its wires), a drag between dots wires, a drag on empty canvas selects by rectangle;
//! scroll pans, Command- or Option-scroll zooms. Geometry, hits and drops are the shared `StepsCanvas`; menus are
//! `ColorGraphMenus`. Coordinates: points, y down, (0, 0) = top-left.

use super::color_grade_controller::ColorGradeController;
use super::color_grade_draw::{ColorGradeHost, GradeMenuRequest};
use super::color_graph_menus::{ColorGraphMenus, GraphMenuCommand, GraphMenuHostRequest, LUTTarget, MenuSink};
use super::color_inspector_model::ColorInspectorModel;
use super::color_inspector_model_graph::GraphLUTSlot;
use super::steps_canvas::{Drag, Drop, Hit, Layout, StepsCanvas, StepsPort, Wire};
use sq_core_color::{ColorGraphExt, ColorGraphWiringExt, GraphPortExt};
use sq_core_model::{ColorStep, GraphLink, GraphPort, StepKind, StepPosition};
use sq_core_time::Id;
use sq_draw::inspector::{ClickCounter, InspectorDraw, TextFieldControl};
use sq_draw::scroll::GestureKind;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::{BTreeMap, BTreeSet};

fn tr(s: &str) -> String {
    SQL10n::string(s)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StepsButton {
    StartEmpty,
    StartFromSimple,
    Tidy,
    Fit,
    /// The graph header's tools: add a Step (a menu), duplicate and delete the selected one.
    Add,
    Duplicate,
    Delete,
}

impl StepsButton {
    /// The icon-only buttons of the graph header.
    pub fn is_tool(self) -> bool {
        matches!(self, StepsButton::Add | StepsButton::Duplicate | StepsButton::Delete)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct WireDrag {
    pub from: StepsPort,
    pub point: CGPoint,
    pub target: Option<StepsPort>,
    pub refused: bool,
    pub is_key: bool,
    pub replacing: Option<GraphLink>,
}

#[derive(Clone, Debug)]
pub struct Marquee {
    pub start: CGPoint,
    pub current: CGPoint,
    pub base: BTreeSet<Id>,
}

impl Marquee {
    pub fn rect(&self) -> CGRect {
        CGRect::new(
            self.start.x.min(self.current.x),
            self.start.y.min(self.current.y),
            (self.current.x - self.start.x).abs(),
            (self.current.y - self.start.y).abs(),
        )
    }
}

/// What a press in the panel asks the host for besides menus.
#[derive(Clone, Debug, PartialEq)]
pub enum StepsHostRequest {
    /// Choose File… of a LUT slot menu (the paths come back to `ColorGradeDraw::files_chosen`).
    ChooseLutFile(LUTTarget),
    /// Import Color Decision… of a Step menu.
    ImportDecision(Id),
}

pub struct ColorStepsDraw {
    pub size: CGSize,
    canvas: StepsCanvas,
    /// Menus the panel asked for, oldest first (Swift `onMenu`).
    pub menus: Vec<GradeMenuRequest>,
    pub requests: Vec<StepsHostRequest>,
    /// The host has a .cube / .3dl chooser (Choose File… is enabled), a decision chooser, and a message sink.
    pub can_choose_lut_file: bool,
    pub can_import_decision: bool,
    sink: MenuSink<GraphMenuCommand>,
    wire_drag: Option<WireDrag>,
    /// A refused drop keeps its target ringed in red until `until` (the Mac `refusedFlash`, 0.7 s); the wire snapped back.
    refused_flash: Option<(StepsPort, bool, f64)>,
    marquee: Option<Marquee>,
    hover_step: Option<Id>,
    hover_insert: Option<Id>,
    hover_button: Option<StepsButton>,
    pressed_button: Option<StepsButton>,
    collapse_on_click: Option<Id>,
    toggle_on_click: Option<Id>,
    counter: ClickCounter,
    renaming: Option<(Id, TextFieldControl)>,
    /// The open rename field's frame as last drawn (panel points): a press inside places the caret, the pointer over it
    /// is the I-beam (the Mac NSTextField).
    rename_rect: Option<CGRect>,
    /// The hint line and summary widths from the last frame (the layout of the footer buttons).
    summary_width: f64,
    widths: BTreeMap<String, f64>,
}

impl Default for ColorStepsDraw {
    fn default() -> Self {
        ColorStepsDraw {
            size: CGSize::new(480.0, 300.0),
            canvas: StepsCanvas::default(),
            menus: Vec::new(),
            requests: Vec::new(),
            can_choose_lut_file: false,
            can_import_decision: false,
            sink: MenuSink::new(),
            wire_drag: None,
            refused_flash: None,
            marquee: None,
            hover_step: None,
            hover_insert: None,
            hover_button: None,
            pressed_button: None,
            collapse_on_click: None,
            toggle_on_click: None,
            counter: ClickCounter::new(),
            renaming: None,
            rename_rect: None,
            summary_width: 0.0,
            widths: BTreeMap::new(),
        }
    }
}

impl ColorStepsDraw {
    /// The "Color Graph" title row above the canvas and the hint row below it (redesign R4d: 34 pt each).
    pub const HEADER: f64 = 34.0;
    pub const TOOL_WIDTH: f64 = 24.0;
    pub const FOOTER: f64 = 34.0;
    /// The canvas runs edge to edge between the two rows.
    pub const INSET: f64 = 0.0;
    pub const DOT_PITCH: f64 = 18.0;
    pub const START_DOT: f64 = 7.0;
    pub const START_WIRE: f64 = 80.0;
    pub const START_RISE: f64 = 40.0;
    pub const REFUSED_FLASH_SECONDS: f64 = 0.7;

    pub fn new() -> ColorStepsDraw {
        ColorStepsDraw::default()
    }

    pub fn canvas(&self) -> &StepsCanvas {
        &self.canvas
    }

    pub fn wire_drag(&self) -> Option<&WireDrag> {
        self.wire_drag.as_ref()
    }

    pub fn marquee(&self) -> Option<&Marquee> {
        self.marquee.as_ref()
    }

    pub fn rename_rect(&self) -> Option<CGRect> {
        self.rename_rect
    }

    pub fn renaming_id(&self) -> Option<Id> {
        self.renaming.as_ref().map(|r| r.0)
    }

    /// The well: the dotted canvas area.
    pub fn well(&self) -> CGRect {
        CGRect::new(
            Self::INSET,
            Self::HEADER,
            (self.size.width - 2.0 * Self::INSET).max(0.0),
            (self.size.height - Self::HEADER - Self::FOOTER).max(0.0),
        )
    }

    fn offers_start(m: Option<&ColorInspectorModel>) -> bool {
        m.is_some_and(|m| m.graph().is_none())
    }

    fn shows_canvas(m: Option<&ColorInspectorModel>) -> bool {
        m.and_then(|m| m.graph()).is_some_and(|g| !g.steps().is_empty()) && !Self::offers_start(m)
    }

    fn menus_for(&self) -> ColorGraphMenus {
        let mut m = ColorGraphMenus::new(self.sink.clone());
        m.can_choose_lut_file = self.can_choose_lut_file;
        m.can_rename = true;
        m.custom_tidy_up = true;
        m.can_import_decision = self.can_import_decision;
        m
    }

    /// Add Step's kinds for the strip's plus button (nil while there is no graph to add to).
    pub fn add_menu_items(&self, model: Option<&ColorInspectorModel>) -> Option<Vec<SQMenuItem>> {
        let m = model?;
        m.graph()?;
        Some(self.menus_for().add_menu_items(m))
    }

    /// Feeds the canvas from the graph (ColorStepsGraphView.refresh) and fits the view until the user moves it.
    pub fn refresh(&mut self, host: &mut ColorGradeHost, measure: &dyn Fn(&str) -> f64) {
        let well = self.well();
        let Some(model) = host.model() else {
            self.canvas.links = None;
            self.canvas.key_links = Vec::new();
            self.canvas.mixer_positions = BTreeMap::new();
            self.canvas.columns = Vec::new();
            self.canvas.positions = BTreeMap::new();
            return;
        };
        let g = model.graph();
        self.canvas.links = g.and_then(|g| g.links.clone());
        self.canvas.key_links = g.map(|g| g.key_links.clone()).unwrap_or_default();
        self.canvas.mixer_positions = g
            .map(|g| g.steps().iter().filter_map(|s| s.mixer_position.map(|p| (s.id, p))).collect())
            .unwrap_or_default();
        self.canvas.columns =
            g.map(|g| g.columns().iter().map(|c| c.iter().map(|s| s.id).collect()).collect()).unwrap_or_default();
        self.canvas.positions =
            g.map(|g| g.steps().iter().filter_map(|s| s.position.map(|p| (s.id, p))).collect()).unwrap_or_default();
        self.canvas.in_slot_width = StepsCanvas::slot_width(
            measure(&model.graph_lut_choice(GraphLUTSlot::Input).map_or(String::new(), |c| c.name)),
            model.graph_lut_choice(GraphLUTSlot::Input).is_some(),
        );
        self.canvas.out_slot_width = StepsCanvas::slot_width(
            measure(&model.graph_lut_choice(GraphLUTSlot::Output).map_or(String::new(), |c| c.name)),
            model.graph_lut_choice(GraphLUTSlot::Output).is_some(),
        );
        if self.canvas.drag().is_none() && !self.canvas.user_view {
            self.canvas.fit(CGSize::new(well.width, well.height), f64::from(spacing::LG));
        }
        let renaming = host.model_mut().and_then(|m| {
            let id = m.renaming_step;
            m.renaming_step = None;
            id
        });
        if let Some(id) = renaming {
            self.begin_rename(host, id);
        }
    }

    pub fn tidy_up(&mut self, host: &mut ColorGradeHost, measure: &dyn Fn(&str) -> f64) {
        self.canvas.user_view = false;
        if let Some(m) = host.model_mut() {
            m.tidy_up_steps();
        }
        host.pump();
        self.refresh(host, measure);
    }

    pub fn fit_view(&mut self, host: &mut ColorGradeHost, measure: &dyn Fn(&str) -> f64) {
        self.canvas.user_view = false;
        self.refresh(host, measure);
    }

    fn local(&self, p: CGPoint) -> CGPoint {
        let w = self.well();
        CGPoint::new(p.x - w.min_x(), p.y - w.min_y())
    }

    // MARK: Footer and start buttons

    fn summary(m: Option<&ColorInspectorModel>) -> String {
        let g = m.and_then(|m| m.graph());
        let n = g.map_or(0, |g| g.steps().len());
        let s = g.map_or(0, |g| g.columns().len());
        tr(&format!("{n} {}, {s} in series", if n == 1 { "step" } else { "steps" }))
    }

    fn button_frames(&self, m: Option<&ColorInspectorModel>) -> Vec<(StepsButton, CGRect)> {
        let width = |s: &str| -> f64 {
            self.widths
                .get(s)
                .copied()
                .map_or(s.chars().count() as f64 * 7.0 + 22.0, |w| (w + InspectorDraw::BUTTON_PADDING * 2.0).ceil())
        };
        let mut out = Vec::new();
        let h = sq_uikit::controls_grid::ControlsGrid::CONTROL_HEIGHT;
        if Self::offers_start(m) {
            let w = self.well();
            let a = width(&tr("Start empty"));
            let b = width(&tr("Start from Simple grade"));
            let y = (w.mid_y() - Self::START_RISE + StepsCanvas::NODE.height + 60.0).round();
            let x = (w.mid_x() - (a + b + f64::from(spacing::SM)) / 2.0).round();
            out.push((StepsButton::StartEmpty, CGRect::new(x, y, a, h)));
            out.push((StepsButton::StartFromSimple, CGRect::new(x + a + f64::from(spacing::SM), y, b, h)));
        } else if Self::shows_canvas(m) {
            let fy = self.size.height - Self::FOOTER + ((Self::FOOTER - h) / 2.0).round();
            let mut rx = self.size.width - f64::from(spacing::MD) - self.summary_width.ceil() - f64::from(spacing::MD);
            let fw = width(&tr("Fit"));
            let tw = width(&tr("Tidy up"));
            rx -= fw;
            out.push((StepsButton::Fit, CGRect::new(rx, fy, fw, h)));
            rx -= f64::from(spacing::XS) + tw;
            out.push((StepsButton::Tidy, CGRect::new(rx, fy, tw, h)));
            // The header's tools: 24 wide, 2 apart, 10 from the right edge (the kit's header row).
            let ty = ((Self::HEADER - 1.0 - h) / 2.0).round();
            let mut tx = self.size.width - 10.0;
            for b in [StepsButton::Delete, StepsButton::Duplicate, StepsButton::Add] {
                tx -= Self::TOOL_WIDTH;
                out.push((b, CGRect::new(tx, ty, Self::TOOL_WIDTH, h)));
                tx -= 2.0;
            }
        }
        out
    }

    fn button_title(b: StepsButton) -> &'static str {
        match b {
            StepsButton::StartEmpty => "Start empty",
            StepsButton::StartFromSimple => "Start from Simple grade",
            StepsButton::Tidy => "Tidy up",
            StepsButton::Fit => "Fit",
            StepsButton::Add => "Add a step",
            StepsButton::Duplicate => "Duplicate step",
            StepsButton::Delete => "Delete step",
        }
    }

    fn tool_icon(b: StepsButton) -> SQIcon {
        match b {
            StepsButton::Duplicate => SQIcon::Copy,
            StepsButton::Delete => SQIcon::Trash,
            _ => SQIcon::Plus,
        }
    }

    /// Duplicate and delete act on the selected Step; without one they draw dim and do nothing.
    fn tool_enabled(b: StepsButton, m: Option<&ColorInspectorModel>) -> bool {
        match b {
            StepsButton::Add => m.is_some_and(|m| m.graph().is_some()),
            StepsButton::Duplicate | StepsButton::Delete => m.is_some_and(|m| m.selected_step().is_some()),
            _ => true,
        }
    }

    // MARK: Drawing

    /// The titles the footer buttons measure with are learned from the first frame's canvas.
    fn learn(&mut self, c: &Canvas, m: Option<&ColorInspectorModel>) {
        for b in [StepsButton::StartEmpty, StepsButton::StartFromSimple, StepsButton::Tidy, StepsButton::Fit] {
            let t = tr(Self::button_title(b));
            let w = c.size_of(&t, f64::from(type_size::BODY), 0).width;
            self.widths.insert(t, w);
        }
        self.summary_width = c.size_of(&Self::summary(m), f64::from(type_size::CAPTION), 0).width;
    }

    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, host: &mut ColorGradeHost, cx: &mut UiCx) {
        self.rename_rect = None;
        {
            let m = host.model();
            let probe = |s: &str| c.size_of(s, f64::from(type_size::CAPTION), 0).width;
            let _ = &probe;
            self.learn(c, m);
        }
        let probe = |s: &str| c.size_of(s, f64::from(type_size::CAPTION), 0).width;
        self.refresh(host, &probe);
        let model = host.model();
        let w = self.well();
        let cap = f64::from(type_size::CAPTION);
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        c.fill(w, t.lane());
        c.save_gstate();
        c.clip_to(w);
        // The dotted grid stays for the start page only: the graph sits on the plain lane (redesign R4d).
        if !Self::shows_canvas(model) {
            self.draw_grid(c, t, w, false);
        }
        if model.is_none() {
            c.draw_text_in(
                &tr("No Pro grade here"),
                CGRect::new(w.min_x(), w.mid_y() - 22.0, w.width, 20.0),
                f64::from(type_size::BODY),
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
            c.draw_text_in(
                &tr("Pick a clip, then choose Pro in the Color panel."),
                CGRect::new(w.min_x(), w.mid_y(), w.width, 18.0),
                cap,
                t.label3(),
                TextAlign::Center,
                0.0,
                0,
            );
        } else if Self::offers_start(model) {
            self.draw_start(c, t, w);
        } else if Self::shows_canvas(model) {
            c.translate_by(w.min_x(), w.min_y());
            self.draw_graph(c, t, model, cx);
        }
        c.restore_gstate();
        for (b, f) in self.button_frames(model) {
            if b.is_tool() {
                let on = Self::tool_enabled(b, model);
                if on && (self.pressed_button == Some(b) || self.hover_button == Some(b)) {
                    let touch = if self.pressed_button == Some(b) {
                        Touch { pressed: true, ..Touch::default() }
                    } else {
                        Touch { hovering: true, ..Touch::default() }
                    };
                    c.stone_button(f, ButtonKind::Quiet, touch, t);
                }
                let ink = if on { t.label2() } else { t.label3().with_alpha(0.5) };
                c.draw_icon(Self::tool_icon(b), CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0), 12.0, ink, None);
                continue;
            }
            InspectorDraw::button(
                c,
                &tr(Self::button_title(b)),
                f,
                self.hover_button == Some(b),
                self.pressed_button == Some(b),
                true,
                false,
                f64::MAX,
                t,
            );
        }
        if !Self::shows_canvas(model) {
            return;
        }
        let fy = self.size.height - Self::FOOTER;
        self.draw_graph_header(c, t);
        c.fill(CGRect::new(0.0, fy, self.size.width, 1.0), t.separator());
        let hint = tr("Drag a step to move it, or onto a wire to insert it. Drag between dots to connect.");
        let right = self
            .button_frames(model)
            .iter()
            .find(|f| f.0 == StepsButton::Tidy)
            .map_or(self.size.width, |f| f.1.min_x());
        let md = f64::from(spacing::MD);
        c.draw_text_in(
            &hint,
            CGRect::new(md, fy, (right - md * 2.0).max(0.0), Self::FOOTER),
            cap,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        c.draw_text_in(
            &Self::summary(model),
            CGRect::new(0.0, fy, self.size.width - md, Self::FOOTER),
            cap,
            t.label3(),
            TextAlign::Right,
            0.0,
            0,
        );
    }

    /// "Color Graph" with the Experimental mark, on its own 34 pt row (the strip's tools stay in the panel header).
    fn draw_graph_header(&self, c: &mut Canvas, t: &DrawTheme) {
        let md = f64::from(spacing::MD);
        let title = tr("Color Graph");
        let size = f64::from(type_size::BODY);
        let face = c.semibold();
        let tw = c.size_of(&title, size, face).width;
        c.draw_text_in(
            &title,
            CGRect::new(md, 0.0, tw + 2.0, Self::HEADER),
            size,
            t.label(),
            TextAlign::Left,
            0.0,
            face,
        );
        // The shared Experimental pill (sq_draw::experimental), 8 pt after the title.
        let origin = CGPoint::new((md + tw + 8.0).ceil(), (Self::HEADER - sq_draw::experimental::PILL_HEIGHT) / 2.0);
        c.experimental_mark(
            sq_draw::experimental::Feature::ProGrading,
            origin,
            sq_draw::experimental::ExperimentalMark::Pill,
            t,
        );
        c.fill(CGRect::new(0.0, Self::HEADER - 1.0, self.size.width, 1.0), t.separator());
    }

    fn draw_grid(&self, c: &mut Canvas, t: &DrawTheme, w: CGRect, shows_canvas: bool) {
        let pitch = Self::DOT_PITCH * if shows_canvas { self.canvas.zoom.max(0.6) } else { 1.0 };
        let ox = (if shows_canvas { self.canvas.pan.x } else { 0.0 }) % pitch;
        let oy = (if shows_canvas { self.canvas.pan.y } else { 0.0 }) % pitch;
        let mut y = w.min_y() + pitch / 2.0 + oy;
        while y < w.max_y() {
            let mut x = w.min_x() + pitch / 2.0 + ox;
            while x < w.max_x() {
                c.fill(CGRect::new(x.round(), y.round(), 1.0, 1.0), t.separator());
                x += pitch;
            }
            y += pitch;
        }
    }

    fn draw_start(&self, c: &mut Canvas, t: &DrawTheme, w: CGRect) {
        let cap = f64::from(type_size::CAPTION);
        let iw = c.size_of("In", cap, 0).width;
        let ow = c.size_of("Out", cap, 0).width;
        let d = Self::START_DOT;
        let gap = 4.0;
        let width = d + gap + iw + Self::START_WIRE + ow + gap + d;
        let mut x = (w.mid_x() - width / 2.0).round();
        let cy = (w.mid_y() - Self::START_RISE).round() + StepsCanvas::NODE.height / 2.0;
        c.fill_ellipse(CGRect::new(x, cy - d / 2.0, d, d), t.label3());
        x += d + gap;
        c.draw_text_in("In", CGRect::new(x, cy - 8.0, iw + 2.0, 16.0), cap, t.label3(), TextAlign::Left, 0.0, 0);
        x += iw;
        c.fill(CGRect::new(x + 4.0, (cy - 0.5).round(), Self::START_WIRE - 8.0, 1.0), t.separator());
        x += Self::START_WIRE;
        c.draw_text_in("Out", CGRect::new(x, cy - 8.0, ow + 2.0, 16.0), cap, t.label3(), TextAlign::Left, 0.0, 0);
        x += ow + gap;
        c.fill_ellipse(CGRect::new(x, cy - d / 2.0, d, d), t.label3());
        let mut y = cy + StepsCanvas::NODE.height / 2.0 + f64::from(spacing::SM);
        c.draw_text_in(
            &tr("No Pro grade on this clip yet"),
            CGRect::new(w.min_x(), y, w.width, 18.0),
            f64::from(type_size::BODY),
            t.label(),
            TextAlign::Center,
            0.0,
            0,
        );
        y += 22.0;
        c.draw_text_in(
            &tr("The first step adds a Color Graph effect. Your Simple grade stays as it is."),
            CGRect::new(w.min_x(), y, w.width, 16.0),
            cap,
            t.label3(),
            TextAlign::Center,
            0.0,
            0,
        );
    }

    fn wire_points(&self, w: &Wire) -> Vec<CGPoint> {
        let v = Wire::new(self.canvas.view_point(w.from), self.canvas.view_point(w.to), w.gap);
        (0..=24).map(|i| v.point(f64::from(i) / 24.0)).collect()
    }

    fn draw_graph(&self, c: &mut Canvas, t: &DrawTheme, model: Option<&ColorInspectorModel>, cx: &mut UiCx) {
        let Some(m) = model else { return };
        let Some(g) = m.graph() else { return };
        let l = self.canvas.layout();
        let lifted = self.wire_drag.and_then(|w| w.replacing);
        for w in self.canvas.wires().iter().filter(|w| w.link.is_none() || w.link != lifted) {
            c.stroke_polyline(&self.wire_points(w), 1.5, t.label3());
        }
        for w in self.canvas.key_wires().iter().filter(|w| w.link != lifted) {
            c.stroke_dashed(&self.wire_points(w), false, 1.0, 3.0, 3.0, 0.0, t.label3());
        }
        for w in self.canvas.preview_wires() {
            c.stroke_polyline(&self.wire_points(&w), 2.0, t.accent());
        }
        let by_id: BTreeMap<Id, &ColorStep> = g.steps().iter().map(|s| (s.id, s)).collect();
        let r0 = f64::from(radius::SMALL);
        let columns = g.columns();
        for (col, head, r) in self.canvas.mixers(&l) {
            let v = self.canvas.view_rect(&r);
            let layer = columns.get(col).is_some_and(|c| c.iter().skip(1).any(|s| s.kind == StepKind::Layer));
            c.fill_rounded(v, r0, t.fill());
            if layer {
                c.stroke_dashed_rounded(v, r0, 1.0, 3.0, 3.0, t.label3());
            } else {
                c.stroke_rounded(v, r0, 1.0, t.label3());
            }
            if m.selected_mixer == Some(head) {
                c.stroke_rounded(v.inset_by(-1.0, -1.0), r0 + 1.0, 2.0, t.accent());
            }
            c.draw_icon(
                if layer { SQIcon::Stack } else { SQIcon::Plus },
                CGPoint::new(v.mid_x() - 5.0, v.mid_y() - 5.0),
                10.0,
                t.label2(),
                None,
            );
            self.dots(c, t, v, false);
        }
        self.slot(
            c,
            t,
            m.graph_lut_choice(GraphLUTSlot::Input).map(|c| c.name),
            "Input color",
            self.canvas.view_rect(&l.in_slot),
        );
        self.slot(
            c,
            t,
            m.graph_lut_choice(GraphLUTSlot::Output).map(|c| c.name),
            "Output LUT",
            self.canvas.view_rect(&l.out_slot),
        );
        self.endpoint(c, t, "In", self.canvas.view_rect(&l.in_pill), true);
        self.endpoint(c, t, "Out", self.canvas.view_rect(&l.out_pill), false);
        let order: Vec<Id> = columns.iter().flatten().map(|s| s.id).collect();
        let number: BTreeMap<Id, usize> = order.iter().enumerate().map(|(i, id)| (*id, i + 1)).collect();
        let key_outs: BTreeSet<Id> = g.key_links.iter().filter_map(|k| k.from.step_id()).collect();
        let key_ins: Vec<GraphPort> = g.key_links.iter().map(|k| k.to).collect();
        let dragged = self.canvas.drag().map(|d| d.id);
        let node = |c: &mut Canvas, cx: &mut UiCx, id: Id| {
            if let (Some(s), Some(r)) = (by_id.get(&id), l.rects.get(&id)) {
                self.node(
                    c,
                    t,
                    m,
                    s,
                    number.get(&id).copied().unwrap_or(0),
                    self.canvas.view_rect(r),
                    key_ins.contains(&GraphPort::Step(id)),
                    key_outs.contains(&id),
                    cx,
                );
            }
        };
        for id in l.order.iter().filter(|id| Some(**id) != dragged) {
            node(c, cx, *id);
        }
        if let Some(id) = dragged {
            node(c, cx, id);
        }
        if let Some(f) = self.refused_flash.filter(|f| cx.now < f.2) {
            let center =
                if f.1 { self.canvas.key_dot_center(f.0, false, &l) } else { self.canvas.dot_center(f.0, false, &l) };
            if let Some(fc) = center {
                let b = self.canvas.view_point(fc);
                c.stroke_ellipse(CGRect::new(b.x - 6.0, b.y - 6.0, 12.0, 12.0), 2.0, t.red());
            }
        }
        if let Some(w) = &self.wire_drag {
            self.draw_wire_drag(c, t, w, &l);
        }
        if let Some(mq) = &self.marquee {
            let r = mq.rect();
            c.fill(r, t.accent().with_alpha(0.12));
            c.stroke_polygon(
                &[
                    CGPoint::new(r.min_x(), r.min_y()),
                    CGPoint::new(r.max_x(), r.min_y()),
                    CGPoint::new(r.max_x(), r.max_y()),
                    CGPoint::new(r.min_x(), r.max_y()),
                ],
                1.0,
                t.accent(),
            );
        }
        if let Some(h) = self.hover_insert.filter(|_| self.canvas.drag().is_none())
            && let Some(r) = self.canvas.insert_buttons(&l).iter().find(|b| b.0 == h).map(|b| b.1)
        {
            c.fill_ellipse(r, t.fill_pressed());
            c.draw_icon(SQIcon::Plus, CGPoint::new(r.mid_x() - 4.0, r.mid_y() - 4.0), 8.0, t.label(), None);
        }
    }

    fn dots(&self, c: &mut Canvas, t: &DrawTheme, r: CGRect, highlight: bool) {
        let d = StepsCanvas::DOT_SIZE;
        for x in [r.min_x(), r.max_x()] {
            c.fill_ellipse(
                CGRect::new(x - d / 2.0, r.mid_y() - d / 2.0, d, d),
                if highlight { t.accent() } else { t.label() },
            );
        }
    }

    /// The LUT slots: a named one is a raised tile with its kind under the name, an empty one the dashed "+ LUT".
    fn slot(&self, c: &mut Canvas, t: &DrawTheme, name: Option<String>, sub: &str, r: CGRect) {
        let rr = f64::from(radius::SMALL);
        if let Some(name) = name {
            c.stone_button(r, ButtonKind::Raised, Touch::default(), t);
            let name = tr(&name);
            let name =
                c.truncated_name(&name, f64::from(type_size::CAPTION), c.medium(), (r.width - 24.0).max(0.0)).shown;
            c.draw_text_in(
                &name,
                CGRect::new(r.min_x() + 12.0, r.min_y() + 5.0, (r.width - 24.0).max(0.0), 16.0),
                f64::from(type_size::CAPTION),
                t.label(),
                TextAlign::Left,
                0.0,
                c.medium(),
            );
            c.draw_text_in(
                &tr(sub),
                CGRect::new(r.min_x() + 12.0, r.min_y() + 20.0, (r.width - 24.0).max(0.0), 12.0),
                10.0,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        } else {
            c.stroke_dashed_rounded(r.inset_by(0.5, 0.5), rr, 1.0, 3.0, 3.0, t.label3());
            c.draw_text_in(
                &tr("+ LUT"),
                r.inset_by(3.0, 0.0),
                f64::from(type_size::CAPTION),
                t.label3(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
        self.dots(c, t, r, false);
    }

    fn endpoint(&self, c: &mut Canvas, t: &DrawTheme, s: &str, r: CGRect, dot_first: bool) {
        let d = Self::START_DOT;
        let gap = 4.0;
        let cap = f64::from(type_size::CAPTION);
        let tw = c.size_of(s, cap, 0).width;
        let dot_x = if dot_first { r.max_x() - d / 2.0 } else { r.min_x() - d / 2.0 };
        let text_x = if dot_first { dot_x - gap - tw } else { dot_x + d + gap };
        c.fill_ellipse(CGRect::new(dot_x, (r.mid_y() - d / 2.0).round(), d, d), t.label());
        c.draw_text_in(
            &tr(s),
            CGRect::new(text_x, r.mid_y() - 8.0, tw + 2.0, 16.0),
            cap,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn node(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        m: &ColorInspectorModel,
        s: &ColorStep,
        number: usize,
        r: CGRect,
        key_in: bool,
        key_out: bool,
        cx: &mut UiCx,
    ) {
        let rr = f64::from(radius::SMALL);
        let cap = f64::from(type_size::CAPTION);
        let sel = m.selected_steps.contains(&s.id) || m.selected_step() == Some(s.id);
        if s.enabled {
            // The kit's raised tile (Color/Node): the stone body, the selected one ringed in the accent.
            let touch = Touch { hovering: self.hover_step == Some(s.id), ..Touch::default() };
            c.stone_button(r, ButtonKind::Raised, touch, t);
        } else {
            c.stroke_rounded(r.inset_by(0.5, 0.5), rr, 1.0, t.separator());
        }
        if s.kind == StepKind::Layer {
            c.stroke_dashed_rounded(r.inset_by(0.5, 0.5), rr, 1.0, 3.0, 3.0, t.label3());
        }
        if sel {
            c.stroke_rounded(r.inset_by(0.75, 0.75), rr - 0.75, 1.5, t.accent());
        }
        self.dots(c, t, r, false);
        let d = StepsCanvas::DOT_SIZE;
        let k = StepsCanvas::key_dots(&r);
        let scale = r.width / StepsCanvas::NODE.width;
        let pts = [
            CGPoint::new(r.min_x() + (k.0.x - r.min_x()) * scale, r.max_y()),
            CGPoint::new(r.max_x() - (r.max_x() - k.1.x) * scale, r.max_y()),
        ];
        for (p, used) in pts.iter().zip([key_in, key_out]) {
            let o = CGRect::new(p.x - d / 2.0, p.y - d / 2.0, d, d);
            c.fill_ellipse(o, if used { t.label2() } else { t.content() });
            c.stroke_ellipse(o, 1.0, t.label3());
        }
        if r.height < 30.0 {
            // Zoomed out (30 Steps in a 240 pt panel): the tile keeps its number so no tile reads blank; the footer has the count.
            let size = (r.height - 4.0).min(10.0);
            let num = format!("{number:02}");
            if size >= 6.0 && c.size_of(&num, size, 0).width + 2.0 <= r.width {
                c.draw_text_in(
                    &num,
                    r,
                    size,
                    if s.enabled { t.label2() } else { t.label3() },
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
            return;
        }
        let eye = StepsCanvas::eye_rect(&r);
        if let Some((id, f)) = self.renaming.as_ref().filter(|x| x.0 == s.id) {
            let _ = id;
            let fr = Self::rename_frame(&r);
            f.draw(c, fr, t, true, cx);
        } else {
            // "01" small and quiet, then the name; the sub line below says what the Step changes.
            let num = format!("{number:02}");
            let nw = c.size_of(&num, 10.0, 0).width.ceil();
            c.draw_text_in(
                &num,
                CGRect::new(r.min_x() + 12.0, r.min_y() + 8.0, nw + 2.0, 16.0),
                10.0,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
            let nx = r.min_x() + 12.0 + nw + 5.0;
            let name_rect = CGRect::new(nx, r.min_y() + 8.0, (eye.min_x() - nx).max(0.0), 16.0);
            let label = tr(&s.label);
            let label = c.truncated_name(&label, cap, c.medium(), name_rect.width).shown;
            c.draw_text_in(
                &label,
                name_rect,
                cap,
                if s.enabled { t.label() } else { t.label3() },
                TextAlign::Left,
                0.0,
                c.medium(),
            );
            if !s.enabled {
                let w = c.size_of(&s.label, cap, 0).width.min(name_rect.width);
                c.fill(CGRect::new(name_rect.min_x(), name_rect.mid_y().round(), w, 1.0), t.label3());
            }
        }
        c.draw_icon(
            if s.enabled { SQIcon::Eye } else { SQIcon::EyeOff },
            CGPoint::new(eye.min_x() + 3.0, eye.mid_y() - 5.0),
            10.0,
            if s.enabled { t.label2() } else { t.label3() },
            None,
        );
        let sub_rect = CGRect::new(r.min_x() + 12.0, r.min_y() + 25.0, (r.width - 24.0).max(0.0), 14.0);
        let mix = if s.mix < 100.0 { Some(format!("{}%", s.mix.round() as i64)) } else { None };
        let mix_w = mix.as_ref().map_or(0.0, |m| c.size_of(m, 10.0, 0).width.ceil() + 6.0);
        c.draw_text_in(
            &tr(&Self::step_summary(s)),
            CGRect::new(sub_rect.min_x(), sub_rect.min_y(), (sub_rect.width - mix_w).max(0.0), sub_rect.height),
            10.0,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        if let Some(mix) = mix {
            c.draw_text_in(&mix, sub_rect, 10.0, t.label2(), TextAlign::Right, 0.0, 0);
        }
    }

    /// What a Step changes, in the kit's sub line: "Primaries · Curves".
    pub fn step_summary(s: &ColorStep) -> String {
        let parts: [(bool, &str); 5] = [
            (!s.primaries.is_neutral(), "Primaries"),
            (!(s.curves.is_neutral() && s.hue_curves.is_neutral()), "Curves"),
            (s.qualifier.is_some(), "Qualifier"),
            (s.window.is_some(), "Window"),
            (s.lut.is_some(), "LUT"),
        ];
        let on: Vec<&str> = parts.iter().filter(|p| p.0).map(|p| p.1).collect();
        if on.is_empty() { "No changes".to_string() } else { on.join(" \u{b7} ") }
    }

    fn draw_wire_drag(&self, c: &mut Canvas, t: &DrawTheme, w: &WireDrag, l: &Layout) {
        let start = if w.is_key {
            w.from.step_id().and_then(|id| self.canvas.key_dot_center(GraphPort::Step(id), true, l))
        } else {
            self.canvas.dot_center(w.from, true, l)
        };
        let Some(s) = start else { return };
        let a = self.canvas.view_point(s);
        let color = if w.refused { t.red() } else { t.accent() };
        if let Some(tgt) = w.target {
            let tc = if w.is_key {
                self.canvas.key_dot_center(tgt, false, l)
            } else {
                self.canvas.dot_center(tgt, false, l)
            };
            if let Some(tc) = tc {
                let b = self.canvas.view_point(tc);
                c.stroke_ellipse(CGRect::new(b.x - 6.0, b.y - 6.0, 12.0, 12.0), 2.0, color);
            }
        }
        let wire = Wire::new(a, w.point, -1);
        let pts: Vec<CGPoint> = (0..=24).map(|i| wire.point(f64::from(i) / 24.0)).collect();
        if w.is_key {
            c.stroke_dashed(&pts, false, 2.0, 3.0, 3.0, 0.0, color);
        } else {
            c.stroke_polyline(&pts, 2.0, color);
        }
    }

    fn rename_frame(node: &CGRect) -> CGRect {
        let eye = StepsCanvas::eye_rect(node);
        CGRect::new(node.min_x() + 2.0, node.min_y() + 3.0, (eye.min_x() - node.min_x() - 2.0).max(40.0), 18.0)
    }

    // MARK: Pointer

    fn hit_at(&self, m: Option<&ColorInspectorModel>, p: CGPoint) -> Option<Hit> {
        if !Self::shows_canvas(m) || !self.well().contains(p) {
            return None;
        }
        self.canvas.hit(self.local(p))
    }

    fn button_at(&self, m: Option<&ColorInspectorModel>, p: CGPoint) -> Option<StepsButton> {
        self.button_frames(m).into_iter().find(|f| f.1.contains(p)).map(|f| f.0)
    }

    /// The tip under the pointer: the footer buttons, a Step's full name, its eye, the connector dots, the insert buttons,
    /// the mixers and the graph's In / Out LUT slots (the Mac layer list's LUT chip tips).
    pub fn help(&self, model: Option<&ColorInspectorModel>, p: CGPoint) -> Option<String> {
        if let Some(b) = self.button_at(model, p) {
            return Some(tr(match b {
                StepsButton::StartEmpty => "Start a Color Graph with one empty Step",
                StepsButton::StartFromSimple => "Start a Color Graph from the values of the Simple grade",
                StepsButton::Tidy => "Line the Steps up in their columns",
                StepsButton::Fit => "Show the whole graph",
                StepsButton::Add => "Add a Step after the selected one",
                StepsButton::Duplicate => "Duplicate the selected Step",
                StepsButton::Delete => "Delete the selected Step",
            }));
        }
        let h = self.hit_at(model, p)?;
        let step = |id: Id| model.and_then(|m| m.graph()).and_then(|g| g.steps().iter().find(|s| s.id == id));
        match h {
            Hit::Step(id) => step(id).map(|s| tr(&s.label)),
            Hit::Eye(id) => step(id).map(|s| tr(if s.enabled { "Turn this Step off" } else { "Turn this Step on" })),
            Hit::Insert(_) => Some(tr("Insert a Step here")),
            Hit::Mixer(_) => Some(tr("Mixer: joins the Steps of its column")),
            Hit::DotOut(_) | Hit::KeyOut(_) => Some(tr("Drag to an input to wire")),
            Hit::DotIn(_) | Hit::KeyIn(_) => Some(tr("Drag the wire away to move or remove it")),
            Hit::Input => Some(SQL10n::format(
                "In LUT: %@",
                &[&tr(&model
                    .and_then(|m| m.graph_lut_choice(GraphLUTSlot::Input))
                    .map_or("None (built-in conversion)".to_string(), |c| c.name))],
            )),
            Hit::Output => Some(SQL10n::format(
                "Out LUT: %@",
                &[&tr(&model
                    .and_then(|m| m.graph_lut_choice(GraphLUTSlot::Output))
                    .map_or("None".to_string(), |c| c.name))],
            )),
        }
    }

    pub fn mouse_moved(&mut self, host: &ColorGradeController, cx: &mut UiCx, p: Option<CGPoint>) {
        if self.renaming.is_some()
            && let Some(p) = p.filter(|p| self.rename_rect.is_some_and(|r| r.contains(*p)))
        {
            let _ = p;
            cx.hover.request(Some(DrawCursor::IBeam));
        }
        if self.canvas.drag().is_some() || self.wire_drag.is_some() || self.marquee.is_some() {
            return;
        }
        let m = host.model();
        self.hover_button = p.and_then(|p| self.button_at(m, p));
        let h = p.and_then(|p| self.hit_at(m, p));
        self.hover_insert = if let Some(Hit::Insert(id)) = h { Some(id) } else { None };
        self.hover_step = match h {
            Some(Hit::Step(id)) | Some(Hit::Eye(id)) => Some(id),
            _ => None,
        };
    }

    /// ColorStepsGraphView.scrollWheel / magnify: the host gesture's raw `scrollingDelta` when there is one.
    pub fn scroll(
        &mut self,
        host: &ColorGradeController,
        cx: &UiCx,
        p: CGPoint,
        dx: f64,
        dy: f64,
        modifiers: InputModifiers,
    ) {
        if !Self::shows_canvas(host.model()) {
            return;
        }
        let (mut dx, mut dy) = (dx, dy);
        if let Some(g) = &cx.gesture {
            match g.kind {
                GestureKind::Magnify(m) => {
                    self.canvas.zoom_by(1.0 + m, self.local(p));
                    return;
                }
                GestureKind::SmartMagnify => return,
                GestureKind::Scroll => {
                    dx = g.delta_x;
                    dy = g.delta_y;
                }
            }
        }
        if modifiers.contains(InputModifiers::COMMAND) || modifiers.contains(InputModifiers::OPTION) {
            self.canvas.zoom_by((dy * 0.01).exp(), self.local(p));
        } else {
            self.canvas.pan_by(dx, dy);
        }
    }

    fn menu(&mut self, items: Vec<SQMenuItem>, p: CGPoint) {
        if items.is_empty() {
            return;
        }
        self.menus.push(GradeMenuRequest { items, anchor: CGRect::new(p.x, p.y, 1.0, 1.0) });
    }

    /// Presses; `measure` is a canvas the rename field measures its caret with (nil: the caret stays).
    pub fn mouse_down(
        &mut self,
        host: &mut ColorGradeHost,
        cx: &UiCx,
        p: CGPoint,
        modifiers: InputModifiers,
        click_count: Option<i64>,
        measure: Option<&Canvas>,
    ) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        if let (Some((_, field)), Some(fr)) = (self.renaming.as_mut(), self.rename_rect)
            && fr.contains(p)
            && !modifiers.contains(InputModifiers::SECONDARY)
        {
            // Inside the open field: the caret goes under the pointer, the field stays open.
            let caret = measure.and_then(|c| field.caret_index(c, p.x, fr));
            field.mouse_down(caret, n);
            return;
        }
        if self.renaming.is_some() {
            self.end_rename(host, true);
        }
        self.refused_flash = None;
        if modifiers.contains(InputModifiers::SECONDARY) {
            self.right_click(host, p);
            return;
        }
        let model_ref = host.model();
        if let Some(b) = self.button_at(model_ref, p) {
            self.pressed_button = Some(b);
            return;
        }
        if model_ref.is_none() {
            return;
        }
        let shift = modifiers.contains(InputModifiers::SHIFT);
        let command = modifiers.contains(InputModifiers::COMMAND);
        let q = self.local(p);
        let hit = self.hit_at(model_ref, p);
        let menus = self.menus_for();
        match hit {
            Some(Hit::DotOut(port)) => {
                if let Some(m) = host.model_mut() {
                    m.selected_mixer = None;
                }
                self.wire_drag = Some(WireDrag {
                    from: port,
                    point: q,
                    target: None,
                    refused: false,
                    is_key: false,
                    replacing: None,
                });
            }
            Some(Hit::DotIn(port)) => {
                if let Some(k) = self.canvas.wire_into(port) {
                    self.wire_drag = Some(WireDrag {
                        from: k.from,
                        point: q,
                        target: None,
                        refused: false,
                        is_key: false,
                        replacing: Some(k),
                    });
                }
            }
            Some(Hit::KeyOut(id)) => {
                self.wire_drag = Some(WireDrag {
                    from: GraphPort::Step(id),
                    point: q,
                    target: None,
                    refused: false,
                    is_key: true,
                    replacing: None,
                });
            }
            Some(Hit::KeyIn(port)) => {
                if let Some(k) = self.canvas.key_links.iter().find(|k| k.to == port).copied() {
                    self.wire_drag = Some(WireDrag {
                        from: k.from,
                        point: q,
                        target: None,
                        refused: false,
                        is_key: true,
                        replacing: Some(k),
                    });
                }
            }
            Some(Hit::Mixer(head)) => {
                if let Some(m) = host.model_mut() {
                    m.selected_mixer = Some(head);
                }
                self.canvas.begin_mixer_drag(head, q);
            }
            Some(Hit::Input) => {
                let items = host.model().map(|m| menus.lut_items(m, LUTTarget::GraphInput)).unwrap_or_default();
                self.menu(items, p);
            }
            Some(Hit::Output) => {
                let items = host.model().map(|m| menus.lut_items(m, LUTTarget::GraphOutput)).unwrap_or_default();
                self.menu(items, p);
            }
            Some(Hit::Eye(id)) => {
                if let Some(m) = host.model_mut()
                    && let Some(on) = m.step(id).map(|s| s.enabled)
                {
                    m.set_step_enabled(id, !on);
                }
                host.pump();
            }
            Some(Hit::Insert(id)) => self.menu(menus.insert_menu_items(id), p),
            Some(Hit::Step(id)) => {
                let Some(m) = host.model_mut() else { return };
                m.selected_mixer = None;
                if n >= 2 && !shift && !command {
                    m.select_step(id, false);
                    host.pump();
                    self.begin_rename(host, id);
                    return;
                }
                let set = m.selected_steps.clone();
                if command {
                    m.select_step(id, true);
                } else if shift {
                    self.toggle_on_click = Some(id);
                    if !set.contains(&id) {
                        m.select_step(id, false);
                    }
                } else if set.contains(&id) && set.len() > 1 {
                    self.collapse_on_click = Some(id);
                    m.set_selected_step(Some(id));
                } else {
                    m.select_step(id, false);
                }
                let group: Vec<Id> = if m.selected_steps.contains(&id) {
                    m.selected_steps.iter().copied().collect()
                } else {
                    Vec::new()
                };
                self.canvas.begin_drag(id, q, if shift { &[] } else { &group }, shift);
                host.pump();
            }
            None => {
                if !Self::shows_canvas(host.model()) || !self.well().contains(p) {
                    return;
                }
                let Some(m) = host.model_mut() else { return };
                m.selected_mixer = None;
                let base = if shift || command { m.selected_steps.clone() } else { BTreeSet::new() };
                self.marquee = Some(Marquee { start: q, current: q, base });
            }
        }
    }

    fn aim(&self, host: &ColorGradeController, w: &WireDrag, q: CGPoint) -> (Option<StepsPort>, bool) {
        let target: Option<StepsPort> = if w.is_key {
            match self.canvas.hit(q) {
                Some(Hit::KeyIn(port)) => Some(port),
                Some(Hit::Step(id)) | Some(Hit::Eye(id)) => Some(GraphPort::Step(id)),
                Some(Hit::Mixer(head)) => Some(GraphPort::Mixer(head)),
                _ => None,
            }
        } else {
            self.canvas.input_port(q)
        };
        let (Some(t), Some(mut g)) = (target, host.model().and_then(|m| m.graph()).cloned()) else {
            return (None, false);
        };
        if let Some(k) = w.replacing {
            if w.is_key {
                g.disconnect_key(k);
            } else {
                g.disconnect(k);
            }
        }
        let why = if w.is_key { w.from.step_id().and_then(|id| g.key_refusal(id, t)) } else { g.refusal(w.from, t) };
        (Some(t), why.is_some())
    }

    pub fn mouse_dragged(&mut self, host: &mut ColorGradeHost, p: CGPoint) {
        let q = self.local(p);
        if let Some(mut w) = self.wire_drag {
            w.point = q;
            let (t, refused) = self.aim(&*host.controller, &w, q);
            w.target = t;
            w.refused = refused;
            self.wire_drag = Some(w);
        } else if let Some(mut m) = self.marquee.take() {
            m.current = q;
            let mut ids: BTreeSet<Id> = self.canvas.steps_in(&m.rect()).into_iter().collect();
            ids.extend(m.base.iter().copied());
            self.marquee = Some(m);
            if let Some(model) = host.model_mut() {
                model.select_steps(&ids, false);
            }
        } else if self.canvas.drag().is_some() {
            self.canvas.continue_drag(q);
            if self.canvas.drag().is_some_and(|d| d.moved) {
                self.collapse_on_click = None;
                self.toggle_on_click = None;
            }
        }
    }

    pub fn mouse_up(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, p: CGPoint, measure: &dyn Fn(&str) -> f64) {
        self.mouse_up_inner(host, cx, p, measure);
        self.mouse_moved(&*host.controller, cx, Some(p));
    }

    fn mouse_up_inner(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, p: CGPoint, measure: &dyn Fn(&str) -> f64) {
        if let Some(b) = self.pressed_button.take() {
            if self.button_at(host.model(), p) != Some(b) {
                return;
            }
            match b {
                StepsButton::StartEmpty => {
                    if let Some(m) = host.model_mut() {
                        m.start_empty_graph();
                    }
                    host.pump();
                }
                StepsButton::StartFromSimple => {
                    if let Some(m) = host.model_mut() {
                        m.start_from_simple();
                    }
                    host.pump();
                }
                StepsButton::Tidy => self.tidy_up(host, measure),
                StepsButton::Fit => self.fit_view(host, measure),
                StepsButton::Add => {
                    let items = self.add_menu_items(host.model());
                    let at = self
                        .button_frames(host.model())
                        .iter()
                        .find(|f| f.0 == b)
                        .map_or(p, |f| CGPoint::new(f.1.min_x(), f.1.max_y()));
                    self.menu(items.unwrap_or_default(), at);
                }
                StepsButton::Duplicate | StepsButton::Delete => {
                    if let Some(m) = host.model_mut()
                        && let Some(id) = m.selected_step()
                    {
                        if b == StepsButton::Duplicate {
                            m.duplicate_step(id);
                        } else {
                            m.remove_step(id);
                        }
                    }
                    host.pump();
                }
            }
            return;
        }
        if let Some(w) = self.wire_drag.take() {
            self.finish(host, cx, w);
            return;
        }
        if self.marquee.take().is_some() {
            return;
        }
        let collapse = self.collapse_on_click.take();
        let toggle = self.toggle_on_click.take();
        let Some(d) = self.canvas.drag().cloned() else { return };
        let frozen = self.positions_before_drop(&d);
        let Some(drop) = self.canvas.end_drag() else { return };
        let all_positions = self.canvas.group_positions(&d);
        let Some(model) = host.model_mut() else { return };
        match drop {
            Drop::Click => {
                if let Some(c) = collapse {
                    model.select_step(c, false);
                }
                if let Some(t) = toggle {
                    model.select_step(t, true);
                }
            }
            Drop::Place(pos) => {
                if d.is_mixer {
                    model.set_mixer_position(d.id, Some(pos));
                } else {
                    let mut all = all_positions;
                    all.insert(d.id, pos);
                    model.place_steps(&all, &frozen);
                }
            }
            Drop::InsertOnto(link) => {
                model.insert_step(d.id, link);
            }
            Drop::Extract(pos) => model.extract_step(d.id, pos),
        }
        host.pump();
    }

    fn positions_before_drop(&self, d: &Drag) -> BTreeMap<Id, StepPosition> {
        if d.is_mixer {
            return BTreeMap::new();
        }
        let mut still = self.canvas.clone();
        still.cancel_drag();
        let l = still.layout();
        let mut moving: BTreeSet<Id> = d.group.keys().copied().collect();
        moving.insert(d.id);
        let mut out = BTreeMap::new();
        for col in &self.canvas.columns {
            if col.len() > 1
                && col.iter().any(|id| moving.contains(id))
                && let Some(head) = col.first()
                && let Some(r) = l.mixers.get(head)
            {
                out.insert(*head, StepPosition { x: r.min_x(), y: r.min_y() });
            }
        }
        out
    }

    /// A wire dropped: connected, moved, removed (on empty canvas) or refused (it snaps back, the target flashes red).
    fn finish(&mut self, host: &mut ColorGradeHost, cx: &UiCx, w: WireDrag) {
        let Some(model) = host.model_mut() else { return };
        let Some(t) = w.target else {
            if let Some(k) = w.replacing {
                if w.is_key {
                    model.disconnect_key(k);
                } else {
                    model.disconnect(k);
                }
            }
            host.pump();
            return;
        };
        if w.refused {
            self.refused_flash = Some((t, w.is_key, cx.now + Self::REFUSED_FLASH_SECONDS));
            return;
        }
        if w.replacing.is_some_and(|k| k.from == w.from && k.to == t) {
            return;
        }
        if w.is_key {
            if let Some(k) = w.replacing {
                model.rewire_key(k, w.from, t);
            } else if let Some(id) = w.from.step_id() {
                model.connect_key(id, t);
            }
        } else if let Some(k) = w.replacing {
            model.rewire(k, w.from, t);
        } else {
            model.connect(w.from, t);
        }
        host.pump();
    }

    fn right_click(&mut self, host: &mut ColorGradeHost, p: CGPoint) {
        let hit = self.hit_at(host.model(), p);
        let menus = self.menus_for();
        match hit {
            Some(Hit::Step(id)) | Some(Hit::Eye(id)) => {
                let items = {
                    let Some(model) = host.model_mut() else { return };
                    if !model.selected_steps.contains(&id) {
                        model.select_step(id, false);
                    } else {
                        model.set_selected_step(Some(id));
                    }
                    model.selected_mixer = None;
                    menus.step_menu_items(model, id)
                };
                host.pump();
                self.menu(items, p);
            }
            Some(Hit::Mixer(head)) => {
                let items = {
                    let Some(model) = host.model_mut() else { return };
                    model.selected_mixer = Some(head);
                    menus.mixer_menu_items(model, head)
                };
                self.menu(items, p);
            }
            Some(Hit::DotOut(_)) | Some(Hit::DotIn(_)) | Some(Hit::KeyOut(_)) | Some(Hit::KeyIn(_)) => {}
            Some(Hit::Insert(id)) => self.menu(menus.insert_menu_items(id), p),
            Some(Hit::Input) => {
                let items = host.model().map(|m| menus.lut_items(m, LUTTarget::GraphInput)).unwrap_or_default();
                self.menu(items, p);
            }
            Some(Hit::Output) => {
                let items = host.model().map(|m| menus.lut_items(m, LUTTarget::GraphOutput)).unwrap_or_default();
                self.menu(items, p);
            }
            None => {
                if Self::shows_canvas(host.model()) {
                    let items = host.model().map(|m| menus.canvas_menu_items(m)).unwrap_or_default();
                    self.menu(items, p);
                }
            }
        }
    }

    /// Runs the rows the menus queued; host-only parts come back as requests, Tidy up refits the view.
    pub fn run_menu_commands(&mut self, host: &mut ColorGradeHost, measure: &dyn Fn(&str) -> f64) {
        let menus = self.menus_for();
        for cmd in self.sink.drain() {
            let req = {
                let Some(m) = host.model_mut() else { return };
                menus.apply(m, cmd)
            };
            host.pump();
            match req {
                Some(GraphMenuHostRequest::Rename(id)) => self.begin_rename(host, id),
                Some(GraphMenuHostRequest::TidyUp) => self.tidy_up(host, measure),
                Some(GraphMenuHostRequest::ChooseLutFile(t)) => self.requests.push(StepsHostRequest::ChooseLutFile(t)),
                Some(GraphMenuHostRequest::ImportDecision(id)) => {
                    self.requests.push(StepsHostRequest::ImportDecision(id))
                }
                None => {}
            }
        }
    }

    // MARK: Renaming

    pub fn begin_rename(&mut self, host: &ColorGradeHost, id: Id) {
        let Some(s) = host.model().and_then(|m| m.step(id)) else { return };
        let mut f = TextFieldControl::new(&s.label);
        f.mouse_down(None, 1);
        self.renaming = Some((id, f));
    }

    pub fn end_rename(&mut self, host: &mut ColorGradeHost, commit: bool) {
        let Some((id, mut field)) = self.renaming.take() else { return };
        self.rename_rect = None;
        if commit && let Some(text) = field.commit() {
            if let Some(m) = host.model_mut() {
                m.rename_step(id, &text);
            }
            host.pump();
            return;
        }
        field.cancel();
    }

    // MARK: Keys

    /// Delete removes the selected Steps (or the mixer), Command-A selects all, Option-Left/Right moves the Step, Escape
    /// cancels a gesture. Returns false when the key is not this panel's.
    pub fn key(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, k: InputKey, modifiers: InputModifiers) -> bool {
        if self.renaming.is_some() {
            match k {
                InputKey::Enter => self.end_rename(host, true),
                InputKey::Escape => self.end_rename(host, false),
                _ => {
                    let done = self.renaming.as_mut().and_then(|(id, f)| f.key(k, modifiers, cx).map(|d| (*id, d)));
                    if let Some((id, text)) = done {
                        self.renaming = None;
                        if let Some(m) = host.model_mut() {
                            m.rename_step(id, &text);
                        }
                        host.pump();
                    }
                }
            }
            return true;
        }
        let model = host.model();
        if model.is_none() || Self::offers_start(model) {
            return false;
        }
        let mixer = model.and_then(|m| m.selected_mixer);
        if let Some(head) = mixer {
            match k {
                InputKey::Delete | InputKey::Backspace => {
                    if let Some(m) = host.model_mut() {
                        m.remove_mixer(head);
                    }
                    host.pump();
                    return true;
                }
                InputKey::Escape => {
                    self.cancel_gesture();
                    if let Some(m) = host.model_mut() {
                        m.selected_mixer = None;
                    }
                    return true;
                }
                _ => {}
            }
        }
        let has_selection = model.is_some_and(|m| m.selected_step().is_some() || !m.selected_steps.is_empty());
        if !has_selection {
            return false;
        }
        let Some(m) = host.model_mut() else { return false };
        match k {
            InputKey::Delete | InputKey::Backspace => m.remove_selected_steps(),
            InputKey::Character('a') if modifiers.contains(InputModifiers::COMMAND) => {
                let all: BTreeSet<Id> = m.graph().map(|g| g.steps().iter().map(|s| s.id).collect()).unwrap_or_default();
                m.select_steps(&all, false);
            }
            InputKey::Left if modifiers.contains(InputModifiers::OPTION) => {
                if let Some(id) = m.selected_step() {
                    m.move_step_by(id, -1);
                }
            }
            InputKey::Right if modifiers.contains(InputModifiers::OPTION) => {
                if let Some(id) = m.selected_step() {
                    m.move_step_by(id, 1);
                }
            }
            InputKey::Escape => self.cancel_gesture(),
            _ => return false,
        }
        host.pump();
        true
    }

    pub fn cancel_gesture(&mut self) {
        self.canvas.cancel_drag();
        self.wire_drag = None;
        self.marquee = None;
    }

    /// The red ring of a refused drop is still up (hosts that redraw on demand keep drawing until it ends).
    pub fn is_flashing(&self, now: f64) -> bool {
        self.refused_flash.is_some_and(|f| now < f.2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_editor_session::{ColorClipboard, EditorSession};

    fn measure(s: &str) -> f64 {
        s.chars().count() as f64 * 6.0
    }

    #[test]
    fn the_well_leaves_room_for_the_footer() {
        let d = ColorStepsDraw::new();
        let w = d.well();
        // Edge to edge between the 34 pt title row and the 34 pt hint row (redesign R4d).
        assert_eq!((w.min_x(), w.min_y()), (0.0, ColorStepsDraw::HEADER));
        assert_eq!(w.width, 480.0);
        assert_eq!(w.height, 300.0 - ColorStepsDraw::HEADER - ColorStepsDraw::FOOTER);
    }

    #[test]
    fn the_marquee_rect_is_normalized() {
        let m = Marquee { start: CGPoint::new(30.0, 40.0), current: CGPoint::new(10.0, 60.0), base: BTreeSet::new() };
        let r = m.rect();
        assert_eq!((r.x, r.y, r.width, r.height), (10.0, 40.0, 20.0, 20.0));
    }

    #[test]
    fn the_summary_counts_steps_and_columns() {
        use super::super::color_inspector_model::ColorInspectorModel;
        use sq_core_time::SequentialIds;
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        assert_eq!(ColorStepsDraw::summary(Some(&m)), "0 steps, 0 in series");
        m.start_empty_graph();
        assert_eq!(ColorStepsDraw::summary(Some(&m)), "1 step, 1 in series");
        m.add_step_at_end(StepKind::Parallel);
        assert_eq!(ColorStepsDraw::summary(Some(&m)), "2 steps, 1 in series");
    }

    #[test]
    fn the_start_page_shows_without_a_graph_and_the_canvas_with_one() {
        use super::super::color_inspector_model::ColorInspectorModel;
        use sq_core_time::SequentialIds;
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        assert!(ColorStepsDraw::offers_start(Some(&m)));
        assert!(!ColorStepsDraw::shows_canvas(Some(&m)));
        assert!(!ColorStepsDraw::offers_start(None));
        let d = ColorStepsDraw::new();
        let frames = d.button_frames(Some(&m));
        assert_eq!(
            frames.iter().map(|f| f.0).collect::<Vec<_>>(),
            vec![StepsButton::StartEmpty, StepsButton::StartFromSimple]
        );
        assert!(frames[0].1.max_x() < frames[1].1.min_x());
        m.start_empty_graph();
        assert!(ColorStepsDraw::shows_canvas(Some(&m)));
        let frames = d.button_frames(Some(&m));
        // The footer's Fit and Tidy up, then the header's Delete, Duplicate and Add (right to left).
        assert_eq!(
            frames.iter().map(|f| f.0).collect::<Vec<_>>(),
            vec![StepsButton::Fit, StepsButton::Tidy, StepsButton::Delete, StepsButton::Duplicate, StepsButton::Add]
        );
        assert!(frames[1].1.max_x() < frames[0].1.min_x());
        assert!(frames[4].1.max_x() < frames[3].1.min_x() && frames[3].1.max_x() < frames[2].1.min_x());
        assert!(frames[2..].iter().all(|f| f.1.max_y() <= ColorStepsDraw::HEADER));
        assert!(
            d.button_at(Some(&m), CGPoint::new(frames[0].1.mid_x(), frames[0].1.mid_y())) == Some(StepsButton::Fit)
        );
    }

    #[test]
    fn the_header_tools_act_on_the_selected_step() {
        use super::super::color_inspector_model::ColorInspectorModel;
        use sq_core_time::SequentialIds;
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        m.start_empty_graph();
        assert!(ColorStepsDraw::tool_enabled(StepsButton::Add, Some(&m)));
        assert!(!ColorStepsDraw::tool_enabled(StepsButton::Add, None));
        let n = m.graph().unwrap().steps().len();
        let id = m.graph().unwrap().steps()[0].id;
        m.set_selected_step(Some(id));
        assert!(ColorStepsDraw::tool_enabled(StepsButton::Duplicate, Some(&m)));
        m.duplicate_step(id);
        assert_eq!(m.graph().unwrap().steps().len(), n + 1);
        let sel = m.selected_step().unwrap();
        m.remove_step(sel);
        assert_eq!(m.graph().unwrap().steps().len(), n);
        assert!(StepsButton::Add.is_tool());
        assert!(!StepsButton::Fit.is_tool());
    }

    #[test]
    fn a_step_tile_sub_line_lists_what_it_changes() {
        use super::super::color_inspector_model::ColorInspectorModel;
        use sq_core_time::SequentialIds;
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        m.start_empty_graph();
        let s = m.graph().unwrap().steps()[0].clone();
        assert_eq!(ColorStepsDraw::step_summary(&s), "No changes");
        // The kit's tile sizes: a Step 140 x 48, an empty LUT slot 90 x 36, a named one at least 120 wide.
        assert_eq!((StepsCanvas::NODE.width, StepsCanvas::NODE.height), (140.0, 48.0));
        assert_eq!((StepsCanvas::SLOT.width, StepsCanvas::SLOT.height), (90.0, 36.0));
        assert_eq!(StepsCanvas::slot_width(10.0, true), 120.0);
    }

    #[test]
    fn help_names_the_buttons_and_the_hit_things() {
        use super::super::color_inspector_model::ColorInspectorModel;
        use sq_core_time::SequentialIds;
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        m.start_empty_graph();
        let mut d = ColorStepsDraw::new();
        d.canvas.columns = m
            .graph()
            .map(|g| g.columns().iter().map(|c| c.iter().map(|s| s.id).collect()).collect())
            .unwrap_or_default();
        d.canvas.fit(CGSize::new(464.0, 264.0), 16.0);
        let l = d.canvas.layout();
        let r = d.canvas.view_rect(&l.rects.values().next().copied().unwrap_or_default());
        let w = d.well();
        let p = CGPoint::new(w.min_x() + r.mid_x(), w.min_y() + r.mid_y());
        assert_eq!(d.help(Some(&m), p).as_deref(), Some("Step 1"));
        let tidy = d.button_frames(Some(&m)).into_iter().find(|f| f.0 == StepsButton::Tidy).map(|f| f.1);
        let tidy = tidy.unwrap_or_default();
        assert_eq!(
            d.help(Some(&m), CGPoint::new(tidy.mid_x(), tidy.mid_y())).as_deref(),
            Some("Line the Steps up in their columns")
        );
        assert_eq!(measure("abc"), 18.0);
        let _ = (ColorClipboard::new(), std::marker::PhantomData::<EditorSession>);
    }
}
