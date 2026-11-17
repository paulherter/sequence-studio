// Swift: FrameSource.swift, ExportEncoding.swift (the three traits of the design, section 1)
//
// Swift's `async` reads become blocking calls; `&mut self` encodes "never called concurrently" (one export thread owns
// its sources). Cancellation is a `CancelToken` argument instead of `Task.isCancelled`.

use super::error::{CancelToken, ExportError};
use super::loudness::LoudnessReport;
use super::settings::{AudioFileFormat, AudioSettings, ExportSettings};
use sq_core_time::Time;
use std::ops::Range;
use std::path::Path;

/// A rendered export frame: the neutral `SQFrame` (CPU bytes or a GPU texture).
pub type ExportFrame = sq_frame::sqframe::SQFrame;

/// Supplies rendered video frames (BGRA, Rec.709 display-referred) for export.
pub trait FrameSource: Send {
    /// Number of frames.
    fn frame_count(&self) -> usize;
    /// Duration of one frame.
    fn frame_duration(&self) -> Time;
    /// Frame `index`, rendered on demand.
    fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError>;
}

/// A frame source that can be split into independent sources over sub-ranges of its frames: each segment renders and
/// decodes on its own, frame 0 of a segment is frame `range.start` of the whole.
pub trait SegmentableFrameSource: FrameSource {
    /// False when segments would share state that serializes them (then the writer exports in one piece).
    fn is_segmentable(&self) -> bool {
        true
    }

    /// An independent source over `range`.
    fn segment(&self, range: Range<usize>) -> Result<Box<dyn FrameSource>, ExportError>;
}

/// Interleaved f32 PCM.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioChunk {
    /// Interleaved samples.
    pub samples: Vec<f32>,
    /// Channel count.
    pub channels: usize,
}

impl AudioChunk {
    /// A chunk of interleaved samples.
    pub fn new(samples: Vec<f32>, channels: usize) -> AudioChunk {
        AudioChunk { samples, channels }
    }

    /// Frames in the chunk.
    pub fn frame_count(&self) -> usize {
        self.samples.len().checked_div(self.channels).unwrap_or(0)
    }
}

/// Supplies mixed audio for export.
pub trait AudioSource: Send {
    /// Sample rate in Hz.
    fn sample_rate(&self) -> i64;
    /// Channel count.
    fn channels(&self) -> usize;
    /// Next chunk of at most `max_frames` frames, or `None` at the end.
    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError>;

    /// Swift's `as? RewindableAudioSource`: the source seen as rewindable, when it is.
    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        None
    }
}

/// An audio source that can be read again from the start (needed for two-pass processing).
pub trait RewindableAudioSource: AudioSource {
    /// Back to the first frame.
    fn rewind(&mut self) -> Result<(), ExportError>;
}

/// Generated sine tone (tests).
pub struct SineAudioSource {
    sample_rate: i64,
    channels: usize,
    /// Frames in total.
    pub total_frames: usize,
    frequency: i64,
    amplitude: f32,
    position: usize,
}

impl SineAudioSource {
    /// A tone of `duration` (440 Hz at amplitude 0.25 in Swift's defaults).
    pub fn new(sample_rate: i64, channels: usize, duration: Time, frequency: i64, amplitude: f32) -> SineAudioSource {
        let total = i128::from(duration.value()) * i128::from(sample_rate) / i128::from(duration.timescale());
        SineAudioSource { sample_rate, channels, total_frames: total as usize, frequency, amplitude, position: 0 }
    }
}

impl AudioSource for SineAudioSource {
    fn sample_rate(&self) -> i64 {
        self.sample_rate
    }

    fn channels(&self) -> usize {
        self.channels
    }

    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        let n = max_frames.min(self.total_frames - self.position);
        if n == 0 {
            return Ok(None);
        }
        let mut out = vec![0.0f32; n * self.channels];
        for i in 0..n {
            // Phase from integer arithmetic: (position * frequency) mod sampleRate.
            let phase =
                ((self.position + i) as i64 * self.frequency % self.sample_rate) as f64 / self.sample_rate as f64;
            let v = (2.0 * std::f64::consts::PI * phase).sin() as f32 * self.amplitude;
            for c in 0..self.channels {
                out[i * self.channels + c] = v;
            }
        }
        self.position += n;
        Ok(Some(AudioChunk::new(out, self.channels)))
    }

    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl RewindableAudioSource for SineAudioSource {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.position = 0;
        Ok(())
    }
}

/// The encoder side of export: writes a file from rendered frames and timeline audio. The Windows and portable
/// implementation is the FFmpeg encoder in `sq-media-ffmpeg`; a Mac fast path may implement it too. `progress` receives
/// 0...1 and ends at 1. A cancelled `cancel` removes the partial file and returns `ExportError::Cancelled`.
pub trait ExportEncoding: Send + Sync {
    /// Writes the video file (or GIF, or image-sequence folder) to `url`.
    fn export(
        &self,
        video: &mut dyn FrameSource,
        audio: Option<&mut dyn AudioSource>,
        settings: &ExportSettings,
        url: &Path,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError>;

    /// One audio file (a stem, a language track) from `audio`: M4A, WAV or FLAC of `duration`, normalized when
    /// `settings` asks. Encoders without audio files (test fakes) say so.
    #[allow(clippy::too_many_arguments)]
    fn export_audio_file(
        &self,
        _audio: &mut dyn AudioSource,
        _format: AudioFileFormat,
        _duration: Time,
        _settings: &AudioSettings,
        _url: &Path,
        _cancel: &CancelToken,
        _progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        Err(ExportError::WriterFailed("this encoder writes no audio files".to_string()))
    }
}
