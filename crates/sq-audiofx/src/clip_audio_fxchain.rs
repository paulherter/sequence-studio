//! Port of `SQAudioFX/Sources/SQAudioFX/ClipAudioFXChain.swift`.

use crate::audio_spectrum::AudioSpectrumTap;
use crate::creator_stages::{ChorusStage, StereoWidthStage};
use crate::de_reverb::DeReverbStage;
use crate::enhance_speech::EnhanceSpeechStage;
use crate::gain::{AudioFXError, GainMath};
use crate::graphic_eqstage::GraphicEQStage;
use crate::limiter::MasterLimiter;
use crate::multiband::BandState;
use crate::multiband_meters::MultibandMeterTap;
use crate::notch_stage::{NotchParams, NotchStage};
use crate::parametric_eq::{MultibandStage, ParametricEQStage};
use crate::pitch_shift::{DisguiseVoiceStage, PitchShiftStage};
use crate::repair_stages::{DeHumParams, DeHumStage, DialogueLevelerStage, HighCutStage, LowCutStage};
use crate::rnnoise_denoiser::{self, DenoiseState, RNNoiseDenoiser};
use crate::role_chain::DeEsser;
use crate::space_and_gate_stages::{DelayStage, NoiseGateStage, ReverbStage};
use sq_core_audio::audio_effects::*;
use std::sync::Arc;

const PI: f64 = std::f64::consts::PI;

/// The audio effect stack of one clip (AUDIO-FX): its `audio.*` effects in list order, on deinterleaved Float channels, in
/// place, at 48 kHz. One instance per clip and mix thread; the layout (which effects, in which order) is fixed, the values
/// (`AudioFXStep`s, evaluated by the caller per block) can change every block without losing state.
///
/// Stages: Noise Reduction (RNNoise wet/dry, as in `RealtimeAudioFX`), Parametric EQ (RBJ low shelf, peak, high shelf),
/// Compressor (single band, the 4-band compressor's detector), De-Esser (`DeEsser`), Gain, Hard Limiter (`MasterLimiter`), Noise Gate, Delay (2 s line), Reverb (Freeverb): see `space_and_gate_stages`.
/// A disabled step passes the sound through; a disabled Noise Reduction (and De-Reverb) still delays it, so the latency never changes.
///
/// Latency: 480 samples when the layout holds a Noise Reduction, plus `MultibandStage::LATENCY` (240) per Multiband
/// Compressor, `AudioDeReverbValues::LATENCY_SAMPLES` per De-Reverb and `AudioEnhanceSpeechValues::LATENCY_SAMPLES` per Enhance Speech, `AudioPitchValues::LATENCY_SAMPLES` per Pitch Shift and Disguise Voice, else 0. The caller compensates it (reads ahead).
/// `process` does not allocate (state is preallocated in `new`, stages are objects); it is not thread-safe.
pub struct ClipAudioFXChain {
    pub layout: Vec<AudioFXSlot>,
    pub channel_count: usize,
    pub max_frames: usize,
    pub latency_samples: usize,
    stages: Vec<Stage>,
    /// Slot ids pre-split for the spectrum tap (one compare per stage and block decides whether to publish).
    slot_keys: Vec<(u64, u64)>,
    /// None = the shared tap.
    spectrum_tap: Option<Arc<AudioSpectrumTap>>,
}

impl ClipAudioFXChain {
    pub const SAMPLE_RATE: i64 = 48_000;
    /// Sub-block length over which ramped parameters (EQ, compressor, limiter ceiling) are re-evaluated.
    pub(crate) const RAMP_CHUNK: usize = 32;

    pub fn new(
        layout: Vec<AudioFXSlot>,
        channel_count: usize,
        max_frames: usize,
        spectrum_tap: Option<Arc<AudioSpectrumTap>>,
    ) -> Result<Self, AudioFXError> {
        if channel_count == 0 {
            return Err(AudioFXError::InvalidChannelCount(0));
        }
        let max_frames = max_frames.max(1);
        let slot_keys = layout.iter().map(|s| MultibandMeterTap::split(s.id)).collect();
        let fs = Self::SAMPLE_RATE as f64;
        let sr = Self::SAMPLE_RATE;
        let ch = channel_count;
        let mut stages = Vec::with_capacity(layout.len());
        for s in &layout {
            let stage = match s.kind.as_str() {
                AUDIO_NOISE_REDUCTION_KIND => {
                    Stage::Denoise(Denoise::new(ch).ok_or(AudioFXError::DenoiserUnavailable)?)
                }
                AUDIO_EQ_KIND => Stage::Eq(Eq::new(ch)),
                AUDIO_COMPRESSOR_KIND => Stage::Compressor(Compressor::new(fs)),
                AUDIO_DE_ESSER_KIND => Stage::DeEsser(DeEsserStage::new(sr, ch)),
                AUDIO_DE_REVERB_KIND => Stage::DeReverb(DeReverbStage::new(fs, ch)),
                AUDIO_GAIN_KIND => Stage::Gain,
                AUDIO_PARAMETRIC_EQ_KIND => Stage::ParametricEQ(ParametricEQStage::new(ch)),
                AUDIO_MULTIBAND_KIND => {
                    Stage::Multiband(Box::new(MultibandStage::new(fs, ch, s.id, MultibandMeterTap::shared())))
                }
                AUDIO_NOISE_GATE_KIND => Stage::Gate(NoiseGateStage::new(fs)),
                AUDIO_DELAY_KIND => Stage::Delay(DelayStage::new(fs, ch)),
                AUDIO_REVERB_KIND => Stage::Reverb(Box::new(ReverbStage::new(fs, ch))),
                AUDIO_LIMITER_KIND => Stage::Limiter(LimiterStage::new(sr, max_frames)),
                AUDIO_DE_HUM_KIND => Stage::DeHum(DeHumStage::new(fs, ch)),
                AUDIO_LOW_CUT_KIND => Stage::LowCut(LowCutStage::new(fs, ch)),
                AUDIO_DIALOGUE_LEVELER_KIND => Stage::Leveler(DialogueLevelerStage::new(fs)),
                AUDIO_ENHANCE_SPEECH_KIND => {
                    Stage::Enhance(Box::new(EnhanceSpeechStage::new(fs, ch).ok_or(AudioFXError::DenoiserUnavailable)?))
                }
                AUDIO_HIGH_CUT_KIND => Stage::HighCut(HighCutStage::new(fs, ch)),
                AUDIO_STEREO_WIDTH_KIND => Stage::StereoWidth(StereoWidthStage),
                AUDIO_CHORUS_KIND => Stage::Chorus(ChorusStage::new(fs, ch)),
                AUDIO_NOTCH_KIND => Stage::Notch(NotchStage::new(fs, ch)),
                AUDIO_GRAPHIC_EQ_KIND => Stage::GraphicEQ(GraphicEQStage::new(ch)),
                AUDIO_PITCH_SHIFT_KIND => Stage::PitchShift(PitchShiftStage::new(ch)),
                AUDIO_DISGUISE_VOICE_KIND => Stage::DisguiseVoice(Box::new(DisguiseVoiceStage::new(fs, ch, s.id))),
                _ => Stage::None,
            };
            stages.push(stage);
        }
        // Noise Reduction: one RNNoise frame; every Multiband Compressor: its limiter's look-ahead (also while disabled).
        let count = |kinds: &[&str]| layout.iter().filter(|s| kinds.contains(&s.kind.as_str())).count();
        let latency_samples = (if count(&[AUDIO_NOISE_REDUCTION_KIND]) > 0 { RNNoiseDenoiser::LATENCY_SAMPLES } else { 0 })
            + count(&[AUDIO_MULTIBAND_KIND]) * MultibandStage::LATENCY
            + count(&[AUDIO_DE_REVERB_KIND]) * AudioDeReverbValues::LATENCY_SAMPLES as usize
            + count(&[AUDIO_ENHANCE_SPEECH_KIND]) * AudioEnhanceSpeechValues::LATENCY_SAMPLES as usize
            // Pitch Shift and Disguise Voice: one analysis window each (also while disabled).
            + count(&[AUDIO_PITCH_SHIFT_KIND, AUDIO_DISGUISE_VOICE_KIND]) * AudioPitchValues::LATENCY_SAMPLES as usize;
        Ok(ClipAudioFXChain { layout, channel_count, max_frames, latency_samples, stages, slot_keys, spectrum_tap })
    }

    /// Clears all filter, detector and denoiser history (a seek, or the clip starts again).
    pub fn reset(&mut self) {
        for st in &mut self.stages {
            match st {
                Stage::Denoise(d) => d.reset(),
                Stage::Eq(e) => e.reset(),
                Stage::Compressor(c) => c.reset(),
                Stage::DeEsser(d) => d.reset(),
                Stage::DeReverb(d) => d.reset(),
                Stage::Limiter(l) => l.reset(),
                Stage::ParametricEQ(e) => e.reset(),
                Stage::Multiband(m) => m.reset(),
                Stage::Gate(g) => g.reset(),
                Stage::Delay(d) => d.reset(),
                Stage::Reverb(r) => r.reset(),
                Stage::DeHum(d) => d.reset(),
                Stage::LowCut(d) => d.reset(),
                Stage::Leveler(d) => d.reset(),
                Stage::Enhance(e) => e.reset(),
                Stage::HighCut(d) => d.reset(),
                Stage::StereoWidth(d) => d.reset(),
                Stage::Chorus(d) => d.reset(),
                Stage::Notch(d) => d.reset(),
                Stage::GraphicEQ(d) => d.reset(),
                Stage::PitchShift(p) => p.reset(),
                Stage::DisguiseVoice(d) => d.reset(),
                Stage::Gain | Stage::None => {}
            }
        }
    }

    /// In place. `steps` are the values at the first sample (same ids and order as `layout`; a missing or mismatched step
    /// silences the block, never passes it dry), `end_steps` the values one block later: every parameter moves towards them across the block
    /// (gains and the denoiser amount per sample, EQ, compressor and limiter ceiling every `RAMP_CHUNK` samples).
    pub fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        frame_count: usize,
        steps: &[AudioFXStep],
        end_steps: Option<&[AudioFXStep]>,
    ) {
        let n = frame_count;
        if n == 0 {
            return;
        }
        assert!(n <= self.max_frames, "frameCount exceeds maxFrames");
        let buf = &mut buf[..self.channel_count];
        let tap: &AudioSpectrumTap = self.spectrum_tap.as_deref().unwrap_or_else(|| AudioSpectrumTap::shared());
        for i in 0..self.stages.len() {
            // Fail closed: a stage without its matching step would pass the voice dry (Disguise Voice must never leak it).
            if i >= steps.len() || steps[i].id != self.layout[i].id {
                for c in buf.iter_mut() {
                    c[..n].fill(0.0);
                }
                return;
            }
            let step = &steps[i];
            let mut end = step;
            if let Some(e) = end_steps
                && i < e.len()
                && e[i].id == step.id
            {
                end = &e[i];
            }
            let tapped = tap.is_watched(self.slot_keys[i].0, self.slot_keys[i].1);
            let tap_input = tapped && tap.at_input();
            if tap_input {
                tap.push(buf, n);
            }
            Self::run_stage(&mut self.stages[i], step, end, buf, n);
            if tapped && !tap_input {
                tap.push(buf, n);
            }
        }
    }

    /// One stage over the block (`step` at the first sample, `end` one block later).
    fn run_stage(stage: &mut Stage, step: &AudioFXStep, end: &AudioFXStep, buf: &mut [&mut [f32]], n: usize) {
        match (stage, &step.stage) {
            (Stage::Denoise(d), AudioFXStage::NoiseReduction { amount }) => {
                let mut amount_end = *amount;
                if let AudioFXStage::NoiseReduction { amount: a } = &end.stage {
                    amount_end = *a;
                }
                let m0 = if step.enabled { amount.clamp(0.0, 1.0) as f32 } else { 0.0 };
                let m1 = if step.enabled { amount_end.clamp(0.0, 1.0) as f32 } else { 0.0 };
                d.process_strength(buf, n, m0, m1);
            }
            (Stage::Eq(e), AudioFXStage::Eq(v)) => {
                if !step.enabled {
                    e.was_off = true;
                    return;
                }
                let mut v1 = *v;
                if let AudioFXStage::Eq(x) = &end.stage {
                    v1 = *x;
                }
                e.process(buf, n, v, &v1, Self::SAMPLE_RATE as f64);
            }
            (
                Stage::Compressor(c),
                AudioFXStage::Compressor { threshold_db, ratio, attack_ms, release_ms, makeup_db },
            ) => {
                if !step.enabled {
                    c.was_off = true;
                    return;
                }
                let mut to = (*threshold_db, *ratio, *makeup_db);
                if let AudioFXStage::Compressor { threshold_db: t1, ratio: r1, makeup_db: m1, .. } = &end.stage {
                    to = (*t1, *r1, *m1);
                }
                c.process(buf, n, (*threshold_db, *ratio, *makeup_db), to, *attack_ms, *release_ms);
            }
            (
                Stage::DeEsser(d),
                AudioFXStage::DeEsser { reduction_db, sensitivity, frequency_hz, range, speed, listen },
            ) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                let mut to = (*reduction_db, *sensitivity);
                if let AudioFXStage::DeEsser { reduction_db: r1, sensitivity: s1, .. } = &end.stage {
                    to = (*r1, *s1);
                }
                d.set_target(*frequency_hz, *range, *speed, *listen);
                d.process(buf, n, (*reduction_db, *sensitivity), to);
            }
            (Stage::DeReverb(d), AudioFXStage::DeReverb { amount, decay_seconds, tone }) => {
                d.process(buf, n, *amount, *decay_seconds, *tone, step.enabled);
            }
            (Stage::Gain, AudioFXStage::Gain { db }) => {
                if !step.enabled {
                    return;
                }
                let mut b = *db;
                if let AudioFXStage::Gain { db: e } = &end.stage {
                    b = *e;
                }
                Self::ramp(buf, n, *db, b);
            }
            (Stage::Limiter(l), AudioFXStage::Limiter { input_db, ceiling_db }) => {
                if !step.enabled {
                    l.was_off = true;
                    return;
                }
                let (mut in_end, mut ceil_end) = (*input_db, *ceiling_db);
                if let AudioFXStage::Limiter { input_db: e, ceiling_db: c } = &end.stage {
                    in_end = *e;
                    ceil_end = *c;
                }
                Self::ramp(buf, n, *input_db, in_end);
                l.process(buf, n, *ceiling_db, ceil_end);
            }
            (Stage::ParametricEQ(e), AudioFXStage::ParametricEq(v)) => {
                if !step.enabled {
                    e.was_off = true;
                    return;
                }
                let mut v1 = *v;
                if let AudioFXStage::ParametricEq(x) = &end.stage {
                    v1 = *x;
                }
                e.process(buf, n, v, &v1, Self::SAMPLE_RATE as f64);
            }
            (Stage::Multiband(m), AudioFXStage::Multiband(v)) => {
                if !step.enabled {
                    m.bypass(buf, n);
                    return;
                }
                let mut v1 = *v;
                if let AudioFXStage::Multiband(x) = &end.stage {
                    v1 = *x;
                }
                m.process(buf, n, v, &v1);
            }
            (Stage::Gate(g), AudioFXStage::NoiseGate { threshold_db, attack_ms, release_ms, range_db, hold_ms }) => {
                if !step.enabled {
                    g.was_off = true;
                    return;
                }
                let mut to = (*threshold_db, *range_db);
                if let AudioFXStage::NoiseGate { threshold_db: t1, range_db: r1, .. } = &end.stage {
                    to = (*t1, *r1);
                }
                g.process(buf, n, (*threshold_db, to.0), (*attack_ms, *release_ms, *hold_ms), (*range_db, to.1));
            }
            (Stage::Delay(d), AudioFXStage::Delay { time_ms, feedback, mix }) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                let mut to = (*time_ms, *feedback, *mix);
                if let AudioFXStage::Delay { time_ms: t1, feedback: f1, mix: m1 } = &end.stage {
                    to = (*t1, *f1, *m1);
                }
                d.process(buf, n, (*time_ms, to.0), (*feedback, to.1), (*mix, to.2));
            }
            (Stage::Reverb(r), AudioFXStage::Reverb { room_size, damping, mix }) => {
                if !step.enabled {
                    r.was_off = true;
                    return;
                }
                let mut to = (*room_size, *damping, *mix);
                if let AudioFXStage::Reverb { room_size: a, damping: b, mix: m1 } = &end.stage {
                    to = (*a, *b, *m1);
                }
                r.process(buf, n, to.0, to.1, (*mix, to.2));
            }
            (Stage::DeHum(d), AudioFXStage::DeHum { frequency_hz, q, gain_db, harmonics, slope, listen }) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                d.process(
                    buf,
                    n,
                    DeHumParams {
                        frequency_hz: *frequency_hz,
                        q: *q,
                        gain_db: *gain_db,
                        harmonics: *harmonics,
                        slope: *slope,
                        listen: *listen,
                    },
                );
            }
            (Stage::LowCut(d), AudioFXStage::LowCut { frequency_hz, order }) => {
                if !step.enabled {
                    d.set_was_off(true);
                    return;
                }
                d.process(buf, n, *frequency_hz, *order);
            }
            (Stage::HighCut(d), AudioFXStage::HighCut { frequency_hz, order }) => {
                if !step.enabled {
                    d.set_was_off(true);
                    return;
                }
                d.process(buf, n, *frequency_hz, *order);
            }
            (Stage::StereoWidth(d), AudioFXStage::StereoWidth { width }) => {
                if !step.enabled {
                    return;
                }
                let mut w1 = *width;
                if let AudioFXStage::StereoWidth { width: x } = &end.stage {
                    w1 = *x;
                }
                d.process(buf, n, *width, w1);
            }
            (Stage::Notch(d), AudioFXStage::Notch { frequency_hz, q, depth_db }) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                let a = NotchParams { hz: *frequency_hz, q: *q, depth_db: *depth_db };
                let mut e = a;
                if let AudioFXStage::Notch { frequency_hz: h1, q: q1, depth_db: d1 } = &end.stage {
                    e = NotchParams { hz: *h1, q: *q1, depth_db: *d1 };
                }
                d.process(buf, n, a, e);
            }
            (Stage::GraphicEQ(d), AudioFXStage::GraphicEq(v)) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                let mut v1 = *v;
                if let AudioFXStage::GraphicEq(x) = &end.stage {
                    v1 = *x;
                }
                d.process(buf, n, v, &v1, Self::SAMPLE_RATE as f64);
            }
            (Stage::Chorus(d), AudioFXStage::Chorus { rate_hz, depth_ms, mix }) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                let mut m1 = *mix;
                if let AudioFXStage::Chorus { mix: x, .. } = &end.stage {
                    m1 = *x;
                }
                d.process(buf, n, *rate_hz, *depth_ms, *mix, m1);
            }
            (Stage::Leveler(d), AudioFXStage::DialogueLeveler(v)) => {
                if !step.enabled {
                    d.was_off = true;
                    return;
                }
                d.process(buf, n, v, 1.0);
            }
            (Stage::Enhance(e), AudioFXStage::EnhanceSpeech(v)) => {
                let mut v1 = *v;
                if let AudioFXStage::EnhanceSpeech(x) = &end.stage {
                    v1 = *x;
                }
                e.process(buf, n, v, &v1, step.enabled);
            }
            (Stage::PitchShift(p), AudioFXStage::PitchShift { semitones, preserve_formants }) => {
                let mut to = *semitones;
                if let AudioFXStage::PitchShift { semitones: s1, .. } = &end.stage {
                    to = *s1;
                }
                p.process(buf, n, *semitones, to, *preserve_formants, step.enabled);
            }
            (Stage::DisguiseVoice(d), AudioFXStage::DisguiseVoice { voice, at }) => {
                d.process(buf, n, *voice, *at, step.enabled);
            }
            _ => {}
        }
    }

    /// Array convenience (tests, offline): `buf[c]` all the same length, at most `max_frames`.
    pub fn process_vecs(&mut self, buf: &mut [Vec<f32>], steps: &[AudioFXStep], end_steps: Option<&[AudioFXStep]>) {
        let n = buf.first().map_or(0, Vec::len);
        if n == 0 {
            return;
        }
        // Missing channels repeat the last one, as in Swift (`buf[min(c, buf.count - 1)]`).
        let mut work: Vec<Vec<f32>> = (0..self.channel_count).map(|c| buf[c.min(buf.len() - 1)].clone()).collect();
        let mut chans: Vec<&mut [f32]> = work.iter_mut().map(Vec::as_mut_slice).collect();
        self.process(&mut chans, n, steps, end_steps);
        for c in 0..self.channel_count.min(buf.len()) {
            buf[c].copy_from_slice(&work[c]);
        }
    }

    /// Linear gain ramp from `from_db` (first sample) towards `to_db` (one block later).
    pub(crate) fn ramp(buf: &mut [&mut [f32]], n: usize, from_db: f64, to_db: f64) {
        let g0 = GainMath::linear_from_db(from_db) as f32;
        let g1 = GainMath::linear_from_db(to_db) as f32;
        if g0 == 1.0 && g1 == 1.0 {
            return;
        }
        let step = (g1 - g0) / n as f32;
        for p in buf.iter_mut() {
            if g0 == g1 {
                for s in &mut p[..n] {
                    *s *= g0;
                }
            } else {
                for (i, s) in p[..n].iter_mut().enumerate() {
                    *s *= g0 + step * i as f32;
                }
            }
        }
    }
}

enum Stage {
    Denoise(Denoise),
    Eq(Eq),
    Compressor(Compressor),
    DeEsser(DeEsserStage),
    DeReverb(DeReverbStage),
    PitchShift(PitchShiftStage),
    DisguiseVoice(Box<DisguiseVoiceStage>),
    Gain,
    Limiter(LimiterStage),
    ParametricEQ(ParametricEQStage),
    Multiband(Box<MultibandStage>),
    Gate(NoiseGateStage),
    Delay(DelayStage),
    Reverb(Box<ReverbStage>),
    DeHum(DeHumStage),
    LowCut(LowCutStage),
    Leveler(DialogueLevelerStage),
    Enhance(Box<EnhanceSpeechStage>),
    HighCut(HighCutStage),
    StereoWidth(StereoWidthStage),
    Chorus(ChorusStage),
    Notch(NotchStage),
    GraphicEQ(GraphicEQStage),
    None,
}

/// RNNoise per channel; the dry path is delayed by the same frame so the mix never shifts.
/// Also the denoiser inside Enhance Speech.
pub(crate) struct Denoise {
    channels: Vec<DenoiseChannel>,
}

struct DenoiseChannel {
    state: DenoiseState,
    in_frame: Vec<f32>,
    wet: Vec<f32>,
    dry: Vec<f32>,
    pos: usize,
}

impl Denoise {
    pub(crate) fn new(n: usize) -> Option<Denoise> {
        rnnoise_denoiser::global_init();
        let f = RNNoiseDenoiser::FRAME_SIZE;
        let mut channels = Vec::with_capacity(n);
        for _ in 0..n {
            channels.push(DenoiseChannel {
                state: DenoiseState::new()?,
                in_frame: vec![0.0; f],
                wet: vec![0.0; f],
                dry: vec![0.0; f],
                pos: 0,
            });
        }
        Some(Denoise { channels })
    }

    pub(crate) fn reset(&mut self) {
        for c in &mut self.channels {
            c.state.reset();
            c.in_frame.fill(0.0);
            c.wet.fill(0.0);
            c.dry.fill(0.0);
            c.pos = 0;
        }
    }

    /// Wet/dry `m0` at the first sample moving linearly towards `m1` one block later.
    pub(crate) fn process(&mut self, buf: &mut [&mut [f32]], n: usize, m0: f32, m1: f32) {
        let f = RNNoiseDenoiser::FRAME_SIZE;
        let scale: f32 = 32768.0;
        let inv: f32 = 1.0 / 32768.0;
        let dm = (m1 - m0) / n as f32;
        let chs = buf.len();
        for (c, ch) in self.channels.iter_mut().enumerate().take(chs) {
            let p = &mut buf[c];
            let mut pos = ch.pos;
            for i in 0..n {
                let mix = m0 + dm * i as f32;
                ch.in_frame[pos] = p[i] * scale;
                p[i] = (ch.wet[pos] * mix + ch.dry[pos] * (1.0 - mix)) * inv;
                pos += 1;
                if pos == f {
                    ch.state.process_frame(&mut ch.wet, &ch.in_frame);
                    ch.dry.copy_from_slice(&ch.in_frame);
                    pos = 0;
                }
            }
            ch.pos = pos;
        }
    }
}

/// Noise Reduction at Strength 0...1: the lowest band gain RNNoise may apply, `[below 2 kHz, 2 to 4 kHz, from 4 kHz, relax]`.
/// The first three are linear gains (`FLOOR_DB` at 100 %, linear in dB with Strength); `relax` (0...1) lets frames RNNoise
/// takes for speech keep more of the signal (the floor's dB is scaled by `1 - relax * speech probability`), so the noise
/// between words drops like in Premiere while the voice stays full.
/// Calibrated against Premiere's own export of "Klingeltoene" (Strength 40 %, notes/proof/audio-premiere/result.md round 2).
/// shortcut: one reference at 40 %; the 100 % depths (32 / 16 / 8 dB) are extrapolated linearly in dB, re-measure at 80 %.
const FLOOR_DB: [f32; 3] = [32.0, 16.0, 8.0];
const FLOOR_SPEECH_RELAX: f32 = 0.8;

pub(crate) fn denoise_floors(strength: f32) -> [f32; 4] {
    let s = strength.clamp(0.0, 1.0);
    [
        10f32.powf(-FLOOR_DB[0] * s / 20.0),
        10f32.powf(-FLOOR_DB[1] * s / 20.0),
        10f32.powf(-FLOOR_DB[2] * s / 20.0),
        FLOOR_SPEECH_RELAX,
    ]
}

impl Denoise {
    /// The Noise Reduction effect: Strength `m0` at the first sample moving linearly towards `m1` one block later. Each
    /// frame is RNNoise's own gain-shaped signal with the band gains bounded below by `denoise_floors` (no wet/dry mix of the
    /// synthesis: the noise is reduced by a bounded amount instead of the voice being replaced by RNNoise's rebuild). A
    /// strength of 0 passes the dry signal (the same one frame late).
    pub(crate) fn process_strength(&mut self, buf: &mut [&mut [f32]], n: usize, m0: f32, m1: f32) {
        let f = RNNoiseDenoiser::FRAME_SIZE;
        let scale: f32 = 32768.0;
        let inv: f32 = 1.0 / 32768.0;
        let dm = (m1 - m0) / n as f32;
        let chs = buf.len();
        for (c, ch) in self.channels.iter_mut().enumerate().take(chs) {
            let p = &mut buf[c];
            let mut pos = ch.pos;
            for i in 0..n {
                let m = m0 + dm * i as f32;
                ch.in_frame[pos] = p[i] * scale;
                p[i] = ch.wet[pos] * inv;
                pos += 1;
                if pos == f {
                    ch.state.process_frame_floor(&mut ch.wet, &ch.in_frame, denoise_floors(m));
                    if m <= 0.0 {
                        ch.wet.copy_from_slice(&ch.in_frame); // state stays warm, the sound is untouched
                    }
                    ch.dry.copy_from_slice(&ch.in_frame);
                    pos = 0;
                }
            }
            ch.pos = pos;
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct EqCoef {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

impl Default for EqCoef {
    fn default() -> Self {
        EqCoef { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0 }
    }
}

#[derive(Clone, Copy, Default)]
struct EqMem {
    z1: f64,
    z2: f64,
}

/// Low shelf, peak, high shelf (RBJ cookbook, shelf slope 1). Coefficients follow the values, filter memory stays.
pub(crate) struct Eq {
    low: EqCoef,
    mid: EqCoef,
    high: EqCoef,
    mem: Vec<EqMem>,
    channels: usize,
    values: Option<AudioEQValues>,
    pub was_off: bool,
}

impl Eq {
    pub(crate) fn new(channels: usize) -> Eq {
        Eq {
            low: EqCoef::default(),
            mid: EqCoef::default(),
            high: EqCoef::default(),
            mem: vec![EqMem::default(); channels * 3],
            channels,
            values: None,
            was_off: false,
        }
    }

    pub(crate) fn reset(&mut self) {
        self.mem.fill(EqMem::default());
    }

    fn set(&mut self, v: &AudioEQValues, fs: f64) {
        if self.values.as_ref() == Some(v) {
            return;
        }
        self.values = Some(*v);
        self.low = Self::shelf(true, v.low_hz, v.low_gain_db, fs);
        self.mid = Self::peak(v.mid_hz, v.mid_gain_db, v.mid_q, fs);
        self.high = Self::shelf(false, v.high_hz, v.high_gain_db, fs);
    }

    /// Values `v0` at the first sample moving linearly towards `v1` one block later (coefficients every `RAMP_CHUNK`).
    pub(crate) fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        v0: &AudioEQValues,
        v1: &AudioEQValues,
        fs: f64,
    ) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        if v0 == v1 {
            self.set(v0, fs);
            self.run(buf, 0, n);
            return;
        }
        let mut s = 0;
        while s < n {
            let k = ClipAudioFXChain::RAMP_CHUNK.min(n - s);
            let t = s as f64 / n as f64;
            let l = |a: f64, b: f64| a + (b - a) * t;
            self.set(
                &AudioEQValues {
                    low_gain_db: l(v0.low_gain_db, v1.low_gain_db),
                    low_hz: l(v0.low_hz, v1.low_hz),
                    mid_gain_db: l(v0.mid_gain_db, v1.mid_gain_db),
                    mid_hz: l(v0.mid_hz, v1.mid_hz),
                    mid_q: l(v0.mid_q, v1.mid_q),
                    high_gain_db: l(v0.high_gain_db, v1.high_gain_db),
                    high_hz: l(v0.high_hz, v1.high_hz),
                },
                fs,
            );
            self.run(buf, s, k);
            s += k;
        }
    }

    fn run(&mut self, buf: &mut [&mut [f32]], from: usize, n: usize) {
        let Some(v) = self.values else { return };
        for c in 0..buf.len().min(self.channels) {
            let p = &mut buf[c][from..from + n];
            for k in 0..3 {
                // A band at 0 dB is the identity (b == a): skipped once its memory is empty. A band coming back to 0 dB
                // keeps running until its memory has drained through the identity (2 samples), never cut (no click).
                let gain = match k {
                    0 => v.low_gain_db,
                    1 => v.mid_gain_db,
                    _ => v.high_gain_db,
                };
                let mut m = self.mem[c * 3 + k];
                if gain == 0.0 && m.z1 == 0.0 && m.z2 == 0.0 {
                    continue;
                }
                let q = match k {
                    0 => self.low,
                    1 => self.mid,
                    _ => self.high,
                };
                for s in p.iter_mut() {
                    let x = f64::from(*s);
                    let y = q.b0 * x + m.z1;
                    m.z1 = q.b1 * x - q.a1 * y + m.z2;
                    m.z2 = q.b2 * x - q.a2 * y;
                    *s = y as f32;
                }
                // At 0 dB the memory is only rounding noise once the input has passed through: drop it.
                if gain == 0.0 && m.z1.abs() < 1e-9 && m.z2.abs() < 1e-9 {
                    m = EqMem::default();
                }
                self.mem[c * 3 + k] = m;
            }
        }
    }

    fn shelf(low: bool, hz: f64, gain_db: f64, fs: f64) -> EqCoef {
        let a = 10.0_f64.powf(gain_db / 40.0);
        let w = 2.0 * PI * hz.max(10.0).min(fs * 0.45) / fs;
        let cw = w.cos();
        let alpha = w.sin() / 2.0 * 2.0_f64.sqrt();
        let sa = 2.0 * a.sqrt() * alpha;
        let (b0, b1, b2, a0, a1, a2);
        if low {
            b0 = a * ((a + 1.0) - (a - 1.0) * cw + sa);
            b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cw);
            b2 = a * ((a + 1.0) - (a - 1.0) * cw - sa);
            a0 = (a + 1.0) + (a - 1.0) * cw + sa;
            a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cw);
            a2 = (a + 1.0) + (a - 1.0) * cw - sa;
        } else {
            b0 = a * ((a + 1.0) + (a - 1.0) * cw + sa);
            b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cw);
            b2 = a * ((a + 1.0) + (a - 1.0) * cw - sa);
            a0 = (a + 1.0) - (a - 1.0) * cw + sa;
            a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cw);
            a2 = (a + 1.0) - (a - 1.0) * cw - sa;
        }
        EqCoef { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
    }

    fn peak(hz: f64, gain_db: f64, q: f64, fs: f64) -> EqCoef {
        let a = 10.0_f64.powf(gain_db / 40.0);
        let w = 2.0 * PI * hz.max(10.0).min(fs * 0.45) / fs;
        let alpha = w.sin() / (2.0 * q.max(0.01));
        let cw = w.cos();
        let a0 = 1.0 + alpha / a;
        EqCoef {
            b0: (1.0 + alpha * a) / a0,
            b1: -2.0 * cw / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: -2.0 * cw / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }
}

/// Single-band, stereo-linked peak compressor on the 4-band compressor's detector and smoothing.
struct Compressor {
    band: BandState,
    hold: f64,
    fs: f64,
    was_off: bool,
}

impl Compressor {
    fn new(sample_rate: f64) -> Self {
        Compressor {
            band: BandState::default(),
            hold: (-1.0 / (0.01 * sample_rate)).exp(),
            fs: sample_rate,
            was_off: false,
        }
    }

    fn reset(&mut self) {
        self.band.env = 0.0;
        self.band.gr = 0.0;
    }

    /// Threshold, ratio and makeup (dB, :1, dB) move from `a` to `b` across the block (every `RAMP_CHUNK` samples).
    fn process(
        &mut self,
        buf: &mut [&mut [f32]],
        n: usize,
        a: (f64, f64, f64),
        b: (f64, f64, f64),
        attack_ms: f64,
        release_ms: f64,
    ) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        self.band.hold = self.hold;
        self.band.attack = (-1.0 / ((attack_ms / 1000.0).max(0.0001) * self.fs)).exp();
        self.band.release = (-1.0 / ((release_ms / 1000.0).max(0.0001) * self.fs)).exp();
        let ramped = a != b;
        let mut s = 0;
        while s < n {
            let k = if ramped { ClipAudioFXChain::RAMP_CHUNK.min(n - s) } else { n };
            let t = s as f64 / n as f64;
            let l = |x: f64, y: f64| x + (y - x) * t;
            self.band.threshold = 10.0_f64.powf(l(a.0, b.0) / 20.0);
            self.band.slope = 1.0 - 1.0 / l(a.1, b.1).max(1.0);
            self.band.gain = GainMath::linear_from_db(l(a.2, b.2));
            for i in s..(s + k) {
                let mut peak = 0.0_f64;
                for c in buf.iter() {
                    peak = peak.max(f64::from(c[i].abs()));
                }
                let g = self.band.step(peak);
                for c in buf.iter_mut() {
                    c[i] = (f64::from(c[i]) * g) as f32;
                }
            }
            s += k;
        }
    }
}

struct DeEsserStage {
    d: DeEsser,
    was_off: bool,
    key: Vec<f64>,
}

impl DeEsserStage {
    fn new(sample_rate: i64, channels: usize) -> Self {
        DeEsserStage { d: DeEsser::new(sample_rate, channels), was_off: false, key: Vec::new() }
    }

    fn reset(&mut self) {
        self.d.reset();
    }

    /// Frequency, range and speed only touch the filters when they changed (the 7 kHz / Wide / Medium defaults are the init's).
    fn set_target(&mut self, frequency_hz: f64, range: i64, speed: i64, listen: bool) {
        self.d.listen = listen;
        let k = vec![frequency_hz, range as f64, speed as f64];
        if k == self.key {
            return;
        }
        if self.key.is_empty() && k == [7_000.0, 1.0, 1.0] {
            self.key = k;
            return;
        }
        if self.key.is_empty() || self.key[0] != k[0] || self.key[1] != k[1] {
            self.d.configure(frequency_hz, range);
        }
        if self.key.is_empty() || self.key[2] != k[2] {
            self.d.set_speed(speed);
        }
        self.key = k;
    }

    /// Reduction (dB) and sensitivity (0...1) move from `a` to `b` across the block (every `RAMP_CHUNK` samples).
    fn process(&mut self, buf: &mut [&mut [f32]], n: usize, a: (f64, f64), b: (f64, f64)) {
        if self.was_off {
            self.d.reset();
            self.was_off = false;
        }
        if a == b {
            self.set_gains(a);
            self.d.process(buf, n);
            return;
        }
        // shortcut: one Vec of channel views per block while the reduction ramps; upgrade by giving DeEsser an offset.
        let mut rest: Vec<&mut [f32]> = buf.iter_mut().map(|c| &mut c[..]).collect();
        let mut s = 0;
        while s < n {
            let k = ClipAudioFXChain::RAMP_CHUNK.min(n - s);
            let t = s as f64 / n as f64;
            self.set_gains((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t));
            self.d.process(&mut rest, k);
            for r in rest.iter_mut() {
                *r = &mut std::mem::take(r)[k..];
            }
            s += k;
        }
    }

    fn set_gains(&mut self, (red, sens): (f64, f64)) {
        self.d.min_gain = GainMath::linear_from_db(-red.abs());
        // Sensitivity 50 % = the voice chain's 0.35 (sibilance 9 dB under broadband); 100 % reacts at 0.1, 0 % at 0.6.
        self.d.ratio_threshold = 0.6 - 0.5 * sens.clamp(0.0, 1.0);
    }
}

/// Stereo-linked on channels 0 and 1 (mono: channel 0 alone); further channels pass.
struct LimiterStage {
    lim: MasterLimiter,
    mono: Vec<f32>,
    was_off: bool,
}

impl LimiterStage {
    fn new(sample_rate: i64, max_frames: usize) -> Self {
        LimiterStage { lim: MasterLimiter::new(sample_rate, -1.0), mono: vec![0.0; max_frames.max(1)], was_off: false }
    }

    fn reset(&mut self) {
        self.lim.reset();
    }

    /// The ceiling moves from `c0` to `c1` across the block (every `RAMP_CHUNK` samples).
    fn process(&mut self, buf: &mut [&mut [f32]], n: usize, c0: f64, c1: f64) {
        if self.was_off {
            self.lim.reset();
            self.was_off = false;
        }
        let mut s = 0;
        while s < n {
            let k = if c0 == c1 { n - s } else { ClipAudioFXChain::RAMP_CHUNK.min(n - s) };
            let c = c0 + (c1 - c0) * s as f64 / n as f64;
            if self.lim.ceiling_db != c {
                self.lim = self.lim.with_ceiling(c, 100.0, 0.0);
            }
            if buf.len() >= 2 {
                let (first, rest) = buf.split_at_mut(1);
                self.lim.process(&mut first[0][s..s + k], &mut rest[0][s..s + k]);
            } else {
                self.mono[..k].copy_from_slice(&buf[0][s..s + k]);
                self.lim.process(&mut buf[0][s..s + k], &mut self.mono[..k]);
            }
            s += k;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;
    use sq_core_time::Id;
    use std::sync::atomic::{AtomicU64, Ordering};

    // AUDIO-FX: the per-clip effect chain runs its stages in list order on deinterleaved stereo.

    fn slot(kind: &str) -> AudioFXSlot {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        AudioFXSlot { id: Id::from_u128(u128::from(NEXT.fetch_add(1, Ordering::Relaxed))), kind: kind.to_string() }
    }

    fn new_chain(layout: &[AudioFXSlot], channels: usize, max_frames: usize) -> ClipAudioFXChain {
        match ClipAudioFXChain::new(layout.to_vec(), channels, max_frames, None) {
            Ok(c) => c,
            Err(e) => panic!("chain: {e}"),
        }
    }

    fn peak(x: &[Vec<f32>], from: usize) -> f64 {
        x.iter().map(|c| c[from..].iter().fold(0.0_f64, |m, v| m.max(f64::from(v.abs())))).fold(0.0, f64::max)
    }

    fn db(g: f64) -> f64 {
        20.0 * g.log10()
    }

    fn run_with(
        layout: &[AudioFXSlot],
        stages: &[AudioFXStage],
        input: &[Vec<f32>],
        enabled: Option<&[bool]>,
        block: usize,
    ) -> Vec<Vec<f32>> {
        let mut chain = new_chain(layout, input.len(), block);
        let steps: Vec<AudioFXStep> = layout
            .iter()
            .zip(stages)
            .enumerate()
            .map(|(i, (s, st))| AudioFXStep { id: s.id, enabled: enabled.is_none_or(|e| e[i]), stage: st.clone() })
            .collect();
        let mut out = Vec::new();
        for mut part in sig::chunked(input, &[block]) {
            chain.process_vecs(&mut part, &steps, None);
            out.push(part);
        }
        sig::concat(&out, input.len())
    }

    fn run(layout: &[AudioFXSlot], stages: &[AudioFXStage], input: &[Vec<f32>]) -> Vec<Vec<f32>> {
        run_with(layout, stages, input, None, 1024)
    }

    fn eq_values(
        low_gain_db: f64,
        low_hz: f64,
        mid_gain_db: f64,
        mid_hz: f64,
        mid_q: f64,
        high_gain_db: f64,
        high_hz: f64,
    ) -> AudioEQValues {
        AudioEQValues { low_gain_db, low_hz, mid_gain_db, mid_hz, mid_q, high_gain_db, high_hz }
    }

    fn sine(f: f64, amp_db: f64, seconds: f64) -> Vec<Vec<f32>> {
        sig::sine(f, amp_db, seconds, 48000, 2, 0.0)
    }

    #[test]
    fn gain_scales_the_signal() {
        let x = sine(1000.0, -20.0, 0.1);
        let y = run(&[slot(AUDIO_GAIN_KIND)], &[AudioFXStage::Gain { db: 6.0 }], &x);
        assert!((db(peak(&y, 0)) - -14.0).abs() < 0.05);
    }

    #[test]
    fn order_matters_gain_then_limiter_versus_limiter_then_gain() {
        let x = sine(1000.0, -6.0, 0.2);
        let (g, l) = (slot(AUDIO_GAIN_KIND), slot(AUDIO_LIMITER_KIND));
        let limiter = AudioFXStage::Limiter { input_db: 0.0, ceiling_db: -6.0 };
        // +6 dB into a -6 dB ceiling: the limiter has the last word.
        let gain_first = run(&[g.clone(), l.clone()], &[AudioFXStage::Gain { db: 6.0 }, limiter.clone()], &x);
        // The limiter sees -6 dB (nothing to do), then +6 dB: 0 dBFS.
        let limiter_first = run(&[l, g], &[limiter, AudioFXStage::Gain { db: 6.0 }], &x);
        assert!(db(peak(&gain_first, 4800)) <= -6.0 + 0.01);
        assert!(db(peak(&limiter_first, 4800)).abs() < 0.1);
    }

    #[test]
    fn disabled_stages_pass_through() {
        let x = sine(440.0, -12.0, 0.05);
        let y = run_with(&[slot(AUDIO_GAIN_KIND)], &[AudioFXStage::Gain { db: -40.0 }], &x, Some(&[false]), 1024);
        assert_eq!(y, x);
    }

    #[test]
    fn eq_boosts_the_mid_band_and_leaves_far_frequencies() {
        let eq = eq_values(0.0, 100.0, 12.0, 1000.0, 1.0, 0.0, 8000.0);
        let layout = [slot(AUDIO_EQ_KIND)];
        let at_1k = run(&layout, &[AudioFXStage::Eq(eq)], &sine(1000.0, -30.0, 0.5));
        let at_50 = run(&layout, &[AudioFXStage::Eq(eq)], &sine(50.0, -30.0, 0.5));
        assert!((db(sig::amplitude(&at_1k[0][12000..24000], 1000.0, 48000)) - -18.0).abs() < 0.3);
        assert!((db(sig::amplitude(&at_50[0][12000..24000], 50.0, 48000)) - -30.0).abs() < 0.5);
    }

    #[test]
    fn shelves_act_on_their_side() {
        let eq = eq_values(-12.0, 200.0, 0.0, 1000.0, 1.0, 6.0, 4000.0);
        let layout = [slot(AUDIO_EQ_KIND)];
        let low = run(&layout, &[AudioFXStage::Eq(eq)], &sine(50.0, -20.0, 0.5));
        let high = run(&layout, &[AudioFXStage::Eq(eq)], &sine(15000.0, -20.0, 0.5));
        assert!((db(sig::amplitude(&low[0][12000..24000], 50.0, 48000)) - -32.0).abs() < 0.5);
        assert!((db(sig::amplitude(&high[0][12000..24000], 15000.0, 48000)) - -14.0).abs() < 0.5);
    }

    #[test]
    fn compressor_reduces_loud_parts_only() {
        let c = AudioFXStage::Compressor {
            threshold_db: -20.0,
            ratio: 4.0,
            attack_ms: 1.0,
            release_ms: 50.0,
            makeup_db: 0.0,
        };
        let layout = [slot(AUDIO_COMPRESSOR_KIND)];
        let loud = run(&layout, std::slice::from_ref(&c), &sine(1000.0, -4.0, 0.5));
        let quiet = run(&layout, &[c], &sine(1000.0, -30.0, 0.5));
        // 16 dB over the threshold at 4:1 leaves 4 dB over: about -16 dBFS.
        assert!((db(peak(&loud, 12000)) - -16.0).abs() < 1.0);
        assert!((db(peak(&quiet, 12000)) - -30.0).abs() < 0.05);
    }

    #[test]
    fn noise_reduction_adds_the_denoiser_latency() {
        let with_nr = new_chain(&[slot(AUDIO_NOISE_REDUCTION_KIND), slot(AUDIO_GAIN_KIND)], 2, 512);
        let without = new_chain(&[slot(AUDIO_GAIN_KIND)], 2, 512);
        assert_eq!(with_nr.latency_samples, 480);
        assert_eq!(without.latency_samples, 0);
    }

    fn rms_db(x: &[f32]) -> f64 {
        20.0 * sig::rms(x).max(1e-9).log10()
    }

    /// Strength 100 % is a bounded reduction (32 dB below 2 kHz, 16 dB to 4 kHz, 8 dB above), never RNNoise's full rebuild: the old wet/dry
    /// mix went to -infinity at 100 % and muffled the voice.
    #[test]
    fn noise_reduction_at_full_strength_is_bounded() {
        let n = 48_000 * 2;
        let layout = [slot(AUDIO_NOISE_REDUCTION_KIND)];
        let stage = [AudioFXStage::NoiseReduction { amount: 1.0 }];
        let low = vec![sig::low_noise(0.05, n, 3)];
        let high = vec![sig::noise(0.05, n, 4)];
        for (x, floor_db) in [(low, -32.0), (high, -9.0)] {
            let y = run_with(&layout, &stage, &x, None, 480);
            let (i, o) = (rms_db(&x[0][48_000..n - 480]), rms_db(&y[0][48_000 + 480..n]));
            assert!(o < i - 0.5, "reduces: in {i} out {o}");
            assert!(o > i + floor_db - 1.5, "bounded: in {i} out {o}");
        }
    }

    #[test]
    fn noise_reduction_floors_follow_strength() {
        let db = |g: f32| 20.0 * g.log10();
        assert_eq!(denoise_floors(0.0)[..3], [1.0, 1.0, 1.0]);
        let f = denoise_floors(1.0);
        assert!((db(f[0]) + 32.0).abs() < 1e-3 && (db(f[1]) + 16.0).abs() < 1e-3 && (db(f[2]) + 8.0).abs() < 1e-3);
        // Premiere's 40 % (calibration point): 12.8 dB below 2 kHz, 6.4 dB to 4 kHz, 3.2 dB above.
        let f = denoise_floors(0.4);
        assert!((db(f[0]) + 12.8).abs() < 1e-3 && (db(f[1]) + 6.4).abs() < 1e-3 && (db(f[2]) + 3.2).abs() < 1e-3);
        // the default 5 % stays a whisper
        let f5 = denoise_floors(0.05);
        assert!(db(f5[0]) > -1.7 && db(f5[2]) > -0.5);
    }

    /// Speech frames keep more of the signal than pauses: a loud 200 Hz tone (RNNoise's speech detector) is not pushed to the
    /// pause floor.
    #[test]
    fn noise_reduction_floor_relaxes_for_speech() {
        let f = denoise_floors(1.0);
        assert!(f[3] > 0.0 && f[3] <= 1.0);
        // powf(floor, 1 - relax * vad) as in denoise.c
        let speech = f[0].powf(1.0 - f[3]);
        assert!(speech > f[0] && 20.0 * speech.log10() > -8.0);
    }

    #[test]
    fn noise_reduction_at_zero_strength_is_the_delayed_dry_signal() {
        let x = vec![sig::noise(0.1, 4800, 1), sig::noise(0.1, 4800, 2)];
        let y = run_with(
            &[slot(AUDIO_NOISE_REDUCTION_KIND)],
            &[AudioFXStage::NoiseReduction { amount: 0.0 }],
            &x,
            None,
            480,
        );
        for c in 0..2 {
            assert_eq!(y[c][480..], x[c][..4800 - 480]);
        }
    }

    #[test]
    fn switched_off_noise_reduction_is_a_delayed_dry_path() {
        let x = vec![sig::noise(0.1, 4800, 1), sig::noise(0.1, 4800, 2)];
        let y = run_with(
            &[slot(AUDIO_NOISE_REDUCTION_KIND)],
            &[AudioFXStage::NoiseReduction { amount: 0.8 }],
            &x,
            Some(&[false]),
            480,
        );
        for c in 0..2 {
            assert_eq!(y[c][480..], x[c][..4800 - 480]);
        }
    }

    #[test]
    fn block_size_does_not_change_the_result() {
        let layout =
            [slot(AUDIO_EQ_KIND), slot(AUDIO_COMPRESSOR_KIND), slot(AUDIO_DE_ESSER_KIND), slot(AUDIO_LIMITER_KIND)];
        let stages = [
            AudioFXStage::Eq(eq_values(3.0, 120.0, -4.0, 900.0, 2.0, 2.0, 6000.0)),
            AudioFXStage::Compressor {
                threshold_db: -24.0,
                ratio: 3.0,
                attack_ms: 5.0,
                release_ms: 80.0,
                makeup_db: 3.0,
            },
            AudioFXStage::DeEsser {
                reduction_db: 8.0,
                sensitivity: 0.5,
                frequency_hz: 7_000.0,
                range: 1,
                speed: 1,
                listen: false,
            },
            AudioFXStage::Limiter { input_db: 3.0, ceiling_db: -2.0 },
        ];
        let x = vec![sig::noise(0.5, 9600, 1), sig::noise(0.5, 9600, 7)];
        let a = run_with(&layout, &stages, &x, None, 1024);
        let b = run_with(&layout, &stages, &x, None, 256);
        assert_eq!(a, b);
    }

    #[test]
    fn reset_forgets_the_state() {
        let s = slot(AUDIO_COMPRESSOR_KIND);
        let mut chain = new_chain(std::slice::from_ref(&s), 2, 4800);
        let step = [AudioFXStep {
            id: s.id,
            enabled: true,
            stage: AudioFXStage::Compressor {
                threshold_db: -30.0,
                ratio: 10.0,
                attack_ms: 1.0,
                release_ms: 1000.0,
                makeup_db: 0.0,
            },
        }];
        let x = sine(1000.0, -6.0, 0.1);
        let mut first = x.clone();
        chain.process_vecs(&mut first, &step, None);
        chain.reset();
        let mut second = x;
        chain.process_vecs(&mut second, &step, None);
        assert_eq!(first, second);
    }

    #[test]
    fn gain_ramps_across_the_block_to_the_end_value() {
        let s = slot(AUDIO_GAIN_KIND);
        let mut chain = new_chain(std::slice::from_ref(&s), 1, 1000);
        let mut x = vec![vec![1.0_f32; 1000]];
        let gain = |db: f64| [AudioFXStep { id: s.id, enabled: true, stage: AudioFXStage::Gain { db } }];
        chain.process_vecs(&mut x, &gain(0.0), Some(&gain(-120.0)));
        assert!((x[0][0] - 1.0).abs() < 1e-6);
        assert!(x[0][999] < 0.01);
        assert!(x[0][500] < x[0][100]);
    }

    #[test]
    fn de_esser_reduction_ramps_across_the_block() {
        let s = slot(AUDIO_DE_ESSER_KIND);
        let mut chain = new_chain(std::slice::from_ref(&s), 1, 9600);
        let mut x = sig::sine(8000.0, -12.0, 0.2, 48000, 1, 0.0);
        let de_ess = |reduction_db: f64| {
            [AudioFXStep {
                id: s.id,
                enabled: true,
                stage: AudioFXStage::DeEsser {
                    reduction_db,
                    sensitivity: 1.0,
                    frequency_hz: 7_000.0,
                    range: 1,
                    speed: 1,
                    listen: false,
                },
            }]
        };
        chain.process_vecs(&mut x, &de_ess(0.0), Some(&de_ess(20.0)));
        let pk = |r: std::ops::Range<usize>| x[0][r].iter().fold(0.0_f32, |m, v| m.max(v.abs()));
        assert!(pk(2000..2500) > 0.1); // early: reduction still small
        assert!(pk(9000..9600) < pk(2000..2500) * 0.6);
    }

    #[test]
    fn eq_band_returning_to_zero_db_does_not_click() {
        let s = slot(AUDIO_EQ_KIND);
        let mut chain = new_chain(std::slice::from_ref(&s), 1, 480);
        let v = |g: f64| eq_values(g, 200.0, 0.0, 1000.0, 1.0, 0.0, 8000.0);
        let step = |g: f64| [AudioFXStep { id: s.id, enabled: true, stage: AudioFXStage::Eq(v(g)) }];
        let x = sig::sine(100.0, -12.0, 0.1, 48000, 1, 0.0);
        let mut out: Vec<f32> = Vec::new();
        // 12 dB low shelf ramping to 0 dB over one block, then staying at 0 dB.
        let gains = [(12.0, 12.0), (12.0, 12.0), (12.0, 0.0), (0.0, 0.0), (0.0, 0.0)];
        for (i, g) in gains.iter().enumerate() {
            let mut b = vec![x[0][i * 480..(i + 1) * 480].to_vec()];
            chain.process_vecs(&mut b, &step(g.0), Some(&step(g.1)));
            out.extend_from_slice(&b[0]);
        }
        // Largest sample-to-sample step stays near the sine's own slope (no jump at a block edge).
        let slope = (0..out.len() - 1).map(|i| (x[0][i + 1] - x[0][i]).abs()).fold(0.0_f32, f32::max);
        let jumps = (0..out.len() - 1).map(|i| (out[i + 1] - out[i]).abs()).fold(0.0_f32, f32::max);
        assert!(jumps < slope * 4.5);
        // Back at 0 dB the band is the identity: the last block is the input (to float rounding).
        for i in 2000..2400 {
            assert!((out[i] - x[0][i]).abs() < 1e-4);
        }
    }

    #[test]
    fn limiter_ceiling_ramps_across_the_block() {
        let s = slot(AUDIO_LIMITER_KIND);
        let mut chain = new_chain(std::slice::from_ref(&s), 1, 4800);
        let mut x = sig::sine(1000.0, 0.0, 0.1, 48000, 1, 0.0);
        let limiter = |ceiling_db: f64| {
            [AudioFXStep { id: s.id, enabled: true, stage: AudioFXStage::Limiter { input_db: 0.0, ceiling_db } }]
        };
        chain.process_vecs(&mut x, &limiter(-1.0), Some(&limiter(-13.0)));
        // Early part near -1 dB, the end near -13 dB: the ceiling moved inside the block, not in one step.
        let pk = |r: std::ops::Range<usize>| db(peak(&[x[0][r].to_vec()], 0));
        assert!(pk(300..900) > -3.0);
        assert!(pk(4600..4800) < -11.0);
        assert!(pk(2200..2600) < -4.0 && pk(2200..2600) > -10.0);
    }

    // Privacy: a stage without its step never passes the voice dry.
    #[test]
    fn missing_or_mismatched_step_silences_the_block() {
        let (a, b) = (slot(AUDIO_GAIN_KIND), slot(AUDIO_DISGUISE_VOICE_KIND));
        let mut chain = new_chain(&[a.clone(), b], 2, 1024);
        let gain0 = |id| AudioFXStep { id, enabled: true, stage: AudioFXStage::Gain { db: 0.0 } };
        let mut x = sine(440.0, -12.0, 0.02);
        chain.process_vecs(&mut x, &[gain0(a.id)], None);
        assert_eq!(peak(&x, 0), 0.0);
        let mut y = sine(440.0, -12.0, 0.02);
        chain.process_vecs(&mut y, &[gain0(a.id), gain0(Id::from_u128(9_999))], None);
        assert_eq!(peak(&y, 0), 0.0);
    }

    #[test]
    fn switched_off_effects_still_pass_dry() {
        let a = slot(AUDIO_GAIN_KIND);
        let mut chain = new_chain(std::slice::from_ref(&a), 2, 1024);
        let mut x = sine(440.0, -12.0, 0.02);
        let before = peak(&x, 0);
        chain.process_vecs(
            &mut x,
            &[AudioFXStep { id: a.id, enabled: false, stage: AudioFXStage::Gain { db: 12.0 } }],
            None,
        );
        assert_eq!(peak(&x, 0), before);
    }

    // CreatorStagesTests

    fn run_one(kind: &str, stage: AudioFXStage, x: &[Vec<f32>], enabled: bool, chunks: &[usize]) -> Vec<Vec<f32>> {
        let s = slot(kind);
        let mut chain = new_chain(std::slice::from_ref(&s), x.len(), 480);
        let mut out = Vec::new();
        for mut part in sig::chunked(x, chunks) {
            chain.process_vecs(&mut part, &[AudioFXStep { id: s.id, enabled, stage: stage.clone() }], None);
            out.push(part);
        }
        sig::concat(&out, x.len())
    }

    fn gain_db(y: &[f32], x: &[f32]) -> f64 {
        sig::db(sig::rms(&y[24000..]) / sig::rms(&x[24000..]))
    }

    #[test]
    fn high_cut_slopes() {
        let g = |f: f64, order: i64| {
            let x = sine(f, -20.0, 1.0);
            gain_db(
                &run_one(AUDIO_HIGH_CUT_KIND, AudioFXStage::HighCut { frequency_hz: 4000.0, order }, &x, true, &[480])
                    [0],
                &x[0],
            )
        };
        assert!((g(4000.0, 2) + 3.0).abs() < 0.7);
        assert!(g(200.0, 2).abs() < 0.1);
        let (o1, o2, o3) = (g(16000.0, 1), g(16000.0, 2), g(16000.0, 3));
        assert!(o1 < -8.0 && o2 < o1 - 8.0 && o3 < o2 - 15.0, "{o1} {o2} {o3}");
        let x = sine(12000.0, -20.0, 0.2);
        assert_eq!(
            run_one(AUDIO_HIGH_CUT_KIND, AudioFXStage::HighCut { frequency_hz: 2000.0, order: 3 }, &x, false, &[480]),
            x
        );
    }

    #[test]
    fn stereo_width_scales_the_side_signal() {
        let l = sine(440.0, -12.0, 1.0).swap_remove(0);
        let r = sig::sine(440.0, -12.0, 1.0, 48000, 1, 1.0).swap_remove(0);
        let x = vec![l.clone(), r.clone()];
        let width = |w: f64| AudioFXStage::StereoWidth { width: w };
        // Width 100 % is transparent.
        let same = run_one(AUDIO_STEREO_WIDTH_KIND, width(1.0), &x, true, &[480]);
        for i in (0..l.len()).step_by(997) {
            assert!((same[0][i] - l[i]).abs() < 1e-5 && (same[1][i] - r[i]).abs() < 1e-5);
        }
        // Width 0 = mono: both channels carry the mid.
        let mono = run_one(AUDIO_STEREO_WIDTH_KIND, width(0.0), &x, true, &[480]);
        for i in (0..l.len()).step_by(997) {
            assert!((mono[0][i] - (l[i] + r[i]) / 2.0).abs() < 1e-5 && mono[0][i] == mono[1][i]);
        }
        // Width 200 %: side doubled, mid kept.
        let wide = run_one(AUDIO_STEREO_WIDTH_KIND, width(2.0), &x, true, &[480]);
        for i in (0..l.len()).step_by(997) {
            let (m, s) = ((l[i] + r[i]) / 2.0, (l[i] - r[i]) / 2.0);
            assert!((wide[0][i] - (m + 2.0 * s)).abs() < 1e-5 && (wide[1][i] - (m - 2.0 * s)).abs() < 1e-5);
        }
        // A mono source (one channel) passes unchanged.
        assert_eq!(run_one(AUDIO_STEREO_WIDTH_KIND, width(0.0), std::slice::from_ref(&l), true, &[480]), vec![l]);
        assert_eq!(run_one(AUDIO_STEREO_WIDTH_KIND, width(0.0), &x, false, &[480]), x);
    }

    #[test]
    fn chorus_mixes_a_modulated_copy_and_is_chunk_independent() {
        let x = sine(1000.0, -12.0, 1.0);
        let stage = AudioFXStage::Chorus { rate_hz: 1.0, depth_ms: 4.0, mix: 0.5 };
        let a = run_one(AUDIO_CHORUS_KIND, stage.clone(), &x, true, &[480]);
        let b = run_one(AUDIO_CHORUS_KIND, stage.clone(), &x, true, &[37, 480, 101]);
        for i in (0..x[0].len()).step_by(331) {
            assert!((a[0][i] - b[0][i]).abs() < 1e-5);
        }
        // The wet copy differs from the dry sound, and the output stays bounded.
        assert!(a[0].iter().zip(&x[0]).any(|(p, q)| (p - q).abs() > 0.05));
        assert!(a[0].iter().all(|v| v.abs() <= 1.0));
        // Mix 0 is the dry sound exactly.
        assert_eq!(
            run_one(
                AUDIO_CHORUS_KIND,
                AudioFXStage::Chorus { rate_hz: 1.0, depth_ms: 4.0, mix: 0.0 },
                &x,
                true,
                &[480]
            ),
            x
        );
        assert_eq!(run_one(AUDIO_CHORUS_KIND, stage, &x, false, &[480]), x);
    }

    // DeEsserDeReverbTests: De-Esser controls

    /// Runs one effect over `input` in 1024-frame blocks (mono) and returns the output and the chain latency.
    fn run_mono(kind: &str, stage: AudioFXStage, input: &[f32], enabled: bool) -> (Vec<f32>, usize) {
        let s = slot(kind);
        let mut chain = new_chain(std::slice::from_ref(&s), 1, 1024);
        let step = [AudioFXStep { id: s.id, enabled, stage }];
        let mut out = Vec::new();
        for part in input.chunks(1024) {
            let mut b = vec![part.to_vec()];
            chain.process_vecs(&mut b, &step, None);
            out.extend_from_slice(&b[0]);
        }
        (out, chain.latency_samples)
    }

    fn de_ess(
        reduction_db: f64,
        sensitivity: f64,
        frequency_hz: f64,
        range: i64,
        speed: i64,
        listen: bool,
    ) -> AudioFXStage {
        AudioFXStage::DeEsser { reduction_db, sensitivity, frequency_hz, range, speed, listen }
    }

    /// Mixed signal: a 300 Hz voice body plus a burst of sibilance at `hz`.
    fn voice(sibilant_hz: f64) -> Vec<f32> {
        let pi = std::f64::consts::PI;
        (0..48_000)
            .map(|i| {
                let t = f64::from(i) / 48_000.0;
                let body = 0.25 * (2.0 * pi * 300.0 * t).sin();
                let burst = if t > 0.3 && t < 0.7 { 0.3 * (2.0 * pi * sibilant_hz * t).sin() } else { 0.0 };
                (body + burst) as f32
            })
            .collect()
    }

    fn burst_rms(x: &[f32]) -> f64 {
        sig::rms(&x[19_200..33_600]) // 0.4 s...0.7 s
    }

    #[test]
    fn de_esser_frequency_moves_the_target() {
        let x = voice(4_000.0);
        let at_7k = run_mono(AUDIO_DE_ESSER_KIND, de_ess(16.0, 0.8, 7_000.0, 1, 1, false), &x, true).0;
        let at_4k = run_mono(AUDIO_DE_ESSER_KIND, de_ess(16.0, 0.8, 4_000.0, 1, 1, false), &x, true).0;
        // Targeting the real sibilance reduces it clearly more than aiming at 7 kHz.
        assert!(burst_rms(&at_4k) < burst_rms(&at_7k) * 0.8);
    }

    #[test]
    fn de_esser_narrow_leaves_the_rest_of_the_highs_alone() {
        // Sibilance at 7 kHz plus an 11 kHz tone: Narrow keeps the 11 kHz, All HF takes it down too.
        let pi = std::f64::consts::PI;
        let x: Vec<f32> = (0..48_000)
            .map(|i| {
                let t = f64::from(i) / 48_000.0;
                let s = if t > 0.3 && t < 0.7 { 0.3 * (2.0 * pi * 7_000.0 * t).sin() } else { 0.0 };
                (0.25 * (2.0 * pi * 300.0 * t).sin() + s + 0.15 * (2.0 * pi * 11_000.0 * t).sin()) as f32
            })
            .collect();
        let high = |y: &[f32]| {
            // 11 kHz level via a one-bin DFT over the burst
            let (mut re, mut im) = (0.0_f64, 0.0_f64);
            for (i, v) in y.iter().enumerate().take(33_600).skip(19_200) {
                let p = 2.0 * pi * 11_000.0 * i as f64 / 48_000.0;
                re += f64::from(*v) * p.cos();
                im += f64::from(*v) * p.sin();
            }
            re.hypot(im) / 14_400.0
        };
        let narrow = run_mono(AUDIO_DE_ESSER_KIND, de_ess(20.0, 0.9, 7_000.0, 0, 1, false), &x, true).0;
        let all = run_mono(AUDIO_DE_ESSER_KIND, de_ess(20.0, 0.9, 7_000.0, 2, 1, false), &x, true).0;
        assert!(high(&narrow) > high(&all) * 1.3);
    }

    #[test]
    fn de_esser_listen_plays_only_the_removed_ess() {
        let x = voice(7_000.0);
        let heard = run_mono(AUDIO_DE_ESSER_KIND, de_ess(12.0, 0.8, 7_000.0, 1, 1, true), &x, true).0;
        // The 300 Hz body is not in it; the sibilance burst is.
        assert!(sig::rms(&heard[2_000..9_000]) < 0.01);
        assert!(sig::rms(&heard[22_000..30_000]) > 0.02);
    }

    #[test]
    fn de_esser_speed_changes_how_fast_it_lets_go() {
        // A short ess: slow release keeps the reduction longer after it ends than fast.
        let pi = std::f64::consts::PI;
        let x: Vec<f32> = (0..24_000)
            .map(|i| {
                let t = f64::from(i) / 48_000.0;
                (0.2 * (2.0 * pi * 300.0 * t).sin()
                    + if t > 0.1 && t < 0.2 { 0.3 * (2.0 * pi * 7_000.0 * t).sin() } else { 0.0 })
                    as f32
            })
            .collect();
        let tail = |speed: i64| {
            sig::rms(
                &run_mono(AUDIO_DE_ESSER_KIND, de_ess(20.0, 0.9, 7_000.0, 1, speed, false), &x, true).0[9_700..10_500],
            )
        };
        assert!(tail(0) != tail(2));
    }

    // DeEsserDeReverbTests: De-Reverb

    /// A "dry" noise burst of `burst` seconds followed by an exponentially decaying noise tail (RT60 `rt60`), the tail starting
    /// at `tail_start` x the burst level. Returns the signal and the sample where the burst ends.
    fn burst_and_tail(burst: f64, rt60: f64) -> (Vec<f32>, usize) {
        let (tail_start, total) = (0.3, 1.6);
        let n = (total * 48_000.0) as usize;
        let b = (burst * 48_000.0) as usize;
        let noise = sig::noise(0.3, n, 7);
        let out = (0..n)
            .map(|i| {
                if i < b {
                    return noise[i];
                }
                let t = (i - b) as f64 / 48_000.0;
                noise[i] * (tail_start * (-6.9078 * t / rt60).exp()) as f32
            })
            .collect();
        (out, b)
    }

    fn de_reverb(amount: f64, tone: f64) -> AudioFXStage {
        AudioFXStage::DeReverb { amount, decay_seconds: 0.6, tone }
    }

    fn rms_ratio_db(a: f64, b: f64) -> f64 {
        20.0 * (a.max(1e-12) / b.max(1e-12)).log10()
    }

    #[test]
    fn de_reverb_declares_its_delay_and_passes_audio_delayed_at_zero_amount() {
        let x = sig::noise(0.3, 12_000, 3);
        let (out, latency) = run_mono(AUDIO_DE_REVERB_KIND, de_reverb(0.0, 0.0), &x, true);
        assert_eq!(latency as i64, AudioDeReverbValues::LATENCY_SAMPLES);
        let d = latency;
        let mut worst: f32 = 0.0;
        for i in 0..x.len() - d {
            worst = worst.max((out[i + d] - x[i]).abs());
        }
        assert!(worst < 1e-4);
        // The delay holds while the effect is switched off.
        let (off, _) = run_mono(AUDIO_DE_REVERB_KIND, de_reverb(1.0, 0.0), &x, false);
        for i in 0..x.len() - d {
            worst = worst.max((off[i + d] - x[i]).abs());
        }
        assert!(worst < 1e-4);
    }

    #[test]
    fn de_reverb_reduces_a_late_reverb_tail() {
        let (x, end) = burst_and_tail(0.4, 0.6);
        let (out, d) = run_mono(AUDIO_DE_REVERB_KIND, de_reverb(0.8, 0.0), &x, true);
        // The tail 150...450 ms after the dry sound, input against output (output delayed by `d`).
        let (a, b) = (end + 7_200, end + 21_600);
        let reduction = rms_ratio_db(sig::rms(&x[a..b]), sig::rms(&out[a + d..b + d]));
        assert!(reduction > 6.0, "tail reduced by {reduction} dB");
    }

    #[test]
    fn de_reverb_more_amount_reduces_more() {
        let (x, end) = burst_and_tail(0.4, 0.6);
        let lvl = |amount: f64| {
            let (out, d) = run_mono(AUDIO_DE_REVERB_KIND, de_reverb(amount, 0.0), &x, true);
            sig::rms(&out[end + 7_200 + d..end + 21_600 + d])
        };
        assert!(lvl(0.9) < lvl(0.3));
    }

    /// Speech-like: 4 Hz syllables of a harmonic voice (150 Hz + harmonics) with pauses, no reverb at all.
    fn speech_like(seconds: f64) -> Vec<f32> {
        let pi = std::f64::consts::PI;
        (0..(seconds * 48_000.0) as usize)
            .map(|i| {
                let t = i as f64 / 48_000.0;
                let syl = (2.0 * pi * 2.5 * t).sin().max(0.0);
                let env = syl.powf(0.5);
                let v: f64 = (1..=12).map(|h| (2.0 * pi * 150.0 * f64::from(h) * t).sin() / f64::from(h)).sum();
                (0.15 * env * v) as f32
            })
            .collect()
    }

    #[test]
    fn de_reverb_leaves_dry_speech_like_signal_alone() {
        let x = speech_like(3.0);
        let (out, d) = run_mono(AUDIO_DE_REVERB_KIND, de_reverb(0.5, 0.0), &x, true);
        // Level of the voiced cores (envelope above 0.7), input against delayed output: within 1.5 dB.
        let (mut sum_in, mut sum_out, mut count) = (0.0, 0.0, 0.0);
        for i in 24_000..x.len() - d {
            let t = i as f64 / 48_000.0;
            if (2.0 * std::f64::consts::PI * 2.5 * t).sin() > 0.7 {
                sum_in += f64::from(x[i]) * f64::from(x[i]);
                sum_out += f64::from(out[i + d]) * f64::from(out[i + d]);
                count += 1.0;
            }
        }
        let loss = rms_ratio_db((sum_in / count).sqrt(), (sum_out / count).sqrt());
        assert!(loss < 1.5, "voiced cores lost {loss} dB");
    }

    #[test]
    fn de_reverb_tone_shifts_the_reduction_between_lows_and_highs() {
        let (x, end) = burst_and_tail(0.4, 0.6);
        let lvl = |tone: f64| {
            let (out, d) = run_mono(AUDIO_DE_REVERB_KIND, de_reverb(0.6, tone), &x, true);
            sig::rms(&out[end + 7_200 + d..end + 21_600 + d])
        };
        assert!(lvl(-1.0) != lvl(1.0));
    }

    // AudioSpectrumTests: the tap in a chain

    fn tap_chain(kind: &str, tap: &Arc<AudioSpectrumTap>) -> (ClipAudioFXChain, AudioFXSlot) {
        let s = slot(kind);
        match ClipAudioFXChain::new(vec![s.clone()], 2, 1_024, Some(Arc::clone(tap))) {
            Ok(c) => (c, s),
            Err(e) => panic!("chain: {e}"),
        }
    }

    #[test]
    fn nothing_is_published_unless_watched_by_a_chain() {
        let tap = Arc::new(AudioSpectrumTap::new());
        let (mut c, s) = tap_chain(AUDIO_GAIN_KIND, &tap);
        let mut b = sine(1_000.0, -20.0, 0.02);
        let step = [AudioFXStep { id: s.id, enabled: true, stage: AudioFXStage::Gain { db: -20.0 } }];
        c.process_vecs(&mut b, &step, None);
        assert_eq!(tap.sequence(), 0);
        let mut out = Vec::new();
        assert_eq!(tap.snapshot(s.id, &mut out), None);
        tap.watch(Some(Id::from_u128(777)), false); // another effect
        c.process_vecs(&mut b, &step, None);
        assert_eq!(tap.sequence(), 0);
    }

    #[test]
    fn input_and_output_taps_see_before_and_after_the_effect() {
        let tap = Arc::new(AudioSpectrumTap::new());
        let (mut c, s) = tap_chain(AUDIO_GAIN_KIND, &tap);
        let x = sine(1_000.0, -20.0, 0.2);
        let step = [AudioFXStep { id: s.id, enabled: true, stage: AudioFXStage::Gain { db: -20.0 } }];
        let feed = |c: &mut ClipAudioFXChain| {
            for mut part in sig::chunked(&x, &[512]) {
                c.process_vecs(&mut part, &step, None);
            }
        };
        let mut out = Vec::new();
        tap.watch(Some(s.id), true);
        feed(&mut c);
        assert!(tap.sequence() > 0);
        assert!(tap.snapshot(s.id, &mut out).is_some());
        assert_eq!(out.len(), crate::audio_spectrum::SpectrumAnalyzer::SIZE);
        let rin = sig::rms(&out);
        tap.watch(Some(s.id), false);
        feed(&mut c);
        let _ = tap.snapshot(s.id, &mut out);
        let rout = sig::rms(&out);
        assert!((sig::db(rin) - -23.0).abs() < 0.5, "input {}", sig::db(rin)); // -20 dB peak sine = -23 dB RMS
        assert!((sig::db(rout) - sig::db(rin) + 20.0).abs() < 0.5, "output {}", sig::db(rout));
    }

    // VoiceChainFXTests: Multiband Compressor as a clip chain stage.

    fn mb(thr: f64, ratio: f64, out: f64, gain: f64) -> AudioMultibandValues {
        AudioMultibandValues {
            output_gain_db: out,
            crossover_hz: [120.0, 700.0, 3000.0],
            threshold_db: [thr; 4],
            ratio: [ratio; 4],
            attack_ms: [1.0; 4],
            release_ms: [50.0; 4],
            gain_db: [gain; 4],
            limiter_on: false,
            limiter_threshold_db: -10.0,
            limiter_margin_db: -0.1,
            limiter_release_ms: 500.0,
            limiter_attack_ms: 0.0,
            band_solo: 0,
            band_bypass: 0,
        }
    }

    fn run_mb(v: AudioMultibandValues, input: &[Vec<f32>], enabled: bool, block: usize) -> Vec<Vec<f32>> {
        run_with(&[slot(AUDIO_MULTIBAND_KIND)], &[AudioFXStage::Multiband(v)], input, Some(&[enabled]), block)
    }

    fn tail_peak(y: &[Vec<f32>]) -> f64 {
        y[0][24000..].iter().fold(0.0_f64, |m, v| m.max(f64::from(v.abs())))
    }

    #[test]
    fn multiband_reduces_above_threshold_only() {
        // 1.45 kHz is the middle of band 3. 24 dB over a -30 dB threshold at 4:1 leaves 6 dB over: about -24 dBFS ideal; the peak
        // detector ripple of a sine leaves a bit less).
        let loud = run_mb(mb(-30.0, 4.0, 0.0, 0.0), &sine(1450.0, -6.0, 1.0), true, 1024);
        let g = db(tail_peak(&loud));
        assert!(g < -17.0 && g > -26.0); // 13...20 dB of reduction (18 dB ideal; ripple and skirts)
        let quiet = run_mb(mb(-30.0, 4.0, 0.0, 0.0), &sine(1450.0, -50.0, 1.0), true, 1024);
        assert!((db(tail_peak(&quiet)) - -50.0).abs() < 0.3);
    }

    #[test]
    fn multiband_output_and_band_gain_apply() {
        let x = sine(1450.0, -20.0, 0.6);
        let out = run_mb(mb(0.0, 1.0, 6.0, 0.0), &x, true, 1024);
        assert!((db(tail_peak(&out)) - -14.0).abs() < 0.2);
        let mut v = mb(0.0, 1.0, 0.0, 0.0);
        v.gain_db = [0.0, 0.0, -6.0, 0.0]; // band 3 holds 1.45 kHz
        let band = run_mb(v, &x, true, 1024);
        assert!(db(tail_peak(&band)) < -23.0 && db(tail_peak(&band)) > -26.5);
    }

    #[test]
    fn multiband_bands_compress_independently() {
        // Only band 1 (below 120 Hz) compresses: 1 kHz stays, 60 Hz drops.
        let mut v = mb(0.0, 1.0, 0.0, 0.0);
        v.threshold_db = [-40.0, 0.0, 0.0, 0.0];
        v.ratio = [8.0, 1.0, 1.0, 1.0];
        let hi = run_mb(v, &sine(1000.0, -10.0, 1.0), true, 1024);
        let lo = run_mb(v, &sine(60.0, -10.0, 1.0), true, 1024);
        assert!((db(tail_peak(&hi)) - -10.0).abs() < 0.5);
        assert!(db(tail_peak(&lo)) < -22.0);
    }

    #[test]
    fn disabled_multiband_passes_through_and_block_size_does_not_matter() {
        let x = sine(800.0, -6.0, 0.3);
        // Disabled: unchanged, only delayed by the stage's fixed look-ahead latency (the chain's caller reads ahead by it).
        let off = run_mb(mb(-40.0, 8.0, 0.0, 0.0), &x, false, 1024);
        let l = MultibandStage::LATENCY;
        assert!(off[0][..l].iter().all(|&v| v == 0.0));
        assert_eq!(off[0][l..], x[0][..x[0].len() - l]);
        let a = run_mb(mb(-30.0, 4.0, 0.0, 0.0), &x, true, 1024);
        let b = run_mb(mb(-30.0, 4.0, 0.0, 0.0), &x, true, 256);
        for i in 0..a[0].len() {
            assert!((a[0][i] - b[0][i]).abs() < 1e-6);
        }
    }

    #[test]
    fn limiter_off_keeps_the_old_output() {
        let x = sine(800.0, -6.0, 0.3);
        let mut a = mb(-30.0, 4.0, 0.0, 0.0);
        a.limiter_threshold_db = -20.0; // values are ignored while the limiter is off
        assert_eq!(run_mb(a, &x, true, 1024), run_mb(mb(-30.0, 4.0, 0.0, 0.0), &x, true, 1024));
    }

    #[test]
    fn bypassed_band_passes_uncompressed_and_without_its_gain() {
        // Band 3 holds 1.45 kHz: compressed hard and cut 6 dB, then bypassed -> the tone comes out at its input level.
        let x = sine(1450.0, -6.0, 1.0);
        let mut v = mb(0.0, 1.0, 0.0, 0.0);
        v.threshold_db = [0.0, 0.0, -40.0, 0.0];
        v.ratio = [1.0, 1.0, 10.0, 1.0];
        v.gain_db = [0.0, 0.0, -6.0, 0.0];
        assert!(db(tail_peak(&run_mb(v, &x, true, 1024))) < -20.0);
        v.band_bypass = 0b0100;
        assert!((db(tail_peak(&run_mb(v, &x, true, 1024))) - -6.0).abs() < 0.3);
        // Bypassing another band leaves band 3's compression in place.
        v.band_bypass = 0b0001;
        assert!(db(tail_peak(&run_mb(v, &x, true, 1024))) < -20.0);
    }

    #[test]
    fn solo_lets_only_soloed_bands_through() {
        let mut v = mb(0.0, 1.0, 0.0, 0.0);
        v.band_solo = 0b0001; // band 1: below 120 Hz
        let hi = run_mb(v, &sine(1450.0, -10.0, 1.0), true, 1024);
        let lo = run_mb(v, &sine(50.0, -10.0, 1.0), true, 1024);
        assert!(db(tail_peak(&hi)) < -60.0);
        assert!((db(tail_peak(&lo)) - -10.0).abs() < 0.5);
        v.band_solo = 0b0101; // bands 1 + 3: 1.45 kHz comes back (band 3 alone, without the skirts of 2 / 4)
        let back = db(tail_peak(&run_mb(v, &sine(1450.0, -10.0, 1.0), true, 1024)));
        assert!(back > -14.0 && back < -9.0);
    }
}
