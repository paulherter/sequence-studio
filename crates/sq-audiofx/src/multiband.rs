// Swift: Multiband.swift
//! Own 4-band compressor: three Linkwitz-Riley 4th-order crossovers (allpass-compensated so the bands sum flat), a linked
//! peak detector per band, per-band threshold/ratio/attack/release/gain.
//!
//! Sample-by-sample with all state in the value, so the output never depends on chunking and the same code serves offline
//! rendering and realtime playback. Zero latency.

use crate::gain::GainMath;
use crate::presets::{MultibandBand, MultibandCompressorSettings};
use sq_core_audio::AudioMultibandValues;

type V4 = [f64; 4];

#[derive(Clone, Copy, Debug)]
struct Coef {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

impl Default for Coef {
    fn default() -> Self {
        Coef { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0 }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Biquad {
    z1: f64,
    z2: f64,
}

impl Biquad {
    #[inline]
    fn run(&mut self, x: f64, c: &Coef) -> f64 {
        let y = c.b0 * x + self.z1;
        self.z1 = c.b1 * x - c.a1 * y + self.z2;
        self.z2 = c.b2 * x - c.a2 * y;
        y
    }
}

/// LR4 low/high pair at one frequency (two cascaded Butterworth biquads each).
#[derive(Clone, Copy, Debug, Default)]
struct Crossover {
    lp: Coef,
    hp: Coef,
}

impl Crossover {
    fn new(freq: f64, sample_rate: f64) -> Crossover {
        let w = 2.0 * std::f64::consts::PI * freq / sample_rate;
        let cw = w.cos();
        let alpha = w.sin() / (2.0 * 0.5_f64.sqrt()); // Q = 1/sqrt(2)
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cw / a0;
        let a2 = (1.0 - alpha) / a0;
        Crossover {
            lp: Coef { b0: (1.0 - cw) / 2.0 / a0, b1: (1.0 - cw) / a0, b2: (1.0 - cw) / 2.0 / a0, a1, a2 },
            hp: Coef { b0: (1.0 + cw) / 2.0 / a0, b1: -(1.0 + cw) / a0, b2: (1.0 + cw) / 2.0 / a0, a1, a2 },
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Split {
    l1: Biquad,
    l2: Biquad,
    h1: Biquad,
    h2: Biquad,
}

impl Split {
    #[inline]
    fn run(&mut self, x: f64, c: &Crossover) -> (f64, f64) {
        let lo = self.l1.run(x, &c.lp);
        let hi = self.h1.run(x, &c.hp);
        (self.l2.run(lo, &c.lp), self.h2.run(hi, &c.hp))
    }

    /// lo + hi: the LR4 allpass at this crossover.
    #[inline]
    fn allpass(&mut self, x: f64, c: &Crossover) -> f64 {
        let (lo, hi) = self.run(x, c);
        lo + hi
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct ChannelFilters {
    s1: Split,
    s2: Split,
    s3: Split,
    ap_low2: Split,
    ap_low3: Split,
    ap_mid3: Split,
}

/// Detector and gain state of one band.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BandState {
    /// Linear.
    pub threshold: f64,
    /// 1 - 1/ratio.
    pub slope: f64,
    /// Detector decay per sample.
    pub hold: f64,
    pub attack: f64,
    pub release: f64,
    /// Band gain, linear.
    pub gain: f64,
    /// Peak detector, linear.
    pub env: f64,
    /// Smoothed gain reduction, dB (>= 0).
    pub gr: f64,
}

impl Default for BandState {
    fn default() -> Self {
        BandState { threshold: 1.0, slope: 0.0, hold: 0.0, attack: 0.0, release: 0.0, gain: 1.0, env: 0.0, gr: 0.0 }
    }
}

impl BandState {
    /// Advances the detector and gain smoothing by one sample, returns the linear band gain.
    #[inline]
    pub fn step(&mut self, peak: f64) -> f64 {
        let held = self.env * self.hold;
        self.env = if held >= peak { held } else { peak };
        let mut target = 0.0;
        if self.env > self.threshold {
            target = 20.0 * (self.env / self.threshold).log10() * self.slope;
        }
        let coef = if target > self.gr { self.attack } else { self.release };
        self.gr = coef * self.gr + (1.0 - coef) * target;
        if self.gr < 1e-9 {
            self.gr = 0.0;
            return self.gain;
        }
        self.gain * (-self.gr * 0.115_129_254_649_702_29).exp() // 10^(-gr/20)
    }
}

/// Time constants of one band: the detector decay follows the band's lowest frequency (one period), bounded to 3...20 ms, so
/// the peak ripple stays small without slowing the detector down.
fn band_state(
    low_edge: f64,
    ratio: f64,
    threshold_db: f64,
    attack_ms: f64,
    release_ms: f64,
    gain: f64,
    sample_rate: f64,
) -> BandState {
    let mut st =
        BandState { threshold: 10.0_f64.powf(threshold_db / 20.0), slope: 1.0 - 1.0 / ratio, ..BandState::default() };
    let hold_s = (1.0 / low_edge).clamp(0.003, 0.02);
    st.hold = (-1.0 / (hold_s * sample_rate)).exp();
    st.attack = (-1.0 / ((attack_ms / 1000.0).max(0.0001) * sample_rate)).exp();
    st.release = (-1.0 / ((release_ms / 1000.0).max(0.0001) * sample_rate)).exp();
    st.gain = gain;
    st
}

/// Crossovers clamped to 20 Hz...0.45 x rate and made ascending.
fn ascending(mut x: [f64; 3], hi: f64) -> [f64; 3] {
    for v in &mut x {
        *v = hi.min(20.0_f64.max(if v.is_nan() { 20.0 } else { *v }));
    }
    for i in 1..3 {
        if x[i] <= x[i - 1] {
            x[i] = hi.min(x[i - 1] * 1.05);
        }
    }
    for i in 1..3 {
        if x[i] <= x[i - 1] {
            x[i - 1] = x[i] / 1.05;
        }
    }
    x
}

/// Everything `settings` decides, precomputed without touching filter/detector state. Plain value (no arrays), so it can be
/// built on any thread and applied on the render thread allocation-free.
#[derive(Clone, Copy, Debug)]
pub struct MultibandConfig {
    active: bool,
    x1: Crossover,
    x2: Crossover,
    x3: Crossover,
    pre_gain: f64,
    makeup: f64,
    bands: [BandState; 4],
    /// Band solo / bypass targets: `audible` 1 = heard, 0 = muted by another band's solo; `bypass` 1 = band passes
    /// uncompressed at unity (no band gain). Both fade with `fade_coef` (5 ms one-pole) so a switch never clicks.
    audible: V4,
    bypass: V4,
    fade_coef: f64,
}

impl MultibandConfig {
    fn empty(sample_rate: f64) -> Self {
        MultibandConfig {
            active: false,
            x1: Crossover::default(),
            x2: Crossover::default(),
            x3: Crossover::default(),
            pre_gain: 1.0,
            makeup: 1.0,
            bands: [BandState::default(); 4],
            audible: [1.0; 4],
            bypass: [0.0; 4],
            fade_coef: (-1.0 / (0.005 * sample_rate)).exp(),
        }
    }

    /// The config for compressor settings.
    pub fn from_settings(raw: &MultibandCompressorSettings, sample_rate: f64) -> Self {
        let s = raw.normalized(sample_rate);
        let mut c = Self::empty(sample_rate);
        // The EQ is the bands' gain, so the stage also runs for a bypassed compressor while the EQ has a gain to apply;
        // it then only equalizes: no compression, no pre or make-up gain.
        let eq_only = s.bypass && s.bands.iter().any(|b| b.gain_db != 0.0);
        c.active = !s.bypass || eq_only;
        c.x1 = Crossover::new(s.crossovers_hz[0], sample_rate);
        c.x2 = Crossover::new(s.crossovers_hz[1], sample_rate);
        c.x3 = Crossover::new(s.crossovers_hz[2], sample_rate);
        let compressing = !s.bypass;
        c.pre_gain = GainMath::linear_from_db(if compressing { s.pre_gain_db } else { 0.0 });
        c.makeup = GainMath::linear_from_db(if compressing { s.makeup_gain_db } else { 0.0 });
        let low_edges = [s.crossovers_hz[0] / 2.0, s.crossovers_hz[0], s.crossovers_hz[1], s.crossovers_hz[2]];
        for (i, edge) in low_edges.iter().enumerate() {
            let b = &s.bands[i];
            c.bands[i] = band_state(
                *edge,
                if compressing { b.ratio } else { 1.0 },
                b.threshold_db,
                b.attack_ms,
                b.release_ms,
                GainMath::linear_from_db(b.gain_db),
                sample_rate,
            );
        }
        c
    }

    /// Same result as `from_settings` for one clip effect's values, without allocating (no arrays). Crossovers are clamped to
    /// 20 Hz...0.45 x rate and made ascending, ratio >= 1, threshold -100...0 dB, band gain +-40 dB.
    pub fn from_values(v: &AudioMultibandValues, sample_rate: f64) -> Self {
        let mut c = Self::empty(sample_rate);
        c.active = true;
        for i in 0..4 {
            if v.band_solo != 0 {
                c.audible[i] = if v.is_soloed(i) { 1.0 } else { 0.0 };
            }
            c.bypass[i] = if v.is_bypassed(i) { 1.0 } else { 0.0 };
        }
        let x = ascending(v.crossover_hz, sample_rate * 0.45);
        c.x1 = Crossover::new(x[0], sample_rate);
        c.x2 = Crossover::new(x[1], sample_rate);
        c.x3 = Crossover::new(x[2], sample_rate);
        c.pre_gain = 1.0;
        c.makeup = GainMath::linear_from_db(v.output_gain_db);
        let low_edges = [x[0] / 2.0, x[0], x[1], x[2]];
        for (i, edge) in low_edges.iter().enumerate() {
            let ratio = if v.ratio[i].is_nan() { 1.0 } else { v.ratio[i].max(1.0) };
            let threshold_db = (if v.threshold_db[i].is_nan() { 0.0 } else { v.threshold_db[i] }).clamp(-100.0, 0.0);
            let gain_db = (if v.gain_db[i].is_nan() { 0.0 } else { v.gain_db[i] }).clamp(-40.0, 40.0);
            c.bands[i] = band_state(
                *edge,
                ratio,
                threshold_db,
                v.attack_ms[i],
                v.release_ms[i],
                GainMath::linear_from_db(gain_db),
                sample_rate,
            );
        }
        c
    }
}

/// The 4-band compressor.
#[derive(Clone, Debug)]
pub struct MultibandCompressor {
    active: bool,
    x1: Crossover,
    x2: Crossover,
    x3: Crossover,
    pre_gain: f64,
    makeup: f64,
    filters: Vec<ChannelFilters>,
    /// Per-channel band split of the current sample (kept here so `process` never allocates).
    split: Vec<V4>,
    bands: [BandState; 4],
    /// Current (fading) solo / bypass mixes and their targets; see `MultibandConfig`.
    audible: V4,
    bypass: V4,
    audible_target: V4,
    bypass_target: V4,
    fade_coef: f64,
    /// Largest band input peak (linear, after the split) since `take_meter_peak`: the per-band input meter.
    meter_peak: V4,
}

impl MultibandCompressor {
    /// A compressor for `channels` channels.
    pub fn new(settings: &MultibandCompressorSettings, sample_rate: f64, channels: usize) -> Self {
        let channels = channels.max(1);
        let mut c = MultibandCompressor {
            active: false,
            x1: Crossover::default(),
            x2: Crossover::default(),
            x3: Crossover::default(),
            pre_gain: 1.0,
            makeup: 1.0,
            filters: vec![ChannelFilters::default(); channels],
            split: vec![[0.0; 4]; channels],
            bands: [BandState::default(); 4],
            audible: [1.0; 4],
            bypass: [0.0; 4],
            audible_target: [1.0; 4],
            bypass_target: [0.0; 4],
            fade_coef: 0.0,
            meter_peak: [0.0; 4],
        };
        c.apply(&MultibandConfig::from_settings(settings, sample_rate), false);
        c
    }

    /// Installs new settings. With `keeping_state` the filter memories and the detector/gain-reduction state survive (no
    /// click when a preset is tweaked). Allocation-free.
    pub fn apply(&mut self, c: &MultibandConfig, keeping_state: bool) {
        self.active = c.active;
        self.x1 = c.x1;
        self.x2 = c.x2;
        self.x3 = c.x3;
        self.pre_gain = c.pre_gain;
        self.makeup = c.makeup;
        for i in 0..4 {
            let mut n = c.bands[i];
            if keeping_state {
                n.env = self.bands[i].env;
                n.gr = self.bands[i].gr;
            }
            self.bands[i] = n;
        }
        self.audible_target = c.audible;
        self.bypass_target = c.bypass;
        self.fade_coef = c.fade_coef;
        if !keeping_state {
            self.audible = c.audible;
            self.bypass = c.bypass;
        }
    }

    /// The band input peak since the last call, then starts a new one. Allocation-free.
    pub fn take_meter_peak(&mut self) -> [f64; 4] {
        std::mem::replace(&mut self.meter_peak, [0.0; 4])
    }

    /// Smoothed gain reduction per band in dB (>= 0), as the detector has it now.
    pub fn gain_reduction_db(&self) -> [f64; 4] {
        [self.bands[0].gr, self.bands[1].gr, self.bands[2].gr, self.bands[3].gr]
    }

    /// Bypass mix per band right now (1 = fully bypassed).
    pub fn bypass_mix(&self) -> [f64; 4] {
        self.bypass
    }

    /// Output makeup and band gains (dB) without touching anything else: the chain ramps them per sub-block. Allocation-free.
    pub fn set_gains(&mut self, makeup_db: f64, band_db: [f64; 4]) {
        self.makeup = GainMath::linear_from_db(makeup_db);
        for (band, db) in self.bands.iter_mut().zip(band_db) {
            band.gain = GainMath::linear_from_db((if db.is_nan() { 0.0 } else { db }).clamp(-40.0, 40.0));
        }
    }

    /// Clears filter memories and detector state. Allocation-free.
    pub fn reset(&mut self) {
        self.filters.fill(ChannelFilters::default());
        for b in &mut self.bands {
            b.env = 0.0;
            b.gr = 0.0;
        }
        self.audible = self.audible_target;
        self.bypass = self.bypass_target;
        self.meter_peak = [0.0; 4];
    }

    /// Planar channels as owned vectors (the offline path).
    pub fn process_planar(&mut self, buf: &mut [Vec<f32>]) {
        let Some(n) = buf.first().map(Vec::len) else { return };
        let mut views: Vec<&mut [f32]> = buf.iter_mut().map(Vec::as_mut_slice).collect();
        self.process(&mut views, n);
    }

    /// Allocation-free core (realtime path): in place on channel slices.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize) {
        if !self.active || n == 0 {
            return;
        }
        let chans = buf.len().min(self.filters.len());
        let (x1, x2, x3, pre_gain, makeup) = (self.x1, self.x2, self.x3, self.pre_gain, self.makeup);
        let [mut bs0, mut bs1, mut bs2, mut bs3] = self.bands;
        // Solo / bypass only touch the arithmetic while one is set or still fading: the default path stays bit-identical.
        let (a_t, b_t, k) = (self.audible_target, self.bypass_target, self.fade_coef);
        let (mut au, mut by) = (self.audible, self.bypass);
        let mixing = au != [1.0; 4] || by != [0.0; 4] || a_t != au || b_t != by;
        let mut meter = self.meter_peak;
        for i in 0..n {
            for (c, chan) in buf.iter().enumerate().take(chans) {
                let x = f64::from(chan[i]) * pre_gain;
                let f = &mut self.filters[c];
                let a = f.s1.run(x, &x1);
                let b = f.s2.run(a.1, &x2);
                let d = f.s3.run(b.1, &x3);
                let b0 = f.ap_low3.allpass(f.ap_low2.allpass(a.0, &x2), &x3);
                let b1 = f.ap_mid3.allpass(b.0, &x3);
                self.split[c] = [b0, b1, d.0, d.1];
            }
            let mut pk = [0.0_f64; 4];
            for sc in self.split.iter().take(chans) {
                for (p, v) in pk.iter_mut().zip(sc) {
                    *p = p.max(v.abs());
                }
            }
            for (m, p) in meter.iter_mut().zip(pk) {
                *m = m.max(p);
            }
            let mut g = [bs0.step(pk[0]), bs1.step(pk[1]), bs2.step(pk[2]), bs3.step(pk[3])];
            if mixing {
                for j in 0..4 {
                    au[j] = a_t[j] + (au[j] - a_t[j]) * k;
                    by[j] = b_t[j] + (by[j] - b_t[j]) * k;
                    g[j] = (g[j] * (1.0 - by[j]) + by[j]) * au[j];
                }
            }
            for (c, chan) in buf.iter_mut().enumerate().take(chans) {
                let s = self.split[c];
                // Sequential lane sum, as Swift's `SIMD4.sum()`.
                let y = (0.0 + s[0] * g[0] + s[1] * g[1] + s[2] * g[2] + s[3] * g[3]) * makeup;
                chan[i] = y as f32;
            }
        }
        self.bands = [bs0, bs1, bs2, bs3];
        self.meter_peak = meter;
        if mixing {
            // Snap once within 1e-6 of the target (-120 dB): from then on the plain path runs again.
            for j in 0..4 {
                if (au[j] - a_t[j]).abs() < 1e-6 {
                    au[j] = a_t[j];
                }
                if (by[j] - b_t[j]).abs() < 1e-6 {
                    by[j] = b_t[j];
                }
            }
            self.audible = au;
            self.bypass = by;
        }
    }
}

impl MultibandCompressorSettings {
    /// Clamps to usable values: crossovers within 20 Hz...0.45*rate and strictly ascending, ratio >= 1.
    pub fn normalized(&self, sample_rate: f64) -> MultibandCompressorSettings {
        let mut s = self.clone();
        let neutral = MultibandCompressorSettings::neutral();
        if s.bands.len() != 4 {
            s.bands = neutral.bands;
        }
        if s.crossovers_hz.len() != 3 {
            s.crossovers_hz = neutral.crossovers_hz;
        }
        let x = ascending([s.crossovers_hz[0], s.crossovers_hz[1], s.crossovers_hz[2]], sample_rate * 0.45);
        s.crossovers_hz = x.to_vec();
        let eq_on = s.eq_on;
        for b in &mut s.bands {
            *b = MultibandBand {
                ratio: if b.ratio.is_nan() { 1.0 } else { b.ratio.max(1.0) },
                threshold_db: (if b.threshold_db.is_nan() { 0.0 } else { b.threshold_db }).clamp(-100.0, 0.0),
                // EQ off (the EQ head's switch): the bands still compress but add no gain.
                gain_db: if eq_on {
                    (if b.gain_db.is_nan() { 0.0 } else { b.gain_db }).clamp(-40.0, 40.0)
                } else {
                    0.0
                },
                ..*b
            };
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eq_off_drops_the_band_gains_and_old_projects_load_as_on() {
        let mut s = MultibandCompressorSettings::new(
            vec![120.0, 700.0, 3000.0],
            vec![MultibandBand::with_gain(-30.0, 2.0, 10.0, 100.0, 6.0); 4],
        );
        assert!(s.eq_on);
        assert_eq!(s.normalized(48_000.0).bands[0].gain_db, 6.0);
        s.eq_on = false;
        assert_eq!(s.normalized(48_000.0).bands[0].gain_db, 0.0);
        // A project saved before the switch existed has no `eqOn` key.
        let mut json: serde_json::Value = serde_json::to_value(&s).unwrap();
        json.as_object_mut().unwrap().remove("eqOn");
        let old: MultibandCompressorSettings = serde_json::from_value(json).unwrap();
        assert!(old.eq_on);
    }
    use crate::gain::sig;
    use crate::presets::TrackAudioPreset;

    const XO: [f64; 3] = [100.0, 1000.0, 10000.0];

    /// Only `band` compresses (threshold -30 dB, ratio 4); the others are ratio 1.
    fn settings(band: usize, gain_db: f64, attack: f64, release: f64) -> MultibandCompressorSettings {
        let mut s = MultibandCompressorSettings::neutral();
        s.bypass = false;
        s.crossovers_hz = XO.to_vec();
        s.bands[band] = MultibandBand::with_gain(-30.0, 4.0, attack, release, gain_db);
        s
    }

    fn flat() -> MultibandCompressorSettings {
        let mut s = MultibandCompressorSettings::neutral();
        s.bypass = false;
        s.crossovers_hz = XO.to_vec();
        s
    }

    fn run(s: &MultibandCompressorSettings, x: &[f32]) -> Vec<f32> {
        let mut c = MultibandCompressor::new(s, 48000.0, 1);
        let mut b = vec![x.to_vec()];
        c.process_planar(&mut b);
        b.remove(0)
    }

    fn amp_db(x: &[f32], f: f64) -> f64 {
        sig::db(sig::amplitude(x, f, 48000))
    }

    #[test]
    fn a_bypassed_compressor_still_applies_the_eq_gains_and_nothing_else() {
        let mut s = flat();
        s.bypass = true;
        s.bands[2] = MultibandBand::with_gain(-30.0, 4.0, 5.0, 500.0, 6.0);
        s.makeup_gain_db = 9.0;
        let x = sig::mono(3000.0, -10.0, 2.0, 48000);
        let y = run(&s, &x);
        let gain = amp_db(&y[48000..], 3000.0) - amp_db(&x[48000..], 3000.0);
        assert!((gain - 6.0).abs() < 0.5, "EQ gain only, no compression or make-up: {gain} dB");
        s.eq_on = false;
        let y = run(&s, &x);
        let gain = amp_db(&y[48000..], 3000.0) - amp_db(&x[48000..], 3000.0);
        assert!(gain.abs() < 0.1, "EQ off and compressor off: untouched, {gain} dB");
    }

    #[test]
    fn recombined_bands_are_flat() {
        let s = flat(); // ratio 1 everywhere: no compression
        for f in [30.0, 100.0, 316.0, 1000.0, 3000.0, 8000.0, 10000.0, 15000.0] {
            let x = sig::mono(f, -12.0, 1.0, 48000);
            let y = run(&s, &x);
            let a = amp_db(&y[24000..], f) - amp_db(&x[24000..], f);
            assert!(a.abs() < 0.1, "{f} Hz: {a} dB");
        }
    }

    #[test]
    fn recombined_noise_keeps_energy() {
        let x = sig::noise(0.3, 96000, 1);
        let y = run(&flat(), &x);
        // Allpass sum: energy preserved; a bad (out-of-phase) recombination would notch it.
        let d = sig::db(sig::rms(&y[4800..])) - sig::db(sig::rms(&x[4800..]));
        assert!(d.abs() < 0.1, "{d} dB");
    }

    #[test]
    fn static_curve_per_band() {
        for (band, freq) in [(0, 25.0), (1, 316.0), (2, 3000.0), (3, 20000.0)] {
            for (level_db, expected_gr) in [(-10.0, 15.0), (-20.0, 7.5), (-40.0, 0.0)] {
                // release long enough to be flat over the period of a 25 Hz tone
                let s = settings(band, 2.0, 5.0, 5000.0);
                let x = sig::mono(freq, level_db, 3.0, 48000);
                let y = run(&s, &x);
                let out_db = amp_db(&y[96000..], freq);
                let expected = level_db - expected_gr + 2.0;
                assert!(
                    (out_db - expected).abs() < 0.75,
                    "band {band} in {level_db}: out {out_db} expected {expected}"
                );
            }
        }
    }

    #[test]
    fn other_bands_are_unaffected() {
        let s = settings(2, 0.0, 5.0, 500.0);
        let loud = sig::mono(3000.0, -10.0, 2.0, 48000);
        let quiet = sig::mono(25.0, -40.0, 2.0, 48000);
        let mix: Vec<f32> = loud.iter().zip(&quiet).map(|(a, b)| a + b).collect();
        let y = run(&s, &mix);
        let (low_out, low_in) = (amp_db(&y[48000..], 25.0), amp_db(&quiet[48000..], 25.0));
        assert!((low_out - low_in).abs() < 0.1, "{}", low_out - low_in);
        assert!(amp_db(&y[48000..], 3000.0) < -10.0 - 10.0); // the loud band is compressed
    }

    /// Gain (dB) applied in a 1 ms window (3 whole periods of 3 kHz) starting at sample `at`, vs. input level.
    fn gain_db(y: &[f32], at: usize, input_db: f64) -> f64 {
        amp_db(&y[at..at + 48], 3000.0) - input_db
    }

    #[test]
    fn attack_time_constant() {
        let tau = 10.0;
        let s = settings(2, 0.0, tau, 100.0);
        let (n, on) = (48000, 4800);
        let mut x = vec![0.0_f32; n];
        let t = sig::mono(3000.0, -10.0, 1.0, 48000);
        x[on..n].copy_from_slice(&t[on..n]);
        let y = run(&s, &x);
        let steady = -15.0;
        for mult in [0.5, 1.0, 3.0] {
            let at = on + (tau * mult * 48.0) as usize;
            let expected = steady * (1.0 - f64::exp(-mult));
            let g = gain_db(&y, at, -10.0);
            assert!((g - expected).abs() < 1.0, "t={mult}tau: {g} vs {expected}");
        }
    }

    #[test]
    fn release_time_constant() {
        let tau = 50.0;
        let s = settings(2, 0.0, 1.0, tau);
        let on = 24000;
        let mut x = sig::mono(3000.0, -10.0, 2.0, 48000);
        for v in &mut x[on..] {
            *v *= 0.01; // drops to -50 dB, far below threshold
        }
        let y = run(&s, &x);
        assert!((gain_db(&y, on - 2400, -10.0) + 15.0).abs() < 1.0); // steady before (short release: some ripple)
        for mult in [0.5, 1.0, 2.0] {
            let at = on + (tau * mult * 48.0) as usize;
            let expected = -15.0 * f64::exp(-mult);
            let g = gain_db(&y, at, -50.0);
            assert!((g - expected).abs() < 1.5, "t={mult}tau: {g} vs {expected}");
        }
        assert!(gain_db(&y, on + (tau * 8.0 * 48.0) as usize, -50.0).abs() < 0.2);
    }

    #[test]
    fn bypass_is_transparent() {
        let mut s = settings(2, 0.0, 5.0, 500.0);
        s.bypass = true;
        let x = sig::noise(0.5, 5000, 1);
        assert_eq!(run(&s, &x), x);
    }

    #[test]
    fn makeup_and_pre_gain() {
        let mut s = flat();
        s.pre_gain_db = -6.0;
        s.makeup_gain_db = 10.0;
        let x = sig::mono(3000.0, -30.0, 1.0, 48000);
        let y = run(&s, &x);
        assert!((amp_db(&y[24000..], 3000.0) - (-30.0 + 4.0)).abs() < 0.1);
    }

    #[test]
    fn chunking_matches_one_shot() {
        let s = TrackAudioPreset::voice().compressor;
        let n = 48000;
        let x = vec![sig::noise(0.4, n, 7), sig::noise(0.4, n, 8)];
        let mut whole = x.clone();
        MultibandCompressor::new(&s, 48000.0, 2).process_planar(&mut whole);
        let mut c = MultibandCompressor::new(&s, 48000.0, 2);
        let parts: Vec<Vec<Vec<f32>>> = sig::chunked(&x, &[1, 7, 480, 1000, 33, 4097])
            .into_iter()
            .map(|mut p| {
                c.process_planar(&mut p);
                p
            })
            .collect();
        assert_eq!(sig::concat(&parts, 2), whole);
    }

    #[test]
    fn stereo_is_linked() {
        let mut s = settings(2, 0.0, 5.0, 500.0);
        s.bands[2].attack_ms = 1.0;
        let mut b = vec![sig::mono(3000.0, -10.0, 1.0, 48000), sig::mono(3000.0, -40.0, 1.0, 48000)];
        MultibandCompressor::new(&s, 48000.0, 2).process_planar(&mut b);
        let gl = amp_db(&b[0][24000..], 3000.0) + 10.0;
        let gr = amp_db(&b[1][24000..], 3000.0) + 40.0;
        assert!((gl - gr).abs() < 0.2); // same gain on both channels
    }

    #[test]
    fn settings_are_validated() {
        let mut s = MultibandCompressorSettings::neutral();
        s.crossovers_hz = vec![5.0, 10.0, 99999.0];
        let n = s.normalized(48000.0);
        assert!(n.crossovers_hz[0] >= 20.0 && n.crossovers_hz[2] <= 24000.0 * 0.95);
        assert!(n.crossovers_hz[0] < n.crossovers_hz[1] && n.crossovers_hz[1] < n.crossovers_hz[2]);
        s.bands[0].ratio = 0.2;
        assert_eq!(s.normalized(48000.0).bands[0].ratio, 1.0);
    }
}
