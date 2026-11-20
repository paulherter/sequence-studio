//! An idle window asks for no frames: no screen may keep the loop drawing once its opening animations and loads are done.
//! The start screen used to draw 60 frames/s for ever (Pip breathes without end); the same rule holds for the editor and
//! the Settings window, so a future endless animation fails here instead of burning a core.

use super::dead_commands_tests::{Scenario, demo_session};
use sq_app_shell::{AppDeps, Headless};
use sq_draw::{InputEvent, InputKey, InputModifiers};
use sq_draw_shell::ShellRoot;
use sq_editor_session::EditorSession;
use sq_runtime::FakeClock;
use std::sync::Arc;
use std::time::Duration;

/// One display refresh at 60 Hz: how far the test clock moves per loop turn.
const TICK: Duration = Duration::from_millis(16);

/// The real app root over `session`, on a clock the test moves.
fn window(session: EditorSession) -> (Headless, Arc<FakeClock>) {
    let dir = crate::test_rig::test_dir("sq-idle-window");
    std::fs::create_dir_all(&dir).expect("dir");
    let clock = Arc::new(FakeClock::new());
    let h = Headless::new(session, AppDeps::headless(Arc::clone(&clock) as _), 1280, 800);
    let root = crate::standard_root(&dir, Arc::clone(&clock) as _, sq_draw::DrawTheme::default()).expect("root");
    h.with(|a| {
        a.add_host(Box::new(root));
        a.launch();
    });
    h.turn();
    (h, clock)
}

/// Turns that drew a frame in the next `turns` turns, one display refresh apart.
fn drawn_in(h: &Headless, clock: &FakeClock, turns: usize) -> usize {
    (0..turns)
        .filter(|_| {
            clock.advance(TICK);
            h.turn().1.is_some()
        })
        .count()
}

/// A saved project: a changed one asks the loop for polls on purpose until its recovery snapshot is written, and the
/// headless session's clock stands still at 0, so that debounce would never end here.
fn saved(mut session: EditorSession) -> EditorSession {
    let path = crate::test_rig::unique_dir("sq-idle-project").join("idle.sqproj");
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    session.save_as(&path).expect("save");
    session
}

/// Plays the screen until it asks for no more frames (at most `limit` seconds of test time) and says whether it did.
fn settles(h: &Headless, clock: &FakeClock, limit: u64) -> bool {
    (0..limit * 1000 / TICK.as_millis() as u64).any(|_| {
        clock.advance(TICK);
        h.turn();
        !h.with(|a| a.needs_redraw()).unwrap_or(true)
    })
}

fn assert_idle(h: &Headless, clock: &FakeClock, what: &str) {
    assert!(settles(h, clock, 30), "{what}: still asking for frames 30 s after it opened");
    assert_eq!(drawn_in(h, clock, 300), 0, "{what}: drew frames while idle (5 s at 60 Hz)");
    assert_eq!(h.with(|a| a.needs_redraw()), Some(false), "{what}: wants a frame while idle");
}

#[test]
fn the_start_screen_plays_pip_at_first_then_asks_for_no_frames() {
    let (h, clock) = window(super::tests::session());
    assert_eq!(h.with(|a| a.shell_parts().shell.is_start_shown()), Some(true));
    assert!(drawn_in(&h, &clock, 60) > 30, "Pip plays while the screen is new");
    assert_idle(&h, &clock, "start screen");
}

#[test]
fn input_wakes_pip_on_the_start_screen_and_he_settles_again() {
    let (h, clock) = window(super::tests::session());
    assert_idle(&h, &clock, "start screen");
    h.input(&InputEvent::MouseMoved { x: 400.0, y: 300.0 });
    assert!(drawn_in(&h, &clock, 60) > 30, "Pip plays again after the pointer moved");
    assert_idle(&h, &clock, "start screen after input");
}

#[test]
fn an_idle_editor_asks_for_no_frames() {
    let (h, clock) = window(saved(demo_session(Scenario::Plain)));
    assert_eq!(h.with(|a| a.shell_parts().shell.is_start_shown()), Some(false));
    assert_idle(&h, &clock, "editor");
}

#[test]
fn an_idle_settings_window_asks_for_no_frames() {
    let (h, clock) = window(saved(demo_session(Scenario::Plain)));
    h.input(&InputEvent::KeyDown { key: InputKey::Character(','), modifiers: InputModifiers::COMMAND });
    assert!(drawn_in(&h, &clock, 10) > 0);
    assert_eq!(h.with(|a| a.shell_parts().shell.dialog().is_some()), Some(true), "Ctrl+, opens Settings");
    assert_idle(&h, &clock, "Settings");
}
