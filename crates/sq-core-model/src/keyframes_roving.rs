// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesRoving.swift (ported by task M-3)

use crate::keyframes_editing::{PropertyTrack, each_track};
use sq_core_time::{EaseHandle, Id, KeyframeTrack, KeyframeValue, SpatialPath, Time, Vec2};
use std::collections::BTreeSet;

/// Roving keys on a position track.
pub trait RovingKeys {
    /// Roving keys: the selected keys between two fixed keys (the first and last key always stay fixed) are moved in
    /// time so the position travels at one steady speed along the path from one fixed key to the next. Values and
    /// tangents stay; only times change. Returns false when no interior selected key moved.
    fn rove(&mut self, ids: &BTreeSet<Id>) -> bool;
}

impl RovingKeys for KeyframeTrack<Vec2> {
    fn rove(&mut self, ids: &BTreeSet<Id>) -> bool {
        let n = self.keys.len();
        if n < 3 {
            return false;
        }
        let mut moved = false;
        let mut anchor = 0;
        for i in 1..n {
            let is_fixed = i == n - 1 || !ids.contains(&self.keys[i].id);
            if !is_fixed {
                continue;
            }
            if i - anchor > 1 {
                moved = rove_between(self, anchor, i) || moved;
            }
            anchor = i;
        }
        moved
    }
}

fn rove_between(track: &mut KeyframeTrack<Vec2>, a: usize, b: usize) -> bool {
    let keys = &mut track.keys;
    let mut cumulative = vec![0.0];
    for i in a..b {
        let p = SpatialPath::new(
            keys[i].value,
            keys[i].value + keys[i].out_tangent,
            keys[i + 1].value + keys[i + 1].in_tangent,
            keys[i + 1].value,
            SpatialPath::DEFAULT_RESOLUTION,
        );
        cumulative.push(cumulative[cumulative.len() - 1] + p.length());
    }
    let total = cumulative[cumulative.len() - 1];
    if total <= 1e-9 {
        return false;
    }
    let t0 = keys[a].time;
    let span = keys[b].time - t0;
    let mut changed = false;
    for i in (a + 1)..b {
        // Saturating `as` stands in for Swift's trap on a non-finite path length.
        let n = (cumulative[i - a] / total * 1_000_000.0).round() as i64;
        let t = t0 + Time::scaled_int(span, n, 1_000_000);
        if t != keys[i].time {
            keys[i].time = t;
            changed = true;
        }
    }
    changed
}

/// Time scale of selected keys.
pub trait KeyTimeScaling {
    /// Scales the time distance of the selected keys from `pivot` by `num / den` (> 0), as the Graph Editor's time
    /// scale. A scaled key landing on an unselected key replaces it. False when nothing moved.
    fn scale_times(&mut self, ids: &BTreeSet<Id>, num: i64, den: i64, pivot: Time) -> bool;
}

impl<V: KeyframeValue> KeyTimeScaling for KeyframeTrack<V> {
    fn scale_times(&mut self, ids: &BTreeSet<Id>, num: i64, den: i64, pivot: Time) -> bool {
        if num <= 0 || den <= 0 || num == den || !self.keys.iter().any(|k| ids.contains(&k.id)) {
            return false;
        }
        self.edit_keys(|list| {
            for k in list.iter_mut().filter(|k| ids.contains(&k.id)) {
                k.time = pivot + Time::scaled_int(k.time - pivot, num, den);
            }
        });
        true
    }
}

impl PropertyTrack {
    /// `KeyTimeScaling::scale_times` for any value type.
    pub fn scale_times(&mut self, ids: &BTreeSet<Id>, num: i64, den: i64, pivot: Time) -> bool {
        each_track!(self, t => t.scale_times(ids, num, den, pivot))
    }
}

/// The numbers of the Keyframe Velocity dialog: speed (units per second) and influence (0...1 of the segment's
/// reach) of one handle, against the segment's average speed. Pure conversion to and from the stored `EaseHandle`.
pub struct KeyVelocity;

impl KeyVelocity {
    /// Smallest influence.
    pub const MIN_INFLUENCE: f64 = 0.01;

    /// `(speed, influence)` of a handle.
    pub fn numbers(h: EaseHandle, average_speed: f64) -> (f64, f64) {
        let influence = h.dx.clamp(Self::MIN_INFLUENCE, 1.0);
        (h.dy / influence * average_speed, influence)
    }

    /// `None` when the segment has no average speed to scale against (a Hold, or two equal values).
    pub fn handle(speed: f64, influence: f64, average_speed: f64) -> Option<EaseHandle> {
        if !average_speed.is_finite() || average_speed.abs() <= 1e-12 || !speed.is_finite() || !influence.is_finite() {
            return None;
        }
        let inf = influence.clamp(Self::MIN_INFLUENCE, 1.0);
        Some(EaseHandle { dx: inf, dy: speed / average_speed * inf })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{id, key, t};
    use sq_core_time::Keyframe;

    fn pos(n: u128, s: i64, x: f64) -> Keyframe<Vec2> {
        Keyframe::new(id(n), t(s), Vec2::new(x, 0.0))
    }

    #[test]
    fn rove_spreads_selected_keys_evenly_along_the_path() {
        // Distances 1 and 3 over a 4 s span: the middle key moves to 1 s.
        let mut tr = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0), pos(2, 3, 1.0), pos(3, 4, 4.0)]);
        assert!(tr.rove(&BTreeSet::from([id(2)])));
        assert_eq!(tr.keys[1].time, t(1));
        assert!(!tr.rove(&BTreeSet::from([id(2)])));
        // First and last stay fixed; fewer than three keys do nothing.
        assert!(!tr.rove(&BTreeSet::from([id(1), id(3)])));
        let mut two = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0), pos(2, 3, 1.0)]);
        assert!(!two.rove(&BTreeSet::from([id(2)])));
    }

    #[test]
    fn scale_times_stretches_selected_keys_from_the_pivot() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 2, 0.0), key(2, 4, 1.0), key(3, 6, 2.0)]);
        assert!(tr.scale_times(&BTreeSet::from([id(2), id(3)]), 2, 1, t(2)));
        assert_eq!(tr.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(2), t(6), t(10)]);
        assert!(!tr.scale_times(&BTreeSet::from([id(2)]), 1, 1, t(2)));
        assert!(!tr.scale_times(&BTreeSet::from([id(2)]), 0, 1, t(2)));
        assert!(!tr.scale_times(&BTreeSet::from([id(9)]), 2, 1, t(2)));
    }

    #[test]
    fn velocity_numbers_convert_both_ways() {
        let h = EaseHandle { dx: 0.5, dy: 1.0 };
        assert_eq!(KeyVelocity::numbers(h, 10.0), (20.0, 0.5));
        assert_eq!(KeyVelocity::handle(20.0, 0.5, 10.0), Some(h));
        assert_eq!(KeyVelocity::handle(1.0, 0.5, 0.0), None);
        assert_eq!(KeyVelocity::handle(1.0, 0.0, 10.0).map(|h| h.dx), Some(0.01));
        assert_eq!(KeyVelocity::numbers(EaseHandle { dx: 0.0, dy: 0.0 }, 10.0).1, 0.01);
    }

    #[test]
    fn rove_puts_a_late_key_where_the_distance_says() {
        // Middle key at 90 % of the distance but 5 s in: roving puts it at 9 s of 10.
        let mut tr = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0), pos(2, 5, 90.0), pos(3, 10, 100.0)]);
        assert!(tr.rove(&BTreeSet::from([id(2)])));
        assert_eq!(tr.keys[1].time, t(9));
        assert_eq!(tr.keys.iter().map(|k| k.value.x).collect::<Vec<_>>(), vec![0.0, 90.0, 100.0]);
    }

    #[test]
    fn rove_keeps_first_last_and_unselected_keys() {
        let mut tr = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0), pos(2, 2, 10.0), pos(3, 4, 50.0), pos(4, 10, 90.0)]);
        assert!(!tr.rove(&BTreeSet::from([id(1), id(4)])));
        assert!(tr.rove(&BTreeSet::from([id(3)])));
        assert_eq!(tr.keys[1].time, t(2));
        assert_eq!(tr.keys[2].time, t(6));
    }

    #[test]
    fn velocity_round_trip() {
        let h = KeyVelocity::handle(300.0, 0.5, 100.0);
        assert_eq!(h, Some(EaseHandle { dx: 0.5, dy: 1.5 }));
        assert_eq!(KeyVelocity::numbers(h.unwrap_or(EaseHandle::LINEAR), 100.0), (300.0, 0.5));
    }
}
