// Swift: EffectControlsModel.swift (Gestures, Color panel gesture, Stopwatch and key buttons, Editing values)
//! Gestures, commits and the edits of values and keys at the playhead.

use std::collections::BTreeSet;

use sq_core_graphics::graphics_editing::Vec2PropertyExt;
use sq_core_graphics::graphics_layer_projection::GraphicsItemProjectionExt;
use sq_core_model::keyframes_editing::KeyframeTrackEditing;
use sq_core_model::keyframes_premiere::KeyframeTrackPremiere;
use sq_core_model::{AnimatedProperty, Clip, ClipTransform, EffectColor};
use sq_core_time::{Id, IdSource, KeyframeValue, Time, Vec2};
use sq_uikit::localization::SQL10n;

use super::core::{EffectControlsEvent, EffectControlsModel, new_key};
use super::property::{EffectComponent, EffectProperty, EffectPropertyKind, StopwatchOutcome};

/// Where and on which keys one value edit lands.
pub(crate) struct EditAt<'a> {
    local: Time,
    in_range: bool,
    selected: &'a BTreeSet<Id>,
}

impl EffectControlsModel {
    // MARK: Gestures

    pub fn begin_gesture(&mut self) {
        self.end_color_gesture();
        self.close_emitted_gesture();
        self.gesture_base = self.clip.clone();
        self.peer_gesture_base = if self.is_multi() { Some(self.peers.clone()) } else { None };
        self.gesture_name = None;
    }

    /// A gesture that reached the session is ended there before its state is dropped (the shown clip changes, the next
    /// gesture begins without a mouse-up of the last): every gesture that emitted ends exactly once, never zero times.
    pub(crate) fn close_emitted_gesture(&mut self) {
        if !self.gesture_emitted {
            return;
        }
        self.gesture_emitted = false;
        self.events.push(EffectControlsEvent::GestureEnded);
    }

    pub fn end_gesture(&mut self) {
        let emitted = self.gesture_emitted;
        self.gesture_base = None;
        self.peer_gesture_base = None;
        self.gesture_emitted = false;
        if emitted {
            self.events.push(EffectControlsEvent::GestureEnded);
        }
    }

    pub(crate) fn in_gesture(&self) -> bool {
        self.gesture_base.is_some()
    }

    /// Escape during a gesture: puts the clip back as it was when the gesture began, coalesced into the gesture's
    /// undo step under the gesture's own name. History drops a step that ends where it began, so nothing is left to undo.
    pub fn cancel_gesture(&mut self) {
        if let Some(base) = self.gesture_base.clone() {
            let peers_differ = self.peer_gesture_base.as_ref().is_some_and(|p| *p != self.peers);
            if Some(&base) != self.clip.as_ref() || peers_differ {
                let name = self.gesture_name.clone().unwrap_or_else(|| "Edit Effects".to_string());
                let peers = self.peer_gesture_base.clone();
                self.commit(base, &name, peers);
            }
        }
        if self.defer_emit {
            self.defer_emit = false;
            self.deferred_edit_name = None;
            self.revert_pending_frame_steps();
        }
        self.end_gesture();
    }

    /// Stores `new`, and emits it unless nothing changed.
    /// `new_peers` (multi-select): the peers as the same edit leaves them; they go to the session with `new` in one step.
    pub(crate) fn commit(&mut self, new: Clip, english_name: &str, new_peers: Option<Vec<Clip>>) {
        let name = SQL10n::undo_name(english_name);
        let peers_changed = new_peers.as_ref().is_some_and(|p| *p != self.peers);
        if Some(&new) == self.clip.as_ref() && !peers_changed {
            return;
        }
        if !self.committing_color {
            self.end_color_gesture();
        }
        let old = self.clip.clone();
        let old_peers = if new_peers.is_some() { self.peers.clone() } else { Vec::new() };
        self.store_clip_pub(Some(new.clone()));
        if let Some(np) = &new_peers
            && peers_changed
        {
            self.peers = np.clone();
            self.version += 1;
        }
        self.prune_selection();
        if self.defer_emit {
            self.deferred_edit_name = Some(name); // key drag: the lanes show it, the session hears once
            return;
        }
        let coalescing = self.in_gesture() && self.gesture_emitted;
        if self.in_gesture() {
            self.gesture_emitted = true;
            self.gesture_name = Some(name.clone());
        }
        if new_peers.is_some() && self.is_multi() {
            let mut clips = vec![new];
            clips.extend(self.peers.iter().cloned());
            let bases = old.into_iter().chain(old_peers).collect();
            self.events.push(EffectControlsEvent::EditMany { clips, name, coalescing, bases });
            return;
        }
        self.emit(new, old, &name, coalescing);
    }

    pub(crate) fn store_clip_pub(&mut self, c: Option<Clip>) {
        self.store_clip(c);
    }

    /// Sends a stored clip to the session (the clip, and the audio partner's share of it).
    pub(crate) fn emit(&mut self, new: Clip, old: Option<Clip>, name: &str, coalescing: bool) {
        if let Some(h) = self.item_host.clone() {
            let merged = h.host.applying_item_projection(&new, h.layer);
            if merged == h.host {
                // a locked item takes no edit: show it as it was
                if let Some(back) = h.host.graphics_item_projection(h.layer) {
                    self.store_clip(Some(back));
                }
                return;
            }
            self.item_host = Some(super::core::ItemHost { host: merged.clone(), layer: h.layer });
            let base = Some(h.host);
            self.events.push(EffectControlsEvent::Edit { clip: merged, name: name.to_string(), coalescing, base });
            return;
        }
        let (partner, own, old) = match (self.audio_partner.clone().zip(self.own_volume.clone()), old) {
            (Some((partner, own)), Some(old)) => (partner, own, old),
            (_, base) => {
                self.events.push(EffectControlsEvent::Edit { clip: new, name: name.to_string(), coalescing, base });
                return;
            }
        };
        // Video clip with an audio partner: Volume and audio effects belong to the partner, everything else to the video clip.
        let new_fx: Vec<_> = new.effects.iter().filter(|e| e.is_audio()).cloned().collect();
        let old_fx: Vec<_> = old.effects.iter().filter(|e| e.is_audio()).cloned().collect();
        if new.animation.volume != old.animation.volume || new_fx != old_fx {
            let back = Time::ZERO - self.partner_offset;
            let mut p = partner.clone();
            p.animation.volume =
                if back == Time::ZERO { new.animation.volume.clone() } else { new.animation.volume.shifted(back) };
            p.effects.retain(|e| !e.is_audio());
            p.effects.extend(new_fx.iter().map(|e| if back == Time::ZERO { e.clone() } else { e.shifted(back) }));
            self.audio_partner = Some(p.clone());
            let base = Some(partner);
            self.events.push(EffectControlsEvent::AudioEdit { clip: p, name: name.to_string(), coalescing, base });
        }
        let mut video = new;
        video.animation.volume = own.clone();
        video.effects.retain(|e| !e.is_audio());
        let mut before = old;
        before.animation.volume = own;
        before.effects.retain(|e| !e.is_audio());
        if video != before {
            let base = Some(before);
            self.events.push(EffectControlsEvent::Edit { clip: video, name: name.to_string(), coalescing, base });
        }
    }

    /// Clip an edit starts from (the gesture's base inside a gesture). Any edit other than the color panel's own
    /// closes an open color gesture first, so it never computes from the color gesture's stale base.
    pub(crate) fn working_clip(&mut self) -> Option<Clip> {
        self.end_color_gesture();
        self.gesture_base.clone().or_else(|| self.clip.clone())
    }

    // MARK: Color panel gesture

    /// Continuous color from the color panel: consecutive calls for the same property are one undo step. The gesture
    /// ends on `end_color_gesture()` (well deactivated, panel closed) or as soon as anything else edits, begins a gesture,
    /// moves the playhead, changes the selection or the clip.
    pub fn set_color_continuously(&mut self, p: &EffectProperty, color: EffectColor) -> bool {
        if self.color_gesture.as_ref() != Some(p) {
            self.end_color_gesture();
            self.close_emitted_gesture();
            self.gesture_base = self.clip.clone();
            self.peer_gesture_base = if self.is_multi() { Some(self.peers.clone()) } else { None };
            self.color_gesture = Some(p.clone());
        }
        self.committing_color = true;
        let base = self.gesture_base.clone().or_else(|| self.clip.clone());
        let ok = self.apply_color(p, color, base);
        self.committing_color = false;
        ok
    }

    /// Ends an open color gesture (no-op otherwise; never ends another gesture).
    pub fn end_color_gesture(&mut self) {
        if self.color_gesture.is_none() {
            return;
        }
        self.color_gesture = None;
        self.end_gesture();
    }

    // MARK: Stopwatch and key buttons

    pub fn toggle_stopwatch(&mut self, p: &EffectProperty, confirm_removal: bool) -> StopwatchOutcome {
        if let EffectProperty::MaskPath(id) = p {
            return self.toggle_mask_path_stopwatch(*id, confirm_removal);
        }
        let Some(mut c) = self.clip.clone() else { return StopwatchOutcome::Unavailable };
        let local = self.key_local();
        if self.is_animated(p) {
            if !confirm_removal {
                return StopwatchOutcome::NeedsConfirmation;
            }
            self.clear_keys(&mut c, p, local);
            let pid = p.id();
            let kept: BTreeSet<_> = self.selection.iter().filter(|m| m.property != pid).cloned().collect();
            self.set_selection(kept);
            // Multi-select: every selected clip loses its keys of the property, frozen at its own playhead.
            let peers = self.edited_peers(p, |this, c, q, l, _| {
                let at = Self::clamped(l, c);
                this.clear_keys(c, q, at);
            });
            self.commit(c, "Remove Keyframes", peers);
            return StopwatchOutcome::Removed;
        }
        if !(self.playhead_in_clip() || self.is_multi()) {
            return StopwatchOutcome::Unavailable;
        }
        self.insert_value_key(&mut c, p, local, p == &EffectProperty::Position);
        // Multi-select: every selected clip gets a key at its own playhead (its nearest end when the playhead is outside it).
        let peers = self.edited_peers(p, |this, c, q, l, _| {
            let at = Self::clamped(l, c);
            this.insert_key_here(c, q, at);
        });
        self.commit(c, "Add Keyframe", peers);
        StopwatchOutcome::Added
    }

    /// A key at `local` holding the value shown there, on whichever kind `p` is (vector, scalar, color).
    fn insert_value_key(&mut self, c: &mut Clip, p: &EffectProperty, local: Time, smooth_spatial: bool) {
        let ids = &mut *self.ids;
        Self::with_vector(ids, c, p, local, |prop, ids| {
            let k = new_key(ids, local, prop.value_at_local(local));
            prop.track.insert_key(k, smooth_spatial);
        });
        Self::with_scalar(ids, c, p, local, |prop, ids| {
            let k = new_key(ids, local, prop.value_at_local(local));
            prop.track.insert(k);
        });
        Self::with_color(ids, c, p, |prop, ids| {
            let k = new_key(ids, local, prop.value_at_local(local));
            prop.track.insert(k);
        });
    }

    /// Add / remove button: key at the playhead on, or off again. On a static property it is the stopwatch.
    /// Multi-select: the same on every selected clip, at its own playhead, in one undo step.
    pub fn toggle_key_at_playhead(&mut self, p: &EffectProperty) -> StopwatchOutcome {
        if let EffectProperty::MaskPath(id) = p {
            return self.toggle_mask_path_key(*id);
        }
        let Some(mut c) = self.clip.clone() else { return StopwatchOutcome::Unavailable };
        if !self.is_animated(p) {
            return self.toggle_stopwatch(p, false);
        }
        let local = self.key_local();
        if self.key_time(p, local) {
            self.remove_key_here(&mut c, p, local);
            let peers = self.edited_peers(p, |this, c, q, l, _| {
                let at = Self::clamped(l, c);
                this.remove_key_here(c, q, at);
            });
            self.commit(c, "Remove Keyframe", peers);
            return StopwatchOutcome::Removed;
        }
        if !(self.playhead_in_clip() || self.is_multi()) {
            return StopwatchOutcome::Unavailable;
        }
        let smooth = p == &EffectProperty::Position;
        {
            let ids = &mut *self.ids;
            Self::with_vector(ids, &mut c, p, local, |prop, ids| {
                let k = new_key(ids, local, prop.value_at_local(local));
                prop.track.insert_key(k, smooth);
            });
        }
        let shown: Option<f64> = if local == self.local_playhead() { Some(self.scalar_value(p)) } else { None }; // hues the short way, Color wheels on the disc
        let before = c.clone();
        {
            let ids = &mut *self.ids;
            Self::with_scalar(ids, &mut c, p, local, |prop, ids| {
                let k = new_key(ids, local, shown.unwrap_or_else(|| prop.value_at_local(local)));
                prop.track.insert(k);
            });
            Self::follow_shown(ids, &mut c, p, &before, local);
            Self::with_color(ids, &mut c, p, |prop, ids| {
                let k = new_key(ids, local, prop.value_at_local(local));
                prop.track.insert(k);
            });
        }
        let peers = self.edited_peers(p, |this, c, q, l, _| {
            let at = Self::clamped(l, c);
            this.insert_key_here(c, q, at);
        });
        self.commit(c, "Add Keyframe", peers);
        StopwatchOutcome::Added
    }

    /// Add Keyframe command: puts a key at the playhead, never removes one. `Unavailable` when a key is already
    /// there (or the property is a mask path), so the caller can say so instead of toggling it off.
    pub fn add_key_at_playhead(&mut self, p: &EffectProperty) -> StopwatchOutcome {
        if matches!(p, EffectProperty::MaskPath(_)) {
            return StopwatchOutcome::Unavailable;
        }
        if self.is_animated(p) && self.key_time(p, self.key_local()) {
            return StopwatchOutcome::Unavailable;
        }
        self.toggle_key_at_playhead(p)
    }

    /// Where the key buttons key the shown clip: the playhead, or with several clips selected the playhead clamped into it.
    fn key_local(&self) -> Time {
        match (&self.clip, self.is_multi()) {
            (Some(c), true) => Self::clamped(self.local_playhead(), c),
            _ => self.local_playhead(),
        }
    }

    pub(crate) fn clamped(l: Time, c: &Clip) -> Time {
        l.max(Time::ZERO).min(c.duration())
    }

    /// Drops every key of `p`, the value frozen as shown at `local`.
    fn clear_keys(&mut self, c: &mut Clip, p: &EffectProperty, local: Time) {
        let ids = &mut *self.ids;
        Self::with_vector(ids, c, p, local, |prop, _| {
            prop.value = prop.value_at_local(local);
            prop.track = Default::default();
        });
        let before = c.clone();
        Self::with_scalar(ids, c, p, local, |prop, _| {
            prop.value = prop.value_at_local(local);
            prop.track = Default::default();
        });
        Self::with_color(ids, c, p, |prop, _| {
            prop.value = prop.value_at_local(local);
            prop.track = Default::default();
        });
        Self::follow_shown(ids, c, p, &before, local);
    }

    /// A key of `p` at `local` holding the value shown there.
    pub(crate) fn insert_key_here(&mut self, c: &mut Clip, p: &EffectProperty, local: Time) {
        let ids = &mut *self.ids;
        let smooth = p == &EffectProperty::Position;
        Self::with_vector(ids, c, p, local, |prop, ids| {
            let k = new_key(ids, local, prop.value_at_local(local));
            prop.track.insert_key(k, smooth);
        });
        let before = c.clone();
        Self::with_scalar(ids, c, p, local, |prop, ids| {
            let k = new_key(ids, local, prop.value_at_local(local));
            prop.track.insert(k);
        });
        Self::follow_shown(ids, c, p, &before, local);
        Self::with_color(ids, c, p, |prop, ids| {
            let k = new_key(ids, local, prop.value_at_local(local));
            prop.track.insert(k);
        });
    }

    /// Removes the key of `p` at `local` (nothing when there is none).
    fn remove_key_here(&mut self, c: &mut Clip, p: &EffectProperty, local: Time) {
        let ids = &mut *self.ids;
        Self::with_vector(ids, c, p, local, |prop, _| Self::remove_key(prop, local));
        let before = c.clone();
        Self::with_scalar(ids, c, p, local, |prop, _| Self::remove_key(prop, local));
        Self::with_color(ids, c, p, |prop, _| Self::remove_key(prop, local));
        Self::follow_shown(ids, c, p, &before, local);
    }

    /// Removes the key; when it was the last one the static value takes over so nothing jumps.
    fn remove_key<V: KeyframeValue>(prop: &mut AnimatedProperty<V>, local: Time) {
        let shown = prop.value_at_local(local);
        if let Some(id) = prop.track.keys.iter().find(|k| k.time == local).map(|k| k.id) {
            prop.track.remove(id);
        }
        if prop.track.is_empty() {
            prop.value = shown;
        }
    }

    // MARK: Editing values

    /// The property should show `v` (native units) at the playhead.
    /// Static: sets the value. Animated with selected keys of this property: relative edit of all of them
    /// (PHASE4 rule 7). Animated otherwise: adds or replaces the key at the playhead.
    pub fn set_value(&mut self, p: &EffectProperty, component: EffectComponent, v: f64) -> bool {
        let Some(mut c) = self.working_clip() else { return false };
        let local = self.local_playhead();
        let in_range = self.playhead_in_clip();
        // Checkbox / popup values are absolute: a relative edit of several selected keys would leave the 0...1 / index range.
        let selected = if p.param_kind().is_some_and(|k| k.is_stepped()) {
            BTreeSet::new()
        } else {
            self.selected_keys_at_playhead(p)
        };
        if !self.apply_value(&mut c, p, component, v, EditAt { local, in_range, selected: &selected }) {
            return false;
        }
        let others = self.edited_peers(p, |this, c, q, l, r| {
            let _ = this.apply_value(c, q, component, v, EditAt { local: l, in_range: r, selected: &BTreeSet::new() });
        });
        self.commit(c, &format!("Change {}", p.title()), others);
        true
    }

    /// Several parameters in ONE commit (one undo step), e.g. loading a preset.
    pub fn set_values(&mut self, pairs: &[(EffectProperty, f64)], name: &str) {
        let Some(mut c) = self.working_clip() else { return };
        let local = self.local_playhead();
        let in_range = self.playhead_in_clip();
        let mut any = false;
        for (p, v) in pairs {
            if self.apply_value(
                &mut c,
                p,
                EffectComponent::All,
                *v,
                EditAt { local, in_range, selected: &BTreeSet::new() },
            ) {
                any = true;
            }
        }
        if any {
            self.commit(c, name, None);
        }
    }

    fn apply_value(
        &mut self,
        c: &mut Clip,
        p: &EffectProperty,
        component: EffectComponent,
        value: f64,
        at: EditAt<'_>,
    ) -> bool {
        let EditAt { local, in_range, selected } = at;
        if !value.is_finite() {
            return false;
        }
        // every entry point (field, graph, preset, relative key edit) stays inside the range
        let v = p.clamped_native(value, self.display_picture());
        let uniform_scale = self.uniform_scale;
        let mut ok = false;
        let before = c.clone();
        let ids = &mut *self.ids;
        Self::with_scalar(ids, c, p, local, |prop, ids| {
            ok = Self::apply(prop, v, local, in_range, selected, false, ids);
        });
        Self::follow_shown(ids, c, p, &before, local);
        let kind = p.kind();
        let smooth = p == &EffectProperty::Position;
        Self::with_vector(ids, c, p, local, |prop, ids| {
            let cur = prop.value_at_local(local);
            let new = match (kind, component) {
                (EffectPropertyKind::Uniform, EffectComponent::X) if !uniform_scale => Vec2::new(v, cur.y),
                (EffectPropertyKind::Uniform, EffectComponent::Y) if !uniform_scale => Vec2::new(cur.x, v),
                (EffectPropertyKind::Uniform, _) | (_, EffectComponent::All) => Vec2::new(v, v),
                (_, EffectComponent::X) => Vec2::new(v, cur.y),
                (_, EffectComponent::Y) => Vec2::new(cur.x, v),
            };
            ok = Self::apply(prop, new, local, in_range, selected, smooth, ids);
        });
        ok
    }

    /// A color parameter should show `color` at the playhead (same rules as `set_value`: static value, selected keys,
    /// or the key at the playhead).
    pub fn set_color(&mut self, p: &EffectProperty, color: EffectColor) -> bool {
        let base = self.working_clip();
        self.apply_color(p, color, base)
    }

    /// Colors are absolute: selected keys all take `color` (a relative shift would push channels out of 0...1).
    pub(crate) fn apply_color(&mut self, p: &EffectProperty, color: EffectColor, base: Option<Clip>) -> bool {
        let Some(mut c) = base else { return false };
        if p.kind() != EffectPropertyKind::Color {
            return false;
        }
        let local = self.local_playhead();
        let in_range = self.playhead_in_clip();
        let selected = self.selected_keys_at_playhead(p);
        let mut ok = false;
        {
            let ids = &mut *self.ids;
            Self::with_color(ids, &mut c, p, |prop, ids| {
                let key_ids: Vec<Id> =
                    prop.track.keys.iter().map(|k| k.id).filter(|id| selected.contains(id)).collect();
                if prop.is_animated() && !key_ids.is_empty() {
                    for id in key_ids {
                        prop.track.set(id, color);
                    }
                    ok = true;
                } else {
                    ok = Self::apply(prop, color, local, in_range, &BTreeSet::new(), false, ids);
                }
            });
        }
        if !ok {
            return false;
        }
        let others = self.edited_peers(p, |this, c, q, l, r| {
            let ids = &mut *this.ids;
            Self::with_color(ids, c, q, |prop, ids| {
                let _ = Self::apply(prop, color, l, r, &BTreeSet::new(), false, ids);
            });
        });
        self.commit(c, &format!("Change {}", p.title()), others);
        true
    }

    /// Direct manipulation in the Program monitor: writes the parts of `t` that differ from `start` (the transform when
    /// the gesture began) into Position, Scale, Rotation and Anchor at the playhead, like typing the values. Static
    /// properties are set, animated ones get or update the key at the playhead. Inside a gesture every call starts
    /// from the clip as it was when the gesture began, so repeated calls never accumulate; one undo step per gesture.
    pub fn set_transform(&mut self, t: &ClipTransform, start: &ClipTransform) -> bool {
        let Some(mut c) = self.working_clip() else { return false };
        let local = self.local_playhead();
        let in_range = self.playhead_in_clip();
        let mut ok = true;
        let none = BTreeSet::new();
        let ids = &mut *self.ids;
        if t.position != start.position {
            if t.anchor != start.anchor && c.animation.position.is_animated() {
                // Anchor drag: Position only compensates so the picture stays put. With animated Position every key
                // gets the same compensation (a key at the playhead alone would bend the motion path).
                let d = t.position - start.position;
                Self::with_vector(ids, &mut c, &EffectProperty::Position, local, |p, _| {
                    let key_ids: Vec<Id> = p.track.keys.iter().map(|k| k.id).collect();
                    for id in key_ids {
                        p.track.update(id, |k| k.value = k.value + d);
                    }
                });
            } else if Self::moves_whole_motion(&c) {
                Self::with_vector(ids, &mut c, &EffectProperty::Position, local, |p, _| {
                    *p = p.moved_base(t.position, local);
                });
            } else {
                Self::with_vector(ids, &mut c, &EffectProperty::Position, local, |p, ids| {
                    ok = Self::apply(p, t.position, local, in_range, &none, true, ids) && ok;
                });
            }
        }
        if t.scale != start.scale {
            Self::with_vector(ids, &mut c, &EffectProperty::Scale, local, |p, ids| {
                ok = Self::apply(p, t.scale, local, in_range, &none, false, ids) && ok;
            });
        }
        if t.rotation != start.rotation {
            Self::with_scalar(ids, &mut c, &EffectProperty::Rotation, local, |p, ids| {
                ok = Self::apply(p, t.rotation, local, in_range, &none, false, ids) && ok;
            });
        }
        if t.anchor != start.anchor {
            Self::with_vector(ids, &mut c, &EffectProperty::Anchor, local, |p, ids| {
                ok = Self::apply(p, t.anchor, local, in_range, &none, false, ids) && ok;
            });
        }
        if !ok {
            return false;
        }
        self.commit(c, "Change Transform", None);
        true
    }

    /// Text and graphic clips: a typed or dragged Position is the base of the whole animation, so every key moves with
    /// it (the fly-in keeps its shape) instead of getting a key at the playhead. Pictures keep key-at-playhead.
    pub(crate) fn moves_whole_motion(c: &Clip) -> bool {
        c.animation.position.is_animated()
            && (c.generator.as_ref().is_some_and(|g| g.kind == sq_text::text_generator::TextGenerator::KIND)
                || c.is_graphics())
    }

    /// A vector property (position, anchor, point parameter) should show `v` at the playhead: both components in one pass
    /// and one commit (two `set_value` calls in a gesture would each start from the gesture base and lose the first).
    pub fn set_vector(&mut self, p: &EffectProperty, v: Vec2) -> bool {
        if p.kind() != EffectPropertyKind::Vector {
            return false;
        }
        let Some(mut c) = self.working_clip() else { return false };
        let local = self.local_playhead();
        let in_range = self.playhead_in_clip();
        let selected = self.selected_keys_at_playhead(p);
        let mut ok = false;
        let ids = &mut *self.ids;
        if p == &EffectProperty::Position && selected.is_empty() && Self::moves_whole_motion(&c) {
            Self::with_vector(ids, &mut c, p, local, |prop, _| {
                *prop = prop.moved_base(v, local);
            });
            ok = true;
        } else {
            let smooth = p == &EffectProperty::Position;
            Self::with_vector(ids, &mut c, p, local, |prop, ids| {
                ok = Self::apply(prop, v, local, in_range, &selected, smooth, ids);
            });
        }
        if !ok {
            return false;
        }
        let others = self.edited_peers(p, |this, c, q, l, r| {
            let ids = &mut *this.ids;
            let smooth = q == &EffectProperty::Position;
            Self::with_vector(ids, c, q, l, |prop, ids| {
                let _ = Self::apply(prop, v, l, r, &BTreeSet::new(), smooth, ids);
            });
        });
        self.commit(c, &format!("Change {}", p.title()), others);
        true
    }

    /// Motion-path edit in the Program monitor: a Position key's value and/or its tangents. Gesture edits merge.
    pub fn edit_position_key(&mut self, id: Id, position: Option<Vec2>, tangents: Option<(Vec2, Vec2)>) {
        let Some(mut c) = self.working_clip() else { return };
        let local = self.local_playhead();
        Self::with_vector(&mut *self.ids, &mut c, &EffectProperty::Position, local, |p, _| {
            p.track.update(id, |k| {
                if let Some(position) = position {
                    k.value = position;
                }
                if let Some((tin, tout)) = tangents {
                    k.in_tangent = tin;
                    k.out_tangent = tout;
                }
            });
        });
        self.commit(c, "Move Keyframe", None);
    }

    /// Selected keys of `p` that an edit at the playhead applies to: only when the playhead sits on one of them
    /// (then all selected keys shift together). A key selected elsewhere never captures the edit: the value at the
    /// playhead always wins and creates a key there (Premiere).
    fn selected_keys_at_playhead(&self, p: &EffectProperty) -> BTreeSet<Id> {
        let selected = self.selected_key_ids(p);
        if selected.is_empty() {
            return BTreeSet::new();
        }
        let Some(t) = self.track_of(p) else { return BTreeSet::new() };
        let l = self.local_playhead();
        if t.times().iter().any(|(id, time)| *time == l && selected.contains(id)) { selected } else { BTreeSet::new() }
    }

    pub(crate) fn apply<V: KeyframeValue + 'static>(
        prop: &mut AnimatedProperty<V>,
        new: V,
        local: Time,
        in_range: bool,
        selected: &BTreeSet<Id>,
        smooth_spatial: bool,
        ids: &mut dyn IdSource,
    ) -> bool {
        if !prop.is_animated() {
            prop.value = new;
            return true;
        }
        if prop.track.keys.iter().any(|k| selected.contains(&k.id)) {
            return prop.track.set_value(&new, local, selected);
        }
        if let Some(id) = prop.track.keys.iter().find(|k| k.time == local).map(|k| k.id) {
            prop.track.set(id, new);
            return true;
        }
        if !in_range {
            return false;
        }
        prop.track.insert_key(new_key(ids, local, new), smooth_spatial);
        true
    }

    /// Frame deletes made during a key drag are undone as the clip was: restores each snapshot.
    pub(crate) fn revert_pending_frame_steps(&mut self) {
        let steps = std::mem::take(&mut self.pending_frame_steps);
        for s in steps.iter().rev() {
            self.magic_frames.restore(&s.snapshot);
        }
    }

    pub fn selected_key_ids(&self, p: &EffectProperty) -> BTreeSet<Id> {
        let pid = p.id();
        self.selection.iter().filter(|m| m.property == pid).map(|m| m.key_id).collect()
    }
}
