//! Helpers of the GPU tests: the shared device (tests skip with a note when there is no adapter), image upload and readback,
//! and the comparison against the CPU references.

use super::effect_chain_plan::lin;
use super::scratch::{Block, half, unhalf};
use crate::effects::image_filters::{Frame, Image};
use crate::effects::simd::{Float2, Float4};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use std::sync::{Arc, OnceLock};

pub type R = Result<(), Box<dyn std::error::Error>>;

/// The shared device; `None` (with a note) when the machine has no adapter.
pub fn gpu() -> Option<Arc<Gpu>> {
    static GPU: OnceLock<Option<Arc<Gpu>>> = OnceLock::new();
    GPU.get_or_init(|| match Gpu::new() {
        Ok(g) => {
            eprintln!("adapter: {} ({:?})", g.info().name, g.info().backend);
            Some(g)
        }
        Err(e) => {
            eprintln!("skipping GPU tests: {e}");
            None
        }
    })
    .clone()
}

/// An opaque working-linear image from 8-bit BT.709-encoded `(r, g, b)` values.
pub fn video_image(w: usize, h: usize, f: impl Fn(usize, usize) -> (u8, u8, u8)) -> Image {
    Image::from_fn(w, h, |x, y| {
        let (r, g, b) = f(x, y);
        Float4::new(lin(f32::from(r) / 255.0), lin(f32::from(g) / 255.0), lin(f32::from(b) / 255.0), 1.0)
    })
}

/// The frame that fills the whole image.
pub fn whole(img: &Image) -> Frame {
    let size = Float2::new(img.width as f32, img.height as f32);
    Frame { center: size / 2.0, size }
}

/// `img` as an `Rgba16Float` texture.
pub fn upload(gpu: &Gpu, img: &Image) -> GpuTexture {
    let t = gpu.texture(img.width as u32, img.height as u32, PixelFormat::Rgba16Float);
    let bytes: Vec<u8> = img.px.iter().flat_map(|p| [p.x, p.y, p.z, p.w]).flat_map(|v| half(v).to_le_bytes()).collect();
    gpu.upload_texture(&t, &bytes, img.width as u32 * 8);
    t
}

/// The pixels of an `Rgba16Float` texture.
pub fn download(gpu: &Arc<Gpu>, t: &GpuTexture) -> Result<Image, GpuError> {
    let bytes = gpu.read_texture(t)?;
    let v: Vec<f32> = bytes.as_chunks::<2>().0.iter().map(|c| unhalf(u16::from_le_bytes(*c))).collect();
    Ok(Image::from_fn(t.width() as usize, t.height() as usize, |x, y| {
        let i = (y * t.width() as usize + x) * 4;
        Float4::new(v[i], v[i + 1], v[i + 2], v[i + 3])
    }))
}

/// Largest color difference (r, g, b) between two images and where it is.
pub fn worst(got: &Image, want: &Image) -> (f32, usize) {
    let mut best = (0.0f32, 0);
    for (i, (g, w)) in got.px.iter().zip(&want.px).enumerate() {
        for d in [(g.x - w.x).abs(), (g.y - w.y).abs(), (g.z - w.z).abs()] {
            if d > best.0 || d.is_nan() {
                best = (d, i);
            }
        }
    }
    best
}

/// The `CompositeU` block (368 bytes) of a plain RGB-texture draw of a `w` x `h` frame: mode 1, source-encoded (linearize),
/// straight alpha, `mask_count` masks.
pub fn composite_block(w: u32, h: u32, mask_count: u32) -> Block {
    let zeros = |n: usize| vec![0.0f32; n];
    Block::new()
        .f32s(&zeros(20)) // m0, m1, m2, solid, range
        .f32s(&[w as f32, h as f32, w as f32, h as f32, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0]) // canvas, size, position, anchor, scale
        .f32s(&[1.0, 0.0, 1.0]) // rotCos, rotSin, opacity
        .u32s(&[1, 1]) // mode: RGB texture, linearize
        .f32s(&[0.0]) // cornerRadius
        .u32s(&[0, 0]) // quarter, blend
        .f32s(&zeros(2 + 4 + 32)) // maskSize, crop, keys
        .u32s(&[0, 0, 1, mask_count]) // keyCount, roundFirst, alphaMode (straight), maskCount
        .f32s(&zeros(1 + 3 + 4 + 4)) // cropFeather + pad, part, tilt
}
