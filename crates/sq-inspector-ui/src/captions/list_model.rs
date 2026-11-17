// Swift: CaptionListModel.swift
//! The read-only caption list (time and text, a click seeks): every caption of the timeline in time order.

use sq_core_model::Timeline;
use sq_core_time::{Id, Time, TimeRange};
use sq_uikit::timecode::Timecode;

/// One row of the list.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionListRow {
    pub id: Id,
    pub track: Id,
    pub range: TimeRange,
    /// Start as timecode.
    pub time: String,
    /// All lines on one row.
    pub text: String,
}

/// A plain value; build it again when the timeline changes. Editing happens on the caption track, not here.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CaptionListModel {
    rows: Vec<CaptionListRow>,
}

impl CaptionListModel {
    pub fn new() -> CaptionListModel {
        CaptionListModel::default()
    }

    /// `visible_only`: leave out hidden caption tracks.
    pub fn from_timeline(timeline: Option<&Timeline>, timecode: &Timecode, visible_only: bool) -> CaptionListModel {
        let Some(timeline) = timeline else { return CaptionListModel::default() };
        let mut out: Vec<CaptionListRow> = Vec::new();
        for t in timeline.caption_tracks.iter().filter(|t| !visible_only || t.is_visible) {
            for item in t.items() {
                out.push(CaptionListRow {
                    id: item.id,
                    track: t.id,
                    range: item.range,
                    time: timecode.format(item.range.start),
                    text: item.lines.join(" "),
                });
            }
        }
        // One track is already in order; several are merged by start (stable, so equal starts keep track order).
        if timeline.caption_tracks.len() > 1 {
            out.sort_by_key(|r| r.range.start);
        }
        CaptionListModel { rows: out }
    }

    /// A list of ready rows (tests of the views that draw it).
    #[cfg(test)]
    pub(crate) fn from_rows_for_test(rows: Vec<CaptionListRow>) -> CaptionListModel {
        CaptionListModel { rows }
    }

    pub fn rows(&self) -> &[CaptionListRow] {
        &self.rows
    }

    /// The row spoken at `playhead`: the last row that starts at or before it and has not ended. Binary search.
    pub fn current_row(&self, playhead: Time) -> Option<usize> {
        let (mut lo, mut hi) = (0, self.rows.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.rows[mid].range.start <= playhead {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Rows of several tracks can overlap: look back a few rows for one that still runs.
        let mut i = lo as i64 - 1;
        while i >= 0 && lo as i64 - i <= 4 {
            if self.rows[i as usize].range.contains(playhead) {
                return Some(i as usize);
            }
            i -= 1;
        }
        None
    }

    /// Where a click on row `index` seeks to.
    pub fn seek_time(&self, index: usize) -> Option<Time> {
        self.rows.get(index).map(|r| r.range.start)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(start: i64, end: i64) -> CaptionListRow {
        CaptionListRow {
            id: Id::fixed(start as u64),
            track: Id::fixed(1),
            range: TimeRange::from_end(Time::new(start, 1), Time::new(end, 1)),
            time: String::new(),
            text: String::new(),
        }
    }

    #[test]
    fn current_row_is_the_last_row_that_started_and_still_runs() {
        let m = CaptionListModel { rows: vec![row(0, 2), row(3, 6), row(5, 9)] };
        assert_eq!(m.current_row(Time::new(1, 1)), Some(0));
        assert_eq!(m.current_row(Time::new(2, 1)), None);
        assert_eq!(m.current_row(Time::new(4, 1)), Some(1));
        // The overlapping rows 1 and 2: the later one wins, the earlier one still runs after the later one ended.
        assert_eq!(m.current_row(Time::new(5, 1)), Some(2));
        assert_eq!(m.seek_time(2), Some(Time::new(5, 1)));
        assert_eq!(m.seek_time(3), None);
        assert_eq!(CaptionListModel::new().current_row(Time::ZERO), None);
    }

    #[test]
    fn no_timeline_no_rows() {
        let tc = Timecode::new(Time::new(1, 30), false);
        assert!(CaptionListModel::from_timeline(None, &tc, false).rows().is_empty());
    }
}
