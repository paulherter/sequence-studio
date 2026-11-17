//! Port of `SQMedia/Sources/SQMedia/CodecConfig.swift`.

use sq_core_model::ColorSpaceID;

/// Dolby Vision decoder configuration (`dvcC` / `dvvC` / `dvwC` payload, DOVIDecoderConfigurationRecord). iPhone HDR
/// video is profile 8.4: an HEVC Main10 base layer in HLG plus RPU metadata. We decode the base layer only (VideoToolbox
/// hands it out untouched, no RPU reshaping), so its compatibility id names the color space we render.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DolbyVisionConfig {
    pub profile: i64,
    pub level: i64,
    pub has_rpu: bool,
    pub has_enhancement_layer: bool,
    pub has_base_layer: bool,
    /// dv_bl_signal_compatibility_id: 1 HDR10, 2 SDR (BT.709), 4 HLG, 6 BT.2100 PQ, 0 none (profile 5, IPTPQc2).
    pub compatibility_id: i64,
}

impl DolbyVisionConfig {
    /// The color space of the cross-compatible base layer; `None` when there is none we can show (profile 5 needs the RPU).
    pub fn base_layer_color_space(&self) -> Option<ColorSpaceID> {
        match self.compatibility_id {
            1 | 6 => Some(ColorSpaceID::PqBT2020),
            2 => Some(ColorSpaceID::Rec709),
            4 => Some(ColorSpaceID::HlgBT2020),
            _ => None,
        }
    }
}

/// Chroma format and bit depth read from a codec configuration record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodecConfigResult {
    pub chroma: String,
    pub bit_depth: i64,
}

fn result(chroma: &str, bit_depth: i64) -> CodecConfigResult {
    CodecConfigResult { chroma: chroma.to_string(), bit_depth }
}

/// Chroma format and bit depth from the `avcC` / `hvcC` atom payload (pure, testable).
pub enum CodecConfig {}

impl CodecConfig {
    pub fn chroma_name(idc: i64) -> &'static str {
        if idc == 0 || idc == 1 {
            "4:2:0"
        } else if idc == 2 {
            "4:2:2"
        } else {
            "4:4:4"
        }
    }

    pub fn hevc(d: &[u8]) -> Option<CodecConfigResult> {
        if d.len() <= 17 {
            return None;
        }
        Some(result(Self::chroma_name(i64::from(d[16] & 3)), i64::from(d[17] & 7) + 8))
    }

    /// `vpcC` payload (version 1 full box): byte 6 holds bit depth (high nibble), chroma subsampling code, full range.
    pub fn vp9(d: &[u8]) -> Option<CodecConfigResult> {
        if d.len() < 7 {
            return None;
        }
        let code = (d[6] >> 1) & 7;
        let chroma = if code == 2 {
            "4:2:2"
        } else if code == 3 {
            "4:4:4"
        } else {
            "4:2:0"
        };
        Some(result(chroma, i64::from(d[6] >> 4)))
    }

    /// `av1C` payload: byte 2 holds high_bitdepth, twelve_bit, monochrome, subsampling x/y.
    pub fn av1(d: &[u8]) -> Option<CodecConfigResult> {
        if d.len() < 4 {
            return None;
        }
        let hi = d[2] & 0x40 != 0;
        let twelve = d[2] & 0x20 != 0;
        let sx = d[2] & 0x08 != 0;
        let sy = d[2] & 0x04 != 0;
        let chroma = if sx && sy {
            "4:2:0"
        } else if sx {
            "4:2:2"
        } else {
            "4:4:4"
        };
        Some(result(
            chroma,
            if twelve {
                12
            } else if hi {
                10
            } else {
                8
            },
        ))
    }

    pub fn avc(d: &[u8]) -> Option<CodecConfigResult> {
        if d.len() <= 8 || d[0] != 1 || d[5] & 0x1F < 1 {
            return None;
        }
        let len = usize::from(d[6]) << 8 | usize::from(d[7]);
        if d.len() < 8 + len || len <= 4 {
            return None;
        }
        // SPS NAL: header byte, then profile_idc, constraints, level_idc, then bit-packed fields.
        let sps = remove_emulation_prevention(&d[8..8 + len]);
        let profile = sps[1];
        if ![100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(&profile) {
            return Some(result("4:2:0", 8));
        }
        // Swift slices `sps[4...]` and traps when emulation prevention shrank the unit below 4 bytes.
        let mut r = BitReader::new(sps.get(4..).unwrap_or(&[]).to_vec());
        let _ = r.ue(); // seq_parameter_set_id
        let chroma = r.ue();
        if chroma == 3 {
            let _ = r.bit(); // separate_color_plane_flag
        }
        let depth = r.ue() + 8;
        Some(result(Self::chroma_name(chroma), depth))
    }

    /// Atom names that carry a DOVIDecoderConfigurationRecord (profiles <= 7, 8-10, > 10).
    pub const DOLBY_VISION_ATOMS: [&'static str; 3] = ["dvvC", "dvcC", "dvwC"];

    /// Bytes 0-1 version, then profile (7 bits), level (6), rpu / el / bl flags, then the compatibility id (high nibble).
    pub fn dolby_vision(d: &[u8]) -> Option<DolbyVisionConfig> {
        if d.len() < 5 {
            return None;
        }
        let bits = i64::from(d[2]) << 8 | i64::from(d[3]);
        Some(DolbyVisionConfig {
            profile: bits >> 9,
            level: (bits >> 3) & 0x3F,
            has_rpu: bits & 4 != 0,
            has_enhancement_layer: bits & 2 != 0,
            has_base_layer: bits & 1 != 0,
            compatibility_id: i64::from(d[4] >> 4),
        })
    }
}

fn remove_emulation_prevention(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut zeros = 0;
    for &x in b {
        if zeros >= 2 && x == 3 {
            zeros = 0;
            continue;
        }
        out.push(x);
        zeros = if x == 0 { zeros + 1 } else { 0 };
    }
    out
}

struct BitReader {
    bytes: Vec<u8>,
    pos: usize,
}

impl BitReader {
    fn new(bytes: Vec<u8>) -> BitReader {
        BitReader { bytes, pos: 0 }
    }

    fn bit(&mut self) -> i64 {
        let Some(&byte) = self.bytes.get(self.pos / 8) else {
            self.pos += 1;
            return 0;
        };
        let v = i64::from(byte >> (7 - (self.pos % 8) as u8)) & 1;
        self.pos += 1;
        v
    }

    fn ue(&mut self) -> i64 {
        let mut zeros = 0;
        while self.bit() == 0 && zeros < 32 && self.pos / 8 < self.bytes.len() {
            zeros += 1;
        }
        let mut v = 0;
        for _ in 0..zeros {
            v = v << 1 | self.bit();
        }
        (1i64 << zeros) - 1 + v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// version 1.0, profile, level, rpu/el/bl flags, compatibility id, then reserved zeros (24 bytes total).
    fn record(profile: i64, level: i64, rpu: bool, el: bool, bl: bool, compat: i64) -> Vec<u8> {
        let mut b = vec![0u8; 24];
        b[0] = 1;
        let bits = (profile << 9) | (level << 3) | (i64::from(rpu) << 2) | (i64::from(el) << 1) | i64::from(bl);
        b[2] = ((bits >> 8) & 0xFF) as u8;
        b[3] = (bits & 0xFF) as u8;
        b[4] = (compat << 4) as u8;
        b
    }

    #[test]
    fn parses_iphone_profile_8_4() {
        let c = CodecConfig::dolby_vision(&record(8, 7, true, false, true, 4)).unwrap();
        let want = DolbyVisionConfig {
            profile: 8,
            level: 7,
            has_rpu: true,
            has_enhancement_layer: false,
            has_base_layer: true,
            compatibility_id: 4,
        };
        assert_eq!(c, want);
        assert_eq!(c.base_layer_color_space(), Some(ColorSpaceID::HlgBT2020));
        assert_eq!(CodecConfig::dolby_vision(&[1, 0, 0]), None);
    }

    #[test]
    fn base_layer_table() {
        let space = |p: i64, id: i64| {
            CodecConfig::dolby_vision(&record(p, 6, true, false, true, id)).and_then(|c| c.base_layer_color_space())
        };
        assert_eq!(space(8, 4), Some(ColorSpaceID::HlgBT2020));
        assert_eq!(space(8, 1), Some(ColorSpaceID::PqBT2020));
        assert_eq!(space(8, 6), Some(ColorSpaceID::PqBT2020));
        assert_eq!(space(8, 2), Some(ColorSpaceID::Rec709));
        assert_eq!(space(5, 0), None);
        assert_eq!(space(8, 0), None);
    }

    #[test]
    fn hevc_reads_chroma_and_bit_depth() {
        // hvcC with general_chroma_format_idc 1 (4:2:0) and bit_depth_luma_minus8 = 2 (10 bit).
        let mut h = vec![0u8; 23];
        h[16] = 0xFC | 1;
        h[17] = 0xF8 | 2;
        assert_eq!(CodecConfig::hevc(&h), Some(result("4:2:0", 10)));
        assert_eq!(CodecConfig::hevc(&h[..17]), None);
    }

    #[test]
    fn vp9_and_av1_records() {
        assert_eq!(CodecConfig::vp9(&[0, 0, 0, 0, 0, 0, 0x64]), Some(result("4:2:2", 6)));
        assert_eq!(CodecConfig::vp9(&[0; 6]), None);
        assert_eq!(CodecConfig::av1(&[0x81, 0, 0x4C, 0]), Some(result("4:2:0", 10)));
        assert_eq!(CodecConfig::av1(&[0x81, 0, 0x20, 0]), Some(result("4:4:4", 12)));
        assert_eq!(CodecConfig::av1(&[0x81, 0, 0]), None);
    }

    #[test]
    fn avc_reads_the_sps_bit_fields() {
        // avcC: version 1, one SPS of 8 bytes: High profile (100), chroma_format_idc 1, bit_depth_luma_minus8 0.
        // After profile/constraints/level: ue(0) = 1, ue(1) = 010, ue(0) = 1 -> bits 1010 1... = 0xA8.
        let sps = [0x67, 100, 0, 30, 0xA8, 0, 0, 0];
        let mut d = vec![1, 100, 0, 30, 0xFF, 0xE1, 0, sps.len() as u8];
        d.extend_from_slice(&sps);
        assert_eq!(CodecConfig::avc(&d), Some(result("4:2:0", 8)));
        // A profile outside the high-profile list stays 4:2:0 8 bit.
        d[9] = 66;
        assert_eq!(CodecConfig::avc(&d), Some(result("4:2:0", 8)));
        assert_eq!(CodecConfig::avc(&d[..8]), None);
    }

    #[test]
    fn emulation_prevention_bytes_are_dropped() {
        assert_eq!(remove_emulation_prevention(&[0, 0, 3, 1, 0, 0, 3]), vec![0, 0, 1, 0, 0]);
    }
}
