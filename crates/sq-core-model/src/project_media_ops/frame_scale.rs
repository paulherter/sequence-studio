// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FrameScale.swift
//
// Scale semantics (Premiere): a clip's Scale of 100 % shows the picture at its own pixel size, one source pixel per
// sequence pixel (upright size: a phone clip rotated 90 degrees counts with width and height swapped). A 4K clip in a
// 1080 wide sequence therefore fills the width at 50 %. "Fit to Frame" writes the fit value into Scale.

use crate::{AnimatedProperty, Clip, EditError, Project, SequenceFormat, Timeline, TrackKind, VariantOverride};
use sq_core_time::{Id, Vec2};
use std::collections::BTreeSet;

impl SequenceFormat {
    /// Scale at which a `w x h` picture fits the frame entirely (aspect kept, bars on one axis). 1 for a degenerate size.
    pub fn fit_scale(&self, w: i64, h: i64) -> f64 {
        if w <= 0 || h <= 0 || self.width <= 0 || self.height <= 0 {
            return 1.0;
        }
        (self.display_width() as f64 / w as f64).min(self.height as f64 / h as f64)
    }

    /// Scale at which a `w x h` picture covers the frame entirely (aspect kept, edges cropped on one axis): "Set to Fill
    /// Frame". 1 for a degenerate size.
    pub fn fill_scale(&self, w: i64, h: i64) -> f64 {
        if w <= 0 || h <= 0 || self.width <= 0 || self.height <= 0 {
            return 1.0;
        }
        (self.display_width() as f64 / w as f64).max(self.height as f64 / h as f64)
    }
}

impl Project {
    /// Upright pixel size of what a clip shows: media display size (rotation applied), or the size of the nested sequence.
    /// `None` for generators and for media without probe info.
    pub fn picture_size(&self, clip: &Clip) -> Option<(i64, i64)> {
        if clip.is_generator() {
            return None;
        }
        if let Some(s) = clip.sequence {
            return self.timeline(s).map(|t| (t.format.display_width(), t.format.height));
        }
        let v = self.media(clip.media)?.info.as_ref()?.video.as_ref()?;
        Some((v.display_width(), v.display_height()))
    }

    /// Scale that fits `clip`'s picture into `timeline`'s frame; `None` when the picture size is unknown.
    pub fn frame_fit_scale(&self, clip: &Clip, timeline: &Timeline) -> Option<f64> {
        let (w, h) = self.picture_size(clip)?;
        Some(timeline.format.fit_scale(w, h))
    }

    /// Scale that fills `timeline`'s frame with `clip`'s picture; `None` when the picture size is unknown.
    pub fn frame_fill_scale(&self, clip: &Clip, timeline: &Timeline) -> Option<f64> {
        let (w, h) = self.picture_size(clip)?;
        Some(timeline.format.fill_scale(w, h))
    }

    /// "Set to Fill Frame": like `set_to_frame_size` but the picture covers the whole frame (edges cropped).
    pub fn set_to_fill_frame(&mut self, ids: &BTreeSet<Id>, timeline: Id) -> Result<usize, EditError> {
        self.write_frame_scale(ids, timeline, true)
    }

    /// "Fit to Frame": Scale of each picture clip becomes the fit value (keyframes of Scale are removed, position and
    /// rotation stay). Generators and clips of unknown size are skipped. Returns `TrackLocked` when a clip sits on a locked
    /// track, `TimelineNotFound` for an unknown timeline; nothing changes then. Returns the number of clips changed.
    pub fn set_to_frame_size(&mut self, ids: &BTreeSet<Id>, timeline: Id) -> Result<usize, EditError> {
        self.write_frame_scale(ids, timeline, false)
    }

    fn write_frame_scale(&mut self, ids: &BTreeSet<Id>, timeline: Id, fill: bool) -> Result<usize, EditError> {
        let ti = self.timelines.iter().position(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        let mut work = self.timelines[ti].clone();
        let mut changed = 0;
        for tr in 0..work.tracks.len() {
            if work.tracks[tr].kind != TrackKind::Video {
                continue;
            }
            for c in work.tracks[tr].clips().to_vec().iter().filter(|c| ids.contains(&c.id)) {
                let fit = if fill { self.frame_fill_scale(c, &work) } else { self.frame_fit_scale(c, &work) };
                let Some(fit) = fit else { continue };
                if work.tracks[tr].is_locked {
                    return Err(EditError::TrackLocked);
                }
                let mut n = c.clone();
                n.animation.scale = AnimatedProperty::new(Vec2::new(fit, fit));
                n.set_pending_source_pixel_scale(false); // an absolute fit value: nothing is owed any more
                if n != *c {
                    work.tracks[tr].replace(n);
                    changed += 1;
                }
            }
        }
        if changed > 0 {
            self.timelines[ti] = work;
        }
        Ok(changed)
    }

    /// File v10: Scale used to be relative to the aspect-fitted picture (100 % = fit). It is now relative to the picture's
    /// own pixels, so every picture clip's Scale (value and keyframes) is multiplied by its fit scale and keeps its on-screen
    /// size. Generators and stills are left alone. A clip whose picture size is unknown (no probe info) cannot be converted
    /// yet: it is marked pending and converted by `apply_pending_scale_migration` once its media has probe info.
    pub fn migrate_scale_to_source_pixels(&mut self) {
        self.convert_scale_to_source_pixels(|c| !c.is_still && !c.is_generator(), true);
    }

    /// Runs the owed v10 Scale step for every pending clip whose picture size is now known; the others stay marked. Called
    /// after media gets probe info.
    pub fn apply_pending_scale_migration(&mut self) {
        self.convert_scale_to_source_pixels(Clip::pending_source_pixel_scale, false);
    }

    fn convert_scale_to_source_pixels(&mut self, include: impl Fn(&Clip) -> bool, mark_unknown: bool) {
        for ti in 0..self.timelines.len() {
            let mut t = self.timelines[ti].clone();
            let mut touched = false;
            for tr in 0..t.tracks.len() {
                if t.tracks[tr].kind != TrackKind::Video {
                    continue;
                }
                for c in t.tracks[tr].clips().to_vec().iter().filter(|c| include(c)) {
                    let Some(f) = self.frame_fit_scale(c, &t) else {
                        if mark_unknown && !c.pending_source_pixel_scale() {
                            let mut n = c.clone();
                            n.set_pending_source_pixel_scale(true);
                            t.tracks[tr].replace(n);
                            touched = true;
                        }
                        continue;
                    };
                    let mut n = c.scaled_to_source_pixels(f);
                    // Variant overrides come from `Timeline::detach` (base Scale x the conform factor): the conform applies
                    // on top of the base semantics, so they convert with the same base fit.
                    if let Some(v) = n.variant_store.as_mut() {
                        for o in v.items.values_mut() {
                            *o = o.scaled_to_source_pixels(f);
                        }
                    }
                    n.set_pending_source_pixel_scale(false);
                    if n != *c {
                        t.tracks[tr].replace(n);
                        touched = true;
                    }
                }
            }
            if touched {
                self.timelines[ti] = t;
            }
        }
    }
}

impl Clip {
    /// The v10 conversion for one clip: Scale (value and keys) times `f`, Anchor divided by `f`. Identity for f == 1.
    fn scaled_to_source_pixels(&self, f: f64) -> Clip {
        if (f - 1.0).abs() <= 1e-12 {
            return self.clone();
        }
        let mut n = self.clone();
        // Layer-local px are now native px (fit factor larger): the anchor shrinks by f to stay on the same point.
        n.animation.anchor = scaled_anchor(&self.animation.anchor, f);
        n.animation.scale = scaled_scale(&self.animation.scale, f);
        n
    }
}

impl VariantOverride {
    /// The v10 conversion of this override's Scale and Anchor (the base fit `f`, like the clip's own values).
    fn scaled_to_source_pixels(&self, f: f64) -> VariantOverride {
        if (f - 1.0).abs() <= 1e-12 {
            return self.clone();
        }
        let mut o = self.clone();
        o.scale = self.scale.as_ref().map(|s| scaled_scale(s, f));
        o.anchor = self.anchor.as_ref().map(|a| scaled_anchor(a, f));
        o
    }
}

fn mapped(p: &AnimatedProperty<Vec2>, f: impl Fn(Vec2) -> Vec2) -> AnimatedProperty<Vec2> {
    let mut n = p.clone();
    n.value = f(p.value);
    for k in &mut n.track.keys {
        k.value = f(k.value);
        k.in_tangent = f(k.in_tangent);
        k.out_tangent = f(k.out_tangent);
    }
    n
}

fn scaled_scale(p: &AnimatedProperty<Vec2>, f: f64) -> AnimatedProperty<Vec2> {
    mapped(p, |v| Vec2::new(v.x * f, v.y * f))
}

fn scaled_anchor(p: &AnimatedProperty<Vec2>, f: f64) -> AnimatedProperty<Vec2> {
    mapped(p, |v| Vec2::new(v.x / f, v.y / f))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MediaFingerprint, MediaRef};
    use serde_json::json;
    use sq_core_time::{Keyframe, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn format(w: i64, h: i64) -> SequenceFormat {
        let mut f = SequenceFormat::new(fd());
        f.width = w;
        f.height = h;
        f
    }

    fn media_ref(w: i64, h: i64, rotation: i64) -> MediaRef {
        let mut m = MediaRef::new(Id::from_u128(77), "m", "/m.mov", MediaFingerprint::new(1));
        m.duration = Some(s(10));
        m.info = serde_json::from_value(json!({"duration": {"value": 10, "timescale": 1}, "video": {
            "width": w, "height": h, "codec": "hvc1", "bitDepth": 10, "chroma": "4:2:0",
            "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": rotation}}))
        .ok();
        m
    }

    /// One video track holding one clip of `media`, in a `seq_w x seq_h` sequence; the clip's Scale is `scale`.
    fn project(seq_w: i64, seq_h: i64, media: MediaRef, scale: Vec2) -> (Project, Id, Id) {
        let mut clip =
            Clip::new(Id::from_u128(1), "c", media.id, TrackKind::Video, TimeRange::new(Time::ZERO, s(5)), Time::ZERO);
        clip.animation.scale = AnimatedProperty::new(scale);
        let mut track = crate::Track::new(Id::from_u128(9), TrackKind::Video);
        track.set_clips(vec![clip.clone()]);
        let tl = Timeline::new(Id::from_u128(8), "T", format(seq_w, seq_h), vec![track]);
        let id = tl.id;
        (Project::new(Id::from_u128(7), "t", vec![media], vec![tl]), id, clip.id)
    }

    fn first_clip(p: &Project) -> Clip {
        p.timelines[0].tracks[0].clips()[0].clone()
    }

    #[test]
    fn fit_scale_examples() {
        let f1080 = format(1080, 1920);
        assert_eq!(format(1920, 1080).fit_scale(3840, 2160), 0.5);
        // 4K phone clip rotated 90 degrees: upright 2160 x 3840 fills a 1080 x 1920 sequence at 50 %, not 28 %.
        assert_eq!(f1080.fit_scale(2160, 3840), 0.5);
        assert!((f1080.fit_scale(3840, 2160) - 0.28125).abs() < 1e-12);
        assert_eq!(f1080.fit_scale(0, 10), 1.0);
        assert_eq!(format(1920, 1080).fill_scale(960, 1080), 2.0);
    }

    #[test]
    fn picture_size_uses_rotation_and_nesting() {
        let (mut p, _, _) = project(1080, 1920, media_ref(3840, 2160, 90), Vec2::new(1.0, 1.0));
        assert_eq!(p.picture_size(&first_clip(&p)), Some((2160, 3840)));
        let inner = Timeline::new(Id::from_u128(30), "in", format(1280, 720), vec![]);
        p.timelines.push(inner.clone());
        let mut nested =
            Clip::new(Id::from_u128(31), "n", inner.id, TrackKind::Video, TimeRange::new(Time::ZERO, s(1)), Time::ZERO);
        nested.sequence = Some(inner.id);
        assert_eq!(p.picture_size(&nested), Some((1280, 720)));
        let mut text_clip = nested.clone();
        text_clip.sequence = None;
        text_clip.generator = Some(crate::GeneratorRef { kind: "text".into(), payload: vec![], payload_version: 1 });
        assert_eq!(p.picture_size(&text_clip), None);
    }

    #[test]
    fn set_to_frame_size_writes_the_fit_and_drops_scale_keys() {
        let (mut p, tl, id) = project(1080, 1920, media_ref(3840, 2160, 90), Vec2::new(2.0, 2.0));
        let mut c = first_clip(&p);
        c.animation.scale.track.insert(Keyframe::new(Id::from_u128(50), Time::ZERO, Vec2::new(3.0, 3.0)));
        p.timelines[0].tracks[0].replace(c);
        let ids = BTreeSet::from([id]);
        assert_eq!(p.set_to_frame_size(&ids, tl), Ok(1));
        let n = first_clip(&p);
        assert!(n.animation.scale.value == Vec2::new(0.5, 0.5) && !n.animation.scale.is_animated());
        assert_eq!(p.set_to_frame_size(&ids, tl), Ok(0), "already there");
        assert_eq!(p.set_to_frame_size(&ids, Id::from_u128(404)), Err(EditError::TimelineNotFound));
        let (mut q, tl, id) = project(1920, 1080, media_ref(3840, 2160, 0), Vec2::new(1.0, 1.0));
        assert_eq!(q.set_to_fill_frame(&BTreeSet::from([id]), tl), Ok(1));
        assert!(first_clip(&q).animation.scale.value == Vec2::new(0.5, 0.5));
    }

    #[test]
    fn set_to_frame_size_refuses_a_locked_track() {
        let (mut p, tl, id) = project(1920, 1080, media_ref(3840, 2160, 0), Vec2::new(1.0, 1.0));
        p.timelines[0].tracks[0].is_locked = true;
        assert_eq!(p.set_to_frame_size(&BTreeSet::from([id]), tl), Err(EditError::TrackLocked));
        assert!(first_clip(&p).animation.scale.value == Vec2::new(1.0, 1.0));
    }

    #[test]
    fn migration_keeps_the_on_screen_size() {
        let (mut p, _, _) = project(1920, 1080, media_ref(3840, 2160, 0), Vec2::new(2.0, 1.5));
        let mut c = first_clip(&p);
        c.animation.scale.track.insert(Keyframe::new(Id::from_u128(50), s(1), Vec2::new(4.0, 4.0)));
        c.animation.anchor = AnimatedProperty::new(Vec2::new(10.0, 20.0));
        p.timelines[0].tracks[0].replace(c);
        let mut text_clip = Clip::new(
            Id::from_u128(2),
            "g",
            Id::from_u128(3),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(1)),
            s(6),
        );
        text_clip.generator = Some(crate::GeneratorRef { kind: "text".into(), payload: vec![], payload_version: 1 });
        let ids = &mut crate::nesting::test_util::TestIds(900);
        assert_eq!(p.timelines[0].tracks[0].overwrite(text_clip, ids), Ok(()));
        p.migrate_scale_to_source_pixels();
        let clips = p.timelines[0].tracks[0].clips().to_vec();
        let media = &clips[0];
        assert!(media.animation.scale.value == Vec2::new(1.0, 0.75)); // fit 0.5
        assert!(media.animation.scale.track.keys[0].value == Vec2::new(2.0, 2.0));
        assert!(media.animation.anchor.value == Vec2::new(20.0, 40.0), "the anchor stays on the same picture point");
        assert!(clips[1].animation.scale.value == Vec2::new(1.0, 1.0), "generators are left alone");
    }

    #[test]
    fn migration_marks_unknown_sizes_and_the_pending_step_converts_them_once_probed() {
        let (mut p, _, _) = project(1920, 1080, media_ref(3840, 2160, 0), Vec2::new(1.0, 1.0));
        let info = p.media[0].info.take();
        p.migrate_scale_to_source_pixels();
        assert!(first_clip(&p).pending_source_pixel_scale());
        assert!(first_clip(&p).animation.scale.value == Vec2::new(1.0, 1.0));
        p.apply_pending_scale_migration();
        assert!(first_clip(&p).pending_source_pixel_scale(), "still unknown: stays marked");
        p.media[0].info = info;
        p.apply_pending_scale_migration();
        assert!(first_clip(&p).animation.scale.value == Vec2::new(0.5, 0.5));
        assert!(!first_clip(&p).pending_source_pixel_scale());
    }

    #[test]
    fn scale_key_tangents_and_variant_overrides_convert_with_the_base_fit() {
        let (mut p, _, _) = project(1920, 1080, media_ref(3840, 2160, 0), Vec2::new(1.0, 1.0));
        let mut c = first_clip(&p);
        let mut k = Keyframe::new(Id::from_u128(50), s(1), Vec2::new(2.0, 2.0));
        k.in_tangent = Vec2::new(4.0, 4.0);
        k.out_tangent = Vec2::new(6.0, 6.0);
        c.animation.scale.track.insert(k);
        let o = VariantOverride {
            scale: Some(AnimatedProperty::new(Vec2::new(2.0, 2.0))),
            anchor: Some(AnimatedProperty::new(Vec2::new(8.0, 8.0))),
            ..VariantOverride::default()
        };
        c.variant_store = Some(crate::VariantOverrides { items: [(Id::from_u128(60), o)].into() });
        p.timelines[0].tracks[0].replace(c);
        p.migrate_scale_to_source_pixels();
        let n = first_clip(&p);
        let key = &n.animation.scale.track.keys[0];
        assert!((key.in_tangent, key.out_tangent) == (Vec2::new(2.0, 2.0), Vec2::new(3.0, 3.0)));
        let ov = n.variant_store.and_then(|v| v.items.get(&Id::from_u128(60)).cloned()).unwrap_or_default();
        assert!(ov.scale.is_some_and(|s| s.value == Vec2::new(1.0, 1.0)));
        assert!(ov.anchor.is_some_and(|a| a.value == Vec2::new(16.0, 16.0)));
    }
}
