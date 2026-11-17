//! The GPU renderer of a [`DrawList`] (Swift `MetalDrawListRenderer` and the D3D12 shim): one instanced draw of the
//! 80-byte quads through sq-gpu's `DrawQuads` pipeline and its fixed binding layout (constants b0, glyph page t0, picture t1,
//! image slots t3...t8, quads t9). Straight-alpha blend in sRGB code values, as [`crate::software::SoftwareRenderer`].
//!
//! One renderer serves one window, so one glyph atlas (one display scale): the page texture mirrors the atlas and only its
//! dirty rect is uploaded per frame ([`GlyphAtlas::take_dirty`]; do not share an atlas between renderers).

use crate::draw_list::{Color, DrawList, DrawQuad};
use crate::glyph_atlas::{DirtyRect, GlyphAtlas};
use crate::software::RgbaImage;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines::{Blend, Primitive, RenderKey, RenderPipeline};
use std::sync::Arc;

/// First input slot of the image textures (`image0` is `t3`).
const IMAGE_SLOT0: usize = 3;
/// The slot of the picture (`luma`, `t1`).
const VIDEO_SLOT: usize = 1;

/// What the video quad shows in one draw: its picture (`Keep`), plain black or plain white. The extended-range window path
/// draws the UI twice, with `Black` and `White`, to learn where the HDR picture shows through ([`crate::hdr_present`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoOverride {
    Keep,
    Black,
    White,
}

/// Draws draw lists with wgpu.
pub struct WgpuRenderer {
    gpu: Arc<Gpu>,
    pipeline: Arc<RenderPipeline>,
    atlas: Option<GpuTexture>,
    /// The atlas generation this renderer last uploaded.
    atlas_seen: u64,
    images: [Option<GpuTexture>; DrawList::IMAGE_SLOTS],
    video: Option<GpuTexture>,
    /// `video` is a texture someone else owns ([`Self::set_video_texture`]): never upload into it.
    video_shared: bool,
    /// A 1x1 white texture for [`VideoOverride::White`].
    white: Option<GpuTexture>,
    /// A 1x1 opaque black texture for an image slot drawn with [`VideoOverride::Black`].
    black: Option<GpuTexture>,
    quads: Option<(wgpu::Buffer, u64)>,
    bytes: Vec<u8>,
}

impl WgpuRenderer {
    /// A renderer for targets of `format` (`Bgra8Unorm` for windows, `Rgba8Unorm` for readback).
    pub fn new(gpu: Arc<Gpu>, format: PixelFormat) -> Result<WgpuRenderer, GpuError> {
        let pipeline = gpu.render_pipeline(RenderKey {
            module: "DrawQuads",
            vertex: "quadVertex",
            fragment: "quadFragment",
            format,
            blend: Blend::StraightOver,
            primitive: Primitive::Triangles,
        })?;
        Ok(WgpuRenderer {
            gpu,
            pipeline,
            atlas: None,
            atlas_seen: 0,
            images: Default::default(),
            video: None,
            video_shared: false,
            white: None,
            black: None,
            quads: None,
            bytes: Vec::new(),
        })
    }

    fn upload(&self, tex: &GpuTexture, img: &RgbaImage) {
        self.gpu.upload_texture(tex, &img.pixels, img.width as u32 * 4);
    }

    /// Uploads image slot `slot` (0...5). The slot's texture is recreated when the size changes.
    pub fn set_image(&mut self, slot: usize, img: &RgbaImage) {
        let Some(cell) = self.images.get_mut(slot) else { return };
        let same = cell.as_ref().is_some_and(|t| (t.width(), t.height()) == (img.width as u32, img.height as u32));
        if !same {
            *cell = Some(self.gpu.texture(img.width as u32, img.height as u32, PixelFormat::Rgba8Unorm));
        }
        if let Some(t) = &self.images[slot] {
            self.upload(t, img);
        }
    }

    /// Sets (or with `None` removes) the picture of the video quad; without one the quad is black.
    pub fn set_video(&mut self, img: Option<&RgbaImage>) {
        let Some(img) = img else {
            self.video = None;
            return;
        };
        let same = !self.video_shared
            && self.video.as_ref().is_some_and(|t| (t.width(), t.height()) == (img.width as u32, img.height as u32));
        if !same {
            self.video_shared = false;
            self.video = Some(self.gpu.texture(img.width as u32, img.height as u32, PixelFormat::Rgba8Unorm));
        }
        if let Some(t) = &self.video {
            self.upload(t, img);
        }
    }

    /// Draws the video quad straight from `texture` (display-ready `Rgba8Unorm` code values on this renderer's device),
    /// with no upload; `None` removes the picture.
    pub fn set_video_texture(&mut self, texture: Option<&GpuTexture>) {
        self.video = texture.cloned();
        self.video_shared = texture.is_some();
    }

    /// Brings the page texture up to date: the whole page the first time, then the dirty rect only.
    fn sync_atlas(&mut self, atlas: &GlyphAtlas) {
        let size = atlas.size();
        // Each renderer keeps its own last seen generation: the window and the floating windows share one atlas.
        let region = if self.atlas.is_none() {
            self.atlas = Some(self.gpu.texture(size, size, PixelFormat::R8Unorm));
            Some(DirtyRect { x: 0, y: 0, w: size, h: size })
        } else {
            atlas.dirty_since(self.atlas_seen)
        };
        self.atlas_seen = atlas.generation();
        let (Some(r), Some(tex)) = (region, &self.atlas) else { return };
        atlas.with_pixels(|pixels| {
            self.gpu.queue().write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: tex.texture(),
                    mip_level: 0,
                    origin: wgpu::Origin3d { x: r.x, y: r.y, z: 0 },
                    aspect: wgpu::TextureAspect::All,
                },
                &pixels[(r.y * size + r.x) as usize..],
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(size), rows_per_image: Some(r.h) },
                wgpu::Extent3d { width: r.w, height: r.h, depth_or_array_layers: 1 },
            );
        });
    }

    /// Draws `list` onto `target` (cleared to `clear`) and submits it without waiting. `view_scale`: target pixels per list
    /// pixel (0 or 1 = unchanged; below 1 the shader supersamples a reduced view).
    pub fn draw(
        &mut self,
        list: &DrawList,
        target: &GpuTexture,
        clear: Color,
        atlas: Option<&GlyphAtlas>,
        view_scale: f32,
    ) -> Result<(), GpuError> {
        self.draw_with(list, target, clear, atlas, view_scale, VideoOverride::Keep)
    }

    /// [`Self::draw`] with the video quad forced to black or white (`Keep` is `draw`).
    pub fn draw_with(
        &mut self,
        list: &DrawList,
        target: &GpuTexture,
        clear: Color,
        atlas: Option<&GlyphAtlas>,
        view_scale: f32,
        video: VideoOverride,
    ) -> Result<(), GpuError> {
        self.draw_with_image(list, target, clear, atlas, view_scale, video, None)
    }

    /// [`Self::draw_with`] that also forces image slot `.0` to black or white (`Keep` leaves it): the Source monitor's picture
    /// in the extended-range window path.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_with_image(
        &mut self,
        list: &DrawList,
        target: &GpuTexture,
        clear: Color,
        atlas: Option<&GlyphAtlas>,
        view_scale: f32,
        video: VideoOverride,
        image: Option<(usize, VideoOverride)>,
    ) -> Result<(), GpuError> {
        let wants = |v: VideoOverride| video == v || image.is_some_and(|(_, o)| o == v);
        if wants(VideoOverride::White) && self.white.is_none() {
            let t = self.gpu.texture(1, 1, PixelFormat::Rgba8Unorm);
            self.gpu.upload_texture(&t, &[255, 255, 255, 255], 4);
            self.white = Some(t);
        }
        if wants(VideoOverride::Black) && self.black.is_none() {
            let t = self.gpu.texture(1, 1, PixelFormat::Rgba8Unorm);
            self.gpu.upload_texture(&t, &[0, 0, 0, 255], 4);
            self.black = Some(t);
        }
        let shown = match video {
            VideoOverride::Keep => self.video.clone(),
            VideoOverride::Black => None,
            VideoOverride::White => self.white.clone(),
        };
        if let Some(a) = atlas {
            self.sync_atlas(a);
        }
        self.bytes.clear();
        for q in list.quads() {
            q.write_bytes(&mut self.bytes);
        }
        let need = (self.bytes.len().max(DrawQuad::SIZE)) as u64;
        if self.quads.as_ref().is_none_or(|(_, cap)| *cap < need) {
            let cap = need.next_power_of_two().max(16 * DrawQuad::SIZE as u64);
            self.quads = Some((self.gpu.storage_buffer(cap), cap));
        }
        let Some((buffer, _)) = &self.quads else { return Ok(()) };
        self.gpu.queue().write_buffer(buffer, 0, &self.bytes);

        // b0: screen, fullRange (2 = the RGBA8 picture), hasVideo, viewExponent, viewScale.
        let constants: Vec<u8> = [
            target.width() as f32,
            target.height() as f32,
            if shown.is_some() { 2.0 } else { 0.0 },
            if shown.is_some() { 1.0 } else { 0.0 },
            1.0,
            view_scale,
            0.0,
            0.0,
        ]
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .collect();

        let mut cmds = self.gpu.commands();
        {
            let mut pass = cmds.render(target, Some([clear.r as f64, clear.g as f64, clear.b as f64, 1.0]));
            pass.set_pipeline(&self.pipeline);
            pass.set_constants(&constants, 0)?;
            if let (Some(_), Some(tex)) = (atlas, &self.atlas) {
                pass.set_input(tex, 0)?;
            }
            if let Some(v) = &shown {
                pass.set_input(v, VIDEO_SLOT)?;
            }
            for (i, img) in self.images.iter().enumerate() {
                let forced = match image {
                    Some((slot, VideoOverride::Black)) if slot == i => self.black.as_ref(),
                    Some((slot, VideoOverride::White)) if slot == i => self.white.as_ref(),
                    _ => None,
                };
                if let Some(t) = forced.or(img.as_ref()) {
                    pass.set_input(t, IMAGE_SLOT0 + i)?;
                }
            }
            pass.set_buffer(buffer, 2)?;
            if !list.quads().is_empty() {
                pass.draw(6, list.quads().len() as u32)?;
            }
        }
        self.gpu.submit(cmds);
        Ok(())
    }

    /// Draws `list` into a fresh `Rgba8Unorm` texture and reads it back as an opaque image (the oracle path of the tests and
    /// the headless screenshots). The renderer must have been made for `Rgba8Unorm`.
    pub fn render_to_image(
        &mut self,
        list: &DrawList,
        width: u32,
        height: u32,
        clear: Color,
        atlas: Option<&GlyphAtlas>,
    ) -> Result<RgbaImage, GpuError> {
        let target = self.gpu.texture(width, height, PixelFormat::Rgba8Unorm);
        self.draw(list, &target, clear, atlas, 1.0)?;
        let mut cmds = self.gpu.commands();
        let ticket = cmds.read_texture(&target)?;
        self.gpu.submit_and_wait(cmds)?;
        let mut pixels = ticket.wait(&self.gpu)?;
        for px in pixels.as_chunks_mut::<4>().0 {
            px[3] = 255;
        }
        Ok(RgbaImage { width: width as usize, height: height as usize, pixels })
    }
}
