// Swift: WebM/VP9Header.swift
//! Fields of a VP9 key frame's uncompressed header (VP9 bitstream spec section 6.2), enough to describe the stream.

/// Fields of a VP9 key frame's uncompressed header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VP9KeyFrameInfo {
    pub profile: i64,
    pub bit_depth: i64,
    pub subsampling_x: i64,
    pub subsampling_y: i64,
    pub color_space: i64,
    pub full_range: bool,
    pub width: i64,
    pub height: i64,
}

impl VP9KeyFrameInfo {
    /// Chroma format as text.
    pub fn chroma(&self) -> &'static str {
        match (self.subsampling_x, self.subsampling_y) {
            (1, 1) => "4:2:0",
            (1, 0) => "4:2:2",
            (0, 1) => "4:4:0",
            _ => "4:4:4",
        }
    }

    /// None when `frame` is not a key frame or is malformed.
    pub fn parse(frame: &[u8]) -> Option<VP9KeyFrameInfo> {
        let mut r = Bits::new(frame);
        if r.read(2) != 2 {
            return None;
        }
        let low = r.read(1);
        let high = r.read(1);
        let profile = high << 1 | low;
        if profile == 3 {
            r.read(1);
        }
        if r.read(1) == 1 {
            return None; // show_existing_frame
        }
        if r.read(1) != 0 {
            return None; // frame_type: 0 = key frame
        }
        r.read(1);
        r.read(1); // show_frame, error_resilient_mode
        if r.read(8) != 0x49 || r.read(8) != 0x83 || r.read(8) != 0x42 {
            return None;
        }
        let mut depth = 8;
        if profile >= 2 {
            depth = if r.read(1) == 1 { 12 } else { 10 };
        }
        let cs = r.read(3);
        let range;
        let (mut sx, mut sy) = (1, 1);
        if cs != 7 {
            range = r.read(1) == 1;
            if profile == 1 || profile == 3 {
                sx = r.read(1);
                sy = r.read(1);
                r.read(1);
            }
        } else {
            range = true;
            if profile == 1 || profile == 3 {
                sx = 0;
                sy = 0;
                r.read(1);
            } else {
                return None; // RGB needs profile 1 or 3
            }
        }
        let w = r.read(16) + 1;
        let h = r.read(16) + 1;
        if r.overrun {
            return None;
        }
        Some(VP9KeyFrameInfo {
            profile,
            bit_depth: depth,
            subsampling_x: sx,
            subsampling_y: sy,
            color_space: cs,
            full_range: range,
            width: w,
            height: h,
        })
    }

    /// `vpcC` atom payload (ISO full box without the size/type header). The three color codes are written as single bytes.
    pub fn vpc_c(&self, primaries: u8, transfer: u8, matrix: u8) -> Vec<u8> {
        let chroma_code: i64 = match (self.subsampling_x, self.subsampling_y) {
            (1, 1) => 0,
            (1, 0) => 2,
            _ => 3,
        };
        let pixels = self.width * self.height;
        let level: u8 = if pixels <= 552_960 {
            31
        } else if pixels <= 983_040 {
            40
        } else if pixels <= 2_228_224 {
            41
        } else if pixels <= 8_912_896 {
            51
        } else {
            62
        };
        let packed = (self.bit_depth << 4 | chroma_code << 1 | i64::from(self.full_range)) as u8;
        vec![1, 0, 0, 0, self.profile as u8, level, packed, primaries, transfer, matrix, 0, 0]
    }
}

/// MSB-first bit reader over the first 32 bytes.
struct Bits {
    d: Vec<u8>,
    pos: usize,
    overrun: bool,
}

impl Bits {
    fn new(data: &[u8]) -> Bits {
        Bits { d: data.iter().take(32).copied().collect(), pos: 0, overrun: false }
    }

    fn read(&mut self, n: usize) -> i64 {
        let mut v: i64 = 0;
        for _ in 0..n {
            let Some(&byte) = self.d.get(self.pos >> 3) else {
                self.overrun = true;
                return v << 1;
            };
            v = v << 1 | i64::from((byte >> (7 - (self.pos & 7))) & 1);
            self.pos += 1;
        }
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// MSB-first bit writer for a profile 0 key frame header.
    fn key_frame(width: u32, height: u32) -> Vec<u8> {
        let mut bits: Vec<u8> = Vec::new();
        let mut put = |v: u32, n: u32| (0..n).rev().for_each(|i| bits.push((v >> i & 1) as u8));
        put(2, 2); // frame marker
        put(0, 1);
        put(0, 1); // profile 0
        put(0, 1); // show_existing_frame
        put(0, 1); // key frame
        put(1, 1);
        put(0, 1); // show_frame, error_resilient
        put(0x49, 8);
        put(0x83, 8);
        put(0x42, 8);
        put(2, 3); // color space BT.709
        put(0, 1); // studio range
        put(width - 1, 16);
        put(height - 1, 16);
        bits.chunks(8).map(|c| c.iter().enumerate().fold(0u8, |a, (i, b)| a | b << (7 - i))).collect()
    }

    #[test]
    fn vp9_header_parse() {
        let info = VP9KeyFrameInfo::parse(&key_frame(1920, 1080));
        let info = info.unwrap_or_else(|| panic!("key frame must parse"));
        assert_eq!((info.width, info.height, info.profile, info.bit_depth), (1920, 1080, 0, 8));
        assert_eq!(info.chroma(), "4:2:0");
        assert!(!info.full_range);
        assert_eq!(VP9KeyFrameInfo::parse(&[0x00, 0x01]), None);
        assert_eq!(VP9KeyFrameInfo::parse(&key_frame(64, 48)[..6]), None);
    }

    #[test]
    fn vpc_c_payload() {
        let info = VP9KeyFrameInfo::parse(&key_frame(1920, 1080)).unwrap_or_else(|| panic!("parse"));
        assert_eq!(info.vpc_c(1, 1, 1), vec![1, 0, 0, 0, 0, 41, 0x80, 1, 1, 1, 0, 0]);
    }
}
