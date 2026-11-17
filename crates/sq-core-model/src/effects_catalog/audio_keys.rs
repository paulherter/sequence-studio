// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioEffects*.swift (kind and parameter key strings of `extension ClipEffect`; stored strings: never rename)

use crate::ClipEffect;

impl ClipEffect {
    // AudioEffects.swift
    /// Stored prefix string `audio.`.
    pub const AUDIO_KIND_PREFIX: &'static str = "audio.";
    /// Stored kind string `audio.noiseReduction`.
    pub const AUDIO_NOISE_REDUCTION_KIND: &'static str = "audio.noiseReduction";
    /// Stored key string `amount`.
    pub const NOISE_AMOUNT_REDUCTION_KEY: &'static str = "amount";
    /// Stored kind string `audio.eq`.
    pub const AUDIO_EQ_KIND: &'static str = "audio.eq";
    /// Stored key string `lowGain`.
    pub const EQ_LOW_GAIN_KEY: &'static str = "lowGain";
    /// Stored key string `lowFreq`.
    pub const EQ_LOW_FREQ_KEY: &'static str = "lowFreq";
    /// Stored key string `midGain`.
    pub const EQ_MID_GAIN_KEY: &'static str = "midGain";
    /// Stored key string `midFreq`.
    pub const EQ_MID_FREQ_KEY: &'static str = "midFreq";
    /// Stored key string `midQ`.
    pub const EQ_MID_Q_KEY: &'static str = "midQ";
    /// Stored key string `highGain`.
    pub const EQ_HIGH_GAIN_KEY: &'static str = "highGain";
    /// Stored key string `highFreq`.
    pub const EQ_HIGH_FREQ_KEY: &'static str = "highFreq";
    /// Stored kind string `audio.compressor`.
    pub const AUDIO_COMPRESSOR_KIND: &'static str = "audio.compressor";
    /// Stored key string `threshold`.
    pub const COMP_THRESHOLD_KEY: &'static str = "threshold";
    /// Stored key string `ratio`.
    pub const COMP_RATIO_KEY: &'static str = "ratio";
    /// Stored key string `attack`.
    pub const COMP_ATTACK_KEY: &'static str = "attack";
    /// Stored key string `release`.
    pub const COMP_RELEASE_KEY: &'static str = "release";
    /// Stored key string `makeup`.
    pub const COMP_MAKEUP_KEY: &'static str = "makeup";
    /// Stored kind string `audio.deEsser`.
    pub const AUDIO_DE_ESSER_KIND: &'static str = "audio.deEsser";
    /// Stored key string `reduction`.
    pub const DE_ESS_REDUCTION_KEY: &'static str = "reduction";
    /// Stored key string `sensitivity`.
    pub const DE_ESS_SENSITIVITY_KEY: &'static str = "sensitivity";
    /// Stored key string `frequency`.
    pub const DE_ESS_FREQUENCY_KEY: &'static str = "frequency";
    /// Stored key string `range`.
    pub const DE_ESS_RANGE_KEY: &'static str = "range";
    /// Stored key string `speed`.
    pub const DE_ESS_SPEED_KEY: &'static str = "speed";
    /// Stored key string `listen`.
    pub const DE_ESS_LISTEN_KEY: &'static str = "listen";
    /// Stored kind string `audio.deReverb`.
    pub const AUDIO_DE_REVERB_KIND: &'static str = "audio.deReverb";
    /// Stored key string `amount`.
    pub const DE_REVERB_AMOUNT_KEY: &'static str = "amount";
    /// Stored key string `decay`.
    pub const DE_REVERB_DECAY_KEY: &'static str = "decay";
    /// Stored key string `tone`.
    pub const DE_REVERB_TONE_KEY: &'static str = "tone";
    /// Stored kind string `audio.gain`.
    pub const AUDIO_GAIN_KIND: &'static str = "audio.gain";
    /// Stored key string `gain`.
    pub const AUDIO_GAIN_KEY: &'static str = "gain";
    /// Stored kind string `audio.limiter`.
    pub const AUDIO_LIMITER_KIND: &'static str = "audio.limiter";
    /// Stored key string `inputGain`.
    pub const LIMITER_INPUT_KEY: &'static str = "inputGain";
    /// Stored key string `ceiling`.
    pub const LIMITER_CEILING_KEY: &'static str = "ceiling";
    /// Stored kind string `audio.noiseGate`.
    pub const AUDIO_NOISE_GATE_KIND: &'static str = "audio.noiseGate";
    /// Stored key string `threshold`.
    pub const GATE_THRESHOLD_KEY: &'static str = "threshold";
    /// Stored key string `attack`.
    pub const GATE_ATTACK_KEY: &'static str = "attack";
    /// Stored key string `release`.
    pub const GATE_RELEASE_KEY: &'static str = "release";
    /// Stored key string `range`.
    pub const GATE_RANGE_KEY: &'static str = "range";
    /// Stored key string `hold`.
    pub const GATE_HOLD_KEY: &'static str = "hold";
    /// Stored kind string `audio.delay`.
    pub const AUDIO_DELAY_KIND: &'static str = "audio.delay";
    /// Stored key string `time`.
    pub const DELAY_TIME_KEY: &'static str = "time";
    /// Stored key string `feedback`.
    pub const DELAY_FEEDBACK_KEY: &'static str = "feedback";
    /// Stored key string `mix`.
    pub const DELAY_MIX_KEY: &'static str = "mix";
    /// Stored kind string `audio.reverb`.
    pub const AUDIO_REVERB_KIND: &'static str = "audio.reverb";
    /// Stored key string `roomSize`.
    pub const REVERB_ROOM_SIZE_KEY: &'static str = "roomSize";
    /// Stored key string `damping`.
    pub const REVERB_DAMPING_KEY: &'static str = "damping";
    /// Stored key string `mix`.
    pub const REVERB_MIX_KEY: &'static str = "mix";
    /// Stored kind string `audio.deHum`.
    pub const AUDIO_DE_HUM_KIND: &'static str = "audio.deHum";
    /// Stored key string `mains`.
    pub const DE_HUM_MAINS_KEY: &'static str = "mains";
    /// Stored key string `frequency`.
    pub const DE_HUM_FREQ_KEY: &'static str = "frequency";
    /// Stored key string `slope`.
    pub const DE_HUM_SLOPE_KEY: &'static str = "slope";
    /// Stored key string `q`.
    pub const DE_HUM_Q_KEY: &'static str = "q";
    /// Stored key string `gain`.
    pub const DE_HUM_GAIN_KEY: &'static str = "gain";
    /// Stored key string `harmonics`.
    pub const DE_HUM_HARMONICS_KEY: &'static str = "harmonics";
    /// Stored key string `listen`.
    pub const DE_HUM_LISTEN_KEY: &'static str = "listen";
    /// Stored kind string `audio.lowCut`.
    pub const AUDIO_LOW_CUT_KIND: &'static str = "audio.lowCut";
    /// Stored key string `frequency`.
    pub const LOW_CUT_FREQ_KEY: &'static str = "frequency";
    /// Stored key string `slope`.
    pub const LOW_CUT_SLOPE_KEY: &'static str = "slope";
    /// Stored kind string `audio.dialogueLeveler`.
    pub const AUDIO_DIALOGUE_LEVELER_KIND: &'static str = "audio.dialogueLeveler";
    /// Stored key string `preset`.
    pub const LEVELER_PRESET_KEY: &'static str = "preset";
    /// Stored key string `reduceLoud`.
    pub const LEVELER_REDUCE_LOUD_KEY: &'static str = "reduceLoud";
    /// Stored key string `liftSoft`.
    pub const LEVELER_LIFT_SOFT_KEY: &'static str = "liftSoft";
    /// Stored key string `background`.
    pub const LEVELER_BACKGROUND_KEY: &'static str = "background";
    /// Stored key string `outputGain`.
    pub const LEVELER_OUTPUT_GAIN_KEY: &'static str = "outputGain";
    /// Stored kind string `audio.highCut`.
    pub const AUDIO_HIGH_CUT_KIND: &'static str = "audio.highCut";
    /// Stored key string `frequency`.
    pub const HIGH_CUT_FREQ_KEY: &'static str = "frequency";
    /// Stored key string `slope`.
    pub const HIGH_CUT_SLOPE_KEY: &'static str = "slope";
    /// Stored kind string `audio.stereoWidth`.
    pub const AUDIO_STEREO_WIDTH_KIND: &'static str = "audio.stereoWidth";
    /// Stored key string `width`.
    pub const STEREO_WIDTH_KEY: &'static str = "width";
    /// Stored kind string `audio.chorus`.
    pub const AUDIO_CHORUS_KIND: &'static str = "audio.chorus";
    /// Stored key string `rate`.
    pub const CHORUS_RATE_KEY: &'static str = "rate";
    /// Stored key string `depth`.
    pub const CHORUS_DEPTH_KEY: &'static str = "depth";
    /// Stored key string `mix`.
    pub const CHORUS_MIX_KEY: &'static str = "mix";
    /// Stored kind string `audio.notch`.
    pub const AUDIO_NOTCH_KIND: &'static str = "audio.notch";
    /// Stored key string `frequency`.
    pub const NOTCH_FREQ_KEY: &'static str = "frequency";
    /// Stored key string `q`.
    pub const NOTCH_Q_KEY: &'static str = "q";
    /// Stored key string `depth`.
    pub const NOTCH_DEPTH_KEY: &'static str = "depth";
    /// Stored kind string `audio.graphicEQ`.
    pub const AUDIO_GRAPHIC_EQ_KIND: &'static str = "audio.graphicEQ";
    /// Stored key string `output`.
    pub const GRAPHIC_EQ_OUTPUT_KEY: &'static str = "output";

    // AudioEffectsPitch.swift
    /// Stored kind string `audio.pitchShift`.
    pub const AUDIO_PITCH_SHIFT_KIND: &'static str = "audio.pitchShift";
    /// Stored key string `semitones`.
    pub const PITCH_SEMITONES_KEY: &'static str = "semitones";
    /// Stored key string `cents`.
    pub const PITCH_CENTS_KEY: &'static str = "cents";
    /// Stored key string `formants`.
    pub const PITCH_FORMANTS_KEY: &'static str = "formants";
    /// Stored kind string `audio.disguiseVoice`.
    pub const AUDIO_DISGUISE_VOICE_KIND: &'static str = "audio.disguiseVoice";
    /// Stored key string `voice`.
    pub const DISGUISE_VOICE_KEY: &'static str = "voice";

    // AudioEffectsVoiceChain.swift
    /// Stored kind string `audio.multiband`.
    pub const AUDIO_MULTIBAND_KIND: &'static str = "audio.multiband";
    /// Stored key string `outGain`.
    pub const MB_OUTPUT_GAIN_KEY: &'static str = "outGain";
    /// Stored key string `limOn`.
    pub const MB_LIMITER_ON_KEY: &'static str = "limOn";
    /// Stored key string `limThr`.
    pub const MB_LIMITER_THRESHOLD_KEY: &'static str = "limThr";
    /// Stored key string `limMargin`.
    pub const MB_LIMITER_MARGIN_KEY: &'static str = "limMargin";
    /// Stored key string `limRel`.
    pub const MB_LIMITER_RELEASE_KEY: &'static str = "limRel";
    /// Stored key string `limAtk`.
    pub const MB_LIMITER_ATTACK_KEY: &'static str = "limAtk";
    /// Stored key string `link`.
    pub const MB_LINK_KEY: &'static str = "link";
    /// Stored kind string `audio.parametricEQ`.
    pub const AUDIO_PARAMETRIC_EQ_KIND: &'static str = "audio.parametricEQ";

    // AudioEffectsEnhanceSpeech.swift
    /// Stored kind string `audio.enhanceSpeech`.
    pub const AUDIO_ENHANCE_SPEECH_KIND: &'static str = "audio.enhanceSpeech";
    /// Stored key string `amount`.
    pub const ENHANCE_AMOUNT_KEY: &'static str = "amount";
    /// Stored key string `preset`.
    pub const ENHANCE_PRESET_KEY: &'static str = "preset";

    /// Graphic EQ band keys, low to high (v76).
    pub const GRAPHIC_EQ_BAND_KEYS: [&'static str; 10] =
        ["band31", "band63", "band125", "band250", "band500", "band1k", "band2k", "band4k", "band8k", "band16k"];
    /// The Parametric EQ filters, low to high (key prefix of `peq_key`).
    pub const PEQ_FILTER_IDS: [&'static str; 9] = ["hp", "ls", "b1", "b2", "b3", "b4", "b5", "hs", "lp"];
    /// Kinds that need project format v46 (older builds would drop them).
    pub const VOICE_CHAIN_KINDS: [&'static str; 2] = [Self::AUDIO_MULTIBAND_KIND, Self::AUDIO_PARAMETRIC_EQ_KIND];

    /// Multiband crossover `i` in 1...3.
    pub fn mb_crossover_key(i: usize) -> String {
        format!("x{i}")
    }
    /// Multiband band threshold, `i` in 1...4.
    pub fn mb_threshold_key(i: usize) -> String {
        format!("thr{i}")
    }
    /// Multiband band ratio.
    pub fn mb_ratio_key(i: usize) -> String {
        format!("ratio{i}")
    }
    /// Multiband band attack.
    pub fn mb_attack_key(i: usize) -> String {
        format!("atk{i}")
    }
    /// Multiband band release.
    pub fn mb_release_key(i: usize) -> String {
        format!("rel{i}")
    }
    /// Multiband band gain.
    pub fn mb_gain_key(i: usize) -> String {
        format!("gain{i}")
    }
    /// Multiband band solo: only soloed bands are heard while any is set.
    pub fn mb_solo_key(i: usize) -> String {
        format!("b{i}solo")
    }
    /// Multiband band bypass: the band passes uncompressed and without its band gain.
    pub fn mb_bypass_key(i: usize) -> String {
        format!("b{i}byp")
    }
    /// Parametric EQ key of filter `id` and `field` (On, Freq, Gain, Q).
    pub fn peq_key(id: &str, field: &str) -> String {
        format!("{id}{field}")
    }

    /// Is `kind` an audio effect kind (runs on the sound of an audio clip, never on the picture)?
    pub fn is_audio_kind(kind: &str) -> bool {
        kind.starts_with(Self::AUDIO_KIND_PREFIX)
    }

    /// An audio effect.
    pub fn is_audio(&self) -> bool {
        Self::is_audio_kind(&self.kind)
    }
}
