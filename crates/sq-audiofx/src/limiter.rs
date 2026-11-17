// Swift: Limiter.swift
//! Stereo-linked master peak limiter at the sequence's true-peak ceiling (`DeliveryTarget.truePeakDB`).
//!
//! Zero latency (no look-ahead), so the playback clock and export alignment do not change: the gain drops instantly to
//! exactly what the loudest channel needs (`ceiling / peak`), is held for `hold_ms`, then recovers exponentially towards
//! unity with the `release_ms` time constant. The sample peak of the output therefore never exceeds the ceiling; the
//! export's loudness pass still measures true peak and keeps its own ceiling. Below the ceiling the signal passes bit-exact.
//!
//! Realtime-safe: a plain value, `process` never allocates or locks. One instance per mix thread.

use crate::gain::GainMath;

/// The master peak limiter.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MasterLimiter {
    /// Sample rate in Hz.
    pub sample_rate: i64,
    /// Ceiling in dB.
    pub ceiling_db: f64,
    /// Linear ceiling, rounded down to the nearest Float so the Float output can never land above it.
    pub ceiling: f64,
    ceiling_f: f32,
    hold_samples: i64,
    release_coef: f64,
    /// 0 = the gain drops at once (default). Above 0 the gain falls towards what the peak needs with this one-pole
    /// coefficient; what it has not caught yet is clipped at the ceiling, so the ceiling still holds (zero latency).
    attack_coef: f64,
    /// Attack time (ms) the limiter was built with.
    pub attack_ms: f64,
    gain: f64,
    hold: i64,
}

impl MasterLimiter {
    /// Limiter with the default release (100 ms), hold (5 ms) and attack (0).
    pub fn new(sample_rate: i64, ceiling_db: f64) -> Self {
        Self::with_times(sample_rate, ceiling_db, 100.0, 5.0, 0.0)
    }

    /// Limiter with explicit times.
    pub fn with_times(sample_rate: i64, ceiling_db: f64, release_ms: f64, hold_ms: f64, attack_ms: f64) -> Self {
        let exact = GainMath::linear_from_db(ceiling_db);
        let mut f = exact as f32;
        if f64::from(f) > exact {
            f = f.next_down();
        }
        let rate = sample_rate as f64;
        let atk = if attack_ms.is_nan() { 0.0 } else { attack_ms.max(0.0) };
        MasterLimiter {
            sample_rate,
            ceiling_db,
            ceiling: f64::from(f),
            ceiling_f: f,
            hold_samples: ((rate * hold_ms / 1000.0).round() as i64).max(0),
            release_coef: (-1.0 / (rate * release_ms / 1000.0).max(1.0)).exp(),
            attack_coef: if atk > 0.0 { (-1.0 / (rate * atk / 1000.0).max(1.0)).exp() } else { 0.0 },
            attack_ms: atk,
            gain: 1.0,
            hold: 0,
        }
    }

    /// Current linear gain (1 = no reduction).
    pub fn gain(&self) -> f64 {
        self.gain
    }

    /// Gain that brings `peak` down to `ceiling`; 1 when it is already at or below.
    pub fn required_gain(peak: f64, ceiling: f64) -> f64 {
        if peak > ceiling { ceiling / peak } else { 1.0 }
    }

    /// Current gain reduction in dB (0 or negative).
    pub fn gain_reduction_db(&self) -> f64 {
        if self.gain >= 1.0 { 0.0 } else { GainMath::db_from_linear(self.gain) }
    }

    /// Forgets the gain and the hold.
    pub fn reset(&mut self) {
        self.gain = 1.0;
        self.hold = 0;
    }

    /// One step of the gain state for a sample whose loudest channel is `peak`.
    #[inline]
    fn advance(&mut self, peak: f64) {
        let need = Self::required_gain(peak, self.ceiling);
        if need < self.gain {
            self.gain = if self.attack_coef == 0.0 { need } else { need + (self.gain - need) * self.attack_coef };
            self.hold = self.hold_samples;
        } else if self.hold > 0 {
            self.hold -= 1;
        } else if self.gain < 1.0 {
            self.gain = need.min(1.0 - (1.0 - self.gain) * self.release_coef);
            if self.gain > 0.999_999_9 {
                self.gain = 1.0;
            }
        }
    }

    /// Float rounding of `x * g` can land one ulp above the ceiling: clamp so `|out| <= ceiling` holds in Float.
    #[inline]
    fn apply(&self, x: f32) -> f32 {
        ((f64::from(x) * self.gain) as f32).max(-self.ceiling_f).min(self.ceiling_f)
    }

    /// In place, both channels with one gain.
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        for (l, r) in left.iter_mut().zip(right.iter_mut()) {
            let peak = f64::from(l.abs().max(r.abs()));
            self.advance(peak);
            if self.gain < 1.0 {
                *l = self.apply(*l);
                *r = self.apply(*r);
            }
        }
    }

    /// In place, interleaved frames of any channel count, all channels linked to one gain (same math as the left/right
    /// version; used by the export's loudness correction on whatever channel count the mix has).
    pub fn process_interleaved(&mut self, s: &mut [f32], channels: usize, count: usize) {
        let ch = channels.max(1);
        for i in 0..count {
            let base = i * ch;
            let mut p = 0.0_f32;
            for c in 0..ch {
                p = p.max(s[base + c].abs());
            }
            self.advance(f64::from(p));
            if self.gain < 1.0 {
                for c in 0..ch {
                    s[base + c] = self.apply(s[base + c]);
                }
            }
        }
    }

    /// The same limiter at another ceiling, keeping its current gain reduction (a changed ceiling causes no jump).
    pub fn with_ceiling(&self, db: f64, release_ms: f64, attack_ms: f64) -> MasterLimiter {
        let mut n = MasterLimiter::with_times(self.sample_rate, db, release_ms, 5.0, attack_ms);
        n.gain = self.gain;
        n.hold = self.hold;
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signal(frames: usize, channels: usize) -> Vec<f32> {
        let mut s = vec![0.0_f32; frames * channels];
        for i in 0..frames {
            let burst: f32 = if i % 4800 < 48 { 1.6 } else { 0.3 };
            for c in 0..channels {
                s[i * channels + c] = burst * ((i as f64 * 0.13 + c as f64).sin() as f32);
            }
        }
        s
    }

    #[test]
    fn stereo_matches_planar_process() {
        let n = 9600;
        let inter = signal(n, 2);
        let mut l: Vec<f32> = (0..n).map(|i| inter[i * 2]).collect();
        let mut r: Vec<f32> = (0..n).map(|i| inter[i * 2 + 1]).collect();
        MasterLimiter::new(48_000, -3.0).process(&mut l, &mut r);
        let mut x = inter;
        MasterLimiter::new(48_000, -3.0).process_interleaved(&mut x, 2, n);
        for i in 0..n {
            assert!(x[i * 2] == l[i] && x[i * 2 + 1] == r[i]);
        }
    }

    #[test]
    fn ceiling_holds_for_any_channel_count() {
        for channels in [1, 3, 6] {
            let n = 9600;
            let mut x = signal(n, channels);
            let mut lim = MasterLimiter::new(48_000, -6.0);
            lim.process_interleaved(&mut x, channels, n);
            let peak = x.iter().map(|v| v.abs()).fold(0.0_f32, f32::max);
            assert!(f64::from(peak) <= lim.ceiling);
        }
    }

    #[test]
    fn below_the_ceiling_the_signal_passes_bit_exact() {
        let mut l = vec![0.1_f32, -0.2, 0.3];
        let mut r = l.clone();
        let want = l.clone();
        MasterLimiter::new(48_000, -1.0).process(&mut l, &mut r);
        assert_eq!(l, want);
    }
}
