// Swift: TimelinePanel+LaneCache.swift
//! The clip layer's quads of the last frame, with the key they were built for. Backend-neutral: it holds `DrawQuad`s,
//! so every renderer replays them. Two frames with an equal key draw the same quads; the playhead, hover, gesture
//! overlays, ruler and headers are not in the key: they draw live every frame.

use crate::geom::RectExt as _;
use crate::panel::TimelinePanel;
use sq_core_model::LabelResolver;
use sq_core_time::Id;
use sq_draw::{Canvas, DrawQuad, DrawTheme, Rect};
use sq_timeline_ui::{ThumbnailMode, TimelineGeometry, TrackRow};
use sq_uikit::controls_grid::CGRect;
use std::collections::{BTreeMap, BTreeSet};

/// Everything the clip layer's quads depend on.
#[derive(Clone, PartialEq)]
pub(crate) struct LaneCacheKey {
    revision: u64,
    geometry: TimelineGeometry,
    frame: Rect,
    clip: Rect,
    scale: f32,
    size: (f64, f64),
    theme: DrawTheme,
    selection: BTreeSet<Id>,
    labels: LabelResolver,
    speed_band_clips: BTreeSet<Id>,
    grade_outline: BTreeSet<Id>,
    analysis_progress: BTreeMap<Id, u64>,
    selected_line_keys: BTreeSet<Id>,
    thumbnail_mode: ThumbnailMode,
    open_item_lanes: BTreeSet<Id>,
    atlas_generation: u64,
    media_revision: u64,
}

/// The cached clip layer.
/// shortcut: one layer for all rows, upgrade to a layer per row when a single track edit should not rebuild the others.
#[derive(Default)]
pub(crate) struct LaneCache {
    key: Option<LaneCacheKey>,
    quads: Vec<DrawQuad>,
    hits: u64,
    misses: u64,
}

impl LaneCache {
    fn lookup(&mut self, k: &LaneCacheKey) -> Option<&[DrawQuad]> {
        if self.key.as_ref() != Some(k) {
            return None;
        }
        self.hits += 1;
        Some(&self.quads)
    }

    fn store(&mut self, k: LaneCacheKey, q: Vec<DrawQuad>) {
        self.key = Some(k);
        self.quads = q;
        self.misses += 1;
    }

    /// Frames replayed from the cache.
    #[cfg(test)]
    pub(crate) fn hits(&self) -> u64 {
        self.hits
    }
    /// Frames drawn fresh.
    #[cfg(test)]
    pub(crate) fn misses(&self) -> u64 {
        self.misses
    }
}

impl TimelinePanel {
    /// `None` when the media source cannot stamp its changes (the layer is then drawn fresh every frame).
    fn lane_cache_key(&self, cv: &Canvas, clip: Rect) -> Option<LaneCacheKey> {
        let media_revision = match &self.media {
            Some(m) => m.draw_revision()?,
            None => 0,
        };
        Some(LaneCacheKey {
            revision: self.content_revision,
            geometry: self.geometry.clone(),
            frame: self.frame,
            clip,
            scale: self.scale,
            size: (self.size.width, self.size.height),
            theme: self.theme,
            selection: self.selection.clone(),
            labels: self.labels.clone(),
            speed_band_clips: self.speed_band_clips.clone(),
            grade_outline: self.grade_outline.clone(),
            analysis_progress: self.analysis_progress.iter().map(|(k, v)| (*k, v.to_bits())).collect(),
            selected_line_keys: self.selected_line_keys.clone(),
            thumbnail_mode: self.thumbnail_mode,
            open_item_lanes: self.item_lanes.open.clone(),
            atlas_generation: cv.atlas().map_or(0, |a| a.wipes()),
            media_revision,
        })
    }

    /// `drawLanes`, replayed from the cache while nothing it draws has changed.
    pub(crate) fn draw_lanes_through_cache(&mut self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let Some(key) = self.lane_cache_key(cv, cv.list.clip()) else {
            self.draw_lanes(cv, rows, clip);
            return;
        };
        if let Some(quads) = self.lane_cache.lookup(&key) {
            cv.list.append(quads);
            return;
        }
        let start = cv.list.quads().len();
        self.draw_lanes(cv, rows, clip);
        let drawn = cv.list.quads_from(start).to_vec();
        self.lane_cache.store(key, drawn);
    }

    /// The veil of disabled and solo-inactive clips (sliver runs keep theirs in the cached layer). It sits over the clip
    /// and its decorations, so it is drawn after them each frame.
    pub(crate) fn draw_lane_veils(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let solo_active = Self::audio_solo_active(&self.timeline);
        for (row_index, row) in rows.iter().enumerate() {
            let lane = CGRect::new(clip.min_x(), row.y, clip.width, row.height);
            if !lane.intersects(&clip) {
                continue;
            }
            let Some(track) = self.timeline.tracks.iter().find(|t| t.id == row.track) else { continue };
            let inactive = Self::is_inactive(track, solo_active);
            if !(inactive || track.clips().iter().any(|c| !c.is_enabled)) {
                continue;
            }
            let lane_color = if Self::is_alt_lane(row_index, rows) { self.theme.lane() } else { self.theme.timeline() };
            for c in &track.clips()[self.visible_clip_indices(track, clip.min_x(), clip.max_x())] {
                let x0 = self.geometry.x(c.start);
                let x1 = self.geometry.x(c.timeline().end());
                if !(x1 >= clip.min_x() && x0 <= clip.max_x() && x1 - x0 >= 3.0) {
                    continue;
                }
                let fade: Option<f32> = if inactive {
                    Some(if self.selection.contains(&c.id) { 0.5 } else { 0.72 })
                } else if c.is_enabled {
                    None
                } else {
                    Some(0.68)
                };
                let Some(fade) = fade else { continue };
                let body =
                    CGRect::new(x0, row.y, x1 - x0, row.height).inset(0.0, crate::skin::TimelineSkin::CLIP_INSET);
                let radius = f64::from(sq_uikit::design_tokens::sq_tokens::radius::SMALL).min(body.height / 2.0);
                cv.fill_rounded(body, radius, lane_color.with_alpha(fade));
            }
        }
    }
}
