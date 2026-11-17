// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+LayerProjection.swift
//
// Controls shows one item (layer) of a graphics clip through the same rows as a clip: the item as a plain text or shape
// clip with the graphic's timing. Keyframes of an item live in Controls only (DECISIONS: one system); the Graphics panel
// edits values at the playhead.

use sq_core_model::{Clip, GraphicsContent, GraphicsDocument};
use sq_core_time::Id;
use std::collections::BTreeSet;

/// Controls' view of one item of a graphics clip.
pub trait GraphicsItemProjectionExt {
    /// Item `layer_id` of this graphics clip as a plain clip under the graphics clip's own id (so the shown clip, its timing
    /// and its twirl state stay the same). `None` when this is no graphics clip or has no such item.
    fn graphics_item_projection(&self, layer_id: Id) -> Option<Clip>;
    /// This graphics clip with the item `layer_id` taking Motion, Opacity, effects and blend mode from `edited` (a clip made by
    /// `graphics_item_projection`; also a text item's text). A locked or missing item, or another clip, leaves the graphic as
    /// it is.
    fn applying_item_projection(&self, edited: &Clip, layer_id: Id) -> Clip;
}

impl GraphicsItemProjectionExt for Clip {
    fn graphics_item_projection(&self, layer_id: Id) -> Option<Clip> {
        if !self.is_graphics() {
            return None;
        }
        let layer = self.graphics()?.layer(layer_id)?;
        let mut c = self.graphics_layer_clip(layer);
        c.id = self.id;
        c.media = self.media;
        c.link = None;
        Some(c)
    }

    fn applying_item_projection(&self, edited: &Clip, layer_id: Id) -> Clip {
        let Some(mut doc) = self.graphics().cloned().filter(|_| self.is_graphics()) else { return self.clone() };
        let Some(i) = doc.index_of(layer_id).filter(|i| !doc.layers[*i].is_locked) else { return self.clone() };
        doc.layers[i].animation = edited.animation.clone();
        doc.layers[i].effects = edited.effects.clone();
        doc.layers[i].blend_mode = edited.blend_mode;
        // Text edits of the shown item (the text generator's payload) belong to the item's content.
        if let (GraphicsContent::Text { .. }, Some(g)) = (&doc.layers[i].content, &edited.generator)
            && g.kind == crate::graphics_make_graphic::TEXT_KIND
        {
            doc.layers[i].content = GraphicsContent::Text { generator: g.clone() };
        }
        let mut c = self.clone();
        c.set_graphics(Some(doc));
        c
    }
}

/// The item picker of Controls.
pub trait GraphicsItemPickerExt {
    /// Entries of the Controls item picker, front-most item first (the order of the Graphics panel list).
    fn item_picker_entries(&self) -> Vec<(Id, String)>;
    /// The item Controls shows for a layer selection: the one selected item, `None` (the whole graphic) for none, several or
    /// an item the document no longer has.
    fn shown_item(&self, selection: &BTreeSet<Id>) -> Option<Id>;
}

impl GraphicsItemPickerExt for GraphicsDocument {
    fn item_picker_entries(&self) -> Vec<(Id, String)> {
        self.layers.iter().rev().map(|l| (l.id, l.name.clone())).collect()
    }

    fn shown_item(&self, selection: &BTreeSet<Id>) -> Option<Id> {
        if selection.len() != 1 {
            return None;
        }
        let id = *selection.iter().next()?;
        self.layer(id).map(|_| id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::rect;
    use sq_core_model::{AnimatedProperty, BlendMode, ClipAnimation, GeneratorRef, TrackKind};
    use sq_core_time::{Keyframe, SequentialIds, Time, TimeRange, Vec2};

    fn graphic() -> (Clip, Id, Id) {
        let mut n = SequentialIds::default();
        let mut doc = GraphicsDocument::default();
        let mut a = rect(&mut n, "Box", None);
        a.animation.position = AnimatedProperty::new(Vec2::new(10.0, 20.0));
        let mut b = sq_core_model::GraphicsLayer::shape(&mut n, sq_core_model::ShapeKind::Ellipse, 1920, 1080);
        b.name = "Dot".to_string();
        let (ia, ib) = (doc.add(a, None), doc.add(b, None));
        let mut c = Clip::new(
            Id::from_u128(500),
            "Graphic",
            Id::from_u128(501),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(5, 1)),
            Time::new(2, 1),
        );
        c.generator = Some(GeneratorRef::graphics_clip());
        c.set_graphics(Some(doc));
        (c, ia, ib)
    }

    #[test]
    fn projection_is_a_plain_clip_with_the_items_motion_and_effects() {
        let (host, a, _) = graphic();
        let p = host.graphics_item_projection(a).unwrap();
        let layer = host.graphics().unwrap().layer(a).unwrap();
        assert!(p.id == host.id && p.start == host.start && p.duration() == host.duration());
        assert_eq!(p.name, "Box");
        assert_eq!(p.generator.as_ref().and_then(|g| g.shape_kind()), Some(sq_core_model::ShapeKind::Rectangle));
        assert!(p.graphics().is_none() && !p.is_graphics());
        assert!(p.animation == layer.animation && p.effects == layer.effects);
    }

    #[test]
    fn unknown_item_or_plain_clip_has_no_projection() {
        let (host, _, _) = graphic();
        assert!(host.graphics_item_projection(Id::from_u128(999)).is_none());
        let mut plain = host.clone();
        plain.generator = None;
        assert!(plain.graphics_item_projection(Id::from_u128(999)).is_none());
    }

    #[test]
    fn edits_go_back_to_the_item_only() {
        let (host, a, b) = graphic();
        let mut p = host.graphics_item_projection(a).unwrap();
        p.animation.rotation = AnimatedProperty::new(45.0);
        p.blend_mode = BlendMode::Multiply;
        let next = host.applying_item_projection(&p, a);
        let doc = next.graphics().unwrap();
        assert_eq!(
            (doc.layer(a).unwrap().animation.rotation.value, doc.layer(a).unwrap().blend_mode),
            (45.0, BlendMode::Multiply)
        );
        assert_eq!(doc.layer(b), host.graphics().unwrap().layer(b));
        assert!(next.animation == host.animation && next.effects == host.effects);
        assert_eq!(next.graphics_item_projection(a), Some(p));
    }

    #[test]
    fn keys_of_an_item_stay_on_the_item() {
        let (host, a, _) = graphic();
        let mut p = host.graphics_item_projection(a).unwrap();
        p.animation.opacity.track.insert(Keyframe::new(Id::from_u128(7), Time::new(1, 1), 0.5));
        let next = host.applying_item_projection(&p, a);
        assert!(next.graphics().unwrap().layer(a).unwrap().animation.opacity.is_animated());
        assert!(!next.animation.opacity.is_animated());
        assert!(!ClipAnimation::default().opacity.is_animated());
    }

    #[test]
    fn locked_item_ignores_edits() {
        let (mut host, a, _) = graphic();
        let mut doc = host.graphics().cloned().unwrap();
        doc.layers[0].is_locked = true;
        host.set_graphics(Some(doc));
        let mut p = host.graphics_item_projection(a).unwrap();
        p.animation.rotation = AnimatedProperty::new(10.0);
        assert_eq!(host.applying_item_projection(&p, a), host);
    }

    #[test]
    fn picker_lists_front_first_and_shows_only_a_single_existing_item() {
        let (host, a, b) = graphic();
        let doc = host.graphics().unwrap();
        let entries = doc.item_picker_entries();
        assert_eq!(entries.iter().map(|e| e.0).collect::<Vec<_>>(), vec![b, a]);
        assert_eq!(entries.iter().map(|e| e.1.as_str()).collect::<Vec<_>>(), vec!["Dot", "Box"]);
        let sel = |v: &[Id]| v.iter().copied().collect::<BTreeSet<Id>>();
        assert_eq!(doc.shown_item(&sel(&[a])), Some(a));
        assert_eq!(doc.shown_item(&sel(&[])), None);
        assert_eq!(doc.shown_item(&sel(&[a, b])), None);
        assert_eq!(doc.shown_item(&sel(&[Id::from_u128(999)])), None);
    }

    #[test]
    fn text_of_a_text_item_goes_back() {
        let (mut host, _, _) = graphic();
        let t = sq_core_model::GraphicsLayer::text(
            Id::from_u128(77),
            GeneratorRef { kind: "text".to_string(), payload: vec![1], payload_version: 1 },
            "Text",
        );
        let mut doc = host.graphics().cloned().unwrap();
        doc.layers.push(t);
        host.set_graphics(Some(doc));
        let mut p = host.graphics_item_projection(Id::from_u128(77)).unwrap();
        assert_eq!(p.generator.as_ref().map(|g| g.kind.as_str()), Some("text"));
        let g2 = GeneratorRef { kind: "text".to_string(), payload: vec![2], payload_version: 1 };
        p.generator = Some(g2.clone());
        let next = host.applying_item_projection(&p, Id::from_u128(77));
        let layer = next.graphics().unwrap().layer(Id::from_u128(77)).unwrap();
        assert_eq!(layer.content, GraphicsContent::Text { generator: g2 });
    }
}
