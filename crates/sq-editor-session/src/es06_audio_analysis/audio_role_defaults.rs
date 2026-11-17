// Swift: AudioRoleDefaults.swift
//! Per-role audio editing defaults (Settings Audio page): J / L cut offset, crossfade length and the crossfade kind.

use std::collections::BTreeMap;

use sq_core_model::{AudioTag, TrackKind, TransitionKind};
use sq_core_time::Time;
use sq_library::library_folder_store::SettingsStore;

use super::settings::{get_f64, get_string, set_f64, set_string};

/// Every role, in Swift's `AudioTag.allCases` order.
const ROLES: [AudioTag; 3] = [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx];

/// Order key of a role for the maps (`AudioTag` has no `Ord`).
fn index(r: AudioTag) -> usize {
    match r {
        AudioTag::Dialogue => 0,
        AudioTag::Music => 1,
        AudioTag::Sfx => 2,
    }
}

/// The stored role name (Swift raw value).
fn role_name(r: AudioTag) -> &'static str {
    match r {
        AudioTag::Dialogue => "dialogue",
        AudioTag::Music => "music",
        AudioTag::Sfx => "sfx",
    }
}

/// The stored name of an audio crossfade kind (Swift raw value), `None` for kinds that are not audio crossfades.
fn kind_name(k: TransitionKind) -> Option<&'static str> {
    match k {
        TransitionKind::ConstantPower => Some("constantPower"),
        TransitionKind::ConstantGain => Some("constantGain"),
        TransitionKind::ExponentialFade => Some("exponentialFade"),
        _ => None,
    }
}

fn kind_from_name(s: &str) -> Option<TransitionKind> {
    [TransitionKind::ConstantPower, TransitionKind::ConstantGain, TransitionKind::ExponentialFade]
        .into_iter()
        .find(|k| kind_name(*k) == Some(s))
}

/// Per-role audio editing defaults. A role is the clip's `AudioTag`; untagged clips use the dialogue values.
// Swift: AudioRoleDefaults.swift:7
#[derive(Clone, Debug, PartialEq)]
pub struct AudioRoleDefaults {
    /// J / L offset in seconds per role (keyed by the role's index: dialogue, music, sfx).
    // Swift: AudioRoleDefaults.swift:8
    split_offset_seconds: BTreeMap<usize, f64>,
    /// Audio transition length in seconds per role.
    // Swift: AudioRoleDefaults.swift:10
    transition_seconds: BTreeMap<usize, f64>,
    /// Kind a default audio transition gets (the crossfade curve).
    // Swift: AudioRoleDefaults.swift:12
    pub crossfade_kind: TransitionKind,
}

/// Settings keys (Swift `AudioRoleDefaults.Key`).
// Swift: AudioRoleDefaults.swift:25
pub enum AudioRoleKey {}

impl AudioRoleKey {
    // Swift: AudioRoleDefaults.swift:26
    pub fn split_offset(r: AudioTag) -> String {
        format!("sq.audio.splitOffsetSeconds.{}", role_name(r))
    }
    // Swift: AudioRoleDefaults.swift:27
    pub fn transition(r: AudioTag) -> String {
        format!("sq.audio.transitionSeconds.{}", role_name(r))
    }
    // Swift: AudioRoleDefaults.swift:28
    pub const CROSSFADE_KIND: &'static str = "sq.audio.crossfadeKind";
}

impl AudioRoleDefaults {
    /// Dialogue and effects: 0.25 s lead; music and voice-over beds lead longer, 0.5 s. Transition lengths: dialogue
    /// short (0.1 s), effects 0.25 s, music long (1 s).
    // Swift: AudioRoleDefaults.swift:16
    pub fn standard() -> AudioRoleDefaults {
        AudioRoleDefaults::new(
            [(AudioTag::Dialogue, 0.25), (AudioTag::Music, 0.5), (AudioTag::Sfx, 0.25)].into(),
            [(AudioTag::Dialogue, 0.1), (AudioTag::Music, 1.0), (AudioTag::Sfx, 0.25)].into(),
            TransitionKind::ConstantPower,
        )
    }

    // Swift: AudioRoleDefaults.swift:20
    pub fn new(
        split_offset_seconds: Vec<(AudioTag, f64)>,
        transition_seconds: Vec<(AudioTag, f64)>,
        crossfade_kind: TransitionKind,
    ) -> AudioRoleDefaults {
        let map = |v: Vec<(AudioTag, f64)>| v.into_iter().map(|(r, s)| (index(r), s)).collect();
        AudioRoleDefaults {
            split_offset_seconds: map(split_offset_seconds),
            transition_seconds: map(transition_seconds),
            crossfade_kind,
        }
    }

    /// J / L offset in seconds of a role, if set.
    // Swift: AudioRoleDefaults.swift:8
    pub fn split_offset_seconds(&self, role: AudioTag) -> Option<f64> {
        self.split_offset_seconds.get(&index(role)).copied()
    }

    /// Sets the J / L offset of a role.
    pub fn set_split_offset_seconds(&mut self, role: AudioTag, seconds: f64) {
        self.split_offset_seconds.insert(index(role), seconds);
    }

    /// Audio transition length in seconds of a role, if set.
    // Swift: AudioRoleDefaults.swift:10
    pub fn transition_seconds(&self, role: AudioTag) -> Option<f64> {
        self.transition_seconds.get(&index(role)).copied()
    }

    /// Sets the audio transition length of a role.
    pub fn set_transition_seconds(&mut self, role: AudioTag, seconds: f64) {
        self.transition_seconds.insert(index(role), seconds);
    }

    // Swift: AudioRoleDefaults.swift:30
    pub fn split_offset(&self, role: Option<AudioTag>, frame_duration: Time) -> Time {
        let r = role.unwrap_or(AudioTag::Dialogue);
        Self::whole_frames(self.split_offset_seconds(r).unwrap_or(0.25), frame_duration)
    }

    /// Audio transition length for a role; `None` role = `fallback_seconds` (the single Settings value).
    // Swift: AudioRoleDefaults.swift:36
    pub fn transition_duration(&self, role: Option<AudioTag>, fallback_seconds: f64, frame_duration: Time) -> Time {
        let s = role.and_then(|r| self.transition_seconds(r)).unwrap_or(fallback_seconds);
        Self::whole_frames(s, frame_duration)
    }

    pub(crate) fn whole_frames(seconds: f64, fd: Time) -> Time {
        fd * ((seconds * fd.timescale() as f64 / fd.value() as f64).round() as i64).max(1)
    }

    // Swift: AudioRoleDefaults.swift:43
    pub fn load(d: &dyn SettingsStore) -> AudioRoleDefaults {
        let mut s = Self::standard();
        for r in ROLES {
            if let Some(v) = get_f64(d, &AudioRoleKey::split_offset(r))
                && v.is_finite()
                && v > 0.0
                && v <= 10.0
            {
                s.set_split_offset_seconds(r, v);
            }
            if let Some(v) = get_f64(d, &AudioRoleKey::transition(r))
                && v.is_finite()
                && v > 0.0
                && v <= 600.0
            {
                s.set_transition_seconds(r, v);
            }
        }
        if let Some(k) = get_string(d, AudioRoleKey::CROSSFADE_KIND).as_deref().and_then(kind_from_name)
            && k.track_kind() == TrackKind::Audio
        {
            s.crossfade_kind = k;
        }
        s
    }

    // Swift: AudioRoleDefaults.swift:57
    pub fn save(&self, d: &mut dyn SettingsStore) {
        for r in ROLES {
            if let Some(v) = self.split_offset_seconds(r) {
                set_f64(d, &AudioRoleKey::split_offset(r), v);
            }
            if let Some(v) = self.transition_seconds(r) {
                set_f64(d, &AudioRoleKey::transition(r), v);
            }
        }
        if let Some(n) = kind_name(self.crossfade_kind) {
            set_string(d, AudioRoleKey::CROSSFADE_KIND, n);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_library::library_folder_store::MemorySettings;

    const FD: Time = Time::new(1, 30);

    #[test]
    fn offsets_round_to_whole_frames_and_default_to_dialogue() {
        let s = AudioRoleDefaults::standard();
        assert_eq!(s.split_offset(None, FD), FD * 8); // 0.25 s at 30 fps = 7.5 -> 8
        assert_eq!(s.split_offset(Some(AudioTag::Music), FD), FD * 15);
        assert_eq!(s.transition_duration(Some(AudioTag::Music), 0.5, FD), FD * 30);
        assert_eq!(s.transition_duration(None, 0.5, FD), FD * 15);
        assert_eq!(AudioRoleDefaults::whole_frames(0.0, FD), FD); // never shorter than one frame
    }

    #[test]
    fn round_trips_and_ignores_bad_values() {
        let mut d = MemorySettings::default();
        let mut s = AudioRoleDefaults::standard();
        s.set_split_offset_seconds(AudioTag::Sfx, 0.4);
        s.crossfade_kind = TransitionKind::ConstantGain;
        s.save(&mut d);
        assert_eq!(AudioRoleDefaults::load(&d), s);
        set_f64(&mut d, &AudioRoleKey::split_offset(AudioTag::Music), 99.0);
        set_string(&mut d, AudioRoleKey::CROSSFADE_KIND, "crossDissolve");
        let l = AudioRoleDefaults::load(&d);
        assert_eq!(l.split_offset_seconds(AudioTag::Music), Some(0.5));
        assert_eq!(l.crossfade_kind, TransitionKind::ConstantPower);
    }
}
