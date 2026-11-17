// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesGraph.swift (ported by task M-3)

use serde::{Deserialize, Serialize};
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{EaseHandle, Id, KeyframeTrack, KeyframeValue, Time};

/// One point of a value graph.
#[derive(Clone, Debug, PartialEq)]
pub struct ValueSample<V> {
    /// Seconds (output only).
    pub time: f64,
    /// The value there.
    pub value: V,
}

/// One point of a speed graph.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpeedSample {
    /// Seconds.
    pub time: f64,
    /// Value units per second (vectors: magnitude).
    pub speed: f64,
}

/// The samples of one segment of a value graph.
#[derive(Clone, Debug, PartialEq)]
pub struct ValueGraphSegment<V> {
    /// Left key.
    pub from_id: Id,
    /// Right key.
    pub to_id: Id,
    /// Points from the left to the right key.
    pub samples: Vec<ValueSample<V>>,
}

/// The samples of one segment of a speed graph.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedGraphSegment {
    /// Left key.
    pub from_id: Id,
    /// Right key.
    pub to_id: Id,
    /// Points from the left to the right key.
    pub samples: Vec<SpeedSample>,
}

/// Graph sampling of a track.
pub trait KeyframeGraph<V> {
    /// One entry per segment, `n` points each (min 2) from the left key to the right key.
    fn value_graph(&self, n: usize) -> Vec<ValueGraphSegment<V>>;

    /// Speed = dv/dt in value units per second (central differences on the evaluated segment).
    fn speed_graph(&self, n: usize) -> Vec<SpeedGraphSegment>;
}

impl<V: KeyframeValue> KeyframeGraph<V> for KeyframeTrack<V> {
    fn value_graph(&self, n: usize) -> Vec<ValueGraphSegment<V>> {
        let n = n.max(2);
        self.keys
            .windows(2)
            .map(|w| {
                let (a, b) = (&w[0], &w[1]);
                let t0 = keyframe_math::seconds(a.time);
                let d = keyframe_math::seconds(b.time) - t0;
                let samples = (0..n)
                    .map(|i| {
                        let tn = i as f64 / (n - 1) as f64;
                        let value = if i == n - 1 { b.value.clone() } else { KeyframeTrack::segment_value(a, b, tn) };
                        ValueSample { time: t0 + tn * d, value }
                    })
                    .collect();
                ValueGraphSegment { from_id: a.id, to_id: b.id, samples }
            })
            .collect()
    }

    fn speed_graph(&self, n: usize) -> Vec<SpeedGraphSegment> {
        let n = n.max(2);
        self.keys
            .windows(2)
            .map(|w| {
                let (a, b) = (&w[0], &w[1]);
                let t0 = keyframe_math::seconds(a.time);
                let d = keyframe_math::seconds(b.time) - t0;
                let h = 1e-4;
                let samples = (0..n)
                    .map(|i| {
                        let tn = i as f64 / (n - 1) as f64;
                        if a.interpolation.is_hold() {
                            // A step has no speed.
                            return SpeedSample { time: t0 + tn * d, speed: 0.0 };
                        }
                        let (lo, hi) = ((tn - h).max(0.0), (tn + h).min(1.0));
                        let dv =
                            V::minus(&KeyframeTrack::segment_value(a, b, hi), &KeyframeTrack::segment_value(a, b, lo));
                        SpeedSample { time: t0 + tn * d, speed: dv.speed_magnitude() / ((hi - lo) * d) }
                    })
                    .collect();
                SpeedGraphSegment { from_id: a.id, to_id: b.id, samples }
            })
            .collect()
    }
}

/// After-Effects style handle: value units per second and time influence (0...1).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct SpeedHandle {
    /// Value units per second.
    pub speed: f64,
    /// Time influence 0...1.
    pub influence: f64,
}

/// Conversion of an `EaseHandle` to After-Effects style numbers.
pub trait EaseHandleSpeed {
    /// `value_delta` = |right value - left value| (signed for scalars), `duration` = segment length.
    fn speed_handle(&self, value_delta: f64, duration: Time) -> SpeedHandle;
}

impl EaseHandleSpeed for EaseHandle {
    fn speed_handle(&self, value_delta: f64, duration: Time) -> SpeedHandle {
        if self.dx <= 0.0 {
            return SpeedHandle { speed: 0.0, influence: self.dx };
        }
        let secs = keyframe_math::seconds(duration);
        SpeedHandle { speed: self.dy / self.dx * value_delta / secs, influence: self.dx }
    }
}

/// The ease handle for an After-Effects style handle (Swift `EaseHandle(speedHandle:valueDelta:duration:)`).
pub fn ease_handle_from_speed_handle(h: SpeedHandle, value_delta: f64, duration: Time) -> EaseHandle {
    let secs = keyframe_math::seconds(duration);
    let linear_speed = value_delta / secs;
    let slope = if linear_speed == 0.0 { 0.0 } else { h.speed / linear_speed };
    EaseHandle { dx: h.influence, dy: slope * h.influence }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{key, t};

    #[test]
    fn value_graph_runs_from_key_to_key_and_speed_is_steady_on_a_line() {
        let tr = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 2, 10.0)]);
        let g = tr.value_graph(5);
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].samples.len(), 5);
        assert_eq!(g[0].samples[0].value, 0.0);
        assert_eq!(g[0].samples[4].value, 10.0);
        assert_eq!(g[0].samples[2].time, 1.0);
        let s = tr.speed_graph(1);
        assert_eq!(s[0].samples.len(), 2);
        assert!(s[0].samples.iter().all(|p| (p.speed - 5.0).abs() < 1e-6));
    }

    #[test]
    fn a_hold_segment_has_zero_speed() {
        let mut a = key(1, 0, 0.0);
        a.interpolation = sq_core_time::Interpolation::Hold;
        let tr = KeyframeTrack::with_keys(vec![a, key(2, 1, 5.0)]);
        assert!(tr.speed_graph(4)[0].samples.iter().all(|p| p.speed == 0.0));
    }

    #[test]
    fn speed_handle_round_trips() {
        let h = EaseHandle { dx: 0.4, dy: 0.2 };
        let sh = h.speed_handle(10.0, t(2));
        assert_eq!(sh.influence, 0.4);
        let back = ease_handle_from_speed_handle(sh, 10.0, t(2));
        assert!((back.dx - h.dx).abs() < 1e-12 && (back.dy - h.dy).abs() < 1e-12);
        assert_eq!(
            EaseHandle { dx: 0.0, dy: 1.0 }.speed_handle(10.0, t(2)),
            SpeedHandle { speed: 0.0, influence: 0.0 }
        );
    }
}
