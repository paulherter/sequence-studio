//! Poster and clip-frame decodes are background work: while the timeline plays or the playhead is being scrubbed they wait,
//! so a 4K software decode does not take the cores the playback decode needs (6.5 cores in the first seconds after a
//! project opened, Dreh 26.11 baseline). The UI reports the playback state once per frame ([`note_playback`]); the decode
//! calls [`wait_until_clear`] before it starts.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use sq_core_time::Time;

/// How long after the last playhead move a scrub still counts as going on.
const SETTLE: Duration = Duration::from_millis(400);
/// A waiting decode never waits longer than this (a thumbnail must come eventually, and a pool thread must end).
const MAX_WAIT: Duration = Duration::from_secs(30);
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
    }

    /// True while playing, or within [`SETTLE`] of the last playhead move.
    pub fn is_yielding(&self, now: Instant) -> bool {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner());
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
}

static GATE: ThumbnailGate = ThumbnailGate { state: Mutex::new(GateState { playing: false, playhead: None, moved: None }) };

/// The UI's once-per-frame report (playing flag and playhead).
pub fn note_playback(playing: bool, playhead: Time) {
    GATE.note(playing, playhead, Instant::now());
}

/// Called by a thumbnail decode before it starts.
pub fn wait_until_clear() {
    GATE.wait_until_clear(MAX_WAIT);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

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
