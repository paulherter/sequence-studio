//! Effect defaults file store, drag payload encoding and the Effect Controls section ids.

use std::path::{Path, PathBuf};

use sq_core_graphics::custom_animation::AnimationSide;
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::{EffectCatalog, TransitionKind};
use sq_core_time::{Id, IdSource, Timestamp};
use sq_library::effect_defaults_file::EffectDefaultsFile;

/// The user's effect defaults and the file they live in (Swift `EffectDefaultsLibrary`; the app owns the instance
/// and tells the session about a change through its inbox).
#[derive(Debug)]
pub struct EffectDefaultsLibrary {
    pub(crate) defaults: EffectDefaults,
    pub(crate) file_url: Option<PathBuf>,
    pub(crate) read_only: bool,
    pub(crate) version: u64,
}

impl EffectDefaultsLibrary {
    /// Name of the change notification, the message the app posts after `update` changed something.
    // Swift: EffectDefaultsLibrary.swift:10
    pub const DID_CHANGE: &'static str = "sq.effectDefaultsDidChange";

    /// Loads `file_url`; a missing file is empty defaults, an unreadable one makes the library read-only.
    // Swift: EffectDefaultsLibrary.swift:20
    // Swift: EffectDefaultsLibrary.swift:11 (the app-wide instance: the app builds one with the default file)
    pub fn new(file_url: Option<PathBuf>, now: Timestamp, ids: &mut dyn IdSource) -> EffectDefaultsLibrary {
        let Some(path) = file_url.clone() else {
            return EffectDefaultsLibrary {
                defaults: EffectDefaults::default(),
                file_url,
                read_only: false,
                version: 0,
            };
        };
        match EffectDefaultsFile::load(&path, now, ids) {
            Ok(defaults) => EffectDefaultsLibrary { defaults, file_url, read_only: false, version: 0 },
            Err(_) => {
                EffectDefaultsLibrary { defaults: EffectDefaults::default(), file_url, read_only: true, version: 0 }
            }
        }
    }
    /// True when the file was unreadable: changes stay in memory and `update` reports false.
    pub fn is_read_only(&self) -> bool {
        self.read_only
    }
    /// Bumped by every change.
    pub fn version(&self) -> u64 {
        self.version
    }
    // Swift: EffectDefaultsLibrary.swift:17
    pub fn file_url(&self) -> Option<&Path> {
        self.file_url.as_deref()
    }
    /// The current defaults.
    pub fn defaults(&self) -> &EffectDefaults {
        &self.defaults
    }
    /// Applies `change`, saves, and returns false when the file could not be written.
    // Swift: EffectDefaultsLibrary.swift:31
    pub fn update(&mut self, change: impl FnOnce(&mut EffectDefaults)) -> bool {
        let mut next = self.defaults.clone();
        change(&mut next);
        if next == self.defaults {
            return true;
        }
        if let Some(path) = &self.file_url
            && (self.read_only || EffectDefaultsFile::save(&next, path).is_err())
        {
            return false;
        }
        self.defaults = next;
        self.version += 1;
        true
    }
    // Swift: EffectDefaultsLibrary.swift:45
    pub fn replace(&mut self, new: EffectDefaults) -> bool {
        self.update(|d| *d = new)
    }
}

/// Encoding of effect and transition ids in drags (Swift `EffectDragPayload`).
pub enum EffectDragPayload {}

impl EffectDragPayload {
    // Swift: EffectDragPayload.swift:7
    pub const TRANSITION_PREFIX: &'static str = "transition.";
    // Swift: EffectDragPayload.swift:8
    pub fn transition_id(k: TransitionKind) -> String {
        format!("{}{}", Self::TRANSITION_PREFIX, transition_kind_raw(k))
    }
    // Swift: EffectDragPayload.swift:9
    pub fn transition_kind(id: &str) -> Option<TransitionKind> {
        transition_kind_from_raw(id.strip_prefix(Self::TRANSITION_PREFIX)?)
    }
    /// The Effects panel's "Adjustment Layer" entry: a drag or double-click that places an Adjustment Layer clip.
    pub const ADJUSTMENT_LAYER_ID: &'static str = "layer.adjustment";
    /// Whether `id` is the Adjustment Layer entry.
    pub fn is_adjustment_layer(id: &str) -> bool {
        id == Self::ADJUSTMENT_LAYER_ID
    }
    /// How long a new Adjustment Layer from the panel is.
    pub fn adjustment_layer_duration() -> sq_core_time::Time {
        sq_core_time::Time::new(5, 1)
    }
    // Swift: EffectDragPayload.swift:14
    pub fn encode_drag(ids: &[String]) -> String {
        ids.join("\n")
    }
    // Swift: EffectDragPayload.swift:15
    pub fn decode_drag(s: &str) -> Vec<String> {
        s.split('\n').filter(|p| !p.is_empty()).map(str::to_string).collect()
    }
}

/// One section of Effect Controls.
// Swift: EffectSection.swift:5
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum EffectSection {
    Motion,
    Opacity,
    Volume,
    Speed,
    Effect { id: Id, kind: String },
    Mask(Id),
    Animation(AnimationSide),
}

impl EffectSection {
    // Swift: EffectSection.swift:19
    pub fn built_ins() -> [EffectSection; 4] {
        [EffectSection::Motion, EffectSection::Opacity, EffectSection::Volume, EffectSection::Speed]
    }
    /// Stable string form (Swift `rawValue`).
    // Swift: EffectSection.swift:21
    pub fn raw_value(&self) -> String {
        match self {
            EffectSection::Motion => "motion".to_string(),
            EffectSection::Opacity => "opacity".to_string(),
            EffectSection::Volume => "volume".to_string(),
            EffectSection::Speed => "speed".to_string(),
            EffectSection::Effect { id, kind } => format!("fx:{}:{kind}", id),
            EffectSection::Mask(id) => format!("mask:{}", id),
            EffectSection::Animation(side) => format!("anim:{}", side_raw(*side)),
        }
    }
    // Swift: EffectSection.swift:33
    pub fn from_raw_value(raw: &str) -> Option<EffectSection> {
        if let Some(rest) = raw.strip_prefix("mask:")
            && let Some(id) = Id::parse(rest)
        {
            return Some(EffectSection::Mask(id));
        }
        if let Some(rest) = raw.strip_prefix("anim:")
            && let Some(side) = AnimationSide::ALL.into_iter().find(|s| side_raw(*s) == rest)
        {
            return Some(EffectSection::Animation(side));
        }
        match raw {
            "motion" => Some(EffectSection::Motion),
            "opacity" => Some(EffectSection::Opacity),
            "volume" => Some(EffectSection::Volume),
            "speed" => Some(EffectSection::Speed),
            _ => {
                let mut parts = raw.splitn(3, ':');
                let (tag, id, kind) = (parts.next()?, parts.next()?, parts.next()?);
                (tag == "fx").then_some(())?;
                Some(EffectSection::Effect { id: Id::parse(id)?, kind: kind.to_string() })
            }
        }
    }
    // Swift: EffectSection.swift:48
    pub fn title(&self) -> String {
        match self {
            // Quiet display names; the ids stay "motion" / "opacity".
            EffectSection::Motion => "Transform".to_string(),
            EffectSection::Opacity => "Blend".to_string(),
            EffectSection::Volume => "Volume".to_string(),
            EffectSection::Speed => "Speed".to_string(),
            EffectSection::Effect { kind, .. } => EffectCatalog::title_for(kind),
            EffectSection::Mask(_) => "Mask".to_string(),
            EffectSection::Animation(side) => format!("{} Animation", side.title()),
        }
    }
    // Swift: EffectSection.swift:62
    pub fn effect_kind(&self) -> Option<&str> {
        match self {
            EffectSection::Effect { kind, .. } => Some(kind),
            _ => None,
        }
    }
    // Swift: EffectSection.swift:66
    pub fn effect_id(&self) -> Option<Id> {
        match self {
            EffectSection::Effect { id, .. } => Some(*id),
            _ => None,
        }
    }
}

fn side_raw(side: AnimationSide) -> &'static str {
    if side == AnimationSide::Intro { "intro" } else { "outro" }
}

/// The stored identifier of a transition kind (Swift `rawValue`).
pub(crate) fn transition_kind_raw(k: TransitionKind) -> String {
    serde_json::to_value(k).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

/// The kind with the stored identifier `raw`.
pub(crate) fn transition_kind_from_raw(raw: &str) -> Option<TransitionKind> {
    serde_json::from_value(serde_json::Value::String(raw.to_string())).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drag_payload_round_trips() {
        let ids = vec!["a".to_string(), "transition.crossDissolve".to_string()];
        assert_eq!(EffectDragPayload::decode_drag(&EffectDragPayload::encode_drag(&ids)), ids);
        assert_eq!(EffectDragPayload::transition_kind("transition.crossDissolve"), Some(TransitionKind::CrossDissolve));
        assert_eq!(EffectDragPayload::transition_kind("crossDissolve"), None);
        assert_eq!(EffectDragPayload::transition_id(TransitionKind::DipToBlack), "transition.dipToBlack");
    }

    #[test]
    fn section_raw_values_round_trip() {
        let id = Id::from_u128(7);
        for s in [
            EffectSection::Motion,
            EffectSection::Speed,
            EffectSection::Effect { id, kind: "blur:x".to_string() },
            EffectSection::Mask(id),
            EffectSection::Animation(AnimationSide::Outro),
        ] {
            assert_eq!(EffectSection::from_raw_value(&s.raw_value()), Some(s));
        }
        assert_eq!(EffectSection::from_raw_value("nope"), None);
        assert_eq!(EffectSection::Motion.title(), "Transform");
        assert_eq!(EffectSection::Animation(AnimationSide::Intro).title(), "Intro Animation");
    }
}
