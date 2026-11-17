//! The fixed binding layout every kernel and draw shares (mirrors `shaders-src/Bindings.slang`).
//!
//! One 35-entry bind group: constant blocks 0..1, read textures `in0..in23` at 2..25, the 3D table `lut0` at 26, `out0` at
//! 27, a filler storage texture at 28 (so `u2` stays `u2` on D3D12), raw data buffers `u2..u4` at 29..31, samplers 32..34.
//! Unused slots get 1x1 dummies. wgpu hands out backend slots densely in binding order, which is why the numbers matter:
//! Metal buffers 0..1 then 2..4, textures 0..23, 24, 25 (out0), 26; D3D12 b0..b1, t0..t24, u0 (out0), u1, u2..u4.
//! `DrawQuads` has its own smaller layout ([`draw_quads_entries`]). `cargo xtask shaders` checks the shader reflection
//! against these numbers.

use wgpu::{
    BindGroupLayoutEntry as Entry, BindingType, BufferBindingType, SamplerBindingType, ShaderStages,
    StorageTextureAccess, TextureSampleType, TextureViewDimension,
};

/// Read textures `in0..in23`.
pub const INPUT_SLOTS: usize = 24;
/// Input slot of the 3D table `lut0`.
pub const TABLE_SLOT: usize = 24;
/// Constant blocks `b0..b1`.
pub const CONSTANT_SLOTS: usize = 2;
/// Data buffer slots (`u2..u4`).
pub const BUFFER_SLOTS: std::ops::RangeInclusive<usize> = 2..=4;
/// Largest constant block a pass may set (the uniform arena window; the largest shader block is 3104 B).
pub const MAX_CONSTANT_BYTES: usize = 4096;
/// Threads per group along x and y (every kernel is `numthreads(16, 16, 1)` and bound-checks its grid).
pub const GROUP_SIDE: u32 = 16;
/// Entries of the fixed bind group.
pub const ENTRY_COUNT: usize = 35;

pub(crate) const BIND_INPUT0: u32 = 2;
pub(crate) const BIND_TABLE: u32 = 26;
pub(crate) const BIND_OUTPUT: u32 = 27;
pub(crate) const BIND_FILLER: u32 = 28;
pub(crate) const BIND_BUFFER0: u32 = 29;
pub(crate) const BIND_SAMPLER0: u32 = 32;
/// DrawQuads: b0 constants, t0..t8 textures at 1..9, the quads buffer at 10, samplers at 11..13.
pub(crate) const DRAW_INPUTS: usize = 9;
pub(crate) const DRAW_BIND_INPUT0: u32 = 1;
pub(crate) const DRAW_BIND_QUADS: u32 = 10;
pub(crate) const DRAW_BIND_SAMPLER0: u32 = 11;

/// Which pass a layout serves; the kinds differ in `out0` access and shader stages.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LayoutKind {
    /// Compute, `out0` write-only.
    Compute,
    /// Compute, `out0` read-write (modules that define `SQ_OUT_READ`).
    ComputeInPlace,
    /// Vertex and fragment stages of a draw (storage seen by the fragment stage only).
    Render,
    /// The `DrawQuads` UI shader.
    DrawQuads,
}

/// Texel formats the passes use (working images are `Rgba16Float`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PixelFormat {
    Rgba16Float,
    Rgba32Float,
    Rgba8Unorm,
    /// Window targets of the UI (`DrawQuads`).
    Bgra8Unorm,
    /// One- and two-channel float planes (flow fields); shaders read them as (r, g, 0, 1).
    R32Float,
    Rg32Float,
    /// 8-bit video planes (NV12 luma and interleaved chroma), read normalized.
    R8Unorm,
    Rg8Unorm,
    /// 16-bit video planes (P010, 10 bits MSB-aligned), read normalized. Needs `TEXTURE_FORMAT_16BIT_NORM`.
    R16Unorm,
    Rg16Unorm,
}

impl PixelFormat {
    pub fn wgpu(self) -> wgpu::TextureFormat {
        use wgpu::TextureFormat as F;
        match self {
            Self::Rgba16Float => F::Rgba16Float,
            Self::Rgba32Float => F::Rgba32Float,
            Self::Rgba8Unorm => F::Rgba8Unorm,
            Self::Bgra8Unorm => F::Bgra8Unorm,
            Self::R32Float => F::R32Float,
            Self::Rg32Float => F::Rg32Float,
            Self::R8Unorm => F::R8Unorm,
            Self::Rg8Unorm => F::Rg8Unorm,
            Self::R16Unorm => F::R16Unorm,
            Self::Rg16Unorm => F::Rg16Unorm,
        }
    }

    pub fn from_wgpu(format: wgpu::TextureFormat) -> Option<Self> {
        [
            Self::Rgba16Float,
            Self::Rgba32Float,
            Self::Rgba8Unorm,
            Self::Bgra8Unorm,
            Self::R32Float,
            Self::Rg32Float,
            Self::R8Unorm,
            Self::Rg8Unorm,
            Self::R16Unorm,
            Self::Rg16Unorm,
        ]
        .into_iter()
        .find(|f| f.wgpu() == format)
    }

    pub fn bytes_per_pixel(self) -> u32 {
        match self {
            Self::Rgba32Float => 16,
            Self::Rgba16Float | Self::Rg32Float => 8,
            Self::Rgba8Unorm | Self::Bgra8Unorm | Self::R32Float | Self::Rg16Unorm => 4,
            Self::Rg8Unorm | Self::R16Unorm => 2,
            Self::R8Unorm => 1,
        }
    }

    /// Formats `out0` can have (storage textures).
    pub fn is_storage(self) -> bool {
        matches!(self, Self::Rgba16Float | Self::Rgba32Float | Self::Rgba8Unorm | Self::R32Float | Self::Rg32Float)
    }

    /// Formats a draw can target.
    pub fn is_renderable(self) -> bool {
        matches!(self, Self::Rgba16Float | Self::Rgba32Float | Self::Rgba8Unorm | Self::Bgra8Unorm)
    }
}

fn buffer(binding: u32, visibility: ShaderStages, ty: BufferBindingType, dynamic: bool) -> Entry {
    Entry {
        binding,
        visibility,
        ty: BindingType::Buffer { ty, has_dynamic_offset: dynamic, min_binding_size: None },
        count: None,
    }
}

// Not `filterable`: r32float/rg32float planes bind to the same slots, and passthrough shaders skip wgpu's sampler check.
fn texture(binding: u32, visibility: ShaderStages, dimension: TextureViewDimension) -> Entry {
    let ty = BindingType::Texture {
        sample_type: TextureSampleType::Float { filterable: false },
        view_dimension: dimension,
        multisampled: false,
    };
    Entry { binding, visibility, ty, count: None }
}

fn storage_texture(binding: u32, visibility: ShaderStages, access: StorageTextureAccess, format: PixelFormat) -> Entry {
    let ty = BindingType::StorageTexture { access, format: format.wgpu(), view_dimension: TextureViewDimension::D2 };
    Entry { binding, visibility, ty, count: None }
}

fn sampler(binding: u32, visibility: ShaderStages) -> Entry {
    Entry { binding, visibility, ty: BindingType::Sampler(SamplerBindingType::Filtering), count: None }
}

/// The 35 entries of the fixed layout; `out` is the format of `out0` (ignored for draws).
pub fn fixed_entries(kind: LayoutKind, out: PixelFormat) -> Vec<Entry> {
    let render = kind == LayoutKind::Render;
    let shared = if render { ShaderStages::VERTEX_FRAGMENT } else { ShaderStages::COMPUTE };
    // Storage is fragment-only on render layouts (vertex stages may not see writable storage); Layer fragments write the
    // mask cache at u2, and D3D12 fails with E_INVALIDARG if 27..31 are missing there (Metal accepts silently).
    let storage = if render { ShaderStages::FRAGMENT } else { ShaderStages::COMPUTE };
    let mut v = Vec::with_capacity(ENTRY_COUNT);
    for b in 0..CONSTANT_SLOTS as u32 {
        v.push(buffer(b, shared, BufferBindingType::Uniform, true));
    }
    for b in 0..INPUT_SLOTS as u32 {
        v.push(texture(BIND_INPUT0 + b, shared, TextureViewDimension::D2));
    }
    v.push(texture(BIND_TABLE, shared, TextureViewDimension::D3));
    let (access, out) = match kind {
        LayoutKind::ComputeInPlace => (StorageTextureAccess::ReadWrite, out),
        LayoutKind::Render => (StorageTextureAccess::WriteOnly, PixelFormat::Rgba16Float),
        _ => (StorageTextureAccess::WriteOnly, out),
    };
    v.push(storage_texture(BIND_OUTPUT, storage, access, out));
    v.push(storage_texture(BIND_FILLER, storage, StorageTextureAccess::WriteOnly, PixelFormat::Rgba16Float));
    for b in 0..3 {
        v.push(buffer(BIND_BUFFER0 + b, storage, BufferBindingType::Storage { read_only: false }, false));
    }
    for b in 0..3 {
        v.push(sampler(BIND_SAMPLER0 + b, shared));
    }
    v
}

/// The `DrawQuads` layout: constants, 9 textures, the read-only quads buffer, the 3 samplers.
pub fn draw_quads_entries() -> Vec<Entry> {
    let stages = ShaderStages::VERTEX_FRAGMENT;
    let mut v = vec![buffer(0, stages, BufferBindingType::Uniform, true)];
    for b in 0..DRAW_INPUTS as u32 {
        v.push(texture(DRAW_BIND_INPUT0 + b, stages, TextureViewDimension::D2));
    }
    v.push(buffer(DRAW_BIND_QUADS, stages, BufferBindingType::Storage { read_only: true }, false));
    for b in 0..3 {
        v.push(sampler(DRAW_BIND_SAMPLER0 + b, stages));
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_layout_has_35_dense_bindings() {
        for kind in [LayoutKind::Compute, LayoutKind::ComputeInPlace, LayoutKind::Render] {
            let bindings: Vec<u32> = fixed_entries(kind, PixelFormat::Rgba16Float).iter().map(|e| e.binding).collect();
            assert_eq!(bindings, (0..ENTRY_COUNT as u32).collect::<Vec<_>>());
        }
    }

    #[test]
    fn format_round_trip() {
        for f in [PixelFormat::Rgba16Float, PixelFormat::R8Unorm, PixelFormat::Rg16Unorm, PixelFormat::Bgra8Unorm] {
            assert_eq!(PixelFormat::from_wgpu(f.wgpu()), Some(f));
        }
        assert_eq!(PixelFormat::from_wgpu(wgpu::TextureFormat::Depth32Float), None);
    }

    /// The committed reflection summary agrees with the Rust constants: 35 entries, constant blocks within the window.
    #[test]
    fn reflection_summary_matches_layout() {
        let text = include_str!("../../shaders/reflection.json");
        let json: serde_json::Value = serde_json::from_str(text).unwrap_or_default();
        assert_eq!(json["fixed_layout_entries"], ENTRY_COUNT);
        let modules = json["modules"].as_object().map(|m| m.len()).unwrap_or(0);
        assert_eq!(modules, 26);
        for (name, module) in json["modules"].as_object().into_iter().flatten() {
            for (entry, info) in module.as_object().into_iter().flatten() {
                for size in info["cbuffers"].as_array().into_iter().flatten() {
                    assert!(size.as_u64().unwrap_or(u64::MAX) <= MAX_CONSTANT_BYTES as u64, "{name}.{entry}");
                }
            }
        }
    }
}
