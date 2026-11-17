//! Passthrough shader modules: the one place that creates unvalidated shaders.

use super::ShaderEntry;
use crate::gpu::{Gpu, GpuError, lock};
use std::borrow::Cow;
use std::sync::Arc;

impl Gpu {
    /// The wgpu module for `entry`. Metal compiles the MSL of the whole module once (all its entries); D3D12 takes the DXIL
    /// and Vulkan the SPIR-V of the one entry.
    #[allow(unsafe_code)]
    pub(crate) fn shader_module(&self, entry: &ShaderEntry) -> Result<Arc<wgpu::ShaderModule>, GpuError> {
        let key = if cfg!(target_os = "macos") {
            entry.module.to_string()
        } else {
            format!("{}.{}", entry.module, entry.name)
        };
        let mut cache = lock(&self.modules);
        if let Some(m) = cache.get(&key) {
            return Ok(Arc::clone(m));
        }
        let point = |e: &ShaderEntry| wgpu::PassthroughShaderEntryPoint {
            name: Cow::Borrowed(e.name),
            workgroup_size: e.workgroup,
        };
        #[allow(unused_mut)]
        let mut descriptor =
            wgpu::ShaderModuleDescriptorPassthrough { label: Some(entry.module), ..Default::default() };
        #[cfg(target_os = "macos")]
        {
            descriptor.entry_points = super::ENTRIES.iter().filter(|e| e.module == entry.module).map(point).collect();
            descriptor.msl = Some(Cow::Borrowed(entry.msl));
        }
        #[cfg(windows)]
        {
            descriptor.entry_points = Cow::Owned(vec![point(entry)]);
            descriptor.dxil = Some(Cow::Borrowed(entry.dxil));
        }
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            descriptor.entry_points = Cow::Owned(vec![point(entry)]);
            let words = entry.spirv.as_chunks::<4>().0.iter().map(|w| u32::from_le_bytes(*w)).collect();
            descriptor.spirv = Some(Cow::Owned(words));
        }
        {
            // SAFETY: passthrough skips wgpu validation. The source comes from slangc for this backend and the layouts in
            // `layout` mirror Bindings.slang; `cargo xtask shaders` checks the reflection against them.
            let module = Arc::new(unsafe { self.device().create_shader_module_passthrough(descriptor) });
            cache.insert(key, Arc::clone(&module));
            Ok(module)
        }
    }
}
