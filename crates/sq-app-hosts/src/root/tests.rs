//! Headless tests of the root: layout, input routing and the answers to queued requests.

use super::*;
use crate::{MonitorHost, TimelinePanelHost};
use sq_app_shell::{App, AppDeps, Headless};
use sq_core_time::{Id, SequentialIds, Time};
use sq_draw::InputModifiers;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::ui_cx::DrawCursor;
use sq_draw_monitor::memory_defaults::MemoryDefaults;
use sq_draw_monitor::meter_panel::MeterPanel;
use sq_draw_monitor::monitor_panel::MonitorPanel;
use sq_draw_monitor::monitor_panel_model::MonitorPanelModel;
use sq_draw_shell::ShellDialog;
use sq_draw_timeline::host::TimelineEditorRequest;
use sq_editor_session::SessionDeps;
use sq_library::library_folder_store::SettingsStore;
use sq_runtime::FakeClock;
use std::sync::Arc;

pub(super) fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

pub(super) fn root() -> AppRoot {
    let root_dir = crate::test_rig::unique_dir("sq-app-hosts-root");
    std::fs::create_dir_all(&root_dir).expect("dir");
    let monitor =
        MonitorHost::new(MonitorPanel::new(MonitorPanelModel::new(Time::new(1001, 30000), MonitorMode::Program), None));
    let inspector = crate::InspectorHost::new(Box::new(|_, _| panic!("no audio clip is shown in these tests")));
    let (hooks, link) = crate::TimelineHooks::new(Default::default());
    let shell = crate::ShellHost::new(
        sq_draw_shell::ShellHost::new(
            sq_uikit::command_map::CommandMap::premiere_default(),
            sq_editor_session::RecentProjects::new(Vec::new()),
            Arc::new(FakeClock::new()),
            Box::new(|| sq_core_time::Timestamp::from_unix_seconds(0.0)),
        ),
        Some(Box::new(hooks)),
    );
    AppRoot::new(
        monitor,
        crate::library_host::test_host(&root_dir),
        TimelinePanelHost::new(DrawTheme::default()),
        inspector,
        shell,
    )
    .with_timeline_link(link)
}

fn laid_out(r: &mut AppRoot) {
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut crate::test_rig::Rig::new(session()).cx());
}

#[test]
fn the_panels_sit_in_the_dock_content_frames() {
    let mut r = root();
    laid_out(&mut r);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let lib = r.dock.content_frame(PanelID::Library).expect("library docked");
    assert!(tl.width > 0.0 && tl.height > 0.0 && lib.width > 0.0);
    assert!(r.dock.frame.contains(CGPoint::new(tl.min_x() + 1.0, tl.min_y() + 1.0)));
}

#[test]
fn a_host_menu_request_opens_the_menu_at_once() {
    let mut r = root();
    laid_out(&mut r);
    let mut rig = crate::test_rig::Rig::new(session());
    r.open_menu(
        &rig.cx(),
        vec![SQMenuItem::new("One")],
        CGRect::new(300.0, 300.0, 0.0, 0.0),
        Some(CGPoint::new(300.0, 300.0)),
    );
    assert!(r.menu.is_open());
    assert_eq!(r.menu.root_items().len(), 1);
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    let (_, list) = h.turn();
    assert!(list.is_some());
}

#[test]
fn a_dialog_takes_every_event_until_it_finishes() {
    let mut r = root();
    r.show_dialog(ShellDialog::new("Title", "Note"));
    assert!(r.has_dialog());
    laid_out(&mut r);
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    h.turn();
    let down = InputEvent::MouseDown { x: 900.0, y: 200.0, modifiers: InputModifiers::NONE };
    assert!(h.input(&down), "the dialog swallows a press on the library");
}

#[test]
fn a_timeline_request_without_an_editor_shows_its_status_line() {
    let mut r = root();
    assert_eq!(r.timeline.inner().host.request(&TimelineEditorRequest::Marker(Id::from_u128(1))), None);
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    h.turn();
    h.input(&InputEvent::MouseMoved { x: 5.0, y: 5.0 });
    let status = h.with(|a| a.status_text().to_string()).unwrap_or_default();
    assert_eq!(status, TimelineEditorRequest::Marker(Id::from_u128(1)).unavailable());
}

#[test]
fn a_caption_word_that_does_not_open_falls_back_to_the_caption_text_request() {
    let mut r = root();
    let word = sq_timeline_ui::caption_word_layout::CaptionWordRef::new(Id::from_u128(9), 0);
    assert!(r.timeline.inner().host.open.as_mut().is_some_and(|open| open(&TimelineEditorRequest::CaptionWord(word))));
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    h.turn();
    h.input(&InputEvent::MouseMoved { x: 5.0, y: 5.0 });
    let status = h.with(|a| a.status_text().to_string()).unwrap_or_default();
    assert_eq!(status, TimelineEditorRequest::CaptionText(Id::from_u128(9)).unavailable());
}

#[test]
fn the_root_draws_all_three_panels_and_routes_clicks_by_position() {
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(root())));
    let (_, list) = h.turn();
    assert!(list.is_some_and(|l| !l.quads().is_empty()));
    let down = |x, y| InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE };
    assert!(h.input(&down(900.0, 200.0)), "library region");
    assert!(h.input(&down(500.0, 600.0)), "timeline region");
}

/// Choosers that answer with fixed paths, as a user picking a file would.
struct Scripted {
    project: Option<std::path::PathBuf>,
    save_to: Option<std::path::PathBuf>,
}

impl sq_app_shell::ShellFilePicker for Scripted {
    fn choose_project(&mut self) -> sq_runtime::ModalAsk<Option<std::path::PathBuf>> {
        sq_app_shell::answered(self.project.clone())
    }
    fn choose_save_location(&mut self, _name: &str, _prompt: &str) -> sq_runtime::ModalAsk<Option<std::path::PathBuf>> {
        sq_app_shell::answered(self.save_to.clone())
    }
    fn choose_media(&mut self) -> sq_runtime::ModalAsk<Vec<std::path::PathBuf>> {
        sq_app_shell::answered(Vec::new())
    }
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = crate::test_rig::unique_dir(&format!("sq-app-hosts-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// A window over `support` with scripted choosers; the start window is up when the session is untitled.
fn window(support: &std::path::Path, files: Scripted, session: EditorSession) -> Headless {
    let mut deps = AppDeps::headless(Arc::new(FakeClock::new()));
    deps.services.files = Box::new(files);
    let h = Headless::new(session, deps, 1000, 800);
    let root = crate::standard_root(support, Arc::new(FakeClock::new()), DrawTheme::default()).expect("root");
    h.with(|a| {
        a.add_host(Box::new(root));
        a.launch();
    });
    h
}

fn run(h: &Headless, action: sq_draw_shell::ShellAction) {
    h.with(|a| {
        use sq_draw_shell::{NoHooks, ShellCx, ShellRoot};
        let (mut ui, p) = (sq_draw::UiCx::new(), a.shell_parts());
        let mut sc = ShellCx {
            session: p.session,
            measure: sq_draw::TextMeasure::new(None, 1.0),
            ui: &mut ui,
            hooks: &mut NoHooks,
        };
        p.shell.perform(&mut sc, action);
    });
    h.with(App::settle);
    for _ in 0..3 {
        h.turn();
    }
}

#[test]
fn an_untitled_launch_shows_the_start_window_and_a_project_launch_does_not() {
    let dir = scratch("launch");
    let h = window(&dir, Scripted { project: None, save_to: None }, session());
    assert_eq!(h.with(|a| sq_draw_shell::ShellRoot::shell_parts(a).shell.is_start_shown()), Some(true));
    let project = dir.join("open.sqproj");
    let mut s = session();
    s.save_as(&project).expect("save");
    let mut opened = session();
    opened.open(&project).expect("open");
    let h = window(&dir, Scripted { project: None, save_to: None }, opened);
    assert_eq!(h.with(|a| sq_draw_shell::ShellRoot::shell_parts(a).shell.is_start_shown()), Some(false));
}

#[test]
fn pip_on_the_start_window_plays_without_input_until_he_settles() {
    let dir = scratch("pip-frames");
    let h = window(&dir, Scripted { project: None, save_to: None }, session());
    for _ in 0..6 {
        h.turn();
    }
    assert_eq!(h.with(|a| sq_draw_shell::ShellRoot::shell_parts(a).shell.start_mascot_animating()), Some(true));
    assert_eq!(h.with(|a| a.needs_redraw()), Some(true), "no input, yet the loop keeps drawing for Pip while he plays");
}

#[test]
fn file_menu_open_save_as_and_quit_run_on_the_session() {
    use sq_draw_shell::ShellAction as C;
    let dir = scratch("flows");
    let (a_path, b_path) = (dir.join("a.sqproj"), dir.join("b.sqproj"));
    let mut s = session();
    s.save_as(&a_path).expect("save");
    let h = window(&dir, Scripted { project: Some(a_path.clone()), save_to: Some(b_path.clone()) }, session());
    run(&h, C::Command(sq_uikit::editor_command::EditorCommand::OpenProject));
    let url = h.with(|a| a.session().file_url().map(std::path::Path::to_path_buf)).flatten();
    assert_eq!(url, Some(a_path));
    run(&h, C::Command(sq_uikit::editor_command::EditorCommand::SaveAs));
    let url = h.with(|a| a.session().file_url().map(std::path::Path::to_path_buf)).flatten();
    assert_eq!(url, Some(b_path.clone()));
    assert!(b_path.exists());
    assert!(dir.join("recents.json").exists(), "the recent list is stored");
    assert_eq!(h.with(|a| a.quit_requested()), Some(false));
    run(&h, C::Quit);
    assert_eq!(h.with(|a| a.quit_requested()), Some(true));
}

#[test]
fn the_dock_layout_is_stored_in_the_support_folder() {
    let dir = scratch("dock");
    let mut r = root().with_storage(dir.join("workspaces.json"), dir.join("recents.json"));
    r.dock.set_frame(CGRect::new(0.0, 0.0, 1000.0, 800.0));
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    r.dock.toggle(PanelID::Library);
    h.with(|a| a.add_host(Box::new(r)));
    h.turn();
    assert!(dir.join("workspaces.json").exists());
}

/// V1 holds clips A (0-2 s) and B (2-4 s); nothing selected, playhead at 1 s.
fn edit_session() -> EditorSession {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        t.tracks[0].is_targeted = true;
        for (n, start) in [(1u128, 0), (2, 2)] {
            let c = sq_core_model::Clip::new(
                Id::from_u128(n),
                "clip",
                Id::from_u128(100 + n),
                sq_core_model::TrackKind::Video,
                sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(2)),
                Time::seconds(start),
            );
            assert!(t.tracks[0].insert(c, &mut ids).is_ok());
        }
    });
    s.take_changes();
    s.seek(Time::seconds(1));
    s
}

fn editing() -> Headless {
    let h = Headless::new(edit_session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(root())));
    h.turn();
    // A press on the timeline gives it the keyboard focus, as it does for the user.
    h.input(&InputEvent::MouseDown { x: 500.0, y: 700.0, modifiers: InputModifiers::NONE });
    h.input(&InputEvent::MouseUp { x: 500.0, y: 700.0 });
    h.turn();
    h.with(|a| a.session_mut().seek(Time::seconds(1)));
    h
}

fn clip_count(h: &Headless) -> usize {
    h.with(|a| a.session().active_timeline().map_or(0, |t| t.tracks[0].clips().len())).unwrap_or(0)
}

fn press(h: &Headless, key: sq_draw::InputKey, modifiers: InputModifiers) -> bool {
    let taken = h.input(&InputEvent::KeyDown { key, modifiers });
    h.turn();
    taken
}

fn command_key(c: char) -> (sq_draw::InputKey, InputModifiers) {
    (sq_draw::InputKey::Character(c), InputModifiers::COMMAND)
}

#[test]
fn the_split_shortcut_cuts_at_the_playhead_and_undo_restores_it() {
    let h = editing();
    assert_eq!(clip_count(&h), 2);
    let (k, m) = command_key('k');
    assert!(press(&h, k, m));
    assert_eq!(clip_count(&h), 3);
    let (k, m) = command_key('z');
    assert!(press(&h, k, m));
    assert_eq!(clip_count(&h), 2);
    let redo = InputModifiers::COMMAND | InputModifiers::SHIFT;
    assert!(press(&h, sq_draw::InputKey::Character('z'), redo));
    assert_eq!(clip_count(&h), 3);
}

#[test]
fn delete_and_ripple_delete_remove_the_selected_clip() {
    let h = editing();
    h.with(|a| a.session_mut().select(std::collections::BTreeSet::from([Id::from_u128(1)]), Default::default()));
    assert!(press(&h, sq_draw::InputKey::Delete, InputModifiers::NONE));
    assert_eq!(clip_count(&h), 1);
    let (k, m) = command_key('z');
    press(&h, k, m);
    assert_eq!(clip_count(&h), 2);
    h.with(|a| a.session_mut().select(std::collections::BTreeSet::from([Id::from_u128(1)]), Default::default()));
    assert!(press(&h, sq_draw::InputKey::Delete, InputModifiers::SHIFT));
    let start = h.with(|a| a.session().active_timeline().map(|t| t.tracks[0].clips()[0].start)).flatten();
    assert_eq!(start, Some(Time::ZERO), "the remaining clip closed the gap");
}

#[test]
fn copy_cut_and_paste_move_a_clip_through_the_clipboard() {
    let h = editing();
    h.with(|a| a.session_mut().select(std::collections::BTreeSet::from([Id::from_u128(1)]), Default::default()));
    let (k, m) = command_key('x');
    assert!(press(&h, k, m));
    assert_eq!(clip_count(&h), 1);
    h.with(|a| a.session_mut().seek(Time::seconds(6)));
    let (k, m) = command_key('v');
    assert!(press(&h, k, m));
    assert_eq!(clip_count(&h), 2);
    let (k, m) = command_key('a');
    assert!(press(&h, k, m));
    assert_eq!(h.with(|a| a.session().selection().len()), Some(2));
}

#[test]
fn space_toggles_playback_and_the_arrows_step_the_playhead() {
    let h = editing();
    assert!(press(&h, sq_draw::InputKey::Space, InputModifiers::NONE));
    assert_eq!(h.with(|a| a.session().is_playing()), Some(true));
    assert!(press(&h, sq_draw::InputKey::Space, InputModifiers::NONE));
    assert_eq!(h.with(|a| a.session().is_playing()), Some(false));
    let before = h.with(|a| a.session().playhead()).unwrap_or(Time::ZERO);
    assert!(press(&h, sq_draw::InputKey::Right, InputModifiers::NONE));
    let after = h.with(|a| a.session().playhead()).unwrap_or(Time::ZERO);
    assert_eq!(after, before + Time::new(1, 30));
    assert!(press(&h, sq_draw::InputKey::Home, InputModifiers::NONE));
    assert_eq!(h.with(|a| a.session().playhead()), Some(Time::ZERO));
    assert!(press(&h, sq_draw::InputKey::End, InputModifiers::NONE));
    assert_eq!(h.with(|a| a.session().playhead()), Some(Time::seconds(4)), "End is the sequence end");
}

#[test]
fn j_k_and_l_shuttle_the_playback_and_k_stops_it() {
    let key = |h: &Headless, c: char| press(h, sq_draw::InputKey::Character(c), InputModifiers::NONE);
    let h = editing();
    assert!(key(&h, 'l'));
    assert_eq!(h.with(|a| a.session().is_playing()), Some(true));
    assert!(key(&h, 'l'));
    assert!(key(&h, 'l'));
    assert_eq!(h.with(|a| a.session().is_playing()), Some(true));
    assert!(key(&h, 'k'));
    assert_eq!(h.with(|a| a.session().is_playing()), Some(false));
    // A fresh session: J alone plays backward (K is still held above, which would make J a slow step).
    let h = editing();
    assert!(key(&h, 'j'));
    assert_eq!(h.with(|a| a.session().is_playing()), Some(true));
}

#[test]
fn i_and_o_mark_the_range_around_the_playhead() {
    let h = editing();
    let key = |h: &Headless, c: char| press(h, sq_draw::InputKey::Character(c), InputModifiers::NONE);
    assert!(key(&h, 'i'));
    h.with(|a| a.session_mut().seek(Time::seconds(3)));
    assert!(key(&h, 'o'));
    let range = h.with(|a| a.session().active_timeline().and_then(|t| t.in_out)).flatten();
    assert_eq!(range.map(|r| (r.start, r.end())), Some((Time::seconds(1), Time::seconds(3) + Time::new(1, 30))));
}

#[test]
fn a_timeline_menu_command_runs_through_the_shell() {
    let mut r = root();
    let queued = r.timeline.inner().host.command.as_mut().map(|f| f(sq_uikit::editor_command::EditorCommand::AddEdit));
    assert!(queued.is_some());
    let h = Headless::new(edit_session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    h.turn();
    h.input(&InputEvent::MouseMoved { x: 5.0, y: 5.0 });
    assert_eq!(clip_count(&h), 3);
}

#[test]
fn the_project_panel_is_docked_and_a_drop_on_the_timeline_places_the_media() {
    let mut r = root();
    laid_out(&mut r);
    let panel = r.dock.content_frame(PanelID::Project).expect("project docked");
    assert!(panel.width > 0.0 && panel.height > 0.0);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");

    let id = Id::from_u128(77);
    let mut media =
        sq_core_model::MediaRef::new(id, "interview", "/tmp/i.mp4", sq_core_model::MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(4));
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-root-project"));
    let mut session = EditorSession::new(project, deps);
    let mut deps = AppDeps::headless(Arc::new(FakeClock::new()));
    let mut ui = sq_draw::UiCx::new();
    let mut events = Vec::new();
    let mut cx = HostCx {
        session: &mut session,
        ui: &mut ui,
        services: &mut deps.services,
        events: &mut events,
        atlas: None,
        scale: 1.0,
    };
    r.sync(cx.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut cx);
    r.sync(cx.session);
    // The list raises this when the pointer is released over the timeline.
    r.project.defer(ProjectListEvent::Drag {
        refs: vec![sq_core_model::BinItemRef::Media(id)],
        phase: ProjectDragPhase::Ended,
        x: (tl.min_x() + 400.0) as f32,
        y: (tl.min_y() + 60.0) as f32,
    });
    r.answer(&mut cx);
    assert!(cx.session.active_timeline().is_some_and(|t| t.tracks.iter().any(|tr| !tr.clips().is_empty())));
}

#[test]
fn a_project_drop_lands_under_the_pointer_not_at_the_playhead() {
    let mut r = root();
    let id = Id::from_u128(77);
    let mut media =
        sq_core_model::MediaRef::new(id, "interview", "/tmp/i.mp4", sq_core_model::MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(4));
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let mut rig = crate::test_rig::Rig::new(EditorSession::new(
        project,
        SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-root-pointer-drop")),
    ));
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.sync(&rig.session);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let (x, y) = ((tl.min_x() + 400.0) as f32, (tl.min_y() + 60.0) as f32);
    let drag = |phase| ProjectListEvent::Drag { refs: vec![sq_core_model::BinItemRef::Media(id)], phase, x, y };
    r.project.defer(drag(ProjectDragPhase::Moved));
    r.answer(&mut rig.cx());
    assert!(r.timeline.inner().panel.drop_hover_active(), "the ghost follows the pointer");
    r.project.defer(drag(ProjectDragPhase::Ended));
    r.answer(&mut rig.cx());
    assert!(!r.timeline.inner().panel.drop_hover_active());
    let start =
        rig.session.active_timeline().and_then(|t| t.tracks.iter().flat_map(|k| k.clips()).map(|c| c.start).min());
    assert!(start.is_some_and(|s| s > Time::ZERO), "placed at the pointer, not the playhead: {start:?}");
}

#[test]
fn command_held_on_a_drag_makes_the_timeline_drop_an_insert() {
    let mut r = root();
    let id = Id::from_u128(77);
    let mut media =
        sq_core_model::MediaRef::new(id, "interview", "/tmp/i.mp4", sq_core_model::MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(4));
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let mut rig = crate::test_rig::Rig::new(EditorSession::new(
        project,
        SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-root-command-drop")),
    ));
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.sync(&rig.session);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let (x, y) = ((tl.min_x() + 400.0) as f32, (tl.min_y() + 60.0) as f32);
    let moved = |m| InputEvent::MouseDragged { x, y, modifiers: m };
    let drag = |phase| ProjectListEvent::Drag { refs: vec![sq_core_model::BinItemRef::Media(id)], phase, x, y };
    r.handle(&moved(sq_draw::InputModifiers::NONE), &mut rig.cx());
    r.project.defer(drag(ProjectDragPhase::Moved));
    r.answer(&mut rig.cx());
    assert!(r.timeline.inner().panel.drop_hover_active());
    assert!(!r.timeline.inner().panel.drop_inserts(), "no key: overwrite");
    // Command pressed mid-drag: the next move of the ghost inserts.
    r.handle(&moved(sq_draw::InputModifiers::COMMAND), &mut rig.cx());
    r.project.defer(drag(ProjectDragPhase::Moved));
    r.answer(&mut rig.cx());
    assert!(r.timeline.inner().panel.drop_inserts(), "Command held on the drag: insert");
}

#[test]
fn dragging_a_track_boundary_resizes_the_track_and_keeps_the_height() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(edit_session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.sync(&rig.session);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let x = (tl.min_x() + 90.0) as f32;
    let mut resized = false;
    // The boundary sits between two track headers: probe rows of the header column the way a pointer would find it.
    let mut y = tl.min_y() + 20.0;
    while !resized && y < tl.max_y() {
        r.handle(&InputEvent::MouseDown { x, y: y as f32, modifiers: InputModifiers::NONE }, &mut rig.cx());
        r.handle(&InputEvent::dragged(x, y as f32 + 24.0), &mut rig.cx());
        r.handle(&InputEvent::MouseUp { x, y: y as f32 + 24.0 }, &mut rig.cx());
        resized = !r.timeline.inner().panel.geometry.height_overrides.is_empty();
        y += 2.0;
    }
    assert!(resized, "a drag on a track boundary sets a height");
}

#[test]
fn a_double_click_in_the_project_panel_opens_the_source_in_the_dock() {
    use crate::{MonitorPicture, SourceMonitorHost};
    let source = SourceMonitorHost::new(
        Box::new(sq_editor_session::StubProgramEngine::new()),
        MonitorPicture::default(),
        Box::new(SequentialIds::default()),
    );
    let mut r = root().with_source(source);
    let mut media =
        sq_core_model::MediaRef::new(Id::from_u128(77), "i", "/tmp/i.mp4", sq_core_model::MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(4));
    media.info = serde_json::from_value(serde_json::json!({
        "duration": {"value": 4, "timescale": 1},
        "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0}
    }))
    .ok();
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let mut session =
        EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-src")));
    let mut deps = AppDeps::headless(Arc::new(FakeClock::new()));
    let mut ui = sq_draw::UiCx::new();
    let mut events = Vec::new();
    let mut cx = HostCx {
        session: &mut session,
        ui: &mut ui,
        services: &mut deps.services,
        events: &mut events,
        atlas: None,
        scale: 1.0,
    };
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut cx);
    r.project.defer(ProjectListEvent::OpenMedia(Id::from_u128(77)));
    r.answer(&mut cx);
    assert_eq!(r.source.as_ref().and_then(|s| s.core().media_id()), Some(Id::from_u128(77)));
    assert_eq!(r.dock.focused(), Some(PanelID::SourceMonitor));
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut cx);
    assert!(r.dock.shows(PanelID::SourceMonitor));
}

fn effects_cx_session() -> EditorSession {
    let mut s = edit_session();
    s.seek(Time::ZERO);
    s
}

fn root_with_effects() -> AppRoot {
    let effects = crate::EffectsHost::new(sq_draw_library::effects::effects_draw_panel::EffectsDrawPanel::new(
        Box::new(sq_draw_monitor::memory_defaults::MemoryDefaults::default()),
        Box::new(SequentialIds::default()),
    ));
    root().with_effects(effects)
}

fn effect_count(s: &EditorSession) -> usize {
    s.active_timeline().map_or(0, |t| t.tracks[0].clips().iter().map(|c| c.effects.len()).sum())
}

#[test]
fn an_effect_dropped_on_a_timeline_clip_is_added_with_undo() {
    use crate::EffectsDeferred;
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.sync(&rig.session);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let ids = vec!["gaussianBlur".to_string()];
    // Find a point over a clip the way the pointer would: the first one the hover lights.
    let mut hit = None;
    let mut y = tl.min_y();
    while hit.is_none() && y < tl.max_y() {
        let mut x = tl.min_x();
        while hit.is_none() && x < tl.max_x() {
            if r.timeline.inner().panel.effect_drop_hover(&ids, x as f32, y as f32, Time::seconds(1)) {
                hit = Some(CGPoint::new(x, y));
            }
            x += 8.0;
        }
        y += 4.0;
    }
    let at = hit.expect("a clip lights up for the effect");
    r.effects.as_mut().expect("effects").defer(EffectsDeferred::Moved(ids.clone(), at));
    r.answer(&mut rig.cx());
    assert_eq!(effect_count(&rig.session), 0, "hovering changes nothing");
    r.effects.as_mut().expect("effects").defer(EffectsDeferred::Dropped(ids.clone(), at));
    r.answer(&mut rig.cx());
    assert_eq!(effect_count(&rig.session), 1);
    assert!(rig.session.undo_name().is_some_and(|n| n.contains("Blur")));
    rig.session.undo();
    assert_eq!(effect_count(&rig.session), 0);
}

#[test]
fn an_effect_dropped_on_effect_controls_goes_to_the_selection_and_one_dropped_elsewhere_to_nothing() {
    use crate::EffectsDeferred;
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    rig.session.select(std::collections::BTreeSet::from([Id::from_u128(1)]), std::collections::BTreeSet::new());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let ids = vec!["gaussianBlur".to_string()];
    let panel = r.dock.content_frame(PanelID::Project).expect("project docked");
    let elsewhere = CGPoint::new(panel.min_x() + 5.0, panel.min_y() + 5.0);
    r.effects.as_mut().expect("effects").defer(EffectsDeferred::Dropped(ids.clone(), elsewhere));
    r.answer(&mut rig.cx());
    assert_eq!(effect_count(&rig.session), 0);
    let ec = r.dock.content_frame(PanelID::EffectControls).expect("effect controls docked");
    let on_ec = CGPoint::new(ec.min_x() + 5.0, ec.min_y() + 5.0);
    r.effects.as_mut().expect("effects").defer(EffectsDeferred::Dropped(ids, on_ec));
    r.answer(&mut rig.cx());
    assert_eq!(effect_count(&rig.session), 1);
}

#[test]
fn a_double_click_on_a_transition_adds_it_at_the_selected_edit() {
    use crate::EffectsDeferred;
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let id = sq_editor_session::EffectDragPayload::transition_id(sq_core_model::TransitionKind::CrossDissolve);
    r.effects.as_mut().expect("effects").defer(EffectsDeferred::Apply(id));
    r.answer(&mut rig.cx());
    // Two clips with a gap: the session answers one way or the other, and never panics; a status line goes out then.
    let undo = rig.session.undo_name();
    let status = rig.events.iter().any(|e| matches!(e, AppEvent::Status(_)));
    assert!(undo.is_some() ^ status, "either a transition was applied or the user was told why not");
}

/// A laid out root over `edit_session()` with `selected` clips (ids) selected.
fn timeline_rig(selected: &[u128]) -> (AppRoot, crate::test_rig::Rig) {
    let mut rig = crate::test_rig::Rig::new(edit_session());
    rig.session.select(selected.iter().map(|n| Id::from_u128(*n)).collect(), Default::default());
    let mut r = root();
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    (r, rig)
}

/// Queues `c` as the timeline's header or menu would and lets the root answer; the last status line.
fn timeline_command(
    r: &mut AppRoot,
    rig: &mut crate::test_rig::Rig,
    c: sq_uikit::editor_command::EditorCommand,
) -> String {
    rig.events.clear();
    r.timeline.inner().host.run(c);
    r.answer(&mut rig.cx());
    rig.events
        .iter()
        .rev()
        .find_map(|e| if let AppEvent::Status(s) = e { Some(s.clone()) } else { None })
        .unwrap_or_default()
}

fn tracks(rig: &crate::test_rig::Rig) -> usize {
    rig.session.active_timeline().map_or(0, |t| t.tracks.len())
}

#[test]
fn snapping_fast_cut_and_tools_reach_the_panel() {
    use sq_uikit::editor_command::{EditorCommand as C, EditorTool};
    let (mut r, mut rig) = timeline_rig(&[]);
    assert_eq!(timeline_command(&mut r, &mut rig, C::ToggleSnapping), "Snapping off");
    assert!(!r.timeline.inner().panel.tool_state().snapping);
    assert_eq!(rig.session.active_timeline().and_then(|t| t.snapping_off_store), Some(true));
    assert!(!r.timeline_link.as_ref().is_some_and(|l| l.borrow().checks_has(&C::ToggleSnapping)));
    timeline_command(&mut r, &mut rig, C::ToggleSnapping);
    assert!(r.timeline.inner().panel.tool_state().snapping);

    let line = timeline_command(&mut r, &mut rig, C::ToggleMagnetic);
    assert!(line.starts_with("Fast Cut"), "{line}");
    assert_eq!(rig.session.active_timeline().map(|t| t.edit_mode()), Some(sq_core_model::TimelineEditMode::Magnetic));
    assert!(timeline_command(&mut r, &mut rig, C::ToggleMagnetic).starts_with("Normal"));

    let mut seen = Vec::new();
    for tool in [EditorTool::TrackForward, EditorTool::Ripple, EditorTool::Rolling, EditorTool::Slip, EditorTool::Slide]
    {
        timeline_command(&mut r, &mut rig, C::Tool(tool));
        seen.push(format!("{:?}", r.timeline.inner().panel.tool_state().tool));
    }
    seen.dedup();
    assert_eq!(seen.len(), 5, "every tool switch reached the panel: {seen:?}");
}

#[test]
fn zoom_and_track_heights_change_the_view() {
    use sq_draw_timeline::panel::TimelinePanel;
    use sq_uikit::editor_command::EditorCommand as C;
    let (mut r, mut rig) = timeline_rig(&[]);
    let pps = |r: &mut AppRoot| {
        r.timeline.inner().panel.settle_zoom_animation();
        r.timeline.inner().panel.geometry.points_per_second
    };
    let start = pps(&mut r);
    timeline_command(&mut r, &mut rig, C::ZoomIn);
    let zoomed = pps(&mut r);
    assert!(zoomed > start);
    timeline_command(&mut r, &mut rig, C::ZoomOut);
    assert!(pps(&mut r) < zoomed);
    timeline_command(&mut r, &mut rig, C::ZoomFit);
    assert!(pps(&mut r) > 0.0);

    timeline_command(&mut r, &mut rig, C::TrackHeightLarge);
    assert_eq!(r.settings.data(TimelinePanel::HEIGHT_MODE_DEFAULTS_KEY), Some(b"large".to_vec()));
    assert_eq!(timeline_command(&mut r, &mut rig, C::AllTracksTaller), "");
}

/// The key a German `#` press becomes (`resolve_key` in the app: the key position's `\\`), pressed with the timeline
/// focused: the view fits the whole sequence, and a second press returns to the zoom before.
#[test]
fn the_backslash_key_fits_the_sequence_through_the_root() {
    let (mut r, mut rig) = timeline_rig(&[]);
    let key = |r: &mut AppRoot, rig: &mut crate::test_rig::Rig, c: char| {
        r.handle(
            &InputEvent::KeyDown { key: sq_draw::InputKey::Character(c), modifiers: InputModifiers::NONE },
            &mut rig.cx(),
        )
    };
    let pps = |r: &mut AppRoot| {
        r.timeline.inner().panel.settle_zoom_animation();
        r.timeline.inner().panel.geometry.points_per_second
    };
    // A press on the timeline gives it the keyboard focus, as it does for the user.
    r.handle(&InputEvent::MouseDown { x: 500.0, y: 700.0, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: 500.0, y: 700.0 }, &mut rig.cx());
    assert_eq!(r.dock.focused(), Some(PanelID::Timeline));
    let start = pps(&mut r);
    for _ in 0..4 {
        key(&mut r, &mut rig, '=');
    }
    let zoomed = pps(&mut r);
    assert!(key(&mut r, &mut rig, '\\'));
    let fit = pps(&mut r);
    assert!(fit < zoomed - 1e-6, "the key zoomed out to fit the sequence: {start} {zoomed} {fit}");
    key(&mut r, &mut rig, '\\');
    assert!((pps(&mut r) - zoomed).abs() < 1e-6, "a second press returns");
}

#[test]
fn track_commands_and_markers_run_on_the_session() {
    use sq_uikit::editor_command::EditorCommand as C;
    let (mut r, mut rig) = timeline_rig(&[1]);
    let n = tracks(&rig);
    timeline_command(&mut r, &mut rig, C::AddVideoTrack);
    timeline_command(&mut r, &mut rig, C::AddAudioTrack);
    assert_eq!(tracks(&rig), n + 2);

    timeline_command(&mut r, &mut rig, C::AddMarker);
    assert_eq!(rig.session.active_timeline().map_or(0, |t| t.markers.len()), 1);
    rig.session.seek(Time::seconds(0));
    timeline_command(&mut r, &mut rig, C::NextMarker);
    assert_eq!(rig.session.playhead(), Time::seconds(1));
}

#[test]
fn lock_and_group_run_on_the_session() {
    use sq_uikit::editor_command::EditorCommand as C;
    let (mut r, mut rig) = timeline_rig(&[1, 2]);
    timeline_command(&mut r, &mut rig, C::ToggleLockOfTargets);
    assert!(rig.session.active_timeline().is_some_and(|t| t.tracks[0].is_locked));
    timeline_command(&mut r, &mut rig, C::ToggleLockOfTargets);
    let timelines = rig.session.project().timelines.len();
    timeline_command(&mut r, &mut rig, C::Group);
    assert_eq!(rig.session.project().timelines.len(), timelines + 1, "Group made a group sequence");
}

#[test]
fn a_right_click_on_a_clip_opens_the_context_menu_and_a_row_runs() {
    let (mut r, mut rig) = timeline_rig(&[]);
    let track = rig.session.active_timeline().map(|t| t.tracks[0].id).expect("track");
    let y = r.timeline.inner().panel.pixel_y_body_of(track).expect("row");
    let x = r.timeline.inner().panel.pixel_x(Time::seconds(1));
    let press = InputEvent::MouseDown { x, y: y + 4.0, modifiers: InputModifiers::SECONDARY };
    assert!(r.handle(&press, &mut rig.cx()));
    assert!(r.menu.is_open(), "the clip menu is open");
    let rows = r.menu.root_items().len();
    assert!(rows > 3, "{rows} rows");
    assert_eq!(rig.session.selection().len(), 1, "the press selected the clip under it");
}

#[test]
fn edit_in_graphics_brings_the_graphics_panel_forward() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    r.inspector.defer(SectionAction::EditGraphics);
    r.answer(&mut rig.cx());
    assert_eq!(r.dock.focused(), Some(PanelID::Graphics));
}

#[test]
fn the_graphics_panel_in_the_dock_shows_the_selected_graphic_after_edit_graphics() {
    let mut r = root().with_graphics(GraphicsHost::new());
    let mut rig = crate::test_rig::Rig::new(session());
    let g = r.graphics.as_mut().expect("graphics host");
    g.panel().with_session(&mut rig.session, |p| {
        assert!(p.host.editor.new_graphics_clip(&mut p.host.session).is_some());
    });
    r.inspector.defer(SectionAction::EditGraphics);
    r.answer(&mut rig.cx());
    assert_eq!(r.dock.focused(), Some(PanelID::Graphics));
    r.layout(CGRect { x: 0.0, y: 0.0, width: 1280.0, height: 800.0 }, &mut rig.cx());
    assert!(r.dock.shows(PanelID::Graphics));
    let shown = r.graphics.as_mut().and_then(|g| g.panel().structure_key().map(str::to_string));
    assert!(shown.is_some_and(|k| !k.is_empty()));
}

#[test]
fn editor_requests_the_root_owns_open_a_dialog() {
    let (mut r, mut rig) = timeline_rig(&[]);
    let marker = rig.session.mark_at_playhead().expect("a marker").id;
    for request in [TimelineEditorRequest::SequenceVolume, TimelineEditorRequest::Marker(marker)] {
        r.dialog = None;
        rig.events.clear();
        r.timeline.inner().host.request(&request);
        r.answer(&mut rig.cx());
        assert!(r.has_dialog(), "{request:?}");
        assert!(rig.events.iter().all(|e| !matches!(e, AppEvent::Status(_))), "{request:?}");
    }
}

#[test]
fn a_transition_duration_request_asks_with_a_prompt_dialog() {
    let (mut r, mut rig) = timeline_rig(&[]);
    r.timeline.inner().host.ask(
        sq_draw_timeline::host::TimelinePrompt::new("Set Transition Duration", ""),
        "",
        Box::new(|_| {}),
    );
    r.answer(&mut rig.cx());
    assert!(r.has_dialog());
}

#[test]
fn reveal_in_project_needs_the_media() {
    let (mut r, mut rig) = timeline_rig(&[]);
    rig.events.clear();
    let request = TimelineEditorRequest::RevealInProject { media: Id::from_u128(404) };
    r.timeline.inner().host.request(&request);
    r.answer(&mut rig.cx());
    assert!(rig.events.iter().any(|e| matches!(e, AppEvent::Status(s) if *s == request.unavailable())));
}

fn source_host() -> crate::SourceMonitorHost {
    crate::SourceMonitorHost::new(
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
        Box::new(SequentialIds::default()),
    )
}

fn click(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, x: f32, y: f32) {
    for e in [InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() }, InputEvent::MouseUp { x, y }] {
        r.handle(&e, &mut rig.cx());
    }
}

#[test]
fn the_monitor_header_switches_between_program_and_source() {
    let mut r = root().with_source(source_host());
    let mut rig = crate::test_rig::Rig::new(session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    assert_eq!(r.monitor.panel.tabs, ["Program", "Source"]);
    assert!(!r.dock.shows(PanelID::SourceMonitor));
    // The tab rectangles exist once the header is drawn.
    let mut canvas = Canvas::with_size(1000.0, 800.0, None, 1.0);
    r.draw(&mut canvas, &DrawTheme::default(), &mut rig.cx());
    let card = r.dock.content_frame(PanelID::ProgramMonitor).expect("program docked");
    // Click along the header row until the Source tab answers.
    let mut x = card.min_x();
    while !r.dock.shows(PanelID::SourceMonitor) && x < card.max_x() {
        click(&mut r, &mut rig, x as f32 + 1.0, card.min_y() as f32 + 12.0);
        x += 6.0;
    }
    assert!(r.dock.shows(PanelID::SourceMonitor), "the Source tab is reachable");
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    assert_eq!(r.monitor.panel.selected_tab, 1);
}

#[test]
fn a_divider_asks_for_the_resize_cursor() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let mut found = None;
    let mut y = 0.0;
    while found.is_none() && y < 800.0 {
        let mut x = 0.0;
        while found.is_none() && x < 1000.0 {
            if let Some(d) = r.dock.divider_at(CGPoint::new(x, y)) {
                found = Some((x, y, d.axis));
            }
            x += 2.0;
        }
        y += 2.0;
    }
    let (x, y, axis) = found.expect("the default layout has dividers");
    rig.ui.hover.begin_event(&InputEvent::MouseMoved { x: x as f32, y: y as f32 });
    r.handle(&InputEvent::MouseMoved { x: x as f32, y: y as f32 }, &mut rig.cx());
    let want = if axis == SplitAxis::Horizontal { DrawCursor::ResizeLeftRight } else { DrawCursor::ResizeUpDown };
    assert_eq!(rig.ui.hover.cursor, Some(want));
    // Away from every divider the root asks for nothing.
    let away = CGPoint::new(500.0, 400.0);
    assert!(r.dock.divider_at(away).is_none());
    rig.ui.hover.begin_event(&InputEvent::MouseMoved { x: 500.0, y: 400.0 });
    r.handle(&InputEvent::MouseMoved { x: 500.0, y: 400.0 }, &mut rig.cx());
    assert_eq!(rig.ui.hover.cursor, None);
}

#[test]
fn a_new_theme_reaches_the_timeline_host() {
    let mut r = root();
    r.theme_changed(&DrawTheme { scale: 2.0, ..DrawTheme::default() });
    assert_eq!(r.timeline.inner().panel.theme.scale, 2.0);
}

#[test]
fn text_and_meter_panels_replace_their_placeholders() {
    let mut r =
        root().with_text(crate::TextHost::new()).with_meter(MeterPanel::new(Box::new(MemoryDefaults::default())));
    let mut rig = crate::test_rig::Rig::new(session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let meter = r.dock.groups().iter().find(|g| g.selected == PanelID::AudioMeter).expect("meter docked");
    assert_eq!(meter.strip.height, 0.0, "no clipped tab title above the meters");
    assert_eq!(r.dock.content_frame(PanelID::AudioMeter), Some(meter.frame));
    let text = r.dock.shows(PanelID::Text);
    let mut c = Canvas::with_size(1400.0, 900.0, None, 1.0);
    r.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert!(text || r.text.is_some());
}

#[test]
fn the_chrome_frames_the_dock_between_title_row_and_status_bar() {
    let mut r = root();
    laid_out(&mut r);
    let (title, status) = (r.chrome.title_frame(), r.chrome.status_frame());
    assert_eq!((title.height, status.height), (40.0, 24.0));
    assert!(r.dock.frame.min_y() >= title.max_y() && r.dock.frame.max_y() <= status.min_y());
}

#[test]
fn status_lines_show_in_the_bar_and_the_shot_draws_both_rows() {
    use sq_draw::{Color, SoftwareRenderer, Sources};
    let mut r = root();
    laid_out(&mut r);
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    let (_, list) = h.turn();
    let list = list.expect("a frame");
    let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
    let image = SoftwareRenderer::render(&list, 1000, 800, clear, &Sources::default());
    let px = |x: usize, y: usize| image.pixels.get((y * 1000 + x) * 4..(y * 1000 + x) * 4 + 3).map(<[u8]>::to_vec);
    // Title row at y 0..40 (the menu titles share it), Export button at its right end, status bar at the bottom.
    assert_ne!(px(950, 20), px(500, 20), "the accent Export button sits in the title row");
    let seam = DrawTheme::default().panel_ground();
    let seam_px = [seam.r, seam.g, seam.b].map(|v| (v * 255.0).round() as u8).to_vec();
    assert_eq!(px(500, 790), Some(seam_px), "the status bar uses the seam ground (r8:369)");
    assert_ne!(px(500, 790), px(500, 400), "the status bar differs from the dock");
}

#[test]
fn a_click_on_export_runs_the_export_command() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let at = |x, y| (x, y);
    let (x, y) = at(955.0, 20.0);
    assert!(r.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx()));
    assert!(r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx()));
}

#[test]
fn marker_list_replaces_its_placeholder() {
    let mut r = root().with_lists(crate::MarkerListHost::new());
    let mut rig = crate::test_rig::Rig::new(session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let mut c = Canvas::with_size(1400.0, 900.0, None, 1.0);
    r.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert!(r.marker_list.is_some());
}

#[test]
fn the_empty_program_monitors_new_sequence_runs_the_new_sequence_command() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    r.monitor.panel.model.emit(sq_draw_monitor::monitor_panel_model::MonitorEvent::NewSequence);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.handle(&InputEvent::MouseMoved { x: 5.0, y: 5.0 }, &mut rig.cx());
    assert!(
        rig.events.iter().any(|e| matches!(e, AppEvent::Flow(ShellFlow::NewSequence))),
        "the New Sequence flow went out"
    );
}

fn root_with_source() -> AppRoot {
    let source = crate::SourceMonitorHost::new(
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
        Box::new(SequentialIds::default()),
    );
    root().with_source(source)
}

#[test]
fn full_screen_fills_the_window_with_one_monitor_and_esc_leaves() {
    let mut r = root_with_source();
    let mut rig = crate::test_rig::Rig::new(session());
    let window = CGRect::new(0.0, 0.0, 1000.0, 800.0);
    r.layout(window, &mut rig.cx());
    r.enter_full_screen(&mut rig.cx(), PanelID::SourceMonitor);
    assert_eq!(r.full_screen, Some(PanelID::SourceMonitor));
    assert_eq!(rig.events, vec![AppEvent::FullScreen(true)]);
    r.layout(window, &mut rig.cx());
    let mut c = Canvas::with_size(1000.0, 800.0, None, 1.0);
    r.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert!(c.list.quads().first().is_some_and(|q| q.rect.w >= 1000.0 && q.rect.h >= 800.0), "black backdrop");
    // Other keys stay in full screen; Esc leaves and tells the window.
    let key = |key| InputEvent::KeyDown { key, modifiers: InputModifiers::NONE };
    assert!(r.handle(&key(sq_draw::InputKey::Right), &mut rig.cx()));
    assert_eq!(r.full_screen, Some(PanelID::SourceMonitor));
    assert!(r.handle(&key(sq_draw::InputKey::Escape), &mut rig.cx()));
    assert_eq!(r.full_screen, None);
    assert_eq!(rig.events.last(), Some(&AppEvent::FullScreen(false)));
}

#[test]
fn full_screen_needs_a_source_monitor_for_the_source_and_works_for_program() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    r.enter_full_screen(&mut rig.cx(), PanelID::SourceMonitor);
    assert_eq!(r.full_screen, None);
    r.enter_full_screen(&mut rig.cx(), PanelID::ProgramMonitor);
    assert_eq!(r.full_screen, Some(PanelID::ProgramMonitor));
    let mut c = Canvas::with_size(1000.0, 800.0, None, 1.0);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert!(!c.list.quads().is_empty());
}

#[test]
fn the_text_styles_are_saved_in_the_support_folder_and_come_back() {
    use sq_inspector_ui::text::style_library::TextStyleEntry;
    let support = scratch("text-styles");
    let mut r = root().with_prefs(&support);
    let mut rig = crate::test_rig::Rig::new(session());
    let mut library = r.text_styles().expect("a store");
    let style = library.entries()[0].style.clone();
    assert!(library.user().is_empty());
    library.add("Lower third", style, &mut SequentialIds::default());
    r.inspector.defer(SectionAction::StylesChanged(Box::new(library)));
    r.answer(&mut rig.cx());
    assert!(support.join("looks.json").exists());
    let again = root().with_prefs(&support).text_styles().expect("a store");
    let names: Vec<String> = again.user().into_iter().map(|e: TextStyleEntry| e.name).collect();
    assert_eq!(names, ["Lower third"]);
}

/// Graphics > Look "+" > Save as New Look reached no file: the Graphics panel dropped the model's change. The panel's
/// request must land in the one Look store, and a new start must list the Look again.
#[test]
fn a_look_saved_in_the_graphics_panel_is_in_the_look_store_after_a_restart() {
    use sq_inspector_ui::graphics::panel_draw::PanelRequest;
    use sq_inspector_ui::text::style_library::TextStyleEntry;
    let support = scratch("graphics-look");
    let mut r = root().with_graphics(GraphicsHost::new()).with_prefs(&support);
    let mut rig = crate::test_rig::Rig::new(session());
    let mut library = r.text_styles().expect("a store");
    let style = library.entries()[0].style.clone();
    library.add("MyLook2", style, &mut SequentialIds::default());
    r.graphics.as_mut().expect("graphics").defer(PanelRequest::StylesChanged(Box::new(library)));
    r.answer(&mut rig.cx());
    let again = root().with_prefs(&support).text_styles().expect("a store");
    let names: Vec<String> = again.user().into_iter().map(|e: TextStyleEntry| e.name).collect();
    assert_eq!(names, ["MyLook2"]);
}

fn transport_rig() -> (AppRoot, crate::test_rig::Rig) {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(edit_session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let mut canvas = Canvas::with_size(1000.0, 800.0, None, 1.0);
    r.draw(&mut canvas, &DrawTheme::default(), &mut rig.cx());
    (r, rig)
}

fn click_transport(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, a: sq_draw::monitor::monitor_modes::MonitorAction) {
    let b = r.monitor.panel.footer().buttons().iter().find(|b| b.0 == a).map(|b| b.1).expect("button");
    click(r, rig, (b.x + b.width / 2.0) as f32, (b.y + b.height / 2.0) as f32);
    r.pump(&mut rig.cx());
}

#[test]
fn the_program_play_button_toggles_playback_like_space() {
    use sq_draw::monitor::monitor_modes::MonitorAction as A;
    let (mut r, mut rig) = transport_rig();
    click_transport(&mut r, &mut rig, A::PlayPause);
    assert!(rig.session.is_playing(), "a click on Play starts playback");
    click_transport(&mut r, &mut rig, A::PlayPause);
    assert!(!rig.session.is_playing(), "a second click pauses");
}

#[test]
fn the_program_step_and_mark_buttons_run_their_commands() {
    use sq_draw::monitor::monitor_modes::MonitorAction as A;
    let (mut r, mut rig) = transport_rig();
    let before = rig.session.playhead();
    click_transport(&mut r, &mut rig, A::StepForward);
    assert_eq!(rig.session.playhead(), before + Time::new(1, 30));
    click_transport(&mut r, &mut rig, A::StepBack);
    assert_eq!(rig.session.playhead(), before);
    click_transport(&mut r, &mut rig, A::MarkIn);
    assert_eq!(rig.session.active_timeline().and_then(|t| t.in_out).map(|r| r.start), Some(before));
}

#[test]
fn picking_a_workspace_switches_the_dock_layout_and_saves_it() {
    let dir = scratch("workspace-pick");
    let mut r = root().with_storage(dir.join("workspaces.json"), dir.join("recents.json"));
    let mut rig = crate::test_rig::Rig::new(session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.pump(&mut rig.cx());
    let items = Chrome::workspace_items(r.shell.shell());
    let other = items
        .iter()
        .find(|i| i.action.is_some() && !i.is_checked && !i.title.contains('…') && !i.title.contains("Reset"))
        .expect("another workspace");
    // The row shows the platform's wording of the stored name ("Laptop" for "MacBook" off the Mac).
    let name = r
        .dock
        .store()
        .library
        .names()
        .into_iter()
        .find(|n| {
            sq_uikit::platform_wording::PlatformWording::workspace_name(n, sq_os::Platform::current()) == other.title
        })
        .expect("the row's workspace");
    assert_ne!(r.dock.store().current().name, name);
    (other.action.clone().expect("action"))();
    r.pump(&mut rig.cx());
    assert_eq!(r.dock.store().current().name, name);
    let saved = sq_editor_session::WorkspaceStore::load(&dir.join("workspaces.json"));
    assert_eq!(saved.current().name, name);
}

/// A session whose project holds one clip, so the Project panel has a row.
fn media_session() -> (EditorSession, Id) {
    let id = Id::from_u128(77);
    let mut reference =
        sq_core_model::MediaRef::new(id, "interview", "/tmp/interview.mp4", sq_core_model::MediaFingerprint::new(1));
    reference.duration = Some(Time::seconds(4));
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![reference], Vec::new());
    (EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-scale"))), id)
}

/// Sends a click at the point `(x, y)` as the window does: in device pixels.
fn click_pt(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, x: f64, y: f64) {
    let (px, py) = ((x * f64::from(rig.scale)) as f32, (y * f64::from(rig.scale)) as f32);
    r.handle(&InputEvent::MouseDown { x: px, y: py, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: px, y: py }, &mut rig.cx());
}

#[test]
fn a_click_on_a_project_row_selects_it_at_every_display_scale() {
    for scale in [1.0_f32, 1.5, 2.0] {
        let (session, id) = media_session();
        let mut rig = crate::test_rig::Rig::new(session).at_scale(scale);
        let mut r = root();
        r.sync(&rig.session);
        r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
        r.sync(&rig.session);
        let f = r.dock.content_frame(PanelID::Project).expect("project docked");
        let mut y = f.min_y();
        while y < f.max_y() && !r.project.view().selection().contains(&sq_core_model::BinItemRef::Media(id)) {
            click_pt(&mut r, &mut rig, f.min_x() + 40.0, y);
            y += 2.0;
        }
        assert!(r.project.view().selection().contains(&sq_core_model::BinItemRef::Media(id)), "scale {scale}");
    }
}

#[test]
/// The window is wide enough that the Project strip (item count and tools) still has room for the Marker List tab.
fn a_click_on_a_dock_tab_focuses_its_panel_at_every_display_scale() {
    for scale in [1.0_f32, 1.5, 2.0] {
        let mut rig = crate::test_rig::Rig::new(session()).at_scale(scale);
        let mut r = root();
        r.layout(CGRect::new(0.0, 0.0, 1600.0, 900.0), &mut rig.cx());
        let f = r.dock.content_frame(PanelID::Project).expect("project docked");
        let strip_y = f.min_y() - 15.0;
        let mut x = f.min_x();
        while x < f.max_x() && r.dock.focused() != Some(PanelID::MarkerList) {
            click_pt(&mut r, &mut rig, x, strip_y);
            x += 3.0;
        }
        assert_eq!(r.dock.focused(), Some(PanelID::MarkerList), "scale {scale}");
    }
}

/// A press on a recent project's row on the start window opens it, at the Retina scale the real window runs at.
#[test]
fn a_click_on_a_recent_project_row_opens_it_at_retina_scale() {
    for scale in [1.0_f32, 2.0] {
        let dir = scratch("start-click");
        let a_path = dir.join("a.sqproj");
        let mut s = session();
        s.save_as(&a_path).expect("save");
        // First run: opening the project stores it in the recent list.
        let h = window(&dir, Scripted { project: Some(a_path.clone()), save_to: None }, session());
        run(&h, sq_draw_shell::ShellAction::Command(sq_uikit::editor_command::EditorCommand::OpenProject));
        // Second run: an untitled launch shows the start window with that recent project.
        let mut deps = AppDeps::headless(Arc::new(FakeClock::new()));
        deps.theme.scale = scale;
        let h = Headless::new(session(), deps, (1000.0 * scale) as i64, (800.0 * scale) as i64);
        let theme = DrawTheme { scale, ..DrawTheme::default() };
        let mut root = crate::standard_root(&dir, Arc::new(FakeClock::new()), theme).expect("root");
        // The Mac window: the system menu bar and the traffic lights over the drawn title row (main.rs `add_root_with`).
        root.shell.shell().menu_bar.use_system_bar();
        root.shell.shell().window_lights = true;
        h.with(|a| {
            a.add_host(Box::new(root));
            a.launch();
        });
        h.turn();
        let spot = h
            .with(|a| {
                use sq_draw_shell::{NoHooks, ShellCx, ShellRoot};
                let (mut ui, p) = (sq_draw::UiCx::new(), a.shell_parts());
                let sc = ShellCx {
                    session: p.session,
                    measure: sq_draw::TextMeasure::new(None, 1.0),
                    ui: &mut ui,
                    hooks: &mut NoHooks,
                };
                p.shell.a11y_start(&sc).into_iter().find(|s| s.is_project)
            })
            .flatten()
            .expect("the recent project is listed");
        let (x, y) = (spot.rect.mid_x() as f32 * scale, spot.rect.mid_y() as f32 * scale);
        h.input(&InputEvent::MouseMoved { x, y });
        h.input(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
        h.input(&InputEvent::MouseUp { x, y });
        for _ in 0..5 {
            h.turn();
        }
        let url = h.with(|a| a.session().file_url().map(std::path::Path::to_path_buf)).flatten();
        assert_eq!(url, Some(a_path), "the click opened the project at scale {scale}");
    }
}

/// A press on a Project panel row through the whole root (every host in front of it sees the press first) selects it.
#[test]
fn a_click_on_a_project_panel_row_through_the_root_selects_it() {
    use sq_core_model::{MediaFingerprint, MediaRef, Project};
    for scale in [1.0_f32, 2.0] {
        let id = Id::from_u128(77);
        let mut m = MediaRef::new(id, "interview", "/tmp/interview.mp4", MediaFingerprint::new(1));
        m.duration = Some(Time::seconds(4));
        let project = Project::new(Id::from_u128(2), "p", vec![m], Vec::new());
        let s =
            EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-pc")));
        let mut deps = AppDeps::headless(Arc::new(FakeClock::new()));
        deps.theme.scale = scale;
        let h = Headless::new(s, deps, (1600.0 * scale) as i64, (1000.0 * scale) as i64);
        h.with(|a| a.add_host(Box::new(root())));
        h.turn();
        h.turn();
        let selected = |h: &Headless| {
            h.with(|a| {
                a.accessibility(true)
                    .nodes()
                    .iter()
                    .any(|(_, n)| n.role() == sq_draw::panel::Role::ListItem && n.is_selected() == Some(true))
            })
            .unwrap_or(false)
        };
        assert!(!selected(&h));
        // Sweep the Project panel (the right bottom corner of a 1600 x 1000 pt window); the press is in device pixels,
        // as winit reports it.
        let mut hit = None;
        'scan: for y in (590..960).step_by(3) {
            for x in (1230..1590).step_by(40) {
                let (px, py) = (x as f32 * scale, y as f32 * scale);
                h.input(&InputEvent::MouseMoved { x: px, y: py });
                h.input(&InputEvent::MouseDown { x: px, y: py, modifiers: InputModifiers::NONE });
                h.input(&InputEvent::MouseUp { x: px, y: py });
                h.turn();
                if selected(&h) {
                    hit = Some((x, y));
                    break 'scan;
                }
            }
        }
        assert!(hit.is_some(), "no press selected the Project row at scale {scale}");
    }
}

#[test]
fn pack_workspaces_become_user_workspaces_and_are_saved() {
    let dir = scratch("pack-workspaces");
    let mut r = root().with_storage(dir.join("workspaces.json"), dir.join("recents.json"));
    let mut w = sq_editor_session::Workspace::built_ins()[0].clone();
    w.name = "From a pack".into();
    let mut builtin = w.clone();
    builtin.name = sq_editor_session::Workspace::built_ins()[0].name.clone();
    assert_eq!(r.import_workspaces(&[w.clone()]), None);
    assert!(r.dock.store().library.names().contains(&"From a pack".to_string()));
    let saved = sq_editor_session::WorkspaceStore::load(&dir.join("workspaces.json"));
    assert!(saved.library.names().contains(&"From a pack".to_string()));
    assert!(r.import_workspaces(&[builtin]).is_some(), "a built-in name is refused with a line");
}

#[test]
fn whoosh_without_a_selected_cut_says_so_and_waits_for_nothing() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    let lines = r.whoosh(&mut rig.cx(), std::path::Path::new("/tmp/whoosh.wav"));
    assert_eq!(lines, vec!["Select a cut first: click an edge, or select clips next to each other.".to_string()]);
    assert!(r.pending_whoosh.is_none());
}

#[test]
fn the_effects_folder_name_dialog_answers_the_panel() {
    use crate::EffectsDeferred;
    use sq_draw_library::effects::effects_draw_panel::{EffectsEvent, NamePurpose};
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let before = r.effects.as_mut().expect("effects").panel_host().panel.folder_store().folders().len();
    r.effects.as_mut().expect("effects").defer(EffectsDeferred::Other(EffectsEvent::AskName {
        title: "New Folder".into(),
        initial: "My Folder".into(),
        purpose: NamePurpose::NewFolder(None),
    }));
    r.answer(&mut rig.cx());
    assert!(r.shell.shell().dialog().is_some(), "the name dialog is up");
    r.shell.shell().dialog_mut().expect("dialog").press(SQDialogResponse::FIRST);
    r.shell_handle(&sq_draw::InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
    r.answer(&mut rig.cx());
    let folders = r.effects.as_mut().expect("effects").panel_host().panel.folder_store().folders().to_vec();
    assert_eq!(folders.len(), before + 1);
    assert_eq!(folders.last().map(|f| f.name.as_str()), Some("My Folder"));
}

#[test]
fn a_canceled_effects_folder_dialog_changes_nothing_and_the_rename_one_renames() {
    use crate::EffectsDeferred;
    use sq_draw_library::effects::effects_draw_panel::{EffectsEvent, NamePurpose};
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let ask = |r: &mut AppRoot, rig: &mut crate::test_rig::Rig, purpose, initial: &str, answer| {
        let title = "Folder".to_string();
        let event = EffectsEvent::AskName { title, initial: initial.into(), purpose };
        r.effects.as_mut().expect("effects").defer(EffectsDeferred::Other(event));
        r.answer(&mut rig.cx());
        r.shell.shell().dialog_mut().expect("the name dialog is up").press(answer);
        r.shell_handle(&sq_draw::InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
        r.answer(&mut rig.cx());
    };
    let names = |r: &mut AppRoot| -> Vec<String> {
        let panel = &r.effects.as_mut().expect("effects").panel_host().panel;
        panel.folder_store().folders().iter().map(|f| f.name.clone()).collect()
    };
    let before = names(&mut r);
    ask(&mut r, &mut rig, NamePurpose::NewFolder(None), "Never", SQDialogResponse::SECOND);
    assert_eq!(names(&mut r), before, "Cancel makes no folder");
    ask(&mut r, &mut rig, NamePurpose::NewFolder(None), "Old", SQDialogResponse::FIRST);
    let id = r.effects.as_mut().expect("effects").panel_host().panel.folder_store().folders().last().map(|f| f.id);
    let id = id.expect("the new folder");
    ask(&mut r, &mut rig, NamePurpose::Rename(id), "New", SQDialogResponse::SECOND);
    assert_eq!(names(&mut r).last().map(String::as_str), Some("Old"), "Cancel keeps the name");
    ask(&mut r, &mut rig, NamePurpose::Rename(id), "New", SQDialogResponse::FIRST);
    assert_eq!(names(&mut r).last().map(String::as_str), Some("New"));
}

#[test]
fn a_curve_saved_from_the_popover_becomes_an_easing_preset_with_a_fallback_name() {
    use sq_core_model::EaseShape;
    use sq_core_time::{EaseHandle, Interpolation};
    let mut r = root();
    laid_out(&mut r);
    let shape =
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.25, dy: 0.5 }, EaseHandle { dx: 0.75, dy: 1.5 });
    r.inspector.ease_saves.push((shape, "  ".to_string()));
    r.inspector.ease_saves.push((shape, " Snappy ".to_string()));
    r.file_ease_saves();
    let kept: Vec<String> = r
        .library
        .panel_host()
        .panel
        .model
        .presets()
        .iter()
        .filter(|p| p.kind == sq_library::preset_store::PresetKind::Easing)
        .map(|p| p.name.clone())
        .collect();
    assert_eq!(kept, ["Custom Curve", "Snappy"]);
}

#[test]
fn the_whoosh_menu_command_without_a_sound_makes_the_sfx_bin_and_says_what_to_do() {
    use sq_draw_shell::ShellHooks;
    let (mut hooks, link) = crate::timeline_commands::TimelineHooks::new(Default::default());
    assert!(hooks.run_whoosh_at_cuts());
    assert!(link.borrow_mut().take_whoosh());
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    let lines = r.whoosh_from_sfx_bin(&mut rig.cx());
    assert_eq!(lines.len(), 1);
    assert!(lines[0].contains("SFX"), "{lines:?}");
}

/// Swift `SharedUIController`: the shell starts on the saved key set, the Sequence Studio one by default: with the
/// Timeline focused E ripple-trims the next edit and W extends the selected edit (Premiere: W and E).
#[test]
fn the_standard_root_starts_on_the_sequence_studio_key_set() {
    use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
    let dir = scratch("keyset");
    let mut root = crate::standard_root(&dir, Arc::new(FakeClock::new()), DrawTheme::default()).expect("root");
    let map = root.shell.shell().map.clone();
    let key = |c| KeyBinding::new(Key::Char(c), KeyModifiers::EMPTY);
    let tl = Some(PanelID::Timeline);
    assert_eq!(map.command_for(&key('e'), tl), Some(sq_uikit::editor_command::EditorCommand::RippleTrimNext));
    assert_eq!(map.command_for(&key('w'), tl), Some(sq_uikit::editor_command::EditorCommand::ExtendEdit));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A key map edited in Keyboard Shortcuts is handed on at the next sync (Swift `onKeymapChanged`), not left pending.
#[test]
fn an_edited_key_map_is_handed_to_the_panels_at_the_next_sync() {
    let rig = crate::test_rig::Rig::new(session());
    let mut r = root();
    r.shell.shell().apply_keymap(sq_uikit::command_map::CommandMap::premiere_default());
    r.sync(&rig.session);
    assert!(r.shell.shell().take_keymap_change().is_none());
}

fn key_up(h: &Headless, key: sq_draw::InputKey) {
    h.with(|a| a.key_up(key));
    h.turn();
}

fn playhead(h: &Headless) -> Time {
    h.with(|a| a.session().playhead()).unwrap_or(Time::ZERO)
}

#[test]
fn j_shuttles_backward_from_stopped_and_after_k_once_key_ups_arrive() {
    use sq_draw::InputKey::Character as Ch;
    let h = editing();
    let rate = |h: &Headless| h.with(|a| a.session().engine().rate()).unwrap();
    // J from a stopped playhead.
    assert!(press(&h, Ch('j'), InputModifiers::NONE));
    key_up(&h, Ch('j'));
    assert!(rate(&h).is_reverse() && h.with(|a| a.session().is_playing()).unwrap(), "J plays backward");
    // K stops, its key-up arrives, J reverses again.
    press(&h, Ch('k'), InputModifiers::NONE);
    key_up(&h, Ch('k'));
    assert!(!h.with(|a| a.session().is_playing()).unwrap());
    press(&h, Ch('j'), InputModifiers::NONE);
    key_up(&h, Ch('j'));
    assert!(rate(&h).is_reverse(), "J after K plays backward");
    // J again doubles the speed (a held-down state left by a missing key-up would swallow it).
    press(&h, Ch('j'), InputModifiers::NONE);
    key_up(&h, Ch('j'));
    assert_eq!(rate(&h), sq_core_edit::playback::PlaybackRate::whole(-2));
}

/// Windows check: L, L, L raised nothing after the first press. Through the window's key path, key-up between or lost.
#[test]
fn repeated_l_shuttles_1x_2x_4x_also_when_a_key_up_is_lost() {
    use sq_core_edit::playback::PlaybackRate;
    use sq_draw::InputKey::Character as Ch;
    for lose_key_ups in [false, true] {
        let h = editing();
        let rate = |h: &Headless| h.with(|a| a.session().engine().rate()).unwrap();
        for want in [1, 2, 4] {
            assert!(press(&h, Ch('l'), InputModifiers::NONE));
            if !lose_key_ups {
                key_up(&h, Ch('l'));
            }
            assert_eq!(rate(&h), PlaybackRate::whole(want), "L number {want} (lost key-ups: {lose_key_ups})");
        }
    }
}

/// J, J, J mirrors L (-1x, -2x, -4x), and Shift+L / Shift+J nudge by a quarter as Swift's `nudged` does: 1.25x from a
/// stop, one quarter more after L, one quarter less against the direction (3/4x from 1x).
#[test]
fn repeated_j_climbs_backward_and_shift_l_j_nudge_by_a_quarter_like_swift() {
    use sq_core_edit::playback::PlaybackRate as R;
    use sq_draw::InputKey::Character as Ch;
    let rate = |h: &Headless| h.with(|a| a.session().engine().rate()).unwrap();
    let h = editing();
    for want in [-1, -2, -4] {
        assert!(press(&h, Ch('j'), InputModifiers::NONE));
        key_up(&h, Ch('j'));
        assert_eq!(rate(&h), R::whole(want), "J number {}", -want);
    }
    for (key, shift_key, want) in
        [('k', 'l', R::new(5, 4)), ('k', 'j', R::new(-5, 4)), ('l', 'l', R::new(5, 4)), ('l', 'j', R::new(3, 4))]
    {
        let h = editing();
        assert!(press(&h, Ch(key), InputModifiers::NONE));
        key_up(&h, Ch(key));
        assert!(press(&h, Ch(shift_key), InputModifiers::SHIFT));
        assert_eq!(rate(&h), want, "Shift+{shift_key} after {key}");
    }
}

/// Every key press is followed by its key-up, as the window delivers them: play, stop at the end (the session's own
/// stop), then J, K and L must all act again, also after Home.
#[test]
fn shuttle_keys_act_again_after_playback_stopped_at_the_end() {
    use sq_draw::InputKey::Character as Ch;
    let h = editing();
    let tap = |h: &Headless, c: char| {
        press(h, Ch(c), InputModifiers::NONE);
        key_up(h, Ch(c));
    };
    let rate = |h: &Headless| h.with(|a| a.session().engine().rate()).unwrap();
    tap(&h, 'l');
    assert!(rate(&h).is_forward());
    h.with(|a| a.session_mut().stop_playback()); // what reaching the sequence end does
    for c in ['l', 'j', 'l'] {
        tap(&h, c);
        assert!(h.with(|a| a.session().is_playing()).unwrap(), "{c} after the end plays");
        h.with(|a| a.session_mut().stop_playback());
    }
    press(&h, sq_draw::InputKey::Home, InputModifiers::NONE);
    tap(&h, 'l');
    assert!(rate(&h).is_forward(), "L after Home plays");
    tap(&h, 'k');
    assert!(!h.with(|a| a.session().is_playing()).unwrap(), "K stops");
}

#[test]
fn losing_the_window_releases_held_shuttle_keys() {
    use sq_draw::InputKey::Character as Ch;
    let h = editing();
    press(&h, Ch('k'), InputModifiers::NONE); // K down, its key-up goes to another window
    h.with(|a| a.focus_lost());
    press(&h, Ch('j'), InputModifiers::NONE);
    assert!(h.with(|a| a.session().engine().rate().is_reverse()).unwrap(), "no stuck K: J shuttles");
}

#[test]
fn next_and_previous_marker_keys_pair_up_on_the_windows_chord() {
    use sq_draw::InputKey::Character as Ch;
    let h = editing();
    for s in [1, 2] {
        h.with(|a| a.session_mut().seek(Time::seconds(s)));
        press(&h, Ch('m'), InputModifiers::NONE);
    }
    h.with(|a| a.session_mut().seek(Time::seconds(3)));
    let prev = InputModifiers::COMMAND | InputModifiers::SHIFT; // Ctrl+Shift on Windows
    assert!(press(&h, Ch('m'), prev));
    assert_eq!(playhead(&h), Time::seconds(2));
    assert!(press(&h, Ch('m'), prev));
    assert_eq!(playhead(&h), Time::seconds(1));
    assert!(press(&h, Ch('m'), InputModifiers::SHIFT));
    assert_eq!(playhead(&h), Time::seconds(2));
}

#[test]
fn ctrl_shift_m_with_two_markers_and_the_playhead_on_the_second_goes_to_the_first() {
    use sq_draw::InputKey::Character as Ch;
    let h = editing();
    for s in [1, 2] {
        h.with(|a| a.session_mut().seek(Time::seconds(s)));
        press(&h, Ch('m'), InputModifiers::NONE);
        key_up(&h, Ch('m'));
    }
    assert_eq!(h.with(|a| a.session().active_timeline().map_or(0, |t| t.markers.len())), Some(2));
    assert_eq!(playhead(&h), Time::seconds(2));
    assert!(press(&h, Ch('m'), InputModifiers::COMMAND | InputModifiers::SHIFT));
    assert_eq!(playhead(&h), Time::seconds(1));
}

/// Quick Apply > Save Effect Stack as Preset: the hook queues it, the root opens the clip preset dialog (Swift
/// `timelineHost.open?(.saveClipPreset)`); without a selected clip the editor says what to do instead.
#[test]
fn save_effect_stack_as_preset_opens_the_clip_preset_dialog() {
    use sq_draw_shell::ShellHooks;
    let (mut r, mut rig) = timeline_rig(&[1]);
    let mut clip = rig.session.single_selected_clip().expect("clip").clone();
    clip.animation.opacity.value = 0.5;
    rig.session.replace_clip(&clip, "Opacity", false);
    let mut hooks = crate::timeline_commands::TimelineHooks(r.timeline_link.clone().expect("link"));
    assert!(hooks.save_stack_as_preset());
    r.answer(&mut rig.cx());
    assert!(r.has_dialog(), "the name dialog of the preset");
}

/// Captions > Style > Save as New Style...: the root's name dialog hands the typed name back to the Captions host, which
/// writes the look (the answer used to sit in the host's queue until a menu closed, so nothing was ever saved).
#[test]
fn the_name_typed_for_save_as_new_style_is_saved_by_the_captions_host() {
    use sq_core_model::CaptionItem;
    use sq_core_time::{IdSource, TimeRange};
    use sq_draw::InputKey;
    use sq_inspector_ui::captions::style_tab_draw::Control;
    use sq_inspector_ui::text::panel_draw::{Tab, TextPanelDraw};
    let support = crate::test_rig::test_dir("sq-capstyle");
    let url = sq_editor_session::LookStore::default_url(&support.join("fresh-home/Looks"));
    let looks = Arc::new(sq_editor_session::LookStore::new(Some(url.clone()), None, None, None));
    let defaults = crate::persist::FileDefaults::shared(&support);
    let mut r = root().with_text(crate::TextHost::new().with_looks(Arc::clone(&looks), defaults));
    let mut rig = crate::test_rig::Rig::new(session());
    let mut ids = SequentialIds::default();
    let item = CaptionItem {
        id: ids.next_id(),
        lines: vec!["Hello".to_string()],
        range: TimeRange::new(Time::seconds(0), Time::seconds(1)),
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    };
    assert!(rig.session.add_caption_track().is_some() && rig.session.add_captions(vec![item]));
    let frame = CGRect::new(40.0, 20.0, 320.0, 480.0);
    let text = r.text.as_mut().expect("text host");
    text.layout(frame, &mut rig.cx());
    text.panel().select(&rig.session, Tab::Style);
    text.layout(frame, &mut rig.cx());
    let f = text.panel().style.frame(&Control::SaveLook).expect("Save as New Style is shown");
    let (x, y) = ((frame.x + f.mid_x()) as f32, (frame.y + TextPanelDraw::BAR_HEIGHT + f.mid_y()) as f32);
    assert!(text.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx()));
    assert!(text.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx()));
    r.answer(&mut rig.cx());
    assert!(r.has_dialog(), "the name dialog is up");
    let key = |k| InputEvent::KeyDown { key: k, modifiers: InputModifiers::NONE };
    for c in "MyCapLook".chars() {
        r.handle(&key(InputKey::Character(c)), &mut rig.cx());
    }
    r.handle(&key(InputKey::Enter), &mut rig.cx());
    assert!(!r.has_dialog(), "Return answers the dialog");
    let saved = r.text.as_mut().expect("text host").panel().style.look_host.as_ref().map(|h| h.saved());
    let names: Vec<String> = saved.unwrap_or_default().into_iter().map(|(_, name, _)| name).collect();
    assert!(names.iter().any(|n| n.ends_with("MyCapLook")), "the style is listed: {names:?}");
    let file = std::fs::read_to_string(&url).unwrap_or_default();
    assert!(file.contains("MyCapLook"), "the style is written to the fresh Looks folder");
}

#[test]
fn a_click_on_the_loudness_column_resets_the_engine_meter() {
    let mut r = root().with_meter(MeterPanel::new(Box::new(MemoryDefaults::default())));
    laid_out(&mut r);
    let mut rig = crate::test_rig::Rig::new(session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.meter.as_mut().expect("meter").layout_px(sq_draw::Rect::new(0.0, 0.0, 120.0, 300.0), 1.0);
    let at = r.meter.as_ref().expect("meter").loudness_rect();
    let down = InputEvent::MouseDown { x: at.mid_x() as f32, y: at.mid_y() as f32, modifiers: InputModifiers::NONE };
    assert!(r.meter.as_mut().expect("meter").handle_event(&down));
    r.answer(&mut rig.cx());
    let stub = rig.session.engine().as_any().downcast_ref::<sq_editor_session::StubProgramEngine>();
    assert_eq!(stub.map(|s| s.loudness_resets), Some(1));
}

#[test]
fn the_meter_panels_listening_level_dim_and_solo_reach_the_engine() {
    let mut r = root().with_meter(MeterPanel::new(Box::new(MemoryDefaults::default())));
    laid_out(&mut r);
    let mut rig = crate::test_rig::Rig::new(session());
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.answer(&mut rig.cx());
    let stub = |rig: &crate::test_rig::Rig| {
        let s = rig.session.engine().as_any().downcast_ref::<sq_editor_session::StubProgramEngine>().expect("stub");
        (s.monitor_gain, s.channel_monitor)
    };
    assert_eq!(stub(&rig).0.map(|g| g.dim), Some(false), "the stored setting is handed over once");
    r.meter.as_mut().expect("meter").set_monitor(Some(-12.0), Some(true));
    r.meter.as_mut().expect("meter").toggle_solo(0);
    r.answer(&mut rig.cx());
    let (gain, channels) = stub(&rig);
    let gain = gain.expect("gain");
    assert!(gain.dim && (gain.level_db + 12.0).abs() < 1e-9);
    assert!(channels.expect("channels").is_soloed(0));
}

/// The screen point (pixels at scale 1) of the Opacity value field of the Effect Controls panel in `r`.
fn opacity_field_point(r: &mut AppRoot) -> CGPoint {
    use sq_inspector_ui::ec::effect_controls_model::layout::EffectRowKind;
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    let ec = r.dock.content_frame(PanelID::EffectControls).expect("effect controls docked");
    let top = r.inspector.sections().height() + r.inspector.controls().top();
    let scroll = r.inspector.controls().rows_panel.scroll_y;
    let row = r
        .inspector
        .controls()
        .rows_panel
        .rows()
        .iter()
        .find(|row| row.kind == EffectRowKind::Property(EffectProperty::Opacity))
        .cloned()
        .expect("opacity row");
    CGPoint::new(
        ec.min_x() + sq_uikit::controls_grid::ControlsGrid::value_column(0) + 10.0,
        ec.min_y() + top + row.y - scroll + row.height / 2.0,
    )
}

/// Types `text` the way the window delivers it: the key press with the layout's text in `typed_text`.
fn type_text(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, text: &str) {
    for ch in text.chars() {
        rig.ui.typed_text = Some(ch.to_string());
        r.handle(
            &InputEvent::KeyDown { key: sq_draw::InputKey::Character(ch), modifiers: InputModifiers::NONE },
            &mut rig.cx(),
        );
        rig.ui.typed_text = None;
    }
}

/// A click at a point (points); the events arrive in pixels, as the window sends them.
fn click_at(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, at: CGPoint) {
    let (x, y) = (at.x as f32 * rig.scale, at.y as f32 * rig.scale);
    r.handle(&InputEvent::MouseMoved { x, y }, &mut rig.cx());
    r.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
}

fn opacity(r: &mut AppRoot) -> f64 {
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    r.inspector.controls().model.scalar_value(&EffectProperty::Opacity)
}

fn opacity_native(display: f64) -> f64 {
    use sq_inspector_ui::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
    EffectProperty::Opacity.native_from_display(display, EffectComponent::All, None)
}

fn enter(r: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Enter, modifiers: InputModifiers::NONE }, &mut rig.cx());
}

fn editing_fields(r: &mut AppRoot) -> usize {
    r.inspector.controls().rows_panel.fields().values().filter(|f| f.is_editing()).count()
}

/// A panel on a 150 % display with the clip selected; `now` advances between clicks as a person's clicks do.
fn field_rig() -> (AppRoot, crate::test_rig::Rig, CGPoint) {
    let (mut r, mut rig) = timeline_rig(&[1]);
    rig.scale = 1.5;
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let at = opacity_field_point(&mut r);
    (r, rig, at)
}

#[test]
fn typing_right_after_a_click_on_a_value_field_edits_it_through_the_root() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    assert_eq!(r.dock.focused(), Some(PanelID::EffectControls));
    assert_eq!(editing_fields(&mut r), 1, "the click opened the field for typing");
    rig.ui.now += 0.05;
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    let mut canvas = Canvas::with_size(1000.0, 800.0, None, 1.0);
    r.draw(&mut canvas, &DrawTheme::default(), &mut rig.cx());
    type_text(&mut r, &mut rig, "40");
    enter(&mut r, &mut rig);
    assert!((opacity(&mut r) - opacity_native(40.0)).abs() < 1e-9);
}

#[test]
fn a_press_outside_the_panel_commits_and_closes_the_field_so_the_next_click_types() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    type_text(&mut r, &mut rig, "30");
    // A press on the timeline: the typed value commits, the field is no longer open, nothing keeps the focus.
    rig.ui.now += 2.0;
    click_at(&mut r, &mut rig, CGPoint::new(500.0, 700.0));
    assert_eq!(r.dock.focused(), Some(PanelID::Timeline));
    assert_eq!(editing_fields(&mut r), 0, "a field never stays in edit mode behind another panel");
    assert!(!r.inspector.has_keyboard_focus());
    assert!((opacity(&mut r) - opacity_native(30.0)).abs() < 1e-9, "the typed value was kept");
    // An Enter now belongs to the timeline, not to a stale field.
    enter(&mut r, &mut rig);
    assert_eq!(editing_fields(&mut r), 0);
    // The next click on the field opens it, and typing right away works.
    rig.ui.now += 2.0;
    click_at(&mut r, &mut rig, at);
    type_text(&mut r, &mut rig, "60");
    enter(&mut r, &mut rig);
    assert!((opacity(&mut r) - opacity_native(60.0)).abs() < 1e-9);
}

/// What the curve popover edits in the click-through tests: nothing, which is enough to open it.
struct NoEase;

impl sq_uikit::ease_curve_source::EaseCurveSource for NoEase {
    fn ease_reading(&self) -> sq_core_model::EaseReading {
        sq_core_model::EaseReading::Empty
    }
    fn apply_ease_shape(&mut self, _shape: sq_core_model::EaseShape) {}
    fn begin_gesture(&mut self) {}
    fn end_gesture(&mut self) {}
    fn session_easing_curves(&self) -> Vec<sq_core_time::EasingCurve> {
        Vec::new()
    }
    fn observe_ease_inputs(&self) {}
    fn empty_ease_hint(&self) -> String {
        "Select keyframes".to_string()
    }
}

/// The first section header of the Effect Controls panel in `r`: its id and the window point of its chevron.
fn first_section_chevron(r: &mut AppRoot) -> (sq_editor_session::EffectSection, CGPoint) {
    use sq_inspector_ui::ec::effect_controls_model::layout::EffectRowKind;
    let ec = r.dock.content_frame(PanelID::EffectControls).expect("effect controls docked");
    let top = r.inspector.sections().height() + r.inspector.controls().top();
    let scroll = r.inspector.controls().rows_panel.scroll_y;
    let row = r
        .inspector
        .controls()
        .rows_panel
        .rows()
        .iter()
        .find(|row| matches!(row.kind, EffectRowKind::Section(_)))
        .cloned()
        .expect("a section header");
    let EffectRowKind::Section(section) = row.kind else { panic!("a section header") };
    let at = CGPoint::new(
        ec.min_x() + sq_uikit::controls_grid::ControlsGrid::HEADER_TOGGLE_MID_X,
        ec.min_y() + top + row.y - scroll + row.height / 2.0,
    );
    (section, at)
}

/// P9 (2026-11-17): with the Ease popover open, the click on a section's chevron only closed the popover and the user had to
/// click again. A light popover closes on a press elsewhere and the press goes on to what is under the pointer.
#[test]
fn one_click_on_a_section_chevron_closes_the_curve_popover_and_folds_the_section() {
    let (mut r, mut rig, _) = field_rig();
    let (section, chevron) = first_section_chevron(&mut r);
    assert!(!r.inspector.controls().model.collapsed_sections().contains(&section), "the section starts open");
    let window = CGRect::new(0.0, 0.0, 1000.0, 800.0);
    let anchor = CGRect::new(900.0, 700.0, 20.0, 12.0);
    assert!(
        !sq_inspector_ui::ec_draw::easing_popover_draw::EasingPopoverDraw::frame(anchor, window).contains(chevron),
        "the popover does not cover the chevron"
    );
    r.inspector.open_ease(&mut rig.cx(), Box::new(NoEase), anchor);
    assert!(r.inspector.has_popover(), "the curve popover is open");
    click_at(&mut r, &mut rig, chevron);
    assert!(!r.inspector.has_popover(), "the click closed the popover");
    assert!(r.inspector.controls().model.collapsed_sections().contains(&section), "and folded the section: one click");
}

/// The control that opened the popover only closes it: a second click on it toggles and the release does not reopen it.
#[test]
fn a_click_on_the_opener_of_the_curve_popover_only_closes_it() {
    let (mut r, mut rig, _) = field_rig();
    let anchor = CGRect::new(900.0, 700.0, 20.0, 12.0);
    r.inspector.open_ease(&mut rig.cx(), Box::new(NoEase), anchor);
    click_at(&mut r, &mut rig, CGPoint::new(anchor.mid_x(), anchor.mid_y()));
    assert!(!r.inspector.has_popover(), "the click on the opener closed the popover");
}

/// Menus follow the same rule as the light popovers (`MenuController::handle`): a press elsewhere closes the menu and acts, a
/// press on the control that opened it only closes it. Only dialogs and sheets keep every press.
#[test]
fn a_context_menu_closes_on_a_click_elsewhere_and_that_click_acts() {
    use sq_uikit::sqmenu_model::SQMenuItem;
    let (mut r, mut rig, _) = field_rig();
    let (section, chevron) = first_section_chevron(&mut r);
    let anchor = CGRect::new(900.0, 700.0, 20.0, 12.0);
    let items = || vec![SQMenuItem::new("First"), SQMenuItem::new("Second")];
    r.open_menu(&rig.cx(), items(), anchor, None);
    assert!(r.menu.is_open(), "the menu is open");
    click_at(&mut r, &mut rig, CGPoint::new(anchor.mid_x(), anchor.mid_y()));
    assert!(!r.menu.is_open(), "a click on the opener closes the menu");
    assert!(!r.inspector.controls().model.collapsed_sections().contains(&section), "and nothing else happens");
    r.open_menu(&rig.cx(), items(), anchor, None);
    click_at(&mut r, &mut rig, chevron);
    assert!(!r.menu.is_open(), "a click elsewhere closes the menu");
    assert!(r.inspector.controls().model.collapsed_sections().contains(&section), "and folds the section");
}

/// The Controls panel writes whole clips from its own copy, which the host re-syncs only on the next change poll. A
/// change the session got in between (another panel's commit in the same event) must survive the panel's write.
#[test]
fn a_controls_write_keeps_a_change_the_session_got_before_the_panel_synced() {
    let live = |rig: &crate::test_rig::Rig| {
        let id = Id::from_u128(1);
        let clip = rig.session.active_timeline().and_then(|t| t.tracks.iter().find_map(|k| k.clip(id)));
        clip.map(|c| (c.name.clone(), c.animation.opacity.value)).expect("the clip stays on the timeline")
    };
    let (mut r, mut rig, at) = field_rig();
    let (name, was) = live(&rig);
    click_at(&mut r, &mut rig, at);
    type_text(&mut r, &mut rig, "40");
    // The rename reaches the session without the host polling it back into the panel.
    rig.session.rename_selected_clip("Renamed");
    enter(&mut r, &mut rig);
    assert_eq!(live(&rig), ("Renamed".to_string(), opacity_native(40.0)), "the rename and the opacity are both kept");
    // One Undo reverts only the opacity, the next one the rename.
    assert!(rig.session.undo());
    assert_eq!(live(&rig), ("Renamed".to_string(), was));
    assert!(rig.session.undo());
    assert_eq!(live(&rig), (name, was));
}

/// A menu shortcut works while a Controls value field is open (Windows VM, 2026-11-16: Ctrl+M did nothing with the title
/// offset field focused). The typed value commits and the command runs; the text verbs stay the field's.
#[test]
fn a_menu_chord_reaches_the_menu_while_a_value_field_is_open() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    assert_eq!(editing_fields(&mut r), 1, "the click opened the field for typing");
    type_text(&mut r, &mut rig, "40");
    let timelines = rig.session.project().timelines.len();
    // Group (Command+G, a global key of the Clip menu) with the field open.
    let g = InputEvent::KeyDown { key: InputKey::Character('g'), modifiers: InputModifiers::COMMAND };
    assert!(r.handle(&g, &mut rig.cx()), "the key reaches the menu");
    assert_eq!(rig.session.project().timelines.len(), timelines + 1, "Group ran with a field open");
    assert!((opacity(&mut r) - opacity_native(40.0)).abs() < 1e-9, "the typed value was kept");
    assert_eq!(editing_fields(&mut r), 0, "the field closed");
}

#[test]
fn select_all_and_the_cursor_keys_stay_the_open_fields_own() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    type_text(&mut r, &mut rig, "40");
    for key in [InputKey::Character('a'), InputKey::Left] {
        r.handle(&InputEvent::KeyDown { key, modifiers: InputModifiers::COMMAND }, &mut rig.cx());
        assert_eq!(editing_fields(&mut r), 1, "{key:?} keeps editing the field");
    }
}

#[test]
fn a_dialog_closes_an_open_field_before_it_shows() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    assert_eq!(editing_fields(&mut r), 1);
    r.show_dialog(ShellDialog::new("Match Loudness", "Done"));
    r.handle(&InputEvent::MouseMoved { x: 5.0, y: 5.0 }, &mut rig.cx());
    assert_eq!(editing_fields(&mut r), 0, "no field stays in edit mode under a dialog");
    assert!(!r.inspector.has_keyboard_focus());
}

#[test]
fn a_double_click_on_a_value_field_types_and_leaves_the_value() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    type_text(&mut r, &mut rig, "40");
    enter(&mut r, &mut rig);
    assert!((opacity(&mut r) - opacity_native(40.0)).abs() < 1e-9);
    rig.ui.now += 2.0;
    click_at(&mut r, &mut rig, at);
    rig.ui.now += 0.1;
    click_at(&mut r, &mut rig, at);
    assert!((opacity(&mut r) - opacity_native(40.0)).abs() < 1e-9, "the double click does not reset the row");
    assert_eq!(editing_fields(&mut r), 1, "the double click types");
}

/// A negative number typed in a value field: the minus is text, the timeline behind the panel never sees it as zoom out
/// (it took the key before the field did, so "-12" came out as 12).
#[test]
fn a_minus_typed_in_a_value_field_is_text_and_never_zooms_the_timeline() {
    let (mut r, mut rig, at) = field_rig();
    click_at(&mut r, &mut rig, at);
    for (key, text) in [
        (sq_draw::InputKey::Minus, "-"),
        (sq_draw::InputKey::Character('1'), "1"),
        (sq_draw::InputKey::Plus, "+"),
        (sq_draw::InputKey::Character('2'), "2"),
        (sq_draw::InputKey::Character(','), ","),
        (sq_draw::InputKey::Character('5'), "5"),
    ] {
        rig.ui.typed_text = Some(text.to_string());
        r.handle(&InputEvent::KeyDown { key, modifiers: InputModifiers::NONE }, &mut rig.cx());
        rig.ui.typed_text = None;
        assert!(!r.timeline.inner().panel.is_zooming(), "{key:?} did not zoom the timeline");
    }
    let typed = r.inspector.controls().rows_panel.fields().values().find_map(|f| f.editor().map(|e| e.string()));
    assert_eq!(typed.as_deref(), Some("-1+2,5"));
}

/// The `running-<pid>.lock` markers under the autosave folder `dir`.
fn markers(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut found = Vec::new();
    for project in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        for file in std::fs::read_dir(project.path()).into_iter().flatten().flatten() {
            if file.file_name().to_string_lossy().starts_with("running-") {
                found.push(file.path());
            }
        }
    }
    found
}

/// An edited project in a window whose autosave folder is `dir` (so the crash marker lands there).
fn edited_window(dir: &std::path::Path) -> Headless {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(dir.to_path_buf());
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    s.perform("Rename", None, |p| p.name = "Edited".to_string());
    window(dir, Scripted { project: None, save_to: None }, s)
}

fn answer_dialog(h: &Headless, response: SQDialogResponse) {
    h.with(|a| {
        use sq_draw_shell::ShellRoot;
        if let Some(d) = a.shell_parts().shell.dialog_mut() {
            d.press(response);
        }
    });
    // The shell drops the answered dialog on the next event, as the next pointer move in the real window does.
    h.input(&InputEvent::MouseMoved { x: 5.0, y: 5.0 });
    for _ in 0..3 {
        h.turn();
    }
}

/// Whether the Save Changes question is up (the first-run welcome card may be too).
fn has_dialog(h: &Headless) -> bool {
    h.with(|a| {
        use sq_draw_shell::ShellRoot;
        a.shell_parts().shell.dialog().is_some_and(|d| d.asks_to_save)
    })
    .unwrap_or(false)
}

/// The window's close button (Alt+F4 on Windows, the window manager's close on Linux) asks Save Changes first; Cancel keeps
/// the window and the marker, Don't Save ends the loop and removes the crash marker.
#[test]
fn a_close_request_with_an_edited_project_asks_and_only_dont_save_quits() {
    let dir = scratch("close-request");
    let h = edited_window(&dir);
    assert_eq!(markers(&dir).len(), 1, "the session wrote its running marker");

    h.with(|a| a.close_requested());
    for _ in 0..3 {
        h.turn();
    }
    assert!(has_dialog(&h), "the Save Changes question is up");
    assert_eq!(h.with(|a| a.quit_requested()), Some(false), "the window stays while the question is up");

    // A second close request while the question is up does not replace it.
    h.with(|a| a.close_requested());
    for _ in 0..3 {
        h.turn();
    }
    assert!(has_dialog(&h));

    answer_dialog(&h, SQDialogResponse::SECOND); // Cancel
    assert!(!has_dialog(&h));
    assert_eq!(h.with(|a| a.quit_requested()), Some(false), "Cancel keeps running");
    assert_eq!(markers(&dir).len(), 1, "Cancel keeps the marker");

    h.with(|a| a.close_requested());
    for _ in 0..3 {
        h.turn();
    }
    assert!(has_dialog(&h), "asked again after Cancel");
    answer_dialog(&h, SQDialogResponse::THIRD); // Don't Save
    assert_eq!(h.with(|a| a.quit_requested()), Some(true), "Don't Save ends the loop");
    assert!(markers(&dir).is_empty(), "the crash marker is removed: {:?}", markers(&dir));
}

#[test]
fn a_close_request_without_changes_quits_at_once_and_removes_the_marker() {
    let dir = scratch("close-clean");
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(dir.clone());
    deps.ids = Box::new(ids);
    let h = window(&dir, Scripted { project: None, save_to: None }, EditorSession::new(project, deps));
    assert_eq!(markers(&dir).len(), 1);
    h.with(|a| a.close_requested());
    for _ in 0..3 {
        h.turn();
    }
    assert!(!has_dialog(&h));
    assert_eq!(h.with(|a| a.quit_requested()), Some(true));
    assert!(markers(&dir).is_empty());
}

#[test]
fn saved_settings_reach_the_running_app() {
    // Swift `onSettingsChanged` / `applySessionSettings`: these values change behavior at once, without a restart.
    let mut r = root();
    let mut s = session();
    assert!(r.monitor.panel.model.drop_indicator_enabled);
    assert!(!sq_editor_session::AppSettings::standard().use_proxies_for_export);
    let changed = sq_editor_session::AppSettings {
        drop_indicator: false,
        selection_follows_playhead: true,
        use_proxies_for_export: true,
        new_sequence_edit_mode: sq_core_model::TimelineEditMode::Magnetic,
        audio_output_uid: Some("test-device".to_string()),
        ..sq_editor_session::AppSettings::standard()
    };
    r.apply_settings_changed(&changed, &mut s);
    assert!(!r.monitor.panel.model.drop_indicator_enabled, "Dropped Frames dot off");
    assert!(s.selection_follows_playhead() && s.use_proxies_for_export());
    assert_eq!(s.new_sequence_edit_mode(), sq_core_model::TimelineEditMode::Magnetic);
    assert_eq!(sq_audio_out::output::devices::preferred().as_deref(), Some("test-device"));
    // Settings > Media sits outside `AppSettings`: the store is what the app hands to the session.
    let media = sq_core_model::MediaPolicyDefaults {
        outside: sq_core_model::OutsideMediaMode::Copy,
        copy_library_items: false,
        watch_folder: false,
    };
    sq_editor_session::MediaSettings::store(media, &mut *r.shell.shell().defaults);
    r.apply_settings_changed(&changed, &mut s);
    assert_eq!(s.media_policy_defaults(), media, "the Media defaults reach the import and the save");
    r.apply_settings_changed(&sq_editor_session::AppSettings::standard(), &mut s);
    assert!(r.monitor.panel.model.drop_indicator_enabled, "and on again");
    assert!(!s.selection_follows_playhead() && !s.use_proxies_for_export(), "the standard values are off");
    assert_eq!(sq_audio_out::output::devices::preferred(), None, "system default output");
}

#[test]
fn the_edit_api_run_state_reaches_the_shell_without_a_page_change() {
    // Swift `api.onState` -> `shell.editAPI?.stateChanged`: a server that starts after the switch tells Preferences.
    use sq_uikit::appearance_palette::UiDefaults;
    let dir = crate::test_rig::test_dir("sq-app-hosts-api-state");
    std::fs::create_dir_all(&dir).expect("dir");
    let (tx, _rx) = sq_runtime::channel::unbounded();
    let mut r = root().with_prefs(&dir).with_edit_api(tx, &dir);
    let port = std::net::TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).map_or(41778, |a| a.port());
    {
        let defaults = r.persist.as_ref().expect("prefs").defaults();
        let mut d = defaults.borrow_mut();
        d.set_integer(crate::edit_api_host::ENABLED_KEY, 1);
        d.set_integer(crate::edit_api_host::PORT_KEY, i64::from(port));
    }
    let mut rig = crate::test_rig::Rig::new(session());
    let shown = |r: &mut AppRoot| r.shell.shell().preferences.edit_api.as_ref().map(|(_, s)| s.text.clone());
    let started = std::time::Instant::now();
    while !shown(&mut r).is_some_and(|t| t.starts_with("Listening") || t.starts_with("Port in use")) {
        assert!(started.elapsed() < std::time::Duration::from_secs(5), "the state never reached the shell");
        r.answer(&mut rig.cx());
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    r.edit_api.as_mut().expect("api").stop();
    let _ = std::fs::remove_dir_all(&dir);
}

fn media_event(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, e: sq_draw_shell::ShellEvent) {
    r.shell.deferred.push(crate::ShellDeferred::Event(e));
    r.answer(&mut rig.cx());
}

#[test]
fn library_folders_added_and_removed_in_preferences_reach_the_library_and_the_page() {
    // Swift `wirePreferencesLibrary`: the rows follow the Library model; Add Folder and Remove act on it.
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    let folder = crate::test_rig::unique_dir("sq-app-hosts-lib-folder");
    std::fs::create_dir_all(&folder).expect("dir");
    r.answer(&mut rig.cx());
    assert_eq!(r.shell.shell().preferences.library_folders.as_ref().map(Vec::len), Some(0), "the rows exist");
    media_event(&mut r, &mut rig, sq_draw_shell::ShellEvent::AddLibraryFolder(folder.clone()));
    assert_eq!(r.library.panel_host().panel.model.folders().len(), 1, "the Library watches it");
    let rows = r.shell.shell().preferences.library_folders.clone().expect("rows");
    assert_eq!(rows.len(), 1);
    media_event(&mut r, &mut rig, sq_draw_shell::ShellEvent::RemoveLibraryFolder(rows[0].id.clone()));
    assert!(r.library.panel_host().panel.model.folders().is_empty());
    assert_eq!(r.shell.shell().preferences.library_folders.as_ref().map(Vec::len), Some(0));
    let _ = std::fs::remove_dir_all(&folder);
}

#[test]
fn delete_cache_empties_the_cache_folder_but_not_the_proxies() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    let cache = crate::test_rig::unique_dir("sq-app-hosts-delete-cache");
    std::fs::create_dir_all(cache.join("Proxies")).expect("dir");
    std::fs::create_dir_all(cache.join("Previews")).expect("dir");
    std::fs::write(cache.join("Previews").join("a.png"), b"x").expect("file");
    std::fs::write(cache.join("Proxies").join("p.mov"), b"proxy").expect("file");
    let s = sq_editor_session::AppSettings {
        cache_folder: Some(cache.clone()),
        ..sq_editor_session::AppSettings::standard()
    };
    s.save(&mut *r.shell.shell().defaults);
    media_event(&mut r, &mut rig, sq_draw_shell::ShellEvent::ClearCache);
    assert!(!cache.join("Previews").exists(), "the cache folder is emptied");
    assert!(cache.join("Proxies").join("p.mov").exists(), "the proxies stay with the proxy cache");
    let _ = std::fs::remove_dir_all(&cache);
}

#[test]
fn a_changed_cache_folder_copies_the_proxies_over() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    let (from, to) =
        (crate::test_rig::unique_dir("sq-app-hosts-proxy-from"), crate::test_rig::unique_dir("sq-app-hosts-proxy-to"));
    std::fs::create_dir_all(&from).expect("dir");
    std::fs::write(from.join("p.mov"), b"proxy").expect("file");
    media_event(&mut r, &mut rig, sq_draw_shell::ShellEvent::MoveProxies { from: from.clone(), to: to.clone() });
    let started = std::time::Instant::now();
    while !to.join("p.mov").exists() {
        assert!(started.elapsed() < std::time::Duration::from_secs(5), "the proxy was never copied");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(from.join("p.mov").exists(), "copied, never moved");
    let _ = std::fs::remove_dir_all(&from);
    let _ = std::fs::remove_dir_all(&to);
}

/// "Move to Floating Window" on a tab: the app sees a floating window for the panel (the host opens an OS window per
/// entry), the panel leaves the dock layout, and the frame's canvas reaches the window's rectangle (right of the window).
/// The OS window itself (sequence-studio `float_windows.rs`) is not testable without a display.
#[test]
fn move_to_floating_window_gives_the_app_a_floating_window_on_the_canvas() {
    let mut r = root();
    laid_out(&mut r);
    let items = r.dock.tab_menu(PanelID::Effects);
    let float = items.iter().find(|i| i.title == "Move to Floating Window").expect("the tab menu offers it");
    (float.action.as_ref().expect("an action"))();
    r.dock.run_tab_actions();
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    let (_, first) = h.turn();
    assert!(first.is_some());
    h.with(|a| a.set_needs_redraw());
    let (_, list) = h.turn();
    let list = list.expect("a frame");
    let (windows, extent) = h
        .with(|a| {
            let d = a.dock_mut().expect("the root owns the dock");
            (d.floating.windows().to_vec(), d.floating.canvas_extent())
        })
        .expect("app");
    assert_eq!(windows.len(), 1);
    assert_eq!(windows[0].panel, PanelID::Effects);
    assert!(windows[0].rect.min_x() >= 1000.0, "the rectangle lies right of the window");
    assert!(
        f64::from(list.width()) >= extent.width,
        "the canvas holds the rectangle: {} < {}",
        list.width(),
        extent.width
    );
}

/// A tab dragged to the window's outer edge floats (a maximized window reaches the screen edge, so the pointer cannot
/// go beyond it): the root's dock keeps the panel out of the layout.
#[test]
fn dragging_a_tab_to_the_window_edge_floats_it() {
    let mut r = root();
    laid_out(&mut r);
    r.dock.floating.main_screen_frame = Some(CGRect::new(0.0, 0.0, 1000.0, 800.0));
    r.dock.floating.screens = vec![CGRect::new(0.0, 0.0, 1000.0, 800.0)];
    let g = r.dock.groups().iter().find(|g| g.panels.contains(&PanelID::Effects)).expect("group").clone();
    let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::Effects).expect("tab")];
    let ev = |x: f64, y: f64, kind: u8| match kind {
        0 => sq_draw::InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE },
        1 => sq_draw::InputEvent::MouseDragged { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE },
        _ => sq_draw::InputEvent::MouseUp { x: x as f32, y: y as f32 },
    };
    r.dock.handle(&ev(tab.mid_x(), tab.mid_y(), 0), 1.0);
    r.dock.handle(&ev(999.5, 300.0, 1), 1.0);
    r.dock.handle(&ev(999.5, 300.0, 2), 1.0);
    assert!(r.dock.floating.is_floating(PanelID::Effects));
}

/// A tab is never lost: wherever a Captions tab is released near the window edge it ends up as a shown tab, or as a
/// floating panel with a window entry (Windows acceptance: the tab vanished and the Window menu still showed it checked).
#[test]
fn a_tab_released_near_the_window_edge_is_never_lost() {
    let ev = |x: f64, y: f64, kind: u8| match kind {
        0 => sq_draw::InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE },
        1 => sq_draw::InputEvent::MouseDragged { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE },
        _ => sq_draw::InputEvent::MouseUp { x: x as f32, y: y as f32 },
    };
    let mut lost = Vec::new();
    for panel in [PanelID::Text, PanelID::Effects] {
        for xi in -60..=40 {
            for y in [30.0, 120.0, 300.0, 600.0, 790.0, 830.0] {
                let mut r = root();
                laid_out(&mut r);
                r.dock.floating.main_screen_frame = Some(CGRect::new(0.0, 0.0, 1000.0, 800.0));
                r.dock.floating.screens = vec![CGRect::new(0.0, 0.0, 1000.0, 800.0)];
                r.dock.show(panel);
                laid_out(&mut r);
                let Some(g) = r.dock.groups().iter().find(|g| g.panels.contains(&panel)).cloned() else { continue };
                let Some(i) = g.panels.iter().position(|p| *p == panel) else { continue };
                let tab = g.tabs[i];
                let x = 1000.0 + f64::from(xi) * 0.5;
                r.dock.handle(&ev(tab.mid_x(), tab.mid_y(), 0), 1.0);
                r.dock.handle(&ev(x, y, 1), 1.0);
                r.dock.handle(&ev(x, y, 2), 1.0);
                laid_out(&mut r);
                let floats =
                    r.dock.floating.is_floating(panel) && r.dock.floating.windows().iter().any(|w| w.panel == panel);
                let shown = r.dock.groups().iter().any(|g| !g.is_floating && g.panels.contains(&panel));
                if !floats && !shown {
                    lost.push((panel, x, y));
                }
                if floats {
                    // The host could not open the window: the panel goes back where it was, as a shown tab.
                    r.dock.dock_back(panel);
                    laid_out(&mut r);
                    if !r.dock.groups().iter().any(|g| !g.is_floating && g.panels.contains(&panel)) {
                        lost.push((panel, x, -y));
                    }
                }
            }
        }
    }
    assert!(lost.is_empty(), "lost tabs (panel, x, y): {:?}", &lost[..lost.len().min(12)]);
}

#[test]
fn a_change_a_task_made_to_the_shell_asks_for_a_frame_without_an_input_event() {
    // Settings > Media > Add Folder: the folder arrives from the chooser task, not from a click.
    let r = root();
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    for _ in 0..6 {
        h.turn();
    }
    h.with(|a| sq_draw_shell::ShellRoot::shell_parts(a).shell.request_frame());
    let (_, list) = h.turn();
    assert!(list.is_some(), "the turn after the task draws");
}

/// Windows bug: typing "blade" in the Effects search arrived as "Ide": the tool and edit shortcuts took letters before
/// the focused field did. Every typed character reaches the search, in order, through the real root.
#[test]
fn typing_in_the_effects_search_gets_every_letter_in_order_through_the_root() {
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.dock.select(PanelID::Effects);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.sync(&rig.session);
    let fx = r.dock.content_frame(PanelID::Effects).expect("effects docked");
    rig.ui.now += 1.0;
    click_at(&mut r, &mut rig, CGPoint::new(fx.min_x() + 40.0, fx.min_y() + 16.0));
    assert!(r.effects.as_mut().expect("effects").panel_host().panel.is_editing_search(), "the click opens the search");
    type_text(&mut r, &mut rig, "blade");
    assert_eq!(r.effects.as_mut().expect("effects").panel_host().panel.search_text(), "blade");
}

/// Windows bug: with the Shortcuts page up, letters went to the tool shortcuts and the clicks to the panels under it.
#[test]
fn the_shortcuts_page_takes_typing_and_escape_through_the_root() {
    let mut r = root_with_effects();
    let mut rig = crate::test_rig::Rig::new(effects_cx_session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.shell.shell().show_shortcuts_page();
    type_text(&mut r, &mut rig, "blade");
    assert_eq!(r.shell.shell().shortcuts().expect("editor").query(), "blade");
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE }, &mut rig.cx());
    assert!(!r.shell.shell().is_shortcuts_shown(), "Escape closes the page");
}

/// A click inside a panel shows the blue focus frame: the dock that draws it (the shell's) focuses that panel too.
#[test]
fn a_press_in_a_panel_puts_the_focus_frame_on_it() {
    let (mut r, mut rig) = timeline_rig(&[]);
    r.handle(&InputEvent::MouseDown { x: 500.0, y: 700.0, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: 500.0, y: 700.0 }, &mut rig.cx());
    r.answer(&mut rig.cx());
    assert_eq!(r.dock.focused(), Some(PanelID::Timeline));
    assert_eq!(r.shell.shell().dock.focused(), Some(PanelID::Timeline));
    // Settled: a second turn does not bounce the focus between the two docks.
    r.answer(&mut rig.cx());
    assert_eq!(r.shell.shell().dock.focused(), Some(PanelID::Timeline));
}

/// Edit -> Color -> Edit: the Edit panels sit exactly where they did (the Color page's layout never leaks back).
#[test]
fn the_edit_layout_is_exactly_back_after_a_visit_to_the_color_page() {
    let frames = |r: &AppRoot| -> Vec<(PanelID, CGRect)> {
        PanelID::ALL.iter().filter_map(|p| r.dock.content_frame(*p).map(|f| (*p, f))).collect()
    };
    for size in [(1000.0, 800.0), (1280.0, 720.0)] {
        let (mut r, mut rig) = timeline_rig(&[]);
        let area = CGRect::new(0.0, 0.0, size.0, size.1);
        r.layout(area, &mut rig.cx());
        let before = frames(&r);
        assert!(!before.is_empty());
        r.dock.set_page(sq_editor_session::WorkspacePage::Color);
        r.layout(area, &mut rig.cx());
        r.layout(area, &mut rig.cx());
        r.dock.set_page(sq_editor_session::WorkspacePage::Edit);
        r.layout(area, &mut rig.cx());
        r.layout(area, &mut rig.cx());
        assert_eq!(frames(&r), before, "at {size:?}");
    }
}

fn window_frame_of(w: usize, h: usize, rgba: [u8; 4]) -> sq_draw::RgbaImage {
    sq_draw::RgbaImage { width: w, height: h, pixels: rgba.iter().copied().cycle().take(w * h * 4).collect() }
}

fn sampling_root() -> (AppRoot, crate::Eyedropper, crate::test_rig::Rig) {
    let dropper = crate::Eyedropper::default();
    let mut r = root().with_color_eyedropper(dropper.clone());
    let mut rig = crate::test_rig::Rig::new(session());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    (r, dropper, rig)
}

#[test]
fn a_press_outside_the_picture_picks_from_the_window_frame() {
    let (mut r, dropper, mut rig) = sampling_root();
    // Not sampling: the root takes nothing.
    assert!(!r.sample_window(&InputEvent::MouseDown { x: 5.0, y: 5.0, modifiers: InputModifiers::NONE }, 1.0));
    dropper.arm();
    assert!(r.wants_window_frame());
    r.set_window_frame(window_frame_of(1000, 800, [10, 200, 30, 255]));
    assert!(!r.wants_window_frame());
    // The pointer in the title bar corner: the loupe shows and the move is used up.
    assert!(r.handle(&InputEvent::MouseMoved { x: 5.0, y: 5.0 }, &mut rig.cx()));
    assert!(r.window_loupe.as_ref().is_some_and(|(l, _)| l.center() == [10, 200, 30]));
    assert!(r.handle(&InputEvent::MouseDown { x: 5.0, y: 5.0, modifiers: InputModifiers::NONE }, &mut rig.cx()));
    assert_eq!(dropper.take_answer(), Some(Some((10.0 / 255.0, 200.0 / 255.0, 30.0 / 255.0))));
    assert!(r.window_loupe.is_none());
}

#[test]
fn escape_cancels_the_sampling_and_the_display_scale_maps_pixels_to_the_frame() {
    let (mut r, dropper, mut rig) = sampling_root();
    dropper.arm();
    r.set_window_frame(window_frame_of(2000, 1600, [1, 2, 3, 255]));
    // At scale 2 the loupe sits at half the pixel position (points).
    r.sample_window(&InputEvent::MouseMoved { x: 20.0, y: 40.0 }, 2.0);
    assert!(r.window_loupe.as_ref().is_some_and(|(_, p)| (p.x, p.y) == (10.0, 20.0)));
    assert!(r.handle(
        &InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE },
        &mut rig.cx()
    ));
    assert_eq!(dropper.take_pick(), Some(None));
    assert!(r.window_loupe.is_none());
}

#[test]
fn default_quality_and_the_rolls_reach_the_monitors_and_a_hand_pick_is_remembered() {
    use sq_editor_session::{AppSettings, MonitorQuality};
    let dir = crate::test_rig::test_dir("sq-app-hosts-quality");
    let mut r = root().with_prefs(&dir).with_source(source_host());
    let mut s = session();
    let changed = AppSettings {
        preview_quality_auto: false,
        default_quality: MonitorQuality::Half,
        preroll_seconds: 7,
        postroll_seconds: 4,
        ..AppSettings::standard()
    };
    r.apply_settings_changed(&changed, &mut s);
    assert_eq!(r.monitor.panel.model.quality(), MonitorQuality::Half, "Default Quality sets the Program monitor");
    let core = r.source.as_ref().expect("source").core();
    assert_eq!((core.preroll, core.postroll), (Time::seconds(7), Time::seconds(4)), "Preroll and Postroll");
    // A hand pick in the monitor's popup is saved as the new default.
    r.monitor.panel.model.set_quality(MonitorQuality::Quarter);
    r.remember_quality(MonitorQuality::Quarter);
    let stored = AppSettings::load(&*r.persist.as_ref().expect("prefs").defaults().borrow());
    assert!(!stored.preview_quality_auto && stored.default_quality == MonitorQuality::Quarter);
    // Auto in Preferences puts the monitor on Auto.
    r.apply_settings_changed(&AppSettings { preview_quality_auto: true, ..AppSettings::standard() }, &mut s);
    assert_eq!(r.monitor.panel.model.quality(), MonitorQuality::Auto);
}

#[test]
fn a_sequences_own_preview_quality_replaces_the_app_quality_and_is_not_remembered() {
    use sq_core_model::SequencePreviewQuality;
    use sq_editor_session::{AppSettings, MonitorQuality};
    let dir = crate::test_rig::test_dir("sq-app-hosts-seq-quality");
    let mut r = root().with_prefs(&dir).with_source(source_host());
    let mut rig = crate::test_rig::Rig::new(edit_session());
    let app =
        AppSettings { preview_quality_auto: false, default_quality: MonitorQuality::Half, ..AppSettings::standard() };
    app.save(&mut *r.persist.as_ref().expect("prefs").defaults().borrow_mut());
    r.apply_settings_changed(&app, &mut rig.session);
    let mut settings = rig.session.active_timeline().expect("timeline").settings();
    settings.preview_quality = Some(SequencePreviewQuality::Quarter);
    assert!(rig.session.apply_sequence_settings(&settings));
    r.pump_quality(&rig.session);
    assert_eq!(r.monitor.panel.model.quality(), MonitorQuality::Quarter, "the sequence value wins");
    r.remember_quality(MonitorQuality::Quarter);
    let stored = AppSettings::load(&*r.persist.as_ref().expect("prefs").defaults().borrow());
    assert_eq!(stored.default_quality, MonitorQuality::Half, "the app default is untouched");
    // A Preferences change while the override is active does not drop it.
    let changed = AppSettings { default_quality: MonitorQuality::Full, ..app.clone() };
    changed.save(&mut *r.persist.as_ref().expect("prefs").defaults().borrow_mut());
    r.apply_settings_changed(&changed, &mut rig.session);
    assert_eq!(r.monitor.panel.model.quality(), MonitorQuality::Quarter, "the sequence value keeps winning");
    app.save(&mut *r.persist.as_ref().expect("prefs").defaults().borrow_mut());
    settings.preview_quality = None;
    assert!(rig.session.apply_sequence_settings(&settings));
    r.pump_quality(&rig.session);
    assert_eq!(r.monitor.panel.model.quality(), MonitorQuality::Half, "back to the app setting");
}

/// Typing `text` into a Color Simple field (`None` = Sharpen) through the real root (timeline first, then the panels):
/// the stored value and the undo steps made, for every way a typed value ends.
fn root_typed(param: Option<ColorParam>, text: &str, end: &str, scale: f32) -> (f32, usize) {
    use sq_core_color::ClipGradeExt;
    use sq_draw::InputKey;
    use sq_inspector_ui::color::color_sharpen::ClipSharpenExt;
    let (mut r, mut rig) = timeline_rig(&[1]);
    rig.scale = scale;
    r.dock.set_page(sq_editor_session::WorkspacePage::Color);
    let area = CGRect::new(0.0, 0.0, 1600.0, 900.0);
    r.layout(area, &mut rig.cx());
    r.layout(area, &mut rig.cx());
    r.pump(&mut rig.cx());
    let (x, y) = r.color.simple_field_point(param).expect("the row on the Simple page");
    let (x, y) = (x * scale, y * scale);
    let depth = rig.session.undo_depth();
    let no = InputModifiers::default();
    for _ in 0..2 {
        r.sync(&rig.session);
        r.layout(area, &mut rig.cx());
        r.handle(&InputEvent::MouseDown { x, y, modifiers: no }, &mut rig.cx());
        r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
        r.pump(&mut rig.cx());
    }
    // The shot harness selects the clip again once its clicks are done.
    let again = rig.session.selection().clone();
    rig.session.select(again, Default::default());
    // The app draws a frame (sync, then layout) before every event; the shot harness and a real window both do.
    let key = |r: &mut AppRoot, rig: &mut crate::test_rig::Rig, key: InputKey| {
        r.sync(&rig.session);
        r.layout(area, &mut rig.cx());
        r.handle(&InputEvent::KeyDown { key, modifiers: no }, &mut rig.cx());
        r.pump(&mut rig.cx());
    };
    for ch in text.chars() {
        key(&mut r, &mut rig, InputKey::Character(ch));
    }
    match end {
        "enter" => key(&mut r, &mut rig, InputKey::Enter),
        "tab" => key(&mut r, &mut rig, InputKey::Character('\t')),
        "escape" => key(&mut r, &mut rig, InputKey::Escape),
        // A press on the picture, outside every Color panel.
        _ => {
            r.handle(&InputEvent::MouseDown { x: 5.0, y: 5.0, modifiers: no }, &mut rig.cx());
        }
    }
    r.pump(&mut rig.cx());
    // The save that follows the typing (Cmd+S) is the app's: a focused Color field must not swallow it.
    let save = InputEvent::KeyDown { key: InputKey::Character('s'), modifiers: InputModifiers::COMMAND };
    assert!(!r.color.handle(&save, &mut rig.cx()), "{param:?} typed {text}, {end}: Cmd+S taken by the Color page");
    let clip = rig.session.single_selected_clip().expect("clip").clone();
    let value = match param {
        Some(p) => p.read(&clip.color_at_local(Time::ZERO).effects()[0]),
        None => clip.sharpen_amount(),
    };
    (value, rig.session.undo_depth() - depth)
}

use sq_inspector_ui::color::color_inspector_model::ColorParam;

/// One row per Simple field: (field, typed text, the stored value). Every field commits through the same edit as a
/// slider drag: one undo step.
#[test]
fn a_typed_color_value_reaches_the_clip_through_the_root_as_one_undo_step() {
    use ColorParam as P;
    let table = [
        (Some(P::Temperature), "40", 40.0),
        (Some(P::Tint), "40", 40.0),
        (Some(P::Exposure), "1", 1.0),
        (Some(P::Contrast), "40", 40.0),
        (Some(P::Highlights), "40", 40.0),
        (Some(P::Shadows), "40", 40.0),
        (Some(P::Whites), "40", 40.0),
        (Some(P::Blacks), "40", 40.0),
        (Some(P::Saturation), "130", 130.0),
        (Some(P::Vibrance), "40", 40.0),
        (None, "80", 80.0),
    ];
    for scale in [1.0, 1.5] {
        for (param, text, want) in table {
            for end in ["enter", "tab", "click away"] {
                assert_eq!(
                    root_typed(param, text, end, scale),
                    (want, 1),
                    "{param:?} typed {text} and {end} at scale {scale}"
                );
            }
            let (value, steps) = root_typed(param, text, "escape", scale);
            let neutral = param.map_or(0.0, ColorParam::neutral);
            assert_eq!((value, steps), (neutral, 0), "{param:?}: Esc reverts at scale {scale}");
        }
    }
}

/// D2: the white-balance picker on a clip that has no Color effect yet. Arm it with a click on the eyedropper, click a
/// warm pixel of the picture: the clip gets its Color effect (one undo step) with Temperature and Tint moved.
#[test]
fn a_white_balance_pick_on_a_clip_without_a_color_effect_creates_it() {
    use sq_core_color::ClipGradeExt;
    let dropper = crate::Eyedropper::default();
    let picture = crate::MonitorPicture::default();
    let (r, mut rig) = timeline_rig(&[1]);
    let mut r = r.with_color_eyedropper(dropper.clone());
    r.monitor =
        MonitorHost::new(MonitorPanel::new(MonitorPanelModel::new(Time::new(1001, 30000), MonitorMode::Program), None))
            .with_picture(picture.clone())
            .with_eyedropper(dropper.clone());
    // A warm gray picture.
    picture.set(Some(sq_draw::RgbaImage { width: 4, height: 4, pixels: [230, 200, 150, 255].repeat(16) }));
    r.dock.set_page(sq_editor_session::WorkspacePage::Color);
    let area = CGRect::new(0.0, 0.0, 1600.0, 900.0);
    for _ in 0..2 {
        r.sync(&rig.session);
        r.layout(area, &mut rig.cx());
        r.pump(&mut rig.cx());
    }
    let clip = |rig: &crate::test_rig::Rig| rig.session.single_selected_clip().expect("clip").clone();
    assert!(clip(&rig).effects.is_empty(), "no effect yet");
    let depth = rig.session.undo_depth();
    let (x, y) = r.color.eyedropper_point().expect("the eyedropper in the Basic Correction header");
    let no = InputModifiers::default();
    r.handle(&InputEvent::MouseDown { x, y, modifiers: no }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(dropper.is_armed(), "the click on the eyedropper arms the pick");
    // A click on the picture.
    let canvas = r.monitor.panel.canvas_rect();
    let (px, py) = ((canvas.x + canvas.width / 2.0) as f32, (canvas.y + canvas.height / 2.0) as f32);
    r.sync(&rig.session);
    r.layout(area, &mut rig.cx());
    r.handle(&InputEvent::MouseDown { x: px, y: py, modifiers: no }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: px, y: py }, &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
    r.layout(area, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert_eq!(rig.session.undo_depth() - depth, 1, "one undo step");
    let fx = clip(&rig).color_at_local(Time::ZERO);
    assert!(fx.effects().iter().any(|e| e.basic.temperature != 0.0 || e.basic.tint != 0.0), "{:?}", fx.effects());
}

/// The blue active-panel frame is computed from the dock's current panel rect each frame: a maximized, focused panel
/// gets one frame as big as the panel, and the shell's lagging copy of the dock draws none.
#[test]
fn the_focus_frame_follows_a_maximized_panel() {
    let mut r = root();
    laid_out(&mut r);
    r.dock.show(PanelID::Library);
    r.dock.toggle_maximize(PanelID::Library);
    r.dock.set_focused(Some(PanelID::Library));
    let panel = r.dock.groups().iter().find(|g| g.selected == PanelID::Library).expect("group").frame;
    assert!(panel.width > 900.0, "maximized: {panel:?}");
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| a.add_host(Box::new(r)));
    let (_, list) = h.turn();
    let list = list.expect("a frame");
    // The 1 px edge sits just outside the panel box (r8:537); other 1 px strokes are not within a point of the panel.
    let near = |q: &&sq_draw::draw_list::DrawQuad| {
        (f64::from(q.rect.x) - panel.x).abs() < 1.5 && (f64::from(q.rect.w) - panel.width).abs() < 3.0
    };
    let frames: Vec<_> = list.quads().iter().filter(|q| q.stroke == 1.0 && q.rect.w > 100.0).filter(near).collect();
    assert_eq!(frames.len(), 1, "one focus frame, not one per dock");
    let q = frames[0];
    assert!(
        (f64::from(q.rect.x) - (panel.x - 1.0)).abs() < 0.5
            && (f64::from(q.rect.y) - (panel.y - 1.0)).abs() < 0.5
            && (f64::from(q.rect.w) - (panel.width + 2.0)).abs() < 0.5
            && (f64::from(q.rect.h) - (panel.height + 2.0)).abs() < 0.5,
        "frame {:?} against panel {panel:?} (outset by the 1 px edge)",
        q.rect
    );
}

/// Windows check: B (Ripple) and R (Rate Stretch) pressed with the timeline focused switch the tool and the strip shows
/// it (the real key events through the root, not the queued command).
#[test]
fn tool_keys_switch_the_tool_through_the_root() {
    use sq_editor_session::TimelineTool as T;
    let (mut r, mut rig) = timeline_rig(&[]);
    r.handle(&InputEvent::MouseDown { x: 500.0, y: 700.0, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: 500.0, y: 700.0 }, &mut rig.cx());
    assert_eq!(r.dock.focused(), Some(PanelID::Timeline));
    for (c, want) in [('b', T::RippleEdit), ('r', T::RateStretch), ('v', T::Selection), ('p', T::Mask)] {
        r.handle(
            &InputEvent::KeyDown { key: sq_draw::InputKey::Character(c), modifiers: InputModifiers::NONE },
            &mut rig.cx(),
        );
        r.answer(&mut rig.cx());
        assert_eq!(r.timeline.inner().panel.tool_state().tool, want, "key {c}");
    }
}

#[test]
fn a_located_file_is_online_in_the_project_list_and_the_timeline_without_a_refresh_request() {
    // Locate relinks the media (a project change); the Project model re-checks its files when it adopts the new project
    // (`ProjectPanelModel::set_project`), so the shell services need no "refresh offline" hook of their own.
    let mut r = root();
    let dir = scratch("locate");
    let (gone, found) = (dir.join("gone.mp4"), dir.join("found.mp4"));
    let id = Id::from_u128(79);
    let media = sq_core_model::MediaRef::new(
        id,
        "gone",
        gone.to_string_lossy().as_ref(),
        sq_core_model::MediaFingerprint::new(1),
    );
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let mut session = EditorSession::new(project, SessionDeps::headless(scratch("locate-session")));
    r.sync(&session);
    r.timeline_media.pump(session.project().media.iter());
    assert!(r.project.model().is_offline(id), "nothing at the old path");
    std::fs::write(&found, b"frames").expect("file");
    assert!(session.locate_media(id, &found));
    r.sync(&session);
    r.timeline_media.pump(session.project().media.iter());
    assert!(!r.project.model().is_offline(id), "the located file is online in the Project list");
    assert!(!sq_draw_timeline::TimelineMediaSource::is_offline(&*r.timeline_media, id), "and in the timeline");
}

#[test]
fn a_missing_file_that_reappears_is_online_again_when_the_window_regains_focus() {
    let mut r = root();
    let dir = scratch("refocus");
    let file = dir.join("late.mp4");
    let id = Id::from_u128(78);
    let media = sq_core_model::MediaRef::new(
        id,
        "late",
        file.to_string_lossy().as_ref(),
        sq_core_model::MediaFingerprint::new(1),
    );
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let mut session = EditorSession::new(project, SessionDeps::headless(scratch("refocus-session")));
    let mut deps = AppDeps::headless(Arc::new(FakeClock::new()));
    let mut ui = sq_draw::UiCx::new();
    let mut events = Vec::new();
    let mut cx = HostCx {
        session: &mut session,
        ui: &mut ui,
        services: &mut deps.services,
        events: &mut events,
        atlas: None,
        scale: 1.0,
    };
    r.sync(cx.session);
    r.timeline_media.pump(cx.session.project().media.iter());
    assert!(r.project.model().is_offline(id), "nothing at the path yet");
    assert!(sq_draw_timeline::TimelineMediaSource::is_offline(&*r.timeline_media, id), "the timeline marks the clip");
    let _ = cx.session.take_events();
    std::fs::write(&file, b"frames").expect("file");
    r.sync(cx.session);
    r.focus_gained(&mut cx);
    assert!(!r.project.model().is_offline(id), "the file is back");
    // The timeline overlay and the engine follow, not only the Project row.
    r.timeline_media.pump(cx.session.project().media.iter());
    assert!(!sq_draw_timeline::TimelineMediaSource::is_offline(&*r.timeline_media, id), "the overlay is gone");
    let events = cx.session.take_events();
    assert!(
        events
            .iter()
            .any(|e| matches!(e, sq_editor_session::SessionEvent::MediaFilesChanged(ids) if ids.contains(&id))),
        "the session reopens the media: {events:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_project_opened_from_the_command_line_joins_the_recent_list() {
    let dir = scratch("launch-recent");
    let file = dir.join("launch.sqproj");
    let mut s = session();
    s.save_as(&file).expect("save");
    let r = root().with_storage(dir.join("workspaces.json"), dir.join("recents.json"));
    let h = Headless::new(s, AppDeps::headless(Arc::new(FakeClock::new())), 1000, 800);
    h.with(|a| {
        a.add_host(Box::new(r));
        a.launch();
    });
    h.turn();
    let text = std::fs::read_to_string(dir.join("recents.json")).expect("the recent list is stored");
    assert!(text.contains("launch.sqproj"), "recents: {text}");
}
