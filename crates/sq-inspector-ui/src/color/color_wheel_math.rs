// Swift: Color/ColorWheelMath.swift
//! Pure geometry for the color wheel control. Disc-local coordinates, y up, origin at the disc center.

use sq_core_color::StepPrimariesExt;
use sq_core_model::{ColorTriple, StepPrimaries};
use std::f64::consts::PI;

/// hue in degrees [0, 360), 0 = +x, counter-clockwise. amount 0…1 (fraction of the radius).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColorWheelValue {
    pub hue: f64,
    pub amount: f64,
}

impl ColorWheelValue {
    pub fn is_neutral(&self) -> bool {
        self.amount == 0.0
    }
}

/// Pure geometry for the color wheel control.
pub struct ColorWheelMath;

impl ColorWheelMath {
    pub const RESET: ColorWheelValue = ColorWheelValue { hue: 0.0, amount: 0.0 };
    /// Shift-drag moves the puck at this fraction of the pointer speed.
    pub const FINE_FACTOR: f64 = 0.2;

    pub fn value(dx: f64, dy: f64, radius: f64) -> ColorWheelValue {
        if radius <= 0.0 {
            return Self::RESET;
        }
        let len = dx.hypot(dy);
        if len <= 0.0 {
            return Self::RESET;
        }
        let mut hue = dy.atan2(dx) * 180.0 / PI;
        if hue < 0.0 {
            hue += 360.0;
        }
        if hue >= 360.0 {
            hue -= 360.0;
        }
        ColorWheelValue { hue, amount: (len / radius).min(1.0) }
    }

    pub fn offset(v: ColorWheelValue, radius: f64) -> (f64, f64) {
        let a = v.amount.clamp(0.0, 1.0) * radius;
        let r = v.hue * PI / 180.0;
        (a * r.cos(), a * r.sin())
    }

    /// Absolute drag follows the pointer; fine drag moves the puck relative to where it started.
    pub fn drag(
        start: ColorWheelValue,
        start_point: (f64, f64),
        point: (f64, f64),
        radius: f64,
        fine: bool,
    ) -> ColorWheelValue {
        if !fine {
            return Self::value(point.0, point.1, radius);
        }
        let o = Self::offset(start, radius);
        Self::value(
            o.0 + (point.0 - start_point.0) * Self::FINE_FACTOR,
            o.1 + (point.1 - start_point.1) * Self::FINE_FACTOR,
            radius,
        )
    }

    /// Side slider: `y` is measured from the top edge; top = +1, middle = 0, bottom = -1.
    pub fn master_for_y(y: f64, height: f64) -> f64 {
        if height <= 0.0 {
            return 0.0;
        }
        (1.0 - 2.0 * y / height).clamp(-1.0, 1.0)
    }

    pub fn y_for_master(m: f64, height: f64) -> f64 {
        (1.0 - m.clamp(-1.0, 1.0)) / 2.0 * height
    }

    /// Slider below the disc (version 9): `x` is measured from the left edge; left = -1, middle = 0, right = +1.
    pub fn master_for_x(x: f64, width: f64) -> f64 {
        if width <= 0.0 {
            return 0.0;
        }
        (2.0 * x / width - 1.0).clamp(-1.0, 1.0)
    }

    pub fn x_for_master(m: f64, width: f64) -> f64 {
        (m.clamp(-1.0, 1.0) + 1.0) / 2.0 * width
    }
}

/// How a Pro Primaries wheel (Lift, Gamma, Gain, Offset) reads and writes a Step's per-channel triple. The puck is the
/// triple's chroma (the channels around their mean, hue 0 = red), the side slider is the mean (the master).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PrimaryWheel {
    Lift,
    Gamma,
    Gain,
    Offset,
}

impl PrimaryWheel {
    /// Swift `allCases`.
    pub const ALL: [PrimaryWheel; 4] =
        [PrimaryWheel::Lift, PrimaryWheel::Gamma, PrimaryWheel::Gain, PrimaryWheel::Offset];

    pub fn title(self) -> &'static str {
        match self {
            PrimaryWheel::Lift => "Lift",
            PrimaryWheel::Gamma => "Gamma",
            PrimaryWheel::Gain => "Gain",
            PrimaryWheel::Offset => "Offset",
        }
    }

    /// Chroma at the rim of the disc (per channel, around the mean).
    fn rim(self) -> f32 {
        match self {
            PrimaryWheel::Lift | PrimaryWheel::Offset => 0.25,
            PrimaryWheel::Gamma | PrimaryWheel::Gain => 0.5,
        }
    }

    /// Lift and Offset add (master -1...1 is -0.5...0.5); Gamma and Gain scale (master -1...1 is x0.5...x2).
    fn is_additive(self) -> bool {
        self == PrimaryWheel::Lift || self == PrimaryWheel::Offset
    }

    fn channel_range(self) -> (f32, f32) {
        match self {
            PrimaryWheel::Lift => StepPrimaries::LIFT_RANGE,
            PrimaryWheel::Offset => StepPrimaries::OFFSET_RANGE,
            PrimaryWheel::Gamma => StepPrimaries::GAMMA_RANGE,
            PrimaryWheel::Gain => StepPrimaries::GAIN_RANGE,
        }
    }

    pub fn triple_of(self, p: &StepPrimaries) -> ColorTriple {
        match self {
            PrimaryWheel::Lift => p.lift,
            PrimaryWheel::Gamma => p.gamma,
            PrimaryWheel::Gain => p.gain,
            PrimaryWheel::Offset => p.offset,
        }
    }

    pub fn write(self, t: ColorTriple, p: &mut StepPrimaries) {
        match self {
            PrimaryWheel::Lift => p.lift = t,
            PrimaryWheel::Gamma => p.gamma = t,
            PrimaryWheel::Gain => p.gain = t,
            PrimaryWheel::Offset => p.offset = t,
        }
    }

    fn mean(t: &ColorTriple) -> f32 {
        (t.r + t.g + t.b) / 3.0
    }

    /// The master slider's value, -1...1.
    pub fn master_of(self, t: &ColorTriple) -> f64 {
        let m = Self::mean(t);
        let v = if self.is_additive() { f64::from(m) * 2.0 } else { f64::from(m.max(0.0001)).log2() };
        v.clamp(-1.0, 1.0)
    }

    /// The puck of a triple.
    pub fn puck_of(self, t: &ColorTriple) -> ColorWheelValue {
        let m = Self::mean(t);
        let cr = t.r - m;
        let cg = t.g - m;
        let cb = t.b - m;
        let x = (2.0 / 3.0) * (f64::from(cr) - 0.5 * f64::from(cg) - 0.5 * f64::from(cb));
        let y = (2.0 / 3.0) * (3.0_f64.sqrt() / 2.0) * f64::from(cg - cb);
        let k = x.hypot(y);
        if k <= 1e-6 {
            return ColorWheelMath::RESET;
        }
        let mut hue = y.atan2(x) * 180.0 / PI;
        if hue < 0.0 {
            hue += 360.0;
        }
        // A scaling wheel's chroma is relative to its mean, so the rim is the same at every master.
        let scale = if self.is_additive() { 1.0 } else { f64::from(m.max(0.0001)) };
        ColorWheelValue { hue, amount: (k / scale / f64::from(self.rim())).min(1.0) }
    }

    /// The triple for a puck and a master value (clamped to the channel range).
    pub fn triple(self, puck: ColorWheelValue, master: f64) -> ColorTriple {
        let m: f32 = if self.is_additive() { (master / 2.0) as f32 } else { 2.0_f64.powf(master) as f32 };
        let k = (puck.amount as f32) * self.rim() * if self.is_additive() { 1.0 } else { m };
        let h = (puck.hue * PI / 180.0) as f32;
        let d = (2.0 * PI / 3.0) as f32;
        let (lo, hi) = self.channel_range();
        let ch = |c: f32| (m + k * c).max(lo).min(hi);
        ColorTriple { r: ch(h.cos()), g: ch((h - d).cos()), b: ch((h + d).cos()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_and_offset_are_inverse() {
        let v = ColorWheelMath::value(30.0, 40.0, 100.0);
        assert!((v.amount - 0.5).abs() < 1e-12);
        let o = ColorWheelMath::offset(v, 100.0);
        assert!((o.0 - 30.0).abs() < 1e-9 && (o.1 - 40.0).abs() < 1e-9);
    }

    #[test]
    fn centre_and_zero_radius_reset() {
        assert_eq!(ColorWheelMath::value(0.0, 0.0, 10.0), ColorWheelMath::RESET);
        assert_eq!(ColorWheelMath::value(3.0, 4.0, 0.0), ColorWheelMath::RESET);
    }

    #[test]
    fn hue_wraps_into_0_360() {
        let v = ColorWheelMath::value(1.0, -1.0, 10.0);
        assert!((v.hue - 315.0).abs() < 1e-9);
    }

    #[test]
    fn fine_drag_moves_a_fifth_of_the_pointer() {
        let start = ColorWheelValue { hue: 0.0, amount: 0.5 };
        let v = ColorWheelMath::drag(start, (50.0, 0.0), (60.0, 0.0), 100.0, true);
        assert!((v.amount - 0.52).abs() < 1e-9);
    }

    #[test]
    fn master_sliders_map_both_ways() {
        assert_eq!(ColorWheelMath::master_for_y(0.0, 100.0), 1.0);
        assert_eq!(ColorWheelMath::master_for_y(50.0, 100.0), 0.0);
        assert_eq!(ColorWheelMath::y_for_master(-1.0, 100.0), 100.0);
        assert_eq!(ColorWheelMath::master_for_x(100.0, 100.0), 1.0);
        assert_eq!(ColorWheelMath::x_for_master(0.0, 100.0), 50.0);
        assert_eq!(ColorWheelMath::master_for_x(5.0, 0.0), 0.0);
    }

    #[test]
    fn primary_wheel_round_trips_puck_and_master() {
        for w in PrimaryWheel::ALL {
            let puck = ColorWheelValue { hue: 120.0, amount: 0.4 };
            let t = w.triple(puck, 0.2);
            let back = w.puck_of(&t);
            assert!((back.hue - 120.0).abs() < 0.5, "{w:?} hue {}", back.hue);
            assert!((back.amount - 0.4).abs() < 0.02, "{w:?} amount {}", back.amount);
            assert!((w.master_of(&t) - 0.2).abs() < 0.02, "{w:?} master");
        }
    }

    #[test]
    fn neutral_triples_have_no_puck() {
        let t = ColorTriple::all(0.0);
        assert_eq!(PrimaryWheel::Lift.puck_of(&t), ColorWheelMath::RESET);
        assert_eq!(PrimaryWheel::Gain.master_of(&ColorTriple::all(1.0)), 0.0);
    }
}

/// The Swift `ColorWheelMathTests`, `ColorPrimaryWheelsTests` and `ColorWheelSmoothTests` (pure parts), same names.
#[cfg(test)]
mod ported_tests {
    use super::*;
    use crate::color::color_grade_draw::ColorGradeDraw;
    use crate::color::color_inspector_model::ColorInspectorModel;
    use crate::color::color_inspector_model_graph_detail::StepPrimaryRow;
    use sq_core_time::SequentialIds;

    fn near(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() < eps
    }

    #[test]
    fn polar_cardinal_directions() {
        let r = ColorWheelMath::value(50.0, 0.0, 100.0);
        assert!(near(r.hue, 0.0, 1e-9) && near(r.amount, 0.5, 1e-9));
        let u = ColorWheelMath::value(0.0, 100.0, 100.0);
        assert!(near(u.hue, 90.0, 1e-9) && near(u.amount, 1.0, 1e-9));
        let l = ColorWheelMath::value(-100.0, 0.0, 100.0);
        assert!(near(l.hue, 180.0, 1e-9));
        let d = ColorWheelMath::value(0.0, -10.0, 100.0);
        assert!(near(d.hue, 270.0, 1e-9) && near(d.amount, 0.1, 1e-9));
    }

    #[test]
    fn clamps_to_disc() {
        let v = ColorWheelMath::value(300.0, 400.0, 100.0);
        assert!(near(v.amount, 1.0, 1e-9));
        assert!(near(v.hue, 4.0_f64.atan2(3.0) * 180.0 / PI, 1e-9));
        let o = ColorWheelMath::offset(ColorWheelValue { hue: 45.0, amount: 5.0 }, 10.0);
        assert!(near(o.0.hypot(o.1), 10.0, 1e-9));
    }

    #[test]
    fn round_trip() {
        for (h, a) in [(0.0, 0.3), (33.0, 0.8), (200.0, 0.55), (359.0, 1.0)] {
            let o = ColorWheelMath::offset(ColorWheelValue { hue: h, amount: a }, 80.0);
            let v = ColorWheelMath::value(o.0, o.1, 80.0);
            assert!(near(v.hue, h, 1e-6) && near(v.amount, a, 1e-9));
        }
    }

    #[test]
    fn center_has_zero_amount_and_stable_hue() {
        let v = ColorWheelMath::value(0.0, 0.0, 100.0);
        assert!(v.amount == 0.0 && v.hue == 0.0);
        assert_eq!(ColorWheelMath::value(1.0, 1.0, 0.0).amount, 0.0);
    }

    #[test]
    fn reset_is_neutral() {
        assert_eq!(ColorWheelMath::RESET, ColorWheelValue { hue: 0.0, amount: 0.0 });
        assert!(ColorWheelMath::RESET.is_neutral());
        assert!(!ColorWheelValue { hue: 10.0, amount: 0.1 }.is_neutral());
    }

    #[test]
    fn absolute_drag_follows_pointer() {
        let v = ColorWheelMath::drag(ColorWheelValue { hue: 0.0, amount: 0.0 }, (0.0, 0.0), (0.0, 50.0), 100.0, false);
        assert!(near(v.hue, 90.0, 1e-9) && near(v.amount, 0.5, 1e-9));
    }

    #[test]
    fn fine_drag_moves_slowly_from_start() {
        let start = ColorWheelValue { hue: 0.0, amount: 0.5 };
        let v = ColorWheelMath::drag(start, (50.0, 0.0), (60.0, 0.0), 100.0, true);
        assert!(near(v.hue, 0.0, 1e-9) && near(v.amount, 0.5 + 10.0 * ColorWheelMath::FINE_FACTOR / 100.0, 1e-9));
        let clamped = ColorWheelMath::drag(start, (50.0, 0.0), (5000.0, 0.0), 100.0, true);
        assert_eq!(clamped.amount, 1.0);
    }

    #[test]
    fn master_slider_mapping() {
        assert!(near(ColorWheelMath::master_for_y(0.0, 100.0), 1.0, 1e-9));
        assert!(near(ColorWheelMath::master_for_y(50.0, 100.0), 0.0, 1e-9));
        assert!(near(ColorWheelMath::master_for_y(100.0, 100.0), -1.0, 1e-9));
        assert_eq!(ColorWheelMath::master_for_y(-40.0, 100.0), 1.0);
        assert_eq!(ColorWheelMath::master_for_y(500.0, 100.0), -1.0);
        assert!(near(ColorWheelMath::y_for_master(0.5, 100.0), 25.0, 1e-9));
    }

    #[test]
    fn every_wheel_round_trips_puck_and_master() {
        for w in PrimaryWheel::ALL {
            let puck = ColorWheelValue { hue: 70.0, amount: 0.4 };
            let t = w.triple(puck, 0.3);
            let back = w.puck_of(&t);
            assert!((back.hue - 70.0).abs() < 0.5 && (back.amount - 0.4).abs() < 0.02, "{} puck", w.title());
            assert!((w.master_of(&t) - 0.3).abs() < 0.02, "{} master", w.title());
        }
    }

    #[test]
    fn neutral_wheels_sit_in_the_center() {
        for w in PrimaryWheel::ALL {
            let t = w.triple_of(&StepPrimaries::default());
            assert!(w.puck_of(&t).amount < 1e-6 && w.master_of(&t).abs() < 1e-6);
        }
    }

    #[test]
    fn horizontal_master_slider_maps_edges_and_center() {
        assert!((ColorWheelMath::master_for_x(0.0, 100.0) + 1.0).abs() < 1e-9);
        assert!(ColorWheelMath::master_for_x(50.0, 100.0).abs() < 1e-9);
        assert!((ColorWheelMath::x_for_master(1.0, 100.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn primary_rows_show_whole_numbers_with_neutral_fifty() {
        assert!(StepPrimaryRow::Contrast.neutral() == 50.0 && StepPrimaryRow::Saturation.neutral() == 50.0);
        assert_eq!(StepPrimaryRow::Pivot.range(), (0.0, 100.0));
        assert!(StepPrimaryRow::ALL.iter().all(|r| r.decimals() == 0));
    }

    #[test]
    fn setting_a_wheel_writes_the_step_and_reads_back() {
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        m.start_empty_graph();
        let graph_events: Vec<_> = m.take_events();
        let id = graph_events.iter().rev().find_map(|e| match e {
            crate::color::color_inspector_model::ColorInspectorEvent::GraphChange(g) => g.steps().first().map(|s| s.id),
            _ => None,
        });
        let Some(id) = id else { panic!("no graph change") };
        m.set_step_wheel(id, PrimaryWheel::Gain, ColorWheelValue { hue: 30.0, amount: 0.5 }, 0.2);
        let r = m.step_wheel(id, PrimaryWheel::Gain);
        assert!((r.0.hue - 30.0).abs() < 0.5 && (r.1 - 0.2).abs() < 0.02);
        assert!(m.step_wheel(id, PrimaryWheel::Lift).0.amount < 1e-6);
    }

    /// The wheel fades in one ring per point (not 12 bands), pre-blended and opaque, and the
    /// ring count stays cheap (a few thousand polygons, built once per size).
    #[test]
    fn wedges_fade_smoothly() {
        let w = ColorGradeDraw::wedges(31.0);
        assert!(w.len() > 1000 && w.len() < 4000);
        // Rings run inner to outer (every ring's wedges are contiguous): the distance from the ground never jumps.
        let ground = ColorGradeDraw::WHEEL_CENTER;
        let from_ground =
            |c: &sq_draw::draw_list::Color| (c.r - ground.0).abs() + (c.g - ground.1).abs() + (c.b - ground.2).abs();
        let dist: Vec<f32> = w.iter().map(|(_, c)| from_ground(c)).collect();
        assert!(dist.iter().cloned().fold(0.0, f32::max) > 0.3, "the rim shows the hues");
        assert!(dist[..30].iter().all(|d| *d < 0.01), "the middle stays the ground");
    }

    /// The tab pitch is the Mac's ceil(NSString.size) + 16 for each title (the strip drifted by up to 1.5 pt).
    #[test]
    fn tab_widths_are_the_mac_ceil() {
        let d = ColorGradeDraw::new();
        for t in ColorGradeDraw::PRO_TAB_TITLES {
            assert!(d.tab_text_width(t, 11.0, false) > 0.0);
        }
        assert_eq!(d.tab_text_width("Primaries", 11.0, false), 50.0);
        assert_eq!(d.tab_text_width("Qualifier", 11.0, false), 45.0);
    }

    /// Every Pro tab title has a German text (the width table is English only; a translated title is measured by the atlas).
    #[test]
    fn every_pro_tab_title_has_a_german_text() {
        use sq_uikit::localization::SQL10n;
        for t in ColorGradeDraw::PRO_TAB_TITLES {
            let de = SQL10n::string_in(t, "de");
            assert!(t == "LUT" || de != t, "{t} has no German text");
        }
    }
}
