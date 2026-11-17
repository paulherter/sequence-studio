// SPDX-License-Identifier: GPL-3.0-or-later
//! Building blocks of a native fault report that need no allocation, no locks and no formatting machinery, so they are
//! safe to call inside a Windows exception filter or a Unix signal handler. The report layout matches
//! `crates/sequence-studio/src/crash.rs`; `sq-platform-win` and `sq-platform-mac` do the system calls.

/// What the installed handler needs, prepared before any fault (the handler itself may not allocate).
#[derive(Clone, Debug)]
pub struct FaultConfig {
    /// The `Crashes/` folder; the reports are `crash-<stamp>.txt` in it.
    pub crashes_dir: std::path::PathBuf,
    /// The app log (`sq.log`); its tail becomes the "Last log lines" part.
    pub log_file: std::path::PathBuf,
    /// `AppVersion::full_name()`.
    pub app: String,
    /// `macos aarch64` style system line.
    pub system: String,
    /// Home folders replaced by `~` in the log lines.
    pub homes: Vec<String>,
}

/// A fixed-size byte buffer that only appends and silently drops what does not fit.
pub struct Buf<'a> {
    data: &'a mut [u8],
    len: usize,
}

impl<'a> Buf<'a> {
    pub fn new(data: &'a mut [u8]) -> Buf<'a> {
        Buf { data, len: 0 }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.data[..self.len]
    }

    pub fn str(&mut self, text: &str) -> &mut Self {
        self.raw(text.as_bytes())
    }

    pub fn raw(&mut self, bytes: &[u8]) -> &mut Self {
        let n = bytes.len().min(self.data.len() - self.len);
        self.data[self.len..self.len + n].copy_from_slice(&bytes[..n]);
        self.len += n;
        self
    }

    /// Decimal, zero-padded to `width` digits.
    pub fn dec(&mut self, value: u64, width: usize) -> &mut Self {
        let mut digits = [b'0'; 20];
        let (mut v, mut i) = (value, digits.len());
        while v > 0 {
            i -= 1;
            digits[i] = b'0' + (v % 10) as u8;
            v /= 10;
        }
        let start = i.min(digits.len().saturating_sub(width.clamp(1, 20)));
        self.raw(&digits[start..])
    }

    /// `0x` and lowercase hex without leading zeros.
    pub fn hex(&mut self, value: u64) -> &mut Self {
        self.str("0x");
        let mut started = false;
        for shift in (0..16).rev() {
            let nibble = ((value >> (shift * 4)) & 0xf) as u8;
            if nibble != 0 || started || shift == 0 {
                started = true;
                self.raw(&[b"0123456789abcdef"[nibble as usize]]);
            }
        }
        self
    }

    /// Appends `bytes` with every `home` replaced by `~` and control bytes (except newline) by a space.
    pub fn redacted(&mut self, bytes: &[u8], home: &[u8]) -> &mut Self {
        let mut i = 0;
        while i < bytes.len() {
            if home.len() > 1 && bytes[i..].starts_with(home) {
                self.str("~");
                i += home.len();
                continue;
            }
            let b = bytes[i];
            self.raw(&[if b < b' ' && b != b'\n' { b' ' } else { b }]);
            i += 1;
        }
        self
    }
}

/// `YYYYMMDD-HHMMSS-mmm`, the stamp in `crash-<stamp>.txt` (same as the store's `file_stamp`).
pub fn stamp(unix_ms: u64, out: &mut Buf<'_>) {
    let (days, ms) = (unix_ms / 86_400_000, unix_ms % 86_400_000);
    let (y, m, d) = civil(days as i64);
    out.dec(y as u64, 4).dec(m as u64, 2).dec(d as u64, 2).str("-");
    out.dec(ms / 3_600_000, 2).dec(ms / 60_000 % 60, 2).dec(ms / 1000 % 60, 2).str("-").dec(ms % 1000, 3);
}

/// `2026-11-08T12:30:00Z`, the `created:` line.
pub fn iso(unix_ms: u64, out: &mut Buf<'_>) {
    let (days, ms) = (unix_ms / 86_400_000, unix_ms % 86_400_000);
    let (y, m, d) = civil(days as i64);
    out.dec(y as u64, 4).str("-").dec(m as u64, 2).str("-").dec(d as u64, 2).str("T");
    out.dec(ms / 3_600_000, 2).str(":").dec(ms / 60_000 % 60, 2).str(":").dec(ms / 1000 % 60, 2).str("Z");
}

fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

/// The part of a log file tail that starts at a whole line (drops the cut first line when the tail did not start at 0).
pub fn whole_lines(tail: &[u8], from_start: bool) -> &[u8] {
    if from_start {
        return tail;
    }
    match tail.iter().position(|&b| b == b'\n') {
        Some(i) => &tail[i + 1..],
        None => &[],
    }
}

/// The head of every report: title, time, app, system. `app` and `system` are prepared at install.
pub fn header(out: &mut Buf<'_>, unix_ms: u64, app: &str, system: &str) {
    out.str("Sequence Studio crash report\ncreated: ");
    iso(unix_ms, out);
    out.str("\napp: ").str(app).str("\nsystem: ").str(system).str("\n");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(f: impl FnOnce(&mut Buf<'_>)) -> String {
        let mut raw = [0u8; 256];
        let mut b = Buf::new(&mut raw);
        f(&mut b);
        String::from_utf8_lossy(b.bytes()).into_owned()
    }

    #[test]
    fn stamp_and_iso_match_the_store_format() {
        // 2025-11-08 00:40:00.123 UTC
        let ms = 1_762_562_400_123;
        assert_eq!(text(|b| stamp(ms, b)), "20251108-004000-123");
        assert_eq!(text(|b| iso(ms, b)), "2025-11-08T00:40:00Z");
        assert_eq!(text(|b| stamp(0, b)), "19700101-000000-000");
    }

    #[test]
    fn numbers() {
        assert_eq!(text(|b| _ = b.hex(0xc000_0005)), "0xc0000005");
        assert_eq!(text(|b| _ = b.hex(0)), "0x0");
        assert_eq!(text(|b| _ = b.dec(0, 1)), "0");
        assert_eq!(text(|b| _ = b.dec(7, 3)), "007");
    }

    #[test]
    fn overflow_is_cut_not_a_panic() {
        let mut raw = [0u8; 4];
        let mut b = Buf::new(&mut raw);
        b.str("abcdefgh").hex(1);
        assert_eq!(b.bytes(), b"abcd");
    }

    #[test]
    fn home_is_redacted() {
        assert_eq!(text(|b| _ = b.redacted(b"open /Users/zoe/a.mov\x01x", b"/Users/zoe")), "open ~/a.mov x");
    }

    #[test]
    fn a_cut_first_line_is_dropped() {
        assert_eq!(whole_lines(b"rt line\nnext\n", false), b"next\n");
        assert_eq!(whole_lines(b"first\nnext\n", true), b"first\nnext\n");
    }
}
