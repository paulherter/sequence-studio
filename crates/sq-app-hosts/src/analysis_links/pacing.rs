//! The one rule for background analyses beside playback: the frames on the monitor come first. Between two units of work
//! (a frame, a picture) an analysis calls [`yield_to_playback`]; while an engine plays or scrubs it stands still and goes on
//! when the picture rests. Measured 2026-11-25 on the real project: an analysis beside playback cost shown frames and a
//! thread cap alone did not protect them. A run while not playing is as fast as before.

use sq_analysis::analysis_turn::CancelToken;
use sq_playback::engine::activity::PlayActivity;
use std::time::{Duration, Instant};

/// A wait for playback shorter than this is not announced.
pub const HOLD_SHOWN: Duration = Duration::from_millis(300);

/// The wait step (the proxy transcode's rule). shortcut: polling slices, an event from the engine when a profile shows it.
const SLICE: Duration = Duration::from_millis(50);

/// Waits while `playback` is busy; a cancel ends the wait at once. `hold(true)` goes out only after a wait of
/// [`HOLD_SHOWN`] (so a short wait does not flicker a status line) and `hold(false)` when such a wait ends.
pub fn yield_to_playback(playback: &PlayActivity, cancel: &CancelToken, hold: &mut dyn FnMut(bool)) {
    let waited = Instant::now();
    let mut shown = false;
    while playback.is_busy() && !cancel.is_cancelled() {
        std::thread::sleep(SLICE);
        if !shown && waited.elapsed() >= HOLD_SHOWN {
            shown = true;
            hold(true);
        }
    }
    if shown {
        hold(false);
    }
}

/// [`yield_to_playback`] against the process's playback counter.
pub fn yield_shared(cancel: &CancelToken, hold: &mut dyn FnMut(bool)) {
    yield_to_playback(&PlayActivity::shared(), cancel, hold);
}

/// The one status line of a background run that waits: neutral, since the counter is busy for playback, scrubbing and export.
pub fn paused_line(what: &str, percent: f64) -> String {
    format!("{what} paused while playing or exporting ({percent:.0}%)")
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_playback::engine::activity::PlayMark;
    use std::sync::{Arc, Mutex};

    #[test]
    fn the_pause_line_is_neutral_for_playing_and_exporting() {
        assert_eq!(paused_line("Tracking mask", 42.4), "Tracking mask paused while playing or exporting (42%)");
    }

    #[test]
    fn an_idle_counter_does_not_wait() {
        let at = Instant::now();
        let mut calls = Vec::new();
        yield_to_playback(&PlayActivity::default(), &CancelToken::new(), &mut |h| calls.push(h));
        assert!(at.elapsed() < Duration::from_millis(40) && calls.is_empty());
    }

    #[test]
    fn it_waits_while_busy_announces_after_300_ms_and_resumes() {
        let activity = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&activity));
        mark.set(true);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let t = {
            let (a, c) = (Arc::clone(&activity), Arc::clone(&calls));
            std::thread::spawn(move || {
                yield_to_playback(&a, &CancelToken::new(), &mut |h| c.lock().unwrap().push(h));
            })
        };
        std::thread::sleep(Duration::from_millis(500));
        assert_eq!(*calls.lock().unwrap(), vec![true], "announced once, still waiting");
        mark.set(false);
        t.join().unwrap();
        assert_eq!(*calls.lock().unwrap(), vec![true, false]);
    }

    #[test]
    fn a_short_wait_is_not_announced() {
        let activity = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&activity));
        mark.set(true);
        let t = {
            let a = Arc::clone(&activity);
            std::thread::spawn(move || {
                let mut calls = Vec::new();
                yield_to_playback(&a, &CancelToken::new(), &mut |h| calls.push(h));
                calls
            })
        };
        std::thread::sleep(Duration::from_millis(100));
        mark.set(false);
        assert!(t.join().unwrap().is_empty());
    }

    #[test]
    fn a_cancel_ends_the_wait_at_once() {
        let activity = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&activity));
        mark.set(true);
        let cancel = CancelToken::new();
        let t = {
            let (a, c) = (Arc::clone(&activity), cancel.clone());
            std::thread::spawn(move || yield_to_playback(&a, &c, &mut |_| {}))
        };
        std::thread::sleep(Duration::from_millis(100));
        cancel.cancel();
        t.join().unwrap();
        mark.set(false);
    }
}
