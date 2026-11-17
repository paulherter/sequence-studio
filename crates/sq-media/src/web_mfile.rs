//! Port of `SQMedia/Sources/SQMedia/WebM/WebMFile.swift`.

use crate::media_error::MediaError;
use sq_core_time::Time;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// What a Matroska track carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WebMTrackKind {
    Video,
    Audio,
    Other,
}

/// One track of a Matroska / WebM file.
#[derive(Clone, Debug, PartialEq)]
pub struct WebMTrack {
    pub number: i64,
    pub kind: WebMTrackKind,
    pub codec_id: String,
    pub codec_private: Vec<u8>,
    // Video
    pub width: i64,
    pub height: i64,
    pub matrix: Option<i64>,
    pub transfer: Option<i64>,
    pub primaries: Option<i64>,
    pub range: Option<i64>,
    pub bits_per_channel: Option<i64>,
    // Audio
    pub sample_rate: f64,
    pub channels: i64,
    pub bit_depth: i64,
    /// Nanoseconds per frame, 0 = unknown.
    pub default_duration: i64,
    /// Opus: samples (48 kHz) to drop from the start; ns of decoder pre-roll.
    pub codec_delay_ns: i64,
    pub seek_pre_roll_ns: i64,
    /// The track's blocks are compressed or encrypted (ContentEncodings): not readable here.
    pub has_content_encoding: bool,
}

impl Default for WebMTrack {
    fn default() -> WebMTrack {
        WebMTrack {
            number: 0,
            kind: WebMTrackKind::Other,
            codec_id: String::new(),
            codec_private: Vec::new(),
            width: 0,
            height: 0,
            matrix: None,
            transfer: None,
            primaries: None,
            range: None,
            bits_per_channel: None,
            sample_rate: 0.0,
            channels: 0,
            bit_depth: 0,
            default_duration: 0,
            codec_delay_ns: 0,
            seek_pre_roll_ns: 0,
            has_content_encoding: false,
        }
    }
}

/// One frame (a laced block yields one entry per frame) of a track, located in the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WebMBlock {
    pub track: i32,
    pub is_key: bool,
    /// Absolute time in `WebMFile::timecode_scale` units.
    pub ticks: i64,
    /// BlockDuration in ticks, `None` when the block has none.
    pub duration_ticks: Option<i64>,
    pub offset: i64,
    pub size: i32,
}

/// Structure of a Matroska / WebM file: tracks and the location of every frame. The payload stays in the file bytes;
/// `WebMFile` is parsed once per file and cached.
#[derive(Debug)]
pub struct WebMFile {
    pub url: PathBuf,
    /// Nanoseconds per tick (default 1 000 000 = 1 ms).
    pub timecode_scale: i64,
    pub tracks: Vec<WebMTrack>,
    /// All blocks in file order.
    pub blocks: Vec<WebMBlock>,
    /// Segment duration in seconds, from the Info element.
    pub info_duration: Option<f64>,
    data: Vec<u8>,
}

/// Most recently opened files (a few, parsed structure only).
static CACHE: Mutex<Vec<(String, Arc<WebMFile>)>> = Mutex::new(Vec::new());

impl WebMFile {
    pub fn track(&self, kind: WebMTrackKind) -> Option<&WebMTrack> {
        self.tracks.iter().find(|t| t.kind == kind)
    }

    pub fn blocks_of(&self, track: i64) -> Vec<WebMBlock> {
        self.blocks.iter().filter(|b| i64::from(b.track) == track).copied().collect()
    }

    /// Time of `ticks` as a rational.
    pub fn time(&self, ticks: i64) -> Time {
        let ns_per_second: i64 = 1_000_000_000;
        if ns_per_second % self.timecode_scale == 0 {
            return Time::new(ticks, ns_per_second / self.timecode_scale);
        }
        // Swift traps on overflow.
        Time::new(ticks.saturating_mul(self.timecode_scale), ns_per_second)
    }

    /// The bytes of a block (empty when the block lies outside the file; Swift traps).
    pub fn payload(&self, b: &WebMBlock) -> &[u8] {
        let start = usize::try_from(b.offset).unwrap_or(usize::MAX);
        let end = start.saturating_add(usize::try_from(b.size).unwrap_or(0));
        self.data.get(start..end).unwrap_or(&[])
    }

    /// True when the file starts with the EBML magic.
    pub fn is_webm(url: &Path) -> bool {
        use std::io::Read;
        let Ok(mut f) = std::fs::File::open(url) else { return false };
        let mut head = [0u8; 4];
        f.read_exact(&mut head).is_ok() && head == [0x1A, 0x45, 0xDF, 0xA3]
    }

    // MARK: cache

    /// The parsed file, from the cache when the same file (path, size, modification date) was opened lately.
    pub fn open(url: &Path) -> Result<Arc<WebMFile>, MediaError> {
        let attrs = std::fs::metadata(url).ok();
        let modified = attrs
            .as_ref()
            .and_then(|a| a.modified().ok())
            .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_nanos());
        let key = format!("{}|{}|{}", url.display(), attrs.as_ref().map_or(0, |a| a.len()), modified);
        let cached = CACHE.lock().ok().and_then(|c| c.iter().find(|(k, _)| *k == key).map(|(_, f)| Arc::clone(f)));
        if let Some(f) = cached {
            return Ok(f);
        }
        let f = Arc::new(WebMFile::new(url)?);
        if let Ok(mut c) = CACHE.lock() {
            c.push((key, Arc::clone(&f)));
            if c.len() > 6 {
                c.remove(0);
            }
        }
        Ok(f)
    }

    // MARK: parsing

    // shortcut: reads the whole file into memory (Swift maps it), upgrade to a memory map when large files matter.
    pub fn new(url: &Path) -> Result<WebMFile, MediaError> {
        let d = std::fs::read(url).map_err(|_| MediaError::Unreadable)?;
        WebMFile::from_data(url.to_path_buf(), d)
    }

    /// Parses `data` as the content of `url`.
    pub fn from_data(url: PathBuf, data: Vec<u8>) -> Result<WebMFile, MediaError> {
        if data.len() <= 16 {
            return Err(MediaError::Unreadable);
        }
        let mut p = Parser::new(&data);
        p.parse();
        if p.tracks.is_empty() {
            return Err(MediaError::Unreadable);
        }
        let (timecode_scale, tracks, blocks, info_duration) = (p.timecode_scale, p.tracks, p.blocks, p.duration);
        Ok(WebMFile { url, timecode_scale, tracks, blocks, info_duration, data })
    }
}

/// `Int(size)` of an EBML size: `None` when it does not fit a signed 64-bit integer (Swift traps).
fn as_int(size: u64) -> Option<usize> {
    i64::try_from(size).ok().and_then(|n| usize::try_from(n).ok())
}

/// Element walker over the file bytes.
pub(crate) struct Parser<'a> {
    data: &'a [u8],
    timecode_scale: i64,
    duration: Option<f64>,
    tracks: Vec<WebMTrack>,
    blocks: Vec<WebMBlock>,
    cluster_time: i64,
}

impl<'a> Parser<'a> {
    const UNKNOWN: u64 = u64::MAX;

    fn new(data: &'a [u8]) -> Parser<'a> {
        Parser {
            data,
            timecode_scale: 1_000_000,
            duration: None,
            tracks: Vec::new(),
            blocks: Vec::new(),
            cluster_time: 0,
        }
    }

    // Swift traps on an index past the end; unreadable bytes read as 0 here.
    fn byte(&self, i: usize) -> u8 {
        self.data.get(i).copied().unwrap_or(0)
    }

    /// EBML element ID (marker bits kept) at `i`; `None` when invalid or out of range.
    fn read_id(&self, i: usize) -> Option<(u32, usize)> {
        if i >= self.data.len() {
            return None;
        }
        let n = self.byte(i).leading_zeros() as usize + 1;
        if n > 4 || i + n > self.data.len() {
            return None;
        }
        let mut v = 0u32;
        for k in 0..n {
            v = v << 8 | u32::from(self.byte(i + k));
        }
        Some((v, n))
    }

    /// EBML variable-size integer (marker removed); all-ones = unknown size.
    fn read_vint(&self, i: usize) -> Option<(u64, usize)> {
        if i >= self.data.len() {
            return None;
        }
        let b = self.byte(i);
        if b == 0 {
            return None;
        }
        let n = b.leading_zeros() as usize + 1;
        if i + n > self.data.len() {
            return None;
        }
        let mut v = u64::from(b) & (0xFF >> n);
        let mut all_ones = v == (0xFF >> n);
        for k in 1..n.max(1) {
            let x = self.byte(i + k);
            if x != 0xFF {
                all_ones = false;
            }
            v = v << 8 | u64::from(x);
        }
        Some((if all_ones { Self::UNKNOWN } else { v }, n))
    }

    fn uint(&self, at: usize, size: usize) -> u64 {
        let mut v: u64 = 0;
        for k in 0..size.min(8) {
            v = v << 8 | u64::from(self.byte(at + k));
        }
        v
    }

    /// `Int64(uint)`: Swift traps above `Int64.max`.
    fn int(&self, at: usize, size: usize) -> i64 {
        i64::try_from(self.uint(at, size)).unwrap_or(i64::MAX)
    }

    fn float(&self, at: usize, size: usize) -> Option<f64> {
        if size == 4 {
            return Some(f64::from(f32::from_bits(self.uint(at, 4) as u32)));
        }
        if size == 8 {
            return Some(f64::from_bits(self.uint(at, 8)));
        }
        None
    }

    /// The next child element of a master at `i` (before `end`) with a known size: ID, body start and body size.
    fn child(&self, i: usize, end: usize) -> Option<(u32, usize, usize)> {
        if i >= end {
            return None;
        }
        let (id, il) = self.read_id(i)?;
        let (size, sl) = self.read_vint(i + il)?;
        if size == Self::UNKNOWN {
            return None;
        }
        Some((id, i + il + sl, as_int(size)?))
    }

    fn parse(&mut self) {
        // Top level: the EBML header, then the Segment. Segment and Cluster are walked flat (their size may be
        // unknown in live recordings); other masters are read with their known size.
        let mut i = 0;
        let end = self.data.len();
        while i < end {
            let Some((id, il)) = self.read_id(i) else { break };
            let Some((size, sl)) = self.read_vint(i + il) else { break };
            let body = i + il + sl;
            if matches!(id, 0x18538067 | 0x1F43B675) {
                i = body; // Segment, Cluster: enter
                continue;
            }
            if size == Self::UNKNOWN {
                return;
            }
            let Some(n) = as_int(size) else { return };
            let next = body.saturating_add(n);
            match id {
                0x1549A966 => self.parse_info(body, next),                 // Info
                0x1654AE6B => self.parse_tracks(body, end.min(next)),      // Tracks
                0xE7 => self.cluster_time = self.uint(body, n) as i64, // cluster Timecode (bit pattern, like Int64(bitPattern:))
                0xA3 => self.add_block(body as i64, n as i64, None, None), // SimpleBlock
                0xA0 => self.parse_group(body, end.min(next)),         // BlockGroup
                _ => {}
            }
            i = next;
        }
    }

    fn parse_info(&mut self, start: usize, end: usize) {
        let mut i = start;
        let mut dur: Option<f64> = None;
        while let Some((id, body, n)) = self.child(i, end) {
            if id == 0x2AD7B1 {
                self.timecode_scale = self.int(body, n).max(1);
            } else if id == 0x4489 {
                dur = self.float(body, n);
            }
            i = body.saturating_add(n);
        }
        if let Some(dur) = dur {
            self.duration = Some(dur * self.timecode_scale as f64 / 1_000_000_000.0);
        }
    }

    fn parse_tracks(&mut self, start: usize, end: usize) {
        let mut i = start;
        while let Some((id, body, n)) = self.child(i, end) {
            if id == 0xAE {
                let track = self.parse_track_entry(body, end.min(body.saturating_add(n)));
                self.tracks.push(track);
            }
            i = body.saturating_add(n);
        }
    }

    fn parse_track_entry(&self, start: usize, end: usize) -> WebMTrack {
        let mut t = WebMTrack::default();
        let mut i = start;
        while let Some((id, body, n)) = self.child(i, end) {
            match id {
                0xD7 => t.number = self.int(body, n),
                0x83 => {
                    let k = self.uint(body, n);
                    t.kind = if k == 1 {
                        WebMTrackKind::Video
                    } else if k == 2 {
                        WebMTrackKind::Audio
                    } else {
                        WebMTrackKind::Other
                    };
                }
                0x86 => {
                    let bytes = self.slice(body, n);
                    let text: Vec<u8> = bytes.iter().copied().take_while(|&b| b != 0).collect();
                    t.codec_id = String::from_utf8_lossy(&text).into_owned();
                }
                0x63A2 => t.codec_private = self.slice(body, n).to_vec(),
                0x56AA => t.codec_delay_ns = self.int(body, n),
                0x56BB => t.seek_pre_roll_ns = self.int(body, n),
                0x23E383 => t.default_duration = self.int(body, n),
                0x6D80 => t.has_content_encoding = true,
                0xE0 => self.parse_video(&mut t, body, body.saturating_add(n)),
                0xE1 => {
                    let e = body.saturating_add(n);
                    let mut j = body;
                    while let Some((cid, cb, cn)) = self.child(j, e) {
                        match cid {
                            0xB5 => t.sample_rate = self.float(cb, cn).unwrap_or(0.0),
                            0x9F => t.channels = self.int(cb, cn),
                            0x6264 => t.bit_depth = self.int(cb, cn),
                            _ => {}
                        }
                        j = cb.saturating_add(cn);
                    }
                }
                _ => {}
            }
            i = body.saturating_add(n);
        }
        t
    }

    fn parse_video(&self, t: &mut WebMTrack, body: usize, e: usize) {
        let mut j = body;
        while let Some((cid, cb, cn)) = self.child(j, e) {
            match cid {
                0xB0 => t.width = self.int(cb, cn),
                0xBA => t.height = self.int(cb, cn),
                0x55B0 => {
                    let ke = cb.saturating_add(cn);
                    let mut k = cb;
                    while let Some((kid, kb, kn)) = self.child(k, ke) {
                        match kid {
                            0x55B1 => t.matrix = Some(self.int(kb, kn)),
                            0x55B2 => t.bits_per_channel = Some(self.int(kb, kn)),
                            0x55B9 => t.range = Some(self.int(kb, kn)),
                            0x55BA => t.transfer = Some(self.int(kb, kn)),
                            0x55BB => t.primaries = Some(self.int(kb, kn)),
                            _ => {}
                        }
                        k = kb.saturating_add(kn);
                    }
                }
                _ => {}
            }
            j = cb.saturating_add(cn);
        }
    }

    /// `n` bytes at `at`, as far as the file has them (Swift traps past the end).
    fn slice(&self, at: usize, n: usize) -> &'a [u8] {
        let start = at.min(self.data.len());
        &self.data[start..at.saturating_add(n).min(self.data.len())]
    }

    fn parse_group(&mut self, start: usize, end: usize) {
        let mut i = start;
        let mut block: Option<(usize, usize)> = None;
        let mut dur: Option<i64> = None;
        let mut has_ref = false;
        while let Some((id, body, n)) = self.child(i, end) {
            match id {
                0xA1 => block = Some((body, n)),
                0x9B => dur = Some(self.int(body, n)),
                0xFB => has_ref = true,
                _ => {}
            }
            i = body.saturating_add(n);
        }
        if let Some((at, size)) = block {
            self.add_block(at as i64, size as i64, Some(!has_ref), dur);
        }
    }

    /// Next EBML-laced frame size: previous size plus the signed delta `raw - bias`. `None` when the value is
    /// unknown, would be negative or overflows (corrupt file).
    pub(crate) fn lace_size(prev: i64, raw: u64, length: usize) -> Option<i64> {
        if raw == Self::UNKNOWN || !(1..=8).contains(&length) {
            return None;
        }
        let r = i64::try_from(raw).ok()?;
        let bias = (1i64 << (7 * length as i64 - 1)) - 1;
        let delta = r.checked_sub(bias)?;
        let sum = prev.checked_add(delta)?;
        if sum < 0 { None } else { Some(sum) }
    }

    /// Block header: track vint, int16 timecode, flags, then the (possibly laced) frames.
    fn add_block(&mut self, at: i64, size: i64, key: Option<bool>, duration: Option<i64>) {
        let len = self.data.len() as i64;
        if size < 4 || at + size > len {
            return;
        }
        let Some((track, tl)) = self.read_vint(at as usize) else { return };
        let tl = tl as i64;
        let rel = self.uint((at + tl) as usize, 2) as u16 as i16;
        let flags = self.byte((at + tl + 2) as usize);
        let is_key = key.unwrap_or(flags & 0x80 != 0);
        let lacing = (flags >> 1) & 3;
        let mut pos = at + tl + 3;
        let end = at + size;
        let ticks = self.cluster_time.wrapping_add(i64::from(rel));
        let track = track as i32; // truncating, like Int32(truncatingIfNeeded:)
        if lacing == 0 {
            // Swift traps when the size does not fit 32 bits.
            if let Ok(size) = i32::try_from(end - pos) {
                self.blocks.push(WebMBlock { track, is_key, ticks, duration_ticks: duration, offset: pos, size });
            }
            return;
        }
        if pos >= end {
            return;
        }
        let count = i64::from(self.byte(pos as usize)) + 1;
        pos += 1;
        let mut sizes: Vec<i64> = Vec::new();
        match lacing {
            1 => {
                // Xiph
                for _ in 0..count - 1 {
                    let mut s = 0;
                    while pos < end {
                        let b = i64::from(self.byte(pos as usize));
                        pos += 1;
                        s += b;
                        if b != 255 {
                            break;
                        }
                    }
                    sizes.push(s);
                }
            }
            3 => {
                // EBML
                let Some((first, fl)) = self.read_vint(pos as usize) else { return };
                pos += fl as i64;
                let Ok(first_size) = i64::try_from(first) else { return };
                if first == Self::UNKNOWN || first_size > end - pos {
                    return;
                }
                sizes.push(first_size);
                if count > 2 {
                    for _ in 1..count - 1 {
                        let Some((raw, l)) = self.read_vint(pos as usize) else { return };
                        let Some(prev) = sizes.last().copied() else { return };
                        let Some(next) = Self::lace_size(prev, raw, l) else { return };
                        if next > end - pos {
                            return;
                        }
                        pos += l as i64;
                        sizes.push(next);
                    }
                }
            }
            _ => {
                // fixed
                let each = (end - pos) / count;
                sizes = vec![each; (count - 1) as usize];
            }
        }
        let used: i64 = sizes.iter().sum();
        sizes.push(end - pos - used);
        for (k, s) in sizes.into_iter().enumerate() {
            if s > 0 && pos + s <= end {
                // Laced frames have no own timestamp: the caller spaces them with the track's default duration.
                if let Ok(size) = i32::try_from(s) {
                    self.blocks.push(WebMBlock {
                        track,
                        is_key,
                        ticks: ticks + k as i64,
                        duration_ticks: None,
                        offset: pos,
                        size,
                    });
                }
                pos += s;
            }
        }
    }
}

/// Minimal Matroska / WebM writer for tests: tracks plus frames, written as 1 s clusters.
#[cfg(test)]
pub(crate) mod test_writer {
    use std::collections::BTreeMap;

    #[derive(Clone, Default)]
    pub struct Track {
        pub number: i64,
        pub is_video: bool,
        pub codec_id: String,
        pub codec_private: Vec<u8>,
        pub width: i64,
        pub height: i64,
        pub channels: i64,
        pub rate: f64,
        pub bit_depth: i64,
        pub default_duration_ns: i64,
        pub codec_delay_ns: i64,
    }

    #[derive(Clone)]
    pub struct Frame {
        pub track: i64,
        pub ms: i64,
        pub key: bool,
        pub data: Vec<u8>,
    }

    #[derive(Default)]
    pub struct WebMTestWriter {
        pub tracks: Vec<Track>,
        pub frames: Vec<Frame>,
        /// Cluster and Segment with the "unknown size" marker (live recordings).
        pub unknown_sizes: bool,
        /// Write non-key video blocks as BlockGroups (with ReferenceBlock) and key frames as SimpleBlocks.
        pub block_groups: bool,
        /// Keep `frames` in the given (decode) order instead of sorting by time: B-frame streams.
        pub keep_order: bool,
    }

    pub fn el(id: &[u8], body: &[u8]) -> Vec<u8> {
        let mut d = id.to_vec();
        let mut size = body.len() as u64;
        let mut s = [0u8; 8];
        for i in (1..8).rev() {
            s[i] = (size & 0xFF) as u8;
            size >>= 8;
        }
        s[0] = 0x01;
        d.extend(s);
        d.extend(body);
        d
    }

    pub fn uint(id: &[u8], v: i64) -> Vec<u8> {
        let mut bytes: Vec<u8> = Vec::new();
        let mut x = v as u64;
        loop {
            bytes.insert(0, (x & 0xFF) as u8);
            x >>= 8;
            if x == 0 {
                break;
            }
        }
        el(id, &bytes)
    }

    pub fn float(id: &[u8], v: f64) -> Vec<u8> {
        el(id, &v.to_bits().to_be_bytes())
    }

    pub fn str(id: &[u8], v: &str) -> Vec<u8> {
        el(id, v.as_bytes())
    }

    impl WebMTestWriter {
        pub fn data(&self) -> Vec<u8> {
            let mut out = el(&[0x1A, 0x45, 0xDF, 0xA3], &str(&[0x42, 0x82], "webm"));
            let mut seg = Vec::new();
            seg.extend(el(&[0x15, 0x49, 0xA9, 0x66], &uint(&[0x2A, 0xD7, 0xB1], 1_000_000)));
            let mut tr = Vec::new();
            for t in &self.tracks {
                let mut e = uint(&[0xD7], t.number);
                e.extend(uint(&[0x83], if t.is_video { 1 } else { 2 }));
                e.extend(str(&[0x86], &t.codec_id));
                if !t.codec_private.is_empty() {
                    e.extend(el(&[0x63, 0xA2], &t.codec_private));
                }
                if t.default_duration_ns > 0 {
                    e.extend(uint(&[0x23, 0xE3, 0x83], t.default_duration_ns));
                }
                if t.codec_delay_ns > 0 {
                    e.extend(uint(&[0x56, 0xAA], t.codec_delay_ns));
                }
                if t.is_video {
                    let mut v = uint(&[0xB0], t.width);
                    v.extend(uint(&[0xBA], t.height));
                    e.extend(el(&[0xE0], &v));
                } else {
                    let mut a = float(&[0xB5], t.rate);
                    a.extend(uint(&[0x9F], t.channels));
                    if t.bit_depth > 0 {
                        a.extend(uint(&[0x62, 0x64], t.bit_depth));
                    }
                    e.extend(el(&[0xE1], &a));
                }
                tr.extend(el(&[0xAE], &e));
            }
            seg.extend(el(&[0x16, 0x54, 0xAE, 0x6B], &tr));
            let mut sorted = self.frames.clone();
            if !self.keep_order {
                sorted.sort_by_key(|f| f.ms);
            }
            // A frame that comes later in decode order than one of the next second stays in the current cluster
            // (negative block offset), so the file order is kept.
            let mut clusters: BTreeMap<i64, Vec<&Frame>> = BTreeMap::new();
            let mut current = 0;
            for f in &sorted {
                current = current.max(f.ms / 1000 * 1000);
                clusters.entry(current).or_default().push(f);
            }
            for (start, frames) in clusters {
                let mut body = uint(&[0xE7], start);
                for f in frames {
                    let video = self.tracks.iter().find(|t| t.number == f.track).is_some_and(|t| t.is_video);
                    let mut hdr = vec![0x80 | f.track as u8];
                    hdr.extend(((f.ms - start) as i16 as u16).to_be_bytes());
                    if self.block_groups && video && !f.key {
                        hdr.push(0);
                        hdr.extend(&f.data);
                        let mut group = el(&[0xA1], &hdr);
                        group.extend(el(&[0xFB], &[0x81]));
                        body.extend(el(&[0xA0], &group));
                    } else {
                        hdr.push(if f.key { 0x80 } else { 0 });
                        hdr.extend(&f.data);
                        body.extend(el(&[0xA3], &hdr));
                    }
                }
                if self.unknown_sizes {
                    seg.extend([0x1F, 0x43, 0xB6, 0x75, 0xFF]);
                    seg.extend(body);
                } else {
                    seg.extend(el(&[0x1F, 0x43, 0xB6, 0x75], &body));
                }
            }
            if self.unknown_sizes {
                out.extend([0x18, 0x53, 0x80, 0x67, 0xFF]);
                out.extend(seg);
            } else {
                out.extend(el(&[0x18, 0x53, 0x80, 0x67], &seg));
            }
            out
        }

        /// First bytes of a profile 0 VP9 key frame (8-bit 4:2:0, BT.709): only the uncompressed header is meaningful.
        pub fn vp9_key_frame(width: i64, height: i64, payload: usize) -> Vec<u8> {
            // marker 2, profile 0, no show-existing, key, shown, no error resilience
            let mut bits: Vec<u8> = vec![1, 0, 0, 0, 0, 0, 1, 0];
            for b in [0x49u32, 0x83, 0x42] {
                for i in (0..8).rev() {
                    bits.push(((b >> i) & 1) as u8);
                }
            }
            bits.extend([0, 1, 0, 0]); // color space 2 (BT.709), studio range
            for v in [width - 1, height - 1] {
                for i in (0..16).rev() {
                    bits.push(((v >> i) & 1) as u8);
                }
            }
            while !bits.len().is_multiple_of(8) {
                bits.push(0);
            }
            let mut d: Vec<u8> = bits.chunks(8).map(|c| c.iter().fold(0u8, |a, &b| a << 1 | b)).collect();
            d.extend(vec![0xAB; payload]);
            d
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_writer::*;
    use super::*;

    fn tmp(w: &WebMTestWriter) -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let u = std::env::temp_dir().join(format!(
            "sq-webm-{}-{}.webm",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&u, w.data()).unwrap();
        u
    }

    fn video_writer(n: i64) -> WebMTestWriter {
        let mut w = WebMTestWriter {
            tracks: vec![Track {
                number: 1,
                is_video: true,
                codec_id: "V_VP9".into(),
                width: 64,
                height: 48,
                ..Track::default()
            }],
            ..WebMTestWriter::default()
        };
        for i in 0..n {
            w.frames.push(Frame {
                track: 1,
                ms: i * 100,
                key: i % 10 == 0,
                data: WebMTestWriter::vp9_key_frame(64, 48, 16),
            });
        }
        w
    }

    #[test]
    fn is_webm_detects_header() {
        let u = tmp(&video_writer(40));
        assert!(WebMFile::is_webm(&u));
        let junk = std::env::temp_dir().join(format!("sq-webm-junk-{}.webm", std::process::id()));
        std::fs::write(&junk, [1u8; 64]).unwrap();
        assert!(!WebMFile::is_webm(&junk));
        assert!(!WebMFile::is_webm(&junk.with_extension("missing")));
    }

    #[test]
    fn parses_tracks_and_blocks() {
        let f = WebMFile::new(&tmp(&video_writer(40))).unwrap();
        assert_eq!(f.tracks.len(), 1);
        assert_eq!(f.track(WebMTrackKind::Video).map(|t| t.codec_id.as_str()), Some("V_VP9"));
        assert_eq!(f.track(WebMTrackKind::Video).map(|t| t.width), Some(64));
        assert_eq!(f.blocks_of(1).len(), 40);
        assert_eq!(f.blocks_of(1).iter().filter(|b| b.is_key).count(), 4);
        assert_eq!(f.time(f.blocks_of(1)[5].ticks), Time::new(1, 2));
        assert_eq!(f.payload(&f.blocks_of(1)[0]), &WebMTestWriter::vp9_key_frame(64, 48, 16)[..]);
    }

    #[test]
    fn unknown_size_clusters_and_block_groups() {
        let mut w = video_writer(40);
        w.unknown_sizes = true;
        w.block_groups = true;
        let f = WebMFile::new(&tmp(&w)).unwrap();
        assert_eq!(f.blocks_of(1).len(), 40);
        assert_eq!(f.blocks_of(1).iter().filter(|b| b.is_key).count(), 4);
    }

    #[test]
    fn matroska_track_details_and_open_cache() {
        let mut w = WebMTestWriter {
            tracks: vec![
                Track {
                    number: 1,
                    is_video: true,
                    codec_id: "V_MPEG4/ISO/AVC".into(),
                    codec_private: vec![1, 100, 0, 40],
                    width: 64,
                    height: 48,
                    ..Track::default()
                },
                Track {
                    number: 2,
                    codec_id: "A_OPUS".into(),
                    channels: 2,
                    rate: 48_000.0,
                    default_duration_ns: 20_000_000,
                    codec_delay_ns: 6_500_000,
                    ..Track::default()
                },
            ],
            ..WebMTestWriter::default()
        };
        w.frames.push(Frame { track: 1, ms: 0, key: true, data: vec![0, 0, 0, 5, 0x41, 0, 0, 0, 0] });
        let u = tmp(&w);
        let f = WebMFile::open(&u).unwrap();
        let v = f.track(WebMTrackKind::Video).unwrap();
        assert_eq!((v.codec_private.as_slice(), v.width, v.height), (&[1u8, 100, 0, 40][..], 64, 48));
        let a = f.track(WebMTrackKind::Audio).unwrap();
        assert_eq!(
            (a.channels, a.sample_rate, a.default_duration, a.codec_delay_ns),
            (2, 48_000.0, 20_000_000, 6_500_000)
        );
        assert!(Arc::ptr_eq(&f, &WebMFile::open(&u).unwrap()));
        assert_eq!(WebMFile::new(&u.with_extension("missing")).unwrap_err(), MediaError::Unreadable);
        assert_eq!(WebMFile::from_data(u, vec![0; 10]).unwrap_err(), MediaError::Unreadable);
    }

    #[test]
    fn time_uses_the_timecode_scale() {
        let mut f = WebMFile::new(&tmp(&video_writer(2))).unwrap();
        assert_eq!(f.time(1500), Time::new(3, 2));
        f.timecode_scale = 3;
        assert_eq!(f.time(10), Time::new(30, 1_000_000_000));
    }

    /// A SimpleBlock with `lacing` flags in a cluster of the given file bytes.
    fn laced_file(flags: u8, lace_header: &[u8], frames: &[&[u8]]) -> WebMFile {
        let w = WebMTestWriter {
            tracks: vec![Track {
                number: 1,
                codec_id: "A_OPUS".into(),
                channels: 2,
                rate: 48_000.0,
                ..Track::default()
            }],
            ..WebMTestWriter::default()
        };
        let mut block = vec![0x81, 0, 0, flags];
        block.extend(lace_header);
        for f in frames {
            block.extend(*f);
        }
        let mut seg = el(&[0x16, 0x54, 0xAE, 0x6B], &{
            let d = w.data();
            // Tracks element body of the writer output: everything after the Info element is the Tracks element.
            let at = d.windows(4).position(|x| x == [0x16, 0x54, 0xAE, 0x6B]).unwrap();
            d[at + 4 + 8..].to_vec()
        });
        let mut cluster = uint(&[0xE7], 0);
        cluster.extend(el(&[0xA3], &block));
        seg.extend(el(&[0x1F, 0x43, 0xB6, 0x75], &cluster));
        let mut out = el(&[0x1A, 0x45, 0xDF, 0xA3], &str(&[0x42, 0x82], "webm"));
        out.extend(el(&[0x18, 0x53, 0x80, 0x67], &seg));
        WebMFile::from_data(PathBuf::from("laced.webm"), out).unwrap()
    }

    #[test]
    fn laced_blocks_yield_one_entry_per_frame() {
        let sizes = |f: &WebMFile| f.blocks.iter().map(|b| (b.ticks, b.size)).collect::<Vec<_>>();
        // Xiph: 3 frames, sizes 2 and 300 (255 + 45) are coded, the last one is the rest.
        let xiph = laced_file(0x02, &[2, 2, 255, 45], &[&[1; 2], &[2; 300], &[3; 4]]);
        assert_eq!(sizes(&xiph), vec![(0, 2), (1, 300), (2, 4)]);
        assert_eq!(xiph.payload(&xiph.blocks[2]), &[3u8; 4][..]);
        // Fixed: 3 equal frames.
        let fixed = laced_file(0x04, &[2], &[&[1; 5], &[2; 5], &[3; 5]]);
        assert_eq!(sizes(&fixed), vec![(0, 5), (1, 5), (2, 5)]);
        // EBML: first size 4 (0x84), then delta +2 (0xBF + 2 = 0xC1 after bias 63 -> 0x80|65).
        let ebml = laced_file(0x06, &[2, 0x84, 0x80 | 65], &[&[1; 4], &[2; 6], &[3; 3]]);
        assert_eq!(sizes(&ebml), vec![(0, 4), (1, 6), (2, 3)]);
    }

    #[test]
    fn ebml_lace_size_rejects_corrupt_values() {
        // 1-byte vint bias is 63: raw 63 is delta 0, raw 70 is +7.
        assert_eq!(Parser::lace_size(100, 70, 1), Some(107));
        assert_eq!(Parser::lace_size(100, 63, 1), Some(100));
        assert_eq!(Parser::lace_size(10, 0, 1), None); // negative
        assert_eq!(Parser::lace_size(10, u64::MAX, 1), None); // unknown size
        assert_eq!(Parser::lace_size(i64::MAX, i64::MAX as u64, 8), None); // overflow
        assert_eq!(Parser::lace_size(1, 5, 9), None);
    }

    #[test]
    fn hostile_sizes_do_not_panic() {
        let d = test_writer::WebMTestWriter { tracks: video_writer(1).tracks, ..WebMTestWriter::default() }.data();
        for cut in 0..d.len() {
            let _ = WebMFile::from_data(PathBuf::from("x"), d[..cut].to_vec());
        }
        let mut bad = d.clone();
        for i in (0..bad.len()).step_by(3) {
            bad[i] = 0xFF;
            let _ = WebMFile::from_data(PathBuf::from("x"), bad.clone());
        }
    }
}
