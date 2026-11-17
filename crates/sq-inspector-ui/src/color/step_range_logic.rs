// Swift: Color/StepRangeLogic.swift
//! The three range bars of a Step's Qualifier (Hue, Saturation, Luma) and the Step window's shape titles: the value
//! mapping and the drag rules, shared by the Mac `ColorRangeRow` and the portable `ColorGradeDraw`.

use super::color_range_model::ColorRangeParam;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StepRangeKind {
    Hue,
    Saturation,
    Luma,
}

impl StepRangeKind {
    /// Swift `allCases`.
    pub const ALL: [StepRangeKind; 3] = [StepRangeKind::Hue, StepRangeKind::Saturation, StepRangeKind::Luma];

    pub fn title(self) -> &'static str {
        match self {
            StepRangeKind::Hue => "Hue",
            StepRangeKind::Saturation => "Saturation",
            StepRangeKind::Luma => "Luma",
        }
    }

    pub fn maximum(self) -> f64 {
        if self == StepRangeKind::Hue { 360.0 } else { 100.0 }
    }

    /// The two Qualifier values a bar edits: Hue is center and full width, Saturation and Luma are minimum and maximum.
    pub fn pair(self) -> (ColorRangeParam, ColorRangeParam) {
        match self {
            StepRangeKind::Hue => (ColorRangeParam::HueCenter, ColorRangeParam::HueWidth),
            StepRangeKind::Saturation => (ColorRangeParam::SatMin, ColorRangeParam::SatMax),
            StepRangeKind::Luma => (ColorRangeParam::LumMin, ColorRangeParam::LumMax),
        }
    }

    /// Bar edges (low, high) from the stored pair.
    pub fn bounds(self, first: f64, second: f64) -> (f64, f64) {
        match self {
            StepRangeKind::Hue => ((first - second / 2.0).max(0.0), (first + second / 2.0).min(360.0)),
            StepRangeKind::Saturation | StepRangeKind::Luma => (first, second),
        }
    }

    /// Stored values from the bar edges.
    pub fn params(self, low: f64, high: f64) -> Vec<(ColorRangeParam, f32)> {
        let (a, b) = self.pair();
        match self {
            StepRangeKind::Hue => vec![(a, ((low + high) / 2.0) as f32), (b, (high - low) as f32)],
            StepRangeKind::Saturation | StepRangeKind::Luma => vec![(a, low as f32), (b, high as f32)],
        }
    }
}

/// The bar's pointer math: which part a press grabs (an edge, or the inside to move the range) and the range a drag at
/// `x` gives. A press outside the range centers it there.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RangeBarMath {
    pub maximum: f64,
    pub min_x: f64,
    pub width: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Grab {
    Low,
    High,
    Move { offset: f64, width: f64 },
}

impl RangeBarMath {
    pub const EDGE: f64 = 6.0;

    pub fn x(&self, v: f64) -> f64 {
        self.min_x + (v / self.maximum) * self.width
    }

    pub fn value_at(&self, x: f64) -> f64 {
        (((x - self.min_x) / self.width.max(1.0)) * self.maximum).max(0.0).min(self.maximum)
    }

    pub fn grab(&self, px: f64, low: f64, high: f64) -> Grab {
        if (px - self.x(low)).abs() <= Self::EDGE && (px - self.x(low)).abs() <= (px - self.x(high)).abs() {
            return Grab::Low;
        }
        if (px - self.x(high)).abs() <= Self::EDGE {
            return Grab::High;
        }
        let v = self.value_at(px);
        let w = high - low;
        if v >= low && v <= high {
            Grab::Move { offset: v - low, width: w }
        } else {
            Grab::Move { offset: w / 2.0, width: w }
        }
    }

    pub fn apply(&self, g: Grab, px: f64, low: f64, high: f64) -> (f64, f64) {
        let v = self.value_at(px);
        match g {
            Grab::Low => (v.min(high), high),
            Grab::High => (low, v.max(low)),
            Grab::Move { offset, width } => {
                let lo = (v - offset).max(0.0).min(self.maximum - width);
                (lo, lo + width)
            }
        }
    }

    /// "low – high" as the value column reads it.
    pub fn text(lo: f64, hi: f64) -> String {
        format!("{} \u{2013} {}", lo.round() as i64, hi.round() as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bar() -> RangeBarMath {
        RangeBarMath { maximum: 100.0, min_x: 10.0, width: 200.0 }
    }

    #[test]
    fn hue_bounds_and_params_are_inverse() {
        let (lo, hi) = StepRangeKind::Hue.bounds(350.0, 40.0);
        assert_eq!((lo, hi), (330.0, 360.0));
        let p = StepRangeKind::Hue.params(300.0, 340.0);
        assert_eq!(p, vec![(ColorRangeParam::HueCenter, 320.0), (ColorRangeParam::HueWidth, 40.0)]);
        let p = StepRangeKind::Luma.params(10.0, 80.0);
        assert_eq!(p, vec![(ColorRangeParam::LumMin, 10.0), (ColorRangeParam::LumMax, 80.0)]);
    }

    #[test]
    fn a_press_near_an_edge_grabs_it() {
        let b = bar();
        assert_eq!(b.grab(b.x(20.0) + 2.0, 20.0, 60.0), Grab::Low);
        assert_eq!(b.grab(b.x(60.0) - 2.0, 20.0, 60.0), Grab::High);
    }

    #[test]
    fn inside_moves_and_outside_centers() {
        let b = bar();
        assert_eq!(b.grab(b.x(40.0), 20.0, 60.0), Grab::Move { offset: 20.0, width: 40.0 });
        assert_eq!(b.grab(b.x(90.0), 20.0, 60.0), Grab::Move { offset: 20.0, width: 40.0 });
    }

    #[test]
    fn drags_keep_the_order_and_the_bounds() {
        let b = bar();
        assert_eq!(b.apply(Grab::Low, b.x(80.0), 20.0, 60.0), (60.0, 60.0));
        assert_eq!(b.apply(Grab::High, b.x(5.0), 20.0, 60.0), (20.0, 20.0));
        assert_eq!(b.apply(Grab::Move { offset: 20.0, width: 40.0 }, b.x(100.0), 20.0, 60.0), (60.0, 100.0));
        assert_eq!(RangeBarMath::text(1.4, 59.6), "1 \u{2013} 60");
    }
}

/// The Swift `rangeBarMathMapsEdgesAndMoves` test of ColorGradeDrawTests.
#[cfg(test)]
mod ported_tests {
    use super::*;

    #[test]
    fn range_bar_math_maps_edges_and_moves() {
        let m = RangeBarMath { maximum: 360.0, min_x: 100.0, width: 180.0 };
        assert_eq!(m.value_at(190.0), 180.0);
        assert_eq!(m.grab(m.x(100.0) + 2.0, 100.0, 200.0), Grab::Low);
        assert_eq!(m.apply(Grab::Move { offset: 10.0, width: 50.0 }, m.x(400.0), 0.0, 0.0).1, 360.0);
        assert_eq!(StepRangeKind::Hue.params(20.0, 60.0).iter().map(|p| p.1).collect::<Vec<_>>(), vec![40.0, 40.0]);
        assert_eq!(StepRangeKind::Hue.bounds(10.0, 40.0), (0.0, 30.0));
    }
}
