//! Finding the first frame where a clip shows, without planning every frame between: a coarse scan in half-second steps
//! finds the first step where the clip shows, then halving inside the step before it finds the exact frame. A plain halving
//! over the whole look-ahead assumed the clip stays visible from its start to the end; a hidden part in the middle (a gap, a
//! disabled stretch) sent it to the start of a later visible part and warmed the wrong frame.

/// Frames in half a second at `frame_duration` (at least 1): the step of the coarse scan.
pub(crate) fn scan_stride(frame_duration: sq_core_time::Time) -> i64 {
    let per_second = frame_duration.timescale() as f64 / frame_duration.value().max(1) as f64;
    ((per_second / 2.0).round() as i64).max(1)
}

/// The first frame in (`from`, `to`] where `shows` is true, `to` being a frame where it is true and `from` one where it is
/// not. Visible parts shorter than `stride` frames that lie between two scan steps are not seen (the scan then finds the next
/// visible step); that costs a missed warm-up of a sub-half-second flash, never a wrong frame.
pub(crate) fn earliest_visible(from: i64, to: i64, stride: i64, shows: impl Fn(i64) -> bool) -> i64 {
    let stride = stride.max(1);
    let (mut lo, mut hi) = (from, to);
    let mut probe = from + stride;
    while probe < to {
        if shows(probe) {
            hi = probe;
            break;
        }
        lo = probe;
        probe += stride;
    }
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if shows(mid) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    hi
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    /// The search this replaces: halving over the whole range.
    fn halving_only(from: i64, to: i64, shows: impl Fn(i64) -> bool) -> i64 {
        let (mut lo, mut hi) = (from, to);
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2;
            if shows(mid) {
                hi = mid;
            } else {
                lo = mid;
            }
        }
        hi
    }

    #[test]
    fn a_clip_that_stays_visible_from_its_start_is_found_at_its_start() {
        for start in [1, 12, 37, 99, 100] {
            assert_eq!(earliest_visible(0, 100, 12, |f| f >= start), start, "start {start}");
        }
    }

    #[test]
    fn a_hidden_middle_part_does_not_send_the_search_to_the_later_visible_part() {
        // Visible 10..=20, hidden 21..=59, visible again from 60 to the end of the look-ahead.
        let shows = |f: i64| (10..=20).contains(&f) || f >= 60;
        assert_eq!(halving_only(0, 100, shows), 60, "the old search lands on the later part");
        assert_eq!(earliest_visible(0, 100, 12, shows), 10);
        assert_eq!(earliest_visible(0, 100, 1, shows), 10, "a stride of one frame is a linear scan");
    }

    #[test]
    fn a_clip_visible_only_at_the_end_is_found_at_the_end() {
        assert_eq!(earliest_visible(0, 100, 12, |f| f == 100), 100);
        assert_eq!(earliest_visible(0, 5, 12, |f| f >= 3), 3, "a range shorter than the stride is halved directly");
    }

    #[test]
    fn the_scan_costs_a_handful_of_probes() {
        let probes = std::cell::Cell::new(0);
        let found = earliest_visible(0, 125, 12, |f| {
            probes.set(probes.get() + 1);
            f >= 90
        });
        assert_eq!(found, 90);
        assert!(probes.get() <= 14, "{} probes for 5 s at 25 fps", probes.get());
    }

    #[test]
    fn the_stride_is_half_a_second_of_frames() {
        assert_eq!(scan_stride(Time::new(1, 25)), 13);
        assert_eq!(scan_stride(Time::new(1001, 30000)), 15);
        assert_eq!(scan_stride(Time::new(1, 1)), 1);
        assert_eq!(scan_stride(Time::new(1, 120)), 60);
    }
}
