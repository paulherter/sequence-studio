//! The extended-range window path forces the Source monitor's image slot to black and white like the Program video quad
//! (HDR-PLAN.md, Step 5): `cover = white - black` then tells the present pass where the Source picture shows. Skips without a GPU.

use sq_draw::wgpu_renderer::VideoOverride;
use sq_draw::{Color, DrawList, Rect, RgbaImage, WgpuRenderer};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;

const SLOT: usize = 5;

#[test]
fn an_image_slot_can_be_forced_to_black_and_white() {
    let Ok(gpu) = Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return;
    };
    let mut renderer = WgpuRenderer::new(std::sync::Arc::clone(&gpu), PixelFormat::Rgba8Unorm).expect("renderer");
    renderer.set_image(SLOT, &RgbaImage { width: 1, height: 1, pixels: vec![200, 40, 20, 255] });
    let mut list = DrawList::new(8.0, 8.0);
    list.image(Rect::new(0.0, 0.0, 4.0, 8.0), SLOT, [0.0, 0.0, 1.0, 1.0], Color::WHITE);
    let target = gpu.texture(8, 8, PixelFormat::Rgba8Unorm);
    let read = |renderer: &mut WgpuRenderer, image: Option<(usize, VideoOverride)>| {
        renderer
            .draw_with_image(&list, &target, Color::hex(0x101010, 1.0), None, 1.0, VideoOverride::Keep, image)
            .expect("draw");
        let px = gpu.read_texture(&target).expect("read");
        // The image side (x = 1) and the plain background (x = 6) of row 4.
        let at = |x: usize| [px[(4 * 8 + x) * 4], px[(4 * 8 + x) * 4 + 1], px[(4 * 8 + x) * 4 + 2]];
        (at(1), at(6))
    };
    let (kept, bg) = read(&mut renderer, None);
    assert_eq!(kept, [200, 40, 20], "the slot's own picture");
    let (black, bg_b) = read(&mut renderer, Some((SLOT, VideoOverride::Black)));
    let (white, bg_w) = read(&mut renderer, Some((SLOT, VideoOverride::White)));
    assert_eq!(black, [0, 0, 0]);
    assert_eq!(white, [255, 255, 255]);
    // Everything outside the picture is the same in all three: it never counts as picture.
    assert!(bg == bg_b && bg == bg_w, "{bg:?} {bg_b:?} {bg_w:?}");
}
