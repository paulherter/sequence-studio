//! Tests of the export core: the portable Swift tests of `Packages/SQExport/Tests`, translated, plus goldens dumped by
//! the Swift code (`oracle/sq-export/core`).

mod delivery_tests;
mod golden_tests;
mod loudness_tests;
mod misc_tests;
mod preset_tests;
mod queue_state_tests;
pub(crate) mod queue_tests;
mod settings_tests;
mod stems_tests;

use crate::core::{AudioChunk, AudioSource, ExportError, RewindableAudioSource};
use sq_core_model::{DeliveryPlatform, DeliveryTarget, SequenceFormat};
use sq_core_time::Time;

pub(crate) fn fmt(w: i64, h: i64) -> SequenceFormat {
    let mut f = SequenceFormat::new(Time::new(1, 30));
    f.width = w;
    f.height = h;
    f
}

pub(crate) fn target(platform: DeliveryPlatform) -> DeliveryTarget {
    DeliveryTarget { platform, target_lufs: -14.0, true_peak_db: -1.0 }
}

/// A fixed buffer served in chunks; rewindable.
pub(crate) struct BufferSource {
    pub rate: i64,
    pub channels: usize,
    pub samples: Vec<f32>,
    pub pos: usize,
}

impl BufferSource {
    pub fn new(rate: i64, channels: usize, samples: Vec<f32>) -> BufferSource {
        BufferSource { rate, channels, samples, pos: 0 }
    }
}

impl AudioSource for BufferSource {
    fn sample_rate(&self) -> i64 {
        self.rate
    }
    fn channels(&self) -> usize {
        self.channels
    }
    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        let total = self.samples.len() / self.channels;
        let n = max_frames.min(total - self.pos);
        if n == 0 {
            return Ok(None);
        }
        let c = AudioChunk::new(
            self.samples[self.pos * self.channels..(self.pos + n) * self.channels].to_vec(),
            self.channels,
        );
        self.pos += n;
        Ok(Some(c))
    }
    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl RewindableAudioSource for BufferSource {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.pos = 0;
        Ok(())
    }
}
