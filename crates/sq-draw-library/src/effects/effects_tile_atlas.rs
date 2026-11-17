// Swift: EffectsTileAtlas.swift
//! The Effects grid's tile stills packed into one image slot.

use crate::effects::effects_grid_model::{EffectPreviewPlan, PreviewStyle};
use sq_core_model::TransitionKind;
use sq_draw::RgbaImage;
use sq_text::text_preset_still::TextPresetStill;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

/// Where an Effects grid tile's still sits in the atlas: the image slot and the normalized source rect.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EffectsTilePicture {
    /// The draw list's image slot.
    pub slot: usize,
    /// Left of the source rect (0...1).
    pub x0: f32,
    /// Top of the source rect.
    pub y0: f32,
    /// Right of the source rect.
    pub x1: f32,
    /// Bottom of the source rect.
    pub y1: f32,
}

impl EffectsTilePicture {
    /// The source rect as `draw_image_slot` takes it.
    pub fn source(&self) -> [f32; 4] {
        [self.x0, self.y0, self.x1, self.y1]
    }
}

/// A block of a shared atlas slot (`size` x `size` pixels) the stills are packed into.
#[derive(Clone, Copy)]
struct Target {
    slot: usize,
    origin: (usize, usize),
    size: usize,
    max_cells: usize,
}

#[derive(Clone, Copy)]
struct Cell {
    index: usize,
    drawn: bool,
}

/// The Effects grid's tile stills, packed into one image slot (`SLOT`): the Mac `EffectPreviewStore.buildStill` picture
/// at the same 192 x 108 pixels, i.e. a video transition mid-mix of the two procedural samples (`EffectPreviewPlan`), a
/// video effect applied to sample A, a text Look or Animation drawn by the real text renderer (`TextPresetStill`) on
/// sample A. Audio transitions and ids without a preview have no still (the grid draws their icon).
/// The host calls `prepare` once per frame with the visible tile ids (a few stills per call, so scrolling never stalls
/// a frame), uploads `image` to `SLOT` when `generation` changed, and answers the panel's `picture` from `picture`.
/// Hovering a tile plays its loop in the live cell 0 (`set_hover`, `advance`).
/// shortcut: the hover loop is made on the UI thread by the first `advance` after the hover (Swift: a detached utility
/// task); a few milliseconds per loop. Upgrade when `sq-runtime` offers background jobs the UI thread can poll.
pub struct EffectsTileAtlas {
    /// Where the stills live when the host packs them into a shared atlas slot instead of `SLOT`.
    target: Option<Target>,
    pending: Vec<(usize, Vec<u8>)>,
    /// The grid's picture; its rows grow as cells are added.
    pub image: RgbaImage,
    /// Bumped on every change of `image`.
    pub generation: u64,
    cells: HashMap<String, Cell>,
    used: usize,
    loops: HashMap<String, Vec<Vec<u8>>>,
    loops_in_flight: HashSet<String>,
    hover: Option<(String, f64)>,
    live_frame: i64,
    live_id: Option<String>,
}

fn samples() -> &'static (Vec<u8>, Vec<u8>) {
    static SAMPLES: OnceLock<(Vec<u8>, Vec<u8>)> = OnceLock::new();
    SAMPLES
        .get_or_init(|| EffectPreviewPlan::sample_images(EffectsTileAtlas::CELL_WIDTH, EffectsTileAtlas::CELL_HEIGHT))
}

impl Default for EffectsTileAtlas {
    fn default() -> Self {
        EffectsTileAtlas::new()
    }
}

impl EffectsTileAtlas {
    /// The draw list's slot for the stills when unbound (`DrawList.IMAGE_SLOTS`: 4 the Text panel's template tiles; the
    /// window binds the atlas into the shared thumbnail slot, slot 5 is the Source picture).
    pub const SLOT: usize = 5;
    /// Pixel width of a cell.
    pub const CELL_WIDTH: usize = EffectPreviewPlan::SAMPLE_WIDTH;
    /// Pixel height of a cell.
    pub const CELL_HEIGHT: usize = EffectPreviewPlan::SAMPLE_HEIGHT;
    /// Cells per row.
    pub const COLUMNS: usize = 8;
    /// Stills made per `prepare` call.
    pub const BUDGET: usize = 4;

    /// An atlas without cells. Cell 0 is the live cell: the hovered tile's loop frame (30 Hz).
    pub fn new() -> EffectsTileAtlas {
        EffectsTileAtlas {
            target: None,
            pending: Vec::new(),
            image: RgbaImage { width: Self::CELL_WIDTH * Self::COLUMNS, height: 0, pixels: Vec::new() },
            generation: 0,
            cells: HashMap::new(),
            used: 1,
            loops: HashMap::new(),
            loops_in_flight: HashSet::new(),
            hover: None,
            live_frame: -1,
            live_id: None,
        }
    }

    /// Packs the stills into the block at `origin` of the `size` x `size` image slot `slot` (a shared atlas) instead of
    /// the slot `SLOT`: `rows` rows of `COLUMNS` cells; stills beyond that fall back to the icon. Call before `prepare`.
    pub fn bind(&mut self, slot: usize, origin: (usize, usize), size: usize, rows: usize) {
        self.target = Some(Target { slot, origin, size, max_cells: rows * Self::COLUMNS });
    }

    /// The block `bind` needs: width and height in pixels for `rows` rows.
    pub fn block_size(rows: usize) -> (usize, usize) {
        (Self::COLUMNS * Self::CELL_WIDTH, rows * Self::CELL_HEIGHT)
    }

    /// The cells made since the last call as `(slot, x, y, picture)` in the bound slot's pixels.
    pub fn take_uploads(&mut self) -> Vec<(usize, usize, usize, RgbaImage)> {
        let Some(t) = self.target else { return Vec::new() };
        std::mem::take(&mut self.pending)
            .into_iter()
            .map(|(index, pixels)| {
                let x = t.origin.0 + (index % Self::COLUMNS) * Self::CELL_WIDTH;
                let y = t.origin.1 + (index / Self::COLUMNS) * Self::CELL_HEIGHT;
                (t.slot, x, y, RgbaImage { width: Self::CELL_WIDTH, height: Self::CELL_HEIGHT, pixels })
            })
            .collect()
    }

    /// The tile whose loop is playing in the live cell (none: none, or its loop is not made yet).
    pub fn live_id(&self) -> Option<&str> {
        self.live_id.as_deref()
    }

    /// Makes up to `budget` missing stills of `ids` (in order); true while some are still missing. Cells are kept for
    /// the session (as the Mac store's stills): the catalog is a few dozen tiles.
    pub fn prepare(&mut self, ids: &[String], budget: usize) -> bool {
        let (mut made, mut left) = (0, false);
        for id in ids {
            if self.cells.contains_key(id) {
                continue;
            }
            if made >= budget {
                left = true;
                break;
            }
            made += 1;
            if self.target.is_some_and(|t| self.used >= t.max_cells) {
                self.cells.insert(id.clone(), Cell { index: 0, drawn: false });
                continue;
            }
            let Some(px) = Self::still(id) else {
                self.cells.insert(id.clone(), Cell { index: 0, drawn: false });
                continue;
            };
            let index = self.used;
            self.used += 1;
            self.blit(&px, index);
            self.cells.insert(id.clone(), Cell { index, drawn: true });
        }
        if made > 0 {
            self.generation += 1;
        }
        left
    }

    /// The pointer is over tile `id` (none: none). The loop is made on first use and cached.
    pub fn set_hover(&mut self, id: Option<&str>, now: f64) {
        if id == self.hover.as_ref().map(|h| h.0.as_str()) {
            return;
        }
        self.hover = id.map(|i| (i.to_string(), now));
        self.live_id = None;
        self.live_frame = -1;
        if let Some(id) = id
            && !self.loops.contains_key(id)
        {
            self.loops_in_flight.insert(id.to_string());
        }
    }

    /// Puts the hovered tile's loop frame for `now` into the live cell (a new frame bumps `generation`).
    pub fn advance(&mut self, now: f64) {
        let Some((id, start)) = self.hover.clone() else { return };
        if self.loops_in_flight.remove(&id) {
            self.loops.insert(id.clone(), Self::loop_frames(&id).unwrap_or_default());
        }
        let Some(frame_pixels) = self.loops.get(&id).filter(|l| !l.is_empty()) else { return };
        let count = frame_pixels.len();
        let f = ((now - start).max(0.0) * EffectPreviewPlan::FPS) as usize % count;
        if f as i64 == self.live_frame && self.live_id.as_deref() == Some(id.as_str()) {
            return;
        }
        self.live_frame = f as i64;
        self.live_id = Some(id.clone());
        let px = frame_pixels[f].clone();
        self.blit(&px, 0);
        self.generation += 1;
    }

    /// The tile's still, none while it is not made (or the id has none); the live cell while its loop plays.
    pub fn picture(&self, id: &str) -> Option<EffectsTilePicture> {
        let index = if self.live_id.as_deref() == Some(id) {
            0
        } else {
            let c = self.cells.get(id).filter(|c| c.drawn)?;
            c.index
        };
        if self.image.height == 0 {
            return None;
        }
        let x = (index % Self::COLUMNS) * Self::CELL_WIDTH;
        let y = (index / Self::COLUMNS) * Self::CELL_HEIGHT;
        if let Some(t) = self.target {
            let (x, y, s) = ((t.origin.0 + x) as f32, (t.origin.1 + y) as f32, t.size as f32);
            let (cw, ch) = (Self::CELL_WIDTH as f32, Self::CELL_HEIGHT as f32);
            return Some(EffectsTilePicture { slot: t.slot, x0: x / s, y0: y / s, x1: (x + cw) / s, y1: (y + ch) / s });
        }
        let (w, h) = (self.image.width as f32, self.image.height as f32);
        Some(EffectsTilePicture {
            slot: Self::SLOT,
            x0: x as f32 / w,
            y0: y as f32 / h,
            x1: (x + Self::CELL_WIDTH) as f32 / w,
            y1: (y + Self::CELL_HEIGHT) as f32 / h,
        })
    }

    /// The still's opaque RGBA pixels (`EffectPreviewStore.buildStill`), none for audio transitions and unknown ids.
    pub fn still(id: &str) -> Option<Vec<u8>> {
        let (w, h) = (Self::CELL_WIDTH, Self::CELL_HEIGHT);
        let s = samples();
        match EffectPreviewPlan::style(id)? {
            PreviewStyle::VideoTransition(k) => {
                let weight = if k == TransitionKind::CrossDissolve { 0.5 } else { 0.3 };
                Some(EffectPreviewPlan::blend(&s.0, &s.1, k, weight))
            }
            PreviewStyle::Effect(e) => {
                Some(EffectPreviewPlan::effect_after(&e, &EffectPreviewPlan::effect_before(&e, &s.0, w, h), w, h))
            }
            PreviewStyle::TextPreset(t) => TextPresetStill::still(&t, &s.0, w, h),
            PreviewStyle::AudioTransition(_) => None,
        }
    }

    /// The loop frames of a video transition (hold, mix, hold) or an effect (before, after); none for the rest (text
    /// presets: the Mac loop is drawn with CoreGraphics, they keep their still on Windows).
    pub fn loop_frames(id: &str) -> Option<Vec<Vec<u8>>> {
        let (w, h) = (Self::CELL_WIDTH, Self::CELL_HEIGHT);
        let s = samples();
        match EffectPreviewPlan::style(id)? {
            PreviewStyle::VideoTransition(k) => {
                let mut cache: Vec<(f64, Vec<u8>)> = vec![(0.0, s.0.clone()), (1.0, s.1.clone())];
                let mut out = Vec::new();
                for wgt in EffectPreviewPlan::transition_loop() {
                    if let Some((_, c)) = cache.iter().find(|(k, _)| *k == wgt) {
                        out.push(c.clone());
                        continue;
                    }
                    let img = EffectPreviewPlan::blend(&s.0, &s.1, k, wgt);
                    cache.push((wgt, img.clone()));
                    out.push(img);
                }
                Some(out)
            }
            PreviewStyle::Effect(e) => {
                let before = EffectPreviewPlan::effect_before(&e, &s.0, w, h);
                let half = (EffectPreviewPlan::FPS * 0.9) as usize;
                let after = EffectPreviewPlan::effect_after(&e, &before, w, h);
                let mut out = vec![before; half];
                out.extend(std::iter::repeat_n(after, half));
                Some(out)
            }
            PreviewStyle::TextPreset(_) | PreviewStyle::AudioTransition(_) => None,
        }
    }

    fn blit(&mut self, px: &[u8], index: usize) {
        let (cw, ch) = (Self::CELL_WIDTH, Self::CELL_HEIGHT);
        let row_bytes = self.image.width * 4;
        if px.len() < cw * ch * 4 {
            return;
        }
        if self.target.is_some() {
            self.pending.push((index, px[..cw * ch * 4].to_vec()));
        }
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effects::effects_draw_panel::EffectsDrawPanel;
    use crate::effects::effects_grid_model::EffectsViewMode;
    use crate::test_support::MemoryDefaults;
    use sq_core_effects::transition::ALL_TRANSITION_KINDS;
    use sq_core_model::{ClipEffect, TrackKind};
    use sq_core_time::SequentialIds;
    use sq_draw::draw_list::QuadKind;
    use sq_draw::{Canvas, DrawList, DrawTheme};
    use sq_editor_session::EffectDragPayload;
    use sq_text::text_presets::TextPresetCatalog;
    use sq_uikit::appearance_palette::AppearanceSettings;

    fn dissolve() -> String {
        EffectDragPayload::transition_id(TransitionKind::CrossDissolve)
    }
    fn audio() -> String {
        ALL_TRANSITION_KINDS
            .iter()
            .find(|k| k.track_kind() == TrackKind::Audio)
            .map(|k| EffectDragPayload::transition_id(*k))
            .unwrap_or_default()
    }

    #[test]
    fn a_bound_atlas_names_cells_of_the_shared_slot_and_hands_out_their_pixels() {
        let mut atlas = EffectsTileAtlas::new();
        atlas.bind(0, (10, 20), 2048, 1);
        let ids = vec![dissolve(), ClipEffect::GAUSSIAN_BLUR_KIND.to_string()];
        atlas.prepare(&ids, 2);
        let p = atlas.picture(&ids[0]).expect("picture");
        let (x, y) = (10.0 + EffectsTileAtlas::CELL_WIDTH as f32, 20.0);
        assert_eq!((p.slot, p.x0, p.y0), (0, x / 2048.0, y / 2048.0));
        let uploads = atlas.take_uploads();
        assert_eq!(uploads.len(), 2);
        assert_eq!((uploads[0].0, uploads[0].1, uploads[0].2), (0, 10 + EffectsTileAtlas::CELL_WIDTH, 20));
        assert!(atlas.take_uploads().is_empty());
    }

    #[test]
    fn stills_are_packed_a_few_per_frame_and_match_the_preview_plan() {
        // The fonts stay in the Swift package; the app points the text renderer at its own copy.
        sq_text::portable_font_match::set_fonts_root(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
        );
        let mut atlas = EffectsTileAtlas::new();
        let look = TextPresetCatalog::looks()[0].id.clone();
        let text_id = format!("{}{look}", TextPresetCatalog::LOOK_PREFIX);
        let ids =
            vec![dissolve(), ClipEffect::GAUSSIAN_BLUR_KIND.to_string(), text_id.clone(), audio(), "unknown.id".into()];
        assert!(atlas.prepare(&ids, 2)); // more to make
        assert!(atlas.picture(&ids[0]).is_some() && atlas.picture(&ids[1]).is_some());
        assert!(atlas.picture(&ids[2]).is_none());
        let g = atlas.generation;
        assert!(!atlas.prepare(&ids, EffectsTileAtlas::BUDGET));
        assert_eq!(atlas.generation, g + 1);
        assert!(atlas.picture(&ids[3]).is_none() && atlas.picture("unknown.id").is_none());
        let text = atlas.picture(&text_id).expect("text still");
        assert!(text.slot == EffectsTileAtlas::SLOT && text.slot < DrawList::IMAGE_SLOTS);
        assert!(!atlas.prepare(&ids, EffectsTileAtlas::BUDGET) && atlas.generation == g + 1); // nothing new: no re-upload
        // The cross dissolve cell holds the mid mix of the two samples.
        let (w, h) = (EffectsTileAtlas::CELL_WIDTH, EffectsTileAtlas::CELL_HEIGHT);
        let samples = EffectPreviewPlan::sample_images(w, h);
        let want = EffectPreviewPlan::blend(&samples.0, &samples.1, TransitionKind::CrossDissolve, 0.5);
        let pic = atlas.picture(&ids[0]).expect("dissolve still");
        let x0 = (pic.x0 * atlas.image.width as f32).round() as usize;
        let y0 = (pic.y0 * atlas.image.height as f32).round() as usize;
        for (x, y) in [(10, 10), (96, 54), (180, 100)] {
            let i = ((y0 + y) * atlas.image.width + x0 + x) * 4;
            let j = (y * w + x) * 4;
            assert_eq!(atlas.image.pixels[i..i + 4], want[j..j + 4]);
        }
    }

    #[test]
    fn hovering_a_tile_plays_its_loop_in_the_live_cell() {
        let mut atlas = EffectsTileAtlas::new();
        atlas.prepare(&[dissolve()], EffectsTileAtlas::BUDGET);
        atlas.set_hover(Some(&dissolve()), 100.0);
        assert!(atlas.live_id().is_none()); // the loop is made on the first advance
        atlas.advance(100.0);
        assert_eq!(atlas.live_id(), Some(dissolve().as_str()));
        let still = atlas.picture(&dissolve()).expect("live picture");
        assert!(still.y0 == 0.0 && still.x0 == 0.0); // the live cell is cell 0
        let g = atlas.generation;
        atlas.advance(100.0); // the same loop frame: no new upload
        assert_eq!(atlas.generation, g);
        atlas.advance(100.5); // half a second in: mid mix
        assert_eq!(atlas.generation, g + 1);
        let (w, h) = (EffectsTileAtlas::CELL_WIDTH, EffectsTileAtlas::CELL_HEIGHT);
        let samples = EffectPreviewPlan::sample_images(w, h);
        let want = EffectPreviewPlan::blend(
            &samples.0,
            &samples.1,
            TransitionKind::CrossDissolve,
            EffectPreviewPlan::transition_loop()[15],
        );
        let i = (54 * atlas.image.width + 96) * 4;
        let j = (54 * w + 96) * 4;
        assert_eq!(atlas.image.pixels[i..i + 4], want[j..j + 4]);
        atlas.set_hover(None, 101.0);
        assert!(atlas.live_id().is_none());
    }

    #[test]
    fn the_grid_draws_the_still_once_it_is_made() {
        let mut panel = EffectsDrawPanel::new(Box::new(MemoryDefaults::default()), Box::new(SequentialIds::default()));
        panel.set_view_mode(EffectsViewMode::Grid);
        panel.set_query("dissolve"); // a search opens the folders with hits
        panel.size = sq_uikit::controls_grid::CGSize::new(260.0, 2000.0);
        let mut atlas = EffectsTileAtlas::new();
        let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
        let mut ui = sq_draw::UiCx::new();
        let mut image_quads = |panel: &mut EffectsDrawPanel, atlas: &EffectsTileAtlas| {
            let mut c = Canvas::with_size(260.0, 2000.0, None, 1.0);
            panel.draw(&mut c, &theme, &mut ui, &|id| atlas.picture(id));
            c.list
                .quads()
                .iter()
                .filter(|q| q.kind == QuadKind::Image && q.slot == EffectsTileAtlas::SLOT as f32)
                .count()
        };
        assert_eq!(image_quads(&mut panel, &atlas), 0);
        let visible = panel.visible_tile_ids();
        assert!(visible.contains(&dissolve()));
        atlas.prepare(&visible, 1000);
        let made = visible.iter().filter(|v| atlas.picture(v).is_some()).count();
        assert_eq!(image_quads(&mut panel, &atlas), made);
        assert!(made > 0);
        panel.set_view_mode(EffectsViewMode::List);
        assert!(panel.visible_tile_ids().is_empty());
    }
}
