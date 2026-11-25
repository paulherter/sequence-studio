//! Preview size: while playing, a frame is composed at the monitor's pixel size instead of the sequence size when the
//! monitor is smaller (a 4K timeline in a 1500 px viewer). Every pixel parameter of the layer requests is scaled by the
//! same factor (`LayerRequest::scaled`, tested per field); a request that cannot be scaled exactly, or a generator whose
//! raster does not follow the canvas, composes the whole frame at full size. Paused pictures, scrubbing, export and
//! frame grabs never come here (the factor is 1 unless playing).
//! shortcut: generators other than text and adjustment layers (shapes, Lottie, solids) compose at full size, upgrade when their rasters take the canvas.

use sq_core_effects::evaluation::LayerRequest;
use sq_core_effects::preview_scale::{scale_format, scale_transform};
use sq_core_model::SequenceFormat;
use sq_media::video_decoding::DecodeScale;

/// Below this factor a preview is never composed (the picture would be a blur).
const MIN_FACTOR: f64 = 0.25;
/// Above this the saving is too small to leave the exact path.
const MAX_FACTOR: f64 = 0.95;

/// The canvas factor for a monitor of `view` pixels showing a `format` sequence at decode `quality`: the monitor's fit
/// factor, times 1/2 or 1/4 for Half or Quarter. 1.0 = compose at the sequence size.
pub fn factor(format: &SequenceFormat, view: Option<(u32, u32)>, quality: DecodeScale) -> f64 {
    let Some((vw, vh)) = view.filter(|(w, h)| *w > 0 && *h > 0) else { return 1.0 };
    let (w, h) = (format.width.max(1) as f64, format.height.max(1) as f64);
    let fit = (f64::from(vw) / w).min(f64::from(vh) / h) / quality.divisor() as f64;
    if fit > MAX_FACTOR { 1.0 } else { fit.max(MIN_FACTOR) }
}

/// A raster drawn for the sequence size, placed on a canvas `f` times as large: the layer size, position and radius follow
/// the canvas; the picture keeps its pixels (the compositor resamples it) and its animation scale. f = 1 returns it as is.
pub fn scale_raster(mut r: sq_render::program::Raster, f: f64) -> sq_render::program::Raster {
    if f >= 1.0 {
        return r;
    }
    r.layer_width *= f;
    r.layer_height *= f;
    r.corner_radius *= f;
    r.transform = scale_transform(&r.transform, f, false);
    r.sample_transforms = r.sample_transforms.iter().map(|t| scale_transform(t, f, false)).collect();
    r
}

/// `SQ_PREVIEW_TRACE=<file>`: each distinct line once (a bench shows whether the preview scaled or why not).
fn trace(line: &str) {
    static SEEN: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
    let Some(path) = std::env::var_os("SQ_PREVIEW_TRACE") else { return };
    let mut seen = SEEN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if seen.iter().any(|l| l == line) {
        return;
    }
    seen.push(line.to_string());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        use std::io::Write;
        let _ = writeln!(f, "{line}");
    }
}

/// Why a request refuses to scale (the first thing that does).
pub fn why_not(r: &LayerRequest) -> String {
    let e = &r.effects;
    let filters: Vec<String> = e.segments.iter().filter_map(|s| s.filter.as_ref()).map(|f| format!("{f:?}")).collect();
    format!(
        "groups {} shape {} pair {} stack {} gyro {} temporal {} look {} flicker {} filters {:?} generator {:?}",
        r.groups.len(),
        r.shape.is_some(),
        r.pair.is_some(),
        r.stack_transitions.len(),
        r.gyro.is_some(),
        e.temporal.is_some(),
        e.look != sq_core_color::FilmLook::default(),
        e.anti_flicker,
        filters,
        r.generator.as_ref().map(|g| g.kind.clone())
    )
}

/// The frame's requests at factor `f` and the compositor format, or `None` to compose at full size.
pub struct Scaled {
    pub factor: f64,
    pub requests: Vec<LayerRequest>,
    pub format: SequenceFormat,
}

/// `None` when not playing, no monitor size is known, the factor is 1, or one request cannot be scaled.
pub fn plan(
    requests_in: &[LayerRequest],
    format: &SequenceFormat,
    view: Option<(u32, u32)>,
    quality: DecodeScale,
    playing: bool,
) -> Option<Scaled> {
    let requests = requests_in;
    if !playing {
        return None;
    }
    let f = factor(format, view, quality);
    if f >= 1.0 {
        trace(&format!("full size: view {view:?}"));
        return None;
    }
    trace(&format!("scaling at f {f:.3} for view {view:?}"));
    let text = sq_text::text_generator::TextGenerator::KIND;
    if let Some(g) =
        requests.iter().filter(|r| !r.is_adjustment()).filter_map(|r| r.generator.as_ref()).find(|g| g.kind != text)
    {
        trace(&format!("refused at f {f:.3}: generator {:?} composes at full size", g.kind));
        return None;
    }
    let requests = requests.iter().map(|r| r.scaled(f)).collect::<Option<Vec<_>>>();
    let Some(requests) = requests else {
        for r in requests_in.iter().filter(|r| r.scaled(f).is_none()) {
            trace(&format!("refused at f {f:.3}: {}", why_not(r)));
        }
        return None;
    };
    Some(Scaled { factor: f, requests, format: scale_format(format, f) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{Id, Time};

    fn format() -> SequenceFormat {
        let mut f = SequenceFormat::new(Time::new(1, 30));
        f.width = 3840;
        f.height = 2160;
        f
    }

    fn req() -> LayerRequest {
        let mut r = LayerRequest::new(Id::from_u128(1), Id::from_u128(2), Id::from_u128(3), Time::ZERO);
        r.transform.position = sq_core_time::Vec2::new(400.0, 0.0);
        r
    }

    #[test]
    fn the_factor_is_the_monitor_fit_times_the_quality_and_one_without_a_small_monitor() {
        let f = format();
        assert_eq!(factor(&f, Some((1920, 1080)), DecodeScale::Full), 0.5);
        assert_eq!(factor(&f, Some((1920, 1200)), DecodeScale::Full), 0.5, "the tighter side decides");
        assert_eq!(factor(&f, Some((1920, 1080)), DecodeScale::Half), 0.25);
        assert_eq!(factor(&f, Some((1920, 1080)), DecodeScale::Quarter), 0.25, "never below the floor");
        assert_eq!(factor(&f, Some((3840, 2160)), DecodeScale::Full), 1.0);
        assert_eq!(factor(&f, Some((5000, 3000)), DecodeScale::Full), 1.0);
        assert_eq!(factor(&f, None, DecodeScale::Full), 1.0);
        assert_eq!(factor(&f, Some((0, 0)), DecodeScale::Full), 1.0);
    }

    #[test]
    fn a_raster_keeps_its_pixels_and_its_placement_follows_the_canvas() {
        let mut t = sq_core_model::ClipTransform::IDENTITY;
        t.position = sq_core_time::Vec2::new(100.0, -60.0);
        t.scale = sq_core_time::Vec2::new(2.0, 2.0);
        let r = sq_render::program::Raster {
            key: 7,
            width: 640,
            height: 200,
            pixels: std::sync::Arc::new(Vec::new()),
            layer_width: 640.0,
            layer_height: 200.0,
            transform: t,
            corner_radius: 8.0,
            footage_fill: None,
            sample_transforms: vec![t],
        };
        let same = scale_raster(r.clone(), 1.0);
        assert_eq!((same.layer_width, same.transform.position), (640.0, t.position));
        let s = scale_raster(r, 0.5);
        assert_eq!((s.width, s.height, s.key), (640, 200, 7));
        assert_eq!((s.layer_width, s.layer_height, s.corner_radius), (320.0, 100.0, 4.0));
        assert_eq!((s.transform.position, s.transform.scale), (sq_core_time::Vec2::new(50.0, -30.0), t.scale));
        assert_eq!(s.sample_transforms[0].position, s.transform.position);
    }

    #[test]
    fn only_playing_with_a_known_smaller_monitor_scales_and_the_requests_follow_the_format() {
        let f = format();
        let r = [req()];
        assert!(plan(&r, &f, Some((1920, 1080)), DecodeScale::Full, false).is_none(), "paused stays exact");
        assert!(plan(&r, &f, None, DecodeScale::Full, true).is_none());
        assert!(plan(&r, &f, Some((3840, 2160)), DecodeScale::Full, true).is_none(), "f = 1 is the exact path");
        let s = plan(&r, &f, Some((1920, 1080)), DecodeScale::Full, true).unwrap();
        assert_eq!((s.format.width, s.format.height), (1920, 1080));
        assert_eq!(s.requests[0].transform.position.x, 200.0);
    }

    #[test]
    fn a_request_that_cannot_be_scaled_or_a_non_text_generator_composes_the_whole_frame_at_full_size() {
        let f = format();
        let mut blur = req();
        blur.effects.anti_flicker = 1.0;
        assert!(plan(&[req(), blur], &f, Some((1920, 1080)), DecodeScale::Full, true).is_none());
        let mut solid = req();
        solid.generator =
            Some(sq_core_model::GeneratorRef { kind: "solid".into(), payload: vec![], payload_version: 1 });
        assert!(plan(&[req(), solid], &f, Some((1920, 1080)), DecodeScale::Full, true).is_none());
    }
}
