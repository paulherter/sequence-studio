// Swift: RazorGuide.swift
//! The hover line of the razor tool (C): where a click would cut. One track row under the pointer, or every row with
//! Shift (Premiere: razor all tracks). Pure; the view draws the rectangle over the content.

use crate::timeline_geometry::TrackRow;
use sq_core_time::Id;
use sq_uikit::keyframe_graph_geometry::Rect;
use std::collections::BTreeSet;

pub struct RazorGuide;

impl RazorGuide {
    /// `x` is the cut position in view coordinates. `None` when the pointer is not over a track row.
    pub fn rect(x: f64, pointer_y: f64, all_tracks: bool, rows: &[TrackRow]) -> Option<Rect> {
        let (first, last) = (rows.first()?, rows.last()?);
        if all_tracks {
            if !(pointer_y >= first.y && pointer_y < last.max_y()) {
                return None;
            }
            return Some(Rect::new(x.round() - 0.5, first.y, 1.0, last.max_y() - first.y));
        }
        let row = rows.iter().find(|r| pointer_y >= r.y && pointer_y < r.max_y())?;
        Some(Rect::new(x.round() - 0.5, row.y, 1.0, row.height))
    }

    /// Guide segments for an explicit set of tracks (the ones the click would cut: the clip under the pointer plus its
    /// linked partners, or every track with Shift). Adjacent rows merge into one segment.
    pub fn rects(x: f64, tracks: &BTreeSet<Id>, rows: &[TrackRow]) -> Vec<Rect> {
        let mut out: Vec<Rect> = Vec::new();
        for row in rows.iter().filter(|r| tracks.contains(&r.track)) {
            match out.last_mut() {
                Some(last) if (last.max_y() - row.y).abs() < 0.5 => last.height = row.max_y() - last.min_y(),
                _ => out.push(Rect::new(x.round() - 0.5, row.y, 1.0, row.height)),
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;

    fn row(n: u128, y: f64, h: f64) -> TrackRow {
        TrackRow {
            track: Id::from_u128(n),
            kind: TrackKind::Video,
            label: String::new(),
            y,
            height: h,
            lane_space: 0.0,
        }
    }

    #[test]
    fn rect_is_one_row_or_all_rows_with_shift() {
        let rows = vec![row(1, 20.0, 40.0), row(2, 60.0, 30.0)];
        assert_eq!(RazorGuide::rect(10.4, 30.0, false, &rows), Some(Rect::new(9.5, 20.0, 1.0, 40.0)));
        assert_eq!(RazorGuide::rect(10.4, 70.0, true, &rows), Some(Rect::new(9.5, 20.0, 1.0, 70.0)));
        assert_eq!(RazorGuide::rect(10.0, 10.0, false, &rows), None);
        assert_eq!(RazorGuide::rect(10.0, 95.0, true, &rows), None);
        assert_eq!(RazorGuide::rect(10.0, 30.0, false, &[]), None);
    }

    #[test]
    fn adjacent_rows_merge_and_gaps_split() {
        let rows = vec![row(1, 20.0, 40.0), row(2, 60.0, 30.0), row(3, 100.0, 20.0)];
        let set: BTreeSet<Id> = [1, 2, 3].map(Id::from_u128).into();
        let r = RazorGuide::rects(5.0, &set, &rows);
        assert_eq!(r, vec![Rect::new(4.5, 20.0, 1.0, 70.0), Rect::new(4.5, 100.0, 1.0, 20.0)]);
        let only: BTreeSet<Id> = [Id::from_u128(2)].into();
        assert_eq!(RazorGuide::rects(5.0, &only, &rows).len(), 1);
    }
}
