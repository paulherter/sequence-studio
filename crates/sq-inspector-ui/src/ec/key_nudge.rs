// Swift: EffectControlsModel+KeyNudge.swift
//! Comma / Period nudge of the selected keys.

use sq_core_time::Time;

use crate::ec::effect_controls_model::core::EffectControlsModel;

impl EffectControlsModel {
    /// Comma / Period (Shift: 10 frames): moves the selected keys (all properties) by `frames` whole frames, one undo
    /// step. A key never lands on a neighbor (it snaps a frame further, nothing merges). Returns the delta applied
    /// (`Time::ZERO` = nothing moved, no edit was sent). The keys stay selected.
    pub fn nudge_selected_keys(&mut self, frames: i64) -> Time {
        if frames == 0 || self.selection.is_empty() {
            return Time::ZERO;
        }
        self.begin_gesture();
        let applied = self.move_selection(Time::frames(frames, self.frame_duration), false);
        self.end_key_move();
        applied
    }
}
