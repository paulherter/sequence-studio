// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ShapeGenerator.swift (the Project verbs; `ShapeKind`, `ShapeStyle`, the Shape effect keys and
// `Project.defaultShapeEffect` live in `sq-core-model`)

use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{EditError, GeneratorRef, Project, ShapeKind};
use sq_core_time::{Id, IdSource};

/// Placing and switching shape clips.
pub trait ProjectShapeExt {
    /// Places a shape clip (rectangle, ellipse or line) like `add_generator_clip`, sized to the sequence. One mutation, so
    /// one undo step. Errors like `add_generator_clip`. Returns the new clip's id.
    fn add_shape_clip(
        &mut self,
        kind: ShapeKind,
        at: GeneratorPlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Switches a shape clip's outline; size, colors and keys stay. `ClipNotFound` for an unknown clip or one that is not a
    /// shape, `TrackLocked` on a locked track.
    fn set_shape_kind(&mut self, clip_id: Id, kind: ShapeKind) -> Result<(), EditError>;
}

impl ProjectShapeExt for Project {
    fn add_shape_clip(
        &mut self,
        kind: ShapeKind,
        at: GeneratorPlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let timeline = at.timeline;
        let tl = self.timelines.iter().find(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        let (width, height) = (tl.format.display_width(), tl.format.height);
        let id = self.add_generator_clip(GeneratorRef::shape(kind), Some(kind.title()), at, ids)?;
        let effect = Project::default_shape_effect(ids, kind, width, height);
        self.edit(timeline, |t| {
            for track in &mut t.tracks {
                let Some(mut c) = track.clip(id).cloned() else { continue };
                c.effects = vec![effect];
                track.replace(c);
                return Ok(());
            }
            Err(EditError::ClipNotFound)
        })?;
        Ok(id)
    }

    // known limit: Swift routes this through `updateGenerator(clipID:payload:payloadVersion:)` (Generators.swift), which the
    // model does not have yet; the same loop is written out here. Use it once it is ported.
    fn set_shape_kind(&mut self, clip_id: Id, kind: ShapeKind) -> Result<(), EditError> {
        let is_shape =
            |c: &sq_core_model::Clip| c.id == clip_id && c.generator.as_ref().is_some_and(|g| g.shape_kind().is_some());
        if !self.timelines.iter().any(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(is_shape))) {
            return Err(EditError::ClipNotFound);
        }
        let new = GeneratorRef::shape(kind);
        for track in self.timelines.iter_mut().flat_map(|t| t.tracks.iter_mut()) {
            let Some(mut c) = track.clip(clip_id).cloned() else { continue };
            let Some(g) = c.generator.as_mut() else { return Err(EditError::ClipNotFound) };
            if track.is_locked {
                return Err(EditError::TrackLocked);
            }
            g.payload = new.payload;
            g.payload_version = new.payload_version;
            track.replace(c);
            return Ok(());
        }
        Err(EditError::ClipNotFound)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::{project, s};
    use sq_core_model::{AnimatedProperty, Clip, ClipEffect, EffectColor, ShapeStyle, TrackKind};
    use sq_core_time::{Keyframe, SequentialIds, Time, TimeRange};

    fn setup(w: i64, h: i64) -> (Project, Id, Id, Id, SequentialIds) {
        let mut ids = SequentialIds::default();
        let (mut p, tl, tr) = project(&[TrackKind::Video, TrackKind::Audio], &mut ids);
        p.timelines[0].format.width = w;
        p.timelines[0].format.height = h;
        (p, tl, tr[0], tr[1], ids)
    }

    fn at(tl: Id, track: Id, start: i64, dur: i64) -> GeneratorPlacement {
        GeneratorPlacement { timeline: tl, track, start: s(start), duration: s(dur) }
    }

    fn clip(p: &Project, id: Id) -> Clip {
        p.timelines[0].tracks.iter().find_map(|t| t.clip(id)).cloned().unwrap()
    }

    fn style(c: &Clip, t: Time) -> Option<ShapeStyle> {
        c.shape_style(t)
    }

    fn shape_effect_mut(c: &mut Clip) -> &mut ClipEffect {
        c.effects.iter_mut().find(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND).unwrap()
    }

    #[test]
    fn add_rectangle_sizes_to_the_canvas() {
        let (mut p, tl, v, _, mut ids) = setup(1920, 1080);
        let id = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v, 1, 4), &mut ids).unwrap();
        let c = clip(&p, id);
        assert_eq!(c.generator.as_ref().and_then(|g| g.shape_kind()), Some(ShapeKind::Rectangle));
        assert_eq!(c.name, "Rectangle");
        assert_eq!(c.timeline(), TimeRange::new(s(1), s(4)));
        let st = style(&c, Time::ZERO).unwrap();
        assert_eq!((st.kind, st.width, st.height, st.corner_radius), (ShapeKind::Rectangle, 960.0, 540.0, 0.0));
        assert!(st.fill.is_some() && st.stroke.is_none());
    }

    #[test]
    fn ellipse_is_a_circle_and_line_is_a_stroke() {
        let (mut p, tl, v, _, mut ids) = setup(1920, 1080);
        let e = p.add_shape_clip(ShapeKind::Ellipse, at(tl, v, 0, 2), &mut ids).unwrap();
        let es = style(&clip(&p, e), Time::ZERO).unwrap();
        assert_eq!((es.width, es.height), (540.0, 540.0));
        let l = p.add_shape_clip(ShapeKind::Line, at(tl, v, 2, 2), &mut ids).unwrap();
        let ls = style(&clip(&p, l), Time::ZERO).unwrap();
        assert_eq!((ls.kind, ls.width), (ShapeKind::Line, 960.0));
        assert!(ls.stroke.is_some() && ls.fill.is_none() && ls.stroke_width > 0.0);
        assert_eq!(ls.raster_size().1, ls.stroke_width);
    }

    #[test]
    fn refuses_audio_tracks() {
        let (mut p, tl, _, a, mut ids) = setup(1920, 1080);
        assert_eq!(p.add_shape_clip(ShapeKind::Rectangle, at(tl, a, 0, 1), &mut ids), Err(EditError::WrongTrackKind));
    }

    #[test]
    fn every_style_value_is_keyframable() {
        let (mut p, tl, v, _, mut ids) = setup(1920, 1080);
        let id = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v, 0, 4), &mut ids).unwrap();
        let mut c = clip(&p, id);
        let key = |ids: &mut SequentialIds, t, v| Keyframe::new(ids.next_id(), s(t), v);
        let ramp = |ids: &mut SequentialIds, a: f64, b: f64| {
            let mut prop = AnimatedProperty::new(0.0);
            prop.track.insert(key(ids, 0, a));
            prop.track.insert(key(ids, 2, b));
            prop
        };
        let (width, radius, stroke_w) =
            (ramp(&mut ids, 100.0, 300.0), ramp(&mut ids, 0.0, 20.0), ramp(&mut ids, 2.0, 10.0));
        let mut fill = AnimatedProperty::new(EffectColor::BLACK);
        fill.track.insert(Keyframe::new(
            ids.next_id(),
            s(0),
            EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 },
        ));
        fill.track.insert(Keyframe::new(
            ids.next_id(),
            s(2),
            EffectColor { red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0 },
        ));
        let e = shape_effect_mut(&mut c);
        e.colors.insert(ClipEffect::SHAPE_FILL_COLOR_KEY.to_string(), fill);
        e.parameters.insert(ClipEffect::SHAPE_WIDTH_KEY.to_string(), width);
        e.parameters.insert(ClipEffect::SHAPE_CORNER_RADIUS_KEY.to_string(), radius);
        e.parameters.insert(ClipEffect::SHAPE_STROKE_KEY.to_string(), AnimatedProperty::new(1.0));
        e.parameters.insert(ClipEffect::SHAPE_STROKE_WIDTH_KEY.to_string(), stroke_w);
        p.edit(tl, |t| {
            t.tracks[0].replace(c);
            Ok(())
        })
        .unwrap();
        let mid = style(&clip(&p, id), s(1)).unwrap();
        assert_eq!((mid.width, mid.corner_radius, mid.stroke_width), (200.0, 10.0, 6.0));
        let f = mid.fill.unwrap();
        assert!((f.red - 0.5).abs() < 1e-9 && (f.blue - 0.5).abs() < 1e-9);
        assert_eq!(mid.raster_size().0, 206.0); // stroke centered on the outline: half of it outside
    }

    #[test]
    fn corner_radius_is_clamped_to_half_the_shorter_side() {
        let (mut p, tl, v, _, mut ids) = setup(400, 200);
        let id = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v, 0, 1), &mut ids).unwrap();
        let mut c = clip(&p, id);
        shape_effect_mut(&mut c)
            .parameters
            .insert(ClipEffect::SHAPE_CORNER_RADIUS_KEY.to_string(), AnimatedProperty::new(5000.0));
        p.edit(tl, |t| {
            t.tracks[0].replace(c);
            Ok(())
        })
        .unwrap();
        assert_eq!(style(&clip(&p, id), Time::ZERO).map(|s| s.corner_radius), Some(50.0)); // 200 x 100 rectangle
    }

    #[test]
    fn disabled_shape_draws_nothing_and_a_missing_effect_uses_defaults() {
        let (mut p, tl, v, _, mut ids) = setup(1920, 1080);
        let id = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v, 0, 1), &mut ids).unwrap();
        let mut c = clip(&p, id);
        c.effects[0].enabled = false;
        assert!(style(&c, Time::ZERO).is_none());
        c.effects.clear();
        assert!(style(&c, Time::ZERO).is_some());
        c.generator = None;
        assert!(style(&c, Time::ZERO).is_none());
    }

    #[test]
    fn changing_the_kind_keeps_the_style() {
        let (mut p, tl, v, _, mut ids) = setup(1920, 1080);
        let id = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v, 0, 1), &mut ids).unwrap();
        let before = clip(&p, id).effects;
        p.set_shape_kind(id, ShapeKind::Ellipse).unwrap();
        let c = clip(&p, id);
        assert_eq!(c.generator.as_ref().and_then(|g| g.shape_kind()), Some(ShapeKind::Ellipse));
        assert_eq!(c.effects, before);
        assert_eq!(p.set_shape_kind(Id::from_u128(999), ShapeKind::Line), Err(EditError::ClipNotFound));
        p.timelines[0].tracks[0].is_locked = true;
        assert_eq!(p.set_shape_kind(id, ShapeKind::Line), Err(EditError::TrackLocked));
    }

    #[test]
    fn payload_round_trips_the_shape_kind() {
        for k in ShapeKind::ALL {
            let r = GeneratorRef::shape(k);
            assert_eq!((r.kind.as_str(), r.shape_kind()), (GeneratorRef::SHAPE, Some(k)));
        }
        let text = GeneratorRef { kind: "text".to_string(), payload: Vec::new(), payload_version: 1 };
        assert_eq!(text.shape_kind(), None);
        let damaged =
            GeneratorRef { kind: GeneratorRef::SHAPE.to_string(), payload: b"x".to_vec(), payload_version: 1 };
        assert_eq!(damaged.shape_kind(), Some(ShapeKind::Rectangle)); // a damaged payload still draws something
    }

    #[test]
    fn arrow_outline_fits_its_box_and_points_right() {
        let st = ShapeStyle { fill: Some(EffectColor::WHITE), ..ShapeStyle::new(ShapeKind::Arrow, 200.0, 100.0) };
        let pts = st.arrow_points();
        assert!(pts.iter().all(|p| (0.0..=200.0).contains(&p.x) && (0.0..=100.0).contains(&p.y)));
        assert!(pts.contains(&sq_core_time::Vec2::new(200.0, 50.0)));
        assert_eq!((pts[0], pts[6]), (sq_core_time::Vec2::new(0.0, 30.0), sq_core_time::Vec2::new(0.0, 70.0)));
        assert!(!st.is_empty() && st.raster_size().0 == 200.0);
        let short = ShapeStyle { fill: Some(EffectColor::WHITE), ..ShapeStyle::new(ShapeKind::Arrow, 50.0, 100.0) };
        assert_eq!(short.arrow_points()[1].x, 20.0);
    }

    #[test]
    fn arrow_clip_has_defaults() {
        let (mut p, tl, v, _, mut ids) = setup(1920, 1080);
        let id = p.add_shape_clip(ShapeKind::Arrow, at(tl, v, 0, 2), &mut ids).unwrap();
        let st = style(&clip(&p, id), Time::ZERO).unwrap();
        assert_eq!((st.kind, st.width, st.height), (ShapeKind::Arrow, 480.0, 180.0));
        assert!(st.fill.is_some());
    }
}
