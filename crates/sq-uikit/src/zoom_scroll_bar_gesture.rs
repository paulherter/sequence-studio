// Swift: ZoomScrollBarGesture.swift
//! The zoom/scroll bar's press and drag rules, portable so every view of the bar shares them: a handle press zooms, the
//! body pans, a click on the empty track centers the visible range there, a double-click fits.

use crate::keyframe_viewport::KeyframeViewport;

/// Pure mapping of the zoom bar: handle fractions <-> x (the round handles stay fully inside the track).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyframeZoomBarGeometry {
    pub width: f64,
}

/// What is under a point of the zoom bar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    Lower,
    Upper,
    Body,
    Track,
}

impl KeyframeZoomBarGeometry {
    pub const HANDLE_RADIUS: f64 = 7.0;
    pub const SIDE_INSET: f64 = 4.0;

    pub fn new(width: f64) -> KeyframeZoomBarGeometry {
        KeyframeZoomBarGeometry { width }
    }

    fn x0(&self) -> f64 {
        Self::SIDE_INSET + Self::HANDLE_RADIUS
    }

    fn x1(&self) -> f64 {
        f64::max(self.width - Self::SIDE_INSET - Self::HANDLE_RADIUS, self.x0() + 1.0)
    }

    /// The x of a handle at fraction `f` (limited to 0...1).
    pub fn x_for_fraction(&self, f: f64) -> f64 {
        self.x0() + f.clamp(0.0, 1.0) * (self.x1() - self.x0())
    }

    /// The fraction (0...1) of a handle dragged to `x`.
    pub fn fraction_at_x(&self, x: f64) -> f64 {
        ((x - self.x0()) / (self.x1() - self.x0())).clamp(0.0, 1.0)
    }

    /// What is under `x`: a handle (they win over the body), the body between them, or the empty track.
    pub fn part_for_viewport(&self, x: f64, viewport: &KeyframeViewport, duration: f64) -> Part {
        self.part(x, viewport.handles(duration))
    }

    /// Same, for handle fractions (0...1) given directly as (lo, hi).
    pub fn part(&self, x: f64, handles: (f64, f64)) -> Part {
        let xl = self.x_for_fraction(handles.0);
        let xh = self.x_for_fraction(handles.1);
        let reach = Self::HANDLE_RADIUS + 2.0;
        let dl = (x - xl).abs();
        let dh = (x - xh).abs();
        if dl <= reach || dh <= reach {
            return if dl <= dh { Part::Lower } else { Part::Upper };
        }
        if x > xl && x < xh { Part::Body } else { Part::Track }
    }
}

/// What a drag on the bar moves.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Drag {
    Lower,
    Upper,
    Pan { grab: f64 },
}

/// What the owner does: snapshot its state (`Begin`), move a handle, pan to a start fraction, or fit.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Output {
    Begin,
    Handle { lower: bool, fraction: f64 },
    Pan { start_fraction: f64 },
    Fit,
}

/// The press and drag rules of one bar.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ZoomScrollBarGesture {
    drag: Option<Drag>,
}

impl ZoomScrollBarGesture {
    /// Board row height (22), shared with the Mix row on its left.
    pub const HEIGHT: f64 = 18.0;

    pub fn new() -> ZoomScrollBarGesture {
        ZoomScrollBarGesture::default()
    }

    /// The drag in progress.
    pub fn drag(&self) -> Option<Drag> {
        self.drag
    }

    pub fn is_panning(&self) -> bool {
        matches!(self.drag, Some(Drag::Pan { .. }))
    }

    /// A press at `x` on a bar `width` wide showing `handles`.
    pub fn begin(&mut self, x: f64, click_count: i64, width: f64, handles: (f64, f64)) -> Vec<Output> {
        if click_count == 2 {
            self.drag = None;
            return vec![Output::Fit];
        }
        let g = KeyframeZoomBarGeometry::new(width);
        match g.part(x, handles) {
            Part::Lower => self.drag = Some(Drag::Lower),
            Part::Upper => self.drag = Some(Drag::Upper),
            Part::Body => self.drag = Some(Drag::Pan { grab: g.fraction_at_x(x) - handles.0 }),
            Part::Track => {
                let half = (handles.1 - handles.0) / 2.0;
                self.drag = Some(Drag::Pan { grab: half });
                return vec![Output::Begin, Output::Pan { start_fraction: g.fraction_at_x(x) - half }];
            }
        }
        vec![Output::Begin]
    }

    /// The output of a drag to `x`.
    pub fn drag_to(&self, x: f64, width: f64) -> Option<Output> {
        let drag = self.drag?;
        let f = KeyframeZoomBarGeometry::new(width).fraction_at_x(x);
        Some(match drag {
            Drag::Lower => Output::Handle { lower: true, fraction: f },
            Drag::Upper => Output::Handle { lower: false, fraction: f },
            Drag::Pan { grab } => Output::Pan { start_fraction: f - grab },
        })
    }

    /// Ends the drag.
    pub fn end(&mut self) {
        self.drag = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: f64 = 200.0;

    #[test]
    fn geometry_maps_fractions_inside_the_track() {
        let g = KeyframeZoomBarGeometry::new(W);
        assert_eq!(g.x_for_fraction(0.0), 11.0);
        assert_eq!(g.x_for_fraction(1.0), 189.0);
        assert_eq!(g.x_for_fraction(2.0), 189.0);
        assert_eq!(g.fraction_at_x(100.0), 0.5);
        assert_eq!(g.fraction_at_x(-50.0), 0.0);
        // A bar narrower than its handles still has a track one point long.
        assert_eq!(KeyframeZoomBarGeometry::new(5.0).x1(), 12.0);
    }

    #[test]
    fn handles_win_over_the_body_and_the_empty_track_is_outside() {
        let g = KeyframeZoomBarGeometry::new(W);
        let h = (0.25, 0.75);
        assert_eq!(g.part(g.x_for_fraction(0.25), h), Part::Lower);
        assert_eq!(g.part(g.x_for_fraction(0.75), h), Part::Upper);
        assert_eq!(g.part(100.0, h), Part::Body);
        assert_eq!(g.part(20.0, h), Part::Track);
        assert_eq!(g.part_for_viewport(78.0, &KeyframeViewport::new(10.0, 10.0), 40.0), Part::Body);
    }

    #[test]
    fn a_double_click_fits_and_a_press_on_the_track_centers_the_range() {
        let mut gesture = ZoomScrollBarGesture::new();
        assert_eq!(gesture.begin(100.0, 2, W, (0.25, 0.75)), vec![Output::Fit]);
        assert_eq!(gesture.drag(), None);
        let out = gesture.begin(20.0, 1, W, (0.25, 0.75));
        let g = KeyframeZoomBarGeometry::new(W);
        assert_eq!(out, vec![Output::Begin, Output::Pan { start_fraction: g.fraction_at_x(20.0) - 0.25 }]);
        assert!(gesture.is_panning());
    }

    #[test]
    fn handle_and_body_drags_report_what_to_move() {
        let g = KeyframeZoomBarGeometry::new(W);
        let mut gesture = ZoomScrollBarGesture::new();
        assert_eq!(gesture.begin(g.x_for_fraction(0.25), 1, W, (0.25, 0.75)), vec![Output::Begin]);
        assert_eq!(gesture.drag_to(100.0, W), Some(Output::Handle { lower: true, fraction: 0.5 }));
        gesture.end();
        assert_eq!(gesture.drag_to(100.0, W), None);
        gesture.begin(100.0, 1, W, (0.25, 0.75));
        assert_eq!(gesture.drag_to(g.x_for_fraction(0.6), W), Some(Output::Pan { start_fraction: 0.6 - (0.5 - 0.25) }));
        gesture.begin(g.x_for_fraction(0.75), 1, W, (0.25, 0.75));
        assert_eq!(gesture.drag_to(100.0, W), Some(Output::Handle { lower: false, fraction: 0.5 }));
    }
}
