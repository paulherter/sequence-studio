// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+SplitPoints.swift
//
// Split points: where linked clips (A/V partners) start or end at different times, as after a J or L cut.

use sq_core_model::{Clip, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Split points and Mark Overhang.
pub trait TimelineSplitPointsExt {
    /// Sorted times at which linked partners do not line up (their differing starts and ends).
    fn split_points(&self) -> Vec<Time>;

    /// The first split point after `t`.
    fn next_split_point(&self, t: Time) -> Option<Time>;

    /// The last split point before `t`.
    fn previous_split_point(&self, t: Time) -> Option<Time>;

    /// In/Out for Mark Overhang: the lead (earliest to latest start) or trail (earliest to latest end) of the linked group
    /// under `t` (or holding a clip of `selection`). Picks the one containing `t`, else lead before trail.
    fn mark_overhang_range(&self, t: Time, selection: &BTreeSet<Id>) -> Option<TimeRange>;
}

/// Linked groups with at least two clips, as their timeline ranges.
fn linked_groups(tl: &Timeline) -> Vec<Vec<TimeRange>> {
    let mut by_link: BTreeMap<Id, Vec<TimeRange>> = BTreeMap::new();
    for c in tl.tracks.iter().flat_map(|t| t.clips()) {
        if let Some(l) = c.link {
            by_link.entry(l).or_default().push(c.timeline());
        }
    }
    by_link.into_values().filter(|g| g.len() > 1).collect()
}

impl TimelineSplitPointsExt for Timeline {
    fn split_points(&self) -> Vec<Time> {
        let mut pts: BTreeSet<Time> = BTreeSet::new();
        for g in linked_groups(self) {
            let starts: BTreeSet<Time> = g.iter().map(|r| r.start).collect();
            let ends: BTreeSet<Time> = g.iter().map(TimeRange::end).collect();
            if starts.len() > 1 {
                pts.extend(starts);
            }
            if ends.len() > 1 {
                pts.extend(ends);
            }
        }
        pts.into_iter().collect()
    }

    fn next_split_point(&self, t: Time) -> Option<Time> {
        self.split_points().into_iter().find(|p| *p > t)
    }

    fn previous_split_point(&self, t: Time) -> Option<Time> {
        self.split_points().into_iter().rev().find(|p| *p < t)
    }

    fn mark_overhang_range(&self, t: Time, selection: &BTreeSet<Id>) -> Option<TimeRange> {
        let clips: Vec<&Clip> = self.tracks.iter().flat_map(|tr| tr.clips()).collect();
        // The links come out sorted; Swift walked a `Set`, so ties between groups are decided by link order here.
        let links: BTreeSet<Id> = clips
            .iter()
            .filter(|c| selection.contains(&c.id) || (selection.is_empty() && c.timeline().contains(t)))
            .filter_map(|c| c.link)
            .collect();
        let mut cands: Vec<TimeRange> = Vec::new();
        for l in links {
            let g: Vec<TimeRange> = clips.iter().filter(|c| c.link == Some(l)).map(|c| c.timeline()).collect();
            if g.len() < 2 {
                continue;
            }
            let starts = g.iter().map(|r| r.start);
            let ends = g.iter().map(TimeRange::end);
            let (Some(s0), Some(s1), Some(e0), Some(e1)) =
                (starts.clone().min(), starts.max(), ends.clone().min(), ends.max())
            else {
                continue;
            };
            if s1 > s0 {
                cands.push(TimeRange::from_end(s0, s1));
            }
            if e1 > e0 {
                cands.push(TimeRange::from_end(e0, e1));
            }
        }
        cands.iter().find(|r| r.contains(t)).copied().or_else(|| cands.iter().min_by_key(|r| r.start).copied())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};

    /// V clip 0...10, linked A clip 2...12 (an L-style offset), plus an aligned pair at 20...30.
    fn tl() -> Timeline {
        let (l1, l2) = (link(), link());
        timeline(vec![
            track(Video, vec![clip(0, 10, 0, Video, Some(l1), None), clip(20, 10, 0, Video, Some(l2), None)]),
            track(Audio, vec![clip(2, 10, 0, Audio, Some(l1), None), clip(20, 10, 0, Audio, Some(l2), None)]),
        ])
    }

    #[test]
    fn points_are_only_misaligned_edges() {
        assert_eq!(tl().split_points(), [s(0), s(2), s(10), s(12)]);
    }

    #[test]
    fn next_and_previous() {
        let t = tl();
        assert_eq!(t.next_split_point(s(2)), Some(s(10)));
        assert_eq!(t.previous_split_point(s(2)), Some(s(0)));
        assert_eq!(t.next_split_point(s(12)), None);
        assert_eq!(t.previous_split_point(s(0)), None);
    }

    #[test]
    fn mark_overhang_picks_lead_or_trail() {
        let t = tl();
        let none = BTreeSet::new();
        assert_eq!(t.mark_overhang_range(s(1), &none), Some(r(0, 2)));
        assert_eq!(t.mark_overhang_range(s(11), &none), Some(r(10, 12)));
        assert_eq!(t.mark_overhang_range(s(5), &none), Some(r(0, 2)));
        assert_eq!(t.mark_overhang_range(s(25), &none), None);
    }
}
