// Swift: RepairStages.swift
//! Audio repair stages of the per-clip chain: De-Hum, Low Cut, High Cut, Dialogue Leveler. Plain DSP, state preallocated,
//! `process` never allocates, zero latency.
//!
//! Buffers are `&mut [&mut [f32]]`, one slice per channel (Swift: an array of channel pointers plus a frame count).

use crate::gain::GainMath;
use sq_core_audio::AudioLevelerValues;

/// One RBJ biquad (direct form II transposed) per channel.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RepairBiquad {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl Default for RepairBiquad {
    fn default() -> Self {
        RepairBiquad { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0 }
    }
}

impl RepairBiquad {
    /// RBJ peaking filter.
    pub fn peak(hz: f64, gain_db: f64, q: f64, fs: f64) -> RepairBiquad {
        let a = 10.0_f64.powf(gain_db / 40.0);
        let w = 2.0 * std::f64::consts::PI * hz.max(5.0).min(fs * 0.45) / fs;
        let alpha = w.sin() / (2.0 * q.max(0.1));
        let cw = w.cos();
        let a0 = 1.0 + alpha / a;
        RepairBiquad {
            b0: (1.0 + alpha * a) / a0,
            b1: -2.0 * cw / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: -2.0 * cw / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }

    /// RBJ low-pass.
    pub fn low_pass(hz: f64, q: f64, fs: f64) -> RepairBiquad {
        let w = 2.0 * std::f64::consts::PI * hz.max(5.0).min(fs * 0.45) / fs;
        let alpha = w.sin() / (2.0 * q);
        let cw = w.cos();
        let a0 = 1.0 + alpha;
        RepairBiquad {
            b0: (1.0 - cw) / 2.0 / a0,
            b1: (1.0 - cw) / a0,
            b2: (1.0 - cw) / 2.0 / a0,
            a1: -2.0 * cw / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    /// RBJ high-pass.
    pub fn high_pass(hz: f64, q: f64, fs: f64) -> RepairBiquad {
        let w = 2.0 * std::f64::consts::PI * hz.max(5.0).min(fs * 0.45) / fs;
        let alpha = w.sin() / (2.0 * q);
        let cw = w.cos();
        let a0 = 1.0 + alpha;
        RepairBiquad {
            b0: (1.0 + cw) / 2.0 / a0,
            b1: -(1.0 + cw) / a0,
            b2: (1.0 + cw) / 2.0 / a0,
            a1: -2.0 * cw / a0,
            a2: (1.0 - alpha) / a0,
        }
    }
}

/// One biquad section over a block (direct form II transposed) with its two memories in `mem[m]`, `mem[m + 1]`.
#[inline]
fn section(f: &RepairBiquad, mem: &mut [f64], m: usize, y: f64) -> f64 {
    let o = f.b0 * y + mem[m];
    mem[m] = f.b1 * y - f.a1 * o + mem[m + 1];
    mem[m + 1] = f.b2 * y - f.a2 * o;
    o
}

/// The settings of the De-Hum stage (the fields of `AudioFXStage::DeHum`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeHumParams {
    /// Root frequency.
    pub frequency_hz: f64,
    /// Notch Q.
    pub q: f64,
    /// Cut of the root in dB.
    pub gain_db: f64,
    /// Number of notches (root plus harmonics), 1...8.
    pub harmonics: i64,
    /// 0.5 = equal depth, 0 = root only, 1 = deeper towards the higher partials.
    pub slope: f64,
    /// Output the removed part only.
    pub listen: bool,
}

/// Notch bank (RBJ peak cuts) at the root and its harmonics. Harmonic k (0 = root) gets `gain x weight(k)`: slope 0.5 = equal,
/// 0 = root only, 1 = deeper towards the higher partials (clamped to -80 dB). Listen = the removed part only.
#[derive(Clone, Debug)]
pub struct DeHumStage {
    fs: f64,
    channels: usize,
    bank: Vec<RepairBiquad>,
    mem: Vec<f64>,
    key: Vec<f64>,
    /// Set by the chain while the stage is off; the next `process` starts from silence.
    pub was_off: bool,
}

impl DeHumStage {
    /// A stage for `channels` channels.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        DeHumStage {
            fs: sample_rate,
            channels,
            bank: vec![],
            mem: vec![0.0; channels * 8 * 2],
            key: vec![],
            was_off: false,
        }
    }

    /// Clears the filter memories.
    pub fn reset(&mut self) {
        self.mem.fill(0.0);
    }

    /// Filters the block in place.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, p: DeHumParams) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let k = vec![p.frequency_hz, p.q, p.gain_db, p.harmonics as f64, p.slope];
        if k != self.key {
            self.key = k;
            self.bank.clear();
            let count = p.harmonics.clamp(1, 8);
            for h in 0..count {
                let hz = p.frequency_hz * (h + 1) as f64;
                if hz >= self.fs * 0.45 {
                    break;
                }
                let t = if count > 1 { h as f64 / (count - 1) as f64 } else { 0.0 };
                let w = (1.0 + (2.0 * p.slope - 1.0) * t).max(0.0);
                self.bank.push(RepairBiquad::peak(hz, (p.gain_db * w).max(-80.0), p.q, self.fs));
            }
        }
        for (c, chan) in buf.iter_mut().enumerate().take(self.channels) {
            for sample in chan[..n].iter_mut() {
                let x = f64::from(*sample);
                let mut y = x;
                for (b, f) in self.bank.iter().enumerate() {
                    y = section(f, &mut self.mem, (c * 8 + b) * 2, y);
                }
                *sample = (if p.listen { x - y } else { y }) as f32;
            }
        }
    }
}

/// Butterworth sections of a 2 x `sections` order filter, run in series (shared by Low Cut and High Cut).
#[derive(Clone, Debug)]
struct CutBank {
    fs: f64,
    channels: usize,
    bank: [RepairBiquad; 4],
    active: usize,
    key_hz: f64,
    key_sections: usize,
    mem: Vec<f64>,
    was_off: bool,
}

impl CutBank {
    fn new(sample_rate: f64, channels: usize) -> Self {
        CutBank {
            fs: sample_rate,
            channels,
            bank: [RepairBiquad::default(); 4],
            active: 0,
            key_hz: -1.0,
            key_sections: 0,
            mem: vec![0.0; channels * 4 * 2],
            was_off: false,
        }
    }

    fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        frequency_hz: f64,
        order: i64,
        design: fn(f64, f64, f64) -> RepairBiquad,
    ) {
        if self.was_off {
            self.mem.fill(0.0);
            self.was_off = false;
        }
        let sections = (if order == 3 {
            4
        } else if order == 2 {
            2
        } else {
            1
        })
        .clamp(1, 4) as usize;
        if frequency_hz != self.key_hz || sections != self.key_sections {
            self.key_hz = frequency_hz;
            self.key_sections = sections;
            self.active = sections;
            for i in 0..sections {
                // Butterworth pole pairs of a 2*sections order filter.
                let q = 1.0 / (2.0 * (std::f64::consts::PI * ((2 * i + 1) as f64) / ((4 * sections) as f64)).cos());
                self.bank[i] = design(frequency_hz, q, self.fs);
            }
        }
        for (c, chan) in buf.iter_mut().enumerate().take(self.channels) {
            for sample in chan[..n].iter_mut() {
                let mut y = f64::from(*sample);
                for b in 0..self.active {
                    y = section(&self.bank[b], &mut self.mem, (c * 4 + b) * 2, y);
                }
                *sample = y as f32;
            }
        }
    }
}

/// Butterworth high-pass, order 1...3 biquads (12, 24, 48 dB/oct).
#[derive(Clone, Debug)]
pub struct LowCutStage(CutBank);

impl LowCutStage {
    /// A stage for `channels` channels.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        LowCutStage(CutBank::new(sample_rate, channels))
    }

    /// Clears the filter memories.
    pub fn reset(&mut self) {
        self.0.mem.fill(0.0);
    }

    /// Set by the chain while the stage is off.
    pub fn set_was_off(&mut self, off: bool) {
        self.0.was_off = off;
    }

    /// Filters the block in place.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, frequency_hz: f64, order: i64) {
        self.0.process(buf, n, frequency_hz, order, RepairBiquad::high_pass);
    }
}

/// Butterworth low-pass, order 1...3 biquads (12, 24, 48 dB/oct): `LowCutStage`'s counterpart.
#[derive(Clone, Debug)]
pub struct HighCutStage(CutBank);

impl HighCutStage {
    /// A stage for `channels` channels.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        HighCutStage(CutBank::new(sample_rate, channels))
    }

    /// Clears the filter memories.
    pub fn reset(&mut self) {
        self.0.mem.fill(0.0);
    }

    /// Set by the chain while the stage is off.
    pub fn set_was_off(&mut self, off: bool) {
        self.0.was_off = off;
    }

    /// Filters the block in place.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, frequency_hz: f64, order: i64) {
        self.0.process(buf, n, frequency_hz, order, RepairBiquad::low_pass);
    }
}

/// Dialogue Leveler: a slow gain ride on the stereo-linked level (RMS, 150 ms). Gain = strength x (target - level), limited
/// to the preset's range, smoothed (400 ms to go up, 120 ms to go down), and held (not lifted) when the level is under the
/// speech floor, so pauses and room noise are not pumped up. Background Reduction pulls the pauses down by up to 6 dB.
#[derive(Clone, Debug)]
pub struct DialogueLevelerStage {
    ms: f64,
    gain_db: f64,
    bg_db: f64,
    ms_coef: f64,
    up_coef: f64,
    down_coef: f64,
    bg_coef: f64,
    /// Set by the chain while the stage is off; the next `process` starts from rest.
    pub was_off: bool,
}

impl DialogueLevelerStage {
    /// A stage at `sample_rate`.
    pub fn new(sample_rate: f64) -> Self {
        DialogueLevelerStage {
            ms: 0.0,
            gain_db: 0.0,
            bg_db: 0.0,
            ms_coef: (-1.0 / (0.150 * sample_rate)).exp(),
            up_coef: (-1.0 / (0.400 * sample_rate)).exp(),
            down_coef: (-1.0 / (0.120 * sample_rate)).exp(),
            bg_coef: (-1.0 / (0.300 * sample_rate)).exp(),
            was_off: false,
        }
    }

    /// Back to rest.
    pub fn reset(&mut self) {
        self.ms = 0.0;
        self.gain_db = 0.0;
        self.bg_db = 0.0;
    }

    /// `depth` 0...1 scales the gain ride (Enhance Speech's Amount); 1 = the effect as set.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, v: &AudioLevelerValues, depth: f64) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let p = v.params();
        let out = GainMath::linear_from_db(v.output_gain_db);
        let (mut ms, mut gain_db, mut bg_db) = (self.ms, self.gain_db, self.bg_db);
        for i in 0..n {
            let mut e = 0.0_f64;
            for chan in buf.iter() {
                let s = f64::from(chan[i]);
                e = e.max(s * s);
            }
            ms = self.ms_coef * ms + (1.0 - self.ms_coef) * e;
            let level_db = 10.0 * ms.max(1e-12).log10();
            if level_db > p.floor_db {
                let mut target = p.strength * (p.target_db - level_db);
                target = target.max(-p.max_down_db).min(p.max_up_db);
                if !v.reduce_loud {
                    target = target.max(0.0);
                }
                if !v.lift_soft {
                    target = target.min(0.0);
                }
                let k = if target > gain_db { self.up_coef } else { self.down_coef };
                gain_db = target + (gain_db - target) * k;
            }
            let bg_target = if v.background && level_db < p.floor_db { -6.0 } else { 0.0 };
            bg_db = bg_target + (bg_db - bg_target) * self.bg_coef;
            let g = (GainMath::linear_from_db((gain_db + bg_db) * depth) * out) as f32;
            for chan in buf.iter_mut() {
                chan[i] *= g;
            }
        }
        self.ms = ms;
        self.gain_db = gain_db;
        self.bg_db = bg_db;
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    /// Runs `f` (channels, frames) over `x` in blocks of `block` frames (the chain's way of feeding a stage) and returns the result.
    pub fn run_blocks(x: &[Vec<f32>], block: usize, mut f: impl FnMut(&mut [&mut [f32]], usize)) -> Vec<Vec<f32>> {
        let n = x[0].len();
        let mut out = x.to_vec();
        let mut pos = 0;
        while pos < n {
            let end = (pos + block).min(n);
            let mut views: Vec<&mut [f32]> = out.iter_mut().map(|c| &mut c[pos..end]).collect();
            f(&mut views, end - pos);
            pos = end;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::run_blocks;
    use super::*;
    use crate::gain::sig;

    /// Gain in dB of the steady part (after 0.5 s) relative to the input.
    fn gain_db(y: &[f32], x: &[f32]) -> f64 {
        sig::db(sig::rms(&y[24000..]) / sig::rms(&x[24000..]))
    }

    fn de_hum(x: &[Vec<f32>], p: DeHumParams) -> Vec<Vec<f32>> {
        let mut stage = DeHumStage::new(48_000.0, x.len());
        run_blocks(x, 480, |b, n| stage.process(b, n, p))
    }

    fn low_cut(x: &[Vec<f32>], hz: f64, order: i64) -> Vec<Vec<f32>> {
        let mut stage = LowCutStage::new(48_000.0, x.len());
        run_blocks(x, 480, |b, n| stage.process(b, n, hz, order))
    }

    fn hum(frequency_hz: f64, gain_db: f64, harmonics: i64, slope: f64, listen: bool) -> DeHumParams {
        DeHumParams { frequency_hz, q: 10.0, gain_db, harmonics, slope, listen }
    }

    #[test]
    fn de_hum_removes_hum_and_harmonics_and_leaves_speech_band() {
        let p = hum(50.0, -30.0, 4, 0.5, false);
        for f in [50.0, 100.0, 150.0, 200.0] {
            let x = sig::sine(f, -20.0, 1.0, 48_000, 2, 0.0);
            let g = gain_db(&de_hum(&x, p)[0], &x[0]);
            assert!(g < -25.0, "hum {f} Hz only {g} dB down");
        }
        for f in [500.0, 1000.0, 4000.0] {
            let x = sig::sine(f, -20.0, 1.0, 48_000, 2, 0.0);
            let g = gain_db(&de_hum(&x, p)[0], &x[0]);
            assert!(g.abs() < 0.7, "{f} Hz: {g} dB");
        }
    }

    #[test]
    fn de_hum_slope_zero_touches_only_the_root() {
        let p = hum(50.0, -30.0, 4, 0.0, false);
        let x200 = sig::sine(200.0, -20.0, 1.0, 48_000, 2, 0.0); // slope 0: the last of 4 harmonics gets no cut
        let g200 = gain_db(&de_hum(&x200, p)[0], &x200[0]);
        assert!(g200.abs() < 1.5, "{g200}");
        let x50 = sig::sine(50.0, -20.0, 1.0, 48_000, 2, 0.0);
        assert!(gain_db(&de_hum(&x50, p)[0], &x50[0]) < -25.0);
    }

    #[test]
    fn de_hum_listen_keeps_only_the_hum() {
        let p = hum(60.0, -40.0, 2, 0.5, true);
        let hum_tone = sig::sine(60.0, -20.0, 1.0, 48_000, 2, 0.0);
        let voice = sig::sine(1000.0, -20.0, 1.0, 48_000, 2, 0.0);
        assert!(gain_db(&de_hum(&hum_tone, p)[0], &hum_tone[0]).abs() < 0.5);
        let gv = gain_db(&de_hum(&voice, p)[0], &voice[0]);
        assert!(gv < -12.0, "{gv}"); // what is left of a 1 kHz tone is the notches' phase shift only
    }

    #[test]
    fn low_cut_slopes() {
        let g = |f: f64, order: i64| {
            let x = sig::sine(f, -20.0, 1.0, 48_000, 2, 0.0);
            gain_db(&low_cut(&x, 100.0, order)[0], &x[0])
        };
        assert!((g(100.0, 2) + 3.0).abs() < 0.7); // Butterworth: -3 dB at the corner
        assert!(g(2000.0, 2).abs() < 0.1);
        let (o1, o2, o3) = (g(25.0, 1), g(25.0, 2), g(25.0, 3));
        assert!(o1 < -10.0 && o2 < o1 - 8.0 && o3 < o2 - 15.0, "{o1} {o2} {o3}"); // 2 octaves down: ~-12, -24, -48 dB
    }

    fn leveler(x: &[Vec<f32>], v: &AudioLevelerValues) -> Vec<Vec<f32>> {
        let mut stage = DialogueLevelerStage::new(48_000.0);
        run_blocks(x, 480, |b, n| stage.process(b, n, v, 1.0))
    }

    #[test]
    fn leveler_evens_loud_and_soft_within_range() {
        let soft = sig::mono(300.0, -36.0, 3.0, 48_000);
        let loud = sig::mono(300.0, -12.0, 3.0, 48_000);
        let both: Vec<f32> = soft.iter().chain(&loud).copied().collect();
        let x = vec![both.clone(), both];
        let v = AudioLevelerValues {
            preset: 3,
            reduce_loud: true,
            lift_soft: true,
            background: false,
            output_gain_db: 0.0,
        };
        let y = &leveler(&x, &v)[0];
        let soft_g = sig::db(sig::rms(&y[120000..144000]) / sig::rms(&x[0][120000..144000])); // end of soft part
        let loud_g = sig::db(sig::rms(&y[264000..288000]) / sig::rms(&x[0][264000..288000])); // end of loud part
        let p = v.params();
        assert!(soft_g > 3.0 && soft_g <= p.max_up_db + 0.3, "soft {soft_g}");
        assert!(loud_g < -3.0 && loud_g >= -p.max_down_db - 0.3, "loud {loud_g}");
        assert!(24.0 + loud_g - soft_g < 24.0 - 6.0); // the 24 dB spread shrinks by more than 6 dB
    }

    #[test]
    fn leveler_does_not_lift_below_speech_floor_and_output_gain_adds() {
        let hiss = sig::mono(300.0, -70.0, 2.0, 48_000);
        let x = vec![hiss.clone(), hiss.clone()];
        let v = AudioLevelerValues {
            preset: 1,
            reduce_loud: true,
            lift_soft: true,
            background: false,
            output_gain_db: 0.0,
        };
        assert!(gain_db(&leveler(&x, &v)[0], &hiss).abs() < 0.1);
        let v6 = AudioLevelerValues { output_gain_db: 6.0, ..v };
        assert!((gain_db(&leveler(&x, &v6)[0], &hiss) - 6.0).abs() < 0.1);
        let bg = AudioLevelerValues { background: true, ..v };
        assert!(gain_db(&leveler(&x, &bg)[0], &hiss) < -4.0);
    }
}
