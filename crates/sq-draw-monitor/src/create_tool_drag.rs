// Swift: CreateToolDrag.swift
//! One Create tool drag on the Program monitor.

use sq_core_graphics::graphics_create::CreateDrag;
use sq_core_graphics::graphics_editing::GraphicsRect;
use sq_core_time::Vec2;
use sq_editor_session::es01_session_core::CreateToolMode;
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// What a Create drag would make right now.
#[derive(Clone, Debug, PartialEq)]
pub enum CreateOutline {
    /// A box; `ellipse` for the Ellipse tool.
    Boxed(GraphicsRect, bool),
    /// A line between two points.
    Line(Vec2, Vec2),
    /// A freehand stroke.
    Stroke(Vec<Vec2>),
}

/// One Create tool drag on the Program monitor, in view points (y down): what it would make right now.
/// Shift constrains (square, circle, 45 degree steps), Option (Alt) grows from the press point.
#[derive(Clone, Debug, PartialEq)]
pub struct CreateToolDrag {
    /// The tool.
    pub mode: CreateToolMode,
    /// The press point.
    pub start: Vec2,
    current: Vec2,
    constrain: bool,
    from_center: bool,
    stroke: Vec<Vec2>,
}

impl CreateToolDrag {
    /// Smoothing tolerance of a drawn stroke, view points.
    pub const STROKE_TOLERANCE: f64 = 1.5;
    /// Recorded stroke points lie at least this far apart, view points.
    pub const STROKE_STEP: f64 = 2.0;
    /// Smallest drag (view points) that makes an item; a click makes nothing.
    pub const MIN_DRAG: f64 = 6.0;

    /// A drag pressed at `start`.
    pub fn new(mode: CreateToolMode, start: CGPoint) -> CreateToolDrag {
        let s = Vec2::new(start.x, start.y);
        CreateToolDrag { mode, start: s, current: s, constrain: false, from_center: false, stroke: vec![s] }
    }

    /// Moves the pointer to `p` (view points).
    pub fn move_to(&mut self, p: CGPoint, constrain: bool, from_center: bool) {
        self.move_to_vec(Vec2::new(p.x, p.y), constrain, from_center);
    }

    /// Moves the pointer to `p`.
    pub fn move_to_vec(&mut self, p: Vec2, constrain: bool, from_center: bool) {
        self.current = p;
        self.constrain = constrain;
        self.from_center = from_center;
        if self.mode == CreateToolMode::Draw
            && let Some(last) = self.stroke.last()
            && (p - *last).length() >= Self::STROKE_STEP
        {
            self.stroke.push(p);
        }
    }

    /// False while the pointer has not left the press point by `minimum` view points: a click makes nothing.
    pub fn is_drag(&self, minimum: f64) -> bool {
        if self.mode == CreateToolMode::Draw {
            return self.stroke.len() >= 2 && self.stroke.iter().any(|p| (*p - self.start).length() >= minimum);
        }
        (self.current.x - self.start.x).abs() >= minimum || (self.current.y - self.start.y).abs() >= minimum
    }

    /// What the drag makes now.
    pub fn outline(&self) -> CreateOutline {
        match self.mode {
            CreateToolMode::Line => {
                let (a, b) = CreateDrag::line(self.start, self.current, self.constrain, self.from_center);
                CreateOutline::Line(a, b)
            }
            CreateToolMode::Draw => CreateOutline::Stroke(self.stroke.clone()),
            CreateToolMode::Ellipse | CreateToolMode::Rectangle | CreateToolMode::Text => CreateOutline::Boxed(
                CreateDrag::box_from(self.start, self.current, self.constrain, self.from_center),
                self.mode == CreateToolMode::Ellipse,
            ),
        }
    }

    /// The size next to the pointer in sequence pixels: "96 × 96" for a box, the length for a line, nothing for a stroke.
    pub fn size_label(&self, view_points_per_pixel: f64) -> Option<String> {
        let k = view_points_per_pixel;
        if k <= 0.0 {
            return None;
        }
        match self.outline() {
            CreateOutline::Boxed(r, _) => {
                Some(format!("{} × {}", (r.width() / k).round() as i64, (r.height() / k).round() as i64))
            }
            CreateOutline::Line(a, b) => Some(format!("{}", ((b - a).length() / k).round() as i64)),
            CreateOutline::Stroke(_) => None,
        }
    }

    /// The outline's bounding box in view points (where the size label goes under).
    pub fn bounds(&self) -> CGRect {
        match self.outline() {
            CreateOutline::Boxed(r, _) => CGRect::new(r.min_x, r.min_y, r.width(), r.height()),
            CreateOutline::Line(a, b) => CGRect::new(a.x.min(b.x), a.y.min(b.y), (a.x - b.x).abs(), (a.y - b.y).abs()),
            CreateOutline::Stroke(pts) => {
                let xs = pts.iter().map(|p| p.x);
                let ys = pts.iter().map(|p| p.y);
                let (Some(x0), Some(x1), Some(y0), Some(y1)) = (
                    xs.clone().reduce(f64::min),
                    xs.reduce(f64::max),
                    ys.clone().reduce(f64::min),
                    ys.reduce(f64::max),
                ) else {
                    return CGRect::default();
                };
                CGRect::new(x0, y0, x1 - x0, y1 - y0)
            }
        }
    }
}
