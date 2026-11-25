//! What a thread of the app is for, and the system's scheduling hint for it; plus the CPU time a thread has used.
//!
//! The playback engine's render thread competes with decoder lanes, ffmpeg's frame threads and the UI. A thread at the default
//! scheduling class can be parked on an efficiency core or preempted for milliseconds (the slow composites of the real-window
//! runs spent their time "nowhere": every timer inside was tiny, the wall time was not). [`set_current_thread_role`] gives each
//! thread its class once, at the top of its body:
//!
//! | Role          | macOS QoS            | Windows priority | Linux |
//! |---------------|----------------------|------------------|-------|
//! | `Interactive` | `USER_INTERACTIVE`   | `ABOVE_NORMAL`   | none  |
//! | `Decode`      | `USER_INITIATED`     | `NORMAL`         | none  |
//! | `Background`  | `UTILITY`            | `BELOW_NORMAL`   | nice 15 (own thread, inherited) |
//!
//! Linux: raising a thread's priority needs `RLIMIT_NICE` or root, which an app must not assume, and real-time classes are
//! not wanted; so Linux does nothing (the call reports `false`). ffmpeg's internal frame threads are created by the thread
//! that opens the decoder; on macOS a new pthread inherits the creator's QoS, so a decoder opened on a `Decode` thread keeps
//! its helper threads at `Decode`. VideoToolbox's own callback threads are the system's and cannot be set.
//!
//! `SQ_THREAD_ROLES=0` turns every call into a no-op (A/B runs).

use std::time::Duration;

/// What a thread is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// The render / compose thread and anything the picture on screen waits for.
    Interactive,
    /// Playback decode lanes and file opens that playback waits for.
    Decode,
    /// Proxy transcodes, graveyard drops and other work nobody waits for.
    Background,
}

/// Whether the environment value of `SQ_THREAD_ROLES` leaves the roles on (only `0` turns them off).
pub fn roles_enabled_from(value: Option<&str>) -> bool {
    value.map(str::trim) != Some("0")
}

fn roles_enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| roles_enabled_from(std::env::var("SQ_THREAD_ROLES").ok().as_deref()))
}

/// Gives the calling thread the scheduling class of `role`. Returns whether the system accepted a change (false: switched
/// off by `SQ_THREAD_ROLES=0`, Linux, or the call failed; the thread then runs as before). Never panics.
pub fn set_current_thread_role(role: Role) -> bool {
    roles_enabled() && apply(role)
}

#[cfg(target_os = "macos")]
fn qos(role: Role) -> libc::qos_class_t {
    match role {
        Role::Interactive => libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE,
        Role::Decode => libc::qos_class_t::QOS_CLASS_USER_INITIATED,
        Role::Background => libc::qos_class_t::QOS_CLASS_UTILITY,
    }
}

#[cfg(target_os = "macos")]
fn apply(role: Role) -> bool {
    // SAFETY: sets the QoS of the calling thread only; no pointers.
    unsafe { libc::pthread_set_qos_class_self_np(qos(role), 0) == 0 }
}

#[cfg(windows)]
fn priority(role: Role) -> i32 {
    use windows_sys::Win32::System::Threading::{
        THREAD_PRIORITY_ABOVE_NORMAL, THREAD_PRIORITY_BELOW_NORMAL, THREAD_PRIORITY_NORMAL,
    };
    match role {
        Role::Interactive => THREAD_PRIORITY_ABOVE_NORMAL,
        Role::Decode => THREAD_PRIORITY_NORMAL,
        Role::Background => THREAD_PRIORITY_BELOW_NORMAL,
    }
}

#[cfg(windows)]
fn apply(role: Role) -> bool {
    use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadPriority};
    // SAFETY: GetCurrentThread returns a pseudo handle that needs no closing; the priority applies to this thread only.
    unsafe { SetThreadPriority(GetCurrentThread(), priority(role)) != 0 }
}

/// Linux nice value of a `Background` thread. Lowering a thread's own priority needs no privilege; new threads inherit it, so
/// the worker threads a library starts afterwards (ONNX Runtime's pool, ffmpeg's frame threads) stay behind playback too.
#[cfg(target_os = "linux")]
const BACKGROUND_NICE: libc::c_int = 15;

#[cfg(target_os = "linux")]
fn apply(role: Role) -> bool {
    if role != Role::Background {
        return false;
    }
    // SAFETY: gettid has no arguments; setpriority(PRIO_PROCESS, tid) changes that one thread only (Linux semantics).
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        // Already at least that nice (the whole process runs niced): raising it again would need privilege; nothing to do.
        libc::getpriority(libc::PRIO_PROCESS, tid) >= BACKGROUND_NICE
            || libc::setpriority(libc::PRIO_PROCESS, tid, BACKGROUND_NICE) == 0
    }
}

#[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
fn apply(_role: Role) -> bool {
    false
}

/// How many compute threads a long background job (EdgeTAM tracking, analysis) may use so that decode, render and the UI keep
/// cores: half of the logical cores (about the physical cores), at least 1. `SQ_BACKGROUND_THREADS=<n>` overrides (A/B runs).
pub fn background_threads() -> usize {
    let cores = std::thread::available_parallelism().map_or(1, |n| n.get());
    let forced = std::env::var("SQ_BACKGROUND_THREADS").ok().and_then(|v| v.trim().parse::<usize>().ok());
    background_threads_for(cores, forced)
}

/// [`background_threads`] for `cores` logical cores and an optional override.
pub fn background_threads_for(cores: usize, forced: Option<usize>) -> usize {
    forced.filter(|n| *n > 0).unwrap_or((cores / 2).max(1))
}

#[cfg(test)]
mod background_tests {
    use super::*;

    #[test]
    fn half_the_cores_at_least_one() {
        assert_eq!(background_threads_for(16, None), 8);
        assert_eq!(background_threads_for(1, None), 1);
        assert_eq!(background_threads_for(3, None), 1);
        assert_eq!(background_threads_for(16, Some(3)), 3);
        assert_eq!(background_threads_for(16, Some(0)), 8);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn background_role_lowers_the_nice_of_this_thread_only() {
        let before = unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) };
        let (changed, inside, child) = std::thread::spawn(|| {
            let changed = apply(Role::Background);
            let inside = unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) };
            let child = std::thread::spawn(|| unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) }).join().unwrap();
            (changed, inside, child)
        })
        .join()
        .unwrap();
        assert!(changed);
        assert_eq!(inside, BACKGROUND_NICE.max(before));
        assert_eq!(child, inside, "threads started later inherit it");
        assert_eq!(unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) }, before);
        assert!(!apply(Role::Decode));
    }
}

/// CPU time (user + system) the calling thread has used so far; `None` where the system does not say. Wall time minus this
/// difference over an interval is the time the thread was not running (preempted, parked, blocked).
pub fn thread_cpu_time() -> Option<Duration> {
    cpu_time()
}

/// The calling thread's user and system CPU time so far, `(user, system)`; `None` where the system does not say. System
/// time is the kernel working for the thread (page faults on fresh memory, munmap of freed buffers, syscalls).
pub fn thread_cpu_split() -> Option<(Duration, Duration)> {
    cpu_split()
}

#[cfg(target_os = "macos")]
fn cpu_split() -> Option<(Duration, Duration)> {
    use std::mem::MaybeUninit;
    let mut info = MaybeUninit::<libc::thread_basic_info>::zeroed();
    let mut count = libc::THREAD_BASIC_INFO_COUNT;
    // SAFETY: `info` has room for `count` integers; the port of the calling thread is borrowed (no right is added, so
    // nothing to release); `info` is only read when the call succeeded.
    let (ok, info) = unsafe {
        let port = libc::pthread_mach_thread_np(libc::pthread_self());
        let ok = libc::thread_info(port, libc::THREAD_BASIC_INFO as u32, info.as_mut_ptr().cast(), &mut count) == 0;
        (ok, info.assume_init())
    };
    let tv = |t: libc::time_value_t| Duration::new(t.seconds.max(0) as u64, (t.microseconds.max(0) as u32) * 1000);
    ok.then(|| (tv(info.user_time), tv(info.system_time)))
}

#[cfg(all(unix, not(target_os = "macos")))]
fn cpu_split() -> Option<(Duration, Duration)> {
    // SAFETY: a zeroed `rusage` is valid; the out pointer is valid for the call.
    let (ok, ru) = unsafe {
        let mut ru: libc::rusage = std::mem::zeroed();
        (libc::getrusage(libc::RUSAGE_THREAD, &mut ru) == 0, ru)
    };
    let tv = |t: libc::timeval| Duration::new(t.tv_sec.max(0) as u64, (t.tv_usec.max(0) as u32) * 1000);
    ok.then(|| (tv(ru.ru_utime), tv(ru.ru_stime)))
}

#[cfg(windows)]
fn cpu_split() -> Option<(Duration, Duration)> {
    thread_times().map(|(kernel, user)| (user, kernel))
}

#[cfg(not(any(unix, windows)))]
fn cpu_split() -> Option<(Duration, Duration)> {
    None
}

#[cfg(unix)]
fn cpu_time() -> Option<Duration> {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid out pointer for the call.
    let ok = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) } == 0;
    (ok && ts.tv_sec >= 0 && ts.tv_nsec >= 0).then(|| Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32))
}

#[cfg(windows)]
fn cpu_time() -> Option<Duration> {
    thread_times().map(|(kernel, user)| kernel + user)
}

/// `(kernel, user)` time of the calling thread.
#[cfg(windows)]
fn thread_times() -> Option<(Duration, Duration)> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, GetThreadTimes};
    let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
    // SAFETY: four valid out pointers; the pseudo handle needs no closing.
    let ok = unsafe { GetThreadTimes(GetCurrentThread(), &mut created, &mut exited, &mut kernel, &mut user) } != 0;
    let ticks = |t: FILETIME| (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime);
    // FILETIME ticks are 100 ns.
    let time = |t: FILETIME| Duration::from_nanos(ticks(t).saturating_mul(100));
    ok.then(|| (time(kernel), time(user)))
}

#[cfg(not(any(unix, windows)))]
fn cpu_time() -> Option<Duration> {
    None
}

/// A handle on the CPU clock of ONE thread, readable from any other thread (the main-thread watchdog of the window loop
/// asks it whether a stalled thread was running or not). Take it on the thread to watch with [`ThreadCpu::of_current`].
/// Reading after the thread ended gives `None`.
pub struct ThreadCpu {
    #[cfg(target_os = "macos")]
    port: u32,
    #[cfg(all(unix, not(target_os = "macos")))]
    clock: libc::clockid_t,
    #[cfg(windows)]
    handle: windows_sys::Win32::Foundation::HANDLE,
}

// SAFETY: the fields are plain identifiers of a thread (a mach port name, a clock id, a duplicated thread handle); reading a
// thread's CPU time through them is allowed from any thread.
unsafe impl Send for ThreadCpu {}
// SAFETY: see above; no field is mutated after creation.
unsafe impl Sync for ThreadCpu {}

impl ThreadCpu {
    /// The handle of the calling thread; `None` where the system does not offer one.
    pub fn of_current() -> Option<ThreadCpu> {
        Self::current()
    }

    /// User plus system CPU time the thread has used so far.
    pub fn read(&self) -> Option<Duration> {
        self.cpu()
    }

    #[cfg(target_os = "macos")]
    fn current() -> Option<ThreadCpu> {
        // SAFETY: borrows the calling thread's port name; no right is added.
        Some(ThreadCpu { port: unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) } })
    }

    #[cfg(target_os = "macos")]
    fn cpu(&self) -> Option<Duration> {
        use std::mem::MaybeUninit;
        let mut info = MaybeUninit::<libc::thread_basic_info>::zeroed();
        let mut count = libc::THREAD_BASIC_INFO_COUNT;
        // SAFETY: `info` has room for `count` integers; it is only read when the call succeeded.
        let ok = unsafe {
            libc::thread_info(self.port, libc::THREAD_BASIC_INFO as u32, info.as_mut_ptr().cast(), &mut count) == 0
        };
        // SAFETY: zero-initialized above, and filled by the successful call.
        let info = unsafe { info.assume_init() };
        let tv = |t: libc::time_value_t| Duration::new(t.seconds.max(0) as u64, (t.microseconds.max(0) as u32) * 1000);
        ok.then(|| tv(info.user_time) + tv(info.system_time))
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    fn current() -> Option<ThreadCpu> {
        let mut clock: libc::clockid_t = 0;
        // SAFETY: `clock` is a valid out pointer; the thread is the calling one.
        let ok = unsafe { libc::pthread_getcpuclockid(libc::pthread_self(), &mut clock) } == 0;
        ok.then_some(ThreadCpu { clock })
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    fn cpu(&self) -> Option<Duration> {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: `ts` is a valid out pointer for the call.
        let ok = unsafe { libc::clock_gettime(self.clock, &mut ts) } == 0;
        (ok && ts.tv_sec >= 0 && ts.tv_nsec >= 0).then(|| Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32))
    }

    #[cfg(windows)]
    fn current() -> Option<ThreadCpu> {
        use windows_sys::Win32::Foundation::{DUPLICATE_SAME_ACCESS, DuplicateHandle, HANDLE};
        use windows_sys::Win32::System::Threading::{GetCurrentProcess, GetCurrentThread};
        let mut handle: HANDLE = std::ptr::null_mut();
        // SAFETY: duplicates the calling thread's pseudo handle into a real one that outlives the call; `handle` is a valid
        // out pointer. It is closed in `Drop`.
        let ok = unsafe {
            DuplicateHandle(
                GetCurrentProcess(),
                GetCurrentThread(),
                GetCurrentProcess(),
                &mut handle,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        } != 0;
        ok.then_some(ThreadCpu { handle })
    }

    #[cfg(windows)]
    fn cpu(&self) -> Option<Duration> {
        use windows_sys::Win32::Foundation::FILETIME;
        use windows_sys::Win32::System::Threading::GetThreadTimes;
        let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
        // SAFETY: four valid out pointers; the handle is ours and open.
        let ok = unsafe { GetThreadTimes(self.handle, &mut created, &mut exited, &mut kernel, &mut user) } != 0;
        let ticks = |t: FILETIME| (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime);
        ok.then(|| Duration::from_nanos(ticks(kernel).saturating_add(ticks(user)).saturating_mul(100)))
    }

    #[cfg(not(any(unix, windows)))]
    fn current() -> Option<ThreadCpu> {
        None
    }

    #[cfg(not(any(unix, windows)))]
    fn cpu(&self) -> Option<Duration> {
        None
    }
}

#[cfg(windows)]
impl Drop for ThreadCpu {
    fn drop(&mut self) {
        // SAFETY: the handle came from `DuplicateHandle` and is closed once.
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.handle) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_zero_switches_the_roles_off() {
        assert!(roles_enabled_from(None));
        assert!(roles_enabled_from(Some("1")));
        assert!(roles_enabled_from(Some("")));
        assert!(!roles_enabled_from(Some("0")));
        assert!(!roles_enabled_from(Some(" 0 ")));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_roles_map_to_three_different_qos_classes() {
        use libc::qos_class_t::*;
        assert_eq!(qos(Role::Interactive) as u32, QOS_CLASS_USER_INTERACTIVE as u32);
        assert_eq!(qos(Role::Decode) as u32, QOS_CLASS_USER_INITIATED as u32);
        assert_eq!(qos(Role::Background) as u32, QOS_CLASS_UTILITY as u32);
    }

    #[cfg(windows)]
    #[test]
    fn windows_roles_map_to_three_ascending_priorities() {
        assert!(priority(Role::Background) < priority(Role::Decode));
        assert!(priority(Role::Decode) < priority(Role::Interactive));
    }

    #[test]
    fn every_role_applies_on_its_own_thread_without_panic() {
        for role in [Role::Interactive, Role::Decode, Role::Background] {
            // A separate thread: a role must not leak into the test runner's thread.
            let applied = std::thread::spawn(move || set_current_thread_role(role)).join().expect("no panic");
            if cfg!(any(target_os = "macos", windows)) && roles_enabled() {
                assert!(applied, "{role:?} should apply on this system");
            } else if cfg!(not(any(target_os = "macos", windows))) {
                // Linux lowers only the Background thread (nice, no privilege needed); the rest is left alone.
                assert_eq!(applied, cfg!(target_os = "linux") && role == Role::Background, "{role:?}");
            }
        }
    }

    #[test]
    fn system_time_is_part_of_the_cpu_time_and_a_page_fault_loop_books_some() {
        let Some((user, system)) = thread_cpu_split() else { return };
        let total = thread_cpu_time().expect("total");
        // Both read the same counters a moment apart: the split never exceeds the later total by more than a tick.
        assert!(user + system <= total + Duration::from_millis(5), "{user:?} + {system:?} vs {total:?}");
        let before = thread_cpu_split().expect("split").1;
        for _ in 0..40 {
            // Fresh zeroed memory touched page by page: the kernel faults the pages in.
            let mut v = vec![0u8; 16 << 20];
            for i in (0..v.len()).step_by(4096) {
                v[i] = 1;
            }
            std::hint::black_box(&v);
        }
        let after = thread_cpu_split().expect("split").1;
        assert!(after > before, "touching 640 MB of fresh pages must cost system time");
    }

    #[test]
    fn cpu_time_grows_with_work_and_stays_below_wall_time_when_sleeping() {
        let Some(a) = thread_cpu_time() else { return };
        let mut x = 0u64;
        for i in 0..20_000_000u64 {
            x = x.wrapping_add(std::hint::black_box(i));
        }
        std::hint::black_box(x);
        let b = thread_cpu_time().expect("second reading");
        assert!(b > a, "busy loop must use CPU time");
        let slept = std::time::Instant::now();
        let c0 = thread_cpu_time().expect("reading");
        std::thread::sleep(Duration::from_millis(60));
        let c1 = thread_cpu_time().expect("reading");
        assert!(slept.elapsed() >= Duration::from_millis(60));
        assert!(c1 - c0 < Duration::from_millis(30), "sleeping is not CPU time: {:?}", c1 - c0);
    }

    #[test]
    fn another_thread_reads_the_cpu_time_of_a_busy_thread() {
        let (tx, rx) = std::sync::mpsc::channel();
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let worker = std::thread::spawn(move || {
            let probe = ThreadCpu::of_current();
            let _ = tx.send(probe);
            let began = std::time::Instant::now();
            while began.elapsed() < Duration::from_millis(150) {
                std::hint::black_box(0u64.wrapping_add(1));
            }
            let _ = stop_rx.recv();
        });
        let Some(probe) = rx.recv().ok().flatten() else { return };
        std::thread::sleep(Duration::from_millis(250));
        let used = probe.read().expect("a live thread reads");
        assert!(used >= Duration::from_millis(80), "a thread that spun 150 ms shows its CPU time: {used:?}");
        let _ = stop_tx.send(());
        let _ = worker.join();
    }
}
