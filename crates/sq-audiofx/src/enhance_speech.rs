// Swift: EnhanceSpeech.swift
//! Enhance Speech: one stage that runs the existing repair blocks as one recipe (`AudioEnhanceSpeechValues::recipe`):
//! Low Cut (Butterworth, 24 dB/oct) -> Noise Reduction (RNNoise wet/dry, the chain's `Denoise`) -> De-Reverb
//! (`DeReverbStage`) -> dialogue EQ (mud cut, presence, air peaks) -> Dialogue Leveler (`DialogueLevelerStage`, depth = recipe).
//!
//! Real-time safe: every buffer is allocated in `new`, coefficients are rewritten in place, `process` never allocates.
//! Delay: exactly `AudioEnhanceSpeechValues::LATENCY_SAMPLES` (RNNoise frame + De-Reverb window), also while off or at 0 %.
//! Disabled = the delay only (denoiser at 0 % mix, De-Reverb at 0 %, filters and leveler skipped).

use crate::clip_audio_fxchain::Denoise;
use crate::de_reverb::DeReverbStage;
use crate::repair_stages::{DialogueLevelerStage, RepairBiquad};
use sq_core_audio::{AudioEnhanceSpeechValues, AudioLevelerValues, EnhanceRecipe};

/// The Enhance Speech stage.
pub struct EnhanceSpeechStage {
    fs: f64,
    channels: usize,
    denoise: Denoise,
    dereverb: DeReverbStage,
    leveler: DialogueLevelerStage,
    bank: [RepairBiquad; EnhanceSpeechStage::SECTIONS],
    mem: Vec<f64>,
    recipe: Option<EnhanceRecipe>,
    was_off: bool,
}

impl EnhanceSpeechStage {
    /// 2 high-pass biquads + 3 EQ peaks.
    const SECTIONS: usize = 5;

    /// A stage for `channels` channels; `None` when the RNNoise state cannot be created.
    pub fn new(sample_rate: f64, channels: usize) -> Option<Self> {
        Some(EnhanceSpeechStage {
            fs: sample_rate,
            channels,
            denoise: Denoise::new(channels)?,
            dereverb: DeReverbStage::new(sample_rate, channels),
            leveler: DialogueLevelerStage::new(sample_rate),
            bank: [RepairBiquad::default(); Self::SECTIONS],
            mem: vec![0.0; channels * Self::SECTIONS * 2],
            recipe: None,
            was_off: false,
        })
    }

    /// Back to silence.
    pub fn reset(&mut self) {
        self.denoise.reset();
        self.dereverb.reset();
        self.leveler.reset();
        self.mem.fill(0.0);
    }

    /// Coefficients for `r`, written in place (no allocation).
    fn set(&mut self, r: &EnhanceRecipe) {
        if self.recipe.as_ref() == Some(r) {
            return;
        }
        self.recipe = Some(*r);
        // 4th-order Butterworth high-pass as two biquads (pole pair Qs 0.541, 1.307).
        for i in 0..2 {
            let q = 1.0 / (2.0 * (std::f64::consts::PI * (2 * i + 1) as f64 / 8.0).cos());
            self.bank[i] = RepairBiquad::high_pass(r.low_cut_hz, q, self.fs);
        }
        self.bank[2] = RepairBiquad::peak(EnhanceRecipe::MUD_HZ, r.mud_db, EnhanceRecipe::MUD_Q, self.fs);
        self.bank[3] =
            RepairBiquad::peak(EnhanceRecipe::PRESENCE_HZ, r.presence_db, EnhanceRecipe::PRESENCE_Q, self.fs);
        self.bank[4] = RepairBiquad::peak(EnhanceRecipe::AIR_HZ, r.air_db, EnhanceRecipe::AIR_Q, self.fs);
    }

    /// Runs sections `range` of the bank over the block, per channel (direct form II transposed).
    fn filter(&mut self, buf: &mut [&mut [f32]], n: usize, range: std::ops::Range<usize>) {
        for (c, chan) in buf.iter_mut().enumerate().take(self.channels) {
            let p = &mut chan[..n];
            for s in range.clone() {
                let f = self.bank[s];
                let m = (c * Self::SECTIONS + s) * 2;
                let (mut z1, mut z2) = (self.mem[m], self.mem[m + 1]);
                for sample in p.iter_mut() {
                    let x = f64::from(*sample);
                    let y = f.b0 * x + z1;
                    z1 = f.b1 * x - f.a1 * y + z2;
                    z2 = f.b2 * x - f.a2 * y;
                    *sample = y as f32;
                }
                self.mem[m] = z1;
                self.mem[m + 1] = z2;
            }
        }
    }

    /// Only the Low Cut and the dialogue EQ of `r` (no denoiser, De-Reverb or leveler, no delay): the filter curve in tests.
    pub fn filters_only(&mut self, buf: &mut [&mut [f32]], n: usize, r: &EnhanceRecipe) {
        self.set(r);
        self.filter(buf, n, 0..Self::SECTIONS);
    }

    /// `v0` at the first sample, `v1` one block later: the denoiser mix ramps across the block, the rest follows `v0`
    /// (filters and De-Reverb change per block, which is inaudible for automation speeds).
    pub fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        v0: &AudioEnhanceSpeechValues,
        v1: &AudioEnhanceSpeechValues,
        enabled: bool,
    ) {
        if !enabled {
            self.was_off = true;
            self.denoise.process(buf, n, 0.0, 0.0);
            self.dereverb.process(buf, n, 0.0, 0.6, 0.0, false);
            return;
        }
        if self.was_off {
            self.was_off = false;
            self.leveler.reset();
            self.mem.fill(0.0);
        }
        let (r, r1) = (v0.recipe(), v1.recipe());
        self.set(&r);
        self.filter(buf, n, 0..2);
        self.denoise.process(buf, n, r.denoise as f32, r1.denoise as f32);
        self.dereverb.process(buf, n, r.dereverb, r.decay_seconds, 0.0, true);
        self.filter(buf, n, 2..5);
        if r.leveling > 0.0 {
            let v = AudioLevelerValues {
                preset: AudioEnhanceSpeechValues::LEVELER_PRESET,
                reduce_loud: true,
                lift_soft: true,
                background: false,
                output_gain_db: 0.0,
            };
            self.leveler.process(buf, n, &v, r.leveling);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use crate::repair_stages::test_support::run_blocks;

    const LAT: usize = AudioEnhanceSpeechValues::LATENCY_SAMPLES as usize;

    fn values(amount: f64, preset: i64) -> AudioEnhanceSpeechValues {
        AudioEnhanceSpeechValues { amount, preset }
    }

    fn run(v: &AudioEnhanceSpeechValues, x: &[Vec<f32>], enabled: bool, block: usize) -> Vec<Vec<f32>> {
        let mut stage = EnhanceSpeechStage::new(48_000.0, x.len()).expect("RNNoise state");
        run_blocks(x, block, |b, n| stage.process(b, n, v, v, enabled))
    }

    /// Gain in dB of a steady tone after the stage (compensated for the delay, measured after 0.5 s).
    fn tone_gain_db(hz: f64, v: &AudioEnhanceSpeechValues, enabled: bool) -> f64 {
        let x = sig::sine(hz, -20.0, 1.5, 48_000, 1, 0.0);
        let y = &run(v, &x, enabled, 480)[0];
        let n = 48_000;
        sig::db(sig::amplitude(&y[24_000 + LAT..n + LAT], hz, 48_000) / sig::amplitude(&x[0][24_000..n], hz, 48_000))
    }

    /// Speech-like test signal: a 120-180 Hz glottal harmonic series shaped by two formants, in 4 Hz syllables (on 150 ms,
    /// off 100 ms), with slow pitch movement. Returns the signal and a mask of the voiced samples.
    fn voice(seconds: f64) -> (Vec<f32>, Vec<bool>) {
        let fs = 48_000.0;
        let n = (seconds * fs) as usize;
        let (mut x, mut voiced) = (vec![0.0_f32; n], vec![false; n]);
        let mut phase = 0.0;
        for i in 0..n {
            let t = i as f64 / fs;
            let f0 = 150.0 + 30.0 * (2.0 * std::f64::consts::PI * 0.7 * t).sin();
            phase += 2.0 * std::f64::consts::PI * f0 / fs;
            let syl = t % 0.25;
            voiced[i] = syl > 0.02 && syl < 0.13;
            if syl >= 0.15 {
                continue;
            }
            let env = (std::f64::consts::PI * syl / 0.15).sin();
            let mut s = 0.0;
            for h in 1..=30 {
                let hf = f0 * f64::from(h);
                if hf > 8_000.0 {
                    break;
                }
                // Formants near 600 Hz and 1.8 kHz, 1/h glottal roll-off.
                let w = 1.0 / f64::from(h)
                    * (1.0
                        + 3.0 * (-((hf - 600.0) / 200.0).powi(2)).exp()
                        + 2.0 * (-((hf - 1_800.0) / 300.0).powi(2)).exp());
                s += w * (f64::from(h) * phase).sin();
            }
            x[i] = (s * env) as f32;
        }
        let rms = sig::rms(&x) * (n as f64 / voiced.iter().filter(|v| **v).count() as f64).sqrt();
        let g = (10.0_f64.powf(-20.0 / 20.0) / rms.max(1e-9)) as f32;
        (x.iter().map(|v| v * g).collect(), voiced)
    }

    #[test]
    fn latency_is_declared_and_exact() {
        // A 1 kHz tone comes out exactly `LAT` samples later (zero crossing phase check via the single-bin DFT).
        let x = sig::sine(1_000.0, -20.0, 1.0, 48_000, 1, 0.0);
        let y = &run(&values(0.0, 0), &x, true, 480)[0];
        let err = (24_000..40_000).fold(0.0_f32, |m, i| m.max((y[i + LAT] - x[0][i]).abs()));
        assert!(err < 0.01, "max error {err}"); // -20 dBFS tone = 0.1 peak: within 20 dB
    }

    #[test]
    fn amount_zero_and_disabled_are_transparent() {
        for hz in [200.0, 1_000.0, 4_000.0, 10_000.0] {
            let g0 = tone_gain_db(hz, &values(0.0, 0), true);
            assert!(g0.abs() < 0.3, "{hz} Hz at 0 %: {g0} dB");
            let off = tone_gain_db(hz, &values(1.0, 0), false);
            assert!(off.abs() < 0.3, "{hz} Hz disabled: {off} dB");
        }
    }

    #[test]
    fn rumble_is_cut() {
        let rumble = tone_gain_db(30.0, &values(1.0, 0), true);
        assert!(rumble < -15.0, "30 Hz {rumble} dB");
    }

    #[test]
    fn dialogue_eq_curve() {
        // The filters alone (the denoiser and leveler react to steady tones, so the curve is measured without them).
        let gain = |hz: f64, amount: f64| {
            let mut st = EnhanceSpeechStage::new(48_000.0, 1).expect("RNNoise state");
            let mut x = sig::mono(hz, -20.0, 0.5, 48_000);
            let reference = sig::amplitude(&x[12_000..], hz, 48_000);
            let n = x.len();
            st.filters_only(&mut [x.as_mut_slice()], n, &values(amount, 0).recipe());
            sig::db(sig::amplitude(&x[12_000..], hz, 48_000) / reference)
        };
        let full = values(1.0, 0).recipe();
        assert!((gain(3_500.0, 1.0) - full.presence_db).abs() < 0.8, "presence {}", gain(3_500.0, 1.0));
        assert!((gain(300.0, 1.0) - full.mud_db).abs() < 0.8, "mud {}", gain(300.0, 1.0));
        assert!(gain(30.0, 1.0) < -25.0, "rumble {}", gain(30.0, 1.0));
        assert!(gain(1_000.0, 1.0) > -1.5 && gain(1_000.0, 1.0) < 1.5);
        for hz in [100.0, 300.0, 3_500.0, 10_000.0] {
            assert!(gain(hz, 0.0).abs() < 0.2, "{hz} Hz at 0 %");
        }
    }

    #[test]
    fn noise_in_pauses_is_reduced_and_voice_kept() {
        let (v, voiced) = voice(4.0);
        let noise = sig::low_noise(0.02, v.len(), 7);
        let x = vec![v.iter().zip(&noise).map(|(a, b)| a + b).collect::<Vec<f32>>()];
        let levels = |amount: f64| {
            let y = &run(&values(amount, 1), &x, true, 480)[0];
            let (mut p, mut pc, mut s, mut sc) = (0.0, 0, 0.0, 0);
            for i in 48_000..(v.len() - LAT) {
                // skip the first second (denoiser and leveler settle)
                let o = f64::from(y[i + LAT]);
                if voiced[i] {
                    s += o * o;
                    sc += 1;
                } else if !voiced[i.saturating_sub(2_400)] && !voiced[(v.len() - 1).min(i + 2_400)] && v[i] == 0.0 {
                    p += o * o;
                    pc += 1;
                }
            }
            (sig::db((p / f64::from(pc.max(1))).sqrt()), sig::db((s / f64::from(sc.max(1))).sqrt()))
        };
        let (dry, half, full) = (levels(0.0), levels(0.5), levels(1.0));
        // Pauses: the noise goes well down, more with more amount.
        assert!(full.0 < dry.0 - 10.0, "pause {} -> {} dB", dry.0, full.0);
        assert!(half.0 < dry.0 - 3.0 && half.0 > full.0, "half {}", half.0);
        // Voice: the speech level stays (within the leveler's few dB), so the speech-to-noise gap grows.
        assert!((full.1 - dry.1).abs() < 6.0, "voice {} -> {} dB", dry.1, full.1);
        assert!((full.1 - full.0) > (dry.1 - dry.0) + 8.0);
    }

    #[test]
    fn block_size_does_not_change_the_sound() {
        let (v, _) = voice(1.0);
        let x = vec![v.iter().zip(sig::low_noise(0.02, v.len(), 3)).map(|(a, b)| a + b).collect::<Vec<f32>>()];
        let a = run(&values(0.8, 2), &x, true, 480);
        let b = run(&values(0.8, 2), &x, true, 333);
        let err = a[0].iter().zip(&b[0]).fold(0.0_f32, |m, (p, q)| m.max((p - q).abs()));
        assert!(err < 1e-4, "{err}");
    }

    #[test]
    fn silence_stays_silent_and_finite() {
        let x = vec![vec![0.0_f32; 24_000]; 2];
        let y = run(&values(1.0, 0), &x, true, 480);
        for c in y {
            assert!(c.iter().all(|v| v.is_finite() && v.abs() < 1e-4));
        }
    }
}
