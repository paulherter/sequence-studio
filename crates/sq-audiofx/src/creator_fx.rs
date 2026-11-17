//! Port of `SQAudioFX/Sources/SQAudioFX/CreatorFX.swift`.

use crate::gate_core::{Detector, GateCore, GateStep, Smoothing};
use serde::{Deserialize, Serialize};
use std::ops::RangeInclusive;

/// Noise gate ("hush" for room noise between words): ducks the signal to `-reduction_db` while the linked
/// level stays under the threshold. Off by default.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct NoiseGateSettings {
    pub enabled: bool,
    #[serde(rename = "thresholdDB")]
    pub threshold_db: f64,
    /// How far the closed gate pulls the signal down (positive dB).
    #[serde(rename = "reductionDB")]
    pub reduction_db: f64,
    #[serde(rename = "attackMs")]
    pub attack_ms: f64,
    #[serde(rename = "holdMs")]
    pub hold_ms: f64,
    #[serde(rename = "releaseMs")]
    pub release_ms: f64,
}

impl Default for NoiseGateSettings {
    fn default() -> Self {
        NoiseGateSettings::OFF
    }
}

/// Ranges the gate settings are clamped to.
pub enum NoiseGateLimits {}

impl NoiseGateLimits {
    pub const THRESHOLD_DB: RangeInclusive<f64> = -80.0..=0.0;
    pub const REDUCTION_DB: RangeInclusive<f64> = 0.0..=80.0;
    pub const ATTACK_MS: RangeInclusive<f64> = 0.1..=100.0;
    pub const HOLD_MS: RangeInclusive<f64> = 0.0..=1000.0;
    pub const RELEASE_MS: RangeInclusive<f64> = 5.0..=2000.0;
}

impl NoiseGateSettings {
    pub const OFF: NoiseGateSettings = NoiseGateSettings {
        enabled: false,
        threshold_db: -45.0,
        reduction_db: 40.0,
        attack_ms: 2.0,
        hold_ms: 80.0,
        release_ms: 150.0,
    };

    pub(crate) fn normalized(&self) -> NoiseGateSettings {
        fn c(v: f64, r: RangeInclusive<f64>) -> f64 {
            if v.is_nan() { *r.start() } else { r.end().min(r.start().max(v)) }
        }
        let mut s = *self;
        s.threshold_db = c(self.threshold_db, NoiseGateLimits::THRESHOLD_DB);
        s.reduction_db = c(self.reduction_db, NoiseGateLimits::REDUCTION_DB);
        s.attack_ms = c(self.attack_ms, NoiseGateLimits::ATTACK_MS);
        s.hold_ms = c(self.hold_ms, NoiseGateLimits::HOLD_MS);
        s.release_ms = c(self.release_ms, NoiseGateLimits::RELEASE_MS);
        s
    }
}

/// Soft-clip saturation ("warmth", tape-like): tanh curve, level-normalized so full-scale peaks stay at full
/// scale, blended with the dry signal. Off by default.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct SaturationSettings {
    pub enabled: bool,
    /// Input drive before the curve, 0...24 dB.
    #[serde(rename = "driveDB")]
    pub drive_db: f64,
    /// Dry/wet 0...1.
    pub mix: f64,
}

impl Default for SaturationSettings {
    fn default() -> Self {
        SaturationSettings::OFF
    }
}

/// Ranges the saturation settings are clamped to.
pub enum SaturationLimits {}

impl SaturationLimits {
    pub const DRIVE_DB: RangeInclusive<f64> = 0.0..=24.0;
    pub const MIX: RangeInclusive<f64> = 0.0..=1.0;
}

impl SaturationSettings {
    pub const OFF: SaturationSettings = SaturationSettings { enabled: false, drive_db: 6.0, mix: 1.0 };
}

/// Sample-by-sample, all state in the value (output never depends on chunking). Zero latency.
#[derive(Clone, Copy, Debug)]
pub(crate) struct NoiseGate {
    c: NoiseGateConfig,
    core: GateCore<f64>,
}

/// The numbers a gate runs with, built off the render thread.
#[derive(Clone, Copy, Debug)]
pub(crate) struct NoiseGateConfig {
    active: bool,
    /// Linear, hysteresis of 3 dB.
    open_level: f64,
    close_level: f64,
    floor_gain: f64,
    attack: f64,
    release: f64,
    decay: f64,
    hold_samples: i64,
}

impl Default for NoiseGateConfig {
    fn default() -> Self {
        NoiseGateConfig {
            active: false,
            open_level: 1.0,
            close_level: 1.0,
            floor_gain: 1.0,
            attack: 0.0,
            release: 0.0,
            decay: 0.0,
            hold_samples: 0,
        }
    }
}

impl NoiseGateConfig {
    pub(crate) fn new(raw: &NoiseGateSettings, sample_rate: f64) -> Self {
        let s = raw.normalized();
        let open_level = 10.0_f64.powf(s.threshold_db / 20.0);
        NoiseGateConfig {
            active: s.enabled && s.reduction_db > 0.0,
            open_level,
            close_level: open_level * 0.7079457843841379, // -3 dB
            floor_gain: 10.0_f64.powf(-s.reduction_db / 20.0),
            attack: (-1.0 / (s.attack_ms / 1000.0 * sample_rate)).exp(),
            release: (-1.0 / (s.release_ms / 1000.0 * sample_rate)).exp(),
            decay: (-1.0 / (0.005 * sample_rate)).exp(), // 5 ms peak detector
            hold_samples: (s.hold_ms / 1000.0 * sample_rate) as i64,
        }
    }
}

impl NoiseGate {
    /// The Noise Gate head's Open / Closed: `None` while the gate is off.
    pub(crate) fn open_state(&self) -> Option<bool> {
        self.c.active.then_some(self.core.is_open)
    }

    pub(crate) fn new(settings: &NoiseGateSettings, sample_rate: f64) -> Self {
        NoiseGate {
            c: NoiseGateConfig::new(settings, sample_rate),
            core: GateCore::new(Detector::PeakDecay, Smoothing::Blend),
        }
    }

    /// Installs new settings; envelope, gain and hold state survive. Allocation-free.
    pub(crate) fn apply(&mut self, config: &NoiseGateConfig) {
        self.c = *config;
        if !self.c.active {
            self.core.bypass();
        }
    }

    pub(crate) fn reset(&mut self) {
        self.core.reset();
    }

    pub(crate) fn process_channels(&mut self, buf: &mut [&mut [f32]], frames: usize) {
        if !self.c.active || frames == 0 {
            return;
        }
        for i in 0..frames {
            let mut peak = 0.0_f64;
            for ch in buf.iter() {
                peak = peak.max(f64::from(ch[i].abs()));
            }
            let g = self.core.step(GateStep {
                peak,
                open_level: self.c.open_level,
                close_level: self.c.close_level,
                floor_gain: self.c.floor_gain,
                decay: self.c.decay,
                attack: self.c.attack,
                release: self.c.release,
                hold_samples: self.c.hold_samples,
            }) as f32;
            for ch in buf.iter_mut() {
                ch[i] *= g;
            }
        }
    }

    pub(crate) fn process(&mut self, buf: &mut [Vec<f32>]) {
        let n = buf.first().map_or(0, Vec::len);
        if !self.c.active || n == 0 {
            return;
        }
        with_channel_slices(buf, |chans| self.process_channels(chans, n));
    }
}

/// Soft-clip saturation stage.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Saturator {
    c: SaturatorConfig,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct SaturatorConfig {
    active: bool,
    drive: f32,
    norm: f32,
    mix: f32,
}

impl Default for SaturatorConfig {
    fn default() -> Self {
        SaturatorConfig { active: false, drive: 1.0, norm: 1.0, mix: 1.0 }
    }
}

impl SaturatorConfig {
    pub(crate) fn new(s: &SaturationSettings) -> Self {
        let d = if s.drive_db.is_nan() { 0.0 } else { s.drive_db.clamp(0.0, 24.0) };
        let m = if s.mix.is_nan() { 0.0 } else { s.mix.clamp(0.0, 1.0) };
        let drive = 10.0_f64.powf(d / 20.0) as f32;
        SaturatorConfig { active: s.enabled && m > 0.0, drive, norm: 1.0 / drive.tanh(), mix: m as f32 }
    }
}

impl Saturator {
    pub(crate) fn new(settings: &SaturationSettings) -> Self {
        Saturator { c: SaturatorConfig::new(settings) }
    }

    pub(crate) fn apply(&mut self, config: &SaturatorConfig) {
        self.c = *config;
    }

    pub(crate) fn process_channels(&self, buf: &mut [&mut [f32]], frames: usize) {
        if !self.c.active || frames == 0 {
            return;
        }
        let (drive, norm, mix) = (self.c.drive, self.c.norm, self.c.mix);
        for p in buf.iter_mut() {
            for s in &mut p[..frames] {
                let x = *s;
                *s = x + mix * ((x * drive).tanh() * norm - x);
            }
        }
    }

    pub(crate) fn process(&self, buf: &mut [Vec<f32>]) {
        let n = buf.first().map_or(0, Vec::len);
        if !self.c.active || n == 0 {
            return;
        }
        with_channel_slices(buf, |chans| self.process_channels(chans, n));
    }
}

/// Offline helper: views `buf` as channel slices for the pointer-style `process_channels` core.
pub(crate) fn with_channel_slices<R>(buf: &mut [Vec<f32>], body: impl FnOnce(&mut [&mut [f32]]) -> R) -> R {
    let mut chans: Vec<&mut [f32]> = buf.iter_mut().map(Vec::as_mut_slice).collect();
    body(&mut chans)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;

    fn rms_db(x: &[f32]) -> f64 {
        20.0 * sig::rms(x).max(1e-9).log10()
    }

    fn gate_settings(
        threshold_db: f64,
        reduction_db: f64,
        attack_ms: f64,
        hold_ms: f64,
        release_ms: f64,
    ) -> NoiseGateSettings {
        NoiseGateSettings { enabled: true, threshold_db, reduction_db, attack_ms, hold_ms, release_ms }
    }

    #[test]
    fn gate_silences_quiet_noise_and_keeps_loud_signal() {
        let n = 48000;
        let mut tone = sig::sine(300.0, -10.0, 0.5, 48000, 2, 0.0);
        let noise = sig::noise(0.001, n / 2, 1);
        for c in tone.iter_mut() {
            c.extend_from_slice(&noise);
        }
        let mut gate = NoiseGate::new(&gate_settings(-40.0, 40.0, 1.0, 20.0, 30.0), 48000.0);
        let mut out = tone.clone();
        gate.process(&mut out);
        assert!((rms_db(&out[0][4800..20000]) - rms_db(&tone[0][4800..20000])).abs() < 0.2);
        assert!(rms_db(&out[0][36000..48000]) < rms_db(&tone[0][36000..48000]) - 30.0);
    }

    #[test]
    fn gate_is_chunk_invariant() {
        let x = sig::low_noise(0.05, 24000, 1);
        let signal = vec![x.clone(), x];
        let s = NoiseGateSettings { enabled: true, threshold_db: -30.0, ..NoiseGateSettings::default() };
        let mut a = NoiseGate::new(&s, 48000.0);
        let mut b = a;
        let mut whole = signal.clone();
        a.process(&mut whole);
        let mut parts: Vec<Vec<f32>> = vec![Vec::new(), Vec::new()];
        for mut chunk in sig::chunked(&signal, &[1, 7, 480, 133]) {
            b.process(&mut chunk);
            for k in 0..2 {
                parts[k].extend_from_slice(&chunk[k]);
            }
        }
        assert_eq!(parts, whole);
    }

    #[test]
    fn disabled_gate_and_saturation_are_transparent() {
        let x = sig::sine(440.0, -6.0, 0.1, 48000, 2, 0.0);
        let mut y = x.clone();
        NoiseGate::new(&NoiseGateSettings::OFF, 48000.0).process(&mut y);
        Saturator::new(&SaturationSettings::OFF).process(&mut y);
        assert_eq!(y, x);
    }

    #[test]
    fn saturation_keeps_peaks_and_mix_zero_is_dry() {
        let x = sig::sine(440.0, -1.0, 0.2, 48000, 2, 0.0);
        let mut wet = x.clone();
        Saturator::new(&SaturationSettings { enabled: true, drive_db: 12.0, mix: 1.0 }).process(&mut wet);
        let peak_out = wet[0].iter().fold(0.0_f32, |m, v| m.max(v.abs()));
        assert!(peak_out <= 1.0001);
        assert!(sig::rms(&wet[0]) > sig::rms(&x[0]));
        let mut dry = x.clone();
        Saturator::new(&SaturationSettings { enabled: true, drive_db: 12.0, mix: 0.0 }).process(&mut dry);
        assert_eq!(dry, x);
    }

    // Gate envelope timing on a synthetic burst (offline buffers only). A level step between a loud and a quiet DC value makes
    // the output / input ratio the gate gain, so the times are read straight off the samples.
    const FS: f64 = 48000.0;
    const LOUD: f32 = 0.5;
    const QUIET: f32 = 0.001; // -6 dB and -60 dB; threshold -40 dB

    fn settings(attack: f64, hold: f64, release: f64) -> NoiseGateSettings {
        gate_settings(-40.0, 40.0, attack, hold, release)
    }

    /// Gain per sample for `loud_ms` of loud signal followed by `quiet_ms` of quiet signal, the gate starting open.
    fn closing_gains(s: &NoiseGateSettings, loud_ms: f64, quiet_ms: f64) -> Vec<f32> {
        let a = (loud_ms / 1000.0 * FS) as usize;
        let b = (quiet_ms / 1000.0 * FS) as usize;
        let mut buf = vec![[vec![LOUD; a], vec![QUIET; b]].concat()];
        NoiseGate::new(s, FS).process(&mut buf);
        (0..a + b).map(|i| buf[0][i] / if i < a { LOUD } else { QUIET }).collect()
    }

    fn first_index(g: &[f32], from: usize, p: impl Fn(f32) -> bool) -> usize {
        (from..g.len()).find(|&i| p(g[i])).unwrap_or(g.len())
    }

    #[test]
    fn hold_delays_the_closing_by_its_time() {
        let start = (0.1 * FS) as usize;
        let t0 = first_index(&closing_gains(&settings(1.0, 0.0, 100.0), 100.0, 700.0), start, |v| v < 0.9);
        let g100 = closing_gains(&settings(1.0, 100.0, 100.0), 100.0, 700.0);
        let t100 = first_index(&g100, start, |v| v < 0.9);
        let ms = (t100 - t0) as f64 / FS * 1000.0;
        assert!((ms - 100.0).abs() < 1.5);
        // Held means the gain stays at 1 until then.
        assert_eq!(g100[t0 + (0.05 * FS) as usize], 1.0);
    }

    #[test]
    fn release_glides_at_its_time() {
        for rel in [30.0, 120.0] {
            let g = closing_gains(&settings(1.0, 0.0, rel), 100.0, 900.0);
            let begin = first_index(&g, (0.1 * FS) as usize, |v| v < 0.999);
            let end = first_index(&g, begin, |v| f64::from(v) < 0.01 + 0.99 * 0.3679);
            let ms = (end - begin) as f64 / FS * 1000.0;
            assert!((ms - rel).abs() < rel * 0.1 + 0.5, "release {rel}: {ms}");
        }
    }

    #[test]
    fn attack_glides_at_its_time() {
        for atk in [5.0, 40.0] {
            let quiet_n = (0.5 * FS) as usize;
            let loud_n = (0.3 * FS) as usize;
            let mut buf = vec![[vec![QUIET; quiet_n], vec![LOUD; loud_n]].concat()];
            NoiseGate::new(&settings(atk, 0.0, 5.0), FS).process(&mut buf);
            let g: Vec<f32> = (quiet_n..quiet_n + loud_n).map(|i| buf[0][i] / LOUD).collect();
            // 63.2 % of the way from the floor (0.01) to 1.
            let n = g.iter().position(|&v| f64::from(v) >= 0.01 + 0.99 * 0.632).unwrap_or(g.len());
            let ms = n as f64 / FS * 1000.0;
            assert!((ms - atk).abs() < atk * 0.1 + 0.5, "attack {atk}: {ms}");
        }
    }

    #[test]
    fn changing_the_times_mid_stream_does_not_jump_the_gain() {
        let mut gate = NoiseGate::new(&settings(50.0, 0.0, 200.0), FS);
        let mut a = vec![vec![QUIET; 4800]];
        gate.process(&mut a);
        gate.apply(&NoiseGateConfig::new(&settings(1.0, 300.0, 5.0), FS));
        let mut b = vec![vec![QUIET; 480]];
        gate.process(&mut b);
        let before = a[0][a[0].len() - 1] / QUIET;
        let after = b[0][0] / QUIET;
        assert!((after - before).abs() < 0.02);
    }

    #[test]
    fn preset_decodes_old_json_without_new_fields() {
        use crate::presets::TrackAudioPreset;
        let mut p = TrackAudioPreset::voice();
        p.gate = NoiseGateSettings::OFF;
        p.saturation = SaturationSettings::OFF;
        // Old files carry no gate/saturation keys.
        let Ok(serde_json::Value::Object(mut obj)) = serde_json::to_value(&p) else { panic!("preset object") };
        obj.remove("gate");
        obj.remove("saturation");
        let old: TrackAudioPreset = match serde_json::from_value(serde_json::Value::Object(obj)) {
            Ok(v) => v,
            Err(e) => panic!("old preset: {e}"),
        };
        assert!(
            old.gate == NoiseGateSettings::OFF
                && old.saturation == SaturationSettings::OFF
                && old.noise_reduction == p.noise_reduction
        );
        let mut q = p.clone();
        q.gate.enabled = true;
        q.saturation.enabled = true;
        let back: Result<TrackAudioPreset, _> = serde_json::from_value(serde_json::to_value(&q).unwrap_or_default());
        assert_eq!(back.ok(), Some(q));
    }
}
