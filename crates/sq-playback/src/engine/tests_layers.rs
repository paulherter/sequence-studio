// SPDX-License-Identifier: GPL-3.0-or-later
//! What the Program monitor shows besides the plain picture: title, shape, Lottie and caption layers are drawn by
//! `LayerRasters`, and a clip's color grade goes through `LayerColorResolver`. Each frame is the engine's own composite, read back and compared with the same
//! timeline without the title / without the grade. Skipped with a message when the machine has no GPU adapter.

use super::caption_preview::CaptionPreview;
use super::core::ProgramEngine;
use super::handle::{EngineDeps, RasterProvider};
use super::layer_rasters::LayerRasters;
use super::testkit::{FakeOpener, clip, id, timeline};
use sq_audio_out::clock::HostClock;
use sq_core_color::ClipGradeExt;
use sq_core_graphics::date_stamp::{DateStampCorner, DateStampSpec};
use sq_core_graphics::lottie_generator::LottieSpec;
use sq_core_model::{CaptionItem, CaptionTrack, ClipColor, GeneratorRef, Project, ShapeKind, Timeline, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_gpu::gpu::Gpu;
use sq_lottie::lottie_document::LottieRenderer;
use sq_lottie::lottie_renderer::{LottieDrawing, LottieEngine};
use sq_media::media_opener::MediaOpener;
use sq_render::compositor::LayerColorResolver;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;
use sq_text::text_template::TextTemplate;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn solid(n: u128, rgb: [u8; 3], graded: bool) -> sq_core_model::Clip {
    let mut c = clip(n, id(n), 0, 0, 3);
    if graded {
        // Graded while it is still a picture clip: a generator clip does not take a Color effect from the editor.
        let mut color = ClipColor::default();
        color.edit_effects(|fx| fx[0].basic.exposure = 1.0);
        c.set_color(&color, None, &mut SequentialIds::default());
    }
    c.generator = Some(GeneratorRef { kind: "solid".into(), payload: rgb.to_vec(), payload_version: 1 });
    c
}

fn title(n: u128) -> sq_core_model::Clip {
    let mut c = clip(n, id(n), 0, 0, 3);
    c.kind = TrackKind::Video;
    let style = TextStyle { size: 20.0, ..TextStyle::default() };
    c.generator = TextGenerator::make_ref(&TextTemplate::new("Title", "HELLO", style), None).ok();
    c
}

/// The engine's paused composite at 1 s as RGBA8, or `None` without a GPU.
fn shoot(
    tl: &Timeline,
    rasters: Option<Arc<dyn RasterProvider>>,
    color: Option<Arc<LayerColorResolver>>,
) -> Option<Vec<u8>> {
    shoot_until(tl, rasters, color, &|_| true)
}

/// Like `shoot`, then waits (without any further command) until the shown frame satisfies `ready`.
fn shoot_until(
    tl: &Timeline,
    rasters: Option<Arc<dyn RasterProvider>>,
    color: Option<Arc<LayerColorResolver>>,
    ready: &dyn Fn(&[u8]) -> bool,
) -> Option<Vec<u8>> {
    let gpu = Gpu::new().map_err(|e| eprintln!("skipped: no GPU adapter ({e})")).ok()?;
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    sq_text::portable_font_match::set_fonts_root(&root);
    let opener = Arc::new(FakeOpener::default());
    let mut deps = EngineDeps::new(opener as Arc<dyn MediaOpener>, Arc::new(HostClock::new()));
    deps.gpu = Some(Arc::clone(&gpu));
    if rasters.is_some() {
        deps.rasters = rasters;
        deps.planner = Some(Arc::new(CaptionPreview));
    }
    deps.color = color;
    let handle = ProgramEngine::spawn(deps);
    handle.set_timeline(tl.clone(), Default::default());
    handle.seek(Time::seconds(1));
    let end = Instant::now() + Duration::from_secs(10);
    while handle.query(|e| e.is_picture_settled() && e.position() == Time::seconds(1)) != Some(true) {
        assert!(Instant::now() < end, "no picture: {:?}", handle.status());
        std::thread::sleep(Duration::from_millis(10));
    }
    loop {
        let shown = handle.latest_shown()?;
        let pixels = gpu.read_texture(&shown.frame.as_ref()?.planes[0]).ok()?;
        if ready(&pixels) {
            return Some(pixels);
        }
        assert!(Instant::now() < end, "the frame never changed: {:?}", &pixels[..4]);
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn grader() -> Option<Arc<LayerColorResolver>> {
    Some(Arc::new(LayerColorResolver::new(None, Arc::new(|_| None))))
}

fn layers() -> Option<Arc<dyn RasterProvider>> {
    Some(Arc::new(LayerRasters::new()))
}

fn timeline_of(tracks: Vec<Vec<sq_core_model::Clip>>) -> Timeline {
    let mut tl = timeline(tracks);
    tl.format.width = 192;
    tl.format.height = 108;
    tl
}

fn differing(a: &[u8], b: &[u8]) -> usize {
    a.chunks(4).zip(b.chunks(4)).filter(|(x, y)| x != y).count()
}

#[test]
fn a_title_clip_is_drawn_into_the_monitor_frame() {
    let plain = timeline_of(vec![vec![solid(1, [30, 60, 120], false)]]);
    let titled = timeline_of(vec![vec![solid(1, [30, 60, 120], false)], vec![title(2)]]);
    let Some(without) = shoot(&titled, None, None) else { return };
    let with = shoot(&titled, layers(), None).expect("frame");
    let background = shoot(&plain, layers(), None).expect("frame");
    assert_eq!(without, background, "without a raster provider the title is invisible");
    let changed = differing(&with, &background);
    assert!(changed > 100, "the title changed only {changed} pixels");
}

#[test]
fn a_color_graded_clip_differs_from_the_ungraded_one() {
    let graded = timeline_of(vec![vec![solid(1, [60, 60, 60], true)]]);
    let Some(off) = shoot(&graded, None, None) else { return };
    let on = shoot(&graded, None, grader()).expect("frame");
    let plain = shoot(&timeline_of(vec![vec![solid(1, [60, 60, 60], false)]]), None, grader()).expect("frame");
    assert_eq!(off, plain, "without a resolver the grade is ignored");
    assert!(on[0] > off[0] + 20, "graded {:?} against {:?}", &on[..4], &off[..4]);
}

fn shape_clip(n: u128) -> sq_core_model::Clip {
    let mut c = clip(n, id(n), 0, 0, 3);
    c.kind = TrackKind::Video;
    c.generator = Some(GeneratorRef::shape(ShapeKind::Rectangle));
    c.effects = vec![Project::default_shape_effect(&mut SequentialIds::default(), ShapeKind::Rectangle, 96, 54)];
    c
}

#[test]
fn a_shape_clip_is_drawn_into_the_monitor_frame() {
    let background = vec![vec![solid(1, [30, 60, 120], false)]];
    let shaped = timeline_of(vec![background[0].clone(), vec![shape_clip(2)]]);
    let Some(without) = shoot(&shaped, None, None) else { return };
    let with = shoot(&shaped, layers(), None).expect("frame");
    let plain = shoot(&timeline_of(background), layers(), None).expect("frame");
    assert_eq!(without, plain, "without a raster provider the shape is invisible");
    let changed = differing(&with, &plain);
    assert!(changed > 100, "the shape changed only {changed} pixels");
}

/// Stands in for the Lottie rasterizer: an opaque red picture.
struct RedEngine;
struct RedDrawing;
impl LottieEngine for RedEngine {
    fn open(&self, _: &[u8]) -> Option<Box<dyn LottieDrawing>> {
        Some(Box::new(RedDrawing))
    }
}
impl LottieDrawing for RedDrawing {
    fn render(&mut self, _: f32, width: usize, height: usize) -> Option<Vec<u8>> {
        Some([255, 0, 0, 255].repeat(width * height))
    }
}

#[test]
fn a_lottie_clip_is_drawn_into_the_monitor_frame() {
    let json = br#"{"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}"#;
    let mut sticker = clip(2, id(2), 0, 0, 3);
    sticker.kind = TrackKind::Video;
    sticker.generator = Some(LottieSpec::new(json.to_vec(), "red.json").generator());
    let tl = timeline_of(vec![vec![solid(1, [30, 60, 120], false)], vec![sticker]]);
    let Some(without) = shoot(&tl, layers(), None) else { return };
    let with = shoot(&tl, Some(Arc::new(LayerRasters::with_lottie(LottieRenderer::new(Box::new(RedEngine))))), None)
        .expect("frame");
    assert_eq!(differing(&without, &with), 108 * 108, "the animation covers a 108 px square");
    let middle = (54 * 192 + 96) * 4;
    assert!(with[middle] > 200 && with[middle + 1] < 60, "red at the center: {:?}", &with[middle..middle + 4]);
}

/// Stands in for a Lottie rasterizer that cannot read the file.
struct BrokenEngine;
impl LottieEngine for BrokenEngine {
    fn open(&self, _: &[u8]) -> Option<Box<dyn LottieDrawing>> {
        None
    }
}

#[test]
fn an_unreadable_lottie_clip_shows_the_offline_slate() {
    let mut sticker = clip(2, id(2), 0, 0, 3);
    sticker.kind = TrackKind::Video;
    sticker.generator = Some(LottieSpec::new(b"not json".to_vec(), "broken.json").generator());
    let tl = timeline_of(vec![vec![solid(1, [30, 60, 120], false)], vec![sticker]]);
    let Some(plain) = shoot(&tl, layers(), None) else { return };
    let slate =
        shoot(&tl, Some(Arc::new(LayerRasters::with_lottie(LottieRenderer::new(Box::new(BrokenEngine))))), None)
            .expect("frame");
    let changed = differing(&plain, &slate);
    assert!(changed > 1000, "the offline slate changed only {changed} pixels");
}

#[test]
fn a_date_stamp_clip_is_drawn_like_a_title() {
    let spec = DateStampSpec {
        blue: 0.0,
        canvas_height: 108,
        canvas_width: 192,
        corner: DateStampCorner::BottomRight,
        font_size: 20.0,
        green: 0.5,
        red: 1.0,
        text: "JUL 14 1998".into(),
    };
    let mut stamp = clip(2, id(2), 0, 0, 3);
    stamp.kind = TrackKind::Video;
    stamp.generator = Some(spec.generator());
    let tl = timeline_of(vec![vec![solid(1, [30, 60, 120], false)], vec![stamp]]);
    let Some(without) = shoot(&tl, None, None) else { return };
    let with = shoot(&tl, layers(), None).expect("frame");
    let changed = differing(&with, &without);
    assert!(changed > 50, "the date stamp changed only {changed} pixels");
}

#[test]
fn a_caption_is_drawn_into_the_monitor_frame() {
    let mut tl = timeline_of(vec![vec![solid(1, [30, 60, 120], false)]]);
    let item = CaptionItem {
        id: Id::from_u128(9),
        lines: vec!["HELLO WORLD".into()],
        range: TimeRange::new(Time::ZERO, Time::seconds(3)),
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    };
    let track: CaptionTrack =
        serde_json::from_value(serde_json::json!({"id": Id::from_u128(8), "items": [item]})).expect("track");
    tl.caption_tracks = vec![track];
    let Some(without) = shoot(&tl, None, None) else { return };
    let with = shoot(&tl, layers(), None).expect("frame");
    let changed = differing(&with, &without);
    assert!(changed > 50, "the caption changed only {changed} pixels");
}

#[test]
fn a_grade_with_a_lut_file_shows_once_the_lut_is_read() {
    use sq_core_model::LUTRef;
    use sq_render::color::clip_pipeline::CachingLutProvider;
    let mut c = clip(1, id(1), 0, 0, 3);
    let mut color = ClipColor::default();
    color.edit_effects(|fx| fx[0].input_lut = Some(LUTRef::File { path: "white.cube".into() }));
    c.set_color(&color, None, &mut SequentialIds::default());
    c.generator = Some(GeneratorRef { kind: "solid".into(), payload: vec![20, 20, 20], payload_version: 1 });
    let tl = timeline_of(vec![vec![c]]);
    // A LUT that turns everything white, read slowly: the compose waits for it (`pipeline_blocking`), no extra trigger.
    let file = Box::new(|_: &str| {
        std::thread::sleep(Duration::from_millis(300));
        Some(format!("LUT_3D_SIZE 2\n{}", "1 1 1\n".repeat(8)).into_bytes())
    });
    let luts = CachingLutProvider::new(Some(file), Box::new(|_| None), Some(Box::new(|_| None)));
    let resolver = Arc::new(LayerColorResolver::new(Some(Arc::new(luts)), Arc::new(|_| None)));
    let Some(frame) = shoot_until(&tl, None, Some(resolver), &|px| px[0] > 200) else { return };
    assert!(frame[0] > 200, "the white LUT never showed: {:?}", &frame[..4]);
}
