// SPDX-License-Identifier: GPL-3.0-or-later
//! The engine's own play range and loop, on a manual clock: the clock wraps at the loop's end and keeps its overshoot, so
//! the audio timeline has no gap (Swift `RenderLoop.locksFramePhase`).

use super::testkit::*;
use sq_audio_out::clock::{ManualClock, PlaybackClock};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::{Time, TimeRange};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

fn rig(clock: &Arc<ManualClock>) -> Rig {
    let c = Arc::clone(clock);
    let rig = Rig::new(move |d| d.clock = c as Arc<dyn PlaybackClock>);
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(id(100), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, id(100), 0, 0, 8)]]), HashMap::new());
    rig
}

/// Plays from `from` with the clock released (the first picture is up), then waits for the engine to be at that position.
fn playing(rig: &Rig, clock: &ManualClock, from: Time) {
    rig.handle.seek(from);
    rig.wait("the first frame", move |e| e.position() == from && e.is_frame_settled());
    rig.handle.play(PlaybackRate::FORWARD);
    let end = std::time::Instant::now() + Duration::from_secs(5);
    while clock.rate().is_paused() && std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!clock.rate().is_paused(), "the clock started");
}

fn wait_until(what: &str, cond: impl Fn() -> bool) {
    let end = std::time::Instant::now() + Duration::from_secs(5);
    while !cond() && std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(cond(), "timed out waiting for {what}");
}

#[test]
fn a_loop_wraps_the_clock_to_in_and_keeps_the_overshoot() {
    let clock = Arc::new(ManualClock::default());
    let rig = rig(&clock);
    let range = TimeRange::from_end(Time::seconds(1), Time::seconds(2));
    rig.handle.set_play_range(Some(range));
    rig.handle.set_loops(true);
    rig.handle.sync();
    playing(&rig, &clock, Time::new(9, 5));
    // Run 0.3 s past Out: the clock continues at In plus those 0.3 s, still playing forward.
    clock.advance(Time::new(5, 10));
    wait_until("the wrap", || clock.now() < Time::seconds(2));
    assert_eq!(clock.now(), Time::new(13, 10), "In + overshoot, no gap");
    assert!(clock.rate().is_forward());
    assert!(rig.handle.status().rate.is_some_and(PlaybackRate::is_forward), "the engine keeps playing");
    // A second round wraps again, exactly at Out.
    clock.advance(Time::new(2, 10));
    std::thread::sleep(Duration::from_millis(50));
    clock.advance(Time::new(5, 10));
    wait_until("the second wrap", || clock.now() < Time::new(15, 10));
    assert_eq!(clock.now(), Time::seconds(1));
}

#[test]
fn a_loop_without_a_range_wraps_at_the_sequence_end() {
    let clock = Arc::new(ManualClock::default());
    let rig = rig(&clock);
    rig.handle.set_loops(true);
    rig.handle.sync();
    playing(&rig, &clock, Time::seconds(7));
    clock.advance(Time::new(11, 10));
    wait_until("the wrap", || clock.now() < Time::seconds(8));
    assert_eq!(clock.now(), Time::new(1, 10));
    assert!(rig.handle.status().rate.is_some_and(PlaybackRate::is_forward));
}

#[test]
fn play_from_behind_the_loop_end_starts_at_in() {
    let clock = Arc::new(ManualClock::default());
    let rig = rig(&clock);
    rig.handle.set_play_range(Some(TimeRange::from_end(Time::seconds(1), Time::seconds(2))));
    rig.handle.set_loops(true);
    rig.handle.sync();
    rig.handle.seek(Time::seconds(5));
    rig.handle.play(PlaybackRate::FORWARD);
    wait_until("the clock", || !clock.rate().is_paused());
    assert_eq!(clock.now(), Time::seconds(1));
}

#[test]
fn without_a_loop_the_clock_runs_on_past_the_range() {
    let clock = Arc::new(ManualClock::default());
    let rig = rig(&clock);
    rig.handle.set_play_range(Some(TimeRange::from_end(Time::seconds(1), Time::seconds(2))));
    rig.handle.sync();
    playing(&rig, &clock, Time::new(9, 5));
    clock.advance(Time::new(12, 10));
    std::thread::sleep(Duration::from_millis(100));
    // The host (the session) stops at Out; the engine only bounds the lead.
    assert_eq!(clock.now(), Time::new(30, 10));
}

/// L, L, L while playing: every further play at another rate must re-anchor the running clock at that rate (the
/// session sends `play(rate)` again, it never pauses in between).
#[test]
fn a_play_at_another_rate_while_playing_moves_the_clock_at_that_rate() {
    let clock = Arc::new(ManualClock::default());
    let rig = rig(&clock);
    playing(&rig, &clock, Time::seconds(1));
    assert_eq!(clock.rate(), PlaybackRate::FORWARD);
    for n in [2, 4, -2] {
        let want = PlaybackRate::whole(n);
        rig.handle.play(want);
        wait_until("the clock rate", || clock.rate() == want);
        assert_eq!(rig.handle.status().rate, Some(want), "the engine reports {n}x");
    }
}
