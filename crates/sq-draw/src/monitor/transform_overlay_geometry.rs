// Swift: TransformOverlayGeometry.swift
//! Pure geometry and drag reducers for the Program monitor's transform overlay.
//!
//! Spaces (all y down):
//! - view: points in the overlay view (`view_rect` is where the sequence canvas is drawn, aspect-fitted by the host).
//! - offset: sequence px relative to the canvas center (what `ClipTransform.position` uses).
//! - local: layer px relative to the aspect-fitted layer center, before scale/rotation (what `anchor` uses).
//!
//! Model: `offset = position + R(rotation) * S(scale) * (local - anchor)`. The anchor therefore sits at `position`
//! on the canvas (Premiere: Position is where the anchor point lies); scale and rotation pivot on it.
//!
//! Premiere behavior, decided here:
//! - Drag body: move (Shift = lock to the dominant axis).
//! - Any handle scales uniformly while the clip's Uniform Scale is on (the default). With it off, side handles change
//!   width, top and bottom handles height, corners both freely; Shift then locks the proportions.
//!   Scaling pivots on the anchor (Premiere default); Option pivots on the opposite handle instead (edge stays put).
//! - Just outside a corner (the outward quadrant from the handle out to `ROTATE_ZONE`, not beside the edges): rotate about the anchor, clockwise positive;
//!   Shift snaps the result to 45 degrees.
//! - The anchor wins every grab within `ANCHOR_RADIUS` of its crosshair, also at the picture center.
//! - Anchor crosshair: moving it does not move the picture (position is compensated).
//!
//! Scale is clamped to `MINIMUM_SCALE` (never negative).

use sq_core_masks::perspective_tilt as tilt;
use sq_core_model::ClipTransform;
use sq_core_time::keyframes_model::KeyframeTrack;
use sq_core_time::{Id, Vec2};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// One of the eight handles.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Handle {
    /// Top-left corner.
    TopLeft,
    /// Top edge.
    Top,
    /// Top-right corner.
    TopRight,
    /// Right edge.
    Right,
    /// Bottom-right corner.
    BottomRight,
    /// Bottom edge.
    Bottom,
    /// Bottom-left corner.
    BottomLeft,
    /// Left edge.
    Left,
}

impl Handle {
    /// Every handle, in declaration order.
    pub const ALL: [Handle; 8] = [
        Handle::TopLeft,
        Handle::Top,
        Handle::TopRight,
        Handle::Right,
        Handle::BottomRight,
        Handle::Bottom,
        Handle::BottomLeft,
        Handle::Left,
    ];

    /// Direction of the handle in layer space: -1, 0 or 1 per axis (y down).
    pub fn direction(self) -> (f64, f64) {
        match self {
            Handle::TopLeft => (-1.0, -1.0),
            Handle::Top => (0.0, -1.0),
            Handle::TopRight => (1.0, -1.0),
            Handle::Right => (1.0, 0.0),
            Handle::BottomRight => (1.0, 1.0),
            Handle::Bottom => (0.0, 1.0),
            Handle::BottomLeft => (-1.0, 1.0),
            Handle::Left => (-1.0, 0.0),
        }
    }

    /// A corner handle.
    pub fn is_corner(self) -> bool {
        let d = self.direction();
        d.0 != 0.0 && d.1 != 0.0
    }
}

/// What a press hit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Hit {
    /// The anchor crosshair.
    Anchor,
    /// A scale handle.
    Handle(Handle),
    /// Rotation zone outside a corner.
    Rotate(Handle),
    /// The picture.
    Body,
}

/// Modifiers of a scale drag.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ScaleModifiers {
    /// Uniform Scale off: locks the proportions. Ignored while Uniform Scale is on.
    pub shift: bool,
    /// Pivot on the opposite handle instead of the anchor.
    pub option: bool,
    /// The clip's Uniform Scale flag (Effect Controls). On: every handle scales both axes by the same factor.
    pub uniform_scale: bool,
}

impl Default for ScaleModifiers {
    fn default() -> Self {
        ScaleModifiers { shift: false, option: false, uniform_scale: true }
    }
}

/// The transform overlay of one layer.
#[derive(Clone, Debug, PartialEq)]
pub struct TransformOverlayGeometry {
    /// The sequence's size in px.
    pub sequence_size: CGSize,
    /// Where the sequence canvas is drawn.
    pub view_rect: CGRect,
    /// Width / height of the media. The layer is aspect-fitted into the sequence.
    pub media_aspect: f64,
    /// Upright source size in px. Set = Scale is relative to source pixels (Premiere: the layer is drawn at this size at
    /// scale 1, see `SequenceFormat.fitScale`); `None` = the layer is aspect-fitted at scale 1 (legacy, tests).
    pub media_pixel_size: Option<CGSize>,
    /// The transform at gesture start.
    pub transform: ClipTransform,
}

fn rotate(v: Vec2, degrees: f64) -> Vec2 {
    let a = degrees * std::f64::consts::PI / 180.0;
    Vec2::new(v.x * a.cos() - v.y * a.sin(), v.x * a.sin() + v.y * a.cos())
}

impl TransformOverlayGeometry {
    /// Smallest scale a drag sets.
    pub const MINIMUM_SCALE: f64 = 0.0001;
    /// Grab radius of a handle.
    pub const HANDLE_RADIUS: f64 = 6.0;
    /// Grab radius of the anchor.
    pub const ANCHOR_RADIUS: f64 = 10.0;
    /// Rotation zone: the quadrant opening outward from a corner handle, within this distance of the corner.
    pub const ROTATE_ZONE: f64 = 20.0;
    /// Shift snaps rotation to these steps.
    pub const ROTATION_SNAP_DEGREES: f64 = 45.0;

    /// An overlay of one layer.
    pub fn new(
        sequence_size: CGSize,
        view_rect: CGRect,
        media_aspect: f64,
        transform: ClipTransform,
        media_pixel_size: Option<CGSize>,
    ) -> TransformOverlayGeometry {
        TransformOverlayGeometry { sequence_size, view_rect, media_aspect, media_pixel_size, transform }
    }

    // Spaces

    /// View points per sequence px.
    pub fn view_scale(&self) -> f64 {
        if self.sequence_size.width > 0.0 { self.view_rect.width / self.sequence_size.width } else { 1.0 }
    }

    /// Aspect-fitted layer size in sequence px (scale 1).
    pub fn fitted_size(&self) -> CGSize {
        if let Some(m) = self.media_pixel_size.filter(|m| m.width > 0.0 && m.height > 0.0) {
            return m;
        }
        if !(self.sequence_size.width > 0.0 && self.sequence_size.height > 0.0 && self.media_aspect > 0.0) {
            return CGSize::default();
        }
        let seq_aspect = self.sequence_size.width / self.sequence_size.height;
        if self.media_aspect >= seq_aspect {
            return CGSize::new(self.sequence_size.width, self.sequence_size.width / self.media_aspect);
        }
        CGSize::new(self.sequence_size.height * self.media_aspect, self.sequence_size.height)
    }

    /// Offset space to view space.
    pub fn view_point_from_offset(&self, o: Vec2) -> CGPoint {
        let s = self.view_scale();
        CGPoint { x: self.view_rect.mid_x() + o.x * s, y: self.view_rect.mid_y() + o.y * s }
    }
    /// View space to offset space.
    pub fn offset_from_view(&self, p: CGPoint) -> Vec2 {
        let s = self.view_scale();
        Vec2::new((p.x - self.view_rect.mid_x()) / s, (p.y - self.view_rect.mid_y()) / s)
    }

    /// Layer-local point to offset space before the tilt: `position + R S (local - anchor)`.
    pub fn flat_offset_from_local(&self, l: Vec2, t: &ClipTransform) -> Vec2 {
        let d = l - t.anchor;
        t.position + rotate(Vec2::new(d.x * t.scale.x, d.y * t.scale.y), t.rotation)
    }

    /// Camera distance of the tilt, the same the compositor derives (`PerspectiveTilt.focal`, layer radius + 2 px).
    pub fn tilt_focal(&self, t: &ClipTransform) -> f64 {
        let s = self.fitted_size();
        let r = tilt::layer_radius(Vec2::new(s.width, s.height), t.anchor, t.scale);
        tilt::focal(r + 2.0, Vec2::new(self.sequence_size.width, self.sequence_size.height))
    }

    /// Layer-local point to offset space, using `t`: affine part, then the perspective tilt about the anchor (`position`).
    pub fn offset_from_local(&self, l: Vec2, t: &ClipTransform) -> Vec2 {
        let flat = self.flat_offset_from_local(l, t);
        if !t.is_tilted() {
            return flat;
        }
        let p = tilt::project(flat - t.position, t.tilt_x, t.tilt_y, self.tilt_focal(t));
        t.position + p
    }

    /// Offset-space point (as seen on screen) back to the untilted offset the affine reducers work in.
    fn flat_offset_from_screen(&self, o: Vec2, t: &ClipTransform) -> Vec2 {
        if !t.is_tilted() {
            return o;
        }
        t.position + tilt::unproject(o - t.position, t.tilt_x, t.tilt_y, self.tilt_focal(t))
    }

    /// Layer-local point to view space under the current transform.
    pub fn view_point_from_local(&self, l: Vec2) -> CGPoint {
        self.view_point_from_offset(self.offset_from_local(l, &self.transform))
    }

    /// Offset-space delta to layer-local delta (inverse of rotation and scale) under `t`.
    fn local_delta_from_offset_delta(&self, d: Vec2, t: &ClipTransform) -> Vec2 {
        let r = rotate(d, -t.rotation);
        Vec2::new(r.x / t.scale.x.max(Self::MINIMUM_SCALE), r.y / t.scale.y.max(Self::MINIMUM_SCALE))
    }

    // Drawing geometry

    /// Corners in view coords: top-left, top-right, bottom-right, bottom-left of the layer.
    pub fn quad(&self) -> Vec<CGPoint> {
        let s = self.fitted_size();
        let (hw, hh) = (s.width / 2.0, s.height / 2.0);
        [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
            .iter()
            .map(|c| self.view_point_from_local(Vec2::new(c.0, c.1)))
            .collect()
    }

    /// A handle in layer-local space.
    pub fn local_point_of(&self, h: Handle) -> Vec2 {
        let s = self.fitted_size();
        let d = h.direction();
        Vec2::new(d.0 * s.width / 2.0, d.1 * s.height / 2.0)
    }
    /// A handle in view space.
    pub fn view_point_of(&self, h: Handle) -> CGPoint {
        self.view_point_from_local(self.local_point_of(h))
    }
    /// The anchor crosshair in view space.
    pub fn anchor_view_point(&self) -> CGPoint {
        self.view_point_from_offset(self.transform.position)
    }

    // Hit testing

    /// Direction of a handle on screen, degrees clockwise from +x (y down), for cursors: from the layer center outward.
    pub fn view_angle_of(&self, h: Handle) -> f64 {
        let c = self.view_point_from_local(Vec2::ZERO);
        let p = self.view_point_of(h);
        (p.y - c.y).atan2(p.x - c.x) * 180.0 / std::f64::consts::PI
    }

    /// The anchor always has priority within `ANCHOR_RADIUS` of its crosshair (it sits on the center of the picture by
    /// default, and must still be grabbable there). `anchor_always: false` is only for tests of the other zones.
    pub fn hit_test(&self, p: CGPoint, anchor_always: bool) -> Option<Hit> {
        let a = self.anchor_view_point();
        if anchor_always && (p.x - a.x).hypot(p.y - a.y) <= Self::ANCHOR_RADIUS {
            return Some(Hit::Anchor);
        }
        let mut best: Option<(Handle, f64)> = None;
        for h in Handle::ALL {
            let hp = self.view_point_of(h);
            let d = (p.x - hp.x).hypot(p.y - hp.y);
            if d <= Self::HANDLE_RADIUS && d < best.map_or(f64::INFINITY, |b| b.1) {
                best = Some((h, d));
            }
        }
        if let Some(best) = best {
            return Some(Hit::Handle(best.0));
        }
        if Self::contains(&self.quad(), p) {
            return Some(Hit::Body);
        }
        let mut near: Option<(Handle, f64)> = None;
        for h in Handle::ALL.into_iter().filter(|h| h.is_corner()) {
            if let Some(d) = self.rotate_distance(p, h)
                && d < near.map_or(f64::INFINITY, |n| n.1)
            {
                near = Some((h, d));
            }
        }
        near.map(|n| Hit::Rotate(n.0))
    }

    /// Distance from `corner` when `p` lies in the rotate zone of that corner, else `None`. The zone is the quadrant that
    /// opens outward from the corner (beyond both edges that meet there), up to `ROTATE_ZONE` away. Points merely near
    /// the corner but beside an edge belong to nothing, so the rotate cursor does not appear on the way to the corner.
    pub fn rotate_distance(&self, p: CGPoint, corner: Handle) -> Option<f64> {
        let hp = self.view_point_of(corner);
        let (a, b) = match corner {
            Handle::TopLeft => (Handle::Top, Handle::Left),
            Handle::TopRight => (Handle::Top, Handle::Right),
            Handle::BottomRight => (Handle::Bottom, Handle::Right),
            _ => (Handle::Bottom, Handle::Left),
        };
        let (vx, vy) = (p.x - hp.x, p.y - hp.y);
        let d = vx.hypot(vy);
        if d > Self::ROTATE_ZONE {
            return None;
        }
        for n in [a, b] {
            let np = self.view_point_of(n);
            // Along the edge towards the neighbor handle: positive means still beside the edge, not past the corner.
            if vx * (np.x - hp.x) + vy * (np.y - hp.y) > 0.0 {
                return None;
            }
        }
        Some(d)
    }

    /// Convex polygon containment, either winding.
    pub fn contains(q: &[CGPoint], p: CGPoint) -> bool {
        let mut sign = 0;
        for i in 0..q.len() {
            let (a, b) = (q[i], q[(i + 1) % q.len()]);
            let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
            let s = if c > 0.0 {
                1
            } else if c < 0.0 {
                -1
            } else {
                0
            };
            if s != 0 {
                if sign == 0 {
                    sign = s;
                } else if sign != s {
                    return false;
                }
            }
        }
        true
    }

    // Drag reducers (self.transform is the transform at gesture start)

    /// The transform after dragging the body from `start` to `p`.
    pub fn moved(&self, start: CGPoint, p: CGPoint, lock_axis: bool) -> ClipTransform {
        let s = self.view_scale();
        let (mut dx, mut dy) = ((p.x - start.x) / s, (p.y - start.y) / s);
        if lock_axis {
            if dx.abs() >= dy.abs() {
                dy = 0.0;
            } else {
                dx = 0.0;
            }
        }
        let mut t = self.transform;
        t.position = self.transform.position + Vec2::new(dx, dy);
        t
    }

    /// The transform after dragging handle `h` from `start` to `p`.
    pub fn scaled(&self, h: Handle, start: CGPoint, p: CGPoint, m: ScaleModifiers) -> ClipTransform {
        let t = self.transform;
        let hl = self.local_point_of(h);
        let dir = h.direction();
        // Pivot in local space.
        let fixed = if m.option {
            Vec2::new(if dir.0 != 0.0 { -hl.x } else { t.anchor.x }, if dir.1 != 0.0 { -hl.y } else { t.anchor.y })
        } else {
            t.anchor
        };
        let v = hl - fixed; // local vector pivot -> handle (unscaled)
        let tilted_pivot = t.is_tilted() && m.option;
        // Screen place of the pivot; with Option on a tilted layer it must stay there (the anchor, the tilt pivot, is
        // not the pivot then, so the pivot is tracked on screen and the position re-solved).
        let pivot_screen = self.offset_from_local(fixed, &t);
        // The handle follows the pointer, keeping the grab offset.
        let target = self.view_point_of(h);
        let eff = CGPoint { x: target.x + (p.x - start.x), y: target.y + (p.y - start.y) };
        let pointer_screen = self.offset_from_view(eff);

        // One solve: the pointer and the pivot are read back through the tilt of context `c` (about its position, with
        // its focal). With the anchor as pivot the start transform is exact; with Option the context is refined below.
        let solve = |c: &ClipTransform| -> ClipTransform {
            let fixed_offset = if tilted_pivot {
                self.flat_offset_from_screen(pivot_screen, c)
            } else {
                self.flat_offset_from_local(fixed, &t)
            };
            // scaled local vector pivot -> pointer
            let d = rotate(self.flat_offset_from_screen(pointer_screen, c) - fixed_offset, -t.rotation);

            let (mut sx, mut sy) = (t.scale.x, t.scale.y);
            if m.uniform_scale || m.shift {
                // Proportions locked: one factor for both axes, measured along the handle (corner: projection on its diagonal).
                let mut k: Option<f64> = None;
                if h.is_corner() {
                    let cur = Vec2::new(v.x * t.scale.x, v.y * t.scale.y);
                    let den = cur.x * cur.x + cur.y * cur.y;
                    if den > 0.0 {
                        k = Some((d.x * cur.x + d.y * cur.y) / den);
                    }
                } else if dir.0 != 0.0 && v.x.abs() > 1e-9 {
                    k = Some(d.x / v.x / t.scale.x.max(Self::MINIMUM_SCALE));
                } else if dir.1 != 0.0 && v.y.abs() > 1e-9 {
                    k = Some(d.y / v.y / t.scale.y.max(Self::MINIMUM_SCALE));
                }
                if let Some(mut k) = k {
                    // One factor for both axes, kept above the minimum for the smaller axis so the proportions survive the clamp.
                    let smallest = t.scale.x.min(t.scale.y).max(Self::MINIMUM_SCALE);
                    k = k.max(Self::MINIMUM_SCALE / smallest);
                    sx = t.scale.x.max(Self::MINIMUM_SCALE) * k;
                    sy = t.scale.y.max(Self::MINIMUM_SCALE) * k;
                }
            } else {
                if dir.0 != 0.0 && v.x.abs() > 1e-9 {
                    sx = d.x / v.x;
                }
                if dir.1 != 0.0 && v.y.abs() > 1e-9 {
                    sy = d.y / v.y;
                }
            }
            sx = sx.max(Self::MINIMUM_SCALE);
            sy = sy.max(Self::MINIMUM_SCALE);

            let mut out = t;
            out.scale = Vec2::new(sx, sy);
            // Keep the pivot where it was on the canvas.
            let shifted = rotate(Vec2::new((fixed.x - t.anchor.x) * sx, (fixed.y - t.anchor.y) * sy), t.rotation);
            if tilted_pivot {
                // The pivot's screen place is `position + project(shifted)`; the focal depends only on the new scale.
                let mut probe = out;
                probe.position = Vec2::ZERO;
                out.position = pivot_screen - tilt::project(shifted, t.tilt_x, t.tilt_y, self.tilt_focal(&probe));
            } else {
                out.position = fixed_offset - shifted;
            }
            out
        };

        let mut out = solve(&t);
        if tilted_pivot {
            // The pointer's plane point depends on the position and focal this solve changes: fixed-point rounds settle
            // it. Near +-89 degrees the map is steep and a plain round can overshoot, so each step is damped (halfway)
            // once the residual stops shrinking, and the candidate with the smallest residual is the one returned.
            // The result is always a real solve() output (its position is exact for its scale), never a blend.
            let mut context = out;
            let mut best = out;
            let mut best_residual = f64::INFINITY;
            let mut damp = 1.0_f64;
            let mut previous = f64::INFINITY;
            for _ in 0..12 {
                let next = solve(&context);
                let residual = (next.scale.x - context.scale.x).abs()
                    + (next.scale.y - context.scale.y).abs()
                    + (next.position.x - context.position.x).abs()
                    + (next.position.y - context.position.y).abs();
                if !residual.is_finite() {
                    break;
                }
                if residual < best_residual {
                    best_residual = residual;
                    best = next;
                }
                if residual < 1e-9 {
                    break;
                }
                if residual >= previous {
                    damp = (damp * 0.5).max(0.0625); // oscillating or diverging: smaller steps
                }
                previous = residual;
                context.scale = Vec2::new(
                    context.scale.x + (next.scale.x - context.scale.x) * damp,
                    context.scale.y + (next.scale.y - context.scale.y) * damp,
                );
                context.position = Vec2::new(
                    context.position.x + (next.position.x - context.position.x) * damp,
                    context.position.y + (next.position.y - context.position.y) * damp,
                );
            }
            out = best;
        }
        out
    }

    /// `last`: the rotation last produced in this gesture, so multi-turn drags do not wrap at 180 degrees.
    pub fn rotated(&self, start: CGPoint, p: CGPoint, snap: bool, last: Option<f64>) -> ClipTransform {
        let c = self.anchor_view_point();
        let a0 = (start.y - c.y).atan2(start.x - c.x);
        let a1 = (p.y - c.y).atan2(p.x - c.x);
        let mut delta = (a1 - a0) * 180.0 / std::f64::consts::PI;
        delta -= 360.0 * (delta / 360.0).round(); // nearest branch to 0 ...
        if let Some(last) = last {
            // ... or to the previous result
            let prev_delta = last - self.transform.rotation;
            delta += 360.0 * ((prev_delta - delta) / 360.0).round();
        }
        let mut r = self.transform.rotation + delta;
        if snap {
            r = (r / Self::ROTATION_SNAP_DEGREES).round() * Self::ROTATION_SNAP_DEGREES;
        }
        let mut t = self.transform;
        t.rotation = r;
        t
    }

    /// Moves the anchor with the pointer; position is compensated so the picture stays where it is.
    /// While tilted the anchor is also the tilt pivot, so moving it changes the projection a little: the anchor goes to
    /// the layer point under the pointer (read back through the tilt) and the position is solved numerically so the four
    /// corners keep their mean place on screen (exact for a flat layer).
    pub fn anchor_moved(&self, start: CGPoint, p: CGPoint) -> ClipTransform {
        let s = self.view_scale();
        let d_off = Vec2::new((p.x - start.x) / s, (p.y - start.y) / s);
        let mut t = self.transform;
        if !self.transform.is_tilted() {
            t.anchor = self.transform.anchor + self.local_delta_from_offset_delta(d_off, &self.transform);
            t.position = self.transform.position + d_off;
            return t;
        }
        // The anchor handle sits at `position`; the pointer moves it by `d_off` on screen.
        let plane = self.flat_offset_from_screen(self.transform.position + d_off, &self.transform);
        t.anchor = self.transform.anchor
            + self.local_delta_from_offset_delta(plane - self.transform.position, &self.transform);
        let size = self.fitted_size();
        let half = Vec2::new(size.width / 2.0, size.height / 2.0);
        let corners = [
            Vec2::new(-half.x, -half.y),
            Vec2::new(half.x, -half.y),
            Vec2::new(half.x, half.y),
            Vec2::new(-half.x, half.y),
        ];
        let before: Vec<Vec2> = corners.iter().map(|c| self.offset_from_local(*c, &self.transform)).collect();
        // Start with the new anchor's own screen place, then shift by the mean corner error.
        t.position = self.offset_from_local(t.anchor, &self.transform);
        for _ in 0..6 {
            let mut err = Vec2::ZERO;
            for (c, b) in corners.iter().zip(before.iter()) {
                err = err + (*b - self.offset_from_local(*c, &t));
            }
            err = err * (1.0 / corners.len() as f64);
            t.position = t.position + err;
            if err.x.abs() + err.y.abs() < 1e-9 {
                break;
            }
        }
        t
    }
}

// Motion path

/// A key of a motion path in view coords.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MotionKey {
    /// The key.
    pub id: Id,
    /// Its place.
    pub point: CGPoint,
    /// Absolute view positions of the tangent handles (equal to `point` when the tangent is zero).
    pub in_handle: CGPoint,
    /// Out handle.
    pub out_handle: CGPoint,
    /// The in tangent is not zero.
    pub has_in_tangent: bool,
    /// The out tangent is not zero.
    pub has_out_tangent: bool,
}

/// What a press on the motion path hit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MotionHit {
    /// A key.
    Key(Id),
    /// Its in tangent handle.
    InTangent(Id),
    /// Its out tangent handle.
    OutTangent(Id),
}

/// Motion path of a position track in view coords, plus drag reducers for its keys and tangents.
#[derive(Clone, Debug, PartialEq)]
pub struct MotionPathGeometry {
    /// Where the sequence canvas is drawn.
    pub view_rect: CGRect,
    /// The sequence's size in px.
    pub sequence_size: CGSize,
    /// One polyline per segment, view coords. Hold segments have a single point.
    pub segments: Vec<Vec<CGPoint>>,
    /// The keys.
    pub keys: Vec<MotionKey>,
}

impl MotionPathGeometry {
    /// Grab radius of a key.
    pub const KEY_RADIUS: f64 = 6.0;
    /// Grab radius of a tangent handle.
    pub const TANGENT_RADIUS: f64 = 5.0;

    /// The path of `track`.
    pub fn new(
        track: &KeyframeTrack<Vec2>,
        sequence_size: CGSize,
        view_rect: CGRect,
        samples_per_segment: usize,
    ) -> MotionPathGeometry {
        let scale = if sequence_size.width > 0.0 { view_rect.width / sequence_size.width } else { 1.0 };
        let to_view = |v: Vec2| CGPoint { x: view_rect.mid_x() + v.x * scale, y: view_rect.mid_y() + v.y * scale };
        let segments = track
            .motion_path(samples_per_segment)
            .iter()
            .map(|s| s.points.iter().map(|p| to_view(*p)).collect())
            .collect();
        let keys = track
            .keys
            .iter()
            .map(|k| MotionKey {
                id: k.id,
                point: to_view(k.value),
                in_handle: to_view(k.value + k.in_tangent),
                out_handle: to_view(k.value + k.out_tangent),
                has_in_tangent: k.in_tangent != Vec2::ZERO,
                has_out_tangent: k.out_tangent != Vec2::ZERO,
            })
            .collect();
        MotionPathGeometry { view_rect, sequence_size, segments, keys }
    }

    /// View points per sequence px.
    pub fn view_scale(&self) -> f64 {
        if self.sequence_size.width > 0.0 { self.view_rect.width / self.sequence_size.width } else { 1.0 }
    }

    /// Tangent handles are hit targets for the selected key or when they are non-zero.
    pub fn hit_test(&self, p: CGPoint, selected_key: Option<Id>) -> Option<MotionHit> {
        let near = |a: CGPoint, r: f64| (p.x - a.x).hypot(p.y - a.y) <= r;
        for k in &self.keys {
            if (Some(k.id) == selected_key || k.has_out_tangent)
                && k.out_handle != k.point
                && near(k.out_handle, Self::TANGENT_RADIUS)
            {
                return Some(MotionHit::OutTangent(k.id));
            }
            if (Some(k.id) == selected_key || k.has_in_tangent)
                && k.in_handle != k.point
                && near(k.in_handle, Self::TANGENT_RADIUS)
            {
                return Some(MotionHit::InTangent(k.id));
            }
        }
        self.keys.iter().find(|k| near(k.point, Self::KEY_RADIUS)).map(|k| MotionHit::Key(k.id))
    }

    /// New position value for a key dragged to `p` (view coords).
    pub fn key_value(&self, p: CGPoint) -> Vec2 {
        let s = self.view_scale();
        Vec2::new((p.x - self.view_rect.mid_x()) / s, (p.y - self.view_rect.mid_y()) / s)
    }

    /// Tangent (offset from the key value, sequence px) for a handle dragged to `p`.
    pub fn tangent(&self, id: Id, p: CGPoint) -> Vec2 {
        let Some(k) = self.keys.iter().find(|k| k.id == id) else { return Vec2::ZERO };
        let s = self.view_scale();
        Vec2::new((p.x - k.point.x) / s, (p.y - k.point.y) / s)
    }

    /// Dragging one handle of a key: the other handle mirrors it (smooth key) unless `independent` (Option).
    /// Returns (in, out).
    pub fn tangents(
        &self,
        id: Id,
        side: MotionHit,
        p: CGPoint,
        independent: bool,
        current: (Vec2, Vec2),
    ) -> (Vec2, Vec2) {
        let t = self.tangent(id, p);
        match side {
            MotionHit::OutTangent(_) => (if independent { current.0 } else { t * -1.0 }, t),
            MotionHit::InTangent(_) => (t, if independent { current.1 } else { t * -1.0 }),
            MotionHit::Key(_) => current,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::keyframes_model::Keyframe;
    use sq_core_time::{IdSource, SequentialIds, Time};

    fn geo(t: ClipTransform, aspect: f64) -> TransformOverlayGeometry {
        // 1920x1080 sequence shown at half size, view origin offset by 10 px.
        TransformOverlayGeometry::new(
            CGSize::new(1920.0, 1080.0),
            CGRect::new(10.0, 10.0, 960.0, 540.0),
            aspect,
            t,
            None,
        )
    }
    fn id() -> ClipTransform {
        ClipTransform::IDENTITY
    }
    fn g0() -> TransformOverlayGeometry {
        geo(id(), 16.0 / 9.0)
    }
    fn pt(x: f64, y: f64) -> CGPoint {
        CGPoint { x, y }
    }
    fn close(a: CGPoint, b: CGPoint) -> bool {
        close_by(a, b, 0.001)
    }
    fn close_by(a: CGPoint, b: CGPoint, e: f64) -> bool {
        (a.x - b.x).abs() < e && (a.y - b.y).abs() < e
    }
    fn mods(shift: bool, option: bool, uniform_scale: bool) -> ScaleModifiers {
        ScaleModifiers { shift, option, uniform_scale }
    }

    #[test]
    fn identity_quad_fills_canvas() {
        let q = g0().quad();
        assert!(close(q[0], pt(10.0, 10.0)));
        assert!(close(q[2], pt(970.0, 550.0)));
    }

    #[test]
    fn portrait_media_is_pillarboxed() {
        let s = geo(id(), 9.0 / 16.0).fitted_size();
        assert!((s.height - 1080.0).abs() < 0.001 && (s.width - 607.5).abs() < 0.001);
    }

    #[test]
    fn position_and_scale_move_quad() {
        let t = ClipTransform { position: Vec2::new(100.0, -50.0), scale: Vec2::new(0.5, 0.5), ..id() };
        let q = geo(t, 16.0 / 9.0).quad();
        assert!(close(q[0], pt(540.0 - 240.0, 255.0 - 135.0)));
    }

    #[test]
    fn rotation_is_clockwise_about_anchor() {
        let g = geo(ClipTransform { rotation: 90.0, ..id() }, 16.0 / 9.0);
        assert!(close(g.quad()[0], pt(490.0 + 270.0, 280.0 - 480.0)));
    }

    #[test]
    fn anchor_offset_pivots_scale() {
        let t = ClipTransform {
            position: Vec2::ZERO,
            scale: Vec2::new(2.0, 2.0),
            anchor: Vec2::new(-960.0, -540.0),
            ..id()
        };
        let g = geo(t, 16.0 / 9.0);
        assert!(close(g.quad()[0], pt(490.0, 280.0)));
        assert!(close(g.quad()[2], pt(490.0 + 1920.0, 280.0 + 1080.0)));
    }

    #[test]
    fn hit_priority() {
        let g = g0();
        assert_eq!(g.hit_test(pt(490.0, 280.0), true), Some(Hit::Anchor));
        assert_eq!(g.hit_test(pt(498.0, 284.0), true), Some(Hit::Anchor));
        assert_eq!(g.hit_test(pt(490.0, 280.0), false), Some(Hit::Body));
        assert_eq!(g.hit_test(pt(520.0, 280.0), true), Some(Hit::Body));
        let off = geo(ClipTransform { anchor: Vec2::new(400.0, 0.0), ..id() }, 16.0 / 9.0);
        assert_eq!(off.hit_test(pt(490.0, 280.0), true), Some(Hit::Anchor));
        assert_eq!(g.hit_test(pt(12.0, 12.0), true), Some(Hit::Handle(Handle::TopLeft)));
        assert_eq!(g.hit_test(pt(490.0, 11.0), true), Some(Hit::Handle(Handle::Top)));
        assert_eq!(g.hit_test(pt(300.0, 200.0), true), Some(Hit::Body));
        assert_eq!(g.hit_test(pt(0.0, 0.0), true), Some(Hit::Rotate(Handle::TopLeft)));
        assert_eq!(g.hit_test(pt(1100.0, 700.0), true), None);
    }

    #[test]
    fn move_and_axis_lock() {
        let g = g0();
        let t = g.moved(pt(100.0, 100.0), pt(150.0, 110.0), false);
        assert_eq!(t.position, Vec2::new(100.0, 20.0));
        let l = g.moved(pt(100.0, 100.0), pt(150.0, 110.0), true);
        assert_eq!(l.position, Vec2::new(100.0, 0.0));
    }

    #[test]
    fn corner_scale_keeps_anchor_fixed_and_follows_pointer() {
        let g = g0();
        let h = g.view_point_of(Handle::BottomRight);
        let t = g.scaled(Handle::BottomRight, h, pt(h.x - 240.0, h.y - 135.0), ScaleModifiers::default());
        assert!((t.scale.x - 0.5).abs() < 1e-9 && (t.scale.y - 0.5).abs() < 1e-9);
        assert_eq!(t.position, Vec2::ZERO);
    }

    #[test]
    fn option_pivots_on_opposite_corner() {
        let g = g0();
        let h = g.view_point_of(Handle::BottomRight);
        let t = g.scaled(Handle::BottomRight, h, pt(h.x - 480.0, h.y - 270.0), mods(false, true, true));
        assert!((t.scale.x - 0.5).abs() < 1e-9);
        let q = geo(t, 16.0 / 9.0).quad();
        assert!(close(q[0], g.quad()[0]));
        assert!(close(q[2], pt(490.0, 280.0)));
    }

    #[test]
    fn uniform_scale_off_edges_scale_one_axis_and_corners_are_free() {
        let g = g0();
        let free = mods(false, false, false);
        let r = g.view_point_of(Handle::Right);
        let e = g.scaled(Handle::Right, r, pt(r.x - 240.0, r.y + 50.0), free);
        assert!((e.scale.x - 0.5).abs() < 1e-9 && e.scale.y == 1.0);
        let tp = g.view_point_of(Handle::Top);
        let v = g.scaled(Handle::Top, tp, pt(tp.x + 80.0, tp.y + 135.0), free);
        assert!((v.scale.y - 0.5).abs() < 1e-9 && v.scale.x == 1.0);
        let c = g.view_point_of(Handle::BottomRight);
        let f = g.scaled(Handle::BottomRight, c, pt(c.x - 240.0, c.y), free);
        assert!((f.scale.x - 0.5).abs() < 1e-9 && f.scale.y == 1.0);
        let shifted = g.scaled(Handle::BottomRight, c, pt(c.x - 240.0, c.y), mods(true, false, false));
        assert!((shifted.scale.x - shifted.scale.y).abs() < 1e-9 && shifted.scale.x < 1.0);
        let side_shift = g.scaled(Handle::Right, r, pt(r.x - 240.0, r.y), mods(true, false, false));
        assert!((side_shift.scale.x - 0.5).abs() < 1e-9 && (side_shift.scale.y - 0.5).abs() < 1e-9);
    }

    #[test]
    fn uniform_scale_on_every_handle_scales_both_axes() {
        let g = g0();
        for h in Handle::ALL {
            let p = g.view_point_of(h);
            let c = g.view_point_from_local(Vec2::ZERO);
            let t = g.scaled(h, p, pt(p.x + (c.x - p.x) / 2.0, p.y + (c.y - p.y) / 2.0), ScaleModifiers::default());
            assert!((t.scale.x - t.scale.y).abs() < 1e-9, "{h:?}");
            assert!((t.scale.x - 0.5).abs() < 1e-6, "{h:?}");
            assert_eq!(t.position, Vec2::ZERO, "{h:?}");
        }
    }

    #[test]
    fn uniform_edge_drag_follows_its_axis_only() {
        let g = g0();
        let r = g.view_point_of(Handle::Right);
        let t = g.scaled(Handle::Right, r, pt(r.x - 240.0, r.y + 300.0), ScaleModifiers::default());
        assert!((t.scale.x - 0.5).abs() < 1e-9 && (t.scale.y - 0.5).abs() < 1e-9);
    }

    #[test]
    fn scale_clamps_positive() {
        let g = g0();
        let c = g.view_point_of(Handle::BottomRight);
        let t = g.scaled(Handle::BottomRight, c, pt(c.x - 2000.0, c.y - 2000.0), ScaleModifiers::default());
        assert_eq!(t.scale.x, TransformOverlayGeometry::MINIMUM_SCALE);
    }

    #[test]
    fn scale_of_rotated_layer() {
        let g = geo(ClipTransform { rotation: 30.0, ..id() }, 16.0 / 9.0);
        let h = g.view_point_of(Handle::Right);
        let a = g.anchor_view_point();
        let t =
            g.scaled(Handle::Right, h, pt(h.x - (h.x - a.x) / 2.0, h.y - (h.y - a.y) / 2.0), ScaleModifiers::default());
        assert!((t.scale.x - 0.5).abs() < 1e-9 && t.position == Vec2::ZERO);
    }

    #[test]
    fn rotate_and_snap() {
        let g = g0();
        let c = g.anchor_view_point();
        let t = g.rotated(pt(c.x + 100.0, c.y), pt(c.x, c.y + 100.0), false, None);
        assert!((t.rotation - 90.0).abs() < 1e-9);
        let s = g.rotated(pt(c.x + 100.0, c.y), pt(c.x + 100.0, c.y + 30.0), true, None);
        assert_eq!(s.rotation, 0.0);
        let s2 = g.rotated(pt(c.x + 100.0, c.y), pt(c.x + 100.0, c.y + 80.0), true, None);
        assert_eq!(s2.rotation, 45.0);
    }

    #[test]
    fn rotate_ring_sits_outside_each_corner_handle() {
        let g = g0();
        let corners = [
            (Handle::TopLeft, pt(10.0, 10.0), (-1.0, -1.0)),
            (Handle::TopRight, pt(970.0, 10.0), (1.0, -1.0)),
            (Handle::BottomRight, pt(970.0, 550.0), (1.0, 1.0)),
            (Handle::BottomLeft, pt(10.0, 550.0), (-1.0, 1.0)),
        ];
        for (h, c, out) in corners {
            let n = 2.0_f64.sqrt();
            let at = |d: f64| pt(c.x + out.0 * d / n, c.y + out.1 * d / n);
            assert_eq!(g.hit_test(at(3.0), true), Some(Hit::Handle(h)));
            assert_eq!(g.hit_test(at(10.0), true), Some(Hit::Rotate(h)));
            assert_eq!(g.hit_test(at(19.0), true), Some(Hit::Rotate(h)));
            assert_eq!(g.hit_test(at(24.0), true), None);
        }
    }

    #[test]
    fn rotate_cursor_not_along_the_edges_on_the_way_to_the_corner() {
        let g = g0();
        assert_eq!(g.hit_test(pt(22.0, 4.0), true), None);
        assert_eq!(g.hit_test(pt(4.0, 22.0), true), None);
        assert_eq!(g.hit_test(pt(976.0, 540.0), true), None);
        assert_eq!(g.hit_test(pt(4.0, 4.0), true), Some(Hit::Rotate(Handle::TopLeft)));
        assert_eq!(g.hit_test(pt(976.0, 556.0), true), Some(Hit::Rotate(Handle::BottomRight)));
    }

    #[test]
    fn rotate_ring_follows_rotated_layer() {
        let g = geo(ClipTransform { rotation: 45.0, ..id() }, 16.0 / 9.0);
        let c = g.view_point_of(Handle::TopLeft);
        let centre = g.view_point_from_local(Vec2::ZERO);
        let len = (c.x - centre.x).hypot(c.y - centre.y);
        let (ux, uy) = ((c.x - centre.x) / len, (c.y - centre.y) / len);
        assert_eq!(g.hit_test(pt(c.x + ux * 16.0, c.y + uy * 16.0), true), Some(Hit::Rotate(Handle::TopLeft)));
    }

    #[test]
    fn handle_view_angle_turns_with_the_object() {
        let g = g0();
        assert!(g.view_angle_of(Handle::Right).abs() < 1e-6);
        assert!((g.view_angle_of(Handle::Bottom) - 90.0).abs() < 1e-6);
        let r = geo(ClipTransform { rotation: 90.0, ..id() }, 16.0 / 9.0);
        assert!((r.view_angle_of(Handle::Right) - 90.0).abs() < 1e-6);
    }

    #[test]
    fn rotation_continues_past_half_turn() {
        let g = g0();
        let c = g.anchor_view_point();
        let start = pt(c.x + 100.0, c.y);
        let t = g.rotated(start, pt(c.x - 100.0, c.y - 1.0), false, Some(170.0));
        assert!(t.rotation > 180.0 && t.rotation < 181.0);
        let u = g.rotated(start, pt(c.x - 100.0, c.y + 1.0), false, Some(179.0));
        assert!(u.rotation > 179.0 && u.rotation < 180.0);
    }

    #[test]
    fn anchor_move_keeps_picture_still() {
        let t0 = ClipTransform {
            position: Vec2::new(30.0, 20.0),
            scale: Vec2::new(0.7, 1.3),
            rotation: 40.0,
            anchor: Vec2::new(10.0, -5.0),
            ..id()
        };
        let g = geo(t0, 16.0 / 9.0);
        let a = g.anchor_view_point();
        let t1 = g.anchor_moved(a, pt(a.x + 60.0, a.y - 25.0));
        let (before, after) = (g.quad(), geo(t1, 16.0 / 9.0).quad());
        for i in 0..4 {
            assert!(close_by(before[i], after[i], 0.0001));
        }
        assert_ne!(t1.anchor, t0.anchor);
        assert!(close(geo(t1, 16.0 / 9.0).anchor_view_point(), pt(a.x + 60.0, a.y - 25.0)));
    }

    #[test]
    fn motion_path_keys_handles_and_drags() {
        let mut ids = SequentialIds::default();
        let mut k1 = Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(-100.0, 0.0));
        k1.out_tangent = Vec2::new(50.0, 100.0);
        let mut k2 = Keyframe::new(ids.next_id(), Time::new(1, 1), Vec2::new(100.0, 0.0));
        k2.in_tangent = Vec2::new(-50.0, 100.0);
        let k1_id = k1.id;
        let track = KeyframeTrack { keys: vec![k1, k2] };
        let m = MotionPathGeometry::new(&track, CGSize::new(1920.0, 1080.0), CGRect::new(0.0, 0.0, 960.0, 540.0), 8);
        assert!(m.segments.len() == 1 && m.segments[0].len() == 8);
        assert!(close(m.keys[0].point, pt(430.0, 270.0)));
        assert!(close(m.keys[0].out_handle, pt(455.0, 320.0)));
        assert_eq!(m.hit_test(pt(431.0, 271.0), None), Some(MotionHit::Key(k1_id)));
        assert_eq!(m.hit_test(pt(455.0, 320.0), None), Some(MotionHit::OutTangent(k1_id)));
        assert_eq!(m.hit_test(pt(10.0, 10.0), None), None);
        assert_eq!(m.key_value(pt(480.0, 270.0)), Vec2::new(0.0, 0.0));
        let tg = m.tangents(
            k1_id,
            MotionHit::OutTangent(k1_id),
            pt(480.0, 270.0),
            false,
            (Vec2::ZERO, Vec2::new(50.0, 100.0)),
        );
        assert!(tg.1 == Vec2::new(100.0, 0.0) && tg.0 == Vec2::new(-100.0, 0.0));
    }

    #[test]
    fn uniform_scale_near_minimum_keeps_proportions() {
        let g = geo(ClipTransform { scale: Vec2::new(2.0, 0.5), ..id() }, 16.0 / 9.0);
        let c = g.view_point_of(Handle::BottomRight);
        let t = g.scaled(Handle::BottomRight, c, pt(c.x - 5000.0, c.y - 5000.0), ScaleModifiers::default());
        assert!(t.scale.y >= TransformOverlayGeometry::MINIMUM_SCALE - 1e-12);
        assert!((t.scale.x / t.scale.y - 4.0).abs() < 1e-6);
        let z = geo(ClipTransform { scale: Vec2::new(1.0, 0.0), ..id() }, 16.0 / 9.0);
        let zt = z.scaled(Handle::Right, z.view_point_of(Handle::Right), pt(100.0, 100.0), ScaleModifiers::default());
        assert!(
            zt.scale.x >= TransformOverlayGeometry::MINIMUM_SCALE
                && zt.scale.y >= TransformOverlayGeometry::MINIMUM_SCALE
        );
    }
}
