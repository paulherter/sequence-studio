// Swift: AudioDriftFit.swift (`Timeline.syncAudio` waits for the edit crate, see NOTES.md)
//! Audio sync with drift: two recordings of one event whose clocks run slightly apart (camera against a recorder). This
//! file holds the result type and the two non-audio modes; the sound fit is on loudness envelopes (`AnglesAudioSync`).

use crate::angles_audio_sync::AnglesAudioSync;
use sq_core_model::ClipSpeed;
use sq_core_time::Time;

/// How a sync was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioSyncMethod {
    /// Loudness envelopes.
    Sound,
    /// Start time of day (timecode).
    Timecode,
    /// Whole-second capture dates.
    CaptureDate,
}

/// The result of a sync fit.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioDriftFit {
    /// Where the other file's time 0 lies on the reference file's clock (positive: other started later).
    pub offset: Time,
    /// Growth of the lag per second of the other file: `lag(t) = offset + drift_ratio * t`. 0 = no drift found.
    pub drift_ratio: f64,
    /// Mean correlation of the chunks that took part, 0...1 (1 for timecode).
    pub confidence: f64,
    /// Chunks that took part.
    pub chunks_used: usize,
    /// Chunks tried.
    pub chunk_count: usize,
    /// How it was found.
    pub method: AudioSyncMethod,
}

impl AudioDriftFit {
    /// Below this ratio (10 ppm, 36 ms per hour) a drift is not corrected.
    pub const MINIMUM_DRIFT: f64 = 1e-5;
    /// Chunks shorter than this many seconds correlate too loosely to place; fewer chunks are used instead.
    pub const MINIMUM_CHUNK_SECONDS: usize = 10;

    /// Speed that lines the other recording up with the reference over its whole length; `None` when the drift is below
    /// `MINIMUM_DRIFT` (a retime would change nothing audible).
    pub fn correcting_speed(&self) -> Option<ClipSpeed> {
        if !(self.drift_ratio.abs() >= Self::MINIMUM_DRIFT && self.drift_ratio > -0.5) {
            return None;
        }
        // Source time p lands at p * (1 + drift) on the reference clock: play it at 1 / (1 + drift).
        let scale: i64 = 1_000_000;
        let num = (scale as f64 / (1.0 + self.drift_ratio)).round() as i64;
        let s = ClipSpeed::new(num, scale);
        (s != ClipSpeed::NORMAL).then_some(s)
    }

    /// `None` when the recordings do not match as a whole (silence, too short, below `AnglesAudioSync::WEAK_CONFIDENCE`,
    /// or the offset lies outside `search_window`, an optional limit on |offset| in seconds). `rate`: envelope values per
    /// second. With fewer than 3 usable chunks the drift is 0 and only the offset is reported.
    pub fn fit(
        reference: &[f32],
        other: &[f32],
        rate: i64,
        chunk_count: usize,
        search_window: Option<f64>,
    ) -> Option<AudioDriftFit> {
        // The whole-file match is only a starting lag: with drift its correlation is smeared and may be weak, so the
        // confidence gate applies to the chunks (or to this match when no drift can be fitted).
        if rate <= 0 {
            return None;
        }
        let global = AnglesAudioSync::find_default(reference, other)?;
        if search_window.is_some_and(|w| (global.lag as f64).abs() / rate as f64 > w) {
            return None;
        }
        let single = AudioDriftFit {
            offset: Time::new(global.lag, rate),
            drift_ratio: 0.0,
            confidence: global.confidence,
            chunks_used: 1,
            chunk_count: 1,
            method: AudioSyncMethod::Sound,
        };
        let fallback = || (global.confidence >= AnglesAudioSync::WEAK_CONFIDENCE).then(|| single.clone());
        let chunks = chunk_count.min(other.len() / (Self::MINIMUM_CHUNK_SECONDS * rate as usize));
        if chunks < 3 {
            return fallback();
        }
        let length = other.len() / chunks;
        let window = (3 * rate).max(other.len() as i64 / 50);
        let (mut xs, mut ys, mut ws) = (Vec::new(), Vec::new(), Vec::new());
        for k in 0..chunks {
            let from = (k * length) as i64;
            let to = if k == chunks - 1 { other.len() as i64 } else { from + length as i64 };
            let base = (from + global.lag - window).max(0);
            let top = (reference.len() as i64).min(to + global.lag + window);
            if top - base < (to - from) / 2 {
                continue;
            }
            let piece = &other[from as usize..to as usize];
            let found = AnglesAudioSync::find_match(
                &reference[base as usize..top as usize],
                piece,
                Some(((to - from) / 2) as usize),
                4096,
            );
            let Some(m) = found.filter(|m| m.confidence >= AnglesAudioSync::WEAK_CONFIDENCE) else { continue };
            // piece[i] lines up with reference[base + i + m.lag]; other[from + i] with reference[from + i + lag].
            xs.push((from + to) as f64 / 2.0);
            ys.push((m.lag + base - from) as f64);
            ws.push(m.confidence);
        }
        if xs.len() < 3 {
            return fallback();
        }
        let Some(mut line) = regression(&xs, &ys, &ws) else { return fallback() };
        // One pass of outlier rejection: chunks that hit a repeated phrase or a noisy stretch.
        let residuals: Vec<f64> =
            xs.iter().zip(&ys).map(|(x, y)| (y - (line.intercept + line.slope * x)).abs()).collect();
        let mut sorted = residuals.clone();
        sorted.sort_by(f64::total_cmp);
        let limit = (3.0f64).max(3.0 * sorted[residuals.len() / 2]);
        let keep: Vec<usize> = (0..residuals.len()).filter(|&i| residuals[i] <= limit).collect();
        if keep.len() < 3 {
            return fallback();
        }
        if keep.len() < xs.len() {
            let pick = |v: &[f64]| keep.iter().map(|&i| v[i]).collect::<Vec<_>>();
            if let Some(again) = regression(&pick(&xs), &pick(&ys), &pick(&ws)) {
                line = again;
            }
        }
        let confidence = keep.iter().fold(0.0, |a, &i| a + ws[i]) / keep.len() as f64;
        Some(AudioDriftFit {
            offset: Time::new(line.intercept.round() as i64, rate),
            drift_ratio: line.slope,
            confidence: confidence.min(1.0),
            chunks_used: keep.len(),
            chunk_count: chunks,
            method: AudioSyncMethod::Sound,
        })
    }

    /// Timecode mode: both files carry a start time of day (timecode, or the capture date as the caller's fallback); the
    /// offset is the difference and nothing drifts.
    pub fn timecode(reference: Time, other: Time) -> AudioDriftFit {
        AudioDriftFit {
            offset: other - reference,
            drift_ratio: 0.0,
            confidence: 1.0,
            chunks_used: 1,
            chunk_count: 1,
            method: AudioSyncMethod::Timecode,
        }
    }

    /// Last resort: whole-second capture dates of the two files. Accurate only to about a second, so callers warn.
    pub fn capture_date(reference: Time, other: Time) -> AudioDriftFit {
        AudioDriftFit { method: AudioSyncMethod::CaptureDate, ..Self::timecode(reference, other) }
    }
}

/// Weighted least-squares line through (x, y).
struct Line {
    intercept: f64,
    slope: f64,
}

fn regression(x: &[f64], y: &[f64], w: &[f64]) -> Option<Line> {
    let sw: f64 = w.iter().sum();
    if sw <= 0.0 {
        return None;
    }
    let mx = x.iter().zip(w).fold(0.0, |a, (x, w)| a + x * w) / sw;
    let my = y.iter().zip(w).fold(0.0, |a, (y, w)| a + y * w) / sw;
    let (mut sxx, mut sxy) = (0.0, 0.0);
    for i in 0..x.len() {
        sxx += w[i] * (x[i] - mx) * (x[i] - mx);
        sxy += w[i] * (x[i] - mx) * (y[i] - my);
    }
    if sxx <= 0.0 {
        return None;
    }
    let slope = sxy / sxx;
    Some(Line { intercept: my - slope * mx, slope })
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::angles_audio_sync::test_envelope as scene;

    /// The other recording: reference sampled `1 + drift` times slower, starting `lag` steps in.
    fn recorded(reference: &[f32], lag: i64, drift: f64, count: usize) -> Vec<f32> {
        (0..count)
            .map(|i| {
                let j = (i as f64 * (1.0 + drift) + lag as f64).round() as i64;
                if j >= 0 && (j as usize) < reference.len() { reference[j as usize] } else { 0.0 }
            })
            .collect()
    }

    fn sound(r: &[f32], o: &[f32], window: Option<f64>) -> Option<AudioDriftFit> {
        AudioDriftFit::fit(r, o, 100, 8, window)
    }

    #[test]
    fn no_drift_gives_offset_and_no_retime() {
        let r = scene(60_000, 11);
        let f = sound(&r, &recorded(&r, 1234, 0.0, 50_000), None).expect("fit");
        assert_eq!(f.offset, Time::new(1234, 100));
        assert!(f.drift_ratio.abs() < 1e-5);
        assert!(f.correcting_speed().is_none());
        assert!(f.chunks_used >= 6);
    }

    #[test]
    fn drift_is_fitted_and_offset_is_at_time_zero() {
        let r = scene(80_000, 12);
        let f = sound(&r, &recorded(&r, 500, 0.002, 60_000), None).expect("fit");
        assert!((f.drift_ratio - 0.002).abs() < 0.0004);
        assert!((f.offset.value() as f64 / f.offset.timescale() as f64 - 5.0).abs() < 0.1);
        let s = f.correcting_speed().expect("retime");
        assert!((s.num() as f64 / s.den() as f64 - 1.0 / 1.002).abs() < 0.0005);
    }

    #[test]
    fn search_window_refuses_far_offsets() {
        let r = scene(60_000, 13);
        let o = recorded(&r, 3000, 0.0, 40_000);
        assert!(sound(&r, &o, Some(10.0)).is_none());
        assert!(sound(&r, &o, Some(60.0)).is_some());
    }

    #[test]
    fn short_recordings_report_offset_only() {
        let r = scene(3000, 14);
        let f = sound(&r, &recorded(&r, 200, 0.0, 2000), None).expect("fit");
        assert!(f.drift_ratio == 0.0 && f.chunk_count == 1);
    }

    fn fit(drift: f64) -> AudioDriftFit {
        AudioDriftFit { drift_ratio: drift, ..AudioDriftFit::timecode(Time::ZERO, Time::ZERO) }
    }

    #[test]
    fn tiny_or_missing_drift_needs_no_retime() {
        assert_eq!(fit(0.0).correcting_speed(), None);
        assert_eq!(fit(5e-6).correcting_speed(), None);
        assert_eq!(fit(-0.5).correcting_speed(), None);
    }

    #[test]
    fn a_drift_plays_the_other_recording_at_one_over_one_plus_drift() {
        let s = fit(0.001).correcting_speed();
        assert_eq!(s, Some(ClipSpeed::new(999_001, 1_000_000)));
        assert!(fit(-0.001).correcting_speed().is_some_and(|s| s.num() > s.den()));
    }

    #[test]
    fn timecode_and_capture_date_modes_do_not_drift() {
        let f = AudioDriftFit::timecode(Time::new(3600, 1), Time::new(3602, 1));
        assert!(f.offset == Time::new(2, 1) && f.method == AudioSyncMethod::Timecode && f.correcting_speed().is_none());
        let f = AudioDriftFit::capture_date(Time::new(100, 1), Time::new(103, 1));
        assert!(
            f.offset == Time::new(3, 1) && f.method == AudioSyncMethod::CaptureDate && f.correcting_speed().is_none()
        );
    }
}
