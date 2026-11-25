// Swift: Draw/TrackAudioDraw.swift
//! Track audio controls on the shared toolkit: `TrackAudioInspectorView` translated (role and preset popups, Denoise,
//! the compressor's Bypass and crossover strip, Noise Gate with attack / hold / release, Warmth and its mix). The model
//! is the Mac `TrackAudioInspectorModel`; this draws it and turns pointer and keys into its setters. Coordinates:
//! points, y down, (0, 0) = the block's top-left; the host reads `height` for the slot.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ops::RangeInclusive;

use sq_audiofx::creator_fx::{NoiseGateLimits, SaturationLimits};
use sq_core_model::AudioTag;
use sq_draw::inspector::scrub_field_control::Event as ScrubEvent;
use sq_draw::inspector::text_field_control::TAB;
use sq_draw::stone::Touch;
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::{
    Canvas, ClickCounter, DrawTheme, InputKey, InputModifiers, InspectorDraw, InspectorTokens, ScrubFieldControl, UiCx,
};
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::redesign_tokens::color as tk;
use sq_uikit::sqmenu_model::SQMenuItem;

use super::audio_effects_tab::{self as fx_tab, EQ_CHIPS, Tab};
use super::compressor_bands_geometry::CompressorBandsGeometry;
use super::compressor_curve;
use super::draw_support::{MenuRequest, offset_by};
use super::track_audio_inspector_model::{ALL_TAGS, BandLimits, TrackAudioInspectorModel};
use crate::color::color_graph_menus::MenuSink;

/// The Role segments' titles: the three roles in `ALL_TAGS` order.
const ROLE_SEGMENTS: [&str; 3] = ["Dialogue", "Music", "Effects"];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    /// The Track | Effects switch.
    Tab,
    /// The EQ plot (click picks a band) and its four chips.
    EqGraph,
    EqBand(usize),
    /// One segment of the Role control (Dialogue, Music, Effects); the active one clears the role again.
    RoleSeg(usize),
    Preset,
    Bypass,
    /// The EQ head's On switch.
    Eq,
    Gate,
    Warmth,
    /// Clean Voice (Track tab row) and the Noise Reduction head (Effects tab): one switch, the denoiser on or off.
    CleanVoice,
    /// The Loudness row's read-only target text.
    Loudness,
    /// "Learn Noise": measures the noise floor of the playhead region.
    LearnNoise,
    Bands,
    /// The transfer curve and the gain-reduction meter (not interactive).
    Curve,
    /// The gain-reduction meter beside the compressor curve (not interactive).
    Meter,
    /// The Noise Gate's open / closed light next to its threshold (not interactive).
    GateState,
    /// The lane under the Noise Reduction head: the learned noise floor (not interactive).
    NoiseGraph,
    Slider(Slider),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Slider {
    Denoise,
    Gate,
    Attack,
    Hold,
    Release,
    Warmth,
    Mix,
    /// The compressor's Threshold, Ratio, Attack, Release of the selected band, and the overall Makeup gain.
    CompThreshold,
    CompRatio,
    CompAttack,
    CompRelease,
    Makeup,
    /// The Effects tab: the picked EQ band's frequency and gain, and the picked Multiband band's gain.
    EqFrequency,
    EqGain,
    /// The picked EQ band's width as a Q, derived from the band's span between its crossovers.
    EqWidth,
    BandGain,
}

impl Slider {
    pub const ALL: [Slider; 16] = [
        Slider::Denoise,
        Slider::Gate,
        Slider::Attack,
        Slider::Hold,
        Slider::Release,
        Slider::Warmth,
        Slider::Mix,
        Slider::CompThreshold,
        Slider::CompRatio,
        Slider::CompAttack,
        Slider::CompRelease,
        Slider::Makeup,
        Slider::EqFrequency,
        Slider::EqGain,
        Slider::EqWidth,
        Slider::BandGain,
    ];
}

#[derive(Clone, Debug)]
pub struct Row {
    pub label: Option<&'static str>,
    /// A card title (drawn stronger, with a rule above unless first).
    pub header: bool,
    pub y: f64,
    pub height: f64,
    pub controls: Vec<(Control, CGRect)>,
    /// Text placed inside the row (labels of the compressor block, quiet hints).
    pub texts: Vec<RowText>,
}

#[derive(Clone, Debug)]
pub struct RowText {
    pub text: &'static str,
    pub rect: CGRect,
    /// Quiet caption (the design's `text-3` hint) instead of a row label.
    pub quiet: bool,
}

/// The Noise Gate light: open, closed, or gray while no live signal feeds it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GateLook {
    Open,
    Closed,
    NoSignal,
}

struct RowsBuilder {
    out: Vec<Row>,
    y: f64,
}

impl RowsBuilder {
    fn add(&mut self, label: Option<&'static str>, header: bool, controls: Vec<(Control, CGRect)>, height: f64) {
        self.add_texts(label, header, controls, height, Vec::new());
    }

    fn add_texts(
        &mut self,
        label: Option<&'static str>,
        header: bool,
        controls: Vec<(Control, CGRect)>,
        height: f64,
        texts: Vec<RowText>,
    ) {
        self.out.push(Row { label, header, y: self.y, height, controls, texts });
        self.y += height;
    }
}

#[derive(Clone, Debug)]
pub struct SliderSpec {
    pub range: RangeInclusive<f64>,
    pub def: f64,
    pub step: f64,
    pub unit: &'static str,
    pub help: Option<&'static str>,
}

/// What a row of the role or preset popup does once the host closes the menu (the menu rows hold no model).
#[derive(Clone, Debug, PartialEq)]
pub enum TrackAudioCommand {
    SetRole(Option<AudioTag>),
    SetLoudness(Option<f64>),
    SelectPreset(String),
    /// The checked "Custom" row: nothing.
    Nothing,
}

pub struct TrackAudioDraw {
    pub model: TrackAudioInspectorModel,
    pub theme: DrawTheme,
    pub width: f64,
    /// Text under the controls (the Mac `note`).
    pub note: String,
    /// Popups opened: the host shows the SQ menu at `anchor` (block coordinates), then calls `run_menu_commands`.
    pub menus: Vec<MenuRequest>,
    sink: MenuSink<TrackAudioCommand>,
    /// One scrub field per slider; `field()` takes it out and `put_field` returns it (Swift copied the struct).
    fields: RefCell<HashMap<Slider, ScrubFieldControl>>,
    focused: Option<Slider>,
    hover: Option<Control>,
    pressed: Option<Control>,
    band_drag: Option<usize>,
    /// The EQ band whose dot is being dragged up and down.
    eq_drag: Option<usize>,
    band_hover: Option<usize>,
    /// The band the compressor's Threshold, Ratio, Attack and Release edit.
    selected_band: usize,
    tab: Tab,
    /// The EQ band the Frequency and Gain rows edit (0..4).
    selected_eq: usize,
    /// Live gain reduction in dB for the meter (0 until the host feeds it).
    gain_reduction_db: f64,
    /// The live gate state for the Noise Gate head (None until the host feeds it).
    gate_open: Option<bool>,
    /// Learn Noise was pressed and waits for the host to hand over the capture (`learn_noise`).
    pub learn_noise_requested: bool,
    /// The noise floor (dBFS) Learn Noise measured in this session; the lane under Noise Reduction marks it.
    learned_floor_db: Option<f64>,
    slider_drag: Option<Slider>,
    field_press: Option<Slider>,
    counter: ClickCounter,
}

impl TrackAudioDraw {
    pub const BANDS_HEIGHT: f64 = CompressorBandsGeometry::STRIP_HEIGHT;
    /// The learned-noise lane under the Noise Reduction head.
    pub const NOISE_GRAPH_HEIGHT: f64 = 56.0;
    /// The Learn Noise button.
    const LEARN_WIDTH: f64 = 92.0;
    /// The curve row: an 80 high curve with 8 above and below.
    pub const CURVE_ROW_HEIGHT: f64 = 96.0;
    const CURVE_SIZE: (f64, f64) = (120.0, 80.0);
    const ROLE_SEG_WIDTH: f64 = 66.0;
    /// The narrowest segment that still shows "Dialogue" whole at caption size.
    const ROLE_SEG_MIN: f64 = 58.0;
    const HINT_WIDTH: f64 = 120.0;
    const BLOCK_GAP: f64 = 14.0;
    const METER_WIDTH: f64 = 26.0;
    const BLOCK_LABEL_WIDTH: f64 = 74.0;
    /// The middle column of the compressor block needs at least this much, else the stacked layout is used.
    const BLOCK_MIN_COLUMN: f64 = 230.0;
    const GATE_LIGHT_LONG: f64 = 130.0;
    const GATE_LIGHT_SHORT: f64 = 56.0;
    const SWITCH_WIDTH: f64 = 34.0;
    /// The width of the "On"/"Off" note left of a header switch.
    const ON_NOTE_WIDTH: f64 = 40.0;
    const LOUDNESS_WIDTH: f64 = 150.0;
    const SWITCH_HEIGHT: f64 = 20.0;
    const FIELD_WIDTH: f64 = 52.0;
    const MAX_TRACK_WIDTH: f64 = 280.0;
    const SLIDER_GAP: f64 = spacing::SM as f64;

    pub fn new(model: TrackAudioInspectorModel) -> TrackAudioDraw {
        TrackAudioDraw {
            model,
            theme: DrawTheme::default(),
            width: 320.0,
            note: String::new(),
            menus: Vec::new(),
            sink: MenuSink::new(),
            fields: RefCell::new(HashMap::new()),
            focused: None,
            hover: None,
            pressed: None,
            band_drag: None,
            eq_drag: None,
            band_hover: None,
            selected_band: 0,
            tab: Tab::Track,
            selected_eq: 0,
            gain_reduction_db: 0.0,
            gate_open: None,
            learn_noise_requested: false,
            learned_floor_db: None,
            slider_drag: None,
            field_press: None,
            counter: ClickCounter::new(),
        }
    }

    /// The band the compressor controls edit (clicking a band in the strip selects it).
    pub fn selected_band(&self) -> usize {
        self.selected_band
    }

    pub fn tab(&self) -> Tab {
        self.tab
    }

    /// Switches the tab (the block's height changes: the host reads `height` again).
    pub fn set_tab(&mut self, tab: Tab) {
        self.tab = tab;
        self.hover = None;
        self.pressed = None;
    }

    pub fn selected_eq(&self) -> usize {
        self.selected_eq
    }

    /// Feeds the meter (the host calls this with the live reduction).
    pub fn set_gain_reduction_db(&mut self, db: f64) {
        self.gain_reduction_db = db.max(0.0);
    }

    /// Feeds the Noise Gate head's Open / Closed indicator.
    pub fn set_gate_open(&mut self, open: Option<bool>) {
        self.gate_open = open;
    }

    /// The Loudness dropdown's text: the integrated target the track is matched to ("Web \u{b7} \u{2212}14 LUFS").
    pub fn loudness_text(&self) -> String {
        TrackAudioInspectorModel::loudness_title(self.model.effective_loudness_target())
    }

    /// The Loudness dropdown's rows: the role's default, then the delivery targets; the current one is checked.
    pub fn loudness_menu(&self) -> Vec<SQMenuItem> {
        let current = self.model.loudness_target();
        TrackAudioInspectorModel::loudness_choices()
            .into_iter()
            .map(|(title, value)| {
                let mut row = SQMenuItem::new(title);
                row.is_checked = value == current;
                let sink = self.sink.clone();
                row.action = Some(std::rc::Rc::new(move || sink.push(TrackAudioCommand::SetLoudness(value))));
                row
            })
            .collect()
    }

    /// Learn Noise with the host's capture (mono samples of the playhead region): measures the floor and sets the gate
    /// and denoiser from it. False when the capture is too short to measure.
    pub fn learn_noise(&mut self, samples: &[f32], sample_rate: f64) -> bool {
        self.learn_noise_requested = false;
        let Some(db) = sq_audiofx::noise_floor::NoiseFloor::db(samples, sample_rate) else { return false };
        self.model.apply_learned_noise_floor(db);
        self.learned_floor_db = Some(db);
        true
    }

    #[cfg(test)]
    fn value_of_band(&self, i: usize) -> sq_audiofx::presets::MultibandBand {
        self.model.compressor().bands[i]
    }

    fn band(&self) -> sq_audiofx::presets::MultibandBand {
        let c = self.model.compressor();
        // The Track tab's single compressor edits all bands together and shows the lowest band's values.
        let i = if self.tab == Tab::Track { 0 } else { self.selected_band };
        c.bands
            .get(i)
            .or(c.bands.first())
            .copied()
            .unwrap_or(sq_audiofx::presets::MultibandBand::new(-20.0, 3.0, 10.0, 120.0))
    }

    pub fn focused(&self) -> Option<Slider> {
        self.focused
    }
    pub fn hover(&self) -> Option<Control> {
        self.hover
    }

    // MARK: Rows (the Mac stack, top to bottom)

    pub fn rows(&self) -> Vec<Row> {
        let rh = ControlsGrid::ROW_HEIGHT;
        let x0 = ControlsGrid::VALUE_X;
        let x1 = (self.width - ControlsGrid::TRAILING).max(x0);
        let ch = ControlsGrid::CONTROL_HEIGHT;
        let boxed = |x: f64, w: f64, h: f64| CGRect::new(x, ((rh - h) / 2.0).round(), w.max(0.0), h);
        let full = boxed(x0, x1 - x0, ch);
        let full_slider = boxed(x0, x1 - x0, ch);
        // Group heads: the title takes the row, the quiet On / Off label and the switch sit at its right end.
        let right = |w: f64| boxed(x1 - w, w, Self::SWITCH_HEIGHT);
        let mut b = RowsBuilder { out: Vec::new(), y: 0.0 };
        // The Track | Effects switch hugs its labels like the kit's segments.
        let strip_w = Self::tab_widths().iter().sum::<f64>().min((x1 - ControlsGrid::LABEL_X).max(0.0));
        b.add(
            None,
            false,
            vec![(Control::Tab, CGRect::new(ControlsGrid::LABEL_X, ((rh - ch) / 2.0).round(), strip_w, ch))],
            rh,
        );
        match self.tab {
            Tab::Track => {
                // Role: a segmented control (Dialogue / Music / Effects) and a quiet hint when there is room. A value
                // column too narrow for the words (the 640 wide window) puts the segments on their own row under "Role".
                let stacked = x1 - x0 < 3.0 * Self::ROLE_SEG_MIN;
                let seg_x = if stacked { ControlsGrid::LABEL_X } else { x0 };
                let seg_w = (x1 - seg_x).clamp(0.0, 3.0 * Self::ROLE_SEG_WIDTH);
                let each = (seg_w / 3.0).floor();
                let segs: Vec<(Control, CGRect)> = (0..3)
                    .map(|i| {
                        let w = if i == 2 { seg_w - 2.0 * each } else { each };
                        (Control::RoleSeg(i), boxed(seg_x + each * i as f64, w, ch))
                    })
                    .collect();
                if stacked {
                    b.add(Some("Role"), false, Vec::new(), rh);
                    b.add(None, false, segs, rh);
                } else {
                    let hint_x = x0 + seg_w + Self::SLIDER_GAP;
                    let hint_room = x1 - hint_x;
                    let texts = if hint_room >= Self::HINT_WIDTH {
                        vec![RowText {
                            text: "Sets the starting chain",
                            rect: CGRect::new(hint_x, 0.0, hint_room, rh),
                            quiet: true,
                        }]
                    } else {
                        Vec::new()
                    };
                    b.add_texts(Some("Role"), false, segs, rh, texts);
                }
                // Clean Voice: the switch and, beside it, the denoiser amount in percent.
                let sw = Self::SWITCH_WIDTH;
                let amount = boxed(x0 + sw + Self::SLIDER_GAP, (x1 - x0 - sw - Self::SLIDER_GAP).max(0.0), ch);
                b.add(
                    Some("Clean Voice"),
                    false,
                    vec![
                        (Control::CleanVoice, boxed(x0, sw, Self::SWITCH_HEIGHT)),
                        (Control::Slider(Slider::Denoise), amount),
                    ],
                    rh,
                );
                b.add(
                    Some("Loudness"),
                    false,
                    vec![(Control::Loudness, boxed(x0, Self::LOUDNESS_WIDTH.min(x1 - x0), ch))],
                    rh,
                );
                b.add(Some("Compressor"), true, vec![(Control::Bypass, right(Self::SWITCH_WIDTH))], rh);
                self.compressor_block(&mut b, x1);
            }
            Tab::Effects => {
                // The preset menu lives here: the Track tab keeps the kit's Role / Clean Voice / Loudness rows.
                b.add(Some("Preset"), false, vec![(Control::Preset, full)], rh);
                let chip_w = ((x1 - ControlsGrid::LABEL_X) / 4.0).floor();
                let chips: Vec<(Control, CGRect)> = (0..4)
                    .map(|i| {
                        (
                            Control::EqBand(i),
                            CGRect::new(
                                ControlsGrid::LABEL_X + chip_w * i as f64,
                                ((rh - ch) / 2.0).round(),
                                chip_w - 4.0,
                                ch,
                            ),
                        )
                    })
                    .collect();
                b.add(Some("EQ"), true, vec![(Control::Eq, right(Self::SWITCH_WIDTH))], rh);
                b.add(
                    None,
                    false,
                    vec![(Control::EqGraph, CGRect::new(ControlsGrid::LABEL_X, 0.0, strip_w, Self::CURVE_ROW_HEIGHT))],
                    Self::CURVE_ROW_HEIGHT,
                );
                b.add(None, false, chips, rh);
                b.add(Some("Frequency"), false, vec![(Control::Slider(Slider::EqFrequency), full_slider)], rh);
                b.add(Some("Gain"), false, vec![(Control::Slider(Slider::EqGain), full_slider)], rh);
                b.add(Some("Width (Q)"), false, vec![(Control::Slider(Slider::EqWidth), full_slider)], rh);
                b.add(Some("Noise Gate"), true, vec![(Control::Gate, right(Self::SWITCH_WIDTH))], rh);
                // Threshold: the slider, its field, and the open / closed light after them.
                let long = (x1 - x0) - Self::FIELD_WIDTH - 2.0 * Self::SLIDER_GAP - Self::GATE_LIGHT_LONG >= 60.0;
                let light_w = if long { Self::GATE_LIGHT_LONG } else { Self::GATE_LIGHT_SHORT };
                let light_w = light_w.min((x1 - x0) / 2.0);
                let slider_w = (x1 - x0 - light_w - Self::SLIDER_GAP).max(0.0);
                b.add(
                    Some("Threshold"),
                    false,
                    vec![
                        (Control::Slider(Slider::Gate), boxed(x0, slider_w, ch)),
                        (Control::GateState, boxed(x1 - light_w, light_w, ch)),
                    ],
                    rh,
                );
                b.add(Some("Attack"), false, vec![(Control::Slider(Slider::Attack), full_slider)], rh);
                b.add(Some("Hold"), false, vec![(Control::Slider(Slider::Hold), full_slider)], rh);
                b.add(Some("Release"), false, vec![(Control::Slider(Slider::Release), full_slider)], rh);
                b.add(Some("Noise Reduction"), true, vec![(Control::CleanVoice, right(Self::SWITCH_WIDTH))], rh);
                b.add(
                    None,
                    false,
                    vec![(
                        Control::NoiseGraph,
                        CGRect::new(ControlsGrid::LABEL_X, 0.0, strip_w, Self::NOISE_GRAPH_HEIGHT),
                    )],
                    Self::NOISE_GRAPH_HEIGHT + ControlsGrid::GAP,
                );
                // Amount: the slider with its field, then the Learn Noise button (kit).
                let learn_w = Self::LEARN_WIDTH.min((x1 - x0) / 2.0);
                let (track, field) = self.slider_parts(boxed(x0, (x1 - x0 - learn_w - Self::SLIDER_GAP).max(0.0), ch));
                let _ = track;
                let learn_x = (field.max_x() + Self::SLIDER_GAP).min(x1 - learn_w);
                b.add(
                    Some("Amount"),
                    false,
                    vec![
                        (
                            Control::Slider(Slider::Denoise),
                            boxed(x0, (x1 - x0 - learn_w - Self::SLIDER_GAP).max(0.0), ch),
                        ),
                        (Control::LearnNoise, boxed(learn_x, learn_w, ch)),
                    ],
                    rh,
                );
                b.add(Some("Warmth"), true, vec![(Control::Warmth, right(Self::SWITCH_WIDTH))], rh);
                b.add(Some("Amount"), false, vec![(Control::Slider(Slider::Warmth), full_slider)], rh);
                b.add(Some("Mix"), false, vec![(Control::Slider(Slider::Mix), full_slider)], rh);
                b.add(Some("Multiband Compressor"), true, vec![(Control::Bypass, right(Self::SWITCH_WIDTH))], rh);
                b.add(
                    None,
                    false,
                    vec![(Control::Bands, CGRect::new(ControlsGrid::LABEL_X, 0.0, strip_w, Self::BANDS_HEIGHT))],
                    Self::BANDS_HEIGHT + ControlsGrid::GAP,
                );
                b.add(Some(self.band_title()), false, Vec::new(), rh);
                b.add(Some("Threshold"), false, vec![(Control::Slider(Slider::CompThreshold), full_slider)], rh);
                b.add(Some("Ratio"), false, vec![(Control::Slider(Slider::CompRatio), full_slider)], rh);
                b.add(Some("Gain"), false, vec![(Control::Slider(Slider::BandGain), full_slider)], rh);
                b.add(Some("Attack"), false, vec![(Control::Slider(Slider::CompAttack), full_slider)], rh);
                b.add(Some("Release"), false, vec![(Control::Slider(Slider::CompRelease), full_slider)], rh);
            }
        }
        b.out
    }

    /// The single-compressor body under the Track tab's Compressor head. Wide panels: the design's one block (curve left,
    /// the five sliders with their labels in the middle, the thin meter right). Narrow panels: the curve and meter on
    /// their own row, then the five labeled slider rows. The crossover strip lives only in the Multiband group.
    fn compressor_block(&self, b: &mut RowsBuilder, x1: f64) {
        let rh = ControlsGrid::ROW_HEIGHT;
        let ch = ControlsGrid::CONTROL_HEIGHT;
        let (cw, chh) = Self::CURVE_SIZE;
        let curve_x = ControlsGrid::LABEL_X;
        let col_x = curve_x + cw + Self::BLOCK_GAP;
        let col_w = x1 - col_x - Self::METER_WIDTH - Self::BLOCK_GAP;
        let sliders: [(&'static str, Slider); 5] = [
            ("Threshold", Slider::CompThreshold),
            ("Ratio", Slider::CompRatio),
            ("Attack", Slider::CompAttack),
            ("Release", Slider::CompRelease),
            ("Makeup gain", Slider::Makeup),
        ];
        if col_w >= Self::BLOCK_MIN_COLUMN {
            let pad = 8.0;
            let height = pad * 2.0 + rh * 5.0;
            let mut controls = vec![
                (Control::Curve, CGRect::new(curve_x, pad, cw, chh)),
                (Control::Meter, CGRect::new(x1 - Self::METER_WIDTH, pad, Self::METER_WIDTH, rh * 5.0)),
            ];
            let mut texts = Vec::new();
            for (i, (label, s)) in sliders.into_iter().enumerate() {
                let y = pad + rh * i as f64 + ((rh - ch) / 2.0).round();
                texts.push(RowText {
                    text: label,
                    rect: CGRect::new(col_x, y, Self::BLOCK_LABEL_WIDTH, ch),
                    quiet: false,
                });
                controls.push((
                    Control::Slider(s),
                    CGRect::new(col_x + Self::BLOCK_LABEL_WIDTH, y, (col_w - Self::BLOCK_LABEL_WIDTH).max(0.0), ch),
                ));
            }
            b.add_texts(None, false, controls, height, texts);
        } else {
            let meter = CGRect::new(curve_x + cw + 14.0, 8.0, Self::METER_WIDTH, chh);
            b.add(
                None,
                false,
                vec![(Control::Curve, CGRect::new(curve_x, 8.0, cw, chh)), (Control::Meter, meter)],
                Self::CURVE_ROW_HEIGHT,
            );
            let x0 = ControlsGrid::VALUE_X;
            let full = CGRect::new(x0, ((rh - ch) / 2.0).round(), (x1 - x0).max(0.0), ch);
            for (label, s) in sliders {
                b.add(Some(label), false, vec![(Control::Slider(s), full)], rh);
            }
        }
    }

    fn band_title(&self) -> &'static str {
        ["Low band", "Low mid band", "High mid band", "High band"].get(self.selected_band).copied().unwrap_or("Band")
    }

    /// The note row: label column to the trailing inset, gap above and below.
    fn note_height(&self) -> f64 {
        if self.note.is_empty() {
            return 0.0;
        }
        let fs = f64::from(type_size::BODY);
        // The note wraps; the line count is estimated from the text length (0.6 em per glyph, a little generous) because
        // the height is asked for without a canvas to measure on.
        let room = (self.width - ControlsGrid::LABEL_X - ControlsGrid::TRAILING).max(fs);
        let per_line = (room / (fs * 0.6)).floor().max(1.0);
        let lines = (self.note.chars().count() as f64 / per_line).ceil().max(1.0);
        lines * (fs + 4.0) + 2.0 * ControlsGrid::GAP
    }

    pub fn height(&self) -> f64 {
        self.rows().last().map_or(0.0, |r| r.y + r.height) + self.note_height()
    }

    /// Slider parts: the track left, the value field right (NumericSlider.layout).
    pub fn slider_parts(&self, r: CGRect) -> (CGRect, CGRect) {
        let fw = Self::FIELD_WIDTH.min(r.width);
        // The kit keeps the track about 280 pt long with its field right next to it, however wide the panel is.
        let track_w = (r.width - fw - Self::SLIDER_GAP).clamp(0.0, Self::MAX_TRACK_WIDTH);
        let field = CGRect::new(
            r.min_x() + track_w + if track_w > 0.0 { Self::SLIDER_GAP } else { 0.0 },
            r.min_y(),
            fw,
            r.height,
        );
        (CGRect::new(r.min_x(), r.min_y(), track_w, r.height), field)
    }

    pub fn frame(&self, c: Control) -> Option<CGRect> {
        for r in self.rows() {
            if let Some(f) = r.controls.iter().find(|x| x.0 == c).map(|x| x.1) {
                return Some(offset_by(&f, 0.0, r.y));
            }
        }
        None
    }

    // MARK: Values

    pub fn spec(&self, s: Slider) -> SliderSpec {
        match s {
            Slider::Denoise => {
                SliderSpec { range: 0.0..=100.0, def: 0.0, step: 1.0, unit: "%", help: Some("Noise reduction") }
            }
            Slider::Gate => {
                SliderSpec { range: NoiseGateLimits::THRESHOLD_DB, def: -45.0, step: 1.0, unit: "dB", help: None }
            }
            Slider::Attack => SliderSpec {
                range: NoiseGateLimits::ATTACK_MS,
                def: 2.0,
                step: 0.1,
                unit: "ms",
                help: Some("How fast the gate opens"),
            },
            Slider::Hold => SliderSpec {
                range: NoiseGateLimits::HOLD_MS,
                def: 80.0,
                step: 1.0,
                unit: "ms",
                help: Some("How long the gate stays open after the sound drops below the threshold"),
            },
            Slider::Release => SliderSpec {
                range: NoiseGateLimits::RELEASE_MS,
                def: 150.0,
                step: 1.0,
                unit: "ms",
                help: Some("How fast the gate closes"),
            },
            Slider::Warmth => {
                SliderSpec { range: SaturationLimits::DRIVE_DB, def: 6.0, step: 1.0, unit: "dB", help: None }
            }
            Slider::CompThreshold => SliderSpec {
                range: BandLimits::THRESHOLD_DB,
                def: -20.0,
                step: 1.0,
                unit: "dB",
                help: Some("Above this level the compressor turns the sound down"),
            },
            Slider::CompRatio => SliderSpec {
                range: BandLimits::RATIO,
                def: 3.0,
                step: 0.1,
                unit: ":1",
                help: Some("How much of the part above the threshold is turned down: 3:1 lets 3 dB become 1 dB"),
            },
            Slider::CompAttack => SliderSpec {
                range: BandLimits::ATTACK_MS,
                def: 10.0,
                step: 0.5,
                unit: "ms",
                help: Some("How fast the compressor reacts"),
            },
            Slider::CompRelease => SliderSpec {
                range: BandLimits::RELEASE_MS,
                def: 120.0,
                step: 1.0,
                unit: "ms",
                help: Some("How fast it lets go again"),
            },
            Slider::Makeup => SliderSpec {
                range: BandLimits::OVERALL_GAIN_DB,
                def: 0.0,
                step: 0.5,
                unit: "dB",
                help: Some("Brings the level back up after compressing"),
            },
            Slider::EqFrequency => SliderSpec {
                range: 20.0..=20_000.0,
                def: 1000.0,
                step: 1.0,
                unit: "Hz",
                help: Some("The middle of a bell, the corner of a shelf"),
            },
            Slider::EqGain => SliderSpec {
                range: BandLimits::GAIN_DB,
                def: 0.0,
                step: 0.5,
                unit: "dB",
                help: Some("Turns this part of the sound up or down"),
            },
            Slider::EqWidth => SliderSpec {
                range: fx_tab::EQ_Q_RANGE,
                def: 1.0,
                step: 0.1,
                unit: "",
                help: Some("How wide this EQ band is: a low number is wide, a high number is narrow"),
            },
            Slider::BandGain => SliderSpec {
                range: BandLimits::GAIN_DB,
                def: 0.0,
                step: 0.5,
                unit: "dB",
                help: Some("Level of this band after compressing"),
            },
            Slider::Mix => SliderSpec {
                range: 0.0..=100.0,
                def: 100.0,
                step: 1.0,
                unit: "%",
                help: Some("Warmth mix: 0 % is the dry sound, 100 % the fully warmed sound"),
            },
        }
    }

    pub fn value(&self, s: Slider) -> f64 {
        match s {
            Slider::Denoise => self.model.noise_reduction_percent(),
            Slider::Gate => self.model.gate().threshold_db,
            Slider::Attack => self.model.gate().attack_ms,
            Slider::Hold => self.model.gate().hold_ms,
            Slider::Release => self.model.gate().release_ms,
            Slider::Warmth => self.model.saturation().drive_db,
            Slider::Mix => (self.model.saturation().mix * 100.0).round(),
            Slider::CompThreshold => self.band().threshold_db,
            Slider::CompRatio => self.band().ratio,
            Slider::CompAttack => self.band().attack_ms,
            Slider::CompRelease => self.band().release_ms,
            Slider::Makeup => self.model.compressor().makeup_gain_db,
            Slider::EqFrequency => fx_tab::eq_frequency(self.selected_eq, &self.model.compressor().crossovers_hz),
            Slider::EqGain => self.model.compressor().bands.get(self.selected_eq).map_or(0.0, |b| b.gain_db),
            Slider::EqWidth => fx_tab::eq_q(self.selected_eq, &self.model.compressor().crossovers_hz),
            Slider::BandGain => self.band().gain_db,
        }
    }

    pub fn is_enabled(&self, s: Slider) -> bool {
        match s {
            Slider::Denoise => true,
            Slider::Gate | Slider::Attack | Slider::Hold | Slider::Release => self.model.gate().enabled,
            Slider::Warmth | Slider::Mix => self.model.saturation().enabled,
            Slider::CompThreshold
            | Slider::CompRatio
            | Slider::CompAttack
            | Slider::CompRelease
            | Slider::Makeup
            | Slider::BandGain => !self.model.compressor().bypass,
            // The EQ has its own switch and works while the compressor is off (the audio chain applies it alone).
            Slider::EqFrequency | Slider::EqGain | Slider::EqWidth => true,
        }
    }

    fn set(&mut self, s: Slider, v: f64) {
        match s {
            Slider::Denoise => self.model.set_noise_reduction_percent(v),
            Slider::Gate => self.model.set_gate_threshold_db(v),
            Slider::Attack => self.model.set_gate_attack_ms(v),
            Slider::Hold => self.model.set_gate_hold_ms(v),
            Slider::Release => self.model.set_gate_release_ms(v),
            Slider::Warmth => self.model.set_warmth_drive_db(v),
            Slider::Mix => self.model.set_warmth_mix_percent(v),
            Slider::CompThreshold => self.set_compressor_band(|b| b.threshold_db = v),
            Slider::CompRatio => self.set_compressor_band(|b| b.ratio = v),
            Slider::CompAttack => self.set_compressor_band(|b| b.attack_ms = v),
            Slider::CompRelease => self.set_compressor_band(|b| b.release_ms = v),
            Slider::Makeup => self.model.set_makeup_gain_db(v),
            Slider::EqFrequency => {
                let i = self.selected_eq;
                if fx_tab::eq_is_bell(i) {
                    let (lo_i, lo, hi) = fx_tab::bell_for_frequency(i, v, &self.model.compressor().crossovers_hz);
                    self.model.set_crossover_pair(lo_i, lo, hi);
                } else {
                    self.model.set_crossover(fx_tab::eq_frequency_index(i), v);
                }
            }
            Slider::EqGain => self.model.set_band(self.selected_eq, |b| b.gain_db = v),
            Slider::EqWidth => {
                let i = self.selected_eq;
                if fx_tab::eq_is_bell(i) {
                    let (lo_i, lo, hi) = fx_tab::bell_for_q(i, v, &self.model.compressor().crossovers_hz);
                    self.model.set_crossover_pair(lo_i, lo, hi);
                } else {
                    let (j, hz) = fx_tab::eq_edge_for_q(i, v, &self.model.compressor().crossovers_hz);
                    self.model.set_crossover(j, hz);
                }
            }
            Slider::BandGain => self.model.set_band(self.selected_band, |b| b.gain_db = v),
        }
    }

    /// The compressor sliders: on the Track tab (one compressor) every band takes the value together; on the Effects tab
    /// (Multiband) only the picked band.
    fn set_compressor_band(&mut self, body: impl Fn(&mut sq_audiofx::presets::MultibandBand)) {
        if self.tab == Tab::Track {
            self.model.set_all_bands(body);
        } else {
            self.model.set_band(self.selected_band, body);
        }
    }

    /// One scrub field per slider; refilled from the model unless it is in a gesture or being typed into.
    fn field(&self, s: Slider) -> ScrubFieldControl {
        let mut f = self.fields.borrow_mut().remove(&s).unwrap_or_else(|| ScrubFieldControl::new(self.value(s)));
        let sp = self.spec(s);
        f.range = sp.range;
        f.step = sp.step;
        f.unit = sp.unit.to_string();
        f.default_value = Some(sp.def);
        f.decimals = if sp.step < 1.0 { 1 } else { 0 };
        f.is_enabled = self.is_enabled(s);
        if !f.is_dragging() && !f.is_editing() {
            f.value = self.value(s);
        }
        f
    }

    fn put_field(&self, s: Slider, fd: ScrubFieldControl) {
        self.fields.borrow_mut().insert(s, fd);
    }

    fn apply(&mut self, events: Vec<ScrubEvent>, s: Slider) {
        for e in events {
            match e {
                ScrubEvent::Begin => self.model.begin_change(),
                ScrubEvent::Live(v) | ScrubEvent::Change(v) => self.set(s, v),
                ScrubEvent::End(v) | ScrubEvent::Cancel(v) => {
                    self.set(s, v);
                    self.model.end_change();
                }
            }
        }
    }

    // MARK: Drawing

    pub fn draw(&self, c: &mut Canvas, cx: &mut UiCx) {
        let t = &self.theme;
        let fs = f64::from(type_size::BODY);
        let h = self.height();
        c.fill(CGRect::new(0.0, 0.0, self.width, h), t.panel());
        for r in self.rows() {
            if r.header {
                // The kit's section header (`Panels/SectionHeader/Open/*`): a group band with a hairline above and below,
                // the semibold title; the On switch sits at the right end (drawn with its control).
                let band = CGRect::new(0.0, r.y, self.width, r.height);
                c.fill(band, t.token(tk::GROUP));
                c.fill(CGRect::new(0.0, band.min_y(), self.width, 1.0), t.token(tk::LINE));
                c.fill(CGRect::new(0.0, band.max_y() - 1.0, self.width, 1.0), t.token(tk::LINE));
                // No chevron: this card has no fold (a chevron that did nothing was decoration, r8 FUNDE).
            }
            if let Some(l) = r.label {
                let face = if r.header { c.semibold() } else { 0 };
                let x = ControlsGrid::LABEL_X;
                // The header title ends before the On/Off note and its switch, whatever the width.
                let header_right =
                    r.controls.iter().map(|(_, f)| f.min_x() - Self::ON_NOTE_WIDTH - 6.0).fold(self.width, f64::min);
                let room = if r.header {
                    (header_right - x - ControlsGrid::GAP).max(0.0)
                } else {
                    ControlsGrid::VALUE_X - ControlsGrid::LABEL_X - ControlsGrid::GAP
                };
                let title = SQL10n::string(l);
                let shown = if r.header {
                    sq_draw::middle_fit::truncate_name(&title, |n| c.size_of(n, fs, face).width <= room).shown
                } else {
                    title
                };
                c.draw_text_in(
                    &shown,
                    CGRect::new(x, r.y, room, r.height),
                    fs,
                    if r.header { t.label() } else { t.label2() },
                    sq_draw::TextAlign::Left,
                    0.0,
                    face,
                );
            }
            for tx in &r.texts {
                c.draw_text_in(
                    &SQL10n::string(tx.text),
                    offset_by(&tx.rect, 0.0, r.y),
                    if tx.quiet { f64::from(type_size::CAPTION) } else { fs },
                    if tx.quiet { t.label3() } else { t.label2() },
                    sq_draw::TextAlign::Left,
                    0.0,
                    0,
                );
            }
            for (k, f0) in &r.controls {
                let k = *k;
                let f = offset_by(f0, 0.0, r.y);
                match k {
                    Control::Tab => self.draw_tab(c, f),
                    Control::EqGraph => self.draw_eq(c, f),
                    Control::EqBand(i) => {
                        let on = i == self.selected_eq;
                        let touch = Touch {
                            hovering: self.hover == Some(k),
                            pressed: self.pressed == Some(k),
                            ..Touch::default()
                        };
                        c.stone_chip(f, on, false, touch, t);
                        c.draw_text_in(
                            &SQL10n::string(EQ_CHIPS[i.min(3)]),
                            f,
                            f64::from(type_size::CAPTION),
                            if on { t.label() } else { t.label2() },
                            sq_draw::TextAlign::Center,
                            0.0,
                            0,
                        );
                    }
                    Control::RoleSeg(i) => {
                        if i == 0
                            && let Some(last) = self.frame(Control::RoleSeg(2))
                        {
                            c.stone_segment_track(
                                CGRect::new(f.min_x(), f.min_y(), last.max_x() - f.min_x(), f.height),
                                Touch::default(),
                                t,
                            );
                        }
                        let on = self.model.role_is_active(ALL_TAGS[i]);
                        let touch = Touch { hovering: self.hover == Some(k) && !on, ..Touch::default() };
                        c.stone_segment(f.inset_by(0.0, 1.0), on, touch, t);
                        c.draw_text_in(
                            &SQL10n::string(ROLE_SEGMENTS[i]),
                            f,
                            f64::from(type_size::CAPTION),
                            if on { t.label() } else { t.label2() },
                            sq_draw::TextAlign::Center,
                            0.0,
                            0,
                        );
                    }
                    Control::Preset => InspectorDraw::popup(
                        c,
                        &self.preset_title(),
                        f,
                        self.hover == Some(k),
                        false,
                        true,
                        true,
                        f64::from(InspectorTokens::CAPSULE),
                        None,
                        t,
                    ),
                    Control::Bypass => self.draw_on_switch(c, f, !self.model.compressor().bypass, k),
                    Control::CleanVoice if self.tab == Tab::Effects => {
                        self.draw_on_switch(c, f, self.model.clean_voice_on(), k);
                    }
                    Control::CleanVoice => {
                        let touch = Touch {
                            hovering: self.hover == Some(k),
                            pressed: self.pressed == Some(k),
                            ..Touch::default()
                        };
                        c.stone_switch(f, self.model.clean_voice_on(), touch, t);
                    }
                    Control::Loudness => {
                        InspectorDraw::popup(
                            c,
                            &self.loudness_text(),
                            f,
                            self.hover == Some(k),
                            false,
                            true,
                            true,
                            f64::from(InspectorTokens::CAPSULE),
                            None,
                            t,
                        );
                        c.draw_text_in(
                            &SQL10n::string("Peak limit \u{2212}1 dBTP"),
                            CGRect::new(f.max_x() + 8.0, f.min_y(), (self.width - f.max_x() - 8.0).max(0.0), f.height),
                            f64::from(type_size::CAPTION),
                            t.label3(),
                            sq_draw::TextAlign::Left,
                            0.0,
                            0,
                        );
                    }
                    Control::LearnNoise => {
                        InspectorDraw::button(
                            c,
                            &SQL10n::string(if self.learn_noise_requested { "Listening..." } else { "Learn Noise" }),
                            f,
                            self.hover == Some(k),
                            self.pressed == Some(k),
                            !self.learn_noise_requested,
                            false,
                            f64::from(InspectorTokens::CAPSULE),
                            t,
                        );
                    }
                    Control::NoiseGraph => self.draw_noise_graph(c, f),
                    Control::Eq => self.draw_on_switch(c, f, self.model.compressor().eq_on, k),
                    Control::Gate | Control::Warmth => {
                        let on = if k == Control::Gate {
                            self.model.gate().enabled
                        } else {
                            self.model.saturation().enabled
                        };
                        self.draw_on_switch(c, f, on, k);
                    }
                    Control::GateState => self.draw_gate_light(c, f),
                    Control::Meter => self.draw_meter(c, f),
                    Control::Bands => self.draw_bands(c, f),
                    Control::Curve => self.draw_curve(c, f),
                    Control::Slider(s) => {
                        let (track, field_rect) = self.slider_parts(f);
                        let on = self.is_enabled(s);
                        let sp = self.spec(s);
                        let frac = Self::track_fraction(&sp, self.value(s));
                        InspectorDraw::slider(c, frac, 0.0, track, on, t);
                        let mut fd = self.field(s);
                        fd.hovering = self.hover == Some(k);
                        fd.draw(c, field_rect, t, self.focused == Some(s), cx);
                        self.put_field(s, fd);
                    }
                }
            }
        }
        if !self.note.is_empty()
            && let Some(last) = self.rows().last()
        {
            c.draw_wrapped(
                &SQL10n::string(&self.note),
                CGRect::new(
                    ControlsGrid::LABEL_X,
                    last.y + last.height + ControlsGrid::GAP,
                    (self.width - ControlsGrid::LABEL_X - ControlsGrid::TRAILING).max(0.0),
                    self.note_height() - 2.0 * ControlsGrid::GAP,
                ),
                fs,
                fs + 4.0,
                t.label3(),
            );
        }
    }

    /// The header's "On" note and its stone switch (`Panels/SectionHeader/Open/Switch`).
    fn draw_on_switch(&self, c: &mut Canvas, f: CGRect, on: bool, k: Control) {
        let t = &self.theme;
        let touch = Touch { hovering: self.hover == Some(k), pressed: self.pressed == Some(k), ..Touch::default() };
        c.stone_switch(f, on, touch, t);
        c.draw_text_in(
            &SQL10n::string(if on { "On" } else { "Off" }),
            CGRect::new(f.min_x() - 6.0 - Self::ON_NOTE_WIDTH, f.min_y(), Self::ON_NOTE_WIDTH, f.height),
            f64::from(type_size::CAPTION),
            t.label3(),
            sq_draw::TextAlign::Right,
            0.0,
            0,
        );
    }

    /// Segment widths of the Track | Effects switch: 7 pt per letter and a 12 pt inset each side.
    fn tab_widths() -> [f64; 2] {
        Tab::ALL.map(|t| t.title().chars().count() as f64 * 7.0 + 24.0)
    }

    /// The Track | Effects switch: a track with two segments.
    fn draw_tab(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        c.stone_segment_track(f, Touch::default(), t);
        let widths = Self::tab_widths();
        for (i, tab) in Tab::ALL.into_iter().enumerate() {
            let r = CGRect::new(f.min_x() + widths[..i].iter().sum::<f64>(), f.min_y(), widths[i], f.height);
            let on = tab == self.tab;
            let touch = Touch { hovering: self.hover == Some(Control::Tab) && !on, ..Touch::default() };
            c.stone_segment(r.inset_by(0.0, 1.0), on, touch, t);
            c.draw_text_in(
                &SQL10n::string(tab.title()),
                r,
                f64::from(type_size::BODY),
                if on { t.label() } else { t.label2() },
                sq_draw::TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    fn eq_plot(&self, f: CGRect) -> CGRect {
        CGRect::new(f.min_x(), f.min_y() + 8.0, f.width, (f.height - 16.0).max(0.0))
    }

    /// The EQ plot: the four band gains over a log frequency axis, the picked band's dot filled.
    fn draw_eq(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let cs = f64::from(type_size::CAPTION);
        let plot = self.eq_plot(f);
        let r = 4.0; // the kit's graph slot: lane fill, radius 4
        c.fill_rounded(plot, r, t.lane());
        c.save_gstate();
        c.clip_to(plot);
        for db in [-6.0, 0.0, 6.0] {
            let a = if db == 0.0 { 0.14 } else { 0.06 };
            c.fill(CGRect::new(plot.min_x(), fx_tab::eq_y(db, plot), plot.width, 1.0), t.ink_fill(a));
        }
        for hz in [100.0, 1_000.0, 10_000.0] {
            c.fill(CGRect::new(fx_tab::eq_x(hz, plot), plot.min_y(), 1.0, plot.height), t.ink_fill(0.06));
        }
        let comp = self.model.compressor();
        let on = comp.eq_on;
        let ink = if on { t.accent() } else { t.label3() };
        let line = fx_tab::eq_curve(&comp.crossovers_hz, &comp.bands, plot);
        c.stroke_polyline(&line, 1.6, ink);
        c.restore_gstate();
        c.stroke_rounded(plot.inset_by(0.5, 0.5), r - 0.5, 1.0, t.field_edge());
        for (hz, label) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
            c.draw_text(
                label,
                CGPoint::new(fx_tab::eq_x(hz, plot) + 3.0, plot.max_y() - cs - 2.0),
                cs,
                t.label3(),
                f64::INFINITY,
                0,
            );
        }
        for (i, b) in comp.bands.iter().take(4).enumerate() {
            let x = fx_tab::eq_x(fx_tab::eq_center_hz(i, &comp.crossovers_hz), plot);
            let d = CGRect::new(x - 7.0, fx_tab::eq_y(b.gain_db, plot) - 7.0, 14.0, 14.0);
            let picked = i == self.selected_eq;
            c.fill_ellipse(d, if picked { ink } else { t.raised() });
            c.draw_text_in(
                &(i + 1).to_string(),
                d,
                9.0,
                if picked { t.panel() } else { t.label() },
                sq_draw::TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    pub fn role_title(&self) -> &'static str {
        let i = self.model.role().and_then(|r| ALL_TAGS.iter().position(|x| *x == r)).map_or(0, |i| i + 1);
        TrackAudioInspectorModel::role_titles()[i]
    }

    pub fn preset_title(&self) -> String {
        self.model
            .selected_preset_id()
            .and_then(|id| self.model.presets().into_iter().find(|p| p.id == id).map(|p| p.name))
            .unwrap_or_else(|| SQL10n::string("Custom"))
    }

    /// The transfer curve with its threshold line, and the gain-reduction meter beside it (the researched compressor panel).
    fn draw_curve(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let cs = f64::from(type_size::CAPTION);
        let (w, h) = Self::CURVE_SIZE;
        let plot = CGRect::new(f.min_x(), f.min_y() + (f.height - h) / 2.0, w.min(f.width), h);
        let r = 4.0;
        c.fill_rounded(plot, r, t.lane());
        for q in [0.25, 0.5, 0.75] {
            c.fill(CGRect::new(plot.min_x(), plot.min_y() + plot.height * q, plot.width, 1.0), t.ink_fill(0.06));
        }
        let b = self.band();
        let on = !self.model.compressor().bypass;
        let [a, z] = compressor_curve::identity_points(plot);
        c.stroke_line(a, z, 1.0, t.ink_fill(0.18));
        let tx = compressor_curve::threshold_x(b.threshold_db, plot);
        let exp = t.token(sq_uikit::redesign_tokens::color::EXP_TEXT);
        c.fill(CGRect::new(tx, plot.min_y() + 2.0, 1.0, plot.height - 4.0), exp.with_alpha(0.8));
        // The label sits left of the line when the line is near the right edge, so it never leaves the plot.
        let label = if b.threshold_db.abs() < 0.5 {
            String::from("0 dB")
        } else {
            format!("\u{2212}{:.0} dB", b.threshold_db.abs())
        };
        let (lx, align) = if tx > plot.min_x() + plot.width * 0.55 {
            (
                CGRect::new(plot.min_x(), plot.min_y() + 2.0, tx - plot.min_x() - 3.0, cs + 2.0),
                sq_draw::TextAlign::Right,
            )
        } else {
            (CGRect::new(tx + 3.0, plot.min_y() + 2.0, plot.max_x() - tx - 3.0, cs + 2.0), sq_draw::TextAlign::Left)
        };
        c.draw_text_in(&label, lx, cs, exp, align, 0.0, 0);
        let makeup = self.model.compressor().makeup_gain_db;
        let line = compressor_curve::curve_points(b.threshold_db, b.ratio, makeup, plot);
        c.stroke_polyline(&line, 1.6, if on { t.accent() } else { t.label3() });
        c.stroke_rounded(plot.inset_by(0.5, 0.5), r - 0.5, 1.0, t.field_edge());
    }

    /// The gain-reduction meter: a thin well, the reduction filling from the top, "GR" above and the number below.
    fn draw_meter(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let cs = f64::from(type_size::CAPTION);
        let on = !self.model.compressor().bypass;
        let exp = t.token(sq_uikit::redesign_tokens::color::EXP_TEXT);
        let label_h = cs + 2.0;
        let well = CGRect::new(f.mid_x() - 4.0, f.min_y() + label_h, 8.0, (f.height - 2.0 * label_h).max(0.0));
        c.fill_rounded(well, 2.0, t.field());
        let fill = compressor_curve::meter_height(if on { self.gain_reduction_db } else { 0.0 }, well.height);
        c.fill(CGRect::new(well.min_x(), well.min_y(), well.width, fill), exp);
        c.draw_text_in(
            "GR",
            CGRect::new(f.min_x(), f.min_y(), f.width, label_h),
            cs,
            t.label3(),
            sq_draw::TextAlign::Center,
            0.0,
            0,
        );
        c.draw_text_in(
            &format!("{:.1}", -self.gain_reduction_db),
            CGRect::new(f.min_x() - 4.0, well.max_y(), f.width + 8.0, label_h),
            cs,
            if self.gain_reduction_db > 0.0 { exp } else { t.label3() },
            sq_draw::TextAlign::Center,
            0.0,
            0,
        );
    }

    /// What the Noise Gate light shows: gray without a live signal (or with the gate off).
    pub fn gate_look(&self) -> GateLook {
        match self.gate_open {
            Some(true) if self.model.gate().enabled => GateLook::Open,
            Some(false) if self.model.gate().enabled => GateLook::Closed,
            _ => GateLook::NoSignal,
        }
    }

    /// The light's words; the short form when the row is narrow.
    pub fn gate_light_text(look: GateLook, long: bool) -> &'static str {
        match (look, long) {
            (GateLook::Open, true) => "Open \u{b7} voice passes",
            (GateLook::Open, false) => "Open",
            (GateLook::Closed, _) => "Closed",
            (GateLook::NoSignal, _) => "No signal",
        }
    }

    fn draw_gate_light(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let look = self.gate_look();
        let dot = if look == GateLook::Open { t.token(tk::GREEN) } else { t.label3() };
        c.fill_ellipse(CGRect::new(f.min_x(), f.mid_y() - 4.0, 8.0, 8.0), dot);
        c.draw_text_in(
            &SQL10n::string(Self::gate_light_text(look, f.width >= Self::GATE_LIGHT_LONG - 1.0)),
            CGRect::new(f.min_x() + 16.0, f.min_y(), (f.width - 16.0).max(0.0), f.height),
            f64::from(type_size::CAPTION),
            t.label3(),
            sq_draw::TextAlign::Left,
            0.0,
            0,
        );
    }

    /// CompressorBandsView.draw: field body, alternate band shading, gain-reduction bars from the top, crossover lines
    /// with their frequency under the strip.
    /// The sunken lane under Noise Reduction: a dashed line at the noise floor Learn Noise measured (dBFS, -80 to 0),
    /// or the one line that says how to get it. There is no live spectrum on the Track tab.
    fn draw_noise_graph(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let r = f64::from(radius::CONTROL);
        c.fill_rounded(f, r, t.field());
        c.stroke_rounded(f.inset_by(0.5, 0.5), r - 0.5, 1.0, t.field_edge());
        let cs = f64::from(type_size::CAPTION);
        match self.learned_floor_db {
            Some(db) => {
                let y = f.min_y() + f.height * (-db / 80.0).clamp(0.0, 1.0);
                let amber = t.yellow();
                let mut x = f.min_x() + 4.0;
                while x < f.max_x() - 4.0 {
                    c.fill(CGRect::new(x, y, (f.max_x() - 4.0 - x).min(4.0), 1.0), amber);
                    x += 7.0;
                }
                let text = SQL10n::format("Noise floor, learned: %@ dB", &[&format!("{db:.0}")]);
                c.draw_text_in(
                    &text,
                    CGRect::new(f.min_x() + 8.0, f.min_y() + 4.0, f.width - 16.0, 14.0),
                    cs,
                    amber,
                    sq_draw::TextAlign::Left,
                    0.0,
                    0,
                );
            }
            None => {
                // Wrapped at word boundaries in the graph's width, the block centered (a long line was cut at the edge).
                let lines =
                    c.wrap(&SQL10n::string("Press Learn Noise on a quiet stretch"), (f.width - 16.0).max(0.0), cs);
                let line_h = (cs * 1.3).ceil();
                let top = f.min_y() + ((f.height - line_h * lines.len() as f64) / 2.0).max(0.0);
                for (i, line) in lines.iter().enumerate() {
                    let row = CGRect::new(f.min_x() + 8.0, top + line_h * i as f64, (f.width - 16.0).max(0.0), line_h);
                    c.draw_text_in(line, row, cs, t.label3(), sq_draw::TextAlign::Center, 0.0, 0);
                }
            }
        }
    }

    fn draw_bands(&self, c: &mut Canvas, f: CGRect) {
        let t = &self.theme;
        let label = 14.0;
        let g = CompressorBandsGeometry::new(f.width);
        let plot = CGRect::new(f.min_x(), f.min_y(), f.width, f.height - label);
        let r = f64::from(radius::CONTROL);
        c.fill_rounded(plot, r, t.field());
        c.save_gstate();
        c.clip_to(plot);
        let ranges = g.band_ranges(&self.model.compressor().crossovers_hz);
        for (i, b) in ranges.iter().enumerate() {
            if i % 2 == 1 {
                c.fill(CGRect::new(plot.min_x() + b.0, plot.min_y(), b.1 - b.0, plot.height), t.ink_fill(0.025));
            }
        }
        let tint = t.accent_tint();
        for b in &ranges {
            // As on the Mac (TrackAudioInspectorView never sets `gainReductionDB`), the track strip has no live reduction
            // feed: the bars stay at 0. The live band meters are in the Multiband setup (`MultibandEditorDraw`).
            let h = plot.height * CompressorBandsGeometry::bar_fraction(0.0);
            let a: f32 = if self.model.compressor().bypass { 0.3 } else { 1.0 };
            c.fill(
                CGRect::new(plot.min_x() + b.0 + 1.0, plot.min_y(), (b.1 - b.0 - 2.0).max(0.0), h),
                tint.with_alpha(tint.a * a),
            );
        }
        if let Some(b) = ranges.get(self.selected_band) {
            c.stroke_rounded(
                CGRect::new(
                    plot.min_x() + b.0 + 0.5,
                    plot.min_y() + 0.5,
                    (b.1 - b.0 - 1.0).max(0.0),
                    plot.height - 1.0,
                ),
                2.0,
                1.5,
                t.accent(),
            );
        }
        // Each band reads like the kit's card: its name and range, and the reduction (a dash while nothing feeds it).
        let cs = f64::from(type_size::CAPTION);
        let xs = &self.model.compressor().crossovers_hz;
        let names = ["Low", "Low mid", "High mid", "High"];
        for (i, b) in ranges.iter().enumerate() {
            let range = match (i.checked_sub(1).and_then(|k| xs.get(k)), xs.get(i)) {
                (None, Some(hi)) => format!("< {}", CompressorBandsGeometry::hz_text(*hi)),
                (Some(lo), Some(hi)) => {
                    format!(
                        "{}\u{2013}{}",
                        CompressorBandsGeometry::hz_text(*lo),
                        CompressorBandsGeometry::hz_text(*hi)
                    )
                }
                (Some(lo), None) => format!("> {}", CompressorBandsGeometry::hz_text(*lo)),
                (None, None) => String::new(),
            };
            let cell = CGRect::new(plot.min_x() + b.0 + 6.0, plot.min_y() + 4.0, (b.1 - b.0 - 12.0).max(0.0), 14.0);
            if cell.width < 24.0 {
                continue;
            }
            c.draw_text_in(names.get(i).copied().unwrap_or(""), cell, cs, t.label(), sq_draw::TextAlign::Left, 0.0, 0);
            c.draw_text_in(&range, offset_by(&cell, 0.0, 14.0), cs, t.label3(), sq_draw::TextAlign::Left, 0.0, 0);
            c.draw_text_in(
                "\u{2014}",
                CGRect::new(cell.min_x(), plot.max_y() - 18.0, cell.width, 14.0),
                cs,
                t.yellow(),
                sq_draw::TextAlign::Left,
                0.0,
                0,
            );
        }
        c.restore_gstate();
        c.stroke_rounded(plot.inset_by(0.5, 0.5), r - 0.5, 1.0, t.field_edge());
        for (i, hz) in self.model.compressor().crossovers_hz.iter().enumerate() {
            let x = plot.min_x() + g.x(*hz).round();
            let active = self.band_drag == Some(i) || self.band_hover == Some(i);
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

    // MARK: Pointer

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        for r in self.rows() {
            if p.y >= r.y && p.y < r.y + r.height {
                for (k, f) in &r.controls {
                    let hit = offset_by(f, 0.0, r.y);
                    // A group head's switch takes its "On" label too; sliders keep their own height inside a tall block.
                    let toggle = matches!(
                        k,
                        Control::Gate | Control::Eq | Control::Warmth | Control::Bypass | Control::CleanVoice
                    );
                    let wide = if toggle && r.header {
                        CGRect::new(hit.min_x() - 50.0, r.y, hit.width + 50.0 + ControlsGrid::TRAILING, r.height)
                    } else if matches!(
                        k,
                        Control::Slider(_) | Control::Meter | Control::GateState | Control::NoiseGraph
                    ) {
                        hit
                    } else {
                        CGRect::new(hit.min_x(), r.y, hit.width, r.height)
                    };
                    if wide.contains(p) {
                        return Some(*k);
                    }
                }
            }
        }
        None
    }

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.band_drag.is_some()
            || self.eq_drag.is_some()
            || self.slider_drag.is_some()
            || self.field_press.is_some()
        {
            return;
        }
        self.hover = p.and_then(|p| self.control_at(p));
        self.band_hover = None;
        if let Some(p) = p
            && self.hover == Some(Control::Bands)
            && let Some(f) = self.frame(Control::Bands)
        {
            self.band_hover = CompressorBandsGeometry::new(f.width)
                .handle_index(p.x - f.min_x(), &self.model.compressor().crossovers_hz);
        }
    }

    pub fn mouse_down(&mut self, p: CGPoint, click_count: Option<i64>, cx: &mut UiCx) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let k = self.control_at(p);
        if let Some(s) = self.focused
            && k != Some(Control::Slider(s))
        {
            self.resign_focus(cx);
        }
        let Some(k) = k else { return };
        self.pressed = Some(k);
        match k {
            Control::Preset | Control::Loudness => {
                let Some(f) = self.frame(k) else { return };
                let items = match k {
                    Control::Loudness => self.loudness_menu(),
                    _ => self.preset_menu(),
                };
                self.menus.push(MenuRequest { items, anchor: f });
                self.pressed = None;
            }
            Control::Bypass
            | Control::Eq
            | Control::Gate
            | Control::Warmth
            | Control::CleanVoice
            | Control::LearnNoise
            | Control::Tab
            | Control::RoleSeg(_)
            | Control::EqBand(_) => {}
            Control::EqGraph => {
                if let Some(f) = self.frame(Control::EqGraph) {
                    self.selected_eq =
                        fx_tab::nearest_band(p.x, &self.model.compressor().crossovers_hz, self.eq_plot(f));
                    self.eq_drag = Some(self.selected_eq);
                    self.model.begin_change();
                    self.set_eq_gain_from_y(p.y);
                }
            }
            Control::Bands => {
                let Some(f) = self.frame(Control::Bands) else { return };
                if let Some(i) = CompressorBandsGeometry::new(f.width)
                    .handle_index(p.x - f.min_x(), &self.model.compressor().crossovers_hz)
                {
                    self.band_drag = Some(i);
                    self.model.begin_change();
                } else if let Some(i) = CompressorBandsGeometry::new(f.width)
                    .band_ranges(&self.model.compressor().crossovers_hz)
                    .iter()
                    .position(|b| p.x - f.min_x() >= b.0 && p.x - f.min_x() < b.1)
                {
                    self.selected_band = i;
                }
            }
            Control::Curve | Control::Meter | Control::GateState | Control::NoiseGraph => {}
            Control::Slider(s) => {
                let Some(f) = self.frame(k) else { return };
                if !self.is_enabled(s) {
                    return;
                }
                let (track, field_rect) = self.slider_parts(f);
                if p.x >= field_rect.min_x() {
                    let mut fd = self.field(s);
                    let ev = fd.mouse_down(p.x as f32, n);
                    self.apply(ev, s);
                    self.put_field(s, fd);
                    self.field_press = Some(s);
                    self.focused = Some(s);
                } else {
                    self.slider_drag = Some(s);
                    self.model.begin_change();
                    self.set_from_slider(s, p.x, track);
                }
            }
        }
    }

    /// Dragging a band's dot sets that band's gain from the pointer height.
    fn set_eq_gain_from_y(&mut self, y: f64) {
        let (Some(i), Some(f)) = (self.eq_drag, self.frame(Control::EqGraph)) else { return };
        let db = fx_tab::eq_db_at(y, self.eq_plot(f));
        self.model.set_band(i, |b| b.gain_db = db);
    }

    pub fn mouse_dragged(&mut self, p: CGPoint, modifiers: InputModifiers, cx: &mut UiCx) {
        if self.eq_drag.is_some() {
            self.set_eq_gain_from_y(p.y);
        } else if let Some(i) = self.band_drag
            && let Some(f) = self.frame(Control::Bands)
        {
            let hz = CompressorBandsGeometry::new(f.width).dragged_hz(
                i,
                p.x - f.min_x(),
                &self.model.compressor().crossovers_hz,
            );
            self.model.set_crossover(i, hz);
        } else if let Some(s) = self.slider_drag
            && let Some(f) = self.frame(Control::Slider(s))
        {
            let track = self.slider_parts(f).0;
            self.set_from_slider(s, p.x, track);
        } else if let Some(s) = self.field_press {
            let mut fd = self.field(s);
            let ev = fd.mouse_dragged(p.x as f32, modifiers, self.theme.scale, cx);
            self.apply(ev, s);
            self.put_field(s, fd);
        }
    }

    pub fn mouse_up(&mut self, p: CGPoint, cx: &mut UiCx) {
        self.mouse_up_inner(p, cx);
        self.pressed = None;
        self.mouse_moved(Some(p));
    }

    fn mouse_up_inner(&mut self, p: CGPoint, cx: &mut UiCx) {
        if self.eq_drag.take().is_some() {
            self.model.end_change();
            return;
        }
        if self.band_drag.is_some() {
            self.band_drag = None;
            self.model.end_change();
            return;
        }
        if self.slider_drag.is_some() {
            self.slider_drag = None;
            self.model.end_change();
            return;
        }
        if let Some(s) = self.field_press {
            let mut fd = self.field(s);
            let ev = fd.mouse_up(cx);
            self.apply(ev, s);
            self.put_field(s, fd);
            self.field_press = None;
            return;
        }
        let Some(k) = self.pressed else { return };
        if self.control_at(p) != Some(k) {
            return;
        }
        match k {
            Control::Tab => {
                if let Some(f) = self.frame(Control::Tab) {
                    self.set_tab(if p.x < f.min_x() + Self::tab_widths()[0] { Tab::Track } else { Tab::Effects });
                }
            }
            Control::EqBand(i) => self.selected_eq = i.min(3),
            Control::RoleSeg(i) => {
                // The active segment is a toggle: a second click clears the role (the old menu's None).
                let role = ALL_TAGS[i.min(2)];
                self.model.set_role(if self.model.role_is_active(role) { None } else { Some(role) });
            }
            Control::Bypass => {
                let b = self.model.compressor().bypass;
                self.model.set_bypass(!b);
            }
            Control::Eq => {
                let on = self.model.compressor().eq_on;
                self.model.set_eq_enabled(!on);
            }
            Control::Gate => {
                let on = self.model.gate().enabled;
                self.model.set_gate_enabled(!on);
            }
            Control::Warmth => {
                let on = self.model.saturation().enabled;
                self.model.set_warmth_enabled(!on);
            }
            Control::CleanVoice => {
                let on = self.model.clean_voice_on();
                self.model.set_clean_voice(!on);
            }
            Control::LearnNoise => self.learn_noise_requested = true,
            _ => {}
        }
    }

    fn set_from_slider(&mut self, s: Slider, x: f64, track: CGRect) {
        let sp = self.spec(s);
        let (lo, hi) = (*sp.range.start(), *sp.range.end());
        let raw = sq_draw::inspector::slider_scale::value(
            InspectorDraw::slider_fraction(x, track),
            lo,
            hi,
            sq_draw::inspector::slider_scale::is_logarithmic(sp.unit, lo, hi),
        );
        self.set(s, (raw / sp.step).round() * sp.step);
    }

    /// Where `value` sits on the track of `sp` (0...1): a frequency slider reads on a log scale.
    fn track_fraction(sp: &SliderSpec, value: f64) -> f64 {
        let (lo, hi) = (*sp.range.start(), *sp.range.end());
        sq_draw::inspector::slider_scale::fraction(
            value,
            lo,
            hi,
            sq_draw::inspector::slider_scale::is_logarithmic(sp.unit, lo, hi),
        )
    }

    /// Keys for the focused value field (typing, arrows, Enter, Esc); false when nothing is focused.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> bool {
        let Some(s) = self.focused else { return false };
        let mut fd = self.field(s);
        if k == TAB {
            let ev = fd.resign_focus(cx);
            self.apply(ev, s);
            self.put_field(s, fd);
            self.move_focus(s, modifiers.contains(InputModifiers::SHIFT));
            return true;
        }
        let (ev, used) = fd.key_used(k, modifiers, cx.now, cx);
        let ended = !fd.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
        self.apply(ev, s);
        self.put_field(s, fd);
        if ended {
            self.focused = None;
        }
        used
    }

    /// Tab order: the enabled value fields top to bottom.
    fn move_focus(&mut self, s: Slider, backward: bool) {
        let shown: Vec<Control> = self.rows().iter().flat_map(|r| r.controls.iter().map(|c| c.0)).collect();
        let order: Vec<Slider> = Slider::ALL
            .iter()
            .copied()
            .filter(|x| self.is_enabled(*x) && shown.contains(&Control::Slider(*x)))
            .collect();
        let Some(i) = order.iter().position(|x| *x == s).filter(|_| !order.is_empty()) else {
            self.focused = None;
            return;
        };
        self.focused = Some(order[(i + if backward { order.len() - 1 } else { 1 }) % order.len()]);
    }

    pub fn resign_focus(&mut self, cx: &mut UiCx) {
        let Some(s) = self.focused else { return };
        let mut fd = self.field(s);
        let ev = fd.resign_focus(cx);
        self.apply(ev, s);
        self.put_field(s, fd);
        self.focused = None;
    }

    /// Per frame: ends arrow / wheel step bursts (one undo step each).
    pub fn tick(&mut self, now: f64) {
        for s in Slider::ALL {
            let Some(mut fd) = self.fields.borrow_mut().remove(&s) else { continue };
            let ev = fd.tick(now);
            self.apply(ev, s);
            self.put_field(s, fd);
        }
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.control_at(p) {
            Some(Control::RoleSeg(_)) => Some(SQL10n::string(
                "Dialogue, Music or Effects: loads a voiced EQ, compressor and level for this track",
            )),
            Some(Control::Eq) => Some(SQL10n::string("EQ On")),
            Some(Control::Gate) => Some(SQL10n::string("Noise gate")),
            Some(Control::Warmth) => Some(SQL10n::string("Warmth")),
            Some(Control::Bypass) => Some(SQL10n::string("Compressor On")),
            Some(Control::CleanVoice) => Some(SQL10n::string("Clean Voice: takes background noise out of speech")),
            Some(Control::LearnNoise) => Some(SQL10n::string(
                "Listens to the playhead region and sets the gate and denoiser from its noise floor",
            )),
            Some(Control::Slider(s)) => self.spec(s).help.map(SQL10n::string),
            _ => None,
        }
    }

    // MARK: Menus

    pub fn role_menu(&self) -> Vec<SQMenuItem> {
        let current = self.role_title();
        TrackAudioInspectorModel::role_titles()
            .into_iter()
            .enumerate()
            .map(|(i, title)| {
                let mut row = SQMenuItem::new(title);
                row.is_checked = title == current;
                let sink = self.sink.clone();
                let role = if i == 0 { None } else { Some(ALL_TAGS[i - 1]) };
                row.action = Some(std::rc::Rc::new(move || sink.push(TrackAudioCommand::SetRole(role))));
                row
            })
            .collect()
    }

    pub fn preset_menu(&self) -> Vec<SQMenuItem> {
        let presets = self.model.presets();
        let selected = self.model.selected_preset_id().map(str::to_string);
        let mut items: Vec<SQMenuItem> = presets
            .iter()
            .map(|p| {
                let mut row = SQMenuItem::new(&p.name);
                row.is_checked = Some(&p.id) == selected.as_ref();
                let sink = self.sink.clone();
                let id = p.id.clone();
                row.action = Some(std::rc::Rc::new(move || sink.push(TrackAudioCommand::SelectPreset(id.clone()))));
                row
            })
            .collect();
        if selected.as_ref().is_none_or(|id| !presets.iter().any(|p| &p.id == id)) {
            let mut row = SQMenuItem::new("Custom");
            row.is_checked = true;
            let sink = self.sink.clone();
            row.action = Some(std::rc::Rc::new(move || sink.push(TrackAudioCommand::Nothing)));
            items.push(row);
        }
        items
    }

    /// Runs the rows the user picked in a menu this block asked for (the host calls it when the menu closes).
    pub fn run_menu_commands(&mut self) {
        for cmd in self.sink.drain() {
            match cmd {
                TrackAudioCommand::SetRole(r) => self.model.set_role(r),
                TrackAudioCommand::SetLoudness(v) => self.model.set_loudness_target(v),
                TrackAudioCommand::SelectPreset(id) => self.model.select_preset(&id),
                TrackAudioCommand::Nothing => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_audiofx::presets::PresetLibrary;
    use sq_core_time::SequentialIds;

    use super::super::track_audio_inspector_model::TrackAudioEvent;

    fn block() -> TrackAudioDraw {
        let mut b = TrackAudioDraw::new(TrackAudioInspectorModel::new(
            PresetLibrary::new(),
            None,
            None,
            Box::new(SequentialIds::default()),
        ));
        b.width = 320.0;
        b
    }

    fn pt(x: f64, y: f64) -> CGPoint {
        CGPoint::new(x, y)
    }

    #[test]
    fn the_noise_hint_wraps_at_word_boundaries_inside_the_graph() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let f = b.frame(Control::NoiseGraph).expect("noise graph");
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let c = Canvas::with_size(400.0, 700.0, Some(&atlas), 1.0);
        let cs = f64::from(type_size::CAPTION);
        let lines = c.wrap("Press Learn Noise on a quiet stretch", f.width - 16.0, cs);
        assert!(lines.len() >= 2, "{lines:?} at {} pt", f.width);
        assert!(lines.iter().all(|l| c.size_of(l, cs, 0).width <= f.width - 16.0 && !l.starts_with(' ')));
        assert_eq!(lines.join(" "), "Press Learn Noise on a quiet stretch", "nothing is lost");
        assert!(lines.len() as f64 * (cs * 1.3).ceil() <= f.height, "the lines fit the graph's height");
    }

    #[test]
    fn the_compressor_sliders_edit_the_selected_band_and_the_makeup() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.set(Slider::CompThreshold, -33.0);
        b.set(Slider::CompRatio, 4.0);
        assert_eq!(b.model.compressor().bands[0].threshold_db, -33.0);
        assert_eq!(b.model.compressor().bands[0].ratio, 4.0);
        b.selected_band = 1;
        assert_ne!(b.value(Slider::CompThreshold), -33.0, "another band has its own values");
        b.set(Slider::CompRelease, 250.0);
        assert_eq!(b.model.compressor().bands[1].release_ms, 250.0);
        b.set(Slider::Makeup, 3.0);
        assert_eq!(b.value(Slider::Makeup), 3.0);
        assert_eq!(b.model.compressor().bands[0].release_ms, b.value_of_band(0).release_ms);
    }

    #[test]
    fn clicking_a_band_in_the_strip_selects_it_and_the_curve_draws() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let mut cx = UiCx::new();
        let f = b.frame(Control::Bands).expect("strip");
        let g = CompressorBandsGeometry::new(f.width);
        let (lo, hi) = g.band_ranges(&b.model.compressor().crossovers_hz)[2];
        let x = f.min_x() + (lo + hi) / 2.0;
        b.mouse_down(pt(x, f.min_y() + 20.0), Some(1), &mut cx);
        b.mouse_up(pt(x, f.min_y() + 20.0), &mut cx);
        assert_eq!(b.selected_band(), 2);
        b.set_gain_reduction_db(6.0);
        let mut c = Canvas::with_size(320.0, b.height() as f32, None, 1.0);
        b.draw(&mut c, &mut UiCx::new());
        assert!(!c.list.quads().is_empty());
    }

    #[test]
    fn the_track_tab_has_one_compressor_block_without_the_crossover_strip() {
        let b = block();
        assert_eq!(b.tab(), Tab::Track);
        assert!(b.frame(Control::Bands).is_none(), "the strip belongs to the Multiband group");
        let heads: Vec<&str> = b.rows().iter().filter(|r| r.header).filter_map(|r| r.label).collect();
        assert_eq!(heads, ["Compressor"]);
        for s in [Slider::CompThreshold, Slider::CompRatio, Slider::CompAttack, Slider::CompRelease, Slider::Makeup] {
            assert!(b.frame(Control::Slider(s)).is_some());
        }
        let mut c = Canvas::with_size(320.0, b.height() as f32, None, 1.0);
        b.draw(&mut c, &mut UiCx::new());
        assert!(!c.list.quads().is_empty());
    }

    #[test]
    fn a_wide_panel_puts_curve_sliders_and_meter_in_one_block() {
        let mut b = block();
        b.width = 614.0;
        b.model.set_bypass(false);
        let curve = b.frame(Control::Curve).expect("curve");
        let thr = b.frame(Control::Slider(Slider::CompThreshold)).expect("threshold");
        let makeup = b.frame(Control::Slider(Slider::Makeup)).expect("makeup");
        let meter = b.frame(Control::Meter).expect("meter");
        assert!(thr.min_x() > curve.max_x() && meter.min_x() > thr.max_x(), "left to right");
        assert!(makeup.min_y() > thr.min_y() && makeup.min_y() < curve.min_y() + 5.0 * ControlsGrid::ROW_HEIGHT);
        // The sliders still take pointer input inside the tall block.
        let mut cx = UiCx::new();
        let track = b.slider_parts(makeup).0;
        b.mouse_down(pt(track.max_x() - 1.0, makeup.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(track.max_x() - 1.0, makeup.mid_y()), &mut cx);
        assert!(b.value(Slider::Makeup) > 10.0);
    }

    #[test]
    fn a_slider_track_stays_short_in_a_wide_panel_with_its_field_beside_it() {
        let b = block();
        let (track, field) = b.slider_parts(CGRect::new(10.0, 0.0, 900.0, 22.0));
        assert_eq!(track.width, TrackAudioDraw::MAX_TRACK_WIDTH);
        assert_eq!(field.min_x(), track.max_x() + TrackAudioDraw::SLIDER_GAP);
        let (narrow, field) = b.slider_parts(CGRect::new(10.0, 0.0, 200.0, 22.0));
        assert_eq!(field.max_x(), 210.0);
        assert!(narrow.width > 100.0 && narrow.max_x() < field.min_x());
    }

    #[test]
    fn track_compressor_sliders_edit_every_band_as_one_change() {
        let mut b = block();
        b.model.take_events();
        b.set(Slider::CompThreshold, -33.0);
        assert!(b.model.compressor().bands.iter().all(|x| x.threshold_db == -33.0));
        let ev = b.model.take_events();
        let begins = ev.iter().filter(|e| matches!(e, TrackAudioEvent::BeginChange)).count();
        assert_eq!(begins, 1, "one undo step");
        b.set_tab(Tab::Effects);
        b.selected_band = 2;
        b.set(Slider::CompThreshold, -10.0);
        assert_eq!(b.model.compressor().bands[2].threshold_db, -10.0);
        assert_eq!(b.model.compressor().bands[1].threshold_db, -33.0, "the Multiband group stays per band");
    }

    #[test]
    fn every_group_head_is_a_right_aligned_switch() {
        let mut b = block();
        let mut cx = UiCx::new();
        let f = b.frame(Control::Bypass).expect("compressor switch");
        assert!(f.max_x() > b.width - 40.0, "at the right end");
        assert!(b.model.compressor().bypass, "a new track starts with the compressor off");
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(f.mid_x(), f.mid_y()), &mut cx);
        assert!(!b.model.compressor().bypass, "the On switch clears the bypass flag");
        b.set_tab(Tab::Effects);
        for k in [Control::Eq, Control::Gate, Control::CleanVoice, Control::Warmth, Control::Bypass] {
            let f = b.frame(k).expect("switch");
            assert!(f.max_x() > b.width - 40.0);
        }
    }

    #[test]
    fn the_eq_has_a_width_row_that_moves_the_band_edge() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.selected_eq = 1;
        assert!(b.frame(Control::Slider(Slider::EqWidth)).is_some());
        let before = b.value(Slider::EqWidth);
        b.set(Slider::EqWidth, before + 2.0);
        assert!((b.value(Slider::EqWidth) - (before + 2.0)).abs() < 0.05, "{}", b.value(Slider::EqWidth));
    }

    /// Types `text` into the value field of `s` the way a user does: a click opens the field, a second press selects the
    /// value, then the characters and Enter.
    fn type_into(b: &mut TrackAudioDraw, s: Slider, text: &str) {
        let mut cx = UiCx::new();
        let f = b.frame(Control::Slider(s)).expect("the row is shown");
        let p = pt(b.slider_parts(f).1.mid_x(), f.mid_y());
        for n in [1, 2] {
            b.mouse_down(p, Some(n), &mut cx);
            b.mouse_up(p, &mut cx);
        }
        for ch in text.chars() {
            let k = if ch == '-' { InputKey::Minus } else { InputKey::Character(ch) };
            assert!(b.key(k, InputModifiers::NONE, &mut cx), "the open field takes {ch:?}");
        }
        assert!(b.key(InputKey::Enter, InputModifiers::NONE, &mut cx));
    }

    #[test]
    fn typed_eq_values_take_on_every_band_while_the_compressor_is_off() {
        // Windows round 4: the EQ fields were greyed while the compressor was off, so a typed value was dropped silently.
        for (band, freq, gain) in [(0, 90.0, 6.0), (1, 200.0, 12.0), (2, 2500.0, -9.0), (3, 5000.0, 3.0)] {
            let mut b = block();
            assert!(b.model.compressor().bypass, "a new track starts with the compressor off");
            b.set_tab(Tab::Effects);
            b.selected_eq = band;
            type_into(&mut b, Slider::EqFrequency, &freq.to_string());
            type_into(&mut b, Slider::EqGain, &gain.to_string());
            assert!(
                (b.value(Slider::EqFrequency) - freq).abs() < freq * 0.005,
                "band {band}: {}",
                b.value(Slider::EqFrequency)
            );
            assert_eq!(b.model.compressor().bands[band].gain_db, gain, "band {band} gain");
            let x = &b.model.compressor().crossovers_hz;
            assert!(x.windows(2).all(|w| w[1] >= w[0] * 1.19), "crossovers stay ordered and apart: {x:?}");
        }
    }

    #[test]
    fn every_value_field_takes_a_typed_value() {
        let mut shown = 0;
        for s in Slider::ALL {
            let mut b = block();
            b.model.set_bypass(false);
            b.model.set_gate_enabled(true);
            b.model.set_warmth_enabled(true);
            let Some(tab) = [Tab::Track, Tab::Effects].into_iter().find(|t| {
                b.set_tab(*t);
                b.frame(Control::Slider(s)).is_some()
            }) else {
                continue;
            };
            b.set_tab(tab);
            let sp = b.spec(s);
            let (lo, hi) = (*sp.range.start(), *sp.range.end());
            // The EQ frequency has the neighbors' crossovers as its limits: 100 Hz fits the first shelf.
            let want = if s == Slider::EqFrequency { 100.0 } else { (lo + (hi - lo) * 0.37).round() };
            type_into(&mut b, s, &format!("{want}"));
            assert!((b.value(s) - want).abs() <= sp.step.max(0.5), "{s:?}: typed {want}, shows {}", b.value(s));
            shown += 1;
        }
        assert!(shown >= 14, "the rows of both tabs were reached, got {shown}");
    }

    /// The EQ frequency track is logarithmic: 120, 200 and 300 Hz used to sit on the same pixels of a linear 20 Hz to 20 kHz track.
    #[test]
    fn the_eq_frequency_track_is_logarithmic() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.selected_eq = 1;
        let sp = b.spec(Slider::EqFrequency);
        let (a, m, c) = (
            TrackAudioDraw::track_fraction(&sp, 120.0),
            TrackAudioDraw::track_fraction(&sp, 200.0),
            TrackAudioDraw::track_fraction(&sp, 300.0),
        );
        assert!(m - a > 0.07 && c - m > 0.05, "120, 200 and 300 Hz sit apart on the track: {a} {m} {c}");
        let row = b.frame(Control::Slider(Slider::EqFrequency)).expect("the EQ frequency row");
        let track = b.slider_parts(row).0;
        let knob = sq_draw::InspectorTokens::SLIDER_KNOB;
        let x_at = |f: f64| track.min_x() + knob / 2.0 + f * (track.width - knob);
        b.set_from_slider(Slider::EqFrequency, x_at(m), track);
        let got = b.value(Slider::EqFrequency);
        assert!((got - 200.0).abs() < 8.0, "a press at the track position of 200 Hz sets {got} Hz");
    }

    #[test]
    fn a_bell_frequency_is_its_middle_and_a_bell_width_keeps_the_middle() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.selected_eq = 1;
        let q = b.value(Slider::EqWidth);
        b.set(Slider::EqFrequency, 200.0);
        let xo = b.model.compressor().crossovers_hz.clone();
        assert!(
            (fx_tab::eq_center_hz(1, &xo) - 200.0).abs() < 0.5,
            "the band is centered on the typed frequency: {xo:?}"
        );
        assert!((b.value(Slider::EqWidth) - q).abs() < 0.02, "moving the band keeps its width");
        b.set(Slider::EqWidth, q + 2.0);
        assert!((b.value(Slider::EqFrequency) - 200.0).abs() < 0.5, "a width change keeps the middle");
        assert!((b.value(Slider::EqWidth) - (q + 2.0)).abs() < 0.1);
        // The dot sits where the field says.
        let plot = CGRect::new(0.0, 0.0, 400.0, 100.0);
        let xo = &b.model.compressor().crossovers_hz;
        assert!((fx_tab::eq_x(fx_tab::eq_center_hz(1, xo), plot) - fx_tab::eq_x(200.0, plot)).abs() < 0.5);
    }

    #[test]
    fn a_shelf_frequency_is_its_corner() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.selected_eq = 0;
        b.set(Slider::EqFrequency, 150.0);
        assert_eq!(b.model.compressor().crossovers_hz[0], 150.0);
        b.selected_eq = 3;
        b.set(Slider::EqFrequency, 6000.0);
        assert_eq!(b.model.compressor().crossovers_hz[2], 6000.0);
    }

    #[test]
    fn a_bell_dragged_to_any_frequency_keeps_the_crossovers_ordered() {
        for band in [1, 2] {
            for hz in [20.0, 35.0, 120.0, 700.0, 3000.0, 9000.0, 20_000.0] {
                let mut b = block();
                b.set_tab(Tab::Effects);
                b.selected_eq = band;
                b.set(Slider::EqFrequency, hz);
                let x = &b.model.compressor().crossovers_hz;
                assert!(x[0] >= 20.0 && x[2] <= 20_000.0, "band {band} at {hz}: {x:?}");
                assert!(x.windows(2).all(|w| w[1] >= w[0] * 1.19), "band {band} at {hz}: {x:?}");
            }
        }
    }

    #[test]
    fn the_gate_light_is_always_there_and_gray_without_signal() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let light = b.frame(Control::GateState).expect("light next to the threshold");
        let thr = b.frame(Control::Slider(Slider::Gate)).expect("threshold");
        assert!(light.min_x() >= thr.max_x());
        b.model.set_gate_enabled(true);
        b.set_gate_open(None);
        assert_eq!(b.gate_look(), GateLook::NoSignal);
        b.set_gate_open(Some(true));
        assert_eq!(b.gate_look(), GateLook::Open);
        b.set_gate_open(Some(false));
        assert_eq!(b.gate_look(), GateLook::Closed);
        b.model.set_gate_enabled(false);
        assert_eq!(b.gate_look(), GateLook::NoSignal, "a gate that is off shows no light");
        assert_eq!(TrackAudioDraw::gate_light_text(GateLook::Open, true), "Open \u{b7} voice passes");
    }

    #[test]
    fn gate_checkbox_enables_its_sliders_and_slider_drag_is_one_change() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let mut cx = UiCx::new();
        assert!(!b.is_enabled(Slider::Attack));
        let Some(check) = b.frame(Control::Gate) else { panic!("no gate frame") };
        b.mouse_down(pt(check.mid_x(), check.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(check.mid_x(), check.mid_y()), &mut cx);
        assert!(b.model.gate().enabled && b.is_enabled(Slider::Attack));
        let Some(f) = b.frame(Control::Slider(Slider::Denoise)) else { panic!("no slider frame") };
        let track = b.slider_parts(f).0;
        b.model.take_events();
        b.mouse_down(pt(track.min_x() + 1.0, track.mid_y()), Some(1), &mut cx);
        b.mouse_dragged(pt(track.mid_x(), track.mid_y()), InputModifiers::NONE, &mut cx);
        b.mouse_dragged(pt(track.max_x(), track.mid_y()), InputModifiers::NONE, &mut cx);
        b.mouse_up(pt(track.max_x(), track.mid_y()), &mut cx);
        assert_eq!(b.model.noise_reduction_percent(), 100.0);
        let changes = b.model.take_events().iter().filter(|e| **e == TrackAudioEvent::BeginChange).count();
        assert_eq!(changes, 1);
    }

    #[test]
    fn crossover_drag_moves_the_band_edge() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let mut cx = UiCx::new();
        let Some(f) = b.frame(Control::Bands) else { panic!("no bands frame") };
        let g = CompressorBandsGeometry::new(f.width);
        let before = b.model.compressor().crossovers_hz[1];
        let x = f.min_x() + g.x(before);
        b.mouse_down(pt(x, f.mid_y()), Some(1), &mut cx);
        b.mouse_dragged(pt(x + 20.0, f.mid_y()), InputModifiers::NONE, &mut cx);
        b.mouse_up(pt(x + 20.0, f.mid_y()), &mut cx);
        assert!(b.model.compressor().crossovers_hz[1] > before);
    }

    #[test]
    fn the_role_segments_set_and_clear_the_role() {
        let mut b = block();
        let mut cx = UiCx::new();
        assert_eq!(
            b.role_menu().len(),
            TrackAudioInspectorModel::role_titles().len(),
            "the menu still lists the roles"
        );
        let Some(seg) = b.frame(Control::RoleSeg(0)) else { panic!("no role segment") };
        b.mouse_down(pt(seg.mid_x(), seg.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(seg.mid_x(), seg.mid_y()), &mut cx);
        assert_eq!(b.model.role(), Some(ALL_TAGS[0]));
        b.mouse_down(pt(seg.mid_x(), seg.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(seg.mid_x(), seg.mid_y()), &mut cx);
        assert_eq!(b.model.role(), None, "the active segment clears the role");
        b.set_tab(Tab::Effects);
        let Some(typed) = b.frame(Control::Slider(Slider::Mix)) else { panic!("no mix frame") };
        assert!(b.help(pt(typed.mid_x(), typed.mid_y())).is_some_and(|h| h.starts_with("Warmth mix")));
    }

    /// A narrow Controls panel (the 640 wide window) cut the Role words to "Dial… Mu… Effe…": the segments then take
    /// their own row under the label, each wide enough for its word, and still set the role.
    #[test]
    fn the_role_segments_keep_their_words_in_a_narrow_panel() {
        // 226: the Controls panel of the 640 wide window.
        for width in [226.0, 240.0, 260.0, 300.0, 320.0, 420.0] {
            let mut b = block();
            b.width = width;
            let segs: Vec<CGRect> = (0..3).filter_map(|i| b.frame(Control::RoleSeg(i))).collect();
            assert_eq!(segs.len(), 3, "{width}");
            assert!(segs.iter().all(|f| f.width >= TrackAudioDraw::ROLE_SEG_MIN), "{width}: {segs:?}");
            assert!(segs[2].max_x() <= width - ControlsGrid::TRAILING + 0.5, "{width}: past the panel");
            let mut cx = UiCx::new();
            let s = segs[1];
            b.mouse_down(pt(s.mid_x(), s.mid_y()), Some(1), &mut cx);
            b.mouse_up(pt(s.mid_x(), s.mid_y()), &mut cx);
            assert_eq!(b.model.role(), Some(ALL_TAGS[1]), "{width}");
        }
    }

    #[test]
    fn clean_voice_switch_drives_the_denoiser_and_remembers_the_amount() {
        let mut b = block();
        let mut cx = UiCx::new();
        assert!(!b.model.clean_voice_on());
        let f = b.frame(Control::CleanVoice).expect("clean voice switch");
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(f.mid_x(), f.mid_y()), &mut cx);
        assert!(b.model.clean_voice_on());
        assert_eq!(b.value(Slider::Denoise), 60.0);
        b.model.set_noise_reduction_percent(35.0);
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(f.mid_x(), f.mid_y()), &mut cx);
        assert_eq!(b.value(Slider::Denoise), 0.0);
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(f.mid_x(), f.mid_y()), &mut cx);
        assert_eq!(b.value(Slider::Denoise), 35.0, "the switch brings back the last amount");
    }

    #[test]
    fn loudness_row_shows_the_role_target_until_a_choice_overrides_it() {
        let mut b = block();
        assert_eq!(b.loudness_text(), "Web \u{b7} \u{2212}14 LUFS", "no role: the dialogue default");
        b.model.set_role(Some(AudioTag::Music));
        assert_eq!(b.loudness_text(), "Music bed \u{b7} \u{2212}20 LUFS");
        b.model.set_loudness_target(Some(-23.0));
        assert_eq!(b.loudness_text(), "Broadcast \u{b7} \u{2212}23 LUFS");
        assert_eq!(b.model.take_events().last(), Some(&TrackAudioEvent::LoudnessChange(Some(-23.0))));
        b.model.set_loudness_target(None);
        assert_eq!(b.loudness_text(), "Music bed \u{b7} \u{2212}20 LUFS", "None goes back to the role default");
    }

    #[test]
    fn the_loudness_dropdown_lists_the_targets_and_a_pick_sets_one() {
        let mut b = block();
        let Some(f) = b.frame(Control::Loudness) else { panic!("no loudness frame") };
        let mut cx = UiCx::new();
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        let items = b.menus.last().map(|m| m.items.clone()).unwrap_or_default();
        let titles: Vec<String> = items.iter().map(|i| i.title.clone()).collect();
        assert_eq!(titles[0], "Role default");
        assert_eq!(titles[1], "Web \u{b7} \u{2212}14 LUFS");
        assert!(items[0].is_checked, "no choice yet: the role default is checked");
        if let Some(action) = &items[4].action {
            action();
        }
        b.run_menu_commands();
        assert_eq!(b.model.loudness_target(), Some(-23.0));
    }

    #[test]
    fn the_eq_head_has_an_on_switch_that_clicks_the_flag() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let mut cx = UiCx::new();
        assert!(b.model.compressor().eq_on);
        let f = b.frame(Control::Eq).expect("eq switch");
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(f.mid_x(), f.mid_y()), &mut cx);
        assert!(!b.model.compressor().eq_on);
    }

    #[test]
    fn learn_noise_is_a_button_in_the_amount_row_and_the_lane_remembers_the_floor() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let learn = b.frame(Control::LearnNoise).expect("learn noise");
        let amount = b.frame(Control::Slider(Slider::Denoise)).expect("amount");
        let lane = b.frame(Control::NoiseGraph).expect("noise lane");
        assert!((learn.mid_y() - amount.mid_y()).abs() < 1.0, "one row");
        assert!(learn.min_x() >= amount.max_x() - 1.0 || learn.min_x() > amount.min_x() + 100.0);
        assert!(lane.max_y() <= amount.min_y() + 1.0, "the lane sits above the Amount row");
        assert!(b.learned_floor_db.is_none());
        let quiet: Vec<f32> = (0..48_000).map(|i| if i % 2 == 0 { 0.01 } else { -0.01 }).collect();
        assert!(b.learn_noise(&quiet, 48_000.0));
        assert!(b.learned_floor_db.is_some());
    }

    #[test]
    fn the_preset_menu_lives_on_the_effects_tab_not_on_the_track_tab() {
        let mut b = block();
        assert!(b.frame(Control::Preset).is_none());
        b.set_tab(Tab::Effects);
        assert!(b.frame(Control::Preset).is_some());
    }

    #[test]
    fn learn_noise_sets_the_gate_from_the_measured_floor() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let mut cx = UiCx::new();
        let f = b.frame(Control::LearnNoise).expect("learn noise");
        b.mouse_down(pt(f.mid_x(), f.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(f.mid_x(), f.mid_y()), &mut cx);
        assert!(b.learn_noise_requested);
        assert!(!b.learn_noise(&[0.0; 10], 48_000.0), "too short to measure");
        let quiet: Vec<f32> = (0..48_000).map(|i| if i % 2 == 0 { 0.01 } else { -0.01 }).collect();
        assert!(b.learn_noise(&quiet, 48_000.0));
        assert!(!b.learn_noise_requested);
        assert!(b.model.gate().enabled);
        assert!((b.model.gate().threshold_db - -34.0).abs() < 0.5, "{}", b.model.gate().threshold_db);
        assert!(b.model.clean_voice_on());
    }

    #[test]
    fn the_gate_head_shows_open_or_closed_when_fed() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.model.set_gate_enabled(true);
        for open in [None, Some(true), Some(false)] {
            b.set_gate_open(open);
            let mut c = Canvas::with_size(320.0, b.height() as f32, None, 1.0);
            b.draw(&mut c, &mut UiCx::new());
            assert!(!c.list.quads().is_empty());
        }
    }

    #[test]
    fn the_tab_switch_shows_the_effect_cards() {
        let mut b = block();
        let mut cx = UiCx::new();
        assert!(b.frame(Control::Gate).is_none(), "gate, warmth and denoise live on the Effects tab");
        let tab = b.frame(Control::Tab).expect("tab");
        let x = tab.max_x() - 4.0;
        b.mouse_down(pt(x, tab.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(x, tab.mid_y()), &mut cx);
        assert_eq!(b.tab(), Tab::Effects);
        let titles: Vec<&str> = b.rows().iter().filter(|r| r.header).filter_map(|r| r.label).collect();
        assert_eq!(titles, ["EQ", "Noise Gate", "Noise Reduction", "Warmth", "Multiband Compressor"]);
        assert!(b.frame(Control::LearnNoise).is_some());
        assert!(b.height() > 20.0 * ControlsGrid::ROW_HEIGHT);
        let mut c = Canvas::with_size(320.0, b.height() as f32, None, 1.0);
        b.draw(&mut c, &mut UiCx::new());
        assert!(!c.list.quads().is_empty());
        let tab = b.frame(Control::Tab).expect("tab");
        b.mouse_down(pt(tab.min_x() + 4.0, tab.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(tab.min_x() + 4.0, tab.mid_y()), &mut cx);
        assert_eq!(b.tab(), Tab::Track);
    }

    #[test]
    fn the_eq_card_edits_the_band_gains_and_crossovers_of_the_compressor() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        let mut cx = UiCx::new();
        let chip = b.frame(Control::EqBand(2)).expect("chip");
        b.mouse_down(pt(chip.mid_x(), chip.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(chip.mid_x(), chip.mid_y()), &mut cx);
        assert_eq!(b.selected_eq(), 2);
        b.set(Slider::EqGain, -3.5);
        assert_eq!(b.model.compressor().bands[2].gain_db, -3.5);
        assert_eq!(b.value(Slider::EqGain), -3.5);
        b.set(Slider::EqFrequency, 2000.0);
        assert!((b.value(Slider::EqFrequency) - 2000.0).abs() < 1.0, "a bell's frequency is its middle");
        let g = b.frame(Control::EqGraph).expect("plot");
        let plot = b.eq_plot(g);
        let low = fx_tab::eq_x(fx_tab::eq_center_hz(0, &b.model.compressor().crossovers_hz), plot);
        b.mouse_down(pt(low, g.mid_y()), Some(1), &mut cx);
        b.mouse_up(pt(low, g.mid_y()), &mut cx);
        assert_eq!(b.selected_eq(), 0);
        b.set(Slider::BandGain, 2.0);
        assert_eq!(b.model.compressor().bands[b.selected_band()].gain_db, 2.0);
    }

    #[test]
    fn an_eq_dot_drag_and_typed_gain_and_frequency_change_the_model_while_the_compressor_is_off() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        assert!(b.model.compressor().bypass, "a new track has the compressor off");
        let mut cx = UiCx::new();
        // Drag band 3's dot up by 20 points.
        let g = b.frame(Control::EqGraph).expect("plot");
        let plot = b.eq_plot(g);
        let x = fx_tab::eq_x(fx_tab::eq_center_hz(2, &b.model.compressor().crossovers_hz), plot);
        b.mouse_down(pt(x, plot.mid_y()), Some(1), &mut cx);
        b.mouse_dragged(pt(x, plot.mid_y() - 20.0), InputModifiers::NONE, &mut cx);
        b.mouse_up(pt(x, plot.mid_y() - 20.0), &mut cx);
        assert_eq!(b.selected_eq(), 2);
        assert!(b.model.compressor().bands[2].gain_db > 1.0, "{}", b.model.compressor().bands[2].gain_db);
        assert_eq!(b.value(Slider::EqGain), b.model.compressor().bands[2].gain_db, "the field shows it");
        // Type Gain 12 and a new Frequency into their fields.
        let before = b.value(Slider::EqFrequency);
        for (s, text) in [(Slider::EqGain, "12"), (Slider::EqFrequency, "2000")] {
            let f = b.frame(Control::Slider(s)).expect("row");
            let field = b.slider_parts(f).1;
            let at = pt(field.mid_x(), field.mid_y());
            b.mouse_down(at, Some(2), &mut cx);
            b.mouse_up(at, &mut cx);
            for ch in text.chars() {
                b.key(InputKey::Character(ch), InputModifiers::NONE, &mut cx);
            }
            b.key(InputKey::Enter, InputModifiers::NONE, &mut cx);
        }
        assert_eq!(b.model.compressor().bands[2].gain_db, 12.0);
        assert_ne!(b.value(Slider::EqFrequency), before, "the typed frequency moved the band");
        assert!((b.value(Slider::EqFrequency) - 2000.0).abs() < 1.0, "{}", b.value(Slider::EqFrequency));
    }

    #[test]
    fn tab_order_only_visits_the_sliders_on_screen() {
        let mut b = block();
        b.set_tab(Tab::Effects);
        b.set(Slider::Gate, -40.0);
        b.model.set_gate_enabled(true);
        b.move_focus(Slider::Denoise, false);
        assert!(b.focused().is_some_and(|s| b.frame(Control::Slider(s)).is_some()));
        b.set_tab(Tab::Track);
        b.model.set_bypass(false);
        b.move_focus(Slider::CompThreshold, false);
        assert_eq!(b.focused(), Some(Slider::CompRatio));
    }
}
