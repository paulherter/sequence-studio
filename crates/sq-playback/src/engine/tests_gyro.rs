// SPDX-License-Identifier: GPL-3.0-or-later
//! A stabilized clip is prepared when the timeline arrives and is never shown unwarped while its data loads.

use super::handle::GyroHook;
use super::testkit::{Rig, clip, id, timeline};
use sq_core_masks::stabilize_effect::{GyroflowOptions, STABILIZE_KIND, STABILIZE_METHOD_KEY};
use sq_core_model::{AnimatedProperty, ClipEffect};
use sq_core_time::Id;
use sq_render::program::{GyroMaps, GyroReadiness, WarpMap};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Default)]
struct Fake {
    ready: Mutex<bool>,
    prepared: AtomicUsize,
    /// The largest `limit` any readiness ask carried (the render loop never waits inside the engine).
    longest_limit: Mutex<Duration>,
    observers: Mutex<Vec<Arc<dyn Fn() + Send + Sync>>>,
}

impl GyroMaps for Fake {
    fn prepare(&self, _: &str, _: &GyroflowOptions) {
        self.prepared.fetch_add(1, Ordering::SeqCst);
    }
    fn readiness(&self, _: &str, _: &GyroflowOptions, limit: Duration) -> GyroReadiness {
        let mut l = self.longest_limit.lock().unwrap();
        *l = (*l).max(limit);
        drop(l);
        if *self.ready.lock().unwrap() { GyroReadiness::Ready } else { GyroReadiness::Loading }
    }
    fn map(&self, _: &str, _: &GyroflowOptions, _: i64, _: bool) -> Option<Arc<WarpMap>> {
        (*self.ready.lock().unwrap()).then(|| Arc::new(WarpMap::identity(2, 2)))
    }
    fn add_observer(&self, f: Arc<dyn Fn() + Send + Sync>) {
        self.observers.lock().unwrap().push(f);
    }
}

#[test]
fn nothing_is_shown_while_gyro_data_loads_and_the_first_frame_shows_once_it_is_ready() {
    let fake = Arc::new(Fake::default());
    let hook = GyroHook { maps: Arc::<Fake>::clone(&fake), wait: false };
    let rig = Rig::new(move |d| d.gyro = Some(hook));
    rig.opener.add("a.mov", 50, Duration::from_millis(1));
    rig.media(&[(id(1), "a.mov")]);
    let mut c = clip(10, id(1), 0, 0, 2);
    let mut e = ClipEffect::new(Id::from_u128(99), STABILIZE_KIND);
    e.parameters.insert(STABILIZE_METHOD_KEY.into(), AnimatedProperty::new(1.0));
    c.effects.push(e);
    rig.handle.set_timeline(timeline(vec![vec![c]]), HashMap::new());
    let seen = Arc::clone(&fake);
    rig.wait("the analysis starts when the timeline arrives", move |_| seen.prepared.load(Ordering::SeqCst) >= 1);
    rig.wait("the gate holds the frame", |e| e.gyro_waiting());
    assert!(rig.handle.latest_shown().is_none(), "no picture is shown before the data is ready");
    *fake.ready.lock().unwrap() = true;
    for f in fake.observers.lock().unwrap().clone() {
        f();
    }
    rig.wait("the frame is composed", |e| !e.gyro_waiting());
    rig.wait("the frame is shown", |e| e.compose_calls() > 1);
    assert!(rig.handle.latest_shown().is_some(), "the first frame shows once the data is ready");
}

fn stabilized(n: u128, media: Id, at: i64, dur: i64) -> sq_core_model::Clip {
    let mut c = clip(n, media, 0, at, dur);
    let mut e = ClipEffect::new(Id::from_u128(n + 900), STABILIZE_KIND);
    e.parameters.insert(STABILIZE_METHOD_KEY.into(), AnimatedProperty::new(1.0));
    c.effects.push(e);
    c
}

fn fire(fake: &Fake) {
    for f in fake.observers.lock().unwrap().clone() {
        f();
    }
}

#[test]
fn the_render_loop_never_sleeps_for_the_gate_and_still_takes_commands_while_it_waits() {
    let fake = Arc::new(Fake::default());
    let hook = GyroHook { maps: Arc::<Fake>::clone(&fake), wait: false };
    let rig = Rig::new(move |d| d.gyro = Some(hook));
    rig.opener.add("a.mov", 50, Duration::from_millis(1));
    rig.media(&[(id(1), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![stabilized(10, id(1), 0, 2)]]), HashMap::new());
    rig.wait("the gate holds the frame", |e| e.gyro_waiting());
    // A command reaches the loop at once (the loop is not asleep inside the gate), also a Stop-like pause and a seek.
    rig.handle.seek(sq_core_time::Time::seconds(1));
    rig.handle.pause();
    rig.handle.sync();
    assert_eq!(*fake.longest_limit.lock().unwrap(), Duration::ZERO, "the gate looks, it does not wait");
    assert!(rig.handle.query(|e| e.gyro_waiting()).unwrap_or(false), "still holding after the commands");
}

#[test]
fn entering_a_loading_stabilized_clip_mid_play_holds_the_clock_and_the_sound_until_it_is_ready() {
    use sq_audio_out::clock::{ManualClock, PlaybackClock};
    use sq_core_time::Time;
    let fake = Arc::new(Fake::default());
    let hook = GyroHook { maps: Arc::<Fake>::clone(&fake), wait: false };
    let clock = Arc::new(ManualClock::default());
    let c = Arc::clone(&clock);
    let rig = Rig::new(move |d| {
        d.gyro = Some(hook);
        d.clock = c as Arc<dyn PlaybackClock>;
    });
    rig.opener.add("a.mov", 250, Duration::from_millis(1));
    rig.opener.add("b.mov", 250, Duration::from_millis(1));
    rig.media(&[(id(1), "a.mov"), (id(2), "b.mov")]);
    rig.handle
        .set_timeline(timeline(vec![vec![clip(10, id(1), 0, 0, 2), stabilized(11, id(2), 2, 4)]]), HashMap::new());
    rig.handle.seek(Time::ZERO);
    rig.handle.sync();
    rig.handle.play(sq_core_edit::playback::PlaybackRate::FORWARD);
    let end = std::time::Instant::now() + Duration::from_secs(10);
    while clock.rate().is_paused() && std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!clock.rate().is_paused(), "the clip before runs");
    clock.advance(Time::new(55, 25)); // 2.2 s: inside the loading clip
    let end = std::time::Instant::now() + Duration::from_secs(10);
    while !clock.rate().is_paused() && std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(clock.rate().is_paused(), "clock and sound hold while the data loads");
    let held_at = clock.now();
    clock.advance(Time::new(100, 25)); // wall time passes: the held clock must not move
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(clock.now(), held_at, "A/V stay in sync: nothing advances while held");
    assert!(held_at >= Time::new(50, 25), "held inside the stabilized clip, not before it: {held_at:?}");
    *fake.ready.lock().unwrap() = true;
    fire(&fake);
    let end = std::time::Instant::now() + Duration::from_secs(10);
    while clock.rate().is_paused() && std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!clock.rate().is_paused(), "the clock runs again once the picture is composed");
    assert!(clock.now() >= held_at, "it resumes at the hold position, not behind it");
}
