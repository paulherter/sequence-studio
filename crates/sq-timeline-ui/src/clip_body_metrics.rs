// Swift: ClipBodyMetrics.swift
//! The clip body layout both timelines share: the name strip on top of a tall clip and the area under it where the
//! waveform, the thumbnails and the volume / opacity lines live.

use sq_core_audio::audio_gain::AudioGain;
use sq_core_model::Clip;
use sq_core_time::Time;
use sq_uikit::keyframe_graph_geometry::Rect;
use std::sync::Arc;

/// Clip body layout.
pub struct ClipBodyMetrics;

impl ClipBodyMetrics {
    /// Height of the name strip.
    pub const NAME_STRIP_HEIGHT: f64 = sq_uikit::redesign_tokens::size::CLIP_BAND as f64;
    /// Tracks at least this tall put the name in a top band and keep waveform / thumbnails below it (one fill, no second tone).
    pub const BODY_MIN_HEIGHT: f64 = 26.0;

    /// The thumbnail of a media video clip: one tile, 24 pt wide, at the clip start under the name band.
    pub const THUMBNAIL_WIDTH: f64 = sq_uikit::redesign_tokens::size::CLIP_THUMB as f64;

    /// The thumbnail column a clip that is not flat (and not offline) gets in a row of `row_height`: `width`, or 0 when the
    /// row is too low or the clip too narrow for it.
    pub fn thumbnail_column(clip_width: f64, row_height: f64, width: f64) -> f64 {
        if row_height - 2.0 >= Self::BODY_MIN_HEIGHT && clip_width >= width + 24.0 { width } else { 0.0 }
    }

    /// The waveform area inside a clip's full rectangle (also where the volume line moves).
    pub fn waveform_rect(rect: &Rect) -> Rect {
        let body = rect.inset_by(0.0, 1.0);
        let top =
            if body.height >= Self::BODY_MIN_HEIGHT { body.min_y() + Self::NAME_STRIP_HEIGHT } else { body.min_y() };
        Rect::new(body.min_x(), top + 1.0, body.width, body.max_y() - top - 2.0)
    }
}

/// What a clip's waveform shows: the level it plays at and, with a speed track, where each point of the clip reads its
/// source.
pub struct ClipAudioCurves;

impl ClipAudioCurves {
    /// Level in dB at seconds since the clip start for the waveform: Volume line plus Audio Gain.
    pub fn volume_db(clip: &Clip) -> Arc<dyn Fn(f64) -> f64 + Send + Sync> {
        let c = clip.clone();
        if !c.animation.volume.is_animated() {
            // no keys: one level for the whole clip, not one evaluation per column
            let db = AudioGain::db_from_linear(c.volume(c.start));
            return Arc::new(move |_| db);
        }
        Arc::new(move |sec| {
            // `sec` counts source seconds from the clip's source start: map through speed and direction.
            let t = c.timeline_time_for_source(
                c.source.start + Time::new((sec * 1_000_000.0).round() as i64, 1_000_000),
                Time::ZERO,
            );
            AudioGain::db_from_linear(c.volume(t))
        })
    }

    /// Waveform mapping of a clip with a speed track: clip fraction -> source seconds since `source.start` (`None` for
    /// constant clips).
    pub fn source_map(clip: &Clip) -> Option<Arc<dyn Fn(f64) -> f64 + Send + Sync>> {
        let k = clip.speed_keys.clone()?;
        let total = k.duration().value() as f64 / k.duration().timescale() as f64;
        let base = clip.source.start.value() as f64 / clip.source.start.timescale() as f64;
        Some(Arc::new(move |f| k.position_approx(f * total) - base))
    }
}
