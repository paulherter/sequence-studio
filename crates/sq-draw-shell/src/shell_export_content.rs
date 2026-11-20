// Swift: ShellExportSheet.swift
//! The Export sheet's drawn body (`ExportDialogView`, 1000 x 740 card): header with the title, the sequence, the preset popup
//! and the add button; a 360 pt left column with the preview box, the scrub bar, the output list and the warnings; the right
//! column with the folding settings sections ([`crate::shell_export_items`]). The dialog around it draws the footer band
//! (summary, Cancel, Export, Other Formats).
//!
//! The body edits the shared [`ExportDialogModel`] live, like the Mac view. What only the flow can do (folder chooser, stems,
//! cut-downs, audio check, a new preview frame) leaves as change ids: `folder`, `stems_run`, `cuts_run`, `audio_check`,
//! `model`, `preview_play`, `preview_scrub`, `preview_step`.

use crate::shell_dialog::{FormValue, PopupRequest, ShellDialogContent};
use crate::shell_export_items::{self as items, Item, Kind, Outcome, Rows, Section, Tone, Val, Width};
use crate::shell_form::{PreviewTransport, segment_draw};
use sq_core_time::Id;
use sq_draw::inspector::inspector_controls::{CheckState, Direction};
use sq_draw::inspector::scrub_field_control::Event;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{metrics, radius};
use sq_draw::{
    Canvas, ClickCounter, Color, DrawTheme, InputEvent, InputKey, InspectorDraw, InspectorTokens, ScrubFieldControl,
    TextAlign, TextFieldControl, UiCx,
};
use sq_editor_session::{ExportDialogModel, ExportPreviewMath};
use sq_export::core::preset::ExportPreset;
use sq_export::core::settings::VideoCodec;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

/// The model the sheet and its flow share.
pub(crate) type SharedModel = Rc<RefCell<ExportDialogModel>>;

/// `ShellExportSheet.M`.
pub(crate) mod m {
    pub const HEADER_H: f64 = 52.0;
    pub const LEFT_W: f64 = 360.0;
    /// A sheet narrower than this (a small window) uses the compact left column and card inset.
    pub const COMPACT_BELOW: f64 = 900.0;
    pub const LEFT_W_COMPACT: f64 = 220.0;
    pub const CARD_INSET_COMPACT: f64 = 12.0;
    /// A settings row narrower than this puts its controls closer to the label.
    /// The narrowest a row's label column gets when its controls need the room.
    pub const MIN_LABEL_W: f64 = 60.0;
    pub const CONTROL_X_COMPACT: f64 = 100.0;
    pub const PAD_X: f64 = 20.0;
    /// The header's right padding (the preset popup and the add button end here).
    pub const HEADER_PAD_R: f64 = 16.0;
    pub const BOX_H: f64 = 250.0;
    pub const PLAYER_H: f64 = 24.0;
    pub const FIELD_H: f64 = 22.0;
    pub const LIST_ROW_H: f64 = 32.0;
    pub const LIST_INSET: f64 = 4.0;
    /// Redesign R4b: each section is a card (`Export` frame): 32 pt rows with a hairline between them, 24 from the edges.
    pub const ROW_H: f64 = 38.0;
    /// The More settings bar.
    pub const BAR_H: f64 = 32.0;
    pub const CARD_INSET: f64 = 24.0;
    pub const CARD_RADIUS: f64 = 8.0;
    pub const LABEL_X: f64 = 14.0;
    pub const CONTROL_X: f64 = 150.0;
    pub const TRAILING: f64 = 14.0;
    /// A fill item (popup, path) never grows past this: the controls sit at the right edge of the row.
    pub const FILL_MAX: f64 = 200.0;
    /// The 7 pt row padding: a top-aligned label starts here, its hint lines follow 3 pt under it.
    pub const ROW_PAD: f64 = 7.0;
    pub const HINT_LINE_H: f64 = 15.0;
    pub const GAP: f64 = 8.0;
    pub const HEADER_H2: f64 = 21.0;
    pub const SECTION_GAP: f64 = 18.0;
    /// Redesign R4f: the essentials card starts 16 below the top; the More settings bar sits 16 below it.
    pub const COLUMN_TOP: f64 = 20.0;
    pub const MORE_GAP: f64 = 22.0;
    pub const RESULT_H: f64 = 110.0;
    pub const BODY: f64 = 11.0;
    pub const CAPTION: f64 = 10.0;
    pub const TITLE: f64 = 13.0;
    pub const CHECK_BOX: f64 = 14.0;
    pub const BUTTON_PAD: f64 = 11.0;
    pub const SCRUB_INSET: f64 = 8.0;
}

/// The key of the "More settings" fold bar (closed until opened; the choice lasts for the session).
pub(crate) const MORE_KEY: &str = "export.more";

fn more_is_open() -> bool {
    OPEN.with(|o| o.borrow().get(MORE_KEY).copied().unwrap_or(false))
}

/// Segment `k` of a segmented track (joined, 1 pt inside the track) or of a row of chips (4 pt apart).
fn segment_rect(f: CGRect, k: usize, width: f64, chips: bool) -> CGRect {
    if chips {
        CGRect::new(f.min_x() + k as f64 * (width + 4.0), f.min_y(), width, f.height)
    } else {
        CGRect::new(f.min_x() + 1.0 + k as f64 * width, f.min_y(), width, f.height)
    }
}

/// Where a control sits: section, row, item.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Path {
    pub s: usize,
    pub r: usize,
    pub i: usize,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Target {
    Add,
    Preset,
    Play,
    Picture,
    Scrub,
    OutputCheck(Id),
    Output(Id),
    Variants,
    Section(&'static str),
    Item(Path),
    Segment(Path, usize),
}

/// What a popup list of the sheet picked (the menu action runs inside the dialog's event; the sheet applies it next).
#[derive(Clone, Copy, Debug)]
enum Pick {
    Preset(usize),
    Item(Path, usize),
}

thread_local! {
    /// Open state per section key, kept for the session (`InspectorSection`'s remembered state).
    static OPEN: RefCell<BTreeMap<&'static str, bool>> = const { RefCell::new(BTreeMap::new()) };
}

/// Green of a passed audio check (the Mac `DrawTheme.green`, system green).
const GREEN: Color = Color { r: 0.204, g: 0.78, b: 0.349, a: 1.0 };

fn warning_color(t: &DrawTheme) -> Color {
    let p = t.palette.warning;
    Color::new((p.r / 255.0) as f32, (p.g / 255.0) as f32, (p.b / 255.0) as f32, p.a as f32)
}

fn dim(c: Color, a: f32) -> Color {
    Color::new(c.r, c.g, c.b, c.a * a)
}

type Measure<'a> = &'a dyn Fn(&str, f64) -> f64;

/// What the label column of a row draws besides the title.
#[derive(Clone, Debug, Default)]
struct RowNote {
    label_w: f64,
    top_label: bool,
    hint_lines: Vec<String>,
    /// Width of the hint lines and the offset of the first line from the row top.
    hint_w: f64,
    hint_top: f64,
}

struct Chip {
    text: String,
    warning: bool,
    frame: CGRect,
}

#[derive(Default)]
struct Blocks {
    warning: CGRect,
    chips: Vec<Chip>,
    hint: CGRect,
    hint_lines: Vec<String>,
    variants: CGRect,
    /// The Result block: a 18 pt title and the card under it.
    result: CGRect,
}

pub(crate) struct Inner {
    model: SharedModel,
    offered: Vec<ExportPreset>,
    codecs: Vec<VideoCodec>,
    can_choose_folder: bool,
    can_copy: bool,
    slot: usize,
    sections: Vec<Section>,
    custom_size: bool,
    name: TextFieldControl,
    name_focused: bool,
    scrubs: BTreeMap<Path, ScrubFieldControl>,
    editing_scrub: Option<Path>,
    scrubbing: Option<Path>,
    frame: CGRect,
    line_h: f64,
    scroll: f64,
    column_height: f64,
    /// Height at the column's foot kept free for the pinned, closed More settings bar (0 = the bar flows with the rows).
    pin_h: f64,
    targets: Vec<(Target, CGRect)>,
    row_frames: Vec<(String, bool, CGRect)>,
    /// One per row frame: what the label column draws besides the title.
    row_notes: Vec<RowNote>,
    card_frames: Vec<CGRect>,
    header_frames: Vec<(&'static str, bool, bool, CGRect)>,
    item_frames: BTreeMap<Path, CGRect>,
    list_frame: CGRect,
    list_scroll: f64,
    blocks: Blocks,
    hover: Option<Target>,
    pressed: Option<Target>,
    clicks: ClickCounter,
    scrubbing_preview: bool,
    transport: PreviewTransport,
    picture: (i64, i64, bool),
    changes: Vec<(String, FormValue)>,
    popup: Option<PopupRequest>,
    picks: Rc<RefCell<Vec<Pick>>>,
    copy: Option<String>,
    dirty: bool,
}

/// The handle the dialog and the flow share.
#[derive(Clone)]
pub struct ShellExportSheet(pub(crate) Rc<RefCell<Inner>>);

impl ShellExportSheet {
    /// A sheet over `model`; `offered` are the presets the encoder writes, `slot` the renderer slot of the preview.
    pub(crate) fn new(
        model: SharedModel,
        offered: Vec<ExportPreset>,
        codecs: Vec<VideoCodec>,
        can_choose_folder: bool,
        can_copy: bool,
        slot: usize,
    ) -> ShellExportSheet {
        let mut name = TextFieldControl::new(&model.borrow().file_name());
        name.alignment = sq_draw::Alignment::Left;
        name.font_size = m::BODY;
        let mut inner = Inner {
            model,
            offered,
            codecs,
            can_choose_folder,
            can_copy,
            slot,
            sections: Vec::new(),
            custom_size: false,
            name,
            name_focused: false,
            scrubs: BTreeMap::new(),
            editing_scrub: None,
            scrubbing: None,
            frame: CGRect::default(),
            line_h: 14.0,
            scroll: 0.0,
            column_height: 0.0,
            pin_h: 0.0,
            targets: Vec::new(),
            row_frames: Vec::new(),
            row_notes: Vec::new(),
            card_frames: Vec::new(),
            header_frames: Vec::new(),
            item_frames: BTreeMap::new(),
            list_frame: CGRect::default(),
            list_scroll: 0.0,
            blocks: Blocks::default(),
            hover: None,
            pressed: None,
            clicks: ClickCounter::new(),
            scrubbing_preview: false,
            transport: PreviewTransport::default(),
            picture: (16, 9, false),
            changes: Vec::new(),
            popup: None,
            picks: Rc::default(),
            copy: None,
            dirty: true,
        };
        inner.rebuild();
        ShellExportSheet(Rc::new(RefCell::new(inner)))
    }

    /// New rows from the model (the Mac `reload()`).
    pub fn rebuild(&self) {
        self.0.borrow_mut().rebuild();
    }

    /// The preview picture's size and whether its image slot holds it.
    pub fn set_picture(&self, width: i64, height: i64, ready: bool) {
        self.0.borrow_mut().picture = (width, height, ready);
    }

    /// The scrub bar under the picture.
    pub fn set_transport(&self, t: PreviewTransport) {
        self.0.borrow_mut().transport = t;
    }

    /// Commits a typed name or number (the Export button reads them, as the Mac `exportTapped`).
    pub fn commit_editing(&self) {
        let mut i = self.0.borrow_mut();
        i.end_name_editing();
        i.end_scrub_editing();
    }

    /// The settings sections as the column shows them.
    #[cfg(test)]
    pub(crate) fn sections(&self) -> Vec<Section> {
        self.0.borrow().sections.clone()
    }

    /// The control rectangles, by section, row and item (tests).
    #[cfg(test)]
    pub(crate) fn item_frames(&self) -> BTreeMap<Path, CGRect> {
        self.0.borrow().item_frames.clone()
    }

    /// The header frames of the column (tests).
    #[cfg(test)]
    pub(crate) fn header_frames(&self) -> Vec<(&'static str, bool, bool, CGRect)> {
        self.0.borrow().header_frames.clone()
    }

    /// The row frames of the column (tests).
    #[cfg(test)]
    pub(crate) fn row_frames(&self) -> Vec<(String, bool, CGRect)> {
        self.0.borrow().row_frames.clone()
    }

    /// Frames of the fixed parts (tests).
    #[cfg(test)]
    pub(crate) fn parts(&self) -> [CGRect; 5] {
        let i = self.0.borrow();
        [i.column_frame(), i.preview_frame(), i.scrub_frame(), i.add_frame(), i.preset_frame()]
    }

    /// Delivers `v` to the control at `path` as the user would (tests).
    #[cfg(test)]
    pub(crate) fn deliver(&self, path: Path, v: Val) {
        let mut i = self.0.borrow_mut();
        let Some(item) = i.item(path) else { return };
        i.run(&item, &v, true);
    }

    /// The model the sheet edits.
    #[cfg(test)]
    pub(crate) fn model(&self) -> SharedModel {
        Rc::clone(&self.0.borrow().model)
    }
}

impl Inner {
    /// The flow holds the model (the preflight questions run on it after the sheet answered): the sheet stays still.
    fn locked(&self) -> bool {
        self.model.try_borrow_mut().is_err()
    }

    fn presets(&self) -> Vec<ExportPreset> {
        let offered: Vec<String> = self.offered.iter().map(|p| p.id()).collect();
        self.model.borrow().presets().into_iter().filter(|p| offered.contains(&p.id())).collect()
    }

    fn rebuild(&mut self) {
        self.scrubs.clear();
        self.editing_scrub = None;
        let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).ok();
        let model = self.model.borrow();
        let rows = Rows {
            model: &model,
            codecs: &self.codecs,
            custom_size: self.custom_size,
            home,
            can_copy: self.can_copy,
            can_choose_folder: self.can_choose_folder,
            support: model.encoder_support(),
        };
        self.sections = rows.sections();
        if !self.name.is_editing() {
            self.name.text = model.file_name();
        }
        drop(model);
        for (si, s) in self.sections.iter().enumerate() {
            for (ri, r) in s.rows.iter().enumerate() {
                for (ii, it) in r.items.iter().enumerate() {
                    if let Kind::Scrub(spec) = &it.kind {
                        let mut f = ScrubFieldControl::new(spec.value);
                        f.well = true;
                        f.range = spec.min..=spec.max;
                        f.step = spec.step;
                        f.decimals = spec.decimals;
                        f.default_value = spec.default;
                        f.is_enabled = it.enabled;
                        self.scrubs.insert(Path { s: si, r: ri, i: ii }, f);
                    }
                }
            }
        }
        self.dirty = true;
    }

    fn is_open(&self, s: &Section) -> bool {
        OPEN.with(|o| o.borrow().get(s.key).copied().unwrap_or(s.default_open))
    }

    fn item(&self, p: Path) -> Option<Item> {
        self.sections.get(p.s)?.rows.get(p.r)?.items.get(p.i).cloned()
    }

    // MARK: Layout

    /// The left column's width: 360 on a wide sheet, narrower on a small window so the settings column keeps room for its
    /// controls (the preview and the output list shrink with it).
    fn left_w(&self) -> f64 {
        if self.frame.width >= m::COMPACT_BELOW { m::LEFT_W } else { m::LEFT_W_COMPACT }
    }

    /// The gap between the settings cards and the column edges.
    fn card_inset(&self) -> f64 {
        if self.frame.width >= m::COMPACT_BELOW { m::CARD_INSET } else { m::CARD_INSET_COMPACT }
    }

    /// The part of the column that scrolls: the column minus the pinned More settings bar.
    fn viewport(&self) -> CGRect {
        let col = self.column_frame();
        CGRect::new(col.min_x(), col.min_y(), col.width, (col.height - self.pin_h).max(0.0))
    }

    fn column_frame(&self) -> CGRect {
        let f = self.frame;
        CGRect::new(f.min_x() + self.left_w(), f.min_y() + m::HEADER_H, f.width - self.left_w(), f.height - m::HEADER_H)
    }

    fn preview_frame(&self) -> CGRect {
        let f = self.frame;
        let width = self.left_w() - 2.0 * m::PAD_X;
        // A compact sheet keeps the 16:9 picture box of its narrower column instead of the tall 250.
        let height = if self.frame.width >= m::COMPACT_BELOW { m::BOX_H } else { (width * 9.0 / 16.0).round() };
        CGRect::new(f.min_x() + m::PAD_X, f.min_y() + m::HEADER_H + 20.0, width, height)
    }

    /// `ExportScrubBar`: from the play button to the timecode column (78), 8 apart.
    fn scrub_frame(&self) -> CGRect {
        let bar_x = self.frame.min_x() + m::PAD_X + 24.0 + 8.0;
        CGRect::new(
            bar_x,
            self.preview_frame().max_y() + 10.0,
            self.frame.min_x() + self.left_w() - m::PAD_X - 78.0 - 8.0 - bar_x,
            m::PLAYER_H,
        )
    }

    fn scrub_fraction(&self, x: f64) -> f64 {
        let r = self.scrub_frame();
        ((x - r.min_x() - m::SCRUB_INSET) / (r.width - 2.0 * m::SCRUB_INSET).max(1.0)).clamp(0.0, 1.0)
    }

    fn add_frame(&self) -> CGRect {
        let f = self.frame;
        CGRect::new(
            f.max_x() - m::HEADER_PAD_R - 24.0,
            f.min_y() + ((m::HEADER_H - m::FIELD_H) / 2.0).round(),
            24.0,
            m::FIELD_H,
        )
    }

    fn preset_frame(&self) -> CGRect {
        let a = self.add_frame();
        CGRect::new(a.min_x() - 10.0 - 260.0, a.min_y(), 260.0, m::FIELD_H)
    }

    /// The header's sequence name column: from after the title to 8 before the "Preset" label, at most 260 wide (a long name
    /// ran into the label at 640 x 400).
    fn seq_name_frame(&self) -> CGRect {
        let x = self.frame.min_x() + m::PAD_X + 48.0 + 12.0;
        let label_left = self.preset_frame().min_x() - 8.0 - 44.0;
        CGRect::new(x, self.frame.min_y(), (label_left - 8.0 - x).clamp(0.0, 260.0), m::HEADER_H)
    }

    fn play_frame(&self) -> CGRect {
        CGRect::new(self.frame.min_x() + m::PAD_X, self.preview_frame().max_y() + 10.0, 24.0, m::PLAYER_H)
    }

    fn layout_all(&mut self, w: Measure) {
        self.dirty = false;
        let add = self.add_frame();
        let preset = self.preset_frame();
        self.targets = vec![(Target::Add, add), (Target::Preset, preset)];
        let bar = self.preview_frame().max_y() + 10.0;
        self.targets.push((Target::Play, self.play_frame()));
        self.targets.push((Target::Scrub, self.scrub_frame()));
        self.targets.push((Target::Picture, self.preview_frame()));
        self.layout_list(w, bar);
        self.layout_column(w);
    }

    fn layout_list(&mut self, w: Measure, bar_y: f64) {
        let width = self.left_w() - 2.0 * m::PAD_X;
        let x = self.frame.min_x() + m::PAD_X;
        let line_h = self.line_h;
        let model = self.model.borrow();
        let rows = model.output_rows();
        let content_h = m::LIST_INSET * 2.0 + rows.len() as f64 * m::LIST_ROW_H;
        let top = bar_y + m::PLAYER_H + 38.0;
        let warning = model.validation_messages().into_iter().next().unwrap_or_default();
        let chip_h = f64::from(metrics::CAPSULE);
        let (mut cx, mut cy) = (0.0, 0.0);
        let mut chips: Vec<Chip> = Vec::new();
        for issue in model.delivery_issues() {
            let text = SQL10n::localized(&issue.text);
            let cw = w(&text, m::CAPTION).ceil() + 24.0;
            if cx > 0.0 && cx + cw > width {
                cx = 0.0;
                cy += chip_h + 4.0;
            }
            let warning = issue.severity == sq_export::core::delivery::DeliverySeverity::Warning;
            chips.push(Chip { text, warning, frame: CGRect::new(cx, cy, cw, chip_h) });
            cx += cw + 4.0;
        }
        let chips_h = if chips.is_empty() { 0.0 } else { cy + chip_h };
        // The left column flows from the top like the kit: list, Result block, the note, then chips and the warning.
        // Six rows show; more scroll inside the field.
        let h = content_h.min(2.0 * m::LIST_INSET + 6.0 * m::LIST_ROW_H);
        let mut next = top + h;
        let mut variants = CGRect::default();
        let has_variants = model.has_variants();
        if has_variants {
            variants = CGRect::new(x, next + 6.0, width, 18.0);
            next = variants.max_y();
        }
        let result = CGRect::new(x, next + 22.0, width, 18.0 + m::RESULT_H);
        next = result.max_y();
        // The notes wrap instead of ending in an ellipsis: "Hardware encoder; it falls back to software ..." is the whole advice.
        let hint_lines = wrap_lines(&model.export_notes(), width - 20.0, &|t| w(t, m::BODY));
        let hint_h = hint_lines.len() as f64 * line_h;
        let hint_rect = CGRect::new(x + 20.0, next + 20.0, width - 20.0, hint_h);
        if !hint_lines.is_empty() {
            next = hint_rect.max_y();
        }
        for c in &mut chips {
            c.frame = CGRect::new(c.frame.min_x() + x, c.frame.min_y() + next + 10.0, c.frame.width, c.frame.height);
        }
        if chips_h > 0.0 {
            next += 10.0 + chips_h;
        }
        let warn_h = if warning.is_empty() { 0.0 } else { line_h * 2.0 };
        let warn_rect = CGRect::new(x, next + 6.0, width, warn_h);
        drop(model);
        if has_variants {
            self.targets.push((Target::Variants, variants));
        }
        self.blocks = Blocks { warning: warn_rect, chips, hint: hint_rect, hint_lines, variants, result };
        self.list_frame = CGRect::new(x, top, width, h);
        self.list_scroll = self.list_scroll.clamp(0.0, (content_h - h).max(0.0));
        for (i, r) in rows.iter().enumerate() {
            let y = top + m::LIST_INSET + i as f64 * m::LIST_ROW_H - self.list_scroll;
            let row = CGRect::new(x, y, width, m::LIST_ROW_H);
            let (t, b) = (row.min_y().max(self.list_frame.min_y()), row.max_y().min(self.list_frame.max_y()));
            if b <= t {
                continue;
            }
            self.targets.push((Target::OutputCheck(r.id), CGRect::new(x + 4.0, t, 26.0, b - t)));
            self.targets.push((Target::Output(r.id), CGRect::new(x, t, width, b - t)));
        }
    }

    /// The settings column: section headers and rows from the top, scrolled by `scroll`.
    fn layout_column(&mut self, w: Measure) {
        let col = self.column_frame();
        self.row_frames.clear();
        self.row_notes.clear();
        self.card_frames.clear();
        self.header_frames.clear();
        self.item_frames.clear();
        let (colx, colw) = (col.min_x() + self.card_inset(), col.width - 2.0 * self.card_inset());
        self.pin_h = 0.0;
        let mut y = m::COLUMN_TOP;
        let sections = self.sections.clone();
        let more_open = more_is_open();
        let mut more_done = false;
        for (si, s) in sections.iter().enumerate() {
            if s.detail {
                if !more_done {
                    more_done = true;
                    // A closed bar that would sit below the fold stays pinned at the column's foot, so it is
                    // always visible without scrolling (kit: the bar sits right under the card).
                    let flow_bottom = y + m::MORE_GAP + m::BAR_H + 16.0;
                    if !more_open && flow_bottom > col.height {
                        self.pin_h = m::BAR_H + 16.0 + 8.0;
                        let bar = CGRect::new(colx, col.max_y() - 16.0 - m::BAR_H, colw, m::BAR_H);
                        self.header_frames.push((MORE_KEY, more_open, false, bar));
                        self.targets.push((Target::Section(MORE_KEY), bar));
                    } else {
                        y += m::MORE_GAP;
                        let bar = CGRect::new(colx, col.min_y() + y - self.scroll, colw, m::BAR_H);
                        self.header_frames.push((MORE_KEY, more_open, false, bar));
                        self.targets.push((Target::Section(MORE_KEY), bar));
                        y += m::BAR_H;
                    }
                }
                if !more_open {
                    continue;
                }
                y += m::SECTION_GAP;
                let header = CGRect::new(colx, col.min_y() + y - self.scroll, colw, m::HEADER_H2);
                let open = self.is_open(s);
                self.header_frames.push((s.key, open, false, header));
                self.targets.push((Target::Section(s.key), header));
                y += m::HEADER_H2;
                if !open {
                    continue;
                }
            }
            let card_top = col.min_y() + y - self.scroll;
            for (ri, r) in s.rows.iter().enumerate() {
                let base_h = r.height.unwrap_or(m::ROW_H);
                let rect = CGRect::new(colx, col.min_y() + y - self.scroll, colw, base_h);
                let frames = Self::layout_items(&r.items, rect, r.top, w);
                // The label column ends 20 before the first control; the hint wraps inside it.
                let label_w =
                    frames.first().map_or(colw / 2.0, |f| f.min_x() - rect.min_x() - m::LABEL_X - 20.0).max(60.0);
                let text = if r.hint.is_empty() { String::new() } else { SQL10n::string(&r.hint) };
                let hint = row_hint(&text, label_w, colw - m::LABEL_X - 2.0 - m::TRAILING, base_h, &|t| w(t, m::BODY));
                let row_h = base_h + hint.extra_h;
                self.row_frames.push((r.title.clone(), r.dimmed, CGRect::new(colx, rect.min_y(), colw, row_h)));
                self.row_notes.push(RowNote {
                    label_w,
                    top_label: r.top.is_some() || !r.hint.is_empty(),
                    hint_lines: hint.lines,
                    hint_w: hint.width,
                    hint_top: hint.top,
                });
                for (ii, f) in frames.into_iter().enumerate() {
                    let p = Path { s: si, r: ri, i: ii };
                    self.item_frames.insert(p, f);
                    if let Kind::Segmented { labels, segment_width, chips, .. } = &r.items[ii].kind {
                        let sw = fitted_segment_width(f.width, labels.len(), *segment_width, *chips);
                        for k in 0..labels.len() {
                            self.targets.push((Target::Segment(p, k), segment_rect(f, k, sw, *chips)));
                        }
                    } else {
                        self.targets.push((Target::Item(p), f));
                    }
                }
                y += row_h;
            }
            self.card_frames.push(CGRect::new(colx, card_top, colw, col.min_y() + y - self.scroll - card_top));
        }
        self.column_height = y + if self.pin_h > 0.0 { 8.0 } else { 16.0 };
        let max_scroll = (self.column_height - self.viewport().height).max(0.0);
        if self.scroll > max_scroll {
            self.scroll = max_scroll;
            self.targets.retain(|t| !matches!(t.0, Target::Item(_) | Target::Segment(..) | Target::Section(_)));
            self.layout_column(w);
        }
    }

    /// `ExportSettingRow.layout`, right-aligned like the kit: fixed and fitted items keep their width, fill items share what
    /// is left (20 at least, [`m::FILL_MAX`] at most), and the group ends `TRAILING` before the row's right edge. `top` is the
    /// offset of the controls from the row top; without it they center in the row.
    pub(crate) fn layout_items(row_items: &[Item], row: CGRect, top: Option<f64>, w: Measure) -> Vec<CGRect> {
        let left = row.min_x() + if row.width < 420.0 { m::CONTROL_X_COMPACT } else { m::CONTROL_X };
        let right = row.max_x() - m::TRAILING;
        let widths: Vec<Option<f64>> = row_items
            .iter()
            .map(|i| match i.width {
                Width::Fill => None,
                Width::Fixed(v) => Some(v),
                Width::Fit => Some(fit_width(&i.kind, w)),
            })
            .collect();
        let mut widths = widths;
        // The controls never start left of the label's room; a segmented control or chip row that is wider than that
        // shrinks (its segments get narrower) instead of running past the row's right edge.
        let room = right - (row.min_x() + m::LABEL_X + m::MIN_LABEL_W).min(left);
        let fixed_now: f64 = widths.iter().flatten().sum::<f64>()
            + row_items.len().saturating_sub(1) as f64 * m::GAP
            + widths.iter().filter(|x| x.is_none()).count() as f64 * 20.0;
        if fixed_now > room {
            let shrinkable: Vec<usize> =
                (0..row_items.len()).filter(|&k| matches!(row_items[k].kind, Kind::Segmented { .. })).collect();
            if let Some(&k) = shrinkable.first() {
                let cut = fixed_now - room;
                widths[k] = widths[k].map(|v| (v - cut).max(40.0));
            }
        }
        let fixed: f64 = widths.iter().flatten().sum();
        let fills = widths.iter().filter(|x| x.is_none()).count();
        let gaps = row_items.len().saturating_sub(1) as f64 * m::GAP;
        let share =
            if fills > 0 { ((right - left - fixed - gaps) / fills as f64).clamp(20.0, m::FILL_MAX) } else { 0.0 };
        let total = fixed + fills as f64 * share + gaps;
        let mut x = (right - total).max(left.min(right));
        if right - total < left {
            // Wider than the control column: start further left, where the label still has room.
            x = (right - total).max(row.min_x() + m::LABEL_X + m::MIN_LABEL_W).min(x);
        }
        let mut out = Vec::new();
        for (i, item) in row_items.iter().enumerate() {
            let width = widths[i].unwrap_or(share).round();
            let h = match item.kind {
                Kind::Check { .. } => 16.0,
                Kind::Switch { .. } => 20.0,
                Kind::Text { .. } | Kind::Unit(_) if top.is_none() => row.height,
                _ => m::FIELD_H,
            };
            let y = top.map_or(((row.height - h) / 2.0).round(), |t| t + ((m::FIELD_H - h) / 2.0).round());
            out.push(CGRect::new(x.round(), row.min_y() + y, width, h));
            x += width + m::GAP;
        }
        out
    }

    fn target_at(&self, p: CGPoint) -> Option<Target> {
        let in_column = self.column_frame().contains(p);
        let in_list = self.list_frame.contains(p);
        self.targets
            .iter()
            .find(|(t, r)| {
                r.contains(p)
                    && match t {
                        Target::Item(_) | Target::Segment(..) | Target::Section(_) => in_column,
                        Target::Output(_) | Target::OutputCheck(_) => in_list,
                        _ => true,
                    }
            })
            .map(|t| t.0)
    }

    // MARK: Editing

    fn note(&mut self, id: &str, v: FormValue) {
        self.changes.push((id.to_string(), v));
    }

    /// Applies a control's value to the model; `last` = a committed value (rows may change).
    fn run(&mut self, it: &Item, v: &Val, last: bool) {
        let out: Outcome = items::apply(&mut self.model.borrow_mut(), &it.act, v);
        if let Some(c) = out.custom_size {
            self.custom_size = c;
        }
        if let Some(e) = out.event {
            self.note(e, FormValue::Index(0));
        } else if out.copy.is_none() {
            self.note("model", FormValue::Bool(true));
        }
        if out.copy.is_some() {
            self.copy = out.copy;
        }
        if out.rebuild && last && it.rebuild {
            self.rebuild();
        } else if last && out.event.is_none() {
            // A value that only moves the summary: the name field and the list still follow the model.
            self.dirty = true;
        }
    }

    /// Hands a number field's events to its action; a committed value (typed, stepped, drag end) rebuilds the rows.
    fn deliver_scrub(&mut self, events: Vec<Event>, p: Path) {
        let Some(it) = self.item(p) else { return };
        let mut last = None;
        for e in events {
            match e {
                Event::Begin => {}
                Event::Live(v) => self.run(&it, &Val::Number(v), false),
                Event::Change(v) | Event::End(v) | Event::Cancel(v) => last = Some(v),
            }
        }
        if let Some(v) = last {
            self.run(&it, &Val::Number(v), true);
        }
    }

    fn end_name_editing(&mut self) {
        if !self.name_focused {
            return;
        }
        self.name_focused = false;
        if let Some(s) = self.name.commit() {
            self.commit_name(&s);
        }
    }

    fn commit_name(&mut self, s: &str) {
        items::apply(&mut self.model.borrow_mut(), &items::Act::FileName, &Val::Text(s.to_string()));
        self.name.text = self.model.borrow().file_name();
        self.note("model", FormValue::Bool(true));
        self.rebuild();
    }

    fn end_scrub_editing(&mut self) {
        let Some(p) = self.editing_scrub.take() else { return };
        let Some(mut f) = self.scrubs.remove(&p) else { return };
        let events = f.commit_editing();
        self.scrubs.insert(p, f);
        self.deliver_scrub(events, p);
    }

    fn drain_picks(&mut self) {
        let picks: Vec<Pick> = std::mem::take(&mut *self.picks.borrow_mut());
        for pick in picks {
            match pick {
                Pick::Preset(i) => {
                    if let Some(p) = self.presets().get(i) {
                        self.model.borrow_mut().set_preset_id(&p.id());
                    }
                    self.custom_size = false;
                    self.note("model", FormValue::Bool(true));
                    self.rebuild();
                }
                Pick::Item(path, i) => {
                    if let Some(it) = self.item(path) {
                        self.run(&it, &Val::Index(i), true);
                    }
                }
            }
        }
    }

    fn press(&mut self, t: Option<Target>, p: CGPoint, x: f32, y: f32, now: f64) {
        let Some(t) = t else { return };
        match t {
            Target::Item(path) => {
                let Some(it) = self.item(path).filter(|i| i.enabled) else { return };
                match &it.kind {
                    Kind::Scrub(_) => {
                        let Some(mut f) = self.scrubs.remove(&path) else { return };
                        let n = self.clicks.press(x, y, now);
                        let ev = f.mouse_down(x, n);
                        self.scrubs.insert(path, f);
                        self.scrubbing = Some(path);
                        self.deliver_scrub(ev, path);
                    }
                    Kind::Popup { titles, selected, disabled } => {
                        let Some(r) = self.item_frames.get(&path).copied() else { return };
                        let menu = titles
                            .iter()
                            .enumerate()
                            .map(|(i, title)| {
                                let picks = Rc::clone(&self.picks);
                                let mut m = SQMenuItem::new(title);
                                m.is_enabled = !disabled.contains(&i);
                                m.is_checked = i == *selected;
                                m.action = Some(Rc::new(move || picks.borrow_mut().push(Pick::Item(path, i))));
                                m
                            })
                            .collect();
                        self.popup = Some(PopupRequest { items: menu, below: r });
                    }
                    _ => self.pressed = Some(t),
                }
            }
            Target::Segment(path, k) => {
                let Some(it) = self.item(path).filter(|i| i.enabled) else { return };
                if let Kind::Segmented { disabled, selected, .. } = &it.kind
                    && !disabled.contains(&k)
                    && k != *selected
                {
                    self.run(&it, &Val::Index(k), true);
                }
            }
            Target::Scrub => {
                if self.transport.frames == 0 {
                    return;
                }
                self.scrubbing_preview = true;
                let f = self.scrub_fraction(p.x);
                self.note("preview_scrub", FormValue::Number(f));
            }
            Target::Preset => {
                let list = self.presets();
                let current = self.model.borrow().shown_preset_id().to_string();
                let custom = !list.iter().any(|p| p.id() == current);
                let mut menu: Vec<SQMenuItem> = list
                    .iter()
                    .enumerate()
                    .map(|(i, pr)| {
                        let picks = Rc::clone(&self.picks);
                        let mut m = SQMenuItem::new(&SQL10n::localized(&pr.name()));
                        m.is_checked = pr.id() == current;
                        m.action = Some(Rc::new(move || picks.borrow_mut().push(Pick::Preset(i))));
                        m
                    })
                    .collect();
                if custom {
                    let mut m = SQMenuItem::new(&SQL10n::string("Custom"));
                    m.is_checked = true;
                    menu.push(m);
                }
                self.popup = Some(PopupRequest { items: menu, below: self.preset_frame() });
            }
            _ => self.pressed = Some(t),
        }
    }

    fn release(&mut self, t: Target) {
        match t {
            Target::Add => {
                self.model.borrow_mut().add_format(None);
                self.note("model", FormValue::Bool(true));
                self.rebuild();
            }
            Target::Play | Target::Picture => self.toggle_play(),
            Target::OutputCheck(id) => {
                let on = self.model.borrow().output_rows().iter().find(|r| r.id == id).is_some_and(|r| r.is_checked);
                self.model.borrow_mut().set_output_checked(id, !on);
                self.note("model", FormValue::Bool(true));
                self.rebuild();
            }
            Target::Output(id) => {
                self.model.borrow_mut().select_output(id);
                self.custom_size = false;
                self.note("model", FormValue::Bool(true));
                self.rebuild();
            }
            Target::Variants => {
                let on = self.model.borrow().export_all_formats();
                self.model.borrow_mut().set_export_all_formats(!on);
                self.rebuild();
            }
            Target::Section(key) => {
                if key == MORE_KEY {
                    let open = more_is_open();
                    OPEN.with(|o| o.borrow_mut().insert(MORE_KEY, !open));
                } else if let Some(s) = self.sections.iter().find(|s| s.key == key) {
                    let open = self.is_open(s);
                    OPEN.with(|o| o.borrow_mut().insert(s.key, !open));
                }
                self.dirty = true;
            }
            Target::Item(path) => {
                let Some(it) = self.item(path).filter(|i| i.enabled) else { return };
                match &it.kind {
                    Kind::Check { on, .. } | Kind::Switch { on } | Kind::Chip { on, .. } => {
                        self.run(&it, &Val::Bool(!on), true)
                    }
                    Kind::Button(_) | Kind::IconButton(_) => self.run(&it, &Val::Press, true),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn toggle_play(&mut self) {
        if self.transport.frames == 0 {
            return;
        }
        let playing = self.transport.playing;
        self.note("preview_play", FormValue::Bool(!playing));
    }

    fn handle(&mut self, e: &InputEvent, scale: f32, cx: &mut UiCx) -> bool {
        self.drain_picks();
        let s = f64::from(scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / s, f64::from(y) / s);
        match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let p = pt(x, y);
                let t = self.target_at(p);
                if let Some(Target::Item(path)) = t
                    && let Some(Kind::Field { .. }) = self.item(path).map(|i| i.kind)
                {
                    self.end_scrub_editing();
                    if !self.name_focused {
                        self.name_focused = true;
                        self.name.mouse_down(None, 1);
                    }
                    return true;
                }
                if let Some(Target::Item(path)) = t
                    && self.editing_scrub == Some(path)
                    && let Some(mut f) = self.scrubs.remove(&path)
                {
                    let n = self.clicks.press(x, y, cx.now);
                    let ev = f.mouse_down(x, n);
                    self.scrubs.insert(path, f);
                    self.deliver_scrub(ev, path);
                    return true;
                }
                self.commit_editing_all();
                self.press(t, p, x, y, cx.now);
                true
            }
            InputEvent::MouseDragged { x, .. } => {
                if self.scrubbing_preview {
                    let f = self.scrub_fraction(f64::from(x) / s);
                    self.note("preview_scrub", FormValue::Number(f));
                    return true;
                }
                if let Some(path) = self.scrubbing
                    && let Some(mut f) = self.scrubs.remove(&path)
                {
                    let ev = f.mouse_dragged(x, sq_draw::InputModifiers::default(), scale, cx);
                    self.scrubs.insert(path, f);
                    self.deliver_scrub(ev, path);
                    return true;
                }
                self.pressed.is_some()
            }
            InputEvent::MouseUp { x, y } => {
                if self.scrubbing_preview {
                    self.scrubbing_preview = false;
                    return true;
                }
                if let Some(path) = self.scrubbing.take() {
                    if let Some(mut f) = self.scrubs.remove(&path) {
                        let ev = f.mouse_up(cx);
                        if f.is_editing() {
                            self.editing_scrub = Some(path);
                        }
                        self.scrubs.insert(path, f);
                        self.deliver_scrub(ev, path);
                    }
                    return true;
                }
                let Some(was) = self.pressed.take() else { return false };
                if self.target_at(pt(x, y)) == Some(was) {
                    self.release(was);
                }
                true
            }
            InputEvent::MouseMoved { x, y } => {
                self.hover = self.target_at(pt(x, y));
                false
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                let p = pt(x, y);
                if self.list_frame.contains(p) {
                    self.list_scroll -= f64::from(dy) / s;
                    self.dirty = true;
                } else if self.column_frame().contains(p) {
                    let max = (self.column_height - self.viewport().height).max(0.0);
                    self.scroll = (self.scroll - f64::from(dy) / s).clamp(0.0, max);
                    self.dirty = true;
                }
                true
            }
            InputEvent::KeyDown { key, modifiers } => {
                if self.name_focused {
                    if key == InputKey::Escape {
                        self.name.cancel();
                        self.name_focused = false;
                        return true;
                    }
                    if key == InputKey::Enter {
                        self.end_name_editing();
                        return true;
                    }
                    if let Some(s) = self.name.key(key, modifiers, cx) {
                        self.name_focused = false;
                        self.commit_name(&s);
                    }
                    return true;
                }
                if let Some(p) = self.editing_scrub
                    && let Some(mut f) = self.scrubs.remove(&p)
                {
                    let ev = f.key(key, modifiers, cx.now, cx);
                    if !f.is_editing() {
                        self.editing_scrub = None;
                    }
                    self.scrubs.insert(p, f);
                    self.deliver_scrub(ev, p);
                    return true;
                }
                // `ExportDialogView.keyDown`: Space plays, the arrows step a frame.
                if key == InputKey::Space {
                    self.toggle_play();
                    return true;
                }
                if key == InputKey::Left || key == InputKey::Right {
                    if self.transport.frames > 0 {
                        self.note("preview_step", FormValue::Index(if key == InputKey::Left { -1 } else { 1 }));
                    }
                    return true;
                }
                false
            }
        }
    }

    fn commit_editing_all(&mut self) {
        self.end_name_editing();
        self.end_scrub_editing();
    }

    // MARK: Drawing

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.drain_picks();
        if self.dirty {
            let measure = |s: &str, size: f64| c.size_of(s, size, 0).width;
            let line = c.size_of("Ag", m::BODY, 0).height;
            // The same line height the text measure reports (it rounds up to whole points).
            self.line_h = line.ceil().max(self.line_h.min(line));
            self.layout_all(&measure);
        }
        let f = self.frame;
        let (title, seq) = {
            let model = self.model.borrow();
            (
                SQL10n::string("Export"),
                model
                    .sequences()
                    .iter()
                    .find(|s| s.id == model.selected_id())
                    .map(|s| s.name.clone())
                    .unwrap_or_default(),
            )
        };
        let medium = c.medium();
        c.draw_text_in(
            &title,
            CGRect::new(f.min_x() + m::PAD_X, f.min_y(), 48.0, m::HEADER_H),
            m::TITLE,
            t.label(),
            TextAlign::Left,
            0.0,
            medium,
        );
        let name_col = self.seq_name_frame();
        let seq = c.ellipsized(&seq, m::BODY, 0, name_col.width);
        c.draw_text_in(&seq, name_col, m::BODY, t.label3(), TextAlign::Left, 0.0, 0);
        let preset = self.preset_frame();
        c.draw_text_in(
            &SQL10n::string("Preset"),
            CGRect::new(preset.min_x() - 8.0 - 44.0, f.min_y(), 44.0, m::HEADER_H),
            m::BODY,
            t.label2(),
            TextAlign::Right,
            0.0,
            0,
        );
        let list = self.presets();
        let (current, custom_title) = {
            let model = self.model.borrow();
            (model.shown_preset_id().to_string(), SQL10n::string("Custom"))
        };
        let preset_title = match list.iter().find(|p| p.id() == current) {
            Some(p) => SQL10n::localized(&p.name()),
            None => custom_title,
        };
        InspectorDraw::popup(
            c,
            &preset_title,
            preset,
            self.hover == Some(Target::Preset),
            false,
            true,
            false,
            m::FIELD_H,
            None,
            t,
        );
        // `SQButton(symbol:)`: a bare icon, a body only under the pointer.
        let add = self.add_frame();
        if self.hover == Some(Target::Add) || self.pressed == Some(Target::Add) {
            InspectorDraw::button(c, "", add, true, self.pressed == Some(Target::Add), true, false, m::FIELD_H, t);
        }
        c.draw_icon(SQIcon::Plus, CGPoint::new(add.mid_x() - 6.0, add.mid_y() - 6.0), 12.0, t.label(), None);
        c.fill(CGRect::new(f.min_x(), f.min_y() + m::HEADER_H - 1.0, f.width, 1.0), t.separator());
        c.fill(
            CGRect::new(f.min_x() + self.left_w() - 1.0, f.min_y() + m::HEADER_H, 1.0, f.height - m::HEADER_H),
            t.separator(),
        );
        // The left column is the chrome tone (kit `Left`); its edge line is the right pixel column.
        c.fill(
            CGRect::new(f.min_x(), f.min_y() + m::HEADER_H, self.left_w() - 1.0, f.height - m::HEADER_H),
            t.token(sq_uikit::redesign_tokens::color::CHROME),
        );
        self.draw_left(c, t);
        self.draw_column(c, t, cx);
    }

    fn draw_left(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let f = self.frame;
        let line_h = self.line_h;
        let boxed = self.preview_frame();
        c.fill_rounded(boxed, f64::from(radius::CONTROL), t.viewer());
        let (pw, ph, ready) = self.picture;
        let (w, h) = {
            let model = self.model.borrow();
            let v = &model.settings().video;
            (v.width, v.height)
        };
        let _ = (pw, ph);
        let pic = ExportPreviewMath::picture_rect(
            sq_uikit::keyframe_graph_geometry::Rect {
                x: boxed.min_x(),
                y: boxed.min_y(),
                width: boxed.width,
                height: boxed.height,
            },
            w,
            h,
        );
        let pic = CGRect::new(pic.x, pic.y, pic.width, pic.height);
        if ready {
            c.draw_image_slot(self.slot, pic, [0.0, 0.0, 1.0, 1.0], Color::WHITE);
        } else {
            c.fill_rounded(pic, f64::from(radius::CONTROL), t.viewer());
        }
        // The live size label in the corner of the preview box.
        let label = format!("{w} \u{00D7} {h}");
        let lw = c.size_of(&label, m::CAPTION, 0).width.ceil() + 12.0;
        let lr = CGRect::new(boxed.max_x() - 8.0 - lw, boxed.max_y() - 8.0 - 18.0, lw, 18.0);
        c.fill_rounded(lr, 3.0, Color::new(0.0, 0.0, 0.0, 0.62));
        c.draw_text_in(&label, lr, m::CAPTION, Color::WHITE, TextAlign::Center, 0.0, 0);
        let bar = boxed.max_y() + 10.0;
        let play = CGRect::new(f.min_x() + m::PAD_X, bar, 24.0, m::PLAYER_H);
        let can_play = self.transport.frames > 0;
        let touch = Touch { hovering: can_play && self.hover == Some(Target::Play), ..Touch::default() };
        c.stone_button(play, ButtonKind::Quiet, touch, t);
        let ink = if can_play { t.label2() } else { dim(t.label2(), 0.4) };
        let icon = if self.transport.playing { SQIcon::Pause } else { SQIcon::Play };
        c.draw_icon(icon, CGPoint::new(play.mid_x() - 5.5, play.mid_y() - 5.5), 11.0, ink, None);
        // `ExportScrubBar`: 4 pt track, accent progress, a 10 pt label-colored knob while enabled.
        let sf = self.scrub_frame();
        let track = CGRect::new(sf.min_x() + m::SCRUB_INSET, sf.mid_y() - 2.0, sf.width - 2.0 * m::SCRUB_INSET, 4.0);
        let kx = track.min_x() + track.width * self.transport.fraction.clamp(0.0, 1.0);
        c.stone_slider_track(track, can_play.then_some((track.min_x(), kx)), Touch::default(), t);
        if can_play {
            c.stone_slider_knob(kx, sf.mid_y(), false, Touch::default(), t);
            c.draw_text_in(
                &self.transport.timecode,
                CGRect::new(
                    f.min_x() + self.left_w() - m::PAD_X - 78.0,
                    bar + ((m::PLAYER_H - line_h) / 2.0).round(),
                    78.0,
                    line_h,
                ),
                m::BODY,
                t.label2(),
                TextAlign::Right,
                0.0,
                0,
            );
        }
        let semibold = c.semibold();
        c.draw_text_in(
            &SQL10n::string("What to export"),
            CGRect::new(f.min_x() + m::PAD_X, bar + m::PLAYER_H + 16.0, 200.0, 22.0),
            m::CAPTION,
            t.label3(),
            TextAlign::Left,
            0.0,
            semibold,
        );

        // The output list: field body, .5 edge, one row per output (check, name, size).
        let lf = self.list_frame;
        c.fill_rounded(lf, m::CARD_RADIUS, t.token(sq_uikit::redesign_tokens::color::GROUP));
        c.save_gstate();
        c.clip_to(lf);
        let rows = self.model.borrow().output_rows();
        for (i, r) in rows.iter().enumerate() {
            let y = lf.min_y() + m::LIST_INSET + i as f64 * m::LIST_ROW_H - self.list_scroll;
            let row = CGRect::new(lf.min_x(), y, lf.width, m::LIST_ROW_H);
            if self.hover == Some(Target::Output(r.id)) {
                c.fill_rounded(row.inset_by(4.0, 1.0), f64::from(radius::SMALL), dim(t.fill_hover(), 0.5));
            }
            let cb = CGRect::new(row.min_x() + 12.0, row.mid_y() - m::CHECK_BOX / 2.0, m::CHECK_BOX, m::CHECK_BOX);
            InspectorDraw::checkbox(
                c,
                if r.is_checked { CheckState::On } else { CheckState::Off },
                cb,
                self.hover == Some(Target::OutputCheck(r.id)),
                self.pressed == Some(Target::OutputCheck(r.id)),
                true,
                false,
                t,
            );
            let size_w = c.size_of(&r.size_text, m::BODY, 0).width.ceil();
            let title_w = c.size_of(&r.title, m::BODY, 0).width.ceil();
            let rects = output_row_rects(row, title_w, size_w);
            c.draw_text_in(&r.title, rects.title, m::BODY, t.label(), TextAlign::Left, 0.0, 0);
            let (size_font, size_align) =
                if rects.stacked { (m::CAPTION, TextAlign::Left) } else { (m::BODY, TextAlign::Right) };
            c.draw_text_in(&r.size_text, rects.size, size_font, t.label2(), size_align, 0.0, 0);
        }
        c.restore_gstate();

        let warn = warning_color(t);
        let (warning, has_variants, all) = {
            let model = self.model.borrow();
            (model.validation_messages().into_iter().next(), model.has_variants(), model.export_all_formats())
        };
        let b = &self.blocks;
        if let Some(w) = warning {
            // One line, cut with an ellipsis, in the lower half of its two-line box.
            let text = truncated(&SQL10n::localized(&w), b.warning.width, c);
            c.draw_text_in(
                &text,
                CGRect::new(b.warning.min_x(), b.warning.max_y() - line_h, b.warning.width, line_h),
                m::BODY,
                warn,
                TextAlign::Left,
                0.0,
                0,
            );
        }
        for chip in &b.chips {
            let r = chip.frame;
            if chip.warning {
                c.fill_rounded(r, r.height / 2.0, dim(warn, 0.14));
            } else {
                c.stone_chip(r, false, true, Touch::default(), t);
            }
            c.draw_text_in(
                &chip.text,
                r,
                m::CAPTION,
                if chip.warning { warn } else { t.label2() },
                TextAlign::Center,
                0.0,
                0,
            );
        }
        let hint_h = b.hint.height / b.hint_lines.len().max(1) as f64;
        // The hardware note is advice, not a warning: neutral text with an info icon.
        for (i, line) in b.hint_lines.iter().enumerate() {
            let r = CGRect::new(b.hint.min_x(), b.hint.min_y() + i as f64 * hint_h, b.hint.width, hint_h);
            c.draw_text_in(line, r, m::BODY, t.label3(), TextAlign::Left, 0.0, 0);
        }
        if !b.hint_lines.is_empty() {
            c.draw_icon(
                SQIcon::Info,
                CGPoint::new(b.hint.min_x() - 20.0, b.hint.min_y() + 1.0),
                13.0,
                t.label3(),
                None,
            );
        }
        self.draw_result(c, t);
        if has_variants {
            let r = b.variants;
            let cb = CGRect::new(r.min_x(), r.mid_y() - m::CHECK_BOX / 2.0, m::CHECK_BOX, m::CHECK_BOX);
            InspectorDraw::checkbox(
                c,
                if all { CheckState::On } else { CheckState::Off },
                cb,
                self.hover == Some(Target::Variants),
                self.pressed == Some(Target::Variants),
                true,
                false,
                t,
            );
            c.draw_text_in(
                &SQL10n::string("Also export every format variant"),
                CGRect::new(cb.max_x() + 6.0, r.min_y(), r.width - 20.0, r.height),
                m::BODY,
                t.label(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    /// The target file of the Result card: `~` for the home folder, the platform's own separators throughout.
    fn result_target(dir: &std::path::Path, name: &str, home: &std::path::Path) -> String {
        if dir.as_os_str().is_empty() {
            return name.to_string();
        }
        sq_os::paths::tilde(sq_os::Platform::current(), &dir.join(name).to_string_lossy(), &home.to_string_lossy())
    }

    /// The Result card's "to <target>" line cut to `width`: a long target loses folders from its middle and keeps the
    /// word, the start and the file name (`to ~/Movies/…/Sequence 01.mp4`), never everything after "to".
    fn result_target_line(c: &Canvas, target: &str, width: f64) -> String {
        c.ellipsized_path(&format!("{} ", SQL10n::string("to")), target, m::BODY, 0, width)
    }

    /// The Result card: the estimated size, the length, the format line and the target file.
    fn draw_result(&self, c: &mut Canvas, t: &DrawTheme) {
        let b = self.blocks.result;
        if b.height <= 0.0 {
            return;
        }
        let (size, length, summary, target) = {
            let model = self.model.borrow();
            let fd = model.settings().video.frame_duration;
            let d = model.effective_duration_with(model.selected_id(), model.settings());
            let ext = model.file_extension();
            let name = if ext.is_empty() { model.file_name() } else { format!("{}.{ext}", model.file_name()) };
            let dir = model.output_directory().map(|d| d.to_path_buf()).unwrap_or_default();
            let home = sq_os::Platform::current().home_dir(|name| std::env::var_os(name)).unwrap_or_default();
            (
                model.estimated_size_text(),
                sq_export::core::error::ExportDecodeError::timecode(d, fd),
                model.summary_text(),
                Self::result_target(&dir, &name, &home),
            )
        };
        let semibold = c.semibold();
        c.draw_text_in(
            &SQL10n::string("Result"),
            CGRect::new(b.min_x(), b.min_y(), 200.0, 18.0),
            m::CAPTION,
            t.label3(),
            TextAlign::Left,
            0.0,
            semibold,
        );
        let card = CGRect::new(b.min_x(), b.min_y() + 18.0, b.width, m::RESULT_H);
        c.fill_rounded(card, m::CARD_RADIUS, t.token(sq_uikit::redesign_tokens::color::GROUP));
        let line = |c: &mut Canvas, text: &str, y: f64, size: f64, ink: Color, face: usize| {
            c.draw_text_in(
                text,
                CGRect::new(card.min_x() + 14.0, card.min_y() + y, card.width - 28.0, 18.0),
                size,
                ink,
                TextAlign::Left,
                0.0,
                face,
            );
        };
        line(c, &size, 14.0, 15.0, t.label(), semibold);
        let size_w = c.size_of(&size, 15.0, semibold).width.ceil();
        c.draw_text_in(
            &format!("\u{00B7} {length}"),
            CGRect::new(card.min_x() + 14.0 + size_w + 8.0, card.min_y() + 15.0, 120.0, 18.0),
            m::BODY,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        line(c, &truncated(&summary, card.width - 28.0, c), 34.0, m::BODY, t.label2(), 0);
        line(c, &Self::result_target_line(c, &target, card.width - 28.0), 53.0, m::BODY, t.label3(), 0);
    }

    fn draw_column(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        let col = self.column_frame();
        let view = self.viewport();
        c.save_gstate();
        c.clip_to(view);
        let medium = c.medium();
        let group = t.token(sq_uikit::redesign_tokens::color::GROUP);
        for card in self.card_frames.clone() {
            c.fill_rounded(card, m::CARD_RADIUS, group);
        }
        for (title, _, frame) in self.row_frames.clone().into_iter().skip(1) {
            if !title.is_empty()
                && self.card_frames.iter().any(|k| frame.min_y() > k.min_y() + 1.0 && frame.min_y() < k.max_y() - 1.0)
            {
                c.fill(CGRect::new(frame.min_x(), frame.min_y(), frame.width, 1.0), t.row_line());
            }
        }
        let detail_count: usize = self.sections.iter().filter(|s| s.detail).map(|s| s.rows.len()).sum();
        for (key, open, _first, frame) in self.header_frames.clone() {
            let r = frame;
            if key == MORE_KEY {
                // A pinned bar lies below the scrolling viewport: draw it with the whole column as its clip.
                c.restore_gstate();
                c.save_gstate();
                c.clip_to(col);
                c.fill_rounded(r, m::CARD_RADIUS, group);
                InspectorDraw::chevron(
                    c,
                    CGRect::new(r.min_x() + 6.0, r.min_y(), 18.0, r.height),
                    if open { Direction::Down } else { Direction::Right },
                    t.label3(),
                    5.0,
                );
                c.draw_text_in(
                    &SQL10n::string("More settings"),
                    CGRect::new(r.min_x() + 30.0, r.min_y(), 200.0, r.height),
                    m::BODY,
                    t.label2(),
                    TextAlign::Left,
                    0.0,
                    medium,
                );
                if !open {
                    let left = r.min_x()
                        + 30.0
                        + c.size_of(&SQL10n::string("More settings"), m::BODY, medium).width.ceil()
                        + 12.0;
                    let room = r.max_x() - m::TRAILING - left;
                    let text = more_summary(detail_count, room, &|s| c.size_of(s, m::CAPTION, 0).width);
                    c.draw_text_in(
                        &text,
                        CGRect::new(left, r.min_y(), room, r.height),
                        m::CAPTION,
                        t.label3(),
                        TextAlign::Right,
                        0.0,
                        0,
                    );
                }
                c.restore_gstate();
                c.save_gstate();
                c.clip_to(view);
                continue;
            }
            // The kit's group title: a small mark, then the name, 8 above the card (the whole line folds the group).
            InspectorDraw::chevron(
                c,
                CGRect::new(r.min_x(), r.min_y(), 13.0, 13.0),
                if open { Direction::Down } else { Direction::Right },
                t.label3(),
                5.0,
            );
            let title = self.sections.iter().find(|s| s.key == key).map_or("", |s| s.title);
            c.draw_text_in(
                &SQL10n::string(title),
                CGRect::new(r.min_x() + 19.0, r.min_y(), r.width - 19.0, 13.0),
                m::BODY,
                t.label2(),
                TextAlign::Left,
                0.0,
                medium,
            );
        }
        for (k, (title, dimmed, frame)) in self.row_frames.clone().into_iter().enumerate() {
            let Some(note) = self.row_notes.get(k) else { continue };
            if title.is_empty() {
                continue;
            }
            let (y, h) =
                if note.top_label { (frame.min_y() + m::ROW_PAD, 16.0) } else { (frame.min_y(), frame.height) };
            c.draw_text_in(
                &SQL10n::string(&title),
                CGRect::new(frame.min_x() + m::LABEL_X + 2.0, y, note.label_w, h),
                m::BODY,
                if dimmed { t.label3() } else { t.label2() },
                TextAlign::Left,
                0.0,
                0,
            );
            for (i, line) in note.hint_lines.iter().enumerate() {
                c.draw_text_in(
                    line,
                    CGRect::new(
                        frame.min_x() + m::LABEL_X + 2.0,
                        frame.min_y() + note.hint_top + i as f64 * m::HINT_LINE_H,
                        note.hint_w,
                        m::HINT_LINE_H,
                    ),
                    m::BODY,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
        let frames: Vec<(Path, CGRect)> = self.item_frames.iter().map(|(p, r)| (*p, *r)).collect();
        for (p, r) in frames {
            if let Some(it) = self.item(p) {
                self.draw_item(c, &it, p, r, t, cx);
            }
        }
        c.restore_gstate();
        if self.column_height > view.height + 0.5 {
            let track = view.inset_by(0.0, 2.0);
            let knob_h = (track.height * view.height / self.column_height).max(24.0);
            let y = track.min_y() + (track.height - knob_h) * self.scroll / (self.column_height - view.height).max(1.0);
            c.fill_rounded(CGRect::new(track.max_x() - 8.0, y, 4.0, knob_h), 2.0, t.label3());
        }
    }

    fn draw_item(&mut self, c: &mut Canvas, it: &Item, p: Path, r: CGRect, t: &DrawTheme, cx: &mut UiCx) {
        let hovering = self.hover == Some(Target::Item(p));
        let down = self.pressed == Some(Target::Item(p));
        let a = if it.enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        match &it.kind {
            Kind::Popup { titles, selected, .. } => {
                let title = titles.get(*selected).cloned().unwrap_or_default();
                InspectorDraw::popup(c, &title, r, hovering, false, it.enabled, false, m::FIELD_H, None, t);
            }
            Kind::Check { title, on } => {
                let cb = CGRect::new(r.min_x(), r.mid_y() - m::CHECK_BOX / 2.0, m::CHECK_BOX, m::CHECK_BOX);
                InspectorDraw::checkbox(
                    c,
                    if *on { CheckState::On } else { CheckState::Off },
                    cb,
                    hovering,
                    down,
                    it.enabled,
                    false,
                    t,
                );
                if !title.is_empty() {
                    c.draw_text_in(
                        title,
                        CGRect::new(cb.max_x() + 6.0, r.min_y() - 4.0, r.width - m::CHECK_BOX - 6.0, r.height + 8.0),
                        m::BODY,
                        dim(t.label(), a),
                        TextAlign::Left,
                        0.0,
                        0,
                    );
                }
            }
            Kind::Switch { on } => {
                let touch = Touch { hovering, pressed: down, disabled: !it.enabled, ..Touch::default() };
                c.stone_switch(r, *on, touch, t);
            }
            Kind::Scrub(_) => {
                let focused = self.editing_scrub == Some(p);
                if let Some(f) = self.scrubs.get_mut(&p) {
                    // The kit's number fields read in the label color, like the New Project fields.
                    if f.value_tint.is_none() {
                        f.value_tint = Some(t.label());
                    }
                    f.draw(c, r, t, focused, cx);
                }
            }
            Kind::Unit(s) => {
                c.draw_text_in(s, r, m::BODY, dim(t.label2(), a), TextAlign::Left, 0.0, 0);
            }
            Kind::Text { text, tone: Tone::Label2, .. } => {
                // The aspect pill beside the size fields (kit `.ar`: 20 high, radius 3, raised).
                let pill = CGRect::new(r.min_x(), r.mid_y() - 10.0, r.width, 20.0);
                c.fill_rounded(pill, 3.0, t.raised());
                c.draw_text_in(text, pill, m::BODY, dim(t.label(), a), TextAlign::Center, 0.0, c.semibold());
            }
            Kind::Text { text, tone, caption } => {
                // The AppKit text field: 2 pt cell inset, and white text smooths heavier than the atlas draws it (medium face).
                let face = if *tone == Tone::Label { c.medium() } else { 0 };
                c.draw_text_in(
                    text,
                    r,
                    if *caption { m::CAPTION } else { m::BODY },
                    dim(tone_color(*tone, t), a),
                    TextAlign::Left,
                    2.0,
                    face,
                );
            }
            Kind::Segmented { labels, selected, disabled, segment_width, chips } => {
                let segment_width = &fitted_segment_width(r.width, labels.len(), *segment_width, *chips);
                let track = CGRect::new(r.min_x(), r.min_y(), labels.len() as f64 * segment_width + 2.0, r.height);
                if !chips {
                    segment_draw::track(c, track, t);
                }
                for (k, l) in labels.iter().enumerate() {
                    let seg = segment_rect(r, k, *segment_width, *chips);
                    let hot = self.hover == Some(Target::Segment(p, k)) && !disabled.contains(&k);
                    let touch = Touch { hovering: hot, ..Touch::default() };
                    let ink_on = it.enabled && !disabled.contains(&k);
                    if *chips {
                        c.stone_chip(seg, k == *selected, true, touch, t);
                    } else {
                        let seg = CGRect::new(seg.min_x(), seg.min_y() + 1.0, seg.width, seg.height - 2.0);
                        c.stone_segment(seg, k == *selected, touch, t);
                    }
                    let ink = if ink_on && (k == *selected || !*chips) { t.label() } else { t.label3() };
                    c.draw_text_in(l, seg, m::BODY, ink, TextAlign::Center, 0.0, 0);
                }
            }
            Kind::IconButton(icon) => {
                let touch = Touch { hovering: hovering && it.enabled, pressed: down, ..Touch::default() };
                c.stone_button(r, ButtonKind::Quiet, touch, t);
                c.draw_icon(*icon, CGPoint::new(r.mid_x() - 6.5, r.mid_y() - 6.5), 13.0, dim(t.label2(), a), None);
            }
            Kind::Chip { title, on } => {
                let touch = Touch { hovering: hovering && it.enabled, ..Touch::default() };
                c.stone_chip(r, *on, true, touch, t);
                let ink = if *on && it.enabled { t.label() } else { t.label3() };
                c.draw_text_in(title, r, m::BODY, ink, TextAlign::Center, 0.0, 0);
            }
            Kind::Button(s) => {
                InspectorDraw::button(c, s, r, hovering, down, it.enabled, false, m::FIELD_H, t);
            }
            Kind::Field { suffix } => {
                self.name.draw(c, r, t, self.name_focused, cx);
                if !suffix.is_empty() && !self.name_focused {
                    let text = TextFieldControl::text_rect(r);
                    let name_w = c.size_of(&self.name.text, m::BODY, 0).width.ceil();
                    let suffix_w = c.size_of(suffix, m::BODY, 0).width.ceil();
                    let x = (text.min_x() + name_w + 1.0).min(text.max_x() - suffix_w);
                    c.draw_text_in(
                        suffix,
                        CGRect::new(x, text.min_y(), text.max_x() - x, text.height),
                        m::BODY,
                        t.label3(),
                        TextAlign::Left,
                        0.0,
                        0,
                    );
                }
            }
            Kind::Path(s) => {
                let mut f = TextFieldControl::new(s);
                f.alignment = sq_draw::Alignment::Left;
                f.font_size = m::BODY;
                f.draw(c, r, t, false, cx);
            }
        }
    }
}

fn tone_color(tone: Tone, t: &DrawTheme) -> Color {
    match tone {
        Tone::Label => t.label(),
        Tone::Label2 => t.label2(),
        Tone::Label3 => t.label3(),
        Tone::Warning => warning_color(t),
        Tone::Green => GREEN,
        Tone::Red => {
            let p = t.palette.red;
            Color::new((p.r / 255.0) as f32, (p.g / 255.0) as f32, (p.b / 255.0) as f32, p.a as f32)
        }
    }
}

/// The width a `.fit` item takes.
fn fit_width(k: &Kind, w: Measure) -> f64 {
    match k {
        Kind::Check { title, .. } => {
            if title.is_empty() {
                16.0
            } else {
                m::CHECK_BOX + 6.0 + w(title, m::BODY).ceil()
            }
        }
        Kind::Switch { .. } => 34.0,
        Kind::Unit(s) => w(s, m::BODY).ceil(),
        Kind::Text { text, caption, .. } => w(text, if *caption { m::CAPTION } else { m::BODY }).ceil() + 4.0,
        Kind::Segmented { labels, segment_width, chips: true, .. } => labels.len() as f64 * (segment_width + 4.0) - 4.0,
        Kind::Segmented { labels, segment_width, .. } => labels.len() as f64 * segment_width + 2.0,
        Kind::Button(s) => w(s, m::BODY).ceil() + 2.0 * m::BUTTON_PAD,
        Kind::IconButton(_) => 28.0,
        Kind::Chip { title, .. } => w(title, m::BODY).ceil() + 20.0,
        Kind::Popup { .. } => 120.0,
        Kind::Scrub(_) => items::NUMBER_FIELD_WIDTH,
        Kind::Field { .. } | Kind::Path(_) => 160.0,
    }
}

/// The segment width that fits `n` segments into `width` (the item frame): the wanted width when it fits, else narrower,
/// so a small window never cuts a segmented control or a row of chips.
fn fitted_segment_width(width: f64, n: usize, wanted: f64, chips: bool) -> f64 {
    let n = n.max(1) as f64;
    let natural = if chips { n * (wanted + 4.0) - 4.0 } else { n * wanted + 2.0 };
    if natural <= width {
        return wanted;
    }
    if chips { ((width + 4.0) / n - 4.0).max(1.0) } else { ((width - 2.0) / n).max(1.0) }
}

/// `lineBreakMode = .byTruncatingTail`: one line, cut with an ellipsis.
/// Greedy word wrap of `text` (its own line breaks kept) into lines no wider than `width`; a single word wider than the
/// line stays whole on its own line.
fn wrap_lines(text: &str, width: f64, measure: &dyn Fn(&str) -> f64) -> Vec<String> {
    let mut out = Vec::new();
    for para in text.lines().filter(|l| !l.is_empty()) {
        let mut line = String::new();
        for word in para.split_whitespace() {
            let joined = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
            if !line.is_empty() && measure(&joined) > width {
                out.push(std::mem::replace(&mut line, word.to_string()));
            } else {
                line = joined;
            }
        }
        out.push(line);
    }
    out
}

/// The closed "More settings" bar's summary: the whole sentence when it fits `room`, else just the count (never cut).
fn more_summary(count: usize, room: f64, measure: &dyn Fn(&str) -> f64) -> String {
    let full = SQL10n::format("Video and audio details, stems, advanced \u{00B7} %@ settings", &[&count.to_string()]);
    if measure(&full) <= room { full } else { SQL10n::format("%@ settings", &[&count.to_string()]) }
}

/// Where an output list row puts its title and size text.
struct OutputRowRects {
    title: CGRect,
    size: CGRect,
    stacked: bool,
}

/// The title takes the width the measured size text leaves; when the whole title does not fit beside the size, the size
/// goes under the title (caption) instead of cutting the title.
fn output_row_rects(row: CGRect, title_w: f64, size_w: f64) -> OutputRowRects {
    let left = row.min_x() + 34.0;
    let right = row.max_x() - 12.0;
    let beside = right - left - size_w - 8.0;
    if title_w <= beside {
        return OutputRowRects {
            title: CGRect::new(left, row.min_y(), beside.max(0.0), row.height),
            size: CGRect::new(right - size_w, row.min_y(), size_w, row.height),
            stacked: false,
        };
    }
    OutputRowRects {
        title: CGRect::new(left, row.min_y() + 2.0, right - left, 16.0),
        size: CGRect::new(left, row.min_y() + 18.0, right - left, 12.0),
        stacked: true,
    }
}

/// A row's hint lines. Beside the title (wrapped in the label column) while that takes two lines at most; a longer hint
/// is set under the row's controls at the full row width and the row grows by its lines, so no hint is ever cut.
struct RowHint {
    lines: Vec<String>,
    width: f64,
    top: f64,
    extra_h: f64,
}

fn row_hint(text: &str, label_w: f64, full_w: f64, base_h: f64, measure: &dyn Fn(&str) -> f64) -> RowHint {
    if text.is_empty() {
        return RowHint { lines: Vec::new(), width: label_w, top: 0.0, extra_h: 0.0 };
    }
    let beside = wrap_lines(text, label_w, measure);
    if beside.len() <= 2 {
        return RowHint { lines: beside, width: label_w, top: m::ROW_PAD + 16.0 + 3.0, extra_h: 0.0 };
    }
    let lines = wrap_lines(text, full_w, measure);
    let extra_h = lines.len() as f64 * m::HINT_LINE_H + 2.0;
    RowHint { lines, width: full_w, top: base_h - 2.0, extra_h }
}

fn truncated(s: &str, width: f64, c: &Canvas) -> String {
    c.ellipsized(s, m::BODY, 0, width)
}

impl ShellDialogContent for ShellExportSheet {
    fn height(&mut self, _width: f64) -> f64 {
        0.0
    }

    fn layout(&mut self, frame: CGRect, tm: &sq_draw::TextMeasure) {
        let mut i = self.0.borrow_mut();
        i.frame = frame;
        i.line_h = tm.line_height(m::BODY);
        i.layout_all(&|s, size| tm.width(s, size, 0));
    }

    fn draw(&mut self, _c: &mut Canvas, _t: &DrawTheme) {}

    fn draw_cx(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        if let Ok(mut i) = self.0.try_borrow_mut()
            && !i.locked()
        {
            i.draw(c, t, cx);
        }
    }

    fn handle(&mut self, _e: &InputEvent, _scale: f32) -> bool {
        false
    }

    fn handle_cx(&mut self, e: &InputEvent, scale: f32, cx: &mut UiCx) -> bool {
        let Ok(mut i) = self.0.try_borrow_mut() else { return false };
        if i.locked() {
            return false;
        }
        let taken = i.handle(e, scale, cx);
        if let Some(text) = i.copy.take() {
            cx.clipboard.write(&text);
        }
        taken
    }

    fn take_popup(&mut self) -> Option<PopupRequest> {
        self.0.try_borrow_mut().ok()?.popup.take()
    }

    fn take_changes(&mut self) -> Vec<(String, FormValue)> {
        let Ok(mut i) = self.0.try_borrow_mut() else { return Vec::new() };
        if i.locked() {
            return Vec::new();
        }
        i.drain_picks();
        std::mem::take(&mut i.changes)
    }
}

/// Whether an item row of `rows` is the one named `title` (tests).
#[cfg(test)]
pub(crate) fn find_row<'a>(sections: &'a [Section], title: &str) -> Option<(usize, usize, &'a items::Row)> {
    sections
        .iter()
        .enumerate()
        .find_map(|(si, s)| s.rows.iter().position(|r| r.title == title).map(|ri| (si, ri, &s.rows[ri])))
}

#[cfg(test)]
#[path = "shell_export_content_tests.rs"]
mod tests;
