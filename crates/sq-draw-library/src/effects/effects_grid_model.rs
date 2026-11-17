// Swift: EffectsGridModel.swift
//! Pure logic behind the Effects grid: the layout mode, the thumbnail and hover-preview pictures and the tile layout.

use crate::effects::effects_catalog::EffectsRow;
use sq_core_effects::transition::TransitionMix;
use sq_core_model::{ClipEffect, EffectCatalog, TrackKind, TransitionKind};
use sq_editor_session::EffectDragPayload;
use sq_text::text_presets::TextPresetCatalog;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;

/// Effects panel layout mode, persisted like the Project and Library panels (own defaults key).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectsViewMode {
    /// Rows.
    List,
    /// Tiles.
    Grid,
}

impl EffectsViewMode {
    /// The settings key.
    pub const KEY: &'static str = "EffectsPanel.viewMode";

    /// The stored name.
    pub fn raw_value(self) -> &'static str {
        match self {
            EffectsViewMode::List => "list",
            EffectsViewMode::Grid => "grid",
        }
    }

    /// The saved mode (list when none).
    pub fn load(d: &dyn UiDefaults) -> EffectsViewMode {
        match d.string(Self::KEY).as_deref() {
            Some("grid") => EffectsViewMode::Grid,
            _ => EffectsViewMode::List,
        }
    }

    /// Saves the mode.
    pub fn save(self, d: &mut dyn UiDefaults) {
        d.set_string(Self::KEY, self.raw_value());
    }
}

/// What a tile's still or loop shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreviewStyle {
    /// A video transition mixed on the two samples.
    VideoTransition(TransitionKind),
    /// An audio transition (no picture).
    AudioTransition(TransitionKind),
    /// A video effect applied to sample A.
    Effect(String),
    /// A text Look or Animation (`TextPresetCatalog` id): drawn by the real text renderer.
    TextPreset(String),
}

/// Pure logic behind the Effects grid thumbnails and hover previews. Everything is RGBA8 bytes (alpha 255), made in code
/// (no licensed media). Transitions are mixed with `TransitionMix`, the same maths as the render path, so the preview
/// shows what the compositor will do; the work is a few hundred bytes-blends at thumbnail size, done once and cached.
pub enum EffectPreviewPlan {}

impl EffectPreviewPlan {
    /// Loop frame rate.
    pub const FPS: f64 = 30.0;
    /// One second at `FPS`: hold A, mix, hold B.
    pub const LOOP_FRAMES: i64 = 30;
    /// Frames held on A and on B.
    pub const HOLD_FRAMES: i64 = 4;
    /// Frames of the mix.
    pub const MIX_FRAMES: i64 = Self::LOOP_FRAMES - 2 * Self::HOLD_FRAMES;
    /// Thumbnail raster width (16:9; drawn at 2x for a ~96 pt tile).
    pub const SAMPLE_WIDTH: usize = 192;
    /// Thumbnail raster height.
    pub const SAMPLE_HEIGHT: usize = 108;

    /// Incoming weight (0 = A only, 1 = B only) per loop frame.
    pub fn transition_loop() -> Vec<f64> {
        let mut out = vec![0.0; Self::HOLD_FRAMES as usize];
        out.extend((0..Self::MIX_FRAMES).map(|i| TransitionMix::video_weight(i, Self::MIX_FRAMES)));
        out.extend(vec![1.0; Self::HOLD_FRAMES as usize]);
        out
    }

    /// The style of a panel row id; none for ids without a preview.
    pub fn style(id: &str) -> Option<PreviewStyle> {
        if TextPresetCatalog::is_text_preset_id(id) {
            return Some(PreviewStyle::TextPreset(id.to_string()));
        }
        if let Some(k) = EffectDragPayload::transition_kind(id) {
            return Some(if k.track_kind() == TrackKind::Video {
                PreviewStyle::VideoTransition(k)
            } else {
                PreviewStyle::AudioTransition(k)
            });
        }
        EffectCatalog::spec_for(id).map(|_| PreviewStyle::Effect(id.to_string()))
    }

    // MARK: Mixing

    /// Blends two RGBA buffers with the render path's mix at incoming weight `w`.
    pub fn blend(a: &[u8], b: &[u8], kind: TransitionKind, w: f64) -> Vec<u8> {
        let m = TransitionMix::video(kind, w);
        let dip = TransitionMix::dip_color(kind, None);
        let (o, inc) = (m.outgoing, m.incoming);
        let d = (m.dip * f64::from(dip[0]), m.dip * f64::from(dip[1]), m.dip * f64::from(dip[2]));
        let mut out = a.to_vec();
        let mut i = 0;
        let n = a.len();
        while i + 2 < n {
            let r = o * f64::from(a[i]) + inc * f64::from(b[i]) + d.0;
            let g = o * f64::from(a[i + 1]) + inc * f64::from(b[i + 1]) + d.1;
            let bl = o * f64::from(a[i + 2]) + inc * f64::from(b[i + 2]) + d.2;
            out[i] = r.round().clamp(0.0, 255.0) as u8;
            out[i + 1] = g.round().clamp(0.0, 255.0) as u8;
            out[i + 2] = bl.round().clamp(0.0, 255.0) as u8;
            i += 4;
        }
        out
    }

    // MARK: Sample images

    /// Two clearly different landscapes: a warm sunset over dark ridges (A) and a cool green valley under a pale sky (B).
    pub fn sample_images(w: usize, h: usize) -> (Vec<u8>, Vec<u8>) {
        let mut a = vec![255u8; w * h * 4];
        let mut b = a.clone();
        fn put(buf: &mut [u8], w: usize, x: usize, y: usize, r: f64, g: f64, bl: f64) {
            let i = (y * w + x) * 4;
            buf[i] = r.clamp(0.0, 255.0) as u8;
            buf[i + 1] = g.clamp(0.0, 255.0) as u8;
            buf[i + 2] = bl.clamp(0.0, 255.0) as u8;
        }
        for y in 0..h {
            let t = y as f64 / (h as f64 - 1.0);
            for x in 0..w {
                let u = x as f64 / (w as f64 - 1.0);
                // A: sky from deep blue to orange, sun, two ridges.
                let (mut r, mut g, mut bl) = (40.0 + 215.0 * t, 60.0 + 120.0 * t * t, 140.0 - 90.0 * t);
                let dx = (u - 0.68) * w as f64;
                let dy = (t - 0.62) * h as f64;
                let sun = (1.0 - (dx * dx + dy * dy).sqrt() / (0.16 * h as f64)).max(0.0);
                r += 200.0 * sun;
                g += 170.0 * sun;
                bl += 60.0 * sun;
                let ridge1 = 0.74 + 0.08 * (u * 9.0).sin() + 0.04 * (u * 23.0 + 1.0).sin();
                let ridge2 = 0.86 + 0.05 * (u * 6.0 + 2.0).sin();
                if t > ridge2 {
                    (r, g, bl) = (18.0, 20.0, 30.0);
                } else if t > ridge1 {
                    (r, g, bl) = (52.0, 40.0, 60.0);
                }
                put(&mut a, w, x, y, r, g, bl);
                // B: pale cyan sky, rolling green hills, a lake.
                let (mut r2, mut g2, mut b2) = (150.0 + 70.0 * (1.0 - t), 200.0 + 40.0 * (1.0 - t), 235.0 - 30.0 * t);
                let hill1 = 0.55 + 0.10 * (u * 5.0 + 0.5).sin() + 0.03 * (u * 17.0).sin();
                let hill2 = 0.70 + 0.07 * (u * 7.0 + 3.0).sin();
                if t > 0.9 {
                    (r2, g2, b2) = (40.0, 110.0, 150.0);
                } else if t > hill2 {
                    (r2, g2, b2) = (40.0, 120.0 + 40.0 * u, 60.0);
                } else if t > hill1 {
                    (r2, g2, b2) = (90.0, 150.0, 90.0);
                }
                put(&mut b, w, x, y, r2, g2, b2);
            }
        }
        (a, b)
    }

    // MARK: Effect before/after

    /// "After" image for a video effect applied to `src` (the "before" is `src` itself). Same ideas as the render blocks,
    /// simplified to the thumbnail size.
    pub fn effect_after(id: &str, src: &[u8], w: usize, h: usize) -> Vec<u8> {
        if id == ClipEffect::GAUSSIAN_BLUR_KIND {
            return Self::box_blur(src, w, h, 4, 3);
        }
        if id == ClipEffect::CROP_KIND {
            let mut out = src.to_vec();
            let (mx, my) = (w / 6, h / 6);
            for y in 0..h {
                for x in 0..w {
                    if x < mx || x + mx >= w || y < my || y + my >= h {
                        let i = (y * w + x) * 4;
                        out[i] = 0;
                        out[i + 1] = 0;
                        out[i + 2] = 0;
                    }
                }
            }
            return out;
        }
        if id == ClipEffect::ROUNDED_CORNERS_KIND {
            let mut out = src.to_vec();
            let r = w.min(h) as f64 * 0.28;
            for y in 0..h {
                for x in 0..w {
                    let cx = (x as f64 + 0.5).max(r).min(w as f64 - r);
                    let cy = (y as f64 + 0.5).max(r).min(h as f64 - r);
                    let d = ((x as f64 + 0.5 - cx) * (x as f64 + 0.5 - cx)
                        + (y as f64 + 0.5 - cy) * (y as f64 + 0.5 - cy))
                        .sqrt();
                    if d > r {
                        let i = (y * w + x) * 4;
                        out[i] = 0;
                        out[i + 1] = 0;
                        out[i + 2] = 0;
                    }
                }
            }
            return out;
        }
        if id == ClipEffect::ULTRA_KEY_KIND {
            let mut out = src.to_vec();
            for y in 0..h {
                for x in 0..w {
                    let i = (y * w + x) * 4;
                    if Self::key_is_green(src[i], src[i + 1], src[i + 2]) {
                        let on = ((x / 8) + (y / 8)) % 2 == 0;
                        let v: u8 = if on { 90 } else { 55 };
                        out[i] = v;
                        out[i + 1] = v;
                        out[i + 2] = v;
                    }
                }
            }
            return out;
        }
        src.to_vec()
    }

    /// "Before" image for an effect: the sample, except Ultra Key which needs a green backdrop to key.
    pub fn effect_before(id: &str, sample: &[u8], w: usize, h: usize) -> Vec<u8> {
        if id != ClipEffect::ULTRA_KEY_KIND {
            return sample.to_vec();
        }
        let mut out = sample.to_vec();
        for y in 0..h {
            for x in 0..w {
                let dx = (x as f64 / w as f64 - 0.5) * 16.0;
                let dy = (y as f64 / h as f64 - 0.55) * 9.0;
                let i = (y * w + x) * 4;
                if dx * dx + dy * dy > 6.5 {
                    // green screen around the subject
                    out[i] = 20;
                    out[i + 1] = 200;
                    out[i + 2] = 60;
                }
            }
        }
        out
    }

    /// Whether a pixel is on the green screen.
    pub fn key_is_green(r: u8, g: u8, b: u8) -> bool {
        i64::from(g) > i64::from(r) + 60 && i64::from(g) > i64::from(b) + 60
    }

    /// Box blur, `passes` times horizontal then vertical, edge pixels repeated.
    pub fn box_blur(src: &[u8], w: usize, h: usize, radius: i64, passes: usize) -> Vec<u8> {
        let mut cur = src.to_vec();
        let mut tmp = src.to_vec();
        let (wi, hi) = (w as i64, h as i64);
        let win = 2 * radius + 1;
        for _ in 0..passes {
            for y in 0..h {
                // horizontal
                for c in 0..3 {
                    let mut sum: i64 = 0;
                    for x in -radius..=radius {
                        sum += i64::from(cur[(y * w + x.clamp(0, wi - 1) as usize) * 4 + c]);
                    }
                    for x in 0..wi {
                        tmp[(y * w + x as usize) * 4 + c] = (sum / win) as u8;
                        let add = (x + radius + 1).min(wi - 1);
                        let sub = (x - radius).max(0);
                        sum += i64::from(cur[(y * w + add as usize) * 4 + c])
                            - i64::from(cur[(y * w + sub as usize) * 4 + c]);
                    }
                }
            }
            for x in 0..w {
                // vertical
                for c in 0..3 {
                    let mut sum: i64 = 0;
                    for y in -radius..=radius {
                        sum += i64::from(tmp[(y.clamp(0, hi - 1) as usize * w + x) * 4 + c]);
                    }
                    for y in 0..hi {
                        cur[(y as usize * w + x) * 4 + c] = (sum / win) as u8;
                        let add = (y + radius + 1).min(hi - 1);
                        let sub = (y - radius).max(0);
                        sum += i64::from(tmp[(add as usize * w + x) * 4 + c])
                            - i64::from(tmp[(sub as usize * w + x) * 4 + c]);
                    }
                }
            }
        }
        cur
    }
}

/// One item of the grid layout.
#[derive(Clone, Debug, PartialEq)]
pub struct GridItem {
    /// The row id.
    pub id: String,
    /// Shown title.
    pub title: String,
    /// Icon shown until the still is made.
    pub symbol: SQIcon,
    /// A heading over the tiles below it.
    pub is_header: bool,
    /// The item's frame (content coordinates).
    pub frame: CGRect,
    /// The thumbnail inside a tile (16:9); empty for headers.
    pub thumb: CGRect,
}

/// Tile layout of the Effects grid: category headers span the width, tiles flow left to right under them.
#[derive(Clone, Debug, Default)]
pub struct EffectsGridLayout {
    /// Headers and tiles in row order.
    pub items: Vec<GridItem>,
    /// Tiles per row.
    pub columns: i64,
    /// Height of all content.
    pub content_height: f64,
}

impl EffectsGridLayout {
    /// Space around the tiles.
    pub const PAD: f64 = 8.0;
    /// Space between tiles.
    pub const GAP: f64 = 8.0;
    /// Height of a header.
    pub const HEADER_HEIGHT: f64 = 24.0;
    /// Height of a tile's caption.
    pub const CAPTION_HEIGHT: f64 = 18.0;

    /// Lays `rows` out for `width` and tiles of `tile_width`.
    pub fn new(rows: &[EffectsRow], width: f64, tile_width: f64) -> EffectsGridLayout {
        let (pad, gap) = (Self::PAD, Self::GAP);
        let columns = (((width - 2.0 * pad + gap) / (tile_width + gap)) as i64).max(1);
        let thumb_h = (tile_width * 9.0 / 16.0).round();
        let tile_h = thumb_h + Self::CAPTION_HEIGHT;
        let mut items = Vec::new();
        let (mut y, mut col) = (4.0, 0i64);
        for r in rows {
            if r.is_header {
                if col > 0 {
                    y += tile_h + gap;
                    col = 0;
                }
                items.push(GridItem {
                    id: r.id.clone(),
                    title: r.title.clone(),
                    symbol: r.symbol,
                    is_header: true,
                    frame: CGRect::new(0.0, y, width, Self::HEADER_HEIGHT),
                    thumb: CGRect::default(),
                });
                y += Self::HEADER_HEIGHT;
                continue;
            }
            let x = pad + col as f64 * (tile_width + gap);
            items.push(GridItem {
                id: r.id.clone(),
                title: r.title.clone(),
                symbol: r.symbol,
                is_header: false,
                frame: CGRect::new(x, y, tile_width, tile_h),
                thumb: CGRect::new(x, y, tile_width, thumb_h),
            });
            col += 1;
            if col == columns {
                y += tile_h + gap;
                col = 0;
            }
        }
        if col > 0 {
            y += tile_h + gap;
        }
        EffectsGridLayout { items, columns, content_height: y + 4.0 }
    }

    /// The tile under `p` (headers are not targets).
    pub fn hit(&self, p: CGPoint) -> Option<&str> {
        self.items.iter().find(|i| !i.is_header && i.frame.contains(p)).map(|i| i.id.as_str())
    }
}
