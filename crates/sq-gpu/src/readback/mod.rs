//! Readback: texture and buffer contents to CPU bytes through pooled staging buffers.

use crate::frames::GpuTexture;
use crate::gpu::{Gpu, GpuError, lock};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, mpsc};

/// Staging buffers by size, reused by the next readback.
#[derive(Default)]
pub(crate) struct StagingPool {
    free: Arc<Mutex<HashMap<u64, Vec<wgpu::Buffer>>>>,
}

impl StagingPool {
    pub(crate) fn take(&self, device: &wgpu::Device, size: u64) -> wgpu::Buffer {
        let reused = lock(&self.free).get_mut(&size).and_then(Vec::pop);
        reused.unwrap_or_else(|| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("readback"),
                size,
                usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            })
        })
    }
}

/// A recorded copy into a staging buffer. Submit the command buffer, then [`ReadbackTicket::wait`].
pub struct ReadbackTicket {
    staging: wgpu::Buffer,
    pool: Arc<Mutex<HashMap<u64, Vec<wgpu::Buffer>>>>,
    /// Bytes per row in the staging buffer, and the tight row length and row count to return.
    padded_row: u64,
    row: u64,
    rows: u64,
}

impl ReadbackTicket {
    pub(crate) fn texture(
        gpu: &Gpu,
        encoder: &mut wgpu::CommandEncoder,
        texture: &GpuTexture,
    ) -> Result<Self, GpuError> {
        let format = texture.format().ok_or_else(|| GpuError::Readback("unsupported texture format".into()))?;
        let (width, height) = (texture.width(), texture.height());
        let row = u64::from(width) * u64::from(format.bytes_per_pixel());
        let padded_row = row.next_multiple_of(u64::from(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT));
        let staging = gpu.staging.take(gpu.device(), padded_row * u64::from(height));
        encoder.copy_texture_to_buffer(
            texture.texture().as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &staging,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_row as u32),
                    rows_per_image: Some(height),
                },
            },
            texture.texture().size(),
        );
        Ok(Self { staging, pool: Arc::clone(&gpu.staging.free), padded_row, row, rows: u64::from(height) })
    }

    pub(crate) fn buffer(gpu: &Gpu, encoder: &mut wgpu::CommandEncoder, source: &wgpu::Buffer, length: u64) -> Self {
        let length = length.next_multiple_of(4);
        let staging = gpu.staging.take(gpu.device(), length);
        encoder.copy_buffer_to_buffer(source, 0, &staging, 0, length);
        Self { staging, pool: Arc::clone(&gpu.staging.free), padded_row: length, row: length, rows: 1 }
    }

    /// Blocks until the copy finished and returns the tightly packed bytes (rows without padding).
    pub fn wait(self, gpu: &Gpu) -> Result<Vec<u8>, GpuError> {
        self.wait_with(gpu, None)
    }

    /// Like [`ReadbackTicket::wait`], but waits only for the submission `index` that holds the copy: work submitted after
    /// it keeps running (a pipelined export has the next frame in flight).
    pub fn wait_after(self, gpu: &Gpu, index: &wgpu::SubmissionIndex) -> Result<Vec<u8>, GpuError> {
        self.wait_with(gpu, Some(index))
    }

    fn wait_with(self, gpu: &Gpu, index: Option<&wgpu::SubmissionIndex>) -> Result<Vec<u8>, GpuError> {
        let (sender, receiver) = mpsc::channel();
        self.staging.slice(..).map_async(wgpu::MapMode::Read, move |result| {
            // The receiver outlives the poll below.
            let _ = sender.send(result);
        });
        match index {
            None => gpu.wait()?,
            Some(i) => {
                gpu.device()
                    .poll(wgpu::PollType::Wait { submission_index: Some(i.clone()), timeout: None })
                    .map_err(|e| GpuError::Readback(e.to_string()))?;
            }
        }
        receiver
            .recv()
            .map_err(|e| GpuError::Readback(e.to_string()))?
            .map_err(|e| GpuError::Readback(e.to_string()))?;
        let bytes = {
            let mapped = self.staging.slice(..).get_mapped_range().map_err(|e| GpuError::Readback(e.to_string()))?;
            let (padded, row) = (self.padded_row as usize, self.row as usize);
            let mut out = Vec::with_capacity(row * self.rows as usize);
            for r in 0..self.rows as usize {
                out.extend_from_slice(&mapped[r * padded..r * padded + row]);
            }
            out
        };
        self.staging.unmap();
        let size = self.staging.size();
        lock(&self.pool).entry(size).or_default().push(self.staging);
        Ok(bytes)
    }
}
