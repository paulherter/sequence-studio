//! Program monitor events that used to end as "not available here yet": the wheel zoom, which the card shows itself, and the
//! "..." menu's Safe Margins row (Swift `MonitorHost`: `model.safeMargins.toggle()`).

use super::tests::{root, session};
use super::*;
use sq_draw::monitor::monitor_modes::MonitorAction;

fn statuses(rig: &crate::test_rig::Rig) -> Vec<String> {
    rig.events.iter().filter_map(|e| if let AppEvent::Status(l) = e { Some(l.clone()) } else { None }).collect()
}

fn armed() -> (AppRoot, crate::test_rig::Rig) {
    let mut s = session();
    s.add_sequence(None, None, None);
    let mut rig = crate::test_rig::Rig::new(s);
    let mut r = root();
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.sync(&rig.session);
    (r, rig)
}

#[test]
fn a_wheel_zoom_on_the_program_picture_gives_no_status_line() {
    let (mut r, mut rig) = armed();
    r.monitor.panel.zoom_gesture(sq_core_edit::viewer_zoom::ViewerZoom::Percent(200));
    r.handle(&InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(statuses(&rig).iter().all(|l| !l.contains("not available")), "{:?}", statuses(&rig));
}

#[test]
fn the_safe_margins_row_toggles_the_overlay() {
    let (mut r, mut rig) = armed();
    let before = r.monitor.panel.model.safe_margins();
    r.monitor.panel.model.perform(MonitorAction::ToggleSafeMargins);
    r.handle(&InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert_eq!(r.monitor.panel.model.safe_margins(), !before);
    assert!(statuses(&rig).iter().all(|l| !l.contains("not available")), "{:?}", statuses(&rig));
}

#[test]
fn a_job_line_shows_in_the_status_bar_and_full_screen_and_presets_events_say_nothing() {
    use sq_draw_shell::ShellEvent;
    let (mut r, mut rig) = armed();
    for e in [ShellEvent::FullScreen(true), ShellEvent::PresetsChanged, ShellEvent::Job(Some("Anonymize: 42 %".into()))]
    {
        r.shell.deferred.push(crate::ShellDeferred::Event(e));
    }
    r.answer(&mut rig.cx());
    assert!(statuses(&rig).iter().all(|l| !l.contains("not available")), "{:?}", statuses(&rig));
    assert_eq!(r.chrome.job_line(), Some("Anonymize: 42 %"));
    r.shell.deferred.push(crate::ShellDeferred::Event(ShellEvent::Job(None)));
    r.answer(&mut rig.cx());
    assert_eq!(r.chrome.job_line(), None);
}
