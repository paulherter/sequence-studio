// Swift: EffectControlsModel+ColorRangeMask.swift
//! v87 Color range mask UI: adding one and the edits of its rows (color, tolerance, softness). Evaluation is in the core
//! crates and the renderer. Each edit is one undo step; a drag inside a gesture coalesces into one.

use std::collections::BTreeSet;

use sq_core_model::{ClipMask, ColorRangeKey, MaskSource, TrackKind};
use sq_core_time::Id;
use sq_editor_session::EffectSection;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::prelude::*;

impl EffectControlsModel {
    /// Color range masks of the clip (their rows differ: a color, tolerance and softness instead of a path, no Feather / Expansion).
    pub fn color_range_mask_ids(&self) -> BTreeSet<Id> {
        self.clip
            .as_ref()
            .map(|c| c.masks().iter().filter(|m| m.source() == MaskSource::ColorRange).map(|m| m.id).collect())
            .unwrap_or_default()
    }

    /// Adds a Color range mask keying `key`, one undo step "Add Mask"; selects it. Returns its id.
    pub fn add_color_range_mask(&mut self, key: ColorRangeKey) -> Option<Id> {
        let mut c = self.working_clip()?;
        if c.kind != TrackKind::Video {
            return None;
        }
        let name = c.next_mask_name();
        let m = ClipMask::make_color_range(self.ids.next_id(), &name, key);
        let id = m.id;
        let mut masks = c.masks().to_vec();
        masks.push(m);
        c.set_masks(masks);
        self.commit(c, "Add Mask", None);
        self.selected_section = Some(EffectSection::Mask(id));
        Some(id)
    }

    /// The key of a Color range mask (nil for any other mask).
    pub fn color_range_of(&self, id: Id) -> Option<ColorRangeKey> {
        let m = self.clip.as_ref()?.mask(id)?;
        (m.source() == MaskSource::ColorRange).then_some(m.color_range())
    }

    /// Changes the key of a Color range mask, one undo step (inside a gesture it joins the gesture's step).
    pub fn set_mask_color_range(&mut self, id: Id, key: ColorRangeKey) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.source() != MaskSource::ColorRange || m.color_range() == key {
            return;
        }
        c.update_mask(id, |m| m.set_color_range(key));
        self.commit(c, "Change Mask Color Range", None);
    }
}
