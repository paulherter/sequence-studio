// Swift: ShellLibraryImport.swift
//! File > Import Lottie Animation…, Import Motion Graphics Template… and Import Premiere Presets… on the shared shell (the
//! Mac `AppController+Lottie`, `+TemplateImport`, `+PremierePresets`; the reading is `library_imports`, shared with them).
//! The file chooser takes one file at a time (`ShellFilePicker::choose_file`), like Swift's `chooseAndImportTemplate`
//! (`chooseFile`); dropping several files on the window imports all.

use crate::library_imports;
use crate::shell_flow_env::ShellTool;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost};
use crate::shell_platform_text::ShellPlatformText;
use sq_editor_session::EditorSession;
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use std::path::{Path, PathBuf};

fn file_name(url: &Path) -> String {
    url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

impl ShellHost {
    /// File > Import Lottie / Motion Graphics Template / Premiere Presets.
    pub(crate) fn run_library_import_command(&mut self, _cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        let tool = match c {
            C::ImportLottie => ShellTool::ChooseAndImportLottie,
            C::ImportMotionGraphicsTemplate => ShellTool::ChooseAndImportTemplate,
            C::ImportPremierePresets => ShellTool::ChooseAndImportPresets,
            _ => return false,
        };
        self.start_flow(ShellFlow::Tool(tool));
        true
    }

    /// Choose a Lottie animation, then place it.
    pub async fn choose_and_import_lottie<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| {
            r.shell_parts().files.choose_file(
                &SQL10n::string("Choose a Lottie animation (.json). It is stored inside the project."),
                None,
            )
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            p.shell.import_lottie(p.session, &url);
        });
    }

    /// Places a Lottie .json at the playhead; a file that cannot be used says why (the Mac alert).
    pub fn import_lottie(&mut self, session: &mut EditorSession, url: &Path) {
        let added = session.add_lottie_clip_file(url, None, None);
        if added.is_none()
            && let Some(message) = session.last_error().map(str::to_string)
        {
            self.present_message(&SQL10n::format("Could not import “%@”", &[&file_name(url)]), &message, None);
        }
    }

    /// Reads a subtitle file onto the caption track (one undo step); the count or the reason goes to the status line.
    pub fn import_subtitles(&mut self, session: &mut EditorSession, url: &Path) {
        let extension = url.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
        let format = sq_transcribe::subtitle_reader::SubtitleReader::format_for_extension(&extension)
            .unwrap_or(sq_transcribe::subtitle_reader::Format::Srt);
        let Ok(data) = std::fs::read(url) else {
            self.flash(&SQL10n::string("Could not open the subtitle file."));
            return;
        };
        let line = match session.import_srt(&data, format) {
            Some(n) => {
                SQL10n::plural(i64::try_from(n).unwrap_or(i64::MAX), "Imported %@ caption.", "Imported %@ captions.")
            }
            None => session
                .last_error()
                .map_or_else(|| SQL10n::string("Could not import the subtitle file."), str::to_string),
        };
        self.flash(&line);
    }

    /// Choose a Motion Graphics Template, then import it.
    pub async fn choose_and_import_template<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| {
            r.shell_parts().files.choose_file(&SQL10n::string("Choose Motion Graphics Template files (.mogrt)"), None)
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        Self::import_motion_graphics_templates(h, vec![url]).await;
    }

    /// Reads `.mogrt` files into the library as title templates.
    /// pending: the template capture of Swift's `MogrtImporter.read` (SQPremiereImport) is not in the Rust importer yet, so
    /// `ShellServices::read_mogrt` provides it; the default says the file cannot be read.
    pub async fn import_motion_graphics_templates<R: ShellRoot + ?Sized>(h: UiRef<R>, urls: Vec<PathBuf>) {
        let card = h.with(|r| {
            let p = r.shell_parts();
            let now = p.shell.wall_now();
            let services = &mut p.shell.flow_env.services;
            let reads: Vec<_> = urls.iter().map(|u| (u.clone(), services.read_mogrt(u))).collect();
            let Some(store) = services.preset_store() else {
                p.shell.flash(ShellPlatformText::not_available());
                return None;
            };
            let out = library_imports::import_mogrts(reads, store, &mut *p.shell.ids, now);
            if out.added > 0 {
                p.shell.emit(ShellEvent::PresetsChanged);
            }
            if let Some(line) = out.status_line() {
                p.shell.emit(ShellEvent::Status(line));
            }
            if let (Some(first), Some(title)) = (out.failures.first(), out.failure_title()) {
                p.shell.present_message(&title, &first.1, Some(crate::shell_dialog::Tone::Error));
            } else if out.added > 0 && out.dropped > 0 {
                let name = if urls.len() == 1 {
                    file_name(&urls[0])
                } else {
                    SQL10n::format("%@ templates", &[&urls.len().to_string()])
                };
                return Some((out.report, name));
            }
            None
        });
        if let Some(Some((report, name))) = card {
            Self::show_import_report(h, report, name).await;
        }
    }

    /// Choose a Premiere preset file, then import it.
    pub async fn choose_and_import_presets<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let start = std::env::var_os("HOME")
            .map(PathBuf::from)
            .and_then(|home| library_imports::premiere_preset_files(&home).into_iter().next())
            .and_then(|f| f.parent().map(Path::to_path_buf));
        let Some(ask) = h.with(|r| {
            r.shell_parts()
                .files
                .choose_file(&SQL10n::string("Choose a Premiere Pro effect preset file (.prfpset)"), start.as_deref())
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        Self::import_premiere_presets(h, url, true).await;
    }

    /// Reads a Premiere effect preset file into the user preset library and says what happened.
    pub async fn import_premiere_presets<R: ShellRoot + ?Sized>(h: UiRef<R>, url: PathBuf, show_report: bool) {
        let card = h.with(|r| {
            let p = r.shell_parts();
            let now = p.shell.wall_now();
            let name = file_name(&url);
            let Some(store) = p.shell.flow_env.services.preset_store() else {
                if show_report {
                    p.shell.flash(ShellPlatformText::not_available());
                }
                return None;
            };
            match library_imports::import_premiere_presets(&url, store, &mut *p.shell.ids, now) {
                Ok(out) => {
                    p.shell.emit(ShellEvent::PresetsChanged);
                    p.shell.emit(ShellEvent::Status(out.status_line(&name)));
                    if show_report && !out.report.entries().is_empty() {
                        return Some((out.report, name));
                    }
                }
                Err(e) => {
                    if show_report {
                        p.shell.present_error(&SQL10n::format("Could not import “%@”", &[&name]), &e);
                    }
                }
            }
            None
        });
        if let Some(Some((report, name))) = card {
            Self::show_import_report(h, report, name).await;
        }
    }
}
