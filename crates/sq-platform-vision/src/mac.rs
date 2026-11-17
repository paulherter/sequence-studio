//! The Vision calls: a `CVPixelBuffer` per gray frame, one `VNImageRegistrationRequest` per pair (Swift
//! `VNImageRequestHandler(cvPixelBuffer: previous).perform([request targeting current])`).

use crate::{Gray8, Kind, VisionWarp};
use objc2::AnyThread;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Sel};
use objc2_core_foundation::CFRetained;
use objc2_core_video::{
    CVPixelBuffer, CVPixelBufferCreate, CVPixelBufferGetBaseAddress, CVPixelBufferGetBytesPerRow,
    CVPixelBufferLockBaseAddress, CVPixelBufferLockFlags, CVPixelBufferUnlockBaseAddress,
    kCVPixelFormatType_OneComponent8,
};
use objc2_foundation::{NSArray, NSDictionary};
use objc2_vision::{
    VNHomographicImageRegistrationRequest, VNImageHomographicAlignmentObservation, VNImageRequestHandler,
    VNImageTranslationAlignmentObservation, VNRequest, VNTranslationalImageRegistrationRequest,
};
use std::ptr::NonNull;

/// An 8-bit gray `CVPixelBuffer` holding `g` (rows padded to the buffer's stride).
fn pixel_buffer(g: Gray8<'_>) -> Option<CFRetained<CVPixelBuffer>> {
    if g.width == 0 || g.height == 0 || g.pixels.len() < g.width * g.height {
        return None;
    }
    let mut raw: *mut CVPixelBuffer = std::ptr::null_mut();
    // SAFETY: plain CoreVideo calls; the buffer is created here, locked while written and unlocked before use.
    unsafe {
        let made = CVPixelBufferCreate(
            None,
            g.width,
            g.height,
            kCVPixelFormatType_OneComponent8,
            None,
            NonNull::from(&mut raw),
        );
        let buffer = CFRetained::from_raw(NonNull::new(raw).filter(|_| made == 0)?);
        let flags = CVPixelBufferLockFlags(0);
        if CVPixelBufferLockBaseAddress(&buffer, flags) != 0 {
            return None;
        }
        let base = CVPixelBufferGetBaseAddress(&buffer).cast::<u8>();
        let stride = CVPixelBufferGetBytesPerRow(&buffer);
        if !base.is_null() && stride >= g.width {
            for y in 0..g.height {
                std::ptr::copy_nonoverlapping(g.pixels.as_ptr().add(y * g.width), base.add(y * stride), g.width);
            }
        }
        CVPixelBufferUnlockBaseAddress(&buffer, flags);
        (!base.is_null() && stride >= g.width).then_some(buffer)
    }
}

pub(crate) fn register(previous: Gray8<'_>, current: Gray8<'_>, kind: Kind) -> Option<VisionWarp> {
    if (previous.width, previous.height) != (current.width, current.height) {
        return None;
    }
    let (prev, cur) = (pixel_buffer(previous)?, pixel_buffer(current)?);
    // SAFETY: documented Vision API on objects this function owns; the request is performed on this thread.
    unsafe {
        let options = NSDictionary::new();
        let handler =
            VNImageRequestHandler::initWithCVPixelBuffer_options(VNImageRequestHandler::alloc(), &prev, &options);
        match kind {
            Kind::Homographic => {
                let request = VNHomographicImageRegistrationRequest::initWithTargetedCVPixelBuffer_options(
                    VNHomographicImageRegistrationRequest::alloc(),
                    &cur,
                    &options,
                );
                let base: &VNRequest = &request;
                handler.performRequests_error(&NSArray::from_slice(&[base])).ok()?;
                let observation: Retained<VNImageHomographicAlignmentObservation> = request.results()?.firstObject()?;
                Some(VisionWarp::Homography { columns: warp_transform(&observation)? })
            }
            Kind::Translational => {
                let request = VNTranslationalImageRegistrationRequest::initWithTargetedCVPixelBuffer_options(
                    VNTranslationalImageRegistrationRequest::alloc(),
                    &cur,
                    &options,
                );
                let base: &VNRequest = &request;
                handler.performRequests_error(&NSArray::from_slice(&[base])).ok()?;
                let observation: Retained<VNImageTranslationAlignmentObservation> = request.results()?.firstObject()?;
                let t = observation.alignmentTransform();
                Some(VisionWarp::Translation { a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty })
            }
        }
    }
}

/// `warpTransform` is a `simd_float3x3`, which the generated bindings leave out. On Apple silicon the three columns come
/// back in v0, v1 and v2 (a homogeneous vector aggregate), which Rust's `extern "C"` return does not model for vector
/// members, so the call is made in assembly.
#[cfg(target_arch = "aarch64")]
fn warp_transform(observation: &VNImageHomographicAlignmentObservation) -> Option<[[f32; 3]; 3]> {
    use core::arch::aarch64::float32x4_t;
    use std::arch::asm;
    let object: *const AnyObject = std::ptr::from_ref(observation).cast();
    let sel: Sel = objc2::sel!(warpTransform);
    let send = objc2::ffi::objc_msgSend as *const ();
    // SAFETY: a `Sel` is one pointer.
    let sel_ptr = unsafe { std::mem::transmute::<Sel, *const std::ffi::c_void>(sel) };
    let (mut a, mut b, mut c): (float32x4_t, float32x4_t, float32x4_t);
    // SAFETY: calls `objc_msgSend(self, _cmd)` under the C calling convention; the method returns simd_float3x3 in v0...v2.
    unsafe {
        asm!(
            "blr {send}",
            send = in(reg) send,
            in("x0") object,
            in("x1") sel_ptr,
            lateout("v0") a,
            lateout("v1") b,
            lateout("v2") c,
            clobber_abi("C"),
        );
    }
    // SAFETY: a float32x4_t is four f32.
    let col = |v: float32x4_t| unsafe { std::mem::transmute::<float32x4_t, [f32; 4]>(v) };
    let (a, b, c) = (col(a), col(b), col(c));
    Some([[a[0], a[1], a[2]], [b[0], b[1], b[2]], [c[0], c[1], c[2]]])
}

/// shortcut: Intel Macs return the matrix through `objc_msgSend_stret`, not bound here; the homography is skipped there
/// and the translation (which needs no matrix) still runs. Upgrade when an Intel Mac is a target again.
#[cfg(not(target_arch = "aarch64"))]
fn warp_transform(_observation: &VNImageHomographicAlignmentObservation) -> Option<[[f32; 3]; 3]> {
    None
}
