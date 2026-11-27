//! Whether any engine of the process is playing or scrubbing. Background work that competes with playback for the CPU, the
//! decoder and the GPU (the automatic proxy transcode) holds back while it is: the frames come first, the proxy a little later.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

/// How many engines are playing or scrubbing right now.
#[derive(Default)]
pub struct PlayActivity {
    busy: AtomicUsize,
    /// A second source of "busy": the UI's playback report (play, scrub with a settle time). Set once by the app host.
    probe: OnceLock<Box<dyn Fn() -> bool + Send + Sync>>,
}

impl PlayActivity {
    /// The one counter of the process.
    pub fn shared() -> Arc<PlayActivity> {
        static SHARED: OnceLock<Arc<PlayActivity>> = OnceLock::new();
        Arc::clone(SHARED.get_or_init(Arc::default))
    }

    /// Adds a probe that also counts as busy (the first one wins). The proxy transcode used to look only at engine marks, and
    /// no engine ever set one, so it ran at full speed during Play (Linux nightly 27.11: 189 of 450 frames dropped).
    pub fn set_probe(&self, probe: impl Fn() -> bool + Send + Sync + 'static) {
        let _ = self.probe.set(Box::new(probe));
    }

    /// True while an engine plays or scrubs.
    pub fn is_busy(&self) -> bool {
        self.busy.load(Ordering::Relaxed) > 0 || self.probe.get().is_some_and(|p| p())
    }

    /// Blocks while an engine plays or scrubs, in steps of `slice`, and returns early when `cancelled` says so.
    pub fn wait_while_busy(&self, cancelled: impl Fn() -> bool, slice: Duration) {
        while self.is_busy() && !cancelled() {
            std::thread::sleep(slice);
        }
    }
}

impl std::fmt::Debug for PlayActivity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PlayActivity(busy {})", self.is_busy())
    }
}

/// One engine's share of a [`PlayActivity`]; dropping it counts the engine as idle.
pub struct PlayMark {
    activity: Arc<PlayActivity>,
    on: bool,
}

impl PlayMark {
    pub fn new(activity: Arc<PlayActivity>) -> PlayMark {
        PlayMark { activity, on: false }
    }

    /// The engine plays or scrubs (`true`) or does not.
    pub fn set(&mut self, busy: bool) {
        if busy == self.on {
            return;
        }
        self.on = busy;
        if busy {
            self.activity.busy.fetch_add(1, Ordering::Relaxed);
        } else {
            self.activity.busy.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

impl Drop for PlayMark {
    fn drop(&mut self) {
        self.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn two_engines_count_and_a_dropped_one_is_idle() {
        let activity = Arc::new(PlayActivity::default());
        let (mut a, mut b) = (PlayMark::new(Arc::clone(&activity)), PlayMark::new(Arc::clone(&activity)));
        assert!(!activity.is_busy());
        a.set(true);
        a.set(true); // the same state again counts once
        b.set(true);
        assert_eq!(activity.busy.load(Ordering::Relaxed), 2);
        a.set(false);
        assert!(activity.is_busy(), "the other engine still plays");
        drop(b);
        assert!(!activity.is_busy(), "a dropped engine that played no longer holds work back");
    }

    #[test]
    fn a_probe_holds_background_work_and_releases_it() {
        let activity = PlayActivity::default();
        let on = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&on);
        activity.set_probe(move || flag.load(Ordering::Relaxed));
        assert!(!activity.is_busy());
        on.store(true, Ordering::Relaxed);
        assert!(activity.is_busy(), "no progress allowed while the probe says play");
        on.store(false, Ordering::Relaxed);
        assert!(!activity.is_busy(), "resumes as soon as playback stops");
        on.store(true, Ordering::Relaxed);
        activity.wait_while_busy(|| true, Duration::from_secs(60)); // a cancel (quit) never hangs on a busy probe
    }

    #[test]
    fn background_work_waits_until_playback_stops() {
        let activity = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&activity));
        mark.set(true);
        let finished = Arc::new(AtomicBool::new(false));
        let worker = {
            let (activity, finished) = (Arc::clone(&activity), Arc::clone(&finished));
            std::thread::spawn(move || {
                activity.wait_while_busy(|| false, Duration::from_millis(2));
                finished.store(true, Ordering::SeqCst);
            })
        };
        std::thread::sleep(Duration::from_millis(60));
        assert!(!finished.load(Ordering::SeqCst), "the transcode holds back while the picture plays");
        mark.set(false);
        assert!(worker.join().is_ok());
        assert!(finished.load(Ordering::SeqCst), "and goes on when playback stopped");
    }

    #[test]
    fn a_cancelled_job_does_not_wait() {
        let activity = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&activity));
        mark.set(true);
        activity.wait_while_busy(|| true, Duration::from_secs(60)); // returns at once
    }
}
