//! The renderer oracle (docs/rust/session-ui-design.md section 5): `SoftwareRenderer` against `WgpuRenderer` on the three
//! G3 spike scenes (timeline, inspector, menu with stacked shadow rings). Pass bar: mean abs error < 0.5 levels, max <= 4
//! levels (8-bit blend rounding across 24 stacked shadow layers). Skips cleanly without a GPU adapter.

use sq_draw::{
    Canvas, Color, DrawList, GlyphAtlas, Rect, RgbaImage, SoftwareRenderer, Sources, TextAlign, WgpuRenderer,
};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use sq_uikit::controls_grid::CGRect;
use std::path::Path;

const BG: u32 = 0x1c1c1e;

fn c(h: u32) -> Color {
    Color::hex(h, 1.0)
}

fn atlas() -> GlyphAtlas {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    GlyphAtlas::inter(&root).unwrap_or_else(|| panic!("bundled Inter loads"))
}

fn text(l: &mut DrawList, a: &GlyphAtlas, s: &str, x: f32, baseline: f32, px: f32, col: Color) {
    l.text(s, x, baseline, px, col, a, TextAlign::Left, f32::INFINITY, 0);
}

fn shadow(cv: &mut Canvas, r: Rect, radius: f64, blur: f64, dy: f64, col: Color, opaque_above: bool) {
    cv.shadow(CGRect::new(r.x as f64, r.y as f64, r.w as f64, r.h as f64), radius, blur, dy, col, opaque_above);
}

fn image_slot(seed: u32) -> RgbaImage {
    let mut pixels = vec![0u8; 256 * 256 * 4];
    for y in 0..256i32 {
        for x in 0..256i32 {
            let i = ((y * 256 + x) * 4) as usize;
            let band = (((x / 16 + y / 16 + seed as i32) % 2) * 30) as u8;
            pixels[i] = (x as u8) / 2 + band;
            pixels[i + 1] = (y as u8) / 2 + band;
            pixels[i + 2] = (90 + seed * 40) as u8;
            pixels[i + 3] = if (x - 128).pow(2) + (y - 128).pow(2) > 126 * 126 && seed % 2 == 1 { 40 } else { 255 };
        }
    }
    RgbaImage { width: 256, height: 256, pixels }
}

fn timeline(a: &GlyphAtlas) -> DrawList {
    let mut l = DrawList::new(1280.0, 240.0);
    l.fill(Rect::new(0.0, 0.0, 1280.0, 240.0), c(BG), 0.0);
    l.fill(Rect::new(0.0, 0.0, 1280.0, 28.0), c(0x252528), 0.0);
    l.fill(Rect::new(0.0, 28.0, 1280.0, 1.0), c(0x3a3a3e), 0.0);
    for i in 0..120 {
        let x = 140.0 + i as f32 * 10.0;
        let major = i % 10 == 0;
        l.fill(Rect::new(x, if major { 14.0 } else { 21.0 }, 1.0, if major { 14.0 } else { 7.0 }), c(0x77777c), 0.0);
        if major {
            text(&mut l, a, &format!("00:00:{:02}", i / 10), x + 4.0, 12.0, 10.5, c(0x9a9aa0));
        }
    }
    for (t, name) in ["V1", "A1"].iter().enumerate() {
        let y = 36.0 + t as f32 * 96.0;
        l.fill(Rect::new(0.0, y, 132.0, 88.0), c(0x2a2a2d), 0.0);
        text(&mut l, a, name, 12.0, y + 30.0, 13.0, c(0xe8e8ea));
        l.stroke(Rect::new(10.0, y + 46.0, 28.0, 18.0), c(0x5a5a60), 1.0, 4.0);
        l.fill(Rect::new(140.0, y, 1140.0, 88.0), c(0x202022), 0.0);
    }
    let video = [
        (150.0, 260.0, 0x3a6ea5u32, "Interview_A001.mov"),
        (420.0, 150.0, 0x7a4fa0, "Broll_Harbor"),
        (580.0, 330.0, 0x3a8f6e, "Interview_A002.mov"),
        (920.0, 200.5, 0xa5693a, "Title 01"),
    ];
    for (x, w, col, name) in video {
        let r = Rect::new(x, 40.0, w, 80.0);
        l.fill(r, c(col), 5.0);
        l.push_clip(r);
        l.image(Rect::new(x, 58.0, w, 62.0), 0, [0.0, 0.0, 1.0, 1.0], Color::new(1.0, 1.0, 1.0, 0.55));
        l.fill(Rect::new(x, 40.0, w, 18.0), c(col).lifted(0.15).with_alpha(0.9), 0.0);
        text(&mut l, a, name, x + 8.0, 53.0, 11.0, Color::new(1.0, 1.0, 1.0, 0.95));
        l.pop_clip();
        l.stroke(r, c(col).lifted(0.35), 1.0, 5.0);
    }
    for (x, w) in [(150.0f32, 520.0f32), (700.0, 430.0)] {
        let r = Rect::new(x, 132.0, w, 80.0);
        l.fill(r, c(0x2f6f5a), 5.0);
        l.stroke(r, c(0x2f6f5a).lifted(0.35), 1.0, 5.0);
        l.push_clip(r);
        let (mut px, mut k) = (x + 4.0, 0u32);
        while px < x + w - 4.0 {
            k = k.wrapping_mul(1664525).wrapping_add(1013904223);
            let amp = 4.0 + ((k >> 16) % 30) as f32;
            l.segment(px, 172.0 - amp, px, 172.0 + amp, 1.5, Color::new(0.85, 1.0, 0.92, 0.8));
            px += 3.0;
        }
        text(&mut l, a, "Music_Bed.wav", x + 8.0, 148.0, 11.0, Color::new(1.0, 1.0, 1.0, 0.95));
        l.pop_clip();
    }
    l.segment(930.0, 60.0, 1100.0, 110.0, 2.0, c(0xffd04a));
    l.segment(300.0, 125.0, 380.0, 128.0, 1.0, c(0xffffff).with_alpha(0.7));
    l.fill(Rect::new(455.0, 28.0, 1.0, 212.0), Color::new(1.0, 0.27, 0.25, 1.0), 0.0);
    l.fill(Rect::new(448.0, 20.0, 15.0, 12.0), Color::new(1.0, 0.27, 0.25, 1.0), 3.0);
    l.triangle(Rect::new(1236.0, 6.0, 10.0, 14.0), c(0xe8e8ea), false);
    l.triangle(Rect::new(1218.0, 6.0, 10.0, 14.0), c(0xe8e8ea), true);
    l
}

fn inspector(a: &GlyphAtlas) -> DrawList {
    let mut cv = Canvas::with_size(360.0, 600.0, None, 1.0);
    cv.list.fill(Rect::new(0.0, 0.0, 360.0, 600.0), c(0x232326), 0.0);
    let mut y = 12.0;
    for (si, sec) in ["Transform", "Opacity", "Audio"].iter().enumerate() {
        cv.list.fill(Rect::new(8.0, y, 344.0, 28.0), c(0x2c2c30), 6.0);
        cv.list.triangle(Rect::new(18.0, y + 9.0, 7.0, 10.0), c(0xb0b0b6), false);
        text(&mut cv.list, a, sec, 34.0, y + 19.0, 12.5, c(0xf0f0f2));
        y += 36.0;
        for (ri, lab) in ["Position X", "Scale", "Rotation", "Anchor"].iter().enumerate() {
            text(&mut cv.list, a, lab, 20.0, y + 14.0, 11.5, c(0xa8a8ae));
            let v = ((si * 4 + ri) as f32 * 0.137 + 0.15) % 1.0;
            let tr = Rect::new(120.0, y + 6.0, 150.0, 4.0);
            cv.list.fill(tr, c(0x151517), 2.0);
            cv.list.fill(Rect::new(tr.x, tr.y, tr.w * v, tr.h), c(0x4c8dff), 2.0);
            let kx = tr.x + tr.w * v;
            shadow(
                &mut cv,
                Rect::new(kx - 6.0, y + 2.0, 12.0, 12.0),
                6.0,
                3.0,
                1.0,
                Color::new(0.0, 0.0, 0.0, 0.5),
                false,
            );
            cv.list.fill(Rect::new(kx - 6.0, y + 2.0, 12.0, 12.0), c(0xf4f4f6), 6.0);
            cv.list.stroke(Rect::new(kx - 6.0, y + 2.0, 12.0, 12.0), c(0x000000).with_alpha(0.25), 1.0, 6.0);
            let f = Rect::new(282.0, y - 2.0, 62.0, 20.0);
            cv.list.fill(f, c(0x19191b), 4.0);
            cv.list.stroke(f, if ri == 1 { c(0x4c8dff) } else { c(0x3a3a3f) }, 1.0, 4.0);
            text(&mut cv.list, a, &format!("{:.1}", v * 100.0), f.x + 8.0, y + 12.0, 11.0, c(0xe8e8ea));
            y += 26.0;
        }
        for (ti, lab) in ["Uniform scale", "Motion blur"].iter().enumerate() {
            let on = (si + ti) % 2 == 0;
            let t = Rect::new(20.0, y + 1.0, 30.0, 16.0);
            cv.list.fill(t, if on { c(0x4c8dff) } else { c(0x3d3d42) }, 8.0);
            let kx = if on { t.x + 15.0 } else { t.x + 1.0 };
            cv.list.fill(Rect::new(kx, t.y + 1.0, 14.0, 14.0), c(0xffffff), 7.0);
            text(&mut cv.list, a, lab, 60.0, y + 13.0, 11.5, c(0xd8d8dc));
            y += 24.0;
        }
        y += 8.0;
    }
    cv.list.fill(Rect::new(20.0, y, 150.0, 28.0), c(0x4c8dff), 6.0);
    text(&mut cv.list, a, "Apply", 20.0 + 75.0 - 15.0, y + 18.0, 12.0, c(0xffffff));
    cv.list.stroke(Rect::new(184.0, y, 150.0, 28.0), c(0x55555b), 1.0, 6.0);
    text(&mut cv.list, a, "Reset", 184.0 + 75.0 - 15.0, y + 18.0, 12.0, c(0xe0e0e4));
    cv.list
}

fn menu(a: &GlyphAtlas) -> DrawList {
    let mut cv = Canvas::with_size(520.0, 420.0, None, 1.0);
    cv.list.fill(Rect::new(0.0, 0.0, 520.0, 420.0), c(BG), 0.0);
    for i in 0..9 {
        cv.list.fill(Rect::new(0.0, i as f32 * 48.0, 520.0, 24.0), c(0x222225), 0.0);
    }
    let card = Rect::new(60.0, 30.0, 300.0, 340.0);
    shadow(&mut cv, card, 10.0, 24.0, 8.0, Color::new(0.0, 0.0, 0.0, 0.55), true);
    cv.list.fill(card, c(0x2d2d31), 10.0);
    cv.list.stroke(card, Color::new(1.0, 1.0, 1.0, 0.12), 1.0, 10.0);
    cv.list.push_clip(card.inset(1.0));
    let items = [
        ("Cut", "Cmd X"),
        ("Copy", "Cmd C"),
        ("Paste", "Cmd V"),
        ("-", ""),
        ("Ripple Delete", "Shift Del"),
        ("Speed / Duration...", "Cmd R"),
        ("-", ""),
        ("Add Transition", ">"),
        ("Nest", ""),
        ("Reveal in Library", ""),
    ];
    let mut y = card.y + 8.0;
    for (i, (t, k)) in items.iter().enumerate() {
        if *t == "-" {
            cv.list.fill(Rect::new(card.x + 12.0, y + 5.0, card.w - 24.0, 1.0), Color::new(1.0, 1.0, 1.0, 0.1), 0.0);
            y += 11.0;
            continue;
        }
        let row = Rect::new(card.x + 6.0, y, card.w - 12.0, 28.0);
        if i == 4 {
            cv.list.fill(row, c(0x4c8dff), 6.0);
        }
        text(&mut cv.list, a, t, row.x + 12.0, y + 19.0, 12.5, c(0xf2f2f4));
        if *k == ">" {
            cv.list.triangle(Rect::new(row.max_x() - 20.0, y + 9.0, 6.0, 10.0), c(0xb8b8be), false);
        } else if !k.is_empty() {
            let col = if i == 4 { Color::new(1.0, 1.0, 1.0, 0.8) } else { c(0x8e8e94) };
            text(&mut cv.list, a, k, row.max_x() - 12.0 - 56.0, y + 19.0, 11.5, col);
        }
        y += 30.0;
    }
    cv.list.pop_clip();
    let c2 = Rect::new(330.5, 120.25, 170.0, 120.0);
    shadow(&mut cv, c2, 8.0, 16.0, 6.0, Color::new(0.0, 0.0, 0.0, 0.5), false);
    cv.list.fill(c2, c(0x35353a), 8.0);
    cv.list.stroke(c2, Color::new(1.0, 1.0, 1.0, 0.14), 1.0, 8.0);
    for (i, t) in ["Cross Dissolve", "Dip to Black", "Wipe"].iter().enumerate() {
        text(&mut cv.list, a, t, c2.x + 12.0, c2.y + 28.0 + i as f32 * 30.0, 12.0, c(0xf0f0f2));
    }
    cv.list
}

/// (mean abs error per channel, max error) over RGB.
fn compare(a: &RgbaImage, b: &RgbaImage) -> (f64, u8) {
    let (mut sum, mut max) = (0u64, 0u8);
    for (p, q) in a.pixels.as_chunks::<4>().0.iter().zip(b.pixels.as_chunks::<4>().0) {
        for k in 0..3 {
            let d = p[k].abs_diff(q[k]);
            sum += d as u64;
            max = max.max(d);
        }
    }
    (sum as f64 / (a.width * a.height * 3) as f64, max)
}

#[test]
fn software_and_wgpu_agree_on_the_three_g3_scenes() {
    let gpu = match Gpu::new() {
        Ok(g) => g,
        Err(e) => {
            eprintln!("skipping the renderer oracle, no GPU adapter: {e}");
            return;
        }
    };
    eprintln!("adapter: {} ({:?})", gpu.info().name, gpu.info().backend);
    let a = atlas();
    let images: Vec<Option<RgbaImage>> = (0..6).map(|s| Some(image_slot(s))).collect();
    let scenes = [
        ("timeline", timeline(&a), 1280u32, 240u32),
        ("inspector", inspector(&a), 360, 600),
        ("menu", menu(&a), 520, 420),
    ];
    let mut renderer = match WgpuRenderer::new(gpu, PixelFormat::Rgba8Unorm) {
        Ok(r) => r,
        Err(e) => panic!("renderer: {e}"),
    };
    for (i, img) in images.iter().enumerate() {
        if let Some(img) = img {
            renderer.set_image(i, img);
        }
    }
    for (name, list, w, h) in &scenes {
        let clear = c(BG);
        let soft = SoftwareRenderer::render(
            list,
            *w as usize,
            *h as usize,
            clear,
            &Sources { atlas: Some(&a), video: None, images: &images },
        );
        let gpu_img = match renderer.render_to_image(list, *w, *h, clear, Some(&a)) {
            Ok(i) => i,
            Err(e) => panic!("{name}: {e}"),
        };
        let (mean, max) = compare(&soft, &gpu_img);
        eprintln!("{name}: {} quads, mean {mean:.4}, max {max}", list.quads().len());
        assert!(
            soft.pixels.as_chunks::<4>().0.iter().any(|p| p[..3] != [0x1c, 0x1c, 0x1e]),
            "{name}: the scene drew something"
        );
        assert!(mean < 0.5, "{name}: mean abs error {mean}");
        assert!(max <= 4, "{name}: max error {max} levels");
    }
}

#[test]
fn dirty_rect_upload_keeps_the_page_in_step() {
    let Ok(gpu) = Gpu::new() else {
        eprintln!("skipping the atlas upload test, no GPU adapter");
        return;
    };
    let a = atlas();
    let mut renderer = match WgpuRenderer::new(gpu, PixelFormat::Rgba8Unorm) {
        Ok(r) => r,
        Err(e) => panic!("renderer: {e}"),
    };
    // First frame uploads the whole page, the second adds new glyphs through the dirty rect only.
    for line in ["Timeline", "Timeline 0123456789 more glyphs"] {
        let mut l = DrawList::new(300.0, 30.0);
        text(&mut l, &a, line, 4.0, 20.0, 14.0, Color::WHITE);
        let soft =
            SoftwareRenderer::render(&l, 300, 30, Color::BLACK, &Sources { atlas: Some(&a), ..Default::default() });
        let img = renderer.render_to_image(&l, 300, 30, Color::BLACK, Some(&a));
        let (mean, max) = compare(&soft, &img.unwrap_or_else(|e| panic!("{e}")));
        assert!(mean < 0.01 && max <= 1, "text is bit-identical given the same atlas: mean {mean}, max {max}");
    }
}
