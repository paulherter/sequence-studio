// Swift: ShellInterchange.swift
//! File > Import Timeline… and File > Export EDL… / Final Cut Pro XML… / FCPXML… / OpenTimelineIO… (the Mac
//! `AppController+Interchange`, `InterchangeExportSheet`, `OTIOScopeSheet`) on the portable readers and writers.
//! Import opens the result as a new untitled project like the Premiere import; the source file is never modified.

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use sq_core_project::media_path_resolver::MediaPathResolver;
use sq_core_time::Time;
use sq_export::formats::{
    EdlWriter, FcpxmlTarget, FcpxmlVersion, FcpxmlWriter, InterchangeExport, InterchangeExportError, OtioScope,
    OtioWriter, XmemlWriter, layer_files,
};
use sq_premiere_import::interchange_model::{IXSequence, InterchangeMapper, InterchangeReader};
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The Mac sheets' remembered choices (same keys, so both shells share them).
pub(crate) const FCPXML_VERSION_KEY: &str = "sq.export.fcpxmlVersion";
pub(crate) const FCPXML_TARGET_KEY: &str = "sq.export.fcpxmlTarget";
pub(crate) const OTIO_SCOPE_KEY: &str = "sq.export.otioScope";
const FCPXML_TARGET_TITLES: [&str; 2] = ["DaVinci Resolve", "Final Cut Pro"];
const FCPXML_VERSIONS: [FcpxmlVersion; 3] = [FcpxmlVersion::V1_8, FcpxmlVersion::V1_10, FcpxmlVersion::V1_13];
const FCPXML_TARGETS: [(FcpxmlTarget, &str); 2] =
    [(FcpxmlTarget::Resolve, "resolve"), (FcpxmlTarget::FinalCut, "finalCut")];
const OTIO_SCOPES: [(OtioScope, &str); 2] =
    [(OtioScope::ActiveSequence, "activeSequence"), (OtioScope::AllSequences, "allSequences")];

/// One interchange file to write: the main text plus EDL layer files ("Name V2.edl" next to it).
pub(crate) struct InterchangeFile {
    pub ext: &'static str,
    pub label: &'static str,
    pub main: InterchangeExport,
    /// File name suffix (" V2") and the layer's file.
    pub extras: Vec<(String, InterchangeExport)>,
}

/// An import error as a message (the reader errors have no `Display` of their own).
#[derive(Debug)]
pub(crate) struct ImportFailure(pub String);

impl std::fmt::Display for ImportFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ImportFailure {}

fn file_name(url: &Path) -> String {
    url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

impl ShellHost {
    /// The FCPXML form: version and target, preset from the remembered choice. `None` = canceled.
    async fn ask_fcpxml_options<R: ShellRoot + ?Sized>(h: &UiRef<R>) -> Option<(FcpxmlVersion, FcpxmlTarget)> {
        let d = h.with(|r| {
            let p = r.shell_parts();
            let v = p
                .shell
                .setting_string(FCPXML_VERSION_KEY)
                .and_then(|s| FCPXML_VERSIONS.iter().position(|v| v.raw() == s))
                .unwrap_or(FCPXML_VERSIONS.len() - 1); // design: the newest version (1.13) is the default
            let t = p
                .shell
                .setting_string(FCPXML_TARGET_KEY)
                .and_then(|s| FCPXML_TARGETS.iter().position(|t| t.1 == s))
                .unwrap_or(0);
            let form = ShellForm::new(vec![
                Row::Popup {
                    id: "version".into(),
                    label: "Version".into(),
                    options: FCPXML_VERSIONS.iter().map(|v| v.raw().to_string()).collect(),
                    selected: v as i64,
                },
                Row::popup("target", "Target", &FCPXML_TARGET_TITLES, t as i64),
            ]);
            let mut dlg = ShellDialog::new(
                "Export FCPXML",
                "Final Cut Pro 10.4 reads 1.8, 10.6 reads 1.10, 11 reads 1.13. DaVinci Resolve reads all three.",
            );
            dlg.width = 420.0;
            dlg.form = Some(Box::new(form));
            dlg.add_button("Export…", SQDialogRole::Default, false);
            dlg.add_button("Cancel", SQDialogRole::Cancel, false);
            dlg
        })?;
        if Self::ask(h, d).await != Some(SQDialogResponse::FIRST) {
            return None;
        }
        h.with(|r| {
            let p = r.shell_parts();
            let form = p.shell.take_answered_form()?;
            let pick = |id: &str, len: usize| usize::try_from(form.index(id).unwrap_or(0)).unwrap_or(0).min(len - 1);
            let version = FCPXML_VERSIONS[pick("version", FCPXML_VERSIONS.len())];
            let target = FCPXML_TARGETS[pick("target", FCPXML_TARGETS.len())];
            p.shell.store_setting_string(FCPXML_VERSION_KEY, version.raw());
            p.shell.store_setting_string(FCPXML_TARGET_KEY, target.1);
            Some((version, target.0))
        })
        .flatten()
    }

    /// The OpenTimelineIO scope; asked only when the project has more than one sequence. `None` = canceled.
    async fn ask_otio_scope<R: ShellRoot + ?Sized>(h: &UiRef<R>) -> Option<OtioScope> {
        let d = h.with(|r| {
            let p = r.shell_parts();
            if p.session.project().timelines.len() <= 1 {
                return None;
            }
            let saved = p
                .shell
                .setting_string(OTIO_SCOPE_KEY)
                .and_then(|s| OTIO_SCOPES.iter().position(|x| x.1 == s))
                .unwrap_or(0);
            let form = ShellForm::new(vec![Row::radio("scope", &["Open sequence", "All sequences"], saved as i64)]);
            let mut dlg = ShellDialog::new(
                "Export OpenTimelineIO",
                "All sequences are written to one file; importing it opens each of them as a sequence.",
            );
            dlg.width = 400.0;
            dlg.form = Some(Box::new(form));
            dlg.add_button("Export…", SQDialogRole::Default, false);
            dlg.add_button("Cancel", SQDialogRole::Cancel, false);
            Some(dlg)
        })?;
        let Some(d) = d else { return Some(OtioScope::ActiveSequence) };
        if Self::ask(h, d).await != Some(SQDialogResponse::FIRST) {
            return None;
        }
        h.with(|r| {
            let p = r.shell_parts();
            let form = p.shell.take_answered_form()?;
            let i = usize::try_from(form.index("scope").unwrap_or(0)).unwrap_or(0).min(OTIO_SCOPES.len() - 1);
            p.shell.store_setting_string(OTIO_SCOPE_KEY, OTIO_SCOPES[i].1);
            Some(OTIO_SCOPES[i].0)
        })
        .flatten()
    }

    /// Renders the file `c` asks for (after its options form); `None` = no sequence or canceled.
    async fn interchange_file<R: ShellRoot + ?Sized>(h: &UiRef<R>, c: EditorCommand) -> Option<InterchangeFile> {
        use EditorCommand as C;
        let has_sequence = h.with(|r| {
            let p = r.shell_parts();
            let has = p.session.active_timeline().is_some();
            if !has {
                p.shell.flash("There is no sequence to export.");
            }
            has
        })?;
        if !has_sequence {
            return None;
        }
        let render = |f: &dyn Fn(&sq_core_model::Timeline, &[sq_core_model::MediaRef]) -> InterchangeExport| {
            h.with(|r| {
                let s = r.shell_parts().session;
                s.active_timeline().map(|t| f(t, &s.project().media))
            })
            .flatten()
        };
        match c {
            C::ExportEDL => {
                let main = render(&|t, m| EdlWriter::render(t, m))?;
                let extras = h
                    .with(|r| {
                        let s = r.shell_parts().session;
                        s.active_timeline().map(|t| layer_files(t, &s.project().media)).unwrap_or_default()
                    })?
                    .into_iter()
                    .map(|(label, e)| (format!(" {label}"), e))
                    .collect();
                Some(InterchangeFile { ext: "edl", label: "EDL", main, extras })
            }
            C::ExportFinalCutXML => Some(InterchangeFile {
                ext: "xml",
                label: "Final Cut Pro XML",
                main: render(&|t, m| XmemlWriter::render(t, m))?,
                extras: Vec::new(),
            }),
            C::ExportFCPXML => {
                let (version, target) = Self::ask_fcpxml_options(h).await?;
                Some(InterchangeFile {
                    ext: "fcpxml",
                    label: "FCPXML",
                    main: render(&|t, m| FcpxmlWriter::render_as(t, m, version, target))?,
                    extras: Vec::new(),
                })
            }
            C::ExportOpenTimelineIO => {
                let scope = Self::ask_otio_scope(h).await?;
                let main = h.with(|r| {
                    let s = r.shell_parts().session;
                    OtioWriter::render_all(&scope.timelines(s.project()), &s.project().media)
                })?;
                Some(InterchangeFile { ext: "otio", label: "OpenTimelineIO", main, extras: Vec::new() })
            }
            _ => None,
        }
    }

    /// Writes `file` to `url` (and its layer files next to it); the status line the Mac shows.
    pub(crate) fn write_interchange(file: &InterchangeFile, url: &Path) -> Result<String, InterchangeExportError> {
        file.main.write_to(url)?;
        for (suffix, export) in &file.extras {
            let stem = url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            let dir = url.parent().map(Path::to_path_buf).unwrap_or_default();
            export.write_to(&dir.join(format!("{stem}{suffix}.{}", file.ext)))?;
        }
        let more = if file.extras.is_empty() {
            String::new()
        } else {
            format!(" {}", SQL10n::plural(file.extras.len() as i64, "Plus %@ layer file.", "Plus %@ layer files."))
        };
        let notes = if file.main.warnings.is_empty() {
            String::new()
        } else {
            let first: Vec<&str> = file.main.warnings.iter().take(2).map(String::as_str).collect();
            format!(" {}", SQL10n::format("%@ notes: %@", &[&file.main.warnings.len().to_string(), &first.join("; ")]))
        };
        Ok(SQL10n::format("Exported %@.", &[&file_name(url)]) + &more + &notes)
    }

    /// File > Export EDL / Final Cut Pro XML / FCPXML / OpenTimelineIO.
    pub async fn export_interchange<R: ShellRoot + ?Sized>(h: UiRef<R>, c: EditorCommand) {
        let Some(file) = Self::interchange_file(&h, c).await else { return };
        let Some(Some((name, ask))) = h.with(|r| {
            let p = r.shell_parts();
            let name = p.session.active_timeline()?.name.clone();
            let ask = p.files.choose_export_location(
                &format!("{name}.{}", file.ext),
                file.ext,
                &format!("Export {}", file.label),
            );
            Some((name, ask))
        }) else {
            return;
        };
        let _ = name;
        let Some(url) = ask.await else { return };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            match Self::write_interchange(&file, &url) {
                Ok(line) => p.shell.emit(ShellEvent::Status(line)),
                Err(e) => p.shell.emit(ShellEvent::Status(SQL10n::format(
                    "Could not write the %@ file: %@",
                    &[file.label, &SQL10n::error_text(&e)],
                ))),
            }
        });
    }

    /// Stored path if the file is there, else the same file name next to the interchange file or in a Reconnect folder.
    pub(crate) fn locate_interchange_media(
        paths: &[String],
        next_to: &Path,
        search_folders: &[PathBuf],
    ) -> BTreeMap<String, String> {
        let mut folders = vec![next_to.parent().map(Path::to_path_buf).unwrap_or_default()];
        folders.extend(search_folders.iter().cloned());
        let mut out = BTreeMap::new();
        for p in paths.iter().filter(|p| !p.is_empty()) {
            if Path::new(p).exists() {
                out.insert(p.clone(), p.clone());
                continue;
            }
            let name = MediaPathResolver::file_name_of(p);
            if name.is_empty() {
                continue;
            }
            if let Some(hit) = folders.iter().map(|f| f.join(&name)).find(|c| c.exists()) {
                out.insert(p.clone(), hit.to_string_lossy().into_owned());
            }
        }
        out
    }

    /// File > Import Timeline…: the chooser, then `import_timeline`.
    pub async fn choose_and_import_timeline<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| {
            r.shell_parts().files.choose_file(
                "Choose an EDL (.edl), Final Cut Pro XML (.xml), FCPXML (.fcpxml) or OpenTimelineIO (.otio) file",
                None,
            )
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        Self::import_timeline(h, url).await;
    }

    /// The Mac `importTimeline(at:)`: read every sequence, find the media, probe it, map, open; then the checklist.
    pub async fn import_timeline<R: ShellRoot + ?Sized>(h: UiRef<R>, url: PathBuf) {
        let Some(running) = h.with(|r| {
            let p = r.shell_parts();
            if p.shell.flow_env.import_running {
                p.shell.flash("An import is already running.");
                return true;
            }
            p.shell.flow_env.import_running = true;
            false
        }) else {
            return;
        };
        if running {
            return;
        }
        Self::run_import_timeline(h.clone(), &url).await;
        let _ = h.with(|r| r.shell_parts().shell.flow_env.import_running = false);
    }

    async fn run_import_timeline<R: ShellRoot + ?Sized>(h: UiRef<R>, url: &Path) {
        if !Self::confirm_discard_changes(h.clone()).await {
            return;
        }
        let name = file_name(url);
        let Some(Some((fd, folders))) = h.with(|r| {
            let p = r.shell_parts();
            p.shell.emit(ShellEvent::Status(SQL10n::format("Importing %@…", &[&name])));
            // An EDL has no frame rate: take the open sequence's.
            let fd = p.session.active_timeline().map_or(Time::new(1, 25), |t| t.format.frame_duration);
            let folders: Vec<PathBuf> = p
                .shell
                .setting_list(crate::shell_background_offers::RELINK_FOLDERS_KEY)
                .into_iter()
                .map(PathBuf::from)
                .collect();
            Some((fd, folders))
        }) else {
            return;
        };
        let stem = url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let ext = url.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        let read = move |url: PathBuf,
                         stem: String,
                         ext: String,
                         folders: Vec<PathBuf>|
              -> Result<(Vec<IXSequence>, BTreeMap<String, String>), ImportFailure> {
            let data = std::fs::read(&url).map_err(|e| ImportFailure(e.to_string()))?;
            let all = InterchangeReader::read_all(&data, &ext, &stem, fd).map_err(|e| ImportFailure(e.to_string()))?;
            let located = Self::locate_interchange_media(&InterchangeMapper::media_paths(&all), &url, &folders);
            Ok((all, located))
        };
        let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
        let read_result = match pool {
            Some(pool) => {
                let (u, s, e) = (url.to_path_buf(), stem.clone(), ext.clone());
                match pool.run(move |_| read(u, s, e, folders)).await {
                    Ok(r) => r,
                    Err(_) => return,
                }
            }
            // shortcut: the file is read on the UI thread when the app provides no worker pool.
            None => read(url.to_path_buf(), stem.clone(), ext.clone(), folders),
        };
        let (sequences, resolved) = match read_result {
            Ok(r) => r,
            Err(e) => {
                let _ = h.with(|r| {
                    r.shell_parts().shell.present_error(&SQL10n::format("Could not import “%@”", &[&name]), &e);
                });
                return;
            }
        };
        let mut refs = BTreeMap::new();
        for (stored, found) in &resolved {
            let Some(ask) = h.with(|r| r.shell_parts().shell.flow_env.services.probe(Path::new(found))).flatten()
            else {
                break;
            };
            if let Some(m) = ask.await {
                refs.insert(stored.clone(), m);
            }
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let result = InterchangeMapper::map(&sequences, Some(&stem), &refs, &mut *p.shell.ids);
            p.session.new_project(result.project);
            p.shell.emit(ShellEvent::ProjectChanged);
            let (approx, dropped) = Self::approximated_and_dropped(&result.report);
            p.shell.emit(ShellEvent::Status(SQL10n::format(
                "Imported %@: %@ approximated, %@ dropped items.",
                &[&name, &approx.to_string(), &dropped.to_string()],
            )));
            p.shell.remember_import(result.report.clone(), p.session.project(), &name);
            // The Mac shows the checklist when something needs a look, then offers Reconnect Media for what is missing.
            if approx + dropped > 0 || p.session.can_relink() {
                p.shell.start_flow(ShellFlow::ImportCard);
            }
        });
    }

    /// The approximated and dropped item counts of an import report.
    pub(crate) fn approximated_and_dropped(report: &sq_premiere_import::primport_report::PRImportReport) -> (i64, i64) {
        use sq_premiere_import::primport_report::Status;
        let sum = |s: Status| report.entries().iter().filter(|e| e.status == s).map(|e| e.count).sum::<i64>();
        (sum(Status::Approximated), sum(Status::Dropped))
    }
}
