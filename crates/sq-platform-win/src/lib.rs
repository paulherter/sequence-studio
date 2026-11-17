//! Windows-only services of the app (see the README). Empty on other systems.
#![cfg(windows)]

mod console;
mod disk;
mod display;
mod drives;
mod fault;
mod keyboard;
mod language;
mod launch;
mod library;
mod memory;
mod notify;
mod power;
mod recent;
mod reduce_motion;
pub mod setup;
mod shell_open;
mod taskbar;
mod toast;

pub use console::attach_parent_console;
pub use disk::{free_bytes, physical_memory, volume_bytes};
pub use display::{output_hdr_state, primary_work_area};
pub use drives::{bus_of_code, drives};
pub use fault::install_fault_report;
pub use keyboard::{active_keyboard, cached_active_keyboard};
pub use language::preferred_languages;
pub use launch::{has_visible_window, open_with_default};
pub use library::first_missing_library;
pub use memory::working_set_bytes;
pub use notify::{BalloonNotifier, app_is_active};
pub use power::SleepLock;
pub use recent::add_recent_document;
pub use reduce_motion::reduce_motion;
pub use shell_open::open;
pub use sq_fault_text::FaultConfig;
pub use taskbar::TaskbarProgress;
pub use toast::{APP_USER_MODEL_ID, ToastSender, register_app_id};

use std::sync::atomic::{AtomicU32, Ordering};
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::ScreenToClient;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetDoubleClickTime, TME_LEAVE, TME_NONCLIENT, TRACKMOUSEEVENT, TrackMouseEvent,
};
use windows_sys::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetMessageTime, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT, HTCAPTION, HTCLIENT, HTLEFT, HTMAXBUTTON, HTRIGHT, HTTOP,
    HTTOPLEFT, HTTOPRIGHT, IsZoomed, PostMessageW, SW_MAXIMIZE, SW_RESTORE, ShowWindow, WM_CLOSE, WM_LBUTTONDBLCLK,
    WM_LBUTTONDOWN, WM_NCDESTROY, WM_NCHITTEST, WM_NCLBUTTONDBLCLK, WM_NCLBUTTONDOWN, WM_NCLBUTTONUP, WM_NCMOUSELEAVE,
    WM_NCMOUSEMOVE, WM_NCRBUTTONDOWN, WM_NCRBUTTONUP,
};
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::Window;

/// What a point of the borderless window is to the window manager.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    /// Ours: clicks reach the app.
    Client,
    /// Drag area; a double click maximizes.
    Caption,
    /// The maximize button: Windows 11 shows its snap layouts over it.
    Maximize,
    Left,
    Right,
    Top,
    Bottom,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

impl Hit {
    fn code(self) -> u32 {
        match self {
            Hit::Client => HTCLIENT,
            Hit::Caption => HTCAPTION,
            Hit::Maximize => HTMAXBUTTON,
            Hit::Left => HTLEFT,
            Hit::Right => HTRIGHT,
            Hit::Top => HTTOP,
            Hit::Bottom => HTBOTTOM,
            Hit::TopLeft => HTTOPLEFT,
            Hit::TopRight => HTTOPRIGHT,
            Hit::BottomLeft => HTBOTTOMLEFT,
            Hit::BottomRight => HTBOTTOMRIGHT,
        }
    }
}

/// The pointer over the maximize button. The system keeps these messages from the client area, so the window
/// forwards them (client pixels).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MaxButton {
    Moved(f32, f32),
    Down(f32, f32),
    Up(f32, f32),
    /// The pointer is over another part of the frame now.
    Left,
}

/// Time (ms, `GetMessageTime`) of the last button press that landed on the client area (a control, a menu row).
static LAST_CLIENT_PRESS: AtomicU32 = AtomicU32::new(0);

/// Whether a double click on the caption may maximize: not when its first press was a client press (a double click on a
/// control or on a popup row, which has closed by the second press), only when both presses were on the empty caption.
fn caption_double_click_zooms(now_ms: u32, last_client_press_ms: u32, double_click_ms: u32) -> bool {
    now_ms.wrapping_sub(last_client_press_ms) > double_click_ms
}

/// The app's answers to the frame messages of its borderless window.
pub struct Chrome {
    /// What the client pixel (x, y) is.
    pub hit: Box<dyn Fn(f32, f32) -> Hit>,
    /// The pointer over the maximize button.
    pub max_button: Box<dyn Fn(MaxButton)>,
}

/// Subclass procedure: answers the hit test and routes the maximize button's frame messages, everything else goes on
/// to the window's own procedure.
unsafe extern "system" fn chrome_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    id: usize,
    data: usize,
) -> LRESULT {
    // SAFETY: `data` is the `Box<Chrome>` leaked by `install_chrome`; it lives until `WM_NCDESTROY` below.
    let chrome = unsafe { &*(data as *const Chrome) };
    // The low and high words are signed screen coordinates (negative on a left-hand monitor).
    let client = || {
        let mut p = POINT { x: (lparam & 0xffff) as i16 as i32, y: ((lparam >> 16) & 0xffff) as i16 as i32 };
        // SAFETY: `hwnd` is the window this procedure is installed on; `p` is a plain in-out struct.
        unsafe { ScreenToClient(hwnd, &mut p) };
        (p.x as f32, p.y as f32)
    };
    let on_max = wparam == HTMAXBUTTON as WPARAM;
    match msg {
        WM_NCHITTEST => {
            let (x, y) = client();
            return (chrome.hit)(x, y).code() as LRESULT;
        }
        WM_NCMOUSEMOVE if on_max => {
            let (x, y) = client();
            // The system reports the pointer leaving the frame only when asked, and once per request.
            let mut track = TRACKMOUSEEVENT {
                cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                dwFlags: TME_LEAVE | TME_NONCLIENT,
                hwndTrack: hwnd,
                dwHoverTime: 0,
            };
            // SAFETY: `track` is a fully initialized struct for this window.
            unsafe { TrackMouseEvent(&mut track) };
            (chrome.max_button)(MaxButton::Moved(x, y));
            return 0;
        }
        WM_NCMOUSELEAVE => (chrome.max_button)(MaxButton::Left),
        // A double click on the drag area toggles maximize; the borderless window has no caption style for the
        // system to do it.
        WM_NCLBUTTONDBLCLK if wparam == HTCAPTION as WPARAM => {
            // SAFETY: plain calls on the window this procedure is installed on.
            unsafe {
                if caption_double_click_zooms(
                    GetMessageTime() as u32,
                    LAST_CLIENT_PRESS.load(Ordering::Relaxed),
                    GetDoubleClickTime(),
                ) {
                    ShowWindow(hwnd, if IsZoomed(hwnd) != 0 { SW_RESTORE } else { SW_MAXIMIZE });
                }
            }
            return 0;
        }
        WM_LBUTTONDOWN | WM_LBUTTONDBLCLK => {
            // SAFETY: reads the time stamp of the message being processed.
            LAST_CLIENT_PRESS.store(unsafe { GetMessageTime() } as u32, Ordering::Relaxed);
        }
        WM_NCMOUSEMOVE => (chrome.max_button)(MaxButton::Left),
        WM_NCLBUTTONDOWN | WM_NCLBUTTONDBLCLK if on_max => {
            let (x, y) = client();
            (chrome.max_button)(MaxButton::Down(x, y));
            return 0;
        }
        WM_NCLBUTTONUP if on_max => {
            let (x, y) = client();
            (chrome.max_button)(MaxButton::Up(x, y));
            return 0;
        }
        // No system menu on the caption: every menu is the app's own.
        WM_NCRBUTTONDOWN | WM_NCRBUTTONUP if wparam == HTCAPTION as WPARAM => return 0,
        WM_NCDESTROY => {
            // SAFETY: the last message of the window; the box was leaked by `install_chrome` and nothing uses it after.
            unsafe {
                RemoveWindowSubclass(hwnd, Some(chrome_proc), id);
                drop(Box::from_raw(data as *mut Chrome));
            }
        }
        _ => {}
    }
    // SAFETY: forwards the message unchanged to the previous procedure of the same window.
    unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) }
}

/// Makes the drawn caption and edges of a borderless `window` behave like system chrome. Returns false when the
/// window has no Win32 handle or the subclass could not be set.
pub fn install_chrome(window: &Window, chrome: Chrome) -> bool {
    let Ok(handle) = window.window_handle() else { return false };
    let RawWindowHandle::Win32(h) = handle.as_raw() else { return false };
    let data = Box::into_raw(Box::new(chrome));
    // SAFETY: the handle belongs to a live winit window on this thread; the procedure frees `data` with the window.
    let set = unsafe { SetWindowSubclass(h.hwnd.get() as HWND, Some(chrome_proc), 1, data as usize) != 0 };
    if !set {
        // SAFETY: the subclass was not set, so nothing else owns the box.
        drop(unsafe { Box::from_raw(data) });
    }
    set
}

/// Asks `window` to close the way its own close button does (winit reports `CloseRequested`).
pub fn request_close(window: &Window) {
    let Ok(handle) = window.window_handle() else { return };
    if let RawWindowHandle::Win32(h) = handle.as_raw() {
        // SAFETY: posts a plain message to a live window of this process.
        unsafe { PostMessageW(h.hwnd.get() as HWND, WM_CLOSE, 0, 0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_caption_double_click_zooms_only_when_no_client_press_began_it() {
        assert!(caption_double_click_zooms(10_000, 2_000, 500), "the last client press was long ago");
        assert!(
            !caption_double_click_zooms(2_300, 2_000, 500),
            "the first press was a client press: a control's double click"
        );
        assert!(caption_double_click_zooms(100, u32::MAX - 5_000, 500), "the millisecond clock wraps");
    }

    #[test]
    fn hits_map_to_the_system_codes() {
        assert_eq!(Hit::Caption.code(), HTCAPTION);
        assert_eq!(Hit::Maximize.code(), HTMAXBUTTON);
        assert_eq!(Hit::BottomRight.code(), HTBOTTOMRIGHT);
    }
}
