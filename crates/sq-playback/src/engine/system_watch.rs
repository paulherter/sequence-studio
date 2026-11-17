// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQCore/MemoryPressure.swift (MemoryPressureRegistry), SQPlayback/PowerPolicy.swift (PowerMonitor)
//! The watchers that feed `power_policy`: one registry every memory-hungry cache listens to for memory pressure, and a
//! monitor of the thermal state and Low Power Mode. Portable and pure; the system sources sit behind `PowerSource` (the Mac
//! reads `NSProcessInfo`, `sq-platform-mac`) and behind `MemoryPressureRegistry::post` (the Mac's dispatch memory-pressure
//! source posts). Swift has no source off the Mac either (Linux: a no-op stand-in; Windows: nominal, never low power),
//! so `NominalPower` is the same behavior, and it says so once in the log.

use super::power_policy::{MemoryPressure, PowerPolicy, ThermalLevel};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

type Handler = Arc<dyn Fn(MemoryPressure) + Send + Sync>;

/// In-order delivery to one registration: a level older than one already delivered is dropped (a racing `post(Normal)` is
/// never followed by a stale warning), and a post arriving while its handler runs is delivered right after by the thread
/// running it.
struct Gate {
    state: Mutex<GateState>,
    handler: Handler,
}

#[derive(Default)]
struct GateState {
    pending: Option<MemoryPressure>,
    seen: u64,
    delivering: bool,
}

impl Gate {
    fn deliver(&self, level: MemoryPressure, seq: u64) {
        {
            let mut s = locked(&self.state);
            if seq <= s.seen {
                return;
            }
            s.seen = seq;
            s.pending = Some(level);
            if s.delivering {
                return;
            }
            s.delivering = true;
        }
        loop {
            let next = {
                let mut s = locked(&self.state);
                match s.pending.take() {
                    Some(p) => p,
                    None => {
                        s.delivering = false;
                        return;
                    }
                }
            };
            (self.handler)(next);
        }
    }
}

#[derive(Default)]
struct Registry {
    level: Option<MemoryPressure>,
    seq: u64,
    next: u64,
    entries: BTreeMap<u64, (String, Arc<Gate>)>,
}

/// The one place every memory-hungry cache listens to memory pressure. A registration made while the level is not normal
/// gets that level at once, so a cache created under pressure starts small.
#[derive(Clone, Default)]
pub struct MemoryPressureRegistry {
    inner: Arc<Mutex<Registry>>,
}

/// Keeps one registration alive; dropping it stops delivery.
pub struct MemoryPressureToken {
    registry: Weak<Mutex<Registry>>,
    id: u64,
}

impl Drop for MemoryPressureToken {
    fn drop(&mut self) {
        if let Some(r) = self.registry.upgrade() {
            locked(&r).entries.remove(&self.id);
        }
    }
}

impl MemoryPressureRegistry {
    pub fn level(&self) -> MemoryPressure {
        locked(&self.inner).level.unwrap_or(MemoryPressure::Normal)
    }

    /// Names of the live registrations (diagnostics).
    pub fn registered_names(&self) -> Vec<String> {
        locked(&self.inner).entries.values().map(|(n, _)| n.clone()).collect()
    }

    pub fn register(
        &self,
        name: &str,
        handler: impl Fn(MemoryPressure) + Send + Sync + 'static,
    ) -> MemoryPressureToken {
        let gate = Arc::new(Gate { state: Mutex::default(), handler: Arc::new(handler) });
        let (id, now, seq) = {
            let mut r = locked(&self.inner);
            r.next += 1;
            let id = r.next;
            r.entries.insert(id, (name.to_string(), Arc::clone(&gate)));
            (id, r.level.unwrap_or(MemoryPressure::Normal), r.seq)
        };
        // Same sequence number as the post that set `now`: any later post is newer and wins.
        if now != MemoryPressure::Normal {
            gate.deliver(now, seq);
        }
        MemoryPressureToken { registry: Arc::downgrade(&self.inner), id }
    }

    /// Delivers `level` to every registration (also when it repeats: the system re-sends warnings while memory stays short).
    pub fn post(&self, level: MemoryPressure) {
        let (gates, seq) = {
            let mut r = locked(&self.inner);
            r.level = Some(level);
            r.seq += 1;
            (r.entries.values().map(|(_, g)| Arc::clone(g)).collect::<Vec<_>>(), r.seq)
        };
        for g in gates {
            g.deliver(level, seq);
        }
    }
}

/// The registry every memory-hungry cache of the process listens to (Swift `MemoryPressureRegistry.shared`).
pub fn shared_memory_pressure() -> MemoryPressureRegistry {
    static REGISTRY: std::sync::OnceLock<MemoryPressureRegistry> = std::sync::OnceLock::new();
    REGISTRY.get_or_init(MemoryPressureRegistry::default).clone()
}

fn system_power_cell() -> &'static Mutex<PowerPolicy> {
    static CELL: std::sync::OnceLock<Mutex<PowerPolicy>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(PowerPolicy::NORMAL))
}

/// What the power monitor last reported (normal until a source reports; non-Mac systems never do, as in Swift).
pub fn system_power() -> PowerPolicy {
    *locked(system_power_cell())
}

/// The power monitor's report; the session reads it with `system_power`.
pub fn set_system_power(policy: PowerPolicy) {
    *locked(system_power_cell()) = policy;
}

/// Where the thermal state and Low Power Mode come from.
pub trait PowerSource: Send + Sync {
    fn thermal(&self) -> ThermalLevel;
    fn low_power(&self) -> bool;
}

/// A system with no thermal or battery-saver signal (Swift's non-Darwin build): nominal, never low power.
pub struct NominalPower;

impl PowerSource for NominalPower {
    fn thermal(&self) -> ThermalLevel {
        ThermalLevel::Nominal
    }
    fn low_power(&self) -> bool {
        false
    }
}

/// Watches the thermal state and Low Power Mode and reports the resulting policy, on change only. The shell calls `update`
/// when the system says the state changed (the Mac's two notifications); `SQ_THERMAL` forces a level and ignores the system.
pub struct PowerMonitor {
    source: Box<dyn PowerSource>,
    forced: Option<ThermalLevel>,
    thermal: ThermalLevel,
    policy: PowerPolicy,
}

impl PowerMonitor {
    pub fn new(source: Box<dyn PowerSource>, environment: Option<&str>) -> PowerMonitor {
        let forced = ThermalLevel::from_environment(environment);
        let thermal = forced.unwrap_or_else(|| source.thermal());
        let low_power = forced.is_none() && source.low_power();
        PowerMonitor { source, forced, thermal, policy: PowerPolicy::new(thermal, low_power) }
    }

    pub fn policy(&self) -> PowerPolicy {
        self.policy
    }

    pub fn thermal(&self) -> ThermalLevel {
        self.thermal
    }

    /// Reads the system again; the new policy when it changed.
    pub fn update(&mut self) -> Option<PowerPolicy> {
        if self.forced.is_some() {
            return None;
        }
        self.thermal = self.source.thermal();
        let p = PowerPolicy::new(self.thermal, self.source.low_power());
        if p == self.policy {
            return None;
        }
        self.policy = p;
        Some(p)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};

    struct Fake(AtomicU8, AtomicBool);
    impl PowerSource for Arc<Fake> {
        fn thermal(&self) -> ThermalLevel {
            [ThermalLevel::Nominal, ThermalLevel::Fair, ThermalLevel::Serious, ThermalLevel::Critical]
                [usize::from(self.0.load(Ordering::SeqCst))]
        }
        fn low_power(&self) -> bool {
            self.1.load(Ordering::SeqCst)
        }
    }

    #[test]
    fn the_monitor_reports_a_change_once() {
        let fake = Arc::new(Fake(AtomicU8::new(0), AtomicBool::new(false)));
        let mut m = PowerMonitor::new(Box::new(Arc::clone(&fake)), None);
        assert_eq!(m.policy(), PowerPolicy::NORMAL);
        assert_eq!(m.update(), None);
        fake.0.store(2, Ordering::SeqCst);
        let hot = m.update().expect("serious is a change");
        assert!(hot.halves_prefetch);
        assert_eq!(m.update(), None, "no change, no report");
        fake.0.store(0, Ordering::SeqCst);
        fake.1.store(true, Ordering::SeqCst);
        assert!(m.update().is_some_and(|p| p.pauses_background_jobs && !p.halves_prefetch));
    }

    #[test]
    fn a_forced_level_ignores_the_system() {
        let fake = Arc::new(Fake(AtomicU8::new(0), AtomicBool::new(true)));
        let mut m = PowerMonitor::new(Box::new(Arc::clone(&fake)), Some("critical"));
        assert_eq!(m.thermal(), ThermalLevel::Critical);
        assert!(!m.policy().pauses_background_jobs || m.policy().halves_prefetch);
        fake.0.store(0, Ordering::SeqCst);
        assert_eq!(m.update(), None);
        assert_eq!(m.thermal(), ThermalLevel::Critical);
    }

    #[test]
    fn a_nominal_system_is_the_normal_policy() {
        let m = PowerMonitor::new(Box::new(NominalPower), None);
        assert_eq!(m.policy(), PowerPolicy::NORMAL);
    }

    #[test]
    fn a_registration_under_pressure_gets_the_level_at_once_and_dropping_stops_delivery() {
        let r = MemoryPressureRegistry::default();
        r.post(MemoryPressure::Warning);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = Arc::clone(&seen);
        let token = r.register("frames", move |l| locked(&s).push(l));
        assert_eq!(*locked(&seen), vec![MemoryPressure::Warning]);
        r.post(MemoryPressure::Critical);
        r.post(MemoryPressure::Critical);
        assert_eq!(locked(&seen).len(), 3, "a repeated level is delivered again");
        assert_eq!(r.registered_names(), vec!["frames".to_string()]);
        drop(token);
        r.post(MemoryPressure::Normal);
        assert_eq!(locked(&seen).len(), 3);
        assert_eq!(r.level(), MemoryPressure::Normal);
    }

    #[test]
    fn a_stale_level_is_dropped_and_a_nested_post_is_delivered_after_the_running_handler() {
        let r = MemoryPressureRegistry::default();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let (s, again) = (Arc::clone(&seen), r.clone());
        let _t = r.register("nested", move |l| {
            locked(&s).push(l);
            if l == MemoryPressure::Warning {
                // A post from inside the handler: delivered after this call returns, in order.
                again.post(MemoryPressure::Normal);
            }
        });
        r.post(MemoryPressure::Warning);
        assert_eq!(*locked(&seen), vec![MemoryPressure::Warning, MemoryPressure::Normal]);
        let gate = Gate { state: Mutex::default(), handler: Arc::new(|_| {}) };
        gate.deliver(MemoryPressure::Normal, 5);
        gate.deliver(MemoryPressure::Warning, 4);
        assert_eq!(locked(&gate.state).seen, 5, "the older level did not replace the newer");
    }
}
