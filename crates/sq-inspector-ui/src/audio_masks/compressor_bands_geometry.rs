// Swift: CompressorBandsGeometry.swift
//! Pure geometry of the 4-band strip: log frequency axis 20 Hz...20 kHz across `width`.

use super::track_audio_inspector_model::CrossoverRules;

/// Pure geometry of the 4-band strip: log frequency axis 20 Hz...20 kHz across `width`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CompressorBandsGeometry {
    pub width: f64,
    pub handle_hit_radius: f64,
}

impl CompressorBandsGeometry {
    /// Height of the strip with its frequency labels (`Theme.Inspector.bandsHeight`).
    pub const STRIP_HEIGHT: f64 = 84.0;
    /// Gain reduction that fills a bar completely.
    pub const FULL_SCALE_GAIN_REDUCTION_DB: f64 = 24.0;

    pub fn new(width: f64) -> Self {
        CompressorBandsGeometry { width, handle_hit_radius: 6.0 }
    }

    fn log_min() -> f64 {
        CrossoverRules::MIN_HZ.ln()
    }

    fn log_span() -> f64 {
        CrossoverRules::MAX_HZ.ln() - CrossoverRules::MIN_HZ.ln()
    }

    pub fn x(&self, hz: f64) -> f64 {
        let h = hz.clamp(CrossoverRules::MIN_HZ, CrossoverRules::MAX_HZ);
        ((h.ln() - Self::log_min()) / Self::log_span()) * self.width
    }

    pub fn hz(&self, x: f64) -> f64 {
        if self.width <= 0.0 {
            return CrossoverRules::MIN_HZ;
        }
        let f = (x / self.width).clamp(0.0, 1.0);
        (Self::log_min() + f * Self::log_span()).exp()
    }

    /// x ranges of the 4 bands, low to high, tiling 0...width, as (lower, upper).
    pub fn band_ranges(&self, crossovers_hz: &[f64]) -> Vec<(f64, f64)> {
        let mut edges = vec![0.0];
        edges.extend(crossovers_hz.iter().map(|h| self.x(*h)));
        edges.push(self.width);
        (0..edges.len() - 1).map(|i| (edges[i], edges[i + 1])).collect()
    }

    /// Index of the crossover handle within `handle_hit_radius` of `x`, nearest first.
    pub fn handle_index(&self, x: f64, crossovers_hz: &[f64]) -> Option<usize> {
        let hits: Vec<(usize, f64)> = crossovers_hz
            .iter()
            .enumerate()
            .map(|(i, h)| (i, (self.x(*h) - x).abs()))
            .filter(|(_, d)| *d <= self.handle_hit_radius)
            .collect();
        // Swift `min(by: <)` keeps the first of equal elements.
        let mut best: Option<(usize, f64)> = None;
        for h in hits {
            if best.is_none_or(|b| h.1 < b.1) {
                best = Some(h);
            }
        }
        best.map(|b| b.0)
    }

    /// Frequency for dragging crossover `index` to `x`, clamped so the order is kept.
    pub fn dragged_hz(&self, index: usize, x: f64, crossovers_hz: &[f64]) -> f64 {
        CrossoverRules::clamp(self.hz(x), index, crossovers_hz)
    }

    /// 0...1 bar fill for a gain reduction in dB (positive = reduction).
    pub fn bar_fraction(gain_reduction_db: f64) -> f64 {
        (gain_reduction_db / Self::FULL_SCALE_GAIN_REDUCTION_DB).clamp(0.0, 1.0)
    }

    /// Crossover label: "120", "4.5k".
    pub fn hz_text(hz: f64) -> String {
        if hz >= 1000.0 { format!("{:.1}k", hz / 1000.0) } else { format!("{hz:.0}") }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g() -> CompressorBandsGeometry {
        CompressorBandsGeometry::new(600.0)
    }

    #[test]
    fn log_axis_endpoints_and_round_trip() {
        let g = g();
        assert!(g.x(20.0).abs() < 1e-9);
        assert!((g.x(20000.0) - 600.0).abs() < 1e-9);
        assert!((g.x(632.455532) - 300.0).abs() < 0.01); // geometric mean
        for hz in [50.0, 120.0, 900.0, 4500.0, 16000.0] {
            assert!((g.hz(g.x(hz)) - hz).abs() < 1e-6 * hz);
        }
    }

    #[test]
    fn band_ranges_tile_the_axis() {
        let r = g().band_ranges(&[120.0, 900.0, 4500.0]);
        assert_eq!(r.len(), 4);
        assert!(r[0].0 == 0.0 && (r[3].1 - 600.0).abs() < 1e-9);
        for i in 0..3 {
            assert_eq!(r[i].1, r[i + 1].0);
        }
    }

    #[test]
    fn hit_test_picks_nearest_handle() {
        let g = g();
        let c = [120.0, 900.0, 4500.0];
        assert_eq!(g.handle_index(g.x(900.0) + 3.0, &c), Some(1));
        assert_eq!(g.handle_index(g.x(900.0) + 30.0, &c), None);
    }

    #[test]
    fn drag_keeps_order() {
        let g = g();
        let c = [120.0, 900.0, 4500.0];
        let hz = g.dragged_hz(0, g.x(3000.0), &c);
        assert!(hz < 900.0 && hz > CrossoverRules::MIN_HZ);
        assert!(g.dragged_hz(2, -50.0, &c) > 900.0);
    }

    #[test]
    fn gain_reduction_bar_height() {
        assert_eq!(CompressorBandsGeometry::bar_fraction(0.0), 0.0);
        assert_eq!(CompressorBandsGeometry::bar_fraction(12.0), 0.5);
        assert_eq!(CompressorBandsGeometry::bar_fraction(99.0), 1.0);
        assert_eq!(CompressorBandsGeometry::bar_fraction(-3.0), 0.0);
    }
}
