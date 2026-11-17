// Swift: GraphicEQStage.swift
//! Graphic EQ: ten RBJ peaking biquads at fixed octave centers (constant Q 1.41, the Parametric EQ's `PEQBiquad::peak`), then
//! the output gain. A band at exactly 0 dB is skipped once its memory is empty (it rings out first); all bands and the output
//! at 0 dB leave the buffer untouched (bit exact). Gains move from the block's first sample to the next block's in steps of
//! `RAMP_CHUNK` samples (coefficients from the interpolated gains), so a sweep does not click. Zero latency; no allocation in
//! `process`.

use crate::clip_audio_fxchain::ClipAudioFXChain;
use crate::parametric_eq::{Coef, Mem, PEQBiquad};
use sq_core_audio::AudioGraphicEQValues;

/// The Graphic EQ stage.
pub struct GraphicEQStage {
    channels: usize,
    /// One per band.
    coefs: [Coef; 10],
    /// The dB the coefficients were made for.
    gains: [f64; 10],
    /// `channels * 10`.
    mem: Vec<Mem>,
    /// Set by the chain while the stage is off; the next `process` starts from empty memories.
    pub was_off: bool,
}

impl GraphicEQStage {
    const N: usize = 10;

    /// A stage for `channels` channels.
    pub fn new(channels: usize) -> Self {
        GraphicEQStage {
            channels,
            coefs: [Coef::default(); 10],
            gains: [0.0; 10],
            mem: vec![Mem::default(); channels * Self::N],
            was_off: false,
        }
    }

    /// Clears the filter memories.
    pub fn reset(&mut self) {
        self.mem.fill(Mem::default());
    }

    fn clamp(g: f64) -> f64 {
        if g.is_nan() { 0.0 } else { g.clamp(-12.0, 12.0) }
    }

    /// Gain of band `i` at position `t` (0...1) of the block.
    fn at(a: &AudioGraphicEQValues, b: &AudioGraphicEQValues, i: usize, t: f64) -> f64 {
        Self::clamp(a.get(i) + (b.get(i) - a.get(i)) * t)
    }

    /// Filters the block in place; the gains move from `a` (first sample) to `b` (next block's first sample).
    pub fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        a: &AudioGraphicEQValues,
        b: &AudioGraphicEQValues,
        fs: f64,
    ) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let out_of = |v: &AudioGraphicEQValues| if v.output_db.is_nan() { 0.0 } else { v.output_db.clamp(-24.0, 24.0) };
        let (out_a, out_b) = (out_of(a), out_of(b));
        let mut s = 0;
        while s < n {
            let k = ClipAudioFXChain::RAMP_CHUNK.min(n - s);
            // Static gains need no interpolation; a moving one is evaluated at the end of the chunk (complete when the block ends).
            let t = if a == b { 0.0 } else { (s + k) as f64 / n as f64 };
            for i in 0..Self::N {
                let g = Self::at(a, b, i, t);
                if g != self.gains[i] {
                    self.coefs[i] = PEQBiquad::peak(AudioGraphicEQValues::BAND_HZ[i], g, AudioGraphicEQValues::Q, fs);
                    self.gains[i] = g;
                }
            }
            self.run(buf, s, k);
            s += k;
        }
        let chs = buf.len().min(self.channels);
        ClipAudioFXChain::ramp(&mut buf[..chs], n, out_a, out_b);
    }

    fn run(&mut self, buf: &mut [&mut [f32]], from: usize, n: usize) {
        for (c, chan) in buf.iter_mut().enumerate().take(self.channels) {
            let p = &mut chan[from..from + n];
            for k in 0..Self::N {
                // A band at 0 dB is the identity: skipped once its memory is empty (never cut while it still rings).
                let flat = self.gains[k] == 0.0;
                let mut m = self.mem[c * Self::N + k];
                if flat && m.z1 == 0.0 && m.z2 == 0.0 {
                    continue;
                }
                let q = self.coefs[k];
                for sample in p.iter_mut() {
                    let x = f64::from(*sample);
                    let y = q.b0 * x + m.z1;
                    m.z1 = q.b1 * x - q.a1 * y + m.z2;
                    m.z2 = q.b2 * x - q.a2 * y;
                    *sample = y as f32;
                }
                if flat && m.z1.abs() < 1e-9 && m.z2.abs() < 1e-9 {
                    m = Mem::default();
                }
                self.mem[c * Self::N + k] = m;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use crate::repair_stages::test_support::run_blocks;

    fn geq(gains: &[f64], out: f64) -> AudioGraphicEQValues {
        AudioGraphicEQValues::from_gains(gains, out)
    }

    fn run(v: &AudioGraphicEQValues, x: &[Vec<f32>], block: usize) -> Vec<Vec<f32>> {
        let mut stage = GraphicEQStage::new(x.len());
        run_blocks(x, block, |b, n| stage.process(b, n, v, v, 48_000.0))
    }

    fn tail_gain(y: &[f32], x: &[f32]) -> f64 {
        sig::db(sig::rms(&y[24000..]) / sig::rms(&x[24000..]))
    }

    #[test]
    fn plus_six_db_band_raises_its_center_and_leaves_a_far_band() {
        let mut g = [0.0; 10];
        g[5] = 6.0; // 1 kHz
        let v = geq(&g, 0.0);
        let at = |f: f64| {
            let x = sig::sine(f, -20.0, 1.0, 48_000, 2, 0.0);
            tail_gain(&run(&v, &x, 480)[0], &x[0])
        };
        let (c, lo, hi) = (at(1000.0), at(31.5), at(16000.0));
        assert!((c - 6.0).abs() < 0.3, "{c}");
        assert!(lo.abs() < 0.5 && hi.abs() < 0.5, "{lo} {hi}");
    }

    #[test]
    fn every_band_hits_its_gain_at_its_center() {
        for (i, hz) in AudioGraphicEQValues::BAND_HZ.iter().enumerate() {
            let mut g = [0.0; 10];
            g[i] = -9.0;
            let x = sig::sine(*hz, -20.0, 1.0, 48_000, 2, 0.0);
            let y = tail_gain(&run(&geq(&g, 0.0), &x, 480)[0], &x[0]);
            assert!((y + 9.0).abs() < 0.5, "{hz}: {y}");
        }
    }

    #[test]
    fn flat_is_bit_exact_passthrough() {
        let x = sig::sine(1234.0, -6.0, 0.3, 48_000, 2, 0.0);
        assert_eq!(run(&geq(&[0.0; 10], 0.0), &x, 480), x);
    }

    #[test]
    fn output_gain_scales_a_flat_eq() {
        let x = sig::sine(440.0, -20.0, 1.0, 48_000, 2, 0.0);
        let y = run(&geq(&[0.0; 10], 6.0), &x, 480);
        assert!((tail_gain(&y[0], &x[0]) - 6.0).abs() < 0.05);
    }

    #[test]
    fn result_is_block_size_independent() {
        let mut g = [0.0; 10];
        g[3] = 8.0;
        g[7] = -5.0;
        let x = sig::sine(300.0, -12.0, 0.5, 48_000, 2, 0.0);
        let v = geq(&g, 0.0);
        let (a, b) = (run(&v, &x, 480), run(&v, &x, 128));
        let diff = a[0].iter().zip(&b[0]).fold(0.0_f32, |m, (p, q)| m.max((p - q).abs()));
        assert!(diff < 1e-5, "{diff}");
    }

    /// Runs `x` in blocks of 480; `values(block)` gives the (start, end) gains of each block.
    fn run_ramped(x: &[Vec<f32>], values: impl Fn(usize) -> (AudioGraphicEQValues, AudioGraphicEQValues)) -> Vec<f32> {
        let mut stage = GraphicEQStage::new(x.len());
        let mut i = 0;
        let y = run_blocks(x, 480, |b, n| {
            let (a, e) = values(i);
            stage.process(b, n, &a, &e, 48_000.0);
            i += 1;
        });
        y[0].clone()
    }

    fn bands(g: f64) -> AudioGraphicEQValues {
        let mut v = AudioGraphicEQValues::default();
        v.set(0, g);
        v
    }

    fn max_step(y: &[f32], r: std::ops::Range<usize>) -> f32 {
        (r.start + 1..r.end).fold(0.0_f32, |m, i| m.max((y[i] - y[i - 1]).abs()))
    }

    fn bass() -> Vec<Vec<f32>> {
        sig::sine(40.0, -12.0, 1.0, 48_000, 2, 0.0)
    }

    #[test]
    fn band_dropping_to_zero_between_blocks_does_not_jump() {
        let y = run_ramped(&bass(), |i| {
            let s = bands(if i < 50 { 12.0 } else { 0.0 });
            (s, s)
        });
        let boundary = 50 * 480;
        let steady = max_step(&y, 24000 - 4800..24000);
        let around = max_step(&y, boundary - 4..boundary + 4);
        assert!(around <= steady * 1.5, "{around} vs {steady}");
    }

    #[test]
    fn keyframed_drop_to_zero_inside_a_block_does_not_jump() {
        let y = run_ramped(&bass(), |i| match i {
            0..50 => (bands(12.0), bands(12.0)),
            50 => (bands(12.0), bands(0.0)),
            _ => (bands(0.0), bands(0.0)),
        });
        let steady = max_step(&y, 24000 - 4800..24000);
        let around = max_step(&y, 50 * 480 - 4..52 * 480);
        assert!(around <= steady * 1.5, "{around} vs {steady}");
    }

    #[test]
    fn fully_dropped_band_is_bit_exact_again_after_it_rang() {
        let x = bass();
        let y = run_ramped(&x, |i| {
            let s = bands(if i < 10 { 12.0 } else { 0.0 });
            (s, s)
        });
        let n = x[0].len();
        assert_eq!(y[n - 2000..], x[0][n - 2000..]);
    }
}
