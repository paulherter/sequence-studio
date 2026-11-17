// SPDX-License-Identifier: GPL-3.0-or-later
//! The CPU-only Swift tests of the effect references (BlendParityTests, UltraKeyTests, ImageFilterLookTests,
//! StyleFilterLookTests, LensDistortionTests, RollingShutterTests), translated with the same inputs and expectations. The GPU
//! halves of those suites wait for the GPU layer (NOTES-effects.md).

use super::blend_modes as bm;
use super::image_filters::{self as imf, Frame, Image};
use super::simd::{Float2, Float3, Float4};
use super::style_filters::{self as sf, dec, enc, in_picture};
use super::ultra_key;
use sq_core_effects::effects_evaluation::{ChromaKey, ImageFilter};
use sq_core_model::BlendMode;
use sq_core_time::Vec2;

/// `(B, G, R, A)` as the Swift tests write 8-bit pixels.
type Px = (u8, u8, u8, u8);

fn linear(c: Px) -> Float4 {
    let a = f32::from(c.3) / 255.0;
    Float4::new(dec(f32::from(c.2) / 255.0) * a, dec(f32::from(c.1) / 255.0) * a, dec(f32::from(c.0) / 255.0) * a, a)
}

fn image(w: usize, h: usize, src: impl Fn(usize, usize) -> Px) -> Image {
    Image::from_fn(w, h, |x, y| linear(src(x, y)))
}

fn lum(v: u8) -> Px {
    (v, v, v, 255)
}

fn ramp(x: usize, y: usize) -> Px {
    ((x * 7 % 256) as u8, (y * 7 % 256) as u8, (255 - x * 7 % 256) as u8, 255)
}

fn whole(img: &Image) -> Frame {
    let size = Float2::new(img.width as f32, img.height as f32);
    Frame { center: size / 2.0, size }
}

fn refer(f: &ImageFilter, img: &Image) -> Image {
    sf::reference(f, img, &whole(img), 1.0).expect("a style filter")
}

fn at(img: &Image, x: i64, y: i64) -> Float4 {
    img.at(x, y)
}

fn close4(a: Float4, b: Float4, tol: f32) -> bool {
    (a - b).abs().max_element() <= tol
}

fn solid(w: usize, h: usize, c: Float4) -> Image {
    Image::from_fn(w, h, |_, _| c)
}

// MARK: blend modes

fn near3(a: Float3, e: Float3, tol: f32) {
    assert!((a - e).abs().max_element() <= tol, "{a:?} vs {e:?}");
}

#[test]
fn separable_new_modes() {
    let d = Float3::new(0.25, 0.5, 0.8);
    let s = Float3::splat;
    near3(bm::channel(BlendMode::LinearLight, d, s(0.75)), Float3::new(0.75, 1.0, 1.3), 1e-6);
    near3(bm::channel(BlendMode::LinearLight, d, s(0.25)), Float3::new(0.0, 0.0, 0.3), 1e-6);
    near3(bm::channel(BlendMode::Subtract, d, s(0.4)), Float3::new(0.0, 0.1, 0.4), 1e-6);
    near3(bm::channel(BlendMode::Divide, d, s(1.0)), d, 1e-6);
    near3(bm::channel(BlendMode::Divide, d, s(0.5)), Float3::new(0.5, 1.0, 1.0), 1e-6);
    near3(bm::channel(BlendMode::PinLight, d, s(0.2)), Float3::new(0.25, 0.4, 0.4), 1e-6);
    near3(bm::channel(BlendMode::PinLight, d, s(0.9)), Float3::new(0.8, 0.8, 0.8), 1e-6);
    near3(bm::channel(BlendMode::HardMix, d, s(0.5)), Float3::new(0.0, 1.0, 1.0), 1e-6);
    near3(bm::channel(BlendMode::VividLight, d, s(0.5)), d, 1e-6);
    near3(bm::channel(BlendMode::VividLight, d, s(0.75)), Float3::new(0.5, 1.0, 1.0), 1e-6);
}

#[test]
fn component_modes_swap_hue_saturation_and_luminance() {
    let red = Float3::new(1.0, 0.0, 0.0);
    let grey = Float3::splat(0.4);
    let d = Float3::new(0.2, 0.5, 0.3);
    let lum = bm::lum;
    assert!((lum(bm::channel(BlendMode::Luminosity, d, grey)) - 0.4).abs() < 1e-5);
    let c = bm::channel(BlendMode::Color, d, red);
    assert!((lum(c) - lum(d)).abs() < 1e-5 && c.x > c.y && (c.y - c.z).abs() < 1e-6);
    near3(bm::channel(BlendMode::Saturation, d, grey), Float3::splat(lum(d)), 1e-5);
    near3(bm::channel(BlendMode::Color, d, grey), Float3::splat(lum(d)), 1e-5);
    near3(bm::channel(BlendMode::Hue, grey, red), grey, 1e-5);
    for m in [BlendMode::Hue, BlendMode::Saturation, BlendMode::Color, BlendMode::Luminosity] {
        let o = bm::channel(m, Float3::new(0.9, 0.95, 0.1), Float3::new(0.05, 0.1, 1.0));
        assert!(o.x.min(o.y).min(o.z) >= -1e-6 && o.max_element() <= 1.0 + 1e-5, "{m:?} {o:?}");
    }
    near3(bm::channel(BlendMode::DarkerColor, d, red), red, 1e-6);
    near3(bm::channel(BlendMode::LighterColor, d, red), d, 1e-6);
}

#[test]
fn dissolve_pattern_is_fixed_and_covers_by_alpha() {
    let mut on = 0;
    for y in 0..64 {
        for x in 0..64 {
            if bm::dissolve_threshold(x, y) < 0.3 {
                on += 1;
            }
        }
    }
    assert!((f64::from(on) / 4096.0 - 0.3).abs() < 0.03);
    let s = Float4::new(0.2, 0.3, 0.4, 1.0);
    let d = Float4::new(0.5, 0.5, 0.5, 1.0);
    assert!(close4(bm::blend(BlendMode::Dissolve, s, d, 3, 4), s, 1e-6));
}

#[test]
fn over_a_transparent_backdrop_the_source_is_untouched() {
    let s = Float4::new(0.25, 0.1, 0.05, 0.5);
    for m in BlendMode::ALL {
        if m != BlendMode::Dissolve {
            assert!(close4(bm::blend(m, s, Float4::ZERO, 0, 0), s, 1e-6), "{m:?}");
        }
    }
}

#[test]
fn shader_ids_are_distinct_and_the_stencil_keeps_the_destination() {
    let mut ids: Vec<u32> = BlendMode::ALL.iter().map(|m| bm::shader_id(*m)).collect();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), BlendMode::ALL.len());
    assert!(ids.iter().all(|i| *i < bm::STENCIL_SHADER_ID));
    let d = Float4::new(0.2, 0.4, 0.6, 1.0);
    assert_eq!(bm::stencil(Float4::new(0.0, 0.0, 0.0, 0.5), d, 1.0), d * 0.5);
}

// MARK: ultra key

fn green() -> ChromaKey {
    ChromaKey::new(120.0, 36.0, 13.0, 0.5, 0.0, 0.0)
}

#[test]
fn green_is_keyed_out_and_others_stay() {
    let k = [green()];
    assert!(ultra_key::apply(Float3::new(0.05, 0.6, 0.05), 1.0, &k).1 < 0.01);
    let red = ultra_key::apply(Float3::new(0.7, 0.1, 0.1), 1.0, &k);
    assert!(red.1 == 1.0 && red.0 == Float3::new(0.7, 0.1, 0.1));
    assert_eq!(ultra_key::apply(Float3::splat(0.4), 1.0, &k).1, 1.0); // no saturation: nothing to key
    assert_eq!(ultra_key::apply(Float3::ZERO, 1.0, &k).1, 1.0);
}

#[test]
fn matte_output_shows_kept_share_as_grey_and_keeps_coverage() {
    let mut k = green();
    k.output = sq_core_effects::effects_evaluation::ChromaKeyOutput::Alpha;
    let keyed = ultra_key::apply(Float3::new(0.05, 0.6, 0.05), 1.0, &[k]);
    assert!(keyed.0.x < 0.01 && keyed.0.x == keyed.0.y && keyed.0.y == keyed.0.z);
    assert_eq!(keyed.1, 1.0);
    let kept = ultra_key::apply(Float3::new(0.7, 0.1, 0.1), 0.5, &[k]);
    assert!(kept.0 == Float3::splat(1.0) && kept.1 == 0.5);
    assert!(ultra_key::apply(Float3::new(0.05, 0.6, 0.05), 1.0, &[green()]).1 < 0.01);
}

#[test]
fn soft_edge_falls_off_with_hue_distance() {
    // Hue 120 +- 36 is fully keyed, then 13 degrees of ramp.
    let alpha = |h: f32| {
        let c = h / 60.0;
        let x = 1.0 - ((c % 2.0) - 1.0).abs();
        let (r, g, b) = if c < 1.0 {
            (1.0, x, 0.0)
        } else if c < 2.0 {
            (x, 1.0, 0.0)
        } else if c < 3.0 {
            (0.0, 1.0, x)
        } else if c < 4.0 {
            (0.0, x, 1.0)
        } else if c < 5.0 {
            (x, 0.0, 1.0)
        } else {
            (1.0, 0.0, x)
        };
        let m = 0.2f32;
        let rgb = Float3::new(r * 0.8 + m * 0.5, g * 0.8 + m * 0.5, b * 0.8 + m * 0.5) * 0.5;
        ultra_key::apply(rgb, 1.0, &[green()]).1
    };
    assert!(alpha(120.0) < 0.01);
    assert!(alpha(150.0) < 0.01); // inside the tolerance
    let edge = alpha(162.0);
    assert!(edge > 0.05 && edge < 0.95); // on the soft edge
    assert!(alpha(220.0) > 0.99); // blue stays
}

#[test]
fn spill_is_desaturated_near_the_key_hue() {
    let c = Float3::new(0.5, 0.45, 0.1); // hue ~ 51 degrees, outside tolerance + soft but inside the spill zone
    let k = ChromaKey::new(120.0, 20.0, 10.0, 1.0, 0.0, 0.0);
    let r = ultra_key::apply(c, 1.0, &[k]);
    assert_eq!(r.1, 1.0);
    assert!(ultra_key::hsv(r.0).1 < ultra_key::hsv(c).1);
}

#[test]
fn two_keys_compose() {
    let blue = ChromaKey::new(220.0, 36.0, 13.0, 0.0, 0.0, 0.0);
    let both = ultra_key::apply(Float3::new(0.05, 0.05, 0.7), 1.0, &[green(), blue]);
    assert!(both.1 < 0.01);
}

#[test]
fn choke_and_pedestal_shape_the_matte() {
    let edge = Float3::new(0.1, 0.5, 0.367); // hue 160: soft edge beyond the tolerance
    let alpha = |k: ChromaKey| ultra_key::apply(edge, 1.0, &[k]).1;
    let plain = alpha(green());
    assert!(plain > 0.05 && plain < 0.95);
    let mut choked = green();
    choked.choke = 0.6;
    assert!(alpha(choked) < plain); // choke shrinks the kept picture
    let mut lifted = green();
    lifted.pedestal = 0.6;
    assert!(alpha(lifted) > plain); // pedestal drops weak keying
    assert!(ultra_key::apply(Float3::new(0.05, 0.6, 0.05), 1.0, &[lifted]).1 < 0.45);
    assert_eq!(ultra_key::apply(Float3::new(0.7, 0.1, 0.1), 1.0, &[choked, lifted]).1, 1.0);
}

#[test]
fn choke_and_pedestal_defaults_are_identity() {
    let c = Float3::new(0.1, 0.5, 0.45);
    let a = ultra_key::apply(c, 1.0, &[green()]).1;
    let mut z = green();
    z.choke = 0.0;
    z.pedestal = 0.0;
    assert_eq!(ultra_key::apply(c, 1.0, &[z]).1, a);
}

// MARK: Sharpen, Unsharp Mask

#[test]
fn sharpen_flat_area_is_untouched_and_an_edge_overshoots() {
    let flat = solid(8, 8, Float4::new(0.3, 0.3, 0.3, 1.0));
    assert!((at(&imf::sharpen(&flat, 2.0, None), 4, 4).x - 0.3).abs() < 1e-6);
    // 0.2 | 0.6 step: the last dark pixel's 3 x 3 mean is (6 * 0.2 + 3 * 0.6) / 9 = 1/3, so it goes to 0.2 - 2/15.
    let step =
        Image::from_fn(
            8,
            8,
            |x, _| if x < 4 { Float4::new(0.2, 0.2, 0.2, 1.0) } else { Float4::new(0.6, 0.6, 0.6, 1.0) },
        );
    let out = imf::sharpen(&step, 1.0, None);
    assert!((at(&out, 3, 4).x - (0.2 - 2.0 / 15.0)).abs() < 1e-5);
    assert!((at(&out, 4, 4).x - (0.6 + 2.0 / 15.0)).abs() < 1e-5);
    assert_eq!(at(&out, 3, 4).w, 1.0);
}

fn edge_image() -> Image {
    Image::from_fn(
        24,
        24,
        |x, _| if x < 12 { Float4::new(0.2, 0.2, 0.2, 1.0) } else { Float4::new(0.6, 0.6, 0.6, 1.0) },
    )
}

#[test]
fn unsharp_mask_amount_zero_threshold_and_overshoot() {
    let edge = edge_image();
    assert_eq!(imf::unsharp_mask(&edge, 1.5, 0.0, 0.0, None), edge);
    let out = imf::unsharp_mask(&edge, 1.5, 1.0, 0.0, None);
    assert!(at(&out, 11, 5).x < 0.2 - 0.01 && at(&out, 12, 5).x > 0.6 + 0.01);
    assert!((at(&out, 2, 5).x - 0.2).abs() < 1e-4 && (at(&out, 21, 5).x - 0.6).abs() < 1e-4);
    assert_eq!(at(&out, 0, 0).w, 1.0);
    // The edge step is 0.4; a threshold above the largest local difference leaves the picture untouched.
    assert_eq!(imf::unsharp_mask(&edge, 1.5, 1.0, 0.4, None), edge);
    assert!(at(&imf::unsharp_mask(&edge, 1.5, 1.0, 0.1, None), 11, 5).x < 0.2 - 0.01);
}

// MARK: Directional Blur, Mirror

fn column() -> Image {
    Image::from_fn(21, 21, |x, _| if x == 10 { Float4::splat(1.0) } else { Float4::ZERO })
}

#[test]
fn directional_blur_smears_along_its_direction_only() {
    let v = imf::directional_blur(&column(), Float2::new(0.0, 8.0));
    assert!((at(&v, 10, 10).x - 1.0).abs() < 1e-5 && at(&v, 9, 10).x < 1e-6 && at(&v, 11, 10).x < 1e-6);
    let h = imf::directional_blur(&column(), Float2::new(8.0, 0.0));
    let row: Vec<f32> = (0..21).map(|x| at(&h, x, 10).x).collect();
    assert!((row.iter().sum::<f32>() - 1.0).abs() < 0.02);
    assert!(row[10] > 0.0 && row[13] > 0.0 && row[7] > 0.0); // reaches 4 px either side
    assert!(row[15] == 0.0 && row[5] == 0.0); // and no further
}

#[test]
fn long_smears_run_as_two_passes_short_ones_as_one() {
    for len in [90.0f32, 140.0, 70.0, 120.0] {
        assert!(imf::smear_passes(imf::smear_taps(Float2::new(len, 0.0))).is_some(), "{len}");
    }
    assert_eq!(imf::smear_passes(imf::smear_taps(Float2::new(10.0, 0.0))), None);
    for len in 33..600 {
        let n = imf::smear_taps(Float2::new(len as f32, 0.0));
        assert!((2..=512 + 24).contains(&n));
    }
}

#[test]
fn mirror_reflects_the_line_s_far_side() {
    let img = image(32, 32, ramp);
    let out = imf::mirror(&img, Float2::new(16.0, 16.0), 0.0);
    for x in 16..32 {
        assert_eq!(at(&out, x, 5), at(&img, 31 - x, 5));
    }
    for x in 0..16 {
        assert_eq!(at(&out, x, 5), at(&img, x, 5));
    }
    let out = imf::mirror(&img, Float2::new(16.0, 16.0), 90.0);
    for y in 16..32 {
        assert_eq!(at(&out, 3, y), at(&img, 3, 31 - y));
    }
}

// MARK: Noise

#[test]
fn noise_mean_strength_channels_clip_and_seed() {
    let flat = solid(64, 64, Float4::new(0.4, 0.4, 0.4, 1.0));
    let out = imf::noise(&flat, 0.5, true, true, 7);
    let v: Vec<f32> = out.px.iter().map(|p| p.x).collect();
    let mean = v.iter().sum::<f32>() / v.len() as f32;
    let sd = (v.iter().map(|x| (x - mean) * (x - mean)).sum::<f32>() / v.len() as f32).sqrt();
    assert!((mean - 0.4).abs() < 0.01);
    assert!((sd - 0.5 / 12.0f32.sqrt()).abs() < 0.01); // uniform on +-0.25
    let mono = imf::noise(&flat, 0.5, false, true, 3);
    assert!(mono.px.iter().all(|p| p.x == p.y && p.y == p.z));
    assert!(imf::noise(&flat, 0.5, true, true, 3).px.iter().any(|p| p.x != p.y));
    let bright = solid(32, 32, Float4::new(0.95, 0.95, 0.95, 1.0));
    assert!(imf::noise(&bright, 1.0, true, true, 1).px.iter().all(|p| p.x <= 1.0 && p.x >= 0.0));
    assert!(imf::noise(&bright, 1.0, true, false, 1).px.iter().any(|p| p.x > 1.0));
    // Clip Result keeps 0...max(1, input): an HDR highlight at 3 is not cut to 1.
    let hdr = solid(32, 32, Float4::new(3.0, 3.0, 3.0, 1.0));
    let o: Vec<f32> = imf::noise(&hdr, 1.0, true, true, 5).px.iter().map(|p| p.x).collect();
    assert!(o.iter().all(|x| *x <= 3.0 && *x >= 2.5) && o.iter().any(|x| *x < 2.9));
    assert_ne!(imf::noise(&flat, 0.5, true, true, 1), imf::noise(&flat, 0.5, true, true, 2));
}

// MARK: Glow, Mosaic

#[test]
fn glow_spills_light_and_tint_colours_the_halo() {
    let img = image(32, 32, |x, y| if (14..18).contains(&x) && (14..18).contains(&y) { lum(255) } else { lum(40) });
    let out = imf::glow(&img, 0.6, 2.0, 1.0, None);
    assert_eq!(at(&out, 2, 2), at(&img, 2, 2)); // below threshold, nothing bright nearby
    assert!(at(&out, 13, 16).x > at(&img, 13, 16).x + 0.05);
    assert!(at(&out, 16, 16).x > 1.0); // the spot itself brightens (HDR)
    let red = imf::glow(&img, 0.6, 2.0, 1.0, Some(Float3::new(1.0, 0.0, 0.0)));
    assert!(at(&red, 12, 16).x > at(&img, 12, 16).x + 0.02);
    assert!((at(&red, 12, 16).y - at(&img, 12, 16).y).abs() < 1e-6); // red glow adds nothing to green
}

#[test]
fn mosaic_blocks_are_averages_centres_or_identity() {
    let frame = Frame { center: Float2::new(16.0, 16.0), size: Float2::new(32.0, 32.0) };
    let ramp_x = Image::from_fn(32, 32, |x, _| Float4::new(x as f32 / 31.0, 0.0, 0.0, 1.0));
    let out = imf::mosaic(&ramp_x, &frame, 4, 2, false);
    assert!((at(&out, 0, 0).x - 3.5 / 31.0).abs() < 1e-5);
    assert_eq!(at(&out, 7, 31), at(&out, 0, 0));
    assert!((at(&out, 8, 0).x - 11.5 / 31.0).abs() < 1e-5);
    // One block over 128 x 128 with a single bright column: the average is exactly 1/128 of it.
    let big_src = image(128, 128, |x, _| if x == 1 { lum(255) } else { lum(0) });
    let big = Frame { center: Float2::new(64.0, 64.0), size: Float2::new(128.0, 128.0) };
    assert!((at(&imf::mosaic(&big_src, &big, 1, 1, false), 50, 50).x - 1.0 / 128.0).abs() < 1e-6);
    // Sharp colors take the center pixel: block 0...8 -> x = 4.
    assert_eq!(at(&imf::mosaic(&ramp_x, &frame, 4, 1, true), 0, 10).x, 4.0 / 31.0);
    let quad = image(32, 32, |x, y| {
        if x < 16 {
            if y < 16 { lum(10) } else { lum(200) }
        } else if y < 16 {
            (0, 0, 255, 255)
        } else {
            (255, 0, 0, 255)
        }
    });
    let same = imf::mosaic(&quad, &frame, 2, 2, false);
    assert!(same.px.iter().zip(&quad.px).all(|(a, b)| (*a - *b).abs().max_element() < 1e-6));
}

// MARK: style filters, colour

#[test]
fn invert_posterize_tint_brightness() {
    let black = image(4, 4, |_, _| lum(0));
    let inv = |c, b| at(&refer(&ImageFilter::Invert { channel: c, blend: b }, &black), 1, 1);
    assert!((inv(0, 0.0).x - 1.0).abs() < 1e-5);
    assert!(inv(0, 1.0).x.abs() < 1e-6);
    assert!((inv(1, 0.0).x - 1.0).abs() < 1e-5 && inv(1, 0.0).y < 1e-6);
    assert!(inv(4, 0.0).w < 1e-6);
    let img = image(16, 16, ramp);
    let post = refer(&ImageFilter::Posterize { levels: 2 }, &img);
    assert!(post.px.iter().all(|p| (0..3).all(|c| p[c].abs() < 1e-5 || (p[c] - 1.0).abs() < 1e-5)));
    let bw = refer(&ImageFilter::Tint { black: [0.0; 3], white: [1.0; 3], amount: 1.0 }, &img);
    assert!(bw.px.iter().all(|p| (p.x - p.y).abs() < 1e-5 && (p.y - p.z).abs() < 1e-5));
    let duo = refer(&ImageFilter::Tint { black: [1.0, 0.0, 0.0], white: [1.0, 0.0, 0.0], amount: 1.0 }, &img);
    assert!(duo.px.iter().all(|p| (p.x - 1.0).abs() < 1e-5 && p.y < 1e-6));
    let flat = refer(&ImageFilter::BrightnessContrast { brightness: 0.0, contrast: -1.0 }, &img);
    assert!(flat.px.iter().all(|p| (p.x - dec(0.5)).abs() < 0.02));
    let lifted = refer(&ImageFilter::BrightnessContrast { brightness: 0.5, contrast: 0.0 }, &img);
    assert!(lifted.px.iter().zip(&img.px).all(|(a, b)| a.y >= b.y));
}

#[test]
fn vignette_darkens_corners_not_the_centre() {
    let img = image(64, 64, |_, _| lum(180));
    let v = |amount, roundness| ImageFilter::Vignette { amount, midpoint: 0.5, roundness, feather: 0.5 };
    let dark = refer(&v(-2.0, 0.0), &img);
    assert!((at(&dark, 32, 32).x - at(&img, 32, 32).x).abs() < 1e-4);
    assert!(at(&dark, 0, 0).x < at(&img, 0, 0).x * 0.4);
    let light = refer(&v(2.0, 0.0), &img);
    assert!(at(&light, 0, 0).x > at(&img, 0, 0).x + 0.1);
    assert!((at(&light, 32, 32).x - at(&img, 32, 32).x).abs() < 1e-4);
    // Roundness: a circle on a wide frame reaches the side edges later than the ellipse.
    let wide = image(128, 32, |_, _| lum(180));
    let w = |roundness| ImageFilter::Vignette { amount: -2.0, midpoint: 0.5, roundness, feather: 0.2 };
    assert!(at(&refer(&w(1.0), &wide), 16, 16).x < at(&refer(&w(0.0), &wide), 16, 16).x);
}

#[test]
fn strobe_and_alpha_adjust() {
    let img = image(8, 8, ramp);
    let flash = refer(&ImageFilter::Strobe { color: [1.0; 3], blend: 0.0, op: 0, transparent: false }, &img);
    assert!(flash.px.iter().all(|p| (p.x - 1.0).abs() < 1e-5 && (p.z - 1.0).abs() < 1e-5));
    let gone = refer(&ImageFilter::Strobe { color: [1.0; 3], blend: 0.0, op: 0, transparent: true }, &img);
    assert!(gone.px.iter().all(|p| *p == Float4::ZERO));
    let red = image(8, 8, |_, _| (0, 0, 255, 255));
    let inv = refer(&ImageFilter::AlphaAdjust { opacity: 1.0, ignore: false, invert: true, mask_only: false }, &red);
    assert!(inv.px.iter().all(|p| p.w == 0.0));
    let half = refer(&ImageFilter::AlphaAdjust { opacity: 0.5, ignore: false, invert: false, mask_only: true }, &red);
    assert!(half.px.iter().all(|p| (p.w - 0.5).abs() < 1e-6 && (p.y - 0.5).abs() < 1e-6));
}

// MARK: style filters, geometry

#[test]
fn flips_mirror_the_picture() {
    let img = image(32, 16, ramp);
    let h = refer(&ImageFilter::Flip { horizontal: true, vertical: false }, &img);
    for x in 0..32 {
        assert!(close4(at(&h, x, 3), at(&img, 31 - x, 3), 1e-5));
    }
    let v = refer(&ImageFilter::Flip { horizontal: false, vertical: true }, &img);
    for y in 0..16 {
        assert!(close4(at(&v, 5, y), at(&img, 5, 15 - y), 1e-5));
    }
}

#[test]
fn rgb_split_moves_red_one_way_and_blue_the_other() {
    let img = Image::from_fn(32, 8, |x, _| if x == 16 { Float4::splat(1.0) } else { Float4::new(0.0, 0.0, 0.0, 1.0) });
    let out = refer(&ImageFilter::RgbSplit { dx: 4.0, dy: 0.0, radial: false, mix: 0.0 }, &img);
    assert!((at(&out, 20, 4).x - 1.0).abs() < 1e-5 && at(&out, 20, 4).z < 1e-6);
    assert!((at(&out, 12, 4).z - 1.0).abs() < 1e-5 && at(&out, 12, 4).x < 1e-6);
    assert!((at(&out, 16, 4).y - 1.0).abs() < 1e-5 && at(&out, 16, 4).x < 1e-6);
}

#[test]
fn radial_blur_spin_and_zoom() {
    let img = Image::from_fn(33, 33, |_, y| if y == 16 { Float4::splat(1.0) } else { Float4::new(0.0, 0.0, 0.0, 1.0) });
    let c = Vec2::ZERO;
    let zoom = refer(&ImageFilter::RadialBlur { center: c, amount: 30.0, zoom: true, high: true }, &img);
    assert!(at(&zoom, 28, 16).x > 0.9);
    let spin = refer(&ImageFilter::RadialBlur { center: c, amount: 30.0, zoom: false, high: true }, &img);
    assert!(at(&spin, 28, 16).x < 0.5 && at(&spin, 28, 14).x > 0.01);
}

#[test]
fn twirl_and_spherize_leave_the_outside_alone() {
    let img = image(64, 64, ramp);
    let tw = refer(&ImageFilter::Twirl { center: Vec2::ZERO, angle: 90.0, radius: 0.25 }, &img);
    assert!((at(&tw, 2, 2) - at(&img, 2, 2)).abs().max_element() < 1e-6);
    assert!((at(&tw, 40, 32) - at(&img, 40, 32)).abs().max_element() > 1e-3);
    let sp = refer(&ImageFilter::Spherize { center: Vec2::ZERO, radius: 16.0, strength: 1.0 }, &img);
    assert!((at(&sp, 2, 2) - at(&img, 2, 2)).abs().max_element() < 1e-6);
    assert!((at(&sp, 40, 32) - at(&img, 40, 32)).abs().max_element() > 1e-3);
}

#[test]
fn wave_warp_moves_across_its_direction_and_pins_edges() {
    let img = Image::from_fn(64, 32, |_, y| if y == 16 { Float4::splat(1.0) } else { Float4::new(0.0, 0.0, 0.0, 1.0) });
    let w = |pinning| ImageFilter::WaveWarp {
        wave_type: 1,
        height: 4.0,
        width: 32.0,
        direction: 90.0,
        phase: 0.0,
        pinning,
    };
    let out = refer(&w(0), &img);
    assert!(at(&out, 8, 20).x > 0.9 || at(&out, 8, 12).x > 0.9);
    assert!(at(&out, 8, 16).x < 0.1);
    assert!(at(&refer(&w(1), &img), 0, 16).x > 0.9); // left edge held
}

#[test]
fn lens_distortion_keeps_the_centre_and_fills_bulged_corners() {
    let img = image(64, 64, ramp);
    let lens = |curvature, fill_alpha, fill| ImageFilter::LensDistortion {
        curvature,
        decenter: Vec2::ZERO,
        fill_alpha,
        fill,
        auto_scale: false,
        exact_model: false,
    };
    let bulge = refer(&lens(-0.8, true, [0.0; 3]), &img);
    assert!((at(&bulge, 32, 32) - at(&img, 32, 32)).abs().max_element() < 0.05);
    assert_eq!(at(&bulge, 0, 0).w, 0.0); // corner reads outside the picture: transparent
    let filled = refer(&lens(-0.8, false, [1.0, 0.0, 0.0]), &img);
    assert_eq!(at(&filled, 0, 0), Float4::new(1.0, 0.0, 0.0, 1.0));
    let pinch = refer(&lens(0.8, false, [1.0, 0.0, 0.0]), &img);
    assert_eq!(at(&pinch, 0, 0).w, 1.0); // pincushion only reads inside: no fill
    assert_ne!(at(&pinch, 0, 0), Float4::new(1.0, 0.0, 0.0, 1.0));
}

#[test]
fn lens_exact_model_pincushion_inverts_the_barrel() {
    let frame = Frame { center: Float2::new(32.0, 32.0), size: Float2::new(64.0, 64.0) };
    let lens = |k: f64| ImageFilter::LensDistortion {
        curvature: k,
        decenter: Vec2::ZERO,
        fill_alpha: true,
        fill: [0.0; 3],
        auto_scale: false,
        exact_model: true,
    };
    // Reading through the barrel (k > 0) and then through the exact pincushion of the same strength lands on the start.
    let (_, barrel) = sf::plan(&lens(-0.5), &frame, 1.0).expect("lens");
    let (_, pin) = sf::plan(&lens(0.5), &frame, 1.0).expect("lens");
    assert!(barrel.a.x > 0.0 && pin.a.x < 0.0);
    for p in [Float2::new(40.0, 36.0), Float2::new(50.0, 20.0), Float2::new(10.0, 55.0)] {
        let back = sf::lens_source(sf::lens_source(p, &pin), &barrel);
        assert!((back - p).length() < 1e-3, "{p:?} -> {back:?}");
    }
}

#[test]
fn lens_auto_scale_leaves_no_empty_edge() {
    let frame = Frame { center: Float2::new(32.0, 32.0), size: Float2::new(64.0, 64.0) };
    for k in [-0.8f64, 0.6] {
        let f = ImageFilter::LensDistortion {
            curvature: k,
            decenter: Vec2::ZERO,
            fill_alpha: true,
            fill: [0.0; 3],
            auto_scale: true,
            exact_model: true,
        };
        let (_, u) = sf::plan(&f, &frame, 1.0).expect("lens");
        for t in 0..=16 {
            let t = t as f32 / 16.0 * 64.0;
            for p in [Float2::new(t, 0.0), Float2::new(t, 64.0), Float2::new(0.0, t), Float2::new(64.0, t)] {
                assert!(in_picture(sf::lens_source(p, &u), &u), "k {k} {p:?}");
            }
        }
    }
}

#[test]
fn hard_alpha_edge_never_gives_more_colour_than_coverage() {
    for c in [
        Float4::new(0.9, 0.9, 0.9, 1.4),
        Float4::new(0.5, 0.2, 0.1, 1.0),
        Float4::new(0.5, 0.2, 0.1, -0.2),
        Float4::new(-0.1, 0.3, 0.2, 0.6),
    ] {
        let o = sf::premultiplied_held(c);
        assert!(o.x >= 0.0 && o.x <= o.w.max(c.x.max(0.0) * if c.w > 1.0 { 1.0 / c.w } else { 1.0 }) + 1e-6);
        assert!(o.w >= 0.0 && o.w <= 1.0);
    }
    assert_eq!(sf::premultiplied_held(Float4::new(0.5, 0.5, 0.5, 0.0)), Float4::ZERO);
}

#[test]
fn light_leak_brightens_near_its_centre_only() {
    let img = image(64, 64, |_, _| lum(80));
    let f = ImageFilter::LightLeak {
        color1: [1.0, 0.5, 0.1],
        color2: [1.0, 0.5, 0.1],
        intensity: 1.0,
        center: Vec2::new(1.0, 0.0),
        size: 0.3,
        angle: 0.0,
    };
    let out = refer(&f, &img);
    assert!(at(&out, 63, 32).x > at(&img, 63, 32).x + 0.1);
    assert!(at(&out, 63, 32).x > at(&out, 63, 32).z); // warm
    assert!((at(&out, 0, 32) - at(&img, 0, 32)).abs().max_element() < 0.01);
}

#[test]
fn halftone_dots_grow_with_shadows() {
    let ht = |softness, color, blend| ImageFilter::Halftone { size: 8.0, angle: 0.0, softness, color, blend };
    let mean = |i: &Image| i.px.iter().map(|p| p.x).sum::<f32>() / i.px.len() as f32;
    let dark = refer(&ht(0.0, false, 1.0), &image(64, 64, |_, _| lum(40)));
    let bright = refer(&ht(0.0, false, 1.0), &image(64, 64, |_, _| lum(220)));
    assert!(mean(&dark) < mean(&bright));
    assert!(mean(&refer(&ht(0.0, false, 1.0), &image(64, 64, |_, _| lum(0)))) < 0.05);
    assert!(mean(&refer(&ht(0.0, false, 1.0), &image(64, 64, |_, _| lum(255)))) > 0.95);
    let img = image(32, 32, |_, _| (200, 80, 40, 255));
    assert_eq!(at(&refer(&ht(0.2, false, 0.0), &img), 3, 3), at(&img, 3, 3));
    assert!(refer(&ht(0.2, true, 1.0), &img).px.iter().any(|p| p.z > p.x * 2.0));
}

#[test]
fn tile_repeats_and_mirrors_alternate_tiles() {
    let img = image(64, 64, ramp);
    let tile = |columns, mirror| ImageFilter::Tile { columns, rows: 1.0, offset: Vec2::ZERO, mirror };
    let t = refer(&tile(2.0, false), &img);
    assert!(close4(at(&t, 8, 20), at(&img, 16, 20), 0.05) && close4(at(&t, 40, 20), at(&img, 16, 20), 0.05));
    let m = refer(&tile(2.0, true), &img);
    assert!(close4(at(&m, 8, 20), at(&img, 16, 20), 0.05));
    assert!(close4(at(&m, 55, 20), at(&img, 16, 20), 0.1)); // second tile runs backwards
    assert!(close4(at(&refer(&tile(1.0, false), &img), 10, 10), at(&img, 10, 10), 0.02));
}

#[test]
fn kaleidoscope_is_mirror_symmetric_across_its_slice_edge() {
    let img = image(64, 64, ramp);
    let k = refer(&ImageFilter::Kaleidoscope { center: Vec2::ZERO, segments: 4, angle: 0.0, zoom: 1.0 }, &img);
    for (x, y) in [(10, 20), (45, 12), (5, 50)] {
        assert!(close4(at(&k, x, y), at(&k, 63 - x, y), 0.1));
        assert!(close4(at(&k, x, y), at(&k, x, 63 - y), 0.1));
    }
}

#[test]
fn edge_feather_fades_the_alpha_towards_the_frame_edge() {
    let img = image(64, 64, |_, _| lum(80));
    let f = refer(&ImageFilter::EdgeFeather { amount: 16.0 }, &img);
    for (x, y) in [(0i64, 32i64), (4, 32), (8, 32), (31, 0), (31, 6)] {
        let d = (x.min(63 - x).min(y.min(63 - y)) as f32) + 0.5;
        let t = (d / 16.0).clamp(0.0, 1.0);
        let want = t * t * (3.0 - 2.0 * t);
        assert!((at(&f, x, y).w - want).abs() < 1e-5, "({x}, {y})");
        assert!((at(&f, x, y).x - at(&img, x, y).x * want).abs() < 1e-5);
    }
    assert_eq!(at(&f, 32, 32), at(&img, 32, 32));
    assert_eq!(at(&refer(&ImageFilter::EdgeFeather { amount: 0.0 }, &img), 0, 0), at(&img, 0, 0));
}

#[test]
fn glitch_displace_shifts_whole_bands_and_splits_colour() {
    let img = image(64, 64, |x, _| lum((x * 3) as u8));
    let g = |split, density, seed| ImageFilter::Glitch { amount: 10.0, block: 8.0, split, density, seed };
    let still = refer(&g(0.0, 0.0, 3), &img);
    assert!((at(&still, 20, 20) - at(&img, 20, 20)).abs().max_element() < 1e-6);
    let a = refer(&g(0.0, 1.0, 3), &img);
    assert_eq!(at(&a, 30, 12), at(&refer(&g(0.0, 1.0, 3), &img), 30, 12));
    assert_eq!(at(&a, 30, 8), at(&a, 30, 15)); // same band (rows 8..<16)
    let moved = (0..8).filter(|b| (at(&a, 30, b * 8) - at(&img, 30, b * 8)).abs().max_element() > 0.001).count();
    assert!(moved >= 6);
    let c = refer(&g(0.0, 1.0, 4), &img);
    assert!((0..8).any(|b| (at(&a, 30, b * 8) - at(&c, 30, b * 8)).abs().max_element() > 0.001));
    let sp = refer(&ImageFilter::Glitch { amount: 0.0, block: 8.0, split: 4.0, density: 0.0, seed: 1 }, &img);
    assert!(at(&sp, 30, 30).x < at(&img, 30, 30).x && at(&sp, 30, 30).z > at(&img, 30, 30).z);
}

#[test]
fn gradient_has_known_pixel_values() {
    let img = image(64, 64, |_, _| lum(80));
    let grad = |c1: [f64; 3], c2: [f64; 3], start: Vec2, end: Vec2, radial, blend| ImageFilter::Gradient {
        color1: c1,
        color2: c2,
        start,
        end,
        radial,
        blend,
    };
    // Linear black -> white from the top edge to the bottom edge: row r center is at r + 0.5, t = (r + 0.5) / 64.
    let lin = refer(&grad([0.0; 3], [1.0; 3], Vec2::new(0.0, -32.0), Vec2::new(0.0, 32.0), false, 1.0), &img);
    for r in [0i64, 16, 32, 63] {
        let t = (r as f32 + 0.5) / 64.0;
        assert!((at(&lin, 10, r).x - dec(t)).abs() < 0.002, "row {r}");
        assert!((at(&lin, 10, r).x - at(&lin, 50, r).x).abs() < 1e-6);
    }
    let half =
        refer(&grad([1.0, 0.0, 0.0], [1.0, 0.0, 0.0], Vec2::new(0.0, -32.0), Vec2::new(0.0, 32.0), false, 0.5), &img);
    let e = enc(at(&img, 5, 5).x);
    assert!((at(&half, 5, 5).x - dec(e + (1.0 - e) * 0.5)).abs() < 0.002);
    assert!((at(&half, 5, 5).y - dec(e * 0.5)).abs() < 0.002 && at(&half, 5, 5).w == 1.0);
    let rad = refer(&grad([1.0; 3], [0.0; 3], Vec2::ZERO, Vec2::new(0.0, 16.0), true, 1.0), &img);
    assert!((at(&rad, 32, 32).x - dec(1.0 - 0.5 * 2.0f32.sqrt() / 16.0)).abs() < 0.002);
    assert!(at(&rad, 0, 0).x < 0.001 && at(&rad, 63, 63).x < 0.001);
    let flat = refer(&grad([1.0; 3], [0.0; 3], Vec2::ZERO, Vec2::ZERO, false, 1.0), &img);
    assert!(at(&flat, 3, 3).x > 0.99);
}

#[test]
fn corner_pin_keeps_a_picture_in_place_shrinks_and_empties() {
    let img = image(64, 64, ramp);
    let pin =
        |tl, tr, br, bl| ImageFilter::CornerPin { top_left: tl, top_right: tr, bottom_right: br, bottom_left: bl };
    let z = Vec2::ZERO;
    let same = refer(&pin(z, z, z, z), &img);
    assert!(close4(at(&same, 20, 20), at(&img, 20, 20), 0.02));
    let shrunk = refer(
        &pin(Vec2::new(16.0, 16.0), Vec2::new(-16.0, 16.0), Vec2::new(-16.0, -16.0), Vec2::new(16.0, -16.0)),
        &img,
    );
    assert_eq!(at(&shrunk, 2, 2).w, 0.0);
    assert!(at(&shrunk, 32, 32).w > 0.99);
    let collapsed = refer(
        &pin(Vec2::new(32.0, 32.0), Vec2::new(-32.0, 32.0), Vec2::new(-32.0, -32.0), Vec2::new(32.0, -32.0)),
        &img,
    );
    assert!(collapsed.px.iter().all(|p| p.w == 0.0));
}

// MARK: Rolling Shutter

#[test]
fn rolling_shutter_holds_edges_and_passes_the_margin_through() {
    // A frame of 32 x 32 centered in a 48 x 48 working image: the margin outside is not picture.
    let img = Image::from_fn(48, 48, |x, y| Float4::new(x as f32 / 48.0, y as f32 / 48.0, 0.5, 1.0));
    let frame = Frame { center: Float2::new(24.0, 24.0), size: Float2::new(32.0, 32.0) };
    let f = ImageFilter::RollingShutter { shear: Vec2::new(0.2, 0.0), along_x: false };
    let out = sf::reference(&f, &img, &frame, 1.0).expect("warp");
    assert_eq!(at(&out, 1, 1), at(&img, 1, 1)); // margin: passes through
    assert_eq!(at(&out, 46, 20), at(&img, 46, 20));
    // Inside the frame every read is held inside the frame.
    for y in 8..40 {
        for x in 8..40 {
            assert!(at(&out, x, y).w > 0.99, "({x}, {y})");
        }
    }
    // Zero shear is the identity.
    let still = sf::reference(&ImageFilter::RollingShutter { shear: Vec2::ZERO, along_x: true }, &img, &frame, 1.0)
        .expect("warp");
    for y in 8..40 {
        for x in 8..40 {
            assert!(close4(at(&still, x, y), at(&img, x, y), 1e-6));
        }
    }
}

#[test]
fn zero_perspective_is_bit_identical_to_the_rolling_shutter_pass() {
    let img = image(48, 48, ramp);
    let frame = Frame { center: Float2::new(24.0, 24.0), size: Float2::new(32.0, 32.0) };
    let plain = ImageFilter::RollingShutter { shear: Vec2::new(0.1, -0.05), along_x: true };
    let stab = ImageFilter::StabilizeWarp { shear: Vec2::new(0.1, -0.05), along_x: true, perspective: vec![0.0; 8] };
    assert_eq!(sf::reference(&plain, &img, &frame, 1.0), sf::reference(&stab, &img, &frame, 1.0));
}

#[test]
fn perspective_inverse_is_none_when_flat_or_singular_and_maps_back() {
    assert!(sf::perspective_inverse(&[0.0; 8], 1.0).is_none());
    assert!(sf::perspective_inverse(&[0.0; 7], 1.0).is_none());
    let v = [0.01, 0.002, 0.5, -0.3, 0.02, 0.4, 0.001, 0.0005];
    let m = sf::perspective_inverse(&v, 1.0).expect("invertible");
    // (I + v) applied to a point and then the inverse gives the point back (pf = 1).
    let p = (7.0f64, -4.0f64);
    let a = [1.0 + v[0], v[1], v[2], v[3], 1.0 + v[4], v[5], v[6], v[7], 1.0];
    let (x, y, w) = (a[0] * p.0 + a[1] * p.1 + a[2], a[3] * p.0 + a[4] * p.1 + a[5], a[6] * p.0 + a[7] * p.1 + 1.0);
    let (qx, qy) = (x / w, y / w);
    let d = m[6] * qx + m[7] * qy + 1.0;
    let (bx, by) = ((m[0] * qx + m[1] * qy + m[2]) / d, (m[3] * qx + m[4] * qy + m[5]) / d);
    assert!((bx - p.0).abs() < 1e-9 && (by - p.1).abs() < 1e-9);
}

#[test]
fn homography_maps_the_points_and_rejects_collapsed_ones() {
    let from = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
    let to = [[0.1, 0.2], [1.2, 0.0], [0.9, 1.1], [0.0, 0.8]];
    let h = sf::homography(&from, &to).expect("non-degenerate");
    for (f, t) in from.iter().zip(&to) {
        let w = h[6] * f[0] + h[7] * f[1] + 1.0;
        assert!(((h[0] * f[0] + h[1] * f[1] + h[2]) / w - t[0]).abs() < 1e-9);
        assert!(((h[3] * f[0] + h[4] * f[1] + h[5]) / w - t[1]).abs() < 1e-9);
    }
    assert!(sf::homography(&from, &[[0.0, 0.0]; 4]).is_none());
}
