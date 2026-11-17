// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ShapeGenerator.swift (ShapeKind helpers, GeneratorRef.shape, ShapeStyle), Graphics.swift (factories, shapeStyle,
// generatorRef, graphicsLayerClip, editGraphics), Graphics+Editing.swift (GraphicsDocument.add)

use crate::{
    AnimatedProperty, Clip, ClipAnimation, ClipEffect, EditError, EffectColor, GeneratorRef, GraphicsContent,
    GraphicsDocument, GraphicsLayer, Project, ShapeKind, TrackKind,
};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, IdSource, Time, Vec2};

impl ShapeKind {
    /// Every outline, in declaration order.
    pub const ALL: [ShapeKind; 4] = [ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line, ShapeKind::Arrow];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            ShapeKind::Rectangle => "Rectangle",
            ShapeKind::Ellipse => "Ellipse",
            ShapeKind::Line => "Line",
            ShapeKind::Arrow => "Arrow",
        }
    }
}

/// Payload of a `GeneratorRef::SHAPE` clip (payload version 1). Only the outline lives here; every look value is a
/// keyframable parameter of the clip's Shape effect.
#[derive(Serialize, Deserialize)]
struct ShapePayload {
    shape: ShapeKind,
}

impl GeneratorRef {
    /// A vector shape layer (W5.2). The payload is the JSON `{"shape": ...}`.
    pub const SHAPE: &'static str = "shape";

    /// The generator of a shape clip.
    pub fn shape(kind: ShapeKind) -> GeneratorRef {
        GeneratorRef {
            kind: Self::SHAPE.to_string(),
            payload: serde_json::to_vec(&ShapePayload { shape: kind }).unwrap_or_default(),
            payload_version: 1,
        }
    }

    /// The outline of a shape generator, `None` for other generators. An unreadable payload falls back to a rectangle.
    pub fn shape_kind(&self) -> Option<ShapeKind> {
        (self.kind == Self::SHAPE)
            .then(|| serde_json::from_slice::<ShapePayload>(&self.payload).map_or(ShapeKind::Rectangle, |p| p.shape))
    }
}

/// A shape at one instant, clamped, in sequence px of the clip's own frame. What the shape renderer draws.
#[derive(Clone, Debug, PartialEq)]
pub struct ShapeStyle {
    /// Outline.
    pub kind: ShapeKind,
    /// Outline size. A line uses `width` as its length; `height` is ignored.
    pub width: f64,
    /// Outline height.
    pub height: f64,
    /// Rectangles only, at most half the shorter side.
    pub corner_radius: f64,
    /// Display-encoded (BT.709 OETF) 0...1 RGBA; `None` = no fill. Never set for a line.
    pub fill: Option<EffectColor>,
    /// `None` = no stroke. A line without a stroke draws nothing.
    pub stroke: Option<EffectColor>,
    /// Stroke width.
    pub stroke_width: f64,
    /// GFX freeform path: points in 0...1 of the `width` x `height` outline box (x right, y down), drawn instead of `kind`'s
    /// outline. Filled only when closed (the caller then sets `fill`). `None` for the built-in outlines.
    pub path: Option<Vec<Vec2>>,
    /// The path is closed.
    pub path_closed: bool,
    /// Gradient fill: `fill` is the start color, this the end; `None` = solid fill. Needs a `fill`.
    pub gradient_end: Option<EffectColor>,
    /// Direction of the gradient in degrees, 0 = left to right, 90 = top to bottom.
    pub gradient_angle: f64,
}

impl ShapeStyle {
    /// A style with no fill, stroke, path or gradient.
    pub fn new(kind: ShapeKind, width: f64, height: f64) -> ShapeStyle {
        ShapeStyle {
            kind,
            width,
            height,
            corner_radius: 0.0,
            fill: None,
            stroke: None,
            stroke_width: 0.0,
            path: None,
            path_closed: false,
            gradient_end: None,
            gradient_angle: 90.0,
        }
    }

    /// The style of `kind` drawn by Shape effect `effect` (catalog defaults when `None`) at effect-local `t`; `None` when it
    /// is off.
    pub fn evaluate(kind: ShapeKind, effect: Option<&ClipEffect>, t: Time) -> Option<ShapeStyle> {
        let fallback;
        let e = match effect {
            Some(e) => e,
            None => {
                fallback = ClipEffect::new(Id::NIL, ClipEffect::SHAPE_EFFECT_KIND);
                &fallback
            }
        };
        if !e.enabled {
            return None;
        }
        let (w, h) = (e.scalar(ClipEffect::SHAPE_WIDTH_KEY, t), e.scalar(ClipEffect::SHAPE_HEIGHT_KEY, t));
        let stroke = e.flag(ClipEffect::SHAPE_STROKE_KEY, t).then(|| e.color(ClipEffect::SHAPE_STROKE_COLOR_KEY, t));
        let fill = (kind != ShapeKind::Line && e.flag(ClipEffect::SHAPE_FILL_KEY, t))
            .then(|| e.color(ClipEffect::SHAPE_FILL_COLOR_KEY, t));
        let radius = if kind == ShapeKind::Rectangle {
            e.scalar(ClipEffect::SHAPE_CORNER_RADIUS_KEY, t).min(w.min(h) / 2.0)
        } else {
            0.0
        };
        let gradient = fill.is_some() && e.flag(ClipEffect::SHAPE_GRADIENT_KEY, t);
        Some(ShapeStyle {
            corner_radius: radius.max(0.0),
            fill,
            stroke,
            stroke_width: e.scalar(ClipEffect::SHAPE_STROKE_WIDTH_KEY, t),
            gradient_end: gradient.then(|| e.color(ClipEffect::SHAPE_GRADIENT_COLOR_KEY, t)),
            gradient_angle: if gradient { e.scalar(ClipEffect::SHAPE_GRADIENT_ANGLE_KEY, t) } else { 90.0 },
            ..ShapeStyle::new(kind, w, h)
        })
    }

    /// Size of the drawn picture (width, height): the outline plus the half of the stroke that lies outside it. A line is
    /// `width` x `stroke_width`.
    pub fn raster_size(&self) -> (f64, f64) {
        if self.kind == ShapeKind::Line {
            return (self.width, if self.stroke.is_none() { 0.0 } else { self.stroke_width });
        }
        let out = if self.stroke.is_none() { 0.0 } else { self.stroke_width };
        (self.width + out, self.height + out)
    }

    /// The arrow outline (N3) as 7 points in box coordinates (x right, y down, origin top-left of the `width` x `height`
    /// outline box). It points right: a shaft 40 % of the height thick, a head as high as the box and 90 % of the height
    /// long (at most 60 % of the width).
    pub fn arrow_points(&self) -> [Vec2; 7] {
        let (w, h) = (self.width, self.height);
        let head = (h * 0.9).min(w * 0.6);
        let shaft = h * 0.4;
        let y0 = (h - shaft) / 2.0;
        let y1 = y0 + shaft;
        let neck = w - head;
        [
            Vec2::new(0.0, y0),
            Vec2::new(neck, y0),
            Vec2::new(neck, 0.0),
            Vec2::new(w, h / 2.0),
            Vec2::new(neck, h),
            Vec2::new(neck, y1),
            Vec2::new(0.0, y1),
        ]
    }

    /// Nothing visible: no fill and no stroke, or no area.
    pub fn is_empty(&self) -> bool {
        let (w, h) = self.raster_size();
        w <= 0.0 || h <= 0.0 || (self.fill.is_none() && self.stroke.is_none())
    }
}

impl Clip {
    /// The shape this clip draws at clip-local `t`; `None` when it is not a shape generator or its Shape effect is switched
    /// off (fx toggle). A shape clip whose Shape effect was removed draws the catalog defaults.
    pub fn shape_style(&self, t: Time) -> Option<ShapeStyle> {
        let kind = self.generator.as_ref()?.shape_kind()?;
        ShapeStyle::evaluate(kind, self.effect_of_kind(ClipEffect::SHAPE_EFFECT_KIND), t)
    }

    /// Layer `l` as a clip with this clip's timing, so clip evaluation (Motion, effects, Shape) applies to it unchanged.
    pub fn graphics_layer_clip(&self, l: &GraphicsLayer) -> Clip {
        let mut c = Clip::new(l.id, &l.name, l.id, TrackKind::Video, self.source, self.start);
        c.animation = l.animation.clone();
        c.generator = Some(l.generator_ref());
        c.effects = l.effects.clone();
        c.blend_mode = l.blend_mode;
        c
    }
}

impl Project {
    /// The Shape effect a new `kind` starts with on a `width` x `height` canvas: a rectangle covering half of each side, a
    /// circle half the shorter side across, a line half the width long with its stroke on.
    pub fn default_shape_effect(
        ids: &mut dyn IdSource,
        kind: ShapeKind,
        canvas_width: i64,
        canvas_height: i64,
    ) -> ClipEffect {
        let mut e = ClipEffect::make(ids.next_id(), ClipEffect::SHAPE_EFFECT_KIND).unwrap_or_else(|| {
            // Unreachable while the catalog lists the Shape effect; an empty one keeps the call total.
            ClipEffect::new(Id::NIL, ClipEffect::SHAPE_EFFECT_KIND)
        });
        let (w, h) = (canvas_width as f64 / 2.0, canvas_height as f64 / 2.0);
        let mut set = |key: &str, v: f64| {
            e.parameters.insert(key.to_string(), AnimatedProperty::new(v));
        };
        match kind {
            ShapeKind::Rectangle => {
                set(ClipEffect::SHAPE_WIDTH_KEY, w);
                set(ClipEffect::SHAPE_HEIGHT_KEY, h);
            }
            ShapeKind::Ellipse => {
                set(ClipEffect::SHAPE_WIDTH_KEY, w.min(h));
                set(ClipEffect::SHAPE_HEIGHT_KEY, w.min(h));
            }
            ShapeKind::Arrow => {
                set(ClipEffect::SHAPE_WIDTH_KEY, w / 2.0);
                set(ClipEffect::SHAPE_HEIGHT_KEY, h / 3.0);
                e.colors.insert(
                    ClipEffect::SHAPE_FILL_COLOR_KEY.to_string(),
                    AnimatedProperty::new(EffectColor { red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0 }),
                );
            }
            ShapeKind::Line => {
                set(ClipEffect::SHAPE_WIDTH_KEY, w);
                set(ClipEffect::SHAPE_STROKE_KEY, 1.0);
                e.colors
                    .insert(ClipEffect::SHAPE_STROKE_COLOR_KEY.to_string(), AnimatedProperty::new(EffectColor::WHITE));
            }
        }
        e
    }

    /// Edits the layers of graphics clip `clip_id` in one mutation (one undo step). `ClipNotFound` for an unknown clip or one
    /// that is not a graphics clip, `TrackLocked` on a locked track.
    pub fn edit_graphics<R>(
        &mut self,
        clip_id: Id,
        body: impl FnOnce(&mut GraphicsDocument) -> Result<R, EditError>,
    ) -> Result<R, EditError> {
        for track in self.timelines.iter_mut().flat_map(|t| t.tracks.iter_mut()) {
            let Some(mut c) = track.clip(clip_id).cloned() else { continue };
            if !c.is_graphics() {
                return Err(EditError::ClipNotFound);
            }
            if track.is_locked {
                return Err(EditError::TrackLocked);
            }
            let mut doc = c.graphics().cloned().unwrap_or_default();
            let r = body(&mut doc)?;
            c.set_graphics(Some(doc));
            track.replace(c);
            return Ok(r);
        }
        Err(EditError::ClipNotFound)
    }
}

impl GraphicsLayer {
    /// A shape layer sized for a `canvas_width` x `canvas_height` graphic (same defaults as a shape clip).
    pub fn shape(ids: &mut dyn IdSource, kind: ShapeKind, canvas_width: i64, canvas_height: i64) -> GraphicsLayer {
        let mut layer = GraphicsLayer::new(ids.next_id(), kind.title(), GraphicsContent::Shape { kind });
        layer.effects = vec![Project::default_shape_effect(ids, kind, canvas_width, canvas_height)];
        layer
    }

    /// A freeform layer from points in canvas px (offset from the canvas center, y down), e.g. a free drawing stroke. The
    /// layer is placed at the points' bounding-box center; the box becomes the Shape effect's Width x Height. Open paths are
    /// stroked in `color`; closed ones are filled with it.
    pub fn path(
        ids: &mut dyn IdSource,
        canvas_points: &[Vec2],
        closed: bool,
        color: EffectColor,
        stroke_width: f64,
    ) -> GraphicsLayer {
        let fold =
            |f: fn(f64, f64) -> f64, init: f64, pick: fn(&Vec2) -> f64| canvas_points.iter().map(pick).fold(init, f);
        let (min_x, max_x) = if canvas_points.is_empty() {
            (0.0, 0.0)
        } else {
            (fold(f64::min, f64::INFINITY, |p| p.x), fold(f64::max, f64::NEG_INFINITY, |p| p.x))
        };
        let (min_y, max_y) = if canvas_points.is_empty() {
            (0.0, 0.0)
        } else {
            (fold(f64::min, f64::INFINITY, |p| p.y), fold(f64::max, f64::NEG_INFINITY, |p| p.y))
        };
        let (w, h) = ((max_x - min_x).max(1.0), (max_y - min_y).max(1.0));
        let points = canvas_points.iter().map(|p| Vec2::new((p.x - min_x) / w, (p.y - min_y) / h)).collect();
        let mut e = ClipEffect::make(ids.next_id(), ClipEffect::SHAPE_EFFECT_KIND)
            .unwrap_or_else(|| ClipEffect::new(Id::NIL, ClipEffect::SHAPE_EFFECT_KIND));
        let flag = |on: bool| AnimatedProperty::new(if on { 1.0 } else { 0.0 });
        e.parameters.insert(ClipEffect::SHAPE_WIDTH_KEY.to_string(), AnimatedProperty::new(w));
        e.parameters.insert(ClipEffect::SHAPE_HEIGHT_KEY.to_string(), AnimatedProperty::new(h));
        e.parameters.insert(ClipEffect::SHAPE_FILL_KEY.to_string(), flag(closed));
        e.colors.insert(ClipEffect::SHAPE_FILL_COLOR_KEY.to_string(), AnimatedProperty::new(color));
        e.parameters.insert(ClipEffect::SHAPE_STROKE_KEY.to_string(), flag(!closed));
        e.colors.insert(ClipEffect::SHAPE_STROKE_COLOR_KEY.to_string(), AnimatedProperty::new(color));
        e.parameters.insert(ClipEffect::SHAPE_STROKE_WIDTH_KEY.to_string(), AnimatedProperty::new(stroke_width));
        let animation = ClipAnimation {
            position: AnimatedProperty::new(Vec2::new((min_x + max_x) / 2.0, (min_y + max_y) / 2.0)),
            ..ClipAnimation::default()
        };
        let mut layer = GraphicsLayer::new(
            ids.next_id(),
            if closed { "Shape" } else { "Drawing" },
            GraphicsContent::Path { points, closed },
        );
        layer.animation = animation;
        layer.effects = vec![e];
        layer
    }

    /// The shape this layer draws at clip-local `t`; `None` for text or a switched-off Shape effect.
    pub fn shape_style(&self, t: Time) -> Option<ShapeStyle> {
        match &self.content {
            GraphicsContent::Shape { kind } => ShapeStyle::evaluate(*kind, self.shape_effect(), t),
            GraphicsContent::Path { points, closed } => {
                let mut s = ShapeStyle::evaluate(ShapeKind::Rectangle, self.shape_effect(), t)?;
                s.corner_radius = 0.0;
                s.path = Some(points.clone());
                s.path_closed = *closed;
                if !*closed {
                    s.fill = None;
                }
                Some(s)
            }
            GraphicsContent::Text { .. } => None,
        }
    }

    /// The generator a request of this layer carries (what the renderers dispatch on).
    pub fn generator_ref(&self) -> GeneratorRef {
        match &self.content {
            GraphicsContent::Shape { kind } => GeneratorRef::shape(*kind),
            GraphicsContent::Path { .. } => GeneratorRef::shape(ShapeKind::Rectangle),
            GraphicsContent::Text { generator } => generator.clone(),
        }
    }
}

impl GraphicsDocument {
    /// Adds `layer` on top (or right above `above`). Returns its id.
    pub fn add(&mut self, layer: GraphicsLayer, above: Option<Id>) -> Id {
        let id = layer.id;
        match above.and_then(|a| self.index_of(a)) {
            Some(i) => self.layers.insert(i + 1, layer),
            None => self.layers.push(layer),
        }
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EffectCatalog, Timeline, Track};
    use sq_core_time::SequentialIds;

    fn style(kind: ShapeKind) -> ShapeStyle {
        let mut ids = SequentialIds::default();
        let e = Project::default_shape_effect(&mut ids, kind, 1920, 1080);
        ShapeStyle::evaluate(kind, Some(&e), Time::ZERO).unwrap_or_else(|| ShapeStyle::new(kind, -1.0, -1.0))
    }

    #[test]
    fn a_new_rectangle_covers_half_of_each_side_with_fill_and_no_stroke() {
        let s = style(ShapeKind::Rectangle);
        assert_eq!((s.width, s.height, s.corner_radius), (960.0, 540.0, 0.0));
        assert!(s.fill.is_some() && s.stroke.is_none());
    }

    #[test]
    fn an_ellipse_is_a_circle_and_a_line_is_a_stroke() {
        let e = style(ShapeKind::Ellipse);
        assert_eq!((e.width, e.height), (540.0, 540.0));
        let l = style(ShapeKind::Line);
        assert_eq!((l.kind, l.width), (ShapeKind::Line, 960.0));
        assert!(l.stroke.is_some() && l.fill.is_none() && l.stroke_width > 0.0);
        assert_eq!(l.raster_size().1, l.stroke_width);
        let a = style(ShapeKind::Arrow);
        assert_eq!((a.width, a.height), (480.0, 180.0));
    }

    #[test]
    fn the_arrow_outline_points_right() {
        let mut s = ShapeStyle::new(ShapeKind::Arrow, 200.0, 100.0);
        s.fill = Some(EffectColor::WHITE);
        let pts = s.arrow_points();
        assert_eq!(pts[3], Vec2::new(200.0, 50.0), "the tip sits on the right edge, half way down");
        assert_eq!((pts[0].y, pts[6].y), (30.0, 70.0), "the shaft is 40 % of the height");
        assert!(!s.is_empty() && s.raster_size().0 == 200.0);
        let narrow = ShapeStyle::new(ShapeKind::Arrow, 50.0, 100.0).arrow_points();
        assert_eq!(narrow[1].x, 20.0, "the head takes at most 60 % of the width");
    }

    #[test]
    fn the_corner_radius_is_kept_inside_half_the_shorter_side() {
        let mut ids = SequentialIds::default();
        let mut e = Project::default_shape_effect(&mut ids, ShapeKind::Rectangle, 400, 200);
        e.parameters.insert(ClipEffect::SHAPE_CORNER_RADIUS_KEY.into(), AnimatedProperty::new(500.0));
        let s = ShapeStyle::evaluate(ShapeKind::Rectangle, Some(&e), Time::ZERO);
        assert_eq!(s.map(|s| (s.width, s.height, s.corner_radius)), Some((200.0, 100.0, 50.0)));
        e.enabled = false;
        assert!(ShapeStyle::evaluate(ShapeKind::Rectangle, Some(&e), Time::ZERO).is_none());
    }

    #[test]
    fn a_stroke_is_centered_on_the_outline() {
        let mut ids = SequentialIds::default();
        let mut e = Project::default_shape_effect(&mut ids, ShapeKind::Rectangle, 400, 200);
        e.parameters.insert(ClipEffect::SHAPE_STROKE_KEY.into(), AnimatedProperty::new(1.0));
        e.parameters.insert(ClipEffect::SHAPE_STROKE_WIDTH_KEY.into(), AnimatedProperty::new(6.0));
        let s = ShapeStyle::evaluate(ShapeKind::Rectangle, Some(&e), Time::ZERO);
        assert_eq!(s.map(|s| s.raster_size()), Some((206.0, 106.0)));
    }

    #[test]
    fn a_shape_clip_without_its_effect_draws_the_catalog_defaults() {
        let mut c = Clip::new(
            Id::from_u128(1),
            "s",
            Id::from_u128(2),
            TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, Time::new(5, 1)),
            Time::ZERO,
        );
        assert!(c.shape_style(Time::ZERO).is_none(), "not a shape generator");
        c.generator = Some(GeneratorRef::shape(ShapeKind::Ellipse));
        assert_eq!(
            c.shape_style(Time::ZERO).map(|s| (s.kind, s.width, s.height)),
            Some((ShapeKind::Ellipse, 400.0, 300.0))
        );
        let mut off = ClipEffect::new(Id::from_u128(3), ClipEffect::SHAPE_EFFECT_KIND);
        off.enabled = false;
        c.effects.push(off);
        assert!(c.shape_style(Time::ZERO).is_none(), "the fx toggle switches the shape off");
    }

    #[test]
    fn the_shape_generator_round_trips_its_outline() {
        for kind in ShapeKind::ALL {
            assert_eq!(GeneratorRef::shape(kind).shape_kind(), Some(kind));
        }
        assert_eq!(GeneratorRef::shape(ShapeKind::Line).payload, br#"{"shape":"line"}"#);
        let broken = GeneratorRef { payload: b"nope".to_vec(), ..GeneratorRef::shape(ShapeKind::Line) };
        assert_eq!(broken.shape_kind(), Some(ShapeKind::Rectangle));
        assert_eq!(GeneratorRef::graphics_clip().shape_kind(), None);
        assert!(EffectCatalog::is_generator_owned(ClipEffect::SHAPE_EFFECT_KIND));
        assert_eq!(EffectCatalog::owning_generator(ClipEffect::SHAPE_EFFECT_KIND), Some(GeneratorRef::SHAPE));
        assert!(EffectCatalog::all().iter().all(|s| !EffectCatalog::is_generator_owned(&s.kind)));
        assert_eq!(EffectCatalog::owning_generator(ClipEffect::GAUSSIAN_BLUR_KIND), None);
    }

    #[test]
    fn a_path_layer_is_placed_at_the_center_of_its_points() {
        let mut ids = SequentialIds::default();
        let pts = [Vec2::new(-100.0, 50.0), Vec2::new(100.0, 150.0), Vec2::new(0.0, 100.0)];
        let layer = GraphicsLayer::path(&mut ids, &pts, false, EffectColor::WHITE, 4.0);
        assert_eq!(layer.name, "Drawing");
        assert_eq!(layer.animation.position.value, Vec2::new(0.0, 100.0));
        let GraphicsContent::Path { points, closed } = &layer.content else { panic!("path") };
        assert!(!closed);
        assert_eq!(points, &vec![Vec2::new(0.0, 0.0), Vec2::new(1.0, 1.0), Vec2::new(0.5, 0.5)]);
        let s = layer.shape_style(Time::ZERO);
        assert_eq!(s.as_ref().map(|s| (s.width, s.height, s.stroke_width)), Some((200.0, 100.0, 4.0)));
        assert!(s.is_some_and(|s| s.fill.is_none() && s.stroke.is_some() && !s.path_closed));
        let closed = GraphicsLayer::path(&mut ids, &pts, true, EffectColor::WHITE, 4.0);
        assert_eq!(closed.name, "Shape");
        assert!(
            closed.shape_style(Time::ZERO).is_some_and(|s| s.fill.is_some() && s.stroke.is_none() && s.path_closed)
        );
        // No points: a 1 x 1 box at the origin rather than a division by zero.
        assert_eq!(
            GraphicsLayer::path(&mut ids, &[], false, EffectColor::WHITE, 1.0).animation.position.value,
            Vec2::ZERO
        );
    }

    #[test]
    fn shape_layers_carry_the_canvas_sized_effect_and_the_request_generator() {
        let mut ids = SequentialIds::default();
        let layer = GraphicsLayer::shape(&mut ids, ShapeKind::Ellipse, 1920, 1080);
        assert_eq!(layer.name, "Ellipse");
        assert_eq!(layer.shape_style(Time::ZERO).map(|s| (s.width, s.height)), Some((540.0, 540.0)));
        assert_eq!(layer.generator_ref(), GeneratorRef::shape(ShapeKind::Ellipse));
        let text = GraphicsLayer::text(Id::from_u128(9), GeneratorRef::graphics_clip(), "Text");
        assert!(text.shape_style(Time::ZERO).is_none());
        assert_eq!(text.generator_ref(), GeneratorRef::graphics_clip());
        let host = Clip::new(
            Id::from_u128(1),
            "g",
            Id::from_u128(2),
            TrackKind::Video,
            sq_core_time::TimeRange::new(Time::new(2, 1), Time::new(4, 1)),
            Time::new(7, 1),
        );
        let as_clip = host.graphics_layer_clip(&layer);
        assert_eq!((as_clip.id, as_clip.start, as_clip.source), (layer.id, host.start, host.source));
        assert_eq!(as_clip.generator, Some(GeneratorRef::shape(ShapeKind::Ellipse)));
        assert_eq!(as_clip.effects, layer.effects);
    }

    #[test]
    fn layers_are_added_on_top_or_right_above_another() {
        let mut doc = GraphicsDocument::default();
        let layer =
            |n: u128| GraphicsLayer::new(Id::from_u128(n), "l", GraphicsContent::Shape { kind: ShapeKind::Line });
        assert_eq!(doc.add(layer(1), None), Id::from_u128(1));
        doc.add(layer(2), None);
        doc.add(layer(3), Some(Id::from_u128(1)));
        doc.add(layer(4), Some(Id::from_u128(99)));
        let order: Vec<_> = doc.layers.iter().map(|l| l.id).collect();
        assert_eq!(order, [1, 3, 2, 4].map(Id::from_u128));
    }

    fn project_with_graphics(locked: bool) -> (Project, Id) {
        let mut host = Clip::new(
            Id::from_u128(10),
            "Graphic",
            Id::from_u128(11),
            TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, Time::new(4, 1)),
            Time::ZERO,
        );
        host.generator = Some(GeneratorRef::graphics_clip());
        host.set_graphics(Some(GraphicsDocument::default()));
        let plain = Clip::new(
            Id::from_u128(12),
            "plain",
            Id::from_u128(13),
            TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, Time::new(4, 1)),
            Time::new(10, 1),
        );
        let mut track = Track::new(Id::from_u128(20), TrackKind::Video);
        track.is_locked = locked;
        track.set_clips(vec![host, plain]);
        let tl = Timeline::new(Id::from_u128(30), "T", crate::SequenceFormat::new(Time::new(1, 25)), vec![track]);
        (Project::new(Id::from_u128(40), "P", Vec::new(), vec![tl]), Id::from_u128(10))
    }

    #[test]
    fn edit_graphics_changes_the_layers_of_a_graphics_clip_only() {
        let (mut p, id) = project_with_graphics(false);
        let layer = GraphicsLayer::new(Id::from_u128(5), "L", GraphicsContent::Shape { kind: ShapeKind::Line });
        let added = p.edit_graphics(id, |d| Ok(d.add(layer, None)));
        assert_eq!(added, Ok(Id::from_u128(5)));
        let doc = p.graphics_clip(id).and_then(|c| c.graphics().cloned());
        assert_eq!(doc.map(|d| d.layers.len()), Some(1));
        assert_eq!(p.edit_graphics(Id::from_u128(12), |_| Ok(())), Err(EditError::ClipNotFound));
        assert_eq!(p.edit_graphics(Id::from_u128(99), |_| Ok(())), Err(EditError::ClipNotFound));
        let (mut locked, id) = project_with_graphics(true);
        assert_eq!(locked.edit_graphics(id, |_| Ok(())), Err(EditError::TrackLocked));
    }
}
