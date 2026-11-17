//! Stills for the Library's saved presets and the Keystones rows: the pictures the Effects tiles use (a transition mid-mix,
//! an effect on the sample landscape) and, for a keystone, the sample landscape in the pose of the keystone's last key.
//! A [`StillCache`] packs each finished still once into the shared thumbnail atlas ([`SharedAtlas`]) and hands the
//! window or the headless shot the upload.

use std::collections::HashMap;
use std::sync::OnceLock;

use sq_app_shell::{ATLAS_SLOT, ImageUpload};
use sq_core_effects::effect_preset::EffectPreset;
use sq_core_effects::keystone::Keystone;
use sq_core_model::anchored_animation::AnimationSample;
use sq_core_model::effect_defaults::TransitionPreset;
use sq_core_model::{GraphicsContent, GraphicsLayer, ShapeStyle};
use sq_core_time::{KeyframeTrack, SequentialIds, Time};
use sq_draw::RgbaImage;
use sq_draw_library::effects::effects_grid_model::EffectPreviewPlan;
use sq_draw_library::effects::effects_tile_atlas::EffectsTileAtlas;
use sq_draw_library::library::library_draw_panel::LibraryPicture;
use sq_editor_session::EffectDragPayload;
use sq_editor_session::GraphicPresetCatalog;
use sq_library::preset_store::{PresetItem, PresetKind};
use sq_library::title_block::TitleBlock;
use sq_library::title_template_preset::TitleTemplatePreset;
use sq_text::portable_font_match::fonts_root;
use sq_text::portable_shape_renderer::PortableShapeRenderer;
use sq_text::portable_text_renderer::{Picture, PortableTextRenderer};
use sq_text::text_generator::TextGenerator;
use sq_text::text_preset_still::TextPresetStill;

use crate::poster_pump::{Placed, SharedAtlas};

/// The canvas the graphics are built for.
const CANVAS: (i64, i64) = (1920, 1080);
const WIDTH: usize = EffectsTileAtlas::CELL_WIDTH;
const HEIGHT: usize = EffectsTileAtlas::CELL_HEIGHT;
/// Stills made per frame, so a long preset list never stalls one.
pub const BUDGET: usize = EffectsTileAtlas::BUDGET;

/// The still of a saved preset (RGBA, `EffectsTileAtlas::CELL_WIDTH` x `CELL_HEIGHT`), none when its kind has no picture.
pub fn preset_still(p: &PresetItem) -> Option<Vec<u8>> {
    match p.kind {
        PresetKind::Effect => {
            let preset =
                EffectPreset::from_payload(&p.payload, p.payload_version, &mut SequentialIds::default()).ok()?;
            EffectsTileAtlas::still(&preset.effects.first()?.kind)
        }
        PresetKind::Transition => {
            let preset = TransitionPreset::from_payload(&p.payload, p.payload_version).ok()?;
            EffectsTileAtlas::still(&EffectDragPayload::transition_id(preset.kind))
        }
        PresetKind::TitleBlock => title_block_still(&TitleBlock::from_preset(p).ok()?),
        PresetKind::TitleTemplate => {
            let png = TitleTemplatePreset::from_preset(p).ok()?.thumbnail?;
            thumbnail_still(&png)
        }
        PresetKind::Keystone => Some(keystone_still(&Keystone::from_payload(&p.payload, p.payload_version).ok()?)),
        _ => None,
    }
}

/// Decodes a PNG thumbnail and fits it into the tile (nearest neighbor, centered, transparent margins show the
/// sample landscape); none when the bytes are not a PNG.
fn thumbnail_still(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let (w, h) = (info.width as usize, info.height as usize);
    if w == 0 || h == 0 {
        return None;
    }
    let rgba = |x: usize, y: usize| -> [u8; 4] {
        let i = y * w + x;
        match info.color_type {
            png::ColorType::Rgba => [buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2], buf[i * 4 + 3]],
            png::ColorType::Rgb => [buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2], 255],
            png::ColorType::GrayscaleAlpha => [buf[i * 2], buf[i * 2], buf[i * 2], buf[i * 2 + 1]],
            _ => [buf[i], buf[i], buf[i], 255],
        }
    };
    let scale = (WIDTH as f64 / w as f64).min(HEIGHT as f64 / h as f64);
    let (dw, dh) = (((w as f64 * scale) as usize).clamp(1, WIDTH), ((h as f64 * scale) as usize).clamp(1, HEIGHT));
    let (ox, oy) = ((WIDTH - dw) / 2, (HEIGHT - dh) / 2);
    let mut out = sample().to_vec();
    for y in 0..dh {
        for x in 0..dw {
            let s = rgba(x * w / dw, y * h / dh);
            let o = ((oy + y) * WIDTH + ox + x) * 4;
            let a = u32::from(s[3]);
            for c in 0..3 {
                out[o + c] = ((u32::from(s[c]) * a + u32::from(out[o + c]) * (255 - a) + 127) / 255) as u8;
            }
            out[o + 3] = 255;
        }
    }
    Some(out)
}

/// The still of a built-in graphic (sticker, lower third, callout), none for an unknown id.
pub fn graphic_still(id: &str) -> Option<Vec<u8>> {
    let entry = GraphicPresetCatalog::entry(id)?;
    let layers = entry.layers(CANVAS.0, CANVAS.1, &mut SequentialIds::default()).ok()?;
    Some(layers_still(&layers))
}

/// The still of a saved title: its text and shape clips laid over the sample landscape.
fn title_block_still(b: &TitleBlock) -> Option<Vec<u8>> {
    let mut out = sample().to_vec();
    for e in &b.block.entries {
        let at = Time::ZERO;
        let k = HEIGHT as f64 / CANVAS.1 as f64;
        let piece = match &e.clip.generator {
            Some(g) if g.kind == "text" => text_picture(g, k).map(|p| (p, 1.0)),
            _ => e.clip.shape_style(at).and_then(|s| shape_picture(&s, k)),
        };
        let Some((pic, scale)) = piece else { continue };
        let pose = AnimationSample { scale, ..AnimationSample::REST };
        out = TextPresetStill::compose(&pic, &pose, &out, WIDTH, HEIGHT);
    }
    Some(out)
}

/// The visible text and shape layers at rest (one second in, so the pop-in has settled), over the sample landscape.
fn layers_still(layers: &[GraphicsLayer]) -> Vec<u8> {
    let at = Time::new(1, 1);
    let k = HEIGHT as f64 / CANVAS.1 as f64;
    let mut out = sample().to_vec();
    for l in layers.iter().filter(|l| l.is_visible) {
        let piece = match &l.content {
            GraphicsContent::Text { generator } => text_picture(generator, k).map(|p| (p, 1.0)),
            GraphicsContent::Shape { kind } => {
                ShapeStyle::evaluate(*kind, l.effects.first(), at).and_then(|s| shape_picture(&s, k))
            }
            GraphicsContent::Path { .. } => None,
        };
        let Some((pic, base)) = piece else { continue };
        let (pos, scale) = (l.animation.position.value_at_local(at), l.animation.scale.value_at_local(at));
        let pose = AnimationSample {
            opacity: l.animation.opacity.value_at_local(at),
            scale: base * scale.x,
            offset: pos,
            rotation: l.animation.rotation.value_at_local(at),
        };
        out = TextPresetStill::compose(&pic, &pose, &out, WIDTH, HEIGHT);
    }
    out
}

/// The text of a generator at scale `k`; none until the app has set the bundled fonts (the renderer panics without).
fn text_picture(g: &sq_core_model::GeneratorRef, k: f64) -> Option<Picture> {
    fonts_root()?;
    let (t, _) = TextGenerator::decode(g).ok()?;
    PortableTextRenderer::render(&t.text, &t.style, None, None, k, None).map(|r| r.picture)
}

/// The shape's picture and the scale that brings its sequence pixels down to the still.
fn shape_picture(s: &ShapeStyle, k: f64) -> Option<(Picture, f64)> {
    PortableShapeRenderer::render(s).map(|shape| (shape.picture, k))
}

fn sample() -> &'static [u8] {
    static A: OnceLock<Vec<u8>> = OnceLock::new();
    A.get_or_init(|| EffectPreviewPlan::sample_images(WIDTH, HEIGHT).0)
}

fn last<V: Copy>(track: &Option<KeyframeTrack<V>>) -> Option<V> {
    track.as_ref()?.keys.last().map(|k| k.value)
}

/// The sample landscape moved, scaled, turned and faded like the keystone's last key says, on a dark backdrop.
pub fn keystone_still(k: &Keystone) -> Vec<u8> {
    let (w, h) = (WIDTH as f64, HEIGHT as f64);
    let offset = last(&k.position).map_or((0.0, 0.0), |v| (v.x * w, v.y * h));
    let scale = last(&k.scale).map_or((1.0, 1.0), |v| (v.x.max(0.05), v.y.max(0.05)));
    let (sin, cos) = last(&k.rotation).unwrap_or(0.0).to_radians().sin_cos();
    let opacity = last(&k.opacity).unwrap_or(1.0).clamp(0.0, 1.0);
    let src = sample();
    let mut out = vec![255u8; WIDTH * HEIGHT * 4];
    for y in 0..HEIGHT {
        for x in 0..WIDTH {
            let (dx, dy) = (x as f64 + 0.5 - w / 2.0 - offset.0, y as f64 + 0.5 - h / 2.0 - offset.1);
            let (u, v) = ((dx * cos + dy * sin) / scale.0 + w / 2.0, (-dx * sin + dy * cos) / scale.1 + h / 2.0);
            let i = (y * WIDTH + x) * 4;
            let backdrop = 24.0;
            let inside = u >= 0.0 && v >= 0.0 && u < w && v < h;
            for c in 0..3 {
                let picture = if inside { f64::from(src[(v as usize * WIDTH + u as usize) * 4 + c]) } else { backdrop };
                let weight = if inside { opacity } else { 0.0 };
                out[i + c] = (picture * weight + backdrop * (1.0 - weight)).round() as u8;
            }
        }
    }
    out
}

/// Stills packed into the shared atlas, each made once.
#[derive(Default)]
pub struct StillCache {
    atlas: Option<SharedAtlas>,
    made: HashMap<String, Option<LibraryPicture>>,
    uploads: Vec<ImageUpload>,
}

impl StillCache {
    /// Packs into `atlas` from now on (the root's, shared with the posters).
    pub fn share_atlas(&mut self, atlas: SharedAtlas) {
        self.atlas = Some(atlas);
    }

    /// The still stored under `key`, made by `make` on first use; none when `make` has no picture or the atlas is full
    /// or not shared yet.
    pub fn picture(&mut self, key: &str, make: impl FnOnce() -> Option<Vec<u8>>) -> Option<LibraryPicture> {
        if let Some(done) = self.made.get(key) {
            return *done;
        }
        let atlas = self.atlas.as_ref()?;
        let pixels = make();
        let placed = pixels.and_then(|pixels| {
            let (x, y) = atlas.borrow_mut().place(WIDTH, HEIGHT)?;
            let at = Placed { x, y, w: WIDTH, h: HEIGHT };
            self.uploads.push(ImageUpload {
                slot: ATLAS_SLOT,
                at: Some((x, y)),
                image: RgbaImage { width: WIDTH, height: HEIGHT, pixels },
            });
            Some(LibraryPicture { slot: ATLAS_SLOT, source: at.uv(), size: at.size() })
        });
        self.made.insert(key.to_string(), placed);
        placed
    }

    /// Whether `key` was tried already.
    pub fn has(&self, key: &str) -> bool {
        self.made.contains_key(key)
    }

    /// The pictures to copy into the atlas slot since the last call.
    pub fn take_uploads(&mut self) -> Vec<ImageUpload> {
        std::mem::take(&mut self.uploads)
    }
}

#[cfg(test)]
pub(crate) mod tests;
