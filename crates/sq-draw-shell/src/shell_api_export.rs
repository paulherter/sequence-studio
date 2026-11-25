//! The edit API's export: the Export sheet's own model and queue without the sheet. The settings come from the same
//! `ExportDialogModel` the sheet drives (preset, range, file name), so the file is what the button would write; the
//! sheet's remembered choices are read but never changed by an API export.

use crate::shell_export::ShellExport;
use crate::shell_host::{FlowReply, ShellEvent, ShellHost};
use crate::shell_flows::ShellRoot;
use sq_core_time::{Id, Time};
use sq_editor_session::EditorSession;
use sq_export::core::queue::ExportJobStatus;
use sq_runtime::UiRef;
use std::path::PathBuf;

/// Which part an API export writes.
#[derive(Clone, Debug, PartialEq)]
pub enum ApiExportRange {
    /// The whole sequence.
    Entire,
    /// In to Out.
    InOut,
    /// Start to end.
    Custom { start: Time, end: Time },
}

/// What `POST /v1/export` asks for.
#[derive(Clone, Debug, PartialEq)]
pub struct ApiExportRequest {
    /// None = the open sequence.
    pub sequence: Option<Id>,
    /// The file to write (absolute).
    pub file: PathBuf,
    /// A preset id (None = what the sheet proposes).
    pub preset: Option<String>,
    /// The part.
    pub range: ApiExportRange,
}

/// The id the API uses for the TikTok 9:16 H.264 preset (the app's `tiktok-h264`).
pub const TIKTOK_ALIAS: &str = "tiktok-9x16";

impl ShellHost {
    /// The presets the Export sheet offers on this machine: (id, name).
    pub fn api_export_presets(&self) -> Vec<(String, String)> {
        ShellExport::presets(&self.export.codecs, self.export.file_outputs)
            .into_iter()
            .map(|p| (p.id(), p.name()))
            .collect()
    }

    /// The queue status of one export job.
    pub fn api_export_status(&self, id: Id) -> Option<ExportJobStatus> {
        self.export.queue.as_ref()?.status(id)
    }

    /// Builds the export like the sheet would (loudness normalization off), queues it and asks the app to run the queue.
    /// The job ids on success; the reason otherwise.
    pub fn api_export(&mut self, session: &EditorSession, r: &ApiExportRequest) -> Result<Vec<Id>, String> {
        let Some(queue) = self.export.queue.clone() else { return Err("export is not available".into()) };
        let Some(mut model) = self.prepare_export_model(session) else {
            return Err("export is not available, or the project has no sequence".into());
        };
        let wanted = r.sequence.or_else(|| session.active_timeline_id());
        if let Some(id) = wanted {
            if !model.sequences().iter().any(|s| s.id == id) {
                return Err("no such sequence".into());
            }
            model.set_selected_id(id);
            model.set_checked_ids([id].into_iter().collect());
        }
        if let Some(wanted) = &r.preset {
            let id = if wanted == TIKTOK_ALIAS { "tiktok-h264" } else { wanted.as_str() };
            if !self.api_export_presets().iter().any(|(p, _)| p == id) {
                return Err(format!("unknown preset '{wanted}': read GET /v1/presets"));
            }
            model.set_preset_id(id);
        }
        // One file, whatever the sheet remembered.
        model.set_one_file_per_clip(false);
        model.set_export_all_formats(false);
        match &r.range {
            ApiExportRange::Entire => model.set_range_mode(0),
            ApiExportRange::InOut => {
                if !model.can_use_in_out() {
                    return Err("the sequence has no In/Out marks".into());
                }
                model.set_range_mode(1);
            }
            ApiExportRange::Custom { start, end } => {
                let secs = |t: &Time| t.value() as f64 / t.timescale() as f64;
                model.set_range_mode(2);
                model.set_custom_range(Some(secs(start)), Some(secs(end)));
            }
        }
        // Loudness normalization stays off for API exports.
        model.set_normalize_loudness(false);
        let (Some(dir), Some(stem)) = (r.file.parent(), r.file.file_stem().and_then(|s| s.to_str())) else {
            return Err("path has no folder or file name".into());
        };
        let ext = model.settings().file_extension();
        let given = r.file.extension().and_then(|e| e.to_str()).unwrap_or("");
        if !ext.is_empty() && !given.eq_ignore_ascii_case(ext) {
            return Err(format!("the preset writes .{ext} files: path must end in .{ext}"));
        }
        model.set_file_name(stem);
        if model.file_name() != stem {
            return Err("the file name has characters a file name cannot have".into());
        }
        model.set_output_directory(Some(dir.to_path_buf()));
        let problems = model.validation_messages();
        if !problems.is_empty() {
            return Err(problems.join(" "));
        }
        std::fs::create_dir_all(dir).map_err(|e| format!("could not create the folder: {e}"))?;
        let ids = model.submit(&queue, dir, true);
        if ids.is_empty() {
            return Err("nothing to export".into());
        }
        self.emit(ShellEvent::RunExportQueue);
        Ok(ids)
    }

    /// The flow of `ShellFlow::ApiExport`.
    pub(crate) async fn api_export_flow<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        request: ApiExportRequest,
        reply: FlowReply<Result<Vec<Id>, String>>,
    ) {
        let answer = h
            .with(|r| {
                let p = r.shell_parts();
                p.shell.api_export(p.session, &request)
            })
            .unwrap_or_else(|| Err("the app is closing".into()));
        reply.send(answer);
    }
}
