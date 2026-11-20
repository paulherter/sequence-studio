//! Ports of the Swift tests of ShellHelp, ShellMascot (in their modules), ShellStart, ShellStartWindows, ShellShortcuts,
//! ShellRecovery and the later shell groups, on the rig of `tests.rs`.

use super::*;
use crate::shell_host::{SettingValue, StartSettings};
use crate::shell_start::{
    Element, ShellStartScreen, StartAction, StartEnv, StartHit, StartSort, StartTab, WHATS_NEW_SEEN_KEY, m,
};
use crate::shell_start_windows::StartWindowStep;
use crate::shell_whats_new::WhatsNew;
use crate::tests::{Rig, measure};
use sq_core_project::project_template::ProjectTemplate;
use sq_core_project::support_policy::{SupportEntry, SupportLinks};
use sq_core_time::Timestamp;
use sq_draw::InputKey;
use sq_draw::{Canvas, InputEvent, InputModifiers};
use sq_editor_session::{RecentEntry, RecentProjects};
use sq_uikit::app_version::AppVersion;
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqdialog_model::SQDialogResponse;

fn opened(rig: &Rig) -> Vec<String> {
    rig.with(|r| r.shell.take_events())
        .into_iter()
        .filter_map(|e| if let ShellEvent::OpenUrl(u) = e { Some(u) } else { None })
        .collect()
}

mod help {
    use super::*;

    #[test]
    fn support_rows_open_their_pages() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.perform(cx, ShellAction::Support(SupportEntry::Github)));
        rig.cx(|h, cx| h.perform(cx, ShellAction::Support(SupportEntry::Support)));
        assert_eq!(opened(&rig), vec![SupportLinks::GITHUB.to_string(), SupportLinks::URL.to_string()]);
    }

    #[test]
    fn discord_row_opens_the_invite() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.perform(cx, ShellAction::Support(SupportEntry::Discord)));
        assert_eq!(opened(&rig), vec![SupportLinks::DISCORD.unwrap_or_default().to_string()]);
    }

    #[test]
    fn feedback_opens_a_prefilled_mail() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.perform(cx, ShellAction::SendFeedback));
        assert!(opened(&rig).first().is_some_and(|u| u.starts_with("mailto:")));
    }

    /// The Mac About (AboutDialog.makeBody): the sList card, the icon above the name, version, tagline, the link buttons (a
    /// click opens the page), License and credits; Acknowledgments swaps to the list, Back swaps back.
    #[test]
    fn about_is_the_mac_card_and_acknowledgments_go_back_and_forth() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.perform(cx, ShellAction::About));
        rig.run_flows();
        assert!(rig.has_dialog());
        let m = measure();
        rig.with(|r| {
            let d = r.shell.dialog_mut().expect("about");
            assert_eq!(d.width, 360.0);
            d.layout(CGRect::new(0.0, 0.0, 1100.0, 720.0), &m);
        });
        rig.answer(SQDialogResponse::SECOND);
        assert!(rig.has_dialog());
        assert_eq!(rig.with(|r| r.shell.dialog().map(|d| d.message_text.clone())), Some("Acknowledgments".to_string()));
        rig.answer(SQDialogResponse::SECOND);
        assert_eq!(rig.with(|r| r.shell.dialog().map(|d| d.message_text.clone())), Some(String::new()));
        rig.answer(SQDialogResponse::FIRST);
        assert!(!rig.has_dialog());
    }

    fn texts(c: &mut ShellAboutContent) -> Vec<String> {
        use crate::shell_dialog::ShellDialogContent;
        c.layout(CGRect::new(0.0, 0.0, 480.0, 0.0), &measure());
        c.text_lines()
    }

    #[test]
    fn about_lists_supporters_only_when_there_are_any() {
        let mut none = ShellAboutContent::new(AboutPage::About, Vec::new(), None, Box::new(|_| {}));
        assert!(!texts(&mut none).contains(&"Supporters".to_string()));
        let mut some =
            ShellAboutContent::new(AboutPage::About, vec!["Ada".into(), "Linus".into()], None, Box::new(|_| {}));
        assert!(texts(&mut some).contains(&"Supporters".to_string()));
    }

    #[test]
    fn about_card_text_and_link_click() {
        use crate::shell_dialog::ShellDialogContent;
        let log = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        let l = std::rc::Rc::clone(&log);
        let mut c = ShellAboutContent::new(
            AboutPage::About,
            Vec::new(),
            SupportLinks::DISCORD,
            Box::new(move |u| l.borrow_mut().push(u.to_string())),
        );
        let t = texts(&mut c);
        assert_eq!(t.first().map(String::as_str), Some("Sequence Studio"));
        assert!(t.contains(&AppVersion::about_line()));
        assert!(t.contains(&format!("License: {}", sq_uikit::about_content::LICENSE)));
        let icon = c.icon_frame().expect("icon");
        assert_eq!(icon.width, 72.0);
        let gh = c.first_button_center().expect("button");
        let (x, y) = (gh.x as f32, gh.y as f32);
        let _ = c.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, 1.0);
        let _ = c.handle(&InputEvent::MouseUp { x, y }, 1.0);
        assert_eq!(*log.borrow(), vec![SupportLinks::GITHUB.to_string()]);
    }

    #[test]
    fn about_scroll_offset_survives_a_new_layout() {
        use crate::shell_dialog::ShellDialogContent;
        let mut c = ShellAboutContent::new(AboutPage::About, Vec::new(), SupportLinks::DISCORD, Box::new(|_| {}));
        let frame = CGRect::new(0.0, 0.0, 480.0, 120.0);
        c.layout(frame, &measure());
        let top = c.icon_frame().expect("icon").y;
        assert!(c.handle(
            &InputEvent::Scroll { x: 10.0, y: 10.0, dx: 0.0, dy: -40.0, modifiers: InputModifiers::NONE },
            1.0
        ));
        let scrolled = c.icon_frame().expect("icon").y;
        assert!(scrolled < top);
        c.layout(frame, &measure());
        assert_eq!(c.icon_frame().expect("icon").y, scrolled, "offset kept");
        // A frame tall enough for the whole card clamps the offset back to the top.
        c.layout(CGRect::new(0.0, 0.0, 480.0, 5000.0), &measure());
        assert_eq!(c.icon_frame().expect("icon").y, top);
    }

    #[test]
    fn about_icon_draws_as_polygons() {
        let mut cv = Canvas::with_size(480.0, 400.0, None, 1.0);
        ShellAppIcon::draw(CGRect::new(0.0, 0.0, 88.0, 88.0), &mut cv, false);
        assert!(cv.list.quads().len() > 20);
    }

    #[test]
    fn update_check_without_a_feed_says_so() {
        let rig = Rig::new();
        rig.cx(|h, _| h.start_flow(ShellFlow::CheckForUpdates));
        rig.run_flows();
        let d = rig.with(|r| r.shell.dialog().map(|d| (d.message_text.clone(), d.informative_text.clone())));
        let (title, text) = d.expect("dialog");
        assert_eq!(title, "Check for Updates");
        assert!(text.contains("not set up"));
    }

    #[test]
    fn reveal_logs_selects_the_newest_log_file() {
        let dir = std::env::temp_dir().join(format!("sq-reveal-logs-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let log = dir.join("sq.log");
        let _ = std::fs::write(&log, "x");
        let rig = Rig::new();
        rig.with(|r| r.shell.log_directory = Some(dir.clone()));
        rig.cx(|h, cx| h.perform(cx, ShellAction::RevealLogs));
        let ev = rig.with(|r| r.shell.take_events());
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(ev, vec![ShellEvent::RevealFile(log)]);
    }

    #[test]
    fn reveal_logs_shows_the_log_folder() {
        let rig = Rig::new();
        rig.with(|r| r.shell.log_directory = Some("/tmp/sq-logs".into()));
        rig.cx(|h, cx| h.perform(cx, ShellAction::RevealLogs));
        let ev = rig.with(|r| r.shell.take_events());
        assert_eq!(ev, vec![ShellEvent::RevealFile("/tmp/sq-logs".into())]);
    }
}

mod start {
    use super::*;

    fn entry(name: &str, days_ago: f64) -> RecentEntry {
        RecentEntry::new(
            format!("/nowhere/{name}/{name}.sqproj"),
            name,
            Timestamp::from_unix_seconds(-days_ago * 86_400.0),
        )
    }

    /// A rig with the start screen up over `recents` in a 1280 x 800 window.
    fn rig(recents: Vec<RecentEntry>) -> Rig {
        let rig = Rig::new();
        rig.with(|r| {
            r.shell.recents = RecentProjects::new(recents);
            r.shell.set_size(sq_uikit::controls_grid::CGSize::new(1280.0, 800.0));
        });
        rig.cx(|h, cx| {
            h.show_start(cx);
        });
        // The recents do not exist on disk; the Swift reload ran detached, after the test body. Here it ran at once.
        screen(&rig, |s, _| s.missing.clear());
        rig
    }

    /// Runs `f` on the screen with its environment.
    fn screen<T>(rig: &Rig, f: impl FnOnce(&mut ShellStartScreen, &StartEnv) -> T) -> T {
        rig.cx(|h, cx| {
            let mut s = h.start.take().expect("start screen");
            let out = {
                let env = h.start_env(&cx.measure, !cx.session.is_empty_untitled(), "", "");
                f(&mut s, &env)
            };
            h.start = Some(s);
            out
        })
    }

    fn click(rig: &Rig, p: CGPoint) {
        rig.cx(|h, cx| {
            h.handle(cx, &InputEvent::MouseDown { x: p.x as f32, y: p.y as f32, modifiers: InputModifiers::NONE }, 1.0);
            h.handle(cx, &InputEvent::MouseUp { x: p.x as f32, y: p.y as f32 }, 1.0);
        });
    }

    fn key(rig: &Rig, k: InputKey, m: InputModifiers) {
        rig.key(k, m);
    }

    #[test]
    fn a_card_shows_its_poster_and_keeps_the_empty_look_without_one() {
        use crate::project_list_view::ProjectPoster;
        let e = entry("Shown", 0.0);
        let rig = rig(vec![e.clone()]);
        let asked = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        let log = std::rc::Rc::clone(&asked);
        rig.with(|r| {
            r.shell.start_poster = Some(std::rc::Rc::new(move |path: &str, seconds: f64| {
                log.borrow_mut().push((path.to_string(), seconds));
                (path == "/media/a.mov").then(|| ProjectPoster::new(3, sq_uikit::controls_grid::CGSize::new(8.0, 4.0)))
            }));
        });
        let path = e.path.clone();
        let with_info = |info: sq_editor_session::StartProjectInfo| {
            screen(&rig, |s, env| {
                s.infos.insert(path.clone(), info);
                s.card_poster(env, &path)
            })
        };
        let new = |media: Option<&str>| {
            sq_editor_session::StartProjectInfo::new(1920, 1080, 30.0, 10, media.map(str::to_string), 2.5)
        };
        let shown = with_info(new(Some("/media/a.mov"))).expect("the saved poster");
        assert_eq!(shown.slot, 3);
        assert_eq!(asked.borrow().last(), Some(&("/media/a.mov".to_string(), 2.5)));
        assert_eq!(with_info(new(None)), None, "no poster media: the fallback");
        assert_eq!(with_info(new(Some("/media/other.mov"))), None, "not decoded yet: the fallback");
        let mut gone = new(Some("/media/a.mov"));
        gone.media_missing = true;
        assert_eq!(with_info(gone), None, "missing media: the fallback");
        screen(&rig, |s, _| s.missing.insert(path.clone()));
        assert_eq!(with_info(new(Some("/media/a.mov"))), None, "missing project: the fallback");
    }

    #[test]
    fn covers_the_window_under_the_menu_bar_and_gates_the_menus() {
        let rig = rig(Vec::new());
        assert!(rig.with(|r| r.shell.is_start_shown()));
        let bar = rig.with(|r| r.shell.menu_bar.height());
        assert_eq!(screen(&rig, |s, _| s.frame), CGRect::new(0.0, bar, 1280.0, 800.0 - bar));
        assert!(rig.with(|r| r.shell.menu_state(&r.session, &NoHooks).chooser_shown));
        // Esc cannot close it without a project behind it.
        key(&rig, InputKey::Escape, InputModifiers::NONE);
        assert!(rig.with(|r| r.shell.is_start_shown()));
        assert!(rig.with(|r| r.shell.owns_keyboard()));
    }

    #[test]
    fn the_window_menu_check_for_tools_follows_the_dock() {
        // The dock alone answers it (`fill_window_state`); the shell hooks add nothing, so `fill_menu_state` was removed.
        use sq_uikit::panel_id::PanelID;
        let rig = rig(Vec::new());
        let checked =
            |rig: &Rig| rig.with(|r| r.shell.menu_state(&r.session, &NoHooks).visible_panels.contains(&PanelID::Tools));
        assert!(checked(&rig), "the Tools card is on screen in the default layout");
        rig.with(|r| r.shell.dock.toggle(PanelID::Tools));
        assert!(!checked(&rig), "hiding it clears the check mark");
        rig.with(|r| r.shell.dock.toggle(PanelID::Tools));
        assert!(checked(&rig), "showing it sets the check mark again");
    }

    #[test]
    fn hover_is_per_element_not_per_command() {
        let rig = rig(Vec::new()); // no recents: the empty pane has its own New project / Open… buttons
        let (rail, center) = screen(&rig, |s, env| {
            let rail = s.rail_spots().into_iter().find(|x| x.1 == StartHit::NewProject).expect("rail").0;
            let center = s
                .empty_state(env)
                .expect("empty")
                .2
                .into_iter()
                .find_map(|e| if let Element::Button(_, StartHit::EmptyNew, r, _) = e { Some(r) } else { None })
                .expect("button");
            (rail, center)
        });
        rig.cx(|h, cx| {
            h.handle(cx, &InputEvent::MouseMoved { x: center.mid_x() as f32, y: center.mid_y() as f32 }, 1.0)
        });
        assert_eq!(screen(&rig, |s, _| s.hover.clone()), Some(StartHit::EmptyNew));
        rig.cx(|h, cx| h.handle(cx, &InputEvent::MouseMoved { x: rail.mid_x() as f32, y: rail.mid_y() as f32 }, 1.0));
        assert_eq!(screen(&rig, |s, _| s.hover.clone()), Some(StartHit::NewProject));
    }

    #[test]
    fn recent_grid_groups_by_day_and_clicks_hit_the_cards() {
        let rig = rig(vec![entry("Today One", 0.0), entry("Week", 3.0), entry("Old", 30.0)]);
        screen(&rig, |s, env| {
            assert_eq!(s.tab(), StartTab::Recent);
            let els = s.pane_layout(env).0;
            let headings: Vec<String> = els
                .iter()
                .filter_map(|e| if let Element::Heading(t, _) = e { Some(t.clone()) } else { None })
                .collect();
            assert_eq!(headings, ["Today", "This week", "Earlier"]);
            let cards: Vec<(RecentEntry, CGRect)> = els
                .iter()
                .filter_map(|e| if let Element::Card(c, r) = e { Some((c.clone(), *r)) } else { None })
                .collect();
            assert_eq!(cards.iter().map(|c| c.0.name.as_str()).collect::<Vec<_>>(), ["Today One", "Week", "Old"]);
            assert!(cards.iter().all(|c| c.1.width >= crate::shell_start::m::TILE_W));
            let first = cards[0].1;
            assert_eq!(
                s.hit_at(CGPoint::new(first.min_x() + 20.0, first.min_y() + 20.0), env),
                Some(StartHit::Card(cards[0].0.path.clone()))
            );
            let more = ShellStartScreen::more_rect(first);
            assert_eq!(
                s.hit_at(CGPoint::new(more.mid_x(), more.mid_y()), env),
                Some(StartHit::CardMore(cards[0].0.path.clone()))
            );
            // Sorting by name drops the groups.
            s.set_sort(StartSort::Name);
            assert!(s.pane_layout(env).0.iter().all(|e| !matches!(e, Element::Heading(..))));
            assert_eq!(s.shown(env).iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["Old", "Today One", "Week"]);
        });
    }

    /// Dead rows: the window sends device pixels (scale 2) and the press may come without a hover frame.
    #[test]
    fn a_real_press_on_a_recent_opens_it_at_scale_two_with_and_without_a_move() {
        // The press looks at the file first, so these recents are real files.
        let dir = std::env::temp_dir().join(format!("sq-start-press-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let on_disk = |name: &str, days_ago: f64| {
            let path = dir.join(format!("{name}.sqproj"));
            std::fs::write(&path, b"x").unwrap_or_default();
            RecentEntry::new(
                path.to_string_lossy().into_owned(),
                name,
                Timestamp::from_unix_seconds(-days_ago * 86_400.0),
            )
        };
        for move_first in [true, false] {
            let rig = rig(vec![on_disk("Today One", 0.0), on_disk("Week", 3.0)]);
            let first = screen(&rig, |s, env| {
                s.pane_layout(env)
                    .0
                    .iter()
                    .find_map(|e| if let Element::Card(_, r) = e { Some(*r) } else { None })
                    .unwrap()
            });
            let (x, y) = ((first.min_x() + 20.0) as f32 * 2.0, (first.min_y() + 20.0) as f32 * 2.0);
            if move_first {
                rig.cx(|h, cx| h.handle(cx, &InputEvent::MouseMoved { x, y }, 2.0));
            }
            rig.cx(|h, cx| h.handle(cx, &InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, 2.0));
            rig.cx(|h, cx| h.handle(cx, &InputEvent::MouseUp { x, y }, 2.0));
            let flows = rig.with(|r| r.shell.take_flows());
            assert!(
                flows.iter().any(|f| matches!(f, crate::ShellFlow::OpenProject(_))),
                "the press opens the project (move first: {move_first})"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_list_toggle_switches_recent_to_header_and_rows() {
        let rig = rig(vec![entry("A", 0.0), entry("B", 3.0)]);
        let seg = screen(&rig, |s, env| s.layout_segment(env, true));
        click(&rig, CGPoint::new(seg.mid_x(), seg.mid_y()));
        let settings = rig.with(|r| r.shell.take_events());
        assert!(settings.contains(&ShellEvent::Setting {
            key: "sq.start.listLayout".into(),
            value: crate::shell_host::SettingValue::Flag(true)
        }));
        screen(&rig, |s, env| {
            assert!(s.list_layout());
            let els = s.pane_layout(env).0;
            assert_eq!(els.iter().filter(|e| matches!(e, Element::ListHeader(_))).count(), 1);
            let rows: Vec<(RecentEntry, CGRect)> = els
                .iter()
                .filter_map(|e| if let Element::ListRow(c, r) = e { Some((c.clone(), *r)) } else { None })
                .collect();
            assert_eq!(rows.iter().map(|c| c.0.name.as_str()).collect::<Vec<_>>(), ["A", "B"]);
            assert!(rows.iter().all(|r| r.1.height == 44.0));
            assert!(els.iter().all(|e| !matches!(e, Element::Heading(..) | Element::Card(..))));
            let r = rows[0].1;
            assert_eq!(
                s.hit_at(CGPoint::new(r.min_x() + 30.0, r.mid_y()), env),
                Some(StartHit::Card(rows[0].0.path.clone()))
            );
            let more = ShellStartScreen::list_columns(r).more;
            assert_eq!(
                s.hit_at(CGPoint::new(more.mid_x(), more.mid_y()), env),
                Some(StartHit::CardMore(rows[0].0.path.clone()))
            );
        });
        let grid = screen(&rig, |s, env| s.layout_segment(env, false));
        click(&rig, CGPoint::new(grid.mid_x(), grid.mid_y()));
        assert!(!screen(&rig, |s, _| s.list_layout()));
    }

    #[test]
    fn the_mac_keeps_the_search_in_the_window_bar_and_drops_the_top_row() {
        let rig = rig(vec![entry("Interview", 0.0)]);
        let own_row = screen(&rig, |s, _| s.rail_rect().min_y());
        rig.with(|r| {
            r.shell.start_search_in_bar = true;
            r.shell.start_layout();
        });
        let bar = rig.with(|r| r.shell.menu_bar.height());
        screen(&rig, |s, _| {
            assert_eq!(s.bar_frame, Some(CGRect::new(0.0, 0.0, 1280.0, bar)));
            assert!(s.search_rect().max_y() <= bar && s.search_rect().max_x() < 1280.0);
            assert_eq!(s.rail_rect().min_y(), own_row - crate::shell_start::m::TOP);
        });
        // A click on the field in the bar starts typing there.
        let f = screen(&rig, |s, _| s.search_rect());
        click(&rig, CGPoint::new(f.mid_x(), f.mid_y()));
        for ch in "int".chars() {
            key(&rig, InputKey::Character(ch), InputModifiers::NONE);
        }
        assert_eq!(screen(&rig, |s, _| s.query()), "int");
    }

    /// The Windows and Linux bar at 640 / 800 / 1024 / 1440: the search field shrinks, then hides, then the last menus fold into
    /// "»"; every title is whole or folded, none is cut by the field or the buttons.
    #[test]
    fn the_start_bar_fits_menus_and_search_at_every_width() {
        let names = ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window", "Help"];
        for (profile, inset) in [("windows", 138.0), ("linux", 0.0)] {
            for width in [260.0, 400.0, 640.0, 800.0, 1024.0, 1440.0] {
                let rig = rig_sized(vec![entry("Interview", 0.0)], width, 400.0);
                rig.cx(|h, cx| {
                    h.start_search_in_bar = true;
                    h.start_bar_right_inset = inset;
                    let m = &cx.measure;
                    h.menu_bar.set_menus(
                        names.iter().map(|n| crate::shell_menu_bar::ShellMenu::new(n, Vec::new())).collect(),
                        m,
                    );
                    if inset > 0.0 {
                        h.menu_bar.set_max_width(Some((width - 186.0 - h.menu_bar.origin().x).max(0.0)), m);
                    }
                    h.relayout_dialog(m);
                });
                let (field, bar_right) = screen(&rig, |s, _| (s.search_rect(), s.bar_frame.map_or(0.0, |b| b.max_x())));
                let (titles, more) =
                    rig.with(|r| (r.shell.menu_bar.title_frames().to_vec(), r.shell.menu_bar.overflow_frame()));
                let end = more.or_else(|| titles.last().copied()).map_or(0.0, |r| r.max_x());
                let ctx = format!("{profile} {width}");
                assert!(end <= bar_right, "{ctx}: the titles end inside the bar");
                if field.width > 0.0 {
                    assert!(end <= field.min_x(), "{ctx}: the titles end before the field ({end} > {})", field.min_x());
                    assert!(field.width >= 120.0 && field.max_x() <= bar_right, "{ctx}: field {field:?}");
                }
                let folded = rig.with(|r| r.shell.menu_bar.menus().len()) - titles.len();
                assert_eq!(folded > 0, more.is_some(), "{ctx}: folded titles live behind the overflow title");
                if width == 1440.0 {
                    assert!(folded == 0 && field.width == 280.0, "{ctx}: everything fits");
                }
                if field.width > 0.0 && field.width < 280.0 {
                    assert_eq!(folded, 0, "{ctx}: the field shrinks before a menu folds");
                }
                if width == 260.0 && inset == 0.0 {
                    assert!(field.width == 0.0 && folded > 0, "{ctx}: field gone, menus folded");
                }
            }
        }
    }

    #[test]
    fn a_window_caption_keeps_the_in_bar_search_clear_of_its_buttons() {
        let rig = rig(vec![entry("Interview", 0.0)]);
        rig.with(|r| {
            r.shell.start_search_in_bar = true;
            r.shell.start_bar_right_inset = 138.0;
            r.shell.start_layout();
        });
        let (field, bar) = (screen(&rig, |s, _| s.search_rect()), rig.with(|r| r.shell.menu_bar.height()));
        assert!(field.max_x() <= 1280.0 - 138.0, "the field ends before the buttons");
        assert!(field.max_y() <= bar, "and sits in the one bar");
        // The bar's row drags the window except over the field.
        assert_eq!(rig.with(|r| r.shell.start_bar_controls()), vec![field]);
        rig.with(|r| r.shell.start_search_in_bar = false);
        rig.with(|r| r.shell.start_layout());
        assert!(rig.with(|r| r.shell.start_bar_controls()).is_empty());
    }

    /// Window chrome (U8): the start screen never swallows a press on empty bar space, so the window can drag and zoom there;
    /// what sits in the bar (the search field, a card, the rail) still takes its press, and the screen stays modal elsewhere.
    #[test]
    fn an_empty_start_bar_is_not_taken_but_its_controls_are() {
        let press = |rig: &Rig, x: f64, y: f64| {
            rig.cx(|h, cx| {
                h.handle(cx, &InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE }, 1.0)
            })
        };
        // Windows and Linux: the bar row is the window caption and the screen lies under it.
        let rig = rig(vec![entry("Interview", 0.0)]);
        rig.with(|r| {
            r.shell.start_search_in_bar = true;
            r.shell.start_bar_right_inset = 138.0;
            r.shell.start_layout();
        });
        let (field, bar) = (screen(&rig, |s, _| s.search_rect()), rig.with(|r| r.shell.menu_bar.height()));
        for share in [0.35_f64, 0.5, 0.7] {
            let x = (1280.0 * share).round();
            if field.contains(CGPoint::new(x, bar / 2.0)) {
                continue; // this narrow window puts the field there
            }
            assert!(!press(&rig, x, bar / 2.0), "{share}: empty bar space is the window's");
        }
        assert!(press(&rig, field.mid_x(), bar / 2.0), "the search field in the bar takes its press");
        assert!(press(&rig, 640.0, bar + 200.0), "the screen under the bar stays modal");
        // The Mac start window: its own top bar is part of the screen's frame.
        rig.with(|r| {
            r.shell.start_window_size = Some(sq_uikit::controls_grid::CGSize::new(1280.0, 800.0));
            r.shell.start_search_in_bar = false;
            r.shell.start_layout();
        });
        let (top, field) = (screen(&rig, |s, _| s.top_bar()), screen(&rig, |s, _| s.search_rect()));
        for share in [0.35_f64, 0.5, 0.7] {
            let x = (1280.0 * share).round();
            if field.contains(CGPoint::new(x, top.mid_y())) {
                continue;
            }
            assert!(!press(&rig, x, top.mid_y()), "{share}: empty top bar space is the window's");
        }
        assert!(press(&rig, field.mid_x(), field.mid_y()), "the search field takes its press");
        assert!(press(&rig, 640.0, top.max_y() + 200.0), "the screen under its top bar stays modal");
    }

    #[test]
    fn search_filters_switches_to_recent_and_esc_clears() {
        let rig = rig(vec![entry("Interview", 0.0), entry("Broll", 1.0)]);
        screen(&rig, |s, _| s.set_tab(StartTab::Learn));
        rig.cx(|h, cx| h.apply_start_actions(cx));
        assert!(rig.with(|r| r.shell.take_events()).contains(&ShellEvent::Setting {
            key: "sq.start.tab".into(),
            value: crate::shell_host::SettingValue::Text("Learn".into())
        }));
        key(&rig, InputKey::Character('f'), InputModifiers::COMMAND);
        for ch in "inter".chars() {
            key(&rig, InputKey::Character(ch), InputModifiers::NONE);
        }
        screen(&rig, |s, env| {
            assert_eq!(s.query(), "inter");
            assert_eq!(s.tab(), StartTab::Recent);
            assert_eq!(s.shown(env).iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["Interview"]);
        });
        key(&rig, InputKey::Escape, InputModifiers::NONE);
        screen(&rig, |s, env| {
            assert!(s.query().is_empty() && s.shown(env).len() == 2);
            // Nothing matches: the empty state offers Clear search.
            s.set_query("zzz");
            assert_eq!(s.empty_state(env).map(|e| e.0), Some("No projects match “zzz”".to_string()));
        });
    }

    #[test]
    fn find_shows_a_hidden_search_field_while_it_is_focused() {
        let rig = rig(vec![entry("Interview", 0.0)]);
        screen(&rig, |s, _| s.search_width = Some(0.0));
        screen(&rig, |s, _| assert_eq!(s.search_rect().width, 0.0, "a narrow window hides the field"));
        key(&rig, InputKey::Character('f'), InputModifiers::COMMAND);
        screen(&rig, |s, _| {
            assert!(s.search.is_editing());
            assert!(s.search_rect().width > 0.0, "Find shows the field while it has the focus");
        });
    }

    #[test]
    fn left_right_step_through_the_recents_like_up_down() {
        let rig = rig(vec![entry("A", 0.0), entry("B", 0.0), entry("C", 0.0)]);
        let paths: Vec<String> = rig.with(|r| r.shell.recents.entries().iter().map(|e| e.path.clone()).collect());
        key(&rig, InputKey::Right, InputModifiers::NONE);
        key(&rig, InputKey::Right, InputModifiers::NONE);
        assert_eq!(screen(&rig, |s, _| s.selected_path.clone()), Some(paths[2].clone()));
        key(&rig, InputKey::Right, InputModifiers::NONE);
        assert_eq!(screen(&rig, |s, _| s.selected_path.clone()), Some(paths[2].clone()), "stops at the last");
        key(&rig, InputKey::Left, InputModifiers::NONE);
        assert_eq!(screen(&rig, |s, _| s.selected_path.clone()), Some(paths[1].clone()));
    }

    #[test]
    fn up_down_move_the_highlight_and_tabs_switch_from_the_rail() {
        let rig = rig(vec![entry("A", 0.0), entry("B", 0.0), entry("C", 0.0)]);
        let paths: Vec<String> = rig.with(|r| r.shell.recents.entries().iter().map(|e| e.path.clone()).collect());
        assert_eq!(screen(&rig, |s, env| s.highlighted_path(env)), Some(paths[0].clone()));
        key(&rig, InputKey::Down, InputModifiers::NONE);
        key(&rig, InputKey::Down, InputModifiers::NONE);
        assert_eq!(screen(&rig, |s, _| s.selected_path.clone()), Some(paths[2].clone()));
        key(&rig, InputKey::Up, InputModifiers::NONE);
        assert_eq!(screen(&rig, |s, _| s.selected_path.clone()), Some(paths[1].clone()));
        let templates = screen(&rig, |s, _| {
            s.rail_spots().into_iter().find(|x| x.1 == StartHit::Tab(StartTab::Templates)).expect("tab").0
        });
        click(&rig, CGPoint::new(templates.mid_x(), templates.mid_y()));
        screen(&rig, |s, env| {
            assert_eq!(s.tab(), StartTab::Templates);
            let names: Vec<String> = s
                .pane_layout(env)
                .0
                .iter()
                .filter_map(|e| if let Element::TemplateCard(t, _) = e { Some(t.name.clone()) } else { None })
                .collect();
            assert_eq!(names, ProjectTemplate::built_in().into_iter().map(|t| t.name).collect::<Vec<_>>());
        });
        let check =
            screen(&rig, |s, _| s.rail_spots().into_iter().find(|x| x.1 == StartHit::ReopenLast).expect("check").0);
        click(&rig, CGPoint::new(check.mid_x(), check.mid_y()));
        assert!(screen(&rig, |s, _| s.reopen_last()));
    }

    /// Every one-line text and button of the start pane, set in the real UI font in its rect, ends at a word boundary
    /// (the Templates "How to save a template" button was cut to "How to save a templ…").
    #[test]
    fn no_start_pane_text_is_cut_mid_word() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let c = Canvas::with_size(1280.0, 800.0, Some(&atlas), 1.0);
        let rig = rig(vec![]);
        let mut checked = 0;
        for tab in [StartTab::Home, StartTab::Recent, StartTab::Templates, StartTab::Learn] {
            let els = screen(&rig, |s, env| {
                s.set_tab(tab);
                s.pane_layout(env).0
            });
            for e in &els {
                let (s, w, size) = match e {
                    Element::Txt(s, r, size, ..) | Element::TxtC(s, r, size, ..) => (s, r.width, *size),
                    Element::Button(s, _, r, _) => (s, r.width - 18.0, m::F_LAB),
                    Element::Section(s, r) if !s.is_empty() => (s, r.width - 32.0, m::F_LAB),
                    _ => continue,
                };
                let shown = c.ellipsized(s, size, 0, w);
                assert!(!sq_draw::glyph_atlas::cuts_mid_word(s, &shown), "{tab:?}: \"{s}\" shows \"{shown}\"");
                checked += 1;
            }
        }
        assert!(checked > 5, "the pane has texts ({checked})");
    }

    #[test]
    fn the_status_bar_drops_the_open_name_then_cuts_the_folder_before_anything_overlaps() {
        let wide = ShellStartScreen::status_widths(1000.0, [300.0, 60.0, 90.0, 140.0]);
        assert_eq!(wide, (300.0, true), "everything fits");
        let (folder, open) = ShellStartScreen::status_widths(608.0, [300.0, 60.0, 90.0, 140.0]);
        assert!(!open, "the open name goes first");
        assert_eq!(folder, 300.0, "the folder still fits");
        let (folder, open) = ShellStartScreen::status_widths(400.0, [300.0, 60.0, 90.0, 140.0]);
        assert!(!open && folder + 16.0 + 60.0 + 16.0 + 140.0 <= 400.0, "folder {folder} + count + version fit");
    }

    /// `rig` in a window of `w` x `h` points.
    fn rig_sized(recents: Vec<RecentEntry>, w: f64, h: f64) -> Rig {
        let rig = Rig::new();
        rig.with(|r| {
            r.shell.recents = RecentProjects::new(recents);
            r.shell.set_size(sq_uikit::controls_grid::CGSize::new(w, h));
        });
        rig.cx(|h, cx| h.show_start(cx));
        screen(&rig, |s, _| s.missing.clear());
        rig
    }

    /// The bounds of an element of the pane (`None` for the ones that only mark something).
    fn bounds_of(e: &Element) -> Option<CGRect> {
        Some(match e {
            Element::Heading(_, r)
            | Element::Txt(_, r, ..)
            | Element::TxtC(_, r, ..)
            | Element::Wrapped(_, r, ..)
            | Element::WrappedC(_, r, ..)
            | Element::Lane(r)
            | Element::Glyph(_, r, ..)
            | Element::IconSq(_, r, _)
            | Element::Tag(_, r, _)
            | Element::Section(_, r)
            | Element::Card(_, r)
            | Element::ListHeader(r)
            | Element::ListRow(_, r)
            | Element::ContinueBox(_, r)
            | Element::Quick(_, r)
            | Element::TemplateCard(_, r)
            | Element::Lesson(_, r)
            | Element::Button(_, _, r, _) => *r,
            _ => return None,
        })
    }

    /// The six views of the start window (Home, the empty Recent pane, Recent as tiles and as a list, Templates, Learn,
    /// What's new) at the window's minimum 640 x 400 and at 800 x 600: every part lies inside its card and inside the
    /// window, texts end at a word boundary or wrap (a text's real width fits its rect), buttons are whole.
    #[test]
    fn all_six_start_views_lay_out_cleanly_down_to_the_minimum_window() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let real = sq_draw::TextMeasure::new(Some(&atlas), 1.0);
        let c = Canvas::with_size(1280.0, 800.0, Some(&atlas), 1.0);
        let semibold = c.semibold();
        let views: [(&str, StartTab, bool, bool); 8] = [
            ("home", StartTab::Home, true, false),
            ("home without a project", StartTab::Home, false, false),
            ("recent, empty", StartTab::Recent, false, false),
            ("recent tiles", StartTab::Recent, true, false),
            ("recent list", StartTab::Recent, true, true),
            ("templates", StartTab::Templates, true, false),
            ("learn", StartTab::Learn, true, false),
            ("what's new", StartTab::WhatsNew, true, false),
        ];
        let mut checked = 0;
        for (w, h) in [(640.0, 400.0), (800.0, 600.0)] {
            for (name, tab, with_recents, list) in views {
                let recents = if with_recents { vec![entry("Last", 0.0), entry("Older", 3.0)] } else { vec![] };
                let rig = rig_sized(recents, w, h);
                let at = format!("{name} at {w} x {h}");
                rig.cx(|host, cx| {
                    let mut screen = host.start.take().expect("start screen");
                    let env = host.start_env(&real, !cx.session.is_empty_untitled(), "", "");
                    screen.set_tab(tab);
                    screen.set_list_layout(list);
                    let content = screen.content_rect();
                    assert!(content.min_x() >= 0.0 && content.max_x() <= w + 0.5, "{at}: the pane is in the window");
                    let mut els = screen.pane_layout(&env).0;
                    if let Some((_, _, extra)) = screen.empty_state(&env) {
                        els.extend(extra);
                    }
                    let inside = |r: CGRect, outer: CGRect| {
                        r.min_x() >= outer.min_x() - 0.5
                            && r.max_x() <= outer.max_x() + 0.5
                            && r.min_y() >= outer.min_y() - 0.5
                            && r.max_y() <= outer.max_y() + 0.5
                    };
                    let tiles: Vec<CGRect> =
                        els.iter().filter_map(|e| if let Element::Section(_, r) = e { Some(*r) } else { None }).collect();
                    for e in &els {
                        let Some(r) = bounds_of(e) else { continue };
                        checked += 1;
                        assert!(
                            r.min_x() >= content.min_x() - 0.5 && r.max_x() <= content.max_x() + 0.5,
                            "{at}: {e:?} leaves the pane"
                        );
                        if !matches!(e, Element::Section(..)) {
                            for t in &tiles {
                                if t.contains(CGPoint::new(r.mid_x(), r.mid_y())) {
                                    assert!(inside(r, *t), "{at}: {e:?} runs out of its card {t:?}");
                                }
                            }
                        }
                        match e {
                            Element::Txt(s, r, size, _, bold) | Element::TxtC(s, r, size, _, bold) => {
                                let face = if *bold { semibold } else { 0 };
                                let width = c.size_of(s, *size, face).width;
                                assert!(
                                    width <= r.width + 0.5,
                                    "{at}: \"{s}\" ({width:.0} pt) does not fit {:.0} pt",
                                    r.width
                                );
                            }
                            Element::Wrapped(s, r, size, _) | Element::WrappedC(s, r, size, _) => {
                                let lines = c.wrap(s, r.width, *size).len() as f64;
                                assert!(
                                    lines * 16.0 <= r.height + 0.5,
                                    "{at}: \"{s}\" needs {lines} lines in {:.0} pt",
                                    r.height
                                );
                            }
                            Element::Button(s, _, r, _) => {
                                let width = c.size_of(s, m::F_LAB, 0).width;
                                assert!(width + 10.0 <= r.width + 0.5, "{at}: the button \"{s}\" is cut");
                            }
                            Element::ContinueBox(_, r) => {
                                let parts = ShellStartScreen::continue_parts(*r);
                                assert!(
                                    inside(parts.poster, *r) && inside(parts.open, *r),
                                    "{at}: the Continue box is whole"
                                );
                                assert!(
                                    parts.facts_x + parts.facts_w <= r.max_x() + 0.5,
                                    "{at}: the facts end inside the box"
                                );
                            }
                            Element::ListRow(_, r) => {
                                let col = ShellStartScreen::list_columns(*r);
                                assert!(
                                    col.name.width >= ShellStartScreen::LIST_NAME_MIN - 0.5,
                                    "{at}: the name keeps its room"
                                );
                                assert!(col.edited.is_some() || w < 700.0 || col.more.min_x() > col.name.max_x());
                            }
                            _ => {}
                        }
                    }
                    host.start = Some(screen);
                });
            }
        }
        assert!(checked > 150, "every view has parts ({checked})");
    }

    #[test]
    fn home_shows_continue_and_one_tile_per_built_in_size() {
        let rig = rig(vec![entry("Last", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::Home);
            let els = s.pane_layout(env).0;
            assert!(els.iter().any(|e| matches!(e, Element::ContinueBox(c, _) if c.name == "Last")));
            let quick: Vec<String> = els
                .iter()
                .filter_map(|e| {
                    if let Element::Quick(t, _) = e {
                        Some(t.as_ref().map_or("all".to_string(), |t| t.id.clone()))
                    } else {
                        None
                    }
                })
                .collect();
            let mut want: Vec<String> = ProjectTemplate::built_in().into_iter().map(|t| t.id).collect();
            want.push("all".into());
            assert_eq!(quick, want);
        });
    }

    #[test]
    fn only_project_commands_pass_the_keys() {
        let rig = rig(vec![entry("A", 0.0)]);
        assert!(crate::shell_start::ALLOWED_COMMANDS.contains(&EditorCommand::OpenProject));
        assert!(!crate::shell_start::ALLOWED_COMMANDS.contains(&EditorCommand::Undo));
        // Ctrl+Z reaches nothing behind the start screen.
        key(&rig, InputKey::Character('z'), InputModifiers::COMMAND);
        assert!(rig.with(|r| r.shell.is_start_shown() && r.shell.dialog().is_none()));
    }

    /// A project moved while the window is up: the click looks again, the card turns to "File not found" and the
    /// Locate… flow starts (it used to open the dead path and say "not a project"); the right-click menu offers Locate….
    #[test]
    fn a_recent_that_vanished_while_the_window_is_up_is_located_not_opened() {
        let dir = std::env::temp_dir().join(format!("sq-start-vanished-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let path = dir.join("Film.sqproj").to_string_lossy().into_owned();
        std::fs::write(&path, b"x").unwrap_or_default();
        let rig = rig(vec![RecentEntry::new(path.clone(), "Film", Timestamp::from_unix_seconds(0.0))]);
        screen(&rig, |s, env| {
            s.press(&StartHit::Card(path.clone()), CGPoint::ZERO, env);
            assert!(matches!(s.take_actions()[..], [StartAction::Open(_)]), "a project that is there opens");
        });
        std::fs::remove_file(&path).unwrap_or_default();
        screen(&rig, |s, env| {
            assert!(!s.missing.contains(&path), "nothing has looked yet");
            s.press(&StartHit::Card(path.clone()), CGPoint::ZERO, env);
            assert!(s.missing.contains(&path), "the card now says File not found");
            assert!(matches!(&s.take_actions()[..], [StartAction::Locate(p)] if *p == path));
            let menu = s.recent_menu(&path);
            assert_eq!(menu[0].title, "Locate…");
            if let Some(action) = &menu[0].action {
                action();
            }
            assert!(matches!(&s.take_actions()[..], [StartAction::Locate(p)] if *p == path));
        });
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_from_recents_saves_the_list() {
        let rig = rig(vec![entry("A", 0.0), entry("B", 0.0)]);
        let first = rig.with(|r| r.shell.recents.entries()[0].path.clone());
        let titles = screen(&rig, |s, _| s.recent_menu(&first).into_iter().map(|i| i.title).collect::<Vec<_>>());
        assert!(titles.contains(&"Remove from Recents".to_string()));
        rig.with(|r| r.shell.remove_recent(&first));
        assert_eq!(rig.with(|r| r.shell.recents.entries().iter().map(|e| e.name.clone()).collect::<Vec<_>>()), ["B"]);
        assert!(rig.with(|r| r.shell.take_events()).contains(&ShellEvent::RecentsChanged));
    }

    #[test]
    fn a_menu_pick_in_the_start_screen_applies_with_the_click_that_made_it() {
        let rig = rig(vec![entry("A", 0.0), entry("B", 0.0)]);
        let sort = screen(&rig, |s, env| s.sort_rect(env));
        click(&rig, CGPoint::new(sort.min_x() + sort.width / 2.0, sort.min_y() + sort.height / 2.0));
        assert!(rig.with(|r| r.shell.menu_bar.controller.is_open()), "the sort menu is up");
        rig.with(|r| r.shell.take_events());
        // Keys pick the row (a quick mouse release is the open click's own release and picks nothing).
        key(&rig, InputKey::Down, InputModifiers::NONE);
        key(&rig, InputKey::Down, InputModifiers::NONE);
        key(&rig, InputKey::Enter, InputModifiers::NONE);
        // No pointer move after the pick: the screen must already hold the new order, else the next frame shows the old one.
        assert_eq!(screen(&rig, |s, _| s.sort()), StartSort::Name);
        assert!(rig.with(|r| r.shell.take_events()).contains(&ShellEvent::Setting {
            key: "sq.start.sort".into(),
            value: crate::shell_host::SettingValue::Text("Name".into())
        }));
    }

    #[test]
    fn windowed_start_fills_its_own_window_and_clears_the_lights() {
        let rig = Rig::new();
        rig.with(|r| {
            r.shell.set_size(sq_uikit::controls_grid::CGSize::new(1440.0, 900.0));
            r.shell.start_window_size = Some(sq_uikit::controls_grid::CGSize::new(1100.0, 720.0));
        });
        rig.cx(|h, cx| h.show_start(cx));
        screen(&rig, |s, _| {
            assert_eq!(s.frame, CGRect::new(0.0, 0.0, 1100.0, 720.0));
            assert_eq!(s.bar_frame, None);
            assert_eq!(s.title_inset, crate::shell_start::m::LIGHTS);
        });
        // Without a project the editor window goes; the close button quits (no project behind it).
        let steps = rig.with(|r| r.shell.start_window_steps(&r.session, false, true));
        assert_eq!(steps, [StartWindowStep::ShowStart, StartWindowStep::HideEditor]);
        rig.with(|r| r.shell.editor_window_activated(&r.session));
        assert!(rig.with(|r| r.shell.is_start_shown()));
    }

    #[test]
    fn inline_start_clears_the_floating_window_buttons_only_when_asked() {
        let rig = rig(Vec::new());
        screen(&rig, |s, _| assert_eq!(s.title_inset, crate::shell_start::m::S3));
        rig.with(|r| r.shell.window_lights = true);
        rig.cx(|h, cx| h.show_start(cx));
        screen(&rig, |s, _| assert_eq!(s.title_inset, crate::shell_start::m::LIGHTS));
    }

    #[test]
    fn the_rail_has_the_appearance_link_before_feedback() {
        let rig = rig(Vec::new());
        screen(&rig, |s, _| {
            let spots = s.rail_spots();
            let a = spots.iter().find(|x| x.1 == StartHit::Appearance).expect("appearance").0;
            let f = spots.iter().find(|x| x.1 == StartHit::Feedback).expect("feedback").0;
            assert!(a.width == 24.0 && a.height == 24.0);
            assert!(a.max_x() <= f.min_x() && a.min_y() == f.min_y());
        });
    }

    #[test]
    fn the_frame_is_the_designs_rail_and_pane_on_two_point_seams() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, _| {
            let (rail, pane, status) = (s.rail_rect(), s.pane_rect(), s.status_bar());
            assert_eq!((rail.width, status.height, s.top_bar().height), (254.0, 24.0, 40.0));
            assert_eq!(pane.min_x() - rail.max_x(), 2.0, "a 2 pt seam between rail and pane");
            assert_eq!((pane.min_x(), pane.min_y() - rail.min_y(), rail.max_y() - pane.max_y()), (256.0, 2.0, 2.0));
            assert_eq!(s.frame.max_x() - pane.max_x(), 2.0);
            let new = s.rail_spots().into_iter().find(|x| x.1 == StartHit::NewProject).unwrap().0;
            assert_eq!((new.min_x(), new.min_y() - rail.min_y(), new.width, new.height), (16.0, 12.0, 222.0, 28.0));
            let tabs: Vec<f64> = s
                .rail_spots()
                .into_iter()
                .filter_map(|x| if let StartHit::Tab(_) = x.1 { Some(x.0.min_y() - rail.min_y()) } else { None })
                .collect();
            assert_eq!(tabs, [110.0, 140.0, 170.0, 200.0, 230.0]);
        });
    }

    #[test]
    fn whats_new_try_leaves_the_start_window_and_runs_the_feature_command() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::WhatsNew);
            let _ = s.take_actions();
            let last = s.whats_new.help_rows().len() - 1;
            s.press(&StartHit::Try(last), CGPoint::ZERO, env);
            let a = s.take_actions();
            assert_eq!(a.len(), 2);
            assert!(matches!(a[0], StartAction::Hide));
            assert!(matches!(a[1], StartAction::Execute(EditorCommand::Stabilize)));
        });
    }

    #[test]
    fn whats_new_dot_clears_when_the_page_is_opened_and_stays_stored() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, _env| {
            assert!(s.whats_new_unseen(), "a fresh install shows the dot");
            s.set_tab(StartTab::WhatsNew);
            assert!(!s.whats_new_unseen());
            let v = s.whats_new.version.clone();
            let stored = s.take_settings();
            assert!(stored.iter().any(|(k, val)| k == WHATS_NEW_SEEN_KEY && *val == SettingValue::Text(v.clone())));
        });
        let seen = StartSettings { whats_new_seen: Some(WhatsNew::bundled().version), ..StartSettings::default() };
        assert!(!ShellStartScreen::new(&seen).whats_new_unseen());
        let older = StartSettings { whats_new_seen: Some("0.0.1".into()), ..StartSettings::default() };
        assert!(ShellStartScreen::new(&older).whats_new_unseen());
    }

    #[test]
    fn whats_new_report_button_asks_for_the_prefilled_issue() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::WhatsNew);
            let _ = s.take_actions();
            s.press(&StartHit::ReportIssue, CGPoint::ZERO, env);
            assert!(matches!(s.take_actions()[..], [StartAction::Perform(ShellAction::ReportIssue)]));
        });
    }

    #[test]
    fn whats_new_shows_the_release_date_in_the_subtitle() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::WhatsNew);
            let want = s.whats_new.date_text();
            assert_eq!(want, "12 Nov 2026");
            let sub = s.pane_subtitle(env);
            assert!(sub.starts_with("Sequence Studio ") && sub.ends_with(&format!(" \u{b7} {want}")), "{sub}");
            // The date is not repeated in the Changes card.
            let els = s.pane_layout(env).0;
            assert!(!els.iter().any(|e| matches!(e, Element::Txt(t, ..) if *t == want)));
        });
    }

    #[test]
    fn whats_new_lists_the_tests_and_three_change_groups() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::WhatsNew);
            let els = s.pane_layout(env).0;
            let tries = els.iter().filter(|e| matches!(e, Element::Button(_, StartHit::Try(_), ..))).count();
            assert_eq!(tries, s.whats_new.help_rows().len());
            let dots = els.iter().filter(|e| matches!(e, Element::Dot(_))).count();
            assert_eq!(dots, 11, "4 new, 4 improved, 3 fixed");
            let github = els.iter().any(|e| matches!(e, Element::Button(_, StartHit::ReportIssue, ..)));
            let discord =
                els.iter().any(|e| matches!(e, Element::Button(_, StartHit::Support(SupportEntry::Discord), ..)));
            assert!(github && discord, "the feedback card reports on GitHub and opens Discord");
        });
    }

    /// The kit's feedback card leaves three text lines (48 px) and 10 px between the text and the buttons.
    #[test]
    fn whats_new_feedback_buttons_sit_below_three_text_lines() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::WhatsNew);
            let els = s.pane_layout(env).0;
            let text = els.iter().find_map(|e| match e {
                Element::Wrapped(t, r, ..) if t.starts_with("Report bugs and ideas") => Some(*r),
                _ => None,
            });
            let button = els.iter().find_map(|e| match e {
                Element::Button(_, StartHit::ReportIssue, r, ..) => Some(*r),
                _ => None,
            });
            let (Some(text), Some(button)) = (text, button) else { panic!("feedback card missing") };
            // The text rect sits 1 px lower than its layout slot so the glyphs land on the kit render's rows.
            assert!(button.min_y() - text.min_y() >= 57.0, "{} px", button.min_y() - text.min_y());
        });
    }

    #[test]
    fn learn_has_six_cards_and_two_of_them_act() {
        let rig = rig(vec![entry("A", 0.0)]);
        screen(&rig, |s, env| {
            s.set_tab(StartTab::Learn);
            let cards: Vec<(usize, CGRect)> = s
                .pane_layout(env)
                .0
                .iter()
                .filter_map(|e| if let Element::Lesson(i, r) = e { Some((*i, *r)) } else { None })
                .collect();
            assert_eq!(cards.len(), 6);
            assert!(cards.iter().all(|c| c.1.width == 258.0 && c.1.height == 156.0));
            let at = |i: usize| CGPoint::new(cards[i].1.mid_x(), cards[i].1.mid_y());
            assert_eq!(s.hit_at(at(0), env), Some(StartHit::Lesson(0)));
            assert_eq!(s.hit_at(at(1), env), Some(StartHit::Lesson(1)));
            assert_eq!(s.hit_at(at(2), env), None, "only the cards with a button act");
        });
    }

    #[test]
    fn the_whats_new_page_matches_the_design_sizes_and_wraps_long_changes() {
        let rig = rig(Vec::new());
        screen(&rig, |s, env| {
            s.set_tab(StartTab::WhatsNew);
            let els = s.pane_layout(env).0;
            let button = |label: &str| {
                els.iter().find_map(|e| match e {
                    Element::Button(l, _, r, _) if l == label => Some(*r),
                    _ => None,
                })
            };
            assert_eq!(button("Report on GitHub").map(|r| r.width), Some(142.0));
            assert_eq!(button("Open Discord").map(|r| r.width), Some(122.0));
            assert_eq!(button("Try").map(|r| (r.width, r.height)), Some((36.0, 24.0)));
            // A change line that does not fit in one line is a wrapped element taller than 16 pt, and the next
            // bullet starts below it (16 pt lines, 4 pt above and below).
            let dots: Vec<f64> =
                els.iter().filter_map(|e| if let Element::Dot(r) = e { Some(r.min_y()) } else { None }).collect();
            let texts: Vec<CGRect> = els
                .iter()
                .filter_map(|e| match e {
                    Element::Wrapped(_, r, size, _) if *size == m::F_LAB => Some(*r),
                    _ => None,
                })
                .collect();
            assert_eq!(dots.len(), texts.len(), "one wrapped text per bullet");
            let mut same_group = 0;
            for (n, r) in texts.iter().enumerate() {
                assert_eq!(r.height % 16.0, 0.0);
                if let Some(next) = dots.get(n + 1) {
                    let pitch = next - dots[n];
                    assert!(pitch >= r.height + 8.0, "the next bullet starts below the wrapped text");
                    same_group += usize::from(pitch == r.height + 8.0);
                }
            }
            // Only the step to the next group header (two of them) is larger than the line count says.
            assert_eq!(same_group, texts.len() - 3);
            assert!(texts.iter().any(|r| r.height > 16.0), "a long change wraps");
        });
    }

    #[test]
    fn the_start_type_and_badge_tokens_follow_the_design() {
        assert_eq!((m::F_LAB, m::F_CAP, m::BADGE), (12.0, 11.0, 18.0));
        assert_eq!(ShellStartScreen::open_rect(CGRect::new(0.0, 0.0, 700.0, 186.0)).width, 84.0);
    }

    #[test]
    fn the_empty_home_names_the_continue_well_and_the_size_rows_sit_372_by_44() {
        let rig = rig(Vec::new());
        screen(&rig, |s, env| {
            s.set_tab(StartTab::Home);
            let els = s.pane_layout(env).0;
            assert!(els.iter().any(|e| matches!(e, Element::Lane(r) if r.width == s.content_rect().width - 48.0 && r.height == 186.0)));
            let quick: Vec<CGRect> =
                els.iter().filter_map(|e| if let Element::Quick(_, r) = e { Some(*r) } else { None }).collect();
            assert_eq!(quick.len(), 4);
            assert!(quick.iter().all(|r| r.width == 372.0 && r.height == 44.0));
            assert_eq!(quick[1].min_x() - quick[0].min_x(), 392.0);
            assert_eq!(quick[2].min_y() - quick[0].min_y(), 56.0);
        });
    }

    #[test]
    fn drawing_the_screen_paints_every_tab() {
        let rig = rig(vec![entry("A", 0.0), entry("B", 3.0)]);
        for tab in StartTab::ALL {
            screen(&rig, |s, _| s.set_tab(tab));
            let mut c = sq_draw::Canvas::with_size(1280.0, 800.0, None, 1.0);
            rig.with(|r| r.shell.draw_overlays(&mut c, &sq_draw::DrawTheme::default(), &mut sq_draw::UiCx::new()));
            assert!(!c.list.quads().is_empty(), "{tab:?}");
        }
    }

    #[test]
    fn the_rail_link_row_ends_with_the_pink_heart() {
        let rig = rig(vec![entry("A", 0.0)]);
        let heart = screen(&rig, |s, _| {
            let spots: Vec<CGRect> = s
                .rail_spots()
                .into_iter()
                .filter(|x| x.1 == StartHit::Support(SupportEntry::Support) && x.0.width < 30.0)
                .map(|x| x.0)
                .collect();
            assert_eq!(spots.len(), 1, "one 24 pt heart in the link row");
            spots[0]
        });
        let mut c = sq_draw::Canvas::with_size(1280.0, 800.0, None, 1.0);
        rig.with(|r| r.shell.draw_overlays(&mut c, &sq_draw::DrawTheme::default(), &mut sq_draw::UiCx::new()));
        let r = sq_draw::Rect {
            x: heart.min_x() as f32,
            y: heart.min_y() as f32,
            w: heart.width as f32,
            h: heart.height as f32,
        };
        assert!(!c.list.region(r).quads().is_empty(), "the heart is drawn");
    }

    #[test]
    fn pip_peeks_over_the_support_card_on_the_first_start_too() {
        let empty = rig(vec![]);
        screen(&empty, |s, _| s.set_tab(StartTab::Home));
        assert!(screen(&empty, |s, env| s.mascot_card(env)).is_some(), "empty Home");
        screen(&empty, |s, _| s.set_tab(StartTab::Recent));
        assert!(screen(&empty, |s, env| s.mascot_card(env)).is_none(), "the empty Recent pane has its own Pip");
        let full = rig(vec![entry("A", 0.0)]);
        assert!(screen(&full, |s, env| s.mascot_card(env)).is_some());
    }

    fn button_rect(e: &Element) -> CGRect {
        match e {
            Element::Button(_, _, r, _) => *r,
            other => panic!("not a button: {other:?}"),
        }
    }

    /// D3: at 640x400 the empty Recent pane's text wraps at word boundaries (it was cut mid-word with an ellipsis), and
    /// the wrapped block stays above the buttons.
    #[test]
    fn the_empty_pane_text_wraps_at_640_by_400() {
        let rig = rig(Vec::new());
        for (w, h) in [(640.0, 400.0), (700.0, 440.0), (1280.0, 800.0)] {
            screen(&rig, |s, env| {
                s.frame = CGRect::new(0.0, 0.0, w, h);
                let (_, body, buttons) = s.empty_state(env).expect("empty pane");
                let (lines, lift) = s.empty_state_body(env, &body);
                let width = s.content_rect().width - 2.0 * crate::shell_start::m::S6;
                assert_eq!(lines.join(" "), body, "{w}x{h}: every word is drawn once, none cut");
                assert!(lines.iter().all(|l| !l.contains('\u{2026}')), "{w}x{h}: {lines:?}");
                assert!(
                    lines.iter().all(|l| env.measure.width(l, crate::shell_start::m::F_LAB, 0) <= width),
                    "{w}x{h}"
                );
                let my = s.content_rect().mid_y();
                let bottom = my - 12.0 - lift + 16.0 * lines.len() as f64;
                let top_of_buttons = buttons.iter().map(|b| button_rect(b).min_y()).fold(f64::MAX, f64::min);
                assert!(bottom <= top_of_buttons, "{w}x{h}: text ends at {bottom}, buttons start at {top_of_buttons}");
            });
        }
    }

    /// Audit P1: at the 640x400 window minimum the support card (and Pip) used to cover the tabs. Now no rail row overlaps
    /// another, with or without the card, at every height from the minimum up.
    #[test]
    fn the_rail_never_overlaps_in_a_small_window() {
        let rig = rig(vec![entry("A", 0.0)]);
        let overlap = |a: &CGRect, b: &CGRect| {
            a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
        };
        for height in (400..=900).step_by(10) {
            screen(&rig, |s, _| {
                s.frame = CGRect::new(0.0, 0.0, 640.0, height as f64);
                let mut spots: Vec<CGRect> = s.rail_spots().into_iter().map(|x| x.0).collect();
                let card = s.support_card_visible().then(|| s.support_card_rect());
                if let Some(card) = card {
                    // The Support button sits inside the card; everything else stays clear of the card and of Pip.
                    spots.retain(|r| !card.contains(CGPoint::new(r.mid_x(), r.mid_y())));
                    let pip =
                        CGRect::new(card.min_x(), card.min_y() - crate::shell_start::m::PIP_PEEK, card.width, 52.0);
                    assert!(spots.iter().all(|r| !overlap(r, &pip) && !overlap(r, &card)), "card vs rail at {height}");
                }
                for (i, a) in spots.iter().enumerate() {
                    assert!(spots[i + 1..].iter().all(|b| !overlap(a, b)), "rail rows overlap at {height}: {a:?}");
                }
                if height == 400 {
                    assert!(card.is_none(), "no room for the card at the minimum");
                    assert!(
                        s.rail_spots()
                            .iter()
                            .all(|x| x.1 != StartHit::Support(SupportEntry::Support) || x.0.width < 30.0)
                    );
                }
                if height == 900 {
                    assert!(card.is_some(), "the card is there when it fits");
                }
            });
        }
    }
}

mod new_shape_length {
    use super::*;
    use sq_core_time::Time;
    use sq_editor_session::AppSettings;

    /// The new clip's length and `seconds` snapped to the sequence's frames (the session snaps a clip to whole frames).
    fn new_clip_length(rig: &Rig, seconds: i64) -> (Option<Time>, Time) {
        rig.with(|r| r.session.add_sequence(None, None, None));
        rig.cx(|h, cx| h.perform(cx, ShellAction::NewShape(sq_core_model::ShapeKind::Rectangle)));
        rig.with(|r| {
            let t = r.session.active_timeline();
            let len = t.and_then(|t| t.tracks.iter().flat_map(|k| k.clips()).map(|c| c.duration()).next());
            (len, Time::new(seconds, 1).snapped(t.map_or(Time::new(1, 30), |t| t.frame_duration())))
        })
    }

    /// Swift ShellMenuActions `.newShape`: a host without the Create tool places the Graphic as long as the stored
    /// "New Text Length", not a fixed 5 s.
    #[test]
    fn sequence_new_shape_takes_the_stored_text_length() {
        let rig = Rig::new();
        rig.with(|r| AppSettings { default_text_seconds: 8, ..AppSettings::standard() }.save(&mut *r.shell.defaults));
        let (len, want) = new_clip_length(&rig, 8);
        assert_eq!(len, Some(want));
        assert!(want > Time::new(7, 1));
    }

    #[test]
    fn sequence_new_shape_defaults_to_five_seconds() {
        let rig = Rig::new();
        let (len, want) = new_clip_length(&rig, 5);
        assert_eq!(len, Some(want));
    }
}

/// P37: the "Locate…" button of a missing project never overlaps the name, at any list width.
#[test]
fn the_locate_button_never_overlaps_the_name_at_any_width() {
    let mut w = 300.0;
    while w <= 1400.0 {
        let r = CGRect::new(0.0, 0.0, w, 48.0);
        let col = ShellStartScreen::list_columns(r);
        let (name, button) = ShellStartScreen::locate_row_parts(&col, r);
        assert!(name.max_x() + 0.5 <= button.min_x() || name.width == 0.0, "width {w}: name {name:?} vs {button:?}");
        assert!(button.max_x() <= col.more.min_x() + 0.5, "width {w}: the button stays left of the ellipsis");
        assert!(button.min_x() >= col.name.min_x() - 0.5, "width {w}: the button stays in the row");
        w += 5.0;
    }
}

mod app_menu {
    use super::*;
    use crate::shell_app_menu::{AppMenuOutcome, AppMenuRequest, AppMenuRow};
    use crate::shell_dialog::FormValue;

    fn run(rig: &Rig) {
        rig.run_flows();
    }

    #[test]
    fn the_settings_row_follows_the_state() {
        assert!(
            AppMenuRow::Hidden.row().is_none() && AppMenuRow::Hidden.status().is_none(),
            "no row outside an AppImage"
        );
        let text = |row: AppMenuRow| match (row.row(), row.status()) {
            (Some(crate::shell_form::Row::Buttons { label, titles, .. }), Some(status)) => (label, status, titles),
            other => panic!("not a buttons row: {other:?}"),
        };
        assert_eq!(text(AppMenuRow::NotAdded), ("App menu".into(), "Not added".into(), vec!["Add…".to_string()]));
        let added = AppMenuRow::Added { file: "~/Applications/SequenceStudio.AppImage".into() };
        assert_eq!(
            text(added),
            (
                "App menu".into(),
                "Added \u{b7} ~/Applications/SequenceStudio.AppImage".into(),
                vec!["Remove…".to_string()]
            )
        );
    }

    #[test]
    fn the_remove_question_keeps_enter_on_cancel_and_reports_the_checkbox() {
        let rig = Rig::new();
        rig.cx(|h, _| h.start_flow(ShellFlow::AppMenuRemove));
        run(&rig);
        let (title, buttons, ret) = rig
            .with(|x| {
                x.shell.dialog().map(|d| {
                    (
                        d.message_text.clone(),
                        d.model.buttons.iter().map(|b| (b.title.clone(), b.role, b.leading)).collect::<Vec<_>>(),
                        d.model.return_index(),
                    )
                })
            })
            .expect("dialog");
        assert_eq!(title, "Remove from the app menu?");
        assert_eq!(
            buttons,
            vec![
                ("Remove".to_string(), sq_uikit::sqdialog_model::SQDialogRole::Destructive, true),
                ("Cancel".to_string(), sq_uikit::sqdialog_model::SQDialogRole::Cancel, false),
            ]
        );
        assert_eq!(ret, Some(1), "Enter is Cancel, never the red button");
        // Remove with the box ticked.
        rig.with(|x| {
            if let Some(f) = x.shell.dialog_mut().and_then(|d| d.form.as_mut()) {
                f.set_value("trash", FormValue::Bool(true));
            }
        });
        // The window loop's next event sweeps the finished dialog and hands its form to the flow, before the flow resumes.
        rig.with(|x| {
            if let Some(d) = x.shell.dialog_mut() {
                d.press(SQDialogResponse::FIRST);
            }
        });
        rig.cx(|h, cx| h.handle(cx, &sq_draw::InputEvent::MouseMoved { x: 0.0, y: 0.0 }, 1.0));
        rig.run_flows();
        let ev = rig.with(|x| x.shell.take_events());
        assert!(matches!(ev.as_slice(), [ShellEvent::AppMenu(AppMenuRequest::Remove { trash_file: true })]), "{ev:?}");
    }

    #[test]
    fn cancel_on_the_remove_question_asks_nothing_of_the_host_and_opens_settings_again() {
        let rig = Rig::new();
        rig.cx(|h, _| h.start_flow(ShellFlow::AppMenuRemove));
        run(&rig);
        rig.answer(SQDialogResponse::SECOND);
        assert!(rig.with(|x| x.shell.take_events()).iter().all(|e| !matches!(e, ShellEvent::AppMenu(_))));
        assert!(rig.with(|x| x.shell.take_flows()).iter().any(|f| matches!(f, ShellFlow::ShowPreferencesAt(..))));
    }

    #[test]
    fn the_result_cards_name_what_happened() {
        let rows = |o: AppMenuOutcome| {
            let d = ShellHost::app_menu_done_dialog(&o);
            (d.message_text.clone(), d.informative_text.clone(), d.model.buttons.len())
        };
        assert_eq!(
            rows(AppMenuOutcome::Removed { trashed: false }),
            ("Removed from the app menu".into(), String::new(), 1)
        );
        assert_eq!(
            rows(AppMenuOutcome::Added { file: "~/Applications/SequenceStudio.AppImage".into() }).0,
            "Added to the app menu"
        );
        let failed = rows(AppMenuOutcome::Failed {
            adding: true,
            sentence: "Your user folder didn't allow adding the menu entry. Nothing was added.".into(),
        });
        assert_eq!(failed.0, "Couldn't add to the app menu");
        assert!(failed.1.contains("Nothing was added"));
    }
}
