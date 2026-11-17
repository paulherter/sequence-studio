//! The Mac's system sources for playback (Swift: `CVDisplayLink` target timestamps in `RenderLoop`, `ProcessInfo` thermal
//! and Low Power notifications in `PowerMonitor`, the `DispatchSource` memory-pressure source of `MemoryPressureRegistry`, and
//! the main run-loop observer of `PlayProbe.watchMainRunLoop`). Each one feeds the portable types of `sq_playback`.

use block2::RcBlock;
use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject, Bool};
use sq_playback::engine::power_policy::{MemoryPressure, ThermalLevel};
use sq_playback::engine::system_watch::{MemoryPressureRegistry, PowerSource};
use sq_playback::probe::{LoopActivity, StallWatch};
use std::ffi::{c_char, c_int, c_ulong, c_void};
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {
    static NSProcessInfoThermalStateDidChangeNotification: *const AnyObject;
    static NSProcessInfoPowerStateDidChangeNotification: *const AnyObject;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRunLoopGetMain() -> *mut c_void;
    fn CFRunLoopObserverCreate(
        allocator: *const c_void,
        activities: c_ulong,
        repeats: u8,
        order: isize,
        callout: extern "C" fn(*mut c_void, c_ulong, *mut c_void),
        context: *const CFRunLoopObserverContext,
    ) -> *mut c_void;
    fn CFRunLoopAddObserver(rl: *mut c_void, observer: *mut c_void, mode: *const c_void);
    static kCFRunLoopCommonModes: *const c_void;
}

#[repr(C)]
struct CFRunLoopObserverContext {
    version: isize,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}

// libdispatch lives in libSystem.
unsafe extern "C" {
    static _dispatch_source_type_memorypressure: c_void;
    fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
    fn dispatch_source_create(kind: *const c_void, handle: usize, mask: c_ulong, queue: *mut c_void) -> *mut c_void;
    fn dispatch_set_context(object: *mut c_void, context: *mut c_void);
    fn dispatch_source_set_event_handler_f(source: *mut c_void, handler: extern "C" fn(*mut c_void));
    fn dispatch_source_get_data(source: *mut c_void) -> c_ulong;
    fn dispatch_source_cancel(source: *mut c_void);
    fn dispatch_resume(object: *mut c_void);
}

// MARK: Power

/// `NSProcessInfo` thermal state and Low Power Mode.
pub struct MacPower;

impl MacPower {
    fn info() -> *mut AnyObject {
        let Some(class) = AnyClass::get(c"NSProcessInfo") else { return std::ptr::null_mut() };
        // SAFETY: `processInfo` is a class method returning the live singleton.
        unsafe { msg_send![class, processInfo] }
    }
}

impl PowerSource for MacPower {
    fn thermal(&self) -> ThermalLevel {
        let info = Self::info();
        if info.is_null() {
            return ThermalLevel::Nominal;
        }
        // SAFETY: `thermalState` is an NSInteger property getter (nominal 0, fair 1, serious 2, critical 3).
        let state: isize = unsafe { msg_send![info, thermalState] };
        match state {
            0 => ThermalLevel::Nominal,
            1 => ThermalLevel::Fair,
            2 => ThermalLevel::Serious,
            _ => ThermalLevel::Critical,
        }
    }

    fn low_power(&self) -> bool {
        let info = Self::info();
        if info.is_null() {
            return false;
        }
        // SAFETY: `isLowPowerModeEnabled` is a BOOL property getter.
        let on: Bool = unsafe { msg_send![info, isLowPowerModeEnabled] };
        on.as_bool()
    }
}

/// Calls `changed` whenever the thermal state or Low Power Mode changes (the same two notifications as Swift's
/// `PowerMonitor`), on the thread that posts them. The observers live for the process.
pub fn watch_power_changes(changed: impl Fn() + Send + Sync + 'static) {
    let Some(center_class) = AnyClass::get(c"NSNotificationCenter") else { return };
    let changed = Arc::new(changed);
    // SAFETY: `defaultCenter` is a class method returning the live singleton; `addObserverForName:object:queue:usingBlock:`
    // takes a notification name, nil object, nil queue and a block that is copied (the observer token is intentionally kept
    // for the process lifetime, so it is not released).
    unsafe {
        let center: *mut AnyObject = msg_send![center_class, defaultCenter];
        if center.is_null() {
            return;
        }
        for name in [NSProcessInfoThermalStateDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification] {
            let changed = Arc::clone(&changed);
            let block = RcBlock::new(move |_note: *mut AnyObject| changed());
            let _token: *mut AnyObject = msg_send![
                center,
                addObserverForName: name,
                object: std::ptr::null::<AnyObject>(),
                queue: std::ptr::null::<AnyObject>(),
                usingBlock: &*block
            ];
        }
    }
}

// MARK: Memory pressure

struct PressureContext {
    source: AtomicPtr<c_void>,
    registry: MemoryPressureRegistry,
}

extern "C" fn memory_pressure_event(context: *mut c_void) {
    // SAFETY: `context` is the leaked `PressureContext` set by `MemoryPressureWatch::start`; it lives for the process.
    let ctx = unsafe { &*context.cast::<PressureContext>() };
    let source = ctx.source.load(Ordering::Acquire);
    if source.is_null() {
        return;
    }
    // SAFETY: the source is alive while the event handler runs.
    let data = unsafe { dispatch_source_get_data(source) };
    let level = if data & 0x4 != 0 {
        MemoryPressure::Critical
    } else if data & 0x2 != 0 {
        MemoryPressure::Warning
    } else {
        MemoryPressure::Normal
    };
    ctx.registry.post(level);
}

/// The system's memory-pressure dispatch source (normal, warning, critical), posting into a registry. Dropping it stops
/// the events.
pub struct MemoryPressureWatch {
    source: *mut c_void,
}

// SAFETY: dispatch sources are thread-safe; the pointer is only used to cancel.
unsafe impl Send for MemoryPressureWatch {}

impl MemoryPressureWatch {
    /// `None` when the source cannot be created.
    pub fn start(registry: MemoryPressureRegistry) -> Option<MemoryPressureWatch> {
        // SAFETY: plain libdispatch calls; the context is leaked on purpose (one watch per process, a few bytes) so the event
        // handler never sees freed memory after `cancel`.
        unsafe {
            let queue = dispatch_queue_create(c"sq.memoryPressure".as_ptr(), std::ptr::null());
            if queue.is_null() {
                return None;
            }
            let source = dispatch_source_create(
                std::ptr::from_ref(&_dispatch_source_type_memorypressure),
                0,
                0x1 | 0x2 | 0x4,
                queue,
            );
            if source.is_null() {
                return None;
            }
            let ctx = Box::into_raw(Box::new(PressureContext { source: AtomicPtr::new(source), registry }));
            dispatch_set_context(source, ctx.cast());
            dispatch_source_set_event_handler_f(source, memory_pressure_event);
            dispatch_resume(source);
            Some(MemoryPressureWatch { source })
        }
    }
}

impl Drop for MemoryPressureWatch {
    fn drop(&mut self) {
        // SAFETY: the source is alive until canceled here.
        unsafe { dispatch_source_cancel(self.source) };
    }
}

// MARK: Run-loop stalls

struct StallContext {
    watch: Mutex<StallWatch>,
    probe: &'static sq_playback::probe::PlayProbe,
}

extern "C" fn run_loop_activity(_observer: *mut c_void, activity: c_ulong, info: *mut c_void) {
    // SAFETY: `info` is the leaked `StallContext` of `watch_main_run_loop`.
    let ctx = unsafe { &*info.cast::<StallContext>() };
    let which = if activity == 1 << 6 { LoopActivity::AfterWaiting } else { LoopActivity::BeforeWaiting };
    let stall = ctx.watch.lock().unwrap_or_else(PoisonError::into_inner).activity(which, sq_playback::probe::now());
    if let Some((ms, line)) = stall {
        ctx.probe.record_stall(ms);
        eprintln!("{line}");
    }
}

/// Records every main run-loop iteration longer than `threshold` seconds (work from wake-up to going back to sleep) into
/// `probe` and logs it. Call once on the main thread; Swift's stack watchdog is not ported.
pub fn watch_main_run_loop(probe: &'static sq_playback::probe::PlayProbe, threshold: f64) {
    let ctx = Box::into_raw(Box::new(StallContext { watch: Mutex::new(StallWatch::new(threshold)), probe }));
    let context = CFRunLoopObserverContext {
        version: 0,
        info: ctx.cast(),
        retain: std::ptr::null(),
        release: std::ptr::null(),
        copy_description: std::ptr::null(),
    };
    // SAFETY: the observer and its context live for the process; CoreFoundation copies the context struct.
    unsafe {
        let observer =
            CFRunLoopObserverCreate(std::ptr::null(), (1 << 5) | (1 << 6), 1, isize::MAX, run_loop_activity, &context);
        if !observer.is_null() {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        }
    }
}

// MARK: Display link

#[repr(C)]
struct CVSMPTETime {
    subframes: i16,
    subframe_divisor: i16,
    counter: u32,
    kind: u32,
    flags: u32,
    hours: i16,
    minutes: i16,
    seconds: i16,
    frames: i16,
}

#[repr(C)]
struct CVTimeStamp {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
    smpte_time: CVSMPTETime,
    flags: u64,
    reserved: u64,
}

#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

unsafe extern "C" {
    fn mach_timebase_info(info: *mut MachTimebase) -> c_int;
    fn mach_absolute_time() -> u64;
}

#[link(name = "CoreVideo", kind = "framework")]
unsafe extern "C" {
    fn CVDisplayLinkCreateWithActiveCGDisplays(out: *mut *mut c_void) -> c_int;
    fn CVDisplayLinkSetOutputCallback(
        link: *mut c_void,
        callback: extern "C" fn(
            *mut c_void,
            *const CVTimeStamp,
            *const CVTimeStamp,
            u64,
            *mut u64,
            *mut c_void,
        ) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn CVDisplayLinkStart(link: *mut c_void) -> c_int;
    fn CVDisplayLinkStop(link: *mut c_void) -> c_int;
    fn CVDisplayLinkRelease(link: *mut c_void);
}

type LinkHandler = Box<dyn Fn(Instant, Instant, Duration) + Send + Sync>;

extern "C" fn link_output(
    _link: *mut c_void,
    _now: *const CVTimeStamp,
    output: *const CVTimeStamp,
    _flags_in: u64,
    _flags_out: *mut u64,
    context: *mut c_void,
) -> c_int {
    // SAFETY: `context` is the `LinkHandler` box owned by the `DisplayLink`, which stops the link before freeing it; `output`
    // is a valid timestamp for the duration of the call.
    let (handler, out) = unsafe { (&*context.cast::<LinkHandler>(), &*output) };
    let mut base = MachTimebase { numer: 0, denom: 0 };
    // SAFETY: plain mach calls.
    let ticks_now = unsafe {
        mach_timebase_info(&mut base);
        mach_absolute_time()
    };
    if base.denom == 0 || out.video_time_scale <= 0 {
        return 0;
    }
    let at = Instant::now();
    // The frame reaches the glass at `output.host_time` (mach ticks); the distance from now may be negative (a late link).
    let delta_ticks = i128::from(out.host_time) - i128::from(ticks_now);
    let delta_ns = delta_ticks * i128::from(base.numer) / i128::from(base.denom);
    let present = if delta_ns >= 0 {
        at + Duration::from_nanos(u64::try_from(delta_ns).unwrap_or(0))
    } else {
        at.checked_sub(Duration::from_nanos(u64::try_from(-delta_ns).unwrap_or(0))).unwrap_or(at)
    };
    let interval = Duration::from_secs_f64(out.video_refresh_period as f64 / f64::from(out.video_time_scale));
    handler(at, present, interval);
    0
}

/// A `CVDisplayLink` on the active displays: each refresh calls `on_tick(now, present, interval)` on the link's thread, with
/// the host time the frame it asks for reaches the glass (Swift reads the same `outputTime` as the display lead's presentation
/// time). Dropping it stops the link.
pub struct DisplayLink {
    link: *mut c_void,
    handler: *mut LinkHandler,
}

// SAFETY: the link is only started and stopped from the owner; its callback runs on the link thread against a Send + Sync handler.
unsafe impl Send for DisplayLink {}

impl DisplayLink {
    /// `None` without a display (headless machine) or when CoreVideo refuses the link.
    pub fn start(on_tick: impl Fn(Instant, Instant, Duration) + Send + Sync + 'static) -> Option<DisplayLink> {
        let handler = Box::into_raw(Box::new(Box::new(on_tick) as LinkHandler));
        let mut link: *mut c_void = std::ptr::null_mut();
        // SAFETY: CoreVideo calls; the handler box outlives the link (freed in `drop` after `CVDisplayLinkStop`).
        unsafe {
            let ok = CVDisplayLinkCreateWithActiveCGDisplays(&mut link) == 0
                && !link.is_null()
                && CVDisplayLinkSetOutputCallback(link, link_output, handler.cast()) == 0
                && CVDisplayLinkStart(link) == 0;
            if !ok {
                if !link.is_null() {
                    CVDisplayLinkRelease(link);
                }
                drop(Box::from_raw(handler));
                return None;
            }
        }
        Some(DisplayLink { link, handler })
    }
}

impl Drop for DisplayLink {
    fn drop(&mut self) {
        // SAFETY: stop first (no callback runs after it returns), then free what the callback read.
        unsafe {
            CVDisplayLinkStop(self.link);
            CVDisplayLinkRelease(self.link);
            drop(Box::from_raw(self.handler));
        }
    }
}

#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn the_display_link_reports_present_times_ahead_of_its_ticks() {
        let seen: Arc<Mutex<Vec<(Duration, Duration)>>> = Arc::default();
        let s = Arc::clone(&seen);
        let Some(link) = DisplayLink::start(move |at, present, interval| {
            let ahead = present.saturating_duration_since(at);
            s.lock().unwrap_or_else(PoisonError::into_inner).push((ahead, interval));
        }) else {
            eprintln!("skipped: no display link");
            return;
        };
        let t = Instant::now();
        while t.elapsed() < Duration::from_millis(600) && seen.lock().map_or(0, |v| v.len()) < 10 {
            std::thread::sleep(Duration::from_millis(20));
        }
        drop(link);
        let v = seen.lock().expect("lock").clone();
        assert!(v.len() >= 5, "a display link ticks, got {}", v.len());
        for (ahead, interval) in v {
            assert!(
                interval >= Duration::from_millis(2) && interval <= Duration::from_millis(50),
                "interval {interval:?}"
            );
            assert!(ahead <= Duration::from_millis(150), "present {ahead:?} ahead");
        }
    }

    #[test]
    fn the_system_power_state_reads_and_a_posted_pressure_reaches_a_registration() {
        // A real read of the thermal state: any level is valid, the call must not fail.
        let _ = MacPower.thermal();
        let _ = MacPower.low_power();
        let registry = MemoryPressureRegistry::default();
        let hits = Arc::new(AtomicUsize::new(0));
        let h = Arc::clone(&hits);
        let _token = registry.register("test", move |_| {
            h.fetch_add(1, Ordering::SeqCst);
        });
        let watch = MemoryPressureWatch::start(registry.clone());
        assert!(watch.is_some(), "the dispatch memory-pressure source starts");
        registry.post(MemoryPressure::Warning);
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        let changes = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&changes);
        watch_power_changes(move || {
            c.fetch_add(1, Ordering::SeqCst);
        });
    }
}
