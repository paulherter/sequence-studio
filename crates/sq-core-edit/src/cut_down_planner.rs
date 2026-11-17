// Swift: CutDownPlanner.swift
//! Plans the short versions of a sequence (60/30/15/6 s) from marker ranges the editor set for it.
//!
//! A cut-down marker is one named "cut-down" / "cutdown" / "cut down" or colored `CUT_DOWN_COLOR`. A marker with a
//! duration is a range by itself; point markers pair up in time order (in, out). A range whose name holds a target
//! length ("cut-down 15") belongs to that target only, an untagged range is a candidate for every target.

use sq_core_model::{Marker, MarkerColor};
use sq_core_time::{Time, TimeRange};

/// How well a plan fills its target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanStatus {
    /// Total equals the target.
    Exact,
    /// Fits, but is shorter than the target.
    Short,
    /// No range fits this target.
    Empty,
}

/// The ranges picked for one target length.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    /// Target length in seconds.
    pub target_seconds: i64,
    /// "Cut-down 15 s".
    pub name: String,
    /// Picked ranges in time order.
    pub ranges: Vec<TimeRange>,
    /// Their total.
    pub duration: Time,
    /// How well the target is filled.
    pub status: PlanStatus,
}

/// Cut-down planning (`enum CutDownPlanner`).
pub enum CutDownPlanner {}

impl CutDownPlanner {
    /// The target lengths in seconds.
    pub const TARGET_SECONDS: [i64; 4] = [60, 30, 15, 6];
    /// Color that marks a cut-down marker.
    pub const CUT_DOWN_COLOR: MarkerColor = MarkerColor::Cyan;

    /// True for a marker named like a cut-down or colored `CUT_DOWN_COLOR`.
    pub fn is_cut_down_marker(m: &Marker) -> bool {
        if m.color == Self::CUT_DOWN_COLOR {
            return true;
        }
        let n = m.name.to_lowercase();
        n.contains("cut-down") || n.contains("cutdown") || n.contains("cut down")
    }

    /// The ranges the cut-down markers describe, with the name of the marker that opened each.
    pub fn ranges(markers: &[Marker]) -> Vec<(String, TimeRange)> {
        let mut all: Vec<&Marker> = markers.iter().filter(|m| Self::is_cut_down_marker(m)).collect();
        all.sort_by_key(|m| m.time);
        let mut out = Vec::new();
        let mut open: Option<&Marker> = None;
        for m in all {
            if m.duration > Time::ZERO {
                out.push((m.name.clone(), TimeRange::new(m.time, m.duration)));
            } else if let Some(o) = open.take() {
                if m.time > o.time {
                    let name = if o.name.is_empty() { &m.name } else { &o.name };
                    out.push((name.clone(), TimeRange::from_end(o.time, m.time)));
                }
            } else {
                open = Some(m);
            }
        }
        out
    }

    /// The target length (seconds) a name asks for, if it holds one of `targets` as a whole number.
    pub(crate) fn tagged_target(name: &str, targets: &[i64]) -> Option<i64> {
        name.split(|c: char| !c.is_numeric())
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse::<i64>().ok())
            .find(|n| targets.contains(n))
    }

    /// One plan per target. Ranges are taken in time order while the total stays within the target.
    pub fn plans(markers: &[Marker], targets: &[i64]) -> Vec<Plan> {
        let all: Vec<(Option<i64>, TimeRange)> =
            Self::ranges(markers).into_iter().map(|(n, r)| (Self::tagged_target(&n, targets), r)).collect();
        targets
            .iter()
            .map(|&t| {
                let limit = Time::seconds(t);
                let mut total = Time::ZERO;
                let mut picked = Vec::new();
                for (tag, range) in &all {
                    if (tag.is_none() || *tag == Some(t)) && total + range.duration <= limit {
                        picked.push(*range);
                        total += range.duration;
                    }
                }
                let status = if picked.is_empty() {
                    PlanStatus::Empty
                } else if total == limit {
                    PlanStatus::Exact
                } else {
                    PlanStatus::Short
                };
                Plan { target_seconds: t, name: format!("Cut-down {t} s"), ranges: picked, duration: total, status }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Id;

    fn s(n: i64) -> Time {
        Time::seconds(n)
    }

    fn pt(secs: i64, name: &str) -> Marker {
        Marker {
            id: Id::fixed(secs as u64),
            time: s(secs),
            name: name.to_string(),
            color: MarkerColor::Green,
            comment: String::new(),
            duration: Time::ZERO,
        }
    }

    #[test]
    fn point_markers_pair_into_ranges() {
        let r = CutDownPlanner::ranges(&[
            pt(0, "cut-down"),
            pt(10, "cut-down"),
            pt(20, "cut-down"),
            pt(35, "cut-down"),
            pt(50, "intro"),
        ]);
        let ranges: Vec<TimeRange> = r.into_iter().map(|x| x.1).collect();
        assert_eq!(ranges, vec![TimeRange::from_end(s(0), s(10)), TimeRange::from_end(s(20), s(35))]);
    }

    #[test]
    fn duration_marker_is_a_range_and_color_counts() {
        let mut m = pt(5, "x");
        m.color = CutDownPlanner::CUT_DOWN_COLOR;
        m.duration = s(4);
        assert_eq!(CutDownPlanner::ranges(&[m])[0].1, TimeRange::new(s(5), s(4)));
    }

    #[test]
    fn plans_fill_each_target_in_order() {
        // 20 s, 20 s, 25 s: 60 takes 20+20 (the 25 would be 65); 30 takes 20; 15 and 6 take nothing.
        let ms: Vec<Marker> = [0, 20, 100, 120, 200, 225].iter().map(|&t| pt(t, "cut-down")).collect();
        let p = CutDownPlanner::plans(&ms, &CutDownPlanner::TARGET_SECONDS);
        assert_eq!(p.iter().map(|x| x.target_seconds).collect::<Vec<_>>(), vec![60, 30, 15, 6]);
        assert!(p[0].ranges.len() == 2 && p[0].duration == s(40) && p[0].status == PlanStatus::Short);
        assert!(p[1].ranges.len() == 1 && p[1].duration == s(20));
        assert!(p[2].status == PlanStatus::Empty && p[3].status == PlanStatus::Empty);
    }

    #[test]
    fn tagged_ranges_belong_to_one_target() {
        let ms = [pt(0, "cut-down 15"), pt(15, "cut-down 15"), pt(30, "cut-down 6s"), pt(36, "cut-down")];
        let p = CutDownPlanner::plans(&ms, &CutDownPlanner::TARGET_SECONDS);
        assert_eq!(p[0].status, PlanStatus::Empty);
        assert!(p[2].duration == s(15) && p[2].status == PlanStatus::Exact);
        assert!(p[3].duration == s(6) && p[3].status == PlanStatus::Exact);
    }

    #[test]
    fn no_markers_means_empty_plans() {
        let p = CutDownPlanner::plans(&[], &CutDownPlanner::TARGET_SECONDS);
        assert!(p.iter().all(|x| x.status == PlanStatus::Empty && x.name.starts_with("Cut-down")));
    }
}
