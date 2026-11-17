// Swift: ColorPipeline.swift (SourceColorSpace), ToneMapping.swift (toneMapPeak), ClipColorPipeline.swift (init from id)
//! The clip source color space: transfer plus gamut. Swift keeps a second enum with the same cases next to
//! `ColorSpaceID`; here the saved `ColorSpaceID` is used directly and this trait adds the render side.

use sq_core_model::ColorSpaceID;

use super::gamut::Gamut;
use super::transfer as tf;
use super::vec::Vec3;

/// The clip source color space (the saved id).
pub type SourceColorSpace = ColorSpaceID;

/// Gamut, curves and tone map peak of a source color space.
pub trait SourceSpaceExt: Copy {
    /// Primaries of the source.
    fn gamut(self) -> &'static Gamut;
    /// Log and HDR sources (scene or display light above 1.0) get the tone map in automatic conversion; Rec.709 bypasses
    /// it. (Swift `isHDR`; not the same as `ColorSpaceIdExt::is_hdr`, which is true only for HLG and PQ.)
    fn gets_tone_map(self) -> bool;
    /// Source-encoded (range-expanded 0...1) to source-linear.
    fn decode(self, v: Vec3) -> Vec3;
    /// Source-linear to source-encoded (exact inverse of `decode`).
    fn encode(self, v: Vec3) -> Vec3;
    /// Display-referred peak (1.0 = 203 nit) the tone map rolls off to: HLG's nominal 1000 nit display and PQ graded for
    /// 1000 nits. `None` for Rec.709 and Log (scene light, open-ended roll-off).
    fn tone_map_peak(self) -> Option<f32>;
}

impl SourceSpaceExt for ColorSpaceID {
    fn gamut(self) -> &'static Gamut {
        use ColorSpaceID::*;
        match self {
            SLog3SGamut3Cine => Gamut::s_gamut3_cine(),
            HlgBT2020 | AppleLog | PqBT2020 | CanonLogBT2020 | CanonLog2BT2020 | CanonLog3BT2020 | NLogBT2020 => {
                Gamut::bt2020()
            }
            Rec709 | CanonLogBT709 | CanonLog2BT709 | CanonLog3BT709 => Gamut::rec709(),
            VLogVGamut => Gamut::v_gamut(),
            DLogDGamut => Gamut::d_gamut(),
            CanonLogCinemaGamut | CanonLog2CinemaGamut | CanonLog3CinemaGamut => Gamut::cinema_gamut(),
            LogC3WideGamut3 => Gamut::arri_wide_gamut3(),
            LogC4WideGamut4 => Gamut::arri_wide_gamut4(),
            Log3G10RedWideGamut => Gamut::red_wide_gamut_rgb(),
            BmdFilmGen5WideGamut => Gamut::blackmagic_wide_gamut(),
            FLog2FGamutC => Gamut::f_gamut_c(),
            AcesCCTAP1 => Gamut::aces_ap1(),
        }
    }

    fn gets_tone_map(self) -> bool {
        self != ColorSpaceID::Rec709
    }

    fn decode(self, v: Vec3) -> Vec3 {
        use ColorSpaceID::*;
        match self {
            SLog3SGamut3Cine => v.map(tf::slog3_decode_legal),
            HlgBT2020 => tf::hlg_decode(v),
            Rec709 => v.map(tf::bt709_inverse_oetf),
            VLogVGamut => v.map(tf::vlog_decode_legal),
            AppleLog => v.map(tf::apple_log_decode),
            PqBT2020 => v.map(tf::pq_decode),
            DLogDGamut => v.map(tf::dlog_decode_legal),
            CanonLogCinemaGamut | CanonLogBT2020 | CanonLogBT709 => v.map(tf::canon_log_decode_legal),
            CanonLog2CinemaGamut | CanonLog2BT2020 | CanonLog2BT709 => v.map(tf::canon_log2_decode_legal),
            CanonLog3CinemaGamut | CanonLog3BT2020 | CanonLog3BT709 => v.map(tf::canon_log3_decode_legal),
            LogC3WideGamut3 => v.map(tf::log_c3_decode_legal),
            LogC4WideGamut4 => v.map(tf::log_c4_decode_legal),
            Log3G10RedWideGamut => v.map(tf::log3g10_decode),
            BmdFilmGen5WideGamut => v.map(tf::bmd_film_gen5_decode_legal),
            NLogBT2020 => v.map(tf::n_log_decode_legal),
            FLog2FGamutC => v.map(tf::f_log2_decode_legal),
            AcesCCTAP1 => v.map(tf::aces_cct_decode),
        }
    }

    fn encode(self, v: Vec3) -> Vec3 {
        use ColorSpaceID::*;
        match self {
            SLog3SGamut3Cine => v.map(tf::slog3_encode_legal),
            HlgBT2020 => tf::hlg_encode(v),
            Rec709 => v.map(tf::bt709_oetf),
            VLogVGamut => v.map(tf::vlog_encode_legal),
            AppleLog => v.map(tf::apple_log_encode),
            PqBT2020 => v.map(tf::pq_encode),
            DLogDGamut => v.map(tf::dlog_encode_legal),
            CanonLogCinemaGamut | CanonLogBT2020 | CanonLogBT709 => v.map(tf::canon_log_encode_legal),
            CanonLog2CinemaGamut | CanonLog2BT2020 | CanonLog2BT709 => v.map(tf::canon_log2_encode_legal),
            CanonLog3CinemaGamut | CanonLog3BT2020 | CanonLog3BT709 => v.map(tf::canon_log3_encode_legal),
            LogC3WideGamut3 => v.map(tf::log_c3_encode_legal),
            LogC4WideGamut4 => v.map(tf::log_c4_encode_legal),
            Log3G10RedWideGamut => v.map(tf::log3g10_encode),
            BmdFilmGen5WideGamut => v.map(tf::bmd_film_gen5_encode_legal),
            NLogBT2020 => v.map(tf::n_log_encode_legal),
            FLog2FGamutC => v.map(tf::f_log2_encode_legal),
            AcesCCTAP1 => v.map(tf::aces_cct_encode),
        }
    }

    fn tone_map_peak(self) -> Option<f32> {
        match self {
            ColorSpaceID::HlgBT2020 => Some(tf::hlg_decode(Vec3::ONE).x),
            ColorSpaceID::PqBT2020 => Some(1000.0 / tf::PQ_REFERENCE_WHITE),
            _ => None,
        }
    }
}
