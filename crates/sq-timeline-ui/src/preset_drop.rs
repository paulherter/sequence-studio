// Swift: PresetDrop.swift
//! A preset drag is handled like an effect drag inside the timeline (same clip-target highlight), under an id with a
//! prefix no effect kind uses; the drop hands it to the preset path instead of the effect path.

use sq_core_time::Id;

/// Effect-drag ids of library presets.
pub struct PresetDrop;

impl PresetDrop {
    const PREFIX: &'static str = "preset:";

    /// The drag id of a library preset.
    pub fn effect_id(id: Id) -> String {
        format!("{}{}", Self::PREFIX, id)
    }

    /// The preset behind a drag id, `None` for an ordinary effect id.
    pub fn preset_id_from_effect_id(s: &str) -> Option<Id> {
        s.strip_prefix(Self::PREFIX).and_then(Id::parse)
    }
}
