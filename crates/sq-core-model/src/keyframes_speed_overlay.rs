// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesSpeedOverlay.swift (ported by task M-3)

use crate::keyframes_editing::{KeyframeSummary, PropertyTrack, SummaryMember, by_property};
use crate::keyframes_graph::{KeyframeGraph, SpeedGraphSegment, SpeedSample};
use crate::keyframes_hue::HueUnwrap;
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{EaseHandle, Id, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, SpatialPath, Vec2};
use std::collections::BTreeSet;

// Graph Editor (After Effects style, speed graph only, DECISIONS 2026-10-03): the keyframed properties of a clip are
// overlaid in one speed graph. Units differ per property, so every curve is "directed speed" (along the direction of
// its segment: a falling opacity still reads as positive speed) and carries its own `peak`, which the view maps to the
// graph height. Handles keep the old model: an `EaseHandle` per side (influence dx, slope dy/dx relative to the
// segment's average speed), so applying one dragged handle to several keys gives them the same influence and the same
// relative speed, whatever their units.

/// Side of a key's speed handle.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeySide {
    /// Arriving from the previous key.
    Incoming,
    /// Leaving to the next key.
    Outgoing,
}

/// A key on a Graph Editor curve.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedOverlayKey {
    /// Key id.
    pub id: Id,
    /// Key time in seconds.
    pub seconds: f64,
    /// Outgoing speed (arriving speed for the last key), directed; 0 on a Hold segment.
    pub speed: f64,
    /// The key's interpolation.
    pub interpolation: Interpolation,
}

/// A speed handle on a Graph Editor curve.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedOverlayHandle {
    /// The key it belongs to.
    pub key_id: Id,
    /// Which side of the key.
    pub side: KeySide,
    /// Time influence 0...1 (`EaseHandle::dx`).
    pub influence: f64,
    /// Directed speed at the key on this side, units per second.
    pub speed: f64,
    /// Distance the segment covers (|delta|, or the path length of a Position segment).
    pub span: f64,
    /// Length of the segment in seconds.
    pub segment_seconds: f64,
}

/// One property's curve in the Graph Editor.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedOverlayCurve {
    /// Directed speed samples per segment.
    pub segments: Vec<SpeedGraphSegment>,
    /// The keys.
    pub keys: Vec<SpeedOverlayKey>,
    /// Handles of every key side that has a non-Hold segment.
    pub handles: Vec<SpeedOverlayHandle>,
    /// Largest |speed| of samples and handles; at least a tiny positive number.
    pub peak: f64,
}

impl SpeedOverlayCurve {
    /// A property without motion: no keys, speed 0 everywhere (drawn as a flat line on the zero line).
    pub fn still() -> SpeedOverlayCurve {
        SpeedOverlayCurve { segments: Vec::new(), keys: Vec::new(), handles: Vec::new(), peak: 1e-9 }
    }
}

/// Handle from a speed-graph position: `directed_speed` in units per second along the segment (negative =
/// backwards), `span` the distance the segment covers, `seconds` its length. Influence is kept inside 0.01...1.
/// (Swift `EaseHandle(directedSpeed:influence:span:seconds:)`.)
pub fn ease_handle_from_directed_speed(directed_speed: f64, influence: f64, span: f64, seconds: f64) -> EaseHandle {
    let dx = influence.clamp(0.01, 1.0);
    let average = if seconds > 0.0 { span / seconds } else { 0.0 };
    let slope = if average > 1e-12 { directed_speed / average } else { 0.0 };
    EaseHandle { dx, dy: slope * dx }
}

/// Speed overlay of a track.
#[doc(hidden)]
pub trait KeyframeTrackOverlay<V> {
    /// Speed curve for the overlay. `span` gives a segment's covered distance, `sign` its direction (+1 / -1) for
    /// signed (scalar) samples.
    fn speed_overlay(
        &self,
        samples: usize,
        span: impl Fn(&Keyframe<V>, &Keyframe<V>) -> f64,
        sign: impl Fn(&Keyframe<V>, &Keyframe<V>) -> f64,
    ) -> SpeedOverlayCurve;

    /// Sets `handle` on `side` of the given keys (skipping sides without a segment or with a Hold segment). Linear
    /// keys become Bezier. Returns the number of keys changed.
    fn set_handle(&mut self, handle: EaseHandle, side: KeySide, on: &BTreeSet<Id>) -> usize;
}

impl<V: KeyframeValue> KeyframeTrackOverlay<V> for KeyframeTrack<V> {
    fn speed_overlay(
        &self,
        samples: usize,
        span: impl Fn(&Keyframe<V>, &Keyframe<V>) -> f64,
        sign: impl Fn(&Keyframe<V>, &Keyframe<V>) -> f64,
    ) -> SpeedOverlayCurve {
        let raw = self.speed_graph(samples);
        let mut segments = Vec::new();
        let mut handles = Vec::new();
        let mut peak = 0.0_f64;
        for (i, seg) in raw.iter().enumerate() {
            let (a, b) = (&self.keys[i], &self.keys[i + 1]);
            let s = if a.interpolation.is_hold() { 1.0 } else { sign(a, b) };
            let directed = SpeedGraphSegment {
                from_id: seg.from_id,
                to_id: seg.to_id,
                samples: seg.samples.iter().map(|x| SpeedSample { time: x.time, speed: x.speed * s }).collect(),
            };
            for x in &directed.samples {
                peak = peak.max(x.speed.abs());
            }
            segments.push(directed);
            if a.interpolation.is_hold() {
                continue;
            }
            let secs = keyframe_math::seconds(b.time - a.time);
            let d = span(a, b);
            let speed = |h: EaseHandle| if h.dx > 0.0 && secs > 0.0 { h.dy / h.dx * d / secs } else { 0.0 };
            handles.push(SpeedOverlayHandle {
                key_id: a.id,
                side: KeySide::Outgoing,
                influence: a.out_handle.dx,
                speed: speed(a.out_handle),
                span: d,
                segment_seconds: secs,
            });
            handles.push(SpeedOverlayHandle {
                key_id: b.id,
                side: KeySide::Incoming,
                influence: b.in_handle.dx,
                speed: speed(b.in_handle),
                span: d,
                segment_seconds: secs,
            });
        }
        for h in &handles {
            peak = peak.max(h.speed.abs());
        }
        let keyed = self
            .keys
            .iter()
            .enumerate()
            .map(|(i, k)| {
                let mut v = 0.0;
                if i < segments.len() {
                    v = segments[i].samples.first().map_or(0.0, |s| s.speed);
                } else if i > 0 && i - 1 < segments.len() {
                    v = segments[i - 1].samples.last().map_or(0.0, |s| s.speed);
                }
                SpeedOverlayKey {
                    id: k.id,
                    seconds: keyframe_math::seconds(k.time),
                    speed: v,
                    interpolation: k.interpolation,
                }
            })
            .collect();
        SpeedOverlayCurve { segments, keys: keyed, handles, peak: peak.max(1e-9) }
    }

    fn set_handle(&mut self, handle: EaseHandle, side: KeySide, on: &BTreeSet<Id>) -> usize {
        self.edit_keys(|keys| {
            let mut n = 0;
            for i in 0..keys.len() {
                if !on.contains(&keys[i].id) {
                    continue;
                }
                match side {
                    KeySide::Outgoing => {
                        if i + 1 >= keys.len() || keys[i].interpolation.is_hold() {
                            continue;
                        }
                        keys[i].out_handle = handle;
                    }
                    KeySide::Incoming => {
                        if i == 0 || keys[i - 1].interpolation.is_hold() {
                            continue;
                        }
                        keys[i].in_handle = handle;
                    }
                }
                if keys[i].interpolation == Interpolation::Linear {
                    keys[i].interpolation = Interpolation::Bezier;
                }
                n += 1;
            }
            n
        })
    }
}

impl PropertyTrack {
    /// The property's curve in the Graph Editor; `None` for colors and paths (no speed to show).
    /// `hue`: the track is a hue in degrees; segments run the short way round the circle (350 -> 10 is a 20 degree
    /// step through 0), so span, direction and speed follow the picture, not the straight difference of the keys.
    pub fn speed_overlay(&self, samples: usize, hue: bool) -> Option<SpeedOverlayCurve> {
        match self {
            PropertyTrack::Scalar(t0) => {
                let t = if hue { t0.hue_unwrapped() } else { t0.clone() };
                Some(t.speed_overlay(
                    samples,
                    |a, b| (b.value - a.value).abs(),
                    |a, b| if b.value < a.value { -1.0 } else { 1.0 },
                ))
            }
            PropertyTrack::Vector(t) => Some(t.speed_overlay(
                samples,
                |a, b| {
                    if a.out_tangent == Vec2::ZERO && b.in_tangent == Vec2::ZERO {
                        return (b.value - a.value).length();
                    }
                    SpatialPath::new(
                        a.value,
                        a.value + a.out_tangent,
                        b.value + b.in_tangent,
                        b.value,
                        SpatialPath::DEFAULT_RESOLUTION,
                    )
                    .length()
                },
                |_, _| 1.0,
            )),
            PropertyTrack::Color(_) | PropertyTrack::Path(_) => None,
        }
    }

    /// See `KeyframeTrackOverlay::set_handle`; colors and paths have no speed handles.
    #[doc(hidden)]
    pub fn set_handle(&mut self, handle: EaseHandle, side: KeySide, on: &BTreeSet<Id>) -> usize {
        match self {
            PropertyTrack::Scalar(t) => t.set_handle(handle, side, on),
            PropertyTrack::Vector(t) => t.set_handle(handle, side, on),
            PropertyTrack::Color(_) | PropertyTrack::Path(_) => 0,
        }
    }
}

impl KeyframeSummary {
    /// Graph Editor handle drag on several keys at once: every member gets `handle` on `side`, i.e. the same
    /// influence and the same speed relative to its own segment. Returns the number of keys changed.
    pub fn set_handle(&mut self, handle: EaseHandle, side: KeySide, on: &BTreeSet<SummaryMember>) -> usize {
        let mut n = 0;
        for (p, ids) in by_property(on) {
            if let Some(t) = self.tracks.get_mut(&p) {
                n += t.set_handle(handle, side, &ids);
            }
        }
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{id, key, scalar, t};
    use sq_core_time::Vec2;
    use std::collections::BTreeMap;

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    fn kind(mut k: Keyframe<f64>, i: Interpolation) -> Keyframe<f64> {
        k.interpolation = i;
        k
    }

    #[test]
    fn linear_scalar_is_directed_and_peaked() {
        // 0 -> 10 in 2 s (5/s), then 10 -> 0 in 1 s (10/s, falling: still positive in the overlay).
        let tr = scalar(vec![key(1, 0, 0.0), key(2, 2, 10.0), key(3, 3, 0.0)]);
        let c = tr.speed_overlay(5, false).expect("curve");
        assert_eq!(c.segments.len(), 2);
        assert!(c.segments[0].samples.iter().all(|s| near(s.speed, 5.0, 1e-4)));
        assert!(c.segments[1].samples.iter().all(|s| near(s.speed, 10.0, 1e-4)));
        assert!(near(c.peak, 10.0, 1e-4));
        assert_eq!(c.keys.iter().map(|k| k.seconds).collect::<Vec<_>>(), vec![0.0, 2.0, 3.0]);
        // A key sits at its outgoing speed, the last key at its arriving speed.
        assert!(
            near(c.keys[0].speed, 5.0, 1e-4) && near(c.keys[1].speed, 10.0, 1e-4) && near(c.keys[2].speed, 10.0, 1e-4)
        );
    }

    #[test]
    fn handles_of_eased_keys() {
        let mut a = kind(key(1, 0, 0.0), Interpolation::Bezier);
        a.out_handle = EaseHandle { dx: 1.0 / 3.0, dy: 0.0 };
        let mut b = kind(key(2, 2, 10.0), Interpolation::Bezier);
        b.in_handle = EaseHandle { dx: 0.5, dy: 0.5 };
        let c = scalar(vec![a, b]).speed_overlay(48, false).expect("curve");
        assert_eq!(c.handles.len(), 2);
        let out = c.handles.iter().find(|h| h.key_id == id(1)).expect("out handle");
        assert!(out.side == KeySide::Outgoing && near(out.influence, 1.0 / 3.0, 1e-9) && out.speed.abs() < 1e-9);
        assert!(out.span == 10.0 && out.segment_seconds == 2.0);
        let inn = c.handles.iter().find(|h| h.key_id == id(2)).expect("in handle");
        // Slope 1 = the average speed.
        assert!(inn.side == KeySide::Incoming && near(inn.speed, 5.0, 1e-9));
    }

    #[test]
    fn hold_has_no_handles_and_zero_speed_but_a_height() {
        let c = scalar(vec![kind(key(1, 0, 0.0), Interpolation::Hold), key(2, 2, 10.0)])
            .speed_overlay(48, false)
            .expect("curve");
        assert!(c.handles.is_empty());
        assert_eq!(c.keys[0].speed, 0.0);
        assert!(c.peak > 0.0);
    }

    #[test]
    fn vector_uses_path_speed_and_colors_have_no_curve() {
        let v = PropertyTrack::Vector(KeyframeTrack::with_keys(vec![
            Keyframe::new(id(1), t(0), Vec2::ZERO),
            Keyframe::new(id(2), t(1), Vec2::new(3.0, 4.0)),
        ]));
        let c = v.speed_overlay(3, false).expect("curve");
        assert!(c.segments[0].samples.iter().all(|s| near(s.speed, 5.0, 1e-4)));
        assert!(c.handles.iter().all(|h| near(h.span, 5.0, 1e-9)));
        assert!(PropertyTrack::Color(KeyframeTrack::new()).speed_overlay(48, false).is_none());
        let one = scalar(vec![key(1, 0, 3.0)]).speed_overlay(48, false).expect("curve");
        assert!(one.segments.is_empty() && one.keys.len() == 1);
        assert_eq!(SpeedOverlayCurve::still().peak, 1e-9);
    }

    #[test]
    fn hue_overlay_follows_the_short_arc() {
        let c = scalar(vec![key(1, 0, 350.0), key(2, 2, 10.0)]).speed_overlay(3, true).expect("curve");
        // 20 degrees in 2 s.
        assert!(c.segments[0].samples.iter().all(|s| near(s.speed, 10.0, 1e-4)));
    }

    #[test]
    fn ease_handle_from_directed_speed_keeps_influence_inside_its_range() {
        // Average speed 5/s; asking for 10/s at influence 0.25 gives slope 2.
        let h = ease_handle_from_directed_speed(10.0, 0.25, 10.0, 2.0);
        assert!(near(h.dx, 0.25, 1e-12) && near(h.dy, 0.5, 1e-12));
        assert_eq!(ease_handle_from_directed_speed(0.0, 0.4, 10.0, 2.0), EaseHandle { dx: 0.4, dy: 0.0 });
        assert_eq!(ease_handle_from_directed_speed(3.0, 2.0, 10.0, 2.0).dx, 1.0);
        assert_eq!(ease_handle_from_directed_speed(3.0, 0.0, 10.0, 2.0).dx, 0.01);
        assert_eq!(ease_handle_from_directed_speed(3.0, 0.3, 0.0, 2.0).dy, 0.0);
    }

    #[test]
    fn summary_set_handle_on_several_properties() {
        let mut s = KeyframeSummary::new(BTreeMap::from([
            ("opacity".into(), scalar(vec![key(1, 0, 0.0), key(2, 2, 1.0)])),
            (
                "position".into(),
                PropertyTrack::Vector(KeyframeTrack::with_keys(vec![
                    Keyframe::new(id(11), t(0), Vec2::ZERO),
                    Keyframe::new(id(12), t(4), Vec2::new(10.0, 0.0)),
                ])),
            ),
        ]));
        let smooth = EaseHandle { dx: 1.0 / 3.0, dy: 0.0 };
        // The last key has no out side.
        let on: BTreeSet<_> = [("opacity", 1), ("position", 11), ("position", 12)]
            .iter()
            .map(|(p, n)| SummaryMember::new((*p).into(), id(*n)))
            .collect();
        assert_eq!(s.set_handle(smooth, KeySide::Outgoing, &on), 2);
        let Some(PropertyTrack::Scalar(ot)) = s.tracks.get(&"opacity".into()) else { panic!("opacity") };
        let Some(PropertyTrack::Vector(pt)) = s.tracks.get(&"position".into()) else { panic!("position") };
        assert!(ot.keys[0].out_handle == smooth && ot.keys[0].interpolation == Interpolation::Bezier);
        assert!(pt.keys[0].out_handle == smooth && pt.keys[0].interpolation == Interpolation::Bezier);
        assert!(pt.keys[1].out_handle == EaseHandle::LINEAR && pt.keys[1].interpolation == Interpolation::Linear);
    }

    #[test]
    fn incoming_skips_hold_segments() {
        let (a, b, c) = (kind(key(1, 0, 0.0), Interpolation::Hold), key(2, 2, 5.0), key(3, 4, 9.0));
        let mut s = KeyframeSummary::new(BTreeMap::from([("opacity".into(), scalar(vec![a, b, c]))]));
        let h = EaseHandle { dx: 0.5, dy: 0.0 };
        // Segment a-b is hold; the first key has no in side.
        let on: BTreeSet<_> = [2, 3, 1].iter().map(|n| SummaryMember::new("opacity".into(), id(*n))).collect();
        assert_eq!(s.set_handle(h, KeySide::Incoming, &on), 1);
        let Some(PropertyTrack::Scalar(tr)) = s.tracks.get(&"opacity".into()) else { panic!("opacity") };
        assert_eq!(tr.keys[1].in_handle, EaseHandle::LINEAR);
        assert!(tr.keys[2].in_handle == h && tr.keys[2].interpolation == Interpolation::Bezier);
    }
}
