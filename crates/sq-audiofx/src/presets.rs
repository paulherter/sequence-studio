// Swift: Presets.swift
//! Track audio presets: the Multiband Compressor settings, the built-in presets and the role voicings.

use crate::creator_fx::{NoiseGateSettings, SaturationSettings};
use serde::{Deserialize, Serialize};
use sq_core_model::AudioTag;
use sq_core_time::IdSource;

/// One band of the Multiband Compressor.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct MultibandBand {
    #[serde(rename = "thresholdDB")]
    pub threshold_db: f64,
    pub ratio: f64,
    #[serde(rename = "attackMs")]
    pub attack_ms: f64,
    #[serde(rename = "releaseMs")]
    pub release_ms: f64,
    #[serde(rename = "gainDB")]
    pub gain_db: f64,
}

impl MultibandBand {
    /// A band with 0 dB gain.
    pub fn new(threshold_db: f64, ratio: f64, attack_ms: f64, release_ms: f64) -> Self {
        MultibandBand { threshold_db, ratio, attack_ms, release_ms, gain_db: 0.0 }
    }

    /// A band with a gain.
    pub fn with_gain(threshold_db: f64, ratio: f64, attack_ms: f64, release_ms: f64, gain_db: f64) -> Self {
        MultibandBand { threshold_db, ratio, attack_ms, release_ms, gain_db }
    }
}

/// Four-band compressor settings (Premiere-style Multiband Compressor), run by `MultibandCompressor`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MultibandCompressorSettings {
    pub bypass: bool,
    /// Exactly 3 crossover frequencies in Hz, ascending.
    #[serde(rename = "crossoversHz")]
    pub crossovers_hz: Vec<f64>,
    /// Exactly 4 bands, low to high.
    pub bands: Vec<MultibandBand>,
    #[serde(rename = "preGainDB")]
    pub pre_gain_db: f64,
    #[serde(rename = "makeupGainDB")]
    pub makeup_gain_db: f64,
    /// The EQ head's On switch: off, the bands' gains are not applied. Old projects have no key and load as on.
    #[serde(rename = "eqOn", default = "eq_on_default")]
    pub eq_on: bool,
}

fn eq_on_default() -> bool {
    true
}

impl MultibandCompressorSettings {
    /// Settings with no pre gain and no makeup gain, not bypassed.
    pub fn new(crossovers_hz: Vec<f64>, bands: Vec<MultibandBand>) -> Self {
        MultibandCompressorSettings {
            bypass: false,
            crossovers_hz,
            bands,
            pre_gain_db: 0.0,
            makeup_gain_db: 0.0,
            eq_on: true,
        }
    }

    /// Transparent: ratio 1, no gain, bypassed.
    pub fn neutral() -> Self {
        MultibandCompressorSettings {
            bypass: true,
            crossovers_hz: vec![120.0, 700.0, 3000.0],
            bands: vec![MultibandBand::new(0.0, 1.0, 10.0, 100.0); 4],
            pre_gain_db: 0.0,
            makeup_gain_db: 0.0,
            eq_on: true,
        }
    }
}

/// A named set of track audio settings.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TrackAudioPreset {
    pub id: String,
    pub name: String,
    #[serde(rename = "isBuiltIn")]
    pub is_built_in: bool,
    pub compressor: MultibandCompressorSettings,
    /// Denoiser strength = wet/dry mix: 0 = denoiser off, 1 = fully denoised. Default 0.5.
    #[serde(rename = "noiseReduction")]
    pub noise_reduction: f64,
    /// Noise gate, runs after the denoiser and before the compressor. Off by default.
    #[serde(default)]
    pub gate: NoiseGateSettings,
    /// Saturation ("warmth"), runs after the de-esser. Off by default.
    #[serde(default)]
    pub saturation: SaturationSettings,
    /// Split-band de-esser after the compressor (the Voice role turns it on). Optional on decode: older presets have none.
    #[serde(rename = "deEss", default)]
    pub de_ess: bool,
}

impl TrackAudioPreset {
    /// A user preset with the default denoiser mix of 0.5; `noise_reduction` is clamped to 0...1.
    pub fn new(id: &str, name: &str, compressor: MultibandCompressorSettings) -> Self {
        TrackAudioPreset {
            id: id.to_string(),
            name: name.to_string(),
            is_built_in: false,
            compressor,
            noise_reduction: 0.5,
            gate: NoiseGateSettings::OFF,
            saturation: SaturationSettings::OFF,
            de_ess: false,
        }
    }

    /// Sets the denoiser mix, clamped to 0...1 (the Swift initializer clamps).
    pub fn with_noise_reduction(mut self, v: f64) -> Self {
        self.noise_reduction = v.clamp(0.0, 1.0);
        self
    }

    fn built_in(id: &str, name: &str, compressor: MultibandCompressorSettings, noise_reduction: f64) -> Self {
        TrackAudioPreset {
            is_built_in: true,
            ..TrackAudioPreset::new(id, name, compressor).with_noise_reduction(noise_reduction)
        }
    }

    /// Nothing: compressor bypassed, no denoiser.
    pub fn off() -> Self {
        Self::built_in("builtin.off", "Off", MultibandCompressorSettings::neutral(), 0.0)
    }

    /// Speech.
    pub fn voice() -> Self {
        let b = MultibandBand::with_gain;
        Self::built_in(
            "builtin.voice",
            "Voice",
            MultibandCompressorSettings {
                makeup_gain_db: 3.0,
                eq_on: true,
                ..MultibandCompressorSettings::new(
                    vec![120.0, 900.0, 4500.0],
                    vec![
                        b(-30.0, 2.5, 15.0, 150.0, -3.0),
                        b(-26.0, 3.0, 8.0, 120.0, 1.0),
                        b(-28.0, 3.0, 5.0, 100.0, 2.0),
                        b(-32.0, 2.0, 3.0, 80.0, 0.0),
                    ],
                )
            },
            0.8,
        )
    }

    /// Music.
    pub fn music() -> Self {
        let b = MultibandBand::new;
        Self::built_in(
            "builtin.music",
            "Music",
            MultibandCompressorSettings {
                makeup_gain_db: 1.5,
                eq_on: true,
                ..MultibandCompressorSettings::new(
                    vec![150.0, 1000.0, 6000.0],
                    vec![
                        b(-20.0, 1.8, 30.0, 250.0),
                        b(-22.0, 1.6, 20.0, 200.0),
                        b(-24.0, 1.6, 10.0, 150.0),
                        b(-26.0, 1.4, 5.0, 120.0),
                    ],
                )
            },
            0.0,
        )
    }

    /// Off, Voice, Music.
    pub fn built_ins() -> Vec<TrackAudioPreset> {
        vec![Self::off(), Self::voice(), Self::music()]
    }

    /// The voiced preset of a track role.
    pub fn for_role(role: AudioTag) -> TrackAudioPreset {
        RoleVoicing::for_role(role).preset()
    }

    /// The chain a track of `role` starts on: its voiced preset, Off without a role.
    pub fn starting_chain(role: Option<AudioTag>) -> TrackAudioPreset {
        role.map_or_else(Self::off, Self::for_role)
    }

    /// Whether both presets run the same chain (compressor with its EQ, denoiser, gate, warmth, de-esser), whatever
    /// their names: the test for "the user changed nothing".
    pub fn same_chain(&self, other: &TrackAudioPreset) -> bool {
        self.compressor == other.compressor
            && self.noise_reduction == other.noise_reduction
            && self.gate == other.gate
            && self.saturation == other.saturation
            && self.de_ess == other.de_ess
    }

    /// The role presets in `AudioTag` order.
    pub fn role_presets() -> Vec<TrackAudioPreset> {
        ALL_TAGS.iter().map(|r| Self::for_role(*r)).collect()
    }
}

/// `AudioTag.allCases`.
const ALL_TAGS: [AudioTag; 3] = [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx];

/// The built-in presets plus the user's own.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PresetLibrary {
    #[serde(rename = "userPresets")]
    user_presets: Vec<TrackAudioPreset>,
}

impl PresetLibrary {
    /// An empty library (only the built-ins).
    pub fn new() -> Self {
        PresetLibrary::default()
    }

    /// The user's presets.
    pub fn user_presets(&self) -> &[TrackAudioPreset] {
        &self.user_presets
    }

    /// Built-ins first, then the user's presets.
    pub fn all(&self) -> Vec<TrackAudioPreset> {
        let mut all = TrackAudioPreset::built_ins();
        all.extend(self.user_presets.iter().cloned());
        all
    }

    /// Also finds the role presets (`TrackAudioPreset::for_role`), which are picked by role, not listed in `all`.
    pub fn preset(&self, id: &str) -> Option<TrackAudioPreset> {
        self.all()
            .into_iter()
            .find(|p| p.id == id)
            .or_else(|| TrackAudioPreset::role_presets().into_iter().find(|p| p.id == id))
    }

    /// Stores a copy as a user preset with a fresh id and returns it.
    pub fn save_user(&mut self, preset: &TrackAudioPreset, ids: &mut dyn IdSource) -> TrackAudioPreset {
        let mut p = preset.clone();
        p.id = format!("user.{}", ids.next_id());
        p.is_built_in = false;
        self.user_presets.push(p.clone());
        p
    }

    /// Renames a user preset; built-ins stay as they are.
    pub fn rename(&mut self, id: &str, name: &str) {
        if let Some(p) = self.user_presets.iter_mut().find(|p| p.id == id) {
            p.name = name.to_string();
        }
    }

    /// Removes a user preset.
    pub fn remove(&mut self, id: &str) {
        self.user_presets.retain(|p| p.id != id);
    }
}

/// Dynamics of one band of a role voicing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VoicingDynamics {
    pub threshold_db: f64,
    pub ratio: f64,
    pub attack_ms: f64,
    pub release_ms: f64,
}

/// The voicing of one track role (Dialogue / Music / SFX): a 4-band EQ at the compressor's crossovers, the compressor's dynamics,
/// a level offset and the denoiser amount. Values tuned by ear for social and YouTube delivery (Premiere's Essential Sound as the
/// reference): dialogue clear with presence, music scooped where speech lives, SFX untouched in tone.
///
/// Level: all offsets and makeup gains are 0 dB (review W4.5). Clip Match Loudness already places each clip at its tag's
/// target (`AudioTag::target_lufs`: dialogue -14, music/SFX -20 LUFS), so a role offset would stack on top of it, and makeup
/// would push matched dialogue above -14. The voicing therefore only shapes tone and dynamics; `level_db` stays as a knob
/// (the maintainer can set e.g. music -6 for unmatched material).
///
/// The multiband compressor carries all of it, so the voicing runs in the one existing FX path (playback and export):
/// EQ = per-band gain, level offset = added to the makeup gain.
#[derive(Clone, Debug, PartialEq)]
pub struct RoleVoicing {
    pub role: AudioTag,
    pub crossovers_hz: Vec<f64>,
    /// Band gains low to high in dB (the EQ).
    pub eq_db: Vec<f64>,
    pub bands: Vec<VoicingDynamics>,
    pub makeup_gain_db: f64,
    /// Role level relative to dialogue, in dB.
    pub level_db: f64,
    pub noise_reduction: f64,
}

impl RoleVoicing {
    /// The voicing of `role`.
    pub fn for_role(role: AudioTag) -> RoleVoicing {
        let d =
            |threshold_db, ratio, attack_ms, release_ms| VoicingDynamics { threshold_db, ratio, attack_ms, release_ms };
        match role {
            AudioTag::Dialogue => RoleVoicing {
                role,
                crossovers_hz: vec![120.0, 900.0, 4500.0],
                eq_db: vec![-6.0, 0.0, 3.0, 1.0],
                bands: vec![
                    d(-30.0, 2.0, 15.0, 150.0),
                    d(-24.0, 3.0, 8.0, 120.0),
                    d(-26.0, 3.0, 5.0, 100.0),
                    d(-30.0, 2.0, 3.0, 80.0),
                ],
                makeup_gain_db: 0.0,
                level_db: 0.0,
                noise_reduction: 0.6,
            },
            AudioTag::Music => RoleVoicing {
                role,
                crossovers_hz: vec![150.0, 1000.0, 5000.0],
                eq_db: vec![0.0, -2.0, -3.0, 0.0],
                bands: vec![
                    d(-18.0, 1.5, 30.0, 250.0),
                    d(-20.0, 1.4, 20.0, 200.0),
                    d(-22.0, 1.4, 10.0, 150.0),
                    d(-24.0, 1.3, 5.0, 120.0),
                ],
                makeup_gain_db: 0.0,
                level_db: 0.0,
                noise_reduction: 0.0,
            },
            AudioTag::Sfx => RoleVoicing {
                role,
                crossovers_hz: vec![120.0, 1000.0, 6000.0],
                eq_db: vec![0.0, 0.0, 0.0, 0.0],
                bands: vec![
                    d(-14.0, 2.0, 20.0, 150.0),
                    d(-14.0, 2.0, 15.0, 120.0),
                    d(-14.0, 2.0, 10.0, 100.0),
                    d(-14.0, 2.0, 10.0, 80.0),
                ],
                makeup_gain_db: 0.0,
                level_db: 0.0,
                noise_reduction: 0.0,
            },
        }
    }

    /// The voicing as a track preset for the FX chain.
    pub fn preset(&self) -> TrackAudioPreset {
        let b: Vec<MultibandBand> = self
            .bands
            .iter()
            .zip(&self.eq_db)
            .map(|(d, g)| MultibandBand::with_gain(d.threshold_db, d.ratio, d.attack_ms, d.release_ms, *g))
            .collect();
        let (raw, title) = match self.role {
            AudioTag::Dialogue => ("dialogue", "Dialogue"),
            AudioTag::Music => ("music", "Music"),
            AudioTag::Sfx => ("sfx", "SFX"),
        };
        TrackAudioPreset {
            is_built_in: true,
            de_ess: self.role == AudioTag::Dialogue,
            ..TrackAudioPreset::new(
                &format!("builtin.role.{raw}"),
                title,
                MultibandCompressorSettings {
                    makeup_gain_db: self.makeup_gain_db + self.level_db,
                    eq_on: true,
                    ..MultibandCompressorSettings::new(self.crossovers_hz.clone(), b)
                },
            )
            .with_noise_reduction(self.noise_reduction)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;
    use std::collections::BTreeSet;

    #[test]
    fn built_ins() {
        let all = TrackAudioPreset::built_ins();
        let ids: BTreeSet<_> = all.iter().map(|p| p.id.clone()).collect();
        assert_eq!(ids.len(), all.len());
        assert!(TrackAudioPreset::off().compressor.bypass);
        assert_eq!(TrackAudioPreset::off().noise_reduction, 0.0);
        assert!(TrackAudioPreset::voice().noise_reduction > 0.0);
        assert!(!TrackAudioPreset::voice().compressor.bypass);
        assert_eq!(TrackAudioPreset::voice().compressor.bands.len(), 4);
        assert_eq!(TrackAudioPreset::voice().compressor.crossovers_hz.len(), 3);
    }

    #[test]
    fn denoise_mix_defaults_to_half() {
        let p = TrackAudioPreset::new("x", "x", MultibandCompressorSettings::neutral());
        assert_eq!(p.noise_reduction, 0.5);
        assert_eq!(p.with_noise_reduction(7.0).noise_reduction, 1.0);
    }

    #[test]
    fn library_user_presets() {
        let mut ids = SequentialIds::default();
        let mut lib = PresetLibrary::new();
        assert_eq!(lib.all().len(), TrackAudioPreset::built_ins().len());
        let mut mine = TrackAudioPreset::voice();
        mine.name = "Podcast".to_string();
        let saved = lib.save_user(&mine, &mut ids);
        assert!(!saved.is_built_in);
        assert_ne!(saved.id, TrackAudioPreset::voice().id);
        assert_eq!(lib.preset(&saved.id).map(|p| p.name), Some("Podcast".to_string()));
        lib.rename(&saved.id, "Podcast 2");
        assert_eq!(lib.preset(&saved.id).map(|p| p.name), Some("Podcast 2".to_string()));
        let json = serde_json::to_string(&lib).unwrap_or_default();
        assert_eq!(serde_json::from_str::<PresetLibrary>(&json).ok(), Some(lib.clone()));
        lib.rename(&TrackAudioPreset::voice().id, "x"); // built-ins immutable
        assert_eq!(lib.preset(&TrackAudioPreset::voice().id).map(|p| p.name), Some("Voice".to_string()));
        lib.remove(&saved.id);
        lib.remove(&TrackAudioPreset::voice().id);
        assert_eq!(lib.all().len(), TrackAudioPreset::built_ins().len());
    }

    #[test]
    fn role_presets_follow_the_voicing() {
        let p = TrackAudioPreset::for_role(AudioTag::Dialogue);
        assert_eq!(p.id, "builtin.role.dialogue");
        assert!(p.de_ess && p.is_built_in);
        assert_eq!(p.compressor.bands[0].gain_db, -6.0);
        assert_eq!(TrackAudioPreset::role_presets().len(), 3);
        assert!(!TrackAudioPreset::for_role(AudioTag::Sfx).de_ess);
    }

    #[test]
    fn old_presets_without_gate_saturation_or_de_ess_still_decode() {
        let mut v = serde_json::to_value(TrackAudioPreset::voice()).unwrap_or_default();
        if let Some(o) = v.as_object_mut() {
            o.remove("gate");
            o.remove("saturation");
            o.remove("deEss");
        }
        let p: Option<TrackAudioPreset> = serde_json::from_value(v).ok();
        assert_eq!(p.as_ref().map(|p| p.de_ess), Some(false));
        assert_eq!(p.map(|p| p.gate), Some(NoiseGateSettings::OFF));
    }
}
