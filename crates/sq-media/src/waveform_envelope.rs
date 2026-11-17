//! Port of `SQMedia/Sources/SQMedia/WaveformEnvelope.swift`.
//!
//! Sync by audio (Create Angles Clip, Sync Audio to Reference): portable, so the Windows app reads the envelope from its
//! FFmpeg waveform.

use sq_core_audio::AudioGainPlan;
use sq_core_time::TimeRange;

use crate::waveform_data::WaveformData;

impl WaveformData {
    /// Steps per second of the sync envelopes: 10 ms, finer than a frame at any usual rate (`AnglesSync.envelopeRate`).
    pub const ENVELOPE_RATE: usize = 100;

    /// Loudness envelope for sync by audio: the peak over all channels per step, `rate` values per second.
    /// Built from the finest waveform level (256 samples per bucket: finer than one step at any usual sample rate).
    pub fn envelope(&self, rate: usize) -> Vec<f32> {
        let Some(base) = self.levels.first() else { return Vec::new() };
        if self.sample_rate == 0 || self.channel_count == 0 || rate == 0 || self.total_frames == 0 {
            return Vec::new();
        }
        let buckets = base.len() / (2 * self.channel_count);
        let (rate, sample_rate) = (rate as i64, self.sample_rate as i64);
        let count = ((self.total_frames as i64 * rate + sample_rate - 1) / sample_rate) as usize;
        if buckets == 0 || count == 0 {
            return Vec::new();
        }
        let mut out = vec![0f32; count];
        for b in 0..buckets {
            let step = (b as i64 * self.base_bucket_size as i64 * rate / sample_rate) as usize;
            if step >= count {
                break;
            }
            let mut peak = 0f32;
            for ch in 0..self.channel_count {
                let i = (b * self.channel_count + ch) * 2;
                peak = peak.max(base[i].abs()).max(base[i + 1].abs());
            }
            if peak > out[step] {
                out[step] = peak;
            }
        }
        out
    }
}

/// Swift: `extension AudioGainPlan` in WaveformEnvelope.swift.
pub trait AudioGainPlanPeakExt {
    /// Loudest sample of the clip's source range as linear 0...1 (Audio Gain's Normalize Peak), from the waveform.
    fn peak(data: &WaveformData, source: TimeRange) -> f64;
}

impl AudioGainPlanPeakExt for AudioGainPlan {
    fn peak(data: &WaveformData, source: TimeRange) -> f64 {
        let p = data.peaks(source, 1);
        p.iter().fold(0.0, |m, ch| {
            m.max(ch.iter().map(|b| f64::from(b.min.abs().max(b.max.abs()))).fold(f64::NEG_INFINITY, f64::max).max(0.0))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    /// Waveform of `seconds` at 48 kHz: silent except bursts (seconds range, level). No audio is decoded or played.
    fn waveform(seconds: usize, bursts: &[((f64, f64), f32)], channels: usize) -> WaveformData {
        let (rate, bucket) = (48_000, 256);
        let frames = seconds * rate;
        let buckets = frames.div_ceil(bucket);
        let mut level = vec![0f32; buckets * channels * 2];
        for b in 0..buckets {
            let t = (b * bucket) as f64 / rate as f64;
            let Some(hit) = bursts.iter().find(|h| h.0.0 <= t && t <= h.0.1) else { continue };
            // Only the last channel is loud: the envelope takes the peak over all channels.
            let i = (b * channels + channels - 1) * 2;
            level[i] = -hit.1;
            level[i + 1] = hit.1 / 2.0;
        }
        WaveformData::new(rate, channels, frames, bucket, vec![level])
    }

    #[test]
    fn envelope_has_one_value_per_step_and_follows_the_peaks() {
        let e = waveform(4, &[((1.0, 2.0), 0.8)], 2).envelope(100);
        assert_eq!(e.len(), 400);
        assert_eq!(e[50], 0.0);
        assert_eq!(e[150], 0.8); // the larger of |min| and |max|
        assert_eq!(e[250], 0.0);
    }

    #[test]
    fn empty_waveform_gives_no_envelope() {
        assert!(
            WaveformData::new(48_000, 2, 0, 256, vec![Vec::new()]).envelope(WaveformData::ENVELOPE_RATE).is_empty()
        );
    }

    #[test]
    fn peak_of_a_source_range_is_the_loudest_sample() {
        let wf = waveform(4, &[((1.0, 2.0), 0.8)], 2);
        assert_eq!(AudioGainPlan::peak(&wf, TimeRange::new(Time::ZERO, Time::new(4, 1))), f64::from(0.8f32));
        assert_eq!(AudioGainPlan::peak(&wf, TimeRange::new(Time::ZERO, Time::new(1, 2))), 0.0);
    }
}
