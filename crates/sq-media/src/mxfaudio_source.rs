// Swift: MXF/MXFAudioSource.swift
//! PCM audio of an MXF file. Cameras write one mono track per channel (Sony XAVC: 4 or 8 tracks, 24 bit, 48 kHz);
//! every channel of every sound track is one source channel here, in track order. The engine's sources are stereo:
//! `left` and `right` say which source channels feed each side. Default: mono channels play centered, the first two
//! on both sides at -3 dB each (equal power, like two centered mono tracks; dual mono does not come out 6 dB hot).
//! A single microphone on channel 1 is then heard on both sides; a file with one channel plays at unity, like the
//! first audio track of a camera MOV (`AssetAudioSource`).

use crate::media_error::MediaError;
use crate::memory_audio_source::AudioSource;
use crate::mxffile::MxfFile;
use sq_core_model::AudioChannelMap;
use std::collections::{BTreeSet, HashMap};
use std::ops::Range;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};

/// One source channel: sound track, channel inside that track's element.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Channel {
    pub track: u32,
    pub index_in_track: usize,
    pub bits: i64,
}

/// Why `MxfAudioSource::stream_all` stopped early.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamAllError<E> {
    /// `is_cancelled` returned true.
    Cancelled,
    /// The body returned an error.
    Body(E),
}

#[derive(Clone, Copy, Debug)]
struct Layout {
    track: u32,
    stride: usize,
    bytes: usize,
    big_endian: bool,
}

type Block = Arc<(Vec<f32>, Vec<f32>)>;

#[derive(Default)]
struct Cache {
    blocks: HashMap<i64, Block>,
    order: Vec<i64>,
}

/// PCM audio of an MXF file.
pub struct MxfAudioSource {
    pub sample_rate: i64,
    /// Sample rate of the file.
    pub native_rate: i64,
    pub channels: Vec<Channel>,
    pub left: Vec<usize>,
    pub right: Vec<usize>,
    is_mono: bool,
    /// Frames at `sample_rate`.
    pub total_frames: i64,
    /// Frames at `native_rate`.
    pub native_total: i64,
    file: MxfFile,
    layouts: Vec<Layout>,
    /// Channel -> (layout, channel in layout).
    map: Vec<(usize, usize)>,
    /// Samples per edit unit: one entry (constant), a repeating cadence (29.97 fps: 1602 1601 1602 1601 1602), or one per unit.
    cadence: Vec<i64>,
    cadence_sum: i64,
    eager_starts: Option<Vec<i64>>,
    /// Irregular cadence in a long file: the per-unit table is not built while probing. It grows with the reads,
    /// each one walking only the units up to the one it needs (never the whole file at once).
    is_lazy: bool,
    lazy_starts: Mutex<Vec<i64>>,
    first_track: u32,
    first_stride: usize,
    /// Clip-wrapped sound (one element for the whole file): its bytes.
    clip: Option<Range<usize>>,
    cache: Mutex<Cache>,
}

const MAX_BLOCKS: usize = 6;

impl MxfAudioSource {
    /// Units up to which an irregular cadence is resolved while opening.
    pub(crate) const EAGER_UNIT_LIMIT: usize = 4096;

    /// Units the lazy table has walked so far (tests).
    #[cfg(test)]
    pub(crate) fn walked_units(&self) -> usize {
        self.lazy_starts.lock().unwrap_or_else(PoisonError::into_inner).len() - 1
    }

    fn samples_in_unit(&self, u: usize) -> i64 {
        let n = self
            .file
            .elements(u)
            .iter()
            .find(|e| e.track == self.first_track)
            .map(|e| e.range.len() / self.first_stride);
        n.unwrap_or(0) as i64
    }

    fn lazy_start(&self, u: usize) -> i64 {
        let u = u.min(self.file.unit_count());
        let mut s = self.lazy_starts.lock().unwrap_or_else(PoisonError::into_inner);
        while s.len() <= u {
            let next = s[s.len() - 1] + self.samples_in_unit(s.len() - 1);
            s.push(next);
        }
        s[u]
    }

    fn lazy_unit(&self, sample: i64) -> usize {
        let units = self.file.unit_count();
        let mut s = self.lazy_starts.lock().unwrap_or_else(PoisonError::into_inner);
        while s[s.len() - 1] <= sample && s.len() <= units {
            let next = s[s.len() - 1] + self.samples_in_unit(s.len() - 1);
            s.push(next);
        }
        let (mut lo, mut hi) = (0, s.len() - 1);
        while lo + 1 < hi {
            let mid = (lo + hi) / 2;
            if s[mid] <= sample {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// First sample of every edit unit (and the total as last entry), from the sound element sizes.
    fn starts(file: &MxfFile, track: u32, stride: usize) -> Vec<i64> {
        let units = file.unit_count();
        let mut starts: Vec<i64> = vec![0];
        starts.reserve(units);
        for u in 0..units {
            let n = file.elements(u).iter().find(|e| e.track == track).map(|e| e.range.len() / stride).unwrap_or(0);
            starts.push(starts[u] + n as i64);
        }
        starts
    }

    fn block_frames(&self) -> i64 {
        self.sample_rate
    }

    /// Opens the file (cached parse) and its sound. `left`/`right`: the source channels feeding each side.
    /// Synchronous: the Swift `async` did not await anything.
    pub fn open(
        path: &Path,
        sample_rate: i64,
        left: Option<&[i64]>,
        right: Option<&[i64]>,
    ) -> Result<MxfAudioSource, MediaError> {
        MxfAudioSource::new(MxfFile::open(path)?, sample_rate, left, right)
    }

    pub fn new(
        file: MxfFile,
        sample_rate: i64,
        left: Option<&[i64]>,
        right: Option<&[i64]>,
    ) -> Result<MxfAudioSource, MediaError> {
        Self::with_eager_units(file, sample_rate, left, right, Self::EAGER_UNIT_LIMIT)
    }

    pub(crate) fn with_eager_units(
        file: MxfFile,
        sample_rate: i64,
        left: Option<&[i64]>,
        right: Option<&[i64]>,
        eager_units: usize,
    ) -> Result<MxfAudioSource, MediaError> {
        let sample_rate = sample_rate.max(1);
        let mut tracks = file.sound_tracks();
        tracks.sort_by_key(|t| (t.number, t.id));
        if tracks.is_empty() {
            return Err(MediaError::Unreadable);
        }
        let mut layouts: Vec<Layout> = Vec::new();
        let mut channels: Vec<Channel> = Vec::new();
        let mut map: Vec<(usize, usize)> = Vec::new();
        let mut rate: i64 = 0;
        for t in &tracks {
            let Some(d) = &t.sound else { continue };
            if !d.is_pcm() {
                return Err(MediaError::UnsupportedCodec(format!("{} audio in MXF", d.codec_name())));
            }
            // Element type 0x10 is SMPTE 331M (D-10) AES3 with channel status framing, not plain PCM.
            if (t.number >> 8) as u8 == 0x10 {
                return Err(MediaError::UnsupportedCodec("D-10 AES3 audio in MXF".to_string()));
            }
            if rate == 0 {
                rate = d.sample_rate;
            }
            if d.sample_rate != rate {
                continue;
            }
            let bytes = d.bytes_per_sample() as usize;
            let ch = d.channels as usize;
            let stride = if d.block_align as usize >= bytes * ch { d.block_align as usize } else { bytes * ch };
            layouts.push(Layout { track: t.number, stride, bytes, big_endian: d.is_big_endian() });
            for c in 0..ch {
                channels.push(Channel { track: t.number, index_in_track: c, bits: d.bits });
                map.push((layouts.len() - 1, c));
            }
        }
        if layouts.is_empty() || rate <= 0 {
            return Err(MediaError::Unreadable);
        }
        let native_rate = rate;
        let n = channels.len();
        let centered: Vec<usize> = if n > 1 { vec![0, 1] } else { vec![0] };
        // A choice the file cannot play (a relink to a file with fewer channels) falls back to the file's layout:
        // never a dead side, never silence.
        let chosen = if left.is_none() && right.is_none() {
            None
        } else {
            AudioChannelMap::new(left.unwrap_or(&[]), right.unwrap_or(&[])).and_then(|m| m.fitting(n as i64))
        };
        let side = |v: Option<&[i64]>| v.map(|c| c.iter().map(|&x| x as usize).collect::<Vec<usize>>());
        let l = chosen.as_ref().and_then(|m| side(Some(m.left()))).unwrap_or_else(|| centered.clone());
        let r = chosen.as_ref().and_then(|m| side(Some(m.right()))).unwrap_or(centered);
        let is_mono = l == r;

        // How many samples each edit unit holds, from the first sound element of each unit.
        let first = layouts[0];
        let samples_in = |u: usize| -> i64 {
            file.elements(u)
                .iter()
                .find(|e| e.track == first.track)
                .map(|e| (e.range.len() / first.stride) as i64)
                .unwrap_or(0)
        };
        let units = file.unit_count();
        let mut clip: Option<Range<usize>> = None;
        if units == 1
            && file.video_track().is_none()
            && let Some(e) = file.elements(0).into_iter().find(|e| e.track == first.track)
        {
            clip = Some(e.range); // audio-only, clip-wrapped: one element holds everything
        }
        let head: Vec<i64> = (0..units.min(10)).map(samples_in).collect();
        let (cadence, eager_starts, is_lazy): (Vec<i64>, Option<Vec<i64>>, bool);
        if let Some(c) = &clip {
            cadence = vec![(c.len() / first.stride) as i64];
            eager_starts = None;
            is_lazy = false;
        } else if units >= 10 && head[0..5] == head[5..10] {
            let distinct: BTreeSet<i64> = head.iter().copied().collect();
            cadence = if distinct.len() == 1 { vec![head[0]] } else { head[0..5].to_vec() };
            eager_starts = None;
            is_lazy = false;
        } else if units <= eager_units {
            cadence = vec![];
            eager_starts = Some(Self::starts(&file, first.track, first.stride));
            is_lazy = false;
        } else {
            // Walking every unit of an hour-long clip does not belong in a probe: the length comes from the edit
            // rate now, the exact table when sound is first read.
            cadence = vec![];
            eager_starts = None;
            is_lazy = true;
        }
        let cadence_sum: i64 = cadence.iter().sum();
        let native_total: i64;
        if let Some(es) = &eager_starts {
            native_total = es.last().copied().unwrap_or(0);
        } else if is_lazy {
            // A corrupt edit rate or sample rate must not overflow.
            let t = file.video_track().unwrap_or(tracks[0]);
            let b = (units as i64).checked_mul(rate).and_then(|a| a.checked_mul(t.edit_rate_den));
            match b {
                Some(b) if t.edit_rate_num > 0 && t.edit_rate_den > 0 => native_total = b / t.edit_rate_num,
                _ => return Err(MediaError::Unreadable),
            }
        } else if clip.is_some() {
            native_total = cadence_sum;
        } else {
            let full = (units / cadence.len()) as i64;
            let rest = units % cadence.len();
            native_total = full * cadence_sum + cadence[..rest].iter().sum::<i64>();
        }
        if native_total <= 0 {
            return Err(MediaError::Unreadable);
        }
        let Some(scaled) = native_total.checked_mul(sample_rate) else { return Err(MediaError::Unreadable) };
        let total_frames = scaled / rate;
        Ok(MxfAudioSource {
            sample_rate,
            native_rate,
            channels,
            left: l,
            right: r,
            is_mono,
            total_frames,
            native_total,
            first_track: first.track,
            first_stride: first.stride,
            file,
            layouts,
            map,
            cadence,
            cadence_sum,
            eager_starts,
            is_lazy,
            lazy_starts: Mutex::new(vec![0]),
            clip,
            cache: Mutex::new(Cache::default()),
        })
    }

    pub fn channel_count(&self) -> usize {
        self.channels.len()
    }

    // MARK: sample positions

    fn start_of_unit(&self, u: usize) -> i64 {
        if self.is_lazy {
            return self.lazy_start(u);
        }
        if let Some(unit_starts) = &self.eager_starts {
            return unit_starts[u.min(unit_starts.len() - 1)];
        }
        let full = (u / self.cadence.len()) as i64;
        let rest = u % self.cadence.len();
        full * self.cadence_sum + self.cadence[..rest].iter().sum::<i64>()
    }

    fn unit_containing(&self, s: i64) -> usize {
        if self.is_lazy {
            return self.lazy_unit(s);
        }
        if let Some(unit_starts) = &self.eager_starts {
            let (mut lo, mut hi) = (0, unit_starts.len() - 1);
            while lo + 1 < hi {
                let mid = (lo + hi) / 2;
                if unit_starts[mid] <= s {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }
        if self.cadence_sum <= 0 {
            return 0;
        }
        let mut u = (s / self.cadence_sum) as usize * self.cadence.len();
        let mut at = (s / self.cadence_sum) * self.cadence_sum;
        for &c in &self.cadence {
            if at + c > s {
                break;
            }
            at += c;
            u += 1;
        }
        u
    }

    /// Native-rate samples `range` of the given source channels; silence where the file has nothing.
    pub(crate) fn decode(&self, wanted: &[usize], range: Range<i64>) -> Vec<Vec<f32>> {
        let count = (range.end - range.start).max(0) as usize;
        let mut out: Vec<Vec<f32>> = vec![vec![0.0; count]; wanted.len()];
        let lo = range.start.max(0);
        let hi = self.native_total.min(range.end);
        if lo >= hi {
            return out;
        }
        let mut copy = |element: Range<usize>, li: usize, element_start: i64| {
            let l = self.layouts[li];
            let have = (element.len() / l.stride) as i64;
            let a = lo.max(element_start);
            let b = hi.min(element_start + have);
            if a >= b {
                return;
            }
            let bytes = (element.start + (a - element_start) as usize * l.stride)
                ..(element.start + (b - element_start) as usize * l.stride);
            self.file.bytes.with_bytes(bytes, |p| {
                for (slot, &c) in wanted.iter().enumerate() {
                    if self.map[c].0 == li {
                        let offset = self.map[c].1 * l.bytes;
                        let at = (a - range.start) as usize;
                        Self::convert(
                            p,
                            l.stride,
                            offset,
                            l.bytes,
                            l.big_endian,
                            &mut out[slot][at..at + (b - a) as usize],
                        );
                    }
                }
            });
        };
        if let Some(clip) = &self.clip {
            copy(clip.clone(), 0, 0);
            return out;
        }
        let mut u = self.unit_containing(lo);
        while u < self.file.unit_count() {
            let s = self.start_of_unit(u);
            if s >= hi {
                break;
            }
            let elements = self.file.elements(u);
            for (li, l) in self.layouts.iter().enumerate() {
                if wanted.iter().any(|&c| self.map[c].0 == li)
                    && let Some(e) = elements.iter().find(|e| e.track == l.track)
                {
                    copy(e.range.clone(), li, s);
                }
            }
            u += 1;
        }
        out
    }

    /// Signed integer PCM (1 to 4 bytes) to f32 in -1...1; fills `dst` as far as `p` reaches.
    pub(crate) fn convert(p: &[u8], stride: usize, offset: usize, bytes: usize, big_endian: bool, dst: &mut [f32]) {
        let scale = 1.0 / (1i64 << (8 * bytes - 1)) as f32;
        let shift = 32 - 8 * bytes as u32;
        for (i, d) in dst.iter_mut().enumerate() {
            let o = i * stride + offset;
            if o + bytes > p.len() {
                break;
            }
            let mut v: u32 = 0;
            if big_endian {
                for k in 0..bytes {
                    v = v << 8 | u32::from(p[o + k]);
                }
            } else {
                for k in (0..bytes).rev() {
                    v = v << 8 | u32::from(p[o + k]);
                }
            }
            *d = ((v << shift) as i32 >> shift) as f32 * scale;
        }
    }

    // MARK: output

    /// Output-rate frames `range` of source channels `wanted` (linear interpolation when the rates differ).
    fn render(&self, wanted: &[usize], range: Range<i64>) -> Vec<Vec<f32>> {
        if self.native_rate == self.sample_rate {
            return self.decode(wanted, range);
        }
        let n = (range.end - range.start) as usize;
        let (num, den) = (self.native_rate, self.sample_rate);
        let first = range.start * num / den;
        let last = (range.end - 1) * num / den + 2;
        let src = self.decode(wanted, first..last);
        src.iter()
            .map(|s| {
                let mut o = vec![0.0f32; n];
                for (i, v) in o.iter_mut().enumerate() {
                    let pos = (range.start + i as i64) * num;
                    let k = (pos / den - first) as usize;
                    let f = (pos % den) as f32 / den as f32;
                    *v = s[k] + (s[k + 1] - s[k]) * f;
                }
                o
            })
            .collect()
    }

    fn mix(&self, list: &[usize], decoded: &[Vec<f32>], wanted: &[usize], count: usize) -> Vec<f32> {
        let mut o = vec![0.0f32; count];
        // Several mono channels summed to the center: -3 dB each (equal power). Channels routed to one side only
        // and a single channel stay at unity.
        let gain: f32 = if self.is_mono && list.len() > 1 { 0.5f32.sqrt() } else { 1.0 };
        for c in list {
            let Some(slot) = wanted.iter().position(|w| w == c) else { continue };
            if list.len() == 1 {
                return decoded[slot].clone();
            }
            for i in 0..count {
                o[i] += decoded[slot][i] * gain;
            }
        }
        o
    }

    fn wanted(&self) -> Vec<usize> {
        self.left.iter().chain(&self.right).copied().collect::<BTreeSet<usize>>().into_iter().collect()
    }

    fn block(&self, b: i64) -> Block {
        if let Some(hit) = self.cache.lock().unwrap_or_else(PoisonError::into_inner).blocks.get(&b) {
            return Arc::clone(hit);
        }
        let range = (b * self.block_frames())..self.total_frames.min((b + 1) * self.block_frames());
        let count = (range.end - range.start) as usize;
        let wanted = self.wanted();
        let decoded = self.render(&wanted, range);
        let l = self.mix(&self.left, &decoded, &wanted, count);
        let r = if self.is_mono { l.clone() } else { self.mix(&self.right, &decoded, &wanted, count) };
        let block = Arc::new((l, r));
        let mut c = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
        c.blocks.insert(b, Arc::clone(&block));
        c.order.push(b);
        while c.order.len() > MAX_BLOCKS {
            let old = c.order.remove(0);
            c.blocks.remove(&old);
        }
        block
    }

    /// One source channel on its own (for channel routing), at the output rate. Returns the frames written.
    pub fn read_source_channel(&self, c: usize, source_frame: i64, buffer: &mut [f32]) -> usize {
        if c >= self.channels.len() || source_frame < 0 || source_frame >= self.total_frames || buffer.is_empty() {
            return 0;
        }
        let n = (buffer.len() as i64).min(self.total_frames - source_frame) as usize;
        let d = self.render(&[c], source_frame..(source_frame + n as i64));
        buffer[..n].copy_from_slice(&d[0][..n]);
        n
    }

    /// The whole file in order, block by block (waveforms, analysis). `body` gets left, right.
    pub fn stream_all<E>(
        &self,
        is_cancelled: impl Fn() -> bool,
        mut body: impl FnMut(&[f32], &[f32]) -> Result<(), E>,
    ) -> Result<(), StreamAllError<E>> {
        let wanted = self.wanted();
        let mut at: i64 = 0;
        while at < self.total_frames {
            if is_cancelled() {
                return Err(StreamAllError::Cancelled);
            }
            let range = at..self.total_frames.min(at + self.block_frames());
            let count = (range.end - range.start) as usize;
            let decoded = self.render(&wanted, range.clone());
            let l = self.mix(&self.left, &decoded, &wanted, count);
            let r = if self.is_mono { l.clone() } else { self.mix(&self.right, &decoded, &wanted, count) };
            body(&l, &r).map_err(StreamAllError::Body)?;
            at = range.end;
        }
        Ok(())
    }
}

impl AudioSource for MxfAudioSource {
    fn read(&self, source_frame: i64, buffer: &mut [f32], channel: usize) -> Result<usize, MediaError> {
        if source_frame < 0 || source_frame >= self.total_frames || buffer.is_empty() {
            return Ok(0);
        }
        let n = (buffer.len() as i64).min(self.total_frames - source_frame) as usize;
        let mut done = 0usize;
        while done < n {
            let at = source_frame + done as i64;
            let b = at / self.block_frames();
            let block = self.block(b);
            let src = if channel == 0 { &block.0 } else { &block.1 };
            let o = (at - b * self.block_frames()) as usize;
            let take = (n - done).min(src.len().saturating_sub(o));
            if take == 0 {
                break;
            }
            buffer[done..done + take].copy_from_slice(&src[o..o + take]);
            done += take;
        }
        Ok(done)
    }

    fn is_mono(&self) -> bool {
        self.is_mono
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mxffile::fixture::{MxfFixture as F, sample, small_frames};

    fn open(
        fx: &F,
        sample_rate: i64,
        left: Option<&[i64]>,
        right: Option<&[i64]>,
    ) -> Result<MxfAudioSource, MediaError> {
        MxfAudioSource::new(MxfFile::from_data(fx.build(), Path::new("/dev/null"))?, sample_rate, left, right)
    }

    fn open_lazy(fx: &F, eager_units: usize) -> Result<MxfAudioSource, MediaError> {
        let file = MxfFile::from_data(fx.build(), Path::new("/dev/null"))?;
        MxfAudioSource::with_eager_units(file, 48_000, None, None, eager_units)
    }

    fn samples(a: &MxfAudioSource, channel: usize, from: i64, count: usize) -> Vec<f32> {
        let mut b = vec![-9.0f32; count];
        let n = a.read_source_channel(channel, from, &mut b);
        b.truncate(n);
        b
    }

    fn expected(c: i64, n: i64, bits: i64) -> f32 {
        sample(c, n, bits) as f32 / (1i64 << (bits - 1)) as f32
    }

    fn expected_range(c: i64, from: i64, to: i64, bits: i64) -> Vec<f32> {
        (from..to).map(|n| expected(c, n, bits)).collect()
    }

    fn read(a: &MxfAudioSource, from: i64, count: usize, channel: usize) -> Vec<f32> {
        let mut b = vec![0.0f32; count];
        assert_eq!(a.read(from, &mut b, channel), Ok(count));
        b
    }

    #[test]
    fn multi_mono_audio_tracks_are_channels() {
        for (bits, big_endian) in [(24, false), (24, true), (16, false), (32, true)] {
            let fx = F {
                frames: small_frames(12),
                audio_tracks: 4,
                audio_bits: bits,
                audio_big_endian: big_endian,
                ..F::default()
            };
            let a = open(&fx, 48_000, None, None).unwrap_or_else(|e| panic!("{e}"));
            assert_eq!((a.channel_count(), a.native_rate, a.total_frames), (4, 48_000, 12 * 1920));
            assert_eq!(a.channels.iter().map(|c| c.bits).collect::<Vec<_>>(), vec![bits; 4]);
            assert!(a.is_mono());
            for c in 0..4 {
                // Across the boundary between two edit units.
                let got = samples(&a, c, 1900, 100);
                assert_eq!(
                    got,
                    expected_range(c as i64, 1900, 2000, bits),
                    "channel {c}, {bits} bit, big endian {big_endian}"
                );
            }
            assert_eq!(samples(&a, 3, 12 * 1920 - 10, 50).len(), 10);
            assert!(samples(&a, 4, 0, 10).is_empty());

            // Default mix: mono channels are centered, channels 1 and 2 on both sides (one microphone on channel 1
            // is not heard left only), each at -3 dB so that dual mono does not come out 6 dB hot.
            let l = read(&a, 5000, 64, 0);
            let r = read(&a, 5000, 64, 1);
            let g = 0.5f32.sqrt();
            for i in 0..64 {
                let want = (expected(0, 5000 + i, bits) + expected(1, 5000 + i, bits)) * g;
                assert!((l[i as usize] - want).abs() < 1e-6);
            }
            assert_eq!(r, l);
            assert_eq!((&a.left, &a.right), (&vec![0, 1], &vec![0, 1]));
        }
    }

    #[test]
    fn audio_routing_and_cadence() {
        let mut fx = F {
            frames: small_frames(12),
            audio_tracks: 4,
            edit_rate: (30_000, 1001),
            samples_per_unit: vec![1602, 1601, 1602, 1601, 1602],
            ..F::default()
        };
        let a = open(&fx, 48_000, Some(&[2, 3]), Some(&[1])).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(a.total_frames, 2 * 8008 + 1602 + 1601);
        let l = read(&a, 7000, 4000, 0);
        let r = read(&a, 7000, 4000, 1);
        for i in (0..4000).step_by(37) {
            let n = 7000 + i as i64;
            assert!((l[i] - (expected(2, n, 24) + expected(3, n, 24))).abs() < 1e-6);
            assert_eq!(r[i], expected(1, n, 24));
        }
        assert_eq!(samples(&a, 0, 16_000, 3219), expected_range(0, 16_000, 19_219, 24));
        // One channel on both sides is mono; out of range channels are ignored.
        assert!(open(&fx, 48_000, Some(&[3]), Some(&[3, 9])).unwrap_or_else(|e| panic!("{e}")).is_mono());
        // Another output rate: length follows, samples are interpolated.
        let half = open(&fx, 24_000, None, None).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(half.total_frames, (2 * 8008 + 1602 + 1601) / 2);
        let want: Vec<f32> = [200, 202, 204].iter().map(|&n| expected(1, n, 24)).collect();
        assert_eq!(samples(&half, 1, 100, 3), want);
        let mut all = 0usize;
        let done = half.stream_all(
            || false,
            |l, _| {
                all += l.len();
                Ok::<(), ()>(())
            },
        );
        assert_eq!(done, Ok(()));
        assert_eq!(all as i64, half.total_frames);
        assert_eq!(half.stream_all(|| true, |_, _| Ok::<(), ()>(())), Err(StreamAllError::Cancelled));

        // Irregular unit lengths (fewer than ten units): per-unit table.
        fx.frames = small_frames(4);
        fx.samples_per_unit = vec![1000, 1920, 7, 1500];
        let odd = open(&fx, 48_000, None, None).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(odd.total_frames, 4427);
        assert_eq!(samples(&odd, 2, 2900, 60), expected_range(2, 2900, 2960, 24));
    }

    #[test]
    fn audio_only_and_unsupported_sound() {
        let mut fx = F { audio_tracks: 2, samples_per_unit: vec![48_000], ..F::default() };
        let file = MxfFile::from_data(fx.build(), Path::new("/dev/null")).unwrap_or_else(|e| panic!("{e}"));
        assert!(file.video_track().is_none());
        let a = MxfAudioSource::new(file, 48_000, None, None).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(a.total_frames, 48_000);
        assert_eq!(samples(&a, 0, 47_990, 10), expected_range(0, 47_990, 48_000, 24));

        fx.frames = small_frames(3);
        fx.samples_per_unit = vec![1920];
        fx.audio_compression =
            Some(vec![0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x04, 0x02, 0x02, 0x02, 0x03, 0x02, 0x01, 0x00]);
        assert_eq!(
            open(&fx, 48_000, None, None).err(),
            Some(MediaError::UnsupportedCodec("AC-3 audio in MXF".to_string()))
        );
        fx.audio_compression = None;
        fx.sound_element_type = 0x10;
        assert_eq!(
            open(&fx, 48_000, None, None).err(),
            Some(MediaError::UnsupportedCodec("D-10 AES3 audio in MXF".to_string()))
        );
    }

    /// A corrupt edit rate or sample rate returns an error instead of overflowing.
    #[test]
    fn corrupt_rates_do_not_overflow_the_length() {
        let fx = F {
            frames: small_frames(12),
            audio_tracks: 2,
            samples_per_unit: vec![1000, 1920, 7, 1500],
            audio_rate: 2_147_483_647,
            edit_rate: (1, 2_147_483_647),
            ..F::default()
        };
        assert_eq!(open_lazy(&fx, 8).err(), Some(MediaError::Unreadable));
        assert_eq!(open(&fx, i64::MAX, None, None).err(), Some(MediaError::Unreadable));
    }

    /// An irregular sample cadence in a long file is not resolved while probing; a read walks only as far as it needs.
    #[test]
    fn irregular_cadence_table_is_built_on_first_read() {
        let fx = F {
            frames: small_frames(12),
            audio_tracks: 4,
            samples_per_unit: vec![1000, 1920, 7, 1500],
            ..F::default()
        };
        let eager = open(&fx, 48_000, None, None).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!((eager.total_frames, eager.walked_units()), (3 * 4427, 0));

        let lazy = open_lazy(&fx, 8).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(lazy.walked_units(), 0, "opening does not walk the units");
        assert_eq!(lazy.total_frames, 12 * 1920, "length from the edit rate until the table exists");
        assert_eq!(samples(&lazy, 0, 10, 60), expected_range(0, 10, 70, 24));
        assert_eq!(lazy.walked_units(), 1, "a read at the start walks the first unit only");
        assert_eq!(samples(&lazy, 3, 2900, 60), samples(&eager, 3, 2900, 60));
        assert_eq!(lazy.walked_units(), 4, "units 1 to 3 hold the samples");
        for from in [0, 2900, 9000, 13_200] {
            assert_eq!(samples(&lazy, 2, from, 60), samples(&eager, 2, from, 60));
        }
        assert_eq!(samples(&lazy, 1, 4400, 60), expected_range(1, 4400, 4460, 24));
        assert_eq!(lazy.walked_units(), 12);
        // Past the real end: silence.
        assert_eq!(samples(&lazy, 0, 20_000, 8), vec![0.0f32; 8]);
    }

    #[test]
    fn scan_without_index_gives_the_audio_length() {
        let fx =
            F { frames: small_frames(7), audio_tracks: 2, index: crate::mxffile::fixture::Index::None, ..F::default() };
        let a = open(&fx, 48_000, None, None).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(a.total_frames, 7 * 1920);
    }
}
