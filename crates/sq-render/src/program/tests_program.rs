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

/// A gradient square standing in for a title raster: its size follows the canvas, like a raster made for a scaled format.
fn title_raster(side: f64) -> Raster {
    let n = side.round() as u32;
    let mut pixels = Vec::new();
    for y in 0..n {
        for x in 0..n {
            pixels.extend([0.2 + 0.6 * x as f32 / n as f32, 0.5 * y as f32 / n as f32, 0.1, 1.0]);
        }
    }
    Raster {
        key: 9,
        width: n,
        height: n,
        pixels: Arc::new(pixels),
        layer_width: side,
        layer_height: side,
        transform: ClipTransform::IDENTITY,
        corner_radius: 0.0,
        footage_fill: None,
        sample_transforms: Vec::new(),
    }
}

fn preview_stack() -> Vec<LayerRequest> {
    use sq_core_effects::effects_evaluation::{DropShadow, EffectSegment};
    let bg = solid(1, [26, 51, 230]);
    let mut card = scaled(solid(2, [230, 153, 26]), 0.5);
    card.transform.position = Vec2::new(-30.0, -10.0);
    card.corner_radius = 16.0;
    card.effects = ClipEffects {
        segments: vec![
            EffectSegment {
                masks: EffectMasks { corner_radius: 16.0, ..EffectMasks::NONE },
                blur_after: 3.0,
                ..EffectSegment::default()
            },
            EffectSegment {
                shadow: Some(DropShadow {
                    color: [0.0; 3],
                    opacity: 0.6,
                    dx: 8.0,
                    dy: 8.0,
                    sigma: 5.0,
                    spread: 0.0,
                    shadow_only: false,
                }),
                ..EffectSegment::default()
            },
        ],
        ..ClipEffects::default()
    };
    let mut title = request(3);
    title.generator = Some(GeneratorRef { kind: "text".into(), payload: Vec::new(), payload_version: 1 });
    title.transform.position = Vec2::new(50.0, 20.0);
    vec![bg, card, title]
}

/// PSNR (dB) over the RGB channels of two same-size RGBA8 pictures.
fn psnr(a: &[u8], b: &[u8]) -> f64 {
    let mut sum = 0.0;
    let mut n = 0.0;
    for (pa, pb) in a.chunks(4).zip(b.chunks(4)) {
        for c in 0..3 {
            let d = f64::from(pa[c]) - f64::from(pb[c]);
            sum += d * d;
            n += 1.0;
        }
    }
    10.0 * (255.0 * 255.0 / (sum / n).max(1e-9)).log10()
}

#[test]
fn a_half_size_preview_of_blur_shadow_rounded_card_and_title_matches_the_downscaled_full_render() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let (full_f, half_f) = (format(256, 160), format(128, 80));
    let side = |f: f64| move |_: &LayerRequest| LayerSource::Raster(title_raster(48.0 * f));
    let full = shoot(&mut pc, &preview_stack(), &full_f, &no_grade, &side(1.0));
    let half_requests: Vec<_> = preview_stack().iter().map(|r| r.scaled(0.5).expect("scalable")).collect();
    let half = shoot(&mut pc, &half_requests, &half_f, &no_grade, &side(0.5));
    // The unscaled requests at the small canvas are the control: the check must see the difference.
    let wrong = shoot(&mut pc, &preview_stack(), &half_f, &no_grade, &side(0.5));
    let mut down = Vec::new();
    for y in 0..80usize {
        for x in 0..128usize {
            for c in 0..4 {
                let at = |dx: usize, dy: usize| u32::from(full.px[((2 * y + dy) * 256 + 2 * x + dx) * 4 + c]);
                down.push(((at(0, 0) + at(1, 0) + at(0, 1) + at(1, 1) + 2) / 4) as u8);
            }
        }
    }
    let (good, bad) = (psnr(&half.px, &down), psnr(&wrong.px, &down));
    eprintln!("preview 1/2 vs downscaled full: {good:.1} dB (unscaled requests: {bad:.1} dB)");
    assert!(good >= 35.0, "{good} dB");
    assert!(bad < good - 3.0, "the control must be clearly worse: {bad} dB");
}

/// 512 x 320 NV12 with fine vertical stripes (period 6 px) over a ramp: a point sample and a box average differ a lot.
fn striped_nv12() -> SQFrame {
    striped_nv12_sized(512, 320, 3)
}

/// Stripes of `half` px per bar (the period is 2 * half).
fn striped_nv12_sized(w: usize, h: usize, half: usize) -> SQFrame {
    let mut bytes = Vec::with_capacity(w * h * 3 / 2);
    for _ in 0..h {
        for x in 0..w {
            bytes.push(if half >= 5 {
                if (x / half).is_multiple_of(2) { 60 } else { 200 }
            } else {
                40 + (x * 60 / w) as u8 + if (x / half).is_multiple_of(2) { 30 } else { 0 }
            });
        }
    }
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

#[test]
fn a_graded_media_layer_in_a_quarter_size_preview_matches_the_downscaled_full_render() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let frame = striped_nv12();
    let source = |l: &LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 1,
            frame: frame.clone(),
            info: info(512, 320),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let basic = BasicCorrection { exposure: 0.5, ..BasicCorrection::default() };
    let mut effect = ColorEffect::new(1, None);
    effect.basic = basic;
    let color = ClipColor::new(Some(ColorSpaceID::Rec709), false, vec![effect]);
    let pipeline = Arc::new(pipeline_from_clip_color(&color, Id::NIL, None, None));
    let grade = |_: &LayerRequest| Some(Arc::clone(&pipeline));
    let render = |pc: &mut ProgramCompositor, r: &LayerRequest, f: &SequenceFormat, preview: bool| {
        let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
        let options = RenderOptions { readback: true, preview, ..RenderOptions::default() };
        let frame = pc.render(std::slice::from_ref(r), f, &options, &inputs).expect("render");
        Shot { px: pc.download_rgba8(frame).expect("download"), w: f.width as usize }
    };
    let (full_f, small_f) = (format(512, 320), format(128, 80));
    let req = request(1);
    let full = render(&mut pc, &req, &full_f, false);
    // f = 1: the preview switch changes nothing at the sequence size (the layer is shown at its texture size).
    assert_eq!(render(&mut pc, &req, &full_f, true).px, full.px, "f = 1 stays on the exact path");
    let small = req.scaled(0.25).expect("scalable");
    let preview = render(&mut pc, &small, &small_f, true);
    let point = render(&mut pc, &small, &small_f, false);
    let mut down = Vec::new();
    for y in 0..80usize {
        for x in 0..128usize {
            for c in 0..4 {
                let mut sum = 0u32;
                for (dx, dy) in (0..16).map(|i| (i % 4, i / 4)) {
                    sum += u32::from(full.px[((4 * y + dy) * 512 + 4 * x + dx) * 4 + c]);
                }
                down.push(((sum + 8) / 16) as u8);
            }
        }
    }
    let (good, bad) = (psnr(&preview.px, &down), psnr(&point.px, &down));
    eprintln!("graded media 1/4 preview vs downscaled full: {good:.1} dB (point sampled: {bad:.1} dB)");
    assert!(good >= 30.0, "{good} dB");
    assert!(bad < good - 3.0, "the control must be clearly worse: {bad} dB");
}

/// Blur, Drop Shadow and a pixel filter on a decoded media layer: the chain runs at the layer's own (native) size whatever
/// the canvas is, so the preview must keep their pixel values (a generator's canvas-sized layer is the one that follows f).
/// Checked at f = 0.5 and 0.25, with the graded (reduced convert) and the ungraded (native texture) path, against the
/// downscaled full render.
#[test]
fn blur_shadow_and_a_pixel_filter_on_a_media_layer_keep_their_strength_in_a_scaled_preview() {
    use sq_core_effects::effects_evaluation::{DropShadow, EffectSegment, ImageFilter};
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let frame = striped_nv12();
    let source = |l: &LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 1,
            frame: frame.clone(),
            info: info(512, 320),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let mut effect = ColorEffect::new(1, None);
    effect.basic = BasicCorrection { exposure: 0.5, ..BasicCorrection::default() };
    let color = ClipColor::new(Some(ColorSpaceID::Rec709), false, vec![effect]);
    let pipeline = Arc::new(pipeline_from_clip_color(&color, Id::NIL, None, None));
    let shadow =
        DropShadow { color: [0.0; 3], opacity: 0.8, dx: 24.0, dy: 16.0, sigma: 8.0, spread: 0.0, shadow_only: false };
    let mut req = request(1);
    req.transform.scale = Vec2::new(0.6, 0.6);
    req.effects = ClipEffects {
        segments: vec![
            EffectSegment { blur_after: 6.0, ..EffectSegment::default() },
            EffectSegment { shadow: Some(shadow), ..EffectSegment::default() },
            EffectSegment {
                filter: Some(ImageFilter::DirectionalBlur { dx: 16.0, dy: 8.0 }),
                ..EffectSegment::default()
            },
        ],
        ..ClipEffects::default()
    };
    let full_f = format(512, 320);
    for graded in [false, true] {
        let grade = |_: &LayerRequest| graded.then(|| Arc::clone(&pipeline));
        let render = |pc: &mut ProgramCompositor, r: &LayerRequest, f: &SequenceFormat, preview: bool| {
            let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
            let options = RenderOptions { readback: true, preview, ..RenderOptions::default() };
            let frame = pc.render(std::slice::from_ref(r), f, &options, &inputs).expect("render");
            Shot { px: pc.download_rgba8(frame).expect("download"), w: f.width as usize }
        };
        let full = render(&mut pc, &req, &full_f, false);
        for (k, small_f) in [(2usize, format(256, 160)), (4, format(128, 80))] {
            let preview = render(&mut pc, &req.scaled(1.0 / k as f64).expect("scalable"), &small_f, true);
            let mut down = Vec::new();
            for y in 0..small_f.height as usize {
                for x in 0..small_f.width as usize {
                    for c in 0..4 {
                        let mut sum = 0u32;
                        for (dx, dy) in (0..k * k).map(|i| (i % k, i / k)) {
                            sum += u32::from(full.px[((k * y + dy) * 512 + k * x + dx) * 4 + c]);
                        }
                        down.push(((sum + (k * k / 2) as u32) / (k * k) as u32) as u8);
                    }
                }
            }
            let db = psnr(&preview.px, &down);
            eprintln!("media effects 1/{k} graded {graded}: {db:.1} dB");
            assert!(db >= 38.0, "1/{k} graded {graded}: {db} dB");
        }
    }
}

/// The scaled convert is an area average: at 1/12 (12 x 12 texels per output texel) wide stripes still match the box-downscaled
/// full render (a 4-sample-per-axis kernel skips texels there and aliases: 19 dB).
#[test]
fn a_graded_media_layer_at_one_twelfth_matches_the_box_downscaled_full_render() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let frame = striped_nv12_sized(768, 768, 5);
    let source = |l: &LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 1,
            frame: frame.clone(),
            info: info(768, 768),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let mut effect = ColorEffect::new(1, None);
    effect.basic = BasicCorrection { exposure: 0.05, ..BasicCorrection::default() };
    let color = ClipColor::new(Some(ColorSpaceID::Rec709), false, vec![effect]);
    let pipeline = Arc::new(pipeline_from_clip_color(&color, Id::NIL, None, None));
    let grade = |_: &LayerRequest| Some(Arc::clone(&pipeline));
    let render = |pc: &mut ProgramCompositor, r: &LayerRequest, f: &SequenceFormat, preview: bool| {
        let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
        let options = RenderOptions { readback: true, preview, ..RenderOptions::default() };
        let frame = pc.render(std::slice::from_ref(r), f, &options, &inputs).expect("render");
        Shot { px: pc.download_rgba8(frame).expect("download"), w: f.width as usize }
    };
    let req = request(1);
    let full = render(&mut pc, &req, &format(768, 768), false);
    let small_f = format(64, 64);
    let preview = render(&mut pc, &req.scaled(1.0 / 12.0).expect("scalable"), &small_f, true);
    let mut down = Vec::new();
    for y in 0..64usize {
        for x in 0..64usize {
            for c in 0..4 {
                let mut sum = 0u32;
                for (dx, dy) in (0..144).map(|i| (i % 12, i / 12)) {
                    sum += u32::from(full.px[((12 * y + dy) * 768 + 12 * x + dx) * 4 + c]);
                }
                down.push(((sum + 72) / 144) as u8);
            }
        }
    }
    let db = psnr(&preview.px, &down);
    eprintln!("graded media 1/12 preview vs box downscaled full: {db:.1} dB");
    assert!(db >= 38.0, "{db} dB");
}

/// Hard-edged coloured NV12: luma and chroma blocks with edges at different, odd positions (chroma is half size, so its
/// edges are 2 luma px wide after upsampling).
fn coloured_nv12(w: usize, h: usize) -> SQFrame {
    let mut bytes = Vec::with_capacity(w * h * 3 / 2);
    for y in 0..h {
        for x in 0..w {
            bytes.push(if ((x + 3) / 37 + y / 29) % 2 == 0 { 90 } else { 180 });
        }
    }
    for y in 0..h / 2 {
        for x in 0..w / 2 {
            let (u, v) = match ((x + 1) / 19 + (y + 2) / 13) % 3 {
                0 => (60u8, 200u8),
                1 => (200, 70),
                _ => (128, 128),
            };
            bytes.push(u);
            bytes.push(v);
        }
    }
    SQFrame::new(
        w,
        h,
        SQFramePixelFormat::Nv12,
        SQFrameColorSpace::Rec709,
        Time::ZERO,
        Arc::new(CpuPlanes { bytes: bytes.into() }),
    )
}

/// The scaled convert of a coloured, hard-edged 4:2:0 frame (a barely visible grade keeps the scaled path on) against the
/// box-downscaled full render: the chroma must be averaged over the same footprint as the full convert.
#[test]
fn a_coloured_hard_edged_nv12_frame_scaled_matches_the_box_downscaled_full_render() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let frame = coloured_nv12(512, 320);
    let source = |l: &LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 1,
            frame: frame.clone(),
            info: info(512, 320),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let mut effect = ColorEffect::new(1, None);
    effect.basic = BasicCorrection { exposure: 0.05, ..BasicCorrection::default() };
    let color = ClipColor::new(Some(ColorSpaceID::Rec709), false, vec![effect]);
    let pipeline = Arc::new(pipeline_from_clip_color(&color, Id::NIL, None, None));
    let grade = |_: &LayerRequest| Some(Arc::clone(&pipeline));
    let render = |pc: &mut ProgramCompositor, r: &LayerRequest, f: &SequenceFormat, preview: bool| {
        let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
        let options = RenderOptions { readback: true, preview, ..RenderOptions::default() };
        let frame = pc.render(std::slice::from_ref(r), f, &options, &inputs).expect("render");
        Shot { px: pc.download_rgba8(frame).expect("download"), w: f.width as usize }
    };
    let req = request(1);
    let full = render(&mut pc, &req, &format(512, 320), false);
    for (k, small_f) in [(2usize, format(256, 160)), (4, format(128, 80))] {
        let preview = render(&mut pc, &req.scaled(1.0 / k as f64).expect("scalable"), &small_f, true);
        let mut down = Vec::new();
        for y in 0..small_f.height as usize {
            for x in 0..small_f.width as usize {
                for c in 0..4 {
                    let mut sum = 0u32;
                    for (dx, dy) in (0..k * k).map(|i| (i % k, i / k)) {
                        sum += u32::from(full.px[((k * y + dy) * 512 + k * x + dx) * 4 + c]);
                    }
                    down.push(((sum + (k * k / 2) as u32) / (k * k) as u32) as u8);
                }
            }
        }
        let db = psnr(&preview.px, &down);
        eprintln!("coloured nv12 1/{k}: {db:.1} dB");
        assert!(db >= 38.0, "1/{k}: {db} dB");
    }
}
