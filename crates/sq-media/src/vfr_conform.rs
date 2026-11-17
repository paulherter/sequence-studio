// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: VFRConform.swift (`VFRConformPlan`; the AVAssetReader/Writer copy is platform code)
//! Pure frame-slot math of a variable-frame-rate conform: which output frames (at `k * frame_duration`) a source frame
//! fills. Frames are placed at the nearest slot; a frame whose slot is taken by a later one is dropped, a gap is filled by
//! repeating the frame before it. Time stays rational.

use sq_core_time::Time;
use std::ops::Range;

/// Slot index nearest to `t` (half up), never below 0.
pub fn slot(t: Time, frame_duration: Time) -> i64 {
    if frame_duration.value() <= 0 || t.value() <= 0 {
        return 0;
    }
    let (fv, ft) = (i128::from(frame_duration.value()), i128::from(frame_duration.timescale()));
    let (tv, ts) = (i128::from(t.value()), i128::from(t.timescale()));
    let num = 2 * tv * ft + fv * ts;
    let den = 2 * fv * ts;
    (num / den) as i64
}

/// Slots filled by the frame at `pts` when the next frame (or the end of the clip) is at `next`. A first frame starts at
/// slot 0 (its picture is held back to the start of the clip instead of leaving it empty).
pub fn slots(pts: Time, next: Time, frame_duration: Time, is_first: bool) -> Range<i64> {
    let lo = if is_first { 0 } else { slot(pts, frame_duration) };
    let hi = slot(next, frame_duration);
    lo..lo.max(hi)
}

/// Slot range of every source frame; the sum of their sizes is the output frame count.
pub fn plan(pts: &[Time], end: Time, frame_duration: Time) -> Vec<Range<i64>> {
    (0..pts.len()).map(|i| slots(pts[i], pts.get(i + 1).copied().unwrap_or(end), frame_duration, i == 0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: Time = Time::new(1, 30);

    #[test]
    fn slot_is_the_nearest_frame() {
        assert_eq!(slot(Time::ZERO, FD), 0);
        assert_eq!(slot(Time::new(1, 30), FD), 1);
        assert_eq!(slot(Time::new(3003, 30000), FD), 3);
        assert_eq!(slot(Time::new(5, 60), FD), 3); // half a frame rounds up
        assert_eq!(slot(Time::new(-1, 30), FD), 0);
    }

    #[test]
    fn gap_repeats_and_dense_frames_drop() {
        let pts = [Time::new(0, 30), Time::new(1, 30), Time::new(5, 30), Time::new(9, 50), Time::new(7, 30)];
        let p = plan(&pts, Time::new(8, 30), FD);
        assert_eq!(p, vec![0..1, 1..5, 5..5, 5..7, 7..8]);
        assert_eq!(p.iter().map(|r| r.end - r.start).sum::<i64>(), 8);
    }

    #[test]
    fn first_frame_starts_at_zero() {
        assert_eq!(plan(&[Time::new(2, 30), Time::new(3, 30)], Time::new(4, 30), FD), vec![0..3, 3..4]);
    }
}
