//! Port of `SQMedia/Sources/SQMedia/MXF/MxfKlv.swift`.
//!
//! KLV keys, bounds-checked big-endian reads over a file or memory, BER lengths. Items Swift marks `internal` are
//! `#[doc(hidden)] pub` because the other MXF modules read them.

use std::fs::File;
use std::ops::Range;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

/// A 16-byte SMPTE universal label: KLV key, instance UID or a label value (coding, color, data definition).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MxfUl {
    pub hi: u64,
    pub lo: u64,
}

impl MxfUl {
    /// From up to 16 bytes (missing bytes are 0).
    pub fn new(bytes: &[u8]) -> Self {
        let (mut h, mut l) = (0u64, 0u64);
        for i in 0..16 {
            let b = u64::from(bytes.get(i).copied().unwrap_or(0));
            if i < 8 {
                h = h << 8 | b;
            } else {
                l = l << 8 | b;
            }
        }
        MxfUl { hi: h, lo: l }
    }

    /// Byte `i` (0...15).
    pub fn byte(&self, i: usize) -> u8 {
        if i < 8 { (self.hi >> (56 - 8 * i)) as u8 } else { (self.lo >> (56 - 8 * (i - 8))) as u8 }
    }

    /// All 16 bytes.
    pub fn bytes(&self) -> [u8; 16] {
        std::array::from_fn(|i| self.byte(i))
    }

    /// True when the bytes from `start` equal `expected`.
    #[doc(hidden)]
    pub fn matches(&self, expected: &[u8], start: usize) -> bool {
        expected.iter().enumerate().all(|(i, &b)| self.byte(start + i) == b)
    }

    fn is_smpte(&self) -> bool {
        self.hi >> 32 == 0x060E_2B34
    }

    // MARK: key kinds

    /// Partition pack (ST 377-1 section 7.1): byte 13 is 2 header, 3 body, 4 footer.
    #[doc(hidden)]
    pub fn partition_kind(&self) -> Option<u8> {
        if self.is_smpte()
            && self.matches(&[0x02, 0x05, 0x01], 4)
            && self.matches(&[0x0D, 0x01, 0x02, 0x01, 0x01], 8)
            && (2..=4).contains(&self.byte(13))
        {
            Some(self.byte(13))
        } else {
            None
        }
    }

    #[doc(hidden)]
    pub fn is_partition_pack(&self) -> bool {
        self.partition_kind().is_some()
    }

    #[doc(hidden)]
    pub fn is_primer(&self) -> bool {
        self.is_smpte()
            && self.matches(&[0x02, 0x05, 0x01], 4)
            && self.matches(&[0x0D, 0x01, 0x02, 0x01, 0x01, 0x05], 8)
    }

    #[doc(hidden)]
    pub fn is_random_index_pack(&self) -> bool {
        self.is_smpte()
            && self.matches(&[0x02, 0x05, 0x01], 4)
            && self.matches(&[0x0D, 0x01, 0x02, 0x01, 0x01, 0x11], 8)
    }

    #[doc(hidden)]
    pub fn is_index_segment(&self) -> bool {
        self.is_smpte() && self.byte(4) == 0x02 && self.matches(&[0x0D, 0x01, 0x02, 0x01, 0x01, 0x10, 0x01], 8)
    }

    #[doc(hidden)]
    pub fn is_fill(&self) -> bool {
        self.is_smpte()
            && self.matches(&[0x01, 0x01, 0x01], 4)
            && self.matches(&[0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00], 8)
    }

    /// Generic container essence element (ST 379); also Avid's private container label.
    #[doc(hidden)]
    pub fn is_essence_element(&self) -> bool {
        self.is_smpte()
            && self.matches(&[0x01, 0x02, 0x01], 4)
            && (self.matches(&[0x0D, 0x01, 0x03, 0x01], 8) || self.matches(&[0x0E, 0x04, 0x03, 0x01], 8))
    }

    /// System item of a content package (CP 0x04, GC 0x14).
    #[doc(hidden)]
    pub fn is_system_item(&self) -> bool {
        self.is_smpte()
            && self.matches(&[0x0D, 0x01, 0x03, 0x01], 8)
            && (self.byte(12) == 0x04 || self.byte(12) == 0x14)
    }

    /// Bytes 12...15 of an essence element key: item type, element count, element type, element number.
    #[doc(hidden)]
    pub fn track_number(&self) -> u32 {
        self.lo as u32
    }

    /// Header metadata local set (2-byte tags, 2-byte lengths): the set kind (byte 14), None for other keys.
    #[doc(hidden)]
    pub fn metadata_set_kind(&self) -> Option<u8> {
        if self.is_smpte()
            && self.byte(4) == 0x02
            && self.byte(5) == 0x53
            && self.matches(&[0x0D, 0x01, 0x01, 0x01, 0x01, 0x01], 8)
        {
            Some(self.byte(14))
        } else {
            None
        }
    }
}

/// One KLV packet: key, position of the value and its declared length (may reach past the end of a truncated file).
#[doc(hidden)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MxfKlv {
    pub key: MxfUl,
    pub offset: usize,
    pub value_offset: usize,
    pub length: usize,
}

impl MxfKlv {
    /// End of the value.
    pub fn end(&self) -> usize {
        self.value_offset + self.length
    }
}

#[derive(Clone)]
enum Backing {
    Memory(Arc<Vec<u8>>),
    File(Arc<MxfFileReader>),
    /// No backing at all (the cached parse of a file that is not open): every accessor returns None.
    Detached,
}

/// Bounds-checked big-endian reader over the file (positional reads) or data in memory. Every accessor returns None instead of
/// reading outside the data, so malformed lengths can never panic.
#[doc(hidden)]
#[derive(Clone)]
pub struct MxfBytes {
    backing: Backing,
    /// The open file, None for data in memory and for a detached parse.
    pub reader: Option<Arc<MxfFileReader>>,
    count: usize,
}

impl MxfBytes {
    /// Data in memory.
    pub fn new(d: Vec<u8>) -> Self {
        MxfBytes { count: d.len(), reader: None, backing: Backing::Memory(Arc::new(d)) }
    }

    /// Reads through the file descriptor: a file that goes away (camera card pulled, copy replaced) gives None from every
    /// accessor, where a memory map would raise SIGBUS.
    pub fn from_reader(r: Arc<MxfFileReader>) -> Self {
        MxfBytes { count: r.size, reader: Some(Arc::clone(&r)), backing: Backing::File(r) }
    }

    /// No backing at all (the cached parse of a file that is not open): every accessor returns None.
    pub fn detached(count: usize) -> Self {
        MxfBytes { count, reader: None, backing: Backing::Detached }
    }

    /// Length of the data in bytes.
    pub fn count(&self) -> usize {
        self.count
    }

    pub fn u8(&self, o: usize) -> Option<u8> {
        if o >= self.count {
            return None;
        }
        if let Backing::Memory(d) = &self.backing {
            return d.get(o).copied();
        }
        self.uint(o, 1).map(|v| v as u8)
    }

    /// Unsigned big-endian integer of `n` bytes (1...8).
    pub fn uint(&self, o: usize, n: usize) -> Option<u64> {
        if !(1..=8).contains(&n) || o > self.count.checked_sub(n)? {
            return None;
        }
        match &self.backing {
            Backing::Memory(d) => Some(d[o..o + n].iter().fold(0u64, |v, &b| v << 8 | u64::from(b))),
            Backing::File(reader) => {
                let mut raw = [0u8; 8];
                if !reader.small(o, n, &mut raw[..n]) {
                    return None;
                }
                Some(raw[..n].iter().fold(0u64, |v, &b| v << 8 | u64::from(b)))
            }
            Backing::Detached => None,
        }
    }

    pub fn u16(&self, o: usize) -> Option<u16> {
        self.uint(o, 2).map(|v| v as u16)
    }

    pub fn u32(&self, o: usize) -> Option<u32> {
        self.uint(o, 4).map(|v| v as u32)
    }

    pub fn u64(&self, o: usize) -> Option<u64> {
        self.uint(o, 8)
    }

    /// A u64 file position or size as usize; None when it cannot be a position in any real file.
    pub fn position(&self, o: usize) -> Option<usize> {
        let v = self.uint(o, 8)?;
        if v < 1u64 << 56 { Some(v as usize) } else { None }
    }

    pub fn ul(&self, o: usize) -> Option<MxfUl> {
        let h = self.uint(o, 8)?;
        let l = self.uint(o + 8, 8)?;
        Some(MxfUl { hi: h, lo: l })
    }

    pub fn contains(&self, r: &Range<usize>) -> bool {
        r.end <= self.count && r.start <= r.end
    }

    /// Copies `r` to `dst` (which must be `r.len()` long); false when the range is not inside the data or the file cannot be read.
    pub fn copy(&self, r: Range<usize>, dst: &mut [u8]) -> bool {
        if !self.contains(&r) {
            return false;
        }
        if r.is_empty() {
            return true;
        }
        match &self.backing {
            Backing::Memory(d) => {
                dst[..r.len()].copy_from_slice(&d[r.clone()]);
                true
            }
            Backing::File(reader) => reader.read(r, dst),
            Backing::Detached => false,
        }
    }

    /// Copy of `r`, None when it is not inside the data.
    pub fn slice(&self, r: Range<usize>) -> Option<Vec<u8>> {
        if !self.contains(&r) {
            return None;
        }
        let mut out = vec![0u8; r.len()];
        if self.copy(r, &mut out) { Some(out) } else { None }
    }

    /// Calls `body` with the bytes of `r`: in place for memory, one read into a scratch buffer for a file.
    /// None when the range is not inside the data or cannot be read.
    pub fn with_bytes<T>(&self, r: Range<usize>, body: impl FnOnce(&[u8]) -> T) -> Option<T> {
        if !self.contains(&r) {
            return None;
        }
        if let Backing::Memory(d) = &self.backing {
            return Some(body(&d[r.clone()]));
        }
        let Backing::File(reader) = &self.backing else { return None };
        let mut scratch = vec![0u8; r.len()];
        if !r.is_empty() && !reader.read(r.clone(), &mut scratch) {
            return None;
        }
        Some(body(&scratch))
    }

    /// The KLV packet at `o`: None when key and length do not fit, or the BER length is malformed (indefinite, more than
    /// 8 bytes, absurd). The value itself may be cut off: check `fits`.
    pub fn klv(&self, o: usize) -> Option<MxfKlv> {
        let key = self.ul(o)?;
        let b = self.u8(o + 16)?;
        if b < 0x80 {
            return Some(MxfKlv { key, offset: o, value_offset: o + 17, length: usize::from(b) });
        }
        let n = usize::from(b & 0x7F);
        if !(1..=8).contains(&n) {
            return None;
        }
        let v = self.uint(o + 17, n)?;
        if v >= 1u64 << 56 {
            return None;
        }
        Some(MxfKlv { key, offset: o, value_offset: o + 17 + n, length: v as usize })
    }

    pub fn fits(&self, k: &MxfKlv) -> bool {
        k.end() <= self.count
    }
}

/// BER length decoding on its own (ST 377-1 section 6.3.4), for tests and small buffers.
#[doc(hidden)]
pub struct MxfBer;

impl MxfBer {
    /// (length, bytes used) at the start of `b`; None when malformed.
    pub fn decode(b: &[u8]) -> Option<(u64, usize)> {
        let first = *b.first()?;
        if first < 0x80 {
            return Some((u64::from(first), 1));
        }
        let n = usize::from(first & 0x7F);
        if !(1..=8).contains(&n) || b.len() <= n {
            return None;
        }
        let v = b[1..=n].iter().fold(0u64, |v, &x| v << 8 | u64::from(x));
        Some((v, n + 1))
    }
}

#[derive(Default, Clone)]
struct Window {
    start: Option<usize>,
    bytes: Vec<u8>,
}

struct Windows {
    list: [Window; 4],
    next: usize,
}

const WINDOW_SIZE: usize = 4096;

/// Positional reads of a file, with a few small cached windows for the many tiny reads of KLV walking and metadata parsing.
/// Errors and short reads are reported, never raised as a signal.
#[doc(hidden)]
pub struct MxfFileReader {
    /// File size in bytes.
    pub size: usize,
    /// Modification date in nanoseconds since 1970.
    pub modified: i64,
    file: File,
    windows: Mutex<Windows>,
}

impl MxfFileReader {
    /// None for a missing file, a directory or an empty file.
    pub fn open(path: &Path) -> Option<Self> {
        let file = File::open(path).ok()?;
        let meta = file.metadata().ok()?;
        if !meta.is_file() || meta.len() == 0 {
            return None;
        }
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| (d.as_secs() as i64).wrapping_mul(1_000_000_000).wrapping_add(i64::from(d.subsec_nanos())))
            .unwrap_or(0);
        Some(MxfFileReader {
            size: usize::try_from(meta.len()).ok()?,
            modified,
            file,
            windows: Mutex::new(Windows { list: Default::default(), next: 0 }),
        })
    }

    #[cfg(unix)]
    fn read_at(&self, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
        std::os::unix::fs::FileExt::read_at(&self.file, buf, offset)
    }

    #[cfg(windows)]
    fn read_at(&self, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
        std::os::windows::fs::FileExt::seek_read(&self.file, buf, offset)
    }

    /// Reads exactly `r` into `dst`; false on an error or when the file ends early.
    pub fn read(&self, r: Range<usize>, dst: &mut [u8]) -> bool {
        if r.end > self.size || r.start > r.end {
            return false;
        }
        let mut done = 0;
        while done < r.len() {
            match self.read_at(&mut dst[done..r.len()], (r.start + done) as u64) {
                Ok(0) => return false,
                Ok(n) => done += n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => return false,
            }
        }
        true
    }

    /// A few bytes through the window cache.
    pub fn small(&self, o: usize, n: usize, dst: &mut [u8]) -> bool {
        if n == 0 || o > self.size.saturating_sub(n) || self.size < n {
            return false;
        }
        let Ok(mut w) = self.windows.lock() else { return false };
        for win in &w.list {
            if let Some(start) = win.start
                && o >= start
                && o + n <= start + win.bytes.len()
            {
                dst[..n].copy_from_slice(&win.bytes[o - start..o - start + n]);
                return true;
            }
        }
        // Aligned so that a walk forward stays inside; a read across the boundary starts its own window.
        let mut start = o & !(WINDOW_SIZE - 1);
        if o + n > start + WINDOW_SIZE {
            start = o;
        }
        let length = WINDOW_SIZE.min(self.size - start);
        let mut bytes = vec![0u8; length];
        if !self.read(start..start + length, &mut bytes) {
            return false;
        }
        dst[..n].copy_from_slice(&bytes[o - start..o - start + n]);
        let next = w.next;
        w.list[next] = Window { start: Some(start), bytes };
        w.next = (next + 1) % w.list.len();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PICTURE_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x15, 0x01, 0x05, 0x00];
    const SYSTEM_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x04, 0x01, 0x01, 0x00];
    const FILL_KEY: [u8; 16] =
        [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02, 0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00];

    /// KLV packet with a BER length of `long` extra bytes (0 = short form).
    fn klv(key: &[u8], value: &[u8], long: usize) -> Vec<u8> {
        let mut out = key.to_vec();
        if long == 0 {
            out.push(value.len() as u8);
        } else {
            out.push(0x80 | long as u8);
            out.extend((0..long).rev().map(|i| (value.len() >> (8 * i)) as u8));
        }
        out.extend_from_slice(value);
        out
    }

    fn partition_key(kind: u8) -> [u8; 16] {
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, kind, 0x04, 0x00]
    }

    #[test]
    fn ber_lengths() {
        assert_eq!(MxfBer::decode(&[0x00]).map(|v| v.0), Some(0));
        assert_eq!(MxfBer::decode(&[0x7F]), Some((127, 1)));
        assert_eq!(MxfBer::decode(&[0x81, 0x80]).map(|v| v.0), Some(128));
        assert_eq!(MxfBer::decode(&[0x83, 0x01, 0x02, 0x03]), Some((0x010203, 4)));
        assert_eq!(MxfBer::decode(&[0x88, 0, 0, 0, 0, 0, 0, 1, 0]).map(|v| v.0), Some(256));
        assert_eq!(MxfBer::decode(&[]), None);
        assert_eq!(MxfBer::decode(&[0x80]), None); // indefinite length
        assert_eq!(MxfBer::decode(&[0x89, 0, 0, 0, 0, 0, 0, 0, 0, 1]), None); // more than 8 length bytes
        assert_eq!(MxfBer::decode(&[0x84, 0x01, 0x02]), None); // cut off
    }

    #[test]
    fn klv_walk() {
        let a = klv(&FILL_KEY, &[1, 2, 3], 0);
        let b = klv(&PICTURE_KEY, &[9; 300], 3);
        let mut all = a.clone();
        all.extend(&b);
        all.extend([0x06, 0x0E]);
        let r = MxfBytes::new(all);
        let first = r.klv(0);
        let second = r.klv(a.len());
        assert_eq!(first.map(|k| (k.length, k.value_offset, k.key.is_fill())), Some((3, 17, true)));
        assert_eq!(second.map(|k| (k.length, k.value_offset)), Some((300, a.len() + 20)));
        assert_eq!(second.map(|k| (k.key.is_essence_element(), k.key.track_number())), Some((true, 0x1501_0500)));
        assert_eq!(r.klv(a.len() + b.len()), None); // key cut off
        assert_eq!(r.klv(1 << 40), None);
        // A length that reaches past the end is returned, and does not fit.
        let cut = MxfBytes::new(b[..100].to_vec());
        assert_eq!(cut.klv(0).map(|k| cut.fits(&k)), Some(false));
        let mut absurd = PICTURE_KEY.to_vec();
        absurd.extend([0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
        assert_eq!(MxfBytes::new(absurd).klv(0), None);
        assert_eq!(r.u32(r.count() - 3), None);
        assert_eq!(r.slice(4..r.count() + 1), None);
        assert_eq!(MxfUl::new(&PICTURE_KEY).bytes(), PICTURE_KEY);
        assert_eq!(MxfUl::new(&partition_key(0x04)).partition_kind(), Some(4));
        assert!(MxfUl::new(&SYSTEM_KEY).is_system_item());
        assert!(!MxfUl::new(&SYSTEM_KEY).is_partition_pack());
    }

    /// Small reads across the reader's window boundaries and the ends of the file give what memory gives.
    #[test]
    fn file_backed_reads_match_memory() {
        let data: Vec<u8> = (0..10_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        let dir = std::env::temp_dir().join(format!("sq-mxfklv-{}", std::process::id()));
        assert!(std::fs::create_dir_all(&dir).is_ok());
        let path = dir.join("clip.bin");
        assert!(std::fs::write(&path, &data).is_ok());
        let reader = MxfFileReader::open(&path).map(Arc::new);
        assert!(reader.is_some());
        let Some(reader) = reader else { return };
        let (file, memory) = (MxfBytes::from_reader(reader), MxfBytes::new(data.clone()));
        let offsets =
            (4088..4101).chain(8185..8196).chain([0, data.len() - 8, data.len() - 7, data.len() - 1, data.len()]);
        for o in offsets {
            for n in [1, 2, 4, 8] {
                assert_eq!(file.uint(o, n), memory.uint(o, n), "{o} {n}");
            }
        }
        assert_eq!(file.slice(data.len() - 4..data.len() + 1), None);
        assert_eq!(file.slice(100..100), Some(Vec::new()));
        assert_eq!(file.slice(5000..6000), Some(data[5000..6000].to_vec()));
        assert_eq!(file.with_bytes(7..11, |b| b.to_vec()), Some(data[7..11].to_vec()));
        // The file shrinks: reads past the new end give None, not a crash.
        assert!(std::fs::write(&path, &data[..5000]).is_ok());
        assert_eq!(file.slice(9000..9100), None);
        assert!(MxfFileReader::open(&dir).is_none());
        assert!(MxfFileReader::open(&dir.join("gone")).is_none());
        assert!(std::fs::remove_dir_all(&dir).is_ok());
    }
}
