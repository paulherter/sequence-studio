// Swift: ExportProgressTracker.swift

/// What the progress window says the export is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExportPhase {
    /// Before the first frame.
    Preparing,
    /// Frames are rendered and encoded.
    Rendering,
    /// The last percent: flush and finalize.
    Finishing,
}

impl ExportPhase {
    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            ExportPhase::Preparing => "Preparing",
            ExportPhase::Rendering => "Rendering and encoding",
            ExportPhase::Finishing => "Finishing",
        }
    }
}

/// Pure progress / ETA math for the export progress window. Time is passed in (seconds, any monotonic origin) so it is
/// testable. The rate is an exponential moving average of progress-per-second, so one slow frame does not make the
/// estimate jump.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ExportProgressTracker {
    progress: f64,
    rate: Option<f64>,
    start: Option<f64>,
    last_time: Option<f64>,
    last_progress: f64,
}

impl ExportProgressTracker {
    /// The estimate needs this much progress and time first; before that the rate is too noisy.
    const MIN_PROGRESS: f64 = 0.01;
    const MIN_ELAPSED: f64 = 2.0;
    /// Weight of the newest sample per second of elapsed time (capped at 1).
    const SMOOTHING: f64 = 0.15;

    /// A tracker before the first sample.
    pub fn new() -> ExportProgressTracker {
        ExportProgressTracker::default()
    }

    /// Progress 0...1.
    pub fn progress(&self) -> f64 {
        self.progress
    }

    /// Progress per second, smoothed.
    pub fn rate(&self) -> Option<f64> {
        self.rate
    }

    /// Records progress `p` at `time` seconds.
    pub fn record(&mut self, progress: f64, time: f64) {
        let p = progress.clamp(0.0, 1.0);
        let Some(s) = self.start else {
            self.start = Some(time);
            self.last_time = Some(time);
            self.last_progress = p;
            self.progress = p;
            return;
        };
        if p <= self.progress {
            return;
        }
        self.progress = p;
        let Some(lt) = self.last_time.filter(|lt| time > *lt) else { return };
        let dt = time - lt;
        if let Some(r) = self.rate {
            let inst = (p - self.last_progress) / dt;
            self.rate = Some(r + (Self::SMOOTHING * dt).min(1.0) * (inst - r));
        } else if time - s >= Self::MIN_ELAPSED && p >= Self::MIN_PROGRESS {
            self.rate = Some(p / (time - s)); // seed with the average since the start
        }
        self.last_time = Some(time);
        self.last_progress = p;
    }

    /// Seconds left, `None` until there is enough data.
    pub fn remaining(&self) -> Option<f64> {
        if self.progress >= 1.0 {
            return Some(0.0);
        }
        self.rate.filter(|r| *r > 0.0).map(|r| (1.0 - self.progress) / r)
    }

    /// The phase for a progress value.
    pub fn phase(progress: f64, running: bool) -> ExportPhase {
        if !running {
            ExportPhase::Preparing
        } else if progress >= 0.99 {
            ExportPhase::Finishing
        } else {
            ExportPhase::Rendering
        }
    }

    /// "m:ss", or "h:mm:ss" from an hour on.
    pub fn format(seconds: f64) -> String {
        let s = seconds.max(0.0).floor() as i64;
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
        if h > 0 { format!("{h}:{m:02}:{sec:02}") } else { format!("{m}:{sec:02}") }
    }

    /// The remaining-time line.
    pub fn remaining_text(seconds: Option<f64>) -> String {
        match seconds {
            None => "Calculating\u{2026}".to_string(),
            Some(s) if s < 1.0 => "Almost done".to_string(),
            Some(s) => format!("{} left", Self::format(s)),
        }
    }
}

/// Lets at most one progress update per `min_interval` through (the UI needs <= 10 Hz); the final value always passes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProgressThrottle {
    /// Minimum seconds between updates.
    pub min_interval: f64,
    last: Option<f64>,
}

impl ProgressThrottle {
    /// A throttle with this interval (Swift default 0.1 s).
    pub fn new(min_interval: f64) -> ProgressThrottle {
        ProgressThrottle { min_interval, last: None }
    }

    /// Whether this update passes.
    pub fn accept(&mut self, progress: f64, time: f64) -> bool {
        if progress >= 1.0 || self.last.is_none_or(|l| time - l >= self.min_interval) {
            self.last = Some(time);
            return true;
        }
        false
    }
}
