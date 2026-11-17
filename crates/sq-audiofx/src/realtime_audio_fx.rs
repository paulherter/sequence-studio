//! Port of `SQAudioFX/Sources/SQAudioFX/RealtimeAudioFX.swift`.

use crate::clip_audio_fxchain::Denoise;
use crate::creator_fx::{NoiseGate, NoiseGateConfig, Saturator, SaturatorConfig};
use crate::gain::{AudioFXError, VolumeAutomation};
use crate::multiband::{MultibandCompressor, MultibandConfig};
use crate::multiband_meters::MultibandMeterTap;
use crate::presets::TrackAudioPreset;
use crate::rnnoise_denoiser::{self, RNNoiseDenoiser};
use crate::role_chain::DeEsser;
use sq_core_time::Id;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Realtime gain/pan/volume -> denoise -> noise gate -> 4-band compressor -> de-esser -> saturation chain for the
/// playback audio engine (clip volume before the track FX, like `OfflineAudioFX` and Premiere).
///
/// Same DSP as `OfflineAudioFX` (same code for the compressor and the gain, the denoiser is the same RNNoise
/// frame logic), on deinterleaved Float channel slices, in place, fixed 48 kHz. Non-48 kHz material is
/// resampled upstream by the feeder, not here.
///
/// Threading contract (Rust mapping of the Swift class, see PORTING-NOTES): the render thread owns the
/// `RealtimeAudioFX` and calls `process`; any other thread holds the `RealtimeControls` handle (`controls()`).
/// - `process` never allocates, never blocks (the mailbox is only ever `try_lock`ed) and never frees memory.
/// - `set_preset`, `set_denoise_mix`, `set_volume`, `set_bypass` build the new parameter set on the caller's thread
///   and hand it over through the mailbox; the new set is applied at the start of the next `process` call. If a setter
///   holds the lock at that instant, the update lands one block later.
/// - `reset()` may be called from any thread; it is applied at the start of the next `process` call.
///
/// Latency: 480 samples while a denoiser exists (`denoiser: true`), else 0. The latency stays constant even
/// at denoise mix 0 or bypass (the dry path is delayed too), so moving the mix never makes the audio jump.
/// The timeline sample handed to `process` is the position of the first INPUT sample; volume is applied to the
/// input at that time, before the delay (like `OfflineAudioFX`).
pub struct RealtimeAudioFX {
    pub channel_count: usize,
    pub max_frames: usize,
    /// 480 while a denoiser exists, else 0. Constant for the lifetime of the object.
    pub latency_samples: usize,
    controls: Arc<RealtimeControls>,

    // Render-thread state
    params: Params,
    gate: NoiseGate,
    compressor: MultibandCompressor,
    de_esser: DeEsser,
    saturator: Saturator,
    denoise: Option<Denoise>,
    /// The track this chain serves, split for the track meter tap (`None` = never published).
    meter_track: Option<(u64, u64)>,
}

/// Everything the render thread needs; plain value, built off the render thread.
#[derive(Clone)]
struct Params {
    gate: NoiseGateConfig,
    compressor: MultibandConfig,
    saturation: SaturatorConfig,
    mix: f32,
    bypass: bool,
    de_ess: bool,
    volume: VolumeAutomation,
}

struct Mailbox {
    /// Setter side, authoritative.
    desired: Params,
    /// Swapped with the render thread's copy.
    outbox: Params,
    dirty: bool,
}

/// The thread-safe side of a `RealtimeAudioFX`: parameter setters and the reset request.
pub struct RealtimeControls {
    mailbox: Mutex<Mailbox>,
    reset_requested: AtomicBool,
}

impl RealtimeControls {
    const SAMPLE_RATE: f64 = RealtimeAudioFX::SAMPLE_RATE as f64;

    fn update(&self, body: impl FnOnce(&mut Params)) {
        if let Ok(mut m) = self.mailbox.lock() {
            body(&mut m.desired);
            m.outbox = m.desired.clone();
            m.dirty = true;
        }
    }

    /// New compressor settings and denoise mix (= `preset.noise_reduction`). Detector state is kept.
    pub fn set_preset(&self, preset: &TrackAudioPreset) {
        let cfg = MultibandConfig::from_settings(&preset.compressor, Self::SAMPLE_RATE);
        let mix = preset.noise_reduction.clamp(0.0, 1.0) as f32;
        let g = NoiseGateConfig::new(&preset.gate, Self::SAMPLE_RATE);
        let s = SaturatorConfig::new(&preset.saturation);
        let de = preset.de_ess;
        self.update(|p| {
            p.compressor = cfg;
            p.mix = mix;
            p.de_ess = de;
            p.gate = g;
            p.saturation = s;
        });
    }

    /// Denoiser wet/dry mix 0...1 (no effect without a denoiser). Latency does not change.
    pub fn set_denoise_mix(&self, mix: f64) {
        let m = mix.clamp(0.0, 1.0) as f32;
        self.update(|p| p.mix = m);
    }

    pub fn set_volume(&self, volume: VolumeAutomation) {
        self.update(|p| p.volume = volume);
    }

    /// Bypass = compressor off and denoiser dry (still delayed by `latency_samples`). Volume/pan stay active:
    /// they are clip properties, not effects.
    pub fn set_bypass(&self, bypass: bool) {
        self.update(|p| p.bypass = bypass);
    }

    /// Clears all DSP state (filters, detectors, denoiser history). Use on seeks; applied at the next `process`.
    pub fn reset(&self) {
        self.reset_requested.store(true, Ordering::Release);
    }
}

impl RealtimeAudioFX {
    pub const SAMPLE_RATE: i64 = 48000;

    /// - `preset`: compressor settings and initial denoise mix (`noise_reduction`).
    /// - `denoiser`: allocate the RNNoise path (default true in Swift). Without it latency is 0 and the mix is ignored.
    pub fn new(
        preset: &TrackAudioPreset,
        volume: VolumeAutomation,
        channel_count: usize,
        max_frames: usize,
        denoiser: bool,
    ) -> Result<Self, AudioFXError> {
        if channel_count == 0 {
            return Err(AudioFXError::InvalidChannelCount(0));
        }
        let fs = Self::SAMPLE_RATE as f64;
        let denoise = if denoiser {
            rnnoise_denoiser::global_init();
            Some(Denoise::new(channel_count).ok_or(AudioFXError::DenoiserUnavailable)?)
        } else {
            None
        };
        let p = Params {
            gate: NoiseGateConfig::new(&preset.gate, fs),
            compressor: MultibandConfig::from_settings(&preset.compressor, fs),
            saturation: SaturatorConfig::new(&preset.saturation),
            mix: preset.noise_reduction.clamp(0.0, 1.0) as f32,
            bypass: false,
            de_ess: preset.de_ess,
            volume,
        };
        let controls = Arc::new(RealtimeControls {
            mailbox: Mutex::new(Mailbox { desired: p.clone(), outbox: p.clone(), dirty: false }),
            reset_requested: AtomicBool::new(false),
        });
        Ok(RealtimeAudioFX {
            channel_count,
            max_frames: max_frames.max(1),
            latency_samples: if denoiser { RNNoiseDenoiser::LATENCY_SAMPLES } else { 0 },
            controls,
            params: p,
            gate: NoiseGate::new(&preset.gate, fs),
            compressor: MultibandCompressor::new(&preset.compressor, fs, channel_count),
            de_esser: DeEsser::new(Self::SAMPLE_RATE, channel_count),
            saturator: Saturator::new(&preset.saturation),
            denoise,
            meter_track: None,
        })
    }

    /// Names the track this chain serves: while the UI watches it (`MultibandMeterTap::tracks`), every block publishes the
    /// compressor's band reductions (the Compressor panel's GR meter).
    pub fn set_meter_track(&mut self, track: Id) {
        self.meter_track = Some(MultibandMeterTap::split(track));
    }

    /// The handle for the parameter setters, to be used from any thread.
    pub fn controls(&self) -> Arc<RealtimeControls> {
        Arc::clone(&self.controls)
    }

    /// In place. `buffers[c]` holds `frame_count` Floats of channel c (`frame_count <= max_frames`).
    /// `timeline_sample` = timeline position (48 kHz samples) of the first sample of this block.
    pub fn process(&mut self, buffers: &mut [&mut [f32]], frame_count: usize, timeline_sample: i64) {
        if frame_count == 0 {
            return;
        }
        assert!(frame_count <= self.max_frames, "frameCount exceeds maxFrames");
        let buffers = &mut buffers[..self.channel_count];

        if self.controls.reset_requested.swap(false, Ordering::AcqRel) {
            self.reset_state();
        }
        if let Ok(mut m) = self.controls.mailbox.try_lock()
            && m.dirty
        {
            let was_de_ess = self.params.de_ess;
            std::mem::swap(&mut self.params, &mut m.outbox); // old value parks in the mailbox, freed by the next setter
            if self.params.de_ess && !was_de_ess {
                self.de_esser.reset();
            }
            m.dirty = false;
            self.gate.apply(&self.params.gate);
            self.compressor.apply(&self.params.compressor, true);
            self.saturator.apply(&self.params.saturation);
        }

        self.params.volume.apply(buffers, frame_count, timeline_sample, Self::SAMPLE_RATE);
        if let Some(d) = &mut self.denoise {
            let mix: f32 = if self.params.bypass { 0.0 } else { self.params.mix.clamp(0.0, 1.0) };
            d.process(buffers, frame_count, mix, mix);
        }
        self.gate.process_channels(buffers, frame_count);
        self.compressor.process(buffers, frame_count);
        if let Some((hi, lo)) = self.meter_track {
            let tap = MultibandMeterTap::tracks();
            if tap.is_watched(hi, lo) {
                tap.publish(self.compressor.take_meter_peak(), self.compressor.gain_reduction_db(), 0.0);
                tap.publish_gate(self.gate.open_state());
            }
        }
        if self.params.de_ess && !self.params.bypass {
            self.de_esser.process(buffers, frame_count);
        }
        self.saturator.process_channels(buffers, frame_count);
    }

    fn reset_state(&mut self) {
        self.gate.reset();
        self.compressor.reset();
        self.de_esser.reset();
        if let Some(d) = &mut self.denoise {
            d.reset();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::creator_fx::{NoiseGateSettings, SaturationSettings};
    use crate::gain::sig;
    use crate::offline_audio_fx::OfflineAudioFX;
    use crate::presets::MultibandCompressorSettings;
    use sq_core_model::AudioTag;
    use sq_core_time::{Id, Keyframe, KeyframeTrack, Time};

    fn rt(
        preset: &TrackAudioPreset,
        volume: VolumeAutomation,
        channels: usize,
        max_frames: usize,
        denoiser: bool,
    ) -> RealtimeAudioFX {
        match RealtimeAudioFX::new(preset, volume, channels, max_frames, denoiser) {
            Ok(f) => f,
            Err(e) => panic!("realtime fx: {e}"),
        }
    }

    fn flat() -> VolumeAutomation {
        VolumeAutomation::new(0.0, None, None)
    }

    /// Runs `fx.process` over `input` (one array per channel) in the given chunk sizes.
    fn run_rt(fx: &mut RealtimeAudioFX, input: &[Vec<f32>], chunks: &[usize], start_sample: i64) -> Vec<Vec<f32>> {
        let n = input[0].len();
        let mut out = vec![Vec::new(); input.len()];
        let (mut pos, mut k) = (0, 0);
        let max_f = chunks.iter().copied().max().unwrap_or(1);
        let mut bufs = vec![vec![0.0_f32; max_f]; input.len()];
        while pos < n {
            let m = chunks[k % chunks.len()].min(n - pos);
            k += 1;
            for (c, b) in bufs.iter_mut().enumerate() {
                b[..m].copy_from_slice(&input[c][pos..pos + m]);
            }
            let mut views: Vec<&mut [f32]> = bufs.iter_mut().map(Vec::as_mut_slice).collect();
            fx.process(&mut views, m, start_sample + pos as i64);
            for (c, b) in bufs.iter().enumerate() {
                out[c].extend_from_slice(&b[..m]);
            }
            pos += m;
        }
        out
    }

    fn max_diff(a: &[Vec<f32>], b: &[Vec<f32>]) -> f32 {
        let mut d: f32 = 0.0;
        for c in 0..a.len() {
            for i in 0..a[c].len() {
                d = d.max((a[c][i] - b[c][i]).abs());
            }
        }
        d
    }

    fn test_signal(n: usize) -> Vec<Vec<f32>> {
        let s = sig::sine(300.0, -12.0, n as f64 / 48000.0, 48000, 2, 0.0);
        let nz = sig::low_noise(0.05, n, 1);
        (0..2).map(|c| (0..n).map(|i| s[c][i] + nz[i] * if c == 0 { 1.0 } else { 0.7 }).collect()).collect()
    }

    fn keys(a: (Time, f64), b: (Time, f64)) -> KeyframeTrack<f64> {
        KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(1), a.0, a.1),
            Keyframe::new(Id::from_u128(2), b.0, b.1),
        ])
    }

    #[test]
    fn matches_offline_in_random_chunks() {
        let vol = VolumeAutomation {
            pan: Some(0.3),
            ..VolumeAutomation::new(0.0, Some(keys((Time::ZERO, -12.0), (Time::new(1, 1), 0.0))), None)
        };
        let presets = [
            TrackAudioPreset::voice(),
            TrackAudioPreset::music(),
            TrackAudioPreset::off(),
            TrackAudioPreset::for_role(AudioTag::Dialogue),
            TrackAudioPreset::for_role(AudioTag::Music),
        ];
        for preset in presets {
            let x = test_signal(48000 + 777);
            let Ok(mut off) = OfflineAudioFX::new(vol.clone(), preset.clone(), 48000, 2) else { panic!("offline") };
            let reference = off.process(&x, Time::ZERO);
            let mut fx = rt(&preset, vol.clone(), 2, 1024, preset.noise_reduction > 0.0);
            assert_eq!(fx.latency_samples, off.latency_samples());
            let out = run_rt(&mut fx, &x, &[1, 512, 37, 1024, 480, 481, 100, 3], 0);
            assert!(max_diff(&reference, &out) < 1e-6, "preset {}", preset.id);
        }
    }

    #[test]
    fn de_esser_state_is_cleared_on_reset() {
        let n = 4800;
        let x = vec![
            (0..n)
                .map(|i| (0.3 * (2.0 * std::f64::consts::PI * 7000.0 * i as f64 / 48000.0).sin()) as f32)
                .collect::<Vec<f32>>(),
        ];
        let p = TrackAudioPreset::for_role(AudioTag::Dialogue);
        let mut fresh = rt(&p, flat(), 1, 1024, false);
        let reference = run_rt(&mut fresh, &x, &[1024], 0);
        let mut used = rt(&p, flat(), 1, 1024, false);
        run_rt(&mut used, &x, &[1024], 0);
        used.controls().reset();
        assert_eq!(max_diff(&reference, &run_rt(&mut used, &x, &[1024], 0)), 0.0);
    }

    #[test]
    fn parameter_change_applies_on_next_block() {
        let mut fx = rt(&TrackAudioPreset::off(), flat(), 1, 256, false);
        let x = vec![vec![0.5_f32; 256]];
        let a = run_rt(&mut fx, &x, &[256], 0);
        assert!((a[0][100] - 0.5).abs() < 1e-6);
        fx.controls().set_volume(VolumeAutomation::new(-6.0206, None, None));
        let b = run_rt(&mut fx, &x, &[256], 0);
        assert!((b[0][0] - 0.25).abs() < 1e-4);
        assert!((b[0][255] - 0.25).abs() < 1e-4);
    }

    #[test]
    fn compressor_change_keeps_detector_state() {
        let mut loud = TrackAudioPreset::music();
        loud.noise_reduction = 0.0;
        let mut fx = rt(&loud, flat(), 1, 512, false);
        let x = sig::sine(1000.0, -3.0, 0.3, 48000, 1, 0.0);
        run_rt(&mut fx, &x, &[512], 0);
        let mut tweaked = loud.clone();
        tweaked.compressor.makeup_gain_db += 0.0; // same layout, same values
        fx.controls().set_preset(&tweaked);
        let mut reference = rt(&loud, flat(), 1, 512, false);
        run_rt(&mut reference, &x, &[512], 0);
        let y = sig::sine(1000.0, -3.0, 0.05, 48000, 1, 0.0);
        assert_eq!(max_diff(&run_rt(&mut fx, &y, &[512], 0), &run_rt(&mut reference, &y, &[512], 0)), 0.0);
    }

    #[test]
    fn reset_makes_output_independent_of_history() {
        let x = test_signal(9000);
        let vol = VolumeAutomation::new(-3.0, None, None);
        let mut fresh = rt(&TrackAudioPreset::voice(), vol.clone(), 2, 512, true);
        let reference = run_rt(&mut fresh, &x, &[512, 100], 0);
        let mut used = rt(&TrackAudioPreset::voice(), vol, 2, 512, true);
        let loud: Vec<Vec<f32>> = test_signal(20000).iter().map(|c| c.iter().map(|v| v * 3.0).collect()).collect();
        run_rt(&mut used, &loud, &[333], 0);
        used.controls().reset();
        assert_eq!(max_diff(&run_rt(&mut used, &x, &[512, 100], 0), &reference), 0.0);
    }

    #[test]
    fn latency_stays_constant_while_denoiser_exists() {
        let fx = rt(&TrackAudioPreset::voice(), VolumeAutomation::default(), 1, 64, true);
        assert_eq!(fx.latency_samples, 480);
        fx.controls().set_denoise_mix(0.0);
        assert_eq!(fx.latency_samples, 480);
        let none = rt(&TrackAudioPreset::off(), VolumeAutomation::default(), 1, 64, false);
        assert_eq!(none.latency_samples, 0);
    }

    #[test]
    fn volume_follows_timeline_sample_after_seek() {
        let track = keys((Time::ZERO, -60.0), (Time::new(10, 1), 0.0));
        let mut fx = rt(&TrackAudioPreset::off(), VolumeAutomation::new(0.0, Some(track), None), 1, 256, false);
        let x = vec![vec![1.0_f32; 256]];
        let late = run_rt(&mut fx, &x, &[256], 48000 * 10);
        assert!((late[0][10] - 1.0).abs() < 1e-3);
        let early = run_rt(&mut fx, &x, &[256], 0);
        assert!(early[0][10] < 0.01);
    }

    #[test]
    fn realtime_matches_offline_with_gate_and_saturation() {
        let mut preset = TrackAudioPreset::new("x", "x", MultibandCompressorSettings::neutral());
        preset.noise_reduction = 0.0;
        preset.gate = NoiseGateSettings { enabled: true, threshold_db: -35.0, ..NoiseGateSettings::default() };
        preset.saturation = SaturationSettings { enabled: true, drive_db: 9.0, mix: 0.7 };
        let mut signal = sig::sine(220.0, -8.0, 0.3, 48000, 2, 0.0);
        let nz = sig::noise(0.003, 9600, 1);
        for c in signal.iter_mut() {
            c.extend_from_slice(&nz);
        }
        let Ok(mut off) = OfflineAudioFX::new(flat(), preset.clone(), 48000, 2) else { panic!("offline") };
        let want = off.render(&signal, Time::ZERO).channels;
        let mut fx = rt(&preset, flat(), 2, 512, false);
        let got = run_rt(&mut fx, &signal, &[300], 0);
        assert!(max_diff(&want, &got) < 1e-5);
    }

    #[test]
    fn a_watched_track_publishes_its_compressor_reduction() {
        let id = Id::from_u128(0x7ac4_0001);
        let mut preset = TrackAudioPreset::off();
        preset.compressor = MultibandCompressorSettings::new(
            vec![120.0, 900.0, 4500.0],
            vec![crate::presets::MultibandBand::new(-40.0, 8.0, 0.5, 50.0); 4],
        );
        preset.noise_reduction = 0.0;
        let signal = sig::sine(220.0, -6.0, 0.4, 48000, 2, 0.0);
        let mut fx = rt(&preset, flat(), 2, 512, false);
        fx.set_meter_track(id);
        let tap = MultibandMeterTap::tracks();
        assert!(tap.reading(id).is_none(), "nobody watches yet");
        tap.watch(Some(id));
        run_rt(&mut fx, &signal, &[512], 0);
        let r = tap.reading(id).expect("watched");
        assert!(r.sequence > 0 && r.gain_reduction_db.iter().any(|g| *g > 1.0), "{r:?}");
        assert_eq!(tap.gate_open(id), None, "the gate is off: no Open / Closed");
        tap.watch(None);
    }

    #[test]
    fn the_track_tap_carries_the_live_gate_state() {
        let id = Id::from_u128(0x7ac4_0002);
        let mut preset = TrackAudioPreset::off();
        preset.gate = NoiseGateSettings { enabled: true, threshold_db: -35.0, ..NoiseGateSettings::default() };
        preset.noise_reduction = 0.0;
        let loud = sig::sine(220.0, -6.0, 0.4, 48000, 2, 0.0);
        let mut fx = rt(&preset, flat(), 2, 512, false);
        fx.set_meter_track(id);
        let tap = MultibandMeterTap::tracks();
        tap.watch(Some(id));
        run_rt(&mut fx, &loud, &[512], 0);
        assert_eq!(tap.gate_open(id), Some(true), "a loud tone holds the gate open");
        tap.watch(None);
    }
}
