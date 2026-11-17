// Swift: ToneMapping.swift
//! HDR to SDR highlight roll-off on the channel maximum (hue-preserving). Identity below `knee`, C1 at the knee.
//! Without a peak (Log sources) the roll-off is exponential with asymptote 1.0; with a peak (display-referred HLG / PQ)
//! it is an extended Reinhard that reaches exactly 1.0 at the peak.

use super::output::SoftGamutCompression;
use super::vec::Vec3;

/// The tone map settings.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ToneMapping {
    knee: f32,
    exposure_stops: f32,
    /// Soft gamut compression of colors outside Rec.709 before the roll-off, instead of clipping them.
    pub compresses_gamut: bool,
}

impl Default for ToneMapping {
    fn default() -> Self {
        ToneMapping::new(0.8, 0.0, false)
    }
}

impl ToneMapping {
    /// Settings; `knee` is clamped to 0...0.99, `exposure_stops` to -4...4.
    pub fn new(knee: f32, exposure_stops: f32, compresses_gamut: bool) -> ToneMapping {
        ToneMapping { knee: knee.clamp(0.0, 0.99), exposure_stops: exposure_stops.clamp(-4.0, 4.0), compresses_gamut }
    }

    /// Where the roll-off starts.
    pub fn knee(&self) -> f32 {
        self.knee
    }

    /// Sets the knee (clamped to 0...0.99).
    pub fn set_knee(&mut self, knee: f32) {
        self.knee = knee.clamp(0.0, 0.99);
    }

    /// Export-time HDR to SDR trim in stops applied before the roll-off.
    pub fn exposure_stops(&self) -> f32 {
        self.exposure_stops
    }

    /// Sets the trim (clamped to -4...4).
    pub fn set_exposure_stops(&mut self, stops: f32) {
        self.exposure_stops = stops.clamp(-4.0, 4.0);
    }

    /// Linear gain of `exposure_stops`.
    pub fn exposure_gain(&self) -> f32 {
        if self.exposure_stops == 0.0 { 1.0 } else { self.exposure_stops.exp2() }
    }

    /// Rec.709-primaries linear light of an HDR source after gamut compression and exposure gain, ready for `apply`.
    pub fn trim(&self, rgb: Vec3) -> Vec3 {
        let mut c = rgb;
        if self.compresses_gamut {
            c = SoftGamutCompression::compress(c);
        }
        if self.exposure_stops == 0.0 { c } else { c * self.exposure_gain() }
    }

    /// Mapped value of the channel maximum, exponential roll-off (no peak).
    pub fn map_max(&self, m: f32) -> f32 {
        if m <= self.knee {
            return m;
        }
        let r = 1.0 - self.knee;
        self.knee + r * (1.0 - (-(m - self.knee) / r).exp())
    }

    /// Mapped value of the channel maximum; with a peak above the knee, `peak` lands on 1.0 and above it clips.
    /// h(x) = x (1 + x / w^2) / (1 + x) on x = (m - knee) / r, w = (peak - knee) / r.
    pub fn map_max_peak(&self, m: f32, peak: Option<f32>) -> f32 {
        let Some(peak) = peak.filter(|p| *p > self.knee + 1e-4) else { return self.map_max(m) };
        if m <= self.knee {
            return m;
        }
        if m >= peak {
            return 1.0;
        }
        let r = 1.0 - self.knee;
        let w = (peak - self.knee) / r;
        let x = (m - self.knee) / r;
        self.knee + r * (x * (1.0 + x / (w * w)) / (1.0 + x))
    }

    /// Roll-off without a peak.
    pub fn apply(&self, rgb: Vec3) -> Vec3 {
        self.apply_peak(rgb, None)
    }

    /// Roll-off with an optional display peak.
    pub fn apply_peak(&self, rgb: Vec3, peak: Option<f32>) -> Vec3 {
        let m = rgb.x.max(rgb.y.max(rgb.z));
        if m <= self.knee {
            return rgb;
        }
        rgb * (self.map_max_peak(m, peak) / m)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_below_knee_and_one_at_peak() {
        let t = ToneMapping::default();
        assert_eq!(t.apply(Vec3::new(0.2, 0.5, 0.7)), Vec3::new(0.2, 0.5, 0.7));
        assert!((t.map_max_peak(4.0, Some(4.0)) - 1.0).abs() < 1e-6);
        assert_eq!(t.map_max_peak(9.0, Some(4.0)), 1.0);
        assert!(t.map_max(50.0) <= 1.0 && t.map_max(2.0) < 1.0);
    }

    #[test]
    fn knee_and_stops_clamp() {
        let mut t = ToneMapping::new(2.0, 9.0, false);
        assert_eq!((t.knee(), t.exposure_stops()), (0.99, 4.0));
        t.set_knee(-1.0);
        t.set_exposure_stops(-9.0);
        assert_eq!((t.knee(), t.exposure_stops()), (0.0, -4.0));
    }
}
