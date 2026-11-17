// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MusicFit.swift
//! Fit a music track to a target length by cutting or looping at bar boundaries (pure logic over a `BeatGrid`).
//! Every version keeps the track's intro and outro and joins two bar boundaries, so the beat phase never shifts.
use crate::beat_grid::BeatGrid;
use sq_core_time::{Time, TimeRange};

/// A piece of the source placed on the output.
#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    /// Where it comes from.
    pub source: TimeRange,
    /// Where it starts on the output.
    pub output_start: Time,
}

/// One auditionable way to reach the target length.
#[derive(Clone, Debug, PartialEq)]
pub struct Version {
    /// The pieces, in output order.
    pub segments: Vec<Segment>,
    /// Output times of the joins; a crossfade of `crossfade` is centered on each (length is unchanged).
    pub joins: Vec<Time>,
    /// Length of the crossfade.
    pub crossfade: Time,
    /// Output length.
    pub length: Time,
    /// `length - target`, signed.
    pub length_error: Time,
    /// Bars between the two joined boundaries.
    pub jump_bars: usize,
    /// The version is shorter than the source.
    pub removes_audio: bool,
}

/// What `MusicFit::propose` may do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    /// Most versions returned.
    pub version_count: usize,
    /// Most loops of one section.
    pub max_repeats: i64,
    /// Crossfade at each join.
    pub crossfade: Time,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { version_count: 3, max_repeats: 8, crossfade: Time::new(1, 4) }
    }
}

/// Fit a music track to a target length.
pub struct MusicFit;

struct Cand {
    a: usize,
    b: usize,
    reps: i64,
    err: f64,
}

fn sec(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

/// Stable merge sort by a "comes before" predicate. The candidate order below uses a tolerance, which is not a strict
/// weak order; `slice::sort_by` may panic on that, this never does.
fn stable_sort(items: Vec<Cand>, before: &impl Fn(&Cand, &Cand) -> bool) -> Vec<Cand> {
    if items.len() <= 1 {
        return items;
    }
    let mut left = items;
    let right = left.split_off(left.len() / 2);
    let (left, right) = (stable_sort(left, before), stable_sort(right, before));
    let mut out = Vec::with_capacity(left.len() + right.len());
    let (mut l, mut r) = (left.into_iter().peekable(), right.into_iter().peekable());
    while let (Some(x), Some(y)) = (l.peek(), r.peek()) {
        // Take from the right only when it strictly comes first, so equal elements keep their order.
        let next = if before(y, x) { r.next() } else { l.next() };
        out.extend(next);
    }
    out.extend(l);
    out.extend(r);
    out
}

impl MusicFit {
    /// Bar boundary times of `grid` that lie inside `duration`.
    pub fn bar_boundaries(grid: &BeatGrid, duration: Time) -> Vec<Time> {
        grid.downbeats().into_iter().filter(|&d| d >= Time::ZERO && d <= duration).collect()
    }

    /// Up to `settings.version_count` auditionable versions, best length match first, joins at different places.
    pub fn propose(grid: &BeatGrid, duration: Time, target: Time, settings: &Settings) -> Vec<Version> {
        let bars = Self::bar_boundaries(grid, duration);
        if bars.len() < 2 || duration <= Time::ZERO || target <= Time::ZERO || duration == target {
            return Vec::new();
        }
        let shorter = target < duration;
        let mut cands: Vec<Cand> = Vec::new();
        let diff = sec(duration) - sec(target);
        for i in 0..bars.len() - 1 {
            for j in i + 1..bars.len() {
                let delta = sec(bars[j]) - sec(bars[i]);
                if shorter {
                    // Remove bars i..<j: join at bars[i] to bars[j]. Keep at least the first bar before the cut.
                    cands.push(Cand { a: i, b: j, reps: 0, err: (delta - diff).abs() });
                } else {
                    let need = -diff;
                    let n = 1.max(settings.max_repeats.min((need / delta).round() as i64));
                    cands.push(Cand { a: i, b: j, reps: n, err: (n as f64 * delta - need).abs() });
                }
            }
        }
        // Prefer small error, then fewer repeats/shorter jumps, then joins away from the very start.
        let cands = stable_sort(cands, &|l, r| {
            if (l.err - r.err).abs() > 0.01 {
                return l.err < r.err;
            }
            if l.reps != r.reps {
                return l.reps < r.reps;
            }
            (l.b - l.a) < (r.b - r.a)
        });
        let mut picked: Vec<Cand> = Vec::new();
        for c in cands {
            // Distinct versions: join position at least two bars from any chosen one.
            if picked.iter().any(|p| p.a.abs_diff(c.a) < 2 && p.b.abs_diff(c.b) < 2) {
                continue;
            }
            if picked.iter().any(|p| p.a == c.a || p.b == c.b) {
                continue;
            }
            picked.push(c);
            if picked.len() == settings.version_count {
                break;
            }
        }
        picked.iter().map(|c| build(c.a, c.b, c.reps, &bars, duration, target, shorter, settings.crossfade)).collect()
    }
}

#[allow(clippy::too_many_arguments, reason = "mirrors the Swift helper's parameters")]
fn build(
    a: usize,
    b: usize,
    reps: i64,
    bars: &[Time],
    duration: Time,
    target: Time,
    shorter: bool,
    cf: Time,
) -> Version {
    let mut segs: Vec<Segment> = Vec::new();
    let mut joins: Vec<Time> = Vec::new();
    let mut out = Time::ZERO;
    let mut add = |from: Time, to: Time, out: &mut Time| {
        segs.push(Segment { source: TimeRange::from_end(from, to), output_start: *out });
        *out += to - from;
    };
    if shorter {
        add(Time::ZERO, bars[a], &mut out);
        joins.push(out);
        add(bars[b], duration, &mut out);
    } else {
        add(Time::ZERO, bars[b], &mut out);
        for _ in 0..reps {
            joins.push(out);
            add(bars[a], bars[b], &mut out);
        }
        joins.push(out);
        add(bars[b], duration, &mut out);
    }
    Version {
        segments: segs,
        joins,
        crossfade: cf,
        length: out,
        length_error: out - target,
        jump_bars: b - a,
        removes_audio: shorter,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// 120 BPM, 4/4: a bar is 2 s; 16 bars = 32 s.
    fn grid() -> BeatGrid {
        let beats = (0..64).map(|i| Time::new(i, 2)).collect();
        BeatGrid { beats, downbeat_beat_indices: (0..64).step_by(4).collect(), beats_per_bar: 4, bpm: 120.0 }
    }

    const DUR: Time = Time::new(32, 1);

    #[test]
    fn shortening_lands_on_bars_and_hits_target() {
        let vs = MusicFit::propose(&grid(), DUR, Time::new(20, 1), &Settings::default());
        assert_eq!(vs.len(), 3);
        for v in &vs {
            assert_eq!(v.length, Time::new(20, 1));
            assert_eq!(v.length_error, Time::ZERO);
            assert_eq!(v.jump_bars, 6);
            assert!(v.removes_audio);
            assert_eq!(v.segments[0].source.start, Time::ZERO);
            assert_eq!(v.segments[v.segments.len() - 1].source.end(), DUR);
            for j in &v.joins {
                assert_eq!(j.value() * 2 % j.timescale(), 0);
            }
        }
        let firsts: BTreeSet<(i64, i64)> = vs.iter().map(|v| (v.joins[0].value(), v.joins[0].timescale())).collect();
        assert_eq!(firsts.len(), 3);
    }

    #[test]
    fn lengthening_loops_whole_bars() {
        let vs = MusicFit::propose(&grid(), DUR, Time::new(40, 1), &Settings::default());
        assert!(!vs.is_empty());
        assert_eq!(vs[0].length, Time::new(40, 1));
        assert!(!vs[0].removes_audio);
        assert_eq!(vs[0].segments[vs[0].segments.len() - 1].source.end(), DUR);
    }

    #[test]
    fn degenerate_inputs() {
        assert!(MusicFit::propose(&grid(), DUR, DUR, &Settings::default()).is_empty());
        let one = BeatGrid { beats: vec![Time::ZERO], downbeat_beat_indices: vec![0], beats_per_bar: 4, bpm: 120.0 };
        assert!(MusicFit::propose(&one, DUR, Time::new(10, 1), &Settings::default()).is_empty());
    }

    #[test]
    fn bar_boundaries_stay_inside_duration() {
        assert_eq!(MusicFit::bar_boundaries(&grid(), Time::new(7, 1)).len(), 4);
    }
}
