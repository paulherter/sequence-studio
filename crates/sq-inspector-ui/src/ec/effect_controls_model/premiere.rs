// Swift: EffectControlsPremiere.swift
//! Premiere handling on top of `EffectControlsModel`: key copy / paste, interpolation menu choices, snapping while
//! dragging keys, effect copy / paste, twirl-down memory per clip kind, Uniform Scale.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_color::ClipGradeExt;
use sq_core_model::keyframes_clipboard::KeyframeClipboard;
use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyID, SummaryMember};
use sq_core_model::keyframes_pair_ease::PairEase;
use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
use sq_core_model::{Clip, EffectCatalog};
use sq_core_model::{EaseReading, EaseSelection, EaseShape};
use sq_core_time::{EaseSide, Id, Interpolation, Time, Vec2};
use sq_editor_session::{BuiltInClipboard, EffectSection};
use sq_uikit::localization::SQL10n;

use super::core::{EffectControlsModel, TwirlState};
use super::property::{EffectProperty, EffectPropertyKind};

/// Spatial interpolation choices of the right-click menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpatialChoice {
    Linear,
    AutoBezier,
    ContinuousBezier,
}

impl SpatialChoice {
    pub const ALL: [SpatialChoice; 3] =
        [SpatialChoice::Linear, SpatialChoice::AutoBezier, SpatialChoice::ContinuousBezier];

    pub fn title(self) -> &'static str {
        match self {
            SpatialChoice::Linear => "Linear",
            SpatialChoice::AutoBezier => "Auto Bezier",
            SpatialChoice::ContinuousBezier => "Continuous Bezier",
        }
    }
}

impl EffectControlsModel {
    // MARK: Twirl-down state per clip (session only)

    pub(crate) fn save_twirl(&mut self) {
        let Some(id) = self.twirl_clip else { return };
        self.twirl_memory
            .insert(id, TwirlState { collapsed: self.collapsed_sections.clone(), expanded: self.expanded.clone() });
    }

    /// The state a clip starts with: its first section (Transform for video, Volume for audio) open, everything else closed.
    pub(crate) fn default_twirl(&self) -> TwirlState {
        TwirlState { collapsed: self.visible_sections().into_iter().skip(1).collect(), expanded: BTreeSet::new() }
    }

    /// Another clip is shown: it gets its own remembered state, or the default when it has none (a split-off half or a
    /// duplicate is a new clip and starts with the default, not with the state of the clip it came from).
    pub(crate) fn adopt_twirl(&mut self, clip_id: Id) {
        if self.twirl_clip == Some(clip_id) {
            return;
        }
        self.twirl_clip = Some(clip_id);
        let st = self.twirl_memory.get(&clip_id).cloned().unwrap_or_else(|| self.default_twirl());
        self.collapsed_sections = st.collapsed;
        self.expanded = st.expanded;
        self.version += 1;
        self.save_twirl();
    }

    // MARK: Uniform Scale

    pub(crate) fn is_uniform_scale(c: &Clip, _t: Time) -> bool {
        let s = &c.animation.scale;
        if (s.value.x - s.value.y).abs() > 1e-9 {
            return false;
        }
        s.track.keys.iter().all(|k| (k.value.x - k.value.y).abs() < 1e-9)
    }

    /// Checked: Width and Height are one value again (an unequal pair takes Width for both).
    pub fn set_uniform_scale(&mut self, on: bool) {
        if on == self.uniform_scale {
            return;
        }
        self.uniform_scale = on;
        self.version += 1;
        let Some(mut c) = self.clip.clone() else { return };
        if !on || Self::is_uniform_scale(&c, Time::ZERO) {
            return;
        }
        let mut changed = 0usize;
        let local = self.local_playhead();
        Self::with_vector(&mut *self.ids, &mut c, &EffectProperty::Scale, local, |prop, _| {
            changed = prop.track.keys.iter().filter(|k| (k.value.x - k.value.y).abs() > 1e-9).count();
            if changed == 0 && (prop.value.x - prop.value.y).abs() > 1e-9 {
                changed = 1;
            }
            prop.value = Vec2::new(prop.value.x, prop.value.x);
            let key_ids: Vec<Id> = prop.track.keys.iter().map(|k| k.id).collect();
            for id in key_ids {
                prop.track.update(id, |k| k.value = Vec2::new(k.value.x, k.value.x));
            }
        });
        self.commit(c, "Uniform Scale", None);
        if changed > 0 {
            let text = SQL10n::plural(
                changed as i64,
                "Height set to Width on %@ keyframe.",
                "Height set to Width on %@ keyframes.",
            );
            self.notice(&text);
        }
    }

    // MARK: Interpolation (right-click menu)

    pub fn apply_interpolation(&mut self, choice: KeyInterpolationChoice) {
        if choice == KeyInterpolationChoice::HoldAhead && !self.selection_takes_hold_ahead() {
            return;
        }
        // Hold and Hold Ahead write the key's kind (a curve cannot say Hold Ahead), so they never go through a curve.
        let by_choice = choice.hold_kind().is_some()
            || choice.smooths_spatial_path()
            || (choice.pair_ease().is_some() && self.has_selected_pair());
        let working = if by_choice { self.working_clip() } else { None };
        let (true, Some(c)) = (by_choice && !self.selection.is_empty(), working) else {
            self.apply_easing(&choice.curve(), choice.side());
            return;
        };
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        s.apply_choice(choice, &self.selection);
        self.forget_held_kinds();
        let mut out = c;
        let tracks = s.tracks.clone();
        self.write(&tracks, &mut out);
        self.commit(out, "Set Keyframe Easing", None);
    }

    pub fn has_selected_vector_key(&self) -> bool {
        let Some(c) = &self.clip else { return false };
        KeyframeSummary::new(Self::tracks_of(c)).has_vector_key(&self.selection)
    }

    pub fn apply_spatial_interpolation(&mut self, choice: SpatialChoice) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        if !s.has_vector_key(&self.selection) {
            return;
        }
        if choice == SpatialChoice::Linear {
            s.straighten_spatial(&self.selection);
        } else {
            s.smooth_spatial(&self.selection);
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Set Spatial Interpolation", None);
    }

    /// Two adjacent keys of one property are selected: Ease In / Out / In & Out then set both sides of the segment.
    pub fn has_selected_pair(&self) -> bool {
        let Some(c) = &self.clip else { return false };
        KeyframeSummary::new(Self::tracks_of(c)).has_adjacent_pair(&self.selection)
    }

    /// Eases the selected pair(s) (out of the first key, in of the second) as one undo step.
    pub fn apply_pair_ease(&mut self, ease: PairEase) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        if s.apply_pair_ease(ease, &self.selection) == 0 {
            return;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Ease Keyframe Pair", None);
    }

    // MARK: Unified easing (curve popover)

    /// Segments touched by the key selection across all properties (computed from the clip as it was when a gesture
    /// began, so a drag keeps acting on the same segments).
    pub fn ease_selection(&mut self) -> EaseSelection {
        let Some(c) = self.working_clip() else {
            return EaseSelection::new(&KeyframeSummary::new(BTreeMap::new()), &BTreeSet::new(), &BTreeSet::new());
        };
        EaseSelection::new(&KeyframeSummary::new(Self::tracks_of(&c)), &self.selection, &Self::stepped_properties(&c))
    }

    /// Checkbox / choice parameters: hold-only, never eased.
    pub(crate) fn stepped_properties(c: &Clip) -> BTreeSet<PropertyID> {
        Self::all_properties(c)
            .iter()
            .filter(|p| p.param_kind().is_some_and(|k| k.is_stepped()))
            .map(|p| p.id())
            .collect()
    }

    /// Common curve of the selected segments, or the distinct curves when they differ.
    pub fn ease_reading(&self) -> Option<EaseReading> {
        let c = self.clip.as_ref()?;
        let s = KeyframeSummary::new(Self::tracks_of(c));
        Some(EaseSelection::new(&s, &self.selection, &Self::stepped_properties(c)).reading(&s))
    }

    /// Writes one curve to every selected segment: one undo step (inside a gesture, the whole drag is one step).
    pub fn apply_ease_shape(&mut self, shape: &EaseShape) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        if EaseSelection::new(&s.clone(), &self.selection, &Self::stepped_properties(&c)).apply(shape, &mut s) == 0 {
            return;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Set Keyframe Easing", None);
    }

    /// "Custom Curve...": makes the selected keys Bezier (if none is yet), opens the graph under each property of the
    /// selection (twirl) in the value graph, where the selected keys show their handles.
    pub fn reveal_custom_curve(&mut self) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let tracks = Self::tracks_of(&c);
        let any_bezier = self
            .selection
            .iter()
            .any(|m| tracks.get(&m.property).and_then(|t| t.interpolation_of(m.key_id)) == Some(Interpolation::Bezier));
        if !any_bezier {
            self.apply_easing(&KeyInterpolationChoice::Bezier.curve(), EaseSide::Both);
        }
        let ids: BTreeSet<PropertyID> = self.selection.iter().map(|m| m.property.clone()).collect();
        let props: Vec<EffectProperty> =
            Self::all_properties(&c).into_iter().filter(|p| ids.contains(&p.id())).collect();
        let mut e = self.expanded.clone();
        e.extend(props.iter().cloned());
        self.set_expanded(e);
        self.graph_mode = sq_uikit::keyframe_graph_geometry::GraphMode::Speed; // the opened row is the speed graph only
        for p in props {
            self.graph_mode_by_property.insert(p, sq_uikit::keyframe_graph_geometry::GraphMode::Speed);
        }
    }

    // MARK: Copy / paste keys

    pub fn can_paste_keys(&self) -> bool {
        self.key_clipboard.is_some() && self.playhead_in_clip() && self.paste_targets().is_some()
    }

    pub fn copy_keys(&mut self) -> bool {
        let Some(c) = &self.clip else { return false };
        if self.selection.is_empty() {
            return false;
        }
        let mut sel: BTreeMap<PropertyID, BTreeSet<Id>> = BTreeMap::new();
        for m in &self.selection {
            sel.entry(m.property.clone()).or_default().insert(m.key_id);
        }
        let Some(cb) = KeyframeClipboard::copy(&Self::tracks_of(c), &sel) else { return false };
        self.key_clipboard = Some(cb);
        true
    }

    /// Clipboard as it would land on this clip: same properties, or one property retargeted to the focused row.
    fn paste_targets(&self) -> Option<KeyframeClipboard> {
        let cb = self.key_clipboard.as_ref()?;
        let c = self.clip.as_ref()?;
        // Mask Paths take keys too (they have no row of their own: their keys sit on the mask's controls row).
        let paths: Vec<PropertyID> = self
            .visible_sections()
            .iter()
            .filter_map(|s| {
                let EffectSection::Mask(id) = s else { return None };
                use sq_core_masks::masks::ClipMasksExt;
                (c.mask(*id)?.source() == sq_core_model::MaskSource::Path).then(|| EffectProperty::MaskPath(*id).id())
            })
            .collect();
        let mut valid: BTreeSet<PropertyID> = self.panel_properties().iter().map(|p| p.id()).collect();
        valid.extend(paths);
        let ids = cb.property_ids();
        if ids.len() == 1
            && let Some(f) = &self.focused_property
            && valid.contains(&f.id())
            && let Some(r) = cb.retargeted(
                &f.id(),
                matches!(f.kind(), EffectPropertyKind::Vector | EffectPropertyKind::Uniform),
                f.kind() == EffectPropertyKind::Color,
                matches!(f, EffectProperty::MaskPath(_)),
            )
        {
            return Some(r);
        }
        let usable = ids.iter().filter(|p| valid.contains(*p)).count();
        if usable == ids.len() { Some(cb.clone()) } else { None }
    }

    /// Cmd+V: the earliest copied key lands at the playhead; keys at the same time are replaced; keys past the clip end
    /// are dropped. Works across clips and, for one copied property, onto any property of the same value type.
    pub fn paste_keys(&mut self) -> bool {
        let Some(c) = self.clip.clone() else { return false };
        if !self.playhead_in_clip() {
            self.notice("Move the playhead onto the clip to paste keyframes.");
            return false;
        }
        let Some(cb) = self.paste_targets() else { return false };
        let mut tracks = Self::tracks_of(&c);
        let within = Time::ZERO..=self.duration();
        if !cb.paste(&mut tracks, self.local_playhead(), Some(&within), &mut *self.ids) {
            return false;
        }
        let mut out = c.clone();
        // A pair row takes the keys member by member: only the member that mirrored a copied hold leads one again.
        let cb_ids = cb.property_ids();
        let pairs: Vec<EffectProperty> =
            Self::all_properties(&c).into_iter().filter(|p| p.pair().is_some() && cb_ids.contains(&p.id())).collect();
        let mut plain = tracks.clone();
        for p in &pairs {
            plain.remove(&p.id());
        }
        self.write(&plain, &mut out);
        let at = self.local_playhead();
        for p in &pairs {
            let ids = &mut *self.ids;
            Self::with_pair(ids, &mut out, p, |x, y, ids| {
                cb.paste_pair(&p.id(), x, y, at, Some(&within), ids);
            });
        }
        if !pairs.is_empty() {
            tracks = Self::tracks_of(&out);
        }
        // The pasted keys become the selection, so a follow-up drag or interpolation change acts on them.
        let before = Self::tracks_of(&c);
        let mut picked: BTreeSet<SummaryMember> = BTreeSet::new();
        for (p, t) in &tracks {
            if !cb_ids.contains(p) {
                continue;
            }
            let old: BTreeSet<Id> = before.get(p).map(|t| t.key_ids().into_iter().collect()).unwrap_or_default();
            for id in t.key_ids() {
                if !old.contains(&id) {
                    picked.insert(SummaryMember::new(p.clone(), id));
                }
            }
        }
        if picked.is_empty() {
            self.notice("The copied keyframes fall after the end of the clip. Move the playhead earlier.");
            return false;
        }
        let changed = out != c;
        self.commit(out, "Paste Keyframes", None);
        let picked_vec: Vec<SummaryMember> = picked.iter().cloned().collect();
        self.select(&picked_vec, false);
        if picked.len() < cb.key_count() {
            let text = SQL10n::plural(
                (cb.key_count() - picked.len()) as i64,
                "%@ keyframe past the end of the clip was not pasted.",
                "%@ keyframes past the end of the clip were not pasted.",
            );
            self.notice(&text);
        }
        changed
    }

    // MARK: Snapping while dragging keys (Shift)

    /// `delta` moved so the dragged keys stick to the playhead, the clip ends and keys that do not move, within
    /// `threshold_seconds`. Computed from the clip as it was when the gesture began.
    pub fn snapped_move_delta(&mut self, delta: Time, threshold_seconds: f64) -> Time {
        let Some(c) = self.working_clip() else { return delta };
        let all = Self::tracks_of(&c);
        let mut moving: Vec<Time> = Vec::new();
        let mut fixed: Vec<Time> = vec![Time::ZERO, c.duration()];
        if self.playhead_in_clip() {
            fixed.push(self.local_playhead());
        }
        for (p, t) in &all {
            for (id, time) in t.times() {
                if self.selection.contains(&SummaryMember::new(p.clone(), id)) {
                    moving.push(time);
                } else {
                    fixed.push(time);
                }
            }
        }
        let mut best = delta;
        let mut best_dist = threshold_seconds;
        for m in &moving {
            for f in &fixed {
                let d = *f - *m;
                let diff = d - delta;
                let dist = (diff.value() as f64 / diff.timescale().max(1) as f64).abs();
                if dist <= best_dist {
                    best_dist = dist;
                    best = d;
                }
            }
        }
        best
    }

    // MARK: Edit menu while Effect Controls has focus

    /// Cmd+C: the selected keyframes, else the selected effect. Returns false when there is nothing to copy.
    pub fn copy_focused(&mut self) -> bool {
        if !self.selection.is_empty() {
            return self.copy_keys() && self.mark_copied(true);
        }
        if let Some(s) = self.selected_section.clone()
            && self.copy_effect(&s)
        {
            return self.mark_copied(false);
        }
        false
    }

    fn mark_copied(&mut self, keys: bool) -> bool {
        self.last_copy_was_keys = keys;
        true
    }

    /// Keyframes were copied last and are still on the clipboard: Cmd+V stays in Effect Controls even when they do not fit.
    pub fn has_key_clipboard(&self) -> bool {
        self.last_copy_was_keys && self.key_clipboard.is_some()
    }

    pub fn can_copy_focused(&self) -> bool {
        !self.selection.is_empty() || self.selected_section.as_ref().is_some_and(|s| self.can_copy_effect(s))
    }

    pub fn can_paste_focused(&self) -> bool {
        if self.last_copy_was_keys { self.can_paste_keys() } else { self.can_paste_effect() }
    }

    /// Cmd+V: what was copied last, keys at the playhead or the effect onto this clip.
    pub fn paste_focused(&mut self) -> bool {
        if self.last_copy_was_keys { self.paste_keys() } else { self.paste_effect() }
    }

    /// Cmd+X: copy, then delete what was copied.
    pub fn can_cut_focused(&self) -> bool {
        !self.selection.is_empty() || self.selected_section.as_ref().is_some_and(|s| self.can_remove_effect(s))
    }

    /// Delete / Backspace: selected keys, else the selected effect (a removable one) or mask.
    pub fn can_delete_focused(&self) -> bool {
        !self.selection.is_empty() || self.selected_section.as_ref().is_some_and(|s| self.can_delete_section(s))
    }

    pub fn cut_focused(&mut self) {
        if !(self.can_cut_focused() && self.copy_focused()) {
            return;
        }
        self.delete_selection_or_effect();
    }

    // MARK: Copy / paste effects

    fn can_paste_built_in_copy(&self) -> bool {
        if let Some(h) = &self.can_paste_built_in {
            return h();
        }
        let (Some((section, _)), Some(c)) = (&self.built_in_copy, &self.clip) else { return false };
        BuiltInClipboard::group_for(section.clone()).is_some_and(|g| g.kind() == c.kind)
    }

    /// Cmd+V after copying Transform / Blend / Volume: values and keyframes replace the same group on the selected clips
    /// (the session), or on the shown clip when no session is wired.
    fn paste_built_in_copy(&mut self) -> bool {
        let Some((section, source)) = self.built_in_copy.clone() else { return false };
        let Some(g) = BuiltInClipboard::group_for(section.clone()) else { return false };
        if let Some(h) = &mut self.on_paste_built_in {
            return h();
        }
        let Some(c) = self.clip.clone() else { return false };
        if g.kind() != c.kind {
            return false;
        }
        let out =
            sq_editor_session::pasting_attributes_in_groups(&c, &source, &BTreeSet::from([g]), false, &mut *self.ids);
        if out == c {
            return false;
        }
        self.commit(out, &format!("Paste {}", section.title()), None);
        true
    }

    pub fn copy_effect(&mut self, s: &EffectSection) -> bool {
        if BuiltInClipboard::group_for(s.clone()).is_some() {
            let Some(c) = self.clip.clone() else { return false };
            if !self.can_copy_effect(s) {
                return false;
            }
            self.built_in_copy = Some((s.clone(), c.clone()));
            self.effect_clipboard = None;
            self.events.push(super::core::EffectControlsEvent::BuiltInCopied { section: s.clone(), clip: c });
            return true;
        }
        let Some(id) = s.effect_id() else { return false };
        let Some(e) = self.clip.as_ref().and_then(|c| c.effects.iter().find(|e| e.id == id)).cloned() else {
            return false;
        };
        self.effect_clipboard = Some(e.clone());
        self.built_in_copy = None;
        self.events.push(super::core::EffectControlsEvent::EffectCopied(e));
        true
    }

    pub fn can_paste_effect(&self) -> bool {
        if self.built_in_copy.is_some() {
            return self.can_paste_built_in_copy();
        }
        let (Some(e), Some(c)) = (&self.effect_clipboard, &self.clip) else { return false };
        if e.is_audio() && self.shows_audio_partner() {
            return true; // lands on the linked audio clip (AUDIO-FX)
        }
        c.can_accept_pasted_effect(e)
    }

    /// Adds the copied effect to the clip as a new instance behind the existing ones (Premiere adds, it does not replace).
    /// A generator-owned effect replaces the clip's own instance instead (a shape has exactly one Shape effect).
    /// A Color effect goes behind the clip's Color effects (color stays first; see `Clip.insertPastedEffect`).
    pub fn paste_effect(&mut self) -> bool {
        if self.built_in_copy.is_some() {
            return self.paste_built_in_copy();
        }
        if !self.can_paste_effect() {
            return false;
        }
        let (Some(mut c), Some(mut e)) = (self.clip.clone(), self.effect_clipboard.clone()) else { return false };
        if EffectCatalog::is_generator_owned(&e.kind) {
            e.id = self.ids.next_id();
            if let Some(i) = c.effects.iter().position(|x| x.kind == e.kind) {
                c.effects[i] = e;
            } else {
                c.effects.insert(0, e);
            }
        } else if e.is_audio() && self.shows_audio_partner() {
            e.id = self.ids.next_id();
            c.effects.push(e); // the partner's audio effects are last; `commit` routes it
        } else if !c.insert_pasted_effect(&e, &mut *self.ids) {
            return false;
        }
        self.commit(c, "Paste Effect", None);
        true
    }
}

/// Which handler gets Cut / Copy / Paste: Effect Controls only when the first responder is inside it, or when it is the
/// focused panel and has something to do. Otherwise the normal (timeline) command runs.
pub enum EffectControlsEditRouting {}

impl EffectControlsEditRouting {
    pub fn effect_controls_handles(responder_inside: bool, panel_focused: bool, can_act: bool) -> bool {
        responder_inside || (panel_focused && can_act)
    }
}
