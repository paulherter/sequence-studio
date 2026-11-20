// Swift: EffectControlsDrawView.swift
//! The whole Effect Controls panel on the shared toolkit: `EffectControlsView.layout` translated. Clip line across the
//! top, then the "Video" / "Audio" header beside the keyframe ruler, then the rows column (`EffectControlsDrawPanel`) left of
//! the divider and the keyframe lanes (`EffectKeyframeLanesDraw`) right of it, scrolling together. Coordinates: points,
//! y down, (0, 0) = the panel's top-left.
//!
//! The view owns the [`EffectControlsModel`] and hands it to the rows column, the lanes, the ruler, the graphs and the Graph
//! Editor, which in Swift all held a reference to it. Hooks of those parts become [`ViewEvent`]s.

use std::collections::HashMap;

use sq_core_color::ColorMatteClipExt;
use sq_core_edit::timeline_edit_targets::TimelineEditTargetsExt;
use sq_core_model::{Clip, GeneratorRef};
use sq_draw::scroll::ScrollGesture;
use sq_draw::theme::{spacing, type_size};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::keyframe_graph_geometry::{GraphInsets, GraphMode};
use sq_uikit::keyframe_viewport::EffectControlsSplit;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;

use super::effect_controls_draw_panel::{EffectControlsDrawPanel, PanelEvent};
use super::effect_keyframe_lanes_draw::{EffectKeyframeLanesDraw, KeyframeRulerDraw, LanesBeside};
use super::graph_editor_draw::GraphEditorDraw;
use super::inline_speed_graph_draw::InlineSpeedGraphDraw;
use super::keyframe_graph_draw::{KeyframeGraphDraw, KeyframeGraphEvent};
use super::{MenuEntry, MenuOutput, ModelMenu, PromptRequest, offset_by, text_in};
use crate::ec::controls_metrics::ControlsMetrics;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::layout::{EffectControlsLayout, EffectGroup, EffectRow, EffectRowKind};
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
use crate::keyframes::keyframe_ruler::EffectControlsHeaderText;

/// What the view asks its host to do.
pub enum ViewEvent {
    /// A popup or a right-click menu; the anchor is in panel points. Run the chosen row with
    /// [`EffectControlsDrawView::run_menu`].
    Menu { menu: std::rc::Rc<ModelMenu>, anchor: CGRect },
    /// A key tool dialog: show `prompt`, then call [`EffectControlsDrawView::answer_prompt`].
    Prompt(PromptRequest),
    /// The name of a curve to save from a value graph: show `KeyToolPrompt::save_curve()`, then call
    /// [`EffectControlsDrawView::save_curve_named`].
    SaveCurve { property: EffectProperty, index: usize },
    /// "Reset to Automatic" of a property a variant overrides.
    ResetToAutomatic(EffectProperty),
    /// The divider was released at this label width (`persistLabelWidth`).
    PersistLabelWidth(f64),
    /// A hook of the rows column.
    Panel(PanelEvent),
}

/// The parts of the view a press can go to.
#[derive(Clone, Debug, PartialEq)]
pub enum Part {
    Header,
    Rows,
    Ruler,
    Lanes,
    Graph(EffectProperty),
    GraphEditor,
    Divider,
    None,
}

/// The whole Effect Controls panel.
pub struct EffectControlsDrawView {
    /// The model every part reads and edits.
    pub model: EffectControlsModel,
    /// The rows column.
    pub rows_panel: EffectControlsDrawPanel,
    /// The keyframe lanes.
    pub lanes: EffectKeyframeLanesDraw,
    /// The keyframe ruler.
    pub ruler: KeyframeRulerDraw,
    /// The Graph Editor: replaces the lanes while `model.graph_editor` is on.
    pub graph_editor: GraphEditorDraw,
    theme: DrawTheme,
    /// The value graphs of opened rows in value mode (one per component, stacked), made on first use.
    value_graphs: HashMap<EffectProperty, Vec<(EffectComponent, KeyframeGraphDraw)>>,
    /// The component graph a press in value mode went to.
    value_press: Option<usize>,
    /// The curve panes of opened rows (`SpeedGraphRow.speedGraph`), made on first use.
    graphs: HashMap<EffectProperty, InlineSpeedGraphDraw>,
    size: CGSize,
    /// Height of a leading clip section the host draws between the header and the rows (0: none).
    lead: f64,
    label_width: f64,
    has_prompt: bool,
    events: Vec<ViewEvent>,
    capture: Part,
    press_modifiers: InputModifiers,
    divider: Option<(f64, f64)>,
    hover_part: Part,
    lanes_focused: bool,
    clicks: sq_draw::ClickCounter,
}

impl EffectControlsDrawView {
    /// A view over `model`; `stored_label_width` is the divider position the app saved (0 when none).
    pub fn new(model: EffectControlsModel, stored_label_width: f64) -> EffectControlsDrawView {
        EffectControlsDrawView {
            model,
            rows_panel: EffectControlsDrawPanel::new(),
            lanes: EffectKeyframeLanesDraw::new(),
            ruler: KeyframeRulerDraw::new(),
            graph_editor: GraphEditorDraw::new(),
            theme: DrawTheme::default(),
            value_graphs: HashMap::new(),
            value_press: None,
            graphs: HashMap::new(),
            size: CGSize::default(),
            lead: 0.0,
            label_width: EffectControlsSplit::width_from_stored(stored_label_width),
            has_prompt: false,
            events: Vec::new(),
            capture: Part::None,
            press_modifiers: InputModifiers::NONE,
            divider: None,
            hover_part: Part::None,
            lanes_focused: false,
            clicks: sq_draw::ClickCounter::new(),
        }
    }

    /// Takes the events pushed since the last call.
    pub fn take_events(&mut self) -> Vec<ViewEvent> {
        std::mem::take(&mut self.events)
    }

    /// The theme (`didSet`: the parts follow).
    pub fn set_theme(&mut self, t: DrawTheme) {
        self.theme = t;
        self.rows_panel.theme = t;
    }

    /// Key-tool dialogs (Scale Time, Loop, Wiggle, Velocity, Save Curve); false leaves them out of the key menu.
    pub fn set_has_prompt(&mut self, on: bool) {
        self.has_prompt = on;
        self.lanes.has_prompt = on;
        for v in self.value_graphs.values_mut() {
            for (_, g) in v {
                g.has_prompt = on;
            }
        }
    }

    /// The divider position (Mac: `EffectControlsView.labelWidth`), clamped by `EffectControlsSplit`.
    pub fn label_width(&self) -> f64 {
        self.label_width
    }

    /// The part of the last press (`lanes_focused`: keys go to the lanes).
    pub fn lanes_focused(&self) -> bool {
        self.lanes_focused
    }

    /// The size of the view in points.
    pub fn size(&self) -> CGSize {
        self.size
    }

    /// `size` with its `didSet`.
    pub fn set_size(&mut self, size: CGSize) {
        if size != self.size {
            self.size = size;
            self.layout();
        }
    }

    fn editor_on(&self) -> bool {
        self.has_clip() && self.model.graph_editor
    }

    // MARK: Layout

    fn has_clip(&self) -> bool {
        self.model.clip().is_some()
    }
    /// Clip line, header row and the leading section's gap: where the rows and lanes start. No clip = the rows column
    /// (its empty state) fills the panel.
    pub fn top(&self) -> f64 {
        if self.has_clip() { self.header_bottom() } else { 0.0 }
    }
    /// Panel y of the "Video" header row: below the clip line and the host's leading section (redesign #34: the selected
    /// item comes first, then "Video · whole clip", then the rows).
    pub fn video_header_y(&self) -> f64 {
        ControlsMetrics::CLIP_LINE + if self.has_clip() { self.lead } else { 0.0 }
    }
    /// Clip line, leading section and the "Video" header row: where the rows start.
    pub fn header_bottom(&self) -> f64 {
        self.video_header_y() + ControlsMetrics::HEADER
    }
    /// Panel y of the leading section's top edge (it sits right below the clip line).
    pub fn lead_top(&self) -> f64 {
        ControlsMetrics::CLIP_LINE
    }
    /// The words over the rows: "Video · whole clip" when a leading item (text layer, shape, graphic) comes first.
    pub fn group_title(&self) -> String {
        let group = SQL10n::string(self.first_group().title());
        if self.lead > 0.0 && self.first_group() == EffectGroup::Video {
            format!("{group} \u{b7} whole clip")
        } else {
            group
        }
    }
    /// Leaves `height` points between the header and the rows for the host's leading clip section.
    pub fn set_lead(&mut self, height: f64) {
        let height = if self.has_clip() { height.max(0.0) } else { 0.0 };
        if height != self.lead {
            self.lead = height;
            self.layout();
        }
    }
    /// Reserves the rows of a text clip's Arrange and Animation parts (heights in points, 0 = none).
    pub fn set_text_slots(&mut self, arrange: f64, animation: f64) {
        if self.rows_panel.text_slots != (arrange, animation) {
            self.rows_panel.text_slots = (arrange, animation);
            self.relayout();
        }
    }
    /// Clip line, header and all rows end to end: the height at which the rows need no scrolling.
    pub fn content_height(&self) -> f64 {
        self.top() + self.rows_panel.content_height()
    }
    /// Left edge of the lanes = the divider.
    pub fn lane_x(&self) -> f64 {
        if self.has_clip() { EffectControlsSplit::clamp(self.label_width, self.size.width) } else { self.size.width }
    }
    pub fn lanes_size(&self) -> CGSize {
        CGSize::new((self.size.width - self.lane_x()).max(0.0), (self.size.height - self.top()).max(0.0))
    }

    /// After a model change (the host's dirty flag): rows first, then the lanes take them.
    pub fn relayout(&mut self) {
        self.rows_panel.relayout(&self.model);
        self.layout();
    }

    fn layout(&mut self) {
        let lanes = self.lanes_size();
        let rows = CGSize::new(self.lane_x(), (self.size.height - self.top()).max(0.0));
        self.rows_panel.set_size(&self.model, rows);
        self.lanes.size = lanes;
        self.graph_editor.size = lanes;
        self.ruler.size = CGSize::new(lanes.width, ControlsMetrics::HEADER);
        self.sync_lanes();
    }

    fn sync_lanes(&mut self) {
        self.lanes.rows = self.rows_panel.rows().to_vec();
        self.lanes.scroll_y = self.rows_panel.scroll_y;
        self.lanes.content_bottom = self.rows_panel.content_height();
        let w = self.lanes_size().width;
        let heights: Vec<(EffectProperty, f64)> =
            self.graphs.keys().map(|p| (p.clone(), self.graph_row(p).map_or(0.0, |r| r.height))).collect();
        for (p, h) in heights {
            if let Some(g) = self.graphs.get_mut(&p) {
                g.size = CGSize::new(w, h);
            }
        }
    }

    /// Ticks the rows column's idle timers.
    pub fn tick(&mut self, now: f64) {
        self.rows_panel.tick(&mut self.model, now);
    }

    // MARK: Opened rows (SpeedGraphRow: the pane left of the divider is the rows column's, the curve sits over the lanes)

    fn graph_pane(&mut self, p: &EffectProperty) {
        if !self.graphs.contains_key(p) {
            let mut g = InlineSpeedGraphDraw::new(p.clone());
            g.size = CGSize::new(self.lanes_size().width, self.graph_row(p).map_or(0.0, |r| r.height));
            self.graphs.insert(p.clone(), g);
        }
    }

    /// The curve pane of an opened row, made on first use (`graph(_:)`).
    pub fn graph(&mut self, p: &EffectProperty) -> &mut InlineSpeedGraphDraw {
        self.graph_pane(p);
        self.graphs.entry(p.clone()).or_insert_with(|| InlineSpeedGraphDraw::new(p.clone()))
    }

    /// The value graphs of an opened row, made on first use (`valueGraphs(_:)`).
    pub fn value_graphs(&mut self, p: &EffectProperty) -> &[(EffectComponent, KeyframeGraphDraw)] {
        self.ensure_value_graphs(p);
        self.value_graphs.get(p).map_or(&[], |v| v.as_slice())
    }

    /// `SpeedGraphRow`'s value graphs: one per component, wired to the model as on the Mac.
    fn ensure_value_graphs(&mut self, p: &EffectProperty) {
        if self.value_graphs.contains_key(p) {
            return;
        }
        let pic = self.model.display_picture();
        let v: Vec<(EffectComponent, KeyframeGraphDraw)> = self
            .model
            .value_components(p)
            .into_iter()
            .map(|c| {
                let mut g = KeyframeGraphDraw::new();
                g.set_mode(GraphMode::Value);
                g.display_scale = if *p == EffectProperty::Volume {
                    1.0
                } else {
                    (p.display(1.0, EffectComponent::All, pic) - p.display(0.0, EffectComponent::All, pic))
                        .abs()
                        .max(1e-9)
                };
                g.insets = GraphInsets { top: 14.0, left: 10.0, bottom: 14.0, right: 10.0 }; // the lanes' inset: curve under the keys
                g.has_prompt = self.has_prompt;
                (c, g)
            })
            .collect();
        self.value_graphs.insert(p.clone(), v);
    }

    /// `SpeedGraphRow.update` + `layout` for the value graphs of `p` in a pane `size` big.
    fn sync_value_graphs(&mut self, p: &EffectProperty, size: CGSize) -> Vec<CGRect> {
        self.ensure_value_graphs(p);
        let model = &self.model;
        let local = model.local_playhead();
        let sel = model.selected_key_ids(p);
        let in_clip = model.playhead_in_clip();
        let (fd, dur, range, lib) =
            (model.frame_duration, model.duration(), model.viewport().range(), model.easing_library.clone());
        let Some(v) = self.value_graphs.get_mut(p) else { return Vec::new() };
        let h = size.height / v.len().max(1) as f64;
        let mut out = Vec::new();
        for (i, (c, g)) in v.iter_mut().enumerate() {
            g.size = CGSize::new(size.width, h);
            let t = model.graph_track(p, *c);
            if g.track() != &t {
                g.set_track(t);
            }
            g.selected_key_ids = sel.clone();
            g.playhead_seconds = if in_clip { Some(local.value() as f64 / local.timescale() as f64) } else { None };
            g.frame_duration = fd;
            g.set_max_time(Some(dur));
            g.set_visible_time(Some(range.0..=range.1));
            g.easing_library = lib.clone();
            out.push(CGRect::new(0.0, i as f64 * h, size.width, h));
        }
        out
    }

    fn is_speed(&self, p: &EffectProperty) -> bool {
        self.model.graph_mode_for(p) == GraphMode::Speed
    }

    fn graph_row(&self, p: &EffectProperty) -> Option<&EffectRow> {
        self.rows_panel.rows().iter().find(|r| r.kind == EffectRowKind::Graph(p.clone()))
    }

    /// The opened rows on screen with their pane in panel points.
    fn graph_frames(&self) -> Vec<(EffectProperty, CGRect)> {
        if !self.has_clip() || self.lanes_size().width <= 0.0 {
            return Vec::new();
        }
        self.rows_panel
            .rows()
            .iter()
            .filter_map(|r| {
                let EffectRowKind::Graph(p) = &r.kind else { return None };
                let f = CGRect::new(
                    self.lane_x(),
                    self.top() + r.y - self.rows_panel.scroll_y,
                    self.lanes_size().width,
                    r.height,
                );
                (f.max_y() > self.top() && f.min_y() < self.size.height).then(|| (p.clone(), f))
            })
            .collect()
    }

    // MARK: Drawing

    /// Draws the panel.
    pub fn draw(&mut self, c: &mut Canvas, cx: &mut UiCx) {
        let t = self.theme;
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        self.sync_lanes();
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.panel());
        if self.has_clip() {
            self.draw_header(c);
        }
        let lw = self.lane_x();
        let top = self.top();
        c.save_gstate();
        c.translate_by(0.0, top);
        self.rows_panel.draw(&self.model, c, cx);
        c.restore_gstate();
        if self.has_clip() && self.lanes_size().width > 0.0 {
            c.save_gstate();
            c.translate_by(lw, self.video_header_y());
            self.ruler.draw(&self.model, c, &t);
            c.restore_gstate();
            c.save_gstate();
            c.translate_by(lw, top);
            if self.editor_on() {
                self.graph_editor.size = self.lanes_size();
                self.graph_editor.draw(&self.model, c, &t);
            } else {
                self.lanes.draw(&self.model, c, &t);
            }
            c.restore_gstate();
            c.save_gstate();
            c.clip_to(CGRect::new(lw, top, self.lanes_size().width, self.lanes_size().height));
            for (p, f) in self.graph_frames() {
                c.save_gstate();
                c.translate_by(f.min_x(), f.min_y());
                if self.is_speed(&p) {
                    self.graph_pane(&p);
                    if let Some(g) = self.graphs.get_mut(&p) {
                        g.size = CGSize::new(f.width, f.height);
                        g.draw(&self.model, c, &t);
                    }
                } else {
                    let frames = self.sync_value_graphs(&p, CGSize::new(f.width, f.height));
                    if let Some(v) = self.value_graphs.get(&p) {
                        for ((_, g), r) in v.iter().zip(frames) {
                            c.save_gstate();
                            c.translate_by(r.min_x(), r.min_y());
                            g.draw(c, &t);
                            c.restore_gstate();
                        }
                    }
                }
                c.restore_gstate();
            }
            c.restore_gstate();
            // A thin overlay thumb at the right edge while the rows overflow (the kit shows one beside the lanes).
            let view = (self.size.height - top).max(0.0);
            if let Some(r) = Self::scroll_thumb(
                self.size.width,
                top,
                view,
                self.rows_panel.content_height(),
                self.rows_panel.scroll_y,
            ) {
                c.fill_rounded(r, 2.0, t.label3().with_alpha(0.5));
            }
            // The divider: a 1 pt line from the clip line down (its 7 pt grab zone is invisible).
            let line = if self.divider_active() { t.accent() } else { t.row_line() };
            c.fill(CGRect::new(lw, self.video_header_y(), 1.0, ControlsMetrics::HEADER), line);
            c.fill(CGRect::new(lw, top, 1.0, (self.size.height - top).max(0.0)), line);
        }
        c.restore_gstate();
    }

    fn divider_active(&self) -> bool {
        self.divider.is_some() || self.hover_part == Part::Divider
    }

    /// v9 `.clhead`: icon, name, meta with the panel's 12 pt inset; then "Video" (or "Audio" on an audio-only clip) over the
    /// rows column; the other side repeats it where its effects start.
    fn draw_header(&self, c: &mut Canvas) {
        let Some(clip) = self.model.clip() else { return };
        let t = self.theme;
        let ch = ControlsMetrics::CLIP_LINE;
        let rh = ControlsMetrics::HEADER;
        let lead = spacing::MD as f64;
        let trail = ControlsGrid::TRAILING;
        let icon_side = 14.0;
        let fs = type_size::BODY as f64;
        let bold = c.semibold();
        c.draw_icon(
            if clip.kind == sq_core_model::TrackKind::Audio { SQIcon::Waveform } else { SQIcon::Film },
            CGPoint::new(lead, ((ch - icon_side) / 2.0).round()),
            icon_side,
            t.label2(),
            None,
        );
        let name = if self.model.is_multi() {
            format!("{} clips selected", self.model.peers().len() + 1)
        } else {
            clip.name.clone()
        };
        let name_x = lead + icon_side + spacing::SM as f64;
        let room = (self.size.width - name_x - trail).max(0.0);
        // The time range keeps its room and the name shortens (the kit: a long name never pushes the range out).
        let meta = self.clip_meta(clip);
        let meta_w = c.size_of(&meta, fs, 0).width.ceil() + 4.0;
        let name_room =
            if room - meta_w - spacing::SM as f64 >= 48.0 { room - meta_w - spacing::SM as f64 } else { room };
        let name_w = (c.size_of(&name, fs, bold).width + 4.0).min(name_room);
        c.draw_text_in(&name, CGRect::new(name_x, 0.0, name_w, ch), fs, t.label(), TextAlign::Left, 0.0, bold);
        let info_x = name_x + name_w + spacing::SM as f64;
        text_in(
            c,
            &meta,
            CGRect::new(info_x, 0.0, (self.size.width - trail - info_x).max(0.0), ch),
            fs,
            t.label3(),
            TextAlign::Left,
        );
        c.fill(CGRect::new(0.0, ch - 1.0, self.size.width, 1.0), t.row_line());
        // The kit's eyebrow: 10 pt capitals, 600, +0.07 em, text 4.
        c.draw_tracked_caps(
            &self.group_title(),
            CGRect::new(lead, self.video_header_y(), (self.lane_x() - lead - trail).max(0.0), rh),
            10.0,
            t.label4(),
            bold,
            0.07,
        );
        c.fill(CGRect::new(0.0, self.video_header_y() + rh - 1.0, self.lane_x(), 1.0), t.row_line());
    }

    /// The overlay scroll thumb in panel points (4 pt wide, 3 pt from the right edge, as tall as the visible share of the
    /// rows, at least 24 pt); `None` while everything fits.
    pub(crate) fn scroll_thumb(width: f64, top: f64, view: f64, content: f64, scroll_y: f64) -> Option<CGRect> {
        let max_scroll = content - view;
        if max_scroll <= 0.5 || view <= 0.0 {
            return None;
        }
        let h = (view * view / content).max(24.0).min(view);
        let y = top + (scroll_y / max_scroll).clamp(0.0, 1.0) * (view - h);
        Some(CGRect::new(width - 7.0, y, 4.0, h))
    }

    /// The side the first effect row belongs to: the header over the rows names it.
    fn first_group(&self) -> EffectGroup {
        self.model.visible_sections().first().map_or_else(
            || {
                if self.model.clip().is_some_and(|c| c.kind == sq_core_model::TrackKind::Audio) {
                    EffectGroup::Audio
                } else {
                    EffectGroup::Video
                }
            },
            EffectControlsLayout::group_of,
        )
    }

    /// `ClipSectionMode.resolve(c).kindName`: the kind the header names for a clip that is not plain video or audio.
    // shortcut: ClipSectionMode lives with the clip sections task; this repeats its leading cases for the header text.
    fn kind_name(c: &Clip) -> Option<&'static str> {
        if c.template_slots.is_some() && c.sequence.is_some() {
            return Some("Template");
        }
        match c.generator.as_ref().map(|g| g.kind.as_str()) {
            Some("text") => return Some("Text"), // GeneratorRef.text
            Some(k) if k == GeneratorRef::SHAPE => return Some("Shape"),
            _ => {}
        }
        if c.is_color_matte() {
            return Some("Color Matte");
        }
        if c.is_graphics() {
            return Some("Graphic");
        }
        None
    }

    fn clip_meta(&self, c: &Clip) -> String {
        let timeline = self.model.timeline.as_ref().and_then(|f| f());
        let track = timeline.as_ref().and_then(|tl| {
            tl.tracks.iter().find(|t| t.clips().iter().any(|k| k.id == c.id)).and_then(|t| tl.track_label(t.id))
        });
        EffectControlsHeaderText::clip_meta(
            timeline.as_ref().map(|t| t.name.as_str()),
            track.as_deref(),
            c.start,
            c.start + self.model.duration(),
            self.model.frame_duration,
            Self::kind_name(c),
        )
    }

    /// Kind and duration of the shown clip: the tooltip over the meta text.
    pub fn clip_info_tip(&self) -> Option<String> {
        let c = self.model.clip()?;
        Some(EffectControlsHeaderText::clip_info(
            c.kind,
            self.model.duration(),
            self.model.frame_duration,
            Self::kind_name(c),
        ))
    }

    // MARK: Input

    /// The part under `p`.
    pub fn part_at(&self, p: CGPoint) -> Part {
        if !(p.x >= 0.0 && p.y >= 0.0 && p.x < self.size.width && p.y < self.size.height) {
            return Part::None;
        }
        if !self.has_clip() {
            return Part::Rows;
        }
        let lw = self.lane_x();
        let in_lead = p.y >= ControlsMetrics::CLIP_LINE && p.y < self.video_header_y();
        if p.y >= ControlsMetrics::CLIP_LINE && !in_lead && self.lanes_size().width > 0.0 && (p.x - lw).abs() <= 3.5 {
            return Part::Divider;
        }
        if in_lead {
            return Part::Header; // the host's leading section sits here
        }
        if p.y < ControlsMetrics::CLIP_LINE {
            return Part::Header;
        }
        if p.x >= lw {
            if p.y < self.header_bottom() {
                return Part::Ruler;
            }
            if self.editor_on() {
                return Part::GraphEditor;
            }
            if let Some(g) = self.graph_frames().into_iter().find(|g| g.1.contains(p)) {
                return Part::Graph(g.0);
            }
            return Part::Lanes;
        }
        if p.y < self.top() { Part::Header } else { Part::Rows }
    }

    fn lane_point(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x - self.lane_x(), p.y - self.top())
    }
    fn ruler_point(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x - self.lane_x(), p.y - ControlsMetrics::CLIP_LINE)
    }
    fn rows_point(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y - self.top())
    }
    fn graph_point(&self, p: CGPoint, prop: &EffectProperty) -> CGPoint {
        let y = self.graph_row(prop).map_or(self.top(), |r| self.top() + r.y - self.rows_panel.scroll_y);
        CGPoint::new(p.x - self.lane_x(), p.y - y)
    }

    fn show_menu(&mut self, menu: ModelMenu, anchor: CGRect) {
        if !menu.is_empty() {
            self.events.push(ViewEvent::Menu { menu: std::rc::Rc::new(menu), anchor });
        }
    }

    /// Runs the row of a menu the view handed out and routes what the action hands back.
    pub fn run_menu(&mut self, menu: &ModelMenu, path: &[usize]) {
        for out in menu.run(path, &mut self.model) {
            match out {
                MenuOutput::Prompt(req) => self.events.push(ViewEvent::Prompt(req)),
                MenuOutput::ResetToAutomatic(p) => self.events.push(ViewEvent::ResetToAutomatic(p)),
                MenuOutput::Graph { property, index, action } => {
                    let save = self
                        .value_graphs
                        .get_mut(&property)
                        .and_then(|v| v.get_mut(index))
                        .is_some_and(|(_, g)| g.run_menu_action(action));
                    if save {
                        self.events.push(ViewEvent::SaveCurve { property, index });
                    }
                    self.drain_graph_events();
                }
            }
        }
    }

    /// The answer of a key tool dialog (`None`: canceled).
    pub fn answer_prompt(&mut self, req: &PromptRequest, texts: Option<Vec<String>>) {
        (req.done)(&mut self.model, texts);
    }

    /// The name for a curve saved from a value graph (`None`: canceled).
    pub fn save_curve_named(&mut self, property: &EffectProperty, index: usize, name: Option<&str>) {
        if let Some((_, g)) = self.value_graphs.get_mut(property).and_then(|v| v.get_mut(index)) {
            g.save_selected_curve(&mut *self.model.ids, name);
        }
        self.drain_graph_events();
    }

    /// Applies what the value graphs reported (`onEdit`, `onSelectionChange`, ...) to the model.
    fn drain_graph_events(&mut self) {
        let props: Vec<EffectProperty> = self.value_graphs.keys().cloned().collect();
        for p in props {
            let Some(v) = self.value_graphs.get_mut(&p) else { continue };
            let mut all: Vec<(EffectComponent, KeyframeGraphEvent)> = Vec::new();
            for (c, g) in v.iter_mut() {
                all.extend(g.take_events().into_iter().map(|e| (*c, e)));
            }
            for (c, e) in all {
                match e {
                    KeyframeGraphEvent::Edit(t) => self.model.apply_graph_edit(&p, c, &t),
                    KeyframeGraphEvent::SelectionChange(ids) => self.model.set_selection_for(&p, &ids),
                    KeyframeGraphEvent::LibraryChange(lib) => {
                        self.model.easing_library = lib.clone();
                        self.model
                            .events
                            .push(crate::ec::effect_controls_model::core::EffectControlsEvent::LibraryChange(lib));
                    }
                    KeyframeGraphEvent::ModeChange(m) => self.model.set_graph_mode_for(m, &p),
                    KeyframeGraphEvent::Zoom { factor, anchor } => self.model.zoom(factor, Some(anchor)),
                    KeyframeGraphEvent::Pan(s) => self.model.pan_viewport(s),
                }
            }
        }
    }

    fn drain_panel_events(&mut self) {
        let top = self.top();
        for e in self.rows_panel.take_events() {
            match e {
                PanelEvent::Menu { menu, anchor } => self.show_menu(menu, offset_by(anchor, 0.0, top)),
                other => self.events.push(ViewEvent::Panel(other)),
            }
        }
    }

    fn drain_lane_menu(&mut self) {
        if let Some((menu, anchor)) = self.lanes.take_menu() {
            let (lx, top) = (self.lane_x(), self.top());
            self.show_menu(menu, offset_by(anchor, lx, top));
        }
    }

    /// A value graph's easing menu as a model menu (its rows hand the choice back through `MenuOutput::Graph`).
    fn graph_menu(
        property: &EffectProperty,
        index: usize,
        items: Vec<super::keyframe_graph_draw::GraphMenuItem>,
    ) -> ModelMenu {
        ModelMenu {
            entries: items
                .into_iter()
                .map(|gi| match gi.action {
                    Some(action) => {
                        let property = property.clone();
                        MenuEntry::action(gi.item, move |_, out| {
                            out.push(MenuOutput::Graph { property: property.clone(), index, action: action.clone() });
                        })
                    }
                    None => MenuEntry::plain(gi.item),
                })
                .collect(),
        }
    }

    /// A press at `p`.
    pub fn mouse_down(&mut self, cx: &mut UiCx, p: CGPoint, click_count: i64, modifiers: InputModifiers) {
        self.capture = self.part_at(p);
        self.press_modifiers = modifiers;
        match self.capture.clone() {
            Part::Rows => {
                self.lanes_focused = false;
                let rp = self.rows_point(p);
                self.rows_panel.mouse_down(&mut self.model, cx, rp, click_count, modifiers);
                self.drain_panel_events();
            }
            Part::Lanes => {
                self.lanes_focused = true;
                self.model.events.push(crate::ec::effect_controls_model::core::EffectControlsEvent::PointerDown);
                let lp = self.lane_point(p);
                self.lanes.mouse_down(&mut self.model, lp, modifiers);
                self.drain_lane_menu();
            }
            Part::Ruler => {
                self.lanes_focused = true;
                if !modifiers.contains(InputModifiers::SECONDARY) {
                    let rp = self.ruler_point(p);
                    self.ruler.mouse_down(&mut self.model, rp, modifiers);
                }
            }
            Part::Graph(prop) => {
                self.lanes_focused = true;
                self.model.events.push(crate::ec::effect_controls_model::core::EffectControlsEvent::PointerDown);
                let gp = self.graph_point(p, &prop);
                let secondary = modifiers.contains(InputModifiers::SECONDARY);
                if !self.is_speed(&prop) {
                    let Some(height) = self.graph_row(&prop).map(|r| r.height) else { return };
                    let parts = self.sync_value_graphs(&prop, CGSize::new(self.lanes_size().width, height));
                    let Some(i) = parts.iter().position(|r| gp.y < r.max_y()).or(parts.len().checked_sub(1)) else {
                        return;
                    };
                    let r = parts[i];
                    let lp = CGPoint::new(gp.x, gp.y - r.min_y());
                    if secondary {
                        self.capture = Part::None;
                        let items = self
                            .value_graphs
                            .get_mut(&prop)
                            .and_then(|v| v.get_mut(i))
                            .map(|(_, g)| g.context_menu(lp))
                            .unwrap_or_default();
                        self.drain_graph_events();
                        self.show_menu(Self::graph_menu(&prop, i, items), CGRect::new(p.x, p.y, 0.0, 0.0));
                    } else {
                        self.value_press = Some(i);
                        if let Some((_, g)) = self.value_graphs.get_mut(&prop).and_then(|v| v.get_mut(i)) {
                            g.mouse_down(lp, modifiers.contains(InputModifiers::SHIFT));
                        }
                        self.drain_graph_events();
                    }
                    return;
                }
                self.graph_pane(&prop);
                if secondary {
                    self.capture = Part::None;
                    let extra = EffectKeyframeLanesDraw::key_items(&self.model, true, self.has_prompt);
                    if let Some(g) = self.graphs.get(&prop) {
                        let menu = g.context_menu(&mut self.model, gp, extra);
                        self.show_menu(menu, CGRect::new(p.x, p.y, 0.0, 0.0));
                    }
                } else if let Some(g) = self.graphs.get_mut(&prop) {
                    g.press(&mut self.model, gp, modifiers.contains(InputModifiers::SHIFT));
                }
            }
            Part::GraphEditor => {
                self.lanes_focused = true;
                self.model.events.push(crate::ec::effect_controls_model::core::EffectControlsEvent::PointerDown);
                let lp = self.lane_point(p);
                if modifiers.contains(InputModifiers::SECONDARY) {
                    self.capture = Part::None;
                    let on_key = self.graph_editor.context_menu(&mut self.model, lp);
                    let menu = EffectKeyframeLanesDraw::key_items(&self.model, on_key, self.has_prompt);
                    self.show_menu(menu, CGRect::new(p.x, p.y, 0.0, 0.0));
                } else {
                    self.graph_editor.mouse_down(&mut self.model, lp, modifiers);
                }
            }
            Part::Divider => self.divider = Some((p.x, self.lane_x())),
            Part::Header | Part::None => {}
        }
        self.sync_lanes();
    }

    /// Drag to `p`; `modifiers` default to those of the press.
    pub fn mouse_dragged(&mut self, cx: &mut UiCx, p: CGPoint, modifiers: Option<InputModifiers>) {
        let m = modifiers.unwrap_or(self.press_modifiers);
        match self.capture.clone() {
            Part::Rows => {
                let rp = self.rows_point(p);
                self.rows_panel.mouse_dragged(&mut self.model, cx, rp, modifiers);
                self.drain_panel_events();
            }
            Part::Lanes => {
                let lp = self.lane_point(p);
                self.lanes.mouse_dragged(&mut self.model, lp, m);
            }
            Part::Ruler => {
                let rp = self.ruler_point(p);
                self.ruler.mouse_dragged(&mut self.model, rp, m);
            }
            Part::Graph(prop) => {
                let gp = self.graph_point(p, &prop);
                if let Some(i) = self.value_press {
                    let Some(height) = self.graph_row(&prop).map(|r| r.height) else { return };
                    let parts = self.sync_value_graphs(&prop, CGSize::new(self.lanes_size().width, height));
                    if let (Some(r), Some((_, g))) =
                        (parts.get(i), self.value_graphs.get_mut(&prop).and_then(|v| v.get_mut(i)))
                    {
                        g.mouse_dragged(CGPoint::new(gp.x, gp.y - r.min_y()), m.contains(InputModifiers::SHIFT));
                    }
                    self.drain_graph_events();
                } else {
                    let row_y = self.graph_row(&prop).map_or(0.0, |r| r.y);
                    if let Some(g) = self.graphs.get_mut(&prop) {
                        let mut bridge = LanesBeside { lanes: &mut self.lanes, row_y };
                        g.drag_gesture(&mut self.model, gp, m.contains(InputModifiers::SHIFT), &mut bridge);
                    }
                }
            }
            Part::GraphEditor => {
                let lp = self.lane_point(p);
                self.graph_editor.mouse_dragged(&mut self.model, lp, m);
            }
            Part::Divider => {
                if let Some(d) = self.divider {
                    self.set_label_width(d.1 + p.x - d.0);
                }
            }
            Part::Header | Part::None => {}
        }
        self.sync_lanes();
    }

    /// Release at `p`.
    pub fn mouse_up(&mut self, cx: &mut UiCx, p: CGPoint) {
        match self.capture.clone() {
            Part::Rows => {
                let rp = self.rows_point(p);
                self.rows_panel.mouse_up(&mut self.model, cx, rp);
                self.drain_panel_events();
            }
            Part::Lanes => {
                let lp = self.lane_point(p);
                self.lanes.mouse_up(&mut self.model, lp);
            }
            Part::Ruler => self.ruler.mouse_up(&mut self.model),
            Part::Graph(prop) => {
                if let Some(i) = self.value_press {
                    let Some(height) = self.graph_row(&prop).map(|r| r.height) else { return };
                    let gp = self.graph_point(p, &prop);
                    let parts = self.sync_value_graphs(&prop, CGSize::new(self.lanes_size().width, height));
                    if let (Some(r), Some((_, g))) =
                        (parts.get(i), self.value_graphs.get_mut(&prop).and_then(|v| v.get_mut(i)))
                    {
                        g.mouse_up(CGPoint::new(gp.x, gp.y - r.min_y()));
                    }
                    self.drain_graph_events();
                } else {
                    let row_y = self.graph_row(&prop).map_or(0.0, |r| r.y);
                    if let Some(g) = self.graphs.get_mut(&prop) {
                        let mut bridge = LanesBeside { lanes: &mut self.lanes, row_y };
                        g.release(&mut self.model, &mut bridge);
                    }
                }
                self.value_press = None;
            }
            Part::GraphEditor => {
                let lp = self.lane_point(p);
                self.graph_editor.mouse_up(&mut self.model, lp);
            }
            Part::Divider => {
                if self.divider.is_some() {
                    self.events.push(ViewEvent::PersistLabelWidth(self.label_width));
                }
                self.divider = None;
            }
            Part::Header | Part::None => {}
        }
        self.capture = Part::None;
        self.sync_lanes();
    }

    /// The pointer moved over the panel (`None`: it left).
    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        let at = p.map_or(Part::None, |p| self.part_at(p));
        self.hover_part = at.clone();
        let rows = if at == Part::Rows { p.map(|p| self.rows_point(p)) } else { None };
        self.rows_panel.mouse_moved(&mut self.model, rows);
        let lanes = if at == Part::Lanes { p.map(|p| self.lane_point(p)) } else { None };
        self.lanes.mouse_moved(&self.model, lanes);
        let ruler = if at == Part::Ruler { p.map(|p| self.ruler_point(p)) } else { None };
        self.ruler.mouse_moved(&self.model, ruler);
        let editor = if at == Part::GraphEditor { p.map(|p| self.lane_point(p)) } else { None };
        self.graph_editor.mouse_moved(editor);
        let props: Vec<EffectProperty> = self.graphs.keys().cloned().collect();
        for prop in props {
            let q = if at == Part::Graph(prop.clone()) { p.map(|p| self.graph_point(p, &prop)) } else { None };
            if let Some(g) = self.graphs.get_mut(&prop) {
                g.mouse_moved(&self.model, q);
            }
        }
        let vprops: Vec<EffectProperty> = self.value_graphs.keys().cloned().collect();
        for prop in vprops {
            let h = self.graph_row(&prop).map_or(0.0, |r| r.height);
            let n = self.value_graphs.get(&prop).map_or(1, |v| v.len().max(1));
            let per = h / n as f64;
            let base = if at == Part::Graph(prop.clone()) { p.map(|p| self.graph_point(p, &prop)) } else { None };
            if let Some(v) = self.value_graphs.get_mut(&prop) {
                for (i, e) in v.iter_mut().enumerate() {
                    e.1.mouse_moved(base.map(|gp| CGPoint::new(gp.x, gp.y - i as f64 * per)));
                }
            }
        }
    }

    /// True while a press is captured by a part.
    pub fn is_dragging(&self) -> bool {
        self.capture != Part::None
    }

    /// Sets the divider position (clamped) and lays out again.
    pub fn set_label_width(&mut self, w: f64) {
        let c = EffectControlsSplit::clamp(w, self.size.width);
        if c == self.label_width {
            return;
        }
        self.label_width = c;
        self.layout();
    }

    /// Tooltip at `p`: a row's help, a key's shape, the clip's kind and duration.
    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.part_at(p) {
            Part::Rows => self.rows_panel.help(&self.model, self.rows_point(p)),
            Part::Lanes => self.lanes.help(&self.model, self.lane_point(p)),
            Part::GraphEditor => self.graph_editor.help(self.lane_point(p)).map(SQL10n::string),
            Part::Header if p.y < ControlsMetrics::CLIP_LINE => self.clip_info_tip(),
            _ => None,
        }
    }

    /// Wheel: over the lanes or ruler horizontal pans and Option / Ctrl zooms; plain vertical scrolls the rows (and with
    /// them the lanes).
    pub fn scroll(
        &mut self,
        cx: &mut UiCx,
        p: CGPoint,
        dx: f64,
        dy: f64,
        precise: bool,
        modifiers: InputModifiers,
    ) -> bool {
        let at = self.part_at(p);
        let g: Option<ScrollGesture> = cx.gesture;
        let (lp, rup) = (self.lane_point(p), self.ruler_point(p));
        if at == Part::GraphEditor && self.graph_editor.scroll(&mut self.model, lp, dx, dy, modifiers, g.as_ref()) {
            return true;
        }
        if (at == Part::Lanes || matches!(at, Part::Graph(_)))
            && self.lanes.scroll(&mut self.model, lp, dx, dy, modifiers, g.as_ref())
        {
            return true;
        }
        if at == Part::Ruler && self.ruler.scroll(&mut self.model, rup, dx, dy, modifiers, g.as_ref()) {
            return true;
        }
        // Over the lanes the rows scroll at a point no field sits under.
        let rp = if at == Part::Rows { self.rows_point(p) } else { CGPoint::new(-1.0, p.y - self.top()) };
        let used = self.rows_panel.scroll(
            &mut self.model,
            cx,
            rp,
            dy,
            precise,
            if at == Part::Rows { modifiers } else { InputModifiers::NONE },
        );
        self.sync_lanes();
        used
    }

    /// The keyboard left the panel: a typed value commits and no field keeps the focus.
    pub fn blur(&mut self, cx: &mut UiCx) {
        self.rows_panel.blur(&mut self.model, cx);
        self.drain_panel_events();
    }

    /// A key for the panel.
    pub fn key(&mut self, cx: &mut UiCx, k: InputKey, modifiers: InputModifiers) -> bool {
        // Cmd+C / X / V belong to Effect Controls whenever it has the keys (the host only sends them here when the panel is
        // focused), not only with the lanes focused: the selected keyframes, else the selected effect (the AppKit
        // `copyFocused` / `cutFocused` / `pasteFocused`). While a value is typed they edit the text instead. Without
        // anything to copy or paste, the key falls through to the timeline.
        if modifiers == InputModifiers::COMMAND
            && self.rows_panel.focused_field().is_none()
            && self.rows_panel.focused_text().is_none()
        {
            match k {
                InputKey::Character('c') if self.model.can_copy_focused() => return self.model.copy_focused(),
                InputKey::Character('x') if self.model.can_cut_focused() => {
                    self.model.cut_focused();
                    return true;
                }
                InputKey::Character('v') if self.model.can_paste_focused() || self.model.has_key_clipboard() => {
                    let _ = self.model.paste_focused();
                    return true;
                }
                _ => {}
            }
        }
        if self.lanes_focused {
            if modifiers.contains(InputModifiers::COMMAND) {
                match k {
                    InputKey::Character('c') => return self.model.copy_keys(),
                    InputKey::Character('v') => return self.model.paste_keys(),
                    _ => {}
                }
            }
            if self.editor_on() {
                if self.graph_editor.key(&mut self.model, k, modifiers) {
                    return true;
                }
            } else if self.lanes.key(&mut self.model, k, modifiers) {
                return true;
            }
        }
        let mut used = self.rows_panel.key(&mut self.model, cx, k, modifiers);
        // Delete / Backspace remove the selected keys, else the selected effect or mask, with the rows focused too (a
        // click on a section header selects the section but gives the keys to the rows, not the lanes). A value being
        // typed keeps its Backspace. Nothing selected: the key is not taken and never reaches the timeline's clips.
        if !used
            && matches!(k, InputKey::Delete | InputKey::Backspace)
            && (modifiers == InputModifiers::NONE || modifiers == InputModifiers::SHIFT)
            && !self.rows_panel.has_keyboard_focus()
            && self.model.can_delete_focused()
        {
            self.model.delete_selection_or_effect();
            used = true;
        }
        self.drain_panel_events();
        self.sync_lanes();
        used
    }

    // MARK: Pixels

    /// Host glue: an `InputEvent` in pixels, the panel at `origin` (points) in the window, `scale` pixels per point.
    // A drag keeps the modifiers of its press: matches Swift (`EffectControlsDrawPanel` passes `modifiers ?? pressModifiers`, and its
    // draw-event path sends none), although `InputEvent::MouseDragged` carries the live ones now.
    pub fn handle(&mut self, cx: &mut UiCx, e: &InputEvent, scale: f32, origin: CGPoint) -> bool {
        let pt = |x: f32, y: f32| CGPoint::new((x / scale) as f64 - origin.x, (y / scale) as f64 - origin.y);
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = pt(x, y);
                let n = self.clicks.press(p.x as f32, p.y as f32, cx.now);
                self.mouse_down(cx, p, n, modifiers);
            }
            InputEvent::MouseDragged { x, y, .. } => self.mouse_dragged(cx, pt(x, y), None),
            InputEvent::MouseUp { x, y } => self.mouse_up(cx, pt(x, y)),
            InputEvent::MouseMoved { x, y } => {
                let p = pt(x, y);
                self.mouse_moved(Some(p));
                let tip = self.help(p);
                cx.hover.offer_tip(tip.as_deref());
            }
            InputEvent::Scroll { x, y, dx, dy, modifiers } => {
                return self.scroll(cx, pt(x, y), (dx / scale) as f64, (dy / scale) as f64, true, modifiers);
            }
            InputEvent::KeyDown { key, modifiers } => return self.key(cx, key, modifiers),
        }
        true
    }
}
