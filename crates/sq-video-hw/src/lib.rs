//! macOS direct VideoToolbox decode with zero-copy IOSurface import into wgpu, behind sq-media's `VideoDecoding`.
//! Other systems get a stub whose constructor fails, so the workspace builds everywhere. See README.md.

pub mod codec;
pub mod plan;
pub mod retire;

#[cfg(target_os = "macos")]
mod decoder;
#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod deinterlace;
#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod ffi;
#[cfg(target_os = "macos")]
pub use decoder::VtVideoDecoder;

#[cfg(not(target_os = "macos"))]
mod stub;
#[cfg(not(target_os = "macos"))]
pub use stub::VtVideoDecoder;

#[cfg(test)]
mod oracle_tests;
