// Swift: ScopesReference.swift
//! CPU reference for the GPU scopes: the working-linear pixel through the Rec.709 output encode, then the shared scope
//! binning (`ScopeBinning` in Swift `SQGPUKernels`, not ported here; see NOTES-color.md).

use super::output::rec709_encode;
use super::vec::Vec3;

/// Output signal R'G'B' (clamped 0...1, BT.709 OETF) and Y'.
pub fn signal(working_linear: Vec3) -> (Vec3, f32) {
    let s = rec709_encode(working_linear);
    (s, s.x * 0.2126 + s.y * 0.7152 + s.z * 0.0722)
}
