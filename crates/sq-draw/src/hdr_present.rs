//! The extended-range window path (HDR-PLAN.md, display path). The window surface is `Rgba16Float` with
//! `SurfaceColorSpace::ExtendedSrgbLinear` (scRGB: Rec.709 primaries, 1.0 = 80 nit), so a value `v` of the working space
//! (1.0 = reference white = 203 nit) is written as `v * 203 / 80`.
//!
//! The UI is still drawn by [`crate::wgpu_renderer::WgpuRenderer`] in sRGB code values, twice into 8-bit targets: once with
//! a black picture and once with a white one. A third pass (this module) writes the surface: UI decoded to linear and scaled,
//! plus the HDR picture where the video quad shows through (`white - black` is how much of the picture is visible
//! there: 1 on the bare picture, 0 under an opaque overlay, so overlays drawn above it keep their blend). UI white lands on 203 nit exactly like the SDR path's white.
//! The shader is WGSL (no Slang build needed); [`reference_pixel`] is its CPU twin.

use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

/// Working space to scRGB: reference white (203 nit) over the scRGB unit (80 nit).
pub const SCRGB_SCALE: f32 = 203.0 / 80.0;
/// Peak of the roll-off view in reference whites (1000 nit / 100 nit, Swift `DisplayView.hdrPeak`).
pub const ROLL_OFF_PEAK: f32 = 10.0;
/// Where the roll-off starts (`ToneMapping::default().knee()`).
pub const ROLL_OFF_KNEE: f32 = 0.8;

/// Rec.709 primaries to Display P3 (D65), rows; `sequence-studio` tests it against `Gamut::rec709().matrix(display_p3())`.
pub const REC709_TO_P3: [[f32; 3]; 3] =
    [[0.822_462, 0.177_538, 0.0], [0.033_194, 0.966_806, 0.0], [0.017_083, 0.072_397, 0.910_520]];

/// What the pass writes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoding {
    /// scRGB (`Rgba16Float`, 1.0 = 80 nit): the picture keeps its highlights ("Not Tone-Mapped").
    Scrgb,
    /// scRGB with the hue-preserving roll-off toward 10x white ("HDR 1000 nit").
    ScrgbRollOff,
    /// Display P3 code values on the 8-bit surface (sRGB transfer, clipped at white): the Display P3 view. The UI is
    /// converted to P3 primaries, so it looks the same under the P3 tag.
    DisplayP3,
}

/// The video quad of a draw list: where the picture shows and which part of it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VideoQuad {
    /// (x, y, w, h) in surface pixels.
    pub rect: [f32; 4],
    /// Normalized source rect (u0, v0, u1, v1).
    pub uv: [f32; 4],
}

impl VideoQuad {
    /// The first video quad of `list`.
    pub fn of(list: &crate::draw_list::DrawList) -> Option<VideoQuad> {
        let q = list.quads().iter().find(|q| q.kind == crate::draw_list::QuadKind::Video)?;
        Some(VideoQuad { rect: [q.rect.x, q.rect.y, q.rect.w, q.rect.h], uv: q.uv })
    }
}

impl VideoQuad {
    /// The first image quad of `list` that shows image slot `slot` (the Source monitor's picture).
    pub fn of_image(list: &crate::draw_list::DrawList, slot: usize) -> Option<VideoQuad> {
        let q = list.quads().iter().find(|q| q.kind == crate::draw_list::QuadKind::Image && q.slot == slot as f32)?;
        Some(VideoQuad { rect: [q.rect.x, q.rect.y, q.rect.w, q.rect.h], uv: q.uv })
    }
}

fn srgb_decode(c: f32) -> f32 {
    if c <= 0.040_45 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn srgb_encode(c: f32) -> f32 {
    if c <= 0.003_130_8 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

/// The Display P3 view's code values for a linear Rec.709 light (matrix, clip, sRGB transfer).
pub fn encode_display_p3(lin: [f32; 3]) -> [f32; 3] {
    let m = REC709_TO_P3;
    let row = |r: usize| (m[r][0] * lin[0] + m[r][1] * lin[1] + m[r][2] * lin[2]).clamp(0.0, 1.0);
    [srgb_encode(row(0)), srgb_encode(row(1)), srgb_encode(row(2))]
}

/// Working-linear picture value as shown: the roll-off view maps the channel maximum toward 10x white (hue-preserving),
/// the other view passes it through. Negative light floors at 0. Not yet scaled to scRGB.
pub fn encode_picture(roll_off: bool, c: [f32; 3]) -> [f32; 3] {
    let c = c.map(|v| v.max(0.0));
    let m = c[0].max(c[1]).max(c[2]);
    if !roll_off || m <= 0.0 {
        return c;
    }
    let x = m / ROLL_OFF_PEAK;
    let mapped = if x <= ROLL_OFF_KNEE {
        x
    } else {
        let r = 1.0 - ROLL_OFF_KNEE;
        ROLL_OFF_KNEE + r * (1.0 - (-(x - ROLL_OFF_KNEE) / r).exp())
    } * ROLL_OFF_PEAK;
    c.map(|v| v * (mapped / m))
}

/// CPU twin of the shader for one pixel: `black` / `white` are the UI codes with a black / white picture (0...1),
/// `picture` the working-linear picture sample with its alpha (`None`: no HDR picture, the UI already shows the picture),
/// `pixel` the surface pixel (the checkerboard under a transparent picture is laid on 16 px cells). Returns the
/// value written to the surface.
pub fn reference_pixel(
    black: [f32; 3],
    white: [f32; 3],
    picture: Option<[f32; 4]>,
    enc: Encoding,
    pixel: (u32, u32),
) -> [f32; 3] {
    let roll_off = enc == Encoding::ScrgbRollOff;
    let mut lin = black.map(srgb_decode);
    if let Some(p) = picture {
        let cover = (((white[0] - black[0]) + (white[1] - black[1]) + (white[2] - black[2])) / 3.0).clamp(0.0, 1.0);
        let e = encode_picture(roll_off, [p[0], p[1], p[2]]);
        // Same as the Swift present shader: a transparent picture shows a gray checkerboard, added after the view encoding.
        let checker = if (pixel.0 / 16 + pixel.1 / 16).is_multiple_of(2) { 0.20 } else { 0.32 };
        let behind = (1.0 - p[3].clamp(0.0, 1.0)) * checker;
        for i in 0..3 {
            lin[i] += cover * (e[i] + behind);
        }
    }
    if enc == Encoding::DisplayP3 { encode_display_p3(lin) } else { lin.map(|v| v * SCRGB_SCALE) }
}

const SHADER: &str = r#"
struct U { rect: vec4<f32>, uv: vec4<f32>, params: vec4<f32>, rect2: vec4<f32>, uv2: vec4<f32>, params2: vec4<f32> };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var ui_black: texture_2d<f32>;
@group(0) @binding(2) var ui_white: texture_2d<f32>;
@group(0) @binding(3) var pic: texture_2d<f32>;
@group(0) @binding(4) var smp: sampler;
@group(0) @binding(5) var pic2: texture_2d<f32>;

@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
}

fn srgb_decode(c: vec3<f32>) -> vec3<f32> {
    return select(pow((c + 0.055) / 1.055, vec3<f32>(2.4)), c / 12.92, c <= vec3<f32>(0.04045));
}

// params2: x = has second picture (1/0), y = Display P3 output (1/0); rect2/uv2 = its quad.
// params: x = scRGB scale, y = has picture (1/0), z = roll-off (1/0), w = peak; knee is a constant.
fn encode_picture(c0: vec3<f32>) -> vec3<f32> {
    let c = max(c0, vec3<f32>(0.0));
    let m = max(c.x, max(c.y, c.z));
    if (u.params.z < 0.5 || m <= 0.0) { return c; }
    let knee = 0.8;
    let peak = u.params.w;
    let x = m / peak;
    var mapped = x;
    if (x > knee) {
        let r = 1.0 - knee;
        mapped = knee + r * (1.0 - exp(-(x - knee) / r));
    }
    return c * (mapped * peak / m);
}

fn srgb_encode(c: vec3<f32>) -> vec3<f32> {
    return select(1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - 0.055, c * 12.92, c <= vec3<f32>(0.0031308));
}

@fragment fn fs(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let px = vec2<i32>(pos.xy);
    let a = textureLoad(ui_black, px, 0);
    var lin = srgb_decode(a.rgb);
    let in2 = u.params2.x > 0.5 && pos.x >= u.rect2.x && pos.x < u.rect2.x + u.rect2.z
        && pos.y >= u.rect2.y && pos.y < u.rect2.y + u.rect2.w;
    if (u.params.y > 0.5 || in2) {
        let b = textureLoad(ui_white, px, 0);
        let cover = clamp(dot(b.rgb - a.rgb, vec3<f32>(1.0 / 3.0)), 0.0, 1.0);
        if (cover > 0.0) {
            let uv1 = u.uv.xy + (u.uv.zw - u.uv.xy) * (pos.xy - u.rect.xy) / u.rect.zw;
            let uv2 = u.uv2.xy + (u.uv2.zw - u.uv2.xy) * (pos.xy - u.rect2.xy) / u.rect2.zw;
            let c = select(textureSampleLevel(pic, smp, uv1, 0.0), textureSampleLevel(pic2, smp, uv2, 0.0), in2);
            let cell = vec2<u32>(pos.xy) / 16u;
            let checker = select(0.32, 0.20, ((cell.x + cell.y) & 1u) == 0u);
            lin = lin + cover * (encode_picture(c.rgb) + (1.0 - clamp(c.a, 0.0, 1.0)) * checker);
        }
    }
    if (u.params2.y > 0.5) {
        let p = vec3<f32>(
            dot(vec3<f32>(0.822462, 0.177538, 0.0), lin),
            dot(vec3<f32>(0.033194, 0.966806, 0.0), lin),
            dot(vec3<f32>(0.017083, 0.072397, 0.910520), lin));
        return vec4<f32>(srgb_encode(clamp(p, vec3<f32>(0.0), vec3<f32>(1.0))), 1.0);
    }
    return vec4<f32>(lin * u.params.x, 1.0);
}
"#;

/// The pass that writes the float surface.
pub struct HdrPresent {
    gpu: Arc<Gpu>,
    /// One pipeline per target format: `Rgba16Float` (scRGB) and `Bgra8Unorm` (Display P3).
    pipelines: [wgpu::RenderPipeline; 2],
    sampler: wgpu::Sampler,
    uniforms: wgpu::Buffer,
}

impl HdrPresent {
    pub fn new(gpu: Arc<Gpu>) -> HdrPresent {
        let device = gpu.device();
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("HdrPresent"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let make = |format: PixelFormat| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("HdrPresent"),
                layout: None,
                vertex: wgpu::VertexState {
                    module: &module,
                    entry_point: Some("vs"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: Default::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &module,
                    entry_point: Some("fs"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: format.wgpu(),
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let pipelines = [make(PixelFormat::Rgba16Float), make(PixelFormat::Bgra8Unorm)];
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });
        let uniforms = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("HdrPresent uniforms"),
            size: 96,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        HdrPresent { gpu, pipelines, sampler, uniforms }
    }

    /// Writes `target` (`Rgba16Float` for the scRGB encodings, `Bgra8Unorm` for `DisplayP3`; the surface texture or a test
    /// texture). `pictures`: up to two HDR pictures (`Rgba16Float` linear working light, Program and Source monitor) with the
    /// quad each fills; empty = the UI textures already hold everything.
    pub fn draw(
        &self,
        ui_black: &GpuTexture,
        ui_white: &GpuTexture,
        pictures: &[(&GpuTexture, VideoQuad)],
        enc: Encoding,
        target: &wgpu::Texture,
    ) {
        let none = VideoQuad { rect: [0.0, 0.0, 1.0, 1.0], uv: [0.0, 0.0, 1.0, 1.0] };
        let (pic1, quad1, has1) = pictures.first().map_or((ui_black, none, 0.0), |(t, q)| (*t, *q, 1.0));
        let (pic2, quad2, has2) = pictures.get(1).map_or((ui_black, none, 0.0), |(t, q)| (*t, *q, 1.0));
        let q = |q: VideoQuad| [q.rect[0], q.rect[1], q.rect[2].max(1e-3), q.rect[3].max(1e-3)];
        let p3 = if enc == Encoding::DisplayP3 { 1.0 } else { 0.0 };
        let floats: Vec<f32> = [
            q(quad1).as_slice(),
            &quad1.uv,
            &[SCRGB_SCALE, has1, if enc == Encoding::ScrgbRollOff { 1.0 } else { 0.0 }, ROLL_OFF_PEAK],
            q(quad2).as_slice(),
            &quad2.uv,
            &[has2, p3, 0.0, 0.0],
        ]
        .concat();
        let bytes: Vec<u8> = floats.iter().flat_map(|f| f.to_le_bytes()).collect();
        self.gpu.queue().write_buffer(&self.uniforms, 0, &bytes);
        let pipeline = &self.pipelines[usize::from(enc == Encoding::DisplayP3)];
        let device = self.gpu.device();
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &pipeline.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: self.uniforms.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(ui_black.view()) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(ui_white.view()) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(pic1.view()) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(pic2.view()) },
            ],
        });
        let view = target.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.draw(0..3, 0..1);
        }
        self.gpu.queue().submit([encoder.finish()]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: [f32; 3], b: [f32; 3], tol: f32) -> bool {
        a.iter().zip(b).all(|(x, y)| (x - y).abs() <= tol)
    }

    #[test]
    fn ui_white_lands_on_reference_white() {
        // Golden: sRGB code 1.0 -> linear 1.0 -> 203/80 = 2.5375.
        let px = reference_pixel([1.0; 3], [1.0; 3], None, Encoding::Scrgb, (0, 0));
        assert!(close(px, [2.5375; 3], 1e-5), "{px:?}");
        assert_eq!(reference_pixel([0.0; 3], [0.0; 3], None, Encoding::Scrgb, (0, 0)), [0.0; 3]);
        // Mid gray code 0.5 decodes to 0.21404...
        let g = reference_pixel([0.5; 3], [0.5; 3], None, Encoding::Scrgb, (0, 0));
        assert!(close(g, [0.214_04 * SCRGB_SCALE; 3], 1e-4), "{g:?}");
    }

    #[test]
    fn the_picture_keeps_highlights_above_one() {
        // Opaque picture area: black UI = 0, white UI = 1 (cover 1). 4x white stays 4x: 4 * 2.5375.
        let px = reference_pixel([0.0; 3], [1.0; 3], Some([4.0, 4.0, 4.0, 1.0]), Encoding::Scrgb, (0, 0));
        assert!(close(px, [10.15; 3], 1e-4), "{px:?}");
        // Fully covered by an overlay (white == black): no picture.
        let covered = reference_pixel([0.5; 3], [0.5; 3], Some([4.0, 4.0, 4.0, 1.0]), Encoding::Scrgb, (0, 0));
        assert!(close(covered, reference_pixel([0.5; 3], [0.5; 3], None, Encoding::Scrgb, (0, 0)), 1e-6));
        // Negative light floors at 0.
        assert_eq!(
            reference_pixel([0.0; 3], [1.0; 3], Some([-1.0, -1.0, -1.0, 1.0]), Encoding::Scrgb, (0, 0)),
            [0.0; 3]
        );
    }

    #[test]
    fn a_transparent_picture_shows_the_checkerboard_like_the_swift_present_shader() {
        // Alpha 0.25 over black UI, white UI: rgb 1 + 0.75 * 0.20 (cell 0,0), 0.75 * 0.32 on the next cell; all times 203/80.
        let a = reference_pixel([0.0; 3], [1.0; 3], Some([1.0, 1.0, 1.0, 0.25]), Encoding::Scrgb, (3, 5));
        assert!(close(a, [1.15 * SCRGB_SCALE; 3], 1e-5), "{a:?}");
        let b = reference_pixel([0.0; 3], [1.0; 3], Some([1.0, 1.0, 1.0, 0.25]), Encoding::Scrgb, (16, 0));
        assert!(close(b, [1.24 * SCRGB_SCALE; 3], 1e-5), "{b:?}");
        // The cell parity wraps: (16, 16) is dark again.
        assert!(close(
            reference_pixel([0.0; 3], [1.0; 3], Some([0.0; 4]), Encoding::Scrgb, (16, 16)),
            [0.20 * SCRGB_SCALE; 3],
            1e-5
        ));
    }

    #[test]
    fn the_roll_off_is_hue_preserving_and_stays_below_the_peak() {
        let e = encode_picture(true, [8.0, 4.0, 2.0]);
        assert!(e[0] > e[1] && e[1] > e[2] && e[0] <= ROLL_OFF_PEAK, "{e:?}");
        assert!((e[0] / e[1] - 2.0).abs() < 1e-5, "ratio kept");
        // Below the knee (0.8 * 10 = 8 whites) values pass unchanged.
        assert!(close(encode_picture(true, [0.5, 0.25, 0.1]), [0.5, 0.25, 0.1], 1e-6));
        // Golden: max 20 -> x = 2.0, r = 0.2: 0.8 + 0.2 * (1 - exp(-6)) = 0.999504 -> 9.99504.
        assert!((encode_picture(true, [20.0, 0.0, 0.0])[0] - 9.995_04).abs() < 1e-3);
    }

    /// The shader against its CPU twin on a real device (skipped without an adapter).
    #[test]
    fn the_shader_matches_the_cpu_twin() {
        let Ok(gpu) = Gpu::new() else {
            sq_os::errln!("skipped: no GPU adapter");
            return;
        };
        let (w, h) = (4u32, 1u32);
        // Pixels: plain UI white, plain dark UI, picture area, half-covered picture area.
        let black: [[u8; 4]; 4] = [[255, 255, 255, 255], [20, 40, 60, 255], [0, 0, 0, 255], [64, 64, 64, 255]];
        let white: [[u8; 4]; 4] = [[255, 255, 255, 255], [20, 40, 60, 255], [255, 255, 255, 255], [159, 159, 159, 255]];
        let upload = |px: &[[u8; 4]; 4]| {
            let t = gpu.texture(w, h, PixelFormat::Rgba8Unorm);
            gpu.upload_texture(&t, px.as_flattened(), w * 4);
            t
        };
        let (tb, tw) = (upload(&black), upload(&white));
        // A 1x1 picture of (3, 1.5, 0.5) at alpha 0.5 in half floats.
        let half = |v: f32| half_bits(v).to_le_bytes();
        let pic = gpu.texture(1, 1, PixelFormat::Rgba16Float);
        let bytes: Vec<u8> = [3.0f32, 1.5, 0.5, 0.5].iter().flat_map(|v| half(*v)).collect();
        gpu.upload_texture(&pic, &bytes, 8);
        let target = gpu.texture(w, h, PixelFormat::Rgba16Float);
        let pass = HdrPresent::new(Arc::clone(&gpu));
        let quad = VideoQuad { rect: [0.0, 0.0, 4.0, 1.0], uv: [0.0, 0.0, 1.0, 1.0] };
        for roll in [false, true] {
            let enc = if roll { Encoding::ScrgbRollOff } else { Encoding::Scrgb };
            pass.draw(&tb, &tw, &[(&pic, quad)], enc, target.texture());
            let got = gpu.read_texture(&target).expect("read");
            for i in 0..4 {
                let f = |c: u8| f32::from(c) / 255.0;
                let want = reference_pixel(
                    [f(black[i][0]), f(black[i][1]), f(black[i][2])],
                    [f(white[i][0]), f(white[i][1]), f(white[i][2])],
                    Some([3.0, 1.5, 0.5, 0.5]),
                    enc,
                    (i as u32, 0),
                );
                for c in 0..3 {
                    let bits = u16::from_le_bytes([got[i * 8 + c * 2], got[i * 8 + c * 2 + 1]]);
                    let v = half_value(bits);
                    assert!(
                        (v - want[c]).abs() <= 0.01 * want[c].max(1.0),
                        "roll {roll} pixel {i} ch {c}: {v} vs {}",
                        want[c]
                    );
                }
            }
        }
    }

    #[test]
    fn display_p3_writes_p3_codes_with_the_srgb_transfer() {
        // Neutral gray stays neutral (the matrix rows sum to 1): linear 0.5 -> sRGB code 0.7354.
        let g = reference_pixel([0.0; 3], [1.0; 3], Some([0.5, 0.5, 0.5, 1.0]), Encoding::DisplayP3, (0, 0));
        assert!(close(g, [0.735_36; 3], 1e-3), "{g:?}");
        // Rec.709 green is inside P3: red and blue drop, nothing clips.
        let green = encode_display_p3([0.0, 1.0, 0.0]);
        assert!(green[0] > 0.0 && green[0] < 1.0 && green[1] > 0.98 && green[2] > 0.0, "{green:?}");
        // Highlights clip at white; the UI white stays white.
        assert!(close(encode_display_p3([4.0, 4.0, 4.0]), [1.0; 3], 1e-6));
        assert!(close(reference_pixel([1.0; 3], [1.0; 3], None, Encoding::DisplayP3, (0, 0)), [1.0; 3], 1e-4));
    }

    /// Two pictures (Program and Source monitor) and a 1000-nit patch on the real device, both targets.
    #[test]
    fn two_pictures_and_the_p3_target_match_the_cpu_twin() {
        let Ok(gpu) = Gpu::new() else {
            sq_os::errln!("skipped: no GPU adapter");
            return;
        };
        let (w, h) = (4u32, 1u32);
        // Pixels 0-1 show picture 1, pixels 2-3 picture 2; pixel 1 and 3 are half covered by an overlay.
        let black: [[u8; 4]; 4] = [[0, 0, 0, 255], [64, 64, 64, 255], [0, 0, 0, 255], [64, 64, 64, 255]];
        let white: [[u8; 4]; 4] = [[255; 4], [159, 159, 159, 255], [255; 4], [159, 159, 159, 255]];
        let upload = |px: &[[u8; 4]; 4]| {
            let t = gpu.texture(w, h, PixelFormat::Rgba8Unorm);
            gpu.upload_texture(&t, px.as_flattened(), w * 4);
            t
        };
        let (tb, tw) = (upload(&black), upload(&white));
        let half = |v: f32| half_bits(v).to_le_bytes();
        let make = |v: [f32; 4]| {
            let t = gpu.texture(1, 1, PixelFormat::Rgba16Float);
            let bytes: Vec<u8> = v.iter().flat_map(|c| half(*c)).collect();
            gpu.upload_texture(&t, &bytes, 8);
            t
        };
        // Picture 1: a 1000-nit patch (1000 / 203 = 4.926 whites). Picture 2: a dim blue-green.
        let (p1, p2) = ([4.926, 4.926, 4.926, 1.0], [0.25, 0.5, 1.0, 1.0]);
        let (pic1, pic2) = (make(p1), make(p2));
        let (q1, q2) = (
            VideoQuad { rect: [0.0, 0.0, 2.0, 1.0], uv: [0.0, 0.0, 1.0, 1.0] },
            VideoQuad { rect: [2.0, 0.0, 2.0, 1.0], uv: [0.0, 0.0, 1.0, 1.0] },
        );
        let pass = HdrPresent::new(Arc::clone(&gpu));
        let f = |c: u8| f32::from(c) / 255.0;
        let want = |i: usize, enc: Encoding| {
            let pic = if i < 2 { p1 } else { p2 };
            reference_pixel(
                [f(black[i][0]), f(black[i][1]), f(black[i][2])],
                [f(white[i][0]), f(white[i][1]), f(white[i][2])],
                Some(pic),
                enc,
                (i as u32, 0),
            )
        };
        // scRGB target: 1000 nit = 12.5 in scRGB (1.0 = 80 nit) on the bare patch.
        let target = gpu.texture(w, h, PixelFormat::Rgba16Float);
        pass.draw(&tb, &tw, &[(&pic1, q1), (&pic2, q2)], Encoding::Scrgb, target.texture());
        let got = gpu.read_texture(&target).expect("read");
        let value = |i: usize, c: usize| half_value(u16::from_le_bytes([got[i * 8 + c * 2], got[i * 8 + c * 2 + 1]]));
        assert!((value(0, 0) - 12.5).abs() < 0.05, "1000 nit patch writes {}", value(0, 0));
        sq_os::errln!("1000-nit patch written as scRGB {} (12.5 = 1000 nit)", value(0, 0));
        for i in 0..4 {
            let w_ = want(i, Encoding::Scrgb);
            for (c, w) in w_.iter().enumerate() {
                assert!((value(i, c) - w).abs() <= 0.01 * w.max(1.0), "scRGB pixel {i} ch {c}: {} vs {w}", value(i, c));
            }
        }
        // Display P3 target (8-bit): codes within one step of the twin.
        let p3 = gpu.texture(w, h, PixelFormat::Bgra8Unorm);
        pass.draw(&tb, &tw, &[(&pic1, q1), (&pic2, q2)], Encoding::DisplayP3, p3.texture());
        let got = gpu.read_texture(&p3).expect("read");
        for i in 0..4 {
            let w_ = want(i, Encoding::DisplayP3);
            // Bgra order in memory.
            let px = [got[i * 4 + 2], got[i * 4 + 1], got[i * 4]];
            for (c, (p, w)) in px.iter().zip(w_).enumerate() {
                assert!((f32::from(*p) / 255.0 - w).abs() <= 1.5 / 255.0, "P3 pixel {i} ch {c}: {p} vs {w}");
            }
        }
    }

    fn half_bits(v: f32) -> u16 {
        // Only exact binary fractions are used in the test (3, 1.5, 0.5, 1).
        let bits = v.to_bits();
        let sign = ((bits >> 16) & 0x8000) as u16;
        let exp = ((bits >> 23) & 0xff) as i32 - 127 + 15;
        let mant = ((bits >> 13) & 0x3ff) as u16;
        sign | ((exp as u16) << 10) | mant
    }

    fn half_value(bits: u16) -> f32 {
        let (s, e, m) = (f32::from(bits >> 15), i32::from((bits >> 10) & 0x1f), f32::from(bits & 0x3ff));
        let mag = if e == 0 { m / 1024.0 * 2f32.powi(-14) } else { (1.0 + m / 1024.0) * 2f32.powi(e - 15) };
        if s > 0.5 { -mag } else { mag }
    }
}
