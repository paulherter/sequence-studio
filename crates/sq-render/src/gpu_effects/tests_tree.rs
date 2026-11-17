//! The clip effect hooks on the compositor (Frame Blending, optical flow cache, Deflicker, Picture mattes). GPU tests skip with a
//! note when there is no adapter.

use super::hooks::ClipEffectHooks;
use crate::compositor::gpu_test_support::{gpu, read_rgba16f};
use crate::compositor::uniforms::lin;
use crate::compositor::{
    Content, FlowPairKey, FlowQuality, FrameBlend, GpuCompositor, OpticalFlowRequest, Picture, RenderLayer, RenderNode,
    TemporalFrames,
};
use sq_core_effects::temporal_effects::{TemporalDeflicker, TemporalFilter};
use sq_core_model::{SequenceFormat, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

struct Slot(usize);
impl SQFrameStorage for Slot {}

fn frame(i: usize, w: usize, h: usize) -> SQFrame {
    SQFrame::new(w, h, SQFramePixelFormat::Rgba8, SQFrameColorSpace::Unspecified, Time::ZERO, Arc::new(Slot(i)))
}

fn gray(gpu: &Gpu, w: u32, h: u32, v: u8) -> Picture {
    let t = gpu.texture(w, h, PixelFormat::Rgba8Unorm);
    let bytes: Vec<u8> = (0..w * h).flat_map(|_| [v, v, v, 255]).collect();
    gpu.upload_texture(&t, &bytes, w * 4);
    Picture::rgba(t, 1)
}

fn hint(w: i64, h: i64) -> VideoTrackInfo {
    VideoTrackInfo {
        width: w,
        height: h,
        codec: "ref".into(),
        bit_depth: 8,
        chroma: "4:4:4".into(),
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

/// Renders `layer` over black and returns the working-linear pixel at the center.
fn center(gpu: &Arc<Gpu>, comp: &mut GpuCompositor, layer: RenderLayer, pictures: &[Picture]) -> [f32; 4] {
    let f = canvas(32, 24);
    let target = gpu.texture(32, 24, PixelFormat::Rgba16Float);
    let mut cmds = gpu.commands();
    let lookup = |fr: &SQFrame| fr.storage_as::<Slot>().and_then(|s| pictures.get(s.0).cloned());
    comp.render(&[RenderNode::Layer(layer)], &f, &target, &mut cmds, false, &lookup).expect("render");
    gpu.submit_and_wait(cmds).expect("submit");
    let px = read_rgba16f(gpu, &target);
    let i = (12 * 32 + 16) * 4;
    [px[i], px[i + 1], px[i + 2], px[i + 3]]
}

fn layer(f: SQFrame) -> RenderLayer {
    let mut l = RenderLayer::new(Content::Frame { frame: f, color_hint: hint(32, 24) });
    l.native_size = Some((32, 24));
    l
}

#[test]
fn frame_blending_mixes_in_light() {
    let Some(gpu) = gpu() else { return };
    let mut comp = ClipEffectHooks::compositor(&gpu).expect("compositor");
    let pictures = [gray(&gpu, 32, 24, 128), gray(&gpu, 32, 24, 0)];
    let mut l = layer(frame(0, 32, 24));
    l.blend = Some(FrameBlend { next: frame(1, 32, 24), weight: 0.5, flow: None });
    let got = center(&gpu, &mut comp, l, &pictures);
    let want = 0.5 * lin(128.0 / 255.0);
    assert!((got[0] - want).abs() < 3e-3 && got[3] > 0.999, "got {got:?}, want {want}");
}

#[test]
fn optical_flow_measures_a_frame_pair_once() {
    let Some(gpu) = gpu() else { return };
    let hooks = ClipEffectHooks::new(&gpu);
    let mut comp = GpuCompositor::with_hooks(&gpu, Arc::clone(&hooks) as _).expect("compositor");
    let pictures = [gray(&gpu, 32, 24, 100), gray(&gpu, 32, 24, 100)];
    let key = FlowPairKey { media: Id::from_u128(1), from: Time::ZERO, to: Time::new(1, 25), variant: 0 };
    let make = || {
        let mut l = layer(frame(0, 32, 24));
        let flow = OpticalFlowRequest { key: Some(key), quality: FlowQuality::Better };
        l.blend = Some(FrameBlend { next: frame(1, 32, 24), weight: 0.5, flow: Some(flow) });
        l
    };
    let a = center(&gpu, &mut comp, make(), &pictures);
    let b = center(&gpu, &mut comp, make(), &pictures);
    assert_eq!(hooks.flow_measure_count(), 1, "the pair measured twice");
    // Two equal frames: no motion, the picture is the frame itself.
    assert!((a[0] - lin(100.0 / 255.0)).abs() < 3e-3, "got {a:?}");
    assert_eq!(a, b);
}

#[test]
fn deflicker_pulls_a_dark_frame_toward_its_neighbors() {
    let Some(gpu) = gpu() else { return };
    let mut comp = ClipEffectHooks::compositor(&gpu).expect("compositor");
    let pictures = [gray(&gpu, 32, 24, 80), gray(&gpu, 32, 24, 160), gray(&gpu, 32, 24, 160)];
    let plain = center(&gpu, &mut comp, layer(frame(0, 32, 24)), &pictures);
    let mut l = layer(frame(0, 32, 24));
    l.temporal = Some(TemporalFrames {
        filter: TemporalFilter { denoise: None, deflicker: Some(TemporalDeflicker::new(1, false, 1.0)), trails: None },
        before: vec![frame(1, 32, 24)],
        after: vec![frame(2, 32, 24)],
    });
    let got = center(&gpu, &mut comp, l, &pictures);
    assert!(got[0] > plain[0] * 1.2, "deflicked {got:?} vs plain {plain:?}");
    assert!(got[0] < lin(160.0 / 255.0), "deflicked {got:?}");
}
