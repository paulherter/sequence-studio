// Swift: Color/ColorInspectorModel+GraphDetail.swift
//! The Step inspector's detail edits: window, qualifier, curves and the Primaries wheels.

use super::color_inspector_model::{ColorInspectorModel, HueCurveKind};
use super::color_range_model::ColorRangeParam;
use super::color_wheel_math::{ColorWheelValue, PrimaryWheel};
use sq_core_color::{ActiveGrade, ColorQualifierExt};
use sq_core_model::{ColorQualifier, ColorStep, CurvePoint, HSLSecondary, RGBCurves, StepWindow, StepWindowShape};
use sq_core_time::Id;

/// One slider of a Step's window (the shape that limits the Step to part of the frame). Positions, sizes and softness
/// show as percent, the model keeps fractions (`StepWindow`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StepWindowParam {
    CenterX,
    CenterY,
    Width,
    Height,
    Rotation,
    Softness,
}

impl StepWindowParam {
    /// Swift `allCases`.
    pub const ALL: [StepWindowParam; 6] = [
        StepWindowParam::CenterX,
        StepWindowParam::CenterY,
        StepWindowParam::Width,
        StepWindowParam::Height,
        StepWindowParam::Rotation,
        StepWindowParam::Softness,
    ];

    pub fn title(self) -> &'static str {
        match self {
            StepWindowParam::CenterX => "Position X",
            StepWindowParam::CenterY => "Position Y",
            StepWindowParam::Width => "Width",
            StepWindowParam::Height => "Height",
            StepWindowParam::Rotation => "Rotation",
            StepWindowParam::Softness => "Softness",
        }
    }

    pub fn range(self) -> (f32, f32) {
        match self {
            StepWindowParam::CenterX | StepWindowParam::CenterY => (0.0, 100.0),
            StepWindowParam::Width | StepWindowParam::Height => (1.0, 200.0),
            StepWindowParam::Rotation => (-180.0, 180.0),
            StepWindowParam::Softness => (0.0, 100.0),
        }
    }

    pub fn neutral(self) -> f32 {
        self.read(&StepWindow::default())
    }

    pub fn decimals(self) -> i64 {
        1
    }

    pub fn read(self, w: &StepWindow) -> f32 {
        match self {
            StepWindowParam::CenterX => w.center_x * 100.0,
            StepWindowParam::CenterY => w.center_y * 100.0,
            StepWindowParam::Width => w.width * 100.0,
            StepWindowParam::Height => w.height * 100.0,
            StepWindowParam::Rotation => w.rotation,
            StepWindowParam::Softness => w.softness * 100.0,
        }
    }

    pub fn write(self, value: f32, w: &mut StepWindow) {
        let (lo, hi) = self.range();
        let v = value.max(lo).min(hi);
        match self {
            StepWindowParam::CenterX => w.center_x = v / 100.0,
            StepWindowParam::CenterY => w.center_y = v / 100.0,
            StepWindowParam::Width => w.width = v / 100.0,
            StepWindowParam::Height => w.height = v / 100.0,
            StepWindowParam::Rotation => w.rotation = v,
            StepWindowParam::Softness => w.softness = v / 100.0,
        }
    }
}

/// Titles of the window shapes (Swift `extension StepWindow.Shape`, here and in StepRangeLogic.swift).
pub trait StepWindowShapeExt {
    fn title(self) -> &'static str;
    /// The shape button's title (version 9 calls the ellipse an oval).
    fn chip_title(self) -> &'static str;
}

impl StepWindowShapeExt for StepWindowShape {
    fn title(self) -> &'static str {
        match self {
            StepWindowShape::Ellipse => "Ellipse",
            StepWindowShape::Rectangle => "Rectangle",
            StepWindowShape::Linear => "Linear",
        }
    }

    fn chip_title(self) -> &'static str {
        if self == StepWindowShape::Ellipse { "Oval" } else { self.title() }
    }
}

/// The qualifier as a Color Range (so the Simple-mode `ColorRangeParam` reads and writes it), and back.
fn qualifier_from_range(r: &HSLSecondary) -> ColorQualifier {
    ColorQualifier {
        hue_center: r.hue_center,
        hue_width: r.hue_width,
        sat_min: r.sat_min,
        sat_max: r.sat_max,
        lum_min: r.lum_min,
        lum_max: r.lum_max,
        softness: r.softness,
        invert: r.invert,
    }
}

/// How a Primaries row reads in the value column (version 9 shows whole numbers, 50 = neutral for Contrast and Saturation).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StepPrimaryRow {
    Saturation,
    Contrast,
    Pivot,
}

impl StepPrimaryRow {
    /// Swift `allCases`.
    pub const ALL: [StepPrimaryRow; 3] = [StepPrimaryRow::Saturation, StepPrimaryRow::Contrast, StepPrimaryRow::Pivot];

    pub fn param(self) -> super::color_inspector_model_graph::StepParam {
        use super::color_inspector_model_graph::StepParam;
        match self {
            StepPrimaryRow::Saturation => StepParam::Saturation,
            StepPrimaryRow::Contrast => StepParam::Contrast,
            StepPrimaryRow::Pivot => StepParam::Pivot,
        }
    }

    pub fn title(self) -> &'static str {
        self.param().title()
    }

    /// Shown value = engine value x scale.
    pub fn scale(self) -> f32 {
        match self {
            StepPrimaryRow::Saturation | StepPrimaryRow::Contrast => 50.0,
            StepPrimaryRow::Pivot => 100.0,
        }
    }

    pub fn range(self) -> (f32, f32) {
        let r = self.param().range();
        (r.0 * self.scale(), r.1 * self.scale())
    }

    pub fn neutral(self) -> f32 {
        self.param().neutral() * self.scale()
    }

    pub fn decimals(self) -> i64 {
        0
    }
}

impl ColorInspectorModel {
    // MARK: Curves (RGB and Hue Saturation) of a Step. The same value types and wrap rule as the Simple section.

    pub fn step_curves(&self, id: Id) -> RGBCurves {
        self.step(id).map(|s| s.curves.clone()).unwrap_or_default()
    }

    pub fn set_step_curves(&mut self, id: Id, c: RGBCurves) {
        self.edit_step(id, |s| s.curves = c);
    }

    pub fn step_hue_curve(&self, id: Id, kind: HueCurveKind) -> Vec<CurvePoint> {
        kind.points(&self.step(id).map(|s| s.hue_curves.clone()).unwrap_or_default())
    }

    pub fn set_step_hue_curve(&mut self, id: Id, kind: HueCurveKind, pts: &[CurvePoint]) {
        self.edit_step(id, |s| {
            let wrapped = kind.wrapped(pts, &kind.points(&s.hue_curves));
            kind.set(wrapped, &mut s.hue_curves);
        });
    }

    // MARK: Qualifier (the Color Range ranges)

    /// Turns the qualifier on (a new one: skin tones) or off (the Step then works on every pixel).
    pub fn set_step_qualifier_enabled(&mut self, id: Id, on: bool) {
        self.edit_step(id, |s| {
            if on {
                if s.qualifier.is_none() {
                    s.qualifier = Some(ColorQualifier::default());
                }
            } else {
                s.qualifier = None;
            }
        });
    }

    pub fn step_qualifier_value(&self, id: Id, p: ColorRangeParam) -> f32 {
        p.read(&self.step(id).and_then(|s| s.qualifier.as_ref()).map(|q| q.as_color_range()).unwrap_or_default())
    }

    /// Writes one range value; a Step without a qualifier is left alone (the switch comes first).
    pub fn set_step_qualifier(&mut self, id: Id, p: ColorRangeParam, v: f32) {
        if !p.is_qualifier() {
            return;
        }
        self.edit_step(id, |s| {
            let Some(q) = &s.qualifier else { return };
            let mut r = q.as_color_range();
            p.write(v, &mut r);
            s.qualifier = Some(qualifier_from_range(&r));
        });
    }

    pub fn reset_step_qualifier_parameter(&mut self, id: Id, p: ColorRangeParam) {
        if self.step(id).is_some_and(|s| s.qualifier.is_none()) || self.step(id).is_none() {
            return;
        }
        self.set_step_qualifier(id, p, p.read(&ColorQualifier::default().as_color_range()));
    }

    pub fn set_step_qualifier_invert(&mut self, id: Id, on: bool) {
        self.edit_step(id, |s| {
            if let Some(q) = &mut s.qualifier {
                q.invert = on;
            }
        });
    }

    // MARK: Window

    pub fn set_step_window_enabled(&mut self, id: Id, on: bool) {
        self.edit_step(id, |s| {
            if on {
                if s.window.is_none() {
                    s.window = Some(StepWindow::default());
                }
            } else {
                s.window = None;
            }
        });
    }

    pub fn step_window_value(&self, id: Id, p: StepWindowParam) -> f32 {
        p.read(&self.step(id).and_then(|s| s.window.clone()).unwrap_or_default())
    }

    pub fn set_step_window(&mut self, id: Id, p: StepWindowParam, v: f32) {
        self.edit_step(id, |s| {
            let Some(mut w) = s.window.clone() else { return };
            p.write(v, &mut w);
            s.window = Some(w);
        });
    }

    pub fn reset_step_window_parameter(&mut self, id: Id, p: StepWindowParam) {
        if self.step(id).is_none_or(|s| s.window.is_none()) {
            return;
        }
        self.set_step_window(id, p, p.neutral());
    }

    /// The Step and window the Program monitor shows handles for: Pro grade, the selected Step, its window on.
    pub fn window_edit_target(&self) -> Option<(Id, StepWindow)> {
        if self.active_grade() != ActiveGrade::Pro {
            return None;
        }
        let id = self.selected_step()?;
        let w = self.step(id)?.window.clone()?;
        Some((id, w))
    }

    /// A drag of the monitor handles: position, size and angle of the window. Shape, softness and invert stay the
    /// panel's; a Step without a window is left alone.
    pub fn set_step_window_geometry(&mut self, id: Id, w: &StepWindow) {
        self.edit_step(id, |s| {
            let Some(mut cur) = s.window.clone() else { return };
            cur.center_x = w.center_x;
            cur.center_y = w.center_y;
            cur.width = w.width;
            cur.height = w.height;
            cur.rotation = w.rotation;
            s.window = Some(cur);
        });
    }

    pub fn set_step_window_shape(&mut self, id: Id, shape: StepWindowShape) {
        self.edit_step(id, |s| {
            if let Some(w) = &mut s.window {
                w.shape = shape;
            }
        });
    }

    pub fn set_step_window_invert(&mut self, id: Id, on: bool) {
        self.edit_step(id, |s| {
            if let Some(w) = &mut s.window {
                w.invert = on;
            }
        });
    }

    // MARK: Primaries wheels (version 9 Pro Primaries)

    /// The puck and master (-1...1) of one wheel of a Step.
    pub fn step_wheel(&self, id: Id, w: PrimaryWheel) -> (ColorWheelValue, f64) {
        let primaries = self.step(id).map(|s| s.primaries.clone()).unwrap_or_else(|| ColorStep::new(id, "").primaries);
        let t = w.triple_of(&primaries);
        (w.puck_of(&t), w.master_of(&t))
    }

    /// Writes one wheel from the controls' puck and master (an undo step; inside a drag the host groups the changes).
    pub fn set_step_wheel(&mut self, id: Id, w: PrimaryWheel, puck: ColorWheelValue, master: f64) {
        self.edit_step(id, |s| w.write(w.triple(puck, master), &mut s.primaries));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn pro() -> (ColorInspectorModel, Id) {
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        m.start_empty_graph();
        m.take_events();
        let id = m.selected_step().unwrap_or(Id::NIL);
        (m, id)
    }

    #[test]
    fn window_params_show_percent_and_keep_fractions() {
        let mut w = StepWindow::default();
        StepWindowParam::Width.write(80.0, &mut w);
        assert_eq!(w.width, 0.8);
        assert_eq!(StepWindowParam::Width.read(&w), 80.0);
        StepWindowParam::Width.write(0.0, &mut w);
        assert_eq!(w.width, 0.01);
        assert_eq!(StepWindowParam::CenterX.neutral(), 50.0);
        assert_eq!(StepWindowShape::Ellipse.chip_title(), "Oval");
        assert_eq!(StepWindowShape::Linear.chip_title(), "Linear");
    }

    #[test]
    fn primary_rows_scale_the_engine_value() {
        assert_eq!(StepPrimaryRow::Saturation.neutral(), 50.0);
        assert_eq!(StepPrimaryRow::Pivot.range(), (0.0, 100.0));
        assert_eq!(StepPrimaryRow::Contrast.range(), (0.0, 100.0));
    }

    #[test]
    fn the_qualifier_needs_its_switch_first() {
        let (mut m, id) = pro();
        m.set_step_qualifier(id, ColorRangeParam::Softness, 55.0);
        assert!(m.step(id).is_some_and(|s| s.qualifier.is_none()));
        m.set_step_qualifier_enabled(id, true);
        m.set_step_qualifier(id, ColorRangeParam::Softness, 55.0);
        assert_eq!(m.step_qualifier_value(id, ColorRangeParam::Softness), 55.0);
        m.reset_step_qualifier_parameter(id, ColorRangeParam::Softness);
        assert_eq!(m.step_qualifier_value(id, ColorRangeParam::Softness), 20.0);
        m.set_step_qualifier_invert(id, true);
        assert!(m.step(id).is_some_and(|s| s.qualifier.as_ref().is_some_and(|q| q.invert)));
        m.set_step_qualifier_enabled(id, false);
        assert!(m.step(id).is_some_and(|s| s.qualifier.is_none()));
    }

    #[test]
    fn the_window_target_follows_pro_selection_and_window() {
        let (mut m, id) = pro();
        assert_eq!(m.window_edit_target(), None);
        m.set_step_window_enabled(id, true);
        assert_eq!(m.window_edit_target().map(|t| t.0), Some(id));
        let w = StepWindow { center_x: 0.2, softness: 0.9, ..StepWindow::default() };
        m.set_step_window_geometry(id, &w);
        assert_eq!(m.step_window_value(id, StepWindowParam::CenterX), 20.0);
        assert_eq!(m.step_window_value(id, StepWindowParam::Softness), 20.0);
        m.set_step_window_shape(id, StepWindowShape::Linear);
        assert_eq!(m.step(id).and_then(|s| s.window.as_ref().map(|w| w.shape)), Some(StepWindowShape::Linear));
    }

    #[test]
    fn a_wheel_write_reads_back() {
        let (mut m, id) = pro();
        m.set_step_wheel(id, PrimaryWheel::Gain, ColorWheelValue { hue: 200.0, amount: 0.5 }, 0.0);
        let (puck, master) = m.step_wheel(id, PrimaryWheel::Gain);
        assert!((puck.hue - 200.0).abs() < 0.5 && (puck.amount - 0.5).abs() < 0.02 && master.abs() < 0.02);
    }

    #[test]
    fn hue_curves_of_a_step_wrap_like_the_simple_ones() {
        let (mut m, id) = pro();
        let mut pts = m.step_hue_curve(id, HueCurveKind::HueVsSat);
        let last = pts.len() - 1;
        pts[last].y = 0.8;
        m.set_step_hue_curve(id, HueCurveKind::HueVsSat, &pts);
        let back = m.step_hue_curve(id, HueCurveKind::HueVsSat);
        assert_eq!(back[0].y, 0.8);
    }
}
