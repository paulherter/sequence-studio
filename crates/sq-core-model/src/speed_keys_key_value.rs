// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedKeysKeyValue.swift

use crate::{ClipSpeed, SpeedKeys, SpeedSegment};
use sq_core_time::Time;

// Speed as keyframes (Effect Controls Speed row): the speed track read as "value at a key, ease between keys".
//
// No second model: a key is a boundary of the speed track, its value is the speed the track has there, and the stretch
// between two keys is a ramp segment (linear or Bezier, `speed_keys_ease.rs`). Before the first key and after the last the
// speed is constant (the first / last key's value), like any other keyframed parameter. Setting a key's value therefore
// rewrites the two segments around it and nothing else; every segment keeps its timeline length (keys stay on their
// frames), the source each segment covers follows the integral of the eased speed, so the source time stays continuous.

/// `s` with new end speeds; a flat ramp keeps its curve, so a drag through the neighbor's value does not lose it.
fn make(s: &SpeedSegment, from: ClipSpeed, to: ClipSpeed) -> SpeedSegment {
    SpeedSegment::new(s.duration, from, Some(to), s.reversed, s.ease().copied())
}

impl SpeedKeys {
    /// Sets the speed at clip-local `local` to `v`. A frame without a key gets one first (holding the speed there, so
    /// nothing else changes). The segment before the key ends on `v` (a ramp from the previous key's value; the stretch
    /// before the first key is constant `v`), the segment after starts on `v` (a ramp to the next key's value; after the
    /// last key constant `v`). Ramps keep their ease curve (also while flat). The clip start is no key: a value set there
    /// goes to the first key. `None` when `local` is outside the clip.
    pub fn setting_key_speed(&self, local: Time, v: ClipSpeed, fd: Time) -> Option<SpeedKeys> {
        let x = local.snapped(fd);
        if !(x >= Time::ZERO && x < self.duration()) {
            return None;
        }
        let mut k = self.clone();
        let b;
        if x == Time::ZERO {
            // Clip start is no key: the stretch before the first key takes the value (that is the first key's value).
            if k.segments.len() == 1 {
                let s = &k.segments[0];
                k.segments[0] = SpeedSegment::new(s.duration, v, Some(v), s.reversed, None);
                return Some(k.normalized(false));
            }
            b = 1;
        } else if let Some(existing) = k.boundaries().iter().position(|t| *t == x).filter(|e| *e < k.segments.len()) {
            b = existing;
        } else if let Some((added, boundary)) = k.adding_key(x, fd) {
            k = added;
            b = boundary;
        } else {
            return None;
        }

        if b >= 1 {
            let s = k.segments[b - 1].clone();
            // Before the first key: constant.
            k.segments[b - 1] = if b - 1 == 0 && !s.is_ramp() { make(&s, v, v) } else { make(&s, s.from, v) };
        }
        let s = k.segments[b].clone();
        k.segments[b] = if s.is_ramp() {
            make(&s, v, s.to)
        } else {
            let next = k.segments.get(b + 1).map_or(v, |n| n.from);
            make(&s, v, next)
        };
        Some(k.normalized(false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: Time = Time::new(1, 30);

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn pct(p: f64) -> ClipSpeed {
        ClipSpeed::from_percent(p)
    }

    fn one() -> SpeedKeys {
        SpeedKeys::constant(pct(100.0), false, f(60), Time::ZERO)
    }

    #[test]
    fn a_value_at_the_clip_start_of_a_single_segment_sets_it_whole() {
        let k = one().setting_key_speed(Time::ZERO, pct(200.0), FD).unwrap();
        assert_eq!((k.segments.len(), k.segments[0].from), (1, pct(200.0)));
        assert_eq!(k.duration(), f(60));
    }

    #[test]
    fn a_value_inside_the_clip_adds_a_key_and_ramps_after_it() {
        let k = one().setting_key_speed(f(30), pct(200.0), FD).unwrap();
        assert_eq!(k.segments.len(), 2);
        assert_eq!((k.segments[0].from, k.segments[0].to), (pct(200.0), pct(200.0)));
        assert_eq!((k.segments[1].from, k.segments[1].to), (pct(200.0), pct(200.0)));
        assert_eq!(k.duration(), f(60));
    }

    #[test]
    fn a_second_key_makes_a_ramp_between_the_two() {
        let a = one().setting_key_speed(f(20), pct(200.0), FD).unwrap();
        let b = a.setting_key_speed(f(40), pct(50.0), FD).unwrap();
        let middle = b.segments.iter().find(|s| s.is_ramp()).unwrap();
        assert_eq!((middle.from, middle.to), (pct(200.0), pct(50.0)));
        assert_eq!(b.duration(), f(60));
    }

    #[test]
    fn outside_the_clip_is_refused() {
        assert!(one().setting_key_speed(f(60), pct(200.0), FD).is_none());
        assert!(one().setting_key_speed(f(0) - f(1), pct(200.0), FD).is_none());
    }
}
