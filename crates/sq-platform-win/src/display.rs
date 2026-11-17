//! The display's HDR state (HDR-PLAN.md, display path): DXGI output description of the monitor the window is on.

use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Dxgi::Common::DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIFactory1, IDXGIOutput6};
use windows::Win32::Graphics::Gdi::{MONITOR_DEFAULTTONEAREST, MonitorFromWindow};
use windows::core::Interface;

/// `(advanced color on, MaxLuminance in nits)` of the output showing the window `hwnd` (a raw `HWND` value); `None` when
/// DXGI cannot tell. Advanced color (HDR) is on when the output's color space is HDR10 (G2084 / P2020).
pub fn output_hdr_state(hwnd: isize) -> Option<(bool, f32)> {
    // SAFETY: plain COM getters on objects created here; `hwnd` is only passed to `MonitorFromWindow`, which tolerates
    // any value (it returns the nearest monitor or null).
    unsafe {
        let monitor = MonitorFromWindow(HWND(hwnd as *mut _), MONITOR_DEFAULTTONEAREST);
        let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let mut a = 0;
        while let Ok(adapter) = factory.EnumAdapters1(a) {
            let mut o = 0;
            while let Ok(output) = adapter.EnumOutputs(o) {
                if let Ok(output6) = output.cast::<IDXGIOutput6>()
                    && let Ok(desc) = output6.GetDesc1()
                    && desc.Monitor == monitor
                {
                    return Some((desc.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020, desc.MaxLuminance));
                }
                o += 1;
            }
            a += 1;
        }
        None
    }
}

/// The primary monitor's work area (the screen without the taskbar) as `(x, y, width, height)` in physical pixels.
pub fn primary_work_area() -> Option<(i32, i32, u32, u32)> {
    use windows_sys::Win32::Foundation::RECT;
    use windows_sys::Win32::UI::WindowsAndMessaging::{SPI_GETWORKAREA, SystemParametersInfoW};
    let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
    // SAFETY: `r` is a live RECT, the size SPI_GETWORKAREA writes.
    let ok = unsafe { SystemParametersInfoW(SPI_GETWORKAREA, 0, (&raw mut r).cast(), 0) };
    (ok != 0 && r.right > r.left && r.bottom > r.top)
        .then(|| (r.left, r.top, (r.right - r.left) as u32, (r.bottom - r.top) as u32))
}
