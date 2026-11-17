//! `SQ_RESIZE_LOG=1`: one stderr line per drawn frame of a window resize, with the time spent in each stage.
//! A measuring aid for the live resize (configure, layout, acquire, draw, present); it costs nothing when the variable is unset.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// Whether `SQ_RESIZE_LOG` is set (read once).
pub fn on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SQ_RESIZE_LOG").is_some())
}

/// Where one present spent its time.
#[derive(Clone, Copy, Debug, Default)]
pub struct PresentTiming {
    pub configure: Duration,
    pub acquire: Duration,
    pub draw: Duration,
    pub present: Duration,
}

/// The resize events since the last drawn frame.
#[derive(Default)]
pub struct ResizeLog {
    first_event: Option<Instant>,
    events: u32,
}

impl ResizeLog {
    /// A `Resized` event arrived.
    pub fn event(&mut self) {
        self.first_event.get_or_insert_with(Instant::now);
        self.events += 1;
    }

    /// A frame was drawn after `layout` and `timing`; prints one line when resize events led to it.
    pub fn frame(&mut self, layout: Duration, timing: PresentTiming, drawn: bool) {
        let Some(first) = self.first_event.take() else { return };
        let ms = |d: Duration| d.as_secs_f64() * 1e3;
        eprintln!(
            "resize-step events={} configure={:.1} layout={:.1} acquire={:.1} draw={:.1} present={:.1} event_to_done={:.1} drawn={drawn}",
            std::mem::take(&mut self.events),
            ms(timing.configure),
            ms(layout),
            ms(timing.acquire),
            ms(timing.draw),
            ms(timing.present),
            ms(first.elapsed()),
        );
    }
}
