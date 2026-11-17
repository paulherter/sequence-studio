//! The first window: the wanted size, shrunk to the monitor's work area and centered in it, so a small screen never
//! shows a window that reaches past its edges.

/// A rectangle in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WorkArea {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// Size (logical points) and top-left position (physical pixels) for a window that wants `wanted` logical points at
/// `scale`: never larger than `area`, centered in it.
pub fn fit_first_window(wanted: (f64, f64), scale: f64, area: WorkArea) -> ((f64, f64), (i32, i32)) {
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
    let w = wanted.0.min(f64::from(area.width) / scale);
    let h = wanted.1.min(f64::from(area.height) / scale);
    let x = area.x + ((f64::from(area.width) - w * scale) / 2.0).max(0.0) as i32;
    let y = area.y + ((f64::from(area.height) - h * scale) / 2.0).max(0.0) as i32;
    ((w, h), (x, y))
}

/// The smallest main window, in logical points, on every system.
pub const MIN_WINDOW: (f64, f64) = (640.0, 400.0);

/// The window builder with the minimum size set (winit turns it into WM_GETMINMAXINFO on Windows, the min size hint on X11
/// and Wayland, and the content min size on the Mac).
pub fn with_min_size(attrs: winit::window::WindowAttributes) -> winit::window::WindowAttributes {
    attrs.with_min_inner_size(winit::dpi::LogicalSize::new(MIN_WINDOW.0, MIN_WINDOW.1))
}

/// The size to ask for when a window resize went below the minimum (physical pixels), `None` when it is big enough or the
/// window is minimized (0 x 0). Windows lets `MoveWindow` and `SetWindowPos` go below the tracking minimum, so the resize
/// event enforces it as well.
pub fn clamp_to_min(size: (u32, u32), scale: f64) -> Option<(u32, u32)> {
    if size.0 == 0 || size.1 == 0 {
        return None;
    }
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
    let min = ((MIN_WINDOW.0 * scale).ceil() as u32, (MIN_WINDOW.1 * scale).ceil() as u32);
    let to = (size.0.max(min.0), size.1.max(min.1));
    (to != size).then_some(to)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_builder_carries_the_minimum_on_every_system() {
        let attrs = with_min_size(winit::window::Window::default_attributes());
        assert_eq!(attrs.min_inner_size, Some(winit::dpi::LogicalSize::new(640.0, 400.0).into()));
    }

    #[test]
    fn a_500_by_300_resize_is_raised_to_the_minimum() {
        assert_eq!(clamp_to_min((500, 300), 1.0), Some((640, 400)));
        assert_eq!(clamp_to_min((500, 900), 1.5), Some((960, 900)));
        assert_eq!(clamp_to_min((640, 400), 1.0), None);
        assert_eq!(clamp_to_min((0, 0), 1.0), None, "minimized");
    }

    const WANTED: (f64, f64) = (1440.0, 900.0);

    #[test]
    fn a_1280_by_800_screen_shrinks_the_window_to_the_work_area() {
        let area = WorkArea { x: 0, y: 0, width: 1280, height: 752 };
        assert_eq!(fit_first_window(WANTED, 1.0, area), ((1280.0, 752.0), (0, 0)));
    }

    #[test]
    fn a_big_screen_keeps_the_size_and_centers() {
        let area = WorkArea { x: 100, y: 20, width: 2560, height: 1400 };
        assert_eq!(fit_first_window(WANTED, 1.0, area), ((1440.0, 900.0), (660, 270)));
    }

    #[test]
    fn scale_turns_points_into_pixels() {
        let area = WorkArea { x: 0, y: 0, width: 2560, height: 1440 };
        // 1440 x 900 points at 2x is 2880 x 1800 pixels: too big, so it shrinks to 1280 x 720 points.
        assert_eq!(fit_first_window(WANTED, 2.0, area), ((1280.0, 720.0), (0, 0)));
    }
}
