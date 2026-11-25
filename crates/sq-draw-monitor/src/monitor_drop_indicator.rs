// Swift: MonitorDropIndicator.swift
//! The dropped-frame dot of the Program monitor and the Source viewer mode.

/// State of the quiet dot in the Program monitor chrome: amber for `HOLD_SECONDS` after the engine dropped a frame while
/// playing, plus the number of drops of the last play run for the tooltip. Pure: the host feeds the engine's cumulative
/// `droppedFrames` and the clock.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DropIndicator {
    last_count: i64,
    run_base: i64,
    was_playing: bool,
    amber_until: Option<f64>,
    last_run_drops: i64,
    has_run: bool,
}

impl DropIndicator {
    /// Seconds the dot stays amber after a drop.
    pub const HOLD_SECONDS: f64 = 2.0;
    /// Drops within one play run from which the run counts as "realtime not achieved" (persists until the next run).
    pub const REALTIME_THRESHOLD: i64 = 5;

    /// Drops since the current (or most recent) play run started.
    pub fn last_run_drops(&self) -> i64 {
        self.last_run_drops
    }

    /// True once any play run was seen.
    pub fn has_run(&self) -> bool {
        self.has_run
    }

    /// One poll. `dropped` is the engine's running total (a smaller value means a new engine: rebase).
    pub fn update(&mut self, dropped: i64, is_playing: bool, now: f64) {
        if dropped < self.last_count {
            self.run_base = dropped;
            self.last_count = dropped;
            self.last_run_drops = 0;
        }
        if is_playing && !self.was_playing {
            self.run_base = dropped;
            self.last_run_drops = 0;
            self.amber_until = None;
            self.has_run = true;
        }
        if is_playing {
            if dropped > self.last_count {
                self.amber_until = Some(now + Self::HOLD_SECONDS);
            }
            self.last_run_drops = (dropped - self.run_base).max(0);
        }
        self.last_count = dropped;
        self.was_playing = is_playing;
    }

    /// Auto quality stepped down while playing: the dot lights like for a drop (the count is untouched).
    pub fn note_quality_step(&mut self, is_playing: bool, now: f64) {
        if is_playing {
            self.amber_until = Some(now + Self::HOLD_SECONDS);
        }
    }

    /// The last (or current) play run dropped at least `REALTIME_THRESHOLD` frames.
    pub fn realtime_not_achieved(&self) -> bool {
        self.has_run && self.last_run_drops >= Self::REALTIME_THRESHOLD
    }

    /// Text of the indicator pill: `None` while nothing was dropped in the last run.
    pub fn badge_text(&self) -> Option<String> {
        if !self.has_run || self.last_run_drops <= 0 {
            return None;
        }
        Some(if self.realtime_not_achieved() {
            format!("Realtime not achieved · {} dropped", self.last_run_drops)
        } else {
            format!("{} dropped", self.last_run_drops)
        })
    }

    /// Amber for `HOLD_SECONDS` after a drop.
    pub fn is_amber(&self, now: f64) -> bool {
        self.amber_until.is_some_and(|u| now < u)
    }

    /// Hover text with the count of the last play run.
    pub fn tooltip(&self) -> String {
        if !self.has_run {
            return "Dropped frames: none yet".to_string();
        }
        if self.last_run_drops == 0 {
            "Last play: no dropped frames".to_string()
        } else {
            format!(
                "Last play: {} dropped frame{}",
                self.last_run_drops,
                if self.last_run_drops == 1 { "" } else { "s" }
            )
        }
    }
}

/// What the Source viewer shows: nothing, the picture, or the waveform of audio-only media.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceViewerMode {
    /// Nothing open.
    Empty,
    /// The picture.
    Picture,
    /// The waveform of audio-only media.
    Waveform,
}

impl SourceViewerMode {
    /// Media with sound but no picture shows its waveform; unknown streams (not probed yet) count as picture.
    pub fn resolve(is_open: bool, has_video: bool, has_audio: bool) -> SourceViewerMode {
        if !is_open {
            return SourceViewerMode::Empty;
        }
        if !has_video && has_audio { SourceViewerMode::Waveform } else { SourceViewerMode::Picture }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_drop_while_playing_turns_amber_for_two_seconds() {
        let mut d = DropIndicator::default();
        d.update(0, true, 0.0);
        d.update(2, true, 1.0);
        assert!(d.is_amber(2.9));
        assert!(!d.is_amber(3.1));
        assert_eq!(d.badge_text().as_deref(), Some("2 dropped"));
    }

    #[test]
    fn five_drops_in_a_run_are_not_realtime() {
        let mut d = DropIndicator::default();
        d.update(0, true, 0.0);
        d.update(5, true, 1.0);
        assert!(d.realtime_not_achieved());
        assert_eq!(d.badge_text().as_deref(), Some("Realtime not achieved · 5 dropped"));
        d.update(5, false, 2.0);
        assert!(d.realtime_not_achieved());
    }

    #[test]
    fn a_smaller_total_rebases_and_the_tooltip_counts_the_last_run() {
        let mut d = DropIndicator::default();
        assert_eq!(d.tooltip(), "Dropped frames: none yet");
        d.update(10, true, 0.0);
        d.update(11, true, 0.5);
        assert_eq!(d.tooltip(), "Last play: 1 dropped frame");
        d.update(0, true, 1.0);
        assert_eq!(d.last_run_drops(), 0);
        assert_eq!(d.tooltip(), "Last play: no dropped frames");
    }

    #[test]
    fn audio_only_media_shows_the_waveform() {
        assert_eq!(SourceViewerMode::resolve(false, true, true), SourceViewerMode::Empty);
        assert_eq!(SourceViewerMode::resolve(true, false, true), SourceViewerMode::Waveform);
        assert_eq!(SourceViewerMode::resolve(true, false, false), SourceViewerMode::Picture);
        assert_eq!(SourceViewerMode::resolve(true, true, true), SourceViewerMode::Picture);
    }
}
