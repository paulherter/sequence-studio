// SPDX-License-Identifier: GPL-3.0-or-later
//! A stabilized layer is never composed unwarped: before its frame is drawn the clip's gyro data is awaited (bounded).
//! The analysis itself starts when the timeline or media arrive (`prepare_gyro`), so the wait is normally zero.

use super::handle::GyroHook;
use sq_core_masks::stabilize_effect::GyroflowOptions;
use sq_render::program::{GyroReadiness, WarpMap};
use std::sync::Arc;
use std::time::Duration;

use sq_core_masks::stabilize_effect::ClipStabilizeExt;
use sq_core_model::Timeline;
use sq_core_time::Id;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

/// The first 0.5 s of a wait is the allowed pre-roll; it is measured (never slept), so the render loop keeps running.
pub const GYRO_FIRST_WAIT: Duration = Duration::from_millis(500);
/// A clip whose data is not ready this long after the first ask counts as failed (shows the original, with a warning).
pub const GYRO_GIVE_UP: Duration = Duration::from_secs(10);

/// What the compositor does before it draws a stabilized layer.
#[derive(Debug, PartialEq, Eq)]
pub enum GyroGate {
    /// Compose now (ready, or not a stabilized layer).
    Go,
    /// The data is still loading: draw nothing new, the playhead and the clock hold, the engine's observer (or the next
    /// tick) looks again. The gate never sleeps.
    Wait,
    /// No data will come (failed, or no result in time): compose with the original and report `why`.
    Failed(String),
}

/// Per clip file and analysis generation: when its data was first asked for. A replaced analysis (Analyze Again after a
/// failure) is a new generation and starts its wait from zero.
pub struct GyroWatch {
    since: Mutex<HashMap<(String, u64), Instant>>,
    give_up: Duration,
}

impl Default for GyroWatch {
    fn default() -> Self {
        GyroWatch::new(GYRO_GIVE_UP)
    }
}

impl GyroWatch {
    pub fn new(give_up: Duration) -> GyroWatch {
        GyroWatch { since: Mutex::new(HashMap::new()), give_up }
    }

    /// How long this clip's data has been waited for (None = not waiting).
    pub fn waited(&self, path: &str, generation: u64) -> Option<Duration> {
        self.map().get(&(path.to_string(), generation)).map(Instant::elapsed)
    }

    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<(String, u64), Instant>> {
        self.since.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Playback: may the layer of `path` with `o` be composed now? Looks at once, never sleeps: while the data loads the
    /// answer is `Wait`, and the caller asks again next tick.
    pub fn check(&self, hook: &GyroHook, path: &str, o: &GyroflowOptions) -> GyroGate {
        if hook.wait {
            return GyroGate::Go;
        }
        let readiness = hook.maps.readiness(path, o, Duration::ZERO);
        let key = (path.to_string(), hook.maps.generation(path, o));
        let gate = match readiness {
            GyroReadiness::Ready => GyroGate::Go,
            GyroReadiness::Failed(why) => GyroGate::Failed(why),
            GyroReadiness::Loading => {
                let since = *self.map().entry(key.clone()).or_insert_with(Instant::now);
                if since.elapsed() >= self.give_up {
                    GyroGate::Failed(format!("no gyro data after {} s", self.give_up.as_secs()))
                } else {
                    GyroGate::Wait
                }
            }
        };
        if gate != GyroGate::Wait {
            self.map().remove(&key);
        }
        gate
    }

    /// Forgets every wait whose clip is no longer asked for (the playhead left it, a new analysis replaced it).
    pub fn retain_asked(&self, asked: &[(String, u64)]) {
        self.map().retain(|k, _| asked.contains(k));
    }
}

/// The media and options of every stabilized clip of these timelines (the top sequence and the nested ones).
pub fn stabilized_media<'a>(timelines: impl IntoIterator<Item = &'a Timeline>) -> Vec<(Id, GyroflowOptions)> {
    timelines
        .into_iter()
        .flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter()))
        .filter_map(|c| c.gyroflow_options().map(|o| (c.media, o)))
        .collect()
}

/// What a stabilized layer shows once the gate let it through. Export (`hook.wait`) blocks inside `map`.
#[derive(Debug, PartialEq)]
pub enum GyroOutcome {
    /// Warp with this map.
    Warped(Arc<WarpMap>),
    /// No map (data still loading after the give-up, canceled, or failed): the original shows.
    Original,
}

/// The map of one frame of a stabilized layer (looks at once; waiting is the gate's job).
pub fn gyro_outcome(hook: &GyroHook, path: &str, o: &GyroflowOptions, ts_us: i64) -> GyroOutcome {
    if !hook.wait && hook.maps.readiness(path, o, Duration::ZERO) != GyroReadiness::Ready {
        return GyroOutcome::Original;
    }
    hook.maps.map(path, o, ts_us, hook.wait).map_or(GyroOutcome::Original, GyroOutcome::Warped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::stabilize_effect::{STABILIZE_KIND, STABILIZE_METHOD_KEY};
    use sq_core_model::AnimatedProperty;
    use sq_core_model::{ClipEffect, Track, TrackKind};
    use sq_render::program::GyroMaps;

    struct Fake(Mutex<GyroReadiness>, Mutex<u64>);
    impl GyroMaps for Fake {
        fn map(&self, _: &str, _: &GyroflowOptions, _: i64, _: bool) -> Option<Arc<WarpMap>> {
            (*self.0.lock().unwrap() == GyroReadiness::Ready).then(|| Arc::new(WarpMap::identity(2, 2)))
        }
        fn readiness(&self, _: &str, _: &GyroflowOptions, _: Duration) -> GyroReadiness {
            self.0.lock().unwrap().clone()
        }
        fn add_observer(&self, _: Arc<dyn Fn() + Send + Sync>) {}
        fn generation(&self, _: &str, _: &GyroflowOptions) -> u64 {
            *self.1.lock().unwrap()
        }
    }

    fn hook(r: GyroReadiness) -> (GyroHook, Arc<Fake>) {
        let f = Arc::new(Fake(Mutex::new(r), Mutex::new(1)));
        (GyroHook { maps: Arc::<Fake>::clone(&f), wait: false }, f)
    }

    #[test]
    fn a_ready_clip_is_warped_from_its_first_frame() {
        let (h, _) = hook(GyroReadiness::Ready);
        let w = GyroWatch::default();
        assert_eq!(w.check(&h, "/a", &GyroflowOptions::default()), GyroGate::Go);
        assert!(matches!(gyro_outcome(&h, "/a", &GyroflowOptions::default(), 0), GyroOutcome::Warped(_)));
    }

    #[test]
    fn a_loading_clip_holds_the_frame_until_ready_and_never_draws_unwarped() {
        let (h, f) = hook(GyroReadiness::Loading);
        let w = GyroWatch::new(Duration::from_secs(60));
        let o = GyroflowOptions::default();
        assert_eq!(w.check(&h, "/a", &o), GyroGate::Wait);
        assert_eq!(w.check(&h, "/a", &o), GyroGate::Wait);
        *f.0.lock().unwrap() = GyroReadiness::Ready;
        assert_eq!(w.check(&h, "/a", &o), GyroGate::Go);
    }

    #[test]
    fn no_result_after_the_give_up_time_and_a_failure_show_the_original_with_a_reason() {
        let (h, _) = hook(GyroReadiness::Loading);
        let w = GyroWatch::new(Duration::ZERO);
        assert!(matches!(w.check(&h, "/a", &GyroflowOptions::default()), GyroGate::Failed(_)));
        let (h, _) = hook(GyroReadiness::Failed("x".into()));
        assert_eq!(GyroWatch::default().check(&h, "/a", &GyroflowOptions::default()), GyroGate::Failed("x".into()));
        assert_eq!(gyro_outcome(&h, "/a", &GyroflowOptions::default(), 0), GyroOutcome::Original);
    }

    #[test]
    fn a_wait_is_per_analysis_generation_and_forgotten_when_the_clip_is_not_asked_for() {
        let (h, f) = hook(GyroReadiness::Loading);
        let w = GyroWatch::new(Duration::from_secs(60));
        let o = GyroflowOptions::default();
        assert_eq!(w.check(&h, "/a", &o), GyroGate::Wait);
        assert!(w.waited("/a", 1).is_some());
        // Analyze Again: a new generation starts from zero, the old wait is dropped with the asked list.
        *f.1.lock().unwrap() = 2;
        assert_eq!(w.check(&h, "/a", &o), GyroGate::Wait);
        w.retain_asked(&[("/a".to_string(), 2)]);
        assert!(w.waited("/a", 1).is_none() && w.waited("/a", 2).is_some());
        // The clip leaves the wanted set: nothing stays behind.
        w.retain_asked(&[]);
        assert!(w.waited("/a", 2).is_none());
        // A failure ends the wait too (Analyze Again later waits afresh).
        *f.0.lock().unwrap() = GyroReadiness::Failed("x".into());
        assert!(matches!(w.check(&h, "/a", &o), GyroGate::Failed(_)));
        assert!(w.waited("/a", 2).is_none());
    }

    fn stabilized(n: u128, media: u128) -> sq_core_model::Clip {
        let mut c = super::super::testkit::clip(n, super::super::testkit::id(media), 0, 0, 2);
        let mut e = ClipEffect::new(Id::from_u128(n + 500), STABILIZE_KIND);
        e.parameters.insert(STABILIZE_METHOD_KEY.into(), AnimatedProperty::new(1.0));
        c.effects.push(e);
        c
    }

    fn timeline_of(clips: Vec<sq_core_model::Clip>) -> Timeline {
        let mut t = Track::new(Id::from_u128(77), TrackKind::Video);
        t.set_clips(clips);
        Timeline::new(Id::from_u128(5), "t", super::super::testkit::format(), vec![t])
    }

    #[test]
    fn clips_of_nested_sequences_are_found_too() {
        let top = timeline_of(vec![stabilized(1, 10)]);
        let nested = timeline_of(vec![
            stabilized(2, 20),
            super::super::testkit::clip(3, super::super::testkit::id(30), 0, 0, 2),
        ]);
        let found: Vec<Id> = stabilized_media([&top, &nested]).into_iter().map(|(m, _)| m).collect();
        assert_eq!(found, vec![super::super::testkit::id(10), super::super::testkit::id(20)]);
    }
}
