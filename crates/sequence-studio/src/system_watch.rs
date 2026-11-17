//! The system sources playback listens to, installed once on the main thread at start (Swift: the display link's target
//! timestamps in `RenderLoop`, `PowerMonitor`, `MemoryPressureRegistry.shared`, `PlayProbe.watchMainRunLoop`).
//!
//! Mac: a CVDisplayLink feeds the engine's present timestamps, the thermal / Low Power notifications feed the power monitor,
//! the dispatch memory-pressure source feeds the registry, and `SQ_PLAY_PROBE=1` adds the run-loop stall watcher. Windows and
//! Linux have no counterpart in Swift's build either (winit gives no present timestamps; no thermal or battery-saver
//! signal): the engine times play from the window loop's ticks, the policy stays normal, and the log says so once.
//! The power policy goes to `sq_playback::engine::system_watch::set_system_power`, memory pressure to the shared registry;
//! the session applies both (`EditorSession::apply_load_policy`).

#[cfg(target_os = "macos")]
use sq_playback::engine::system_watch::{MemoryPressureRegistry, PowerMonitor};
#[cfg(target_os = "macos")]
use std::sync::{Arc, Mutex, PoisonError};

/// The registry every memory-hungry cache of the app listens to.
#[cfg(target_os = "macos")]
pub fn memory_pressure() -> MemoryPressureRegistry {
    sq_playback::engine::system_watch::shared_memory_pressure()
}

/// What stays alive for the process: the links and sources are dropped (stopped) with it.
pub struct Watchers {
    #[cfg(target_os = "macos")]
    _link: Option<sq_platform_mac::DisplayLink>,
    #[cfg(target_os = "macos")]
    _pressure: Option<sq_platform_mac::MemoryPressureWatch>,
}

#[cfg(target_os = "macos")]
pub fn install() -> Watchers {
    use crate::applog;
    let timing = crate::playback::display_timing();
    let link =
        sq_platform_mac::DisplayLink::start(move |at, present, interval| timing.link_tick(at, present, interval));
    if link.is_none() {
        applog::info("display link: none (no display); playback times from the window loop's ticks");
    }
    let monitor = Arc::new(Mutex::new(PowerMonitor::new(
        Box::new(sq_platform_mac::MacPower),
        std::env::var("SQ_THERMAL").ok().as_deref(),
    )));
    if let Ok(m) = monitor.lock() {
        applog::info(&format!("power: {:?}, {:?}", m.thermal(), m.policy()));
        sq_playback::engine::system_watch::set_system_power(m.policy());
    }
    let watched = Arc::clone(&monitor);
    sq_platform_mac::watch_power_changes(move || {
        let changed = watched.lock().unwrap_or_else(PoisonError::into_inner).update();
        if let Some(p) = changed {
            sq_playback::engine::system_watch::set_system_power(p);
            applog::info(&format!("power: {p:?}"));
        }
    });
    let registry = memory_pressure();
    // The log line is the first listener; each cache registers its own.
    let token = registry.register("log", |level| applog::info(&format!("memory pressure: {level:?}")));
    std::mem::forget(token);
    let pressure = sq_platform_mac::MemoryPressureWatch::start(registry);
    if sq_playback::probe::enabled() {
        sq_platform_mac::watch_main_run_loop(sq_playback::probe::PlayProbe::shared(), 0.008);
    }
    Watchers { _link: link, _pressure: pressure }
}

#[cfg(not(target_os = "macos"))]
pub fn install() -> Watchers {
    crate::applog::info(
        "playback sources: no display link, thermal or battery-saver signal on this system; \
         play is timed from the window loop's ticks and the power policy stays normal",
    );
    Watchers {}
}
