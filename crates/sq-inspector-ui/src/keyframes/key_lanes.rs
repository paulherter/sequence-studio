// Swift: KeyLanes.swift
//! Key lane on a timeline clip: a thin strip along the bottom of the clip body with one diamond per key time of the
//! effect section selected in Effect Controls (all of its properties merged, one glyph per time). Shown on selected
//! clips only, so the timeline stays quiet otherwise. Pure geometry, portable. Positions come from an `x` closure so
//! this file needs no timeline module.

use std::collections::BTreeSet;

use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyID};
use sq_core_model::{Clip, TrackKind};
use sq_core_time::Time;
use sq_editor_session::EffectSection;
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::section::EffectSectionExt;
use crate::ec::magic_tracked_frames::MagicTrackedFrames;
use sq_core_masks::masks::ClipMasksExt;

/// One glyph of a drawn lane.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyLaneGlyph {
    pub center: Point,
    pub time: Time,
    pub selected: bool,
}

/// One drawn lane: the strip and the glyphs inside the visible span, each with its timeline time.
#[derive(Clone, Debug, PartialEq)]
pub struct KeyLaneLayout {
    pub lane: Rect,
    pub glyphs: Vec<KeyLaneGlyph>,
}

pub enum KeyLanes {}

impl KeyLanes {
    /// Rows shorter than this show no lane.
    pub const MIN_ROW_HEIGHT: f64 = 40.0;
    pub const LANE_HEIGHT: f64 = 10.0;
    pub const GLYPH_SIZE: f64 = 7.0;

    /// Timeline times of the keys of `section` on `clip`, sorted, one per distinct time. A mask section includes its Path
    /// keys, a Magic mask section its tracked frames (`magic`: where those come from, None = not shown).
    pub fn key_times(
        clip: &Clip,
        section: &EffectSection,
        frame_duration: Time,
        magic: Option<&MagicTrackedFrames>,
    ) -> Vec<Time> {
        let props: BTreeSet<PropertyID> = section.key_properties().iter().map(|p| p.id()).collect();
        let groups = KeyframeSummary::new(EffectControlsModel::tracks_of(clip)).groups(Some(&props));
        let mut local: Vec<Time> = groups.iter().map(|g| g.time).collect();
        if let EffectSection::Mask(id) = section
            && let Some(frames) = magic
            && let Some(m) = clip.mask(*id)
            && let Some(key) = EffectControlsModel::magic_cache_key(m, clip)
        {
            let tracked = frames.keys(clip, m, &key, frame_duration);
            let mut all: BTreeSet<Time> = local.iter().copied().collect();
            all.extend(tracked.iter().map(|k| k.time));
            local = all.into_iter().collect();
        }
        local.into_iter().map(|t| clip.start + t).collect()
    }

    /// Cheap checks before any key work: a lane is possible for this clip, section, selection and row height.
    pub fn is_applicable(clip: &Clip, section: Option<&EffectSection>, selected: bool, row_height: f64) -> bool {
        if !selected || row_height < Self::MIN_ROW_HEIGHT {
            return false;
        }
        let Some(section) = section else { return false };
        match section {
            EffectSection::Volume => clip.kind == TrackKind::Audio,
            EffectSection::Speed => false,
            EffectSection::Motion | EffectSection::Opacity => clip.kind == TrackKind::Video,
            EffectSection::Effect { .. } | EffectSection::Mask(_) | EffectSection::Animation(_) => true,
        }
    }

    pub fn is_visible(
        clip: &Clip,
        section: Option<&EffectSection>,
        selected: bool,
        row_height: f64,
        magic: Option<&MagicTrackedFrames>,
    ) -> bool {
        if !Self::is_applicable(clip, section, selected, row_height) {
            return false;
        }
        let Some(section) = section else { return false };
        !Self::key_times(clip, section, Time::ZERO, magic).is_empty()
    }

    /// The strip inside the clip's full rectangle: bottom of the body.
    pub fn lane(clip_rect: Rect) -> Rect {
        let body = clip_rect.inset_by(0.0, 1.0);
        Rect::new(body.min_x(), body.max_y() - Self::LANE_HEIGHT - 1.0, body.width, Self::LANE_HEIGHT)
    }

    /// Glyph centers (view space) for `times`, skipping those outside `visible` horizontally.
    pub fn glyph_centers(times: &[Time], clip_rect: Rect, visible: Rect, x: impl Fn(Time) -> f64) -> Vec<Point> {
        let lane = Self::lane(clip_rect);
        times
            .iter()
            .map(|t| Point::new(x(*t), lane.mid_y()))
            .filter(|p| p.x >= visible.min_x() - Self::GLYPH_SIZE && p.x <= visible.max_x() + Self::GLYPH_SIZE)
            .collect()
    }

    /// Timeline time of the key glyph under `p` (nil = none): inside the lane strip, within half a glyph plus 2 pt of its center.
    pub fn hit_test(
        clip: &Clip,
        section: &EffectSection,
        clip_rect: Rect,
        p: Point,
        frame_duration: Time,
        magic: Option<&MagicTrackedFrames>,
        x: impl Fn(Time) -> f64,
    ) -> Option<Time> {
        let lane = Self::lane(clip_rect);
        if p.y < lane.min_y() - 2.0 || p.y > lane.max_y() + 2.0 {
            return None;
        }
        let reach = Self::GLYPH_SIZE / 2.0 + 2.0;
        let times = Self::key_times(clip, section, frame_duration, magic);
        let mut best: Option<Time> = None;
        for t in times.into_iter().filter(|t| (x(*t) - p.x).abs() <= reach) {
            if best.is_none_or(|b| (x(t) - p.x).abs() < (x(b) - p.x).abs()) {
                best = Some(t);
            }
        }
        best
    }

    /// Everything one clip's lane draws: nil when the clip shows no lane (not applicable, off screen, no keys).
    pub fn layout(req: &KeyLaneRequest<'_>, x: impl Fn(Time) -> f64) -> Option<KeyLaneLayout> {
        let section = req.section?;
        if req.clip_rect.max_x() < req.visible.min_x()
            || req.clip_rect.min_x() > req.visible.max_x()
            || !Self::is_applicable(
                req.clip,
                Some(section),
                req.selected,
                req.row_height.unwrap_or(req.clip_rect.height),
            )
        {
            return None;
        }
        let times = Self::key_times(req.clip, section, req.frame_duration, req.magic);
        if times.is_empty() {
            return None;
        }
        let strip = Self::lane(req.clip_rect);
        let glyphs = times
            .iter()
            .filter_map(|t| {
                let c = Self::glyph_centers(&[*t], req.clip_rect, req.visible, &x).into_iter().next()?;
                Some(KeyLaneGlyph { center: c, time: *t, selected: req.picked.contains(t) })
            })
            .collect();
        Some(KeyLaneLayout { lane: strip, glyphs })
    }
}

/// Inputs of `KeyLanes::layout`: `picked` are the lane times Effect Controls has selected (`key_lane_selected_times`);
/// `row_height` defaults to the clip rectangle's height.
pub struct KeyLaneRequest<'a> {
    pub clip: &'a Clip,
    pub section: Option<&'a EffectSection>,
    pub clip_rect: Rect,
    pub visible: Rect,
    pub selected: bool,
    pub row_height: Option<f64>,
    pub picked: &'a BTreeSet<Time>,
    pub frame_duration: Time,
    pub magic: Option<&'a MagicTrackedFrames>,
}
