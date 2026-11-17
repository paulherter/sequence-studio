// Swift: PitchShift.swift
//! The spectral engine of Pitch Shift and Disguise Voice: one channel, STFT with a 2048 window and 512 hop (sqrt-Hann
//! analysis and synthesis), own implementation, no borrowed code.
//!
//! Pitch: phase vocoder with peak-region shifting (the method of Laroche and Dolson, "New phase-vocoder techniques for
//! pitch-shifting", 1999). Every spectral peak is one partial; its true frequency comes from the phase advance since the last
//! frame; the peak and the bins around it move as one block by `frequency x (ratio - 1)` and get one common phase rotation that
//! accumulates per frame. Bins of a partial keep their phase relation (no "phasiness" of the plain phase vocoder) and the
//! output frequency is exact, not rounded to a bin. Phases are referenced to the frame center, where a windowed partial has
//! one phase across its whole lobe, so a block can be read at a fractional bin position.
//!
//! Formants: the spectral envelope (peak-riding: running maximum of the log spectrum, then cepstral smoothing) is measured on
//! the input; the shifted spectrum is re-weighted from where its envelope went (`bin / ratio`) to where it shall be
//! (`bin / formant`). `formant` 1 keeps the voice character, `formant == ratio` lets it move with the pitch.
//!
//! Delay: exactly `AudioPitchValues::LATENCY_SAMPLES` (= the window). Neutral controls pass the sound through unchanged.
//! Nothing here allocates after `new`.
//!
//! The FFT is the portable radix-2 one (`FFTRadix2`), the path the Windows build of the Swift package takes.

use crate::de_reverb::FFTRadix2;
use crate::multiband_meters::MultibandMeterTap;
use sq_core_audio::AudioPitchValues;
use sq_core_time::{Id, Time};

/// What the engine is told for one synthesized frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Controls {
    /// Pitch ratio (2 = one octave up).
    pub ratio: f64,
    /// Where the spectral envelope goes: 1 = stays, `ratio` = moves with the pitch.
    pub formant: f64,
    /// Extra, frequency-dependent envelope shift in bins: largest around 2 kHz, none at 0 and from 4 kHz up.
    pub bend: f64,
    /// The envelope is put back blurred (formant detail is lost).
    pub coarse: bool,
    /// Random phase offset per partial and frame in radians, 0 = none.
    pub jitter: f64,
    /// Seed of the jitter of this frame.
    pub jitter_key: u64,
}

impl Default for Controls {
    fn default() -> Self {
        Controls { ratio: 1.0, formant: 1.0, bend: 0.0, coarse: false, jitter: 0.0, jitter_key: 0 }
    }
}

impl Controls {
    /// True when the controls pass the sound through unchanged.
    pub fn is_neutral(&self) -> bool {
        self.ratio == 1.0 && self.formant == 1.0 && self.bend == 0.0 && !self.coarse && self.jitter == 0.0
    }

    /// True when the spectral envelope has to be re-weighted.
    pub fn shapes_envelope(&self) -> bool {
        self.formant != self.ratio || self.bend != 0.0 || self.coarse
    }
}

/// One channel of the pitch engine.
pub struct PitchVocoder {
    window: Vec<f64>,
    lift_fine: Vec<f64>,
    lift_coarse: Vec<f64>,
    fft: FFTRadix2,
    /// Last n input samples, circular.
    in_ring: Vec<f64>,
    in_pos: usize,
    since_frame: usize,
    ola: Vec<f64>,
    /// Circular output queue, 2 n.
    fifo: Vec<f32>,
    fifo_read: usize,
    fifo_count: usize,
    re: Vec<f64>,
    im: Vec<f64>,
    cep: Vec<f64>,
    xr: Vec<f64>,
    xi: Vec<f64>,
    pr: Vec<f64>,
    pi: Vec<f64>,
    yr: Vec<f64>,
    yi: Vec<f64>,
    mag: Vec<f64>,
    log_mag: Vec<f64>,
    env_fine: Vec<f64>,
    env_coarse: Vec<f64>,
    theta: Vec<f64>,
    theta_next: Vec<f64>,
    peaks: Vec<usize>,
    peak_count: usize,
    /// Pitch tracker: the window at a quarter of the rate.
    dec: Vec<f64>,
    rho: Vec<f64>,
}

impl PitchVocoder {
    /// Window length.
    pub const N: usize = 2_048;
    /// Hop between frames.
    pub const HOP: usize = 512;
    /// Bins of the half spectrum.
    pub const BINS: usize = Self::N / 2 + 1;
    /// Half width of the running maximum of the envelope in bins (+-140 Hz: closes the gaps between harmonics up to 280 Hz pitch; the smoothing after it does the rest).
    pub const ENVELOPE_REACH: usize = 6;
    /// Largest envelope correction per bin in nepers (30 dB).
    pub const MAX_ENVELOPE_GAIN: f64 = 3.45;
    const DEC_N: usize = Self::N / 4;
    const LAG_MIN: usize = 30;
    const LAG_MAX: usize = 200;
    /// The pre-fill: the rest of the delay is the window.
    const PREFILL: usize = AudioPitchValues::LATENCY_SAMPLES as usize - (Self::N - Self::HOP);

    /// A vocoder at rest.
    pub fn new() -> Self {
        let (n, bins) = (Self::N, Self::BINS);
        let window =
            (0..n).map(|i| (0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / n as f64).cos()).sqrt()).collect();
        // Cepstral low-pass, full below `pass`, cosine fade to 0 at `stop` (quefrency in samples, mirrored).
        let lifter = |pass: usize, stop: usize| -> Vec<f64> {
            (0..n)
                .map(|q| {
                    let d = q.min(n - q);
                    if d <= pass {
                        1.0
                    } else if d >= stop {
                        0.0
                    } else {
                        0.5 + 0.5 * (std::f64::consts::PI * (d - pass) as f64 / (stop - pass) as f64).cos()
                    }
                })
                .collect()
        };
        let mut v = PitchVocoder {
            window,
            lift_fine: lifter(64, 110), // keeps formants (detail from about 300 Hz), removes harmonics up to 400 Hz pitch
            lift_coarse: lifter(22, 44), // formants blur into broad humps (detail narrower than about 1 kHz is gone)
            fft: FFTRadix2::new(n),
            in_ring: vec![0.0; n],
            in_pos: 0,
            since_frame: 0,
            ola: vec![0.0; n],
            fifo: vec![0.0; 2 * n],
            fifo_read: 0,
            fifo_count: 0,
            re: vec![0.0; n],
            im: vec![0.0; n],
            cep: vec![0.0; n],
            xr: vec![0.0; bins],
            xi: vec![0.0; bins],
            pr: vec![0.0; bins],
            pi: vec![0.0; bins],
            yr: vec![0.0; bins],
            yi: vec![0.0; bins],
            mag: vec![0.0; bins],
            log_mag: vec![0.0; bins],
            env_fine: vec![0.0; bins],
            env_coarse: vec![0.0; bins],
            theta: vec![0.0; bins],
            theta_next: vec![0.0; bins],
            peaks: vec![0; bins],
            peak_count: 0,
            dec: vec![0.0; Self::DEC_N],
            rho: vec![0.0; Self::LAG_MAX + 2],
        };
        v.reset();
        v
    }

    /// Back to silence at the start of a stream.
    pub fn reset(&mut self) {
        self.in_ring.fill(0.0);
        self.ola.fill(0.0);
        self.pr.fill(0.0);
        self.pi.fill(0.0);
        self.theta.fill(0.0);
        self.theta_next.fill(0.0);
        self.fifo.fill(0.0);
        self.in_pos = 0;
        self.since_frame = 0;
        self.fifo_read = 0;
        self.fifo_count = Self::PREFILL;
    }

    /// `reset` with the hop grid on absolute positions: the next sample pushed is number `p`, and a hop completes with every
    /// sample whose number plus one is a multiple of `HOP`. So the frames of a stream that starts anywhere fall where the
    /// frames of the same stream started at 0 fall. The first hop is shorter then, and so is the pre-fill: the delay stays
    /// one window.
    pub fn reset_at(&mut self, p: i64) {
        self.reset();
        let h = Self::HOP as i64;
        let phase = (((p % h) + h) % h) as usize;
        self.since_frame = phase;
        self.fifo_count -= phase;
    }

    /// Takes one input sample; true when a hop is complete: call `analyze` and `synthesize` before the next `pop`.
    #[inline]
    pub fn push(&mut self, x: f32) -> bool {
        self.in_ring[self.in_pos] = f64::from(x);
        self.in_pos = (self.in_pos + 1) & (Self::N - 1);
        self.since_frame += 1;
        if self.since_frame == Self::HOP {
            self.since_frame = 0;
            return true;
        }
        false
    }

    /// The next output sample (the input `LATENCY_SAMPLES` ago, processed).
    #[inline]
    pub fn pop(&mut self) -> f32 {
        let v = self.fifo[self.fifo_read];
        self.fifo_read = (self.fifo_read + 1) & (2 * Self::N - 1);
        self.fifo_count -= 1;
        v
    }

    /// Spectrum of the last `N` samples, phases referenced to the frame center.
    pub fn analyze(&mut self) {
        let n = Self::N;
        for k in 0..n {
            self.re[k] = self.in_ring[(self.in_pos + k) & (n - 1)] * self.window[k]; // oldest first
            self.im[k] = 0.0;
        }
        self.fft.transform(&mut self.re, &mut self.im, false);
        for k in 0..Self::BINS {
            let s: f64 = if k & 1 == 0 { 1.0 } else { -1.0 };
            let a = self.re[k] * s;
            let b = self.im[k] * s;
            self.xr[k] = a;
            self.xi[k] = b;
            self.mag[k] = (a * a + b * b).sqrt();
        }
    }

    /// Pitch of the last window in Hz, `None` when it is not voiced (60...400 Hz, normalized autocorrelation at 12 kHz).
    pub fn estimate_f0(&mut self, sample_rate: f64) -> Option<f64> {
        let (m, n) = (Self::DEC_N, Self::N);
        let mut energy = 0.0;
        for j in 0..m {
            let b = self.in_pos + 4 * j;
            let v = 0.25
                * (self.in_ring[b & (n - 1)]
                    + self.in_ring[(b + 1) & (n - 1)]
                    + self.in_ring[(b + 2) & (n - 1)]
                    + self.in_ring[(b + 3) & (n - 1)]);
            self.dec[j] = v;
            energy += v * v;
        }
        if energy / m as f64 <= 1e-7 {
            return None; // below -70 dBFS: silence
        }
        let len = m - Self::LAG_MAX - 1;
        let mut e0 = 0.0;
        for j in 0..len {
            e0 += self.dec[j] * self.dec[j];
        }
        if e0 <= 1e-12 {
            return None;
        }
        let mut best = 0.0;
        let mut e1 = 0.0; // energy of the shifted part, slid along
        for j in 0..len {
            e1 += self.dec[j + Self::LAG_MIN - 1] * self.dec[j + Self::LAG_MIN - 1];
        }
        for lag in (Self::LAG_MIN - 1)..=(Self::LAG_MAX + 1) {
            let mut num = 0.0;
            for j in 0..len {
                num += self.dec[j] * self.dec[j + lag];
            }
            let r = if e1 > 1e-12 { num / (e0 * e1).sqrt() } else { 0.0 };
            if lag + len < m {
                e1 += self.dec[lag + len] * self.dec[lag + len] - self.dec[lag] * self.dec[lag];
            }
            self.rho[lag] = r;
            if (Self::LAG_MIN..=Self::LAG_MAX).contains(&lag) && r > best {
                best = r;
            }
        }
        if best <= 0.5 {
            return None;
        }
        // The shortest period that is nearly as good as the best one (the best alone often is two periods).
        for lag in Self::LAG_MIN..=Self::LAG_MAX {
            if self.rho[lag] >= 0.9 * best && self.rho[lag] >= self.rho[lag - 1] && self.rho[lag] >= self.rho[lag + 1] {
                let (a, b, c) = (self.rho[lag - 1], self.rho[lag], self.rho[lag + 1]);
                let den = a - 2.0 * b + c;
                let off = if den.abs() > 1e-12 { (0.5 * (a - c) / den).clamp(-0.5, 0.5) } else { 0.0 };
                return Some(sample_rate / 4.0 / (lag as f64 + off));
            }
        }
        None
    }

    /// Builds the output frame for `c` from the analyzed spectrum and queues one hop.
    pub fn synthesize(&mut self, c: &Controls) {
        let (n, bins) = (Self::N, Self::BINS);
        if c.is_neutral() {
            for k in 0..bins {
                self.yr[k] = self.xr[k];
                self.yi[k] = self.xi[k];
                self.theta[k] = 0.0;
            }
        } else {
            self.shift(c);
            if c.shapes_envelope() {
                self.shape_envelope(c);
            }
        }
        for k in 0..bins {
            self.pr[k] = self.xr[k];
            self.pi[k] = self.xi[k];
        }
        for k in 0..bins {
            let s: f64 = if k & 1 == 0 { 1.0 } else { -1.0 };
            self.re[k] = self.yr[k] * s;
            self.im[k] = self.yi[k] * s;
            if k > 0 && k < n / 2 {
                self.re[n - k] = self.re[k];
                self.im[n - k] = -self.im[k];
            }
        }
        self.im[0] = 0.0;
        self.im[n / 2] = 0.0;
        self.fft.transform(&mut self.re, &mut self.im, true);
        // Overlap-add (sqrt-Hann at 75 % overlap sums to 2), emit the finished hop.
        for k in 0..n {
            self.ola[k] += self.re[k] * self.window[k] * 0.5;
        }
        for k in 0..Self::HOP {
            self.fifo[(self.fifo_read + self.fifo_count) & (2 * n - 1)] = self.ola[k] as f32;
            self.fifo_count += 1;
        }
        for k in 0..(n - Self::HOP) {
            self.ola[k] = self.ola[k + Self::HOP];
        }
        for k in (n - Self::HOP)..n {
            self.ola[k] = 0.0;
        }
    }

    /// Moves every partial (peak and its region) to `ratio` times its frequency.
    fn shift(&mut self, c: &Controls) {
        let bins = Self::BINS;
        self.yr.fill(0.0);
        self.yi.fill(0.0);
        self.peak_count = 0;
        let mut k = 2;
        while k < bins - 2 {
            let m = self.mag[k];
            if m > 1e-9 && m > self.mag[k - 1] && m >= self.mag[k + 1] && m > self.mag[k - 2] && m >= self.mag[k + 2] {
                self.peaks[self.peak_count] = k;
                self.peak_count += 1;
                k += 2;
            }
            k += 1;
        }
        if self.peak_count == 0 {
            // Nothing tonal (silence, a click): passed on as it is.
            for i in 0..bins {
                self.yr[i] = self.xr[i];
                self.yi[i] = self.xi[i];
                self.theta[i] = 0.0;
            }
            return;
        }
        let two_pi = 2.0 * std::f64::consts::PI;
        let bins_per_radian = Self::N as f64 / (two_pi * Self::HOP as f64);
        let radians_per_bin = two_pi * Self::HOP as f64 / Self::N as f64;
        let mut lo = 0;
        for p in 0..self.peak_count {
            let k = self.peaks[p];
            let mut hi = bins - 1;
            if p + 1 < self.peak_count {
                // The region ends at the lowest bin before the next peak.
                let (mut mi, mut mv) = (k + 1, self.mag[k + 1]);
                let mut i = k + 2;
                while i < self.peaks[p + 1] {
                    if self.mag[i] < mv {
                        mv = self.mag[i];
                        mi = i;
                    }
                    i += 1;
                }
                hi = mi;
            }
            // True frequency from the phase advance since the last frame (expected: k quarter turns at hop = n / 4).
            let cr = self.xr[k] * self.pr[k] + self.xi[k] * self.pi[k];
            let ci = self.xi[k] * self.pr[k] - self.xr[k] * self.pi[k];
            let mut d = ci.atan2(cr) - radians_per_bin * (k & 3) as f64;
            d -= two_pi * (d / two_pi).round();
            let mut k_true = k as f64 + d * bins_per_radian;
            if (k_true - k as f64).abs() > 1.0 {
                k_true = k as f64; // onset or noise: no reliable advance
            }
            let s = k_true * (c.ratio - 1.0);
            let mut th = self.theta[k] + radians_per_bin * s;
            th -= two_pi * (th / two_pi).round();
            for i in lo..=hi {
                self.theta_next[i] = th;
            }
            let out = if c.jitter == 0.0 {
                th
            } else {
                th + c.jitter * Self::unit(c.jitter_key.wrapping_add((k as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)))
            };
            let (co, si) = (out.cos(), out.sin());
            let j0 = ((lo as f64 + s).ceil() as i64).max(0);
            let j1 = ((hi as f64 + s).floor() as i64).min(bins as i64 - 1);
            if j0 <= j1 {
                for j in j0 as usize..=j1 as usize {
                    // The block read at a fractional bin: Catmull-Rom across four bins.
                    let src = j as f64 - s;
                    let fl = src.floor();
                    let f = src - fl;
                    let i1 = (fl as i64).max(0).min(bins as i64 - 1) as usize;
                    let i0 = i1.saturating_sub(1);
                    let i2 = (bins - 1).min(i1 + 1);
                    let i3 = (bins - 1).min(i1 + 2);
                    let f2 = f * f;
                    let f3 = f2 * f;
                    let w0 = -0.5 * f3 + f2 - 0.5 * f;
                    let w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
                    let w2 = -1.5 * f3 + 2.0 * f2 + 0.5 * f;
                    let w3 = 0.5 * f3 - 0.5 * f2;
                    let a = w0 * self.xr[i0] + w1 * self.xr[i1] + w2 * self.xr[i2] + w3 * self.xr[i3];
                    let b = w0 * self.xi[i0] + w1 * self.xi[i1] + w2 * self.xi[i2] + w3 * self.xi[i3];
                    self.yr[j] += a * co - b * si;
                    self.yi[j] += a * si + b * co;
                }
            }
            lo = hi + 1;
        }
        std::mem::swap(&mut self.theta, &mut self.theta_next);
    }

    /// Re-weights the shifted spectrum: from the envelope it carries now to the wanted one.
    fn shape_envelope(&mut self, c: &Controls) {
        let (n, bins, reach) = (Self::N, Self::BINS, Self::ENVELOPE_REACH);
        for k in 0..bins {
            self.log_mag[k] = 0.5 * (self.mag[k] * self.mag[k] + 1e-14).ln();
        }
        for k in 0..bins {
            let mut m = self.log_mag[k];
            let mut i = k.saturating_sub(reach);
            let e = (bins - 1).min(k + reach);
            while i <= e {
                if self.log_mag[i] > m {
                    m = self.log_mag[i];
                }
                i += 1;
            }
            self.re[k] = m;
            if k > 0 && k < n / 2 {
                self.re[n - k] = m;
            }
        }
        self.im.fill(0.0);
        self.fft.transform(&mut self.re, &mut self.im, false);
        if c.coarse {
            self.cep.copy_from_slice(&self.re);
        }
        for q in 0..n {
            self.re[q] *= self.lift_fine[q];
            self.im[q] = 0.0;
        }
        self.fft.transform(&mut self.re, &mut self.im, true);
        self.env_fine.copy_from_slice(&self.re[..bins]);
        if c.coarse {
            for q in 0..n {
                self.re[q] = self.cep[q] * self.lift_coarse[q];
                self.im[q] = 0.0;
            }
            self.fft.transform(&mut self.re, &mut self.im, true);
            self.env_coarse.copy_from_slice(&self.re[..bins]);
        }
        let top = (bins - 1) as f64;
        let bend_end = 4_000.0 / 48_000.0 * n as f64; // the bend acts below 4 kHz
        let inv_ratio = 1.0 / c.ratio;
        let inv_formant = 1.0 / c.formant;
        for j in 0..bins {
            let x = j as f64;
            let mut from = x * inv_formant;
            if c.bend != 0.0 && x < bend_end {
                from += c.bend * (std::f64::consts::PI * x / bend_end).sin();
            }
            let at = top.min(from.max(0.0));
            let target = if c.coarse { Self::read(&self.env_coarse, at) } else { Self::read(&self.env_fine, at) };
            let current = Self::read(&self.env_fine, top.min(x * inv_ratio));
            let g = (target - current).clamp(-Self::MAX_ENVELOPE_GAIN, Self::MAX_ENVELOPE_GAIN).exp();
            self.yr[j] *= g;
            self.yi[j] *= g;
        }
    }

    /// `a` holds `BINS` values; `x` within 0...BINS - 1.
    #[inline]
    fn read(a: &[f64], x: f64) -> f64 {
        let i = x as usize;
        let f = x - i as f64;
        if i + 1 < Self::BINS { a[i] + (a[i + 1] - a[i]) * f } else { a[Self::BINS - 1] }
    }

    /// SplitMix64.
    #[inline]
    pub fn hash(x: u64) -> u64 {
        let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// -1...1 from a key.
    #[inline]
    pub fn unit(key: u64) -> f64 {
        (Self::hash(key) >> 11) as f64 / (1_u64 << 53) as f64 * 2.0 - 1.0
    }
}

impl Default for PitchVocoder {
    fn default() -> Self {
        PitchVocoder::new()
    }
}

/// Pitch Shift of a clip chain: one engine per channel.
pub struct PitchShiftStage {
    channels: Vec<PitchVocoder>,
}

impl PitchShiftStage {
    /// A stage for `channels` channels.
    pub fn new(channels: usize) -> Self {
        PitchShiftStage { channels: (0..channels).map(|_| PitchVocoder::new()).collect() }
    }

    /// Back to silence.
    pub fn reset(&mut self) {
        for c in &mut self.channels {
            c.reset();
        }
    }

    /// `from` at the first sample, `to` one block later (semitones). `enabled == false` runs neutral: the delay stays.
    pub fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        from: f64,
        to: f64,
        preserve_formants: bool,
        enabled: bool,
    ) {
        let step = (to - from) / n as f64;
        for (v, x) in self.channels.iter_mut().zip(buf.iter_mut()) {
            for i in 0..n {
                if v.push(x[i]) {
                    let mut ctl = Controls::default();
                    if enabled {
                        ctl.ratio = AudioPitchValues::ratio((from + step * i as f64).clamp(-24.0, 24.0));
                        ctl.formant = if preserve_formants { 1.0 } else { ctl.ratio };
                    }
                    v.analyze();
                    v.synthesize(&ctl);
                }
                x[i] = v.pop();
            }
        }
    }
}

/// Test hook of `DisguiseVoiceStage`: called with the step and the controls of every synthesized frame.
pub type TraceFn = Box<dyn FnMut(i64, &Controls) + Send>;

/// Disguise Voice of a clip chain. Not a pitch shifter with a fixed setting (that is undone by shifting back):
///
/// - the speaker's pitch is tracked and replaced: the output follows an invented melody (seeded noise around a fixed center),
///   so neither the speaker's average pitch nor the intonation is left in the output;
/// - the formants move by a factor that drifts over time, plus a bend that shifts the lower formants against the upper ones;
/// - the spectral envelope goes back blurred (detail narrower than about 1 kHz is discarded, not hidden);
/// - every partial gets a small random phase offset per frame; the channels are summed to mono.
///
/// The modulation is a function of the clip-local position and a seed derived from the effect's id, which exists only in the
/// project: an export holds the processed sound and nothing about the curves. It still is not anonymization: what is said,
/// rhythm, accent and wording stay, and speaker recognition trained on disguised speech does better than chance.
pub struct DisguiseVoiceStage {
    voc: PitchVocoder,
    fs: f64,
    rate: i64,
    seed: u64,
    /// Clip-local number of the next sample, counted in this stage's own sample rate.
    pos: i64,
    has_pos: bool,
    /// Tests: every synthesized frame as (step on the absolute hop grid, what the engine was told).
    pub trace: Option<TraceFn>,
    /// The untouched sound per channel, for "switched off".
    delay: Vec<Vec<f32>>,
    delay_pos: usize,
    log_ratio: f64,
    has_ratio: bool,
    was_off: bool,
}

impl DisguiseVoiceStage {
    const LATENCY: usize = AudioPitchValues::LATENCY_SAMPLES as usize;

    /// A stage for `channels` channels whose curves are seeded by `id`.
    pub fn new(sample_rate: f64, channels: usize, id: Id) -> Self {
        let (hi, lo) = MultibandMeterTap::split(id);
        DisguiseVoiceStage {
            voc: PitchVocoder::new(),
            fs: sample_rate,
            rate: sample_rate.round() as i64,
            seed: PitchVocoder::hash(hi ^ PitchVocoder::hash(lo)),
            pos: 0,
            has_pos: false,
            trace: None,
            delay: vec![vec![0.0; Self::LATENCY]; channels],
            delay_pos: 0,
            log_ratio: 0.0,
            has_ratio: false,
            was_off: true,
        }
    }

    /// Back to silence.
    pub fn reset(&mut self) {
        self.voc.reset();
        for p in &mut self.delay {
            p.fill(0.0);
        }
        self.delay_pos = 0;
        self.log_ratio = 0.0;
        self.has_ratio = false;
        self.was_off = true;
        self.has_pos = false;
    }

    /// Smooth seeded noise, -1...1; `x` counts in steps (one new random value per unit).
    #[inline]
    fn noise(&self, x: f64, lane: u64) -> f64 {
        let fl = x.floor();
        let f = x - fl;
        let i = (fl as i64) as u64;
        let base = self.seed.wrapping_add(lane.wrapping_mul(0xD6E8_FEB8_6659_FD93));
        let a = PitchVocoder::unit(base.wrapping_add(i));
        let b = PitchVocoder::unit(base.wrapping_add(i).wrapping_add(1));
        a + (b - a) * f * f * (3.0 - 2.0 * f)
    }

    /// What the engine does at `step` of the absolute hop grid (clip-local sample `step * HOP`): the seeded curves depend
    /// on the step alone, so playback from a seek point and an export from the start read the same values.
    /// `f0` = tracked pitch of the input, `None` while unvoiced.
    pub fn controls(&mut self, voice: i64, step: i64, f0: Option<f64>) -> Controls {
        let t = (step * PitchVocoder::HOP as i64) as f64 / self.fs;
        let high = voice == 1;
        // The invented melody: slow swings of +-2.5 semitones plus quicker ones of +-0.8 around the center.
        let target = (if high { 215.0 } else { 100.0 })
            * 2.0_f64.powf((2.5 * self.noise(t * 1.3, 1) + 0.8 * self.noise(t * 4.7, 2)) / 12.0);
        if let Some(f0) = f0 {
            let want = (target / f0).log2().clamp(-1.2, 1.2);
            self.log_ratio = if self.has_ratio { self.log_ratio + 0.5 * (want - self.log_ratio) } else { want };
            self.has_ratio = true;
        } else if !self.has_ratio {
            self.log_ratio = if high { 0.5 } else { -0.4 }; // nothing voiced yet: a plain shift in the chosen direction
        }
        Controls {
            ratio: 2.0_f64.powf(self.log_ratio),
            formant: (if high { 1.15 } else { 0.87 }) * 2.0_f64.powf(0.1 * self.noise(t * 0.9, 3)),
            bend: 250.0 / self.fs * PitchVocoder::N as f64 * self.noise(t * 0.7, 4),
            coarse: true,
            jitter: 0.3,
            jitter_key: PitchVocoder::hash(self.seed ^ (step as u64)),
        }
    }

    /// `at` = clip-local position of the block's first sample. Switched off: every channel delayed, untouched.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, voice: i64, at: Time, enabled: bool) {
        let chs = buf.len().min(self.delay.len());
        let len = Self::LATENCY;
        if chs == 0 {
            return;
        }
        // The stage counts its own samples; the block position only places the start and a jump (rounding moves it by one).
        let want = AudioPitchValues::sample(at, self.rate);
        let jumped = !self.has_pos || (want - self.pos).abs() > 1;
        if jumped {
            self.pos = want;
            self.has_pos = true;
        }
        // Starts from silence, never from the original; a jump is a new start as well.
        if enabled && (self.was_off || jumped) {
            self.voc.reset_at(self.pos);
            self.has_ratio = false;
        }
        self.was_off = !enabled;
        let scale = 1.0 / chs as f32;
        for i in 0..n {
            let mut mono = 0.0_f32;
            for (chan, delay) in buf.iter_mut().zip(self.delay.iter_mut()).take(chs) {
                let x = chan[i];
                mono += x;
                if !enabled {
                    chan[i] = delay[self.delay_pos];
                }
                delay[self.delay_pos] = x;
            }
            self.delay_pos = (self.delay_pos + 1) & (len - 1);
            self.pos += 1;
            if !enabled {
                continue;
            }
            if self.voc.push(mono * scale) {
                let f0 = self.voc.estimate_f0(self.fs);
                self.voc.analyze();
                let step = self.pos / PitchVocoder::HOP as i64; // exact: a hop completes on the grid only
                let c = self.controls(voice, step, f0);
                if let Some(trace) = self.trace.as_mut() {
                    trace(step, &c);
                }
                self.voc.synthesize(&c);
            }
            let y = self.voc.pop();
            for chan in buf.iter_mut().take(chs) {
                chan[i] = y;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use std::collections::BTreeMap;
    use std::sync::{Arc, Mutex};

    // Pitch Shift and Disguise Voice (F7.8): pitch accuracy, formants, delay, determinism.

    const FS: f64 = 48_000.0;

    fn fixed_id() -> Id {
        Id::parse("5B0C1E7A-2A4D-4F0B-9C55-0E6F3A1D7B21").unwrap_or(Id::NIL)
    }

    /// Feeds `x` to `f` in blocks of the cycling `sizes` (position of the block's first sample, planar block).
    fn run_blocks(x: &[Vec<f32>], sizes: &[usize], mut f: impl FnMut(i64, &mut [&mut [f32]], usize)) -> Vec<Vec<f32>> {
        let total = x[0].len();
        let mut out = x.to_vec();
        let (mut pos, mut i) = (0, 0);
        while pos < total {
            let len = sizes[i % sizes.len()].min(total - pos);
            let mut views: Vec<&mut [f32]> = out.iter_mut().map(|c| &mut c[pos..pos + len]).collect();
            f(pos as i64, &mut views, len);
            pos += len;
            i += 1;
        }
        out
    }

    fn pitch(x: &[Vec<f32>], semitones: f64, preserve: bool, sizes: &[usize], enabled: bool) -> Vec<Vec<f32>> {
        let mut stage = PitchShiftStage::new(x.len());
        run_blocks(x, sizes, |_, b, n| stage.process(b, n, semitones, semitones, preserve, enabled))
    }

    fn disguise(x: &[Vec<f32>], voice: i64, id: Id, sizes: &[usize], enabled: bool) -> Vec<Vec<f32>> {
        let mut stage = DisguiseVoiceStage::new(FS, x.len(), id);
        run_blocks(x, sizes, |pos, b, n| stage.process(b, n, voice, Time::new(pos, 48_000), enabled))
    }

    /// Magnitude of the Hann-windowed component at `f`.
    fn level(x: &[f32], f: f64) -> f64 {
        let (mut re, mut im) = (0.0, 0.0);
        let n = x.len() as f64;
        for (k, v) in x.iter().enumerate() {
            let w = 0.5 - 0.5 * (2.0 * std::f64::consts::PI * k as f64 / n).cos();
            let p = 2.0 * std::f64::consts::PI * f * k as f64 / FS;
            re += f64::from(*v) * w * p.cos();
            im += f64::from(*v) * w * p.sin();
        }
        4.0 * (re * re + im * im).sqrt() / n
    }

    /// The strongest frequency within `cents` of `near` (grid of `grid` cents, refined by a parabola).
    fn peak_frequency(x: &[f32], near: f64, cents: f64, grid: f64) -> f64 {
        let steps = (cents / grid) as i64;
        let (mut best, mut best_i) = (-1.0, 0_i64);
        let f = |i: i64| near * 2.0_f64.powf(i as f64 * grid / 1200.0);
        for i in -steps..=steps {
            let l = level(x, f(i));
            if l > best {
                best = l;
                best_i = i;
            }
        }
        let (a, c) = (level(x, f(best_i - 1)), level(x, f(best_i + 1)));
        let den = a - 2.0 * best + c;
        let off = if den.abs() > 1e-15 { 0.5 * (a - c) / den } else { 0.0 };
        near * 2.0_f64.powf((best_i as f64 + off) * grid / 1200.0)
    }

    fn cents(a: f64, b: f64) -> f64 {
        1200.0 * (a / b).log2()
    }

    /// Harmonics of `f0` up to 6 kHz; `weight(frequency)` is each one's amplitude.
    fn harmonics(f0: f64, seconds: f64, weight: impl Fn(f64) -> f64) -> Vec<f32> {
        let n = (seconds * FS) as usize;
        let mut out = vec![0.0_f64; n];
        let mut h = 1;
        while f64::from(h) * f0 < 6_000.0 {
            let f = f64::from(h) * f0;
            let a = weight(f);
            for (i, o) in out.iter_mut().enumerate() {
                *o += a * (2.0 * std::f64::consts::PI * f * i as f64 / FS + f64::from(h) * 0.7).sin();
            }
            h += 1;
        }
        let peak = out.iter().fold(0.0_f64, |m, v| m.max(v.abs()));
        out.iter().map(|v| (0.4 * v / peak) as f32).collect()
    }

    /// Center of the spectral envelope: amplitude-squared weighted mean frequency of the harmonics of `f0`.
    fn envelope_center(x: &[f32], f0: f64) -> f64 {
        let (mut num, mut den) = (0.0, 0.0);
        let mut h = 1;
        while f64::from(h) * f0 < 6_000.0 {
            let f = f64::from(h) * f0;
            let a = level(x, f);
            num += f * a * a;
            den += a * a;
            h += 1;
        }
        if den > 0.0 { num / den } else { 0.0 }
    }

    const ONE_BLOCK: [usize; 1] = [512];

    #[test]
    fn sine_lands_on_the_pitch() {
        let x = sig::mono(440.0, -12.0, 1.5, 48_000);
        // Formants free: a single sine has no envelope to keep (with Preserve Formants it would be held down at its new place).
        for st in [7.0, -5.0, 12.0, -12.0, 0.5, -0.07, 3.33] {
            let y = &pitch(std::slice::from_ref(&x), st, false, &ONE_BLOCK, true)[0];
            let want = 440.0 * 2.0_f64.powf(st / 12.0);
            let seg = &y[30_000..46_384];
            let got = peak_frequency(seg, want, 60.0, 1.0);
            assert!(cents(got, want).abs() < 2.0, "{st} st: {got} Hz, wanted {want}");
            assert!((sig::db(level(seg, got)) - -12.0).abs() < 1.0, "{st} st: level {} dB", sig::db(level(seg, got)));
        }
    }

    #[test]
    fn harmonic_tone_moves_every_partial() {
        let x = harmonics(150.0, 1.5, |f| 1.0 / (f / 150.0));
        for st in [4.0, -7.0] {
            let y = &pitch(std::slice::from_ref(&x), st, false, &ONE_BLOCK, true)[0];
            let f0 = 150.0 * 2.0_f64.powf(st / 12.0);
            for h in [1.0, 2.0, 3.0, 5.0, 8.0] {
                let got = peak_frequency(&y[30_000..62_768], h * f0, 60.0, 1.0);
                assert!(cents(got, h * f0).abs() < 3.0, "{st} st, partial {h}: {got} Hz, wanted {}", h * f0);
            }
        }
    }

    #[test]
    fn preserve_formants_keeps_the_envelope() {
        // A "vowel": harmonics of 120 Hz under one formant at 1 kHz.
        let x = harmonics(120.0, 1.5, |f| (-((f - 1_000.0) / 350.0).powi(2)).exp() + 0.02);
        let before = envelope_center(&x[30_000..62_768], 120.0);
        for st in [5.0, -5.0] {
            let r = 2.0_f64.powf(st / 12.0);
            let x1 = std::slice::from_ref(&x);
            let kept = envelope_center(&pitch(x1, st, true, &ONE_BLOCK, true)[0][30_000..62_768], 120.0 * r);
            let moved = envelope_center(&pitch(x1, st, false, &ONE_BLOCK, true)[0][30_000..62_768], 120.0 * r);
            // Without the option the center moves by 33 % (5 semitones); with it, it stays within 8 %.
            assert!((kept / before - 1.0).abs() < 0.08, "{st} st preserved: {kept} Hz, was {before}");
            assert!((moved / (before * r) - 1.0).abs() < 0.03, "{st} st free: {moved} Hz, wanted {}", before * r);
        }
    }

    #[test]
    fn delay_is_one_window_and_compensable() {
        let mut x = vec![0.0_f32; 16_384];
        x[5_000] = 0.8;
        let noise = sig::noise(0.3, 16_384, 7);
        let lat = AudioPitchValues::LATENCY_SAMPLES as usize;
        // 0 semitones, and any setting while switched off: the same sound, exactly one window later.
        let cases = [
            ("neutral impulse", vec![x.clone()], pitch(std::slice::from_ref(&x), 0.0, true, &ONE_BLOCK, true)),
            ("off impulse", vec![x.clone()], pitch(std::slice::from_ref(&x), 7.0, true, &ONE_BLOCK, false)),
            ("neutral noise", vec![noise.clone()], pitch(std::slice::from_ref(&noise), 0.0, false, &ONE_BLOCK, true)),
            (
                "disguise off",
                vec![noise.clone(), x.clone()],
                disguise(&[noise.clone(), x.clone()], 0, fixed_id(), &ONE_BLOCK, false),
            ),
        ];
        for (name, input, output) in &cases {
            for c in 0..input.len() {
                let err = (lat..input[c].len()).fold(0.0_f32, |m, i| m.max((output[c][i] - input[c][i - lat]).abs()));
                assert!(err < 2e-5, "{name}: {err}");
                let early = output[c][..lat].iter().fold(0.0_f32, |m, v| m.max(v.abs()));
                assert!(early < 1e-6, "{name}: sound before the delay");
            }
        }
        // A shifted impulse stays where it is in time (the delay does not depend on the shift).
        let y = &pitch(std::slice::from_ref(&x), 5.0, true, &ONE_BLOCK, true)[0];
        // The shifted impulse is smeared over a few hundred samples with several near-equal lobes, so the loudest sample
        // jumps between machines (libm differences move it by 56 samples on Linux); the energy centroid is stable.
        let (num, den) = y.iter().enumerate().fold((0.0_f64, 0.0_f64), |(n, d), (i, v)| {
            let e = f64::from(*v) * f64::from(*v);
            (n + e * i as f64, d + e)
        });
        let at = num / den;
        assert!((at - (5_000 + lat) as f64).abs() <= 48.0, "impulse centroid at {at}"); // within a millisecond
    }

    #[test]
    fn block_size_does_not_change_the_result() {
        let tone = harmonics(140.0, 1.0, |f| 1.0 / (f / 140.0));
        let x: Vec<f32> = tone.iter().zip(sig::noise(0.05, tone.len(), 3)).map(|(a, b)| a + b).collect();
        let odd = [1, 37, 480, 512, 129, 1_024, 7];
        let x1 = std::slice::from_ref(&x);
        assert_eq!(pitch(x1, 3.0, true, &ONE_BLOCK, true), pitch(x1, 3.0, true, &odd, true));
        let x2 = [x.clone(), x];
        assert_eq!(disguise(&x2, 0, fixed_id(), &ONE_BLOCK, true), disguise(&x2, 0, fixed_id(), &odd, true));
    }

    #[test]
    fn disguise_is_deterministic_per_effect_and_differs_between_effects() {
        let x = harmonics(130.0, 1.5, |f| (-((f - 900.0) / 500.0).powi(2)).exp() + 0.05);
        let x2 = [x.clone(), x.clone()];
        let a = disguise(&x2, 0, fixed_id(), &ONE_BLOCK, true);
        let b = disguise(&x2, 0, fixed_id(), &ONE_BLOCK, true);
        let other = disguise(&x2, 0, Id::from_u128(77), &ONE_BLOCK, true);
        assert_eq!(a, b);
        assert_eq!(a[0], a[1]);
        assert!(a[0].iter().all(|v| v.is_finite()));
        let diff: Vec<f32> = a[0].iter().zip(&other[0]).map(|(p, q)| p - q).collect();
        assert!(sig::rms(&diff[20_000..]) > 0.3 * sig::rms(&a[0][20_000..]));
        let gain = sig::db(sig::rms(&a[0][20_000..])) - sig::db(sig::rms(&x[20_000..]));
        assert!(gain.abs() < 9.0, "level change {gain} dB");
    }

    type Steps = Arc<Mutex<BTreeMap<i64, Controls>>>;

    fn render(rate: f64, x: &[f32], start: usize, block: usize) -> (Steps, Vec<f32>) {
        let mut stage = DisguiseVoiceStage::new(rate, 1, fixed_id());
        let steps: Steps = Arc::default();
        let sink = Arc::clone(&steps);
        stage.trace = Some(Box::new(move |step, c| {
            sink.lock().unwrap().insert(step, *c);
        }));
        let mut out = vec![];
        let mut pos = start;
        while pos < x.len() {
            let n = block.min(x.len() - pos);
            let mut b = x[pos..pos + n].to_vec();
            stage.process(&mut [b.as_mut_slice()], n, 0, Time::new(pos as i64, rate as i64), true);
            out.extend(b);
            pos += n;
        }
        (steps, out)
    }

    /// Playback after a seek and an export from the start: the seeded curves are read on one absolute hop grid, at any
    /// sample rate, so both get the same values for the same place in the clip.
    #[test]
    fn seek_lands_on_the_same_curve_as_a_render_from_the_start() {
        for rate in [48_000.0, 44_100.0] {
            let (total, seek) = (3 * rate as usize, rate as usize + 1_237); // off the hop grid on purpose
            let x: Vec<f32> = (0..total)
                .map(|i| {
                    let v: f64 = (1..=8)
                        .map(|h| {
                            (2.0 * std::f64::consts::PI * 140.0 * f64::from(h) * i as f64 / rate).sin() / f64::from(h)
                        })
                        .sum();
                    (0.2 * v) as f32
                })
                .collect();
            let (whole, _) = render(rate, &x, 0, 512);
            let (part, _) = render(rate, &x, seek, 441);
            let (whole, part) = (whole.lock().unwrap(), part.lock().unwrap());
            let shared: Vec<i64> = whole.keys().filter(|k| part.contains_key(k)).copied().collect();
            // Every frame of the seeked render sits on the grid of the full one.
            assert!(shared.len() == part.len() && shared.len() > 50);
            assert_eq!(shared.first().copied(), Some((seek / 512 + 1) as i64));
            for k in &shared {
                let (a, b) = (whole[k], part[k]);
                assert!(a.formant == b.formant && a.bend == b.bend && a.jitter_key == b.jitter_key, "step {k}");
            }
            // The pitch target follows the same curve; the follower needs a few frames after the seek to arrive on it.
            for k in shared.iter().skip(40) {
                assert!((whole[k].ratio / part[k].ratio - 1.0).abs() < 1e-6, "step {k}");
            }
            // Same delay from any start. With silence before the sound both renders have the same history, so the seeked one
            // must give the very same samples at the same places (a shifted grid or delay would move them).
            let burst: Vec<f32> = (0..20_000)
                .map(|i| {
                    if (6_000..12_000).contains(&i) {
                        (0.3 * (2.0 * std::f64::consts::PI * 180.0 * i as f64 / rate).sin()) as f32
                    } else {
                        0.0
                    }
                })
                .collect();
            let b0 = render(rate, &burst, 0, 512).1;
            let b1 = render(rate, &burst, 1_237, 300).1;
            let worst = b0[1_237..].iter().zip(&b1).fold(0.0_f32, |m, (p, q)| m.max((p - q).abs()));
            assert!(worst < 1e-5, "largest difference {worst}");
            assert!(sig::rms(&b1[8_000..12_000]) > 0.01);
            // Two rates count the same place in the clip: the slow curves agree where both grids meet (step 0 of each).
            let mut other = DisguiseVoiceStage::new(if rate == 48_000.0 { 44_100.0 } else { 48_000.0 }, 1, fixed_id());
            let mut here = DisguiseVoiceStage::new(rate, 1, fixed_id());
            assert_eq!(here.controls(0, 0, None).formant, other.controls(0, 0, None).formant);
        }
    }

    /// The point of the disguise: the pitch that comes out is the invented one, not a function of the speaker's.
    #[test]
    fn disguised_pitch_does_not_follow_the_speaker() {
        let track = |f0: f64| -> Vec<f64> {
            let x = harmonics(f0, 4.0, |f| (-((f - 900.0) / 600.0).powi(2)).exp() + 0.1);
            let y = &disguise(&[x], 0, fixed_id(), &ONE_BLOCK, true)[0];
            (24_000..180_000).step_by(12_000).map(|at| peak_frequency(&y[at..at + 8_192], 100.0, 700.0, 5.0)).collect()
        };
        let (low, high) = (track(110.0), track(165.0)); // two "speakers" a fifth apart
        for (a, b) in low.iter().zip(&high) {
            assert!(cents(*a, *b).abs() < 60.0, "{a} Hz against {b} Hz");
            assert!(*a > 70.0 && *a < 140.0);
        }
        // And it moves: the melody is not a constant either.
        let spread = cents(low.iter().copied().fold(0.0, f64::max), low.iter().copied().fold(f64::MAX, f64::min));
        assert!(spread > 100.0, "pitch range {spread} cents");
    }

    #[test]
    fn higher_voice_goes_up() {
        let x = harmonics(110.0, 2.0, |f| (-((f - 900.0) / 600.0).powi(2)).exp() + 0.1);
        let y = &disguise(&[x], 1, fixed_id(), &ONE_BLOCK, true)[0];
        let f = peak_frequency(&y[48_000..56_192], 215.0, 700.0, 5.0);
        assert!(f > 150.0 && f < 300.0, "{f} Hz");
    }

    #[test]
    fn switching_on_mid_clip_never_leaks_the_original_voice() {
        // Off for the first half, on for the second: after the delay, what comes out is processed from its first sample.
        let x = harmonics(130.0, 2.0, |f| 1.0 / (f / 130.0));
        let mut stage = DisguiseVoiceStage::new(FS, 1, Id::from_u128(5));
        let out = &run_blocks(std::slice::from_ref(&x), &ONE_BLOCK, |pos, b, n| {
            stage.process(b, n, 0, Time::new(pos, 48_000), pos >= 48_000);
        })[0];
        let lat = AudioPitchValues::LATENCY_SAMPLES as usize;
        let on = 48_128; // first block boundary at or after 48 000
        let same = (on..on + lat).filter(|&i| (out[i] - x[i - lat]).abs() < 1e-4 && x[i - lat].abs() > 0.01).count();
        assert!(same < lat / 50, "{same} samples of the original after switching on");
    }
}
