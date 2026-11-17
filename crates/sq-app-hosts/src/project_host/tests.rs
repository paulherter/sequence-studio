//! Tests of the Project host: the rows follow the session's project, events route to the session.

use super::*;
use sq_core_model::{MediaFingerprint, MediaRef, Project};
use sq_core_time::Time;
use sq_draw::{Canvas, DrawTheme};
use sq_editor_session::SessionDeps;
use sq_editor_session::{Thumbnail, ThumbnailJob};
use sq_runtime::WorkerPool;
use sq_uikit::controls_grid::CGSize;

fn session_with_clip() -> (EditorSession, Id) {
    session_with_path("/tmp/interview.mp4")
}

fn session_with_path(path: &str) -> (EditorSession, Id) {
    let id = Id::from_u128(77);
    let mut reference = MediaRef::new(id, "interview", path, MediaFingerprint::new(1));
    reference.duration = Some(Time::seconds(4));
    let project = Project::new(Id::from_u128(2), "p", vec![reference], Vec::new());
    let deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-project"));
    (EditorSession::new(project, deps), id)
}

fn quads(host: &mut ProjectHost) -> usize {
    let mut rig = crate::test_rig::Rig::new(session_with_clip().0);
    host.layout(CGRect::new(0.0, 0.0, 480.0, 300.0), &mut rig.cx());
    let mut canvas = Canvas::with_size(480.0, 300.0, None, 1.0);
    host.draw(&mut canvas, &DrawTheme::default(), &mut rig.cx());
    canvas.list.quads().len()
}

#[test]
fn the_list_shows_the_media_of_the_session() {
    let (session, id) = session_with_clip();
    let mut host = ProjectHost::new();
    let empty = quads(&mut host);
    host.sync(&session);
    let rows = host.view.rows(host.model());
    assert!(rows.iter().any(|r| r.item_ref == BinItemRef::Media(id)), "the imported clip has a row");
    assert!(quads(&mut host) > empty, "the row draws");
}

#[test]
fn events_that_need_only_the_session_run_and_the_rest_waits() {
    let (mut session, id) = session_with_clip();
    let events = vec![
        ProjectListEvent::Flash("hi".into()),
        ProjectListEvent::Host(ProjectMenuAction::ImportMedia, Vec::new()),
        ProjectListEvent::Host(ProjectMenuAction::Rename, vec![BinItemRef::Media(id)]),
    ];
    let (deferred, status, flows) = route_project(&mut session, events);
    assert_eq!(status, ["hi"]);
    assert!(matches!(flows.as_slice(), [ShellFlow::ImportAnything]));
    assert!(matches!(deferred.as_slice(), [ProjectListEvent::Host(ProjectMenuAction::Rename, _)]));
}

#[test]
fn insert_and_overwrite_go_through_the_format_question_flow() {
    let (mut session, id) = session_with_clip();
    for (action, mode) in
        [(ProjectMenuAction::Insert, ThreePointMode::Insert), (ProjectMenuAction::Overwrite, ThreePointMode::Overwrite)]
    {
        let refs = vec![BinItemRef::Media(id)];
        let (_, status, flows) = route_project(&mut session, vec![ProjectListEvent::Host(action, refs)]);
        assert!(status.is_empty(), "{status:?}");
        match flows.as_slice() {
            [ShellFlow::PlaceMedia { ids, options }] => {
                assert_eq!(ids, &[id]);
                assert_eq!(options.mode, mode);
            }
            other => panic!("expected one PlaceMedia flow, got {other:?}"),
        }
    }
}

struct FakeSource;

impl ThumbnailSource for FakeSource {
    fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
        let pic = Thumbnail { width: 2, height: 1, rgba: Arc::new(vec![9; 8]) };
        match job {
            ThumbnailJob::PosterAndFrame { .. } => vec![Some(pic.clone()), Some(pic)],
            _ => vec![Some(pic)],
        }
    }
}

#[derive(Default)]
struct FakePlatform(std::sync::Arc<std::sync::Mutex<Vec<std::path::PathBuf>>>);

impl FileManager for FakePlatform {
    fn reveal(&self, path: &Path) -> Result<(), String> {
        self.0.lock().map_err(|e| e.to_string())?.push(path.to_path_buf());
        Ok(())
    }

    fn open(&self, path: &Path) -> Result<(), String> {
        self.reveal(path)
    }
}

fn host_with(pool: Arc<WorkerPool>, platform: FakePlatform) -> ProjectHost {
    ProjectHost::with_services(Arc::new(FakeSource), pool, Box::new(platform))
}

#[test]
fn a_poster_is_decoded_on_a_worker_and_lands_in_a_slot() {
    let (session, id) = session_with_clip();
    let pool = Arc::new(WorkerPool::manual());
    let mut host = host_with(Arc::clone(&pool), FakePlatform::default());
    host.sync(&session);
    assert!(host.view.posters.is_empty(), "nothing is drawn before the worker ran");
    assert_eq!(pool.pending(), 1, "the decode waits for a worker, not the UI thread");
    assert!(pool.step());
    host.sync(&session);
    let poster = host.view.posters.get(&id).copied();
    assert_eq!(poster.map(|p| p.pixel_size), Some(CGSize::new(2.0, 1.0)));
    let uploads = host.take_uploads();
    assert_eq!(uploads.len(), 1);
    assert_eq!(Some(uploads[0].slot), poster.map(|p| p.slot));
    assert_eq!(uploads[0].at, Some((0, 0)), "the first poster sits in the atlas corner");
    host.sync(&session);
    assert!(host.take_uploads().is_empty(), "a settled poster is not made again");
}

#[test]
fn every_poster_stays_after_more_imports_and_a_reopen() {
    let session_of = |n: u128| {
        let refs: Vec<MediaRef> = (1..=n)
            .map(|i| {
                let mut r =
                    MediaRef::new(Id::from_u128(i), "clip", &format!("/tmp/clip{i}.mp4"), MediaFingerprint::new(1));
                r.duration = Some(Time::seconds(4));
                r
            })
            .collect();
        let project = Project::new(Id::from_u128(2), "p", refs, Vec::new());
        EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-project")))
    };
    let pool = Arc::new(WorkerPool::manual());
    let mut host = host_with(Arc::clone(&pool), FakePlatform::default());
    let settle = |host: &mut ProjectHost, session: &EditorSession| {
        host.sync(session);
        // More posters than decode slots: each settled one starts the next.
        while pool.pending() > 0 {
            while pool.step() {}
            host.sync(session);
        }
    };
    let have = |host: &ProjectHost, n: u128| (1..=n).all(|i| host.view.posters.contains_key(&Id::from_u128(i)));
    settle(&mut host, &session_of(5));
    assert!(have(&host, 5), "five imports, five posters");
    host.shown = None;
    settle(&mut host, &session_of(8));
    assert!(have(&host, 8), "later imports keep the earlier posters");
    // Reopen: the view lost its pictures (the pump still has them cached and decodes nothing).
    host.view.posters.clear();
    host.shown = None;
    settle(&mut host, &session_of(8));
    assert!(have(&host, 8), "after a reopen every item shows its poster again");
}

#[test]
fn find_replace_and_locate_start_the_shell_flows() {
    let (mut session, id) = session_with_clip();
    let refs = vec![BinItemRef::Media(id)];
    let events = vec![
        ProjectListEvent::Host(ProjectMenuAction::Find, Vec::new()),
        ProjectListEvent::Host(ProjectMenuAction::ReplaceMedia, refs.clone()),
        ProjectListEvent::Host(ProjectMenuAction::LocateMedia, refs),
    ];
    let (deferred, _, flows) = route_project(&mut session, events);
    assert!(deferred.is_empty());
    assert!(matches!(
        flows.as_slice(),
        [
            ShellFlow::Tool(ShellTool::Find),
            ShellFlow::Tool(ShellTool::ReplaceMedia(a)),
            ShellFlow::Tool(ShellTool::LocateOffline(b)),
        ] if *a == id && *b == id
    ));
}

#[test]
fn reveal_shows_an_existing_file_and_reports_an_offline_one() {
    let file = std::env::temp_dir().join("sq-app-hosts-reveal.txt");
    assert!(std::fs::write(&file, b"x").is_ok());
    for (path, shown) in [("/no/such/file.mp4", false), (file.to_str().unwrap_or_default(), true)] {
        let (session, id) = session_with_path(path);
        let seen = FakePlatform::default();
        let log = Arc::clone(&seen.0);
        let mut host = host_with(Arc::new(WorkerPool::manual()), seen);
        let mut rig = crate::test_rig::Rig::new(session);
        host.model.set_project(rig.session.project().clone());
        let event = ProjectListEvent::Host(ProjectMenuAction::Reveal, vec![BinItemRef::Media(id)]);
        host.route_events(vec![event], &mut rig.cx());
        let revealed = log.lock().map(|l| l.clone()).unwrap_or_default();
        if shown {
            assert_eq!(revealed, vec![file.clone()]);
            assert!(rig.events.is_empty());
        } else {
            assert!(revealed.is_empty());
            assert!(matches!(rig.events.as_slice(), [AppEvent::Status(s)] if s == "The file is offline."));
        }
    }
}

#[test]
fn rename_edits_in_place_and_commits_on_enter() {
    let (session, id) = session_with_clip();
    let mut host = host_with(Arc::new(WorkerPool::manual()), FakePlatform::default());
    host.sync(&session);
    let mut rig = crate::test_rig::Rig::new(session);
    host.route_events(vec![ProjectListEvent::Rename(BinItemRef::Media(id))], &mut rig.cx());
    assert!(host.is_renaming());
    let key = |key| InputEvent::KeyDown { key, modifiers: InputModifiers::NONE };
    assert!(host.handle(&key(InputKey::Escape), &mut rig.cx()));
    assert!(!host.is_renaming(), "Escape leaves the name as it was");
    assert_eq!(host.model.display_name(BinItemRef::Media(id)), "interview");

    host.route_events(vec![ProjectListEvent::Rename(BinItemRef::Media(id))], &mut rig.cx());
    if let Some(r) = &mut host.renaming {
        r.field = TextFieldControl::new("A");
        r.field.mouse_down(None, 1);
    }
    assert!(host.handle(&key(InputKey::Enter), &mut rig.cx()));
    assert!(!host.is_renaming());
    assert_eq!(host.model.display_name(BinItemRef::Media(id)), "A");
}

#[test]
fn view_settings_round_trip_through_the_store() {
    use sq_draw_shell::{MemoryDefaults, ViewMode};
    let store: SharedDefaults = std::rc::Rc::new(std::cell::RefCell::new(MemoryDefaults::default()));
    let s = ProjectListSettings {
        view_mode: ViewMode::Icons,
        search_visible: true,
        thumb_size: 120.0,
        ..ProjectListSettings::default()
    };
    write_settings(&mut *store.borrow_mut(), &s);
    let read = read_settings(&*store.borrow());
    assert_eq!(read, s);
    let mut host = ProjectHost::new();
    host.set_settings_store(store);
    assert_eq!(host.view().settings(), &s);
}

#[test]
fn the_rows_are_accessibility_nodes() {
    let (session, _) = session_with_clip();
    let mut host = ProjectHost::new();
    host.sync(&session);
    let mut a = A11y::new(true);
    host.a11y(&mut a);
    let roles: Vec<_> = a.nodes().iter().map(|(_, n)| n.role()).collect();
    assert_eq!(roles[0], sq_draw::panel::Role::List);
    assert!(roles.contains(&sq_draw::panel::Role::ListItem));
}

#[test]
fn a_click_on_a_row_node_selects_the_item() {
    let (session, _) = session_with_clip();
    let mut host = ProjectHost::new();
    host.sync(&session);
    let mut rig = crate::test_rig::Rig::new(session_with_clip().0);
    let mut a = A11y::new(true);
    host.a11y(&mut a);
    let row = a.nodes().iter().find(|(_, n)| n.role() == sq_draw::panel::Role::ListItem).map(|(id, _)| *id);
    let row = row.expect("a row node");
    assert!(host.a11y_action(row, sq_app_shell::A11yAction::Click, &mut rig.cx()));
    let mut b = A11y::new(true);
    host.a11y(&mut b);
    assert!(b.nodes().iter().any(|(_, n)| n.is_selected() == Some(true)));
    assert!(!host.a11y_action(accesskit::NodeId(1), sq_app_shell::A11yAction::Click, &mut rig.cx()));
}

#[test]
fn a_click_on_a_row_selects_it_at_every_display_scale() {
    for scale in [1.0_f32, 1.5, 2.0] {
        let (session, id) = session_with_clip();
        let mut host = ProjectHost::new();
        host.sync(&session);
        let mut rig = crate::test_rig::Rig::new(session_with_clip().0).at_scale(scale);
        host.layout(CGRect::new(0.0, 0.0, 480.0, 300.0), &mut rig.cx());
        // Events are pixels: the point (x, y) of the layout arrives as (x, y) times the scale.
        let mut hit = false;
        let mut y = 0.0_f32;
        while !hit && y < 300.0 {
            let (px, py) = (60.0 * scale, y * scale);
            host.handle(&InputEvent::MouseDown { x: px, y: py, modifiers: InputModifiers::NONE }, &mut rig.cx());
            host.handle(&InputEvent::MouseUp { x: px, y: py }, &mut rig.cx());
            hit = host.view.selection().contains(&BinItemRef::Media(id));
            y += 2.0;
        }
        assert!(hit, "a click on the row selects the clip at scale {scale}");
    }
}

#[test]
fn panel_menu_rows_start_the_shell_flows_the_swift_panel_ran() {
    let (mut session, _) = session_with_clip();
    let events = vec![
        ProjectListEvent::Host(ProjectMenuAction::NewColorMatte, Vec::new()),
        ProjectListEvent::Host(ProjectMenuAction::CustomPixelAspect, Vec::new()),
        ProjectListEvent::Collect,
    ];
    let (deferred, status, flows) = route_project(&mut session, events);
    assert!(status.is_empty());
    // New Color Matte… opens the timeline menu's dialog in the root.
    assert!(matches!(deferred.as_slice(), [ProjectListEvent::Host(ProjectMenuAction::NewColorMatte, _)]));
    assert_eq!(flows, [ShellFlow::Project(ShellAction::CustomPixelAspect), ShellFlow::Tool(ShellTool::CollectFiles),]);
}

#[test]
fn reconnect_with_all_media_online_says_so() {
    let (mut session, _) = session_with_path(&std::env::current_exe().unwrap().to_string_lossy());
    let (_, status, flows) = route_project(&mut session, vec![ProjectListEvent::Reconnect]);
    if session.can_relink() {
        assert!(matches!(flows.as_slice(), [ShellFlow::Project(ShellAction::RelinkMedia)]));
    } else {
        assert_eq!(status, ["All media is online."]);
    }
}

/// A press on a tile in icon view, a pull past the slop and a release raise a drag on the media, at every display scale.
#[test]
fn dragging_a_tile_in_icon_view_raises_the_drag_at_every_scale() {
    use sq_draw::InputModifiers;
    use sq_draw_shell::{MemoryDefaults, ViewMode};
    for scale in [1.0_f32, 1.5, 2.0] {
        let (session, id) = session_with_clip();
        let store: SharedDefaults = std::rc::Rc::new(std::cell::RefCell::new(MemoryDefaults::default()));
        write_settings(
            &mut *store.borrow_mut(),
            &ProjectListSettings { view_mode: ViewMode::Icons, ..ProjectListSettings::default() },
        );
        let mut host = ProjectHost::new();
        host.set_settings_store(store);
        host.sync(&session);
        let mut rig = crate::test_rig::Rig::new(session).at_scale(scale);
        host.layout(CGRect::new(900.0, 400.0, 300.0, 300.0), &mut rig.cx());
        // Probe the grid like a pointer: the first point that selects the item is on a tile.
        let mut hit = None;
        'scan: for gy in 0..60 {
            for gx in 0..30 {
                let (x, y) = ((905 + gx * 10) as f32 * scale, (430 + gy * 4) as f32 * scale);
                host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
                host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
                if host.view().selection() == [BinItemRef::Media(id)] {
                    hit = Some((x, y));
                    break 'scan;
                }
            }
        }
        let (x, y) = hit.expect("a tile under the probe");
        host.take_deferred();
        host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
        host.handle(&InputEvent::dragged(x - 300.0 * scale, y - 100.0 * scale), &mut rig.cx());
        host.handle(&InputEvent::MouseUp { x: x - 300.0 * scale, y: y - 100.0 * scale }, &mut rig.cx());
        let drags = host
            .take_deferred()
            .iter()
            .filter(|d| matches!(d, ProjectListEvent::Drag { phase: sq_draw_shell::DragPhase::Ended, .. }))
            .count();
        assert_eq!(drags, 1, "icon-view drag ended once at scale {scale}");
    }
}

/// The Locate… button in the Project panel's footer starts the Reconnect Media flow, like the menu row does.
#[test]
fn the_footer_locate_button_starts_the_relink_flow() {
    use sq_draw::InputModifiers;
    for scale in [1.0_f32, 2.0] {
        let (session, _) = session_with_path("/nonexistent/missing.mp4");
        let mut host = ProjectHost::new();
        host.sync(&session);
        let mut rig = crate::test_rig::Rig::new(session).at_scale(scale);
        host.layout(CGRect::new(0.0, 0.0, 480.0, 300.0), &mut rig.cx());
        // Probe the footer row from the right like a pointer; the button is the rightmost part of the line.
        let y = (300.0 - 12.0) * scale;
        let mut started = false;
        for gx in 0..40 {
            let x = (470.0 - f32::from(gx as u8) * 4.0) * scale;
            host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
            host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
            // No pump: the root pumps the host only when a menu closes, so a direct press must act by itself.
            if rig.events.iter().any(|e| matches!(e, AppEvent::Flow(ShellFlow::Project(ShellAction::RelinkMedia)))) {
                started = true;
                break;
            }
        }
        assert!(started, "the footer Locate… press raised no relink flow at scale {scale}: {:?}", rig.events.len());
    }
}
