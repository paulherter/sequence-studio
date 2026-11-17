// Swift: NotchStage.swift
//! Notch: one RBJ peak cut (gain = -depth) per channel, zero latency. Parameters move from the block's first sample to the
//! next block's (`from` to `to`); the coefficients follow in steps of `SUB_BLOCK` samples, computed from the swept parameters
//! (never by interpolating coefficients), so every step is a stable biquad and a sweep does not click. With constant
//! parameters the result does not depend on the block size.

use crate::repair_stages::RepairBiquad;

/// Frequency, Q and depth of the notch at one instant.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NotchParams {
    /// Center frequency.
    pub hz: f64,
    /// Q.
    pub q: f64,
    /// Depth of the cut in dB.
    pub depth_db: f64,
}

/// The Notch stage.
#[derive(Clone, Debug)]
pub struct NotchStage {
    fs: f64,
    channels: usize,
    mem: Vec<f64>,
    coef: RepairBiquad,
    key_hz: f64,
    key_q: f64,
    key_depth: f64,
    /// Set by the chain while the stage is off; the next `process` starts from silence.
    pub was_off: bool,
}

impl NotchStage {
    const SUB_BLOCK: usize = 16;

    /// A stage for `channels` channels.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        NotchStage {
            fs: sample_rate,
            channels,
            mem: vec![0.0; channels * 2],
            coef: RepairBiquad::default(),
            key_hz: -1.0,
            key_q: -1.0,
            key_depth: -1.0,
            was_off: false,
        }
    }

    /// Clears the filter memories.
    pub fn reset(&mut self) {
        self.mem.fill(0.0);
    }

    fn design(&mut self, hz: f64, q: f64, depth_db: f64) -> RepairBiquad {
        if hz != self.key_hz || q != self.key_q || depth_db != self.key_depth {
            self.key_hz = hz;
            self.key_q = q;
            self.key_depth = depth_db;
            // `peak` puts the poles at Q / A (A = 10^(-depth/40)); passing q / A keeps the -3 dB width at f / Q at any depth.
            let a = 10.0_f64.powf(-depth_db / 40.0);
            self.coef = RepairBiquad::peak(hz, -depth_db, q / a, self.fs);
        }
        self.coef
    }

    /// Filters the block in place; the parameters move from `a` (first sample) to `b` (next block's first sample).
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, a: NotchParams, b: NotchParams) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let d0 = a.depth_db.clamp(0.0, 80.0);
        let d1 = b.depth_db.clamp(0.0, 80.0);
        // Neutral depth: bypass, bit exact.
        if d0 < 0.01 && d1 < 0.01 {
            self.reset();
            return;
        }
        let f0 = a.hz.clamp(20.0, 20_000.0);
        let f1 = b.hz.clamp(20.0, 20_000.0);
        let q0 = a.q.clamp(0.1, 100.0);
        let q1 = b.q.clamp(0.1, 100.0);
        let moving = f0 != f1 || q0 != q1 || d0 != d1;
        let ch_count = buf.len().min(self.channels);
        let mut pos = 0;
        while pos < n {
            let len = Self::SUB_BLOCK.min(n - pos);
            let (mut f, mut q, mut d) = (f0, q0, d0);
            if moving {
                // Parameters at the middle of this step; frequency moves on a log scale.
                let t = (pos as f64 + len as f64 / 2.0) / n as f64;
                f = f0 * (f1 / f0).powf(t);
                q = q0 + (q1 - q0) * t;
                d = d0 + (d1 - d0) * t;
            }
            let c = self.design(f, q, d);
            for (ch, chan) in buf.iter_mut().enumerate().take(ch_count) {
                let m = ch * 2;
                let (mut s1, mut s2) = (self.mem[m], self.mem[m + 1]);
                for sample in &mut chan[pos..pos + len] {
                    let x = f64::from(*sample);
                    let o = c.b0 * x + s1;
                    s1 = c.b1 * x - c.a1 * o + s2;
                    s2 = c.b2 * x - c.a2 * o;
                    *sample = o as f32;
                }
                self.mem[m] = s1;
                self.mem[m + 1] = s2;
            }
            pos += len;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use crate::repair_stages::test_support::run_blocks;

    fn notch(hz: f64, q: f64, depth_db: f64) -> NotchParams {
        NotchParams { hz, q, depth_db }
    }

    fn run(p: NotchParams, x: &[Vec<f32>], block: usize) -> Vec<Vec<f32>> {
        let mut stage = NotchStage::new(48_000.0, x.len());
        run_blocks(x, block, |b, n| stage.process(b, n, p, p))
    }

    fn tail_gain(y: &[f32], x: &[f32]) -> f64 {
        sig::db(sig::rms(&y[24000..]) / sig::rms(&x[24000..]))
    }

    #[test]
    fn attenuates_the_center_by_the_depth() {
        for depth in [12.0, 30.0, 60.0] {
            let x = sig::sine(1000.0, -12.0, 1.0, 48_000, 2, 0.0);
            let g = tail_gain(&run(notch(1000.0, 10.0, depth), &x, 480)[0], &x[0]);
            assert!(g <= -(depth - 1.0), "{depth}: {g}");
        }
    }

    #[test]
    fn leaves_two_octaves_away_alone() {
        for f in [250.0, 4000.0] {
            let x = sig::sine(f, -12.0, 1.0, 48_000, 2, 0.0);
            let g = tail_gain(&run(notch(1000.0, 10.0, 40.0), &x, 480)[0], &x[0]);
            assert!(g.abs() < 0.5, "{f}: {g}");
        }
    }

    #[test]
    fn width_stays_f_over_q_at_full_depth() {
        let g = |f: f64| {
            let x = sig::sine(f, -12.0, 1.0, 48_000, 2, 0.0);
            tail_gain(&run(notch(1000.0, 10.0, 60.0), &x, 480)[0], &x[0])
        };
        let (lo, hi, center, far1, far2) = (g(950.0), g(1050.0), g(1000.0), g(250.0), g(4000.0));
        assert!(far1.abs() < 0.5 && far2.abs() < 0.5);
        assert!((lo + 3.0).abs() < 1.5 && (hi + 3.0).abs() < 1.5, "{lo} {hi}");
        assert!(center < -59.0);
    }

    #[test]
    fn silence_stays_silence() {
        let x = vec![vec![0.0_f32; 48000]; 2];
        assert_eq!(run(notch(50.0, 10.0, 30.0), &x, 480), x);
    }

    #[test]
    fn block_size_does_not_matter() {
        let x = sig::sine(997.0, -12.0, 0.5, 48_000, 2, 0.0);
        let p = notch(1000.0, 5.0, 24.0);
        let (a, b) = (run(p, &x, 64), run(p, &x, 1024));
        for c in 0..2 {
            for i in 0..a[c].len() {
                assert!((a[c][i] - b[c][i]).abs() < 1e-5);
            }
        }
    }

    #[test]
    fn zero_depth_is_bypass() {
        let x = sig::sine(1000.0, -12.0, 0.3, 48_000, 2, 0.0);
        assert_eq!(run(notch(1000.0, 10.0, 0.0), &x, 480), x);
    }

    #[test]
    fn swept_parameters_stay_finite_and_bounded() {
        let x = vec![sig::noise(0.5, 48000, 1), sig::noise(0.5, 48000, 2)];
        let mut stage = NotchStage::new(48_000.0, 2);
        let mut peak = 0.0_f32;
        let mut k = 0;
        let y = run_blocks(&x, 480, |b, n| {
            let f0 = 30.0 * 600.0_f64.powf((k % 20) as f64 / 20.0);
            let f1 = 30.0 * 600.0_f64.powf(((k + 1) % 20) as f64 / 20.0);
            stage.process(b, n, notch(f0, 40.0, 60.0), notch(f1, 40.0, 60.0));
            k += 1;
        });
        for v in y.iter().flatten() {
            assert!(v.is_finite());
            peak = peak.max(v.abs());
        }
        assert!(peak < 2.0);
    }
}
