//! RGB -> NV12 on the GPU for an 8-bit 4:2:0 export (H.264, HEVC Main): the frame is read back as the two planes the
//! encoder takes instead of RGBA that the CPU converts with swscale (11 ms per 4K frame on the encode thread).
//!
//! The arithmetic is the one `sq_media_ffmpeg` `sq_enc_video` asks swscale for: RGB is full-range Rec.709 code values, the
//! file is limited-range BT.709 (`Y = 16 + 219 Y'`, `C = 128 + 224 C'`), chroma is the mean of the 2x2 block.
//! shortcut: chroma is box-averaged at the block centre (swscale's bicubic filter sits at the left edge); upgrade when a
//! chroma-edge comparison asks for it.

use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::Gpu;
use std::cell::{Cell, RefCell};
use std::sync::Arc;

const SHADER: &str = r#"
struct P { w: u32, h: u32, pad0: u32, pad1: u32 };
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> out: array<u32>;
@group(0) @binding(2) var<uniform> p: P;

fn yuv(c: vec3<f32>) -> vec3<f32> {
    let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    let cb = (c.b - y) / 1.8556;
    let cr = (c.r - y) / 1.5748;
    return vec3<f32>(16.0 + 219.0 * y, 128.0 + 224.0 * cb, 128.0 + 224.0 * cr);
}

fn byte(v: f32) -> u32 { return u32(clamp(floor(v + 0.5), 0.0, 255.0)); }

// One thread: 4 pixels wide, 2 rows. Y bytes of both rows, and the two CbCr pairs of the block row.
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= p.w / 4u || id.y >= p.h / 2u) { return; }
    let x0 = id.x * 4u;
    let y0 = id.y * 2u;
    var cbcr = array<vec2<f32>, 2>(vec2<f32>(0.0), vec2<f32>(0.0));
    for (var r = 0u; r < 2u; r = r + 1u) {
        var packed = 0u;
        for (var k = 0u; k < 4u; k = k + 1u) {
            let c = yuv(textureLoad(src, vec2<u32>(x0 + k, y0 + r), 0).rgb);
            packed = packed | (byte(c.x) << (8u * k));
            cbcr[k / 2u] = cbcr[k / 2u] + c.yz * 0.25;
        }
        out[((y0 + r) * p.w + x0) / 4u] = packed;
    }
    let base = p.w * p.h;
    let word = byte(cbcr[0].x) | (byte(cbcr[0].y) << 8u) | (byte(cbcr[1].x) << 16u) | (byte(cbcr[1].y) << 24u);
    out[(base + id.y * p.w + x0) / 4u] = word;
}
"#;

/// The compute pipeline and a ring of output buffers (two frames are in flight, a third is being filled).
pub struct YuvConverter {
    pipeline: wgpu::ComputePipeline,
    ring: RefCell<Vec<wgpu::Buffer>>,
    next: Cell<usize>,
}

impl YuvConverter {
    /// `None` when the pipeline does not build on this device (the CPU path stays).
    pub fn new(gpu: &Arc<Gpu>) -> Option<YuvConverter> {
        let device = gpu.device();
        let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("export-yuv"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("export-yuv"),
            layout: None,
            module: &module,
            entry_point: Some("main"),
            compilation_options: Default::default(),
            cache: None,
        });
        pollster::block_on(scope.pop()).is_none().then_some(YuvConverter {
            pipeline,
            ring: RefCell::new(Vec::new()),
            next: Cell::new(0),
        })
    }

    /// Converts `texture` (RGBA8 code values) into a buffer holding the Y plane then the interleaved CbCr plane, tightly packed;
    /// returns it with its byte length. `None` for a size the kernel does not cover (width not a multiple of 4, odd height).
    pub fn convert(&self, gpu: &Arc<Gpu>, texture: &GpuTexture) -> Option<(wgpu::Buffer, u64)> {
        let (w, h) = (texture.width(), texture.height());
        if w == 0 || h == 0 || !w.is_multiple_of(4) || !h.is_multiple_of(2) {
            return None;
        }
        let len = u64::from(w) * u64::from(h) * 3 / 2;
        let slot = self.next.get() % 3;
        self.next.set(slot + 1);
        let buffer = {
            let mut ring = self.ring.borrow_mut();
            if ring.get(slot).is_none_or(|b| b.size() < len) {
                let fresh = gpu.storage_buffer(len);
                if slot < ring.len() { ring[slot] = fresh } else { ring.push(fresh) }
            }
            ring[slot].clone()
        };
        let device = gpu.device();
        let mut params = [0u8; 16];
        params[0..4].copy_from_slice(&w.to_le_bytes());
        params[4..8].copy_from_slice(&h.to_le_bytes());
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        gpu.queue().write_buffer(&uniform, 0, &params);
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.pipeline.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(texture.view()) },
                wgpu::BindGroupEntry { binding: 1, resource: buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: uniform.as_entire_binding() },
            ],
        });
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("export-yuv") });
        {
            let mut pass =
                encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: None, timestamp_writes: None });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups((w / 4).div_ceil(16), (h / 2).div_ceil(16), 1);
        }
        gpu.queue().submit([encoder.finish()]);
        Some((buffer, len))
    }
}

/// NV12 (limited-range BT.709) to RGBA8 on the CPU, for the export dialog's preview picture.
pub fn nv12_to_rgba(bytes: &[u8], w: usize, h: usize) -> sq_draw::RgbaImage {
    let mut pixels = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let yy = (f32::from(bytes[y * w + x]) - 16.0) / 219.0;
            let c = w * h + (y / 2) * w + (x / 2) * 2;
            let cb = (f32::from(bytes[c]) - 128.0) / 224.0;
            let cr = (f32::from(bytes[c + 1]) - 128.0) / 224.0;
            let r = yy + 1.5748 * cr;
            let b = yy + 1.8556 * cb;
            let g = (yy - 0.2126 * r - 0.0722 * b) / 0.7152;
            pixels.extend([r, g, b].map(|v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8));
            pixels.push(255);
        }
    }
    sq_draw::RgbaImage { width: w, height: h, pixels }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_gpu::layout::PixelFormat;

    /// The CPU definition: full-range RGB to limited BT.709, chroma of the 2x2 mean.
    fn reference(rgba: &[u8], w: usize, h: usize) -> Vec<u8> {
        let conv = |p: &[u8]| {
            let (r, g, b) = (f64::from(p[0]) / 255.0, f64::from(p[1]) / 255.0, f64::from(p[2]) / 255.0);
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            [16.0 + 219.0 * y, 128.0 + 224.0 * (b - y) / 1.8556, 128.0 + 224.0 * (r - y) / 1.5748]
        };
        let byte = |v: f64| v.round().clamp(0.0, 255.0) as u8;
        let mut out = vec![0u8; w * h * 3 / 2];
        for y in 0..h {
            for x in 0..w {
                out[y * w + x] = byte(conv(&rgba[(y * w + x) * 4..])[0]);
            }
        }
        for cy in 0..h / 2 {
            for cx in 0..w / 2 {
                let mut sum = [0.0; 2];
                for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let c = conv(&rgba[((cy * 2 + dy) * w + cx * 2 + dx) * 4..]);
                    sum[0] += c[1] / 4.0;
                    sum[1] += c[2] / 4.0;
                }
                out[w * h + cy * w + cx * 2] = byte(sum[0]);
                out[w * h + cy * w + cx * 2 + 1] = byte(sum[1]);
            }
        }
        out
    }

    fn run(rgba: &[u8], w: usize, h: usize) -> Option<Vec<u8>> {
        let gpu = Gpu::new().ok()?;
        let converter = YuvConverter::new(&gpu)?;
        let texture = gpu.texture(w as u32, h as u32, PixelFormat::Rgba8Unorm);
        gpu.upload_texture(&texture, rgba, (w * 4) as u32);
        let (buffer, len) = converter.convert(&gpu, &texture)?;
        gpu.read_buffer(&buffer, len).ok()
    }

    #[test]
    fn known_colors_match_the_cpu_matrix() {
        // Flat 2x2 blocks (chroma needs no averaging across colors): black, white, the primaries, a gray, a skin tone.
        let colors: [[u8; 3]; 8] = [
            [0, 0, 0],
            [255, 255, 255],
            [255, 0, 0],
            [0, 255, 0],
            [0, 0, 255],
            [128, 128, 128],
            [224, 172, 105],
            [16, 235, 90],
        ];
        let (w, h) = (16usize, 4usize);
        let mut rgba = vec![255u8; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let c = colors[(x / 2) % 8];
                rgba[(y * w + x) * 4..(y * w + x) * 4 + 3].copy_from_slice(&c);
            }
        }
        let Some(gpu_out) = run(&rgba, w, h) else { return eprintln!("no GPU: skipped") };
        let want = reference(&rgba, w, h);
        let worst = gpu_out.iter().zip(&want).map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
        assert!(worst <= 1, "GPU and CPU NV12 differ by {worst} codes");
        // Spot values: white is Y 235, black Y 16, both neutral chroma 128.
        assert_eq!((gpu_out[2], gpu_out[0]), (235, 16));
        assert_eq!((gpu_out[w * h + 2], gpu_out[w * h + 3]), (128, 128));
    }

    #[test]
    fn noise_and_blocks_stay_within_one_code() {
        let (w, h) = (64usize, 32usize);
        let mut seed = 12345u32;
        let rgba: Vec<u8> = (0..w * h * 4)
            .map(|i| {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                if i % 4 == 3 { 255 } else { (seed >> 24) as u8 }
            })
            .collect();
        let Some(gpu_out) = run(&rgba, w, h) else { return };
        let want = reference(&rgba, w, h);
        let worst = gpu_out.iter().zip(&want).map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
        assert!(worst <= 1, "worst difference {worst}");
    }

    #[test]
    fn nv12_round_trip_is_close() {
        let (w, h) = (8usize, 4usize);
        let rgba: Vec<u8> = (0..w * h).flat_map(|_| [180u8, 100, 40, 255]).collect();
        let image = nv12_to_rgba(&reference(&rgba, w, h), w, h);
        assert_eq!(image.pixels.len(), rgba.len());
        let first = (i32::from(image.pixels[0]) - i32::from(rgba[0])).abs();
        assert!(first < 3, "round trip red off by {first}");
    }

    /// `SQ_YUV_DUMP_DIR=<dir>`: writes a 1920x1080 test picture (smooth ramps, bars, a circle) as `in.rgba` and the GPU's NV12 as
    /// `gpu.nv12`, so `ffmpeg` (swscale) can convert `in.rgba` and compare (PSNR) the conversion itself without an encoder in between.
    #[test]
    fn dump_for_the_swscale_comparison() {
        let Some(dir) = std::env::var_os("SQ_YUV_DUMP_DIR") else { return };
        let (w, h) = (1920usize, 1080usize);
        let mut rgba = vec![255u8; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let (fx, fy) = (x as f32 / w as f32, y as f32 / h as f32);
                let bars = (x / 120) % 2 == 0 && y > h / 2;
                let circle = ((x as f32 - 900.0).powi(2) + (y as f32 - 400.0).powi(2)).sqrt() < 200.0;
                let c = if bars {
                    [250, 30, 30]
                } else if circle {
                    [20, 200, 240]
                } else {
                    [(fx * 255.0) as u8, (fy * 255.0) as u8, ((fx + fy) * 127.0) as u8]
                };
                rgba[(y * w + x) * 4..(y * w + x) * 4 + 3].copy_from_slice(&c);
            }
        }
        let out = run(&rgba, w, h).expect("GPU conversion");
        let dir = std::path::PathBuf::from(dir);
        std::fs::write(dir.join("in.rgba"), &rgba).unwrap();
        std::fs::write(dir.join("gpu.nv12"), out).unwrap();
    }
}
