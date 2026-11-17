// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+MakeGraphic.swift
//
// Make Graphic (G9): a text / shape clip becomes a graphics clip with one layer.

use sq_core_effects::effect_transform_stage::ClipStageEval;
use sq_core_model::{
    Clip, ClipEffect, EditError, GeneratorRef, GraphicsContent, GraphicsDocument, GraphicsLayer, Project, Timeline,
};
use sq_core_time::{Id, IdSource};

/// The text generator's kind (Swift `GeneratorRef.text`). `sq-core-effects` keeps a copied literal until it imports this.
pub const TEXT_KIND: &str = "text";

/// Clip queries of Make Graphic.
pub trait ClipMakeGraphicExt {
    /// A text or shape generator clip (can become a graphic).
    fn is_text_or_shape(&self) -> bool;
    /// The clip is rendered over a shutter (Motion shutter open or keyed, a Motion Blur effect or a transform-stage effect).
    fn has_motion_blur(&self) -> bool;
}

impl ClipMakeGraphicExt for Clip {
    fn is_text_or_shape(&self) -> bool {
        self.generator.as_ref().is_some_and(|g| g.kind == TEXT_KIND || g.shape_kind().is_some())
    }

    fn has_motion_blur(&self) -> bool {
        self.effects.iter().any(|e| e.enabled && (e.kind == ClipEffect::MOTION_BLUR_KIND || self.moves_clip(e)))
            || self.motion_enabled && self.animation.is_shutter_open_or_keyed()
    }
}

/// Make Graphic on a sequence.
pub trait TimelineMakeGraphicExt {
    /// `ProjectMakeGraphicExt::make_graphic_blocker` for clip `c` of this sequence.
    fn make_graphic_blocker(&self, c: &Clip) -> Option<&'static str>;
}

impl TimelineMakeGraphicExt for Timeline {
    fn make_graphic_blocker(&self, c: &Clip) -> Option<&'static str> {
        if !c.is_text_or_shape() {
            return Some("Only text and shape clips can become graphics.");
        }
        if c.variant_store.as_ref().is_some_and(|s| !s.items.is_empty())
            || (c.generator.as_ref().is_some_and(|g| g.kind == TEXT_KIND) && !self.variants.is_empty())
        {
            return Some("Remove format variants first.");
        }
        if c.has_motion_blur() {
            return Some("Turn off motion blur first.");
        }
        if let Some(e) = c.effects.iter().find(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND)
            && (e.parameters.values().any(|p| p.is_animated()) || e.colors.values().any(|p| p.is_animated()))
        {
            return Some("Remove the keys of the shape first.");
        }
        None
    }
}

/// Make Graphic on a project.
pub trait ProjectMakeGraphicExt {
    /// Why `clip_id` cannot become a graphic without changing its picture or behavior; `None` when it can. Hints are shown to
    /// the user. Refused: format variants (their conform and per-effect overrides only reach text / clip-level effects),
    /// motion blur (graphic layers are not sampled over the shutter) and a keyed Shape effect (keys on layer effects do not
    /// follow trims and animation zones yet).
    fn make_graphic_blocker(&self, clip_id: Id) -> Option<&'static str>;
    /// True when `clip_id` is a text or shape clip that can become a graphic (`make_graphic_blocker` is `None`).
    fn can_convert_to_graphics(&self, clip_id: Id) -> bool;
    /// Turns a text or shape clip into a graphics clip with one layer at identity, so evaluation draws the same picture: the
    /// text payload is copied unchanged; a shape's kind and Shape effect move to the layer. The clip keeps its Motion, other
    /// effects, masks, blend mode, zones and markers (they now apply to the graphic as a whole). One mutation = one undo
    /// step. `ClipNotFound` for an unknown clip or one that is not text or shape, `TrackLocked` on a locked track.
    fn convert_to_graphics(&mut self, clip_id: Id, ids: &mut dyn IdSource) -> Result<GraphicsLayer, EditError>;
}

impl ProjectMakeGraphicExt for Project {
    fn make_graphic_blocker(&self, clip_id: Id) -> Option<&'static str> {
        for t in &self.timelines {
            if let Some(c) = t.tracks.iter().find_map(|tr| tr.clip(clip_id)) {
                return t.make_graphic_blocker(c);
            }
        }
        Some("Select a text or shape clip.")
    }

    fn can_convert_to_graphics(&self, clip_id: Id) -> bool {
        self.make_graphic_blocker(clip_id).is_none()
    }

    fn convert_to_graphics(&mut self, clip_id: Id, ids: &mut dyn IdSource) -> Result<GraphicsLayer, EditError> {
        for ti in 0..self.timelines.len() {
            for tr in 0..self.timelines[ti].tracks.len() {
                let Some(mut c) = self.timelines[ti].tracks[tr].clip(clip_id).cloned() else { continue };
                let Some(r) = c.generator.clone().filter(|_| c.is_text_or_shape()) else {
                    return Err(EditError::ClipNotFound);
                };
                if self.timelines[ti].tracks[tr].is_locked {
                    return Err(EditError::TrackLocked);
                }
                if self.make_graphic_blocker(clip_id).is_some() {
                    return Err(EditError::NotConvertible);
                }
                let layer = if let Some(kind) = r.shape_kind() {
                    let mut effects = Vec::new();
                    if let Some(i) = c.effects.iter().position(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND) {
                        effects.push(c.effects.remove(i));
                    }
                    let mut l = GraphicsLayer::new(ids.next_id(), kind.title(), GraphicsContent::Shape { kind });
                    l.effects = effects;
                    l
                } else {
                    GraphicsLayer::text(ids.next_id(), r, "Text")
                };
                c.generator = Some(GeneratorRef::graphics_clip());
                c.set_graphics(Some(GraphicsDocument { layers: vec![layer.clone()], groups: Vec::new() }));
                self.timelines[ti].tracks[tr].replace(c);
                return Ok(layer);
            }
        }
        Err(EditError::ClipNotFound)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::{project, s};
    use crate::graphics_editing::ProjectGraphicsExt as _;
    use crate::shape_generator::ProjectShapeExt as _;
    use sq_core_model::project_media_ops::GeneratorPlacement;
    use sq_core_model::{AnimatedProperty, BlendMode, ClipAnimation, FormatVariant, ShapeKind, TrackKind};
    use sq_core_time::{Keyframe, SequentialIds, Time};

    fn setup() -> (Project, Id, Id, SequentialIds) {
        let mut ids = SequentialIds::default();
        let (p, tl, tr) = project(&[TrackKind::Video, TrackKind::Video, TrackKind::Audio], &mut ids);
        (p, tl, tr[1], ids)
    }

    fn at(tl: Id, track: Id, start: i64, dur: i64) -> GeneratorPlacement {
        GeneratorPlacement { timeline: tl, track, start: s(start), duration: s(dur) }
    }

    fn clip(p: &Project, id: Id) -> Clip {
        p.timelines[0].tracks.iter().find_map(|t| t.clip(id)).cloned().unwrap()
    }

    fn put(p: &mut Project, tl: Id, c: Clip) {
        p.edit(tl, |t| {
            for tr in &mut t.tracks {
                if tr.clip(c.id).is_some() {
                    tr.replace(c);
                    return Ok(());
                }
            }
            Err(EditError::ClipNotFound)
        })
        .unwrap();
    }

    #[test]
    fn shape_clip_keeps_picture_and_clip_properties() {
        let (mut p, tl, v2, mut ids) = setup();
        let id = p.add_shape_clip(ShapeKind::Ellipse, at(tl, v2, 1, 4), &mut ids).unwrap();
        let mut c = clip(&p, id);
        c.animation.position = AnimatedProperty::new(sq_core_time::Vec2::new(40.0, -20.0));
        c.blend_mode = BlendMode::Multiply;
        let blur = ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap();
        c.effects.push(blur);
        put(&mut p, tl, c.clone());
        let style_before = clip(&p, id).shape_style(Time::ZERO);
        p.convert_to_graphics(id, &mut ids).unwrap();
        let n = clip(&p, id);
        assert!(n.is_graphics() && n.graphics().unwrap().layers.len() == 1);
        assert!(n.animation == c.animation && n.blend_mode == BlendMode::Multiply && n.timeline() == c.timeline());
        assert!(n.effects.iter().any(|e| e.kind == ClipEffect::GAUSSIAN_BLUR_KIND));
        assert!(!n.effects.iter().any(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND));
        let l = &n.graphics().unwrap().layers[0];
        assert!(l.animation == ClipAnimation::default() && l.shape_effect().is_some());
        assert_eq!(l.shape_style(Time::ZERO), style_before);
        assert_eq!(l.name, "Ellipse");
    }

    #[test]
    fn text_clip_copies_the_payload_unchanged() {
        let (mut p, tl, v2, mut ids) = setup();
        let g = GeneratorRef { kind: "text".to_string(), payload: b"hello".to_vec(), payload_version: 3 };
        let id = p.add_generator_clip(g.clone(), Some("Title"), at(tl, v2, 0, 3), &mut ids).unwrap();
        p.convert_to_graphics(id, &mut ids).unwrap();
        let layer = clip(&p, id).graphics().unwrap().layers[0].clone();
        assert_eq!(layer.content, GraphicsContent::Text { generator: g });
    }

    #[test]
    fn refuses_what_would_change_the_picture() {
        let (mut p, tl, v2, mut ids) = setup();
        let keyed = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v2, 0, 2), &mut ids).unwrap();
        let mut c = clip(&p, keyed);
        let key = Keyframe::new(ids.next_id(), Time::ZERO, 50.0);
        let e = c.effects.iter_mut().find(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND).unwrap();
        e.parameters.get_mut(ClipEffect::SHAPE_WIDTH_KEY).unwrap().track.insert(key);
        put(&mut p, tl, c);
        assert_eq!(p.make_graphic_blocker(keyed), Some("Remove the keys of the shape first."));
        assert_eq!(p.convert_to_graphics(keyed, &mut ids).unwrap_err(), EditError::NotConvertible);
        let blur = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v2, 3, 2), &mut ids).unwrap();
        let mut m = clip(&p, blur);
        m.animation.shutter_angle = AnimatedProperty::new(180.0);
        put(&mut p, tl, m);
        assert_eq!(p.make_graphic_blocker(blur), Some("Turn off motion blur first."));
        let text = p
            .add_generator_clip(
                GeneratorRef { kind: "text".to_string(), payload: b"t".to_vec(), payload_version: 1 },
                None,
                at(tl, v2, 9, 1),
                &mut ids,
            )
            .unwrap();
        assert_eq!(p.make_graphic_blocker(text), None);
        p.timelines[0].variants = vec![FormatVariant {
            id: ids.next_id(),
            name: "V".to_string(),
            width: 1080,
            height: 1920,
            conform: sq_core_model::ConformMode::Fill,
        }];
        assert_eq!(p.make_graphic_blocker(text), Some("Remove format variants first."));
    }

    #[test]
    fn rejects_other_clips_and_locked_tracks() {
        let (mut p, tl, v2, mut ids) = setup();
        let g = p.add_graphics_clip(at(tl, v2, 0, 2), Vec::new(), &mut ids).unwrap();
        assert!(!p.can_convert_to_graphics(g));
        assert_eq!(p.make_graphic_blocker(g), Some("Only text and shape clips can become graphics."));
        assert_eq!(p.make_graphic_blocker(Id::from_u128(999)), Some("Select a text or shape clip."));
        assert_eq!(p.convert_to_graphics(g, &mut ids).unwrap_err(), EditError::ClipNotFound);
        assert_eq!(p.convert_to_graphics(Id::from_u128(999), &mut ids).unwrap_err(), EditError::ClipNotFound);
        let sh = p.add_shape_clip(ShapeKind::Rectangle, at(tl, v2, 5, 2), &mut ids).unwrap();
        assert!(p.can_convert_to_graphics(sh));
        p.timelines[0].tracks[1].is_locked = true;
        assert_eq!(p.convert_to_graphics(sh, &mut ids).unwrap_err(), EditError::TrackLocked);
    }
}
