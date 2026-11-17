//! FFmpeg demux, decode and encode behind sq-media's traits (C++ shim built with cc).

pub mod animated;
pub mod conform;
pub mod decode;
pub mod encode;
pub mod shim;

#[cfg(test)]
#[path = "../build_def.rs"]
mod build_def;
