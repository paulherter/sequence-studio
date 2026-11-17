// SPDX-License-Identifier: GPL-3.0-or-later
//! Raw deflate (RFC 1951): port of SQCore `RawInflate.inflate` (bit-by-bit Huffman decoding, same checks and limits).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Corrupt;

struct Huffman {
    counts: [usize; 16],
    symbols: Vec<usize>,
}

impl Huffman {
    fn new(lengths: &[usize]) -> Huffman {
        let mut counts = [0usize; 16];
        for &l in lengths {
            counts[l] += 1;
        }
        counts[0] = 0;
        let mut offs = [0usize; 16];
        for i in 1..15 {
            offs[i + 1] = offs[i] + counts[i];
        }
        let mut symbols = vec![0usize; lengths.len()];
        for (s, &l) in lengths.iter().enumerate() {
            if l != 0 {
                symbols[offs[l]] = s;
                offs[l] += 1;
            }
        }
        Huffman { counts, symbols }
    }
}

const LEN_BASE: [usize; 29] =
    [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA: [usize; 29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE: [usize; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [usize; 30] =
    [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CL_ORDER: [usize; 19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

struct Bits<'a> {
    src: &'a [u8],
    pos: usize,
    buf: u64,
    cnt: usize,
}

impl Bits<'_> {
    fn bits(&mut self, n: usize) -> Result<usize, Corrupt> {
        while self.cnt < n {
            let b = *self.src.get(self.pos).ok_or(Corrupt)?;
            self.buf |= (b as u64) << self.cnt;
            self.pos += 1;
            self.cnt += 8;
        }
        let v = (self.buf & ((1u64 << n) - 1)) as usize;
        self.buf >>= n;
        self.cnt -= n;
        Ok(v)
    }

    fn decode(&mut self, h: &Huffman) -> Result<usize, Corrupt> {
        let (mut code, mut first, mut index) = (0usize, 0usize, 0usize);
        for len in 1..16 {
            code |= self.bits(1)?;
            let count = h.counts[len];
            if code < first + count {
                // Swift: `code - count < first` indexes `symbols[index + code - first]`; out of range traps there, here it is corrupt.
                return h.symbols.get(index + (code - first)).copied().ok_or(Corrupt);
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        Err(Corrupt)
    }
}

/// Inflates raw deflate bytes; `Err(Corrupt)` for bad input or output beyond `limit`.
pub fn inflate(src: &[u8], limit: usize) -> Result<Vec<u8>, Corrupt> {
    let mut r = Bits { src, pos: 0, buf: 0, cnt: 0 };
    let mut out: Vec<u8> = Vec::new();
    let mut fixed: Option<(Huffman, Huffman)> = None;
    let mut last = false;
    while !last {
        last = r.bits(1)? == 1;
        let kind = r.bits(2)?;
        if kind == 0 {
            r.buf = 0;
            r.cnt = 0;
            if r.pos + 4 > src.len() {
                return Err(Corrupt);
            }
            let len = src[r.pos] as usize | (src[r.pos + 1] as usize) << 8;
            r.pos += 4;
            if r.pos + len > src.len() || out.len() + len > limit {
                return Err(Corrupt);
            }
            out.extend_from_slice(&src[r.pos..r.pos + len]);
            r.pos += len;
            continue;
        }
        let owned;
        let (lit, dist): (&Huffman, &Huffman) = if kind == 1 {
            let f = fixed.get_or_insert_with(|| {
                let mut l = vec![8usize; 288];
                l[144..256].fill(9);
                l[256..280].fill(7);
                (Huffman::new(&l), Huffman::new(&[5usize; 30]))
            });
            (&f.0, &f.1)
        } else if kind == 2 {
            let nlen = r.bits(5)? + 257;
            let ndist = r.bits(5)? + 1;
            let ncode = r.bits(4)? + 4;
            if nlen > 286 || ndist > 30 {
                return Err(Corrupt);
            }
            let mut cl = [0usize; 19];
            for &o in CL_ORDER.iter().take(ncode) {
                cl[o] = r.bits(3)?;
            }
            let clh = Huffman::new(&cl);
            let mut lengths: Vec<usize> = Vec::new();
            while lengths.len() < nlen + ndist {
                let sym = r.decode(&clh)?;
                if sym < 16 {
                    lengths.push(sym);
                    continue;
                }
                let (rep, val) = if sym == 16 {
                    let p = *lengths.last().ok_or(Corrupt)?;
                    (3 + r.bits(2)?, p)
                } else if sym == 17 {
                    (3 + r.bits(3)?, 0)
                } else {
                    (11 + r.bits(7)?, 0)
                };
                if lengths.len() + rep > nlen + ndist {
                    return Err(Corrupt);
                }
                lengths.resize(lengths.len() + rep, val);
            }
            owned = (Huffman::new(&lengths[..nlen]), Huffman::new(&lengths[nlen..]));
            (&owned.0, &owned.1)
        } else {
            return Err(Corrupt);
        };
        loop {
            let sym = r.decode(lit)?;
            if sym < 256 {
                if out.len() >= limit {
                    return Err(Corrupt);
                }
                out.push(sym as u8);
            } else if sym == 256 {
                break;
            } else {
                let li = sym - 257;
                if li >= 29 {
                    return Err(Corrupt);
                }
                let len = LEN_BASE[li] + r.bits(LEN_EXTRA[li])?;
                let ds = r.decode(dist)?;
                if ds >= 30 {
                    return Err(Corrupt);
                }
                let d = DIST_BASE[ds] + r.bits(DIST_EXTRA[ds])?;
                if d > out.len() || out.len() + len > limit {
                    return Err(Corrupt);
                }
                let start = out.len() - d;
                for i in 0..len {
                    let b = out[start + i];
                    out.push(b);
                }
            }
        }
    }
    Ok(out)
}

/// Port of `PRGzip.inflate`: gzip (RFC 1952) around raw deflate; data that is not gzip comes back unchanged.
pub const MAX_PROJECT_SIZE: usize = 4 << 30;

pub fn gzip_inflate(data: &[u8], limit: usize) -> Result<Vec<u8>, Corrupt> {
    let b = data;
    if b.len() < 18 || b[0] != 0x1f || b[1] != 0x8b {
        return Ok(data.to_vec());
    }
    if b[2] != 8 {
        return Err(Corrupt);
    }
    let flags = b[3];
    let mut p = 10usize;
    if flags & 0x04 != 0 {
        if p + 2 > b.len() {
            return Err(Corrupt);
        }
        p += 2 + (b[p] as usize | (b[p + 1] as usize) << 8);
    }
    if flags & 0x08 != 0 {
        while p < b.len() && b[p] != 0 {
            p += 1;
        }
        p += 1;
    }
    if flags & 0x10 != 0 {
        while p < b.len() && b[p] != 0 {
            p += 1;
        }
        p += 1;
    }
    if flags & 0x02 != 0 {
        p += 2;
    }
    if p + 8 >= b.len() {
        return Err(Corrupt);
    }
    inflate(&b[p..b.len() - 8], limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_block() {
        let src = [0x01, 0x03, 0x00, 0xfc, 0xff, b'a', b'b', b'c'];
        assert_eq!(inflate(&src, 100).unwrap(), b"abc");
    }

    #[test]
    fn fixed_huffman_hello() {
        // zlib.compress(b"hello hello hello") without the 2-byte header and Adler-32.
        let src = [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x90, 0x00];
        assert_eq!(inflate(&src, 100).unwrap(), b"hello hello hello");
    }

    #[test]
    fn limit_and_garbage() {
        let src = [0x01, 0x03, 0x00, 0xfc, 0xff, b'a', b'b', b'c'];
        assert_eq!(inflate(&src, 2), Err(Corrupt));
        assert_eq!(inflate(&[0x07], 10), Err(Corrupt)); // block type 3
        assert_eq!(inflate(&[], 10), Err(Corrupt));
    }

    #[test]
    fn gzip_passthrough_and_flags() {
        assert_eq!(gzip_inflate(b"<xml/>", 10).unwrap(), b"<xml/>");
        let mut g = vec![0x1f, 0x8b, 9, 0, 0, 0, 0, 0, 0, 0];
        g.extend_from_slice(&[0; 12]);
        assert_eq!(gzip_inflate(&g, 10), Err(Corrupt));
    }
}
