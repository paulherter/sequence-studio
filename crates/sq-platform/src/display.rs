//! The HDR headroom of the display a window is on (HDR-PLAN.md, display path), behind one trait so the window code has no
//! `cfg(target_os)` and tests can feed fixed values. Headroom = the display's peak over reference white (203 nit), `None` =
//! unknown or not HDR; `> 1.0` lets `surface_mode` pick the float surface.

use winit::window::Window;

/// Reference white of the working space in nits (`HDRConform`, HDR-PLAN.md).
pub const REFERENCE_WHITE_NITS: f32 = 203.0;

pub trait HeadroomProbe {
    /// The headroom of the display `window` is on now (ask again after the window moved to another display).
    fn headroom(&self, window: &Window) -> Option<f32>;
}

/// The system's answer: macOS `NSScreen.maximumExtendedDynamicRangeColorComponentValue`, Windows DXGI output description.
pub struct SystemProbe;

/// A fixed answer (tests, `SQ_HDR_HEADROOM` override of the app).
pub struct FixedProbe(pub Option<f32>);

impl HeadroomProbe for FixedProbe {
    fn headroom(&self, _window: &Window) -> Option<f32> {
        self.0
    }
}

/// macOS: the screen's maximum EDR component value is already relative to SDR white.
pub fn headroom_from_edr(max_component: f64) -> Option<f32> {
    (max_component.is_finite() && max_component > 1.0).then_some(max_component as f32)
}

/// Windows: HDR on (advanced color) and the output's peak luminance in nits.
pub fn headroom_from_output(advanced_color: bool, max_luminance_nits: f32) -> Option<f32> {
    let h = max_luminance_nits / REFERENCE_WHITE_NITS;
    (advanced_color && max_luminance_nits.is_finite() && h > 1.0).then_some(h)
}

impl HeadroomProbe for SystemProbe {
    fn headroom(&self, window: &Window) -> Option<f32> {
        use winit::raw_window_handle::HasWindowHandle;
        #[cfg(any(target_os = "macos", windows))]
        use winit::raw_window_handle::RawWindowHandle;
        let handle = window.window_handle().ok()?.as_raw();
        #[cfg(target_os = "macos")]
        if let RawWindowHandle::AppKit(h) = handle {
            return sq_platform_mac::max_edr_component_value(h.ns_view.as_ptr().cast()).and_then(headroom_from_edr);
        }
        #[cfg(windows)]
        if let RawWindowHandle::Win32(h) = handle {
            let (on, nits) = sq_platform_win::output_hdr_state(h.hwnd.get())?;
            return headroom_from_output(on, nits);
        }
        let _ = handle;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_values_map_to_headroom() {
        assert_eq!(headroom_from_edr(1.0), None);
        assert_eq!(headroom_from_edr(f64::NAN), None);
        assert_eq!(headroom_from_edr(4.0), Some(4.0));
    }

    #[test]
    fn windows_needs_hdr_on_and_a_peak_above_white() {
        assert_eq!(headroom_from_output(false, 1000.0), None, "SDR mode reports the panel peak but shows SDR");
        assert_eq!(headroom_from_output(true, 150.0), None);
        let h = headroom_from_output(true, 1015.0).unwrap_or(0.0);
        assert!((h - 5.0).abs() < 1e-3, "{h}");
    }
}
