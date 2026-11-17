//! Port of `SQMedia/Sources/SQMedia/WaveformData.swift`.

use serde::{Deserialize, Serialize};
use sq_core_time::{Time, TimeRange};
use std::fmt;

/// Smallest and largest sample of one bucket.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct WaveformPeak {
    pub min: f32,
    pub max: f32,
}

/// Why a waveform could not be built.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WaveformError {
    NoAudioTrack,
    ReadFailed(String),
}

impl fmt::Display for WaveformError {
    /// English text (the display sink translates it).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WaveformError::NoAudioTrack => f.write_str("The file has no audio track."),
            WaveformError::ReadFailed(why) => write!(f, "The audio could not be read: {why}"),
        }
    }
}

impl std::error::Error for WaveformError {}

/// Why the binary form of a waveform could not be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FormatError {
    BadMagic,
    UnsupportedVersion(u32),
    Truncated,
    Invalid,
}

impl fmt::Display for FormatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FormatError::BadMagic => f.write_str("bad magic"),
            FormatError::UnsupportedVersion(v) => write!(f, "unsupported version {v}"),
            FormatError::Truncated => f.write_str("truncated"),
            FormatError::Invalid => f.write_str("invalid"),
        }
    }
}

impl std::error::Error for FormatError {}

/// Multi-resolution min/max peak summary of an audio file.
/// Level 0 has one bucket per `base_bucket_size` sample frames, level k per `base_bucket_size << k`.
/// Each level stores (min, max) per channel per bucket, interleaved: `[b0c0min, b0c0max, b0c1min, ...]`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaveformData {
    pub sample_rate: usize,
    pub channel_count: usize,
    /// Sample frames per channel in the source.
    pub total_frames: usize,
    pub base_bucket_size: usize,
    pub levels: Vec<Vec<f32>>,
}

impl WaveformData {
    pub const FORMAT_VERSION: u32 = 1;
    pub const DEFAULT_BASE_BUCKET_SIZE: usize = 256;
    const MAGIC: [u8; 4] = *b"SQWF";

    pub fn new(
        sample_rate: usize,
        channel_count: usize,
        total_frames: usize,
        base_bucket_size: usize,
        levels: Vec<Vec<f32>>,
    ) -> WaveformData {
        WaveformData { sample_rate, channel_count, total_frames, base_bucket_size, levels }
    }

    pub fn level_count(&self) -> usize {
        self.levels.len()
    }

    pub fn bucket_size(&self, level: usize) -> usize {
        self.base_bucket_size << level
    }

    pub fn bucket_count(&self, level: usize) -> usize {
        self.levels[level].len() / (2 * self.channel_count)
    }

    /// The peak of one bucket; silence for any index outside the data.
    pub fn bucket(&self, level: i64, index: i64, channel: i64) -> WaveformPeak {
        let silent = WaveformPeak { min: 0.0, max: 0.0 };
        let (Ok(level), Ok(index), Ok(channel)) =
            (usize::try_from(level), usize::try_from(index), usize::try_from(channel))
        else {
            return silent;
        };
        if level >= self.levels.len() || index >= self.bucket_count(level) || channel >= self.channel_count {
            return silent;
        }
        let o = (index * self.channel_count + channel) * 2;
        WaveformPeak { min: self.levels[level][o], max: self.levels[level][o + 1] }
    }

    /// Peaks for `buckets` equal slices of `range`, per channel (`result[channel][bucket]`).
    /// Picks the coarsest mip level whose buckets are at most a quarter of an output bucket (limits edge bleed). Time outside the audio is silent.
    pub fn peaks(&self, range: TimeRange, buckets: usize) -> Vec<Vec<WaveformPeak>> {
        let silent = WaveformPeak { min: 0.0, max: 0.0 };
        if buckets == 0 || self.channel_count == 0 || self.sample_rate == 0 || self.levels.is_empty() {
            return vec![Vec::new(); self.channel_count];
        }
        let mut out = vec![vec![silent; buckets]; self.channel_count];
        // Frame positions are exact rationals: frame = seconds * sampleRate, floored, scaled to `buckets` slices.
        let rate = self.sample_rate as i128;
        let frame = |t: Time| -> i64 {
            let n = i128::from(t.value()) * rate;
            let q = floor_div(n, i128::from(t.timescale()));
            q.clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64
        };
        let start_frame = frame(range.start);
        let end_frame = frame(range.end());
        let span = (end_frame - start_frame).max(1);
        let per_bucket = span as f64 / buckets as f64;
        let mut level = 0;
        while level + 1 < self.levels.len() && (self.bucket_size(level + 1) as f64) * 4.0 <= per_bucket {
            level += 1;
        }
        let size = self.bucket_size(level) as i64;
        let count = self.bucket_count(level) as i64;
        for (ch, row) in out.iter_mut().enumerate() {
            for (i, slot) in row.iter_mut().enumerate() {
                let a = start_frame + span * i as i64 / buckets as i64;
                let mut b = start_frame + span * (i as i64 + 1) / buckets as i64;
                if b <= a {
                    b = a + 1;
                }
                let first = floor_div_i64(a, size).max(0);
                let last = floor_div_i64(b - 1, size).min(count - 1);
                if first > last {
                    continue;
                }
                let mut lo = f32::MAX;
                let mut hi = -f32::MAX;
                for k in first as usize..=last as usize {
                    let o = (k * self.channel_count + ch) * 2;
                    lo = lo.min(self.levels[level][o]);
                    hi = hi.max(self.levels[level][o + 1]);
                }
                *slot = WaveformPeak { min: lo, max: hi };
            }
        }
        out
    }

    // MARK: Binary format (little endian)
    // "SQWF" | version u32 | sampleRate u32 | channels u32 | totalFrames u64 | baseBucket u32 | levelCount u32
    // then per level: bucketCount u32, then bucketCount*channels*2 Float32.

    pub fn serialized(&self) -> Vec<u8> {
        let mut d = Self::MAGIC.to_vec();
        d.reserve(36 + self.levels.iter().map(|l| 4 + l.len() * 4).sum::<usize>());
        // Swift traps when a field does not fit its width; these saturate instead.
        let u32_of = |v: usize| u32::try_from(v).unwrap_or(u32::MAX);
        d.extend_from_slice(&Self::FORMAT_VERSION.to_le_bytes());
        d.extend_from_slice(&u32_of(self.sample_rate).to_le_bytes());
        d.extend_from_slice(&u32_of(self.channel_count).to_le_bytes());
        d.extend_from_slice(&(self.total_frames as u64).to_le_bytes());
        d.extend_from_slice(&u32_of(self.base_bucket_size).to_le_bytes());
        d.extend_from_slice(&u32_of(self.levels.len()).to_le_bytes());
        for (i, l) in self.levels.iter().enumerate() {
            d.extend_from_slice(&u32_of(self.bucket_count(i)).to_le_bytes());
            for f in l {
                d.extend_from_slice(&f.to_bits().to_le_bytes());
            }
        }
        d
    }

    /// Reads the binary form written by `serialized`.
    pub fn from_serialized(bytes: &[u8]) -> Result<WaveformData, FormatError> {
        let mut r = Reader { bytes, pos: 0 };
        if r.take(4)? != Self::MAGIC {
            return Err(FormatError::BadMagic);
        }
        let version = r.u32()?;
        if version != Self::FORMAT_VERSION {
            return Err(FormatError::UnsupportedVersion(version));
        }
        let rate = r.u32()? as usize;
        let channels = r.u32()? as usize;
        let s = r.take(8)?;
        let frames = u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]);
        let frames = usize::try_from(frames).map_err(|_| FormatError::Invalid)?;
        let base = r.u32()? as usize;
        let level_count = r.u32()? as usize;
        if channels == 0 || channels > 64 || base == 0 || level_count > 64 {
            return Err(FormatError::Invalid);
        }
        let mut levels: Vec<Vec<f32>> = Vec::new();
        for _ in 0..level_count {
            let n = r.u32()? as usize * channels * 2;
            let raw = r.take(n * 4)?;
            levels.push(raw.as_chunks::<4>().0.iter().map(|c| f32::from_bits(u32::from_le_bytes(*c))).collect());
        }
        Ok(WaveformData::new(rate, channels, frames, base, levels))
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], FormatError> {
        let end = self.pos.checked_add(n).filter(|&e| e <= self.bytes.len()).ok_or(FormatError::Truncated)?;
        let s = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    fn u32(&mut self) -> Result<u32, FormatError> {
        let s = self.take(4)?;
        Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }
}

fn floor_div(a: i128, b: i128) -> i128 {
    let q = a / b;
    if a % b != 0 && (a < 0) != (b < 0) { q - 1 } else { q }
}

fn floor_div_i64(a: i64, b: i64) -> i64 {
    let q = a / b;
    if a % b != 0 && (a < 0) != (b < 0) { q - 1 } else { q }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 48 kHz stereo, 256-frame base buckets, mip levels merged pairwise; every channel has a click (min 0, max 1)
    /// at each of `clicks` (sample frames).
    fn with_clicks(clicks: &[usize], frames: usize) -> WaveformData {
        let base = 256;
        let buckets = frames.div_ceil(base);
        let mut level = vec![0f32; buckets * 2 * 2];
        for &c in clicks {
            for ch in 0..2 {
                level[((c / base) * 2 + ch) * 2 + 1] = 1.0;
            }
        }
        let mut levels = vec![level];
        while levels.last().is_some_and(|l| l.len() / 4 > 1) {
            let prev = &levels[levels.len() - 1];
            let n = (prev.len() / 4).div_ceil(2);
            let mut next = vec![0f32; n * 4];
            for b in 0..n {
                for ch in 0..2 {
                    for (k, src) in [2 * b, 2 * b + 1].into_iter().enumerate() {
                        let o = (src * 2 + ch) * 2;
                        if o + 1 >= prev.len() {
                            continue;
                        }
                        let t = (b * 2 + ch) * 2;
                        next[t] = if k == 0 { prev[o] } else { next[t].min(prev[o]) };
                        next[t + 1] = next[t + 1].max(prev[o + 1]);
                    }
                }
            }
            levels.push(next);
        }
        WaveformData::new(48_000, 2, frames, base, levels)
    }

    #[test]
    fn click_lands_in_right_bucket() {
        let wf = with_clicks(&[48_000, 120_000], 192_000);
        assert_eq!(wf.base_bucket_size, 256);
        for sample in [48_000i64, 120_000] {
            let b = sample / 256;
            for ch in 0..2 {
                assert_eq!(wf.bucket(0, b, ch), WaveformPeak { min: 0.0, max: 1.0 });
                assert_eq!(wf.bucket(0, b - 1, ch), WaveformPeak { min: 0.0, max: 0.0 });
                assert_eq!(wf.bucket(0, b + 1, ch), WaveformPeak { min: 0.0, max: 0.0 });
            }
        }
        assert_eq!(wf.bucket(-1, 0, 0), WaveformPeak { min: 0.0, max: 0.0 });
        assert_eq!(wf.bucket(0, 0, 2), WaveformPeak { min: 0.0, max: 0.0 });
    }

    #[test]
    fn peaks_in_range() {
        let wf = with_clicks(&[84_480], 192_000); // 1.76 s
        // 0..4 s in 8 buckets of 0.5 s: the click (1.76 s) is inside bucket 3 (1.5..2.0 s).
        let peaks = wf.peaks(TimeRange::new(Time::ZERO, Time::new(4, 1)), 8);
        assert!(peaks.len() == 2 && peaks[0].len() == 8);
        for (i, p) in peaks[0].iter().enumerate() {
            assert_eq!(p.max, if i == 3 { 1.0 } else { 0.0 });
        }
        // Zoomed in on 1.7..1.8 s (4 buckets of 25 ms): 1.76 s lands in bucket 2.
        let z = wf.peaks(TimeRange::from_end(Time::new(17, 10), Time::new(18, 10)), 4);
        assert_eq!(z[0].iter().map(|p| p.max).collect::<Vec<_>>(), vec![0.0, 0.0, 1.0, 0.0]);
        // Outside the clip: silence, no crash.
        let out = wf.peaks(TimeRange::new(Time::new(100, 1), Time::new(1, 1)), 3);
        assert!(out[0].iter().all(|p| p.max == 0.0 && p.min == 0.0));
    }

    #[test]
    fn mip_levels_agree() {
        let wf = with_clicks(&[96_000], 192_000);
        assert!(wf.level_count() > 3);
        for level in 1..wf.level_count() {
            let size = wf.bucket_size(level);
            assert_eq!(size, wf.base_bucket_size << level);
            assert_eq!(wf.bucket(level as i64, (96_000 / size) as i64, 0).max, 1.0);
        }
        assert!(wf.bucket_count(wf.level_count() - 1) <= 2);
    }

    #[test]
    fn binary_round_trip_and_version() {
        let wf = with_clicks(&[8000], 30 * 1600);
        let data = wf.serialized();
        assert_eq!(WaveformData::from_serialized(&data), Ok(wf.clone()));
        let mut bad = data.clone();
        bad[4] = 99; // version byte
        assert_eq!(WaveformData::from_serialized(&bad), Err(FormatError::UnsupportedVersion(99)));
        bad[0] = b'X';
        assert_eq!(WaveformData::from_serialized(&bad), Err(FormatError::BadMagic));
        assert_eq!(WaveformData::from_serialized(&data[..10]), Err(FormatError::Truncated));
        assert_eq!(WaveformData::from_serialized(&data[..data.len() - 3]), Err(FormatError::Truncated));
        let json = serde_json::to_string(&wf).unwrap();
        assert_eq!(serde_json::from_str::<WaveformData>(&json).unwrap(), wf);
    }

    #[test]
    fn serialization_round_trips_large_data() {
        let first: Vec<f32> = (0..20_000).map(|i| i as f32 * 0.001 - 7.0).collect();
        let second = vec![f32::MAX, -f32::MAX, 0.0, -0.0];
        let wf = WaveformData::new(44_100, 2, 1_234_567, 256, vec![first, second]);
        let back = WaveformData::from_serialized(&wf.serialized()).unwrap();
        let bits = |w: &WaveformData| {
            w.levels.iter().map(|l| l.iter().map(|f| f.to_bits()).collect::<Vec<_>>()).collect::<Vec<_>>()
        };
        assert_eq!(bits(&back), bits(&wf));
        assert_eq!(back, wf);
    }

    #[test]
    fn json_uses_the_swift_property_names() {
        let wf = WaveformData::new(48_000, 1, 10, 256, vec![vec![0.5, 1.0]]);
        assert_eq!(
            serde_json::to_string(&wf).unwrap(),
            r#"{"sampleRate":48000,"channelCount":1,"totalFrames":10,"baseBucketSize":256,"levels":[[0.5,1.0]]}"#
        );
    }

    #[test]
    fn invalid_headers_are_rejected() {
        let wf = WaveformData::new(48_000, 1, 10, 256, vec![vec![0.5, 1.0]]);
        let mut d = wf.serialized();
        d[12..16].copy_from_slice(&0u32.to_le_bytes()); // channels 0
        assert_eq!(WaveformData::from_serialized(&d), Err(FormatError::Invalid));
    }

    #[test]
    fn error_texts() {
        assert_eq!(WaveformError::NoAudioTrack.to_string(), "The file has no audio track.");
        assert_eq!(WaveformError::ReadFailed("x".into()).to_string(), "The audio could not be read: x");
    }
}
