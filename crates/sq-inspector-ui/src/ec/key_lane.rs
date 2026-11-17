// Swift: EffectControlsModel+KeyLane.swift
//! The timeline key lane's presses and selection.

use std::collections::BTreeSet;

use sq_core_time::{Id, Time};

use crate::ec::effect_controls_model::core::EffectControlsModel;

impl EffectControlsModel {
    /// A press on a diamond of the timeline key lane: selects every key of the shown section at that timeline time
    /// (Shift toggles it into the selection). False when the time holds no key or the lane clip is not the shown clip.
    pub fn select_key_lane_key(&mut self, clip: Id, time: Time, extend: bool) -> bool {
        let Some(c) = self.clip.clone() else { return false };
        if c.id != clip {
            return false;
        }
        let Some(section) = self.selected_section.clone() else { return false };
        let Some(key) = self.summary_keys(&section).into_iter().find(|k| c.start + k.time == time) else {
            return false;
        };
        self.select_summary(&key, extend);
        true
    }

    /// Timeline times of the lane keys that are fully selected (the timeline draws them filled).
    pub fn key_lane_selected_times(&self) -> BTreeSet<Time> {
        let (Some(c), Some(section)) = (&self.clip, &self.selected_section) else { return BTreeSet::new() };
        if self.selection.is_empty() {
            return BTreeSet::new();
        }
        self.summary_keys(section).iter().filter(|k| self.is_selected(k)).map(|k| c.start + k.time).collect()
    }
}
