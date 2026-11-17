// Swift: SourceTimecode.swift
//! The timecode a camera recorded with the footage: time of day of the first frame, as an exact rational.
//!
//! Sources, in this order: the QuickTime `tmcd` track (read at its own rate, which can differ from the picture's, and with
//! its drop-frame flag), Sony's `rtmd` track (cameras without `tmcd`), and the Broadcast Wave `bext` chunk (sample count
//! since midnight, audio files).

use sq_core_time::Time;
use sq_core_time::cmx_timecode::CmxTimecode;
use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::ops::Range;
use std::path::Path;

/// Where a timecode was read from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Source {
    Tmcd,
    Rtmd,
    Bext,
}

/// The timecode a camera recorded with the footage.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SourceTimecode {
    /// Time of day of the first frame / sample.
    pub origin: Time,
    /// The clock the timecode counts on (the tmcd track's own frame duration, 1001/30000 for 29.97). None for audio-only
    /// sources, which count samples.
    pub frame_duration: Option<Time>,
    pub drop_frame: bool,
    pub source: Source,
}

const MAX_MOOV: u64 = 64 << 20;

struct TrackSample {
    format: String,
    description: Vec<u8>,
    sample: Vec<u8>,
}

impl SourceTimecode {
    /// Frames since midnight on `fd` (default: the timecode's own clock), rounded to the nearest frame.
    pub fn frame_count(&self, fd: Option<Time>) -> Option<i64> {
        let fd = fd.or(self.frame_duration)?;
        if fd <= Time::ZERO || self.origin < Time::ZERO {
            return None;
        }
        let n = i128::from(self.origin.value()) * i128::from(fd.timescale());
        let d = i128::from(self.origin.timescale()) * i128::from(fd.value());
        let q = (2 * n + d) / (2 * d);
        Some(i64::try_from(q).unwrap_or(if q < 0 { i64::MIN } else { i64::MAX }))
    }

    /// HH:MM:SS:FF (`;` before the frames for drop frame). `fd`: the clock to show an audio source on.
    pub fn label(&self, fd: Option<Time>) -> Option<String> {
        let clock = self.frame_duration.or(fd)?;
        let frames = self.frame_count(Some(clock))?;
        let nominal = CmxTimecode::from_frame_duration(clock, false).nominal_rate();
        let drop = if self.frame_duration.is_some() {
            self.drop_frame
        } else {
            CmxTimecode::from_frame_duration(clock, true).drop_frame()
        };
        Some(CmxTimecode::new(nominal, drop).string(frames))
    }

    // MARK: Reading

    /// The file's source timecode: tmcd, else rtmd (MP4/MOV), or bext (WAV/BWF). None = the file carries none.
    pub fn read(path: &Path) -> io::Result<Option<SourceTimecode>> {
        let mut fh = File::open(path)?;
        let head = read_up_to(&mut fh, 4)?;
        if head.len() != 4 {
            return Ok(None);
        }
        if head == *b"RIFF" || head == *b"RF64" {
            return read_bext(&mut fh);
        }
        read_mp4(&mut fh)
    }

    /// `description`: the whole tmcd sample entry; `sample`: the first sample (a 32-bit frame counter).
    pub(crate) fn parse_tmcd(description: &[u8], sample: &[u8]) -> Option<SourceTimecode> {
        // size(4) 'tmcd'(4) reserved(6) dataRef(2) | reserved(4) flags(4) timescale(4) frameDuration(4) frames(1) reserved(1)
        if description.len() < 34 || sample.len() < 4 {
            return None;
        }
        let flags = be32(description, 20);
        let timescale = i64::from(be32(description, 24));
        let duration = i64::from(be32(description, 28));
        if timescale <= 0 || duration <= 0 {
            return None;
        }
        let raw = be32(sample, 0);
        let counter: i64 = if flags & 0x4 != 0 { i64::from(raw as i32) } else { i64::from(raw) };
        if counter < 0 {
            return None;
        }
        // Frame counter times the track's own frame duration: 30000/1001 stays exact, not 30.
        let origin = Time::reducing(i128::from(counter) * i128::from(duration), i128::from(timescale));
        Some(SourceTimecode {
            origin,
            frame_duration: Some(Time::new(duration, timescale)),
            drop_frame: flags & 0x1 != 0,
            source: Source::Tmcd,
        })
    }

    /// Sony's rtmd sample: a 0x1c-byte header whose bytes 0x0d, 0x0e, 0x0f and 0x11 are read as hours, minutes, seconds and
    /// frame in BCD (layout after ExifTool's notes; unverified on camera files). Only digits that form a valid time are
    /// taken, so a header of another layout gives None rather than a wrong timecode. `clock`: the picture's frame duration
    /// (the header does not carry it); None = nothing is read.
    pub(crate) fn parse_rtmd(sample: &[u8], clock: Option<Time>) -> Option<SourceTimecode> {
        let clock = clock?;
        if clock <= Time::ZERO || sample.len() < 0x1c || usize::from(sample[0]) << 8 | usize::from(sample[1]) != 0x1c {
            return None;
        }
        fn bcd(v: u8) -> Option<i64> {
            let (hi, lo) = (i64::from(v >> 4), i64::from(v & 0xF));
            (hi < 10 && lo < 10).then_some(hi * 10 + lo)
        }
        let nominal = CmxTimecode::from_frame_duration(clock, false).nominal_rate();
        let (h, m, s, f) = (bcd(sample[0x0d])?, bcd(sample[0x0e])?, bcd(sample[0x0f])?, bcd(sample[0x11])?);
        if h >= 24 || m >= 60 || s >= 60 || f >= nominal {
            return None;
        }
        let frames = (h * 3600 + m * 60 + s) * nominal + f;
        Some(SourceTimecode {
            origin: Time::reducing(i128::from(frames) * i128::from(clock.value()), i128::from(clock.timescale())),
            frame_duration: Some(clock),
            drop_frame: false,
            source: Source::Rtmd,
        })
    }
}

/// Reads up to `n` bytes; fewer only at the end of the file (like `FileHandle.read(upToCount:)`).
fn read_up_to(fh: &mut File, n: u64) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    fh.take(n).read_to_end(&mut out)?;
    Ok(out)
}

fn read_mp4(fh: &mut File) -> io::Result<Option<SourceTimecode>> {
    let end = fh.seek(SeekFrom::End(0))?;
    let mut pos: u64 = 0;
    while pos + 8 <= end {
        fh.seek(SeekFrom::Start(pos))?;
        let hb = read_up_to(fh, 8)?;
        if hb.len() != 8 {
            return Ok(None);
        }
        let mut size = u64::from(be32(&hb, 0));
        let mut header: u64 = 8;
        if size == 1 {
            let l = read_up_to(fh, 8)?;
            if l.len() != 8 {
                return Ok(None);
            }
            size = l.iter().fold(0u64, |a, &b| a << 8 | u64::from(b));
            header = 16;
        } else if size == 0 {
            size = end - pos;
        }
        if size < header || size > end - pos {
            return Ok(None);
        }
        if &hb[4..8] == b"moov" {
            if size - header > MAX_MOOV {
                return Ok(None);
            }
            fh.seek(SeekFrom::Start(pos + header))?;
            let moov = read_up_to(fh, size - header)?;
            return from_moov(&moov, fh);
        }
        pos += size;
    }
    Ok(None)
}

/// tmcd and rtmd tracks of a `moov` body, preferring tmcd.
fn from_moov(moov: &[u8], fh: &mut File) -> io::Result<Option<SourceTimecode>> {
    let mut found: HashMap<String, TrackSample> = HashMap::new();
    for trak in boxes(moov, 0..moov.len(), "trak", 0) {
        let Some(t) = track_sample(moov, trak, fh)? else { continue };
        if found.contains_key(&t.format) {
            continue;
        }
        found.insert(t.format.clone(), t);
    }
    if let Some(t) = found.get("tmcd")
        && let Some(tc) = SourceTimecode::parse_tmcd(&t.description, &t.sample)
    {
        return Ok(Some(tc));
    }
    if let Some(t) = found.get("rtmd")
        && let Some(tc) = SourceTimecode::parse_rtmd(&t.sample, picture_clock(moov))
    {
        return Ok(Some(tc));
    }
    Ok(None)
}

/// Frame duration of the first video track (mdhd timescale, first stts delta).
fn picture_clock(d: &[u8]) -> Option<Time> {
    for trak in boxes(d, 0..d.len(), "trak", 0) {
        let Some(mdia) = boxes(d, trak, "mdia", 0).into_iter().next() else { continue };
        let Some(hdlr) = boxes(d, mdia.clone(), "hdlr", 0).into_iter().next().filter(|h| h.len() >= 12) else {
            continue;
        };
        if &d[hdlr.start + 8..hdlr.start + 12] != b"vide" {
            continue;
        }
        let Some(mdhd) = boxes(d, mdia.clone(), "mdhd", 0).into_iter().next().filter(|m| m.len() >= 24) else {
            continue;
        };
        let Some(minf) = boxes(d, mdia, "minf", 0).into_iter().next() else { continue };
        let Some(stbl) = boxes(d, minf, "stbl", 0).into_iter().next() else { continue };
        let Some(stts) = boxes(d, stbl, "stts", 0).into_iter().next().filter(|s| s.len() >= 16) else { continue };
        let at = if d[mdhd.start] == 1 { 20 } else { 12 };
        let scale = i64::from(be32(d, mdhd.start + at));
        let delta = i64::from(be32(d, stts.start + 12));
        if scale > 0 && delta > 0 {
            return Some(Time::new(delta, scale));
        }
    }
    None
}

fn track_sample(d: &[u8], trak: Range<usize>, fh: &mut File) -> io::Result<Option<TrackSample>> {
    let Some(mdia) = boxes(d, trak, "mdia", 0).into_iter().next() else { return Ok(None) };
    let Some(minf) = boxes(d, mdia, "minf", 0).into_iter().next() else { return Ok(None) };
    let Some(stbl) = boxes(d, minf, "stbl", 0).into_iter().next() else { return Ok(None) };
    let Some(stsd) = boxes(d, stbl.clone(), "stsd", 8).into_iter().next().filter(|s| s.len() >= 16) else {
        return Ok(None);
    };
    let entry = stsd.start;
    let size = be32(d, entry) as usize;
    if size < 16 || entry + size > d.len() {
        return Ok(None);
    }
    let format = String::from_utf8_lossy(&d[entry + 4..entry + 8]).into_owned();
    if format != "tmcd" && format != "rtmd" {
        return Ok(None);
    }
    let mut offset: Option<u64> = None;
    if let Some(co) = boxes(d, stbl.clone(), "stco", 4).into_iter().next().filter(|c| c.len() >= 8)
        && be32(d, co.start) > 0
    {
        offset = Some(u64::from(be32(d, co.start + 4)));
    } else if let Some(co) = boxes(d, stbl.clone(), "co64", 4).into_iter().next().filter(|c| c.len() >= 12)
        && be32(d, co.start) > 0
    {
        offset = Some(u64::from(be32(d, co.start + 4)) << 32 | u64::from(be32(d, co.start + 8)));
    }
    let Some(offset) = offset else { return Ok(None) };
    let mut length: usize = if format == "tmcd" { 4 } else { 4096 };
    if let Some(sz) = boxes(d, stbl, "stsz", 4).into_iter().next().filter(|s| s.len() >= 4) {
        let fixed = be32(d, sz.start) as usize;
        let first = if fixed != 0 {
            fixed
        } else if sz.len() >= 12 {
            be32(d, sz.start + 8) as usize
        } else {
            0
        };
        if first > 0 {
            length = first.min(65_536);
        }
    }
    fh.seek(SeekFrom::Start(offset))?;
    let s = read_up_to(fh, length as u64)?;
    if s.is_empty() {
        return Ok(None);
    }
    Ok(Some(TrackSample { format, description: d[entry..entry + size].to_vec(), sample: s }))
}

// MARK: bext

fn read_bext(fh: &mut File) -> io::Result<Option<SourceTimecode>> {
    let end = fh.seek(SeekFrom::End(0))?;
    let mut pos: u64 = 12;
    let mut sample_rate: Option<i64> = None;
    let mut reference: Option<u64> = None;
    while pos + 8 <= end && (sample_rate.is_none() || reference.is_none()) {
        fh.seek(SeekFrom::Start(pos))?;
        let b = read_up_to(fh, 8)?;
        if b.len() != 8 {
            break;
        }
        let id = String::from_utf8_lossy(&b[0..4]).into_owned();
        let size = u64::from(le32(&b, 4));
        if id == "fmt " && size >= 8 {
            let f = read_up_to(fh, 8)?;
            if f.len() == 8 {
                sample_rate = Some(i64::from(le32(&f, 4)));
            }
        } else if id == "bext" && size >= 346 {
            let x = read_up_to(fh, 346)?;
            if x.len() == 346 {
                reference = Some(u64::from(le32(&x, 338)) | u64::from(le32(&x, 342)) << 32);
            }
        }
        if id == "data" && pos + 8 + size > end {
            break;
        }
        pos += 8 + size + (size & 1);
    }
    let (Some(sample_rate), Some(reference)) = (sample_rate, reference) else { return Ok(None) };
    if sample_rate <= 0 || reference > i64::MAX as u64 {
        return Ok(None);
    }
    Ok(Some(SourceTimecode {
        origin: Time::new(reference as i64, sample_rate),
        frame_duration: None,
        drop_frame: false,
        source: Source::Bext,
    }))
}

// MARK: Bytes

fn be32(b: &[u8], i: usize) -> u32 {
    u32::from(b[i]) << 24 | u32::from(b[i + 1]) << 16 | u32::from(b[i + 2]) << 8 | u32::from(b[i + 3])
}

fn le32(b: &[u8], i: usize) -> u32 {
    u32::from(b[i + 3]) << 24 | u32::from(b[i + 2]) << 16 | u32::from(b[i + 1]) << 8 | u32::from(b[i])
}

/// Body ranges of the child boxes called `name` inside `range`; `skip_full_box` bytes at the start of a body (version and
/// flags, entry count) are skipped so the range starts at the payload.
fn boxes(d: &[u8], range: Range<usize>, name: &str, skip_full_box: usize) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut p = range.start;
    while p + 8 <= range.end {
        let size = be32(d, p) as usize;
        if size < 8 || p + size > range.end {
            break;
        }
        if &d[p + 4..p + 8] == name.as_bytes() && 8 + skip_full_box <= size {
            out.push(p + 8 + skip_full_box..p + size);
        }
        p += size;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn u32b(v: u32) -> Vec<u8> {
        v.to_be_bytes().to_vec()
    }
    fn le(v: u32) -> Vec<u8> {
        v.to_le_bytes().to_vec()
    }
    fn bx(kind: &str, body: &[u8]) -> Vec<u8> {
        [u32b(body.len() as u32 + 8), kind.as_bytes().to_vec(), body.to_vec()].concat()
    }
    fn full(kind: &str, body: &[u8]) -> Vec<u8> {
        bx(kind, &[&[0u8, 0, 0, 0][..], body].concat())
    }

    fn tmcd_entry(flags: u32, timescale: u32, duration: u32, frames: u8) -> Vec<u8> {
        let body =
            [vec![0u8; 6], vec![0, 1], u32b(0), u32b(flags), u32b(timescale), u32b(duration), vec![frames, 0]].concat();
        bx("tmcd", &body)
    }

    fn video(timescale: u32, delta: u32) -> Vec<u8> {
        let mdhd = full("mdhd", &[u32b(0), u32b(0), u32b(timescale), u32b(0), vec![0, 0, 0, 0]].concat());
        let hdlr = full("hdlr", &[u32b(0), b"vide".to_vec(), vec![0u8; 13]].concat());
        let stts = full("stts", &[u32b(1), u32b(10), u32b(delta)].concat());
        bx("trak", &bx("mdia", &[mdhd, hdlr, bx("minf", &bx("stbl", &stts))].concat()))
    }

    fn data_track(format: &[u8], offset: u32, size: u32) -> Vec<u8> {
        let stsd = full("stsd", &[u32b(1), format.to_vec()].concat());
        let stco = full("stco", &[u32b(1), u32b(offset)].concat());
        let stsz = full("stsz", &[u32b(0), u32b(1), u32b(size)].concat());
        bx("trak", &bx("mdia", &bx("minf", &bx("stbl", &[stsd, stco, stsz].concat()))))
    }

    struct TempFile(std::path::PathBuf);
    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn write(d: &[u8], ext: &str) -> TempFile {
        static N: AtomicU32 = AtomicU32::new(0);
        let p = std::env::temp_dir().join(format!(
            "sqtc-{}-{}.{ext}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        assert!(std::fs::write(&p, d).is_ok());
        TempFile(p)
    }

    /// mdat first (so offsets are known), then moov with the tracks.
    fn mp4(samples: &[Vec<u8>], tracks: impl Fn(&[u32]) -> Vec<u8>) -> TempFile {
        let mut mdat = Vec::new();
        let mut offsets = Vec::new();
        for s in samples {
            offsets.push(8 + mdat.len() as u32);
            mdat.extend_from_slice(s);
        }
        write(&[bx("mdat", &mdat), bx("moov", &tracks(&offsets))].concat(), "mov")
    }

    fn read(f: &TempFile) -> Option<SourceTimecode> {
        SourceTimecode::read(&f.0).unwrap_or(None)
    }

    #[test]
    fn tmcd_reads_at_its_own_rate_and_drop_flag() {
        // Video 30 fps timescale 3000/100; the timecode track counts 30000/1001 with drop frame.
        let f =
            mp4(&[u32b(1800)], |o| [video(3000, 100), data_track(&tmcd_entry(1, 30000, 1001, 30), o[0], 4)].concat());
        let tc = read(&f).unwrap_or_else(|| panic!("timecode"));
        assert!(tc.source == Source::Tmcd && tc.drop_frame);
        assert_eq!(tc.frame_duration, Some(Time::new(1001, 30000)));
        assert_eq!(tc.origin, Time::new(1800 * 1001, 30000)); // exact, not 1800/30
        assert_eq!(tc.label(None).as_deref(), Some("00:01:00;02")); // drop frame skips :00 and :01 at the minute
    }

    #[test]
    fn tmcd_non_drop_and_twenty_four() {
        let f = mp4(&[u32b(24 * 3600 * 2 + 12)], |o| data_track(&tmcd_entry(0, 24, 1, 24), o[0], 4));
        let tc = read(&f).unwrap_or_else(|| panic!("timecode"));
        assert_eq!(tc.label(None).as_deref(), Some("02:00:00:12"));
        assert!(!tc.drop_frame);
        assert_eq!(tc.origin, Time::new(7200 * 24 + 12, 24));
    }

    #[test]
    fn drop_frame_boundaries() {
        let label = |frames: i64| {
            SourceTimecode {
                origin: Time::new(frames * 1001, 30000),
                frame_duration: Some(Time::new(1001, 30000)),
                drop_frame: true,
                source: Source::Tmcd,
            }
            .label(None)
        };
        assert_eq!(label(0).as_deref(), Some("00:00:00;00"));
        assert_eq!(label(1799).as_deref(), Some("00:00:59;29"));
        assert_eq!(label(1800).as_deref(), Some("00:01:00;02"));
        assert_eq!(label(17981).as_deref(), Some("00:09:59;29")); // 10 minutes hold 17982 frames
        assert_eq!(label(17982).as_deref(), Some("00:10:00;00")); // every tenth minute keeps :00
        assert_eq!(label(17982 + 1800).as_deref(), Some("00:11:00;02"));
        assert_eq!(label(17982 * 6).as_deref(), Some("01:00:00;00")); // an hour is 107892 frames
    }

    #[test]
    fn negative_counter_flag_is_not_taken() {
        let f = mp4(&[u32b(u32::MAX)], |o| data_track(&tmcd_entry(4, 25, 1, 25), o[0], 4));
        assert_eq!(read(&f), None);
    }

    fn rtmd_sample(h: u8, m: u8, s: u8, f: u8) -> Vec<u8> {
        let mut b = vec![0u8; 0x20];
        b[0] = 0;
        b[1] = 0x1c;
        b[0x0d] = h;
        b[0x0e] = m;
        b[0x0f] = s;
        b[0x11] = f;
        b
    }

    #[test]
    fn rtmd_used_when_no_tmcd() {
        let sample = rtmd_sample(0x10, 0x25, 0x30, 0x07);
        let f = mp4(std::slice::from_ref(&sample), |o| {
            [video(25000, 1000), data_track(&bx("rtmd", &[0u8; 16]), o[0], sample.len() as u32)].concat()
        });
        let tc = read(&f).unwrap_or_else(|| panic!("timecode"));
        assert!(tc.source == Source::Rtmd && tc.label(None).as_deref() == Some("10:25:30:07"));
        assert_eq!(tc.origin, Time::new(((10 * 3600 + 25 * 60 + 30) * 25 + 7) * 1000, 25000));
    }

    #[test]
    fn rtmd_with_implausible_digits_gives_nothing() {
        let clock = Some(Time::new(1, 25));
        assert_eq!(SourceTimecode::parse_rtmd(&rtmd_sample(0x2A, 0, 0, 0), clock), None);
        assert_eq!(SourceTimecode::parse_rtmd(&rtmd_sample(0x23, 0x61, 0, 0), clock), None);
        assert_eq!(SourceTimecode::parse_rtmd(&rtmd_sample(0x01, 0, 0, 0x30), clock), None);
    }

    #[test]
    fn tmcd_wins_over_rtmd() {
        let sample = rtmd_sample(0x10, 0, 0, 0);
        let f = mp4(&[sample.clone(), u32b(25 * 60)], |o| {
            [
                video(25000, 1000),
                data_track(&bx("rtmd", &[0u8; 16]), o[0], sample.len() as u32),
                data_track(&tmcd_entry(0, 25, 1, 25), o[1], 4),
            ]
            .concat()
        });
        let tc = read(&f).unwrap_or_else(|| panic!("timecode"));
        assert!(tc.source == Source::Tmcd && tc.label(None).as_deref() == Some("00:01:00:00"));
    }

    #[test]
    fn file_without_timecode_is_none() {
        let f = mp4(&[], |_| video(25000, 1000));
        assert_eq!(read(&f), None);
    }

    fn chunk(id: &str, body: &[u8]) -> Vec<u8> {
        [
            id.as_bytes().to_vec(),
            le(body.len() as u32),
            body.to_vec(),
            if body.len() % 2 == 1 { vec![0] } else { vec![] },
        ]
        .concat()
    }

    #[test]
    fn bext_time_reference_is_samples_since_midnight() {
        let mut bext = vec![0u8; 602];
        let reference: u64 = 48_000 * 3600 * 14 + 48_000 * 90; // 14:01:30
        bext[338..342].copy_from_slice(&le((reference & 0xFFFF_FFFF) as u32));
        bext[342..346].copy_from_slice(&le((reference >> 32) as u32));
        let fmt = [le(0x0001_0001), le(48_000), le(96_000), vec![2, 0, 16, 0]].concat(); // PCM mono 16 bit
        let payload =
            [b"WAVE".to_vec(), chunk("fmt ", &fmt), chunk("bext", &bext), chunk("data", &[0, 0, 0, 0])].concat();
        let f = write(&[b"RIFF".to_vec(), le(payload.len() as u32), payload].concat(), "wav");
        let tc = read(&f).unwrap_or_else(|| panic!("timecode"));
        assert!(tc.source == Source::Bext && tc.origin == Time::new(reference as i64, 48_000));
        assert_eq!(tc.label(Some(Time::new(1, 25))).as_deref(), Some("14:01:30:00"));
        assert_eq!(tc.label(None), None); // audio alone has no frame clock
    }

    #[test]
    fn wav_without_bext_is_none() {
        let fmt = [le(0x0001_0001), le(44_100), le(88_200), vec![2, 0, 16, 0]].concat();
        let payload = [b"WAVE".to_vec(), b"fmt ".to_vec(), le(fmt.len() as u32), fmt].concat();
        let f = write(&[b"RIFF".to_vec(), le(payload.len() as u32), payload].concat(), "wav");
        assert_eq!(read(&f), None);
    }
}
