//! Headless tests of the app root: routing, dispatch, inbox, redraw rules and an async flow across a dialog.

use crate::{App, AppDeps, AppEvent, AppHost, AppMessage, CancelAllFiles, Headless, HostCx, ShellFilePicker};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers};
use sq_editor_session::{Change, EditorSession, SessionDeps, SessionRoot};
use sq_runtime::{FakeClock, ModalAnswer, ModalAsk, UiRef, modal};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

type Log = Rc<RefCell<Vec<String>>>;

fn session() -> EditorSession {
    let mut ids = sq_core_time::SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-app-shell-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn headless() -> (Headless, FakeClock) {
    let clock = FakeClock::new();
    (Headless::new(session(), AppDeps::headless(Arc::new(clock.clone())), 800, 600), clock)
}

/// A block that takes clicks inside its frame: it renames the project (one undo step) and reports a status line.
struct Block {
    name: &'static str,
    frame: CGRect,
    log: Log,
}

impl Block {
    fn boxed(name: &'static str, log: &Log) -> Box<Block> {
        Box::new(Block { name, frame: CGRect::default(), log: Rc::clone(log) })
    }
}

impl AppHost for Block {
    fn sync(&mut self, session: &EditorSession) {
        self.log.borrow_mut().push(format!("{} sync {}", self.name, session.project().name));
    }
    fn layout(&mut self, frame: CGRect, _cx: &mut HostCx) {
        self.frame = frame;
    }
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut HostCx) {
        c.fill(self.frame, t.panel());
    }
    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        match *e {
            InputEvent::MouseDown { x, y, .. } if self.frame.contains(CGPoint { x: x as f64, y: y as f64 }) => {
                let name = self.name;
                cx.session.perform("Rename", None, |p| p.name = name.to_string());
                cx.emit(AppEvent::Status(format!("{name} clicked")));
                true
            }
            InputEvent::MouseMoved { .. } => {
                cx.ui.hover.request(Some(DrawCursor::Razor));
                false
            }
            _ => false,
        }
    }
    fn on_change(&mut self, changes: Change, _cx: &mut HostCx) {
        self.log.borrow_mut().push(format!("{} change {}", self.name, changes.raw_value()));
    }
}

fn down(x: f32, y: f32) -> InputEvent {
    InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }
}

#[test]
fn first_turn_draws_then_the_loop_idles_until_input() {
    let (h, _clock) = headless();
    let log = Log::default();
    h.with(|a| a.add_host(Block::boxed("a", &log)));
    let (_, first) = h.turn();
    let first = first.unwrap_or_else(|| panic!("the first turn draws"));
    assert_eq!(first.quads().len(), 1);
    assert!(h.turn().1.is_none(), "nothing changed");
    h.input(&InputEvent::MouseMoved { x: 1.0, y: 1.0 });
    assert!(h.turn().1.is_some(), "input redraws");
}

#[test]
fn a_new_project_ends_the_status_line_of_the_one_before() {
    let (h, _clock) = headless();
    h.with(|a| a.add_host(Block::boxed("top", &Log::default())));
    h.turn();
    assert!(h.input(&down(10.0, 10.0)));
    h.with(|a| assert_eq!(a.status_text(), "top clicked"));
    h.with(|a| {
        a.session_mut()
            .new_project(sq_editor_session::EditorSession::make_empty(&mut sq_core_time::SequentialIds::default()))
    });
    h.turn();
    h.with(|a| assert_eq!(a.status_text(), ""));
}

#[test]
fn input_goes_top_most_first_and_stops_at_the_taker() {
    let (h, _clock) = headless();
    let log = Log::default();
    h.with(|a| {
        a.add_host(Block::boxed("bottom", &log));
        a.add_host(Block::boxed("top", &log));
    });
    h.turn();
    assert!(h.input(&down(10.0, 10.0)));
    h.with(|a| {
        assert_eq!(a.session().project().name, "top");
        assert_eq!(a.session().undo_name(), Some("Rename"));
        assert_eq!(a.status_text(), "top clicked");
    });
    // The edit's PROJECT change reached every host in the order added, after the handler returned.
    let changes: Vec<String> = log.borrow().iter().filter(|l| l.contains("change")).cloned().collect();
    assert!(changes.len() == 2 && changes[0].starts_with("bottom") && changes[1].starts_with("top"), "{changes:?}");
    log.borrow_mut().clear();
    h.turn();
    let syncs: Vec<String> = log.borrow().iter().filter(|l| l.contains("sync")).cloned().collect();
    assert_eq!(syncs, vec!["bottom sync top", "top sync top"]);
}

#[test]
fn a_host_frame_limits_where_it_takes_clicks() {
    let (h, _clock) = headless();
    let log = Log::default();
    h.with(|a| {
        let id = a.add_host(Block::boxed("a", &log));
        a.set_host_frame(id, Some(CGRect::new(100.0, 100.0, 50.0, 50.0)));
    });
    h.turn();
    assert!(!h.input(&down(10.0, 10.0)));
    assert!(h.input(&down(120.0, 120.0)));
}

#[test]
fn the_pointer_shape_comes_from_the_panel_under_the_pointer() {
    let (h, _clock) = headless();
    let log = Log::default();
    h.with(|a| a.add_host(Block::boxed("a", &log)));
    assert_eq!(h.with(|a| a.pointer_shape()), Some(DrawCursor::Arrow));
    h.input(&InputEvent::MouseMoved { x: 5.0, y: 5.0 });
    assert_eq!(h.with(|a| a.pointer_shape()), Some(DrawCursor::Razor));
}

#[test]
fn inbox_messages_from_other_threads_apply_at_frame_start_and_wake_the_loop() {
    let clock = FakeClock::new();
    let wakes = Arc::new(AtomicUsize::new(0));
    let w = Arc::clone(&wakes);
    let mut deps = AppDeps::headless(Arc::new(clock));
    deps.wake = Box::new(move || {
        w.fetch_add(1, Ordering::SeqCst);
    });
    let h = Headless::new(session(), deps, 400, 300);
    h.turn();
    let tx = h.with(|a| a.sender()).unwrap_or_else(|| panic!("root"));
    let media_before = h.with(|a| a.session().version(Change::MEDIA));
    std::thread::spawn(move || {
        tx.send(AppMessage::Notify(Change::MEDIA));
        tx.send(AppMessage::Post(Box::new(|a: &mut App| {
            a.session_mut().perform("Background", None, |p| p.name = "from a worker".to_string());
        })));
    })
    .join()
    .ok();
    assert_eq!(wakes.load(Ordering::SeqCst), 2);
    let (_, list) = h.turn();
    assert!(list.is_some());
    h.with(|a| {
        assert_eq!(a.session().version(Change::MEDIA), media_before.map_or(0, |v| v + 1));
        assert_eq!(a.session().project().name, "from a worker");
    });
    assert_eq!(h.with(App::drain), Some(0));
}

#[test]
fn a_tooltip_delay_keeps_frames_coming_until_it_shows() {
    struct Tip;
    impl AppHost for Tip {
        fn layout(&mut self, _frame: CGRect, _cx: &mut HostCx) {}
        fn draw(&mut self, _c: &mut Canvas, _t: &DrawTheme, _cx: &mut HostCx) {}
        fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
            if let InputEvent::MouseMoved { .. } = e {
                cx.ui.hover.offer_tip(Some("Razor"));
            }
            false
        }
    }
    let (h, clock) = headless();
    h.with(|a| a.add_host(Box::new(Tip)));
    h.turn();
    h.input(&InputEvent::MouseMoved { x: 5.0, y: 5.0 });
    h.turn();
    assert_eq!(h.with(|a| a.needs_redraw()), Some(true), "the tip waits for its delay");
    clock.advance(std::time::Duration::from_secs(5));
    let (_, list) = h.turn();
    assert!(list.is_some_and(|l| !l.quads().is_empty()), "the tip is drawn");
}

/// A picker whose project dialog stays open until the test answers it.
#[derive(Default)]
struct OpenDialogs(Rc<RefCell<Vec<ModalAnswer<Option<PathBuf>>>>>);

impl ShellFilePicker for OpenDialogs {
    fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
        let (ask, answer) = modal();
        self.0.borrow_mut().push(answer);
        ask
    }
    fn choose_save_location(&mut self, _suggested_name: &str, _prompt: &str) -> ModalAsk<Option<PathBuf>> {
        crate::answered(None)
    }
    fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
        CancelAllFiles.choose_media()
    }
}

/// An open-project flow in the shape of a session flow: short borrows, the dialog awaited outside them.
async fn open_flow<R: SessionRoot + ?Sized>(h: UiRef<R>, ask: impl FnOnce(&mut R) -> ModalAsk<Option<PathBuf>>) {
    let Some(dialog) = h.with(ask) else { return };
    let Some(path) = dialog.await else { return };
    h.with(|r| r.session().perform("Open", None, |p| p.name = path.display().to_string()));
}

#[test]
fn an_async_flow_awaits_a_platform_dialog_outside_the_root_borrow() {
    let (h, _clock) = headless();
    let dialogs = OpenDialogs::default();
    let answers = Rc::clone(&dialogs.0);
    h.with(|a| a.services_mut().files = Box::new(dialogs));
    let handle = h.handle();
    h.executor().spawn_local(open_flow(handle, |a: &mut App| a.services_mut().files.choose_project()));
    h.turn();
    assert_eq!(answers.borrow().len(), 1, "the dialog is open");
    assert!(answers.borrow()[0].answer(Some(PathBuf::from("/films/cut.sqproj"))));
    h.turn();
    h.with(|a| assert_eq!(a.session().project().name, "/films/cut.sqproj"));
}

#[test]
fn a_flow_started_by_a_task_runs_in_the_same_turn() {
    use sq_draw_shell::{ShellFlow, ShellRoot};
    let (h, _clock) = headless();
    let handle = h.handle();
    // Like the export follower: a task ends and queues the "Export finished" card; no input or timer follows.
    h.executor().spawn_local(async move {
        let _ = handle.with(|a| a.emit_flow(ShellFlow::ExportFinished(vec![PathBuf::from("/out/a.mp4")])));
    });
    h.turn();
    assert!(h.with(|a| a.shell_parts().shell.dialog().is_some()).unwrap(), "the card is up after one turn");
}

#[test]
fn a_polling_task_wakes_the_loop_and_queues_the_card_when_its_timer_is_due() {
    use sq_draw_shell::{ShellFlow, ShellRoot};
    let (h, clock) = headless();
    let handle = h.handle();
    // The export follower: poll every 250 ms, then queue the "Export finished" card when the jobs are done.
    h.executor().spawn_local(async move {
        for _ in 0..3 {
            if sq_runtime::sleep(std::time::Duration::from_millis(250)).await.is_err() {
                return;
            }
        }
        let _ = handle.with(|a| a.emit_flow(ShellFlow::ExportFinished(vec![PathBuf::from("/out/a.mp4")])));
    });
    h.turn();
    let mut waits = 0;
    // What the window loop does: sleep until the executor's next deadline, then turn.
    while let Some(at) = h.executor().next_deadline() {
        clock.set(at);
        h.turn();
        waits += 1;
        assert!(waits <= 3, "the timer chain ends");
    }
    assert_eq!(waits, 3, "each poll arms the next deadline");
    assert!(h.with(|a| a.shell_parts().shell.dialog().is_some()).unwrap(), "the card is up with no input");
}

#[test]
fn a_flow_ends_quietly_once_the_app_is_gone() {
    let (h, _clock) = headless();
    let weak = h.handle();
    drop(h);
    assert!(!weak.is_alive());
    assert_eq!(weak.with(|a| a.status_text().to_string()), None);
}

#[test]
fn ten_thousand_random_events_do_not_panic() {
    let (h, _clock) = headless();
    let log = Log::default();
    h.with(|a| {
        let id = a.add_host(Block::boxed("left", &log));
        a.set_host_frame(id, Some(CGRect::new(0.0, 0.0, 400.0, 600.0)));
        a.add_host(Block::boxed("right", &log));
    });
    // A fixed LCG: the run is the same every time.
    let mut seed: u64 = 0x5eed;
    let mut next = move || {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) as u32
    };
    let keys = [InputKey::Space, InputKey::Left, InputKey::Right, InputKey::Up, InputKey::Down, InputKey::Home];
    for i in 0..10_000 {
        let (x, y) = ((next() % 1000) as f32 - 100.0, (next() % 800) as f32 - 100.0);
        let e = match next() % 6 {
            0 => down(x, y),
            1 => InputEvent::dragged(x, y),
            2 => InputEvent::MouseUp { x, y },
            3 => InputEvent::MouseMoved { x, y },
            4 => InputEvent::Scroll { x, y, dx: 1.0, dy: -2.0, modifiers: InputModifiers::SHIFT },
            _ => InputEvent::KeyDown { key: keys[next() as usize % keys.len()], modifiers: InputModifiers::COMMAND },
        };
        h.input(&e);
        if i % 50 == 0 {
            log.borrow_mut().clear();
            h.turn();
        }
    }
    assert_eq!(h.with(|a| a.session().can_undo()), Some(true));
}

/// Probes every path as a ten-second clip named after the file, so imports run without a media library.
struct TenSeconds;

impl sq_editor_session::ImportBackend for TenSeconds {
    fn probe(&self, path: &std::path::Path) -> Result<sq_core_model::MediaRef, sq_editor_session::ImportError> {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let id = sq_core_time::Id::fixed(name.len() as u64 + 1);
        let mut m =
            sq_core_model::MediaRef::new(id, &name, &path.to_string_lossy(), sq_core_model::MediaFingerprint::new(1));
        m.duration = Some(sq_core_time::Time::new(10, 1));
        Ok(m)
    }
}

#[test]
fn dropped_files_land_in_the_project_and_can_be_placed_on_the_timeline() {
    let clock = FakeClock::new();
    let mut deps = AppDeps::headless(Arc::new(clock.clone()));
    deps.import.backend = Arc::new(TenSeconds);
    deps.import.pool = Arc::new(sq_runtime::WorkerPool::threads(2));
    let app = Headless::new(session(), deps, 800, 600);
    app.with(|a| a.drop_files(vec![PathBuf::from("/media/clip.mov")]));
    for _ in 0..200 {
        app.turn();
        if app.with(|a| !a.session().project().media.is_empty()).unwrap_or(false) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let placed = app.with(|a| {
        let media = a.session().project().media.first().cloned();
        let id = media.as_ref().map(|m| m.id);
        let name = media.map(|m| (m.name, m.duration));
        assert_eq!(name, Some(("clip.mov".to_string(), Some(sq_core_time::Time::new(10, 1)))));
        assert_eq!(a.panel().project().media.len(), 1);
        a.session_mut().place_media(&id.into_iter().collect::<Vec<_>>(), &sq_editor_session::PlaceOptions::default())
    });
    assert_eq!(placed, Some(true));
    let clips = app
        .with(|a| a.session().active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum::<usize>()));
    assert_eq!(clips, Some(1));
}

#[test]
fn files_dragged_to_the_timeline_are_imported_and_placed() {
    let clock = FakeClock::new();
    let mut deps = AppDeps::headless(Arc::new(clock.clone()));
    deps.import.backend = Arc::new(TenSeconds);
    deps.import.pool = Arc::new(sq_runtime::WorkerPool::threads(2));
    let app = Headless::new(session(), deps, 800, 600);
    app.with(|a| a.emit_flow(sq_draw_shell::ShellFlow::PlaceFiles(vec![PathBuf::from("/media/drag.mov")])));
    for _ in 0..200 {
        app.turn();
        let clips = app.with(|a| {
            a.session().active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum::<usize>())
        });
        if clips == Some(1) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    panic!("the dragged file was not placed");
}

#[test]
fn a_display_scale_change_keeps_the_interface_size() {
    let (h, _clock) = headless();
    h.with(|a| {
        a.set_display_scale(2.0);
        a.set_ui_scale(1.25);
        assert_eq!(a.theme().scale, 2.5);
        a.set_display_scale(1.0);
        assert_eq!(a.theme().scale, 1.25, "the new display scale times the interface size");
        a.set_display_scale(2.0);
        assert_eq!(a.theme().scale, 2.5);
    });
}
