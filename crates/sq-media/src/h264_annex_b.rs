//! Port of `SQMedia/Sources/SQMedia/MXF/H264AnnexB.swift`.

use std::ops::Range;

/// H.264 byte stream (Annex B) handling for essence that is not in the length-prefixed MP4 form: XAVC in MXF.
pub enum H264AnnexB {}

/// Profiles whose SPS carries chroma format, bit depth and scaling list fields.
const HIGH_PROFILES: [i64; 13] = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135];

impl H264AnnexB {
    /// True when the buffer begins with a start code (after leading zero bytes).
    pub fn has_start_code(p: &[u8]) -> bool {
        let mut i = 0;
        while i < p.len() && i < 64 && p[i] == 0 {
            i += 1;
        }
        i >= 2 && i < p.len() && p[i] == 1
    }

    /// The NAL units of a byte stream: ranges without start codes and without trailing zero bytes.
    pub fn nal_ranges(p: &[u8], limit: usize) -> Vec<Range<usize>> {
        if p.len() < 4 {
            return Vec::new();
        }
        let mut out: Vec<Range<usize>> = Vec::new();
        let mut nal_start: Option<usize> = None;
        let close = |out: &mut Vec<Range<usize>>, nal_start: Option<usize>, end: usize| {
            let Some(start) = nal_start else { return };
            let mut e = end;
            while e > start && p[e - 1] == 0 {
                e -= 1;
            }
            if e > start {
                out.push(start..e);
            }
        };
        let mut i = 2;
        let n = p.len();
        while i < n && out.len() < limit {
            // Start codes end in 0x01: jump from one 0x01 byte to the next.
            let Some(off) = p[i..].iter().position(|&b| b == 1) else { break };
            let j = i + off;
            if p[j - 1] == 0 && p[j - 2] == 0 {
                close(&mut out, nal_start, j - 2);
                nal_start = Some(j + 1);
            }
            i = j + 1;
        }
        if out.len() < limit {
            close(&mut out, nal_start, n);
        }
        out
    }

    /// The NAL units of a length-prefixed buffer (4-byte big-endian sizes); `None` when the sizes do not add up.
    pub fn length_prefixed_ranges(p: &[u8], limit: usize) -> Option<Vec<Range<usize>>> {
        let mut out: Vec<Range<usize>> = Vec::new();
        let mut i = 0;
        while i + 4 <= p.len() && out.len() < limit {
            let len = usize::from(p[i]) << 24
                | usize::from(p[i + 1]) << 16
                | usize::from(p[i + 2]) << 8
                | usize::from(p[i + 3]);
            if len == 0 || len > p.len() - i - 4 {
                return None;
            }
            out.push((i + 4)..(i + 4 + len));
            i += 4 + len;
        }
        if out.len() == limit || i == p.len() { if out.is_empty() { None } else { Some(out) } } else { None }
    }

    /// NAL units of a frame in either form.
    pub fn nals(p: &[u8], limit: usize) -> Vec<Range<usize>> {
        if Self::has_start_code(p) {
            return Self::nal_ranges(p, limit);
        }
        Self::length_prefixed_ranges(p, limit).unwrap_or_else(|| Self::nal_ranges(p, limit))
    }

    /// The NAL units VideoToolbox gets: filler data (type 12) and access unit delimiters are dropped, constant-bitrate
    /// intra streams are padded with megabytes of filler. Returns the ranges and the length-prefixed size.
    pub fn kept(p: &[u8]) -> (Vec<Range<usize>>, usize) {
        let mut size = 0;
        let ranges = Self::nals(p, usize::MAX)
            .into_iter()
            .filter(|r| {
                let ty = p[r.start] & 0x1F;
                if ty == 12 || ty == 9 {
                    return false;
                }
                size += 4 + r.len();
                true
            })
            .collect();
        (ranges, size)
    }

    /// Writes `ranges` of `p` as length-prefixed NAL units (4-byte sizes) to `dst` (`kept(p).1` bytes).
    pub fn write(p: &[u8], ranges: &[Range<usize>], dst: &mut [u8]) {
        let mut o = 0;
        for r in ranges {
            // Swift truncates the count to 32 bits.
            let n = (r.len() as u32).to_be_bytes();
            dst[o..o + 4].copy_from_slice(&n);
            dst[o + 4..o + 4 + r.len()].copy_from_slice(&p[r.clone()]);
            o += 4 + r.len();
        }
    }

    /// The frame as length-prefixed NAL units (4-byte sizes).
    pub fn length_prefixed(p: &[u8]) -> Vec<u8> {
        let (ranges, size) = Self::kept(p);
        if size == 0 {
            return Vec::new();
        }
        let mut out = vec![0u8; size];
        Self::write(p, &ranges, &mut out);
        out
    }

    /// First sequence and picture parameter sets of a frame.
    pub fn parameter_sets(p: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
        let mut sps: Option<Vec<u8>> = None;
        let mut pps: Option<Vec<u8>> = None;
        for r in Self::nals(p, 32) {
            let ty = p[r.start] & 0x1F;
            if ty == 7 && sps.is_none() {
                sps = Some(p[r.clone()].to_vec());
            }
            if ty == 8 && pps.is_none() {
                pps = Some(p[r.clone()].to_vec());
            }
            if ty == 1 || ty == 5 {
                break;
            }
        }
        Some((sps?, pps?))
    }

    // MARK: bit level (only what picture order needs)

    /// The raw payload of a NAL unit without its header byte: emulation prevention bytes removed.
    pub fn rbsp(nal: &[u8], max_bytes: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(nal.len().min(512));
        let mut zeros = 0;
        let mut i = 1;
        while i < nal.len() && out.len() < max_bytes {
            let b = nal[i];
            if zeros >= 2 && b == 3 {
                zeros = 0;
                i += 1;
                continue;
            }
            zeros = if b == 0 { zeros + 1 } else { 0 };
            out.push(b);
            i += 1;
        }
        out
    }

    /// Parses a sequence parameter set NAL (with header byte) as far as picture order needs.
    pub fn sps(nal: &[u8]) -> Option<SPS> {
        if nal.len() <= 4 || nal[0] & 0x1F != 7 {
            return None;
        }
        let mut r = BitReader::new(Self::rbsp(nal, usize::MAX));
        let mut s = SPS { profile: i64::from(r.bits(8)), ..SPS::default() };
        let _ = r.bits(16);
        let _ = r.ue();
        if HIGH_PROFILES.contains(&s.profile) {
            s.chroma_format = i64::from(r.ue());
            if s.chroma_format == 3 {
                s.separate_color_plane = r.bit() == 1;
            }
            let _ = r.ue();
            let _ = r.ue();
            let _ = r.bit();
            if r.bit() == 1 {
                // scaling matrix
                let lists = if s.chroma_format != 3 { 8 } else { 12 };
                for i in 0..lists {
                    if r.bit() != 1 {
                        continue;
                    }
                    let mut last: i32 = 8;
                    let mut next: i32 = 8;
                    for _ in 0..(if i < 6 { 16 } else { 64 }) {
                        if next != 0 {
                            let delta = r.se();
                            if !(-128..=127).contains(&delta) {
                                return None; // the standard's range
                            }
                            next = last.wrapping_add(delta).wrapping_add(256) % 256;
                        }
                        last = if next == 0 { last } else { next };
                        if r.failed {
                            return None;
                        }
                    }
                }
            }
        }
        s.log2_max_frame_num = i64::from(r.ue()) + 4;
        s.poc_type = i64::from(r.ue());
        if s.poc_type == 0 {
            s.log2_max_poc_lsb = i64::from(r.ue()) + 4;
        } else if s.poc_type == 1 {
            let _ = r.bit();
            let _ = r.se();
            let _ = r.se();
            let n = r.ue();
            if n > 255 {
                return None;
            }
            for _ in 0..n {
                let _ = r.se();
            }
        }
        let _ = r.ue();
        let _ = r.bit();
        let _ = r.ue();
        let _ = r.ue();
        s.frame_mbs_only = r.bit() == 1;
        if r.failed || s.log2_max_frame_num > 16 || s.log2_max_poc_lsb > 16 || s.poc_type > 2 {
            return None;
        }
        Some(s)
    }

    /// The first slice of a frame: NAL type, reference flag and picture order count (type 0 only).
    pub fn first_slice(p: &[u8], sps: Option<&SPS>) -> Option<Slice> {
        for range in Self::nals(p, 32) {
            let header = p[range.start];
            let ty = header & 0x1F;
            if ty != 1 && ty != 5 {
                continue;
            }
            let mut s = Slice { is_idr: ty == 5, is_reference: header & 0x60 != 0, ..Slice::default() };
            let mut r = BitReader::new(Self::rbsp(&p[range], 48));
            let _ = r.ue();
            s.slice_type = i64::from(r.ue() % 5);
            let _ = r.ue();
            if let Some(sps) = sps
                && !r.failed
            {
                if sps.separate_color_plane {
                    let _ = r.bits(2);
                }
                let _ = r.bits(sps.log2_max_frame_num);
                if !sps.frame_mbs_only && r.bit() == 1 {
                    let _ = r.bit();
                }
                if s.is_idr {
                    let _ = r.ue();
                }
                if sps.poc_type == 0 {
                    let lsb = i64::from(r.bits(sps.log2_max_poc_lsb));
                    if !r.failed {
                        s.poc_lsb = Some(lsb);
                    }
                }
            }
            return if r.failed { None } else { Some(s) };
        }
        None
    }

    /// Display position of each frame (given in decode order) from picture order counts: frames are sorted by count
    /// inside each IDR period. `None` when a count is missing (the caller then keeps decode order).
    pub fn display_order(slices: &[Slice], log2_max_poc_lsb: i64) -> Option<Vec<usize>> {
        // Swift's smart shift gives 0 for an out-of-range count.
        let max_lsb: i64 = u32::try_from(log2_max_poc_lsb).ok().and_then(|n| 1i64.checked_shl(n)).unwrap_or(0);
        let mut poc = vec![0i64; slices.len()];
        let mut prev_msb = 0;
        let mut prev_lsb = 0;
        for (i, s) in slices.iter().enumerate() {
            let lsb = s.poc_lsb?;
            if s.is_idr {
                prev_msb = 0;
                prev_lsb = 0;
            }
            let mut msb = prev_msb;
            if lsb < prev_lsb && prev_lsb - lsb >= max_lsb / 2 {
                msb += max_lsb;
            } else if lsb > prev_lsb && lsb - prev_lsb > max_lsb / 2 {
                msb -= max_lsb;
            }
            poc[i] = msb + lsb;
            if s.is_reference {
                prev_msb = msb;
                prev_lsb = lsb;
            }
        }
        let mut display = vec![0usize; slices.len()];
        let mut start = 0;
        while start < slices.len() {
            let mut end = start + 1;
            while end < slices.len() && !slices[end].is_idr {
                end += 1;
            }
            let mut order: Vec<usize> = (start..end).collect();
            order.sort_by(|&a, &b| poc[a].cmp(&poc[b]).then(a.cmp(&b)));
            for (rank, frame) in order.into_iter().enumerate() {
                display[frame] = start + rank;
            }
            start = end;
        }
        Some(display)
    }
}

/// Bit reader over an RBSP; reading past the end sets `failed` and yields zeros.
pub struct BitReader {
    b: Vec<u8>,
    pos: usize,
    pub failed: bool,
}

impl BitReader {
    pub fn new(b: Vec<u8>) -> BitReader {
        BitReader { b, pos: 0, failed: false }
    }

    pub fn bit(&mut self) -> u32 {
        if self.pos >= self.b.len() * 8 {
            self.failed = true;
            return 0;
        }
        let v = (self.b[self.pos >> 3] >> (7 - (self.pos & 7) as u8)) & 1;
        self.pos += 1;
        u32::from(v)
    }

    pub fn bits(&mut self, n: i64) -> u32 {
        let mut v: u32 = 0;
        for _ in 0..n.clamp(0, 32) {
            v = v << 1 | self.bit();
        }
        v
    }

    pub fn ue(&mut self) -> u32 {
        let mut zeros: u32 = 0;
        while self.bit() == 0 {
            zeros += 1;
            if self.failed || zeros > 31 {
                self.failed = true;
                return 0;
            }
        }
        if zeros == 0 { 0 } else { (1u32 << zeros) - 1 + self.bits(i64::from(zeros)) }
    }

    pub fn se(&mut self) -> i32 {
        let k = self.ue();
        if k & 1 == 1 { k.div_ceil(2) as i32 } else { -((k / 2) as i32) }
    }
}

/// The sequence parameter set fields picture order needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SPS {
    pub profile: i64,
    pub chroma_format: i64,
    pub separate_color_plane: bool,
    pub log2_max_frame_num: i64,
    pub poc_type: i64,
    pub log2_max_poc_lsb: i64,
    pub frame_mbs_only: bool,
}

impl Default for SPS {
    fn default() -> SPS {
        SPS {
            profile: 0,
            chroma_format: 1,
            separate_color_plane: false,
            log2_max_frame_num: 4,
            poc_type: 0,
            log2_max_poc_lsb: 4,
            frame_mbs_only: true,
        }
    }
}

/// The first slice header of a frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Slice {
    pub is_idr: bool,
    pub is_reference: bool,
    /// Slice type modulo 5: 0 P, 1 B, 2 I.
    pub slice_type: i64,
    pub poc_lsb: Option<i64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Bit writer of the Swift test stream builder (`H264TestStream.Bits`).
    #[derive(Default)]
    struct Bits {
        bytes: Vec<u8>,
        current: u8,
        filled: u32,
    }

    impl Bits {
        fn put(&mut self, v: u32, n: u32) {
            for i in (0..n).rev() {
                self.current = self.current << 1 | ((v >> i) & 1) as u8;
                self.filled += 1;
                if self.filled == 8 {
                    self.bytes.push(self.current);
                    self.current = 0;
                    self.filled = 0;
                }
            }
        }
        fn ue(&mut self, v: u32) {
            let x = v.wrapping_add(1);
            let len = 32 - x.leading_zeros();
            self.put(0, len - 1);
            self.put(x, len);
        }
        fn se(&mut self, v: i32) {
            self.ue(if v > 0 { (2 * v - 1) as u32 } else { (-2 * v) as u32 });
        }
        fn align(&mut self) {
            while self.filled != 0 {
                self.put(0, 1);
            }
        }
        fn trailing(&mut self) {
            self.put(1, 1);
            self.align();
        }
    }

    /// NAL unit with start code and emulation prevention.
    fn nal(header: u8, payload: &[u8], long_start_code: bool) -> Vec<u8> {
        let mut out = if long_start_code { vec![0, 0, 0, 1, header] } else { vec![0, 0, 1, header] };
        let mut zeros = 0;
        for &b in payload {
            if zeros >= 2 && b <= 3 {
                out.push(3);
                zeros = 0;
            }
            out.push(b);
            zeros = if b == 0 { zeros + 1 } else { 0 };
        }
        out
    }

    /// 64x48 High 4:2:2 10-bit intra SPS with explicit picture order counts (`pocType` 0).
    fn sps_10bit_422() -> Vec<u8> {
        let mut b = Bits::default();
        b.put(122, 8);
        b.put(0x10, 8);
        b.put(30, 8);
        b.ue(0);
        b.ue(2);
        b.ue(2);
        b.ue(2);
        b.put(0, 1);
        b.put(0, 1);
        b.ue(0);
        b.ue(0);
        b.ue(2);
        b.ue(1);
        b.put(0, 1);
        b.ue(3);
        b.ue(2);
        b.put(1, 1);
        b.put(1, 1);
        b.put(0, 1);
        b.put(0, 1);
        b.trailing();
        nal(0x67, &b.bytes, true)
    }

    fn pps() -> Vec<u8> {
        let mut b = Bits::default();
        b.ue(0);
        b.ue(0);
        b.put(0, 1);
        b.put(0, 1);
        b.ue(0);
        b.ue(0);
        b.ue(0);
        b.put(0, 1);
        b.put(0, 2);
        b.se(0);
        b.se(0);
        b.se(0);
        b.put(1, 1);
        b.put(0, 1);
        b.put(0, 1);
        b.trailing();
        nal(0x68, &b.bytes, true)
    }

    #[test]
    fn annex_b_conversion() {
        let stream: Vec<u8> = vec![
            0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1E, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80, 0, 0, 0, 0, 0,
            1, 0x0C, 0xFF, 0xFF, 0x80, 0, 0, 1, 0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0x42,
        ];
        let p = &stream[..];
        assert!(H264AnnexB::has_start_code(p));
        let ranges = H264AnnexB::nal_ranges(p, usize::MAX);
        assert_eq!(ranges.iter().map(|r| p[r.start] & 0x1F).collect::<Vec<_>>(), vec![9, 7, 8, 12, 5]);
        assert_eq!(&p[ranges[2].clone()], &[0x68, 0xEE, 0x3C, 0x80], "trailing zero bytes are not part of the unit");
        assert_eq!(&p[ranges[4].clone()], &[0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0x42], "emulation prevention stays");
        assert_eq!(H264AnnexB::nal_ranges(p, 2).len(), 2);
        let (sps, pps) = H264AnnexB::parameter_sets(p).unwrap();
        assert_eq!(sps, vec![0x67, 0x64, 0x00, 0x1E]);
        assert_eq!(pps, vec![0x68, 0xEE, 0x3C, 0x80]);
        let out = H264AnnexB::length_prefixed(p);
        assert_eq!(
            out,
            vec![
                0, 0, 0, 4, 0x67, 0x64, 0x00, 0x1E, 0, 0, 0, 4, 0x68, 0xEE, 0x3C, 0x80, 0, 0, 0, 7, 0x65, 0x88, 0x00,
                0x00, 0x03, 0x01, 0x42
            ]
        );
        // Already length-prefixed input is taken as it is.
        assert!(!H264AnnexB::has_start_code(&out));
        assert_eq!(H264AnnexB::length_prefixed(&out), out);

        assert!(H264AnnexB::nal_ranges(&[1, 2, 3], usize::MAX).is_empty());
        assert!(H264AnnexB::nal_ranges(&[0, 0, 0, 0, 0, 0, 0, 1], usize::MAX).is_empty());
        assert_eq!(H264AnnexB::length_prefixed_ranges(&[0, 0, 0, 9, 1, 2], usize::MAX), None);
        assert_eq!(H264AnnexB::rbsp(&[0x65, 1, 0, 0, 3, 0, 0, 3, 1], usize::MAX), vec![1, 0, 0, 0, 0, 1]);
    }

    #[test]
    fn parameter_set_and_slice_parsing() {
        // A non-IDR, non-reference intra slice (frame_num 3, pic_order_cnt_lsb 22) after SPS and PPS.
        let mut b = Bits::default();
        b.ue(0);
        b.ue(7);
        b.ue(0);
        b.put(3, 4);
        b.put(22, 6);
        b.se(0);
        b.ue(1);
        b.ue(25);
        b.align();
        let mut frame = sps_10bit_422();
        frame.extend(pps());
        frame.extend(nal(0x01, &b.bytes, false));

        let (sps_nal, _) = H264AnnexB::parameter_sets(&frame).unwrap();
        let sps = H264AnnexB::sps(&sps_nal).unwrap();
        assert_eq!(sps.profile, 122);
        assert_eq!(sps.chroma_format, 2);
        assert_eq!(sps.poc_type, 0);
        assert_eq!(sps.log2_max_frame_num, 4);
        assert_eq!(sps.log2_max_poc_lsb, 6);
        assert!(sps.frame_mbs_only);
        let slice = H264AnnexB::first_slice(&frame, Some(&sps)).unwrap();
        assert_eq!(slice, Slice { is_idr: false, is_reference: false, slice_type: 2, poc_lsb: Some(22) });

        assert_eq!(H264AnnexB::sps(&[0x67, 0x64]), None);
        assert_eq!(H264AnnexB::sps(&[0x68, 1, 2, 3, 4, 5]), None);
        // Counts wrap around: 60, 62, then 0 and 2 belong to the next cycle.
        let s = |is_idr: bool, is_reference: bool, slice_type: i64, poc_lsb: Option<i64>| Slice {
            is_idr,
            is_reference,
            slice_type,
            poc_lsb,
        };
        let wrapped = [
            s(true, true, 2, Some(56)),
            s(false, true, 0, Some(62)),
            s(false, false, 1, Some(58)),
            s(false, false, 1, Some(60)),
            s(false, true, 0, Some(4)),
            s(false, false, 1, Some(0)),
            s(false, false, 1, Some(2)),
        ];
        assert_eq!(H264AnnexB::display_order(&wrapped, 6), Some(vec![0, 3, 1, 2, 6, 4, 5]));
        assert_eq!(H264AnnexB::display_order(&[s(true, false, 0, None)], 6), None);
    }

    /// A scaling list delta outside the standard's range used to overflow.
    #[test]
    fn crafted_scaling_list_is_rejected() {
        let sps = |delta: &dyn Fn(&mut Bits)| -> Vec<u8> {
            let mut b = Bits::default();
            b.put(100, 8);
            b.put(0, 16);
            b.ue(0);
            b.ue(1);
            b.ue(0);
            b.ue(0);
            b.put(0, 1);
            b.put(1, 1); // scaling matrix
            b.put(1, 1); // first list
            delta(&mut b);
            for _ in 0..15 {
                b.se(0);
            }
            for _ in 0..7 {
                b.put(0, 1);
            }
            b.ue(0);
            b.ue(2);
            b.ue(1);
            b.put(0, 1);
            b.ue(3);
            b.ue(2);
            b.put(1, 1);
            b.put(1, 1);
            b.put(0, 1);
            b.put(0, 1);
            b.trailing();
            let mut out = vec![0x67];
            out.extend(b.bytes);
            out
        };
        assert_eq!(H264AnnexB::sps(&sps(&|b| b.ue(0xFFFF_FFFD))), None, "delta Int32.max");
        assert_eq!(H264AnnexB::sps(&sps(&|b| b.ue(0xFFFF_FFFE))), None, "delta -Int32.max");
        assert_eq!(H264AnnexB::sps(&sps(&|b| b.se(128))), None);
        assert_eq!(H264AnnexB::sps(&sps(&|b| b.se(-129))), None);
        assert_eq!(H264AnnexB::sps(&sps(&|b| b.se(-128))).map(|s| s.profile), Some(100));
        assert_eq!(H264AnnexB::sps(&sps(&|b| b.se(127))).map(|s| s.poc_type), Some(2));
    }
}
