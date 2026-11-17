// Swift: Draw/TextTemplateTileAtlas.swift
//! The pictures of the Text panel's template tiles, packed into one image slot: the saved PNG of a multi-layer template,
//! else the template's look drawn by the real text renderer (with its outline, box and shadow) on the tile background, at
//! 256 x 160 pixels. Tiles without either keep the sample text the tab draws itself.
//!
//! The host calls `prepare` once per frame while the tab shows (a few pictures per call, so a long list never stalls a
//! frame), uploads `image` to `SLOT` when `generation` changed, and answers the tab's `picture` from `picture_for`.

use std::collections::BTreeMap;

use sq_draw::software::RgbaImage;
use sq_text::text_preset_still::TextPresetStill;

use crate::text::template_tiles::TextTemplateTile;

/// Where a template tile's picture sits in the atlas: the image slot and the normalized source rect.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextTemplateTilePicture {
    pub slot: usize,
    pub source: (f32, f32, f32, f32),
}

/// Decodes a saved template's PNG bytes.
pub type PictureDecoder = Box<dyn Fn(&[u8]) -> Option<RgbaImage>>;

struct Cell {
    index: usize,
    tile: TextTemplateTile,
    drawn: bool,
}

pub struct TextTemplateTileAtlas {
    /// Decodes a saved template's PNG (`None`: no decoder on this platform, the look or the sample text shows).
    pub decode_picture: Option<PictureDecoder>,
    background: (u8, u8, u8),
    image: RgbaImage,
    generation: u64,
    cells: BTreeMap<String, Cell>,
    free: Vec<usize>,
    used: usize,
}

impl Default for TextTemplateTileAtlas {
    fn default() -> Self {
        Self::new()
    }
}

impl TextTemplateTileAtlas {
    /// The draw list's slot for the tiles (`DrawList::IMAGE_SLOTS`: 0 thumbnails, 1 Slip two-up, 2-3 scopes).
    pub const SLOT: usize = 4;
    pub const CELL_WIDTH: usize = 256;
    pub const CELL_HEIGHT: usize = 160;
    pub const COLUMNS: usize = 8;
    /// Pictures made per `prepare` call.
    pub const BUDGET: usize = 4;

    pub fn new() -> TextTemplateTileAtlas {
        TextTemplateTileAtlas {
            decode_picture: None,
            background: (34, 34, 34),
            image: RgbaImage { width: Self::CELL_WIDTH * Self::COLUMNS, height: 0, pixels: Vec::new() },
            generation: 0,
            cells: BTreeMap::new(),
            free: Vec::new(),
            used: 0,
        }
    }

    pub fn image(&self) -> &RgbaImage {
        &self.image
    }

    /// Bumped on every change of `image`.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn background(&self) -> (u8, u8, u8) {
        self.background
    }

    /// The tile background (Mac `Theme.Colors.tileBackground`), sRGB bytes; a change redraws every picture.
    pub fn set_background(&mut self, bg: (u8, u8, u8)) {
        if bg != self.background {
            self.background = bg;
            self.cells.clear();
            self.free.clear();
            self.used = 0;
            self.generation += 1;
        }
    }

    /// Makes up to `budget` missing pictures of `tiles` (in order), frees the cells of tiles no longer listed; `true` while
    /// some are still missing (the host draws another frame).
    pub fn prepare(&mut self, tiles: &[TextTemplateTile], budget: usize) -> bool {
        let ids: std::collections::BTreeSet<String> = tiles.iter().map(TextTemplateTile::id).collect();
        let gone: Vec<String> = self.cells.keys().filter(|k| !ids.contains(*k)).cloned().collect();
        for id in gone {
            if let Some(c) = self.cells.remove(&id) {
                self.free.push(c.index);
            }
        }
        let (mut made, mut left) = (0, false);
        for tile in tiles.iter().filter(|t| t.thumbnail.is_some() || t.style.is_some()) {
            let id = tile.id();
            if self.cells.get(&id).is_some_and(|c| c.tile == *tile) {
                continue;
            }
            if made >= budget {
                left = true;
                break;
            }
            made += 1;
            let index = match self.cells.get(&id).map(|c| c.index).or_else(|| self.free.pop()) {
                Some(i) => i,
                None => {
                    self.used += 1;
                    self.used - 1
                }
            };
            let pixels = self.render(tile);
            if let Some(px) = &pixels {
                self.blit(px, index);
            }
            self.cells.insert(id, Cell { index, tile: tile.clone(), drawn: pixels.is_some() });
        }
        if made > 0 {
            self.generation += 1;
        }
        left
    }

    /// The tile's picture, `None` while it is not made (or has none).
    pub fn picture_for(&self, tile: &TextTemplateTile) -> Option<TextTemplateTilePicture> {
        let c = self.cells.get(&tile.id()).filter(|c| c.drawn && c.tile == *tile && self.image.height > 0)?;
        let (x, y) = ((c.index % Self::COLUMNS) * Self::CELL_WIDTH, (c.index / Self::COLUMNS) * Self::CELL_HEIGHT);
        let (w, h) = (self.image.width as f32, self.image.height as f32);
        Some(TextTemplateTilePicture {
            slot: Self::SLOT,
            source: (x as f32 / w, y as f32 / h, (x + Self::CELL_WIDTH) as f32 / w, (y + Self::CELL_HEIGHT) as f32 / h),
        })
    }

    /// The tile's cell pixels: the saved PNG stretched to the cell (the Mac draws it into the well), else the look.
    fn render(&self, tile: &TextTemplateTile) -> Option<Vec<u8>> {
        let (w, h) = (Self::CELL_WIDTH, Self::CELL_HEIGHT);
        if let Some(data) = &tile.thumbnail
            && let Some(img) = self.decode_picture.as_ref().and_then(|d| d(data))
            && img.width > 0
            && img.height > 0
        {
            return Some(Self::resized(&img, w, h, self.background));
        }
        let style = tile.style.as_ref()?;
        let (r, g, b) = self.background;
        let bg = TextPresetStill::background(r, g, b, w, h);
        Some(TextPresetStill::still_style(style, &tile.sample_text, &bg, w, h))
    }

    fn blit(&mut self, px: &[u8], index: usize) {
        let (cw, ch, row_bytes) = (Self::CELL_WIDTH, Self::CELL_HEIGHT, self.image.width * 4);
        let (row, col) = (index / Self::COLUMNS, index % Self::COLUMNS);
        let need = (row + 1) * ch * row_bytes;
        if self.image.pixels.len() < need {
            self.image.pixels.resize(need, 0);
        }
        for y in 0..ch {
            let dst = (row * ch + y) * row_bytes + col * cw * 4;
            self.image.pixels[dst..dst + cw * 4].copy_from_slice(&px[y * cw * 4..(y + 1) * cw * 4]);
        }
        self.image.height = self.image.pixels.len() / row_bytes;
    }

    /// `img` scaled to `w` x `h` (box average when shrinking, nearest when growing), over an opaque background.
    pub(crate) fn resized(img: &RgbaImage, w: usize, h: usize, bg: (u8, u8, u8)) -> Vec<u8> {
        let mut out = vec![255u8; w * h * 4];
        let (sx, sy) = (img.width as f64 / w as f64, img.height as f64 / h as f64);
        let bgc = [bg.0, bg.1, bg.2];
        for y in 0..h {
            let y0 = (y as f64 * sy) as usize;
            let y1 = (y0 + 1).max(img.height.min(((y + 1) as f64 * sy) as usize));
            for x in 0..w {
                let x0 = (x as f64 * sx) as usize;
                let x1 = (x0 + 1).max(img.width.min(((x + 1) as f64 * sx) as usize));
                let mut sum = [0.0_f64; 4];
                for yy in y0..y1.min(img.height) {
                    for xx in x0..x1.min(img.width) {
                        let i = (yy * img.width + xx) * 4;
                        for (k, s) in sum.iter_mut().enumerate() {
                            *s += f64::from(img.pixels[i + k]);
                        }
                    }
                }
                let n =
                    ((y1.min(img.height) as i64 - y0 as i64) * (x1.min(img.width) as i64 - x0 as i64)).max(1) as f64;
                let a = sum[3] / n / 255.0;
                let o = (y * w + x) * 4;
                for k in 0..3 {
                    out[o + k] = (sum[k] / n * a + f64::from(bgc[k]) * (1.0 - a)).round().min(255.0) as u8;
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::template_tiles::TileSource;
    use sq_core_time::Id;
    use sq_draw::Color;
    use sq_library::preset_store::PresetKind;

    #[test]
    fn a_saved_picture_wins_and_a_changed_tile_is_redrawn() {
        let mut atlas = TextTemplateTileAtlas::new();
        atlas.decode_picture = Some(Box::new(|_| Some(RgbaImage::filled(2, 2, Color::rgb(1.0, 0.0, 0.0)))));
        let mut saved = TextTemplateTile {
            source: TileSource::User(Id::fixed(1), PresetKind::TitleTemplate),
            name: "Lower third".into(),
            style: None,
            sample_text: "Lower third".into(),
            thumbnail: Some(vec![1, 2, 3]),
        };
        let plain = TextTemplateTile {
            source: TileSource::BuiltIn("plain".into()),
            name: "Plain".into(),
            style: None,
            sample_text: "Text".into(),
            thumbnail: None,
        };
        atlas.prepare(&[saved.clone(), plain.clone()], TextTemplateTileAtlas::BUDGET);
        assert!(atlas.picture_for(&plain).is_none());
        assert!(atlas.picture_for(&saved).is_some());
        assert_eq!(atlas.image().pixels[0..4], [255, 0, 0, 255]);
        saved.name = "Renamed".into();
        assert!(atlas.picture_for(&saved).is_none());
        atlas.prepare(std::slice::from_ref(&saved), TextTemplateTileAtlas::BUDGET);
        assert!(atlas.picture_for(&saved).is_some());
    }

    #[test]
    fn a_background_change_redraws_everything_and_gone_tiles_free_their_cell() {
        let mut atlas = TextTemplateTileAtlas::new();
        atlas.decode_picture = Some(Box::new(|_| Some(RgbaImage::filled(1, 1, Color::rgb(0.0, 1.0, 0.0)))));
        let tile = |n: u64| TextTemplateTile {
            source: TileSource::User(Id::fixed(n), PresetKind::TitleTemplate),
            name: format!("t{n}"),
            style: None,
            sample_text: String::new(),
            thumbnail: Some(vec![n as u8]),
        };
        let (a, b, c) = (tile(1), tile(2), tile(3));
        assert!(atlas.prepare(&[a.clone(), b.clone()], 1));
        assert!(!atlas.prepare(&[a.clone(), b.clone()], 4));
        let g = atlas.generation();
        assert!(!atlas.prepare(&[a.clone(), b.clone()], 4) && atlas.generation() == g);
        // `a` is gone: its cell (0) is taken by the next new tile.
        atlas.prepare(&[b.clone(), c.clone()], 4);
        assert_eq!(atlas.picture_for(&c).map(|p| p.source.0), Some(0.0));
        atlas.set_background((10, 10, 10));
        assert!(atlas.picture_for(&c).is_none() && atlas.generation() > g);
    }

    #[test]
    fn pictures_are_resized_over_the_background() {
        let half = RgbaImage { width: 1, height: 1, pixels: vec![200, 100, 0, 128] };
        let px = TextTemplateTileAtlas::resized(&half, 2, 2, (0, 0, 100));
        assert_eq!(px.len(), 16);
        assert_eq!(px[3], 255);
        assert!(px[0] > 90 && px[2] > 40 && px[2] < 60);
    }
}
