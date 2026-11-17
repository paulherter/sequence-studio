//! The system's "Reduce motion" setting (`NSWorkspace.accessibilityDisplayShouldReduceMotion`).

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject, Bool};

/// True when the user turned on Reduce motion in the Accessibility settings.
pub fn reduce_motion() -> bool {
    let Some(class) = AnyClass::get(c"NSWorkspace") else { return false };
    // SAFETY: `sharedWorkspace` returns a live singleton; the property getter takes no arguments and returns a BOOL.
    unsafe {
        let ws: *mut AnyObject = msg_send![class, sharedWorkspace];
        if ws.is_null() {
            return false;
        }
        let on: Bool = msg_send![ws, accessibilityDisplayShouldReduceMotion];
        on.as_bool()
    }
}
