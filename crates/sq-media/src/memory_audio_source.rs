// Swift: MemoryAudioSource.swift
//! The `AudioSource` seam and an in-memory stereo source for tests and short generated sources.

use crate::media_error::MediaError;

/// Timeline-rate PCM access: f32, non-interleaved, stereo, at the sample rate the source was opened with
/// (`SequenceFormat.audioSampleRate`, 48 kHz). Frame numbers are in that rate, relative to the media start.
/// Implemented by the decoders (sq-media-ffmpeg) and the playback and export crates read through it.
pub trait AudioSource: Send + Sync {
    /// Copies up to `buffer.len()` frames of `channel` (0 = left, 1 = right) starting at `source_frame` into `buffer`.
    /// Returns the number of frames written; fewer than `buffer.len()` only at the end of the media (0 past the end).
    /// The caller zero-fills the rest. Blocking; call from the feeder thread, never from the render thread.
    fn read(&self, source_frame: i64, buffer: &mut [f32], channel: usize) -> Result<usize, MediaError>;

    /// The media itself has one channel (it is delivered as identical left and right). Decides the pan law.
    fn is_mono(&self) -> bool {
        false
    }
}

/// In-memory stereo PCM. Used for tests and for short generated sources.
#[derive(Clone, Debug, PartialEq)]
pub struct MemoryAudioSource {
    pub left: Vec<f32>,
    pub right: Vec<f32>,
    is_mono: bool,
}

impl MemoryAudioSource {
    /// Two separate channels.
    pub fn new(left: Vec<f32>, right: Vec<f32>) -> MemoryAudioSource {
        MemoryAudioSource { left, right, is_mono: false }
    }

    /// One channel, delivered as identical left and right.
    pub fn mono(mono: Vec<f32>) -> MemoryAudioSource {
        MemoryAudioSource { left: mono.clone(), right: mono, is_mono: true }
    }
}

impl AudioSource for MemoryAudioSource {
    fn read(&self, source_frame: i64, buffer: &mut [f32], channel: usize) -> Result<usize, MediaError> {
        let data = if channel == 0 { &self.left } else { &self.right };
        let Ok(start) = usize::try_from(source_frame) else { return Ok(0) };
        if start >= data.len() || buffer.is_empty() {
            return Ok(0);
        }
        let n = buffer.len().min(data.len() - start);
        buffer[..n].copy_from_slice(&data[start..start + n]);
        Ok(n)
    }

    fn is_mono(&self) -> bool {
        self.is_mono
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_clip_at_the_end_and_return_zero_past_it() {
        let s = MemoryAudioSource::mono(vec![1.0, 2.0, 3.0, 4.0]);
        assert!(s.is_mono());
        let mut b = [0.0f32; 3];
        assert_eq!(s.read(2, &mut b, 1), Ok(2));
        assert_eq!(b, [3.0, 4.0, 0.0]);
        assert_eq!(s.read(4, &mut b, 0), Ok(0));
        assert_eq!(s.read(-1, &mut b, 0), Ok(0));
        assert_eq!(s.read(0, &mut [], 0), Ok(0));
    }

    #[test]
    fn stereo_channels_are_separate() {
        let s = MemoryAudioSource::new(vec![1.0, 2.0], vec![5.0, 6.0]);
        assert!(!s.is_mono());
        let mut b = [0.0f32; 2];
        assert_eq!(s.read(0, &mut b, 1), Ok(2));
        assert_eq!(b, [5.0, 6.0]);
    }
}
