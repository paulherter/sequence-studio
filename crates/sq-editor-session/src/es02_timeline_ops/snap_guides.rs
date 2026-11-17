//! Smart guides of the Program monitor: while a layer is moved, its edges and center snap to the canvas center and
//! edges and to the edges and centers of the other layers. Everything is in offset space (sequence px from the canvas
//! center, y down).

use sq_core_model::{Clip, ClipTransform, Project, Timeline};
use sq_core_time::{Id, KeyframeTrack, Time, Vec2};
use sq_text::portable_text_carets::TextGeneratorBoxExt;
use sq_text::text_generator::TextGenerator;
use sq_uikit::keyframe_graph_geometry::{Rect, Size};

use super::prelude::*;

/// Snap lines per axis.
// Swift: SnapGuides.swift:12
#[derive(Clone, Debug, PartialEq)]
pub struct SnapTargets {
    // Swift: SnapGuides.swift:13
    pub xs: Vec<f64>,
    // Swift: SnapGuides.swift:14
    pub ys: Vec<f64>,
}

impl SnapTargets {
    // Swift: SnapGuides.swift:15
    pub fn new(xs: Vec<f64>, ys: Vec<f64>) -> SnapTargets {
        SnapTargets { xs, ys }
    }
}

/// What a snap found.
// Swift: SnapGuides.swift:19
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SnapResult {
    /// Correction to add to the moved layer's position.
    // Swift: SnapGuides.swift:20
    pub dx: f64,
    // Swift: SnapGuides.swift:20
    pub dy: f64,
    /// x positions of vertical guide lines to draw.
    // Swift: SnapGuides.swift:22
    pub vertical_lines: Vec<f64>,
    /// y positions of horizontal guide lines to draw.
    // Swift: SnapGuides.swift:23
    pub horizontal_lines: Vec<f64>,
}

impl SnapResult {
    /// No correction, no guide.
    // Swift: SnapGuides.swift:24
    pub fn none() -> SnapResult {
        SnapResult::default()
    }

    /// Shift axis lock: no correction (and no guide) on a locked axis.
    // Swift: SnapGuides.swift:27
    pub fn locking(&self, x: bool, y: bool) -> SnapResult {
        SnapResult {
            dx: if x { 0.0 } else { self.dx },
            dy: if y { 0.0 } else { self.dy },
            vertical_lines: if x { Vec::new() } else { self.vertical_lines.clone() },
            horizontal_lines: if y { Vec::new() } else { self.horizontal_lines.clone() },
        }
    }
}

/// Namespace of the snapping rules.
pub enum SnapGuides {}

impl SnapGuides {
    /// Canvas lines, the edges of the given safe areas, plus min / mid / max of every other layer's bounds.
    // Swift: SnapGuides.swift:33
    pub fn targets(canvas: Size, others: &[Rect], safe_areas: &[SafeArea], zone: Option<Rect>) -> SnapTargets {
        let mut xs = vec![-canvas.width / 2.0, 0.0, canvas.width / 2.0];
        let mut ys = vec![-canvas.height / 2.0, 0.0, canvas.height / 2.0];
        for a in safe_areas {
            let r = a.rect(canvas);
            xs.extend([r.min_x(), r.max_x()]);
            ys.extend([r.min_y(), r.max_y()]);
        }
        if let Some(z) = zone {
            // Platform UI zone (offset space): content snaps onto its edges.
            xs.extend([z.min_x(), z.max_x()]);
            ys.extend([z.min_y(), z.max_y()]);
        }
        for r in others.iter().filter(|r| r.width > 0.0 && r.height > 0.0) {
            xs.extend([r.min_x(), r.mid_x(), r.max_x()]);
            ys.extend([r.min_y(), r.mid_y(), r.max_y()]);
        }
        SnapTargets { xs, ys }
    }

    /// Bounds of the other layers to snap to. A graphics clip's overlay box is its canvas-sized group: at identity it only
    /// repeats the canvas lines, and once moved or scaled its edges are empty space, so it never becomes a snap target.
    // Swift: SnapGuides.swift:54
    pub fn other_bounds(others: &[OverlayTarget]) -> Vec<Rect> {
        others.iter().filter(|o| !o.is_graphics).map(|o| LayerBounds::rect(o.size, &o.display_transform())).collect()
    }

    /// Snaps the bounds `box_` of the moving layer. The nearest (feature, target) pair within `threshold` wins per axis.
    // Swift: SnapGuides.swift:59
    pub fn snap_box(box_: Rect, targets: &SnapTargets, threshold: f64) -> SnapResult {
        let (dx, vx) = axis(&[box_.min_x(), box_.mid_x(), box_.max_x()], &targets.xs, threshold);
        let (dy, hy) = axis(&[box_.min_y(), box_.mid_y(), box_.max_y()], &targets.ys, threshold);
        SnapResult { dx, dy, vertical_lines: vx, horizontal_lines: hy }
    }

    /// Snaps a single point (point-parameter handles).
    // Swift: SnapGuides.swift:66
    pub fn snap_point(point: Vec2, targets: &SnapTargets, threshold: f64) -> SnapResult {
        Self::snap_box(Rect::new(point.x, point.y, 0.0, 0.0), targets, threshold)
    }
}

fn axis(features: &[f64], targets: &[f64], threshold: f64) -> (f64, Vec<f64>) {
    let mut best: Option<f64> = None;
    for f in features {
        for t in targets {
            let d = t - f;
            if d.abs() <= threshold && d.abs() < best.map_or(f64::INFINITY, f64::abs) {
                best = Some(d);
            }
        }
    }
    let Some(d) = best else { return (0.0, Vec::new()) };
    // Every target that one of the shifted features now sits on gets a guide line.
    let mut lines: Vec<f64> = Vec::new();
    for t in targets {
        if features.iter().any(|f| (f + d - t).abs() < 1e-6) && !lines.iter().any(|l| (l - t).abs() < 1e-6) {
            lines.push(*t);
        }
    }
    lines.sort_by(f64::total_cmp);
    (d, lines)
}

/// Title / action safe margins (Premiere: action 90 %, title 80 % of the frame), centered on the canvas.
// Swift: SnapGuides.swift:89
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SafeArea {
    Action,
    Title,
}

impl SafeArea {
    /// Both areas, in Swift's declaration order.
    pub const ALL: [SafeArea; 2] = [SafeArea::Action, SafeArea::Title];

    // Swift: SnapGuides.swift:91
    pub fn fraction(self) -> f64 {
        if self == SafeArea::Action { 0.9 } else { 0.8 }
    }

    /// In offset space (centered on the origin).
    // Swift: SnapGuides.swift:93
    pub fn rect(self, canvas: Size) -> Rect {
        let (w, h) = (canvas.width * self.fraction(), canvas.height * self.fraction());
        Rect::new(-w / 2.0, -h / 2.0, w, h)
    }
}

/// Bounding box of a layer in offset space, for snapping.
pub enum LayerBounds {}

impl LayerBounds {
    /// `size` = the layer at scale 1 (native px); `offset = position + R(rotation) * S(scale) * (local - anchor)`.
    // Swift: SnapGuides.swift:103
    pub fn rect(size: Size, t: &ClipTransform) -> Rect {
        let (hw, hh) = (size.width / 2.0, size.height / 2.0);
        let a = t.rotation * std::f64::consts::PI / 180.0;
        let (s, c) = a.sin_cos();
        let (mut min_x, mut min_y, mut max_x, mut max_y) =
            (f64::INFINITY, f64::INFINITY, -f64::INFINITY, -f64::INFINITY);
        for (lx, ly) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)] {
            let (dx, dy) = ((lx - t.anchor.x) * t.scale.x, (ly - t.anchor.y) * t.scale.y);
            let x = t.position.x + dx * c - dy * s;
            let y = t.position.y + dx * s + dy * c;
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
        }
        Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

/// What the Program monitor's transform overlay manipulates: one picture, text or graphics clip at the playhead.
/// `display_transform` is what the overlay draws; edits come back through `base_transform_from_display`.
// Swift: SnapGuides.swift:117
#[derive(Clone, Debug, PartialEq)]
pub struct OverlayTarget {
    // Swift: SnapGuides.swift:120
    pub clip: Id,
    /// The layer at scale 1 in sequence px: native picture size (100 % = source pixels) or the text raster.
    // Swift: SnapGuides.swift:123
    pub size: Size,
    // Swift: SnapGuides.swift:124
    pub is_text: bool,
    /// Transform as stored in the clip (evaluated at the playhead).
    // Swift: SnapGuides.swift:126
    pub base_transform: ClipTransform,
    /// Text: its raster center relative to the canvas center (the clip's Position is added on top); zero for pictures.
    // Swift: SnapGuides.swift:128
    pub shift: Vec2,
    // Swift: SnapGuides.swift:129
    pub position_track: KeyframeTrack<Vec2>,
    /// Text in/out animation factors at the playhead, folded into the drawn transform like the renderer does.
    // Swift: SnapGuides.swift:131
    pub anim_scale: f64,
    // Swift: SnapGuides.swift:132
    pub anim_rotation: f64,
    /// A graphics clip: `size` is its canvas-sized group, not visible content.
    // Swift: SnapGuides.swift:134
    pub is_graphics: bool,
    /// The clip's Group Transform effects at the playhead, in list order. They act after everything else.
    // Swift: SnapGuides.swift:137
    pub group_stages: Vec<ClipTransform>,
}

impl OverlayTarget {
    // Swift: SnapGuides.swift:138
    pub fn new(
        clip: Id,
        size: Size,
        is_text: bool,
        base_transform: ClipTransform,
        shift: Vec2,
        position_track: KeyframeTrack<Vec2>,
    ) -> OverlayTarget {
        OverlayTarget {
            clip,
            size,
            is_text,
            base_transform,
            shift,
            position_track,
            anim_scale: 1.0,
            anim_rotation: 0.0,
            is_graphics: false,
            group_stages: Vec::new(),
        }
    }

    // Swift: SnapGuides.swift:146
    pub fn display_transform(&self) -> ClipTransform {
        let mut t = self.base_transform;
        t.position = Vec2::new(t.position.x + self.shift.x, t.position.y + self.shift.y);
        t.scale = Vec2::new(t.scale.x * self.anim_scale, t.scale.y * self.anim_scale);
        t.rotation += self.anim_rotation;
        for g in &self.group_stages {
            t = g.composed(&t);
        }
        t
    }

    /// Stored transform for a transform edited in the overlay (inverse of `display_transform`).
    // Swift: SnapGuides.swift:157
    pub fn base_transform_from_display(&self, t: &ClipTransform) -> ClipTransform {
        let mut b = t.removing_group_stages(&self.group_stages);
        b.position = Vec2::new(b.position.x - self.shift.x, b.position.y - self.shift.y);
        let k = if self.anim_scale.abs() > 1e-9 { self.anim_scale } else { 1.0 };
        b.scale = Vec2::new(b.scale.x / k, b.scale.y / k);
        b.rotation -= self.anim_rotation;
        b
    }

    /// `None` when the clip is not a picture/text clip or is not under `time`. A picture clip of unknown size is treated
    /// as filling the sequence. `variant`: the format variant `timeline` shows.
    // Swift: SnapGuides.swift:169
    pub fn make(
        clip: &Clip,
        project: &Project,
        timeline: &Timeline,
        time: Time,
        variant: Option<Id>,
    ) -> Option<OverlayTarget> {
        if clip.kind == sq_core_model::TrackKind::Audio || !clip.timeline().contains(time) {
            return None;
        }
        let base = clip.transform(time);
        let canvas = Size::new(timeline.format.display_width() as f64, timeline.format.height as f64);
        let none_track = KeyframeTrack::<Vec2>::default;
        if clip.is_graphics() {
            // The overlay manipulates the canvas-sized group that carries the clip's Motion (layer handles belong to
            // the Graphics overlay).
            let mut target = OverlayTarget::new(
                clip.id,
                canvas,
                false,
                base,
                Vec2::new(0.0, 0.0),
                clip.animation.position.track.clone(),
            );
            target.group_stages = clip.group_stage_transforms(time);
            if !target.group_stages.is_empty() {
                target.position_track = none_track();
            }
            target.is_graphics = true;
            return Some(target);
        }
        if let Some(r) = &clip.generator {
            if r.kind != TextGenerator::KIND {
                return project_picture(clip, project, variant, canvas, base, time);
            }
            let (template, _) = TextGenerator::decode(r).ok()?;
            // The portable layout gives the box the portable raster draws, without drawing it.
            let local = time - clip.start;
            let Some(f) = TextGenerator::portable_box(r, local, clip.source.duration, &timeline.format).ok().flatten()
            else {
                // Empty text renders nothing: a small box at the position so the caret has somewhere to sit.
                return Some(OverlayTarget::new(
                    clip.id,
                    Size::new(24.0, template.style.size * 1.2),
                    true,
                    base,
                    Vec2::new(0.0, 0.0),
                    none_track(),
                ));
            };
            let shift = Vec2::new(
                f.x + f.width / 2.0 - timeline.format.display_width() as f64 / 2.0 + f.offset_x,
                f.y + f.height / 2.0 - timeline.format.height as f64 / 2.0 + f.offset_y,
            );
            let mut target = OverlayTarget::new(clip.id, Size::new(f.width, f.height), true, base, shift, none_track());
            target.anim_scale = f.scale;
            target.anim_rotation = f.rotation;
            target.group_stages = clip.group_stage_transforms(time);
            return Some(target); // no motion path for text (keys are not shifted)
        }
        project_picture(clip, project, variant, canvas, base, time)
    }
}

fn project_picture(
    clip: &Clip,
    project: &Project,
    variant: Option<Id>,
    canvas: Size,
    base: ClipTransform,
    time: Time,
) -> Option<OverlayTarget> {
    let size = project.picture_size_in(clip, variant).map_or(canvas, |(w, h)| Size::new(w as f64, h as f64));
    let mut target =
        OverlayTarget::new(clip.id, size, false, base, Vec2::new(0.0, 0.0), clip.animation.position.track.clone());
    target.group_stages = clip.group_stage_transforms(time);
    // The motion path is in Motion's space: with a group stage on top it would not sit on the picture.
    if !target.group_stages.is_empty() {
        target.position_track = KeyframeTrack::default();
    }
    Some(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t() -> SnapTargets {
        SnapGuides::targets(Size::new(1920.0, 1080.0), &[], &[], None)
    }

    #[test]
    fn canvas_lines_are_targets() {
        let x = t();
        assert_eq!(x.xs, vec![-960.0, 0.0, 960.0]);
        assert_eq!(x.ys, vec![-540.0, 0.0, 540.0]);
    }

    #[test]
    fn box_center_snaps_within_threshold() {
        let r = SnapGuides::snap_box(Rect::new(-97.0, -48.0, 200.0, 100.0), &t(), 6.0);
        assert_eq!((r.dx, r.dy), (-3.0, -2.0));
        assert_eq!(r.vertical_lines, vec![0.0]);
        assert_eq!(r.horizontal_lines, vec![0.0]);
        assert_eq!(SnapGuides::snap_box(Rect::new(-97.0, -48.0, 200.0, 100.0), &t(), 1.0), SnapResult::none());
    }

    #[test]
    fn locking_an_axis_drops_its_correction_and_lines() {
        let r = SnapGuides::snap_box(Rect::new(-97.0, -48.0, 200.0, 100.0), &t(), 6.0).locking(true, false);
        assert_eq!((r.dx, r.dy), (0.0, -2.0));
        assert!(r.vertical_lines.is_empty());
    }

    #[test]
    fn safe_areas_add_their_edges() {
        let x = SnapGuides::targets(Size::new(1000.0, 500.0), &[], &SafeArea::ALL, None);
        assert!(x.xs.contains(&-450.0) && x.xs.contains(&400.0) && x.ys.contains(&-200.0));
    }

    #[test]
    fn rotated_layer_bounds_grow() {
        let mut tr = ClipTransform::IDENTITY;
        tr.rotation = 90.0;
        let r = LayerBounds::rect(Size::new(200.0, 100.0), &tr);
        assert!((r.width - 100.0).abs() < 1e-9 && (r.height - 200.0).abs() < 1e-9);
    }

    #[test]
    fn display_and_base_transform_are_inverse() {
        let mut target = OverlayTarget::new(
            Id::from_u128(1),
            Size::new(10.0, 10.0),
            true,
            ClipTransform::IDENTITY,
            Vec2::new(5.0, -3.0),
            KeyframeTrack::default(),
        );
        target.anim_scale = 2.0;
        target.anim_rotation = 10.0;
        let shown = target.display_transform();
        assert_eq!(target.base_transform_from_display(&shown), target.base_transform);
    }
}
