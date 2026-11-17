// Swift: ProjectSalvageNotice.swift
//! The one notice shown after a damaged project file opened with parts dropped.

use sq_core_file::ProjectSalvageReport;

pub const TITLE: &str = "Opened with parts left out";
/// Longest list shown; the rest is counted.
pub const MAX_LINES: usize = 8;

/// Body text of the notice for `file_name`.
pub fn detail(file_name: &str, report: &ProjectSalvageReport) -> String {
    let mut lines: Vec<String> = report.dropped.iter().take(MAX_LINES).map(|d| format!("• {d}")).collect();
    if report.dropped.len() > MAX_LINES {
        lines.push(format!("… and {} more", report.dropped.len() - MAX_LINES));
    }
    format!(
        "Parts of “{file_name}” could not be read and were left out:\n\n{}\n\nThe original file was not changed. The project stays unsaved until you save it: Save asks for a place, and if you choose the original name, the damaged file is kept next to it as “.damaged.bak”.",
        lines.join("\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_lists_are_counted() {
        let report = ProjectSalvageReport { dropped: (1..=10).map(|i| format!("Clip {i}")).collect() };
        let text = detail("a.sqproj", &report);
        assert!(text.starts_with("Parts of “a.sqproj” could not be read and were left out:\n\n• Clip 1\n"));
        assert!(text.contains("• Clip 8\n… and 2 more\n\nThe original file"));
        assert!(!text.contains("Clip 9"));
    }
}
