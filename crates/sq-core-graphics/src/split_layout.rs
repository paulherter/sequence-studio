// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SplitLayout.swift
//
// Split-screen layouts: N clips on stacked video tracks get Scale, Position and a Crop effect so that each fills one cell of
// the frame. Everything is written as ordinary Motion values, Crop parameters and keyframes, so the result is editable in
// Effect Controls afterwards. Pure model code, no file-format change (Crop is an existing effect).

use sq_core_effects::effects_editing::ClipEffectsEditingExt as _;
use sq_core_effects::effects_evaluation::CropInsets;
use sq_core_model::{AnimatedProperty, Clip, ClipEffect, EditError, Project, TrackKind};
use sq_core_time::{EaseHandle, Id, IdSource, Interpolation, Keyframe, KeyframeValue, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// A rectangle of the sequence frame in pixels, origin top-left, y down.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SplitCell {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// The built-in layouts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitLayoutPreset {
    /// 50/50 with a vertical divider: first clip left, second right.
    SideBySide,
    /// 50/50 with a horizontal divider: first clip top, second bottom.
    Stacked,
    /// 60/40 with a vertical divider: first clip left (60 %).
    SixtyForty,
    /// Three equal rows, first clip on top.
    ThreeStacked,
    /// First clip fills the frame, second sits in the bottom-right corner (30 % width).
    PictureInPicture,
    /// Like Picture in Picture, but a square slot with fully rounded corners (a circle).
    PictureInPictureCircle,
}

impl SplitLayoutPreset {
    /// Every preset, in declaration order.
    pub const ALL: [SplitLayoutPreset; 6] = [
        SplitLayoutPreset::SideBySide,
        SplitLayoutPreset::Stacked,
        SplitLayoutPreset::SixtyForty,
        SplitLayoutPreset::ThreeStacked,
        SplitLayoutPreset::PictureInPicture,
        SplitLayoutPreset::PictureInPictureCircle,
    ];

    /// Clips a preset needs (extra selected clips are left alone).
    pub fn cell_count(self) -> usize {
        if self == SplitLayoutPreset::ThreeStacked { 3 } else { 2 }
    }

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            SplitLayoutPreset::SideBySide => "Side by Side 50/50",
            SplitLayoutPreset::Stacked => "Top and Bottom 50/50",
            SplitLayoutPreset::SixtyForty => "Side by Side 60/40",
            SplitLayoutPreset::ThreeStacked => "Three Stacked",
            SplitLayoutPreset::PictureInPicture => "Picture in Picture",
            SplitLayoutPreset::PictureInPictureCircle => "Picture in Picture (Circle)",
        }
    }
}

/// Why a split layout was refused. Swift throws `SplitLayoutError` or `EditError`; both are cases here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitLayoutError {
    /// Fewer clips than the preset has cells.
    TooFewClips {
        /// Cells of the preset.
        required: usize,
    },
    /// Two selected clips share a track: a split screen needs one clip per track.
    SameTrack,
    /// An edit error (`TrackLocked`, `TimelineNotFound`).
    Edit(EditError),
}

impl std::fmt::Display for SplitLayoutError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for SplitLayoutError {}

/// Where a clip lands in its cell: cover fit (the picture fills the cell, the excess is cropped, aspect kept).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SplitPlacement {
    /// Uniform scale.
    pub scale: f64,
    /// Offset of the cell center from the frame center, px (the Motion Position convention).
    pub position: Vec2,
    /// Fractions 0...1 of the clip's own frame.
    pub crop: CropInsets,
}

const PIP_WIDTH_FRACTION: f64 = 0.3;
const PIP_MARGIN_FRACTION: f64 = 0.04;

/// The layout geometry.
pub struct SplitLayout;

impl SplitLayout {
    /// Cells of `preset`, in clip order (lowest track first). `gap` px of divider is cut out of the touching edges (the
    /// background shows through); ignored for Picture in Picture. Swift also has an `Int` canvas overload; callers convert.
    pub fn cells(preset: SplitLayoutPreset, w: f64, h: f64, gap: f64) -> Vec<SplitCell> {
        let g = gap.max(0.0) / 2.0;
        match preset {
            SplitLayoutPreset::SideBySide => Self::columns(&[0.5, 0.5], w, h, g),
            SplitLayoutPreset::SixtyForty => Self::columns(&[0.6, 0.4], w, h, g),
            SplitLayoutPreset::Stacked => Self::rows(&[0.5, 0.5], w, h, g),
            SplitLayoutPreset::ThreeStacked => Self::rows(&[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0], w, h, g),
            SplitLayoutPreset::PictureInPicture => {
                let (pw, ph, m) = (w * PIP_WIDTH_FRACTION, h * PIP_WIDTH_FRACTION, w * PIP_MARGIN_FRACTION);
                vec![
                    SplitCell { x: 0.0, y: 0.0, width: w, height: h },
                    SplitCell { x: w - m - pw, y: h - m * h / w - ph, width: pw, height: ph },
                ]
            }
            SplitLayoutPreset::PictureInPictureCircle => {
                let (side, m) = (w * PIP_WIDTH_FRACTION, w * PIP_MARGIN_FRACTION);
                vec![
                    SplitCell { x: 0.0, y: 0.0, width: w, height: h },
                    SplitCell { x: w - m - side, y: h - m - side, width: side, height: side },
                ]
            }
        }
    }

    fn columns(f: &[f64], w: f64, h: f64, g: f64) -> Vec<SplitCell> {
        let mut x = 0.0;
        (0..f.len())
            .map(|i| {
                let cw = if i == f.len() - 1 { w - x } else { w * f[i] };
                let at = x;
                x += cw;
                let l = if i > 0 { g } else { 0.0 };
                let r = if i < f.len() - 1 { g } else { 0.0 };
                SplitCell { x: at + l, y: 0.0, width: cw - l - r, height: h }
            })
            .collect()
    }

    fn rows(f: &[f64], w: f64, h: f64, g: f64) -> Vec<SplitCell> {
        let mut y = 0.0;
        (0..f.len())
            .map(|i| {
                let ch = if i == f.len() - 1 { h - y } else { h * f[i] };
                let at = y;
                y += ch;
                let t = if i > 0 { g } else { 0.0 };
                let b = if i < f.len() - 1 { g } else { 0.0 };
                SplitCell { x: 0.0, y: at + t, width: w, height: ch - t - b }
            })
            .collect()
    }

    /// Cover fit of a `picture` (upright pixels, width and height) into `cell`.
    pub fn placement(cell: SplitCell, picture: (i64, i64), w: f64, h: f64) -> SplitPlacement {
        let pw = picture.0.max(1) as f64;
        let ph = picture.1.max(1) as f64;
        let s = (cell.width / pw).max(cell.height / ph);
        let (shown_w, shown_h) = (pw * s, ph * s);
        let cx = (1.0 - (cell.width / shown_w).min(1.0)) / 2.0;
        let cy = (1.0 - (cell.height / shown_h).min(1.0)) / 2.0;
        SplitPlacement {
            scale: s,
            position: Vec2::new(cell.x + cell.width / 2.0 - w / 2.0, cell.y + cell.height / 2.0 - h / 2.0),
            crop: CropInsets { left: cx, top: cy, right: cx, bottom: cy },
        }
    }
}

/// How the cells come and go.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitAnimationStyle {
    /// The cell slides in from outside the frame (Position keys).
    Slide,
    /// The cell is revealed from one edge (Crop keys).
    Wipe,
    /// The cell grows from nothing (Scale keys).
    Scale,
}

/// Side a cell comes from (slide, wipe). Cells alternate: the second one comes from the opposite side, and so on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitDirection {
    /// From the left.
    Left,
    /// From the right.
    Right,
    /// From the top.
    Top,
    /// From the bottom.
    Bottom,
}

impl SplitDirection {
    fn opposite(self) -> SplitDirection {
        match self {
            SplitDirection::Left => SplitDirection::Right,
            SplitDirection::Right => SplitDirection::Left,
            SplitDirection::Top => SplitDirection::Bottom,
            SplitDirection::Bottom => SplitDirection::Top,
        }
    }
}

/// The ease of the in and out.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitEase {
    /// Straight.
    Linear,
    /// Slow start.
    EaseIn,
    /// Slow arrival.
    EaseOut,
    /// Slow at both ends.
    EaseInOut,
}

impl SplitEase {
    /// Handles of the in segment (leaving the first key, arriving at the second).
    fn handles(self) -> (EaseHandle, EaseHandle) {
        let h = |dx: f64, dy: f64| EaseHandle { dx, dy };
        match self {
            SplitEase::Linear => (EaseHandle::LINEAR, EaseHandle::LINEAR),
            SplitEase::EaseIn => (h(0.42, 0.0), h(0.0, 0.0)),
            SplitEase::EaseOut => (h(0.0, 0.0), h(0.42, 0.0)),
            SplitEase::EaseInOut => (h(0.42, 0.0), h(0.42, 0.0)),
        }
    }
}

/// In and out animation of the cells.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SplitAnimation {
    /// What moves.
    pub style: SplitAnimationStyle,
    /// Where the first cell comes from.
    pub direction: SplitDirection,
    /// Ease of in and out.
    pub ease: SplitEase,
    /// Length of the in and of the out, clamped to half the clip.
    pub duration: Time,
    /// Animate the in.
    pub animate_in: bool,
    /// Animate the out.
    pub animate_out: bool,
    /// Second, fourth... cell comes from the opposite side.
    pub alternate: bool,
}

impl Default for SplitAnimation {
    /// Slide from the left, ease in-out, half a second, in and out, alternating.
    fn default() -> SplitAnimation {
        SplitAnimation {
            style: SplitAnimationStyle::Slide,
            direction: SplitDirection::Left,
            ease: SplitEase::EaseInOut,
            duration: Time::new(1, 2),
            animate_in: true,
            animate_out: true,
            alternate: true,
        }
    }
}

/// What `split_keys` needs besides the values.
#[derive(Clone, Copy)]
struct KeyPlan {
    length: Time,
    d: Time,
    ease: SplitEase,
    animate_in: bool,
    animate_out: bool,
}

/// Hidden -> final over `duration` at the head, final -> hidden at the tail (reverse curve), keys on a shared time merged.
fn split_keys<V: KeyframeValue>(
    final_value: &V,
    hidden: &V,
    plan: &KeyPlan,
    ids: &mut dyn IdSource,
) -> Vec<Keyframe<V>> {
    let KeyPlan { length, d, ease, animate_in, animate_out } = *plan;
    let (out_h, in_h) = ease.handles();
    let shape = if ease == SplitEase::Linear { Interpolation::Linear } else { Interpolation::Bezier };
    let mut keys: Vec<Keyframe<V>> = Vec::new();
    if animate_in {
        let mut a = Keyframe::new(ids.next_id(), Time::ZERO, hidden.clone());
        (a.interpolation, a.out_handle) = (shape, out_h);
        let mut b = Keyframe::new(ids.next_id(), d, final_value.clone());
        (b.interpolation, b.in_handle) = (shape, in_h);
        keys.push(a);
        keys.push(b);
    } else {
        keys.push(Keyframe::new(ids.next_id(), Time::ZERO, final_value.clone()));
    }
    if animate_out {
        let from = length - d;
        match keys.last_mut().filter(|last| last.time == from) {
            Some(last) => {
                last.out_handle = in_h;
                last.interpolation = shape;
            }
            None => {
                let mut k = Keyframe::new(ids.next_id(), from, final_value.clone());
                (k.interpolation, k.out_handle) = (shape, in_h);
                keys.push(k);
            }
        }
        let mut end = Keyframe::new(ids.next_id(), length, hidden.clone());
        (end.interpolation, end.in_handle) = (shape, out_h);
        keys.push(end);
    } else if keys.len() == 1 {
        keys.clear();
    }
    keys
}

/// Whole frames of `fd` in `t`, rounded down, at most half of `len`.
fn frames_floor(t: Time, fd: Time, len: Time) -> Time {
    let count = |x: Time| -> i64 {
        if x <= Time::ZERO || fd.value() <= 0 {
            return 0;
        }
        match (x.value().checked_mul(fd.timescale()), x.timescale().checked_mul(fd.value())) {
            (Some(n), Some(dn)) if dn != 0 => n / dn,
            _ => 0,
        }
    };
    fd * count(t).min(count(len) / 2)
}

/// The canvas and animation a layout is written for.
#[derive(Clone, Copy)]
struct SplitFrame<'a> {
    canvas: (f64, f64),
    animation: Option<&'a SplitAnimation>,
    frame_duration: Time,
}

/// Split placement on a clip.
trait ClipSplitExt {
    fn apply_split_placement(
        &mut self,
        p: &SplitPlacement,
        slot: (usize, SplitCell),
        frame: &SplitFrame,
        ids: &mut dyn IdSource,
    );
    fn set_circle_corners(&mut self, diameter: f64, scale: f64, ids: &mut dyn IdSource);
}

impl ClipSplitExt for Clip {
    /// Writes one cell: static Scale/Position, a Crop effect (reused when present, added when needed), all earlier keys of
    /// those properties removed. Optional in/out keys on top.
    fn apply_split_placement(
        &mut self,
        p: &SplitPlacement,
        slot: (usize, SplitCell),
        frame: &SplitFrame,
        ids: &mut dyn IdSource,
    ) {
        let (cell_index, cell) = slot;
        let SplitFrame { canvas: (w, h), animation: split_animation, frame_duration } = *frame;
        let (l, t, r, b) = (p.crop.left * 100.0, p.crop.top * 100.0, p.crop.right * 100.0, p.crop.bottom * 100.0);
        // Cover fit and crop assume an upright picture around its center.
        self.animation.rotation = AnimatedProperty::new(0.0);
        self.animation.anchor = AnimatedProperty::new(Vec2::new(0.0, 0.0));
        let mut scale = AnimatedProperty::new(Vec2::new(p.scale, p.scale));
        let mut position = AnimatedProperty::new(p.position);
        let mut crops: BTreeMap<String, AnimatedProperty<f64>> = [
            (ClipEffect::CROP_LEFT_KEY, l),
            (ClipEffect::CROP_TOP_KEY, t),
            (ClipEffect::CROP_RIGHT_KEY, r),
            (ClipEffect::CROP_BOTTOM_KEY, b),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), AnimatedProperty::new(v)))
        .collect();

        let len = self.duration();
        // Whole frames, rounded down, at most half the clip: in and out never overlap and keys stay ordered.
        let d = split_animation.map_or(Time::ZERO, |a| frames_floor(a.duration, frame_duration, len));
        if let Some(a) = split_animation.filter(|a| d > Time::ZERO && (a.animate_in || a.animate_out)) {
            let plan = KeyPlan { length: len, d, ease: a.ease, animate_in: a.animate_in, animate_out: a.animate_out };
            let dir = if a.alternate && cell_index % 2 == 1 { a.direction.opposite() } else { a.direction };
            match a.style {
                SplitAnimationStyle::Slide => {
                    let mut hidden = p.position;
                    match dir {
                        SplitDirection::Left => hidden.x = -w / 2.0 - cell.width / 2.0,
                        SplitDirection::Right => hidden.x = w / 2.0 + cell.width / 2.0,
                        SplitDirection::Top => hidden.y = -h / 2.0 - cell.height / 2.0,
                        SplitDirection::Bottom => hidden.y = h / 2.0 + cell.height / 2.0,
                    }
                    position.track.keys = split_keys(&position.value, &hidden, &plan, ids);
                }
                SplitAnimationStyle::Scale => {
                    scale.track.keys = split_keys(&scale.value, &Vec2::new(0.0, 0.0), &plan, ids);
                }
                SplitAnimationStyle::Wipe => {
                    let (key, hidden) = match dir {
                        SplitDirection::Left => (ClipEffect::CROP_RIGHT_KEY, (100.0 - l).max(r)),
                        SplitDirection::Right => (ClipEffect::CROP_LEFT_KEY, (100.0 - r).max(l)),
                        SplitDirection::Top => (ClipEffect::CROP_BOTTOM_KEY, (100.0 - t).max(b)),
                        SplitDirection::Bottom => (ClipEffect::CROP_TOP_KEY, (100.0 - b).max(t)),
                    };
                    if let Some(prop) = crops.get_mut(key) {
                        prop.track.keys = split_keys(&prop.value, &hidden, &plan, ids);
                    }
                }
            }
        }

        self.animation.scale = scale;
        self.animation.position = position;
        let has_crop = crops.values().any(|c| c.value != 0.0 || c.is_animated());
        let index = match self.effects.iter().position(|e| e.kind == ClipEffect::CROP_KIND) {
            Some(i) => Some(i),
            None if has_crop => {
                let added = self.add_effect(ClipEffect::CROP_KIND, None, ids);
                added.and_then(|id| self.effects.iter().position(|e| e.id == id))
            }
            None => None,
        };
        if let Some(i) = index {
            self.effects[i].parameters.extend(crops);
        }
    }

    /// Rounded Corners at half the cell side; the radius is layer-local, so it is divided by the clip's scale.
    fn set_circle_corners(&mut self, diameter: f64, scale: f64, ids: &mut dyn IdSource) {
        let r = diameter / 2.0 / scale.max(1e-9);
        match self.effects.iter().position(|e| e.kind == ClipEffect::ROUNDED_CORNERS_KIND) {
            Some(i) => {
                self.effects[i].parameters.insert(ClipEffect::RADIUS_KEY.to_string(), AnimatedProperty::new(r));
            }
            None => self.effects.push(ClipEffect::rounded_corners(ids.next_id(), r)),
        }
    }
}

/// The split screen command.
pub trait ProjectSplitLayoutExt {
    /// Applies `preset` to the video clips in `ids`, ordered by track (lowest track = first cell). Clips beyond the preset's
    /// cell count are left alone; fewer clips than cells fails with `TooFewClips`. Picture size comes from the media
    /// (generators and unknown media count as frame-sized). `animation` writes in/out keys; `None` = static layout. Fails with
    /// `Edit(TrackLocked)` / `Edit(TimelineNotFound)`; nothing changes then. Returns the number of clips changed.
    fn apply_split_layout(
        &mut self,
        preset: SplitLayoutPreset,
        clip_ids: &BTreeSet<Id>,
        timeline: Id,
        gap: f64,
        animation: Option<&SplitAnimation>,
        ids: &mut dyn IdSource,
    ) -> Result<usize, SplitLayoutError>;
}

impl ProjectSplitLayoutExt for Project {
    fn apply_split_layout(
        &mut self,
        preset: SplitLayoutPreset,
        clip_ids: &BTreeSet<Id>,
        timeline: Id,
        gap: f64,
        animation: Option<&SplitAnimation>,
        ids: &mut dyn IdSource,
    ) -> Result<usize, SplitLayoutError> {
        let ti = self
            .timelines
            .iter()
            .position(|t| t.id == timeline)
            .ok_or(SplitLayoutError::Edit(EditError::TimelineNotFound))?;
        let mut work = self.timelines[ti].clone();
        let mut targets: Vec<(usize, Clip)> = Vec::new();
        for (tr, track) in work.tracks.iter().enumerate().filter(|(_, t)| t.kind == TrackKind::Video) {
            targets.extend(track.clips().iter().filter(|c| clip_ids.contains(&c.id)).map(|c| (tr, c.clone())));
        }
        let distinct: BTreeSet<usize> = targets.iter().map(|t| t.0).collect();
        if distinct.len() != targets.len() {
            return Err(SplitLayoutError::SameTrack);
        }
        if targets.len() < preset.cell_count() {
            return Err(SplitLayoutError::TooFewClips { required: preset.cell_count() });
        }
        let (display_width, height) = (work.format.display_width(), work.format.height);
        let (w, h) = (display_width as f64, height as f64);
        let cells = SplitLayout::cells(preset, w, h, gap);
        let mut changed = 0;
        for (i, cell) in cells.iter().enumerate() {
            let (tr, c) = &targets[i];
            if work.tracks[*tr].is_locked {
                return Err(SplitLayoutError::Edit(EditError::TrackLocked));
            }
            let size = self.picture_size(c).unwrap_or((display_width, height));
            let placement = SplitLayout::placement(*cell, size, w, h);
            let mut n = c.clone();
            let frame = SplitFrame { canvas: (w, h), animation, frame_duration: work.format.frame_duration };
            n.apply_split_placement(&placement, (i, *cell), &frame, ids);
            if preset == SplitLayoutPreset::PictureInPictureCircle && i == 1 {
                n.set_circle_corners(cell.width, placement.scale, ids);
            }
            if n != *c {
                work.tracks[*tr].replace(n);
                changed += 1;
            }
        }
        if changed > 0 {
            self.timelines[ti] = work;
        }
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sq_core_model::{MediaFingerprint, MediaRef, SequenceFormat, Timeline, Track};
    use sq_core_time::{SequentialIds, TimeRange};

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn v(x: f64, y: f64) -> Vec2 {
        Vec2::new(x, y)
    }

    fn media_ref() -> MediaRef {
        let mut m = MediaRef::new(Id::from_u128(77), "m", "/m.mov", MediaFingerprint::new(1));
        m.duration = Some(s(10));
        m.info = serde_json::from_value(json!({"duration": {"value": 10, "timescale": 1}, "video": {
            "width": 1920, "height": 1080, "codec": "hvc1", "bitDepth": 10, "chroma": "4:2:0",
            "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0}}))
        .ok();
        m
    }

    struct Setup {
        p: Project,
        tl: Id,
        clips: BTreeSet<Id>,
        order: Vec<Id>,
        ids: SequentialIds,
    }

    /// `n` stacked video tracks, one clip of `frames` frames of `frame` each (V1 first), all 1920x1080 pictures.
    fn setup(seq_w: i64, seq_h: i64, n: usize, clip_len: Time, frame: Time) -> Setup {
        let m = media_ref();
        let mut format = SequenceFormat::new(frame);
        format.width = seq_w;
        format.height = seq_h;
        let (mut order, mut tracks) = (Vec::new(), Vec::new());
        for i in 0..n {
            let c = Clip::new(
                Id::from_u128(100 + i as u128),
                &format!("c{i}"),
                m.id,
                TrackKind::Video,
                TimeRange::new(Time::ZERO, clip_len),
                Time::ZERO,
            );
            order.push(c.id);
            let mut t = Track::new(Id::from_u128(200 + i as u128), TrackKind::Video);
            t.set_clips(vec![c]);
            tracks.push(t);
        }
        let tl = Timeline::new(Id::from_u128(300), "T", format, tracks);
        let id = tl.id;
        let p = Project::new(Id::from_u128(301), "t", vec![m], vec![tl]);
        Setup { p, tl: id, clips: order.iter().copied().collect(), order, ids: SequentialIds::default() }
    }

    fn std_setup(n: usize) -> Setup {
        setup(1920, 1080, n, s(10), fd())
    }

    fn clip(p: &Project, id: Id) -> Clip {
        p.timelines[0].tracks.iter().find_map(|t| t.clip(id)).cloned().unwrap()
    }

    fn crop(c: &Clip, key: &str) -> f64 {
        c.effects
            .iter()
            .find(|e| e.kind == ClipEffect::CROP_KIND)
            .and_then(|e| e.parameters.get(key))
            .map_or(0.0, |p| p.value)
    }

    fn apply(
        st: &mut Setup,
        preset: SplitLayoutPreset,
        subset: Option<&BTreeSet<Id>>,
        anim: Option<&SplitAnimation>,
    ) -> Result<usize, SplitLayoutError> {
        let ids = subset.unwrap_or(&st.clips).clone();
        st.p.apply_split_layout(preset, &ids, st.tl, 0.0, anim, &mut st.ids)
    }

    fn cell(x: f64, y: f64, width: f64, height: f64) -> SplitCell {
        SplitCell { x, y, width, height }
    }

    // geometry

    #[test]
    fn halves_16_by_9() {
        let cells = SplitLayout::cells(SplitLayoutPreset::SideBySide, 1920.0, 1080.0, 0.0);
        assert_eq!(cells, vec![cell(0.0, 0.0, 960.0, 1080.0), cell(960.0, 0.0, 960.0, 1080.0)]);
    }

    #[test]
    fn placement_cover_fits_and_crops() {
        // 16:9 picture into a 960x1080 cell on a 1920x1080 canvas: scale 1 (height fits), crop width 960 of 1920.
        let p = SplitLayout::placement(cell(0.0, 0.0, 960.0, 1080.0), (1920, 1080), 1920.0, 1080.0);
        assert_eq!((p.scale, p.position), (1.0, v(-480.0, 0.0)));
        assert!((p.crop.left - 0.25).abs() < 1e-9 && (p.crop.right - 0.25).abs() < 1e-9);
        assert!(p.crop.top == 0.0 && p.crop.bottom == 0.0);
    }

    #[test]
    fn halves_9_by_16() {
        // Vertical canvas 1080x1920, top/bottom halves: cells 1080x960. 16:9 picture covers at scale 960/1080.
        let cells = SplitLayout::cells(SplitLayoutPreset::Stacked, 1080.0, 1920.0, 0.0);
        assert_eq!(cells[0], cell(0.0, 0.0, 1080.0, 960.0));
        let p = SplitLayout::placement(cells[1], (1920, 1080), 1080.0, 1920.0);
        let sc = 960.0 / 1080.0;
        assert!((p.scale - sc).abs() < 1e-9);
        assert_eq!(p.position, v(0.0, 480.0));
        let c = (1.0 - 1080.0 / (1920.0 * sc)) / 2.0;
        assert!((p.crop.left - c).abs() < 1e-9 && (p.crop.right - c).abs() < 1e-9);
    }

    #[test]
    fn sixty_forty_and_three() {
        let c = SplitLayout::cells(SplitLayoutPreset::SixtyForty, 1920.0, 1080.0, 0.0);
        assert!(c[0].width == 1152.0 && c[1].x == 1152.0 && c[1].width == 768.0);
        let t = SplitLayout::cells(SplitLayoutPreset::ThreeStacked, 1080.0, 1920.0, 0.0);
        assert_eq!(t.len(), 3);
        assert_eq!(t.iter().map(|c| c.height).sum::<f64>(), 1920.0);
        assert_eq!(t[2].y, 1280.0);
    }

    #[test]
    fn picture_in_picture_corner() {
        let c = SplitLayout::cells(SplitLayoutPreset::PictureInPicture, 1920.0, 1080.0, 0.0);
        assert_eq!(c[0], cell(0.0, 0.0, 1920.0, 1080.0));
        assert!(c[1].width == 576.0 && c[1].height == 324.0);
        assert!((c[1].x + c[1].width - (1920.0 - 76.8)).abs() < 1e-9);
    }

    #[test]
    fn picture_in_picture_circle_is_square_with_rounded_corners() {
        let c = SplitLayout::cells(SplitLayoutPreset::PictureInPictureCircle, 1920.0, 1080.0, 0.0);
        assert!(c[1].width == 576.0 && c[1].height == 576.0);
        let mut st = std_setup(2);
        apply(&mut st, SplitLayoutPreset::PictureInPictureCircle, None, None).unwrap();
        let top = clip(&st.p, st.order[1]);
        let r = top
            .effects
            .iter()
            .find(|e| e.kind == ClipEffect::ROUNDED_CORNERS_KIND)
            .and_then(|e| e.parameters.get(ClipEffect::RADIUS_KEY))
            .map(|p| p.value);
        assert!(r.is_some());
        assert!((r.unwrap_or(0.0) * top.animation.scale.value.x - 288.0).abs() < 1e-6);
        assert!(clip(&st.p, st.order[0]).effects.iter().all(|e| e.kind != ClipEffect::ROUNDED_CORNERS_KIND));
    }

    #[test]
    fn gap_shrinks_inner_edges() {
        let c = SplitLayout::cells(SplitLayoutPreset::SideBySide, 1920.0, 1080.0, 20.0);
        assert_eq!(c, vec![cell(0.0, 0.0, 950.0, 1080.0), cell(970.0, 0.0, 950.0, 1080.0)]);
    }

    // applying

    #[test]
    fn apply_writes_motion_and_crop() {
        let mut st = std_setup(2);
        assert_eq!(apply(&mut st, SplitLayoutPreset::SideBySide, None, None), Ok(2));
        let (a, b) = (clip(&st.p, st.order[0]), clip(&st.p, st.order[1]));
        assert_eq!(a.animation.scale.value, v(1.0, 1.0));
        assert_eq!(a.animation.position.value, v(-480.0, 0.0));
        assert_eq!(b.animation.position.value, v(480.0, 0.0));
        assert!(crop(&a, ClipEffect::CROP_LEFT_KEY) == 25.0 && crop(&a, ClipEffect::CROP_RIGHT_KEY) == 25.0);
        assert!(!a.animation.position.is_animated());
    }

    #[test]
    fn apply_twice_keeps_one_crop_effect_and_is_editable() {
        let mut st = std_setup(2);
        apply(&mut st, SplitLayoutPreset::SideBySide, None, None).unwrap();
        apply(&mut st, SplitLayoutPreset::Stacked, None, None).unwrap();
        let a = clip(&st.p, st.order[0]);
        assert_eq!(a.effects.iter().filter(|e| e.kind == ClipEffect::CROP_KIND).count(), 1);
        assert_eq!(a.animation.position.value, v(0.0, -270.0));
    }

    #[test]
    fn needs_enough_clips() {
        let mut st = std_setup(2);
        assert_eq!(
            apply(&mut st, SplitLayoutPreset::ThreeStacked, None, None),
            Err(SplitLayoutError::TooFewClips { required: 3 })
        );
        let one: BTreeSet<Id> = [st.order[0]].into_iter().collect();
        assert!(apply(&mut st, SplitLayoutPreset::SideBySide, Some(&one), None).is_err());
    }

    // animation

    fn animated(
        style: SplitAnimationStyle,
        direction: SplitDirection,
        ease: SplitEase,
        in_out: (bool, bool),
    ) -> (Clip, Clip) {
        let mut st = std_setup(2);
        let anim = SplitAnimation {
            style,
            direction,
            ease,
            duration: s(1),
            animate_in: in_out.0,
            animate_out: in_out.1,
            ..SplitAnimation::default()
        };
        apply(&mut st, SplitLayoutPreset::SideBySide, None, Some(&anim)).unwrap();
        (clip(&st.p, st.order[0]), clip(&st.p, st.order[1]))
    }

    fn slide() -> (Clip, Clip) {
        animated(SplitAnimationStyle::Slide, SplitDirection::Left, SplitEase::Linear, (true, true))
    }

    #[test]
    fn slide_in_out_values() {
        let (a, b) = slide();
        let len = s(10);
        let pos = |t: Time| a.animation.position.value_at_local(t);
        // Left cell enters from the left: cell right edge at canvas left edge -> x = -960 - 480.
        assert_eq!(pos(Time::ZERO), v(-1440.0, 0.0));
        assert_eq!(pos(Time::new(1, 2)), v(-960.0, 0.0)); // linear midpoint
        assert_eq!(pos(s(1)), v(-480.0, 0.0));
        assert_eq!(pos(s(5)), v(-480.0, 0.0));
        assert_eq!(pos(len - Time::new(1, 2)), v(-960.0, 0.0));
        assert_eq!(pos(len), v(-1440.0, 0.0));
        // Second cell alternates: enters from the right.
        assert_eq!(b.animation.position.value_at_local(Time::ZERO), v(1440.0, 0.0));
    }

    #[test]
    fn slide_in_only() {
        let (a, _) = animated(SplitAnimationStyle::Slide, SplitDirection::Left, SplitEase::Linear, (true, false));
        assert_eq!(a.animation.position.track.keys.len(), 2);
        assert_eq!(a.animation.position.value_at_local(s(10)), v(-480.0, 0.0));
    }

    #[test]
    fn wipe_in_out_values() {
        let (a, _) = animated(SplitAnimationStyle::Wipe, SplitDirection::Left, SplitEase::Linear, (true, true));
        let right = |t: Time| a.effects[0].parameters[ClipEffect::CROP_RIGHT_KEY].value_at_local(t);
        assert_eq!(right(Time::ZERO), 75.0); // 100 - left(25): nothing visible
        assert_eq!((right(Time::new(1, 2)), right(s(1)), right(s(10))), (50.0, 25.0, 75.0));
        assert_eq!(a.animation.position.value, v(-480.0, 0.0));
    }

    #[test]
    fn scale_in_out_values() {
        let (a, _) = animated(SplitAnimationStyle::Scale, SplitDirection::Left, SplitEase::Linear, (true, true));
        let sc = |t: Time| a.animation.scale.value_at_local(t);
        assert_eq!((sc(Time::ZERO), sc(Time::new(1, 2))), (v(0.0, 0.0), v(0.5, 0.5)));
        assert_eq!((sc(s(5)), sc(s(10))), (v(1.0, 1.0), v(0.0, 0.0)));
    }

    #[test]
    fn ease_out_is_fast_at_start() {
        let (a, _) = animated(SplitAnimationStyle::Scale, SplitDirection::Left, SplitEase::EaseOut, (true, true));
        let mid = a.animation.scale.value_at_local(Time::new(1, 2)).x;
        assert!(mid > 0.5 && mid < 1.0);
        let (c, _) = animated(SplitAnimationStyle::Scale, SplitDirection::Left, SplitEase::EaseIn, (true, true));
        let mid_in = c.animation.scale.value_at_local(Time::new(1, 2)).x;
        assert!(mid_in < 0.5 && mid_in > 0.0);
        assert_eq!(c.animation.scale.value_at_local(s(1)), v(1.0, 1.0));
    }

    #[test]
    fn duration_clamped_to_half_clip() {
        let mut st = std_setup(2);
        let anim = SplitAnimation { duration: s(30), ..SplitAnimation::default() };
        apply(&mut st, SplitLayoutPreset::SideBySide, None, Some(&anim)).unwrap();
        let keys: Vec<Time> = clip(&st.p, st.order[0]).animation.position.track.keys.iter().map(|k| k.time).collect();
        assert!(keys.first() == Some(&Time::ZERO) && keys.last() == Some(&s(10)));
        assert!(keys.iter().all(|k| *k <= s(10)));
    }

    #[test]
    fn reapply_without_animation_clears_keys() {
        let mut st = std_setup(2);
        apply(&mut st, SplitLayoutPreset::SideBySide, None, Some(&SplitAnimation::default())).unwrap();
        apply(&mut st, SplitLayoutPreset::SideBySide, None, None).unwrap();
        assert!(!clip(&st.p, st.order[0]).animation.position.is_animated());
    }

    // review fixes

    #[test]
    fn odd_frame_counts_give_strictly_increasing_keys() {
        let f24 = Time::new(1, 24);
        for frames in [1_i64, 2, 3, 5] {
            let mut st = setup(1920, 1080, 2, f24 * frames, f24);
            let anim = SplitAnimation { ease: SplitEase::Linear, ..SplitAnimation::default() };
            apply(&mut st, SplitLayoutPreset::SideBySide, None, Some(&anim)).unwrap();
            let keys: Vec<Time> =
                st.p.timelines[0].tracks[0].clips()[0].animation.position.track.keys.iter().map(|k| k.time).collect();
            assert!(keys.windows(2).all(|w| w[0] < w[1]), "frames {frames}: {keys:?}");
            assert!(keys.iter().all(|k| *k <= f24 * frames));
            if frames == 1 {
                assert!(keys.is_empty());
            }
        }
    }

    #[test]
    fn layout_resets_rotation_and_anchor() {
        let mut st = std_setup(2);
        let mut c = clip(&st.p, st.order[0]);
        c.animation.rotation = AnimatedProperty::new(90.0);
        c.animation.anchor = AnimatedProperty::new(v(40.0, 20.0));
        st.p.timelines[0].tracks[0].replace(c);
        apply(&mut st, SplitLayoutPreset::SideBySide, None, None).unwrap();
        let a = clip(&st.p, st.order[0]);
        assert!(a.animation.rotation.value == 0.0 && !a.animation.rotation.is_animated());
        assert_eq!(a.animation.anchor.value, v(0.0, 0.0));
    }

    #[test]
    fn clips_on_the_same_track_are_refused() {
        let mut st = std_setup(1);
        let m = st.p.media[0].id;
        let second = Clip::new(Id::from_u128(150), "d", m, TrackKind::Video, TimeRange::new(Time::ZERO, s(5)), s(10));
        st.p.timelines[0].tracks[0].overwrite(second, &mut st.ids).unwrap();
        let all: BTreeSet<Id> = st.p.timelines[0].tracks[0].clips().iter().map(|c| c.id).collect();
        assert_eq!(all.len(), 2);
        assert_eq!(apply(&mut st, SplitLayoutPreset::SideBySide, Some(&all), None), Err(SplitLayoutError::SameTrack));
    }

    #[test]
    fn locked_track_and_unknown_timeline_change_nothing() {
        let mut st = std_setup(2);
        st.p.timelines[0].tracks[1].is_locked = true;
        let before = st.p.clone();
        assert_eq!(
            apply(&mut st, SplitLayoutPreset::SideBySide, None, None),
            Err(SplitLayoutError::Edit(EditError::TrackLocked))
        );
        assert_eq!(st.p, before);
        let r =
            st.p.apply_split_layout(SplitLayoutPreset::SideBySide, &st.clips, Id::from_u128(9), 0.0, None, &mut st.ids);
        assert_eq!(r, Err(SplitLayoutError::Edit(EditError::TimelineNotFound)));
    }
}
