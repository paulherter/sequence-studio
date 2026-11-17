// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: LZFSE.swift
//! LZFSE decoding (Apple's BSD-3 reference decoder, vendored as C and built by `build.rs`; docs/THIRD_PARTY.md).
//! The Mac Magic Mask cache stores its 8-bit frames LZFSE-compressed; Windows reads them through this.

/// The only unsafe code of the crate: the call into the C decoder.
#[allow(unsafe_code, reason = "FFI to the vendored LZFSE decoder")]
mod ffi {
    use std::ffi::c_void;

    unsafe extern "C" {
        fn lzfse_decode_buffer(
            dst: *mut u8,
            dst_size: usize,
            src: *const u8,
            src_size: usize,
            scratch: *mut c_void,
        ) -> usize;
    }

    /// Decodes `src` into `dst`; returns the bytes written (`dst.len()` also for a longer stream).
    pub(super) fn decode_buffer(dst: &mut [u8], src: &[u8]) -> usize {
        // SAFETY: both pointers come from live slices and the lengths passed are exactly theirs; the decoder writes at most
        // `dst.len()` bytes and reads at most `src.len()`; a null scratch makes it allocate its own.
        unsafe { lzfse_decode_buffer(dst.as_mut_ptr(), dst.len(), src.as_ptr(), src.len(), std::ptr::null_mut()) }
    }
}

/// LZFSE decoding that works on every platform.
pub struct Lzfse;

impl Lzfse {
    /// The `size` bytes `data` decodes to, or `None` when it is damaged or decodes to another length.
    pub fn decode(data: &[u8], size: usize) -> Option<Vec<u8>> {
        if size == 0 || data.is_empty() {
            return None;
        }
        let mut out = vec![0_u8; size];
        let written = ffi::decode_buffer(&mut out, data);
        // A full buffer is also what a longer stream returns, so only an exact fit counts.
        (written == size).then_some(out)
    }
}

/// Fixtures written by Apple's `NSData.compressed(using: .lzfse)` (what the Mac matte store does): a 24 x 24 disc (LZVN
/// block, `bvxn`) and an 80 x 80 disc (LZFSE block with FSE tables, `bvx2`).
#[cfg(test)]
pub(crate) mod mac_matte_fixture {
    use sq_core_time::base64;

    pub(crate) fn disc(w: usize, h: usize) -> Vec<u8> {
        let mut b = vec![0_u8; w * h];
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 - w as f64 / 2.0;
                let dy = y as f64 - h as f64 / 2.0;
                let d = (dx * dx + dy * dy).sqrt();
                let r = w as f64 / 3.0;
                b[y * w + x] = ((r - d) * 40.0).clamp(0.0, 255.0) as u8;
            }
        }
        b
    }

    pub(crate) fn small() -> Vec<u8> {
        base64::decode("YnZ4bkACAACrAAAAaAEA8GjoDxwlKCUcDwD69OwHHzNDTFBMQzMfBwD68ewHJT9WaHR4dGhWPyU4GfLuHz9deI2boJuNeF0/HwD57g8zVniWr8HIwa+WeFYzOGTgABxDaI2vzubw5s6vjWhDHAAoAeAAJUx0m8Hm////5sGbdEwlAPjmKFB4oMjwABjm8MigeFAo+Tgw/jhg/jiQ/jjA/jjw/zkg/jlQ/zgB8D7hAAYAAAAAAAAAYnZ4JA==").unwrap_or_default()
    }

    pub(crate) fn large() -> Vec<u8> {
        base64::decode("YnZ4MgAZAADgAQAYAFcAUCDQkEQY0wBg0AAAAB38QARfgMDac6sBMQjgQARkfAHXvgavAQAAADCBckrvOu8u5sXFRS+OLi4KAAAAAAC8A5MJTOYJcMARHAFnHBxxBsABcAAHBxzwAjAALi7gggvg8uLiHgAu4OLiErgALoALLi4ALi4v4JLrCcAFXMIFcAEXwMUFlxdwwQXAJZcTgIuLS4ALBlzAJcAlAJdwwQWXk4tL4AIAuOCCCy7g4gLggqsLuIOrCXABEwC4nEyACfAIAAAAqlqz2bjAHgTrO/rQXxZoeYfdfYDbgLzi0/jI/gqPmiePxm8F5Mn6d2zxUnQJ+T1Pr2TcXGd4gUF4vai196FUImcHud5XNvN2yoRa2zXhGi95yrrUxShPCpnBU8JGLPcO3ujdUIWbdNnkGNiYynRaTVXN8WPVD1Ek70vmIK4wUKKJZ5jjeF0QXDEXzy3TGzf0yHRq7OHJCwcc4n9T9F2++Bq/TnPyKkSA/Kl69b6iPjSqzsz2uX0FvhExypUjwQpQjeyKCOjedRxUoLhoJQBthi6c9DkVp/0wevTnZyScQ0qG4DxU3lYnIz7psBpjZWggy40sBgtYXsI5Mh1ZZMvfLnTiubI6wdSPojdNHOv5i4BeOyai2TOcFIeBV400OEEoBSgw535FyuKa93aPmyWGFvGGc8BLKr0Jm+zz2u5gJXbjROdBC0cwUPfO4V80m+pmeBEl8YRDQLlhJ2aEfDJW9ohjDu2S6vADz2KAR5MfODVe0D+nPK4vWUPAqj2wLwAAAAAAAAAAAJBWQCIGip+Q/hoTpBXPKiOjMyJuM0IyZohQzAj5mBGiIiOkREYICIyQFRkhxjFCYmeEcIsR8pkRoocR0ocRAoMRMpMRYo8RksQIoTFCljBCRDBCfoyYGOlBsSADiAXvHpIkXChqrOx60gc54SPSjw+pmeB0tx5nRy01dPfZMJ8fEXoKY5oMLGw4/qDuQvQo6DA7j4FzHfWYYokwfWcTuUPMItjZtOjnBW43XtIEF49wVDdRptpM+8Rnugn/Jj8NfDz+CIh+BLpKg3didngk").unwrap_or_default()
    }

    /// A Mac `.sqmatte` file (SQMT, version 2) with the given stored frames (pts, width, height, stored bytes).
    pub(crate) fn file(frames: &[(f64, u32, u32, Vec<u8>)]) -> Vec<u8> {
        let mut out = b"SQMT".to_vec();
        out.extend(2_u32.to_le_bytes());
        out.extend((frames.len() as u32).to_le_bytes());
        for (pts, w, h, stored) in frames {
            out.extend(pts.to_le_bytes());
            out.extend(w.to_le_bytes());
            out.extend(h.to_le_bytes());
            out.extend((stored.len() as u32).to_le_bytes());
            out.extend(stored);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::mac_matte_fixture as fx;
    use super::*;

    #[test]
    fn decodes_an_lzvn_block_written_on_the_mac() {
        assert_eq!(Lzfse::decode(&fx::small(), 24 * 24), Some(fx::disc(24, 24)));
    }

    #[test]
    fn decodes_an_lzfse_block_with_fse_tables_written_on_the_mac() {
        assert_eq!(Lzfse::decode(&fx::large(), 80 * 80), Some(fx::disc(80, 80)));
    }

    #[test]
    fn damaged_or_wrong_sized_data_is_refused() {
        let large = fx::large();
        assert_eq!(Lzfse::decode(&large, 80 * 80 + 1), None);
        assert_eq!(Lzfse::decode(&large[..100], 80 * 80), None);
        assert_eq!(Lzfse::decode(&[], 4), None);
        assert_eq!(Lzfse::decode(&[1, 2, 3, 4, 5], 16), None);
    }
}
