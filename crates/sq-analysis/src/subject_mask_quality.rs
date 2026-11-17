// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectMaskQuality.swift
//! How a subject mask's edge is made while it is tracked. An app setting of this machine, not part of the project: mattes
//! tracked before a change keep the edge they were made with until the mask is tracked again.

/// String settings (Swift `UserDefaults`), injected: the app provides the real store.
pub trait StringDefaults {
    /// The stored text; `None` when the key is not set.
    fn string(&self, key: &str) -> Option<String>;
    /// Stores text.
    fn set_string(&mut self, key: &str, value: &str);
}

/// How a subject mask's edge is made while it is tracked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubjectMaskQuality {
    /// The frames are read at up to twice the tracking size (long edge at most `LONG_EDGE`) and the matte is made at that
    /// size from the color picture: soft alpha along hair and fine edges.
    Quality,
    /// The matte at the tracking size with the quick edge step.
    Speed,
}

impl SubjectMaskQuality {
    /// Every case.
    pub const ALL: [SubjectMaskQuality; 2] = [SubjectMaskQuality::Quality, SubjectMaskQuality::Speed];
    /// The settings key.
    pub const DEFAULTS_KEY: &'static str = "sq.subjectMask.quality";
    /// Long edge of the largest matte Quality makes.
    pub const LONG_EDGE: i64 = 1920;

    /// The raw string value.
    pub fn raw_value(self) -> &'static str {
        match self {
            SubjectMaskQuality::Quality => "quality",
            SubjectMaskQuality::Speed => "speed",
        }
    }

    /// The case with this raw value.
    pub fn from_raw(raw: &str) -> Option<SubjectMaskQuality> {
        Self::ALL.into_iter().find(|c| c.raw_value() == raw)
    }

    /// Quality on 64-bit ARM machines (Apple silicon), Speed elsewhere (Intel Macs, the PC).
    pub fn standard() -> SubjectMaskQuality {
        if cfg!(target_arch = "aarch64") { SubjectMaskQuality::Quality } else { SubjectMaskQuality::Speed }
    }

    /// The menu hint (Swift `SubjectMaskQualityMenu.help`).
    pub fn help(self) -> &'static str {
        match self {
            SubjectMaskQuality::Quality => "Finer hair and soft edges, tracks slower",
            SubjectMaskQuality::Speed => "Tracks faster, simpler edges",
        }
    }

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            SubjectMaskQuality::Quality => "Quality",
            SubjectMaskQuality::Speed => "Speed",
        }
    }

    /// The stored choice; a missing or unknown value is the default.
    pub fn stored(defaults: &dyn StringDefaults) -> SubjectMaskQuality {
        defaults.string(Self::DEFAULTS_KEY).and_then(|s| Self::from_raw(&s)).unwrap_or_else(Self::standard)
    }

    /// Stores this choice.
    pub fn store(self, defaults: &mut dyn StringDefaults) {
        defaults.set_string(Self::DEFAULTS_KEY, self.raw_value());
    }

    /// Long edge the frames of a track are read at: `analysis` is the size the tracking itself works at on this machine, so
    /// a small machine gets a smaller Quality matte too.
    pub fn frame_dimension(self, analysis: i64) -> i64 {
        if self == SubjectMaskQuality::Quality { analysis.max(Self::LONG_EDGE.min(analysis * 2)) } else { analysis }
    }
}

/// The choice as one value shared between the UI thread (which reads the stored setting) and the tracking runs (which read it
/// when they start, like Swift `MagicMaskTracker.decide`). Cloning shares it.
#[derive(Clone, Debug)]
pub struct SubjectEdgesChoice(std::sync::Arc<std::sync::atomic::AtomicBool>);

impl Default for SubjectEdgesChoice {
    fn default() -> SubjectEdgesChoice {
        let choice = SubjectEdgesChoice(std::sync::Arc::default());
        choice.set(SubjectMaskQuality::standard());
        choice
    }
}

impl SubjectEdgesChoice {
    /// Settles the choice.
    pub fn set(&self, q: SubjectMaskQuality) {
        self.0.store(q == SubjectMaskQuality::Quality, std::sync::atomic::Ordering::Relaxed);
    }

    /// The choice now.
    pub fn get(&self) -> SubjectMaskQuality {
        if self.0.load(std::sync::atomic::Ordering::Relaxed) {
            SubjectMaskQuality::Quality
        } else {
            SubjectMaskQuality::Speed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Memory(HashMap<String, String>);

    impl StringDefaults for Memory {
        fn string(&self, key: &str) -> Option<String> {
            self.0.get(key).cloned()
        }
        fn set_string(&mut self, key: &str, value: &str) {
            self.0.insert(key.to_string(), value.to_string());
        }
    }

    #[test]
    fn a_missing_or_unknown_value_is_the_default() {
        let mut m = Memory::default();
        assert_eq!(SubjectMaskQuality::stored(&m), SubjectMaskQuality::standard());
        m.set_string(SubjectMaskQuality::DEFAULTS_KEY, "nonsense");
        assert_eq!(SubjectMaskQuality::stored(&m), SubjectMaskQuality::standard());
    }

    #[test]
    fn the_choice_is_stored_and_read_back() {
        let mut m = Memory::default();
        for q in SubjectMaskQuality::ALL {
            q.store(&mut m);
            assert_eq!(SubjectMaskQuality::stored(&m), q);
        }
    }

    #[test]
    fn a_shared_choice_reaches_every_clone() {
        let a = SubjectEdgesChoice::default();
        let b = a.clone();
        for q in SubjectMaskQuality::ALL {
            a.set(q);
            assert_eq!(b.get(), q);
        }
    }

    #[test]
    fn quality_reads_larger_frames_up_to_the_long_edge() {
        assert_eq!(SubjectMaskQuality::Speed.frame_dimension(960), 960);
        assert_eq!(SubjectMaskQuality::Quality.frame_dimension(960), 1920);
        assert_eq!(SubjectMaskQuality::Quality.frame_dimension(1500), 1920);
        assert_eq!(SubjectMaskQuality::Quality.frame_dimension(2500), 2500);
    }
}
