//! The uniform arena: constant blocks are written into big chunk buffers and bound with dynamic offsets (b0/b1), so a pass
//! costs one `write_buffer` and no buffer allocation per dispatch. Immediates stay unused (they would move cbuffers on D3D12).

use crate::gpu::{GpuError, lock};
use crate::layout::MAX_CONSTANT_BYTES;
use std::sync::{Arc, Mutex};

/// Bytes of block data in one chunk (plus [`MAX_CONSTANT_BYTES`] of tail, the window of the last block).
const CHUNK_BYTES: u64 = 256 * 1024;

/// Finished chunks wait here for the next command buffer; they come back when the GPU is done with them.
pub(crate) struct ChunkPool {
    pub(crate) free: Arc<Mutex<Vec<wgpu::Buffer>>>,
    pub(crate) alignment: u64,
}

impl ChunkPool {
    pub(crate) fn new(alignment: u64) -> Self {
        Self { free: Arc::default(), alignment: alignment.max(4) }
    }

    pub(crate) fn shared(&self) -> Arc<Mutex<Vec<wgpu::Buffer>>> {
        Arc::clone(&self.free)
    }
}

/// The blocks of one command buffer.
pub(crate) struct UniformArena {
    chunks: Vec<wgpu::Buffer>,
    used: u64,
}

impl UniformArena {
    pub(crate) fn new() -> Self {
        Self { chunks: Vec::new(), used: CHUNK_BYTES }
    }

    /// Copies `bytes` into the arena; returns the chunk and the dynamic offset of the block.
    pub(crate) fn push(&mut self, gpu: &crate::gpu::Gpu, bytes: &[u8]) -> Result<(wgpu::Buffer, u32), GpuError> {
        if bytes.len() > MAX_CONSTANT_BYTES {
            return Err(GpuError::Binding(format!(
                "constant block of {} B exceeds {MAX_CONSTANT_BYTES} B",
                bytes.len()
            )));
        }
        let size = (bytes.len() as u64).max(16).next_multiple_of(gpu.chunks.alignment);
        if self.used + size > CHUNK_BYTES {
            let reused = lock(&gpu.chunks.free).pop();
            let chunk = reused.unwrap_or_else(|| {
                gpu.device().create_buffer(&wgpu::BufferDescriptor {
                    label: Some("uniform arena"),
                    size: CHUNK_BYTES + MAX_CONSTANT_BYTES as u64,
                    usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                })
            });
            self.chunks.push(chunk);
            self.used = 0;
        }
        let chunk = self.chunks.last().ok_or_else(|| GpuError::Binding("uniform arena has no chunk".into()))?;
        let mut padded = bytes.to_vec();
        padded.resize(bytes.len().next_multiple_of(4), 0);
        gpu.queue().write_buffer(chunk, self.used, &padded);
        let offset = self.used as u32;
        self.used += size;
        Ok((chunk.clone(), offset))
    }

    pub(crate) fn into_chunks(self) -> Vec<wgpu::Buffer> {
        self.chunks
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_are_aligned_and_chunks_roll_over() -> Result<(), GpuError> {
        let Some(gpu) = crate::gpu::tests::test_gpu() else { return Ok(()) };
        let mut arena = UniformArena::new();
        let (a, first) = arena.push(&gpu, &[1; 20])?;
        let (b, second) = arena.push(&gpu, &[2; 3104])?;
        assert_eq!((first, u64::from(second) % gpu.chunks.alignment), (0, 0));
        assert_eq!(a, b);
        assert!(second >= 20);
        for _ in 0..200 {
            arena.push(&gpu, &[0; 4096])?;
        }
        assert!(arena.into_chunks().len() >= 2);
        assert!(UniformArena::new().push(&gpu, &[0; 4097]).is_err());
        Ok(())
    }
}
