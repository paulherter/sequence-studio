// SPDX-License-Identifier: GPL-3.0-or-later
//! Raw deflate (RFC 1951) and zlib (RFC 1950), `RawInflate`. The deflate decoder lives in `sq-prproj-reader` (one home
//! per helper) and is re-exported here; this module adds the zlib wrapper PNG needs.

pub use sq_prproj_reader::inflate::{Corrupt, inflate};

/// A zlib stream (2-byte header, deflate data, Adler-32 not checked) as in a PNG's IDAT chunks.
pub fn zlib(src: &[u8], limit: usize) -> Result<Vec<u8>, Corrupt> {
    let header_ok = src.len() > 2
        && src[0] & 0x0F == 8
        && src[1] & 0x20 == 0
        && (usize::from(src[0]) << 8 | usize::from(src[1])) % 31 == 0;
    if !header_ok {
        return Err(Corrupt);
    }
    inflate(&src[2..], limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Stored (uncompressed) deflate block.
    fn stored(data: &[u8]) -> Vec<u8> {
        let len = data.len() as u16;
        let mut v = vec![1];
        v.extend_from_slice(&len.to_le_bytes());
        v.extend_from_slice(&(!len).to_le_bytes());
        v.extend_from_slice(data);
        v
    }

    #[test]
    fn zlib_strips_the_header() {
        let mut z = vec![0x78, 0x01];
        z.extend(stored(b"hello"));
        assert_eq!(zlib(&z, 100), Ok(b"hello".to_vec()));
        assert_eq!(zlib(&z, 3), Err(Corrupt));
    }

    #[test]
    fn zlib_rejects_bad_headers() {
        assert_eq!(zlib(&[0x78, 0x01], 10), Err(Corrupt));
        assert_eq!(zlib(&[0x79, 0x01, 0, 0], 10), Err(Corrupt));
        // Preset dictionary flag.
        assert_eq!(zlib(&[0x78, 0x20 | 0x1e, 0, 0], 10), Err(Corrupt));
        // Header check bits wrong.
        assert_eq!(zlib(&[0x78, 0x02, 0, 0], 10), Err(Corrupt));
    }

    #[test]
    fn fixed_huffman_block() {
        // "a" via the fixed table: BFINAL=1, BTYPE=01, literal 0x61 (code 10010001), end of block.
        assert_eq!(inflate(&[0x4b, 0x04, 0x00], 10), Ok(b"a".to_vec()));
    }
}
