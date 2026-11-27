//! What the clipboard offers, without opening it: the sequence number and the formats on offer.

use windows_sys::Win32::System::DataExchange::{
    GetClipboardSequenceNumber, IsClipboardFormatAvailable, RegisterClipboardFormatW,
};
use windows_sys::Win32::System::Ole::{CF_DIB, CF_DIBV5, CF_HDROP};

/// The clipboard's sequence number and whether it offers files and/or a picture.
pub fn clipboard_facts() -> Option<(u64, bool, bool)> {
    let png_name: Vec<u16> = "PNG\0".encode_utf16().collect();
    // SAFETY: the three calls take plain values and a NUL-terminated UTF-16 name that outlives the call; none of them
    // opens the clipboard or touches its data.
    unsafe {
        let seq = GetClipboardSequenceNumber();
        let files = IsClipboardFormatAvailable(u32::from(CF_HDROP)) != 0;
        let png = RegisterClipboardFormatW(png_name.as_ptr());
        let image = IsClipboardFormatAvailable(u32::from(CF_DIB)) != 0
            || IsClipboardFormatAvailable(u32::from(CF_DIBV5)) != 0
            || (png != 0 && IsClipboardFormatAvailable(png) != 0);
        Some((u64::from(seq), files, image))
    }
}
