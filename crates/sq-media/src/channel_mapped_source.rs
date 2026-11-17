// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioChannelRouting.swift (`ChannelMappedSource`), MonoAudioDecoder.swift (`mono`)
//! A channel map over a source that already delivers two sides (the WebM stereo decode, a test source), and the mono
//! downmix used by analysis such as the beat tracker.

use crate::media_error::MediaError;
use crate::memory_audio_source::AudioSource;
use sq_core_audio::audio_channel_map::AudioChannelMapExt;
use sq_core_model::AudioChannelMap;
use std::sync::Mutex;

/// The map picks from the two sides of `base`. A side that takes one channel reads it straight from the base (no copy, no
/// extra work); a sum uses one scratch buffer that is kept between reads.
pub struct ChannelMappedSource {
    base: Box<dyn AudioSource>,
    left: Vec<usize>,
    right: Vec<usize>,
    gain: f32,
    is_mono: bool,
    scratch: Mutex<Vec<f32>>,
}

impl ChannelMappedSource {
    /// `base` itself when there is nothing to map (no map, no channel of it among the two, or the plain stereo order).
    pub fn wrap(base: Box<dyn AudioSource>, map: Option<&AudioChannelMap>) -> Box<dyn AudioSource> {
        // The reader delivers two sides: a map naming a channel beyond them is not a map for this file (it plays the file
        // layout, not a partial sum that silently drops the other channels).
        let Some(m) = map.and_then(|m| m.fitting(2).filter(|f| f == m)) else { return base };
        if Some(&m) == AudioChannelMap::stereo(0, 1).as_ref() && !base.is_mono() {
            return base;
        }
        let side = |c: &[i64]| c.iter().map(|c| *c as usize).collect();
        Box::new(ChannelMappedSource {
            left: side(m.left()),
            right: side(m.right()),
            gain: m.gain(),
            is_mono: m.is_centered(),
            base,
            scratch: Mutex::new(Vec::new()),
        })
    }
}

impl AudioSource for ChannelMappedSource {
    fn read(&self, source_frame: i64, buffer: &mut [f32], channel: usize) -> Result<usize, MediaError> {
        if channel > 1 {
            return Ok(0);
        }
        let list = if channel == 0 { &self.left } else { &self.right };
        if list.len() == 1 {
            return self.base.read(source_frame, buffer, list[0]);
        }
        let n = self.base.read(source_frame, buffer, 0)?;
        if n == 0 {
            return Ok(n);
        }
        if list.is_empty() {
            buffer[..n].fill(0.0);
            return Ok(n);
        }
        let mut s = self.scratch.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if s.len() < n {
            s.resize(n, 0.0);
        }
        let m = self.base.read(source_frame, &mut s[..n], 1)?;
        for i in 0..n {
            buffer[i] = (buffer[i] + if i < m { s[i] } else { 0.0 }) * self.gain;
        }
        Ok(n)
    }

    fn is_mono(&self) -> bool {
        self.is_mono
    }
}

/// Analysis rate: beat tracking needs no more, and it keeps a 10 minute song near 50 MB.
pub const ANALYSIS_SAMPLE_RATE: i64 = 22_050;

/// Reads `source` from frame 0 to its end (or `max_frames`) and mixes it down to mono (left and right averaged).
pub fn mono(source: &dyn AudioSource, max_frames: usize, block: usize) -> Result<Vec<f32>, MediaError> {
    let mut out = Vec::new();
    let (mut left, mut right) = (vec![0f32; block], vec![0f32; block]);
    let mut at = 0usize;
    while at < max_frames {
        let n = block.min(max_frames - at);
        let l = source.read(at as i64, &mut left[..n], 0)?;
        if l == 0 {
            break;
        }
        if source.is_mono() {
            out.extend_from_slice(&left[..l]);
        } else {
            let r = source.read(at as i64, &mut right[..l], 1)?;
            out.extend((0..l).map(|i| if i < r { (left[i] + right[i]) * 0.5 } else { left[i] }));
        }
        at += l;
        if l < n {
            break;
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory_audio_source::MemoryAudioSource;

    fn src() -> Box<dyn AudioSource> {
        Box::new(MemoryAudioSource::new(vec![1.0, 2.0, 3.0], vec![10.0, 20.0, 30.0]))
    }

    fn read(s: &dyn AudioSource, ch: usize) -> Vec<f32> {
        let mut b = vec![0f32; 3];
        let n = s.read(0, &mut b, ch).unwrap();
        b.truncate(n);
        b
    }

    #[test]
    fn nothing_to_map_returns_the_base() {
        assert!(!ChannelMappedSource::wrap(src(), None).is_mono());
        let plain = AudioChannelMap::stereo(0, 1).unwrap();
        let s = ChannelMappedSource::wrap(src(), Some(&plain));
        assert_eq!((read(&*s, 0), read(&*s, 1)), (vec![1.0, 2.0, 3.0], vec![10.0, 20.0, 30.0]));
        // A map naming a channel beyond the two sides is not a map for this file.
        let beyond = AudioChannelMap::stereo(0, 2).unwrap();
        let s = ChannelMappedSource::wrap(src(), Some(&beyond));
        assert_eq!(read(&*s, 1), vec![10.0, 20.0, 30.0]);
    }

    #[test]
    fn swapped_sides_single_channels_and_sums() {
        let swap = AudioChannelMap::stereo(1, 0).unwrap();
        let s = ChannelMappedSource::wrap(src(), Some(&swap));
        assert_eq!((read(&*s, 0), read(&*s, 1)), (vec![10.0, 20.0, 30.0], vec![1.0, 2.0, 3.0]));
        assert!(!s.is_mono());
        let mono_right = AudioChannelMap::mono(1).unwrap();
        let s = ChannelMappedSource::wrap(src(), Some(&mono_right));
        assert!(s.is_mono());
        assert_eq!(read(&*s, 0), read(&*s, 1));
        let dual = AudioChannelMap::dual_mono(0, 1).unwrap();
        let s = ChannelMappedSource::wrap(src(), Some(&dual));
        let g = 0.5f32.sqrt();
        assert_eq!(read(&*s, 0), vec![11.0 * g, 22.0 * g, 33.0 * g]);
        assert_eq!(read(&*s, 5), Vec::<f32>::new());
    }

    #[test]
    fn mono_downmix_averages_and_stops_at_the_end() {
        let s = MemoryAudioSource::new(vec![1.0, 2.0, 3.0, 4.0, 5.0], vec![3.0, 2.0, 1.0, 0.0, 5.0]);
        assert_eq!(mono(&s, usize::MAX, 2).unwrap(), vec![2.0, 2.0, 2.0, 2.0, 5.0]);
        assert_eq!(mono(&s, 3, 2).unwrap(), vec![2.0, 2.0, 2.0]);
        let m = MemoryAudioSource::mono(vec![7.0, 8.0]);
        assert_eq!(mono(&m, usize::MAX, 65_536).unwrap(), vec![7.0, 8.0]);
    }
}
