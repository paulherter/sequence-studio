//! Port of `SQAudioFX/Sources/SQAudioFX/Loudness.swift`.

use crate::gain::GainMath;
use std::sync::OnceLock;

const PI: f64 = std::f64::consts::PI;

fn sum(xs: &[f64]) -> f64 {
    xs.iter().fold(0.0, |a, &b| a + b)
}

/// ITU-R BS.1770-4 / EBU R128 loudness and peak meter.
///
/// Feed audio with `process`. Momentary (400 ms) and short-term (3 s) are evaluated on 100 ms steps;
/// integrated uses 400 ms blocks with 75 % overlap, absolute gate -70 LUFS and relative gate -10 LU.
#[derive(Clone, Debug)]
pub struct LoudnessMeter {
    pub sample_rate: i64,
    pub channel_count: usize,
    pub weights: Vec<f64>,

    filters: Vec<KWeighting>,
    true_peak: Vec<TruePeakDetector>,
    step_length: usize,
    /// Weighted sum of squares in the current 100 ms step.
    step_energy: f64,
    step_fill: usize,
    /// Mean weighted energy per 100 ms step (only last 30 kept).
    steps: Vec<f64>,
    /// 400 ms block energies (for gating).
    block_energies: Vec<f64>,
    sample_peak: Vec<f64>,
    /// 3 s window energy on every 100 ms step (for the loudness range).
    short_term_energies: Vec<f64>,
}

impl LoudnessMeter {
    pub fn default_weights(channel_count: usize) -> Vec<f64> {
        match channel_count {
            6 => vec![1.0, 1.0, 1.0, 0.0, 1.41253754, 1.41253754], // L R C LFE Ls Rs
            n => vec![1.0; n],
        }
    }

    pub fn new(sample_rate: i64, channel_count: usize, weights: Option<Vec<f64>>) -> Self {
        let w = weights.unwrap_or_else(|| Self::default_weights(channel_count));
        let weights = if w.len() == channel_count { w } else { Self::default_weights(channel_count) };
        LoudnessMeter {
            sample_rate,
            channel_count,
            weights,
            filters: vec![KWeighting::new(sample_rate as f64); channel_count],
            true_peak: vec![TruePeakDetector::new(); channel_count],
            step_length: ((sample_rate as f64 * 0.1).round() as usize).max(1),
            step_energy: 0.0,
            step_fill: 0,
            steps: Vec::new(),
            block_energies: Vec::new(),
            sample_peak: vec![0.0; channel_count],
            short_term_energies: Vec::new(),
        }
    }

    pub fn reset(&mut self) {
        *self = LoudnessMeter::new(self.sample_rate, self.channel_count, Some(self.weights.clone()));
    }

    pub fn process(&mut self, input: &[Vec<f32>]) {
        assert!(input.len() == self.channel_count, "channel count mismatch");
        let n = input.first().map_or(0, Vec::len);
        if n == 0 {
            return;
        }
        let mut energy = vec![0.0_f64; n];
        let mut xs = vec![0.0_f64; n];
        for (c, channel) in input.iter().enumerate() {
            let w = self.weights[c];
            let mut peak = self.sample_peak[c];
            let filter = &mut self.filters[c];
            for i in 0..n {
                let v = f64::from(channel[i]);
                xs[i] = v;
                let a = v.abs();
                if a > peak {
                    peak = a;
                }
            }
            self.true_peak[c].push_slice(&xs);
            if w != 0.0 {
                for i in 0..n {
                    let y = filter.process(xs[i]);
                    energy[i] += w * y * y;
                }
            }
            self.sample_peak[c] = peak;
        }
        for e in energy {
            self.step_energy += e;
            self.step_fill += 1;
            if self.step_fill == self.step_length {
                self.steps.push(self.step_energy / self.step_length as f64);
                self.step_energy = 0.0;
                self.step_fill = 0;
                if self.steps.len() >= 4 {
                    self.block_energies.push(sum(&self.steps[self.steps.len() - 4..]) / 4.0);
                }
                if self.steps.len() > 30 {
                    self.steps.drain(..self.steps.len() - 30);
                }
                if self.steps.len() == 30 {
                    self.short_term_energies.push(sum(&self.steps) / 30.0);
                }
            }
        }
    }

    pub(crate) fn lufs_from_energy(z: f64) -> f64 {
        if z > 0.0 { -0.691 + 10.0 * z.log10() } else { f64::NEG_INFINITY }
    }

    /// Momentary loudness (LUFS) of the last 400 ms; None until 400 ms have been seen.
    pub fn momentary(&self) -> Option<f64> {
        (self.steps.len() >= 4).then(|| Self::lufs_from_energy(sum(&self.steps[self.steps.len() - 4..]) / 4.0))
    }

    /// Short-term loudness (LUFS) of the last 3 s; None until 3 s have been seen.
    pub fn short_term(&self) -> Option<f64> {
        (self.steps.len() >= 30).then(|| Self::lufs_from_energy(sum(&self.steps[self.steps.len() - 30..]) / 30.0))
    }

    /// Gated integrated loudness (LUFS); -inf if nothing passes the gates.
    pub fn integrated(&self) -> f64 {
        let abs_gate: Vec<f64> =
            self.block_energies.iter().copied().filter(|&e| Self::lufs_from_energy(e) > -70.0).collect();
        if abs_gate.is_empty() {
            return f64::NEG_INFINITY;
        }
        let rel_threshold = Self::lufs_from_energy(sum(&abs_gate) / abs_gate.len() as f64) - 10.0;
        let passed: Vec<f64> =
            abs_gate.iter().copied().filter(|&e| Self::lufs_from_energy(e) > rel_threshold).collect();
        if passed.is_empty() {
            return f64::NEG_INFINITY;
        }
        Self::lufs_from_energy(sum(&passed) / passed.len() as f64)
    }

    /// Loudness range in LU (EBU Tech 3342): 3 s short-term windows every 100 ms, absolute gate -70 LUFS, relative gate
    /// -20 LU, then the 95th minus the 10th percentile. None when there is no window above the gates (under 3 s or silent).
    pub fn loudness_range(&self) -> Option<f64> {
        let abs: Vec<f64> =
            self.short_term_energies.iter().copied().filter(|&e| Self::lufs_from_energy(e) > -70.0).collect();
        if abs.is_empty() {
            return None;
        }
        let gate = Self::lufs_from_energy(sum(&abs) / abs.len() as f64) - 20.0;
        let mut v: Vec<f64> = abs.iter().map(|&e| Self::lufs_from_energy(e)).filter(|&l| l > gate).collect();
        v.sort_by(f64::total_cmp);
        let lo = Self::percentile(&v, 0.10)?;
        let hi = Self::percentile(&v, 0.95)?;
        Some(hi - lo)
    }

    /// Linear interpolation between closest ranks on a sorted array.
    pub(crate) fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
        if sorted.is_empty() {
            return None;
        }
        let r = p * (sorted.len() - 1) as f64;
        let i = r.floor() as usize;
        let f = r - i as f64;
        Some(if i + 1 < sorted.len() { sorted[i] + f * (sorted[i + 1] - sorted[i]) } else { sorted[i] })
    }

    /// Per-channel sample peak in dBFS.
    pub fn sample_peak_db(&self) -> Vec<f64> {
        self.sample_peak.iter().map(|&p| GainMath::db_from_linear(p)).collect()
    }

    /// Per-channel true peak in dBTP (4x oversampled).
    pub fn true_peak_db(&self) -> Vec<f64> {
        self.true_peak.iter().zip(&self.sample_peak).map(|(t, &s)| GainMath::db_from_linear(t.peak.max(s))).collect()
    }
}

/// BS.1770 K-weighting: high-shelf pre-filter followed by the RLB high-pass, derived from the
/// standard's f0/Q/gain so it is valid for any sample rate (reproduces the 48 kHz table).
#[derive(Clone, Copy, Debug)]
pub(crate) struct KWeighting {
    s1: Biquad,
    s2: Biquad,
}

impl KWeighting {
    pub(crate) fn new(fs: f64) -> Self {
        // Stage 1: high shelf (bilinear transform of the standard's analog prototype)
        let vh = 10.0_f64.powf(3.999843853973347 / 20.0);
        let vb = vh.powf(0.4996667741545416);
        let mut k = (PI * 1681.974450955533 / fs).tan();
        let mut q = 0.7071752369554196;
        let mut a0 = 1.0 + k / q + k * k;
        let s1 = Biquad::with_coefficients(
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
            2.0 * (k * k - 1.0) / a0,
            (1.0 - k / q + k * k) / a0,
        );
        // Stage 2: RLB high-pass, numerator [1, -2, 1]
        k = (PI * 38.13547087602444 / fs).tan();
        q = 0.5003270373238773;
        a0 = 1.0 + k / q + k * k;
        let s2 = Biquad::with_coefficients(1.0, -2.0, 1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0);
        KWeighting { s1, s2 }
    }

    pub(crate) fn process(&mut self, x: f64) -> f64 {
        let y = self.s1.process(x);
        self.s2.process(y)
    }
}

/// Transposed direct form II, double precision.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Biquad {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
    z1: f64,
    z2: f64,
}

impl Default for Biquad {
    fn default() -> Self {
        Biquad { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0, z1: 0.0, z2: 0.0 }
    }
}

impl Biquad {
    pub(crate) fn with_coefficients(b0: f64, b1: f64, b2: f64, a1: f64, a2: f64) -> Self {
        Biquad { b0, b1, b2, a1, a2, z1: 0.0, z2: 0.0 }
    }

    pub(crate) fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    pub(crate) fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }
}

/// 4x oversampling true-peak detector: 48-tap windowed-sinc, 4 polyphase branches of 12 taps.
#[derive(Clone, Debug)]
pub(crate) struct TruePeakDetector {
    /// The 12 history values twice over, so the newest-first window is contiguous at `head` (no shifting per sample).
    history: [f64; 24],
    head: usize,
    pub(crate) peak: f64,
}

impl TruePeakDetector {
    /// Phase-major, 4 x 12.
    fn flat_taps() -> &'static [f64; 48] {
        static TAPS: OnceLock<[f64; 48]> = OnceLock::new();
        TAPS.get_or_init(|| {
            let n = 48;
            let mut h: Vec<f64> = (0..n)
                .map(|i| {
                    let x = (i as f64 - (n - 1) as f64 / 2.0) / 4.0;
                    let s = if x == 0.0 { 1.0 } else { (PI * x).sin() / (PI * x) };
                    let w = 0.42 - 0.5 * (2.0 * PI * i as f64 / (n - 1) as f64).cos()
                        + 0.08 * (4.0 * PI * i as f64 / (n - 1) as f64).cos();
                    s * w
                })
                .collect();
            let total = sum(&h);
            h = h.iter().map(|v| v * 4.0 / total).collect();
            let mut flat = [0.0; 48];
            for p in 0..4 {
                for k in 0..12 {
                    flat[p * 12 + k] = h[4 * k + p];
                }
            }
            flat
        })
    }

    pub(crate) fn new() -> Self {
        TruePeakDetector { history: [0.0; 24], head: 0, peak: 0.0 }
    }

    /// Same result as pushing the samples one by one.
    pub(crate) fn push_slice(&mut self, xs: &[f64]) {
        let t = Self::flat_taps();
        let mut peak = self.peak;
        let mut head = self.head;
        for &x in xs {
            head = if head == 0 { 11 } else { head - 1 };
            self.history[head] = x;
            self.history[head + 12] = x;
            for phase in 0..4 {
                let mut acc = 0.0;
                let base = phase * 12;
                for k in 0..12 {
                    acc += t[base + k] * self.history[head + k];
                }
                let m = acc.abs();
                if m > peak {
                    peak = m;
                }
            }
        }
        self.peak = peak;
        self.head = head;
    }

    #[cfg(test)]
    pub(crate) fn push(&mut self, x: f64) {
        self.push_slice(&[x]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;

    fn sine(freq: f64, db: f64, seconds: f64) -> Vec<Vec<f32>> {
        sig::sine(freq, db, seconds, 48000, 2, 0.0)
    }

    fn meter() -> LoudnessMeter {
        LoudnessMeter::new(48000, 2, None)
    }

    #[test]
    fn sine_1k_stereo_minus_23() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 10.0));
        assert!((m.integrated() - -23.0).abs() < 0.1, "integrated {}", m.integrated());
        assert!((m.momentary().unwrap_or(0.0) - -23.0).abs() < 0.1);
        assert!((m.short_term().unwrap_or(0.0) - -23.0).abs() < 0.1);
    }

    #[test]
    fn sine_level_shifts_linearly() {
        let mut m = meter();
        m.process(&sine(1000.0, -33.0, 5.0));
        assert!((m.integrated() - -33.0).abs() < 0.1);
    }

    #[test]
    fn mono_is_three_db_below_stereo() {
        let mut m = LoudnessMeter::new(48000, 1, None);
        m.process(&sig::sine(1000.0, -23.0, 5.0, 48000, 1, 0.0));
        assert!((m.integrated() - -26.0).abs() < 0.1);
    }

    #[test]
    fn k_weighting_attenuates_low_frequencies() {
        let mut lo = meter();
        lo.process(&sine(40.0, -23.0, 5.0));
        assert!(lo.integrated() < -24.5); // 40 Hz is ~ -1.5 dB after the RLB filter
        let mut hi = meter();
        hi.process(&sine(8000.0, -23.0, 5.0));
        assert!(hi.integrated() > -21.5); // high shelf ~ +3.7 dB at 8 kHz
    }

    #[test]
    fn works_at_44100() {
        let mut m = LoudnessMeter::new(44100, 2, None);
        m.process(&sig::sine(1000.0, -23.0, 5.0, 44100, 2, 0.0));
        assert!((m.integrated() - -23.0).abs() < 0.1);
    }

    #[test]
    fn chunking_does_not_matter() {
        let x = sine(440.0, -20.0, 6.0);
        let mut a = meter();
        a.process(&x);
        let mut b = meter();
        for p in sig::chunked(&x, &[1, 100, 4799, 4800, 4801, 77]) {
            b.process(&p);
        }
        assert!((a.integrated() - b.integrated()).abs() < 1e-9);
        assert_eq!(a.momentary(), b.momentary());
    }

    #[test]
    fn absolute_gate_ignores_quiet_blocks() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 5.0));
        m.process(&sine(1000.0, -90.0, 6.0)); // below -70 LUFS
        assert!((m.integrated() - -23.0).abs() < 0.3); // transition blocks legitimately count
    }

    #[test]
    fn relative_gate_ignores_blocks_more_than_10_lu_below() {
        let mut m = meter();
        m.process(&sine(1000.0, -20.0, 10.0));
        m.process(&sine(1000.0, -45.0, 10.0)); // -25 LU below: gated out
        assert!((m.integrated() - -20.0).abs() < 0.15);
    }

    #[test]
    fn short_term_needs_three_seconds() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 1.0));
        assert!(m.momentary().is_some());
        assert!(m.short_term().is_none());
        let mut short = meter();
        short.process(&sine(1000.0, -23.0, 0.3));
        assert!(short.momentary().is_none());
        assert_eq!(short.integrated(), f64::NEG_INFINITY);
    }

    #[test]
    fn silence_is_minus_infinity() {
        let mut m = meter();
        m.process(&vec![vec![0.0_f32; 48000 * 2]; 2]);
        assert_eq!(m.integrated(), f64::NEG_INFINITY);
        assert_eq!(m.sample_peak_db(), vec![f64::NEG_INFINITY, f64::NEG_INFINITY]);
    }

    #[test]
    fn sample_peak() {
        let mut m = meter();
        let mut x = sine(1000.0, -20.0, 1.0);
        x[1][100] = 0.5;
        m.process(&x);
        assert!((m.sample_peak_db()[0] - -20.0).abs() < 0.05);
        assert!((m.sample_peak_db()[1] - -6.0206).abs() < 0.01);
    }

    #[test]
    fn true_peak_finds_intersample_peak() {
        // fs/4 sine at 45 degrees: every sample is +-0.7071 (-3 dBFS), true peak is 1.0 (0 dBTP)
        let mut m = LoudnessMeter::new(48000, 1, None);
        m.process(&sig::sine(12000.0, 0.0, 0.5, 48000, 1, PI / 4.0));
        assert!((m.sample_peak_db()[0] - -3.01).abs() < 0.05);
        assert!(m.true_peak_db()[0].abs() < 0.3, "true peak {}", m.true_peak_db()[0]);
    }

    #[test]
    fn true_peak_never_below_sample_peak() {
        let mut m = LoudnessMeter::new(48000, 1, None);
        m.process(&[sig::noise(0.8, 20000, 1)]);
        assert!(m.true_peak_db()[0] >= m.sample_peak_db()[0] - 1e-9);
    }

    #[test]
    fn reset() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 5.0));
        m.reset();
        assert_eq!(m.integrated(), f64::NEG_INFINITY);
        assert!(m.momentary().is_none());
    }

    #[test]
    fn forty_five_seconds_stereo_measures_quickly() {
        let signal = sine(1000.0, -20.0, 45.0);
        let mut m = meter();
        let start = std::time::Instant::now();
        let block = 4096;
        let mut at = 0;
        while at < signal[0].len() {
            let end = (at + block).min(signal[0].len());
            let part: Vec<Vec<f32>> = signal.iter().map(|c| c[at..end].to_vec()).collect();
            m.process(&part);
            at = end;
        }
        assert!((m.integrated() - -20.0).abs() < 0.1);
        // About 2 s in a debug build alone; the margin covers a full parallel test run on a loaded machine.
        assert!(start.elapsed().as_secs() < 20, "took {:?}", start.elapsed());
    }

    #[test]
    fn true_peak_block_push_equals_sample_push() {
        let xs: Vec<f64> = sig::noise(0.9, 1000, 1).into_iter().map(f64::from).collect();
        let (mut a, mut b) = (TruePeakDetector::new(), TruePeakDetector::new());
        for &x in &xs {
            a.push(x);
        }
        b.push_slice(&xs);
        assert_eq!(a.peak, b.peak);
        assert!(a.peak >= xs.iter().fold(0.0_f64, |m, x| m.max(x.abs())) * 0.99);
    }

    // EBU Tech 3342 style: a constant level has range 0; a 10 LU step half and half gives LRA of about 10.
    #[test]
    fn loudness_range_of_constant_tone_is_zero() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 20.0));
        assert!(m.loudness_range().unwrap_or(99.0).abs() < 0.1);
    }

    #[test]
    fn loudness_range_of_ten_lu_step_is_about_ten() {
        let mut m = meter();
        m.process(&sine(1000.0, -33.0, 20.0));
        m.process(&sine(1000.0, -23.0, 20.0));
        assert!((m.loudness_range().unwrap_or(0.0) - 10.0).abs() < 0.3);
    }

    #[test]
    fn loudness_range_gates_quiet_passages() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 30.0));
        m.process(&sine(1000.0, -60.0, 3.0)); // more than 20 LU below: ignored
        assert!(m.loudness_range().unwrap_or(99.0) < 0.5);
    }

    #[test]
    fn loudness_range_needs_three_seconds_and_sound() {
        let mut m = meter();
        m.process(&sine(1000.0, -23.0, 2.0));
        assert!(m.loudness_range().is_none());
        m.reset();
        m.process(&vec![vec![0.0_f32; 48000 * 5]; 2]);
        assert!(m.loudness_range().is_none());
    }
}
