// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRImportChecklist.swift. The "what came over" list shown after an import: one row for what arrived as is,
//! then what was approximated, what was left out and which files are missing.

use crate::primport_report::{Location, PRImportReport, Status};
use sq_core_model::Project;

/// Row group, in display order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    CameOver,
    Approximated,
    LeftOut,
    MissingFiles,
}

/// One row.
#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    pub id: String,
    pub kind: Kind,
    pub title: String,
    pub detail: String,
    pub count: i64,
    pub locations: Vec<Location>,
}

/// The checklist built from the importer's report; rows with `locations` can jump to clips.
#[derive(Debug, Clone, PartialEq)]
pub struct PRImportChecklist {
    items: Vec<Item>,
}

fn plural(n: i64, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

impl PRImportChecklist {
    /// The feature name of media that was not found.
    pub const OFFLINE_FEATURE: &'static str = "Offline media";

    /// The rows, top to bottom.
    pub fn items(&self) -> &[Item] {
        &self.items
    }

    /// True when something was approximated, left out or is missing.
    pub fn needs_attention(&self) -> bool {
        self.items.iter().any(|i| i.kind != Kind::CameOver)
    }

    /// Builds the list from an import report and the imported project.
    pub fn new(report: &PRImportReport, project: &Project) -> PRImportChecklist {
        let clips: i64 = project.timelines.iter().flat_map(|t| t.tracks.iter()).map(|t| t.clips().len() as i64).sum();
        let sequences = project.timelines.len() as i64;
        let mut items = vec![Item {
            id: "came-over".into(),
            kind: Kind::CameOver,
            title: format!("{}, {}", plural(clips, "clip"), plural(sequences, "sequence")),
            detail: "Imported".into(),
            count: clips,
            locations: Vec::new(),
        }];
        let mut rest = Vec::new();
        let mut offline_count = 0;
        let mut offline_locations = Vec::new();
        for e in report.entries().iter().filter(|e| e.status != Status::Mapped) {
            if e.feature == Self::OFFLINE_FEATURE {
                offline_count += e.count;
                offline_locations.extend(e.locations.iter().copied());
                continue;
            }
            rest.push(Item {
                id: format!("{}-{}", e.status.label(), e.feature),
                kind: if e.status == Status::Dropped { Kind::LeftOut } else { Kind::Approximated },
                title: Self::display_name(&e.feature),
                detail: e.note.clone(),
                count: e.count,
                locations: e.locations.clone(),
            });
        }
        // Approximated before left out, bigger counts first, then by name.
        rest.sort_by(|a, b| (a.kind, -a.count, &a.title).cmp(&(b.kind, -b.count, &b.title)));
        items.extend(rest);
        if offline_count > 0 {
            items.push(Item {
                id: "missing-files".into(),
                kind: Kind::MissingFiles,
                title: format!("{} missing", plural(offline_count, "file")),
                detail: "Placeholders until reconnected".into(),
                count: offline_count,
                locations: offline_locations,
            });
        }
        PRImportChecklist { items }
    }

    /// Internal match names ("AE.ADBE Motion") become plain names.
    pub fn display_name(feature: &str) -> String {
        for prefix in ["AE.ADBE ", "ADBE "] {
            if let Some(rest) = feature.strip_prefix(prefix) {
                return rest.to_string();
            }
        }
        feature.to_string()
    }
}
