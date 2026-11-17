//! Native faults (access violation, stack overflow, illegal instruction, ...) write a crash report before the process
//! dies: an unhandled-exception filter that uses only prepared buffers and Win32 file calls, no allocation.
//!
//! A stack overflow needs stack to report on: `SetThreadStackGuarantee` keeps 64 KB in reserve on the installing
//! thread (the main thread). Other threads get the reserve of the Rust runtime. After the report the filter returns
//! `EXCEPTION_CONTINUE_SEARCH`, so the system's own handling and the exit code stay.
//!
//! An `abort()` of the C runtime (ffmpeg, ONNX Runtime and other C code) raises `SIGABRT` and skips the filter: a
//! `signal(SIGABRT)` handler writes the same report ("fault: abort"), then returns so the runtime ends the process, the
//! counterpart of the Mac's `SIGABRT` handler. A Rust `process::abort` is a `__fastfail`, which no handler can see;
//! shortcut: that one leaves no report here, upgrade by routing our own abort calls through a function that reports first.
//! A panic never gets that far: the panic hook (sequence-studio `crash.rs`) writes its report before any abort.

use sq_fault_text::{Buf, FaultConfig};
use std::os::windows::ffi::OsStrExt;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use windows_sys::Win32::Foundation::{CloseHandle, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::{
    CREATE_ALWAYS, CreateFileW, FILE_BEGIN, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, GetFileSizeEx,
    OPEN_EXISTING, ReadFile, SetFilePointerEx, WriteFile,
};
use windows_sys::Win32::System::Diagnostics::Debug::{EXCEPTION_POINTERS, SetUnhandledExceptionFilter};
use windows_sys::Win32::System::LibraryLoader::{
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, GetModuleFileNameW,
    GetModuleHandleExW,
};
use windows_sys::Win32::System::SystemInformation::GetSystemTimeAsFileTime;
use windows_sys::Win32::System::Threading::SetThreadStackGuarantee;

const REPORT_BYTES: usize = 48 * 1024;
const LOG_BYTES: usize = 16 * 1024;
const EXCEPTION_CONTINUE_SEARCH: i32 = 0;

struct Prepared {
    /// `<Crashes>\crash-` as UTF-16; the filter appends stamp and `.txt`.
    prefix: Vec<u16>,
    log: Vec<u16>,
    app: String,
    system: String,
    home: Vec<u8>,
    /// Report area followed by log scratch; leaked, written by the first fault only.
    scratch: usize,
}

static PREPARED: OnceLock<Prepared> = OnceLock::new();
static ENTERED: AtomicBool = AtomicBool::new(false);

fn wide(text: &std::path::Path) -> Vec<u16> {
    text.as_os_str().encode_wide().collect()
}

/// Installs the filter and the stack reserve for the calling thread (call on the main thread, early). A second call
/// does nothing.
pub fn install_fault_report(config: &FaultConfig) {
    let _ = std::fs::create_dir_all(&config.crashes_dir);
    let mut prefix = wide(&config.crashes_dir);
    prefix.extend("\\crash-".encode_utf16());
    let mut log = wide(&config.log_file);
    log.push(0);
    let scratch: &'static mut [u8] = Box::leak(vec![0u8; REPORT_BYTES + LOG_BYTES].into_boxed_slice());
    let prepared = Prepared {
        prefix,
        log,
        app: config.app.clone(),
        system: config.system.clone(),
        home: config.homes.iter().find(|h| h.len() > 1).cloned().unwrap_or_default().into_bytes(),
        scratch: scratch.as_mut_ptr() as usize,
    };
    if PREPARED.set(prepared).is_err() {
        return;
    }
    // SAFETY: both calls only read their arguments; the filter is a plain function that outlives the process.
    unsafe {
        let mut reserve: u32 = 64 * 1024;
        SetThreadStackGuarantee(&mut reserve);
        SetUnhandledExceptionFilter(Some(filter));
        signal(SIGABRT, on_abort as *const () as usize);
    }
}

fn describe(code: u32) -> &'static str {
    match code {
        0xC000_0005 => "access violation",
        0xC000_00FD => "stack overflow",
        0xC000_001D => "illegal instruction",
        0xC000_0094 => "integer divide by zero",
        0xC000_0096 => "privileged instruction",
        0xC000_0409 => "stack buffer overrun",
        0xC000_0374 => "heap corruption",
        0x8000_0003 => "breakpoint",
        _ => "exception",
    }
}

/// The unhandled-exception filter.
///
/// # Safety
/// Called by the system with a valid `EXCEPTION_POINTERS`, or null.
unsafe extern "system" fn filter(pointers: *const EXCEPTION_POINTERS) -> i32 {
    if pointers.is_null() {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    // SAFETY: the exception record is valid for the duration of the filter.
    unsafe {
        let record = (*pointers).ExceptionRecord;
        if record.is_null() {
            return EXCEPTION_CONTINUE_SEARCH;
        }
        let code = (*record).ExceptionCode as u32;
        let access = (code == 0xC000_0005 && (*record).NumberParameters >= 2)
            .then(|| ((*record).ExceptionInformation[0], (*record).ExceptionInformation[1] as u64));
        write_fault(code, (*record).ExceptionAddress as usize as u64, access);
    }
    EXCEPTION_CONTINUE_SEARCH
}

/// The CRT `SIGABRT` number.
const SIGABRT: i32 = 22;

unsafe extern "C" {
    /// C runtime `signal`; the handler is passed and returned as an address.
    fn signal(sig: i32, handler: usize) -> usize;
}

/// `abort()` of C code: the same report, no exception record. The runtime ends the process when this returns.
extern "C" fn on_abort(_sig: i32) {
    // SAFETY: only prepared buffers and Win32 file calls, like the filter.
    unsafe { write_fault(ABORT_CODE, 0, None) };
}

/// Marks the abort report: not an NT status, `describe` and the header line say "abort".
const ABORT_CODE: u32 = 0;

/// Writes one report for a fault (the first one only).
///
/// # Safety
/// `PREPARED` buffers are used by this one fault; Win32 calls only, no allocation.
unsafe fn write_fault(code: u32, address: u64, access: Option<(usize, u64)>) {
    let Some(p) = PREPARED.get() else { return };
    if ENTERED.swap(true, Ordering::SeqCst) {
        return;
    }
    // SAFETY: Win32 calls on prepared buffers; `scratch` is the leaked buffer, used by this one fault.
    unsafe {
        let mem = std::slice::from_raw_parts_mut(p.scratch as *mut u8, REPORT_BYTES + LOG_BYTES);
        let (report_mem, log_mem) = mem.split_at_mut(REPORT_BYTES);
        let (mut ft, ms) = (std::mem::zeroed(), 0u64);
        GetSystemTimeAsFileTime(&mut ft);
        let ticks = (u64::from(ft.dwHighDateTime) << 32) | u64::from(ft.dwLowDateTime);
        let ms = ms + ticks.saturating_sub(116_444_736_000_000_000) / 10_000;

        let mut out = Buf::new(report_mem);
        sq_fault_text::header(&mut out, ms, &p.app, &p.system);
        if code == ABORT_CODE {
            out.str("fault: abort (SIGABRT)\n");
        } else {
            out.str("fault: ").str(describe(code)).str(" (").hex(u64::from(code)).str(")\n");
        }
        if let Some((kind, target)) = access {
            let kind = match kind {
                0 => "reading",
                1 => "writing",
                _ => "executing",
            };
            out.str("access: ").str(kind).str(" address ").hex(target).str("\n");
        }
        if code != ABORT_CODE {
            out.str("address: ").hex(address).str("\n");
            module_line(&mut out, address);
        }
        out.str("\nLast log lines\n");
        let tail = read_tail(&p.log, log_mem);
        out.redacted(tail, &p.home);

        let mut path = [0u16; 600];
        let len = p.prefix.len().min(500);
        path[..len].copy_from_slice(&p.prefix[..len]);
        let mut stamp_raw = [0u8; 40];
        let mut stamp = Buf::new(&mut stamp_raw);
        sq_fault_text::stamp(ms, &mut stamp);
        stamp.str(".txt");
        for (slot, &b) in path[len..].iter_mut().zip(stamp.bytes()) {
            *slot = u16::from(b);
        }
        let file = CreateFileW(
            path.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_READ,
            std::ptr::null(),
            CREATE_ALWAYS,
            0,
            std::ptr::null_mut(),
        );
        if file != INVALID_HANDLE_VALUE {
            let bytes = out.bytes();
            let mut written = 0u32;
            WriteFile(file, bytes.as_ptr(), bytes.len() as u32, &mut written, std::ptr::null_mut());
            CloseHandle(file);
        }
    }
}

/// `module: name.exe + 0xoffset`, from the module that holds `address`.
///
/// # Safety
/// Win32 calls with local buffers only.
unsafe fn module_line(out: &mut Buf<'_>, address: u64) {
    unsafe {
        let mut module = std::ptr::null_mut();
        let flags = GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
        if GetModuleHandleExW(flags, address as usize as *const u16, &mut module) == 0 || module.is_null() {
            return;
        }
        let mut name = [0u16; 520];
        let n = GetModuleFileNameW(module, name.as_mut_ptr(), name.len() as u32) as usize;
        let base = name[..n.min(name.len())].iter().rposition(|&c| c == u16::from(b'\\')).map_or(0, |i| i + 1);
        out.str("module: ");
        for &c in &name[base..n.min(name.len())] {
            out.raw(&[if (0x20..0x7f).contains(&c) { c as u8 } else { b'?' }]);
        }
        out.str(" + ").hex(address.wrapping_sub(module as usize as u64)).str("\n");
    }
}

/// The whole lines at the end of the log file, read into `scratch`.
///
/// # Safety
/// `log` is NUL-terminated UTF-16.
unsafe fn read_tail<'a>(log: &[u16], scratch: &'a mut [u8]) -> &'a [u8] {
    unsafe {
        let file = CreateFileW(
            log.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        );
        if file == INVALID_HANDLE_VALUE {
            return &[];
        }
        let mut size = 0i64;
        GetFileSizeEx(file, &mut size);
        let start = (size.max(0) as u64).saturating_sub(scratch.len() as u64);
        let mut read = 0u32;
        let ok = SetFilePointerEx(file, start as i64, std::ptr::null_mut(), FILE_BEGIN) != 0
            && ReadFile(file, scratch.as_mut_ptr(), scratch.len() as u32, &mut read, std::ptr::null_mut()) != 0;
        CloseHandle(file);
        if !ok || read == 0 {
            return &[];
        }
        sq_fault_text::whole_lines(&scratch[..read as usize], start == 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    const CHILD: &str = "SQ_FAULT_CHILD";

    /// Runs in a child process only: installs the filter and writes through a null pointer.
    #[test]
    fn child_faults_on_purpose() {
        let Ok(dir) = std::env::var(CHILD) else { return };
        let dir = std::path::PathBuf::from(dir);
        let log = dir.join("sq.log");
        let _ = std::fs::write(&log, "1 INFO start\r\n2 INFO opened C:\\Users\\zoe\\film.sqproj\r\n");
        install_fault_report(&FaultConfig {
            crashes_dir: dir.join("Crashes"),
            log_file: log,
            app: "Sequence Studio test".into(),
            system: "windows test".into(),
            homes: vec!["C:\\Users\\zoe".into()],
        });
        // SAFETY: deliberately invalid, to raise an access violation.
        unsafe { std::ptr::null_mut::<u8>().write_volatile(1) };
    }

    /// Runs in a child process only: installs the handlers and calls the C runtime's `abort`.
    #[test]
    fn child_aborts_on_purpose() {
        let Ok(dir) = std::env::var(CHILD) else { return };
        let dir = std::path::PathBuf::from(dir);
        let log = dir.join("sq.log");
        let _ = std::fs::write(&log, "1 INFO start\r\n");
        install_fault_report(&FaultConfig {
            crashes_dir: dir.join("Crashes"),
            log_file: log,
            app: "Sequence Studio test".into(),
            system: "windows test".into(),
            homes: Vec::new(),
        });
        unsafe extern "C" {
            fn abort() -> !;
        }
        // SAFETY: deliberately ends the process through the C runtime.
        unsafe { abort() }
    }

    #[test]
    fn a_c_abort_leaves_a_report() {
        if std::env::var(CHILD).is_ok() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-fault-win-abort-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let exe = std::env::current_exe().unwrap_or_default();
        let status = Command::new(exe)
            .args(["--exact", "fault::tests::child_aborts_on_purpose", "--nocapture", "--test-threads=1"])
            .env(CHILD, &dir)
            .status();
        assert!(status.is_ok_and(|s| !s.success()));
        let found = std::fs::read_dir(dir.join("Crashes")).map(|d| d.flatten().next()).unwrap_or(None);
        let text = found.and_then(|f| std::fs::read_to_string(f.path()).ok()).unwrap_or_default();
        assert!(text.contains("fault: abort (SIGABRT)"), "{text}");
        assert!(text.contains("1 INFO start"), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_access_violation_leaves_a_report() {
        if std::env::var(CHILD).is_ok() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-fault-win-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let exe = std::env::current_exe().unwrap_or_default();
        let status = Command::new(exe)
            .args(["--exact", "fault::tests::child_faults_on_purpose", "--nocapture", "--test-threads=1"])
            .env(CHILD, &dir)
            .status();
        assert!(status.is_ok_and(|s| !s.success()));
        let found = std::fs::read_dir(dir.join("Crashes")).map(|d| d.flatten().next()).unwrap_or(None);
        let text = found.and_then(|f| std::fs::read_to_string(f.path()).ok()).unwrap_or_default();
        assert!(text.starts_with("Sequence Studio crash report\ncreated: "), "{text}");
        assert!(text.contains("fault: access violation (0xc0000005)"), "{text}");
        assert!(text.contains("access: writing address 0x0"), "{text}");
        assert!(text.contains("module: "), "{text}");
        assert!(text.contains("app: Sequence Studio test"), "{text}");
        assert!(text.contains("2 INFO opened ~\\film.sqproj"), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
