// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CustomAnimation.swift
//
// A Custom animation is a `KeyframeTemplate` whose tracks the user keys by hand. These helpers show one side's tracks in
// clip-local time (what the Controls lanes use) and write them back in template time.

use sq_core_effects::keystone::{Keystone, KeystoneAnchor};
use sq_core_model::AnimatedProperty;
use sq_core_model::anchored_animation::{
    AnimationAnchor, AnimationSet, AnimationTrack, KeyframeTemplate, SegmentShape,
};
use sq_core_model::keyframes_pair::KeyframesPair;
use sq_core_time::keyframes_easing::EaseSide;
use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, Time, Vec2};
use std::collections::BTreeMap;

/// The two sides of an item's animation (`AnimationSet::animation_in` / `animation_out`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnimationSide {
    /// The in-animation.
    Intro,
    /// The out-animation.
    Outro,
}

impl AnimationSide {
    /// Both sides.
    pub const ALL: [AnimationSide; 2] = [AnimationSide::Intro, AnimationSide::Outro];

    /// Shown name.
    pub fn title(self) -> &'static str {
        if self == AnimationSide::Intro { "Intro" } else { "Outro" }
    }
}

/// What a Custom animation keys per side: one Controls row each. Position is the pair "positionX" / "positionY".
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnimationParam {
    /// Position (two tracks).
    Position,
    /// Scale.
    Scale,
    /// Rotation.
    Rotation,
    /// Opacity.
    Opacity,
}

impl AnimationParam {
    /// Every row.
    pub const ALL: [AnimationParam; 4] =
        [AnimationParam::Position, AnimationParam::Scale, AnimationParam::Rotation, AnimationParam::Opacity];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            AnimationParam::Position => "Position",
            AnimationParam::Scale => "Scale",
            AnimationParam::Rotation => "Rotation",
            AnimationParam::Opacity => "Opacity",
        }
    }

    /// The `AnimationTrack::property` names behind the row.
    pub fn track_names(self) -> &'static [&'static str] {
        match self {
            AnimationParam::Position => &["positionX", "positionY"],
            AnimationParam::Scale => &["scale"],
            AnimationParam::Rotation => &["rotation"],
            AnimationParam::Opacity => &["opacity"],
        }
    }

    /// The value where the row does nothing (`AnimationSample.rest`).
    pub fn rest(self) -> f64 {
        if self == AnimationParam::Scale || self == AnimationParam::Opacity { 1.0 } else { 0.0 }
    }

    /// The rest value of the track `name`.
    pub fn rest_of_track(name: &str) -> f64 {
        if name == "scale" || name == "opacity" { 1.0 } else { 0.0 }
    }
}

/// Built-in templates number their keys per track (`AnimationTrack::key_id`), so two tracks share ids: ten leading zero bytes.
fn is_shared(id: Id) -> bool {
    id.as_u128() >> 48 == 0
}

/// The lanes select keys by id: a shared id is replaced by one that also carries side and track. The same key always maps
/// to the same id.
fn stable_id(id: Id, side: AnimationSide, track: usize) -> Id {
    if !is_shared(id) {
        return id;
    }
    let side_byte: u128 = if side == AnimationSide::Intro { 1 } else { 2 };
    // Bytes 7 and 9 of the UUID; `track + 1` is truncated to a byte like Swift's `truncatingIfNeeded`.
    let track_byte = u128::from((track + 1) as u8);
    Id::from_u128((id.as_u128() & !(0xFF << 64) & !(0xFF << 48)) | (side_byte << 64) | (track_byte << 48))
}

/// The side's template as a Custom animation edits it (Swift `extension AnimationSet`).
pub trait AnimationSetCustomExt {
    /// Length of a side that starts as Custom from nothing (10 frames at 30 fps).
    const CUSTOM_LENGTH: Time = Time::new(1, 3);

    /// The side's template.
    fn template(&self, side: AnimationSide) -> Option<&KeyframeTemplate>;
    /// Clip time of the side's template time 0. The outro of a clip too short to play it still ends at the clip's end.
    fn offset(&self, side: AnimationSide, clip_duration: Time) -> Time;
    /// One track of a side with clip-local key times; without keys it rests.
    fn track(&self, name: &str, side: AnimationSide, clip_duration: Time) -> AnimatedProperty<f64>;
    /// A scalar row (Scale, Rotation, Opacity) in clip-local time. Position reads its X member; use `position`.
    fn scalar(&self, param: AnimationParam, side: AnimationSide, clip_duration: Time) -> AnimatedProperty<f64>;
    /// The Position row: both members as one point (`KeyframesPair::editable`).
    fn position(&self, side: AnimationSide, clip_duration: Time, ids: &mut dyn IdSource) -> AnimatedProperty<Vec2>;
    /// Edits a scalar row in clip-local time and writes it back (`write`).
    fn edit(
        &mut self,
        param: AnimationParam,
        side: AnimationSide,
        clip_duration: Time,
        body: impl FnOnce(&mut AnimatedProperty<f64>),
    );
    /// Edits the Position row in clip-local time; storage stays two aligned scalar tracks.
    fn edit_position(
        &mut self,
        side: AnimationSide,
        clip_duration: Time,
        ids: &mut dyn IdSource,
        body: impl FnOnce(&mut AnimatedProperty<Vec2>),
    );
    /// Stores tracks given in clip-local time. A track without keys is removed (the row rests). Then the side's length
    /// follows its keys: an intro ends at its last key; an outro starts at its first key and keeps its end, so every key
    /// stays at its clip time. A looping template keeps its period.
    fn write(&mut self, edited: &BTreeMap<String, AnimatedProperty<f64>>, side: AnimationSide, clip_duration: Time);
}

impl AnimationSetCustomExt for AnimationSet {
    fn template(&self, side: AnimationSide) -> Option<&KeyframeTemplate> {
        if side == AnimationSide::Intro { self.animation_in.as_ref() } else { self.animation_out.as_ref() }
    }

    fn offset(&self, side: AnimationSide, clip_duration: Time) -> Time {
        if side != AnimationSide::Outro {
            return Time::ZERO;
        }
        self.out_start(clip_duration)
            .unwrap_or_else(|| clip_duration - self.animation_out.as_ref().map_or(Self::CUSTOM_LENGTH, |a| a.duration))
    }

    fn track(&self, name: &str, side: AnimationSide, clip_duration: Time) -> AnimatedProperty<f64> {
        let rest = AnimationParam::rest_of_track(name);
        let found = self.template(side).and_then(|t| t.tracks.iter().position(|x| x.property == name).map(|i| (t, i)));
        let Some((t, i)) = found else { return AnimatedProperty::new(rest) };
        let offset = self.offset(side, clip_duration);
        let stored = t.tracks[i].track();
        // A Custom intro is stored as it is shown (time 0 = clip start, ids of its own): no copy per read.
        if offset == Time::ZERO && !stored.keys.iter().any(|k| is_shared(k.id)) {
            return AnimatedProperty { value: rest, track: stored.clone() };
        }
        let mut keys = stored.keys.clone();
        for k in &mut keys {
            k.time += offset;
            k.id = stable_id(k.id, side, i);
        }
        AnimatedProperty { value: rest, track: KeyframeTrack::with_keys(keys) }
    }

    fn scalar(&self, param: AnimationParam, side: AnimationSide, clip_duration: Time) -> AnimatedProperty<f64> {
        self.track(param.track_names()[0], side, clip_duration)
    }

    fn position(&self, side: AnimationSide, clip_duration: Time, ids: &mut dyn IdSource) -> AnimatedProperty<Vec2> {
        KeyframesPair::editable(
            &self.track("positionX", side, clip_duration),
            &self.track("positionY", side, clip_duration),
            ids,
        )
    }

    fn edit(
        &mut self,
        param: AnimationParam,
        side: AnimationSide,
        clip_duration: Time,
        body: impl FnOnce(&mut AnimatedProperty<f64>),
    ) {
        if param == AnimationParam::Position {
            return;
        }
        let name = param.track_names()[0];
        let mut v = self.track(name, side, clip_duration);
        let before = v.clone();
        body(&mut v);
        if v == before {
            return; // nothing edited: the stored keys (and their ids) stay as they are
        }
        self.write(&BTreeMap::from([(name.to_string(), v)]), side, clip_duration);
    }

    fn edit_position(
        &mut self,
        side: AnimationSide,
        clip_duration: Time,
        ids: &mut dyn IdSource,
        body: impl FnOnce(&mut AnimatedProperty<Vec2>),
    ) {
        let mut x = self.track("positionX", side, clip_duration);
        let mut y = self.track("positionY", side, clip_duration);
        let mut point = KeyframesPair::editable(&x, &y, ids);
        let before = point.clone();
        body(&mut point);
        if point == before {
            return; // nothing edited: no split into two tracks, no new ids
        }
        KeyframesPair::edit(&mut x, &mut y, ids, |v, _| *v = point.clone());
        let edited = BTreeMap::from([("positionX".to_string(), x), ("positionY".to_string(), y)]);
        self.write(&edited, side, clip_duration);
    }

    fn write(&mut self, edited: &BTreeMap<String, AnimatedProperty<f64>>, side: AnimationSide, clip_duration: Time) {
        let offset = self.offset(side, clip_duration);
        let mut t = self.template(side).cloned().unwrap_or(KeyframeTemplate {
            tracks: Vec::new(),
            duration: Self::CUSTOM_LENGTH,
            anchor: AnimationAnchor::Start,
            text_animator: None,
            loops: false,
        });
        for (name, v) in edited {
            let i = t.tracks.iter().position(|x| &x.property == name);
            if v.track.is_empty() {
                if let Some(i) = i {
                    t.tracks.remove(i);
                }
                continue;
            }
            let track = AnimationTrack::new(name.clone(), v.shifted(Time::ZERO - offset).track);
            match i {
                Some(i) => t.tracks[i] = track,
                None => t.tracks.push(track),
            }
        }
        let times: Vec<Time> = t.tracks.iter().flat_map(|x| x.track().keys.iter().map(|k| k.time)).collect();
        if let (false, Some(first), Some(last)) = (t.loops, times.iter().copied().min(), times.iter().copied().max()) {
            match side {
                AnimationSide::Intro => {
                    if last > Time::ZERO {
                        t.duration = last;
                    }
                }
                AnimationSide::Outro => {
                    let length = t.duration - first;
                    if first != Time::ZERO && length > Time::ZERO {
                        for tr in &mut t.tracks {
                            let mut keys = tr.track().keys.clone();
                            for k in &mut keys {
                                k.time -= first;
                            }
                            tr.set_track(KeyframeTrack::with_keys(keys));
                        }
                        t.duration = length;
                    }
                }
            }
        }
        t.anchor = if side == AnimationSide::Intro { AnimationAnchor::Start } else { AnimationAnchor::End };
        // Nothing keyed and no text animator: the side is Off again (None, the same bits as never animated).
        let stored = if t.tracks.is_empty() && t.text_animator.is_none() { None } else { Some(t) };
        if side == AnimationSide::Intro {
            self.animation_in = stored;
        } else {
            self.animation_out = stored;
        }
    }
}

/// Custom animation helpers on a template (Swift `extension KeyframeTemplate`).
pub trait KeyframeTemplateCustomExt {
    /// The template with new key ids (a copy that is edited on its own).
    fn with_fresh_key_ids(&self, ids: &mut dyn IdSource) -> KeyframeTemplate;
    /// Equal apart from key ids (a Custom animation against the preset or saved one it came from).
    fn same_curves(&self, other: &KeyframeTemplate) -> bool;
    /// What Custom starts from when the side was Off: a plain fade over `AnimationSet::CUSTOM_LENGTH`.
    fn custom_start(side: AnimationSide, ids: &mut dyn IdSource) -> KeyframeTemplate;
    /// True once a key carries an id of its own: the template was made Custom (`with_fresh_key_ids`) and is edited by hand.
    /// Presets number their keys per track (`AnimationTrack::key_id`).
    fn has_own_key_ids(&self) -> bool;
    /// The same animation whatever the frame it was built for: equal apart from key ids, and each Position track may differ
    /// by one positive factor (a saved animation stores Position as a fraction of the frame, so its pixels change with the
    /// sequence format).
    fn same_shape(&self, other: &KeyframeTemplate) -> bool;
}

impl KeyframeTemplateCustomExt for KeyframeTemplate {
    fn with_fresh_key_ids(&self, ids: &mut dyn IdSource) -> KeyframeTemplate {
        let mut c = self.clone();
        for tr in &mut c.tracks {
            let mut keys = tr.track().keys.clone();
            for k in &mut keys {
                k.id = ids.next_id();
            }
            tr.set_track(KeyframeTrack::with_keys(keys));
        }
        c
    }

    fn same_curves(&self, other: &KeyframeTemplate) -> bool {
        fn strip(t: &KeyframeTemplate) -> KeyframeTemplate {
            let mut c = t.clone();
            for tr in &mut c.tracks {
                let mut keys = tr.track().keys.clone();
                for (n, k) in keys.iter_mut().enumerate() {
                    k.id = AnimationTrack::key_id(n);
                }
                tr.set_track(KeyframeTrack::with_keys(keys));
            }
            c
        }
        strip(self) == strip(other)
    }

    fn custom_start(side: AnimationSide, ids: &mut dyn IdSource) -> KeyframeTemplate {
        let d = AnimationSet::CUSTOM_LENGTH;
        let keys: [(Time, f64, SegmentShape); 2] = if side == AnimationSide::Intro {
            [(Time::ZERO, 0.0, SegmentShape::Linear), (d, 1.0, SegmentShape::Linear)]
        } else {
            [(Time::ZERO, 1.0, SegmentShape::Linear), (d, 0.0, SegmentShape::Linear)]
        };
        KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes("opacity", &keys)],
            duration: d,
            anchor: if side == AnimationSide::Intro { AnimationAnchor::Start } else { AnimationAnchor::End },
            text_animator: None,
            loops: false,
        }
        .with_fresh_key_ids(ids)
    }

    fn has_own_key_ids(&self) -> bool {
        self.tracks.iter().any(|t| t.track().keys.iter().any(|k| k.id.as_u128() >> 80 != 0))
    }

    fn same_shape(&self, other: &KeyframeTemplate) -> bool {
        if self.duration != other.duration
            || self.anchor != other.anchor
            || self.loops != other.loops
            || self.text_animator != other.text_animator
            || self.tracks.len() != other.tracks.len()
        {
            return false;
        }
        for a in &self.tracks {
            let Some(b) = other.track_for(&a.property) else { return false };
            let (ak, bk) = (&a.track().keys, &b.track().keys);
            if ak.len() != bk.len() {
                return false;
            }
            let position = a.property == "positionX" || a.property == "positionY";
            let norm = |keys: &[Keyframe<f64>]| {
                if position { keys.iter().fold(0.0, |m, k| f64::max(m, k.value.abs())) } else { 1.0 }
            };
            let (na, nb) = (norm(ak), norm(bk));
            if (na == 0.0) != (nb == 0.0) {
                return false;
            }
            for (x, y) in ak.iter().zip(bk) {
                if x.time != y.time
                    || x.interpolation != y.interpolation
                    || x.in_handle != y.in_handle
                    || x.out_handle != y.out_handle
                {
                    return false;
                }
                let u = if na == 0.0 { 0.0 } else { x.value / na };
                let v = if nb == 0.0 { 0.0 } else { y.value / nb };
                if (u - v).abs() > 1e-6 {
                    return false;
                }
            }
        }
        true
    }
}

/// `k` with another id and value, same time and shape.
fn rekey<A, B>(k: &Keyframe<A>, id: Id, value: B) -> Keyframe<B> {
    let mut n = Keyframe::new(id, k.time, value);
    n.interpolation = k.interpolation;
    n.in_handle = k.in_handle;
    n.out_handle = k.out_handle;
    n
}

/// A saved Custom animation is a keystone (`PresetKind.keystone`): the same store as every other keyframe building block.
pub trait KeystoneAnimationExt: Sized {
    /// The side of an item's animation this keystone can play: one that starts with the clip or ends with it.
    fn animation_side(&self) -> Option<AnimationSide>;
    /// Saves one side of an animation. Position becomes a fraction of `frame_size`, Scale a factor, as a keystone stores
    /// them. `None` when the side keys nothing. The text animator is not part of it (it is chosen on its own).
    fn from_animation(
        t: &KeyframeTemplate,
        side: AnimationSide,
        name: &str,
        frame_size: Vec2,
        ids: &mut dyn IdSource,
    ) -> Option<Self>;
    /// The keystone as one side of an item's animation (keys numbered like a preset's); `None` for a free keystone or an
    /// empty one. Position is `frame_size` pixels, Scale its X factor.
    fn animation_template(&self, frame_size: Vec2) -> Option<KeyframeTemplate>;
}

impl KeystoneAnimationExt for Keystone {
    fn animation_side(&self) -> Option<AnimationSide> {
        match self.anchor {
            KeystoneAnchor::ClipStart => Some(AnimationSide::Intro),
            KeystoneAnchor::ClipEnd => Some(AnimationSide::Outro),
            KeystoneAnchor::Free => None,
        }
    }

    fn from_animation(
        t: &KeyframeTemplate,
        side: AnimationSide,
        name: &str,
        frame_size: Vec2,
        ids: &mut dyn IdSource,
    ) -> Option<Keystone> {
        if t.duration <= Time::ZERO || !t.tracks.iter().any(|x| !x.track().is_empty()) {
            return None;
        }
        let anchor = if side == AnimationSide::Intro { KeystoneAnchor::ClipStart } else { KeystoneAnchor::ClipEnd };
        let mut k = Keystone::new(ids.next_id(), name, t.duration, anchor);
        if t.loops {
            k.loops = Some(true);
        }
        let member = |n: &str| AnimatedProperty {
            value: AnimationParam::rest_of_track(n),
            track: t.track_for(n).map_or_else(KeyframeTrack::default, |x| x.track().clone()),
        };
        let w = if frame_size.x == 0.0 { 1.0 } else { frame_size.x };
        let h = if frame_size.y == 0.0 { 1.0 } else { frame_size.y };
        let p = KeyframesPair::editable(&member("positionX"), &member("positionY"), ids).track;
        if !p.is_empty() {
            let keys =
                p.keys.iter().map(|q| rekey(q, ids.next_id(), Vec2::new(q.value.x / w, q.value.y / h))).collect();
            k.position = Some(KeyframeTrack::with_keys(keys));
        }
        let s = member("scale").track;
        if !s.is_empty() {
            let keys = s.keys.iter().map(|q| rekey(q, ids.next_id(), Vec2::new(q.value, q.value))).collect();
            k.scale = Some(KeyframeTrack::with_keys(keys));
        }
        let r = member("rotation").track;
        if !r.is_empty() {
            k.rotation =
                Some(KeyframeTrack::with_keys(r.keys.iter().map(|q| rekey(q, ids.next_id(), q.value)).collect()));
        }
        let o = member("opacity").track;
        if !o.is_empty() {
            k.opacity =
                Some(KeyframeTrack::with_keys(o.keys.iter().map(|q| rekey(q, ids.next_id(), q.value)).collect()));
        }
        Some(k)
    }

    fn animation_template(&self, frame_size: Vec2) -> Option<KeyframeTemplate> {
        let side = self.animation_side().filter(|_| self.duration > Time::ZERO)?;
        let mut tracks: Vec<AnimationTrack> = Vec::new();
        let mut add = |name: &str, keys: Vec<Keyframe<f64>>| {
            if keys.is_empty() {
                return;
            }
            let keys = keys
                .iter()
                .enumerate()
                .map(|(n, k)| {
                    let mut key = rekey(k, AnimationTrack::key_id(n), k.value);
                    if let Some(e) = &self.easing {
                        e.apply(&mut key, EaseSide::Both); // the keystone's own curve replaces each key's shape, as on apply
                    }
                    key
                })
                .collect();
            tracks.push(AnimationTrack::new(name.to_string(), KeyframeTrack::with_keys(keys)));
        };
        let scalar = |t: &Option<KeyframeTrack<f64>>| t.as_ref().map(|t| t.keys.clone()).unwrap_or_default();
        let pick = |t: &Option<KeyframeTrack<Vec2>>, f: &dyn Fn(Vec2) -> f64| -> Vec<Keyframe<f64>> {
            t.as_ref().map(|t| t.keys.iter().map(|k| rekey(k, k.id, f(k.value))).collect()).unwrap_or_default()
        };
        add("opacity", scalar(&self.opacity));
        add("scale", pick(&self.scale, &|v| v.x));
        add("positionX", pick(&self.position, &|v| v.x * frame_size.x));
        add("positionY", pick(&self.position, &|v| v.y * frame_size.y));
        add("rotation", scalar(&self.rotation));
        if tracks.is_empty() {
            return None;
        }
        Some(KeyframeTemplate {
            tracks,
            duration: self.duration,
            anchor: if side == AnimationSide::Intro { AnimationAnchor::Start } else { AnimationAnchor::End },
            text_animator: None,
            loops: self.loops == Some(true),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::keystone::KeystoneProperty;
    use sq_core_model::anchored_animation::AnimationSample;
    use sq_core_time::{EasingCurve, Interpolation};

    /// Ids like random UUIDs (high bytes set): `SequentialIds` would make every id look like a preset's numbered key id.
    #[derive(Default)]
    struct SequentialIds(u128);

    impl IdSource for SequentialIds {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128((0xA1B2_u128 << 100) + self.0)
        }
    }

    fn f() -> Time {
        Time::new(1, 30)
    }

    fn clip() -> Time {
        Time::new(3, 1)
    }

    fn template(tracks: Vec<AnimationTrack>, duration: Time, anchor: AnimationAnchor) -> KeyframeTemplate {
        KeyframeTemplate { tracks, duration, anchor, text_animator: None, loops: false }
    }

    fn fade_in(end: Time) -> KeyframeTemplate {
        let keys = [(Time::ZERO, 0.0, SegmentShape::Linear), (end, 1.0, SegmentShape::Linear)];
        template(vec![AnimationTrack::from_shapes("opacity", &keys)], end, AnimationAnchor::Start)
    }

    fn fade_out(length: Time) -> KeyframeTemplate {
        let keys = [(Time::ZERO, 1.0, SegmentShape::Linear), (length, 0.0, SegmentShape::Linear)];
        template(vec![AnimationTrack::from_shapes("opacity", &keys)], length, AnimationAnchor::End)
    }

    fn set(i: Option<KeyframeTemplate>, o: Option<KeyframeTemplate>) -> AnimationSet {
        AnimationSet::new(i, o)
    }

    fn times(p: &AnimatedProperty<f64>) -> Vec<Time> {
        p.track.keys.iter().map(|k| k.time).collect()
    }

    fn v2(x: f64, y: f64) -> Vec2 {
        Vec2::new(x, y)
    }

    fn keyed(ids: &mut SequentialIds, keys: &[(Time, f64)]) -> KeyframeTrack<f64> {
        KeyframeTrack::with_keys(keys.iter().map(|(t, v)| Keyframe::new(ids.next_id(), *t, *v)).collect())
    }

    fn keyed2(ids: &mut SequentialIds, keys: &[(Time, Vec2)]) -> KeyframeTrack<Vec2> {
        KeyframeTrack::with_keys(keys.iter().map(|(t, v)| Keyframe::new(ids.next_id(), *t, *v)).collect())
    }

    #[test]
    fn off_is_no_animation_bit_for_bit() {
        let off = set(None, None);
        for t in [Time::ZERO, f() * 7, clip(), clip() + f()] {
            assert_eq!(off.sample(t, clip()), AnimationSample::REST);
            assert!(off.sample(t, clip()).is_rest());
        }
        assert!(AnimationSet::single(Some(&KeyframeTemplate::none())).is_none());
        assert!(AnimationSet::single(None).is_none());
        // A row that was read and written back without a key leaves Off as it was: the same bits.
        let mut s = off.clone();
        s.edit(AnimationParam::Scale, AnimationSide::Intro, clip(), |_| {});
        assert_eq!(s.sample(f() * 3, clip()), AnimationSample::REST);
        assert_eq!(s, off);
    }

    #[test]
    fn intro_and_outro_ranges_in_clip_time() {
        let mut ids = SequentialIds::default();
        let s = set(Some(fade_in(f() * 10)), Some(fade_out(f() * 6)));
        assert_eq!(s.offset(AnimationSide::Intro, clip()), Time::ZERO);
        assert_eq!(s.offset(AnimationSide::Outro, clip()), clip() - f() * 6);
        assert_eq!(times(&s.scalar(AnimationParam::Opacity, AnimationSide::Intro, clip())), vec![Time::ZERO, f() * 10]);
        assert_eq!(
            times(&s.scalar(AnimationParam::Opacity, AnimationSide::Outro, clip())),
            vec![clip() - f() * 6, clip()]
        );
        // A row nothing keys rests.
        let scale = s.scalar(AnimationParam::Scale, AnimationSide::Intro, clip());
        assert!(!scale.is_animated() && scale.value == 1.0);
        assert_eq!(s.position(AnimationSide::Outro, clip(), &mut ids).value, v2(0.0, 0.0));
    }

    #[test]
    fn values_at_both_ends() {
        let mut ids = SequentialIds::default();
        let mut s = set(None, None);
        let t1 = keyed(&mut ids, &[(Time::ZERO, 0.5), (f() * 12, 1.0)]);
        s.edit(AnimationParam::Scale, AnimationSide::Intro, clip(), |p| p.track = t1);
        let t2 = keyed(&mut ids, &[(clip() - f() * 9, 0.0), (clip(), 45.0)]);
        s.edit(AnimationParam::Rotation, AnimationSide::Outro, clip(), |p| p.track = t2);
        assert_eq!(s.animation_in.as_ref().map(|t| t.duration), Some(f() * 12));
        assert_eq!(s.animation_out.as_ref().map(|t| t.duration), Some(f() * 9));
        assert_eq!(s.animation_in.as_ref().map(|t| t.anchor), Some(AnimationAnchor::Start));
        assert_eq!(s.animation_out.as_ref().map(|t| t.anchor), Some(AnimationAnchor::End));
        assert_eq!(s.sample(Time::ZERO, clip()).scale, 0.5);
        assert_eq!(s.sample(f() * 12, clip()).scale, 1.0);
        assert_eq!(s.sample(f() * 40, clip()), AnimationSample::REST);
        assert_eq!(s.sample(clip() - f() * 9, clip()).rotation, 0.0);
        assert_eq!(s.sample(clip(), clip()).rotation, 45.0);
        assert!((s.sample(f() * 6, clip()).scale - 0.75).abs() < 1e-9);
    }

    #[test]
    fn moving_the_first_outro_key_keeps_every_clip_time() {
        let mut s = set(None, Some(fade_out(f() * 6)));
        let early = clip() - f() * 11;
        s.edit(AnimationParam::Opacity, AnimationSide::Outro, clip(), |p| {
            let first = p.track.keys[0].id;
            p.track.move_key(first, early);
        });
        assert_eq!(s.animation_out.as_ref().map(|t| t.duration), Some(f() * 11));
        assert_eq!(times(&s.scalar(AnimationParam::Opacity, AnimationSide::Outro, clip())), vec![early, clip()]);
        assert_eq!(s.sample(early, clip()).opacity, 1.0);
        assert_eq!(s.sample(clip(), clip()).opacity, 0.0);
        // And later again: the side gets shorter, the end stays at the clip's end.
        s.edit(AnimationParam::Opacity, AnimationSide::Outro, clip(), |p| {
            let first = p.track.keys[0].id;
            p.track.move_key(first, clip() - f() * 4);
        });
        assert_eq!(s.animation_out.as_ref().map(|t| t.duration), Some(f() * 4));
        assert_eq!(
            times(&s.scalar(AnimationParam::Opacity, AnimationSide::Outro, clip())),
            vec![clip() - f() * 4, clip()]
        );
    }

    #[test]
    fn intro_length_follows_its_last_key_and_an_empty_row_is_removed() {
        let mut s = set(Some(fade_in(f() * 10)), None);
        s.edit(AnimationParam::Opacity, AnimationSide::Intro, clip(), |p| {
            let last = p.track.keys[1].id;
            p.track.move_key(last, f() * 20);
        });
        assert_eq!(s.animation_in.as_ref().map(|t| t.duration), Some(f() * 20));
        s.edit(AnimationParam::Opacity, AnimationSide::Intro, clip(), |p| p.track = KeyframeTrack::default());
        assert!(s.animation_in.is_none()); // the last key gone: the side is Off again
        assert_eq!(s.sample(f() * 3, clip()), AnimationSample::REST);
    }

    #[test]
    fn position_is_one_row_over_two_tracks() {
        let mut ids = SequentialIds::default();
        let mut s = set(None, None);
        let t = keyed2(&mut ids, &[(Time::ZERO, v2(-40.0, 60.0)), (f() * 8, v2(0.0, 0.0))]);
        s.edit_position(AnimationSide::Intro, clip(), &mut ids, |p| p.track = t);
        let mut names: Vec<&str> =
            s.animation_in.as_ref().unwrap().tracks.iter().map(|t| t.property.as_str()).collect();
        names.sort_unstable();
        assert_eq!(names, vec!["positionX", "positionY"]);
        assert_eq!(s.sample(Time::ZERO, clip()).offset, v2(-40.0, 60.0));
        assert_eq!(s.sample(f() * 8, clip()).offset, v2(0.0, 0.0));
        let vals: Vec<Vec2> =
            s.position(AnimationSide::Intro, clip(), &mut ids).track.keys.iter().map(|k| k.value).collect();
        assert_eq!(vals, vec![v2(-40.0, 60.0), v2(0.0, 0.0)]);
        // The members never share key ids.
        let all: std::collections::BTreeSet<Id> =
            s.animation_in.as_ref().unwrap().tracks.iter().flat_map(|t| t.track().keys.iter().map(|k| k.id)).collect();
        assert_eq!(all.len(), 4);
    }

    #[test]
    fn clip_shorter_than_intro_plus_outro() {
        let short = f() * 12;
        let s = set(Some(fade_in(f() * 10)), Some(fade_out(f() * 6)));
        // The intro has priority: the outro starts when it ended and is cut by the clip's end.
        assert_eq!(s.out_start(short), Some(f() * 10));
        assert_eq!(times(&s.scalar(AnimationParam::Opacity, AnimationSide::Outro, short)), vec![f() * 10, f() * 16]);
        assert!((s.sample(f() * 5, short).opacity - 0.5).abs() < 1e-9);
        assert_eq!(s.sample(f() * 10, short).opacity, 1.0);
        // A clip no longer than the intro: the outro does not play, its row still shows it ending at the clip's end.
        let tiny = f() * 8;
        assert!(s.out_start(tiny).is_none());
        assert_eq!(s.offset(AnimationSide::Outro, tiny), tiny - f() * 6);
        assert!((s.sample(tiny, tiny).opacity - 0.8).abs() < 1e-9);
    }

    #[test]
    fn built_in_key_ids_are_unique_per_side_and_track() {
        let both = template(
            vec![
                AnimationTrack::from_shapes(
                    "opacity",
                    &[(Time::ZERO, 0.0, SegmentShape::Linear), (f() * 6, 1.0, SegmentShape::Linear)],
                ),
                AnimationTrack::from_shapes(
                    "scale",
                    &[(Time::ZERO, 0.8, SegmentShape::EaseOut), (f() * 6, 1.0, SegmentShape::Linear)],
                ),
            ],
            f() * 6,
            AnimationAnchor::Start,
        );
        let s = set(Some(both), Some(fade_out(f() * 6)));
        let collect = || -> Vec<Id> {
            [
                s.scalar(AnimationParam::Opacity, AnimationSide::Intro, clip()),
                s.scalar(AnimationParam::Scale, AnimationSide::Intro, clip()),
                s.scalar(AnimationParam::Opacity, AnimationSide::Outro, clip()),
            ]
            .iter()
            .flat_map(|p| p.track.keys.iter().map(|k| k.id))
            .collect()
        };
        let ids = collect();
        assert_eq!(ids.iter().collect::<std::collections::BTreeSet<_>>().len(), 6);
        assert_eq!(ids, collect());
    }

    #[test]
    fn custom_start_and_same_curves() {
        let mut n = SequentialIds::default();
        let a = KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n);
        let b = KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n);
        assert_ne!(a, b);
        assert!(a.same_curves(&b));
        assert!(a.same_curves(&fade_in(AnimationSet::CUSTOM_LENGTH)));
        assert!(!a.same_curves(&fade_in(f() * 6)));
        let out = KeyframeTemplate::custom_start(AnimationSide::Outro, &mut n);
        assert_eq!(out.anchor, AnimationAnchor::End);
        let s = set(Some(a), Some(out));
        assert_eq!(s.sample(Time::ZERO, clip()).opacity, 0.0);
        assert_eq!(s.sample(clip(), clip()).opacity, 0.0);
        assert_eq!(s.sample(f() * 45, clip()), AnimationSample::REST);
    }

    #[test]
    fn loop_survives_the_keystone_format() {
        let mut n = SequentialIds::default();
        let frame = v2(1080.0, 1920.0);
        let mut looping = KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n);
        looping.loops = true;
        let k = Keystone::from_animation(&looping, AnimationSide::Intro, "Loop", frame, &mut n).unwrap();
        assert_eq!(k.loops, Some(true));
        assert_eq!(k.animation_template(frame).map(|t| t.loops), Some(true));
        let payload = k.payload().unwrap();
        let again = Keystone::from_payload(&payload, k.written_payload_version()).unwrap();
        assert_eq!(again.animation_template(frame).map(|t| t.loops), Some(true));
        // Once stays once, and the field is absent from the payload (older saved keystones decode as before).
        let once_t = KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n);
        let once = Keystone::from_animation(&once_t, AnimationSide::Intro, "Once", frame, &mut n).unwrap();
        assert_eq!(once.loops, None);
        assert_eq!(once.animation_template(frame).map(|t| t.loops), Some(false));
        assert!(!String::from_utf8(once.payload().unwrap()).unwrap().contains("loops"));
        assert_eq!(k.written_payload_version(), 1);
    }

    #[test]
    fn saved_as_keystone_and_back() {
        let mut n = SequentialIds::default();
        let frame = v2(1080.0, 1920.0);
        let mut s = set(Some(KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n)), None);
        let t1 = keyed2(&mut n, &[(Time::ZERO, v2(-108.0, 192.0)), (f() * 10, v2(0.0, 0.0))]);
        s.edit_position(AnimationSide::Intro, clip(), &mut n, |p| p.track = t1);
        let t2 = keyed(&mut n, &[(Time::ZERO, 0.8), (f() * 10, 1.0)]);
        s.edit(AnimationParam::Scale, AnimationSide::Intro, clip(), |p| p.track = t2);
        let custom = s.animation_in.clone().unwrap();
        assert!(custom.has_own_key_ids());
        let k = Keystone::from_animation(&custom, AnimationSide::Intro, "Mine", frame, &mut n).unwrap();
        assert_eq!(k.anchor, KeystoneAnchor::ClipStart);
        assert_eq!(k.animation_side(), Some(AnimationSide::Intro));
        assert_eq!(k.duration, f() * 10);
        let want = [KeystoneProperty::Position, KeystoneProperty::Scale, KeystoneProperty::Opacity];
        assert_eq!(k.properties(), want.into_iter().collect());
        let first = k.position.as_ref().and_then(|p| p.keys.first()).map(|k| k.value).unwrap();
        assert!((first.x - -0.1).abs() < 1e-12 && (first.y - 0.1).abs() < 1e-12);
        let back = k.animation_template(frame).unwrap();
        assert!(!back.has_own_key_ids());
        assert_eq!(back.anchor, AnimationAnchor::Start);
        // Same picture at every time.
        let (a, b) = (set(Some(custom), None), set(Some(back.clone()), None));
        for t in [Time::ZERO, f(), f() * 3, f() * 5, f() * 9, f() * 10, f() * 12] {
            let (x, y) = (a.sample(t, clip()), b.sample(t, clip()));
            assert!((x.opacity - y.opacity).abs() < 1e-9 && (x.scale - y.scale).abs() < 1e-9);
            assert!((x.offset.x - y.offset.x).abs() < 1e-9 && (x.offset.y - y.offset.y).abs() < 1e-9);
        }
        // Read twice it is the same animation, also through the preset payload.
        assert_eq!(Some(back.clone()), k.animation_template(frame));
        let again = Keystone::from_payload(&k.payload().unwrap(), Keystone::PAYLOAD_VERSION).unwrap();
        assert_eq!(again.animation_template(frame), Some(back));
        // Nothing keyed, or a free keystone: nothing to save or play.
        let empty = template(Vec::new(), f() * 10, AnimationAnchor::Start);
        assert!(Keystone::from_animation(&empty, AnimationSide::Outro, "x", frame, &mut n).is_none());
        let mut free = Keystone::new(n.next_id(), "free", f() * 10, KeystoneAnchor::Free);
        free.opacity = k.opacity.clone();
        assert!(free.animation_template(frame).is_none());
        let out_t = KeyframeTemplate::custom_start(AnimationSide::Outro, &mut n);
        let out = Keystone::from_animation(&out_t, AnimationSide::Outro, "o", frame, &mut n);
        assert_eq!(out.and_then(|k| k.animation_template(frame)).map(|t| t.anchor), Some(AnimationAnchor::End));
    }

    #[test]
    fn presets_carry_no_own_key_ids() {
        let mut n = SequentialIds::default();
        let preset = fade_in(f() * 6);
        assert!(!preset.has_own_key_ids());
        assert!(preset.with_fresh_key_ids(&mut n).has_own_key_ids());
        // Reading a preset's rows and writing one back keeps it a preset as far as ids go.
        let mut s = set(Some(preset), None);
        s.edit(AnimationParam::Opacity, AnimationSide::Intro, clip(), |_| {});
        assert!(!s.animation_in.as_ref().is_some_and(|t| t.has_own_key_ids()));
    }

    /// Reading a preset's rows and writing them back unchanged leaves the preset bit for bit, on both sides and for a preset
    /// with one Position member only (no second track appears).
    #[test]
    fn an_unedited_preset_stays_what_it_was() {
        let mut n = SequentialIds::default();
        let rise = template(
            vec![
                AnimationTrack::from_shapes(
                    "opacity",
                    &[(Time::ZERO, 0.0, SegmentShape::Linear), (f() * 6, 1.0, SegmentShape::Linear)],
                ),
                AnimationTrack::from_shapes(
                    "positionY",
                    &[(Time::ZERO, 40.0, SegmentShape::EaseOut), (f() * 6, 0.0, SegmentShape::Linear)],
                ),
            ],
            f() * 6,
            AnimationAnchor::Start,
        );
        let mut out = rise.clone();
        out.anchor = AnimationAnchor::End;
        let original = set(Some(rise), Some(out));
        let mut s = original.clone();
        for side in AnimationSide::ALL {
            for p in AnimationParam::ALL.into_iter().filter(|p| *p != AnimationParam::Position) {
                s.edit(p, side, clip(), |_| {});
            }
            s.edit_position(side, clip(), &mut n, |_| {});
            s.edit_position(side, clip(), &mut n, |p| p.track = p.track.clone());
        }
        assert_eq!(s, original);
        // The ids the rows show for a preset are distinct per side and track, and still not "own" ids.
        let mut seen = std::collections::BTreeSet::new();
        let mut count = 0;
        for side in AnimationSide::ALL {
            for name in ["opacity", "positionY"] {
                for k in original.track(name, side, clip()).track.keys {
                    seen.insert(k.id);
                    count += 1;
                    assert!(k.id.as_u128() >> 80 == 0, "an own id");
                }
            }
        }
        assert_eq!(seen.len(), count);
        // A Custom intro is read as stored: the same ids, the same times.
        let custom = set(Some(KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n)), None);
        let stored = custom.animation_in.as_ref().and_then(|t| t.track_for("opacity")).map(|t| t.track().clone());
        assert_eq!(Some(custom.track("opacity", AnimationSide::Intro, clip()).track), stored);
    }

    /// A saved animation is the same in every sequence format: Position scales with the frame, nothing else may differ.
    #[test]
    fn same_shape_ignores_the_frame_and_key_ids() {
        let mut n = SequentialIds::default();
        let mut s = set(Some(KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n)), None);
        let t1 = keyed2(&mut n, &[(Time::ZERO, v2(-120.0, 300.0)), (f() * 10, v2(0.0, 0.0))]);
        s.edit_position(AnimationSide::Intro, clip(), &mut n, |p| p.track = t1);
        let t = s.animation_in.clone().unwrap();
        let k = Keystone::from_animation(&t, AnimationSide::Intro, "Mine", v2(1080.0, 1920.0), &mut n).unwrap();
        let tall = k.animation_template(v2(1080.0, 1920.0)).unwrap();
        let wide = k.animation_template(v2(3840.0, 2160.0)).unwrap();
        assert!(!tall.has_own_key_ids());
        assert_ne!(tall, wide);
        assert!(tall.same_shape(&wide) && wide.same_shape(&tall) && t.same_shape(&wide));
        let edit_first = |t: &KeyframeTemplate, name: &str, f: &dyn Fn(f64) -> f64| {
            let mut c = t.clone();
            let i = c.tracks.iter().position(|x| x.property == name).unwrap();
            let mut keys = c.tracks[i].track().keys.clone();
            keys[0].value = f(keys[0].value);
            c.tracks[i].set_track(KeyframeTrack::with_keys(keys));
            c
        };
        assert!(!tall.same_shape(&edit_first(&wide, "opacity", &|v| v + 0.25))); // Opacity is not a matter of the frame
        assert!(!tall.same_shape(&edit_first(&wide, "positionX", &|v| -v))); // the other direction is another animation
        let mut later = wide.clone();
        later.duration += f();
        assert!(!tall.same_shape(&later));
    }

    #[test]
    fn codable_round_trip_of_a_custom_set() {
        let mut n = SequentialIds::default();
        let mut s = set(Some(KeyframeTemplate::custom_start(AnimationSide::Intro, &mut n)), None);
        let t = keyed2(&mut n, &[(clip() - f() * 5, v2(0.0, 0.0)), (clip(), v2(0.0, 30.0))]);
        s.edit_position(AnimationSide::Outro, clip(), &mut n, |p| p.track = t);
        let back: AnimationSet = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
        assert_eq!(back, s);
    }

    /// A keystone's own curve replaces the shape of every key of the side it plays; without one the keys stay as stored.
    #[test]
    fn keystone_easing_shapes_the_animation_template() {
        let mut n = SequentialIds::default();
        let frame = v2(1080.0, 1920.0);
        let mut k = Keystone::new(n.next_id(), "Fade", Time::new(1, 2), KeystoneAnchor::ClipStart);
        k.opacity = Some(keyed(&mut n, &[(Time::ZERO, 0.0), (Time::new(1, 2), 1.0)]));
        let keys_of = |k: &Keystone| {
            k.animation_template(frame).and_then(|t| t.track_for("opacity").map(|x| x.track().keys.clone())).unwrap()
        };
        let plain = keys_of(&k);
        assert!(plain.iter().all(|x| x.interpolation == Interpolation::Linear));
        k.easing = Some(EasingCurve::fast_start());
        let eased = keys_of(&k);
        assert!(eased.iter().all(|x| x.interpolation == Interpolation::Bezier));
        let c = EasingCurve::fast_start();
        assert_eq!(eased[0].out_handle, c.out_handle);
        assert_eq!(eased[1].in_handle, c.in_handle);
        assert_eq!(eased.iter().map(|x| x.time).collect::<Vec<_>>(), plain.iter().map(|x| x.time).collect::<Vec<_>>());
        assert_eq!(
            eased.iter().map(|x| x.value).collect::<Vec<_>>(),
            plain.iter().map(|x| x.value).collect::<Vec<_>>()
        );
    }
}
