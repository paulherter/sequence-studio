// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesLoopBake.swift (ported by task M-3)

use sq_core_time::{IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time};

// Advanced key operations on one track (the AE-style Loop, Convert to Keys and Wiggle). All of them produce plain
// keys: the file format has no expression, so nothing here needs a project file field.

fn sample_times(start: Time, end: Time, per_second: i64) -> Vec<Time> {
    let step = Time::new(1, per_second);
    let mut times = Vec::new();
    let mut t = start;
    while t < end {
        times.push(t);
        t += step;
    }
    times.push(end);
    times
}

/// Loop and Convert to Keys.
pub trait KeyLoopBake {
    /// Repeats the key pattern `cycles` more times after the last key (Loop). The first key of a repeat sits on the
    /// previous cycle's last key and is dropped; new keys get new ids. Needs at least two keys. (Swift `loop`.)
    fn loop_keys(&mut self, cycles: i64, ids: &mut dyn IdSource);

    /// Replaces the keys in `start...end` by linear keys sampled from the current curve at `samples_per_second`
    /// (Convert to Keys). The sampled curve keeps both end values; keys outside the range stay. Returns false for an
    /// empty range.
    fn bake_samples(&mut self, start: Time, end: Time, samples_per_second: i64, ids: &mut dyn IdSource) -> bool;
}

impl<V: KeyframeValue> KeyLoopBake for KeyframeTrack<V> {
    fn loop_keys(&mut self, cycles: i64, ids: &mut dyn IdSource) {
        let (Some(first), Some(last)) = (self.keys.first(), self.keys.last()) else { return };
        if cycles <= 0 || self.keys.len() < 2 {
            return;
        }
        let period = last.time - first.time;
        if period <= Time::ZERO {
            return;
        }
        let mut out = self.keys.clone();
        for c in 1..=cycles {
            let shift = period * c;
            for k in self.keys.iter().skip(1) {
                let mut n = k.clone();
                n.id = ids.next_id();
                n.time = k.time + shift;
                out.push(n);
            }
        }
        self.edit_keys(|keys| *keys = out);
    }

    fn bake_samples(&mut self, start: Time, end: Time, samples_per_second: i64, ids: &mut dyn IdSource) -> bool {
        if samples_per_second <= 0 || end <= start || self.keys.is_empty() {
            return false;
        }
        let times = sample_times(start, end, samples_per_second);
        let mut out: Vec<_> = self.keys.iter().filter(|k| k.time < start || k.time > end).cloned().collect();
        for time in times {
            if let Some(v) = self.value(time) {
                let mut k = Keyframe::new(ids.next_id(), time, v);
                k.interpolation = Interpolation::Linear;
                out.push(k);
            }
        }
        self.edit_keys(|keys| *keys = out);
        true
    }
}

/// Wiggle on a scalar track.
pub trait KeyWiggle {
    /// Wiggle: bakes `per_second` random offsets of up to +/- `amount` into `start...end` (deterministic for one
    /// `seed`). The key at `start` and at `end` keeps the curve value so the wiggle blends in and out.
    fn wiggle(
        &mut self,
        start: Time,
        end: Time,
        per_second: i64,
        amount: f64,
        seed: u64,
        ids: &mut dyn IdSource,
    ) -> bool;
}

impl KeyWiggle for KeyframeTrack<f64> {
    fn wiggle(
        &mut self,
        start: Time,
        end: Time,
        per_second: i64,
        amount: f64,
        seed: u64,
        ids: &mut dyn IdSource,
    ) -> bool {
        if per_second <= 0 || end <= start || self.keys.is_empty() {
            return false;
        }
        let times = sample_times(start, end, per_second);
        let mut rng = SplitMix64::new(seed);
        let mut out: Vec<_> = self.keys.iter().filter(|k| k.time < start || k.time > end).cloned().collect();
        for (i, time) in times.iter().enumerate() {
            let Some(base) = self.value(*time) else { continue };
            let edge = i == 0 || i == times.len() - 1;
            let noise = if edge { 0.0 } else { (rng.next_unit() * 2.0 - 1.0) * amount };
            out.push(Keyframe::new(ids.next_id(), *time, base + noise));
        }
        self.edit_keys(|keys| *keys = out);
        true
    }
}

/// The random generator behind Wiggle; the same seed gives the same offsets.
#[doc(hidden)]
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// A generator from `seed`.
    pub fn new(seed: u64) -> SplitMix64 {
        SplitMix64 { state: seed }
    }

    /// The next 64 random bits.
    pub fn next_bits(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// 0..<1
    pub fn next_unit(&mut self) -> f64 {
        (self.next_bits() >> 11) as f64 / (1u64 << 53) as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{FreshIds, key, t};

    #[test]
    fn loop_repeats_the_pattern_after_the_last_key() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 2, 10.0)]);
        tr.loop_keys(2, &mut FreshIds::new());
        assert_eq!(tr.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(0), t(2), t(4), t(6)]);
        assert_eq!(tr.keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![0.0, 10.0, 10.0, 10.0]);
        let mut one = KeyframeTrack::with_keys(vec![key(1, 0, 0.0)]);
        one.loop_keys(3, &mut FreshIds::new());
        assert_eq!(one.keys.len(), 1);
    }

    #[test]
    fn bake_samples_replaces_the_range_with_linear_keys_keeping_both_ends() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 1, 10.0), key(3, 5, 0.0)]);
        assert!(tr.bake_samples(t(0), t(2), 2, &mut FreshIds::new()));
        let times: Vec<_> = tr.keys.iter().map(|k| k.time).collect();
        assert_eq!(times, vec![t(0), Time::new(1, 2), t(1), Time::new(3, 2), t(2), t(5)]);
        assert_eq!((tr.keys[0].value, tr.keys[2].value, tr.keys[4].value), (0.0, 10.0, 7.5));
        assert!(tr.keys[..5].iter().all(|k| k.interpolation == Interpolation::Linear));
        assert!(!tr.bake_samples(t(2), t(2), 2, &mut FreshIds::new()));
        assert!(!tr.bake_samples(t(0), t(2), 0, &mut FreshIds::new()));
    }

    #[test]
    fn wiggle_is_deterministic_and_leaves_the_edges_on_the_curve() {
        let make = || KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 4, 4.0)]);
        let (mut a, mut b) = (make(), make());
        assert!(a.wiggle(t(0), t(4), 2, 1.0, 7, &mut FreshIds::new()));
        assert!(b.wiggle(t(0), t(4), 2, 1.0, 7, &mut FreshIds::new()));
        assert_eq!(a, b);
        assert_eq!(a.keys.len(), 9);
        assert_eq!((a.keys[0].value, a.keys[8].value), (0.0, 4.0));
        assert!(a.keys.iter().all(|k| (k.value - k.time.value() as f64 / k.time.timescale() as f64).abs() <= 1.0));
    }

    #[test]
    fn splitmix_matches_the_reference_sequence() {
        let mut r = SplitMix64::new(0);
        assert_eq!(r.next_bits(), 0xE220_A839_7B1D_CDAF);
        assert_eq!(r.next_bits(), 0x6E78_9E6A_A1B9_65F4);
        assert!(SplitMix64::new(1).next_unit() < 1.0);
    }
}
