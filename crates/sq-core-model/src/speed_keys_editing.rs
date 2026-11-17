// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedKeysEditing.swift

use crate::{Clip, ClipSpeed, Rational, SpeedKeys, SpeedSegment};
use sq_core_time::Time;

// Pure edits of a speed track (the rubber-band gestures), all on whole frames of `fd`.
//
// The rules these follow: a key splits into two halves with a ramp between them; dragging a segment of the rubber band
// changes its speed and so the clip's length (the source range stays); dragging a key moves where the speed changes;
// deleting a key removes the change. Ramps are linear in timeline time unless they carry a Bezier speed curve
// (`speed_keys_ease.rs`); every edit below keeps a ramp's curve.

impl SpeedKeys {
    /// The track a constant clip is equal to: one segment (what the first edit starts from).
    pub fn of(c: &Clip) -> SpeedKeys {
        c.speed_keys.clone().unwrap_or_else(|| {
            SpeedKeys::constant(
                c.speed,
                c.reversed,
                c.duration(),
                if c.reversed { c.source.end() } else { c.source.start },
            )
        })
    }

    /// Adds a key (a boundary) at clip-local `local` (snapped to a frame). A ramp is cut in two sub-ramps; the speed does
    /// not change. `None` when `local` is on an existing boundary or outside the clip. Returns the new boundary index too.
    pub fn adding_key(&self, local: Time, fd: Time) -> Option<(SpeedKeys, usize)> {
        let x = local.snapped(fd);
        let bs = self.boundaries();
        if !(x > Time::ZERO && x < self.duration()) || bs.contains(&x) {
            return None;
        }
        let i = bs.iter().rposition(|b| *b < x)?;
        let s = self.segments.get(i)?;
        let off = x - bs[i];
        let left = s.sub_segment(Time::ZERO, off);
        let right = s.sub_segment(off, s.duration);
        let mut k = self.clone();
        k.segments.splice(i..=i, [left, right]);
        Some((k, i + 1))
    }

    /// Sets the speed of constant segment `i` (a ramp becomes constant). The segment keeps the source it covers, so its
    /// timeline length changes to `span / speed`, rounded to whole frames (at least one): the clip gets shorter or longer.
    pub fn setting_speed(&self, i: usize, v: ClipSpeed, fd: Time) -> SpeedKeys {
        let Some(s) = self.segments.get(i) else { return self.clone() };
        let mut k = self.clone();
        let n = v.unscale(s.span()).snapped(fd).max(fd);
        k.segments[i] = SpeedSegment::constant(n, v, s.reversed);
        k.normalized(false) // a key next to an equal speed stays
    }

    /// Splits the key at `boundary` into two halves with a ramp between them (a "split key"): `half` frames come off each
    /// neighbor (ramp of `2 * half`, centered). See `splitting_key_taking`.
    pub fn splitting_key(&self, b: usize, half: Time, fd: Time) -> Option<SpeedKeys> {
        self.splitting_key_taking(b, half, half, fd)
    }

    /// Splits the key at `boundary` into two halves: the ramp takes `take_left` from the segment before and `take_right`
    /// from the one after (dragging only the right half to the right gives `take_right` only). Both neighbors must be
    /// constant segments that keep at least one frame and play in the same direction (a ramp cannot pass through a stop);
    /// the ramp is at least one frame. `None` otherwise.
    pub fn splitting_key_taking(&self, b: usize, take_left: Time, take_right: Time, fd: Time) -> Option<SpeedKeys> {
        if b < 1 || b >= self.segments.len() {
            return None;
        }
        let (l, r) = (&self.segments[b - 1], &self.segments[b]);
        let (tl, tr) = (take_left.snapped(fd), take_right.snapped(fd));
        let ok = tl >= Time::ZERO
            && tr >= Time::ZERO
            && tl + tr >= fd
            && !l.is_ramp()
            && !r.is_ramp()
            && l.reversed == r.reversed
            && l.from != r.from
            && l.duration - tl >= fd
            && r.duration - tr >= fd;
        if !ok {
            return None;
        }
        let mut k = self.clone();
        k.segments[b - 1].duration = l.duration - tl;
        k.segments[b].duration = r.duration - tr;
        k.segments.insert(b, SpeedSegment::new(tl + tr, l.from, Some(r.from), l.reversed, None));
        Some(k)
    }

    /// Removes the speed transition `i`: the change of speed becomes instant in the middle of where the ramp was
    /// (deleting a half of a split key reverts the transition).
    pub fn removing_ramp(&self, i: usize, fd: Time) -> Option<SpeedKeys> {
        if !self.segments.get(i)?.is_ramp() {
            return None;
        }
        let mut k = self.clone();
        let ramp = &self.segments[i];
        let half = ramp.duration.halved().snapped(fd);
        let left_gets = half.min(ramp.duration);
        let right_gets = ramp.duration - left_gets;
        let mut parts = vec![SpeedSegment::constant(left_gets, ramp.from, ramp.reversed)];
        if right_gets > Time::ZERO {
            parts.push(SpeedSegment::constant(right_gets, ramp.to, ramp.reversed));
        }
        // The halves rejoin the constant neighbors they came from: one key is left where the ramp was.
        let (mut lo, mut hi) = (i, i);
        if i > 0 && k.segments[i - 1].joins(&parts[0]) {
            parts[0].duration += k.segments[i - 1].duration;
            lo = i - 1;
        }
        if i + 1 < k.segments.len() {
            let last = parts.len() - 1;
            if k.segments[i + 1].joins(&parts[last]) {
                parts[last].duration += k.segments[i + 1].duration;
                hi = i + 1;
            }
        }
        k.segments.splice(lo..=hi, parts);
        Some(k.normalized(false))
    }

    /// Changes the width of ramp `i` to `width` (whole frames), taking the difference from the neighbors evenly (all from
    /// one side at a clip end). Clamped to what the neighbors can give (each keeps one frame) and to at least 2 frames.
    pub fn setting_ramp_width(&self, i: usize, width: Time, fd: Time) -> Option<SpeedKeys> {
        if !self.segments.get(i)?.is_ramp() {
            return None;
        }
        let (has_l, has_r) = (i > 0, i + 1 < self.segments.len());
        if !(has_l || has_r) {
            return None;
        }
        let cur = self.segments[i].duration.frame_index(fd);
        let want = width.snapped(fd).frame_index(fd).max(2);
        let mut n = want - cur; // frames to add (negative = give back)
        let room_l = if has_l { (self.segments[i - 1].duration.frame_index(fd) - 1).max(0) } else { 0 };
        let room_r = if has_r { (self.segments[i + 1].duration.frame_index(fd) - 1).max(0) } else { 0 };
        if n > 0 {
            n = n.min(room_l + room_r);
        }
        if n == 0 {
            return if n == want - cur { Some(self.clone()) } else { None };
        }
        let (mut l, mut r) = (0i64, 0i64);
        if has_l && has_r {
            l = n / 2;
            if n > 0 {
                l = l.min(room_l);
            }
            r = n - l;
            if n > 0 && r > room_r {
                r = room_r;
                l = n - r;
            }
        } else if has_l {
            l = n;
        } else {
            r = n;
        }
        let mut k = self.clone();
        if has_l {
            k.segments[i - 1].duration -= fd * l;
        }
        if has_r {
            k.segments[i + 1].duration -= fd * r;
        }
        k.segments[i].duration = fd * (cur + n);
        Some(k)
    }

    /// Moves the key at `boundary` by `delta` (snapped to frames; each neighbor keeps at least one frame). The clip length
    /// stays.
    pub fn moving_key(&self, b: usize, delta: Time, fd: Time) -> Option<SpeedKeys> {
        if b < 1 || b >= self.segments.len() {
            return None;
        }
        let mut d = delta.snapped(fd);
        let (l, r) = (self.segments[b - 1].duration, self.segments[b].duration);
        d = d.min(r - fd);
        d = d.max(fd - l);
        if d == Time::ZERO {
            return None;
        }
        let mut k = self.clone();
        k.segments[b - 1].duration = l + d;
        k.segments[b].duration = r - d;
        Some(k)
    }

    /// Moves a whole speed transition by `delta` (snapped to frames): the segment before grows by it, the one after
    /// shrinks; the ramp keeps its width. Each neighbor keeps at least one frame.
    pub fn moving_ramp(&self, i: usize, delta: Time, fd: Time) -> Option<SpeedKeys> {
        if !(self.segments.get(i)?.is_ramp() && i >= 1 && i + 1 < self.segments.len()) {
            return None;
        }
        let mut d = delta.snapped(fd);
        d = d.min(self.segments[i + 1].duration - fd);
        d = d.max(fd - self.segments[i - 1].duration);
        if d == Time::ZERO {
            return None;
        }
        let mut k = self.clone();
        k.segments[i - 1].duration += d;
        k.segments[i + 1].duration -= d;
        Some(k)
    }

    /// Deletes the key at `boundary`: the two segments join into one constant segment over the same timeline length that
    /// covers the same source (their average speed). Segments that play in different directions are left alone.
    pub fn removing_key(&self, b: usize) -> Option<SpeedKeys> {
        if b < 1 || b >= self.segments.len() {
            return None;
        }
        let (l, r) = (&self.segments[b - 1], &self.segments[b]);
        if l.reversed != r.reversed {
            return None;
        }
        let dur = l.duration + r.duration;
        let avg = (Rational::from_time(l.span()) + Rational::from_time(r.span())) / Rational::from_time(dur);
        let mut k = self.clone();
        k.segments.splice((b - 1)..=b, [SpeedSegment::constant(dur, ClipSpeed::from_rational(avg), l.reversed)]);
        Some(k)
    }

    /// Scales every segment's length so the track is `requested` long (whole frames; the last segment takes the
    /// rounding), and every speed by `old/new` so each segment still covers the same source (used by the Speed/Duration
    /// dialog and Rate Stretch on a remapped clip: the whole shape gets faster or slower).
    pub fn scaled(&self, requested: Time, fd: Time) -> SpeedKeys {
        let old = self.duration();
        let target = self.clamped_duration(requested, fd);
        if !(old > Time::ZERO && target > Time::ZERO && old != target) {
            return self.clone();
        }
        let ratio = Rational::from_time(target) / Rational::from_time(old);
        let mut k = self.clone();
        let mut used = Time::ZERO;
        let count = k.segments.len();
        for i in 0..count {
            let s = k.segments[i].clone();
            let remaining = target - used;
            let mut d = if i == count - 1 {
                remaining
            } else {
                (Rational::from_time(s.duration) * ratio).time().snapped(fd).max(fd)
            };
            d = d.min(remaining - fd * (count - 1 - i) as i64);
            d = d.max(fd);
            // Same source span in the new length: speeds scale by old/new.
            let f = Rational::from_time(s.duration) / Rational::from_time(d);
            k.segments[i] = SpeedSegment::new(
                d,
                ClipSpeed::from_rational(Rational::from_speed(s.from) * f),
                Some(ClipSpeed::from_rational(Rational::from_speed(s.to) * f)),
                s.reversed,
                s.ease().copied(),
            );
            used += d;
        }
        k
    }

    /// The shortest and longest length this track can be scaled to whole frames without any segment speed leaving
    /// 1 % ... 10000 % (the source each segment covers is preserved).
    pub fn duration_limits(&self, fd: Time) -> (Time, Time) {
        let (mut lo, mut hi) = (Rational::new(1_000_000, 1), Rational::new(0, 1));
        for s in &self.segments {
            for v in [Rational::from_speed(s.from), Rational::from_speed(s.to)] {
                if v.double() < lo.double() {
                    lo = v;
                }
                if v.double() > hi.double() {
                    hi = v;
                }
            }
        }
        let old = Rational::from_time(self.duration());
        let min_t = (old * hi / Rational::new(100, 1)).time();
        let max_t = (old * lo * Rational::new(100, 1)).time();
        let n = self.segments.len() as i64;
        let min_frames = min_t.frame_index(fd);
        let min_f = (min_frames + i64::from(min_t > fd * min_frames)).max(n);
        let max_f = max_t.frame_index(fd).max(min_f);
        (fd * min_f, fd * max_f)
    }

    /// `t` clamped into `duration_limits`.
    pub fn clamped_duration(&self, t: Time, fd: Time) -> Time {
        let (lo, hi) = self.duration_limits(fd);
        t.max(lo).min(hi)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: Time = Time::new(1, 30);

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn seg(frames: i64, pct: f64) -> SpeedSegment {
        SpeedSegment::constant(f(frames), ClipSpeed::from_percent(pct), false)
    }

    fn two() -> SpeedKeys {
        SpeedKeys::new(vec![seg(30, 100.0), seg(30, 200.0)], Time::ZERO)
    }

    #[test]
    fn adding_a_key_splits_a_segment_and_refuses_boundaries() {
        let (k, b) = two().adding_key(f(10), FD).unwrap();
        assert_eq!((k.segments.len(), b), (3, 1));
        assert_eq!((k.segments[0].duration, k.segments[1].duration), (f(10), f(20)));
        assert_eq!(k.position(f(45)), two().position(f(45)));
        assert!(two().adding_key(f(30), FD).is_none());
        assert!(two().adding_key(Time::ZERO, FD).is_none());
        assert!(two().adding_key(f(60), FD).is_none());
    }

    #[test]
    fn setting_a_segment_speed_keeps_its_source_and_changes_its_length() {
        let k = two().setting_speed(0, ClipSpeed::from_percent(50.0), FD);
        assert_eq!(k.segments[0].duration, f(60));
        assert_eq!(k.segments[0].span(), two().segments[0].span());
        assert_eq!(k.duration(), f(90));
    }

    #[test]
    fn splitting_a_key_makes_a_centered_ramp() {
        let k = two().splitting_key(1, f(5), FD).unwrap();
        assert_eq!(k.segments.len(), 3);
        assert!(k.segments[1].is_ramp());
        assert_eq!((k.segments[0].duration, k.segments[1].duration, k.segments[2].duration), (f(25), f(10), f(25)));
        assert_eq!((k.segments[1].from, k.segments[1].to), (two().segments[0].from, two().segments[1].from));
        assert!(two().splitting_key(0, f(5), FD).is_none());
        assert!(two().splitting_key(1, f(30), FD).is_none());
    }

    #[test]
    fn removing_a_ramp_rejoins_the_neighbors() {
        let split = two().splitting_key(1, f(5), FD).unwrap();
        let back = split.removing_ramp(1, FD).unwrap();
        assert_eq!(back.segments.len(), 2);
        assert_eq!(back.duration(), f(60));
        assert!(two().removing_ramp(0, FD).is_none());
    }

    #[test]
    fn moving_a_key_keeps_the_length_and_one_frame_per_neighbor() {
        let k = two().moving_key(1, f(10), FD).unwrap();
        assert_eq!((k.segments[0].duration, k.segments[1].duration), (f(40), f(20)));
        let far = two().moving_key(1, f(500), FD).unwrap();
        assert_eq!(far.segments[1].duration, f(1));
        assert!(two().moving_key(1, Time::ZERO, FD).is_none());
    }

    #[test]
    fn moving_a_ramp_shifts_its_neighbors() {
        let split = two().splitting_key(1, f(5), FD).unwrap();
        let k = split.moving_ramp(1, f(5), FD).unwrap();
        assert_eq!((k.segments[0].duration, k.segments[2].duration), (f(30), f(20)));
        assert_eq!(k.segments[1].duration, f(10));
    }

    #[test]
    fn removing_a_key_averages_the_speeds_over_the_same_source() {
        let k = two().removing_key(1).unwrap();
        assert_eq!(k.segments.len(), 1);
        assert_eq!(k.segments[0].from, ClipSpeed::from_percent(150.0));
        assert_eq!(k.position(f(60)), two().position(f(60)));
        let mut rev = two();
        rev.segments[1].reversed = true;
        assert!(rev.removing_key(1).is_none());
    }

    #[test]
    fn ramp_width_takes_from_both_neighbors() {
        let split = two().splitting_key(1, f(5), FD).unwrap();
        let wide = split.setting_ramp_width(1, f(20), FD).unwrap();
        assert_eq!(wide.segments[1].duration, f(20));
        assert_eq!(wide.duration(), f(60));
        assert_eq!(split.setting_ramp_width(1, f(10), FD), Some(split.clone()));
    }

    #[test]
    fn scaling_the_duration_keeps_the_source_each_segment_covers() {
        let k = two();
        let s = k.scaled(f(120), FD);
        assert_eq!(s.duration(), f(120));
        assert_eq!(s.segments[0].span(), k.segments[0].span());
        assert_eq!(s.segments[1].span(), k.segments[1].span());
    }

    #[test]
    fn duration_limits_respect_the_speed_range() {
        let (lo, hi) = two().duration_limits(FD);
        assert!(lo < f(60) && hi > f(60));
        assert_eq!(two().clamped_duration(Time::new(100_000, 1), FD), hi);
        assert_eq!(two().clamped_duration(Time::ZERO, FD), lo);
    }
}
