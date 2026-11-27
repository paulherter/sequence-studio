// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnimatedImage.swift (`writeStrip`, `frame`), MediaImporter.probeAnimated
//! Animated GIF, APNG and WebP, and numbered image sequences, become a cached ProRes 4444 strip (alpha straight) that the normal video path plays. The frames
//! are decoded with the `gif` and `png` crates (composited onto the canvas with the formats' dispose and blend rules),
//! scaled down to `MAX_DIMENSION`, and written through the FFmpeg encoder (`prores_ks`, profile 4444). The timing rules,
//! the cache key and the straight-alpha rule are `sq_media::animated_image`'s.
//! WebP is decoded with the `image-webp` crate (it composites its frames onto the canvas); the stills of a sequence are
//! decoded by FFmpeg (PNG, TIFF, EXR, DPX, TGA ...). The last frame's delay is written as a repeated frame (the muxer has no end time).

use crate::encode::{EncodeConfig, Encoder, PixelLayout};
use sq_core_time::Time;
use sq_media::animated_image::{self, MAX_DIMENSION};
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

/// Why a strip could not be made (the importer shows "unreadable").
#[derive(Debug)]
pub struct AnimatedError(pub String);

impl std::fmt::Display for AnimatedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for AnimatedError {}

fn fail<E: std::fmt::Display>(e: E) -> AnimatedError {
    AnimatedError(e.to_string())
}

/// What a frame callback gets: the composited canvas (straight RGBA, `width * height * 4` bytes) and the frame's delay.
type FrameFn<'a> = dyn FnMut(&[u8], Option<f64>) -> Result<(), AnimatedError> + 'a;

/// Something that feeds every frame of an image to a `FrameFn` and returns the canvas size.
type FrameSource<'a> = dyn FnMut(&mut FrameFn<'_>) -> Result<(usize, usize), AnimatedError> + 'a;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Format {
    Gif,
    Png,
    Webp,
}

fn format_of(path: &Path) -> Option<Format> {
    let mut head = [0u8; 8];
    std::io::Read::read_exact(&mut File::open(path).ok()?, &mut head).ok()?;
    if head.starts_with(b"GIF8") {
        Some(Format::Gif)
    } else if head == [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a] {
        Some(Format::Png)
    } else if head.starts_with(b"RIFF") && webp_tag(path) {
        Some(Format::Webp)
    } else {
        None
    }
}

fn webp_tag(path: &Path) -> bool {
    let mut head = [0u8; 12];
    File::open(path).and_then(|mut f| std::io::Read::read_exact(&mut f, &mut head)).is_ok() && &head[8..12] == b"WEBP"
}

/// Animated WebP: the decoder composites every frame onto the canvas (dispose and blend); a still WebP gives no frames.
fn webp_frames(path: &Path, f: &mut FrameFn<'_>) -> Result<(usize, usize), AnimatedError> {
    let mut dec = image_webp::WebPDecoder::new(BufReader::new(File::open(path).map_err(fail)?)).map_err(fail)?;
    let (w, h) = dec.dimensions();
    let (cw, ch) = (w as usize, h as usize);
    if !dec.is_animated() {
        return Ok((cw, ch));
    }
    let size = dec.output_buffer_size().ok_or_else(|| fail("the picture is too large"))?;
    let alpha = dec.has_alpha();
    let mut buf = vec![0u8; size];
    for _ in 0..dec.num_frames() {
        let ms = dec.read_frame(&mut buf).map_err(fail)?;
        let delay = Some(f64::from(ms) / 1000.0);
        if alpha {
            f(&buf, delay)?;
        } else {
            let rgba: Vec<u8> = buf.as_chunks::<3>().0.iter().flat_map(|p| [p[0], p[1], p[2], 255]).collect();
            f(&rgba, delay)?;
        }
    }
    Ok((cw, ch))
}

/// Source-over of a straight-alpha pixel onto a straight-alpha canvas pixel.
fn over(dst: &mut [u8], src: &[u8]) {
    let sa = u32::from(src[3]);
    if sa == 255 {
        dst.copy_from_slice(src);
        return;
    }
    if sa == 0 {
        return;
    }
    let da = u32::from(dst[3]);
    let out_a_255 = sa * 255 + da * (255 - sa); // alpha scaled by 255
    for c in 0..3 {
        let num = u32::from(src[c]) * sa * 255 + u32::from(dst[c]) * da * (255 - sa);
        dst[c] = ((num + out_a_255 / 2) / out_a_255).min(255) as u8;
    }
    dst[3] = ((out_a_255 + 127) / 255).min(255) as u8;
}

fn clear_rect(canvas: &mut [u8], cw: usize, ch: usize, x: usize, y: usize, w: usize, h: usize) {
    for row in y..(y + h).min(ch) {
        let a = (row * cw + x.min(cw)) * 4;
        let b = (row * cw + (x + w).min(cw)) * 4;
        canvas[a..b].fill(0);
    }
}

/// Draws `rgba` (a `w` x `h` rect) at (`x`, `y`) onto the canvas; `blend` composites, else the pixels replace.
#[allow(clippy::too_many_arguments)] // a rect and a position: one argument per number
fn blit(canvas: &mut [u8], cw: usize, ch: usize, rgba: &[u8], x: usize, y: usize, w: usize, h: usize, blend: bool) {
    for row in 0..h {
        if y + row >= ch {
            break;
        }
        for col in 0..w {
            if x + col >= cw {
                break;
            }
            let s = &rgba[(row * w + col) * 4..][..4];
            let d = &mut canvas[((y + row) * cw + x + col) * 4..][..4];
            if blend {
                over(d, s);
            } else {
                d.copy_from_slice(s);
            }
        }
    }
}

fn gif_frames(path: &Path, f: &mut FrameFn<'_>) -> Result<(usize, usize), AnimatedError> {
    let mut opts = gif::DecodeOptions::new();
    opts.set_color_output(gif::ColorOutput::RGBA);
    let mut dec = opts.read_info(BufReader::new(File::open(path).map_err(fail)?)).map_err(fail)?;
    let (cw, ch) = (usize::from(dec.width()), usize::from(dec.height()));
    let mut canvas = vec![0u8; cw * ch * 4];
    while let Some(frame) = dec.read_next_frame().map_err(fail)? {
        let (x, y, w, h) =
            (usize::from(frame.left), usize::from(frame.top), usize::from(frame.width), usize::from(frame.height));
        let saved = (frame.dispose == gif::DisposalMethod::Previous).then(|| canvas.clone());
        // A transparent source pixel shows what is below (GIF has no partial alpha), so `over` is exact here.
        blit(&mut canvas, cw, ch, &frame.buffer, x, y, w, h, true);
        f(&canvas, Some(f64::from(frame.delay) / 100.0))?;
        match frame.dispose {
            gif::DisposalMethod::Background => clear_rect(&mut canvas, cw, ch, x, y, w, h),
            gif::DisposalMethod::Previous => {
                if let Some(s) = saved {
                    canvas = s;
                }
            }
            _ => {}
        }
    }
    Ok((cw, ch))
}

/// 8-bit pixels of any color type as RGBA.
fn to_rgba(buf: &[u8], line: usize, w: usize, h: usize, color: png::ColorType) -> Vec<u8> {
    let mut out = Vec::with_capacity(w * h * 4);
    for row in 0..h {
        let r = &buf[row * line..];
        for col in 0..w {
            match color {
                png::ColorType::Rgba => out.extend_from_slice(&r[col * 4..col * 4 + 4]),
                png::ColorType::Rgb => out.extend_from_slice(&[r[col * 3], r[col * 3 + 1], r[col * 3 + 2], 255]),
                png::ColorType::GrayscaleAlpha => {
                    out.extend_from_slice(&[r[col * 2], r[col * 2], r[col * 2], r[col * 2 + 1]])
                }
                _ => out.extend_from_slice(&[r[col], r[col], r[col], 255]),
            }
        }
    }
    out
}

fn png_frames(path: &Path, f: &mut FrameFn<'_>) -> Result<(usize, usize), AnimatedError> {
    let mut dec = png::Decoder::new(BufReader::new(File::open(path).map_err(fail)?));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut rd = dec.read_info().map_err(fail)?;
    let (cw, ch) = (rd.info().width as usize, rd.info().height as usize);
    let Some(total) = rd.info().animation_control.map(|a| a.num_frames) else { return Ok((cw, ch)) };
    let mut canvas = vec![0u8; cw * ch * 4];
    let mut buf = vec![0u8; rd.output_buffer_size().unwrap_or(cw * ch * 8).max(cw * ch * 8)];
    let mut shown = 0u32;
    // The default image may or may not be part of the animation: frames without a frame-control chunk are skipped.
    for _ in 0..=total {
        if shown == total {
            break;
        }
        let out = match rd.next_frame(&mut buf) {
            Ok(o) => o,
            Err(e) if shown > 0 => {
                let _ = e;
                break;
            }
            Err(e) => return Err(fail(e)),
        };
        let Some(fc) = rd.info().frame_control else { continue };
        let (x, y, w, h) = (fc.x_offset as usize, fc.y_offset as usize, fc.width as usize, fc.height as usize);
        let rgba = to_rgba(&buf, out.line_size, w, h, out.color_type);
        let dispose = if shown == 0 && fc.dispose_op == png::DisposeOp::Previous {
            png::DisposeOp::Background
        } else {
            fc.dispose_op
        };
        let saved = (dispose == png::DisposeOp::Previous).then(|| canvas.clone());
        blit(&mut canvas, cw, ch, &rgba, x, y, w, h, fc.blend_op == png::BlendOp::Over);
        let den = if fc.delay_den == 0 { 100.0 } else { f64::from(fc.delay_den) };
        f(&canvas, Some(f64::from(fc.delay_num) / den))?;
        shown += 1;
        match dispose {
            png::DisposeOp::Background => clear_rect(&mut canvas, cw, ch, x, y, w, h),
            png::DisposeOp::Previous => {
                if let Some(s) = saved {
                    canvas = s;
                }
            }
            png::DisposeOp::None => {}
        }
    }
    Ok((cw, ch))
}

fn for_each_frame(path: &Path, f: &mut FrameFn<'_>) -> Result<(usize, usize), AnimatedError> {
    match format_of(path) {
        Some(Format::Gif) => gif_frames(path, f),
        Some(Format::Png) => png_frames(path, f),
        Some(Format::Webp) => webp_frames(path, f),
        None => Err(AnimatedError("not a GIF, PNG or WebP".into())),
    }
}

/// Box-filter reduction so the longest side is at most `MAX_DIMENSION`; the size is returned with the pixels.
fn fit(rgba: &[u8], w: usize, h: usize) -> (Vec<u8>, usize, usize) {
    let longest = w.max(h);
    if longest as i64 <= MAX_DIMENSION {
        return (rgba.to_vec(), w, h);
    }
    let s = MAX_DIMENSION as f64 / longest as f64;
    let (nw, nh) = (((w as f64 * s).round() as usize).max(1), ((h as f64 * s).round() as usize).max(1));
    let mut out = vec![0u8; nw * nh * 4];
    for y in 0..nh {
        let (y0, y1) = (y * h / nh, ((y + 1) * h).div_ceil(nh).min(h).max(y * h / nh + 1));
        for x in 0..nw {
            let (x0, x1) = (x * w / nw, ((x + 1) * w).div_ceil(nw).min(w).max(x * w / nw + 1));
            // Alpha-weighted so a transparent edge does not darken the color.
            let (mut r, mut g, mut b, mut a, mut n) = (0u64, 0u64, 0u64, 0u64, 0u64);
            for yy in y0..y1 {
                for xx in x0..x1 {
                    let p = &rgba[(yy * w + xx) * 4..][..4];
                    let pa = u64::from(p[3]);
                    r += u64::from(p[0]) * pa;
                    g += u64::from(p[1]) * pa;
                    b += u64::from(p[2]) * pa;
                    a += pa;
                    n += 1;
                }
            }
            let o = &mut out[(y * nw + x) * 4..][..4];
            let mean = |v: u64| (v + a / 2).checked_div(a).unwrap_or(0) as u8;
            if a > 0 {
                o[0] = mean(r);
                o[1] = mean(g);
                o[2] = mean(b);
                o[3] = ((a + n / 2) / n) as u8;
            }
        }
    }
    (out, nw, nh)
}

/// Path, size and date of a source (the cache key part, so an edited file gets a new strip).
pub fn file_stamp(path: &Path) -> String {
    let m = std::fs::metadata(path).ok();
    let size = m.as_ref().map_or(0, std::fs::Metadata::len);
    let secs = m
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs());
    format!("{}:{size}:{secs}", path.display())
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// The length of each delay in units of `1/scale` s and the tick (their greatest common divisor) the strip's timestamps
/// count in. Delays that share one timescale (a sequence at 30 fps) stay exact; mixed ones are counted in milliseconds.
fn ticks(delays: &[Time]) -> (Vec<i64>, i64, i64) {
    let scale = delays.first().map_or(1000, |d| d.timescale());
    let (vals, scale): (Vec<i64>, i64) = if delays.iter().all(|d| d.timescale() == scale) {
        (delays.iter().map(|d| d.value()).collect(), scale)
    } else {
        (delays.iter().map(|d| d.value() * 1000 / d.timescale().max(1)).collect(), 1000)
    };
    let g = vals.iter().fold(0, |a, b| gcd(a, *b)).max(1);
    (vals, g, scale)
}

/// Animated GIF, APNG or WebP at `path` as a cached ProRes 4444 strip in `cache`: the strip's path, or `None` for a
/// single-frame or unreadable picture (it imports as a still). An existing strip is reused (Swift `probeAnimated`).
pub fn probe_animated(path: &Path, cache: &Path) -> Result<Option<PathBuf>, AnimatedError> {
    if format_of(path).is_none() {
        return Ok(None);
    }
    let mut delays: Vec<Option<f64>> = Vec::new();
    let (cw, ch) = for_each_frame(path, &mut |_, d| {
        delays.push(d);
        Ok(())
    })?;
    let Some(info) = animated_image::info(&delays) else { return Ok(None) };
    let strip = animated_image::strip_path(&["anim".to_string(), file_stamp(path)], cache);
    if strip.exists() {
        return Ok(Some(strip));
    }
    write_cached(&strip, cache, |tmp| write_strip(&mut |f| for_each_frame(path, f), tmp, cw, ch, &info.delays))?;
    Ok(Some(strip))
}

/// Writes through a temporary file in `cache` and renames it to `strip` when it is whole.
fn write_cached(
    strip: &Path,
    cache: &Path,
    write: impl FnOnce(&Path) -> Result<(), AnimatedError>,
) -> Result<(), AnimatedError> {
    std::fs::create_dir_all(cache).map_err(fail)?;
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let tmp = cache.join(format!("{}-{nanos}.tmp.mov", std::process::id()));
    if let Err(e) = write(&tmp) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    std::fs::rename(&tmp, strip).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        fail(e)
    })
}

/// Numbered stills (already in frame order, at least two) as one cached ProRes 4444 strip at `fps` (Swift
/// `probeSequence`). The strip has the first picture's size; a picture of another size is fitted into it, centered.
pub fn probe_sequence(frames: &[PathBuf], fps: i64, cache: &Path) -> Result<PathBuf, AnimatedError> {
    if frames.len() < 2 || fps <= 0 {
        return Err(AnimatedError("An image sequence needs at least two frames.".into()));
    }
    let (cw, ch) = crate::shim::image_size(&frames[0]).map_err(fail)?;
    let mut key = vec!["seq".to_string(), fps.to_string()];
    key.extend(frames.iter().map(|p| file_stamp(p)));
    let strip = animated_image::strip_path(&key, cache);
    if strip.exists() {
        return Ok(strip);
    }
    let delays = vec![Time::new(1, fps); frames.len()];
    write_cached(&strip, cache, |tmp| {
        let each = &mut |f: &mut FrameFn<'_>| -> Result<(usize, usize), AnimatedError> {
            for p in frames {
                let (w, h) = crate::shim::image_size(p).map_err(fail)?;
                let rgba = crate::shim::image_rgba(p, w, h).map_err(fail)?;
                if (w, h) == (cw, ch) {
                    f(&rgba, None)?;
                } else {
                    f(&fit_centered(&rgba, w, h, cw, ch), None)?;
                }
            }
            Ok((cw, ch))
        };
        write_strip(each, tmp, cw, ch, &delays)
    })?;
    Ok(strip)
}

/// `rgba` (`w` x `h`) scaled to fit `cw` x `ch` (nearest neighbor) and centered on transparent.
fn fit_centered(rgba: &[u8], w: usize, h: usize, cw: usize, ch: usize) -> Vec<u8> {
    let s = (cw as f64 / w as f64).min(ch as f64 / h as f64);
    let (nw, nh) = (((w as f64 * s).round() as usize).clamp(1, cw), ((h as f64 * s).round() as usize).clamp(1, ch));
    let (ox, oy) = ((cw - nw) / 2, (ch - nh) / 2);
    let mut out = vec![0u8; cw * ch * 4];
    for y in 0..nh {
        for x in 0..nw {
            let src = ((y * h / nh) * w + x * w / nw) * 4;
            let dst = ((oy + y) * cw + ox + x) * 4;
            out[dst..dst + 4].copy_from_slice(&rgba[src..src + 4]);
        }
    }
    out
}

/// Writes the frames `each` produces (it calls the callback once per frame) as the strip `out`.
fn write_strip(
    each: &mut FrameSource<'_>,
    out: &Path,
    cw: usize,
    ch: usize,
    delays: &[Time],
) -> Result<(), AnimatedError> {
    let (w, h) = scaled_size(cw, ch);
    let (ms, g, scale) = ticks(delays);
    let cfg = EncodeConfig {
        path: out.to_path_buf(),
        width: i32::try_from(w).map_err(fail)?,
        height: i32::try_from(h).map_err(fail)?,
        fps_num: i32::try_from(scale).map_err(fail)?,
        fps_den: i32::try_from(g).map_err(fail)?,
        prores: 5,
        ..EncodeConfig::default()
    };
    let mut enc = Encoder::open(&cfg).map_err(fail)?;
    let mut index = 0usize;
    let mut start = 0i64;
    let last = ms.len() - 1;
    each(&mut |canvas, _| {
        if index >= ms.len() {
            return Ok(());
        }
        let (mut px, fw, fh) = fit(canvas, cw, ch);
        debug_assert_eq!((fw, fh), (w, h));
        for p in px.as_chunks_mut::<4>().0.iter_mut() {
            if p[3] == 0 {
                p[..3].fill(0);
            }
        }
        let stride = i32::try_from(fw * 4).map_err(fail)?;
        enc.video(&px, PixelLayout::Rgba, stride, start / g).map_err(fail)?;
        if index == last && ms[index] > g {
            // The muxer ends a track one tick after its last frame: repeat the frame to show it for its whole delay.
            enc.video(&px, PixelLayout::Rgba, stride, (start + ms[index]) / g - 1).map_err(fail)?;
        }
        start += ms[index];
        index += 1;
        Ok(())
    })?;
    enc.finish().map_err(fail)
}

fn scaled_size(w: usize, h: usize) -> (usize, usize) {
    let longest = w.max(h);
    if longest as i64 <= MAX_DIMENSION {
        return (w, h);
    }
    let s = MAX_DIMENSION as f64 / longest as f64;
    (((w as f64 * s).round() as usize).max(1), ((h as f64 * s).round() as usize).max(1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::FFmpegDemuxer;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-animated-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        dir
    }

    /// Three 8x6 frames: red, green (half transparent), blue; delays 100, 200, 100 ms.
    fn write_gif(path: &Path) {
        let mut enc = gif::Encoder::new(File::create(path).expect("file"), 8, 6, &[]).expect("encoder");
        for (rgba, delay) in [([255u8, 0, 0, 255], 10u16), ([0, 255, 0, 255], 20), ([0, 0, 255, 255], 10)] {
            let mut px: Vec<u8> = rgba.iter().copied().cycle().take(8 * 6 * 4).collect();
            if rgba[1] == 255 {
                for p in px.as_chunks_mut::<4>().0.iter_mut().take(8 * 3) {
                    p[3] = 0; // top half transparent
                }
            }
            let mut f = gif::Frame::from_rgba(8, 6, &mut px);
            f.delay = delay;
            enc.write_frame(&f).expect("frame");
        }
    }

    fn write_apng(path: &Path) {
        let mut enc = png::Encoder::new(std::io::BufWriter::new(File::create(path).expect("file")), 8, 6);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_animated(3, 0).expect("animated");
        let mut w = enc.write_header().expect("header");
        for (c, den) in [([255u8, 0, 0, 255], 10u16), ([0, 255, 0, 128], 5), ([0, 0, 255, 255], 10)] {
            w.set_frame_delay(1, den).expect("delay");
            let px: Vec<u8> = c.iter().copied().cycle().take(8 * 6 * 4).collect();
            w.write_image_data(&px).expect("data");
        }
        w.finish().expect("finish");
    }

    #[test]
    fn gif_frames_composite_with_their_delays() {
        let dir = temp("gif-decode");
        let gif = dir.join("a.gif");
        write_gif(&gif);
        let mut seen: Vec<(u8, u8, Option<f64>)> = Vec::new();
        let size = for_each_frame(&gif, &mut |canvas, d| {
            seen.push((canvas[0], canvas[1], d));
            Ok(())
        })
        .expect("decode");
        assert_eq!(size, (8, 6));
        // Frame 2: the transparent top half shows frame 1 below it (dispose none), the bottom is opaque green.
        assert_eq!(seen, vec![(255, 0, Some(0.1)), (255, 0, Some(0.2)), (0, 0, Some(0.1))]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn apng_frames_decode_with_straight_alpha_and_delays() {
        let dir = temp("apng-decode");
        let file = dir.join("a.png");
        write_apng(&file);
        let mut seen: Vec<([u8; 4], Option<f64>)> = Vec::new();
        for_each_frame(&file, &mut |c, d| {
            seen.push(([c[0], c[1], c[2], c[3]], d));
            Ok(())
        })
        .expect("decode");
        assert_eq!(seen.len(), 3);
        assert_eq!(seen[0], ([255, 0, 0, 255], Some(0.1)));
        assert_eq!(seen[2], ([0, 0, 255, 255], Some(0.1)));
        assert!((seen[1].1.unwrap_or(0.0) - 0.2).abs() < 1e-9);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn single_frame_gif_and_other_files_make_no_strip() {
        let dir = temp("single");
        let one = dir.join("one.gif");
        let mut enc = gif::Encoder::new(File::create(&one).expect("file"), 4, 4, &[]).expect("encoder");
        let mut px = vec![255u8; 4 * 4 * 4];
        enc.write_frame(&gif::Frame::from_rgba(4, 4, &mut px)).expect("frame");
        drop(enc);
        assert!(matches!(probe_animated(&one, &dir.join("cache")), Ok(None)));
        let txt = dir.join("x.txt");
        std::fs::write(&txt, b"hello").expect("write");
        assert!(matches!(probe_animated(&txt, &dir.join("cache")), Ok(None)));
        let _ = std::fs::remove_dir_all(dir);
    }

    fn strip_check(file: &Path, dir: &Path, expect_ms: i64) {
        let cache = dir.join("cache");
        let strip = probe_animated(file, &cache).expect("probe").expect("animated");
        assert!(strip.starts_with(&cache) && strip.exists());
        // The same source reuses the strip.
        assert_eq!(probe_animated(file, &cache).expect("again"), Some(strip.clone()));
        let d = FFmpegDemuxer::open(&strip).expect("strip opens");
        assert_eq!(d.packet_count(), 3);
        assert_eq!(d.table().index.duration(), Time::new(expect_ms, 1000));
        assert!(d.track_info().codec.to_lowercase().contains("prores") || !d.track_info().codec.is_empty());
    }

    #[test]
    fn gif_becomes_a_prores_strip_with_the_gif_timing() {
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = temp("gif-strip");
        let gif = dir.join("a.gif");
        write_gif(&gif);
        strip_check(&gif, &dir, 400);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn apng_becomes_a_prores_strip_with_the_apng_timing() {
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = temp("apng-strip");
        let file = dir.join("a.png");
        write_apng(&file);
        strip_check(&file, &dir, 400);
        // Alpha stays straight: the second frame (t = 0.1 s) is green at alpha 128, not a darkened premultiplied green (the
        // color check is loose: the CLI reads the untagged strip back with its own matrix).
        let strip = probe_animated(&file, &dir.join("cache")).ok().flatten().expect("strip");
        let ffmpeg = std::env::var_os("SQ_FFMPEG")
            .map(|r| PathBuf::from(r).join("bin").join("ffmpeg"))
            .filter(|p| p.exists() || p.with_extension("exe").exists())
            .unwrap_or_else(|| "ffmpeg".into());
        let out = std::process::Command::new(ffmpeg)
            .args(["-v", "error", "-ss", "0.1", "-i"])
            .arg(&strip)
            .args(["-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"])
            .output();
        if let Some(o) = out.ok().filter(|o| o.status.success() && o.stdout.len() == 8 * 6 * 4) {
            let p = &o.stdout[..4];
            assert!(p[0] <= 40 && p[1] >= 220 && p[2] <= 40 && (i32::from(p[3]) - 128).abs() <= 2, "pixel {p:?}");
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn tick_is_the_gcd_of_the_delays() {
        let d = [Time::new(100, 1000), Time::new(200, 1000), Time::new(150, 1000)];
        let (ms, g, scale) = ticks(&d);
        assert_eq!((ms, g, scale), (vec![100, 200, 150], 50, 1000));
        // Delays of one timescale stay exact: 30 fps is 1/30 s, not 33 ms.
        let (v, g, scale) = ticks(&[Time::new(1, 30), Time::new(1, 30)]);
        assert_eq!((v, g, scale), (vec![1, 1], 1, 30));
    }

    fn ffmpeg_cmd() -> std::process::Command {
        let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
        std::process::Command::new(
            bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffmpeg".into()),
        )
    }

    /// Runs ffmpeg with `args` and the output file; false when it is missing or fails (the test then skips).
    fn make(args: &[&str], out: &Path) -> bool {
        ffmpeg_cmd().args(["-v", "error", "-y"]).args(args).arg(out).status().is_ok_and(|s| s.success()) && out.exists()
    }

    fn le24(v: u32) -> [u8; 3] {
        [v as u8, (v >> 8) as u8, (v >> 16) as u8]
    }

    fn chunk(tag: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut c = tag.to_vec();
        c.extend((body.len() as u32).to_le_bytes());
        c.extend(body);
        if body.len() % 2 == 1 {
            c.push(0);
        }
        c
    }

    /// An animated WebP made by hand: one lossless picture per `(color, delay ms)`, all `w` x `h`, no ffmpeg needed.
    fn write_animated_webp(path: &Path, w: u32, h: u32, frames: &[([u8; 4], u32)]) {
        let mut anmfs = Vec::new();
        for (color, ms) in frames {
            let px: Vec<u8> = color.iter().copied().cycle().take((w * h * 4) as usize).collect();
            let mut still = Vec::new();
            image_webp::WebPEncoder::new(&mut still)
                .encode(&px, w, h, image_webp::ColorType::Rgba8)
                .expect("encode still");
            // Find the VP8L chunk of the still (after the 12-byte RIFF header).
            let mut at = 12;
            let vp8l = loop {
                let size = u32::from_le_bytes(still[at + 4..at + 8].try_into().expect("size")) as usize;
                if &still[at..at + 4] == b"VP8L" {
                    break still[at..at + 8 + size + size % 2].to_vec();
                }
                at += 8 + size + size % 2;
            };
            let mut body = Vec::new();
            body.extend([0, 0, 0, 0, 0, 0]); // x, y
            body.extend(le24(w - 1));
            body.extend(le24(h - 1));
            body.extend(le24(*ms));
            body.push(0); // blend, no dispose
            body.extend(vp8l);
            anmfs.extend(chunk(b"ANMF", &body));
        }
        let mut vp8x = vec![0x12, 0, 0, 0]; // animation + alpha
        vp8x.extend(le24(w - 1));
        vp8x.extend(le24(h - 1));
        let mut payload = b"WEBP".to_vec();
        payload.extend(chunk(b"VP8X", &vp8x));
        payload.extend(chunk(b"ANIM", &[0, 0, 0, 0, 0, 0]));
        payload.extend(anmfs);
        let mut file = b"RIFF".to_vec();
        file.extend((payload.len() as u32).to_le_bytes());
        file.extend(payload);
        std::fs::write(path, file).expect("write webp");
    }

    #[test]
    fn animated_webp_frames_decode_with_their_delays() {
        let dir = temp("webp-decode");
        let file = dir.join("a.webp");
        write_animated_webp(&file, 8, 6, &[([255, 0, 0, 255], 100), ([0, 255, 0, 255], 200), ([0, 0, 255, 255], 100)]);
        assert!(format_of(&file) == Some(Format::Webp));
        let mut seen: Vec<([u8; 4], Option<f64>)> = Vec::new();
        let size = for_each_frame(&file, &mut |c, d| {
            assert_eq!(c.len(), 8 * 6 * 4);
            seen.push(([c[0], c[1], c[2], c[3]], d));
            Ok(())
        })
        .expect("decode");
        assert_eq!(size, (8, 6));
        // The decoder's color conversion may be one step off.
        let want = [([255u8, 0, 0, 255], 0.1), ([0, 255, 0, 255], 0.2), ([0, 0, 255, 255], 0.1)];
        assert_eq!(seen.len(), 3);
        for ((got, d), (c, ms)) in seen.iter().zip(want) {
            assert!(got.iter().zip(c).all(|(a, b)| a.abs_diff(b) <= 1), "{got:?}");
            assert!(d.is_some_and(|d| (d - ms).abs() < 1e-9));
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn animated_webp_becomes_a_strip_with_its_timing() {
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = temp("webp-strip");
        let file = dir.join("a.webp");
        write_animated_webp(&file, 8, 6, &[([255, 0, 0, 255], 100), ([0, 255, 0, 255], 200), ([0, 0, 255, 255], 100)]);
        strip_check(&file, &dir, 400);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_still_webp_is_no_animation() {
        let dir = temp("webp-still");
        let file = dir.join("s.webp");
        let mut bytes = Vec::new();
        image_webp::WebPEncoder::new(&mut bytes)
            .encode(&[255u8; 4 * 4 * 4], 4, 4, image_webp::ColorType::Rgba8)
            .expect("encode");
        std::fs::write(&file, bytes).expect("write");
        assert!(matches!(probe_animated(&file, &dir.join("cache")), Ok(None)));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn stills_of_every_sequence_format_decode_to_rgba() {
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = temp("still-formats");
        for ext in ["png", "tif", "dpx", "tga", "exr"] {
            let file = dir.join(format!("r.{ext}"));
            if !make(&["-f", "lavfi", "-i", "color=c=0xFF0000:s=16x12", "-frames:v", "1"], &file) {
                sq_os::errln!("skipped {ext}: ffmpeg cannot write it");
                continue;
            }
            let (w, h) = crate::shim::image_size(&file).expect("size");
            assert_eq!((w, h), (16, 12), "{ext}");
            let px = crate::shim::image_rgba(&file, w, h).expect("decode");
            let mid = &px[(6 * 16 + 8) * 4..][..4];
            assert!(mid[0] >= 235 && mid[1] <= 20 && mid[2] <= 20 && mid[3] == 255, "{ext}: {mid:?}");
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn numbered_stills_become_one_strip_at_the_sequence_rate() {
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = temp("sequence");
        let mut frames = Vec::new();
        for i in 1..=5u8 {
            let f = dir.join(format!("fx_{i:04}.png"));
            // The last frame is smaller: it is fitted into the first one's size.
            let size = if i == 5 { "8x6" } else { "16x12" };
            if !make(&["-f", "lavfi", "-i", &format!("color=c=0x{:02X}0000:s={size}", i * 40), "-frames:v", "1"], &f) {
                return;
            }
            frames.push(f);
        }
        let cache = dir.join("cache");
        let strip = probe_sequence(&frames, 30, &cache).expect("strip");
        assert_eq!(probe_sequence(&frames, 30, &cache).expect("again"), strip);
        assert_ne!(probe_sequence(&frames, 24, &cache).expect("other rate"), strip);
        let d = FFmpegDemuxer::open(&strip).expect("strip opens");
        assert_eq!(d.packet_count(), 5);
        assert_eq!(d.table().index.duration(), Time::new(5, 30));
        assert_eq!((d.track_info().width, d.track_info().height), (16, 12));
        assert!(probe_sequence(&frames[..1], 30, &cache).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_smaller_picture_is_centered_on_transparent() {
        let px = vec![255u8; 2 * 2 * 4];
        let out = fit_centered(&px, 2, 2, 4, 2);
        // 2x2 fitted into 4x2: the picture is 2 wide, one column of transparent on each side.
        assert_eq!(&out[..4], &[0, 0, 0, 0]);
        assert_eq!(&out[4..8], &[255; 4]);
        assert_eq!(&out[12..16], &[0, 0, 0, 0]);
    }

    #[test]
    fn large_pictures_are_reduced_to_the_maximum() {
        let (w, h) = (4096usize, 2048usize);
        let px = vec![200u8; w * h * 4];
        let (out, nw, nh) = fit(&px, w, h);
        assert_eq!((nw, nh), (2048, 1024));
        assert_eq!(out.len(), nw * nh * 4);
        assert_eq!(&out[..4], &[200, 200, 200, 200]);
        assert_eq!(scaled_size(100, 50), (100, 50));
    }
}
