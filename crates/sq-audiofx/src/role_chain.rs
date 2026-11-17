// Swift: RoleChain.swift
//! Split-band de-esser and the offline role chain of a track.

use crate::gain::{AudioFXError, GainMath, VolumeAutomation};
use crate::limiter::MasterLimiter;
use crate::loudness::{Biquad, LoudnessMeter};
use crate::offline_audio_fx::OfflineAudioFX;
use crate::presets::TrackAudioPreset;
use sq_core_model::AudioTag;
use sq_core_time::Time;

/// Everything one channel keeps between samples.
#[derive(Clone, Copy, Debug)]
struct Chan {
    detector: Biquad,
    splitter: Biquad,
    splitter2: Biquad,
    lowpass: Biquad,
    lowpass2: Biquad,
    env_sib: f64,
    env_all: f64,
    /// Narrow range only: the upper edge of the reduced band.
    band_top: Biquad,
}

/// Split-band de-esser: a band-pass detector at the sibilance region drives gain reduction of the content above `split_hz`.
/// The trigger is relative (sibilance level against broadband level), so it needs no absolute threshold and works before
/// loudness normalization. Zero latency, state kept across `process` calls.
#[derive(Clone, Debug)]
pub struct DeEsser {
    pub sample_rate: i64,
    /// Sibilance/broadband envelope ratio above which reduction starts (0.35 = sibilance 9 dB under broadband).
    pub ratio_threshold: f64,
    /// Maximum reduction as linear gain of the high band.
    pub min_gain: f64,
    chan: Vec<Chan>,
    gain: f64,
    atk: f64,
    rel: f64,
    env_coef: f64,
    /// Narrow: only the band between the split and 1.3 x the center is reduced (`x - (1 - gain) x band`). Wide / All HF reduce
    /// everything above the split (the original path, bit for bit).
    narrow: bool,
    /// Output only what is being removed (`(1 - gain) x band`), for tuning.
    pub listen: bool,
    /// Per-sample high and low band of each channel (kept here so `process` never allocates).
    hi: Vec<f64>,
    lo: Vec<f64>,
}

impl DeEsser {
    /// De-esser with center 7 kHz, split 5 kHz, ratio threshold 0.35 and at most 10 dB of reduction.
    pub fn new(sample_rate: i64, channel_count: usize) -> Self {
        Self::with_params(sample_rate, channel_count, 7000.0, 5000.0, 0.35, 10.0)
    }

    /// De-esser with explicit center, split, ratio threshold and maximum reduction.
    pub fn with_params(
        sample_rate: i64,
        channel_count: usize,
        center_hz: f64,
        split_hz: f64,
        ratio_threshold: f64,
        max_reduction_db: f64,
    ) -> Self {
        let fs = sample_rate as f64;
        let (bp, hp, lp) = Self::filters(center_hz, split_hz, fs);
        let c = Chan {
            detector: bp,
            splitter: hp,
            splitter2: hp,
            lowpass: lp,
            lowpass2: lp,
            env_sib: 0.0,
            env_all: 0.0,
            band_top: Biquad::default(),
        };
        DeEsser {
            sample_rate,
            ratio_threshold,
            min_gain: GainMath::linear_from_db(-max_reduction_db.abs()),
            chan: vec![c; channel_count],
            gain: 1.0,
            atk: (-1.0 / (fs * 0.001)).exp(),
            rel: (-1.0 / (fs * 0.04)).exp(),
            env_coef: (-1.0 / (fs * 0.005)).exp(),
            narrow: false,
            listen: false,
            hi: vec![0.0; channel_count],
            lo: vec![0.0; channel_count],
        }
    }

    /// RBJ band-pass (constant 0 dB peak) and 2nd-order Butterworth high/low-pass pair, cascaded twice (Linkwitz-Riley 4th order: low + high sum is flat in level).
    fn filters(center_hz: f64, split_hz: f64, fs: f64) -> (Biquad, Biquad, Biquad) {
        let w0 = 2.0 * std::f64::consts::PI * center_hz.min(fs * 0.45) / fs;
        let q = 1.0;
        let al = w0.sin() / (2.0 * q);
        let a0 = 1.0 + al;
        let bp = Biquad::with_coefficients(al / a0, 0.0, -al / a0, -2.0 * w0.cos() / a0, (1.0 - al) / a0);
        let h0 = 2.0 * std::f64::consts::PI * split_hz.min(fs * 0.45) / fs;
        let hq = 7071.0 / 10_000.0; // the Swift literal 0.7071 (not 1/sqrt 2), written so clippy does not read it as a constant
        let ha = h0.sin() / (2.0 * hq);
        let hn = 1.0 + ha;
        let c = h0.cos();
        let hp = Biquad::with_coefficients(
            (1.0 + c) / 2.0 / hn,
            -(1.0 + c) / hn,
            (1.0 + c) / 2.0 / hn,
            -2.0 * c / hn,
            (1.0 - ha) / hn,
        );
        let lp = Biquad::with_coefficients(
            (1.0 - c) / 2.0 / hn,
            (1.0 - c) / hn,
            (1.0 - c) / 2.0 / hn,
            -2.0 * c / hn,
            (1.0 - ha) / hn,
        );
        (bp, hp, lp)
    }

    /// Where the de-esser listens and what it reduces, keeping all filter state (safe while playing). `range` 0 Narrow (a band
    /// around the center), 1 Wide (from 5/7 of the center up: 5 kHz at 7 kHz, the original), 2 All HF (from 0.4 x the center up).
    pub fn configure(&mut self, center_hz: f64, range: i64) {
        let fs = self.sample_rate as f64;
        let split = if range == 0 {
            center_hz * 0.8
        } else if range == 2 {
            center_hz * 0.4
        } else {
            center_hz * 5.0 / 7.0
        };
        let (bp, hp, lp) = Self::filters(center_hz, split, fs);
        let top = Self::filters(center_hz, center_hz * 1.3, fs).2;
        self.narrow = range == 0;
        for c in &mut self.chan {
            Self::set_coefficients(&mut c.detector, &bp);
            Self::set_coefficients(&mut c.splitter, &hp);
            Self::set_coefficients(&mut c.splitter2, &hp);
            Self::set_coefficients(&mut c.lowpass, &lp);
            Self::set_coefficients(&mut c.lowpass2, &lp);
            Self::set_coefficients(&mut c.band_top, &top);
        }
    }

    fn set_coefficients(b: &mut Biquad, c: &Biquad) {
        b.b0 = c.b0;
        b.b1 = c.b1;
        b.b2 = c.b2;
        b.a1 = c.a1;
        b.a2 = c.a2;
    }

    /// Reaction speed: 0 Fast (0.5 ms / 20 ms), 1 Medium (1 ms / 40 ms, the original), 2 Slow (2 ms / 100 ms). Times are ours (unsourced).
    pub fn set_speed(&mut self, speed: i64) {
        let fs = self.sample_rate as f64;
        let (a, r) = if speed == 0 {
            (0.0005, 0.02)
        } else if speed == 2 {
            (0.002, 0.1)
        } else {
            (0.001, 0.04)
        };
        self.atk = (-1.0 / (fs * a)).exp();
        self.rel = (-1.0 / (fs * r)).exp();
    }

    /// Forgets all filter, envelope and gain state (use on a seek).
    pub fn reset(&mut self) {
        for c in &mut self.chan {
            c.detector.reset();
            c.splitter.reset();
            c.splitter2.reset();
            c.lowpass.reset();
            c.lowpass2.reset();
            c.env_sib = 0.0;
            c.env_all = 0.0;
            c.band_top.reset();
        }
        self.gain = 1.0;
    }

    /// Planar channels as owned vectors (the offline path).
    pub fn process_planar(&mut self, buf: &mut [Vec<f32>]) {
        let n = buf.first().map_or(0, Vec::len);
        if n == 0 || buf.is_empty() {
            return;
        }
        let mut views: Vec<&mut [f32]> = buf.iter_mut().map(Vec::as_mut_slice).collect();
        self.process(&mut views, n);
    }

    /// In place on channel slices; does not allocate (the realtime path). The channel count must not exceed the constructor's.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize) {
        let chs = buf.len().min(self.chan.len());
        let (env_coef, ratio_threshold, min_gain, atk, rel) =
            (self.env_coef, self.ratio_threshold, self.min_gain, self.atk, self.rel);
        let mut gain = self.gain;
        let (narrow, listen) = (self.narrow, self.listen);
        for i in 0..n {
            let (mut sib, mut all) = (0.0_f64, 0.0_f64);
            for (c, chan) in buf.iter().enumerate().take(chs) {
                let cp = &mut self.chan[c];
                let x = f64::from(chan[i]);
                self.hi[c] = cp.splitter2.process(cp.splitter.process(x));
                self.lo[c] = cp.lowpass2.process(cp.lowpass.process(x));
                let s = cp.detector.process(x).abs();
                cp.env_sib = s.max(cp.env_sib * env_coef + s * (1.0 - env_coef));
                let a = x.abs();
                cp.env_all = a.max(cp.env_all * env_coef + a * (1.0 - env_coef));
                sib = sib.max(cp.env_sib);
                all = all.max(cp.env_all);
            }
            let mut target = 1.0;
            if all > 1e-6 && sib > ratio_threshold * all {
                target = min_gain.max(ratio_threshold * all / sib);
            }
            let k = if target < gain { atk } else { rel };
            gain = target + (gain - target) * k;
            if narrow || listen {
                for (c, chan) in buf.iter_mut().enumerate().take(chs) {
                    // Narrow cuts only the band (hi up to 1.3 x center); Wide / All HF cut everything above the split.
                    let band = if narrow { self.chan[c].band_top.process(self.hi[c]) } else { self.hi[c] };
                    let removed = (1.0 - gain) * band;
                    chan[i] = if listen { removed as f32 } else { (f64::from(chan[i]) - removed) as f32 };
                }
            } else {
                for (c, chan) in buf.iter_mut().enumerate().take(chs) {
                    chan[i] = (self.lo[c] + gain * self.hi[c]) as f32;
                }
            }
        }
        self.gain = gain;
    }
}

/// Offline role chain for a track: Voice (dialogue) = mono to stereo, noise reduction + EQ + compressor (the role preset incl. de-esser), loudness to -14 LUFS, true-peak limiter at -1 dBTP. Music and SFX = mono to stereo, role voicing, loudness to
/// -20 LUFS (`AudioTag::target_lufs`, i.e. 6 dB under the voice), same limiter. The loudness stage lands within a few tenths of
/// a LU; the limiter's ceiling is tightened until the measured 4x true peak is at or under the target.
pub enum RoleChain {}

impl RoleChain {
    /// The true-peak ceiling of the chain.
    pub const TRUE_PEAK_CEILING_DB: f64 = -1.0;
    /// Maximum boost the loudness stage may apply.
    pub const MAX_BOOST_DB: f64 = 24.0;

    /// iPhone/phone clips are mono: duplicate to stereo so the track pans and meters like the rest. Other counts pass through.
    pub fn mono_to_stereo(x: &[Vec<f32>]) -> Vec<Vec<f32>> {
        if x.len() == 1 { vec![x[0].clone(), x[0].clone()] } else { x.to_vec() }
    }

    /// Renders `input` for `role` with the default true-peak ceiling.
    pub fn render(input: &[Vec<f32>], role: AudioTag, sample_rate: i64) -> Result<Vec<Vec<f32>>, AudioFXError> {
        Self::render_with_ceiling(input, role, sample_rate, Self::TRUE_PEAK_CEILING_DB)
    }

    /// Renders `input` for `role` with an explicit true-peak ceiling.
    pub fn render_with_ceiling(
        input: &[Vec<f32>],
        role: AudioTag,
        sample_rate: i64,
        true_peak_ceiling_db: f64,
    ) -> Result<Vec<Vec<f32>>, AudioFXError> {
        let n = input.first().map_or(0, Vec::len);
        if n == 0 {
            return Ok(Self::mono_to_stereo(input));
        }
        let x = Self::mono_to_stereo(input);
        let mut fx = OfflineAudioFX::new(
            VolumeAutomation::new(0.0, None, None),
            TrackAudioPreset::for_role(role),
            sample_rate,
            x.len(),
        )?;
        let x = fx.render(&x, Time::ZERO).channels;
        Ok(Self::finish(&x, role.target_lufs(), sample_rate, true_peak_ceiling_db))
    }

    /// Loudness gain to the target (boost capped at `MAX_BOOST_DB`), then the limiter; up to 6 passes with corrected gain /
    /// ceiling. Returns the candidate with the true peak at or under `ceiling_db` that is closest to the target. If no pass
    /// gets under the ceiling, the last one is trimmed by exactly its overshoot (gain is linear in true peak), so the result
    /// never exceeds the ceiling. Clips without a gated loudness (< 400 ms or below -70 LUFS) get the limiter only; true
    /// silence is returned unchanged. Any channel count: channels are limited in linked pairs (an odd last one alone).
    pub fn finish(x: &[Vec<f32>], target_lufs: f64, sample_rate: i64, ceiling_db: f64) -> Vec<Vec<f32>> {
        let m0 = Self::measure(x, sample_rate);
        // Swift `guard truePeakDB > -120`: a NaN peak also returns the input.
        if m0.1.is_nan() || m0.1 <= -120.0 {
            return x.to_vec();
        }
        let mut gain_db = if m0.0.is_finite() { Self::MAX_BOOST_DB.min(target_lufs - m0.0) } else { 0.0 };
        let can_tune = m0.0.is_finite();
        let mut ceiling = ceiling_db;
        let mut best: Option<(Vec<Vec<f32>>, f64)> = None;
        let mut last = x.to_vec();
        let mut last_over = 0.0;
        for _ in 0..6 {
            let y = Self::limited(x, gain_db, sample_rate, ceiling);
            let m = Self::measure(&y, sample_rate);
            let over = m.1 - ceiling_db;
            let err = if can_tune { target_lufs - m.0 } else { 0.0 };
            if over <= 0.0 && best.as_ref().is_none_or(|b| err.abs() < b.1.abs()) {
                best = Some((y.clone(), err));
            }
            last = y;
            last_over = over;
            if over <= 0.0 && (err.abs() <= 0.3 || !can_tune) {
                break;
            }
            if over > 0.0 {
                ceiling -= over + 0.05;
            }
            if can_tune && err.abs() > 0.3 && err.is_finite() {
                gain_db = Self::MAX_BOOST_DB.min(gain_db + err);
            }
        }
        if let Some((y, _)) = best {
            return y;
        }
        let trim = GainMath::linear_from_db(-(last_over + 0.01)) as f32;
        last.iter().map(|c| c.iter().map(|v| v * trim).collect()).collect()
    }

    fn limited(x: &[Vec<f32>], gain_db: f64, sample_rate: i64, ceiling_db: f64) -> Vec<Vec<f32>> {
        let mut y = x.to_vec();
        let g = GainMath::linear_from_db(gain_db) as f32;
        for chan in &mut y {
            for v in chan.iter_mut() {
                *v *= g;
            }
        }
        let mut c = 0;
        while c < y.len() {
            let mut lim = MasterLimiter::new(sample_rate, ceiling_db);
            let mut l = y[c].clone();
            let mut r = if c + 1 < y.len() { y[c + 1].clone() } else { y[c].clone() };
            lim.process(&mut l, &mut r);
            y[c] = l;
            if c + 1 < y.len() {
                y[c + 1] = r;
            }
            c += 2;
        }
        y
    }

    /// Integrated loudness (LUFS) and the highest true peak (dBTP) of `x`.
    pub fn measure(x: &[Vec<f32>], sample_rate: i64) -> (f64, f64) {
        let mut m = LoudnessMeter::new(sample_rate, x.len(), None);
        m.process(x);
        (m.integrated(), m.true_peak_db().into_iter().reduce(f64::max).unwrap_or(f64::NEG_INFINITY))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;

    /// Speech-like synthetic: harmonic pitch glide (12 harmonics) with a syllable envelope, plus a little hiss.
    fn voice(seconds: f64, rate: i64, peak_db: f64) -> Vec<f32> {
        let n = (seconds * rate as f64) as usize;
        let noise = sig::noise(1.0, n, 7);
        let mut phase = 0.0;
        let mut out = vec![0.0_f32; n];
        let two_pi = 2.0 * std::f64::consts::PI;
        for (i, o) in out.iter_mut().enumerate() {
            let t = i as f64 / rate as f64;
            let f0 = 140.0 + 30.0 * (two_pi * 0.7 * t).sin();
            phase += two_pi * f0 / rate as f64;
            let mut s = 0.0;
            for h in 1..=12 {
                s += (f64::from(h) * phase).sin() / f64::from(h);
            }
            let env = 0.15 + 0.85 * (two_pi * 3.5 * t).sin().max(0.0);
            *o = (s * env * 0.3 + f64::from(noise[i]) * 0.003) as f32;
        }
        let a = 10.0_f32.powf(peak_db as f32 / 20.0) / out.iter().fold(0.0_f32, |m, v| m.max(v.abs()));
        out.iter().map(|v| v * a).collect()
    }

    /// Amplitude of the `freq` component (correlation with sin/cos over the second half).
    fn component(x: &[f32], freq: f64, rate: i64) -> f64 {
        let (mut a, mut b) = (0.0, 0.0);
        let from = x.len() / 2;
        for (i, v) in x.iter().enumerate().skip(from) {
            let ph = 2.0 * std::f64::consts::PI * freq * i as f64 / rate as f64;
            a += f64::from(*v) * ph.sin();
            b += f64::from(*v) * ph.cos();
        }
        2.0 * (a * a + b * b).sqrt() / (x.len() - from) as f64
    }

    fn two_tones() -> (Vec<f32>, Vec<f32>, Vec<f32>) {
        let low = sig::sine(300.0, -12.0, 1.0, 48_000, 1, 0.0).remove(0);
        let hiss = sig::sine(7000.0, -12.0, 1.0, 48_000, 1, 0.0).remove(0);
        let mix = low.iter().zip(&hiss).map(|(a, b)| a + b).collect();
        (low, hiss, mix)
    }

    #[test]
    fn voice_lands_at_minus_14_with_true_peak_under_minus_1() {
        let mono = voice(12.0, 48_000, -3.0);
        let out = RoleChain::render(std::slice::from_ref(&mono), AudioTag::Dialogue, 48_000).unwrap_or_default();
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].len(), mono.len());
        let m = RoleChain::measure(&out, 48_000);
        assert!((m.0 - -14.0).abs() <= 0.4, "lufs {}", m.0);
        assert!(m.1 <= -1.0, "tp {}", m.1);
    }

    #[test]
    fn hot_voice_still_respects_ceiling() {
        let x = voice(8.0, 48_000, -0.1);
        let out = RoleChain::render(&[x.clone(), x], AudioTag::Dialogue, 48_000).unwrap_or_default();
        let m = RoleChain::measure(&out, 48_000);
        assert!((m.0 - -14.0).abs() <= 0.4, "lufs {}", m.0);
        assert!(m.1 <= -1.0, "tp {}", m.1);
    }

    #[test]
    fn music_sits_six_db_under_voice() {
        let tone = sig::sine(440.0, -12.0, 6.0, 48_000, 2, 0.0);
        let out = RoleChain::render(&tone, AudioTag::Music, 48_000).unwrap_or_default();
        let m = RoleChain::measure(&out, 48_000);
        assert!((m.0 - -20.0).abs() <= 0.4, "lufs {}", m.0);
        assert!(m.1 <= -1.0);
    }

    #[test]
    fn mono_becomes_identical_stereo() {
        assert_eq!(RoleChain::mono_to_stereo(&[vec![0.1, 0.2]]), vec![vec![0.1, 0.2], vec![0.1, 0.2]]);
        assert_eq!(RoleChain::mono_to_stereo(&[vec![1.0], vec![2.0]]), vec![vec![1.0], vec![2.0]]);
    }

    #[test]
    fn de_esser_crossover_is_flat_in_level() {
        for rate in [44_100_i64, 48_000, 96_000] {
            for f in [200.0, 1000.0, 3000.0, 4800.0, 5200.0, 8000.0] {
                let mut buf = sig::sine(f, -12.0, 1.0, rate, 1, 0.0);
                let reference = component(&buf[0], f, rate);
                let mut d = DeEsser::with_params(rate, 1, 7000.0, 5000.0, 1000.0, 10.0); // never triggers
                d.process_planar(&mut buf);
                let ratio = component(&buf[0], f, rate) / reference;
                assert!((20.0 * ratio.log10()).abs() < 0.1, "{rate} Hz {f}: {ratio}");
            }
        }
    }

    #[test]
    fn de_esser_leaves_speech_alone() {
        let v = voice(4.0, 48_000, -3.0);
        let mut buf = vec![v.clone()];
        DeEsser::new(48_000, 1).process_planar(&mut buf);
        let db = 20.0 * (sig::rms(&buf[0][24000..]) / sig::rms(&v[24000..])).log10();
        assert!(db.abs() < 0.2, "{db}");
    }

    #[test]
    fn de_esser_reduces_sibilance_by_three_to_ten_db() {
        let (low, hiss, mix) = two_tones();
        let mut buf = vec![mix];
        DeEsser::new(48_000, 1).process_planar(&mut buf);
        let sib_db = 20.0 * (component(&buf[0], 7000.0, 48_000) / component(&hiss, 7000.0, 48_000)).log10();
        let low_db = 20.0 * (component(&buf[0], 300.0, 48_000) / component(&low, 300.0, 48_000)).log10();
        assert!(sib_db < -2.5 && sib_db > -10.5, "sib {sib_db}");
        assert!(low_db.abs() < 0.2, "low {low_db}");
    }

    #[test]
    fn de_esser_state_continues_across_buffers() {
        let (_, _, whole) = two_tones();
        let mut a = vec![whole.clone()];
        DeEsser::new(48_000, 1).process_planar(&mut a);
        let mut d2 = DeEsser::new(48_000, 1);
        let mut out: Vec<f32> = vec![];
        let mut pos = 0;
        for size in [1, 77, 1000, 4096, 333] {
            if pos >= whole.len() {
                break;
            }
            let mut chunk = vec![whole[pos..whole.len().min(pos + size)].to_vec()];
            d2.process_planar(&mut chunk);
            out.extend(&chunk[0]);
            pos += size;
        }
        let mut rest = vec![whole[pos..].to_vec()];
        d2.process_planar(&mut rest);
        out.extend(&rest[0]);
        assert_eq!(out, a[0]);
    }

    #[test]
    fn other_sample_rates_and_silence() {
        // The denoiser of the Dialogue preset runs at other rates through the portable resampler (Swift: AVAudioConverter).
        for rate in [44_100_i64, 96_000] {
            let x = [voice(8.0, rate, -3.0)];
            let dialogue = RoleChain::render(&x, AudioTag::Dialogue, rate).expect("dialogue at another rate");
            assert_eq!(dialogue[0].len(), x[0].len(), "{rate}");
            let d = RoleChain::measure(&dialogue, rate);
            assert!((d.0 - AudioTag::Dialogue.target_lufs()).abs() <= 1.0 && d.1 <= -1.0, "{rate}: {d:?}");
            let out = RoleChain::render(&x, AudioTag::Music, rate).unwrap_or_default();
            let m = RoleChain::measure(&out, rate);
            assert!((m.0 - -20.0).abs() <= 0.4 && m.1 <= -1.0, "{rate}: {m:?}");
        }
        let silent = RoleChain::render(&[vec![0.0; 48_000]], AudioTag::Dialogue, 48_000).unwrap_or_default();
        assert!(silent.len() == 2 && silent[0].iter().all(|v| *v == 0.0));
    }

    /// The role preset (what playback and export run per track) tames sibilance; without the de-esser it does not.
    #[test]
    fn role_preset_de_esses_in_the_shared_fx_path() {
        let n = 48_000;
        let sib: Vec<f32> = (0..n)
            .map(|i| {
                (0.2 * (2.0 * std::f64::consts::PI * 7000.0 * i as f64 / 48_000.0).sin()) as f32
                    * if i % 24_000 < 12_000 { 1.0 } else { 0.0 }
            })
            .collect();
        let level = |preset: TrackAudioPreset| {
            let p = TrackAudioPreset { noise_reduction: 0.0, ..preset };
            let mut fx = OfflineAudioFX::new(VolumeAutomation::new(0.0, None, None), p, 48_000, 1).unwrap();
            let y = fx.render(std::slice::from_ref(&sib), Time::ZERO).channels.remove(0);
            component(&y[6000..12_000], 7000.0, 48_000)
        };
        let voiced = level(TrackAudioPreset::for_role(AudioTag::Dialogue));
        let plain = level(TrackAudioPreset { de_ess: false, ..TrackAudioPreset::for_role(AudioTag::Dialogue) });
        assert!(voiced < plain * 0.8, "voice {voiced} plain {plain}");
    }

    #[test]
    fn short_loud_clip_stays_under_ceiling() {
        let click = voice(0.25, 48_000, 0.0);
        for role in [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx] {
            let out = RoleChain::render(std::slice::from_ref(&click), role, 48_000).unwrap_or_default();
            assert!(RoleChain::measure(&out, 48_000).1 <= -1.0);
        }
        let direct = RoleChain::finish(&[click.clone(), click], -14.0, 48_000, -1.0);
        assert!(RoleChain::measure(&direct, 48_000).1 <= -1.0);
    }

    #[test]
    fn boost_is_capped() {
        let quiet = sig::sine(440.0, -50.0, 3.0, 48_000, 2, 0.0);
        let out = RoleChain::finish(&quiet, -14.0, 48_000, -1.0);
        let gain = RoleChain::measure(&out, 48_000).0 - RoleChain::measure(&quiet, 48_000).0;
        assert!(gain <= RoleChain::MAX_BOOST_DB + 0.1, "{gain}");
    }

    #[test]
    fn three_and_six_channels_are_limited() {
        let v = voice(3.0, 48_000, 0.0);
        for count in [3, 4, 6] {
            let out = RoleChain::finish(&vec![v.clone(); count], -14.0, 48_000, -1.0);
            assert_eq!(out.len(), count);
            assert!(RoleChain::measure(&out, 48_000).1 <= -1.0, "{count}");
        }
    }

    #[test]
    fn only_the_voice_role_de_esses() {
        assert!(TrackAudioPreset::for_role(AudioTag::Dialogue).de_ess);
        assert!(!TrackAudioPreset::for_role(AudioTag::Music).de_ess);
        assert!(!TrackAudioPreset::for_role(AudioTag::Sfx).de_ess);
    }
}
