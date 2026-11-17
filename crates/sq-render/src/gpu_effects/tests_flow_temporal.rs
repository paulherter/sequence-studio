//! Optical flow against ground truth (a pattern moved by a known shift), the flow cache, and the temporal passes on flat and
//! noisy frames. Ported from the Swift OpticalFlowTests, TemporalRenderTests and TrailsRenderTests: those render through the
//! compositor, here the passes get the frames' planes directly. Tests skip with a note when there is no GPU adapter.

use super::effect_chain_plan::lin;
use super::kernels::Kernels;
use super::optical_flow_passes::{FlowPairKey, FlowQuality, FlowStore, OpticalFlowRequest};
use super::scratch::{Scratch, half};
use super::temporal_passes::{TemporalInput, TemporalPasses, neighbor_limits};
use super::testing::{R, composite_block, download, gpu};
use crate::effects::image_filters::Image;
use crate::effects::simd::Float4;
use crate::effects::style_filters::enc;
use sq_core_effects::temporal_effects::{
    TemporalDeflicker, TemporalDenoise, TemporalFilter, TemporalTrails, TrailBlend,
};
use sq_core_time::{Id, Time};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

// MARK: Optical flow

/// Smooth color texture (waves plus non-repeating blobs, one per 40 px cell at a hashed place, size and sign: like real detail,
/// a shift can not be mistaken for a period), encoded 0...1.
fn pattern(x: f64, y: f64) -> [f64; 3] {
    let v = 0.5
        + 0.12 * (x / 9.1 + 0.7 * (y / 23.0).sin()).sin()
        + 0.1 * (y / 7.3 + x / 31.0).sin()
        + 0.08 * ((x + y) / 13.7).sin();
    let w = 0.5 + 0.14 * (x / 11.3 - y / 17.9).sin() + 0.1 * (y / 8.7 + 0.5 * (x / 29.0).sin()).cos();
    let k = blobs(x, y);
    [v + k, w - 0.6 * k, 0.5 * v + 0.5 * w + 0.4 * k]
}

fn blobs(x: f64, y: f64) -> f64 {
    let cell = 40.0;
    let (cx, cy) = ((x / cell).floor() as i64, (y / cell).floor() as i64);
    let mut sum = 0.0;
    for j in cy - 1..=cy + 1 {
        for i in cx - 1..=cx + 1 {
            let mut hsh = (i.wrapping_mul(73_856_093) ^ j.wrapping_mul(19_349_663)) as u64;
            hsh = hsh.wrapping_mul(0x9E37_79B9_7F4A_7C15);
            let mut next = || {
                hsh ^= hsh >> 29;
                hsh = hsh.wrapping_mul(0xBF58_476D_1CE4_E5B9);
                hsh ^= hsh >> 32;
                (hsh % 10_000) as f64 / 10_000.0
            };
            let (bx, by) = ((i as f64 + next()) * cell, (j as f64 + next()) * cell);
            let r = 6.0 + 14.0 * next();
            let amp = (next() - 0.5) * 0.6;
            let d2 = (x - bx).powi(2) + (y - by).powi(2);
            sum += amp * (-d2 / (2.0 * r * r)).exp();
        }
    }
    sum
}

/// A different texture (a cut, a moving object).
fn other(x: f64, y: f64) -> [f64; 3] {
    let v = 0.45 + 0.25 * (x / 6.9 + y / 15.1).sin() * (y / 10.3 - x / 41.0).cos();
    [1.0 - v, v, 0.3 + 0.4 * v]
}

/// Encoded 8-bit picture, each pixel the mean of 2 x 2 samples (a box-filtered camera pixel).
fn picture(w: usize, h: usize, f: impl Fn(f64, f64) -> [f64; 3]) -> Vec<[f32; 3]> {
    (0..w * h)
        .map(|i| {
            let (x, y) = ((i % w) as f64, (i / w) as f64);
            let mut c = [0.0f64; 3];
            for (sx, sy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let s = f(x + sx, y + sy);
                (0..3).for_each(|k| c[k] += s[k] / 4.0);
            }
            c.map(|v| (v * 255.0).round().clamp(0.0, 255.0) as f32 / 255.0)
        })
        .collect()
}

fn encoded_texture(gpu: &Gpu, w: usize, h: usize, px: &[[f32; 3]]) -> GpuTexture {
    let t = gpu.texture(w as u32, h as u32, PixelFormat::Rgba16Float);
    let bytes: Vec<u8> = px.iter().flat_map(|c| [c[0], c[1], c[2], 1.0]).flat_map(|v| half(v).to_le_bytes()).collect();
    gpu.upload_texture(&t, &bytes, w as u32 * 8);
    t
}

/// Mean absolute difference in 8-bit encoded steps between the linear output and the encoded truth, inside `margin`.
fn error(out: &Image, truth: &[[f32; 3]], margin: usize) -> f64 {
    let (w, h) = (out.width, out.height);
    let (mut sum, mut n) = (0.0f64, 0usize);
    for y in margin..h - margin {
        for x in margin..w - margin {
            let p = out.px[y * w + x];
            for (c, v) in [p.x, p.y, p.z].into_iter().enumerate() {
                sum += f64::from((enc(v) - truth[y * w + x][c]).abs());
                n += 1;
            }
        }
    }
    sum / n as f64 * 255.0
}

struct FlowRun {
    flow: Image,
    blend: Image,
}

/// Interpolates `a` to `b` at `t` by optical flow and by the plain frame blend.
fn flow_and_blend(
    gpu: &Arc<Gpu>,
    a: &GpuTexture,
    b: &GpuTexture,
    t: f32,
    quality: FlowQuality,
) -> Result<FlowRun, Box<dyn std::error::Error>> {
    let mut store = FlowStore::new(gpu);
    let mut scratch = Scratch::new(gpu);
    let mut cmds = gpu.commands();
    let request = OpticalFlowRequest { key: None, quality };
    let field = store.field(&mut cmds, &mut scratch, a, b, &request)?;
    let (flow, blend) = (
        gpu.texture(a.width(), a.height(), PixelFormat::Rgba16Float),
        gpu.texture(a.width(), a.height(), PixelFormat::Rgba16Float),
    );
    store.passes().interpolate(&mut cmds, a, b, &field, t, true, &flow)?;
    Kernels::new(gpu).blend_frames(&mut cmds, a, b, &blend, t, true)?;
    gpu.submit_and_wait(cmds)?;
    Ok(FlowRun { flow: download(gpu, &flow)?, blend: download(gpu, &blend)? })
}

#[test]
fn translation_is_interpolated_close_to_the_truth() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (320usize, 180usize);
    for ((dx, dy), t) in [((6.4f64, -3.3f64), 0.5f32), ((23.7, 11.2), 0.25)] {
        let a = picture(w, h, pattern);
        let b = picture(w, h, |x, y| pattern(x - dx, y - dy));
        let truth = picture(w, h, |x, y| pattern(x - f64::from(t) * dx, y - f64::from(t) * dy));
        let margin = dx.abs().max(dy.abs()) as usize + 8;
        let (ta, tb) = (encoded_texture(&gpu, w, h, &a), encoded_texture(&gpu, w, h, &b));
        let better = flow_and_blend(&gpu, &ta, &tb, t, FlowQuality::Better)?;
        let faster = flow_and_blend(&gpu, &ta, &tb, t, FlowQuality::Faster)?;
        let (fe, be, ff) = (
            error(&better.flow, &truth, margin),
            error(&better.blend, &truth, margin),
            error(&faster.flow, &truth, margin),
        );
        eprintln!(
            "translation d=({dx}, {dy}) t={t}: flow(better) {fe:.2} flow(faster) {ff:.2} blend {be:.2} (8-bit steps)"
        );
        assert!(fe < be * 0.25, "flow {fe} vs blend {be}");
        assert!(fe < 3.0, "flow error {fe}");
        assert!(ff < be * 0.5, "faster flow {ff} vs blend {be}");
    }
    Ok(())
}

#[test]
fn a_cut_falls_back_to_the_blend() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (320usize, 180usize);
    let a = encoded_texture(&gpu, w, h, &picture(w, h, pattern));
    let b = encoded_texture(&gpu, w, h, &picture(w, h, |x, y| other(x * 1.3, y * 0.8)));
    let run = flow_and_blend(&gpu, &a, &b, 0.5, FlowQuality::Better)?;
    let diff = error(&run.flow, &run.blend.px.iter().map(|p| [enc(p.x), enc(p.y), enc(p.z)]).collect::<Vec<_>>(), 0);
    assert!(diff < 6.0, "flow strays {diff} steps from the blend on a cut");
    Ok(())
}

#[test]
fn flow_is_cached_per_frame_pair_and_the_result_is_the_same() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (160usize, 90usize);
    let a = encoded_texture(&gpu, w, h, &picture(w, h, pattern));
    let b = encoded_texture(&gpu, w, h, &picture(w, h, |x, y| pattern(x - 2.5, y - 1.0)));
    let key = FlowPairKey { media: Id::from_u128(9), from: Time::new(0, 30), to: Time::new(1, 30), variant: 0 };
    let mut store = FlowStore::new(&gpu);
    let interpolate = |store: &mut FlowStore,
                       key: Option<FlowPairKey>,
                       t: f32|
     -> Result<Image, Box<dyn std::error::Error>> {
        let mut scratch = Scratch::new(&gpu);
        let mut cmds = gpu.commands();
        let out = gpu.texture(w as u32, h as u32, PixelFormat::Rgba16Float);
        let field =
            store.field(&mut cmds, &mut scratch, &a, &b, &OpticalFlowRequest { key, quality: FlowQuality::Better })?;
        store.passes().interpolate(&mut cmds, &a, &b, &field, t, true, &out)?;
        gpu.submit_and_wait(cmds)?;
        Ok(download(&gpu, &out)?)
    };
    let first = interpolate(&mut store, Some(key), 0.5)?;
    assert_eq!(store.measure_count(), 1);
    interpolate(&mut store, Some(key), 0.25)?;
    let again = interpolate(&mut store, Some(key), 0.5)?;
    assert_eq!((store.measure_count(), store.cached_pairs()), (1, 1));
    let uncached = interpolate(&mut store, None, 0.5)?;
    assert_eq!((store.measure_count(), store.cached_pairs()), (2, 1));
    // Cached and freshly measured: the same pixels (playback and export agree).
    assert!(first == again && first == uncached);
    // Bounded: a small cap keeps only the newest pair.
    store.cache_byte_limit = 1;
    let next = FlowPairKey { from: Time::new(1, 30), to: Time::new(2, 30), ..key };
    interpolate(&mut store, Some(next), 0.5)?;
    assert_eq!(store.cached_pairs(), 1);
    Ok(())
}

// MARK: Temporal passes

/// A gray 8-bit frame as the planes the passes read (RGB texture, no chroma).
fn gray_frame(gpu: &Gpu, w: usize, h: usize, f: impl Fn(usize, usize) -> u8) -> (GpuTexture, GpuTexture) {
    let t = gpu.texture(w as u32, h as u32, PixelFormat::Rgba8Unorm);
    let bytes: Vec<u8> = (0..w * h)
        .flat_map(|i| {
            let v = f(i % w, i / w);
            [v, v, v, 255]
        })
        .collect();
    gpu.upload_texture(&t, &bytes, w as u32 * 4);
    (t, gpu.texture(1, 1, PixelFormat::Rgba16Float))
}

/// Runs `filter` on `frames[center]` with the others as neighbors (nearest first on each side); `None` when nothing ran.
fn run_temporal(
    gpu: &Arc<Gpu>,
    frames: &[(GpuTexture, GpuTexture)],
    center: usize,
    filter: &TemporalFilter,
) -> Result<Option<Image>, Box<dyn std::error::Error>> {
    let (w, h) = (frames[center].0.width(), frames[center].0.height());
    let before: Vec<_> = frames[..center].iter().rev().cloned().collect();
    let after: Vec<_> = frames[center + 1..].to_vec();
    let (nb, na) = neighbor_limits(filter);
    let (before, after) = (&before[..before.len().min(nb)], &after[..after.len().min(na)]);
    let block = composite_block(w, h, 0);
    let input = TemporalInput { center: &frames[center], before, after, composite: block.bytes(), size: (w, h) };
    let mut scratch = Scratch::new(gpu);
    let mut cmds = gpu.commands();
    let Some(out) = TemporalPasses::new(gpu).run(&mut cmds, &mut scratch, filter, &input, None)? else {
        return Ok(None);
    };
    gpu.submit_and_wait(cmds)?;
    Ok(Some(download(gpu, &out)?))
}

fn lumas(img: &Image) -> Vec<f32> {
    img.px.iter().map(|p| 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z).collect()
}

fn mean(v: &[f32]) -> f32 {
    v.iter().sum::<f32>() / v.len() as f32
}

fn variance(v: &[f32]) -> f32 {
    let m = mean(v);
    v.iter().map(|x| (x - m) * (x - m)).sum::<f32>() / v.len() as f32
}

/// Deterministic noise in -amp...amp per pixel and frame.
fn noise(x: usize, y: usize, frame: usize, amp: i32) -> i32 {
    let mut v = (x.wrapping_mul(73_856_093) ^ y.wrapping_mul(19_349_663) ^ frame.wrapping_mul(83_492_791)) as u32;
    v ^= v >> 13;
    v = v.wrapping_mul(0x5bd1_e995);
    v ^= v >> 15;
    (v % (2 * amp as u32 + 1)) as i32 - amp
}

fn flat_value(v: u8) -> f32 {
    lin(f32::from(v) / 255.0)
}

#[test]
fn temporal_denoise_lowers_the_noise_of_a_still_picture() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (64usize, 64usize);
    let frames: Vec<_> = (0..5).map(|f| gray_frame(&gpu, w, h, |x, y| (128 + noise(x, y, f, 12)) as u8)).collect();
    let plain = Image::from_fn(w, h, |x, y| {
        let v = flat_value((128 + noise(x, y, 2, 12)) as u8);
        Float4::new(v, v, v, 1.0)
    });
    let denoise = |best| TemporalFilter {
        denoise: Some(TemporalDenoise { best, ..TemporalDenoise::new(2) }),
        ..Default::default()
    };
    let mk = |best| TemporalFilter {
        denoise: Some(TemporalDenoise {
            luma: 0.6,
            color: 0.6,
            ..denoise(best).denoise.unwrap_or(TemporalDenoise::new(2))
        }),
        ..Default::default()
    };
    let plain_l = lumas(&plain);
    for best in [false, true] {
        let Some(out) = run_temporal(&gpu, &frames, 2, &mk(best))? else { return Err("denoise did not run".into()) };
        let out_l = lumas(&out);
        assert!(
            variance(&out_l) < variance(&plain_l) * 0.5,
            "best {best}: {} vs {}",
            variance(&out_l),
            variance(&plain_l)
        );
        assert!((mean(&out_l) - mean(&plain_l)).abs() < 0.01);
    }
    Ok(())
}

#[test]
fn moving_detail_is_not_smeared_into_the_center_frame() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (64usize, 64usize);
    // A white square that is somewhere else in every neighbor.
    let frame = |off: i32| {
        gray_frame(&gpu, w, h, move |x, y| {
            if (8 + off..24 + off).contains(&(x as i32)) && (24..40).contains(&y) { 235 } else { 30 }
        })
    };
    let frames = [frame(-16), frame(-8), frame(0), frame(8), frame(16)];
    let filter = TemporalFilter {
        denoise: Some(TemporalDenoise { luma: 1.0, color: 1.0, ..TemporalDenoise::new(2) }),
        ..Default::default()
    };
    let Some(out) = run_temporal(&gpu, &frames, 2, &filter)? else { return Err("denoise did not run".into()) };
    let at = |x: usize| out.px[32 * w + x].x;
    assert!((at(16) - flat_value(235)).abs() < 0.01, "square stays");
    assert!((at(30) - flat_value(30)).abs() < 0.01, "no ghost where a neighbor's square was");
    Ok(())
}

#[test]
fn deflicker_pulls_a_frame_to_the_brightness_of_its_neighbors() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let frames: Vec<_> = [100u8, 100, 140, 100, 100].iter().map(|v| gray_frame(&gpu, 32, 32, |_, _| *v)).collect();
    for local in [false, true] {
        let filter = TemporalFilter { deflicker: Some(TemporalDeflicker::new(2, local, 1.0)), ..Default::default() };
        let Some(out) = run_temporal(&gpu, &frames, 2, &filter)? else { return Err("deflicker did not run".into()) };
        // (140 + 4 x 100) / 5 = 108
        let m = mean(&lumas(&out));
        assert!((m - flat_value(108)).abs() < 0.006, "local {local}: {m} vs {}", flat_value(108));
    }
    // Half strength lands half way (in encoded values: 124).
    let filter = TemporalFilter { deflicker: Some(TemporalDeflicker::new(2, false, 0.5)), ..Default::default() };
    let Some(out) = run_temporal(&gpu, &frames, 2, &filter)? else { return Err("deflicker did not run".into()) };
    assert!((mean(&lumas(&out)) - flat_value(124)).abs() < 0.006);
    Ok(())
}

#[test]
fn best_deflicker_leaves_a_region_that_really_changes() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (64usize, 36usize);
    // The whole frame flickers, but the left quarter of the center frame really got brighter (a lamp switched on).
    let f = |base: u8, lamp: bool| gray_frame(&gpu, w, h, move |x, _| if lamp && x < 16 { 220 } else { base });
    let frames = [f(100, false), f(100, false), f(110, true), f(100, false), f(100, false)];
    let run = |local| {
        let filter = TemporalFilter { deflicker: Some(TemporalDeflicker::new(2, local, 1.0)), ..Default::default() };
        run_temporal(&gpu, &frames, 2, &filter)
    };
    let (Some(fast), Some(best)) = (run(false)?, run(true)?) else { return Err("deflicker did not run".into()) };
    let (lamp, rest) = (18 * w + 2, 18 * w + 50);
    let (lamp_plain, rest_plain) = (flat_value(220), flat_value(110));
    // Best keeps the lamp (within the gain map's soft edge) and still corrects the rest; Fast darkens everything.
    assert!((best.px[lamp].x - lamp_plain).abs() < 0.02);
    assert!(best.px[rest].x < rest_plain - 0.005);
    assert!(fast.px[lamp].x < lamp_plain - 0.02);
    Ok(())
}

#[test]
fn spatial_denoise_smooths_a_single_frame_and_no_neighbors_means_no_temporal_pass() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (64usize, 64usize);
    let frame = gray_frame(&gpu, w, h, |x, y| (128 + noise(x, y, 0, 10)) as u8);
    let plain = Image::from_fn(w, h, |x, y| {
        let v = flat_value((128 + noise(x, y, 0, 10)) as u8);
        Float4::new(v, v, v, 1.0)
    });
    let spatial = TemporalFilter {
        denoise: Some(TemporalDenoise {
            detail_size: 2,
            spatial_luma: 0.8,
            spatial_color: 0.8,
            ..TemporalDenoise::new(0)
        }),
        ..Default::default()
    };
    let Some(out) = run_temporal(&gpu, std::slice::from_ref(&frame), 0, &spatial)? else {
        return Err("spatial denoise did not run".into());
    };
    assert!(variance(&lumas(&out)) < variance(&lumas(&plain)) * 0.5);
    // A temporal-only filter without neighbors has nothing to do.
    let temporal = TemporalFilter {
        denoise: Some(TemporalDenoise { luma: 0.6, ..TemporalDenoise::new(2) }),
        ..Default::default()
    };
    assert!(run_temporal(&gpu, std::slice::from_ref(&frame), 0, &temporal)?.is_none());
    Ok(())
}

#[test]
fn trails_lay_earlier_frames_over_the_shown_one() -> R {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (64usize, 16usize);
    // Dark frames with a bright 16 px bar per frame at x = 16 * frame index (frames 0 and 1 are earlier).
    let bar = |i: usize| gray_frame(&gpu, w, h, move |x, _| if x / 16 == i { 200 } else { 20 });
    let frames = [bar(0), bar(1), bar(2)]; // center = 2, before (nearest first) = 1, 0
    let lighten =
        TemporalFilter { trails: Some(TemporalTrails::new(2, 1, 0.0, TrailBlend::Lighten)), ..Default::default() };
    let Some(out) = run_temporal(&gpu, &frames, 2, &lighten)? else { return Err("trails did not run".into()) };
    let at = |bar: usize| out.px[8 * w + bar * 16 + 8].x;
    for b in 0..=2 {
        assert!((at(b) - flat_value(200)).abs() < 0.006, "bar {b}: {}", at(b));
    }
    assert!((at(3) - flat_value(20)).abs() < 0.006, "no frame has a bar there");
    // Without earlier frames the filter is the plain frame (nothing runs).
    assert!(run_temporal(&gpu, &frames[2..], 0, &lighten)?.is_none());
    Ok(())
}

#[test]
fn neighbor_limits_follow_the_filter() {
    let denoise = TemporalFilter {
        denoise: Some(TemporalDenoise { luma: 0.5, ..TemporalDenoise::new(3) }),
        ..Default::default()
    };
    assert_eq!(neighbor_limits(&denoise), (3, 3));
    let mut trails = TemporalTrails::new(4, 2, 0.5, TrailBlend::Add);
    assert_eq!(neighbor_limits(&TemporalFilter { trails: Some(trails), ..Default::default() }), (8, 0));
    trails.backward = true;
    assert_eq!(neighbor_limits(&TemporalFilter { trails: Some(trails), ..Default::default() }), (0, 8));
}
