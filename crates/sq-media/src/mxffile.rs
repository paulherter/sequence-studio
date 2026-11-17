// Swift: MXF/MXFFile.swift
//! A parsed MXF file (SMPTE ST 377-1): OP1a, frame-wrapped essence, as cameras and editors write it.
//! The file is read with positional reads, never mapped; every length is bounds-checked, malformed files return an error
//! instead of panicking.

use crate::media_error::MediaError;
use crate::mxfdemuxer::Built;
use crate::mxfklv::{MxfBytes, MxfFileReader, MxfKlv};
use crate::mxfmetadata::{MxfMetadata, MxfSet, MxfTimecode, MxfTrack, MxfTrackKind, MxfVideoCodec};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

/// One index table segment (ST 377-1 section 11).
#[derive(Clone, Debug, Default)]
pub struct MxfIndexSegment {
    pub start_position: i64,
    pub duration: i64,
    pub edit_unit_byte_count: usize,
    pub index_sid: u32,
    pub body_sid: u32,
    pub temporal_offsets: Vec<i8>,
    pub flags: Vec<u8>,
    pub stream_offsets: Vec<u64>,
}

impl MxfIndexSegment {
    pub fn new(r: &MxfBytes, k: &MxfKlv) -> Option<MxfIndexSegment> {
        let s = MxfSet::new(r, k, 0x10);
        let mut seg = MxfIndexSegment {
            start_position: s.int64(0x3F0C).unwrap_or(0),
            duration: s.int64(0x3F0D).unwrap_or(0),
            edit_unit_byte_count: s.int(0x3F05).unwrap_or(0) as usize,
            index_sid: s.uint(0x3F06).unwrap_or(0) as u32,
            body_sid: s.uint(0x3F07).unwrap_or(0) as u32,
            ..MxfIndexSegment::default()
        };
        if seg.start_position < 0 || seg.duration < 0 {
            return None;
        }
        if let Some(a) = s.items.get(&0x3F0A).filter(|a| a.len() >= 8)
            && let (Some(n), Some(len)) = (r.u32(a.start), r.u32(a.start + 4))
            && len >= 11
        {
            let count = (n as usize).min((a.len() - 8) / len as usize);
            for i in 0..count {
                let o = a.start + 8 + i * len as usize;
                let (Some(t), Some(f), Some(so)) = (r.u8(o), r.u8(o + 2), r.u64(o + 3)) else { break };
                seg.temporal_offsets.push(t as i8);
                seg.flags.push(f);
                seg.stream_offsets.push(so);
            }
        }
        Some(seg)
    }
}

/// A partition pack and what follows it.
#[derive(Clone, Debug, Default)]
pub struct MxfPartition {
    pub offset: usize,
    /// 2 header, 3 body, 4 footer.
    pub kind: u8,
    /// Open partitions (status 1 and 3) may carry unfinished metadata.
    pub is_open: bool,
    pub previous: usize,
    pub footer: usize,
    pub header_byte_count: usize,
    pub index_byte_count: usize,
    pub index_sid: u32,
    pub body_sid: u32,
    pub body_offset: u64,
    pub pack_end: usize,
    /// First essence or system item KLV of this partition, None when it has none.
    pub essence_start: Option<usize>,
    pub essence_end: usize,
    /// Primer pack and metadata sets.
    pub metadata: Option<Range<usize>>,
}

/// What every open instance of one file shares through the cached parse (`open`, keyed by path, size and
/// modification date): the sample index a demuxer built, so thumbnails and color detection do not sort the
/// index or scan the stream again.
#[derive(Default)]
pub struct Shared {
    pub built: Mutex<Option<Built>>,
    /// How often a demuxer built the sample index of this file (tests).
    pub index_builds: Mutex<usize>,
}

/// One essence element of an edit unit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Element {
    pub track: u32,
    pub range: Range<usize>,
}

/// A parsed MXF file.
pub struct MxfFile {
    pub path: PathBuf,
    pub bytes: MxfBytes,
    /// Picture, sound and data tracks of the file package.
    pub tracks: Vec<MxfTrack>,
    pub timecode: Option<MxfTimecode>,
    /// Bytes before the header partition (run-in).
    pub run_in: usize,
    pub partition_count: usize,
    /// True when the edit units come from the index table, false when the essence was scanned (no usable index:
    /// file still being written, truncated, or a broken index).
    pub uses_index_table: bool,
    /// File offset of each edit unit (content package), in stored order.
    pub unit_offsets: Vec<usize>,
    /// Per edit unit from the index table: temporal offset and flags. Empty when the index does not have them.
    pub temporal_offsets: Vec<i8>,
    pub flags: Vec<u8>,
    pub shared: Arc<Shared>,
}

/// Parses without an open file, least recently used last.
// Ownership: the cache is the one global the Swift code has (a `Mutex` around the list); it holds parses without a file.
static CACHE: Mutex<Vec<(String, MxfFile)>> = Mutex::new(Vec::new());
pub(crate) const CACHE_LIMIT: usize = 32;

fn lock_cache() -> std::sync::MutexGuard<'static, Vec<(String, MxfFile)>> {
    CACHE.lock().unwrap_or_else(PoisonError::into_inner)
}

fn cache_key(path: &Path, r: &MxfFileReader) -> String {
    format!("{}|{}|{}", path.display(), r.size, r.modified)
}

/// Index table joined into one table.
#[derive(Default)]
struct Table {
    offsets: Vec<u64>,
    temporal: Vec<i8>,
    flags: Vec<u8>,
    cbr: usize,
    duration: i64,
    body_sid: u32,
}

/// Edit unit file offsets found through the index table.
pub struct Units {
    pub offsets: Vec<usize>,
    pub temporal: Vec<i8>,
    pub flags: Vec<u8>,
}

impl MxfFile {
    pub fn unit_count(&self) -> usize {
        self.unit_offsets.len()
    }

    pub fn video_track(&self) -> Option<&MxfTrack> {
        self.tracks.iter().find(|t| t.kind == MxfTrackKind::Picture)
    }

    pub fn sound_tracks(&self) -> Vec<&MxfTrack> {
        self.tracks.iter().filter(|t| t.kind == MxfTrackKind::Sound).collect()
    }

    // MARK: opening

    /// True for a file that starts with an MXF partition pack; a run-in (up to 64 KB) is only searched for `.mxf`.
    pub fn is_mxf(path: &Path) -> bool {
        use std::io::Read;
        let Ok(h) = std::fs::File::open(path) else { return false };
        let wide = path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("mxf"));
        let want: u64 = if wide { 65_536 + 16 } else { 16 };
        let mut d = Vec::new();
        if h.take(want).read_to_end(&mut d).is_err() || d.len() < 16 {
            return false;
        }
        Self::header_offset(&MxfBytes::new(d), if wide { 65_536 } else { 0 }).is_some()
    }

    pub(crate) fn header_offset(r: &MxfBytes, limit: usize) -> Option<usize> {
        const PREFIX: [u8; 11] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02];
        r.with_bytes(0..r.count().min(limit + 16), |p| {
            let mut i = 0;
            while i + 16 <= p.len() {
                if p[i] == 0x06
                    && p[i + 1] == 0x0E
                    && (2..PREFIX.len()).all(|j| p[i + j] == PREFIX[j])
                    && p[i + 13] == 0x02
                {
                    return Some(i);
                }
                i += 1;
            }
            None
        })
        .flatten()
    }

    /// Opens `path` with its own file descriptor (closed when the returned file is released). The parse is cached
    /// by path, size and modification date; the cache itself keeps no file open, so a card can be ejected once
    /// nothing reads from it.
    pub fn open(path: &Path) -> Result<MxfFile, MediaError> {
        let reader = Arc::new(MxfFileReader::open(path).ok_or(MediaError::Unreadable)?);
        let key = cache_key(path, &reader);
        let hit = {
            let mut c = lock_cache();
            c.iter().position(|e| e.0 == key).map(|i| {
                let e = c.remove(i);
                let parse = e.1.with_bytes(MxfBytes::detached(e.1.bytes.count()));
                c.push(e);
                parse
            })
        };
        if let Some(parse) = hit {
            return Ok(parse.with_bytes(MxfBytes::from_reader(reader)));
        }
        let f = MxfFile::from_bytes(MxfBytes::from_reader(reader), path)?;
        let parse = f.with_bytes(MxfBytes::detached(f.bytes.count()));
        let mut c = lock_cache();
        c.retain(|e| e.0 != key);
        c.push((key, parse));
        if c.len() > CACHE_LIMIT {
            let extra = c.len() - CACHE_LIMIT;
            c.drain(..extra);
        }
        Ok(f)
    }

    /// The cached parse of `path` (it has no open file), None when there is none. Does not count as a use.
    pub fn cached_parse(path: &Path) -> Option<MxfFile> {
        let reader = MxfFileReader::open(path)?;
        let key = cache_key(path, &reader);
        lock_cache().iter().find(|e| e.0 == key).map(|e| e.1.with_bytes(MxfBytes::detached(e.1.bytes.count())))
    }

    /// The parse over other bytes: an open file for a cached parse, or no file for the cache.
    fn with_bytes(&self, bytes: MxfBytes) -> MxfFile {
        MxfFile {
            path: self.path.clone(),
            bytes,
            tracks: self.tracks.clone(),
            timecode: self.timecode,
            run_in: self.run_in,
            partition_count: self.partition_count,
            uses_index_table: self.uses_index_table,
            unit_offsets: self.unit_offsets.clone(),
            temporal_offsets: self.temporal_offsets.clone(),
            flags: self.flags.clone(),
            shared: Arc::clone(&self.shared),
        }
    }

    /// Parses `path` without the cache. Positional reads, no memory map: MXF comes from camera cards, and a pulled card
    /// or a file replaced while it is copied must end in an error.
    pub fn new(path: &Path) -> Result<MxfFile, MediaError> {
        let reader = MxfFileReader::open(path).ok_or(MediaError::Unreadable)?;
        MxfFile::from_bytes(MxfBytes::from_reader(Arc::new(reader)), path)
    }

    /// Parses data in memory.
    pub fn from_data(data: Vec<u8>, path: &Path) -> Result<MxfFile, MediaError> {
        MxfFile::from_bytes(MxfBytes::new(data), path)
    }

    pub(crate) fn from_bytes(r: MxfBytes, path: &Path) -> Result<MxfFile, MediaError> {
        let header = match Self::header_offset(&r, 65_536) {
            Some(h) if r.count() >= 64 => h,
            _ => return Err(MediaError::Unreadable),
        };
        let mut parts = Self::partitions(&r, header);
        if parts.is_empty() {
            return Err(MediaError::Unreadable);
        }
        let mut segments: Vec<MxfIndexSegment> = Vec::new();
        Self::walk(&mut parts, &r, &mut segments);
        let partition_count = parts.len();

        // Metadata: the header partition's, unless it is open or has no durations and the footer repeats it.
        let mut meta =
            parts.first().and_then(|p| p.metadata.clone()).map(|m| MxfMetadata::parse(&r, m)).unwrap_or_default();
        let unfinished = parts[0].is_open || meta.tracks.is_empty() || meta.tracks.iter().any(|t| t.duration < 0);
        if unfinished && let Some(region) = parts.iter().skip(1).rev().find_map(|p| p.metadata.clone()) {
            let m = MxfMetadata::parse(&r, region);
            if !m.tracks.is_empty() {
                meta = m;
            }
        }
        let tracks = meta.tracks;
        let timecode = meta.timecode;
        if tracks.is_empty() {
            return Err(MediaError::Unreadable);
        }

        let (unit_offsets, temporal_offsets, flags, uses_index_table);
        if let Some(t) = Self::units_from_index(&r, &parts, &segments, &tracks) {
            unit_offsets = t.offsets;
            temporal_offsets = t.temporal;
            flags = t.flags;
            uses_index_table = true;
        } else {
            let offsets = Self::scan(&r, header);
            // Index entries stay useful when they cover what the scan found (a complete index, broken offsets).
            match Self::table(&segments) {
                Some(table) if table.cbr == 0 && table.temporal.len() >= offsets.len() && !offsets.is_empty() => {
                    temporal_offsets = table.temporal[..offsets.len()].to_vec();
                    flags = table.flags[..offsets.len()].to_vec();
                }
                _ => {
                    temporal_offsets = vec![];
                    flags = vec![];
                }
            }
            unit_offsets = offsets;
            uses_index_table = false;
        }
        Ok(MxfFile {
            path: path.to_path_buf(),
            bytes: r,
            tracks,
            timecode,
            run_in: header,
            partition_count,
            uses_index_table,
            unit_offsets,
            temporal_offsets,
            flags,
            shared: Arc::new(Shared::default()),
        })
    }

    // MARK: partitions

    pub(crate) fn partition(r: &MxfBytes, o: usize, run_in: usize) -> Option<MxfPartition> {
        let k = r.klv(o)?;
        let kind = k.key.partition_kind()?;
        if k.length < 64 || !r.fits(&k) {
            return None;
        }
        let v = k.value_offset;
        let mut p = MxfPartition { offset: o, kind, pack_end: k.end(), ..MxfPartition::default() };
        p.is_open = k.key.byte(14) == 1 || k.key.byte(14) == 3;
        let (prev, foot, hbc) = (r.position(v + 16)?, r.position(v + 24)?, r.position(v + 32)?);
        let (ibc, isid, bo, bsid) = (r.position(v + 40)?, r.u32(v + 48)?, r.u64(v + 52)?, r.u32(v + 60)?);
        p.previous = if prev > 0 { run_in.wrapping_add(prev) } else { 0 };
        p.footer = if foot > 0 { run_in.wrapping_add(foot) } else { 0 };
        p.header_byte_count = hbc;
        p.index_byte_count = ibc;
        p.index_sid = isid;
        p.body_offset = bo;
        p.body_sid = bsid;
        Some(p)
    }

    /// Partition packs by the random index pack, the footer's previous-partition chain, and (in `walk`) by meeting them.
    fn partitions(r: &MxfBytes, header: usize) -> Vec<MxfPartition> {
        let mut offsets: BTreeSet<usize> = BTreeSet::from([header]);
        if let Some(total) = r.count().checked_sub(4).and_then(|o| r.u32(o))
            && total >= 33
            && total as usize <= r.count() - header
        {
            let o = r.count() - total as usize;
            if let Some(k) = r.klv(o)
                && k.key.is_random_index_pack()
                && r.fits(&k)
            {
                let mut p = k.value_offset;
                while p + 12 <= k.end() - 4 && offsets.len() < 100_000 {
                    let Some(off) = r.position(p + 4) else { break };
                    if off < r.count() - header {
                        offsets.insert(header + off);
                    }
                    p += 12;
                }
            }
        }
        if let Some(hp) = Self::partition(r, header, header)
            && hp.footer > header
        {
            let (mut o, mut n) = (hp.footer, 0);
            while o > header && n < 100_000 {
                let Some(p) = Self::partition(r, o, header) else { break };
                offsets.insert(o);
                n += 1;
                if p.previous <= header || p.previous >= o {
                    break;
                }
                o = p.previous;
            }
        }
        offsets.into_iter().filter_map(|o| Self::partition(r, o, header)).collect()
    }

    /// Walks what follows each partition pack up to its essence: metadata region, index segments, essence start.
    /// Partitions met on the way that nothing pointed to are added.
    fn walk(parts: &mut Vec<MxfPartition>, r: &MxfBytes, segments: &mut Vec<MxfIndexSegment>) {
        let mut i = 0;
        let mut known: HashSet<usize> = parts.iter().map(|p| p.offset).collect();
        let run_in = parts[0].offset;
        while i < parts.len() && parts.len() < 100_000 {
            let mut p = parts[i].pack_end;
            let mut steps = 0;
            let mut meta_start: Option<usize> = None;
            let mut meta_end = 0;
            while steps < 2_000_000 {
                let Some(k) = r.klv(p) else { break };
                steps += 1;
                let key = k.key;
                if key.is_partition_pack() {
                    if !known.contains(&p)
                        && let Some(np) = Self::partition(r, p, run_in)
                    {
                        known.insert(p);
                        parts.push(np);
                        parts.sort_by_key(|x| x.offset);
                    }
                    break;
                }
                if key.is_random_index_pack() {
                    break;
                }
                if key.is_essence_element() || key.is_system_item() {
                    parts[i].essence_start = Some(p);
                    break;
                }
                if !r.fits(&k) || k.end() <= p {
                    break;
                }
                if key.is_index_segment() {
                    if let Some(s) = MxfIndexSegment::new(r, &k) {
                        segments.push(s);
                    }
                } else if key.is_primer() || key.metadata_set_kind().is_some() {
                    if meta_start.is_none() {
                        meta_start = Some(p);
                    }
                    meta_end = k.end();
                }
                p = k.end();
            }
            if let Some(s) = meta_start {
                parts[i].metadata = Some(s..meta_end);
            }
            i += 1;
        }
        for i in 0..parts.len() {
            parts[i].essence_end = if i + 1 < parts.len() { parts[i + 1].offset } else { r.count() };
            // Essence that starts past the next partition pack (a corrupt length before it) cannot be placed.
            if let Some(s) = parts[i].essence_start
                && s >= parts[i].essence_end
            {
                parts[i].essence_start = None;
            }
        }
    }

    // MARK: edit units

    /// The segments joined into one table in edit unit order; None when there is no usable index.
    fn table(segments: &[MxfIndexSegment]) -> Option<Table> {
        // Index tables are often repeated (footer and body): for one start position keep the longest segment.
        let mut by_start: BTreeMap<i64, &MxfIndexSegment> = BTreeMap::new();
        for s in segments.iter().filter(|s| !s.stream_offsets.is_empty()) {
            if let Some(old) = by_start.get(&s.start_position)
                && old.stream_offsets.len() >= s.stream_offsets.len()
            {
                continue;
            }
            by_start.insert(s.start_position, s);
        }
        let mut t = Table::default();
        if by_start.is_empty() {
            let cbr = segments.iter().find(|s| s.edit_unit_byte_count > 0)?;
            t.cbr = cbr.edit_unit_byte_count;
            t.duration = cbr.duration;
            t.body_sid = cbr.body_sid;
            return Some(t);
        }
        for (&start, s) in &by_start {
            let have = t.offsets.len() as i64;
            if start > have {
                break; // a gap: what follows cannot be placed
            }
            let skip = (have - start) as usize;
            if skip >= s.stream_offsets.len() {
                continue;
            }
            t.offsets.extend_from_slice(&s.stream_offsets[skip..]);
            t.temporal.extend_from_slice(&s.temporal_offsets[skip..]);
            t.flags.extend_from_slice(&s.flags[skip..]);
            t.body_sid = s.body_sid;
        }
        (!t.offsets.is_empty()).then_some(t)
    }

    /// Edit unit file offsets by index table arithmetic (no essence is read), checked against a few real positions.
    pub(crate) fn units_from_index(
        r: &MxfBytes,
        parts: &[MxfPartition],
        segments: &[MxfIndexSegment],
        tracks: &[MxfTrack],
    ) -> Option<Units> {
        let t = Self::table(segments)?;
        let wanted = t.body_sid;
        // A partition whose essence starts past its end makes every offset behind it wrong: the scan takes over.
        if parts.iter().any(|p| p.essence_start.is_some_and(|s| s >= p.essence_end)) {
            return None;
        }
        let mut bodies: Vec<&MxfPartition> =
            parts.iter().filter(|p| p.essence_start.is_some() && (wanted == 0 || p.body_sid == wanted)).collect();
        if bodies.is_empty() {
            bodies = parts.iter().filter(|p| p.essence_start.is_some()).collect();
        }
        if bodies.is_empty() {
            return None;
        }
        bodies.sort_by_key(|b| b.body_offset);
        let mut bi = 0;
        let mut file_offset = |s: u64| -> Option<usize> {
            if bodies[bi].body_offset > s {
                bi = 0;
            }
            while bi + 1 < bodies.len() && bodies[bi + 1].body_offset <= s {
                bi += 1;
            }
            let b = bodies[bi];
            let start = b.essence_start?;
            if s < b.body_offset || b.essence_end <= start || s - b.body_offset >= (b.essence_end - start) as u64 {
                return None;
            }
            Some(start + (s - b.body_offset) as usize)
        };
        let is_content = |k: &MxfKlv| (k.key.is_essence_element() || k.key.is_system_item()) && r.fits(k);
        let mut offsets: Vec<usize> = Vec::new();
        let total: usize =
            bodies.iter().map(|b| b.essence_end.saturating_sub(b.essence_start.unwrap_or(b.essence_end))).sum();
        if let Some(by_bytes) = total.checked_div(t.cbr) {
            let by_bytes = by_bytes as i64;
            let mut count =
                if t.duration > 0 { t.duration } else { tracks.iter().map(|t| t.duration).max().unwrap_or(-1) };
            if count <= 0 {
                count = by_bytes;
            }
            count = count.min(by_bytes + 1).clamp(0, 50_000_000);
            // The first two units must be content packages before the table is filled: clip-wrapped sound with a
            // constant byte count would otherwise give millions of offsets inside one element.
            for i in 0..2.min(count as usize) {
                let ok = file_offset(i as u64 * t.cbr as u64).and_then(|o| r.klv(o)).is_some_and(|k| is_content(&k));
                if !ok {
                    return None;
                }
            }
            for i in 0..count as usize {
                let Some(o) = file_offset(i as u64 * t.cbr as u64) else { break };
                offsets.push(o);
            }
        } else {
            for &s in &t.offsets {
                offsets.push(file_offset(s)?);
            }
        }
        if offsets.is_empty() {
            return None;
        }
        // The index must land on content packages: first, second, middle and last unit.
        let n = offsets.len();
        for i in BTreeSet::from([0, 1.min(n - 1), n / 2, n - 1]) {
            if !r.klv(offsets[i]).is_some_and(|k| is_content(&k)) {
                return None;
            }
        }
        let cbr = t.cbr > 0;
        Some(Units {
            offsets,
            temporal: if cbr { vec![] } else { t.temporal },
            flags: if cbr { vec![] } else { t.flags },
        })
    }

    /// Finds the content packages by walking every KLV: for files without a usable index.
    fn scan(r: &MxfBytes, start: usize) -> Vec<usize> {
        #[derive(Default)]
        struct State {
            offsets: Vec<usize>,
            seen: Vec<u32>,
            unit: Option<usize>,
            has_picture: bool,
        }
        impl State {
            fn close(&mut self) {
                if let Some(u) = self.unit
                    && !self.seen.is_empty()
                {
                    self.offsets.push(u);
                }
                self.unit = None;
                self.seen.clear();
                self.has_picture = false;
            }
        }
        let mut st = State::default();
        let mut any_picture = false;
        let mut p = start;
        while let Some(k) = r.klv(p) {
            if k.end() <= p {
                break;
            }
            let key = k.key;
            if key.is_system_item() {
                if st.unit.is_none() || !st.seen.is_empty() {
                    st.close();
                    st.unit = Some(p);
                }
            } else if key.is_essence_element() {
                if !r.fits(&k) {
                    break; // cut off inside this element: the unit is incomplete
                }
                let n = key.track_number();
                if st.unit.is_none() || st.seen.contains(&n) {
                    st.close();
                    st.unit = Some(p);
                }
                st.seen.push(n);
                let item = (n >> 24) as u8;
                if item == 0x05 || item == 0x15 {
                    st.has_picture = true;
                    any_picture = true;
                }
            } else if key.is_partition_pack() || key.is_random_index_pack() {
                st.close();
            }
            if !r.fits(&k) {
                break;
            }
            p = k.end();
        }
        // The last unit counts when nothing of it is missing as far as one can tell.
        if !any_picture || st.has_picture {
            st.close();
        }
        st.offsets
    }

    // MARK: essence access

    /// The essence elements of edit unit `u` (walked on demand).
    pub(crate) fn elements(&self, u: usize) -> Vec<Element> {
        let Some(&start) = self.unit_offsets.get(u) else { return vec![] };
        let limit = match self.unit_offsets.get(u + 1) {
            Some(&next) if next > start => next,
            _ => self.bytes.count(),
        };
        let mut out: Vec<Element> = Vec::new();
        let mut p = start;
        while p < limit && out.len() < 256 {
            let Some(k) = self.bytes.klv(p) else { break };
            if k.end() <= p {
                break;
            }
            let key = k.key;
            if key.is_system_item() {
                if !out.is_empty() {
                    break;
                }
            } else if key.is_essence_element() {
                let n = key.track_number();
                // An element ends before the next edit unit: a corrupt length must not make a reader allocate and
                // read up to the end of the file.
                if !self.bytes.fits(&k) || k.end() > limit || out.iter().any(|e| e.track == n) {
                    break;
                }
                out.push(Element { track: n, range: k.value_offset..k.end() });
            } else if !key.is_fill() {
                break;
            }
            if !self.bytes.fits(&k) {
                break;
            }
            p = k.end();
        }
        out
    }

    /// The picture element of edit unit `u`.
    pub fn picture_range(&self, u: usize) -> Option<Range<usize>> {
        let all: Vec<Element> =
            self.elements(u).into_iter().filter(|e| matches!((e.track >> 24) as u8, 0x05 | 0x15)).collect();
        if let Some(n) = self.video_track().map(|t| t.number).filter(|&n| n != 0)
            && let Some(e) = all.iter().find(|e| e.track == n)
        {
            return Some(e.range.clone());
        }
        all.first().map(|e| e.range.clone())
    }

    pub fn video_codec(&self) -> Option<MxfVideoCodec> {
        let v = self.video_track()?;
        match &v.picture {
            Some(p) => MxfVideoCodec::identify(p.coding, p.container),
            None => MxfVideoCodec::identify(None, None),
        }
    }
}

/// Builds MXF files in memory for tests (OP1a, frame-wrapped): header partition with metadata, body partitions with
/// content packages, footer with an index table, random index pack. No footage is needed. Port of the Swift
/// `MXFFixture` (the H.264 test stream writer is not needed here: picture payloads are opaque bytes).
#[cfg(test)]
pub(crate) mod fixture {
    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Index {
        Vbr,
        Cbr,
        None,
    }

    #[derive(Clone)]
    pub(crate) struct MxfFixture {
        pub run_in: usize,
        pub edit_rate: (i64, i64),
        /// Picture element payloads in stored order.
        pub frames: Vec<Vec<u8>>,
        /// Index entry fields per edit unit; defaults: 0 and 0x80 (key frame).
        pub temporal_offsets: Option<Vec<i8>>,
        pub flags: Option<Vec<u8>>,
        pub index: Index,
        /// Entries per index table segment.
        pub segment_size: usize,
        pub has_footer: bool,
        pub has_rip: bool,
        pub has_system_item: bool,
        /// Body partitions the content packages are spread over; 0 puts the essence into the header partition.
        pub body_partitions: usize,
        pub linked_track_ids: bool,
        pub coding: Option<Vec<u8>>,
        pub picture_container: Vec<u8>,
        pub width: i64,
        pub height: i64,
        /// Frame layout of the picture descriptor (0 full frame, 1 separate fields, 3 mixed fields, 4 segmented frame).
        pub frame_layout: u8,
        pub field_dominance: Option<u8>,
        pub video_line_map: Option<(i64, i64)>,
        pub depth: i64,
        pub h_sub: i64,
        pub v_sub: i64,
        pub transfer: Option<Vec<u8>>,
        pub primaries: Option<Vec<u8>>,
        pub equations: Option<Vec<u8>>,
        /// Mono sound tracks.
        pub audio_tracks: usize,
        pub audio_bits: i64,
        pub audio_big_endian: bool,
        pub audio_compression: Option<Vec<u8>>,
        pub audio_rate: i64,
        pub samples_per_unit: Vec<usize>,
        /// Element type byte of the sound element keys (3 wave, 0x10 D-10 AES3).
        pub sound_element_type: u8,
        pub timecode: Option<(i64, i64, bool)>,
    }

    pub(crate) const AVC_INTRA_CODING: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02, 0x01, 0x32, 0x31, 0x01];
    pub(crate) const AVC_LONG_CODING: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02, 0x01, 0x31, 0x60, 0x01];
    pub(crate) const AVC_CONTAINER: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x10, 0x60, 0x01];
    const WAVE_CONTAINER: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x06, 0x01, 0x00];
    const BIG_ENDIAN_PCM: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x07, 0x04, 0x02, 0x02, 0x01, 0x7E, 0x00, 0x00, 0x00];
    const PICTURE_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x15, 0x01, 0x05, 0x00];
    const SYSTEM_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x04, 0x01, 0x01, 0x00];
    const FILL_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02, 0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00];
    const INDEX_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x10, 0x01, 0x00];
    const OP1A: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x01, 0x09, 0x00];

    impl Default for MxfFixture {
        fn default() -> Self {
            MxfFixture {
                run_in: 0,
                edit_rate: (25, 1),
                frames: vec![],
                temporal_offsets: None,
                flags: None,
                index: Index::Vbr,
                segment_size: 1000,
                has_footer: true,
                has_rip: true,
                has_system_item: true,
                body_partitions: 1,
                linked_track_ids: true,
                coding: Some(AVC_INTRA_CODING.to_vec()),
                picture_container: AVC_CONTAINER.to_vec(),
                width: 1920,
                height: 1080,
                frame_layout: 0,
                field_dominance: None,
                video_line_map: None,
                depth: 10,
                h_sub: 2,
                v_sub: 1,
                transfer: Some(label(0x01, 0x02)),
                primaries: Some(label(0x03, 0x03)),
                equations: Some(label(0x02, 0x02)),
                audio_tracks: 0,
                audio_bits: 24,
                audio_big_endian: false,
                audio_compression: None,
                audio_rate: 48_000,
                samples_per_unit: vec![1920],
                sound_element_type: 0x03,
                timecode: Some((90_000, 25, false)),
            }
        }
    }

    /// Color label `04 01 01 01 kind value`.
    pub(crate) fn label(kind: u8, value: u8) -> Vec<u8> {
        vec![0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x04, 0x01, 0x01, 0x01, kind, value, 0x00, 0x00]
    }

    /// Distinct opaque picture payloads (the Swift tests use tiny H.264 streams; only the bytes matter here).
    pub(crate) fn small_frames(n: usize) -> Vec<Vec<u8>> {
        (0..n).map(|i| (0..400 + 37 * i).map(|k| (k * 7 + i * 13) as u8).collect()).collect()
    }

    fn partition_key(kind: u8, status: u8) -> Vec<u8> {
        vec![0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, kind, status, 0x00]
    }

    fn sound_key(count: usize, ty: u8, number: usize) -> Vec<u8> {
        vec![
            0x06,
            0x0E,
            0x2B,
            0x34,
            0x01,
            0x02,
            0x01,
            0x01,
            0x0D,
            0x01,
            0x03,
            0x01,
            0x16,
            count as u8,
            ty,
            number as u8,
        ]
    }

    /// The sample test audio holds: channel `c`, sample `n` (a signed value of `bits` bits).
    pub(crate) fn sample(c: i64, n: i64, bits: i64) -> i32 {
        let span = 1i64 << (bits - 1);
        ((n * 7_919 + c * 104_729 + 17) % (2 * span - 2) - span + 1) as i32
    }

    pub(crate) fn be(v: u64, n: usize) -> Vec<u8> {
        (0..n).map(|i| v.checked_shr(8 * (n - 1 - i) as u32).unwrap_or(0) as u8).collect()
    }

    pub(crate) fn ber(n: usize, long: usize) -> Vec<u8> {
        if long == 0 && n < 0x80 {
            vec![n as u8]
        } else {
            [vec![0x80 | long.max(1) as u8], be(n as u64, long.max(1))].concat()
        }
    }

    fn klv(key: &[u8], value: &[u8], long: usize) -> Vec<u8> {
        [key.to_vec(), ber(value.len(), long), value.to_vec()].concat()
    }

    fn item(tag: u16, value: &[u8]) -> Vec<u8> {
        [be(u64::from(tag), 2), be(value.len() as u64, 2), value.to_vec()].concat()
    }

    fn set(kind: u8, items: &[Vec<u8>]) -> Vec<u8> {
        klv(
            &[0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, kind, 0x00],
            &items.concat(),
            4,
        )
    }

    fn uid(n: i64) -> Vec<u8> {
        [vec![0xAA, 0xBB], be(n as u64, 14)].concat()
    }

    fn refs(ids: &[i64]) -> Vec<u8> {
        [be(ids.len() as u64, 4), be(16, 4), ids.iter().flat_map(|&i| uid(i)).collect()].concat()
    }

    fn rational(n: i64, d: i64) -> Vec<u8> {
        [be(u64::from(n as i32 as u32), 4), be(u64::from(d as i32 as u32), 4)].concat()
    }

    struct Meta {
        sets: Vec<Vec<u8>>,
        next: i64,
        duration: Vec<u8>,
        rate: Vec<u8>,
    }

    impl Meta {
        fn id(&mut self) -> i64 {
            self.next += 1;
            self.next
        }

        /// A track with a sequence holding one component.
        fn track(
            &mut self,
            track_id: i64,
            number: u32,
            definition: u8,
            component: impl Fn(i64, &[u8]) -> Vec<u8>,
        ) -> i64 {
            let (t, s, c) = (self.id(), self.id(), self.id());
            let dd = vec![
                0x06,
                0x0E,
                0x2B,
                0x34,
                0x04,
                0x01,
                0x01,
                0x01,
                0x01,
                0x03,
                0x02,
                if definition == 0 { 0x01 } else { 0x02 },
                if definition == 0 { 0x01 } else { definition },
                0x00,
                0x00,
                0x00,
            ];
            self.sets.push(set(
                0x3B,
                &[
                    item(0x3C0A, &uid(t)),
                    item(0x4801, &be(track_id as u64, 4)),
                    item(0x4804, &be(u64::from(number), 4)),
                    item(0x4B01, &self.rate),
                    item(0x4B02, &be(0, 8)),
                    item(0x4803, &uid(s)),
                ],
            ));
            self.sets.push(set(
                0x0F,
                &[item(0x3C0A, &uid(s)), item(0x0201, &dd), item(0x0202, &self.duration), item(0x1001, &refs(&[c]))],
            ));
            let comp = component(c, &self.duration);
            self.sets.push(comp);
            t
        }

        fn timecode_track(&mut self, track_id: i64, timecode: Option<(i64, i64, bool)>) -> Option<i64> {
            let tc = timecode?;
            Some(self.track(track_id, 0, 0, move |c, duration| {
                set(
                    0x14,
                    &[
                        item(0x3C0A, &uid(c)),
                        item(0x0202, duration),
                        item(0x1501, &be(tc.0 as u64, 8)),
                        item(0x1502, &be(tc.1 as u64, 2)),
                        item(0x1503, &[u8::from(tc.2)]),
                    ],
                )
            }))
        }
    }

    fn clip(c: i64, duration: &[u8]) -> Vec<u8> {
        set(0x11, &[item(0x3C0A, &uid(c)), item(0x0202, duration)])
    }

    impl MxfFixture {
        pub(crate) fn picture_track_number(&self) -> u32 {
            0x1501_0500
        }

        fn sound_track_number(&self, i: usize) -> u32 {
            0x1600_0000 | (self.audio_tracks as u32) << 16 | u32::from(self.sound_element_type) << 8 | i as u32
        }

        fn metadata(&self) -> Vec<u8> {
            let mut m = Meta {
                sets: vec![],
                next: 100,
                duration: be(self.frames.len() as u64, 8),
                rate: rational(self.edit_rate.0, self.edit_rate.1),
            };
            let (preface, storage, material, source, multi) = (m.id(), m.id(), m.id(), m.id(), m.id());
            let rate = m.rate.clone();
            let material_tracks: Vec<i64> = m.timecode_track(1, self.timecode).into_iter().collect();
            let mut source_tracks: Vec<i64> = m.timecode_track(1, self.timecode).into_iter().collect();
            let mut descriptors: Vec<i64> = vec![];
            if !self.frames.is_empty() {
                source_tracks.push(m.track(2, self.picture_track_number(), 1, clip));
                let d = m.id();
                let mut items = vec![
                    item(0x3C0A, &uid(d)),
                    item(0x3001, &rate),
                    item(0x3004, &self.picture_container),
                    item(0x3202, &be(self.height as u64, 4)),
                    item(0x3203, &be(self.width as u64, 4)),
                    item(0x3208, &be(self.height as u64, 4)),
                    item(0x3209, &be(self.width as u64, 4)),
                    item(0x320C, &[self.frame_layout]),
                    item(0x320E, &rational(16, 9)),
                    item(0x3301, &be(self.depth as u64, 4)),
                    item(0x3302, &be(self.h_sub as u64, 4)),
                    item(0x3308, &be(self.v_sub as u64, 4)),
                ];
                if self.linked_track_ids {
                    items.push(item(0x3006, &be(2, 4)));
                }
                if let Some(f) = self.field_dominance {
                    items.push(item(0x3212, &[f]));
                }
                if let Some(l) = self.video_line_map {
                    items.push(item(0x320D, &[be(2, 4), be(4, 4), be(l.0 as u64, 4), be(l.1 as u64, 4)].concat()));
                }
                if let Some(c) = &self.coding {
                    items.push(item(0x3201, c));
                }
                if let Some(c) = &self.transfer {
                    items.push(item(0x3210, c));
                }
                if let Some(c) = &self.primaries {
                    items.push(item(0x3219, c));
                }
                if let Some(c) = &self.equations {
                    items.push(item(0x321A, c));
                }
                m.sets.push(set(0x28, &items));
                descriptors.push(d);
            }
            let bytes = (self.audio_bits + 7) / 8;
            for i in 0..self.audio_tracks {
                source_tracks.push(m.track(3 + i as i64, self.sound_track_number(i), 2, clip));
                let d = m.id();
                let mut items = vec![
                    item(0x3C0A, &uid(d)),
                    item(0x3001, &rate),
                    item(0x3004, &WAVE_CONTAINER),
                    item(0x3D03, &rational(self.audio_rate, 1)),
                    item(0x3D07, &be(1, 4)),
                    item(0x3D01, &be(self.audio_bits as u64, 4)),
                    item(0x3D0A, &be(bytes as u64, 2)),
                ];
                if self.linked_track_ids {
                    items.push(item(0x3006, &be(3 + i as u64, 4)));
                }
                let compression =
                    self.audio_compression.clone().or(self.audio_big_endian.then(|| BIG_ENDIAN_PCM.to_vec()));
                if let Some(c) = compression {
                    items.push(item(0x3D06, &c));
                }
                m.sets.push(set(0x48, &items));
                descriptors.push(d);
            }
            let mut out =
                klv(&partition_key(0x05, 0x01), &[be(1, 4), be(18, 4), be(0x3C0A, 2), vec![0u8; 16]].concat(), 4);
            out.extend(set(0x2F, &[item(0x3C0A, &uid(preface)), item(0x3B03, &uid(storage))]));
            out.extend(set(0x18, &[item(0x3C0A, &uid(storage)), item(0x1901, &refs(&[material, source]))]));
            out.extend(set(0x36, &[item(0x3C0A, &uid(material)), item(0x4403, &refs(&material_tracks))]));
            out.extend(set(
                0x37,
                &[item(0x3C0A, &uid(source)), item(0x4403, &refs(&source_tracks)), item(0x4701, &uid(multi))],
            ));
            out.extend(set(0x44, &[item(0x3C0A, &uid(multi)), item(0x3001, &rate), item(0x3F01, &refs(&descriptors))]));
            out.extend(m.sets.concat());
            out
        }

        /// One content package: system item, picture, sound elements, fill.
        fn unit(&self, u: usize, sample_start: usize, samples: usize, pad_to: usize) -> Vec<u8> {
            let mut out: Vec<u8> = vec![];
            if self.has_system_item {
                out.extend(klv(&SYSTEM_KEY, &[0x5A; 57], 0));
            }
            if let Some(f) = self.frames.get(u) {
                out.extend(klv(&PICTURE_KEY, f, 4));
            }
            let bytes = ((self.audio_bits + 7) / 8) as usize;
            for c in 0..self.audio_tracks {
                let mut pcm: Vec<u8> = Vec::with_capacity(samples * bytes);
                for n in sample_start..sample_start + samples {
                    let v = sample(c as i64, n as i64, self.audio_bits) as u32;
                    let mut le: Vec<u8> = (0..bytes).map(|k| (v >> (8 * k)) as u8).collect();
                    if self.audio_big_endian {
                        le.reverse();
                    }
                    pcm.extend(le);
                }
                out.extend(klv(&sound_key(self.audio_tracks, self.sound_element_type, c), &pcm, 4));
            }
            let fill = (pad_to as i64 - out.len() as i64 - 20).max(37) as usize;
            out.extend(klv(&FILL_KEY, &vec![0u8; fill], 4));
            out
        }

        pub(crate) fn build(&self) -> Vec<u8> {
            /// Fields of one partition pack.
            struct Pack {
                kind: u8,
                status: u8,
                header_bytes: usize,
                index_bytes: usize,
                index_sid: u32,
                body_offset: usize,
                body_sid: u32,
            }
            impl Pack {
                fn new(kind: u8) -> Pack {
                    Pack {
                        kind,
                        status: 0x04,
                        header_bytes: 0,
                        index_bytes: 0,
                        index_sid: 0,
                        body_offset: 0,
                        body_sid: 0,
                    }
                }
            }
            struct Out {
                out: Vec<u8>,
                run_in: usize,
                partition_offsets: Vec<(u32, usize)>,
                packs: Vec<usize>, // value offsets of the partition packs, for patching
            }
            impl Out {
                fn pack(&mut self, container: &[u8], a: Pack) {
                    let Pack { kind, status, header_bytes, index_bytes, index_sid, body_offset, body_sid } = a;
                    let here = self.out.len() - self.run_in;
                    let previous = self.partition_offsets.last().map(|p| p.1).unwrap_or(0);
                    self.partition_offsets.push((body_sid, here));
                    let mut v =
                        [be(1, 2), be(3, 2), be(1, 4), be(here as u64, 8), be(previous as u64, 8), be(0, 8)].concat();
                    v.extend(
                        [be(header_bytes as u64, 8), be(index_bytes as u64, 8), be(u64::from(index_sid), 4)].concat(),
                    );
                    v.extend([be(body_offset as u64, 8), be(u64::from(body_sid), 4), OP1A.to_vec()].concat());
                    v.extend([be(1, 4), be(16, 4), container.to_vec()].concat());
                    self.out.extend(partition_key(kind, status));
                    self.out.extend(ber(v.len(), 4));
                    self.packs.push(self.out.len());
                    self.out.extend(v);
                }
            }
            let mut o =
                Out { out: vec![0x11; self.run_in], run_in: self.run_in, partition_offsets: vec![], packs: vec![] };
            let container = self.picture_container.clone();
            let meta = self.metadata();
            let unit_count = self.frames.len().max(if self.audio_tracks > 0 && self.frames.is_empty() {
                self.samples_per_unit.len()
            } else {
                0
            });
            let per_unit = |u: usize| {
                if self.audio_tracks > 0 { self.samples_per_unit[u % self.samples_per_unit.len()] } else { 0 }
            };
            let mut units: Vec<Vec<u8>> = vec![];
            let mut sample_start = 0;
            for u in 0..unit_count {
                let n = per_unit(u);
                units.push(self.unit(u, sample_start, n, 0));
                sample_start += n;
            }
            if self.index == Index::Cbr
                && let Some(longest) = units.iter().map(Vec::len).max()
            {
                sample_start = 0;
                for (u, unit) in units.iter_mut().enumerate() {
                    let n = per_unit(u);
                    *unit = self.unit(u, sample_start, n, longest + 64);
                    sample_start += n;
                }
            }

            let finished = self.has_footer;
            let status = if finished { 0x04 } else { 0x01 };
            o.pack(
                &container,
                Pack {
                    status,
                    header_bytes: meta.len(),
                    body_sid: u32::from(self.body_partitions == 0),
                    ..Pack::new(0x02)
                },
            );
            o.out.extend(&meta);
            let mut stream_offsets: Vec<usize> = vec![];
            let mut stream = 0;
            let groups = self.body_partitions.max(1);
            let per_group = unit_count.div_ceil(groups).max(1);
            for g in 0..groups {
                let slice = &units[(g * per_group).min(unit_count)..((g + 1) * per_group).min(unit_count)];
                if self.body_partitions > 0 {
                    o.pack(&container, Pack { body_offset: stream, body_sid: 1, ..Pack::new(0x03) });
                }
                for u in slice {
                    stream_offsets.push(stream);
                    o.out.extend(u);
                    stream += u.len();
                }
            }

            if self.has_footer {
                let mut segments: Vec<u8> = vec![];
                let rate = rational(self.edit_rate.0, self.edit_rate.1);
                if self.index == Index::Vbr {
                    let mut start = 0;
                    while start < unit_count {
                        let end = unit_count.min(start + self.segment_size);
                        let mut entries = [be((end - start) as u64, 4), be(11, 4)].concat();
                        for u in start..end {
                            let t = self.temporal_offsets.as_ref().map(|t| t[u]).unwrap_or(0);
                            let f = self.flags.as_ref().map(|f| f[u]).unwrap_or(0x80);
                            entries.extend([vec![t as u8, 0, f], be(stream_offsets[u] as u64, 8)].concat());
                        }
                        let items = [
                            item(0x3C0A, &uid(9000 + start as i64)),
                            item(0x3F0B, &rate),
                            item(0x3F0C, &be(start as u64, 8)),
                            item(0x3F0D, &be((end - start) as u64, 8)),
                            item(0x3F05, &be(0, 4)),
                            item(0x3F06, &be(2, 4)),
                            item(0x3F07, &be(1, 4)),
                            item(0x3F08, &[0]),
                            item(0x3F0A, &entries),
                        ];
                        segments.extend(klv(&INDEX_KEY, &items.concat(), 4));
                        start = end;
                    }
                } else if self.index == Index::Cbr {
                    let items = [
                        item(0x3C0A, &uid(9000)),
                        item(0x3F0B, &rate),
                        item(0x3F0C, &be(0, 8)),
                        item(0x3F0D, &be(unit_count as u64, 8)),
                        item(0x3F05, &be(units.first().map(Vec::len).unwrap_or(0) as u64, 4)),
                        item(0x3F06, &be(2, 4)),
                        item(0x3F07, &be(1, 4)),
                    ];
                    segments.extend(klv(&INDEX_KEY, &items.concat(), 4));
                }
                let footer = o.out.len() - self.run_in;
                o.pack(
                    &container,
                    Pack {
                        index_bytes: segments.len(),
                        index_sid: if segments.is_empty() { 0 } else { 2 },
                        ..Pack::new(0x04)
                    },
                );
                o.out.extend(&segments);
                for &v in &o.packs.clone() {
                    o.out[v + 24..v + 32].copy_from_slice(&be(footer as u64, 8));
                }
                if self.has_rip {
                    let mut rip: Vec<u8> = vec![];
                    for p in &o.partition_offsets {
                        rip.extend([be(u64::from(p.0), 4), be(p.1 as u64, 8)].concat());
                    }
                    let total = 16 + 5 + rip.len() + 4;
                    o.out.extend(klv(&partition_key(0x11, 0x01), &[rip, be(total as u64, 4)].concat(), 4));
                }
            }
            o.out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::{AVC_LONG_CODING, Index, MxfFixture as F, ber, label, small_frames};
    use super::*;
    use crate::mxfklv::MxfUl;
    use crate::mxfmetadata::MxfVideoCodec;
    use sq_core_time::Time;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct TempDir(PathBuf);
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn temp_dir() -> TempDir {
        static N: AtomicU32 = AtomicU32::new(0);
        let d =
            std::env::temp_dir().join(format!("sq-mxf-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        assert!(std::fs::create_dir_all(&d).is_ok());
        TempDir(d)
    }

    fn write(dir: &TempDir, data: &[u8], name: &str) -> PathBuf {
        let p = dir.0.join(format!("{name}.MXF"));
        assert!(std::fs::write(&p, data).is_ok());
        p
    }

    fn parse(fx: &F) -> MxfFile {
        MxfFile::from_data(fx.build(), Path::new("/dev/null")).unwrap_or_else(|e| panic!("parse failed: {e}"))
    }

    fn picture(f: &MxfFile, u: usize) -> Option<Vec<u8>> {
        f.bytes.slice(f.picture_range(u)?)
    }

    #[test]
    fn partitions_run_in_and_random_index_pack() {
        let mut fx = F { frames: small_frames(9), run_in: 512, body_partitions: 3, audio_tracks: 2, ..F::default() };
        for rip in [true, false] {
            fx.has_rip = rip;
            let f = parse(&fx);
            assert_eq!(f.run_in, 512);
            assert_eq!(f.partition_count, 5, "header, three bodies, footer (rip: {rip})");
            assert!(f.uses_index_table);
            assert_eq!(f.unit_count(), 9);
            for u in 0..9 {
                assert_eq!(picture(&f, u).as_ref(), Some(&fx.frames[u]), "unit {u}");
                let tracks: Vec<u32> = f.elements(u).iter().map(|e| e.track).collect();
                assert_eq!(tracks, vec![0x1501_0500, 0x1602_0300, 0x1602_0301]);
            }
        }
        // Essence in the header partition, no system items.
        fx.body_partitions = 0;
        fx.has_system_item = false;
        fx.run_in = 0;
        let f = parse(&fx);
        assert_eq!((f.partition_count, f.unit_count(), f.uses_index_table), (2, 9, true));
        assert_eq!(picture(&f, 8).as_ref(), Some(&fx.frames[8]));
    }

    #[test]
    fn is_mxf() {
        let dir = temp_dir();
        let mut fx = F { frames: small_frames(2), ..F::default() };
        assert!(MxfFile::is_mxf(&write(&dir, &fx.build(), "a")));
        fx.run_in = 4096;
        assert!(MxfFile::is_mxf(&write(&dir, &fx.build(), "b")), "run-in");
        assert!(!MxfFile::is_mxf(&write(&dir, &[7u8; 5000], "c")));
        assert!(!MxfFile::is_mxf(&write(&dir, &[1, 2, 3], "d")));
        assert!(MxfFile::from_data(vec![0; 4000], Path::new("/dev/null")).is_err());
    }

    #[test]
    fn descriptor_mapping() {
        let mut fx = F {
            frames: small_frames(4),
            audio_tracks: 4,
            edit_rate: (30_000, 1001),
            samples_per_unit: vec![1602, 1601, 1602, 1601, 1602],
            transfer: Some(label(0x01, 0x0B)),
            primaries: Some(label(0x03, 0x04)),
            equations: Some(label(0x02, 0x06)),
            ..F::default()
        };
        for linked in [true, false] {
            fx.linked_track_ids = linked;
            let f = parse(&fx);
            let kinds: Vec<MxfTrackKind> = f.tracks.iter().map(|t| t.kind).collect();
            use MxfTrackKind::{Picture, Sound};
            assert_eq!(kinds, vec![Picture, Sound, Sound, Sound, Sound]);
            let v = f.video_track().unwrap_or_else(|| panic!("video"));
            let p = v.picture.as_ref().unwrap_or_else(|| panic!("picture"));
            assert_eq!(v.edit_unit(), Some(Time::new(1001, 30_000)));
            assert_eq!((v.duration, v.number), (4, 0x1501_0500));
            assert_eq!((p.stored_width, p.stored_height, p.display_height), (1920, 1080, 1080));
            assert_eq!((p.component_depth, p.chroma(), p.is_interlaced()), (10, Some("4:2:2"), false));
            assert_eq!(p.aspect(), Some((16, 9)));
            assert_eq!(p.transfer_tag(), Some("ITU_R_2100_HLG"));
            assert_eq!(p.primaries_tag(), Some("ITU_R_2020"));
            assert_eq!(p.matrix_tag(), Some("ITU_R_2020"));
            assert_eq!(f.video_codec(), Some(MxfVideoCodec::H264));
            let s = f.sound_tracks().last().and_then(|t| t.sound.clone()).unwrap_or_else(|| panic!("sound"));
            assert_eq!((s.sample_rate, s.bits, s.channels), (48_000, 24, 1));
            assert_eq!(s.bytes_per_sample(), 3);
            assert!(s.is_pcm() && !s.is_big_endian());
            let numbers: Vec<u32> = f.sound_tracks().iter().map(|t| t.number).collect();
            assert_eq!(numbers, vec![0x1604_0300, 0x1604_0301, 0x1604_0302, 0x1604_0303]);
        }
    }

    #[test]
    fn codec_identification() {
        let id = |tail: &[u8]| {
            let coding = [&[0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02][..], tail].concat();
            MxfVideoCodec::identify(Some(MxfUl::new(&coding)), None)
        };
        let unsupported = |s: &str| Some(MxfVideoCodec::Unsupported(s.to_string()));
        assert_eq!(id(&[0x01, 0x32, 0x31, 0x01]), Some(MxfVideoCodec::H264));
        assert_eq!(id(&[0x01, 0x31, 0x60, 0x01]), Some(MxfVideoCodec::H264));
        assert_eq!(id(&[0x03, 0x06, 0x04, 0x00]), Some(MxfVideoCodec::Prores(Some(MxfVideoCodec::code("apch")))));
        assert_eq!(id(&[0x03, 0x06, 0x05, 0x00]), Some(MxfVideoCodec::Prores(Some(MxfVideoCodec::code("ap4h")))));
        assert_eq!(id(&[0x71, 0x01, 0x00, 0x00]), unsupported("DNxHD / DNxHR"));
        assert_eq!(id(&[0x03, 0x02, 0x01, 0x00]), unsupported("DNxHD / DNxHR"));
        assert_eq!(id(&[0x01, 0x04, 0x03, 0x00]), unsupported("MPEG-2 (XDCAM / IMX)"));
        assert_eq!(id(&[0x03, 0x01, 0x01, 0x00]), unsupported("JPEG 2000"));
        assert_eq!(id(&[0x02, 0x02, 0x02, 0x00]), unsupported("DV"));
        assert_eq!(
            MxfVideoCodec::identify(None, Some(MxfUl::new(&super::fixture::AVC_CONTAINER))),
            Some(MxfVideoCodec::H264)
        );
        assert_eq!(MxfVideoCodec::identify(None, None), None);
    }

    #[test]
    fn timecode() {
        let tc = |start_frame, base, drop_frame| MxfTimecode { start_frame, base, drop_frame }.string();
        assert_eq!(tc(90_000, 25, false), "01:00:00:00");
        assert_eq!(tc(1_799, 30, true), "00:00:59;29");
        assert_eq!(tc(1_800, 30, true), "00:01:00;02");
        assert_eq!(tc(17_982, 30, true), "00:10:00;00");
        assert_eq!(tc(107_892, 30, true), "01:00:00;00");
        assert_eq!(tc(3_600, 60, true), "00:01:00;04");
        assert_eq!(tc(1_800, 30, false), "00:01:00:00");
        assert_eq!(tc(5, 0, false), "00:00:00:00");

        let mut fx = F { frames: small_frames(2), timecode: Some((107_892, 30, true)), ..F::default() };
        assert_eq!(parse(&fx).timecode, Some(MxfTimecode { start_frame: 107_892, base: 30, drop_frame: true }));
        fx.timecode = None;
        assert_eq!(parse(&fx).timecode, None);
    }

    #[test]
    fn constant_bytes_per_unit_index() {
        let fx = F { frames: small_frames(8), index: Index::Cbr, audio_tracks: 2, ..F::default() };
        let f = parse(&fx);
        assert!(f.uses_index_table);
        assert_eq!(f.unit_count(), 8);
        for u in 0..8 {
            assert_eq!(picture(&f, u).as_ref(), Some(&fx.frames[u]));
        }
    }

    #[test]
    fn long_gop_index_keeps_temporal_offsets_and_flags() {
        let fx = F {
            frames: small_frames(14),
            coding: Some(AVC_LONG_CODING.to_vec()),
            temporal_offsets: Some(vec![0, 1, 1, -2, 1, 1, -2, 0, 1, 1, -2, 1, 1, -2]),
            flags: Some(vec![0xC0, 0x22, 0x33, 0x33, 0x22, 0x33, 0x33, 0xC0, 0x22, 0x33, 0x33, 0x22, 0x33, 0x33]),
            ..F::default()
        };
        let f = parse(&fx);
        assert_eq!(Some(&f.temporal_offsets), fx.temporal_offsets.as_ref());
        assert_eq!(Some(&f.flags), fx.flags.as_ref());
    }

    #[test]
    fn scan_without_index() {
        let mut fx = F { frames: small_frames(7), audio_tracks: 2, ..F::default() };
        // No index table; then a file still being written: no footer, open header partition.
        for (index, footer) in [(Index::None, true), (Index::Vbr, false)] {
            fx.index = index;
            fx.has_footer = footer;
            for system in [true, false] {
                fx.has_system_item = system;
                let data = fx.build();
                let f = MxfFile::from_data(data.clone(), Path::new("/dev/null")).unwrap_or_else(|e| panic!("{e}"));
                assert!(!f.uses_index_table);
                assert_eq!(f.unit_count(), 7);
                assert_eq!(picture(&f, 6).as_ref(), Some(&fx.frames[6]));
                if !footer {
                    // Cut inside the last picture: that unit is gone, the rest plays.
                    let cut_len = data.len() - 2 * 1920 * 3 - fx.frames[6].len() / 2 - 150;
                    let cut = MxfFile::from_data(data[..cut_len].to_vec(), Path::new("/dev/null"))
                        .unwrap_or_else(|e| panic!("{e}"));
                    assert_eq!(cut.unit_count(), 6);
                }
            }
        }
    }

    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            self.0 ^ (self.0 >> 29)
        }
    }

    #[test]
    fn corrupt_partition_layout_gives_no_index_instead_of_a_trap() {
        let part = MxfPartition { essence_start: Some(500), essence_end: 100, ..MxfPartition::default() };
        let later = MxfPartition {
            offset: 100,
            essence_start: Some(140),
            essence_end: 1000,
            body_offset: 64,
            ..MxfPartition::default()
        };
        let bytes = MxfBytes::new(vec![0; 1000]);
        for constant in [0usize, 64] {
            let mut s = MxfIndexSegment { duration: 3, edit_unit_byte_count: constant, ..MxfIndexSegment::default() };
            if constant == 0 {
                s.stream_offsets = vec![0, 64, 128];
                s.temporal_offsets = vec![0, 0, 0];
                s.flags = vec![0x80, 0x80, 0x80];
            }
            let segments = [s];
            assert!(MxfFile::units_from_index(&bytes, std::slice::from_ref(&part), &segments, &[]).is_none());
            assert!(MxfFile::units_from_index(&bytes, &[part.clone(), later.clone()], &segments, &[]).is_none());
            assert!(MxfFile::units_from_index(&bytes, &[later.clone(), part.clone()], &segments, &[]).is_none());
        }

        // In a file: any 8-byte position field of a partition pack or the random index pack set to a small or huge value.
        let fx = F { frames: small_frames(6), audio_tracks: 2, body_partitions: 2, ..F::default() };
        let data = fx.build();
        let mut rng = Lcg(11);
        for _ in 0..300 {
            let mut d = data.clone();
            let at = (rng.next() % (d.len() as u64 - 8)) as usize;
            let values = [0u64, 1, 40, 0x7FFF_FFFF_FFFF_FFFF, d.len() as u64 - 1];
            let value = values[(rng.next() % values.len() as u64) as usize];
            d[at..at + 8].copy_from_slice(&value.to_be_bytes());
            let _ = MxfFile::from_data(d, Path::new("/dev/null")); // must not panic
        }
    }

    #[test]
    fn cached_parse_holds_no_open_file() {
        let dir = temp_dir();
        let fx = F { frames: small_frames(4), ..F::default() };
        let data = fx.build();
        let path = write(&dir, &data, "clip");
        let a = MxfFile::open(&path).unwrap_or_else(|e| panic!("{e}"));
        let b = MxfFile::open(&path).unwrap_or_else(|e| panic!("{e}"));
        assert!(Arc::ptr_eq(&a.shared, &b.shared));
        assert_eq!(picture(&b, 2).as_ref(), Some(&fx.frames[2]));
        let kept = MxfFile::cached_parse(&path).unwrap_or_else(|| panic!("cached"));
        assert_eq!(kept.unit_count(), 4);
        assert!(Arc::ptr_eq(&kept.shared, &a.shared));

        let mut others: Vec<PathBuf> = vec![];
        for i in 0..CACHE_LIMIT - 1 {
            others.push(write(&dir, &data, &format!("other{i}")));
            assert!(MxfFile::open(&others[i]).is_ok());
        }
        assert!(MxfFile::open(&path).is_ok()); // used again: now the newest
        assert!(MxfFile::open(&write(&dir, &data, "last")).is_ok());
        assert!(MxfFile::cached_parse(&path).is_some());
        assert!(MxfFile::cached_parse(&others[0]).is_none(), "the least recently used parse went");
        assert!(MxfFile::cached_parse(&others[1]).is_some());
    }

    #[test]
    fn field_order_from_the_picture_descriptor() {
        use sq_core_model::FieldOrder::{BottomFirst, TopFirst};
        let order = |layout: u8, dominance: Option<u8>, map: Option<(i64, i64)>| {
            let fx = F {
                frames: small_frames(2),
                frame_layout: layout,
                field_dominance: dominance,
                video_line_map: map,
                ..F::default()
            };
            parse(&fx).video_track().and_then(|t| t.picture.as_ref()).map(|p| p.field_order())
        };
        let m = Some((21, 584));
        // Progressive: full frame, and a segmented frame (PsF) whatever its line map says.
        assert_eq!(order(0, None, None), Some(None));
        assert_eq!(order(0, Some(1), m), Some(None));
        assert_eq!(order(4, None, m), Some(None));
        assert_eq!(order(4, Some(2), m), Some(None));
        assert_eq!(order(2, None, m), Some(None), "a single field has no second one");
        // 1080i (XAVC 50i / 59.94i): separate fields, lines 21 and 584, field 1 on top and first.
        assert_eq!(order(1, None, m), Some(Some(TopFirst)));
        assert_eq!(order(1, Some(1), m), Some(Some(TopFirst)));
        assert_eq!(order(1, Some(2), m), Some(Some(BottomFirst)));
        assert_eq!(order(3, None, Some((23, 336))), Some(Some(TopFirst)), "625 lines, mixed fields");
        // 525-line DV style map: both start lines odd, field 1 is the lower field.
        assert_eq!(order(1, None, Some((23, 285))), Some(Some(BottomFirst)));
        assert_eq!(order(1, Some(2), Some((23, 285))), Some(Some(TopFirst)));
        // No line map: field 1 is the top field.
        assert_eq!(order(1, None, None), Some(Some(TopFirst)));
        assert_eq!(order(1, Some(2), None), Some(Some(BottomFirst)));
    }

    /// A corrupt element length cannot reach past the next edit unit (no huge allocation and read).
    #[test]
    fn element_past_the_next_unit_is_rejected() {
        let fx = F { frames: small_frames(12), ..F::default() };
        let mut data = fx.build();
        let r = parse(&fx).picture_range(3).unwrap_or_else(|| panic!("range"));
        let length = (data.len() - r.start) as u32; // the four length bytes before the value
        data[r.start - 4..r.start].copy_from_slice(&length.to_be_bytes());
        let f = MxfFile::from_data(data, Path::new("/dev/null")).unwrap_or_else(|e| panic!("{e}"));
        assert!(f.uses_index_table);
        assert_eq!(f.picture_range(3), None);
        assert_eq!(f.picture_range(4).map(|r| r.len()), Some(fx.frames[4].len()));
    }

    /// Clip-wrapped sound with a constant byte count per unit: rejected at the first units, not after the table
    /// of offsets is filled.
    #[test]
    fn constant_byte_count_inside_one_element_is_rejected() {
        let mut d = vec![0u8; 4_000_000];
        let key = [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x16, 0x01, 0x02, 0x01];
        let klv = [key.to_vec(), ber(4_000_000 - 120, 4)].concat();
        d[100..100 + klv.len()].copy_from_slice(&klv);
        let part = MxfPartition { essence_start: Some(100), essence_end: 4_000_000, ..MxfPartition::default() };
        let s = MxfIndexSegment { edit_unit_byte_count: 6, ..MxfIndexSegment::default() };
        assert!(MxfFile::units_from_index(&MxfBytes::new(d), &[part], &[s], &[]).is_none());
    }
}
