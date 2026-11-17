//! Tests of the Shell host: event routing, a command that reports a status line, and the bar through the headless App.

use super::*;
use sq_app_shell::{A11yAction, App, AppDeps, AppServices, Headless};
use sq_core_time::{SequentialIds, Timestamp};
use sq_draw::{InputModifiers, UiCx};
use sq_editor_session::{RecentProjects, SessionDeps};
use sq_runtime::FakeClock;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use std::sync::Arc;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-shell-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn shell() -> DrawShell {
    DrawShell::new(
        CommandMap::premiere_default(),
        RecentProjects::new(Vec::new()),
        Arc::new(FakeClock::new()),
        Box::new(|| Timestamp::from_unix_seconds(0.0)),
    )
}

#[test]
fn status_lines_are_split_off_and_the_rest_keeps_its_order() {
    let events = vec![ShellEvent::Status("Saved".into()), ShellEvent::Quit, ShellEvent::ProjectChanged];
    let (deferred, status) = route_shell(events, vec![ShellFlow::ChooseAndOpenProject]);
    assert_eq!(status, vec!["Saved".to_string()]);
    assert_eq!(
        deferred,
        vec![
            ShellDeferred::Event(ShellEvent::Quit),
            ShellDeferred::Event(ShellEvent::ProjectChanged),
            ShellDeferred::Flow(ShellFlow::ChooseAndOpenProject),
        ]
    );
}

#[test]
fn a_menu_command_that_awaits_a_dialog_waits_as_a_flow() {
    let mut host = ShellHost::new(shell(), None);
    let (mut s, mut ui, mut services, mut events) = (session(), UiCx::new(), AppServices::headless(), Vec::new());
    {
        let mut sc = ShellCx {
            session: &mut s,
            measure: sq_draw::TextMeasure::new(None, 1.0),
            ui: &mut ui,
            hooks: &mut NoHooks,
        };
        host.shell().execute(&mut sc, EditorCommand::Preferences);
    }
    let mut cx =
        HostCx { session: &mut s, ui: &mut ui, services: &mut services, events: &mut events, atlas: None, scale: 1.0 };
    host.on_change(Change::PROJECT, &mut cx);
    assert!(events.is_empty(), "a flow is not a status line");
    assert_eq!(host.take_deferred(), vec![ShellDeferred::Flow(ShellFlow::ShowPreferences)]);
}

#[test]
fn the_bar_draws_and_a_click_on_it_opens_a_menu_through_the_app() {
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a: &mut App| {
        a.add_host(Box::new(ShellHost::new(shell(), None)));
    });
    let (_, list) = h.turn();
    assert!(list.is_some_and(|l| !l.quads().is_empty()), "the bar draws");
    assert!(
        h.input(&InputEvent::MouseDown { x: 30.0, y: 10.0, modifiers: InputModifiers::NONE }),
        "a title takes the click"
    );
}

#[test]
fn menus_and_rows_are_accessibility_nodes_and_a_click_runs_the_row() {
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a: &mut App| {
        a.add_host(Box::new(ShellHost::new(shell(), None)));
    });
    h.turn();
    let a = h.with(|a: &mut App| a.accessibility(true)).expect("app");
    let items: Vec<_> = a.nodes().iter().filter(|(_, n)| n.role() == accesskit::Role::MenuItem).collect();
    assert!(items.len() > 10, "titles and rows");
    assert!(a.nodes().iter().any(|(_, n)| n.role() == accesskit::Role::MenuBar));
    let ran = items
        .iter()
        .filter(|(_, n)| n.supports_action(accesskit::Action::Click))
        .filter(|(id, _)| h.with(|app: &mut App| app.accessibility_action(*id, A11yAction::Click)).unwrap_or(false))
        .count();
    assert!(ran > 0, "an enabled row runs its action");
}

/// Node ids by label of everything the host pushes.
fn nodes_of(host: &ShellHost) -> Vec<(accesskit::NodeId, accesskit::Node)> {
    let mut a = A11y::new(true);
    host.a11y(&mut a);
    a.take()
}

fn id_of(all: &[(accesskit::NodeId, accesskit::Node)], role: accesskit::Role, label: &str) -> accesskit::NodeId {
    all.iter().find(|(_, n)| n.role() == role && n.label() == Some(label)).map(|(i, _)| *i).expect(label)
}

#[test]
fn a_menu_title_click_opens_its_menu() {
    let mut host = ShellHost::new(shell(), None);
    let (mut s, mut ui, mut services, mut events) = (session(), UiCx::new(), AppServices::headless(), Vec::new());
    let mut cx =
        HostCx { session: &mut s, ui: &mut ui, services: &mut services, events: &mut events, atlas: None, scale: 1.0 };
    host.sync(cx.session);
    host.layout(CGRect::new(0.0, 0.0, 800.0, 600.0), &mut cx);
    let all = nodes_of(&host);
    let title =
        all.iter().find(|(_, n)| n.role() == accesskit::Role::MenuItem && n.supports_action(accesskit::Action::Click));
    let (id, _) = title.expect("a title");
    assert_eq!(host.inner.menu_bar.open(), None);
    assert!(host.a11y_action(*id, A11yAction::Click, &mut cx));
    assert!(host.inner.menu_bar.open().is_some());
}

#[test]
fn dialog_buttons_and_fields_are_nodes_that_take_presses_and_values() {
    use sq_draw_shell::{FormRow as Row, ShellDialog, ShellForm};
    use sq_uikit::sqdialog_model::SQDialogRole;
    let mut sh = shell();
    let mut d = ShellDialog::new("Rename", "Pick a name");
    d.add_button("Rename", SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.form = Some(Box::new(ShellForm::new(vec![
        Row::Field { id: "name".into(), label: "Name".into(), value: "Old".into(), unit: String::new() },
        Row::Check { id: "all".into(), title: "All".into(), on: false },
        Row::Popup { id: "kind".into(), label: "Kind".into(), options: vec!["A".into(), "B".into()], selected: 0 },
    ])));
    let _ask = sh.present(d);
    let mut host = ShellHost::new(sh, None);
    let (mut s, mut ui, mut services, mut events) = (session(), UiCx::new(), AppServices::headless(), Vec::new());
    let mut cx =
        HostCx { session: &mut s, ui: &mut ui, services: &mut services, events: &mut events, atlas: None, scale: 1.0 };
    let all = nodes_of(&host);
    assert!(all.iter().any(|(_, n)| n.role() == accesskit::Role::Dialog && n.label() == Some("Rename")));
    let name = id_of(&all, accesskit::Role::TextInput, "Name");
    assert!(host.a11y_action(name, A11yAction::SetText("Trip".into()), &mut cx));
    let all2 = nodes_of(&host);
    let shown = all2.iter().find(|(i, _)| *i == name).and_then(|(_, n)| n.value().map(str::to_string));
    assert_eq!(shown.as_deref(), Some("Trip"));
    let check = id_of(&all, accesskit::Role::CheckBox, "All");
    assert!(host.a11y_action(check, A11yAction::Click, &mut cx));
    let kind = id_of(&all, accesskit::Role::ComboBox, "Kind");
    assert!(host.a11y_action(kind, A11yAction::SetText("B".into()), &mut cx));
    assert!(!host.a11y_action(kind, A11yAction::SetText("Z".into()), &mut cx));
    let all3 = nodes_of(&host);
    let on = all3.iter().find(|(i, _)| *i == check).map(|(_, n)| n.toggled());
    assert_eq!(on, Some(Some(accesskit::Toggled::True)));
    let kind_value = all3.iter().find(|(i, _)| *i == kind).and_then(|(_, n)| n.value().map(str::to_string));
    assert_eq!(kind_value.as_deref(), Some("B"));
    let ok = id_of(&all, accesskit::Role::Button, "Rename");
    assert!(host.a11y_action(ok, A11yAction::Click, &mut cx));
    assert!(!host.has_dialog(), "the press answered the dialog");
}

#[test]
fn the_start_window_controls_are_nodes_and_a_click_runs_them() {
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 1280, 800);
    h.with(|a: &mut App| {
        a.add_host(Box::new(ShellHost::new(shell(), None)));
        a.launch();
    });
    h.turn();
    let a = h.with(|a: &mut App| a.accessibility(true)).expect("app");
    let find = |a: &A11y, role: accesskit::Role, label: &str| {
        a.nodes().iter().find(|(_, n)| n.role() == role && n.label() == Some(label)).map(|(i, _)| *i)
    };
    let new_project = find(&a, accesskit::Role::Button, "New Project").expect("the rail's New Project button");
    assert!(find(&a, accesskit::Role::Tab, "Recent").is_some(), "the tabs are nodes");
    assert!(h.with(|app: &mut App| app.accessibility_action(new_project, A11yAction::Click)).unwrap_or(false));
}

#[test]
fn the_welcome_waits_for_the_recovery_offer_and_skips_a_recovered_project() {
    let mut h = ShellHost::new(shell(), None);
    h.welcome_checked = false;
    h.hold_welcome(true, false);
    assert!(h.welcome_held && !h.welcome_checked, "held: still waiting, not consumed");
    h.hold_welcome(false, false);
    assert!(!h.welcome_held);
    h.hold_welcome(false, true);
    assert!(h.welcome_checked, "a recovered project gets no tour this run");
}

/// Alt held with a letter (Windows, Linux): opens the menu whose mnemonic it is, unless the chord is a bound shortcut.
#[test]
fn alt_with_a_mnemonic_letter_opens_its_menu_and_a_bound_alt_chord_still_runs() {
    use sq_draw::InputKey;
    let alt = |c: char| InputEvent::KeyDown { key: InputKey::Character(c), modifiers: InputModifiers::OPTION };
    let mut host = ShellHost::new(shell(), None);
    host.inner.platform = sq_os::Platform::Windows;
    let (mut s, mut ui, mut services, mut events) = (session(), UiCx::new(), AppServices::headless(), Vec::new());
    let mut cx =
        HostCx { session: &mut s, ui: &mut ui, services: &mut services, events: &mut events, atlas: None, scale: 1.0 };
    host.sync(cx.session);
    host.layout(CGRect::new(0.0, 0.0, 800.0, 600.0), &mut cx);
    let map = CommandMap::premiere_default();
    let bound: Vec<char> = "abcdefghijklmnopqrstuvwxyz"
        .chars()
        .filter(|c| {
            sq_draw_shell::ShellKeys::command(InputKey::Character(*c), InputModifiers::OPTION, None, &map, false)
                .is_some()
        })
        .collect();
    assert!(!bound.is_empty(), "the map binds some Alt chords");
    assert!(!bound.contains(&'f'), "Alt+F is free");
    host.handle(&alt('f'), &mut cx);
    assert_eq!(host.inner.menu_bar.open(), Some(0), "Alt+F opens File");
    host.inner.menu_bar.dismiss();
    for c in bound {
        host.handle(&alt(c), &mut cx);
        assert_eq!(host.inner.menu_bar.open(), None, "Alt+{c} is bound: no menu opens");
    }
}

/// The real track header menu, opened by a right-click at the bottom of the window: whole (no scrollbar) whenever the room
/// above or below holds it, and "Rename…" stays reachable. Window heights 600-1080 px at the Windows scales.
#[test]
fn the_track_header_menu_at_the_window_bottom_shows_whole_without_a_scrollbar() {
    use sq_core_model::{Track, TrackKind};
    use sq_core_time::Id;
    use sq_draw::TextMeasure;
    use sq_draw_shell::MenuController;
    use sq_timeline_ui::{TimelineSideMenus, TrackHeaderMenu};
    use sq_uikit::controls_grid::CGPoint;
    use sq_uikit::sqmenu_model::SQMenuLayout;
    let noop = || -> std::rc::Rc<dyn Fn()> { std::rc::Rc::new(|| {}) };
    for kind in [TrackKind::Video, TrackKind::Audio] {
        let track = Track::new(Id::from_u128(1), kind);
        let items = TimelineSideMenus::track_header(
            &track,
            TrackHeaderMenu {
                add_video: noop(),
                add_audio: noop(),
                delete: noop(),
                rename: noop(),
                move_up: Some(noop()),
                move_down: Some(noop()),
                mix: noop(),
                toggle_ducking: noop(),
                sequence_volume: Some(noop()),
                select_all: Some(noop()),
                toggle: Some(std::rc::Rc::new(|_| {})),
            },
        );
        assert!(items.iter().any(|i| i.title == "Rename…"), "the menu has Rename…");
        for scale in [1.0_f64, 1.25, 1.5, 2.0] {
            for px in [600.0_f64, 720.0, 768.0, 900.0, 1080.0] {
                let height = px / scale;
                for click_y in [height - 47.0, height - 10.0, height * 0.5] {
                    let m = TextMeasure::new(None, scale as f32);
                    let mut c = MenuController::new();
                    c.bounds = CGRect::new(0.0, 0.0, 1280.0 / scale, height);
                    let at = CGPoint::new(120.0, click_y);
                    c.pop_up(items.clone(), CGRect::new(at.x, at.y, 0.0, 0.0), Some(at), &m);
                    let v = &c.views()[0];
                    let content = v.content_size().height;
                    let room = (click_y.max(height - click_y)) - 2.0 * SQMenuLayout::SCREEN_MARGIN;
                    let ctx = format!("{kind:?} scale {scale} window {px} px click {click_y}");
                    if content <= room {
                        assert_eq!(v.visible_size().height, content, "no scrollbar: {ctx}");
                    }
                    let f = v.frame();
                    assert!(f.min_y() >= 0.0 && f.max_y() <= height, "inside the window: {ctx}");
                }
            }
        }
    }
}

/// Through the real host and menus: a click on a disabled row (Paste in an empty project) keeps the Edit menu open.
#[test]
fn a_click_on_a_disabled_menu_row_in_the_host_keeps_the_menu_open() {
    use sq_draw::InputKey;
    use sq_uikit::controls_grid::CGPoint;
    let mut host = ShellHost::new(shell(), None);
    host.inner.platform = sq_os::Platform::Windows;
    let (mut s, mut ui, mut services, mut events) = (session(), UiCx::new(), AppServices::headless(), Vec::new());
    let mut cx =
        HostCx { session: &mut s, ui: &mut ui, services: &mut services, events: &mut events, atlas: None, scale: 1.0 };
    host.sync(cx.session);
    host.layout(CGRect::new(0.0, 0.0, 800.0, 600.0), &mut cx);
    host.handle(&InputEvent::KeyDown { key: InputKey::Character('e'), modifiers: InputModifiers::OPTION }, &mut cx);
    let edit = host.inner.menu_bar.open().expect("Alt+E opens a menu");
    let v = &host.inner.menu_bar.controller.views()[0];
    let row = v.items.iter().position(|i| i.title == "Paste").expect("Edit has Paste");
    assert!(!v.items[row].is_enabled, "Paste is disabled in an empty project");
    let (x, y) = ((v.origin.x + 12.0) as f32, (v.origin.y + v.row_frames[row].mid_y() - v.scroll_offset) as f32);
    assert_eq!(v.index_at(CGPoint::new(f64::from(x), f64::from(y))), Some(row));
    host.handle(&InputEvent::MouseMoved { x, y }, &mut cx);
    host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut cx);
    host.handle(&InputEvent::MouseUp { x, y }, &mut cx);
    assert_eq!(host.inner.menu_bar.open(), Some(edit), "the menu stays open");
}

/// A session with `places` clips on the timeline, one per call, each 20 s after the last.
fn session_with_clips(places: usize) -> EditorSession {
    use sq_core_model::{MediaFingerprint, MediaRef, Project};
    use sq_core_time::{Id, Time};
    use sq_editor_session::PlaceOptions;
    let mut m = MediaRef::new(Id::from_u128(901), "c", "/tmp/sq-menu-cache.mp4", MediaFingerprint::new(1));
    m.duration = Some(Time::seconds(10));
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-menu-cache"));
    deps.ids = Box::new(SequentialIds::default());
    let mut s = EditorSession::new(Project::new(Id::from_u128(2), "demo", vec![m], Vec::new()), deps);
    for i in 0..places {
        let at = Some(Time::seconds(i as i64 * 20));
        s.place_media(&[Id::from_u128(901)], &PlaceOptions { at, ..PlaceOptions::default() });
    }
    s
}

fn undo_row_enabled(menus: &[ShellMenu]) -> Option<bool> {
    let edit = menus.iter().find(|m| m.title == "Edit")?;
    edit.items.iter().find(|i| i.title.starts_with("Undo")).map(|i| i.is_enabled)
}

#[test]
fn an_idle_frame_does_not_build_the_menu_bar_again() {
    let (s, host) = (session_with_clips(5), ShellHost::new(shell(), None));
    assert!(host.inner.refresh_menus(&s, host.hooks.as_ref()).is_some(), "the first frame builds");
    // A hit also rebuilds and compares (`verify_menu_cache`): an input the stamp misses fails here.
    for _ in 0..10 {
        assert!(host.inner.refresh_menus(&s, host.hooks.as_ref()).is_none(), "nothing changed");
    }
    assert_eq!(host.inner.menu_builds(), 1);
}

#[test]
fn a_state_change_shows_in_the_next_menu_bar() {
    let (mut s, host) = (session_with_clips(0), ShellHost::new(shell(), None));
    let first = host.inner.refresh_menus(&s, host.hooks.as_ref()).expect("first build");
    assert_eq!(undo_row_enabled(&first), Some(false), "nothing to undo yet");
    s.place_media(&[sq_core_time::Id::from_u128(901)], &sq_editor_session::PlaceOptions::default());
    let after_edit = host.inner.refresh_menus(&s, host.hooks.as_ref()).expect("an edit builds again");
    assert_eq!(undo_row_enabled(&after_edit), Some(true), "Undo follows the edit");
    while s.can_undo() {
        s.undo();
    }
    let after_undo = host.inner.refresh_menus(&s, host.hooks.as_ref()).expect("an undo builds again");
    assert_eq!(undo_row_enabled(&after_undo), Some(false), "Undo follows the undo");
}

#[test]
fn a_focus_change_builds_the_menu_bar_again() {
    let (s, mut host) = (session_with_clips(1), ShellHost::new(shell(), None));
    host.inner.refresh_menus(&s, host.hooks.as_ref());
    host.inner.focus = Some(sq_uikit::panel_id::PanelID::Project);
    assert!(host.inner.refresh_menus(&s, host.hooks.as_ref()).is_some(), "Cut, Copy and Paste follow the focus");
}
