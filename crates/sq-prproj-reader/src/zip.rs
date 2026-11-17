// SPDX-License-Identifier: GPL-3.0-or-later
//! Minimal ZIP reader: port of `PRZip` (stored and deflated entries through the central directory; no ZIP64, no
//! encryption, no CRC check).

use crate::inflate::{self, Corrupt};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub method: usize,
    pub compressed_size: usize,
    pub uncompressed_size: usize,
    pub local_offset: usize,
    pub encrypted: bool,
}

/// Largest entry this reader inflates.
pub const MAX_ENTRY_SIZE: usize = 256 << 20;
/// Longest entry name accepted; a longer one is a damaged or hostile archive.
pub const MAX_NAME_LENGTH: usize = 1024;

pub struct Zip<'a> {
    data: &'a [u8],
    pub entries: Vec<Entry>,
}

fn u16_at(d: &[u8], o: usize) -> Option<usize> {
    let b = d.get(o..o.checked_add(2)?)?;
    Some(b[0] as usize | (b[1] as usize) << 8)
}

fn u32_at(d: &[u8], o: usize) -> Option<usize> {
    Some(u16_at(d, o)? | u16_at(d, o.checked_add(2)?)? << 16)
}

/// UTF-8 when valid, otherwise ASCII with every byte >= 0x80 replaced by U+FFFD (Swift `Unicode.ASCII` decoding).
fn decode_name(b: &[u8]) -> String {
    match std::str::from_utf8(b) {
        Ok(s) => s.to_string(),
        Err(_) => b.iter().map(|&c| if c < 0x80 { c as char } else { '\u{FFFD}' }).collect(),
    }
}

impl<'a> Zip<'a> {
    pub fn new(data: &'a [u8]) -> Result<Zip<'a>, Corrupt> {
        let n = data.len();
        if n < 22 {
            return Err(Corrupt);
        }
        let mut eocd = None;
        let lowest = n.saturating_sub(22 + 0xFFFF);
        let mut p = n - 22;
        loop {
            if u32_at(data, p) == Some(0x0605_4b50) {
                eocd = Some(p);
                break;
            }
            if p == lowest {
                break;
            }
            p -= 1;
        }
        let eocd = eocd.ok_or(Corrupt)?;
        let count = u16_at(data, eocd + 10).ok_or(Corrupt)?;
        let cd_offset = u32_at(data, eocd + 16).ok_or(Corrupt)?;
        if cd_offset >= n {
            return Err(Corrupt);
        }
        let mut out = Vec::new();
        let mut q = cd_offset;
        for _ in 0..count {
            let fields = (|| {
                if u32_at(data, q)? != 0x0201_4b50 {
                    return None;
                }
                let flags = u16_at(data, q + 8)?;
                let method = u16_at(data, q + 10)?;
                let csize = u32_at(data, q + 20)?;
                let usize_ = u32_at(data, q + 24)?;
                let name_len = u16_at(data, q + 28)?;
                let extra_len = u16_at(data, q + 30)?;
                let comment_len = u16_at(data, q + 32)?;
                let local = u32_at(data, q + 42)?;
                if q + 46 + name_len > n || name_len > MAX_NAME_LENGTH {
                    return None;
                }
                Some((flags, method, csize, usize_, name_len, extra_len, comment_len, local))
            })();
            let (flags, method, csize, usize_, name_len, extra_len, comment_len, local) = fields.ok_or(Corrupt)?;
            out.push(Entry {
                name: decode_name(&data[q + 46..q + 46 + name_len]),
                method,
                compressed_size: csize,
                uncompressed_size: usize_,
                local_offset: local,
                encrypted: flags & 1 != 0,
            });
            q += 46 + name_len + extra_len + comment_len;
        }
        Ok(Zip { data, entries: out })
    }

    /// First entry whose name matches case-insensitively (simple Unicode lowercase; Swift uses `caseInsensitiveCompare`).
    pub fn entry(&self, name: &str) -> Option<&Entry> {
        let want = name.to_lowercase();
        self.entries.iter().find(|e| e.name.to_lowercase() == want)
    }

    /// The entry's bytes; `Ok(None)` when there is no such entry.
    pub fn data_named(&self, name: &str) -> Result<Option<Vec<u8>>, Corrupt> {
        self.entry(name).map(|e| self.data(e)).transpose()
    }

    pub fn data(&self, e: &Entry) -> Result<Vec<u8>, Corrupt> {
        let (n, o) = (self.data.len(), e.local_offset);
        if e.encrypted || e.uncompressed_size > MAX_ENTRY_SIZE || e.compressed_size > MAX_ENTRY_SIZE {
            return Err(Corrupt);
        }
        if u16_at(self.data, o) != Some(0x4b50) || u16_at(self.data, o + 2) != Some(0x0403) {
            return Err(Corrupt);
        }
        let name_len = u16_at(self.data, o + 26).ok_or(Corrupt)?;
        let extra_len = u16_at(self.data, o + 28).ok_or(Corrupt)?;
        let start = o + 30 + name_len + extra_len;
        if start + e.compressed_size > n {
            return Err(Corrupt);
        }
        let body = &self.data[start..start + e.compressed_size];
        match e.method {
            0 => Ok(body.to_vec()),
            8 => {
                let inflated = inflate::inflate(body, e.uncompressed_size.min(MAX_ENTRY_SIZE))?;
                if inflated.len() != e.uncompressed_size {
                    return Err(Corrupt);
                }
                Ok(inflated)
            }
            _ => Err(Corrupt),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stored_zip(name: &str, body: &[u8]) -> Vec<u8> {
        let mut z = Vec::new();
        z.extend_from_slice(&[0x50, 0x4b, 3, 4, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        z.extend_from_slice(&(body.len() as u32).to_le_bytes());
        z.extend_from_slice(&(body.len() as u32).to_le_bytes());
        z.extend_from_slice(&(name.len() as u16).to_le_bytes());
        z.extend_from_slice(&[0, 0]);
        z.extend_from_slice(name.as_bytes());
        z.extend_from_slice(body);
        let cd = z.len();
        z.extend_from_slice(&[0x50, 0x4b, 1, 2, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        z.extend_from_slice(&(body.len() as u32).to_le_bytes());
        z.extend_from_slice(&(body.len() as u32).to_le_bytes());
        z.extend_from_slice(&(name.len() as u16).to_le_bytes());
        z.extend_from_slice(&[0; 12]);
        z.extend_from_slice(&0u32.to_le_bytes());
        z.extend_from_slice(name.as_bytes());
        let cd_len = z.len() - cd;
        z.extend_from_slice(&[0x50, 0x4b, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0]);
        z.extend_from_slice(&(cd_len as u32).to_le_bytes());
        z.extend_from_slice(&(cd as u32).to_le_bytes());
        z.extend_from_slice(&[0, 0]);
        z
    }

    #[test]
    fn reads_stored_entry_case_insensitive() {
        let z = stored_zip("Project.prgraphic", b"hello");
        let zip = Zip::new(&z).unwrap();
        assert_eq!(zip.entries.len(), 1);
        assert_eq!(zip.data_named("PROJECT.PRGRAPHIC").unwrap().unwrap(), b"hello");
        assert_eq!(zip.data_named("nope").unwrap(), None);
    }

    #[test]
    fn rejects_long_names() {
        assert!(Zip::new(&stored_zip(&"n".repeat(1025), b"x")).is_err());
        assert!(Zip::new(&stored_zip(&"n".repeat(1024), b"x")).is_ok());
    }

    #[test]
    fn rejects_short_truncated_and_oversized() {
        assert!(Zip::new(b"PK").is_err());
        let z = stored_zip("a", b"hello");
        assert!(Zip::new(&z[..z.len() - 5]).is_err());
        let mut zip = Zip::new(&z).unwrap();
        zip.entries[0].uncompressed_size = MAX_ENTRY_SIZE + 1;
        let e = zip.entries[0].clone();
        assert_eq!(zip.data(&e), Err(Corrupt));
    }
}
