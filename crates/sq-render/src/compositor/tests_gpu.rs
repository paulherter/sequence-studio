//! GPU tests of the compositor on the machine's adapter (Metal on the Mac, D3D12 on Windows); they skip with a note when
//! there is none. Small trees are checked against CPU maths; the reference tree is dumped (`SQ_GPU_DUMP=<dir>`) and compared
//! with the other backend's dump (`SQ_GPU_GOLDEN=<dir>`, <= 1/255 in the 8-bit view, 0 % of channels over 1).
//! Swift: GPUCompositorResampleTests, GPUCompositorReference (the draws without clip effects).

use std::path::PathBuf;
use std::sync::Arc;

use sq_core_effects::transition::{Compose, TransitionRender, TransitionSide};
use sq_core_model::{BasicCorrection, BlendMode, ClipTransform, SequenceFormat, VideoTrackInfo};
use sq_core_time::{Time, Vec2};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;

use super::gpu_test_support::{f16_to_f32, f32_to_f16, gpu, read_rgba16f, upload_rgba16f};
use super::layer::{Content, RenderLayer, RenderNode};
use super::uniforms::lin;
use super::{GpuCompositor, Picture};
use crate::color::ToneMapping;
use crate::color::pipeline::{ColorOp, ColorPipeline};
use crate::color::vec::Vec3;
use sq_core_model::ColorSpaceID;

fn canvas(w: i64, h: i64) -> SequenceFormat {
    SequenceFormat {
        width: w,
        height: h,
        frame_duration: Time::new(1, 25),
        audio_sample_rate: 48_000,
        pixel_aspect_store: None,
        unknown: sq_core_model::UnknownKeys::default(),
    }
}

/// Which uploaded picture a test frame stands for.
struct Storage(usize);
impl SQFrameStorage for Storage {}

fn frame(index: usize, w: usize, h: usize) -> SQFrame {
    SQFrame::new(
        w,
        h,
        SQFramePixelFormat::Bgra8,
        SQFrameColorSpace::Unspecified,
        Time::new(0, 1),
        Arc::new(Storage(index)),
    )
}

fn hint(w: i64, h: i64) -> VideoTrackInfo {
    VideoTrackInfo {
        width: w,
        height: h,
        codec: "ref".into(),
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

fn rgba8(gpu: &Gpu, w: u32, h: u32, f: impl Fn(u32, u32) -> [u8; 4]) -> GpuTexture {
    let bytes: Vec<u8> = (0..h).flat_map(|y| (0..w).map(move |x| (x, y))).flat_map(|(x, y)| f(x, y)).collect();
    let t = gpu.texture(w, h, PixelFormat::Rgba8Unorm);
    gpu.upload_texture(&t, &bytes, w * 4);
    t
}

fn solid(r: f32, g: f32, b: f32) -> RenderLayer {
    RenderLayer::new(Content::Solid { red: r, green: g, blue: b })
}

struct Rendered {
    px: Vec<f32>,
    w: usize,
}

impl Rendered {
    fn at(&self, x: usize, y: usize) -> [f32; 4] {
        let i = (y * self.w + x) * 4;
        [self.px[i], self.px[i + 1], self.px[i + 2], self.px[i + 3]]
    }
}

fn render(gpu: &Arc<Gpu>, format: &SequenceFormat, nodes: &[RenderNode], pictures: &[Picture]) -> Rendered {
    let mut compositor = GpuCompositor::new(gpu).expect("compositor");
    let target = gpu.texture(format.width as u32, format.height as u32, PixelFormat::Rgba16Float);
    let mut cmds = gpu.commands();
    let lookup = |f: &SQFrame| f.storage_as::<Storage>().and_then(|s| pictures.get(s.0).cloned());
    compositor.render(nodes, format, &target, &mut cmds, false, &lookup).expect("render");
    gpu.submit_and_wait(cmds).expect("submit");
    Rendered { px: read_rgba16f(gpu, &target), w: format.width as usize }
}

fn near(got: [f32; 4], want: [f32; 4], tol: f32, what: &str) {
    for c in 0..4 {
        assert!((got[c] - want[c]).abs() <= tol, "{what}: channel {c}: got {got:?}, want {want:?}");
    }
}

#[test]
fn a_translucent_solid_over_black() {
    let Some(gpu) = gpu() else { return };
    let mut l = solid(0.5, 0.5, 0.5);
    l.transform.opacity = 0.5;
    let out = render(&gpu, &canvas(64, 48), &[RenderNode::Layer(l)], &[]);
    let v = lin(0.5) * 0.5;
    near(out.at(32, 24), [v, v, v, 1.0], 2e-3, "center");
    near(out.at(0, 0), [v, v, v, 1.0], 2e-3, "corner");
}

#[test]
fn a_picture_lands_where_the_transform_puts_it() {
    let Some(gpu) = gpu() else { return };
    let checker =
        rgba8(&gpu, 64, 48, |x, y| if (x / 8 + y / 8) % 2 == 0 { [230, 220, 40, 255] } else { [30, 60, 200, 255] });
    let mut l = RenderLayer::new(Content::Frame { frame: frame(0, 64, 48), color_hint: hint(64, 48) });
    l.transform.position = Vec2::new(20.0, -8.0);
    let out = render(&gpu, &canvas(192, 128), &[RenderNode::Layer(l)], &[Picture::rgba(checker, 0)]);
    // The layer is 64 x 48 at one pixel per pixel, centered on (96 + 20, 64 - 8): it covers x 84..148, y 32..80.
    let want = |x: usize, y: usize| -> [f32; 4] {
        let (sx, sy) = (x - 84, y - 32);
        let c = if (sx / 8 + sy / 8) % 2 == 0 { [230.0, 220.0, 40.0] } else { [30.0, 60.0, 200.0] };
        [lin(c[0] / 255.0), lin(c[1] / 255.0), lin(c[2] / 255.0), 1.0]
    };
    for (x, y) in [(88, 36), (100, 36), (96, 50), (140, 75), (147, 79)] {
        near(out.at(x, y), want(x, y), 3e-3, &format!("pixel {x},{y}"));
    }
    near(out.at(83, 50), [0.0, 0.0, 0.0, 1.0], 1e-6, "left of the layer");
    near(out.at(100, 31), [0.0, 0.0, 0.0, 1.0], 1e-6, "above the layer");
}

#[test]
fn a_ycbcr_picture_converts_to_linear_light() {
    let Some(gpu) = gpu() else { return };
    let (w, h) = (32u32, 32u32);
    let luma = upload_rgba16f(&gpu, w, h, &[0.5; 32 * 32 * 4]);
    let chroma = upload_rgba16f(&gpu, w / 2, h / 2, &[128.0 / 255.0; 16 * 16 * 4]);
    let l = RenderLayer::new(Content::Frame { frame: frame(0, 32, 32), color_hint: hint(32, 32) });
    let out = render(&gpu, &canvas(32, 32), &[RenderNode::Layer(l)], &[Picture::ycbcr(luma, chroma, 8, true)]);
    let v = lin(0.5);
    near(out.at(16, 16), [v, v, v, 1.0], 2e-3, "gray");
}

#[test]
fn a_blend_mode_reads_the_copy_of_what_is_below() {
    let Some(gpu) = gpu() else { return };
    let mut top = solid(0.5, 0.5, 0.5);
    top.blend_mode = BlendMode::Multiply;
    let nodes = [RenderNode::Layer(solid(0.8, 0.8, 0.8)), RenderNode::Layer(top)];
    let out = render(&gpu, &canvas(32, 32), &nodes, &[]);
    let v = lin(0.8) * lin(0.5);
    near(out.at(16, 16), [v, v, v, 1.0], 3e-3, "multiply");
}

#[test]
fn a_pair_sums_its_sides_as_premultiplied_color() {
    let Some(gpu) = gpu() else { return };
    let half = |mut l: RenderLayer| {
        l.transform.opacity = 0.5;
        RenderNode::Layer(l)
    };
    let f = canvas(32, 32);
    let nodes = [RenderNode::Pair {
        format: f.clone(),
        first: vec![half(solid(1.0, 0.0, 0.0))],
        second: vec![half(solid(0.0, 0.0, 1.0))],
    }];
    let out = render(&gpu, &f, &nodes, &[]);
    near(out.at(16, 16), [0.5, 0.0, 0.5, 1.0], 2e-3, "pair");
}

#[test]
fn a_stencil_keeps_what_is_below_only_where_the_matte_covers() {
    let Some(gpu) = gpu() else { return };
    let f = canvas(64, 64);
    let mut matte = solid(1.0, 1.0, 1.0);
    matte.transform.scale = Vec2::new(0.3, 0.3);
    let nodes = [
        RenderNode::Layer(solid(0.8, 0.4, 0.2)),
        RenderNode::Stencil { opacity: 1.0, children: vec![RenderNode::Layer(matte)] },
    ];
    let out = render(&gpu, &f, &nodes, &[]);
    near(out.at(32, 32), [lin(0.8), lin(0.4), lin(0.2), 1.0], 3e-3, "inside the matte");
    near(out.at(2, 2), [0.0, 0.0, 0.0, 0.0], 2e-3, "outside the matte is cleared");
}

#[test]
fn a_fused_transition_mixes_its_sides() {
    let Some(gpu) = gpu() else { return };
    let f = canvas(48, 48);
    let render_t = TransitionRender {
        outgoing: TransitionSide { opacity: 0.25, ..TransitionSide::default() },
        incoming: TransitionSide { opacity: 0.75, ..TransitionSide::default() },
        compose: Compose::Sum,
        ..TransitionRender::default()
    };
    let nodes = [RenderNode::Transition {
        format: f.clone(),
        render: render_t,
        first: vec![RenderNode::Layer(solid(1.0, 0.0, 0.0))],
        second: vec![RenderNode::Layer(solid(0.0, 0.0, 1.0))],
    }];
    let out = render(&gpu, &f, &nodes, &[]);
    near(out.at(24, 24), [0.25, 0.0, 0.75, 1.0], 3e-3, "dissolve");
}

#[test]
fn a_graded_layer_runs_the_color_chain() {
    let Some(gpu) = gpu() else { return };
    let basic = BasicCorrection { exposure: 0.5, saturation: 150.0, ..BasicCorrection::default() };
    let p = Arc::new(ColorPipeline::new(
        ColorSpaceID::Rec709,
        vec![ColorOp::Conversion(None), ColorOp::Basic(basic)],
        ToneMapping::default(),
    ));
    let mut l = solid(0.5, 0.4, 0.3);
    l.color_pipeline = Some(Arc::clone(&p));
    let out = render(&gpu, &canvas(32, 32), &[RenderNode::Layer(l)], &[]);
    let want = p.process(Vec3::new(0.5, 0.4, 0.3));
    // The flat frame is 8-bit, goes through half-float intermediates and a bilinear stretch.
    near(out.at(16, 16), [want.x, want.y, want.z, 1.0], 6e-3, "graded solid");
}

fn bilinear(px: &[f32], w: usize, h: usize, u: f32, v: f32, c: usize) -> f32 {
    let (x, y) = (u * w as f32 - 0.5, v * h as f32 - 0.5);
    let (x0, y0) = (x.floor() as i64, y.floor() as i64);
    let (fx, fy) = (x - x0 as f32, y - y0 as f32);
    let at = |i: i64, j: i64| px[(j.clamp(0, h as i64 - 1) as usize * w + i.clamp(0, w as i64 - 1) as usize) * 4 + c];
    let top = at(x0, y0) * (1.0 - fx) + at(x0 + 1, y0) * fx;
    let bottom = at(x0, y0 + 1) * (1.0 - fx) + at(x0 + 1, y0 + 1) * fx;
    top * (1.0 - fy) + bottom * fy
}

/// `resample_linear` against one bilinear tap at the output pixel's center, clamped to the edge, alpha kept.
#[test]
fn resampled_linear_frames_match_the_bilinear_tap() {
    let Some(gpu) = gpu() else { return };
    let (w, h) = (40usize, 30usize);
    let mut px = vec![0f32; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let a = if x < 8 { 0.0 } else { (y as f32 / 20.0 + 0.2).min(1.0) };
            let i = (y * w + x) * 4;
            px[i] = x as f32 / w as f32 * a;
            px[i + 1] = ((x * 7 + y * 3) % 17) as f32 / 16.0 * a;
            px[i + 2] = if (x / 5 + y / 5) % 2 == 0 { 0.9 * a } else { 0.1 * a };
            px[i + 3] = a;
        }
    }
    let half: Vec<f32> = px.iter().map(|v| f16_to_f32(f32_to_f16(*v))).collect();
    let source = upload_rgba16f(&gpu, w as u32, h as u32, &px);
    for (ow, oh) in [(25usize, 17usize), (64, 50), (40, 12)] {
        let mut compositor = GpuCompositor::new(&gpu).expect("compositor");
        let target = gpu.texture(ow as u32, oh as u32, PixelFormat::Rgba16Float);
        let mut cmds = gpu.commands();
        compositor.resample_linear(&source, &target, &mut cmds).expect("resample");
        gpu.submit_and_wait(cmds).expect("submit");
        let got = read_rgba16f(&gpu, &target);
        let mut worst = 0f32;
        for y in 0..oh {
            for x in 0..ow {
                for c in 0..4 {
                    let (u, v) = ((x as f32 + 0.5) / ow as f32, (y as f32 + 0.5) / oh as f32);
                    worst = worst.max((got[(y * ow + x) * 4 + c] - bilinear(&half, w, h, u, v, c)).abs());
                }
            }
        }
        assert!(worst <= 2.0 / 255.0, "{ow}x{oh}: max difference {worst}");
    }
}

/// The draws of `GPUCompositorReference` that need no clip effect: a Y'CbCr picture and an RGBA picture with straight alpha,
/// transform with rotation and tilt, opacity, corner radius, grades, a blend mode, a nested group with a stencil, a pair
/// and a fused and a blended transition.
fn reference_tree(gpu: &Gpu) -> (SequenceFormat, Vec<RenderNode>, Vec<Picture>) {
    let (w0, h0) = (192usize, 128usize);
    let mut luma = vec![1f32; w0 * h0 * 4];
    let mut chroma = vec![1f32; w0 / 2 * h0 / 2 * 4];
    for y in 0..h0 {
        for x in 0..w0 {
            let (r, g) = (x as f32 / w0 as f32, y as f32 / h0 as f32);
            let b = if (x / 24 + y / 16) % 2 == 0 { 0.8f32 } else { 0.15 };
            let yy = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            let i = (y * w0 + x) * 4;
            luma[i..i + 3].fill(yy);
            if x % 2 == 0 && y % 2 == 0 {
                let j = ((y / 2) * (w0 / 2) + x / 2) * 4;
                chroma[j] = (b - yy) / 1.8556 + 0.5;
                chroma[j + 1] = (r - yy) / 1.5748 + 0.5;
                chroma[j + 2] = 0.0;
            }
        }
    }
    let ycbcr = Picture::ycbcr(
        upload_rgba16f(gpu, w0 as u32, h0 as u32, &luma),
        upload_rgba16f(gpu, w0 as u32 / 2, h0 as u32 / 2, &chroma),
        8,
        true,
    );
    let hole = Picture::rgba(
        rgba8(gpu, 120, 80, |x, y| {
            let (dx, dy) = (x as f32 - 60.0, y as f32 - 40.0);
            let a = ((dx * dx + dy * dy).sqrt() - 14.0) * 20.0;
            [(x * 2) as u8, 200u32.wrapping_sub(y) as u8, 90, a.clamp(0.0, 255.0) as u8]
        }),
        1,
    );
    let checker = Picture::rgba(
        rgba8(gpu, 64, 48, |x, y| if (x / 8 + y / 8) % 2 == 0 { [230, 220, 40, 255] } else { [30, 60, 200, 255] }),
        0,
    );
    let pictures = vec![ycbcr, hole, checker];
    let layer = |i: usize, w: usize, h: usize| {
        RenderLayer::new(Content::Frame { frame: frame(i, w, h), color_hint: hint(w as i64, h as i64) })
    };
    let format = canvas(w0 as i64, h0 as i64);
    let mut turned = layer(1, 120, 80);
    turned.transform = ClipTransform {
        position: Vec2::new(20.0, -8.0),
        scale: Vec2::new(0.9, 0.9),
        rotation: 15.0,
        opacity: 0.9,
        ..ClipTransform::IDENTITY
    };
    turned.corner_radius = 8.0;
    let mut tilted = layer(2, 64, 48);
    tilted.transform = ClipTransform {
        position: Vec2::new(-50.0, 30.0),
        scale: Vec2::new(1.2, 1.2),
        tilt_x: 25.0,
        tilt_y: -15.0,
        ..ClipTransform::IDENTITY
    };
    let mut overlay = solid(0.9, 0.4, 0.2);
    overlay.blend_mode = BlendMode::Overlay;
    overlay.transform =
        ClipTransform { position: Vec2::new(40.0, 30.0), scale: Vec2::new(0.4, 0.3), ..ClipTransform::IDENTITY };
    let mut white = solid(1.0, 1.0, 1.0);
    white.transform.scale = Vec2::new(0.3, 0.3);
    let inner = canvas(64, 48);
    let push = TransitionRender {
        outgoing: TransitionSide { offset: Vec2::new(-0.3, 0.0), ..TransitionSide::default() },
        incoming: TransitionSide { offset: Vec2::new(0.7, 0.0), ..TransitionSide::default() },
        compose: Compose::Sum,
        ..TransitionRender::default()
    };
    let wipe = TransitionRender {
        incoming: TransitionSide { offset: Vec2::new(0.5, 0.0), ..TransitionSide::default() },
        compose: Compose::IncomingOver,
        ..TransitionRender::default()
    };
    let basic = BasicCorrection {
        exposure: 0.5,
        saturation: 150.0,
        contrast: 25.0,
        temperature: 20.0,
        ..BasicCorrection::default()
    };
    let grade = Arc::new(ColorPipeline::new(
        ColorSpaceID::Rec709,
        vec![ColorOp::Conversion(None), ColorOp::Basic(basic)],
        ToneMapping::default(),
    ));
    let mut graded = layer(0, w0, h0);
    graded.color_pipeline = Some(Arc::clone(&grade));
    tilted.color_pipeline = Some(grade);
    let nodes = vec![
        RenderNode::Layer(graded),
        RenderNode::Layer(turned.clone()),
        RenderNode::Layer(tilted.clone()),
        RenderNode::Layer(overlay),
        RenderNode::Group {
            format: inner,
            transform: ClipTransform { position: Vec2::new(60.0, -35.0), rotation: -10.0, ..ClipTransform::IDENTITY },
            opacity: 0.8,
            corner_radius: 6.0,
            children: vec![
                RenderNode::Layer(layer(2, 64, 48)),
                RenderNode::Stencil { opacity: 0.85, children: vec![RenderNode::Layer(white.clone())] },
            ],
        },
        RenderNode::Pair {
            format: format.clone(),
            first: vec![RenderNode::Layer(white.clone())],
            second: vec![RenderNode::Layer(tilted)],
        },
        RenderNode::Transition {
            format: format.clone(),
            render: push,
            first: vec![RenderNode::Layer(layer(2, 64, 48))],
            second: vec![RenderNode::Layer(white)],
        },
        RenderNode::Blended(
            Box::new(RenderNode::Transition {
                format: format.clone(),
                render: wipe,
                first: vec![RenderNode::Layer(turned)],
                second: vec![RenderNode::Layer(layer(2, 64, 48))],
            }),
            BlendMode::Difference,
        ),
    ];
    (format, nodes, pictures)
}

/// Half-float bytes of the render (the dump a backend comparison reads).
fn dump_bytes(px: &[f32]) -> Vec<u8> {
    px.iter().flat_map(|v| f32_to_f16(*v).to_le_bytes()).collect()
}

/// 8-bit view difference of two dumps: (max, share of channels over 1).
fn diff8(a: &[u8], b: &[u8]) -> (i32, f64) {
    let q8 = |c: &[u8; 2]| (f16_to_f32(u16::from_le_bytes(*c)).clamp(0.0, 1.0) * 255.0).round() as i32;
    let (mut max, mut over) = (0, 0usize);
    for (x, y) in a.as_chunks::<2>().0.iter().zip(b.as_chunks::<2>().0) {
        let d = (q8(x) - q8(y)).abs();
        max = max.max(d);
        over += usize::from(d > 1);
    }
    (max, over as f64 / (a.len() / 2).max(1) as f64)
}

#[test]
fn the_reference_tree_renders_the_same_on_every_backend() {
    let Some(gpu) = gpu() else { return };
    let (format, nodes, pictures) = reference_tree(&gpu);
    let first = render(&gpu, &format, &nodes, &pictures);
    assert!(first.px.iter().all(|v| v.is_finite()), "non-finite pixels");
    let distinct: std::collections::HashSet<u8> = first.px.iter().map(|v| (lin_to_8(*v)) as u8).collect();
    assert!(distinct.len() > 64, "the tree must draw something: {} distinct values", distinct.len());
    // Rendering again gives the same bits (pooled textures and arenas carry no state between renders).
    let second = render(&gpu, &format, &nodes, &pictures);
    assert_eq!(dump_bytes(&first.px), dump_bytes(&second.px), "second render differs");
    let name = "compositor_core_192x128.f16";
    let bytes = dump_bytes(&first.px);
    if let Ok(dir) = std::env::var("SQ_GPU_DUMP") {
        std::fs::create_dir_all(&dir).expect("dump dir");
        std::fs::write(PathBuf::from(dir).join(name), &bytes).expect("dump");
    }
    if let Ok(dir) = std::env::var("SQ_GPU_GOLDEN") {
        let other = std::fs::read(PathBuf::from(dir).join(name)).expect("golden dump of the other backend");
        let (max8, over) = diff8(&bytes, &other);
        sq_os::errln!("{name}: 8-bit max {max8}/255, channels over 1: {:.3} %", over * 100.0);
        assert!(max8 <= 1 && over == 0.0, "{name}: max {max8}/255, {:.3} % of channels over 1", over * 100.0);
    }
}

fn lin_to_8(v: f32) -> i32 {
    (v.clamp(0.0, 1.0) * 255.0).round() as i32
}

/// Not a check unless `SQ_P210_DUMP=<folder>` holds `<frame>.<w>x<h>.P210` files (the playing route's pictures of a real
/// 4:2:2 clip): renders each once with its true 4:2:2 chroma (the new route) and once with the chroma merged vertically
/// to 4:2:0 (the old route), and prints the PSNR per Y / Cb / Cr and the largest code difference of the two frames.
/// With `SQ_P210_PNG=<folder>` the two renders are also written as raw rgb24 for a glance.
#[test]
fn p210_chroma_versus_the_merged_420_chroma_of_real_frames() {
    let Ok(dir) = std::env::var("SQ_P210_DUMP") else { return };
    let Some(gpu) = gpu() else { return };
    let mut files: Vec<_> = std::fs::read_dir(&dir).expect("dump folder").flatten().map(|e| e.path()).collect();
    files.sort();
    for path in files.iter().filter(|p| p.extension().is_some_and(|e| e.to_string_lossy().starts_with("P210"))) {
        let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
        let full_range = path.extension().is_some_and(|e| e == "P210FullRange");
        let (tag, dims) = stem.split_once('.').expect("name");
        let (w, h) =
            dims.split_once('x').map(|(a, b)| (a.parse::<usize>().unwrap(), b.parse::<usize>().unwrap())).unwrap();
        let bytes = std::fs::read(path).expect("read");
        let (cw, luma_bytes) = (w / 2, w * h * 2);
        // The old route: pairs of chroma rows averaged (what the 4:2:0 reduction produced).
        let mut merged = bytes[..luma_bytes].to_vec();
        let word = |b: &[u8], i: usize| u32::from(u16::from_le_bytes([b[2 * i], b[2 * i + 1]]));
        for cy in 0..h / 2 {
            for k in 0..cw * 2 {
                let a = word(&bytes[luma_bytes..], (2 * cy) * cw * 2 + k);
                let b = word(&bytes[luma_bytes..], (2 * cy + 1) * cw * 2 + k);
                // codes are MSB-aligned 10 bit: average the 10-bit values, as the reduction did
                let v = ((a >> 6) + (b >> 6)).div_ceil(2) << 6;
                merged.extend_from_slice(&(v as u16).to_le_bytes());
            }
        }
        let mk = |fmt: SQFramePixelFormat, data: Vec<u8>| {
            SQFrame::new(
                w,
                h,
                fmt,
                SQFrameColorSpace::Rec709,
                Time::new(0, 1),
                Arc::new(crate::program::CpuPlanes { bytes: data.into() }),
            )
        };
        let mut cache = crate::program::PlaneCache::new();
        let mut kept = Vec::new();
        let new_pic = crate::program::to_gpu(
            &gpu,
            &mk(if full_range { SQFramePixelFormat::P210FullRange } else { SQFramePixelFormat::P210 }, bytes.clone()),
            None,
            &mut cache,
            &mut kept,
        )
        .expect("p210");
        let old_pic = crate::program::to_gpu(
            &gpu,
            &mk(if full_range { SQFramePixelFormat::P010FullRange } else { SQFramePixelFormat::P010 }, merged),
            None,
            &mut cache,
            &mut kept,
        )
        .expect("p010");
        let layer = || RenderLayer::new(Content::Frame { frame: frame(0, w, h), color_hint: hint(w as i64, h as i64) });
        let fmt = canvas(w as i64, h as i64);
        let a = render(&gpu, &fmt, &[RenderNode::Layer(layer())], &[old_pic]);
        let b = render(&gpu, &fmt, &[RenderNode::Layer(layer())], &[new_pic]);
        // Linear light back to encoded BT.709 R'G'B', then Y'CbCr (full-range floats): PSNR per plane against peak 1.
        let enc = |l: f32| if l < 0.018_053_97 { l * 4.5 } else { 1.099_296_8 * l.powf(0.45) - 0.099_296_8 };
        let ycc = |px: &[f32], i: usize| {
            let (r, g, bl) = (enc(px[i * 4].max(0.0)), enc(px[i * 4 + 1].max(0.0)), enc(px[i * 4 + 2].max(0.0)));
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
            [y, (bl - y) / 1.8556, (r - y) / 1.5748]
        };
        let (mut se, mut worst) = ([0f64; 3], [0f32; 3]);
        for i in 0..w * h {
            let (p, q) = (ycc(&a.px, i), ycc(&b.px, i));
            for c in 0..3 {
                let d = (p[c] - q[c]).abs();
                se[c] += f64::from(d * d);
                worst[c] = worst[c].max(d);
            }
        }
        let psnr = |s: f64| if s == 0.0 { f64::INFINITY } else { -10.0 * (s / (w * h) as f64).log10() };
        sq_os::outln!(
            "P210CMP {tag} {w}x{h}: PSNR Y {:.2} Cb {:.2} Cr {:.2} dB; max abs diff (of 1.0) Y {:.4} Cb {:.4} Cr {:.4}",
            psnr(se[0]),
            psnr(se[1]),
            psnr(se[2]),
            worst[0],
            worst[1],
            worst[2]
        );
        if let Ok(out) = std::env::var("SQ_P210_PNG") {
            for (name, r) in [("A", &a), ("B", &b)] {
                let rgb: Vec<u8> = (0..w * h)
                    .flat_map(|i| (0..3).map(move |c| (enc(r.px[i * 4 + c].clamp(0.0, 1.0)) * 255.0 + 0.5) as u8))
                    .collect();
                std::fs::write(format!("{out}/{tag}.{name}.{w}x{h}.rgb"), rgb).expect("write");
            }
        }
        cache.end_frame();
    }
}
