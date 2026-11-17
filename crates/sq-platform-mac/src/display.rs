//! The display's HDR headroom (HDR-PLAN.md, display path): `NSScreen.maximumExtendedDynamicRangeColorComponentValue` of the
//! screen the window is on, relative to SDR white (1.0 = no headroom).

use objc2::msg_send;
use objc2::runtime::AnyObject;
use std::ffi::c_void;

/// What the window's screen reports as (current, potential) maximum extended-range component value. The current value is 1.0
/// while no EDR content shows on an XDR screen (and it follows the brightness), the potential one is what the screen can
/// reach once a layer asks for EDR. `ns_view` is the window's `NSView` (winit's `AppKitWindowHandle::ns_view`); `None` when
/// the view has no window or screen yet. Call on the main thread.
pub fn edr_values(ns_view: *mut c_void) -> Option<(f64, f64)> {
    if ns_view.is_null() {
        return None;
    }
    // SAFETY: `ns_view` is a live NSView owned by the window (the caller holds the window); each message is a getter that
    // returns an autoreleased object or a scalar, and nil is checked before the next message.
    unsafe {
        let view = ns_view as *mut AnyObject;
        let window: *mut AnyObject = msg_send![view, window];
        if window.is_null() {
            return None;
        }
        let screen: *mut AnyObject = msg_send![window, screen];
        if screen.is_null() {
            return None;
        }
        let current: f64 = msg_send![screen, maximumExtendedDynamicRangeColorComponentValue];
        let has_potential: bool =
            msg_send![screen, respondsToSelector: objc2::sel!(maximumPotentialExtendedDynamicRangeColorComponentValue)];
        let potential: f64 = if has_potential {
            msg_send![screen, maximumPotentialExtendedDynamicRangeColorComponentValue]
        } else {
            current
        };
        Some((current, potential))
    }
}

/// The largest component value the window's screen can show above SDR white: the potential one, so a screen that is idle at
/// 1.0 (no EDR content yet) still gets the float surface; `None` as `edr_values`.
pub fn max_edr_component_value(ns_view: *mut c_void) -> Option<f64> {
    edr_values(ns_view).map(|(current, potential)| current.max(potential))
}
