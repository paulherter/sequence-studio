//! The layout the user types with now (`GetKeyboardLayout`, `ToUnicodeEx`; Swift's `currentLayout` was Mac only).

use sq_os::keyboard::{ActiveKeyboard, KeyProbe, normalize_layout_id};
use std::sync::{Arc, Mutex};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetKeyboardLayout, MapVirtualKeyExW, ToUnicodeEx};

/// The scan code of the key at a US (ANSI) position; `<` is the ISO key left of Z.
fn scan_code(position: char) -> Option<u32> {
    const ROW1: &str = "1234567890-=";
    const ROW2: &str = "qwertyuiop[]";
    const ROW3: &str = "asdfghjkl;'`";
    const ROW4: &str = "zxcvbnm,./";
    let at = |row: &str, base: u32| row.chars().position(|c| c == position).map(|i| base + i as u32);
    match position {
        '\\' => Some(0x2b),
        '<' => Some(0x56),
        _ => at(ROW1, 0x02).or_else(|| at(ROW2, 0x10)).or_else(|| at(ROW3, 0x1e)).or_else(|| at(ROW4, 0x2c)),
    }
}

/// The language id of a keyboard layout handle as a layout id (`"de"`, `"fr"`, `"us"`), else its four hex digits.
fn layout_id(langid: u16) -> String {
    match langid & 0x3ff {
        0x07 => "de".to_string(),
        0x0c => "fr".to_string(),
        0x09 if langid != 0x0809 => "us".to_string(),
        _ => normalize_layout_id(&format!("{langid:04x}")),
    }
}

/// [`active_keyboard`] kept for the layout handle: the layout changes rarely and shortcut labels ask on every frame.
/// `positions` is built only when the layout changed.
pub fn cached_active_keyboard(positions: impl FnOnce() -> Vec<char>) -> Option<Arc<ActiveKeyboard>> {
    static CACHE: Mutex<Option<(usize, Arc<ActiveKeyboard>)>> = Mutex::new(None);
    // SAFETY: a plain Win32 query without arguments that need care.
    let hkl = unsafe { GetKeyboardLayout(0) } as usize;
    let mut cache = CACHE.lock().ok()?;
    if let Some((handle, kb)) = cache.as_ref()
        && *handle == hkl
    {
        return Some(Arc::clone(kb));
    }
    let kb = Arc::new(active_keyboard(&positions())?);
    *cache = Some((hkl, Arc::clone(&kb)));
    Some(kb)
}

/// The active layout of the calling thread (call it from the UI thread) with what each key types.
pub fn active_keyboard(positions: &[char]) -> Option<ActiveKeyboard> {
    // SAFETY: plain Win32 queries; the buffers are local and sized as documented.
    unsafe {
        let hkl = GetKeyboardLayout(0);
        if hkl.is_null() {
            return None;
        }
        let langid = (hkl as usize & 0xffff) as u16;
        let mut probes = Vec::new();
        for &position in positions {
            let Some(sc) = scan_code(position) else { continue };
            let vk = MapVirtualKeyExW(sc, 3, hkl); // MAPVK_VSC_TO_VK_EX
            if vk == 0 {
                continue;
            }
            let mut typed = [None, None];
            for (i, shift) in [false, true].into_iter().enumerate() {
                let mut state = [0_u8; 256];
                if shift {
                    state[0x10] = 0x80; // VK_SHIFT
                }
                let mut buf = [0_u16; 4];
                // Flag 4: leave the keyboard's dead-key state alone.
                let n = ToUnicodeEx(vk, sc, state.as_ptr(), buf.as_mut_ptr(), buf.len() as i32, 4, hkl);
                if n == 1 {
                    typed[i] = char::from_u32(u32::from(buf[0]));
                }
            }
            probes.push(KeyProbe { position, plain: typed[0], shifted: typed[1] });
        }
        Some(ActiveKeyboard { layout_id: layout_id(langid), probes })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_codes_follow_the_ansi_rows() {
        assert_eq!(scan_code('q'), Some(0x10));
        assert_eq!(scan_code('a'), Some(0x1e));
        assert_eq!(scan_code('z'), Some(0x2c));
        assert_eq!(scan_code('1'), Some(0x02));
        assert_eq!(scan_code('='), Some(0x0d));
        assert_eq!(scan_code('/'), Some(0x35));
        assert_eq!(scan_code('<'), Some(0x56));
        assert_eq!(scan_code('é'), None);
    }

    #[test]
    fn language_ids_become_layout_ids() {
        assert_eq!(layout_id(0x0407), "de");
        assert_eq!(layout_id(0x0c07), "de");
        assert_eq!(layout_id(0x040c), "fr");
        assert_eq!(layout_id(0x0409), "us");
    }
}
