//! Port of `SQAudioFX/Sources/SQAudioFX/ParametricEQ.swift`.

use crate::clip_audio_fxchain::ClipAudioFXChain;
use crate::lookahead_limiter::LookaheadLimiter;
use crate::multiband::{MultibandCompressor, MultibandConfig};
use crate::multiband_meters::MultibandMeterTap;
use crate::presets::MultibandCompressorSettings;
use sq_core_audio::audio_effects::{AudioMultibandValues, AudioPEQBand, AudioParametricEQValues};
use sq_core_time::Id;

const PI: f64 = std::f64::consts::PI;

/// RBJ biquad coefficients for the 5-band Parametric EQ (HP, low shelf, 5 peaks, high shelf, LP). Pure functions, shared by
/// the chain stage and the tests (magnitude response).
pub(crate) enum PEQBiquad {}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Coef {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl Default for Coef {
    fn default() -> Self {
        Coef { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0 }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct Mem {
    pub z1: f64,
    pub z2: f64,
}

impl PEQBiquad {
    pub(crate) fn clamp_hz(hz: f64, fs: f64) -> f64 {
        (if hz.is_nan() { 1_000.0 } else { hz }).max(10.0).min(fs * 0.45)
    }

    pub(crate) fn peak(hz: f64, gain_db: f64, q: f64, fs: f64) -> Coef {
        let a = 10.0_f64.powf(gain_db / 40.0);
        let w = 2.0 * PI * Self::clamp_hz(hz, fs) / fs;
        let alpha = w.sin() / (2.0 * q.max(0.05));
        let cw = w.cos();
        let a0 = 1.0 + alpha / a;
        Coef {
            b0: (1.0 + alpha * a) / a0,
            b1: -2.0 * cw / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: -2.0 * cw / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }

    /// RBJ shelf with Q (Q = 0.7071 is slope 1).
    pub(crate) fn shelf(low: bool, hz: f64, gain_db: f64, q: f64, fs: f64) -> Coef {
        let a = 10.0_f64.powf(gain_db / 40.0);
        let w = 2.0 * PI * Self::clamp_hz(hz, fs) / fs;
        let cw = w.cos();
        let alpha = w.sin() / (2.0 * q.max(0.05));
        let sa = 2.0 * a.sqrt() * alpha;
        let (b0, b1, b2, a0, a1, a2);
        if low {
            b0 = a * ((a + 1.0) - (a - 1.0) * cw + sa);
            b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cw);
            b2 = a * ((a + 1.0) - (a - 1.0) * cw - sa);
            a0 = (a + 1.0) + (a - 1.0) * cw + sa;
            a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cw);
            a2 = (a + 1.0) + (a - 1.0) * cw - sa;
        } else {
            b0 = a * ((a + 1.0) + (a - 1.0) * cw + sa);
            b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cw);
            b2 = a * ((a + 1.0) + (a - 1.0) * cw - sa);
            a0 = (a + 1.0) - (a - 1.0) * cw + sa;
            a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cw);
            a2 = (a + 1.0) - (a - 1.0) * cw - sa;
        }
        Coef { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
    }

    /// 2nd-order Butterworth high-pass (12 dB/oct) or low-pass.
    pub(crate) fn cut(high: bool, hz: f64, fs: f64) -> Coef {
        let w = 2.0 * PI * Self::clamp_hz(hz, fs) / fs;
        let cw = w.cos();
        let alpha = w.sin() / (2.0 * 0.5_f64.sqrt());
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cw / a0;
        let a2 = (1.0 - alpha) / a0;
        if high {
            Coef { b0: (1.0 + cw) / 2.0 / a0, b1: -(1.0 + cw) / a0, b2: (1.0 + cw) / 2.0 / a0, a1, a2 }
        } else {
            Coef { b0: (1.0 - cw) / 2.0 / a0, b1: (1.0 - cw) / a0, b2: (1.0 - cw) / 2.0 / a0, a1, a2 }
        }
    }

    pub(crate) fn coef(filter: usize, b: &AudioPEQBand, fs: f64) -> Coef {
        match filter {
            0 => Self::cut(true, b.hz, fs),
            1 => Self::shelf(true, b.hz, b.gain_db, b.q, fs),
            7 => Self::shelf(false, b.hz, b.gain_db, b.q, fs),
            8 => Self::cut(false, b.hz, fs),
            _ => Self::peak(b.hz, b.gain_db, b.q, fs),
        }
    }

    /// |H| in dB at `hz`.
    pub(crate) fn magnitude_db(c: &Coef, hz: f64, fs: f64) -> f64 {
        let w = 2.0 * PI * hz / fs;
        let (c1, s1, c2, s2) = (w.cos(), w.sin(), (2.0 * w).cos(), (2.0 * w).sin());
        let nr = c.b0 + c.b1 * c1 + c.b2 * c2;
        let ni = -(c.b1 * s1 + c.b2 * s2);
        let dr = 1.0 + c.a1 * c1 + c.a2 * c2;
        let di = -(c.a1 * s1 + c.a2 * s2);
        10.0 * ((nr * nr + ni * ni) / (dr * dr + di * di)).log10()
    }

    /// Combined response of every enabled filter of `v` at `hz`.
    pub(crate) fn total_magnitude_db(v: &AudioParametricEQValues, hz: f64, fs: f64) -> f64 {
        let mut sum = 0.0;
        for i in 0..AudioParametricEQValues::BAND_COUNT {
            let b = v.band(i);
            if b.on {
                sum += Self::magnitude_db(&Self::coef(i, &b, fs), hz, fs);
            }
        }
        sum
    }
}

/// The 5-band Parametric EQ stage of a clip chain. Coefficients follow the values (ramped every `RAMP_CHUNK` samples), filter
/// memory stays; a filter that is off is skipped and its memory cleared.
pub(crate) struct ParametricEQStage {
    coefs: [Coef; AudioParametricEQValues::BAND_COUNT],
    mem: Vec<Mem>,
    channels: usize,
    values: Option<AudioParametricEQValues>,
    pub was_off: bool,
}

impl ParametricEQStage {
    const N: usize = AudioParametricEQValues::BAND_COUNT;

    pub(crate) fn new(channels: usize) -> Self {
        ParametricEQStage {
            coefs: [Coef::default(); Self::N],
            mem: vec![Mem::default(); channels * Self::N],
            channels,
            values: None,
            was_off: false,
        }
    }

    pub(crate) fn reset(&mut self) {
        self.mem.fill(Mem::default());
    }

    fn set(&mut self, v: &AudioParametricEQValues, fs: f64) {
        if self.values.as_ref() == Some(v) {
            return;
        }
        for i in 0..Self::N {
            if let Some(old) = &self.values
                && old.band(i) == v.band(i)
            {
                continue;
            }
            self.coefs[i] = PEQBiquad::coef(i, &v.band(i), fs);
        }
        self.values = Some(*v);
    }

    /// A band switching off fades its gain to 0 dB across the block (then it is dropped); one switching on fades in from 0 dB.
    /// `t_end` = position of the chunk's end, so the fade is complete when the block ends.
    fn lerp(a: &AudioPEQBand, b: &AudioPEQBand, t: f64, t_end: f64) -> AudioPEQBand {
        let mut r = AudioPEQBand {
            on: b.on,
            hz: a.hz + (b.hz - a.hz) * t,
            gain_db: a.gain_db + (b.gain_db - a.gain_db) * t,
            q: a.q + (b.q - a.q) * t,
        };
        if a.on && !b.on {
            r.on = true;
            r.hz = a.hz;
            r.q = a.q;
            r.gain_db = a.gain_db * (1.0 - t_end);
        } else if !a.on && b.on {
            r.gain_db = b.gain_db * t_end;
        }
        r
    }

    /// Values `v0` at the first sample moving linearly towards `v1` one block later.
    pub(crate) fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        v0: &AudioParametricEQValues,
        v1: &AudioParametricEQValues,
        fs: f64,
    ) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        if v0 == v1 {
            self.set(v0, fs);
            self.run(buf, 0, n);
            return;
        }
        let mut s = 0;
        while s < n {
            let k = ClipAudioFXChain::RAMP_CHUNK.min(n - s);
            let t = s as f64 / n as f64;
            let te = (s + k) as f64 / n as f64;
            let bands = std::array::from_fn(|i| Self::lerp(&v0.band(i), &v1.band(i), t, te));
            self.set(&AudioParametricEQValues { bands }, fs);
            self.run(buf, s, k);
            s += k;
        }
    }

    fn run(&mut self, buf: &mut [&mut [f32]], from: usize, n: usize) {
        let Some(v) = self.values else { return };
        for (c, chan) in buf.iter_mut().enumerate().take(self.channels) {
            let p = &mut chan[from..from + n];
            for k in 0..Self::N {
                let band = v.band(k);
                if !band.on {
                    self.mem[c * Self::N + k] = Mem::default();
                    continue;
                }
                // A shelf or peak at 0 dB is the identity: skipped once its memory is empty (never cut while it still rings).
                let mut m = self.mem[c * Self::N + k];
                let flat = (1..=7).contains(&k) && band.gain_db == 0.0;
                if flat && m.z1 == 0.0 && m.z2 == 0.0 {
                    continue;
                }
                let q = self.coefs[k];
                for s in p.iter_mut() {
                    let x = f64::from(*s);
                    let y = q.b0 * x + m.z1;
                    m.z1 = q.b1 * x - q.a1 * y + m.z2;
                    m.z2 = q.b2 * x - q.a2 * y;
                    *s = y as f32;
                }
                if flat && m.z1.abs() < 1e-9 && m.z2.abs() < 1e-9 {
                    m = Mem::default();
                }
                self.mem[c * Self::N + k] = m;
            }
        }
    }
}

/// The Multiband Compressor clip stage: `MultibandCompressor` (4 bands, LR4 crossovers) fed from the clip effect's values,
/// then the output limiter (`LookaheadLimiter`). Output gain and band gains ramp from the block-start to the block-end value
/// every `RAMP_CHUNK` samples; thresholds, ratios, times and crossovers apply from the block start (the Config is rebuilt only
/// when they change). Allocation-free while the gains are not ramped.
///
/// Latency: `LATENCY` samples (the limiter's look-ahead), always, also with the limiter off or the effect disabled, so the
/// chain's latency depends on the layout only.
pub(crate) struct MultibandStage {
    comp: MultibandCompressor,
    /// Last values the Config was built from (gains zeroed).
    settled: Option<AudioMultibandValues>,
    sample_rate: f64,
    channels: usize,
    /// Output limiter (Premiere's Multiband Limiter): `limiter_gain_db` in front, then a look-ahead brickwall at the margin.
    limiter: LookaheadLimiter,
    pub was_off: bool,
    /// The clip effect's id, split for `MultibandMeterTap` (one atomic compare per block decides whether to publish).
    id_hi: u64,
    id_lo: u64,
    meters: &'static MultibandMeterTap,
}

impl MultibandStage {
    pub(crate) const LOOKAHEAD_MS: f64 = 5.0;
    /// Fixed latency of every multiband slot at 48 kHz (240 samples).
    pub(crate) const LATENCY: usize = (ClipAudioFXChain::SAMPLE_RATE as f64 * Self::LOOKAHEAD_MS / 1000.0) as usize;

    pub(crate) fn new(sample_rate: f64, channels: usize, id: Id, meters: &'static MultibandMeterTap) -> Self {
        let (id_hi, id_lo) = MultibandMeterTap::split(id);
        MultibandStage {
            comp: MultibandCompressor::new(&MultibandCompressorSettings::neutral(), sample_rate, channels),
            settled: None,
            sample_rate,
            channels,
            limiter: LookaheadLimiter::with_times(sample_rate, channels, Self::LOOKAHEAD_MS, -0.1, 500.0, 5.0),
            was_off: false,
            id_hi,
            id_lo,
            meters,
        }
    }

    pub(crate) fn reset(&mut self) {
        self.comp.reset();
        self.limiter.reset();
    }

    /// The effect is switched off: the sound passes unchanged, still delayed by `LATENCY`.
    pub(crate) fn bypass(&mut self, buf: &mut [&mut [f32]], n: usize) {
        self.was_off = true;
        let c = buf.len().min(self.channels);
        self.limiter.delay_only(&mut buf[..c], n);
    }

    pub(crate) fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        v0: &AudioMultibandValues,
        v1: &AudioMultibandValues,
    ) {
        if self.was_off {
            self.comp.reset();
            self.was_off = false;
        }
        let mut key = *v0;
        key.output_gain_db = 0.0;
        key.gain_db = [0.0; 4];
        if self.settled != Some(key) {
            self.comp.apply(&MultibandConfig::from_values(v0, self.sample_rate), true);
            self.settled = Some(key);
        }
        let ramped = v0.output_gain_db != v1.output_gain_db || v0.gain_db != v1.gain_db;
        if !ramped {
            self.comp.set_gains(v0.output_gain_db, v0.gain_db);
        }
        let c = buf.len().min(self.channels);
        if ramped {
            // shortcut: one Vec of channel views per block while the gains ramp; upgrade by letting the compressor take an offset.
            let mut rest: Vec<&mut [f32]> = buf[..c].iter_mut().map(|ch| &mut ch[..]).collect();
            let mut s = 0;
            while s < n {
                let k = ClipAudioFXChain::RAMP_CHUNK.min(n - s);
                let t = s as f64 / n as f64;
                let band_db = std::array::from_fn(|i| v0.gain_db[i] + (v1.gain_db[i] - v0.gain_db[i]) * t);
                self.comp.set_gains(v0.output_gain_db + (v1.output_gain_db - v0.output_gain_db) * t, band_db);
                self.comp.process(&mut rest, k);
                for r in rest.iter_mut() {
                    *r = &mut std::mem::take(r)[k..];
                }
                s += k;
            }
        } else {
            self.comp.process(&mut buf[..c], n);
        }
        if v0.limiter_on {
            let g1 = if v1.limiter_on { v1.limiter_gain_db() } else { v0.limiter_gain_db() };
            ClipAudioFXChain::ramp(&mut buf[..c], n, v0.limiter_gain_db(), g1);
            let margin = (if v0.limiter_margin_db.is_nan() { -0.1 } else { v0.limiter_margin_db }).clamp(-18.0, 0.0);
            let release =
                (if v0.limiter_release_ms.is_nan() { 500.0 } else { v0.limiter_release_ms }).clamp(5.0, 5_000.0);
            let attack = (if v0.limiter_attack_ms.is_nan() { 0.0 } else { v0.limiter_attack_ms }).clamp(0.0, 500.0);
            self.limiter.configure(margin, release, attack);
        }
        // Safety: never NaN / inf out of this stage (one would poison every filter after it for good).
        for ch in buf[..c].iter_mut() {
            for s in &mut ch[..n] {
                if !s.is_finite() {
                    *s = 0.0;
                }
            }
        }
        self.limiter.process(&mut buf[..c], n, v0.limiter_on);
        let peak = self.comp.take_meter_peak();
        if self.meters.is_watched(self.id_hi, self.id_lo) {
            // Applied reduction: a bypassed band reduces nothing (its detector keeps running for a smooth return).
            let (gr, bypass) = (self.comp.gain_reduction_db(), self.comp.bypass_mix());
            let applied = std::array::from_fn(|i| gr[i] * (1.0 - bypass[i]));
            let lim = if v0.limiter_on { -self.limiter.gain_reduction_db() } else { 0.0 };
            self.meters.publish(peak, applied, lim);
        }
    }
}
