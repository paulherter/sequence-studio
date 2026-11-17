// Swift: MacShell/ExportNotificationDelegate.swift + `ExportNotifier.post` (UserNotifications on the Mac)
//! Notifications on Windows: a tray balloon (`Shell_NotifyIconW` with `NIF_INFO`), which Windows 10/11 shows as a toast.
//!
//! The fallback of the WinRT toast (`toast.rs`): a balloon needs no app id, but a click on it does not reach the app.

use std::time::Duration;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::System::Threading::GetCurrentProcessId;
use windows_sys::Win32::UI::Shell::{
    NIF_ICON, NIF_INFO, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW, Shell_NotifyIconW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GCLP_HICON, GetClassLongPtrW, GetForegroundWindow, GetWindowThreadProcessId, IDI_APPLICATION, LoadIconW,
};
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::Window;

/// How long the tray icon that carries the balloon stays.
const ICON_LIFE: Duration = Duration::from_secs(12);

/// A balloon over the window's tray icon.
pub struct BalloonNotifier {
    hwnd: isize,
    next_id: u32,
}

fn wide<const N: usize>(text: &str) -> [u16; N] {
    let mut out = [0u16; N];
    for (slot, unit) in out.iter_mut().zip(text.encode_utf16().take(N - 1)) {
        *slot = unit;
    }
    out
}

impl BalloonNotifier {
    pub fn new(window: &Window) -> BalloonNotifier {
        let hwnd = match window.window_handle().map(|h| h.as_raw()) {
            Ok(RawWindowHandle::Win32(h)) => h.hwnd.get(),
            _ => 0,
        };
        BalloonNotifier { hwnd, next_id: 0x5100 }
    }

    /// Shows `title` / `body`; the tray icon is removed again after a while.
    pub fn post(&mut self, title: &str, body: &str) {
        if self.hwnd == 0 {
            return;
        }
        self.next_id += 1;
        let hwnd = self.hwnd as HWND;
        // SAFETY: NOTIFYICONDATAW is plain data, all-zero is a valid empty value; the calls take it by pointer for their
        // duration only. The icon handle is the window class icon or the stock application icon (never destroyed here).
        let mut data: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
        data.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        data.hWnd = hwnd;
        data.uID = self.next_id;
        data.uFlags = NIF_ICON | NIF_TIP | NIF_INFO;
        data.hIcon = unsafe {
            let class_icon = GetClassLongPtrW(hwnd, GCLP_HICON) as windows_sys::Win32::UI::WindowsAndMessaging::HICON;
            if class_icon.is_null() { LoadIconW(std::ptr::null_mut(), IDI_APPLICATION) } else { class_icon }
        };
        data.szTip = wide("Sequence Studio");
        data.szInfoTitle = wide(title);
        data.szInfo = wide(body);
        data.dwInfoFlags = NIIF_INFO;
        // SAFETY: see above.
        if unsafe { Shell_NotifyIconW(NIM_ADD, &data) } == 0 {
            return;
        }
        let (hwnd, id) = (self.hwnd, self.next_id);
        let _ = std::thread::Builder::new().name("sq-balloon".into()).spawn(move || {
            std::thread::sleep(ICON_LIFE);
            // SAFETY: a delete names the icon by window and id only.
            let mut gone: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
            gone.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
            gone.hWnd = hwnd as HWND;
            gone.uID = id;
            unsafe { Shell_NotifyIconW(NIM_DELETE, &gone) };
        });
    }
}

/// Whether the window in front belongs to this process (Swift `NSApp.isActive`).
pub fn app_is_active() -> bool {
    // SAFETY: plain queries; a null foreground window (none) is checked.
    unsafe {
        let front = GetForegroundWindow();
        if front.is_null() {
            return false;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(front, &mut pid);
        pid == GetCurrentProcessId()
    }
}
