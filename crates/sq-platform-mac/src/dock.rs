//! The Dock icon shows the overall export progress (Swift `DockProgress`, which draws a bar over the icon).
//!
//! The progress is the Dock tile's badge text ("42%"), not a bar drawn over the icon (a bar needs a custom `NSView`
//! class through objc2-app-kit and a Mac to test on). The notification when an export ends in the
//! background (`ExportNotificationDelegate`) needs the UserNotifications framework and is not ported yet.

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject};
use std::ffi::CString;

/// Tracks the last shown percent so the tile is touched on a visible change only (1 %).
#[derive(Default)]
pub struct DockProgress {
    shown: Option<i64>,
}

/// The badge text for a progress fraction, `None` clears it.
pub fn badge_text(progress: Option<f64>) -> Option<String> {
    progress.map(|p| format!("{}%", (p.clamp(0.0, 1.0) * 100.0).round() as i64))
}

impl DockProgress {
    /// Call every frame with the overall export progress (`None` = nothing exports). Main thread only.
    pub fn set(&mut self, progress: Option<f64>) {
        let percent = progress.map(|p| (p.clamp(0.0, 1.0) * 100.0).round() as i64);
        if percent == self.shown {
            return;
        }
        self.shown = percent;
        set_badge(badge_text(progress).as_deref());
    }
}

fn set_badge(text: Option<&str>) {
    let (Some(app_class), Some(string_class)) = (AnyClass::get(c"NSApplication"), AnyClass::get(c"NSString")) else {
        return;
    };
    // SAFETY: AppKit calls on the main thread (the caller's contract): `sharedApplication` and `dockTile` return live
    // objects, `setBadgeLabel:` takes an NSString or nil, and the string is autoreleased by `stringWithUTF8String:`.
    unsafe {
        let app: *mut AnyObject = msg_send![app_class, sharedApplication];
        if app.is_null() {
            return;
        }
        let tile: *mut AnyObject = msg_send![app, dockTile];
        if tile.is_null() {
            return;
        }
        let label: *mut AnyObject = match text.and_then(|t| CString::new(t).ok()) {
            Some(c) => msg_send![string_class, stringWithUTF8String: c.as_ptr()],
            None => std::ptr::null_mut(),
        };
        let () = msg_send![tile, setBadgeLabel: label];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_badge_follows_the_progress_and_clears() {
        assert_eq!(badge_text(Some(0.424)).as_deref(), Some("42%"));
        assert_eq!(badge_text(Some(1.7)).as_deref(), Some("100%"));
        assert_eq!(badge_text(None), None);
    }
}
