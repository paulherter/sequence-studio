// Swift: TimelineAudioSource.swift, ExportFrameCount.swift

use super::error::ExportError;
use super::traits::{AudioChunk, AudioSource, RewindableAudioSource};
use sq_core_time::{Time, TimeRange};

/// Frames of a range at a frame duration (rounded up: the last, partial frame is still written).
pub fn export_frame_count(range: TimeRange, frame_duration: Time) -> usize {
    let n = i128::from(range.duration.value()) * i128::from(frame_duration.timescale());
    let d = i128::from(range.duration.timescale()) * i128::from(frame_duration.value());
    if d <= 0 || n <= 0 {
        return 0;
    }
    (n / d + i128::from(n % d > 0)) as usize
}

/// The offline mixer behind `TimelineAudioSource`: the playback audio feeder (`sq-playback`, clip/nest volume, per-track
/// FX presets, latency compensation, nested sequences) with its ring buffer. The playback crate implements this for its
/// feeder; tests use a fake.
pub trait MixFeed: Send {
    /// Moves the read position to this frame (48 kHz) of the timeline.
    fn seek(&mut self, frame: i64);
    /// Renders the first block after a seek so the feeder applies it (flush, FX reset, latency), and returns the FX
    /// latency in frames that must be dropped from the start.
    fn prime(&mut self) -> usize;
    /// Renders up to `max_blocks` blocks into the ring; returns the blocks rendered (0 at the end of the timeline).
    fn fill(&mut self, max_blocks: usize) -> usize;
    /// Frames waiting in the ring.
    fn available_to_read(&self) -> usize;
    /// Pops `left.len()` frames into both slices (the slices have equal length, at most `available_to_read`).
    fn pop(&mut self, left: &mut [f32], right: &mut [f32]);
}

/// Output sample rate of the export mix.
pub const MIX_SAMPLE_RATE: i64 = 48_000;

/// Offline audio for export: the timeline mixed by the feeder at 48 kHz stereo, read in order from `range.start`.
/// Rewindable, so loudness normalization can measure first.
// The Swift class ran all blocking reads on one dedicated queue to keep them off the cooperative pool; here the export
// thread owns the source and reads directly.
pub struct TimelineAudioSource<F: MixFeed> {
    feed: F,
    channels: usize,
    /// Frames this source delivers in total (`range.duration` at 48 kHz, rounded up).
    pub total_frames: usize,
    start_frame: i64,
    produced: usize,
    skipped: usize,
    needs_seek: bool,
}

fn ceil_frames(t: Time) -> i64 {
    let n = i128::from(t.value()) * i128::from(MIX_SAMPLE_RATE);
    let d = i128::from(t.timescale());
    (n / d + i128::from(n % d > 0)) as i64
}

impl<F: MixFeed> TimelineAudioSource<F> {
    /// `channels` is 2, or 1 for a Mono sequence: the feeder already folded the mix to dual mono, so the export keeps
    /// one of the two identical channels.
    pub fn new(feed: F, channels: usize, range: TimeRange) -> TimelineAudioSource<F> {
        let start_frame = ceil_frames(range.start);
        TimelineAudioSource {
            feed,
            channels,
            total_frames: (ceil_frames(range.end()) - start_frame).max(0) as usize,
            start_frame,
            produced: 0,
            skipped: 0,
            needs_seek: true,
        }
    }

    /// The feed behind the source.
    pub fn feed(&self) -> &F {
        &self.feed
    }

    fn produce(&mut self, max_frames: usize) -> Option<AudioChunk> {
        if self.needs_seek {
            self.needs_seek = false;
            self.feed.seek(self.start_frame);
            self.skipped = self.feed.prime();
        }
        let want = max_frames.min(self.total_frames - self.produced);
        if want == 0 {
            return None;
        }
        let mut l = vec![0.0f32; want];
        let mut r = vec![0.0f32; want];
        let mut got = 0;
        while got < want {
            if self.feed.available_to_read() == 0 && self.feed.fill(4) == 0 && self.feed.available_to_read() == 0 {
                break;
            }
            let n = (want - got).min(self.feed.available_to_read());
            if self.skipped > 0 {
                let drop = self.skipped.min(n);
                let (mut tl, mut tr) = (vec![0.0f32; drop], vec![0.0f32; drop]);
                self.feed.pop(&mut tl, &mut tr);
                self.skipped -= drop;
                continue;
            }
            self.feed.pop(&mut l[got..got + n], &mut r[got..got + n]);
            got += n;
        }
        self.produced += got;
        if got == 0 {
            return None;
        }
        if self.channels == 1 {
            l.truncate(got);
            return Some(AudioChunk::new(l, 1));
        }
        let mut out = vec![0.0f32; got * 2];
        for i in 0..got {
            out[2 * i] = l[i];
            out[2 * i + 1] = r[i];
        }
        Some(AudioChunk::new(out, 2))
    }
}

impl<F: MixFeed> AudioSource for TimelineAudioSource<F> {
    fn sample_rate(&self) -> i64 {
        MIX_SAMPLE_RATE
    }

    fn channels(&self) -> usize {
        self.channels
    }

    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        Ok(self.produce(max_frames))
    }

    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl<F: MixFeed> RewindableAudioSource for TimelineAudioSource<F> {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.produced = 0;
        self.needs_seek = true;
        Ok(())
    }
}
