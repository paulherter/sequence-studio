//! SDR regression (HDR-PLAN.md, display path): a fixed scene (shapes, strokes, a segment, a triangle, a video quad with a
//! picture and an overlay above it) through `WgpuRenderer` must hash to the same value before and after the extended-range
//! work. The golden was measured with the renderer as it was before `draw_with` / `VideoOverride` existed. Skips without a GPU.

use sq_draw::{Color, DrawList, Rect, RgbaImage, WgpuRenderer};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;

/// FNV-1a over the pixels.
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3))
}

/// Pinned hash of the scene on the PC's DX12 adapter (Windows test PC); measured with the renderer before and after the change (equal).
const GOLDEN_DX12: Option<u64> = Some(0x7ec1_6e01_663d_0a44);

#[test]
fn the_sdr_scene_hashes_as_before() {
    let Ok(gpu) = Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return;
    };
    let mut renderer = WgpuRenderer::new(std::sync::Arc::clone(&gpu), PixelFormat::Rgba8Unorm).expect("renderer");
    let mut pixels = vec![0u8; 32 * 32 * 4];
    for (i, px) in pixels.as_chunks_mut::<4>().0.iter_mut().enumerate() {
        *px = [(i % 32 * 8) as u8, (i / 32 * 8) as u8, 120, 255];
    }
    renderer.set_video(Some(&RgbaImage { width: 32, height: 32, pixels }));
    let mut list = DrawList::new(160.0, 120.0);
    list.fill(Rect::new(4.0, 4.0, 152.0, 112.0), Color::hex(0x2c2c2e, 1.0), 6.0);
    list.video(Rect::new(20.0, 20.0, 100.0, 60.0), [0.0, 0.0, 1.0, 1.0]);
    list.fill(Rect::new(60.0, 40.0, 50.0, 30.0), Color::hex(0xff3b30, 0.5), 4.0);
    list.stroke(Rect::new(10.0, 90.0, 60.0, 20.0), Color::hex(0x0a84ff, 1.0), 2.0, 5.0);
    list.segment(10.0, 10.0, 150.0, 110.0, 3.0, Color::hex(0x30d158, 0.8));
    list.triangle(Rect::new(120.0, 85.0, 20.0, 24.0), Color::WHITE, false);
    let shot = renderer.render_to_image(&list, 160, 120, Color::hex(0x1c1c1e, 1.0), None).expect("render");
    let hash = fnv(&shot.pixels);
    eprintln!("sdr scene hash: {hash:#018x} on {}", gpu.info().name);
    if let Some(golden) = GOLDEN_DX12.filter(|_| gpu.info().backend == wgpu::Backend::Dx12) {
        assert_eq!(hash, golden, "the SDR path changed");
    }
}
