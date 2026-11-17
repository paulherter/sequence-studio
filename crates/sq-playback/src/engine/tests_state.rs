// SPDX-License-Identifier: GPL-3.0-or-later
//! The engine's lifecycle through the real render thread: `EngineState` moves only through `transition`, and a compositor
//! that cannot be created is a visible failure, not a silent black picture.

use super::state::EngineState;
use super::testkit::{Rig, clip, id, timeline};
use sq_core_edit::playback::PlaybackRate;
use std::collections::HashMap;

fn state(rig: &Rig) -> EngineState {
    rig.handle.query(|e| e.state()).expect("the engine answers")
}

#[test]
fn play_pause_and_scrub_walk_the_state_machine() {
    let rig = Rig::new(|_| {});
    // A long clip: playing past the end would pause by itself.
    rig.handle.set_timeline(timeline(vec![vec![clip(10, id(1), 0, 0, 100_000)]]), HashMap::new());
    assert_eq!(state(&rig), EngineState::Paused);
    rig.handle.play(PlaybackRate::FORWARD);
    assert_eq!(state(&rig), EngineState::Playing(PlaybackRate::FORWARD));
    rig.handle.begin_scrub();
    assert_eq!(state(&rig), EngineState::Scrubbing, "a scrub stops playing");
    rig.handle.play(PlaybackRate::FORWARD);
    assert_eq!(state(&rig), EngineState::Playing(PlaybackRate::FORWARD), "play ends the scrub");
    rig.handle.end_scrub();
    assert_eq!(
        state(&rig),
        EngineState::Playing(PlaybackRate::FORWARD),
        "end of a scrub that is not running is ignored"
    );
    rig.handle.pause();
    assert_eq!(state(&rig), EngineState::Paused);
    rig.handle.begin_scrub();
    rig.handle.end_scrub();
    assert_eq!(state(&rig), EngineState::Paused);
}

#[test]
fn a_compositor_that_cannot_be_created_is_reported_once_and_stays_failed() {
    let rig = Rig::new(|_| {});
    assert_eq!(rig.handle.status().compositor_failure, None);
    rig.handle.query(|e| e.ensure_compositor(|| Err("no adapter".to_string())));
    rig.wait("the failure is published", |e| e.compositor_failure().is_some());
    let status = loop {
        let s = rig.handle.status();
        if s.compositor_failure.is_some() {
            break s;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    assert_eq!(status.compositor_failure.as_deref(), Some("no adapter"));
    assert_eq!(status.last_error.as_deref(), Some("compositor: no adapter"));
    // A second ask never runs the factory again.
    rig.handle.query(|e| e.ensure_compositor(|| panic!("a failed compositor is not retried")));
    assert_eq!(
        rig.handle.query(|e| e.compositor_failure().map(str::to_string)).flatten().as_deref(),
        Some("no adapter")
    );
}
