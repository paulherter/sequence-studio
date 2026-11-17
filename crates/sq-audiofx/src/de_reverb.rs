//! Port of `SQAudioFX/Sources/SQAudioFX/DeReverb.swift`.

use sq_core_audio::audio_effects::AudioDeReverbValues;

const PI: f64 = std::f64::consts::PI;

/// De-Reverb: spectral suppression of the late reverberant tail (STFT, 1024 window, 256 hop, sqrt-Hann analysis and synthesis).
///
/// Model (Lebart-style late reverb estimate, simplified): the tail energy in a band now is the band's energy `delay` ago, decayed
/// by the room's reverb time: `tail = P(t - delay) x 10^(-6 delay / RT60)`. A band only counts as "tail" when it actually falls
/// like a tail (`d` = how close its fall is to the room's decay, 0 for steady or rising sound), so held vowels and onsets are left
/// alone. Gain per band = `max(floor, 1 - over x tail / P)`; the gain drops smoothly and rises at once (speech onsets stay clean).
///
/// Delay: exactly `AudioDeReverbValues::LATENCY_SAMPLES` (= the window), also while the effect is off or at 0 %.
/// The constants (50 ms delay, over-subtraction, 24 dB floor at 100 %, band width) are ours, tuned on synthetic tails: unsourced.
pub(crate) struct DeReverbChannel {
    fft: FFTRadix2,
    window: Vec<f64>,
    /// Last n input samples, circular.
    in_ring: Vec<f64>,
    in_pos: usize,
    ola: Vec<f64>,
    /// Circular output queue.
    fifo: Vec<f32>,
    fifo_read: usize,
    fifo_count: usize,
    since_frame: usize,
    re: Vec<f64>,
    im: Vec<f64>,
    smoothed: Vec<f64>,
    /// Band powers of the last `DELAY_FRAMES + 1` frames, flat.
    history: Vec<f64>,
    band: Vec<f64>,
    hist_pos: usize,
    gain_band: Vec<f64>,
    gain_bin: Vec<f64>,
}

impl DeReverbChannel {
    const N: usize = 1_024;
    const HOP: usize = 256;
    const BINS: usize = Self::N / 2 + 1;
    const BAND_BINS: usize = 8;
    const BANDS: usize = Self::BINS.div_ceil(Self::BAND_BINS);
    /// Frames between the current spectrum and the one the tail estimate is taken from (50 ms).
    const DELAY_FRAMES: usize = 10;

    pub(crate) fn new() -> Self {
        let mut c = DeReverbChannel {
            fft: FFTRadix2::new(1_024),
            window: (0..Self::N).map(|i| (0.5 - 0.5 * (2.0 * PI * i as f64 / Self::N as f64).cos()).sqrt()).collect(),
            in_ring: vec![0.0; Self::N],
            in_pos: 0,
            ola: vec![0.0; Self::N],
            fifo: vec![0.0; 2 * Self::N],
            fifo_read: 0,
            fifo_count: 0,
            since_frame: 0,
            re: vec![0.0; Self::N],
            im: vec![0.0; Self::N],
            smoothed: vec![0.0; Self::BANDS],
            history: vec![0.0; (Self::DELAY_FRAMES + 1) * Self::BANDS],
            band: vec![0.0; Self::BANDS],
            hist_pos: 0,
            gain_band: vec![1.0; Self::BANDS],
            gain_bin: vec![1.0; Self::BINS],
        };
        c.reset();
        c
    }

    pub(crate) fn reset(&mut self) {
        self.in_ring.fill(0.0);
        self.ola.fill(0.0);
        for i in 0..self.smoothed.len() {
            self.smoothed[i] = 0.0;
            self.gain_band[i] = 1.0;
        }
        self.history.fill(0.0);
        self.gain_bin.fill(1.0);
        self.in_pos = 0;
        self.hist_pos = 0;
        self.since_frame = 0;
        self.fifo.fill(0.0);
        self.fifo_read = 0;
        // the pre-fill: the rest of the delay is the window
        self.fifo_count = AudioDeReverbValues::LATENCY_SAMPLES as usize - (Self::N - Self::HOP);
    }

    /// In place. `amount` 0...1, `decay` = reverb time in seconds, `tone` -1...1.
    pub(crate) fn process(
        &mut self,
        x: &mut [f32],
        frames: usize,
        amount: f64,
        decay: f64,
        tone: f64,
        sample_rate: f64,
    ) {
        for s in x.iter_mut().take(frames) {
            self.in_ring[self.in_pos] = f64::from(*s);
            self.in_pos = (self.in_pos + 1) % Self::N;
            self.since_frame += 1;
            if self.since_frame == Self::HOP {
                self.since_frame = 0;
                self.frame(amount, decay, tone, sample_rate);
            }
            *s = self.fifo[self.fifo_read];
            self.fifo_read = (self.fifo_read + 1) % self.fifo.len();
            self.fifo_count -= 1;
        }
    }

    fn frame(&mut self, amount: f64, decay: f64, tone: f64, sample_rate: f64) {
        let n = Self::N;
        for k in 0..n {
            self.re[k] = self.in_ring[(self.in_pos + k) % n] * self.window[k]; // oldest first
            self.im[k] = 0.0;
        }
        self.fft.transform(&mut self.re, &mut self.im, false);

        // Band powers, smoothed over time a little.
        for b in 0..Self::BANDS {
            let (mut p, mut c) = (0.0, 0.0);
            for k in (b * Self::BAND_BINS)..((b + 1) * Self::BAND_BINS).min(Self::BINS) {
                p += self.re[k] * self.re[k] + self.im[k] * self.im[k];
                c += 1.0;
            }
            self.band[b] = p / c;
            self.smoothed[b] = 0.5 * self.smoothed[b] + 0.5 * self.band[b];
        }
        let old_base = self.hist_pos * Self::BANDS; // the frame `DELAY_FRAMES` ago (the slot we are about to overwrite)
        self.hist_pos = (self.hist_pos + 1) % (Self::DELAY_FRAMES + 1);

        let amount = amount.clamp(0.0, 1.0);
        let hop_sec = Self::HOP as f64 / sample_rate;
        let delay_sec = Self::DELAY_FRAMES as f64 * hop_sec;
        let a = 10.0_f64.powf(-6.0 * delay_sec / decay.max(0.05)); // power left after `delay` of tail decay
        let floor_pow = 10.0_f64.powf(-2.4 * amount); // 24 dB at 100 %
        let over = 0.5 + amount;
        for b in 0..Self::BANDS {
            let p = self.smoothed[b];
            let pd = self.history[old_base + b];
            self.history[old_base + b] = p;
            let mut target = 1.0;
            if amount > 0.0 && pd > 1e-9 && p > 1e-12 {
                let d = ((1.0 - p / pd) / (1.0 - a)).clamp(0.0, 1.0);
                let f = ((b * Self::BAND_BINS) as f64 + Self::BAND_BINS as f64 / 2.0) * sample_rate / n as f64;
                let w = 2.0_f64.powf(tone * (f.max(62.5) / 1000.0).log2() / 2.0).clamp(0.25, 4.0);
                let ratio = (a * pd * d / p * w).min(1.0);
                target = (floor_pow.max(1.0 - over * ratio)).sqrt();
            }
            // Down slowly (no gulps), up at once (onsets stay clean).
            self.gain_band[b] = if target > self.gain_band[b] {
                target
            } else {
                self.gain_band[b] + (target - self.gain_band[b]) * 0.5
            };
        }
        // Bands to bins, smoothed across the band edges.
        for k in 0..Self::BINS {
            self.gain_bin[k] = self.gain_band[(k / Self::BAND_BINS).min(Self::BANDS - 1)];
        }
        if amount > 0.0 {
            let mut prev = self.gain_bin[0];
            for k in 1..(Self::BINS - 1) {
                let cur = self.gain_bin[k];
                self.gain_bin[k] = 0.25 * prev + 0.5 * cur + 0.25 * self.gain_bin[k + 1];
                prev = cur;
            }
        }
        for k in 0..Self::BINS {
            let g = self.gain_bin[k];
            self.re[k] *= g;
            self.im[k] *= g;
            if k > 0 && k < n / 2 {
                self.re[n - k] = self.re[k];
                self.im[n - k] = -self.im[k];
            }
        }
        self.fft.transform(&mut self.re, &mut self.im, true);

        // Overlap-add (sqrt-Hann at 75 % overlap sums to 2), emit the finished hop.
        for k in 0..n {
            self.ola[k] += self.re[k] * self.window[k] * 0.5;
        }
        for k in 0..Self::HOP {
            let at = (self.fifo_read + self.fifo_count) % self.fifo.len();
            self.fifo[at] = self.ola[k] as f32;
            self.fifo_count += 1;
        }
        for k in 0..(n - Self::HOP) {
            self.ola[k] = self.ola[k + Self::HOP];
        }
        for k in (n - Self::HOP)..n {
            self.ola[k] = 0.0;
        }
    }
}

/// Radix-2 complex FFT of `size` points (a power of two; in place, forward unscaled, inverse scaled by 1/n).
/// De-Reverb uses 1024, the spectrum display 4096.
pub(crate) struct FFTRadix2 {
    n: usize,
    cos_t: Vec<f64>,
    sin_t: Vec<f64>,
    rev: Vec<usize>,
}

impl FFTRadix2 {
    pub(crate) fn new(size: usize) -> Self {
        assert!(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two");
        let bits = size.trailing_zeros();
        FFTRadix2 {
            n: size,
            cos_t: (0..size / 2).map(|i| (2.0 * PI * i as f64 / size as f64).cos()).collect(),
            sin_t: (0..size / 2).map(|i| -(2.0 * PI * i as f64 / size as f64).sin()).collect(),
            rev: (0..size)
                .map(|i| {
                    let (mut r, mut v) = (0, i);
                    for _ in 0..bits {
                        r = (r << 1) | (v & 1);
                        v >>= 1;
                    }
                    r
                })
                .collect(),
        }
    }

    pub(crate) fn transform(&self, re: &mut [f64], im: &mut [f64], inverse: bool) {
        let n = self.n;
        for i in 0..n {
            if i < self.rev[i] {
                re.swap(i, self.rev[i]);
                im.swap(i, self.rev[i]);
            }
        }
        let mut len = 2;
        while len <= n {
            let half = len / 2;
            let step = n / len;
            let mut start = 0;
            while start < n {
                for j in 0..half {
                    let wr = self.cos_t[j * step];
                    let wi = if inverse { -self.sin_t[j * step] } else { self.sin_t[j * step] };
                    let a = start + j;
                    let b = a + half;
                    let tr = re[b] * wr - im[b] * wi;
                    let ti = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
                start += len;
            }
            len <<= 1;
        }
        if inverse {
            let s = 1.0 / n as f64;
            for i in 0..n {
                re[i] *= s;
                im[i] *= s;
            }
        }
    }
}

/// The De-Reverb stage of a clip chain: one channel processor per channel.
pub(crate) struct DeReverbStage {
    channels: Vec<DeReverbChannel>,
    fs: f64,
}

impl DeReverbStage {
    pub(crate) fn new(sample_rate: f64, channels: usize) -> Self {
        DeReverbStage { channels: (0..channels).map(|_| DeReverbChannel::new()).collect(), fs: sample_rate }
    }

    pub(crate) fn reset(&mut self) {
        for c in &mut self.channels {
            c.reset();
        }
    }

    /// `enabled == false` runs at 0 % so the delay stays (the chain's latency counts this stage while it is off).
    pub(crate) fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        amount: f64,
        decay: f64,
        tone: f64,
        enabled: bool,
    ) {
        let chs = buf.len();
        for (c, ch) in self.channels.iter_mut().enumerate().take(chs) {
            ch.process(buf[c], n, if enabled { amount } else { 0.0 }, decay, tone, self.fs);
        }
    }
}
