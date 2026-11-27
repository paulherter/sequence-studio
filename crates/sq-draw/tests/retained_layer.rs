//! The retained UI layer (`WgpuRenderer::draw_retained`) shows exactly what a full draw shows, frame after frame, while
//! redrawing only the changed parts. Skips without a GPU.

use sq_draw::damage::Damage;
use sq_draw::{Color, DrawList, Rect, RgbaImage, WgpuRenderer};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

fn list(x: f32, tint: f32) -> DrawList {
    let mut l = DrawList::new(96.0, 64.0);
    l.fill(Rect::new(0.0, 0.0, 96.0, 64.0), Color::hex(0x202830, 1.0), 0.0);
    l.fill(Rect::new(4.0, 4.0, 40.0, 30.0), Color { r: 0.9, g: 0.2, b: 0.1, a: 0.5 }, 6.0);
    l.image(Rect::new(50.0, 4.0, 30.0, 30.0), 5, [0.0, 0.0, 1.0, 1.0], Color::WHITE);
    l.fill(Rect::new(x, 40.0, 12.0, 20.0), Color { r: 0.1, g: tint, b: 0.9, a: 0.6 }, 3.0);
    l
}

#[test]
fn a_retained_frame_equals_a_full_draw_after_every_kind_of_change() {
    let Ok(gpu) = Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return;
    };
    let fmt = PixelFormat::Rgba8Unorm;
    let mut kept = WgpuRenderer::new(Arc::clone(&gpu), fmt).expect("renderer");
    let mut full = WgpuRenderer::new(Arc::clone(&gpu), fmt).expect("renderer");
    let (a, b) = (gpu.texture(96, 64, fmt), gpu.texture(96, 64, fmt));
    let clear = Color::hex(0x101010, 1.0);
    let image = |v: u8| RgbaImage { width: 1, height: 1, pixels: vec![v, 90, 30, 255] };
    let frames: Vec<(DrawList, Option<u8>)> = vec![
        (list(10.0, 0.5), Some(200)),
        (list(10.0, 0.5), None),
        (list(60.0, 0.5), None),
        (list(60.0, 0.9), None),
        (list(60.0, 0.9), Some(40)),
        (list(5.0, 0.1), Some(90)),
    ];
    let mut kinds = Vec::new();
    for (l, img) in &frames {
        if let Some(v) = img {
            kept.set_image(5, &image(*v));
            full.set_image(5, &image(*v));
        }
        kinds.push(kept.draw_retained(l, &a, clear, None).expect("retained"));
        full.draw(l, &b, clear, None, 1.0).expect("full");
        assert_eq!(gpu.read_texture(&a).expect("read"), gpu.read_texture(&b).expect("read"));
    }
    assert_eq!(kinds[0], Damage::Full);
    assert_eq!(kinds[1], Damage::None);
    assert!(matches!(kinds[2], Damage::Regions(_)), "{:?}", kinds[2]);
    assert!(matches!(kinds[4], Damage::Regions(_)), "a new image redraws only its quad: {:?}", kinds[4]);
}
