// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRImportReport.swift. What an import did with each Premiere feature: mapped 1:1, approximated (reason in
//! `note`) or dropped.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_time::Id;
use std::cmp::Ordering;

/// How faithfully a feature came over. Ordered by raw value: mapped < approximated < dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Mapped,
    Approximated,
    Dropped,
}

impl Status {
    /// Lower-case name.
    pub fn label(self) -> &'static str {
        match self {
            Status::Mapped => "mapped",
            Status::Approximated => "approximated",
            Status::Dropped => "dropped",
        }
    }

    /// Position in declaration order (the Swift raw value).
    pub fn raw_value(self) -> i64 {
        self as i64
    }
}

impl Serialize for Status {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for Status {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Status, D::Error> {
        match i64::deserialize(d)? {
            0 => Ok(Status::Mapped),
            1 => Ok(Status::Approximated),
            2 => Ok(Status::Dropped),
            n => Err(D::Error::custom(format!("invalid status {n}"))),
        }
    }
}

/// Where an affected clip sits: the timeline it is on and its id (for "Show" in the checklist).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Location {
    pub timeline: Id,
    pub clip: Id,
}

/// One counted feature.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub feature: String,
    pub status: Status,
    pub count: i64,
    pub note: String,
    /// Clips this entry touched, in import order (approximated and dropped only). Not encoded: ids change per import.
    #[serde(skip)]
    pub locations: Vec<Location>,
}

/// The import report.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PRImportReport {
    entries: Vec<Entry>,
    #[serde(skip)]
    collecting: bool,
    #[serde(skip)]
    touched: Vec<usize>,
}

impl PRImportReport {
    /// Every counted feature, in first-seen order.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Starts recording which entries `note` touches, until `end_collect`.
    pub fn begin_collect(&mut self) {
        self.collecting = true;
        self.touched = Vec::new();
    }

    /// Ends the recording and ties every approximated or dropped entry touched since `begin_collect` to `location`.
    pub fn end_collect(&mut self, location: Option<Location>) {
        let touched = std::mem::take(&mut self.touched);
        self.collecting = false;
        let Some(location) = location else { return };
        let mut idx = touched;
        idx.sort_unstable();
        idx.dedup();
        for i in idx {
            if self.entries[i].status != Status::Mapped && !self.entries[i].locations.contains(&location) {
                self.entries[i].locations.push(location);
            }
        }
    }

    /// Ties an already counted entry to one more clip (offline media is counted once per file, shown per clip).
    pub fn attach(&mut self, feature: &str, status: Status, to: Location) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.feature == feature && e.status == status)
            && !e.locations.contains(&to)
        {
            e.locations.push(to);
        }
    }

    /// Counts one occurrence of `feature` with `status`; the first non-empty note is kept.
    pub fn note(&mut self, feature: &str, status: Status, note: &str) {
        if let Some(i) = self.entries.iter().position(|e| e.feature == feature && e.status == status) {
            self.entries[i].count += 1;
            if self.entries[i].note.is_empty() {
                self.entries[i].note = note.to_string();
            }
            if self.collecting {
                self.touched.push(i);
            }
        } else {
            self.entries.push(Entry {
                feature: feature.to_string(),
                status,
                count: 1,
                note: note.to_string(),
                locations: Vec::new(),
            });
            if self.collecting {
                self.touched.push(self.entries.len() - 1);
            }
        }
    }

    /// The worst status recorded for `feature`; `None` if it never occurred.
    pub fn status_of(&self, feature: &str) -> Option<Status> {
        self.entries.iter().filter(|e| e.feature == feature).map(|e| e.status).max()
    }

    /// Total count over all statuses of `feature`.
    pub fn count_of(&self, feature: &str) -> i64 {
        self.entries.iter().filter(|e| e.feature == feature).map(|e| e.count).sum()
    }

    /// One line per feature and status, worst first.
    pub fn summary(&self) -> String {
        let mut sorted: Vec<&Entry> = self.entries.iter().collect();
        // Swift compares `(a.status, b.count, a.feature) > (b.status, a.count, b.feature)`: status descending, count
        // ascending, feature descending.
        sorted.sort_by(|a, b| match b.status.cmp(&a.status) {
            Ordering::Equal => match a.count.cmp(&b.count) {
                Ordering::Equal => b.feature.cmp(&a.feature),
                o => o,
            },
            o => o,
        });
        sorted
            .iter()
            .map(|e| {
                format!("{:<13} {}x {}", e.status.label(), e.count, e.feature)
                    + &if e.note.is_empty() { String::new() } else { format!(" - {}", e.note) }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_keep_first_note_and_worst_status() {
        let mut r = PRImportReport::default();
        r.note("Blur", Status::Approximated, "");
        r.note("Blur", Status::Approximated, "why");
        r.note("Blur", Status::Dropped, "");
        assert_eq!(r.entries()[0].count, 2);
        assert_eq!(r.entries()[0].note, "why");
        assert_eq!(r.status_of("Blur"), Some(Status::Dropped));
        assert_eq!(r.count_of("Blur"), 3);
        assert_eq!(r.status_of("Other"), None);
    }

    #[test]
    fn collect_ties_only_non_mapped_entries_to_the_clip() {
        let mut r = PRImportReport::default();
        let loc = Location { timeline: Id::from_u128(1), clip: Id::from_u128(2) };
        r.begin_collect();
        r.note("A", Status::Mapped, "");
        r.note("B", Status::Dropped, "");
        r.note("B", Status::Dropped, "");
        r.end_collect(Some(loc));
        assert!(r.entries()[0].locations.is_empty());
        assert_eq!(r.entries()[1].locations, vec![loc]);
        r.note("B", Status::Dropped, "");
        assert_eq!(r.entries()[1].locations.len(), 1);
    }

    #[test]
    fn summary_orders_worst_first_and_codes_status_as_int() {
        let mut r = PRImportReport::default();
        r.note("Z", Status::Mapped, "");
        r.note("A", Status::Dropped, "gone");
        assert_eq!(r.summary(), "dropped       1x A - gone\nmapped        1x Z");
        let json = serde_json::to_string(&r).unwrap_or_default();
        assert_eq!(
            json,
            r#"{"entries":[{"feature":"Z","status":0,"count":1,"note":""},{"feature":"A","status":2,"count":1,"note":"gone"}]}"#
        );
    }
}
