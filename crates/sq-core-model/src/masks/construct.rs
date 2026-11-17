// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Masks.swift (path builders, `polygon()` and the `ClipMask.make*` constructors)

use crate::{ClipMask, ColorRangeKey, MagicPoint, MagicSelection, MaskPath, MaskShapeKind, MaskSource, MaskVertex};
use sq_core_time::{Id, Vec2};

impl MaskPath {
    /// Line pieces per curved segment when flattened (`polygon()`).
    pub const CURVE_SUBDIVISIONS: usize = 16;
    /// Most polygon points one mask hands to the renderer.
    pub const MAX_POLYGON_POINTS: usize = 1024;

    /// Corners clockwise from the top left.
    pub fn rectangle(a: Vec2, b: Vec2) -> MaskPath {
        let (lo, hi) = (Vec2::new(a.x.min(b.x), a.y.min(b.y)), Vec2::new(a.x.max(b.x), a.y.max(b.y)));
        MaskPath {
            vertices: vec![
                MaskVertex::corner(lo),
                MaskVertex::corner(Vec2::new(hi.x, lo.y)),
                MaskVertex::corner(hi),
                MaskVertex::corner(Vec2::new(lo.x, hi.y)),
            ],
        }
    }

    /// Four-point bezier ellipse (top, right, bottom, left), tangents at the circle constant.
    pub fn ellipse(center: Vec2, radius: Vec2) -> MaskPath {
        let k = 0.552_284_749_830_793_6;
        let (kx, ky) = (radius.x * k, radius.y * k);
        let (c, r) = (center, radius);
        let vertex = |point, tangent: Vec2| MaskVertex {
            point,
            in_tangent: Vec2::new(-tangent.x, -tangent.y),
            out_tangent: tangent,
        };
        MaskPath {
            vertices: vec![
                vertex(Vec2::new(c.x, c.y - r.y), Vec2::new(kx, 0.0)),
                vertex(Vec2::new(c.x + r.x, c.y), Vec2::new(0.0, ky)),
                vertex(Vec2::new(c.x, c.y + r.y), Vec2::new(-kx, 0.0)),
                vertex(Vec2::new(c.x - r.x, c.y), Vec2::new(0.0, -ky)),
            ],
        }
    }

    /// The path as a closed polygon (frame fractions): straight segments give one point, curved ones
    /// `CURVE_SUBDIVISIONS`.
    pub fn polygon(&self) -> Vec<Vec2> {
        let n = self.vertices.len();
        let mut out = Vec::with_capacity(n * 4);
        for i in 0..n {
            let (a, b) = (&self.vertices[i], &self.vertices[(i + 1) % n]);
            out.push(a.point);
            if a.out_tangent == Vec2::ZERO && b.in_tangent == Vec2::ZERO {
                continue;
            }
            let (p0, p1, p2, p3) = (a.point, a.point + a.out_tangent, b.point + b.in_tangent, b.point);
            for s in 1..Self::CURVE_SUBDIVISIONS {
                let t = s as f64 / Self::CURVE_SUBDIVISIONS as f64;
                let u = 1.0 - t;
                let (w0, w1, w2, w3) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
                out.push(Vec2::new(
                    p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3,
                    p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3,
                ));
            }
        }
        if out.len() > Self::MAX_POLYGON_POINTS {
            let step = out.len() as f64 / Self::MAX_POLYGON_POINTS as f64;
            out = (0..Self::MAX_POLYGON_POINTS).map(|i| out[(i as f64 * step) as usize]).collect();
        }
        out
    }

    fn whole_frame() -> MaskPath {
        MaskPath::rectangle(Vec2::ZERO, Vec2::new(1.0, 1.0))
    }
}

impl ClipMask {
    /// A new Rectangle / Ellipse mask in the middle of the frame (half its size), Premiere's default feather.
    pub fn make(id: Id, kind: MaskShapeKind, name: &str) -> ClipMask {
        let path = if kind == MaskShapeKind::Ellipse {
            MaskPath::ellipse(Vec2::new(0.5, 0.5), Vec2::new(0.25, 0.25))
        } else {
            MaskPath::rectangle(Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.75))
        };
        let mut m = ClipMask::new(id, name, kind, path);
        m.feather.value = Self::DEFAULT_FEATHER;
        m
    }

    /// A mask whose shape is not its path: the path is the whole frame, so a build without that source cuts nothing.
    fn sourced(id: Id, name: &str, source: MaskSource) -> ClipMask {
        let mut m = ClipMask::new(id, name, MaskShapeKind::Rectangle, MaskPath::whole_frame());
        m.set_source(source);
        m
    }

    /// W9.8: a person matte (Vision) as the mask. Feather, expansion and the path are not used while the source is
    /// `Subject`.
    pub fn make_subject(id: Id, name: &str) -> ClipMask {
        Self::sourced(id, name, MaskSource::Subject)
    }

    /// A Magic mask: the objects under `points` (empty = nothing picked yet), followed by Track. Feather, Expansion and
    /// Opacity act on the matte edge.
    pub fn make_magic(id: Id, name: &str, points: Vec<MagicPoint>) -> ClipMask {
        let mut m = Self::sourced(id, name, MaskSource::Magic);
        m.magic = Some(MagicSelection { points, part: None });
        m
    }

    /// C6: another track's picture as the mask (`track`: a video track of the same timeline, not the clip's own). Feather
    /// and Expansion are not used in v1.
    pub fn make_picture(id: Id, name: &str, track: Option<Id>) -> ClipMask {
        let mut m = Self::sourced(id, name, MaskSource::Picture);
        m.picture_track = track;
        m
    }

    /// v87: the picture's own color as the mask (`key`). Feather and Expansion are not used (Softness is the edge).
    pub fn make_color_range(id: Id, name: &str, key: ColorRangeKey) -> ClipMask {
        let mut m = Self::sourced(id, name, MaskSource::ColorRange);
        m.set_color_range(key);
        m
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn a_rectangle_runs_clockwise_from_the_top_left_whatever_order_the_corners_come_in() {
        let r = MaskPath::rectangle(Vec2::new(0.75, 0.25), Vec2::new(0.25, 0.75));
        let pts: Vec<_> = r.vertices.iter().map(|v| (v.point.x, v.point.y)).collect();
        assert_eq!(pts, [(0.25, 0.25), (0.75, 0.25), (0.75, 0.75), (0.25, 0.75)]);
        assert!(r.vertices.iter().all(|v| v.in_tangent == Vec2::ZERO && v.out_tangent == Vec2::ZERO));
        assert_eq!(r.polygon().len(), 4, "straight segments give one point each");
    }

    #[test]
    fn an_ellipse_has_four_bezier_points_and_flattens_to_sixty_four() {
        let e = MaskPath::ellipse(Vec2::new(0.5, 0.5), Vec2::new(0.25, 0.25));
        assert_eq!(e.vertices[0].point, Vec2::new(0.5, 0.25));
        assert_eq!(e.vertices[0].out_tangent, Vec2::new(0.25 * 0.552_284_749_830_793_6, 0.0));
        assert_eq!(e.vertices[0].in_tangent, Vec2::new(-0.25 * 0.552_284_749_830_793_6, 0.0));
        assert_eq!(e.vertices[3].out_tangent.y, -0.25 * 0.552_284_749_830_793_6);
        let poly = e.polygon();
        assert_eq!(poly.len(), 4 * MaskPath::CURVE_SUBDIVISIONS);
        // Every flattened point lies on the circle to within the flattening error.
        for p in &poly {
            let d = ((p.x - 0.5).powi(2) + (p.y - 0.5).powi(2)).sqrt();
            assert!((d - 0.25).abs() < 1e-3, "{p:?} is {d} from the center");
        }
        assert_eq!(poly[0], Vec2::new(0.5, 0.25));
    }

    #[test]
    fn a_long_polygon_is_thinned_to_the_limit_and_an_empty_path_has_none() {
        let many = MaskPath { vertices: (0..2_000).map(|i| MaskVertex::corner(Vec2::new(i as f64, 0.0))).collect() };
        let poly = many.polygon();
        assert_eq!(poly.len(), MaskPath::MAX_POLYGON_POINTS);
        assert_eq!(poly[0], Vec2::new(0.0, 0.0));
        assert!(poly.windows(2).all(|w| w[0].x < w[1].x));
        assert!(MaskPath { vertices: Vec::new() }.polygon().is_empty());
    }

    #[test]
    fn make_builds_a_half_size_shape_with_the_default_feather() {
        let rect = ClipMask::make(id(1), MaskShapeKind::Rectangle, "Mask 1");
        assert_eq!((rect.feather.value, rect.opacity.value, rect.source()), (10.0, 100.0, MaskSource::Path));
        assert_eq!(rect.path.value, MaskPath::rectangle(Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.75)));
        let ellipse = ClipMask::make(id(2), MaskShapeKind::Ellipse, "Mask 2");
        assert_eq!(ellipse.kind, MaskShapeKind::Ellipse);
        assert_eq!(ellipse.path.value.vertices.len(), 4);
        assert!(ellipse.path.value.vertices[0].out_tangent != Vec2::ZERO);
    }

    #[test]
    fn sourced_masks_cover_the_whole_frame_path_and_keep_their_source() {
        let whole = MaskPath::rectangle(Vec2::ZERO, Vec2::new(1.0, 1.0));
        let subject = ClipMask::make_subject(id(1), "Subject");
        assert_eq!((subject.source(), &subject.path.value), (MaskSource::Subject, &whole));
        let magic = ClipMask::make_magic(id(2), "Magic", Vec::new());
        assert_eq!(magic.source(), MaskSource::Magic);
        assert_eq!(magic.magic.as_ref().map(|m| m.points.len()), Some(0));
        let picture = ClipMask::make_picture(id(3), "Picture", Some(id(9)));
        assert_eq!((picture.source(), picture.picture_track), (MaskSource::Picture, Some(id(9))));
        let none = ClipMask::make_picture(id(4), "Picture", None);
        assert_eq!(none.picture_track, None);
        let key = ColorRangeKey::new(0.0, 1.0, 0.0, 0.3, 0.1);
        let range = ClipMask::make_color_range(id(5), "Color Range", key);
        assert_eq!((range.source(), range.color_range()), (MaskSource::ColorRange, key));
        // Only the non-path source is written.
        let json = serde_json::to_value(&subject).unwrap_or_default();
        assert_eq!(json["source"], "subject");
        assert!(
            serde_json::to_value(ClipMask::make(id(6), MaskShapeKind::Rectangle, "m"))
                .unwrap_or_default()
                .get("source")
                .is_none()
        );
    }
}
