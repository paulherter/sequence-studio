// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MultiTrackAudio.swift (the pure parts: `part`, `plan`, `totalChannels`, `SummedTracksSource`; listing and opening
// the tracks of a file is decoder code)
//! Files from cameras and recorders often carry several audio tracks (a mono lavalier next to the stereo mix). The channels
//! of a file are counted across all its audio tracks, in track order and then channel order, so "Audio Channels" can name
//! any of them. Tracks no map channel falls in are never opened, so they cost no decoding.

use crate::media_error::MediaError;
use crate::memory_audio_source::AudioSource;
use sq_core_model::AudioChannelMap;
use std::sync::Mutex;

/// Channels a file counts: all usable tracks together (`usable` = channels of each), or the first track's own count when
/// none is usable (`first_track_channels`); `None` without any track.
pub fn total_channels(usable: &[i64], first_track_channels: Option<i64>) -> Option<i64> {
    if usable.is_empty() { first_track_channels } else { Some(usable.iter().sum()) }
}

/// The part of `map` that falls on the track holding file channels `offset..offset + count`, numbered from the track's first
/// channel; `None` when the map uses none of them.
pub fn part_of(map: &AudioChannelMap, offset: i64, count: i64) -> Option<AudioChannelMap> {
    let local = |side: &[i64]| -> Vec<i64> {
        side.iter().filter(|c| **c >= offset && **c < offset + count).map(|c| c - offset).collect()
    };
    AudioChannelMap::new(&local(map.left()), &local(map.right()))
}

/// The tracks `map` uses with the part of the map each one plays (`counts` in track order): `(track index, part)`.
pub fn plan(map: &AudioChannelMap, counts: &[i64]) -> Vec<(usize, AudioChannelMap)> {
    let mut offset = 0;
    let mut out = Vec::new();
    for (i, c) in counts.iter().enumerate() {
        if let Some(p) = part_of(map, offset, *c) {
            out.push((i, p));
        }
        offset += c;
    }
    out
}

/// The sides of several track sources added up (each already carries the map's level).
pub struct SummedTracksSource {
    parts: Vec<Box<dyn AudioSource>>,
    is_mono: bool,
    scratch: Mutex<Vec<f32>>,
}

impl SummedTracksSource {
    /// `parts` must not be empty.
    pub fn new(parts: Vec<Box<dyn AudioSource>>, is_mono: bool) -> SummedTracksSource {
        SummedTracksSource { parts, is_mono, scratch: Mutex::new(Vec::new()) }
    }
}

impl AudioSource for SummedTracksSource {
    fn read(&self, source_frame: i64, buffer: &mut [f32], channel: usize) -> Result<usize, MediaError> {
        let count = buffer.len();
        let mut total = self.parts[0].read(source_frame, buffer, channel)?;
        let mut s = self.scratch.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if s.len() < count {
            s.resize(count, 0.0);
        }
        for p in &self.parts[1..] {
            let m = p.read(source_frame, &mut s[..count], channel)?;
            if m > total {
                buffer[total..m].fill(0.0);
                total = m;
            }
            for i in 0..m {
                buffer[i] += s[i];
            }
        }
        Ok(total)
    }

    fn is_mono(&self) -> bool {
        self.is_mono
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory_audio_source::MemoryAudioSource;

    #[test]
    fn channels_count_across_tracks_in_order() {
        assert_eq!(total_channels(&[1, 2], Some(1)), Some(3));
        assert_eq!(total_channels(&[], Some(2)), Some(2));
        assert_eq!(total_channels(&[], None), None);
    }

    #[test]
    fn a_map_is_cut_into_the_parts_of_the_tracks_it_uses() {
        // Track 0: mono (file channel 0). Track 1: stereo (file channels 1, 2).
        let map = AudioChannelMap::stereo(0, 2).unwrap();
        let p = plan(&map, &[1, 2]);
        assert_eq!(p.len(), 2);
        assert_eq!((p[0].0, p[0].1.left(), p[0].1.right()), (0, &[0][..], &[][..]));
        assert_eq!((p[1].0, p[1].1.left(), p[1].1.right()), (1, &[][..], &[1][..]));
        // A map that uses only the second track never opens the first.
        let only = AudioChannelMap::stereo(1, 2).unwrap();
        let p = plan(&only, &[1, 2]);
        assert_eq!(p.iter().map(|(i, _)| *i).collect::<Vec<_>>(), vec![1]);
        assert_eq!((p[0].1.left(), p[0].1.right()), (&[0][..], &[1][..]));
        assert!(part_of(&only, 0, 1).is_none());
    }

    #[test]
    fn summed_tracks_add_up_and_the_longer_one_wins() {
        let a: Box<dyn AudioSource> = Box::new(MemoryAudioSource::new(vec![1.0, 1.0], vec![0.0, 0.0]));
        let b: Box<dyn AudioSource> = Box::new(MemoryAudioSource::new(vec![2.0, 2.0, 2.0], vec![0.0; 3]));
        let s = SummedTracksSource::new(vec![a, b], false);
        let mut buf = vec![9.0f32; 4];
        assert_eq!(s.read(0, &mut buf, 0).unwrap(), 3);
        assert_eq!(&buf[..3], &[3.0, 3.0, 2.0]);
    }
}
