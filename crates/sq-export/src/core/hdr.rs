// Swift: HDRDelivery.swift, HDRDelivery+Suggestion.swift, HDRToSDR (ExportSettings.swift)

use serde::{Deserialize, Serialize};
use sq_core_model::TargetSpace;

/// HLG or PQ.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HdrTransfer {
    /// Hybrid log-gamma.
    Hlg,
    /// SMPTE ST 2084 (HDR10).
    Pq,
}

impl HdrTransfer {
    /// Both transfers.
    pub const ALL: [HdrTransfer; 2] = [HdrTransfer::Hlg, HdrTransfer::Pq];

    /// Shown name.
    pub fn title(self) -> &'static str {
        if self == HdrTransfer::Hlg { "HLG" } else { "PQ (HDR10)" }
    }

    /// The delivery transfer the export dialog suggests when clips target these spaces: PQ beats HLG (it carries the
    /// brighter range), a Rec.2020 SDR or Rec.709 target suggests nothing.
    pub fn suggested(targets: impl IntoIterator<Item = TargetSpace>) -> Option<HdrTransfer> {
        let set: Vec<TargetSpace> = targets.into_iter().collect();
        if set.contains(&TargetSpace::Rec2020PQ) {
            Some(HdrTransfer::Pq)
        } else if set.contains(&TargetSpace::Rec2020HLG) {
            Some(HdrTransfer::Hlg)
        } else {
            None
        }
    }
}

/// HDR delivery tagging of the exported file (an SDR to HLG/PQ conform): Rec.2020 primaries and matrix, the HLG or PQ
/// transfer, plus mastering display (MDCV) and content light level (CLLI) metadata. Pure data. Needs a 10-bit codec:
/// only HEVC (Main 10) carries it; H.264 and ProRes ignore the setting.
///
/// Reading is tolerant per key (a wrong type reads as the default) and the values are clamped.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "serde_json::Value")]
pub struct HdrDelivery {
    /// Transfer.
    pub transfer: HdrTransfer,
    /// Peak luminance of the mastering display and of the brightest pixel, in nits, 100...10000.
    pub peak_nits: f64,
    /// Maximum frame-average light level in nits, at most `peak_nits`.
    pub frame_average_nits: f64,
    /// Black level of the mastering display in nits.
    pub min_nits: f64,
}

impl From<serde_json::Value> for HdrDelivery {
    fn from(v: serde_json::Value) -> HdrDelivery {
        fn get<T: serde::de::DeserializeOwned>(v: &serde_json::Value, k: &str) -> Option<T> {
            v.get(k).and_then(|x| serde_json::from_value(x.clone()).ok())
        }
        HdrDelivery::new(
            get(&v, "transfer").unwrap_or(HdrTransfer::Pq),
            get(&v, "peakNits").unwrap_or(1000.0),
            get(&v, "frameAverageNits").unwrap_or(400.0),
            get(&v, "minNits").unwrap_or(0.005),
        )
    }
}

impl Default for HdrDelivery {
    fn default() -> HdrDelivery {
        HdrDelivery::new(HdrTransfer::Pq, 1000.0, 400.0, 0.005)
    }
}

fn be16(v: f64) -> [u8; 2] {
    // Swift `UInt16(clamping: Int)`.
    (v as i64).clamp(0, i64::from(u16::MAX)).to_be_bytes()[6..].try_into().unwrap_or([0; 2])
}

fn be32(v: f64) -> [u8; 4] {
    (v as i64).clamp(0, i64::from(u32::MAX)).to_be_bytes()[4..].try_into().unwrap_or([0; 4])
}

impl HdrDelivery {
    /// Values are clamped: peak 100...10000, frame average 1...peak, black 0...5.
    pub fn new(transfer: HdrTransfer, peak_nits: f64, frame_average_nits: f64, min_nits: f64) -> HdrDelivery {
        let peak = peak_nits.clamp(100.0, 10_000.0);
        HdrDelivery {
            transfer,
            peak_nits: peak,
            frame_average_nits: frame_average_nits.clamp(1.0, peak),
            min_nits: min_nits.clamp(0.0, 5.0),
        }
    }

    /// 24 bytes as in `kCMFormatDescriptionExtension_MasteringDisplayColorVolume`: primaries G, B, R then white point
    /// (x, y as UInt16 in 0.00002 units), then max and min luminance (UInt32 in 0.0001 nit). Display: P3 primaries, D65.
    pub fn mastering_display_data(&self) -> Vec<u8> {
        let c = |v: f64| be16((v / 0.00002).round());
        let mut b = Vec::with_capacity(24);
        for (x, y) in [(0.265, 0.690), (0.150, 0.060), (0.680, 0.320), (0.3127, 0.3290)] {
            b.extend_from_slice(&c(x));
            b.extend_from_slice(&c(y));
        }
        b.extend_from_slice(&be32((self.peak_nits / 0.0001).round()));
        b.extend_from_slice(&be32((self.min_nits / 0.0001).round()));
        b
    }

    /// 4 bytes as in `kCMFormatDescriptionExtension_ContentLightLevelInfo`: MaxCLL then MaxFALL, UInt16 nits.
    pub fn content_light_level_data(&self) -> Vec<u8> {
        let mut b = be16(self.peak_nits.round()).to_vec();
        b.extend_from_slice(&be16(self.frame_average_nits.round()));
        b
    }
}

/// Export-time HDR to SDR conversion options: the tone map itself is always on for HDR sources; this trims it for the
/// file (a brighter or darker result, colors outside Rec.709 eased in instead of clipped). Not HDR tagging.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "HdrToSdrWire")]
pub struct HdrToSdr {
    /// Gain in stops before the roll-off, -4...4.
    pub exposure_stops: f64,
    /// Ease colors outside Rec.709 in instead of clipping them.
    pub compresses_gamut: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HdrToSdrWire {
    exposure_stops: f64,
    compresses_gamut: bool,
}

impl From<HdrToSdrWire> for HdrToSdr {
    fn from(w: HdrToSdrWire) -> HdrToSdr {
        HdrToSdr::new(w.exposure_stops, w.compresses_gamut)
    }
}

impl Default for HdrToSdr {
    fn default() -> HdrToSdr {
        HdrToSdr::new(0.0, true)
    }
}

impl HdrToSdr {
    /// Exposure is clamped to -4...4.
    pub fn new(exposure_stops: f64, compresses_gamut: bool) -> HdrToSdr {
        HdrToSdr { exposure_stops: exposure_stops.clamp(-4.0, 4.0), compresses_gamut }
    }

    /// Neutral values: same output as no setting except for the gamut compression.
    pub fn is_default(&self) -> bool {
        self.exposure_stops == 0.0 && !self.compresses_gamut
    }
}
