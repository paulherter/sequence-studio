// SPDX-License-Identifier: GPL-3.0-or-later
// New in Rust (gate G6, spikes/g6-audio/REPORT.md, risk 1).
//! Delay-locked loop for audio callback time stamps.
//!
//! WASAPI callback times are the QPC read at event time: a fixed +-2 ms pattern with spikes to 12 ms, while the frames
//! consumed stay exact. The loop tracks the callback arrival times with a second-order filter (bandwidth 0.3 Hz by
//! default) and returns a smooth estimate that is never earlier than the previous one. Pure arithmetic, no allocation,
//! no locks: it runs inside the audio callback.

/// Smooths the host time of consecutive audio callbacks.
#[derive(Clone, Debug)]
pub struct StampSmoother {
    sample_rate: f64,
    bandwidth_hz: f64,
    /// Filtered time of the previous callback (ns), `None` before the first one.
    t_filt: Option<f64>,
    /// Device frames consumed by the previous callback.
    prev_frames: usize,
    /// Device clock over host clock (~1.0), tracked by the loop.
    rate_corr: f64,
    last_out: i64,
}

/// A gap longer than this since the predicted time re-seeds the filter (pause, stop, device restart).
const RESEED_NS: f64 = 250_000_000.0;

impl StampSmoother {
    pub fn new(sample_rate: u32, bandwidth_hz: f64) -> StampSmoother {
        StampSmoother {
            sample_rate: f64::from(sample_rate),
            bandwidth_hz,
            t_filt: None,
            prev_frames: 0,
            rate_corr: 1.0,
            last_out: i64::MIN,
        }
    }

    /// Forgets the history (the next call seeds the filter from its raw time).
    pub fn reset(&mut self) {
        self.t_filt = None;
        self.last_out = i64::MIN;
    }

    /// Smoothed time (ns) of a callback that ran at raw time `raw_ns` and handles `frames` device frames.
    pub fn filter(&mut self, raw_ns: i64, frames: usize) -> i64 {
        let raw = raw_ns as f64;
        let out = match self.t_filt {
            None => raw,
            Some(prev) => {
                let period = self.prev_frames as f64 / self.sample_rate * 1e9;
                let predicted = prev + period * self.rate_corr;
                let e = raw - predicted;
                if self.prev_frames == 0 || e.abs() > RESEED_NS {
                    raw
                } else {
                    let w = 2.0 * std::f64::consts::PI * self.bandwidth_hz * period * 1e-9;
                    let (b, c) = (std::f64::consts::SQRT_2 * w, w * w);
                    self.rate_corr = (self.rate_corr + c * e / period).clamp(0.99, 1.01);
                    predicted + b * e
                }
            }
        };
        let out = (out as i64).max(self.last_out);
        self.last_out = out;
        self.t_filt = Some(out as f64);
        self.prev_frames = frames;
        out
    }
}
