//! Port of `SQMedia/Sources/SQMedia/PeakPyramid.swift`.
//!
//! Portable peaks (no Accelerate): the scalar twin of the Mac's `PeakAccumulator` and the pyramid of mip levels, so Windows
//! builds the same `WaveformData` the Mac builds.

use std::fmt;

use crate::media_error::MediaError;
use crate::memory_audio_source::AudioSource;
use crate::waveform_data::{WaveformData, WaveformError};

/// Min/max per channel and bucket of sample frames, built from planar float buffers.
#[derive(Debug, Clone)]
pub struct ScalarPeakAccumulator {
    channels: usize,
    bucket_size: usize,
    frames: usize,
    base: Vec<f32>,
    lo: Vec<f32>,
    hi: Vec<f32>,
    in_bucket: usize,
}

impl ScalarPeakAccumulator {
    /// `channels` and `bucket_size` must be above zero.
    pub fn new(channels: usize, bucket_size: usize) -> Self {
        debug_assert!(channels > 0 && bucket_size > 0);
        ScalarPeakAccumulator {
            channels,
            bucket_size,
            frames: 0,
            base: Vec::new(),
            lo: vec![f32::MAX; channels],
            hi: vec![-f32::MAX; channels],
            in_bucket: 0,
        }
    }

    /// Channel count.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Bucket size in sample frames.
    pub fn bucket_size(&self) -> usize {
        self.bucket_size
    }

    /// Sample frames added so far.
    pub fn frames(&self) -> usize {
        self.frames
    }

    /// One buffer per channel, each at least `n` frames long.
    pub fn add(&mut self, planar: &[&[f32]], n: usize) {
        debug_assert_eq!(planar.len(), self.channels);
        let mut f = 0;
        while f < n {
            let take = (self.bucket_size - self.in_bucket).min(n - f);
            for (c, plane) in planar.iter().enumerate() {
                let mut mn = self.lo[c];
                let mut mx = self.hi[c];
                for &v in &plane[f..f + take] {
                    if v < mn {
                        mn = v;
                    }
                    if v > mx {
                        mx = v;
                    }
                }
                self.lo[c] = mn;
                self.hi[c] = mx;
            }
            self.in_bucket += take;
            f += take;
            if self.in_bucket == self.bucket_size {
                self.flush();
            }
        }
        self.frames += n;
    }

    fn flush(&mut self) {
        for c in 0..self.channels {
            self.base.push(self.lo[c]);
            self.base.push(self.hi[c]);
            self.lo[c] = f32::MAX;
            self.hi[c] = -f32::MAX;
        }
        self.in_bucket = 0;
    }

    /// Level 0 (`[b0c0min, b0c0max, b0c1min, ...]`), the last partial bucket included.
    pub fn finish(&mut self) -> Vec<f32> {
        if self.in_bucket > 0 {
            self.flush();
        }
        std::mem::take(&mut self.base)
    }
}

/// Why peaks of an audio source could not be built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PeakError {
    /// The source gave no audio at all.
    Waveform(WaveformError),
    /// The source failed while reading.
    Media(MediaError),
}

impl fmt::Display for PeakError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PeakError::Waveform(e) => e.fmt(f),
            PeakError::Media(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for PeakError {}

impl From<MediaError> for PeakError {
    fn from(e: MediaError) -> Self {
        PeakError::Media(e)
    }
}

/// The pyramid of mip levels over level 0 peaks.
pub struct PeakPyramid;

impl PeakPyramid {
    /// The next coarser level: each pair of buckets becomes one (min of mins, max of maxes); an odd last bucket stays.
    pub fn mip(src: &[f32], channels: usize) -> Vec<f32> {
        let stride = 2 * channels;
        let n = src.len() / stride;
        let m = n.div_ceil(2);
        let mut dst = vec![0f32; m * stride];
        for i in 0..m {
            for c in 0..channels {
                let a = (2 * i) * stride + c * 2;
                let (mut l, mut h) = (src[a], src[a + 1]);
                if 2 * i + 1 < n {
                    let b = (2 * i + 1) * stride + c * 2;
                    l = l.min(src[b]);
                    h = h.max(src[b + 1]);
                }
                dst[i * stride + c * 2] = l;
                dst[i * stride + c * 2 + 1] = h;
            }
        }
        dst
    }

    /// Level 0 plus mip levels down to two buckets, as `Waveform.build` returns them.
    pub fn waveform(
        level0: Vec<f32>,
        channels: usize,
        frames: usize,
        bucket_size: usize,
        sample_rate: usize,
    ) -> WaveformData {
        let mut levels = vec![level0];
        while levels[levels.len() - 1].len() / (2 * channels) > 2 {
            let next = Self::mip(&levels[levels.len() - 1], channels);
            levels.push(next);
        }
        WaveformData::new(sample_rate, channels, frames, bucket_size, levels)
    }

    /// Peaks of an `AudioSource` (decoded at `sample_rate`), read start to end in chunks; a mono source gives one channel.
    /// `Ok(None)` when canceled.
    pub fn waveform_from(
        source: &dyn AudioSource,
        sample_rate: usize,
        base_bucket_size: usize,
        chunk: usize,
        mut is_cancelled: impl FnMut() -> bool,
    ) -> Result<Option<WaveformData>, PeakError> {
        let channels = if source.is_mono() { 1 } else { 2 };
        let mut acc = ScalarPeakAccumulator::new(channels, base_bucket_size);
        let mut bufs = vec![vec![0f32; chunk]; channels];
        let mut at: i64 = 0;
        loop {
            if is_cancelled() {
                return Ok(None);
            }
            let mut n = 0;
            for (c, buf) in bufs.iter_mut().enumerate() {
                let got = source.read(at, buf, c)?;
                n = if c == 0 { got } else { n.min(got) };
            }
            if n == 0 {
                break;
            }
            let planar: Vec<&[f32]> = bufs.iter().map(Vec::as_slice).collect();
            acc.add(&planar, n);
            at += n as i64;
            if n < chunk {
                break;
            }
        }
        let frames = acc.frames();
        let level0 = acc.finish();
        if level0.is_empty() {
            return Err(PeakError::Waveform(WaveformError::NoAudioTrack));
        }
        Ok(Some(Self::waveform(level0, channels, frames, base_bucket_size, sample_rate)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory_audio_source::MemoryAudioSource;

    fn noise(n: usize, seed: u64) -> Vec<f32> {
        let mut x = seed;
        (0..n)
            .map(|_| {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                ((x >> 11) as i64 % 2000) as f32 / 1000.0 - 1.0
            })
            .collect()
    }

    fn min_max(s: &[f32]) -> (f32, f32) {
        (s.iter().copied().fold(f32::MAX, f32::min), s.iter().copied().fold(-f32::MAX, f32::max))
    }

    #[test]
    fn source_peaks_match_a_scalar_loop_and_the_pyramid_halves() {
        let (l, r) = (noise(10_000, 1), noise(10_000, 2));
        let src = MemoryAudioSource::new(l.clone(), r);
        let wf = PeakPyramid::waveform_from(&src, 48_000, 256, 1000, || false).ok().flatten();
        let Some(wf) = wf else { panic!("no waveform") };
        assert!(wf.channel_count == 2 && wf.total_frames == 10_000 && wf.base_bucket_size == 256);
        let level0 = &wf.levels[0];
        assert_eq!(level0.len(), 40 * 4); // 40 buckets (the last partial) x 2 channels x min/max
        for b in 0..40 {
            let (mn, mx) = min_max(&l[b * 256..((b + 1) * 256).min(l.len())]);
            assert!(level0[b * 4] == mn && level0[b * 4 + 1] == mx);
        }
        assert_eq!(wf.levels[1].len(), 20 * 4);
        assert!(wf.levels[1][0] == level0[0].min(level0[4]) && wf.levels[1][1] == level0[1].max(level0[5]));
        assert!(wf.levels[wf.levels.len() - 1].len() / 4 <= 2);
    }

    #[test]
    fn mono_source_gives_one_channel_and_cancel_stops() {
        let wf = PeakPyramid::waveform_from(
            &MemoryAudioSource::mono(noise(3000, 3)),
            48_000,
            WaveformData::DEFAULT_BASE_BUCKET_SIZE,
            1 << 16,
            || false,
        );
        assert_eq!(wf.ok().flatten().map(|w| w.channel_count), Some(1));
        let canceled = PeakPyramid::waveform_from(&MemoryAudioSource::mono(vec![0.5]), 48_000, 256, 1 << 16, || true);
        assert_eq!(canceled.ok(), Some(None));
    }

    #[test]
    fn silence_less_source_has_no_audio_track() {
        let empty = PeakPyramid::waveform_from(&MemoryAudioSource::mono(Vec::new()), 48_000, 256, 1 << 16, || false);
        assert_eq!(empty.err(), Some(PeakError::Waveform(WaveformError::NoAudioTrack)));
    }

    #[test]
    fn mip_keeps_an_odd_last_bucket() {
        // 3 buckets, 1 channel: (min, max) pairs.
        let src = [0.0, 1.0, -1.0, 0.5, -0.25, 2.0];
        assert_eq!(PeakPyramid::mip(&src, 1), vec![-1.0, 1.0, -0.25, 2.0]);
    }
}
