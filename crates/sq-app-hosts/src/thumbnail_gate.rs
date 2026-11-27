//! Poster and clip-frame decodes are background work: while the timeline plays or the playhead is being scrubbed they wait,
//! so a 4K software decode does not take the cores the playback decode needs (6.5 cores in the first seconds after a
//! project opened, Dreh 26.11 baseline). The UI reports the playback state once per frame ([`note_playback`]); the decode
//! calls [`wait_until_clear`] before it starts.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use sq_core_time::Time;

/// How long after the last playhead move a scrub still counts as going on.
const SETTLE: Duration = Duration::from_millis(400);
/// A waiting decode never waits longer than this (a pool thread must end). It is long on purpose: 30 s let every queued
/// thumbnail decode run in the middle of a long play (Linux trace, Dreh 26.11); a pause or stop releases them at once.
const MAX_WAIT: Duration = Duration::from_secs(10 * 60);
/// A report older than this is not believed: the UI reports once per frame while it plays, so a silent UI (closing, a
/// finished bench, a hidden window) must not hold the thumbnails (nor the pool threads at shutdown) any longer.
const STALE: Duration = Duration::from_secs(1);
const POLL: Duration = Duration::from_millis(40);

/// What the decodes need to know about playback.
#[derive(Default)]
pub struct ThumbnailGate {
    state: Mutex<GateState>,
}

#[derive(Default)]
struct GateState {
    playing: bool,
    playhead: Option<Time>,
    moved: Option<Instant>,
    noted: Option<Instant>,
}

impl ThumbnailGate {
    /// Takes the playback facts of one UI frame at `now`: a playhead that moved while paused is a scrub.
    pub fn note(&self, playing: bool, playhead: Time, now: Instant) {
        let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if s.playhead.is_some_and(|p| p != playhead) {
            s.moved = Some(now);
        }
        s.playhead = Some(playhead);
        s.playing = playing;
        s.noted = Some(now);
    }

    /// True while playing, or within [`SETTLE`] of the last playhead move.
    pub fn is_yielding(&self, now: Instant) -> bool {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let Some(noted) = s.noted else { return false };
        if now.saturating_duration_since(noted) > STALE {
            return false;
        }
        s.playing || s.moved.is_some_and(|m| now.saturating_duration_since(m) < SETTLE)
    }

    /// Blocks the calling (background) thread until playback and scrubbing are over, at most `max`. Returns whether it
    /// had to wait.
    pub fn wait_until_clear(&self, max: Duration) -> bool {
        let start = Instant::now();
        let mut waited = false;
        while self.is_yielding(Instant::now()) && start.elapsed() < max {
            waited = true;
            std::thread::sleep(POLL);
        }
        waited
    }

    /// Runs `work` while nothing plays or scrubs, as background work that gives way: `work` gets a `stop` question to ask
    /// between pictures. When play or a scrub starts mid-way, `stop` says yes, the half-done decode is dropped and the
    /// whole `work` runs again after the gate cleared (a thumbnail is one picture, so little is lost). Returns what `work`
    /// returned and whether it had to wait.
    pub fn run_when_clear<T>(&self, max: Duration, work: impl Fn(&dyn Fn() -> bool) -> T) -> (T, bool) {
        let mut waited = false;
        loop {
            waited |= self.wait_until_clear(max);
            if self.is_yielding(Instant::now()) {
                // The wait ran out while playback still goes on: the pool thread must end, so decode without stopping.
                return (work(&|| false), waited);
            }
            let interrupted = std::cell::Cell::new(false);
            let stop = || {
                let yielding = self.is_yielding(Instant::now());
                interrupted.set(interrupted.get() || yielding);
                yielding
            };
            let out = work(&stop);
            if !interrupted.get() {
                return (out, waited);
            }
        }
    }
}

static GATE: ThumbnailGate =
    ThumbnailGate { state: Mutex::new(GateState { playing: false, playhead: None, moved: None, noted: None }) };

/// The UI's once-per-frame report (playing flag and playhead).
pub fn note_playback(playing: bool, playhead: Time) {
    // The proxy transcode and the other background jobs ask `PlayActivity`: it follows this same gate (one mechanism).
    static LINKED: std::sync::Once = std::sync::Once::new();
    LINKED.call_once(|| {
        sq_playback::engine::activity::PlayActivity::shared().set_probe(|| GATE.is_yielding(Instant::now()));
    });
    GATE.note(playing, playhead, Instant::now());
}

/// Runs a thumbnail decode when nothing plays or scrubs; see [`ThumbnailGate::run_when_clear`].
pub fn run_when_clear<T>(work: impl Fn(&dyn Fn() -> bool) -> T) -> (T, bool) {
    GATE.run_when_clear(MAX_WAIT, work)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn thumbnails_pause_while_playing_and_resume_after_pause() {
        let gate = ThumbnailGate::default();
        let t0 = Instant::now();
        assert!(!gate.is_yielding(t0));
        gate.note(true, Time::new(1, 30), t0);
        assert!(gate.is_yielding(t0), "playing");
        gate.note(false, Time::new(1, 30), t0);
        assert!(!gate.is_yielding(t0), "paused and still");
    }

    #[test]
    fn a_scrub_holds_thumbnails_until_the_playhead_has_rested() {
        let gate = ThumbnailGate::default();
        let t0 = Instant::now();
        gate.note(false, Time::new(1, 30), t0);
        gate.note(false, Time::new(5, 30), t0);
        assert!(gate.is_yielding(t0 + Duration::from_millis(100)));
        assert!(!gate.is_yielding(t0 + SETTLE + Duration::from_millis(1)));
    }

    #[test]
    fn thumbnail_source_does_not_decode_while_a_play_state_is_active() {
        let gate = Arc::new(ThumbnailGate::default());
        gate.note(true, Time::ZERO, Instant::now());
        let runs = Arc::new(AtomicUsize::new(0));
        let (g, n) = (Arc::clone(&gate), Arc::clone(&runs));
        let worker = std::thread::spawn(move || {
            g.run_when_clear(Duration::from_secs(5), |_| {
                n.fetch_add(1, Ordering::SeqCst);
            })
        });
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(runs.load(Ordering::SeqCst), 0, "no decode while playing");
        gate.note(false, Time::ZERO, Instant::now());
        let ((), waited) = worker.join().unwrap();
        assert!(waited);
        assert_eq!(runs.load(Ordering::SeqCst), 1, "it resumes after the stop");
    }

    #[test]
    fn a_decode_in_flight_stops_when_play_starts_and_restarts_after_the_stop() {
        let gate = Arc::new(ThumbnailGate::default());
        gate.note(false, Time::ZERO, Instant::now());
        let runs = Arc::new(AtomicUsize::new(0));
        let releaser = {
            let g = Arc::clone(&gate);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(150));
                g.note(false, Time::ZERO, Instant::now());
            })
        };
        let (out, _) = gate.run_when_clear(Duration::from_secs(5), |stop| {
            let run = runs.fetch_add(1, Ordering::SeqCst) + 1;
            if run == 1 {
                gate.note(true, Time::ZERO, Instant::now()); // Play pressed while the decode runs.
            }
            assert_eq!(stop(), run == 1, "only the first run is told to stop");
            run
        });
        releaser.join().unwrap();
        assert_eq!(out, 2, "the second run, after the stop, is the result");
    }

    #[test]
    fn a_silent_ui_does_not_hold_the_thumbnails() {
        let gate = ThumbnailGate::default();
        let t0 = Instant::now();
        gate.note(true, Time::ZERO, t0);
        assert!(gate.is_yielding(t0 + Duration::from_millis(500)));
        assert!(
            !gate.is_yielding(t0 + STALE + Duration::from_millis(1)),
            "no report for a second: not playing any more"
        );
    }

    #[test]
    fn a_wait_that_runs_out_decodes_anyway() {
        let gate = ThumbnailGate::default();
        gate.note(true, Time::ZERO, Instant::now());
        let (out, waited) = gate.run_when_clear(Duration::from_millis(60), |stop| stop());
        assert!(waited);
        assert!(!out, "the pool thread must end: no stop after the wait ran out");
    }

    #[test]
    fn a_waiting_decode_starts_when_playback_stops() {
        let gate = Arc::new(ThumbnailGate::default());
        gate.note(true, Time::ZERO, Instant::now());
        let g = Arc::clone(&gate);
        let stopper = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(120));
            g.note(false, Time::ZERO, Instant::now());
        });
        assert!(gate.wait_until_clear(Duration::from_secs(5)), "it had to wait");
        stopper.join().unwrap();
        assert!(!gate.is_yielding(Instant::now()));
        // A bounded wait gives up on a playback that never ends.
        gate.note(true, Time::ZERO, Instant::now());
        assert!(gate.wait_until_clear(Duration::from_millis(100)));
    }
}
