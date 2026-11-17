//! Which streams the direct VideoToolbox route takes and how their pictures are laid out (portable, no platform calls).

use sq_core_model::VideoTrackInfo;
use sq_frame::sqframe::{SQFrameColorSpace, SQFramePixelFormat};
use sq_gpu::frames::PlaneLayout;

/// Codecs VideoToolbox decodes here (FFmpeg's names in `DemuxedFormat::codec`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    H264,
    Hevc,
    ProRes,
}

impl Codec {
    pub fn from_name(name: &str) -> Option<Codec> {
        match name {
            "h264" | "avc1" => Some(Codec::H264),
            "hevc" | "hvc1" | "hev1" => Some(Codec::Hevc),
            "prores" => Some(Codec::ProRes),
            _ => None,
        }
    }

    /// The CoreMedia codec type (FourCC). ProRes: one decoder takes every profile, 422 standard stands for all.
    pub fn fourcc(self) -> [u8; 4] {
        match self {
            Codec::H264 => *b"avc1",
            Codec::Hevc => *b"hvc1",
            Codec::ProRes => *b"apcn",
        }
    }

    /// The sample-description atom that carries the codec configuration record (`extradata`), if the codec has one.
    pub fn config_atom(self) -> Option<&'static str> {
        match self {
            Codec::H264 => Some("avcC"),
            Codec::Hevc => Some("hvcC"),
            Codec::ProRes => None,
        }
    }

    /// True when `extradata` is the length-prefixed (avcC / hvcC) record VideoToolbox needs; Annex B streams are not.
    pub fn accepts_extradata(self, extradata: &[u8]) -> bool {
        match self {
            Codec::H264 | Codec::Hevc => extradata.first() == Some(&1),
            Codec::ProRes => true,
        }
    }

    /// True when decoding can start at `sample` with an empty reference list by the stream's own rules: an IDR (H.264),
    /// IDR or BLA (HEVC) picture clears the decoder's references, ProRes is intra-only. A non-IDR sync sample (H.264
    /// open GOP, HEVC CRA) does not: a decoder that held other pictures keeps predicting from them.
    /// `extradata` is the avcC / hvcC record (its NAL length size); `sample` is length-prefixed.
    pub fn clears_references(self, extradata: &[u8], sample: &[u8]) -> bool {
        let length_size = match self {
            Codec::ProRes => return true,
            Codec::H264 => extradata.get(4).map(|b| usize::from(b & 3) + 1),
            Codec::Hevc => extradata.get(21).map(|b| usize::from(b & 3) + 1),
        };
        let Some(length_size) = length_size else { return false };
        let mut at = 0;
        while at + length_size < sample.len() {
            let len = sample[at..at + length_size].iter().fold(0usize, |n, b| (n << 8) | usize::from(*b));
            if len == 0 || at + length_size + len > sample.len() {
                return false;
            }
            let head = sample[at + length_size];
            match self {
                Codec::H264 => match head & 0x1f {
                    5 => return true,
                    1..=4 => return false,
                    _ => {}
                },
                _ => match (head >> 1) & 0x3f {
                    16..=20 => return true,
                    0..=15 | 21 => return false,
                    _ => {}
                },
            }
            at += length_size + len;
        }
        false
    }
}

/// How a stream's range is handled: what VideoToolbox is asked for and how the pictures are then read.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StreamRange {
    /// The stream flags full range: the full-range layout is requested so no codes are rescaled.
    pub flagged_full: bool,
    /// The pictures are read as full range (see `sq_media_ffmpeg::decode::frame_color`).
    pub read_full: bool,
}

/// The bi-planar CoreVideo layout VideoToolbox is asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelKind {
    /// `420v`: 8-bit 4:2:0, video range.
    Nv12,
    /// `x420`: 10-bit 4:2:0 in 16-bit words.
    P010,
    /// `x422`: 10-bit 4:2:2 in 16-bit words.
    P210,
}

impl PixelKind {
    /// 4:4:4 (ProRes 4444) has no bi-planar layout here: it stays on the FFmpeg software route.
    pub fn for_stream(bit_depth: i64, chroma: &str) -> Option<PixelKind> {
        match (chroma, bit_depth > 8) {
            ("4:2:0", false) => Some(PixelKind::Nv12),
            ("4:2:0", true) => Some(PixelKind::P010),
            ("4:2:2", _) => Some(PixelKind::P210),
            _ => None,
        }
    }

    /// The layout asked of VideoToolbox. `full` = the stream is full range: the full-range twin is asked for then, because
    /// a video-range request makes VideoToolbox rescale the codes, which wrecks log footage (blue cast, banding).
    pub fn fourcc(self, full: bool) -> [u8; 4] {
        match (self, full) {
            (PixelKind::Nv12, false) => *b"420v",
            (PixelKind::Nv12, true) => *b"420f",
            (PixelKind::P010, false) => *b"x420",
            (PixelKind::P010, true) => *b"xf20",
            (PixelKind::P210, false) => *b"x422",
            (PixelKind::P210, true) => *b"xf22",
        }
    }

    /// The kind of a delivered buffer, either range.
    pub fn from_fourcc(code: u32) -> Option<PixelKind> {
        [PixelKind::Nv12, PixelKind::P010, PixelKind::P210]
            .into_iter()
            .find(|k| [false, true].iter().any(|f| u32::from_be_bytes(k.fourcc(*f)) == code))
    }

    pub fn is_sixteen_bit(self) -> bool {
        self != PixelKind::Nv12
    }

    /// The frame format; `full` = read the codes as full range.
    pub fn pixel_format(self, full: bool) -> SQFramePixelFormat {
        match (self, full) {
            (PixelKind::Nv12, false) => SQFramePixelFormat::Nv12,
            (PixelKind::Nv12, true) => SQFramePixelFormat::Nv12FullRange,
            (PixelKind::P010, false) => SQFramePixelFormat::P010,
            (PixelKind::P010, true) => SQFramePixelFormat::P010FullRange,
            (PixelKind::P210, false) => SQFramePixelFormat::P210,
            (PixelKind::P210, true) => SQFramePixelFormat::P210FullRange,
        }
    }

    /// 4:2:2 shares the P010 layout: the chroma plane's own size says it is full height.
    pub fn plane_layout(self) -> PlaneLayout {
        if self.is_sixteen_bit() { PlaneLayout::P010 } else { PlaneLayout::Nv12 }
    }
}

/// The neutral color space of the track's tags (same table as the FFmpeg decoder's `frame_color`).
pub fn color_space(info: &VideoTrackInfo) -> SQFrameColorSpace {
    let tag = |t: &Option<String>| t.clone().unwrap_or_default();
    let (primaries, transfer, matrix) = (tag(&info.color_primaries), tag(&info.transfer), tag(&info.matrix));
    let bt2020 = |s: &str| s == "ITU_R_2020";
    let bt709 = |s: &str| s == "ITU_R_709_2";
    let bt601 = |s: &str| matches!(s, "EBU_3213" | "SMPTE_C" | "ITU_R_601_4");
    if transfer == "SMPTE_ST_2084_PQ" && (bt2020(&primaries) || bt2020(&matrix)) {
        SQFrameColorSpace::Rec2020PQ
    } else if transfer == "ITU_R_2100_HLG" && (bt2020(&primaries) || bt2020(&matrix)) {
        SQFrameColorSpace::Rec2020HLG
    } else if bt2020(&primaries) || bt2020(&matrix) {
        SQFrameColorSpace::Rec2020
    } else if bt709(&primaries) || bt709(&matrix) {
        SQFrameColorSpace::Rec709
    } else if bt601(&primaries) || bt601(&matrix) {
        SQFrameColorSpace::Rec601
    } else {
        SQFrameColorSpace::Unspecified
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codec_names_and_records() {
        assert_eq!(Codec::from_name("hevc"), Some(Codec::Hevc));
        assert_eq!(Codec::from_name("h264"), Some(Codec::H264));
        assert_eq!(Codec::from_name("prores"), Some(Codec::ProRes));
        assert_eq!(Codec::from_name("vp9"), None);
        assert!(Codec::H264.accepts_extradata(&[1, 100, 0, 31]));
        assert!(!Codec::H264.accepts_extradata(&[0, 0, 0, 1, 0x67]), "Annex B is not an avcC record");
        assert!(!Codec::Hevc.accepts_extradata(&[]));
        assert!(Codec::ProRes.accepts_extradata(&[]));
        assert_eq!(Codec::Hevc.config_atom(), Some("hvcC"));
    }

    /// Only an IDR (BLA) picture lets a seek keep the decoder's session: the C2177 sync samples alternate IDR / non-IDR I.
    #[test]
    fn idr_pictures_clear_references_non_idr_sync_samples_do_not() {
        let avcc = [1, 100, 0, 31, 0xff];
        // 4-byte lengths: AUD (9), SEI (6), then the slice.
        let sample = |slice: u8| [&[0, 0, 0, 2, 9, 0xf0][..], &[0, 0, 0, 1, 6], &[0, 0, 0, 2, slice, 0x88]].concat();
        assert!(Codec::H264.clears_references(&avcc, &sample(0x65)), "IDR");
        assert!(!Codec::H264.clears_references(&avcc, &sample(0x41)), "non-IDR I of an open GOP");
        assert!(!Codec::H264.clears_references(&avcc, &[0, 0, 0, 9, 0x65]), "truncated");
        let mut hvcc = vec![0u8; 23];
        hvcc[21] = 3;
        let nal = |t: u8| [0, 0, 0, 2, t << 1, 1];
        assert!(Codec::Hevc.clears_references(&hvcc, &nal(19)), "IDR_W_RADL");
        assert!(!Codec::Hevc.clears_references(&hvcc, &nal(21)), "CRA");
        assert!(
            !Codec::Hevc.clears_references(&hvcc, &[&nal(35)[..], &nal(1)].concat()),
            "AUD, then a trailing picture"
        );
        assert!(Codec::ProRes.clears_references(&[], &[]));
    }

    #[test]
    fn pixel_kinds_follow_depth_and_chroma() {
        assert_eq!(PixelKind::for_stream(8, "4:2:0"), Some(PixelKind::Nv12));
        assert_eq!(PixelKind::for_stream(10, "4:2:0"), Some(PixelKind::P010));
        assert_eq!(PixelKind::for_stream(10, "4:2:2"), Some(PixelKind::P210));
        assert_eq!(PixelKind::for_stream(12, "4:4:4"), None);
        for k in [PixelKind::Nv12, PixelKind::P010, PixelKind::P210] {
            for full in [false, true] {
                assert_eq!(PixelKind::from_fourcc(u32::from_be_bytes(k.fourcc(full))), Some(k));
            }
        }
        assert_eq!(&PixelKind::P210.fourcc(true), b"xf22", "a full-range request keeps log codes unscaled");
        assert_eq!(PixelKind::from_fourcc(0), None);
        assert_eq!(PixelKind::P210.plane_layout(), PlaneLayout::P010);
        assert_eq!(PixelKind::Nv12.pixel_format(false), SQFramePixelFormat::Nv12);
        assert_eq!(PixelKind::P010.pixel_format(true), SQFramePixelFormat::P010FullRange);
        assert_eq!(
            PixelKind::P210.pixel_format(true),
            SQFramePixelFormat::P210FullRange,
            "Sony XAVC S-I 4:2:2 is full range"
        );
    }
}
