//! Linux counterpart of `sq-platform-mac/src/fault.rs` (same report text, same async-signal-safe handler).
//!
//! Fatal signals (SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP) write a crash report before the process dies.
//!
//! The handler uses only async-signal-safe calls (`open`, `write`, `pread`, `close`, `clock_gettime`) and buffers
//! prepared at install. It runs on an alternate stack of the installing thread, so a stack overflow on that thread (the
//! main thread when installed there) is reported too; other threads run the handler on their own stack. After the
//! report the default action runs again (`SA_RESETHAND`), so the exit status and the system's own report stay.

use sq_fault_text::{Buf, FaultConfig};
use std::ffi::CString;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

const SIGNALS: [libc::c_int; 6] =
    [libc::SIGSEGV, libc::SIGBUS, libc::SIGILL, libc::SIGABRT, libc::SIGFPE, libc::SIGTRAP];
const REPORT_BYTES: usize = 48 * 1024;
const LOG_BYTES: usize = 16 * 1024;
const ALT_STACK: usize = 128 * 1024;

struct Prepared {
    /// `<Crashes>/crash-` without the stamp; the handler appends stamp and `.txt`.
    prefix: Vec<u8>,
    log: CString,
    app: String,
    system: String,
    home: Vec<u8>,
    /// Load address of the main program (PIE slide), read at install.
    slide: u64,
    /// Report area followed by log scratch; leaked, written by the first fault only.
    scratch: usize,
}

static PREPARED: OnceLock<Prepared> = OnceLock::new();
static ENTERED: AtomicBool = AtomicBool::new(false);

/// Installs the handlers on this thread (call on the main thread, early). A second call does nothing.
pub fn install_fault_report(config: &FaultConfig) {
    let _ = std::fs::create_dir_all(&config.crashes_dir);
    let mut prefix = config.crashes_dir.to_string_lossy().into_owned().into_bytes();
    prefix.extend_from_slice(b"/crash-");
    let Ok(log) = CString::new(config.log_file.to_string_lossy().into_owned()) else { return };
    let scratch: &'static mut [u8] = Box::leak(vec![0u8; REPORT_BYTES + LOG_BYTES].into_boxed_slice());
    let prepared = Prepared {
        prefix,
        log,
        app: config.app.clone(),
        system: config.system.clone(),
        home: config.homes.iter().find(|h| h.len() > 1).cloned().unwrap_or_default().into_bytes(),
        slide: main_image_slide(),
        scratch: scratch.as_mut_ptr() as usize,
    };
    if PREPARED.set(prepared).is_err() {
        return;
    }
    let stack: &'static mut [u8] = Box::leak(vec![0u8; ALT_STACK].into_boxed_slice());
    // SAFETY: plain libc calls with zeroed, then filled, structs; the alternate stack and the buffers are leaked, so
    // they outlive every signal; the handler only calls async-signal-safe functions.
    unsafe {
        let ss = libc::stack_t { ss_sp: stack.as_mut_ptr().cast(), ss_flags: 0, ss_size: ALT_STACK };
        libc::sigaltstack(&ss, std::ptr::null_mut());
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = handler as extern "C" fn(libc::c_int, *mut libc::siginfo_t, *mut libc::c_void) as usize;
        action.sa_flags = libc::SA_SIGINFO | libc::SA_ONSTACK | libc::SA_RESETHAND | libc::SA_NODEFER;
        libc::sigemptyset(&mut action.sa_mask);
        for sig in SIGNALS {
            libc::sigaction(sig, &action, std::ptr::null_mut());
        }
    }
}

fn name(sig: libc::c_int) -> &'static str {
    match sig {
        libc::SIGSEGV => "SIGSEGV (invalid memory access)",
        libc::SIGBUS => "SIGBUS (bus error)",
        libc::SIGILL => "SIGILL (illegal instruction)",
        libc::SIGABRT => "SIGABRT (abort)",
        libc::SIGFPE => "SIGFPE (arithmetic error)",
        libc::SIGTRAP => "SIGTRAP (trap)",
        _ => "signal",
    }
}

/// The load address of the main program (`dl_iterate_phdr` reports it first); 0 when unknown.
fn main_image_slide() -> u64 {
    unsafe extern "C" fn first(
        info: *mut libc::dl_phdr_info,
        _size: libc::size_t,
        data: *mut libc::c_void,
    ) -> libc::c_int {
        // SAFETY: the loader passes a valid `dl_phdr_info`; `data` is the `u64` we gave.
        unsafe { *data.cast::<u64>() = (*info).dlpi_addr };
        1
    }
    let mut slide = 0u64;
    // SAFETY: the callback only writes the `u64` behind `data`, which lives through the call.
    unsafe { libc::dl_iterate_phdr(Some(first), (&raw mut slide).cast()) };
    slide
}

/// The instruction pointer of the interrupted code.
///
/// # Safety
/// `ctx` is the `ucontext_t` the kernel passed to a `SA_SIGINFO` handler, or null.
unsafe fn program_counter(ctx: *mut libc::c_void) -> u64 {
    if ctx.is_null() {
        return 0;
    }
    unsafe {
        let uc = &*ctx.cast::<libc::ucontext_t>();
        #[cfg(target_arch = "x86_64")]
        return uc.uc_mcontext.gregs[libc::REG_RIP as usize] as u64;
        #[cfg(target_arch = "aarch64")]
        return uc.uc_mcontext.pc;
        #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
        {
            let _ = uc;
            0
        }
    }
}

extern "C" fn handler(sig: libc::c_int, info: *mut libc::siginfo_t, ctx: *mut libc::c_void) {
    let Some(p) = PREPARED.get() else { return };
    if ENTERED.swap(true, Ordering::SeqCst) {
        return;
    }
    // SAFETY: async-signal-safe libc calls only; `scratch` is the leaked buffer, used by this one fault.
    unsafe {
        let mem = std::slice::from_raw_parts_mut(p.scratch as *mut u8, REPORT_BYTES + LOG_BYTES);
        let (report_mem, log_mem) = mem.split_at_mut(REPORT_BYTES);
        let mut ts: libc::timespec = std::mem::zeroed();
        libc::clock_gettime(libc::CLOCK_REALTIME, &mut ts);
        let ms = ts.tv_sec.max(0) as u64 * 1000 + ts.tv_nsec.max(0) as u64 / 1_000_000;

        let mut out = Buf::new(report_mem);
        sq_fault_text::header(&mut out, ms, &p.app, &p.system);
        out.str("fault: ").str(name(sig)).str("\n");
        if !info.is_null() {
            out.str("address: ").hex((*info).si_addr() as usize as u64).str("\n");
        }
        let pc = program_counter(ctx);
        out.str("pc: ").hex(pc).str("\n");
        out.str("image slide: ").hex(p.slide).str(" (pc - slide = offset)\n");
        out.str("\nLast log lines\n");
        let tail = read_tail(&p.log, log_mem);
        out.redacted(tail, &p.home);

        let mut path = [0u8; 1024];
        let mut name_buf = Buf::new(&mut path[..1000]);
        name_buf.raw(&p.prefix);
        sq_fault_text::stamp(ms, &mut name_buf);
        name_buf.str(".txt");
        let len = name_buf.bytes().len();
        path[len] = 0;
        let fd = libc::open(path.as_ptr().cast(), libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC, 0o644);
        if fd >= 0 {
            let bytes = out.bytes();
            let mut done = 0;
            while done < bytes.len() {
                let n = libc::write(fd, bytes[done..].as_ptr().cast(), bytes.len() - done);
                if n <= 0 {
                    break;
                }
                done += n as usize;
            }
            libc::close(fd);
        }
    }
    // Returning runs the default action: SA_RESETHAND restored it, and the fault repeats or abort() re-raises.
}

/// The whole lines at the end of the log file, read into `scratch`.
///
/// # Safety
/// Async-signal-safe: only `open`, `lseek`, `pread` and `close`.
unsafe fn read_tail<'a>(log: &CString, scratch: &'a mut [u8]) -> &'a [u8] {
    unsafe {
        let fd = libc::open(log.as_ptr(), libc::O_RDONLY);
        if fd < 0 {
            return &[];
        }
        let size = libc::lseek(fd, 0, libc::SEEK_END).max(0) as u64;
        let start = size.saturating_sub(scratch.len() as u64);
        let n = libc::pread(fd, scratch.as_mut_ptr().cast(), scratch.len(), start as libc::off_t);
        libc::close(fd);
        if n <= 0 {
            return &[];
        }
        sq_fault_text::whole_lines(&scratch[..n as usize], start == 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    const CHILD: &str = "SQ_FAULT_CHILD";

    /// Runs in a child process only: installs the handler and dereferences null.
    #[test]
    fn child_faults_on_purpose() {
        let Ok(dir) = std::env::var(CHILD) else { return };
        let dir = std::path::PathBuf::from(dir);
        let log = dir.join("sq.log");
        let _ = std::fs::write(&log, "1 INFO start\n2 INFO opened /Users/zoe/film.sqproj\n");
        install_fault_report(&FaultConfig {
            crashes_dir: dir.join("Crashes"),
            log_file: log,
            app: "Sequence Studio test".into(),
            system: "linux test".into(),
            homes: vec!["/Users/zoe".into()],
        });
        // SAFETY: deliberately invalid, to raise SIGSEGV.
        unsafe { std::ptr::null_mut::<u8>().write_volatile(1) };
    }

    #[test]
    fn a_segfault_leaves_a_report() {
        if std::env::var(CHILD).is_ok() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-fault-linux-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let exe = std::env::current_exe().unwrap_or_default();
        let status = Command::new(exe)
            .args(["--exact", "fault_linux::tests::child_faults_on_purpose", "--nocapture", "--test-threads=1"])
            .env(CHILD, &dir)
            .status();
        assert!(status.is_ok_and(|s| !s.success()));
        let found = std::fs::read_dir(dir.join("Crashes")).map(|d| d.flatten().next()).unwrap_or(None);
        let text = found.and_then(|f| std::fs::read_to_string(f.path()).ok()).unwrap_or_default();
        assert!(text.starts_with("Sequence Studio crash report\ncreated: "), "{text}");
        assert!(text.contains("fault: SIGSEGV"), "{text}");
        assert!(text.contains("address: 0x0\n"), "{text}");
        assert!(text.contains("app: Sequence Studio test"), "{text}");
        assert!(text.contains("2 INFO opened ~/film.sqproj"), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
