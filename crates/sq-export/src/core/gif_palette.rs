// Swift: GIFPalette.swift

use std::collections::HashMap;

/// The 256 colors of one animated-GIF frame (each frame gets its own table: a scene change does not inherit the palette
/// of the shot before it).
///
/// Median cut over a 5-bit-per-channel histogram, each box's color the pixel-weighted mean, then every pixel to the
/// nearest palette color.
// Same as Swift (GIFPalette.swift:8): no dithering and no transparency; add error diffusion when gradients band visibly in delivered GIFs.
pub struct GifPalette;

/// One quantized frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GifPaletteFrame {
    /// One palette index per pixel, rows top down.
    pub indices: Vec<u8>,
    /// Up to 256 colors as (r, g, b).
    pub colors: Vec<(u8, u8, u8)>,
}

struct Bounds {
    keys: Vec<usize>,
    pixels: usize,
}

fn axis_range(keys: &[usize]) -> (usize, usize) {
    let (mut lo, mut hi) = ([31usize; 3], [0usize; 3]);
    for &k in keys {
        let c = [(k >> 10) & 31, (k >> 5) & 31, k & 31];
        for a in 0..3 {
            lo[a] = lo[a].min(c[a]);
            hi[a] = hi[a].max(c[a]);
        }
    }
    let spans = [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]];
    let max = spans[0].max(spans[1]).max(spans[2]);
    let a = spans.iter().position(|&s| s == max).unwrap_or(0);
    (a, spans[a])
}

impl GifPalette {
    /// `pixels`: `width * height` packed 4-byte pixels, `r_offset` / `g_offset` / `b_offset` the channel bytes (RGBA:
    /// 0, 1, 2; BGRA: 2, 1, 0), rows `bytes_per_row` apart.
    #[allow(clippy::too_many_arguments)]
    pub fn quantize(
        pixels: &[u8],
        width: usize,
        height: usize,
        bytes_per_row: usize,
        r_offset: usize,
        g_offset: usize,
        b_offset: usize,
        max_colors: usize,
    ) -> GifPaletteFrame {
        let n = width * height;
        if n == 0 {
            return GifPaletteFrame { indices: Vec::new(), colors: Vec::new() };
        }
        let rgb = |p: usize| {
            let o = (p / width) * bytes_per_row + (p % width) * 4;
            (usize::from(pixels[o + r_offset]), usize::from(pixels[o + g_offset]), usize::from(pixels[o + b_offset]))
        };
        // Exact colors when the frame has few (flat graphics stay exact).
        let mut exact: HashMap<u32, u8> = HashMap::new();
        let mut exact_colors: Vec<(u8, u8, u8)> = Vec::new();
        let mut fits = true;
        let mut indices = vec![0u8; n];
        for (p, slot) in indices.iter_mut().enumerate() {
            let (r, g, b) = rgb(p);
            let key = (r << 16 | g << 8 | b) as u32;
            if let Some(&i) = exact.get(&key) {
                *slot = i;
                continue;
            }
            if exact_colors.len() >= max_colors {
                fits = false;
                break;
            }
            let i = exact_colors.len() as u8;
            exact.insert(key, i);
            *slot = i;
            exact_colors.push((r as u8, g as u8, b as u8));
        }
        if fits {
            return GifPaletteFrame { indices, colors: exact_colors };
        }

        // Histogram of 15-bit colors with channel sums (for the box means).
        let mut count = vec![0usize; 32768];
        let mut sums = vec![0usize; 32768 * 3];
        for p in 0..n {
            let (r, g, b) = rgb(p);
            let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3);
            count[k] += 1;
            sums[k * 3] += r;
            sums[k * 3 + 1] += g;
            sums[k * 3 + 2] += b;
        }
        let used: Vec<usize> = (0..32768).filter(|&k| count[k] > 0).collect();
        let mut boxes = vec![Bounds { keys: used.clone(), pixels: n }];
        while boxes.len() < max_colors {
            // Split the box with the most pixels that still has a span (ties: the first).
            let mut pick: Option<usize> = None;
            for (i, b) in boxes.iter().enumerate() {
                if b.keys.len() > 1 && pick.is_none_or(|p| boxes[p].pixels < b.pixels) {
                    pick = Some(i);
                }
            }
            let Some(bi) = pick else { break };
            let (axis, span) = axis_range(&boxes[bi].keys);
            if span == 0 {
                break;
            }
            let shift = [10, 5, 0][axis];
            let mut sorted = boxes[bi].keys.clone();
            sorted.sort_by_key(|k| (k >> shift) & 31);
            // Median by pixel count.
            let (mut acc, mut cut) = (0usize, 1usize);
            for (i, &k) in sorted.iter().enumerate() {
                acc += count[k];
                if acc * 2 >= boxes[bi].pixels {
                    cut = (i + 1).min(sorted.len() - 1).max(1);
                    break;
                }
            }
            let a: Vec<usize> = sorted[..cut].to_vec();
            let b: Vec<usize> = sorted[cut..].to_vec();
            let (pa, pb) = (a.iter().map(|&k| count[k]).sum(), b.iter().map(|&k| count[k]).sum());
            boxes[bi] = Bounds { keys: a, pixels: pa };
            boxes.push(Bounds { keys: b, pixels: pb });
        }
        let colors: Vec<(u8, u8, u8)> = boxes
            .iter()
            .map(|bx| {
                let (mut r, mut g, mut b) = (0, 0, 0);
                for &k in &bx.keys {
                    r += sums[k * 3];
                    g += sums[k * 3 + 1];
                    b += sums[k * 3 + 2];
                }
                let m = bx.pixels.max(1);
                (((r + m / 2) / m) as u8, ((g + m / 2) / m) as u8, ((b + m / 2) / m) as u8)
            })
            .collect();
        // Nearest palette color per histogram cell (at the cell's mean), then per pixel through the cell.
        let mut map = vec![0u8; 32768];
        for &k in &used {
            let c = count[k].max(1);
            let (r, g, b) = (sums[k * 3] / c, sums[k * 3 + 1] / c, sums[k * 3 + 2] / c);
            let (mut best, mut best_d) = (0usize, usize::MAX);
            for (i, p) in colors.iter().enumerate() {
                let (dr, dg, db) =
                    (r.abs_diff(usize::from(p.0)), g.abs_diff(usize::from(p.1)), b.abs_diff(usize::from(p.2)));
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
                if d < best_d {
                    best_d = d;
                    best = i;
                }
            }
            map[k] = best as u8;
        }
        for (p, slot) in indices.iter_mut().enumerate() {
            let (r, g, b) = rgb(p);
            *slot = map[(r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)];
        }
        GifPaletteFrame { indices, colors }
    }
}
