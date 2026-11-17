// SPDX-License-Identifier: GPL-3.0-or-later
//! A PNG reader without any picture library: straight-alpha RGBA8 for the saved-template tiles (`PortablePNG`).
//! Handles every color type (gray, RGB, palette with tRNS, gray+alpha, RGBA) at 1 to 16 bits, not interlaced. Color
//! management chunks are ignored; the pixels are taken as sRGB.
// shortcut: Adam7 interlaced pictures return None (the caller falls back to another decoder); upgrade when one shows up.

use crate::raw_inflate::zlib;

/// A decoded picture.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Image {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// `width * height * 4` bytes, R G B A, straight (not premultiplied) alpha.
    pub rgba: Vec<u8>,
}

/// Largest picture taken (pixels), so a corrupt header cannot ask for gigabytes.
const MAX_PIXELS: usize = 64_000_000;

fn u32_at(png: &[u8], o: usize) -> usize {
    u32::from_be_bytes([png[o], png[o + 1], png[o + 2], png[o + 3]]) as usize
}

/// Decodes a PNG; `None` for anything unreadable or unsupported.
pub fn decode(png: &[u8]) -> Option<Image> {
    if png.len() <= 33 || png[..8] != [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
        return None;
    }
    let (mut width, mut height, mut depth, mut color_type) = (0usize, 0usize, 0usize, 0u8);
    let (mut palette, mut trns, mut idat): (&[u8], &[u8], Vec<u8>) = (&[], &[], Vec::new());
    let (mut saw_header, mut p) = (false, 8);
    while p + 12 <= png.len() {
        let n = u32_at(png, p);
        let (kind, body) = (&png[p + 4..p + 8], p + 8);
        if body + n + 4 > png.len() {
            return None;
        }
        let data = &png[body..body + n];
        match kind {
            b"IHDR" => {
                if n != 13 || data[10..13] != [0, 0, 0] {
                    return None; // method, filter, not interlaced
                }
                (width, height, depth, color_type) =
                    (u32_at(png, body), u32_at(png, body + 4), usize::from(data[8]), data[9]);
                saw_header = true;
            }
            b"PLTE" => palette = data,
            b"tRNS" => trns = data,
            b"IDAT" => idat.extend_from_slice(data),
            b"IEND" => break,
            _ => {}
        }
        p = body + n + 4;
    }
    if !saw_header || width == 0 || height == 0 || width.checked_mul(height)? > MAX_PIXELS {
        return None;
    }
    let (channels, depths): (usize, &[usize]) = match color_type {
        0 => (1, &[1, 2, 4, 8, 16]),
        2 => (3, &[8, 16]),
        3 => (1, &[1, 2, 4, 8]),
        4 => (2, &[8, 16]),
        6 => (4, &[8, 16]),
        _ => return None,
    };
    if !depths.contains(&depth) || (color_type == 3 && palette.len() < 3) {
        return None;
    }
    let bits_per_pixel = channels * depth;
    let bpp = (bits_per_pixel / 8).max(1); // bytes per complete pixel for the filters
    let stride = (width * bits_per_pixel).div_ceil(8);
    let raw = zlib(&idat, height * (stride + 1)).ok().filter(|r| r.len() == height * (stride + 1))?;
    let lines = unfilter(&raw, height, stride, bpp);

    // One sample (at most 16 bits) of line `y`, sample index `i` (pixel * channels + channel).
    let sample = |y: usize, i: usize| -> usize {
        let line = &lines[y * stride..(y + 1) * stride];
        match depth {
            8 => usize::from(line[i]),
            16 => usize::from(line[2 * i]) << 8 | usize::from(line[2 * i + 1]),
            _ => {
                let bit = i * depth;
                (usize::from(line[bit / 8]) >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
            }
        }
    };
    let max_value = (1usize << depth) - 1;
    // The sample scaled to 8 bits.
    let to8 = |v: usize| -> u8 { if depth == 8 { v as u8 } else { ((v * 255 + max_value / 2) / max_value) as u8 } };
    // tRNS color key for gray / RGB.
    let key = |k: usize| -> Option<usize> {
        (trns.len() >= 2 * (k + 1)).then(|| usize::from(trns[2 * k]) << 8 | usize::from(trns[2 * k + 1]))
    };
    let mut rgba = vec![255u8; width * height * 4];
    for y in 0..height {
        for x in 0..width {
            let d = (y * width + x) * 4;
            match color_type {
                0 => {
                    let g = sample(y, x);
                    rgba[d..d + 3].fill(to8(g));
                    if key(0) == Some(g) {
                        rgba[d + 3] = 0;
                    }
                }
                2 => {
                    let (r, g, b) = (sample(y, x * 3), sample(y, x * 3 + 1), sample(y, x * 3 + 2));
                    rgba[d..d + 3].copy_from_slice(&[to8(r), to8(g), to8(b)]);
                    if (key(0), key(1), key(2)) == (Some(r), Some(g), Some(b)) {
                        rgba[d + 3] = 0;
                    }
                }
                3 => {
                    let i = sample(y, x);
                    rgba[d..d + 3].copy_from_slice(palette.get(i * 3..i * 3 + 3)?);
                    if let Some(&a) = trns.get(i) {
                        rgba[d + 3] = a;
                    }
                }
                4 => {
                    rgba[d..d + 3].fill(to8(sample(y, x * 2)));
                    rgba[d + 3] = to8(sample(y, x * 2 + 1));
                }
                _ => {
                    for k in 0..4 {
                        rgba[d + k] = to8(sample(y, x * 4 + k));
                    }
                }
            }
        }
    }
    Some(Image { width, height, rgba })
}

/// Undoes the per-row filters: `raw` is `height` rows of a filter byte plus `stride` bytes; the result has `stride` bytes per row.
fn unfilter(raw: &[u8], height: usize, stride: usize, bpp: usize) -> Vec<u8> {
    let mut out = vec![0u8; height * stride];
    for y in 0..height {
        let (filter, src) = (raw[y * (stride + 1)], &raw[y * (stride + 1) + 1..(y + 1) * (stride + 1)]);
        let o = y * stride;
        for x in 0..stride {
            let a = if x >= bpp { i32::from(out[o + x - bpp]) } else { 0 };
            let b = if y > 0 { i32::from(out[o - stride + x]) } else { 0 };
            let c = if x >= bpp && y > 0 { i32::from(out[o - stride + x - bpp]) } else { 0 };
            let v = i32::from(src[x]);
            let r = match filter {
                1 => v + a,
                2 => v + b,
                3 => v + (a + b) / 2,
                4 => {
                    let (pa, pb, pc) = ((b - c).abs(), (a - c).abs(), (a + b - 2 * c).abs());
                    v + if pa <= pb && pa <= pc {
                        a
                    } else if pb <= pc {
                        b
                    } else {
                        c
                    }
                }
                _ => v,
            };
            out[o + x] = r as u8; // truncating, like the filter arithmetic mod 256
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn be32(v: usize) -> [u8; 4] {
        (v as u32).to_be_bytes()
    }

    fn chunk(kind: &str, body: &[u8]) -> Vec<u8> {
        [&be32(body.len())[..], kind.as_bytes(), body, &[0; 4]].concat() // CRC not checked
    }

    /// A zlib stream of stored blocks (no compression), the form the Windows template saver writes.
    fn stored(raw: &[u8]) -> Vec<u8> {
        let mut out = vec![0x78, 0x01];
        let mut blocks = raw.chunks(65535).peekable();
        if blocks.peek().is_none() {
            out.extend([1, 0, 0, 0xFF, 0xFF]);
        }
        while let Some(b) = blocks.next() {
            let n = b.len() as u16;
            out.push(u8::from(blocks.peek().is_none()));
            out.extend(n.to_le_bytes());
            out.extend((!n).to_le_bytes());
            out.extend(b);
        }
        out.extend([0; 4]);
        out
    }

    struct Spec<'a> {
        width: usize,
        height: usize,
        depth: u8,
        kind: u8,
        rows: Vec<Vec<u8>>,
        filters: &'a [u8],
        plte: &'a [u8],
        trns: &'a [u8],
    }

    fn spec(width: usize, height: usize, depth: u8, kind: u8, rows: Vec<Vec<u8>>) -> Spec<'static> {
        Spec { width, height, depth, kind, rows, filters: &[0], plte: &[], trns: &[] }
    }

    fn png(s: &Spec) -> Vec<u8> {
        let channels = [1, 0, 3, 1, 2, 0, 4][usize::from(s.kind)];
        let bpp = (usize::from(s.depth) * channels / 8).max(1);
        let mut raw = Vec::new();
        for (y, row) in s.rows.iter().enumerate() {
            let f = s.filters[y % s.filters.len()];
            raw.push(f);
            for (x, &v) in row.iter().enumerate() {
                let a = if x >= bpp { i32::from(row[x - bpp]) } else { 0 };
                let b = if y > 0 { i32::from(s.rows[y - 1][x]) } else { 0 };
                let c = if x >= bpp && y > 0 { i32::from(s.rows[y - 1][x - bpp]) } else { 0 };
                let pred = match f {
                    1 => a,
                    2 => b,
                    3 => (a + b) / 2,
                    4 => {
                        let (pa, pb, pc) = ((b - c).abs(), (a - c).abs(), (a + b - 2 * c).abs());
                        if pa <= pb && pa <= pc {
                            a
                        } else if pb <= pc {
                            b
                        } else {
                            c
                        }
                    }
                    _ => 0,
                };
                raw.push((i32::from(v) - pred) as u8);
            }
        }
        let mut out = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        out.extend(chunk("IHDR", &[&be32(s.width)[..], &be32(s.height), &[s.depth, s.kind, 0, 0, 0]].concat()));
        if !s.plte.is_empty() {
            out.extend(chunk("PLTE", s.plte));
        }
        if !s.trns.is_empty() {
            out.extend(chunk("tRNS", s.trns));
        }
        // Two IDAT chunks: the stream is joined across them.
        let z = stored(&raw);
        let half = z.len() / 2;
        out.extend(chunk("IDAT", &z[..half]));
        out.extend(chunk("IDAT", &z[half..]));
        out.extend(chunk("IEND", &[]));
        out
    }

    #[test]
    fn rgba_with_every_filter_keeps_straight_alpha() {
        let (w, h) = (7, 10);
        let rows: Vec<Vec<u8>> =
            (0..h).map(|y| (0..w * 4).map(|i| ((i * 37 + y * 11) ^ (y * 5)) as u8).collect()).collect();
        let s = Spec { filters: &[0, 1, 2, 3, 4], ..spec(w, h, 8, 6, rows.clone()) };
        let img = decode(&png(&s));
        assert_eq!(img, Some(Image { width: w, height: h, rgba: rows.concat() }));
    }

    #[test]
    fn transparency_of_the_tile_picture_survives() {
        let px = vec![255, 0, 0, 128, 10, 20, 30, 0];
        let img = decode(&png(&spec(2, 1, 8, 6, vec![px.clone()])));
        assert_eq!(img.map(|i| i.rgba), Some(px));
    }

    #[test]
    fn rgb_gray_palette_and_sixteen_bit() {
        let rgba = |s: Spec| decode(&png(&s)).map(|i| i.rgba);
        assert_eq!(rgba(spec(2, 1, 8, 2, vec![vec![1, 2, 3, 4, 5, 6]])), Some(vec![1, 2, 3, 255, 4, 5, 6, 255]));
        assert_eq!(rgba(spec(1, 1, 8, 4, vec![vec![100, 50]])), Some(vec![100, 100, 100, 50]));
        // 4-bit gray: two pixels in one byte (0x0F -> 0 and 255).
        assert_eq!(rgba(spec(2, 1, 4, 0, vec![vec![0x0F]])), Some(vec![0, 0, 0, 255, 255, 255, 255, 255]));
        // 2-bit palette with tRNS: index 1 half transparent.
        let pal = Spec {
            plte: &[9, 9, 9, 200, 100, 50, 1, 2, 3],
            trns: &[255, 128],
            ..spec(3, 1, 2, 3, vec![vec![0b00_01_10_00]])
        };
        assert_eq!(rgba(pal), Some(vec![9, 9, 9, 255, 200, 100, 50, 128, 1, 2, 3, 255]));
        // 16-bit RGBA: high bytes after rounding 0x8000 -> 128, 0xFFFF -> 255.
        let deep = spec(1, 1, 16, 6, vec![vec![0x80, 0, 0xFF, 0xFF, 0, 0, 0x40, 0]]);
        assert_eq!(rgba(deep), Some(vec![128, 255, 0, 64]));
    }

    #[test]
    fn color_key_makes_gray_and_rgb_transparent() {
        let gray = Spec { trns: &[0, 7], ..spec(2, 1, 8, 0, vec![vec![7, 8]]) };
        assert_eq!(decode(&png(&gray)).map(|i| i.rgba), Some(vec![7, 7, 7, 0, 8, 8, 8, 255]));
        let rgb = Spec { trns: &[0, 1, 0, 2, 0, 3], ..spec(2, 1, 8, 2, vec![vec![1, 2, 3, 1, 2, 4]]) };
        assert_eq!(decode(&png(&rgb)).map(|i| i.rgba), Some(vec![1, 2, 3, 0, 1, 2, 4, 255]));
    }

    #[test]
    fn rejects_what_it_cannot_read() {
        assert_eq!(decode(&[1, 2, 3]), None);
        let mut interlaced = png(&spec(1, 1, 8, 6, vec![vec![1, 2, 3, 4]]));
        interlaced[28] = 1; // IHDR interlace byte
        assert_eq!(decode(&interlaced), None);
        let full = png(&spec(4, 4, 8, 6, vec![vec![9; 16]; 4]));
        assert_eq!(decode(&full[..60]), None);
        // Invalid depth for the color type.
        assert_eq!(decode(&png(&spec(1, 1, 4, 6, vec![vec![0, 0]]))), None);
    }
}
