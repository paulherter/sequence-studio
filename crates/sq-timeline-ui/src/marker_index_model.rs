// Swift: MarkerIndexModel.swift
//! The marker list (timeline index): every sequence marker and every clip marker the timeline shows, in time order,
//! with a text filter and a color filter. Pure model; the view draws it, the App wires "go" (move the playhead) and the
//! CSV export.

use sq_core_edit::clip_markers::ClipMarkersExt;
use sq_core_model::{MarkerColor, TimecodeDisplay, Timeline};
use sq_core_time::text::ci_contains;
use sq_core_time::{CmxTimecode, Id, Time};

/// Where a marker lives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MarkerScope {
    /// On the sequence.
    Sequence,
    /// On a clip.
    Clip {
        /// The clip.
        id: Id,
        /// Its name.
        name: String,
    },
}

/// One row of the marker index.
#[derive(Clone, Debug, PartialEq)]
pub struct MarkerIndexEntry {
    /// The marker.
    pub marker: Id,
    /// Where it lives.
    pub scope: MarkerScope,
    /// Sequence time of the marker.
    pub time: Time,
    /// Length (zero = point).
    pub duration: Time,
    /// Shown name.
    pub name: String,
    /// Color.
    pub color: MarkerColor,
    /// Free text.
    pub comment: String,
}

impl MarkerIndexEntry {
    /// Unique per row: a speed track may show one clip marker several times, a marker id repeats then.
    pub fn id(&self) -> String {
        match &self.scope {
            MarkerScope::Sequence => format!("s-{}", self.marker),
            MarkerScope::Clip { id, .. } => {
                format!("c-{}-{}-{}/{}", id, self.marker, self.time.value(), self.time.timescale())
            }
        }
    }

    /// The Name column: the marker's own name, or a placeholder while it has none. The scope ("Sequence", a clip's name)
    /// is where the marker lives, never what it is called; it only takes part in the search.
    pub fn display_name(&self) -> &str {
        if self.name.is_empty() { Self::UNNAMED } else { &self.name }
    }

    /// Shown, muted, for a marker without a name.
    pub const UNNAMED: &'static str = "Unnamed";

    /// "Sequence" or the clip's name.
    pub fn scope_label(&self) -> &str {
        match &self.scope {
            MarkerScope::Sequence => "Sequence",
            MarkerScope::Clip { name, .. } => name,
        }
    }
}

/// The column the marker list is ordered by.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MarkerSortKey {
    Time,
    Name,
    Length,
}

/// The marker index with its filters.
#[derive(Clone, Debug, PartialEq)]
pub struct MarkerIndexModel {
    entries: Vec<MarkerIndexEntry>,
    /// Case-insensitive match on name, comment and clip name. Empty = every row.
    pub query: String,
    /// `None` = every color.
    pub color: Option<MarkerColor>,
    /// The column the rows are ordered by and whether the order ascends (the arrow in the column head).
    pub sort: (MarkerSortKey, bool),
    frame_duration: Time,
    timecode_start: Time,
    display: TimecodeDisplay,
}

impl Default for MarkerIndexModel {
    fn default() -> MarkerIndexModel {
        MarkerIndexModel::new()
    }
}

impl MarkerIndexModel {
    /// An empty model.
    pub fn new() -> MarkerIndexModel {
        MarkerIndexModel {
            entries: Vec::new(),
            query: String::new(),
            color: None,
            sort: (MarkerSortKey::Time, true),
            frame_duration: Time::new(1, 30),
            timecode_start: Time::ZERO,
            display: TimecodeDisplay::Timecode,
        }
    }

    /// A model of `timeline`.
    pub fn of(timeline: &Timeline) -> MarkerIndexModel {
        let mut m = MarkerIndexModel::new();
        m.reload(timeline);
        m
    }

    /// All entries in time order.
    pub fn entries(&self) -> &[MarkerIndexEntry] {
        &self.entries
    }

    /// Reads the markers of `timeline` again.
    pub fn reload(&mut self, timeline: &Timeline) {
        self.frame_duration = timeline.frame_duration();
        self.timecode_start = timeline.timecode_start();
        self.display = timeline.timecode_display();
        let mut out: Vec<MarkerIndexEntry> = timeline
            .markers
            .iter()
            .map(|m| MarkerIndexEntry {
                marker: m.id,
                scope: MarkerScope::Sequence,
                time: m.time,
                duration: m.duration,
                name: m.name.clone(),
                color: m.color,
                comment: m.comment.clone(),
            })
            .collect();
        for track in timeline.tracks.iter() {
            for c in track.clips().iter().filter(|c| c.markers.as_ref().is_some_and(|m| !m.is_empty())) {
                for m in c.visible_markers(timeline.frame_duration()) {
                    out.push(MarkerIndexEntry {
                        marker: m.id,
                        scope: MarkerScope::Clip { id: c.id, name: c.name.clone() },
                        time: c.start + m.time,
                        duration: m.duration,
                        name: m.name,
                        color: m.color,
                        comment: m.comment,
                    });
                }
            }
        }
        // Stable sort by time keeps the discovery order of equal times.
        out.sort_by_key(|e| e.time);
        self.entries = out;
    }

    /// A click on a column head: the same column flips the direction, another one starts ascending.
    pub fn toggle_sort(&mut self, key: MarkerSortKey) {
        self.sort = if self.sort.0 == key { (key, !self.sort.1) } else { (key, true) };
    }

    /// The rows the filters leave, in the sort order (equal rows keep their time order).
    pub fn rows(&self) -> Vec<&MarkerIndexEntry> {
        let mut rows = self.filtered_rows();
        let (key, ascending) = self.sort;
        match key {
            MarkerSortKey::Time => rows.sort_by_key(|e| e.time),
            MarkerSortKey::Name => rows.sort_by_cached_key(|e| e.name.to_lowercase()),
            MarkerSortKey::Length => rows.sort_by_key(|e| e.duration),
        }
        if !ascending {
            rows.reverse();
        }
        rows
    }

    fn filtered_rows(&self) -> Vec<&MarkerIndexEntry> {
        let q = self.query.trim_matches(|c: char| c == '\t' || c.is_whitespace() && !c.is_control());
        self.entries
            .iter()
            .filter(|e| {
                if self.color.is_some_and(|c| e.color != c) {
                    return false;
                }
                if q.is_empty() {
                    return true;
                }
                ci_contains(&e.name, q) || ci_contains(&e.comment, q) || ci_contains(e.scope_label(), q)
            })
            .collect()
    }

    fn timecode(&self) -> CmxTimecode {
        CmxTimecode::from_frame_duration(self.frame_duration, true)
    }

    /// Position text of `time` as the sequence shows it (timecode with its start, or a frame count).
    pub fn text(&self, time: Time) -> String {
        let frames =
            time.frame_index(self.frame_duration).max(0) + self.timecode_start.frame_index(self.frame_duration);
        match self.display {
            TimecodeDisplay::Frames => frames.to_string(),
            TimecodeDisplay::Timecode => self.timecode().string(frames),
        }
    }

    /// Length text: a plain duration, not shifted by the timecode start. Empty for a point marker.
    pub fn duration_text(&self, e: &MarkerIndexEntry) -> String {
        if e.duration <= Time::ZERO {
            return String::new();
        }
        let frames = e.duration.frame_index(self.frame_duration).max(0);
        match self.display {
            TimecodeDisplay::Frames => frames.to_string(),
            TimecodeDisplay::Timecode => self.timecode().string(frames),
        }
    }

    /// Index in `rows` of the last row at or before `time` (the marker the playhead is "in"); `None` before the first.
    pub fn current_row(&self, time: Time) -> Option<usize> {
        self.rows().iter().rposition(|r| r.time <= time)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::{Marker, SequenceFormat};

    fn marker(t: Time, name: &str, color: MarkerColor) -> Marker {
        Marker { id: uid(), time: t, name: name.to_string(), color, comment: String::new(), duration: Time::ZERO }
    }

    fn tl() -> Timeline {
        let mut t = Timeline::new(uid(), "t", SequenceFormat::new(Time::new(1, 30)), vec![]);
        t.markers = vec![
            marker(Time::new(2, 1), "Second", MarkerColor::Red),
            marker(Time::new(1, 1), "First", MarkerColor::Green),
        ];
        t
    }

    #[test]
    fn rows_are_in_time_order_and_filters_apply() {
        let mut m = MarkerIndexModel::of(&tl());
        assert_eq!(m.rows().iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), vec!["First", "Second"]);
        m.query = "sec".to_string();
        assert_eq!(m.rows().len(), 1);
        m.query = String::new();
        m.color = Some(MarkerColor::Green);
        assert_eq!(m.rows().iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), vec!["First"]);
    }

    #[test]
    fn current_row_is_the_last_marker_at_or_before_the_playhead() {
        let m = MarkerIndexModel::of(&tl());
        assert_eq!(m.current_row(Time::new(1, 2)), None);
        assert_eq!(m.current_row(Time::new(3, 2)), Some(0));
        assert_eq!(m.current_row(Time::new(5, 1)), Some(1));
    }

    #[test]
    fn position_text_follows_the_display_mode() {
        let m = MarkerIndexModel::of(&tl());
        assert_eq!(m.text(Time::new(1, 1)), "00:00:01:00");
        assert_eq!(m.entries()[0].scope_label(), "Sequence");
        assert!(m.entries()[0].id().starts_with("s-"));
    }

    #[test]
    fn an_unnamed_marker_shows_a_placeholder_and_never_its_scope() {
        let mut t = tl();
        t.markers.push(marker(Time::new(9, 1), "", MarkerColor::Green));
        let m = MarkerIndexModel::of(&t);
        let unnamed = m.entries().iter().find(|e| e.name.is_empty()).expect("the unnamed marker is listed");
        assert_eq!(unnamed.scope_label(), "Sequence");
        assert_eq!(unnamed.display_name(), MarkerIndexEntry::UNNAMED);
        assert_ne!(unnamed.display_name(), unnamed.scope_label());
        assert!(m.entries().iter().filter(|e| !e.name.is_empty()).all(|e| e.display_name() == e.name));
    }
}
