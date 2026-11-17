//! Scope counts, the film look kernel, anti-flicker and the mask scope on the GPU. Scope counts are exact integers; the look
//! and anti-flicker kernels are compared with their CPU descriptions. Tests skip with a note when there is no GPU adapter.

use super::look_passes::{LookPasses, LookUniforms, anti_flicker_column, anti_flicker_weight};
use super::mask_data::{MaskInputs, MaskTextures, mask_entries, mask_scope};
use super::scope_passes::{ScopeLayout, ScopePasses, ScopePlanes, ScopeSelection};
use super::testing::{R, composite_block, download, gpu, upload, video_image, worst};
use crate::effects::image_filters::Image;
use crate::effects::simd::Float4;
use crate::effects::style_filters::enc;
use sq_core_color::{FilmLook, Scanlines};
use sq_core_masks::MaskShape;
use sq_core_time::Vec2;
use sq_gpu::layout::PixelFormat;

fn solid(w: usize, h: usize, v: f32) -> Image {
    Image::from_fn(w, h, |_, _| Float4::new(v, v, v, 1.0))
}

#[test]
fn scopes_count_every_pixel_of_a_flat_gray_picture() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h, v) = (64usize, 32usize, 0.18f32);
    let layout = ScopeLayout::default();
    let passes = ScopePasses::new(&gpu);
    let source = upload(&gpu, &solid(w, h, v));
    let counts_buffer = passes.make_counts(&layout);
    let planes = ScopePlanes::new(&gpu, &layout);
    let mut cmds = gpu.commands();
    passes.encode(&mut cmds, &source, &counts_buffer, &layout, Some(&planes), ScopeSelection::ALL, 1)?;
    gpu.submit_and_wait(cmds)?;
    let counts = passes.read(&counts_buffer, &layout)?;
    let n = (w * h) as u32;
    let bin = ((enc(v) * 256.0).floor() as usize).min(255);
    // Histogram: every channel has all pixels in the same bin.
    for channel in 0..4 {
        let row = &counts.histogram[channel * 256..(channel + 1) * 256];
        assert_eq!(row[bin], n, "channel {channel}");
        assert_eq!(row.iter().sum::<u32>(), n);
    }
    assert_eq!(counts.max_histogram, n);
    // Waveform: a column per source x (stride 8 columns), `h` pixels each, all at one level.
    assert_eq!(counts.waveform_luma.iter().sum::<u32>(), n);
    assert_eq!(counts.max_waveform_luma, h as u32);
    assert_eq!(counts.waveform_parade.iter().sum::<u32>(), 3 * n);
    // Vectorscope: gray lands in the center bin.
    assert_eq!(counts.vectorscope[128 * 256 + 128], n);
    assert_eq!(counts.max_vectorscope, n);
    // Resolved planes hold count / max.
    let plane = gpu.read_texture(&planes.vectorscope)?;
    let center = f32::from_le_bytes([
        plane[(128 * 256 + 128) * 4],
        plane[(128 * 256 + 128) * 4 + 1],
        plane[(128 * 256 + 128) * 4 + 2],
        plane[(128 * 256 + 128) * 4 + 3],
    ]);
    assert_eq!(center, 1.0);
    // Every second pixel in x and y: a quarter of the pixels.
    let strided = passes.measure(&source, &counts_buffer, &layout, ScopeSelection::HISTOGRAM, 2)?;
    assert_eq!(strided.histogram[3 * 256 + bin], n / 4);
    assert_eq!(strided.waveform_luma.iter().sum::<u32>(), 0, "unselected scopes stay empty");
    Ok(())
}

#[test]
fn an_empty_look_passes_the_picture_and_scanlines_darken_rows() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let img = video_image(32, 32, |x, y| ((x * 7) as u8, (y * 7) as u8, 128));
    let passes = LookPasses::new(&gpu);
    let src = upload(&gpu, &img);
    let run = |look: &FilmLook| -> Result<Image, Box<dyn std::error::Error>> {
        let out = gpu.texture(32, 32, PixelFormat::Rgba16Float);
        let mut cmds = gpu.commands();
        passes.film_look(&mut cmds, look, &src, &out)?;
        gpu.submit_and_wait(cmds)?;
        Ok(download(&gpu, &out)?)
    };
    let (w, _) = worst(&run(&FilmLook::default())?, &img);
    assert!(w < 0.002, "empty look changes the picture by {w}");
    let lines =
        FilmLook { scanlines: Some(Scanlines { intensity: 0.5, spacing: 4.0, thickness: 0.5 }), ..FilmLook::default() };
    let out = run(&lines)?;
    let sum = |i: &Image| i.px.iter().map(|p| p.x + p.y + p.z).sum::<f32>();
    assert!(sum(&out) < sum(&img) * 0.95, "scanlines darken: {} vs {}", sum(&out), sum(&img));
    assert!(out.px.iter().zip(&img.px).all(|(o, i)| o.x <= i.x + 0.002), "and never brighten");
    Ok(())
}

#[test]
fn look_uniforms_carry_each_effect_in_its_row() {
    let look = FilmLook {
        scanlines: Some(Scanlines { intensity: 0.5, spacing: 4.0, thickness: 0.25 }),
        ..FilmLook::default()
    };
    let u = LookUniforms::new(&look, 1920, 1080);
    assert_eq!(u.dims, [1920.0, 1080.0, 1.0, 0.0]);
    assert_eq!(u.ids, [8, 0, 0, 0]);
    assert_eq!(u.scan, [0.5, 4.0, 0.25, 0.0]);
    assert_eq!(LookUniforms::new(&look, 960, 540).dims[2], 0.5);
}

#[test]
fn anti_flicker_matches_the_column_reference() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let rows = 16usize;
    let column: Vec<f32> = (0..rows).map(|y| if y % 3 == 0 { 0.9 } else { 0.1 + 0.02 * y as f32 }).collect();
    let img = Image::from_fn(4, rows, |_, y| Float4::new(column[y], column[y] * 0.5, 0.25, 1.0));
    let passes = LookPasses::new(&gpu);
    for strength in [1.0, 0.4, 0.0] {
        let (src, out) = (upload(&gpu, &img), gpu.texture(4, rows as u32, PixelFormat::Rgba16Float));
        let mut cmds = gpu.commands();
        passes.anti_flicker(&mut cmds, &src, &out, strength)?;
        gpu.submit_and_wait(cmds)?;
        let got = download(&gpu, &out)?;
        let want = anti_flicker_column(&column, strength);
        for (y, w) in want.iter().enumerate() {
            assert!(
                (got.px[y * 4 + 1].x - w).abs() < 0.002,
                "strength {strength} row {y}: {} vs {w}",
                got.px[y * 4 + 1].x
            );
        }
    }
    assert_eq!(anti_flicker_weight(2.0), 0.25);
    assert_eq!(anti_flicker_column(&[0.0, 1.0, 0.0], 1.0), vec![0.25, 0.5, 0.25]);
    Ok(())
}

#[test]
fn mask_scope_takes_the_post_image_inside_the_mask_and_the_pre_image_outside() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (32usize, 32usize);
    let (pre, post) = (upload(&gpu, &solid(w, h, 0.2)), upload(&gpu, &solid(w, h, 0.8)));
    let square = MaskShape::new(vec![
        Vec2::new(0.25, 0.25),
        Vec2::new(0.75, 0.25),
        Vec2::new(0.75, 0.75),
        Vec2::new(0.25, 0.75),
    ]);
    let inputs = MaskInputs {
        frame: [w as f32, h as f32],
        edge_scale: 1.0,
        screen: None,
        picture_slot: &[None],
        matte_slot: &[None],
        has_matte: false,
    };
    let entries = mask_entries(&[square], &inputs);
    let bytes: Vec<u8> = entries.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
    let buffer = gpu.storage_buffer(256);
    gpu.queue().write_buffer(&buffer, 0, &bytes);
    let out = gpu.texture(w as u32, h as u32, PixelFormat::Rgba16Float);
    let mut cmds = gpu.commands();
    mask_scope(
        &gpu,
        &mut cmds,
        composite_block(w as u32, h as u32, 1).bytes(),
        &buffer,
        &MaskTextures::default(),
        &pre,
        &post,
        &out,
    )?;
    gpu.submit_and_wait(cmds)?;
    let got = download(&gpu, &out)?;
    assert!((got.px[16 * w + 16].x - 0.8).abs() < 0.01, "inside: {}", got.px[16 * w + 16].x);
    assert!((got.px[2 * w + 2].x - 0.2).abs() < 0.01, "outside: {}", got.px[2 * w + 2].x);
    Ok(())
}
