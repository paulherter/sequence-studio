// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnchoredAnimation.swift
//! W7.3 AnimationStackUnify: the one animation model. Clip keyframes (`AnimatedProperty`, `ClipEffect` parameters) and
//! anchored in/out animations (text clips, Caption Looks, text templates) are both `KeyframeTrack`s evaluated by
//! `KeyframeTrack::value`; this module adds the anchoring (in = clip start, out = clip end, never scaled) and the
//! `AnimationSample` every renderer folds into its layer. On-disk shape unchanged: project files v26-v28 decode to the
//! same values.

mod text_animator;

pub use text_animator::{
    TextAnimator, TextAnimatorEffect, TextAnimatorOrder, TextAnimatorUnit, TextCursor, TextSlideDirection,
};

use serde::{Deserialize, Serialize};
use sq_core_time::{EaseHandle, Id, Interpolation, Keyframe, KeyframeTrack, Time, Vec2};
use std::fmt;

/// Shape of one keyframe segment, expressed as interpolation plus bezier handles.
/// Overshoot is a bezier whose handle leaves 0...1 (`dy > 1`); hold is `Interpolation::Hold`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SegmentShape {
    /// Straight.
    Linear,
    /// Slow start.
    EaseIn,
    /// Slow arrival.
    EaseOut,
    /// Slow at both ends.
    EaseInOut,
    /// Ease-out that passes the end value and settles back (back-out, cubic-bezier 0.34, 1.56, 0.64, 1).
    Overshoot,
    /// Keeps the start value until the next key.
    Hold,
}

impl SegmentShape {
    /// The key interpolation of this shape.
    pub fn interpolation(self) -> Interpolation {
        match self {
            SegmentShape::Linear => Interpolation::Linear,
            SegmentShape::Hold => Interpolation::Hold,
            _ => Interpolation::Bezier,
        }
    }

    /// (outgoing handle of the segment's first key, incoming handle of its second key).
    pub fn handles(self) -> (EaseHandle, EaseHandle) {
        let h = |dx: f64, dy: f64| EaseHandle { dx, dy };
        match self {
            SegmentShape::Linear | SegmentShape::Hold => (EaseHandle::LINEAR, EaseHandle::LINEAR),
            SegmentShape::EaseIn => (h(1.0 / 3.0, 0.0), h(1.0 / 3.0, 1.0)),
            SegmentShape::EaseOut => (h(1.0 / 3.0, 1.0), h(1.0 / 3.0, 0.0)),
            SegmentShape::EaseInOut => (h(1.0 / 3.0, 0.0), h(1.0 / 3.0, 0.0)),
            SegmentShape::Overshoot => (h(0.34, 1.56), h(0.36, 0.0)),
        }
    }
}

/// One animated property (e.g. "scale", "opacity", "positionX", "positionY", "rotation") as a track.
/// Key times are template-local: 0 = start of the animation, `KeyframeTemplate::duration` = its end.
/// A Hold Ahead key is stored as Hold: these tracks are saved inside text payloads, templates and Caption Looks, which
/// the project version gate does not see.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "AnimationTrackWire")]
pub struct AnimationTrack {
    /// Which property.
    pub property: String,
    track: KeyframeTrack<f64>,
}

/// The coded shape of `AnimationTrack`; reading goes through `AnimationTrack::new` (old payloads' Hold Ahead folds).
#[derive(Deserialize)]
struct AnimationTrackWire {
    property: String,
    track: KeyframeTrack<f64>,
}

impl From<AnimationTrackWire> for AnimationTrack {
    fn from(w: AnimationTrackWire) -> Self {
        AnimationTrack::new(w.property, w.track)
    }
}

impl AnimationTrack {
    /// A track; Hold Ahead keys become Hold.
    pub fn new(property: String, track: KeyframeTrack<f64>) -> AnimationTrack {
        let mut t = AnimationTrack { property, track };
        t.plain_holds();
        t
    }

    /// The keys.
    pub fn track(&self) -> &KeyframeTrack<f64> {
        &self.track
    }

    /// Replaces the keys (Swift `didSet`: Hold Ahead becomes Hold).
    pub fn set_track(&mut self, track: KeyframeTrack<f64>) {
        self.track = track;
        self.plain_holds();
    }

    fn plain_holds(&mut self) {
        for k in &mut self.track.keys {
            if k.interpolation == Interpolation::HoldAhead {
                k.interpolation = Interpolation::Hold;
            }
        }
    }

    /// Builds a track from (time, value, shape of the segment starting at that key). Key ids are deterministic
    /// (by index) so built-in templates compare and encode stably.
    pub fn from_shapes(property: &str, keys: &[(Time, f64, SegmentShape)]) -> AnimationTrack {
        let mut ks: Vec<Keyframe<f64>> = keys
            .iter()
            .enumerate()
            .map(|(i, &(time, value, shape))| {
                let mut k = Keyframe::new(Self::key_id(i), time, value);
                k.interpolation = shape.interpolation();
                k.out_handle = shape.handles().0;
                k
            })
            .collect();
        for i in 1..ks.len() {
            ks[i].in_handle = keys[i - 1].2.handles().1;
        }
        AnimationTrack::new(property.to_string(), KeyframeTrack::with_keys(ks))
    }

    /// `00000000-0000-0000-0000-%012d` for key `i` + 1.
    pub fn key_id(i: usize) -> Id {
        Id::fixed(i as u64 + 1)
    }

    /// `None` for an empty track; clamped to the first/last value outside the keyed range.
    pub fn value_at(&self, t: Time) -> Option<f64> {
        self.track.value(t)
    }
}

/// What a template's local time 0 is measured from when it is played on a clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AnimationAnchor {
    /// In-animation: template-local time t plays at clip time t.
    Start,
    /// Out-animation: template-local 0...duration plays at clip time (clipDuration - duration)...clipDuration.
    End,
}

/// Errors from decoding old template formats.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyframeTemplateError {
    /// A v1 key time (duration * fraction) does not fit the Int64 rational.
    TimeOverflow,
}

impl fmt::Display for KeyframeTemplateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("timeOverflow")
    }
}

impl std::error::Error for KeyframeTemplateError {}

fn is_false(b: &bool) -> bool {
    !*b
}

/// Reusable animation: property tracks over template-local time plus a default playback length.
///
/// `anchor` decides how the template is placed on a clip (see `AnimationAnchor`, `resolved`); durations are never
/// scaled to the clip.
///
/// On-disk shape (TextTemplate format v3): `{"anchor": "start"|"end", "duration": Time, "tracks": [{"property",
/// "track": {"keys": [...]}}]}`. `anchor` is absent in v1/v2 files and then reads as `Start`. Decoding also reads the
/// v1 shape (normalized `Fraction` times, `easing` enum), converting key times to `duration * fraction` and easings to
/// handles.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", try_from = "KeyframeTemplateWire")]
pub struct KeyframeTemplate {
    /// The animated properties.
    pub tracks: Vec<AnimationTrack>,
    /// Default playback length of the animation (rational timeline time).
    pub duration: Time,
    /// Where template time 0 sits on a clip.
    pub anchor: AnimationAnchor,
    /// Per character/word/line animation (TextAnimator); plays alongside the property tracks, which move the whole
    /// block. Absent in older files; written only when set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text_animator: Option<TextAnimator>,
    /// True: after `duration` the animation starts over for as long as the clip plays (wave, hop, pulse). The last key
    /// should equal the first so the cycle is seamless. Only meaningful for `Start` templates. Absent in older files;
    /// written only when true.
    #[serde(skip_serializing_if = "is_false")]
    pub loops: bool,
}

/// The coded shape of `KeyframeTemplate`; `tracks` is read as the current form first, then as the v1 form.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyframeTemplateWire {
    duration: Time,
    #[serde(default)]
    anchor: Option<AnimationAnchor>,
    #[serde(default)]
    text_animator: Option<TextAnimator>,
    #[serde(default)]
    loops: Option<bool>,
    tracks: serde_json::Value,
}

impl TryFrom<KeyframeTemplateWire> for KeyframeTemplate {
    type Error = String;
    fn try_from(w: KeyframeTemplateWire) -> Result<Self, String> {
        let tracks = match serde_json::from_value::<Vec<AnimationTrack>>(w.tracks.clone()) {
            Ok(v2) => v2,
            Err(_) => {
                let legacy: Vec<LegacyTrack> = serde_json::from_value(w.tracks).map_err(|e| e.to_string())?;
                legacy
                    .iter()
                    .map(|t| t.migrated(w.duration))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?
            }
        };
        Ok(KeyframeTemplate {
            tracks,
            duration: w.duration,
            anchor: w.anchor.unwrap_or(AnimationAnchor::Start),
            text_animator: w.text_animator,
            loops: w.loops.unwrap_or(false),
        })
    }
}

impl KeyframeTemplate {
    /// No tracks, no length: nothing to play.
    pub fn none() -> KeyframeTemplate {
        KeyframeTemplate {
            tracks: Vec::new(),
            duration: Time::ZERO,
            anchor: AnimationAnchor::Start,
            text_animator: None,
            loops: false,
        }
    }

    /// The track of `property`.
    pub fn track_for(&self, property: &str) -> Option<&AnimationTrack> {
        self.tracks.iter().find(|t| t.property == property)
    }

    /// Value of `property` at template-local time `t`; `None` if the property has no keys.
    /// A looping template repeats every `duration` from template time 0 on (earlier times clamp as usual).
    pub fn value_of(&self, property: &str, t: Time) -> Option<f64> {
        self.track_for(property)?.value_at(if self.loops { Self::wrap(t, self.duration) } else { t })
    }

    /// `t` modulo `period` as an exact rational. Negative `t` and a non-positive period are returned unchanged.
    pub fn wrap(t: Time, period: Time) -> Time {
        if period <= Time::ZERO || t < period {
            return t;
        }
        // t = a/b, period = c/d  ->  (a*d mod c*b) / (b*d)
        let (a, b) = (i128::from(t.value()), i128::from(t.timescale()));
        let (c, d) = (i128::from(period.value()), i128::from(period.timescale()));
        let mut num = (a * d) % (c * b);
        let mut den = b * d;
        let (mut x, mut y) = (num.unsigned_abs(), den.unsigned_abs());
        while y != 0 {
            (x, y) = (y, x % y);
        }
        if x > 1 {
            num /= x as i128;
            den /= x as i128;
        }
        if let (Ok(n), Ok(m)) = (i64::try_from(num), i64::try_from(den)) {
            return Time::new(n, m);
        }
        let r = (t.value() as f64 / t.timescale() as f64) % (period.value() as f64 / period.timescale() as f64);
        // shortcut: a rounded nanosecond fallback for an exact result beyond Int64, as in Swift; only pathological times.
        Time::new((r * 1e9).round() as i64, 1_000_000_000)
    }

    /// Clip time at which template-local time 0 plays (may be negative when the clip is shorter than an end-anchored
    /// animation: the first part of the animation is then simply never seen).
    pub fn start_offset(&self, clip_duration: Time) -> Time {
        if self.anchor == AnimationAnchor::Start { Time::ZERO } else { clip_duration - self.duration }
    }

    /// Value of `property` at clip time `clip_time`. Exact (no key rewriting). Before the animation it holds the first
    /// key's value, after it the last key's value; `None` if the property has no keys.
    pub fn value_of_clip_time(&self, property: &str, clip_time: Time, clip_duration: Time) -> Option<f64> {
        self.value_of(property, clip_time - self.start_offset(clip_duration))
    }

    /// The tracks with key times moved to clip-local time (`start_offset` added).
    ///
    /// Clamping: keys are kept inside `0...clip_duration`. When the animation does not fit (clip shorter than the
    /// animation, or a non-positive clip), keys outside the range are dropped and replaced by boundary keys at 0 /
    /// `clip_duration` carrying the exact value there; curve handles of a cut bezier segment are then only
    /// approximated. For a non-positive clip duration each track collapses to one key at 0 (value at clip time 0). Use
    /// `value_of_clip_time` for exact evaluation.
    pub fn resolved(&self, clip_duration: Time) -> Vec<AnimationTrack> {
        let offset = self.start_offset(clip_duration);
        let (lo, hi) = (Time::ZERO, clip_duration.max(Time::ZERO));
        self.tracks
            .iter()
            .map(|t| AnimationTrack::new(t.property.clone(), Self::place(&t.track, offset, lo, hi)))
            .collect()
    }

    fn place(track: &KeyframeTrack<f64>, offset: Time, lo: Time, hi: Time) -> KeyframeTrack<f64> {
        let (Some(first), Some(last)) = (track.keys.first(), track.keys.last()) else { return track.clone() };
        let boundary =
            |t: Time, like: &Keyframe<f64>| Keyframe::new(like.id, t, track.value(t - offset).unwrap_or(like.value));
        let mut out: Vec<Keyframe<f64>> = Vec::new();
        // Later wins on identical times, so the order makes the lower boundary win for an empty range.
        if last.time + offset > hi {
            out.push(boundary(hi, last));
        }
        out.extend(
            track
                .keys
                .iter()
                .map(|k| {
                    let mut c = k.clone();
                    c.time = k.time + offset;
                    c
                })
                .filter(|k| k.time >= lo && k.time <= hi),
        );
        if first.time + offset < lo {
            out.push(boundary(lo, first));
        }
        KeyframeTrack::with_keys(out)
    }

    /// Copy with template-local key times scaled by `new_duration / duration` (exact rational arithmetic; results
    /// beyond Int64 are approximated/clamped, never trap; key ids, values, shapes and anchor unchanged). For
    /// authoring/editing ("make this animation longer"), never used by anchored playback: playing a template on a clip
    /// does not scale it (see `resolved`).
    ///
    /// Degenerate cases: a negative `new_duration` is treated as zero; with zero target all keys collapse to time 0
    /// (per track the last key wins); a zero source duration has no scale, so key times stay as they are.
    pub fn retimed(&self, new_duration: Time) -> KeyframeTemplate {
        let target = new_duration.max(Time::ZERO);
        let mut copy = self.clone();
        copy.duration = target;
        if self.duration <= Time::ZERO || target == self.duration {
            return copy;
        }
        copy.tracks = self
            .tracks
            .iter()
            .map(|track| {
                let scaled = KeyframeTrack::with_keys(
                    track
                        .track
                        .keys
                        .iter()
                        .map(|k| {
                            let mut c = k.clone();
                            c.time = Self::scale(k.time, self.duration, target);
                            c
                        })
                        .collect(),
                );
                AnimationTrack::new(track.property.clone(), scaled)
            })
            .collect();
        copy
    }

    /// t * to / from as a reduced rational, exact whenever the i128 intermediates do not overflow and the reduced
    /// result fits Int64. Otherwise (pathological inputs only) it falls back to a Double ratio at nanosecond
    /// resolution, and a value beyond +-Int64.max seconds is clamped. Never traps.
    fn scale(t: Time, from: Time, to: Time) -> Time {
        let n1 = i128::from(t.value()) * i128::from(to.value());
        let d1 = i128::from(t.timescale()) * i128::from(to.timescale());
        let (n2, o1) = n1.overflowing_mul(i128::from(from.timescale()));
        let (d2, o2) = d1.overflowing_mul(i128::from(from.value()));
        if !o1 && !o2 {
            let (mut num, mut den) = (n2, d2);
            let (mut a, mut b) = (num.unsigned_abs(), den.unsigned_abs());
            while b != 0 {
                (a, b) = (b, a % b);
            }
            if a > 1 {
                num /= a as i128;
                den /= a as i128;
            }
            if let (Ok(n), Ok(d)) = (i64::try_from(num), i64::try_from(den)) {
                return Time::new(n, d);
            }
        }
        let secs = |x: Time| x.value() as f64 / x.timescale() as f64;
        let r = secs(t) * secs(to) / secs(from);
        let limit = i64::MAX as f64 / 2.0;
        if r.is_nan() || r.abs() >= limit {
            return Time::new(if r < 0.0 { -i64::MAX } else { i64::MAX }, 1);
        }
        if r.abs() < limit / 1e9 {
            return Time::new((r * 1e9).round() as i64, 1_000_000_000);
        }
        Time::new(r.round() as i64, 1)
    }
}

/// Format v1: normalized Fraction times + Easing enum.
#[derive(Deserialize)]
struct LegacyTrack {
    property: String,
    keyframes: Vec<LegacyKey>,
}

#[derive(Deserialize)]
struct LegacyKey {
    time: LegacyFraction,
    value: f64,
    easing: SegmentShape,
}

#[derive(Deserialize)]
struct LegacyFraction {
    numerator: i64,
    denominator: i64,
}

impl LegacyTrack {
    /// time = duration * fraction; with a zero duration the fraction is read as seconds (nothing else is meaningful).
    /// Fails with `TimeOverflow` if a key time does not fit Int64 after the multiplication.
    fn migrated(&self, duration: Time) -> Result<AnimationTrack, KeyframeTemplateError> {
        let keys = self
            .keyframes
            .iter()
            .map(|k| {
                let d = k.time.denominator.max(1);
                if duration == Time::ZERO {
                    return Ok((Time::new(k.time.numerator, d), k.value, k.easing));
                }
                let v = duration.value().checked_mul(k.time.numerator).ok_or(KeyframeTemplateError::TimeOverflow)?;
                let s = duration.timescale().checked_mul(d).ok_or(KeyframeTemplateError::TimeOverflow)?;
                Ok((Time::new(v, s), k.value, k.easing))
            })
            .collect::<Result<Vec<_>, KeyframeTemplateError>>()?;
        Ok(AnimationTrack::from_shapes(&self.property, &keys))
    }
}

/// An in-animation (start-anchored) plus an out-animation (end-anchored) on one clip.
///
/// Both sides are optional. The anchors of the passed templates are overridden (`in` -> `Start`, `out` -> `End`).
/// Crossing policy: the in-animation has priority. The out-animation starts at `clip_duration - out.duration`, but
/// never before the in-animation ended; if that leaves no room (in-animation as long as the clip or longer) the
/// out-animation does not play at all. When it is pushed later it is cut by the clip end (not scaled).
/// Per property, while the out-animation plays its value wins if it animates that property, else the in-animation's
/// (clamped) value applies.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnimationSet {
    /// The in-animation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub animation_in: Option<KeyframeTemplate>,
    /// The out-animation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub animation_out: Option<KeyframeTemplate>,
}

impl KeyframeTemplate {
    /// A side's template: the preset's tracks (none for `none`) plus the text animator; `None` when both are empty.
    pub fn combined_with_animator(
        preset: Option<&KeyframeTemplate>,
        animator: Option<TextAnimator>,
        anchor: AnimationAnchor,
    ) -> Option<KeyframeTemplate> {
        let mut t = preset.filter(|p| !p.tracks.is_empty()).cloned();
        if t.is_none() && animator.is_some() {
            t = Some(KeyframeTemplate {
                tracks: Vec::new(),
                duration: Time::ZERO,
                anchor,
                text_animator: None,
                loops: false,
            });
        }
        if let Some(t) = t.as_mut() {
            t.text_animator = animator;
            t.anchor = anchor;
        }
        t
    }
}

impl AnimationSet {
    /// The text animator of a side (`intro` = in, else out).
    pub fn text_animator(&self, intro: bool) -> Option<&TextAnimator> {
        let t = if intro { self.animation_in.as_ref() } else { self.animation_out.as_ref() };
        t?.text_animator.as_ref()
    }

    /// Sets or clears the text animator of a side, keeping the side's property tracks; an empty template is dropped. The
    /// one place the Text panel and the Edit API change an animator.
    pub fn set_text_animator(&mut self, intro: bool, animator: Option<TextAnimator>) {
        let anchor = if intro { AnimationAnchor::Start } else { AnimationAnchor::End };
        let cur = if intro { self.animation_in.as_ref() } else { self.animation_out.as_ref() };
        let t = KeyframeTemplate::combined_with_animator(cur, animator, anchor);
        if intro {
            self.animation_in = t;
        } else {
            self.animation_out = t;
        }
    }

    /// A set; the templates' anchors are forced to their side.
    pub fn new(animation_in: Option<KeyframeTemplate>, animation_out: Option<KeyframeTemplate>) -> AnimationSet {
        AnimationSet {
            animation_in: animation_in.map(|mut a| {
                a.anchor = AnimationAnchor::Start;
                a
            }),
            animation_out: animation_out.map(|mut a| {
                a.anchor = AnimationAnchor::End;
                a
            }),
        }
    }

    /// One template played by its own anchor (start = in, end = out), as text templates and Caption Looks carry it.
    /// `None` for `None` or `none()` (nothing to play).
    pub fn single(template: Option<&KeyframeTemplate>) -> Option<AnimationSet> {
        let template = template.filter(|t| **t != KeyframeTemplate::none())?;
        Some(if template.anchor == AnimationAnchor::Start {
            AnimationSet::new(Some(template.clone()), None)
        } else {
            AnimationSet::new(None, Some(template.clone()))
        })
    }

    /// Clip time where the out-animation starts; `None` if there is none or it does not play (see type docs).
    pub fn out_start(&self, clip_duration: Time) -> Option<Time> {
        let out = self.animation_out.as_ref()?;
        let in_duration = self.animation_in.as_ref().map_or(Time::ZERO, |a| a.duration);
        let start = (clip_duration - out.duration).max(in_duration).max(Time::ZERO);
        if start < clip_duration { Some(start) } else { None }
    }

    /// Value of `property` at clip time `clip_time`: the out-animation's while it plays, else the in-animation's.
    pub fn value_of(&self, property: &str, clip_time: Time, clip_duration: Time) -> Option<f64> {
        let in_value = self.animation_in.as_ref().and_then(|a| a.value_of(property, clip_time));
        let Some(out) = self.animation_out.as_ref() else { return in_value };
        let Some(start) = self.out_start(clip_duration) else { return in_value };
        let out_value = out.value_of(property, clip_time - start);
        if clip_time >= start { out_value.or(in_value) } else { in_value.or(out_value) }
    }

    /// The block-level animation at clip time `clip_time`: the properties "opacity" (clamped to 0...1), "scale",
    /// "positionX"/"positionY" (sequence px, y down) and "rotation" (degrees), each at rest where no side animates it.
    pub fn sample(&self, clip_time: Time, clip_duration: Time) -> AnimationSample {
        let v = |p: &str, d: f64| self.value_of(p, clip_time, clip_duration).unwrap_or(d);
        AnimationSample {
            opacity: v("opacity", 1.0).clamp(0.0, 1.0),
            scale: v("scale", 1.0),
            offset: Vec2::new(v("positionX", 0.0), v("positionY", 0.0)),
            rotation: v("rotation", 0.0),
        }
    }
}

/// An anchored animation evaluated at one instant (`AnimationSet::sample`). The renderer folds it into its layer:
/// opacity multiplies, scale and rotation act about the block center, `offset` moves it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnimationSample {
    /// 0...1.
    pub opacity: f64,
    /// Linear, not clamped (an overshoot may pass 1; consumers clamp at 0 where they need to).
    pub scale: f64,
    /// Offset in sequence px.
    pub offset: Vec2,
    /// Degrees, clockwise on screen.
    pub rotation: f64,
}

impl AnimationSample {
    /// Nothing animates.
    pub const REST: AnimationSample = AnimationSample { opacity: 1.0, scale: 1.0, offset: Vec2::ZERO, rotation: 0.0 };

    /// Equal to `REST`.
    pub fn is_rest(&self) -> bool {
        *self == Self::REST
    }
}

impl Default for AnimationSample {
    fn default() -> Self {
        Self::REST
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SegmentShape::*;
    use serde_json::json;

    type Row<'a> = (&'a str, &'a [(Time, f64, SegmentShape)]);

    fn tracks(rows: &[Row]) -> Vec<AnimationTrack> {
        rows.iter().map(|(p, k)| AnimationTrack::from_shapes(p, k)).collect()
    }

    fn template(tr: Vec<AnimationTrack>, duration: Time, anchor: AnimationAnchor) -> KeyframeTemplate {
        KeyframeTemplate { tracks: tr, duration, anchor, text_animator: None, loops: false }
    }

    fn pop_in() -> KeyframeTemplate {
        template(
            tracks(&[
                ("scale", &[(Time::ZERO, 0.8, Overshoot), (Time::new(1, 4), 1.0, Linear)]),
                ("opacity", &[(Time::ZERO, 0.0, EaseOut), (Time::new(1, 8), 1.0, Linear)]),
            ]),
            Time::new(1, 4),
            AnimationAnchor::Start,
        )
    }

    fn slide_out() -> KeyframeTemplate {
        let half = Time::new(1, 2);
        template(
            tracks(&[
                ("positionX", &[(Time::ZERO, 0.0, Linear), (half, 300.0, Linear)]),
                ("positionY", &[(Time::ZERO, 0.0, Linear), (half, -50.0, Linear)]),
                ("rotation", &[(Time::ZERO, 0.0, Linear), (half, 30.0, Linear)]),
                ("opacity", &[(Time::ZERO, 1.0, Linear), (half, -1.0, Linear)]),
            ]),
            half,
            AnimationAnchor::End,
        )
    }

    fn wave(loops: bool) -> KeyframeTemplate {
        let mut t = template(
            tracks(&[(
                "positionY",
                &[
                    (Time::ZERO, 0.0, EaseInOut),
                    (Time::new(1, 4), -14.0, EaseInOut),
                    (Time::new(3, 4), 14.0, EaseInOut),
                    (Time::new(1, 1), 0.0, Linear),
                ],
            )]),
            Time::new(1, 1),
            AnimationAnchor::Start,
        );
        t.loops = loops;
        t
    }

    #[test]
    fn single_template_picks_the_side_by_anchor() {
        assert_eq!(AnimationSet::single(Some(&pop_in())), Some(AnimationSet::new(Some(pop_in()), None)));
        assert_eq!(AnimationSet::single(Some(&slide_out())), Some(AnimationSet::new(None, Some(slide_out()))));
        assert_eq!(AnimationSet::single(Some(&KeyframeTemplate::none())), None);
        assert_eq!(AnimationSet::single(None), None);
        // An animator-only template is not "none".
        let mut animator = KeyframeTemplate::none();
        animator.text_animator = Some(TextAnimator::new(
            TextAnimatorEffect::Fade,
            TextAnimatorUnit::Word,
            Time::new(1, 2),
            Time::new(1, 10),
        ));
        assert_eq!(AnimationSet::single(Some(&animator)), Some(AnimationSet::new(Some(animator.clone()), None)));
    }

    #[test]
    fn sample_equals_the_per_property_values() {
        let set = AnimationSet::new(Some(pop_in()), Some(slide_out()));
        let d = Time::new(2, 1);
        for n in 0..=60 {
            let t = Time::new(n, 30);
            let s = set.sample(t, d);
            let v = |p: &str, def: f64| set.value_of(p, t, d).unwrap_or(def);
            assert_eq!(s.opacity, v("opacity", 1.0).clamp(0.0, 1.0));
            assert_eq!(s.scale, v("scale", 1.0));
            assert_eq!(s.offset, Vec2::new(v("positionX", 0.0), v("positionY", 0.0)));
            assert_eq!(s.rotation, v("rotation", 0.0));
        }
    }

    #[test]
    fn empty_set_samples_to_rest() {
        let s = AnimationSet::new(None, None).sample(Time::new(1, 1), Time::new(2, 1));
        assert_eq!(s, AnimationSample::REST);
        assert!(s.is_rest());
    }

    #[test]
    fn out_side_ends_hidden_and_clamps_opacity() {
        let set = AnimationSet::new(None, Some(slide_out()));
        let end = set.sample(Time::new(2, 1), Time::new(2, 1));
        assert_eq!(end.opacity, 0.0); // -1 clamps to 0
        assert!(end.offset == Vec2::new(300.0, -50.0) && end.rotation == 30.0);
        assert_eq!(set.sample(Time::new(1, 1), Time::new(2, 1)), AnimationSample::REST);
    }

    #[test]
    fn the_out_animation_never_starts_before_the_in_animation_ended() {
        let set = AnimationSet::new(Some(pop_in()), Some(slide_out()));
        assert_eq!(set.out_start(Time::new(2, 1)), Some(Time::new(3, 2)));
        assert_eq!(set.out_start(Time::new(1, 2)), Some(Time::new(1, 4))); // pushed behind the in-animation
        assert_eq!(set.out_start(Time::new(1, 4)), None); // no room: it does not play
    }

    #[test]
    fn wrap_is_exact_rational() {
        let p = Time::new(2, 3);
        assert_eq!(KeyframeTemplate::wrap(Time::new(1, 3), p), Time::new(1, 3));
        assert_eq!(KeyframeTemplate::wrap(Time::new(2, 3), p), Time::ZERO);
        assert_eq!(KeyframeTemplate::wrap(Time::new(5, 3), p), Time::new(1, 3));
        assert_eq!(
            KeyframeTemplate::wrap(Time::new(1001, 30000) * 90, Time::new(1, 1)),
            Time::new(90 * 1001 - 3 * 30000, 30000)
        );
    }

    #[test]
    fn wrap_leaves_negative_and_degenerate_alone() {
        assert_eq!(KeyframeTemplate::wrap(Time::new(-1, 5), Time::new(1, 1)), Time::new(-1, 5));
        assert_eq!(KeyframeTemplate::wrap(Time::new(7, 5), Time::ZERO), Time::new(7, 5));
    }

    #[test]
    fn looping_template_repeats_and_plain_one_clamps() {
        let (t, plain) = (wave(true), wave(false));
        let probe = Time::new(1, 7);
        let a = t.value_of("positionY", probe).unwrap_or(f64::NAN);
        for n in [1, 2, 5] {
            let b = t.value_of("positionY", probe + t.duration * n).unwrap_or(f64::NAN);
            assert!((b - a).abs() < 1e-9);
        }
        assert_eq!(plain.value_of("positionY", plain.duration * 10), Some(0.0));
    }

    #[test]
    fn loops_are_optional_on_disk_and_written_only_when_true() {
        let old = json!({"anchor": "start", "duration": {"value": 1, "timescale": 2}, "tracks": []});
        let read: KeyframeTemplate = serde_json::from_value(old).unwrap_or_else(|e| panic!("{e}"));
        assert!(!read.loops);
        assert!(serde_json::to_value(wave(false)).unwrap_or_default().get("loops").is_none());
        let on = wave(true);
        let back: KeyframeTemplate =
            serde_json::from_value(serde_json::to_value(&on).unwrap_or_default()).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(back, on);
    }

    #[test]
    fn animation_set_plays_loops_past_the_cycle() {
        let set = AnimationSet::new(Some(wave(true)), None);
        let clip = Time::new(10, 1);
        let early = set.value_of("positionY", Time::new(1, 8), clip).unwrap_or(f64::NAN);
        let late = set.value_of("positionY", Time::new(1, 8) + Time::new(3, 1), clip).unwrap_or(f64::NAN);
        assert!((early - late).abs() < 1e-9);
    }

    #[test]
    fn version_1_templates_migrate_fractions_and_easings() {
        let v1 = json!({"duration": {"value": 1, "timescale": 2}, "tracks": [{"property": "opacity",
            "keyframes": [{"time": {"numerator": 0, "denominator": 1}, "value": 0.0, "easing": "easeOut"},
                          {"time": {"numerator": 1, "denominator": 1}, "value": 1.0, "easing": "linear"}]}]});
        let t: KeyframeTemplate = serde_json::from_value(v1).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(t.anchor, AnimationAnchor::Start);
        let keys = &t.tracks[0].track().keys;
        assert_eq!((keys[0].time, keys[1].time), (Time::ZERO, Time::new(1, 2)));
        assert_eq!(keys[0].interpolation, Interpolation::Bezier);
        assert_eq!(keys[0].id, AnimationTrack::key_id(0));
        let huge = json!({"duration": {"value": i64::MAX, "timescale": 1}, "tracks": [{"property": "p",
            "keyframes": [{"time": {"numerator": 2, "denominator": 1}, "value": 0.0, "easing": "linear"}]}]});
        assert!(serde_json::from_value::<KeyframeTemplate>(huge).is_err());
    }

    #[test]
    fn hold_ahead_keys_read_and_set_as_hold() {
        let wire = json!({"property": "p", "track": {"keys": [{"id": "00000000-0000-0000-0000-000000000001",
            "time": {"value": 0, "timescale": 1}, "value": 1.0, "interpolation": "holdAhead"}]}});
        let t: AnimationTrack = serde_json::from_value(wire).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(t.track().keys[0].interpolation, Interpolation::Hold);
        let mut k = Keyframe::new(Id::from_u128(1), Time::ZERO, 0.0);
        k.interpolation = Interpolation::HoldAhead;
        let mut t = t;
        t.set_track(KeyframeTrack::with_keys(vec![k]));
        assert_eq!(t.track().keys[0].interpolation, Interpolation::Hold);
    }

    #[test]
    fn resolved_places_end_anchored_keys_at_the_clip_end() {
        let out = slide_out();
        for clip in [Time::new(1, 1), Time::new(60, 1)] {
            assert_eq!(out.resolved(clip)[0].track().keys.first().map(|k| k.time), Some(clip - out.duration));
        }
        // A clip shorter than the animation: boundary keys carry the exact value there.
        let short = out.resolved(Time::new(1, 4));
        assert_eq!(short[0].track().keys.last().map(|k| k.time), Some(Time::new(1, 4)));
        assert_eq!(
            short[0].track().keys.last().map(|k| k.value),
            Some(out.value_of("positionX", Time::new(1, 2)).unwrap_or(f64::NAN))
        );
        let none = out.resolved(Time::new(-1, 1));
        assert!(none.iter().all(|t| t.track().keys.len() == 1 && t.track().keys[0].time == Time::ZERO));
    }

    #[test]
    fn retime_scales_key_times_exactly() {
        let odd = template(
            tracks(&[(
                "p",
                &[(Time::ZERO, 0.0, Linear), (Time::new(1, 3), 1.0, Linear), (Time::new(1, 1), 2.0, Linear)],
            )]),
            Time::new(1, 1),
            AnimationAnchor::Start,
        )
        .retimed(Time::new(3, 7));
        let times: Vec<Time> = odd.tracks[0].track().keys.iter().map(|k| k.time).collect();
        assert_eq!(times, vec![Time::ZERO, Time::new(1, 7), Time::new(3, 7)]);
        let p = pop_in();
        assert_eq!(p.retimed(p.duration), p);
        assert_eq!(p.retimed(Time::new(3, 4)).retimed(p.duration), p);
    }

    #[test]
    fn retime_degenerate_targets() {
        let p = pop_in();
        let r = p.retimed(Time::ZERO);
        assert_eq!(r.duration, Time::ZERO);
        assert!(r.tracks.iter().all(|t| t.track().keys.len() == 1 && t.track().keys[0].time == Time::ZERO));
        assert_eq!(r.value_of("opacity", Time::ZERO), Some(1.0)); // collapsed to the final key
        assert_eq!(p.retimed(Time::new(-1, 2)).duration, Time::ZERO);
        let none = KeyframeTemplate::none().retimed(Time::new(1, 2));
        assert!(none.duration == Time::new(1, 2) && none.tracks.is_empty());
        let flat = template(tracks(&[("p", &[(Time::ZERO, 4.0, Hold)])]), Time::ZERO, AnimationAnchor::Start)
            .retimed(Time::new(1, 2));
        assert_eq!(flat.duration, Time::new(1, 2));
        assert_eq!(flat.track_for("p").map(|t| t.track().keys.len()), Some(1));
    }

    #[test]
    fn extreme_retime_never_traps() {
        let big = i64::MAX - 1;
        let t = template(
            tracks(&[("opacity", &[(Time::new(1, 1), 1.0, Linear)])]),
            Time::new(1, 1_000_000_000),
            AnimationAnchor::Start,
        );
        let r = t.retimed(Time::new(big, 1));
        assert_eq!(r.track_for("opacity").map(|t| t.track().keys[0].time), Some(Time::new(i64::MAX, 1)));
        let r2 = template(
            tracks(&[("opacity", &[(Time::new(big, 3), 1.0, Linear)])]),
            Time::new(big, 7),
            AnimationAnchor::Start,
        )
        .retimed(Time::new(big - 2, 11));
        assert!(r2.tracks[0].track().keys[0].time > Time::ZERO);
    }
}
