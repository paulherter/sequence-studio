// Swift: SpectrumDisplay.swift
//! What a popup's spectrum curve shows, from successive `AudioSpectrumTap` snapshots (pure, testable). A new sequence runs
//! the FFT (`spectrum`) and the curve rises at once; between readings it falls at `FALL_DB_PER_SECOND`. Nothing new for
//! `STALE_SECONDS` (stopped, or the playhead left the clip), or the effect is not watched: no curve.

/// The curve state of one spectrum plot.
#[derive(Clone, Debug, PartialEq)]
pub struct SpectrumDisplay {
    /// One level per `SpectrumAnalyzer.frequencies(points: POINTS)`, empty = nothing to draw.
    levels_db: Vec<f32>,
    last_sequence: u64,
    last_new_at: f64,
    last_time: f64,
}

impl Default for SpectrumDisplay {
    fn default() -> Self {
        SpectrumDisplay::new()
    }
}

impl SpectrumDisplay {
    /// Points of the curve.
    pub const POINTS: usize = 160;
    /// Seconds without a new reading after which the curve disappears.
    pub const STALE_SECONDS: f64 = 0.3;
    /// How fast the curve falls between readings.
    pub const FALL_DB_PER_SECOND: f32 = 40.0;
    /// The plot's top (dBFS of a sine).
    pub const TOP_DB: f32 = 0.0;
    /// The plot's bottom (dBFS of a sine).
    pub const BOTTOM_DB: f32 = -90.0;

    /// Nothing to draw yet.
    pub fn new() -> Self {
        SpectrumDisplay {
            levels_db: vec![],
            last_sequence: 0,
            last_new_at: f64::NEG_INFINITY,
            last_time: f64::NEG_INFINITY,
        }
    }

    /// The levels to draw.
    pub fn levels_db(&self) -> &[f32] {
        &self.levels_db
    }

    /// `sequence`: the tap's sequence for this effect (`None` = not watched, 0 = nothing published yet).
    pub fn update(&mut self, sequence: Option<u64>, time: f64, spectrum: impl FnOnce() -> Vec<f32>) {
        let dt = (time - self.last_time).max(0.0) as f32;
        self.last_time = time;
        let Some(sequence) = sequence.filter(|s| *s != 0) else {
            self.levels_db = vec![];
            return;
        };
        if sequence != self.last_sequence {
            self.last_sequence = sequence;
            self.last_new_at = time;
            let new = spectrum();
            if self.levels_db.len() != new.len() {
                self.levels_db = new;
                return;
            }
            for (level, n) in self.levels_db.iter_mut().zip(&new) {
                *level = n.max(*level - Self::FALL_DB_PER_SECOND * dt);
            }
            return;
        }
        if time - self.last_new_at > Self::STALE_SECONDS {
            self.levels_db = vec![];
            return;
        }
        for level in &mut self.levels_db {
            *level -= Self::FALL_DB_PER_SECOND * dt;
        }
    }

    /// 0 (bottom) ... 1 (top) of the plot for a level.
    pub fn fraction(db: f32) -> f32 {
        ((db - Self::BOTTOM_DB) / (Self::TOP_DB - Self::BOTTOM_DB)).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_reading_shows_at_once_and_falls_without_audio() {
        let mut d = SpectrumDisplay::new();
        assert!(d.levels_db().is_empty());
        d.update(Some(1), 0.0, || vec![-20.0, -40.0]);
        assert_eq!(d.levels_db(), [-20.0, -40.0]);
        // Same sequence = no new audio: the curve falls at `FALL_DB_PER_SECOND`.
        d.update(Some(1), 0.1, || panic!("no FFT without new audio"));
        assert!((d.levels_db()[0] - (-20.0 - SpectrumDisplay::FALL_DB_PER_SECOND * 0.1)).abs() < 0.01);
        // A new reading rises at once, a lower one only pulls the curve down at the fall rate.
        d.update(Some(2), 0.2, || vec![-10.0, -90.0]);
        assert_eq!(d.levels_db()[0], -10.0);
        assert!((d.levels_db()[1] - (-40.0 - SpectrumDisplay::FALL_DB_PER_SECOND * 0.2)).abs() < 0.01);
    }

    #[test]
    fn stale_or_unwatched_clears() {
        let mut d = SpectrumDisplay::new();
        d.update(Some(3), 1.0, || vec![-30.0]);
        d.update(Some(3), 1.0 + SpectrumDisplay::STALE_SECONDS + 0.01, Vec::new);
        assert!(d.levels_db().is_empty());
        d.update(Some(4), 2.0, || vec![-30.0]);
        d.update(None, 2.01, Vec::new);
        assert!(d.levels_db().is_empty());
        // Sequence 0 = nothing published since watching began.
        d.update(Some(0), 3.0, || vec![-30.0]);
        assert!(d.levels_db().is_empty());
    }

    #[test]
    fn plot_mapping() {
        assert_eq!(SpectrumDisplay::fraction(SpectrumDisplay::TOP_DB), 1.0);
        assert_eq!(SpectrumDisplay::fraction(SpectrumDisplay::BOTTOM_DB), 0.0);
        assert!(SpectrumDisplay::fraction(-200.0) == 0.0 && SpectrumDisplay::fraction(10.0) == 1.0);
    }
}
