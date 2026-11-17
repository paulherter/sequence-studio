//! Port of `SQMedia/Sources/SQMedia/EmbeddedLUT.swift`.

use crate::media_error::MediaError;
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// One item of the MP4 `meta` box (ISO BMFF item model: iinf/infe + iloc, bytes in `idat` or at a file offset).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EmbeddedItem {
    pub id: u32,
    pub name: String,
    pub item_type: Option<String>,
    pub content_type: Option<String>,
    /// 1 = offsets relative to `idat`, 0 = absolute file offsets, 2 = item offsets (unsupported).
    pub construction_method: i64,
    /// Absolute file offset of the first extent, and total length of all extents.
    pub file_offset: u64,
    pub length: u64,
    #[doc(hidden)]
    pub extent_offsets: Vec<u64>,
    #[doc(hidden)]
    pub extent_lengths: Vec<u64>,
}

/// Whether a clip carries a look LUT, and its name (`EmbeddedMeta::lut_header_in_clip`), without the LUT itself.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EmbeddedLUTHeader {
    pub name: Option<String>,
    pub source_item_bytes: usize,
    pub source_item_name: String,
}

/// A camera look LUT found inside a clip. `data` is always `.cube` text, ready for a cube parser.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EmbeddedLUT {
    pub name: Option<String>,
    pub data: Vec<u8>,
    /// Size of the item in the file (Sony: a binary "BCUB" block, converted to text for `data`).
    pub source_item_bytes: usize,
    pub source_item_name: String,
}

impl EmbeddedLUT {
    pub fn new(name: Option<String>, data: Vec<u8>, source_item_bytes: usize, source_item_name: String) -> EmbeddedLUT {
        EmbeddedLUT { name, data, source_item_bytes, source_item_name }
    }

    fn header(&self) -> EmbeddedLUTHeader {
        EmbeddedLUTHeader {
            name: self.name.clone(),
            source_item_bytes: self.source_item_bytes,
            source_item_name: self.source_item_name.clone(),
        }
    }
}

/// Reads `count` bytes (fewer at the end of the data) at `offset`.
pub type Reader<'a> = &'a dyn Fn(u64, usize) -> Result<Vec<u8>, MediaError>;

/// Embedded metadata items of an MP4 clip.
pub enum EmbeddedMeta {}

impl EmbeddedMeta {
    pub const MAX_ITEM_BYTES: u64 = 16 << 20;

    // MARK: Public entry points

    /// Lists the items of the clip's `meta` box (top level or inside `moov`). Empty if there is none.
    pub fn items_in_clip(path: &Path) -> Result<Vec<EmbeddedItem>, MediaError> {
        let mut fh = open(path)?;
        let size = fh.seek(SeekFrom::End(0)).map_err(|_| MediaError::Unreadable)?;
        Self::items_read(size, &file_reader(&fh))
    }

    /// Bytes of one item (all extents concatenated, capped at 16 MB).
    pub fn data_of_in_clip(item: &EmbeddedItem, path: &Path) -> Result<Vec<u8>, MediaError> {
        let fh = open(path)?;
        Self::data_of_read(item, &file_reader(&fh))
    }

    /// The camera look LUT of the clip, if any item holds one (plain `.cube` text or Sony's binary look data).
    pub fn lut_in_clip(path: &Path) -> Result<Option<EmbeddedLUT>, MediaError> {
        let mut fh = open(path)?;
        let size = fh.seek(SeekFrom::End(0)).map_err(|_| MediaError::Unreadable)?;
        let read = file_reader(&fh);
        let items = Self::items_read(size, &read)?;
        Self::lut_read(&items, &read, true)
    }

    // MARK: Pure parts (testable on synthetic bytes)

    pub fn items_in_data(bytes: &[u8]) -> Result<Vec<EmbeddedItem>, MediaError> {
        Self::items_read(bytes.len() as u64, &data_reader(bytes))
    }

    pub fn lut_in_data(bytes: &[u8]) -> Result<Option<EmbeddedLUT>, MediaError> {
        let read = data_reader(bytes);
        let items = Self::items_read(bytes.len() as u64, &read)?;
        Self::lut_read(&items, &read, true)
    }

    pub fn items_read(size: u64, read: Reader) -> Result<Vec<EmbeddedItem>, MediaError> {
        let Some(meta) = find_meta(size, read)? else { return Ok(Vec::new()) };
        parse_meta(meta.start, meta.end, read)
    }

    pub fn data_of_read(item: &EmbeddedItem, read: Reader) -> Result<Vec<u8>, MediaError> {
        let mut out = Vec::new();
        for (&o, &l) in item.extent_offsets.iter().zip(&item.extent_lengths) {
            if (out.len() as u64).saturating_add(l) > Self::MAX_ITEM_BYTES {
                break;
            }
            out.extend(read(o, l as usize)?);
        }
        Ok(out)
    }

    /// Whether the clip has a look LUT and its name, as `lut_in_clip` would answer, without building the `.cube` text
    /// (a Sony 33-point block is ~36 000 formatted lines: most of a Sony clip's import probe). Import needs only this.
    pub fn lut_header_in_clip(path: &Path) -> Result<Option<EmbeddedLUTHeader>, MediaError> {
        let mut fh = open(path)?;
        let size = fh.seek(SeekFrom::End(0)).map_err(|_| MediaError::Unreadable)?;
        let read = file_reader(&fh);
        let items = Self::items_read(size, &read)?;
        Ok(Self::lut_read(&items, &read, false)?.map(|l| l.header()))
    }

    pub fn lut_header_in_data(bytes: &[u8]) -> Result<Option<EmbeddedLUTHeader>, MediaError> {
        let read = data_reader(bytes);
        let items = Self::items_read(bytes.len() as u64, &read)?;
        Ok(Self::lut_read(&items, &read, false)?.map(|l| l.header()))
    }

    /// `text: false` leaves `data` empty (the answer and the name are the same).
    pub fn lut_read(items: &[EmbeddedItem], read: Reader, text: bool) -> Result<Option<EmbeddedLUT>, MediaError> {
        // Likely candidates first (name mentions look/LUT, then big items), skipping unsupported/empty ones.
        let mut ranked: Vec<&EmbeddedItem> = items.iter().collect();
        ranked.sort_by_key(|i| rank(i));
        for item in ranked {
            if !(item.length > 0 && item.length <= Self::MAX_ITEM_BYTES && item.construction_method != 2) {
                continue;
            }
            let bytes = Self::data_of_read(item, read)?;
            if Self::looks_like_cube(&bytes) {
                let name =
                    cube_title(&bytes).or_else(|| if item.name.is_empty() { None } else { Some(item.name.clone()) });
                let data = if text { bytes.clone() } else { Vec::new() };
                return Ok(Some(EmbeddedLUT::new(name, data, bytes.len(), item.name.clone())));
            }
            if let Some(sony) = SonyLookData::decode(&bytes, text) {
                return Ok(Some(EmbeddedLUT::new(
                    sony.name,
                    sony.cube_text.into_bytes(),
                    bytes.len(),
                    item.name.clone(),
                )));
            }
        }
        Ok(None)
    }

    /// True if the bytes are `.cube` text: a keyword header line (TITLE / LUT_*_SIZE / DOMAIN_*) comes first.
    pub fn looks_like_cube(d: &[u8]) -> bool {
        let head = &d[..d.len().min(4096)];
        if head.contains(&0) {
            return false;
        }
        // A multi-byte character may be cut by the 4096 byte limit: drop up to three bytes.
        let Some(text) = (0..=3).find_map(|k| std::str::from_utf8(&head[..head.len().saturating_sub(k)]).ok()) else {
            return false;
        };
        for raw in text.split(is_newline) {
            let line = raw.trim_matches(is_blank);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let key = line.split(' ').next().unwrap_or(line);
            return key == "TITLE"
                || key == "LUT_3D_SIZE"
                || key == "LUT_1D_SIZE"
                || key.starts_with("DOMAIN_")
                || key.starts_with("LUT_3D_INPUT_RANGE")
                || key.starts_with("LUT_1D_INPUT_RANGE");
        }
        false
    }
}

fn open(path: &Path) -> Result<File, MediaError> {
    File::open(path).map_err(|_| MediaError::Unreadable)
}

fn rank(i: &EmbeddedItem) -> i32 {
    let n = i.name.to_lowercase();
    if n.contains("look") || n.contains("lut") {
        return 0;
    }
    if i.length > 100_000 { 1 } else { 2 }
}

/// `Character.isNewline`.
fn is_newline(c: char) -> bool {
    matches!(c, '\u{A}'..='\u{D}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `CharacterSet.whitespaces`: tab and the Unicode space separators.
fn is_blank(c: char) -> bool {
    matches!(c, '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

fn cube_title(d: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(&d[..d.len().min(4096)]).ok()?;
    for raw in text.split(is_newline) {
        let line = raw.trim_matches(is_blank);
        if let Some(rest) = line.strip_prefix("TITLE") {
            let t = rest.trim_matches(|c| c == ' ' || c == '\t' || c == '"');
            return if t.is_empty() { None } else { Some(t.to_string()) };
        }
    }
    None
}

// MARK: Readers

fn data_reader(d: &[u8]) -> impl Fn(u64, usize) -> Result<Vec<u8>, MediaError> + '_ {
    move |off, n| {
        // The Swift reader throws CocoaError.fileReadCorruptFile.
        if off > d.len() as u64 {
            return Err(MediaError::Unreadable);
        }
        let s = off as usize;
        Ok(d[s..s.saturating_add(n).min(d.len())].to_vec())
    }
}

fn file_reader(fh: &File) -> impl Fn(u64, usize) -> Result<Vec<u8>, MediaError> + '_ {
    move |off, n| {
        let mut f = fh;
        f.seek(SeekFrom::Start(off)).map_err(|_| MediaError::Unreadable)?;
        let mut out = Vec::new();
        f.take(n as u64).read_to_end(&mut out).map_err(|_| MediaError::Unreadable)?;
        Ok(out)
    }
}

// MARK: Box walking

struct BoxHeader {
    kind: String,
    start: u64, // after the header
    end: u64,
}

fn boxes(from: u64, to: u64, read: Reader) -> Result<Vec<BoxHeader>, MediaError> {
    let mut out = Vec::new();
    let mut pos = from;
    while pos + 8 <= to {
        let h = read(pos, 16)?;
        if h.len() < 8 {
            break;
        }
        let mut size = be(&h, 0, 4);
        let kind = String::from_utf8_lossy(&h[4..8]).into_owned();
        let mut header: u64 = 8;
        if size == 1 {
            if h.len() != 16 {
                break;
            }
            size = be(&h, 8, 8);
            header = 16;
        } else if size == 0 {
            size = to - pos;
        }
        // Swift traps when `pos + size` overflows; a box that large cannot fit anyway.
        if size < header || pos.checked_add(size).is_none_or(|e| e > to) {
            break;
        }
        out.push(BoxHeader { kind, start: pos + header, end: pos + size });
        pos += size;
    }
    Ok(out)
}

fn find_meta(size: u64, read: Reader) -> Result<Option<BoxHeader>, MediaError> {
    let mut top = boxes(0, size, read)?;
    if let Some(i) = top.iter().position(|b| b.kind == "meta") {
        return Ok(Some(top.swap_remove(i)));
    }
    if let Some(moov) = top.iter().find(|b| b.kind == "moov") {
        return Ok(boxes(moov.start, moov.end, read)?.into_iter().find(|b| b.kind == "meta"));
    }
    Ok(None)
}

struct Info {
    id: u32,
    name: String,
    kind: Option<String>,
    content: Option<String>,
}

struct Loc {
    method: i64,
    base: u64,
    offsets: Vec<u64>,
    lengths: Vec<u64>,
}

fn parse_meta(body: u64, end: u64, read: Reader) -> Result<Vec<EmbeddedItem>, MediaError> {
    if body + 4 > end {
        return Ok(Vec::new());
    }
    let children = boxes(body + 4, end, read)?; // FullBox: skip version/flags
    let mut infos: Vec<Info> = Vec::new();
    let mut locs: HashMap<u32, Loc> = HashMap::new();
    let mut idat_start: u64 = 0;
    for c in &children {
        match c.kind.as_str() {
            "iinf" => infos = parse_iinf(c, read)?,
            "iloc" => locs = parse_iloc(c, read)?,
            "idat" => idat_start = c.start,
            _ => {}
        }
    }
    let mut items = Vec::new();
    for info in infos {
        let Some(loc) = locs.get(&info.id) else { continue };
        let origin = if loc.method == 1 { idat_start } else { 0 };
        let offsets: Vec<u64> =
            loc.offsets.iter().map(|o| origin.saturating_add(loc.base).saturating_add(*o)).collect();
        items.push(EmbeddedItem {
            id: info.id,
            name: info.name,
            item_type: info.kind,
            content_type: info.content,
            construction_method: loc.method,
            file_offset: offsets.first().copied().unwrap_or(0),
            length: loc.lengths.iter().fold(0u64, |a, l| a.saturating_add(*l)),
            extent_offsets: offsets,
            extent_lengths: loc.lengths.clone(),
        });
    }
    Ok(items)
}

fn parse_iinf(b: &BoxHeader, read: Reader) -> Result<Vec<Info>, MediaError> {
    let d = read(b.start, (b.end - b.start).min(1 << 20) as usize)?;
    if d.len() < 6 {
        return Ok(Vec::new());
    }
    let version = d[0];
    let mut p = 4;
    let count = if version == 0 { be(&d, p, 2) } else { be(&d, p, 4) } as usize;
    p += if version == 0 { 2 } else { 4 };
    let mut out = Vec::new();
    for _ in 0..count {
        if p + 12 > d.len() {
            break;
        }
        let size = be(&d, p, 4) as usize;
        if size < 12 || p + size > d.len() || &d[p + 4..p + 8] != b"infe" {
            break;
        }
        let v = d[p + 8];
        let b = &d[p + 12..p + size]; // after size, type, version/flags
        let mut q;
        let id: u32;
        let mut item_type: Option<String> = None;
        if v >= 2 {
            let id_len = if v == 2 { 2 } else { 4 };
            if b.len() < id_len + 2 + 4 {
                break;
            }
            id = be(b, 0, id_len) as u32;
            q = id_len + 2;
            item_type = Some(String::from_utf8_lossy(&b[q..q + 4]).into_owned());
            q += 4;
        } else {
            if b.len() < 4 {
                break;
            }
            id = be(b, 0, 2) as u32;
            q = 4;
        }
        let name = c_string(b, &mut q);
        let mut content = None;
        if q < b.len() && (v < 2 || item_type.as_deref() == Some("mime")) {
            content = Some(c_string(b, &mut q));
        }
        out.push(Info { id, name, kind: item_type, content });
        p += size;
    }
    Ok(out)
}

fn parse_iloc(b: &BoxHeader, read: Reader) -> Result<HashMap<u32, Loc>, MediaError> {
    let d = read(b.start, (b.end - b.start).min(1 << 20) as usize)?;
    if d.len() < 8 {
        return Ok(HashMap::new());
    }
    let version = i64::from(d[0]);
    let off_size = usize::from(d[4] >> 4);
    let len_size = usize::from(d[4] & 15);
    let base_size = usize::from(d[5] >> 4);
    let index_size = if version >= 1 { usize::from(d[5] & 15) } else { 0 };
    let mut p = 6;
    let count;
    if version < 2 {
        count = be(&d, p, 2) as usize;
        p += 2;
    } else {
        count = be(&d, p, 4) as usize;
        p += 4;
    }
    let mut out = HashMap::new();
    for _ in 0..count {
        let id_size = if version < 2 { 2 } else { 4 };
        if p + id_size > d.len() {
            break;
        }
        let id = be(&d, p, id_size) as u32;
        p += id_size;
        let mut method = 0;
        if version >= 1 {
            if p + 2 > d.len() {
                break;
            }
            method = (be(&d, p, 2) & 15) as i64;
            p += 2;
        }
        if p + 2 + base_size + 2 > d.len() {
            break;
        }
        p += 2; // data_reference_index
        let base = be(&d, p, base_size);
        p += base_size;
        let n = be(&d, p, 2) as usize;
        p += 2;
        let mut loc = Loc { method, base, offsets: Vec::new(), lengths: Vec::new() };
        for _ in 0..n {
            if p + index_size + off_size + len_size > d.len() {
                break;
            }
            p += index_size;
            loc.offsets.push(be(&d, p, off_size));
            p += off_size;
            loc.lengths.push(be(&d, p, len_size));
            p += len_size;
        }
        out.insert(id, loc);
    }
    Ok(out)
}

/// Big-endian integer of `n` bytes at `at`; 0 when out of range.
fn be(b: &[u8], at: usize, n: usize) -> u64 {
    if n == 0 || at + n > b.len() {
        return 0;
    }
    b[at..at + n].iter().fold(0u64, |a, &x| a << 8 | u64::from(x))
}

fn c_string(b: &[u8], q: &mut usize) -> String {
    let s = *q;
    while *q < b.len() && b[*q] != 0 {
        *q += 1;
    }
    let str = String::from_utf8_lossy(&b[s..*q]).into_owned();
    if *q < b.len() {
        *q += 1;
    }
    str
}

/// Sony "Look Control data" item: SMPTE KLV ("ELUT") wrapping a big-endian "SONYBCUB" block.
/// Layout found in ZV-E1 clips (offsets from the start of "SONYBCUB"): u32 version at 8, u32 block length at 12,
/// u32 LUT size N at 128, u32 data offset at 136 (3328), u32 data length at 140 (N^3 * 12), 3 x f32 domain min at 144,
/// 3 x f32 domain max at 156, NUL-terminated file name at 256; the data are N^3 big-endian RGB f32 triplets, red fastest.
pub enum SonyLookData {}

/// A decoded Sony look table.
pub struct SonyDecoded {
    pub name: Option<String>,
    pub size: usize,
    pub cube_text: String,
}

impl SonyLookData {
    /// `want_text: false` checks the block the same way but leaves `cube_text` empty.
    pub fn decode(item: &[u8], want_text: bool) -> Option<SonyDecoded> {
        const MAGIC: &[u8] = b"SONYBCUB";
        if item.len() <= 400 {
            return None;
        }
        let at = item.windows(MAGIC.len()).position(|w| w == MAGIC)?;
        let b = &item[at..];
        let u32_at = |o: usize| -> usize {
            if o + 4 > b.len() {
                return 0;
            }
            b[o..o + 4].iter().fold(0usize, |a, &x| a << 8 | usize::from(x))
        };
        let f32_at = |o: usize| f32::from_bits(u32_at(o) as u32);
        let n = u32_at(128);
        let data_offset = u32_at(136);
        let data_length = u32_at(140);
        if !(2..=129).contains(&n)
            || data_length != n * n * n * 12
            || data_offset < 256
            || data_offset + data_length > b.len()
        {
            return None;
        }
        let dmin: Vec<f32> = (0..3).map(|i| f32_at(144 + 4 * i)).collect();
        let dmax: Vec<f32> = (0..3).map(|i| f32_at(156 + 4 * i)).collect();
        if !dmin.iter().chain(&dmax).all(|v| v.is_finite()) || !dmin.iter().zip(&dmax).all(|(a, z)| a < z) {
            return None;
        }
        let mut name_end = 256;
        while name_end < b.len().min(256 + 128) && b[name_end] != 0 {
            name_end += 1;
        }
        let name = String::from_utf8_lossy(&b[256..name_end]).into_owned();
        let name_opt = if name.is_empty() { None } else { Some(name.clone()) };
        if !want_text {
            if (0..n * n * n * 3).any(|i| !f32_at(data_offset + i * 4).is_finite()) {
                return None;
            }
            return Some(SonyDecoded { name: name_opt, size: n, cube_text: String::new() });
        }
        let mut text = format!("TITLE \"{name}\"\nLUT_3D_SIZE {n}\n");
        let f = |v: f32| f64::from(v);
        text += &format!(
            "DOMAIN_MIN {:.6} {:.6} {:.6}\nDOMAIN_MAX {:.6} {:.6} {:.6}\n",
            f(dmin[0]),
            f(dmin[1]),
            f(dmin[2]),
            f(dmax[0]),
            f(dmax[1]),
            f(dmax[2])
        );
        for i in 0..n * n * n {
            let o = data_offset + i * 12;
            let (x, y, z) = (f32_at(o), f32_at(o + 4), f32_at(o + 8));
            if !(x.is_finite() && y.is_finite() && z.is_finite()) {
                return None;
            }
            text += &format!("{:.6} {:.6} {:.6}\n", f(x), f(y), f(z));
        }
        Some(SonyDecoded { name: name_opt, size: n, cube_text: text })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn be_bytes(v: u64, n: usize) -> Vec<u8> {
        (0..n).map(|i| (v >> (8 * (n - 1 - i))) as u8).collect()
    }

    fn make_box(kind: &str, payload: &[u8]) -> Vec<u8> {
        let mut d = be_bytes(8 + payload.len() as u64, 4);
        d.extend(kind.as_bytes());
        d.extend(payload);
        d
    }

    fn cstr(s: &str) -> Vec<u8> {
        let mut d = s.as_bytes().to_vec();
        d.push(0);
        d
    }

    /// Sony-style item list: infe v0 (id, protection, name, content type), iloc v1, construction_method 1 into `idat`.
    fn meta_box(items: &[(&str, &[u8])], infe_version: u8, iloc_method: u64, base_offset: u64) -> Vec<u8> {
        let mut infes = Vec::new();
        for (i, it) in items.iter().enumerate() {
            let mut p = vec![infe_version, 0, 0, 0];
            p.extend(be_bytes(i as u64 + 1, 2));
            p.extend(be_bytes(0, 2));
            if infe_version >= 2 {
                p.extend(b"mime");
            }
            p.extend(cstr(it.0));
            p.extend(cstr("application/octet-stream"));
            infes.extend(make_box("infe", &p));
        }
        let mut iinf_body = vec![0, 0, 0, 0];
        iinf_body.extend(be_bytes(items.len() as u64, 2));
        iinf_body.extend(infes);
        let iinf = make_box("iinf", &iinf_body);

        let mut idat = vec![0u8; base_offset as usize];
        let mut iloc = vec![1, 0, 0, 0, 0x44, 0x40];
        iloc.extend(be_bytes(items.len() as u64, 2));
        for (i, it) in items.iter().enumerate() {
            iloc.extend(be_bytes(i as u64 + 1, 2));
            iloc.extend(be_bytes(iloc_method, 2));
            iloc.extend(be_bytes(0, 2));
            iloc.extend(be_bytes(if iloc_method == 1 { base_offset } else { 0 }, 4));
            iloc.extend(be_bytes(1, 2));
            iloc.extend(be_bytes(idat.len() as u64 - if iloc_method == 1 { base_offset } else { 0 }, 4));
            iloc.extend(be_bytes(it.1.len() as u64, 4));
            idat.extend(it.1);
        }
        let mut hdlr_body = vec![0u8; 8];
        hdlr_body.extend(b"nrtm");
        hdlr_body.extend([0u8; 12]);
        hdlr_body.extend(cstr("Non-Real Time Metadata"));
        let hdlr = make_box("hdlr", &hdlr_body);
        let mut body = vec![0, 0, 0, 0];
        body.extend(hdlr);
        body.extend(iinf);
        body.extend(make_box("iloc", &iloc));
        body.extend(make_box("idat", &idat));
        make_box("meta", &body)
    }

    fn mp4(meta: Vec<u8>, inside_moov: bool) -> Vec<u8> {
        let mut d = make_box("ftyp", b"isom0000");
        d.extend(make_box("mdat", &[7u8; 100]));
        if inside_moov {
            let mut moov = make_box("mvhd", &[0u8; 4]);
            moov.extend(meta);
            d.extend(make_box("moov", &moov));
        } else {
            d.extend(meta);
        }
        d
    }

    const CUBE_TEXT: &str =
        "# comment\nTITLE \"Look\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";

    /// Builds an item in Sony's "ELUT" + "SONYBCUB" layout with an N^3 identity-ish LUT (red fastest, big-endian f32).
    fn sony_item(n: usize, name: &str) -> Vec<u8> {
        let data_offset = 3328;
        let mut blob = b"SONYBCUB".to_vec();
        blob.extend(vec![0u8; data_offset - 8]);
        let put = |blob: &mut Vec<u8>, v: u32, at: usize| blob[at..at + 4].copy_from_slice(&v.to_be_bytes());
        put(&mut blob, 0x0100_0000, 8);
        put(&mut blob, (data_offset + n * n * n * 12) as u32, 12);
        put(&mut blob, n as u32, 128);
        put(&mut blob, data_offset as u32, 136);
        put(&mut blob, (n * n * n * 12) as u32, 140);
        for at in [156, 160, 164] {
            put(&mut blob, 1f32.to_bits(), at);
        }
        blob[256..256 + name.len()].copy_from_slice(name.as_bytes());
        for b in 0..n {
            for g in 0..n {
                for r in 0..n {
                    for c in [r, g, b] {
                        blob.extend(((c as f64 / (n - 1) as f64) as f32).to_bits().to_be_bytes());
                    }
                }
            }
        }
        let mut item = b"ELUT".to_vec();
        item.extend([0u8; 9]);
        item.extend(blob);
        item
    }

    fn default_meta(items: &[(&str, &[u8])]) -> Vec<u8> {
        mp4(meta_box(items, 0, 1, 0), false)
    }

    #[test]
    fn lists_items_with_names_and_sizes() {
        let lens = [9u8; 33];
        let file = default_meta(&[("Look Control data", CUBE_TEXT.as_bytes()), ("Lens profile", &lens)]);
        let items = EmbeddedMeta::items_in_data(&file).unwrap();
        assert_eq!(
            items.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(),
            vec!["Look Control data", "Lens profile"]
        );
        assert_eq!(items.iter().map(|i| i.length).collect::<Vec<_>>(), vec![CUBE_TEXT.len() as u64, 33]);
        assert!(
            items
                .iter()
                .all(|i| i.construction_method == 1 && i.content_type.as_deref() == Some("application/octet-stream"))
        );
        let read = data_reader(&file);
        assert_eq!(EmbeddedMeta::data_of_read(&items[0], &read).unwrap(), CUBE_TEXT.as_bytes());
        assert_eq!(EmbeddedMeta::data_of_read(&items[1], &read).unwrap(), lens.to_vec());
    }

    #[test]
    fn extracts_cube_text() {
        let file = default_meta(&[("Lens profile", &[1u8; 50]), ("Look Control data", CUBE_TEXT.as_bytes())]);
        let lut = EmbeddedMeta::lut_in_data(&file).unwrap().unwrap();
        assert_eq!(lut.data, CUBE_TEXT.as_bytes());
        assert_eq!(lut.name.as_deref(), Some("Look"));
        assert_eq!(lut.source_item_name, "Look Control data");
    }

    #[test]
    fn meta_inside_moov_and_base_offset() {
        let file = mp4(meta_box(&[("LUT", CUBE_TEXT.as_bytes())], 0, 1, 5), true);
        let lut = EmbeddedMeta::lut_in_data(&file).unwrap().unwrap();
        assert_eq!(lut.data, CUBE_TEXT.as_bytes());
    }

    #[test]
    fn infe_version_2() {
        let file = mp4(meta_box(&[("x", CUBE_TEXT.as_bytes())], 2, 1, 0), false);
        let items = EmbeddedMeta::items_in_data(&file).unwrap();
        assert_eq!(items[0].item_type.as_deref(), Some("mime"));
        assert_eq!(items[0].name, "x");
        assert_eq!(EmbeddedMeta::lut_in_data(&file).unwrap().unwrap().data, CUBE_TEXT.as_bytes());
    }

    #[test]
    fn absolute_offsets_method_zero() {
        // Method 0: offsets are file offsets. Put the bytes in mdat and point iloc at them.
        let payload = CUBE_TEXT.as_bytes();
        let mut d = make_box("ftyp", b"isom0000");
        let payload_offset = d.len() as u64 + 8;
        d.extend(make_box("mdat", payload));
        let mut infe_body = vec![0, 0, 0, 0];
        infe_body.extend(be_bytes(1, 2));
        infe_body.extend(be_bytes(0, 2));
        infe_body.extend(cstr("Look"));
        infe_body.extend(cstr("application/octet-stream"));
        let infe = make_box("infe", &infe_body);
        let mut iinf_body = vec![0, 0, 0, 0];
        iinf_body.extend(be_bytes(1, 2));
        iinf_body.extend(infe);
        let iinf = make_box("iinf", &iinf_body);
        let mut iloc_body = vec![1, 0, 0, 0, 0x44, 0x00];
        for (v, n) in [(1, 2), (1, 2), (0, 2), (0, 2), (1, 2), (payload_offset, 4), (payload.len() as u64, 4)] {
            iloc_body.extend(be_bytes(v, n));
        }
        let iloc = make_box("iloc", &iloc_body);
        let mut meta_body = vec![0, 0, 0, 0];
        meta_body.extend(iinf);
        meta_body.extend(iloc);
        d.extend(make_box("meta", &meta_body));
        let items = EmbeddedMeta::items_in_data(&d).unwrap();
        assert_eq!(items[0].construction_method, 0);
        assert_eq!(items[0].file_offset, payload_offset);
        assert_eq!(EmbeddedMeta::lut_in_data(&d).unwrap().unwrap().data, payload);
    }

    #[test]
    fn no_meta_or_no_lut() {
        assert!(EmbeddedMeta::items_in_data(&make_box("ftyp", b"isom0000")).unwrap().is_empty());
        let file = default_meta(&[("Lens profile", &[9u8; 200])]);
        assert_eq!(EmbeddedMeta::lut_in_data(&file), Ok(None));
    }

    #[test]
    fn truncated_data_does_not_crash() {
        let file = default_meta(&[("Look", CUBE_TEXT.as_bytes())]);
        for cut in (40..file.len()).step_by(7) {
            let _ = EmbeddedMeta::lut_in_data(&file[..cut]);
        }
    }

    #[test]
    fn cube_validation() {
        assert!(EmbeddedMeta::looks_like_cube(CUBE_TEXT.as_bytes()));
        assert!(EmbeddedMeta::looks_like_cube(b"LUT_3D_SIZE 33\n0 0 0\n"));
        assert!(!EmbeddedMeta::looks_like_cube(b"hello world\n"));
        assert!(!EmbeddedMeta::looks_like_cube(&[0x45, 0x4c, 0x55, 0x54, 0, 0, 1, 2]));
        assert!(!EmbeddedMeta::looks_like_cube(&[]));
    }

    #[test]
    fn sony_binary_look_converts_to_cube() {
        let file = default_meta(&[("Look Control data", &sony_item(3, "NeutralPaul.cube"))]);
        let lut = EmbeddedMeta::lut_in_data(&file).unwrap().unwrap();
        assert_eq!(lut.name.as_deref(), Some("NeutralPaul.cube"));
        assert!(EmbeddedMeta::looks_like_cube(&lut.data));
        let text = String::from_utf8(lut.data).unwrap();
        let lines: Vec<&str> = text.split('\n').filter(|l| !l.is_empty()).collect();
        assert_eq!(lines[1], "LUT_3D_SIZE 3");
        assert_eq!(lines.len(), 4 + 27);
        assert_eq!(lines[4], "0.000000 0.000000 0.000000");
        assert_eq!(lines[5], "0.500000 0.000000 0.000000"); // red fastest
        assert_eq!(lines[lines.len() - 1], "1.000000 1.000000 1.000000");
    }

    /// Import only needs to know there is a look and its name: same answer as `lut`, without building the cube text.
    #[test]
    fn header_matches_full_lut_without_text() {
        let sony = sony_item(3, "NeutralPaul.cube");
        let sony_unnamed = sony_item(3, "");
        let cases: Vec<Vec<u8>> = vec![
            default_meta(&[("Lens profile", &[1u8; 50]), ("Look Control data", CUBE_TEXT.as_bytes())]),
            default_meta(&[("Look Control data", &sony)]),
            default_meta(&[("Look Control data", &sony_unnamed)]),
            default_meta(&[("Lens profile", &[9u8; 200])]),
            make_box("ftyp", b"isom0000"),
        ];
        for file in &cases {
            let full = EmbeddedMeta::lut_in_data(file).unwrap();
            let header = EmbeddedMeta::lut_header_in_data(file).unwrap();
            assert_eq!(full.is_none(), header.is_none());
            assert_eq!(full.as_ref().map(|l| &l.name), header.as_ref().map(|h| &h.name));
            assert_eq!(full.as_ref().map(|l| &l.source_item_name), header.as_ref().map(|h| &h.source_item_name));
            assert_eq!(full.as_ref().map(|l| l.source_item_bytes), header.as_ref().map(|h| h.source_item_bytes));
        }
        // A Sony block with a broken (non-finite) table is no LUT for either.
        let mut bad = sony_item(3, "Bad");
        let n = bad.len();
        bad[n - 4..].copy_from_slice(&f32::NAN.to_bits().to_be_bytes());
        let file = default_meta(&[("Look Control data", &bad)]);
        assert_eq!(EmbeddedMeta::lut_in_data(&file), Ok(None));
        assert_eq!(EmbeddedMeta::lut_header_in_data(&file), Ok(None));
    }

    #[test]
    fn clip_entry_points_read_a_file() {
        let file = default_meta(&[("Look Control data", CUBE_TEXT.as_bytes())]);
        let path = std::env::temp_dir().join(format!("sq-embedded-lut-{}.mp4", std::process::id()));
        std::fs::write(&path, &file).unwrap();
        let items = EmbeddedMeta::items_in_clip(&path).unwrap();
        assert_eq!(EmbeddedMeta::data_of_in_clip(&items[0], &path).unwrap(), CUBE_TEXT.as_bytes());
        let lut = EmbeddedMeta::lut_in_clip(&path).unwrap().unwrap();
        assert_eq!(lut.data, CUBE_TEXT.as_bytes());
        let header = EmbeddedMeta::lut_header_in_clip(&path).unwrap().unwrap();
        assert_eq!(header.name.as_deref(), Some("Look"));
        std::fs::remove_file(&path).unwrap();
        assert_eq!(EmbeddedMeta::items_in_clip(&path), Err(MediaError::Unreadable));
    }
}
