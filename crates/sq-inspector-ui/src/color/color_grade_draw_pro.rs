// Swift: Draw/ColorGradeDraw+Pro.swift
//! The Pro grade page of the Color panel (the Mac `ColorGraphPage`): the empty state, the layer list, the Step's path line,
//! the warning bands, the tab row and the Primaries tab (a 2 x 2 grid of wheels, Saturation, Contrast, Pivot). The other
//! tabs are in `color_grade_draw_pro_tabs`. Same logic, same session actions; only the drawing is portable.

use super::color_grade_controller::ColorGradeController;
use super::color_grade_draw::{
    ColorGradeDraw, ColorGradeHost, Control, DrawMenuCommand, GradeFileRequest, Mac, Row, RowStyle, Slider, Wheel,
};
use super::color_graph_menus::{ColorGraphMenus, LUTTarget};
use super::color_inspector_model::ColorInspectorModel;
use super::color_inspector_model_graph::GraphLUTSlot;
use super::color_inspector_model_graph_detail::StepPrimaryRow;
use super::color_wheel_math::PrimaryWheel;
use super::geom::offset_by;
use sq_core_color::{ColorGraphExt, ColorGraphWiringExt, StepBlend};
use sq_core_model::{ColorStep, LayerMixMode};
use sq_core_time::Id;
use sq_draw::inspector::InspectorDraw;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{metrics, radius, spacing, type_size};
use sq_draw::{Canvas, DrawTheme, InputModifiers, TextAlign, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

fn tr(s: &str) -> String {
    SQL10n::string(s)
}

impl ColorGradeDraw {
    // shortcut: no "Effects" tab. A Step cannot hold effects yet (no `ColorStep` field, no render stage after the Step's color
    // work, no project file entry), so the tab was a dead "Add effect" popup. Bring it back with that feature.
    pub const PRO_TAB_TITLES: [&'static str; 5] = ["Primaries", "Curves", "Qualifier", "Window", "LUT"];
    pub const LIST_ROW_HEIGHT: f64 = 28.0;
    pub const LIST_FOOTER_HEIGHT: f64 = 36.0;
    pub const EMPTY_HEIGHT: f64 = 96.0;
    /// The gap above the Experimental notice.
    pub const NOTICE_TOP: f64 = 8.0;
    pub const TAB_ROW_HEIGHT: f64 = metrics::PANEL_HEADER as f64;
    /// A row of controls (the Mac `ColorFormRow`): the capsule plus 4 above and below.
    pub const FORM_ROW_HEIGHT: f64 = metrics::CAPSULE as f64 + 8.0;
    pub const WIRING_NOTICE: &'static str = "Free wiring is saved. The picture still follows the Step order.";
    pub const WHEEL_SIZE: f64 = 96.0;
    pub const WHEEL_TITLE_HEIGHT: f64 = 20.0;
    pub const MASTER_BELOW: f64 = 20.0;
    pub const WHEEL_TOP: f64 = 6.0;
    pub const WHEEL_CELL: f64 = 145.0;
    pub const FOOTNOTE_LINE: f64 = 13.0;

    /// `ceil(NSString.size)` of each tab title in the Mac tab strip, regular and Medium (the selected tab), at the 11 pt UI
    /// font. The atlas measures from whole font-unit advances and is up to 0.6 pt off the Mac's sub-pixel width, which
    /// moved tabs by up to 1.5 pt. The table is English only, like Swift's `macTabWidths`: a translated title (every title
    /// has a German text) is measured by the atlas.
    fn mac_tab_width(s: &str, bold: bool) -> Option<f64> {
        let (r, m) = match s {
            "Primaries" => (50.0, 51.0),
            "Curves" => (37.0, 38.0),
            "Qualifier" => (45.0, 46.0),
            "Window" => (42.0, 43.0),
            "LUT" => (22.0, 22.0),
            "Effects" => (37.0, 39.0),
            _ => return None,
        };
        Some(if bold { m } else { r })
    }

    pub(crate) fn tab_text_width(&self, s: &str, size: f64, bold: bool) -> f64 {
        if size == 11.0
            && tr(s) == s
            && let Some(w) = Self::mac_tab_width(s, bold)
        {
            return w;
        }
        self.text_width(s, size, bold)
    }

    pub(crate) fn button_width(&self, s: &str) -> f64 {
        (self.text_width(s, f64::from(type_size::BODY), false) + InspectorDraw::BUTTON_PADDING * 2.0).ceil()
    }

    pub(crate) fn wrap_lines(&self, s: &str, width: f64, size: f64) -> Vec<String> {
        // shortcut: a character-count estimate until the canvas wraps with the atlas, upgrade when `rows` can measure.
        let text = tr(s);
        let per_line = ((width / (size * 0.56)).floor() as usize).max(1);
        let mut lines: Vec<String> = Vec::new();
        let mut cur = String::new();
        for word in text.split_whitespace() {
            if !cur.is_empty() && cur.chars().count() + 1 + word.chars().count() > per_line {
                lines.push(std::mem::take(&mut cur));
            }
            if !cur.is_empty() {
                cur.push(' ');
            }
            cur.push_str(word);
        }
        if !cur.is_empty() || lines.is_empty() {
            lines.push(cur);
        }
        lines
    }

    // MARK: Rows

    /// No Step selected: the controls draw disabled and write nowhere (the id matches no Step).
    pub(crate) const NO_STEP: Id = Id::NIL;

    pub(crate) fn pro_rows(&self, model: &ColorInspectorModel, steps_shown: bool, add: &mut dyn FnMut(Row)) {
        let w = self.size.width;
        let inset = Mac::INSET;
        let cap = f64::from(metrics::CAPSULE);
        let fs = f64::from(type_size::BODY);
        let mid = |h: f64, ch: f64| ((h - ch) / 2.0).round();
        let shows_strip = !steps_shown;
        let Some(g) = model.graph() else {
            use sq_draw::experimental::{self, Feature};
            let notice = experimental::prefs().shows_notice(Feature::ProGrading);
            if notice {
                let text = format!("{} {}", experimental::LEAD, Feature::ProGrading.notice());
                let box_w = w - 2.0 * inset;
                let lines = self.wrap_lines(&text, experimental::notice_text_width(box_w), 11.0).len();
                let bh = experimental::notice_height(lines);
                let close = sq_draw::close_x::hit_rect(experimental::notice_close(CGRect::new(
                    inset,
                    Self::NOTICE_TOP,
                    box_w,
                    bh,
                )));
                let n =
                    Row::new(None, RowStyle::Notice, Self::NOTICE_TOP + bh + 4.0, vec![(Control::CloseNotice, close)]);
                add(n);
            }
            // Under the notice the empty state sits tighter (the kit: 21 pt below the box).
            let eh = if notice { Self::EMPTY_HEIGHT - 24.0 } else { Self::EMPTY_HEIGHT };
            let mut empty = Row::new(Some("No Pro grade yet"), RowStyle::Empty, eh, Vec::new());
            empty.summary = Some(
                if shows_strip {
                    "Nothing in your Simple grade changes."
                } else {
                    "Start from the graph below. Nothing in your Simple grade changes."
                }
                .to_string(),
            );
            add(empty);
            if shows_strip {
                let h = Mac::POPUP_ROW;
                let a = self.button_width("Start empty");
                let b = self.button_width("Start from Simple grade");
                let bx = w - inset - b;
                let ax = bx - f64::from(spacing::SM) - a;
                add(Row::plain(
                    None,
                    h,
                    vec![
                        (Control::StartEmpty, CGRect::new(ax, mid(h, cap), a, cap)),
                        (Control::StartFromSimple, CGRect::new(bx, mid(h, cap), b, cap)),
                    ],
                ));
            }
            return;
        };
        let step = model.selected_step().and_then(|s| model.step(s));
        if shows_strip {
            let base = g.steps().first().map(|s| s.id);
            for st in g.list_steps() {
                let h = Self::LIST_ROW_HEIGHT;
                let q = mid(h, cap);
                let mix_w = 60.0;
                let pop_w = 96.0;
                let sm = f64::from(spacing::SM);
                let mix_x = w - inset - mix_w;
                let pop_x = mix_x - sm - pop_w;
                let mut c: Vec<(Control, CGRect)> = vec![
                    (Control::ListEye(st.id), CGRect::new(inset, q, cap, cap)),
                    (Control::ListMix(st.id), CGRect::new(mix_x, q, mix_w, cap)),
                ];
                if Some(st.id) != base {
                    c.push((Control::ListBlend(st.id), CGRect::new(pop_x, q, pop_w, cap)));
                }
                c.push((Control::ListRow(st.id), CGRect::new(0.0, 0.0, w, h)));
                let mut r = Row::new(Some(&st.label), RowStyle::ListItem, h, c);
                r.dim = !st.enabled;
                r.summary = if st.lut.is_some() { Some("lut".to_string()) } else { None };
                r.open = Some(st.id) == model.selected_step();
                add(r);
            }
            let h = Self::LIST_FOOTER_HEIGHT;
            let q = mid(h, cap);
            let in_w = self.button_width("In").max(cap);
            let out_w = self.button_width("Out").max(cap);
            add(Row::new(
                None,
                RowStyle::ListFoot,
                h,
                vec![
                    (Control::ListChip(GraphLUTSlot::Input), CGRect::new(inset, q, in_w, cap)),
                    (Control::ListChip(GraphLUTSlot::Output), CGRect::new(w - inset - out_w, q, out_w, cap)),
                    (Control::ListAdd, CGRect::new((w / 2.0 - cap / 2.0).round(), q, cap, cap)),
                ],
            ));
        }
        // The path line: "01   Name", the Step's eye and its menu.
        let number = step.and_then(|s| g.steps().iter().position(|x| x.id == s.id)).map(|i| format!("{:02}", i + 1));
        let ph = Mac::POPUP_ROW;
        let btn = Mac::ICON;
        let more = CGRect::new(w - inset - btn, mid(ph, cap), btn, cap);
        let eye = offset_by(&more, -(btn + 6.0), 0.0);
        let path_label =
            step.map_or(String::new(), |s| format!("{}   {}", number.clone().unwrap_or_default(), s.label));
        add(Row::new(Some(&path_label), RowStyle::Path, ph, vec![(Control::PathEye, eye), (Control::PathMore, more)]));
        if let Some(step) = step.filter(|s| !s.enabled) {
            let _ = step;
            let b = self.button_width("Turn On");
            add(Row::new(
                Some("This Step is off. Its values are kept."),
                RowStyle::Warning,
                ph,
                vec![(Control::TurnOn, CGRect::new(w - inset - b, mid(ph, cap), b, cap))],
            ));
        }
        if g.has_custom_wiring() {
            add(Row::new(Some(Self::WIRING_NOTICE), RowStyle::Warning, ph, Vec::new()));
        }
        // The tab row: the Mac tab strip (12 inset, 8 padding each side, the underline under the selected title).
        let mut x = inset - 8.0;
        let mut tabs: Vec<(Control, CGRect)> = Vec::new();
        for (i, t) in Self::PRO_TAB_TITLES.iter().enumerate() {
            let tw = self.tab_text_width(t, fs, i == self.pro_tab) + 16.0;
            tabs.push((Control::ProTab(i), CGRect::new(x, 0.0, tw, Self::TAB_ROW_HEIGHT)));
            x += tw;
        }
        add(Row::plain(None, Self::TAB_ROW_HEIGHT, tabs));
        self.pro_tab_rows(model, step, add);
    }

    /// The selected tab's rows (Primaries here, the others in `color_grade_draw_pro_tabs`).
    fn pro_tab_rows(&self, model: &ColorInspectorModel, step: Option<&ColorStep>, add: &mut dyn FnMut(Row)) {
        let id = step.map_or(Self::NO_STEP, |s| s.id);
        let dim = step.is_none();
        match self.pro_tab {
            0 => self.primaries_rows(id, dim, add),
            _ => self.pro_other_tab_rows(model, id, step, add),
        }
    }

    pub(crate) fn slider_box(&self, row_h: f64) -> CGRect {
        CGRect::new(
            Mac::CONTROL_X,
            ((row_h - Mac::SLIDER) / 2.0).round(),
            (self.size.width - Mac::INSET - Mac::CONTROL_X).max(0.0),
            Mac::SLIDER,
        )
    }

    /// Version 9 `.wheels.four`: Lift, Gamma, Gain and Offset as a 2 x 2 grid of 96 pt wheels (title above, master slider
    /// under each), then Saturation, Contrast and Pivot.
    fn primaries_rows(&self, id: Id, dim: bool, add: &mut dyn FnMut(Row)) {
        let inset = Mac::INSET;
        let md = f64::from(spacing::MD);
        let sm = f64::from(spacing::SM);
        let xs = f64::from(spacing::XS);
        let cell_w = ((self.size.width - 2.0 * inset - sm) / 2.0).max(0.0);
        let d = Self::WHEEL_SIZE;
        // Redesign R4d: 6 above the first title, a 143 pt cell (title 20, 6, wheel 96, its slider), 292 pt in all.
        let cell_h = Self::WHEEL_CELL;
        let _ = (md, xs);
        let mut controls: Vec<(Control, CGRect)> = Vec::new();
        for (i, p) in PrimaryWheel::ALL.iter().enumerate() {
            let col = (i % 2) as f64;
            let line = (i / 2) as f64;
            let x = inset + col * (cell_w + sm) + ((cell_w - d) / 2.0).round();
            // The kit keeps 12 pt between the title's text and the disc (R4d had 6, measured 10 pt short at 1x).
            let y = Self::WHEEL_TOP + line * cell_h + Self::WHEEL_TITLE_HEIGHT + 16.0;
            controls.push((Control::Wheel(Wheel::Step(id, *p)), CGRect::new(x, y, d, d)));
            controls.push((Control::Master(Wheel::Step(id, *p)), CGRect::new(x, y + d + 2.0, d, 16.0)));
        }
        add(Row::plain(None, Self::WHEEL_TOP + 2.0 * cell_h, controls).dimmed(dim));
        for r in StepPrimaryRow::ALL {
            add(Row::plain(
                Some(r.title()),
                Mac::ROW,
                vec![(Control::Slider(Slider::Primary(id, r)), self.slider_box(Mac::ROW))],
            )
            .dimmed(dim));
        }
    }

    // MARK: Drawing

    pub(crate) fn draw_pro_row(&self, c: &mut Canvas, t: &DrawTheme, host: &ColorGradeController, r: &Row, a: f32) {
        let fs = f64::from(type_size::BODY);
        let cap = f64::from(type_size::CAPTION);
        let w = self.size.width;
        let inset = Mac::INSET;
        let label = r.label.as_deref().unwrap_or("");
        match r.style {
            RowStyle::Empty => {
                c.draw_text_in(
                    &tr(label),
                    CGRect::new(0.0, r.y + r.height / 2.0 - 22.0, w, 20.0),
                    15.0,
                    t.label(),
                    TextAlign::Center,
                    0.0,
                    c.semibold(),
                );
                c.draw_text_in(
                    &tr(r.summary.as_deref().unwrap_or("")),
                    CGRect::new(0.0, r.y + r.height / 2.0 + 2.0, w, 16.0),
                    cap,
                    t.label3(),
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
            RowStyle::Notice => {
                let b = CGRect::new(inset, r.y + Self::NOTICE_TOP, w - 2.0 * inset, r.height - Self::NOTICE_TOP - 4.0);
                c.experimental_notice(sq_draw::experimental::Feature::ProGrading, b, t);
            }
            RowStyle::ListItem => {
                let row = CGRect::new(0.0, r.y, w, r.height);
                if r.open {
                    c.fill_rounded(row.inset_by(4.0, 1.0), f64::from(radius::CONTROL), t.selection());
                }
                let lx = inset + f64::from(metrics::CAPSULE) + 8.0;
                let right = w - inset - 60.0 - 8.0 - 96.0 - 8.0;
                let text = tr(label);
                c.draw_text_in(
                    &text,
                    CGRect::new(lx, r.y, (right - lx).max(0.0), r.height),
                    fs,
                    if r.dim { t.label3() } else { t.label() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
                if r.summary.is_some() {
                    let tw = (c.size_of(&text, fs, 0).width.ceil() + 4.0).min(right - lx - 4.0);
                    c.fill_ellipse(CGRect::new(lx + tw, row.mid_y() - 2.0, 4.0, 4.0), t.accent());
                }
            }
            RowStyle::ListFoot => {
                c.fill(CGRect::new(0.0, r.y, w, 1.0), t.separator());
                if let (Some(d), Some(g)) = (self.list_drag, host.model().and_then(|m| m.graph()))
                    && let Some(from) = g.list_steps().iter().position(|s| s.id == d.0)
                {
                    let y = r.y - g.steps().len() as f64 * Self::LIST_ROW_HEIGHT
                        + d.1 as f64 * Self::LIST_ROW_HEIGHT
                        + if d.1 > from { Self::LIST_ROW_HEIGHT } else { 0.0 };
                    c.fill(CGRect::new(inset, y - 1.0, w - 2.0 * inset, 2.0), t.accent());
                }
            }
            RowStyle::Path => {
                c.draw_text_in(
                    &tr(label),
                    CGRect::new(inset, r.y, (w - inset - 2.0 * 30.0 - 8.0).max(0.0), r.height),
                    fs,
                    t.label(),
                    TextAlign::Left,
                    0.0,
                    c.semibold(),
                );
            }
            RowStyle::Warning => {
                c.fill(CGRect::new(0.0, r.y, w, r.height), t.warning().with_alpha(0.10));
                c.draw_icon(
                    SQIcon::Warning,
                    CGPoint::new(inset, r.y + (r.height - 14.0) / 2.0),
                    14.0,
                    t.warning(),
                    None,
                );
                c.draw_text_in(
                    &tr(label),
                    CGRect::new(inset + 20.0, r.y, (w - inset - 20.0 - 90.0).max(0.0), r.height),
                    fs,
                    t.warning(),
                    TextAlign::Left,
                    0.0,
                    c.semibold(),
                );
            }
            RowStyle::Footnote => {
                for (i, l) in r.lines.iter().enumerate() {
                    c.draw_text_in(
                        l,
                        CGRect::new(
                            inset,
                            r.y + 8.0 + i as f64 * Self::FOOTNOTE_LINE,
                            w - 2.0 * inset,
                            Self::FOOTNOTE_LINE,
                        ),
                        cap,
                        t.label3(),
                        TextAlign::Left,
                        0.0,
                        0,
                    );
                }
            }
            RowStyle::GroupHead => {
                c.draw_text_in(
                    &tr(label).to_uppercase(),
                    CGRect::new(inset, r.y, w - 2.0 * inset, r.height),
                    cap,
                    t.label3().with_alpha(a),
                    TextAlign::Left,
                    0.0,
                    c.semibold(),
                );
            }
            RowStyle::Title => {
                c.draw_text_in(
                    &tr(label),
                    CGRect::new(inset, r.y, (w - 2.0 * inset - 30.0).max(0.0), r.height),
                    fs,
                    if r.open { t.label() } else { t.label3() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            _ => {}
        }
    }

    /// Draws the Pro page's own controls; false = not one of them.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn draw_pro_control(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        _host: &ColorGradeController,
        model: &ColorInspectorModel,
        k: Control,
        f: CGRect,
        enabled: bool,
        cx: &mut UiCx,
    ) -> bool {
        let fs = f64::from(type_size::BODY);
        let hov = self.hover == Some(k);
        let prs = self.pressed == Some(k);
        let h = f64::MAX;
        match k {
            Control::StartEmpty => InspectorDraw::button(c, &tr("Start empty"), f, hov, prs, true, true, h, t),
            Control::StartFromSimple => {
                InspectorDraw::button(c, &tr("Start from Simple grade"), f, hov, prs, true, false, h, t)
            }
            // The notice draws its own X.
            Control::CloseNotice => {}
            Control::TurnOn => InspectorDraw::button(c, &tr("Turn On"), f, hov, prs, true, false, h, t),
            Control::ListEye(id) => {
                let on = model.step(id).is_none_or(|s| s.enabled);
                if hov {
                    c.stone_button(f, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
                }
                c.draw_icon(
                    if on { SQIcon::Eye } else { SQIcon::EyeOff },
                    CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0),
                    12.0,
                    t.label2(),
                    None,
                );
            }
            Control::PathEye => {
                let step = model.selected_step().and_then(|s| model.step(s));
                let on = step.is_none_or(|s| s.enabled);
                if hov && step.is_some() {
                    c.stone_button(f, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
                }
                c.draw_icon(
                    if on { SQIcon::Eye } else { SQIcon::EyeOff },
                    CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0),
                    12.0,
                    if step.is_none() { t.label3().with_alpha(0.5) } else { t.label2() },
                    None,
                );
            }
            Control::PathMore => {
                if hov {
                    c.stone_button(f, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
                }
                c.draw_icon(SQIcon::Ellipsis, CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0), 12.0, t.label2(), None);
            }
            Control::ListBlend(id) => {
                let b = model.graph().and_then(|g| g.blend(id)).unwrap_or(StepBlend::Series);
                let editable = model.graph().is_none_or(|g| g.allows_list_edit());
                InspectorDraw::popup(
                    c,
                    &tr(&Self::blend_title(b)),
                    f,
                    hov,
                    false,
                    enabled && editable,
                    false,
                    h,
                    None,
                    t,
                );
            }
            Control::ListMix(id) => {
                let mut fd = self.field(Some(model), Slider::Mix(id));
                fd.unit = "%".to_string();
                fd.is_enabled = enabled;
                fd.hovering = hov;
                fd.value_tint = Some(t.accent());
                fd.draw(c, f, t, self.focused == Some(Slider::Mix(id)), cx);
                self.put_field(Slider::Mix(id), fd);
            }
            Control::ListAdd => {
                if hov {
                    c.stone_button(f, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
                }
                c.draw_icon(SQIcon::Plus, CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0), 12.0, t.label2(), None);
            }
            Control::ListChip(slot) => {
                let name = model.graph_lut_choice(slot).map(|c| c.name);
                let title = tr(if slot == GraphLUTSlot::Input { "In" } else { "Out" });
                // A loaded LUT turns the chip's text purple (the Mac layer list).
                InspectorDraw::button(c, if name.is_none() { &title } else { "" }, f, hov, prs, true, false, h, t);
                if name.is_some() {
                    c.draw_text_in(&title, f, fs, t.accent(), TextAlign::Center, 0.0, 0);
                }
            }
            Control::ListRow(_) => {}
            Control::ProTab(i) => {
                let on = i == self.pro_tab;
                let w = self.tab_text_width(Self::PRO_TAB_TITLES[i], fs, on);
                c.draw_text_in(
                    &tr(Self::PRO_TAB_TITLES[i]),
                    CGRect::new(f.min_x() + 8.0, f.min_y(), w + 4.0, f.height),
                    fs,
                    if on {
                        t.label()
                    } else if hov {
                        t.label2()
                    } else {
                        t.label3()
                    },
                    TextAlign::Left,
                    0.0,
                    if on { c.medium() } else { 0 },
                );
                if on {
                    c.stone_tab_underline(f, true, t);
                }
            }
            _ => return self.draw_pro_tab_control(c, t, model, k, f, enabled),
        }
        true
    }

    pub fn blend_title(b: StepBlend) -> String {
        match b {
            StepBlend::Series => "Series".to_string(),
            StepBlend::Parallel => "Parallel".to_string(),
            StepBlend::Layer(LayerMixMode::Normal) => "Layer".to_string(),
            StepBlend::Layer(m) => {
                let raw = format!("{m:?}").to_lowercase();
                let mut ch = raw.chars();
                ch.next().map_or(String::new(), |f| f.to_uppercase().collect::<String>() + ch.as_str())
            }
        }
    }

    // MARK: Pointer

    /// The Step menus (rename is the model's own begin-rename; the file choosers go to the host).
    fn step_menus(&self) -> ColorGraphMenus {
        let mut menus = ColorGraphMenus::new(self.graph_sink.clone());
        menus.can_rename = true;
        menus.can_choose_lut_file = true;
        menus.can_import_decision = false;
        menus
    }

    fn menu_at(&mut self, host: &ColorGradeHost, items: Vec<SQMenuItem>, k: Control) {
        let steps_shown = host.controller.steps_shown();
        if items.is_empty() {
            return;
        }
        let Some(f) = host.model().and_then(|m| Self::frame_in(&self.rows(m, steps_shown), k)) else { return };
        self.menus
            .push(super::color_grade_draw::GradeMenuRequest { items, anchor: offset_by(&f, 0.0, -self.scroll_y) });
    }

    pub(crate) fn pro_secondary(&mut self, host: &mut ColorGradeHost, k: Control) {
        let menus = self.step_menus();
        match k {
            Control::ListRow(id) => {
                if let Some(m) = host.model_mut() {
                    m.set_selected_step(Some(id));
                }
                host.pump();
                let items = host.model().map(|m| menus.step_menu_items(m, id)).unwrap_or_default();
                self.menu_at(host, items, k);
            }
            Control::PathMore => {
                let id = host.model().and_then(|m| m.selected_step());
                if let Some(id) = id {
                    let items = host.model().map(|m| menus.step_menu_items(m, id)).unwrap_or_default();
                    self.menu_at(host, items, k);
                }
            }
            _ => {}
        }
    }

    pub(crate) fn pro_mouse_down(
        &mut self,
        host: &mut ColorGradeHost,
        _cx: &mut UiCx,
        k: Control,
        q: CGPoint,
        modifiers: InputModifiers,
        n: i64,
    ) {
        if host.model().is_none() {
            return;
        }
        let steps_shown = host.controller.steps_shown();
        match k {
            Control::ListRow(id) => {
                if let Some(m) = host.model_mut() {
                    m.set_selected_step(Some(id));
                }
                host.pump();
                self.list_press = Some((id, q.y));
            }
            Control::ListBlend(id) => {
                let editable = host.model().and_then(|m| m.graph()).is_none_or(|g| g.allows_list_edit());
                if !editable {
                    self.pressed = None;
                    return;
                }
                let current = host.model().and_then(|m| m.graph()).and_then(|g| g.blend(id));
                let items: Vec<SQMenuItem> = StepBlend::all()
                    .into_iter()
                    .map(|b| {
                        let mut i = self.row(&Self::blend_title(b), DrawMenuCommand::SetBlend(id, b));
                        i.is_checked = current == Some(b);
                        i
                    })
                    .collect();
                self.menu_at(host, items, k);
                self.pressed = None;
            }
            Control::ListMix(id) => {
                if host.model().and_then(|m| Self::frame_in(&self.rows(m, steps_shown), k)).is_none() {
                    return;
                }
                let s = Slider::Mix(id);
                let mut fd = self.field(host.model(), s);
                fd.unit = "%".to_string();
                let events = fd.mouse_down(q.x as f32, n);
                self.apply(host, events, s);
                self.put_field(s, fd);
                self.field_press = Some(s);
                self.focused = Some(s);
            }
            Control::ListChip(slot) => {
                let menus = self.step_menus();
                let target = if slot == GraphLUTSlot::Input { LUTTarget::GraphInput } else { LUTTarget::GraphOutput };
                let items = host.model().map(|m| menus.lut_items(m, target)).unwrap_or_default();
                self.menu_at(host, items, k);
                self.pressed = None;
            }
            Control::PathMore => {
                let menus = self.step_menus();
                if let Some(id) = host.model().and_then(|m| m.selected_step()) {
                    let items = host.model().map(|m| menus.step_menu_items(m, id)).unwrap_or_default();
                    self.menu_at(host, items, k);
                }
                self.pressed = None;
            }
            Control::ProTab(i) => {
                self.pro_tab = i;
                self.pressed = None;
            }
            // These act on the click, not on the press, and need no selected Step: with no graph there is none, and
            // the Step-bound press below would drop the press (the empty state's buttons did nothing).
            Control::StartEmpty
            | Control::StartFromSimple
            | Control::CloseNotice
            | Control::TurnOn
            | Control::ListAdd
            | Control::ListEye(_)
            | Control::PathEye => {}
            _ => self.pro_tab_mouse_down(host, k, q, modifiers),
        }
    }

    /// A drag in progress that the Pro page owns (a list row, a range bar); false = not ours.
    pub(crate) fn pro_mouse_dragged(&mut self, host: &mut ColorGradeHost, q: CGPoint) -> bool {
        if let Some(p) = self.list_press {
            let allows = host.model().and_then(|m| m.graph()).is_some_and(|g| g.allows_list_edit());
            if allows {
                if self.list_drag.is_none() && (q.y - p.1).abs() <= 4.0 {
                    return true;
                }
                let steps_shown = host.controller.steps_shown();
                let top = host.model().and_then(|m| {
                    self.rows(m, steps_shown).iter().find(|r| r.style == RowStyle::ListItem).map(|r| r.y)
                });
                let Some(top) = top else { return true };
                let n = host.model().and_then(|m| m.graph()).map_or(0, |g| g.steps().len());
                let row = (((q.y - top) / Self::LIST_ROW_HEIGHT).floor() as i64).clamp(0, (n as i64 - 1).max(0));
                self.list_drag = Some((p.0, row as usize));
                return true;
            }
        }
        self.pro_range_dragged(host, q)
    }

    pub(crate) fn pro_mouse_up(&mut self, host: &mut ColorGradeHost) -> bool {
        if self.list_press.is_some() {
            let drag = self.list_drag.take();
            self.list_press = None;
            if let Some(d) = drag {
                let from =
                    host.model().and_then(|m| m.graph()).and_then(|g| g.list_steps().iter().position(|s| s.id == d.0));
                if from != Some(d.1) {
                    if let Some(m) = host.model_mut() {
                        m.move_step_to_list_row(d.0, d.1 as i64);
                    }
                    host.pump();
                }
            }
            return true;
        }
        self.pro_range_up(host)
    }

    /// A click that ended on the control it started on.
    pub(crate) fn pro_clicked(&mut self, host: &mut ColorGradeHost, k: Control) {
        let Some(m) = host.model_mut() else { return };
        match k {
            Control::ListEye(id) => {
                if let Some(on) = m.step(id).map(|s| s.enabled) {
                    m.set_step_enabled(id, !on);
                }
            }
            Control::PathEye | Control::TurnOn => {
                if let Some(id) = m.selected_step()
                    && let Some(on) = m.step(id).map(|s| s.enabled)
                {
                    m.set_step_enabled(id, if k == Control::TurnOn { true } else { !on });
                }
            }
            Control::ListAdd => m.add_layer_on_top(),
            Control::StartEmpty => m.start_empty_graph(),
            Control::StartFromSimple => m.start_from_simple(),
            Control::CloseNotice => sq_draw::experimental::close_notice(sq_draw::experimental::Feature::ProGrading),
            _ => {
                self.pro_tab_clicked(host, k);
                return;
            }
        }
        host.pump();
    }

    pub(crate) fn pro_help(&self, host: &ColorGradeController, k: Control) -> Option<String> {
        match k {
            Control::ListAdd => Some(tr("Add a step after the selected one")),
            Control::CloseNotice => Some(tr("Close this note for good")),
            Control::ListChip(slot) => {
                let name = host.model().and_then(|m| m.graph_lut_choice(slot)).map(|c| c.name).unwrap_or_else(|| {
                    (if slot == GraphLUTSlot::Input { "None (built-in conversion)" } else { "None" }).to_string()
                });
                Some(SQL10n::format(
                    if slot == GraphLUTSlot::Input { "In LUT: %@" } else { "Out LUT: %@" },
                    &[&tr(&name)],
                ))
            }
            _ => None,
        }
    }

    /// Runs the Step menus' queued rows (they use their own sink).
    pub fn run_graph_commands(&mut self, host: &mut ColorGradeHost) {
        let menus = self.step_menus();
        for cmd in self.graph_sink.drain() {
            let Some(m) = host.model_mut() else { return };
            if let Some(req) = menus.apply(m, cmd) {
                match req {
                    super::color_graph_menus::GraphMenuHostRequest::ChooseLutFile(_) => {
                        if let Some(id) = host.model().and_then(|m| m.selected_step()) {
                            self.file_requests.push(GradeFileRequest::LutFiles {
                                multiple: false,
                                then: super::color_grade_draw::LutFilesFor::StepLut(id),
                            });
                        }
                    }
                    super::color_graph_menus::GraphMenuHostRequest::Rename(id) => {
                        if let Some(m) = host.model_mut() {
                            m.begin_rename(id);
                        }
                    }
                    other => self.graph_requests.push(other),
                }
            }
            host.pump();
        }
    }
}
