//! Tests of the passes: the pure planning, packing and binning always run; the GPU tests skip with a note when the
//! machine has no adapter. GPU-vs-CPU tolerance is 1/255 as in the design; scope counters must be exact.

#![allow(clippy::chunks_exact_to_as_chunks)]

use super::kernels::{Kernel, Kernels};
use super::reference_graph::{self, HEIGHT, WIDTH, gaussian_weights, png_encode};
use super::scope_binning::{self, ScopeCounts, ScopeLayout};
use super::uniforms::{BlurU, FilterU, FlowU};
use super::{PixelRect, smear_passes, smear_taps};
use crate::color::scopes_reference::signal;
use crate::color::vec::Vec3;
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines;
use std::sync::{Arc, OnceLock};

type R<T> = Result<T, Box<dyn std::error::Error>>;

fn gpu() -> Option<Arc<Gpu>> {
    static GPU: OnceLock<Option<Arc<Gpu>>> = OnceLock::new();
    GPU.get_or_init(|| match Gpu::new() {
        Ok(g) => Some(g),
        Err(e) => {
            eprintln!("skipping GPU tests: {e}");
            None
        }
    })
    .clone()
}

fn floats(bytes: &[u8]) -> Vec<f32> {
    bytes.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

fn f32_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}

#[test]
fn uniform_layouts_mirror_the_shaders() {
    assert_eq!(FilterU::default().bytes().len(), 96);
    assert_eq!(BlurU::default().bytes().len(), 32);
    assert_eq!(FlowU::default().bytes().len(), 48);
    let blur = BlurU { axis: [1, 0], radius: 9, clamp_edges: 1, lo: [2, 3], hi: [4, 5] }.bytes();
    let words: Vec<i32> = blur.chunks_exact(4).map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
    assert_eq!(words, [1, 0, 9, 1, 2, 3, 4, 5]);
    let flow = floats(&FlowU { lambda: 2.0, sigma: 3.0, ..FlowU::default() }.bytes());
    assert_eq!((flow[1], flow[6], flow[7], flow[8]), (2.0, 1.0, 1.0, 3.0));
}

#[test]
fn every_kernel_has_a_compute_entry() {
    for kernel in Kernel::ALL {
        let entry = pipelines::find(kernel.module, kernel.name);
        assert!(entry.is_some_and(|e| e.stage == pipelines::ShaderStage::Compute), "{} missing", kernel.name);
    }
}

#[test]
fn smear_plan_splits_long_smears() {
    assert_eq!(smear_taps([10.0, 0.0]), 11);
    let n = smear_taps([60.0, 20.0]);
    let (fine, coarse) = smear_passes(n).unwrap_or_default();
    assert!(fine * coarse == n && n > 32);
    assert_eq!(smear_taps([0.0, 0.0]), 2);
    assert_eq!(smear_taps([10_000.0, 0.0]), 23 * 23);
    assert_eq!(smear_passes(11), None);
}

#[test]
fn pixel_rect_keeps_centers_inside_the_frame() {
    let rect = PixelRect::new([16.0, 16.0], [288.0, 148.0], 320, 180);
    assert_eq!(rect, PixelRect { min_x: 16, min_y: 16, max_x: 303, max_y: 163 });
    let clipped = PixelRect::new([-10.0, -10.0], [400.0, 400.0], 320, 180);
    assert_eq!(clipped, PixelRect { min_x: 0, min_y: 0, max_x: 319, max_y: 179 });
}

#[test]
fn png_has_signature_and_chunks() {
    let png = png_encode(&[128; 4 * 4 * 4], 4, 4);
    assert_eq!(png[..8], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    assert!(png.len() > 8 + 25 + 12 + 64);
    // IEND chunk with its fixed CRC closes the file.
    assert_eq!(png[png.len() - 12..], [0, 0, 0, 0, b'I', b'E', b'N', b'D', 0xae, 0x42, 0x60, 0x82]);
}

#[test]
fn gaussian_weights_are_normalized() {
    let w = gaussian_weights(3.0);
    assert_eq!(w.len(), 19);
    assert!((w.iter().sum::<f32>() - 1.0).abs() < 1e-5);
}

#[test]
fn scope_layout_offsets_follow_the_buffer_order() {
    let l = ScopeLayout::default();
    assert_eq!(l.offset_parade(), 512 * 256);
    assert_eq!(l.offset_vector(), 4 * 512 * 256);
    assert_eq!(l.offset_histogram(), 4 * 512 * 256 + 256 * 256);
    assert_eq!(l.total_count(), l.offset_histogram() + 1024 + 4);
}

#[test]
fn gray_lands_in_the_vectorscope_center_and_white_on_top() {
    let layout = ScopeLayout { waveform_width: 8, waveform_levels: 16, vectorscope_size: 32 };
    let mut counts = ScopeCounts::new(layout);
    counts.add([0.5, 0.5, 0.5], 0.5, 0, 8);
    counts.add([1.0, 1.0, 1.0], 1.0, 7, 8);
    counts.finish();
    assert_eq!(counts.vectorscope[16 * 32 + 16], 2);
    assert_eq!(counts.waveform_luma[(15 - 8) * 8], 1);
    assert_eq!(counts.waveform_luma[7], 1); // white: top row, last column
    assert_eq!(counts.waveform_parade[(15 - 8) * 24 + 8], 1); // G panel
    assert_eq!((counts.histogram[128], counts.histogram[3 * 256 + 255]), (1, 1));
    assert_eq!(counts.max_vectorscope, 2);
    assert_eq!(counts.max_waveform_luma, 1);
}

#[test]
fn red_is_right_of_center_and_above_in_cbcr() {
    let [cb, cr] = scope_binning::cbcr([1.0, 0.0, 0.0]);
    assert!(cb < 0.0 && (cr - 0.5).abs() < 1e-6);
    let (col, row) = scope_binning::vectorscope_bin(cb, cr, 256);
    assert_eq!((col < 128, row), (true, 0));
}

#[test]
fn rgba_scopes_count_every_pixel_once_per_scope() {
    let (w, h) = (8, 4);
    let bytes: Vec<u8> = (0..w * h).flat_map(|i| [(i * 8) as u8, 40, 200, 255]).collect();
    let layout = ScopeLayout { waveform_width: 8, waveform_levels: 16, vectorscope_size: 16 };
    let c = scope_binning::compute_rgba(&bytes, w, h, layout, 1);
    let total = |v: &[u32]| v.iter().sum::<u32>();
    assert_eq!(total(&c.waveform_luma), 32);
    assert_eq!(total(&c.waveform_parade), 96);
    assert_eq!(total(&c.vectorscope), 32);
    assert_eq!(total(&c.histogram), 128);
    assert_eq!(scope_binning::compute_rgba(&bytes, w, h, layout, 2).vectorscope.iter().sum::<u32>(), 8);
    assert_eq!(scope_binning::compute_rgba(&bytes[..8], w, h, layout, 1).max_histogram, 0);
}

#[test]
fn nv12_gray_is_neutral() {
    let (w, h) = (4, 4);
    let mut bytes = vec![126u8; w * h]; // limited range mid gray
    bytes.extend(vec![128u8; w * h / 2]);
    let layout = ScopeLayout { waveform_width: 4, waveform_levels: 16, vectorscope_size: 16 };
    let c = scope_binning::compute_nv12(&bytes, w, h, false, layout, 1);
    assert_eq!(c.vectorscope[8 * 16 + 8], 16);
    assert_eq!(c.max_vectorscope, 16);
}

#[test]
fn from_words_splits_the_gpu_buffer() {
    let layout = ScopeLayout { waveform_width: 2, waveform_levels: 2, vectorscope_size: 2 };
    let words: Vec<u32> = (0..layout.total_count() as u32).collect();
    let c = ScopeCounts::from_words(layout, &words);
    assert_eq!(c.as_ref().map(|c| c.waveform_parade[0]), Some(4));
    assert_eq!(c.map(|c| c.max_histogram), Some(layout.total_count() as u32 - 1));
    assert!(ScopeCounts::from_words(layout, &words[..5]).is_none());
}

#[test]
fn premultiply_matches_the_cpu_within_one_step() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (16u32, 8u32);
    let src: Vec<f32> = (0..w * h * 4).map(|i| ((i * 37) % 101) as f32 / 100.0).collect();
    let input = gpu.texture(w, h, PixelFormat::Rgba32Float);
    gpu.upload_texture(&input, &f32_bytes(&src), w * 16);
    let out = gpu.texture(w, h, PixelFormat::Rgba32Float);
    let mut cb = gpu.commands();
    Kernels::new(&gpu).premultiply(&mut cb, &input, &out)?;
    gpu.submit_and_wait(cb)?;
    let got = floats(&gpu.read_texture(&out)?);
    for (px, expected) in got.chunks_exact(4).zip(src.chunks_exact(4)) {
        for c in 0..3 {
            assert!((px[c] - expected[c] * expected[3]).abs() <= 1.0 / 255.0);
        }
        assert!((px[3] - expected[3]).abs() <= 1.0 / 255.0);
    }
    Ok(())
}

#[test]
fn blur_keeps_a_flat_image_flat() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (48u32, 32u32);
    let a = gpu.texture(w, h, PixelFormat::Rgba32Float);
    let b = gpu.texture(w, h, PixelFormat::Rgba32Float);
    gpu.upload_texture(&a, &f32_bytes(&vec![0.5; (w * h * 4) as usize]), w * 16);
    let mut cb = gpu.commands();
    Kernels::new(&gpu).blur(&mut cb, &a, &b, &gaussian_weights(3.0), None)?;
    gpu.submit_and_wait(cb)?;
    let got = floats(&gpu.read_texture(&a)?);
    let center = ((h / 2 * w + w / 2) * 4) as usize;
    assert!(got[center..center + 4].iter().all(|v| (v - 0.5).abs() <= 1.0 / 255.0));
    Ok(())
}

/// Exact counters: the GPU scopes against the CPU binning of the same pixels (palette colors sit inside their bins).
#[test]
fn gpu_scope_counters_equal_the_cpu_binning() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let layout = ScopeLayout { waveform_width: 64, waveform_levels: 32, vectorscope_size: 32 };
    let (w, h) = (96u32, 24u32);
    let palette =
        [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0], [0.18, 0.18, 0.18], [0.5, 0.2, 0.05], [0.05, 0.3, 0.7], [0.9, 0.6, 0.1]];
    let mut pixels = Vec::new();
    let mut expected = ScopeCounts::new(layout);
    for y in 0..h as usize {
        for x in 0..w as usize {
            let c = palette[(x / 3 + y * 5) % palette.len()];
            pixels.extend([c[0], c[1], c[2], 1.0]);
            let (s, luma) = signal(Vec3::new(c[0], c[1], c[2]));
            expected.add([s.x, s.y, s.z], luma, x, w as usize);
        }
    }
    let input = gpu.texture(w, h, PixelFormat::Rgba32Float);
    gpu.upload_texture(&input, &f32_bytes(&pixels), w * 16);
    let counts = gpu.storage_buffer(layout.total_count() as u64 * 4);
    let mut block = super::Block::new(80);
    block.u(0, &[w, h, 1, 15, 64, 32, 32, 64]);
    block.u(32, &[layout.offset_waveform_luma() as u32, layout.offset_parade() as u32]);
    block.u(40, &[layout.offset_vector() as u32, layout.offset_histogram() as u32]);
    let dummy = gpu.texture(w, h, PixelFormat::Rgba16Float);
    let bytes = block.bytes();
    let mut cb = gpu.commands();
    super::Dispatch {
        kernel: Kernel::new("Scopes", "scopeAccumulate"),
        inputs: &[(0, &input)],
        buffers: &[(2, &counts)],
        constants: &[&bytes],
        output: &dummy,
        grid: Some((w, h)),
    }
    .record(&gpu, &mut cb.compute())?;
    gpu.submit_and_wait(cb)?;
    let words: Vec<u32> = gpu
        .read_buffer(&counts, layout.total_count() as u64 * 4)?
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let got = ScopeCounts::from_words(layout, &words).ok_or("short counts")?;
    assert_eq!(got.waveform_luma, expected.waveform_luma);
    assert_eq!(got.waveform_parade, expected.waveform_parade);
    assert_eq!(got.vectorscope, expected.vectorscope);
    assert_eq!(got.histogram, expected.histogram);
    Ok(())
}

/// The ReferenceGraph: both graphs render, are not blank, and the families graph ends opaque (present). `SQ_GPU_DUMP=<dir>`
/// writes `reference-graph-<backend>.png` for the cross-backend compare.
#[test]
fn reference_graph_renders() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let image = reference_graph::render(&gpu)?;
    assert_eq!(image.len(), (WIDTH * HEIGHT * 4) as usize);
    let (filters, families) = image.split_at((WIDTH * reference_graph::GRAPH_HEIGHT * 4) as usize);
    for half in [filters, families] {
        assert!(half.iter().any(|v| *v > 8) && half.windows(4).any(|p| p[..3] != half[..3]), "blank graph");
    }
    assert!(families.chunks_exact(4).all(|p| p[3] == 255));
    if let Ok(dir) = std::env::var("SQ_GPU_DUMP") {
        let name = format!("{dir}/reference-graph-{:?}.png", gpu.info().backend);
        std::fs::write(name, png_encode(&image, WIDTH as usize, HEIGHT as usize))?;
    }
    Ok(())
}
