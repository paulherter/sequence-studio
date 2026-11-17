//! EXIF of still images (Swift `ShootMetadata.readStill`): the original shoot date and the camera model of a JPEG or TIFF.
//! Best-effort: `None` for anything it cannot read.
//! JPEG (APP1 Exif), TIFF, PNG (`eXIf` chunk) and HEIC / AVIF (the `Exif` item of `meta`). The date has no time zone and
//! is read in the local zone, as Swift does (`DateFormatter` with the current zone).

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// What the EXIF block names.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExifInfo {
    /// `DateTimeOriginal`, seconds since 1970-01-01 UTC (the written clock time read in the local zone).
    pub created_unix: Option<f64>,
    /// TIFF `Model`, else `Make`, trimmed.
    pub camera_model: Option<String>,
}

/// Reads the EXIF of a JPEG, TIFF, PNG or HEIC file.
pub fn read_exif(path: &Path) -> ExifInfo {
    let Ok(mut f) = std::fs::File::open(path) else { return ExifInfo::default() };
    let mut head = Vec::new();
    if (&mut f).take(1 << 20).read_to_end(&mut head).is_err() {
        return ExifInfo::default();
    }
    if head.starts_with(&PNG_MAGIC) {
        return png_exif(&mut f).map(|t| parse_exif(&t)).unwrap_or_default();
    }
    if head.get(4..8) == Some(b"ftyp") {
        return heic_exif(&mut f).map(|t| parse_exif(&t)).unwrap_or_default();
    }
    parse_exif(&head)
}

const PNG_MAGIC: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

fn read_at(f: &mut std::fs::File, pos: u64, n: u64) -> Option<Vec<u8>> {
    f.seek(SeekFrom::Start(pos)).ok()?;
    let mut out = Vec::new();
    f.take(n).read_to_end(&mut out).ok()?;
    (out.len() as u64 == n).then_some(out)
}

/// The data of the PNG `eXIf` chunk (a TIFF stream), found by walking the chunks.
fn png_exif(f: &mut std::fs::File) -> Option<Vec<u8>> {
    let end = f.seek(SeekFrom::End(0)).ok()?;
    let mut pos = 8u64;
    while pos + 12 <= end {
        let h = read_at(f, pos, 8)?;
        let len = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
        if &h[4..8] == b"eXIf" {
            return (len <= 1 << 20).then(|| read_at(f, pos + 8, len)).flatten();
        }
        if &h[4..8] == b"IEND" {
            return None;
        }
        pos += 12 + len;
    }
    None
}

fn be(b: &[u8], at: usize, n: usize) -> Option<u64> {
    let s = b.get(at..at + n)?;
    Some(s.iter().fold(0u64, |a, &x| (a << 8) | u64::from(x)))
}

/// The boxes of one level: (kind, body).
fn boxes(mut b: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    while b.len() >= 8 {
        let size = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize;
        let size = if size == 0 { b.len() } else { size };
        if size < 8 || size > b.len() {
            break;
        }
        out.push(([b[4], b[5], b[6], b[7]], &b[8..size]));
        b = &b[size..];
    }
    out
}

/// The TIFF stream of a HEIC / AVIF file: `meta` > `iinf` names the item of type `Exif`, `iloc` says where its bytes are
/// (4 bytes of header offset, then the stream).
fn heic_exif(f: &mut std::fs::File) -> Option<Vec<u8>> {
    let end = f.seek(SeekFrom::End(0)).ok()?;
    let (mut pos, mut meta) = (0u64, None);
    while pos + 8 <= end {
        let h = read_at(f, pos, 8)?;
        let size = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
        if size < 8 || size > end - pos {
            return None;
        }
        if &h[4..8] == b"meta" {
            meta = (size <= 16 << 20).then(|| read_at(f, pos + 8, size - 8)).flatten();
            break;
        }
        pos += size;
    }
    let meta = meta?;
    let all = boxes(meta.get(4..)?);
    let iinf = all.iter().find(|(k, _)| k == b"iinf")?.1;
    let iloc = all.iter().find(|(k, _)| k == b"iloc")?.1;
    // iinf: version, flags, entry count (16 bit, 32 bit from version 1), then `infe` boxes.
    let head = if *iinf.first()? == 0 { 6 } else { 8 };
    let item = boxes(iinf.get(head..)?).into_iter().find_map(|(k, b)| {
        if &k != b"infe" {
            return None;
        }
        let v = *b.first()?;
        let (id, ty) = match v {
            2 => (be(b, 4, 2)?, b.get(8..12)?),
            3 => (be(b, 4, 4)?, b.get(10..14)?),
            _ => return None,
        };
        (ty == b"Exif").then_some(id)
    })?;
    // iloc: version, flags, offset/length sizes, base/index sizes, item count, then the items.
    let v = *iloc.first()?;
    let (osz, lsz) = ((iloc.get(4)? >> 4) as usize, (iloc.get(4)? & 15) as usize);
    let (bsz, isz) = ((iloc.get(5)? >> 4) as usize, if v == 1 || v == 2 { (iloc.get(5)? & 15) as usize } else { 0 });
    let (count, mut at) = if v < 2 { (be(iloc, 6, 2)?, 8) } else { (be(iloc, 6, 4)?, 10) };
    for _ in 0..count {
        let id = if v < 2 {
            let x = be(iloc, at, 2)?;
            at += 2;
            x
        } else {
            let x = be(iloc, at, 4)?;
            at += 4;
            x
        };
        let method = if v == 1 || v == 2 {
            let m = be(iloc, at, 2)? & 15;
            at += 2;
            m
        } else {
            0
        };
        at += 2; // data reference index
        let base = be(iloc, at, bsz).unwrap_or(0);
        at += bsz;
        let extents = be(iloc, at, 2)?;
        at += 2;
        let (mut first, mut len) = (None, 0u64);
        for _ in 0..extents {
            at += isz;
            let o = be(iloc, at, osz)?;
            at += osz;
            let l = be(iloc, at, lsz)?;
            at += lsz;
            if first.is_none() {
                (first, len) = (Some(o), l);
            }
        }
        if id == item && method == 0 {
            let data = read_at(f, base + first?, len.min(1 << 20))?;
            let skip = 4 + be(&data, 0, 4)? as usize;
            return data.get(skip..).map(<[u8]>::to_vec);
        }
    }
    None
}

/// The EXIF of a JPEG (`FFD8` ... APP1 `Exif`) or a bare TIFF stream.
pub fn parse_exif(bytes: &[u8]) -> ExifInfo {
    let tiff = if bytes.starts_with(&[0xFF, 0xD8]) { jpeg_exif(bytes) } else { Some(bytes) };
    tiff.and_then(parse_tiff).unwrap_or_default()
}

fn jpeg_exif(b: &[u8]) -> Option<&[u8]> {
    let mut pos = 2;
    while pos + 4 <= b.len() && b[pos] == 0xFF {
        let marker = b[pos + 1];
        if marker == 0xDA || marker == 0xD9 {
            return None;
        }
        let len = usize::from(u16::from_be_bytes([b[pos + 2], b[pos + 3]]));
        let body = b.get(pos + 4..pos + 2 + len)?;
        if marker == 0xE1 && body.starts_with(b"Exif\0\0") {
            return Some(&body[6..]);
        }
        pos += 2 + len;
    }
    None
}

struct Tiff<'a> {
    b: &'a [u8],
    big: bool,
}

impl Tiff<'_> {
    fn u16(&self, at: usize) -> Option<u16> {
        let v: [u8; 2] = self.b.get(at..at + 2)?.try_into().ok()?;
        Some(if self.big { u16::from_be_bytes(v) } else { u16::from_le_bytes(v) })
    }
    fn u32(&self, at: usize) -> Option<u32> {
        let v: [u8; 4] = self.b.get(at..at + 4)?.try_into().ok()?;
        Some(if self.big { u32::from_be_bytes(v) } else { u32::from_le_bytes(v) })
    }
    /// The ASCII value of tag `tag` in the IFD at `ifd`, or its offset when `pointer`.
    fn entry(&self, ifd: usize, tag: u16) -> Option<(usize, usize)> {
        let n = usize::from(self.u16(ifd)?);
        (0..n).find_map(|i| {
            let e = ifd + 2 + i * 12;
            (self.u16(e)? == tag).then(|| (self.u32(e + 4).unwrap_or(0) as usize, e + 8))
        })
    }
    fn text(&self, ifd: usize, tag: u16) -> Option<String> {
        let (count, slot) = self.entry(ifd, tag)?;
        let at = if count <= 4 { slot } else { self.u32(slot)? as usize };
        let raw = self.b.get(at..at + count)?;
        Some(String::from_utf8_lossy(raw).trim_matches(|c: char| c.is_whitespace() || c.is_control()).to_string())
    }
}

fn parse_tiff(b: &[u8]) -> Option<ExifInfo> {
    let big = match b.get(..2)? {
        b"MM" => true,
        b"II" => false,
        _ => return None,
    };
    let t = Tiff { b, big };
    if t.u16(2)? != 42 {
        return None;
    }
    let ifd0 = t.u32(4)? as usize;
    let model =
        t.text(ifd0, 0x0110).filter(|s| !s.is_empty()).or_else(|| t.text(ifd0, 0x010F).filter(|s| !s.is_empty()));
    let date = t
        .entry(ifd0, 0x8769)
        .and_then(|(_, slot)| t.u32(slot))
        .and_then(|exif| t.text(exif as usize, 0x9003))
        .and_then(|s| parse_date(&s));
    Some(ExifInfo { created_unix: date, camera_model: model })
}

/// `yyyy:MM:dd HH:mm:ss` read as a clock time in the local zone, as seconds since 1970 UTC.
fn parse_date(s: &str) -> Option<f64> {
    let n: Vec<i64> = s.split([':', ' ']).map(|p| p.parse().ok()).collect::<Option<_>>()?;
    let [y, mo, d, h, mi, se] = n[..] else { return None };
    local_unix(y, mo, d, h, mi, se)
}

/// A civil date and time in the local zone as seconds since 1970 UTC (the earlier one when a clock change repeats it).
fn local_unix(y: i64, mo: i64, d: i64, h: i64, mi: i64, se: i64) -> Option<f64> {
    use chrono::TimeZone;
    let t = chrono::Local
        .with_ymd_and_hms(
            i32::try_from(y).ok()?,
            u32::try_from(mo).ok()?,
            u32::try_from(d).ok()?,
            u32::try_from(h).ok()?,
            u32::try_from(mi).ok()?,
            u32::try_from(se).ok()?,
        )
        .earliest()?;
    Some(t.timestamp() as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A little-endian TIFF: IFD0 with Make, Model and the Exif pointer; the Exif IFD with DateTimeOriginal.
    fn tiff() -> Vec<u8> {
        let make = b"ACME\0";
        let model = b"Cam One \0";
        let date = b"2024:03:05 12:30:15\0";
        let mut b = vec![b'I', b'I', 42, 0, 8, 0, 0, 0];
        // IFD0 at 8: 3 entries = 2 + 36 + 4 bytes, strings after.
        let strings_at = 8 + 2 + 36 + 4;
        let exif_at = strings_at + make.len() + model.len();
        let date_at = exif_at + 2 + 12 + 4;
        b.extend_from_slice(&3u16.to_le_bytes());
        let entry = |tag: u16, kind: u16, count: u32, value: u32| {
            let mut e = tag.to_le_bytes().to_vec();
            e.extend_from_slice(&kind.to_le_bytes());
            e.extend_from_slice(&count.to_le_bytes());
            e.extend_from_slice(&value.to_le_bytes());
            e
        };
        b.extend(entry(0x010F, 2, make.len() as u32, strings_at as u32));
        b.extend(entry(0x0110, 2, model.len() as u32, (strings_at + make.len()) as u32));
        b.extend(entry(0x8769, 4, 1, exif_at as u32));
        b.extend_from_slice(&[0; 4]);
        b.extend_from_slice(make);
        b.extend_from_slice(model);
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend(entry(0x9003, 2, date.len() as u32, date_at as u32));
        b.extend_from_slice(&[0; 4]);
        b.extend_from_slice(date);
        b
    }

    #[test]
    fn a_tiff_gives_model_and_original_date() {
        let e = parse_exif(&tiff());
        assert_eq!(e.camera_model.as_deref(), Some("Cam One"));
        // The written clock time, read in the local zone (Swift `DateFormatter`).
        assert_eq!(e.created_unix, local_unix(2024, 3, 5, 12, 30, 15));
        assert!(e.created_unix.is_some());
    }

    #[test]
    fn a_jpeg_carries_the_same_block_in_app1() {
        let t = tiff();
        let mut j = vec![0xFF, 0xD8, 0xFF, 0xE1];
        j.extend_from_slice(&((t.len() + 8) as u16).to_be_bytes());
        j.extend_from_slice(b"Exif\0\0");
        j.extend_from_slice(&t);
        j.extend_from_slice(&[0xFF, 0xDA, 0, 2]);
        assert_eq!(parse_exif(&j), parse_exif(&t));
        assert!(parse_exif(&j).camera_model.is_some());
    }

    #[test]
    fn junk_reads_as_nothing() {
        assert_eq!(parse_exif(b"not an image"), ExifInfo::default());
        assert_eq!(parse_exif(&[0xFF, 0xD8, 0xFF, 0xD9]), ExifInfo::default());
        assert_eq!(parse_date("2024:13:05 00:00:00"), None);
    }

    #[test]
    fn the_date_is_read_in_the_local_zone() {
        // The same clock time differs from its UTC reading by exactly the zone's offset.
        let local = parse_date("2024:07:01 12:00:00").unwrap();
        let utc = 1_719_835_200.0;
        use chrono::{Local, Offset, TimeZone};
        let offset = f64::from(Local.timestamp_opt(local as i64, 0).unwrap().offset().fix().local_minus_utc());
        assert_eq!(local, utc - offset);
    }

    fn file(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-exif-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let p = dir.join(name);
        std::fs::write(&p, bytes).unwrap_or_default();
        p
    }

    fn chunk(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = (body.len() as u32).to_be_bytes().to_vec();
        v.extend(kind);
        v.extend(body);
        v.extend([0u8; 4]); // the crc is not read
        v
    }

    #[test]
    fn a_png_carries_the_block_in_its_exif_chunk() {
        let mut png = PNG_MAGIC.to_vec();
        png.extend(chunk(b"IHDR", &[0; 13]));
        png.extend(chunk(b"IDAT", &[1, 2, 3]));
        png.extend(chunk(b"eXIf", &tiff()));
        png.extend(chunk(b"IEND", &[]));
        let e = read_exif(&file("a.png", &png));
        assert_eq!(e, parse_exif(&tiff()));
        assert_eq!(e.camera_model.as_deref(), Some("Cam One"));
    }

    fn bx(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend(kind);
        v.extend(body);
        v
    }

    #[test]
    fn a_heic_names_its_exif_item_in_iinf_and_iloc() {
        // ftyp, meta { iinf [infe v2 id 7 'Exif'], iloc v0 (4-byte offsets and lengths) }, mdat with 4 + tiff bytes.
        let ftyp = bx(b"ftyp", b"heic\0\0\0\0mif1");
        let mut infe = vec![2, 0, 0, 0, 0, 7, 0, 0];
        infe.extend(b"Exif");
        infe.push(0);
        let mut iinf = vec![0, 0, 0, 0, 0, 1];
        iinf.extend(bx(b"infe", &infe));
        let payload = {
            let mut p = 0u32.to_be_bytes().to_vec(); // the TIFF header follows at once
            p.extend(tiff());
            p
        };
        let build = |offset: u32| {
            // iloc v0: sizes 4/4, base 0/index 0, count 1, item 7, dref 0, base (none), 1 extent.
            let mut iloc = vec![0, 0, 0, 0, 0x44, 0x00, 0, 1, 0, 7, 0, 0, 0, 1];
            iloc.extend(offset.to_be_bytes());
            iloc.extend((payload.len() as u32).to_be_bytes());
            let mut meta = vec![0, 0, 0, 0];
            meta.extend(bx(b"iinf", &iinf));
            meta.extend(bx(b"iloc", &iloc));
            let mut file = ftyp.clone();
            file.extend(bx(b"meta", &meta));
            file
        };
        let head = build(0).len();
        let mut heic = build((head + 8) as u32);
        heic.extend(bx(b"mdat", &payload));
        let e = read_exif(&file("a.heic", &heic));
        assert_eq!(e.camera_model.as_deref(), Some("Cam One"));
        assert!(e.created_unix.is_some());
    }
}
