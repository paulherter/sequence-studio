use super::*;
use crate::shell_dialog::FormValue;
use crate::shell_live::test_rig::{answer_swept, type_into};
use crate::tests::Rig;
use sq_core_model::{MediaFingerprint, MediaPolicyDefaults, MediaRef, OutsideMediaMode};
use sq_editor_session::{ImportBackend, ImportError, ProjectPanelDeps};
use std::sync::Arc;

/// Probes any path into a media item named after the file (the files are real, the content is not media).
struct Probe;

impl ImportBackend for Probe {
    fn probe(&self, path: &Path) -> Result<MediaRef, ImportError> {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if name.starts_with("corrupt") {
            return Err(ImportError::Failed("not media".into()));
        }
        let key = path.to_string_lossy().bytes().fold(7u128, |h, b| h.wrapping_mul(131).wrapping_add(u128::from(b)));
        Ok(MediaRef::new(Id::from_u128(key), &name, &path.to_string_lossy(), MediaFingerprint::new(1)))
    }
}

struct Setup {
    rig: Rig,
    root: PathBuf,
    /// A folder outside the project folder.
    elsewhere: PathBuf,
}

impl Setup {
    /// A saved project in its own folder (`<root>/Film/Film.sqproj`) with the given Outside files choice.
    fn new(name: &str, outside: Option<OutsideMediaMode>) -> Setup {
        let root = std::env::temp_dir().join(format!("sq-outside-{name}-{}", std::process::id()));
        Setup::at(root, "Film/Film.sqproj", outside)
    }

    /// A project file that does not sit in a folder of its own name (`<root>/Film.sqproj`).
    fn loose(name: &str, outside: Option<OutsideMediaMode>) -> Setup {
        let root = std::env::temp_dir().join(format!("sq-outside-{name}-{}", std::process::id()));
        Setup::at(root, "Film.sqproj", outside)
    }

    /// A project file saved by an earlier run and opened from its path, as `sequence-studio <path>` does.
    fn opened(name: &str, project_file: &str, outside: Option<OutsideMediaMode>) -> Setup {
        let root = std::env::temp_dir().join(format!("sq-outside-{name}-{}", std::process::id()));
        let t = Setup::at(root.clone(), project_file, outside);
        t.rig.with(|r| {
            r.session.save().expect("save");
            r.session.open(&root.join(project_file)).expect("open");
        });
        t
    }

    fn at(root: PathBuf, project_file: &str, outside: Option<OutsideMediaMode>) -> Setup {
        let _ = std::fs::remove_dir_all(&root);
        let project_dir = root.join("Film");
        let elsewhere = root.join("Downloads");
        std::fs::create_dir_all(project_dir.join("Footage")).expect("dirs");
        std::fs::create_dir_all(&elsewhere).expect("dirs");
        let rig = Rig::new();
        rig.with(|r| {
            r.session.save_as(&root.join(project_file)).expect("save");
            if let Some(mode) = outside {
                r.session.perform("Change Media Setting", None, |p| {
                    p.media_policy = Some(sq_core_model::MediaPolicy { outside: Some(mode), ..Default::default() });
                });
            }
            let deps = ProjectPanelDeps {
                backend: Arc::new(Probe),
                pool: Arc::clone(&rig.rt.pool),
                ..ProjectPanelDeps::headless()
            };
            r.panel = ProjectPanelModel::new(r.session.project().clone(), deps);
        });
        Setup { rig, root, elsewhere }
    }

    fn file(dir: &Path, name: &str, content: &str) -> PathBuf {
        std::fs::create_dir_all(dir).expect("dir");
        let p = dir.join(name);
        std::fs::write(&p, content).expect("write");
        p
    }

    fn files_imported(&self) -> PathBuf {
        self.root.join("Film/Files/Imported")
    }

    /// Starts an import and runs it until it asks or ends.
    fn start(&self, urls: Vec<PathBuf>, generated: bool) {
        // The app hands the session's project to the panel after every change (`App` in sq-app-shell).
        self.rig.with(|r| r.panel.set_project(r.session.project().clone()));
        self.rig.rt.ex.spawn_local(ShellHost::import_media(self.rig.handle(), urls, generated));
        self.rig.rt.run_until_stalled();
    }

    fn paths(&self) -> Vec<String> {
        let mut v: Vec<String> = self.rig.with(|r| r.session.project().media.iter().map(|m| m.path.clone()).collect());
        v.sort();
        v
    }
}

impl Drop for Setup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

#[test]
fn copy_mode_copies_outside_files_and_points_the_clips_at_the_copies() {
    let t = Setup::new("copy", Some(OutsideMediaMode::Copy));
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    let b = Setup::file(&t.elsewhere, "b.mov", "bbb");
    t.start(vec![a.clone(), b.clone()], false);
    assert!(!t.rig.has_dialog(), "Copy never asks");
    let copies = [t.files_imported().join("a.mov"), t.files_imported().join("b.mov")];
    assert_eq!(t.paths(), [s(&copies[0]), s(&copies[1])]);
    assert!(copies.iter().all(|c| c.exists()), "the clip points at a copy that exists");
    assert!(a.exists() && b.exists(), "originals stay");
    // One undo step for the import; the relink is not one, and redo still has the copies.
    t.rig.with(|r| {
        assert!(r.session.undo());
        assert!(r.session.project().media.is_empty());
        assert!(r.session.redo());
    });
    assert_eq!(t.paths(), [s(&copies[0]), s(&copies[1])]);
}

#[test]
fn a_loose_project_file_keeps_outside_files_in_place_whatever_the_setting_says() {
    // Swift `MediaManagement.disposition`: only a project in its own folder applies the setting; a loose file has no
    // `Files/` to copy into. The new-project flow always makes the folder, so this is a file moved out of it.
    for mode in [OutsideMediaMode::Copy, OutsideMediaMode::Move, OutsideMediaMode::Ask] {
        let t = Setup::loose(&format!("loose-{mode:?}"), Some(mode));
        let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
        t.start(vec![a.clone()], false);
        assert!(!t.rig.has_dialog(), "{mode:?}: a loose project never asks");
        assert_eq!(t.paths(), [s(&a)], "{mode:?}: the clip stays at its own path");
        let said = t.rig.with(|r| r.shell.take_events()).into_iter().any(
            |e| matches!(e, ShellEvent::Status(line) if line.starts_with("Kept 1 file where it is: this project is not in a folder")),
        );
        assert!(said, "{mode:?}: the status line says why nothing was copied");
    }
}

#[test]
fn files_inside_the_project_folder_are_never_copied() {
    let t = Setup::new("inside", Some(OutsideMediaMode::Copy));
    let inside = Setup::file(&t.root.join("Film/Footage"), "c.mov", "ccc");
    t.start(vec![inside.clone()], false);
    assert_eq!(t.paths(), [s(&inside)]);
    assert!(!t.files_imported().exists(), "nothing was copied");
}

#[test]
fn leave_mode_keeps_the_files_where_they_are() {
    let t = Setup::new("leave", Some(OutsideMediaMode::Leave));
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a.clone()], false);
    assert!(!t.rig.has_dialog());
    assert_eq!(t.paths(), [s(&a)]);
    assert!(!t.files_imported().exists());
}

#[test]
fn ask_mode_asks_after_the_clip_landed_and_copy_copies() {
    let t = Setup::new("ask-copy", None);
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a.clone()], false);
    assert!(t.rig.has_dialog(), "the default is Ask each time");
    assert_eq!(t.paths(), [s(&a)], "the clip is in the project and uses the original while the question is up");
    assert!(!t.files_imported().exists(), "nothing is copied before the answer");
    answer_swept(&t.rig, SQDialogResponse::FIRST);
    assert_eq!(t.paths(), [s(&t.files_imported().join("a.mov"))]);
    assert!(t.files_imported().join("a.mov").exists());
}

#[test]
fn ask_mode_leave_keeps_the_original_and_esc_counts_as_leave() {
    let t = Setup::new("ask-leave", None);
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a.clone()], false);
    answer_swept(&t.rig, SQDialogResponse::THIRD);
    assert_eq!(t.paths(), [s(&a)]);
    assert!(!t.files_imported().exists());
    assert!(t.rig.with(|r| r.session.project().media_policy.is_none()), "no \"always\": nothing is remembered");
}

#[test]
fn esc_is_not_remembered_the_next_import_asks_again() {
    let t = Setup::new("esc-asks-again", None);
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a], false);
    // The real key, not a canned answer: the dialog's own Esc path.
    t.rig.key(sq_draw::InputKey::Escape, sq_draw::InputModifiers::NONE);
    t.rig.rt.run_until_stalled();
    assert!(!t.rig.has_dialog(), "Esc closed the question");
    let b = Setup::file(&t.elsewhere, "b.mov", "bbb");
    t.start(vec![b], false);
    assert!(t.rig.has_dialog(), "Esc was not \"always\": the next import asks again");
}

#[test]
fn a_folder_import_with_an_unreadable_file_still_asks_about_the_readable_ones() {
    let t = Setup::new("ask-after-corrupt", None);
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a], false);
    answer_swept(&t.rig, SQDialogResponse::THIRD);
    let bad = Setup::file(&t.elsewhere, "corrupt.mp4", "xxx");
    let b = Setup::file(&t.elsewhere, "b.mov", "bbb");
    t.start(vec![bad, b], false);
    assert!(t.rig.has_dialog(), "the unreadable file does not swallow the question");
}

#[test]
fn always_remembers_the_answer_in_the_project() {
    let t = Setup::new("ask-always", None);
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a], false);
    type_into(&t.rig, "always", FormValue::Bool(true));
    answer_swept(&t.rig, SQDialogResponse::FIRST);
    let outside = t.rig.with(|r| r.session.project().media_policy.as_ref().and_then(|p| p.outside));
    assert_eq!(outside, Some(OutsideMediaMode::Copy));
    // The next import does not ask any more.
    let b = Setup::file(&t.elsewhere, "b.mov", "bbb");
    t.start(vec![b], false);
    let open = t.rig.with(|r| r.shell.dialog().map(|d| d.message_text.clone()));
    assert_eq!(open, None, "the project remembers the answer");
    assert!(t.files_imported().join("b.mov").exists());
}

#[test]
fn move_copies_now_and_keeps_the_original_until_a_save_holds_the_copy() {
    let t = Setup::new("move", Some(OutsideMediaMode::Move));
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a.clone()], false);
    assert_eq!(t.paths(), [s(&t.files_imported().join("a.mov"))]);
    assert!(a.exists(), "the original waits for the save");
    let waiting = t.rig.with(|r| r.shell.outside_media.pending_moves.len());
    assert_eq!(waiting, 1);
}

#[test]
fn a_name_clash_in_files_imported_gets_a_number_like_collect_files() {
    let t = Setup::new("clash", Some(OutsideMediaMode::Copy));
    let one = Setup::file(&t.elsewhere.join("one"), "a.mov", "first");
    let two = Setup::file(&t.elsewhere.join("two"), "a.mov", "second");
    t.start(vec![one, two], false);
    assert_eq!(t.paths(), [s(&t.files_imported().join("a 2.mov")), s(&t.files_imported().join("a.mov"))]);
    assert_eq!(std::fs::read_to_string(t.files_imported().join("a.mov")).expect("a"), "first");
    assert_eq!(std::fs::read_to_string(t.files_imported().join("a 2.mov")).expect("a 2"), "second");
}

#[test]
fn library_items_are_copied_into_files_library_and_never_asked_about() {
    let t = Setup::new("library", None);
    let library = t.root.join("MyLibrary");
    let sound = Setup::file(&library, "boom.wav", "boom");
    t.rig.with(|r| r.shell.outside_media.library_roots = vec![library.clone()]);
    t.start(vec![sound], false);
    assert!(!t.rig.has_dialog(), "a Library item never asks");
    let copy = t.root.join("Film/Files/Library/boom.wav");
    assert_eq!(t.paths(), [s(&copy)]);
    assert!(copy.exists());
}

#[test]
fn a_file_the_app_made_is_copied_without_asking() {
    let t = Setup::new("generated", None);
    let take = Setup::file(&t.elsewhere, "Voiceover.wav", "voice");
    t.start(vec![take], true);
    assert!(!t.rig.has_dialog());
    assert_eq!(t.paths(), [s(&t.files_imported().join("Voiceover.wav"))]);
}

#[test]
fn the_app_default_in_the_session_applies_when_the_project_has_no_choice() {
    // The Media page's default reaches the session once (`apply_session_settings_from`); the import reads it there,
    // not from the settings store (which only the Preferences page knows).
    let t = Setup::new("app-default", None);
    let copy_default = MediaPolicyDefaults { outside: OutsideMediaMode::Copy, ..MediaPolicyDefaults::default() };
    t.rig.with(|r| r.session.set_media_policy_defaults(Box::new(move || copy_default)));
    let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
    t.start(vec![a.clone()], false);
    assert!(!t.rig.has_dialog(), "the app default Copy never asks");
    let copy = t.files_imported().join("a.mov");
    assert_eq!(t.paths(), [s(&copy)]);
    assert!(copy.exists() && a.exists(), "copied, the original stays");
}

#[test]
fn the_menu_rows_show_the_session_default_until_the_project_chooses() {
    let t = Setup::new("menu-default", None);
    let leave =
        MediaPolicyDefaults { outside: OutsideMediaMode::Leave, copy_library_items: false, watch_folder: false };
    t.rig.with(|r| r.session.set_media_policy_defaults(Box::new(move || leave)));
    let mut state = crate::shell_menu_bar::ShellMenuState::default();
    t.rig.with(|r| r.shell.fill_project_state(&r.session, &crate::shell_host::NoHooks, &mut state));
    assert_eq!(state.outside_media, OutsideMediaMode::Leave);
    assert!(!state.copy_library_items);
}

#[test]
fn enter_on_the_question_copies_in_a_project_opened_from_its_folder() {
    // FINAL-LIN-4 row 4: Enter (Copy is the default) copied nothing in a project opened from a path.
    for mode in [None, Some(OutsideMediaMode::Ask)] {
        let t = Setup::opened(&format!("opened-enter-{mode:?}"), "Film/Film.sqproj", mode);
        let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
        t.start(vec![a.clone()], false);
        assert!(t.rig.has_dialog(), "{mode:?}: an outside file asks");
        t.rig.key(sq_draw::InputKey::Enter, sq_draw::InputModifiers::NONE);
        t.rig.rt.run_until_stalled();
        assert_eq!(t.paths(), [s(&t.files_imported().join("a.mov"))], "{mode:?}: Enter is Copy");
        assert!(t.files_imported().join("a.mov").exists(), "{mode:?}: the copy is on disk");
    }
}

#[test]
fn a_loose_project_opened_from_a_path_does_not_ask_and_keeps_the_file() {
    for mode in [None, Some(OutsideMediaMode::Ask), Some(OutsideMediaMode::Copy)] {
        let t = Setup::opened(&format!("opened-loose-{mode:?}"), "Film.sqproj", mode);
        let a = Setup::file(&t.elsewhere, "a.mov", "aaa");
        t.start(vec![a.clone()], false);
        assert!(!t.rig.has_dialog(), "{mode:?}: a loose project never asks");
        assert_eq!(t.paths(), [s(&a)], "{mode:?}: the clip stays at its own path");
    }
}
