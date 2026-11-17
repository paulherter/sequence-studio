//! The layout the Mac types with now (Text Input Sources and `UCKeyTranslate`, like Swift's `currentLayout`).

use sq_os::keyboard::{ActiveKeyboard, KeyProbe, normalize_layout_id};
use std::ffi::{CStr, c_char, c_void};

#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" {
    static kTISPropertyUnicodeKeyLayoutData: *const c_void;
    static kTISPropertyInputSourceID: *const c_void;
    fn TISCopyCurrentKeyboardLayoutInputSource() -> *const c_void;
    fn TISGetInputSourceProperty(source: *const c_void, key: *const c_void) -> *const c_void;
    fn UCKeyTranslate(
        layout: *const c_void,
        key_code: u16,
        key_action: u16,
        modifier_state: u32,
        keyboard_type: u32,
        options: u32,
        dead_key_state: *mut u32,
        max_len: usize,
        actual_len: *mut usize,
        chars: *mut u16,
    ) -> i32;
    fn LMGetKbdType() -> u8;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFDataGetBytePtr(data: *const c_void) -> *const u8;
    fn CFStringGetCString(s: *const c_void, buf: *mut c_char, size: isize, encoding: u32) -> u8;
    fn CFRelease(o: *const c_void);
}

const UTF8: u32 = 0x0800_0100;

/// The active keyboard layout with what each key code types. `positions` are the `(key code, US position)` pairs of
/// the shortcut map's character keys.
pub fn active_keyboard(positions: &[(u16, char)]) -> Option<ActiveKeyboard> {
    // SAFETY: Text Input Sources calls follow the Create/Get rules: the copied source is released at the end, the layout
    // data and the id string are owned by it and only read while it lives.
    unsafe {
        let source = TISCopyCurrentKeyboardLayoutInputSource();
        if source.is_null() {
            return None;
        }
        let mut id = String::new();
        let id_ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
        if !id_ref.is_null() {
            let mut buf = [0 as c_char; 256];
            if CFStringGetCString(id_ref, buf.as_mut_ptr(), 256, UTF8) != 0 {
                id = CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned();
            }
        }
        let mut probes = Vec::new();
        let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
        let layout = if data.is_null() { std::ptr::null() } else { CFDataGetBytePtr(data) };
        if !layout.is_null() {
            let kbd_type = u32::from(LMGetKbdType());
            for &(code, position) in positions {
                let mut typed = [None, None];
                for (i, shift) in [false, true].into_iter().enumerate() {
                    let mut dead = 0_u32;
                    let mut len = 0_usize;
                    let mut chars = [0_u16; 4];
                    let modifiers = if shift { 2 } else { 0 }; // (shiftKey >> 8) & 0xFF
                    let status = UCKeyTranslate(
                        layout.cast(),
                        code,
                        0, // kUCKeyActionDown
                        modifiers,
                        kbd_type,
                        1, // kUCKeyTranslateNoDeadKeysMask
                        &raw mut dead,
                        chars.len(),
                        &raw mut len,
                        chars.as_mut_ptr(),
                    );
                    if status == 0 && len == 1 {
                        typed[i] = char::from_u32(u32::from(chars[0]));
                    }
                }
                probes.push(KeyProbe { position, plain: typed[0], shifted: typed[1] });
            }
        }
        CFRelease(source);
        Some(ActiveKeyboard { layout_id: normalize_layout_id(&id), probes })
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_active_layout_has_an_id_and_types_letters() {
        let Some(k) = super::active_keyboard(&[(0, 'a')]) else { return };
        assert!(!k.layout_id.is_empty() || k.probes.is_empty());
        if let Some(p) = k.probes.first() {
            assert!(p.plain.is_some());
        }
    }
}
