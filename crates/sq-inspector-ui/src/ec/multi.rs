// Swift: EffectControlsModel+Multi.swift
//! Multi-select editing (Premiere): with several clips selected Effect Controls shows the first (by start) and its
//! `peers`. A field shows the value when every clip has it at the playhead (each clip at its own local time), an empty
//! field when they differ; an edit sets that one value on all of them in one undo step (`EditMany`). An effect section
//! shows when the shown clip and at least one other selected clip have an effect of that kind at that occurrence; its
//! edits go to the clips that have it, the others are left alone. Transform's Crop rows map to each clip's first Crop and
//! add one where it is missing. The stopwatch and the add / remove key button key every clip at its own playhead
//! (clamped into the clip) in one step; Speed, masks and the linked-audio group stay single-clip, and key drags, graphs
//! and key copy / paste work on the shown clip.

use sq_core_graphics::custom_animation::{AnimationParam, AnimationSide};
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::{Clip, ClipEffect, EffectCatalog, EffectColor, TrackKind};
use sq_core_time::{Id, Time, Vec2};
use sq_editor_session::{EditorSession, EffectSection};

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty, EffectPropertyKind};
use crate::ec::prelude::*;

/// One property of one clip at one time, for the mixed-value comparison.
#[derive(Clone, Debug, PartialEq)]
pub enum Reading {
    Scalar(f64),
    Vector(Vec2),
    Color(EffectColor),
    None,
}

impl EffectControlsModel {
    pub fn is_multi(&self) -> bool {
        !self.peers.is_empty()
    }

    /// Follows a selection of several clips. False when the selection is one clip (or one linked pair): the single path runs.
    pub(crate) fn sync_multi(&mut self, session: &EditorSession) -> bool {
        let clips = session.selected_edit_clips();
        if clips.len() <= 1 {
            return false;
        }
        let sound = clips.iter().filter(|c| c.kind == TrackKind::Audio).count();
        // Picture and sound-only clips share nothing Effect Controls could edit together.
        if sound == 0 || sound == clips.len() {
            self.set_clip(Some(clips[0].clone()), None, clips[1..].to_vec(), None);
        } else {
            self.set_clip(None, None, Vec::new(), None);
        }
        true
    }

    /// The Custom sides every selected clip has: only these show rows in a multi-selection (a side that is Off or plays
    /// a preset in some clip has no keys to edit there). A row's value reads mixed where the clips differ (`is_mixed`).
    pub(crate) fn shared_custom_sides(&self) -> Vec<AnimationSide> {
        let Some(c) = &self.clip else { return Vec::new() };
        Self::custom_sides(Some(c))
            .into_iter()
            .filter(|side| self.peers.iter().all(|p| Self::custom_sides(Some(p)).contains(side)))
            .collect()
    }

    /// Some peer has an effect matching `id` of the shown clip: there is something to edit together.
    pub(crate) fn shared_by_any_peer(&self, id: Id) -> bool {
        let Some(c) = &self.clip else { return false };
        self.peers.iter().any(|p| p.matching_effect_id(id, c).is_some())
    }

    /// `p` of the shown clip as the same property of `peer`; nil when the peer has no such property (masks, missing effect).
    pub(crate) fn mapped(&self, p: &EffectProperty, peer: &Clip) -> Option<EffectProperty> {
        match p {
            EffectProperty::Fx { id, kind, key } => {
                let c = self.clip.as_ref()?;
                // Transform's Crop rows: the peer's first Crop (or the one they add to it).
                if kind == ClipEffect::CROP_KIND && Some(*id) == Self::transform_crop_id(c) {
                    return Self::transform_crop_id(peer).map(|m| EffectProperty::Fx {
                        id: m,
                        kind: kind.clone(),
                        key: key.clone(),
                    });
                }
                let m = peer.matching_effect_id(*id, c)?;
                Some(EffectProperty::Fx { id: m, kind: kind.clone(), key: key.clone() })
            }
            EffectProperty::Mask(..) => None,
            EffectProperty::Anim(side, _) => {
                if Self::custom_sides(Some(peer)).contains(side) { Some(p.clone()) } else { None } // a peer's own Custom side
            }
            _ => Some(p.clone()),
        }
    }

    /// Section `s` of the shown clip as the same section of `peer`; nil when the peer has none (an effect it lacks, a mask).
    pub(crate) fn mapped_section(&self, s: &EffectSection, peer: &Clip) -> Option<EffectSection> {
        match s {
            EffectSection::Motion | EffectSection::Opacity | EffectSection::Volume => Some(s.clone()),
            EffectSection::Speed | EffectSection::Mask(_) => None,
            EffectSection::Animation(side) => {
                if Self::custom_sides(Some(peer)).contains(side) {
                    Some(s.clone())
                } else {
                    None
                }
            }
            EffectSection::Effect { id, kind } => {
                let c = self.clip.as_ref()?;
                let m = peer.matching_effect_id(*id, c)?;
                Some(EffectSection::Effect { id: m, kind: kind.clone() })
            }
        }
    }

    /// The fx switch of `s` is on in some selected clips that have the section and off in others.
    pub fn is_effect_enabled_mixed(&self, s: &EffectSection) -> bool {
        let Some(c) = &self.clip else { return false };
        if !self.is_multi() {
            return false;
        }
        let Some(mine) = Self::enabled(s, c) else { return false };
        self.peers
            .iter()
            .any(|peer| self.mapped_section(s, peer).and_then(|t| Self::enabled(&t, peer)).is_some_and(|e| e != mine))
    }

    /// The fx switch was clicked: flips it, or turns it on everywhere while it is mixed.
    pub fn toggle_effect_enabled(&mut self, s: &EffectSection) {
        let on = self.is_effect_enabled_mixed(s) || !self.is_effect_enabled(s);
        self.set_effect_enabled(s, on);
    }

    fn enabled(s: &EffectSection, c: &Clip) -> Option<bool> {
        match s {
            EffectSection::Motion => Some(c.motion_enabled && c.opacity_enabled),
            EffectSection::Opacity => Some(c.opacity_enabled),
            EffectSection::Volume | EffectSection::Speed | EffectSection::Animation(_) => None,
            EffectSection::Effect { id, .. } => c.effects.iter().find(|e| e.id == *id).map(|e| e.enabled),
            EffectSection::Mask(id) => c.mask(*id).map(|m| m.enabled),
        }
    }

    /// The selected clips use different blend modes: the popup shows nothing picked.
    pub fn is_blend_mode_mixed(&self) -> bool {
        let Some(c) = &self.clip else { return false };
        self.is_multi() && self.peers.iter().any(|p| p.kind == TrackKind::Video && p.blend_mode != c.blend_mode)
    }

    /// The peers (from the gesture's base inside a gesture) with `body` applied to each, given the mapped property, the
    /// peer's own local playhead and whether that lies inside it. nil when there are no peers.
    pub(crate) fn edited_peers(
        &mut self,
        p: &EffectProperty,
        mut body: impl FnMut(&mut EffectControlsModel, &mut Clip, &EffectProperty, Time, bool),
    ) -> Option<Vec<Clip>> {
        if !self.is_multi() {
            return None;
        }
        let base = self.peer_gesture_base.clone().unwrap_or_else(|| self.peers.clone());
        let mut out = Vec::with_capacity(base.len());
        for peer in base {
            let mut c = peer.clone();
            if let Some(q) = self.mapped(p, &peer) {
                let l = self.playhead - peer.start;
                body(self, &mut c, &q, l, l >= Time::ZERO && l <= peer.duration());
            }
            out.push(c);
        }
        Some(out)
    }

    /// True when the selected clips show different values of `p` (or of one component of it) at the playhead: the field is empty.
    pub fn is_mixed(&self, p: &EffectProperty, component: EffectComponent) -> bool {
        let Some(c) = &self.clip else { return false };
        if !self.is_multi() {
            return false;
        }
        let mine = Self::reading(p, c, self.local_playhead());
        for peer in &self.peers {
            let Some(q) = self.mapped(p, peer) else { continue };
            if !Self::same(&mine, &Self::reading(&q, peer, self.playhead - peer.start), component) {
                return true;
            }
        }
        false
    }

    pub(crate) fn reading(p: &EffectProperty, c: &Clip, l: Time) -> Reading {
        let a = &c.animation;
        match p {
            EffectProperty::Position => Reading::Vector(a.position.value_at_local(l)),
            EffectProperty::Scale => Reading::Vector(a.scale.value_at_local(l)),
            EffectProperty::Anchor => Reading::Vector(a.anchor.value_at_local(l)),
            EffectProperty::Rotation => Reading::Scalar(a.rotation.value_at_local(l)),
            EffectProperty::TiltX => Reading::Scalar(a.tilt_x.value_at_local(l)),
            EffectProperty::TiltY => Reading::Scalar(a.tilt_y.value_at_local(l)),
            EffectProperty::Opacity => Reading::Scalar(a.opacity.value_at_local(l)),
            EffectProperty::Volume => Reading::Scalar(a.volume.value_at_local(l)),
            EffectProperty::ShutterAngle => Reading::Scalar(a.shutter_angle.value_at_local(l)),
            EffectProperty::AntiFlicker => Reading::Scalar(a.anti_flicker.value_at_local(l)),
            EffectProperty::Mask(..) => {
                Self::mask_param(p, Some(c)).map_or(Reading::None, |m| Reading::Scalar(m.value_at_local(l)))
            }
            EffectProperty::MaskPath(_) => Reading::None,
            EffectProperty::Anim(_, param) => {
                if *param == AnimationParam::Position {
                    return Self::anim_vector(p, Some(c))
                        .map_or(Reading::None, |v| Reading::Vector(v.value_at_local(l)));
                }
                Self::anim_scalar(p, Some(c)).map_or(Reading::None, |v| Reading::Scalar(v.value_at_local(l)))
            }
            EffectProperty::Fx { id, kind, key } => match p.kind() {
                EffectPropertyKind::Color => {
                    Self::color_param(p, Some(c)).map_or(Reading::None, |v| Reading::Color(v.value_at_local(l)))
                }
                EffectPropertyKind::Vector => {
                    Self::point_param(p, Some(c)).map_or(Reading::None, |v| Reading::Vector(v.value_at_local(l)))
                }
                _ => {
                    if let Some(v) = Self::param(p, Some(c)) {
                        return Reading::Scalar(v.value_at_local(l));
                    }
                    // A Crop not added yet, or a Softness an old Crop does not store: the default, like the rows show.
                    if kind == ClipEffect::CROP_KIND
                        && (Self::is_pending_crop(p, c) || c.effects.iter().any(|e| e.id == *id))
                    {
                        return Reading::Scalar(EffectCatalog::param(kind, key).map_or(0.0, |s| s.default_value));
                    }
                    Reading::None
                }
            },
        }
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() <= 1e-9 * 1.0f64.max(a.abs()).max(b.abs())
    }

    fn same(a: &Reading, b: &Reading, component: EffectComponent) -> bool {
        match (a, b) {
            (Reading::Scalar(x), Reading::Scalar(y)) => Self::close(*x, *y),
            (Reading::Vector(u), Reading::Vector(v)) => match component {
                EffectComponent::X => Self::close(u.x, v.x),
                EffectComponent::Y => Self::close(u.y, v.y),
                EffectComponent::All => Self::close(u.x, v.x) && Self::close(u.y, v.y),
            },
            _ => a == b,
        }
    }
}
