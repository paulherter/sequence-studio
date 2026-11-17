// Swift: EffectControlsMultibandModel.swift
//! Multiband Compressor custom setup: a row under the effect header opens a popup editor with preset menu, link toggle,
//! output gain, a band display (draggable crossovers, live band input level and gain reduction), crossover frequencies,
//! per-band Solo / Bypass, four band columns (threshold, ratio, attack, release, gain) and the output limiter (Brickwall
//! on/off, threshold, margin, attack, release, live reduction). Everything maps to the effect's real parameters
//! (`ClipEffect::mb_*_key`); the generic rows below keep the keyframe controls. The band display draws the live spectrum of
//! the effect's output, or its input with "Spectrum at Input" (`AudioSpectrumTap`, real engine feed).
//! This file is the portable part (presets, meter display, model calls) shared by the Mac window
//! (`EffectControlsMultiband.swift`) and the shared-toolkit editor (`Draw/MultibandEditorDraw.swift`).

use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

use sq_audiofx::multiband_meters::MultibandMeterReading;
use sq_audiofx::presets::{MultibandBand, RoleVoicing};
use sq_core_model::{ClipEffect, EffectCatalog, EffectParamSpec};
use sq_core_time::Id;
use sq_draw::monitor::audio_meter::{MeterBallistics, MeterStyle};

use super::track_audio_inspector_model::{ALL_TAGS, CrossoverRules};
use crate::ec::controls_metrics::ControlsMetrics;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty};

pub struct MultibandEditor;

/// A band settings row: caption and the parameter key of band n.
pub struct BandRow {
    pub title: &'static str,
    pub key: fn(usize) -> String,
}

/// A limiter row: caption and parameter key.
pub struct LimiterRow {
    pub title: &'static str,
    pub key: &'static str,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Preset {
    pub name: String,
    pub values: BTreeMap<String, f64>,
}

impl MultibandEditor {
    pub const BAND_COUNT: usize = 4;
    pub const ROW_HEIGHT: f64 = ControlsMetrics::MULTIBAND_ROW;

    /// The band settings rows (caption, parameter key of band n), top to bottom / left to right.
    pub const BAND_ROWS: [BandRow; 5] = [
        BandRow { title: "Threshold (dB)", key: ClipEffect::mb_threshold_key },
        BandRow { title: "Gain (dB)", key: ClipEffect::mb_gain_key },
        BandRow { title: "Ratio (:1)", key: ClipEffect::mb_ratio_key },
        BandRow { title: "Attack (ms)", key: ClipEffect::mb_attack_key },
        BandRow { title: "Release (ms)", key: ClipEffect::mb_release_key },
    ];
    /// The limiter rows.
    pub const LIMITER_ROWS: [LimiterRow; 4] = [
        LimiterRow { title: "Threshold (dB)", key: ClipEffect::MB_LIMITER_THRESHOLD_KEY },
        LimiterRow { title: "Margin (dB)", key: ClipEffect::MB_LIMITER_MARGIN_KEY },
        LimiterRow { title: "Attack (ms)", key: ClipEffect::MB_LIMITER_ATTACK_KEY },
        LimiterRow { title: "Release (ms)", key: ClipEffect::MB_LIMITER_RELEASE_KEY },
    ];

    /// A band's range label: frequencies above 1 kHz in kHz with one decimal.
    pub fn hz(v: f64) -> String {
        if v >= 1000.0 { format!("{:.1}k", v / 1000.0) } else { format!("{v:.0}") }
    }

    /// A band's range label ("20 - 137 Hz").
    pub fn range_text(n: usize, xs: &[f64]) -> String {
        let lo = if n == 0 { 20.0 } else { xs[n - 1] };
        let hi = if n == Self::BAND_COUNT - 1 { 20_000.0 } else { xs[n] };
        format!("{} - {} Hz", Self::hz(lo), Self::hz(hi))
    }

    /// Values of one preset as effect parameters.
    pub fn values(crossovers: &[f64], bands: &[MultibandBand], output_gain_db: f64) -> BTreeMap<String, f64> {
        let mut v: BTreeMap<String, f64> = BTreeMap::new();
        v.insert(ClipEffect::MB_OUTPUT_GAIN_KEY.to_string(), output_gain_db);
        for (i, hz) in crossovers.iter().enumerate() {
            v.insert(ClipEffect::mb_crossover_key(i + 1), *hz);
        }
        for (i, b) in bands.iter().enumerate() {
            let n = i + 1;
            v.insert(ClipEffect::mb_threshold_key(n), b.threshold_db);
            v.insert(ClipEffect::mb_ratio_key(n), b.ratio);
            v.insert(ClipEffect::mb_attack_key(n), b.attack_ms);
            v.insert(ClipEffect::mb_release_key(n), b.release_ms);
            v.insert(ClipEffect::mb_gain_key(n), b.gain_db);
        }
        v
    }

    /// The maintainer's Broadcast setup: bands plus the limiter (threshold -9, ceiling -0.1, attack 4 ms, release 500 ms, Brickwall on).
    pub fn broadcast() -> BTreeMap<String, f64> {
        let b = MultibandBand::with_gain;
        let mut v = Self::values(
            &[137.0, 1147.0, 6910.0],
            &[
                b(-15.0, 3.0, 1.0, 100.0, 4.0),
                b(-11.0, 2.0, 1.0, 100.0, -2.0),
                b(-17.0, 2.0, 1.0, 100.0, -4.0),
                b(-15.0, 3.0, 1.0, 100.0, -2.0),
            ],
            0.0,
        );
        for (k, x) in [
            (ClipEffect::MB_LIMITER_ON_KEY, 1.0),
            (ClipEffect::MB_LIMITER_THRESHOLD_KEY, -9.0),
            (ClipEffect::MB_LIMITER_MARGIN_KEY, -0.1),
            (ClipEffect::MB_LIMITER_ATTACK_KEY, 4.0),
            (ClipEffect::MB_LIMITER_RELEASE_KEY, 500.0),
        ] {
            v.insert(k.to_string(), x);
        }
        v
    }

    /// Solo and link are listening / editing aids, not part of a sound: presets neither set nor compare them.
    pub fn preset_excluded_keys() -> BTreeSet<String> {
        let mut s: BTreeSet<String> = (1..=4).map(ClipEffect::mb_solo_key).collect();
        s.insert(ClipEffect::MB_LINK_KEY.to_string());
        s
    }

    /// "Default" (catalog defaults), "Broadcast", and the three role voicings of the engine, clamped to the ranges.
    /// Every preset is complete (all sound keys, limiter and bypass included), so loading one never leaves the last one's
    /// limiter or bypass behind.
    pub fn presets() -> &'static [Preset] {
        static PRESETS: OnceLock<Vec<Preset>> = OnceLock::new();
        PRESETS.get_or_init(|| {
            let Some(spec) = EffectCatalog::spec_for(ClipEffect::AUDIO_MULTIBAND_KIND) else { return Vec::new() };
            let excluded = Self::preset_excluded_keys();
            let defaults: BTreeMap<String, f64> = spec
                .params
                .iter()
                .filter(|p| !excluded.contains(&p.key))
                .map(|p| (p.key.clone(), p.default_value))
                .collect();
            let complete = |v: &BTreeMap<String, f64>| -> BTreeMap<String, f64> {
                let mut out = defaults.clone();
                for (k, x) in v {
                    out.insert(k.clone(), *x);
                }
                for p in &spec.params {
                    if let Some(x) = out.get(&p.key).copied() {
                        out.insert(p.key.clone(), x.max(*p.range.start()).min(*p.range.end()));
                    }
                }
                out.retain(|k, _| defaults.contains_key(k));
                out
            };
            let mut out = vec![
                Preset { name: "Default".to_string(), values: defaults.clone() },
                Preset { name: "Broadcast".to_string(), values: complete(&Self::broadcast()) },
            ];
            for role in ALL_TAGS {
                let r = RoleVoicing::for_role(role);
                let bands: Vec<MultibandBand> = r
                    .bands
                    .iter()
                    .zip(r.eq_db.iter())
                    .map(|(d, g)| MultibandBand::with_gain(d.threshold_db, d.ratio, d.attack_ms, d.release_ms, *g))
                    .collect();
                out.push(Preset {
                    name: role.title().to_string(),
                    values: complete(&Self::values(&r.crossovers_hz, &bands, r.makeup_gain_db + r.level_db)),
                });
            }
            out
        })
    }

    /// Index of the preset whose values equal `current` (within display precision), None for custom values.
    pub fn matching_preset(current: &BTreeMap<String, f64>) -> Option<usize> {
        Self::presets()
            .iter()
            .position(|p| p.values.iter().all(|(k, v)| (current.get(k).copied().unwrap_or(f64::NAN) - v).abs() < 0.05))
    }

    /// Every parameter of the effect (snapshot keys).
    pub fn all_keys() -> &'static [String] {
        static KEYS: OnceLock<Vec<String>> = OnceLock::new();
        KEYS.get_or_init(|| {
            EffectCatalog::spec_for(ClipEffect::AUDIO_MULTIBAND_KIND)
                .map(|s| s.params.iter().map(|p| p.key.clone()).collect())
                .unwrap_or_default()
        })
    }

    pub fn spec(key: &str) -> Option<EffectParamSpec> {
        EffectCatalog::spec_for(ClipEffect::AUDIO_MULTIBAND_KIND)?.params.into_iter().find(|p| p.key == key)
    }
}

/// What the popup's meters show, from successive `MultibandMeterReading`s (pure, testable). A new sequence feeds the
/// bars (input level with the meter ballistics, reduction as read); the same sequence again means no new audio: the
/// input bars fall. Nothing new for `STALE_SECONDS` (stopped, or the playhead left the clip): no reading is shown.
#[derive(Clone, Debug, PartialEq)]
pub struct MultibandMeterDisplay {
    bands: [MeterBallistics; MultibandEditor::BAND_COUNT],
    gain_reduction_db: [f32; 4],
    limiter_reduction_db: f32,
    is_live: bool,
    last_sequence: u64,
    last_new_at: f64,
}

impl Default for MultibandMeterDisplay {
    fn default() -> Self {
        MultibandMeterDisplay::new()
    }
}

impl MultibandMeterDisplay {
    pub const STALE_SECONDS: f64 = 0.3;

    pub fn new() -> Self {
        MultibandMeterDisplay {
            bands: [MeterBallistics::new(MeterStyle::Standard); MultibandEditor::BAND_COUNT],
            gain_reduction_db: [0.0; 4],
            limiter_reduction_db: 0.0,
            is_live: false,
            last_sequence: 0,
            last_new_at: f64::NEG_INFINITY,
        }
    }

    pub fn gain_reduction_db(&self) -> [f32; 4] {
        self.gain_reduction_db
    }
    pub fn limiter_reduction_db(&self) -> f32 {
        self.limiter_reduction_db
    }
    pub fn is_live(&self) -> bool {
        self.is_live
    }

    pub fn input_db(&self) -> Vec<f32> {
        self.bands.iter().map(|b| b.level_db()).collect()
    }

    pub fn update(&mut self, r: Option<&MultibandMeterReading>, time: f64) {
        if let Some(r) = r
            && r.sequence != 0
            && r.sequence != self.last_sequence
        {
            self.last_sequence = r.sequence;
            self.last_new_at = time;
            self.is_live = true;
            for i in 0..self.bands.len() {
                self.bands[i].update(r.input_peak[i], time, false);
            }
            self.gain_reduction_db = std::array::from_fn(|i| r.gain_reduction_db[i].max(0.0));
            self.limiter_reduction_db = r.limiter_reduction_db.max(0.0);
            return;
        }
        if time - self.last_new_at > Self::STALE_SECONDS {
            if !(self.is_live || self.bands.iter().any(|b| !b.is_settled())) {
                return;
            }
            self.is_live = false;
            for b in &mut self.bands {
                b.silence();
            }
            self.gain_reduction_db = [0.0; 4];
            self.limiter_reduction_db = 0.0;
        } else {
            for b in &mut self.bands {
                b.update(0.0, time, false);
            }
        }
    }
}

impl EffectControlsModel {
    fn mb_property(effect: Id, key: &str) -> EffectProperty {
        EffectProperty::Fx { id: effect, kind: ClipEffect::AUDIO_MULTIBAND_KIND.to_string(), key: key.to_string() }
    }

    /// Shown value of one Multiband parameter at the playhead.
    pub fn multiband_value(&self, effect: Id, key: &str) -> f64 {
        self.scalar_value(&Self::mb_property(effect, key))
    }

    pub fn multiband_property(&self, effect: Id, key: &str) -> EffectProperty {
        Self::mb_property(effect, key)
    }

    /// All parameter values at the playhead, by key.
    pub fn multiband_snapshot(&self, effect: Id) -> BTreeMap<String, f64> {
        let mut v = BTreeMap::new();
        for k in MultibandEditor::all_keys() {
            v.insert(k.clone(), self.multiband_value(effect, k));
        }
        v
    }

    pub fn crossovers(&self, effect: Id) -> Vec<f64> {
        (1..=3).map(|i| self.multiband_value(effect, &ClipEffect::mb_crossover_key(i))).collect()
    }

    /// One crossover, kept in order and spaced (`CrossoverRules`).
    pub fn set_crossover(&mut self, effect: Id, index: usize, hz: f64) {
        let c = CrossoverRules::clamp(hz, index, &self.crossovers(effect));
        self.set_value(&Self::mb_property(effect, &ClipEffect::mb_crossover_key(index + 1)), EffectComponent::All, c);
    }

    /// Loads a preset: every parameter in one undo step (animated parameters get a key at the playhead).
    pub fn apply_multiband_preset(&mut self, effect: Id, index: usize) {
        let Some(preset) = MultibandEditor::presets().get(index) else { return };
        let pairs: Vec<(EffectProperty, f64)> =
            preset.values.iter().map(|(k, v)| (Self::mb_property(effect, k), *v)).collect();
        self.set_values(&pairs, "Multiband Preset");
    }

    // MARK: Solo / Bypass / Link (band is 0-based)

    pub fn multiband_solo(&self, effect: Id, band: usize) -> bool {
        self.multiband_value(effect, &ClipEffect::mb_solo_key(band + 1)) >= 0.5
    }
    pub fn multiband_bypass(&self, effect: Id, band: usize) -> bool {
        self.multiband_value(effect, &ClipEffect::mb_bypass_key(band + 1)) >= 0.5
    }
    pub fn multiband_linked(&self, effect: Id) -> bool {
        self.multiband_value(effect, ClipEffect::MB_LINK_KEY) >= 0.5
    }

    pub fn toggle_multiband_solo(&mut self, effect: Id, band: usize) {
        let on = self.multiband_solo(effect, band);
        let name = if on { format!("Unsolo Band {}", band + 1) } else { format!("Solo Band {}", band + 1) };
        self.set_values(
            &[(Self::mb_property(effect, &ClipEffect::mb_solo_key(band + 1)), if on { 0.0 } else { 1.0 })],
            &name,
        );
    }

    pub fn toggle_multiband_bypass(&mut self, effect: Id, band: usize) {
        let on = self.multiband_bypass(effect, band);
        let name = if on { format!("Band {} On", band + 1) } else { format!("Band {} Off", band + 1) };
        self.set_values(
            &[(Self::mb_property(effect, &ClipEffect::mb_bypass_key(band + 1)), if on { 0.0 } else { 1.0 })],
            &name,
        );
    }

    pub fn set_multiband_link(&mut self, effect: Id, on: bool) {
        let name = if on { "Link Band Controls" } else { "Unlink Band Controls" };
        self.set_values(&[(Self::mb_property(effect, ClipEffect::MB_LINK_KEY), if on { 1.0 } else { 0.0 })], name);
    }

    /// One band value (threshold, ratio, attack, release or gain). Linked: every band moves by the same delta from its
    /// current value, each clamped to its range, in one commit (so one undo step, or part of the running gesture).
    pub fn set_multiband_band_value(&mut self, effect: Id, key: fn(usize) -> String, band: usize, v: f64) {
        if band >= MultibandEditor::BAND_COUNT {
            return;
        }
        let Some(s) = MultibandEditor::spec(&key(band + 1)) else { return };
        let clamp = |x: f64| x.max(*s.range.start()).min(*s.range.end());
        let target = clamp(v);
        if !self.multiband_linked(effect) {
            self.set_value(&Self::mb_property(effect, &key(band + 1)), EffectComponent::All, target);
            return;
        }
        let delta = target - self.multiband_value(effect, &key(band + 1));
        let pairs: Vec<(EffectProperty, f64)> = (1..=MultibandEditor::BAND_COUNT)
            .map(|n| {
                let value = if n == band + 1 { target } else { clamp(self.multiband_value(effect, &key(n)) + delta) };
                (Self::mb_property(effect, &key(n)), value)
            })
            .collect();
        let title = s.title.replace(&format!("Band {} ", band + 1), "");
        self.set_values(&pairs, &format!("Change {title} (Linked)"));
    }
}
