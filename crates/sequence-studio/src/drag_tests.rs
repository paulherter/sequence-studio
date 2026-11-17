//! Replays a winit-like pointer sequence through the same translation and loop turns the window uses.

use crate::input::Pointer;
use sq_app_shell::{AppDeps, Headless};
use sq_core_time::{Id, SequentialIds, Time};
use sq_draw::{DrawTheme, InputModifiers};
use sq_editor_session::EditorSession;
use sq_runtime::{Clock, SystemClock};
use std::sync::Arc;
use winit::event::{ElementState, MouseButton};

fn session(support: &std::path::Path) -> EditorSession {
    let (mut s, _) = crate::untitled_session(support);
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        t.tracks[0].is_targeted = true;
        for (n, start) in [(1u128, 0), (2, 3)] {
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
    s
}

fn starts(h: &Headless) -> Vec<Time> {
    h.with(|a| {
        a.session().active_timeline().map_or(Vec::new(), |t| t.tracks[0].clips().iter().map(|c| c.start).collect())
    })
    .unwrap_or_default()
}

/// One winit turn: the event reaches the app, then the loop runs (`about_to_wait`).
fn send(h: &Headless, e: &sq_draw::InputEvent) {
    h.input(e);
    h.turn();
}

fn drag_at(scale: f32, from: (f64, f64)) -> bool {
    let (w, hgt) = ((1440.0 * scale) as i64, (900.0 * scale) as i64);
    let support = std::env::temp_dir().join(format!("sq-drag-test-{}-{scale}", std::process::id()));
    std::fs::create_dir_all(&support).expect("dir");
    let clock = Arc::new(SystemClock::new());
    let mut deps = AppDeps::headless(Arc::clone(&clock) as Arc<dyn Clock>);
    deps.theme = DrawTheme { scale, ..DrawTheme::default() };
    let theme = deps.theme;
    let h = Headless::new(session(&support), deps, w, hgt);
    crate::add_root(&h, clock, theme, &support, Default::default(), sq_editor_session::WorkspacePage::Edit);
    h.turn();
    let before = starts(&h);
    let mut p = Pointer::default();
    send(&h, &p.moved(from.0, from.1, InputModifiers::NONE));
    for e in p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE) {
        send(&h, &e);
    }
    for i in 1..=10 {
        send(&h, &p.moved(from.0 + f64::from(i) * 8.0 * f64::from(scale), from.1, InputModifiers::NONE));
    }
    for e in p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE) {
        send(&h, &e);
    }
    starts(&h) != before
}

#[test]
fn a_winit_style_drag_moves_a_timeline_clip() {
    for scale in [1.0_f32, 2.0] {
        // The timeline sits in the lower part of the window: probe a row of points over it.
        let moved = (0..40).any(|i| {
            let y = (560.0 + f64::from(i) * 8.0) * f64::from(scale);
            (200..1200).step_by(100).any(|x| drag_at(scale, (f64::from(x) * f64::from(scale), y)))
        });
        assert!(moved, "no clip moved at scale {scale}");
    }
}

/// Turns of an idle editor that still ask for a frame, after the first frames settled.
fn idle_frames(turns: usize) -> (usize, Headless) {
    let support = std::env::temp_dir().join(format!("sq-idle-test-{}", std::process::id()));
    std::fs::create_dir_all(&support).expect("dir");
    let clock = Arc::new(SystemClock::new());
    let deps = AppDeps::headless(Arc::clone(&clock) as Arc<dyn Clock>);
    let theme = deps.theme;
    let h = Headless::new(session(&support), deps, 1440, 900);
    crate::add_root(&h, clock, theme, &support, Default::default(), sq_editor_session::WorkspacePage::Edit);
    for _ in 0..30 {
        h.turn();
    }
    // Opening fades of the first frames (140 ms) must be over before idleness is measured.
    std::thread::sleep(std::time::Duration::from_millis(300));
    for _ in 0..3 {
        h.turn();
    }
    // The demo project starts changed: its recovery snapshot is written after the 1 s debounce, and until then the loop
    // asks for polls on purpose (an idle window has no other wake). Wait that out, then measure idleness.
    for _ in 0..200 {
        std::thread::sleep(std::time::Duration::from_millis(25));
        h.turn();
        if !h.with(|a| a.needs_redraw()).unwrap_or(true) {
            break;
        }
    }
    let mut drawn = 0;
    for _ in 0..turns {
        drawn += usize::from(h.turn().1.is_some());
    }
    (drawn, h)
}

#[test]
fn an_idle_editor_asks_for_no_frames() {
    let (drawn, h) = idle_frames(100);
    assert_eq!(drawn, 0, "idle turns drew frames");
    assert!(!h.with(|a| a.needs_redraw()).unwrap_or(true));
}

#[test]
fn a_finished_job_wakes_exactly_one_frame() {
    let (_, h) = idle_frames(0);
    let tx = h.with(|a| a.sender()).expect("sender");
    tx.send(sq_app_shell::AppMessage::Post(Box::new(|_| {})));
    // The message wakes a frame; a dialog that opens in it fades in over 140 ms (real frames, then it parks). Turn on a
    // 10 ms grid for 600 ms: the first turn draws, and the last 300 ms draw nothing.
    let drawn: Vec<bool> = (0..60)
        .map(|_| {
            std::thread::sleep(std::time::Duration::from_millis(10));
            h.turn().1.is_some()
        })
        .collect();
    assert!(drawn[0], "the finished job woke a frame");
    assert!(drawn[30..].iter().all(|d| !d), "the loop parked after the frame and any opening fade");
}

#[test]
fn playback_keeps_requesting_frames() {
    let (_, h) = idle_frames(0);
    h.with(|a| a.session_mut().play_pause());
    let drawn: usize = (0..20).map(|_| usize::from(h.turn().1.is_some())).sum();
    assert_eq!(drawn, 20, "every turn of a playing app draws");
    h.with(|a| a.session_mut().play_pause());
    h.turn();
    assert!(!h.with(|a| a.needs_redraw()).unwrap_or(true), "paused: idle again");
}
