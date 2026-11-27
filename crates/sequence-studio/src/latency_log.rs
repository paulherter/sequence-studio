//! `SQ_LATENCY_LOG=1`: one stderr line per drawn frame that answers pointer events or is drawn while a button is held, with
//! the age of the oldest and newest event when the frame was handed to the system and the time spent in each stage.
//! `events=0` with `down=1` is a frame that no pointer event asked for (a second frame in the same refresh). A measuring aid
//! for the drag feel (scripts/latency-probe.sh); it costs nothing when the variable is unset.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::resize_log::PresentTiming;

/// Whether `SQ_LATENCY_LOG` is set (read once).
pub fn on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SQ_LATENCY_LOG").is_some())
}

/// The pointer events since the last drawn frame.
#[derive(Default)]
pub struct LatencyLog {
    oldest: Option<Instant>,
    newest: Option<Instant>,
    events: u32,
}

impl LatencyLog {
    /// A pointer event (move or button) reached the loop.
    pub fn pointer(&mut self, now: Instant) {
        self.oldest.get_or_insert(now);
        self.newest = Some(now);
        self.events += 1;
    }

    /// A frame went to the system after `layout` and `timing`; `down` is whether a pointer button is held and `shape` the pointer shape the app asks for
    /// (a card drag shows its own).
    pub fn frame(&mut self, layout: Duration, timing: PresentTiming, down: bool, drawn: bool, shape: &str) {
        let (oldest, newest) = (self.oldest.take(), self.newest.take());
        let events = std::mem::take(&mut self.events);
        if events == 0 && !down {
            return;
        }
        let ms = |d: Duration| d.as_secs_f64() * 1e3;
        let age = |at: Option<Instant>| at.map_or(0.0, |t| ms(t.elapsed()));
        sq_os::errln!(
            "latency-frame events={events} oldest={:.1} newest={:.1} layout={:.1} acquire={:.1} draw={:.1} present={:.1} down={} drawn={drawn} shape={shape}",
            age(oldest),
            age(newest),
            ms(layout),
            ms(timing.acquire),
            ms(timing.draw),
            ms(timing.present),
            u8::from(down),
        );
    }
}
