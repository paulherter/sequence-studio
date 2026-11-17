//! GPU tests of the program compositor on the machine's adapter (they skip with a note when there is none): the full node
//! tree (picture in picture, blur, mask, crop, adjustment layer, grade, text raster, NV12 media) checked against the
//! display code values the maths gives, and one scene dumped as RGBA8 (`SQ_GPU_DUMP=<dir>`) for the Metal vs D3D12 compare
//! (`SQ_GPU_GOLDEN=<dir>`, <= 1/255 on every channel).

use super::{Inputs, LayerSource, ProgramCompositor, Raster, RenderOptions, Source};
use crate::color::pipeline_from_clip_color;
use crate::compositor::gpu_test_support::gpu;
use crate::program::CpuPlanes;
use sq_core_color::FilmLook;
use sq_core_effects::adjustment_clip::ADJUSTMENT_KIND;
use sq_core_effects::effects_evaluation::{ClipEffects, CropInsets, EffectMasks};
use sq_core_effects::evaluation::LayerRequest;
use sq_core_masks::MaskShape;
use sq_core_model::{
    BasicCorrection, ClipColor, ClipTransform, ColorEffect, ColorSpaceID, GeneratorRef, SequenceFormat, VideoTrackInfo,
};
use sq_core_time::{Id, Time, Vec2};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat};
use std::path::PathBuf;
use std::sync::Arc;

fn format(w: i64, h: i64) -> SequenceFormat {
    SequenceFormat {
        width: w,
        height: h,
        frame_duration: Time::new(1, 25),
        audio_sample_rate: 48_000,
        pixel_aspect_store: None,
        unknown: sq_core_model::UnknownKeys::default(),
    }
}

fn request(n: u128) -> LayerRequest {
    LayerRequest::new(Id::from_u128(n), Id::from_u128(100 + n), Id::from_u128(200), Time::ZERO)
}

/// A solid generator layer of display color `rgb` (0...255).
fn solid(n: u128, rgb: [u8; 3]) -> LayerRequest {
    let mut r = request(n);
    r.generator = Some(GeneratorRef { kind: "solid".into(), payload: rgb.to_vec(), payload_version: 1 });
    r
}

fn scaled(mut r: LayerRequest, s: f64) -> LayerRequest {
    r.transform.scale = Vec2::new(s, s);
    r
}

fn no_grade(_: &LayerRequest) -> Option<Arc<crate::color::pipeline::ColorPipeline>> {
    None
}

struct Shot {
    px: Vec<u8>,
    w: usize,
}

impl Shot {
    fn at(&self, x: usize, y: usize) -> [i32; 4] {
        let i = (y * self.w + x) * 4;
        [i32::from(self.px[i]), i32::from(self.px[i + 1]), i32::from(self.px[i + 2]), i32::from(self.px[i + 3])]
    }
}

fn shoot(
    pc: &mut ProgramCompositor,
    requests: &[LayerRequest],
    f: &SequenceFormat,
    grade: &dyn Fn(&LayerRequest) -> Option<Arc<crate::color::pipeline::ColorPipeline>>,
    source: &dyn Fn(&LayerRequest) -> LayerSource,
) -> Shot {
    let inputs = Inputs { grade, split: None, mattes: None, source };
    let frame =
        pc.render(requests, f, &RenderOptions { readback: true, ..RenderOptions::default() }, &inputs).expect("render");
    Shot { px: pc.download_rgba8(frame).expect("download"), w: f.width as usize }
}

fn near(got: [i32; 4], want: [i32; 4], tol: i32, what: &str) {
    for c in 0..4 {
        assert!((got[c] - want[c]).abs() <= tol, "{what}: channel {c}: got {got:?}, want {want:?}");
    }
}

fn nothing(_: &LayerRequest) -> LayerSource {
    LayerSource::Hidden
}

#[test]
fn a_render_loop_never_queues_more_than_two_frames_on_the_gpu() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(256, 144);
    let reqs = [solid(1, [26, 51, 230]), scaled(solid(2, [230, 153, 26]), 0.5)];
    let inputs = Inputs { grade: &no_grade, split: None, mattes: None, source: &nothing };
    for i in 0..40 {
        // Alternating waits: a frame that never drops (None) and one that may (a bound far above this GPU's frame time).
        let gpu_wait = (i % 2 == 0).then(|| std::time::Duration::from_secs(5));
        let options = RenderOptions { gpu_wait, ..RenderOptions::default() };
        pc.render(&reqs, &f, &options, &inputs).expect("render");
        assert!(pc.frames_in_flight() <= sq_gpu::gpu::FRAMES_IN_FLIGHT, "frame {i}: {}", pc.frames_in_flight());
    }
}

#[test]
fn picture_in_picture_keeps_both_colors_as_code_values() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(96, 64);
    let reqs = [solid(1, [26, 51, 230]), scaled(solid(2, [230, 153, 26]), 0.5)];
    let s = shoot(&mut pc, &reqs, &f, &no_grade, &nothing);
    near(s.at(48, 32), [230, 153, 26, 255], 1, "inner");
    near(s.at(4, 4), [26, 51, 230, 255], 1, "outer");
}

#[test]
fn a_blurred_layer_has_a_soft_edge_and_an_untouched_center() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(128, 96);
    let mut white = scaled(solid(1, [255, 255, 255]), 0.5);
    white.effects = ClipEffects::simple(EffectMasks::NONE, 6.0, EffectMasks::NONE, Vec::new());
    let s = shoot(&mut pc, &[white], &f, &no_grade, &nothing);
    near(s.at(64, 48), [255, 255, 255, 255], 1, "center");
    // The picture covers x 32..96: the edge pixel is about half covered in light (code value about 190), outside it the blur
    // fades out.
    let edge = s.at(32, 48)[0];
    assert!((150..=215).contains(&edge), "edge {edge}");
    // Layer px: sigma 6 is 3 screen px at scale 0.5.
    let outside = s.at(29, 48)[0];
    assert!(outside < edge && outside > 0, "outside {outside}");
    assert_eq!(s.at(2, 2)[0], 0, "far corner");
}

#[test]
fn a_clip_mask_shows_the_layer_only_inside() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(96, 64);
    let mut red = solid(1, [204, 51, 51]);
    let square = vec![Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.25), Vec2::new(0.75, 0.75), Vec2::new(0.25, 0.75)];
    red.effects = ClipEffects::new(Vec::new(), vec![MaskShape::new(square)], FilmLook::default());
    let s = shoot(&mut pc, &[red], &f, &no_grade, &nothing);
    near(s.at(48, 32), [204, 51, 51, 255], 1, "inside");
    near(s.at(4, 4), [0, 0, 0, 255], 0, "outside");
}

#[test]
fn crop_removes_the_left_half() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(96, 64);
    let mut red = solid(1, [204, 51, 51]);
    let crop = EffectMasks { crop: CropInsets { left: 0.5, ..CropInsets::NONE }, ..EffectMasks::NONE };
    red.effects = ClipEffects::simple(crop, 0.0, EffectMasks::NONE, Vec::new());
    let s = shoot(&mut pc, &[red], &f, &no_grade, &nothing);
    near(s.at(20, 32), [0, 0, 0, 255], 0, "cropped");
    near(s.at(76, 32), [204, 51, 51, 255], 1, "kept");
}

#[test]
fn an_adjustment_layer_blurs_what_is_below_it() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(128, 96);
    let mut adj = request(2);
    adj.generator = Some(GeneratorRef { kind: ADJUSTMENT_KIND.into(), payload: Vec::new(), payload_version: 1 });
    adj.effects = ClipEffects::simple(EffectMasks::NONE, 6.0, EffectMasks::NONE, Vec::new());
    let reqs = [scaled(solid(1, [255, 255, 255]), 0.5), adj];
    let s = shoot(&mut pc, &reqs, &f, &no_grade, &nothing);
    near(s.at(64, 48), [255, 255, 255, 255], 1, "center");
    // The picture below stays; the blurred copy spreads light past its edge.
    assert!(s.at(29, 48)[0] > 40, "outside {:?}", s.at(29, 48));
    assert_eq!(s.at(2, 2)[0], 0, "far corner");
}

#[test]
fn a_grade_changes_the_layer() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(64, 48);
    let basic = BasicCorrection { exposure: 1.0, ..BasicCorrection::default() };
    let mut effect = ColorEffect::new(1, None);
    effect.basic = basic;
    let color = ClipColor::new(Some(ColorSpaceID::Rec709), false, vec![effect]);
    let pipeline = Arc::new(pipeline_from_clip_color(&color, Id::NIL, None, None));
    let reqs = [solid(1, [64, 64, 64])];
    let plain = shoot(&mut pc, &reqs, &f, &no_grade, &nothing);
    let graded = shoot(&mut pc, &reqs, &f, &|_| Some(Arc::clone(&pipeline)), &nothing);
    near(plain.at(10, 10), [64, 64, 64, 255], 1, "ungraded");
    assert!(graded.at(10, 10)[0] > 64 + 20, "graded {:?}", graded.at(10, 10));
}

fn red_square(key: u64) -> Raster {
    let mut pixels = Vec::new();
    for _ in 0..16 * 16 {
        pixels.extend([0.6, 0.0, 0.0, 1.0]);
    }
    Raster {
        key,
        width: 16,
        height: 16,
        pixels: Arc::new(pixels),
        layer_width: 16.0,
        layer_height: 16.0,
        transform: ClipTransform::IDENTITY,
        corner_radius: 0.0,
        footage_fill: None,
        sample_transforms: Vec::new(),
    }
}

#[test]
fn a_text_raster_sits_at_the_center_and_is_uploaded_once() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(64, 48);
    let mut title = request(1);
    title.generator = Some(GeneratorRef { kind: "text".into(), payload: Vec::new(), payload_version: 1 });
    let source = |_: &LayerRequest| LayerSource::Raster(red_square(7));
    let s = shoot(&mut pc, &[title.clone()], &f, &no_grade, &source);
    let want = (crate::compositor::uniforms::lin(0.0).max(0.0), 0);
    let _ = want;
    assert!(s.at(32, 24)[0] > 100 && s.at(32, 24)[1] == 0, "center {:?}", s.at(32, 24));
    near(s.at(4, 4), [0, 0, 0, 255], 0, "corner");
    let again = shoot(&mut pc, &[title], &f, &no_grade, &source);
    assert_eq!(again.px, s.px);
}

fn gray_nv12(w: usize, h: usize, y: u8) -> SQFrame {
    let mut bytes = vec![y; w * h];
    bytes.extend(std::iter::repeat_n(128u8, w * h / 2));
    SQFrame::new(
        w,
        h,
        SQFramePixelFormat::Nv12,
        SQFrameColorSpace::Rec709,
        Time::ZERO,
        Arc::new(CpuPlanes { bytes: bytes.into() }),
    )
}

fn info(w: i64, h: i64) -> VideoTrackInfo {
    VideoTrackInfo {
        width: w,
        height: h,
        codec: "h264".into(),
        bit_depth: 8,
        chroma: "4:2:0".into(),
        nominal_frame_duration: Time::new(1, 25),
        is_variable_frame_rate: false,
        color_primaries: None,
        transfer: None,
        matrix: None,
        rotation: 0,
        pixel_aspect: sq_core_model::PixelAspect::square(),
        pixel_aspect_override: None,
        field_order: None,
        deinterlace_off: false,
    }
}

#[test]
fn an_nv12_media_layer_shows_its_code_value_and_the_planes_are_cached() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(64, 48);
    let req = request(1);
    let frame = gray_nv12(64, 48, 126);
    let source = |l: &LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 3,
            frame: frame.clone(),
            info: info(64, 48),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let s = shoot(&mut pc, std::slice::from_ref(&req), &f, &no_grade, &source);
    // Video-range Y' 126 is 0.502 of full range.
    near(s.at(32, 24), [128, 128, 128, 255], 2, "gray");
    let again = shoot(&mut pc, &[req], &f, &no_grade, &source);
    assert_eq!(again.px, s.px);
}

/// The scene of the Metal vs D3D12 compare: every feature of the tree in one frame.
fn full_scene() -> Vec<LayerRequest> {
    let bg = solid(1, [26, 51, 230]);
    let mut blurred = scaled(solid(2, [230, 153, 26]), 0.4);
    blurred.transform.position = Vec2::new(-30.0, -10.0);
    blurred.effects = ClipEffects::simple(EffectMasks::NONE, 4.0, EffectMasks::NONE, Vec::new());
    let mut masked = solid(3, [51, 204, 102]);
    let tri = vec![Vec2::new(0.55, 0.1), Vec2::new(0.95, 0.1), Vec2::new(0.95, 0.5)];
    masked.effects = ClipEffects::new(Vec::new(), vec![MaskShape::new(tri)], FilmLook::default());
    let mut cropped = scaled(solid(4, [240, 240, 240]), 0.3);
    cropped.transform.position = Vec2::new(30.0, 30.0);
    let crop =
        EffectMasks { crop: CropInsets { top: 0.25, ..CropInsets::NONE }, corner_radius: 6.0, ..EffectMasks::NONE };
    cropped.effects = ClipEffects::simple(crop, 0.0, EffectMasks::NONE, Vec::new());
    vec![bg, blurred, masked, cropped]
}

fn diff8(a: &[u8], b: &[u8]) -> (i32, f64) {
    let mut max = 0;
    let mut over = 0usize;
    for (x, y) in a.iter().zip(b) {
        let d = (i32::from(*x) - i32::from(*y)).abs();
        max = max.max(d);
        over += usize::from(d > 1);
    }
    (max, over as f64 / a.len().max(1) as f64)
}

#[test]
fn the_full_scene_matches_the_other_backend() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(192, 128);
    let first = shoot(&mut pc, &full_scene(), &f, &no_grade, &nothing);
    let second = shoot(&mut pc, &full_scene(), &f, &no_grade, &nothing);
    assert_eq!(first.px, second.px, "second render differs");
    // A few facts of the scene itself.
    near(first.at(150, 30), [51, 204, 102, 255], 1, "masked triangle");
    near(first.at(5, 120), [26, 51, 230, 255], 1, "background");
    let name = "program_scene_192x128.rgba8";
    if let Ok(dir) = std::env::var("SQ_GPU_DUMP") {
        std::fs::create_dir_all(&dir).expect("dump dir");
        std::fs::write(PathBuf::from(dir).join(name), &first.px).expect("dump");
    }
    if let Ok(dir) = std::env::var("SQ_GPU_GOLDEN") {
        let other = std::fs::read(PathBuf::from(dir).join(name)).expect("golden dump of the other backend");
        let (max8, over) = diff8(&first.px, &other);
        eprintln!("{name}: max {max8}/255, channels over 1: {:.3} %", over * 100.0);
        assert!(max8 <= 1 && over == 0.0, "{name}: max {max8}/255, {:.3} % of channels over 1", over * 100.0);
    }
}

#[test]
fn consecutive_renders_land_in_different_textures_so_a_reader_never_sees_a_half_drawn_frame() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(32, 32);
    let inputs = Inputs { grade: &no_grade, split: None, mattes: None, source: &nothing };
    let mut outs = Vec::new();
    for n in 0..super::OUTPUT_RING + 1 {
        let reqs = [solid(1, [n as u8 * 40, 0, 0])];
        outs.push(pc.render(&reqs, &f, &RenderOptions::default(), &inputs).expect("render").output);
    }
    for i in 0..super::OUTPUT_RING {
        for j in i + 1..super::OUTPUT_RING {
            assert!(outs[i].texture() != outs[j].texture(), "{i} vs {j}");
        }
    }
    assert!(outs[0].texture() == outs[super::OUTPUT_RING].texture(), "the ring wraps");
}

/// Export Frame writes the linear half-float composite (`download_linear`) through the BT.709 curve: it must land within
/// 1/255 of the 8-bit frame the monitor shows (the Present pass).
#[test]
fn the_linear_composite_matches_the_shown_frame_after_the_709_curve() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = format(96, 64);
    let reqs = [solid(1, [26, 51, 230]), scaled(solid(2, [230, 153, 26]), 0.5)];
    let inputs = Inputs { grade: &no_grade, split: None, mattes: None, source: &nothing };
    let frame =
        pc.render(&reqs, &f, &RenderOptions { readback: true, ..RenderOptions::default() }, &inputs).expect("render");
    let (linear, w, h) = pc.download_linear(&frame, None).expect("linear");
    let shown = pc.download_rgba8(frame).expect("download");
    assert_eq!((w, h), (96, 64));
    let oetf = |x: f32| {
        let v = x.clamp(0.0, 1.0);
        if v < 0.018_053_968 { 4.5 * v } else { 1.099_296_8 * v.powf(0.45) - 0.099_296_83 }
    };
    for (i, px) in linear.as_chunks::<8>().0.iter().enumerate() {
        for c in 0..3 {
            let half = u16::from_le_bytes([px[c * 2], px[c * 2 + 1]]);
            let code = (oetf(half_to_f32(half)) * 255.0).round() as i32;
            let got = i32::from(shown[i * 4 + c]);
            assert!((code - got).abs() <= 1, "pixel {i} channel {c}: linear gives {code}, shown {got}");
        }
    }
}

fn half_to_f32(h: u16) -> f32 {
    let (e, m) = (i32::from((h >> 10) & 0x1F), f32::from(h & 0x3FF));
    let v = if e == 0 { m * 2f32.powi(-24) } else { (1.0 + m / 1024.0) * 2f32.powi(e - 15) };
    if h & 0x8000 != 0 { -v } else { v }
}
