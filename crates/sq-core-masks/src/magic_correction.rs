// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagicCorrection.swift
//! Magic mask corrections: add / remove points that cut a picked object apart or grow it where the segmentation has no
//! object (Vision merged the person with a lamp, or missed a hat). Works on a coarse grid (at most `GRID_MAX` px a side)
//! of the frame's picture (`MagicGuide`): a color-aware geodesic distance from the points decides which pixels belong
//! to the correction, so cuts and growth follow color edges. The regions found are carried to the next frame
//! (`State`), so one correction keeps working while the shot is tracked.

use crate::magic_follow::MagicGuide;
use crate::subject_mask::SubjectMatte;
use sq_core_time::Vec2;

/// Longest side of the work grid.
pub const GRID_MAX: usize = 160;
/// How far a correction reaches from its points: color steps plus distance (a uniform area reaches ~30 % of the frame).
pub const REACH: f32 = 0.35;
/// Color differences below this (RGB distance 0...1.7) are texture, not an edge.
pub const COLOR_FLOOR: f32 = 0.03;
/// How far (grid cells) a carried region is searched for on the next frame.
pub const SEARCH_RADIUS: i64 = 8;
/// A carried cell survives when its color moved along with it (RGB distance).
pub const CARRY_COLOR: f32 = 0.15;

/// The coarse picture and the selection mask on the grid.
pub struct Grid {
    width: usize,
    height: usize,
    rgb: Vec<f32>,
}

impl Grid {
    /// The guide picture averaged onto the grid.
    pub fn new(g: &MagicGuide) -> Grid {
        let s = (GRID_MAX as f64 / g.width().max(g.height()) as f64).min(1.0);
        let w = ((g.width() as f64 * s).round() as usize).max(1);
        let h = ((g.height() as f64 * s).round() as usize).max(1);
        let mut out = vec![0.0_f32; w * h * 3];
        let mut count = vec![0.0_f32; w * h];
        for y in 0..g.height() {
            let gy = (y * h / g.height()).min(h - 1);
            for x in 0..g.width() {
                let gx = (x * w / g.width()).min(w - 1);
                let (i, j) = (gy * w + gx, (y * g.width() + x) * 3);
                out[i * 3] += g.rgb[j];
                out[i * 3 + 1] += g.rgb[j + 1];
                out[i * 3 + 2] += g.rgb[j + 2];
                count[i] += 1.0;
            }
        }
        for i in 0..w * h {
            if count[i] > 0.0 {
                out[i * 3] /= count[i];
                out[i * 3 + 1] /= count[i];
                out[i * 3 + 2] /= count[i];
            }
        }
        Grid { width: w, height: h, rgb: out }
    }

    /// Spatial cost of one grid step (so a uniform area is reached up to ~30 % of the frame).
    fn step(&self) -> f32 {
        REACH / (0.3 * self.width.max(self.height) as f32)
    }

    /// Grid cell of frame fraction `p` (clamped).
    fn cell(&self, p: Vec2) -> usize {
        let x = ((p.x * self.width as f64) as i64).clamp(0, self.width as i64 - 1) as usize;
        let y = ((p.y * self.height as f64) as i64).clamp(0, self.height as i64 - 1) as usize;
        y * self.width + x
    }

    /// A matte of any size on the grid (area mean), as inside / outside at 0.5.
    fn inside(&self, m: &SubjectMatte) -> Vec<bool> {
        m.resampled(self.width, self.height).values.iter().map(|v| *v >= 0.5).collect()
    }

    /// Color-aware geodesic distance from `seeds` over the cells `allowed` permits (infinity elsewhere).
    fn distances(&self, seeds: &[usize], allowed: &[bool]) -> Vec<f32> {
        let (width, height) = (self.width, self.height);
        let mut d = vec![f32::INFINITY; width * height];
        let mut heap = MinHeap::default();
        for &s in seeds {
            if allowed[s] && d[s] > 0.0 {
                d[s] = 0.0;
                heap.push(0.0, s);
            }
        }
        let st = self.step();
        let diag = st * 2.0_f32.sqrt();
        while let Some((c, i)) = heap.pop() {
            if c > d[i] {
                continue;
            }
            let (x, y) = ((i % width) as i64, (i / width) as i64);
            for dy in -1..=1_i64 {
                let ny = y + dy;
                if ny < 0 || ny >= height as i64 {
                    continue;
                }
                for dx in -1..=1_i64 {
                    if dx == 0 && dy == 0 {
                        continue;
                    }
                    let nx = x + dx;
                    if nx < 0 || nx >= width as i64 {
                        continue;
                    }
                    let j = ny as usize * width + nx as usize;
                    if !allowed[j] {
                        continue;
                    }
                    let (a, b) = (i * 3, j * 3);
                    let dr = self.rgb[a] - self.rgb[b];
                    let dg = self.rgb[a + 1] - self.rgb[b + 1];
                    let db = self.rgb[a + 2] - self.rgb[b + 2];
                    let col = ((dr * dr + dg * dg + db * db).sqrt() - COLOR_FLOOR).max(0.0);
                    let nc = c + col + if dx != 0 && dy != 0 { diag } else { st };
                    if nc < d[j] {
                        d[j] = nc;
                        heap.push(nc, j);
                    }
                }
            }
        }
        d
    }

    /// Cells of `m` minus a border of `r` cells (seeds that stay clear of the edge).
    fn eroded(&self, m: &[bool], r: i64) -> Vec<bool> {
        if r <= 0 {
            return m.to_vec();
        }
        let (width, height) = (self.width as i64, self.height as i64);
        let mut out = m.to_vec();
        for y in 0..height {
            for x in 0..width {
                if !m[(y * width + x) as usize] {
                    continue;
                }
                'outer: for dy in -r..=r {
                    for dx in -r..=r {
                        let (nx, ny) = (x + dx, y + dy);
                        if nx < 0 || ny < 0 || nx >= width || ny >= height || !m[(ny * width + nx) as usize] {
                            out[(y * width + x) as usize] = false;
                            break 'outer;
                        }
                    }
                }
            }
        }
        out
    }

    fn dilated(&self, m: &[bool], r: i64) -> Vec<bool> {
        let inverted: Vec<bool> = m.iter().map(|v| !v).collect();
        self.eroded(&inverted, r).iter().map(|v| !v).collect()
    }

    /// A grid mask as a matte of `w` x `h` (bilinear: soft edges at the grid's resolution).
    fn matte(&self, m: &[bool], w: usize, h: usize) -> SubjectMatte {
        SubjectMatte::new(self.width, self.height, m.iter().map(|b| if *b { 1.0 } else { 0.0 }).collect())
            .resampled(w, h)
    }

    /// `region` of the last frame's picture `before` (same grid) carried onto this frame: moved by the shift (up to
    /// `SEARCH_RADIUS` cells) whose colors match best, then only the cells whose color still matches.
    fn carry(&self, region: &[bool], before: &[f32]) -> Vec<bool> {
        let cells: Vec<usize> = (0..region.len()).filter(|i| region[*i]).collect();
        if cells.is_empty() || before.len() != self.rgb.len() {
            return vec![false; region.len()];
        }
        let sample: Vec<usize> = if cells.len() > 600 {
            (0..cells.len()).step_by(cells.len() / 600).map(|i| cells[i]).collect()
        } else {
            cells.clone()
        };
        let diff = |i: usize, j: usize| {
            let (a, b) = (i * 3, j * 3);
            let dr = before[a] - self.rgb[b];
            let dg = before[a + 1] - self.rgb[b + 1];
            let db = before[a + 2] - self.rgb[b + 2];
            (dr * dr + dg * dg + db * db).sqrt()
        };
        let (w, h) = (self.width as i64, self.height as i64);
        let r = SEARCH_RADIUS;
        let (mut best, mut best_cost) = ((0_i64, 0_i64), f32::INFINITY);
        for dy in -r..=r {
            for dx in -r..=r {
                let mut c = 0.0_f32;
                for &i in &sample {
                    let x = (i as i64 % w) + dx;
                    let y = (i as i64 / w) + dy;
                    c += if x < 0 || y < 0 || x >= w || y >= h { 1.0 } else { diff(i, (y * w + x) as usize) };
                }
                // Ties go to the smaller move.
                c += (dx.abs() + dy.abs()) as f32 * 1e-4 * sample.len() as f32;
                if c < best_cost {
                    best_cost = c;
                    best = (dx, dy);
                }
            }
        }
        let mut out = vec![false; region.len()];
        for &i in &cells {
            let x = (i as i64 % w) + best.0;
            let y = (i as i64 / w) + best.1;
            if x < 0 || y < 0 || x >= w || y >= h {
                continue;
            }
            let j = (y * w + x) as usize;
            if diff(i, j) < CARRY_COLOR {
                out[j] = true;
            }
        }
        out
    }
}

/// Regions a correction found on the last frame, carried to the next one (grid cells).
#[derive(Clone, Debug, Default)]
pub struct State {
    width: usize,
    height: usize,
    removed: Vec<bool>,
    added: Vec<bool>,
    kept: Vec<bool>,
    /// The last frame's grid picture (carried regions are found again on the next frame by color).
    rgb: Vec<f32>,
}

impl State {
    /// Nothing is carried.
    pub fn is_empty(&self) -> bool {
        !self.removed.contains(&true) && !self.added.contains(&true)
    }
}

/// Applies the corrections of this frame (`add` / `remove`: frame fractions of the points made on it) and the carried
/// regions of `state` to `base` (the soft matte of the followed objects). Returns the corrected matte; updates `state`.
/// Without a guide, or with nothing to correct, `base` comes back unchanged.
///
/// Cut: the selection splits between remove seeds (this frame's remove points, last frame's removed region) and keep
/// seeds (add points, last frame's kept core, and every selected cell beyond `REACH` of the remove seeds); a cell goes
/// to the nearer side, so the split lands on the color edge between them. Grow works the same way outside the selection.
pub fn apply(
    base: &SubjectMatte,
    guide: Option<&MagicGuide>,
    add: &[Vec2],
    remove: &[Vec2],
    state: &mut State,
) -> SubjectMatte {
    let Some(guide) = guide else { return base.clone() };
    if add.is_empty() && remove.is_empty() && state.is_empty() {
        state.kept = Vec::new();
        return base.clone();
    }
    let g = Grid::new(guide);
    if state.width != g.width || state.height != g.height {
        *state = State { width: g.width, height: g.height, ..State::default() };
    }
    let n = g.width * g.height;
    let none = vec![false; n];
    let in_base = g.inside(base);
    let removed_before =
        if state.removed.contains(&true) { g.carry(&g.eroded(&state.removed, 1), &state.rgb) } else { none.clone() };
    let kept_before =
        if state.kept.contains(&true) { g.carry(&g.eroded(&state.kept, 1), &state.rgb) } else { none.clone() };
    let added_before =
        if state.added.contains(&true) { g.carry(&g.eroded(&state.added, 1), &state.rgb) } else { none.clone() };
    let remove_cells: Vec<usize> = remove.iter().map(|p| g.cell(*p)).collect();
    let add_cells: Vec<usize> = add.iter().map(|p| g.cell(*p)).collect();

    let mut cut = none.clone();
    let mut remove_seeds: Vec<usize> = remove_cells.iter().copied().filter(|c| in_base[*c]).collect();
    for i in 0..n {
        if removed_before[i] && in_base[i] {
            remove_seeds.push(i);
        }
    }
    if !remove_seeds.is_empty() {
        let d_remove = g.distances(&remove_seeds, &in_base);
        // A fresh remove point overrules what was kept on the last frame.
        let carry_kept = !remove_cells.iter().any(|c| in_base[*c]);
        let mut keep_seeds: Vec<usize> =
            add_cells.iter().copied().filter(|c| in_base[*c] && d_remove[*c] > 0.0).collect();
        for i in 0..n {
            if in_base[i] && d_remove[i] > 0.0 && ((carry_kept && kept_before[i]) || d_remove[i] >= REACH) {
                keep_seeds.push(i);
            }
        }
        let d_keep = g.distances(&keep_seeds, &in_base);
        for i in 0..n {
            if in_base[i] {
                cut[i] = d_remove[i] < d_keep[i];
            }
        }
    }

    let mut grow = none;
    let outside: Vec<bool> = in_base.iter().map(|v| !v).collect();
    let mut add_seeds: Vec<usize> = add_cells.iter().copied().filter(|c| outside[*c]).collect();
    for i in 0..n {
        if added_before[i] && outside[i] {
            add_seeds.push(i);
        }
    }
    if !add_seeds.is_empty() {
        let d_add = g.distances(&add_seeds, &outside);
        let mut stop_seeds: Vec<usize> =
            remove_cells.iter().copied().filter(|c| outside[*c] && d_add[*c] > 0.0).collect();
        for i in 0..n {
            if outside[i] && d_add[i] > 0.0 && d_add[i] >= REACH {
                stop_seeds.push(i);
            }
        }
        let d_stop = g.distances(&stop_seeds, &outside);
        for i in 0..n {
            if outside[i] {
                grow[i] = d_add[i] < d_stop[i];
            }
        }
    }

    state.kept = (0..n).map(|i| in_base[i] && !cut[i]).collect();
    state.removed = cut;
    state.added = grow;
    state.rgb = g.rgb.clone();
    if !state.removed.contains(&true) && !state.added.contains(&true) {
        return base.clone();
    }
    let cut_m = g.matte(&state.removed, base.width(), base.height());
    let grow_m = g.matte(&state.added, base.width(), base.height());
    let mut v = base.values.clone();
    for (i, x) in v.iter_mut().enumerate() {
        *x = (*x * (1.0 - cut_m.values[i])).max(grow_m.values[i]);
    }
    SubjectMatte::new(base.width(), base.height(), v)
}

/// The correction a stored matte already holds (`corrected` against the segmentation's `raw` matte of the same objects),
/// as carried state: Track that continues from a corrected frame keeps the correction.
pub fn state(raw: &SubjectMatte, corrected: &SubjectMatte, guide: Option<&MagicGuide>) -> State {
    let Some(guide) = guide else { return State::default() };
    let g = Grid::new(guide);
    let (a, b) = (g.inside(raw), g.inside(corrected));
    let mut s = State { width: g.width, height: g.height, ..State::default() };
    s.removed = a.iter().zip(&b).map(|(a, b)| *a && !*b).collect();
    s.added = a.iter().zip(&b).map(|(a, b)| !*a && *b).collect();
    // Specks from soft edges are no correction.
    s.removed = g.dilated(&g.eroded(&s.removed, 1), 1);
    s.added = g.dilated(&g.eroded(&s.added, 1), 1);
    s.kept = a.iter().zip(&s.removed).map(|(a, r)| *a && !*r).collect();
    s.rgb = g.rgb.clone();
    s
}

/// Binary min-heap of (cost, cell) for the geodesic distance.
#[derive(Default)]
struct MinHeap {
    items: Vec<(f32, usize)>,
}

impl MinHeap {
    fn push(&mut self, c: f32, i: usize) {
        self.items.push((c, i));
        let mut k = self.items.len() - 1;
        while k > 0 {
            let p = (k - 1) / 2;
            if self.items[p].0 <= self.items[k].0 {
                break;
            }
            self.items.swap(p, k);
            k = p;
        }
    }

    fn pop(&mut self) -> Option<(f32, usize)> {
        let top = *self.items.first()?;
        let last = self.items.pop()?;
        if !self.items.is_empty() {
            self.items[0] = last;
            let mut k = 0;
            loop {
                let l = 2 * k + 1;
                let r = l + 1;
                let mut m = k;
                if l < self.items.len() && self.items[l].0 < self.items[m].0 {
                    m = l;
                }
                if r < self.items.len() && self.items[r].0 < self.items[m].0 {
                    m = r;
                }
                if m == k {
                    break;
                }
                self.items.swap(m, k);
                k = m;
            }
        }
        Some(top)
    }
}
