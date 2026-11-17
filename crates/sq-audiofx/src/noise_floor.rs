//! The noise floor of a short capture (the playhead region), for "Learn Noise". Pure.

/// Measures the floor of a mono capture.
pub enum NoiseFloor {}

impl NoiseFloor {
    /// Window length of the level curve.
    pub const WINDOW_SECONDS: f64 = 0.05;
    /// Captures shorter than this (seconds) give no floor.
    pub const MIN_SECONDS: f64 = 0.2;

    /// The floor in dBFS: the RMS of 50 ms windows, taking the quietest 10 % (a floor sits under speech and music, so the
    /// average would be too high). `None` for captures that are too short or have no windows.
    pub fn db(samples: &[f32], sample_rate: f64) -> Option<f64> {
        if sample_rate <= 0.0 || (samples.len() as f64) < Self::MIN_SECONDS * sample_rate {
            return None;
        }
        let win = ((Self::WINDOW_SECONDS * sample_rate) as usize).max(1);
        let mut levels: Vec<f64> = samples
            .chunks_exact(win)
            .map(|w| {
                let ms = w.iter().map(|x| f64::from(*x) * f64::from(*x)).sum::<f64>() / win as f64;
                10.0 * ms.max(1e-12).log10()
            })
            .collect();
        if levels.is_empty() {
            return None;
        }
        levels.sort_by(f64::total_cmp);
        let n = (levels.len() / 10).max(1);
        Some(levels[..n].iter().sum::<f64>() / n as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise(len: usize, amp: f32) -> Vec<f32> {
        // A deterministic pseudo-noise (no rand dependency).
        let mut s = 12345u32;
        (0..len)
            .map(|_| {
                s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                ((s >> 8) as f32 / 8_388_608.0 - 1.0) * amp
            })
            .collect()
    }

    #[test]
    fn a_floor_under_louder_speech_is_found() {
        let mut x = noise(48_000, 0.01);
        x.extend(noise(48_000, 0.5));
        let db = NoiseFloor::db(&x, 48_000.0).expect("floor");
        assert!((-47.0..-42.0).contains(&db), "{db}");
    }

    #[test]
    fn short_or_silent_captures() {
        assert_eq!(NoiseFloor::db(&noise(100, 0.1), 48_000.0), None);
        let db = NoiseFloor::db(&vec![0.0; 48_000], 48_000.0).expect("floor");
        assert!(db <= -100.0);
    }
}
