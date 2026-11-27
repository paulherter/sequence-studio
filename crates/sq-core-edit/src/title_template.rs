//! Title templates: capture a selection, apply a template as one nested clip, change a slot, detect animation zones.
// Swift: TitleTemplate.swift (capture, detectZones, applyTitleTemplate, setTemplateSlot), AnimationZones.swift (autoDetect)

use crate::snapping::keyframe_times;
use crate::timeline_reel_fill::TimelineReelFillExt;
use sq_core_model::{
    AnimationZones, Clip, EditError, PayloadPath, Project, SlotValue, TemplateEditError, TemplateSlot,
    TemplateSlotKind, Timeline, TitleTemplate, TitleTemplateError, Track, TrackKind, ZoneMiddle,
};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

// shortcut: the text generator kind is owned by sq-text, which this crate cannot depend on; keep in step with
// `TextGenerator::KIND`, replace when the kind constants move to a shared module.
const TEXT_KIND: &str = "text";

/// Swift `TitleTemplate.detectZones` and `capture` (static functions of the Swift type).
pub trait TitleTemplateExt: Sized {
    /// Zones from the first/last keys of every layer (`AnimationZones::detect`); `extra_key_times` (content time) adds
    /// keys the core cannot see, such as a text layer's anchored in/out animation.
    fn detect_zones(content: &Timeline, extra_key_times: &[Time]) -> AnimationZones;

    /// Save as Template: the video clips `ids` of `timeline` become one template (shifted so the earliest starts at 0, one
    /// content track per involved track, transitions between them kept). Each text layer gets a text slot ("Text 1",
    /// "Text 2" ...); zones are auto-detected. Errors: `EmptyClip` (no ids / no video clip), `ClipNotFound`,
    /// `TimelineNotFound`.
    fn capture(
        clips: &[Id],
        timeline: Id,
        project: &Project,
        name: &str,
        extra_key_times: &[Time],
        ids: &mut dyn IdSource,
    ) -> Result<TitleTemplate, EditError>;
}

impl TitleTemplateExt for TitleTemplate {
    fn detect_zones(content: &Timeline, extra_key_times: &[Time]) -> AnimationZones {
        let d = content.duration();
        let mut times: Vec<Time> = extra_key_times.to_vec();
        for t in content.tracks.iter().filter(|t| t.kind == TrackKind::Video) {
            for c in t.clips() {
                times.extend(keyframe_times(c).into_iter().map(|k| k + c.start));
            }
        }
        AnimationZones::detect(&times, d, ZoneMiddle::Hold, Some(d))
            .unwrap_or_else(|| AnimationZones::new(Time::ZERO, Time::ZERO, ZoneMiddle::Hold, Some(d)))
    }

    fn capture(
        clips: &[Id],
        timeline: Id,
        project: &Project,
        name: &str,
        extra_key_times: &[Time],
        ids: &mut dyn IdSource,
    ) -> Result<TitleTemplate, EditError> {
        let tl = project.timeline(timeline).ok_or(EditError::TimelineNotFound)?;
        if clips.is_empty() {
            return Err(EditError::EmptyClip);
        }
        let all: BTreeSet<Id> = tl.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
        if !clips.iter().all(|c| all.contains(c)) {
            return Err(EditError::ClipNotFound);
        }
        let wanted: BTreeSet<Id> = clips.iter().copied().collect();
        let involved: Vec<&Track> = tl
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video && t.clips().iter().any(|c| wanted.contains(&c.id)))
            .collect();
        let picked: Vec<&Clip> =
            involved.iter().flat_map(|t| t.clips().iter().filter(|c| wanted.contains(&c.id))).collect();
        let Some(s) = picked.iter().map(|c| c.start).min() else { return Err(EditError::EmptyClip) };
        let mut track_ids: BTreeMap<Id, Id> = BTreeMap::new();
        let mut tracks: Vec<Track> = Vec::new();
        for t in &involved {
            let moved: Vec<Clip> = t
                .clips()
                .iter()
                .filter(|c| wanted.contains(&c.id))
                .map(|c| {
                    let mut c = c.clone();
                    c.start -= s;
                    c
                })
                .collect();
            let carried = t
                .transitions
                .iter()
                .filter(|tr| {
                    tr.outgoing.is_none_or(|o| wanted.contains(&o)) && tr.incoming.is_none_or(|n| wanted.contains(&n))
                })
                .cloned()
                .collect();
            let mut n = Track::new(ids.next_id(), TrackKind::Video);
            n.set_clips(moved);
            n.sync_lock = t.sync_lock;
            n.name = t.name.clone();
            n.is_visible = t.is_visible;
            n.height = t.height;
            n.transitions = carried;
            track_ids.insert(t.id, n.id);
            tracks.push(n);
        }
        let mut content = Timeline::new(ids.next_id(), name, tl.format.clone(), tracks);
        content.remap_picture_masks(&track_ids);
        content.drop_attachments_to_missing_hosts();
        let mut slots: Vec<TemplateSlot> = Vec::new();
        let track_index = |id: Id| involved.iter().position(|t| t.clips().iter().any(|c| c.id == id)).unwrap_or(0);
        let mut sorted = picked.clone();
        sorted.sort_by(|a, b| {
            let (ia, ib) = (track_index(a.id), track_index(b.id));
            if ia != ib { ia.cmp(&ib) } else { a.start.cmp(&b.start) }
        });
        for c in sorted {
            let path = "template.text";
            let text_of = |payload: &[u8]| match PayloadPath::value(path, payload) {
                Ok(serde_json::Value::String(t)) => t,
                _ => String::new(),
            };
            if let Some(g) = c.generator.as_ref().filter(|g| g.kind == TEXT_KIND) {
                let text = text_of(&g.payload);
                slots.push(TemplateSlot {
                    id: ids.next_id(),
                    name: format!("Text {}", slots.len() + 1),
                    kind: if sq_core_model::is_single_emoji(&text) {
                        TemplateSlotKind::Emoji
                    } else {
                        TemplateSlotKind::Text
                    },
                    layer: c.id,
                    graphics_layer: None,
                    path: path.to_string(),
                    value: SlotValue::Text(text),
                });
            } else if c.is_still
                && !c.is_graphics()
                && let Some(m) = project.media(c.media)
            {
                // An image layer: the slot keeps the file path; applying imports the file when the project lacks it.
                slots.push(TemplateSlot {
                    id: ids.next_id(),
                    name: format!("Image {}", slots.len() + 1),
                    kind: TemplateSlotKind::Image,
                    layer: c.id,
                    graphics_layer: None,
                    path: String::new(),
                    value: SlotValue::Media { path: m.path.clone(), bookmark: m.bookmark.clone() },
                });
            } else if c.is_graphics()
                && let Some(doc) = c.graphics()
            {
                // v62: each text layer of a graphics clip is a field of its own.
                for l in &doc.layers {
                    let sq_core_model::GraphicsContent::Text { generator } = &l.content else { continue };
                    let text = text_of(&generator.payload);
                    slots.push(TemplateSlot {
                        id: ids.next_id(),
                        name: format!("Text {}", slots.len() + 1),
                        kind: TemplateSlotKind::Text,
                        layer: c.id,
                        graphics_layer: Some(l.id),
                        path: path.to_string(),
                        value: SlotValue::Text(text),
                    });
                }
            }
        }
        let zones = Self::detect_zones(&content, extra_key_times);
        Ok(TitleTemplate::new(ids.next_id(), name, None, content, slots, Some(zones)))
    }
}

/// `extension Project` of TitleTemplate.swift and AnimationZones.swift (auto-detect).
pub trait ProjectTitleTemplateExt {
    /// Applies a title template as ONE nested clip on video track `track` of `timeline` at `start` (overwrite), `duration`
    /// long (default: the template's, in whole host frames). The content is copied into a new inner sequence with fresh
    /// ids; `values` replace slot values (by the template's slot ids). The clip carries the template's zones, so trimming it
    /// keeps the intro and outro whole. One mutation: one undo step. Errors: `TimelineNotFound`, `ClipNotFound` (track),
    /// `WrongTrackKind`, `TrackLocked`, `EmptyClip`, `SlotPathNotFound`.
    #[allow(clippy::too_many_arguments)]
    fn apply_title_template(
        &mut self,
        template: &TitleTemplate,
        timeline: Id,
        track: Id,
        start: Time,
        duration: Option<Time>,
        values: &BTreeMap<Id, SlotValue>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, TemplateEditError>;

    /// Changes one slot of an applied template clip: writes the value into its layer inside the clip's inner sequence and
    /// remembers it on the clip. One mutation: one undo step. Errors: `ClipNotFound`, `TrackLocked`, `SlotNotFound`,
    /// `SlotPathNotFound`.
    fn set_template_slot(
        &mut self,
        slot: Id,
        value: SlotValue,
        clip: Id,
        ids: &mut dyn IdSource,
    ) -> Result<(), TemplateEditError>;

    /// Turns zones on for a clip, detected from its keyframes (a nested template clip keeps its design duration and
    /// middle mode). Errors: `NoKeyframes`.
    fn auto_detect_animation_zones(&mut self, clip: Id) -> Result<(), TemplateEditError>;
}

impl ProjectTitleTemplateExt for Project {
    fn apply_title_template(
        &mut self,
        template: &TitleTemplate,
        timeline: Id,
        track: Id,
        start: Time,
        duration: Option<Time>,
        values: &BTreeMap<Id, SlotValue>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, TemplateEditError> {
        let host = self.timeline(timeline).ok_or(EditError::TimelineNotFound)?;
        let tr = host.tracks.iter().position(|t| t.id == track).ok_or(EditError::ClipNotFound)?;
        if host.tracks[tr].kind != TrackKind::Video {
            return Err(EditError::WrongTrackKind.into());
        }
        if host.tracks[tr].is_locked {
            return Err(EditError::TrackLocked.into());
        }
        let fd = host.frame_duration();
        if template.duration() <= Time::ZERO || start < Time::ZERO {
            return Err(EditError::EmptyClip.into());
        }
        // Never shorter than intro + outro + one frame, so a short clip cannot cut the intro (animation_zones content_time).
        let floor = (template.zones.intro_end + template.zones.outro_length + fd).snapped(fd).max(fd);
        let len = duration.unwrap_or(template.duration()).snapped(fd).max(floor);

        let (mut inner, mut slots) = instantiated(template, ids);
        let mut work_media = self.media.clone();
        for (s, original) in slots.iter_mut().zip(&template.slots) {
            let given = values.get(&s.id);
            if let Some(v) = given {
                s.value = v.clone();
            }
            // An image is always imported: the saved path names a file the project may not have yet.
            if given.is_some() || s.value != original.value || matches!(s.value, SlotValue::Media { .. }) {
                if let SlotValue::Media { path, bookmark } = &s.value {
                    let media_id = import_media(&mut work_media, path, bookmark.as_ref(), ids);
                    inner.point_layer_at_media(s.layer, media_id)?;
                } else {
                    inner.set_slot(s.layer, s.graphics_layer, &s.path, &s.value)?;
                }
            }
        }
        let mut c = Clip::new(
            ids.next_id(),
            &template.name,
            inner.id,
            TrackKind::Video,
            TimeRange::new(Time::ZERO, len),
            start,
        );
        c.media_duration = Some(template.duration());
        c.sequence = Some(inner.id);
        c.zones = Some(template.zones.clone());
        c.template_slots = Some(slots);
        let clip_id = c.id;
        let mut work = self.clone();
        work.media = work_media;
        work.timelines.push(inner);
        work.edit(timeline, |t| t.tracks[tr].overwrite(c, ids))?;
        *self = work;
        Ok(clip_id)
    }

    fn set_template_slot(
        &mut self,
        slot: Id,
        value: SlotValue,
        clip: Id,
        ids: &mut dyn IdSource,
    ) -> Result<(), TemplateEditError> {
        let mut work = self.clone();
        let mut target: Option<(Id, TemplateSlot)> = None;
        // Copy on write: a copy of an applied clip shares the inner sequence until one of them is edited, then that one
        // gets its own copy (fresh ids, slots repointed), so the other keeps its text.
        let uses: Vec<&Clip> = self
            .timelines
            .iter()
            .flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter()))
            .filter(|c| c.template_slots.is_some() && c.sequence.is_some())
            .collect();
        let mut fork: Option<Timeline> = None;
        let mut clip_map: BTreeMap<Id, Id> = BTreeMap::new();
        if let Some(seq) = uses.iter().find(|c| c.id == clip).and_then(|me| me.sequence)
            && uses.iter().filter(|c| c.sequence == Some(seq)).count() > 1
            && let Some(inner) = self.timeline(seq)
        {
            let (f, m) = inner.copy_with_fresh_ids_mapped(ids);
            fork = Some(f);
            clip_map = m;
        }
        work.modify_clip_for_zones(clip, |c| {
            let (Some(seq), Some(mut slots)) = (c.sequence, c.template_slots.clone()) else {
                return Err(TitleTemplateError::SlotNotFound.into());
            };
            let Some(k) = slots.iter().position(|s| s.id == slot) else {
                return Err(TitleTemplateError::SlotNotFound.into());
            };
            if let Some(f) = &fork {
                for s in slots.iter_mut() {
                    s.layer = clip_map.get(&s.layer).copied().unwrap_or(s.layer);
                }
                c.sequence = Some(f.id);
                if c.media == seq {
                    c.media = f.id;
                }
            }
            slots[k].value = value.clone();
            c.template_slots = Some(slots.clone());
            target = Some((fork.as_ref().map_or(seq, |f| f.id), slots[k].clone()));
            Ok::<(), TemplateEditError>(())
        })?;
        if let Some(f) = fork {
            work.timelines.push(f);
        }
        let Some((seq, s)) = target else { return Err(TitleTemplateError::SlotNotFound.into()) };
        let Some(ti) = work.timelines.iter().position(|t| t.id == seq) else {
            return Err(TitleTemplateError::SlotNotFound.into());
        };
        if let SlotValue::Media { path, bookmark } = &value {
            let media_id = import_media(&mut work.media, path, bookmark.as_ref(), ids);
            work.timelines[ti].point_layer_at_media(s.layer, media_id)?;
        } else {
            work.timelines[ti].set_slot(s.layer, s.graphics_layer, &s.path, &value)?;
        }
        *self = work;
        Ok(())
    }

    fn auto_detect_animation_zones(&mut self, clip: Id) -> Result<(), TemplateEditError> {
        self.modify_clip_for_zones(clip, |c| {
            let Some(mut z) = detected_zones(c) else { return Err(TitleTemplateError::NoKeyframes.into()) };
            if let Some(old) = &c.zones {
                z.middle = old.middle;
                z.design_duration = old.design_duration;
            }
            c.zones = Some(z);
            Ok::<(), TemplateEditError>(())
        })
    }
}

/// The media item for the file at `path` (already in the project: that one; else a new item, named after the file).
fn import_media(
    media: &mut sq_core_model::CowVec<sq_core_model::MediaRef>,
    path: &str,
    bookmark: Option<&Vec<u8>>,
    ids: &mut dyn IdSource,
) -> Id {
    if let Some(m) = media.iter().find(|m| m.path == path) {
        return m.id;
    }
    let name =
        std::path::Path::new(path).file_stem().map_or_else(|| path.to_string(), |n| n.to_string_lossy().into_owned());
    let mut item = sq_core_model::MediaRef::new(ids.next_id(), &name, path, sq_core_model::MediaFingerprint::new(0));
    item.bookmark = bookmark.cloned();
    let id = item.id;
    media.push(item);
    id
}

/// The content with fresh ids for the inner sequence, every track, clip, transition, link and bundle, and the slots
/// pointing at the new layer ids (slot ids stay, so callers can address them by the template's slot ids).
// Swift: TitleTemplate.swift `instantiated()`
fn instantiated(template: &TitleTemplate, ids: &mut dyn IdSource) -> (Timeline, Vec<TemplateSlot>) {
    let (inner, clip_map) = template.content.copy_with_fresh_ids_mapped(ids);
    let slots = template
        .slots
        .iter()
        .map(|s| {
            let mut s = s.clone();
            s.layer = clip_map.get(&s.layer).copied().unwrap_or(s.layer);
            s
        })
        .collect();
    (inner, slots)
}

/// Zones auto-detected from a clip's keyframes (transform, opacity, volume, effect parameters); `None` without keys
/// (Swift `Clip.detectedZones`).
pub fn detected_zones(c: &Clip) -> Option<AnimationZones> {
    AnimationZones::detect(&keyframe_times(c), c.timeline().duration, ZoneMiddle::Hold, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{GeneratorRef, GraphicsContent, GraphicsDocument, GraphicsLayer, SequenceFormat, ShapeKind};
    use sq_core_time::SequentialIds;

    fn s(x: i64) -> Time {
        Time::new(x, 1)
    }

    fn ms(x: i64) -> Time {
        Time::new(x, 1000)
    }

    fn cid(n: u128) -> Id {
        Id::from_u128(n)
    }

    /// Fresh ids far from the fixed ids of the fixtures.
    struct Fresh(u128);
    impl IdSource for Fresh {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128(self.0)
        }
    }

    fn fresh() -> Fresh {
        Fresh(10_000)
    }

    fn text_payload(text: &str) -> Vec<u8> {
        let v = serde_json::json!({"template": {"text": text, "name": "T",
            "style": {"fontName": "Inter", "size": 80.0, "color": {"red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0}}}});
        serde_json::to_vec(&v).unwrap()
    }

    fn payload_object(c: &Clip) -> serde_json::Value {
        serde_json::from_slice(&c.generator.as_ref().unwrap().payload).unwrap()
    }

    fn layer(n: u128, kind: &str, payload: Vec<u8>, start: Time, duration: Time, keys: &[Time]) -> Clip {
        let mut c =
            Clip::new(cid(n), kind, cid(n + 500), TrackKind::Video, TimeRange::new(Time::ZERO, duration), start);
        c.generator = Some(GeneratorRef { kind: kind.to_string(), payload, payload_version: 1 });
        for (i, k) in keys.iter().enumerate() {
            c.animation.opacity.track.keys.push(sq_core_time::Keyframe::new(cid(900 + i as u128), *k, 1.0));
        }
        c
    }

    /// Host sequence: three layers at 10 s (two texts, one shape) on V1-V3, plus an empty V4 to apply onto.
    fn host() -> (Project, Id, Vec<Id>, Id) {
        let a = layer(1, "text", text_payload("Title"), s(10), s(5), &[Time::ZERO, ms(500), ms(4500), s(5)]);
        let b = layer(2, "text", text_payload("Subtitle"), s(10), s(5), &[Time::ZERO, s(1)]);
        let c = layer(3, "shape", b"{}".to_vec(), s(10), s(5), &[]);
        let mut ids = fresh();
        let mut tracks: Vec<Track> = Vec::new();
        for (i, x) in [a, b, c].into_iter().enumerate() {
            let mut t = Track::new(cid(60 + i as u128), TrackKind::Video);
            t.overwrite(x, &mut ids).unwrap();
            tracks.push(t);
        }
        tracks.push(Track::new(cid(64), TrackKind::Video));
        let tl = Timeline::new(cid(50), "S", SequenceFormat::new(Time::new(1, 30)), tracks);
        (Project::new(cid(999), "P", vec![], vec![tl]), cid(50), vec![cid(1), cid(2), cid(3)], cid(64))
    }

    fn template() -> TitleTemplate {
        let (p, tl, ids, _) = host();
        TitleTemplate::capture(&ids, tl, &p, "Intro", &[], &mut fresh()).unwrap()
    }

    fn placed(p: &Project, id: Id) -> Clip {
        p.timelines
            .iter()
            .flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter()))
            .find(|c| c.id == id)
            .unwrap()
            .clone()
    }

    fn inner_text(p: &Project, c: &Clip, layer: Id) -> Option<String> {
        let inner = p.timeline(c.sequence.unwrap()).unwrap();
        let l = inner.tracks.iter().flat_map(|t| t.clips().iter()).find(|x| x.id == layer)?;
        payload_object(l)["template"]["text"].as_str().map(str::to_string)
    }

    #[test]
    fn capture_makes_one_snapshot_from_zero() {
        let t = template();
        assert_eq!(t.duration(), s(5));
        let kinds: Vec<_> = t.layers().iter().map(|l| l.kind).collect();
        assert_eq!(
            kinds,
            vec![
                sq_core_model::TemplateLayerKind::Text,
                sq_core_model::TemplateLayerKind::Text,
                sq_core_model::TemplateLayerKind::Shape
            ]
        );
        assert!(t.content.tracks.iter().all(|tr| tr.clips().iter().all(|c| c.start == Time::ZERO)));
        assert_eq!(t.slots.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(), vec!["Text 1", "Text 2"]);
        assert_eq!(
            t.slots.iter().map(|x| x.value.clone()).collect::<Vec<_>>(),
            vec![SlotValue::Text("Title".into()), SlotValue::Text("Subtitle".into())]
        );
        // Zones from the first/last keys of all layers.
        assert_eq!(t.zones.intro_end, s(1));
        assert_eq!(t.zones.outro_start(t.duration()), ms(4500));
        assert_eq!(t.zones.design_duration, Some(s(5)));
    }

    #[test]
    fn capture_refuses_empty_and_unknown() {
        let (p, tl, _, _) = host();
        assert_eq!(
            TitleTemplate::capture(&[cid(77)], tl, &p, "X", &[], &mut fresh()).err(),
            Some(EditError::ClipNotFound)
        );
        assert_eq!(TitleTemplate::capture(&[], tl, &p, "X", &[], &mut fresh()).err(), Some(EditError::EmptyClip));
    }

    #[test]
    fn codable_round_trip() {
        let mut t = template();
        let l = t.layers()[0].clip;
        for (n, kind, path, value) in [
            (
                "Color",
                TemplateSlotKind::Color,
                "template.style.color",
                SlotValue::Color { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 },
            ),
            ("Font", TemplateSlotKind::Font, "template.style.fontName", SlotValue::Font("Futura".into())),
            ("Size", TemplateSlotKind::Number, "template.style.size", SlotValue::Number(120.0)),
        ] {
            t.slots.push(TemplateSlot {
                id: cid(800),
                name: n.into(),
                kind,
                layer: l,
                graphics_layer: None,
                path: path.into(),
                value,
            });
        }
        let back: TitleTemplate = serde_json::from_slice(&serde_json::to_vec(&t).unwrap()).unwrap();
        assert_eq!(back, t);
        assert_eq!(TitleTemplate::FORMAT_VERSION, 6);
    }

    #[test]
    fn apply_places_one_nested_clip_with_slot_values() {
        let t = template();
        let (mut p, tl, _, v4) = host();
        let mut ids = fresh();
        let before = p.timelines.len();
        let values = BTreeMap::from([
            (t.slots[0].id, SlotValue::Text("Hello".into())),
            (t.slots[1].id, SlotValue::Text("World".into())),
        ]);
        let id = p.apply_title_template(&t, tl, v4, s(20), None, &values, &mut ids).unwrap();
        assert_eq!(p.timelines.len(), before + 1);
        let c = placed(&p, id);
        assert!(c.start == s(20) && c.timeline().duration == s(5));
        assert_eq!(c.zones.as_ref(), Some(&t.zones));
        let got: Vec<SlotValue> = c.template_slots.as_ref().unwrap().iter().map(|x| x.value.clone()).collect();
        assert_eq!(got, vec![SlotValue::Text("Hello".into()), SlotValue::Text("World".into())]);
        let layers: Vec<Id> = c.template_slots.as_ref().unwrap().iter().map(|x| x.layer).collect();
        assert_eq!(inner_text(&p, &c, layers[0]), Some("Hello".into()));
        assert_eq!(inner_text(&p, &c, layers[1]), Some("World".into()));
        // Layer ids are fresh: applying twice never shares a clip id.
        let id2 = p.apply_title_template(&t, tl, v4, s(30), None, &BTreeMap::new(), &mut ids).unwrap();
        let ids_of = |c: &Clip| -> BTreeSet<Id> {
            p.timeline(c.sequence.unwrap())
                .unwrap()
                .tracks
                .iter()
                .flat_map(|tr| tr.clips().iter().map(|x| x.id))
                .collect()
        };
        let (ids1, ids2) = (ids_of(&c), ids_of(&placed(&p, id2)));
        assert!(ids1.is_disjoint(&ids2));
        let template_ids: BTreeSet<Id> =
            t.content.tracks.iter().flat_map(|tr| tr.clips().iter().map(|x| x.id)).collect();
        assert!(ids1.is_disjoint(&template_ids));
    }

    #[test]
    fn apply_with_longer_duration() {
        let t = template();
        let (mut p, tl, _, v4) = host();
        let id = p.apply_title_template(&t, tl, v4, s(20), Some(s(12)), &BTreeMap::new(), &mut fresh()).unwrap();
        assert_eq!(placed(&p, id).timeline().duration, s(12));
    }

    #[test]
    fn apply_refuses_a_locked_or_audio_track_and_a_missing_one() {
        let t = template();
        let (mut p, tl, _, v4) = host();
        let i = p.timelines.iter().position(|x| x.id == tl).unwrap();
        p.timelines[i].tracks[3].is_locked = true;
        let before = p.clone();
        let r = p.apply_title_template(&t, tl, v4, s(20), None, &BTreeMap::new(), &mut fresh());
        assert_eq!(r, Err(EditError::TrackLocked.into()));
        assert_eq!(p, before);
        let r = p.apply_title_template(&t, tl, cid(12345), s(20), None, &BTreeMap::new(), &mut fresh());
        assert_eq!(r, Err(EditError::ClipNotFound.into()));
    }

    #[test]
    fn set_slot_replaces_the_text() {
        let t = template();
        let (mut p, tl, _, v4) = host();
        let mut ids = fresh();
        let id = p.apply_title_template(&t, tl, v4, s(20), None, &BTreeMap::new(), &mut ids).unwrap();
        let base = p.clone();
        p.set_template_slot(t.slots[1].id, SlotValue::Text("New".into()), id, &mut ids).unwrap();
        let c = placed(&p, id);
        assert_eq!(c.template_slots.as_ref().unwrap()[1].value, SlotValue::Text("New".into()));
        let layer_id = c.template_slots.as_ref().unwrap()[1].layer;
        assert_eq!(inner_text(&p, &c, layer_id), Some("New".into()));
        assert_ne!(p, base);
        // A slot the clip does not have.
        assert_eq!(
            p.set_template_slot(cid(31337), SlotValue::Text("x".into()), id, &mut ids),
            Err(TitleTemplateError::SlotNotFound.into())
        );
    }

    #[test]
    fn editing_a_copy_forks_its_inner_sequence() {
        let t = template();
        let (mut p, tl, _, v4) = host();
        let mut ids = fresh();
        let id = p.apply_title_template(&t, tl, v4, s(20), None, &BTreeMap::new(), &mut ids).unwrap();
        // A copy of the applied clip (same inner sequence) further along the same track.
        let mut copy = placed(&p, id);
        copy.id = cid(4000);
        copy.start = s(40);
        let i = p.timelines.iter().position(|x| x.id == tl).unwrap();
        p.timelines[i].tracks[3].overwrite(copy.clone(), &mut ids).unwrap();
        let seq0 = copy.sequence.unwrap();
        p.set_template_slot(t.slots[1].id, SlotValue::Text("New".into()), copy.id, &mut ids).unwrap();
        let (a, b) = (placed(&p, id), placed(&p, copy.id));
        assert_eq!(a.sequence, Some(seq0));
        assert_ne!(b.sequence, Some(seq0));
        assert_ne!(a.template_slots.as_ref().unwrap()[1].value, SlotValue::Text("New".into()));
        assert_eq!(b.template_slots.as_ref().unwrap()[1].value, SlotValue::Text("New".into()));
        assert_eq!(inner_text(&p, &a, a.template_slots.as_ref().unwrap()[1].layer), Some("Subtitle".into()));
        assert_eq!(inner_text(&p, &b, b.template_slots.as_ref().unwrap()[1].layer), Some("New".into()));
        // A second edit of the (now unshared) copy keeps its sequence.
        p.set_template_slot(t.slots[1].id, SlotValue::Text("Newer".into()), copy.id, &mut ids).unwrap();
        assert_eq!(placed(&p, copy.id).sequence, b.sequence);
        assert_eq!(p.timelines.len(), 3);
    }

    #[test]
    fn colour_font_and_number_slots() {
        let mut t = template();
        let l = t.layers()[0].clip;
        let slot = |n: u128, name: &str, kind, path: &str, value| TemplateSlot {
            id: cid(n),
            name: name.into(),
            kind,
            layer: l,
            graphics_layer: None,
            path: path.into(),
            value,
        };
        let colour = slot(
            801,
            "Color",
            TemplateSlotKind::Color,
            "template.style.color",
            SlotValue::Color { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 },
        );
        let font =
            slot(802, "Font", TemplateSlotKind::Font, "template.style.fontName", SlotValue::Font("Inter".into()));
        let size = slot(803, "Size", TemplateSlotKind::Number, "template.style.size", SlotValue::Number(80.0));
        t.slots.extend([colour.clone(), font.clone(), size.clone()]);
        let (mut p, tl, _, v4) = host();
        let values = BTreeMap::from([
            (colour.id, SlotValue::Color { red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5 }),
            (font.id, SlotValue::Font("Futura".into())),
            (size.id, SlotValue::Number(120.0)),
        ]);
        let id = p.apply_title_template(&t, tl, v4, s(20), None, &values, &mut fresh()).unwrap();
        let c = placed(&p, id);
        let inner = p.timeline(c.sequence.unwrap()).unwrap();
        let first = payload_object(&inner.tracks[0].clips()[0]);
        let style = &first["template"]["style"];
        assert_eq!(style["fontName"], "Futura");
        assert_eq!(style["size"].as_f64(), Some(120.0));
        assert_eq!(style["color"]["red"].as_f64(), Some(1.0));
        assert_eq!(style["color"]["green"].as_f64(), Some(0.0));
        assert_eq!(style["color"]["alpha"].as_f64(), Some(0.5));
    }

    #[test]
    fn slot_with_a_missing_path_errors() {
        let mut t = template();
        t.slots = vec![TemplateSlot {
            id: cid(810),
            name: "X".into(),
            kind: TemplateSlotKind::Text,
            layer: t.layers()[0].clip,
            graphics_layer: None,
            path: "nope.text".into(),
            value: SlotValue::Text("a".into()),
        }];
        let (mut p, tl, _, v4) = host();
        let values = BTreeMap::from([(cid(810), SlotValue::Text("b".into()))]);
        let r = p.apply_title_template(&t, tl, v4, s(20), None, &values, &mut fresh());
        assert_eq!(r, Err(TitleTemplateError::SlotPathNotFound("nope.text".into()).into()));
    }

    // MARK: Graphics clips (TitleTemplateGraphicsTests, TitleTemplateFormatTests)

    fn text_ref(text: &str) -> GeneratorRef {
        GeneratorRef { kind: "text".into(), payload: text_payload(text), payload_version: 1 }
    }

    fn text_of(l: Option<&GraphicsLayer>) -> Option<String> {
        let GraphicsContent::Text { generator } = &l?.content else { return None };
        let v: serde_json::Value = serde_json::from_slice(&generator.payload).ok()?;
        v["template"]["text"].as_str().map(str::to_string)
    }

    /// A graphics clip with a title, a box and a subtitle layer on V1, and an empty V2.
    fn graphics_host() -> (Project, Id, Id, [Id; 3], Id) {
        let layers = [
            GraphicsLayer::new(cid(21), "Title", GraphicsContent::Text { generator: text_ref("Title") }),
            GraphicsLayer::new(cid(22), "Box", GraphicsContent::Shape { kind: ShapeKind::Rectangle }),
            GraphicsLayer::new(cid(23), "Sub", GraphicsContent::Text { generator: text_ref("Sub") }),
        ];
        let mut c = Clip::new(cid(20), "g", cid(20), TrackKind::Video, TimeRange::new(Time::ZERO, s(5)), s(10));
        c.generator = Some(GeneratorRef::graphics_clip());
        c.set_graphics(Some(GraphicsDocument { layers: layers.to_vec(), groups: vec![] }));
        let mut src = Track::new(cid(60), TrackKind::Video);
        src.overwrite(c, &mut fresh()).unwrap();
        let dst = Track::new(cid(61), TrackKind::Video);
        let tl = Timeline::new(cid(50), "S", SequenceFormat::new(Time::new(1, 30)), vec![src, dst]);
        (Project::new(cid(999), "P", vec![], vec![tl]), cid(50), cid(20), [cid(21), cid(22), cid(23)], cid(61))
    }

    fn inner_doc(p: &Project, placed_id: Id) -> GraphicsDocument {
        let c = placed(p, placed_id);
        let seq = p.timeline(c.sequence.unwrap()).unwrap();
        seq.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.is_graphics()).unwrap().graphics().unwrap().clone()
    }

    #[test]
    fn capture_makes_slots_for_text_layers_of_graphics_clips() {
        let (p, tl, id, layers, _) = graphics_host();
        let t = TitleTemplate::capture(&[id], tl, &p, "G", &[], &mut fresh()).unwrap();
        assert_eq!(t.slots.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(), vec!["Text 1", "Text 2"]);
        assert_eq!(
            t.slots.iter().map(|x| x.graphics_layer).collect::<Vec<_>>(),
            vec![Some(layers[0]), Some(layers[2])]
        );
        assert!(t.slots.iter().all(|x| x.layer == id && x.path == "template.text"));
        assert_eq!(
            t.slots.iter().map(|x| x.value.clone()).collect::<Vec<_>>(),
            vec![SlotValue::Text("Title".into()), SlotValue::Text("Sub".into())]
        );
    }

    #[test]
    fn apply_and_set_rewrite_the_graphics_layer() {
        let (p0, tl, id, layers, dst) = graphics_host();
        let mut ids = fresh();
        let t = TitleTemplate::capture(&[id], tl, &p0, "G", &[], &mut ids).unwrap();
        let mut p = p0.clone();
        let values = BTreeMap::from([(t.slots[0].id, SlotValue::Text("Hello".into()))]);
        let placed_id = p.apply_title_template(&t, tl, dst, s(20), None, &values, &mut ids).unwrap();
        assert_eq!(text_of(inner_doc(&p, placed_id).layer(layers[0])), Some("Hello".into()));
        assert_eq!(text_of(inner_doc(&p, placed_id).layer(layers[2])), Some("Sub".into()));
        let slot = placed(&p, placed_id).template_slots.unwrap()[1].clone();
        let before = p.clone();
        p.set_template_slot(slot.id, SlotValue::Text("World".into()), placed_id, &mut ids).unwrap();
        assert_eq!(text_of(inner_doc(&p, placed_id).layer(layers[2])), Some("World".into()));
        assert_eq!(text_of(inner_doc(&p, placed_id).layer(layers[0])), Some("Hello".into()));
        assert_ne!(p, before);
        // The source graphics clip is untouched.
        let src = placed(&p, id);
        assert_eq!(text_of(src.graphics().unwrap().layer(layers[0])), Some("Title".into()));
    }

    #[test]
    fn a_missing_graphics_layer_errors() {
        let (p0, tl, id, _, dst) = graphics_host();
        let mut t = TitleTemplate::capture(&[id], tl, &p0, "G", &[], &mut fresh()).unwrap();
        t.slots[0].graphics_layer = Some(cid(31337));
        let mut p = p0;
        let values = BTreeMap::from([(t.slots[0].id, SlotValue::Text("x".into()))]);
        let r = p.apply_title_template(&t, tl, dst, s(20), None, &values, &mut fresh());
        assert_eq!(r, Err(TitleTemplateError::SlotPathNotFound("template.text".into()).into()));
    }

    #[test]
    fn plain_template_stays_format_1_and_graphics_template_is_format_2() {
        let (p, tl, id, _, _) = graphics_host();
        let g = TitleTemplate::capture(&[id], tl, &p, "G", &[], &mut fresh()).unwrap();
        assert_eq!(serde_json::to_value(&g).unwrap()["formatVersion"], 2);
        let mut plain = g.clone();
        plain.slots = vec![TemplateSlot {
            id: cid(820),
            name: "T".into(),
            kind: TemplateSlotKind::Text,
            layer: id,
            graphics_layer: None,
            path: "template.text".into(),
            value: SlotValue::Text("x".into()),
        }];
        assert_eq!(serde_json::to_value(&plain).unwrap()["formatVersion"], 1);
        plain.slots = vec![];
        assert_eq!(serde_json::to_value(&plain).unwrap()["formatVersion"], 1);
    }

    #[test]
    fn an_older_build_refuses_a_newer_format() {
        let (p, tl, id, _, _) = graphics_host();
        let g = TitleTemplate::capture(&[id], tl, &p, "G", &[], &mut fresh()).unwrap();
        let mut v = serde_json::to_value(&g).unwrap();
        v["formatVersion"] = serde_json::json!(TitleTemplate::FORMAT_VERSION + 1);
        let err = serde_json::from_value::<TitleTemplate>(v).unwrap_err().to_string();
        assert!(err.contains("NewerFormat"), "{err}");
    }

    #[test]
    fn reorder_keeps_slots_and_delete_breaks_them_cleanly() {
        let (p0, tl, id, layers, dst) = graphics_host();
        let mut ids = fresh();
        let t = TitleTemplate::capture(&[id], tl, &p0, "G", &[], &mut ids).unwrap();
        let mut p = p0;
        let placed_id = p.apply_title_template(&t, tl, dst, s(20), None, &BTreeMap::new(), &mut ids).unwrap();
        let slot_id = placed(&p, placed_id).template_slots.unwrap()[1].id;
        let seq = placed(&p, placed_id).sequence.unwrap();
        fn edit_doc(p: &mut Project, seq: Id, f: impl Fn(&mut GraphicsDocument)) {
            let ti = p.timelines.iter().position(|t| t.id == seq).unwrap();
            for i in 0..p.timelines[ti].tracks.len() {
                let clips: Vec<Clip> = p.timelines[ti].tracks[i].clips().to_vec();
                for mut gc in clips.into_iter().filter(Clip::is_graphics) {
                    let mut d = gc.graphics().unwrap().clone();
                    f(&mut d);
                    gc.set_graphics(Some(d));
                    p.timelines[ti].tracks[i].replace(gc);
                }
            }
        }
        let mut reordered = p.clone();
        edit_doc(&mut reordered, seq, |d| d.layers.reverse());
        reordered.set_template_slot(slot_id, SlotValue::Text("New".into()), placed_id, &mut ids).unwrap();
        let doc = reordered
            .timeline(seq)
            .unwrap()
            .tracks
            .iter()
            .flat_map(|t| t.clips().iter())
            .find(|c| c.is_graphics())
            .unwrap()
            .graphics()
            .unwrap()
            .clone();
        assert_eq!(text_of(doc.layer(layers[2])), Some("New".into()));
        assert_eq!(text_of(doc.layer(layers[0])), Some("Title".into()));

        let mut deleted = p;
        edit_doc(&mut deleted, seq, |d| d.layers.retain(|l| l.id != layers[2]));
        let before = deleted.clone();
        let r = deleted.set_template_slot(slot_id, SlotValue::Text("x".into()), placed_id, &mut ids);
        assert_eq!(r, Err(TitleTemplateError::SlotPathNotFound("template.text".into()).into()));
        assert_eq!(deleted, before);
    }

    #[test]
    fn auto_detect_zones_needs_keys_and_keeps_design_duration() {
        let (mut p, tl, ids, _) = host();
        // Clip 1 has keys at 0, 0.5, 4.5, 5 s: intro ends at 0.5 s, outro starts at 4.5 s.
        p.auto_detect_animation_zones(ids[0]).unwrap();
        let z = placed(&p, ids[0]).zones.unwrap();
        assert_eq!(z.intro_end, ms(500));
        assert_eq!(z.outro_start(s(5)), ms(4500));
        assert_eq!(z.design_duration, None);
        // The shape layer has no keys.
        assert_eq!(p.auto_detect_animation_zones(ids[2]), Err(TitleTemplateError::NoKeyframes.into()));
        assert_eq!(p.auto_detect_animation_zones(cid(777)), Err(EditError::ClipNotFound.into()));
        let _ = (tl, SequentialIds::default());
    }

    fn fd() -> Time {
        Time::new(1, 30)
    }

    #[test]
    fn a_longer_or_shorter_placement_keeps_intro_and_outro_at_their_own_speed() {
        let t = template(); // design 5 s, intro 1 s, outro 0.5 s
        assert_eq!((t.duration(), t.zones.outro_length), (s(5), ms(500)));
        for len in [s(10), ms(2500)] {
            let (mut p, tl, _, v4) = host();
            let id = p.apply_title_template(&t, tl, v4, s(20), Some(len), &BTreeMap::new(), &mut fresh()).unwrap();
            let c = placed(&p, id);
            assert_eq!(c.duration(), len);
            assert_eq!(c.inner_time(len - ms(500), fd()), s(5) - ms(500), "outro starts 0.5 s before the end, 1:1");
            assert_eq!(c.inner_time(len - ms(100), fd()), s(5) - ms(100));
            assert_eq!(c.inner_time(ms(300), fd()), ms(300), "intro 1:1 from the start");
        }
    }

    #[test]
    fn a_text_animator_intro_keeps_its_length_when_the_clip_is_stretched() {
        let (p, tl, ids, v4) = host();
        let only_text = [ids[1]]; // "Subtitle", keys at 0 and 1 s: intro 1 s
        let t = TitleTemplate::capture(&only_text, tl, &p, "Anim", &[ms(800)], &mut fresh()).unwrap();
        assert_eq!(t.zones.intro_end, s(1));
        let mut p = p;
        let id =
            p.apply_title_template(&t, tl, v4, s(20), Some(t.duration() * 2), &BTreeMap::new(), &mut fresh()).unwrap();
        let c = placed(&p, id);
        assert_eq!(c.inner_time(ms(800), fd()), ms(800));
        assert_eq!(c.inner_time(s(1), fd()), s(1));
    }

    #[test]
    fn a_requested_duration_is_clamped_to_intro_plus_outro_plus_one_frame() {
        let t = template();
        let (mut p, tl, _, v4) = host();
        let id = p.apply_title_template(&t, tl, v4, s(20), Some(ms(100)), &BTreeMap::new(), &mut fresh()).unwrap();
        assert_eq!(placed(&p, id).duration(), s(1) + ms(500) + fd());
    }

    #[test]
    fn a_single_emoji_text_layer_becomes_an_emoji_slot() {
        let (mut p, tl, ids, _) = host();
        let e = layer(20, "text", text_payload("\u{1F600}"), s(10), s(5), &[]);
        let mut track = Track::new(cid(70), TrackKind::Video);
        track.overwrite(e, &mut fresh()).unwrap();
        p.edit(tl, |t| {
            t.tracks.push(track);
            Ok(())
        })
        .unwrap();
        let mut all = ids[..2].to_vec();
        all.push(cid(20));
        let t = TitleTemplate::capture(&all, tl, &p, "E", &[], &mut fresh()).unwrap();
        let kinds: Vec<_> = t.slots.iter().map(|x| x.kind).collect();
        assert_eq!(kinds, [TemplateSlotKind::Text, TemplateSlotKind::Text, TemplateSlotKind::Emoji]);
        assert_eq!(t.written_format_version(), 6);
        let kinds: Vec<_> = t.fields().iter().map(|f| f.kind).collect();
        assert_eq!(kinds.last(), Some(&sq_core_model::TemplateFieldKind::Duration));
        assert_eq!(kinds.iter().filter(|k| **k == sq_core_model::TemplateFieldKind::Text).count(), 2);
    }

    #[test]
    fn an_image_layer_is_saved_by_path_and_imported_on_apply() {
        let (mut p, tl, _, _) = host();
        let media =
            sq_core_model::MediaRef::new(cid(300), "logo", "/art/logo.png", sq_core_model::MediaFingerprint::new(1));
        p.media.push(media);
        let mut img = Clip::new(cid(30), "logo", cid(300), TrackKind::Video, TimeRange::new(Time::ZERO, s(5)), s(10));
        img.is_still = true;
        let mut track = Track::new(cid(71), TrackKind::Video);
        track.overwrite(img, &mut fresh()).unwrap();
        p.edit(tl, |t| {
            t.tracks.push(track);
            Ok(())
        })
        .unwrap();
        let t = TitleTemplate::capture(&[cid(30)], tl, &p, "Logo", &[], &mut fresh()).unwrap();
        assert_eq!(t.slots.len(), 1);
        assert_eq!(t.slots[0].kind, TemplateSlotKind::Image);
        assert_eq!(t.slots[0].value, SlotValue::Media { path: "/art/logo.png".into(), bookmark: None });
        // Another project that does not have the file.
        let (mut other, otl, _, ov4) = host();
        assert!(other.media.is_empty());
        let id = other.apply_title_template(&t, otl, ov4, s(0), None, &BTreeMap::new(), &mut fresh()).unwrap();
        let imported = other.media.iter().find(|m| m.path == "/art/logo.png").expect("imported").id;
        let inner = other.timeline(placed(&other, id).sequence.unwrap()).unwrap();
        assert_eq!(inner.tracks[0].clips()[0].media, imported);
        // Swapping the image later reuses an existing item or imports a new one.
        let slot = placed(&other, id).template_slots.unwrap()[0].id;
        other
            .set_template_slot(
                slot,
                SlotValue::Media { path: "/art/other.png".into(), bookmark: None },
                id,
                &mut fresh(),
            )
            .unwrap();
        assert_eq!(other.media.len(), 2);
    }
}
