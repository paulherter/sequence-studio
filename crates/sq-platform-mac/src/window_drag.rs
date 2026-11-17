//! The window must not move or zoom by itself when a drawn control in the title row is clicked. AppKit lets a click in the
//! titlebar strip drag the window, and a double-click there zoom it, whenever the view under the pointer answers
//! `mouseDownCanMoveWindow` with YES, which is NSView's default for a view that is not opaque (winit's content view).
//! The app moves the window itself for empty title-row space (`drag_window`), so the content view says NO.

use std::ffi::{c_char, c_void};
use std::ptr::NonNull;

// libobjc is already linked (objc2); these are its plain C entry points.
unsafe extern "C" {
    fn object_getClass(object: *const c_void) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *const c_void;
    fn class_replaceMethod(
        class: *mut c_void,
        name: *const c_void,
        imp: *const c_void,
        types: *const c_char,
    ) -> *const c_void;
}

/// `-[NSView mouseDownCanMoveWindow]`: always NO (BOOL is one byte).
extern "C" fn mouse_down_cannot_move_window(_this: *mut c_void, _cmd: *const c_void) -> u8 {
    0
}

/// Makes the class of the content view `ns_view` answer NO to `mouseDownCanMoveWindow`, so the system never starts a window
/// drag or the title-bar double-click zoom from a click on a drawn control. Call once on the main thread after the window
/// exists.
pub fn keep_clicks_out_of_the_titlebar_drag(ns_view: NonNull<c_void>) {
    let ns_view = ns_view.as_ptr();
    // BOOL is `bool` on arm64 and `signed char` on x86_64.
    let types: &std::ffi::CStr = if cfg!(target_arch = "aarch64") { c"B@:" } else { c"c@:" };
    // SAFETY: `ns_view` is the live NSView of this app's window (main thread); replacing a method of its own class only
    // changes this window's view class, and the replacement has the exact signature of the method it replaces.
    unsafe {
        let class = object_getClass(ns_view);
        let selector = sel_registerName(c"mouseDownCanMoveWindow".as_ptr());
        class_replaceMethod(class, selector, mouse_down_cannot_move_window as *const c_void, types.as_ptr());
    }
}
