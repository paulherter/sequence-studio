// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DenoiseStage.swift
//! RNNoise at any sample rate: converts to 48 kHz, denoises, converts back (Swift uses `AVAudioConverter`; here a
//! streaming windowed-sinc resampler, no extra dependency).
//!
//! `process` returns exactly as many samples as it is given. The output is delayed by `latency_samples()` (at the
//! caller's rate); at 48 kHz that is the denoiser's 480 samples, otherwise it is measured once at construction by
//! pushing an impulse through the whole stage, so it includes both resamplers. Streaming-safe, not thread-safe.

use crate::gain::AudioFXError;
use crate::rnnoise_denoiser::RNNoiseDenoiser;

/// Zero samples queued ahead of the resampler output so a short call never starves `process`.
const SAFETY_PAD: usize = 256;
/// Kernel half width in zero crossings of the lower rate.
const HALF_WIDTH: f64 = 24.0;
/// Table phases per input sample (linear interpolation between them).
const PHASES: usize = 512;

/// Streaming windowed-sinc resampler for one channel.
struct Resampler {
    /// Input samples advanced per output sample.
    step: f64,
    /// Kernel half width in input samples.
    half: usize,
    /// `table[p * (2 * half + 1) ..]`: kernel values at offset `p / PHASES` of an input sample.
    table: Vec<f32>,
    /// Input held back; `buf[0]` is input sample `base`.
    buf: Vec<f32>,
    base: i64,
    /// Input position of the next output sample.
    pos: f64,
}

fn bessel_i0(x: f64) -> f64 {
    let (mut sum, mut term, mut k) = (1.0, 1.0, 1.0);
    while term > 1e-12 * sum {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        k += 1.0;
    }
    sum
}

impl Resampler {
    fn new(from: i64, to: i64) -> Resampler {
        let step = from as f64 / to as f64;
        // Low-pass at 0.93 of the lower Nyquist.
        let cutoff = 0.93 * (1.0f64).min(to as f64 / from as f64);
        let half_in = HALF_WIDTH / cutoff;
        let half = half_in.ceil() as usize;
        let width = 2 * half + 1;
        let beta = 9.0;
        let norm = bessel_i0(beta);
        let mut table = vec![0.0f32; (PHASES + 1) * width];
        for p in 0..=PHASES {
            let frac = p as f64 / PHASES as f64;
            for (k, slot) in table[p * width..(p + 1) * width].iter_mut().enumerate() {
                // Tap k is input sample (floor(pos) - half + k); its distance from the output position.
                let x = k as f64 - half as f64 - frac;
                let w = x / half_in;
                let win = if w.abs() >= 1.0 { 0.0 } else { bessel_i0(beta * (1.0 - w * w).sqrt()) / norm };
                let arg = std::f64::consts::PI * cutoff * x;
                let sinc = if arg.abs() < 1e-12 { 1.0 } else { arg.sin() / arg };
                *slot = (cutoff * sinc * win) as f32;
            }
        }
        // The stream starts with silence before sample 0.
        Resampler { step, half, table, buf: vec![0.0; half], base: -(half as i64), pos: 0.0 }
    }

    fn process(&mut self, input: &[f32]) -> Vec<f32> {
        self.buf.extend_from_slice(input);
        let width = 2 * self.half + 1;
        let mut out = Vec::with_capacity((input.len() as f64 / self.step) as usize + 2);
        loop {
            let i = self.pos.floor() as i64;
            // Needs input up to i + half.
            let last = i + self.half as i64 - self.base;
            if last >= self.buf.len() as i64 {
                break;
            }
            let frac = (self.pos - i as f64) * PHASES as f64;
            let p = frac.floor() as usize;
            let t = (frac - p as f64) as f32;
            let first = (i - self.half as i64 - self.base) as usize;
            // `first` can be -half..: the buffer starts `half` zeros before sample 0, so it is never negative here.
            let (a, b) = (&self.table[p * width..(p + 1) * width], &self.table[(p + 1) * width..(p + 2) * width]);
            let x = &self.buf[first..first + width];
            let mut acc = 0.0f32;
            for k in 0..width {
                acc += x[k] * (a[k] + (b[k] - a[k]) * t);
            }
            out.push(acc);
            self.pos += self.step;
        }
        // Drop what no later output needs.
        let keep_from = self.pos.floor() as i64 - self.half as i64;
        let drop = (keep_from - self.base).clamp(0, self.buf.len() as i64) as usize;
        self.buf.drain(..drop);
        self.base += drop as i64;
        out
    }
}

/// The denoiser at any sample rate.
pub struct DenoiseStage {
    sample_rate: i64,
    channel_count: usize,
    latency: usize,
    denoiser: RNNoiseDenoiser,
    paths: Option<Paths>,
}

struct Paths {
    up: Vec<Resampler>,
    down: Vec<Resampler>,
    fifo: Vec<Vec<f32>>,
}

impl DenoiseStage {
    pub fn new(sample_rate: i64, channel_count: usize) -> Result<DenoiseStage, AudioFXError> {
        Self::build(sample_rate, channel_count, true)
    }

    fn build(sample_rate: i64, channel_count: usize, calibrate: bool) -> Result<DenoiseStage, AudioFXError> {
        if channel_count == 0 {
            return Err(AudioFXError::InvalidChannelCount(0));
        }
        if sample_rate <= 0 {
            return Err(AudioFXError::UnsupportedSampleRate(sample_rate));
        }
        let denoiser = RNNoiseDenoiser::new(channel_count, RNNoiseDenoiser::SAMPLE_RATE)?;
        let mut s = DenoiseStage {
            sample_rate,
            channel_count,
            latency: RNNoiseDenoiser::LATENCY_SAMPLES,
            denoiser,
            paths: None,
        };
        if sample_rate != RNNoiseDenoiser::SAMPLE_RATE {
            let hz = RNNoiseDenoiser::SAMPLE_RATE;
            s.paths = Some(Paths {
                up: (0..channel_count).map(|_| Resampler::new(sample_rate, hz)).collect(),
                down: (0..channel_count).map(|_| Resampler::new(hz, sample_rate)).collect(),
                fifo: vec![vec![0.0; SAFETY_PAD]; channel_count],
            });
            s.latency = 0;
            if calibrate {
                s.latency = Self::measure_latency(sample_rate, channel_count)?;
            }
        }
        Ok(s)
    }

    /// Impulse through a dry (mix 0) copy of the stage; the peak position is the latency.
    fn measure_latency(sample_rate: i64, channel_count: usize) -> Result<usize, AudioFXError> {
        let mut probe = Self::build(sample_rate, channel_count, false)?;
        probe.set_mix(0.0);
        let total = 8192;
        let mut impulse = vec![0.0f32; total];
        impulse[0] = 1.0;
        let mut out: Vec<f32> = Vec::new();
        let mut pos = 0;
        while pos < total {
            let len = 512.min(total - pos);
            let mut block = vec![impulse[pos..pos + len].to_vec()];
            block.extend((1..channel_count).map(|_| vec![0.0; len]));
            out.extend(probe.process(&block)[0].iter());
            pos += len;
        }
        let (mut best, mut best_v) = (0, 0.0f32);
        for (i, v) in out.iter().enumerate() {
            if v.abs() > best_v {
                best_v = v.abs();
                best = i;
            }
        }
        Ok(best)
    }

    pub fn sample_rate(&self) -> i64 {
        self.sample_rate
    }

    /// Delay of the stage in samples at the caller's rate.
    pub fn latency_samples(&self) -> usize {
        self.latency
    }

    /// Wet/dry, 1 = fully denoised.
    pub fn mix(&self) -> f32 {
        self.denoiser.mix
    }

    pub fn set_mix(&mut self, mix: f32) {
        self.denoiser.mix = mix;
    }

    /// Same number of samples out as in, delayed by `latency_samples()`.
    pub fn process(&mut self, input: &[Vec<f32>]) -> Vec<Vec<f32>> {
        assert!(input.len() == self.channel_count, "channel count mismatch");
        let n = input.first().map_or(0, Vec::len);
        let Some(p) = &mut self.paths else { return self.denoiser.process(input) };
        if n == 0 {
            return input.to_vec();
        }
        let up: Vec<Vec<f32>> = input.iter().zip(&mut p.up).map(|(c, r)| r.process(c)).collect();
        let wet = self.denoiser.process(&up);
        let mut out = Vec::with_capacity(self.channel_count);
        for ((w, r), f) in wet.iter().zip(&mut p.down).zip(&mut p.fifo) {
            f.extend(r.process(w));
            if f.len() < n {
                f.resize(n, 0.0);
            }
            out.push(f[..n].to_vec());
            f.drain(..n);
        }
        out
    }

    /// The `latency_samples()` still inside the stage (feeds silence through it).
    pub fn flush(&mut self) -> Vec<Vec<f32>> {
        if self.paths.is_none() {
            return self.denoiser.flush();
        }
        let zeros = vec![vec![0.0f32; self.latency]; self.channel_count];
        self.process(&zeros)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f64, rate: i64, n: usize) -> Vec<f32> {
        (0..n).map(|i| (0.5 * (2.0 * std::f64::consts::PI * freq * i as f64 / rate as f64).sin()) as f32).collect()
    }

    #[test]
    fn resampler_keeps_a_tone_and_its_level() {
        for (from, to) in [(44_100, 48_000), (48_000, 44_100), (96_000, 48_000), (48_000, 96_000), (22_050, 48_000)] {
            let mut r = Resampler::new(from, to);
            let x = sine(1000.0, from, from as usize);
            let y = r.process(&x);
            assert!((y.len() as f64 - to as f64).abs() < 64.0, "{from}->{to}: {}", y.len());
            // Compare to the ideal tone in the middle (delay-free: the stream starts at sample 0 with the
            // kernel centered, so output j is the signal at j / to seconds).
            let mut worst = 0.0f64;
            for (j, v) in y.iter().enumerate().skip(2000).take(to as usize / 2) {
                let want = 0.5 * (2.0 * std::f64::consts::PI * 1000.0 * j as f64 / to as f64).sin();
                worst = worst.max((f64::from(*v) - want).abs());
            }
            assert!(worst < 2e-3, "{from}->{to}: error {worst}");
        }
    }

    #[test]
    fn chunking_does_not_change_the_resampled_signal() {
        let x = sine(440.0, 44_100, 20_000);
        let whole = Resampler::new(44_100, 48_000).process(&x);
        let mut r = Resampler::new(44_100, 48_000);
        let mut parts = Vec::new();
        for c in x.chunks(333) {
            parts.extend(r.process(c));
        }
        assert_eq!(parts.len(), whole.len());
        for (a, b) in parts.iter().zip(&whole) {
            assert!((a - b).abs() < 1e-6);
        }
    }

    #[test]
    fn other_rates_work_and_keep_the_length() {
        for rate in [44_100_i64, 96_000, 32_000] {
            let mut s = DenoiseStage::new(rate, 2).expect("stage");
            assert!(s.latency_samples() > 0, "{rate}");
            s.set_mix(0.0);
            let x = [sine(300.0, rate, 8192), sine(500.0, rate, 8192)];
            let mut out: Vec<Vec<f32>> = vec![Vec::new(); 2];
            for c in 0..16 {
                let blk: Vec<Vec<f32>> = x.iter().map(|ch| ch[c * 512..(c + 1) * 512].to_vec()).collect();
                let o = s.process(&blk);
                assert_eq!(o[0].len(), 512);
                for (acc, v) in out.iter_mut().zip(o) {
                    acc.extend(v);
                }
            }
            // Dry mix: the output is the input delayed by the measured latency.
            let lat = s.latency_samples();
            let mut worst = 0.0f32;
            for i in 3000..8000 - lat {
                worst = worst.max((out[0][i + lat] - x[0][i]).abs());
            }
            assert!(worst < 0.02, "{rate}: {worst}");
        }
    }

    #[test]
    fn at_48k_it_is_the_plain_denoiser() {
        let s = DenoiseStage::new(48_000, 1).expect("stage");
        assert_eq!(s.latency_samples(), RNNoiseDenoiser::LATENCY_SAMPLES);
        assert!(DenoiseStage::new(0, 1).is_err() && DenoiseStage::new(48_000, 0).is_err());
    }
}
