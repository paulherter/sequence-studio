//! The system's animation setting (Settings > Accessibility > Visual effects > Animation effects).

use windows_sys::Win32::UI::WindowsAndMessaging::{SPI_GETCLIENTAREAANIMATION, SystemParametersInfoW};

/// True when the user turned animation effects off (reduce motion).
pub fn reduce_motion() -> bool {
    let mut on: i32 = 1;
    // SAFETY: `on` is a writable BOOL (4 bytes) as SPI_GETCLIENTAREAANIMATION requires.
    let ok = unsafe { SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, (&raw mut on).cast(), 0) };
    ok != 0 && on == 0
}
