// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SequenceConform.swift
//! How a picture clip is conformed when its sequence changes frame size (Sequence > Change Format) and the project
//! verbs behind it. Positions are offsets from the canvas center in sequence pixels, so a uniform factor on position and
//! scale maps the old frame onto the new one and keeps the subject center. Pure maths; the destructive edit is one
//! `Project` mutation (undo = snapshot).

use serde::{Deserialize, Serialize};
use sq_core_model::{
    AnimatedProperty, CaptionTrack, Clip, ClipEffect, EditError, Project, SequenceFormat, SourcePatch, Timeline,
    TrackKind,
};
use sq_core_time::{Id, IdSource, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// Kind of the text generator (Swift `GeneratorRef.text`); the text crate owns the payload.
///
/// shortcut: copied literal until the graphics crate exports the constant.
pub(crate) const TEXT_KIND: &str = "text";

/// How a picture clip is conformed when its sequence changes frame size.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConformMode {
    /// The whole old frame stays visible inside the new one (bars on one axis).
    Fit,
    /// The old frame covers the new one, cropping one axis; the center stays the center.
    Fill,
}

impl ConformMode {
    /// Every mode, in menu order.
    pub const ALL: [ConformMode; 2] = [ConformMode::Fit, ConformMode::Fill];

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            ConformMode::Fit => "Fit (show everything, bars)",
            ConformMode::Fill => "Fill (crop to the new frame)",
        }
    }
}

/// One of the shapes Change Format offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AspectPreset {
    /// Label such as "9:16".
    pub name: &'static str,
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
}

/// A text clip's block (the text, or the box of area text) at Scale 100 %, in sequence pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextBlock {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
    /// Ink center minus block center (shadow or stroke make the raster lopsided). The layer scales about the raster (ink)
    /// center, so the block center moves by `ink_offset * (1 - scale)`.
    pub ink_offset: Vec2,
}

impl TextBlock {
    /// A block whose ink is centered.
    pub fn new(width: f64, height: f64) -> TextBlock {
        TextBlock { width, height, ink_offset: Vec2::ZERO }
    }
}

/// Measures a text clip's block; `None` = unknown. The core cannot lay out text, so the caller measures it.
pub type TextSize<'a> = &'a dyn Fn(&Clip) -> Option<TextBlock>;

/// Retargets a sequence to a new frame size and conforms every clip.
pub struct SequenceConform;

impl SequenceConform {
    /// The shapes Change Format offers, at 1080 class sizes.
    pub const ASPECT_PRESETS: [AspectPreset; 5] = [
        AspectPreset { name: "9:16", width: 1080, height: 1920 },
        AspectPreset { name: "16:9", width: 1920, height: 1080 },
        AspectPreset { name: "4:5", width: 1080, height: 1350 },
        AspectPreset { name: "1:1", width: 1080, height: 1080 },
        AspectPreset { name: "4:3", width: 1440, height: 1080 },
    ];

    /// Title safe inset per side, as a fraction of the frame (the title safe area is 80 % of the frame).
    pub const TITLE_SAFE_INSET: f64 = 0.1;

    /// Uniform factor that maps the old frame into the new one: fit = whole old frame visible, fill = new frame covered.
    pub fn frame_factor(old: &SequenceFormat, new: &SequenceFormat, mode: ConformMode) -> f64 {
        if old.display_width() <= 0 || old.height <= 0 || new.display_width() <= 0 || new.height <= 0 {
            return 1.0;
        }
        let sx = new.display_width() as f64 / old.display_width() as f64;
        let sy = new.height as f64 / old.height as f64;
        if mode == ConformMode::Fit { sx.min(sy) } else { sx.max(sy) }
    }

    /// Half width and half height of the title safe area, in sequence pixels from the center.
    pub fn safe_half_extent(f: &SequenceFormat) -> Vec2 {
        Vec2::new(
            f.display_width() as f64 * (0.5 - Self::TITLE_SAFE_INSET),
            f.height as f64 * (0.5 - Self::TITLE_SAFE_INSET),
        )
    }

    /// "16:9" when the size has one of the preset shapes, else "W×H".
    pub fn aspect_label(width: i64, height: i64) -> String {
        fn gcd(a: i64, b: i64) -> i64 {
            if b == 0 { a } else { gcd(b, a % b) }
        }
        let g = gcd(width, height).max(1);
        let label = format!("{}:{}", width / g, height / g);
        if Self::ASPECT_PRESETS.iter().any(|p| p.name == label) { label } else { format!("{width}×{height}") }
    }

    /// A picture clip (media, nested sequence) after its frame was scaled by `k`: Scale and Position, values and keys
    /// (with spatial tangents), are multiplied by `k`. Anchor (layer pixels), rotation and effects stay.
    pub fn conform_picture(c: &Clip, k: f64) -> Clip {
        let mut n = c.clone();
        n.animation.position = Self::scaled(&c.animation.position, k, k);
        n.animation.scale = Self::scaled(&c.animation.scale, k, k);
        Self::conform_group_stages(n, k, k)
    }

    /// Group Transform effects (an ungrouped Group's Motion, canvas px) on a new frame: Position and Anchor move with the
    /// canvas by (sx, sy); Scale and Rotation stay, since the clip's own Motion already carries the frame scale.
    fn conform_group_stages(c: Clip, sx: f64, sy: f64) -> Clip {
        if !c.effects.iter().any(|e| e.kind == ClipEffect::GROUP_TRANSFORM_KIND) {
            return c;
        }
        let mut n = c;
        n.effects = n.effects.iter().map(|e| Self::conform_group_stage(e, sx, sy)).collect();
        n
    }

    /// One effect on a new frame: a Group Transform's Position and Anchor scale by (sx, sy); anything else is returned as is.
    pub fn conform_group_stage(e: &ClipEffect, sx: f64, sy: f64) -> ClipEffect {
        if e.kind != ClipEffect::GROUP_TRANSFORM_KIND {
            return e.clone();
        }
        let mut n = e.clone();
        for key in [ClipEffect::GROUP_POSITION_KEY, ClipEffect::GROUP_ANCHOR_KEY] {
            if let Some(p) = e.points.get(key) {
                n.points.insert(key.to_string(), Self::scaled(p, sx, sy));
            }
        }
        n
    }

    /// A text clip on a new frame: Scale is kept (text never grows with a fill), Position moves per axis with the frame (a
    /// lower third stays a lower third). With a known block size the text shrinks to fit the title safe area and an
    /// unanimated position is clamped so the block sits inside it. Animated positions are only scaled (a slide in from off
    /// screen must keep its outside key). Rotation is ignored for the bounds.
    pub fn conform_text(c: &Clip, old: &SequenceFormat, new: &SequenceFormat, block_size: Option<TextBlock>) -> Clip {
        if old.display_width() <= 0 || old.height <= 0 {
            return c.clone();
        }
        let mut n = c.clone();
        let sx = new.display_width() as f64 / old.display_width() as f64;
        let sy = new.height as f64 / old.height as f64;
        n.animation.position = Self::scaled(&c.animation.position, sx, sy);
        n = Self::conform_group_stages(n, sx, sy);
        let Some(block) = block_size.filter(|b| b.width > 0.0 && b.height > 0.0) else { return n };
        let safe = Self::safe_half_extent(new);
        let sc = Self::max_abs_scale(&n.animation.scale);
        let (bw, bh) = (block.width * sc.x / 2.0, block.height * sc.y / 2.0);
        let mut shrink = 1.0_f64;
        if bw > 0.0 {
            shrink = shrink.min(safe.x / bw);
        }
        if bh > 0.0 {
            shrink = shrink.min(safe.y / bh);
        }
        if shrink < 1.0 {
            n.animation.scale = Self::scaled(&n.animation.scale, shrink, shrink);
        }
        // Animated position/scale/anchor are not clamped (a slide in must keep its off-screen key); only the static
        // values are used for the block center offset below.
        if !n.animation.position.is_animated() {
            // Screen block center = position + ink * (1 - scale) - anchor * scale (layer scaled about the raster center,
            // anchor lands on the position).
            let (s, a) = (n.animation.scale.value, n.animation.anchor.value);
            let off =
                Vec2::new(block.ink_offset.x * (1.0 - s.x) - a.x * s.x, block.ink_offset.y * (1.0 - s.y) - a.y * s.y);
            let rx = (safe.x - bw * shrink).max(0.0);
            let ry = (safe.y - bh * shrink).max(0.0);
            let mut p = n.animation.position.value;
            p.x = (p.x + off.x).max(-rx).min(rx) - off.x;
            p.y = (p.y + off.y).max(-ry).min(ry) - off.y;
            n.animation.position.value = p;
        }
        n
    }

    /// `t` with the new frame size and every video clip conformed. Audio clips, solids and other generators stay.
    /// Frame rate and sample rate come from `format` too (callers usually keep them).
    pub fn conformed(
        t: &Timeline,
        format: &SequenceFormat,
        mode: ConformMode,
        overrides: &BTreeMap<Id, ConformMode>,
        text_size: TextSize<'_>,
    ) -> Timeline {
        let mut out = t.clone();
        let old = t.format.clone();
        out.format = format.clone();
        // A platform target belongs to an orientation (vertical vs horizontal loudness group); square counts as vertical.
        if (old.display_width() > old.height) != (format.display_width() > format.height) {
            out.delivery_target = None;
        }
        for tr in out.tracks.iter_mut().filter(|tr| tr.kind == TrackKind::Video) {
            let clips: Vec<Clip> = tr.clips().to_vec();
            for c in clips {
                let n = if let Some(g) = &c.generator {
                    if g.kind != TEXT_KIND {
                        continue;
                    }
                    Self::conform_text(&c, &old, format, text_size(&c))
                } else {
                    let m = overrides.get(&c.id).copied().unwrap_or(mode);
                    Self::conform_picture(&c, Self::frame_factor(&old, format, m))
                };
                if n != c {
                    tr.replace(n);
                }
            }
        }
        out
    }

    /// Multiplies values, keys and spatial tangents by (sx, sy).
    pub fn scaled(p: &AnimatedProperty<Vec2>, sx: f64, sy: f64) -> AnimatedProperty<Vec2> {
        let m = |v: Vec2| Vec2::new(v.x * sx, v.y * sy);
        let mut q = p.clone();
        q.value = m(p.value);
        for k in q.track.keys.iter_mut() {
            k.value = m(k.value);
            k.in_tangent = m(k.in_tangent);
            k.out_tangent = m(k.out_tangent);
        }
        q
    }

    /// Largest scale magnitude per axis the property reaches (its keys when animated, else its value).
    fn max_abs_scale(p: &AnimatedProperty<Vec2>) -> Vec2 {
        let vs: Vec<Vec2> =
            if p.is_animated() { p.track.keys.iter().map(|k| k.value).collect() } else { vec![p.value] };
        let max = |f: fn(&Vec2) -> f64| {
            vs.iter().map(|v| f(v).abs()).fold(None, |m: Option<f64>, x| Some(m.map_or(x, |m| m.max(x))))
        };
        Vec2::new(max(|v| v.x).unwrap_or(1.0), max(|v| v.y).unwrap_or(1.0))
    }
}

/// Project verbs of Change Format (Swift `extension Project` in SequenceConform.swift).
pub trait ProjectSequenceConformExt {
    /// Sequence > Change Format: sets the frame size (rate and sample rate from `format`) and conforms every video clip,
    /// `mode` for all clips unless `overrides` names one. The delivery target is cleared when the orientation flips.
    /// Locked tracks are conformed too (the frame changes for them as well). `InvalidFormat` or `TimelineNotFound`; nothing
    /// changes then. One mutation = one undo step.
    fn change_format(
        &mut self,
        id: Id,
        format: &SequenceFormat,
        mode: ConformMode,
        overrides: &BTreeMap<Id, ConformMode>,
        text_size: TextSize<'_>,
    ) -> Result<(), EditError>;
    /// Sequence > Duplicate as Format: a conformed copy of the sequence, appended to the project (the original is
    /// untouched). Tracks, clips, link groups, transitions, markers and caption tracks/items get fresh ids (transitions
    /// follow their clips, a generator's `media` stays its own id). Default name: "<name> <aspect>", made unique. Returns
    /// the new id.
    #[allow(clippy::too_many_arguments)]
    fn duplicate_sequence(
        &mut self,
        id: Id,
        format: &SequenceFormat,
        mode: ConformMode,
        overrides: &BTreeMap<Id, ConformMode>,
        name: Option<&str>,
        text_size: TextSize<'_>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
}

/// The caption track with a new id and a new id on every item.
///
/// shortcut: goes through JSON because `CaptionTrack::items` is read-only in the model; swap for a model setter.
fn caption_track_with_fresh_ids(ct: &CaptionTrack, ids: &mut dyn IdSource) -> CaptionTrack {
    let Ok(mut v) = serde_json::to_value(ct) else { return ct.clone() };
    v["id"] = serde_json::json!(ids.next_id());
    if let Some(items) = v["items"].as_array_mut() {
        for item in items {
            item["id"] = serde_json::json!(ids.next_id());
        }
    }
    serde_json::from_value(v).unwrap_or_else(|_| ct.clone())
}

/// After tracks were copied with new ids (`map`: old -> new): the patch follows its tracks; one not copied falls back.
fn remap_source_patch(t: &mut Timeline, map: &BTreeMap<Id, Id>) {
    let Some(mut p) = t.source_patch_store.clone() else { return };
    for slot in [&mut p.video, &mut p.audio] {
        slot.track = slot.track.and_then(|id| map.get(&id).copied());
    }
    t.source_patch_store = (p != SourcePatch::default()).then_some(p);
}

impl ProjectSequenceConformExt for Project {
    fn change_format(
        &mut self,
        id: Id,
        format: &SequenceFormat,
        mode: ConformMode,
        overrides: &BTreeMap<Id, ConformMode>,
        text_size: TextSize<'_>,
    ) -> Result<(), EditError> {
        if !format.is_valid() {
            return Err(EditError::InvalidFormat);
        }
        let i = self.timelines.iter().position(|t| t.id == id).ok_or(EditError::TimelineNotFound)?;
        let mut t = SequenceConform::conformed(&self.timelines[i], format, mode, overrides, text_size);
        t.format_locked = true;
        self.timelines[i] = t;
        Ok(())
    }

    fn duplicate_sequence(
        &mut self,
        id: Id,
        format: &SequenceFormat,
        mode: ConformMode,
        overrides: &BTreeMap<Id, ConformMode>,
        name: Option<&str>,
        text_size: TextSize<'_>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        if !format.is_valid() {
            return Err(EditError::InvalidFormat);
        }
        let src = self.timeline(id).ok_or(EditError::TimelineNotFound)?.clone();
        let conformed = SequenceConform::conformed(&src, format, mode, overrides, text_size);

        let mut clip_ids: BTreeMap<Id, Id> = BTreeMap::new();
        let mut link_ids: BTreeMap<Id, Id> = BTreeMap::new();
        let mut copy = conformed.clone();
        copy.id = ids.next_id();
        copy.format_locked = true;
        // Fresh variant ids, so the duplicate's variants are its own (active-variant state, export file names); a variant a
        // nested clip's inner sequence also has keeps its id, so that clip still renders the inner variant.
        let inner_variants: BTreeSet<Id> = conformed
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| t.clips().iter())
            .filter_map(|c| c.sequence)
            .filter_map(|s| self.timeline(s))
            .flat_map(|t| t.variants.iter().map(|v| v.id))
            .collect();
        let variant_ids: BTreeMap<Id, Id> = conformed
            .variants
            .iter()
            .map(|v| (v.id, if inner_variants.contains(&v.id) { v.id } else { ids.next_id() }))
            .collect();
        copy.variants = conformed
            .variants
            .iter()
            .map(|v| {
                let mut v = v.clone();
                v.id = variant_ids[&v.id];
                v
            })
            .collect();
        let mut track_ids: BTreeMap<Id, Id> = BTreeMap::new();
        let mut tracks = Vec::with_capacity(conformed.tracks.len());
        for tr in &conformed.tracks {
            let mut clips: Vec<Clip> = Vec::with_capacity(tr.clips().len());
            for c in tr.clips() {
                let mut n = c.clone();
                n.id = ids.next_id();
                clip_ids.insert(c.id, n.id);
                if c.is_generator() {
                    n.media = n.id;
                }
                if let Some(v) = n.variant_store.as_mut() {
                    v.items = v.items.iter().filter_map(|(k, o)| variant_ids.get(k).map(|k| (*k, o.clone()))).collect();
                }
                if let Some(l) = c.link {
                    n.link = Some(*link_ids.entry(l).or_insert_with(|| ids.next_id()));
                }
                clips.push(n);
            }
            let transitions = tr
                .transitions
                .iter()
                .map(|x| {
                    let mut y = x.clone();
                    y.id = ids.next_id();
                    y.outgoing = x.outgoing.and_then(|c| clip_ids.get(&c).copied());
                    y.incoming = x.incoming.and_then(|c| clip_ids.get(&c).copied());
                    y
                })
                .collect();
            let mut n = tr.clone(); // keeps every track setting (audio role, volume, pan, ...)
            n.id = ids.next_id();
            track_ids.insert(tr.id, n.id);
            let mut k = 0;
            n.map_clips_keeping_timing(|_| {
                k += 1;
                clips[k - 1].clone()
            });
            n.transitions = transitions;
            tracks.push(n);
        }
        copy.tracks = tracks.into();

        copy.remap_picture_masks(&track_ids);
        remap_source_patch(&mut copy, &track_ids);
        copy.remap_attachments(&clip_ids, None, false);
        copy.markers = conformed
            .markers
            .iter()
            .map(|m| {
                let mut m = m.clone();
                m.id = ids.next_id();
                m
            })
            .collect();
        copy.caption_tracks = conformed.caption_tracks.iter().map(|ct| caption_track_with_fresh_ids(ct, ids)).collect();

        let names: BTreeSet<&str> = self.timelines.iter().map(|t| t.name.as_str()).collect();
        // shortcut: `trim` is the Unicode White_Space set; Foundation's whitespacesAndNewlines differs on a few exotic
        // characters, upgrade with a shared helper in sq_core_time::text when a second caller needs one.
        let trimmed = name.map_or("", str::trim);
        let base = if trimmed.is_empty() {
            format!("{} {}", src.name, SequenceConform::aspect_label(format.display_width(), format.height))
        } else {
            trimmed.to_string()
        };
        let mut candidate = base.clone();
        let mut n = 2;
        while names.contains(candidate.as_str()) {
            candidate = format!("{base} {n}");
            n += 1;
        }
        copy.name = candidate;

        let new_id = copy.id;
        self.timelines.push(copy);
        self.normalize_bins();
        Ok(new_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sq_core_model::{CaptionItem, GeneratorRef, Marker, Track, Transition};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn fmt(w: i64, h: i64) -> SequenceFormat {
        let mut f = SequenceFormat::new(fd());
        f.width = w;
        f.height = h;
        f
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    fn close2(a: Vec2, b: Vec2) -> bool {
        close(a.x, b.x) && close(a.y, b.y)
    }

    fn no_text(_: &Clip) -> Option<TextBlock> {
        None
    }

    fn video_clip(ids: &mut SequentialIds, start: i64, scale: Vec2, position: Vec2) -> Clip {
        let mut c =
            Clip::new(ids.next_id(), "v", ids.next_id(), TrackKind::Video, TimeRange::new(Time::ZERO, s(5)), s(start));
        c.animation.scale = AnimatedProperty::new(scale);
        c.animation.position = AnimatedProperty::new(position);
        c
    }

    fn text_clip(ids: &mut SequentialIds, position: Vec2, scale: Vec2) -> Clip {
        let mut c = video_clip(ids, 10, scale, position);
        c.generator = Some(GeneratorRef { kind: TEXT_KIND.into(), payload: b"t".to_vec(), payload_version: 1 });
        c.media = c.id;
        c.name = "Title".into();
        c
    }

    fn project(ids: &mut SequentialIds, clips: Vec<Clip>, audio: Vec<Clip>) -> (Project, Id) {
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        for c in clips {
            assert!(v.overwrite(c, ids).is_ok());
        }
        let mut a = Track::new(ids.next_id(), TrackKind::Audio);
        for c in audio {
            assert!(a.overwrite(c, ids).is_ok());
        }
        let t = Timeline::new(ids.next_id(), "Main", fmt(1920, 1080), vec![v, a]);
        let tid = t.id;
        (Project::new(ids.next_id(), "p", Vec::new(), vec![t]), tid)
    }

    fn change(p: &mut Project, id: Id, f: &SequenceFormat, mode: ConformMode) -> Result<(), EditError> {
        p.change_format(id, f, mode, &BTreeMap::new(), &no_text)
    }

    #[test]
    fn frame_factor_fit_and_fill() {
        let (hd, vert, classic, square) = (fmt(1920, 1080), fmt(1080, 1920), fmt(1440, 1080), fmt(1080, 1080));
        let k = SequenceConform::frame_factor;
        assert!(close(k(&hd, &vert, ConformMode::Fill), 1920.0 / 1080.0));
        assert!(close(k(&hd, &vert, ConformMode::Fit), 1080.0 / 1920.0));
        assert!(close(k(&hd, &classic, ConformMode::Fill), 1.0));
        assert!(close(k(&hd, &classic, ConformMode::Fit), 0.75));
        assert!(close(k(&hd, &square, ConformMode::Fill), 1.0));
        assert!(close(k(&hd, &hd, ConformMode::Fit), 1.0));
        assert!(close(k(&hd, &fmt(3840, 2160), ConformMode::Fit), 2.0));
        assert!(close(k(&hd, &fmt(3840, 2160), ConformMode::Fill), 2.0));
    }

    #[test]
    fn safe_area_is_title_safe_and_presets_cover_five_shapes() {
        let a = SequenceConform::safe_half_extent(&fmt(1080, 1920));
        assert!(close(a.x, 1080.0 * 0.4) && close(a.y, 1920.0 * 0.4));
        let names: Vec<&str> = SequenceConform::ASPECT_PRESETS.iter().map(|p| p.name).collect();
        assert_eq!(names, ["9:16", "16:9", "4:5", "1:1", "4:3"]);
        assert_eq!((SequenceConform::ASPECT_PRESETS[0].width, SequenceConform::ASPECT_PRESETS[0].height), (1080, 1920));
    }

    #[test]
    fn aspect_label_of_custom_size() {
        assert_eq!(SequenceConform::aspect_label(1920, 1080), "16:9");
        assert_eq!(SequenceConform::aspect_label(1080, 1350), "4:5");
        assert_eq!(SequenceConform::aspect_label(1000, 700), "1000×700");
    }

    #[test]
    fn fill_scales_value_position_and_keys() {
        use sq_core_time::{Keyframe, KeyframeTrack};
        let mut ids = SequentialIds::default();
        let mut c = video_clip(&mut ids, 0, Vec2::new(1.0, 1.0), Vec2::new(90.0, -60.0));
        let mut k0 = Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(0.0, 0.0));
        k0.out_tangent = Vec2::new(30.0, 0.0);
        let mut k1 = Keyframe::new(ids.next_id(), s(1), Vec2::new(300.0, 150.0));
        k1.in_tangent = Vec2::new(-30.0, 6.0);
        c.animation.position.track = KeyframeTrack::with_keys(vec![k0, k1]);
        c.animation.scale.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(1.0, 1.0)),
            Keyframe::new(ids.next_id(), s(2), Vec2::new(2.0, 2.0)),
        ]);
        c.animation.anchor = AnimatedProperty::new(Vec2::new(10.0, 20.0));
        c.animation.rotation = AnimatedProperty::new(15.0);
        let (mut p, id) = project(&mut ids, vec![c.clone()], vec![]);
        assert!(change(&mut p, id, &fmt(1080, 1920), ConformMode::Fill).is_ok());
        let t = p.timeline(id).unwrap();
        assert_eq!((t.format.width, t.format.height, t.format.frame_duration), (1080, 1920, fd()));
        let n = &t.tracks[0].clips()[0];
        let k = 1920.0 / 1080.0;
        assert!(close2(n.animation.scale.value, Vec2::new(k, k)));
        assert!(close2(n.animation.position.value, Vec2::new(90.0 * k, -60.0 * k)));
        let keys = &n.animation.position.track.keys;
        assert!(close2(keys[1].value, Vec2::new(300.0 * k, 150.0 * k)));
        assert!(close2(keys[0].out_tangent, Vec2::new(30.0 * k, 0.0)));
        assert!(close2(keys[1].in_tangent, Vec2::new(-30.0 * k, 6.0 * k)));
        assert!(close2(n.animation.scale.track.keys[1].value, Vec2::new(2.0 * k, 2.0 * k)));
        assert_eq!(keys[1].time, s(1));
        assert_eq!(n.animation.anchor, c.animation.anchor);
        assert_eq!(n.animation.rotation, c.animation.rotation);
        assert!(n.id == c.id && n.start == c.start && n.source == c.source);
    }

    #[test]
    fn fit_letterboxes_and_per_clip_override() {
        let mut ids = SequentialIds::default();
        let a = video_clip(&mut ids, 0, Vec2::new(1.0, 1.0), Vec2::ZERO);
        let b = video_clip(&mut ids, 5, Vec2::new(1.0, 1.0), Vec2::ZERO);
        let (mut p, id) = project(&mut ids, vec![a, b.clone()], vec![]);
        let overrides = BTreeMap::from([(b.id, ConformMode::Fill)]);
        assert!(p.change_format(id, &fmt(1080, 1920), ConformMode::Fit, &overrides, &no_text).is_ok());
        let clips = p.timeline(id).unwrap().tracks[0].clips();
        assert!(close(clips[0].animation.scale.value.x, 1080.0 / 1920.0));
        assert!(close(clips[1].animation.scale.value.x, 1920.0 / 1080.0));
    }

    #[test]
    fn audio_clips_and_solids_untouched() {
        let mut ids = SequentialIds::default();
        let mut solid = video_clip(&mut ids, 20, Vec2::new(1.0, 1.0), Vec2::ZERO);
        solid.generator = Some(GeneratorRef { kind: "solid".into(), payload: vec![0, 0, 0], payload_version: 1 });
        solid.media = solid.id;
        let audio = Clip::new(
            ids.next_id(),
            "a",
            ids.next_id(),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, s(5)),
            Time::ZERO,
        );
        let (mut p, id) = project(&mut ids, vec![solid.clone()], vec![audio.clone()]);
        assert!(change(&mut p, id, &fmt(1080, 1350), ConformMode::Fill).is_ok());
        let t = p.timeline(id).unwrap();
        assert_eq!(t.tracks[0].clips()[0], solid);
        assert_eq!(t.tracks[1].clips()[0], audio);
    }

    #[test]
    fn refuses_invalid_and_unknown_without_change() {
        let mut ids = SequentialIds::default();
        let c = video_clip(&mut ids, 0, Vec2::new(1.0, 1.0), Vec2::ZERO);
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        let before = p.clone();
        assert_eq!(change(&mut p, id, &fmt(0, 1920), ConformMode::Fill), Err(EditError::InvalidFormat));
        assert_eq!(
            change(&mut p, ids.next_id(), &fmt(1080, 1920), ConformMode::Fill),
            Err(EditError::TimelineNotFound)
        );
        assert_eq!(p, before);
    }

    #[test]
    fn text_keeps_scale_moves_relatively_and_stays_in_safe_area() {
        let mut ids = SequentialIds::default();
        let c = text_clip(&mut ids, Vec2::new(500.0, 400.0), Vec2::new(1.0, 1.0));
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        let block = |_: &Clip| Some(TextBlock::new(600.0, 100.0));
        assert!(p.change_format(id, &fmt(1080, 1920), ConformMode::Fill, &BTreeMap::new(), &block).is_ok());
        let n = &p.timeline(id).unwrap().tracks[0].clips()[0];
        assert!(close2(n.animation.scale.value, Vec2::new(1.0, 1.0)));
        assert!(close(n.animation.position.value.x, 432.0 - 300.0));
        assert!(close(n.animation.position.value.y, 400.0 * 1920.0 / 1080.0));
    }

    #[test]
    fn oversized_text_shrinks_to_safe_area() {
        let mut ids = SequentialIds::default();
        let c = text_clip(&mut ids, Vec2::ZERO, Vec2::new(1.0, 1.0));
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        let block = |_: &Clip| Some(TextBlock::new(1728.0, 200.0));
        assert!(p.change_format(id, &fmt(1080, 1920), ConformMode::Fit, &BTreeMap::new(), &block).is_ok());
        let n = &p.timeline(id).unwrap().tracks[0].clips()[0];
        assert!(close2(n.animation.scale.value, Vec2::new(0.5, 0.5)));
        assert!(close2(n.animation.position.value, Vec2::ZERO));
    }

    #[test]
    fn text_without_size_only_moves_relatively() {
        let mut ids = SequentialIds::default();
        let c = text_clip(&mut ids, Vec2::new(800.0, 300.0), Vec2::new(1.0, 1.0));
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        assert!(change(&mut p, id, &fmt(1080, 1920), ConformMode::Fill).is_ok());
        let n = &p.timeline(id).unwrap().tracks[0].clips()[0];
        assert!(close2(n.animation.position.value, Vec2::new(800.0 * 1080.0 / 1920.0, 300.0 * 1920.0 / 1080.0)));
        assert!(close2(n.animation.scale.value, Vec2::new(1.0, 1.0)));
    }

    #[test]
    fn animated_text_position_scaled_per_axis_not_clamped() {
        use sq_core_time::{Keyframe, KeyframeTrack};
        let mut ids = SequentialIds::default();
        let mut c = text_clip(&mut ids, Vec2::ZERO, Vec2::new(1.0, 1.0));
        c.animation.position.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(-1920.0, 0.0)),
            Keyframe::new(ids.next_id(), s(1), Vec2::new(0.0, 270.0)),
        ]);
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        let block = |_: &Clip| Some(TextBlock::new(400.0, 100.0));
        assert!(p.change_format(id, &fmt(1080, 1920), ConformMode::Fill, &BTreeMap::new(), &block).is_ok());
        let keys = &p.timeline(id).unwrap().tracks[0].clips()[0].animation.position.track.keys;
        assert!(close2(keys[0].value, Vec2::new(-1080.0, 0.0)));
        assert!(close2(keys[1].value, Vec2::new(0.0, 480.0)));
    }

    #[test]
    fn text_clamp_accounts_for_anchor_and_ink_offset() {
        let mut ids = SequentialIds::default();
        let mut c = text_clip(&mut ids, Vec2::new(1000.0, 0.0), Vec2::new(0.5, 0.5));
        c.animation.anchor = AnimatedProperty::new(Vec2::new(100.0, 0.0));
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        let block = |_: &Clip| Some(TextBlock { width: 400.0, height: 100.0, ink_offset: Vec2::new(40.0, 0.0) });
        assert!(p.change_format(id, &fmt(1920, 1080), ConformMode::Fill, &BTreeMap::new(), &block).is_ok());
        let n = &p.timeline(id).unwrap().tracks[0].clips()[0];
        assert!(close(n.animation.position.value.x, 698.0));
    }

    #[test]
    fn duplicate_as_format_copies_with_fresh_ids_and_names_stay_unique() {
        let mut ids = SequentialIds::default();
        let mut a = video_clip(&mut ids, 0, Vec2::new(1.0, 1.0), Vec2::ZERO);
        let b = video_clip(&mut ids, 5, Vec2::new(1.0, 1.0), Vec2::ZERO);
        let link = ids.next_id();
        a.link = Some(link);
        let mut audio = Clip::new(ids.next_id(), "a", a.media, TrackKind::Audio, a.source, Time::ZERO);
        audio.link = Some(link);
        let title = text_clip(&mut ids, Vec2::new(0.0, 300.0), Vec2::new(1.0, 1.0));
        let (mut p, id) = project(&mut ids, vec![a.clone(), b.clone(), title], vec![audio]);
        let tr: Transition = serde_json::from_value(json!({"id": ids.next_id(), "kind": "crossDissolve",
            "duration": {"value": 30, "timescale": 30}, "alignment": "center",
            "customBefore": {"value": 0, "timescale": 1}, "outgoing": a.id, "incoming": b.id}))
        .unwrap();
        p.timelines[0].tracks[0].transitions = vec![tr];
        let original = p.timeline(id).unwrap().clone();
        let new_id = p
            .duplicate_sequence(id, &fmt(1080, 1920), ConformMode::Fill, &BTreeMap::new(), None, &no_text, &mut ids)
            .unwrap();
        assert_eq!(p.timelines.len(), 2);
        assert_eq!(p.timeline(id), Some(&original));
        let d = p.timeline(new_id).unwrap();
        assert_eq!(d.name, "Main 9:16");
        assert_eq!((d.format.width, d.format.height, d.format.frame_duration), (1080, 1920, fd()));
        let old_clips: BTreeSet<Id> = original.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
        let new_clips: Vec<&Clip> = d.tracks.iter().flat_map(|t| t.clips().iter()).collect();
        assert_eq!(new_clips.len(), 4);
        assert!(new_clips.iter().all(|c| !old_clips.contains(&c.id)));
        assert!(d.tracks.iter().all(|t| original.tracks.iter().all(|o| o.id != t.id)));
        let (v0, a0) = (&d.tracks[0].clips()[0], &d.tracks[1].clips()[0]);
        assert!(v0.link.is_some() && v0.link == a0.link && v0.link != Some(link));
        let tr = &d.tracks[0].transitions[0];
        assert!(tr.outgoing == Some(v0.id) && tr.incoming == Some(d.tracks[0].clips()[1].id));
        let g = &d.tracks[0].clips()[2];
        assert!(g.is_generator() && g.media == g.id);
        assert!(close(v0.animation.scale.value.x, 1920.0 / 1080.0));
        assert!(close(g.animation.position.value.y, 300.0 * 1920.0 / 1080.0));

        let two = p
            .duplicate_sequence(id, &fmt(1080, 1920), ConformMode::Fill, &BTreeMap::new(), None, &no_text, &mut ids)
            .unwrap();
        let three = p
            .duplicate_sequence(
                id,
                &fmt(1080, 1080),
                ConformMode::Fit,
                &BTreeMap::new(),
                Some(" Square cut "),
                &no_text,
                &mut ids,
            )
            .unwrap();
        assert_eq!(p.timeline(two).map(|t| t.name.as_str()), Some("Main 9:16 2"));
        assert_eq!(p.timeline(three).map(|t| t.name.as_str()), Some("Square cut"));
    }

    #[test]
    fn duplicate_regenerates_marker_and_caption_ids() {
        let mut ids = SequentialIds::default();
        let c = video_clip(&mut ids, 0, Vec2::new(1.0, 1.0), Vec2::ZERO);
        let (mut p, id) = project(&mut ids, vec![c], vec![]);
        let marker: Marker = serde_json::from_value(json!({"id": ids.next_id(), "time": {"value": 1, "timescale": 1},
            "name": "m"}))
        .unwrap();
        p.timelines[0].markers = vec![marker];
        let item: CaptionItem = serde_json::from_value(json!({"id": ids.next_id(), "lines": ["Hi"],
            "range": {"start": {"value": 0, "timescale": 1}, "duration": {"value": 1, "timescale": 1}}}))
        .unwrap();
        let ct: CaptionTrack =
            serde_json::from_value(json!({"id": ids.next_id(), "name": "C", "styleRef": "s", "items": [item]}))
                .unwrap();
        p.timelines[0].caption_tracks = vec![ct];
        let src = p.timeline(id).unwrap().clone();
        let dup = p
            .duplicate_sequence(id, &fmt(1080, 1920), ConformMode::Fill, &BTreeMap::new(), None, &no_text, &mut ids)
            .unwrap();
        let d = p.timeline(dup).unwrap();
        assert!(d.markers.len() == 1 && d.markers[0].id != src.markers[0].id && d.markers[0].name == "m");
        let ct = &d.caption_tracks[0];
        assert!(ct.id != src.caption_tracks[0].id && ct.style_ref == "s" && ct.name == "C");
        assert!(ct.items().len() == 1 && ct.items()[0].id != item.id && ct.items()[0].lines == ["Hi"]);
    }
}
