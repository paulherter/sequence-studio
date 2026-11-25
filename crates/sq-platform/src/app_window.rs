//! The name every window of the app carries for the desktop. Linux desktops match a window to its menu entry, icon and task
//! bar group by the Wayland `app_id` (X11: the `WM_CLASS`); a window without one shows a generic icon and groups apart.

use winit::window::WindowAttributes;

/// `attrs` with the app's id on Linux (Wayland `app_id` and X11 class, the installed desktop entry's id); unchanged on
/// macOS and Windows, which identify the app by its bundle and its exe. Every window of the app goes through this, the floating
/// panels too: a second toplevel without an id would group apart from the main window.
pub fn with_app_id(attrs: WindowAttributes) -> WindowAttributes {
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        use winit::platform::wayland::WindowAttributesExtWayland;
        use winit::platform::x11::WindowAttributesExtX11;
        let id = crate::desktop_integration::app_id();
        // One name for both display servers: winit applies the one of the server the window ends up on.
        let attrs = WindowAttributesExtWayland::with_name(attrs, id, id);
        WindowAttributesExtX11::with_name(attrs, id, id)
    }
    #[cfg(not(all(unix, not(target_os = "macos"))))]
    attrs
}

#[cfg(all(test, unix, not(target_os = "macos")))]
mod tests {
    use super::*;
    use winit::window::Window;

    /// The platform part of winit's attributes has no getter; its `Debug` text names the application.
    fn named(attrs: &WindowAttributes) -> bool {
        let want = format!(
            "general: {:?}, instance: {:?}",
            crate::desktop_integration::app_id(),
            crate::desktop_integration::app_id()
        );
        format!("{attrs:?}").contains(&want)
    }

    #[test]
    fn a_window_gets_the_id_of_the_desktop_entry() {
        assert!(!named(&Window::default_attributes()), "the check can tell a named window from an unnamed one");
        assert!(named(&with_app_id(Window::default_attributes().with_title("Sequence Studio"))));
    }

    #[test]
    fn the_id_survives_the_attributes_a_floating_panel_adds() {
        let float = with_app_id(Window::default_attributes().with_decorations(false).with_title("Effects"));
        assert!(named(&float));
    }
}
