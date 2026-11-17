// Swift: GateCore.swift
//! The one gate state machine behind both gates: the clip Noise Gate (`NoiseGateStage`, `f32`, keyframed) and the track
//! gate (`NoiseGate` in `creator_fx`, `f64`, fixed settings). It owns the level detector, the open/hold/close logic and the
//! gain glide; the callers only differ in how they get their per-sample numbers and in the three choices below, which keep
//! each gate sounding exactly as it did before they shared this core.
//!
//! - `Detector`: the track gate keeps a peak with a pure exponential fall; the clip gate falls as a one-pole smoother of the
//!   peak (so it also dips towards the input instead of only decaying).
//! - `Smoothing`: the same glide written two ways; the float rounding differs, so each gate keeps its own order.
//! - Hysteresis: `close_level` below `open_level` (track gate, 3 dB) or equal to it (clip gate, none).
//!
//! Hold: after the level fell below `close_level` the gate stays open for `hold_samples` samples, then closes.

use std::ops::{Add, Mul, Sub};

/// The two float types the gate runs in (Swift `BinaryFloatingPoint`, used with `Float` and `Double`).
pub trait GateFloat: Copy + PartialOrd + Add<Output = Self> + Sub<Output = Self> + Mul<Output = Self> {
    /// 0.
    const ZERO: Self;
    /// 1.
    const ONE: Self;
}

impl GateFloat for f32 {
    const ZERO: f32 = 0.0;
    const ONE: f32 = 1.0;
}

impl GateFloat for f64 {
    const ZERO: f64 = 0.0;
    const ONE: f64 = 1.0;
}

/// How the level detector falls.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Detector {
    /// `env = max(peak, env * decay)`.
    PeakDecay,
    /// One-pole smoother of the peak on the way down.
    SmoothedFall,
}

/// How the gain glides to its target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Smoothing {
    /// `k * gain + (1 - k) * target`.
    Blend,
    /// `target + (gain - target) * k`.
    Lerp,
}

/// The numbers of one gate step (Swift passes them as labeled arguments of `step`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GateStep<F> {
    /// The loudest channel's magnitude.
    pub peak: F,
    /// Level at or above which a closed gate opens.
    pub open_level: F,
    /// Level below which an open gate starts to hold, then closes.
    pub close_level: F,
    /// Linear gain while closed.
    pub floor_gain: F,
    /// Detector fall coefficient.
    pub decay: F,
    /// Gain coefficient while the gain rises.
    pub attack: F,
    /// Gain coefficient while the gain falls.
    pub release: F,
    /// Samples the gate stays open after the level fell below `close_level`.
    pub hold_samples: i64,
}

/// Detector, hold logic and gain glide of a gate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GateCore<F> {
    detector: Detector,
    smoothing: Smoothing,
    /// Detector level.
    pub env: F,
    /// Current gain.
    pub gain: F,
    /// Samples of hold left.
    pub hold: i64,
    /// True while the gate is open.
    pub is_open: bool,
}

impl<F: GateFloat> GateCore<F> {
    /// An open gate at unity gain.
    pub fn new(detector: Detector, smoothing: Smoothing) -> Self {
        GateCore { detector, smoothing, env: F::ZERO, gain: F::ONE, hold: 0, is_open: true }
    }

    /// Back to the open start state.
    pub fn reset(&mut self) {
        self.env = F::ZERO;
        self.gain = F::ONE;
        self.hold = 0;
        self.is_open = true;
    }

    /// Gate off: unity gain, nothing held.
    pub fn bypass(&mut self) {
        self.gain = F::ONE;
        self.is_open = true;
        self.hold = 0;
    }

    /// One sample: returns the gain to multiply every channel with.
    #[inline]
    pub fn step(&mut self, s: GateStep<F>) -> F {
        match self.detector {
            // Swift `max(a, b)` is `b >= a ? b : a`.
            Detector::PeakDecay => {
                let fall = self.env * s.decay;
                self.env = if fall >= s.peak { fall } else { s.peak };
            }
            Detector::SmoothedFall => {
                self.env = if s.peak > self.env { s.peak } else { self.env * s.decay + s.peak * (F::ONE - s.decay) };
            }
        }
        if self.is_open {
            if self.env < s.close_level {
                if self.hold > 0 {
                    self.hold -= 1;
                } else {
                    self.is_open = false;
                }
            } else {
                self.hold = s.hold_samples;
            }
        } else if self.env >= s.open_level {
            self.is_open = true;
            self.hold = s.hold_samples;
        }
        let target = if self.is_open { F::ONE } else { s.floor_gain };
        let k = if target > self.gain { s.attack } else { s.release };
        self.gain = match self.smoothing {
            Smoothing::Blend => k * self.gain + (F::ONE - k) * target,
            Smoothing::Lerp => target + (self.gain - target) * k,
        };
        self.gain
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(peak: f32, hold_samples: i64) -> GateStep<f32> {
        GateStep {
            peak,
            open_level: 0.1,
            close_level: 0.1,
            floor_gain: 0.0,
            decay: 0.5,
            attack: 0.0,
            release: 0.0,
            hold_samples,
        }
    }

    #[test]
    fn closes_after_the_hold_and_reopens_at_the_open_level() {
        let mut g = GateCore::<f32>::new(Detector::SmoothedFall, Smoothing::Lerp);
        assert_eq!(g.step(step(0.5, 2)), 1.0);
        // Quiet input: the level falls below the threshold, the gate holds for two samples, then closes.
        let mut gains = vec![];
        for _ in 0..12 {
            gains.push(g.step(step(0.0, 2)));
        }
        assert_eq!(gains[0], 1.0);
        assert_eq!(gains[11], 0.0);
        assert!(!g.is_open);
        assert_eq!(g.step(step(0.5, 2)), 1.0);
        assert!(g.is_open && g.hold == 2);
    }

    #[test]
    fn reset_and_bypass_restore_unity() {
        let mut g = GateCore::<f64>::new(Detector::PeakDecay, Smoothing::Blend);
        g.is_open = false;
        g.gain = 0.2;
        g.hold = 5;
        g.bypass();
        assert!(g.is_open && g.gain == 1.0 && g.hold == 0);
        g.env = 3.0;
        g.reset();
        assert_eq!(g.env, 0.0);
    }
}
