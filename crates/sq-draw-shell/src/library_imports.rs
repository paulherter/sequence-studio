// Swift: LibraryImports.swift
//! The file reading and library writing behind File > Import Motion Graphics Template… and Import Premiere Presets…,
//! shared by the AppKit app and the shared shell (Mac and Windows). Source files are never modified; a name that is
//! already in the library is not added again (docs/PRPROJ-IMPORT.md, docs/ENGINE-NOTES.md "Motion Graphics Templates").

use sq_core_time::{IdSource, Timestamp};
use sq_editor_session::EditorSession;
use sq_library::preset_store::{PresetItem, PresetStore};
use sq_library::title_template_preset::TitleTemplatePreset;
use sq_premiere_import::primport_report::{PRImportReport, Status};
use sq_premiere_import::prpreset::{PRPresetMapper, PRPresetReader};
use sq_uikit::localization::SQL10n;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// What reading one `.mogrt` gave (Swift `MogrtImportResult` reduced to what the library import uses).
pub struct MogrtRead {
    /// The template's own name.
    pub name: String,
    /// The template in the Library's own format.
    pub preset: TitleTemplatePreset,
    /// Number of editable text fields.
    pub slot_count: usize,
    /// Everything that was left out, summed.
    pub dropped_count: i64,
    /// Mapped / approximated / dropped, per feature.
    pub report: PRImportReport,
}

/// What importing `.mogrt` files did.
#[derive(Default)]
pub struct MogrtOutcome {
    /// Templates added.
    pub added: i64,
    /// Templates the library had already.
    pub already: i64,
    /// Items left out of the added templates.
    pub dropped: i64,
    /// The import report of the added templates.
    pub report: PRImportReport,
    /// File name and reason of each file that failed.
    pub failures: Vec<(String, String)>,
}

impl MogrtOutcome {
    /// The status line; `None` when nothing was added and nothing was there already.
    pub fn status_line(&self) -> Option<String> {
        if self.added == 0 && self.already == 0 {
            return None;
        }
        let mut s = SQL10n::plural(
            self.added,
            "Imported %@ template. Find it in the Library under Titles",
            "Imported %@ templates. Find them in the Library under Titles",
        );
        if self.already > 0 {
            s += &SQL10n::format(", %@ already in the library", &[&self.already.to_string()]);
        }
        s += &if self.dropped > 0 {
            SQL10n::plural(self.dropped, ", %@ unsupported item left out.", ", %@ unsupported items left out.")
        } else {
            ".".to_string()
        };
        Some(s)
    }

    /// The alert title for the first failure (the first reason is shown in full, the rest only counted).
    pub fn failure_title(&self) -> Option<String> {
        let first = self.failures.first()?;
        Some(if self.failures.len() == 1 {
            format!("Could not import “{}”", first.0)
        } else {
            format!("Could not import “{}” and {} more", first.0, self.failures.len() - 1)
        })
    }
}

/// Puts the read `.mogrt` files into the library as title templates. Each entry is a file and what reading it gave: the
/// Rust `MogrtImporter` stops at `open` (the template capture of Swift's `MogrtImporter.read` is not ported yet), so the
/// caller reads (`ShellServices::read_mogrt`).
pub fn import_mogrts(
    reads: Vec<(PathBuf, Result<MogrtRead, String>)>,
    store: &mut PresetStore,
    ids: &mut dyn IdSource,
    now: Timestamp,
) -> MogrtOutcome {
    let mut existing = TitleTemplatePreset::names(store.all());
    let mut out = MogrtOutcome::default();
    let several = reads.len() > 1;
    for (url, read) in reads {
        let file = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let result = match read {
            Ok(r) => r,
            Err(e) => {
                out.failures.push((file, e));
                continue;
            }
        };
        let name = result.name.clone();
        if existing.contains(&name) {
            out.already += 1;
            continue;
        }
        let item = match result.preset.preset_item(&name, ids.next_id(), now) {
            Ok(i) => i,
            Err(e) => {
                out.failures.push((file, e.to_string()));
                continue;
            }
        };
        if let Err(e) = store.add(item) {
            out.failures.push((file, e.to_string()));
            continue;
        }
        existing.insert(name.clone());
        out.added += 1;
        out.dropped += result.dropped_count;
        out.report.note(
            &name,
            if result.dropped_count > 0 { Status::Approximated } else { Status::Mapped },
            &format!("{} editable text {}", result.slot_count, if result.slot_count == 1 { "field" } else { "fields" }),
        );
        for e in result.report.entries().iter().filter(|e| e.status != Status::Mapped) {
            for _ in 0..e.count {
                let feature = if several { format!("{name}: {}", e.feature) } else { e.feature.clone() };
                out.report.note(&feature, e.status, &e.note);
            }
        }
    }
    out
}

/// What importing a Premiere preset file did.
#[derive(Default)]
pub struct PresetOutcome {
    /// Presets added.
    pub added: i64,
    /// Presets the library had already.
    pub already: i64,
    /// Presets not imported.
    pub skipped: i64,
    /// The import report.
    pub report: PRImportReport,
    /// The mapper's own report, for the log.
    pub mapper_summary: String,
}

impl PresetOutcome {
    /// The status line of the import.
    pub fn status_line(&self, file_name: &str) -> String {
        let mut s =
            SQL10n::plural_with(self.added, "Imported %@ preset from %@", "Imported %@ presets from %@", &[file_name]);
        if self.already > 0 {
            s += &SQL10n::format(", %@ already in the library", &[&self.already.to_string()]);
        }
        s += &if self.skipped == 0 {
            ".".to_string()
        } else {
            SQL10n::format(", %@ skipped.", &[&self.skipped.to_string()])
        };
        s
    }
}

/// Why a preset file was not imported.
#[derive(Debug)]
pub struct PresetImportError(pub String);

impl std::fmt::Display for PresetImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PresetImportError {}

/// Reads a Premiere effect preset file (.prfpset) into the user preset library. Fails when the file cannot be read.
pub fn import_premiere_presets(
    url: &Path,
    store: &mut PresetStore,
    ids: &mut dyn IdSource,
    now: Timestamp,
) -> Result<PresetOutcome, PresetImportError> {
    let data = std::fs::read(url).map_err(|e| PresetImportError(e.to_string()))?;
    let presets = PRPresetReader::read(&data).map_err(|e| PresetImportError(e.to_string()))?;
    let result = PRPresetMapper::map(&presets, (1080, 1920), &PRPresetMapper::ignored_folders(), ids);
    let mut existing: BTreeSet<String> = store.all().iter().map(|p| p.name.clone()).collect();
    let mut out = PresetOutcome::default();
    for p in &result.presets {
        if existing.contains(&p.name) {
            out.already += 1;
            continue;
        }
        let item: PresetItem =
            EditorSession::effect_preset_item(&p.name, &p.preset, ids.next_id(), now).map_err(PresetImportError)?;
        store.add(item).map_err(|e| PresetImportError(e.to_string()))?;
        existing.insert(p.name.clone());
        out.added += 1;
        out.report.note(
            &p.name,
            if p.notes.is_empty() { Status::Mapped } else { Status::Approximated },
            &p.notes.join("; "),
        );
    }
    for s in &result.skipped {
        out.report.note(&s.path, Status::Dropped, &s.reason);
    }
    out.skipped = result.skipped.len() as i64;
    out.mapper_summary = result.report.summary();
    Ok(out)
}

/// `~/Documents/Adobe/Premiere Pro/<version>/Profile-*/Effect Presets and Custom Items.prfpset`, best first: highest
/// version, then the most recently changed (the user's own profile over a stock one).
pub fn premiere_preset_files(home: &Path) -> Vec<PathBuf> {
    let root = home.join("Documents/Adobe/Premiere Pro");
    let mut found: Vec<(f64, std::time::SystemTime, PathBuf)> = Vec::new();
    let versions =
        std::fs::read_dir(&root).map(|d| d.flatten().map(|e| e.path()).collect::<Vec<_>>()).unwrap_or_default();
    for v in versions {
        let Some(number) = v.file_name().and_then(|n| n.to_string_lossy().parse::<f64>().ok()) else { continue };
        let profiles =
            std::fs::read_dir(&v).map(|d| d.flatten().map(|e| e.path()).collect::<Vec<_>>()).unwrap_or_default();
        for p in profiles {
            if !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("Profile-")) {
                continue;
            }
            let f = p.join("Effect Presets and Custom Items.prfpset");
            let Some(date) = std::fs::metadata(&f).and_then(|m| m.modified()).ok() else { continue };
            found.push((number, date, f));
        }
    }
    found.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.cmp(&a.1)));
    found.into_iter().map(|f| f.2).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mogrt_status_line_counts_added_already_and_dropped() {
        let mut o = MogrtOutcome::default();
        assert_eq!(o.status_line(), None);
        o.added = 1;
        assert_eq!(o.status_line().as_deref(), Some("Imported 1 template. Find it in the Library under Titles."));
        o.added = 2;
        o.already = 1;
        o.dropped = 3;
        assert_eq!(
            o.status_line().as_deref(),
            Some(
                "Imported 2 templates. Find them in the Library under Titles, 1 already in the library, 3 unsupported items left out."
            )
        );
    }

    #[test]
    fn failure_title_names_the_first_and_counts_the_rest() {
        let mut o = MogrtOutcome::default();
        assert_eq!(o.failure_title(), None);
        o.failures.push(("a.mogrt".into(), "x".into()));
        assert_eq!(o.failure_title().as_deref(), Some("Could not import “a.mogrt”"));
        o.failures.push(("b.mogrt".into(), "y".into()));
        assert_eq!(o.failure_title().as_deref(), Some("Could not import “a.mogrt” and 1 more"));
    }

    #[test]
    fn preset_status_line_ends_with_the_skipped_count() {
        let o = PresetOutcome { added: 4, already: 1, skipped: 2, ..PresetOutcome::default() };
        assert_eq!(
            o.status_line("p.prfpset"),
            "Imported 4 presets from p.prfpset, 1 already in the library, 2 skipped."
        );
        let o = PresetOutcome { added: 1, ..PresetOutcome::default() };
        assert_eq!(o.status_line("p.prfpset"), "Imported 1 preset from p.prfpset.");
    }

    #[test]
    fn preset_files_are_empty_without_an_adobe_folder() {
        assert!(premiere_preset_files(Path::new("/nonexistent-home")).is_empty());
    }
}
