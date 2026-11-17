// Swift: AudioEffects.swift, AudioEffectsVoiceChain.swift, AudioEffectsPitch.swift, AudioEffectsEnhanceSpeech.swift
//! AUDIO-FX: clip audio effects. They are `ClipEffect`s with `audio.` kinds in `Clip::effects` of AUDIO clips, so enable
//! switch, keyframes, reorder, duplicate, remove and paste work like for video effects. List order = processing order.
//! Volume stays the fixed clip property (`ClipAnimation::volume`) and is applied after the effects.
//!
//! Kinds and parameter keys are stored strings: never rename. The Swift `ClipEffect.scalar(_:atLocal:)` lives in the
//! effects crate (it clamps to the catalog), so stage evaluation takes it as a closure: `scalar(key, local_time)`.

use sq_core_model::hidden_catalog::{is_active, is_hidden_effect_kind};
use sq_core_model::{Clip, ClipEffect, EffectParamSpec, EffectSpec, Project, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;
use std::sync::OnceLock;

// MARK: Kinds and keys

/// Every audio effect kind starts with this.
pub const AUDIO_KIND_PREFIX: &str = "audio.";
pub const AUDIO_NOISE_REDUCTION_KIND: &str = "audio.noiseReduction";
pub const NOISE_AMOUNT_REDUCTION_KEY: &str = "amount";
pub const AUDIO_EQ_KIND: &str = "audio.eq";
pub const EQ_LOW_GAIN_KEY: &str = "lowGain";
pub const EQ_LOW_FREQ_KEY: &str = "lowFreq";
pub const EQ_MID_GAIN_KEY: &str = "midGain";
pub const EQ_MID_FREQ_KEY: &str = "midFreq";
pub const EQ_MID_Q_KEY: &str = "midQ";
pub const EQ_HIGH_GAIN_KEY: &str = "highGain";
pub const EQ_HIGH_FREQ_KEY: &str = "highFreq";
pub const AUDIO_COMPRESSOR_KIND: &str = "audio.compressor";
pub const COMP_THRESHOLD_KEY: &str = "threshold";
pub const COMP_RATIO_KEY: &str = "ratio";
pub const COMP_ATTACK_KEY: &str = "attack";
pub const COMP_RELEASE_KEY: &str = "release";
pub const COMP_MAKEUP_KEY: &str = "makeup";
pub const AUDIO_DE_ESSER_KIND: &str = "audio.deEsser";
pub const DE_ESS_REDUCTION_KEY: &str = "reduction";
pub const DE_ESS_SENSITIVITY_KEY: &str = "sensitivity";
pub const DE_ESS_FREQUENCY_KEY: &str = "frequency";
pub const DE_ESS_RANGE_KEY: &str = "range";
pub const DE_ESS_SPEED_KEY: &str = "speed";
pub const DE_ESS_LISTEN_KEY: &str = "listen";
pub const AUDIO_DE_REVERB_KIND: &str = "audio.deReverb";
pub const DE_REVERB_AMOUNT_KEY: &str = "amount";
pub const DE_REVERB_DECAY_KEY: &str = "decay";
pub const DE_REVERB_TONE_KEY: &str = "tone";
pub const AUDIO_GAIN_KIND: &str = "audio.gain";
pub const AUDIO_GAIN_KEY: &str = "gain";
pub const AUDIO_LIMITER_KIND: &str = "audio.limiter";
pub const LIMITER_INPUT_KEY: &str = "inputGain";
pub const LIMITER_CEILING_KEY: &str = "ceiling";
pub const AUDIO_NOISE_GATE_KIND: &str = "audio.noiseGate";
pub const GATE_THRESHOLD_KEY: &str = "threshold";
pub const GATE_ATTACK_KEY: &str = "attack";
pub const GATE_RELEASE_KEY: &str = "release";
pub const GATE_RANGE_KEY: &str = "range";
/// Gate Hold (v76): ms the gate stays open after the level fell below the threshold. Missing key = 0 (the earlier behavior).
pub const GATE_HOLD_KEY: &str = "hold";
pub const AUDIO_DELAY_KIND: &str = "audio.delay";
pub const DELAY_TIME_KEY: &str = "time";
pub const DELAY_FEEDBACK_KEY: &str = "feedback";
pub const DELAY_MIX_KEY: &str = "mix";
pub const AUDIO_REVERB_KIND: &str = "audio.reverb";
pub const REVERB_ROOM_SIZE_KEY: &str = "roomSize";
pub const REVERB_DAMPING_KEY: &str = "damping";
pub const REVERB_MIX_KEY: &str = "mix";
pub const AUDIO_DE_HUM_KIND: &str = "audio.deHum";
pub const DE_HUM_MAINS_KEY: &str = "mains";
pub const DE_HUM_FREQ_KEY: &str = "frequency";
pub const DE_HUM_SLOPE_KEY: &str = "slope";
pub const DE_HUM_Q_KEY: &str = "q";
pub const DE_HUM_GAIN_KEY: &str = "gain";
pub const DE_HUM_HARMONICS_KEY: &str = "harmonics";
pub const DE_HUM_LISTEN_KEY: &str = "listen";
pub const AUDIO_LOW_CUT_KIND: &str = "audio.lowCut";
pub const LOW_CUT_FREQ_KEY: &str = "frequency";
pub const LOW_CUT_SLOPE_KEY: &str = "slope";
pub const AUDIO_DIALOGUE_LEVELER_KIND: &str = "audio.dialogueLeveler";
pub const LEVELER_PRESET_KEY: &str = "preset";
pub const LEVELER_REDUCE_LOUD_KEY: &str = "reduceLoud";
pub const LEVELER_LIFT_SOFT_KEY: &str = "liftSoft";
pub const LEVELER_BACKGROUND_KEY: &str = "background";
pub const LEVELER_OUTPUT_GAIN_KEY: &str = "outputGain";
pub const AUDIO_HIGH_CUT_KIND: &str = "audio.highCut";
pub const HIGH_CUT_FREQ_KEY: &str = "frequency";
pub const HIGH_CUT_SLOPE_KEY: &str = "slope";
pub const AUDIO_STEREO_WIDTH_KIND: &str = "audio.stereoWidth";
pub const STEREO_WIDTH_KEY: &str = "width";
pub const AUDIO_CHORUS_KIND: &str = "audio.chorus";
pub const CHORUS_RATE_KEY: &str = "rate";
pub const CHORUS_DEPTH_KEY: &str = "depth";
pub const CHORUS_MIX_KEY: &str = "mix";
pub const AUDIO_NOTCH_KIND: &str = "audio.notch";
pub const NOTCH_FREQ_KEY: &str = "frequency";
pub const NOTCH_Q_KEY: &str = "q";
pub const NOTCH_DEPTH_KEY: &str = "depth";
pub const AUDIO_GRAPHIC_EQ_KIND: &str = "audio.graphicEQ";
pub const GRAPHIC_EQ_OUTPUT_KEY: &str = "output";
pub const GRAPHIC_EQ_BAND_KEYS: [&str; 10] =
    ["band31", "band63", "band125", "band250", "band500", "band1k", "band2k", "band4k", "band8k", "band16k"];
pub const AUDIO_MULTIBAND_KIND: &str = "audio.multiband";
pub const MB_OUTPUT_GAIN_KEY: &str = "outGain";
/// Output limiter (Multiband "Limiter"): off by default. On, the signal is raised by margin - threshold and peak-limited
/// at the margin (threshold -9 / margin -0.1 = +8.9 dB, peaks at -0.1 dBFS).
pub const MB_LIMITER_ON_KEY: &str = "limOn";
pub const MB_LIMITER_THRESHOLD_KEY: &str = "limThr";
pub const MB_LIMITER_MARGIN_KEY: &str = "limMargin";
pub const MB_LIMITER_RELEASE_KEY: &str = "limRel";
/// Limiter attack (ms): 0 = the gain drops at once (the original brickwall); longer = the gain falls with this time
/// constant and any overshoot left is clipped at the margin (zero latency, the margin always holds).
pub const MB_LIMITER_ATTACK_KEY: &str = "limAtk";
/// "Link band controls" of the custom setup: a UI option stored with the effect (no sound of its own).
pub const MB_LINK_KEY: &str = "link";
pub const AUDIO_PARAMETRIC_EQ_KIND: &str = "audio.parametricEQ";
/// Fixed Q of the Parametric EQ's high-pass and low-pass (Butterworth), the Swift literal 0.7071.
pub const PEQ_CUT_Q: f64 = 7071.0 / 10_000.0;
/// Filter ids of the Parametric EQ. Keys are `<id>On`, `<id>Freq`, `<id>Gain`, `<id>Q`.
pub const PEQ_FILTER_IDS: [&str; 9] = ["hp", "ls", "b1", "b2", "b3", "b4", "b5", "hs", "lp"];
/// Kinds that need project format v46 (older builds would drop them).
pub const VOICE_CHAIN_KINDS: [&str; 2] = [AUDIO_MULTIBAND_KIND, AUDIO_PARAMETRIC_EQ_KIND];
pub const AUDIO_PITCH_SHIFT_KIND: &str = "audio.pitchShift";
pub const PITCH_SEMITONES_KEY: &str = "semitones";
pub const PITCH_CENTS_KEY: &str = "cents";
pub const PITCH_FORMANTS_KEY: &str = "formants";
pub const AUDIO_DISGUISE_VOICE_KIND: &str = "audio.disguiseVoice";
pub const DISGUISE_VOICE_KEY: &str = "voice";
pub const AUDIO_ENHANCE_SPEECH_KIND: &str = "audio.enhanceSpeech";
pub const ENHANCE_AMOUNT_KEY: &str = "amount";
pub const ENHANCE_PRESET_KEY: &str = "preset";

/// Crossover key, `i` in 1...3.
pub fn mb_crossover_key(i: usize) -> String {
    format!("x{i}")
}
/// Band threshold key, `i` in 1...4.
pub fn mb_threshold_key(i: usize) -> String {
    format!("thr{i}")
}
/// Band ratio key.
pub fn mb_ratio_key(i: usize) -> String {
    format!("ratio{i}")
}
/// Band attack key.
pub fn mb_attack_key(i: usize) -> String {
    format!("atk{i}")
}
/// Band release key.
pub fn mb_release_key(i: usize) -> String {
    format!("rel{i}")
}
/// Band gain key.
pub fn mb_gain_key(i: usize) -> String {
    format!("gain{i}")
}
/// Per band (i in 1...4). Solo: only soloed bands are heard while any is set (also in export). Bypass: the band passes
/// uncompressed and without its band gain.
pub fn mb_solo_key(i: usize) -> String {
    format!("b{i}solo")
}
/// Band bypass key.
pub fn mb_bypass_key(i: usize) -> String {
    format!("b{i}byp")
}
/// Parametric EQ key of filter `id`; `field` is On, Freq, Gain or Q.
pub fn peq_key(id: &str, field: &str) -> String {
    format!("{id}{field}")
}
/// Keys edited only in the custom setup popup: not shown as parameter rows.
pub fn mb_setup_only_keys() -> BTreeSet<String> {
    (1..=4).flat_map(|i| [mb_solo_key(i), mb_bypass_key(i)]).chain([MB_LINK_KEY.to_string()]).collect()
}

/// `ClipEffect.isAudioKind`.
pub fn is_audio_kind(kind: &str) -> bool {
    kind.starts_with(AUDIO_KIND_PREFIX)
}

// MARK: Value types

/// De-Esser option titles (stored as the choice index, never reorder).
pub enum AudioDeEsserValues {}
impl AudioDeEsserValues {
    /// Range choices.
    pub const RANGE_TITLES: [&'static str; 3] = ["Narrow", "Wide", "All HF"];
    /// Speed choices.
    pub const SPEED_TITLES: [&'static str; 3] = ["Fast", "Medium", "Slow"];
}

/// De-Reverb constants shared by the DSP and the latency the playback and export paths compensate.
pub enum AudioDeReverbValues {}
impl AudioDeReverbValues {
    /// One analysis window at 48 kHz (the stage delays the sound by exactly this).
    pub const LATENCY_SAMPLES: i64 = 1_024;
}

/// Graphic EQ values at one instant: gain per octave band (`BAND_HZ`, always ten) and the output gain.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AudioGraphicEQValues {
    gains: [f64; 10],
    /// Output gain in dB.
    pub output_db: f64,
}

impl AudioGraphicEQValues {
    /// Band center frequencies.
    pub const BAND_HZ: [f64; 10] = [31.5, 63.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0];
    /// Band titles.
    pub const BAND_TITLES: [&'static str; 10] =
        ["31.5 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"];
    /// Constant Q of every band (about one octave wide).
    pub const Q: f64 = 1.41;

    /// All bands flat with the given output gain.
    pub fn new(output_db: f64) -> Self {
        AudioGraphicEQValues { gains: [0.0; 10], output_db }
    }

    /// Convenience for tests and presets; missing bands are 0, extra ones are ignored.
    pub fn from_gains(gains_db: &[f64], output_db: f64) -> Self {
        let mut v = Self::new(output_db);
        for (i, g) in gains_db.iter().take(10).enumerate() {
            v.set(i, *g);
        }
        v
    }

    /// Gain of band `i` (0...9) in dB; reads of an index outside the range give 0.
    pub fn get(&self, i: usize) -> f64 {
        self.gains.get(i).copied().unwrap_or(0.0)
    }

    /// Sets band `i`; writes outside the range are ignored.
    pub fn set(&mut self, i: usize, db: f64) {
        if let Some(g) = self.gains.get_mut(i) {
            *g = db;
        }
    }
}

/// Values of the three-band EQ at one instant.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioEQValues {
    pub low_gain_db: f64,
    pub low_hz: f64,
    pub mid_gain_db: f64,
    pub mid_hz: f64,
    pub mid_q: f64,
    pub high_gain_db: f64,
    pub high_hz: f64,
}

/// Dialogue Leveler values: preset index (see `PRESET_TITLES`), toggles, output gain 0...6 dB.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioLevelerValues {
    pub preset: i64,
    pub reduce_loud: bool,
    pub lift_soft: bool,
    pub background: bool,
    pub output_gain_db: f64,
}

/// What a leveler preset does.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LevelerParams {
    /// Target level dBFS.
    pub target_db: f64,
    /// Most gain down in dB.
    pub max_down_db: f64,
    /// Most gain up in dB.
    pub max_up_db: f64,
    /// How much of the gap to the target is closed (0...1).
    pub strength: f64,
    /// Speech floor dBFS (below it the gain is held, never lifted).
    pub floor_db: f64,
}

impl AudioLevelerValues {
    /// Preset titles.
    pub const PRESET_TITLES: [&'static str; 4] =
        ["Allow wider dynamics", "More lift for low levels", "Lift soft whispery sources", "Optimize moderate levels"];

    /// Per preset (chosen by us, the reference only names the presets).
    pub fn params(&self) -> LevelerParams {
        let p = |target_db, max_down_db, max_up_db, strength, floor_db| LevelerParams {
            target_db,
            max_down_db,
            max_up_db,
            strength,
            floor_db,
        };
        match self.preset {
            1 => p(-20.0, 6.0, 12.0, 0.8, -50.0),
            2 => p(-22.0, 4.0, 15.0, 0.8, -58.0),
            3 => p(-20.0, 9.0, 9.0, 0.9, -50.0),
            _ => p(-20.0, 6.0, 6.0, 0.5, -50.0),
        }
    }
}

/// The Multiband Compressor at one instant: three crossovers (ascending, Hz) and four bands low to high.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioMultibandValues {
    pub output_gain_db: f64,
    pub crossover_hz: [f64; 3],
    pub threshold_db: [f64; 4],
    pub ratio: [f64; 4],
    pub attack_ms: [f64; 4],
    pub release_ms: [f64; 4],
    pub gain_db: [f64; 4],
    /// Output limiter after the output gain: raises by `limiter_gain_db` and holds the peaks at `limiter_margin_db`.
    pub limiter_on: bool,
    pub limiter_threshold_db: f64,
    pub limiter_margin_db: f64,
    pub limiter_release_ms: f64,
    /// 0 = instant gain drop (default, the sound before attack existed).
    pub limiter_attack_ms: f64,
    /// Bit i (0 = lowest band) set: band i + 1 soloed.
    pub band_solo: u8,
    /// Bit i set: band i + 1 bypassed.
    pub band_bypass: u8,
}

impl AudioMultibandValues {
    /// `band` 0...3, low to high.
    pub fn is_soloed(&self, band: usize) -> bool {
        self.band_solo & (1 << band) != 0
    }

    /// `band` 0...3, low to high.
    pub fn is_bypassed(&self, band: usize) -> bool {
        self.band_bypass & (1 << band) != 0
    }

    /// Gain in front of the limiter: the threshold is brought up to the margin (never a cut).
    pub fn limiter_gain_db(&self) -> f64 {
        (self.limiter_margin_db - self.limiter_threshold_db).max(0.0)
    }
}

/// One filter of the Parametric EQ. `gain_db` is unused by HP / LP; `q` is the peak Q, the shelf Q, and ignored by HP / LP
/// (fixed Butterworth).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioPEQBand {
    pub on: bool,
    pub hz: f64,
    pub gain_db: f64,
    pub q: f64,
}

/// The Parametric EQ at one instant: high-pass, low shelf, five peaks, high shelf, low-pass (processing order).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioParametricEQValues {
    pub bands: [AudioPEQBand; 9],
}

impl AudioParametricEQValues {
    /// Number of filters.
    pub const BAND_COUNT: usize = 9;

    /// Filter `i` in processing order: 0 HP, 1 low shelf, 2...6 peaks, 7 high shelf, 8 LP (above: LP).
    pub fn band(&self, i: usize) -> AudioPEQBand {
        self.bands[i.min(Self::BAND_COUNT - 1)]
    }
}

/// Enhance Speech at one instant: amount 0...1, preset index (`PRESET_TITLES`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioEnhanceSpeechValues {
    pub amount: f64,
    pub preset: i64,
}

/// What each Enhance Speech stage gets. Denoise / dereverb / leveling 0...1, EQ gains in dB, decay in seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EnhanceRecipe {
    pub low_cut_hz: f64,
    pub denoise: f64,
    pub dereverb: f64,
    pub decay_seconds: f64,
    /// Peak at `MUD_HZ` (cut).
    pub mud_db: f64,
    /// Peak at `PRESENCE_HZ` (boost).
    pub presence_db: f64,
    /// Wide peak at `AIR_HZ` (boost).
    pub air_db: f64,
    /// 0 = leveler off, 1 = its full gain ride.
    pub leveling: f64,
}

impl EnhanceRecipe {
    pub const MUD_HZ: f64 = 300.0;
    pub const PRESENCE_HZ: f64 = 3_500.0;
    pub const AIR_HZ: f64 = 10_000.0;
    pub const MUD_Q: f64 = 1.0;
    pub const PRESENCE_Q: f64 = 0.9;
    pub const AIR_Q: f64 = 0.7;
}

impl AudioEnhanceSpeechValues {
    /// Stored as the choice index: never reorder.
    pub const PRESET_TITLES: [&'static str; 4] = ["Balanced", "Noisy Location", "Echoey Room", "Light Touch"];
    /// Low Cut corner at Amount 0 (below speech and nearly every playback system: practically transparent).
    pub const NEUTRAL_LOW_CUT_HZ: f64 = 20.0;
    /// RNNoise frame (480) + De-Reverb window: the stage delays the sound by exactly this, also while off or at 0 %.
    pub const LATENCY_SAMPLES: i64 = 480 + AudioDeReverbValues::LATENCY_SAMPLES;
    /// Dialogue Leveler preset the recipe rides with ("Optimize moderate levels").
    pub const LEVELER_PRESET: i64 = 3;

    /// The preset at full amount. Numbers are ours (tuned on synthetic voice + noise, by ear later): unsourced.
    fn full(preset: i64) -> EnhanceRecipe {
        let r = |low_cut_hz, denoise, dereverb, decay_seconds, mud_db, presence_db, air_db, leveling| EnhanceRecipe {
            low_cut_hz,
            denoise,
            dereverb,
            decay_seconds,
            mud_db,
            presence_db,
            air_db,
            leveling,
        };
        match preset {
            1 => r(110.0, 1.0, 0.3, 0.5, -2.0, 3.5, 1.0, 1.0),
            2 => r(90.0, 0.7, 0.9, 1.0, -3.5, 3.0, 1.5, 1.0),
            3 => r(75.0, 0.5, 0.2, 0.6, -1.0, 1.5, 1.0, 0.6),
            _ => r(90.0, 0.85, 0.45, 0.6, -2.5, 3.0, 2.0, 1.0),
        }
    }

    /// The recipe scaled by `amount` (0 = every stage neutral).
    pub fn recipe(&self) -> EnhanceRecipe {
        let a = self.amount.clamp(0.0, 1.0);
        let f = Self::full(self.preset);
        EnhanceRecipe {
            low_cut_hz: Self::NEUTRAL_LOW_CUT_HZ + (f.low_cut_hz - Self::NEUTRAL_LOW_CUT_HZ) * a,
            denoise: f.denoise * a,
            dereverb: f.dereverb * a,
            decay_seconds: f.decay_seconds,
            mud_db: f.mud_db * a,
            presence_db: f.presence_db * a,
            air_db: f.air_db * a,
            leveling: f.leveling * a,
        }
    }
}

/// Shared numbers of the pitch engine.
pub enum AudioPitchValues {}
impl AudioPitchValues {
    /// One analysis window: the delay of Pitch Shift and of Disguise Voice in samples, also while the effect is off.
    pub const LATENCY_SAMPLES: i64 = 2_048;

    /// Semitones to a frequency ratio.
    pub fn ratio(semitones: f64) -> f64 {
        2.0_f64.powf(semitones / 12.0)
    }

    /// `t` as a sample index at `rate` (nearest, whole-number math; negative before the clip's start).
    pub fn sample(t: Time, rate: i64) -> i64 {
        if t.timescale() <= 0 || rate <= 0 {
            return 0;
        }
        let num = 2 * i128::from(t.value()) * i128::from(rate) + i128::from(t.timescale());
        let den = 2 * i128::from(t.timescale());
        let q = num / den;
        let r = if num % den < 0 { q - 1 } else { q };
        r.clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64
    }
}

/// Disguise Voice options and text.
pub enum AudioDisguiseValues {}
impl AudioDisguiseValues {
    /// Stored as the choice index: never reorder.
    pub const VOICE_TITLES: [&'static str; 2] = ["Lower", "Higher"];
    /// The one honest description of the effect, used by every hint, tooltip and status line.
    pub const HINT: &'static str = "Makes the voice harder to recognize. Not a guarantee.";
}

/// Why Disguise Voice refused a range.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DisguiseVoiceError {
    /// A linked audio clip that carries the same voice sits on a locked track: disguising the rest would leave it as it is.
    LinkedAudioLocked,
}

impl std::fmt::Display for DisguiseVoiceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DisguiseVoiceError::LinkedAudioLocked => f.write_str(
                "A linked audio clip in this range is on a locked track, so its voice would stay as it is. Unlock the track or unlink the clip, then run Disguise Voice again.",
            ),
        }
    }
}

impl std::error::Error for DisguiseVoiceError {}

/// One audio effect evaluated at an instant: what the DSP chain runs.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioFXStage {
    /// Denoiser wet/dry 0...1.
    NoiseReduction { amount: f64 },
    /// Three-band EQ.
    Eq(AudioEQValues),
    /// Compressor.
    Compressor { threshold_db: f64, ratio: f64, attack_ms: f64, release_ms: f64, makeup_db: f64 },
    /// Most reduction of the highs in dB; sensitivity 0...1 (1 = reacts earliest). `frequency_hz` is the sibilance center,
    /// `range` 0 Narrow / 1 Wide / 2 All HF, `speed` 0 Fast / 1 Medium / 2 Slow, `listen` = only the reduced band.
    DeEsser { reduction_db: f64, sensitivity: f64, frequency_hz: f64, range: i64, speed: i64, listen: bool },
    /// Late-reverb suppression: amount 0...1, decay = assumed reverb time in seconds, tone -1...1.
    DeReverb { amount: f64, decay_seconds: f64, tone: f64 },
    /// Plain gain.
    Gain { db: f64 },
    /// Limiter.
    Limiter { input_db: f64, ceiling_db: f64 },
    /// Gate: closes below the threshold (dB), pulls the sound down by `range_db` while closed.
    NoiseGate { threshold_db: f64, attack_ms: f64, release_ms: f64, range_db: f64, hold_ms: f64 },
    /// Delay line: time in ms, feedback and mix 0...1.
    Delay { time_ms: f64, feedback: f64, mix: f64 },
    /// Reverb: room size, damping and mix 0...1.
    Reverb { room_size: f64, damping: f64, mix: f64 },
    /// Multiband compressor.
    Multiband(AudioMultibandValues),
    /// Parametric EQ.
    ParametricEq(AudioParametricEQValues),
    /// Notch bank at `frequency_hz` and its harmonics: Q, depth, count, slope 0...1 (0.5 = equal depth), listen = the hum only.
    DeHum { frequency_hz: f64, q: f64, gain_db: f64, harmonics: i64, slope: f64, listen: bool },
    /// High-pass: corner Hz, order 1...3 (12, 24, 48 dB/oct).
    LowCut { frequency_hz: f64, order: i64 },
    /// Dialogue leveler.
    DialogueLeveler(AudioLevelerValues),
    /// Low-pass: corner Hz, order 1...3.
    HighCut { frequency_hz: f64, order: i64 },
    /// Mid/side width, 0 (mono) ... 2 (side doubled); 1 = unchanged.
    StereoWidth { width: f64 },
    /// Modulated short delay: LFO rate Hz, sweep depth ms, mix 0...1.
    Chorus { rate_hz: f64, depth_ms: f64, mix: f64 },
    /// Narrow cut: center Hz, Q, depth in dB (0 = bypass).
    Notch { frequency_hz: f64, q: f64, depth_db: f64 },
    /// Ten octave bands in dB plus the output gain.
    GraphicEq(AudioGraphicEQValues),
    /// One-click speech clean-up (`AudioEnhanceSpeechValues::recipe` drives the repair stages).
    EnhanceSpeech(AudioEnhanceSpeechValues),
    /// Semitones (cents included); `preserve_formants` keeps the spectral envelope where it was.
    PitchShift { semitones: f64, preserve_formants: bool },
    /// `voice` = index into `AudioDisguiseValues::VOICE_TITLES`, `at` = clip-local position (drives the modulation).
    DisguiseVoice { voice: i64, at: Time },
}

/// One audio effect of a clip at an instant. A disabled one stays in the chain (its state and latency are kept) but passes
/// the sound through.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioFXStep {
    pub id: Id,
    pub enabled: bool,
    pub stage: AudioFXStage,
}

/// Which effects a clip's chain holds, in order: a change rebuilds the DSP chain, parameter changes do not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioFXSlot {
    pub id: Id,
    pub kind: String,
}

/// `Int(x.rounded())` on a catalog-clamped parameter (NaN cannot reach it: the scalar is sanitized).
fn index(v: f64) -> i64 {
    if v.is_finite() { v.round() as i64 } else { 0 }
}

/// Evaluation of an audio effect and of the audio chain of a clip.
pub trait ClipEffectAudioExt {
    /// An audio effect (runs on the sound of an audio clip, never on the picture).
    fn is_audio(&self) -> bool;
    /// This audio effect at clip-local `t`, values from `scalar(key, t)` (clamped to the catalog ranges); `None` for any
    /// other kind.
    fn audio_stage(&self, t: Time, scalar: &dyn Fn(&str, Time) -> f64) -> Option<AudioFXStage>;
}

impl ClipEffectAudioExt for ClipEffect {
    fn is_audio(&self) -> bool {
        is_audio_kind(&self.kind)
    }

    fn audio_stage(&self, t: Time, scalar: &dyn Fn(&str, Time) -> f64) -> Option<AudioFXStage> {
        let v = |k: &str| scalar(k, t);
        let stage = match self.kind.as_str() {
            AUDIO_NOISE_REDUCTION_KIND => {
                AudioFXStage::NoiseReduction { amount: v(NOISE_AMOUNT_REDUCTION_KEY) / 100.0 }
            }
            AUDIO_EQ_KIND => AudioFXStage::Eq(AudioEQValues {
                low_gain_db: v(EQ_LOW_GAIN_KEY),
                low_hz: v(EQ_LOW_FREQ_KEY),
                mid_gain_db: v(EQ_MID_GAIN_KEY),
                mid_hz: v(EQ_MID_FREQ_KEY),
                mid_q: v(EQ_MID_Q_KEY),
                high_gain_db: v(EQ_HIGH_GAIN_KEY),
                high_hz: v(EQ_HIGH_FREQ_KEY),
            }),
            AUDIO_COMPRESSOR_KIND => AudioFXStage::Compressor {
                threshold_db: v(COMP_THRESHOLD_KEY),
                ratio: v(COMP_RATIO_KEY),
                attack_ms: v(COMP_ATTACK_KEY),
                release_ms: v(COMP_RELEASE_KEY),
                makeup_db: v(COMP_MAKEUP_KEY),
            },
            AUDIO_DE_ESSER_KIND => AudioFXStage::DeEsser {
                reduction_db: v(DE_ESS_REDUCTION_KEY),
                sensitivity: v(DE_ESS_SENSITIVITY_KEY) / 100.0,
                frequency_hz: v(DE_ESS_FREQUENCY_KEY),
                range: index(v(DE_ESS_RANGE_KEY)),
                speed: index(v(DE_ESS_SPEED_KEY)),
                listen: v(DE_ESS_LISTEN_KEY) >= 0.5,
            },
            AUDIO_DE_REVERB_KIND => AudioFXStage::DeReverb {
                amount: v(DE_REVERB_AMOUNT_KEY) / 100.0,
                decay_seconds: v(DE_REVERB_DECAY_KEY) / 1000.0,
                tone: v(DE_REVERB_TONE_KEY) / 100.0,
            },
            AUDIO_GAIN_KIND => AudioFXStage::Gain { db: v(AUDIO_GAIN_KEY) },
            AUDIO_LIMITER_KIND => {
                AudioFXStage::Limiter { input_db: v(LIMITER_INPUT_KEY), ceiling_db: v(LIMITER_CEILING_KEY) }
            }
            AUDIO_NOISE_GATE_KIND => AudioFXStage::NoiseGate {
                threshold_db: v(GATE_THRESHOLD_KEY),
                attack_ms: v(GATE_ATTACK_KEY),
                release_ms: v(GATE_RELEASE_KEY),
                range_db: v(GATE_RANGE_KEY),
                hold_ms: v(GATE_HOLD_KEY),
            },
            AUDIO_DELAY_KIND => AudioFXStage::Delay {
                time_ms: v(DELAY_TIME_KEY),
                feedback: v(DELAY_FEEDBACK_KEY) / 100.0,
                mix: v(DELAY_MIX_KEY) / 100.0,
            },
            AUDIO_REVERB_KIND => AudioFXStage::Reverb {
                room_size: v(REVERB_ROOM_SIZE_KEY) / 100.0,
                damping: v(REVERB_DAMPING_KEY) / 100.0,
                mix: v(REVERB_MIX_KEY) / 100.0,
            },
            AUDIO_DE_HUM_KIND => {
                let mains = index(v(DE_HUM_MAINS_KEY));
                AudioFXStage::DeHum {
                    frequency_hz: if mains == 1 {
                        50.0
                    } else if mains == 2 {
                        60.0
                    } else {
                        v(DE_HUM_FREQ_KEY)
                    },
                    q: v(DE_HUM_Q_KEY) / 100.0,
                    gain_db: v(DE_HUM_GAIN_KEY),
                    harmonics: index(v(DE_HUM_HARMONICS_KEY)),
                    slope: v(DE_HUM_SLOPE_KEY) / 100.0,
                    listen: v(DE_HUM_LISTEN_KEY) >= 0.5,
                }
            }
            AUDIO_LOW_CUT_KIND => {
                AudioFXStage::LowCut { frequency_hz: v(LOW_CUT_FREQ_KEY), order: index(v(LOW_CUT_SLOPE_KEY)) + 1 }
            }
            AUDIO_DIALOGUE_LEVELER_KIND => AudioFXStage::DialogueLeveler(AudioLevelerValues {
                preset: index(v(LEVELER_PRESET_KEY)),
                reduce_loud: v(LEVELER_REDUCE_LOUD_KEY) >= 0.5,
                lift_soft: v(LEVELER_LIFT_SOFT_KEY) >= 0.5,
                background: v(LEVELER_BACKGROUND_KEY) >= 0.5,
                output_gain_db: v(LEVELER_OUTPUT_GAIN_KEY),
            }),
            AUDIO_HIGH_CUT_KIND => {
                AudioFXStage::HighCut { frequency_hz: v(HIGH_CUT_FREQ_KEY), order: index(v(HIGH_CUT_SLOPE_KEY)) + 1 }
            }
            AUDIO_STEREO_WIDTH_KIND => AudioFXStage::StereoWidth { width: v(STEREO_WIDTH_KEY) / 100.0 },
            AUDIO_CHORUS_KIND => AudioFXStage::Chorus {
                rate_hz: v(CHORUS_RATE_KEY),
                depth_ms: v(CHORUS_DEPTH_KEY),
                mix: v(CHORUS_MIX_KEY) / 100.0,
            },
            AUDIO_NOTCH_KIND => AudioFXStage::Notch {
                frequency_hz: v(NOTCH_FREQ_KEY),
                q: v(NOTCH_Q_KEY) / 100.0,
                depth_db: v(NOTCH_DEPTH_KEY),
            },
            AUDIO_GRAPHIC_EQ_KIND => {
                let mut g = AudioGraphicEQValues::new(v(GRAPHIC_EQ_OUTPUT_KEY));
                for (i, key) in GRAPHIC_EQ_BAND_KEYS.iter().enumerate() {
                    g.set(i, v(key));
                }
                AudioFXStage::GraphicEq(g)
            }
            AUDIO_MULTIBAND_KIND => AudioFXStage::Multiband(multiband_values(&v)),
            AUDIO_PARAMETRIC_EQ_KIND => AudioFXStage::ParametricEq(parametric_eq_values(&v)),
            AUDIO_ENHANCE_SPEECH_KIND => AudioFXStage::EnhanceSpeech(AudioEnhanceSpeechValues {
                amount: v(ENHANCE_AMOUNT_KEY) / 100.0,
                preset: index(v(ENHANCE_PRESET_KEY)),
            }),
            AUDIO_PITCH_SHIFT_KIND => AudioFXStage::PitchShift {
                semitones: v(PITCH_SEMITONES_KEY) + v(PITCH_CENTS_KEY) / 100.0,
                preserve_formants: v(PITCH_FORMANTS_KEY) >= 0.5,
            },
            // The random modulation is a function of the clip-local position (the engine counts it in its own samples),
            // so a seek and an export land on the same curve.
            AUDIO_DISGUISE_VOICE_KIND => AudioFXStage::DisguiseVoice { voice: index(v(DISGUISE_VOICE_KEY)), at: t },
            _ => return None,
        };
        Some(stage)
    }
}

fn multiband_values(v: &dyn Fn(&str) -> f64) -> AudioMultibandValues {
    let four = |f: fn(usize) -> String| [v(&f(1)), v(&f(2)), v(&f(3)), v(&f(4))];
    let mask = |f: fn(usize) -> String| (0..4).fold(0_u8, |m, i| m | if v(&f(i + 1)) >= 0.5 { 1 << i } else { 0 });
    AudioMultibandValues {
        output_gain_db: v(MB_OUTPUT_GAIN_KEY),
        crossover_hz: [v(&mb_crossover_key(1)), v(&mb_crossover_key(2)), v(&mb_crossover_key(3))],
        threshold_db: four(mb_threshold_key),
        ratio: four(mb_ratio_key),
        attack_ms: four(mb_attack_key),
        release_ms: four(mb_release_key),
        gain_db: four(mb_gain_key),
        limiter_on: v(MB_LIMITER_ON_KEY) >= 0.5,
        limiter_threshold_db: v(MB_LIMITER_THRESHOLD_KEY),
        limiter_margin_db: v(MB_LIMITER_MARGIN_KEY),
        limiter_release_ms: v(MB_LIMITER_RELEASE_KEY),
        limiter_attack_ms: v(MB_LIMITER_ATTACK_KEY),
        band_solo: mask(mb_solo_key) & 0xF,
        band_bypass: mask(mb_bypass_key) & 0xF,
    }
}

fn parametric_eq_values(v: &dyn Fn(&str) -> f64) -> AudioParametricEQValues {
    let band = |id: &str| {
        let cut = id == "hp" || id == "lp";
        AudioPEQBand {
            on: v(&peq_key(id, "On")) >= 0.5,
            hz: v(&peq_key(id, "Freq")),
            gain_db: if cut { 0.0 } else { v(&peq_key(id, "Gain")) },
            q: if cut { PEQ_CUT_Q } else { v(&peq_key(id, "Q")) },
        }
    };
    // Processing order: hp, ls, b1...b5, hs, lp (`PEQ_FILTER_IDS`).
    AudioParametricEQValues { bands: PEQ_FILTER_IDS.map(band) }
}

/// The audio chain of a clip.
pub trait ClipAudioChainExt {
    /// An audio clip with at least one audio effect (switched off ones count).
    fn has_audio_effects(&self) -> bool;
    /// The audio effects of this clip in processing order (empty for video clips).
    fn audio_fx_layout(&self) -> Vec<AudioFXSlot>;
    /// Every audio effect at clip-local `t`, in processing order (same order and ids as `audio_fx_layout`).
    fn audio_fx_steps(&self, t: Time, scalar: &dyn Fn(&ClipEffect, &str, Time) -> f64) -> Vec<AudioFXStep>;
    /// Same effects in the same order as `layout` (a DSP chain built for it still fits).
    fn audio_fx_layout_matches(&self, layout: &[AudioFXSlot]) -> bool;
    /// The clip carries Disguise Voice.
    fn has_disguise_voice(&self) -> bool;
}

impl ClipAudioChainExt for Clip {
    fn has_audio_effects(&self) -> bool {
        self.kind == TrackKind::Audio && self.effects.iter().any(|e| e.is_audio())
    }

    fn audio_fx_layout(&self) -> Vec<AudioFXSlot> {
        if self.kind != TrackKind::Audio {
            return Vec::new();
        }
        self.effects
            .iter()
            .filter(|e| e.is_audio() && audio_spec(&e.kind).is_some())
            .map(|e| AudioFXSlot { id: e.id, kind: e.kind.clone() })
            .collect()
    }

    fn audio_fx_steps(&self, t: Time, scalar: &dyn Fn(&ClipEffect, &str, Time) -> f64) -> Vec<AudioFXStep> {
        if self.kind != TrackKind::Audio {
            return Vec::new();
        }
        self.effects
            .iter()
            .filter_map(|e| {
                let stage = e.audio_stage(t, &|k, at| scalar(e, k, at))?;
                Some(AudioFXStep { id: e.id, enabled: e.enabled, stage })
            })
            .collect()
    }

    fn audio_fx_layout_matches(&self, layout: &[AudioFXSlot]) -> bool {
        if self.kind != TrackKind::Audio {
            return layout.is_empty();
        }
        let mut i = 0;
        for e in self.effects.iter().filter(|e| e.is_audio() && audio_spec(&e.kind).is_some()) {
            if !layout.get(i).is_some_and(|s| s.id == e.id && s.kind == e.kind) {
                return false;
            }
            i += 1;
        }
        i == layout.len()
    }

    fn has_disguise_voice(&self) -> bool {
        self.effects.iter().any(|e| e.kind == AUDIO_DISGUISE_VOICE_KIND)
    }
}

/// `extension Project` of the audio effect files.
pub trait ProjectAudioEffectsExt {
    /// Any timeline holds an audio clip with audio effects: the file must be v39.
    fn contains_audio_effects(&self) -> bool;
    /// Any timeline holds a clip with a Multiband Compressor or 5-band Parametric EQ: the file must be v46.
    fn contains_voice_chain_effects(&self) -> bool;
    /// The sequences that play nested somewhere below a clip carrying Disguise Voice (transitively, through any depth).
    /// Exporting such a sequence directly plays its voice undisguised: the effect sits on the nest clip outside it.
    fn sequences_nested_under_disguise_voice(&self) -> BTreeSet<Id>;
}

impl ProjectAudioEffectsExt for Project {
    fn contains_audio_effects(&self) -> bool {
        self.timelines.iter().any(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.has_audio_effects())))
    }

    fn contains_voice_chain_effects(&self) -> bool {
        self.timelines.iter().any(|t| {
            t.tracks.iter().any(|tr| {
                tr.clips().iter().any(|c| c.effects.iter().any(|e| VOICE_CHAIN_KINDS.contains(&e.kind.as_str())))
            })
        })
    }

    fn sequences_nested_under_disguise_voice(&self) -> BTreeSet<Id> {
        let mut result = BTreeSet::new();
        let mut queue: Vec<Id> = Vec::new();
        for t in &self.timelines {
            for c in t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| c.has_disguise_voice()) {
                if let Some(s) = c.sequence
                    && result.insert(s)
                {
                    queue.push(s);
                }
            }
        }
        while let Some(id) = queue.pop() {
            // everything below a disguised nest clip, whatever clips it holds
            let Some(t) = self.timelines.iter().find(|t| t.id == id) else { continue };
            for c in t.tracks.iter().flat_map(|tr| tr.clips()) {
                if let Some(s) = c.sequence
                    && result.insert(s)
                {
                    queue.push(s);
                }
            }
        }
        result
    }
}

// MARK: Catalog

fn spec(kind: &str, title: &str, params: Vec<EffectParamSpec>) -> EffectSpec {
    EffectSpec { kind: kind.to_string(), title: title.to_string(), params, pairs: Vec::new() }
}

fn slider(
    key: &str,
    title: &str,
    unit: &str,
    default: f64,
    range: std::ops::RangeInclusive<f64>,
    step: f64,
    decimals: i64,
) -> EffectParamSpec {
    EffectParamSpec::new(key, title, unit, default, range, step, decimals)
}

fn with_display_scale(mut p: EffectParamSpec, scale: f64) -> EffectParamSpec {
    p.display_scale = scale;
    p
}

const SLOPES: [&str; 3] = ["12 dB/oct", "24 dB/oct", "48 dB/oct"];

fn multiband_spec() -> EffectSpec {
    let mut p = vec![slider(MB_OUTPUT_GAIN_KEY, "Output Gain", "dB", 0.0, -18.0..=18.0, 0.1, 1)];
    let xs = [120.0, 700.0, 3_000.0];
    for i in 1..=3 {
        p.push(slider(&mb_crossover_key(i), &format!("Crossover {i}"), "Hz", xs[i - 1], 20.0..=20_000.0, 1.0, 0));
    }
    for i in 1..=4 {
        p.push(slider(&mb_threshold_key(i), &format!("Band {i} Threshold"), "dB", -20.0, -60.0..=0.0, 0.1, 1));
        p.push(slider(&mb_ratio_key(i), &format!("Band {i} Ratio"), ":1", 2.0, 1.0..=30.0, 0.1, 1));
        p.push(slider(&mb_attack_key(i), &format!("Band {i} Attack"), "ms", 10.0, 0.1..=500.0, 0.1, 1));
        p.push(slider(&mb_release_key(i), &format!("Band {i} Release"), "ms", 100.0, 5.0..=2_000.0, 1.0, 0));
        p.push(slider(&mb_gain_key(i), &format!("Band {i} Gain"), "dB", 0.0, -18.0..=18.0, 0.1, 1));
    }
    p.push(EffectParamSpec::checkbox(MB_LIMITER_ON_KEY, "Limiter", false));
    p.push(slider(MB_LIMITER_THRESHOLD_KEY, "Limiter Threshold", "dB", -10.0, -60.0..=0.0, 0.1, 1));
    p.push(slider(MB_LIMITER_MARGIN_KEY, "Limiter Margin", "dB", -0.1, -18.0..=0.0, 0.1, 1));
    p.push(slider(MB_LIMITER_ATTACK_KEY, "Limiter Attack", "ms", 0.0, 0.0..=500.0, 0.1, 1));
    p.push(slider(MB_LIMITER_RELEASE_KEY, "Limiter Release", "ms", 500.0, 5.0..=5_000.0, 1.0, 0));
    for i in 1..=4 {
        p.push(EffectParamSpec::checkbox(&mb_solo_key(i), &format!("Band {i} Solo"), false));
        p.push(EffectParamSpec::checkbox(&mb_bypass_key(i), &format!("Band {i} Bypass"), false));
    }
    p.push(EffectParamSpec::checkbox(MB_LINK_KEY, "Link Band Controls", false));
    spec(AUDIO_MULTIBAND_KIND, "Multiband Compressor", p)
}

fn parametric_eq_spec() -> EffectSpec {
    let mut p = Vec::new();
    let title = |id: &str| match id {
        "hp" => "High-Pass",
        "lp" => "Low-Pass",
        "ls" => "Low Shelf",
        "hs" => "High Shelf",
        "b1" => "Band 1",
        "b2" => "Band 2",
        "b3" => "Band 3",
        "b4" => "Band 4",
        _ => "Band 5",
    };
    let freq = |id: &str| match id {
        "hp" => 80.0,
        "ls" => 120.0,
        "b1" => 100.0,
        "b2" => 400.0,
        "b3" => 1_500.0,
        "b4" => 4_000.0,
        "b5" => 10_000.0,
        "hs" => 8_000.0,
        _ => 16_000.0,
    };
    for id in PEQ_FILTER_IDS {
        let t = title(id);
        let is_cut = id == "hp" || id == "lp";
        p.push(EffectParamSpec::checkbox(&peq_key(id, "On"), &format!("{t} On"), !is_cut));
        p.push(slider(&peq_key(id, "Freq"), &format!("{t} Frequency"), "Hz", freq(id), 20.0..=20_000.0, 1.0, 0));
        if !is_cut {
            p.push(slider(&peq_key(id, "Gain"), &format!("{t} Gain"), "dB", 0.0, -24.0..=24.0, 0.1, 1));
            let q = if id == "ls" || id == "hs" { 0.71 } else { 1.0 };
            p.push(slider(&peq_key(id, "Q"), &format!("{t} Q"), "", q, 0.1..=10.0, 0.01, 2));
        }
    }
    spec(AUDIO_PARAMETRIC_EQ_KIND, "EQ", p)
}

/// The Effects panel's "Audio Effects" folder, in panel order. Not part of the video list.
fn build_every_audio_spec() -> Vec<EffectSpec> {
    let mut v = vec![
        // RNNoise wet/dry: 0 = off, 100 = fully denoised. Adds 10 ms of latency the mixer compensates.
        spec(
            AUDIO_NOISE_REDUCTION_KIND,
            "Noise Reduction",
            vec![slider(NOISE_AMOUNT_REDUCTION_KEY, "Amount", "%", 50.0, 0.0..=100.0, 1.0, 0)],
        ),
        // Three-band parametric EQ: low shelf, mid peak, high shelf (RBJ).
        spec(
            AUDIO_EQ_KIND,
            "EQ (3 band)",
            vec![
                slider(EQ_LOW_GAIN_KEY, "Low Gain", "dB", 0.0, -24.0..=24.0, 0.1, 1),
                slider(EQ_LOW_FREQ_KEY, "Low Frequency", "Hz", 100.0, 20.0..=1_000.0, 1.0, 0),
                slider(EQ_MID_GAIN_KEY, "Mid Gain", "dB", 0.0, -24.0..=24.0, 0.1, 1),
                slider(EQ_MID_FREQ_KEY, "Mid Frequency", "Hz", 1_000.0, 100.0..=10_000.0, 1.0, 0),
                slider(EQ_MID_Q_KEY, "Mid Q", "", 1.0, 0.1..=10.0, 0.01, 2),
                slider(EQ_HIGH_GAIN_KEY, "High Gain", "dB", 0.0, -24.0..=24.0, 0.1, 1),
                slider(EQ_HIGH_FREQ_KEY, "High Frequency", "Hz", 8_000.0, 1_000.0..=20_000.0, 1.0, 0),
            ],
        ),
        // Single-band peak compressor (the detector of the 4-band compressor).
        spec(
            AUDIO_COMPRESSOR_KIND,
            "Compressor",
            vec![
                slider(COMP_THRESHOLD_KEY, "Threshold", "dB", -20.0, -60.0..=0.0, 0.1, 1),
                slider(COMP_RATIO_KEY, "Ratio", ":1", 4.0, 1.0..=20.0, 0.1, 1),
                slider(COMP_ATTACK_KEY, "Attack", "ms", 10.0, 0.1..=200.0, 0.1, 1),
                slider(COMP_RELEASE_KEY, "Release", "ms", 100.0, 10.0..=2_000.0, 1.0, 0),
                slider(COMP_MAKEUP_KEY, "Makeup Gain", "dB", 0.0, 0.0..=24.0, 0.1, 1),
            ],
        ),
        // Split-band de-esser. The 2-10 kHz span and the split ratios per Range and the speed times are our own (unsourced).
        spec(
            AUDIO_DE_ESSER_KIND,
            "De-Esser",
            vec![
                slider(DE_ESS_REDUCTION_KEY, "Reduction", "dB", 10.0, 0.0..=24.0, 0.5, 1),
                slider(DE_ESS_SENSITIVITY_KEY, "Sensitivity", "%", 50.0, 0.0..=100.0, 1.0, 0),
                slider(DE_ESS_FREQUENCY_KEY, "Frequency", "Hz", 7_000.0, 2_000.0..=10_000.0, 50.0, 0),
                EffectParamSpec::choice(DE_ESS_RANGE_KEY, "Range", &AudioDeEsserValues::RANGE_TITLES, 1),
                EffectParamSpec::choice(DE_ESS_SPEED_KEY, "Reaction", &AudioDeEsserValues::SPEED_TITLES, 1),
                EffectParamSpec::checkbox(DE_ESS_LISTEN_KEY, "Listen to Ess", false),
            ],
        ),
        // Late-reverb suppression (spectral). Adds a fixed delay (`AudioDeReverbValues::LATENCY_SAMPLES`).
        spec(
            AUDIO_DE_REVERB_KIND,
            "De-Reverb",
            vec![
                slider(DE_REVERB_AMOUNT_KEY, "Amount", "%", 50.0, 0.0..=100.0, 1.0, 0),
                slider(DE_REVERB_DECAY_KEY, "Decay", "ms", 600.0, 150.0..=2_500.0, 10.0, 0),
                slider(DE_REVERB_TONE_KEY, "Tone", "", 0.0, -100.0..=100.0, 1.0, 0),
            ],
        ),
        spec(AUDIO_GAIN_KIND, "Gain", vec![slider(AUDIO_GAIN_KEY, "Gain", "dB", 0.0, -60.0..=24.0, 0.1, 1)]),
        // Input gain into a zero-latency peak limiter (the master limiter's code).
        spec(
            AUDIO_LIMITER_KIND,
            "Limiter",
            vec![
                slider(LIMITER_INPUT_KEY, "Input Boost", "dB", 0.0, 0.0..=24.0, 0.1, 1),
                slider(LIMITER_CEILING_KEY, "Maximum Amplitude", "dB", -1.0, -24.0..=0.0, 0.1, 1),
            ],
        ),
        // Downward gate: closes below Threshold, Range = how far it pulls the sound down while closed.
        spec(
            AUDIO_NOISE_GATE_KIND,
            "Noise Gate",
            vec![
                slider(GATE_THRESHOLD_KEY, "Threshold", "dB", -40.0, -80.0..=0.0, 0.1, 1),
                slider(GATE_ATTACK_KEY, "Attack", "ms", 1.0, 0.1..=100.0, 0.1, 1),
                slider(GATE_HOLD_KEY, "Hold", "ms", 0.0, 0.0..=1_000.0, 1.0, 0),
                slider(GATE_RELEASE_KEY, "Release", "ms", 100.0, 5.0..=2_000.0, 1.0, 0),
                slider(GATE_RANGE_KEY, "Range", "dB", 60.0, 0.0..=80.0, 0.5, 1),
            ],
        ),
        // Feedback delay (2 s line).
        spec(
            AUDIO_DELAY_KIND,
            "Delay",
            vec![
                slider(DELAY_TIME_KEY, "Delay", "ms", 350.0, 1.0..=2_000.0, 1.0, 0),
                slider(DELAY_FEEDBACK_KEY, "Feedback", "%", 35.0, 0.0..=95.0, 1.0, 0),
                slider(DELAY_MIX_KEY, "Mix", "%", 30.0, 0.0..=100.0, 1.0, 0),
            ],
        ),
        // Freeverb-style room.
        spec(
            AUDIO_REVERB_KIND,
            "Reverb",
            vec![
                slider(REVERB_ROOM_SIZE_KEY, "Room Size", "%", 50.0, 0.0..=100.0, 1.0, 0),
                slider(REVERB_DAMPING_KEY, "Damping", "%", 50.0, 0.0..=100.0, 1.0, 0),
                slider(REVERB_MIX_KEY, "Mix", "%", 25.0, 0.0..=100.0, 1.0, 0),
            ],
        ),
        // Hum notch bank: the root and its harmonics. Defaults chosen by us: 50 Hz (EU mains), Q 10, -30 dB, 4 harmonics.
        spec(
            AUDIO_DE_HUM_KIND,
            "De-Hum",
            vec![
                EffectParamSpec::choice(DE_HUM_MAINS_KEY, "Mains", &["Custom", "50 Hz", "60 Hz"], 1),
                slider(DE_HUM_FREQ_KEY, "Frequency", "Hz", 50.0, 20.0..=20_000.0, 0.1, 1),
                slider(DE_HUM_SLOPE_KEY, "Slope", "", 50.0, 0.0..=100.0, 1.0, 0),
                with_display_scale(slider(DE_HUM_Q_KEY, "Q", "", 1_000.0, 30.0..=3_000.0, 10.0, 1), 0.01),
                slider(DE_HUM_GAIN_KEY, "Gain", "dB", -30.0, -80.0..=5.0, 0.5, 1),
                slider(DE_HUM_HARMONICS_KEY, "Harmonics", "", 4.0, 1.0..=8.0, 1.0, 0),
                EffectParamSpec::checkbox(DE_HUM_LISTEN_KEY, "Listen to Hum", false),
            ],
        ),
        // Rumble: a high-pass (Butterworth) with 12, 24 or 48 dB per octave.
        spec(
            AUDIO_LOW_CUT_KIND,
            "Low Cut",
            vec![
                slider(LOW_CUT_FREQ_KEY, "Frequency", "Hz", 80.0, 20.0..=400.0, 1.0, 0),
                EffectParamSpec::choice(LOW_CUT_SLOPE_KEY, "Slope", &SLOPES, 1),
            ],
        ),
        // Slow level ride: loud speech down, soft speech up, no lift below the speech floor (so no pumping on pauses).
        spec(
            AUDIO_DIALOGUE_LEVELER_KIND,
            "Dialogue Leveler",
            vec![
                EffectParamSpec::choice(LEVELER_PRESET_KEY, "Preset", &AudioLevelerValues::PRESET_TITLES, 0),
                EffectParamSpec::checkbox(LEVELER_REDUCE_LOUD_KEY, "Reduce Loud Dialogue", true),
                EffectParamSpec::checkbox(LEVELER_LIFT_SOFT_KEY, "Lift Soft Dialogue", true),
                EffectParamSpec::checkbox(LEVELER_BACKGROUND_KEY, "Background Reduction", false),
                slider(LEVELER_OUTPUT_GAIN_KEY, "Output Gain", "dB", 0.0, 0.0..=6.0, 0.1, 1),
            ],
        ),
    ];
    v.push(multiband_spec());
    v.push(parametric_eq_spec());
    // Amount default 70 % (the exact value is ours, unsourced).
    v.push(spec(
        AUDIO_ENHANCE_SPEECH_KIND,
        "Enhance Speech",
        vec![
            slider(ENHANCE_AMOUNT_KEY, "Amount", "%", 70.0, 0.0..=100.0, 1.0, 0),
            EffectParamSpec::choice(ENHANCE_PRESET_KEY, "Preset", &AudioEnhanceSpeechValues::PRESET_TITLES, 0),
        ],
    ));
    // Creator tools: High Cut, Stereo Width, Chorus, Notch, Graphic EQ.
    v.push(spec(
        AUDIO_HIGH_CUT_KIND,
        "High Cut",
        vec![
            slider(HIGH_CUT_FREQ_KEY, "Frequency", "Hz", 12_000.0, 1_000.0..=20_000.0, 10.0, 0),
            EffectParamSpec::choice(HIGH_CUT_SLOPE_KEY, "Slope", &SLOPES, 1),
        ],
    ));
    // Mid/side width: 0 = mono, 100 = as recorded, 200 = side doubled. Mono clips stay as they are.
    v.push(spec(
        AUDIO_STEREO_WIDTH_KIND,
        "Stereo Width",
        vec![slider(STEREO_WIDTH_KEY, "Width", "%", 150.0, 0.0..=200.0, 1.0, 0)],
    ));
    // A short delay (about 15 ms) swept by a sine LFO, mixed with the dry sound; right channel runs a quarter cycle later.
    v.push(spec(
        AUDIO_CHORUS_KIND,
        "Chorus",
        vec![
            slider(CHORUS_RATE_KEY, "Rate", "Hz", 0.8, 0.1..=10.0, 0.1, 1),
            slider(CHORUS_DEPTH_KEY, "Depth", "ms", 3.0, 0.0..=10.0, 0.1, 1),
            slider(CHORUS_MIX_KEY, "Mix", "%", 40.0, 0.0..=100.0, 1.0, 0),
        ],
    ));
    // A narrow cut for one tone (hum, whistle, ring). Width is the filter's Q: higher = narrower. Depth 0 = off.
    v.push(spec(
        AUDIO_NOTCH_KIND,
        "Notch",
        vec![
            slider(NOTCH_FREQ_KEY, "Frequency", "Hz", 50.0, 20.0..=20_000.0, 0.1, 1),
            with_display_scale(slider(NOTCH_Q_KEY, "Q", "", 1_000.0, 50.0..=5_000.0, 10.0, 1), 0.01),
            slider(NOTCH_DEPTH_KEY, "Depth", "dB", 30.0, 0.0..=60.0, 0.5, 1),
        ],
    ));
    // Ten fixed octave bands, each -12...+12 dB (0 = untouched), and an output gain.
    let mut bands: Vec<EffectParamSpec> = GRAPHIC_EQ_BAND_KEYS
        .iter()
        .zip(AudioGraphicEQValues::BAND_TITLES)
        .map(|(key, title)| slider(key, title, "dB", 0.0, -12.0..=12.0, 0.1, 1))
        .collect();
    bands.push(slider(GRAPHIC_EQ_OUTPUT_KEY, "Output gain", "dB", 0.0, -24.0..=24.0, 0.1, 1));
    v.push(spec(AUDIO_GRAPHIC_EQ_KIND, "Graphic EQ", bands));
    v.push(spec(
        AUDIO_PITCH_SHIFT_KIND,
        "Pitch Shift",
        vec![
            slider(PITCH_SEMITONES_KEY, "Semitones", "st", 0.0, -12.0..=12.0, 1.0, 0),
            slider(PITCH_CENTS_KEY, "Cents", "ct", 0.0, -100.0..=100.0, 1.0, 0),
            EffectParamSpec::checkbox(PITCH_FORMANTS_KEY, "Preserve Formants", true),
        ],
    ));
    // One choice only on purpose: every other number of the disguise comes from a random stream nobody can dial back.
    v.push(spec(
        AUDIO_DISGUISE_VOICE_KIND,
        "Disguise Voice",
        vec![EffectParamSpec::choice(DISGUISE_VOICE_KEY, "Voice", &AudioDisguiseValues::VOICE_TITLES, 0)],
    ));
    v
}

/// Every audio effect spec, hidden ones included, in panel order.
pub fn every_audio_spec() -> &'static [EffectSpec] {
    static SPECS: OnceLock<Vec<EffectSpec>> = OnceLock::new();
    SPECS.get_or_init(build_every_audio_spec)
}

/// The spec of an audio effect kind.
pub fn audio_spec(kind: &str) -> Option<&'static EffectSpec> {
    every_audio_spec().iter().find(|s| s.kind == kind)
}

/// The "Audio Effects" folder as offered (hidden ones left out) for an explicit switch (tests; `audio` uses the app-level
/// default).
pub fn offered_audio(hiding: bool) -> Vec<EffectSpec> {
    every_audio_spec().iter().filter(|s| !is_hidden_effect_kind(&s.kind, hiding)).cloned().collect()
}

/// The "Audio Effects" folder as offered with the app-level hiding switch.
pub fn audio() -> Vec<EffectSpec> {
    offered_audio(is_active())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn param<'a>(kind: &str, key: &str) -> &'a EffectParamSpec {
        let s = audio_spec(kind).unwrap_or_else(|| panic!("no spec {kind}"));
        s.params.iter().find(|p| p.key == key).unwrap_or_else(|| panic!("no param {key}"))
    }

    #[test]
    fn catalog_has_the_audio_effects_in_panel_order() {
        let kinds: Vec<String> = offered_audio(true).iter().map(|s| s.kind.clone()).collect();
        // Gain and the 3-band EQ are hidden (HiddenCatalog).
        let expect = [
            AUDIO_NOISE_REDUCTION_KIND,
            AUDIO_COMPRESSOR_KIND,
            AUDIO_DE_ESSER_KIND,
            AUDIO_DE_REVERB_KIND,
            AUDIO_LIMITER_KIND,
            AUDIO_NOISE_GATE_KIND,
            AUDIO_DELAY_KIND,
            AUDIO_REVERB_KIND,
            AUDIO_DE_HUM_KIND,
            AUDIO_LOW_CUT_KIND,
            AUDIO_DIALOGUE_LEVELER_KIND,
            AUDIO_MULTIBAND_KIND,
            AUDIO_PARAMETRIC_EQ_KIND,
            AUDIO_ENHANCE_SPEECH_KIND,
            AUDIO_HIGH_CUT_KIND,
            AUDIO_STEREO_WIDTH_KIND,
            AUDIO_CHORUS_KIND,
            AUDIO_NOTCH_KIND,
            AUDIO_GRAPHIC_EQ_KIND,
            AUDIO_PITCH_SHIFT_KIND,
            AUDIO_DISGUISE_VOICE_KIND,
        ];
        assert_eq!(kinds, expect);
        assert!(kinds.iter().all(|k| is_audio_kind(k)));
        assert_eq!(offered_audio(false).len(), expect.len() + 2);
        assert_eq!(every_audio_spec().len(), expect.len() + 2);
    }

    #[test]
    fn defaults_and_ranges_of_the_catalog() {
        let p = param(AUDIO_NOISE_GATE_KIND, GATE_HOLD_KEY);
        assert_eq!((p.default_value, p.range.clone()), (0.0, 0.0..=1_000.0));
        let q = param(AUDIO_DE_HUM_KIND, DE_HUM_Q_KEY);
        assert_eq!((q.default_value, q.display_scale), (1_000.0, 0.01));
        assert_eq!(param(AUDIO_DE_ESSER_KIND, DE_ESS_RANGE_KEY).default_value, 1.0);
        assert_eq!(param(AUDIO_PITCH_SHIFT_KIND, PITCH_FORMANTS_KEY).default_value, 1.0);
        assert_eq!(param(AUDIO_MULTIBAND_KIND, MB_LIMITER_ON_KEY).default_value, 0.0);
        assert_eq!(param(AUDIO_PARAMETRIC_EQ_KIND, "hpOn").default_value, 0.0);
        assert_eq!(param(AUDIO_PARAMETRIC_EQ_KIND, "lsQ").default_value, 0.71);
        assert!(audio_spec(AUDIO_PARAMETRIC_EQ_KIND).is_some_and(|s| !s.params.iter().any(|p| p.key == "hpGain")));
        assert_eq!(audio_spec(AUDIO_GRAPHIC_EQ_KIND).map(|s| s.params.len()), Some(11));
        assert_eq!(audio_spec(AUDIO_MULTIBAND_KIND).map(|s| s.params.len()), Some(1 + 3 + 20 + 5 + 8 + 1));
    }

    #[test]
    fn setup_only_keys_are_solo_bypass_and_link() {
        let k = mb_setup_only_keys();
        assert!(k.contains("b1solo") && k.contains("b4byp") && k.contains("link"));
        assert_eq!(k.len(), 9);
    }

    /// The scalar closure of a test: every key reads its catalog default.
    fn defaults(kind: &str) -> impl Fn(&str, Time) -> f64 + '_ {
        move |key, _| param(kind, key).default_value
    }

    fn stage(kind: &str) -> Option<AudioFXStage> {
        let e = ClipEffect::new(Id::from_u128(1), kind);
        e.audio_stage(Time::ZERO, &defaults(kind))
    }

    #[test]
    fn stages_read_the_catalog_defaults() {
        assert_eq!(
            stage(AUDIO_NOISE_GATE_KIND),
            Some(AudioFXStage::NoiseGate {
                threshold_db: -40.0,
                attack_ms: 1.0,
                release_ms: 100.0,
                range_db: 60.0,
                hold_ms: 0.0
            })
        );
        assert_eq!(stage(AUDIO_DELAY_KIND), Some(AudioFXStage::Delay { time_ms: 350.0, feedback: 0.35, mix: 0.3 }));
        assert_eq!(stage(AUDIO_LOW_CUT_KIND), Some(AudioFXStage::LowCut { frequency_hz: 80.0, order: 2 }));
        assert_eq!(
            stage(AUDIO_DE_HUM_KIND),
            Some(AudioFXStage::DeHum {
                frequency_hz: 50.0,
                q: 10.0,
                gain_db: -30.0,
                harmonics: 4,
                slope: 0.5,
                listen: false
            })
        );
        assert_eq!(stage(AUDIO_DISGUISE_VOICE_KIND), Some(AudioFXStage::DisguiseVoice { voice: 0, at: Time::ZERO }));
        assert_eq!(stage("blur"), None);
        let Some(AudioFXStage::Multiband(m)) = stage(AUDIO_MULTIBAND_KIND) else { panic!("multiband") };
        assert!(!m.limiter_on && m.band_solo == 0 && m.band_bypass == 0 && m.crossover_hz == [120.0, 700.0, 3_000.0]);
        assert_eq!(m.limiter_gain_db(), 9.9);
        let Some(AudioFXStage::ParametricEq(q)) = stage(AUDIO_PARAMETRIC_EQ_KIND) else { panic!("peq") };
        assert!(!q.band(0).on && q.band(0).q == PEQ_CUT_Q && q.band(1).on && q.band(8).hz == 16_000.0);
        assert_eq!(q.band(99), q.band(8));
    }

    #[test]
    fn multiband_masks_follow_the_flags() {
        let e = ClipEffect::new(Id::from_u128(1), AUDIO_MULTIBAND_KIND);
        let scalar = |key: &str, _t: Time| match key {
            "b2solo" | "b4byp" => 1.0,
            k => param(AUDIO_MULTIBAND_KIND, k).default_value,
        };
        let Some(AudioFXStage::Multiband(m)) = e.audio_stage(Time::ZERO, &scalar) else { panic!("multiband") };
        assert!(m.is_soloed(1) && !m.is_soloed(0) && m.is_bypassed(3) && !m.is_bypassed(2));
    }

    #[test]
    fn graphic_eq_bands_read_and_write_inside_the_range_only() {
        let mut g = AudioGraphicEQValues::from_gains(&[1.0, 2.0], 3.0);
        assert_eq!((g.get(0), g.get(1), g.get(2), g.get(99), g.output_db), (1.0, 2.0, 0.0, 0.0, 3.0));
        g.set(99, 5.0);
        g.set(9, 4.0);
        assert_eq!(g.get(9), 4.0);
        assert_eq!(AudioGraphicEQValues::from_gains(&[1.0; 20], 0.0).get(9), 1.0);
    }

    #[test]
    fn enhance_speech_scales_the_recipe_with_the_amount() {
        let none = AudioEnhanceSpeechValues { amount: 0.0, preset: 0 }.recipe();
        assert_eq!((none.low_cut_hz, none.denoise, none.mud_db, none.leveling), (20.0, 0.0, 0.0, 0.0));
        let full = AudioEnhanceSpeechValues { amount: 2.0, preset: 2 }.recipe();
        assert_eq!((full.low_cut_hz, full.denoise, full.dereverb, full.decay_seconds), (90.0, 0.7, 0.9, 1.0));
        assert_eq!(AudioEnhanceSpeechValues::LATENCY_SAMPLES, 480 + 1_024);
    }

    #[test]
    fn leveler_presets_and_pitch_numbers() {
        let v = |preset| AudioLevelerValues {
            preset,
            reduce_loud: true,
            lift_soft: true,
            background: false,
            output_gain_db: 0.0,
        };
        assert_eq!(v(2).params().floor_db, -58.0);
        assert_eq!(v(9).params(), v(0).params());
        assert!((AudioPitchValues::ratio(12.0) - 2.0).abs() < 1e-12);
        assert_eq!(AudioPitchValues::sample(Time::new(1, 2), 48_000), 24_000);
        assert_eq!(AudioPitchValues::sample(Time::new(-1, 48_000), 48_000), -1);
        assert_eq!(AudioPitchValues::sample(Time::new(1, 3), 0), 0);
        assert_eq!(AudioPitchValues::sample(Time::new(1, 96_000), 48_000), 1); // half a sample rounds up
    }
}
