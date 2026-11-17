// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ShuttleStretch.swift
//! Pitch-keeping playback rate for shuttle audio (J/L at 2x, 4x, 8x ... and slow rates).
//!
//! The ring holds the timeline at 1x. Played straight, the device pops 48,000 ring frames per second whatever the rate, so
//! the audio clock (frames the output consumed) would run at 1x while the picture asks for 2x. This stage sits between the
//! ring and the device: it pulls `rate` ring frames per output frame, so the ring is consumed (and the clock advances)
//! `rate` times faster and the sound keeps its pitch. Streaming overlap-add: Hann grains of `2 * HOP` input frames, one
//! grain per `HOP` output frames, the grain start advancing `rate * HOP` input frames. No waveform alignment: speech at
//! high rates sounds grainy, which is what shuttle needs. Latency: `HOP` frames.
//!
//! Runs on the audio callback: `render` never allocates or locks.

/// Output frames per grain step; also the latency of the stage in frames.
pub const HOP: usize = 1024;
/// Rates are clamped to `1 / MAX_RATE ..= MAX_RATE`.
pub const MAX_RATE: f64 = 32.0;

/// Fills equally long planar stereo slices with the next frames of the 1x stream.
pub type Source<'a> = dyn FnMut(&mut [f32], &mut [f32]) + 'a;

pub struct ShuttleStretch {
    in_l: Vec<f32>,
    in_r: Vec<f32>,
    acc_l: Vec<f32>,
    acc_r: Vec<f32>,
    window: Vec<f32>,
    /// Input frames buffered in `in_l/in_r`.
    in_count: usize,
    /// Grain start inside them (the fraction is carried).
    pos: f64,
    /// Finished output frames not yet read, and where they start in the accumulator.
    ready: usize,
    read_at: usize,
    /// The next grain continues a 1x stream that was playing straight: it adds the fall of the grain that never was.
    seed: bool,
    /// Leaving the stretch: the fall of the last grain is being played, `fall_at` frames of it so far.
    draining: bool,
    fall_at: usize,
}

impl Default for ShuttleStretch {
    fn default() -> ShuttleStretch {
        ShuttleStretch::new()
    }
}

impl ShuttleStretch {
    pub fn new() -> ShuttleStretch {
        let capacity = 2 * HOP + (MAX_RATE as usize) * HOP + 2;
        // Periodic Hann: two grains `HOP` apart sum to exactly 1.
        let window =
            (0..2 * HOP).map(|k| (0.5 - 0.5 * (std::f64::consts::PI * k as f64 / HOP as f64).cos()) as f32).collect();
        ShuttleStretch {
            in_l: vec![0.0; capacity],
            in_r: vec![0.0; capacity],
            acc_l: vec![0.0; 2 * HOP],
            acc_r: vec![0.0; 2 * HOP],
            window,
            in_count: 0,
            pos: 0.0,
            ready: 0,
            read_at: 0,
            seed: false,
            draining: false,
            fall_at: 0,
        }
    }

    /// New input (rate change, seek) while sound is playing: drops the buffered input but keeps the grain in flight. Its
    /// remaining frames and its fall add to the rise of the next grain (the periodic Hann pair sums to 1), so the output
    /// never drops to zero between the two rates.
    pub fn reset_input(&mut self) {
        self.in_count = 0;
        self.pos = 0.0;
    }

    /// Starts from nothing after the output played straight (no stretch state is valid). The first grain continues the
    /// straight stream: its first `HOP` output frames are the input itself, so the level does not step at the switch.
    pub fn restart(&mut self) {
        self.reset_input();
        self.ready = 0;
        self.read_at = 0;
        self.acc_l.fill(0.0);
        self.acc_r.fill(0.0);
        self.seed = true;
        self.draining = false;
        self.fall_at = 0;
    }

    /// Leaving the stretch for the straight 1x stream (`l`/`r` hold the straight frames of this callback): plays out the
    /// finished frames of the last grain, then its fall plus the rise of the straight stream (the mirror of the seed in
    /// `restart`). Call it every callback until it returns true; the straight frames before the fall are dropped.
    pub fn drain_into(&mut self, l: &mut [f32], r: &mut [f32], count: usize) -> bool {
        if !self.draining {
            self.draining = true;
            // Nothing in flight (paused): no fade, the straight stream starts as it is.
            if self.ready == 0 && self.acc_l.iter().chain(&self.acc_r).all(|v| *v == 0.0) {
                self.restart();
                self.seed = false;
                return true;
            }
        }
        for k in 0..count {
            if self.ready > 0 {
                l[k] = self.acc_l[self.read_at];
                r[k] = self.acc_r[self.read_at];
                self.read_at += 1;
                self.ready -= 1;
                if self.ready == 0 {
                    self.shift_accumulator();
                }
                continue;
            }
            if self.fall_at >= HOP {
                break;
            }
            let w = self.window[self.fall_at];
            l[k] = self.acc_l[self.fall_at] + w * l[k];
            r[k] = self.acc_r[self.fall_at] + w * r[k];
            self.fall_at += 1;
        }
        let done = self.ready == 0 && self.fall_at >= HOP;
        if done {
            self.restart();
            self.seed = false;
        }
        done
    }

    /// Fills `count` output frames at `rate` (input frames per output frame), pulling the input from `source` as needed.
    pub fn render(&mut self, rate: f64, l: &mut [f32], r: &mut [f32], count: usize, source: &mut Source<'_>) {
        let rate = rate.clamp(1.0 / MAX_RATE, MAX_RATE);
        let mut done = 0;
        while done < count {
            if self.ready == 0 {
                self.grain(rate, source);
            }
            let n = self.ready.min(count - done);
            let from = self.read_at;
            l[done..done + n].copy_from_slice(&self.acc_l[from..from + n]);
            r[done..done + n].copy_from_slice(&self.acc_r[from..from + n]);
            self.read_at += n;
            self.ready -= n;
            done += n;
            if self.ready == 0 {
                self.shift_accumulator();
            }
        }
    }

    /// Adds the next grain; afterwards the first `HOP` accumulator frames are final.
    fn grain(&mut self, rate: f64, source: &mut Source<'_>) {
        let start = self.pos as usize;
        let need = start + 2 * HOP;
        if self.in_count < need {
            let from = self.in_count;
            source(&mut self.in_l[from..need], &mut self.in_r[from..need]);
            self.in_count = need;
        }
        if self.seed {
            self.seed = false;
            for k in 0..HOP {
                self.acc_l[k] += self.window[HOP + k] * self.in_l[k];
                self.acc_r[k] += self.window[HOP + k] * self.in_r[k];
            }
        }
        for k in 0..2 * HOP {
            self.acc_l[k] += self.window[k] * self.in_l[start + k];
            self.acc_r[k] += self.window[k] * self.in_r[start + k];
        }
        self.ready = HOP;
        self.read_at = 0;
        self.pos += rate * HOP as f64;
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
        for acc in [&mut self.acc_l, &mut self.acc_r] {
            acc.copy_within(HOP.., 0);
            acc[HOP..].fill(0.0);
        }
    }
}

#[cfg(test)]
mod tests;
