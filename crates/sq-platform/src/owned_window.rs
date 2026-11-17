//! A window owned by another one (the floating panels of the main window): it stays above its owner when the owner is
//! clicked, as the Swift utility panels do.
//!
//! Windows: the owner relation (`with_owner_window`; an owned window is always above its owner and leaves the taskbar).
//! macOS and X11: a parent window (a child `NSWindow`, `WM_TRANSIENT_FOR`). Wayland: winit 0.30 has no parent for a
//! toplevel, so the compositor orders the windows (shortcut: upgrade when winit offers an xdg parent).

use winit::window::{Window, WindowAttributes};

/// `attrs` with `owner` as the owner of the new window; unchanged where the system has no such relation.
pub fn owned_by(attrs: WindowAttributes, owner: &Window) -> WindowAttributes {
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let Ok(handle) = owner.window_handle() else { return attrs };
    let raw = handle.as_raw();
    #[cfg(windows)]
    {
        use winit::platform::windows::WindowAttributesExtWindows;
        match raw {
            RawWindowHandle::Win32(h) => attrs.with_owner_window(h.hwnd.get()),
            _ => attrs,
        }
    }
    #[cfg(not(windows))]
    {
        match raw {
            // Wayland handles stay unparented (see the module text).
            RawWindowHandle::Wayland(_) => attrs,
            // SAFETY: the handle is the live main window's, which outlives the floating windows it owns.
            other => unsafe { attrs.with_parent_window(Some(other)) },
        }
    }
}
