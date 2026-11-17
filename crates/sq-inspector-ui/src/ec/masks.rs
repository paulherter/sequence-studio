// Swift: EffectControlsModel+Masks.swift (`trackMask` is the host's, see below), +MaskTool.swift
//! W6.7 MasksV1: the minimal editing hooks for clip masks (add, delete, drag a vertex in the Program monitor) and the
//! Mask tool on the Program monitor (Magic / Pen / Ellipse / Rectangle) with how a mask is used: cutting the picture
//! (Opacity) and/or as the input of picture effects.
// `trackMask` lives in the host: `PanelEvent::TrackMask` -> `FlowRequest::TrackMask` (sq-app-hosts `inspector_host.rs`,
// `analysis_links/magic_flow.rs`).

use sq_core_masks::mask_inputs::MaskInputsExt;
use sq_core_masks::mask_path_editing::{MaskPathEditingExt, MaskTrackingExt};
use sq_core_masks::masks::MaskPathExt;
use sq_core_model::{Clip, ClipMask, EffectCatalog, MagicPoint, MaskMode, MaskPath, MaskShapeKind, MaskSource};
use sq_core_time::{Id, Time, Vec2};
use sq_draw::monitor::mask_overlay_geometry::MaskOverlay;
use sq_editor_session::{EffectSection, MaskToolMode};

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::prelude::*;

/// What a Magic click changes, not applied yet: a host that has to store a matte for it first applies it only when
/// that worked, so the project never holds a point without a matte.
#[derive(Clone, Debug)]
pub struct MagicClickEdit {
    clip: Clip,
    pub mask: Id,
    name: String,
    /// The mask's matte cache key after the click.
    pub key: Option<String>,
}

impl MagicClickEdit {
    /// The mask's points after the click.
    pub fn points(&self) -> Vec<MagicPoint> {
        self.clip.mask(self.mask).and_then(|m| m.magic.as_ref()).map(|s| s.points.clone()).unwrap_or_default()
    }
}

/// An enabled mask's choice of an effect that takes a mask input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MaskInputChoice {
    pub effect: Id,
    pub title: String,
    pub on: bool,
}

impl EffectControlsModel {
    /// Enabled masks of the clip with their paths at the playhead, for the Program monitor overlay. Subject masks (W9.8, a
    /// person matte) have no path to show or drag, so they get no outline and no handles.
    pub fn mask_overlays(&self) -> Vec<MaskOverlay> {
        let Some(c) = &self.clip else { return Vec::new() };
        let local = self.local_playhead();
        let active = self.active_mask_id();
        c.masks()
            .iter()
            .filter(|m| m.enabled && m.source() == MaskSource::Path)
            .map(|m| MaskOverlay::new(m.id, m.path.value_at_local(local), Some(m.id) == active))
            .collect()
    }

    /// The mask the pen handles edit: the one selected in Effect Controls, else the clip's only enabled path mask.
    pub fn active_mask_id(&self) -> Option<Id> {
        let c = self.clip.as_ref()?;
        let paths: Vec<&ClipMask> = c.masks().iter().filter(|m| m.enabled && m.source() == MaskSource::Path).collect();
        if let Some(EffectSection::Mask(id)) = &self.selected_section
            && paths.iter().any(|m| m.id == *id)
        {
            return Some(*id);
        }
        if paths.len() == 1 { Some(paths[0].id) } else { None }
    }

    /// Edits the path shown at the playhead (a key there when animated; nothing outside the clip then). Inside a gesture
    /// `body` starts from the gesture base, so a drag is one undo step.
    fn edit_mask_path_at_playhead(&mut self, id: Id, name: &str, body: impl FnOnce(&mut MaskPath) -> bool) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.path.is_animated() && !self.playhead_in_clip() {
            return;
        }
        let local = self.local_playhead();
        let mut path = m.path.value_at_local(local);
        if !body(&mut path) {
            return;
        }
        c.set_mask_path(id, path, local, &mut *self.ids);
        self.commit(c, name, None);
    }

    /// True when editing this mask's path would do nothing: it is animated and the playhead is outside the clip (no key to write).
    pub fn mask_edit_needs_playhead(&self, id: Id) -> bool {
        self.clip.as_ref().and_then(|c| c.mask(id)).is_some_and(|m| m.path.is_animated() && !self.playhead_in_clip())
    }

    /// Drags a tangent handle to `offset` (from its vertex); the other side mirrors unless `independent` (Option).
    pub fn move_mask_tangent(&mut self, id: Id, index: usize, out: bool, offset: Vec2, independent: bool) {
        self.edit_mask_path_at_playhead(id, "Move Mask Handle", |p| {
            if index >= p.vertices.len() {
                return false;
            }
            p.set_tangent(index, out, offset, independent);
            true
        });
    }

    /// Moves the whole mask by `d` (frame fractions) from where the gesture began.
    pub fn move_mask(&mut self, id: Id, d: Vec2) {
        self.edit_mask_path_at_playhead(id, "Move Mask", |p| {
            *p = p.translated(d);
            true
        });
    }

    /// Option-click on a vertex: corner <-> smooth.
    pub fn toggle_mask_vertex_smooth(&mut self, id: Id, index: usize) {
        self.edit_mask_path_at_playhead(id, "Convert Mask Vertex", |p| {
            if index >= p.vertices.len() {
                return false;
            }
            *p = p.toggling_smooth(index);
            true
        });
    }

    /// Click on the outline: a vertex there, in the static path and every key (keys keep blending).
    pub fn insert_mask_vertex(&mut self, id: Id, segment: usize, t: f64) {
        let Some(mut c) = self.working_clip() else { return };
        if c.mask(id).is_none() {
            return;
        }
        c.insert_mask_vertex(id, segment, t);
        self.commit(c, "Add Mask Vertex", None);
    }

    /// Pen: press on the outline places a vertex, dragging pulls its handles to `handle` (offset from the point; mirrored
    /// unless `independent`). Inside a gesture every call starts from the gesture base, so a drag is one undo step.
    pub fn place_mask_vertex(&mut self, id: Id, segment: usize, t: f64, handle: Vec2, independent: bool) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.path.is_animated() && !self.playhead_in_clip() {
            return;
        }
        let local = self.local_playhead();
        c.place_mask_vertex(id, segment, t, handle, independent, local, &mut *self.ids);
        self.commit(c, "Add Mask Vertex", None);
    }

    /// Command-click on a vertex: deletes it from the path and every key (a mask keeps at least three).
    pub fn remove_mask_vertex(&mut self, id: Id, index: usize) {
        let Some(mut c) = self.working_clip() else { return };
        if !c.remove_mask_vertex(id, index) {
            self.notice("A mask needs at least three points.");
            return;
        }
        self.commit(c, "Delete Mask Vertex", None);
    }

    /// Adds a centered Rectangle or Ellipse mask (Premiere's defaults: half the frame, feather 10). Returns its id.
    pub fn add_mask(&mut self, kind: MaskShapeKind) -> Option<Id> {
        let mut c = self.working_clip()?;
        let m = ClipMask::make(self.ids.next_id(), kind, &c.next_mask_name());
        let id = m.id;
        let mut masks = c.masks().to_vec();
        masks.push(m);
        c.set_masks(masks);
        self.commit(c, "Add Mask", None);
        Some(id)
    }

    /// Deletes every mask of the clip, one undo step.
    pub fn remove_all_masks(&mut self) {
        let Some(mut c) = self.working_clip() else { return };
        if c.masks().is_empty() {
            return;
        }
        let ids: Vec<Id> = c.masks().iter().map(|m| m.id).collect();
        for id in &ids {
            c.remove_mask(*id);
        }
        self.forget_removed_masks(&ids);
        self.commit(c, "Delete Masks", None);
    }

    /// Moves one vertex of the path at the playhead (a key there when the path is animated; nothing outside the clip then).
    /// Inside a gesture every call starts from the gesture base, one undo step per drag.
    pub fn move_mask_vertex(&mut self, id: Id, index: usize, to: Vec2) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.path.is_animated() && !self.playhead_in_clip() {
            return;
        }
        let local = self.local_playhead();
        let mut path = m.path.value_at_local(local);
        if index >= path.vertices.len() {
            return;
        }
        path.move_vertex(index, to);
        c.set_mask_path(id, path, local, &mut *self.ids);
        self.commit(c, "Move Mask Vertex", None);
    }

    /// W9.8: subject masks of the clip, top first: one Effect Controls entry each under Opacity.
    pub fn subject_mask_ids(&self) -> Vec<Id> {
        self.clip
            .as_ref()
            .map(|c| c.masks().iter().filter(|m| m.source() == MaskSource::Subject).map(|m| m.id).collect())
            .unwrap_or_default()
    }

    /// C6: Picture masks of the clip (their rows differ: a track and a channel instead of a path, no Feather / Expansion).
    pub fn magic_mask_ids(&self) -> std::collections::BTreeSet<Id> {
        self.clip
            .as_ref()
            .map(|c| c.masks().iter().filter(|m| m.source() == MaskSource::Magic).map(|m| m.id).collect())
            .unwrap_or_default()
    }

    pub fn picture_mask_ids(&self) -> std::collections::BTreeSet<Id> {
        self.clip
            .as_ref()
            .map(|c| c.masks().iter().filter(|m| m.source() == MaskSource::Picture).map(|m| m.id).collect())
            .unwrap_or_default()
    }

    pub fn set_mask_inverted(&mut self, id: Id, on: bool) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.inverted == on {
            return;
        }
        c.update_mask(id, |m| m.inverted = on);
        self.commit(c, "Invert Mask", None);
    }

    pub fn set_mask_mode(&mut self, id: Id, mode: MaskMode) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.mode == mode {
            return;
        }
        c.update_mask(id, |m| m.mode = mode);
        self.commit(c, "Change Mask Mode", None);
    }

    // MARK: Mask tool

    /// The Magic mask clicks add to: the one selected in Effect Controls, else the clip's only Magic mask.
    pub fn active_magic_mask_id(&self) -> Option<Id> {
        let c = self.clip.as_ref()?;
        let magic: Vec<&ClipMask> = c.masks().iter().filter(|m| m.source() == MaskSource::Magic).collect();
        if let Some(EffectSection::Mask(id)) = &self.selected_section
            && magic.iter().any(|m| m.id == *id)
        {
            return Some(*id);
        }
        if magic.len() == 1 { Some(magic[0].id) } else { None }
    }

    /// A click of the Mask tool at frame fraction `p` (0...1, origin top left). Magic: picks the object there (adds to the
    /// active Magic mask, `subtract` = Option removes); Pen: a corner point on the active path mask; Ellipse / Rectangle:
    /// a new shape centered there. `new_mask` (Shift) starts a new mask. Selects the mask; nil = nothing changed.
    /// A Magic click on another frame than the pick's corrects the pick from there on (`magic_click_edit`).
    pub fn mask_tool_click(&mut self, mode: MaskToolMode, p: Vec2, subtract: bool, new_mask: bool) -> Option<Id> {
        let mut c = self.working_clip()?;
        if !self.playhead_in_clip() {
            return None;
        }
        let (id, name) = match mode {
            MaskToolMode::Magic => {
                let e = self.magic_click_edit(p, subtract, new_mask)?;
                return Some(self.apply_magic_click(&e));
            }
            MaskToolMode::Pen => {
                let target = if new_mask { None } else { self.active_mask_id() };
                (c.pen_click(target, p, self.local_playhead(), &mut *self.ids), "Add Mask Point")
            }
            MaskToolMode::Ellipse => (c.add_shape_mask_at(MaskShapeKind::Ellipse, p, &mut *self.ids), "Add Mask"),
            MaskToolMode::Rectangle => (c.add_shape_mask_at(MaskShapeKind::Rectangle, p, &mut *self.ids), "Add Mask"),
        };
        self.commit(c, name, None);
        self.selected_section = Some(EffectSection::Mask(id));
        Some(id)
    }

    /// A Magic click at frame fraction `p` on the playhead's frame, nil = it changes nothing. Its point is stored at the
    /// clip's source time of that frame (rational); on another frame than the pick's it is a correction.
    pub fn magic_click_edit(&mut self, p: Vec2, subtract: bool, new_mask: bool) -> Option<MagicClickEdit> {
        let mut c = self.working_clip()?;
        if !self.playhead_in_clip() {
            return None;
        }
        let last = (c.duration() - self.frame_duration).max(Time::ZERO);
        let local = self.local_playhead().snapped(self.frame_duration).min(last);
        let target = if new_mask { None } else { self.active_magic_mask_id() };
        let here = c.source_instant(local);
        let anchor = target.and_then(|t| c.mask(t)).and_then(|m| m.magic.as_ref()).and_then(|s| s.anchor_time());
        let picks = anchor.is_none() || anchor == Some(here);
        let id = c.magic_click(target, p, subtract, here, &mut *self.ids)?;
        let name = if subtract {
            "Remove from Magic Mask"
        } else if picks {
            "Magic Mask Pick"
        } else {
            "Add to Magic Mask"
        };
        let key = c.mask(id).and_then(|m| Self::magic_cache_key(m, &c));
        Some(MagicClickEdit { clip: c, mask: id, name: name.to_string(), key })
    }

    /// Applies a Magic click (one undo step) and selects its mask.
    pub fn apply_magic_click(&mut self, e: &MagicClickEdit) -> Id {
        self.commit(e.clip.clone(), &e.name, None);
        self.selected_section = Some(EffectSection::Mask(e.mask));
        e.mask
    }

    /// Ellipse / Rectangle drawn by dragging with the Mask tool (`MaskShapeDrag`): one undo step on release; selects it.
    pub fn add_drawn_mask(&mut self, kind: MaskShapeKind, path: MaskPath) -> Option<Id> {
        let mut c = self.working_clip()?;
        if !self.playhead_in_clip() {
            return None;
        }
        let id = c.add_shape_mask_path(kind, path, &mut *self.ids);
        self.commit(c, "Add Mask", None);
        self.selected_section = Some(EffectSection::Mask(id));
        Some(id)
    }

    /// Selects a mask (its Effect Controls row; the monitor shows its handles). No edit.
    pub fn select_mask(&mut self, id: Id) {
        if self.clip.as_ref().and_then(|c| c.mask(id)).is_none()
            || self.selected_section == Some(EffectSection::Mask(id))
        {
            return;
        }
        self.clear_selection();
        self.selected_section = Some(EffectSection::Mask(id));
    }

    /// Cache key of a Magic mask's mattes (`MagicMatteStore`): changes with every click of the pick. Holds the followed
    /// objects as they are (for a Face / Skin mask made by Anonymize: the whole person).
    pub fn magic_cache_key_of(&self, id: Id) -> Option<String> {
        let c = self.clip.as_ref()?;
        let m = c.mask(id)?;
        Self::magic_cache_key(m, c)
    }

    /// Cache key of the narrowed mattes a Face / Skin mask made by Anonymize draws; nil for every other mask.
    pub fn magic_part_key(&self, id: Id) -> Option<String> {
        let c = self.clip.as_ref()?;
        let m = c.mask(id)?;
        if m.source() != MaskSource::Magic {
            return None;
        }
        let sel = m.magic.as_ref()?;
        if sel.points.is_empty() {
            return None;
        }
        sel.part_key(c.media)
    }

    /// Whether a Magic click on the playhead's frame corrects mask `id` (a frame other than its pick's) rather than picking.
    pub fn magic_click_corrects(&self, id: Id) -> bool {
        let Some(c) = &self.clip else { return false };
        if !self.playhead_in_clip() {
            return false;
        }
        let Some(anchor) = c.mask(id).and_then(|m| m.magic.as_ref()).and_then(|s| s.anchor_time()) else {
            return false;
        };
        let last = (c.duration() - self.frame_duration).max(Time::ZERO);
        let local = self.local_playhead().snapped(self.frame_duration).min(last);
        c.source_instant(local) != anchor
    }

    /// Track Forward / Backward of a Magic mask: source seconds from the playhead's frame to the clip's last (first) frame.
    pub fn magic_track_range(&self, id: Id, forward: bool) -> Option<(f64, f64)> {
        let c = self.clip.as_ref()?;
        if c.mask(id)?.source() != MaskSource::Magic || !self.playhead_in_clip() {
            return None;
        }
        let last = (c.duration() - self.frame_duration).max(Time::ZERO);
        let local = self.local_playhead().snapped(self.frame_duration).min(last);
        let s = |t: Time| -> f64 {
            let x = c.source_instant(t);
            x.value() as f64 / x.timescale().max(1) as f64
        };
        Some((s(local), s(if forward { last } else { Time::ZERO })))
    }

    /// Whether the mask cuts the clip's picture (Opacity); off = it only limits the effects that use it.
    pub fn set_mask_used_by_opacity(&mut self, id: Id, on: bool) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.used_by_opacity() == on {
            return;
        }
        c.set_mask_used_by_opacity(id, on);
        self.commit(c, "Mask Cuts Picture", None);
    }

    /// Adds or removes the mask as an input of a picture effect.
    pub fn set_mask_input(&mut self, id: Id, on: bool, effect_id: Id) {
        let Some(mut c) = self.working_clip() else { return };
        let before = c.effects.iter().find(|e| e.id == effect_id).map(|e| e.mask_input.clone());
        c.set_mask_input(id, on, effect_id);
        if c.effects.iter().find(|e| e.id == effect_id).map(|e| e.mask_input.clone()) == before {
            return;
        }
        self.commit(c, if on { "Use Mask in Effect" } else { "Stop Using Mask in Effect" }, None);
    }

    /// The clip's effects that can take a mask input, with whether they use mask `id` (the "Use in" menu).
    pub fn mask_input_choices(&self, id: Id) -> Vec<MaskInputChoice> {
        let Some(c) = &self.clip else { return Vec::new() };
        c.effects
            .iter()
            .filter(|e| c.takes_mask_input(e))
            .map(|e| MaskInputChoice {
                effect: e.id,
                title: EffectCatalog::title_for(&e.kind),
                on: e.mask_input.contains(&id),
            })
            .collect()
    }
}
