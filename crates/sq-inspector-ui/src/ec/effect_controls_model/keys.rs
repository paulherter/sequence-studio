// Swift: EffectControlsModel.swift (Selection, Key edits on the selection, Reset, enable, remove, Easing library, Graph)
//! Key selection, edits of the selected keys, reset and the section switches.

use std::collections::{BTreeMap, BTreeSet};
use std::ops::RangeInclusive;

use sq_core_color::ColorEffectGroups;
use sq_core_effects::effects_editing::ClipEffectsEditingExt;
use sq_core_graphics::custom_animation::AnimationParam;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyID, PropertyTrack, SummaryKey, SummaryMember};
use sq_core_model::{AnimatedProperty, Clip, ClipAnimation, ClipEffect, EffectCatalog, EffectColor};
use sq_core_time::{EaseSide, EasingCurve, Id, KeyframeTrack, KeyframeValue, Time, Vec2};
use sq_editor_session::{BuiltInClipboard, EffectSection};

use super::core::{EffectControlsEvent, EffectControlsModel, MagicFrameStep};
use super::layout::{GraphProjection, GraphProjectionComponent};
use super::property::{EffectComponent, EffectProperty, EffectPropertyKind};
use super::section::EffectSectionExt;

impl EffectControlsModel {
    // MARK: Selection

    pub(crate) fn prune_selection(&mut self) {
        if self.selection.is_empty() && self.clip.is_some() {
            return; // nothing selected, nothing to prune: skips cloning every key track on each sync
        }
        let Some(c) = self.clip.clone() else {
            self.set_selection(BTreeSet::new());
            return;
        };
        let tracks = Self::tracks_of(&c);
        let mut alive: BTreeSet<SummaryMember> = BTreeSet::new();
        for p in Self::all_properties(&c) {
            let ids: BTreeSet<Id> = tracks.get(&p.id()).map(|t| t.key_ids().into_iter().collect()).unwrap_or_default();
            let pid = p.id();
            alive.extend(self.selection.iter().filter(|m| m.property == pid && ids.contains(&m.key_id)).cloned());
        }
        alive.extend(self.live_magic_members(&self.selection));
        if alive != self.selection {
            self.set_selection(alive);
        }
    }

    pub fn select(&mut self, members: &[SummaryMember], extend: bool) {
        let set: BTreeSet<SummaryMember> = members.iter().cloned().collect();
        let next = if extend { self.selection.symmetric_difference(&set).cloned().collect() } else { set };
        self.set_selection(next);
    }

    /// Keys, section selection and expansion that belonged to deleted masks must not linger (they would target nothing).
    pub(crate) fn forget_removed_masks(&mut self, ids: &[Id]) {
        for id in ids {
            let section = EffectSection::Mask(*id);
            let props = section.properties();
            let pids: BTreeSet<PropertyID> = section.key_properties().iter().map(|p| p.id()).collect();
            let kept: BTreeSet<SummaryMember> =
                self.selection.iter().filter(|m| !pids.contains(&m.property)).cloned().collect();
            self.set_selection(kept);
            let mut expanded = self.expanded.clone();
            for p in &props {
                expanded.remove(p);
            }
            self.set_expanded(expanded);
            if self.selected_section == Some(section) {
                self.selected_section = None;
            }
        }
    }

    pub fn clear_selection(&mut self) {
        if !self.selection.is_empty() {
            self.set_selection(BTreeSet::new());
        }
    }

    /// Replaces this property's selected keys (graph view selection feedback).
    pub fn set_selection_for(&mut self, p: &EffectProperty, ids: &BTreeSet<Id>) {
        let pid = p.id();
        let mut s: BTreeSet<SummaryMember> = self.selection.iter().filter(|m| m.property != pid).cloned().collect();
        for id in ids {
            s.insert(SummaryMember::new(pid.clone(), *id));
        }
        self.set_selection(s);
    }

    pub fn summary_keys(&self, section: &EffectSection) -> Vec<SummaryKey> {
        let Some(c) = &self.clip else { return Vec::new() };
        let props: BTreeSet<PropertyID> = section.key_properties().iter().map(|p| p.id()).collect();
        Self::merging_magic(
            KeyframeSummary::new(Self::tracks_of(c)).groups(Some(&props)),
            self.magic_summary_keys(section),
        )
    }

    /// Summary keys of one closed group of a Color effect (the group's switch and numbers), empty while the group is open.
    pub fn color_group_summary_keys(&self, effect: Id, group_key: &str) -> Vec<SummaryKey> {
        let Some(c) = &self.clip else { return Vec::new() };
        if self.open_color_groups.contains(&Self::color_group_id(effect, group_key)) {
            return Vec::new();
        }
        let params = EffectCatalog::spec_for(ClipEffect::COLOR_KIND).map(|s| s.params).unwrap_or_default();
        let ids: BTreeSet<PropertyID> = params
            .iter()
            .filter(|p| ColorEffectGroups::group_key(&p.key).as_deref() == Some(group_key))
            .map(|p| {
                EffectProperty::Fx { id: effect, kind: ClipEffect::COLOR_KIND.to_string(), key: p.key.clone() }.id()
            })
            .collect();
        KeyframeSummary::new(Self::tracks_of(c)).groups(Some(&ids))
    }

    pub fn is_selected(&self, key: &SummaryKey) -> bool {
        key.members.is_subset(&self.selection)
    }

    pub fn select_summary(&mut self, key: &SummaryKey, extend: bool) {
        if extend {
            let mut s = self.selection.clone();
            if self.is_selected(key) {
                for m in &key.members {
                    s.remove(m);
                }
            } else {
                s.extend(key.members.iter().cloned());
            }
            self.set_selection(s);
        } else {
            self.set_selection(key.members.clone());
        }
    }

    pub fn select_key(&mut self, p: &EffectProperty, id: Id, extend: bool) {
        self.focused_property = Some(p.clone());
        self.select(&[SummaryMember::new(p.id(), id)], extend);
    }

    /// Marquee: all keys of `properties` whose clip-local time lies in `range`.
    pub fn select_keys_in(
        &mut self,
        range: &RangeInclusive<Time>,
        properties: &BTreeSet<EffectProperty>,
        extend: bool,
    ) {
        let hit = self.keys_in(range, properties);
        let next = if extend { self.selection.union(&hit).cloned().collect() } else { hit };
        self.set_selection(next);
    }

    /// All keys of `properties` whose clip-local time lies in `range`.
    pub fn keys_in(
        &self,
        range: &RangeInclusive<Time>,
        properties: &BTreeSet<EffectProperty>,
    ) -> BTreeSet<SummaryMember> {
        let mut hit = BTreeSet::new();
        for p in properties {
            for (id, time) in self.lane_keys(p) {
                if range.contains(&time) {
                    hit.insert(SummaryMember::new(p.id(), id));
                }
            }
        }
        hit
    }

    // MARK: Key edits on the selection

    pub(crate) fn write(&mut self, tracks: &BTreeMap<PropertyID, PropertyTrack>, c: &mut Clip) {
        let local = self.local_playhead();
        for p in Self::all_properties(c) {
            let t = tracks.get(&p.id());
            match &p {
                EffectProperty::Position => {
                    if let Some(PropertyTrack::Vector(v)) = t {
                        c.animation.position.track = v.clone();
                    }
                }
                EffectProperty::Scale => {
                    if let Some(PropertyTrack::Vector(v)) = t {
                        c.animation.scale.track = v.clone();
                    }
                }
                EffectProperty::Anchor => {
                    if let Some(PropertyTrack::Vector(v)) = t {
                        c.animation.anchor.track = v.clone();
                    }
                }
                EffectProperty::Rotation => Self::write_scalar(&mut c.animation.rotation, t),
                EffectProperty::TiltX => Self::write_scalar(&mut c.animation.tilt_x, t),
                EffectProperty::TiltY => Self::write_scalar(&mut c.animation.tilt_y, t),
                EffectProperty::Opacity => Self::write_scalar(&mut c.animation.opacity, t),
                EffectProperty::Volume => Self::write_scalar(&mut c.animation.volume, t),
                EffectProperty::ShutterAngle => Self::write_scalar(&mut c.animation.shutter_angle, t),
                EffectProperty::AntiFlicker => Self::write_scalar(&mut c.animation.anti_flicker, t),
                EffectProperty::Fx { .. } => {
                    let ids = &mut *self.ids;
                    match t {
                        Some(PropertyTrack::Scalar(s)) => Self::with_fx(ids, c, &p, |v, _| v.track = s.clone()),
                        Some(PropertyTrack::Vector(v)) => Self::with_fx_point(ids, c, &p, |x, _| x.track = v.clone()),
                        Some(PropertyTrack::Color(k)) => Self::with_fx_color(ids, c, &p, |x, _| x.track = k.clone()),
                        Some(PropertyTrack::Path(_)) | None => {}
                    }
                }
                EffectProperty::Mask(..) => {
                    if let Some(PropertyTrack::Scalar(s)) = t {
                        Self::with_mask(c, &p, |v| v.track = s.clone());
                    }
                }
                EffectProperty::MaskPath(id) => {
                    if let Some(PropertyTrack::Path(k)) = t {
                        c.update_mask(*id, |m| m.path.track = k.clone());
                    }
                }
                EffectProperty::Anim(..) => {
                    let ids = &mut *self.ids;
                    // Only a row that changed is stored: every other key of the side keeps its id.
                    match t {
                        Some(PropertyTrack::Scalar(s))
                            if Self::anim_scalar(&p, Some(c)).map(|v| v.track) != Some(s.clone()) =>
                        {
                            Self::with_scalar(ids, c, &p, local, |v, _| v.track = s.clone());
                        }
                        Some(PropertyTrack::Vector(v))
                            if Self::anim_vector(&p, Some(c)).map(|x| x.track) != Some(v.clone()) =>
                        {
                            Self::with_vector(ids, c, &p, local, |x, _| x.track = v.clone());
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    fn write_scalar(prop: &mut AnimatedProperty<f64>, t: Option<&PropertyTrack>) {
        if let Some(PropertyTrack::Scalar(s)) = t {
            prop.track = s.clone();
        }
    }

    /// Moves the selected keys (all properties) in time by `delta`, from the gesture base. Not held inside the clip. Keys
    /// pass unselected neighbors; landing exactly on one snaps a frame further (nothing is replaced).
    /// Steps only change the shown clip, `end_key_move` sends the one edit. Returns the delta applied.
    pub fn move_selection(&mut self, delta: Time, duplicate: bool) -> Time {
        let Some(c) = self.working_clip() else { return Time::ZERO };
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let members: BTreeSet<SummaryMember> = self
            .selection
            .iter()
            .filter(|m| s.tracks.get(&m.property).is_some_and(|t| t.key_ids().contains(&m.key_id)))
            .cloned()
            .collect();
        if members.is_empty() {
            return Time::ZERO;
        }
        // Keys may leave the clip on either side (Premiere): they stay in the clip's data, are not drawn, and a Select All
        // still takes them. Only a day either way is the stop, so a runaway drag cannot overflow the time.
        let limits = Time::new(-86_400, 1)..=Time::new(86_400, 1);
        let clamped = delta.max(*limits.start()).min(*limits.end());
        let applied = if duplicate {
            s.move_duplicating(&members, clamped, self.frame_duration, Some(&limits), &mut *self.ids)
        } else {
            s.move_key(&members, clamped, self.frame_duration, Some(&limits))
        };
        let mut out = c;
        self.write(&s.tracks, &mut out);
        if self.in_gesture() {
            self.defer_emit = true;
        }
        self.commit(out, if duplicate { "Duplicate Keyframes" } else { "Move Keyframes" }, None);
        applied
    }

    /// Ends a key drag: one undo step, and the moved keys stay selected (Premiere). A value change at the playhead
    /// still only edits selected keys when the playhead sits on one of them (`selected_keys_at_playhead`).
    pub fn end_key_move(&mut self) {
        let base = self.gesture_base.clone();
        let name = self.deferred_edit_name.take();
        self.defer_emit = false;
        if let (Some(name), Some(c)) = (name, self.clip.clone())
            && Some(&c) != base.as_ref()
        {
            // the one edit of the drag: one undo step
            self.emit(c, base, &name, false);
            self.gesture_emitted = true;
        }
        self.register_pending_frame_steps();
        self.end_gesture();
    }

    pub fn apply_easing(&mut self, curve: &EasingCurve, side: EaseSide) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        s.apply(curve, &self.selection, side);
        self.forget_held_kinds();
        let mut out = c;
        self.write(&s.tracks, &mut out);
        self.commit(out, "Set Keyframe Easing", None);
    }

    /// The selected keys got an ease by name: Toggle Hold has nothing to bring back for them.
    pub(crate) fn forget_held_kinds(&mut self) {
        for m in &self.selection {
            self.held_kinds.remove(&m.key_id);
        }
    }

    /// Hold Ahead can be stored on every selected key. Animation (In/Out) tracks live inside text payloads, templates
    /// and Caption Looks and store it as a Hold, so with one of their keys selected it is not offered.
    pub fn selection_takes_hold_ahead(&self) -> bool {
        !self
            .selection
            .iter()
            .any(|m| EffectProperty::from_raw_value(&m.property.0).is_some_and(|p| p.is_animation_row()))
    }

    /// All selected keys hold: they leave it; otherwise all become a hold, each the kind (Hold or Hold Ahead) it was
    /// when this toggle last took it out (a key it never took out becomes a Hold). The memory only holds while the
    /// clip is the one the last toggle left: undo, a dragged handle or any other edit in between clears it.
    pub fn toggle_hold(&mut self) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        if self.held_kinds_revision != Some(self.clip_revision) {
            self.held_kinds.clear();
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        for m in &self.selection {
            if let Some(kind) = s.interpolation_of(m)
                && kind.is_hold()
            {
                self.held_kinds.insert(m.key_id, kind);
            }
        }
        s.toggle_hold(&self.selection, &self.held_kinds);
        let mut out = c;
        self.write(&s.tracks, &mut out);
        self.commit(out, "Toggle Hold Keyframes", None);
        self.held_kinds_revision = Some(self.clip_revision);
    }

    /// Removes the selected keys. A property left without keys keeps the value it shows at the playhead.
    pub fn delete_selection(&mut self) {
        let Some(mut c) = self.clip.clone() else { return };
        if self.selection.is_empty() {
            return;
        }
        let local = self.local_playhead();
        let before = c.clone();
        for p in Self::all_properties(&c) {
            let ids = self.selected_key_ids(&p);
            if ids.is_empty() {
                continue;
            }
            let key_ids = &mut *self.ids;
            Self::with_vector(key_ids, &mut c, &p, local, |prop, _| Self::remove_all(&ids, prop, local));
            Self::with_scalar(key_ids, &mut c, &p, local, |prop, _| Self::remove_all(&ids, prop, local));
            Self::with_color(key_ids, &mut c, &p, |prop, _| Self::remove_all(&ids, prop, local));
            if let EffectProperty::MaskPath(id) = &p {
                c.update_mask(*id, |m| {
                    let shown = m.path.value_at_local(local);
                    for kid in &ids {
                        m.path.track.remove(*kid);
                    }
                    if m.path.track.is_empty() {
                        m.path.value = shown;
                    }
                });
            }
            Self::follow_shown(key_ids, &mut c, &p, &before, local);
        }
        let gone: Vec<MagicFrameStep> = self.remove_selected_magic_frames(&mut c);
        self.set_selection(BTreeSet::new());
        self.commit(c, "Delete Keyframes", None);
        // The deleted mattes are no project state: their own undo step, so one Undo brings the frames back.
        if !gone.is_empty() {
            if self.defer_emit {
                // Mid key drag the clip edit is not emitted yet: the frames join the drag's one undo step (`end_key_move`).
                self.pending_frame_steps.extend(gone);
            } else {
                self.events
                    .push(EffectControlsEvent::FrameSideStep { name: "Delete Keyframes".to_string(), steps: gone });
            }
        }
    }

    /// The drag's step is in the session: the pending frame deletes belong to it, so it stays ONE undo step.
    fn register_pending_frame_steps(&mut self) {
        if self.pending_frame_steps.is_empty() || !self.has_session {
            return;
        }
        let steps = std::mem::take(&mut self.pending_frame_steps);
        self.events.push(EffectControlsEvent::FrameSideStep { name: "Delete Keyframes".to_string(), steps });
    }

    fn remove_all<V: KeyframeValue>(ids: &BTreeSet<Id>, prop: &mut AnimatedProperty<V>, local: Time) {
        let shown = prop.value_at_local(local);
        for id in ids {
            prop.track.remove(*id);
        }
        if prop.track.is_empty() {
            prop.value = shown;
        }
    }

    // MARK: Reset, enable, remove (Premiere: circular arrow, fx toggle, Delete)

    /// Value a property returns to on reset (no keyframes).
    pub fn default_value(&self, p: &EffectProperty) -> Option<AnimatedProperty<f64>> {
        let d = ClipAnimation::default();
        match p {
            EffectProperty::Rotation => Some(d.rotation),
            EffectProperty::TiltX => Some(d.tilt_x),
            EffectProperty::TiltY => Some(d.tilt_y),
            EffectProperty::Opacity => Some(d.opacity),
            EffectProperty::Volume => Some(d.volume),
            EffectProperty::ShutterAngle => Some(d.shutter_angle),
            EffectProperty::AntiFlicker => Some(d.anti_flicker),
            EffectProperty::Fx { kind, key, .. } => self
                .effect_defaults
                .effect(kind)
                .and_then(|e| e.parameters.get(key).cloned())
                .or_else(|| ClipEffect::default_parameters(kind).get(key).cloned()),
            EffectProperty::Mask(_, m) => Some(AnimatedProperty::new(m.default_value())),
            EffectProperty::Anim(_, param) if *param != AnimationParam::Position => {
                Some(AnimatedProperty::new(param.rest()))
            }
            _ => None,
        }
    }

    /// Default of a color parameter (nil for anything else).
    pub fn default_color(&self, p: &EffectProperty) -> Option<EffectColor> {
        if let EffectProperty::Fx { kind, key, .. } = p
            && let Some(u) = self.effect_defaults.effect(kind).and_then(|e| e.colors.get(key))
        {
            return Some(u.value);
        }
        if let Some(sq_core_model::EffectParamKind::Color(d)) = p.param_kind() {
            return Some(d);
        }
        None
    }

    /// Default of a point parameter (nil for anything else).
    pub fn default_point(&self, p: &EffectProperty) -> Option<Vec2> {
        if let Some(pr) = p.pair()
            && let EffectProperty::Fx { id, kind, .. } = p
        {
            let x = self.default_value(&EffectProperty::Fx { id: *id, kind: kind.clone(), key: pr.x.clone() });
            let y = self.default_value(&EffectProperty::Fx { id: *id, kind: kind.clone(), key: pr.y.clone() });
            if let (Some(x), Some(y)) = (x, y) {
                return Some(Vec2::new(x.value, y.value));
            }
        }
        if let EffectProperty::Fx { kind, key, .. } = p
            && let Some(u) = self.effect_defaults.effect(kind).and_then(|e| e.points.get(key))
        {
            return Some(u.value);
        }
        if let Some(sq_core_model::EffectParamKind::Point(d)) = p.param_kind() {
            return Some(d);
        }
        None
    }

    /// True when the property has no keys and sits at its default (the reset button is dimmed then).
    pub fn is_default(&self, p: &EffectProperty) -> bool {
        let Some(c) = &self.clip else { return true };
        let d = ClipAnimation::default();
        match p {
            EffectProperty::Position => return c.animation.position == d.position,
            EffectProperty::Scale => return c.animation.scale == d.scale,
            EffectProperty::Anchor => return c.animation.anchor == d.anchor,
            EffectProperty::Anim(_, AnimationParam::Position) => {
                return !Self::anim_vector(p, Some(c)).is_some_and(|v| v.is_animated());
            }
            _ => {}
        }
        if let EffectProperty::Fx { id, kind, key } = p {
            if p.kind() == EffectPropertyKind::Color {
                let Some(cur) = Self::color_param(p, Some(c)) else { return true };
                if let Some(u) = self.effect_defaults.effect(kind).and_then(|e| e.colors.get(key))
                    && u.is_animated()
                {
                    return cur.same_curve(u);
                }
                return Some(cur.value) == self.default_color(p) && !cur.is_animated();
            }
            if let Some(pr) = p.pair() {
                // Member by member (the X member's EffectProperty *is* the pair row, so read storage directly).
                let Some(e) = c.effects.iter().find(|e| e.id == *id) else { return true };
                return [pr.x.clone(), pr.y.clone()].iter().all(|k| {
                    let cur = Self::member(e, kind, k);
                    let Some(def) =
                        self.default_value(&EffectProperty::Fx { id: *id, kind: kind.clone(), key: k.clone() })
                    else {
                        return true;
                    };
                    if def.is_animated() { cur.same_curve(&def) } else { cur.value == def.value && !cur.is_animated() }
                });
            }
            if p.kind() == EffectPropertyKind::Vector {
                let Some(cur) = Self::point_param(p, Some(c)) else { return true };
                if let Some(u) = self.effect_defaults.effect(kind).and_then(|e| e.points.get(key))
                    && u.is_animated()
                {
                    return cur.same_curve(u);
                }
                return Some(cur.value) == self.default_point(p) && !cur.is_animated();
            }
        }
        let (Some(cur), Some(def)) = (Self::scalar(p, c), self.default_value(p)) else { return true };
        if def.is_animated() {
            return cur.same_curve(&def);
        }
        cur.value == def.value && !cur.is_animated()
    }

    fn scalar(p: &EffectProperty, c: &Clip) -> Option<AnimatedProperty<f64>> {
        match p {
            EffectProperty::Rotation => Some(c.animation.rotation.clone()),
            EffectProperty::TiltX => Some(c.animation.tilt_x.clone()),
            EffectProperty::TiltY => Some(c.animation.tilt_y.clone()),
            EffectProperty::Opacity => Some(c.animation.opacity.clone()),
            EffectProperty::Volume => Some(c.animation.volume.clone()),
            EffectProperty::ShutterAngle => Some(c.animation.shutter_angle.clone()),
            EffectProperty::AntiFlicker => Some(c.animation.anti_flicker.clone()),
            EffectProperty::Fx { .. } => Self::param(p, Some(c)),
            EffectProperty::Mask(..) => Self::mask_param(p, Some(c)),
            EffectProperty::Anim(..) => Self::anim_scalar(p, Some(c)),
            _ => None,
        }
    }

    fn reset_in_place(&mut self, c: &mut Clip, p: &EffectProperty) {
        let d = ClipAnimation::default();
        match p {
            EffectProperty::Position => c.animation.position = d.position,
            EffectProperty::Scale => c.animation.scale = d.scale,
            EffectProperty::Anchor => c.animation.anchor = d.anchor,
            EffectProperty::Anim(_, AnimationParam::Position) => {
                Self::with_vector(&mut *self.ids, c, p, self.playhead - c.start, |v, _| {
                    *v = AnimatedProperty::new(Vec2::ZERO)
                });
            }
            EffectProperty::Fx { id, kind, key } if p.kind() == EffectPropertyKind::Color => {
                let local = self.local_playhead();
                if let Some(u) = self.effect_defaults.effect(kind).and_then(|e| e.colors.get(key)).cloned() {
                    let ids = &mut *self.ids;
                    let fresh = u.with_fresh_key_ids(ids);
                    Self::with_color(ids, c, p, |v, _| *v = fresh);
                } else if let Some(def) = self.default_color(p) {
                    Self::with_color(&mut *self.ids, c, p, |v, _| *v = AnimatedProperty::new(def));
                }
                let _ = (id, local);
            }
            EffectProperty::Fx { id, kind, .. } if p.pair().is_some() => {
                let Some(pr) = p.pair() else { return };
                let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return };
                for key in [pr.x.clone(), pr.y.clone()] {
                    if let Some(def) =
                        self.default_value(&EffectProperty::Fx { id: *id, kind: kind.clone(), key: key.clone() })
                    {
                        let fresh = def.with_fresh_key_ids(&mut *self.ids);
                        c.effects[i].parameters.insert(key, fresh);
                    }
                }
                if pr.linkable {
                    c.effects[i].parameters.remove(&pr.y); // P5: a reset Scale is linked again
                }
            }
            EffectProperty::Fx { kind, key, .. } if p.kind() == EffectPropertyKind::Vector => {
                let local = self.local_playhead();
                if let Some(u) = self.effect_defaults.effect(kind).and_then(|e| e.points.get(key)).cloned() {
                    let ids = &mut *self.ids;
                    let fresh = u.with_fresh_key_ids(ids);
                    Self::with_vector(ids, c, p, local, |v, _| *v = fresh);
                } else if let Some(def) = self.default_point(p) {
                    Self::with_vector(&mut *self.ids, c, p, local, |v, _| *v = AnimatedProperty::new(def));
                }
            }
            _ => {
                let Some(def) = self.default_value(p) else { return };
                let local = self.local_playhead();
                let ids = &mut *self.ids;
                let fresh = def.with_fresh_key_ids(ids);
                Self::with_scalar(ids, c, p, local, |v, _| *v = fresh);
            }
        }
    }

    /// Reset arrow: the property goes back to its default and its keys are removed, one undo step (animated or not).
    /// "Reset at Playhead" (`reset_at_playhead`) is the separate context-menu item. Always true.
    pub fn reset(&mut self, p: &EffectProperty) -> bool {
        self.reset_all(p);
        true
    }

    /// Default value in place of the value at the playhead (key created or replaced).
    pub fn reset_at_playhead(&mut self, p: &EffectProperty) -> bool {
        let Some(mut c) = self.working_clip() else { return false };
        let local = self.local_playhead();
        if !self.playhead_in_clip() || !self.reset_value(&mut c, p, local, true) {
            return false;
        }
        // Multi-select: every other clip at its own playhead (a static one just gets the default).
        let peers = self.edited_peers(p, |this, c, q, l, r| {
            let _ = this.reset_value(c, q, l, r);
        });
        self.commit(c, &format!("Reset {}", p.title()), peers);
        true
    }

    /// The default in place of `p`'s value at `local` (static: the value; animated: the key there, added when `in_range`).
    fn reset_value(&mut self, c: &mut Clip, p: &EffectProperty, local: Time, in_range: bool) -> bool {
        let d = ClipAnimation::default();
        let mut ok = false;
        let none = BTreeSet::new();
        let point_default = self.default_point(p);
        let color_default = self.default_color(p);
        let scalar_default = self.default_value(p).map(|v| v.value);
        let ids = &mut *self.ids;
        Self::with_vector(ids, c, p, local, |prop, ids| {
            let def: Vec2 = point_default.unwrap_or(if p == &EffectProperty::Position {
                d.position.value
            } else if p == &EffectProperty::Scale {
                d.scale.value
            } else {
                d.anchor.value
            });
            ok = Self::apply(prop, def, local, in_range, &none, false, ids);
        });
        Self::with_scalar(ids, c, p, local, |prop, ids| {
            let Some(def) = scalar_default else { return };
            ok = Self::apply(prop, def, local, in_range, &none, false, ids);
        });
        Self::with_color(ids, c, p, |prop, ids| {
            let Some(def) = color_default else { return };
            ok = Self::apply(prop, def, local, in_range, &none, false, ids);
        });
        ok
    }

    /// Reset one property to its default and drop its keys: one undo step.
    pub fn reset_all(&mut self, p: &EffectProperty) {
        let Some(mut c) = self.clip.clone() else { return };
        self.reset_in_place(&mut c, p);
        let pid = p.id();
        let kept: BTreeSet<SummaryMember> = self.selection.iter().filter(|m| m.property != pid).cloned().collect();
        self.set_selection(kept);
        let peers = self.edited_peers(p, |this, c, q, _, _| this.reset_in_place(c, q));
        self.commit(c, &format!("Reset {}", p.title()), peers);
    }

    /// Reset every property of a section (and re-enable its effect): one undo step.
    pub fn reset_section(&mut self, s: &EffectSection) {
        let Some(mut c) = self.clip.clone() else { return };
        if *s == EffectSection::Speed {
            self.reset_speed();
            return;
        }
        let props = self.properties_of(s);
        self.reset_section_in(s, &props, &mut c);
        let ids: BTreeSet<PropertyID> = props.iter().map(|p| p.id()).collect();
        let kept: BTreeSet<SummaryMember> =
            self.selection.iter().filter(|m| !ids.contains(&m.property)).cloned().collect();
        self.set_selection(kept);
        // Multi-select: the same section of every clip that has it (its properties mapped to that clip).
        let others = if self.is_multi() {
            let base = self.peer_gesture_base.clone().unwrap_or_else(|| self.peers.clone());
            let mut out = Vec::with_capacity(base.len());
            for peer in base {
                let mut o = peer.clone();
                if let Some(t) = self.mapped_section(s, &peer) {
                    let mapped: Vec<EffectProperty> = props.iter().filter_map(|p| self.mapped(p, &peer)).collect();
                    self.reset_section_in(&t, &mapped, &mut o);
                }
                out.push(o);
            }
            Some(out)
        } else {
            None
        };
        self.commit(c, &format!("Reset {}", s.title()), others);
    }

    /// Resets `s` of `c` (its rows `props`) and switches it on again.
    fn reset_section_in(&mut self, s: &EffectSection, props: &[EffectProperty], c: &mut Clip) {
        // FB-W: an effect that can have a user default goes back to it as a whole (keys included), else to factory.
        if let EffectSection::Effect { id, kind } = s
            && EffectDefaults::can_have_default(kind)
        {
            c.reset_effect(*id, Some(&self.effect_defaults), &mut *self.ids);
        } else {
            for p in props {
                self.reset_in_place(c, p); // Transform resets its Crop rows too
            }
        }
        match s {
            EffectSection::Motion => {
                c.motion_enabled = true;
                c.opacity_enabled = true;
                c.blend_mode = sq_core_model::BlendMode::Normal;
            }
            EffectSection::Opacity => {
                c.opacity_enabled = true;
                c.blend_mode = sq_core_model::BlendMode::Normal;
            }
            EffectSection::Volume | EffectSection::Speed | EffectSection::Animation(_) => {}
            EffectSection::Effect { id, .. } => {
                if let Some(i) = c.effects.iter().position(|e| e.id == *id) {
                    c.effects[i].enabled = true;
                }
            }
            EffectSection::Mask(id) => c.update_mask(*id, |m| m.enabled = true),
        }
    }

    // MARK: User defaults (FB-W)

    fn applied_effect(&self, s: &EffectSection) -> Option<&ClipEffect> {
        let EffectSection::Effect { id, .. } = s else { return None };
        self.clip.as_ref()?.effects.iter().find(|e| e.id == *id)
    }

    /// "Use as Default" is offered for applied effects other than Color and generator-owned looks.
    pub fn can_use_as_default(&self, s: &EffectSection) -> bool {
        self.applied_effect(s).is_some_and(|e| EffectDefaults::can_have_default(&e.kind))
    }

    /// The effect's kind has a user default (marker in the header; "Reset" goes back to it).
    pub fn has_user_default(&self, s: &EffectSection) -> bool {
        let EffectSection::Effect { kind, .. } = s else { return false };
        self.effect_defaults.has_default_effect(kind)
    }

    /// The effect has keyframes (the menu then also offers a default without them).
    pub fn effect_is_animated(&self, s: &EffectSection) -> bool {
        self.applied_effect(s).is_some_and(|e| !e.key_times().is_empty())
    }

    /// This effect's values become the default of its kind. `keep_keyframes`: keys stay, relative to the clip's first
    /// frame; otherwise the values shown at the playhead are kept (no keys).
    pub fn use_as_default(&mut self, s: &EffectSection, keep_keyframes: bool) -> bool {
        let (Some(e), Some(c)) = (self.applied_effect(s).cloned(), self.clip.clone()) else { return false };
        let at = self.local_playhead().max(Time::ZERO).min(c.duration());
        let mut d = self.effect_defaults.clone();
        if !d.set_default_effect(&e, keep_keyframes, at, &mut *self.ids) {
            return false;
        }
        self.set_effect_defaults(d);
        true
    }

    /// Deletes the user default of the section's kind: new instances and "Reset" use the built-in values again.
    pub fn reset_default_to_factory(&mut self, s: &EffectSection) {
        let EffectSection::Effect { kind, .. } = s else { return };
        let mut d = self.effect_defaults.clone();
        d.remove_default_effect(kind);
        self.set_effect_defaults(d);
    }

    fn set_effect_defaults(&mut self, d: EffectDefaults) {
        if d == self.effect_defaults {
            return;
        }
        self.effect_defaults = d.clone();
        self.version += 1;
        self.events.push(EffectControlsEvent::EffectDefaultsChange(d));
    }

    pub fn is_effect_enabled(&self, s: &EffectSection) -> bool {
        let c = self.clip.as_ref();
        match s {
            EffectSection::Motion => c.is_none_or(|c| c.motion_enabled) && c.is_none_or(|c| c.opacity_enabled),
            EffectSection::Opacity => c.is_none_or(|c| c.opacity_enabled),
            EffectSection::Volume | EffectSection::Speed | EffectSection::Animation(_) => true,
            EffectSection::Effect { id, .. } => {
                c.and_then(|c| c.effects.iter().find(|e| e.id == *id)).is_some_and(|e| e.enabled)
            }
            EffectSection::Mask(id) => c.and_then(|c| c.mask(*id)).is_some_and(|m| m.enabled),
        }
    }

    /// Blend Mode and mask rows follow the visible Transform fx switch, never the hidden Blend section's own flag (AUDIT D13):
    /// the switch sets both flags, so a row can no longer look dead while the visible switch is on.
    pub fn is_blend_group_enabled(&self) -> bool {
        self.is_effect_enabled(&EffectSection::Motion)
    }

    /// fx toggle of an applied effect.
    /// Multi-select: every clip that has the section gets the same state (a mixed switch included), one undo step.
    pub fn set_effect_enabled(&mut self, s: &EffectSection, on: bool) {
        let Some(mut c) = self.clip.clone() else { return };
        if !(self.is_effect_enabled(s) != on || self.is_effect_enabled_mixed(s)) {
            return;
        }
        if !Self::set_enabled(s, on, &mut c) {
            return;
        }
        let others = if self.is_multi() {
            let base = self.peer_gesture_base.clone().unwrap_or_else(|| self.peers.clone());
            Some(
                base.into_iter()
                    .map(|peer| {
                        let mut o = peer.clone();
                        if let Some(t) = self.mapped_section(s, &peer) {
                            let _ = Self::set_enabled(&t, on, &mut o);
                        }
                        o
                    })
                    .collect(),
            )
        } else {
            None
        };
        let name = if on { format!("Enable {}", s.title()) } else { format!("Disable {}", s.title()) };
        self.commit(c, &name, others);
    }

    fn set_enabled(s: &EffectSection, on: bool, c: &mut Clip) -> bool {
        match s {
            EffectSection::Motion => {
                c.motion_enabled = on;
                c.opacity_enabled = on;
            }
            EffectSection::Opacity => c.opacity_enabled = on,
            EffectSection::Volume | EffectSection::Speed | EffectSection::Animation(_) => return false,
            EffectSection::Effect { id, .. } => {
                let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return false };
                c.effects[i].enabled = on;
            }
            EffectSection::Mask(id) => c.update_mask(*id, |m| m.enabled = on),
        }
        true
    }

    /// A generator-owned effect (a shape's look) belongs to its clip: it can be reset, copied and pasted onto the same
    /// generator kind, never removed, cut or duplicated.
    pub fn can_remove_effect(&self, s: &EffectSection) -> bool {
        let Some(id) = s.effect_id() else { return false };
        let Some(e) = self.clip.as_ref().and_then(|c| c.effects.iter().find(|e| e.id == id)) else { return false };
        !EffectCatalog::is_generator_owned(&e.kind)
    }

    pub fn can_copy_effect(&self, s: &EffectSection) -> bool {
        if let Some(g) = BuiltInClipboard::group_for(s.clone()) {
            return self.clip.as_ref().is_some_and(|c| c.kind == g.kind());
        }
        let Some(id) = s.effect_id() else { return false };
        self.clip.as_ref().is_some_and(|c| c.effects.iter().any(|e| e.id == id))
    }

    // MARK: Convert to Keyframes / Re-open as Effect (W7.5): timeline edits, done by the session through events.

    /// Consulted for enabling (the session knows variants and the active timeline); None falls back to the clip alone.
    pub fn can_convert_to_keyframes(&self, s: &EffectSection, can_convert: Option<&dyn Fn(Id, Id) -> bool>) -> bool {
        use sq_core_effects::user_preset_bake::ClipBakeExt;
        let (Some(c), Some(id)) = (&self.clip, s.effect_id()) else { return false };
        match can_convert {
            Some(f) => f(c.id, id),
            None => c.can_convert_to_keyframes(id),
        }
    }

    pub fn convert_to_keyframes(&mut self, s: &EffectSection) {
        let (Some(c), Some(id)) = (&self.clip, s.effect_id()) else { return };
        let (clip, effect) = (c.id, id);
        self.events.push(EffectControlsEvent::ConvertToKeyframes { clip, effect });
    }

    /// The newest baked record can be re-opened; it is offered on the Motion section.
    pub fn can_reopen_as_effect(&self) -> bool {
        use sq_core_effects::user_preset_bake::ClipBakeExt;
        let Some(c) = &self.clip else { return false };
        let Some(r) = c.baked_effects().last() else { return false };
        c.can_reopen_as_effect(r.id)
    }

    pub fn reopen_title(&self) -> String {
        use sq_core_effects::user_preset_bake::ClipBakeExt;
        match self.clip.as_ref().and_then(|c| c.baked_effects().last().cloned()) {
            Some(r) => format!("Re-open as Effect ({})", EffectCatalog::title_for(&r.recipe_id)),
            None => "Re-open as Effect".to_string(),
        }
    }

    pub fn reopen_as_effect(&mut self) {
        if let Some(c) = &self.clip {
            let id = c.id;
            self.events.push(EffectControlsEvent::ReopenAsEffect(id));
        }
    }

    /// Removes the applied effect with all its values and keys: one undo step.
    pub fn remove_effect(&mut self, s: &EffectSection) -> bool {
        let Some(id) = s.effect_id() else { return false };
        let Some(mut c) = self.clip.clone() else { return false };
        if !self.can_remove_effect(s) {
            return false;
        }
        c.remove_effect(id);
        let props = s.properties();
        let ids: BTreeSet<PropertyID> = props.iter().map(|p| p.id()).collect();
        let kept: BTreeSet<SummaryMember> =
            self.selection.iter().filter(|m| !ids.contains(&m.property)).cloned().collect();
        self.set_selection(kept);
        if self.selected_section.as_ref() == Some(s) {
            self.selected_section = None;
        }
        let mut expanded = self.expanded.clone();
        for p in &props {
            expanded.remove(p);
        }
        self.set_expanded(expanded);
        self.commit(c, &format!("Remove {}", s.title()), None);
        true
    }

    /// Delete key: selected keys first, else the selected effect section or mask.
    pub fn delete_selection_or_effect(&mut self) {
        if !self.selection.is_empty() {
            self.delete_selection();
        } else if let Some(EffectSection::Mask(id)) = self.selected_section.clone() {
            self.remove_mask(id);
        } else if let Some(s) = self.selected_section.clone() {
            self.remove_effect(&s);
        }
    }

    /// Sections whose header selection survives a clip update: effects and masks.
    pub(crate) fn keeps_selection(s: &EffectSection) -> bool {
        if matches!(s, EffectSection::Mask(_)) {
            return true;
        }
        if BuiltInClipboard::group_for(s.clone()).is_some() {
            return true;
        }
        s.effect_kind().is_some()
    }

    /// Whether Delete / Backspace removes section `s` (a removable effect, or a mask of the clip).
    pub fn can_delete_section(&self, s: &EffectSection) -> bool {
        if let EffectSection::Mask(id) = s {
            return self.clip.as_ref().and_then(|c| c.mask(*id)).is_some();
        }
        self.can_remove_effect(s)
    }

    /// Whether the section header shows as selected (effects and masks; Motion and the fixed sections never do).
    pub fn is_section_selected(&self, s: &EffectSection) -> bool {
        if self.selected_section.as_ref() != Some(s) {
            return false;
        }
        Self::keeps_selection(s)
    }

    // MARK: Easing library

    pub fn save_curve_from_selection(&mut self, name: &str) {
        let Some(c) = self.clip.clone() else { return };
        for p in Self::all_properties(&c) {
            let Some(id) = self.selected_key_ids(&p).into_iter().next() else { continue };
            match self.track(&p, Some(&c)) {
                Some(PropertyTrack::Scalar(t)) => {
                    if let Some(k) = t.key(id) {
                        self.easing_library.save_curve(&mut *self.ids, k, name.to_string());
                    }
                }
                Some(PropertyTrack::Vector(t)) => {
                    if let Some(k) = t.key(id) {
                        self.easing_library.save_curve(&mut *self.ids, k, name.to_string());
                    }
                }
                Some(PropertyTrack::Color(t)) => {
                    if let Some(k) = t.key(id) {
                        self.easing_library.save_curve(&mut *self.ids, k, name.to_string());
                    }
                }
                Some(PropertyTrack::Path(t)) => {
                    if let Some(k) = t.key(id) {
                        self.easing_library.save_curve(&mut *self.ids, k, name.to_string());
                    }
                }
                None => {}
            }
            self.events.push(EffectControlsEvent::LibraryChange(self.easing_library.clone()));
            return;
        }
    }

    // MARK: Graph

    /// Scalar track shown in the graph: the property itself, or one component of a vector property.
    pub fn graph_track(&self, p: &EffectProperty, component: EffectComponent) -> KeyframeTrack<f64> {
        match self.track_of(p) {
            Some(PropertyTrack::Scalar(t)) => Self::mirrored(&t, p.display_sign(EffectComponent::All)),
            Some(PropertyTrack::Vector(t)) => {
                let comp = if component == EffectComponent::Y {
                    GraphProjectionComponent::Y
                } else {
                    GraphProjectionComponent::X
                };
                Self::mirrored(&GraphProjection::project(&t, comp), p.display_sign(component))
            }
            _ => KeyframeTrack::new(), // colors and mask paths have no value graph
        }
    }

    /// The graph draws the displayed direction (up = larger shown number): a flipped row shows its mirrored values.
    /// Ease handles are fractions of the segment, so negating the values mirrors the curve exactly.
    pub(crate) fn mirrored(t: &KeyframeTrack<f64>, sign: f64) -> KeyframeTrack<f64> {
        if sign >= 0.0 {
            return t.clone();
        }
        let mut m = t.clone();
        for k in &t.keys {
            m.update(k.id, |x| x.value = -x.value);
        }
        m
    }

    /// Takes the complete track edited in the graph (one gesture = one undo step) and merges it back.
    pub fn apply_graph_edit(&mut self, p: &EffectProperty, component: EffectComponent, edited: &KeyframeTrack<f64>) {
        let Some(mut c) = self.clip.clone() else { return };
        let edited = Self::mirrored(edited, p.display_sign(component)); // back to stored direction
        let uniform = p.kind() == EffectPropertyKind::Uniform && self.uniform_scale;
        let comp =
            if component == EffectComponent::Y { GraphProjectionComponent::Y } else { GraphProjectionComponent::X };
        let local = self.local_playhead();
        let ids = &mut *self.ids;
        Self::with_scalar(ids, &mut c, p, local, |prop, _| prop.track = edited.clone());
        Self::with_vector(ids, &mut c, p, local, |prop, _| {
            prop.track = GraphProjection::merge(&prop.track, &edited, comp, uniform);
        });
        self.commit(c, &format!("Edit {} Keyframes", p.title()), None);
    }
}
