// Swift: Draw/MultibandEditorDraw.swift
//! The Multiband Compressor setup on the shared toolkit: `MultibandEditorPanel` (the Mac floating window) translated into
//! a panel the host draws above the window. Title bar with the clip name and a close button; power, preset, link and
//! output gain; the band strip (draggable crossovers, live band input level and gain reduction from
//! `MultibandMeterTap`); crossover fields; per band Solo / On, five parameter rows and the live reduction; the output
//! limiter. Every control maps to the effect's parameters through the same model calls as the Mac window, and a drag is
//! one undo step. The live spectrum (`AudioSpectrumTap`, after the compressor or at its input) is drawn behind the bars.
//! Coordinates: points, y down, (0, 0) = the panel's top-left, title bar included.
//!
//! The Swift class held the `EffectControlsModel`; here every call takes it. The model's `Edit` events are applied back by
//! the host (`set_clip`) after each call, then the host calls `sync`. The close hook is the `Close` request, the
//! `sq.multiband.spectrumAtInput` default is the `spectrum_at_input` field (the host stores the `SpectrumAtInput` request).

use std::collections::HashMap;
use std::rc::Rc;
use std::sync::OnceLock;

use sq_audiofx::audio_spectrum::{AudioSpectrumTap, SpectrumAnalyzer};
use sq_audiofx::clip_audio_fxchain::ClipAudioFXChain;
use sq_audiofx::multiband_meters::MultibandMeterTap;
use sq_audiofx::spectrum_display::SpectrumDisplay;
use sq_core_model::{ClipEffect, LabelColor};
use sq_core_time::Id;
use sq_draw::inspector::scrub_field_control::Event as ScrubEvent;
use sq_draw::inspector::text_field_control::TAB;
use sq_draw::monitor::audio_meter::MeterBallistics;
use sq_draw::theme::{radius, type_size};
use sq_draw::{
    Canvas, CheckState, ClickCounter, Color, DrawTheme, InputKey, InputModifiers, InspectorDraw, ScrubFieldControl,
    TextAlign, UiCx,
};
use sq_editor_session::EffectSection;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuLayout};

use super::compressor_bands_geometry::CompressorBandsGeometry;
use super::draw_support::MenuRequest;
use super::effect_controls_multiband_model::{MultibandEditor, MultibandMeterDisplay};
use crate::color::color_graph_menus::MenuSink;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectComponent;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    Close,
    Power,
    Preset,
    Link,
    Limiter,
    Strip,
    SpectrumInput,
    Field(String),
    Solo(usize),
    Bypass(usize),
}

/// What the host must do for the panel (Swift `onClose` and the defaults write).
#[derive(Clone, Debug, PartialEq)]
pub enum MultibandEditorRequest {
    /// The close button, Esc, or the effect left the clip: the host removes the panel (and calls `stop_meters`).
    Close,
    /// "Spectrum at Input" changed: the host stores it under `sq.multiband.spectrumAtInput`.
    SpectrumAtInput(bool),
}

pub struct MultibandEditorDraw {
    pub effect: Id,
    pub theme: DrawTheme,
    /// Menus the panel asked for (the preset popup), then `run_menu_commands`.
    pub menus: Vec<MenuRequest>,
    pub requests: Vec<MultibandEditorRequest>,
    /// The `sq.multiband.spectrumAtInput` default; the host sets it when the panel opens.
    pub spectrum_at_input: bool,
    sink: MenuSink<usize>,
    fields: HashMap<String, ScrubFieldControl>,
    focused: Option<String>,
    hover: Option<Control>,
    pressed: Option<Control>,
    strip_drag: Option<usize>,
    strip_hover: Option<usize>,
    counter: ClickCounter,
    meters: MultibandMeterDisplay,
    metering: bool,
    /// The curve behind the bars; the analyzer is made on the first reading.
    spectrum: SpectrumDisplay,
    analyzer: Option<SpectrumAnalyzer>,
    spectrum_samples: Vec<f32>,
    frames: Vec<(Control, CGRect)>,
    /// text, frame, right-aligned
    captions: Vec<(&'static str, CGRect, bool)>,
    heading_frames: Vec<CGRect>,
    band_header_frames: Vec<CGRect>,
    range_frames: Vec<CGRect>,
    reduction_frames: Vec<CGRect>,
    limiter_reduction_frame: CGRect,
    separators: Vec<f64>,
    size: CGSize,
    snapshot: std::collections::BTreeMap<String, f64>,
    clip_name: String,
    enabled: bool,
}

impl MultibandEditorDraw {
    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): capsule 22, Row.property + 2 = 28,
    // Spacing.sm 6 / md 10 / xs 4. Upgrade when SQUIKit's tokens move into a portable file.
    pub const WIDTH: f64 = 560.0;
    const TITLE_HEIGHT: f64 = 32.0;
    const PAD: f64 = 16.0;
    const CAPTION_W: f64 = 96.0;
    const CELL: f64 = 4.0;
    const FH: f64 = 22.0;
    const ROW: f64 = ControlsGrid::ROW_HEIGHT + 2.0;
    const CH: f64 = 14.0;
    const STRIP_HEIGHT: f64 = 96.0;
    const PRESET_WIDTH: f64 = 150.0;
    pub const SPECTRUM_INPUT_DEFAULTS_KEY: &'static str = "sq.multiband.spectrumAtInput";

    /// The fields of the panel: output gain, crossovers, the band rows, the limiter rows.
    pub fn field_keys() -> &'static [String] {
        static KEYS: OnceLock<Vec<String>> = OnceLock::new();
        KEYS.get_or_init(|| {
            let mut k = vec![ClipEffect::MB_OUTPUT_GAIN_KEY.to_string()];
            k.extend((1..=3).map(ClipEffect::mb_crossover_key));
            for r in &MultibandEditor::BAND_ROWS {
                k.extend((1..=MultibandEditor::BAND_COUNT).map(r.key));
            }
            k.extend(MultibandEditor::LIMITER_ROWS.iter().map(|r| r.key.to_string()));
            k
        })
    }

    pub fn new(effect: Id, model: &EffectControlsModel) -> MultibandEditorDraw {
        let mut d = MultibandEditorDraw {
            effect,
            theme: DrawTheme::default(),
            menus: Vec::new(),
            requests: Vec::new(),
            spectrum_at_input: false,
            sink: MenuSink::new(),
            fields: HashMap::new(),
            focused: None,
            hover: None,
            pressed: None,
            strip_drag: None,
            strip_hover: None,
            counter: ClickCounter::new(),
            meters: MultibandMeterDisplay::new(),
            metering: false,
            spectrum: SpectrumDisplay::new(),
            analyzer: None,
            spectrum_samples: Vec::new(),
            frames: Vec::new(),
            captions: Vec::new(),
            heading_frames: Vec::new(),
            band_header_frames: Vec::new(),
            range_frames: Vec::new(),
            reduction_frames: Vec::new(),
            limiter_reduction_frame: CGRect::new(0.0, 0.0, 0.0, 0.0),
            separators: Vec::new(),
            size: CGSize::new(Self::WIDTH, 560.0),
            snapshot: std::collections::BTreeMap::new(),
            clip_name: String::new(),
            enabled: true,
        };
        for key in Self::field_keys() {
            let Some(s) = MultibandEditor::spec(key) else { continue };
            let mut f = ScrubFieldControl::new(s.default_value);
            f.range = s.range.clone();
            f.decimals = s.decimals;
            f.default_value = Some(s.default_value);
            f.step = s.step.max((s.range.end() - s.range.start()) / 400.0);
            d.fields.insert(key.clone(), f);
        }
        d.layout_frames();
        d.sync(model);
        d
    }

    pub fn size(&self) -> CGSize {
        self.size
    }
    pub fn focused(&self) -> Option<&str> {
        self.focused.as_deref()
    }
    pub fn hover(&self) -> Option<&Control> {
        self.hover.as_ref()
    }
    pub fn meters(&self) -> &MultibandMeterDisplay {
        &self.meters
    }
    pub fn spectrum(&self) -> &SpectrumDisplay {
        &self.spectrum
    }
    pub fn clip_name(&self) -> &str {
        &self.clip_name
    }

    /// The frame of a control.
    pub fn frame_of(&self, k: &Control) -> Option<CGRect> {
        self.frames.iter().find(|(c, _)| c == k).map(|(_, f)| *f)
    }

    // MARK: Metrics (MultibandEditorPanel.layout)

    fn layout_frames(&mut self) {
        let (w, pad, fh, row, ch) = (Self::WIDTH, Self::PAD, Self::FH, Self::ROW, Self::CH);
        let dw = w - 2.0 * pad;
        let col_x = pad + Self::CAPTION_W;
        let col_w = (dw - Self::CAPTION_W) / MultibandEditor::BAND_COUNT as f64;
        let field_w = col_w - Self::CELL;
        let mid_y = |y: f64, h: f64, item: f64| y + ((h - item) / 2.0).round();
        let col = |i: usize| col_x + i as f64 * col_w;
        let mut f: Vec<(Control, CGRect)> = Vec::new();
        let mut caps: Vec<(&'static str, CGRect, bool)> = Vec::new();
        f.push((Control::Close, CGRect::new(w - 8.0 - 20.0, (Self::TITLE_HEIGHT - 20.0) / 2.0, 20.0, 20.0)));

        // Top bar: power, preset, link, output gain.
        let mut y = Self::TITLE_HEIGHT + 12.0;
        f.push((Control::Power, CGRect::new(pad, y, fh, fh)));
        f.push((Control::Preset, CGRect::new(pad + fh + 6.0, y, Self::PRESET_WIDTH, fh)));
        let link_x = pad + fh + 6.0 + Self::PRESET_WIDTH + 10.0;
        f.push((Control::Link, CGRect::new(link_x, y, 150.0, fh)));
        f.push((
            Control::Field(ClipEffect::MB_OUTPUT_GAIN_KEY.to_string()),
            CGRect::new(w - pad - field_w, y, field_w, fh),
        ));
        caps.push((
            "Output Gain (dB)",
            CGRect::new(link_x + 150.0 + 6.0, y, (w - pad - field_w - 6.0 - link_x - 156.0).max(0.0), fh),
            true,
        ));
        y += fh + 12.0;
        self.separators = vec![y];
        y += 1.0;

        // Bands: heading, strip, crossover fields.
        y += 10.0;
        self.heading_frames = vec![CGRect::new(pad, y, dw, ch)];
        f.push((Control::SpectrumInput, CGRect::new(w - pad - 140.0, y - 4.0, 140.0, ch + 8.0)));
        y += ch + 6.0;
        f.push((Control::Strip, CGRect::new(pad, y, dw, Self::STRIP_HEIGHT)));
        y += Self::STRIP_HEIGHT + 8.0;
        caps.push(("Crossover (Hz)", CGRect::new(pad, y, Self::CAPTION_W - 4.0, fh), false));
        for i in 1..=3 {
            f.push((Control::Field(ClipEffect::mb_crossover_key(i)), CGRect::new(col(i - 1), y, field_w, fh)));
        }
        y += fh + 12.0;
        self.separators.push(y);
        y += 1.0;

        // Band settings: colored headers with their range, Solo / On, the five rows, live reduction.
        y += 10.0;
        self.heading_frames.push(CGRect::new(pad, y, dw, ch));
        y += ch + 6.0;
        self.band_header_frames = (0..4).map(|i| CGRect::new(col(i), y, field_w, ch)).collect();
        self.range_frames = (0..4).map(|i| CGRect::new(col(i), y + ch, field_w, ch)).collect();
        y += 2.0 * ch + 4.0;
        caps.push(("Solo / On", CGRect::new(pad, y, Self::CAPTION_W - 4.0, row), false));
        let bw = (field_w - 4.0) / 2.0;
        for n in 0..4 {
            f.push((Control::Solo(n), CGRect::new(col(n), mid_y(y, row, fh), bw, fh)));
            f.push((Control::Bypass(n), CGRect::new(col(n) + bw + 4.0, mid_y(y, row, fh), bw, fh)));
        }
        y += row;
        for r in &MultibandEditor::BAND_ROWS {
            caps.push((r.title, CGRect::new(pad, y, Self::CAPTION_W - 4.0, row), false));
            for n in 0..4 {
                f.push((Control::Field((r.key)(n + 1)), CGRect::new(col(n), mid_y(y, row, fh), field_w, fh)));
            }
            y += row;
        }
        caps.push(("Reduction dB", CGRect::new(pad, y, Self::CAPTION_W - 4.0, row), false));
        self.reduction_frames = (0..4).map(|i| CGRect::new(col(i), y, field_w, row)).collect();
        y += row + 6.0;
        self.separators.push(y);
        y += 1.0;

        // Output limiter: the switch with its title, live reduction at the right, four fields under captions.
        y += 10.0;
        f.push((Control::Limiter, CGRect::new(pad, y, 200.0, fh)));
        self.limiter_reduction_frame = CGRect::new(pad + 206.0, y, (w - pad - pad - 206.0).max(0.0), fh);
        y += fh + 6.0;
        for (i, r) in MultibandEditor::LIMITER_ROWS.iter().enumerate() {
            caps.push((r.title, CGRect::new(col(i), y, field_w, ch), false));
        }
        y += ch + 4.0;
        for (i, r) in MultibandEditor::LIMITER_ROWS.iter().enumerate() {
            f.push((Control::Field(r.key.to_string()), CGRect::new(col(i), y, field_w, fh)));
        }
        y += fh + 16.0;
        self.frames = f;
        self.captions = caps;
        self.size = CGSize::new(w, y);
    }

    /// Where the panel opens: under (or above) the button, inside the visible area.
    pub fn frame(&self, anchor: CGRect, visible: CGRect) -> CGRect {
        let area = visible.inset_by(6.0, 6.0);
        let mut y = anchor.max_y() + 4.0;
        if y + self.size.height > area.max_y() {
            y = area.min_y().max(area.max_y() - self.size.height);
        }
        let x = anchor.min_x().max(area.min_x()).min(area.min_x().max(area.max_x() - self.size.width));
        CGRect::new(x, y, self.size.width, self.size.height)
    }

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        self.frames.iter().find(|(_, f)| f.contains(p)).map(|(k, _)| k.clone())
    }

    // MARK: Model

    fn on(&self, k: &str) -> bool {
        self.snapshot.get(k).copied().unwrap_or(0.0) >= 0.5
    }

    pub fn crossovers(&self) -> Vec<f64> {
        (1..=3).map(|i| self.snapshot.get(&ClipEffect::mb_crossover_key(i)).copied().unwrap_or(0.0)).collect()
    }

    fn effect_section(&self) -> EffectSection {
        EffectSection::Effect { id: self.effect, kind: ClipEffect::AUDIO_MULTIBAND_KIND.to_string() }
    }

    /// Reads the effect at the playhead into the fields (a field being typed in or dragged keeps its value). False when
    /// the clip no longer has the effect: the host closes the panel.
    pub fn sync(&mut self, model: &EffectControlsModel) -> bool {
        let Some(name) = model.multiband_clip_name(self.effect) else { return false };
        self.clip_name = name;
        self.enabled = model.is_effect_enabled(&self.effect_section());
        self.snapshot = model.multiband_snapshot(self.effect);
        let limiter_on = self.on(ClipEffect::MB_LIMITER_ON_KEY);
        for key in Self::field_keys() {
            let p = model.multiband_property(self.effect, key);
            let Some(f) = self.fields.get_mut(key) else { continue };
            if !f.is_dragging() && !f.is_editing() {
                f.value = self.snapshot.get(key).copied().unwrap_or(f.value);
            }
            f.is_mixed = model.is_mixed(&p, EffectComponent::All);
            f.is_enabled = !MultibandEditor::LIMITER_ROWS.iter().any(|r| r.key == key) || limiter_on;
        }
        true
    }

    fn set(&self, model: &mut EffectControlsModel, key: &str, v: f64) {
        if let Some(rest) = key.strip_prefix('x')
            && let Ok(i) = rest.parse::<usize>()
        {
            model.set_crossover(self.effect, i.saturating_sub(1), v);
        } else if let Some((r, n)) =
            MultibandEditor::BAND_ROWS.iter().find_map(|r| (1..=4).find(|n| (r.key)(*n) == key).map(|n| (r, n)))
        {
            model.set_multiband_band_value(self.effect, r.key, n - 1, v);
        } else {
            model.set_value(&model.multiband_property(self.effect, key), EffectComponent::All, v);
        }
    }

    fn apply(&mut self, model: &mut EffectControlsModel, events: Vec<ScrubEvent>, key: &str) {
        for e in events {
            match e {
                ScrubEvent::Begin => model.begin_gesture(),
                ScrubEvent::Live(v) | ScrubEvent::Change(v) => self.set(model, key, v),
                ScrubEvent::End(v) => {
                    self.set(model, key, v);
                    model.end_gesture();
                }
                ScrubEvent::Cancel(_) => model.cancel_gesture(),
            }
        }
        self.sync(model);
    }

    // MARK: Meters (the engine's MultibandMeterTap, read every frame while the panel is open)

    pub fn start_meters(&mut self) {
        MultibandMeterTap::shared().watch(Some(self.effect));
        AudioSpectrumTap::shared().watch(Some(self.effect), self.spectrum_at_input);
        self.meters = MultibandMeterDisplay::new();
        self.spectrum = SpectrumDisplay::new();
        self.metering = true;
    }

    pub fn stop_meters(&mut self) {
        if !self.metering {
            return;
        }
        self.metering = false;
        MultibandMeterTap::shared().watch(None);
        AudioSpectrumTap::shared().watch(None, false);
        self.meters = MultibandMeterDisplay::new();
        self.spectrum = SpectrumDisplay::new();
    }

    /// Per frame: meters, idle arrow / wheel bursts. True when something to draw changed.
    pub fn tick(&mut self, model: &mut EffectControlsModel, now: f64) -> bool {
        let keys: Vec<String> = self.fields.keys().cloned().collect();
        for key in keys {
            let Some(mut f) = self.fields.remove(&key) else { continue };
            let ev = f.tick(now);
            self.fields.insert(key.clone(), f);
            if !ev.is_empty() {
                self.apply(model, ev, &key);
            }
        }
        if !self.metering {
            return false;
        }
        let before = self.meters.clone();
        let before_spectrum = self.spectrum.clone();
        self.meters.update(MultibandMeterTap::shared().reading(self.effect).as_ref(), now);
        let seq = AudioSpectrumTap::shared().snapshot(self.effect, &mut self.spectrum_samples);
        let samples = std::mem::take(&mut self.spectrum_samples);
        let mut analyzer = self.analyzer.take().unwrap_or_default();
        self.feed_spectrum(seq, now, || {
            analyzer.magnitudes_db(&samples, ClipAudioFXChain::SAMPLE_RATE as f64, SpectrumDisplay::POINTS)
        });
        self.analyzer = Some(analyzer);
        self.spectrum_samples = samples;
        self.meters != before || self.spectrum != before_spectrum
    }

    /// One spectrum reading (`sequence` None = not watched); the host goes through `tick`, tests call it directly.
    pub fn feed_spectrum(&mut self, sequence: Option<u64>, time: f64, levels: impl FnOnce() -> Vec<f32>) {
        self.spectrum.update(sequence, time, levels);
    }

    /// Spectrum at Input: the curve shows what goes into the compressor instead of what comes out (kept in the defaults).
    fn toggle_spectrum_input(&mut self) {
        let on = !self.spectrum_at_input;
        self.spectrum_at_input = on;
        self.requests.push(MultibandEditorRequest::SpectrumAtInput(on));
        self.spectrum = SpectrumDisplay::new();
        if self.metering {
            AudioSpectrumTap::shared().watch(Some(self.effect), on);
        }
    }

    /// Feeds one reading (tests; the host goes through `tick`).
    pub fn feed(&mut self, r: Option<&sq_audiofx::multiband_meters::MultibandMeterReading>, time: f64) {
        self.meters.update(r, time);
    }

    // MARK: Drawing

    pub fn band_colors(t: &DrawTheme) -> [Color; 4] {
        // Theme.Colors accent, warning, green, clipTitle (the Mac band colors).
        [t.accent(), t.warning(), t.green(), Color::hex(LabelColor::TEXT_DEFAULT.rgb(), 1.0)]
    }

    pub fn draw(&self, c: &mut Canvas, cx: &mut UiCx) {
        let t = self.theme;
        let fs = f64::from(type_size::BODY);
        let cs = f64::from(type_size::CAPTION);
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        let rad = SQMenuLayout::CORNER_RADIUS;
        c.shadow(bounds, rad, 14.0, 6.0, Color::new(0.0, 0.0, 0.0, 0.3), false);
        c.fill_rounded(bounds, rad, t.panel());
        // Title bar: title and clip name, close button.
        c.draw_text_in(
            &SQL10n::string("Multiband Compressor"),
            CGRect::new(Self::PAD, 0.0, 200.0, Self::TITLE_HEIGHT),
            fs,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        let title_w = c.size_of(&SQL10n::string("Multiband Compressor"), fs, 0).width;
        c.draw_text_in(
            &self.clip_name,
            CGRect::new(
                Self::PAD + title_w + 8.0,
                0.0,
                (Self::WIDTH - Self::PAD - title_w - 8.0 - 40.0).max(0.0),
                Self::TITLE_HEIGHT,
            ),
            fs,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        if let Some(f) = self.frame_of(&Control::Close) {
            c.close_x(
                f,
                sq_draw::close_x::CloseXState {
                    hovered: self.hover == Some(Control::Close),
                    pressed: false,
                    focused: false,
                },
                &t,
            );
        }
        c.fill(CGRect::new(0.0, Self::TITLE_HEIGHT - 1.0, Self::WIDTH, 1.0), t.divider());
        for y in &self.separators {
            c.fill(CGRect::new(0.0, *y, Self::WIDTH, 1.0), t.divider());
        }

        // Top bar.
        if let Some(f) = self.frame_of(&Control::Power) {
            if self.hover == Some(Control::Power) {
                c.fill_rounded(f, f64::from(radius::SMALL), t.fill_hover());
            }
            c.draw_icon(
                SQIcon::Power,
                CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0),
                12.0,
                if self.enabled { t.accent() } else { t.label2() },
                None,
            );
        }
        let presets = MultibandEditor::presets();
        let matched = MultibandEditor::matching_preset(&self.snapshot);
        if let Some(f) = self.frame_of(&Control::Preset) {
            let name = matched.map_or("Custom", |i| presets[i].name.as_str());
            InspectorDraw::popup(
                c,
                &SQL10n::string(name),
                f,
                self.hover == Some(Control::Preset),
                false,
                true,
                true,
                f64::from(sq_draw::InspectorTokens::CAPSULE),
                None,
                &t,
            );
        }
        self.checkbox(c, &Control::Link, "Link Band Controls", self.on(ClipEffect::MB_LINK_KEY), fs);
        self.checkbox(c, &Control::SpectrumInput, "Spectrum at Input", self.spectrum_at_input, cs);
        for (text, f, right) in &self.captions {
            c.draw_text_in(
                &SQL10n::string(text),
                *f,
                cs,
                t.label3(),
                if *right { TextAlign::Right } else { TextAlign::Left },
                0.0,
                0,
            );
        }
        for (i, h) in ["Bands", "Band Settings"].iter().enumerate() {
            if let Some(hf) = self.heading_frames.get(i) {
                c.draw_text_in(&SQL10n::string(h), *hf, cs, t.label2(), TextAlign::Left, 0.0, 0);
            }
        }

        // Band strip.
        if let Some(f) = self.frame_of(&Control::Strip) {
            self.draw_strip(c, f);
        }

        // Band columns.
        let colors = Self::band_colors(&t);
        let xs = self.crossovers();
        for n in 0..4 {
            c.draw_text_in(
                &SQL10n::format("Band %@", &[&(n + 1).to_string()]),
                self.band_header_frames[n],
                cs,
                colors[n],
                TextAlign::Left,
                0.0,
                0,
            );
            c.draw_text_in(
                &MultibandEditor::range_text(n, &xs),
                self.range_frames[n],
                cs,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
            self.toggle(c, &Control::Solo(n), "S", self.on(&ClipEffect::mb_solo_key(n + 1)), colors[1]);
            // "On" lights while the band works (the stored key is still the bypass).
            self.toggle(c, &Control::Bypass(n), "On", !self.on(&ClipEffect::mb_bypass_key(n + 1)), t.accent());
            let text = if self.meters.is_live() {
                format!("{:.1}", self.meters.gain_reduction_db()[n])
            } else {
                "\u{2013}".to_string()
            };
            c.draw_text_in(&text, self.reduction_frames[n], cs, t.label2(), TextAlign::Left, 0.0, 0);
        }

        // Limiter.
        self.checkbox(c, &Control::Limiter, "Output Limiter (Brickwall)", self.on(ClipEffect::MB_LIMITER_ON_KEY), fs);
        let lr = if self.meters.is_live() {
            SQL10n::format("Reduction %@ dB", &[&format!("{:.1}", self.meters.limiter_reduction_db())])
        } else {
            SQL10n::string("Reduction \u{2013}")
        };
        c.draw_text_in(&lr, self.limiter_reduction_frame, cs, t.label2(), TextAlign::Right, 0.0, 0);

        // Fields.
        for key in Self::field_keys() {
            let (Some(fd), Some(f)) = (self.fields.get(key), self.frame_of(&Control::Field(key.clone()))) else {
                continue;
            };
            fd.draw(c, f, &t, self.focused.as_deref() == Some(key.as_str()), cx);
        }
        c.stroke_rounded(bounds.inset_by(0.25, 0.25), rad, 0.5, t.ink_fill(0.14));
    }

    fn checkbox(&self, c: &mut Canvas, k: &Control, title: &str, on: bool, font_size: f64) {
        let Some(f) = self.frame_of(k) else { return };
        let boxed = CGRect::new(f.min_x(), f.mid_y() - 7.0, 14.0, 14.0);
        InspectorDraw::checkbox(
            c,
            if on { CheckState::On } else { CheckState::Off },
            boxed,
            self.hover.as_ref() == Some(k),
            self.pressed.as_ref() == Some(k),
            true,
            false,
            &self.theme,
        );
        c.draw_text_in(
            &SQL10n::string(title),
            CGRect::new(boxed.max_x() + 6.0, f.min_y(), f.width - 20.0, f.height),
            font_size,
            self.theme.label(),
            TextAlign::Left,
            0.0,
            0,
        );
    }

    fn toggle(&self, c: &mut Canvas, k: &Control, title: &str, on: bool, tint: Color) {
        let Some(f) = self.frame_of(k) else { return };
        let t = &self.theme;
        let fill = if on || self.pressed.as_ref() == Some(k) {
            t.fill_pressed()
        } else if self.hover.as_ref() == Some(k) {
            t.fill_hover()
        } else {
            t.fill()
        };
        c.fill_rounded(f, f64::from(radius::SMALL), fill);
        c.draw_text_in(
            title,
            f,
            f64::from(type_size::BODY),
            if on { tint } else { t.label2() },
            TextAlign::Center,
            0.0,
            0,
        );
    }

    /// CompressorBandsView.draw: field body, alternate band shading, band input level from the bottom in the band color,
    /// gain-reduction bars from the top, crossover lines with their frequency under the strip.
    fn draw_strip(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let label = 14.0;
        let g = CompressorBandsGeometry::new(f.width);
        let xs = self.crossovers();
        let plot = CGRect::new(f.min_x(), f.min_y(), f.width, f.height - label);
        let r = f64::from(radius::CONTROL);
        c.fill_rounded(plot, r, t.field());
        c.save_gstate();
        c.clip_to(plot);
        let ranges = g.band_ranges(&xs);
        let colors = Self::band_colors(t);
        let any_solo = (1..=4).any(|i| self.on(&ClipEffect::mb_solo_key(i)));
        for (i, b) in ranges.iter().enumerate() {
            if i % 2 == 1 {
                c.fill(CGRect::new(plot.min_x() + b.0, plot.min_y(), b.1 - b.0, plot.height), t.ink_fill(0.025));
            }
        }
        self.draw_spectrum(c, plot);
        let input_db = self.meters.input_db();
        for (i, b) in ranges.iter().enumerate() {
            let dimmed = !self.enabled
                || self.on(&ClipEffect::mb_bypass_key(i + 1))
                || (any_solo && !self.on(&ClipEffect::mb_solo_key(i + 1)));
            let a: f32 = if dimmed { 0.3 } else { 1.0 };
            let level = f64::from(MeterBallistics::position(input_db[i]).clamp(0.0, 1.0));
            let h = plot.height * level;
            let bw = ((b.1 - b.0) * 0.3).clamp(4.0, 14.0);
            if h > 0.0 {
                c.fill(
                    CGRect::new(plot.min_x() + (b.0 + b.1) / 2.0 - bw / 2.0, plot.max_y() - h, bw, h),
                    colors[i].with_alpha(0.55 * a),
                );
            }
            let bar_h =
                plot.height * CompressorBandsGeometry::bar_fraction(f64::from(self.meters.gain_reduction_db()[i]));
            let tint = t.accent_tint();
            c.fill(
                CGRect::new(plot.min_x() + b.0 + 1.0, plot.min_y(), (b.1 - b.0 - 2.0).max(0.0), bar_h),
                tint.with_alpha(tint.a * a),
            );
        }
        c.restore_gstate();
        c.stroke_rounded(plot.inset_by(0.5, 0.5), r - 0.5, 1.0, t.field_edge());
        let cs = f64::from(type_size::CAPTION);
        for (i, hz) in xs.iter().enumerate() {
            let x = plot.min_x() + g.x(*hz).round();
            let active = self.strip_drag == Some(i) || self.strip_hover == Some(i);
            c.fill(
                CGRect::new(x, plot.min_y(), if active { 2.0 } else { 1.0 }, plot.height),
                if active { t.accent() } else { t.label2() },
            );
            let text = CompressorBandsGeometry::hz_text(*hz);
            let w = c.size_of(&text, cs, 0).width;
            let tx = (x - w / 2.0).max(f.min_x()).min(f.max_x() - w);
            c.draw_text(
                &text,
                CGPoint::new(tx, plot.max_y() + 2.0),
                cs,
                if active { t.label() } else { t.label3() },
                f64::INFINITY,
                0,
            );
        }
    }

    /// The spectrum as a filled curve from the bottom plus its outline, neutral so the band colors stay readable on top
    /// (CompressorBandsView.drawSpectrum). Filled per segment: each trapezoid is convex, the whole curve is not.
    fn draw_spectrum(&self, c: &mut Canvas, plot: CGRect) {
        let levels = self.spectrum.levels_db();
        let n = levels.len();
        if n <= 1 || plot.width <= 0.0 {
            return;
        }
        let step = plot.width / (n - 1) as f64;
        let mut points: Vec<CGPoint> = Vec::with_capacity(n);
        for (i, db) in levels.iter().enumerate() {
            let y = plot.height * (1.0 - f64::from(SpectrumDisplay::fraction(*db)));
            points.push(CGPoint::new(plot.min_x() + step * i as f64, plot.min_y() + y));
        }
        let fill = self.theme.label3().with_alpha(0.16);
        for i in 0..n - 1 {
            let (a, b) = (points[i], points[i + 1]);
            c.fill_polygon(&[a, b, CGPoint::new(b.x, plot.max_y()), CGPoint::new(a.x, plot.max_y())], fill);
        }
        c.stroke_polyline(&points, 1.0, self.theme.label3().with_alpha(0.5));
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.pressed.is_some() || self.strip_drag.is_some() {
            return;
        }
        self.hover = p.and_then(|p| self.control_at(p));
        self.strip_hover = None;
        if let Some(p) = p
            && self.hover == Some(Control::Strip)
            && let Some(f) = self.frame_of(&Control::Strip)
        {
            self.strip_hover = CompressorBandsGeometry::new(f.width).handle_index(p.x - f.min_x(), &self.crossovers());
        }
    }

    pub fn mouse_down(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx, p: CGPoint, click_count: Option<i64>) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let k = self.control_at(p);
        if let Some(key) = self.focused.clone()
            && k != Some(Control::Field(key))
        {
            self.resign_focus(model, cx);
        }
        self.pressed = k.clone();
        match k {
            Some(Control::Field(key)) => {
                let Some(mut f) = self.fields.remove(&key) else { return };
                self.focused = Some(key.clone());
                if n == 2 && !f.is_editing() {
                    // Double-click: back to the default, keys included (the Mac field's onReset -> resetAll).
                    self.pressed = None;
                    self.fields.insert(key.clone(), f);
                    model.reset_all(&model.multiband_property(self.effect, &key));
                    self.sync(model);
                    return;
                }
                let ev = f.mouse_down(p.x as f32, n);
                self.fields.insert(key.clone(), f);
                self.apply(model, ev, &key);
            }
            Some(Control::Strip) => {
                let Some(f) = self.frame_of(&Control::Strip) else { return };
                let Some(i) = CompressorBandsGeometry::new(f.width).handle_index(p.x - f.min_x(), &self.crossovers())
                else {
                    self.pressed = None;
                    return;
                };
                self.strip_drag = Some(i);
                model.begin_gesture();
            }
            Some(Control::Preset) => {
                self.pressed = None;
                let matched = MultibandEditor::matching_preset(&self.snapshot);
                let mut items: Vec<SQMenuItem> = MultibandEditor::presets()
                    .iter()
                    .enumerate()
                    .map(|(i, pr)| {
                        let mut row = SQMenuItem::new(&SQL10n::string(&pr.name));
                        row.is_checked = Some(i) == matched;
                        let sink = self.sink.clone();
                        row.action = Some(Rc::new(move || sink.push(i)));
                        row
                    })
                    .collect();
                let mut custom = SQMenuItem::new(&SQL10n::string("Custom"));
                custom.is_enabled = false;
                custom.is_checked = matched.is_none();
                items.push(custom);
                if let Some(f) = self.frame_of(&Control::Preset) {
                    self.menus.push(MenuRequest { items, anchor: f });
                }
            }
            _ => {}
        }
    }

    /// Loads the preset rows the user picked in a menu this panel asked for (the host calls it when the menu closes).
    pub fn run_menu_commands(&mut self, model: &mut EffectControlsModel) {
        for i in self.sink.drain() {
            model.apply_multiband_preset(self.effect, i);
            self.sync(model);
        }
    }

    pub fn mouse_dragged(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        p: CGPoint,
        modifiers: InputModifiers,
    ) {
        if let Some(i) = self.strip_drag
            && let Some(f) = self.frame_of(&Control::Strip)
        {
            let hz = CompressorBandsGeometry::new(f.width).dragged_hz(i, p.x - f.min_x(), &self.crossovers());
            model.set_crossover(self.effect, i, hz);
            self.sync(model);
            return;
        }
        let Some(Control::Field(key)) = self.pressed.clone() else { return };
        let Some(mut f) = self.fields.remove(&key) else { return };
        let ev = f.mouse_dragged(p.x as f32, modifiers, self.theme.scale, cx);
        self.fields.insert(key.clone(), f);
        self.apply(model, ev, &key);
    }

    pub fn mouse_up(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx, p: CGPoint) {
        let k = self.pressed.take();
        self.mouse_up_inner(model, cx, p, k);
        self.mouse_moved(Some(p));
    }

    fn mouse_up_inner(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx, p: CGPoint, k: Option<Control>) {
        if self.strip_drag.is_some() {
            self.strip_drag = None;
            model.end_gesture();
            self.sync(model);
            return;
        }
        if let Some(Control::Field(key)) = &k
            && let Some(mut f) = self.fields.remove(key)
        {
            let ev = f.mouse_up(cx);
            self.fields.insert(key.clone(), f);
            self.apply(model, ev, key);
            return;
        }
        let Some(k) = k else { return };
        if self.control_at(p).as_ref() != Some(&k) {
            return;
        }
        match k {
            Control::Close => self.requests.push(MultibandEditorRequest::Close),
            Control::Power => model.toggle_effect_enabled(&self.effect_section()),
            Control::Link => {
                let on = self.on(ClipEffect::MB_LINK_KEY);
                model.set_multiband_link(self.effect, !on);
            }
            Control::SpectrumInput => self.toggle_spectrum_input(),
            Control::Limiter => {
                let on = self.on(ClipEffect::MB_LIMITER_ON_KEY);
                model.set_value(
                    &model.multiband_property(self.effect, ClipEffect::MB_LIMITER_ON_KEY),
                    EffectComponent::All,
                    if on { 0.0 } else { 1.0 },
                );
            }
            Control::Solo(n) => model.toggle_multiband_solo(self.effect, n),
            Control::Bypass(n) => model.toggle_multiband_bypass(self.effect, n),
            _ => {}
        }
        self.sync(model);
    }

    /// The wheel over a field steps it (with the field's own rules).
    pub fn scroll(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        p: CGPoint,
        dy: f64,
        precise: bool,
        modifiers: InputModifiers,
    ) -> bool {
        let Some(Control::Field(key)) = self.control_at(p) else { return false };
        let Some(mut f) = self.fields.remove(&key) else { return false };
        f.hovering = true;
        let focused = self.focused.as_deref() == Some(key.as_str());
        let (used, ev) = f.scroll(dy, precise, modifiers, focused, cx.now, cx);
        self.fields.insert(key.clone(), f);
        self.apply(model, ev, &key);
        used
    }

    /// Keys for the focused field; Esc with nothing to cancel closes the panel. False = not taken (Space plays).
    pub fn key(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        k: InputKey,
        modifiers: InputModifiers,
    ) -> bool {
        if let Some(key) = self.focused.clone()
            && let Some(mut f) = self.fields.remove(&key)
        {
            if k == TAB {
                self.fields.insert(key.clone(), f);
                let order = Self::field_keys();
                let i = order.iter().position(|x| *x == key).unwrap_or(0);
                self.resign_focus(model, cx);
                let step = if modifiers.contains(InputModifiers::SHIFT) { order.len() - 1 } else { 1 };
                let next = order[(i + step) % order.len()].clone();
                self.focused = Some(next.clone());
                if let Some(nf) = self.fields.get_mut(&next) {
                    nf.begin_editing();
                }
                return true;
            }
            let was_active = f.is_editing() || f.is_dragging();
            let (ev, used) = f.key_used(k, modifiers, cx.now, cx);
            let editing = f.is_editing();
            self.fields.insert(key.clone(), f);
            let empty = ev.is_empty();
            self.apply(model, ev, &key);
            if k == InputKey::Escape && !was_active && empty {
                self.focused = None;
                self.requests.push(MultibandEditorRequest::Close);
            }
            return used && (k != InputKey::Space || editing);
        }
        if k == InputKey::Escape {
            self.requests.push(MultibandEditorRequest::Close);
            return true;
        }
        false
    }

    pub fn resign_focus(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx) {
        let Some(key) = self.focused.take() else { return };
        let Some(mut f) = self.fields.remove(&key) else { return };
        let ev = f.resign_focus(cx);
        self.fields.insert(key.clone(), f);
        self.apply(model, ev, &key);
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.control_at(p)? {
            Control::Power => Some(SQL10n::string("Multiband Compressor On / Off")),
            Control::Link => Some(SQL10n::string("Dragging one band moves all four by the same amount")),
            Control::SpectrumInput => {
                Some(SQL10n::string("Show the spectrum going into the compressor instead of coming out"))
            }
            Control::Limiter => Some(SQL10n::string(
                "Output limiter: raises by margin minus threshold and holds the peaks at the margin",
            )),
            Control::Solo(n) => Some(SQL10n::format("Solo Band %@", &[&(n + 1).to_string()])),
            Control::Bypass(n) => Some(SQL10n::format("Band %@ On", &[&(n + 1).to_string()])),
            Control::Field(key) => MultibandEditor::spec(&key).map(|s| s.title),
            Control::Close => Some(SQL10n::string("Close")),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ec::effect_controls_model::core::EffectControlsEvent;
    use sq_audiofx::multiband_meters::MultibandMeterReading;
    use sq_core_effects::effects_editing::ClipEffectsEditingExt;
    use sq_core_model::{Clip, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    /// The model, the effect, the panel and a host that applies the model's edits back (Swift `onEdit`).
    struct Rig {
        m: EffectControlsModel,
        id: Id,
        e: MultibandEditorDraw,
        cx: UiCx,
    }

    impl Rig {
        fn new() -> Rig {
            let mut clip = Clip::new(
                Id::from_u128(1000),
                "Voice",
                Id::from_u128(1001),
                TrackKind::Audio,
                TimeRange::new(Time::ZERO, Time::new(10, 1)),
                Time::ZERO,
            );
            let mut ids = SequentialIds::default();
            let Some(id) = clip.add_effect(ClipEffect::AUDIO_MULTIBAND_KIND, None, &mut ids) else {
                panic!("no multiband effect")
            };
            let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
            m.set_clip(Some(clip), None, Vec::new(), None);
            let e = MultibandEditorDraw::new(id, &m);
            let mut cx = UiCx::new();
            cx.now = 100.0;
            Rig { m, id, e, cx }
        }

        fn pump(&mut self) {
            for ev in self.m.take_events() {
                if let EffectControlsEvent::Edit { clip, .. } = ev {
                    self.m.set_clip(Some(clip), None, Vec::new(), None);
                }
            }
            self.e.sync(&self.m);
        }

        fn click(&mut self, k: &Control) {
            let Some(f) = self.e.frame_of(k) else { panic!("no frame") };
            let p = CGPoint::new(f.mid_x(), f.mid_y());
            self.e.mouse_down(&mut self.m, &mut self.cx, p, Some(1));
            self.e.mouse_up(&mut self.m, &mut self.cx, p);
            self.pump();
        }
    }

    fn key(k: &str) -> Control {
        Control::Field(k.to_string())
    }

    #[test]
    fn layout_fits_and_every_field_has_a_frame() {
        let r = Rig::new();
        let s = r.e.size();
        assert!(s.width == 560.0 && s.height > 500.0 && s.height < 640.0);
        for k in MultibandEditorDraw::field_keys() {
            assert!(r.e.frame_of(&key(k)).is_some());
        }
        assert_eq!(MultibandEditorDraw::field_keys().len(), 1 + 3 + 20 + 4);
        // Nothing overlaps another control.
        let all: Vec<CGRect> = r.e.frames.iter().map(|x| x.1).collect();
        let hit = |a: &CGRect, b: &CGRect| {
            a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
        };
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert!(!hit(a, b));
            }
        }
        assert_eq!(r.e.clip_name(), "Voice");
    }

    #[test]
    fn toggles_and_preset_menu_edit_the_effect() {
        let mut r = Rig::new();
        r.click(&Control::Solo(1));
        assert!(r.m.multiband_solo(r.id, 1));
        r.click(&Control::Bypass(2));
        assert!(r.m.multiband_bypass(r.id, 2));
        r.click(&Control::Link);
        assert!(r.m.multiband_linked(r.id));
        r.click(&Control::Limiter);
        assert!(r.m.multiband_value(r.id, ClipEffect::MB_LIMITER_ON_KEY) >= 0.5);
        r.click(&Control::Preset);
        let menu = r.e.menus.last().map(|m| m.items.clone()).unwrap_or_default();
        assert_eq!(menu.len(), MultibandEditor::presets().len() + 1);
        if let Some(a) = &menu[1].action {
            a();
        }
        r.e.run_menu_commands(&mut r.m);
        r.pump();
        assert_eq!(r.m.multiband_value(r.id, &ClipEffect::mb_crossover_key(3)), 6910.0);
        r.click(&Control::Power);
        assert!(!r.m.is_effect_enabled(&r.e.effect_section()));
    }

    #[test]
    fn fields_drag_type_and_link_bands() {
        let mut r = Rig::new();
        r.m.set_multiband_link(r.id, true);
        r.pump();
        let gain =
            |r: &Rig| -> Vec<f64> { (1..=4).map(|i| r.m.multiband_value(r.id, &ClipEffect::mb_gain_key(i))).collect() };
        let Some(f) = r.e.frame_of(&key(&ClipEffect::mb_gain_key(1))) else { panic!("no frame") };
        let before = gain(&r);
        r.e.mouse_down(&mut r.m, &mut r.cx, CGPoint::new(f.mid_x(), f.mid_y()), Some(1));
        r.pump();
        r.e.mouse_dragged(&mut r.m, &mut r.cx, CGPoint::new(f.mid_x() + 40.0, f.mid_y()), InputModifiers::NONE);
        r.pump();
        r.e.mouse_up(&mut r.m, &mut r.cx, CGPoint::new(f.mid_x() + 40.0, f.mid_y()));
        r.pump();
        let after = gain(&r);
        assert!(after[0] > before[0]);
        assert!(((after[3] - before[3]) - (after[0] - before[0])).abs() < 0.001); // linked: same delta
        // Typing into a crossover field.
        let Some(x) = r.e.frame_of(&key(&ClipEffect::mb_crossover_key(2))) else { panic!("no frame") };
        let p = CGPoint::new(x.mid_x(), x.mid_y());
        r.e.mouse_down(&mut r.m, &mut r.cx, p, Some(1));
        r.e.mouse_up(&mut r.m, &mut r.cx, p);
        r.pump();
        let type_text = |r: &mut Rig, text: &str| {
            for ch in text.chars() {
                r.cx.typed_text = Some(ch.to_string());
                r.e.key(&mut r.m, &mut r.cx, InputKey::Character(ch), InputModifiers::NONE);
            }
            r.cx.typed_text = None;
        };
        type_text(&mut r, "2000");
        for _ in 0..8 {
            r.e.key(&mut r.m, &mut r.cx, InputKey::Backspace, InputModifiers::NONE);
        }
        type_text(&mut r, "2000");
        r.e.key(&mut r.m, &mut r.cx, InputKey::Enter, InputModifiers::NONE);
        r.pump();
        assert_eq!(r.m.multiband_value(r.id, &ClipEffect::mb_crossover_key(2)), 2000.0);
    }

    #[test]
    fn strip_drags_a_crossover_and_meters_feed_the_bars() {
        let mut r = Rig::new();
        let Some(s) = r.e.frame_of(&Control::Strip) else { panic!("no strip") };
        let g = CompressorBandsGeometry::new(s.width);
        let x0 = s.min_x() + g.x(r.m.crossovers(r.id)[0]);
        r.e.mouse_down(&mut r.m, &mut r.cx, CGPoint::new(x0, s.mid_y()), Some(1));
        r.e.mouse_dragged(&mut r.m, &mut r.cx, CGPoint::new(x0 + 30.0, s.mid_y()), InputModifiers::NONE);
        r.pump();
        r.e.mouse_up(&mut r.m, &mut r.cx, CGPoint::new(x0 + 30.0, s.mid_y()));
        r.pump();
        assert!(r.m.crossovers(r.id)[0] > 130.0);
        let reading = MultibandMeterReading {
            sequence: 3,
            input_peak: [0.5, 0.0, 0.0, 0.0],
            gain_reduction_db: [6.0, 0.0, 0.0, 0.0],
            limiter_reduction_db: 1.0,
        };
        r.e.feed(Some(&reading), 1.0);
        assert!(r.e.meters().is_live() && r.e.meters().gain_reduction_db()[0] == 6.0);
        let mut c = Canvas::with_size(600.0, 600.0, None, 1.0);
        r.e.draw(&mut c, &mut r.cx);
    }

    #[test]
    fn spectrum_curve_feeds_and_input_toggle_is_kept() {
        let mut r = Rig::new();
        r.e.feed_spectrum(Some(1), 0.0, || (0..SpectrumDisplay::POINTS).map(|i| -30.0 - (i % 7) as f32).collect());
        assert_eq!(r.e.spectrum().levels_db().len(), SpectrumDisplay::POINTS);
        let mut c = Canvas::with_size(600.0, 600.0, None, 1.0);
        r.e.draw(&mut c, &mut r.cx);
        r.e.feed_spectrum(Some(1), 1.0, Vec::new); // stale: the curve goes away
        assert!(r.e.spectrum().levels_db().is_empty());
        r.click(&Control::SpectrumInput);
        assert!(r.e.spectrum_at_input);
        let Some(f) = r.e.frame_of(&Control::SpectrumInput) else { panic!("no frame") };
        assert!(r.e.help(CGPoint::new(f.mid_x(), f.mid_y())).is_some());
        r.click(&Control::SpectrumInput);
        assert!(!r.e.spectrum_at_input);
        assert_eq!(
            r.e.requests,
            vec![MultibandEditorRequest::SpectrumAtInput(true), MultibandEditorRequest::SpectrumAtInput(false)]
        );
    }

    #[test]
    fn esc_closes_and_a_gone_effect_reports_it() {
        let mut r = Rig::new();
        assert!(r.e.key(&mut r.m, &mut r.cx, InputKey::Escape, InputModifiers::NONE));
        assert_eq!(r.e.requests, vec![MultibandEditorRequest::Close]);
        // Space is left to the shell (play).
        assert!(!r.e.key(&mut r.m, &mut r.cx, InputKey::Space, InputModifiers::NONE));
        let Some(mut clip) = r.m.clip().cloned() else { panic!("no clip") };
        clip.effects.retain(|e| e.id != r.id);
        r.m.set_clip(Some(clip), None, Vec::new(), None);
        assert!(!r.e.sync(&r.m));
    }

    #[test]
    fn meter_display_follows_sequences_and_goes_stale() {
        let mut d = MultibandMeterDisplay::new();
        let reading = MultibandMeterReading {
            sequence: 1,
            input_peak: [1.0, 0.5, 0.0, 0.0],
            gain_reduction_db: [3.0, -1.0, 0.0, 0.0],
            limiter_reduction_db: -2.0,
        };
        d.update(Some(&reading), 0.0);
        assert!(d.is_live());
        assert_eq!(d.gain_reduction_db(), [3.0, 0.0, 0.0, 0.0]);
        assert_eq!(d.limiter_reduction_db(), 0.0);
        d.update(Some(&reading), 0.1); // same sequence: no new audio, the bars fall
        assert!(d.is_live());
        d.update(Some(&reading), 1.0); // nothing new for STALE_SECONDS
        assert!(!d.is_live());
        assert_eq!(d.gain_reduction_db(), [0.0; 4]);
    }
}
