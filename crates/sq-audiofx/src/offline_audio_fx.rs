//! Port of `SQAudioFX/Sources/SQAudioFX/OfflineAudioFX.swift`.

use crate::creator_fx::{NoiseGate, Saturator};
use crate::denoise_stage::DenoiseStage;
use crate::gain::{AudioFXError, VolumeAutomation};
use crate::multiband::MultibandCompressor;
use crate::presets::TrackAudioPreset;
#[cfg(test)]
use crate::rnnoise_denoiser::RNNoiseDenoiser;
use crate::role_chain::DeEsser;
use sq_core_time::Time;

/// Offline gain -> denoise -> noise gate -> multiband compressor -> de-esser -> saturation chain on plain `Vec<Vec<f32>>` buffers.
///
/// Gain (incl. pan and keyframed volume) is first: clip volume is a clip property and the compressor/denoiser
/// are track effects, so the track FX see the gained signal (Premiere order: clip -> track FX). Same order as
/// `RealtimeAudioFX` and the playback/export mixer (`AudioFeeder`).
/// The denoiser runs at 48 kHz; other rates go through the portable resampler of `DenoiseStage` (Swift: `AVAudioConverter`).
///
/// Streaming use: `process` (keeps state; output is delayed by `latency_samples`, call `flush_tail`
/// at the end). The volume automation is evaluated on the input at its own time, before the delay.
/// One-shot use: `render` (whole clip, latency compensated, same length out as in).
pub struct OfflineAudioFX {
    pub volume: VolumeAutomation,
    pub preset: TrackAudioPreset,
    pub sample_rate: i64,
    pub channel_count: usize,
    denoise: Option<DenoiseStage>,
    gate: NoiseGate,
    compressor: MultibandCompressor,
    de_esser: Option<DeEsser>,
    saturator: Saturator,
}

/// What `OfflineAudioFX::render` returns.
#[derive(Clone, Debug, PartialEq)]
pub struct OfflineRenderResult {
    pub channels: Vec<Vec<f32>>,
    /// True if the denoiser ran (noise reduction > 0 in the preset).
    pub denoise_applied: bool,
}

impl OfflineAudioFX {
    pub fn new(
        volume: VolumeAutomation,
        preset: TrackAudioPreset,
        sample_rate: i64,
        channel_count: usize,
    ) -> Result<Self, AudioFXError> {
        if channel_count == 0 {
            return Err(AudioFXError::InvalidChannelCount(0));
        }
        if sample_rate <= 0 {
            return Err(AudioFXError::UnsupportedSampleRate(sample_rate));
        }
        let denoise = if preset.noise_reduction > 0.0 {
            let mut d = DenoiseStage::new(sample_rate, channel_count)?;
            d.set_mix(preset.noise_reduction.min(1.0) as f32);
            Some(d)
        } else {
            None
        };
        let fs = sample_rate as f64;
        Ok(OfflineAudioFX {
            gate: NoiseGate::new(&preset.gate, fs),
            compressor: MultibandCompressor::new(&preset.compressor, fs, channel_count),
            de_esser: preset.de_ess.then(|| DeEsser::new(sample_rate, channel_count)),
            saturator: Saturator::new(&preset.saturation),
            volume,
            preset,
            sample_rate,
            channel_count,
            denoise,
        })
    }

    /// Denoiser wet/dry mix, 0 (input, time-aligned) ... 1 (fully denoised). Starts at `preset.noise_reduction`.
    /// No effect if the preset had the denoiser off at init.
    pub fn denoise_mix(&self) -> f64 {
        self.denoise.as_ref().map_or(0.0, |d| f64::from(d.mix()))
    }

    /// Sets the denoiser mix (clamped to 0...1).
    pub fn set_denoise_mix(&mut self, mix: f64) {
        if let Some(d) = &mut self.denoise {
            d.set_mix(mix.clamp(0.0, 1.0) as f32);
        }
    }

    /// Delay added by the denoiser path, in samples at `sample_rate`.
    pub fn latency_samples(&self) -> usize {
        self.denoise.as_ref().map_or(0, DenoiseStage::latency_samples)
    }

    /// Streaming step. `start` = timeline time of the first sample of `input`.
    pub fn process(&mut self, input: &[Vec<f32>], start: Time) -> Vec<Vec<f32>> {
        let mut g = input.to_vec();
        self.volume.apply_to(&mut g, start, self.sample_rate);
        let denoised = match &mut self.denoise {
            Some(d) => d.process(&g),
            None => g,
        };
        self.compress(denoised)
    }

    /// Streaming end: the `latency_samples` still held back. `start` = timeline time just after the last input sample
    /// (unused since the gain runs before the delay; kept for call-site symmetry).
    pub fn flush_tail(&mut self, _start: Time) -> Vec<Vec<f32>> {
        let Some(d) = &mut self.denoise else { return vec![Vec::new(); self.channel_count] };
        let flushed = d.flush();
        self.compress(flushed)
    }

    fn compress(&mut self, denoised: Vec<Vec<f32>>) -> Vec<Vec<f32>> {
        let mut b = denoised;
        self.gate.process(&mut b);
        self.compressor.process_planar(&mut b);
        if let Some(d) = &mut self.de_esser {
            d.process_planar(&mut b);
        }
        self.saturator.process(&mut b);
        b
    }

    /// Whole-buffer render, latency removed.
    pub fn render(&mut self, input: &[Vec<f32>], start: Time) -> OfflineRenderResult {
        let n = input.first().map_or(0, Vec::len);
        let mut out = self.process(input, start);
        let denoise_applied = self.denoise.is_some();
        if denoise_applied {
            let tail = self.flush_tail(start + Time::new(n as i64, self.sample_rate));
            let lat = self.latency_samples();
            for (o, t) in out.iter_mut().zip(&tail) {
                o.extend_from_slice(t);
                o.drain(..lat.min(o.len()));
                o.truncate(n);
            }
        }
        OfflineRenderResult { channels: out, denoise_applied }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use sq_core_time::{Id, Keyframe, KeyframeTrack};

    fn fx(volume: VolumeAutomation, preset: TrackAudioPreset, rate: i64, channels: usize) -> OfflineAudioFX {
        match OfflineAudioFX::new(volume, preset, rate, channels) {
            Ok(f) => f,
            Err(e) => panic!("offline fx: {e}"),
        }
    }

    fn flat() -> VolumeAutomation {
        VolumeAutomation::new(0.0, None, None)
    }

    fn off_with_nr() -> TrackAudioPreset {
        let mut p = TrackAudioPreset::off();
        p.noise_reduction = 1.0;
        p
    }

    fn compressing_preset() -> TrackAudioPreset {
        let mut preset = TrackAudioPreset::off();
        preset.compressor = crate::presets::MultibandCompressorSettings::neutral();
        preset.compressor.bypass = false;
        for b in &mut preset.compressor.bands {
            b.threshold_db = -30.0;
            b.ratio = 4.0;
            b.attack_ms = 1.0;
            b.release_ms = 50.0;
        }
        preset
    }

    fn track(keys: &[(Time, f64)]) -> KeyframeTrack<f64> {
        let mut t = KeyframeTrack::<f64>::new();
        for (i, (time, v)) in keys.iter().enumerate() {
            t.insert(Keyframe::new(Id::from_u128(i as u128 + 1), *time, *v));
        }
        t
    }

    #[test]
    fn off_preset_only_applies_gain() {
        let mut p = fx(VolumeAutomation::new(-6.0206, None, None), TrackAudioPreset::off(), 48000, 2);
        let x = sig::sine(1000.0, -10.0, 0.5, 48000, 2, 0.0);
        let r = p.render(&x, Time::ZERO);
        assert_eq!(r.channels[0].len(), x[0].len());
        assert!(!r.denoise_applied);
        for i in (0..x[0].len()).step_by(97) {
            assert!((r.channels[0][i] - x[0][i] * 0.5).abs() < 1e-4);
        }
    }

    #[test]
    fn voice_preset_denoises_and_keeps_length() {
        let mut preset = TrackAudioPreset::voice();
        preset.noise_reduction = 1.0;
        preset.compressor.bypass = true;
        let mut p = fx(flat(), preset, 48000, 1);
        let n = 48000 * 2;
        let noise = sig::low_noise(0.05, n, 1);
        let r = p.render(std::slice::from_ref(&noise), Time::ZERO);
        assert!(r.denoise_applied);
        assert_eq!(r.channels[0].len(), n);
        assert!(sig::rms(&r.channels[0][48000..n]) < sig::rms(&noise[48000..n]) * 0.5);
    }

    #[test]
    fn denoise_mix_zero_is_input_exactly_and_one_is_wet() {
        let x = vec![sig::low_noise(0.1, 20000, 1)];
        let mut dry = fx(flat(), off_with_nr(), 48000, 1);
        dry.set_denoise_mix(0.0);
        assert_eq!(dry.render(&x, Time::ZERO).channels, x);

        let mut wet = fx(flat(), off_with_nr(), 48000, 1);
        wet.set_denoise_mix(1.0);
        let w = wet.render(&x, Time::ZERO).channels;
        let Ok(mut reference) = RNNoiseDenoiser::new(1, 48000) else { panic!("denoiser") };
        let mut full = reference.process(&x).swap_remove(0);
        full.extend(reference.flush().swap_remove(0));
        let expected: Vec<f32> = full.into_iter().skip(RNNoiseDenoiser::LATENCY_SAMPLES).take(20000).collect();
        assert_eq!(w[0], expected);

        let mut half = fx(flat(), off_with_nr(), 48000, 1);
        half.set_denoise_mix(0.5);
        let h = half.render(&x, Time::ZERO).channels.swap_remove(0);
        for i in (0..20000).step_by(131) {
            assert!((h[i] - (x[0][i] + w[0][i]) / 2.0).abs() < 1e-6);
        }
    }

    #[test]
    fn render_compensates_latency() {
        let mut p = fx(flat(), off_with_nr(), 48000, 1);
        p.set_denoise_mix(0.0);
        let x = vec![sig::noise(0.3, 5000, 1)];
        let r = p.render(&x, Time::ZERO);
        for (y, v) in r.channels[0].iter().zip(&x[0]) {
            assert!((y - v).abs() < 1e-6);
        }
    }

    #[test]
    fn compressor_reduces_loud_peaks_above_threshold() {
        let mut p = fx(flat(), compressing_preset(), 48000, 1);
        let x = sig::sine(440.0, -6.0, 1.0, 48000, 1, 0.0);
        let r = p.render(&x, Time::ZERO);
        assert!(sig::rms(&r.channels[0][24000..]) < sig::rms(&x[0][24000..]) * 0.6);
    }

    #[test]
    fn gain_comes_before_compressor() {
        // Clip volume is a clip property, the compressor a track effect (Premiere order: clip -> track FX):
        // the compressor sees the gained signal, so +20 dB in comes out as roughly +20/ratio dB above threshold.
        let x = sig::sine(440.0, -10.0, 1.0, 48000, 1, 0.0);
        let mut a = fx(flat(), compressing_preset(), 48000, 1);
        let mut b = fx(VolumeAutomation::new(20.0, None, None), compressing_preset(), 48000, 1);
        let ya = a.render(&x, Time::ZERO).channels.swap_remove(0);
        let yb = b.render(&x, Time::ZERO).channels.swap_remove(0);
        let d =
            sig::db(sig::amplitude(&yb[24000..], 440.0, 48000)) - sig::db(sig::amplitude(&ya[24000..], 440.0, 48000));
        assert!(d > 2.0 && d < 10.0, "compressed gain difference {d} dB");
    }

    #[test]
    fn volume_automation_uses_start_time() {
        let t = track(&[(Time::ZERO, 0.0), (Time::new(2, 1), -20.0)]);
        let mut p = fx(VolumeAutomation::new(0.0, Some(t), None), TrackAudioPreset::off(), 48000, 1);
        let r = p.render(&[vec![1.0; 100]], Time::new(1, 1));
        assert!((20.0 * f64::from(r.channels[0][0]).log10() + 10.0).abs() < 0.05);
    }

    #[test]
    fn volume_automation_aligned_with_denoise_latency() {
        // Gain first, at input time: a keyframed ramp must land on the compensated (input-aligned) samples.
        let t = track(&[(Time::ZERO, 0.0), (Time::new(1, 1), -20.0)]);
        let mut p = fx(VolumeAutomation::new(0.0, Some(t), None), off_with_nr(), 48000, 1);
        p.set_denoise_mix(0.0);
        let r = p.render(&[vec![0.5; 48000]], Time::ZERO);
        assert!((f64::from(r.channels[0][24000]) - 0.5 * 10.0_f64.powf(-10.0 / 20.0)).abs() < 1e-4);
        assert!((f64::from(r.channels[0][0]) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn streaming_matches_render_48k() {
        let x = vec![sig::low_noise(0.1, 30000, 1)];
        let mut one = fx(VolumeAutomation::new(-3.0, None, None), TrackAudioPreset::voice(), 48000, 1);
        let reference = one.render(&x, Time::ZERO).channels;
        let mut s = fx(VolumeAutomation::new(-3.0, None, None), TrackAudioPreset::voice(), 48000, 1);
        let mut pos = Time::ZERO;
        let mut parts = Vec::new();
        for c in sig::chunked(&x, &[1000, 333, 4096]) {
            parts.push(s.process(&c, pos));
            pos += Time::new(c[0].len() as i64, 48000);
        }
        parts.push(s.flush_tail(pos));
        let all = sig::concat(&parts, 1).swap_remove(0);
        let out: Vec<f32> = all.into_iter().skip(s.latency_samples()).take(30000).collect();
        assert_eq!(out.len(), 30000);
        for i in 0..30000 {
            assert!((out[i] - reference[0][i]).abs() < 1e-5);
        }
    }

    #[test]
    fn offline_chain_applies_gate() {
        let mut preset = TrackAudioPreset::new("x", "x", crate::presets::MultibandCompressorSettings::neutral());
        preset.noise_reduction = 0.0;
        preset.gate = crate::creator_fx::NoiseGateSettings {
            enabled: true,
            threshold_db: -30.0,
            reduction_db: 60.0,
            attack_ms: 1.0,
            hold_ms: 0.0,
            release_ms: 10.0,
        };
        let quiet = vec![sig::noise(0.002, 24000, 1)];
        let mut p = fx(flat(), preset, 48000, 1);
        let out = p.render(&quiet, Time::ZERO).channels;
        assert!(sig::rms(&out[0][12000..]) < sig::rms(&quiet[0][12000..]) * 0.01);
    }

    #[test]
    fn runs_the_denoiser_at_another_rate() {
        let fx = OfflineAudioFX::new(flat(), off_with_nr(), 44100, 1).expect("44.1 kHz works");
        assert!(fx.latency_samples() > 0);
        assert!(matches!(
            OfflineAudioFX::new(flat(), off_with_nr(), 0, 1),
            Err(AudioFXError::UnsupportedSampleRate(0))
        ));
    }
}
