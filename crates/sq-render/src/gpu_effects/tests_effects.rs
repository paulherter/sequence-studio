//! GPU against the CPU references for every pass of the effect chain. Tolerance 0.01 on r, g, b as in the Swift look tests
//! (ImageFilterLookTests, StyleFilterLookTests); the inputs here are the working images themselves, so f16 storage is the only
//! source of difference. Tests skip with a note when the machine has no GPU adapter.

use super::effect_passes::EffectPasses;
use super::scratch::Scratch;
use super::testing::{R, download, gpu, upload, video_image, whole, worst};
use crate::effects::gaussian_blur::{self, Plan};
use crate::effects::image_filters::{self as filters, Frame, Image};
use crate::effects::simd::{Float2, Float4};
use crate::effects::style_filters;
use sq_core_effects::effects_evaluation::{DropShadow, ImageFilter, OutlinePosition};
use sq_core_time::Vec2;
use sq_gpu::layout::PixelFormat;

const TOLERANCE: f32 = 0.01;

/// Runs `filter` on `img` (frame = whole image) on the GPU.
fn render(
    filter: &ImageFilter,
    img: &Image,
    frame: &Frame,
    pf: f64,
) -> Result<Option<Image>, Box<dyn std::error::Error>> {
    let Some(gpu) = gpu() else { return Ok(None) };
    let passes = EffectPasses::new(&gpu);
    let mut scratch = Scratch::new(&gpu);
    let mut cmds = gpu.commands();
    let src = upload(&gpu, img);
    let out = gpu.texture(img.width as u32, img.height as u32, PixelFormat::Rgba16Float);
    assert!(passes.filter(&mut cmds, &mut scratch, filter, &src, &out, frame, pf)?, "{filter:?} did not run");
    gpu.submit_and_wait(cmds)?;
    Ok(Some(download(&gpu, &out)?))
}

fn expect_matches(filter: &ImageFilter, img: &Image, want: &Image) -> R {
    let Some(got) = render(filter, img, &whole(img), 1.0)? else { return Ok(()) };
    let (w, at) = worst(&got, want);
    assert!(
        w <= TOLERANCE,
        "{filter:?}: worst {w} at ({}, {}) got {:?} want {:?}",
        at % img.width,
        at / img.width,
        got.px[at],
        want.px[at]
    );
    Ok(())
}

fn checker() -> Image {
    video_image(32, 32, |x, y| if (x / 4 + y / 4) % 2 == 0 { (200, 200, 200) } else { (60, 60, 60) })
}

fn ramp() -> Image {
    video_image(32, 32, |x, y| ((255 - x * 7 % 256) as u8, (y * 7 % 256) as u8, (x * 7 % 256) as u8))
}

#[test]
fn sharpen_and_unsharp_match_the_reference() -> R {
    let img = checker();
    expect_matches(&ImageFilter::Sharpen { amount: 0.8 }, &img, &filters::sharpen(&img, 0.8, None))?;
    let f = ImageFilter::UnsharpMask { sigma: 1.5, amount: 0.8, threshold: 0.02 };
    expect_matches(&f, &img, &filters::unsharp_mask(&img, 1.5, 0.8, 0.02, None))
}

#[test]
fn short_and_long_smears_match_the_reference() -> R {
    let spot =
        video_image(
            32,
            32,
            |x, y| {
                if (12..20).contains(&x) && (12..20).contains(&y) { (240, 200, 40) } else { (30, 30, 30) }
            },
        );
    let a = 30f64.to_radians();
    let (dx, dy) = (10.0 * a.sin(), -10.0 * a.cos());
    let f = ImageFilter::DirectionalBlur { dx, dy };
    expect_matches(&f, &spot, &filters::directional_blur(&spot, Float2::new(dx as f32, dy as f32)))?;
    // A long smear runs as two comb passes on the GPU: the same picture as the one-pass reference, edges included.
    for (len, degrees) in [(90.0, 30.0), (140.0, 0.0), (70.0, 90.0), (120.0, 200.0)] {
        let src = video_image(112, 80, |x, y| {
            if (40..70).contains(&x) && (30..50).contains(&y) {
                (240, 200, 40)
            } else if (x + y) % 23 == 0 {
                (220, 220, 220)
            } else {
                (30, 30, 30)
            }
        });
        let a = f64::to_radians(degrees);
        let (dx, dy) = (len * a.sin(), -len * a.cos());
        let d = Float2::new(dx as f32, dy as f32);
        assert!(filters::smear_passes(filters::smear_taps(Float2::new(len as f32, 0.0))).is_some());
        expect_matches(&ImageFilter::DirectionalBlur { dx, dy }, &src, &filters::directional_blur(&src, d))?;
    }
    Ok(())
}

#[test]
fn mirror_matches_the_reference_with_an_off_center_line() -> R {
    let img = ramp();
    let f = ImageFilter::Mirror { center: Vec2::new(4.0, 0.0), angle: 0.0 };
    expect_matches(&f, &img, &filters::mirror(&img, Float2::new(20.0, 16.0), 0.0))?;
    let f = ImageFilter::Mirror { center: Vec2::new(0.0, 0.0), angle: 45.0 };
    expect_matches(&f, &img, &filters::mirror(&img, Float2::new(16.0, 16.0), 45.0))
}

#[test]
fn noise_matches_the_reference() -> R {
    // 64 px wide: the working texture has no margin, so its pixel grid (the hash input) is the frame's.
    let img = video_image(64, 64, |_, _| (128, 128, 128));
    let f = ImageFilter::Noise { amount: 0.6, color: true, clip: true, seed: 12345 };
    expect_matches(&f, &img, &filters::noise(&img, 0.6, true, true, 12345))
}

#[test]
fn glow_matches_the_reference() -> R {
    let spot = video_image(32, 32, |x, y| {
        if (14..18).contains(&x) && (14..18).contains(&y) { (255, 255, 255) } else { (40, 40, 40) }
    });
    let f = ImageFilter::Glow { threshold: 0.5, sigma: 3.0, intensity: 1.5, color: None };
    expect_matches(&f, &spot, &filters::glow(&spot, 0.5, 3.0, 1.5, None))?;
    let tint = [0.0, 0.5, 1.0];
    let f = ImageFilter::Glow { threshold: 0.5, sigma: 2.0, intensity: 1.0, color: Some(tint) };
    let lin3 = crate::effects::simd::Float3::new(0.0, super::effect_chain_plan::lin(0.5), 1.0);
    expect_matches(&f, &spot, &filters::glow(&spot, 0.5, 2.0, 1.0, Some(lin3)))
}

#[test]
fn mosaic_matches_the_reference_and_big_blocks_are_true_averages() -> R {
    let img = video_image(32, 32, |x, y| ((x * 8) as u8, ((x * y) & 255) as u8, (y * 8) as u8));
    let frame = whole(&img);
    for (columns, rows, sharp) in [(4, 8, false), (4, 4, true)] {
        let f = ImageFilter::Mosaic { columns, rows, sharp };
        expect_matches(&f, &img, &filters::mosaic(&img, &frame, columns, rows, sharp))?;
    }
    // One block over 128 x 128 with a single bright column: the average is exactly 1/128 of it, not a sampled guess.
    let big = video_image(128, 128, |x, _| if x == 1 { (255, 255, 255) } else { (0, 0, 0) });
    let f = ImageFilter::Mosaic { columns: 1, rows: 1, sharp: false };
    if let Some(got) = render(&f, &big, &whole(&big), 1.0)? {
        let v = got.px[50 * 128 + 50].x;
        assert!((v - 1.0 / 128.0).abs() < 0.0005, "got {v}");
    }
    Ok(())
}

#[test]
fn every_style_filter_matches_its_reference() -> R {
    use ImageFilter as F;
    let v = Vec2::new;
    let filters_under_test = [
        F::Vignette { amount: -1.5, midpoint: 0.5, roundness: 0.0, feather: 0.5 },
        F::Vignette { amount: 1.5, midpoint: 0.3, roundness: -0.6, feather: 0.3 },
        F::Invert { channel: 0, blend: 0.25 },
        F::Invert { channel: 4, blend: 0.5 },
        F::Tint { black: [0.1, 0.0, 0.4], white: [1.0, 0.9, 0.3], amount: 0.8 },
        F::BrightnessContrast { brightness: 0.2, contrast: 0.4 },
        F::Strobe { color: [1.0, 0.5, 0.0], blend: 0.3, op: 3, transparent: false },
        F::AlphaAdjust { opacity: 0.6, ignore: false, invert: false, mask_only: false },
        F::Flip { horizontal: true, vertical: true },
        F::Twirl { center: v(3.0, -2.0), angle: 120.0, radius: 0.4 },
        F::WaveWarp { wave_type: 0, height: 3.0, width: 12.0, direction: 90.0, phase: 0.3, pinning: 0 },
        F::WaveWarp { wave_type: 2, height: 2.0, width: 9.0, direction: 30.0, phase: 0.1, pinning: 1 },
        F::Spherize { center: v(-4.0, 4.0), radius: 14.0, strength: -0.6 },
        F::RgbSplit { dx: 3.0, dy: 1.0, radial: false, mix: 0.2 },
        F::RgbSplit { dx: 4.0, dy: 0.0, radial: true, mix: 0.0 },
        F::RadialBlur { center: v(0.0, 0.0), amount: 25.0, zoom: false, high: true },
        F::RadialBlur { center: v(4.0, 2.0), amount: 30.0, zoom: true, high: false },
        F::LensDistortion {
            curvature: -0.6,
            decenter: v(0.1, -0.2),
            fill_alpha: true,
            fill: [0.0; 3],
            auto_scale: false,
            exact_model: false,
        },
        F::LensDistortion {
            curvature: 0.5,
            decenter: v(0.0, 0.0),
            fill_alpha: false,
            fill: [0.2, 0.4, 1.0],
            auto_scale: false,
            exact_model: false,
        },
        F::LightLeak {
            color1: [1.0, 0.6, 0.2],
            color2: [1.0, 0.2, 0.5],
            intensity: 1.2,
            center: v(0.8, -0.5),
            size: 0.5,
            angle: 1.0,
        },
        F::Gradient {
            color1: [0.1, 0.2, 0.9],
            color2: [1.0, 0.8, 0.0],
            start: v(-10.0, -12.0),
            end: v(8.0, 14.0),
            radial: false,
            blend: 0.8,
        },
        F::Halftone { size: 6.0, angle: 30.0, softness: 0.3, color: false, blend: 0.9 },
        F::Tile { columns: 2.5, rows: 3.0, offset: v(0.2, -0.3), mirror: false },
        F::Tile { columns: 3.0, rows: 2.0, offset: v(0.1, 0.0), mirror: true },
        F::Kaleidoscope { center: v(2.0, -3.0), segments: 6, angle: 20.0, zoom: 1.5 },
        F::EdgeFeather { amount: 9.0 },
        F::Glitch { amount: 6.0, block: 5.0, split: 3.0, density: 0.7, seed: 11 },
        F::Glitch { amount: 4.0, block: 7.0, split: 0.0, density: 1.0, seed: 2 },
    ];
    let img = ramp();
    let frame = whole(&img);
    for f in &filters_under_test {
        let want = style_filters::reference(f, &img, &frame, 1.0).ok_or("no reference")?;
        expect_matches(f, &img, &want)?;
    }
    let patches = video_image(32, 32, |x, y| {
        [(200, 90, 30), (120, 40, 220), (128, 128, 128), (60, 240, 10)][(x / 8 + y / 8) % 4]
    });
    let f = F::Posterize { levels: 4 };
    expect_matches(&f, &patches, &style_filters::reference(&f, &patches, &whole(&patches), 1.0).ok_or("no reference")?)
}

#[test]
fn blur_matches_the_cpu_blur_with_and_without_repeated_edges() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let img = video_image(40, 24, |x, y| {
        if x < 20 {
            (230, 100, 40)
        } else if y < 12 {
            (20, 60, 200)
        } else {
            (250, 250, 250)
        }
    });
    let passes = EffectPasses::new(&gpu);
    for repeat in [false, true] {
        let plan = Plan::new(40.0, 24.0, 3.0, 0.0, None, 1, i64::MAX);
        let (src, scratch_b) = (upload(&gpu, &img), gpu.texture(40, 24, PixelFormat::Rgba16Float));
        let mut cmds = gpu.commands();
        let edges = repeat.then_some(([0, 0], [39, 23]));
        passes.blur(&mut cmds, &plan, &src, &scratch_b, edges)?;
        gpu.submit_and_wait(cmds)?;
        let want = gaussian_blur::blur(&img.px, 40, 24, plan.sigma, repeat);
        let want = Image { width: 40, height: 24, px: want };
        let (w, at) = worst(&download(&gpu, &src)?, &want);
        assert!(w <= 0.005, "repeat {repeat}: worst {w} at {at}");
    }
    Ok(())
}

fn shadow_case(opacity: f64, shadow_only: bool) -> Result<Option<(Image, Image)>, Box<dyn std::error::Error>> {
    let Some(gpu) = gpu() else { return Ok(None) };
    // A 16 px square centered in a 64 px working image, premultiplied opaque white.
    let img = Image::from_fn(64, 64, |x, y| {
        if (24..40).contains(&x) && (24..40).contains(&y) { Float4::new(1.0, 1.0, 1.0, 1.0) } else { Float4::ZERO }
    });
    let sh = DropShadow { color: [0.0; 3], opacity, dx: 8.0, dy: 0.0, sigma: 2.0, spread: 0.0, shadow_only };
    let plan = Plan::new(64.0, 64.0, 0.0, 0.0, None, 1, i64::MAX);
    let passes = EffectPasses::new(&gpu);
    let mut scratch = Scratch::new(&gpu);
    let mut cmds = gpu.commands();
    let (src, out) = (upload(&gpu, &img), gpu.texture(64, 64, PixelFormat::Rgba16Float));
    passes.shadow(&mut cmds, &mut scratch, &sh, &plan, &src, &out)?;
    gpu.submit_and_wait(cmds)?;
    Ok(Some((img, download(&gpu, &out)?)))
}

#[test]
fn drop_shadow_falls_beside_the_picture_and_keeps_it() -> R {
    let Some((_, out)) = shadow_case(0.5, false)? else { return Ok(()) };
    let at = |x: usize, y: usize| out.px[y * 64 + x];
    assert!((at(32, 32).x - 1.0).abs() < 0.01 && (at(32, 32).w - 1.0).abs() < 0.01, "picture intact: {:?}", at(32, 32));
    // Shadow: black at half opacity 8 px to the right of the square (x 32...47), alpha 0.5 deep inside, none far away.
    assert!((at(43, 32).w - 0.5).abs() < 0.03, "shadow alpha {:?}", at(43, 32));
    assert!(at(43, 32).x < 0.01);
    assert!(at(55, 32).w < 0.01 && at(5, 5).w < 0.001);
    Ok(())
}

#[test]
fn shadow_only_drops_the_picture() -> R {
    let Some((_, out)) = shadow_case(1.0, true)? else { return Ok(()) };
    let at = |x: usize, y: usize| out.px[y * 64 + x];
    assert!(at(26, 32).w < 0.01, "picture hidden where no shadow falls: {:?}", at(26, 32));
    assert!(at(43, 32).w > 0.95);
    Ok(())
}

fn disc(w: usize) -> Image {
    let c = (w as f32 - 1.0) / 2.0;
    Image::from_fn(w, w, |x, y| {
        let d = ((x as f32 - c).powi(2) + (y as f32 - c).powi(2)).sqrt();
        if d < w as f32 / 6.0 { Float4::new(1.0, 1.0, 1.0, 1.0) } else { Float4::ZERO }
    })
}

#[test]
fn outline_has_the_requested_width_on_each_side() -> R {
    let img = disc(96);
    let frame = whole(&img);
    let run = |position: OutlinePosition| {
        render(&ImageFilter::Outline { width: 6.0, color: [1.0, 0.0, 0.0], softness: 0.0, position }, &img, &frame, 1.0)
    };
    let (Some(outside), Some(inside)) = (run(OutlinePosition::Outside)?, run(OutlinePosition::Inside)?) else {
        return Ok(());
    };
    let row = 48;
    let edge = (96.0f32 / 6.0 + 47.5) as usize; // first column right of the disc's edge, about 63.5
    let red = |img: &Image, x: usize| img.px[row * 96 + x].x > 0.5 && img.px[row * 96 + x].y < 0.5;
    // Outside: red band of about 6 px beyond the disc; inside: red band within it.
    let outside_run = (edge - 4..edge + 12).filter(|x| red(&outside, *x)).count();
    let inside_run = (edge - 12..edge + 4).filter(|x| red(&inside, *x)).count();
    assert!((5..=7).contains(&outside_run), "outside band {outside_run} px");
    assert!((5..=7).contains(&inside_run), "inside band {inside_run} px");
    assert!(!red(&outside, 48) && !red(&inside, 48), "disc center untouched");
    Ok(())
}

#[test]
fn long_shadow_runs_along_its_angle_for_its_length() -> R {
    let img = Image::from_fn(128, 64, |x, y| {
        if (10..20).contains(&x) && (28..36).contains(&y) { Float4::new(1.0, 1.0, 1.0, 1.0) } else { Float4::ZERO }
    });
    // 90 degrees = to the right (clockwise from up), 40 px long, black, opaque, no fade.
    let f = ImageFilter::LongShadow { angle: 90.0, length: 40.0, color: [0.0; 3], fade: 0.0, opacity: 1.0 };
    let Some(out) = render(&f, &img, &whole(&img), 1.0)? else { return Ok(()) };
    let alpha = |x: usize| out.px[32 * 128 + x].w;
    assert!(alpha(15) > 0.99, "picture stays");
    assert!(alpha(40) > 0.9 && alpha(58) > 0.9, "shadow between: {} {}", alpha(40), alpha(58));
    assert!(alpha(65) < 0.05 && alpha(100) < 0.01, "ends at its length: {} {}", alpha(65), alpha(100));
    assert!(out.px[10 * 128 + 40].w < 0.01, "only along the angle");
    Ok(())
}
