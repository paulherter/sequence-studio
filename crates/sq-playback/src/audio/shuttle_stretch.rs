// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ShuttleStretch.swift
//! Pitch-keeping playback rate for shuttle audio (J/L at 2x, 4x, 8x... and slow rates). Streaming overlap-add: Hann grains
//! of `2 * HOP` input frames, one grain per `HOP` output frames, the grain start advancing `rate * HOP` input frames, so
//! the audio runs `rate` times faster at its own pitch. Same grain math as `AudioRetimer`'s stretch (no waveform
//! alignment). Latency: `HOP` frames. `render` never allocates.

/// Streaming time-stretcher; one render thread owns it.
pub struct ShuttleStretch {
    in_l: Vec<f32>,
    in_r: Vec<f32>,
    acc_l: Vec<f32>,
    acc_r: Vec<f32>,
    window: Vec<f32>,
    /// Input frames buffered, grain start in them (fraction carried), finished output frames not yet read.
    in_count: usize,
    pos: f64,
    ready: usize,
    read_at: usize,
}

impl Default for ShuttleStretch {
    fn default() -> Self {
        Self::new()
    }
}

impl ShuttleStretch {
    pub const HOP: usize = 1024;
    pub const MAX_RATE: f64 = 32.0;
    /// Output frames between the input and what is heard (the first grain's rise).
    pub const LATENCY_FRAMES: usize = Self::HOP;

    pub fn new() -> ShuttleStretch {
        let h = Self::HOP;
        let capacity = 2 * h + (Self::MAX_RATE * h as f64) as usize + 2;
        // Periodic Hann: two grains `hop` apart sum to exactly 1.
        let window =
            (0..2 * h).map(|k| (0.5 - 0.5 * (std::f64::consts::PI * k as f64 / h as f64).cos()) as f32).collect();
        ShuttleStretch {
            in_l: vec![0.0; capacity],
            in_r: vec![0.0; capacity],
            acc_l: vec![0.0; 2 * h],
            acc_r: vec![0.0; 2 * h],
            window,
            in_count: 0,
            pos: 0.0,
            ready: 0,
            read_at: 0,
        }
    }

    /// Drops all buffered audio (seek, rate change).
    pub fn reset(&mut self) {
        self.in_count = 0;
        self.pos = 0.0;
        self.ready = 0;
        self.read_at = 0;
        self.acc_l.fill(0.0);
        self.acc_r.fill(0.0);
    }

    /// `left.len()` output frames at `rate` (input frames per output frame, clamped to 1/32...32), pulling the input from
    /// `source` as needed. `source(l, r)` fills planar stereo frames of the 1x stream.
    pub fn render(
        &mut self,
        rate: f64,
        left: &mut [f32],
        right: &mut [f32],
        source: &mut dyn FnMut(&mut [f32], &mut [f32]),
    ) {
        let r = rate.clamp(1.0 / Self::MAX_RATE, Self::MAX_RATE);
        let count = left.len().min(right.len());
        let mut done = 0;
        while done < count {
            if self.ready == 0 {
                self.grain(r, source);
            }
            let n = self.ready.min(count - done);
            left[done..done + n].copy_from_slice(&self.acc_l[self.read_at..self.read_at + n]);
            right[done..done + n].copy_from_slice(&self.acc_r[self.read_at..self.read_at + n]);
            self.read_at += n;
            self.ready -= n;
            done += n;
            if self.ready == 0 {
                self.shift_accumulator();
            }
        }
    }

    /// Adds the next grain; afterwards the first `HOP` accumulator frames are final.
    fn grain(&mut self, rate: f64, source: &mut dyn FnMut(&mut [f32], &mut [f32])) {
        let h = Self::HOP;
        let start = self.pos as usize;
        let need = start + 2 * h;
        if self.in_count < need {
            let (a, b) = (self.in_count, need);
            source(&mut self.in_l[a..b], &mut self.in_r[a..b]);
            self.in_count = need;
        }
        for k in 0..2 * h {
            self.acc_l[k] += self.window[k] * self.in_l[start + k];
            self.acc_r[k] += self.window[k] * self.in_r[start + k];
        }
        self.ready = h;
        self.read_at = 0;
        self.pos += rate * h as f64;
        // Keep only input the next grain can still read.
        let drop = (self.pos as usize).min(self.in_count);
        if drop > 0 {
            let keep = self.in_count - drop;
            if keep > 0 {
                self.in_l.copy_within(drop..drop + keep, 0);
                self.in_r.copy_within(drop..drop + keep, 0);
            }
            self.in_count = keep;
            self.pos -= drop as f64;
        }
    }

    fn shift_accumulator(&mut self) {
        let h = Self::HOP;
        self.acc_l.copy_within(h..2 * h, 0);
        self.acc_r.copy_within(h..2 * h, 0);
        self.acc_l[h..].fill(0.0);
        self.acc_r[h..].fill(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `frames` output frames at `rate` from a 440 Hz sine (left) and DC 0.5 (right); returns both and the input used.
    fn run(rate: f64, frames: usize) -> (Vec<f32>, Vec<f32>, usize) {
        let mut s = ShuttleStretch::new();
        let (mut l, mut r) = (vec![0.0f32; frames], vec![0.0f32; frames]);
        let mut t = 0usize;
        let mut done = 0;
        while done < frames {
            // Device-sized blocks.
            let n = 480.min(frames - done);
            s.render(rate, &mut l[done..done + n], &mut r[done..done + n], &mut |a, b| {
                for i in 0..a.len() {
                    a[i] = (2.0 * std::f64::consts::PI * 440.0 * (t + i) as f64 / 48_000.0).sin() as f32;
                    b[i] = 0.5;
                }
                t += a.len();
            });
            done += n;
        }
        (l, r, t)
    }

    fn crossings(x: &[f32]) -> usize {
        x.windows(2).filter(|w| (w[1] >= 0.0) != (w[0] >= 0.0)).count()
    }

    #[test]
    fn consumes_rate_times_input_and_keeps_pitch() {
        for rate in [2.0, 4.0, 8.0, 0.5] {
            let frames = 48_000;
            let (l, r, used) = run(rate, frames);
            // Input runs `rate` times faster (give or take one grain step and one grain of look-ahead).
            let expected = rate * frames as f64;
            assert!((used as f64 - expected).abs() <= (rate + 2.0) * ShuttleStretch::HOP as f64 + 2.0, "rate {rate}");
            // 440 Hz stays 440 Hz: about 880 zero crossings per second of output after the first grain.
            let c = crossings(&l[2 * ShuttleStretch::HOP..]);
            let seconds = (frames - 2 * ShuttleStretch::HOP) as f64 / 48_000.0;
            assert!((c as f64 / seconds - 880.0).abs() < 880.0 * 0.08, "rate {rate}");
            // Overlapping grain windows sum to 1: DC passes unchanged after the first grain's rise.
            assert!(r[ShuttleStretch::HOP..].iter().all(|v| (v - 0.5).abs() < 1e-4), "rate {rate}");
        }
    }

    #[test]
    fn reset_drops_buffered_audio() {
        let mut s = ShuttleStretch::new();
        let (mut l, mut r) = (vec![0.0f32; 64], vec![0.0f32; 64]);
        s.render(2.0, &mut l, &mut r, &mut |a, b| {
            a.fill(1.0);
            b.fill(1.0);
        });
        s.reset();
        s.render(2.0, &mut l, &mut r, &mut |a, b| {
            a.fill(0.0);
            b.fill(0.0);
        });
        assert!(l.iter().all(|v| *v == 0.0) && r.iter().all(|v| *v == 0.0));
    }
}
