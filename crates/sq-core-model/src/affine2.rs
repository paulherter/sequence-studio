// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectTransformStage.swift (the Affine2 type, moved down; its math: task M-2)

use crate::ClipTransform;
use sq_core_time::Vec2;

/// A 2-D affine map p -> L p + t (L row-major `a b / c d`), in f64.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Affine2 {
    /// L[0][0].
    pub a: f64,
    /// L[0][1].
    pub b: f64,
    /// L[1][0].
    pub c: f64,
    /// L[1][1].
    pub d: f64,
    /// Translation.
    pub t: Vec2,
}

impl Affine2 {
    /// p -> p.
    pub const IDENTITY: Affine2 = Affine2 { a: 1.0, b: 0.0, c: 0.0, d: 1.0, t: Vec2::ZERO };
}

/// One effect transform stage at one instant, in px of the clip's own frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StageTransform {
    /// Offset.
    pub position: Vec2,
    /// Width factor, linear (1 = 100 %), >= 0; also the height factor unless `scale_y_override` is set.
    pub scale: f64,
    /// Separate height factor (Transform's unlinked Scale, P5); `None` = linked to `scale`.
    pub scale_y_override: Option<f64>,
    /// Degrees, clockwise on screen.
    pub rotation: f64,
    /// Pivot, offset from the frame center.
    pub anchor: Vec2,
    /// 0...1.
    pub opacity: f64,
}

impl StageTransform {
    /// A stage that moves nothing and keeps the opacity.
    pub const IDENTITY: StageTransform = StageTransform {
        position: Vec2::ZERO,
        scale: 1.0,
        scale_y_override: None,
        rotation: 0.0,
        anchor: Vec2::ZERO,
        opacity: 1.0,
    };

    /// The height factor.
    pub fn scale_y(&self) -> f64 {
        self.scale_y_override.unwrap_or(self.scale)
    }

    /// Moves no pixel (the anchor then does not matter) and keeps the opacity.
    pub fn is_identity(&self) -> bool {
        self.position == Vec2::ZERO
            && self.scale == 1.0
            && self.scale_y() == 1.0
            && self.rotation == 0.0
            && self.opacity == 1.0
    }
}

impl Default for StageTransform {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl From<&StageTransform> for Affine2 {
    /// The map of a stage: p -> R s (p - anchor) + anchor + position.
    fn from(s: &StageTransform) -> Affine2 {
        let m = Affine2::rot_scale(s.rotation, s.scale, s.scale_y());
        Affine2 { t: s.anchor + s.position - m.linear(s.anchor), ..m }
    }
}

impl ClipTransform {
    /// Where the clip-frame point `p` (offset from the frame center, source px, y down) lands on the canvas (offset from the
    /// canvas center): R S (p - anchor) + position, as the compositor draws it.
    pub fn map(&self, p: Vec2) -> Vec2 {
        Affine2::rot_scale(self.rotation, self.scale.x, self.scale.y).linear(p - self.anchor) + self.position
    }
}

impl Affine2 {
    /// Rotation (degrees, clockwise with y down) times scale (sx, sy), scale applied first.
    pub fn rot_scale(degrees: f64, sx: f64, sy: f64) -> Affine2 {
        let r = degrees * std::f64::consts::PI / 180.0;
        let (si, co) = r.sin_cos();
        Affine2 { a: co * sx, b: -si * sy, c: si * sx, d: co * sy, t: Vec2::ZERO }
    }

    /// The linear part applied to `p`.
    pub fn linear(&self, p: Vec2) -> Vec2 {
        Vec2::new(self.a * p.x + self.b * p.y, self.c * p.x + self.d * p.y)
    }

    /// The map applied to `p`.
    pub fn apply(&self, p: Vec2) -> Vec2 {
        self.linear(p) + self.t
    }

    /// self after `o`: p -> self(o(p)).
    pub fn after(&self, o: &Affine2) -> Affine2 {
        Affine2 {
            a: self.a * o.a + self.b * o.c,
            b: self.a * o.b + self.b * o.d,
            c: self.c * o.a + self.d * o.c,
            d: self.c * o.b + self.d * o.d,
            t: self.linear(o.t) + self.t,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_is_clockwise_with_y_down_and_scale_comes_first() {
        let m = Affine2::rot_scale(90.0, 2.0, 3.0);
        let p = m.linear(Vec2::new(1.0, 0.0));
        assert!(p.x.abs() < 1e-12 && (p.y - 2.0).abs() < 1e-12);
        let q = m.linear(Vec2::new(0.0, 1.0));
        assert!((q.x + 3.0).abs() < 1e-12 && q.y.abs() < 1e-12);
    }

    #[test]
    fn after_composes_right_to_left() {
        let shift = Affine2 { t: Vec2::new(10.0, 5.0), ..Affine2::IDENTITY };
        let scale = Affine2::rot_scale(0.0, 2.0, 2.0);
        let both = scale.after(&shift);
        assert_eq!(both.apply(Vec2::new(1.0, 1.0)), scale.apply(shift.apply(Vec2::new(1.0, 1.0))));
        assert_eq!(both.apply(Vec2::new(1.0, 1.0)), Vec2::new(22.0, 12.0));
        assert_eq!(Affine2::IDENTITY.after(&both), both);
    }

    #[test]
    fn a_stage_scales_and_turns_about_its_anchor_then_moves() {
        let stage = StageTransform {
            position: Vec2::new(10.0, 0.0),
            scale: 2.0,
            rotation: 90.0,
            anchor: Vec2::new(1.0, 0.0),
            ..StageTransform::IDENTITY
        };
        let m = Affine2::from(&stage);
        assert_eq!(m.apply(stage.anchor), Vec2::new(11.0, 0.0), "the anchor stays put and only the position moves it");
        let p = m.apply(Vec2::new(2.0, 0.0));
        assert!(
            (p.x - 11.0).abs() < 1e-12 && (p.y - 2.0).abs() < 1e-12,
            "{p:?}: one unit right of the anchor, turned down, doubled"
        );
        assert_eq!(Affine2::from(&StageTransform::IDENTITY), Affine2::IDENTITY);
    }

    #[test]
    fn the_height_follows_the_width_unless_unlinked() {
        let linked = StageTransform { scale: 1.5, ..StageTransform::IDENTITY };
        assert_eq!(linked.scale_y(), 1.5);
        let unlinked = StageTransform { scale_y_override: Some(0.5), ..linked };
        assert_eq!((Affine2::from(&unlinked).a, Affine2::from(&unlinked).d), (1.5, 0.5));
        assert!(StageTransform::IDENTITY.is_identity() && !unlinked.is_identity());
        assert!(StageTransform { anchor: Vec2::new(5.0, 5.0), ..StageTransform::IDENTITY }.is_identity());
    }

    #[test]
    fn clip_transform_maps_frame_points_to_the_canvas() {
        assert_eq!(ClipTransform::IDENTITY.map(Vec2::new(3.0, -4.0)), Vec2::new(3.0, -4.0));
        let t = ClipTransform {
            position: Vec2::new(100.0, 50.0),
            scale: Vec2::new(2.0, 2.0),
            anchor: Vec2::new(10.0, 0.0),
            ..ClipTransform::IDENTITY
        };
        assert_eq!(t.map(Vec2::new(10.0, 0.0)), Vec2::new(100.0, 50.0), "the anchor lands on the position");
        assert_eq!(t.map(Vec2::new(11.0, 1.0)), Vec2::new(102.0, 52.0));
    }
}
