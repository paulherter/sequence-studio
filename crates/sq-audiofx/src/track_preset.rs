//! The track's audio chain tweaks as stored in the project (`Track::audio_preset`), typed.

use crate::presets::TrackAudioPreset;
use sq_core_model::Track;

/// Typed access to the preset JSON a track stores. Playback and export read the track through `audio_preset`, so both run the
/// same chain.
pub trait TrackPresetExt {
    /// The stored tweaks; `None` when there are none or the stored value is not a preset (the role's preset runs then).
    fn audio_preset(&self) -> Option<TrackAudioPreset>;
    /// Stores (or clears) the tweaks.
    fn set_audio_preset(&mut self, preset: Option<&TrackAudioPreset>);
}

impl TrackPresetExt for Track {
    fn audio_preset(&self) -> Option<TrackAudioPreset> {
        self.audio_preset.clone().and_then(|v| serde_json::from_value(v).ok())
    }

    fn set_audio_preset(&mut self, preset: Option<&TrackAudioPreset>) {
        self.audio_preset = preset.and_then(|p| serde_json::to_value(p).ok());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::Id;

    #[test]
    fn preset_round_trips_through_the_track_and_its_json() {
        let mut t = Track::new(Id::from_u128(1), TrackKind::Audio);
        assert_eq!(t.audio_preset(), None);
        let mut p = TrackAudioPreset::voice();
        p.compressor.eq_on = false;
        p.compressor.bypass = true;
        t.set_audio_preset(Some(&p));
        let json = serde_json::to_string(&t).expect("encode");
        let back: Track = serde_json::from_str(&json).expect("decode");
        assert_eq!(back.audio_preset(), Some(p));
        t.set_audio_preset(None);
        assert!(!serde_json::to_string(&t).expect("encode").contains("audioPreset"));
    }

    #[test]
    fn a_broken_stored_value_falls_back_to_the_role() {
        let mut t = Track::new(Id::from_u128(1), TrackKind::Audio);
        t.audio_preset = Some(serde_json::json!({"nonsense": 1}));
        assert_eq!(t.audio_preset(), None);
    }
}
