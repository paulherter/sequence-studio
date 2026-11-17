// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectTrackRules.swift
//! The model-free rules of subject tracking with a segment-and-remember model (EdgeTAM): how a frame maps onto the
//! model's square, how its answer becomes a matte, which prompt answer to keep.
//!
//! The frame is stretched onto the model square (no letterbox): a point at frame fractions (u, v) is at (u * 1024, v *
//! 1024), and the 256 x 256 logits cover the whole frame. A matte is the logits resampled to the frame size (bilinear,
//! texel centers) and then put through the sigmoid, in that order (the reference code's order).

use crate::subject_mask::SubjectMatte;
use sq_core_model::MagicPoint;
use sq_core_time::Vec2;

/// Which devices run the subject tracking model (the Core ML compute units, named without Core ML).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubjectTrackCompute {
    /// CPU and GPU: fastest on Pro / Max / Ultra chips (about 50 ms per frame), about 400 MB.
    Gpu,
    /// CPU and Neural Engine: about 80 ms per frame, about 110 MB. The choice of every other Apple chip.
    NeuralEngine,
}

/// A box in frame fractions (0...1, y down), `x0 <= x1`, `y0 <= y1`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubjectTrackBox {
    /// Left.
    pub x0: f64,
    /// Top.
    pub y0: f64,
    /// Right.
    pub x1: f64,
    /// Bottom.
    pub y1: f64,
}

impl SubjectTrackBox {
    /// A box from its edges.
    pub fn new(x0: f64, y0: f64, x1: f64, y1: f64) -> SubjectTrackBox {
        SubjectTrackBox { x0, y0, x1, y1 }
    }

    /// Width, never negative.
    pub fn width(&self) -> f64 {
        (self.x1 - self.x0).max(0.0)
    }

    /// Height, never negative.
    pub fn height(&self) -> f64 {
        (self.y1 - self.y0).max(0.0)
    }

    /// Width times height.
    pub fn area(&self) -> f64 {
        self.width() * self.height()
    }

    /// `p` lies inside (edges included).
    pub fn contains(&self, p: Vec2) -> bool {
        p.x >= self.x0 && p.x <= self.x1 && p.y >= self.y0 && p.y <= self.y1
    }

    /// Grown by `dx` / `dy` on each side.
    pub fn grown(&self, dx: f64, dy: f64) -> SubjectTrackBox {
        SubjectTrackBox::new(self.x0 - dx, self.y0 - dy, self.x1 + dx, self.y1 + dy)
    }

    /// The boxes overlap.
    pub fn intersects(&self, o: &SubjectTrackBox) -> bool {
        self.x1.min(o.x1) > self.x0.max(o.x0) && self.y1.min(o.y1) > self.y0.max(o.y0)
    }

    /// Intersection over union with `o` (0 when they do not touch).
    pub fn iou(&self, o: &SubjectTrackBox) -> f64 {
        let w = self.x1.min(o.x1) - self.x0.max(o.x0);
        let h = self.y1.min(o.y1) - self.y0.max(o.y0);
        if !(w > 0.0 && h > 0.0) {
            return 0.0;
        }
        let inter = w * h;
        let union = self.area() + o.area() - inter;
        if union > 0.0 { inter / union } else { 0.0 }
    }
}

/// Subject tracking rules.
pub struct SubjectTrackRules;

/// Share of the frame the logits call subject and the box around it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LogitStats {
    /// Share of the frame.
    pub area: f64,
    /// The box; `None` when nothing is subject.
    pub box_: Option<SubjectTrackBox>,
}

/// A piece the person holds that the model's answer left out.
type Piece = Vec<usize>;

impl SubjectTrackRules {
    /// Side of the model's input square (px).
    pub const MODEL_SIZE: usize = 1024;
    /// Side of the model's mask logits.
    pub const LOGIT_SIZE: usize = 256;
    /// Largest logit written for a matte given as the subject (`logits_from`).
    pub const MATTE_LOGIT: f32 = 10.0;
    /// Width (output pixels) of the soft band at a matte's edge: alpha runs from 0 to 1 across it.
    pub const MATTE_EDGE_WIDTH: f32 = 2.0;
    /// Smallest logit slope (per pixel) the edge distance divides by.
    pub const MATTE_SLOPE_FLOOR: f32 = 1e-4;
    /// A prompt box wider than this many times its instance's box is shrunk to the instance (a person box that took in
    /// neighbors, measured on the mask bench: 0.076 against a truth of 0.047).
    pub const PROMPT_BOX_MAX_RATIO: f64 = 1.3;
    /// A standing person's share of the person box's height, for `click_box`.
    pub const CLICK_BOX_HEIGHT: f64 = 0.85;
    /// A person's width over height, for `click_box`.
    pub const CLICK_BOX_ASPECT: f64 = 0.25;
    /// Pixels (logit grid) of erosion that take the outline slivers between two segmentations of one subject out of a
    /// held piece.
    pub const HELD_EROSION: usize = 1;
    /// The piece's part of `seen` must touch the answer within this many pixels.
    pub const HELD_TOUCH: usize = 2;
    /// A held piece is at most this share of the answer's area (a touching neighbor is about as large as the answer).
    pub const HELD_MAX_SHARE: f64 = 0.35;
    /// The overlap the model's answer for a held piece needs with it.
    pub const HELD_AGREEMENT: f64 = 0.4;
    /// Held pieces asked per pick.
    pub const HELD_LIMIT: usize = 3;
    /// A held piece is at least this many grid pixels (4 x 4 of 256 x 256): a phone held by a person a third of the
    /// frame tall is ~25.
    pub const HELD_MIN_PIXELS: usize = 16;
    /// A piece with more than this share in another person (`others`) is that person, not something held; one that
    /// touches another person (within `HELD_TOUCH`) is theirs too.
    pub const HELD_OTHER_SHARE: f64 = 0.3;
    /// A piece whose box is more than this many times as long as wide is a strip along the person, not something held.
    pub const HELD_MAX_ELONGATION: f64 = 4.0;
    /// A piece with more than this share of its outline within `HELD_TOUCH` of the answer is a gap the answer surrounds,
    /// not something held out of the hand.
    pub const HELD_MAX_ENCLOSED: f64 = 0.7;
    /// A piece with at least this share in the picked person's own Vision person mask (`own`) is a limb the answer left
    /// out, held however much the answer surrounds it.
    pub const HELD_OWN_SHARE: f64 = 0.6;
    /// A limb is at least this share of the answer's area and reaches the outline (enclosed at most
    /// `HELD_LIMB_MAX_ENCLOSED`).
    pub const HELD_LIMB_MIN_SHARE: f64 = 0.03;
    /// See `HELD_LIMB_MIN_SHARE`.
    pub const HELD_LIMB_MAX_ENCLOSED: f64 = 0.95;

    /// The compute units for this Mac, `None` = the model does not run here (Intel: no Neural Engine, GPUs too slow for
    /// it; the subject mask stays on the system's segmentation). Never "all devices": that plan was the slowest to load
    /// and no faster to run.
    pub fn compute(cpu_brand: &str, is_intel: bool, low_memory: bool) -> Option<SubjectTrackCompute> {
        if is_intel {
            return None;
        }
        if low_memory {
            return Some(SubjectTrackCompute::NeuralEngine);
        }
        let brand = cpu_brand.to_lowercase();
        for big in [" pro", " max", " ultra"] {
            if brand.contains(big) {
                return Some(SubjectTrackCompute::Gpu);
            }
        }
        Some(SubjectTrackCompute::NeuralEngine)
    }

    /// A frame point in the model's square.
    pub fn model_point(p: Vec2) -> (f64, f64) {
        (p.x * Self::MODEL_SIZE as f64, p.y * Self::MODEL_SIZE as f64)
    }

    /// A frame box in the model's square.
    pub fn model_box(b: &SubjectTrackBox) -> (f64, f64, f64, f64) {
        let s = Self::MODEL_SIZE as f64;
        (b.x0 * s, b.y0 * s, b.x1 * s, b.y1 * s)
    }

    /// The matte (`width` x `height`) of `size` x `size` logits: bilinear resample, then alpha from each pixel's
    /// distance to the edge (`edge_alpha`).
    pub fn matte(logits: &[f32], size: usize, width: usize, height: usize) -> SubjectMatte {
        assert!(logits.len() == size * size && width > 0 && height > 0, "logits size mismatch");
        let mut out = vec![0.0_f32; width * height];
        let sz = size as f64;
        // Column taps once per matte.
        let mut x0s = vec![0_usize; width];
        let mut x1s = vec![0_usize; width];
        let mut txs = vec![0.0_f32; width];
        for x in 0..width {
            let fx = ((x as f64 + 0.5) * sz / width as f64 - 0.5).clamp(0.0, sz - 1.0);
            x0s[x] = fx as usize;
            x1s[x] = (fx as usize + 1).min(size - 1);
            txs[x] = (fx - (fx as usize) as f64) as f32;
        }
        for y in 0..height {
            let fy = ((y as f64 + 0.5) * sz / height as f64 - 0.5).clamp(0.0, sz - 1.0);
            let r0 = fy as usize * size;
            let r1 = (fy as usize + 1).min(size - 1) * size;
            let ty = (fy - (fy as usize) as f64) as f32;
            for x in 0..width {
                let (a, b, c, d) = (logits[r0 + x0s[x]], logits[r0 + x1s[x]], logits[r1 + x0s[x]], logits[r1 + x1s[x]]);
                let top = a + (b - a) * txs[x];
                let bottom = c + (d - c) * txs[x];
                out[y * width + x] = top + (bottom - top) * ty;
            }
        }
        SubjectMatte::new(width, height, Self::edge_alpha(&out, width, height))
    }

    /// Alpha of a resampled logit plane: the pixel's signed distance to the edge (logit / slope, in pixels), mapped to
    /// 0...1 across `MATTE_EDGE_WIDTH`. Inside the mask alpha is 1 however weak the logits are; 0.5 stays where the
    /// logits cross 0. The slope is the central difference (one-sided, doubled, at the border).
    pub fn edge_alpha(v: &[f32], width: usize, height: usize) -> Vec<f32> {
        let mut out = vec![0.0_f32; v.len()];
        for y in 0..height {
            for x in 0..width {
                let i = y * width + x;
                let gx: f32 = if width < 2 {
                    0.0
                } else if x == 0 {
                    2.0 * (v[i + 1] - v[i])
                } else if x == width - 1 {
                    2.0 * (v[i] - v[i - 1])
                } else {
                    v[i + 1] - v[i - 1]
                };
                let gy: f32 = if height < 2 {
                    0.0
                } else if y == 0 {
                    2.0 * (v[i + width] - v[i])
                } else if y == height - 1 {
                    2.0 * (v[i] - v[i - width])
                } else {
                    v[i + width] - v[i - width]
                };
                let slope = ((gx * gx + gy * gy).sqrt() * 0.5).max(Self::MATTE_SLOPE_FLOOR);
                out[i] = (v[i] / slope * (1.0 / Self::MATTE_EDGE_WIDTH) + 0.5).clamp(0.0, 1.0);
            }
        }
        out
    }

    /// `size` x `size` logits of a matte (a mask the user corrected, a frame tracked before): the model's memory of a
    /// frame can be made from them. 0.5 is the edge; fully in or out is `MATTE_LOGIT`.
    pub fn logits_from(matte: &SubjectMatte, size: usize) -> Vec<f32> {
        let mut out = vec![-Self::MATTE_LOGIT; size * size];
        for y in 0..size {
            let py = (y as f64 + 0.5) * matte.height() as f64 / size as f64;
            for x in 0..size {
                let px = (x as f64 + 0.5) * matte.width() as f64 / size as f64;
                out[y * size + x] = (matte.sample_px(px, py) - 0.5) as f32 * 2.0 * Self::MATTE_LOGIT;
            }
        }
        out
    }

    /// Share of the frame the logits call subject (> 0) and the box around it; `box_` is `None` when nothing is.
    pub fn stats(logits: &[f32], size: usize) -> LogitStats {
        let (mut n, mut min_x, mut min_y, mut max_x, mut max_y) = (0_usize, size, size, -1_i64, -1_i64);
        for y in 0..size {
            let row = y * size;
            for x in 0..size {
                if logits[row + x] > 0.0 {
                    n += 1;
                    min_x = min_x.min(x);
                    max_x = max_x.max(x as i64);
                    min_y = min_y.min(y);
                    max_y = max_y.max(y as i64);
                }
            }
        }
        if n == 0 {
            return LogitStats { area: 0.0, box_: None };
        }
        let s = size as f64;
        LogitStats {
            area: n as f64 / (s * s),
            box_: Some(SubjectTrackBox::new(
                min_x as f64 / s,
                min_y as f64 / s,
                (max_x + 1) as f64 / s,
                (max_y + 1) as f64 / s,
            )),
        }
    }

    /// The box around the subject of a matte (values >= 0.5); `None` when it holds none.
    pub fn box_of(m: &SubjectMatte) -> Option<SubjectTrackBox> {
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (m.width(), m.height(), -1_i64, -1_i64);
        for y in 0..m.height() {
            let row = y * m.width();
            for x in 0..m.width() {
                if m.values[row + x] >= 0.5 {
                    min_x = min_x.min(x);
                    max_x = max_x.max(x as i64);
                    min_y = min_y.min(y);
                    max_y = max_y.max(y as i64);
                }
            }
        }
        if max_x < 0 {
            return None;
        }
        let (w, h) = (m.width() as f64, m.height() as f64);
        Some(SubjectTrackBox::new(min_x as f64 / w, min_y as f64 / h, (max_x + 1) as f64 / w, (max_y + 1) as f64 / h))
    }

    /// The matte on a grid of at most 256 px a side, `true` where it is >= 0.5.
    fn coarse_grid(m: &SubjectMatte) -> (Vec<bool>, usize, usize) {
        let side = 256;
        let (gw, gh) = (m.width().min(side), m.height().min(side));
        let mut grid = vec![false; gw * gh];
        for y in 0..gh {
            let sy = (((y as f64 + 0.5) * m.height() as f64 / gh as f64) as usize).min(m.height() - 1);
            for x in 0..gw {
                let sx = (((x as f64 + 0.5) * m.width() as f64 / gw as f64) as usize).min(m.width() - 1);
                if m.values[sy * m.width() + sx] >= 0.5 {
                    grid[y * gw + x] = true;
                }
            }
        }
        (grid, gw, gh)
    }

    /// Clears the 4-connected piece holding `start` in `grid` and returns its cell count and box (frame fractions).
    fn take_piece(grid: &mut [bool], gw: usize, gh: usize, start: usize) -> (usize, SubjectTrackBox) {
        let (mut count, mut min_x, mut min_y, mut max_x, mut max_y) = (0_usize, gw, gh, 0_usize, 0_usize);
        let mut stack = vec![start];
        grid[start] = false;
        while let Some(i) = stack.pop() {
            let (x, y) = (i % gw, i / gw);
            count += 1;
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
            let around = [
                (x as i64 - 1, y as i64),
                (x as i64 + 1, y as i64),
                (x as i64, y as i64 - 1),
                (x as i64, y as i64 + 1),
            ];
            for (nx, ny) in around {
                if nx >= 0
                    && (nx as usize) < gw
                    && ny >= 0
                    && (ny as usize) < gh
                    && grid[ny as usize * gw + nx as usize]
                {
                    grid[ny as usize * gw + nx as usize] = false;
                    stack.push(ny as usize * gw + nx as usize);
                }
            }
        }
        (
            count,
            SubjectTrackBox::new(
                min_x as f64 / gw as f64,
                min_y as f64 / gh as f64,
                (max_x + 1) as f64 / gw as f64,
                (max_y + 1) as f64 / gh as f64,
            ),
        )
    }

    /// The box of the connected piece of the matte (values >= 0.5, 4-connected, worked at <= 256 px) that holds the
    /// click, or the nearest piece when the click is off the subject; `None` for a matte with no subject. Unlike
    /// `box_of` it does not join a neighbor that only shares the matte.
    pub fn instance_box(m: &SubjectMatte, p: Vec2) -> Option<SubjectTrackBox> {
        let (mut grid, gw, gh) = Self::coarse_grid(m);
        if !grid.iter().any(|g| *g) {
            return None;
        }
        let cx = ((p.x * gw as f64) as i64).clamp(0, gw as i64 - 1);
        let cy = ((p.y * gh as f64) as i64).clamp(0, gh as i64 - 1);
        let mut seed = (cy as usize) * gw + cx as usize;
        if !grid[seed] {
            let mut best = i64::MAX;
            for (i, on) in grid.iter().enumerate() {
                if *on {
                    let dx = (i % gw) as i64 - cx;
                    let dy = (i / gw) as i64 - cy;
                    if dx * dx + dy * dy < best {
                        best = dx * dx + dy * dy;
                        seed = i;
                    }
                }
            }
        }
        Some(Self::take_piece(&mut grid, gw, gh, seed).1)
    }

    /// The box of a person whose label an occluder may have split: the piece under the click (`instance_box`) united
    /// with every other piece (values >= 0.5, 4-connected, worked at <= 256 px) of at least `min_share` of the biggest
    /// piece. Specks across the picture stay out; a head and a torso on either side of a table both stay in.
    pub fn pieces_box(m: &SubjectMatte, p: Vec2, min_share: f64) -> Option<SubjectTrackBox> {
        let click = Self::instance_box(m, p)?;
        let (mut grid, gw, gh) = Self::coarse_grid(m);
        let mut pieces: Vec<(usize, SubjectTrackBox)> = Vec::new();
        for start in 0..grid.len() {
            if grid[start] {
                pieces.push(Self::take_piece(&mut grid, gw, gh, start));
            }
        }
        let biggest = pieces.iter().map(|p| p.0).max().unwrap_or(0);
        let mut out = click;
        for piece in &pieces {
            if piece.0 as f64 >= min_share * biggest as f64 {
                out = SubjectTrackBox::new(
                    out.x0.min(piece.1.x0),
                    out.y0.min(piece.1.y0),
                    out.x1.max(piece.1.x1),
                    out.y1.max(piece.1.y1),
                );
            }
        }
        Some(out)
    }

    /// What `seen` holds that `first` does not, kept to the pixels inside `box_` (frame fractions): the area a second
    /// person-sized box clamped into `box_` can contain its point in.
    pub fn leftover(seen: &[f32], first: &[f32], box_: &SubjectTrackBox, size: usize) -> Vec<f32> {
        let mut out = vec![0.0_f32; size * size];
        for y in 0..size {
            let v = (y as f64 + 0.5) / size as f64;
            if !(v >= box_.y0 && v <= box_.y1) {
                continue;
            }
            for x in 0..size {
                let u = (x as f64 + 0.5) / size as f64;
                let i = y * size + x;
                if u >= box_.x0 && u <= box_.x1 && seen[i] > 0.0 && first[i] <= 0.0 {
                    out[i] = 1.0;
                }
            }
        }
        out
    }

    /// A box for the one person under the click when the person box may hold several (touching people): as tall as a
    /// share of the person box, a person's width, centered on the click, kept inside the person box and the frame.
    pub fn click_box(click: Vec2, person: &SubjectTrackBox) -> SubjectTrackBox {
        let h = person.height() * Self::CLICK_BOX_HEIGHT;
        let w = h * Self::CLICK_BOX_ASPECT;
        let place = |c: f64, size: f64, lo: f64, hi: f64| {
            let a = (c - size / 2.0).max(lo).min((hi - size).max(lo));
            (a, (a + size).min(hi))
        };
        let x = place(click.x, w, person.x0.max(0.0), person.x1.min(1.0));
        let y = place(click.y, h, person.y0.max(0.0), person.y1.min(1.0));
        SubjectTrackBox::new(x.0, y.0, x.1, y.1)
    }

    /// Whether the picked area (`seen`, logits) held several people: `first` is the model's mask for a person-sized box
    /// over the click (`click_box`), `second` its mask for another person-sized box over what is left of `seen`. True
    /// when the two are as large as each other (0.8 to 1.25 times), hardly touch (<= 8% of either) and together cover
    /// most of `seen` (>= 75%).
    pub fn holds_several_people(first: &[f32], second: &[f32], seen: &[f32], size: usize) -> bool {
        if first.len() != size * size || second.len() != size * size || seen.len() != size * size {
            return false;
        }
        let (mut a, mut b, mut both, mut union, mut area) = (0_usize, 0_usize, 0_usize, 0_usize, 0_usize);
        for i in 0..size * size {
            let (p, q) = (first[i] > 0.0, second[i] > 0.0);
            if p {
                a += 1;
            }
            if q {
                b += 1;
            }
            if p && q {
                both += 1;
            }
            if seen[i] > 0.0 {
                area += 1;
                if p || q {
                    union += 1;
                }
            }
        }
        if !(a > 0 && b > 0 && area > 0) {
            return false;
        }
        let ratio = b as f64 / a as f64;
        if !(0.8..=1.25).contains(&ratio) {
            return false;
        }
        if !(both as f64 / a as f64 <= 0.08 && both as f64 / b as f64 <= 0.08) {
            return false;
        }
        union as f64 >= 0.75 * area as f64
    }

    /// `box_` as the model's prompt: when it is much larger than the instance the click meant (`PROMPT_BOX_MAX_RATIO`),
    /// the instance's own bounds.
    pub fn prompt_box(box_: &SubjectTrackBox, instance: Option<&SubjectTrackBox>) -> SubjectTrackBox {
        match instance {
            Some(i) if i.area() > 0.0 && box_.area() > Self::PROMPT_BOX_MAX_RATIO * i.area() => *i,
            _ => *box_,
        }
    }

    /// What the person holds and the model's answer left out (a phone in the hand: Vision's person mask, so the
    /// person's box prompt, excludes it; the system's foreground segmentation `seen` holds it). The largest piece of
    /// `seen` outside `answer` (logit grids of `size`) that is more than an outline sliver (`HELD_EROSION`), is joined
    /// to the answer in `seen` and is at most `HELD_MAX_SHARE` of it; as logits (+`MATTE_LOGIT` in it), `None` when none.
    pub fn held_piece(seen: &[f32], answer: &[f32], size: usize) -> Option<Vec<f32>> {
        Self::held_pieces(seen, answer, size, 1, None, None).into_iter().next()
    }

    /// The pieces of `held_piece`, largest first, at most `limit` (each costs the leg one model call), none smaller than
    /// `HELD_MIN_PIXELS`; with `others` (the grid's pixels of people other than the picked one, > 0) none that is more
    /// than `HELD_OTHER_SHARE` in them; with `own` (the picked person's pixels, > 0) one at least `HELD_OWN_SHARE` in
    /// them passes the `HELD_MAX_ENCLOSED` rule.
    // Same as Swift (SubjectTrackRules.swift:358): at most `HELD_LIMIT` pieces per pick; raise it when a clip shows a person holding more.
    pub fn held_pieces(
        seen: &[f32],
        answer: &[f32],
        size: usize,
        limit: usize,
        others: Option<&[f32]>,
        own: Option<&[f32]>,
    ) -> Vec<Vec<f32>> {
        let n = size * size;
        if seen.len() != n || answer.len() != n {
            return Vec::new();
        }
        let (mut answer_area, mut x0, mut y0, mut x1, mut y1) = (0_usize, size, size, -1_i64, -1_i64);
        for y in 0..size {
            for x in 0..size {
                let i = y * size + x;
                if answer[i] > 0.0 {
                    answer_area += 1;
                } else if seen[i] > 0.0 {
                    x0 = x0.min(x);
                    x1 = x1.max(x as i64);
                    y0 = y0.min(y);
                    y1 = y1.max(y as i64);
                }
            }
        }
        if answer_area == 0 || x1 < 0 {
            return Vec::new();
        }
        // Everything below looks at most this far from a pixel of `rest`; the window's edge is the grid's or farther.
        let margin = Self::HELD_EROSION * 2 + Self::HELD_TOUCH + 1;
        let wx = x0.saturating_sub(margin);
        let wy = y0.saturating_sub(margin);
        let w = (x1 as usize + margin).min(size - 1) - wx + 1;
        let h = (y1 as usize + margin).min(size - 1) - wy + 1;
        let wn = w * h;
        let window = |grid: &[f32]| -> Vec<bool> {
            let mut out = vec![false; wn];
            for y in 0..h {
                for x in 0..w {
                    out[y * w + x] = grid[(wy + y) * size + wx + x] > 0.0;
                }
            }
            out
        };
        let in_answer = window(answer);
        let mut rest = window(seen);
        for i in 0..wn {
            if in_answer[i] {
                rest[i] = false;
            }
        }
        // Opened (eroded, then grown back inside `rest`): the outline slivers go, a piece keeps its own shape.
        let core = Self::square(&rest, w, h, Self::HELD_EROSION, true);
        let mut opened = Self::square(&core, w, h, Self::HELD_EROSION, false);
        let mut any = false;
        for i in 0..wn {
            if opened[i] {
                if rest[i] {
                    any = true;
                } else {
                    opened[i] = false;
                }
            }
        }
        if !any {
            return Vec::new();
        }
        let near = Self::square(&in_answer, w, h, Self::HELD_TOUCH, false);
        let flood = |start: usize, inside: &[bool], visited: &mut [bool]| -> Piece {
            let mut piece: Piece = Vec::new();
            let mut stack = vec![start];
            visited[start] = true;
            while let Some(i) = stack.pop() {
                piece.push(i);
                let (x, y) = (i % w, i / w);
                if x > 0 && inside[i - 1] && !visited[i - 1] {
                    visited[i - 1] = true;
                    stack.push(i - 1);
                }
                if x < w - 1 && inside[i + 1] && !visited[i + 1] {
                    visited[i + 1] = true;
                    stack.push(i + 1);
                }
                if y > 0 && inside[i - w] && !visited[i - w] {
                    visited[i - w] = true;
                    stack.push(i - w);
                }
                if y < h - 1 && inside[i + w] && !visited[i + w] {
                    visited[i + w] = true;
                    stack.push(i + w);
                }
            }
            piece
        };
        // Which parts of `rest` (with their slivers) reach the answer.
        let mut joined = vec![false; wn];
        let mut seen_rest = vec![false; wn];
        for start in 0..wn {
            if opened[start] && !seen_rest[start] {
                let part = flood(start, &rest, &mut seen_rest);
                if part.iter().any(|&i| near[i]) {
                    for i in part {
                        joined[i] = true;
                    }
                }
            }
        }
        let people = others.filter(|o| o.len() == n).map(window);
        let other_near = people.as_ref().map(|p| Self::square(p, w, h, Self::HELD_TOUCH, false));
        let mine = own.filter(|o| o.len() == n).map(window);
        let mut visited = vec![false; wn];
        let mut pieces: Vec<Piece> = Vec::new();
        for start in 0..wn {
            if !(opened[start] && joined[start] && !visited[start]) {
                continue;
            }
            let piece = flood(start, &opened, &mut visited);
            if piece.len() < Self::HELD_MIN_PIXELS || piece.len() as f64 > Self::HELD_MAX_SHARE * answer_area as f64 {
                continue;
            }
            let xs = piece.iter().map(|i| i % w);
            let ys = piece.iter().map(|i| i / w);
            let pw = (xs.clone().max().unwrap_or(0) - xs.min().unwrap_or(0) + 1) as f64;
            let ph = (ys.clone().max().unwrap_or(0) - ys.min().unwrap_or(0) + 1) as f64;
            if pw.max(ph) > Self::HELD_MAX_ELONGATION * pw.min(ph) {
                continue;
            }
            // A 4-neighbor in `opened` is in this piece (it is one 4-connected part of it); on the window's edge is on
            // the grid's (the margin).
            let outline: Vec<usize> = piece
                .iter()
                .copied()
                .filter(|&i| {
                    let (x, y) = (i % w, i / w);
                    x == 0
                        || y == 0
                        || x == w - 1
                        || y == h - 1
                        || !opened[i - 1]
                        || !opened[i + 1]
                        || !opened[i - w]
                        || !opened[i + w]
                })
                .collect();
            let enclosed = outline.iter().filter(|&&i| near[i]).count() as f64 / outline.len() as f64;
            let limb = mine.as_ref().is_some_and(|m| {
                piece.len() as f64 >= Self::HELD_LIMB_MIN_SHARE * answer_area as f64
                    && enclosed <= Self::HELD_LIMB_MAX_ENCLOSED
                    && piece.iter().filter(|&&i| m[i]).count() as f64 >= Self::HELD_OWN_SHARE * piece.len() as f64
            });
            if !(limb || enclosed <= Self::HELD_MAX_ENCLOSED) {
                continue;
            }
            if let Some(people) = &people
                && piece.iter().filter(|&&i| people[i]).count() as f64 > Self::HELD_OTHER_SHARE * piece.len() as f64
            {
                continue;
            }
            if let Some(other_near) = &other_near
                && piece.iter().any(|&i| other_near[i])
            {
                continue;
            }
            pieces.push(piece);
        }
        pieces.sort_by_key(|p| std::cmp::Reverse(p.len()));
        pieces
            .into_iter()
            .take(limit)
            .map(|piece| {
                let mut out = vec![-Self::MATTE_LOGIT; n];
                for i in piece {
                    out[(wy + i / w) * size + wx + i % w] = Self::MATTE_LOGIT;
                }
                out
            })
            .collect()
    }

    /// `answer` joined with the model's answer for a held piece (`object`), kept to the piece's box grown by half its
    /// size each way: `None` when that answer is not the piece (overlap below `HELD_AGREEMENT` outside `answer`).
    pub fn with_held(answer: &[f32], object: &[f32], piece: &[f32], size: usize) -> Option<Vec<f32>> {
        let n = size * size;
        if answer.len() != n || object.len() != n || piece.len() != n {
            return None;
        }
        let box_ = Self::stats(piece, size).box_?;
        let near =
            box_.grown((box_.width() / 2.0).max(2.0 / size as f64), (box_.height() / 2.0).max(2.0 / size as f64));
        let mut kept = object.to_vec();
        let (mut both, mut union) = (0_usize, 0_usize);
        for y in 0..size {
            let v = (y as f64 + 0.5) / size as f64;
            for x in 0..size {
                let i = y * size + x;
                let u = (x as f64 + 0.5) / size as f64;
                if !near.contains(Vec2::new(u, v)) {
                    kept[i] = kept[i].min(-Self::MATTE_LOGIT);
                    continue;
                }
                if answer[i] > 0.0 {
                    continue;
                }
                let (p, q) = (kept[i] > 0.0, piece[i] > 0.0);
                if p && q {
                    both += 1;
                }
                if p || q {
                    union += 1;
                }
            }
        }
        if !(union > 0 && both as f64 / union as f64 >= Self::HELD_AGREEMENT) {
            return None;
        }
        Some((0..n).map(|i| answer[i].max(kept[i])).collect())
    }

    /// Square neighborhood of `radius`: every pixel in it set (`all`, erosion) or any (dilation). Separable.
    fn square(m: &[bool], width: usize, height: usize, r: usize, all: bool) -> Vec<bool> {
        // A running count of set pixels over the 2r+1 window along each row, then each column (outside the grid counts
        // as unset).
        let full = 2 * r + 1;
        let pass = |src: &[bool], horizontal: bool| -> Vec<bool> {
            let mut out = vec![false; src.len()];
            let (lines, length) = if horizontal { (height, width) } else { (width, height) };
            for line in 0..lines {
                let (base, step) = if horizontal { (line * width, 1) } else { (line, width) };
                let mut count = 0_usize;
                for k in 0..r.min(length) {
                    if src[base + k * step] {
                        count += 1;
                    }
                }
                for k in 0..length {
                    let ahead = k + r;
                    if ahead < length && src[base + ahead * step] {
                        count += 1;
                    }
                    if k > r && src[base + (k - r - 1) * step] {
                        count -= 1;
                    }
                    out[base + k * step] = if all { count == full } else { count > 0 };
                }
            }
            out
        };
        pass(&pass(m, true), false)
    }

    /// A point on the subject of a matte (frame fractions): its pixel nearest to the center of mass, which need not lie
    /// on the subject itself (a ring, a person with arms out). `None` when the matte holds no subject.
    pub fn interior_point(m: &SubjectMatte) -> Option<Vec2> {
        let (mut n, mut sx, mut sy) = (0.0_f64, 0.0_f64, 0.0_f64);
        for y in 0..m.height() {
            for x in 0..m.width() {
                if m.values[y * m.width() + x] >= 0.5 {
                    n += 1.0;
                    sx += x as f64;
                    sy += y as f64;
                }
            }
        }
        if n <= 0.0 {
            return None;
        }
        let (cx, cy) = (sx / n, sy / n);
        let (mut best, mut bx, mut by) = (f64::INFINITY, 0_usize, 0_usize);
        for y in 0..m.height() {
            let dy = (y as f64 - cy) * (y as f64 - cy);
            if dy >= best {
                continue;
            }
            for x in 0..m.width() {
                if m.values[y * m.width() + x] >= 0.5 {
                    let d = dy + (x as f64 - cx) * (x as f64 - cx);
                    if d < best {
                        best = d;
                        bx = x;
                        by = y;
                    }
                }
            }
        }
        Some(Vec2::new((bx as f64 + 0.5) / m.width() as f64, (by as f64 + 0.5) / m.height() as f64))
    }

    /// The logit at frame fractions `p` (nearest texel).
    pub fn value(logits: &[f32], size: usize, p: Vec2) -> f32 {
        let x = ((p.x * size as f64) as i64).clamp(0, size as i64 - 1) as usize;
        let y = ((p.y * size as f64) as i64).clamp(0, size as i64 - 1) as usize;
        logits[y * size + x]
    }

    /// Intersection over union of two logit grids' subjects (> 0); 1 when both are empty.
    pub fn iou(a: &[f32], b: &[f32]) -> f64 {
        let (mut inter, mut union) = (0_usize, 0_usize);
        for i in 0..a.len().min(b.len()) {
            let (p, q) = (a[i] > 0.0, b[i] > 0.0);
            if p && q {
                inter += 1;
            }
            if p || q {
                union += 1;
            }
        }
        if union == 0 { 1.0 } else { inter as f64 / union as f64 }
    }

    /// A click without a box has three answers (part, object, whole). The rule for a pick: the largest of the candidates
    /// 1...3 the model itself rates at `floor` or better (the whole person, not the shirt); when it trusts none, the best
    /// rated one that is not empty. `areas` / `ious`: per mask token 0...3.
    pub fn largest_candidate(areas: &[f64], ious: &[f32], floor: f32) -> usize {
        let candidates: Vec<usize> = (1..=3).filter(|&i| i < areas.len() && i < ious.len() && areas[i] > 0.0).collect();
        let trusted: Vec<usize> = candidates.iter().copied().filter(|&i| ious[i] >= floor).collect();
        // Swift's `max(by:)` keeps the first of equal maxima.
        let first_max = |items: &[usize], key: &dyn Fn(usize) -> f64| -> Option<usize> {
            let mut best: Option<usize> = None;
            for &i in items {
                if best.is_none_or(|b| key(b) < key(i)) {
                    best = Some(i);
                }
            }
            best
        };
        if let Some(best) = first_max(&trusted, &|i| areas[i]) {
            return best;
        }
        first_max(&candidates, &|i| f64::from(ious[i])).unwrap_or(1)
    }
}

/// Says when a tracked frame no longer shows the subject. The model's own "object present" score never reported an
/// absent subject on the measured clips, so the mask itself is judged against the frames found before it:
/// - an empty mask is lost;
/// - a mask under `shrink` of the usual area (the median of the last found frames) is lost: the track holds on to a
///   scrap of the subject or of what hides it;
/// - a mask over `grow` times the usual area whose box hardly overlaps the last one is lost: it flooded the background;
/// - a mask far from where the subject was on the frame before is lost: it jumped to something that looks alike.
///
/// A lost frame does not move the reference, so the subject is found again when it looks as before. So that no run is
/// locked out for good (a subject that really did change at a cut inside the clip), an odd state that holds for
/// `settle` frames in a row is taken as the subject.
#[derive(Clone, Debug)]
pub struct SubjectLostRule {
    /// Share of the usual area under which a mask is lost.
    pub shrink: f64,
    /// Times the usual area over which (with little overlap) a mask is lost.
    pub grow: f64,
    /// Smallest box overlap with the last box.
    pub min_overlap: f64,
    /// Frames an odd state must hold to be taken.
    pub settle: usize,
    /// A mask under this share of the frame (49 of the 256 x 256 logit pixels) is lost, whatever the subject's usual
    /// size.
    pub tiny: f64,
    /// Distance from the frame edge that counts as touching it.
    pub edge: f64,
    /// Found areas the usual area is the median of.
    pub window: usize,
    areas: Vec<f64>,
    last: Option<SubjectTrackBox>,
    /// The frame before this one was found (only then a far jump says anything: after a gap the subject may be anywhere).
    last_found: bool,
    odd: Vec<(f64, SubjectTrackBox)>,
}

impl Default for SubjectLostRule {
    fn default() -> Self {
        SubjectLostRule {
            shrink: 0.25,
            grow: 4.0,
            min_overlap: 0.3,
            settle: 4,
            tiny: 49.0 / 65536.0,
            edge: 0.01,
            window: 5,
            areas: Vec::new(),
            last: None,
            last_found: false,
            odd: Vec::new(),
        }
    }
}

impl SubjectLostRule {
    /// Starts from a frame known to show the subject (the pick's frame).
    pub fn starting_at(area: f64, box_: SubjectTrackBox) -> SubjectLostRule {
        let mut r = SubjectLostRule::default();
        if area > 0.0 {
            r.areas = vec![area];
            r.last = Some(box_);
            r.last_found = true;
        }
        r
    }

    fn usual(&self) -> Option<f64> {
        if self.areas.is_empty() {
            return None;
        }
        let mut s = self.areas.clone();
        s.sort_by(f64::total_cmp);
        Some(s[s.len() / 2])
    }

    /// Judges the mask of the next frame (in tracking order): share of the frame it covers and its box.
    pub fn is_lost(&mut self, area: f64, box_: Option<SubjectTrackBox>) -> bool {
        let Some(box_) = box_.filter(|_| area > 0.0) else {
            self.odd.clear();
            self.last_found = false;
            return true;
        };
        if area < self.tiny {
            self.odd.clear();
            self.last_found = false;
            return true;
        }
        let (Some(usual), Some(last)) = (self.usual(), self.last) else {
            self.accept(area, box_);
            return false;
        };
        let ratio = area / usual;
        // A subject leaving through a frame edge shrinks for real: its mask is right, not lost.
        let leaving = self.last_found && Self::leaving(&last, &box_, self.edge);
        let mut suspicious =
            (ratio < self.shrink && !leaving) || (ratio > self.grow && box_.iou(&last) < self.min_overlap);
        if !suspicious && self.last_found {
            // Room to move in one frame: its own size and a good part of the frame.
            let reach = last.grown(last.width().max(0.15), last.height().max(0.15));
            suspicious = !reach.intersects(&box_);
        }
        if !suspicious {
            self.accept(area, box_);
            return false;
        }
        match self.odd.last() {
            Some(o) if area / o.0 > 0.5 && area / o.0 < 2.0 && box_.iou(&o.1) >= self.min_overlap => {
                self.odd.push((area, box_))
            }
            _ => self.odd = vec![(area, box_)],
        }
        if self.odd.len() >= self.settle {
            self.areas = self.odd.iter().map(|o| o.0).collect();
            self.last = Some(box_);
            self.last_found = true;
            self.odd.clear();
            return false;
        }
        self.last_found = false;
        true
    }

    /// Both boxes touch a common frame edge and the box moved toward it (its center by at least `edge`): a subject that
    /// sits at the edge and merely collapses is not leaving.
    fn leaving(a: &SubjectTrackBox, b: &SubjectTrackBox, edge: f64) -> bool {
        let dx = (b.x0 + b.x1 - a.x0 - a.x1) / 2.0;
        let dy = (b.y0 + b.y1 - a.y0 - a.y1) / 2.0;
        (a.x0 <= edge && b.x0 <= edge && dx <= -edge)
            || (a.x1 >= 1.0 - edge && b.x1 >= 1.0 - edge && dx >= edge)
            || (a.y0 <= edge && b.y0 <= edge && dy <= -edge)
            || (a.y1 >= 1.0 - edge && b.y1 >= 1.0 - edge && dy >= edge)
    }

    fn accept(&mut self, area: f64, box_: SubjectTrackBox) {
        self.areas.push(area);
        if self.areas.len() > self.window {
            let extra = self.areas.len() - self.window;
            self.areas.drain(..extra);
        }
        self.last = Some(box_);
        self.last_found = true;
        self.odd.clear();
    }
}

/// Which tracked frames enter the tracker's memory: a frame is stored only when at least `min_distance` frames have
/// passed since the last stored one AND its mask is certain (mean |p - 0.5| of the logits as probabilities is at least
/// `min_certainty`), so blurry or uncertain masks never enter. The conditioning (first prompt) entry is not part of this
/// gate: it always stays.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubjectMemoryGate {
    /// Frames between stored ones.
    pub min_distance: usize,
    /// Smallest certainty.
    pub min_certainty: f64,
    /// Frames seen since the last stored one (starts at "far enough": the first tracked frame may enter).
    since_last: usize,
}

impl Default for SubjectMemoryGate {
    /// The default admits every frame (distance 1, certainty 0): the behavior before the gate.
    fn default() -> Self {
        SubjectMemoryGate::new(1, 0.0)
    }
}

impl SubjectMemoryGate {
    /// A gate; `min_distance` is at least 1.
    pub fn new(min_distance: usize, min_certainty: f64) -> SubjectMemoryGate {
        let d = min_distance.max(1);
        SubjectMemoryGate { min_distance: d, min_certainty, since_last: d }
    }

    /// The tracker's setting, picked on the 13-clip mask benchmark (mean J&F 0.900 -> 0.905, no clip down by more than
    /// 0.004; certainty alone 0...0.48 changes nothing, 0.49 drops lindy-hop and walking).
    pub fn tracker() -> SubjectMemoryGate {
        SubjectMemoryGate::new(2, 0.45)
    }

    /// Mean of |sigmoid(logit) - 0.5| (0...0.5). 0 for no logits.
    pub fn certainty(logits: &[f32]) -> f64 {
        if logits.is_empty() {
            return 0.0;
        }
        let mut sum = 0.0_f64;
        for l in logits {
            sum += (1.0 / (1.0 + f64::from((-*l).exp())) - 0.5).abs();
        }
        let c = sum / logits.len() as f64;
        if c.is_nan() { 0.0 } else { c } // NaN logits count as uncertain (0), so certainty 0 still admits
    }

    /// Counts one tracked frame; true when it enters the memory (and restarts the distance).
    pub fn admit(&mut self, logits: &[f32]) -> bool {
        if !(self.since_last >= self.min_distance && Self::certainty(logits) >= self.min_certainty) {
            self.since_last += 1;
            return false;
        }
        self.since_last = 1;
        true
    }

    /// Back to "the next frame may enter" (a new conditioning frame).
    pub fn reset(&mut self) {
        self.since_last = self.min_distance;
    }
}

/// How many frames in a row the model calls empty enter its memory. The reference tracker remembers every one: once the
/// subject was out of view longer than the recent-frame memory (six slots), that memory holds only empty frames and the
/// model goes on answering "empty" after the subject is back. Remembering only the first `limit` keeps frames with the
/// subject in the memory, so it is found again when it returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SubjectAbsenceMemory {
    /// Empty frames remembered in a row.
    pub limit: usize,
    run: usize,
}

impl Default for SubjectAbsenceMemory {
    /// The default remembers every empty frame (the behavior before this rule).
    fn default() -> Self {
        SubjectAbsenceMemory::new(usize::MAX)
    }
}

impl SubjectAbsenceMemory {
    /// A memory rule.
    pub fn new(limit: usize) -> SubjectAbsenceMemory {
        SubjectAbsenceMemory { limit, run: 0 }
    }

    /// The tracker's setting, picked on the mask benchmark's recovery scenarios.
    pub fn tracker() -> SubjectAbsenceMemory {
        SubjectAbsenceMemory::new(2)
    }

    /// Counts one frame the model called empty; true when it enters the memory.
    pub fn admits_empty(&mut self) -> bool {
        if self.run < self.limit {
            self.run += 1;
            return true;
        }
        false
    }

    /// A frame with the subject on it (tracked or conditioned): the count starts over.
    pub fn found(&mut self) {
        self.run = 0;
    }
}

/// After a gap (at least `after_lost` frames in a row lost) a mask the model is not sure of (score under `min_score`) is
/// a re-acquisition only once it holds still: `settle` weak masks in a row, each within `area_tolerance` of the one
/// before in area and overlapping it by `min_overlap` (box IoU). Until then the frame stays lost and out of the memory.
#[derive(Clone, Copy, Debug)]
pub struct SubjectReacquireRule {
    /// Scores at or above this are taken at once.
    pub min_score: f32,
    /// Lost frames in a row before the rule applies.
    pub after_lost: usize,
    /// Weak masks in a row needed.
    pub settle: usize,
    /// Allowed area change between them.
    pub area_tolerance: f64,
    /// Box overlap needed between them.
    pub min_overlap: f64,
    steady: usize,
    last: Option<(f64, SubjectTrackBox)>,
}

/// Equality ignores the running state, like the Swift `==`.
impl PartialEq for SubjectReacquireRule {
    fn eq(&self, a: &Self) -> bool {
        a.min_score == self.min_score
            && a.after_lost == self.after_lost
            && a.settle == self.settle
            && a.area_tolerance == self.area_tolerance
            && a.min_overlap == self.min_overlap
    }
}

impl SubjectReacquireRule {
    /// A rule; `after_lost` and `settle` are at least 1.
    pub fn new(
        min_score: f32,
        after_lost: usize,
        settle: usize,
        area_tolerance: f64,
        min_overlap: f64,
    ) -> SubjectReacquireRule {
        SubjectReacquireRule {
            min_score,
            after_lost: after_lost.max(1),
            settle: settle.max(1),
            area_tolerance,
            min_overlap,
            steady: 0,
            last: None,
        }
    }

    /// Off: every mask is taken as before this rule.
    pub fn off() -> SubjectReacquireRule {
        SubjectReacquireRule::new(f32::NEG_INFINITY, 1, 1, 0.15, 0.6)
    }

    /// The tracker's setting, picked on the mask benchmark's recovery scenarios.
    pub fn tracker() -> SubjectReacquireRule {
        SubjectReacquireRule::new(2.0, 3, 3, 0.15, 0.6)
    }

    /// True when a mask the model scored `score` (its area and box in frame fractions) may be taken after `lost_run`
    /// lost frames in a row.
    pub fn accepts(&mut self, score: f32, area: f64, box_: SubjectTrackBox, lost_run: usize) -> bool {
        if lost_run < self.after_lost || score >= self.min_score {
            self.empty();
            return true;
        }
        match self.last {
            Some(l)
                if l.0 > 0.0
                    && (area / l.0 - 1.0).abs() <= self.area_tolerance
                    && l.1.iou(&box_) >= self.min_overlap =>
            {
                self.steady += 1;
            }
            _ => self.steady = 1,
        }
        self.last = Some((area, box_));
        self.steady >= self.settle
    }

    /// A frame without a mask: a weak mask after it starts the count over.
    pub fn empty(&mut self) {
        self.steady = 0;
        self.last = None;
    }
}

/// A click made on a tracked frame (a correction) refines the tracked mask, it does not swap it for another one: a mask
/// that already answers the clicks stays as it is, else the model's answer that answers them and changes the tracked
/// mask least is taken.
pub struct SubjectCorrectionRule;

impl SubjectCorrectionRule {
    /// Share of the tracked mask an added click must keep (it adds, it does not move the mask).
    pub const KEEPS: f64 = 0.8;
    /// Share of a removed click's answer that must lie on the tracked mask (it cuts, it does not move the mask).
    pub const INSIDE: f64 = 0.8;
    /// An added click grows the mask at most this much (area).
    pub const GROW_LIMIT: f64 = 2.0;
    /// A removed click shrinks the mask at most to this share.
    pub const SHRINK_FLOOR: f64 = 0.25;

    /// Whether the mask (logits, > 0 = subject) has every added point on it and every removed point off it. False for no
    /// points.
    pub fn answers(points: &[MagicPoint], logits: &[f32], size: usize) -> bool {
        if points.is_empty() || logits.len() != size * size {
            return false;
        }
        points.iter().all(|p| (SubjectTrackRules::value(logits, size, p.position) > 0.0) != p.subtract)
    }

    /// The same for a matte (>= 0.5 = subject, nearest pixel).
    pub fn answers_matte(points: &[MagicPoint], m: &SubjectMatte) -> bool {
        if points.is_empty() {
            return false;
        }
        points.iter().all(|p| {
            let x = ((p.position.x * m.width() as f64) as i64).clamp(0, m.width() as i64 - 1) as usize;
            let y = ((p.position.y * m.height() as f64) as i64).clamp(0, m.height() as i64 - 1) as usize;
            (m.values[y * m.width() + x] >= 0.5) != p.subtract
        })
    }

    /// Index of the candidate (logits, the model's best rated first) that answers `points` and refines `tracked`: added
    /// points keep `KEEPS` of it and grow it at most `GROW_LIMIT`, removed points stay `INSIDE` it and leave at least
    /// `SHRINK_FLOOR`; of those the one closest to `tracked` (IoU). A lost frame (`tracked` empty): the first that
    /// answers. `None` when none does.
    pub fn refinement(candidates: &[Vec<f32>], tracked: &[f32], points: &[MagicPoint], size: usize) -> Option<usize> {
        let tracked_area = tracked.iter().filter(|v| **v > 0.0).count();
        let adds = points.iter().any(|p| !p.subtract);
        let removes = points.iter().any(|p| p.subtract);
        let mut best: Option<(usize, f64)> = None;
        for (index, c) in candidates.iter().enumerate() {
            if c.len() != tracked.len() || !Self::answers(points, c, size) {
                continue;
            }
            let (mut both, mut area) = (0_usize, 0_usize);
            for i in 0..c.len() {
                if c[i] > 0.0 {
                    area += 1;
                    if tracked[i] > 0.0 {
                        both += 1;
                    }
                }
            }
            if area == 0 {
                continue;
            }
            if tracked_area == 0 {
                return Some(index);
            }
            let (t, a, b) = (tracked_area as f64, area as f64, both as f64);
            if adds && (b / t < Self::KEEPS || a > Self::GROW_LIMIT * t) {
                continue;
            }
            if removes && (b / a < Self::INSIDE || a < Self::SHRINK_FLOOR * t) {
                continue;
            }
            let iou = b / (t + a - b);
            if best.is_none_or(|bst| iou > bst.1) {
                best = Some((index, iou));
            }
        }
        best.map(|b| b.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bx(x0: f64, y0: f64, x1: f64, y1: f64) -> SubjectTrackBox {
        SubjectTrackBox::new(x0, y0, x1, y1)
    }

    /// A square of logits: +8 inside the box (fractions), -8 outside.
    fn logits(b: &SubjectTrackBox, size: usize) -> Vec<f32> {
        let mut out = vec![-8.0_f32; size * size];
        for y in 0..size {
            for x in 0..size {
                let u = (x as f64 + 0.5) / size as f64;
                let v = (y as f64 + 0.5) / size as f64;
                if u >= b.x0 && u <= b.x1 && v >= b.y0 && v <= b.y1 {
                    out[y * size + x] = 8.0;
                }
            }
        }
        out
    }

    fn l64(b: &SubjectTrackBox) -> Vec<f32> {
        logits(b, 64)
    }

    #[test]
    fn pro_and_max_chips_use_the_gpu_others_the_neural_engine_intel_nothing() {
        let c = SubjectTrackRules::compute;
        assert_eq!(c("Apple M1 Pro", false, false), Some(SubjectTrackCompute::Gpu));
        assert_eq!(c("Apple M3 Max", false, false), Some(SubjectTrackCompute::Gpu));
        assert_eq!(c("Apple M2 Ultra", false, false), Some(SubjectTrackCompute::Gpu));
        assert_eq!(c("Apple M2", false, false), Some(SubjectTrackCompute::NeuralEngine));
        assert_eq!(c("", false, false), Some(SubjectTrackCompute::NeuralEngine));
        assert_eq!(c("Apple M1 Pro", false, true), Some(SubjectTrackCompute::NeuralEngine));
        assert_eq!(c("Intel(R) Core(TM) i9", true, false), None);
    }

    #[test]
    fn the_frame_is_stretched_onto_the_model_square() {
        let p = SubjectTrackRules::model_point(Vec2::new(0.25, 0.5));
        assert!(p.0 == 256.0 && p.1 == 512.0);
        let b = SubjectTrackRules::model_box(&bx(0.1, 0.2, 0.5, 1.0));
        assert!((b.0 - 102.4).abs() < 1e-9 && (b.1 - 204.8).abs() < 1e-9 && b.2 == 512.0 && b.3 == 1024.0);
    }

    #[test]
    fn logits_become_a_matte_of_the_frame_size_and_back() {
        let b = bx(0.25, 0.5, 0.75, 1.0);
        let m = SubjectTrackRules::matte(&l64(&b), 64, 160, 90);
        assert!(m.width() == 160 && m.height() == 90);
        assert!(m.values[60 * 160 + 80] > 0.99);
        assert!(m.values[10 * 160 + 80] < 0.01);
        assert!(m.values[60 * 160 + 10] < 0.01);
        let found = SubjectTrackRules::box_of(&m).unwrap_or(bx(9.0, 9.0, 9.0, 9.0));
        assert!(
            (found.x0 - 0.25).abs() < 0.02
                && (found.x1 - 0.75).abs() < 0.02
                && (found.y0 - 0.5).abs() < 0.02
                && found.y1 > 0.98
        );
        let back = SubjectTrackRules::logits_from(&m, 64);
        assert!(SubjectTrackRules::iou(&back, &l64(&b)) > 0.95);
        assert!(back.iter().all(|v| (-10.0..=10.0).contains(v)));
    }

    /// A weak answer of the model (logits of +-0.6) is solid inside the mask and soft only in a thin band at its edge,
    /// which stays where the logits cross 0.
    #[test]
    fn a_weak_mask_is_solid_inside_and_soft_only_at_its_edge() {
        let (size, px) = (64, 256);
        let mut l = vec![-0.6_f32; size * size];
        for y in 16..48 {
            for x in 16..48 {
                l[y * size + x] = 0.6;
            }
        }
        for y in 52..60 {
            for x in 0..size {
                l[y * size + x] = -1.0;
            }
        }
        for y in 52..60 {
            l[y * size + 40] = 1.0;
        }
        let m = SubjectTrackRules::matte(&l, size, px, px);
        let row = 128 * px;
        assert!(m.values[row + 63] < 0.5 && m.values[row + 64] > 0.5);
        for x in 0..px {
            let d = if x < 128 { x as f64 - 63.5 } else { 191.5 - x as f64 };
            if d >= 2.0 {
                assert!(m.values[row + x] >= 0.99, "x {x}: {}", m.values[row + x]);
            }
            if d <= -2.0 {
                assert!(m.values[row + x] <= 0.01, "x {x}: {}", m.values[row + x]);
            }
        }
        assert!(m.values[56 * 4 * px + 40 * 4 + 1] >= 0.99 && m.values[56 * 4 * px + 40 * 4 + 2] >= 0.99);
        let sure = SubjectTrackRules::matte(&l64(&bx(0.25, 0.25, 0.75, 0.75)), 64, px, px);
        assert!(sure.values[row + 128] == 1.0 && sure.values[row + 10] == 0.0);
    }

    #[test]
    fn stats_of_logits_give_area_and_box() {
        let s = SubjectTrackRules::stats(&l64(&bx(0.0, 0.0, 0.5, 0.5)), 64);
        assert!((s.area - 0.25).abs() < 1e-9);
        assert_eq!(s.box_, Some(bx(0.0, 0.0, 0.5, 0.5)));
        let none = SubjectTrackRules::stats(&vec![-3.0; 64 * 64], 64);
        assert!(none.area == 0.0 && none.box_.is_none());
        assert!(SubjectTrackRules::box_of(&SubjectMatte::new(1, 1, vec![0.0])).is_none());
    }

    #[test]
    fn the_interior_point_lies_on_the_subject_even_when_the_centroid_does_not() {
        let mut v = vec![0.0_f32; 40 * 40];
        for y in 8..32 {
            for x in 8..32 {
                if !((14..26).contains(&x) && (14..26).contains(&y)) {
                    v[y * 40 + x] = 1.0;
                }
            }
        }
        let m = SubjectMatte::new(40, 40, v);
        let p = SubjectTrackRules::interior_point(&m).unwrap_or(Vec2::ZERO);
        assert_eq!(m.values[((p.y * 40.0) as usize).min(39) * 40 + ((p.x * 40.0) as usize).min(39)], 1.0);
        assert!(SubjectTrackRules::interior_point(&SubjectMatte::new(2, 2, vec![0.0; 4])).is_none());
    }

    #[test]
    fn the_largest_trusted_candidate_wins_else_the_best_rated() {
        let f = |a: &[f64], i: &[f32]| SubjectTrackRules::largest_candidate(a, i, 0.6);
        assert_eq!(f(&[0.9, 0.1, 0.3, 0.2], &[0.9, 0.9, 0.7, 0.8]), 2);
        assert_eq!(f(&[0.9, 0.1, 0.3, 0.2], &[0.9, 0.9, 0.5, 0.8]), 3);
        assert_eq!(f(&[0.0, 0.1, 0.3, 0.2], &[0.0, 0.4, 0.5, 0.3]), 2);
        assert_eq!(f(&[0.0, 0.0, 0.0, 0.2], &[0.0, 0.9, 0.9, 0.2]), 3);
    }

    #[test]
    fn boxes_overlap_and_contain() {
        let (a, b) = (bx(0.0, 0.0, 0.5, 0.5), bx(0.25, 0.0, 0.75, 0.5));
        assert!((a.iou(&b) - 1.0 / 3.0).abs() < 1e-9);
        assert!(a.contains(Vec2::new(0.1, 0.4)) && !a.contains(Vec2::new(0.6, 0.4)));
        assert_eq!(a.iou(&bx(0.6, 0.6, 0.7, 0.7)), 0.0);
    }

    fn sq(cx: f64, cy: f64, side: f64) -> SubjectTrackBox {
        bx(cx - side / 2.0, cy - side / 2.0, cx + side / 2.0, cy + side / 2.0)
    }

    #[test]
    fn a_steady_subject_is_never_lost() {
        let mut rule = SubjectLostRule::default();
        for i in 0..40 {
            let side = 0.2 + f64::from(i) * 0.005;
            assert!(!rule.is_lost(side * side, Some(sq(0.3 + f64::from(i) * 0.01, 0.5, side))));
        }
    }

    #[test]
    fn an_empty_mask_is_lost_and_the_subject_comes_back_anywhere() {
        let mut rule = SubjectLostRule::default();
        assert!(!rule.is_lost(0.04, Some(sq(0.2, 0.5, 0.2))));
        assert!(rule.is_lost(0.0, None));
        assert!(rule.is_lost(0.0, None));
        assert!(!rule.is_lost(0.04, Some(sq(0.8, 0.5, 0.2))));
    }

    #[test]
    fn a_mask_that_collapses_is_lost_until_it_is_back() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.04, Some(sq(0.5, 0.5, 0.2))));
        }
        assert!(rule.is_lost(0.004, Some(sq(0.5, 0.5, 0.06))));
        assert!(rule.is_lost(0.001, Some(sq(0.55, 0.5, 0.03))));
        assert!(!rule.is_lost(0.035, Some(sq(0.52, 0.5, 0.19))));
    }

    #[test]
    fn a_mask_that_floods_the_frame_is_lost() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.04, Some(sq(0.5, 0.5, 0.2))));
        }
        assert!(rule.is_lost(0.9, Some(bx(0.0, 0.0, 1.0, 1.0))));
        assert!(!rule.is_lost(0.045, Some(sq(0.5, 0.5, 0.21))));
    }

    #[test]
    fn a_jump_to_another_place_on_the_next_frame_is_lost() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.01, Some(sq(0.2, 0.2, 0.1))));
        }
        assert!(rule.is_lost(0.01, Some(sq(0.8, 0.8, 0.1))));
        assert!(!rule.is_lost(0.01, Some(sq(0.22, 0.2, 0.1))));
    }

    #[test]
    fn a_new_state_that_holds_is_accepted_after_a_few_frames() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.04, Some(sq(0.5, 0.5, 0.2))));
        }
        let mut lost = 0;
        for _ in 0..rule.settle - 1 {
            if rule.is_lost(0.005, Some(sq(0.5, 0.5, 0.07))) {
                lost += 1;
            }
        }
        assert_eq!(lost, rule.settle - 1);
        assert!(!rule.is_lost(0.005, Some(sq(0.5, 0.5, 0.07))));
    }

    #[test]
    fn flicker_does_not_settle() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.04, Some(sq(0.5, 0.5, 0.2))));
        }
        for i in 0..12 {
            let odd = if i % 2 == 0 { sq(0.1, 0.1, 0.03) } else { sq(0.9, 0.9, 0.05) };
            assert!(rule.is_lost(odd.area(), Some(odd)));
        }
    }

    #[test]
    fn a_rule_started_from_a_reference_judges_the_first_frame() {
        let mut rule = SubjectLostRule::starting_at(0.04, sq(0.5, 0.5, 0.2));
        assert!(rule.is_lost(0.0005, Some(sq(0.5, 0.5, 0.02))));
        assert!(!rule.is_lost(0.04, Some(sq(0.5, 0.5, 0.2))));
    }

    fn matte_of(boxes: &[SubjectTrackBox], size: usize) -> SubjectMatte {
        let mut v = vec![0.0_f32; size * size];
        for y in 0..size {
            for x in 0..size {
                let u = (x as f64 + 0.5) / size as f64;
                let w = (y as f64 + 0.5) / size as f64;
                if boxes.iter().any(|b| u >= b.x0 && u <= b.x1 && w >= b.y0 && w <= b.y1) {
                    v[y * size + x] = 1.0;
                }
            }
        }
        SubjectMatte::new(size, size, v)
    }

    #[test]
    fn instance_box_is_the_component_under_the_click_not_the_union_of_neighbors() {
        let (a, b) = (bx(0.1, 0.2, 0.3, 0.8), bx(0.6, 0.3, 0.9, 0.7));
        let m = matte_of(&[a, b], 100);
        let got = SubjectTrackRules::instance_box(&m, Vec2::new(0.2, 0.5)).unwrap_or(a.grown(9.0, 9.0));
        assert!(
            (got.x0 - 0.1).abs() < 0.02
                && (got.x1 - 0.3).abs() < 0.02
                && (got.y0 - 0.2).abs() < 0.02
                && (got.y1 - 0.8).abs() < 0.02
        );
        let other = SubjectTrackRules::instance_box(&m, Vec2::new(0.75, 0.5)).unwrap_or(a.grown(9.0, 9.0));
        assert!((other.x0 - 0.6).abs() < 0.02 && (other.x1 - 0.9).abs() < 0.02);
        assert!(SubjectTrackRules::box_of(&m).is_some_and(|u| u.area() > a.area() + b.area()));
    }

    #[test]
    fn instance_box_takes_the_nearest_component_when_the_click_misses_and_none_when_empty() {
        let m = matte_of(&[bx(0.1, 0.1, 0.2, 0.2)], 100);
        let got = SubjectTrackRules::instance_box(&m, Vec2::new(0.23, 0.15)).unwrap_or(bx(9.0, 9.0, 9.0, 9.0));
        assert!((got.x1 - 0.2).abs() < 0.02);
        assert!(SubjectTrackRules::instance_box(&matte_of(&[], 100), Vec2::new(0.5, 0.5)).is_none());
    }

    #[test]
    fn a_prompt_box_much_larger_than_its_instance_is_shrunk_to_the_instance() {
        let instance = bx(0.4, 0.2, 0.6, 0.8);
        let big = bx(0.2, 0.1, 0.8, 0.9);
        assert_eq!(SubjectTrackRules::prompt_box(&big, Some(&instance)), instance);
        let close = bx(0.38, 0.18, 0.62, 0.82);
        assert_eq!(SubjectTrackRules::prompt_box(&close, Some(&instance)), close);
        assert_eq!(SubjectTrackRules::prompt_box(&big, None), big);
    }

    /// Logit grids (256) of a person and of what the system's segmentation saw: the person plus `extra` boxes.
    fn held(extra: &[SubjectTrackBox], person: SubjectTrackBox) -> (Vec<f32>, Vec<f32>) {
        let answer = logits(&person, 256);
        let mut seen = answer.clone();
        for b in extra {
            for (i, v) in logits(b, 256).iter().enumerate() {
                if *v > 0.0 {
                    seen[i] = *v;
                }
            }
        }
        (answer, seen)
    }

    fn person() -> SubjectTrackBox {
        bx(0.4, 0.2, 0.6, 0.8)
    }
    fn phone() -> SubjectTrackBox {
        bx(0.6, 0.45, 0.64, 0.53)
    }
    fn stats_box(l: &[f32]) -> SubjectTrackBox {
        SubjectTrackRules::stats(l, 256).box_.unwrap_or(bx(9.0, 9.0, 9.0, 9.0))
    }
    fn carve(answer: &mut [f32], b: &SubjectTrackBox) {
        for (i, v) in logits(b, 256).iter().enumerate() {
            if *v > 0.0 {
                answer[i] = -SubjectTrackRules::MATTE_LOGIT;
            }
        }
    }

    #[test]
    fn a_held_object_the_segmentation_saw_next_to_the_answer_is_its_held_piece() {
        let (answer, seen) = held(&[phone()], person());
        let piece = SubjectTrackRules::held_piece(&seen, &answer, 256).unwrap_or_default();
        let b = stats_box(&piece);
        assert!(
            (b.x0 - 0.6).abs() < 0.01
                && (b.x1 - 0.64).abs() < 0.01
                && (b.y0 - 0.45).abs() < 0.01
                && (b.y1 - 0.53).abs() < 0.01
        );
        let cup = bx(0.36, 0.5, 0.4, 0.55);
        let both = held(&[phone(), cup], person());
        let pieces = SubjectTrackRules::held_pieces(&both.1, &both.0, 256, SubjectTrackRules::HELD_LIMIT, None, None);
        assert_eq!(pieces.len(), 2);
        assert!(stats_box(&pieces[0]).x0 > 0.55);
        assert!(stats_box(&pieces[1]).x1 < 0.45);
        assert_eq!(SubjectTrackRules::held_pieces(&both.1, &both.0, 256, 1, None, None).len(), 1);
    }

    #[test]
    fn outline_slivers_neighbors_and_objects_apart_are_no_held_piece() {
        let none = |h: &(Vec<f32>, Vec<f32>)| SubjectTrackRules::held_piece(&h.1, &h.0, 256).is_none();
        assert!(none(&held(&[bx(0.396, 0.196, 0.604, 0.804)], person())));
        assert!(none(&held(&[bx(0.6, 0.2, 0.8, 0.8)], person())));
        assert!(none(&held(&[bx(0.66, 0.45, 0.7, 0.53)], person())));
        assert!(none(&held(&[], person())));
        assert!(none(&held(&[bx(0.6, 0.5, 0.606, 0.506)], person())));
        assert!(none(&held(&[bx(0.6, 0.5, 0.6 + 3.0 / 256.0, 0.5 + 3.0 / 256.0)], person())));
        let far = held(&[bx(0.56, 0.5, 0.56 + 5.0 / 256.0, 0.5 + 5.0 / 256.0)], bx(0.5, 0.4, 0.56, 0.6));
        assert!(!none(&far));
    }

    #[test]
    fn a_piece_of_another_person_is_no_held_piece() {
        let arm = bx(0.6, 0.6, 0.68, 0.66);
        let (answer, seen) = held(&[phone(), arm], person());
        assert_eq!(SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, None, None).len(), 2);
        let others = logits(&bx(0.6, 0.58, 0.9, 0.9), 256);
        let pieces = SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, Some(&others), None);
        assert_eq!(pieces.len(), 1);
        assert!((stats_box(&pieces[0]).y0 - 0.45).abs() < 0.01);
        let beside = logits(&bx(0.685, 0.58, 0.9, 0.9), 256);
        assert_eq!(SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, Some(&beside), None).len(), 1);
    }

    #[test]
    fn a_gap_the_answer_surrounds_is_no_held_piece() {
        let (mut answer, seen) = held(&[phone()], person());
        carve(&mut answer, &bx(0.48, 0.4, 0.52, 0.46));
        carve(&mut answer, &bx(0.4, 0.6, 0.44, 0.64));
        let pieces = SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, None, None);
        assert_eq!(pieces.len(), 1);
        assert!((stats_box(&pieces[0]).y0 - 0.45).abs() < 0.01);
    }

    #[test]
    fn a_limb_of_the_picked_person_the_answer_left_out_is_a_held_piece_though_the_answer_surrounds_it() {
        let (mut answer, seen) = held(&[], person());
        let limb = bx(0.4, 0.4, 0.56, 0.5);
        carve(&mut answer, &limb);
        assert!(SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, None, None).is_empty());
        let own = logits(&bx(0.39, 0.19, 0.61, 0.81), 256);
        let pieces = SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, None, Some(&own));
        assert_eq!(pieces.len(), 1);
        let b = stats_box(&pieces[0]);
        assert!((b.x0 - 0.4).abs() < 0.01 && (b.y0 - 0.4).abs() < 0.01 && (b.x1 - 0.56).abs() < 0.01);
        let mut gapless = own.clone();
        carve(&mut gapless, &limb);
        assert!(SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, None, Some(&gapless)).is_empty());
        let mut holes = held(&[], person());
        for b in [bx(0.45, 0.3, 0.55, 0.36), bx(0.4, 0.6, 0.42, 0.63)] {
            carve(&mut holes.0, &b);
        }
        assert!(SubjectTrackRules::held_pieces(&holes.1, &holes.0, 256, 3, None, Some(&own)).is_empty());
    }

    #[test]
    fn a_long_strip_is_no_held_piece() {
        let strip = bx(0.6, 0.2, 0.616, 0.4);
        let (answer, seen) = held(&[phone(), strip], person());
        let pieces = SubjectTrackRules::held_pieces(&seen, &answer, 256, 3, None, None);
        assert_eq!(pieces.len(), 1);
        assert!((stats_box(&pieces[0]).y0 - 0.45).abs() < 0.01);
    }

    #[test]
    fn the_models_answer_for_a_held_piece_is_kept_near_the_piece_and_joins_the_answer() {
        let (answer, seen) = held(&[phone()], person());
        let piece = SubjectTrackRules::held_piece(&seen, &answer, 256).unwrap_or_default();
        let mut object = logits(&bx(0.6, 0.44, 0.645, 0.54), 256);
        for (i, v) in logits(&bx(0.05, 0.05, 0.15, 0.15), 256).iter().enumerate() {
            if *v > 0.0 {
                object[i] = *v;
            }
        }
        let joined = SubjectTrackRules::with_held(&answer, &object, &piece, 256).unwrap_or_default();
        let b = stats_box(&joined);
        assert!((b.x0 - 0.4).abs() < 0.01 && (b.x1 - 0.645).abs() < 0.01 && b.y0 > 0.19);
        assert!(SubjectTrackRules::with_held(&answer, &answer, &piece, 256).is_none());
        assert!(SubjectTrackRules::with_held(&answer, &vec![-8.0; 256 * 256], &piece, 256).is_none());
    }

    #[test]
    fn click_box_is_person_sized_centered_on_the_click_and_inside_the_person_box() {
        let p = bx(0.3, 0.1, 0.7, 0.9);
        let b = SubjectTrackRules::click_box(Vec2::new(0.4, 0.5), &p);
        assert!((b.height() - 0.8 * SubjectTrackRules::CLICK_BOX_HEIGHT).abs() < 1e-9);
        assert!((b.width() - b.height() * SubjectTrackRules::CLICK_BOX_ASPECT).abs() < 1e-9);
        assert!(((b.x0 + b.x1) / 2.0 - 0.4).abs() < 1e-9);
        let e = SubjectTrackRules::click_box(Vec2::new(0.31, 0.12), &p);
        assert!(e.x0 >= p.x0 && e.y0 >= p.y0 && e.x1 <= p.x1 && e.y1 <= p.y1);
    }

    #[test]
    fn two_touching_people_are_told_from_one_wide_person() {
        let one = bx(0.47, 0.12, 0.6, 0.83);
        let other = bx(0.34, 0.12, 0.47, 0.8);
        let seen = l64(&bx(0.34, 0.12, 0.6, 0.83));
        let f = SubjectTrackRules::holds_several_people;
        assert!(f(&l64(&one), &l64(&other), &seen, 64));
        assert!(!f(&l64(&one), &l64(&one), &seen, 64));
        let wide = l64(&bx(0.1, 0.12, 0.6, 0.83));
        assert!(!f(&l64(&one), &l64(&other), &wide, 64));
        assert!(!f(&l64(&one), &l64(&bx(0.34, 0.12, 0.37, 0.2)), &seen, 64));
        assert!(!f(&l64(&one), &vec![-8.0; 64 * 64], &seen, 64));
    }

    #[test]
    fn pieces_box_keeps_a_head_and_a_torso_split_by_an_occluder_but_not_specks() {
        let head = bx(0.4, 0.1, 0.5, 0.25);
        let torso = bx(0.38, 0.45, 0.52, 0.9);
        let speck = bx(0.9, 0.05, 0.91, 0.06);
        let m = matte_of(&[head, torso, speck], 100);
        let b = SubjectTrackRules::pieces_box(&m, Vec2::new(0.45, 0.17), 0.05).unwrap_or(bx(9.0, 9.0, 9.0, 9.0));
        assert!((b.y0 - 0.1).abs() < 0.02 && (b.y1 - 0.9).abs() < 0.02 && (b.x1 - 0.52).abs() < 0.02);
        assert!(b.x1 < 0.6);
        assert!(SubjectTrackRules::pieces_box(&matte_of(&[], 100), Vec2::new(0.5, 0.5), 0.05).is_none());
    }

    #[test]
    fn leftover_is_what_the_first_mask_missed_inside_the_box() {
        let size = 64;
        let seen = logits(&bx(0.1, 0.1, 0.9, 0.9), size);
        let first = logits(&bx(0.1, 0.1, 0.4, 0.9), size);
        let rest = SubjectTrackRules::leftover(&seen, &first, &bx(0.0, 0.0, 0.6, 1.0), size);
        for y in 0..size {
            for x in 0..size {
                if rest[y * size + x] > 0.0 {
                    let u = (x as f64 + 0.5) / size as f64;
                    assert!(u > 0.4 && u <= 0.6);
                }
            }
        }
        assert!(rest.iter().any(|v| *v > 0.0));
    }
}

#[cfg(test)]
mod rule_tests {
    use super::*;
    use sq_core_time::Time;

    fn l64(x0: f64, y0: f64, x1: f64, y1: f64) -> Vec<f32> {
        let size = 64;
        let mut out = vec![-8.0_f32; size * size];
        for y in 0..size {
            for x in 0..size {
                let u = (x as f64 + 0.5) / size as f64;
                let v = (y as f64 + 0.5) / size as f64;
                if u >= x0 && u <= x1 && v >= y0 && v <= y1 {
                    out[y * size + x] = 8.0;
                }
            }
        }
        out
    }
    fn add(x: f64, y: f64) -> MagicPoint {
        MagicPoint { position: Vec2::new(x, y), subtract: false, source_time: Time::ZERO }
    }
    fn remove(x: f64, y: f64) -> MagicPoint {
        MagicPoint { position: Vec2::new(x, y), subtract: true, source_time: Time::ZERO }
    }

    #[test]
    fn a_mask_answers_added_points_on_it_and_removed_points_off_it() {
        let tracked = l64(0.2, 0.2, 0.6, 0.6);
        assert!(SubjectCorrectionRule::answers(&[add(0.4, 0.4)], &tracked, 64));
        assert!(!SubjectCorrectionRule::answers(&[add(0.8, 0.8)], &tracked, 64));
        assert!(SubjectCorrectionRule::answers(&[remove(0.8, 0.8)], &tracked, 64));
        assert!(!SubjectCorrectionRule::answers(&[remove(0.4, 0.4), add(0.3, 0.3)], &tracked, 64));
        assert!(!SubjectCorrectionRule::answers(&[], &tracked, 64));
    }

    #[test]
    fn a_matte_answers_the_same_way_at_its_own_size() {
        let mut values = vec![0.0_f32; 100];
        for y in 2..6 {
            for x in 2..6 {
                values[y * 10 + x] = 1.0;
            }
        }
        let m = SubjectMatte::new(10, 10, values);
        assert!(SubjectCorrectionRule::answers_matte(&[add(0.35, 0.35), remove(0.9, 0.1)], &m));
        assert!(!SubjectCorrectionRule::answers_matte(&[add(0.75, 0.75)], &m));
    }

    #[test]
    fn an_added_click_takes_the_candidate_that_grows_the_tracked_mask_least() {
        let tracked = l64(0.2, 0.2, 0.5, 0.6);
        let candidates =
            vec![l64(0.6, 0.3, 0.9, 0.9), l64(0.0, 0.0, 1.0, 1.0), l64(0.2, 0.2, 0.75, 0.6), l64(0.2, 0.2, 0.5, 0.6)];
        assert_eq!(SubjectCorrectionRule::refinement(&candidates, &tracked, &[add(0.7, 0.4)], 64), Some(2));
    }

    #[test]
    fn a_removed_click_takes_a_candidate_inside_the_tracked_mask() {
        let tracked = l64(0.1, 0.1, 0.9, 0.5);
        let candidates = vec![l64(0.6, 0.6, 0.9, 0.9), l64(0.1, 0.1, 0.5, 0.5)];
        assert_eq!(SubjectCorrectionRule::refinement(&candidates, &tracked, &[remove(0.8, 0.3)], 64), Some(1));
        assert_eq!(
            SubjectCorrectionRule::refinement(&[l64(0.1, 0.1, 0.15, 0.15)], &tracked, &[remove(0.8, 0.3)], 64),
            None
        );
    }

    #[test]
    fn no_candidate_that_refines_is_none() {
        let tracked = l64(0.2, 0.2, 0.5, 0.6);
        assert_eq!(SubjectCorrectionRule::refinement(&[l64(0.6, 0.6, 0.9, 0.9)], &tracked, &[add(0.7, 0.7)], 64), None);
        assert_eq!(SubjectCorrectionRule::refinement(&[], &tracked, &[add(0.7, 0.7)], 64), None);
    }

    #[test]
    fn a_lost_frame_takes_the_first_candidate_that_answers_the_click() {
        let empty = vec![-8.0_f32; 64 * 64];
        let candidates = vec![l64(0.0, 0.0, 0.2, 0.2), l64(0.6, 0.6, 0.9, 0.9), l64(0.5, 0.5, 1.0, 1.0)];
        assert_eq!(SubjectCorrectionRule::refinement(&candidates, &empty, &[add(0.7, 0.7)], 64), Some(1));
    }

    #[test]
    fn certainty_is_mean_distance_from_half() {
        assert_eq!(SubjectMemoryGate::certainty(&[0.0, 0.0]), 0.0);
        assert!(SubjectMemoryGate::certainty(&[8.0; 16]) > 0.49);
        assert_eq!(SubjectMemoryGate::certainty(&[]), 0.0);
    }

    #[test]
    fn default_gate_admits_every_frame() {
        let mut g = SubjectMemoryGate::default();
        assert!((0..5).all(|_| g.admit(&[0.2; 16])));
    }

    #[test]
    fn distance_spaces_entries() {
        let mut g = SubjectMemoryGate::new(3, 0.0);
        let got: Vec<bool> = (0..7).map(|_| g.admit(&[8.0; 16])).collect();
        assert_eq!(got, vec![true, false, false, true, false, false, true]);
    }

    #[test]
    fn blurry_masks_never_enter_and_do_not_restart_distance() {
        let mut g = SubjectMemoryGate::new(2, 0.3);
        assert!(g.admit(&[8.0; 16]));
        assert!(!g.admit(&[8.0; 16])); // too near
        assert!(!g.admit(&[0.2; 16])); // far enough but uncertain
        assert!(g.admit(&[8.0; 16])); // still far enough
    }

    #[test]
    fn nan_logits_count_as_zero_certainty_and_reset_lets_the_next_frame_in() {
        let nan = [f32::NAN; 4];
        assert_eq!(SubjectMemoryGate::certainty(&nan), 0.0);
        assert!(SubjectMemoryGate::default().admit(&nan));
        assert!(!SubjectMemoryGate::new(1, 0.1).admit(&nan));
        let mut g = SubjectMemoryGate::new(4, 0.0);
        g.admit(&[8.0; 16]);
        g.reset();
        assert!(g.admit(&[8.0; 16]));
    }

    #[test]
    fn only_the_first_empty_frames_in_a_row_are_remembered() {
        let mut m = SubjectAbsenceMemory::new(2);
        let first: Vec<bool> = (0..5).map(|_| m.admits_empty()).collect();
        assert_eq!(first, vec![true, true, false, false, false]);
        m.found();
        let again: Vec<bool> = (0..3).map(|_| m.admits_empty()).collect();
        assert_eq!(again, vec![true, true, false]);
        let mut all = SubjectAbsenceMemory::default();
        assert!((0..50).all(|_| all.admits_empty()));
        assert!(!SubjectAbsenceMemory::new(0).admits_empty());
        assert!(SubjectAbsenceMemory::tracker().limit < 6);
    }

    fn reacquire_box() -> SubjectTrackBox {
        SubjectTrackBox::new(0.6, 0.1, 0.8, 0.9)
    }

    #[test]
    fn a_weak_mask_after_a_gap_is_no_reacquisition() {
        let b = reacquire_box();
        let mut rule = SubjectReacquireRule::new(2.0, 3, 3, 0.15, 0.6);
        assert!(rule.accepts(0.3, 0.05, b, 0) && rule.accepts(0.3, 0.02, b, 2));
        assert!(rule.accepts(2.0, 0.05, b, 3));
        let areas = [0.024, 0.031, 0.040, 0.061, 0.019, 0.040];
        assert!(areas.iter().all(|a| !rule.accepts(0.4, *a, b, 10)));
        assert_eq!(SubjectReacquireRule::new(1.0, 0, 0, 0.15, 0.6).after_lost, 1);
    }

    #[test]
    fn a_weak_mask_that_holds_still_is_the_subject_back() {
        let b = reacquire_box();
        let mut rule = SubjectReacquireRule::new(2.0, 3, 3, 0.15, 0.6);
        let held: Vec<bool> = [0.0733, 0.0723, 0.0722, 0.0724].iter().map(|a| rule.accepts(0.7, *a, b, 15)).collect();
        assert_eq!(held, vec![false, false, true, true]);
        let moved = SubjectTrackBox::new(0.1, 0.1, 0.3, 0.9);
        let mut other = SubjectReacquireRule::new(2.0, 3, 2, 0.15, 0.6);
        let (a, m1, m2) =
            (other.accepts(0.7, 0.07, b, 15), other.accepts(0.7, 0.07, moved, 15), other.accepts(0.7, 0.07, moved, 15));
        assert!(!a && !m1 && m2);
        let mut gap = SubjectReacquireRule::new(2.0, 3, 2, 0.15, 0.6);
        let d = gap.accepts(0.7, 0.07, b, 15);
        gap.empty();
        let (e, f) = (gap.accepts(0.7, 0.07, b, 15), gap.accepts(0.7, 0.07, b, 15));
        assert!(!d && !e && f);
        assert!(SubjectReacquireRule::off().accepts(-100.0, 0.5, b, 1000));
    }
}
