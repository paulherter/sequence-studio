// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+MoveOut.swift
//
// Lane drag-out (Graphic layer system): layers leave their Graphic and land in another Graphic or on a new Graphic on
// another track. Layer ranges and keys are clip-local, so they travel through absolute timeline time: `extract_layers`
// hands them out in absolute time, `insert_layers` puts them back into the local time of the receiving clip.

use crate::graphics_editing::{GraphicsDocumentEditingExt as _, ProjectGraphicsExt as _};
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{EditError, FollowTarget, GraphicsDocument, GraphicsLayer, Project, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// A layer on its way between two Graphics: `span` is the part of the timeline it shows in, and its keys are absolute too.
#[derive(Clone, Debug, PartialEq)]
pub struct ExtractedLayer {
    /// The layer, keys in timeline time.
    pub layer: GraphicsLayer,
    /// Where it shows.
    pub span: TimeRange,
}

/// `r` limited to 0..<`d`; a range wholly outside becomes an empty one at the nearer edge.
// shortcut: copy of the private `clamped` in sq-core-model's graphics_item_range.rs, which this crate cannot call; share it
// when the model exports it.
fn clamped(r: TimeRange, d: Time) -> TimeRange {
    let a = r.start.max(Time::ZERO).min(d);
    let b = r.end().max(Time::ZERO).min(d);
    TimeRange::from_end(a, a.max(b))
}

/// Moves every key time (Motion, Opacity, effects) of `l` by `d`.
fn shift_keys(l: &mut GraphicsLayer, d: Time) {
    if d == Time::ZERO {
        return;
    }
    l.animation = l.animation.remapped(|t| t + d);
    l.effects = l.effects.iter().map(|e| e.remapped(|t| t + d)).collect();
}

/// Layer hand-over between Graphics.
pub trait GraphicsMoveOutExt {
    /// Removes the layers `ids` (bottom first in the result) and returns them in absolute time. A layer leaves its group and
    /// unpins a Follow whose target does not travel with it; layers that followed a removed one are unpinned.
    fn extract_layers(&mut self, ids: &[Id], clip_start: Time, clip_duration: Time) -> Vec<ExtractedLayer>;
    /// The same as `extract_layers`, the layers stay (copy).
    fn extracted_copies(&self, ids: &[Id], clip_start: Time, clip_duration: Time) -> Vec<ExtractedLayer>;
    /// Puts `items` into the clip at `clip_start` lasting `clip_duration`, above the layer at `index` (`None` = on top), and
    /// returns their ids. A layer keeps its picture and keys on the same timeline times; a range that fills the clip is
    /// stored as `None`. `fresh` gives every layer new ids (copy); Follow links among the set follow the copies.
    fn insert_layers(
        &mut self,
        items: &[ExtractedLayer],
        clip_start: Time,
        clip_duration: Time,
        index: Option<i64>,
        fresh: bool,
        new_ids: &mut dyn IdSource,
    ) -> Vec<Id>;
}

impl GraphicsMoveOutExt for GraphicsDocument {
    fn extract_layers(&mut self, ids: &[Id], clip_start: Time, clip_duration: Time) -> Vec<ExtractedLayer> {
        let set: BTreeSet<Id> = ids.iter().copied().collect();
        let out = self.extracted_copies(ids, clip_start, clip_duration);
        self.remove(&set);
        out
    }

    fn extracted_copies(&self, ids: &[Id], clip_start: Time, clip_duration: Time) -> Vec<ExtractedLayer> {
        let set: BTreeSet<Id> = ids.iter().copied().collect();
        self.layers
            .iter()
            .filter(|l| set.contains(&l.id))
            .map(|l| {
                let mut m = l.clone();
                let local = self.shown_range(l, clip_duration);
                m.group = None;
                m.range = None;
                if matches!(m.follow.as_ref().map(|f| f.target), Some(FollowTarget::Layer(t)) if !set.contains(&t)) {
                    m.follow = None;
                }
                shift_keys(&mut m, clip_start);
                ExtractedLayer { layer: m, span: TimeRange::new(clip_start + local.start, local.duration) }
            })
            .collect()
    }

    fn insert_layers(
        &mut self,
        items: &[ExtractedLayer],
        clip_start: Time,
        clip_duration: Time,
        index: Option<i64>,
        fresh: bool,
        new_ids: &mut dyn IdSource,
    ) -> Vec<Id> {
        let mut map: BTreeMap<Id, Id> = BTreeMap::new();
        let mut placed: Vec<GraphicsLayer> = Vec::new();
        for it in items {
            let mut l = it.layer.clone();
            if fresh {
                let old = l.id;
                l.id = new_ids.next_id();
                l.name.push_str(" copy");
                l.animation.position = l.animation.position.with_fresh_key_ids(new_ids);
                l.animation.scale = l.animation.scale.with_fresh_key_ids(new_ids);
                l.animation.rotation = l.animation.rotation.with_fresh_key_ids(new_ids);
                l.animation.opacity = l.animation.opacity.with_fresh_key_ids(new_ids);
                l.animation.anchor = l.animation.anchor.with_fresh_key_ids(new_ids);
                for e in &mut l.effects {
                    e.id = new_ids.next_id();
                }
                map.insert(old, l.id);
            }
            shift_keys(&mut l, Time::ZERO - clip_start);
            let r = clamped(TimeRange::new(it.span.start - clip_start, it.span.duration), clip_duration);
            l.range = if r.start <= Time::ZERO && r.end() >= clip_duration { None } else { Some(r) };
            placed.push(l);
        }
        for l in &mut placed {
            if let Some(FollowTarget::Layer(t)) = l.follow.as_ref().map(|f| f.target)
                && let (Some(n), Some(f)) = (map.get(&t), l.follow.as_mut())
            {
                f.target = FollowTarget::Layer(*n);
            }
        }
        let count = self.layers.len() as i64;
        let at = index.unwrap_or(count).clamp(0, count) as usize;
        let ids = placed.iter().map(|l| l.id).collect();
        self.layers.splice(at..at, placed);
        ids
    }
}

/// Where dragged layers land.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphicsLayerDestination {
    /// Another Graphic, above the layer at `index` of its list (`None` = on top).
    Graphic {
        /// The receiving Graphic.
        clip: Id,
        /// Position in its list.
        index: Option<i64>,
    },
    /// A new Graphic on a video track, covering the time the layers show in.
    NewGraphic {
        /// The track.
        track: Id,
    },
}

/// The Move Layer Out verb.
pub trait ProjectMoveOutExt {
    /// Moves (or, with `copy`, copies) layers of Graphic `source` to another Graphic or to a new Graphic on another track, as
    /// one mutation (one undo step "Move Layer Out"). The edit is all or nothing. A moved-out Graphic that is left without
    /// layers is removed. Errors: `ClipNotFound` (unknown clip or layers), `TrackLocked`, `WrongTrackKind` and `Collision`
    /// (the target Graphic does not overlap a layer in time, the new Graphic would cover another clip, or the destination is
    /// the source). Returns the receiving Graphic and the ids of the layers there.
    fn move_graphics_layers(
        &mut self,
        ids: &[Id],
        source: Id,
        dest: GraphicsLayerDestination,
        copy: bool,
        new_ids: &mut dyn IdSource,
    ) -> Result<(Id, Vec<Id>), EditError>;
}

impl ProjectMoveOutExt for Project {
    fn move_graphics_layers(
        &mut self,
        ids: &[Id],
        source: Id,
        dest: GraphicsLayerDestination,
        copy: bool,
        new_ids: &mut dyn IdSource,
    ) -> Result<(Id, Vec<Id>), EditError> {
        let mut work = self.clone();
        let has = |tr: &sq_core_model::Track| tr.clip(source).is_some();
        let ti = work.timelines.iter().position(|t| t.tracks.iter().any(has)).ok_or(EditError::ClipNotFound)?;
        let si = work.timelines[ti].tracks.iter().position(has).ok_or(EditError::ClipNotFound)?;
        let src = work.timelines[ti].tracks[si].clip(source).cloned().ok_or(EditError::ClipNotFound)?;
        let mut doc = src.graphics().cloned().filter(|_| src.is_graphics()).ok_or(EditError::ClipNotFound)?;
        if ids.is_empty() || !ids.iter().all(|i| doc.layer(*i).is_some()) {
            return Err(EditError::ClipNotFound);
        }
        if work.timelines[ti].tracks[si].is_locked {
            return Err(EditError::TrackLocked);
        }
        let (start, length) = (src.timeline().start, src.timeline().duration);
        let items =
            if copy { doc.extracted_copies(ids, start, length) } else { doc.extract_layers(ids, start, length) };
        let landed = match dest {
            GraphicsLayerDestination::Graphic { clip: target, index } => {
                if target == source {
                    return Err(EditError::Collision);
                }
                let c = work.graphics_clip(target).cloned().ok_or(EditError::ClipNotFound)?;
                if !items.iter().all(|i| i.span.overlaps(&c.timeline())) {
                    return Err(EditError::Collision);
                }
                let placed = work.edit_graphics(target, |d| {
                    Ok(d.insert_layers(&items, c.timeline().start, c.timeline().duration, index, copy, new_ids))
                })?;
                (target, placed)
            }
            GraphicsLayerDestination::NewGraphic { track: track_id } => {
                let tr =
                    work.timelines[ti].tracks.iter().position(|t| t.id == track_id).ok_or(EditError::ClipNotFound)?;
                if work.timelines[ti].tracks[tr].kind != TrackKind::Video {
                    return Err(EditError::WrongTrackKind);
                }
                if work.timelines[ti].tracks[tr].is_locked {
                    return Err(EditError::TrackLocked);
                }
                let from = items.iter().map(|i| i.span.start).min().unwrap_or(start);
                let to = items.iter().map(|i| i.span.end()).max().unwrap_or(start);
                let span = TimeRange::from_end(from, to.max(from + work.timelines[ti].frame_duration()));
                // shortcut: no overwrite here; a drop onto occupied time is refused so the receiving track never eats a clip
                // (the source Graphic included), upgrade when a drop should be allowed to overwrite.
                if work.timelines[ti].tracks[tr].clips().iter().any(|c| c.timeline().overlaps(&span)) {
                    return Err(EditError::Collision);
                }
                let at = GeneratorPlacement {
                    timeline: work.timelines[ti].id,
                    track: track_id,
                    start: span.start,
                    duration: span.duration,
                };
                let id = work.add_graphics_clip(at, Vec::new(), new_ids)?;
                let placed = work.edit_graphics(id, |d| {
                    Ok(d.insert_layers(&items, span.start, span.duration, None, copy, new_ids))
                })?;
                (id, placed)
            }
        };
        if !copy {
            if doc.layers.is_empty() {
                work.timelines[ti].tracks[si].remove(source);
            } else {
                let mut edited = src;
                edited.set_graphics(Some(doc));
                work.timelines[ti].tracks[si].replace(edited);
            }
        }
        *self = work;
        Ok(landed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::{project, rect, s};
    use sq_core_model::Clip;
    use sq_core_time::{Keyframe, SequentialIds};

    /// Source: 10 s at 2 s on V1 (A, B); other: 6 s at 5 s on V2 (empty item X); V3 free.
    struct Setup {
        p: Project,
        src: Id,
        other: Id,
        v3: Id,
        a: Id,
        b: Id,
        ids: SequentialIds,
    }

    fn setup() -> Setup {
        let mut ids = SequentialIds::default();
        let (mut p, tl, tr) = project(&[TrackKind::Video, TrackKind::Video, TrackKind::Video], &mut ids);
        let a = rect(&mut ids, "A", Some(TimeRange::from_end(s(1), s(4)))); // absolute 3..6
        let b = rect(&mut ids, "B", None);
        let (ia, ib) = (a.id, b.id);
        let place = |start, track, dur| GeneratorPlacement { timeline: tl, track, start: s(start), duration: s(dur) };
        let src = p.add_graphics_clip(place(2, tr[0], 10), vec![a, b], &mut ids).unwrap();
        let x = rect(&mut ids, "X", None);
        let other = p.add_graphics_clip(place(5, tr[1], 6), vec![x], &mut ids).unwrap();
        Setup { p, src, other, v3: tr[2], a: ia, b: ib, ids }
    }

    fn clip(p: &Project, id: Id) -> Option<Clip> {
        p.timelines[0].tracks.iter().find_map(|t| t.clip(id)).cloned()
    }

    fn layer_ids(p: &Project, id: Id) -> Vec<Id> {
        clip(p, id).and_then(|c| c.graphics().map(|d| d.layers.iter().map(|l| l.id).collect())).unwrap_or_default()
    }

    #[test]
    fn extract_and_insert_shift_ranges_through_absolute_time() {
        let mut n = SequentialIds::default();
        let mut doc = GraphicsDocument {
            layers: vec![rect(&mut n, "A", Some(TimeRange::from_end(s(1), s(4)))), rect(&mut n, "B", None)],
            groups: Vec::new(),
        };
        let ids: Vec<Id> = doc.layers.iter().map(|l| l.id).collect();
        let out = doc.extract_layers(&ids, s(2), s(10));
        assert!(doc.layers.is_empty());
        assert_eq!(out[0].span, TimeRange::from_end(s(3), s(6)));
        assert_eq!(out[1].span, TimeRange::from_end(s(2), s(12)));
        let mut dest = GraphicsDocument::default();
        dest.insert_layers(&out, s(5), s(6), None, false, &mut n);
        assert_eq!(dest.layers[0].range, Some(TimeRange::from_end(Time::ZERO, s(1))));
        assert!(dest.layers[1].range.is_none() || dest.layers[1].range == Some(TimeRange::from_end(Time::ZERO, s(6))));
    }

    #[test]
    fn move_to_another_graphic_keeps_times_and_removes_from_source() {
        let mut t = setup();
        let dest = GraphicsLayerDestination::Graphic { clip: t.other, index: None };
        let r = t.p.move_graphics_layers(&[t.a], t.src, dest, false, &mut t.ids).unwrap();
        assert_eq!(r, (t.other, vec![t.a]));
        assert_eq!(layer_ids(&t.p, t.src), vec![t.b]);
        let c = clip(&t.p, t.other).unwrap();
        let doc = c.graphics().unwrap();
        assert_eq!(doc.layers.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(), vec!["X", "A"]);
        assert_eq!(doc.layer(t.a).unwrap().range, Some(TimeRange::from_end(Time::ZERO, s(1)))); // 3..6 clamped to 5..11
    }

    #[test]
    fn a_whole_clip_layer_becomes_the_range_span_of_the_source() {
        let mut t = setup();
        let dest = GraphicsLayerDestination::Graphic { clip: t.other, index: Some(0) };
        t.p.move_graphics_layers(&[t.b], t.src, dest, false, &mut t.ids).unwrap();
        let c = clip(&t.p, t.other).unwrap();
        let doc = c.graphics().unwrap();
        assert_eq!(doc.layers[0].id, t.b);
        assert!(doc.layer(t.b).unwrap().range.is_none()); // source span 2..12 covers 5..11
    }

    #[test]
    fn move_to_a_new_graphic_on_another_track() {
        let mut t = setup();
        let dest = GraphicsLayerDestination::NewGraphic { track: t.v3 };
        let (new, placed) = t.p.move_graphics_layers(&[t.a], t.src, dest, false, &mut t.ids).unwrap();
        let c = clip(&t.p, new).unwrap();
        assert_eq!(c.timeline(), TimeRange::from_end(s(3), s(6)));
        assert_eq!(placed, vec![t.a]);
        assert!(c.graphics().unwrap().layer(t.a).unwrap().range.is_none());
        assert_eq!(layer_ids(&t.p, t.src).len(), 1);
    }

    #[test]
    fn moving_the_last_layers_removes_the_empty_graphic() {
        let mut t = setup();
        let dest = GraphicsLayerDestination::NewGraphic { track: t.v3 };
        t.p.move_graphics_layers(&[t.a, t.b], t.src, dest, false, &mut t.ids).unwrap();
        assert!(clip(&t.p, t.src).is_none());
    }

    #[test]
    fn copy_keeps_the_original_and_gives_fresh_ids() {
        let mut t = setup();
        let dest = GraphicsLayerDestination::Graphic { clip: t.other, index: None };
        let r = t.p.move_graphics_layers(&[t.a], t.src, dest, true, &mut t.ids).unwrap();
        assert_ne!(r.1, vec![t.a]);
        assert_eq!(layer_ids(&t.p, t.src).len(), 2);
        assert_eq!(layer_ids(&t.p, t.other).len(), 2);
    }

    #[test]
    fn refused_drops_change_nothing() {
        let mut t = setup();
        let before = t.p.clone();
        let own = GraphicsLayerDestination::Graphic { clip: t.src, index: None };
        assert!(t.p.move_graphics_layers(&[t.a], t.src, own, false, &mut t.ids).is_err());
        let same_track = GraphicsLayerDestination::NewGraphic { track: t.p.timelines[0].tracks[0].id };
        assert!(t.p.move_graphics_layers(&[t.a], t.src, same_track, false, &mut t.ids).is_err());
        let free = GraphicsLayerDestination::NewGraphic { track: t.v3 };
        assert!(t.p.move_graphics_layers(&[Id::from_u128(999)], t.src, free, false, &mut t.ids).is_err());
        assert_eq!(t.p, before);
        // No overlap in time: a Graphic at 20 s.
        let (tl, v2) = (t.p.timelines[0].id, t.p.timelines[0].tracks[1].id);
        let item = rect(&mut t.ids, "F", None);
        let at = GeneratorPlacement { timeline: tl, track: v2, start: s(20), duration: s(2) };
        let far = t.p.add_graphics_clip(at, vec![item], &mut t.ids).unwrap();
        let b2 = t.p.clone();
        let to_far = GraphicsLayerDestination::Graphic { clip: far, index: None };
        assert!(t.p.move_graphics_layers(&[t.a], t.src, to_far, false, &mut t.ids).is_err());
        assert_eq!(t.p, b2);
        let _ = t.other;
    }

    #[test]
    fn keys_travel_on_their_timeline_times() {
        let mut t = setup();
        let key = Keyframe::new(t.ids.next_id(), s(2), 0.5); // absolute 4
        let a = t.a;
        t.p.edit_graphics(t.src, |d| {
            d.layers.iter_mut().filter(|l| l.id == a).for_each(|l| l.animation.opacity.track.insert(key.clone()));
            Ok(())
        })
        .unwrap();
        let dest = GraphicsLayerDestination::Graphic { clip: t.other, index: None };
        t.p.move_graphics_layers(&[t.a], t.src, dest, false, &mut t.ids).unwrap();
        let c = clip(&t.p, t.other).unwrap();
        let l = c.graphics().unwrap().layer(t.a).unwrap();
        assert_eq!(l.animation.opacity.track.keys[0].time, s(-1)); // absolute 4 is -1 s in the clip starting at 5
    }
}
