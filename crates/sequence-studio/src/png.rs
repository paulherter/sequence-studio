//! A minimal PNG writer for test output.
// shortcut: stored (uncompressed) deflate blocks, so files are large; swap in a real encoder if shots are archived.

use sq_draw::RgbaImage;

fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = if crc & 1 == 1 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &x in data {
        a = (a + u32::from(x)) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], body: &[u8]) {
    out.extend((body.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend(kind);
    out.extend(body);
    let crc = crc32(&out[start..]);
    out.extend(crc.to_be_bytes());
}

/// Encodes `image` as an 8-bit RGBA PNG.
pub fn encode(image: &RgbaImage) -> Vec<u8> {
    let row = image.width * 4;
    let mut raw = Vec::with_capacity((row + 1) * image.height);
    for line in image.pixels.chunks(row.max(1)) {
        raw.push(0);
        raw.extend(line);
    }
    let mut z = vec![0x78, 0x01];
    let mut blocks = raw.chunks(65535).peekable();
    while let Some(block) = blocks.next() {
        z.push(u8::from(blocks.peek().is_none()));
        z.extend((block.len() as u16).to_le_bytes());
        z.extend((!(block.len() as u16)).to_le_bytes());
        z.extend(block);
    }
    z.extend(adler32(&raw).to_be_bytes());
    let mut header = Vec::new();
    header.extend((image.width as u32).to_be_bytes());
    header.extend((image.height as u32).to_be_bytes());
    header.extend([8, 6, 0, 0, 0]);
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    chunk(&mut out, b"IHDR", &header);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::portable_png;

    #[test]
    fn crc_and_adler_match_known_values() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(adler32(b"Wikipedia"), 0x11E6_0398);
    }

    #[test]
    fn roundtrips_through_the_decoder() {
        let pixels: Vec<u8> = (0..3 * 2 * 4).map(|i| (i * 9) as u8).collect();
        let png = encode(&RgbaImage { width: 3, height: 2, pixels: pixels.clone() });
        let back = portable_png::decode(&png);
        assert_eq!(back.map(|b| (b.width, b.height, b.rgba)), Some((3, 2, pixels)));
    }
}
