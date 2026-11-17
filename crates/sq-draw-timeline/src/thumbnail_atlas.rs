// Swift: ThumbnailAtlas.swift
//! Timeline thumbnails packed into one image slot: a fixed grid of cells, each holding one decoded frame scaled to fit
//! (aspect kept). The least recently used cell is reused when the grid is full. The host uploads `image` to `slot`
//! whenever `generation` changes and answers `TimelineMediaSource::picture` from [`ThumbnailAtlas::picture`].
//! Not thread-safe: the host keeps it behind its own lock.

use crate::media::TimelinePicture;
use sq_core_time::Id;
use sq_draw::RgbaImage;
use std::collections::BTreeMap;

/// A cached frame: media and a host-chosen frame number (the Windows host uses milliseconds of media time).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ThumbnailKey {
    /// The media.
    pub media: Id,
    /// Host-chosen frame number.
    pub frame: i64,
}

#[derive(Clone, Copy)]
struct Entry {
    cell: usize,
    w: usize,
    h: usize,
    used: u64,
}

/// The grid of thumbnail cells.
pub struct ThumbnailAtlas {
    /// The image slot the host uploads to.
    pub slot: usize,
    /// Cell width in pixels.
    pub cell_width: usize,
    /// Cell height in pixels.
    pub cell_height: usize,
    /// Cells per row.
    pub columns: usize,
    /// Rows of cells.
    pub rows: usize,
    image: RgbaImage,
    generation: u64,
    entries: BTreeMap<ThumbnailKey, Entry>,
    owner: Vec<Option<ThumbnailKey>>,
    clock: u64,
}

impl ThumbnailAtlas {
    /// An atlas of `columns x rows` cells (the Swift defaults are 160 x 90 pixels, 12 x 22 cells).
    pub fn new(slot: usize, cell_width: usize, cell_height: usize, columns: usize, rows: usize) -> ThumbnailAtlas {
        let (width, height) = (cell_width * columns, cell_height * rows);
        ThumbnailAtlas {
            slot,
            cell_width,
            cell_height,
            columns,
            rows,
            image: RgbaImage { width, height, pixels: vec![0; width * height * 4] },
            generation: 0,
            entries: BTreeMap::new(),
            owner: vec![None; columns * rows],
            clock: 0,
        }
    }

    /// The packed image.
    pub fn image(&self) -> &RgbaImage {
        &self.image
    }
    /// Bumped on every change of `image`.
    pub fn generation(&self) -> u64 {
        self.generation
    }
    /// How many frames fit.
    pub fn capacity(&self) -> usize {
        self.columns * self.rows
    }
    /// How many frames are cached.
    pub fn count(&self) -> usize {
        self.entries.len()
    }
    /// Whether `key` is cached.
    pub fn contains(&self, key: &ThumbnailKey) -> bool {
        self.entries.contains_key(key)
    }

    /// The cell of `key` as a picture (marks it recently used); `None` when it is not cached.
    pub fn picture(&mut self, key: &ThumbnailKey) -> Option<TimelinePicture> {
        let mut e = *self.entries.get(key)?;
        self.clock += 1;
        e.used = self.clock;
        self.entries.insert(*key, e);
        Some(self.picture_of(&e))
    }

    /// Scales `frame` to fit a cell (area average, aspect kept) and stores it under `key`, reusing the least recently
    /// used cell when the grid is full.
    pub fn insert(&mut self, key: ThumbnailKey, frame: &RgbaImage) {
        if frame.width == 0 || frame.height == 0 {
            return;
        }
        let k =
            (self.cell_width as f64 / frame.width as f64).min(self.cell_height as f64 / frame.height as f64).min(1.0);
        let w = ((frame.width as f64 * k).round() as usize).max(1);
        let h = ((frame.height as f64 * k).round() as usize).max(1);
        let cell = if let Some(e) = self.entries.get(&key) {
            e.cell
        } else if let Some(free) = self.owner.iter().position(Option::is_none) {
            free
        } else {
            let oldest = self.entries.iter().min_by_key(|(_, e)| e.used).map(|(k, e)| (*k, e.cell));
            let Some((old, cell)) = oldest else { return };
            self.entries.remove(&old);
            cell
        };
        self.owner[cell] = Some(key);
        self.clock += 1;
        self.entries.insert(key, Entry { cell, w, h, used: self.clock });
        self.blit(&Self::scaled(frame, w, h), cell);
        self.generation += 1;
    }

    fn picture_of(&self, e: &Entry) -> TimelinePicture {
        let (aw, ah) = (self.image.width as f32, self.image.height as f32);
        let x = ((e.cell % self.columns) * self.cell_width) as f32;
        let y = ((e.cell / self.columns) * self.cell_height) as f32;
        // Half a texel in from the cell's edges so bilinear sampling never reads the neighbor cell.
        let u0 = (x + 0.5) / aw;
        let v0 = (y + 0.5) / ah;
        let u1 = (x + e.w as f32 - 0.5) / aw;
        let v1 = (y + e.h as f32 - 0.5) / ah;
        TimelinePicture { slot: self.slot, source: [u0, v0, u1, v1], pixel_width: e.w as f64, pixel_height: e.h as f64 }
    }

    fn blit(&mut self, src: &RgbaImage, cell: usize) {
        let x0 = (cell % self.columns) * self.cell_width;
        let y0 = (cell / self.columns) * self.cell_height;
        let stride = self.image.width * 4;
        for row in 0..src.height {
            let d = (y0 + row) * stride + x0 * 4;
            let s = row * src.width * 4;
            self.image.pixels[d..d + src.width * 4].copy_from_slice(&src.pixels[s..s + src.width * 4]);
        }
    }

    /// Area-average downscale (each output pixel averages the source box it covers).
    pub fn scaled(src: &RgbaImage, w: usize, h: usize) -> RgbaImage {
        if src.width == w && src.height == h {
            return RgbaImage { width: src.width, height: src.height, pixels: src.pixels.clone() };
        }
        let mut out = vec![0u8; w * h * 4];
        for oy in 0..h {
            let sy0 = oy * src.height / h;
            let sy1 = (sy0 + 1).max((oy + 1) * src.height / h);
            for ox in 0..w {
                let sx0 = ox * src.width / w;
                let sx1 = (sx0 + 1).max((ox + 1) * src.width / w);
                let mut acc = [0usize; 4];
                for sy in sy0..sy1 {
                    let mut i = (sy * src.width + sx0) * 4;
                    for _ in sx0..sx1 {
                        for (c, a) in acc.iter_mut().enumerate() {
                            *a += src.pixels[i + c] as usize;
                        }
                        i += 4;
                    }
                }
                let n = (sy1 - sy0) * (sx1 - sx0);
                let o = (oy * w + ox) * 4;
                for (c, a) in acc.iter().enumerate() {
                    out[o + c] = (a / n) as u8;
                }
            }
        }
        RgbaImage { width: w, height: h, pixels: out }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: usize, h: usize, v: u8) -> RgbaImage {
        RgbaImage { width: w, height: h, pixels: vec![v; w * h * 4] }
    }

    fn key(n: i64) -> ThumbnailKey {
        ThumbnailKey { media: Id::from_u128(1), frame: n }
    }

    #[test]
    fn insert_keeps_aspect_and_reports_a_picture() {
        let mut a = ThumbnailAtlas::new(3, 16, 9, 2, 2);
        a.insert(key(0), &solid(32, 18, 200));
        let p = a.picture(&key(0));
        assert!(p.is_some_and(|p| p.slot == 3 && p.pixel_width == 16.0 && p.pixel_height == 9.0));
        assert_eq!(a.generation(), 1);
    }

    #[test]
    fn full_grid_reuses_the_least_recently_used_cell() {
        let mut a = ThumbnailAtlas::new(0, 4, 4, 1, 2);
        a.insert(key(0), &solid(4, 4, 1));
        a.insert(key(1), &solid(4, 4, 2));
        let _ = a.picture(&key(0));
        a.insert(key(2), &solid(4, 4, 3));
        assert!(a.contains(&key(0)) && a.contains(&key(2)) && !a.contains(&key(1)));
        assert_eq!(a.count(), a.capacity());
    }

    #[test]
    fn scaling_averages_the_covered_box() {
        let mut img = solid(2, 1, 0);
        img.pixels[0..4].copy_from_slice(&[100, 100, 100, 100]);
        img.pixels[4..8].copy_from_slice(&[200, 200, 200, 200]);
        assert_eq!(ThumbnailAtlas::scaled(&img, 1, 1).pixels, vec![150, 150, 150, 150]);
    }
}
