//! Format variants of a sequence: which one the monitor shows, edits through it, add/remove/overrides.

use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_effects::sequence_conform::AspectPreset;
use sq_core_graphics::format_variants_view::{
    ProjectVariantsExt, TimelineVariantsExt, VariantError, VariantOverrideExt, VariantProperty,
};
use sq_core_model::{Clip, ConformMode, EditError, FormatVariant, SequenceFormat, Timeline};
use sq_core_time::Id;

use crate::{Change, EditorSession};

/// The edit error a variant error stands for (an unknown variant reads as a missing clip).
fn variant_edit(e: VariantError) -> EditError {
    match e {
        VariantError::Edit(e) => e,
        VariantError::VariantNotFound => EditError::ClipNotFound,
    }
}

impl EditorSession {
    // Swift: EditorSession+Variants.swift:9
    pub fn active_variant_id(&self) -> Option<Id> {
        let t = self.active_timeline()?;
        let v = *self.active_variants.get(&t.id)?;
        t.variant(Some(v)).map(|_| v)
    }
    // Swift: EditorSession+Variants.swift:13
    pub fn active_variant(&self) -> Option<&FormatVariant> {
        self.active_timeline()?.variant(self.active_variant_id())
    }
    // Swift: EditorSession+Variants.swift:17
    pub fn display_format(&self) -> Option<SequenceFormat> {
        self.active_timeline().map(|t| t.format_for(self.active_variant_id()))
    }
    // Swift: EditorSession+Variants.swift:22
    pub fn display_timeline(&self) -> Option<Timeline> {
        let id = self.active_timeline_id?;
        if self.active_variant_id().is_none() {
            return self.active_timeline().cloned();
        }
        if let Some(p) = self.pushed.as_ref().filter(|p| p.timeline.id == id) {
            return Some(p.timeline.clone());
        }
        self.project().variant_view(id, self.active_variant_id()).map(|v| v.timeline)
    }
    // Swift: EditorSession+Variants.swift:31
    pub fn displayed_clip(&self, clip: &Clip) -> Clip {
        match self.active_timeline() {
            Some(t) => self.project().displayed_clip(clip, t, self.active_variant_id()),
            None => clip.clone(),
        }
    }
    // Swift: EditorSession+Variants.swift:37
    pub fn displayed_selected_clip(&self) -> Option<Clip> {
        self.single_selected_clip().cloned().map(|c| self.displayed_clip(&c))
    }
    // Swift: EditorSession+Variants.swift:41
    pub fn replace_displayed_clip(&mut self, clip: Clip, name: &str, continues_gesture: bool) {
        let key = self.gesture_key("clip", clip.id, continues_gesture);
        let Some(v) = self.active_variant_id() else {
            self.attempt_keyed_ids(name, Some(&key), |t, _| t.replace_clip(clip));
            return;
        };
        let conforms = self.project().conforms_picture(&clip, Some(v));
        self.attempt_keyed_ids(name, Some(&key), |t, _| {
            t.apply_displayed_edit(&clip, Some(v), conforms).map_err(variant_edit)
        });
    }
    /// `replace_displayed_clip` of an edit computed from `base` (the displayed clip the panel held), merged onto the
    /// clip the session displays now. See `replace_clip_rebased`.
    pub fn replace_displayed_clip_rebased(&mut self, base: &Clip, clip: Clip, name: &str, continues_gesture: bool) {
        let rebased = match self.clip_in_active(clip.id) {
            Some(stored) => Clip::rebased(base, &clip, &self.displayed_clip(&stored)),
            None => clip,
        };
        self.replace_displayed_clip(rebased, name, continues_gesture);
    }
    // Swift: EditorSession+Variants.swift:51
    pub fn set_active_variant(&mut self, variant: Option<Id>) {
        let Some(t) = self.active_timeline() else { return };
        let (tid, v) = (t.id, t.variant(variant).map(|v| v.id));
        if v == self.active_variant_id() {
            return;
        }
        match v {
            Some(v) => self.active_variants.insert(tid, v),
            None => self.active_variants.remove(&tid),
        };
        self.force_dirty = true; // saved with the project (`active_variants`)
        self.push_timeline(true);
        self.notify(Change::PROJECT | Change::SELECTION);
    }
    /// Opens sequence `id` in a tab showing format variant `variant` (Swift `openSequenceTab(_:variant:)`).
    // Swift: EditorSession+Variants.swift:62
    pub fn open_sequence_tab_variant(&mut self, id: Id, variant: Id) {
        self.open_sequence_tab(id);
        self.set_active_variant(Some(variant));
    }
    // Swift: EditorSession+Variants.swift:68
    pub fn add_variant(&mut self, name: &str, width: i64, height: i64, conform: ConformMode) -> Option<Id> {
        let mut made = None;
        let ok = self.attempt_keyed_ids("Add Format", None, |t, ids| {
            made = Some(t.add_variant(name, width, height, conform, ids).map_err(variant_edit)?);
            Ok(())
        });
        let id = made.filter(|_| ok)?;
        self.set_active_variant(Some(id));
        Some(id)
    }
    // Swift: EditorSession+Variants.swift:78
    pub fn remove_variant(&mut self, id: Id) {
        self.attempt_keyed_ids("Remove Format", None, |t, _| t.remove_variant(id).map_err(variant_edit));
    }
    // Swift: EditorSession+Variants.swift:83
    pub fn has_variant_override(&self, property: VariantProperty, clip: Id) -> bool {
        let (Some(v), Some(t)) = (self.active_variant_id(), self.active_timeline()) else { return false };
        t.override_of(clip, v).is_some_and(|o| o.has(property))
    }
    // Swift: EditorSession+Variants.swift:90
    pub fn reset_variant_override(&mut self, property: VariantProperty, clip: Id) -> bool {
        let Some(v) = self.active_variant_id() else { return false };
        if !self.has_variant_override(property, clip) {
            return false;
        }
        let label = match property {
            VariantProperty::Position => "Position",
            VariantProperty::Scale => "Scale",
            VariantProperty::Rotation => "Rotation",
            VariantProperty::Anchor => "Anchor",
            VariantProperty::Tilt => "Tilt",
        };
        self.attempt_keyed_ids(&format!("Reset {label} to Automatic"), None, |t, _| {
            t.reset_override(Some(property), clip, v).map_err(variant_edit)
        })
    }
    // Swift: EditorSession+Variants.swift:99
    pub fn add_variant_preset(&mut self, preset: &AspectPreset) -> Option<Id> {
        self.add_variant(preset.name, preset.width, preset.height, ConformMode::Fill)
    }
}
