//! Decisions behind Quick Export (EXP-34).

use std::path::{Path, PathBuf};

use sq_export::core::settings::RangeSelection;
use sq_uikit::localization::SQL10n;

use super::model::ExportDialogModel;

/// Quick Export: where it writes, the range notice and the preset it starts from.
// Swift: Export/QuickExport.swift:6
pub enum QuickExport {}

impl QuickExport {
    /// Where Quick Export writes: `Exports/` next to a saved project, else the folder of the last export (if it still
    /// exists), else ~/Movies (`movies_directory`), else the temporary directory. Never creates the folder: opening the
    /// Export sheet and cancelling must leave nothing behind; the export itself creates it (`export_after_sheet`).
    // Swift: Export/QuickExport.swift:9
    pub fn directory(
        project_file: Option<&Path>,
        last_directory: Option<&str>,
        movies_directory: Option<&Path>,
    ) -> PathBuf {
        if let Some(file) = project_file {
            // Swift `MediaManagement.exportsFolder(forProjectAt:)`: the "Exports" folder beside the project file.
            return file.parent().unwrap_or_else(|| Path::new("")).join("Exports");
        }
        if let Some(p) = last_directory
            && Path::new(p).exists()
        {
            return PathBuf::from(p);
        }
        movies_directory.map_or_else(std::env::temp_dir, Path::to_path_buf)
    }

    /// Status line for a Quick Export that covers only In to Out ("Exporting In to Out, 0:12"); `None` for the whole
    /// sequence.
    // Swift: Export/QuickExport.swift:20
    pub fn range_notice(model: &ExportDialogModel) -> Option<String> {
        let RangeSelection::InOut(r) = model.settings().range else { return None };
        let secs = (r.duration.value() as f64 / r.duration.timescale() as f64).round() as i64;
        Some(SQL10n::format("Exporting In to Out, %@:%@", &[&(secs / 60).to_string(), &format!("{:02}", secs % 60)]))
    }

    /// The sequence's own platform preset (and loudness target) stays; a sequence without a delivery target uses the
    /// last preset exported with, when that preset still exists.
    // Swift: Export/QuickExport.swift:28
    pub fn apply_preset(model: &mut ExportDialogModel, last_preset_id: Option<&str>) {
        let selected = model.selected_id();
        let has_target =
            model.sequences().iter().find(|s| s.id == selected).is_some_and(|s| s.delivery_target.is_some());
        let Some(last) = last_preset_id else { return };
        if has_target || !model.presets().iter().any(|p| p.id() == last) {
            return;
        }
        model.open_with_preset_id(last);
    }
}
