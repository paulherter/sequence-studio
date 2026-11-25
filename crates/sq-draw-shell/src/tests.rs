//! Ports of the Swift tests of ShellKeys, MenuController, MenuBar, MenuListView, ShellDialog, ShellMenuBar, ShellHost and the
//! keyboard parity suite. Flow tests drive the shell through a `UiRoot` and the manual runtime, answering dialogs step by step.

use super::*;
use sq_core_time::{SequentialIds, Timestamp};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, TextMeasure, UiCx};
use sq_editor_session::{
    EditorSession, ProjectPanelDeps, ProjectPanelModel, ProjectPanelRoot, RecentEntry, RecentProjects, SessionDeps,
    SessionRoot,
};
use sq_os::Platform;
use sq_runtime::testing::Rt;
use sq_runtime::{FakeClock, ModalAsk, UiRef, UiRoot};
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::menu_spec::EditorMenus;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind, SQMenuLayout};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

pub(crate) fn measure() -> TextMeasure<'static> {
    TextMeasure::new(None, 1.0)
}

fn press(k: InputKey, m: InputModifiers) -> InputEvent {
    InputEvent::KeyDown { key: k, modifiers: m }
}

const NONE: InputModifiers = InputModifiers::NONE;

type Ran = Rc<RefCell<Vec<String>>>;

fn row(t: &str, ran: &Ran, sub: Option<Vec<SQMenuItem>>) -> SQMenuItem {
    let mut i = SQMenuItem::new(t);
    match sub {
        Some(s) => i.submenu = Some(s),
        None => {
            let (ran, title) = (Rc::clone(ran), t.to_string());
            i.action = Some(Rc::new(move || ran.borrow_mut().push(title.clone())));
        }
    }
    i
}

fn controller(now: &Rc<Cell<f64>>) -> MenuController {
    let mut c = MenuController::new();
    c.bounds = CGRect::new(0.0, 0.0, 800.0, 600.0);
    let now = Rc::clone(now);
    c.clock = Box::new(move || now.get());
    c
}

// MARK: ShellKeys

mod keys {
    use super::*;

    #[test]
    fn ctrl_s_saves_and_plain_keys_reach_the_timeline_map() {
        let map = CommandMap::premiere_default();
        let cmd = |k, m, f| ShellKeys::command(k, m, f, &map, false);
        assert_eq!(cmd(InputKey::Character('S'), InputModifiers::COMMAND, None), Some(EditorCommand::Save));
        assert_eq!(cmd(InputKey::Space, NONE, None), Some(EditorCommand::PlayPause));
        assert_eq!(cmd(InputKey::Plus, NONE, Some(PanelID::Timeline)), Some(EditorCommand::ZoomIn));
        assert_eq!(
            cmd(InputKey::Minus, InputModifiers::COMMAND, Some(PanelID::Timeline)),
            Some(EditorCommand::VideoTracksShorter)
        );
    }

    /// Space plays and pauses whichever panel was clicked last (a click moves the focus; none may swallow the key).
    #[test]
    fn space_plays_from_every_focused_panel() {
        let map = CommandMap::premiere_default();
        for panel in PanelID::ALL {
            assert_eq!(
                ShellKeys::command(InputKey::Space, NONE, Some(panel), &map, false),
                Some(EditorCommand::PlayPause),
                "focus on {panel:?}"
            );
        }
    }

    #[test]
    fn mac_forward_delete_falls_back_to_delete() {
        let map = CommandMap::premiere_default();
        let del = ShellKeys::command(InputKey::Backspace, NONE, Some(PanelID::Timeline), &map, true);
        assert!(del.is_some());
        assert_eq!(ShellKeys::command(InputKey::Delete, NONE, Some(PanelID::Timeline), &map, true), del);
    }

    #[test]
    fn alt_alone_is_a_tap_but_alt_with_a_key_or_click_is_not() {
        let mut t = AltTap::new();
        let mut taps = Vec::new();
        t.alt_down();
        t.alt_down(); // key repeat
        taps.push(t.alt_up());
        t.alt_down();
        t.other();
        t.alt_down();
        taps.push(t.alt_up()); // Alt+F: a shortcut
        taps.push(t.alt_up()); // a lone key-up (Alt went down before the window had focus)
        t.alt_down();
        taps.push(t.alt_up());
        assert_eq!(taps, vec![true, false, false, true]);
    }

    fn bar_with_menus(m: &TextMeasure) -> MenuBar {
        let ran: Ran = Rc::default();
        let mut bar = MenuBar::new();
        let menus = ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window"]
            .map(|t| ShellMenu::new(t, vec![row("Open", &ran, None)]));
        bar.set_menus(menus.to_vec(), m);
        bar
    }

    fn key(bar: &mut MenuBar, k: InputKey, m: &TextMeasure) -> bool {
        bar.handle(&InputEvent::KeyDown { key: k, modifiers: NONE }, 1.0, m, &mut None)
    }

    #[test]
    fn alt_tap_focuses_the_first_title_and_a_second_tap_lets_go() {
        let m = measure();
        let mut bar = bar_with_menus(&m);
        bar.alt_tapped(&m, &mut None);
        assert_eq!((bar.keyboard_focus(), bar.open()), (Some(0), None));
        bar.alt_tapped(&m, &mut None);
        assert_eq!(bar.keyboard_focus(), None);
    }

    #[test]
    fn f10_does_what_an_alt_tap_does() {
        let m = measure();
        let mut bar = bar_with_menus(&m);
        assert!(key(&mut bar, InputKey::Function(10), &m));
        assert_eq!(bar.keyboard_focus(), Some(0));
        assert!(key(&mut bar, InputKey::Function(10), &m));
        assert_eq!(bar.keyboard_focus(), None);
    }

    #[test]
    fn the_focused_bar_moves_with_arrows_wraps_and_opens_with_down_or_enter() {
        let m = measure();
        let mut bar = bar_with_menus(&m);
        bar.alt_tapped(&m, &mut None);
        key(&mut bar, InputKey::Right, &m);
        key(&mut bar, InputKey::Right, &m);
        assert_eq!(bar.keyboard_focus(), Some(2));
        bar.alt_tapped(&m, &mut None);
        bar.alt_tapped(&m, &mut None);
        key(&mut bar, InputKey::Left, &m);
        assert_eq!(bar.keyboard_focus(), Some(6), "Left from the first title wraps to the last");
        key(&mut bar, InputKey::Enter, &m);
        assert_eq!((bar.open(), bar.keyboard_focus()), (Some(6), None));
        bar.dismiss();
        bar.alt_tapped(&m, &mut None);
        key(&mut bar, InputKey::Down, &m);
        assert_eq!(bar.open(), Some(0));
        assert!(!bar.controller.animates(), "a menu opened by keyboard does not animate");
    }

    #[test]
    fn a_mnemonic_letter_opens_its_menu_and_escape_leaves_the_bar() {
        let m = measure();
        let mut bar = bar_with_menus(&m);
        assert_eq!(bar.mnemonics()[..4], [Some('f'), Some('e'), Some('c'), Some('s')]);
        bar.alt_tapped(&m, &mut None);
        assert!(key(&mut bar, InputKey::Character('w'), &m));
        assert_eq!(bar.open(), Some(6));
        bar.dismiss();
        bar.alt_tapped(&m, &mut None);
        assert!(key(&mut bar, InputKey::Escape, &m));
        assert_eq!((bar.keyboard_focus(), bar.open()), (None, None));
    }

    #[test]
    fn titles_with_the_same_first_letter_get_the_next_free_one() {
        let m = measure();
        let mut bar = MenuBar::new();
        let titles = ["Edit", "Export", "Effects"];
        bar.set_menus(titles.map(|t| ShellMenu::new(t, Vec::new())).to_vec(), &m);
        assert_eq!(bar.mnemonics(), vec![Some('e'), Some('x'), Some('f')]);
    }

    #[test]
    fn a_press_or_another_key_lets_the_bar_go_and_the_system_bar_never_takes_focus() {
        let m = measure();
        let mut bar = bar_with_menus(&m);
        bar.alt_tapped(&m, &mut None);
        assert!(key(&mut bar, InputKey::Backspace, &m), "the bar eats the key that ends its focus");
        assert_eq!(bar.keyboard_focus(), None);
        bar.alt_tapped(&m, &mut None);
        bar.handle(&InputEvent::MouseDown { x: 900.0, y: 900.0, modifiers: NONE }, 1.0, &m, &mut None);
        assert_eq!(bar.keyboard_focus(), None);
        let mut mac = bar_with_menus(&m);
        mac.use_system_bar();
        mac.alt_tapped(&m, &mut None);
        assert_eq!(mac.keyboard_focus(), None);
        assert!(!key(&mut mac, InputKey::Function(10), &m));
    }

    #[test]
    fn a_menu_opened_by_the_keyboard_does_not_animate_but_a_click_does() {
        let ran: Ran = Rc::default();
        let m = measure();
        let mut bar = MenuBar::new();
        bar.set_menus(vec![ShellMenu::new("File", vec![row("Open", &ran, None)])], &m);
        bar.open_menu(0, None, true, &m, &mut None);
        assert!(!bar.controller.animates());
        bar.dismiss();
        bar.open_menu(0, Some(CGPoint::new(5.0, 5.0)), false, &m, &mut None);
        assert!(bar.controller.animates());
    }

    #[test]
    fn backspace_is_the_mac_delete_and_escape_stays_with_the_host() {
        use sq_uikit::key_binding::Key;
        assert_eq!(ShellKeys::key(InputKey::Backspace), Some(Key::Delete));
        assert_eq!(ShellKeys::key(InputKey::Delete), Some(Key::ForwardDelete));
        assert_eq!(ShellKeys::key(InputKey::Escape), None);
    }

    #[test]
    fn page_and_function_keys_reach_the_map() {
        use sq_uikit::key_binding::Key;
        assert_eq!(ShellKeys::key(InputKey::PageUp), Some(Key::PageUp));
        assert_eq!(ShellKeys::key(InputKey::PageDown), Some(Key::PageDown));
        assert_eq!(ShellKeys::key(InputKey::Function(5)), Some(Key::Function(5)));
        assert_eq!(ShellKeys::key(InputKey::Character('\t')), Some(Key::Char('\t')));
    }

    #[test]
    fn window_title_marks_unsaved_changes() {
        assert_eq!(ShellWindowTitle::text(Some("Film"), true), "*Film - Sequence Studio");
        assert_eq!(ShellWindowTitle::text(Some("Film"), false), "Film - Sequence Studio");
        assert_eq!(ShellWindowTitle::text(None, false), "Sequence Studio");
    }
}

// MARK: MenuController, MenuBar, MenuListView

mod menus {
    use super::*;

    #[test]
    fn opens_at_the_point_and_keys_run_the_row() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        c.present(
            vec![row("Cut", &ran, None), row("Copy", &ran, None)],
            CGPoint::new(100.0, 50.0),
            None,
            None,
            None,
            &m,
        );
        assert_eq!(c.views()[0].origin, CGPoint::new(100.0, 50.0));
        assert!(c.handle(&press(InputKey::Down, NONE), 1.0, &m));
        assert!(c.handle(&press(InputKey::Down, NONE), 1.0, &m));
        c.handle(&press(InputKey::Enter, NONE), 1.0, &m);
        assert_eq!(*ran.borrow(), vec!["Copy"]);
        assert!(!c.is_open());
    }

    /// Down, Up, Home and End jump over disabled rows, and Enter never runs one.
    #[test]
    fn keyboard_navigation_skips_disabled_rows() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        let mut off = row("Off", &ran, None);
        off.is_enabled = false;
        let mut last_off = row("Last", &ran, None);
        last_off.is_enabled = false;
        c.present(
            vec![row("A", &ran, None), off, row("B", &ran, None), last_off],
            CGPoint::new(100.0, 50.0),
            None,
            None,
            None,
            &m,
        );
        for k in [InputKey::Down, InputKey::Down] {
            c.handle(&press(k, NONE), 1.0, &m);
        }
        c.handle(&press(InputKey::Up, NONE), 1.0, &m);
        c.handle(&press(InputKey::Down, NONE), 1.0, &m);
        c.handle(&press(InputKey::End, NONE), 1.0, &m);
        c.handle(&press(InputKey::Enter, NONE), 1.0, &m);
        assert_eq!(*ran.borrow(), vec!["B"], "Off and Last are never highlighted or run");
    }

    /// A click (press + release) and a quick tap on a disabled row do nothing and keep the menu open: a context menu at a
    /// point, a popup under a control, with the press landing first or the release alone.
    #[test]
    fn a_disabled_row_in_a_context_menu_or_popup_ignores_the_click() {
        let (now, m) = (Rc::new(Cell::new(10.0)), measure());
        for from_control in [false, true] {
            let ran = Ran::default();
            let mut c = controller(&now);
            let mut paste = row("Paste", &ran, None);
            paste.is_enabled = false;
            let items = vec![row("Cut", &ran, None), paste];
            if from_control {
                c.pop_up(items, CGRect::new(100.0, 40.0, 80.0, 22.0), None, &m);
            } else {
                c.present(items, CGPoint::new(100.0, 50.0), None, None, None, &m);
            }
            let v = &c.views()[0];
            let r = v.row_frames[1];
            let (x, y) = ((v.origin.x + 12.0) as f32, (v.origin.y + r.mid_y() - v.scroll_offset) as f32);
            assert_eq!(v.index_at(CGPoint::new(f64::from(x), f64::from(y))), Some(1));
            now.set(now.get() + 1.0);
            c.handle(&InputEvent::MouseDown { x, y, modifiers: NONE }, 1.0, &m);
            c.handle(&InputEvent::MouseUp { x, y }, 1.0, &m);
            assert!(c.is_open(), "press and release on a disabled row (control: {from_control})");
            // A release alone (the opening press and drag ended on the row) after the grace time.
            now.set(now.get() + 1.0);
            c.handle(&InputEvent::MouseUp { x: x + 1.0, y }, 1.0, &m);
            assert!(c.is_open(), "a release on a disabled row (control: {from_control})");
            assert!(ran.borrow().is_empty(), "nothing ran");
        }
    }

    #[test]
    fn flips_above_when_no_room_below() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        c.pop_up(
            vec![row("A", &ran, None), row("B", &ran, None), row("C", &ran, None)],
            CGRect::new(10.0, 560.0, 80.0, 22.0),
            None,
            &m,
        );
        assert!(c.views()[0].frame().max_y() <= 560.0);
    }

    #[test]
    fn hover_opens_submenu_right_of_parent_at_the_row() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        c.present(
            vec![row("A", &ran, None), row("More", &ran, Some(vec![row("X", &ran, None)]))],
            CGPoint::new(100.0, 50.0),
            None,
            None,
            None,
            &m,
        );
        let r = c.views()[0].row_frames[1];
        let o = c.views()[0].origin;
        c.handle(&InputEvent::MouseMoved { x: (o.x + r.mid_x()) as f32, y: (o.y + r.mid_y()) as f32 }, 1.0, &m);
        assert_eq!(c.depth(), 2);
        assert_eq!(c.views()[1].origin.x, c.views()[0].frame().max_x() - SQMenuLayout::SUBMENU_OVERLAP);
        assert_eq!(c.views()[1].origin.y, c.views()[0].origin.y + r.min_y() - SQMenuLayout::INSET);
    }

    #[test]
    fn opening_click_release_never_selects_but_a_press_in_the_list_does() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        c.present(
            vec![row("Cut", &ran, None)],
            CGPoint::new(100.0, 50.0),
            None,
            None,
            Some(CGPoint::new(100.0, 50.0)),
            &m,
        );
        let r = c.views()[0].row_frames[0];
        let (x, y) = ((100.0 + r.mid_x()) as f32, (50.0 + r.mid_y()) as f32);
        c.handle(&InputEvent::MouseUp { x, y }, 1.0, &m); // release of the opening click, no delay
        assert!(ran.borrow().is_empty() && c.is_open());
        now.set(now.get() + 1.0);
        c.handle(&InputEvent::MouseDown { x, y, modifiers: NONE }, 1.0, &m);
        c.handle(&InputEvent::MouseUp { x, y }, 1.0, &m);
        assert_eq!(*ran.borrow(), vec!["Cut"]);
    }

    #[test]
    fn press_outside_closes_and_passes_through() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        c.present(vec![row("Cut", &ran, None)], CGPoint::new(100.0, 50.0), None, None, None, &m);
        assert!(!c.handle(&InputEvent::MouseDown { x: 700.0, y: 500.0, modifiers: NONE }, 1.0, &m));
        assert!(!c.is_open());
    }

    /// Every kind of opener the app has: a pull-down below a rect, a button reporting only a placement point (timeline
    /// header, monitor and meter menus), and a plain `present`. A second press on the opener closes the menu and the
    /// host's reopen request for the same click is ignored; a later click and another opener still open.
    #[test]
    fn a_second_click_on_the_opener_closes_it_for_every_kind_of_opener() {
        let m = measure();
        type Open = fn(&mut MenuController, &Ran, &TextMeasure);
        let openers: [(&str, Open); 3] = [
            ("pull-down below a rect", |c, ran, m| {
                c.pop_up(vec![row("A", ran, None)], CGRect::new(300.0, 100.0, 80.0, 22.0), None, m);
            }),
            ("point only (zero rect)", |c, ran, m| {
                let at = CGPoint::new(300.0, 122.0);
                c.pop_up(vec![row("A", ran, None)], CGRect::new(at.x, at.y, 0.0, 0.0), Some(at), m);
            }),
            ("plain present", |c, ran, m| {
                c.present(vec![row("A", ran, None)], CGPoint::new(300.0, 122.0), None, None, None, m);
            }),
        ];
        for (name, open) in openers {
            let (ran, now) = (Ran::default(), Rc::new(Cell::new(10.0)));
            let mut c = controller(&now);
            open(&mut c, &ran, &m);
            assert!(c.is_open(), "{name}: opens");
            now.set(now.get() + 1.0);
            // The second click on the opener: press and release over the button, the host asks for the menu again.
            let down = InputEvent::MouseDown { x: 340.0, y: 110.0, modifiers: NONE };
            c.handle(&down, 1.0, &m);
            open(&mut c, &ran, &m);
            c.handle(&InputEvent::MouseUp { x: 340.0, y: 110.0 }, 1.0, &m);
            assert!(!c.is_open(), "{name}: the second click closes it and does not reopen it");
            // A later deliberate click opens it again.
            now.set(now.get() + 1.0);
            open(&mut c, &ran, &m);
            assert!(c.is_open(), "{name}: opens again after the guard time");
        }
        // Another opener right after a closing press still opens (switching from one menu to the next).
        let (ran, now) = (Ran::default(), Rc::new(Cell::new(10.0)));
        let mut c = controller(&now);
        c.present(vec![row("A", &ran, None)], CGPoint::new(300.0, 122.0), None, None, None, &m);
        c.handle(&InputEvent::MouseDown { x: 600.0, y: 110.0, modifiers: NONE }, 1.0, &m);
        c.present(vec![row("B", &ran, None)], CGPoint::new(560.0, 122.0), None, None, None, &m);
        assert!(c.is_open(), "a different opener opens its own menu");
    }

    #[test]
    fn typing_filters_and_escape_clears_first() {
        let (ran, now, m) = (Ran::default(), Rc::new(Cell::new(10.0)), measure());
        let mut c = controller(&now);
        c.present(
            vec![row("Cut", &ran, None), row("Copy", &ran, None), row("Paste", &ran, None)],
            CGPoint::ZERO,
            None,
            None,
            None,
            &m,
        );
        c.handle(&press(InputKey::Character('p'), NONE), 1.0, &m);
        let titles: Vec<&str> = c.views()[0].items.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles, vec!["Copy", "Paste"]);
        c.handle(&press(InputKey::Escape, NONE), 1.0, &m);
        assert!(c.is_open() && c.views()[0].items.len() == 3);
        c.handle(&press(InputKey::Escape, NONE), 1.0, &m);
        assert!(!c.is_open());
    }

    #[test]
    fn click_opens_below_the_title_and_hover_switches() {
        let (ran, m) = (Ran::default(), measure());
        let mut bar = MenuBar::new();
        bar.controller.bounds = CGRect::new(0.0, 0.0, 800.0, 600.0);
        bar.set_menus(
            vec![
                ShellMenu::new("File", vec![row("New", &ran, None)]),
                ShellMenu::new("Edit", vec![row("Undo", &ran, None)]),
            ],
            &m,
        );
        let f = bar.title_frames().to_vec();
        let mut none = None;
        assert!(bar.handle(
            &InputEvent::MouseDown { x: f[0].mid_x() as f32, y: 10.0, modifiers: NONE },
            1.0,
            &m,
            &mut none
        ));
        assert_eq!(bar.open(), Some(0));
        assert_eq!(bar.controller.views()[0].origin.y, MenuBar::DEFAULT_HEIGHT);
        bar.handle(&InputEvent::MouseMoved { x: f[1].mid_x() as f32, y: 10.0 }, 1.0, &m, &mut none);
        assert_eq!(bar.open(), Some(1));
        bar.handle(&press(InputKey::Left, NONE), 1.0, &m, &mut none);
        assert_eq!(bar.open(), Some(0));
        bar.handle(&press(InputKey::Escape, NONE), 1.0, &m, &mut none);
        assert_eq!(bar.open(), None);
    }

    /// A press and release on a disabled row does nothing and the menu stays open (bar menus; the same controller serves
    /// context menus and popups).
    #[test]
    fn a_click_on_a_disabled_row_keeps_the_menu_open() {
        let (ran, m) = (Ran::default(), measure());
        let mut bar = MenuBar::new();
        bar.controller.bounds = CGRect::new(0.0, 0.0, 800.0, 600.0);
        let mut paste = row("Paste", &ran, None);
        paste.is_enabled = false;
        bar.set_menus(vec![ShellMenu::new("Edit", vec![row("Undo", &ran, None), paste])], &m);
        let mut none = None;
        let x = bar.title_frames()[0].mid_x() as f32;
        bar.handle(&InputEvent::MouseDown { x, y: 10.0, modifiers: NONE }, 1.0, &m, &mut none);
        bar.handle(&InputEvent::MouseUp { x, y: 10.0 }, 1.0, &m, &mut none);
        assert_eq!(bar.open(), Some(0));
        let v = &bar.controller.views()[0];
        let px = v.origin.x as f32 + 10.0;
        let py = (0..600).map(|y| y as f32).find(|y| v.index_at(CGPoint::new(f64::from(px), f64::from(*y))) == Some(1));
        let py = py.expect("the disabled row has a frame");
        bar.handle(&InputEvent::MouseMoved { x: px, y: py }, 1.0, &m, &mut none);
        bar.handle(&InputEvent::MouseDown { x: px, y: py, modifiers: NONE }, 1.0, &m, &mut none);
        bar.handle(&InputEvent::MouseUp { x: px, y: py }, 1.0, &m, &mut none);
        assert_eq!(bar.open(), Some(0), "the menu stays open");
        assert!(ran.borrow().is_empty(), "nothing ran");
    }

    #[test]
    fn the_bar_rebuilds_its_menus_right_before_one_opens() {
        let (ran, m) = (Ran::default(), measure());
        let mut bar = MenuBar::new();
        bar.set_menus(vec![ShellMenu::new("File", vec![row("Old", &ran, None)])], &m);
        let x = bar.title_frames()[0].mid_x() as f32;
        let mut fresh = || vec![ShellMenu::new("File", vec![row("New", &ran, None)])];
        bar.handle(&InputEvent::MouseDown { x, y: 10.0, modifiers: NONE }, 1.0, &m, &mut Some(&mut fresh));
        assert_eq!(bar.controller.views()[0].items[0].title, "New");
    }

    /// The Mac shows the shared menus in the system menu bar: the in-window bar then lays out, draws and takes no titles,
    /// while its controller still opens the bar's popups (the Workspace popup).
    #[test]
    fn hidden_titles_take_no_room_and_no_clicks() {
        let (ran, m) = (Ran::default(), measure());
        let mut bar = MenuBar::new();
        bar.set_menus(
            vec![
                ShellMenu::new("File", vec![row("Save", &ran, None)]),
                ShellMenu::new("Edit", vec![row("Undo", &ran, None)]),
            ],
            &m,
        );
        assert_eq!(bar.title_frames().len(), 2);
        bar.set_shows_titles(false, &m);
        assert!(bar.title_frames().is_empty());
        assert!(!bar.handle(&InputEvent::MouseDown { x: 20.0, y: 10.0, modifiers: NONE }, 1.0, &m, &mut None));
        bar.draws_background = false;
        let mut c = Canvas::with_size(800.0, 600.0, None, 1.0);
        bar.draw(&mut c, &DrawTheme::default(), 800.0);
        assert!(c.list.quads().is_empty());
        bar.set_shows_titles(true, &m);
        assert_eq!(bar.title_frames().len(), 2);
    }

    /// A narrow window (Windows): the titles that do not fit fold into one "»" title whose menu holds them as submenus.
    #[test]
    fn titles_past_the_width_fold_into_an_overflow_menu() {
        let (ran, m) = (Ran::default(), measure());
        let mut bar = MenuBar::new();
        let names = ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window", "Help"];
        bar.set_menus(
            names.iter().map(|n| ShellMenu::new(n, vec![row(&format!("{n} row"), &ran, None)])).collect(),
            &m,
        );
        let full = bar.title_frames().last().map_or(0.0, |r| r.max_x());
        assert!(bar.overflow_frame().is_none());
        bar.set_max_width(Some(full - 60.0), &m);
        let shown = bar.title_frames().len();
        assert!(shown < 8 && shown > 0);
        let more = bar.overflow_frame();
        assert!(more.is_some_and(|r| r.min_x() >= bar.title_frames()[shown - 1].max_x() && r.max_x() <= full - 60.0));
        let more = more.unwrap_or_default();
        assert!(bar.handle(
            &InputEvent::MouseDown { x: more.mid_x() as f32, y: more.mid_y() as f32, modifiers: NONE },
            1.0,
            &m,
            &mut None
        ));
        let items = bar.controller.views()[0].items.clone();
        let folded: Vec<String> = bar.menus()[shown..].iter().map(|x| x.title.clone()).collect();
        assert_eq!(items.iter().map(|i| i.title.clone()).collect::<Vec<_>>(), folded);
        assert_eq!(
            items[0].submenu.as_ref().map(|s| s[0].title.clone()),
            Some(format!("{} row", bar.menus()[shown].title))
        );
        bar.dismiss();
        bar.set_max_width(None, &m);
        assert!(bar.title_frames().len() == 8 && bar.overflow_frame().is_none());
        bar.set_max_width(Some(1.0), &m); // nothing fits: only the overflow title
        assert!(bar.title_frames().is_empty() && bar.overflow_frame().is_some());
    }

    /// The room limit (Export button, start search field) folds titles like `set_max_width`; the smaller limit wins and no
    /// title frame ever reaches past it.
    #[test]
    fn the_room_limit_folds_titles_and_the_smaller_limit_wins() {
        let (ran, m) = (Ran::default(), measure());
        let mut bar = MenuBar::new();
        let names = ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window", "Help"];
        bar.set_menus(names.iter().map(|n| ShellMenu::new(n, vec![row("r", &ran, None)])).collect(), &m);
        let full = bar.natural_right(&m);
        assert_eq!(bar.title_frames().last().map(|r| r.max_x()), Some(full));
        for limit in [full - 1.0, full * 0.7, full * 0.3, 1.0] {
            bar.set_room_limit(Some(limit), &m);
            let end = bar.overflow_frame().or_else(|| bar.title_frames().last().copied()).map_or(0.0, |r| r.max_x());
            assert!(end <= limit.max(MenuBar::FIRST_TITLE_X + 30.0), "{limit}: ends at {end}");
            assert!(bar.overflow_frame().is_some(), "{limit}: something folded");
        }
        bar.set_room_limit(Some(full * 0.7), &m);
        let n = bar.title_frames().len();
        bar.set_max_width(Some(full * 0.3), &m);
        assert!(bar.title_frames().len() < n, "the smaller max width wins");
        bar.set_max_width(None, &m);
        bar.set_room_limit(None, &m);
        assert!(bar.overflow_frame().is_none() && bar.title_frames().len() == 8);
    }

    #[test]
    fn rows_stack_from_the_inset_with_menu_heights() {
        let m = measure();
        let mut v = MenuListView::new(vec![
            SQMenuItem::new("Cut"),
            SQMenuItem::separator(),
            SQMenuItem::header("Clips"),
            SQMenuItem::new("Paste"),
        ]);
        v.relayout(&m);
        let i = SQMenuLayout::INSET;
        let ys: Vec<f64> = v.row_frames.iter().map(|r| r.min_y()).collect();
        assert_eq!(ys, vec![i, i + 24.0, i + 33.0, i + 33.0 + SQMenuLayout::HEADER_HEIGHT]);
        assert_eq!(v.content_size().height, i + 33.0 + SQMenuLayout::HEADER_HEIGHT + 24.0 + i);
        assert!(v.width >= SQMenuLayout::MIN_WIDTH);
    }

    #[test]
    fn max_height_scrolls_and_reveal_shows_the_row() {
        let m = measure();
        let i = SQMenuLayout::INSET;
        let mut v = MenuListView::new((0..20).map(|n| SQMenuItem::new(&format!("Row {n}"))).collect());
        v.max_height = Some(100.0);
        v.relayout(&m);
        assert_eq!(v.visible_size().height, 100.0);
        v.reveal(10);
        assert_eq!(v.scroll_offset, v.row_frames[10].max_y() + i - 100.0);
        let p = CGPoint::new(20.0, 95.0);
        let expected = v.row_frames.iter().position(|r| r.contains(CGPoint::new(20.0, 95.0 + v.scroll_offset)));
        assert_eq!(v.index_at(p), expected);
        v.scroll(10_000.0);
        assert_eq!(v.scroll_offset, v.max_scroll());
    }

    #[test]
    fn a_cut_menu_shows_an_arrow_on_each_edge_that_hides_rows() {
        let m = measure();
        let items: Vec<SQMenuItem> = (0..20).map(|i| SQMenuItem::new(&format!("Item {i}"))).collect();
        let mut v = MenuListView::new(items);
        v.max_height = Some(120.0);
        v.relayout(&m);
        let quads = |v: &MenuListView| {
            let mut c = Canvas::with_size(400.0, 300.0, None, 2.0);
            v.draw(&mut c, &DrawTheme::default());
            c.list.quads().len()
        };
        assert_eq!(v.scroll_hints(), (false, true));
        let top = quads(&v);
        v.scroll(50.0);
        assert_eq!(v.scroll_hints(), (true, true));
        assert!(quads(&v) > top, "the second hidden edge gets its own arrow strip");
        v.scroll(10_000.0);
        assert_eq!(v.scroll_hints(), (true, false));
        let mut whole = MenuListView::new(vec![SQMenuItem::new("Cut")]);
        whole.relayout(&m);
        assert_eq!(whole.scroll_hints(), (false, false));
    }

    #[test]
    fn filter_row_pushes_rows_down() {
        let m = measure();
        let mut v = MenuListView::new(vec![SQMenuItem::new("Cut")]);
        v.filter = "cu".to_string();
        v.relayout(&m);
        assert!(v.filter_frame.is_some());
        assert_eq!(v.row_frames[0].min_y(), SQMenuLayout::INSET + 24.0 + 9.0);
    }

    #[test]
    fn draw_paints_panel_highlight_and_clips() {
        let m = measure();
        let mut v = MenuListView::new(vec![SQMenuItem::new("Cut"), SQMenuItem::new("Copy")]);
        v.highlighted = Some(1);
        v.relayout(&m);
        let mut c = Canvas::with_size(400.0, 300.0, None, 2.0);
        v.draw(&mut c, &DrawTheme::default());
        assert!(c.list.quads().len() > 3);
    }

    #[test]
    fn a_disabled_row_does_not_highlight() {
        let m = measure();
        let quads = |enabled: bool, highlighted: Option<usize>| {
            let mut item = SQMenuItem::new("Paste");
            item.is_enabled = enabled;
            let mut v = MenuListView::new(vec![item]);
            v.highlighted = highlighted;
            v.relayout(&m);
            let mut c = Canvas::with_size(400.0, 300.0, None, 2.0);
            v.draw(&mut c, &DrawTheme::default());
            c.list.quads().len()
        };
        assert_eq!(quads(false, Some(0)), quads(false, None));
        assert!(quads(true, Some(0)) > quads(true, None));
    }

    #[test]
    fn a_long_row_never_widens_the_menu_past_its_cap_and_keeps_its_tip() {
        let m = measure();
        let long = format!("{}.mov", "Interview ".repeat(30));
        let mut v = MenuListView::new(vec![SQMenuItem::new(&long), SQMenuItem::new("Cut")]);
        v.max_width = Some(300.0);
        v.relayout(&m);
        assert!(v.width <= 300.0, "{}", v.width);
        assert_eq!(v.title_tip(0, &m).as_deref(), Some(long.as_str()));
        assert_eq!(v.title_tip(1, &m), None);
        // Without a cap the same row makes the menu wider than the cap.
        let mut free = MenuListView::new(vec![SQMenuItem::new(&long)]);
        free.relayout(&m);
        assert!(free.width > 300.0);
    }
}

// MARK: ShellDialog

mod dialog {
    use super::*;

    const WINDOW: CGRect = CGRect::new(0.0, 0.0, 1000.0, 800.0);

    #[test]
    fn footer_order_and_centered_card() {
        let mut d = ShellDialog::new("Save changes?", "");
        d.add_button("Save", SQDialogRole::Save, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.add_button("Don't Save", SQDialogRole::DontSave, false);
        d.layout(WINDOW, &measure());
        let f = d.button_frames();
        assert_eq!(d.card().mid_x(), 500.0);
        assert_eq!(f[&2].min_x(), d.card().min_x() + 20.0); // Don't Save alone on the left (kit card padding 20)
        assert_eq!(f[&0].max_x(), d.card().max_x() - 20.0); // Save, the main action, rightmost
        assert_eq!(f[&1].max_x(), f[&0].min_x() - 8.0);
    }

    #[test]
    fn keys_answer_with_the_model_roles() {
        let got: Rc<RefCell<Vec<SQDialogResponse>>> = Rc::default();
        let mut d = ShellDialog::new("Delete?", "");
        d.add_button("Delete", SQDialogRole::Destructive, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        let g = Rc::clone(&got);
        d.completion = Some(Box::new(move |r| g.borrow_mut().push(r)));
        d.layout(WINDOW, &measure());
        // Destructive: Return presses Cancel.
        assert_eq!(d.response(InputKey::Enter, NONE), Some(SQDialogResponse::SECOND));
        assert_eq!(d.response(InputKey::Character('.'), InputModifiers::COMMAND), Some(SQDialogResponse::SECOND));
        d.handle(&press(InputKey::Escape, NONE), 1.0, &measure(), &mut UiCx::new());
        assert_eq!(*got.borrow(), vec![SQDialogResponse::SECOND]);
    }

    #[test]
    fn a_dialog_opens_on_its_first_number_field_even_below_a_popup() {
        use crate::shell_form::{NumberField, Row, ShellForm};
        let number = NumberField {
            id: "n".into(),
            value: 5.0,
            range: 0.0..=100.0,
            step: 1.0,
            decimals: 0,
            unit: String::new(),
            default_value: None,
        };
        let rows = vec![
            Row::Popup { id: "p".into(), label: "Pick".into(), options: vec!["A".into(), "B".into()], selected: 0 },
            Row::Number { label: "Amount".into(), field: number },
        ];
        let mut d = ShellDialog::new("Amount", "");
        d.form = Some(Box::new(ShellForm::new(rows)));
        let tm = measure();
        d.layout(WINDOW, &tm);
        assert_eq!(d.focused(), None, "the form owns the focus, not a button");
        assert_eq!(d.form.as_ref().and_then(|f| f.focused()), Some(1));
        let mut cx = UiCx::new();
        d.handle(&press(InputKey::Character('7'), NONE), 1.0, &tm, &mut cx);
        d.handle(&press(InputKey::Enter, NONE), 1.0, &tm, &mut cx);
        assert_eq!(d.form.as_ref().and_then(|f| f.number("n")), Some(7.0));
    }

    #[test]
    fn a_form_that_fits_does_not_scroll() {
        // Swift `aFormThatFitsDoesNotScroll`.
        let mut d = ShellDialog::new("New Project", "");
        d.form = Some(Box::new(crate::shell_form::ShellForm::new(vec![crate::shell_form::Row::check("a", "A", true)])));
        d.layout(WINDOW, &measure());
        assert!(!d.form_scrolls());
        d.scroll_form(50.0, &measure());
        assert_eq!(d.form_scroll(), 0.0);
    }

    #[test]
    fn click_on_a_button_presses_it() {
        let got: Rc<RefCell<Vec<SQDialogResponse>>> = Rc::default();
        let mut d = ShellDialog::new("Info", "");
        let g = Rc::clone(&got);
        d.completion = Some(Box::new(move |r| g.borrow_mut().push(r)));
        d.layout(WINDOW, &measure());
        let r = d.button_frames()[&0];
        let (x, y) = (r.mid_x() as f32, r.mid_y() as f32);
        let mut ui = UiCx::new();
        d.handle(&InputEvent::MouseDown { x, y, modifiers: NONE }, 1.0, &measure(), &mut ui);
        d.handle(&InputEvent::MouseUp { x, y }, 1.0, &measure(), &mut ui);
        assert_eq!(*got.borrow(), vec![SQDialogResponse::FIRST]);
    }

    #[test]
    fn a_click_on_welcome_skip_answers_cancel() {
        let got: Rc<RefCell<Vec<SQDialogResponse>>> = Rc::default();
        let mut d = ShellHost::welcome_dialog();
        let g = Rc::clone(&got);
        d.completion = Some(Box::new(move |r| g.borrow_mut().push(r)));
        d.layout(WINDOW, &measure());
        let skip = d.model.buttons.iter().position(|b| b.title == "Skip").expect("a Skip button");
        let r = d.button_frames()[&skip];
        let (x, y) = (r.mid_x() as f32, r.mid_y() as f32);
        let mut ui = UiCx::new();
        d.handle(&InputEvent::MouseDown { x, y, modifiers: NONE }, 1.0, &measure(), &mut ui);
        d.handle(&InputEvent::MouseUp { x, y }, 1.0, &measure(), &mut ui);
        assert_eq!(*got.borrow(), vec![SQDialogResponse::SECOND]);
    }

    #[test]
    fn a_disabled_button_does_not_answer() {
        let got: Rc<RefCell<Vec<SQDialogResponse>>> = Rc::default();
        let mut d = ShellDialog::new("Info", "");
        d.add_button("Go", SQDialogRole::Default, false);
        d.button_enabled = Some(Box::new(|_| false));
        let g = Rc::clone(&got);
        d.completion = Some(Box::new(move |r| g.borrow_mut().push(r)));
        d.press(SQDialogResponse::FIRST);
        assert!(got.borrow().is_empty() && !d.finished());
    }
}

// MARK: ShellMenuBar

mod main_menu {
    use super::*;

    fn menus(s: &ShellMenuState, platform: Platform, log: &Rc<RefCell<Vec<ShellAction>>>) -> Vec<ShellMenu> {
        let log = Rc::clone(log);
        ShellMenuBar::build(
            s,
            &CommandMap::premiere_default(),
            platform,
            None,
            Rc::new(move |a| log.borrow_mut().push(a)),
        )
    }

    fn plain(platform: Platform) -> Vec<ShellMenu> {
        menus(&ShellMenuState::default(), platform, &Rc::default())
    }

    fn menu(m: &[ShellMenu], t: &str) -> Vec<SQMenuItem> {
        m.iter().find(|x| x.title == t).map(|x| x.items.clone()).unwrap_or_default()
    }

    fn dump(items: &[SQMenuItem], ind: usize, out: &mut String) {
        for i in items {
            if i.kind == SQMenuItemKind::Separator {
                out.push_str(&format!("{}---\n", " ".repeat(ind)));
                continue;
            }
            out.push_str(&format!(
                "{}{} | {}{}{}\n",
                " ".repeat(ind),
                i.title,
                i.shortcut,
                if i.is_enabled { "" } else { " |D" },
                if i.is_checked { " |CHK" } else { "" }
            ));
            if let Some(s) = &i.submenu {
                dump(s, ind + 3, out);
            }
        }
    }

    #[test]
    #[ignore = "dump"]
    fn zz_dump_menus() {
        let mut out = String::new();
        for m in plain(Platform::Mac) {
            out.push_str(&format!("## {}\n", m.title));
            dump(&m.items, 1, &mut out);
        }
        std::fs::write(std::env::temp_dir().join("sq-menu-dump.txt"), out).unwrap();
    }

    #[test]
    fn the_drawn_bar_folds_the_app_menu_into_file_and_ends_it_with_exit() {
        let merged = MenuBar::merge_app_menu(plain(Platform::Windows));
        let titles: Vec<&str> = merged.iter().map(|x| x.title.as_str()).collect();
        assert_eq!(titles.first(), Some(&"File"));
        assert!(!titles.contains(&"Sequence Studio"));
        let file = menu(&merged, "File");
        let tail: Vec<&str> = file.iter().rev().take(6).map(|i| i.title.as_str()).collect();
        assert_eq!(tail, ["Exit", "", "Keyboard Shortcuts…", "Settings…", "About Sequence Studio", ""]);
        // Already merged (or Mac-only lists without File after the app menu) stay as they are.
        assert_eq!(MenuBar::merge_app_menu(merged.clone()).len(), merged.len());
    }

    #[test]
    fn bar_order_is_app_then_editor_menus_then_help() {
        let m = plain(Platform::Mac);
        assert_eq!(m.first().map(|x| x.title.as_str()), Some("Sequence Studio"));
        assert_eq!(m.last().map(|x| x.title.as_str()), Some("Help"));
        let middle: Vec<&str> = m[1..m.len() - 1].iter().map(|x| x.title.as_str()).collect();
        let specs: Vec<&str> = EditorMenus::visible().iter().map(|x| x.title.as_str()).collect();
        assert_eq!(middle, specs);
    }

    /// Windows shows the Mac menu model: same menus, rows, order and enabled state; a shortcut is spelled with Ctrl/Alt/Shift
    /// (no Mac glyphs) exactly where the Mac row has one. Only the app menu differs (Hide rows, Quit vs Exit).
    #[test]
    fn windows_menus_are_the_mac_menus_with_ctrl_shortcuts() {
        let glyphs = "\u{2318}\u{2325}\u{21E7}\u{2303}";
        // Window system rows: Zoom is Maximize on Windows; Bring All to Front and the window list are Mac-only.
        fn tidied(items: &[SQMenuItem]) -> Vec<SQMenuItem> {
            ShellMenuBar::tidy(
                items
                    .iter()
                    .filter(|i| i.title != "Bring All to Front")
                    .map(|i| {
                        let mut i = i.clone();
                        if i.title == "Maximize" {
                            i.title = "Zoom".to_string();
                        }
                        i
                    })
                    .collect(),
            )
        }
        fn compare(mac: &[SQMenuItem], win: &[SQMenuItem], path: &str, glyphs: &str) {
            let (mac, win) = (tidied(mac), tidied(win));
            let titles = |v: &[SQMenuItem]| v.iter().map(|i| i.title.clone()).collect::<Vec<_>>();
            assert_eq!(titles(&mac), titles(&win), "rows of {path}");
            for (m, w) in mac.iter().zip(win.iter()) {
                assert!(
                    m.kind == w.kind && m.is_enabled == w.is_enabled && m.is_checked == w.is_checked,
                    "{path} > {}",
                    m.title
                );
                // Save Checkpoint is Ctrl+Cmd+S on the Mac and menu only on Windows (Ctrl+Ctrl+S would read Ctrl+S, Save).
                // A command whose chord Windows cannot press as that command (a Control binding with a bound Ctrl twin)
                // shows no key there: the key map says which.
                if m.title != "Save Checkpoint…" {
                    let pc = CommandMap::sq_default_for(Platform::Windows);
                    let hidden_on_windows = pc
                        .entries
                        .iter()
                        .any(|e| e.command.title() == m.title && !pc.is_pressable_on(e, Platform::Windows));
                    assert!(
                        m.shortcut.is_empty() == w.shortcut.is_empty() || (w.shortcut.is_empty() && hidden_on_windows),
                        "shortcut presence of {path} > {}",
                        m.title
                    );
                }
                assert!(
                    !w.shortcut.chars().any(|c| glyphs.contains(c)),
                    "Mac glyph in {path} > {}: {}",
                    m.title,
                    w.shortcut
                );
                compare(
                    m.submenu.as_deref().unwrap_or(&[]),
                    w.submenu.as_deref().unwrap_or(&[]),
                    &format!("{path} > {}", m.title),
                    glyphs,
                );
            }
        }
        let (mac, win) = (plain(Platform::Mac), plain(Platform::Windows));
        let titles = |v: &[ShellMenu]| v.iter().map(|m| m.title.clone()).collect::<Vec<_>>();
        assert_eq!(titles(&mac), titles(&win));
        for (m, w) in mac.iter().zip(win.iter()).skip(1) {
            compare(&m.items, &w.items, &m.title, glyphs);
        }
        assert!(win.iter().flat_map(|m| m.items.iter()).any(|i| i.shortcut == "Ctrl+Z"));
    }

    #[test]
    fn linux_app_menu_ends_with_exit_ctrl_q() {
        let app = plain(Platform::Linux)[0].items.clone();
        assert_eq!(app.last().map(|i| (i.title.as_str(), i.shortcut.as_str())), Some(("Exit", "Ctrl+Q")));
    }

    #[test]
    fn windows_app_menu_ends_with_exit_alt_f4_and_has_no_hide() {
        let app = plain(Platform::Windows)[0].items.clone();
        assert_eq!(app.last().map(|i| i.title.as_str()), Some("Exit"));
        assert_eq!(app.last().map(|i| i.shortcut.as_str()), Some("Alt+F4"));
        assert!(!app.iter().any(|i| i.title.starts_with("Hide")));
        let mac = plain(Platform::Mac)[0].items.clone();
        assert_eq!(mac.last().map(|i| i.title.as_str()), Some("Quit Sequence Studio"));
        assert!(mac.iter().any(|i| i.title == "Hide Sequence Studio"));
    }

    #[test]
    fn linux_menus_match_windows_with_ctrl_hints_and_no_mac_rows() {
        let (win, linux) = (plain(Platform::Windows), plain(Platform::Linux));
        let rows = |v: &[ShellMenu]| {
            v.iter().flat_map(|m| m.items.iter().map(|i| (i.title.clone(), i.shortcut.clone()))).collect::<Vec<_>>()
        };
        // The one difference: Exit is Alt+F4 on Windows (the system's) and Ctrl+Q on Linux (the shell's, see `is_quit_chord`).
        let same_but_exit = |v: Vec<(String, String)>| v.into_iter().filter(|(t, _)| t != "Exit").collect::<Vec<_>>();
        assert_eq!(same_but_exit(rows(&win)), same_but_exit(rows(&linux)));
        let all = rows(&linux);
        for gone in ["Hide Sequence Studio", "Hide Others", "Show All", "Bring All to Front"] {
            assert!(!all.iter().any(|(t, _)| t == gone), "{gone}");
        }
        assert!(all.iter().any(|(_, s)| s == "Ctrl+Z"));
        assert!(!all.iter().any(|(_, s)| s.contains('\u{2318}')));
    }

    /// The AppKit bar: Hide Others (Option-Command-H) and Show All under Hide on the Mac; File ends with Collect and
    /// Media Management (`MediaMenuTarget`: four modes, library copies and watching, the last two need a project folder).
    #[test]
    fn mac_app_menu_and_file_media_management_are_the_appkit_rows() {
        let mac = plain(Platform::Mac)[0].items.clone();
        let titles: Vec<&str> = mac.iter().map(|i| i.title.as_str()).collect();
        let hide = titles.iter().position(|t| *t == "Hide Sequence Studio");
        assert_eq!(titles.iter().position(|t| *t == "Hide Others"), hide.map(|h| h + 1));
        assert!(titles.contains(&"Show All"));
        assert_eq!(
            mac.iter().find(|i| i.title == "Hide Others").map(|i| i.shortcut.as_str()),
            Some("\u{2325}\u{2318}H")
        );
        assert!(!plain(Platform::Windows)[0].items.iter().any(|i| i.title == "Show All"));
        let s = ShellMenuState {
            outside_media: sq_core_model::OutsideMediaMode::Copy,
            copy_library_items: true,
            ..Default::default()
        };
        let log: Rc<RefCell<Vec<ShellAction>>> = Rc::default();
        let file = menu(&menus(&s, Platform::Mac, &log), "File");
        let tail: Vec<&str> = file[file.len() - 2..].iter().map(|i| i.title.as_str()).collect();
        assert_eq!(tail, vec!["Collect Files into Project Folder", "Media Management"]);
        let media = file.last().and_then(|i| i.submenu.clone()).unwrap_or_default();
        let actions: Vec<&str> =
            media.iter().filter(|i| i.kind == SQMenuItemKind::Action).map(|i| i.title.as_str()).collect();
        assert_eq!(
            actions,
            vec![
                "Ask About Outside Files",
                "Copy Outside Files Into Project",
                "Move Outside Files Into Project",
                "Leave Outside Files Where They Are",
                "Copy Library Items Into Project",
                "Watch Project Folder"
            ]
        );
        assert_eq!(
            media.iter().find(|i| i.is_checked).map(|i| i.title.as_str()),
            Some("Copy Outside Files Into Project")
        );
        assert_eq!(media.iter().find(|i| i.title == "Watch Project Folder").map(|i| i.is_enabled), Some(false));
        if let Some(a) =
            media.iter().find(|i| i.title == "Move Outside Files Into Project").and_then(|i| i.action.clone())
        {
            a();
        }
        assert_eq!(*log.borrow(), vec![ShellAction::OutsideMedia(sq_core_model::OutsideMediaMode::Move)]);
    }

    #[test]
    fn open_recent_follows_open_project_and_performs_the_path() {
        let s = ShellMenuState {
            recents: vec![RecentEntry::new("/p/Film.sqproj", "Film", Timestamp::from_unix_seconds(0.0))],
            ..Default::default()
        };
        let log: Rc<RefCell<Vec<ShellAction>>> = Rc::default();
        let file = menu(&menus(&s, Platform::Windows, &log), "File");
        let i = file.iter().position(|i| i.title == "Open Recent");
        assert!(i.is_some());
        let i = i.unwrap_or(1);
        assert_eq!(file[i - 1].title, EditorCommand::OpenProject.title());
        let rows = file[i].submenu.clone().unwrap_or_default();
        assert_eq!(rows[0].title, "Film");
        assert!(rows.last().is_some_and(|r| r.title == "Clear Menu" && r.is_enabled));
        if let Some(a) = rows[0].action.clone() {
            a();
        }
        assert_eq!(*log.borrow(), vec![ShellAction::OpenRecent { path: "/p/Film.sqproj".to_string() }]);
    }

    /// Save Checkpoint is Ctrl+Cmd+S on the Mac; on Windows and Linux that chord would read Ctrl+S (Save), so it has no key.
    #[test]
    fn save_checkpoint_is_menu_only_where_command_is_ctrl() {
        fn checkpoint(items: &[SQMenuItem]) -> Option<SQMenuItem> {
            items.iter().find_map(|i| {
                if i.title == "Save Checkpoint…" {
                    Some(i.clone())
                } else {
                    i.submenu.as_deref().and_then(checkpoint)
                }
            })
        }
        let key = |p| checkpoint(&menu(&plain(p), "File")).map(|i| i.shortcut);
        for p in [Platform::Windows, Platform::Linux] {
            assert_eq!(key(p), Some(String::new()));
        }
        assert!(key(Platform::Mac).is_some_and(|k| !k.is_empty()));
    }

    #[test]
    fn empty_recents_disable_clear_menu() {
        let file = menu(&plain(Platform::Mac), "File");
        let rows = file.iter().find(|i| i.title == "Open Recent").and_then(|i| i.submenu.clone()).unwrap_or_default();
        assert!(rows.len() == 1 && !rows[0].is_enabled);
    }

    #[test]
    fn undo_title_carries_the_step_name() {
        let s = ShellMenuState { undo_name: Some("Trim".to_string()), ..Default::default() };
        let edit: Vec<SQMenuItem> =
            menus(&s, Platform::Windows, &Rc::default()).into_iter().flat_map(|m| m.items).collect();
        assert!(edit.iter().any(|i| i.title.starts_with("Undo ") && i.is_enabled && i.shortcut == "Ctrl+Z"));
        assert!(edit.iter().any(|i| i.title == "Redo" && !i.is_enabled));
    }

    #[test]
    fn running_command_shows_its_cancel_title() {
        let title = EditorCommand::Anonymize.title();
        let all = |m: Vec<ShellMenu>| -> Vec<SQMenuItem> {
            fn walk(items: &[SQMenuItem], out: &mut Vec<SQMenuItem>) {
                for i in items {
                    out.push(i.clone());
                    walk(i.submenu.as_deref().unwrap_or(&[]), out);
                }
            }
            let mut out = Vec::new();
            for menu in m {
                walk(&menu.items, &mut out);
            }
            out
        };
        assert!(all(plain(Platform::Mac)).iter().any(|i| i.title == title));
        let mut s = ShellMenuState::default();
        s.titles.insert(EditorCommand::Anonymize, "Cancel Anonymize".to_string());
        let m = all(menus(&s, Platform::Mac, &Rc::default()));
        assert!(m.iter().any(|i| i.title == "Cancel Anonymize"));
        assert!(!m.iter().any(|i| i.title == title));
    }

    #[test]
    fn chooser_lets_only_project_starts_through() {
        let mut s = ShellMenuState { chooser_shown: true, ..Default::default() };
        let file = menu(&menus(&s, Platform::Mac, &Rc::default()), "File");
        let enabled = |t: String| file.iter().find(|i| i.title == t).map(|i| i.is_enabled);
        assert_eq!(enabled(EditorCommand::OpenProject.title()), Some(true));
        assert_eq!(enabled(EditorCommand::Save.title()), Some(false));
        s.chooser_shown = false;
        s.modal_shown = true;
        let file = menu(&menus(&s, Platform::Mac, &Rc::default()), "File");
        assert!(file.iter().all(|i| !i.is_enabled || i.kind != SQMenuItemKind::Action || i.submenu.is_some()));
    }

    #[test]
    fn the_start_window_can_check_for_updates() {
        let s = ShellMenuState { chooser_shown: true, ..Default::default() };
        let help = menu(&menus(&s, Platform::Mac, &Rc::default()), "Help");
        let enabled = |t: &str| help.iter().find(|i| i.title == t).map(|i| i.is_enabled);
        assert_eq!(enabled("Check for Updates\u{2026}"), Some(true));
        assert_eq!(enabled("Welcome Tour\u{2026}"), Some(true));
    }

    #[test]
    fn tidy_drops_edge_and_doubled_separators() {
        let (a, b) = (SQMenuItem::new("A"), SQMenuItem::new("B"));
        let sep = SQMenuItem::separator;
        let kinds: Vec<SQMenuItemKind> =
            ShellMenuBar::tidy(vec![sep(), a, sep(), sep(), b, sep()]).iter().map(|i| i.kind).collect();
        assert_eq!(kinds, vec![SQMenuItemKind::Action, SQMenuItemKind::Separator, SQMenuItemKind::Action]);
    }
}

// MARK: ShellHost

pub(crate) fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

pub(crate) fn shell() -> ShellHost {
    let mut h = ShellHost::new(
        CommandMap::premiere_default(),
        RecentProjects::new(Vec::new()),
        Arc::new(FakeClock::new()),
        Box::new(|| Timestamp::from_unix_seconds(0.0)),
    );
    h.set_size(CGSize::new(1000.0, 700.0));
    h
}

/// A platform whose choosers answer from a script and remember what they were asked.
#[derive(Default)]
pub(crate) struct Picker {
    pub(crate) save: Option<PathBuf>,
    pub(crate) file: Option<PathBuf>,
    /// The file Keyboard Shortcuts > Import Shortcuts picks.
    pub(crate) shortcut_file: Option<PathBuf>,
    asked: Vec<String>,
}

impl ShellFilePicker for Picker {
    fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    fn choose_save_location(&mut self, suggested_name: &str, _prompt: &str) -> ModalAsk<Option<PathBuf>> {
        self.asked.push(suggested_name.to_string());
        answered(self.save.clone())
    }
    fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
        answered(Vec::new())
    }
    fn choose_shortcut_file(&mut self) -> ModalAsk<Option<PathBuf>> {
        answered(self.shortcut_file.clone())
    }
    fn choose_file(&mut self, _prompt: &str, _directory: Option<&Path>) -> ModalAsk<Option<PathBuf>> {
        answered(self.file.clone())
    }
}

pub(crate) struct Root {
    pub(crate) session: EditorSession,
    pub(crate) shell: ShellHost,
    pub(crate) files: Picker,
    pub(crate) panel: ProjectPanelModel,
}

impl Root {
    pub(crate) fn new() -> Root {
        let session = session();
        let panel = ProjectPanelModel::new(session.project().clone(), ProjectPanelDeps::headless());
        Root { session, shell: shell(), files: Picker::default(), panel }
    }
}

impl ProjectPanelRoot for Root {
    fn panel_parts(&mut self) -> (&mut ProjectPanelModel, &mut EditorSession) {
        (&mut self.panel, &mut self.session)
    }
}

impl SessionRoot for Root {
    fn session(&mut self) -> &mut EditorSession {
        &mut self.session
    }
}

impl ShellRoot for Root {
    fn shell_parts(&mut self) -> ShellParts<'_> {
        ShellParts { session: &mut self.session, shell: &mut self.shell, files: &mut self.files }
    }
}

/// The runtime, the root and a weak handle for the flows.
pub(crate) struct Rig {
    pub(crate) rt: Rt,
    root: UiRoot<Root>,
    ui: RefCell<UiCx>,
}

impl Rig {
    pub(crate) fn new() -> Rig {
        let root = UiRoot::new(Root::new());
        Rig { rt: Rt::manual(), root, ui: RefCell::new(UiCx::new()) }
    }

    pub(crate) fn with<T>(&self, f: impl FnOnce(&mut Root) -> T) -> T {
        self.root.with(f).expect("root alive")
    }

    /// One shell call with a context.
    pub(crate) fn cx<T>(&self, f: impl FnOnce(&mut ShellHost, &mut ShellCx) -> T) -> T {
        self.with(|r| {
            let mut hooks = NoHooks;
            let mut ui = self.ui.borrow_mut();
            let mut cx = ShellCx { session: &mut r.session, measure: measure(), ui: &mut ui, hooks: &mut hooks };
            f(&mut r.shell, &mut cx)
        })
    }

    pub(crate) fn key(&self, k: InputKey, m: InputModifiers) -> bool {
        self.cx(|h, cx| h.handle(cx, &press(k, m), 1.0))
    }

    pub(crate) fn execute(&self, c: EditorCommand) -> bool {
        self.cx(|h, cx| h.execute(cx, c))
    }

    /// The handle a flow runs on.
    pub(crate) fn handle(&self) -> UiRef<dyn ShellRoot> {
        UiRef::new(self.root.weak())
    }

    /// Starts the flows the shell asked for and runs them until they wait.
    pub(crate) fn run_flows(&self) {
        let h: UiRef<dyn ShellRoot> = UiRef::new(self.root.weak());
        for f in self.with(|r| r.shell.take_flows()) {
            self.rt.ex.spawn_local(ShellHost::run_flow(h.clone(), f));
        }
        self.rt.run_until_stalled();
    }

    pub(crate) fn answer(&self, r: SQDialogResponse) {
        self.with(|root| {
            if let Some(d) = root.shell.dialog_mut() {
                d.press(r);
            }
        });
        self.rt.run_until_stalled();
    }

    pub(crate) fn has_dialog(&self) -> bool {
        self.with(|r| r.shell.dialog().is_some())
    }

    pub(crate) fn dirty(&self) {
        self.with(|r| r.session.mark_in());
    }
}

mod host {
    use super::*;

    #[test]
    fn title_marks_unsaved_changes() {
        let rig = Rig::new();
        // nothing open: the Mac shows the start window
        rig.with(|r| r.session.close_project());
        assert_eq!(rig.with(|r| r.shell.window_title(&r.session)), "Sequence Studio");
        rig.with(|r| r.session.new_project(EditorSession::make_untitled(&mut SequentialIds::default())));
        rig.dirty();
        assert_eq!(rig.with(|r| r.shell.window_title(&r.session)), "*Untitled - Sequence Studio");
    }

    /// Linux has no system Quit key (Mac: Cmd+Q in the menu bar, Windows: Alt+F4): the shell takes Ctrl+Q and asks the
    /// same Save Changes question as File > Exit. Found in the real KDE window, where Ctrl+Q did nothing.
    #[test]
    fn ctrl_q_starts_the_quit_flow_on_linux_only() {
        let rig = Rig::new();
        rig.with(|r| r.shell.platform = Platform::Linux);
        assert!(rig.key(InputKey::Character('q'), InputModifiers::COMMAND));
        assert_eq!(rig.with(|r| r.shell.take_flows()), vec![ShellFlow::Quit]);
        // Another chord, or another system, leaves the key alone.
        assert!(!rig.key(InputKey::Character('q'), InputModifiers::COMMAND | InputModifiers::SHIFT));
        rig.with(|r| r.shell.platform = Platform::Windows);
        rig.key(InputKey::Character('q'), InputModifiers::COMMAND);
        assert!(rig.with(|r| r.shell.take_flows()).is_empty());
    }

    #[test]
    fn ctrl_key_runs_the_command_and_unknown_keys_pass_through() {
        let rig = Rig::new();
        assert!(rig.key(InputKey::Character('i'), NONE));
        assert!(rig.with(|r| r.session.active_timeline().is_some_and(|t| t.in_out.is_some())));
        assert!(rig.key(InputKey::Character('z'), InputModifiers::COMMAND));
        assert!(rig.with(|r| r.session.active_timeline().is_some_and(|t| t.in_out.is_none())));
        assert!(!rig.key(InputKey::Character('q'), InputModifiers::OPTION | InputModifiers::SHIFT));
    }

    #[test]
    fn close_asks_and_dont_save_closes() {
        let rig = Rig::new();
        rig.dirty();
        assert!(rig.execute(EditorCommand::CloseProject));
        rig.run_flows();
        assert!(rig.has_dialog());
        rig.answer(SQDialogResponse::THIRD); // Don’t Save
        assert!(rig.with(|r| r.session.is_empty_untitled()));
        assert!(!rig.has_dialog());
    }

    #[test]
    fn cancel_keeps_the_project() {
        let rig = Rig::new();
        rig.dirty();
        rig.execute(EditorCommand::CloseProject);
        rig.run_flows();
        rig.answer(SQDialogResponse::SECOND); // Cancel
        assert!(!rig.with(|r| r.session.is_empty_untitled()));
        assert!(rig.with(|r| r.session.is_dirty()));
    }

    #[test]
    fn dialog_takes_every_event_while_it_shows() {
        let rig = Rig::new();
        rig.dirty();
        rig.execute(EditorCommand::CloseProject);
        rig.run_flows();
        assert!(rig.has_dialog());
        assert!(rig.key(InputKey::Character('i'), NONE));
        assert!(!rig.cx(|h, cx| h.enabled(cx.session, &*cx.hooks, EditorCommand::CloseProject)));
        assert!(rig.with(|r| r.shell.owns_keyboard()));
        assert!(rig.key(InputKey::Escape, NONE)); // Esc = Cancel
        rig.rt.run_until_stalled();
        assert!(!rig.has_dialog());
        assert!(!rig.with(|r| r.session.is_empty_untitled()));
    }

    #[test]
    fn save_of_an_untitled_project_asks_for_a_place_and_notes_the_recent() {
        let rig = Rig::new();
        let dir = std::env::temp_dir().join(format!("sqshell-{}", std::process::id()));
        assert!(std::fs::create_dir_all(&dir).is_ok());
        rig.with(|r| r.files.save = Some(dir.join("Cut")));
        rig.dirty();
        rig.execute(EditorCommand::Save);
        rig.run_flows();
        assert_eq!(rig.with(|r| r.files.asked.clone()), vec!["Untitled.sqproj"]);
        assert_eq!(
            rig.with(|r| r.session.file_url().and_then(|u| u.extension().map(|e| e.to_os_string()))),
            Some("sqproj".into())
        );
        assert!(!rig.with(|r| r.session.is_dirty()));
        assert_eq!(rig.with(|r| r.shell.recents.entries().first().map(|e| e.name.clone())), Some("Cut".to_string()));
        assert_eq!(rig.with(|r| r.shell.window_title(&r.session)), "Cut - Sequence Studio");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn canceled_save_place_stays_dirty() {
        let rig = Rig::new();
        rig.dirty();
        rig.execute(EditorCommand::Save);
        rig.run_flows();
        assert!(rig.with(|r| r.session.is_dirty()));
        assert!(rig.with(|r| r.session.file_url().is_none()));
    }

    #[test]
    fn menus_follow_the_session_and_clear_recents() {
        let rig = Rig::new();
        rig.with(|r| r.shell.recents.note(std::path::Path::new("/tmp/A.sqproj"), Timestamp::from_unix_seconds(0.0)));
        assert_eq!(rig.cx(|h, cx| h.menu_state(cx.session, &*cx.hooks).recents.len()), 1);
        rig.cx(|h, cx| h.perform(cx, ShellAction::ClearRecents));
        assert!(rig.with(|r| r.shell.recents.entries().is_empty()));
        let events = rig.with(|r| r.shell.take_events());
        assert_eq!(events, vec![ShellEvent::RecentsChanged]);
        rig.cx(|h, cx| h.perform(cx, ShellAction::BringAllToFront)); // a Mac-only row nobody runs here
        let status = rig.with(|r| r.shell.take_events());
        assert_eq!(
            status,
            vec![ShellEvent::Status(crate::shell_platform_text::ShellPlatformText::not_available().to_string())]
        );
    }

    #[test]
    fn a_picked_menu_row_is_performed_after_the_menu_closed() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.layout(cx.session, &*cx.hooks, &cx.measure));
        // The drawn bar has no app title: File is the first one.
        let file = rig.with(|r| r.shell.menu_bar.title_frames()[0]);
        let (x, y) = (file.mid_x() as f32, file.mid_y() as f32);
        let down = InputEvent::MouseDown { x, y, modifiers: NONE };
        assert!(rig.cx(|h, cx| h.handle(cx, &down, 1.0)));
        assert!(rig.with(|r| r.shell.menu_bar.controller.is_open()));
        assert!(rig.with(|r| r.shell.owns_keyboard()));
        // Down to the first enabled row, Enter: its action is queued and performed by the shell.
        rig.key(InputKey::Down, NONE);
        rig.key(InputKey::Enter, NONE);
        assert!(!rig.with(|r| r.shell.menu_bar.controller.is_open()));
        assert_eq!(rig.with(|r| r.shell.take_flows()), vec![ShellFlow::NewProjectForm]);
    }

    #[test]
    fn command_z_undoes_and_shift_command_z_redoes_in_every_focus() {
        for focus in [
            None,
            Some(PanelID::Timeline),
            Some(PanelID::EffectControls),
            Some(PanelID::ProgramMonitor),
            Some(PanelID::Project),
        ] {
            let rig = Rig::new();
            rig.with(|r| r.shell.focus = focus);
            rig.dirty();
            let has_range = |rig: &Rig| rig.with(|r| r.session.active_timeline().is_some_and(|t| t.in_out.is_some()));
            assert!(has_range(&rig));
            assert!(rig.key(InputKey::Character('z'), InputModifiers::COMMAND), "undo key taken, focus {focus:?}");
            assert!(!has_range(&rig), "undone, focus {focus:?}");
            assert!(rig.key(InputKey::Character('z'), InputModifiers::COMMAND | InputModifiers::SHIFT));
            assert!(has_range(&rig), "redone, focus {focus:?}");
        }
    }

    #[test]
    fn revert_and_close_rows_follow_the_session() {
        let rig = Rig::new();
        let enabled = |c| rig.cx(|h, cx| h.enabled(cx.session, &*cx.hooks, c));
        assert!(!enabled(EditorCommand::Revert));
        assert!(!enabled(EditorCommand::CloseProject)); // nothing open yet
        rig.dirty();
        assert!(enabled(EditorCommand::CloseProject));
        assert!(!enabled(EditorCommand::Revert)); // dirty but never saved
    }
}

// MARK: Keyboard parity (undo after edits, held keys, J/K/L, Esc)

mod key_parity {
    use super::*;

    fn clip_rig() -> Rig {
        use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind};
        use sq_core_time::{IdSource, SequentialIds, Time, TimeRange};
        let rig = Rig::new();
        rig.with(|r| {
            // A real two-second clip: an empty sequence never enters playing (w87), so the rig needs one.
            let mut ids = SequentialIds::default();
            let clip = Clip::new(
                ids.next_id(),
                "c",
                ids.next_id(),
                TrackKind::Video,
                TimeRange::new(Time::ZERO, Time::new(2, 1)),
                Time::ZERO,
            );
            let mut video = Track::new(ids.next_id(), TrackKind::Video);
            video.overwrite(clip, &mut ids).expect("clip fits");
            let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 25)), vec![video]);
            r.session.new_project(Project::new(ids.next_id(), "P", Vec::new(), vec![tl]));
            r.session.seek(Time::new(1, 1));
        });
        rig
    }

    fn held(rig: &Rig, k: InputKey, m: InputModifiers) -> bool {
        rig.with(|r| {
            let mut ui = rig.ui.borrow_mut();
            ui.with_key_repeat(true, |ui| {
                let mut hooks = NoHooks;
                let mut cx = ShellCx { session: &mut r.session, measure: measure(), ui, hooks: &mut hooks };
                r.shell.handle(&mut cx, &press(k, m), 1.0)
            })
        })
    }

    #[test]
    fn a_held_key_does_not_repeat_a_one_shot_command() {
        let rig = clip_rig();
        assert!(rig.key(InputKey::Space, NONE));
        assert!(rig.with(|r| r.session.is_playing()));
        assert!(held(&rig, InputKey::Space, NONE), "swallowed, not passed on");
        assert!(rig.with(|r| r.session.is_playing()), "a held Space runs once");
    }

    #[test]
    fn l_plays_and_k_stops() {
        let rig = clip_rig();
        assert!(rig.key(InputKey::Character('l'), NONE));
        assert!(rig.with(|r| r.session.is_playing()));
        rig.with(|r| r.shell.key_up(&mut r.session, InputKey::Character('l')));
        assert!(rig.with(|r| r.session.is_playing()), "L keeps playing after the key comes up");
        assert!(rig.key(InputKey::Character('k'), NONE));
        rig.with(|r| r.shell.key_up(&mut r.session, InputKey::Character('k')));
        assert!(!rig.with(|r| r.session.is_playing()));
    }

    #[test]
    fn k_held_and_l_steps_one_frame() {
        let rig = clip_rig();
        let t0 = rig.with(|r| r.session.monitor_time());
        assert!(rig.key(InputKey::Character('k'), NONE));
        assert!(rig.key(InputKey::Character('l'), NONE));
        rig.with(|r| {
            r.shell.key_up(&mut r.session, InputKey::Character('l'));
            r.shell.key_up(&mut r.session, InputKey::Character('k'));
        });
        assert!(rig.with(|r| r.session.monitor_time()) > t0);
        assert!(!rig.with(|r| r.session.is_playing()));
    }

    #[test]
    fn escape_with_nothing_to_close_or_clear_is_not_ours() {
        let rig = clip_rig();
        // nothing selected, no trim mode, no menu: Esc goes on to the panels
        assert!(!rig.key(InputKey::Escape, NONE));
    }
}

// MARK: Modal keys

mod modal_keys {
    use super::*;

    #[test]
    fn a_dialog_and_an_open_menu_own_the_keyboard_until_they_close() {
        let rig = Rig::new();
        assert!(!rig.with(|r| r.shell.owns_keyboard()));
        rig.with(|r| {
            let mut d = ShellDialog::new("Hello", "");
            d.add_button("OK", SQDialogRole::Default, false);
            drop(r.shell.present(d));
        });
        assert!(rig.with(|r| r.shell.owns_keyboard()));
        assert!(rig.key(InputKey::Enter, NONE));
        assert!(!rig.with(|r| r.shell.owns_keyboard()));
    }
}
