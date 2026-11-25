// Swift: ShellHost.swift (the async methods: `ask`, `confirmDiscardChanges`, `newProject`, `chooseAndOpenProject`,
// `openProject`, `saveDocument`, `saveDocumentAs`, `saveDocumentCopy`, `revert`, `closeProject`)
//! The flows of the shell that wait for a dialog or a file chooser. Each synchronous stretch runs inside `h.with(..)`;
//! nothing is borrowed across an `.await`, and a vanished root ends the flow (Swift's `[weak self]` was nil).

use crate::shell_dialog::ShellDialog;
use crate::shell_file_picker::ShellFilePicker;
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use sq_core_edit::project_open_routing::{ProjectOpenRoute, message, open_route};
use sq_core_file::{FILE_EXTENSION, ProjectFileError};
use sq_core_model::ThreePointMode;
use sq_editor_session::{EditorSession, PlaceOptions, ProjectPanelRoot, SaveError, SessionRoot};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::save_changes_prompt::{SaveChangesPrompt, SaveChoice, SaveOutcome};
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::path::{Path, PathBuf};

/// Disjoint borrows of what a shell flow needs from the app root.
pub struct ShellParts<'a> {
    /// The session.
    pub session: &'a mut EditorSession,
    /// The shell.
    pub shell: &'a mut ShellHost,
    /// The platform's file choosers.
    pub files: &'a mut dyn ShellFilePicker,
}

/// What the shell flows need from the app root; the app implements it next to `SessionRoot`.
pub trait ShellRoot: SessionRoot + ProjectPanelRoot {
    /// The session, the shell and the platform choosers, borrowed together.
    fn shell_parts(&mut self) -> ShellParts<'_>;
}

impl ShellFlow {
    /// What a file drop on the window runs (the Mac `SharedUIController.drop`): the first Sequence Studio project among the
    /// files is opened and never imported as media; anything else goes through File > Import's sorting. `None` for no files.
    pub fn for_drop(urls: Vec<PathBuf>) -> Option<ShellFlow> {
        use sq_core_edit::project_open_routing::route;
        if let Some(project) = urls.iter().find(|u| route(u) == ProjectOpenRoute::SequenceStudioProject) {
            return Some(ShellFlow::OpenProject(project.clone()));
        }
        (!urls.is_empty()).then_some(ShellFlow::ImportMixed(urls))
    }
}

impl ShellHost {
    /// Runs a flow the host started ([`ShellHost::take_flows`]).
    pub async fn run_flow<R: ShellRoot + ?Sized>(h: UiRef<R>, flow: ShellFlow) {
        match flow {
            ShellFlow::PlaceMedia { ids, options } => {
                Self::place_media_asking(h, ids, options).await;
            }
            ShellFlow::NewProjectForm => Self::new_project_form(h).await,
            ShellFlow::ChooseAndOpenProject => Self::choose_and_open_project(h).await,
            ShellFlow::OpenProject(url) => Self::open_project(h, url).await,
            ShellFlow::Save => {
                Self::save_document(h).await;
            }
            ShellFlow::SaveAs => {
                Self::save_document_as(h).await;
            }
            ShellFlow::SaveCopy => {
                Self::save_document_copy(h).await;
            }
            ShellFlow::Revert => Self::revert(h).await,
            ShellFlow::CloseProject => Self::close_project(h).await,
            ShellFlow::Quit => {
                // A second close request (a second Alt+F4) while the question is up must not replace it.
                if h.with(|r| r.shell_parts().shell.dialog().is_some_and(|d| d.asks_to_save)).unwrap_or(false) {
                    return;
                }
                if Self::confirm_discard_changes(h.clone()).await {
                    let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::Quit));
                }
            }
            ShellFlow::SaveWorkspaceAs => Self::save_workspace_as(h).await,
            ShellFlow::RenameWorkspace => Self::rename_workspace(h).await,
            ShellFlow::DeleteWorkspace => Self::delete_workspace(h).await,
            ShellFlow::History => Self::show_history(h).await,
            ShellFlow::SaveCheckpoint => Self::save_checkpoint(h).await,
            ShellFlow::CreateAngles { clips, name, sync, sound, follows } => {
                Self::create_angles(h, clips, name, sync, sound, follows).await;
            }
            ShellFlow::ImportAnything => Self::import_anything(h).await,
            ShellFlow::PasteSettings => Self::paste_settings(h).await,
            ShellFlow::PunchInCuts => Self::punch_in_cuts(h).await,
            ShellFlow::NewSequence => Self::new_sequence(h).await,
            ShellFlow::SequenceSettings => Self::sequence_settings(h).await,
            ShellFlow::ProjectNotes => Self::project_notes(h).await,
            ShellFlow::EditMarker(id) => {
                Self::edit_marker(h, id, None).await;
            }
            ShellFlow::GoToTimecode => Self::go_to_timecode(h).await,
            ShellFlow::Tone { editing } => Self::tone_dialog(h, editing).await,
            ShellFlow::ImportMixed(urls) => Self::import_mixed(h, urls).await,
            ShellFlow::ApiImport { urls, reply } => Self::api_import(h, urls, reply).await,
            ShellFlow::ApiExport { request, reply } => Self::api_export_flow(h, request, reply).await,
            ShellFlow::ApiSyncFit { clip, to, reply } => Self::api_sync_fit(h, clip, to, reply).await,
            ShellFlow::PlaceFiles(urls) => Self::place_files(h, urls, PlaceOptions::default()).await,
            ShellFlow::PlaceFilesAt { urls, at, track, new_track, insert } => {
                let mode = if insert { ThreePointMode::Insert } else { ThreePointMode::Overwrite };
                let options =
                    PlaceOptions { at: Some(at), video_track: track, new_track, mode, ..PlaceOptions::default() };
                Self::place_files(h, urls, options).await;
            }
            ShellFlow::ShowPreferences => Self::show_preferences(h).await,
            ShellFlow::ShowPreferencesAt(page, search) => Self::show_preferences_at(h, Some(page), search).await,
            ShellFlow::ShowExport => Self::show_export(h).await,
            ShellFlow::QuickExport => Self::quick_export(h).await,
            ShellFlow::Welcome => Self::show_welcome(h).await,
            ShellFlow::ImportProject => Self::import_project_as_bin(h).await,
            ShellFlow::Project(a) => Self::run_project_flow(h, a).await,
            ShellFlow::LocateRecent(url) => Self::locate_recent(h, url).await,
            ShellFlow::QuickCreate(id) => Self::quick_create(h, id, false).await,
            ShellFlow::CreateNamed(id) => Self::quick_create(h, id, true).await,
            ShellFlow::RenameTemplate(id) => Self::rename_template(h, id).await,
            ShellFlow::DeleteTemplate(id) => Self::delete_template(h, id).await,
            ShellFlow::Shortcuts(f) => Self::shortcuts_flow(h, f).await,
            ShellFlow::StopExport(id) => {
                Self::stop_export(h, id).await;
            }
            ShellFlow::ExportFinished(done) => Self::present_export_finished(h, done).await,
            ShellFlow::ImportCard => Self::import_card_flow(h).await,
            ShellFlow::SaveImportReport(report, name) => Self::save_import_report(h, report, name).await,
            ShellFlow::ShowAbout => Self::show_about(h).await,
            ShellFlow::CheckForUpdates => Self::check_for_updates(h).await,
            ShellFlow::AppMenuRemove => Self::app_menu_remove_flow(h).await,
            ShellFlow::AppMenuDone(outcome) => Self::app_menu_done_flow(h, outcome).await,
            ShellFlow::Tool(tool) => Self::run_tool(h, tool).await,
        }
    }

    /// Shows `d` modally and waits for the answer. `None` when the root is gone.
    pub async fn ask<R: ShellRoot + ?Sized>(h: &UiRef<R>, d: ShellDialog) -> Option<SQDialogResponse> {
        let ask = h.with(|r| r.shell_parts().shell.present(d))?;
        Some(ask.await)
    }

    /// The Save Changes question; Don't Save sits at the left in red (`dialogs.html` 01).
    pub(crate) fn save_changes_dialog(name: &str, has_file: bool) -> ShellDialog {
        let mut d =
            ShellDialog::new(&SQL10n::format("Save changes to “%@”?", &[name]), SaveChangesPrompt::detail(has_file));
        d.asks_to_save = true;
        for b in SaveChangesPrompt::buttons() {
            d.add_button(&b.title, b.role, b.is_leading());
        }
        d
    }

    /// Asks before the project in the window is replaced. True to go on.
    pub async fn confirm_discard_changes<R: ShellRoot + ?Sized>(h: UiRef<R>) -> bool {
        let Some(dialog) = h.with(|r| {
            let p = r.shell_parts();
            if !p.session.is_dirty() {
                return None;
            }
            Some(Self::save_changes_dialog(&p.session.display_name(), p.session.file_url().is_some()))
        }) else {
            return false;
        };
        let Some(d) = dialog else { return true };
        let Some(answer) = Self::ask(&h, d).await else { return false };
        let choice = SaveChangesPrompt::choice(answer);
        let saved = if choice == SaveChoice::Save { Some(Self::save_document(h).await) } else { None };
        SaveChangesPrompt::outcome(choice, saved) == SaveOutcome::Proceed
    }

    // MARK: Project files

    /// File > Open Project: the chooser, then `open_project`.
    pub async fn choose_and_open_project<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| r.shell_parts().files.choose_project()) else { return };
        let Some(url) = ask.await else { return };
        Self::open_project(h, url).await;
    }

    /// Opens the project file at `url` in the session and tells the shell (no question, no dialog): what the flow below does
    /// once the unsaved changes are settled, and what the edit API's `/v1/open` calls.
    pub fn open_project_now(p: ShellParts<'_>, url: &Path) -> Result<(), Box<dyn std::error::Error>> {
        sq_core_time::milestones::begin("project open begins");
        match p.session.open(url) {
            Ok(_) => {
                sq_core_time::milestones::mark("session open returned");
                crate::shell_log::info(&format!("open project: opened {}", url.display()));
                p.shell.emit(ShellEvent::ProjectChanged);
                p.shell.project_opened(p.session);
                Ok(())
            }
            Err(e) => {
                crate::shell_log::error(&format!("open project: failed {}: {e}", url.display()));
                Err(e)
            }
        }
    }

    /// Saves the open project (`target` None) or saves it as `target`, without asking or showing a dialog: what the edit
    /// API's `/v1/save` calls. Returns the file written, or the error text.
    pub fn save_now(p: ShellParts<'_>, target: Option<&Path>) -> Result<PathBuf, String> {
        let url = match target {
            Some(t) => {
                p.session.save_as(t).map_err(|e| e.to_string())?;
                t.to_path_buf()
            }
            None => {
                let url = p.session.file_url().map(Path::to_path_buf).ok_or("the project has no file yet")?;
                p.session.save().map_err(|e| e.to_string())?;
                url
            }
        };
        p.shell.note_recent(&url);
        p.shell.emit(ShellEvent::ProjectChanged);
        Ok(url)
    }

    /// Opens the project at `url`; a Premiere project is imported instead.
    pub async fn open_project<R: ShellRoot + ?Sized>(h: UiRef<R>, url: PathBuf) {
        crate::shell_log::info(&format!("open project: {}", url.display()));
        match open_route(&url) {
            ProjectOpenRoute::PremiereImport => {
                Self::import_premiere_project(h, url).await;
                return;
            }
            // Open With / the Dock / the command line handed over a video, sound or picture: it goes into the open
            // project (an untitled one when none is open), like a drop on the window.
            ProjectOpenRoute::MediaImport => {
                Self::import_mixed(h, vec![url]).await;
                return;
            }
            ProjectOpenRoute::SequenceStudioProject | ProjectOpenRoute::Unsupported => {}
        }
        if !Self::confirm_discard_changes(h.clone()).await {
            crate::shell_log::info("open project: canceled at the unsaved changes question");
            return;
        }
        let ran = h.with(|r| {
            let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if let Err(e) = Self::open_project_now(r.shell_parts(), &url) {
                let known = e.downcast_ref::<ProjectFileError>().and_then(|pfe| message(pfe, &name, url.exists()));
                match known {
                    Some((title, detail)) => r.shell_parts().shell.present_message(&title, &detail, None),
                    None => r.shell_parts().shell.present_error(&SQL10n::format("Could not open “%@”", &[&name]), &*e),
                }
            }
        });
        if ran.is_none() {
            crate::shell_log::error(&format!("open project: the app is gone, {} not opened", url.display()));
        }
    }

    /// Save, or Save As for an untitled project. False when the user canceled or saving failed.
    pub async fn save_document<R: ShellRoot + ?Sized>(h: UiRef<R>) -> bool {
        let Some(url) = h.with(|r| r.shell_parts().session.file_url().map(Path::to_path_buf)) else { return false };
        let Some(url) = url else { return Self::save_document_as(h).await };
        let saved = h
            .with(|r| {
                let p = r.shell_parts();
                match p.session.save() {
                    Ok(()) => {
                        p.shell.note_recent(&url);
                        true
                    }
                    Err(e) => {
                        if !Self::reported_silently(&*e) {
                            p.shell.present_error("Could not save", &*e);
                        }
                        false
                    }
                }
            })
            .unwrap_or(false);
        if saved {
            Self::trash_moved_originals(h).await;
        }
        saved
    }

    /// Save As: asks for the place, then writes there.
    pub async fn save_document_as<R: ShellRoot + ?Sized>(h: UiRef<R>) -> bool {
        let Some(url) = Self::choose_save_url(&h, "", "Save").await else { return false };
        h.with(|r| {
            let p = r.shell_parts();
            match p.session.save_as(&url) {
                Ok(()) => {
                    p.shell.note_recent(&url);
                    p.shell.emit(ShellEvent::ProjectChanged);
                    true
                }
                Err(e) => {
                    if !Self::reported_silently(&*e) {
                        p.shell.present_error("Could not save", &*e);
                    }
                    false
                }
            }
        })
        .unwrap_or(false)
    }

    /// Save a Copy: writes the project somewhere as a new document; this window keeps its file and unsaved changes.
    pub async fn save_document_copy<R: ShellRoot + ?Sized>(h: UiRef<R>) -> bool {
        let Some(url) = Self::choose_save_url(&h, " copy", "Save a Copy").await else { return false };
        h.with(|r| {
            let p = r.shell_parts();
            match p.session.save_copy(&url) {
                Ok(()) => true,
                Err(e) => {
                    if !Self::reported_silently(&*e) {
                        p.shell.present_error("Could not save a copy", &*e);
                    }
                    false
                }
            }
        })
        .unwrap_or(false)
    }

    /// The save chooser with the project's name plus `suffix`; the extension is added when the user dropped it.
    async fn choose_save_url<R: ShellRoot + ?Sized>(h: &UiRef<R>, suffix: &str, prompt: &str) -> Option<PathBuf> {
        let ask = h.with(|r| {
            let p = r.shell_parts();
            // A repaired copy suggests the damaged file's own name: saving there keeps the old file as `.damaged.bak`.
            let base = match p.session.salvaged_from().and_then(|f| f.file_stem()) {
                Some(stem) => stem.to_string_lossy().into_owned(),
                None => p.session.project().name.clone(),
            };
            let suggested = format!("{base}{suffix}.{FILE_EXTENSION}");
            p.files.choose_save_location(&suggested, prompt)
        })?;
        let mut url = ask.await?;
        if url.extension().and_then(|e| e.to_str()) != Some(FILE_EXTENSION) {
            let mut name = url.as_os_str().to_os_string();
            name.push(".");
            name.push(FILE_EXTENSION);
            url = PathBuf::from(name);
        }
        Some(url)
    }

    /// The user opened another project while saving: no dialog, one log line (the log waits for the Rust logger).
    fn reported_silently(error: &(dyn std::error::Error + 'static)) -> bool {
        error.downcast_ref::<SaveError>() == Some(&SaveError::ProjectChanged)
    }

    /// File > Revert: back to the last saved version.
    pub async fn revert<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(d)) = h.with(|r| {
            let p = r.shell_parts();
            if p.session.file_url().is_none() || !p.session.is_dirty() {
                return None;
            }
            let mut d = ShellDialog::new(
                &SQL10n::format("Revert to the last saved version of “%@”?", &[&p.session.display_name()]),
                "Your changes since the last save will be lost.",
            );
            d.add_button("Revert", SQDialogRole::Destructive, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some(d)
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(url) = p.session.file_url().map(Path::to_path_buf) else { return };
            match p.session.open(&url) {
                Ok(_) => {
                    p.shell.emit(ShellEvent::ProjectChanged);
                    p.shell.project_opened(p.session);
                }
                Err(e) => p.shell.present_error("Could not revert", &*e),
            }
        });
    }

    /// File > Close Project.
    pub async fn close_project<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        if !Self::confirm_discard_changes(h.clone()).await {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            p.session.close_project();
            p.shell.emit(ShellEvent::ProjectChanged);
        });
    }
}

#[cfg(test)]
mod drop_tests {
    use super::*;

    fn paths(names: &[&str]) -> Vec<PathBuf> {
        names.iter().map(PathBuf::from).collect()
    }

    #[test]
    fn a_dropped_project_is_opened_never_imported() {
        assert_eq!(
            ShellFlow::for_drop(paths(&["/a/clip.mov", "/b/Film.sqproj", "/c/Other.SSPROJ"])),
            Some(ShellFlow::OpenProject(PathBuf::from("/b/Film.sqproj")))
        );
    }

    #[test]
    fn dropped_media_and_other_files_are_imported_and_nothing_is_nothing() {
        let urls = paths(&["/a/clip.mov", "/a/Cut.prproj"]);
        assert_eq!(ShellFlow::for_drop(urls.clone()), Some(ShellFlow::ImportMixed(urls)));
        assert_eq!(ShellFlow::for_drop(Vec::new()), None);
    }
}
