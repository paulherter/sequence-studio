use super::error::media_error;
use crate::shim;
use sq_core_audio::audio_channel_map::AudioChannelMapExt;
use sq_core_model::AudioChannelMap;
use sq_media::channel_mapped_source::ChannelMappedSource;
use sq_media::media_error::MediaError;
use sq_media::memory_audio_source::AudioSource;
use sq_media::multi_track_audio::{self, SummedTracksSource};
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicI64, Ordering};

/// `AudioSource` over FFmpeg: the file's best audio stream, streamed and resampled to `sample_rate` (48 kHz, the mixer
/// rate) stereo float. A mono file is delivered as identical left and right (`is_mono`). Only a window of about a second
/// is held; a read elsewhere seeks (Swift `AssetAudioSource` keeps a chunk cache the same way).
pub struct FFmpegAudioSource {
    sample_rate: i64,
    frame_count: AtomicI64,
    is_mono: bool,
    inner: Mutex<Inner>,
}

/// Frames decoded per refill (and the least a read asks the decoder for).
const WINDOW: usize = 1 << 16;

struct Inner {
    reader: shim::AudioReader,
    mono: bool,
    /// Frame index of the first window frame.
    start: i64,
    left: Vec<f32>,
    right: Vec<f32>,
}

/// The audio stream of a file as its container states it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioStreamInfo {
    /// Samples per second of the file itself.
    pub sample_rate: i64,
    /// Channels of the file itself.
    pub channels: i64,
    /// Codec name.
    pub codec: String,
    /// Container duration in microseconds; `None` = unknown.
    pub duration_us: Option<i64>,
}

/// The whole-file decode, for the test that compares it with the streamed read.
#[cfg(test)]
pub(super) fn decode_for_test(path: &Path, rate: i32, channels: i32) -> Result<Vec<f32>, MediaError> {
    Ok(shim::decode_audio(path, rate, channels).map_err(|e| media_error(&e, ""))?.samples)
}

impl FFmpegAudioSource {
    /// Decodes `path` at `sample_rate` Hz.
    pub fn open(path: &Path, sample_rate: i32) -> Result<FFmpegAudioSource, MediaError> {
        let mono = shim::probe_audio(path).ok().and_then(|p| p.audio).is_some_and(|(_, channels, _)| channels == 1);
        Self::load(path, sample_rate, None, mono)
    }

    // A mono stream is decoded as one channel and copied to both sides at unity, which is what Swift plays: AVAssetReader
    // converts mono to two channels by duplication (`AssetAudioSource`, MediaRobustness "playback duplicates mono onto
    // both sides"), and the mono routes of a channel map copy the channel to both sides the same way. The resampler's own
    // mono-to-stereo mix would take 3 dB off.
    fn load(path: &Path, rate: i32, ordinal: Option<usize>, mono: bool) -> Result<FFmpegAudioSource, MediaError> {
        let mut reader =
            shim::AudioReader::open(path, rate, if mono { 1 } else { 2 }, ordinal).map_err(|e| media_error(&e, ""))?;
        let is_mono = reader.source_channels == 1;
        let inner_probe = |reader: &mut shim::AudioReader| -> Result<i64, MediaError> {
            // The container did not state a length: count by reading through once (nothing is kept).
            let mut buf = vec![0f32; WINDOW * if mono { 1 } else { 2 }];
            let mut at = 0i64;
            loop {
                let n = reader.read(at, &mut buf).map_err(|e| media_error(&e, ""))?;
                if n == 0 {
                    return Ok(at);
                }
                at += n as i64;
            }
        };
        let frames = match reader.estimated_frames {
            n if n >= 0 => n,
            _ => inner_probe(&mut reader)?,
        };
        Ok(FFmpegAudioSource {
            sample_rate: i64::from(rate),
            frame_count: AtomicI64::new(frames),
            is_mono,
            inner: Mutex::new(Inner { reader, mono, start: 0, left: Vec::new(), right: Vec::new() }),
        })
    }

    /// The audio track `ordinal` of `path` (0-based) on its own, delivered as two sides like `open`.
    pub fn open_track(path: &Path, sample_rate: i32, ordinal: usize) -> Result<FFmpegAudioSource, MediaError> {
        let mono = Self::track_channels(path)?.get(ordinal) == Some(&1);
        Self::load(path, sample_rate, Some(ordinal), mono)
    }

    /// The channels of each audio track of `path`, in file order.
    pub fn track_channels(path: &Path) -> Result<Vec<i64>, MediaError> {
        shim::audio_track_channels(path).map_err(|e| media_error(&e, ""))
    }

    /// The file's audio as `map` (the media item's Audio Channels) plays it: the channels of all tracks count in track
    /// order, only the tracks the map uses are decoded, and their parts are summed (Swift `MultiTrackAudio`). Without a
    /// map, or for a one-track file, this is `open`.
    pub fn open_mapped(
        path: &Path,
        sample_rate: i32,
        map: Option<&AudioChannelMap>,
    ) -> Result<Box<dyn AudioSource>, MediaError> {
        let counts = Self::track_channels(path)?;
        let Some(map) = map.filter(|_| counts.len() > 1) else {
            return Ok(ChannelMappedSource::wrap(Box::new(Self::open(path, sample_rate)?), map));
        };
        let mut parts: Vec<Box<dyn AudioSource>> = Vec::new();
        for (track, part) in multi_track_audio::plan(map, &counts) {
            let base = Box::new(Self::open_track(path, sample_rate, track)?);
            parts.push(ChannelMappedSource::wrap(base, Some(&part)));
        }
        if parts.is_empty() {
            return Ok(Box::new(Self::open(path, sample_rate)?));
        }
        Ok(Box::new(SummedTracksSource::new(parts, map.is_centered())))
    }

    pub fn sample_rate(&self) -> i64 {
        self.sample_rate
    }

    pub fn frame_count(&self) -> i64 {
        self.frame_count.load(Ordering::Relaxed)
    }

    /// Reads the stream headers of `path`: `Ok(None)` for a file without sound. Nothing is decoded.
    pub fn stream_info(path: &Path) -> Result<Option<AudioStreamInfo>, MediaError> {
        let p = shim::probe_audio(path).map_err(|e| media_error(&e, ""))?;
        Ok(p.audio.map(|(rate, channels, codec)| AudioStreamInfo {
            sample_rate: i64::from(rate),
            channels: i64::from(channels),
            codec,
            duration_us: p.duration_us,
        }))
    }

    /// Whether the best audio stream of `path` has a decoder here: opens the decoder and reads nothing. The import uses it to
    /// find a file whose sound would not play (`MediaError::UnsupportedCodec`, with no codec name: `stream_info` has it).
    pub fn decoder_check(path: &Path) -> Result<(), MediaError> {
        shim::AudioReader::open(path, 48_000, 2, None).map(drop).map_err(|e| media_error(&e, ""))
    }

    /// The best audio stream of `path` as mono floats at `sample_rate` (speech recognition wants 16 kHz).
    /// Fails when the file has no audio stream.
    ///
    /// Read through the seeking reader in `WINDOW`-frame steps (the stream the player uses), so no whole-file decode
    /// buffer sits next to the result; the result is sized from the container's estimate.
    pub fn mono_samples(path: &Path, sample_rate: i32) -> Result<Vec<f32>, MediaError> {
        let mut reader = shim::AudioReader::open(path, sample_rate, 1, None).map_err(|e| media_error(&e, ""))?;
        let mut out: Vec<f32> = Vec::with_capacity(usize::try_from(reader.estimated_frames).unwrap_or(0));
        let mut chunk = vec![0f32; WINDOW];
        loop {
            let n = reader.read(out.len() as i64, &mut chunk).map_err(|e| media_error(&e, ""))?;
            if n == 0 {
                return Ok(out);
            }
            out.extend_from_slice(&chunk[..n]);
        }
    }
}

impl Inner {
    /// Refills the window from `from` with at least `want` frames.
    fn fill(&mut self, from: i64, want: usize) -> Result<usize, MediaError> {
        let want = want.max(WINDOW);
        let ch = if self.mono { 1 } else { 2 };
        let mut buf = vec![0f32; want * ch];
        let n = self.reader.read(from, &mut buf).map_err(|e| media_error(&e, ""))?;
        self.start = from;
        self.left.clear();
        self.right.clear();
        if self.mono {
            self.left.extend_from_slice(&buf[..n]);
            self.right.extend_from_slice(&buf[..n]);
        } else {
            for f in buf[..n * 2].as_chunks::<2>().0 {
                self.left.push(f[0]);
                self.right.push(f[1]);
            }
        }
        Ok(n)
    }
}

impl AudioSource for FFmpegAudioSource {
    fn read(&self, source_frame: i64, buffer: &mut [f32], channel: usize) -> Result<usize, MediaError> {
        if source_frame < 0 || source_frame >= self.frame_count() || buffer.is_empty() {
            return Ok(0);
        }
        let mut s = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let held = |s: &Inner| source_frame >= s.start && source_frame < s.start + s.left.len() as i64;
        if !held(&s) {
            let got = s.fill(source_frame, buffer.len())?;
            if got < WINDOW.min(buffer.len()) {
                // Short fill: the stream ended before its stated length; the true length is known now.
                if let Some(end) = s.reader.end() {
                    self.frame_count.store(end, Ordering::Relaxed);
                }
            }
            if !held(&s) {
                return Ok(0);
            }
        }
        let src = if channel == 0 { &s.left } else { &s.right };
        let from = usize::try_from(source_frame - s.start).unwrap_or(0);
        let n = buffer.len().min(src.len() - from);
        buffer[..n].copy_from_slice(&src[from..from + n]);
        Ok(n)
    }

    fn is_mono(&self) -> bool {
        self.is_mono
    }
}
