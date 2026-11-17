//! The raised-button shadow on a dark panel through the real GPU blend must match the 8-bit software model that the
//! screenshots and the shadow math tests use, at every desktop scale (1, 1.5, 2). The shadow is a stack of faint layers
//! (`Canvas::shadow`); a GPU that rounds each blend down instead of to nearest would darken it by one level per layer.
//! Skips without a GPU adapter.

use sq_draw::{Canvas, Color, RgbaImage, SoftwareRenderer, Sources, WgpuRenderer};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use sq_uikit::controls_grid::CGRect;

const PANEL: u32 = 0x1c1c1e;

fn scene(scale: f32) -> (sq_draw::DrawList, usize, usize) {
    let (w, h) = ((120.0 * scale) as usize, (60.0 * scale) as usize);
    let mut c = Canvas::with_size(w as f32, h as f32, None, scale);
    let card = CGRect::new(20.0, 15.0, 80.0, 24.0);
    // The values `stone_button` uses on a dark panel: `0 1px 1.5px #00000080` under a radius 6 body.
    c.shadow(card, 6.0, 1.5, 1.0, Color::new(0.0, 0.0, 0.0, 128.0 / 255.0), true);
    c.fill_rounded(card, 6.0, Color::hex(0x3a3a3c, 1.0));
    (c.list, w, h)
}

/// The red channel down the column through the middle of the card, from `y0` for `n` rows.
fn column(img: &RgbaImage, x: usize, y0: usize, n: usize) -> Vec<u8> {
    (y0..y0 + n).map(|y| img.pixels[(y * img.width + x) * 4]).collect()
}

#[test]
fn the_gpu_draws_the_button_shadow_like_the_model_at_every_scale() {
    let Ok(gpu) = Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return;
    };
    let mut renderer = WgpuRenderer::new(std::sync::Arc::clone(&gpu), PixelFormat::Rgba8Unorm).expect("renderer");
    for scale in [1.0f32, 1.5, 2.0] {
        let (list, w, h) = scene(scale);
        let clear = Color::hex(PANEL, 1.0);
        let model = SoftwareRenderer::render_8bit(&list, w, h, clear, &Sources::default());
        let gpu_img = renderer.render_to_image(&list, w as u32, h as u32, clear, None).expect("render");
        let x = (60.0 * scale) as usize;
        let y0 = (38.0 * scale) as usize;
        let n = (6.0 * scale) as usize;
        let (m, g) = (column(&model, x, y0, n), column(&gpu_img, x, y0, n));
        eprintln!("scale {scale} on {}: model {m:?} gpu {g:?}", gpu.info().name);
        for (a, b) in m.iter().zip(&g) {
            assert!(a.abs_diff(*b) <= 1, "scale {scale}: model {m:?} gpu {g:?}");
        }
    }
}
