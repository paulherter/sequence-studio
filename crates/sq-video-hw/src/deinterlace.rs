//! The GPU pass that deinterlaces a VideoToolbox frame (Swift `MetalDeinterlacer`, Deinterlacer.swift:231): the same
//! arithmetic as `sq_media::deinterlacer::deinterlace_plane`, once per plane, on the plane textures the importer made. The
//! Metal source is Swift's kernel unchanged; it runs as a passthrough module on the app's wgpu device, so a frame never
//! leaves the GPU. Apple-only like the decoder around it (the Windows and Linux decoders read through FFmpeg, whose CPU
//! pass is the same definition).

use sq_core_model::FieldOrder;
use sq_gpu::frames::{GpuFrame, GpuTexture, PlaneLayout};
use sq_gpu::gpu::Gpu;
use std::borrow::Cow;
use std::sync::Arc;

/// Comb thresholds and the direction bias, the constants of `sq_media::deinterlacer` as the kernel takes them.
const LOW: f32 = 5.0 / 255.0;
const HIGH: f32 = 13.0 / 255.0;
const DIRECTION_BIAS: f32 = 1.5 / 1024.0;
const GROUP: u32 = 8;
const ENTRY: &str = "sq_deinterlace";

/// `Params` of the kernel (16 bytes).
fn params(order: FieldOrder) -> [u8; 16] {
    let keep: i32 = if order == FieldOrder::TopFirst { 0 } else { 1 };
    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&keep.to_le_bytes());
    out[4..8].copy_from_slice(&LOW.to_le_bytes());
    out[8..12].copy_from_slice(&HIGH.to_le_bytes());
    out[12..16].copy_from_slice(&DIRECTION_BIAS.to_le_bytes());
    out
}

fn plane_formats(layout: PlaneLayout) -> Option<[wgpu::TextureFormat; 2]> {
    use wgpu::TextureFormat as F;
    match layout {
        PlaneLayout::Nv12 => Some([F::R8Unorm, F::Rg8Unorm]),
        PlaneLayout::P010 => Some([F::R16Unorm, F::Rg16Unorm]),
        // RGB is not deinterlaced (the definition covers Y'CbCr planes and packed four-channel Y'CbCr only).
        PlaneLayout::Rgba8Straight | PlaneLayout::Rgba16f => None,
    }
}

/// The pipeline of the kernel and the field order it keeps. Built once per decoder.
pub struct GpuDeinterlacer {
    gpu: Arc<Gpu>,
    order: FieldOrder,
    group: wgpu::BindGroupLayout,
    pipelines: Vec<(wgpu::TextureFormat, wgpu::ComputePipeline)>,
}

impl GpuDeinterlacer {
    /// `None` when the device cannot write the plane formats as storage textures (the caller uses the FFmpeg route).
    pub fn new(gpu: Arc<Gpu>, order: FieldOrder, layout: PlaneLayout) -> Option<GpuDeinterlacer> {
        let formats = plane_formats(layout)?;
        let device = gpu.device();
        let entry = |binding, ty| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty,
            count: None,
        };
        let mut pipelines = Vec::new();
        // One bind group layout per storage format (the format is part of the layout); Metal slots follow binding order:
        // texture(0) source, texture(1) destination, buffer(0) params.
        let mut group = None;
        let source = wgpu::ShaderModuleDescriptorPassthrough {
            label: Some("sq-deinterlace"),
            entry_points: Cow::Owned(vec![wgpu::PassthroughShaderEntryPoint {
                name: Cow::Borrowed(ENTRY),
                workgroup_size: (GROUP, GROUP, 1),
            }]),
            msl: Some(Cow::Borrowed(KERNEL)),
            ..Default::default()
        };
        let outer = device.push_error_scope(wgpu::ErrorFilter::Validation);
        // SAFETY: passthrough skips wgpu validation; the source is the Metal kernel below and its three bindings are the
        // three entries of the layouts built here.
        #[allow(unsafe_code)]
        let module = unsafe { device.create_shader_module_passthrough(source) };
        for format in formats {
            let layout_entries = [
                entry(
                    0,
                    wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                ),
                entry(
                    1,
                    wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format,
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                ),
                entry(
                    2,
                    wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                ),
            ];
            let bgl = device
                .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &layout_entries });
            let pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(&bgl)],
                immediate_size: 0,
            });
            let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(ENTRY),
                layout: Some(&pl),
                module: &module,
                entry_point: Some(ENTRY),
                compilation_options: Default::default(),
                cache: None,
            });
            pipelines.push((format, pipeline));
            group.get_or_insert(bgl);
        }
        if pollster::block_on(outer.pop()).is_some() {
            return None;
        }
        // The layouts differ only in the storage format; a pipeline's own layout makes its groups.
        Some(GpuDeinterlacer { gpu, order, group: group?, pipelines })
    }

    /// The progressive copy of `frame` (new plane textures, nothing kept from the source), or `None` when a plane cannot
    /// be written.
    pub fn run(&self, frame: &GpuFrame) -> Option<GpuFrame> {
        let device = self.gpu.device();
        let _ = &self.group;
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        self.gpu.queue().write_buffer(&uniform, 0, &params(self.order));
        let mut planes = Vec::new();
        let mut encoder = device.create_command_encoder(&Default::default());
        for source in &frame.planes {
            let format = source.texture().format();
            let (_, pipeline) = self.pipelines.iter().find(|(f, _)| *f == format)?;
            let size = source.texture().size();
            let out = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("deinterlaced"),
                size,
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: wgpu::TextureUsages::STORAGE_BINDING
                    | wgpu::TextureUsages::TEXTURE_BINDING
                    | wgpu::TextureUsages::COPY_SRC
                    | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            let out = GpuTexture::from_texture(out);
            let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: None,
                layout: &pipeline.get_bind_group_layout(0),
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(source.view()) },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(out.view()) },
                    wgpu::BindGroupEntry { binding: 2, resource: uniform.as_entire_binding() },
                ],
            });
            {
                let mut pass = encoder.begin_compute_pass(&Default::default());
                pass.set_pipeline(pipeline);
                pass.set_bind_group(0, &bind, &[]);
                pass.dispatch_workgroups(size.width.div_ceil(GROUP), size.height.div_ceil(GROUP), 1);
            }
            planes.push(out);
        }
        self.gpu.queue().submit([encoder.finish()]);
        // The kernel reads the decoder's IOSurface: it must be done before the picture goes back (Swift waits too).
        self.gpu.wait().ok()?;
        Some(GpuFrame {
            planes,
            layout: frame.layout,
            size: frame.size,
            color: frame.color,
            pts: frame.pts,
            keep: None,
        })
    }
}

/// Swift's `MetalDeinterlacer.source`, kernel `sq_deinterlace`.
const KERNEL: &str = r#"
#include <metal_stdlib>
using namespace metal;

struct Params { int keep; float low; float high; float bias; };

static inline float4 px(texture2d<float, access::read> t, int x, int y, int w) {
    return t.read(uint2(clamp(x, 0, w - 1), y));
}
static inline float total(float4 v) { return v.x + v.y + v.z + v.w; }

static float comb(texture2d<float, access::read> t, int x, int y, int ya, int yb, int w, int h) {
    float4 c = px(t, x, y, w), a = px(t, x, ya, w), b = px(t, x, yb, w);
    float4 cu = c, cd = c;
    if (y - 2 >= 0) { cu = px(t, x, y - 2, w); }
    if (y + 2 < h) { cd = px(t, x, y + 2, w); }
    float4 d1 = c - a, d2 = c - b;
    float4 s = sign(d1);
    float4 m = min(min(abs(d1), abs(d2)), max(max(s * (cu - a), s * (cd - b)), float4(0.0)));
    m = select(float4(0.0), m, d1 * d2 > float4(0.0));
    return max(max(m.x, m.y), max(m.z, m.w));
}

kernel void sq_deinterlace(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant Params &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int w = src.get_width(), h = src.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    int x = gid.x, y = gid.y;
    float4 c = src.read(gid);
    if ((y & 1) == p.keep || y == 0 || y == h - 1) { dst.write(c, gid); return; }
    int ya = y > 0 ? y - 1 : y + 1;
    int yb = y + 1 < h ? y + 1 : y - 1;
    float m = max(comb(src, x - 1, y, ya, yb, w, h), max(comb(src, x, y, ya, yb, w, h), comb(src, x + 1, y, ya, yb, w, h)));
    float weight = clamp((m - p.low) / (p.high - p.low), 0.0f, 1.0f);
    if (weight <= 0.0f) { dst.write(c, gid); return; }
    float4 a0 = px(src, x, ya, w), am = px(src, x - 1, ya, w), ap = px(src, x + 1, ya, w);
    float4 am2 = px(src, x - 2, ya, w), ap2 = px(src, x + 2, ya, w);
    float4 b0 = px(src, x, yb, w), bm = px(src, x - 1, yb, w), bp = px(src, x + 1, yb, w);
    float4 bm2 = px(src, x - 2, yb, w), bp2 = px(src, x + 2, yb, w);
    float best = total(abs(am - bm)) + total(abs(a0 - b0)) + total(abs(ap - bp));
    float4 r = (a0 + b0) * 0.5f;
    float d = total(abs(am2 - b0)) + total(abs(am - bp)) + total(abs(a0 - bp2));
    if (d + p.bias < best) { best = d; r = (am + bp) * 0.5f; }
    d = total(abs(a0 - bm2)) + total(abs(ap - bm)) + total(abs(ap2 - b0));
    if (d + p.bias < best) { r = (ap + bm) * 0.5f; }
    r = clamp(r, min(a0, b0), max(a0, b0));
    dst.write(c + (r - c) * weight, gid);
}
"#;

#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests {
    use super::*;
    use sq_media::deinterlacer::deinterlace_biplanar_420;

    const W: usize = 192;
    const H: usize = 96;

    /// An interlaced scene: gradient, bars, a one-line rule and a bright box that moved 12 px between the two fields.
    fn luma(x: usize, y: usize) -> u8 {
        let box_x = if y.is_multiple_of(2) { 40 } else { 52 };
        if (24..60).contains(&y) && (box_x..box_x + 40).contains(&x) {
            return 220;
        }
        if y == 80 {
            return 200;
        }
        if x >= 150 {
            return if (x / 3).is_multiple_of(2) { 60 } else { 150 };
        }
        (40 + (x + 2 * y) / 4) as u8
    }

    fn picture() -> Vec<u8> {
        let mut v = Vec::new();
        for y in 0..H {
            for x in 0..W {
                v.push(luma(x, y));
            }
        }
        // Chroma: half the rows, interleaved CbCr, also moving with the field.
        for y in 0..H / 2 {
            for x in 0..W / 2 {
                let moved = if y.is_multiple_of(2) { x } else { x + 6 };
                v.push((100 + moved % 40) as u8);
                v.push((140 - (moved / 2) % 30) as u8);
            }
        }
        v
    }

    fn texture(gpu: &Gpu, w: usize, h: usize, format: wgpu::TextureFormat, bytes: &[u8], bpr: usize) -> GpuTexture {
        let t = gpu.device().create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width: w as u32, height: h as u32, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let t = GpuTexture::from_texture(t);
        gpu.upload_texture(&t, bytes, bpr as u32);
        t
    }

    /// The GPU pass on an interlaced 4:2:0 picture equals the CPU definition within 1/255 on every sample, for both field orders.
    #[test]
    fn gpu_deinterlace_matches_the_cpu_pass_within_one_code_value() {
        let Ok(gpu) = Gpu::new() else {
            sq_os::errln!("skipped: no GPU");
            return;
        };
        let bytes = picture();
        for order in [FieldOrder::TopFirst, FieldOrder::BottomFirst] {
            let frame = GpuFrame {
                planes: vec![
                    texture(&gpu, W, H, wgpu::TextureFormat::R8Unorm, &bytes[..W * H], W),
                    texture(&gpu, W / 2, H / 2, wgpu::TextureFormat::Rg8Unorm, &bytes[W * H..], W),
                ],
                layout: PlaneLayout::Nv12,
                size: (W as u32, H as u32),
                color: sq_frame::sqframe::SQFrameColorSpace::Rec709,
                pts: sq_core_time::Time::ZERO,
                keep: None,
            };
            let Some(pass) = GpuDeinterlacer::new(Arc::clone(&gpu), order, PlaneLayout::Nv12) else {
                sq_os::errln!("skipped: the device cannot write 8-bit planes as storage");
                return;
            };
            let out = pass.run(&frame).expect("the pass runs");
            let expected = deinterlace_biplanar_420(&bytes, W, H, W, false, order).expect("cpu pass");
            let mut got = gpu.read_texture(&out.planes[0]).expect("luma");
            got.extend(gpu.read_texture(&out.planes[1]).expect("chroma"));
            assert_eq!(got.len(), expected.len());
            let worst = got.iter().zip(&expected).map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
            let changed = got.iter().zip(&bytes).filter(|(a, b)| a != b).count();
            assert!(worst <= 1, "{order:?}: largest difference {worst}");
            assert!(changed > 100, "{order:?}: the pattern combs, the pass must change it ({changed} samples)");
        }
    }
}
