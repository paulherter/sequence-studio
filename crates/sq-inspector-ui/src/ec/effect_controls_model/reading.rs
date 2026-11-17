// Swift: EffectControlsModel.swift (Reading, Property access by kind), EffectControlsModel+TransformCrop.swift
//! Reading values and tracks of the shown clip, and the typed access every edit goes through.

use std::collections::BTreeMap;

use sq_core_graphics::custom_animation::AnimationParam;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::keyframes_editing::{PropertyID, PropertyTrack};
use sq_core_model::keyframes_pair::KeyframesPair;
use sq_core_model::{AnimatedProperty, Clip, ClipEffect, EffectCatalog, EffectColor, TrackKind};
use sq_core_time::{Id, IdSource, Time, Vec2};
use sq_editor_session::EffectSection;
use sq_uikit::keyframe_control_state::{KeyframeControlState, ScrubKeyframeState};

use super::core::{EffectControlsEvent, EffectControlsModel};
use super::property::{EffectProperty, EffectPropertyKind};
use super::section::EffectSectionExt;

impl EffectControlsModel {
    pub fn is_animated(&self, p: &EffectProperty) -> bool {
        self.track(p, self.clip.as_ref()).is_some_and(|t| !t.key_ids().is_empty())
    }

    pub fn key_state(&self, p: &EffectProperty) -> ScrubKeyframeState {
        if !self.is_animated(p) {
            return ScrubKeyframeState::None;
        }
        if self.key_time(p, self.local_playhead()) { ScrubKeyframeState::OnKey } else { ScrubKeyframeState::Between }
    }

    /// What the property's `KeyframeControls` show (ring, prev / diamond / next and their enabled states).
    pub fn keyframe_control_state(&self, p: &EffectProperty) -> KeyframeControlState {
        KeyframeControlState::resolve(
            self.is_animated(p),
            self.key_state(p) == ScrubKeyframeState::OnKey,
            self.previous_key_time(p).is_some(),
            self.next_key_time(p).is_some(),
            self.playhead_in_clip(),
        )
    }

    pub fn scalar_value(&self, p: &EffectProperty) -> f64 {
        let Some(c) = &self.clip else { return 0.0 };
        let a = &c.animation;
        let l = self.local_playhead();
        match p {
            EffectProperty::Rotation => a.rotation.value_at_local(l),
            EffectProperty::TiltX => a.tilt_x.value_at_local(l),
            EffectProperty::TiltY => a.tilt_y.value_at_local(l),
            EffectProperty::Opacity => a.opacity.value_at_local(l),
            EffectProperty::Volume => a.volume.value_at_local(l),
            EffectProperty::ShutterAngle => a.shutter_angle.value_at_local(l),
            EffectProperty::AntiFlicker => a.anti_flicker.value_at_local(l),
            EffectProperty::Fx { id, key, .. } => {
                c.effects.iter().find(|e| e.id == *id).and_then(|e| e.shown_value(key, l)).unwrap_or(0.0)
            }
            EffectProperty::Mask(..) => Self::mask_param(p, Some(c)).map_or(0.0, |m| m.value_at_local(l)),
            EffectProperty::MaskPath(_) => 0.0,
            EffectProperty::Anim(_, AnimationParam::Position) => {
                Self::anim_vector(p, Some(c)).map_or(0.0, |v| v.value_at_local(l).x)
            }
            EffectProperty::Anim(..) => Self::anim_scalar(p, Some(c)).map_or(0.0, |v| v.value_at_local(l)),
            EffectProperty::Scale => a.scale.value_at_local(l).x,
            EffectProperty::Position => a.position.value_at_local(l).x,
            EffectProperty::Anchor => a.anchor.value_at_local(l).x,
        }
    }

    pub fn vector_value(&self, p: &EffectProperty) -> Vec2 {
        let Some(c) = &self.clip else { return Vec2::ZERO };
        let a = &c.animation;
        let l = self.local_playhead();
        match p {
            EffectProperty::Position => a.position.value_at_local(l),
            EffectProperty::Scale => a.scale.value_at_local(l),
            EffectProperty::Anchor => a.anchor.value_at_local(l),
            EffectProperty::Fx { .. } if p.pair().is_some() => match Self::pair_members(p, Some(c)) {
                Some((x, y)) => Vec2::new(x.value_at_local(l), y.value_at_local(l)),
                None => Vec2::ZERO,
            },
            EffectProperty::Fx { .. } if p.kind() == EffectPropertyKind::Vector => {
                Self::point_param(p, Some(c)).map_or(Vec2::ZERO, |v| v.value_at_local(l))
            }
            EffectProperty::Anim(_, AnimationParam::Position) => {
                Self::anim_vector(p, Some(c)).map_or(Vec2::ZERO, |v| v.value_at_local(l))
            }
            _ => Vec2::new(self.scalar_value(p), 0.0),
        }
    }

    /// Color of a color parameter at the playhead (black for anything else).
    pub fn color_value(&self, p: &EffectProperty) -> EffectColor {
        Self::color_param(p, self.clip.as_ref()).map_or(EffectColor::BLACK, |v| v.value_at_local(self.local_playhead()))
    }

    /// The animated value of a slider / checkbox / choice parameter; nil when that effect instance is not on the clip.
    pub(crate) fn param(p: &EffectProperty, c: Option<&Clip>) -> Option<AnimatedProperty<f64>> {
        let EffectProperty::Fx { id, key, .. } = p else { return None };
        c?.effects.iter().find(|e| e.id == *id)?.parameters.get(key).cloned()
    }

    /// The animated number of a mask (Feather, Opacity, Expansion); nil when the mask is gone.
    pub(crate) fn mask_param(p: &EffectProperty, c: Option<&Clip>) -> Option<AnimatedProperty<f64>> {
        let EffectProperty::Mask(id, m) = p else { return None };
        Some(m.value_of(c?.mask(*id)?))
    }

    pub(crate) fn with_mask(c: &mut Clip, p: &EffectProperty, body: impl FnOnce(&mut AnimatedProperty<f64>)) {
        let EffectProperty::Mask(id, m) = p else { return };
        let m = *m;
        c.update_mask(*id, |mask| {
            let mut v = m.value_of(mask);
            body(&mut v);
            m.set(v, mask);
        });
    }

    /// The animated value of a color parameter.
    pub(crate) fn color_param(p: &EffectProperty, c: Option<&Clip>) -> Option<AnimatedProperty<EffectColor>> {
        let EffectProperty::Fx { id, key, .. } = p else { return None };
        c?.effects.iter().find(|e| e.id == *id)?.colors.get(key).cloned()
    }

    /// The animated value of a point parameter.
    pub(crate) fn point_param(p: &EffectProperty, c: Option<&Clip>) -> Option<AnimatedProperty<Vec2>> {
        let EffectProperty::Fx { id, key, .. } = p else { return None };
        if p.pair().is_some() {
            // Reads need no stable ids: a throwaway source serves `editable`.
            let mut ids = sq_core_time::SequentialIds::default();
            return Self::pair_members(p, c).map(|(x, y)| KeyframesPair::editable(&x, &y, &mut ids));
        }
        c?.effects.iter().find(|e| e.id == *id)?.points.get(key).cloned()
    }

    /// The two scalar members of a pair row (P4), as stored.
    pub(crate) fn pair_members(
        p: &EffectProperty,
        c: Option<&Clip>,
    ) -> Option<(AnimatedProperty<f64>, AnimatedProperty<f64>)> {
        let EffectProperty::Fx { id, kind, .. } = p else { return None };
        let pr = p.pair()?;
        let e = c?.effects.iter().find(|e| e.id == *id)?;
        let x = Self::member(e, kind, &pr.x);
        let y = if pr.linkable && !e.parameters.contains_key(&pr.y) { x.clone() } else { Self::member(e, kind, &pr.y) };
        Some((x, y))
    }

    /// A pair member as stored, or its catalog default when the effect does not store it (yet).
    pub(crate) fn member(e: &ClipEffect, kind: &str, key: &str) -> AnimatedProperty<f64> {
        e.parameters
            .get(key)
            .cloned()
            .unwrap_or_else(|| AnimatedProperty::new(EffectCatalog::param(kind, key).map_or(0.0, |s| s.default_value)))
    }

    /// P5: a linkable pair row (Transform Scale) is linked while its Y member is not stored (Height follows Scale).
    pub fn is_linked(&self, p: &EffectProperty) -> bool {
        let EffectProperty::Fx { id, .. } = p else { return false };
        let Some(pr) = p.pair() else { return false };
        if !pr.linkable {
            return false;
        }
        self.clip
            .as_ref()
            .and_then(|c| c.effects.iter().find(|e| e.id == *id))
            .is_some_and(|e| !e.parameters.contains_key(&pr.y))
    }

    /// Link toggle of a linkable pair row. Off: Height gets Scale's keys (same picture). On: Height is dropped and follows
    /// Scale again (a differing Height is lost, with a notice).
    pub fn set_linked(&mut self, p: &EffectProperty, on: bool) {
        let EffectProperty::Fx { id, .. } = p else { return };
        let Some(pr) = p.pair() else { return };
        if !pr.linkable || on == self.is_linked(p) {
            return;
        }
        let Some(mut c) = self.working_clip() else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return };
        if on {
            let kind = c.effects[i].kind.clone();
            let x = Self::member(&c.effects[i], &kind, &pr.x);
            let y = c.effects[i].parameters.get(&pr.y).cloned();
            let differs = y.is_some_and(|y| y.is_animated() || (y.value - x.value).abs() > 1e-9);
            c.effects[i].parameters.remove(&pr.y);
            self.commit(c, &format!("Link {}", p.title()), None);
            if differs {
                self.notice("Height set to Width.");
            }
        } else {
            let kind = c.effects[i].kind.clone();
            let fresh = Self::member(&c.effects[i], &kind, &pr.x).with_fresh_key_ids(&mut *self.ids);
            c.effects[i].parameters.insert(pr.y.clone(), fresh);
            self.commit(c, &format!("Unlink {}", p.title()), None);
        }
    }

    /// Keys of an effect parameter, typed by its kind.
    pub(crate) fn fx_track(p: &EffectProperty, c: Option<&Clip>) -> Option<PropertyTrack> {
        match p.kind() {
            EffectPropertyKind::Color => Self::color_param(p, c).map(|v| PropertyTrack::Color(v.track)),
            EffectPropertyKind::Vector => Self::point_param(p, c).map(|v| PropertyTrack::Vector(v.track)),
            _ => Self::param(p, c).map(|v| PropertyTrack::Scalar(v.track)),
        }
    }

    /// Every property that exists on `c` right now: the fixed ones and the parameters of its applied effects.
    pub(crate) fn all_properties(c: &Clip) -> Vec<EffectProperty> {
        let mut out: Vec<EffectProperty> = EffectProperty::BUILT_INS.to_vec();
        for e in c.effects.iter().filter(|e| EffectCatalog::spec_for(&e.kind).is_some()) {
            out.extend(EffectSection::Effect { id: e.id, kind: e.kind.clone() }.properties());
        }
        for m in c.masks() {
            out.extend(EffectSection::Mask(m.id).properties());
        }
        for m in c.masks().iter().filter(|m| m.source() == sq_core_model::MaskSource::Path) {
            out.push(EffectProperty::MaskPath(m.id));
        }
        // a preset side has no rows to edit
        for side in Self::custom_sides(Some(c)) {
            out.extend(EffectSection::Animation(side).properties());
        }
        out
    }

    pub fn track_of(&self, p: &EffectProperty) -> Option<PropertyTrack> {
        self.track(p, self.clip.as_ref())
    }

    pub(crate) fn track(&self, p: &EffectProperty, c: Option<&Clip>) -> Option<PropertyTrack> {
        let a = &c?.animation;
        match p {
            EffectProperty::Position => Some(PropertyTrack::Vector(a.position.track.clone())),
            EffectProperty::Scale => Some(PropertyTrack::Vector(a.scale.track.clone())),
            EffectProperty::Anchor => Some(PropertyTrack::Vector(a.anchor.track.clone())),
            EffectProperty::Rotation => Some(PropertyTrack::Scalar(a.rotation.track.clone())),
            EffectProperty::TiltX => Some(PropertyTrack::Scalar(a.tilt_x.track.clone())),
            EffectProperty::TiltY => Some(PropertyTrack::Scalar(a.tilt_y.track.clone())),
            EffectProperty::Opacity => Some(PropertyTrack::Scalar(a.opacity.track.clone())),
            EffectProperty::Volume => Some(PropertyTrack::Scalar(a.volume.track.clone())),
            EffectProperty::ShutterAngle => Some(PropertyTrack::Scalar(a.shutter_angle.track.clone())),
            EffectProperty::AntiFlicker => Some(PropertyTrack::Scalar(a.anti_flicker.track.clone())),
            EffectProperty::Fx { .. } => Self::fx_track(p, c),
            EffectProperty::Mask(..) => Self::mask_param(p, c).map(|m| PropertyTrack::Scalar(m.track)),
            EffectProperty::MaskPath(id) => c?.mask(*id).map(|m| PropertyTrack::Path(m.path.track.clone())),
            EffectProperty::Anim(_, AnimationParam::Position) => {
                Self::anim_vector(p, c).map(|v| PropertyTrack::Vector(v.track))
            }
            EffectProperty::Anim(..) => Self::anim_scalar(p, c).map(|v| PropertyTrack::Scalar(v.track)),
        }
    }

    pub(crate) fn key_time(&self, p: &EffectProperty, at: Time) -> bool {
        self.track_of(p).is_some_and(|t| t.times().iter().any(|(_, time)| *time == at))
    }

    /// Key times in timeline time.
    pub fn keys(&self, p: &EffectProperty) -> Vec<(Id, Time)> {
        let start = self.clip.as_ref().map_or(Time::ZERO, |c| c.start);
        self.track_of(p).map(|t| t.times()).unwrap_or_default().into_iter().map(|(id, t)| (id, t + start)).collect()
    }

    // MARK: Property access by kind

    pub(crate) fn with_scalar(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        local: Time,
        body: impl FnOnce(&mut AnimatedProperty<f64>, &mut dyn IdSource),
    ) {
        match p {
            EffectProperty::Rotation => body(&mut c.animation.rotation, ids),
            EffectProperty::TiltX => body(&mut c.animation.tilt_x, ids),
            EffectProperty::TiltY => body(&mut c.animation.tilt_y, ids),
            EffectProperty::Opacity => body(&mut c.animation.opacity, ids),
            EffectProperty::Volume => body(&mut c.animation.volume, ids),
            EffectProperty::ShutterAngle => body(&mut c.animation.shutter_angle, ids),
            EffectProperty::AntiFlicker => body(&mut c.animation.anti_flicker, ids),
            EffectProperty::Fx { .. } if p.pair().is_some() => {} // a pair row is a vector (withVector writes both members)
            EffectProperty::Fx { .. } => Self::with_fx(ids, c, p, body),
            EffectProperty::Mask(..) => Self::with_mask(c, p, |v| body(v, ids)),
            EffectProperty::Anim(..) => Self::with_anim_scalar(ids, c, p, local, body),
            _ => {}
        }
    }

    pub(crate) fn with_vector(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        local: Time,
        body: impl FnOnce(&mut AnimatedProperty<Vec2>, &mut dyn IdSource),
    ) {
        match p {
            EffectProperty::Position => body(&mut c.animation.position, ids),
            EffectProperty::Scale => body(&mut c.animation.scale, ids),
            EffectProperty::Anchor => body(&mut c.animation.anchor, ids),
            EffectProperty::Fx { .. } => Self::with_fx_point(ids, c, p, body),
            EffectProperty::Anim(..) => Self::with_anim_vector(ids, c, p, local, body),
            _ => {}
        }
    }

    pub(crate) fn with_color(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        body: impl FnOnce(&mut AnimatedProperty<EffectColor>, &mut dyn IdSource),
    ) {
        if matches!(p, EffectProperty::Fx { .. }) {
            Self::with_fx_color(ids, c, p, body);
        }
    }

    /// After a per-row key edit at `local`: a value left static keeps what the picture showed (hue the short way,
    /// wheel on the disc) and an animated Color wheel partner is keyed so the puck does not jump.
    pub(crate) fn follow_shown(ids: &mut dyn IdSource, c: &mut Clip, p: &EffectProperty, before: &Clip, local: Time) {
        let EffectProperty::Fx { id, key, .. } = p else { return };
        c.follow_shown_values(*id, key, local, before, ids);
    }

    /// Mutates one effect parameter in place (nothing happens when the instance or parameter is gone).
    pub(crate) fn with_fx(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        body: impl FnOnce(&mut AnimatedProperty<f64>, &mut dyn IdSource),
    ) {
        if Self::is_pending_crop(p, c) {
            Self::with_pending_crop(ids, c, p, body); // Transform's Crop rows add the Crop
            return;
        }
        let EffectProperty::Fx { id, kind, key } = p else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return };
        // A Crop saved before Softness existed does not store it: it starts from the default.
        let stored = c.effects[i].parameters.get(key).cloned().or_else(|| {
            if kind == ClipEffect::CROP_KIND {
                EffectCatalog::param(kind, key).map(|s| AnimatedProperty::new(s.default_value))
            } else {
                None
            }
        });
        let Some(mut v) = stored else { return };
        let before: std::collections::BTreeSet<Id> = v.track.keys.iter().map(|k| k.id).collect();
        body(&mut v, ids);
        // Checkbox / popup values jump: keys they get are hold, never interpolated.
        if p.param_kind().is_some_and(|k| k.is_stepped()) {
            let new_ids: Vec<Id> = v.track.keys.iter().map(|k| k.id).filter(|id| !before.contains(id)).collect();
            for id in new_ids {
                v.track.update(id, |k| k.interpolation = sq_core_time::Interpolation::Hold);
            }
        }
        c.effects[i].parameters.insert(key.clone(), v);
    }

    /// Mutates one point parameter of an effect instance.
    pub(crate) fn with_fx_point(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        body: impl FnOnce(&mut AnimatedProperty<Vec2>, &mut dyn IdSource),
    ) {
        if p.pair().is_some() {
            // P4: both scalar members as one Vec2, written back aligned (storage stays two tracks, no file change).
            Self::with_pair(ids, c, p, |x, y, ids| KeyframesPair::edit(x, y, ids, body));
            return;
        }
        let EffectProperty::Fx { id, key, .. } = p else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return };
        let Some(mut v) = c.effects[i].points.get(key).cloned() else { return };
        body(&mut v, ids);
        c.effects[i].points.insert(key.clone(), v);
    }

    /// Mutates the two scalar members of a pair row (P4) and stores them. Linked (P5): Height is not stored; it follows
    /// X, edited as a pair of equals.
    pub(crate) fn with_pair(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        body: impl FnOnce(&mut AnimatedProperty<f64>, &mut AnimatedProperty<f64>, &mut dyn IdSource),
    ) {
        let EffectProperty::Fx { id, kind, .. } = p else { return };
        let Some(pr) = p.pair() else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return };
        let mut x = Self::member(&c.effects[i], kind, &pr.x);
        let mut y = Self::member(&c.effects[i], kind, &pr.y);
        let linked = pr.linkable && !c.effects[i].parameters.contains_key(&pr.y);
        if linked {
            y = x.with_fresh_key_ids(ids);
        }
        body(&mut x, &mut y, ids);
        c.effects[i].parameters.insert(pr.x.clone(), x);
        if !linked {
            c.effects[i].parameters.insert(pr.y.clone(), y);
        }
    }

    /// Mutates one color parameter of an effect instance.
    pub(crate) fn with_fx_color(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        body: impl FnOnce(&mut AnimatedProperty<EffectColor>, &mut dyn IdSource),
    ) {
        let EffectProperty::Fx { id, key, .. } = p else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == *id) else { return };
        let Some(mut v) = c.effects[i].colors.get(key).cloned() else { return };
        body(&mut v, ids);
        c.effects[i].colors.insert(key.clone(), v);
    }

    // MARK: Transform's Crop rows (EffectControlsModel+TransformCrop.swift)

    pub(crate) const TRANSFORM_CROP_KEYS: [&'static str; 5] = [
        ClipEffect::CROP_LEFT_KEY,
        ClipEffect::CROP_RIGHT_KEY,
        ClipEffect::CROP_TOP_KEY,
        ClipEffect::CROP_BOTTOM_KEY,
        ClipEffect::CROP_SOFTNESS_KEY,
    ];

    /// Id the Crop of `clip` gets when Transform's Crop rows add it: fixed per clip, so the rows keep their identity
    /// (expanded state, focus) across the add.
    pub(crate) fn pending_crop_id(clip: Id) -> Id {
        let mut u = clip.as_u128();
        // bytes 0, 5, 10, 15 of the UUID (index 0 is the most significant byte)
        u ^= 0x5Cu128 << (8 * 15);
        u ^= 0xC5u128 << (8 * 10);
        u ^= 0x5Cu128 << (8 * 5);
        u ^= 0xC5u128;
        Id::from_u128(u)
    }

    /// The Crop Transform's rows edit: the clip's first Crop, or the placeholder id. nil for sound clips.
    pub(crate) fn transform_crop_id(c: &Clip) -> Option<Id> {
        if c.kind == TrackKind::Audio {
            return None;
        }
        Some(
            c.effects
                .iter()
                .find(|e| e.kind == ClipEffect::CROP_KIND)
                .map_or_else(|| Self::pending_crop_id(c.id), |e| e.id),
        )
    }

    /// The Crop rows under Transform for the shown clip (empty for sound clips and when nothing is shown).
    pub fn transform_crop_properties(&self) -> Vec<EffectProperty> {
        let Some(c) = &self.clip else { return Vec::new() };
        let Some(id) = Self::transform_crop_id(c) else { return Vec::new() };
        Self::TRANSFORM_CROP_KEYS
            .iter()
            .map(|k| EffectProperty::Fx { id, kind: ClipEffect::CROP_KIND.to_string(), key: (*k).to_string() })
            .collect()
    }

    /// The rows of a section as the panel shows them: Transform carries the Crop rows.
    pub fn properties_of(&self, s: &EffectSection) -> Vec<EffectProperty> {
        let mut p = s.properties();
        if *s == EffectSection::Motion {
            p.extend(self.transform_crop_properties());
        }
        p
    }

    /// Every property row of the visible sections, in panel order.
    pub(crate) fn panel_properties(&self) -> Vec<EffectProperty> {
        self.visible_sections().iter().flat_map(|s| self.properties_of(s)).collect()
    }

    /// True when `p` is a Crop row of `c` whose Crop is not on the clip yet.
    pub(crate) fn is_pending_crop(p: &EffectProperty, c: &Clip) -> bool {
        let EffectProperty::Fx { id, kind, .. } = p else { return false };
        if kind != ClipEffect::CROP_KIND || *id != Self::pending_crop_id(c.id) {
            return false;
        }
        !c.effects.iter().any(|e| e.id == *id)
    }

    /// `body` on a Crop row of `c` whose Crop is not there yet: the Crop is added (at the end, like an applied effect) only
    /// when `body` leaves it different from a fresh one, so a reset or a no-op adds nothing.
    pub(crate) fn with_pending_crop(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        body: impl FnOnce(&mut AnimatedProperty<f64>, &mut dyn IdSource),
    ) {
        let EffectProperty::Fx { id, key, .. } = p else { return };
        let Some(made) = ClipEffect::make(*id, ClipEffect::CROP_KIND) else { return };
        let mut e = made;
        let fresh = e.clone();
        let mut v = e.parameters.get(key).cloned().unwrap_or_else(|| {
            AnimatedProperty::new(EffectCatalog::param(ClipEffect::CROP_KIND, key).map_or(0.0, |s| s.default_value))
        });
        body(&mut v, ids);
        e.parameters.insert(key.clone(), v);
        if e != fresh {
            c.effects.push(e);
        }
    }

    // MARK: Tracks of a clip

    pub(crate) fn tracks_of(c: &Clip) -> BTreeMap<PropertyID, PropertyTrack> {
        let a = &c.animation;
        let mut out: BTreeMap<PropertyID, PropertyTrack> = BTreeMap::new();
        let mut put = |p: &EffectProperty, t: PropertyTrack| {
            if !t.key_ids().is_empty() {
                out.insert(p.id(), t);
            }
        };
        put(&EffectProperty::Position, PropertyTrack::Vector(a.position.track.clone()));
        put(&EffectProperty::Scale, PropertyTrack::Vector(a.scale.track.clone()));
        put(&EffectProperty::Anchor, PropertyTrack::Vector(a.anchor.track.clone()));
        put(&EffectProperty::Rotation, PropertyTrack::Scalar(a.rotation.track.clone()));
        put(&EffectProperty::TiltX, PropertyTrack::Scalar(a.tilt_x.track.clone()));
        put(&EffectProperty::TiltY, PropertyTrack::Scalar(a.tilt_y.track.clone()));
        put(&EffectProperty::Opacity, PropertyTrack::Scalar(a.opacity.track.clone()));
        put(&EffectProperty::Volume, PropertyTrack::Scalar(a.volume.track.clone()));
        put(&EffectProperty::ShutterAngle, PropertyTrack::Scalar(a.shutter_angle.track.clone()));
        put(&EffectProperty::AntiFlicker, PropertyTrack::Scalar(a.anti_flicker.track.clone()));
        for p in Self::all_properties(c) {
            match &p {
                EffectProperty::Fx { .. } => {
                    if let Some(t) = Self::fx_track(&p, Some(c)) {
                        put(&p, t);
                    }
                }
                EffectProperty::Mask(..) => {
                    if let Some(m) = Self::mask_param(&p, Some(c)) {
                        put(&p, PropertyTrack::Scalar(m.track));
                    }
                }
                EffectProperty::MaskPath(id) => {
                    if let Some(m) = c.mask(*id) {
                        put(&p, PropertyTrack::Path(m.path.track.clone()));
                    }
                }
                EffectProperty::Anim(_, param) => {
                    if *param == AnimationParam::Position {
                        if let Some(v) = Self::anim_vector(&p, Some(c)) {
                            put(&p, PropertyTrack::Vector(v.track));
                        }
                    } else if let Some(v) = Self::anim_scalar(&p, Some(c)) {
                        put(&p, PropertyTrack::Scalar(v.track));
                    }
                }
                _ => {}
            }
        }
        out
    }

    /// Posts a seek to the host (timeline time).
    pub(crate) fn seek(&mut self, t: Time) {
        self.events.push(EffectControlsEvent::Seek(t));
    }

    pub fn previous_key_time(&self, p: &EffectProperty) -> Option<Time> {
        let l = self.local_playhead();
        let t = self.track_of(p)?.times().into_iter().map(|(_, t)| t).filter(|t| *t < l).max()?;
        Some(t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start))
    }

    pub fn next_key_time(&self, p: &EffectProperty) -> Option<Time> {
        let l = self.local_playhead();
        let t = self.track_of(p)?.times().into_iter().map(|(_, t)| t).filter(|t| *t > l).min()?;
        Some(t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start))
    }

    pub fn go_to_previous_key(&mut self, p: &EffectProperty) {
        if let Some(t) = self.previous_key_time(p) {
            self.reveal_playhead(t);
            self.seek(t);
        }
    }

    pub fn go_to_next_key(&mut self, p: &EffectProperty) {
        if let Some(t) = self.next_key_time(p) {
            self.reveal_playhead(t);
            self.seek(t);
        }
    }
}
