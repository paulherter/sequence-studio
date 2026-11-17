//! The system setting "Double-click a window's title bar to" (`AppleActionOnDoubleClick`: Maximize, Minimize or None).

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject};
use std::ffi::{CStr, c_char};

/// The raw text of `AppleActionOnDoubleClick` from the global domain, `None` when the user never set it.
pub fn title_bar_double_click_setting() -> Option<String> {
    let defaults = AnyClass::get(c"NSUserDefaults")?;
    let string = AnyClass::get(c"NSString")?;
    // SAFETY: NSUserDefaults/NSString class methods with the documented signatures; the returned UTF8String pointer is
    // valid while the autoreleased NSString lives, and is copied before this returns.
    unsafe {
        let key: *mut AnyObject = msg_send![string, stringWithUTF8String: c"AppleActionOnDoubleClick".as_ptr()];
        let user: *mut AnyObject = msg_send![defaults, standardUserDefaults];
        if key.is_null() || user.is_null() {
            return None;
        }
        let value: *mut AnyObject = msg_send![user, stringForKey: key];
        if value.is_null() {
            return None;
        }
        let text: *const c_char = msg_send![value, UTF8String];
        (!text.is_null()).then(|| CStr::from_ptr(text).to_string_lossy().into_owned())
    }
}
