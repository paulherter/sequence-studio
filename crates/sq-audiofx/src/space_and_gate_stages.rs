// Swift: SpaceAndGateStages.swift
//! Noise Gate, Delay and Reverb stages of the per-clip chain (`ClipAudioFXChain`). Plain-Float DSP, all state preallocated in
//! `new`; `process` never allocates. Playback and export run the same code (one chain type).

use crate::gate_core::{Detector, GateCore, GateStep, Smoothing};

/// Downward gate, stereo-linked: the level follows the loudest channel (fast rise, 10 ms fall so it does not chatter on
/// waveform dips); the gain glides to 1 (open) or to the range floor (closed) with the attack and release times.
#[derive(Clone, Debug)]
pub struct NoiseGateStage {
    core: GateCore<f32>,
    fs: f64,
    decay: f32,
    /// Set by the chain while the stage is off; the next `process` starts from the open state.
    pub was_off: bool,
}

impl NoiseGateStage {
    /// A gate at `sample_rate`.
    pub fn new(sample_rate: f64) -> Self {
        NoiseGateStage {
            core: GateCore::new(Detector::SmoothedFall, Smoothing::Lerp),
            fs: sample_rate,
            decay: (-1.0 / (0.010 * sample_rate)).exp() as f32,
            was_off: false,
        }
    }

    /// Back to the open start state.
    pub fn reset(&mut self) {
        self.core.reset();
    }

    /// `threshold` and `range` run from the first sample's value to the next block's. `times` = (attack ms, release ms, hold
    /// ms): after the level fell below the threshold the gate stays open for the hold before it starts to close (0 = no hold).
    pub fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        threshold: (f64, f64),
        times: (f64, f64, f64),
        range: (f64, f64),
    ) {
        let (attack_ms, release_ms, hold_ms) = times;
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let (t0, t1) = threshold;
        let (r0, r1) = range;
        let hold_samples =
            ((if hold_ms.is_nan() { 0.0 } else { hold_ms.clamp(0.0, 1_000.0) }) / 1000.0 * self.fs) as i64;
        // A keyframed Hold going down shortens a hold that is already running.
        self.core.hold = self.core.hold.min(hold_samples);
        let atk = (-1.0 / ((attack_ms / 1000.0).max(0.0001) * self.fs)).exp() as f32;
        let rel = (-1.0 / ((release_ms / 1000.0).max(0.0001) * self.fs)).exp() as f32;
        let inv = 1.0 / n as f64;
        for i in 0..n {
            let t = i as f64 * inv;
            let thr = 10.0_f64.powf((t0 + (t1 - t0) * t) / 20.0) as f32;
            let floor_gain = 10.0_f64.powf(-(r0 + (r1 - r0) * t).abs() / 20.0) as f32;
            let mut peak = 0.0_f32;
            for chan in buf.iter() {
                peak = peak.max(chan[i].abs());
            }
            let gain = self.core.step(GateStep {
                peak,
                open_level: thr,
                close_level: thr,
                floor_gain,
                decay: self.decay,
                attack: atk,
                release: rel,
                hold_samples,
            });
            for chan in buf.iter_mut() {
                chan[i] *= gain;
            }
        }
    }
}

/// Feedback delay with a 2 s line per channel. The delay time glides (at most 0.05 sample per sample) so changing it does not
/// click; reads interpolate linearly. Mix crossfades dry and delayed sound; feedback feeds the delayed sound back.
#[derive(Clone, Debug)]
pub struct DelayStage {
    size: usize,
    /// `channels * size`.
    line: Vec<f32>,
    pos: usize,
    /// In samples, -1 = not set yet.
    current: f64,
    channels: usize,
    fs: f64,
    /// Set by the chain while the stage is off; the next `process` starts from an empty line.
    pub was_off: bool,
}

impl DelayStage {
    /// Length of the delay line in seconds.
    pub const MAX_SECONDS: f64 = 2.0;

    /// A delay for `channels` channels.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        let size = (Self::MAX_SECONDS * sample_rate) as usize + 8;
        DelayStage {
            size,
            line: vec![0.0; size * channels],
            pos: 0,
            current: -1.0,
            channels,
            fs: sample_rate,
            was_off: false,
        }
    }

    /// Empties the line.
    pub fn reset(&mut self) {
        self.line.fill(0.0);
        self.pos = 0;
        self.current = -1.0;
    }

    /// `time` (ms), `feedback` and `mix` run from the first sample's value to the next block's.
    pub fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        time: (f64, f64),
        feedback: (f64, f64),
        mix: (f64, f64),
    ) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let (t0, t1) = time;
        let (f0, f1) = feedback;
        let (m0, m1) = mix;
        let max_delay = (self.size - 4) as f64;
        let fs = self.fs;
        let samples = |ms: f64| (ms * 0.001 * fs).max(1.0).min(max_delay);
        if self.current < 0.0 {
            self.current = samples(t0);
        }
        let mut cur = self.current;
        let inv = 1.0 / n as f64;
        let mut p = self.pos;
        // The same delay for every channel (the stereo image stays put).
        for i in 0..n {
            let t = i as f64 * inv;
            let target = samples(t0 + (t1 - t0) * t);
            cur += (target - cur).clamp(-0.05, 0.05);
            let fb = (f0 + (f1 - f0) * t).clamp(0.0, 0.95) as f32;
            let mix = (m0 + (m1 - m0) * t).clamp(0.0, 1.0) as f32;
            let mut rp = p as f64 - cur;
            if rp < 0.0 {
                rp += self.size as f64;
            }
            let i0 = rp as usize;
            let frac = (rp - i0 as f64) as f32;
            let i1 = if i0 + 1 == self.size { 0 } else { i0 + 1 };
            for (c, chan) in buf.iter_mut().enumerate().take(self.channels) {
                let l = &mut self.line[c * self.size..(c + 1) * self.size];
                let delayed = l[i0] * (1.0 - frac) + l[i1] * frac;
                let x = chan[i];
                l[p] = x + delayed * fb;
                chan[i] = x * (1.0 - mix) + delayed * mix;
            }
            p += 1;
            if p == self.size {
                p = 0;
            }
        }
        self.pos = p;
        self.current = cur;
    }
}

#[derive(Clone, Copy, Debug)]
struct Comb {
    offset: usize,
    length: usize,
    pos: usize,
    store: f32,
}

#[derive(Clone, Copy, Debug)]
struct Allpass {
    offset: usize,
    length: usize,
    pos: usize,
}

/// Freeverb (Jezar, public domain): per channel 8 parallel damped feedback combs into 4 series allpasses; odd channel
/// indexes (the right one) use delays 23 samples longer for a stereo image. The input is the mean of all channels.
#[derive(Clone, Debug)]
pub struct ReverbStage {
    /// `channels * 8`, fixed size after `new`.
    combs: Vec<Comb>,
    /// `channels * 4`.
    allpasses: Vec<Allpass>,
    memory: Vec<f32>,
    channels: usize,
    /// Set by the chain while the stage is off; the next `process` starts from an empty room.
    pub was_off: bool,
}

impl ReverbStage {
    const COMB_TUNINGS: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
    const ALLPASS_TUNINGS: [usize; 4] = [556, 441, 341, 225];
    const SPREAD: usize = 23;

    /// A reverb for `channels` channels.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        let scale = sample_rate / 44_100.0;
        let mut off = 0;
        let (mut combs, mut allpasses) = (vec![], vec![]);
        for c in 0..channels {
            let extra = (c % 2) * Self::SPREAD;
            for t in Self::COMB_TUNINGS {
                let length = ((t + extra) as f64 * scale) as usize;
                combs.push(Comb { offset: off, length, pos: 0, store: 0.0 });
                off += length;
            }
            for t in Self::ALLPASS_TUNINGS {
                let length = ((t + extra) as f64 * scale) as usize;
                allpasses.push(Allpass { offset: off, length, pos: 0 });
                off += length;
            }
        }
        ReverbStage { combs, allpasses, memory: vec![0.0; off.max(1)], channels, was_off: false }
    }

    /// Empties the room.
    pub fn reset(&mut self) {
        self.memory.fill(0.0);
        for c in &mut self.combs {
            c.pos = 0;
            c.store = 0.0;
        }
        for a in &mut self.allpasses {
            a.pos = 0;
        }
    }

    /// `mix` runs from the first sample's value to the next block's.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, room: f64, damping: f64, mix: (f64, f64)) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let (m0, m1) = mix;
        let feedback = (0.7 + 0.28 * room.clamp(0.0, 1.0)) as f32;
        let damp = (0.4 * damping.clamp(0.0, 1.0)) as f32;
        let (in_gain, wet_scale) = (0.015_f32, 3.0_f32);
        let used = buf.len().min(self.channels);
        let inv = 1.0 / n as f64;
        let mean_scale = 1.0 / used.max(1) as f32;
        for i in 0..n {
            let mix = (m0 + (m1 - m0) * i as f64 * inv).clamp(0.0, 1.0) as f32;
            let mut sum = 0.0_f32;
            for chan in buf.iter().take(used) {
                sum += chan[i];
            }
            let input = sum * mean_scale * in_gain;
            for (c, chan) in buf.iter_mut().enumerate().take(used) {
                let mut acc = 0.0_f32;
                for k in 0..8 {
                    let comb = &mut self.combs[c * 8 + k];
                    let p = comb.offset + comb.pos;
                    let out = self.memory[p];
                    comb.store = out * (1.0 - damp) + comb.store * damp;
                    self.memory[p] = input + comb.store * feedback;
                    comb.pos += 1;
                    if comb.pos == comb.length {
                        comb.pos = 0;
                    }
                    acc += out;
                }
                for k in 0..4 {
                    let ap = &mut self.allpasses[c * 4 + k];
                    let p = ap.offset + ap.pos;
                    let bufout = self.memory[p];
                    let out = -acc + bufout;
                    self.memory[p] = acc + bufout * 0.5;
                    ap.pos += 1;
                    if ap.pos == ap.length {
                        ap.pos = 0;
                    }
                    acc = out;
                }
                chan[i] = chan[i] * (1.0 - mix) + acc * wet_scale * mix;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use crate::repair_stages::test_support::run_blocks;

    fn rms(x: &[f32], r: std::ops::Range<usize>) -> f64 {
        sig::rms(&x[r])
    }

    fn gate(x: &[Vec<f32>], threshold: f64, attack_ms: f64, release_ms: f64, range: f64) -> Vec<Vec<f32>> {
        let mut stage = NoiseGateStage::new(48_000.0);
        run_blocks(x, 480, |b, n| {
            stage.process(b, n, (threshold, threshold), (attack_ms, release_ms, 0.0), (range, range))
        })
    }

    fn delay(x: &[Vec<f32>], block: usize, time: f64, feedback: f64, mix: f64) -> Vec<Vec<f32>> {
        let mut stage = DelayStage::new(48_000.0, x.len());
        run_blocks(x, block, |b, n| stage.process(b, n, (time, time), (feedback, feedback), (mix, mix)))
    }

    fn reverb(x: &[Vec<f32>], room: f64, mix: f64) -> Vec<Vec<f32>> {
        let mut stage = ReverbStage::new(48_000.0, x.len());
        run_blocks(x, 480, |b, n| stage.process(b, n, room, 0.5, (mix, mix)))
    }

    fn impulse(frames: usize) -> Vec<Vec<f32>> {
        let mut x = vec![vec![0.0_f32; frames]; 2];
        x[0][0] = 1.0;
        x[1][0] = 1.0;
        x
    }

    #[test]
    fn gate_closes_on_quiet_and_opens_on_loud() {
        // 0.5 s quiet (-60 dB) then 0.5 s loud (-10 dB).
        let quiet = sig::sine(440.0, -60.0, 0.5, 48_000, 2, 0.0);
        let loud = sig::sine(440.0, -10.0, 0.5, 48_000, 2, 0.0);
        let x: Vec<Vec<f32>> = (0..2).map(|c| quiet[c].iter().chain(&loud[c]).copied().collect()).collect();
        let y = gate(&x, -40.0, 1.0, 50.0, 60.0);
        assert!(rms(&y[0], 12000..24000) < rms(&x[0], 12000..24000) * 0.01); // at least -40 dB further down
        assert!((rms(&y[0], 30000..46000) / rms(&x[0], 30000..46000) - 1.0).abs() < 0.02); // loud part untouched
    }

    #[test]
    fn gate_range_sets_the_floor() {
        let x = sig::sine(440.0, -50.0, 0.5, 48_000, 2, 0.0);
        let y = gate(&x, -30.0, 1.0, 20.0, 12.0);
        let ratio = rms(&y[0], 12000..24000) / rms(&x[0], 12000..24000);
        assert!((20.0 * ratio.log10() + 12.0).abs() < 0.5);
    }

    #[test]
    fn delay_echoes_after_the_set_time() {
        let y = delay(&impulse(48000), 480, 100.0, 0.5, 0.5);
        assert!((y[0][0] - 0.5).abs() < 1e-4); // dry share
        assert!((y[0][4800] - 0.5).abs() < 1e-4); // first echo at 100 ms: input 1 * mix 0.5
        assert!((y[0][9600] - 0.25).abs() < 1e-4); // second echo, feedback 0.5
        assert!(y[0][2400].abs() < 1e-6);
    }

    #[test]
    fn delay_mix_zero_is_dry() {
        let x = sig::sine(300.0, -12.0, 0.2, 48_000, 2, 0.0);
        let y = delay(&x, 480, 200.0, 0.9, 0.0);
        for i in 0..x[0].len() {
            assert!((y[0][i] - x[0][i]).abs() < 1e-5);
        }
    }

    #[test]
    fn delay_at_maximum_time_and_feedback_stays_bounded() {
        let x = vec![sig::noise(0.5, 96000, 1), sig::noise(0.5, 96000, 2)];
        let y = delay(&x, 480, 2000.0, 0.95, 1.0);
        assert!(y[0].iter().all(|v| v.is_finite() && v.abs() < 20.0));
    }

    #[test]
    fn reverb_has_a_tail_and_decays() {
        let y = reverb(&impulse(96000), 0.7, 1.0);
        let (early, late) = (rms(&y[0], 2400..9600), rms(&y[0], 72000..96000));
        assert!(early > 1e-3);
        assert!(late < early);
        assert!(y[0].iter().all(|v| v.is_finite()));
        assert!(y[0][0].abs() < 0.05); // wet only: the first echoes need the comb delays (>= 25 ms)
    }

    #[test]
    fn reverb_mix_zero_is_dry_and_bigger_room_rings_longer() {
        let x = sig::sine(300.0, -12.0, 0.1, 48_000, 2, 0.0);
        let dry = reverb(&x, 0.5, 0.0);
        for i in 0..x[0].len() {
            assert!((dry[0][i] - x[0][i]).abs() < 1e-5);
        }
        let imp = impulse(96000);
        let small = reverb(&imp, 0.2, 1.0);
        let big = reverb(&imp, 0.9, 1.0);
        assert!(rms(&big[0], 48000..96000) > rms(&small[0], 48000..96000));
    }

    #[test]
    fn stereo_reverb_decorrelates_the_channels() {
        let y = reverb(&impulse(24000), 0.7, 1.0);
        assert_ne!(y[0], y[1]);
    }

    #[test]
    fn delay_is_independent_of_block_size() {
        let x = sig::sine(440.0, -12.0, 0.3, 48_000, 2, 0.0);
        let (a, b) = (delay(&x, 480, 50.0, 0.4, 0.4), delay(&x, 997, 50.0, 0.4, 0.4));
        for i in 0..a[0].len() {
            assert!((a[0][i] - b[0][i]).abs() < 1e-5);
        }
    }

    /// Burst of 0.2 s at -10 dB, then 0.8 s at -80 dB.
    fn burst_then_silence() -> Vec<Vec<f32>> {
        let loud = sig::sine(440.0, -10.0, 0.2, 48_000, 2, 0.0);
        let quiet = sig::sine(440.0, -80.0, 0.8, 48_000, 2, 0.0);
        (0..2).map(|c| loud[c].iter().chain(&quiet[c]).copied().collect()).collect()
    }

    fn gate_hold(x: &[Vec<f32>], release_ms: f64, hold_for_block: impl Fn(usize) -> f64) -> Vec<Vec<f32>> {
        let mut stage = NoiseGateStage::new(48_000.0);
        let mut block = 0;
        run_blocks(x, 480, |b, n| {
            let h = hold_for_block(block);
            stage.process(b, n, (-40.0, -40.0), (1.0, release_ms, h), (60.0, 60.0));
            block += 1;
        })
    }

    /// Level of the 20 ms window starting `ms` after the burst ended (burst = 9600 samples).
    fn level(y: &[f32], ms: f64) -> f64 {
        let s = 9600 + (ms * 48.0) as usize;
        sig::rms(&y[s..s + 960])
    }

    #[test]
    fn hold_keeps_the_gate_open_for_the_hold_time() {
        let x = burst_then_silence();
        let none = gate_hold(&x, 5.0, |_| 0.0);
        let held = gate_hold(&x, 5.0, |_| 200.0);
        // The quiet tail is -80 dB. Open gate = it passes unchanged; closed = pulled down 60 dB.
        let open = level(&x[0], 100.0);
        assert!(level(&none[0], 100.0) < open * 0.01);
        assert!(level(&held[0], 100.0) > open * 0.9);
        assert!(level(&held[0], 400.0) < open * 0.01);
    }

    #[test]
    fn hold_falling_to_zero_shortens_a_running_hold() {
        let x = burst_then_silence();
        let y = gate_hold(&x, 5.0, |i| if i < 20 { 1000.0 } else { 0.0 }); // burst = 20 blocks of 480
        let open = sig::rms(&x[0][9600 + 4800..9600 + 5760]);
        let tail = sig::rms(&y[0][9600 + 4800..9600 + 5760]); // 100 ms after the burst
        assert!(tail < open * 0.01);
    }

    /// Frozen copy of the clip gate as it was before it shared `GateCore` (2026-10-12): the shared core must reproduce it
    /// sample for sample.
    struct LegacyClipGate {
        env: f32,
        gain: f32,
        hold_left: i64,
        fs: f64,
        decay: f32,
    }

    impl LegacyClipGate {
        fn new(sample_rate: f64) -> Self {
            LegacyClipGate {
                env: 0.0,
                gain: 1.0,
                hold_left: 0,
                fs: sample_rate,
                decay: (-1.0 / (0.010 * sample_rate)).exp() as f32,
            }
        }

        /// `times` = (attack ms, release ms, hold ms).
        fn process(
            &mut self,
            x: &mut [Vec<f32>],
            pos: usize,
            m: usize,
            thr: (f64, f64),
            times: (f64, f64, f64),
            range: (f64, f64),
        ) {
            let (attack_ms, release_ms, hold_ms) = times;
            let hold_samples =
                ((if hold_ms.is_nan() { 0.0 } else { hold_ms.clamp(0.0, 1_000.0) }) / 1000.0 * self.fs) as i64;
            let mut hold_left = self.hold_left.min(hold_samples);
            let atk = (-1.0 / ((attack_ms / 1000.0).max(0.0001) * self.fs)).exp() as f32;
            let rel = (-1.0 / ((release_ms / 1000.0).max(0.0001) * self.fs)).exp() as f32;
            let inv = 1.0 / m as f64;
            let (mut env, mut gain) = (self.env, self.gain);
            for i in 0..m {
                let t = i as f64 * inv;
                let thr = 10.0_f64.powf((thr.0 + (thr.1 - thr.0) * t) / 20.0) as f32;
                let floor_gain = 10.0_f64.powf(-(range.0 + (range.1 - range.0) * t).abs() / 20.0) as f32;
                let mut peak = 0.0_f32;
                for c in x.iter() {
                    peak = peak.max(c[pos + i].abs());
                }
                env = if peak > env { peak } else { env * self.decay + peak * (1.0 - self.decay) };
                let mut open = env >= thr;
                if open {
                    hold_left = hold_samples;
                } else if hold_left > 0 {
                    hold_left -= 1;
                    open = true;
                }
                let target: f32 = if open { 1.0 } else { floor_gain };
                let k = if target > gain { atk } else { rel };
                gain = target + (gain - target) * k;
                for c in x.iter_mut() {
                    c[pos + i] *= gain;
                }
            }
            self.env = env;
            self.gain = gain;
            self.hold_left = hold_left;
        }
    }

    /// Deterministic speech-like input: tone bursts with an attack/decay shape, pauses with low noise, two channels.
    fn speech_like(frames: usize) -> Vec<Vec<f32>> {
        let sample_rate = 48_000.0;
        let mut seed: u64 = 0x2545_F491_4F6C_DD1D;
        let mut noise = move || {
            seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            ((seed >> 11) as i64 % 2_000_000) as f64 / 1_000_000.0 - 1.0
        };
        let (mut left, mut right) = (Vec::with_capacity(frames), Vec::with_capacity(frames));
        let burst = (0.18 * sample_rate) as usize;
        let pause = (0.22 * sample_rate) as usize;
        for i in 0..frames {
            let pos = i % (burst + pause);
            let mut v = 0.002 * noise();
            if pos < burst {
                let env = (pos as f64 / 200.0).min(1.0)
                    * (-(pos as f64) / (0.12 * sample_rate)).exp()
                    * (0.2 + 0.5 * ((i / (burst + pause)) % 3) as f64 / 2.0);
                v += env * ((i as f64 * 0.07).sin() + 0.4 * (i as f64 * 0.31).sin()) * 0.6;
            }
            left.push(v as f32);
            right.push((v * 0.8 + 0.001 * noise()) as f32);
        }
        vec![left, right]
    }

    #[test]
    fn clip_gate_matches_legacy() {
        let params = [
            (-30.0, 2.0, 150.0, 40.0, 80.0),
            (-45.0, 0.5, 60.0, 20.0, 0.0),
            (-20.0, 10.0, 400.0, 60.0, 300.0),
            (-35.0, 1.0, 20.0, 12.0, 1000.0),
            (-60.0, 5.0, 100.0, 40.0, 40.0),
        ];
        for p in params {
            let x = speech_like(48_000 * 2);
            let mut legacy = LegacyClipGate::new(48_000.0);
            let mut stage = NoiseGateStage::new(48_000.0);
            let (mut want, mut got) = (x.clone(), x.clone());
            let (block, mut pos, mut k) = (960, 0, 0);
            while pos < x[0].len() {
                let m = block.min(x[0].len() - pos);
                // A moving threshold and range exercise the per-sample ramps; the hold changes between blocks.
                let thr = (p.0 + (k % 3) as f64, p.0 - (k % 2) as f64 * 4.0);
                let hold = p.4 * if k % 5 == 4 { 0.5 } else { 1.0 };
                legacy.process(&mut want, pos, m, thr, (p.1, p.2, hold), (p.3, p.3 + 6.0));
                let mut views: Vec<&mut [f32]> = got.iter_mut().map(|c| &mut c[pos..pos + m]).collect();
                stage.process(&mut views, m, thr, (p.1, p.2, hold), (p.3, p.3 + 6.0));
                pos += m;
                k += 1;
            }
            assert!(got == want);
            assert!(want != x);
        }
    }
}
