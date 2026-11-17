// Swift: SQAppShell/Library/LibraryHost.swift (`run`, `exportPack`, `importPack`)
//! The Library requests that need a file chooser or a dialog (Add Folder, preset and pack export and import, Delete
//! Preset), as small state machines the root polls once per answer round. Each step waits on a [`ModalAsk`] of the shell
//! (a dialog) or of the platform's file chooser; the model calls are the synchronous ones of `LibraryPanelModel`.
//! shortcut: a step is polled with a no-op waker from the root's frame loop (it asks for animation while flows wait),
//! not spawned as a task; upgrade when the model can be reached from a `UiRef` task.

use sq_core_time::Id;
use sq_draw_library::library::library_draw_panel::LibraryRequest;
use sq_draw_library::library::library_panel_logic::LibraryLabels;
use sq_draw_library::library::library_panel_model::LibraryPanelModel;
use sq_draw_shell::{FormRow, ShellDialog, ShellFilePicker, ShellForm, ShellHost};
use sq_library::preset_store::{PresetFile, PresetItem};
use sq_library::sqpack::{SQPackFormat, SQPackManifest, SQPackReadResult};
use sq_library::sqpack_store::SQPackConflict;
use sq_runtime::ModalAsk;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::task::{Context, Poll, Waker};

/// The settings key of the pack author (`LibraryHost.authorKey`).
pub const AUTHOR_KEY: &str = "sq.pack.author";

/// What a step may touch.
pub struct Env<'a> {
    /// The Library's model.
    pub model: &'a mut LibraryPanelModel,
    /// Dialogs and stored settings.
    pub shell: &'a mut ShellHost,
    /// The platform's file choosers.
    pub files: &'a mut dyn ShellFilePicker,
}

enum Step {
    Folder(ModalAsk<Option<PathBuf>>),
    ExportPreset(ModalAsk<Option<PathBuf>>, PresetItem),
    ImportPresets(ModalAsk<Option<PathBuf>>),
    Delete(ModalAsk<SQDialogResponse>, PresetItem),
    PackForm(ModalAsk<SQDialogResponse>, Vec<Id>),
    PackWhere(ModalAsk<Option<PathBuf>>, Vec<Id>, SQPackManifest),
    ImportPack(ModalAsk<Option<PathBuf>>),
    Clash(ModalAsk<SQDialogResponse>, SQPackReadResult, String),
}

/// The running Library flows.
#[derive(Default)]
pub struct LibraryFlows {
    steps: Vec<Step>,
}

/// The answer of `ask` if it came, else `None` (the ask stays usable).
fn ready<T>(ask: &mut ModalAsk<T>) -> Option<T> {
    let mut cx = Context::from_waker(Waker::noop());
    match Pin::new(ask).poll(&mut cx) {
        Poll::Ready(v) => Some(v),
        Poll::Pending => None,
    }
}

fn now() -> sq_core_time::Timestamp {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
    sq_core_time::Timestamp::from_unix_seconds(secs)
}

fn message(env: &mut Env, title: &str, detail: &str) {
    env.shell.present_message(title, detail, None);
}

fn count_text(n: usize, one: &str, other: &str) -> String {
    SQL10n::format(if n == 1 { one } else { other }, &[&n.to_string()])
}

impl LibraryFlows {
    /// Whether a flow waits for an answer.
    pub fn is_active(&self) -> bool {
        !self.steps.is_empty()
    }

    /// Starts the flow of `request`; true when it is one of these flows.
    pub fn start(&mut self, request: LibraryRequest, env: &mut Env) -> bool {
        let step = match request {
            LibraryRequest::AddFolder => Step::Folder(env.files.choose_folder(&SQL10n::string("Add Folder"))),
            LibraryRequest::ExportPreset(p) => Step::ExportPreset(
                env.files.choose_export_location(
                    &PresetFile::suggested_file_name(&p.name),
                    PresetFile::FILE_EXTENSION,
                    &SQL10n::string("Export Preset"),
                ),
                p,
            ),
            LibraryRequest::ImportPresets => {
                Step::ImportPresets(env.files.choose_file(&SQL10n::string("Import Presets"), None))
            }
            LibraryRequest::DeletePreset(p) => {
                let mut d = ShellDialog::new(
                    &SQL10n::format("Delete “%@”?", &[&p.name]),
                    &SQL10n::string("The preset is removed from the Library. Clips that use it keep their keyframes."),
                );
                d.add_button(&SQL10n::string("Delete"), SQDialogRole::Destructive, false);
                d.add_button(&SQL10n::string("Cancel"), SQDialogRole::Cancel, false);
                Step::Delete(env.shell.present(d), p)
            }
            LibraryRequest::ExportPack { ids, suggested_name } => {
                if ids.is_empty() {
                    return true;
                }
                let info = if ids.len() == 1 {
                    SQL10n::string("One preset goes into the pack.")
                } else {
                    SQL10n::format("%@ presets go into the pack.", &[&ids.len().to_string()])
                };
                let mut d = ShellDialog::new(&SQL10n::string("Export as Pack"), &info);
                let author = env.shell.settings.borrow().string(AUTHOR_KEY).unwrap_or_default();
                d.form = Some(Box::new(ShellForm::new(vec![
                    FormRow::field("name", &SQL10n::string("Name"), &suggested_name),
                    FormRow::field("author", &SQL10n::string("Author"), &author),
                    FormRow::field("version", &SQL10n::string("Version"), "1.0"),
                ])));
                d.add_button(&SQL10n::string("Export…"), SQDialogRole::Default, false);
                d.add_button(&SQL10n::string("Cancel"), SQDialogRole::Cancel, false);
                Step::PackForm(env.shell.present(d), ids)
            }
            LibraryRequest::ImportPack => Step::ImportPack(env.files.choose_file(&SQL10n::string("Import Pack"), None)),
            _ => return false,
        };
        self.steps.push(step);
        true
    }

    /// Advances every flow whose answer came; true while some still wait.
    pub fn poll(&mut self, env: &mut Env) -> bool {
        let mut waiting = Vec::new();
        for step in std::mem::take(&mut self.steps) {
            // A step may start the next one (a chooser after the form), which can be answered at once: loop.
            let mut current = Some(step);
            while let Some(s) = current.take() {
                match Self::advance(s, env) {
                    Advance::Wait(s) => waiting.push(s),
                    Advance::Next(s) => current = Some(s),
                    Advance::Done => {}
                }
            }
        }
        self.steps = waiting;
        self.is_active()
    }

    fn advance(step: Step, env: &mut Env) -> Advance {
        match step {
            Step::Folder(mut ask) => match ready(&mut ask) {
                None => Advance::Wait(Step::Folder(ask)),
                Some(Some(url)) => {
                    env.model.add_folder(url, None);
                    Advance::Done
                }
                Some(None) => Advance::Done,
            },
            Step::ExportPreset(mut ask, p) => match ready(&mut ask) {
                None => Advance::Wait(Step::ExportPreset(ask, p)),
                Some(None) => Advance::Done,
                Some(Some(url)) => {
                    if let Err(e) = env.model.export_preset(p.id, &url) {
                        let (_, detail) = LibraryLabels::preset_error(&e, None);
                        message(env, &SQL10n::string("The preset could not be exported."), &detail);
                    }
                    Advance::Done
                }
            },
            Step::ImportPresets(mut ask) => match ready(&mut ask) {
                None => Advance::Wait(Step::ImportPresets(ask)),
                Some(None) => Advance::Done,
                Some(Some(url)) => {
                    let is_pack = url
                        .extension()
                        .is_some_and(|e| e.to_string_lossy().eq_ignore_ascii_case(SQPackFormat::FILE_EXTENSION));
                    if is_pack {
                        return Self::read_pack(url, env);
                    }
                    for (file, error) in env.model.import_presets(&[url]) {
                        let (title, detail) = LibraryLabels::preset_error(&error, Some(&file));
                        message(env, &title, &detail);
                    }
                    Advance::Done
                }
            },
            Step::Delete(mut ask, p) => match ready(&mut ask) {
                None => Advance::Wait(Step::Delete(ask, p)),
                Some(r) => {
                    if r == SQDialogResponse::FIRST {
                        env.model.delete_preset(p.id);
                    }
                    Advance::Done
                }
            },
            Step::PackForm(mut ask, ids) => match ready(&mut ask) {
                None => Advance::Wait(Step::PackForm(ask, ids)),
                Some(r) if r != SQDialogResponse::FIRST => Advance::Done,
                Some(_) => Self::pack_form_answered(ids, env),
            },
            Step::PackWhere(mut ask, ids, manifest) => match ready(&mut ask) {
                None => Advance::Wait(Step::PackWhere(ask, ids, manifest)),
                Some(None) => Advance::Done,
                Some(Some(url)) => {
                    if let Err(e) = env.model.export_pack(&ids, &manifest, &url) {
                        message(env, &SQL10n::string("The pack could not be saved"), &LibraryLabels::pack_error(&e));
                    }
                    Advance::Done
                }
            },
            Step::ImportPack(mut ask) => match ready(&mut ask) {
                None => Advance::Wait(Step::ImportPack(ask)),
                Some(None) => Advance::Done,
                Some(Some(url)) => Self::read_pack(url, env),
            },
            Step::Clash(mut ask, read, name) => match ready(&mut ask) {
                None => Advance::Wait(Step::Clash(ask, read, name)),
                Some(r) => {
                    let policy = match r {
                        SQDialogResponse::FIRST => SQPackConflict::Rename,
                        SQDialogResponse::SECOND => SQPackConflict::Replace,
                        SQDialogResponse::THIRD => SQPackConflict::Skip,
                        _ => return Advance::Done,
                    };
                    Self::install(&read, &name, policy, env);
                    Advance::Done
                }
            },
        }
    }

    /// "Export as Pack…": the form was confirmed; validate the name and ask where to save (`LibraryHost.exportPack`).
    fn pack_form_answered(ids: Vec<Id>, env: &mut Env) -> Advance {
        let Some(mut form) = env.shell.take_answered_form() else { return Advance::Done };
        form.commit_editing();
        let text = |id: &str| form.text(id).unwrap_or_default().trim().to_string();
        let (title, author, version) = (text("name"), text("author"), text("version"));
        env.shell.settings.borrow_mut().set_string(AUTHOR_KEY, &author);
        if SQPackFormat::validate_name(&title).is_err() {
            message(
                env,
                &SQL10n::string("Choose another name"),
                &SQL10n::string("A pack name needs 1 to 120 characters and no slashes or colons."),
            );
            return Advance::Done;
        }
        let mut manifest = SQPackManifest::new(&title, now());
        manifest.author = author;
        manifest.version = version;
        let ask = env.files.choose_export_location(
            &SQPackFormat::suggested_file_name(&title),
            SQPackFormat::FILE_EXTENSION,
            &SQL10n::string("Export as Pack"),
        );
        Advance::Next(Step::PackWhere(ask, ids, manifest))
    }

    /// Reads and checks a `.sqpack`, asks only when names clash, then adds it (`LibraryHost.importPack`).
    fn read_pack(url: PathBuf, env: &mut Env) -> Advance {
        let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let read = match env.model.read_pack(&url) {
            Ok(r) => r,
            Err(e) => {
                message(env, &SQL10n::format("“%@” could not be imported", &[&name]), &LibraryLabels::pack_error(&e));
                return Advance::Done;
            }
        };
        let clashes = env.model.pack_conflicts(&read.pack).len();
        if clashes == 0 {
            Self::install(&read, &name, SQPackConflict::Rename, env);
            return Advance::Done;
        }
        let info = count_text(
            clashes,
            "%@ preset has the same name as one you already imported from this pack.",
            "%@ presets have the same name as one you already imported from this pack.",
        );
        let d = ShellHost::pack_clash_dialog(&read.pack.manifest.name, &info);
        Advance::Next(Step::Clash(env.shell.present(d), read, name))
    }

    fn install(read: &SQPackReadResult, file: &str, policy: SQPackConflict, env: &mut Env) {
        match env.model.import_pack(read, policy) {
            Ok(s) if s.unreadable > 0 => message(
                env,
                &SQL10n::format("“%@” was imported", &[&s.pack_name]),
                &count_text(
                    s.unreadable,
                    "%@ preset in it needs a newer version of Sequence Studio and was left out.",
                    "%@ presets in it need a newer version of Sequence Studio and were left out.",
                ),
            ),
            Ok(_) => {}
            Err(e) => {
                message(env, &SQL10n::format("“%@” could not be imported", &[file]), &LibraryLabels::pack_error(&e))
            }
        }
    }
}

enum Advance {
    Wait(Step),
    Next(Step),
    Done,
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Timestamp;
    use sq_draw_shell::answered;
    use sq_library::preset_store::PresetKind;
    use sq_runtime::FakeClock;
    use std::sync::Arc;

    /// Choosers that answer at once with the next path of the list (None when it ran out).
    struct Files(Vec<PathBuf>);

    impl Files {
        fn next(&mut self) -> ModalAsk<Option<PathBuf>> {
            answered(if self.0.is_empty() { None } else { Some(self.0.remove(0)) })
        }
    }

    impl ShellFilePicker for Files {
        fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
            self.next()
        }
        fn choose_save_location(&mut self, _: &str, _: &str) -> ModalAsk<Option<PathBuf>> {
            self.next()
        }
        fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
            answered(Vec::new())
        }
        fn choose_folder(&mut self, _: &str) -> ModalAsk<Option<PathBuf>> {
            self.next()
        }
        fn choose_file(&mut self, _: &str, _: Option<&std::path::Path>) -> ModalAsk<Option<PathBuf>> {
            self.next()
        }
        fn choose_export_location(&mut self, _: &str, _: &str, _: &str) -> ModalAsk<Option<PathBuf>> {
            self.next()
        }
    }

    struct Rig {
        dir: PathBuf,
        model: LibraryPanelModel,
        shell: ShellHost,
        files: Files,
        flows: LibraryFlows,
    }

    impl Rig {
        fn said(&self) -> String {
            self.shell.dialog().map(|d| format!("{} / {}", d.message_text, d.informative_text)).unwrap_or_default()
        }

        fn new(name: &str, files: Vec<PathBuf>) -> Rig {
            let dir = crate::test_rig::unique_dir(&format!("sq-lib-flows-{name}"));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("dir");
            let model = crate::standard::library_panel(&dir).expect("panel").model;
            let shell = ShellHost::new(
                sq_uikit::command_map::CommandMap::premiere_default(),
                sq_editor_session::RecentProjects::new(Vec::new()),
                Arc::new(FakeClock::new()),
                Box::new(|| Timestamp::from_unix_seconds(0.0)),
            );
            Rig { dir, model, shell, files: Files(files), flows: LibraryFlows::default() }
        }

        fn run(&mut self, r: LibraryRequest) {
            let mut env = Env { model: &mut self.model, shell: &mut self.shell, files: &mut self.files };
            assert!(self.flows.start(r, &mut env));
            self.flows.poll(&mut env);
        }

        fn poll(&mut self) -> bool {
            let mut env = Env { model: &mut self.model, shell: &mut self.shell, files: &mut self.files };
            self.flows.poll(&mut env)
        }

        /// The presets the user saved (the Motion built-ins the Library lists on its own are left out).
        fn saved_presets(&self) -> Vec<&sq_library::preset_store::PresetItem> {
            self.model.presets().iter().filter(|p| p.kind != sq_library::preset_store::PresetKind::Keystone).collect()
        }

        fn save(&mut self, n: u128, name: &str) -> PresetItem {
            let item = PresetItem::new(
                Id::from_u128(n),
                PresetKind::Transition,
                name,
                Timestamp::from_unix_seconds(1.0),
                {
                    use sq_core_effects::transition::TransitionPresetExt;
                    sq_core_model::effect_defaults::TransitionPreset::new(
                        sq_core_model::TransitionKind::CrossDissolve,
                        sq_core_time::Time::seconds(1),
                    )
                    .payload()
                    .expect("payload")
                },
                1,
            );
            self.model.save_preset(item.clone()).expect("save");
            item
        }
    }

    #[test]
    fn add_folder_adds_the_chosen_folder_and_reports_the_change() {
        let mut rig = Rig::new("folder", Vec::new());
        let folder = rig.dir.join("Footage");
        std::fs::create_dir_all(&folder).expect("folder");
        rig.files = Files(vec![folder.clone()]);
        let before = rig.model.folders().len();
        rig.run(LibraryRequest::AddFolder);
        assert_eq!(rig.model.folders().len(), before + 1);
        assert!(rig.model.folders().iter().any(|f| f.folder.url == folder));
        let events = rig.model.take_events();
        assert!(
            events.iter().any(|e| matches!(
                e,
                sq_draw_library::library::library_panel_model::LibraryModelEvent::FoldersChanged(_)
            ))
        );
    }

    #[test]
    fn a_canceled_chooser_changes_nothing() {
        let mut rig = Rig::new("cancel", Vec::new());
        rig.run(LibraryRequest::AddFolder);
        assert!(!rig.flows.is_active());
        assert!(rig.model.folders().is_empty());
    }

    #[test]
    fn delete_preset_waits_for_the_answer_and_deletes_on_the_first_button() {
        let mut rig = Rig::new("delete", Vec::new());
        let item = rig.save(1, "Warm");
        rig.run(LibraryRequest::DeletePreset(item.clone()));
        assert!(rig.flows.is_active(), "the dialog is up");
        assert_eq!(rig.saved_presets().len(), 1);
        rig.shell.dialog_mut().expect("dialog").press(SQDialogResponse::FIRST);
        assert!(!rig.poll());
        assert!(rig.saved_presets().is_empty());
    }

    #[test]
    fn delete_preset_keeps_it_on_cancel() {
        let mut rig = Rig::new("keep", Vec::new());
        let item = rig.save(1, "Warm");
        rig.run(LibraryRequest::DeletePreset(item));
        rig.shell.dialog_mut().expect("dialog").press(SQDialogResponse::SECOND);
        assert!(!rig.poll());
        assert_eq!(rig.saved_presets().len(), 1);
    }

    #[test]
    fn a_preset_exports_to_a_file_and_imports_again() {
        let mut rig = Rig::new("preset", Vec::new());
        let item = rig.save(1, "Warm");
        let file = rig.dir.join("Warm.sqpreset");
        rig.files = Files(vec![file.clone(), file.clone()]);
        rig.run(LibraryRequest::ExportPreset(item.clone()));
        assert!(file.exists());
        rig.model.delete_preset(item.id);
        assert!(rig.saved_presets().is_empty());
        rig.run(LibraryRequest::ImportPresets);
        assert_eq!(rig.saved_presets().len(), 1, "{}", rig.said());
        assert_eq!(rig.saved_presets()[0].name, "Warm");
    }

    #[test]
    fn a_pack_exports_and_imports_through_a_temp_folder() {
        let mut rig = Rig::new("pack", Vec::new());
        let a = rig.save(1, "Warm");
        let b = rig.save(2, "Cool");
        let file = rig.dir.join("Looks.sqpack");
        // The form step is the dialog's; from the chooser on the flow is the same code.
        let manifest = SQPackManifest::new("Looks", now());
        let ask = answered(Some(file.clone()));
        rig.flows.steps.push(Step::PackWhere(ask, vec![a.id, b.id], manifest));
        assert!(!rig.poll());
        assert!(file.exists(), "{}", rig.said());
        for id in [a.id, b.id] {
            rig.model.delete_preset(id);
        }
        rig.files = Files(vec![file]);
        rig.run(LibraryRequest::ImportPack);
        assert!(!rig.flows.is_active(), "no clash, no question");
        assert_eq!(rig.model.preset_ids_in_pack("Looks").len(), 2);
    }

    #[test]
    fn importing_a_pack_twice_asks_how_to_handle_the_clash() {
        let mut rig = Rig::new("clash", Vec::new());
        let a = rig.save(1, "Warm");
        let file = rig.dir.join("One.sqpack");
        rig.flows.steps.push(Step::PackWhere(
            answered(Some(file.clone())),
            vec![a.id],
            SQPackManifest::new("One", now()),
        ));
        rig.poll();
        rig.files = Files(vec![file.clone(), file]);
        rig.run(LibraryRequest::ImportPack);
        assert!(!rig.flows.is_active(), "{}", rig.said());
        rig.run(LibraryRequest::ImportPack);
        assert!(rig.flows.is_active(), "the same names ask");
        rig.shell.dialog_mut().expect("dialog").press(SQDialogResponse::THIRD);
        assert!(!rig.poll());
        assert_eq!(rig.model.preset_ids_in_pack("One").len(), 1, "Skip Existing adds nothing");
    }

    #[test]
    fn a_file_that_is_no_pack_says_so() {
        let mut rig = Rig::new("bad", Vec::new());
        let file = rig.dir.join("x.sqpack");
        std::fs::write(&file, b"nope").expect("write");
        rig.files = Files(vec![file]);
        rig.run(LibraryRequest::ImportPack);
        assert!(!rig.flows.is_active());
        assert!(rig.shell.dialog().is_some_and(|d| d.message_text.contains("could not be imported")));
    }
}
