//! The live window resize: a `Resized` event only notes the newest size, the next frame applies it once (surface configure and
//! layout). A drag sends a size per pointer step (125 to 1000 a second). Drawing and committing a frame per step outruns the
//! display: on Wayland the compositor queues every commit and applies one per refresh, so the window follows the pointer
//! seconds late; on Windows every step also rebuilds the swap chain (18 to 80 ms). One frame per `RedrawRequested` keeps the
//! newest size only, and that event is paced by the system (frame callback, vsync).

use std::time::{Duration, Instant};

/// How long the loop turn leaves a resize frame to `RedrawRequested` before it draws one itself (a request that got lost must
/// not freeze the window).
const WAIT: Duration = Duration::from_millis(250);

/// The newest window size that no frame has applied yet.
#[derive(Default)]
pub struct LiveResize {
    /// The size and when the oldest unapplied event came.
    latest: Option<((u32, u32), Instant)>,
}

impl LiveResize {
    /// A `Resized` event: the newest size wins, the age is the oldest event's.
    pub fn event(&mut self, size: (u32, u32), now: Instant) {
        let since = self.latest.map_or(now, |(_, since)| since);
        self.latest = Some((size, since));
    }

    /// The newest size, once: the frame that applies it.
    pub fn take(&mut self) -> Option<(u32, u32)> {
        self.latest.take().map(|(size, _)| size)
    }

    /// Whether no resize waits for a frame (a drag pacing may hold the frame back only then).
    pub fn is_idle(&self) -> bool {
        self.latest.is_none()
    }

    /// Whether the loop turn must not draw: a resize frame is waiting for `RedrawRequested` and is not overdue.
    pub fn holds_frame(&self, now: Instant) -> bool {
        self.latest.is_some_and(|(_, since)| now.duration_since(since) < WAIT)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_drag_of_events_applies_the_newest_size_once() {
        let mut r = LiveResize::default();
        let t = Instant::now();
        for i in 0..600u32 {
            r.event((1600 + i, 900 + i / 2), t);
        }
        assert_eq!(r.take(), Some((2199, 1199)));
        assert_eq!(r.take(), None);
    }

    #[test]
    fn the_loop_turn_holds_its_frame_for_a_waiting_resize_only() {
        let mut r = LiveResize::default();
        let t = Instant::now();
        assert!(!r.holds_frame(t), "no resize: the loop turn draws as before");
        r.event((1700, 900), t);
        r.event((1710, 905), t + Duration::from_millis(200));
        assert!(r.holds_frame(t + Duration::from_millis(240)));
        assert!(!r.holds_frame(t + Duration::from_millis(260)), "overdue since the first event: the loop draws itself");
        r.take();
        assert!(!r.holds_frame(t + Duration::from_millis(10)));
    }
}
