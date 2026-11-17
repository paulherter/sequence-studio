// Swift: SQAppShell/CaptionsHost.swift (onImportSRT, onExportSRT)
//! Import Subtitles and Export SRT of the Captions menu: the host picks the file, the panel reads or the writer renders.

use sq_app_shell::{AppEvent, HostCx};
use sq_export::formats::{RangeSelection, SrtCue, SrtWriter};
use sq_inspector_ui::captions::captions_tab_draw::CaptionsTabDraw;
use sq_uikit::localization::SQL10n;

/// What the Captions menu asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SrtAsk {
    Import,
    Export,
}

/// Runs one ask: the chooser of the platform, then the read or write. Every outcome ends in a status line (a canceled
/// chooser says nothing).
pub(super) fn run(ask: SrtAsk, captions: &mut CaptionsTabDraw, cx: &mut HostCx) {
    match ask {
        SrtAsk::Import => {
            let Some(path) = cx.services.panel_files.choose_subtitles() else { return };
            match std::fs::read(&path) {
                Ok(data) => {
                    let ext = path.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
                    captions.import_subtitles(cx.session, &data, &ext);
                }
                Err(_) => cx.emit(AppEvent::Status(SQL10n::string("Could not open the subtitle file."))),
            }
        }
        SrtAsk::Export => {
            let cues: Vec<SrtCue> = CaptionsTabDraw::export_items(cx.session)
                .into_iter()
                .map(|i| SrtCue { lines: i.lines, range: i.range })
                .collect();
            if cues.is_empty() {
                cx.emit(AppEvent::Status(SQL10n::string("There are no captions to export.")));
                return;
            }
            let name = cx.session.active_timeline().map_or("Captions", |t| t.name.as_str()).to_string() + ".srt";
            let Some(path) = cx.services.panel_files.choose_srt_location(&name) else { return };
            let line = match std::fs::write(&path, SrtWriter::render(&cues, RangeSelection::EntireSequence)) {
                Ok(()) => SQL10n::plural(
                    i64::try_from(cues.len()).unwrap_or(i64::MAX),
                    "Exported %@ caption.",
                    "Exported %@ captions.",
                ),
                Err(e) => SQL10n::format("Could not write the SRT file: %@", &[&e.to_string()]),
            };
            cx.emit(AppEvent::Status(line));
        }
    }
}
