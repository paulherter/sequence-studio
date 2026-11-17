// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DynamicZoom.swift (`dynamicZoomSpec` is `stage_specs::dynamic_zoom` in sq-core-model)
//! Dynamic Zoom (Ken Burns): a start rectangle and an end rectangle of the clip's picture, eased over the clip, written as
//! Scale and Position keys of a transform stage (`ClipEffect::DYNAMIC_ZOOM_KIND`, same stage maths as Transform / Auto
//! Reframe, no render path of its own). The user's Motion values and keys are never touched.

use sq_core_model::{AnimatedProperty, Clip, ClipEffect};
use sq_core_time::{EaseHandle, IdSource, Interpolation, Keyframe, KeyframeTrack, Time, Vec2};

/// A window onto the clip's upright picture, normalized: 0...1, origin top-left, y down.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ZoomRect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl ZoomRect {
    /// The whole picture (no zoom).
    pub const FULL: ZoomRect = ZoomRect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 };

    /// A window of the picture's aspect, `1 / zoom` of its size, centered on `center` (normalized) and kept inside it.
    pub fn centred(zoom: f64, center: Vec2) -> ZoomRect {
        let side = 1.0 / (if zoom.is_finite() { zoom } else { 1.0 }).max(1.0);
        ZoomRect { x: center.x - side / 2.0, y: center.y - side / 2.0, width: side, height: side }.clamped()
    }

    /// Sizes limited to 0.01...1 (uniform: the larger side rules, so the picture's aspect is kept), moved inside the picture.
    pub fn clamped(&self) -> ZoomRect {
        let raw = (if self.width.is_finite() { self.width } else { 1.0 }).max(if self.height.is_finite() {
            self.height
        } else {
            1.0
        });
        let side = raw.clamp(0.01, 1.0);
        let cx = if self.x.is_finite() { self.x + self.width / 2.0 } else { 0.5 };
        let cy = if self.y.is_finite() { self.y + self.height / 2.0 } else { 0.5 };
        ZoomRect {
            x: (cx - side / 2.0).max(0.0).min(1.0 - side),
            y: (cy - side / 2.0).max(0.0).min(1.0 - side),
            width: side,
            height: side,
        }
    }

    /// Scale (1 = 100 %) at which this window fills the frame.
    pub fn zoom(&self) -> f64 {
        1.0 / self.clamped().width
    }

    /// Moved by `d` (normalized), same size, kept inside the picture.
    pub fn moved(&self, d: Vec2) -> ZoomRect {
        let r = self.clamped();
        ZoomRect { x: r.x + d.x, y: r.y + d.y, ..r }.clamped()
    }

    /// The corner dragged to `p` (normalized), the opposite corner fixed. Uniform: the larger distance rules (picture aspect
    /// kept); the window stays inside the picture and keeps at least 1 % of its size.
    pub fn resized(&self, corner: ZoomCorner, p: Vec2) -> ZoomRect {
        let r = self.clamped();
        let (dx, dy) = corner.direction();
        let fx = if dx > 0.0 { r.x } else { r.x + r.width };
        let fy = if dy > 0.0 { r.y } else { r.y + r.height };
        let room = (if dx > 0.0 { 1.0 - fx } else { fx }).min(if dy > 0.0 { 1.0 - fy } else { fy });
        let want = (p.x - fx).abs().max((p.y - fy).abs());
        let side = want.max(0.01).min(room.max(0.01));
        ZoomRect {
            x: if dx > 0.0 { fx } else { fx - side },
            y: if dy > 0.0 { fy } else { fy - side },
            width: side,
            height: side,
        }
        .clamped()
    }

    /// Resized to `zoom` (1 = whole picture) about its center, kept inside the picture.
    pub fn with_zoom(&self, zoom: f64) -> ZoomRect {
        let r = self.clamped();
        ZoomRect::centred(zoom, Vec2::new(r.x + r.width / 2.0, r.y + r.height / 2.0))
    }
}

/// Corner of a window (picture space, y down).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ZoomCorner {
    TopLeft,
    TopRight,
    BottomRight,
    BottomLeft,
}

impl ZoomCorner {
    /// Which way the window grows when this corner is dragged outwards.
    fn direction(self) -> (f64, f64) {
        match self {
            Self::TopLeft => (-1.0, -1.0),
            Self::TopRight => (1.0, -1.0),
            Self::BottomRight => (1.0, 1.0),
            Self::BottomLeft => (-1.0, 1.0),
        }
    }
}

/// How the zoom moves between the two rectangles.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ZoomEase {
    Linear,
    EaseIn,
    EaseOut,
    EaseInOut,
}

impl ZoomEase {
    /// Every ease, in menu order.
    pub const ALL: [ZoomEase; 4] = [Self::Linear, Self::EaseIn, Self::EaseOut, Self::EaseInOut];

    /// (out-handle of the first key, in-handle of the second key).
    fn handles(self) -> (EaseHandle, EaseHandle) {
        let h = |dx| EaseHandle { dx, dy: 0.0 };
        match self {
            Self::Linear => (EaseHandle::LINEAR, EaseHandle::LINEAR),
            Self::EaseIn => (h(0.6), EaseHandle::LINEAR),
            Self::EaseOut => (EaseHandle::LINEAR, h(0.6)),
            Self::EaseInOut => (h(0.5), h(0.5)),
        }
    }
}

/// Swift `DynamicZoom`.
pub struct DynamicZoom;

impl DynamicZoom {
    /// Stage Scale (%) and Position (px of the clip's frame from its center) that show `rect` full frame.
    /// The stage maps p to s p + pos, so the picture point at the frame center is q = -pos / s.
    pub fn stage_values(rect: &ZoomRect, picture: Vec2) -> (f64, Vec2) {
        let r = rect.clamped();
        let s = 1.0 / r.width;
        let c = Vec2::new((r.x + r.width / 2.0 - 0.5) * picture.x, (r.y + r.height / 2.0 - 0.5) * picture.y);
        (s * 100.0, Vec2::new(-s * c.x, -s * c.y))
    }

    /// The Dynamic Zoom stage: keys at clip-local 0 and `duration`, eased as `ease`. `None` when the two windows are the
    /// same (nothing to animate) or the duration / picture is empty. `id` is the effect's, `ids` draws the key ids.
    pub fn effect(
        start: &ZoomRect,
        end: &ZoomRect,
        duration: Time,
        picture: Vec2,
        ease: ZoomEase,
        id: sq_core_time::Id,
        ids: &mut dyn IdSource,
    ) -> Option<ClipEffect> {
        if duration <= Time::ZERO || picture.x <= 0.0 || picture.y <= 0.0 || start.clamped() == end.clamped() {
            return None;
        }
        let (sa, pa) = Self::stage_values(start, picture);
        let (sb, pb) = Self::stage_values(end, picture);
        let (out, into) = ease.handles();
        let kind = if ease == ZoomEase::Linear { Interpolation::Linear } else { Interpolation::Bezier };
        let mut track = |v0: f64, v1: f64| {
            let mut k0 = Keyframe::new(ids.next_id(), Time::ZERO, v0);
            (k0.interpolation, k0.in_handle, k0.out_handle) = (kind, EaseHandle::LINEAR, out);
            let mut k1 = Keyframe::new(ids.next_id(), duration, v1);
            (k1.interpolation, k1.in_handle, k1.out_handle) = (kind, into, EaseHandle::LINEAR);
            AnimatedProperty { value: v0, track: KeyframeTrack::with_keys(vec![k0, k1]) }
        };
        let mut e = ClipEffect::make(id, ClipEffect::DYNAMIC_ZOOM_KIND)?;
        e.parameters.insert(ClipEffect::STAGE_SCALE_KEY.to_string(), track(sa, sb));
        e.parameters.insert(ClipEffect::STAGE_POSITION_X_KEY.to_string(), track(pa.x, pb.x));
        e.parameters.insert(ClipEffect::STAGE_POSITION_Y_KEY.to_string(), track(pa.y, pb.y));
        Some(e)
    }

    /// The two windows (and ease) the clip's Dynamic Zoom stage shows at its first and last Scale key. `None` without a
    /// stage or when it is not a two-key stage written by `apply` (the user may have edited it in Effect Controls).
    pub fn windows(clip: &Clip, picture: Vec2) -> Option<(ZoomRect, ZoomRect, ZoomEase)> {
        if picture.x <= 0.0 || picture.y <= 0.0 {
            return None;
        }
        let e = clip.effect_of_kind(ClipEffect::DYNAMIC_ZOOM_KIND)?;
        let sc = e.parameters.get(ClipEffect::STAGE_SCALE_KEY).filter(|s| s.track.keys.len() == 2)?;
        let px = e.parameters.get(ClipEffect::STAGE_POSITION_X_KEY)?;
        let py = e.parameters.get(ClipEffect::STAGE_POSITION_Y_KEY)?;
        let k = &sc.track.keys;
        let window = |t: Time| {
            let s = (sc.value_at_local(t) / 100.0).max(1.0);
            let cx = 0.5 + (-px.value_at_local(t) / s) / picture.x;
            let cy = 0.5 + (-py.value_at_local(t) / s) / picture.y;
            ZoomRect { x: cx - 0.5 / s, y: cy - 0.5 / s, width: 1.0 / s, height: 1.0 / s }
        };
        let ease = ZoomEase::ALL
            .into_iter()
            .find(|e| e.handles().0 == k[0].out_handle && e.handles().1 == k[1].in_handle)
            .unwrap_or(ZoomEase::EaseInOut);
        Some((window(k[0].time), window(k[1].time), ease))
    }

    /// Writes (or replaces) the clip's Dynamic Zoom stage. False when `effect` has nothing to write.
    pub fn apply(
        clip: &mut Clip,
        start: &ZoomRect,
        end: &ZoomRect,
        picture: Vec2,
        ease: ZoomEase,
        ids: &mut dyn IdSource,
    ) -> bool {
        let existing = clip.effects.iter().position(|e| e.kind == ClipEffect::DYNAMIC_ZOOM_KIND);
        let id = existing.map_or_else(|| ids.next_id(), |i| clip.effects[i].id);
        let Some(e) = Self::effect(start, end, clip.duration(), picture, ease, id, ids) else { return false };
        match existing {
            Some(i) => clip.effects[i] = e,
            None => clip.effects.push(e),
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect_transform_stage::{ClipEffectStage, ClipStageEval};
    use sq_core_model::{EffectCatalog, TrackKind};
    use sq_core_time::{Id, SequentialIds, TimeRange};

    const PIC: Vec2 = Vec2::new(1920.0, 1080.0);

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() <= 1e-9
    }

    fn clip() -> Clip {
        Clip::new(
            Id::from_u128(1),
            "v",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(4)),
            Time::ZERO,
        )
    }

    fn centred(zoom: f64) -> ZoomRect {
        ZoomRect::centred(zoom, Vec2::new(0.5, 0.5))
    }

    fn apply(c: &mut Clip, a: &ZoomRect, b: &ZoomRect, ease: ZoomEase) -> bool {
        DynamicZoom::apply(c, a, b, PIC, ease, &mut SequentialIds::default())
    }

    #[test]
    fn full_and_centred_windows() {
        let (sc, p) = DynamicZoom::stage_values(&ZoomRect::FULL, PIC);
        assert!(close(sc, 100.0) && close(p.x, 0.0) && close(p.y, 0.0));
        let (sc, p) = DynamicZoom::stage_values(&centred(2.0), PIC);
        assert!(close(sc, 200.0) && close(p.x, 0.0) && close(p.y, 0.0));
    }

    #[test]
    fn corner_window_shows_that_corner() {
        let (sc, p) = DynamicZoom::stage_values(&ZoomRect { x: 0.0, y: 0.0, width: 0.5, height: 0.5 }, PIC);
        let k = sc / 100.0;
        assert!(close(k * -960.0 + p.x, -960.0) && close(k * -540.0 + p.y, -540.0));
        assert!(close(p.x, 960.0) && close(p.y, 540.0));
    }

    #[test]
    fn windows_are_kept_inside_the_picture() {
        let r = ZoomRect { x: 0.9, y: -0.2, width: 0.5, height: 0.5 }.clamped();
        assert!(close(r.x, 0.5) && close(r.y, 0.0) && close(r.width, 0.5));
        assert_eq!(ZoomRect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 }.clamped().width, 0.01);
        assert_eq!(ZoomRect { x: f64::NAN, y: 0.0, width: f64::INFINITY, height: 1.0 }.clamped().width, 1.0);
    }

    #[test]
    fn effect_has_eased_keys_at_clip_start_and_end() {
        let mut c = clip();
        assert!(apply(&mut c, &ZoomRect::FULL, &centred(1.25), ZoomEase::EaseInOut));
        let e = &c.effects[0];
        assert!(e.kind == ClipEffect::DYNAMIC_ZOOM_KIND && e.is_transform_stage());
        let sc = &e.parameters[ClipEffect::STAGE_SCALE_KEY];
        assert_eq!(sc.track.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![Time::ZERO, s(4)]);
        assert!(close(sc.value_at_local(Time::ZERO), 100.0) && close(sc.value_at_local(s(4)), 125.0));
        let q = sc.value_at_local(s(1)); // slow start: behind the linear 106.25
        assert!(q > 100.0 && q < 106.25);
        assert!(sc.track.keys.iter().all(|k| k.interpolation == Interpolation::Bezier));
    }

    #[test]
    fn linear_ease_uses_linear_keys() {
        let mut c = clip();
        apply(&mut c, &ZoomRect::FULL, &centred(2.0), ZoomEase::Linear);
        let sc = &c.effects[0].parameters[ClipEffect::STAGE_SCALE_KEY];
        assert!((sc.value_at_local(s(2)) - 150.0).abs() < 1e-6);
    }

    #[test]
    fn renders_as_stage_on_top_of_motion_without_touching_it() {
        let mut c = clip();
        c.animation.scale = AnimatedProperty::new(Vec2::new(120.0, 120.0));
        let before = c.transform(s(2));
        apply(&mut c, &ZoomRect::FULL, &centred(2.0), ZoomEase::Linear);
        assert_eq!(c.transform(s(2)), before);
        let end = c.render_transform(s(4), PIC);
        assert!(close(end.scale.x, before.scale.x * 2.0));
    }

    #[test]
    fn same_windows_or_empty_clip_write_nothing() {
        let mut c = clip();
        assert!(!apply(&mut c, &ZoomRect::FULL, &ZoomRect::FULL, ZoomEase::EaseInOut));
        assert!(c.effects.is_empty());
        let mut z = clip();
        z.source = TimeRange::new(Time::ZERO, Time::ZERO);
        assert!(!apply(&mut z, &ZoomRect::FULL, &centred(2.0), ZoomEase::EaseInOut));
    }

    #[test]
    fn second_run_replaces_the_stage_keeping_its_id() {
        let mut c = clip();
        apply(&mut c, &ZoomRect::FULL, &centred(2.0), ZoomEase::EaseInOut);
        let id = c.effects[0].id;
        apply(&mut c, &centred(2.0), &ZoomRect::FULL, ZoomEase::EaseInOut);
        assert!(c.effects.len() == 1 && c.effects[0].id == id);
        assert!(close(c.effects[0].parameters[ClipEffect::STAGE_SCALE_KEY].value_at_local(Time::ZERO), 200.0));
    }

    #[test]
    fn catalog_knows_the_kind_but_does_not_offer_it() {
        assert!(EffectCatalog::spec_for(ClipEffect::DYNAMIC_ZOOM_KIND).is_some());
        assert!(!EffectCatalog::all().iter().any(|e| e.kind == ClipEffect::DYNAMIC_ZOOM_KIND));
    }

    #[test]
    fn moving_keeps_the_size_and_stays_inside_the_picture() {
        let r = ZoomRect { x: 0.1, y: 0.1, width: 0.5, height: 0.5 };
        let m = r.moved(Vec2::new(0.2, -0.3));
        assert!(close(m.x, 0.3) && close(m.y, 0.0) && close(m.width, 0.5));
        let far = r.moved(Vec2::new(5.0, 5.0));
        assert!(close(far.x, 0.5) && close(far.y, 0.5));
    }

    #[test]
    fn corner_resize_keeps_the_opposite_corner_and_the_aspect() {
        let r = ZoomRect { x: 0.25, y: 0.25, width: 0.5, height: 0.5 };
        let a = r.resized(ZoomCorner::BottomRight, Vec2::new(0.95, 0.8)); // larger side rules
        assert!(close(a.x, 0.25) && close(a.y, 0.25) && close(a.width, 0.7) && close(a.height, 0.7));
        let b = r.resized(ZoomCorner::TopLeft, Vec2::new(0.5, 0.5)); // bottom-right (0.75) stays
        assert!(close(b.x, 0.5) && close(b.y, 0.5) && close(b.width, 0.25));
        let c = r.resized(ZoomCorner::BottomRight, Vec2::new(3.0, 3.0)); // cannot leave the picture
        assert!(close(c.x, 0.25) && close(c.width, 0.75));
        let d = r.resized(ZoomCorner::BottomRight, Vec2::new(0.25, 0.25)); // collapsed: smallest window
        assert!(close(d.width, 0.01));
    }

    #[test]
    fn zoom_amount_keeps_the_centre() {
        let r = ZoomRect { x: 0.5, y: 0.5, width: 0.5, height: 0.5 }; // center 0.75
        let z = r.with_zoom(4.0);
        assert!(close(z.width, 0.25) && close(z.x + z.width / 2.0, 0.75) && close(z.y + z.height / 2.0, 0.75));
        let edge = r.with_zoom(1.0); // full picture: center cannot stay
        assert!(close(edge.x, 0.0) && close(edge.width, 1.0));
    }

    #[test]
    fn windows_read_back_from_the_written_stage_and_every_ease_is_recognised() {
        let mut c = clip();
        let a = ZoomRect { x: 0.1, y: 0.2, width: 0.6, height: 0.6 };
        let b = ZoomRect { x: 0.4, y: 0.4, width: 0.5, height: 0.5 };
        apply(&mut c, &a, &b, ZoomEase::EaseOut);
        let (w0, w1, ease) = DynamicZoom::windows(&c, PIC).expect("written stage");
        assert!(close(w0.x, 0.1) && close(w0.y, 0.2) && close(w0.width, 0.6));
        assert!(close(w1.x, 0.4) && close(w1.y, 0.4) && close(w1.width, 0.5));
        assert_eq!(ease, ZoomEase::EaseOut);
        assert!(DynamicZoom::windows(&clip(), PIC).is_none());
        for e in ZoomEase::ALL {
            let mut c = clip();
            apply(&mut c, &ZoomRect::FULL, &centred(2.0), e);
            assert_eq!(DynamicZoom::windows(&c, PIC).map(|w| w.2), Some(e));
        }
    }
}
