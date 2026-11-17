//! The user's interface language (`GetUserDefaultLocaleName`), for the app's language choice at launch.

use windows_sys::Win32::Globalization::GetUserDefaultLocaleName;

/// Locale names in order of preference, e.g. `["de-DE"]`; empty when the system does not say.
pub fn preferred_languages() -> Vec<String> {
    let mut buf = [0_u16; 85]; // LOCALE_NAME_MAX_LENGTH
    // SAFETY: `buf` is a writable buffer of the length passed; the call writes a NUL-terminated name into it.
    let n = unsafe { GetUserDefaultLocaleName(buf.as_mut_ptr(), buf.len() as i32) };
    if n <= 1 {
        return Vec::new();
    }
    vec![String::from_utf16_lossy(&buf[..(n as usize - 1)])]
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_locale_name_has_a_language_part() {
        let l = super::preferred_languages();
        assert!(l.is_empty() || l[0].len() >= 2);
    }
}
