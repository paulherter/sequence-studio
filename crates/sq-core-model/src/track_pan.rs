// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TrackPan.swift

use serde::{Deserialize, Serialize};

/// Track fader and pan: the one definition used by playback, scrubbing and export (the feeder applies it to every
/// audio track bus), so the mix is identical everywhere. Gain in dB is the track fader; pan is -1 (left) ... +1 (right).
pub enum TrackPan {}

impl TrackPan {
    /// Lowest fader value; at or below it the track is silent.
    pub const MIN_VOLUME_DB: f64 = -60.0;
    /// Highest fader value.
    pub const MAX_VOLUME_DB: f64 = 15.0;

    /// (left, right) gain of the pan control. Never above unity, so panning cannot clip what the fader left clean.
    /// - Stereo sources (`stereo_source`): a balance control. The center is unity on both sides; panning attenuates only
    ///   the opposite side, linearly (pan 0.5 right = left at 0.5), hard right silences the left channel.
    /// - Mono sources: equal power, `sin`/`cos` of the pan angle scaled to unity at the center and capped at unity. The
    ///   loud side stays at unity and the far side falls off with the power law (hard left: left 1, right 0). The mono
    ///   law is continuous through the center (no step when the slider crosses 0), unlike a -3 dB center that would make
    ///   an untouched track quieter than a panned one.
    pub fn gains(pan: f64, stereo_source: bool) -> (f64, f64) {
        let p = pan.clamp(-1.0, 1.0);
        if p == 0.0 {
            return (1.0, 1.0); // exact center (cos/sin of pi/4 are not exactly 1/sqrt(2))
        }
        if stereo_source {
            return if p < 0.0 { (1.0, 1.0 + p) } else { (1.0 - p, 1.0) };
        }
        let a = (p + 1.0) * std::f64::consts::PI / 4.0;
        let k = 2.0_f64.sqrt();
        ((a.cos() * k).min(1.0), (a.sin() * k).min(1.0))
    }

    /// Fader dB to linear gain; at or below the floor the track is silent.
    pub fn linear(volume_db: f64) -> f64 {
        if volume_db <= Self::MIN_VOLUME_DB { 0.0 } else { 10.0_f64.powf(volume_db.min(Self::MAX_VOLUME_DB) / 20.0) }
    }

    /// Final per-channel gain of a track: fader times pan. (1, 1) for an untouched track.
    pub fn channel_gains(volume_db: f64, pan: f64, stereo_source: bool) -> (f64, f64) {
        let g = Self::linear(volume_db);
        let p = Self::gains(pan, stereo_source);
        (g * p.0, g * p.1)
    }
}

/// Dialogue / Music / SFX role of a clip or track.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioTag {
    /// Speech.
    Dialogue,
    /// Music.
    Music,
    /// Sound effects.
    Sfx,
}

impl AudioTag {
    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            AudioTag::Dialogue => "Dialogue",
            AudioTag::Music => "Music",
            AudioTag::Sfx => "SFX",
        }
    }

    /// THE loudness table (E8): Gain sheet, Match Loudness, voice chain readout, role chain and delivery targets read
    /// it. Integrated loudness target for web delivery. Dialogue -14 LUFS (YouTube/TikTok reference); music and
    /// effects sit 6 dB below the dialogue so speech stays on top.
    pub fn target_lufs(self) -> f64 {
        match self {
            AudioTag::Dialogue => -14.0,
            AudioTag::Music | AudioTag::Sfx => -20.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn centre_is_unity_for_both_laws() {
        for stereo in [true, false] {
            assert_eq!(TrackPan::gains(0.0, stereo), (1.0, 1.0));
        }
    }

    #[test]
    fn pan_never_boosts_above_unity() {
        for stereo in [true, false] {
            for i in 0..=40 {
                let p = -1.0 + 0.05 * f64::from(i);
                let (l, r) = TrackPan::gains(p, stereo);
                assert!(l <= 1.0 && r <= 1.0 && l >= 0.0 && r >= 0.0, "pan {p} stereo {stereo}");
            }
        }
    }

    #[test]
    fn stereo_balance_attenuates_only_the_opposite_side() {
        let r = TrackPan::gains(0.5, true);
        assert!(r.1 == 1.0 && (r.0 - 0.5).abs() < 1e-12);
        let l = TrackPan::gains(-0.25, true);
        assert!(l.0 == 1.0 && (l.1 - 0.75).abs() < 1e-12);
    }

    #[test]
    fn mono_uses_equal_power_and_is_continuous_through_the_centre() {
        let g = TrackPan::gains(-0.5, false);
        assert!(g.0 == 1.0 && (g.1 - 2.0_f64.sqrt() * (std::f64::consts::PI / 8.0).sin()).abs() < 1e-12);
        let near = TrackPan::gains(0.001, false);
        assert!((near.0 - 1.0).abs() < 0.01 && near.1 == 1.0);
    }

    #[test]
    fn hard_left_silences_the_right() {
        for stereo in [true, false] {
            let g = TrackPan::gains(-1.0, stereo);
            assert!(g.1.abs() < 1e-12 && g.0 == 1.0);
            assert!(TrackPan::gains(1.0, stereo).0.abs() < 1e-12);
            assert_eq!(TrackPan::gains(-5.0, stereo).1, TrackPan::gains(-1.0, stereo).1);
        }
    }

    #[test]
    fn fader_floor_mutes() {
        assert_eq!(TrackPan::linear(0.0), 1.0);
        assert_eq!(TrackPan::linear(-60.0), 0.0);
        assert!((TrackPan::linear(-6.0206) - 0.5).abs() < 1e-4);
        assert_eq!(TrackPan::linear(40.0), TrackPan::linear(15.0));
        assert_eq!(TrackPan::channel_gains(0.0, 0.0, true), (1.0, 1.0));
    }

    #[test]
    fn audio_tags_have_titles_and_the_loudness_table() {
        assert_eq!(AudioTag::Sfx.title(), "SFX");
        assert_eq!(AudioTag::Dialogue.target_lufs(), -14.0);
        assert_eq!(AudioTag::Music.target_lufs(), -20.0);
    }
}
