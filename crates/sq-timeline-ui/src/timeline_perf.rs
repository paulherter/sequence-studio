// Swift: TimelinePerf.swift
//! Opt-in timing of the first scroll and zoom steps after a timeline is created (`SQ_TIMELINE_PERF=1`).
//! A step = the handler (scroll / set zoom) plus the draw that follows it. Cost buckets are summed over the step.
//! When disabled every entry point is one `bool` test. The clock and the log sink are injected.

/// What a step measures.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PerfKind {
    /// A scroll step.
    Scroll,
    /// A zoom step.
    Zoom,
}

impl PerfKind {
    fn raw_value(self) -> &'static str {
        match self {
            PerfKind::Scroll => "scroll",
            PerfKind::Zoom => "zoom",
        }
    }

    fn index(self) -> usize {
        match self {
            PerfKind::Scroll => 0,
            PerfKind::Zoom => 1,
        }
    }
}

/// Cost buckets of one draw.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PerfBucket {
    /// Row layout.
    Rows,
    /// Names.
    Names,
    /// Waveforms (also used for the waveform tiles).
    Waveform,
    /// Everything else.
    Other,
}

const BUCKET_COUNT: usize = 4;

impl PerfBucket {
    fn index(self) -> usize {
        match self {
            PerfBucket::Rows => 0,
            PerfBucket::Names => 1,
            PerfBucket::Waveform => 2,
            PerfBucket::Other => 3,
        }
    }
}

/// The step timer.
pub struct TimelinePerf {
    /// Whether the timer records.
    pub enabled: bool,
    counts: [i64; 2],
    pending: Option<(PerfKind, u64)>,
    handler_start: u64,
    draw_start: u64,
    buckets: [u64; BUCKET_COUNT],
    lines: Vec<String>,
    now: Box<dyn Fn() -> u64>,
    sink: Box<dyn FnMut(&str)>,
}

impl TimelinePerf {
    /// Steps logged per kind.
    pub const STEP_LIMIT: i64 = 30;

    /// A timer reading `now` (nanoseconds) and logging to `sink`.
    pub fn new(enabled: bool, now: Box<dyn Fn() -> u64>, sink: Box<dyn FnMut(&str)>) -> TimelinePerf {
        TimelinePerf {
            enabled,
            counts: [0; 2],
            pending: None,
            handler_start: 0,
            draw_start: 0,
            buckets: [0; BUCKET_COUNT],
            lines: Vec::new(),
            now,
            sink,
        }
    }

    /// Steps counted so far for `kind`.
    pub fn count(&self, kind: PerfKind) -> i64 {
        self.counts[kind.index()]
    }

    /// Lines of the steps logged so far.
    pub fn lines(&self) -> &[String] {
        &self.lines
    }

    /// Starts the handler of a step.
    pub fn begin_handler(&mut self, kind: PerfKind) {
        if !self.enabled || self.counts[kind.index()] >= Self::STEP_LIMIT {
            return;
        }
        self.pending = Some((kind, 0));
        self.handler_start = (self.now)();
    }

    /// Ends the handler of the step.
    pub fn end_handler(&mut self) {
        if !self.enabled {
            return;
        }
        let elapsed = (self.now)().wrapping_sub(self.handler_start);
        if let Some(p) = self.pending.as_mut() {
            p.1 = elapsed;
        }
    }

    /// Starts the draw.
    pub fn begin_draw(&mut self) {
        if self.enabled {
            self.draw_start = (self.now)();
        }
    }

    /// Adds `ns` to a cost bucket of the draw in flight.
    pub fn add(&mut self, bucket: PerfBucket, ns: u64) {
        if self.enabled {
            let b = &mut self.buckets[bucket.index()];
            *b = b.wrapping_add(ns);
        }
    }

    /// Runs `body` and adds its time to `bucket`.
    pub fn time<T>(&mut self, bucket: PerfBucket, body: impl FnOnce() -> T) -> T {
        if !self.enabled {
            return body();
        }
        let t0 = (self.now)();
        let r = body();
        let dt = (self.now)().wrapping_sub(t0);
        self.add(bucket, dt);
        r
    }

    /// Ends the draw and logs the step.
    pub fn end_draw(&mut self) {
        if !self.enabled {
            return;
        }
        let pending = self.pending.take();
        let b = std::mem::take(&mut self.buckets);
        let Some(p) = pending else { return };
        let draw_ns = (self.now)().wrapping_sub(self.draw_start);
        let n = self.counts[p.0.index()] + 1;
        self.counts[p.0.index()] = n;
        let ms = |ns: u64| format!("{:.2}", ns as f64 / 1e6);
        let line = format!(
            "TimelinePerf {} #{}: total {} ms | handler {} draw {} (rows {} names {} waveform {})",
            p.0.raw_value(),
            n,
            ms(p.1.wrapping_add(draw_ns)),
            ms(p.1),
            ms(draw_ns),
            ms(b[PerfBucket::Rows.index()]),
            ms(b[PerfBucket::Names.index()]),
            ms(b[PerfBucket::Waveform.index()]),
        );
        self.lines.push(line.clone());
        (self.sink)(&line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    #[test]
    fn disabled_timer_records_nothing() {
        let mut p = TimelinePerf::new(false, Box::new(|| 0), Box::new(|_| {}));
        p.begin_handler(PerfKind::Scroll);
        p.end_handler();
        p.begin_draw();
        p.end_draw();
        assert!(p.lines().is_empty() && p.count(PerfKind::Scroll) == 0);
    }

    #[test]
    fn one_step_logs_one_line() {
        let clock = Rc::new(Cell::new(0_u64));
        let c = Rc::clone(&clock);
        let mut p = TimelinePerf::new(true, Box::new(move || c.get()), Box::new(|_| {}));
        p.begin_handler(PerfKind::Zoom);
        clock.set(2_000_000);
        p.end_handler();
        p.begin_draw();
        clock.set(5_000_000);
        p.add(PerfBucket::Rows, 1_000_000);
        p.end_draw();
        assert_eq!(p.count(PerfKind::Zoom), 1);
        assert_eq!(
            p.lines()[0],
            "TimelinePerf zoom #1: total 5.00 ms | handler 2.00 draw 3.00 (rows 1.00 names 0.00 waveform 0.00)"
        );
    }
}
