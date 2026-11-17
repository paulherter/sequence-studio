// Swift: HDRConform.swift
//! The automatic HDR/SDR conform step: moves a clip's picture between SDR and the two HDR transfer curves before the
//! grade. All maths run on display-referred light with 1.0 = reference white (203 nit), the same unit as
//! `hlg_decode` / `pq_decode`. The SDR-to-HDR and HLG/PQ directions are the maths for an HDR target; the compositor's output
//! path is still Rec.709, so they are not wired into rendering yet (as in Swift).

use sq_core_model::{ColorSpaceID, TargetSpace};

use super::gamut::Gamut;
use super::source_space::SourceSpaceExt;
use super::tone_mapping::ToneMapping;
use super::transfer as tf;
use super::vec::Vec3;

/// Where SDR white lands in an HLG picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WhiteReference {
    /// SDR white at 75 % signal (203 nit, the broadcast reference white).
    Percent75,
    /// SDR white at 100 % signal (the HLG peak).
    Percent100,
}

/// One conform direction.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ConformKind {
    /// HLG to SDR.
    HlgToSdr,
    /// PQ to SDR.
    PqToSdr,
    /// SDR to HLG.
    SdrToHlg(WhiteReference),
    /// SDR to PQ with the given peak.
    SdrToPq {
        /// Peak in nits (clamped 10...10000).
        peak_nits: f32,
    },
    /// HLG to PQ.
    HlgToPq,
    /// PQ to HLG.
    PqToHlg,
}

/// The HDR conform maths.
pub struct HdrConform;

impl HdrConform {
    /// The step for a source that is converted to `target`; `None` when nothing is needed (same transfer, log source).
    pub fn kind(source: ColorSpaceID, target: TargetSpace) -> Option<ConformKind> {
        use ColorSpaceID::{HlgBT2020, PqBT2020, Rec709};
        match (source, target) {
            (HlgBT2020, TargetSpace::Rec709 | TargetSpace::Rec2020) => Some(ConformKind::HlgToSdr),
            (PqBT2020, TargetSpace::Rec709 | TargetSpace::Rec2020) => Some(ConformKind::PqToSdr),
            (Rec709, TargetSpace::Rec2020HLG) => Some(ConformKind::SdrToHlg(WhiteReference::Percent75)),
            (Rec709, TargetSpace::Rec2020PQ) => Some(ConformKind::SdrToPq { peak_nits: tf::PQ_REFERENCE_WHITE }),
            (HlgBT2020, TargetSpace::Rec2020PQ) => Some(ConformKind::HlgToPq),
            (PqBT2020, TargetSpace::Rec2020HLG) => Some(ConformKind::PqToHlg),
            _ => None,
        }
    }

    /// Input: the signal of the source (HLG or PQ code values) for the HDR sources, linear Rec.709 light for SDR.
    /// Output: linear Rec.709 light (0...1 after the roll-off) for `*ToSdr`, the target's code values otherwise.
    pub fn convert(v: Vec3, kind: ConformKind, tone_mapping: &ToneMapping) -> Vec3 {
        let to2020 = Gamut::rec709().matrix(Gamut::bt2020());
        match kind {
            ConformKind::HlgToSdr => {
                let c = Gamut::bt2020().matrix(Gamut::rec709()).mul_vec(tf::hlg_decode(v));
                tone_mapping.apply_peak(tone_mapping.trim(c), ColorSpaceID::HlgBT2020.tone_map_peak())
            }
            ConformKind::PqToSdr => {
                let c = Gamut::bt2020().matrix(Gamut::rec709()).mul_vec(v.map(tf::pq_decode));
                tone_mapping.apply_peak(tone_mapping.trim(c), ColorSpaceID::PqBT2020.tone_map_peak())
            }
            ConformKind::HlgToPq => tf::hlg_decode(v).map(tf::pq_encode),
            ConformKind::PqToHlg => tf::hlg_encode(v.map(tf::pq_decode)).min(Vec3::ONE),
            ConformKind::SdrToHlg(reference) => {
                let gain = if reference == WhiteReference::Percent75 { 1.0 } else { tf::hlg_decode(Vec3::ONE).x };
                tf::hlg_encode(to2020.mul_vec(v) * gain).min(Vec3::ONE)
            }
            ConformKind::SdrToPq { peak_nits } => {
                let gain = peak_nits.clamp(10.0, 10_000.0) / tf::PQ_REFERENCE_WHITE;
                (to2020.mul_vec(v) * gain).map(tf::pq_encode)
            }
        }
    }
}
