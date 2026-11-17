// Swift: ShellMenuActions.swift (the `ShellAction` enum, `ShellMenuState` and the Style Kit chooser default live in
// shell_menu_bar.rs and shell_file_picker.rs)
//! The File > Project, Sequence > Format and New > Layer rows the Mac `AppController` runs from its own selectors
//! (AppController+Shapes, +ProjectColor, +StyleKit, +Relink, +ImportChecklist, SequenceSettingsSheet, PixelAspectMenuTarget),
//! translated to session calls the shell can make on any platform.

use crate::pending_steps::project_flow;
use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHooks, ShellHost};
use crate::shell_menu_bar::{ShellAction, ShellMenuState};
use sq_core_effects::style_kit::StyleKitFile;
use sq_core_model::{GraphicsLayer, MediaPolicy, OutsideMediaMode};
use sq_core_time::Time;
use sq_editor_session::{AppSettings, EditorSession};
use sq_media::media_file_ops::MediaManagement;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::SQDialogRole;

impl ShellHost {
    /// True when the row was handled here.
    pub(crate) fn perform_project(&mut self, cx: &mut ShellCx, a: &ShellAction) -> bool {
        match a {
            ShellAction::ProjectInputColor(space) => cx.session.set_project_input_color_space(*space),
            ShellAction::CollectFiles
            | ShellAction::ExportStyleKit
            | ShellAction::ImportStyleKit
            | ShellAction::ImportChecklist
            | ShellAction::ChangeFormat
            | ShellAction::DuplicateAsFormat
            | ShellAction::NewSequenceFromTemplate
            | ShellAction::SaveSequenceAsTemplate
            | ShellAction::CustomPixelAspect => self.start_flow(ShellFlow::Project(a.clone())),
            ShellAction::OutsideMedia(mode) => {
                let mode = *mode;
                Self::change_media_policy(cx.session, move |p| p.outside = Some(mode));
                self.flash(match mode {
                    OutsideMediaMode::Ask => "Files from outside the project folder: ask.",
                    OutsideMediaMode::Copy => "Files from outside the project folder: copy into project.",
                    OutsideMediaMode::Move => "Files from outside the project folder: move into project.",
                    OutsideMediaMode::Leave => "Files from outside the project folder: leave where it is.",
                });
            }
            ShellAction::ToggleCopyLibraryItems => {
                let defaults = cx.session.media_policy_defaults();
                let on = !cx
                    .session
                    .project()
                    .media_policy
                    .as_ref()
                    .and_then(|p| p.copy_library_items)
                    .unwrap_or(defaults.copy_library_items);
                Self::change_media_policy(cx.session, move |p| p.copy_library_items = Some(on));
            }
            ShellAction::ToggleWatchFolder => {
                // Stores the choice only, like Swift's `ShellMenuActions` (the shared UI has no project folder watcher there either).
                let on = !cx.session.project().media_policy.as_ref().and_then(|p| p.watch_folder).unwrap_or(false);
                Self::change_media_policy(cx.session, move |p| p.watch_folder = Some(on));
            }
            ShellAction::NewAdjustmentLayer => {
                if cx.session.active_timeline().is_none() {
                    self.flash("Open a sequence first.");
                    return true;
                }
                cx.session.stop_playback();
                if cx.session.add_adjustment_layer(None, None, Time::new(5, 1)).is_none() {
                    let line = cx.session.last_error().unwrap_or("Could not add the adjustment layer.").to_string();
                    self.flash(&line);
                } else {
                    cx.session.seek(cx.session.playhead());
                }
            }
            ShellAction::NewGraphicsClip => {
                if cx.session.active_timeline().is_none() {
                    self.flash("Open a sequence first.");
                    return true;
                }
                cx.session.stop_playback();
                if cx.session.add_graphics_clip(None, None, Time::new(5, 1), Vec::new(), false).is_none() {
                    let line = cx.session.last_error().unwrap_or("Could not add the graphic.").to_string();
                    self.flash(&line);
                } else {
                    cx.session.seek(cx.session.playhead());
                    self.dock.show(PanelID::Graphics);
                    self.sync_dock(&cx.measure);
                }
            }
            ShellAction::NewShape(kind) => {
                if cx.session.active_timeline().is_none() {
                    self.flash("Open a sequence first.");
                    return true;
                }
                // Hosts without the Create tool add a new Graphic with the kind's default box, as long as the stored
                // default text length (Preferences > Editing > New Text Length).
                if !cx.hooks.on_new_shape(*kind) {
                    cx.session.stop_playback();
                    let Some(f) = cx.session.active_timeline().map(|t| (t.format.width, t.format.height)) else {
                        return true;
                    };
                    let layer = GraphicsLayer::shape(&mut *cx.session.ids, *kind, f.0, f.1);
                    let seconds = AppSettings::load(&*self.defaults).default_text_seconds;
                    if cx.session.add_graphics_clip(None, None, Time::new(seconds, 1), vec![layer], true).is_none() {
                        let line = cx.session.last_error().unwrap_or("Could not add the graphic.").to_string();
                        self.flash(&line);
                    } else {
                        cx.session.seek(cx.session.playhead());
                    }
                }
            }
            ShellAction::UseKitCaptionStyle => {
                if !cx.session.use_kit_caption_style() {
                    self.flash("This project's style kit has no caption style. Import a style kit that has one.");
                }
            }
            ShellAction::RelinkMedia => {
                if !cx.session.can_relink() {
                    self.flash("All media is online.");
                } else {
                    self.start_flow(ShellFlow::Project(a.clone()));
                }
            }
            ShellAction::PixelAspect(p) => self.set_selection_pixel_aspect(cx.session, *p),
            _ => return false,
        }
        true
    }

    /// File > Project > Style Kit > Export: the chooser, then the `.sqstyle` file.
    pub(crate) async fn export_style_kit<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| {
            let p = r.shell_parts();
            let suggested = format!("{}.{}", p.session.display_name(), StyleKitFile::FILE_EXTENSION);
            p.files.choose_style_kit(true, &suggested)
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            if let Err(e) = p.session.export_style_kit(&url) {
                p.shell.flash_raw(SQL10n::format("Could not export the style kit: %@", &[&e]));
            }
        });
    }

    /// File > Project > Style Kit > Import: the chooser, then what the merge added.
    pub(crate) async fn import_style_kit<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| r.shell_parts().files.choose_style_kit(false, "")) else { return };
        let Some(url) = ask.await else { return };
        let Some(dialog) = h
            .with(|r| {
                let p = r.shell_parts();
                let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                match p.session.import_style_kit(&url) {
                    Ok(rep) => {
                        let mut lines: Vec<String> = Vec::new();
                        if !rep.added_tokens.is_empty() {
                            lines.push(format!("Added: {}", rep.added_tokens.join(", ")));
                        }
                        if !rep.added_looks.is_empty() {
                            lines.push(format!("Looks: {}", rep.added_looks.join(", ")));
                        }
                        if !rep.kept_tokens.is_empty() {
                            lines.push(format!("Kept yours: {}", rep.kept_tokens.join(", ")));
                        }
                        let empty =
                            rep.added_tokens.is_empty() && rep.added_looks.is_empty() && rep.kept_tokens.is_empty();
                        let mut d = ShellDialog::new(
                            &SQL10n::string(if empty { "Nothing new in this style kit" } else { "Style kit imported" }),
                            &lines.join("\n"),
                        );
                        d.add_button("OK", SQDialogRole::Normal, false);
                        Some(d)
                    }
                    Err(e) => {
                        p.shell.flash_raw(SQL10n::format("Could not import “%@”: %@", &[&name, &e]));
                        None
                    }
                }
            })
            .flatten()
        else {
            return;
        };
        let _ = Self::ask(&h, dialog).await;
    }

    /// Runs the dialog flows `ShellFlow::Project` names.
    pub(crate) async fn run_project_flow<R: ShellRoot + ?Sized>(h: UiRef<R>, a: ShellAction) {
        match a {
            ShellAction::CollectFiles => Self::collect_files(h, None, false).await,
            ShellAction::ExportStyleKit => Self::export_style_kit(h).await,
            ShellAction::ImportStyleKit => Self::import_style_kit(h).await,
            ShellAction::ChangeFormat => Self::change_format(h, false).await,
            ShellAction::DuplicateAsFormat => Self::change_format(h, true).await,
            ShellAction::NewSequenceFromTemplate => Self::new_sequence_from_template(h).await,
            ShellAction::SaveSequenceAsTemplate => Self::save_sequence_as_template(h).await,
            ShellAction::RelinkMedia => Self::relink_media(h).await,
            ShellAction::CustomPixelAspect => Self::custom_selection_pixel_aspect(h).await,
            other => project_flow(h, other).await,
        }
    }

    pub(crate) fn flash_raw(&mut self, line: String) {
        self.emit(ShellEvent::Status(line));
    }

    /// `MediaMenuTarget.change`: one undo step "Change Media Setting"; an empty policy is stored as nil.
    pub(crate) fn change_media_policy(session: &mut EditorSession, edit: impl FnOnce(&mut MediaPolicy)) {
        session.perform("Change Media Setting", None, |p| {
            let mut policy = p.media_policy.clone().unwrap_or_default();
            edit(&mut policy);
            p.media_policy = if policy == MediaPolicy::default() { None } else { Some(policy) };
        });
    }

    /// The Mac `validateMenuItem` facts of the shell rows.
    pub(crate) fn fill_project_state(&self, session: &EditorSession, hooks: &dyn ShellHooks, s: &mut ShellMenuState) {
        let d = session.media_policy_defaults();
        let project = session.project();
        let policy = project.media_policy.as_ref();
        s.outside_media = MediaManagement::outside_mode(project, &d);
        s.copy_library_items = policy.and_then(|p| p.copy_library_items).unwrap_or(d.copy_library_items);
        s.watch_folder = policy.and_then(|p| p.watch_folder).unwrap_or(false);
        s.in_project_folder = MediaManagement::project_folder(session.file_url()).is_some();
        s.project_input_color = project.input_color_space;
        s.has_sequence = session.active_timeline().is_some();
        s.can_relink = session.can_relink();
        s.has_import_checklist = self.flow_env.import_checklist.is_some();
        s.pixel_aspect = self.pixel_aspect_rows(session);
        let mut checked = self.view_checks(session);
        checked.extend(hooks.menu_checks());
        s.checked_commands = checked;
    }
}
