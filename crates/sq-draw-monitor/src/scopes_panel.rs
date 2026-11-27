// Swift: ScopesPanel.swift
//! The Scopes panel on the canvas (the Mac `ScopesView` stacked arrangement of the Edit page translated): one scope
//! under its popup, a second below when the card is tall enough (waveform, then vectorscope), each a dark box with the
//! scope picture (an image slot) and the graticule over it. The counts come from the shown NV12 frame
//! (`compute_nv12`, the CPU form of the Metal accumulation), or straight from the GPU when the platform measures the
//! composite there ([`ScopeCountsSource`], [`ScopesPanel::update_counts`]).
// shortcut: binning and the scope pictures are made on the calling (UI) thread; Swift bins and draws them in detached tasks
// and coalesces asks. The picture key still skips a redraw when nothing changed. Upgrade to executor tasks when the
// Color page shows the stall (160-250 ms) again.

use crate::monitor_panel_model::MenuQueue;
use crate::scope_image::ScopeImage;
use crate::scope_trace_settings::ScopeTraceSettings;
use sq_app_shell::{AppHost, HostCx};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::scope_graticule::ScopeKind;
use sq_draw::monitor::scopes_drawing::{ScopeBoxLayout, ScopeOverlay};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{DrawTheme, radius, spacing, type_size};
use sq_draw::{Color, InputEvent, InputModifiers, InspectorDraw, Rect, RgbaImage, TextAlign};
use sq_render::passes::scope_binning::{ScopeCounts, ScopeLayout, compute_nv12, compute_rgba};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;
use std::sync::{Arc, OnceLock};

/// Draws one scope picture from its counts on the GPU (`kind`, counts, width, height, gain); `None` = could not, the CPU draws.
pub type ScopeDrawer = Arc<dyn Fn(ScopeKind, &ScopeCounts, usize, usize, f32) -> Option<RgbaImage> + Send + Sync>;

static DRAWER: OnceLock<ScopeDrawer> = OnceLock::new();

/// Installs the GPU scope drawing of the app (once; the shared `Scopes.scopeDraw` kernel on whatever backend the app runs).
/// `SQ_SCOPES_CPU=1` keeps the CPU drawing (A/B runs).
pub fn install_gpu_drawer(drawer: ScopeDrawer) {
    let _ = DRAWER.set(drawer);
}

/// One scope picture: the GPU drawing when installed, else (or when it fails) the CPU `ScopeImage::render`.
fn draw_scope(kind: ScopeKind, counts: &ScopeCounts, width: usize, height: usize, gain: f32) -> RgbaImage {
    static CPU_ONLY: OnceLock<bool> = OnceLock::new();
    let cpu_only = *CPU_ONLY.get_or_init(|| std::env::var_os("SQ_SCOPES_CPU").is_some());
    if !cpu_only
        && width > 0
        && height > 0
        && let Some(img) = DRAWER.get().and_then(|d| d(kind, counts, width, height, gain))
    {
        return img;
    }
    ScopeImage::render(kind, counts, width, height, gain)
}

/// A picture source that measures the scopes of its shown composite on the GPU (Windows: the shared `ScopePasses` on
/// D3D12): the host asks it before falling back to the CPU binning of the readback.
pub trait ScopeCountsSource {
    /// The counts of the shown picture, every `pixel_stride`-th pixel; `None` when the picture is not on the GPU.
    fn scope_counts(&mut self, pixel_stride: usize) -> Option<ScopeCounts>;
}

/// One shown scope's popup and box (points).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScopeSlot {
    /// The scope picker.
    pub popup: CGRect,
    /// The dark box.
    pub box_: CGRect,
}

/// The empty-state text of the first box.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopesEmpty {
    /// Title line.
    pub title: String,
    /// Hint line.
    pub hint: String,
}

/// What the Swift panel's `onMenu` hook reported.
#[derive(Clone, Debug)]
pub struct ScopesMenu {
    /// The rows.
    pub items: Vec<SQMenuItem>,
    /// Where they open (points).
    pub anchor: CGRect,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum ScopesCommand {
    Select(ScopeKind, usize),
    Intensity(f32),
}

/// What the scope pictures depend on besides the counts: plot pixel sizes, kinds and trace gains.
#[derive(Clone, Debug, PartialEq)]
struct ImageKey {
    sizes: Vec<i64>,
    kinds: Vec<ScopeKind>,
    gains: Vec<f32>,
    all: bool,
}

/// One big scope with a switch, or all four at once (double-click a scope to toggle).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScopesMode {
    One,
    All,
}

/// What the scopes measure: the program (timeline) monitor or the source monitor. Shown in the head.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ScopeSource {
    #[default]
    Program,
    Source,
}

impl ScopeSource {
    pub fn label(self) -> &'static str {
        match self {
            ScopeSource::Program => "PROGRAM",
            ScopeSource::Source => "SOURCE",
        }
    }
}

/// The Scopes card.
pub struct ScopesPanel {
    /// The theme (set from `draw`).
    pub theme: DrawTheme,
    kinds: Vec<ScopeKind>,
    mode: ScopesMode,
    /// The scope shown in `ScopesMode::One`.
    selected: ScopeKind,
    /// The head's PROGRAM / SOURCE label.
    pub source: ScopeSource,
    clicks: sq_draw::ClickCounter,
    /// `ScopesMode::All`: the four pictures sit in one atlas (one image slot): the cell size and each tile's size.
    atlas_cell: (usize, usize),
    atlas_tiles: Vec<(usize, usize)>,
    frame: CGRect,
    slots: Vec<ScopeSlot>,
    images: [Option<RgbaImage>; 2],
    image_generation: u64,
    /// No picture to measure: the first box says so.
    pub empty_text: Option<ScopesEmpty>,
    /// "On screen: X" from the Color page (the scopes measure X, not the graded clip); `None` hides the line.
    pub hint: Option<String>,
    hint_frame: Option<CGRect>,
    scale: f32,
    counts: Option<ScopeCounts>,
    measured_generation: i64,
    /// Sample every Nth pixel in x and y (the Mac `ScopesView.pixelStride` knob).
    pub pixel_stride: usize,
    /// The waveform settings (trace intensity of the Waveform and RGB Parade), shared with every scopes view.
    pub settings: ScopeTraceSettings,
    requested_key: Option<ImageKey>,
    hover_settings: Option<usize>,
    /// The first of the two image slots the host uploads `images` to.
    pub slot_base: usize,
    /// Menus the panel asked for since the owner last took them.
    pub menus: Vec<ScopesMenu>,
    queue: MenuQueue<ScopesCommand>,
}

impl Default for ScopesPanel {
    fn default() -> Self {
        Self::new()
    }
}

impl ScopesPanel {
    /// The least width the scope popup keeps before the PROGRAM / SOURCE label is left out.
    const MIN_POPUP: f64 = 84.0;

    /// Caption text (10 pt) line height: the Mac label's intrinsic height.
    pub const HINT_LINE_HEIGHT: f64 = 13.0;
    /// The Mac `SQPopup` intrinsic height.
    pub const POPUP_HEIGHT: f64 = 22.0;
    /// The settings button's side (points), at the right end of a Waveform / Parade popup row.
    const SETTINGS_BUTTON_SIZE: f64 = 14.0;

    /// A card with one big Waveform.
    pub fn new() -> ScopesPanel {
        ScopesPanel {
            theme: DrawTheme::default(),
            kinds: vec![ScopeKind::Waveform],
            mode: ScopesMode::One,
            selected: ScopeKind::Waveform,
            source: ScopeSource::Program,
            clicks: sq_draw::ClickCounter::new(),
            atlas_cell: (0, 0),
            atlas_tiles: Vec::new(),
            frame: CGRect::default(),
            slots: Vec::new(),
            images: [None, None],
            image_generation: 0,
            empty_text: None,
            hint: None,
            hint_frame: None,
            scale: 1.0,
            counts: None,
            measured_generation: -1,
            pixel_stride: 2,
            settings: ScopeTraceSettings::new(),
            requested_key: None,
            hover_settings: None,
            slot_base: 0,
            menus: Vec::new(),
            queue: MenuQueue::default(),
        }
    }

    /// The scope shown in each slot.
    pub fn kinds(&self) -> &[ScopeKind] {
        &self.kinds
    }
    pub fn mode(&self) -> ScopesMode {
        self.mode
    }
    pub fn selected(&self) -> ScopeKind {
        self.selected
    }

    /// One big scope or all four (a 2 x 2 grid, one picture atlas in the first image slot).
    pub fn set_mode(&mut self, mode: ScopesMode) {
        if self.mode == mode {
            return;
        }
        self.mode = mode;
        self.kinds = if mode == ScopesMode::All { ScopeKind::ALL.to_vec() } else { vec![self.selected] };
        self.layout_frame(self.frame);
        self.render_images();
    }

    /// Double-click: all four, and back.
    pub fn toggle_all(&mut self) {
        self.set_mode(if self.mode == ScopesMode::All { ScopesMode::One } else { ScopesMode::All });
    }

    /// The card in points.
    pub fn frame(&self) -> CGRect {
        self.frame
    }
    /// Per shown scope: popup rect and box rect (points).
    pub fn slots(&self) -> &[ScopeSlot] {
        &self.slots
    }
    /// The scope pictures for the boxes (index = shown scope).
    pub fn images(&self) -> &[Option<RgbaImage>; 2] {
        &self.images
    }
    /// A counter that changes with the pictures.
    pub fn image_generation(&self) -> u64 {
        self.image_generation
    }
    /// The hint line's frame (points; `None` = no line).
    pub fn hint_frame(&self) -> Option<CGRect> {
        self.hint_frame
    }

    /// ScopesView.layout (stacked). `r` in pixels.
    pub fn layout_px(&mut self, r: Rect, scale: f32) {
        self.scale = scale.max(0.01);
        let k = self.scale as f64;
        self.layout_frame(CGRect::new(r.x as f64 / k, r.y as f64 / k, r.w as f64 / k, r.h as f64 / k));
    }

    /// The same in window points.
    pub fn layout_frame(&mut self, frame: CGRect) {
        self.frame = frame;
        type L = ScopeBoxLayout;
        // ScopesPanelView.layout: the hint line at (md, xs), the scopes below it with their own insets.
        let xs = spacing::XS as f64;
        let md = spacing::MD as f64;
        let lead = if self.hint.is_none() { 0.0 } else { Self::HINT_LINE_HEIGHT + xs };
        self.hint_frame = self.hint.as_ref().map(|_| {
            CGRect::new(
                frame.min_x() + md,
                frame.min_y() + xs,
                (frame.width - 2.0 * md).max(0.0),
                Self::HINT_LINE_HEIGHT,
            )
        });
        let body = CGRect::new(frame.min_x(), frame.min_y() + lead, frame.width, (frame.height - lead).max(0.0));
        let x = body.min_x() + L::SIDE;
        let w = (body.width - 2.0 * L::SIDE).max(0.0);
        let h = (body.height - 2.0 * L::TOP).max(0.0);
        let slot = |y: f64, height: f64| {
            let popup = CGRect::new(x, y, w, Self::POPUP_HEIGHT);
            ScopeSlot {
                popup,
                box_: CGRect::new(x, popup.max_y() + L::GAP, w, (height - Self::POPUP_HEIGHT - L::GAP).max(0.0)),
            }
        };
        let top = body.min_y() + L::TOP;
        if self.empty_text.is_none() && self.mode == ScopesMode::All {
            // 2 x 2: every cell is a popup over its box.
            let cw = ((w - L::GAP) / 2.0).max(0.0);
            let ch = ((h - L::GAP) / 2.0).max(0.0);
            self.slots = (0..4)
                .map(|i| {
                    let cx = x + (cw + L::GAP) * (i % 2) as f64;
                    let cy = top + (ch + L::GAP) * (i / 2) as f64;
                    let popup = CGRect::new(cx, cy, cw, Self::POPUP_HEIGHT);
                    ScopeSlot {
                        popup,
                        box_: CGRect::new(cx, popup.max_y() + L::GAP, cw, (ch - Self::POPUP_HEIGHT - L::GAP).max(0.0)),
                    }
                })
                .collect();
        } else {
            let height = if self.empty_text.is_none() { h } else { h.min(Self::POPUP_HEIGHT + L::GAP + L::FIRST_BOX) };
            self.slots = vec![slot(top, height)];
        }
        // The host lays out on every window frame: redraw the pictures only when what they show changed.
        if Some(self.image_key()) != self.requested_key {
            self.render_images();
        }
    }

    fn image_key(&self) -> ImageKey {
        let mut sizes = Vec::new();
        for (i, s) in self.slots.iter().enumerate().take(self.kinds.len()) {
            let p =
                ScopeBoxLayout::plot(self.kinds[i], sq_uikit::controls_grid::CGSize::new(s.box_.width, s.box_.height));
            sizes.push((p.width * self.scale as f64).round() as i64);
            sizes.push((p.height * self.scale as f64).round() as i64);
        }
        ImageKey {
            sizes,
            kinds: self.kinds.clone(),
            gains: self.kinds.iter().map(|k| self.settings.intensity_for(*k)).collect(),
            all: self.mode == ScopesMode::All,
        }
    }

    /// The hint line's text (`ScopesPanelView.hint`): "Measuring X, not the graded clip".
    pub fn hint_text(hint: &str) -> String {
        let what = hint.strip_prefix("On screen: ").unwrap_or(hint);
        format!("Measuring {what}, not the graded clip")
    }

    /// A new shown frame (8-bit NV12, or RGBA with `rgba`): bins it when `generation` changed, then redraws the pictures.
    pub fn update_nv12(
        &mut self,
        bytes: &[u8],
        width: usize,
        height: usize,
        full_range: bool,
        rgba: bool,
        generation: i64,
    ) {
        if generation == self.measured_generation {
            return;
        }
        self.measured_generation = generation;
        let c = if rgba {
            compute_rgba(bytes, width, height, ScopeLayout::default(), self.pixel_stride)
        } else {
            compute_nv12(bytes, width, height, full_range, ScopeLayout::default(), self.pixel_stride)
        };
        self.counts = Some(c);
        self.render_images();
    }

    /// Counts measured elsewhere (the GPU scope passes on the shown composite): redraws the pictures when `generation`
    /// changed.
    pub fn update_counts(&mut self, c: ScopeCounts, generation: i64) {
        if generation == self.measured_generation {
            return;
        }
        self.measured_generation = generation;
        self.counts = Some(c);
        self.render_images();
    }

    /// GPU counts from `source` (once per generation); false when it has none (the host bins the readback instead).
    pub fn measure(&mut self, source: &mut dyn ScopeCountsSource, generation: i64) -> bool {
        if generation == self.measured_generation {
            return true;
        }
        let Some(c) = source.scope_counts(self.pixel_stride) else { return false };
        self.update_counts(c, generation);
        true
    }

    /// Clears the scopes (no picture).
    pub fn clear(&mut self) {
        self.counts = None;
        self.measured_generation = -1;
        self.images = [None, None];
        self.image_generation += 1;
        self.requested_key = None;
    }

    /// The scope pictures at the plots' pixel sizes. The old pictures stay until the new ones are ready.
    fn render_images(&mut self) {
        let Some(counts) = &self.counts else { return };
        let key = self.image_key();
        let mut out: [Option<RgbaImage>; 2] = [None, None];
        if self.mode == ScopesMode::All && self.slots.len() == 4 {
            let counts = counts.clone();
            self.render_atlas(counts, &mut out);
            self.images = out;
            self.image_generation += 1;
            self.requested_key = Some(key);
            return;
        }
        self.atlas_tiles.clear();
        for (i, s) in self.slots.iter().enumerate().take(1) {
            let p =
                ScopeBoxLayout::plot(self.kinds[i], sq_uikit::controls_grid::CGSize::new(s.box_.width, s.box_.height));
            let w = (p.width * self.scale as f64).round() as i64;
            let h = (p.height * self.scale as f64).round() as i64;
            if w > 1 && h > 1 {
                let mut img = draw_scope(
                    self.kinds[i],
                    counts,
                    w as usize,
                    h as usize,
                    self.settings.intensity_for(self.kinds[i]),
                );
                if self.kinds[i] == ScopeKind::Vectorscope {
                    Self::cut_to_circle(&mut img);
                }
                out[i] = Some(img);
            }
        }
        self.images = out;
        self.image_generation += 1;
        self.requested_key = Some(key);
    }

    /// The four scopes in one picture (2 x 2 cells of the largest tile), so all four need one image slot only.
    fn render_atlas(&mut self, counts: ScopeCounts, out: &mut [Option<RgbaImage>; 2]) {
        let mut tiles: Vec<Option<RgbaImage>> = Vec::new();
        for (i, s) in self.slots.iter().enumerate() {
            let k = self.kinds[i];
            let p = ScopeBoxLayout::plot(k, sq_uikit::controls_grid::CGSize::new(s.box_.width, s.box_.height));
            let w = (p.width * self.scale as f64).round() as i64;
            let h = (p.height * self.scale as f64).round() as i64;
            tiles.push((w > 1 && h > 1).then(|| {
                let mut img = draw_scope(k, &counts, w as usize, h as usize, self.settings.intensity_for(k));
                if k == ScopeKind::Vectorscope {
                    Self::cut_to_circle(&mut img);
                }
                img
            }));
        }
        let cw = tiles.iter().flatten().map(|t| t.width).max().unwrap_or(0);
        let ch = tiles.iter().flatten().map(|t| t.height).max().unwrap_or(0);
        self.atlas_cell = (cw, ch);
        self.atlas_tiles = tiles.iter().map(|t| t.as_ref().map_or((0, 0), |t| (t.width, t.height))).collect();
        if cw == 0 || ch == 0 {
            return;
        }
        let mut atlas = RgbaImage { width: 2 * cw, height: 2 * ch, pixels: vec![0; 4 * 2 * cw * 2 * ch] };
        for (i, t) in tiles.iter().enumerate() {
            let Some(t) = t else { continue };
            let (ox, oy) = ((i % 2) * cw, (i / 2) * ch);
            for y in 0..t.height {
                let src = y * t.width * 4;
                let dst = ((oy + y) * atlas.width + ox) * 4;
                atlas.pixels[dst..dst + t.width * 4].copy_from_slice(&t.pixels[src..src + t.width * 4]);
            }
        }
        out[0] = Some(atlas);
    }

    /// The Mac clips the vectorscope layer to its ring (`cornerRadius`); the canvas has no round clip, so the pixels
    /// outside the circle turn transparent.
    pub fn cut_to_circle(img: &mut RgbaImage) {
        let cx = img.width as f64 / 2.0;
        let cy = img.height as f64 / 2.0;
        let r2 = cx * cx;
        for y in 0..img.height {
            for x in 0..img.width {
                let dx = x as f64 + 0.5 - cx;
                let dy = y as f64 + 0.5 - cy;
                if dx * dx + dy * dy > r2 {
                    img.pixels[(y * img.width + x) * 4 + 3] = 0;
                }
            }
        }
    }

    /// Draws the card; the pictures are image slots `slot_base` and `slot_base + 1`.
    pub fn draw_card(&mut self, c: &mut Canvas, t: &DrawTheme) {
        self.theme = *t;
        self.scale = c.scale;
        if self.frame.width <= 0.0 || self.frame.height <= 0.0 {
            return;
        }
        c.fill_rounded(self.frame, t.panel_radius(), t.panel());
        if let (Some(hint), Some(r)) = (&self.hint, self.hint_frame) {
            let warning = crate::monitor_panel::MonitorPanel::color(t.palette.warning);
            c.draw_text_in(&Self::hint_text(hint), r, type_size::CAPTION as f64, warning, TextAlign::Left, 0.0, 0);
        }
        for (i, s) in self.slots.clone().iter().enumerate() {
            let kind = self.kinds[i];
            // ScopeSlotView.apply: only a shown vectorscope is a bare disc with the legend; an empty slot is a box.
            let circle = kind == ScopeKind::Vectorscope && !(i == 0 && self.empty_text.is_some());
            // `SQPopup` at its intrinsic width (10 inset, the title, 8 gap, 7 chevron, 7 inset), 22 high at the top of the slot.
            let title = ScopeBoxLayout::title(kind);
            // Every popup takes the width of the widest scope title (the Mac stack aligns them on one width).
            let widest =
                ScopeKind::ALL.iter().map(|k| c.size_of(ScopeBoxLayout::title(*k), 11.0, 0).width).fold(0.0, f64::max);
            let pw = widest.ceil() + 32.0;
            // The head: what the scopes measure, at the right end of the first popup row.
            let head_w = if i == 0 { c.size_of(self.source.label(), 10.0, 0).width.ceil() + 12.0 } else { 0.0 };
            // Left of the settings button when the scope has one.
            let head_right = self.settings_button(i).map_or(s.popup.max_x(), |b| b.min_x() - 6.0);
            // The popup gives way to the head label; below `MIN_POPUP` the label is left out instead (never over the popup).
            let room = head_right - head_w - s.popup.min_x();
            let (pw, head_w) = if head_w == 0.0 || pw <= room {
                (pw, head_w)
            } else if room >= Self::MIN_POPUP {
                (room, head_w)
            } else {
                (pw.min(head_right - s.popup.min_x()), 0.0)
            };
            InspectorDraw::popup(
                c,
                title,
                CGRect::new(s.popup.min_x(), s.popup.min_y(), pw, 22.0),
                false,
                false,
                true,
                true,
                22.0,
                Some(11.0),
                t,
            );
            if i == 0 && head_w > 0.0 {
                c.draw_text_in(
                    self.source.label(),
                    CGRect::new(head_right - head_w, s.popup.min_y(), head_w, s.popup.height),
                    10.0,
                    t.label2(),
                    TextAlign::Right,
                    0.0,
                    0,
                );
            }
            if circle {
                // The skin tone legend right of the popup (left of the head label).
                let lw = c.size_of("Skin tone", 11.0, 0).width;
                let s = &ScopeSlot {
                    popup: CGRect::new(s.popup.min_x(), s.popup.min_y(), s.popup.width - head_w, s.popup.height),
                    ..*s
                };
                c.draw_text_in(
                    "Skin tone",
                    CGRect::new(s.popup.max_x() - lw, s.popup.min_y(), lw, s.popup.height),
                    11.0,
                    t.label2(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                c.fill(
                    CGRect::new(s.popup.max_x() - lw - 6.0 - 14.0, s.popup.mid_y().round() - 1.0, 14.0, 2.0),
                    t.label2(),
                );
            } else {
                if let Some(b) = self.settings_button(i) {
                    let touch = Touch { hovering: self.hover_settings == Some(i), ..Touch::default() };
                    c.stone_button(b, ButtonKind::Quiet, touch, t);
                    c.draw_icon(
                        SQIcon::SlidersHorizontal,
                        CGPoint::new(b.mid_x() - 6.0, b.mid_y() - 6.0),
                        12.0,
                        if self.hover_settings == Some(i) { t.label() } else { t.label2() },
                        None,
                    );
                }
                // `Theme.Colors.scopeBox` with the hairline edge and the control radius.
                let rad = radius::CONTROL as f64;
                c.fill_rounded(s.box_, rad, Color::hex(0x0A0A0A, 1.0));
                c.stroke_rounded(s.box_, rad, 1.0, t.separator());
            }
            if i == 0
                && let Some(e) = &self.empty_text
            {
                c.draw_text_in(
                    &e.title,
                    CGRect::new(s.box_.min_x(), s.box_.mid_y() - 18.0, s.box_.width, 18.0),
                    13.0,
                    t.label2(),
                    TextAlign::Center,
                    0.0,
                    0,
                );
                c.draw_text_in(
                    &e.hint,
                    CGRect::new(s.box_.min_x(), s.box_.mid_y() + 2.0, s.box_.width, 16.0),
                    11.0,
                    t.label2(),
                    TextAlign::Center,
                    0.0,
                    0,
                );
                continue;
            }
            // The vectorscope's disc and rings go under its trace (cut to the circle), the other graticules over theirs.
            if kind == ScopeKind::Vectorscope {
                ScopeOverlay::draw(c, kind, s.box_, t);
            }
            let all = self.mode == ScopesMode::All && self.slots.len() == 4;
            if (all && self.images[0].is_some()) || (!all && self.images.get(i).is_some_and(Option::is_some)) {
                let mut p =
                    ScopeBoxLayout::plot(kind, sq_uikit::controls_grid::CGSize::new(s.box_.width, s.box_.height));
                p.x += s.box_.min_x();
                p.y += s.box_.min_y();
                if all {
                    let (cw, ch) = (self.atlas_cell.0.max(1) as f32, self.atlas_cell.1.max(1) as f32);
                    let (tw, th) = self.atlas_tiles.get(i).copied().unwrap_or((0, 0));
                    let (u0, v0) = ((i % 2) as f32 * 0.5, (i / 2) as f32 * 0.5);
                    let uv = [u0, v0, u0 + 0.5 * tw as f32 / cw, v0 + 0.5 * th as f32 / ch];
                    c.draw_image_slot(self.slot_base, p, uv, Color::WHITE);
                } else {
                    c.draw_image_slot(self.slot_base + i, p, [0.0, 0.0, 1.0, 1.0], Color::WHITE);
                }
            }
            if kind != ScopeKind::Vectorscope {
                ScopeOverlay::draw(c, kind, s.box_, t);
            }
        }
    }

    /// The settings button of scope `i` (points): only a shown Waveform or RGB Parade has one.
    pub fn settings_button(&self, i: usize) -> Option<CGRect> {
        let s = self.slots.get(i)?;
        if !ScopeTraceSettings::has_settings(self.kinds[i]) || (i == 0 && self.empty_text.is_some()) {
            return None;
        }
        let p = s.popup;
        let d = Self::SETTINGS_BUTTON_SIZE;
        Some(CGRect::new(p.max_x() - d, (p.mid_y() - d / 2.0).round(), d, d))
    }

    fn settings_index(&self, p: CGPoint) -> Option<usize> {
        (0..self.slots.len()).find(|i| self.settings_button(*i).is_some_and(|b| b.contains(p)))
    }

    /// The tip under the pointer (points).
    pub fn help_at(&self, p: CGPoint) -> Option<String> {
        self.settings_index(p).map(|_| SQL10n::string(ScopeTraceSettings::BUTTON_TIP))
    }

    /// Which scope's popup is at `p` (points).
    fn popup_index(&self, p: CGPoint) -> Option<usize> {
        self.slots.iter().position(|s| s.popup.inset_by(0.0, -2.0).contains(p))
    }

    /// The scope choices (ScopesView's popup). A pick queues `select`; `pump` runs it.
    pub fn menu_items_for(&self, i: usize) -> Vec<SQMenuItem> {
        ScopeKind::ALL
            .into_iter()
            .map(|k| {
                let q = self.queue.clone();
                let mut row = SQMenuItem::new(ScopeBoxLayout::title(k));
                row.is_checked = self.kinds.get(i) == Some(&k);
                row.action = Some(Rc::new(move || q.push(ScopesCommand::Select(k, i))));
                row
            })
            .collect()
    }

    fn settings_menu(&self) -> Vec<SQMenuItem> {
        let q = self.queue.clone();
        self.settings.menu_items(Rc::new(move |v| q.push(ScopesCommand::Intensity(v))))
    }

    /// Runs the picks of the menus (the owner calls it after a row ran; `handle` does too).
    pub fn pump(&mut self) {
        for c in self.queue.take() {
            match c {
                ScopesCommand::Select(k, i) => self.select(k, i),
                ScopesCommand::Intensity(v) => {
                    self.settings.set_intensity(v);
                    if Some(self.image_key()) != self.requested_key {
                        self.render_images();
                    }
                }
            }
        }
    }

    /// Shows scope `k` in slot `i`.
    pub fn select(&mut self, k: ScopeKind, i: usize) {
        if self.mode == ScopesMode::All {
            // Picking in the grid goes back to one big scope of that kind.
            self.selected = k;
            self.set_mode(ScopesMode::One);
            return;
        }
        if i >= self.kinds.len() || self.kinds[i] == k {
            return;
        }
        self.selected = k;
        self.kinds[i] = k;
        self.render_images();
    }

    /// A press in pixels; true when it was on the card.
    pub fn handle_event(&mut self, e: &InputEvent, cx: Option<&mut sq_draw::UiCx>) -> bool {
        let k = self.scale as f64;
        if let InputEvent::MouseMoved { x, y } = *e {
            let p = CGPoint::new(x as f64 / k, y as f64 / k);
            self.hover_settings = if self.frame.contains(p) { self.settings_index(p) } else { None };
            if self.hover_settings.is_some()
                && let Some(cx) = cx
            {
                cx.hover.offer_tip(self.help_at(p).as_deref());
            }
            return false;
        }
        let InputEvent::MouseDown { x, y, modifiers } = *e else { return false };
        let p = CGPoint::new(x as f64 / k, y as f64 / k);
        if !self.frame.contains(p) {
            return false;
        }
        if let Some(i) = self.settings_index(p) {
            let anchor = self.settings_button(i).unwrap_or(self.slots[i].popup);
            self.menus.push(ScopesMenu { items: self.settings_menu(), anchor });
        } else if modifiers.contains(InputModifiers::SECONDARY)
            && let Some(i) = (0..self.slots.len()).find(|i| self.slots[*i].box_.contains(p))
            && self.settings_button(i).is_some()
        {
            // A right-click on a Waveform / Parade box: the same settings menu at the pointer.
            self.menus.push(ScopesMenu { items: self.settings_menu(), anchor: CGRect::new(p.x, p.y, 1.0, 1.0) });
        } else if self.slots.iter().any(|s| s.box_.contains(p))
            && self.clicks.press(x, y, cx.as_ref().map_or(0.0, |c| c.now)) == 2
        {
            self.toggle_all();
        } else if let Some(i) = self.popup_index(p) {
            self.menus.push(ScopesMenu { items: self.menu_items_for(i), anchor: self.slots[i].popup });
        }
        true
    }
}

impl AppHost for ScopesPanel {
    fn sync(&mut self, _session: &sq_editor_session::EditorSession) {
        self.pump();
    }

    fn layout(&mut self, frame: CGRect, _cx: &mut HostCx) {
        self.layout_frame(frame);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut HostCx) {
        self.draw_card(c, t);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let taken = self.handle_event(e, Some(cx.ui));
        self.pump();
        taken
    }
}
