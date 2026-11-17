// Swift: WaveformTint.swift
//! Waveform ink by audio role: Dialogue, Music and SFX each get a tint so a creator reads the mix at a glance.

use sq_core_audio::audio_role::TrackRoleExt;
use sq_core_model::{AudioTag, Clip, Track};

/// Waveform tint rules.
pub struct WaveformTint;

impl WaveformTint {
    /// The one role every clip in the row shares (clip tag, else track role); `None` when none or when they differ.
    // One ink per track row (the row's waveforms are one blended mask), as in Swift.
    pub fn role(track: &Track, clips: &[Clip]) -> Option<AudioTag> {
        let Some(first) = clips.first().map(|c| track.role_of(c)) else { return track.audio_role };
        if clips.iter().all(|c| track.role_of(c) == first) { first } else { None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::TrackKind;

    #[test]
    fn a_row_shares_one_role_or_none() {
        let mut t = track(TrackKind::Audio, vec![]);
        t.audio_role = Some(AudioTag::Music);
        assert_eq!(WaveformTint::role(&t, &[]), Some(AudioTag::Music));
        let (mut a, b) = (mk(0, 10, TrackKind::Audio, None), mk(10, 10, TrackKind::Audio, None));
        assert_eq!(WaveformTint::role(&t, &[a.clone(), b.clone()]), Some(AudioTag::Music));
        a.audio_tag = Some(AudioTag::Dialogue);
        assert_eq!(WaveformTint::role(&t, &[a, b]), None);
    }
}
