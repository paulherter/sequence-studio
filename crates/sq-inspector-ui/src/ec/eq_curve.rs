// Swift: EQCurve.swift
//! Pure mapping of the EQ curve plot and the EQ curve under the Parametric EQ's header.

use sq_core_audio::audio_effects::{AudioPEQBand, AudioParametricEQValues, PEQ_FILTER_IDS, peq_key};
use sq_core_model::{ClipEffect, EffectCatalog};
use sq_core_time::Id;
use sq_uikit::keyframe_graph_geometry::Rect;

use crate::ec::controls_metrics::EQ_CURVE_KEY;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectProperty;

/// Pure mapping of the EQ curve plot: frequency on a log axis (20 Hz...20 kHz), gain linear (about +-18 dB).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EQCurveGeometry {
    pub plot: Rect,
}

impl EQCurveGeometry {
    pub const MIN_HZ: f64 = 20.0;
    pub const MAX_HZ: f64 = 20_000.0;
    pub const MAX_DB: f64 = 18.0;
    pub const GRID_DB: [f64; 5] = [-12.0, -6.0, 0.0, 6.0, 12.0];
    pub const GRID_HZ: [f64; 28] = [
        20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 900.0,
        1_000.0, 2_000.0, 3_000.0, 4_000.0, 5_000.0, 6_000.0, 7_000.0, 8_000.0, 9_000.0, 10_000.0, 20_000.0,
    ];
    /// Decade lines (drawn stronger and labeled).
    pub const DECADE_HZ: [f64; 3] = [100.0, 1_000.0, 10_000.0];
    pub const FILTER_NAMES: [&'static str; 9] =
        ["High-Pass", "Low Shelf", "Band 1", "Band 2", "Band 3", "Band 4", "Band 5", "High Shelf", "Low-Pass"];

    /// Q of the high-pass and low-pass (the Swift literal 0.7071, written as a ratio).
    pub const CUT_Q: f64 = 7071.0 / 10000.0;

    pub fn new(plot: Rect) -> EQCurveGeometry {
        EQCurveGeometry { plot }
    }

    fn log_span() -> f64 {
        (Self::MAX_HZ / Self::MIN_HZ).log10()
    }

    pub fn x(&self, hz: f64) -> f64 {
        let t = (hz.clamp(Self::MIN_HZ, Self::MAX_HZ) / Self::MIN_HZ).log10() / Self::log_span();
        self.plot.min_x() + t * self.plot.width
    }

    pub fn hz(&self, x: f64) -> f64 {
        let t = (x - self.plot.min_x()) / self.plot.width.max(1.0);
        Self::MIN_HZ * 10f64.powf(t.clamp(0.0, 1.0) * Self::log_span())
    }

    /// Top of the plot is +MAX_DB (flipped view: y grows downward).
    pub fn y(&self, db: f64) -> f64 {
        let t = (db.clamp(-Self::MAX_DB, Self::MAX_DB) + Self::MAX_DB) / (2.0 * Self::MAX_DB);
        self.plot.max_y() - t * self.plot.height
    }

    pub fn db(&self, y: f64) -> f64 {
        let t = (self.plot.max_y() - y) / self.plot.height.max(1.0);
        t.clamp(0.0, 1.0) * 2.0 * Self::MAX_DB - Self::MAX_DB
    }

    /// Frequencies the curve is sampled at: log spaced, one per `step` points of width (Swift default 2, at least 8).
    pub fn sample_frequencies(&self, step: f64) -> Vec<f64> {
        let n = ((self.plot.width / step) as i64).max(8);
        (0..=n).map(|i| Self::MIN_HZ * 10f64.powf(i as f64 / n as f64 * Self::log_span())).collect()
    }

    /// HP (0) and LP (8) only have a frequency; the shelves and bands also gain and Q.
    pub fn has_gain(i: usize) -> bool {
        (1..=7).contains(&i)
    }

    /// Option-drag / scroll Q: up = narrower (higher Q), 2x per 40 points.
    pub fn q_factor(start: f64, dy: f64) -> f64 {
        (start * 2f64.powf(dy / 40.0)).clamp(0.1, 10.0)
    }
}

impl EffectControlsModel {
    pub fn is_eq_curve_open(&self, effect: Id) -> bool {
        self.open_color_groups.contains(&Self::color_group_id(effect, EQ_CURVE_KEY))
    }

    pub fn toggle_eq_curve(&mut self, effect: Id) {
        self.toggle_color_group(effect, EQ_CURVE_KEY);
    }

    fn eq_property(effect: Id, filter: usize, field: &str) -> EffectProperty {
        EffectProperty::Fx {
            id: effect,
            kind: ClipEffect::AUDIO_PARAMETRIC_EQ_KIND.to_string(),
            key: peq_key(PEQ_FILTER_IDS[filter], field),
        }
    }

    /// The shown values at the playhead.
    pub fn eq_values(&self, effect: Id) -> Option<AudioParametricEQValues> {
        let c = self.clip.as_ref()?;
        if !c.effects.iter().any(|e| e.id == effect && e.kind == ClipEffect::AUDIO_PARAMETRIC_EQ_KIND) {
            return None;
        }
        let band = |i: usize| -> AudioPEQBand {
            let v = |f: &str| self.scalar_value(&Self::eq_property(effect, i, f));
            let cut = !EQCurveGeometry::has_gain(i);
            AudioPEQBand {
                on: v("On") >= 0.5,
                hz: v("Freq"),
                gain_db: if cut { 0.0 } else { v("Gain") },
                q: if cut { EQCurveGeometry::CUT_Q } else { v("Q") },
            }
        };
        Some(AudioParametricEQValues { bands: std::array::from_fn(band) })
    }

    /// Frequency, gain and Q of one filter in one commit (inside a gesture: part of it). A None `hz` / `gain_db` / `q` is
    /// not written (no key on an animated parameter).
    pub fn set_eq_band(&mut self, effect: Id, filter: usize, hz: Option<f64>, gain_db: Option<f64>, q: Option<f64>) {
        if filter >= AudioParametricEQValues::BAND_COUNT {
            return;
        }
        let mut pairs: Vec<(EffectProperty, f64)> = Vec::new();
        if let Some(hz) = hz {
            pairs.push((Self::eq_property(effect, filter, "Freq"), hz));
        }
        if let Some(g) = gain_db
            && EQCurveGeometry::has_gain(filter)
        {
            pairs.push((Self::eq_property(effect, filter, "Gain"), g));
        }
        if let Some(q) = q
            && EQCurveGeometry::has_gain(filter)
        {
            pairs.push((Self::eq_property(effect, filter, "Q"), q));
        }
        if pairs.is_empty() {
            return;
        }
        self.set_values(&pairs, &format!("Change EQ {}", EQCurveGeometry::FILTER_NAMES[filter]));
    }

    /// Frequency, gain and Q back to the catalog defaults (one undo step).
    pub fn reset_eq_band(&mut self, effect: Id, filter: usize) {
        if filter >= AudioParametricEQValues::BAND_COUNT {
            return;
        }
        let Some(spec) = EffectCatalog::spec_for(ClipEffect::AUDIO_PARAMETRIC_EQ_KIND) else { return };
        let id = PEQ_FILTER_IDS[filter];
        let fields: &[&str] = if EQCurveGeometry::has_gain(filter) { &["Freq", "Gain", "Q"] } else { &["Freq"] };
        let pairs: Vec<(EffectProperty, f64)> = fields
            .iter()
            .filter_map(|f| {
                spec.params
                    .iter()
                    .find(|p| p.key == peq_key(id, f))
                    .map(|p| (Self::eq_property(effect, filter, f), p.default_value))
            })
            .collect();
        self.set_values(&pairs, &format!("Reset EQ {}", EQCurveGeometry::FILTER_NAMES[filter]));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frequency_and_gain_map_round_trip() {
        let g = EQCurveGeometry::new(Rect::new(10.0, 20.0, 400.0, 180.0));
        assert!((g.x(20.0) - 10.0).abs() < 1e-9);
        assert!((g.x(20_000.0) - 410.0).abs() < 1e-9);
        for hz in [30.0, 440.0, 5_000.0] {
            assert!((g.hz(g.x(hz)) - hz).abs() < 1e-6 * hz);
        }
        assert!((g.y(18.0) - 20.0).abs() < 1e-9);
        assert!((g.y(-18.0) - 200.0).abs() < 1e-9);
        assert!((g.db(g.y(6.0)) - 6.0).abs() < 1e-9);
    }

    #[test]
    fn only_shelves_and_bands_have_gain_and_q_doubles_per_40_points() {
        assert!(!EQCurveGeometry::has_gain(0) && !EQCurveGeometry::has_gain(8));
        assert!((1..=7).all(EQCurveGeometry::has_gain));
        assert!((EQCurveGeometry::q_factor(1.0, 40.0) - 2.0).abs() < 1e-12);
        assert_eq!(EQCurveGeometry::q_factor(1.0, 1000.0), 10.0);
        assert_eq!(EQCurveGeometry::q_factor(1.0, -1000.0), 0.1);
    }

    #[test]
    fn samples_are_log_spaced_from_20_hz_to_20_khz() {
        let g = EQCurveGeometry::new(Rect::new(0.0, 0.0, 100.0, 50.0));
        let f = g.sample_frequencies(2.0);
        assert_eq!(f.len(), 51);
        assert!((f[0] - 20.0).abs() < 1e-9 && (f[50] - 20_000.0).abs() < 1e-6);
    }
}
