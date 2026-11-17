//! The Markers panel's table model.

use sq_core_model::{Marker, MarkerColor};
use sq_core_time::{Id, Time};
use sq_uikit::timecode::Timecode;

/// Marker colors as in Premiere's marker dialog (stored on `Marker`).
// Swift: MarkersPanelModel.swift:5
pub type MarkerColorChoice = MarkerColor;

/// One table row. `color`, `duration` and `comment` are display values.
// Swift: MarkersPanelModel.swift:9
#[derive(Clone, Debug, PartialEq)]
pub struct MarkerRow {
    // Swift: MarkersPanelModel.swift:10
    pub id: Id,
    // Swift: MarkersPanelModel.swift:11
    pub color: MarkerColorChoice,
    // Swift: MarkersPanelModel.swift:12
    pub name: String,
    // Swift: MarkersPanelModel.swift:13
    pub time: Time,
    // Swift: MarkersPanelModel.swift:14
    pub in_timecode: String,
    // Swift: MarkersPanelModel.swift:15
    pub duration: Time,
    // Swift: MarkersPanelModel.swift:16
    pub duration_timecode: String,
    // Swift: MarkersPanelModel.swift:17
    pub comment: String,
}

/// The table's columns.
// Swift: MarkersPanelModel.swift:21
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarkerColumn {
    Color,
    Name,
    InPoint,
    Duration,
    Comment,
}

/// An edit the Markers panel asks for (Swift `MarkersPanelModel.Edit`).
#[derive(Clone, Debug, PartialEq)]
pub enum MarkerEdit {
    Rename(Id, String),
    SetComment(Id, String),
    SetColor(Id, MarkerColorChoice),
    SetDuration(Id, Time),
    Move(Id, Time),
}

/// Hooks of `MarkersPanelModel` as events (the app drains them with `take_events`).
#[derive(Clone, Debug, PartialEq)]
pub enum MarkersPanelEvent {
    // Swift: MarkersPanelModel.swift:37
    Seek(Time),
    // Swift: MarkersPanelModel.swift:38
    Edit(MarkerEdit),
    // Swift: MarkersPanelModel.swift:39
    Change,
}

/// The Markers panel's table model (Swift `@Observable` class): `version` goes up with every change of what it shows.
// Swift: MarkersPanelModel.swift:26
#[derive(Clone, Debug, PartialEq)]
pub struct MarkersPanelModel {
    markers: Vec<Marker>,
    frame_duration: Time,
    events: Vec<MarkersPanelEvent>,
    version: u64,
}

impl MarkersPanelModel {
    // Swift: MarkersPanelModel.swift:40
    pub fn new() -> MarkersPanelModel {
        MarkersPanelModel { markers: Vec::new(), frame_duration: Time::new(1, 30), events: Vec::new(), version: 0 }
    }

    pub fn markers(&self) -> &[Marker] {
        &self.markers
    }

    pub fn frame_duration(&self) -> Time {
        self.frame_duration
    }

    /// Shows `markers` (sorted by time) on the grid of `frame_duration`.
    // Swift: MarkersPanelModel.swift:42
    pub fn update(&mut self, mut markers: Vec<Marker>, frame_duration: Time) {
        markers.sort_by_key(|m| m.time);
        self.markers = markers;
        self.frame_duration = frame_duration;
        self.version += 1;
        self.events.push(MarkersPanelEvent::Change);
    }

    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn take_events(&mut self) -> Vec<MarkersPanelEvent> {
        std::mem::take(&mut self.events)
    }

    /// The table rows.
    // Swift: MarkersPanelModel.swift:48
    pub fn rows(&self) -> Vec<MarkerRow> {
        self.markers
            .iter()
            .map(|m| MarkerRow {
                id: m.id,
                color: m.color,
                name: m.name.clone(),
                time: m.time,
                in_timecode: Self::timecode(m.time, self.frame_duration),
                duration: m.duration,
                duration_timecode: Self::timecode(m.duration, self.frame_duration),
                comment: m.comment.clone(),
            })
            .collect()
    }

    /// Double-click on a row: seek the playhead to the marker.
    // Swift: MarkersPanelModel.swift:59
    pub fn activate(&mut self, row: usize) {
        if let Some(m) = self.markers.get(row) {
            self.events.push(MarkersPanelEvent::Seek(m.time));
        }
    }

    /// Inline edit commit. Returns false when the text is not valid for that column.
    // Swift: MarkersPanelModel.swift:65
    pub fn commit(&mut self, row: usize, column: MarkerColumn, text: &str) -> bool {
        if row >= self.markers.len() {
            return false;
        }
        let id = self.markers[row].id;
        let current = self.rows().swap_remove(row);
        let edit = match column {
            MarkerColumn::Name => (text != current.name).then(|| MarkerEdit::Rename(id, text.to_string())),
            MarkerColumn::Comment => (text != current.comment).then(|| MarkerEdit::SetComment(id, text.to_string())),
            MarkerColumn::Color => {
                let Some(c) = Self::color_from_raw(&text.to_lowercase()) else { return false };
                (c != current.color).then_some(MarkerEdit::SetColor(id, c))
            }
            MarkerColumn::InPoint => {
                let Some(t) = Self::parse_timecode(text, self.frame_duration) else { return false };
                // The shown value is frame-floored: unchanged text moves nothing.
                (text != current.in_timecode).then_some(MarkerEdit::Move(id, t))
            }
            MarkerColumn::Duration => {
                let Some(t) = Self::parse_timecode(text, self.frame_duration) else { return false };
                (text != current.duration_timecode).then_some(MarkerEdit::SetDuration(id, t))
            }
        };
        if let Some(e) = edit {
            self.events.push(MarkersPanelEvent::Edit(e));
        }
        true
    }

    fn color_from_raw(raw: &str) -> Option<MarkerColor> {
        Some(match raw {
            "green" => MarkerColor::Green,
            "red" => MarkerColor::Red,
            "purple" => MarkerColor::Purple,
            "orange" => MarkerColor::Orange,
            "yellow" => MarkerColor::Yellow,
            "white" => MarkerColor::White,
            "blue" => MarkerColor::Blue,
            "cyan" => MarkerColor::Cyan,
            _ => return None,
        })
    }

    /// The monitor's timecode: drop-frame at 29.97 / 59.94, else non-drop.
    // Swift: MarkersPanelModel.swift:87
    pub fn timecode(t: Time, frame_duration: Time) -> String {
        Timecode::new(frame_duration, true).format(t.max(Time::ZERO))
    }

    /// Accepts `HH:MM:SS:FF`, `MM:SS:FF`, `SS:FF` (`;` before the frames for drop-frame) or a plain frame count.
    // Swift: MarkersPanelModel.swift:93
    pub fn parse_timecode(text: &str, frame_duration: Time) -> Option<Time> {
        let s = text.trim_matches([' ', '\t']);
        if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) {
            let frames: i64 = s.parse().ok()?;
            // Keeps the maths below overflow.
            return (frames <= 999_999_999).then(|| frame_duration * frames);
        }
        if s.starts_with('-') {
            return None;
        }
        Timecode::new(frame_duration, true).parse(s)
    }
}

impl Default for MarkersPanelModel {
    fn default() -> MarkersPanelModel {
        MarkersPanelModel::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: Time = Time::new(1, 30);

    fn marker(n: u128, time: Time, name: &str) -> Marker {
        Marker {
            id: Id::from_u128(n),
            time,
            name: name.into(),
            color: MarkerColor::Green,
            comment: String::new(),
            duration: Time::ZERO,
        }
    }

    fn model() -> MarkersPanelModel {
        let mut m = MarkersPanelModel::new();
        m.update(vec![marker(1, Time::new(65, 1), "b"), marker(2, Time::new(2, 1), "a")], FD);
        m
    }

    #[test]
    fn huge_timecode_entries_and_times_neither_panic_nor_wrap() {
        for text in [
            "99999999999:59:59:29",
            "99999999999999999999:00:00:00",
            "00:99999999999:00:00",
            "00:00:99999999999999999999:00",
            "9999999999999999999",
            "1e9",
            "-0",
            "NaN",
            "",
            "::::",
        ] {
            if let Some(t) = MarkersPanelModel::parse_timecode(text, FD) {
                assert!(t >= Time::ZERO, "{text} parsed to a negative time");
            }
        }
        // 100 hours and an overflowing time still format.
        assert_eq!(MarkersPanelModel::timecode(Time::new(360_000, 1), FD), "100:00:00:00");
        let _ = MarkersPanelModel::timecode(Time::new(i64::MAX / 4, 1), FD);
        let _ = MarkersPanelModel::timecode(Time::new(-5, 1), FD);
    }

    #[test]
    fn rows_sorted_with_timecode() {
        let r = model().rows();
        assert_eq!(r.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        assert_eq!(r[0].in_timecode, "00:00:02:00");
        assert_eq!(r[1].in_timecode, "00:01:05:00");
    }

    #[test]
    fn double_click_seeks() {
        let mut m = model();
        m.take_events();
        m.activate(1);
        assert_eq!(m.take_events(), vec![MarkersPanelEvent::Seek(Time::new(65, 1))]);
        m.activate(9);
        assert!(m.take_events().is_empty());
    }

    #[test]
    fn inline_edits() {
        let mut m = model();
        m.take_events();
        assert!(m.commit(0, MarkerColumn::Name, "x"));
        assert!(m.commit(0, MarkerColumn::InPoint, "00:00:03:15"));
        assert!(!m.commit(0, MarkerColumn::InPoint, "00:00:03:45"));
        assert!(!m.commit(0, MarkerColumn::Duration, "abc"));
        assert!(m.commit(0, MarkerColumn::Color, "Red"));
        let edits = m.take_events();
        assert_eq!(edits.len(), 3);
        let id = m.markers()[0].id;
        assert_eq!(edits[1], MarkersPanelEvent::Edit(MarkerEdit::Move(id, Time::new(3, 1) + Time::new(15, 30))));
    }

    #[test]
    fn timecode_round_trip() {
        let t = Time::new(3661, 1) + Time::new(7, 30);
        let s = MarkersPanelModel::timecode(t, FD);
        assert_eq!(s, "01:01:01:07");
        assert_eq!(MarkersPanelModel::parse_timecode(&s, FD), Some(t));
        assert_eq!(MarkersPanelModel::parse_timecode("45", FD), Some(FD * 45));
    }
}
