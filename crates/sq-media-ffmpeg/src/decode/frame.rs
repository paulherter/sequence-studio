use crate::shim::Frame;
use sq_frame::sqframe::SQFrameStorage;

/// `SQFrameStorage` of a decoded FFmpeg picture: a reference to the AVFrame. A hardware frame is a slice of a D3D11
/// texture array owned by the decoder's pool (the slice returns to the pool when the last reference goes); a software
/// frame holds its pixels in memory. `download()` gives the pixels in the frame's `SQFramePixelFormat` layout
/// (NV12 or P010, planes packed).
pub type FFmpegFrame = Frame;

impl SQFrameStorage for Frame {}

/// Pixels in memory (frame sources and tests): planes packed in the `SQFrame`'s pixel format layout.
pub struct MemoryFrame {
    pub bytes: Vec<u8>,
    /// Bytes per row of the first plane.
    pub bytes_per_row: usize,
}

impl SQFrameStorage for MemoryFrame {}
