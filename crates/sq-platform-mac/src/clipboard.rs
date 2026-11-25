//! What the general pasteboard offers, without reading any data: its change count and the type names.

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject};
use std::ffi::CStr;

/// The pasteboard's change count and whether it offers files and/or a picture. `None` when the pasteboard is unreachable.
pub fn clipboard_facts() -> Option<(u64, bool, bool)> {
    let class = AnyClass::get(c"NSPasteboard")?;
    // SAFETY: `generalPasteboard` returns a live singleton; `changeCount` returns an NSInteger, `types` an NSArray of
    // NSString (or nil); `count`, `objectAtIndex:` and `UTF8String` are plain getters and the strings live while the
    // autoreleased array does (no autorelease pool drains inside this function).
    unsafe {
        let board: *mut AnyObject = msg_send![class, generalPasteboard];
        if board.is_null() {
            return None;
        }
        let count: isize = msg_send![board, changeCount];
        let types: *mut AnyObject = msg_send![board, types];
        let (mut files, mut image) = (false, false);
        if !types.is_null() {
            let n: usize = msg_send![types, count];
            for i in 0..n {
                let ty: *mut AnyObject = msg_send![types, objectAtIndex: i];
                if ty.is_null() {
                    continue;
                }
                let raw: *const std::ffi::c_char = msg_send![ty, UTF8String];
                if raw.is_null() {
                    continue;
                }
                match CStr::from_ptr(raw).to_str().unwrap_or("") {
                    "public.file-url" | "NSFilenamesPboardType" => files = true,
                    "public.png" | "public.tiff" | "public.jpeg" => image = true,
                    _ => {}
                }
            }
        }
        Some((count as u64, files, image))
    }
}
