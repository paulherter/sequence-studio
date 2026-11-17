//! No command or menu row of the real root ends in "Not available on Windows yet." / "…in the shared UI yet.": each
//! one either runs or is disabled with a reason. The command walk is in `dead_commands_tests.rs`; this file walks the
//! menu rows of every platform profile and checks the services the flows ask for.

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use sq_draw_shell::{ShellAction, ShellMenuBar, ShellMenuState};
use sq_os::Platform;
use sq_runtime::FakeClock;
use sq_uikit::command_map::CommandMap;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind};
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

/// Menu rows that may end in the not-available text because the platform really lacks the feature, with the reason.
const PLATFORM_LIMITED: [(&str, &str); 4] = [
    (
        "Hide",
        "Mac app menu: the system's own Hide runs from the system menu bar (`use_system_bar`); the row is Mac only",
    ),
    ("HideOthers", "Mac app menu: the system's own Hide Others"),
    ("ShowAll", "Mac app menu: the system's own Show All"),
    ("BringAllToFront", "Mac Window menu: the system's own Bring All to Front"),
];

/// Both texts, so one walk covers every platform profile.
const TEXTS: [&str; 2] = ["Not available on Windows yet.", "Not available in the shared UI yet."];

pub(super) fn said_not_available(rig: &crate::test_rig::Rig) -> bool {
    rig.events.iter().any(|e| matches!(e, AppEvent::Status(l) if TEXTS.contains(&l.as_str())))
}

fn root_in(tag: &str) -> (AppRoot, std::path::PathBuf) {
    let dir = crate::test_rig::unique_dir(tag);
    std::fs::create_dir_all(&dir).expect("dir");
    let root = crate::standard_root_with_source(
        &dir,
        Arc::new(FakeClock::new()),
        DrawTheme::default(),
        crate::MonitorPicture::default(),
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
    )
    .expect("root");
    // The app's own composition (sequence-studio main.rs) hands the root the FFmpeg probe; a fake stands in here.
    let root = root.with_conform(Arc::new(|p| Err(format!("fake probe {}", p.display()))));
    (root, dir)
}

fn collect(items: &[SQMenuItem], into: &mut Vec<String>, rows: &mut usize) {
    for i in items {
        if let Some(sub) = &i.submenu {
            collect(sub, into, rows);
        } else if i.kind == SQMenuItemKind::Action && i.is_enabled {
            *rows += 1;
            if let Some(a) = &i.action {
                a();
            }
            into.push(i.title.clone());
        }
    }
}

#[test]
fn no_menu_row_of_any_platform_ends_in_the_not_available_text() {
    let map = CommandMap::premiere_default();
    for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
        let queued: Rc<RefCell<Vec<ShellAction>>> = Rc::default();
        let sink = Rc::clone(&queued);
        let menus = ShellMenuBar::build(
            &ShellMenuState::default(),
            &map,
            platform,
            None,
            Rc::new(move |a| sink.borrow_mut().push(a)),
        );
        let (mut titles, mut rows) = (Vec::new(), 0);
        for m in &menus {
            collect(&m.items, &mut titles, &mut rows);
        }
        let actions: Vec<ShellAction> = queued.borrow().clone();
        assert!(rows > 100 && actions.len() > 20, "{platform:?}: only {rows} rows, {} actions", actions.len());
        let mut said = Vec::new();
        for a in actions {
            // A row that opens a dialog or starts a flow leaves the root before the next one.
            let (mut root, dir) = root_in("sq-not-available-menu");
            let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain));
            root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
            root.shell.perform_action(&mut rig.cx(), a.clone());
            let mut lines = Vec::new();
            root.answer_timeline(&mut rig.cx(), &mut lines);
            root.pump(&mut rig.cx());
            if said_not_available(&rig) && !PLATFORM_LIMITED.iter().any(|(n, _)| format!("{a:?}") == *n) {
                said.push(format!("{a:?}"));
            }
            let _ = std::fs::remove_dir_all(&dir);
        }
        assert!(said.is_empty(), "{platform:?}: menu rows that end in the not-available text: {said:?}");
    }
}

#[test]
fn add_title_runs_on_the_real_root() {
    use sq_uikit::editor_command::EditorCommand as C;
    let (mut root, dir) = root_in("sq-not-available-title");
    let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    assert!(root.shell.shell().flow_env.services.look_store().is_some(), "the services hold the Looks");
    let titles = |rig: &crate::test_rig::Rig| {
        rig.session.active_timeline().map_or(0, |t| t.tracks.iter().flat_map(|t| t.clips()).count())
    };
    let before = titles(&rig);
    assert!(root.shell.run_command(&mut rig.cx(), C::AddTitle));
    assert!(!said_not_available(&rig), "{:?}", rig.events);
    assert!(titles(&rig) > before, "a title clip was added");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_services_give_the_flows_a_probe_and_a_preset_store() {
    let (mut root, dir) = root_in("sq-not-available-services");
    let services = &mut root.shell.shell().flow_env.services;
    assert!(services.preset_store().is_some(), "Premiere presets and .mogrt files import into the user library");
    let mut ask = services.probe(std::path::Path::new("/nowhere/a.mov")).expect("a probe");
    let mut session = demo_session(Scenario::Plain);
    let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let answer = loop {
        services.pump(&mut session);
        if let std::task::Poll::Ready(a) = std::pin::Pin::new(&mut ask).poll(&mut cx) {
            break a;
        }
        assert!(std::time::Instant::now() < deadline, "the probe never answered");
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    assert!(answer.is_none(), "the fake probe could not read the file");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn show_captions_follows_the_view_switch() {
    use sq_uikit::editor_command::EditorCommand as C;
    let (mut root, dir) = root_in("sq-not-available-captions");
    let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    assert!(root.shell.run_command(&mut rig.cx(), C::ToggleCaptionsInMonitor));
    assert!(!said_not_available(&rig), "{:?}", rig.events);
    let _ = std::fs::remove_dir_all(&dir);
}
