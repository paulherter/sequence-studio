//! Export progress on the taskbar button (`ITaskbarList3`), the counterpart of the Mac Dock badge
//! (`sq-platform-mac/src/dock.rs`). windows-sys has no COM interfaces, so the two vtable slots used are declared here.

use std::ffi::c_void;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
};
use windows_sys::core::{GUID, HRESULT};
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::Window;

const CLSID_TASKBAR_LIST: GUID = GUID::from_u128(0x56fdf344_fd6d_11d0_958a_006097c9a090);
const IID_ITASKBAR_LIST3: GUID = GUID::from_u128(0xea1afb91_9e28_4b86_90e9_9e9f8a5eefaf);
const TBPF_NOPROGRESS: i32 = 0;
const TBPF_NORMAL: i32 = 2;
const TBPF_ERROR: i32 = 4;

/// `ITaskbarList3` up to `SetProgressState` (IUnknown 3, ITaskbarList 5, ITaskbarList2 1, then these).
#[repr(C)]
struct Vtbl {
    query_interface: usize,
    add_ref: usize,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    hr_init: unsafe extern "system" fn(*mut c_void) -> HRESULT,
    _tab_slots: [usize; 4],
    _mark_fullscreen: usize,
    set_progress_value: unsafe extern "system" fn(*mut c_void, HWND, u64, u64) -> HRESULT,
    set_progress_state: unsafe extern "system" fn(*mut c_void, HWND, i32) -> HRESULT,
}

/// The progress of one window's taskbar button. Main thread only.
pub struct TaskbarProgress {
    hwnd: HWND,
    list: *mut *const Vtbl,
}

impl TaskbarProgress {
    /// A no-op object when the window has no Win32 handle or the shell service is missing.
    pub fn new(window: &Window) -> TaskbarProgress {
        let hwnd = match window.window_handle().map(|h| h.as_raw()) {
            Ok(RawWindowHandle::Win32(h)) => h.hwnd.get() as HWND,
            _ => return TaskbarProgress { hwnd: std::ptr::null_mut(), list: std::ptr::null_mut() },
        };
        let mut list: *mut c_void = std::ptr::null_mut();
        // SAFETY: COM calls on the main thread; `list` receives an owned `ITaskbarList3` pointer or stays null, and
        // `HrInit` is the documented first call. S_FALSE / RPC_E_CHANGED_MODE from the init mean COM already runs.
        let ok = unsafe {
            CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED as u32);
            let hr = CoCreateInstance(
                &CLSID_TASKBAR_LIST,
                std::ptr::null_mut(),
                CLSCTX_INPROC_SERVER,
                &IID_ITASKBAR_LIST3,
                &mut list,
            );
            hr >= 0 && !list.is_null() && {
                let l = list as *mut *const Vtbl;
                ((**l).hr_init)(list) >= 0
            }
        };
        TaskbarProgress { hwnd, list: if ok { list as *mut *const Vtbl } else { std::ptr::null_mut() } }
    }

    /// The bar turns red at its current value (a failed job).
    pub fn set_error(&mut self) {
        if self.list.is_null() {
            return;
        }
        // SAFETY: `list` is the live interface from `new`, used on its own thread.
        unsafe {
            let v = &**self.list;
            (v.set_progress_state)(self.list.cast(), self.hwnd, TBPF_ERROR);
        }
    }

    /// `Some(0..=100)` shows the bar, `None` removes it.
    pub fn set(&mut self, percent: Option<u8>) {
        if self.list.is_null() {
            return;
        }
        // SAFETY: `list` is the live interface from `new`, used on its own thread.
        unsafe {
            let v = &**self.list;
            match percent {
                Some(p) => {
                    (v.set_progress_state)(self.list.cast(), self.hwnd, TBPF_NORMAL);
                    (v.set_progress_value)(self.list.cast(), self.hwnd, u64::from(p.min(100)), 100);
                }
                None => {
                    (v.set_progress_state)(self.list.cast(), self.hwnd, TBPF_NOPROGRESS);
                }
            }
        }
    }
}

impl Drop for TaskbarProgress {
    fn drop(&mut self) {
        if !self.list.is_null() {
            // SAFETY: releases the reference `CoCreateInstance` gave.
            unsafe { ((**self.list).release)(self.list.cast()) };
        }
    }
}
