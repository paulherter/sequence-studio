// Swift: Export/ExportDialogModel.swift, Export/ExportDialogModel+Session.swift, Export/ExportPreflightReport.swift,
// Export/ExportPreviewMath.swift, Export/QuickExport.swift.
//! ES9: the export dialog model, preflight report, preview math, quick export.
//!
//! The Swift `ExportDialogModel` is one class; here it is `model` (state, formats, settings, checks), `model_jobs`
//! (audio check, stems, cut-downs, jobs) and `session_items` (the sequence list from the session), all one type.
//! Swift `async` parts become blocking requests the host runs on a worker (see `model_jobs`).

mod format_text;
mod model;
mod model_jobs;
mod preflight_report;
mod preview_math;
mod quick_export;
mod session_items;

pub use format_text::{ExportSeconds, format_g};
pub use model::{
    CutDownKey, ExportDialogEvent, ExportDialogModel, FormatEntry, FreeSpaceProvider, OutputRow, PreviewSourceProvider,
    RangeSeconds, SelectedClipRange, SequenceItem, SourceProvider, StemAudioProvider,
};
pub use model_jobs::{AudioCheckOutcome, AudioCheckRequest, StemExportOutcome, StemExportRequest};
pub use preflight_report::{ExportPreflightReport, Report, UntrackedMagicFrames};
pub use preview_math::ExportPreviewMath;
pub use quick_export::QuickExport;

#[cfg(test)]
mod tests;
