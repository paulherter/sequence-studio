//! Flow tests of the flow and dialog files (analysis, anonymize, audio tools, background offers, captions, card import, check
//! cuts, clip dialogs, collect, find, import, interchange, library import, locate): the shell is driven through a `UiRoot`
//! and the manual runtime, dialogs are answered step by step.

use super::*;
use crate::shell_background_offers::ShellRelinkOffer;
use crate::shell_flow_env::ShellTool;
use crate::tests::Root;
use sq_core_model::BinItemRef;
use sq_core_time::{Id, Time};
use sq_editor_session::FindCriteria;
use sq_runtime::testing::Rt;
use sq_runtime::{UiRef, UiRoot};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::cell::RefCell;
use std::future::Future;
use std::path::PathBuf;
use std::rc::Rc;

/// The runtime and the root of one test.
struct Env {
    rt: Rt,
    root: UiRoot<Root>,
}

impl Env {
    fn new() -> Env {
        Env { rt: Rt::manual(), root: UiRoot::new(Root::new()) }
    }

    fn with<T>(&self, f: impl FnOnce(&mut Root) -> T) -> T {
        self.root.with(f).expect("root alive")
    }

    /// One shell call with a context.
    fn cx<T>(&self, f: impl FnOnce(&mut ShellHost, &mut ShellCx) -> T) -> T {
        self.with(|r| {
            let mut ui = sq_draw::UiCx::new();
            let mut hooks = NoHooks;
            let mut cx =
                ShellCx { session: &mut r.session, measure: crate::tests::measure(), ui: &mut ui, hooks: &mut hooks };
            f(&mut r.shell, &mut cx)
        })
    }

    fn handle(&self) -> UiRef<dyn ShellRoot> {
        UiRef::new(self.root.weak())
    }

    /// Spawns a flow and runs it until it waits; the result lands in the returned cell.
    fn spawn<T: 'static>(&self, f: impl Future<Output = T> + 'static) -> Rc<RefCell<Option<T>>> {
        let out = Rc::new(RefCell::new(None));
        let o = Rc::clone(&out);
        self.rt.ex.spawn_local(async move {
            *o.borrow_mut() = Some(f.await);
        });
        self.rt.run_until_stalled();
        out
    }

    fn tool(&self, t: ShellTool) {
        self.with(|r| r.shell.start_flow(ShellFlow::Tool(t)));
        for f in self.with(|r| r.shell.take_flows()) {
            self.rt.ex.spawn_local(ShellHost::run_flow(self.handle(), f));
        }
        self.rt.run_until_stalled();
    }

    /// Presses a button the way the window loop does: the next event sweeps the finished dialog, then the flow resumes.
    fn answer(&self, r: SQDialogResponse) {
        self.with(|root| {
            if let Some(d) = root.shell.dialog_mut() {
                d.press(r);
            }
        });
        self.cx(|h, cx| h.handle(cx, &sq_draw::InputEvent::MouseMoved { x: 0.0, y: 0.0 }, 1.0));
        self.rt.run_until_stalled();
    }

    fn has_dialog(&self) -> bool {
        self.with(|r| r.shell.dialog().is_some())
    }

    fn dialog_title(&self) -> Option<String> {
        self.with(|r| r.shell.dialog().map(|d| d.message_text.clone()))
    }

    fn statuses(&self) -> Vec<String> {
        self.with(|r| r.shell.take_events())
            .into_iter()
            .filter_map(|e| if let ShellEvent::Status(s) = e { Some(s) } else { None })
            .collect()
    }
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sqshell-d-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    assert!(std::fs::create_dir_all(&dir).is_ok());
    dir
}

mod find {
    use super::*;

    #[test]
    fn the_sheet_dims_find_until_there_is_something_to_look_for() {
        let env = Env::new();
        env.tool(ShellTool::Find);
        assert_eq!(env.dialog_title().as_deref(), Some("Find"));
        assert!(!env.with(|r| r.shell.dialog().is_some_and(|d| d.is_enabled(0))));
        assert!(env.with(|r| r.shell.dialog().is_some_and(|d| d.is_enabled(1))));
        env.answer(SQDialogResponse::SECOND);
        assert!(!env.has_dialog());
    }

    #[test]
    fn the_unlabeled_field_and_popup_have_screen_reader_names() {
        let env = Env::new();
        env.tool(ShellTool::Find);
        let names = env.with(|r| {
            let d = r.shell.dialog().expect("dialog");
            d.form
                .as_ref()
                .map(|f| f.a11y_fields().into_iter().map(|f| f.label).collect::<Vec<_>>())
                .unwrap_or_default()
        });
        assert_eq!(names, ["Search text", "Search in", "Offline media only"]);
    }

    #[test]
    fn the_matches_are_counted_and_the_app_is_asked_to_reveal_them() {
        let env = Env::new();
        let found = vec![BinItemRef::Media(Id::fixed(1)), BinItemRef::Media(Id::fixed(2))];
        let c = FindCriteria::new("clip", sq_editor_session::FindField::Name, false);
        let reveal = env.with(|r| {
            r.shell.select_found(&c);
            assert_eq!(r.shell.take_find_request(), Some(c.clone()));
            assert_eq!(r.shell.take_find_request(), None);
            r.shell.show_found(&c, &found)
        });
        assert!(reveal);
        assert_eq!(env.statuses(), vec!["2 matches."]);
    }

    #[test]
    fn no_match_and_an_empty_search_say_so() {
        let env = Env::new();
        let reveal = env.with(|r| {
            r.shell.show_found(&FindCriteria::new("zzz", sq_editor_session::FindField::Name, false), &[])
                | r.shell.show_found(&FindCriteria::default(), &[])
        });
        assert!(!reveal);
        assert_eq!(env.statuses(), vec!["No match.", "Nothing to find."]);
    }
}

mod collect {
    use super::*;

    #[test]
    fn an_unsaved_project_asks_to_save_first() {
        let env = Env::new();
        env.spawn(ShellHost::collect_files(env.handle(), None, false));
        assert_eq!(env.dialog_title().as_deref(), Some("Save the project first"));
    }
}

mod captions {
    use super::*;
    use crate::shell_captions::ShellCaptionStyle;

    fn styles() -> Vec<ShellCaptionStyle> {
        vec![
            ShellCaptionStyle { name: "Classic".into(), max_chars: 42, lines: 2, min_seconds: 1.0, gap_frames: 2 },
            ShellCaptionStyle { name: "Pop".into(), max_chars: 20, lines: 1, min_seconds: 0.5, gap_frames: 0 },
        ]
    }

    #[test]
    fn the_dialog_returns_the_first_styles_limits_untouched() {
        let env = Env::new();
        let out = env.spawn(ShellHost::ask_create_captions(env.handle(), styles(), 0));
        assert_eq!(env.dialog_title().as_deref(), Some("Create Captions"));
        env.answer(SQDialogResponse::FIRST);
        let choice = out.borrow().clone().flatten();
        assert_eq!(
            choice,
            Some(ShellCreateCaptionsChoice { style: 0, max_chars: 42, lines: 2, min_seconds: 1.0, gap_frames: 2 })
        );
    }

    #[test]
    fn cancel_and_no_styles_return_nothing() {
        let env = Env::new();
        let out = env.spawn(ShellHost::ask_create_captions(env.handle(), styles(), 1));
        env.answer(SQDialogResponse::SECOND);
        assert_eq!(out.borrow().clone(), Some(None));
        let none = env.spawn(ShellHost::ask_create_captions(env.handle(), Vec::new(), 0));
        assert_eq!(none.borrow().clone(), Some(None));
        assert!(!env.has_dialog());
    }

    #[test]
    fn replace_transcript_is_a_yes_no_question() {
        let env = Env::new();
        let out = env.spawn(ShellHost::confirm_replace_transcript(env.handle()));
        env.answer(SQDialogResponse::FIRST);
        assert_eq!(*out.borrow(), Some(true));
        let out = env.spawn(ShellHost::confirm_replace_transcript(env.handle()));
        env.answer(SQDialogResponse::SECOND);
        assert_eq!(*out.borrow(), Some(false));
    }
}

mod anonymize {
    use super::*;
    use sq_core_masks::anonymize::{AnonymizeBox, AnonymizeCover, AnonymizePerson};
    use sq_core_model::AnonymizeTarget;
    use sq_core_time::Vec2;
    use sq_editor_session::AnonymizeCheckLine;

    fn person(x: f64) -> AnonymizePerson {
        AnonymizePerson {
            label: 1,
            point: Vec2 { x, y: 0.5 },
            box_: AnonymizeBox { x: x - 0.05, y: 0.2, width: 0.1, height: 0.5 },
            face: None,
        }
    }

    #[test]
    fn everyone_is_ticked_and_the_choice_is_remembered() {
        let env = Env::new();
        let out = env.spawn(ShellHost::ask_anonymize(env.handle(), "Interview", vec![person(0.2), person(0.8)]));
        assert_eq!(env.dialog_title().as_deref(), Some("Anonymize"));
        assert_eq!(
            env.with(|r| r.shell.dialog().and_then(|d| d.header_subtitle.clone())).as_deref(),
            Some("Interview")
        );
        env.answer(SQDialogResponse::FIRST);
        let choice = out.borrow().clone().flatten();
        assert_eq!(
            choice.map(|c| (c.target, c.cover, c.people)),
            Some((AnonymizeTarget::Face, AnonymizeCover::Mosaic, vec![0, 1]))
        );
        assert_eq!(env.with(|r| r.shell.setting_string("sq.anonymize.target")).as_deref(), Some("face"));
    }

    #[test]
    fn cancel_returns_nothing() {
        let env = Env::new();
        let out = env.spawn(ShellHost::ask_anonymize(env.handle(), "Clip", vec![person(0.5)]));
        env.answer(SQDialogResponse::SECOND);
        assert_eq!(out.borrow().clone().map(|c| c.is_none()), Some(true));
    }

    #[test]
    fn the_check_list_goes_to_the_first_frame() {
        let env = Env::new();
        let lines = vec![
            AnonymizeCheckLine::new(Time::new(5, 1), "later", false),
            AnonymizeCheckLine::new(Time::new(9, 1), "critical", true),
        ];
        let out = env.spawn(ShellHost::ask_anonymize_checks(env.handle(), lines));
        env.answer(SQDialogResponse::FIRST);
        // critical ranges come first
        assert_eq!((*out.borrow()).flatten(), Some(Time::new(9, 1)));
        let none = env.spawn(ShellHost::ask_anonymize_checks(env.handle(), Vec::new()));
        assert_eq!((*none.borrow()).map(|t| t.is_none()), Some(true));
    }

    /// A host whose Anonymize command raises the sheet and records the answer.
    struct Anon {
        answers: Rc<RefCell<Vec<Option<sq_editor_session::AnonymizeChoice>>>>,
        events: Vec<crate::AnonymizeEvent>,
    }

    impl ShellServices for Anon {
        fn run_anonymize(&mut self, _: &mut sq_editor_session::EditorSession) -> bool {
            self.events.push(crate::AnonymizeEvent::Job(Some("Anonymize: looking for people".to_string())));
            self.events
                .push(crate::AnonymizeEvent::Ask { clip_name: "Interview".to_string(), people: vec![person(0.3)] });
            true
        }
        fn take_anonymize_events(&mut self) -> Vec<crate::AnonymizeEvent> {
            std::mem::take(&mut self.events)
        }
        fn anonymize_answer(
            &mut self,
            _: &mut sq_editor_session::EditorSession,
            c: Option<sq_editor_session::AnonymizeChoice>,
        ) {
            self.answers.borrow_mut().push(c);
        }
        fn anonymize_running(&self) -> bool {
            true
        }
    }

    #[test]
    fn the_flow_events_raise_the_sheet_and_the_answer_goes_back_to_the_host() {
        let env = Env::new();
        let answers = Rc::new(RefCell::new(Vec::new()));
        env.with(|r| {
            r.shell.flow_env.services = Box::new(Anon { answers: Rc::clone(&answers), events: Vec::new() });
        });
        env.cx(|h, cx| h.anonymize_command(cx));
        for f in env.with(|r| r.shell.take_flows()) {
            env.rt.ex.spawn_local(ShellHost::run_flow(env.handle(), f));
        }
        env.rt.run_until_stalled();
        assert_eq!(env.dialog_title().as_deref(), Some("Anonymize"));
        env.answer(SQDialogResponse::FIRST);
        let got = answers.borrow().clone();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].as_ref().map(|c| c.people.clone()), Some(vec![0]));
    }

    #[test]
    fn the_command_says_when_the_build_has_no_people_finder() {
        let env = Env::new();
        env.cx(|h, cx| h.anonymize_command(cx));
        assert_eq!(env.statuses(), vec!["Anonymize needs the people finder, which this build does not have."]);
    }
}

mod analysis {
    use super::*;

    fn run(env: &Env, c: EditorCommand) -> bool {
        env.cx(|h, cx| h.run_analysis_command(cx, c))
    }

    #[test]
    fn without_a_backend_the_commands_say_so() {
        let env = Env::new();
        assert!(run(&env, EditorCommand::FindSceneChanges));
        assert!(run(&env, EditorCommand::Stabilize));
        assert!(run(&env, EditorCommand::AutoReframe));
        assert_eq!(
            env.statuses(),
            vec![
                "Find Scene Changes is not available on this computer yet.",
                "Stabilize is not available on this computer yet.",
                "Auto Reframe is not available on this computer yet.",
            ]
        );
        assert!(!run(&env, EditorCommand::Save));
    }

    #[test]
    fn menu_rules_follow_the_targets() {
        let env = Env::new();
        let rule = |c| env.with(|r| r.shell.analysis_enabled(&r.session, c));
        assert_eq!(rule(EditorCommand::FindSceneChanges), Some(false));
        assert_eq!(rule(EditorCommand::MatchColorToClip), Some(false));
        assert_eq!(rule(EditorCommand::Save), None);
    }
}

mod background_offers {
    use super::*;

    #[test]
    fn nothing_is_offered_for_a_project_without_offline_media() {
        let env = Env::new();
        env.with(|r| r.shell.offer_relink_if_needed());
        for f in env.with(|r| r.shell.take_flows()) {
            env.rt.ex.spawn_local(ShellHost::run_flow(env.handle(), f));
        }
        env.rt.run_until_stalled();
        assert!(env.with(|r| r.shell.flow_env.relink_offer.is_none()));
    }

    #[test]
    fn accepting_an_offer_of_another_project_does_nothing() {
        let env = Env::new();
        env.with(|r| {
            r.shell.flow_env.relink_offer = Some(ShellRelinkOffer {
                text: ShellRelinkOffer::text(1, 1),
                plan: [(Id::fixed(7), "/x.mov".to_string())].into_iter().collect(),
                project_id: Id::fixed(99),
            });
            let (shell, session) = (&mut r.shell, &mut r.session);
            shell.accept_relink_offer(session);
        });
        assert!(env.with(|r| r.shell.flow_env.relink_offer.is_none()));
        assert!(env.statuses().is_empty());
    }
}

/// A project folder that is moved or renamed: the media stored with absolute paths of the old place links again on open
/// (Swift `relinkNearProject`), and media outside the folder is left alone.
mod moved_project {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaRef};
    use sq_core_time::SequentialIds;
    use sq_editor_session::{EditorSession, SessionDeps};
    use sq_runtime::WorkerPool;
    use std::sync::Arc;

    struct Pooled(Arc<WorkerPool>);

    impl ShellServices for Pooled {
        fn worker_pool(&self) -> Option<Arc<WorkerPool>> {
            Some(Arc::clone(&self.0))
        }
    }

    /// Saves a project at `url` with these media (id, path, size), as a session writes it.
    fn save_project(url: &std::path::Path, media: &[(u64, &std::path::Path, i64)]) {
        let mut ids = SequentialIds::default();
        let mut project = EditorSession::make_untitled(&mut ids);
        for (n, path, size) in media {
            project.add(MediaRef::new(
                Id::fixed(*n),
                "clip.mov",
                &path.to_string_lossy(),
                MediaFingerprint::new(*size),
            ));
        }
        let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-moved"));
        deps.ids = Box::new(ids);
        let mut s = EditorSession::new(project, deps);
        assert!(s.save_as(url).is_ok());
    }

    fn write(path: &std::path::Path, size: usize) {
        assert!(std::fs::create_dir_all(path.parent().unwrap_or(path)).is_ok());
        assert!(std::fs::write(path, vec![0u8; size]).is_ok());
    }

    /// Opens `url` in the shell, runs the background offer to the end and returns the paths that stay offline.
    fn open_and_offer(url: &std::path::Path) -> (Env, Vec<String>) {
        let env = Env::new();
        let pool = Arc::new(WorkerPool::manual());
        env.with(|r| r.shell.flow_env.services = Box::new(Pooled(Arc::clone(&pool))));
        assert!(env.with(|r| r.session.open(url).is_ok()));
        env.with(|r| r.shell.offer_relink_if_needed());
        for f in env.with(|r| r.shell.take_flows()) {
            env.rt.ex.spawn_local(ShellHost::run_flow(env.handle(), f));
        }
        env.rt.run_until_stalled();
        while pool.step() {
            env.rt.run_until_stalled();
        }
        let offline = env.with(|r| r.session.missing_media().iter().map(|m| m.path.clone()).collect());
        (env, offline)
    }

    #[test]
    fn a_moved_and_renamed_project_folder_links_its_files_again() {
        let root = temp("moved-project");
        let old = root.join("Old Name");
        let clip = old.join("Files").join("Imported").join("clip.mov");
        write(&clip, 3);
        save_project(&old.join("Cut.sqproj"), &[(1, &clip, 3)]);

        let new = root.join("elsewhere").join("New Name");
        assert!(std::fs::create_dir_all(new.parent().unwrap_or(&root)).is_ok());
        assert!(std::fs::rename(&old, &new).is_ok());

        let (env, offline) = open_and_offer(&new.join("Cut.sqproj"));
        assert!(offline.is_empty(), "still offline: {offline:?}");
        let moved = new.join("Files").join("Imported").join("clip.mov");
        let path = env.with(|r| r.session.project().media(Id::fixed(1)).map(|m| m.path.clone()));
        assert_eq!(path, Some(moved.to_string_lossy().into_owned()));
        assert!(env.statuses().iter().any(|s| s == "Reconnected 1 media file."));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_loose_project_with_a_file_outside_its_folder_keeps_working() {
        let root = temp("loose-project");
        let outside = root.join("Footage").join("outside.mov");
        write(&outside, 4);
        let old = root.join("Proj A");
        save_project(&old.join("Cut.sqproj"), &[(2, &outside, 4)]);
        let new = root.join("Proj B");
        assert!(std::fs::rename(&old, &new).is_ok());

        let (env, offline) = open_and_offer(&new.join("Cut.sqproj"));
        assert!(offline.is_empty(), "still offline: {offline:?}");
        let path = env.with(|r| r.session.project().media(Id::fixed(2)).map(|m| m.path.clone()));
        assert_eq!(path, Some(outside.to_string_lossy().into_owned()));
        assert!(env.statuses().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }
}

mod import {
    use super::*;

    #[test]
    fn a_file_that_is_not_a_premiere_project_is_refused() {
        let env = Env::new();
        env.spawn(ShellHost::import_premiere_project(env.handle(), PathBuf::from("/a/clip.mov")));
        assert_eq!(env.dialog_title().as_deref(), Some("“clip.mov” is not a Premiere project"));
    }
}

mod interchange {
    use super::*;
    use crate::shell_interchange::InterchangeFile;
    use sq_export::formats::InterchangeExport;

    #[test]
    fn the_status_names_the_file_layers_and_notes() {
        let dir = temp("interchange");
        let file = InterchangeFile {
            ext: "edl",
            label: "EDL",
            main: InterchangeExport::new(
                "TITLE: A\n".into(),
                vec!["note one".into(), "note two".into(), "note three".into()],
            ),
            extras: vec![(" V2".into(), InterchangeExport::new("TITLE: B\n".into(), Vec::new()))],
        };
        let line = ShellHost::write_interchange(&file, &dir.join("Cut.edl"));
        assert_eq!(line.ok().as_deref(), Some("Exported Cut.edl. Plus 1 layer file. 3 notes: note one; note two"));
        assert!(dir.join("Cut.edl").exists() && dir.join("Cut V2.edl").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn media_is_found_as_stored_or_beside_the_interchange_file_or_in_a_search_folder() {
        let dir = temp("locate");
        let beside = dir.join("beside.mov");
        let other = temp("locate-search");
        let searched = other.join("searched.mov");
        assert!(std::fs::write(&beside, b"x").is_ok() && std::fs::write(&searched, b"x").is_ok());
        let paths = vec![
            beside.to_string_lossy().into_owned(),
            "/gone/beside.mov".to_string(),
            "C:\\old\\searched.mov".to_string(),
            "/gone/missing.mov".to_string(),
            String::new(),
        ];
        let found = ShellHost::locate_interchange_media(&paths, &dir.join("cut.edl"), std::slice::from_ref(&other));
        assert_eq!(found.get(&paths[0]), Some(&paths[0]));
        assert_eq!(found.get("/gone/beside.mov"), Some(&beside.to_string_lossy().into_owned()));
        assert_eq!(found.get("C:\\old\\searched.mov"), Some(&searched.to_string_lossy().into_owned()));
        assert_eq!(found.len(), 3);
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&other);
    }

    #[test]
    fn an_export_without_a_chosen_place_writes_nothing() {
        let env = Env::new();
        env.spawn(ShellHost::export_interchange(env.handle(), EditorCommand::ExportEDL));
        assert!(!env.has_dialog());
    }
}

mod library_import {
    use super::*;

    #[test]
    fn presets_without_a_store_say_so() {
        let env = Env::new();
        env.spawn(ShellHost::import_premiere_presets(env.handle(), PathBuf::from("/a/p.prfpset"), true));
        assert_eq!(env.statuses(), vec![crate::shell_platform_text::ShellPlatformText::not_available().to_string()]);
    }

    #[test]
    fn templates_without_a_store_say_so() {
        let env = Env::new();
        env.spawn(ShellHost::import_motion_graphics_templates(env.handle(), vec![PathBuf::from("/a/t.mogrt")]));
        assert_eq!(env.statuses(), vec![crate::shell_platform_text::ShellPlatformText::not_available().to_string()]);
    }
}

mod card_import {
    use super::*;

    /// P20: card import went to the app services, which had no import, and ended in "Import is not available yet."
    #[test]
    fn card_import_hands_the_picked_clips_to_the_project_panel() {
        let env = Env::new();
        // The panel's import runs on the test pool, which `run_until_stalled` drives.
        env.with(|r| {
            let mut deps = sq_editor_session::ProjectPanelDeps::headless();
            deps.pool = std::sync::Arc::clone(&env.rt.pool);
            r.panel = sq_editor_session::ProjectPanelModel::new(r.session.project().clone(), deps);
        });
        let volume = temp("card-volume");
        let clip = volume.join("C0001.MP4");
        assert!(std::fs::write(&clip, b"x").is_ok());
        env.spawn(ShellHost::import_from_card(env.handle(), vec![clip], false));
        let said = env.statuses();
        assert!(!said.iter().any(|s| s.contains("not available")), "{said:?}");
        assert!(said.iter().any(|s| s == "Importing…"), "{said:?}");
        // The headless backend probes nothing, so the panel ran its import and reported the one file it could not read.
        let report = env.with(|r| r.panel.last_import_report().cloned());
        assert!(report.is_some(), "the panel never ran an import");
    }

    #[test]
    fn an_empty_card_says_so_and_frees_the_volume() {
        let env = Env::new();
        let card = temp("card-empty");
        env.with(|r| r.shell.open_card_import(&card, false));
        // a second call while the first is queued does nothing
        env.with(|r| r.shell.open_card_import(&card, false));
        assert_eq!(env.with(|r| r.shell.take_flows().len()), 1);
        env.tool(ShellTool::CardImport(card.clone()));
        let name = card.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        assert_eq!(env.statuses(), vec![format!("Reading “{name}”…"), format!("“{name}” holds no videos or photos.")]);
        assert!(env.with(|r| r.shell.flow_env.card_import_volumes.is_empty()));
        let _ = std::fs::remove_dir_all(&card);
    }

    #[test]
    fn the_dialog_keeps_open_for_select_all_and_for_an_import_with_nothing_ticked() {
        let env = Env::new();
        let card = temp("card-files");
        assert!(std::fs::write(card.join("A001.mp4"), b"x").is_ok());
        assert!(std::fs::write(card.join("B001.jpg"), b"x").is_ok());
        env.tool(ShellTool::CardImport(card.clone()));
        assert!(env.has_dialog());
        assert!(env.dialog_title().is_some_and(|t| t.starts_with("Import from ")));
        // Copy & Import with nothing ticked says so and stays
        env.statuses();
        env.answer(SQDialogResponse::FIRST);
        assert!(env.has_dialog());
        let events = env.with(|r| r.shell.take_events());
        assert!(events.contains(&ShellEvent::Status("Tick the files to import first.".to_string())));
        // Select All stays open as well
        env.answer(SQDialogResponse::THIRD);
        assert!(env.has_dialog());
        // closing the volume closes the dialog like Cancel
        env.with(|r| r.shell.close_card_import(&card));
        env.rt.run_until_stalled();
        assert!(!env.has_dialog());
        assert!(env.with(|r| r.shell.flow_env.card_import_volumes.is_empty()));
        let _ = std::fs::remove_dir_all(&card);
    }

    #[test]
    fn the_start_window_holds_back_a_card_that_was_mounted_at_launch() {
        let env = Env::new();
        let card = temp("card-launch");
        env.cx(|h, cx| h.perform(cx, ShellAction::StartWindow));
        assert!(env.with(|r| r.shell.is_start_shown()));
        env.with(|r| r.shell.open_card_import(&card, true));
        assert!(env.with(|r| r.shell.take_flows().is_empty()));
        let _ = std::fs::remove_dir_all(&card);
    }
}

mod loudness {
    use super::*;
    use crate::LoudnessState;
    use crate::shell_flow_env::LoudnessMeasurer;
    use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds, TimeRange};
    use sq_editor_session::{EditorSession, SessionDeps};
    use sq_runtime::WorkerPool;
    use std::sync::Arc;

    /// A pool the test steps by hand and a measurer that reads a fixed level.
    struct Fake {
        pool: Arc<WorkerPool>,
        lufs: Option<f64>,
    }

    impl ShellServices for Fake {
        fn worker_pool(&self) -> Option<Arc<WorkerPool>> {
            Some(Arc::clone(&self.pool))
        }
        fn loudness_measurer(&self, _m: Vec<sq_core_model::MediaRef>, _s: Vec<Timeline>) -> Option<LoudnessMeasurer> {
            let lufs = self.lufs;
            Some(Arc::new(move |_t, _r, cancel| if cancel.is_cancelled() { None } else { lufs }))
        }
    }

    /// One selected audio clip on a project with a fake measurer; returns the clip's id and the pool.
    fn rig(lufs: Option<f64>) -> (Env, Id, Arc<WorkerPool>) {
        let env = Env::new();
        let mut ids = SequentialIds::default();
        let clip = Clip::new(
            ids.next_id(),
            "a",
            ids.next_id(),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::ZERO,
        );
        let id = clip.id;
        let mut track = Track::new(ids.next_id(), TrackKind::Audio);
        assert!(track.overwrite(clip, &mut ids).is_ok());
        let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
        let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-loud"));
        deps.ids = Box::new(ids);
        let pool = Arc::new(WorkerPool::manual());
        env.with(|r| {
            r.session = EditorSession::new(project, deps);
            r.session.set_selection([id].into_iter().collect(), Default::default());
            r.shell.flow_env.services = Box::new(Fake { pool: Arc::clone(&pool), lufs });
        });
        (env, id, pool)
    }

    fn gain(env: &Env, id: Id) -> f64 {
        env.with(|r| {
            let t = r.session.active_timeline().cloned();
            t.and_then(|t| t.tracks.iter().flat_map(|tr| tr.clips().to_vec()).find(|c| c.id == id))
                .map_or(f64::NAN, |c| c.audio_gain_db)
        })
    }

    fn state(env: &Env) -> LoudnessState {
        env.with(|r| r.shell.flow_env.loudness.clone())
    }

    #[test]
    fn match_loudness_waits_for_the_worker_then_sets_the_gain() {
        let (env, id, pool) = rig(Some(-24.0));
        env.tool(ShellTool::MatchLoudness);
        assert!(matches!(state(&env), LoudnessState::Measuring { done: 0, total: 1, .. }));
        assert_eq!(pool.pending(), 1);
        assert_eq!(gain(&env, id), 0.0);
        assert!(pool.step());
        env.rt.run_until_stalled();
        assert!(matches!(state(&env), LoudnessState::Idle));
        assert_eq!(gain(&env, id), 10.0);
        assert!(env.statuses().iter().any(|s| s == "Matched 1 clip to -14 LUFS."));
    }

    #[test]
    fn canceling_ends_the_flow_without_a_result() {
        let (env, id, pool) = rig(Some(-24.0));
        env.tool(ShellTool::MatchLoudness);
        env.with(|r| r.shell.cancel_loudness());
        assert!(pool.step());
        env.rt.run_until_stalled();
        assert!(matches!(state(&env), LoudnessState::Idle));
        assert_eq!(gain(&env, id), 0.0);
        assert!(!env.statuses().iter().any(|s| s.starts_with("Matched")));
    }

    #[test]
    fn a_second_request_is_refused_while_one_measures() {
        let (env, _id, pool) = rig(Some(-24.0));
        env.tool(ShellTool::MatchLoudness);
        env.tool(ShellTool::VoiceChainReadout);
        assert_eq!(pool.pending(), 1);
        assert!(env.statuses().iter().any(|s| s == "Still measuring loudness..."));
    }

    #[test]
    fn the_voice_chain_readout_says_the_loudness_when_the_number_arrives() {
        let (env, _id, pool) = rig(Some(-14.0));
        env.tool(ShellTool::VoiceChainReadout);
        assert!(pool.step());
        env.rt.run_until_stalled();
        assert!(env.statuses().iter().any(|s| s.contains("-14.0 LUFS")));
        assert!(matches!(state(&env), LoudnessState::Idle));
    }

    #[test]
    fn silence_matches_nothing() {
        let (env, id, pool) = rig(None);
        env.tool(ShellTool::MatchLoudness);
        assert!(pool.step());
        env.rt.run_until_stalled();
        assert_eq!(gain(&env, id), 0.0);
        assert!(env.statuses().iter().any(|s| s == "The audio is silent: nothing to match."));
    }
}
