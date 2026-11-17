//! What the last import did, in one value (Swift `ImportReport`).

/// One file of an [`ImportReport`] list with its plain-language detail.
// Swift: ImportReport.swift:7
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportReportEntry {
    pub file: String,
    /// Reason (failed), codec (unsupported, audio dropped) or the name of what it duplicates.
    // Swift: ImportReport.swift:9
    pub detail: String,
}

impl ImportReportEntry {
    /// The codec of an unsupported or sound-less entry, or a stand-in when the probe did not name one.
    fn codec_text(&self) -> &str {
        if self.detail.is_empty() { "unknown codec" } else { &self.detail }
    }

    // Swift: ImportReport.swift:10
    pub fn new(file: impl Into<String>, detail: impl Into<String>) -> ImportReportEntry {
        ImportReportEntry { file: file.into(), detail: detail.into() }
    }
}

/// How many files landed and every file that did not (or landed without sound). Shown by a notice or sheet; empty
/// lists mean nothing to tell.
// Swift: ImportReport.swift:5
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportReport {
    // Swift: ImportReport.swift:12
    pub imported: i64,
    /// Same path as an item in the project.
    // Swift: ImportReport.swift:15
    pub already_in_project: Vec<String>,
    /// Another path to a file that is already in the project or earlier in the same batch.
    // Swift: ImportReport.swift:17
    pub duplicates: Vec<String>,
    // Swift: ImportReport.swift:18
    pub failed: Vec<ImportReportEntry>,
    // Swift: ImportReport.swift:19
    pub unsupported: Vec<ImportReportEntry>,
    /// Imported, but without sound (its audio codec cannot be decoded here).
    // Swift: ImportReport.swift:21
    pub audio_dropped: Vec<ImportReportEntry>,
    // Swift: ImportReport.swift:22
    pub canceled: bool,
}

impl ImportReport {
    // Swift: ImportReport.swift:23
    pub fn new() -> ImportReport {
        ImportReport::default()
    }

    /// Files that were not imported.
    // Swift: ImportReport.swift:27
    pub fn skipped_count(&self) -> usize {
        self.already_in_project.len() + self.duplicates.len() + self.failed.len() + self.unsupported.len()
    }

    // Swift: ImportReport.swift:28
    pub fn is_clean(&self) -> bool {
        self.skipped_count() == 0 && self.audio_dropped.is_empty() && !self.canceled
    }

    /// The dialog for what did not go in (title, detail): one line per file with the reason, the first few only. `None` when
    /// every file landed whole (a file the project already had is the status line's business, see `summary`).
    pub fn failure_notice(&self) -> Option<(String, String)> {
        const SHOWN: usize = 6;
        let failed = self.failed.iter().map(|f| (f.file.as_str(), f.detail.clone()));
        let unsupported = self
            .unsupported
            .iter()
            .map(|u| (u.file.as_str(), format!("uses a codec that is not supported ({}).", u.codec_text())));
        let lost: Vec<(&str, String)> = failed.chain(unsupported).collect();
        let dropped: Vec<(&str, String)> = self
            .audio_dropped
            .iter()
            .map(|a| (a.file.as_str(), format!("imported without sound ({}).", a.codec_text())))
            .collect();
        let title = match (lost.as_slice(), dropped.as_slice()) {
            ([], []) => return None,
            ([], _) => "Imported without sound".to_string(),
            ([(one, _)], _) => format!("Could not import \u{201C}{one}\u{201D}"),
            ([(first, _), rest @ ..], _) => format!("Could not import \u{201C}{first}\u{201D} and {} more", rest.len()),
        };
        let lines: Vec<String> =
            lost.iter().chain(dropped.iter()).map(|(file, why)| format!("{file}: {why}")).collect();
        let mut detail = lines.iter().take(SHOWN).cloned().collect::<Vec<_>>().join("\n");
        if lines.len() > SHOWN {
            detail.push_str(&format!("\nand {} more.", lines.len() - SHOWN));
        }
        Some((title, detail))
    }

    /// One status line: "Imported 12 files. 3 skipped: 1 already in the project, 2 could not be read."
    // Swift: ImportReport.swift:31
    pub fn summary(&self) -> String {
        self.summary_on(sq_os::Platform::current())
    }

    /// `summary` for a given system: "this Mac" on the Mac, "this computer" elsewhere.
    pub fn summary_on(&self, platform: sq_os::Platform) -> String {
        let machine = if platform == sq_os::Platform::Mac { "Mac" } else { "computer" };
        let files = format!("{} file{}", self.imported, if self.imported == 1 { "" } else { "s" });
        let mut parts: Vec<String> = Vec::new();
        if !self.already_in_project.is_empty() {
            parts.push(format!("{} already in the project", self.already_in_project.len()));
        }
        if !self.duplicates.is_empty() {
            let n = self.duplicates.len();
            parts.push(format!("{n} {} the same file as one already imported", if n == 1 { "is" } else { "are" }));
        }
        if !self.failed.is_empty() {
            parts.push(format!("{} could not be read", self.failed.len()));
        }
        if !self.unsupported.is_empty() {
            let n = self.unsupported.len();
            parts.push(format!("{n} {} a codec this {machine} cannot decode", if n == 1 { "uses" } else { "use" }));
        }
        let skipped = self.skipped_count();
        let mut line = if self.imported == 0 && skipped > 0 {
            "Nothing imported".to_string()
        } else {
            format!("Imported {files}")
        };
        if skipped > 0 {
            line.push_str(&if self.imported == 0 { ": ".to_string() } else { format!(". {skipped} skipped: ") });
            line.push_str(&parts.join(", "));
        }
        line.push('.');
        if !self.audio_dropped.is_empty() {
            line.push_str(&format!(
                " {} imported without sound (audio codec not supported).",
                self.audio_dropped.len()
            ));
        }
        if self.canceled {
            line.push_str(" Import canceled.");
        }
        line
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn unsupported_summary_names_the_machine_per_platform() {
        use sq_os::Platform;
        let r = super::ImportReport {
            unsupported: vec![super::ImportReportEntry::new("a.mkv", "av01")],
            ..Default::default()
        };
        assert!(r.summary_on(Platform::Mac).contains("a codec this Mac cannot decode"));
        for p in [Platform::Windows, Platform::Linux] {
            assert!(r.summary_on(p).contains("a codec this computer cannot decode"));
        }
    }

    use super::*;

    #[test]
    fn a_failed_file_is_named_with_its_reason_and_a_clean_import_says_nothing() {
        let mut r = ImportReport::new();
        assert_eq!(r.failure_notice(), None);
        r.already_in_project.push("a.mov".into());
        assert_eq!(r.failure_notice(), None, "known files go to the status line");
        r.failed.push(ImportReportEntry::new("corrupt.mp4", "The file is empty."));
        let (title, detail) = r.failure_notice().unwrap_or_default();
        assert_eq!(title, "Could not import \u{201C}corrupt.mp4\u{201D}");
        assert_eq!(detail, "corrupt.mp4: The file is empty.");
        r.unsupported.push(ImportReportEntry::new("clip.avi", "mp4v"));
        let (title, detail) = r.failure_notice().unwrap_or_default();
        assert_eq!(title, "Could not import \u{201C}corrupt.mp4\u{201D} and 1 more");
        assert!(detail.contains("clip.avi: uses a codec that is not supported (mp4v)."), "{detail}");
    }

    #[test]
    fn clean_report_counts_only() {
        let r = ImportReport { imported: 2, ..ImportReport::new() };
        assert!(r.is_clean());
        assert_eq!(r.summary(), "Imported 2 files.");
    }

    #[test]
    fn report_lists_every_skipped_kind() {
        let r = ImportReport {
            imported: 2,
            already_in_project: vec!["old.mov".into()],
            failed: vec![ImportReportEntry::new("broken.mov", "x")],
            unsupported: vec![ImportReportEntry::new("hdr.mkv", "av01")],
            audio_dropped: vec![ImportReportEntry::new("talk.webm", "ac-3")],
            ..ImportReport::new()
        };
        assert_eq!(r.skipped_count(), 3);
        assert!(!r.is_clean());
        let s = r.summary();
        assert!(s.contains("Imported 2 files"));
        assert!(s.contains("3 skipped"));
        assert!(s.contains("1 already in the project"));
        assert!(s.contains("1 could not be read"));
        let machine = if sq_os::Platform::current() == sq_os::Platform::Mac { "Mac" } else { "computer" };
        assert!(s.contains(&format!("1 uses a codec this {machine} cannot decode")));
        assert!(s.contains("1 imported without sound"));
    }

    #[test]
    fn nothing_imported_and_duplicates_and_cancel() {
        let r = ImportReport { already_in_project: vec!["a.mov".into()], ..ImportReport::new() };
        assert_eq!(r.summary(), "Nothing imported: 1 already in the project.");
        let d = ImportReport {
            imported: 1,
            duplicates: vec!["l".into(), "h".into()],
            canceled: true,
            ..ImportReport::new()
        };
        assert_eq!(
            d.summary(),
            "Imported 1 file. 2 skipped: 2 are the same file as one already imported. Import canceled."
        );
    }
}
