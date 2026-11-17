// SPDX-License-Identifier: GPL-3.0-or-later
//! An Apple `sbix` font read from its file without loading it: only the small tables stay in memory (the sfnt table
//! directory, `head`, `hhea`, `maxp`, `hmtx`, `cmap` and each strike's glyph offsets); one glyph's PNG is a seek + read.
//! Apple Color Emoji is about 190 MB, nearly all of it PNG data.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Mutex;
use ttf_parser::{Face, RawFaceTables};

/// Biggest single glyph record read (a 160 px emoji PNG is about 10 KB).
const MAX_RECORD: u64 = 16 * 1024 * 1024;

struct Strike {
    ppem: u16,
    /// File offset of the strike's table (the glyph offsets count from here).
    base: u64,
    /// Glyph record offsets from `base`, one more than the glyph count.
    offsets: Vec<u32>,
}

/// One stored PNG with its placement, as `sbix` keeps it.
pub(crate) struct SbixImage {
    pub x: i16,
    pub y: i16,
    pub ppem: u16,
    pub png: Vec<u8>,
}

pub(crate) struct SbixFile {
    file: Mutex<File>,
    head: Vec<u8>,
    hhea: Vec<u8>,
    maxp: Vec<u8>,
    hmtx: Vec<u8>,
    cmap: Vec<u8>,
    strikes: Vec<Strike>,
}

fn be16(d: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes(d.get(at..at + 2)?.try_into().ok()?))
}

fn be32(d: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(d.get(at..at + 4)?.try_into().ok()?))
}

fn read_at(file: &mut File, at: u64, len: u64) -> Option<Vec<u8>> {
    if len > MAX_RECORD * 16 {
        return None;
    }
    file.seek(SeekFrom::Start(at)).ok()?;
    let mut buf = vec![0; len as usize];
    file.read_exact(&mut buf).ok()?;
    Some(buf)
}

/// The table records `(tag, offset, length)` of face `index` of a collection or a single sfnt file.
fn table_directory(file: &mut File, index: u32) -> Option<Vec<([u8; 4], u64, u64)>> {
    let head = read_at(file, 0, 12)?;
    let sfnt_at = if &head[..4] == b"ttcf" {
        let n = be32(&head, 8)?;
        if index >= n {
            return None;
        }
        u64::from(be32(&read_at(file, 12 + 4 * u64::from(index), 4)?, 0)?)
    } else if index == 0 {
        0
    } else {
        return None;
    };
    let hdr = read_at(file, sfnt_at, 12)?;
    let count = usize::from(be16(&hdr, 4)?);
    let recs = read_at(file, sfnt_at + 12, 16 * count as u64)?;
    let (recs, _) = recs.as_chunks::<16>();
    Some(
        recs.iter()
            .filter_map(|r| Some((r[..4].try_into().ok()?, u64::from(be32(r, 8)?), u64::from(be32(r, 12)?))))
            .collect(),
    )
}

impl SbixFile {
    /// Opens face `index` when it is an `sbix` font; `None` for any other font (or an unreadable file).
    pub(crate) fn open(path: &Path, index: u32) -> Option<SbixFile> {
        let mut file = File::open(path).ok()?;
        let dir = table_directory(&mut file, index)?;
        let table = |file: &mut File, tag: &[u8; 4]| -> Option<Vec<u8>> {
            let &(_, off, len) = dir.iter().find(|(t, _, _)| t == tag)?;
            read_at(file, off, len)
        };
        let (sbix_at, sbix_head) = {
            let &(_, off, len) = dir.iter().find(|(t, _, _)| t == b"sbix")?;
            // The header and the strike offset list; the rest of the table is glyph data.
            let n = be32(&read_at(&mut file, off, 8.min(len))?, 4)?;
            (off, read_at(&mut file, off, (8 + 4 * u64::from(n)).min(len))?)
        };
        let head = table(&mut file, b"head")?;
        let hhea = table(&mut file, b"hhea")?;
        let maxp = table(&mut file, b"maxp")?;
        let hmtx = table(&mut file, b"hmtx")?;
        let cmap = table(&mut file, b"cmap")?;
        let glyphs = u64::from(be16(&maxp, 4)?);
        if be16(&sbix_head, 0)? != 1 {
            return None;
        }
        let mut strikes = Vec::new();
        for i in 0..be32(&sbix_head, 4)? as usize {
            let base = sbix_at + u64::from(be32(&sbix_head, 8 + 4 * i)?);
            let raw = read_at(&mut file, base, 4 + 4 * (glyphs + 1))?;
            let (words, _) = raw[4..].as_chunks::<4>();
            let offsets = words.iter().map(|c| u32::from_be_bytes(*c)).collect();
            strikes.push(Strike { ppem: be16(&raw, 0)?, base, offsets });
        }
        (!strikes.is_empty()).then(|| SbixFile { file: Mutex::new(file), head, hhea, maxp, hmtx, cmap, strikes })
    }

    /// Whether face `index` of the file has an `sbix` table (cheap: only the table directory is read).
    pub(crate) fn is_sbix(path: &Path, index: u32) -> bool {
        File::open(path)
            .ok()
            .and_then(|mut f| table_directory(&mut f, index))
            .is_some_and(|d| d.iter().any(|(t, _, _)| t == b"sbix"))
    }

    /// The face over the small tables: character map, metrics, units per em.
    pub(crate) fn face(&self) -> Option<Face<'_>> {
        Face::from_raw_tables(RawFaceTables {
            head: &self.head,
            hhea: &self.hhea,
            maxp: &self.maxp,
            cmap: Some(&self.cmap),
            hmtx: Some(&self.hmtx),
            ..Default::default()
        })
        .ok()
    }

    /// Bytes held in memory.
    #[cfg(test)]
    pub(crate) fn resident_bytes(&self) -> usize {
        let tables = self.head.len() + self.hhea.len() + self.maxp.len() + self.hmtx.len() + self.cmap.len();
        tables + self.strikes.iter().map(|s| s.offsets.len() * 4).sum::<usize>()
    }

    /// The strike ttf-parser's `best_strike` picks: the smallest ppem not below `ppem`, else the biggest.
    fn best_strike(&self, ppem: u16) -> &Strike {
        let (mut idx, mut max) = (0, 0);
        for (i, s) in self.strikes.iter().enumerate() {
            if (ppem <= s.ppem && s.ppem < max) || (ppem > max && s.ppem > max) {
                (idx, max) = (i, s.ppem);
            }
        }
        &self.strikes[idx]
    }

    /// The PNG of `glyph` at the strike for `ppem` (`dupe` records followed), read from the file. `None` when the glyph has
    /// no PNG. With `header_only` the PNG bytes are not read, only checked to exist (`png` is then empty).
    pub(crate) fn image(&self, glyph: u16, ppem: u16, header_only: bool) -> Option<SbixImage> {
        let strike = self.best_strike(ppem);
        let mut glyph = glyph;
        for _ in 0..10 {
            let start = u64::from(*strike.offsets.get(usize::from(glyph))?);
            let end = u64::from(*strike.offsets.get(usize::from(glyph) + 1)?);
            let len = end.checked_sub(start)?.checked_sub(8)?;
            if start == end || len > MAX_RECORD {
                return None;
            }
            let rec = {
                let mut file = self.file.lock().ok()?;
                read_at(&mut file, strike.base + start, if header_only { 8.min(len + 8) } else { len + 8 })?
            };
            match &rec[4..8] {
                b"png " => {
                    let png = if header_only { Vec::new() } else { rec[8..].to_vec() };
                    return Some(SbixImage {
                        x: i16::from_be_bytes([rec[0], rec[1]]),
                        y: i16::from_be_bytes([rec[2], rec[3]]),
                        ppem: strike.ppem,
                        png,
                    });
                }
                b"dupe" if len >= 2 => {
                    glyph = match header_only {
                        false => be16(&rec, 8)?,
                        true => {
                            let mut file = self.file.lock().ok()?;
                            be16(&read_at(&mut file, strike.base + start + 8, 2)?, 0)?
                        }
                    };
                }
                _ => return None,
            }
        }
        None
    }
}
