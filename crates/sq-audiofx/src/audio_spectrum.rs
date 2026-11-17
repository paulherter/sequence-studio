//! Port of `SQAudioFX/Sources/SQAudioFX/AudioSpectrum.swift`.

use crate::de_reverb::FFTRadix2;
use crate::multiband_meters::MultibandMeterTap;
use sq_core_time::Id;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

struct Ring {
    samples: Vec<f32>,
    pos: usize,
}

/// Per-clip spectrum feed for the effect popups (Multiband / EQ): the UI names ONE effect to watch and whether it wants the
/// sound before ("Spectrum at Input") or after the effect. Every `ClipAudioFXChain` holding that effect copies its block
/// (channels averaged to mono) into a ring of the last `SpectrumAnalyzer::SIZE` samples; the UI copies the ring out at
/// ~30 Hz and runs the FFT itself (`SpectrumAnalyzer`), so the audio thread never does an FFT.
///
/// Realtime: a chain not holding the watched effect pays one atomic load per stage and block. The watched one writes
/// under `try_lock` (never waits: if the UI is copying at that moment, that block is skipped) and never
/// allocates (the ring is preallocated and only written in place; the UI copies element-wise into its own array, so the
/// ring's storage is never shared). Whatever chain runs the effect feeds it (playback, scrub, export); nothing is
/// estimated: no audio = no new sequence.
pub struct AudioSpectrumTap {
    watching: AtomicBool,
    input: AtomicBool,
    id_hi: AtomicU64,
    id_lo: AtomicU64,
    seq: AtomicU64,
    ring: Mutex<Ring>,
}

impl Default for AudioSpectrumTap {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioSpectrumTap {
    /// The process-wide tap the chains use unless given another one.
    pub fn shared() -> &'static AudioSpectrumTap {
        static SHARED: OnceLock<AudioSpectrumTap> = OnceLock::new();
        SHARED.get_or_init(AudioSpectrumTap::new)
    }

    pub fn new() -> Self {
        AudioSpectrumTap {
            watching: AtomicBool::new(false),
            input: AtomicBool::new(false),
            id_hi: AtomicU64::new(0),
            id_lo: AtomicU64::new(0),
            seq: AtomicU64::new(0),
            ring: Mutex::new(Ring { samples: vec![0.0; SpectrumAnalyzer::SIZE], pos: 0 }),
        }
    }

    /// The effect whose chain publishes (None stops all publishing); `at_input` = the sound going into it, else coming out.
    /// Clears the ring, so nothing of the previous effect shows.
    pub fn watch(&self, id: Option<Id>, at_input: bool) {
        self.watching.store(false, Ordering::Release);
        let Some(id) = id else { return };
        let (h, l) = MultibandMeterTap::split(id);
        self.id_hi.store(h, Ordering::Relaxed);
        self.id_lo.store(l, Ordering::Relaxed);
        self.input.store(at_input, Ordering::Relaxed);
        if let Ok(mut r) = self.ring.lock() {
            r.samples.fill(0.0);
            r.pos = 0;
        }
        self.watching.store(true, Ordering::Release);
    }

    /// Audio thread: is the effect with this (pre-split) id the watched one? One to three atomic loads.
    pub(crate) fn is_watched(&self, hi: u64, lo: u64) -> bool {
        self.watching.load(Ordering::Acquire)
            && self.id_hi.load(Ordering::Relaxed) == hi
            && self.id_lo.load(Ordering::Relaxed) == lo
    }

    /// Audio thread: tap the input (true) or the output (false) of the watched effect.
    pub(crate) fn at_input(&self) -> bool {
        self.input.load(Ordering::Relaxed)
    }

    /// Audio thread: one block, channels averaged. Never waits, never allocates.
    pub(crate) fn push(&self, buf: &[&mut [f32]], frames: usize) {
        let chs = buf.len();
        if chs == 0 || frames == 0 {
            return;
        }
        let scale = 1.0 / chs as f32;
        let Ok(mut r) = self.ring.try_lock() else { return };
        let size = r.samples.len();
        let mut pos = r.pos;
        for i in 0..frames {
            let mut v: f32 = 0.0;
            for c in buf {
                v += c[i];
            }
            r.samples[pos] = v * scale;
            pos += 1;
            if pos == size {
                pos = 0;
            }
        }
        r.pos = pos;
        self.seq.fetch_add(1, Ordering::Release);
    }

    /// Published blocks so far.
    pub fn sequence(&self) -> u64 {
        self.seq.load(Ordering::Acquire)
    }

    /// UI: the last `SpectrumAnalyzer::SIZE` samples (oldest first) into `out` when `id` is the watched effect, and the
    /// sequence they belong to (0 = nothing published since `watch`); None when `id` is not watched.
    pub fn snapshot(&self, id: Id, out: &mut Vec<f32>) -> Option<u64> {
        let (h, l) = MultibandMeterTap::split(id);
        if !self.is_watched(h, l) {
            return None;
        }
        if out.len() != SpectrumAnalyzer::SIZE {
            *out = vec![0.0; SpectrumAnalyzer::SIZE];
        }
        let s = self.seq.load(Ordering::Acquire);
        if let Ok(r) = self.ring.lock() {
            let size = r.samples.len();
            for (i, o) in out.iter_mut().enumerate() {
                *o = r.samples[(r.pos + i) % size];
            }
        }
        Some(s)
    }
}

/// Magnitude spectrum for the display: Hann-windowed FFT of `SIZE` samples, read out at log-spaced frequencies
/// 20 Hz...20 kHz as the level of a sine (dBFS: a full-scale sine reads 0 dB), clamped at `FLOOR_DB`. Main thread only.
pub struct SpectrumAnalyzer {
    fft: FFTRadix2,
    window: Vec<f64>,
    re: Vec<f64>,
    im: Vec<f64>,
    mag: Vec<f64>,
}

impl Default for SpectrumAnalyzer {
    fn default() -> Self {
        Self::new()
    }
}

impl SpectrumAnalyzer {
    pub const SIZE: usize = 4_096;
    pub const FLOOR_DB: f32 = -120.0;
    pub const MIN_HZ: f64 = 20.0;
    pub const MAX_HZ: f64 = 20_000.0;

    pub fn new() -> Self {
        SpectrumAnalyzer {
            fft: FFTRadix2::new(Self::SIZE),
            window: (0..Self::SIZE)
                .map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / Self::SIZE as f64).cos())
                .collect(),
            re: vec![0.0; Self::SIZE],
            im: vec![0.0; Self::SIZE],
            mag: vec![0.0; Self::SIZE / 2 + 1],
        }
    }

    /// `points` frequencies, log-spaced from `MIN_HZ` to `MAX_HZ` inclusive.
    pub fn frequencies(points: usize) -> Vec<f64> {
        if points <= 1 {
            return vec![Self::MIN_HZ];
        }
        let a = Self::MIN_HZ.ln();
        let b = Self::MAX_HZ.ln();
        (0..points).map(|i| (a + (b - a) * i as f64 / (points - 1) as f64).exp()).collect()
    }

    /// One reading per frequency of `frequencies(points)`: the strongest bin in the point's slice of the axis, or (where
    /// the points are denser than the bins, in the lows) the magnitude interpolated between the two nearest bins.
    pub fn magnitudes_db(&mut self, samples: &[f32], sample_rate: f64, points: usize) -> Vec<f32> {
        let n = Self::SIZE;
        for i in 0..n {
            self.re[i] = if i < samples.len() { f64::from(samples[i]) * self.window[i] } else { 0.0 };
            self.im[i] = 0.0;
        }
        self.fft.transform(&mut self.re, &mut self.im, false);
        // Sine amplitude: 2|X| / (n x coherent gain 0.5).
        for k in 0..=(n / 2) {
            self.mag[k] = 4.0 * (self.re[k] * self.re[k] + self.im[k] * self.im[k]).sqrt() / n as f64;
        }
        let df = sample_rate / n as f64;
        let freqs = Self::frequencies(points);
        let half = if points > 1 { (Self::MAX_HZ.ln() - Self::MIN_HZ.ln()) / (points - 1) as f64 / 2.0 } else { 0.0 };
        freqs
            .iter()
            .map(|&f| {
                let lo = f * (-half).exp() / df;
                let hi = f * half.exp() / df;
                let k0 = lo.ceil() as usize;
                let k1 = (hi.floor() as usize).min(n / 2);
                let mut a: f64 = 0.0;
                if k0 <= k1 {
                    for k in k0..=k1 {
                        a = a.max(self.mag[k]);
                    }
                } else {
                    let x = (f / df).min((n / 2) as f64);
                    let i = x as usize;
                    let t = x - i as f64;
                    a = self.mag[i] * (1.0 - t) + self.mag[(i + 1).min(n / 2)] * t;
                }
                if a > 0.0 { Self::FLOOR_DB.max((20.0 * a.log10()) as f32) } else { Self::FLOOR_DB }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;

    #[test]
    fn sine_peaks_at_its_frequency_with_its_level() {
        let mut a = SpectrumAnalyzer::new();
        let x = sig::mono(1_000.0, -20.0, 0.2, 48_000);
        let pts = SpectrumAnalyzer::frequencies(128);
        let db = a.magnitudes_db(&x[x.len() - SpectrumAnalyzer::SIZE..], 48_000.0, 128);
        assert_eq!(db.len(), 128);
        let nearest = |hz: f64| {
            (0..pts.len()).min_by(|&i, &j| (pts[i] / hz).ln().abs().total_cmp(&(pts[j] / hz).ln().abs())).unwrap_or(0)
        };
        let i1k = nearest(1_000.0);
        assert!((f64::from(db[i1k]) + 20.0).abs() < 1.5, "1 kHz reads {} dB", db[i1k]);
        let (i100, i8k) = (nearest(100.0), nearest(8_000.0));
        assert!(db[i100] < -70.0 && db[i8k] < -70.0, "leak {} {}", db[i100], db[i8k]);
        let max = db.iter().copied().fold(f32::MIN, f32::max);
        assert!(max == db[i1k] || (f64::from(max) - f64::from(db[i1k])).abs() < 0.5);
    }

    #[test]
    fn silence_reads_the_floor_and_frequencies_are_log_spaced() {
        let db = SpectrumAnalyzer::new().magnitudes_db(&[0.0; SpectrumAnalyzer::SIZE], 48_000.0, 64);
        assert!(db.iter().all(|&v| v == SpectrumAnalyzer::FLOOR_DB));
        let f = SpectrumAnalyzer::frequencies(64);
        assert!((f[0] - 20.0).abs() < 1e-9 && (f[63] - 20_000.0).abs() < 1e-6);
        assert!((f[1] / f[0] - f[63] / f[62]).abs() < 1e-9);
    }

    #[test]
    fn snapshot_is_oldest_first_and_holds_the_latest_samples() {
        let tap = AudioSpectrumTap::new();
        let id = Id::from_u128(7);
        tap.watch(Some(id), false);
        let n = SpectrumAnalyzer::SIZE + 300;
        let mut ramp: Vec<f32> = (0..n).map(|i| i as f32).collect();
        tap.push(&[ramp.as_mut_slice()], n);
        let mut out = Vec::new();
        assert_eq!(tap.snapshot(id, &mut out), Some(1));
        assert!(out.first() == Some(&((n - SpectrumAnalyzer::SIZE) as f32)) && out.last() == Some(&((n - 1) as f32)));
    }

    #[test]
    fn nothing_is_published_unless_watched() {
        let tap = AudioSpectrumTap::new();
        let id = Id::from_u128(1);
        let mut out = Vec::new();
        assert_eq!(tap.sequence(), 0);
        assert_eq!(tap.snapshot(id, &mut out), None);
        tap.watch(Some(Id::from_u128(2)), false); // another effect
        assert_eq!(tap.snapshot(id, &mut out), None);
    }
}
