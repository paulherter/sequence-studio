// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioEffects*.swift (catalog entries)

use super::util::{p, spec};
use crate::{ClipEffect, EffectParamSpec, EffectSpec};

const DE_ESSER_RANGE_TITLES: [&str; 3] = ["Narrow", "Wide", "All HF"];
const DE_ESSER_SPEED_TITLES: [&str; 3] = ["Fast", "Medium", "Slow"];
const LEVELER_PRESET_TITLES: [&str; 4] =
    ["Allow wider dynamics", "More lift for low levels", "Lift soft whispery sources", "Optimize moderate levels"];
const ENHANCE_SPEECH_PRESET_TITLES: [&str; 4] = ["Balanced", "Noisy Location", "Echoey Room", "Light Touch"];
const DISGUISE_VOICE_TITLES: [&str; 2] = ["Lower", "Higher"];
const GRAPHIC_EQ_BAND_TITLES: [&str; 10] =
    ["31.5 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"];

/// The Effects panel's "Audio Effects" folder, in panel order (Swift `everyAudioSpec`).
pub(super) fn every() -> Vec<EffectSpec> {
    let mut all = vec![
        // RNNoise wet/dry: 0 = off, 100 = fully denoised. Adds 10 ms of latency the mixer compensates.
        spec(
            ClipEffect::AUDIO_NOISE_REDUCTION_KIND,
            "Noise Reduction",
            vec![p(ClipEffect::NOISE_AMOUNT_REDUCTION_KEY, "Amount", "%", 50.0, 0.0, 100.0, 1.0, 0)],
        ),
        // Three-band parametric EQ: low shelf, mid peak, high shelf (RBJ).
        spec(
            ClipEffect::AUDIO_EQ_KIND,
            "EQ (3 band)",
            vec![
                p(ClipEffect::EQ_LOW_GAIN_KEY, "Low Gain", "dB", 0.0, -24.0, 24.0, 0.1, 1),
                p(ClipEffect::EQ_LOW_FREQ_KEY, "Low Frequency", "Hz", 100.0, 20.0, 1_000.0, 1.0, 0),
                p(ClipEffect::EQ_MID_GAIN_KEY, "Mid Gain", "dB", 0.0, -24.0, 24.0, 0.1, 1),
                p(ClipEffect::EQ_MID_FREQ_KEY, "Mid Frequency", "Hz", 1_000.0, 100.0, 10_000.0, 1.0, 0),
                p(ClipEffect::EQ_MID_Q_KEY, "Mid Q", "", 1.0, 0.1, 10.0, 0.01, 2),
                p(ClipEffect::EQ_HIGH_GAIN_KEY, "High Gain", "dB", 0.0, -24.0, 24.0, 0.1, 1),
                p(ClipEffect::EQ_HIGH_FREQ_KEY, "High Frequency", "Hz", 8_000.0, 1_000.0, 20_000.0, 1.0, 0),
            ],
        ),
        // Single-band peak compressor (the detector of the 4-band compressor).
        spec(
            ClipEffect::AUDIO_COMPRESSOR_KIND,
            "Compressor",
            vec![
                p(ClipEffect::COMP_THRESHOLD_KEY, "Threshold", "dB", -20.0, -60.0, 0.0, 0.1, 1),
                p(ClipEffect::COMP_RATIO_KEY, "Ratio", ":1", 4.0, 1.0, 20.0, 0.1, 1),
                p(ClipEffect::COMP_ATTACK_KEY, "Attack", "ms", 10.0, 0.1, 200.0, 0.1, 1),
                p(ClipEffect::COMP_RELEASE_KEY, "Release", "ms", 100.0, 10.0, 2_000.0, 1.0, 0),
                p(ClipEffect::COMP_MAKEUP_KEY, "Makeup Gain", "dB", 0.0, 0.0, 24.0, 0.1, 1),
            ],
        ),
        // Split-band de-esser: Reduction = the most the highs above the split are pulled down; Sensitivity = how early it reacts.
        // Frequency / Range / Speed / Listen follow the Resolve De-Esser's controls (target frequency, Narrow / Wide / All HF,
        // Slow / Medium / Fast, Listen to Ess; docs/research/AUDIO-EFFECTS.md). Defaults (7 kHz, Wide, Medium) are the values
        // the effect always had, so older projects sound the same. The 2-10 kHz span and the split ratios per Range and the
        // speed times are our own (unsourced).
        spec(
            ClipEffect::AUDIO_DE_ESSER_KIND,
            "De-Esser",
            vec![
                p(ClipEffect::DE_ESS_REDUCTION_KEY, "Reduction", "dB", 10.0, 0.0, 24.0, 0.5, 1),
                p(ClipEffect::DE_ESS_SENSITIVITY_KEY, "Sensitivity", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::DE_ESS_FREQUENCY_KEY, "Frequency", "Hz", 7_000.0, 2_000.0, 10_000.0, 50.0, 0),
                EffectParamSpec::choice(ClipEffect::DE_ESS_RANGE_KEY, "Range", &DE_ESSER_RANGE_TITLES, 1),
                EffectParamSpec::choice(ClipEffect::DE_ESS_SPEED_KEY, "Reaction", &DE_ESSER_SPEED_TITLES, 1),
                EffectParamSpec::checkbox(ClipEffect::DE_ESS_LISTEN_KEY, "Listen to Ess", false),
            ],
        ),
        // Late-reverb suppression (spectral): Amount = how much of the tail goes, Decay = the room's reverb time the estimate
        // assumes, Tone = which end of the spectrum is reduced more. Adds a fixed delay (`AudioDeReverbValues.latencySamples`).
        // Premiere's Reduce Reverb documents only Amount (0-100 %); Decay and Tone are ours, defaults unsourced.
        spec(
            ClipEffect::AUDIO_DE_REVERB_KIND,
            "De-Reverb",
            vec![
                p(ClipEffect::DE_REVERB_AMOUNT_KEY, "Amount", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::DE_REVERB_DECAY_KEY, "Decay", "ms", 600.0, 150.0, 2_500.0, 10.0, 0),
                p(ClipEffect::DE_REVERB_TONE_KEY, "Tone", "", 0.0, -100.0, 100.0, 1.0, 0),
            ],
        ),
        spec(
            ClipEffect::AUDIO_GAIN_KIND,
            "Gain",
            vec![p(ClipEffect::AUDIO_GAIN_KEY, "Gain", "dB", 0.0, -60.0, 24.0, 0.1, 1)],
        ),
        // Input gain into a zero-latency peak limiter (the master limiter's code).
        spec(
            ClipEffect::AUDIO_LIMITER_KIND,
            "Limiter",
            vec![
                p(ClipEffect::LIMITER_INPUT_KEY, "Input Boost", "dB", 0.0, 0.0, 24.0, 0.1, 1),
                p(ClipEffect::LIMITER_CEILING_KEY, "Maximum Amplitude", "dB", -1.0, -24.0, 0.0, 0.1, 1),
            ],
        ),
        // Downward gate: closes below Threshold, Range = how far it pulls the sound down while closed.
        spec(
            ClipEffect::AUDIO_NOISE_GATE_KIND,
            "Noise Gate",
            vec![
                p(ClipEffect::GATE_THRESHOLD_KEY, "Threshold", "dB", -40.0, -80.0, 0.0, 0.1, 1),
                p(ClipEffect::GATE_ATTACK_KEY, "Attack", "ms", 1.0, 0.1, 100.0, 0.1, 1),
                p(ClipEffect::GATE_HOLD_KEY, "Hold", "ms", 0.0, 0.0, 1_000.0, 1.0, 0),
                p(ClipEffect::GATE_RELEASE_KEY, "Release", "ms", 100.0, 5.0, 2_000.0, 1.0, 0),
                p(ClipEffect::GATE_RANGE_KEY, "Range", "dB", 60.0, 0.0, 80.0, 0.5, 1),
            ],
        ),
        // Feedback delay (2 s line).
        spec(
            ClipEffect::AUDIO_DELAY_KIND,
            "Delay",
            vec![
                p(ClipEffect::DELAY_TIME_KEY, "Delay", "ms", 350.0, 1.0, 2_000.0, 1.0, 0),
                p(ClipEffect::DELAY_FEEDBACK_KEY, "Feedback", "%", 35.0, 0.0, 95.0, 1.0, 0),
                p(ClipEffect::DELAY_MIX_KEY, "Mix", "%", 30.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        // Freeverb-style room.
        spec(
            ClipEffect::AUDIO_REVERB_KIND,
            "Reverb",
            vec![
                p(ClipEffect::REVERB_ROOM_SIZE_KEY, "Room Size", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::REVERB_DAMPING_KEY, "Damping", "%", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::REVERB_MIX_KEY, "Mix", "%", 25.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        // Hum notch bank: the root and its harmonics (mains 50 / 60 Hz or Custom = Frequency). Defaults chosen by us (the
        // reference sheets store ranges only): 50 Hz (EU mains), Q 10, -30 dB, 4 harmonics, slope 50 = equal depth.
        spec(
            ClipEffect::AUDIO_DE_HUM_KIND,
            "De-Hum",
            vec![
                EffectParamSpec::choice(ClipEffect::DE_HUM_MAINS_KEY, "Mains", &["Custom", "50 Hz", "60 Hz"], 1),
                p(ClipEffect::DE_HUM_FREQ_KEY, "Frequency", "Hz", 50.0, 20.0, 20_000.0, 0.1, 1),
                p(ClipEffect::DE_HUM_SLOPE_KEY, "Slope", "", 50.0, 0.0, 100.0, 1.0, 0),
                p(ClipEffect::DE_HUM_Q_KEY, "Q", "", 1_000.0, 30.0, 3_000.0, 10.0, 1).display_scale(0.01),
                p(ClipEffect::DE_HUM_GAIN_KEY, "Gain", "dB", -30.0, -80.0, 5.0, 0.5, 1),
                p(ClipEffect::DE_HUM_HARMONICS_KEY, "Harmonics", "", 4.0, 1.0, 8.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::DE_HUM_LISTEN_KEY, "Listen to Hum", false),
            ],
        ),
        // Rumble: a high-pass (Butterworth) with 12, 24 or 48 dB per octave.
        spec(
            ClipEffect::AUDIO_LOW_CUT_KIND,
            "Low Cut",
            vec![
                p(ClipEffect::LOW_CUT_FREQ_KEY, "Frequency", "Hz", 80.0, 20.0, 400.0, 1.0, 0),
                EffectParamSpec::choice(
                    ClipEffect::LOW_CUT_SLOPE_KEY,
                    "Slope",
                    &["12 dB/oct", "24 dB/oct", "48 dB/oct"],
                    1,
                ),
            ],
        ),
        // Slow level ride: loud speech down, soft speech up, no lift below the speech floor (so no pumping on pauses).
        spec(
            ClipEffect::AUDIO_DIALOGUE_LEVELER_KIND,
            "Dialogue Leveler",
            vec![
                EffectParamSpec::choice(ClipEffect::LEVELER_PRESET_KEY, "Preset", &LEVELER_PRESET_TITLES, 0),
                EffectParamSpec::checkbox(ClipEffect::LEVELER_REDUCE_LOUD_KEY, "Reduce Loud Dialogue", true),
                EffectParamSpec::checkbox(ClipEffect::LEVELER_LIFT_SOFT_KEY, "Lift Soft Dialogue", true),
                EffectParamSpec::checkbox(ClipEffect::LEVELER_BACKGROUND_KEY, "Background Reduction", false),
                p(ClipEffect::LEVELER_OUTPUT_GAIN_KEY, "Output Gain", "dB", 0.0, 0.0, 6.0, 0.1, 1),
            ],
        ),
    ];
    all.push(multiband());
    all.push(parametric_eq());
    all.push(enhance_speech());
    all.extend(creator());
    all.extend(pitch());
    all
}

/// High Cut (low-pass, the Low Cut's counterpart for hiss and harsh highs), Stereo Width (mid/side), Chorus, Notch and
/// Graphic EQ.
fn creator() -> Vec<EffectSpec> {
    let mut bands: Vec<EffectParamSpec> = ClipEffect::GRAPHIC_EQ_BAND_KEYS
        .iter()
        .zip(GRAPHIC_EQ_BAND_TITLES)
        .map(|(key, title)| p(key, title, "dB", 0.0, -12.0, 12.0, 0.1, 1))
        .collect();
    bands.push(p(ClipEffect::GRAPHIC_EQ_OUTPUT_KEY, "Output gain", "dB", 0.0, -24.0, 24.0, 0.1, 1));
    vec![
        spec(
            ClipEffect::AUDIO_HIGH_CUT_KIND,
            "High Cut",
            vec![
                p(ClipEffect::HIGH_CUT_FREQ_KEY, "Frequency", "Hz", 12_000.0, 1_000.0, 20_000.0, 10.0, 0),
                EffectParamSpec::choice(
                    ClipEffect::HIGH_CUT_SLOPE_KEY,
                    "Slope",
                    &["12 dB/oct", "24 dB/oct", "48 dB/oct"],
                    1,
                ),
            ],
        ),
        // Mid/side width: 0 = mono, 100 = as recorded, 200 = side doubled. Mono clips stay as they are.
        spec(
            ClipEffect::AUDIO_STEREO_WIDTH_KIND,
            "Stereo Width",
            vec![p(ClipEffect::STEREO_WIDTH_KEY, "Width", "%", 150.0, 0.0, 200.0, 1.0, 0)],
        ),
        // A short delay (about 15 ms) swept by a sine LFO, mixed with the dry sound; right channel runs a quarter cycle later.
        spec(
            ClipEffect::AUDIO_CHORUS_KIND,
            "Chorus",
            vec![
                p(ClipEffect::CHORUS_RATE_KEY, "Rate", "Hz", 0.8, 0.1, 10.0, 0.1, 1),
                p(ClipEffect::CHORUS_DEPTH_KEY, "Depth", "ms", 3.0, 0.0, 10.0, 0.1, 1),
                p(ClipEffect::CHORUS_MIX_KEY, "Mix", "%", 40.0, 0.0, 100.0, 1.0, 0),
            ],
        ),
        // A narrow cut for one tone (hum, whistle, ring). Width is the filter's Q: higher = narrower. Depth 0 = off.
        spec(
            ClipEffect::AUDIO_NOTCH_KIND,
            "Notch",
            vec![
                p(ClipEffect::NOTCH_FREQ_KEY, "Frequency", "Hz", 50.0, 20.0, 20_000.0, 0.1, 1),
                p(ClipEffect::NOTCH_Q_KEY, "Q", "", 1_000.0, 50.0, 5_000.0, 10.0, 1).display_scale(0.01),
                p(ClipEffect::NOTCH_DEPTH_KEY, "Depth", "dB", 30.0, 0.0, 60.0, 0.5, 1),
            ],
        ),
        // Ten fixed octave bands, each -12...+12 dB (0 = untouched), and an output gain.
        spec(ClipEffect::AUDIO_GRAPHIC_EQ_KIND, "Graphic EQ", bands),
    ]
}

/// Pitch Shift and Disguise Voice.
fn pitch() -> Vec<EffectSpec> {
    vec![
        spec(
            ClipEffect::AUDIO_PITCH_SHIFT_KIND,
            "Pitch Shift",
            vec![
                p(ClipEffect::PITCH_SEMITONES_KEY, "Semitones", "st", 0.0, -12.0, 12.0, 1.0, 0),
                p(ClipEffect::PITCH_CENTS_KEY, "Cents", "ct", 0.0, -100.0, 100.0, 1.0, 0),
                EffectParamSpec::checkbox(ClipEffect::PITCH_FORMANTS_KEY, "Preserve Formants", true),
            ],
        ),
        // One choice only on purpose: every other number of the disguise comes from a random stream nobody can dial back.
        spec(
            ClipEffect::AUDIO_DISGUISE_VOICE_KIND,
            "Disguise Voice",
            vec![EffectParamSpec::choice(ClipEffect::DISGUISE_VOICE_KEY, "Voice", &DISGUISE_VOICE_TITLES, 0)],
        ),
    ]
}

fn enhance_speech() -> EffectSpec {
    spec(
        ClipEffect::AUDIO_ENHANCE_SPEECH_KIND,
        "Enhance Speech",
        vec![
            p(ClipEffect::ENHANCE_AMOUNT_KEY, "Amount", "%", 70.0, 0.0, 100.0, 1.0, 0),
            EffectParamSpec::choice(ClipEffect::ENHANCE_PRESET_KEY, "Preset", &ENHANCE_SPEECH_PRESET_TITLES, 0),
        ],
    )
}

/// A 4-band Multiband Compressor (three crossovers, four bands, output limiter).
fn multiband() -> EffectSpec {
    let mut params = vec![p(ClipEffect::MB_OUTPUT_GAIN_KEY, "Output Gain", "dB", 0.0, -18.0, 18.0, 0.1, 1)];
    for (i, hz) in [(1, 120.0), (2, 700.0), (3, 3_000.0)] {
        params.push(p(&ClipEffect::mb_crossover_key(i), &format!("Crossover {i}"), "Hz", hz, 20.0, 20_000.0, 1.0, 0));
    }
    for i in 1..=4 {
        let band = |what: &str| format!("Band {i} {what}");
        params.push(p(&ClipEffect::mb_threshold_key(i), &band("Threshold"), "dB", -20.0, -60.0, 0.0, 0.1, 1));
        params.push(p(&ClipEffect::mb_ratio_key(i), &band("Ratio"), ":1", 2.0, 1.0, 30.0, 0.1, 1));
        params.push(p(&ClipEffect::mb_attack_key(i), &band("Attack"), "ms", 10.0, 0.1, 500.0, 0.1, 1));
        params.push(p(&ClipEffect::mb_release_key(i), &band("Release"), "ms", 100.0, 5.0, 2_000.0, 1.0, 0));
        params.push(p(&ClipEffect::mb_gain_key(i), &band("Gain"), "dB", 0.0, -18.0, 18.0, 0.1, 1));
    }
    params.push(EffectParamSpec::checkbox(ClipEffect::MB_LIMITER_ON_KEY, "Limiter", false));
    params.push(p(ClipEffect::MB_LIMITER_THRESHOLD_KEY, "Limiter Threshold", "dB", -10.0, -60.0, 0.0, 0.1, 1));
    params.push(p(ClipEffect::MB_LIMITER_MARGIN_KEY, "Limiter Margin", "dB", -0.1, -18.0, 0.0, 0.1, 1));
    params.push(p(ClipEffect::MB_LIMITER_ATTACK_KEY, "Limiter Attack", "ms", 0.0, 0.0, 500.0, 0.1, 1));
    params.push(p(ClipEffect::MB_LIMITER_RELEASE_KEY, "Limiter Release", "ms", 500.0, 5.0, 5_000.0, 1.0, 0));
    for i in 1..=4 {
        params.push(EffectParamSpec::checkbox(&ClipEffect::mb_solo_key(i), &format!("Band {i} Solo"), false));
        params.push(EffectParamSpec::checkbox(&ClipEffect::mb_bypass_key(i), &format!("Band {i} Bypass"), false));
    }
    params.push(EffectParamSpec::checkbox(ClipEffect::MB_LINK_KEY, "Link Band Controls", false));
    spec(ClipEffect::AUDIO_MULTIBAND_KIND, "Multiband Compressor", params)
}

/// A 5-band Parametric EQ (HP, low shelf, 5 peaks, high shelf, LP).
fn parametric_eq() -> EffectSpec {
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
    let mut params = Vec::new();
    for id in ClipEffect::PEQ_FILTER_IDS {
        let (t, is_cut) = (title(id), id == "hp" || id == "lp");
        params.push(EffectParamSpec::checkbox(&ClipEffect::peq_key(id, "On"), &format!("{t} On"), !is_cut));
        params.push(p(
            &ClipEffect::peq_key(id, "Freq"),
            &format!("{t} Frequency"),
            "Hz",
            freq(id),
            20.0,
            20_000.0,
            1.0,
            0,
        ));
        if !is_cut {
            params.push(p(&ClipEffect::peq_key(id, "Gain"), &format!("{t} Gain"), "dB", 0.0, -24.0, 24.0, 0.1, 1));
            let q = if id == "ls" || id == "hs" { 0.71 } else { 1.0 };
            params.push(p(&ClipEffect::peq_key(id, "Q"), &format!("{t} Q"), "", q, 0.1, 10.0, 0.01, 2));
        }
    }
    spec(ClipEffect::AUDIO_PARAMETRIC_EQ_KIND, "EQ", params)
}
